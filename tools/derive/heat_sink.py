"""
The M1 heat sink (D-032, F33): what §9.2's part-load table asks of the IHXs, and what each way of standing in
for the steam plant does to the primary.

§9.2 holds the core inlet at 375 °C at every load and gives the secondary cold and hot legs. §4.3 gives one UA,
which D-022 holds constant. This script shows the two cannot both hold at part load, and by how much:

  1. UA implied by each row of the table (duty / LMTD of the row's own four temperatures). From 40 % up it falls
     in proportion to flow, because those rows repeat the full-load temperatures at part duty.
  2. A cold leg PINNED to the table, with §4.3's UA: the primary settles where the exchangers carry the load,
     which is well below the programme's 375 °C inlet.
  3. A sink that TAKES the load, with §4.3's UA and the primary on the programme: the cold leg it needs, against
     the table's column. This is what Systems/IHX does.

Flows follow §9.2's flow column on both sides (Systems/PartLoad: the table's own heat balance gives it). Pump
heat is left out, as in IHXSpec, so the load is the whole duty. ε-NTU, c_p and the three-pass convergence are the
same as tools/derive/ihx.py and Systems/IHX.
Run: python tools/derive/heat_sink.py
"""
import math

KELVIN = 273.15
CP = (1.6582, -8.479e-4, 4.4541e-7, -2992.6)   # Appendix A, as ihx.py

UNITS = 6
UA = 9.6e6              # §4.3, W/K per unit (D-022)
M_PRIMARY = 1782.0      # §4.3, kg/s per unit at rated flow
M_SECONDARY = 1556.0
CORE_MWT = 2380.0       # §1.1
INLET = 375.0           # §9.2: core inlet held throughout

# §9.2 table
POWER = [100, 80, 60, 40, 30, 20, 10, 5]
FLOW = [100, 80, 60, 40, 40, 40, 40, 25]
OUTLET = [550, 550, 550, 550, 506, 462, 419, 410]
S_COLD = [320, 320, 320, 320, 334, 348, 361, 364]
S_HOT = [520, 520, 520, 520, 484, 448, 411, 404]


def cp(T):
    a, b, c, d = CP
    return 1000.0 * (a + T * (b + T * c) + d / (T * T))


def effectiveness(ua, c_hot, c_cold):
    c_min, c_max = min(c_hot, c_cold), max(c_hot, c_cold)
    if c_min <= 0.0:
        return 0.0
    ntu = ua / c_min
    cr = c_min / c_max
    if cr > 0.999999:
        return ntu / (1.0 + ntu)
    e = math.exp(-ntu * (1.0 - cr))
    return (1.0 - e) / (1.0 - cr * e)


def duty(m_p, t_p_in, m_s, t_s_in):
    t_p_out, t_s_out = t_p_in, t_s_in
    q = 0.0
    for _ in range(3):
        c_p_ = m_p * cp(0.5 * (t_p_in + t_p_out) + KELVIN)
        c_s_ = m_s * cp(0.5 * (t_s_in + t_s_out) + KELVIN)
        q = effectiveness(UA, c_p_, c_s_) * min(c_p_, c_s_) * (t_p_in - t_s_in)
        t_p_out = t_p_in - q / c_p_
        t_s_out = t_s_in + q / c_s_
    return q, t_p_out, t_s_out


def bisect(f, lo, hi, n=200):
    """Root of an increasing f on [lo, hi]."""
    for _ in range(n):
        mid = 0.5 * (lo + hi)
        if f(mid) > 0:
            hi = mid
        else:
            lo = mid
    return 0.5 * (lo + hi)


def lmtd(t_p_in, t_p_out, t_s_in, t_s_out):
    d1, d2 = t_p_in - t_s_out, t_p_out - t_s_in
    return d1 if abs(d1 - d2) < 1e-9 else (d1 - d2) / math.log(d1 / d2)


checks = []


def check(label, ok):
    checks.append(ok)
    print(f"  [{'ok' if ok else 'FAIL'}] {label}")


print("1. UA each row of §9.2 implies (duty / LMTD of the row's own temperatures), against §4.3's 9.6 MW/K")
ratios = []
for p, f, out, sc, sh in zip(POWER, FLOW, OUTLET, S_COLD, S_HOT):
    q = p / 100 * CORE_MWT * 1e6 / UNITS
    ua = q / lmtd(out, INLET, sc, sh)
    ratios.append((p, f, ua / UA))
    print(f"  {p:3d} %FP on {f:3d} % flow: {ua / 1e6:5.2f} MW/K = {ua / UA:.3f} of §4.3's")
check("from 40 % up, the implied UA is the flow fraction to within the table's rounding",
      all(abs(r - f / 100) < 0.02 for p, f, r in ratios if p >= 40))

print()
print("2. Cold leg pinned to the table, §4.3's UA: where the primary settles to carry the load")
pinned = []
for p, f, sc in zip(POWER, FLOW, S_COLD):
    mp, ms = M_PRIMARY * f / 100, M_SECONDARY * f / 100
    q = p / 100 * CORE_MWT * 1e6 / UNITS
    hot = bisect(lambda th: duty(mp, th, ms, sc)[0] - q, sc, 700.0)
    _, primary_out, _ = duty(mp, hot, ms, sc)
    pinned.append((p, primary_out - INLET))
    print(f"  {p:3d} %FP: hot pool {hot:6.1f} °C, core inlet {primary_out:6.1f} °C ({primary_out - INLET:+5.1f} K)")
part = [d for p, d in pinned if p < 100]
print(f"  part load: {min(part):+.1f} to {max(part):+.1f} K from the programme's 375 °C")
check("at part load a pinned cold leg always pulls the inlet below the programme", all(d < 0 for d in part))

print()
print("3. A sink that takes the load, §4.3's UA, primary on the programme: the cold leg it needs")
taking = []
for p, f, out, sc in zip(POWER, FLOW, OUTLET, S_COLD):
    mp, ms = M_PRIMARY * f / 100, M_SECONDARY * f / 100
    q = p / 100 * CORE_MWT * 1e6 / UNITS
    cold = bisect(lambda tc: q - duty(mp, out, ms, tc)[0], 0.0, out)
    taking.append((p, cold - sc, cold))
    print(f"  {p:3d} %FP: cold leg {cold:6.1f} °C against the table's {sc} °C ({cold - sc:+5.1f} K)")
part = [d for p, d, _ in taking if p < 100]
print(f"  part load: {min(part):+.1f} to {max(part):+.1f} K from the table's secondary column")
check("every row's cold leg lies inside the sink's range: the table's value to 375 °C",
      all(sc - 0.5 <= c <= INLET for (p, d, c), sc in zip(taking, S_COLD)))
check("at full load the needed cold leg is the table's 320 °C to within its rounding", abs(taking[0][1]) < 0.5)

print()
print(f"{sum(checks)}/{len(checks)} checks pass")
