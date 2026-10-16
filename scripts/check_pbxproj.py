"""Structural validator for an Xcode project.pbxproj (old-style ASCII plist).

Usage: python3 scripts/check_pbxproj.py MIQ.xcodeproj/project.pbxproj .

Checks: the file parses as an OpenStep plist; every 24-hex ID referenced anywhere is
defined; every `ID /* comment */` comment matches the object's name; every file
reference sits in exactly one group and exists on disk; every build file sits in
exactly one build phase and points at a real file/product; target wiring
(phases, config lists, dependencies, proxies) is consistent; Info.plist /
entitlements paths named in build settings exist.
"""
import os
import re
import sys

ID_RE = re.compile(r"\b[0-9A-F]{24}\b")


class Parser:
    def __init__(self, text):
        self.s = text
        self.i = 0

    def ws(self):
        s = self.s
        while self.i < len(s):
            c = s[self.i]
            if c in " \t\r\n":
                self.i += 1
            elif s.startswith("//", self.i):
                j = s.find("\n", self.i)
                self.i = len(s) if j < 0 else j + 1
            elif s.startswith("/*", self.i):
                j = s.find("*/", self.i + 2)
                if j < 0:
                    raise ValueError("unterminated comment at %d" % self.i)
                self.i = j + 2
            else:
                break

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.dict()
        if c == "(":
            return self.array()
        if c == '"':
            return self.quoted()
        return self.bare()

    def dict(self):
        self.i += 1
        out = {}
        while True:
            self.ws()
            if self.s[self.i] == "}":
                self.i += 1
                return out
            key = self.value()
            if not isinstance(key, str):
                raise ValueError("non-string key at %d" % self.i)
            self.ws()
            if self.s[self.i] != "=":
                raise ValueError("expected '=' at %d near %r" % (self.i, self.s[self.i:self.i + 40]))
            self.i += 1
            val = self.value()
            self.ws()
            if self.s[self.i] != ";":
                raise ValueError("expected ';' at %d near %r" % (self.i, self.s[self.i:self.i + 40]))
            self.i += 1
            if key in out:
                raise ValueError("duplicate key %r" % key)
            out[key] = val

    def array(self):
        self.i += 1
        out = []
        while True:
            self.ws()
            if self.s[self.i] == ")":
                self.i += 1
                return out
            out.append(self.value())
            self.ws()
            if self.s[self.i] == ",":
                self.i += 1
            elif self.s[self.i] != ")":
                raise ValueError("expected ',' or ')' at %d" % self.i)

    def quoted(self):
        self.i += 1
        buf = []
        while True:
            c = self.s[self.i]
            if c == "\\":
                buf.append(self.s[self.i:self.i + 2])
                self.i += 2
            elif c == '"':
                self.i += 1
                return "".join(buf)
            else:
                buf.append(c)
                self.i += 1

    def bare(self):
        m = re.compile(r"[A-Za-z0-9_$+/:.\-]+").match(self.s, self.i)
        if not m:
            raise ValueError("unexpected char %r at %d" % (self.s[self.i], self.i))
        self.i = m.end()
        return m.group(0)


def _inside(base, *parts):
    """Resolve ``parts`` under ``base`` and refuse anything that lands outside it."""
    root = os.path.realpath(base)
    path = os.path.realpath(os.path.join(root, *parts))
    if os.path.commonpath([root, path]) != root:
        raise SystemExit("refusing path outside %s: %s" % (root, os.path.join(*parts)))
    return path


# Build-phase display names Xcode writes in `ID /* name */` comments.
PHASE_NAMES = {
    "PBXSourcesBuildPhase": "Sources",
    "PBXFrameworksBuildPhase": "Frameworks",
    "PBXResourcesBuildPhase": "Resources",
}


def _build_file_name(objects, oid, o):
    ref = o.get("fileRef") or o.get("productRef")
    phase = next((ph for ph in objects.values() if oid in ph.get("files", []) and "isa" in ph), None)
    pname = None
    if phase is not None:
        pname = phase.get("name") or PHASE_NAMES.get(phase["isa"])
    return "%s in %s" % (display_name(objects, ref), pname)


def _file_name(objects, oid, o):
    return o.get("name") or o.get("path")


def _config_list_name(objects, oid, o):
    owner = next(x for x in objects.values() if x.get("buildConfigurationList") == oid)
    return 'Build configuration list for %s "%s"' % (owner["isa"], owner.get("name", "MIQ"))


def _remote_package_name(objects, oid, o):
    return 'XCRemoteSwiftPackageReference "%s"' % o["repositoryURL"].rstrip("/").split("/")[-1]


# isa → function(objects, oid, object) giving the name Xcode puts in comments.
NAMERS = {
    "PBXBuildFile": _build_file_name,
    "PBXFileReference": _file_name,
    "PBXGroup": _file_name,
    "PBXVariantGroup": _file_name,
    "XCSwiftPackageProductDependency": lambda objects, oid, o: o["productName"],
    "PBXNativeTarget": lambda objects, oid, o: o["name"],
    "PBXProject": lambda objects, oid, o: "Project object",
    "PBXContainerItemProxy": lambda objects, oid, o: o["isa"],
    "PBXTargetDependency": lambda objects, oid, o: o["isa"],
    "PBXCopyFilesBuildPhase": lambda objects, oid, o: o.get("name", "CopyFiles"),
    "XCBuildConfiguration": lambda objects, oid, o: o["name"],
    "XCConfigurationList": _config_list_name,
    "XCLocalSwiftPackageReference": lambda objects, oid, o: 'XCLocalSwiftPackageReference "%s"' % o["relativePath"],
    "XCRemoteSwiftPackageReference": _remote_package_name,
}


def display_name(objects, oid):
    """The comment Xcode writes after ``oid``, or None for kinds not checked."""
    o = objects[oid]
    isa = o["isa"]
    if isa in PHASE_NAMES:
        return PHASE_NAMES[isa]
    namer = NAMERS.get(isa)
    return namer(objects, oid, o) if namer else None


def check_sections(text, objects, errors):
    """Each object sits inside the section named after its isa; sections are sorted."""
    for m in re.finditer(r"/\* Begin (\w+) section \*/(.*?)/\* End \1 section \*/", text, re.S):
        isa, body = m.group(1), m.group(2)
        for oid in re.findall(r"^\t\t([0-9A-F]{24})\b", body, re.M):
            if objects[oid]["isa"] != isa:
                errors.append("%s (%s) is in the %s section" % (oid, objects[oid]["isa"], isa))
    sections = re.findall(r"/\* Begin (\w+) section \*/", text)
    if sections != sorted(sections):
        errors.append("sections not in alphabetical order: %s" % sections)


def check_comments(text, objects, errors):
    """Comments after IDs must match the object they name."""
    for m in re.finditer(r"\b([0-9A-F]{24}) /\* (.*?) \*/", text):
        oid, comment = m.group(1), m.group(2)
        if oid not in objects:
            continue
        expected = display_name(objects, oid)
        if expected is not None and comment != expected:
            errors.append("comment mismatch for %s: %r != %r" % (oid, comment, expected))


def group_parents(objects, errors):
    """Child ID → parent group ID; a child listed by two groups is an error."""
    parents = {}
    for gid, g in objects.items():
        if g["isa"] not in ("PBXGroup", "PBXVariantGroup"):
            continue
        for child in g["children"]:
            if child in parents:
                errors.append("%s has two parents" % child)
            parents[child] = gid
    return parents


class GroupTree:
    """Resolves group / file-reference paths on disk through the group tree."""

    def __init__(self, objects, parents, main_group, root):
        self.objects = objects
        self.parents = parents
        self.main_group = main_group
        self.root = root

    def resolve(self, oid):
        o = self.objects[oid]
        tree = o.get("sourceTree")
        own = o.get("path", "")
        if tree == "<group>":
            if oid == self.main_group:
                return self.root
            return os.path.normpath(os.path.join(self.resolve(self.parents[oid]), own))
        if tree == "SOURCE_ROOT":
            return os.path.normpath(os.path.join(self.root, own))
        return None


def _check_group_member(objects, root_id, tree, oid, errors):
    o = objects[oid]
    if o.get("sourceTree") == "BUILT_PRODUCTS_DIR":
        if tree.parents.get(oid) != objects[root_id]["productRefGroup"]:
            errors.append("product %s not in Products group" % oid)
        return
    if oid not in tree.parents:
        errors.append("%s (%s) is in no group" % (oid, display_name(objects, oid)))
        return
    if o["isa"] == "PBXFileReference":
        fs = tree.resolve(oid)
        if fs and not os.path.exists(fs) and not fs.endswith("LocalSigning.xcconfig"):
            errors.append("missing on disk: %s" % fs)


def check_groups(objects, root_id, root, errors):
    """Every non-main group / file ref has exactly one parent; file refs exist on disk."""
    parents = group_parents(objects, errors)
    main_group = objects[root_id]["mainGroup"]
    tree = GroupTree(objects, parents, main_group, root)
    for oid, o in objects.items():
        if o["isa"] in ("PBXGroup", "PBXVariantGroup", "PBXFileReference") and oid != main_group:
            _check_group_member(objects, root_id, tree, oid, errors)


def build_file_phases(objects, errors):
    """Build file ID → the phase listing it; phases list only build files, once each."""
    phase_of = {}
    for pid, ph in objects.items():
        if not ph["isa"].endswith("BuildPhase"):
            continue
        for bf in ph["files"]:
            if objects[bf]["isa"] != "PBXBuildFile":
                errors.append("phase %s lists non-build-file %s" % (pid, bf))
            if bf in phase_of:
                errors.append("build file %s in two phases" % bf)
            phase_of[bf] = pid
    return phase_of


def check_build_files(objects, errors):
    """Build files: one phase each, valid target."""
    phase_of = build_file_phases(objects, errors)
    for bid, b in objects.items():
        if b["isa"] != "PBXBuildFile":
            continue
        if bid not in phase_of:
            errors.append("build file %s in no phase" % bid)
        ref = b.get("fileRef") or b.get("productRef")
        if ref is None or objects[ref]["isa"] not in ("PBXFileReference", "PBXVariantGroup", "XCSwiftPackageProductDependency"):
            errors.append("build file %s has bad ref" % bid)


def _check_target_configs(objects, t, root, errors):
    cl = objects[t["buildConfigurationList"]]
    names = sorted(objects[c]["name"] for c in cl["buildConfigurations"])
    if names != ["Debug", "Release"]:
        errors.append("target %s configs %s" % (t["name"], names))
    for c in cl["buildConfigurations"]:
        bs = objects[c]["buildSettings"]
        for key in ("INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS"):
            if key in bs and not os.path.exists(os.path.join(root, bs[key])):
                errors.append("%s %s missing: %s" % (t["name"], key, bs[key]))


def _check_target_dependencies(objects, t, root_id, errors):
    for dep in t["dependencies"]:
        d = objects[dep]
        proxy = objects[d["targetProxy"]]
        if proxy["remoteGlobalIDString"] != d["target"] or objects[d["target"]]["name"] != proxy["remoteInfo"]:
            errors.append("dependency %s proxy mismatch" % dep)
        if proxy["containerPortal"] != root_id:
            errors.append("proxy %s wrong portal" % d["targetProxy"])
    for pkg in t.get("packageProductDependencies", []):
        if objects[pkg]["isa"] != "XCSwiftPackageProductDependency":
            errors.append("bad package dep %s" % pkg)


def check_targets(objects, root_id, root, errors):
    """Target wiring: phases, config lists, dependencies, proxies, products."""
    owner_of_phase = {}
    for tid in objects[root_id]["targets"]:
        t = objects[tid]
        if t["isa"] != "PBXNativeTarget":
            errors.append("%s is not a native target" % tid)
        for ph in t["buildPhases"]:
            if ph in owner_of_phase:
                errors.append("phase %s shared by two targets" % ph)
            owner_of_phase[ph] = tid
        _check_target_configs(objects, t, root, errors)
        _check_target_dependencies(objects, t, root_id, errors)
        prod = objects[t["productReference"]]
        if prod.get("sourceTree") != "BUILT_PRODUCTS_DIR":
            errors.append("product of %s not in BUILT_PRODUCTS_DIR" % t["name"])
    for pid, ph in objects.items():
        if ph["isa"].endswith("BuildPhase") and pid not in owner_of_phase:
            errors.append("phase %s owned by no target" % pid)


def check_embeds(objects, root_id, errors):
    """Embedded products must come from a target the embedding target depends on."""
    targets = objects[root_id]["targets"]
    for tid in targets:
        t = objects[tid]
        deps = {objects[d]["target"] for d in t["dependencies"]}
        copy_phases = [ph for ph in t["buildPhases"] if objects[ph]["isa"] == "PBXCopyFilesBuildPhase"]
        for ph in copy_phases:
            for bf in objects[ph]["files"]:
                ref = objects[bf]["fileRef"]
                producer = [x for x in targets if objects[x]["productReference"] == ref]
                if not producer or producer[0] not in deps:
                    errors.append("%s embeds %s without a dependency on its target" % (t["name"], ref))


def parse_project(text):
    """Parses ``text``; returns the root plist and any header / trailing-content errors."""
    errors = []
    if not text.startswith("// !$*UTF8*$!"):
        errors.append("missing UTF8 header")
    p = Parser(text)
    plist = p.value()
    p.ws()
    if p.i != len(text):
        errors.append("trailing content after root dict at %d" % p.i)
    return plist, errors


def fail(errors):
    print("\n".join(errors))
    sys.exit(1)


def main():
    # The script is run from the repository root; both arguments must stay inside it.
    cwd = os.getcwd()
    root = _inside(cwd, sys.argv[2])
    with open(_inside(cwd, sys.argv[1]), encoding="utf-8") as fh:
        text = fh.read()

    plist, errors = parse_project(text)
    objects = plist["objects"]
    root_id = plist["rootObject"]

    # Every ID token in the file must be a defined object.
    for ref in sorted(set(ID_RE.findall(text))):
        if ref not in objects:
            errors.append("referenced but undefined ID %s" % ref)
    if errors:  # later checks assume a closed object graph
        fail(errors)

    check_sections(text, objects, errors)
    check_comments(text, objects, errors)
    check_groups(objects, root_id, root, errors)
    check_build_files(objects, errors)
    check_targets(objects, root_id, root, errors)
    check_embeds(objects, root_id, errors)

    if errors:
        fail(errors)
    print("OK: %d objects, %d targets" % (len(objects), len(objects[root_id]["targets"])))
    for tid in objects[root_id]["targets"]:
        t = objects[tid]
        phases = ["%s(%d)" % (display_name(objects, ph), len(objects[ph]["files"])) for ph in t["buildPhases"]]
        print("  %-22s %-36s %s" % (t["name"], t["productType"], " ".join(phases)))


if __name__ == "__main__":
    main()
