"""
Kallskar xsgen: transcribe the MOX-1000 radial layout (NEA/NSC/R(2015)9, Figure 2.12, report page 32 = PDF page 34)
from a 400 dpi render, instead of by eye.

    pdftoppm -f 34 -l 34 -r 400 -png references/nsc-r2015-9.pdf references/figs/mox1000_layout_r400

Method
  1. Cells: every hexagon is a region enclosed by dark outline pixels. Regions are labelled (4-connectivity), and
     those with a hexagon-sized area are kept; their centroids are the assembly centres.
  2. Lattice: the pitch is the median nearest-neighbour distance; the centre is the cell nearest the centroid mean.
     Every centroid must sit within 10% of a pitch of its lattice point (script fails otherwise).
  3. Colours: each cell's median colour (white letters "P"/"S" excluded) is grouped, and each group is mapped to the
     nearest legend swatch. The group table is printed for audit: the map and legend colours are not identical in the
     PDF (e.g. the outer-core cells are lighter cyan than their swatch).
  4. Checks (script fails otherwise): the per-type counts printed in the legend (30/90/60/114/15/4/66, total 379).
     The layout's rotational symmetry is reported.

Output: tools/xsgen/results/mox1000_layout.json with axial coordinates (q, r; x = p(q + r/2), y = p·√3/2·r, y up).
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

REPO = Path(__file__).resolve().parents[2]
IMAGE = REPO / "references" / "figs" / "mox1000_layout_r400-34.png"
OUT = REPO / "tools" / "xsgen" / "results" / "mox1000_layout.json"

# legend swatch centres, read off the 100 dpi render (×4 for 400 dpi); the counts are printed next to them
LEGEND = {
    "inner": ((555, 234), 30),
    "middle": ((555, 270), 90),
    "outer": ((555, 306), 60),
    "reflector": ((555, 342), 114),
    "primary": ((555, 378), 15),
    "secondary": ((555, 414), 4),
    "shield": ((555, 450), 66),
}
FIGURE_BOX = (480, 640, 2120, 2260)  # x0, y0, x1, y1 at 400 dpi: the core map without the legend
DARK = 90  # outline pixels: every channel below this
WHITE = 250  # background and letters: every channel above this


def swatch_colour(img, x, y):
    patch = img[y - 20:y + 21, x - 20:x + 21].reshape(-1, 3)
    keep = ~((patch < DARK).all(axis=1) | (patch > WHITE).all(axis=1))
    return np.median(patch[keep], axis=0)


def ring_of(q, r):
    return max(abs(q), abs(r), abs(q + r))


def main():
    img = np.asarray(Image.open(IMAGE).convert("RGB")).astype(np.int32)
    legend = {name: swatch_colour(img, x * 4, y * 4) for name, ((x, y), _) in LEGEND.items()}
    print("legend colours:", {k: tuple(int(c) for c in v) for k, v in legend.items()})

    x0, y0, x1, y1 = FIGURE_BOX
    fig = img[y0:y1, x0:x1]
    # anti-aliased slanted outlines have lighter pixels that would let neighbouring cells merge: grow the outline mask by
    # one pixel so every cell is sealed (cells shrink by a pixel all round, which moves no centroid)
    dark = ndimage.binary_dilation((fig < DARK).all(axis=2), iterations=1)
    labels, n = ndimage.label(~dark)
    sizes = ndimage.sum_labels(np.ones_like(labels), labels, index=np.arange(1, n + 1))
    # the background region(s) touch the box edge; drop them and anything tiny (letter counters, specks)
    edge = set(np.unique(np.concatenate([labels[0], labels[-1], labels[:, 0], labels[:, -1]]))) - {0}
    typical = np.median([s for i, s in enumerate(sizes, 1) if i not in edge and s > 1000])
    cells = []
    for i, s in enumerate(sizes, 1):
        if i in edge or not (0.6 * typical < s < 1.4 * typical):
            continue
        mask = labels == i
        ys, xs = np.nonzero(mask)
        colours = fig[ys, xs]
        coloured = colours[~(colours > WHITE).all(axis=1)]
        cells.append((xs.mean() + x0, ys.mean() + y0, np.median(coloured, axis=0), int(s)))
    print(f"{len(cells)} cell regions (typical area {typical:.0f} px²)")

    pts = np.array([(c[0], c[1]) for c in cells])
    d = np.sqrt(((pts[:, None, :] - pts[None, :, :]) ** 2).sum(axis=2))
    np.fill_diagonal(d, np.inf)
    pitch = float(np.median(d.min(axis=1)))
    mean = pts.mean(axis=0)
    centre = pts[np.argmin(((pts - mean) ** 2).sum(axis=1))]
    h = pitch * math.sqrt(3) / 2
    print(f"pitch {pitch:.2f} px, centre cell at ({centre[0]:.1f}, {centre[1]:.1f}), centroid mean ({mean[0]:.1f}, {mean[1]:.1f})")

    worst = 0.0
    for x, y, _, _ in cells:
        r = round(-(y - centre[1]) / h)
        q = round((x - centre[0]) / pitch - r / 2)
        ex, ey = centre[0] + pitch * (q + r / 2), centre[1] - h * r
        err = math.hypot(x - ex, y - ey) / pitch
        worst = max(worst, err)
        if err > 0.10:
            sys.exit(f"cell at ({x:.0f}, {y:.0f}) is {err:.2f} pitch from lattice point ({q}, {r})")
    print(f"all {len(cells)} sealed cells sit on the lattice (worst offset {worst:.3f} pitch)")

    # the regions only fix the lattice (some neighbouring cells share a faint outline and merge); the colour is sampled
    # at every lattice point from a disc well inside the hexagon, without outline or white letter pixels
    full_dark = (img < DARK).all(axis=2)
    full_white = (img > WHITE).all(axis=2)
    yy, xx = np.mgrid[-40:41, -40:41]
    disc = (xx * xx + yy * yy) <= (0.30 * pitch) ** 2
    placed = {}
    for q in range(-13, 14):
        for r in range(-13, 14):
            if ring_of(q, r) > 13:
                continue
            cx, cy = int(round(centre[0] + pitch * (q + r / 2))), int(round(centre[1] - h * r))
            if not (x0 + 40 <= cx <= x1 - 40 and y0 + 40 <= cy <= y1 - 40):
                continue  # outside the map (the legend swatches sit on the far right)
            sl =(slice(cy - 40, cy + 41), slice(cx - 40, cx + 41))
            keep = disc & ~full_dark[sl] & ~full_white[sl]
            if keep.sum() < 0.3 * disc.sum():
                continue  # background
            placed[(q, r)] = np.median(img[sl][keep], axis=0)

    # group colours, then map groups to the legend
    groups = []
    for col in placed.values():
        for g in groups:
            if np.linalg.norm(g["colour"] - col) < 12:
                g["n"] += 1
                break
        else:
            groups.append({"colour": col, "n": 1})
    names = list(legend)
    print("colour groups in the map:")
    for g in groups:
        dists = {k: float(np.linalg.norm(g["colour"] - legend[k])) for k in names}
        g["name"] = min(dists, key=dists.get)
        ordered = sorted(dists.values())
        print(f"  {tuple(int(c) for c in g['colour'])} ×{g['n']} → {g['name']} (distance {ordered[0]:.0f}, next {ordered[1]:.0f})")
        if ordered[1] < 1.5 * ordered[0]:
            sys.exit("colour group is ambiguous between two legend entries")
    if len({g["name"] for g in groups}) != len(groups):
        sys.exit("two colour groups map to the same legend entry")

    layout = {}
    for key, col in placed.items():
        g = min(groups, key=lambda g: np.linalg.norm(g["colour"] - col))
        layout[key] = g["name"]
    counts = {k: sum(1 for v in layout.values() if v == k) for k in names}
    print("counts:", counts, "total", len(layout))
    for k, (_, expect) in LEGEND.items():
        if counts[k] != expect:
            sys.exit(f"count mismatch for {k}: got {counts[k]}, legend says {expect}")

    def rotate(q, r, k):
        for _ in range(k):
            q, r = -r, q + r  # 60° anticlockwise
        return q, r

    sym = [k for k in range(1, 6) if all(layout.get(rotate(q, r, k)) == v for (q, r), v in layout.items())]
    mirror = all(layout.get((q + r, -r)) == v for (q, r), v in layout.items())  # reflection in the x axis
    print("rotational symmetry (multiples of 60°):", sym, "| mirror in x:", mirror)
    maxring = max(ring_of(q, r) for q, r in layout)
    per_ring = {}
    for (q, r), v in layout.items():
        per_ring.setdefault(ring_of(q, r), {}).setdefault(v, 0)
        per_ring[ring_of(q, r)][v] += 1

    letters = {"inner": "I", "middle": "M", "outer": "O", "reflector": "R", "primary": "P", "secondary": "S", "shield": "H"}
    rows = []
    for r in range(maxring, -maxring - 1, -1):
        line = " " * abs(r)
        for q in range(-maxring, maxring + 1):
            if ring_of(q, r) <= maxring:
                line += letters.get(layout.get((q, r)), ".") + " "
        rows.append(line.rstrip())
    print("\n".join(rows))

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({
        "source": "NEA/NSC/R(2015)9 Figure 2.12 (report p.32), rendered at 400 dpi; tools/xsgen/mox1000_layout.py",
        "convention": "axial (q, r); x = pitch*(q + r/2), y = pitch*sqrt(3)/2*r, y up; hexagons point-up (OpenMC orientation 'x')",
        "counts": counts,
        "rotationalSymmetry60": sym,
        "mirrorX": mirror,
        "maxRing": maxring,
        "perRing": {str(k): per_ring[k] for k in sorted(per_ring)},
        "cells": [[q, r, v] for (q, r), v in sorted(layout.items())],
        "textMap": rows,
    }, indent=1))
    print("wrote", OUT)


if __name__ == "__main__":
    main()
