"""
Decay heat as a state model: §3.6's formula turned into exponential groups that follow any power history.

§3.6 gives P/P0 = 0.066 (t^-0.2 - (t + T_op)^-0.2), t and T_op in seconds, and a table for T_op = 160 EFPD. That is
the answer for one history only: constant P0 for T_op, then shutdown. The simulator runs arbitrary histories (load
follow, a trip at 30 % after a week at 80 %, a restart the next day), so the formula has to become a state that is
driven by the power. It already is one in disguise: the formula is exactly the superposition of the kernel

    g(tau) = 0.066 x 0.2 x tau^-1.2         (decay power per unit power, per second of operation, tau after it)

since  integral from t to t + T_op of g = 0.066 (t^-0.2 - (t + T_op)^-0.2).  A sum of exponentials
g(tau) ~ sum E_i lambda_i exp(-lambda_i tau) turns that convolution into N first-order states,

    dH_i/dt = lambda_i (E_i P - H_i),       decay power = sum H_i,

and after constant P0 for T then shutdown  H(t)/P0 = sum E_i (1 - exp(-lambda_i T)) exp(-lambda_i t).

This script fits the E_i >= 0 on a fixed log-spaced lambda grid by non-negative least squares (Lawson-Hanson,
implemented here) on RELATIVE error over t in [1 s, 7 d], for the 160 EFPD history and a set of other histories so
that the kernel, not just one curve, is what gets fitted. It then checks the fit against the §3.6 table at the
table's printed precision, against the formula for histories it was and was not trained on, checks that the model
is stable at the 0.1 s tick, and uses the formula to test §4.5's coping-time statement.

The delayed-neutron fission tail is not here: §3.6 says it comes out of the kinetics model and must not be added.

Sources, all in this repository unless named:
  §3.6 formula and table, §4.1 masses and heat capacity, §4.3 pool temperatures, §4.5 coping time, §2.3 cycle,
  §14.1 fast loop 10 Hz, §0.2 x10 clock, Appendix A sodium c_p     KALLSKAR_ALL_IN_ONE.txt
  steel c_p for comparison only    P. Pichler, B. J. Simonds, J. W. Sowards, G. Pottlacher, "Measurements of
                                   thermophysical properties of solid and liquid NIST SRM 316L stainless steel",
                                   J. Mater. Sci. (2020), doi:10.1007/s10853-019-04261-6, Table 7 (DSC c_p)
Pure standard library (no numpy/scipy).
Run: PYTHONIOENCODING=utf-8 python tools/derive/decay_heat.py > tools/derive/decay_heat.out.txt
"""
import math
import sys

sys.stdout.reconfigure(newline="\n")   # LF even when redirected on Windows (.gitattributes: eol=lf)

EPS = sys.float_info.epsilon           # 2^-52
U = EPS / 2.0                          # unit roundoff, 2^-53

# ---------------------------------------------------------------- spec
COEF, EXP = 0.066, 0.2                 # §3.6: P/P0 = 0.066 (t^-0.2 - (t + T_op)^-0.2)
DAY = 86400.0                          # 1 EFPD = 86,400 s at full power
EFPD = DAY
T_REF = 160 * EFPD                     # §3.6: the table is for T_op = 160 EFPD (§2.3: one cycle)
P0_MW = 2380.0                         # §1.1 / §3.6: % of 2,380 MWt
TABLE_T = [1, 10, 60, 600, 1800, 3600, 14400, 86400, 259200, 604800]
TABLE_LABEL = ["1 s", "10 s", "1 min", "10 min", "30 min", "1 h", "4 h", "1 d", "3 d", "7 d"]
TABLE_PCT = [6.35, 3.92, 2.66, 1.59, 1.23, 1.04, 0.73, 0.43, 0.30, 0.22]
TABLE_MW = [151, 93, 63, 38, 29, 25, 17, 10, 7, 5]
PCT_HALF_UNIT = 0.005                  # the % column is printed to 0.01: half a unit in the last place
MW_HALF_UNIT = 0.5                     # the MW column is printed to 1 MW
T_MIN, T_MAX = 1.0, 7 * DAY            # the table's span, which is the fit's span

# Relative tolerance for "indistinguishable from the formula": the finest relative resolution anywhere in the table,
# half a unit of its most precise entry (6.35 % at 1 s): 0.005 / 6.35 = 7.87e-4. An error below this cannot be seen
# at any printed entry of the table; every other entry resolves less (0.005 / 0.22 = 2.3 % at 7 d).
REL_TOL = PCT_HALF_UNIT / max(TABLE_PCT)

# Histories. §2.3: a cycle is 160 EFPD and a quarter of the core is replaced per outage, so no fuel has seen more than
# 4 x 160 = 640 EFPD of operation; that is the longest history the groups need to carry. The fit uses 160 EFPD
# (primary) plus histories spread from an hour to that limit; the check adds histories the fit never saw.
T_LONGEST = 4 * 160 * EFPD
YEAR = 365.25 * DAY
FIT_OTHER = [("1 h", 3600.0), ("1 d", DAY), ("30 d", 30 * DAY), ("1 yr", YEAR), ("640 EFPD", T_LONGEST)]
UNSEEN = [("10 s", 10.0), ("1 min", 60.0), ("10 min", 600.0), ("4 h", 4 * 3600.0), ("7 d", 7 * DAY),
          ("90 d", 90 * DAY), ("480 EFPD", 480 * EFPD)]
# "Primarily": the reference history carries as much of the least-squares objective as all others together, so its
# row weight is sqrt(K) against 1 for each of the K others (residuals enter squared).
W_REF = math.sqrt(len(FIT_OTHER))

# Simulator clocks: §14.1 fast loop 10 Hz; §0.2 allows x10 in Modes 3-5, i.e. 1 s of plant time per tick.
DT_TICK = 0.1
DT_ACCEL = 1.0


def formula(t, T):
    """§3.6, P/P0. Written as t^-a (1 - (1 + T/t)^-a) so that short histories (T << t) lose no digits."""
    return COEF * t ** -EXP * -math.expm1(-EXP * math.log1p(T / t))


def logspace(a, b, n):
    la, lb = math.log(a), math.log(b)
    return [math.exp(la + (lb - la) * k / (n - 1)) for k in range(n)]


def saturation(lam, T):
    return -math.expm1(-lam * T)          # 1 - exp(-lambda T), exact for small lambda T


def model(E, lam, t, T):
    """Groups after constant P0 for T, then shutdown, at t after it: sum E (1 - e^-lT) e^-lt."""
    return sum(e * saturation(l, T) * math.exp(-l * t) for e, l in zip(E, lam))


# ---------------------------------------------------------------- non-negative least squares
def lstsq(cols, b):
    """Least squares by Householder QR. cols: the columns of A (each a list of length m)."""
    m, n = len(b), len(cols)
    R = [c[:] for c in cols]
    y = b[:]
    for k in range(n):
        v = R[k]
        norm = math.sqrt(sum(v[i] * v[i] for i in range(k, m)))
        alpha = -norm if v[k] >= 0.0 else norm
        u = [0.0] * m
        u[k] = v[k] - alpha
        for i in range(k + 1, m):
            u[i] = v[i]
        uu = sum(u[i] * u[i] for i in range(k, m))
        if uu == 0.0:
            continue
        for j in range(k, n):
            c = R[j]
            s = 2.0 * sum(u[i] * c[i] for i in range(k, m)) / uu
            for i in range(k, m):
                c[i] -= s * u[i]
        s = 2.0 * sum(u[i] * y[i] for i in range(k, m)) / uu
        for i in range(k, m):
            y[i] -= s * u[i]
    x = [0.0] * n
    for k in range(n - 1, -1, -1):
        x[k] = (y[k] - sum(R[j][k] * x[j] for j in range(k + 1, n))) / R[k][k]
    return x


def nnls(cols, b):
    """
    Lawson & Hanson (1974), Solving Least Squares Problems, ch. 23, algorithm NNLS: min |Ax - b| subject to x >= 0.
    Returns x and the gradient w = A^T (b - Ax), whose sign pattern is the optimality (KKT) certificate.
    The tolerance is the one SciPy's port uses, 10 eps |A|_1 max(m, n): below it a gradient is roundoff.
    """
    n, m = len(cols), len(b)

    def gradient(x):
        r = b[:]
        for j in range(n):
            if x[j] != 0.0:
                for i in range(m):
                    r[i] -= x[j] * cols[j][i]
        return [sum(cols[j][i] * r[i] for i in range(m)) for j in range(n)]

    tol = 10.0 * EPS * max(sum(abs(v) for v in c) for c in cols) * max(m, n)
    x, passive = [0.0] * n, []
    for _ in range(3 * n):
        w = gradient(x)
        active = [j for j in range(n) if j not in passive]
        if not active or max(w[j] for j in active) <= tol:
            return x, w, tol
        passive.append(max(active, key=lambda j: w[j]))
        while True:
            z = lstsq([cols[j] for j in passive], b)
            if all(v > 0.0 for v in z):
                x = [0.0] * n
                for j, v in zip(passive, z):
                    x[j] = v
                break
            # step back to the boundary and drop the variables that reach it
            a = min(x[j] / (x[j] - v) for j, v in zip(passive, z) if v <= 0.0)
            for j, v in zip(passive, z):
                x[j] += a * (v - x[j])
            passive = [j for j in passive if x[j] > tol]
            x = [x[j] if j in passive else 0.0 for j in range(n)]
    raise RuntimeError("NNLS did not converge in 3n outer iterations")


def fit(lam, histories, ts):
    """Rows: (model / formula - 1) at each t of each (weight, T). Columns scaled to unit norm; x >= 0 is unaffected."""
    cols = [[] for _ in lam]
    b = []
    for weight, T in histories:
        for t in ts:
            f = formula(t, T)
            for j, l in enumerate(lam):
                cols[j].append(weight * saturation(l, T) * math.exp(-l * t) / f)
            b.append(weight)
    scale = [math.sqrt(sum(v * v for v in c)) for c in cols]
    x, w, tol = nnls([[v / s for v in c] for c, s in zip(cols, scale)], b)
    return [v / s for v, s in zip(x, scale)], x, w, tol


def max_rel(E, lam, T, ts):
    return max(abs(model(E, lam, t, T) / formula(t, T) - 1.0) for t in ts)


checks = []


def check(label, ok):
    checks.append(ok)
    print(f"  [{'ok' if ok else 'FAIL'}] {label}")


def dur(s):
    for unit, size in (("d", DAY), ("h", 3600.0), ("min", 60.0)):
        if s >= size:
            return f"{s / size:.3g} {unit}"
    return f"{s:.3g} s"


# fit rows: 20 per decade; check rows: 100 per decade, fine enough to see the ripple between groups (several points
# per group spacing) and between fit rows.
DECADES = math.log10(T_MAX / T_MIN)
TS_FIT = logspace(T_MIN, T_MAX, math.ceil(20 * DECADES) + 1)
TS_CHECK = logspace(T_MIN, T_MAX, math.ceil(100 * DECADES) + 1)
HISTORIES = [(W_REF, T_REF)] + [(1.0, T) for _, T in FIT_OTHER]

print("Decay heat, §3.6: P/P0 = 0.066 (t^-0.2 - (t + T_op)^-0.2) as exponential groups")
print(f"  relative tolerance from the table's finest entry: 0.005 / {max(TABLE_PCT)} = {REL_TOL:.3e}")

# ================================================================ 1
print()
print("1. The formula against the §3.6 table (T_op = 160 EFPD), within its printed rounding")
print("     t        formula %    table %   diff pp    formula MW  table MW")
mw_ok = []
for t, lab, pct, mw in zip(TABLE_T, TABLE_LABEL, TABLE_PCT, TABLE_MW):
    f = 100.0 * formula(t, T_REF)
    mw_ok.append(abs(f / 100.0 * P0_MW - mw) <= MW_HALF_UNIT)
    print(f"     {lab:<7}  {f:9.5f}   {pct:7.2f}   {f - pct:+.5f}    {f / 100 * P0_MW:8.2f}   {mw:6d}")
for t, lab, pct in zip(TABLE_T, TABLE_LABEL, TABLE_PCT):
    check(f"formula at {lab:<6} within ±0.005 pp of the table's {pct:.2f} %",
          abs(100.0 * formula(t, T_REF) - pct) <= PCT_HALF_UNIT)
check("formula x 2,380 MWt within ±0.5 MW of every MW entry", all(mw_ok))

# ================================================================ 2
print()
print("2. Choosing the lambda grid")
print("   Upper end: the fastest group has to resolve t = 1 s, the table's first point; anything much faster is not")
print("   constrained by the data at all and only adds to the t = 0+ value. Lower end: the (t + T_op)^-0.2 term is")
print("   carried by groups slower than 1 / (t + T_op); for the longest history (640 EFPD, §2.3) and t = 7 d that")
floor = 1.0 / (T_MAX + T_LONGEST)
print(f"   is {floor:.3e} /s, so each grid runs down to its first point below it. Candidates are anchored on decades")
print("   (lambda = 10^(k s)); the choice is the smallest N whose worst error over the FITTED histories is under the")
print("   tolerance, ties to the lower upper end (less unconstrained sub-second content).")
print("     spacing   lambda_max   N   worst fitted   fRef")
candidates = []
for per_decade in (2.0, 2.5, 3.0):
    step = 1.0 / per_decade
    for kmax in (0, 1, 2):
        k_lo = math.floor(math.log10(floor) / step)        # first grid index at or below the floor
        lam = [10.0 ** (k * step) for k in range(kmax, k_lo - 1, -1)]
        E, _, _, _ = fit(lam, HISTORIES, TS_FIT)
        worst = max(max_rel(E, lam, T, TS_CHECK) for _, T in HISTORIES)
        fref = sum(e * saturation(l, T_REF) for e, l in zip(E, lam))
        candidates.append((len(lam), lam[0], worst, fref, lam))
        print(f"     10^{step:.3f}   {lam[0]:8.4f}   {len(lam):2d}   {worst:.2e}{'  *' if worst <= REL_TOL else '   '}   "
              f"{fref:.5f}")
passing = [c for c in candidates if c[2] <= REL_TOL]
N, _, _, _, LAM = min(passing, key=lambda c: (c[0], c[1]))
print(f"   (* = under {REL_TOL:.2e})  chosen: N = {N}, lambda {LAM[0]:.4f} ... {LAM[-1]:.1e} /s, "
      f"ratio {LAM[0] / LAM[1]:.4f} (10^{math.log10(LAM[0] / LAM[1]):.1f})")
lam_1s = [c for c in candidates if abs(c[1] - 1.0) < 1e-12]
check("no grid whose fastest group is 1 /s meets the tolerance (t = 1 s needs faster groups)",
      all(c[2] > REL_TOL for c in lam_1s))
check(f"N = {N} is within the tick budget of 12-24 groups", 12 <= N <= 24)
fref_passing = sorted({round(c[3], 6) for c in passing})
print(f"   fRef across the passing grids: {', '.join(f'{v:.4f}' for v in fref_passing)} -- set by the grid's upper end,")
print("   not by the data: the formula has no finite value at t = 0 (see 6).")

# ================================================================ 3
print()
print(f"3. The fit: NNLS on relative error, {len(TS_FIT)} times per history x {len(HISTORIES)} histories, "
      f"reference weight {W_REF:.4f}")
E, x_scaled, grad, nnls_tol = fit(LAM, HISTORIES, TS_FIT)
f_ref_i = [e * saturation(l, T_REF) for e, l in zip(E, LAM)]
fRef = sum(f_ref_i)
print("     i   lambda /s            1/lambda     E_i (fraction)         E_i (1 - e^-l T_ref)")
for i, (l, e, s) in enumerate(zip(LAM, E, f_ref_i), 1):
    print(f"    {i:2d}   {l:.12e}   {dur(1 / l):>9}   {e:.12e}   {s:.12e}")
kkt_active = all(g <= nnls_tol for g, v in zip(grad, x_scaled) if v == 0.0)
kkt_free = max((abs(g) for g, v in zip(grad, x_scaled) if v > 0.0), default=0.0)
print(f"   NNLS: {sum(v > 0 for v in x_scaled)} of {N} groups free; largest |gradient| on a free group {kkt_free:.2e}, "
      f"Lawson-Hanson tolerance {nnls_tol:.2e}")
check("Lawson-Hanson optimality: no group held at zero has a positive gradient", kkt_active)
check("Lawson-Hanson optimality: the gradient vanishes on every free group (to the algorithm's tolerance)",
      kkt_free <= nnls_tol)

# ================================================================ 4
print()
print("4. The groups against the formula and the table, T_op = 160 EFPD")
print("     t        formula %    groups %   table %   groups - formula pp")
table_points = []
for t, lab, pct in zip(TABLE_T, TABLE_LABEL, TABLE_PCT):
    f, g = 100.0 * formula(t, T_REF), 100.0 * model(E, LAM, t, T_REF)
    table_points.append((t, f, g, pct))
    print(f"     {lab:<7}  {f:9.5f}   {g:9.5f}   {pct:6.2f}    {g - f:+.6f}")
for (t, f, g, pct), lab in zip(table_points, TABLE_LABEL):
    check(f"groups at {lab:<6} within ±0.005 pp of the formula", abs(g - f) <= PCT_HALF_UNIT)
check("groups also round to the table's printed value at all ten points",
      all(abs(g - pct) <= PCT_HALF_UNIT for _, _, g, pct in table_points))
err_ref = max_rel(E, LAM, T_REF, TS_CHECK)
check(f"groups within {REL_TOL:.2e} of the formula everywhere in [1 s, 7 d] (max {err_ref:.2e})", err_ref <= REL_TOL)
print("   beyond the fitted span (information):", ", ".join(
    f"{dur(t)} {model(E, LAM, t, T_REF) / formula(t, T_REF) - 1:+.1e}" for t in (14 * DAY, 30 * DAY, 90 * DAY,
                                                                                160 * DAY, YEAR)))

# ================================================================ 5
print()
print(f"5. Other histories: max relative error over [1 s, 7 d] against the tolerance {REL_TOL:.2e}")
other_errs = []
for tag, group in (("fitted", FIT_OTHER), ("not fitted", UNSEEN)):
    for name, T in group:
        err = max_rel(E, LAM, T, TS_CHECK)
        other_errs.append((name, tag, err))
        check(f"T_op = {name:<9} ({tag:<10}) max relative error {err:.2e}", err <= REL_TOL)

# ================================================================ 6
print()
print("6. Stability, the tick update, and the decay fraction at t = 0+")
check("every E_i >= 0 (NNLS), so decay power is never negative for P >= 0", all(e >= 0.0 for e in E))
check("every lambda_i > 0: each state is a decaying mode, eigenvalues -lambda_i < 0", all(l > 0.0 for l in LAM))
# The update the simulator should use is exact for P held over the tick and stable for any dt:
#   H_i <- H_i exp(-lambda_i dt) + E_i P (1 - exp(-lambda_i dt))
# Forward Euler is stable only while lambda dt < 2 (and monotone while < 1).
lmax = max(LAM)
print(f"   exact update factors exp(-lambda dt): {math.exp(-lmax * DT_TICK):.4f} ... {math.exp(-min(LAM) * DT_TICK):.12f}"
      f" at 0.1 s; forward Euler: lambda_max dt = {lmax * DT_TICK:.3f} at 0.1 s, {lmax * DT_ACCEL:.3f} at the x10 clock")
check("forward Euler would also be monotone at the 0.1 s tick (lambda_max dt < 1)", lmax * DT_TICK < 1.0)
print(f"   NOTE: at the §0.2 x10 clock (1 s of plant time per tick) Euler has lambda_max dt = {lmax * DT_ACCEL:.2f} > 2 and "
      "diverges; use the exact update")
# Tick by tick: 160 EFPD at P = 1 in 1 h steps (exact for constant P), trip, then 0.1 s ticks for an hour.
H = [0.0] * N
decay = [math.exp(-l * 3600.0) for l in LAM]
for _ in range(int(T_REF / 3600.0)):
    H = [h * d + e * (1.0 - d) for h, d, e in zip(H, decay, E)]
steps_op = int(T_REF / 3600.0)
decay = [math.exp(-l * DT_TICK) for l in LAM]
worst_tick, k = 0.0, 0
for t_mark in (1, 10, 60, 600, 1800, 3600):
    while k < round(t_mark / DT_TICK):
        H = [h * d for h, d in zip(H, decay)]
        k += 1
    worst_tick = max(worst_tick, abs(sum(H) / model(E, LAM, t_mark, T_REF) - 1.0))
# Worst-case roundoff: each step rounds the product and the sum and carries exp(-l dt) to within one unit roundoff,
# which compounds once per step, so 4u per step bounds it; the closed form adds a handful of roundings more.
bound = 4.0 * U * (steps_op + k) + 16.0 * U
check(f"tick-by-tick exact update (160 EFPD in 1 h steps, then 0.1 s ticks) matches the closed form: "
      f"{worst_tick:.1e} <= {bound:.1e}", worst_tick <= bound)
# t = 0+ after 160 EFPD is sum E_i (1 - exp(-lambda_i T_ref)): the same number as fRef, by definition.
lo, hi = 1e-9, 1.0
for _ in range(200):
    mid = math.sqrt(lo * hi)
    lo, hi = (mid, hi) if formula(mid, T_REF) > fRef else (lo, mid)
t_equiv = math.sqrt(lo * hi)
sub_second = sum(s for s, l in zip(f_ref_i, LAM) if 1.0 / l < 1.0)
print(f"   fRef = sum E_i (1 - exp(-lambda_i x 160 EFPD)) = {fRef:.12f}  ({100 * fRef:.3f} % of P0)")
print(f"   t = 0+ after 160 EFPD at P0: the groups give the same {100 * fRef:.3f} %. The formula has no value there")
print(f"   (t^-0.2 -> infinity); t = 0+ lies below the table's 1 s start, where the formula is {100 * formula(1, T_REF):.3f} %.")
print(f"   The groups' 0+ value equals the formula at t = {t_equiv:.3f} s; {100 * sub_second:.3f} %P0 of it sits in groups")
print(f"   faster than 1 s, which the table cannot constrain. Prompt heat scale for rated steady power: 1 - fRef = "
      f"{1 - fRef:.12f}")
check("t = 0+ value is finite and above the formula at 1 s (the groups decay monotonically)",
      math.isfinite(fRef) and fRef > formula(1, T_REF))

# ================================================================ 7
print()
print("7. §4.5 coping time: 'the pool rises 200 K in ~6.5 h ... (the §3.6 curve integrated into 1,250 t of sodium")
print("   and 1,500 t of steel)'. A consistency check on the spec, not an input to the model.")
T_COPE, RISE = 6.5 * 3600.0, 200.0
# integral from 0 to t of 0.066 (s^-0.2 - (s + T)^-0.2) ds = 0.066 / 0.8 (t^0.8 - ((t + T)^0.8 - T^0.8)).
# The singular first term is integrated analytically; the second is written with expm1/log1p so it keeps its digits.


def energy_formula(t, T=T_REF):
    """Decay energy in full-power seconds (x P0 for joules)."""
    return COEF / 0.8 * (t ** 0.8 - T ** 0.8 * math.expm1(0.8 * math.log1p(t / T)))


def energy_groups(t, T=T_REF):
    return sum(e * saturation(l, T) * -math.expm1(-l * t) / l for e, l in zip(E, LAM))


def time_for(energy_fn, target, lo=1.0, hi=1e7):
    for _ in range(200):
        mid = math.sqrt(lo * hi)
        lo, hi = (mid, hi) if energy_fn(mid) < target else (lo, mid)
    return math.sqrt(lo * hi)


P0 = P0_MW * 1e6
e_cope = energy_formula(T_COPE)
C_req = e_cope * P0 / RISE
print(f"   decay energy 0 -> 6.5 h: {e_cope:.4f} full-power s = {e_cope * P0 / 1e9:.2f} GJ, so the pool heat capacity "
      f"the spec implies is {C_req / 1e6:,.1f} MJ/K")
# §4.1 lists 'Heat capacity, sodium plus internals ~2,400 MJ/K'. Read as two significant figures (a round figure
# marked ~), its half unit is 50 MJ/K.
check(f"that agrees with §4.1's ~2,400 MJ/K to its two significant figures ({C_req / 1e6:,.0f} vs 2,400 ± 50)",
      abs(C_req / 1e6 - 2400.0) <= 50.0)
t_groups = time_for(energy_groups, e_cope)
# The printed 6.5 h is good to ±0.05 h; the groups the simulator runs must reach the same energy within that.
check(f"the groups reach that energy at {t_groups / 3600:.5f} h, within ±0.05 h of the formula's 6.5 h",
      abs(t_groups - T_COPE) <= 0.05 * 3600.0)

# Sodium: Appendix A c_p (as ihx.py), integrated exactly: h = 1000 (aT + bT^2/2 + cT^3/3 - d/T) J/kg.
KELVIN = 273.15
CP = (1.6582, -8.479e-4, 4.4541e-7, -2992.6)
M_NA, M_STEEL = 1250e3, 1500e3                     # §4.1 / §4.5
# §4.1 inventories at §4.3's temperatures: hot pool 620 t at 550 °C, cold pool 560 t at 375 °C, core and diagrid
# 70 t taken at the middle of its 375 -> 550 °C rise. With no heat sink the pools mix, so 'the pool' starts at the
# mass-weighted mean; the two pool temperatures bound it.
T_START = (620e3 * 550.0 + 560e3 * 375.0 + 70e3 * 462.5) / M_NA


def h_na(T_c):
    T = T_c + KELVIN
    a, b, c, d = CP
    return 1000.0 * (a * T + b * T * T / 2.0 + c * T ** 3 / 3.0 - d / T)


# Pichler et al. 2020, Table 7: DSC specific heat of NIST SRM 316L, kJ/(kg K), k = 2 uncertainty 0.004-0.015.
PICHLER_T = list(range(473, 1254, 20))
PICHLER_CP = [0.528, 0.529, 0.530, 0.532, 0.534, 0.537, 0.541, 0.544, 0.547, 0.550, 0.553, 0.556, 0.559, 0.561,
              0.564, 0.566, 0.569, 0.572, 0.578, 0.587, 0.595, 0.598, 0.599, 0.600, 0.601, 0.603, 0.605, 0.606,
              0.608, 0.610, 0.611, 0.613, 0.614, 0.615, 0.617, 0.619, 0.620, 0.621, 0.622, 0.624]


def cp_316l_mean(T1_c, T2_c):
    """Mean c_p over [T1, T2] of the piecewise-linear Table 7, kJ/(kg K)."""
    T1, T2, s = T1_c + KELVIN, T2_c + KELVIN, 0.0
    for x0, y0, x1, y1 in zip(PICHLER_T, PICHLER_CP, PICHLER_T[1:], PICHLER_CP[1:]):
        lo, hi = max(x0, T1), min(x1, T2)
        if hi > lo:
            s += 0.5 * (y0 + (y1 - y0) * (lo - x0) / (x1 - x0) + y0 + (y1 - y0) * (hi - x0) / (x1 - x0)) * (hi - lo)
    return s / (T2 - T1)


def steel_implied(t_cope, t_start):
    c_na = M_NA * (h_na(t_start + RISE) - h_na(t_start)) / RISE
    return (energy_formula(t_cope) * P0 / RISE - c_na) / M_STEEL / 1000.0, c_na


cp_mid, c_na = steel_implied(T_COPE, T_START)
print(f"   sodium: 1,250 t from the mixed {T_START:.1f} °C to {T_START + RISE:.1f} °C, Appendix A mean c_p "
      f"{c_na / M_NA / 1000:.4f} kJ/(kg K) = {c_na / 1e6:,.1f} MJ/K")
print(f"   steel c_p the spec's 6.5 h implies (1,500 t): {cp_mid:.4f} kJ/(kg K)")
band = [steel_implied(3600.0 * h, T_START)[0] for h in (6.45, 6.55)]
starts = [steel_implied(T_COPE, T0)[0] for T0 in (375.0, 550.0)]
print(f"     over the ±0.05 h the printed 6.5 h allows: {band[0]:.4f} to {band[1]:.4f}; "
      f"sodium starting at 375 or 550 °C instead: {min(starts):.4f} to {max(starts):.4f}")
cp_pub = cp_316l_mean(T_START, T_START + RISE)
cp_pub_lo, cp_pub_hi = cp_316l_mean(375.0, 575.0), cp_316l_mean(550.0, 750.0)
t_pub = time_for(energy_formula, (c_na + M_STEEL * 1000.0 * cp_pub) * RISE / P0)
t_file20 = time_for(energy_formula, (M_NA * 1270.0 + M_STEEL * 550.0) * RISE / P0)
print(f"   published: NIST SRM 316L (Pichler et al. 2020, Table 7) averages {cp_pub:.4f} kJ/(kg K) over the same")
print(f"     {T_START:.0f} -> {T_START + RISE:.0f} °C ({cp_pub_lo:.4f} from 375 °C, {cp_pub_hi:.4f} from 550 °C); with it the "
      f"curve gives {t_pub / 3600:.2f} h.")
print(f"     The spec's own file-20 basis (1.27 and 0.55 kJ/(kg K)) gives {t_file20 / 3600:.2f} h (F17's 6.60 h).")
t_match = min(PICHLER_T[1:], key=lambda T: abs(cp_316l_mean(-KELVIN + PICHLER_T[0], T - KELVIN) * 0 +
                                                    PICHLER_CP[PICHLER_T.index(T)] - cp_mid))
lo_pub, hi_pub = min(PICHLER_CP), max(PICHLER_CP)
check(f"implied steel c_p is an austenitic-stainless magnitude: inside 316L's measured {lo_pub}-{hi_pub} kJ/(kg K) "
      f"(Table 7, 200-980 °C)", lo_pub <= cp_mid <= hi_pub)
print(f"   FINDING (consistency only, not a model input): the implied {cp_mid:.3f} is what 316L has near "
      f"{t_match - KELVIN:.0f} °C, and")
print(f"     {100 * (1 - cp_mid / cp_pub):.1f} % below 316L at the transient's own temperatures; 316L would make the "
      f"coping time {t_pub / 3600:.2f} h rather than ~6.5 h.")
print("     The spec does not say what the 1,500 t of steel is (§4.1 vessel 316LN; §2.3 cladding 15-15Ti, wrappers")
print("     ferritic-martensitic), so this stays an inversion: '~6.5 h' holds to about 4 %, not to its ±0.05 h.")

# ================================================================ 8
print()
print("8. Config-ready groups (Luau)")
print("\t-- derived: tools/derive/decay_heat.py (fit to §3.6 over 1 s .. 7 d, T_op 1 h .. 640 EFPD)")
print("\tgroups = {")
for l, e in zip(LAM, E):
    print(f"\t\t{{ lambda_ps = {l!r}, fraction = {e!r} }},   -- 1/lambda {dur(1 / l)}")
print("\t},")
print(f"\treferenceFraction = {fRef!r},   -- fRef: sum fraction (1 - exp(-lambda 160 EFPD))")

print()
print(f"{sum(checks)}/{len(checks)} checks pass")
raise SystemExit(0 if all(checks) else 1)
