#!/usr/bin/env python3
"""Generate the cross-platform conformance corpus in Tests/Fixtures/conformance/.

Each case is a tiny reference volume (one of NIfTI-1, NIfTI-2, MGH, MRtrix MIF,
NRRD; some gzip'd) plus an expected.json describing what a conforming reader
must report for it: dimensions, spacing, datatype, volume count, storage
orientation code, effective scaling, a few probe voxels, and the SHA-256 of
each canonical center slice. The contract is spelled out in
Tests/Fixtures/conformance/README.md; MIQ (Swift, ConformanceCorpusTests) and
its Windows sibling MIQ-Win both verify themselves against these files.

The expected values are computed here, independently of either reader, from
the voxel array this script writes — so a reader passing the corpus agrees
with the contract, not merely with the other reader.

Usage:
    scripts/dev/make_conformance_corpus.py [OUTPUT_DIR]

OUTPUT_DIR defaults to Tests/Fixtures/conformance next to this script's
repository root. Output is deterministic (gzip mtime 0, fixed values), so
re-running it on an unchanged script leaves the committed files unchanged.
Standard library only (struct, gzip, json, hashlib).
"""

import gzip
import hashlib
import json
import math
import os
import struct
import sys

CONTRACT_VERSION = 1

# Odd extents on every spatial axis, so the center index floor(n/2) is the
# same counted from either end of an axis: a reader that reverses an axis for
# display picks the same physical slice as one that does not.
NX, NY, NZ = 5, 7, 9


def f32(x):
    """Round a Python float to IEEE float32 (the readers' value type)."""
    return struct.unpack("<f", struct.pack("<f", x))[0]


def pattern(x, y, z, t=0):
    """Distinct value per voxel: decimal digits encode the logical coordinate."""
    return x + 10 * y + 100 * z + 1000 * t


# ---------------------------------------------------------------------------
# Logical volume model
# ---------------------------------------------------------------------------
#
# Every case is described in *reader storage space*: three spatial axes in
# on-disk traversal order (axis 0 fastest), plus volumes. For NIfTI/MGH/NRRD
# that is simply the file's own axis order; for MIF it is the axes sorted by
# `layout` rank (see README "Storage space").


class Case:
    def __init__(self, name, filename, fmt, description, dims, volumes, spacing, datatype,
                 orientation, raw, slope=1.0, inter=0.0, pending=None):
        self.name = name
        self.filename = filename
        self.fmt = fmt
        self.description = description
        self.dims = dims            # [nx, ny, nz] in storage space
        self.volumes = volumes
        self.spacing = spacing      # per storage axis, mm
        self.datatype = datatype    # MIQ datatype label
        self.orientation = orientation  # e.g. "LPS", or "unknown"
        self.raw = raw              # raw(x, y, z, t) -> stored number
        self.slope = slope          # effective scaling: value = raw * slope + inter
        self.inter = inter
        self.pending = pending

    def value(self, x, y, z, t):
        raw = float(self.raw(x, y, z, t))
        # Exact identity scaling (no rounding steps): compared exactly on purpose.
        if math.isclose(self.slope, 1.0, rel_tol=0.0, abs_tol=0.0) and math.isclose(self.inter, 0.0, abs_tol=0.0):
            return f32(raw)
        # Two float32 roundings, as the readers compute it (no fused multiply-add).
        return f32(f32(f32(raw) * f32(self.slope)) + f32(self.inter))

    def storage_values(self):
        """All values in storage order: x fastest, then y, z, t."""
        nx, ny, nz = self.dims
        return [self.raw(x, y, z, t)
                for t in range(self.volumes)
                for z in range(nz) for y in range(ny) for x in range(nx)]


# ---------------------------------------------------------------------------
# Canonical slices (the contract's slice definition; see README)
# ---------------------------------------------------------------------------

AXIS = {"R": ("RL", True), "L": ("RL", False), "A": ("AP", True), "P": ("AP", False),
        "S": ("SI", True), "I": ("SI", False)}

# stored mode: (sliceAxis, hAxis, vAxis); h runs forward, v runs from its last index down.
STORED = {"coronal": (1, 0, 2), "sagittal": (0, 1, 2), "axial": (2, 0, 1)}

# neurological mode: (slice anatomy, h anatomy, v anatomy, h positive, v positive)
NEURO = {
    "coronal": ("AP", "RL", "SI", True, True),   # cols L->R, rows S at top
    "sagittal": ("RL", "AP", "SI", False, True),  # cols A->P, rows S at top
    "axial": ("SI", "RL", "AP", True, True),      # cols L->R, rows A at top
}

PLANES = ["axial", "coronal", "sagittal"]


def plan(case, mode, plane):
    """(sliceAxis, hAxis, vAxis, hReversed, vReversed) for a plane in a mode."""
    if mode == "stored" or case.orientation == "unknown":
        s, h, v = STORED[plane]
        return s, h, v, False, True
    roles = [AXIS[letter] for letter in case.orientation]
    s_anat, h_anat, v_anat, h_pos, v_pos = NEURO[plane]
    s = next(i for i, r in enumerate(roles) if r[0] == s_anat)
    h = next(i for i, r in enumerate(roles) if r[0] == h_anat)
    v = next(i for i, r in enumerate(roles) if r[0] == v_anat)
    return s, h, v, roles[h][1] != h_pos, roles[v][1] == v_pos


def canonical_slice(case, mode, plane, volume):
    s, h, v, h_rev, v_rev = plan(case, mode, plane)
    dims = case.dims
    index = dims[s] // 2
    out = bytearray()
    for row in range(dims[v]):
        for col in range(dims[h]):
            c = [0, 0, 0]
            c[s] = index
            c[h] = dims[h] - 1 - col if h_rev else col
            c[v] = dims[v] - 1 - row if v_rev else row
            out += struct.pack("<f", case.value(c[0], c[1], c[2], volume))
    return {
        "mode": mode,
        "plane": plane,
        "volume": volume,
        "sliceAxis": s,
        "sliceIndex": index,
        "width": dims[h],
        "height": dims[v],
        "sha256": hashlib.sha256(bytes(out)).hexdigest(),
    }


def expected(case):
    nx, ny, nz = case.dims
    last = case.volumes - 1
    probes = [(0, 0, 0, 0), (nx // 2, ny // 2, nz // 2, 0), (nx - 1, ny - 1, nz - 1, last), (1, 2, 3, last)]
    volumes = [0] if case.volumes == 1 else [0, last]
    return {
        "contractVersion": CONTRACT_VERSION,
        "file": case.filename,
        "format": case.fmt,
        "description": case.description,
        "dims": case.dims,
        "volumes": case.volumes,
        "spacing": case.spacing,
        "datatype": case.datatype,
        "orientation": case.orientation,
        "effectiveScaling": {"slope": case.slope, "inter": case.inter},
        "probes": [{"x": x, "y": y, "z": z, "t": t, "value": case.value(x, y, z, t)} for x, y, z, t in probes],
        "slices": [canonical_slice(case, mode, plane, vol)
                   for vol in volumes for mode in ("stored", "neurological") for plane in PLANES],
        "pending": case.pending,
    }


# ---------------------------------------------------------------------------
# Writers
# ---------------------------------------------------------------------------

NIFTI_TYPES = {"uint8": (2, "B"), "int16": (4, "h"), "float32": (16, "f"), "float64": (64, "d")}


def pack_values(values, code, big_endian=False):
    return struct.pack((">" if big_endian else "<") + code * len(values), *values)


def nifti1(case, sform_code=0, srow=None, qform_code=0, quatern=(0.0, 0.0, 0.0), qfac=1.0,
           slope=0.0, inter=0.0):
    dt, code = NIFTI_TYPES[case.datatype]
    hdr = bytearray(352)
    struct.pack_into("<i", hdr, 0, 348)
    ndim = 4 if case.volumes > 1 else 3
    struct.pack_into("<8h", hdr, 40, ndim, *case.dims, case.volumes, 1, 1, 1)
    struct.pack_into("<hh", hdr, 70, dt, struct.calcsize(code) * 8)
    struct.pack_into("<8f", hdr, 76, qfac, *case.spacing, 1, 0, 0, 0)
    struct.pack_into("<fff", hdr, 108, 352.0, slope, inter)
    struct.pack_into("<hh", hdr, 252, qform_code, sform_code)
    struct.pack_into("<3f", hdr, 256, *quatern)
    rows = srow or [[0.0] * 4] * 3
    for i, row in enumerate(rows):
        struct.pack_into("<4f", hdr, 280 + 16 * i, *row)
    hdr[344:348] = b"n+1\x00"
    return bytes(hdr) + pack_values(case.storage_values(), code)


def nifti2(case, srow):
    dt, code = NIFTI_TYPES[case.datatype]
    hdr = bytearray(544)
    struct.pack_into("<i", hdr, 0, 540)
    hdr[4:12] = b"n+2\x00\r\n\x1a\n"
    struct.pack_into("<hh", hdr, 12, dt, struct.calcsize(code) * 8)
    struct.pack_into("<8q", hdr, 16, 4 if case.volumes > 1 else 3, *case.dims, case.volumes, 1, 1, 1)
    struct.pack_into("<8d", hdr, 104, 1.0, *case.spacing, 1, 0, 0, 0)
    struct.pack_into("<q", hdr, 168, 544)
    struct.pack_into("<dd", hdr, 176, 0.0, 0.0)
    struct.pack_into("<ii", hdr, 344, 0, 1)  # qform_code, sform_code
    for i, row in enumerate(srow):
        struct.pack_into("<4d", hdr, 400 + 32 * i, *row)
    return bytes(hdr) + pack_values(case.storage_values(), code)


def mgh(case, cosines):
    """cosines: x_ras, y_ras, z_ras (direction of each storage axis in RAS)."""
    types = {"uint8": (0, "B"), "int32": (1, "i"), "float32": (3, "f"), "int16": (4, "h")}
    mtype, code = types[case.datatype]
    hdr = bytearray(284)
    struct.pack_into(">7i", hdr, 0, 1, *case.dims, case.volumes, mtype, 0)
    struct.pack_into(">h", hdr, 28, 1)  # goodRASFlag
    struct.pack_into(">3f", hdr, 30, *case.spacing)
    struct.pack_into(">9f", hdr, 42, *(c for col in cosines for c in col))
    return bytes(hdr) + pack_values(case.storage_values(), code, big_endian=True)


def mif(case, image_dims, vox, layout, transform):
    """`image_dims` / `vox` / `layout` are in *image* axis order; the payload is
    written in storage order (layout rank order), which is what `case` models."""
    lines = [
        "mrtrix image",
        "dim: " + ",".join(str(d) for d in image_dims),
        "vox: " + ",".join(repr(float(v)) for v in vox),
        "layout: " + layout,
        "datatype: Float32LE",
    ] + ["transform: " + ",".join(repr(float(v)) for v in row) for row in transform]
    offset = 0
    while True:
        text = "\n".join(lines + ["file: . %d" % offset, "END"]) + "\n"
        if len(text.encode()) == offset:
            break
        offset = len(text.encode())
    return text.encode() + pack_values(case.storage_values(), "f")


def nrrd(case, fields, encoding):
    head = ["NRRD0004", "type: short", "dimension: 3", "sizes: %d %d %d" % tuple(case.dims)]
    head += fields + ["endian: little", "encoding: " + encoding]
    payload = pack_values(case.storage_values(), "h")
    if encoding == "gzip":
        payload = gzip.compress(payload, compresslevel=9, mtime=0)
    return ("\n".join(head) + "\n\n").encode() + payload


def gz(data):
    return gzip.compress(data, compresslevel=9, mtime=0)


# ---------------------------------------------------------------------------
# The corpus
# ---------------------------------------------------------------------------

def build_cases():
    D = [NX, NY, NZ]
    cases = []

    def add(case, data):
        cases.append((case, data))

    c = Case("nifti1_ras_float32", "image.nii", "nifti1",
             "NIfTI-1 float32, sform (code 2) diagonal RAS with anisotropic spacing 1x2x3 mm.",
             D, 1, [1.0, 2.0, 3.0], "float32", "RAS", lambda x, y, z, t: pattern(x, y, z) + 0.5)
    add(c, nifti1(c, sform_code=2, srow=[[1, 0, 0, -2], [0, 2, 0, -6], [0, 0, 3, -12]]))

    c = Case("nifti1_las_int16", "image.nii", "nifti1",
             "NIfTI-1 int16, sform diagonal with negative x: LAS.",
             D, 1, [1.0, 1.0, 1.0], "int16", "LAS", lambda x, y, z, t: pattern(x, y, z) - 400)
    add(c, nifti1(c, sform_code=1, srow=[[-1, 0, 0, 2], [0, 1, 0, -3], [0, 0, 1, -4]]))

    c = Case("nifti1_lps_uint8_gz", "image.nii.gz", "nifti1",
             "Gzip'd NIfTI-1 uint8, sform diagonal with negative x and y: LPS (DICOM-like).",
             D, 1, [1.0, 1.0, 1.0], "uint8", "LPS", lambda x, y, z, t: pattern(x, y, z) % 256)
    add(c, gz(nifti1(c, sform_code=1, srow=[[-1, 0, 0, 2], [0, -1, 0, 3], [0, 0, 1, -4]])))

    cos60, sin60 = 0.5, math.sqrt(3) / 2
    c = Case("nifti1_oblique_sform", "image.nii", "nifti1",
             "NIfTI-1 float32, sform rotated 60 degrees about x: j is mostly +S, k mostly -P, so the "
             "dominant-axis code is RSP.",
             D, 1, [1.0, 1.0, 1.0], "float32", "RSP", lambda x, y, z, t: pattern(x, y, z))
    add(c, nifti1(c, sform_code=1, srow=[[1, 0, 0, 0], [0, cos60, -sin60, 0], [0, sin60, cos60, 0]]))

    c = Case("nifti1_qform_only", "image.nii", "nifti1",
             "NIfTI-1 int16, sform_code 0 (its RAS rows must be ignored), qform_code 1 with quaternion "
             "(b,c,d)=(0,0,1) i.e. 180 degrees about z, and qfac (pixdim[0]) = -1: LPI.",
             D, 1, [1.0, 1.0, 1.0], "int16", "LPI", lambda x, y, z, t: pattern(x, y, z))
    add(c, nifti1(c, sform_code=0, srow=[[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
                  qform_code=1, quatern=(0.0, 0.0, 1.0), qfac=-1.0))

    c = Case("nifti1_no_orientation", "image.nii", "nifti1",
             "NIfTI-1 int16 with qform_code = sform_code = 0: orientation is unknown, and the "
             "neurological slices fall back to the stored ones.",
             D, 1, [1.0, 1.0, 1.0], "int16", "unknown", lambda x, y, z, t: pattern(x, y, z))
    add(c, nifti1(c))

    c = Case("nifti2_4d_float64", "image.nii", "nifti2",
             "NIfTI-2 float64, 4D with 3 volumes, sform RAS at 1.5 mm isotropic.",
             D, 3, [1.5, 1.5, 1.5], "float64", "RAS", lambda x, y, z, t: pattern(x, y, z, t) + 0.25)
    add(c, nifti2(c, srow=[[1.5, 0, 0, 0], [0, 1.5, 0, 0], [0, 0, 1.5, 0]]))

    c = Case("nifti1_int16_scaled_gz", "image.nii.gz", "nifti1",
             "Gzip'd NIfTI-1 int16 with scl_slope 0.5 and scl_inter -10 (values are exact in float32).",
             D, 1, [1.0, 1.0, 1.0], "int16", "RAS", lambda x, y, z, t: pattern(x, y, z), slope=0.5, inter=-10.0)
    add(c, gz(nifti1(c, sform_code=1, srow=[[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]], slope=0.5, inter=-10.0)))

    c = Case("nifti1_uint8_labels_gz", "image.nii.gz", "nifti1",
             "Gzip'd NIfTI-1 uint8 label map (27 blocky labels, background 0), sform RAS.",
             D, 1, [1.0, 1.0, 1.0], "uint8", "RAS",
             lambda x, y, z, t: 0 if x == 0 else 1 + (x - 1) // 2 + 3 * (y // 3) + 9 * (z // 4))
    add(c, gz(nifti1(c, sform_code=1, srow=[[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]])))

    c = Case("mgh_lia_int16", "image.mgz", "mgh",
             "Compressed MGH int16 in FreeSurfer's conformed LIA orientation (x_ras=(-1,0,0), "
             "y_ras=(0,0,-1), z_ras=(0,1,0)), spacing 1x1.5x2 mm.",
             D, 1, [1.0, 1.5, 2.0], "int16", "LIA", lambda x, y, z, t: pattern(x, y, z))
    add(c, gz(mgh(c, cosines=[(-1, 0, 0), (0, 0, -1), (0, 1, 0)])))

    # MIF: image axes (i0, i1, i2) = dims 5, 9, 7 with vox 1, 3, 2 and layout -0,+2,+1:
    # i0 is stored fastest and reversed, then i2, then i1. Storage space is therefore
    # (i0, i2, i1) = dims 5x7x9, spacing 1x2x3, and the identity transform composed with
    # the layout gives L (i0 reversed), S (i2), A (i1).
    c = Case("mif_layout_permuted", "image.mif", "mif",
             "MRtrix MIF float32, identity transform, layout -0,+2,+1 (axis 0 reversed, axes 1 and 2 "
             "swapped in storage): storage-space dims 5x7x9 and orientation LSA.",
             D, 1, [1.0, 2.0, 3.0], "float32", "LSA", lambda x, y, z, t: pattern(x, y, z))
    add(c, mif(c, image_dims=[NX, NZ, NY], vox=[1, 3, 2], layout="-0,+2,+1",
               transform=[[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]))

    c = Case("nrrd_lps_gzip", "image.nrrd", "nrrd",
             "NRRD int16, gzip encoding, space left-posterior-superior with diagonal space directions "
             "(1.5,1.5,2): LPS.",
             D, 1, [1.5, 1.5, 2.0], "int16", "LPS", lambda x, y, z, t: pattern(x, y, z))
    add(c, nrrd(c, ["space: left-posterior-superior",
                    "space directions: (1.5,0,0) (0,1.5,0) (0,0,2)",
                    "kinds: domain domain domain", "space origin: (0,0,0)"], "gzip"))

    c = Case("nrrd_no_space", "image.nrrd", "nrrd",
             "NRRD int16, raw encoding, no space / space directions (only spacings): orientation "
             "unknown.",
             D, 1, [1.0, 1.0, 1.0], "int16", "unknown", lambda x, y, z, t: pattern(x, y, z))
    add(c, nrrd(c, ["spacings: 1 1 1", "kinds: domain domain domain"], "raw"))

    return cases


def main():
    root = os.path.realpath(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    out_dir = os.path.realpath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Tests", "Fixtures", "conformance"))
    # Only ever write inside the repository.
    if os.path.commonpath([root, out_dir]) != root:
        sys.exit("refusing to write outside the repository: %s" % out_dir)
    total = 0
    names = []
    for case, data in build_cases():
        case_dir = os.path.join(out_dir, case.name)
        os.makedirs(case_dir, exist_ok=True)
        with open(os.path.join(case_dir, case.filename), "wb") as fh:
            fh.write(data)
        text = json.dumps(expected(case), indent=2) + "\n"
        with open(os.path.join(case_dir, "expected.json"), "w") as fh:
            fh.write(text)
        total += len(data) + len(text)
        names.append(case.name)
    with open(os.path.join(out_dir, "index.json"), "w") as fh:
        fh.write(json.dumps({"contractVersion": CONTRACT_VERSION, "cases": names}, indent=2) + "\n")
    print("wrote %d cases, %d bytes, to %s" % (len(names), total, out_dir))


if __name__ == "__main__":
    main()
