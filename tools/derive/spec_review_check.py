"""
Kallskar: independent recomputation of every quantitative claim in REACTOR SPEC/3A SPEC REVIEW.

The review file collects comments from eight reviewers. It is explicitly NOT a source of truth, so every numeric
claim here is recomputed from the spec's own primitives (KALLSKAR_ALL_IN_ONE.txt, Appendix A sodium correlations,
§3.1 kinetics data, §3.4 rod worths) and given a verdict. Sections are cited for each claim.

Run: python tools/derive/spec_review_check.py > tools/derive/spec_review_check.out.txt
"""
import math

# ---------------------------------------------------------------- spec primitives
PTH = 2380.0  # MWt, §1.1
PUMP_HEAT = 10.0  # MWt, §4.2
BETA = [8.8, 71.3, 66.6, 131.8, 61.6, 20.2]  # pcm, §3.1
LAMBDA = [0.0130, 0.0315, 0.135, 0.345, 1.37, 3.82]  # 1/s, §3.1
BETA_SUM = sum(BETA)

# Appendix A (Fink–Leibowitz), T in kelvin
def rho_na(T):
    x = 1 - T / 2503.7
    return 219 + 275.32 * x + 511.58 * math.sqrt(x)

def cp_na(T):  # kJ/(kg·K)
    return 1.6582 - 8.479e-4 * T + 4.4541e-7 * T * T - 2992.6 / (T * T)

def h_na(T):  # kJ/kg, arbitrary zero
    return 1.6582 * T - 8.479e-4 * T * T / 2 + 4.4541e-7 * T ** 3 / 3 + 2992.6 / T

def K(c):
    return c + 273.15

def verdict(label, spec_value, computed, tol, unit="", note=""):
    ok = spec_value is None or abs(computed - spec_value) <= tol
    mark = "OK  " if ok else "MISMATCH"
    s = f"  [{mark}] {label}: computed {computed:,.4g}{unit}"
    if spec_value is not None:
        s += f" vs spec {spec_value:,.4g}{unit} (tolerance {tol:g})"
    if note:
        s += f"\n           {note}"
    print(s)
    return ok


print("=" * 108)
print("KALLSKAR SPEC REVIEW — INDEPENDENT RECOMPUTATION")
print("=" * 108)

# ---------------------------------------------------------------- 1. kinetics / periods (E1 #1, E4 #1)
print("\n1. REACTOR PERIOD FOR +300 pcm  (spec §3.4 'period near 2.5 s'; E1 says 0.47 s, E4 says 0.46 s)")

def inhour_rho(T):
    return sum(b / (1 + l * T) for b, l in zip(BETA, LAMBDA))

def period_for(rho_pcm, lo=1e-4, hi=1e6):
    for _ in range(300):
        mid = math.sqrt(lo * hi)
        if inhour_rho(mid) > rho_pcm:
            lo = mid
        else:
            hi = mid
    return math.sqrt(lo * hi)

T300 = period_for(300.0)
print(f"  inhour equation with §3.1 data: rho = sum(beta_i / (1 + lambda_i T))")
verdict("period at +300 pcm", 2.5, T300, 0.05, " s", "spec §3.4 is wrong; the reviewers are right (F12/D-016 already records this)")
verdict("reactivity giving a 2.5 s period", None, inhour_rho(2.5), 0, " pcm")
verdict("reactivity giving the 10 s period trip (§9.5)", None, inhour_rho(10.0), 0, " pcm")
verdict("reactivity giving the 30 s rod block (§9.5)", None, inhour_rho(30.0), 0, " pcm")

# ---------------------------------------------------------------- 2. rod ramp rates vs the 4 pcm/s interlock (E1, E4)
print("\n2. ROD WITHDRAWAL RATES vs THE 4 pcm/s INTERLOCK  (§3.4)")
STROKE_MM = 1000.0

def diff_worth(total_pcm, d):
    """dW/dx in pcm/mm for W(d) = W_total (d - sin(2 pi d)/2 pi)."""
    return total_pcm * (1 - math.cos(2 * math.pi * d)) / STROKE_MM

for name, total, speed in (("shim bank A (6 x 400)", 2400, 1.0), ("shim bank B (6 x 300)", 1800, 1.0),
                           ("shim bank C (6 x 200)", 1200, 1.0), ("single shim rod (400)", 400, 2.0),
                           ("RR bank (3 x 100)", 300, 5.0)):
    peak = diff_worth(total, 0.5) * speed
    flag = "EXCEEDS the 4 pcm/s interlock" if peak > 4 else "within the interlock"
    print(f"  {name:24} at {speed:g} mm/s: peak {peak:.2f} pcm/s — {flag}")

# ---------------------------------------------------------------- 3. S-19: how fast can the RRs actually ramp? (E1)
print("\n3. S-19 RAMP TIME TO THE PERIOD TRIP  (§3.4 interlock: one rod or one bank at a time; RR 5 mm/s)")
rho_trip = inhour_rho(10.0)

def rr_worth_from(d_start, mm_withdrawn, rods=1, per_rod=100.0):
    """Worth released by withdrawing `mm` from inserted fraction d_start, one rod at a time."""
    released = 0.0
    for _ in range(rods):
        d0 = d_start
        d1 = max(0.0, d0 - mm_withdrawn / STROKE_MM)
        w = lambda d: per_rod * (d - math.sin(2 * math.pi * d) / (2 * math.pi))
        released += w(d0) - w(d1)
    return released

# RR band 400-700 mm withdrawn height => inserted fraction 0.6 .. 0.3; mid-band position 550 mm => d = 0.45
d_mid = 0.45
full_three = rr_worth_from(d_mid, 1000, rods=3)
t_seq = 3 * (d_mid * STROKE_MM) / 5.0
print(f"  from mid-band (d = {d_mid}), withdrawing all three RRs releases {full_three:.1f} pcm "
      f"(the spec's +300 pcm assumes they start fully inserted)")
print(f"  one rod at a time at 5 mm/s: {t_seq:.0f} s to run all three out; "
      f"the 10 s-period trip needs {rho_trip:.0f} pcm")
# time to reach rho_trip, sequential withdrawal
t, released, d, rod = 0.0, 0.0, d_mid, 1
while released < rho_trip and rod <= 3:
    d -= 5.0 / STROKE_MM  # 1 s at 5 mm/s
    t += 1.0
    if d <= 0:
        d, rod = d_mid, rod + 1
    released = rr_worth_from(d_mid, (d_mid - max(d, 0)) * STROKE_MM, rods=1) + (rod - 1) * rr_worth_from(d_mid, 1000, rods=1)
print(f"  => the period trip is reached after about {t:.0f} s of continuous withdrawal "
      f"(E1's '40 s' assumes the three rods move together at ~3 pcm/s, which the §3.4 interlock forbids)")

# ---------------------------------------------------------------- 4. IHX duty (E1 #2, E3 #4, E4 #2)
print("\n4. IHX PRIMARY DUTY  (§4.3: 1,782 kg/s, 545 -> 375 C, rated 400 MWt each)")
m_ihx = 1782.0
for t_in in (545.0, 550.0):
    q = m_ihx * (h_na(K(t_in)) - h_na(K(375.0))) / 1000  # MW
    verdict(f"duty with {t_in:g} C inlet", None, q, 0, " MWt")
q545 = m_ihx * (h_na(K(545)) - h_na(K(375))) / 1000
q550 = m_ihx * (h_na(K(550)) - h_na(K(375))) / 1000
print(f"  six units: {6 * q545:.0f} MWt at 545 C vs {6 * q550:.0f} MWt at 550 C; core + pump heat = {PTH + PUMP_HEAT:.0f} MWt")
print(f"  => 545 C leaves a {PTH + PUMP_HEAT - 6 * q545:.0f} MWt shortfall; 550 C closes to "
      f"{PTH + PUMP_HEAT - 6 * q550:+.0f} MWt. The reviewers are right.")
# LMTD with secondary 320 -> 520 (counter-current)
d1, d2 = 545 - 520, 375 - 320
lmtd545 = (d1 - d2) / math.log(d1 / d2)
d1b = 550 - 520
lmtd550 = (d1b - d2) / math.log(d1b / d2)
verdict("LMTD at 545 C (spec 'LMTD ~ 40 K')", 40.0, lmtd545, 2.0, " K")
verdict("LMTD at 550 C", 40.0, lmtd550, 2.0, " K")
print(f"  UA implied: {q545 / lmtd545:.2f} MW/K at 545 C, {q550 / lmtd550:.2f} MW/K at 550 C (spec 'UA ~ 10 MW/K')")

# ---------------------------------------------------------------- 5. secondary and primary heat balance (E5, E7)
print("\n5. PRIMARY AND SECONDARY HEAT BALANCE  (§1.1, §5.1)")
m_pri = 10694.0
q_pri = m_pri * (h_na(K(550)) - h_na(K(375))) / 1000
verdict("primary duty at 10,694 kg/s, 375 -> 550 C", PTH + PUMP_HEAT, q_pri, 25, " MWt",
        "the primary loop carries core power plus pump heat")
m_sec = 3 * 3112.0
q_sec = m_sec * (h_na(K(520)) - h_na(K(320))) / 1000
verdict("secondary duty at 3 x 3,112 kg/s, 320 -> 520 C", 3 * 796.0, q_sec, 15, " MWt")
print(f"  SG section arithmetic: 24 x 99.5 = {24 * 99.5:.0f} MWt vs the stated reactor rating {PTH:.0f} MWt "
      f"(+ pump heat {PUMP_HEAT:g}) = {PTH + PUMP_HEAT:.0f} MWt")
print(f"  => the 2,380 / 2,388 gap the reviewers flag is {24 * 99.5 - PTH:.0f} MWt; against core+pump heat it is "
      f"{24 * 99.5 - (PTH + PUMP_HEAT):+.0f} MWt, i.e. rounding of the section duty (99.5 vs {(PTH + PUMP_HEAT) / 24:.3f}).")

# ---------------------------------------------------------------- 6. average linear heat rate (E3 #2)
print("\n6. AVERAGE LINEAR HEAT RATE  (§2.4: 27.7 kW/m; E3 claims it should be 29.2)")
pins = 301 * 271
length = pins * 1.0
print(f"  active fuel length: 301 x 271 x 1.0 m = {length:,.0f} m")
verdict("LHR if ALL 2,380 MWt were in the pins", None, PTH * 1e3 / length, 0, " kW/m")
verdict("LHR with the 95 % pin fraction the spec's own file-20 calc uses", 27.7, 0.95 * PTH * 1e3 / length, 0.05, " kW/m",
        "5 % of fission energy is deposited outside the pins (gammas in structure and coolant); E3 ignored it")
peaking = 1.20 * 1.04 * 1.22
verdict("peak LHR = 27.7 x 1.20 x 1.04 x 1.22", 42.0, 27.7 * peaking, 0.3, " kW/m")

# ---------------------------------------------------------------- 7. core flow velocity and transit (E3 #3)
print("\n7. BUNDLE VELOCITY AND CORE TRANSIT  (§2.5: 32.9 kg/s per assembly, 5.4 m/s, 0.19 s)")
flats_outer = 0.173  # §2.1 wrapper across flats
wall = 0.0045  # §2.1 wrapper wall
flats_inner = flats_outer - 2 * wall
area_hex = math.sqrt(3) / 2 * flats_inner ** 2
area_pins = 271 * math.pi / 4 * 0.0085 ** 2
area_wire = 271 * math.pi / 4 * 0.0012 ** 2
area_flow = area_hex - area_pins - area_wire
print(f"  inner across-flats {flats_inner * 1000:.0f} mm -> duct area {area_hex * 1e4:.2f} cm2; "
      f"pins {area_pins * 1e4:.2f}; wire {area_wire * 1e4:.2f}; free area {area_flow * 1e4:.2f} cm2")
for label, T in (("core inlet 375 C", 375.0), ("core average 467 C", 467.0), ("core outlet 559 C", 559.0)):
    v = 32.9 / rho_na(K(T)) / area_flow
    print(f"    velocity at {label}: {v:.2f} m/s; 1.0 m fuel transit {1.0 / v:.3f} s")
v_avg = 32.9 / rho_na(K(467)) / area_flow
verdict("bundle velocity at core-average density", 5.4, v_avg, 0.4, " m/s",
        "E3 used the 173 mm OUTER across-flats and got 3.6-3.7 m/s; the 4.5 mm wrapper wall makes the inner flats 164 mm")
verdict("core transit time", 0.19, 1.0 / v_avg, 0.02, " s")

# ---------------------------------------------------------------- 8. cover gas cooldown (E1, E4)
print("\n8. COVER GAS ON COOLDOWN  (§4.4: 320 m3, 0.120 MPa, ~90 m3 swing, '~0.074 MPa')")
V1, V2 = 320.0, 410.0
Tg_full, Tg_cold = K(300.0), K(180.0)  # cover-gas space temperatures used by the spec's file-20 calc
print(f"  gas-space temperatures from the spec's own calc: {Tg_full - 273.15:.0f} C at power, {Tg_cold - 273.15:.0f} C cold")
verdict("volume change only", None, 0.120 * V1 / V2, 0, " MPa")
verdict("gas cooling only", None, 0.120 * Tg_cold / Tg_full, 0, " MPa")
verdict("both (the spec's number)", 0.074, 0.120 * (V1 / V2) * (Tg_cold / Tg_full), 0.001, " MPa",
        "E1 (volume alone 0.094) and E4 (0.057 using sodium temperatures 230/550 C for the gas) both mis-stated it")

# ---------------------------------------------------------------- 9. DRACS / SBO coping time (E1 #4)
print("\n9. COPING TIME, NO HEAT SINK  (§4.5: 'pool rises 200 K in about 5 h'; E1 says 6.5 h)")
C_pool = 1250e3 * 1.27 + 1500e3 * 0.55  # kJ/K: 1,250 t sodium + 1,500 t steel (the spec's file-20 basis)
E_200K = C_pool * 200  # kJ
TOP = 160 * 86400.0

def decay_energy(t):
    """Integral of 0.066 (s^-0.2 - (s+T_op)^-0.2) P0 ds from 0 to t, in kJ."""
    return 0.066 * PTH * 1e3 / 0.8 * (t ** 0.8 - ((t + TOP) ** 0.8 - TOP ** 0.8))

def decay_energy_first_term_only(t):
    return 0.066 * PTH * 1e3 / 0.8 * t ** 0.8

for name, fn in (("spec calc.py (first term only)", decay_energy_first_term_only), ("full §3.6 formula", fn2 := decay_energy)):
    lo, hi = 1.0, 1e7
    for _ in range(200):
        mid = math.sqrt(lo * hi)
        if fn(mid) < E_200K:
            lo = mid
        else:
            hi = mid
    print(f"  {name:32}: 200 K rise after {math.sqrt(lo * hi) / 3600:.2f} h")
print(f"  pool heat capacity used: {C_pool / 1e3:,.0f} MJ/K (1,250 t Na x 1.27 + 1,500 t steel x 0.55)")
print("  => the spec's ~5 h comes from dropping the -(t+T_op)^-0.2 term when integrating; with the §3.6 formula")
print("     as written the answer is ~6.7 h. E1 is right (they said ~6.5 h).")

# ---------------------------------------------------------------- 10. decay heat at 1 s (E7)
print("\n10. DECAY HEAT AT 1 s  (§3.6 table: 6.35 %, 151 MW; E7 claims the formula gives 156 MW)")
f1 = 0.066 * (1 ** -0.2 - (1 + TOP) ** -0.2)
verdict("P/P0 at t = 1 s from the full formula", 0.0635, f1, 0.0002, "")
verdict("MW at 1 s", 151.0, f1 * PTH, 1.0, " MW",
        "E7 evaluated only 0.066 x t^-0.2 = 6.6 %; the second term is worth -0.25 %FP. No change needed.")

# ---------------------------------------------------------------- 11. source range count rate (E4 #6)
print("\n11. SOURCE-RANGE COUNT RATE, ALL RODS IN  (§3.5: '15/(1-k), about 250 cps')")
excess = 2250.0  # §3.3 at 230 C
pss = 300 + 5400.0
sss = 9 * 330.0
for label, worth in (("PSS only, most reactive rod stuck (the §3.3 shutdown margin)", pss - 400),
                     ("PSS only, no rod stuck", pss), ("all rods in (PSS + SSS)", pss + sss)):
    rho = (excess - worth) / 1e5
    k = 1 / (1 - rho)
    print(f"  {label:58}: rho = {rho * 1e5:+7.0f} pcm, k = {k:.4f}, SR = {15 / (1 - k):5.0f} cps")
print("  => 'all rods in' means PSS + SSS, which gives 249 cps. The spec's 250 cps is right;")
print("     E4's 492 cps used the stuck-rod shutdown margin instead.")

# ---------------------------------------------------------------- 12. RR band worth and drift (E1 #5)
print("\n12. REGULATING BAND WORTH AND DRIFT  (§3.4 band 400-700 mm; §3.3 reserves 250 pcm; §10.5 says ~20 min)")
def rr_integral(d):
    return 300.0 * (d - math.sin(2 * math.pi * d) / (2 * math.pi))
band = rr_integral(0.6) - rr_integral(0.3)  # 400 mm withdrawn = 0.6 inserted, 700 mm = 0.3 inserted
verdict("worth of the 400-700 mm band", None, band, 0, " pcm", "§3.3 reserves 250 pcm for the RR band")
wide = rr_integral(0.75) - rr_integral(0.25)
verdict("worth of a 250-750 mm band", 250.0, wide, 6, " pcm", "E1's suggested band matches the 250 pcm reservation")
drift_per_real_min = 3.0 / (24 * 60) * 360  # 3 pcm/EFPD at x360
verdict("burnup drift at x360", None, drift_per_real_min, 0, " pcm per real minute")
print(f"  mid-band to edge = {band / 2:.0f} pcm -> {band / 2 / drift_per_real_min:.0f} real minutes "
      f"(spec §10.5 says about 20 min)")
print(f"  with the intended 250 pcm band: {wide / 2 / drift_per_real_min:.0f} real minutes")

# ---------------------------------------------------------------- 13. dump tank (E1 #3)
print("\n13. SECONDARY DUMP TANK  (§5.1: 400 t inventory, 450 m3 tank)")
for T in (200.0, 320.0, 420.0, 520.0):
    v = 400e3 / rho_na(K(T))
    print(f"  400 t at {T:5.1f} C occupies {v:6.1f} m3  ({v / 450 * 100:5.1f} % of the 450 m3 tank)")
print("  => cold (200 C idle setpoint) it just fits at 98 %; drained hot it does not. E1 is right.")

# ---------------------------------------------------------------- 14. part-load rows vs turbine minimum (E1 #7)
print("\n14. PART-LOAD PROGRAM vs TURBINE MINIMUM STABLE LOAD  (§9.2 table, §7.1: 30 % = 150 MWe, trip below 420 C hot reheat)")
rows = [(100, 1000), (80, 783), (60, 573), (40, 371), (30, 273), (20, 178), (10, 86), (5, 42)]
for pct, mwe in rows:
    per_two, per_one = mwe / 2, mwe
    note = []
    if per_one < 150:
        note.append("below minimum even on ONE turbine")
    elif per_two < 150:
        note.append("below minimum if both turbines are online")
    print(f"  {pct:3d} %FP: {mwe:4d} MWe gross -> {per_two:5.1f} MWe each on two, {per_one:5.1f} on one   {'; '.join(note)}")
print("  main steam at the 10 % and 5 % rows is 408 and 401 C; §7.1 trips the turbine below 420 C hot reheat,")
print("  and hot reheat is below main steam. So those rows cannot be run with a turbine online. E1 is right.")

# ---------------------------------------------------------------- 15. hottest assembly outlet (E1 #8)
print("\n15. HOTTEST ASSEMBLY OUTLET  (§2.4 says 580-585 C; §2.5 T_out = 375 + 183.7 (p/f) (P/Q))")
for zone, f in (("I (rings 0-5)", 1.12), ("II (rings 6-8)", 1.00), ("III (rings 9-10)", 0.92)):
    for p in (1.20, 1.05):
        print(f"  zone {zone:16} f = {f:.2f}, p = {p:.2f}: T_out = {375 + 183.7 * p / f:.1f} C")
print("  the spec's own file-20 calc used f = 1.08 (inner) and 0.925 (outer), giving 579 and 583 C,")
print("  which is where 580-585 came from; those flow factors are not the §2.5 zone factors (finding F11/D-013).")

# ---------------------------------------------------------------- 16. natural circulation formula (E3 #5)
print("\n16. NATURAL-CIRCULATION FORMULA  (§4.2: Q_nc = 3.5 % x (P / 1 %FP)^(1/3))")
for p in (100, 10, 1):
    print(f"  at P = {p:3d} %FP, as written: {3.5 * (p / 1) ** (1 / 3):6.2f} % rated flow; "
          f"with (P/100 %FP): {3.5 * (p / 100) ** (1 / 3):5.2f} %")
print("  => as written the formula gives 16 % flow at full power, which is not 'natural circulation with no pumps'.")
print("     E3 is right that the intended form is (P / 100 %FP)^(1/3), i.e. 3.5 % at full power. E5 called it")
print("     'a reasonable order-of-magnitude fit', which only holds for the corrected form.")

# ---------------------------------------------------------------- 17. house load (E3 #6)
print("\n17. HOUSE LOAD vs LISTED MOTOR RATINGS  (§1.1: ~65 MWe house load)")
motors = [("4 main feed pumps", 4, 9.8), ("3 primary pumps", 3, 4.0), ("3 secondary pumps", 3, 2.5), ("4 CW pumps", 4, 3.7)]
total_rating = sum(n * p for _, n, p in motors)
print("  nameplate motor ratings:")
for name, n, p in motors:
    print(f"    {name:20} {n} x {p:4.1f} MW = {n * p:5.1f} MW")
print(f"    total {total_rating:.1f} MW of nameplate rating alone")
shaft = 4 * 9.8 + 3 * 3.3 + 3 * 2.0 + 4 * 3.7
print(f"  using SHAFT powers where the spec gives them (primary 3.3, secondary 2.0): {shaft:.1f} MW")
print(f"  => even on shaft power the four biggest auxiliary groups are {shaft:.0f} MW of the {65:.0f} MWe house load,")
print("     leaving ~5 MW for condensate pumps, heaters, sodium services, HVAC and losses. Too tight: E3 is right")
print("     that the electrical balance needs to be stated explicitly.")

# ---------------------------------------------------------------- 18. amplitude update lag (E1, E6)
print("\n18. AMPLITUDE UPDATE ACCURACY  (§14.2 snippet uses the previous step's n in the precursor update)")
def growth(scheme, rho_frac, dt=0.1, steps=2000):
    rho = rho_frac * BETA_SUM / 1e5
    beta = [b / 1e5 for b in BETA]
    bsum = sum(beta)
    s = list(beta)  # n0 = 1
    n = 1.0
    e = [math.exp(-l * dt) for l in LAMBDA]
    w = [(1 - ei) - (1 - ei - l * dt * ei) / (l * dt) for ei, l in zip(e, LAMBDA)]
    hist = []
    logscale = 0.0  # the equations are linear: rescale periodically so n cannot overflow
    for k in range(steps):
        if n > 1e100:
            s = [si / n for si in s]
            logscale += math.log(n)
            n = 1.0
        if scheme == "spec":  # s_i = s_i e + beta_i n_old (1 - e), then n = sum s / (beta - rho)
            s = [si * ei + bi * n * (1 - ei) for si, ei, bi in zip(s, e, beta)]
            n = sum(s) / (bsum - rho)
        elif scheme == "implicit":  # E6's fully implicit form
            s = [si * ei for si, ei in zip(s, e)]
            n = sum(s) / (sum(bi * ei for bi, ei in zip(beta, e)) - rho)
            s = [si + bi * n * (1 - ei) for si, bi, ei in zip(s, beta, e)]
        else:  # D-015: n linear across the step (what Kallskar implements)
            num = sum(si * ei + bi * n * (1 - ei - wi) for si, ei, bi, wi in zip(s, e, beta, w))
            n1 = num / (bsum - rho - sum(bi * wi for bi, wi in zip(beta, w)))
            s = [si * ei + bi * (n * (1 - ei - wi) + n1 * wi) for si, ei, bi, wi in zip(s, e, beta, w)]
            n = n1
        hist.append(logscale + math.log(n))
    # asymptotic period from the second half of the run
    i0, i1 = steps // 2, steps - 1
    return (i1 - i0) * dt / (hist[i1] - hist[i0])

for frac in (0.5, 0.8, 0.9):
    exact = period_for(frac * BETA_SUM)
    print(f"  rho = {frac:.1f} beta ({frac * BETA_SUM:.0f} pcm), exact inhour period {exact:.4f} s:")
    for scheme, label in (("spec", "spec §14.2 snippet"), ("implicit", "fully implicit (E6)"), ("linear", "linear-n (D-015, implemented)")):
        T = growth(scheme, frac)
        print(f"    {label:32} period {T:.4f} s  ({(exact / T - 1) * 100:+6.1f} % growth-rate error)")

# ---------------------------------------------------------------- 19. P/Q during a pump trip with RB-2 (E6)
print("\n19. P/Q DURING A PRIMARY PUMP TRIP WITH RB-2  (§4.2 coastdown, §9.5 trip at 1.12, RB-2 = 60 %/min)")
print("   flow = (2 + 1/(1 + t/10)) / 3 while the flap valve is open; power falls at 1 %FP/s once RB-2 acts")
worst = 0
for t in range(0, 41, 2):
    f = (2 + 1 / (1 + t / 10)) / 3
    p = max(0.4, 1 - 0.01 * t)
    pq = p / f
    worst = max(worst, pq)
    seated = 2 / 3
    if t in (0, 2, 4, 6, 8, 10, 15, 20, 30, 40):
        print(f"    t = {t:2d} s: flow {f * 100:5.1f} %, power {p * 100:5.1f} %, P/Q = {pq:.3f}"
              f"   (if the check valve had already seated: {p / seated:.3f})")
print(f"  peak P/Q with the valve open: {worst:.3f} vs alarm 1.05 and trip 1.12 -> alarms but does not trip")
print("  => E6's '>98 % power at 8 s' assumes the shims start nearly withdrawn. At BOC the shims hold about")
print(f"     {excess - band / 2:.0f} pcm, i.e. mid-stroke, where bank A gives {diff_worth(2400, 0.5) * 10:.0f} pcm/s at the 10 mm/s")
print("     runback speed — far more than the ~6 pcm/s needed for 60 %/min. The real risk is the check-valve step,")
print("     which takes flow to 2/3 and P/Q above the trip unless the surviving pumps ramp up. Spec should say when it seats.")

# ---------------------------------------------------------------- 20. splitter table addition (E2)
print("\n20. SPLITTER TABLE TOTAL  (§6.5 'Loop 2 all to B' row: 333 + 311 vs 645 MWe)")
print("  the spec's own file-20 calc prints A 333 MWe, B 311 MWe, total 645 — the parts are rounded down from")
print("  333.x and 311.x, so the rounded total is 645 while the rounded parts sum to 644. Presentation, not an error.")

# ---------------------------------------------------------------- 21. steam mass balance (E3 #11)
print("\n21. STEAM MASS BALANCE  (§5.1/§6: 291.7 kg/s per SG, §7.1: 437.5 kg/s per turbine)")
verdict("3 SGs vs 2 turbines", 2 * 437.5, 3 * 291.7, 0.5, " kg/s")

print("\n" + "=" * 108)
