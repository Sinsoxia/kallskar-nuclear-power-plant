"""
Kallskar: derive rod-set placement within the hexagonal rings (docs/DECISIONS.md D-010).

Spec §2.2 fixes:
  * which ring holds each rod set and how many rods it has,
  * "space each rod set evenly so it is 3-fold symmetric",
  * "offset bank B by 30° from bank A so they don't shadow each other",
  * regulating rods at 0°, 120°, 240°.
It leaves the angles of the secondary shutdown rods (rings 4 and 7) and shim bank C (ring 8) open.

Rule used for the open sets (the spec's own anti-shadowing principle, made explicit):
  place the remaining sets inside-out; for each, choose the evenly spaced, rotation-symmetric placement that
  maximises the minimum angular separation from rod sets already placed in the adjacent rings; break ties by the
  smallest starting angle.

Geometry: ring n has 6n positions. Corners sit at angles 60°k at distance n pitches; position j lies on edge
e = j // n, step s = j % n, linearly between corner e and corner e+1. Angles are measured from corner 0.

Run:  python tools/derive/rod_layout.py        (stdlib only; exits non-zero if Config disagrees)
"""
import math
import sys

TOL_DEG = 1e-6

# Ring and count for every rod set (spec §2.2)
SETS = [
    ("RR", 2, 3),
    ("SM_A", 3, 6),
    ("SSR", 4, 3),
    ("SM_B", 6, 6),
    ("SSR", 7, 6),
    ("SM_C", 8, 6),
]

# What src/shared/Config/Core.luau declares (must match the derivation)
CONFIG = {
    ("RR", 2): [0, 120, 240],
    ("SM_A", 3): [0, 60, 120, 180, 240, 300],
    ("SSR", 4): [30, 150, 270],
    ("SM_B", 6): [30, 90, 150, 210, 270, 330],
    ("SSR", 7): [0, 60, 120, 180, 240, 300],
    ("SM_C", 8): [30, 90, 150, 210, 270, 330],
}


def position_xy(n, j):
    if n == 0:
        return (0.0, 0.0)
    e, s = divmod(j, n)
    a0, a1 = math.radians(60 * e), math.radians(60 * (e + 1))
    c0 = (n * math.cos(a0), n * math.sin(a0))
    c1 = (n * math.cos(a1), n * math.sin(a1))
    f = s / n
    return (c0[0] + f * (c1[0] - c0[0]), c0[1] + f * (c1[1] - c0[1]))


def angle(n, j):
    x, y = position_xy(n, j)
    return math.degrees(math.atan2(y, x)) % 360.0


def ang_dist(a, b):
    d = abs(a - b) % 360.0
    return min(d, 360.0 - d)


def placements(n, k):
    """Evenly spaced (in position index) placements of k rods in ring n; these are 360/k-rotation symmetric."""
    step = 6 * n // k
    return [[(j0 + m * step) for m in range(k)] for j0 in range(step)]


def angles_of(n, js):
    return sorted(round(angle(n, j), 9) for j in js)


def main():
    placed = {}  # (set, ring) -> list of angles

    # 1. Regulating rods: spec gives the angles directly. Confirm they land exactly on positions.
    rr = next(p for p in placements(2, 3) if all(ang_dist(a, b) < TOL_DEG for a, b in zip(angles_of(2, p), [0, 120, 240])))
    placed[("RR", 2)] = angles_of(2, rr)

    # 2. Banks A and B: B must sit exactly 30° from A. Enumerate every A and B placement and keep exact matches.
    matches = []
    for pa in placements(3, 6):
        aa = angles_of(3, pa)
        for pb in placements(6, 6):
            ab = angles_of(6, pb)
            offset = (ab[0] - aa[0]) % 60.0
            if abs(offset - 30.0) < TOL_DEG:
                matches.append((aa, ab))
    if len(matches) != 1:
        print(f"expected exactly one A/B placement with an exact 30° offset, found {len(matches)}")
        return 1
    placed[("SM_A", 3)], placed[("SM_B", 6)] = matches[0]
    print(f"A/B: the only exact 30° offset puts A at {placed[('SM_A', 3)][0]:.1f}° (corners) and B at {placed[('SM_B', 6)][0]:.1f}°")

    # 3. Open sets, inside-out, maximising separation from already-placed rods in adjacent rings.
    for name, ring, count in [s for s in SETS if (s[0], s[1]) not in placed]:
        neighbours = [a for (nm, r), angs in placed.items() if abs(r - ring) == 1 for a in angs]
        best, best_score = None, -1.0
        for p in placements(ring, count):
            angs = angles_of(ring, p)
            score = min((ang_dist(a, b) for a in angs for b in neighbours), default=180.0)
            if score > best_score + TOL_DEG or (abs(score - best_score) <= TOL_DEG and angs[0] < best[0] - TOL_DEG):
                best, best_score = angs, score
        placed[(name, ring)] = best
        print(f"{name} ring {ring}: first angle {best[0]:.3f}°, min separation from adjacent-ring rods {best_score:.3f}°")

    # 4. Compare with Config
    bad = 0
    for key, want in CONFIG.items():
        got = placed[key]
        ok = len(got) == len(want) and all(ang_dist(a, b) < TOL_DEG for a, b in zip(got, sorted(want)))
        print(f"{'OK ' if ok else 'BAD'} {key[0]:<5} ring {key[1]}: derived {[round(a, 3) for a in got]}  config {want}")
        bad += 0 if ok else 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
