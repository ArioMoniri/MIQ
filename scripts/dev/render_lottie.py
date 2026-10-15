#!/usr/bin/env python3
"""Author the README/website Lottie animations and render them to animated SVG.

GitHub READMEs cannot run JavaScript, so a Lottie file cannot play there
directly. This script keeps one source of truth per animation and produces two
outputs from it:

1. ``docs/lottie/<name>.json`` and ``<name>_dark.json`` -- Lottie (bodymovin
   5.x) documents, played on the website by lottie-web.
2. ``docs/lottie/<name>.svg`` and ``<name>_dark.svg`` -- the same animation
   converted to a self-contained SVG with CSS keyframes, which GitHub shows
   through ``<img>`` / ``<picture>``. The SVG converter reads only the JSON, so
   the two cannot drift apart.

The SVGs honour ``prefers-reduced-motion``: with it set, every animation is
switched off and the elements keep their static attributes, which hold a
"poster" frame chosen per animation (a meaningful still, not a blank first
frame). Viewers that ignore CSS animation see the same poster.

Only the small Lottie subset the scenes below use is converted: shape layers
(rect, ellipse, path, fill, stroke, linear gradient fill, group transform),
text layers with one static document, layer parenting, and animated position,
scale, rotation and opacity with cubic-bezier or hold keyframes.

Usage (Python 3.9+, standard library only)::

    python3 scripts/dev/render_lottie.py            # writes docs/lottie/*
    python3 scripts/dev/render_lottie.py --check    # fails if outputs are stale

To inspect frames, open an SVG in a browser and pause it with
``document.getAnimations().forEach(a => { a.pause(); a.currentTime = ms })``,
or load the JSON with lottie-web and call ``goToAndStop(frame, true)``.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "docs" / "lottie"
FPS = 30

FONT_STACK = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', Helvetica, Arial, sans-serif"
MONO_STACK = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, monospace"
FONTS = {
    "MIQ-Regular": (FONT_STACK, "Regular", 400),
    "MIQ-Semibold": (FONT_STACK, "Semibold", 600),
    "MIQ-Mono": (MONO_STACK, "Regular", 400),
}

# --------------------------------------------------------------------------
# Themes. Panel colours follow GitHub's canvas so the animations sit well in a
# README; the accent is the website's. The crosshair/label red is MIQ's
# default "Axis labels & crosshair colour" (1.0, 0.15, 0.1).
# --------------------------------------------------------------------------

THEMES = {
    "light": {
        "panel": "#f6f8fa", "border": "#d0d7de", "fg": "#1f2328", "soft": "#59636e",
        "accent": "#2f6df6", "accentSoft": "#dbe6fd", "key": "#ffffff", "keyEdge": "#c4ccd5",
        "chrome": "#e4e7eb", "chromeFg": "#3d444d", "paper": "#ffffff", "paperEdge": "#b8c0ca",
        "chip": "#ffffff", "red": "#ff2619", "tile": "#000000",
    },
    "dark": {
        "panel": "#161b22", "border": "#30363d", "fg": "#e6edf3", "soft": "#9198a1",
        "accent": "#5b8dff", "accentSoft": "#1f2f52", "key": "#262c36", "keyEdge": "#454d59",
        "chrome": "#2a2f37", "chromeFg": "#c9d1d9", "paper": "#e9edf2", "paperEdge": "#8b949e",
        "chip": "#21262d", "red": "#ff2619", "tile": "#000000",
    },
}

GREYS = {"scalp": "#5a5a5a", "csf": "#141414", "gm": "#7c7c7c", "wm": "#cdcdcd", "dark": "#1c1c1c",
         "cc": "#e6e6e6", "cereb": "#9a9a9a", "white": "#f2f2f2", "label": "#8f8f8f"}


def rgb(hexstr: str) -> list[float]:
    h = hexstr.lstrip("#")
    return [round(int(h[i:i + 2], 16) / 255, 4) for i in (0, 2, 4)]


def rgba(hexstr: str) -> list[float]:
    return rgb(hexstr) + [1]


# --------------------------------------------------------------------------
# Lottie authoring helpers
# --------------------------------------------------------------------------

EASE = {
    "linear": ((0, 0), (1, 1)),
    "inout": ((0.42, 0), (0.58, 1)),
    "out": ((0.16, 1), (0.3, 1)),
    "in": ((0.5, 0), (0.85, 0.2)),
    "pop": ((0.2, 0.9), (0.3, 1.12)),
}


def st(v):
    """Static property."""
    return {"a": 0, "k": v}


def kf(*frames):
    """Animated property from (frame, value[, ease]) tuples. ``ease`` applies to
    the segment that starts at that keyframe; "hold" keeps the value until the
    next keyframe."""
    keys = []
    for i, f in enumerate(frames):
        t, v = f[0], f[1]
        ease = f[2] if len(f) > 2 else "inout"
        val = v if isinstance(v, list) else [v]
        k = {"t": t, "s": val}
        if i < len(frames) - 1:
            if ease == "hold":
                k["h"] = 1
            else:
                (ox, oy), (ix, iy) = EASE[ease]
                n = len(val)
                k["o"] = {"x": [ox] * n, "y": [oy] * n}
                k["i"] = {"x": [ix] * n, "y": [iy] * n}
        keys.append(k)
    return {"a": 1, "k": keys}


def prop(v):
    return v if isinstance(v, dict) else st(v)


def transform(p=(0, 0), a=(0, 0), s=(100, 100), r=0, o=100):
    return {"p": prop(list(p) if isinstance(p, tuple) else p), "a": prop(list(a)),
            "s": prop(list(s) if isinstance(s, tuple) else s), "r": prop(r), "o": prop(o)}


def rect(w, h, r=0, c=(0, 0)):
    return {"ty": "rc", "d": 1, "p": st(list(c)), "s": st([w, h]), "r": st(r)}


def ellipse(w, h, c=(0, 0)):
    return {"ty": "el", "d": 1, "p": st(list(c)), "s": st([w, h])}


def path(points, closed=True, tin=None, tout=None):
    n = len(points)
    return {"ty": "sh", "d": 1, "ks": st({
        "c": closed, "v": [list(p) for p in points],
        "i": [list(p) for p in (tin or [(0, 0)] * n)],
        "o": [list(p) for p in (tout or [(0, 0)] * n)]})}


def fill(color, opacity=100):
    return {"ty": "fl", "c": st(rgba(color)), "o": st(opacity), "r": 1}


def stroke(color, width, opacity=100):
    return {"ty": "st", "c": st(rgba(color)), "o": st(opacity), "w": st(width), "lc": 2, "lj": 2}


def gradient(start, end, stops):
    """Linear gradient fill; ``stops`` = [(offset, hex, opacity 0-1)]."""
    colors, alphas = [], []
    for off, hexstr, alpha in stops:
        colors += [off] + rgb(hexstr)
        alphas += [off, alpha]
    return {"ty": "gf", "t": 1, "o": st(100), "r": 1, "s": st(list(start)), "e": st(list(end)),
            "g": {"p": len(stops), "k": st(colors + alphas)}}


def group(*items, p=(0, 0), s=(100, 100), r=0, o=100, name="g"):
    tr = {"ty": "tr", "p": st(list(p)), "a": st([0, 0]), "s": st(list(s)), "r": st(r), "o": st(o)}
    return {"ty": "gr", "nm": name, "it": list(items) + [tr]}


class Scene:
    def __init__(self, name, w, h, frames, poster):
        self.name, self.w, self.h, self.op, self.poster = name, w, h, frames, poster
        self.layers = []  # in paint order (first = bottom); reversed for Lottie

    def add(self, nm, ks=None, shapes=None, text=None, parent=None):
        ind = len(self.layers) + 1
        layer = {"ddd": 0, "ind": ind, "nm": nm, "sr": 1, "ks": ks or transform(), "ao": 0,
                 "ip": 0, "op": self.op, "st": 0, "bm": 0}
        if parent is not None:
            layer["parent"] = parent
        if text is not None:
            layer["ty"] = 5
            layer["t"] = text
        elif shapes is not None:
            layer["ty"] = 4
            layer["shapes"] = shapes
        else:
            layer["ty"] = 3  # null layer: a transform for children only
        self.layers.append(layer)
        return ind

    def text(self, nm, s, size, color, p, font="MIQ-Regular", j=0, parent=None, o=100):
        doc = {"s": size, "f": font, "t": s, "j": j, "tr": 0, "lh": round(size * 1.2, 2),
               "ls": 0, "fc": rgb(color)}
        t = {"d": {"k": [{"s": doc, "t": 0}]}, "p": {}, "m": {"g": 1, "a": st([0, 0])}, "a": []}
        return self.add(nm, ks=transform(p=p, o=o), text=t, parent=parent)

    def lottie(self):
        return {
            "v": "5.12.2", "fr": FPS, "ip": 0, "op": self.op, "w": self.w, "h": self.h,
            "nm": self.name, "ddd": 0, "assets": [],
            "fonts": {"list": [{"fName": k, "fFamily": f, "fStyle": s, "fWeight": str(wt), "ascent": 75}
                               for k, (f, s, wt) in FONTS.items()]},
            "markers": [{"tm": self.poster, "cm": "poster", "dr": 0}],
            "layers": list(reversed(self.layers)),
        }


# --------------------------------------------------------------------------
# Shared drawings
# --------------------------------------------------------------------------

def backdrop(sc, th):
    sc.add("backdrop", shapes=[group(rect(sc.w - 2, sc.h - 2, 14, (sc.w / 2, sc.h / 2)),
                                     stroke(th["border"], 1), fill(th["panel"]))])


def brain_coronal(k=1.0):
    g = GREYS
    return [
        group(ellipse(86, 100), fill(g["csf"]), stroke(g["scalp"], 3), s=(100 * k, 100 * k)),
        group(ellipse(76, 88, (0, 2)), fill(g["gm"]), s=(100 * k, 100 * k)),
        group(ellipse(54, 58, (0, -2)), fill(g["wm"]), s=(100 * k, 100 * k)),
        group(path([(-1, -30), (1, -30), (1, -8), (-1, -8)]), fill(g["dark"]), s=(100 * k, 100 * k)),
        group(ellipse(9, 16, (-6, -4)), fill(g["dark"]), r=-25, s=(100 * k, 100 * k)),
        group(ellipse(9, 16, (6, -4)), fill(g["dark"]), r=25, s=(100 * k, 100 * k)),
    ]


def brain_sagittal(k=1.0):
    g = GREYS
    s = (100 * k, 100 * k)
    cc = path([(-24, -2), (0, -16), (24, 0)], closed=False,
              tin=[(0, 0), (-14, 0), (0, -10)], tout=[(0, -10), (14, 0), (0, 0)])
    stem = path([(4, 8), (12, 8), (16, 40), (8, 40)])
    return [
        group(ellipse(116, 92, (0, 2)), fill(g["csf"]), stroke(g["scalp"], 3), s=s),
        group(ellipse(102, 74, (-2, -4)), fill(g["gm"]), s=s),
        group(ellipse(72, 46, (-4, -8)), fill(g["wm"]), s=s),
        group(ellipse(28, 20, (30, 24)), fill(g["cereb"]), stroke(g["gm"], 2), s=s),
        group(stem, fill(g["gm"]), s=s),
        group(cc, stroke(g["cc"], 5), s=s),
    ]


def brain_axial(k=1.0):
    g = GREYS
    s = (100 * k, 100 * k)
    return [
        group(ellipse(88, 108), fill(g["csf"]), stroke(g["scalp"], 3), s=s),
        group(ellipse(76, 96), fill(g["gm"]), s=s),
        group(ellipse(54, 72), fill(g["wm"]), s=s),
        group(path([(-1, -48), (1, -48), (1, -18), (-1, -18)]), fill(g["dark"]), s=s),
        group(path([(-1, 20), (1, 20), (1, 48), (-1, 48)]), fill(g["dark"]), s=s),
        group(ellipse(7, 30, (-7, 0)), fill(g["dark"]), r=-8, s=s),
        group(ellipse(7, 30, (7, 0)), fill(g["dark"]), r=8, s=s),
    ]


# --------------------------------------------------------------------------
# Scene 1: press Space on a file in Finder, the 2x2 preview opens.
# --------------------------------------------------------------------------

def scene_quicklook(th):
    sc = Scene("MIQ quick look", 720, 340, 210, poster=120)
    backdrop(sc, th)

    icon = (128, 132)
    # Selection highlight behind the icon (Finder-style).
    sc.add("selection", ks=transform(p=icon, o=kf((0, 0), (12, 0), (22, 100, "hold"), (186, 100), (198, 0))),
           shapes=[group(rect(100, 118, 10, (0, 8)), fill(th["accentSoft"]))])
    # Document icon with folded corner and a small slice on it.
    doc = path([(-28, -40), (14, -40), (28, -26), (28, 40), (-28, 40)])
    fold = path([(14, -40), (14, -26), (28, -26)])
    sc.add("file", ks=transform(p=icon), shapes=[
        group(rect(10, 10, 2, (0, 18)), fill(GREYS["wm"])),
        group(ellipse(30, 36, (0, 14)), fill(GREYS["gm"])),
        group(rect(40, 46, 4, (0, 14)), fill("#000000")),
        group(fold, stroke(th["paperEdge"], 1.5), fill(th["chrome"])),
        group(doc, stroke(th["paperEdge"], 1.5), fill(th["paper"])),
    ])
    sc.text("file name", "sub-01_T1w.nii.gz", 12, th["fg"], (icon[0], icon[1] + 64), j=2)

    # Space bar keycap: pressed at frames 28-40.
    press = kf((0, [100, 100]), (28, [100, 100], "in"), (33, [94, 90], "out"), (42, [100, 100]))
    key = sc.add("space key", ks=transform(p=(128, 266), s=press), shapes=[
        group(rect(120, 34, 8, (0, 0)), stroke(th["keyEdge"], 1.5), fill(th["key"])),
        group(rect(120, 34, 8, (0, 3)), fill(th["keyEdge"])),
    ])
    sc.add("space key lit", ks=transform(o=kf((0, 0), (29, 0, "out"), (34, 100), (60, 0))), parent=key,
           shapes=[group(rect(120, 34, 8, (0, 0)), fill(th["accent"]))])
    sc.text("space label", "space", 13, th["fg"], (0, 5), j=2, parent=key, font="MIQ-Semibold")
    sc.text("space label lit", "space", 13, "#ffffff", (0, 5), j=2, parent=key, font="MIQ-Semibold",
            o=kf((0, 0), (29, 0, "out"), (34, 100), (60, 0)))

    # The Quick Look window: a null drives the zoom from the icon.
    centre = (470, 170)
    win = sc.add("window", ks=transform(
        p=kf((0, list(icon), "hold"), (36, list(icon), "pop"), (60, list(centre), "hold"),
             (184, list(centre), "in"), (200, list(icon), "hold"), (209, list(icon))),
        s=kf((0, [12, 12], "hold"), (36, [12, 12], "pop"), (60, [100, 100], "hold"),
             (184, [100, 100], "in"), (200, [12, 12], "hold"), (209, [12, 12]))))
    # Lottie parents pass on transforms but not opacity, so every child layer
    # carries the window's fade (or a later fade-in) itself.
    win_o = kf((0, 0, "hold"), (36, 0, "out"), (46, 100, "hold"), (186, 100), (198, 0, "hold"), (209, 0))
    fade = lambda t0: kf((0, 0, "hold"), (t0, 0, "out"), (t0 + 12, 100, "hold"), (186, 100), (198, 0, "hold"),
                         (209, 0))
    W, H = 400, 290
    sc.add("window body", parent=win, ks=transform(o=win_o), shapes=[  # first group paints on top
        group(ellipse(10, 10, (-W / 2 + 16, -H / 2 + 15)), fill("#ff5f57")),
        group(ellipse(10, 10, (-W / 2 + 32, -H / 2 + 15)), fill("#febc2e")),
        group(rect(W - 12, H - 40, 8, (0, 14)), fill(th["tile"])),
        group(rect(W, H, 12, (0, 0)), fill(th["chrome"]), stroke(th["border"], 1)),
    ])
    sc.text("window title", "sub-01_T1w.nii.gz", 11, th["chromeFg"], (-W / 2 + 46, -H / 2 + 19),
            font="MIQ-Semibold", parent=win, o=win_o)

    # 2x2 grid: coronal | sagittal / axial | metadata (MIQ's layout).
    tiles = {"cor": (-97, -48), "sag": (97, -48), "ax": (-97, 76)}
    for nm, drawing in (("cor", brain_coronal(0.95)), ("sag", brain_sagittal(0.9)), ("ax", brain_axial(0.9))):
        sc.add("slice " + nm, ks=transform(p=tiles[nm], o=fade(52)), shapes=list(reversed(drawing)), parent=win)
    for (x, y, letter) in ((-97, -112, "S"), (-187, -48, "L"), (-7, -48, "R"),
                           (97, -112, "S"), (12, -48, "A"), (186, -48, "P"),
                           (-187, 76, "L"), (-7, 76, "R")):
        sc.text("label " + letter, letter, 9, th["red"], (x, y + 3), j=2, font="MIQ-Semibold", parent=win,
                o=fade(56))
    rows = [("Format", "NIfTI-1"), ("Dimensions", "256 × 256 × 176"), ("Spacing", "1.00 mm iso"),
            ("Orientation", "RAS"), ("Datatype", "int16"), ("Volumes", "1")]
    for i, (k, v) in enumerate(rows):
        y = 30 + i * 17
        sc.text("key " + k, k, 10.5, GREYS["label"], (14, y), parent=win, o=fade(60 + i * 3))
        sc.text("val " + k, v, 10.5, GREYS["white"], (86, y), parent=win, o=fade(60 + i * 3))

    # Crosshair lines in the coronal tile, drawn after the preview settles.
    sc.add("crosshair", parent=win, ks=transform(o=fade(72)), shapes=[
        group(rect(1, 112, 0, (-97, -48)), fill(th["red"], 85)),
        group(rect(176, 1, 0, (-97, -48)), fill(th["red"], 85)),
        group(rect(1, 112, 0, (97, -48)), fill(th["red"], 85)),
        group(rect(176, 1, 0, (97, -48)), fill(th["red"], 85)),
        group(rect(1, 112, 0, (-97, 76)), fill(th["red"], 85)),
        group(rect(176, 1, 0, (-97, 76)), fill(th["red"], 85)),
    ])
    return sc


# --------------------------------------------------------------------------
# Scene 2: a crosshair sweeping through coronal/sagittal/axial slices. The
# head is modelled as nested ellipsoids, so each view's cross-section grows and
# shrinks exactly as the slice position moves.
# --------------------------------------------------------------------------

ELLIPSOIDS = [  # name, centre (x=R, y=A, z=S), radii, fill, stroke
    ("scalp", (0, 0, 0), (62, 78, 64), GREYS["csf"], GREYS["scalp"]),
    ("gm", (0, -2, 4), (54, 70, 54), GREYS["gm"], None),
    ("wm", (0, -2, 6), (40, 54, 38), GREYS["wm"], None),
    ("vent L", (-8, 2, 10), (5, 24, 11), GREYS["dark"], None),
    ("vent R", (8, 2, 10), (5, 24, 11), GREYS["dark"], None),
]
VIEWS = {  # slice axis, screen-x (axis, sign), screen-y (axis, sign), edge labels L/R/T/B
    "Coronal": (1, (0, 1), (2, -1), ("L", "R", "S", "I")),
    "Sagittal": (0, (1, -1), (2, -1), ("A", "P", "S", "I")),
    "Axial": (2, (0, 1), (1, -1), ("L", "R", "A", "P")),
}


def sweep(u):
    """Crosshair position (x, y, z) in mm at loop phase u in [0, 1)."""
    a = 2 * math.pi * u
    return (30 * math.sin(a), 40 * math.sin(2 * a), 14 + 22 * math.sin(a + 1.1) * math.cos(a))


def scene_crosshair(th):
    frames = 300
    sc = Scene("MIQ crosshair", 720, 300, frames, poster=0)
    backdrop(sc, th)
    T, k = 200, 1.25  # tile size, px per mm
    step = 5
    times = list(range(0, frames + 1, step))
    for vi, (vname, (axis, (sxa, sxs), (sya, sys_), labels)) in enumerate(VIEWS.items()):
        cx, cy = 130 + vi * 230, 136
        tile = sc.add(vname + " tile", ks=transform(p=(cx, cy)),
                      shapes=[group(rect(T, T, 8), fill(th["tile"]))])
        for (nm, c, r, fc, sc_) in ELLIPSOIDS:
            scales, shown = [], []
            for t in times:
                pos = sweep((t % frames) / frames)
                d = (pos[axis] - c[axis]) / r[axis]
                f = math.sqrt(max(0.0, 1 - d * d)) * 100
                scales.append((t, [round(f, 2), round(f, 2)], "linear"))
                shown.append(f > 0)
            # A zero-size ellipse still rasterises as a dot, so also hide it
            # (hold keyframes) while the slice misses this ellipsoid.
            vis = [(times[i], 100 if shown[i] or (i and shown[i - 1]) or (i + 1 < len(times) and shown[i + 1])
                    else 0, "hold") for i in range(len(times))]
            vis = [k for i, k in enumerate(vis) if i == 0 or k[1] != vis[i - 1][1]] + [(frames, vis[-1][1])]
            opacity = kf(*vis) if len(vis) > 2 else vis[0][1]
            items = [ellipse(2 * r[sxa] * k, 2 * r[sya] * k)]
            if sc_:
                items.append(stroke(sc_, 2.5))
            items.append(fill(fc))
            sc.add(f"{vname} {nm}", parent=tile, shapes=[group(*items)],
                   ks=transform(p=(c[sxa] * sxs * k, c[sya] * sys_ * k), s=kf(*scales), o=opacity))
        # Crosshair: vertical line follows screen-x, horizontal follows screen-y.
        vx = [(t, [round(sweep((t % frames) / frames)[sxa] * sxs * k, 2), 0], "linear") for t in times]
        hy = [(t, [0, round(sweep((t % frames) / frames)[sya] * sys_ * k, 2)], "linear") for t in times]
        sc.add(vname + " v-line", parent=tile, ks=transform(p=kf(*vx)),
               shapes=[group(rect(1.2, T - 2, 0), fill(th["red"], 90))])
        sc.add(vname + " h-line", parent=tile, ks=transform(p=kf(*hy)),
               shapes=[group(rect(T - 2, 1.2, 0), fill(th["red"], 90))])
        for (x, y, letter) in ((-T / 2 + 10, 4, labels[0]), (T / 2 - 10, 4, labels[1]),
                               (0, -T / 2 + 14, labels[2]), (0, T / 2 - 6, labels[3])):
            sc.text(f"{vname} {letter}", letter, 10, th["red"], (x, y), j=2, font="MIQ-Semibold", parent=tile)
        sc.text(vname + " name", vname, 12, th["soft"], (cx, cy + T / 2 + 22), j=2, font="MIQ-Semibold")
        if vname == "Axial":
            # A pointer drags the crosshair in the axial view.
            arrow = path([(0, 0), (0, 17), (4.5, 13), (7.5, 20), (10, 19), (7, 12), (12.5, 12)])
            sc.add("pointer", parent=tile, ks=transform(p=kf(*[(t, [vx[i][1][0], hy[i][1][1]], "linear")
                                                                for i, t in enumerate(times)])),
                   shapes=[group(arrow, stroke("#000000", 1.2), fill("#ffffff"))])
    return sc


# --------------------------------------------------------------------------
# Scene 3: a strip of supported formats sliding under a fixed highlight, with a
# small table below that switches to the highlighted format's details.
# --------------------------------------------------------------------------

# (strip label, chip extensions, table: extensions, table: notes)
FORMATS = [
    ("NIfTI-1 / 2", ".nii  .nii.gz", ".nii, .nii.gz",
     "Orientation from sform/qform, with a warning if they disagree"),
    ("FreeSurfer", ".mgh  .mgz", ".mgh, .mgz, .mgh.gz",
     "World position from c_ras; FreeSurfer label colours and names"),
    ("MRtrix", ".mif  .mih", ".mif, .mif.gz, .mih",
     "Any axis layout; .mih keeps the data in a second file"),
    ("NRRD", ".nrrd  .nhdr", ".nrrd, .nhdr",
     "Raw or gzip; no anatomical space means orientation \u201c?\u201d"),
    ("MetaImage", ".mha  .mhd", ".mha, .mhd",
     "ITK format, including zlib-compressed data"),
    ("DICOM", ".dcm", ".dcm, .dicom",
     "Uncompressed, single or multi-frame; patient tags never shown"),
    ("Zarr", ".ome.zarr", ".zarr, .ome.zarr, .nii.zarr",
     "OME-Zarr and NIfTI-Zarr, lowest-resolution level"),
]


def scene_formats(th):
    n, hold, move, fade = len(FORMATS), 54, 14, 6
    frames = n * (hold + move)
    sc = Scene("MIQ formats", 720, 250, frames, poster=0)
    backdrop(sc, th)
    pitch, cw, ch, sy = 150, 136, 70, 58
    # Hold on each chip, then slide one pitch; the strip repeats, so the last
    # position looks exactly like the first and the loop is seamless.
    seq = []
    for i in range(n):
        t0 = i * (hold + move)
        seq.append((t0, [360 - i * pitch, sy], "hold"))
        seq.append((t0 + hold, [360 - i * pitch, sy], "inout"))
    seq.append((frames, [360 - n * pitch, sy]))
    row = sc.add("row", ks=transform(p=kf(*seq)))
    for j in range(-3, n + 4):
        name, ext = FORMATS[j % n][:2]
        x = j * pitch
        sc.add(f"chip {j}", parent=row, shapes=[group(rect(cw, ch, 12, (x, 0)), stroke(th["border"], 1),
                                                      fill(th["chip"]))])
        sc.text(f"chip {j} name", name, 15, th["fg"], (x, -2), j=2, font="MIQ-Semibold", parent=row)
        sc.text(f"chip {j} ext", ext, 11, th["soft"], (x, 18), j=2, font="MIQ-Mono", parent=row)
    # Fixed highlight frame and soft edge fades.
    sc.add("highlight", shapes=[group(rect(cw + 8, ch + 8, 15, (360, sy)), stroke(th["accent"], 2.5))])
    sc.add("fade left", shapes=[group(rect(170, 112, 0, (86, sy)),
                                      gradient((2, 0), (170, 0), [(0, th["panel"], 1), (1, th["panel"], 0)]))])
    sc.add("fade right", shapes=[group(rect(170, 112, 0, (634, sy)),
                                       gradient((718, 0), (550, 0), [(0, th["panel"], 1), (1, th["panel"], 0)]))])

    # The table: three label/value rows; the values swap with the highlighted chip.
    tx, ty, tw, rh = 24, 124, 672, 36
    sc.add("table", shapes=[group(rect(tw, rh * 3, 10, (tx + tw / 2, ty + rh * 1.5)), stroke(th["border"], 1),
                                  fill(th["chip"]))])
    for r in (1, 2):
        sc.add(f"table rule {r}", shapes=[group(rect(tw - 2, 1, 0, (tx + tw / 2, ty + rh * r)), fill(th["border"]))])
    sc.add("table column rule", shapes=[group(rect(1, rh * 3 - 2, 0, (tx + 120, ty + rh * 1.5)), fill(th["border"]))])
    for r, label in enumerate(("Format", "Extensions", "Notes")):
        sc.text(f"label {label}", label, 13, th["soft"], (tx + 14, ty + rh * r + 23), font="MIQ-Semibold")

    def visibility(i):
        """Opacity keyframes: shown while chip i sits in the highlight."""
        t0 = i * (hold + move)
        if i == 0:
            return kf((0, 100, "hold"), (hold, 100), (hold + fade, 0, "hold"), (frames - fade, 0), (frames, 100))
        return kf((0, 0, "hold"), (t0 - fade, 0), (t0, 100, "hold"), (t0 + hold, 100),
                  (t0 + hold + fade, 0, "hold"), (frames, 0))

    for i, (name, _, exts, notes) in enumerate(FORMATS):
        o = visibility(i)
        vx = tx + 136
        sc.text(f"value {i} name", name, 13, th["fg"], (vx, ty + 23), font="MIQ-Semibold", o=o)
        sc.text(f"value {i} ext", exts, 12, th["fg"], (vx, ty + rh + 23), font="MIQ-Mono", o=o)
        sc.text(f"value {i} notes", notes, 13, th["fg"], (vx, ty + rh * 2 + 23), o=o)

    sc.add("frame", shapes=[group(rect(sc.w - 2, sc.h - 2, 14, (sc.w / 2, sc.h / 2)), stroke(th["border"], 1))])
    return sc


SCENES = {"quicklook": scene_quicklook, "crosshair": scene_crosshair, "formats": scene_formats}


# --------------------------------------------------------------------------
# Lottie -> animated SVG
# --------------------------------------------------------------------------

def _bezier_y(x, p1, p2):
    """y of a CSS-style cubic bezier (0,0)-(p1)-(p2)-(1,1) at x."""
    lo, hi = 0.0, 1.0
    for _ in range(40):
        t = (lo + hi) / 2
        bx = 3 * (1 - t) ** 2 * t * p1[0] + 3 * (1 - t) * t * t * p2[0] + t ** 3
        lo, hi = (t, hi) if bx < x else (lo, t)
    t = (lo + hi) / 2
    return 3 * (1 - t) ** 2 * t * p1[1] + 3 * (1 - t) * t * t * p2[1] + t ** 3


def value_at(p, t):
    """Evaluate a Lottie property at frame t (as a list)."""
    if not p.get("a"):
        k = p["k"]
        return k if isinstance(k, list) else [k]
    ks = p["k"]
    if t <= ks[0]["t"]:
        return ks[0]["s"]
    for a, b in zip(ks, ks[1:]):
        if a["t"] <= t < b["t"]:
            if a.get("h"):
                return a["s"]
            x = (t - a["t"]) / (b["t"] - a["t"])
            y = _bezier_y(x, (a["o"]["x"][0], a["o"]["y"][0]), (a["i"]["x"][0], a["i"]["y"][0]))
            return [sa + (sb - sa) * y for sa, sb in zip(a["s"], b["s"])]
    return ks[-1]["s"]


def hexcol(c):
    return "#%02x%02x%02x" % tuple(round(v * 255) for v in c[:3])


def num(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


class SvgWriter:
    def __init__(self, doc):
        self.doc = doc
        self.op = doc["op"]
        self.dur = doc["op"] / doc["fr"]
        self.poster = next((m["tm"] for m in doc.get("markers", []) if m.get("cm") == "poster"), 0)
        self.css = []
        self.defs = []
        self.n = 0
        self.fonts = {f["fName"]: f for f in doc["fonts"]["list"]}

    def _anim(self, prop, fmt):
        """CSS keyframes for an animated property; returns the class name."""
        self.n += 1
        name = f"k{self.n}"
        frames = []
        ks = prop["k"]
        if ks[0]["t"] > 0:
            frames.append(f"0%{{{fmt(ks[0]['s'])}}}")
        for i, k in enumerate(ks):
            pct = num(k["t"] / self.op * 100)
            if i < len(ks) - 1:
                if k.get("h"):
                    tf = "steps(1,end)"
                else:
                    tf = "cubic-bezier({},{},{},{})".format(*(num(v) for v in (
                        k["o"]["x"][0], k["o"]["y"][0], k["i"]["x"][0], k["i"]["y"][0])))
                frames.append(f"{pct}%{{{fmt(k['s'])};animation-timing-function:{tf}}}")
            else:
                frames.append(f"{pct}%{{{fmt(k['s'])}}}")
        if ks[-1]["t"] < self.op:
            frames.append(f"100%{{{fmt(ks[-1]['s'])}}}")
        self.css.append(f"@keyframes {name}{{{''.join(frames)}}}.{name}{{animation:{name} {num(self.dur)}s linear infinite}}")
        return name

    def _tgroups(self, ks):
        """Open/close tags for a layer's transform (translate, rotate, scale, anchor)."""
        opens = []
        parts = [
            ("p", lambda v: f"translate({num(v[0])}px,{num(v[1])}px)", lambda v: f"translate({num(v[0])} {num(v[1])})"),
            ("r", lambda v: f"rotate({num(v[0])}deg)", lambda v: f"rotate({num(v[0])})"),
            ("s", lambda v: f"scale({num(v[0] / 100)},{num(v[1] / 100)})",
             lambda v: f"scale({num(v[0] / 100)} {num(v[1] / 100)})"),
        ]
        for key, css, attr in parts:
            p = ks[key]
            v = value_at(p, self.poster)
            if p.get("a"):
                cls = self._anim(p, lambda s, css=css: "transform:" + css(s))
                opens.append(f'<g class="{cls}" transform="{attr(v)}">')
            elif (key == "p" and any(v)) or (key == "r" and v[0]) or (key == "s" and v != [100, 100]):
                opens.append(f'<g transform="{attr(v)}">')
        a = value_at(ks["a"], 0)
        if any(a):
            opens.append(f'<g transform="translate({num(-a[0])} {num(-a[1])})">')
        return "".join(opens), "</g>" * len(opens)

    def _opacity(self, ks):
        p = ks["o"]
        v = value_at(p, self.poster)[0] / 100
        if p.get("a"):
            cls = self._anim(p, lambda s: f"opacity:{num(s[0] / 100)}")
            return f'<g class="{cls}" opacity="{num(v)}">', "</g>"
        if v < 1:
            return f'<g opacity="{num(v)}">', "</g>"
        return "", ""

    def _paint(self, items):
        fill_attr, stroke_attr = 'fill="none"', ""
        for it in items:
            if it["ty"] == "fl":
                c, o = it["c"]["k"], it["o"]["k"] / 100
                fill_attr = f'fill="{hexcol(c)}"' + (f' fill-opacity="{num(o)}"' if o < 1 else "")
            elif it["ty"] == "gf":
                self.n += 1
                gid = f"g{self.n}"
                n = it["g"]["p"]
                raw = it["g"]["k"]["k"]
                stops = []
                for i in range(n):
                    off, r, g, b = raw[i * 4:i * 4 + 4]
                    alpha = raw[n * 4 + i * 2 + 1]
                    stops.append(f'<stop offset="{num(off)}" stop-color="{hexcol([r, g, b])}" stop-opacity="{num(alpha)}"/>')
                s, e = it["s"]["k"], it["e"]["k"]
                self.defs.append(f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" x1="{num(s[0])}" '
                                 f'y1="{num(s[1])}" x2="{num(e[0])}" y2="{num(e[1])}">{"".join(stops)}</linearGradient>')
                fill_attr = f'fill="url(#{gid})"'
            elif it["ty"] == "st":
                c, o, w = it["c"]["k"], it["o"]["k"] / 100, it["w"]["k"]
                stroke_attr = (f' stroke="{hexcol(c)}" stroke-width="{num(w)}" stroke-linecap="round" '
                               f'stroke-linejoin="round"' + (f' stroke-opacity="{num(o)}"' if o < 1 else ""))
        return fill_attr + stroke_attr

    def _geometry(self, it, paint):
        if it["ty"] == "rc":
            (cx, cy), (w, h), r = it["p"]["k"], it["s"]["k"], it["r"]["k"]
            rr = f' rx="{num(r)}"' if r else ""
            return f'<rect x="{num(cx - w / 2)}" y="{num(cy - h / 2)}" width="{num(w)}" height="{num(h)}"{rr} {paint}/>'
        if it["ty"] == "el":
            (cx, cy), (w, h) = it["p"]["k"], it["s"]["k"]
            return f'<ellipse cx="{num(cx)}" cy="{num(cy)}" rx="{num(w / 2)}" ry="{num(h / 2)}" {paint}/>'
        if it["ty"] == "sh":
            k = it["ks"]["k"]
            v, ti, to = k["v"], k["i"], k["o"]
            d = [f"M{num(v[0][0])} {num(v[0][1])}"]
            segs = list(range(1, len(v))) + ([0] if k["c"] else [])
            for j in segs:
                a = j - 1 if j else len(v) - 1
                c1 = (v[a][0] + to[a][0], v[a][1] + to[a][1])
                c2 = (v[j][0] + ti[j][0], v[j][1] + ti[j][1])
                if to[a] == [0, 0] and ti[j] == [0, 0]:
                    d.append(f"L{num(v[j][0])} {num(v[j][1])}")
                else:
                    d.append("C" + " ".join(num(q) for q in (*c1, *c2, v[j][0], v[j][1])))
            if k["c"]:
                d.append("Z")
            return f'<path d="{"".join(d)}" {paint}/>'
        return ""

    def _group(self, g):
        items = g["it"]
        tr = next(i for i in items if i["ty"] == "tr")
        paint = self._paint(items)
        body = "".join(self._geometry(i, paint) for i in items if i["ty"] in ("rc", "el", "sh"))
        p, s, r, o = tr["p"]["k"], tr["s"]["k"], tr["r"]["k"], tr["o"]["k"]
        t = []
        if any(p):
            t.append(f"translate({num(p[0])} {num(p[1])})")
        if r:
            t.append(f"rotate({num(r)})")
        if s != [100, 100]:
            t.append(f"scale({num(s[0] / 100)} {num(s[1] / 100)})")
        attrs = (f' transform="{" ".join(t)}"' if t else "") + (f' opacity="{num(o / 100)}"' if o < 100 else "")
        return f"<g{attrs}>{body}</g>" if attrs else body

    def _content(self, layer):
        if layer["ty"] == 4:
            return "".join(self._group(g) for g in reversed(layer["shapes"]))
        if layer["ty"] == 5:
            d = layer["t"]["d"]["k"][0]["s"]
            font = self.fonts[d["f"]]
            anchor = {0: "start", 1: "end", 2: "middle"}[d["j"]]
            return (f'<text font-family="{escape(font["fFamily"], {chr(34): "&quot;"})}" '
                    f'font-weight="{font["fWeight"]}" font-size="{num(d["s"])}" fill="{hexcol(d["fc"])}" '
                    f'text-anchor="{anchor}">{escape(d["t"])}</text>')
        return ""

    def render(self, title, desc):
        by_ind = {l["ind"]: l for l in self.doc["layers"]}
        body = []
        for layer in reversed(self.doc["layers"]):  # Lottie lists top layer first
            if layer["ty"] == 3:
                continue
            chain, cur = [], layer
            while "parent" in cur:
                cur = by_ind[cur["parent"]]
                chain.insert(0, cur)
            opens, closes = [], []
            for anc in chain:  # parents pass on their transform, not their opacity
                o, c = self._tgroups(anc["ks"])
                opens.append(o)
                closes.insert(0, c)
            oo, oc = self._opacity(layer["ks"])
            to, tc = self._tgroups(layer["ks"])
            body.append("".join(opens) + oo + to + self._content(layer) + tc + oc + "".join(closes))
        css = ("svg *{transform-box:view-box;transform-origin:0 0}"
               + "".join(self.css)
               + "@media (prefers-reduced-motion:reduce){svg *{animation:none!important}}")
        w, h = self.doc["w"], self.doc["h"]
        return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" '
                f'role="img" aria-labelledby="t d">'
                f'<title id="t">{escape(title)}</title><desc id="d">{escape(desc)}</desc>'
                f"<style>{css}</style>"
                + (f"<defs>{''.join(self.defs)}</defs>" if self.defs else "")
                + "".join(body) + "</svg>\n")


DESCRIPTIONS = {
    "quicklook": ("Press Space to preview",
                  "A NIfTI file is selected in Finder, the Space key is pressed, and a Quick Look window opens "
                  "with coronal, sagittal and axial slices and a metadata panel."),
    "crosshair": ("Linked crosshair",
                  "A red crosshair moves through coronal, sagittal and axial views of a stylised head; each view "
                  "shows the slice through the crosshair, so the cross-sections grow and shrink as it moves."),
    "formats": ("Supported formats",
                "Supported formats slide past a highlight: NIfTI, FreeSurfer MGH/MGZ, MRtrix, NRRD, MetaImage, "
                "DICOM and Zarr."),
}


def build():
    outputs = {}
    for name, make in SCENES.items():
        for theme, suffix in (("light", ""), ("dark", "_dark")):
            doc = make(THEMES[theme]).lottie()
            outputs[f"{name}{suffix}.json"] = json.dumps(doc, separators=(",", ":"), ensure_ascii=False) + "\n"
            title, desc = DESCRIPTIONS[name]
            outputs[f"{name}{suffix}.svg"] = SvgWriter(json.loads(outputs[f"{name}{suffix}.json"])).render(title, desc)
    return outputs


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="exit 1 if docs/lottie is out of date")
    args = ap.parse_args()
    outputs = build()
    stale = [n for n, text in outputs.items()
             if not (OUT / n).exists() or (OUT / n).read_text(encoding="utf-8") != text]
    if args.check:
        for n in stale:
            print(f"stale: docs/lottie/{n}")
        return 1 if stale else 0
    OUT.mkdir(parents=True, exist_ok=True)
    for n, text in outputs.items():
        (OUT / n).write_text(text, encoding="utf-8")
        print(f"docs/lottie/{n}  {len(text.encode()) / 1024:.1f} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
