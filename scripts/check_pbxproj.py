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


def _confined(arg):
    """Resolve a command-line path and require it to stay inside the current
    directory tree (the script is run from the repository root)."""
    cwd = os.path.realpath(os.getcwd())
    path = os.path.realpath(os.path.join(cwd, arg))
    if os.path.commonpath([cwd, path]) != cwd:
        sys.exit("refusing path outside %s: %s" % (cwd, arg))
    return path


def main():
    path, root = _confined(sys.argv[1]), _confined(sys.argv[2])
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    errors = []

    if not text.startswith("// !$*UTF8*$!"):
        errors.append("missing UTF8 header")
    p = Parser(text)
    plist = p.value()
    p.ws()
    if p.i != len(text):
        errors.append("trailing content after root dict at %d" % p.i)
    objects = plist["objects"]
    root_id = plist["rootObject"]

    # Every ID token in the file must be a defined object.
    for ref in sorted(set(ID_RE.findall(text))):
        if ref not in objects:
            errors.append("referenced but undefined ID %s" % ref)
    if errors:  # later checks assume a closed object graph
        print("\n".join(errors))
        sys.exit(1)

    # Section markers: each object sits inside the section named after its isa.
    for m in re.finditer(r"/\* Begin (\w+) section \*/(.*?)/\* End \1 section \*/", text, re.S):
        isa, body = m.group(1), m.group(2)
        for oid in re.findall(r"^\t\t([0-9A-F]{24})\b", body, re.M):
            if objects[oid]["isa"] != isa:
                errors.append("%s (%s) is in the %s section" % (oid, objects[oid]["isa"], isa))
    sections = re.findall(r"/\* Begin (\w+) section \*/", text)
    if sections != sorted(sections):
        errors.append("sections not in alphabetical order: %s" % sections)

    def display_name(oid):
        o = objects[oid]
        isa = o["isa"]
        if isa == "PBXBuildFile":
            ref = o.get("fileRef") or o.get("productRef")
            phase = next((ph for ph in objects.values() if oid in ph.get("files", []) and "isa" in ph), None)
            pname = None
            if phase is not None:
                pname = phase.get("name") or {"PBXSourcesBuildPhase": "Sources", "PBXFrameworksBuildPhase": "Frameworks",
                                               "PBXResourcesBuildPhase": "Resources"}.get(phase["isa"])
            return "%s in %s" % (display_name(ref), pname)
        if isa in ("PBXFileReference", "PBXGroup", "PBXVariantGroup"):
            return o.get("name") or o.get("path")
        if isa == "XCSwiftPackageProductDependency":
            return o["productName"]
        if isa == "PBXNativeTarget":
            return o["name"]
        if isa == "PBXProject":
            return "Project object"
        if isa in ("PBXContainerItemProxy", "PBXTargetDependency"):
            return isa
        if isa in ("PBXSourcesBuildPhase",):
            return "Sources"
        if isa == "PBXFrameworksBuildPhase":
            return "Frameworks"
        if isa == "PBXResourcesBuildPhase":
            return "Resources"
        if isa == "PBXCopyFilesBuildPhase":
            return o.get("name", "CopyFiles")
        if isa == "XCBuildConfiguration":
            return o["name"]
        if isa == "XCConfigurationList":
            owner = next(x for x in objects.values() if x.get("buildConfigurationList") == oid)
            return 'Build configuration list for %s "%s"' % (owner["isa"], owner.get("name", "MIQ"))
        if isa == "XCLocalSwiftPackageReference":
            return 'XCLocalSwiftPackageReference "%s"' % o["relativePath"]
        if isa == "XCRemoteSwiftPackageReference":
            return 'XCRemoteSwiftPackageReference "%s"' % o["repositoryURL"].rstrip("/").split("/")[-1]
        return None

    # Comments after IDs must match the object they name.
    for m in re.finditer(r"\b([0-9A-F]{24}) /\* (.*?) \*/", text):
        oid, comment = m.group(1), m.group(2)
        if oid not in objects:
            continue
        expected = display_name(oid)
        if expected is not None and comment != expected:
            errors.append("comment mismatch for %s: %r != %r" % (oid, comment, expected))

    # Group tree: every non-main group / file ref has exactly one parent; resolve paths.
    parents = {}
    for gid, g in objects.items():
        if g["isa"] in ("PBXGroup", "PBXVariantGroup"):
            for child in g["children"]:
                if child in parents:
                    errors.append("%s has two parents" % child)
                parents[child] = gid
    main_group = objects[root_id]["mainGroup"]

    def resolve(oid):
        o = objects[oid]
        tree = o.get("sourceTree")
        own = o.get("path", "")
        if tree == "<group>":
            if oid == main_group:
                return root
            return os.path.normpath(os.path.join(resolve(parents[oid]), own))
        if tree == "SOURCE_ROOT":
            return os.path.normpath(os.path.join(root, own))
        return None

    for oid, o in objects.items():
        if o["isa"] in ("PBXGroup", "PBXVariantGroup", "PBXFileReference") and oid != main_group:
            if o.get("sourceTree") == "BUILT_PRODUCTS_DIR":
                if parents.get(oid) != objects[root_id]["productRefGroup"]:
                    errors.append("product %s not in Products group" % oid)
                continue
            if oid not in parents:
                errors.append("%s (%s) is in no group" % (oid, display_name(oid)))
                continue
            if o["isa"] == "PBXFileReference":
                fs = resolve(oid)
                if fs and not os.path.exists(fs) and not fs.endswith("LocalSigning.xcconfig"):
                    errors.append("missing on disk: %s" % fs)

    # Build files: one phase each, valid target.
    phase_of = {}
    for pid, ph in objects.items():
        if ph["isa"].endswith("BuildPhase"):
            for bf in ph["files"]:
                if objects[bf]["isa"] != "PBXBuildFile":
                    errors.append("phase %s lists non-build-file %s" % (pid, bf))
                if bf in phase_of:
                    errors.append("build file %s in two phases" % bf)
                phase_of[bf] = pid
    for bid, b in objects.items():
        if b["isa"] == "PBXBuildFile":
            if bid not in phase_of:
                errors.append("build file %s in no phase" % bid)
            ref = b.get("fileRef") or b.get("productRef")
            if ref is None or objects[ref]["isa"] not in ("PBXFileReference", "PBXVariantGroup", "XCSwiftPackageProductDependency"):
                errors.append("build file %s has bad ref" % bid)

    # Targets.
    owner_of_phase = {}
    for tid in objects[root_id]["targets"]:
        t = objects[tid]
        if t["isa"] != "PBXNativeTarget":
            errors.append("%s is not a native target" % tid)
        for ph in t["buildPhases"]:
            if ph in owner_of_phase:
                errors.append("phase %s shared by two targets" % ph)
            owner_of_phase[ph] = tid
        cl = objects[t["buildConfigurationList"]]
        names = sorted(objects[c]["name"] for c in cl["buildConfigurations"])
        if names != ["Debug", "Release"]:
            errors.append("target %s configs %s" % (t["name"], names))
        for c in cl["buildConfigurations"]:
            bs = objects[c]["buildSettings"]
            for key in ("INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS"):
                if key in bs and not os.path.exists(os.path.join(root, bs[key])):
                    errors.append("%s %s missing: %s" % (t["name"], key, bs[key]))
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
        prod = objects[t["productReference"]]
        if prod.get("sourceTree") != "BUILT_PRODUCTS_DIR":
            errors.append("product of %s not in BUILT_PRODUCTS_DIR" % t["name"])
    for pid, ph in objects.items():
        if ph["isa"].endswith("BuildPhase") and pid not in owner_of_phase:
            errors.append("phase %s owned by no target" % pid)

    # Embedded products must come from a target the embedding target depends on.
    for tid in objects[root_id]["targets"]:
        t = objects[tid]
        deps = {objects[d]["target"] for d in t["dependencies"]}
        for ph in t["buildPhases"]:
            if objects[ph]["isa"] != "PBXCopyFilesBuildPhase":
                continue
            for bf in objects[ph]["files"]:
                ref = objects[bf]["fileRef"]
                producer = [x for x in objects[root_id]["targets"] if objects[x]["productReference"] == ref]
                if not producer or producer[0] not in deps:
                    errors.append("%s embeds %s without a dependency on its target" % (t["name"], ref))

    if errors:
        print("\n".join(errors))
        sys.exit(1)
    print("OK: %d objects, %d targets" % (len(objects), len(objects[root_id]["targets"])))
    for tid in objects[root_id]["targets"]:
        t = objects[tid]
        phases = ["%s(%d)" % (display_name(ph), len(objects[ph]["files"])) for ph in t["buildPhases"]]
        print("  %-22s %-36s %s" % (t["name"], t["productType"], " ".join(phases)))


if __name__ == "__main__":
    main()
