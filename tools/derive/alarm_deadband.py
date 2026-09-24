"""
Alarm deadbands and the off-delay: how often an alarm on a noisy channel changes state while its signal sits still
(D-050, as amended on 2026-09-24).

THE ALARM. Protection samples a §9.5 row's alarm once per fast tick, as a two-state machine:
  - OUT -> IN on a tick when any channel is past the setpoint;
  - IN -> OUT once every channel has been back past the setpoint by the deadband for r consecutive ticks, where
    r = off-delay / tick, and r = 1 with no off-delay (out on the first tick back).
A flicker is one change of state, in or out, so each out-in-out cycle is two. Flicker rates below are changes of
state per second, the same count the review used ("about 2.5 times a second").

THE RULE (Aqua's amendment to D-050):
  - bounded noise (the thermocouple, uniform +-1 K, §2.5): the deadband is the full peak-to-peak span, 2 K, with no
    off-delay;
  - Gaussian noise (the power range, D-025's 0.5 %; the DNDs, Poisson counts through the ratemeter, whose sigma is
    sqrt(R / tau_avg)): the deadband is 3 sigma at the setpoint, and the alarm goes out only after the signal has
    stayed past it for 5 s. The 5 s is this derivation's engineering input, not its output.

METHOD. The rate at a steady level m is maximised over m, because a signal parked at the worst level is the case
that matters and no other level does worse.
  - Independent ticks (the thermocouple and the power range draw fresh noise every tick): exact. The out period is
    geometric, 1/p ticks, where p is the chance that a tick has a channel past the setpoint. The in period, from
    the tick the alarm came in, is the expected wait for r consecutive back ticks, (1 - q^r) / ((1 - q) q^r),
    where q is the chance that every channel is back. The rate is 2 / (tick (1/p + that wait)).
  - Correlated ticks (the DNDs, whose ratemeter carries each reading into the next): at the worst level both
    periods last hours, while the ratemeter forgets in about a second. Each period then ends at the process's
    stationary rate for its event:
        U = P(no channel past the setpoint at t-1, and some channel past it at t)
        W = P(some channel not back at t-r, and every channel back for the r ticks after it)
    and the flicker rate is 2 / (tick (1/U + 1/W)). The channels are independent, so both factor through one
    channel's run probabilities: U = s1^N - s2^N and W = b_r^N - b_(r+1)^N, where s_k (b_k) is the stationary
    chance that one channel stays below the setpoint (below the deadband's edge) for k ticks running. Those come
    from the ratemeter's transfer operator on a grid, with the exact Poisson counts Detectors draws. The same
    formula applied to the power range reproduces its exact rate, which is the check that the method holds.

Run: python tools/derive/alarm_deadband.py
"""
import math
from statistics import NormalDist

PHI = NormalDist().cdf

# §14.1
TICK_S = 0.1
# §9.5 alarm setpoints
PR_ALARM_PCTFP = 105.0
CORE_OUT_ALARM_C = 565.0
DND_BACKGROUND_CPS = 40.0        # §3.5
DND_ALARM_FACTOR = 3.0
DND_ALARM_CPS = DND_BACKGROUND_CPS * DND_ALARM_FACTOR
# channel counts (§3.5, §9.5)
PR_CHANNELS = 4
DND_CHANNELS = 6
# noise: §2.5 and D-025
THERMOCOUPLE_K = 1.0             # uniform, +-1 K
PR_RELATIVE = 0.005              # Gaussian, relative to the power
RATEMETER_AVERAGING_S = 2.0      # the DND ratemeter's averaging time; a first-order filter of half that
# Aqua's amendment. The off-delay is the engineering input.
GAUSSIAN_SIGMAS = 3.0
OFF_DELAY_S = 5.0

# the §9.5 row as it stood under D-050, for comparison
OLD_PR_DEADBAND = PR_RELATIVE * PR_ALARM_PCTFP
OLD_TC_DEADBAND = THERMOCOUPLE_K

checks = []


def check(label, ok, detail=""):
    checks.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {label}{(': ' + detail) if detail else ''}")


def ticks_for(off_delay_s):
    return max(1, round(off_delay_s / TICK_S))


def exact_rate(p, q, r):
    """Flicker rate, per second, of the two-state alarm on independent ticks."""
    if p <= 0.0 or q <= 0.0 or q ** r == 0.0:
        return 0.0
    wait_in = (1.0 - q ** r) / ((1.0 - q) * q ** r)
    return 2.0 / (TICK_S * (1.0 / p + wait_in))


def asymptotic_rate(U, W):
    """Flicker rate, per second, when both periods are long against the channel's memory."""
    if U <= 0.0 or W <= 0.0:
        return 0.0
    return 2.0 / (TICK_S * (1.0 / U + 1.0 / W))


def maximise(f, lo, hi, coarse):
    """The level in [lo, hi] where f is largest: a coarse scan, then golden-section search around its best."""
    best, at = -1.0, lo
    m = lo
    while m <= hi + 1e-12:
        v = f(m)
        if v > best:
            best, at = v, m
        m += coarse
    a, b = max(lo, at - coarse), min(hi, at + coarse)
    g = (math.sqrt(5.0) - 1.0) / 2.0
    c, d = b - g * (b - a), a + g * (b - a)
    fc, fd = f(c), f(d)
    while b - a > coarse * 1e-3:
        if fc > fd:
            b, d, fd = d, c, fc
            c = b - g * (b - a)
            fc = f(c)
        else:
            a, c, fc = c, d, fd
            d = a + g * (b - a)
            fd = f(d)
    m = (a + b) / 2.0
    return m, f(m)


def every(rate):
    if rate <= 0.0:
        return "never"
    if rate < 1e-12:
        return f"never in practice ({rate:.0e}/s)"
    s = 1.0 / rate
    if s < 120.0:
        return f"once every {s:.2f} s"
    if s < 7200.0:
        return f"once every {s / 60.0:.1f} min"
    return f"once every {s / 3600.0:.1f} h"


# ---------------------------------------------------------------------------------------------------------------
print("The thermocouple: uniform noise, +-1 K, independent ticks (§2.5, Pools)")


def tc_rate(m, deadband, r):
    a = THERMOCOUPLE_K
    p = min(1.0, max(0.0, (m + a - CORE_OUT_ALARM_C) / (2.0 * a)))               # m + u past the setpoint
    q = min(1.0, max(0.0, (CORE_OUT_ALARM_C - deadband - (m - a)) / (2.0 * a)))  # m + u back past the edge
    return exact_rate(p, q, r)


m_old, r_old = maximise(lambda m: tc_rate(m, OLD_TC_DEADBAND, 1), CORE_OUT_ALARM_C - 3.0, CORE_OUT_ALARM_C + 1.0, 0.01)
print(f"       D-050 as it stood, 1 K deadband: worst at {m_old:.2f} °C, {r_old:.2f} flickers/s")
check("the review's CORE-OUT figure, about 2.5 a second", abs(r_old - 2.5) < 0.05, f"{r_old:.3f}/s")
tc_new = 2.0 * THERMOCOUPLE_K
worst_new = max(tc_rate(CORE_OUT_ALARM_C - 3.0 + i * 0.001, tc_new, 1) for i in range(4001))
print(f"       amended, {tc_new:.0f} K deadband: an in needs m > {CORE_OUT_ALARM_C - THERMOCOUPLE_K:.0f} °C, a tick back"
      f" needs m < {CORE_OUT_ALARM_C - tc_new + THERMOCOUPLE_K:.0f} °C; no steady level has both")
check("with the full span as deadband, no steady level flickers", worst_new == 0.0, f"worst {worst_new}/s")

# ---------------------------------------------------------------------------------------------------------------
print("\nThe power range: Gaussian noise relative to the power, four channels, independent ticks (D-025, Detectors)")


def pr_pq(m, deadband, sigma_at=None):
    sigma = PR_RELATIVE * (sigma_at if sigma_at else m)
    p = 1.0 - PHI((PR_ALARM_PCTFP - m) / sigma) ** PR_CHANNELS
    q = PHI((PR_ALARM_PCTFP - deadband - m) / sigma) ** PR_CHANNELS
    return p, q


def pr_rate(m, deadband, r, sigma_at=None):
    p, q = pr_pq(m, deadband, sigma_at)
    return exact_rate(p, q, r)


rate104 = pr_rate(104.0, OLD_PR_DEADBAND, 1)
print(f"       D-050 as it stood, 1 sigma deadband: {rate104:.2f} flickers/s at 104 %FP")
check("the review's PR-HIGH figure, about 1.7 a second at 104 %FP", abs(rate104 - 1.7) < 0.05, f"{rate104:.3f}/s")
pr_old_m, pr_old_r = maximise(lambda m: pr_rate(m, OLD_PR_DEADBAND, 1), 100.0, 106.0, 0.01)
print(f"       its worst: {pr_old_r:.2f} flickers/s at {pr_old_m:.2f} %FP, {every(pr_old_r)}")
check("the review's 'one every 0.4 s now'", abs(1.0 / pr_old_r - 0.43) < 0.01, f"{1.0 / pr_old_r:.3f} s")

R_OFF = ticks_for(OFF_DELAY_S)
pr_new_deadband = GAUSSIAN_SIGMAS * PR_RELATIVE * PR_ALARM_PCTFP
print(f"       amended: deadband {GAUSSIAN_SIGMAS:.0f} sigma at the setpoint = {pr_new_deadband:.3f} %FP,"
      f" off-delay {OFF_DELAY_S:.0f} s = {R_OFF} ticks")
m_aqua, r_aqua = maximise(lambda m: pr_rate(m, pr_new_deadband, R_OFF, PR_ALARM_PCTFP), 95.0, 106.0, 0.05)
print(f"       with the noise's sigma taken at the setpoint: worst at {m_aqua:.2f} %FP, {every(r_aqua)}")
check("Aqua's estimate, about one flicker every 3.4 h", abs(1.0 / r_aqua / 3600.0 - 3.4) < 0.05,
      f"{1.0 / r_aqua / 3600.0:.2f} h")
pr_m, pr_r = maximise(lambda m: pr_rate(m, pr_new_deadband, R_OFF), 95.0, 106.0, 0.05)
p_w, q_w = pr_pq(pr_m, pr_new_deadband)
print(f"       with the noise relative to the power, as Detectors draws it: worst at {pr_m:.2f} %FP, {every(pr_r)}")
print(f"         there: p = {p_w:.3e} a tick (a channel past 105), q = {q_w:.4f} (all four back past"
      f" {PR_ALARM_PCTFP - pr_new_deadband:.3f}), q^{R_OFF} = {q_w ** R_OFF:.3e}")
print(f"         the alarm is in {1.0 - (1.0 / p_w) / (1.0 / p_w + (1.0 - q_w ** R_OFF) / ((1.0 - q_w) * q_w ** R_OFF)):.0%}"
      " of the time there: the worst level is where both states are long, not where either is short")
old_at_worst = pr_rate(pr_old_m, pr_new_deadband, R_OFF)
print(f"       amended, at the old rule's worst level ({pr_old_m:.2f} %FP): {every(old_at_worst)}"
      " -- the alarm comes in and stays in")
check("the amended rule is at least 10^4 times quieter than the old at its worst", pr_r * 1e4 < pr_old_r,
      f"{pr_old_r / pr_r:.2e} times")

# ---------------------------------------------------------------------------------------------------------------
print("\nThe asymptotic method, checked on the power range, where the exact rate is known")


def pr_asymptotic(m, deadband, r):
    sigma = PR_RELATIVE * m
    s = PHI((PR_ALARM_PCTFP - m) / sigma)
    b = PHI((PR_ALARM_PCTFP - deadband - m) / sigma)
    U = s ** PR_CHANNELS - (s * s) ** PR_CHANNELS
    W = (b ** r) ** PR_CHANNELS - (b ** (r + 1)) ** PR_CHANNELS
    return asymptotic_rate(U, W)


a = pr_asymptotic(pr_m, pr_new_deadband, R_OFF)
print(f"       at {pr_m:.2f} %FP: exact {pr_r:.6e}/s, asymptotic {a:.6e}/s")
check("the asymptotic rate matches the exact one to 0.1 %", abs(a / pr_r - 1.0) < 1e-3, f"{a / pr_r - 1.0:+.2e}")

# ---------------------------------------------------------------------------------------------------------------
print("\nThe DNDs: Poisson counts through the ratemeter, six channels, correlated ticks (§3.5, D-025, Detectors)")
TAU = RATEMETER_AVERAGING_S / 2.0
ALPHA = 1.0 - math.exp(-TICK_S / TAU)
dnd_sigma = math.sqrt(DND_ALARM_CPS / RATEMETER_AVERAGING_S)
dnd_deadband = GAUSSIAN_SIGMAS * dnd_sigma
dnd_edge = DND_ALARM_CPS - dnd_deadband
print(f"       sigma at the {DND_ALARM_CPS:.0f} cps setpoint {dnd_sigma:.3f} cps: deadband {dnd_deadband:.2f} cps,"
      f" back below {dnd_edge:.2f} cps")


def dnd_runs(R, h, k_max):
    """One channel's stationary run probabilities at true rate R: s1, s2 below the setpoint; b_k below the edge."""
    x_max = DND_ALARM_CPS * 2.0
    nb = int(x_max / h) + 2
    lam = R * TICK_S
    pmf, n, pn = [], 0, math.exp(-lam)
    while n <= lam + 12.0 * math.sqrt(lam) + 10.0:
        pmf.append(pn)
        n += 1
        pn *= lam / n
    # each bin's reading moves to (1 - alpha) x + alpha n / tick, split linearly between the two nearest bins
    moves = []
    for i in range(nb):
        row = {}
        for n, w in enumerate(pmf):
            f = ((1.0 - ALPHA) * i * h + ALPHA * n / TICK_S) / h
            j = int(f)
            frac = f - j
            if j >= nb - 1:
                j, frac = nb - 2, 1.0
            row[j] = row.get(j, 0.0) + w * (1.0 - frac)
            row[j + 1] = row.get(j + 1, 0.0) + w * frac
        moves.append(list(row.items()))

    def step(v, keep=None):
        out = [0.0] * nb
        for i, vi in enumerate(v):
            if vi:
                for j, w in moves[i]:
                    out[j] += vi * w
        if keep is not None:
            out = [o if keep[j] else 0.0 for j, o in enumerate(out)]
        return out

    v = [0.0] * nb
    v[min(nb - 1, int(R / h))] = 1.0
    for _ in range(200):  # (1 - alpha)^200 = 2e-9: the start is forgotten
        v = step(v)
    below_sp = [j * h <= DND_ALARM_CPS for j in range(nb)]
    below_edge = [j * h <= dnd_edge for j in range(nb)]
    u = [vi if below_sp[j] else 0.0 for j, vi in enumerate(v)]
    s1 = sum(u)
    s2 = sum(step(u, below_sp))
    u = [vi if below_edge[j] else 0.0 for j, vi in enumerate(v)]
    b = {1: sum(u)}
    for k in range(2, k_max + 1):
        u = step(u, below_edge)
        b[k] = sum(u)
    return s1, s2, b


def dnd_rate(R, h=0.25, r=R_OFF):
    s1, s2, b = dnd_runs(R, h, r + 1)
    U = s1 ** DND_CHANNELS - s2 ** DND_CHANNELS
    W = b[r] ** DND_CHANNELS - b[r + 1] ** DND_CHANNELS
    return asymptotic_rate(U, W), U, W


dnd_m, dnd_r = maximise(lambda R: dnd_rate(R)[0], 80.0, 100.0, 2.0)
_, U, W = dnd_rate(dnd_m)
print(f"       amended: worst at {dnd_m:.1f} cps ({dnd_m / DND_BACKGROUND_CPS:.2f} x background), {every(dnd_r)}")
print(f"         there: U = {U:.3e} a tick (out period {1.0 / U / 36000.0:.1f} h),"
      f" W = {W:.3e} a tick (in period {1.0 / W / 36000.0:.1f} h), against a ratemeter time constant of {TAU:.0f} s")
fine, _, _ = dnd_rate(dnd_m, 0.125)
print(f"         on a grid of half the step: {every(fine)} ({fine / dnd_r - 1.0:+.1%})")
check("the grid is fine enough: halving it moves the rate by under 5 %", abs(fine / dnd_r - 1.0) < 0.05)
check("both periods are long against the ratemeter's memory, as the method needs",
      min(1.0 / U, 1.0 / W) * TICK_S > 1000.0 * TAU)
print(f"       {dnd_r / pr_r:.1f} times the power range's worst: the ratemeter carries each reading into the next, so")
print("       the six readings stay back for 5 s far more often than 50 fresh draws would. For comparison only,")
print("       the worst rate with a longer off-delay and the same deadband (Aqua's rule gives the DNDs 5 s):")
for off in (10.0, 20.0, 30.0):
    r = ticks_for(off)
    m, v = maximise(lambda R: dnd_rate(R, 0.25, r)[0], 80.0, 100.0, 2.0)
    print(f"         {off:4.0f} s: worst at {m:.1f} cps, {every(v)}")

print("\nSummary: steady-signal flicker at each row's worst level")
print(f"       CORE-OUT  1 K, no off-delay: {every(r_old):>24}   amended (2 K):              never")
print(f"       PR-HIGH   1 sigma, no delay: {every(pr_old_r):>24}   amended (3 sigma, 5 s): {every(pr_r)}")
print(f"       DND       amended (3 sigma, 5 s): {every(dnd_r)}")
print(f"\n{sum(checks)}/{len(checks)} checks pass")
raise SystemExit(0 if all(checks) else 1)
