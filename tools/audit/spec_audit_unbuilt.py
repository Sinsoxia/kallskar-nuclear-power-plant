"""
Kallskar: audit of the spec sections the code has not reached yet.

Scope: sections 5-8 and 10-13 and file 16 (except Appendix A) of KALLSKAR_ALL_IN_ONE.txt, plus the cross-references
from those sections into sections 0-4 and 9.1-9.6. Every number is recomputed from the spec's own primitives:
- Appendix A sodium correlations (Fink-Leibowitz), as file 20 uses them;
- IAPWS-IF97 steam and water (the iapws package, which file 20 names);
- TEOS-10 seawater (the gsw package) for the site's brackish water, "about 5 psu" (section 1.4);
- the spec's own file-20 calc.py, which this script cuts out of the spec text and runs unmodified.

Every check prints PASS or FAIL with an ID. C-xx are the findings in docs/audit/SPEC_AUDIT_UNBUILT.md, K-xx the checks
that came out consistent, P-xx errors in the earlier audit documents. A FAIL on a C or P check means the finding
reproduces. Unless a line says otherwise, a tolerance is half a unit in the last printed digit of the spec figure.
Every quoted spec line is checked against KALLSKAR_ALL_IN_ONE.txt before anything else runs, so the line numbers in the
report cannot drift silently.

Run:      python tools/audit/spec_audit_unbuilt.py > tools/audit/spec_audit_unbuilt.out.txt
Requires: pip install iapws numpy gsw
"""
import contextlib
import io
import math
import os
import re
import sys

import gsw

sys.stdout.reconfigure(encoding="utf-8")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEC_PATH = os.path.join(ROOT, "KALLSKAR_ALL_IN_ONE.txt")
with open(SPEC_PATH, encoding="utf-8") as fh:
    LINES = fh.read().splitlines()

RESULTS = []  # (id, ok)
CITE_ERRORS = []


def cite(line, text):
    """Return 'L<line>' after checking that the spec line really contains the quoted text."""
    if text not in LINES[line - 1]:
        hits = [i + 1 for i, l in enumerate(LINES) if text in l]
        CITE_ERRORS.append(f"L{line} does not contain {text!r}; found at {hits}")
    return f"L{line}"


def check(cid, label, ok, detail=""):
    RESULTS.append((cid, bool(ok)))
    print(f"  [{'PASS' if ok else 'FAIL'}] {cid} {label}")
    for d in detail.split("\n") if detail else []:
        print(f"         {d}")
    return ok


def near(cid, label, computed, printed, tol, unit="", basis="printed rounding"):
    ok = abs(computed - printed) <= tol + 1e-12
    return check(cid, f"{label}: computed {computed:,.4g}{unit} vs spec {printed:,.6g}{unit} (tolerance ±{tol:g}, "
                      f"{basis})", ok)


def section(title):
    print("\n" + "=" * 116)
    print(title)
    print("=" * 116)


# ================================================================================================= file-20 calc.py
start = next(i for i, l in enumerate(LINES) if l.startswith("SCRIPT SOURCE: calc.py")) + 2
stop = next(i for i, l in enumerate(LINES) if l.startswith("CONDENSER LINEUP SNIPPET")) - 1
snip0 = stop + 3
CALC_SRC = "\n".join(LINES[start:stop])
SNIP_SRC = "\n".join(LINES[snip0:snip0 + 6])
F20 = {}
_buf = io.StringIO()
with contextlib.redirect_stdout(_buf):
    exec(CALC_SRC, F20)
    exec(SNIP_SRC, F20)
CALC_OUT = _buf.getvalue()

S, ts, hf, dh, rho_na, cp_na = F20["S"], F20["ts"], F20["hf"], F20["dh"], F20["rho"], F20["cp"]
CYC = F20["c"]
ML = F20["ml"]  # steam per loop, kg/s
MT = F20["mt"]  # steam per turbine, kg/s
MNA = F20["mna"]  # secondary sodium per loop, kg/s
QT = F20["Qt"]  # SG heat per turbine, MWt
TRH, LIM = F20["Trh"], F20["lim"]
UA_RH, CNA_RH, CPS_RH = F20["UA"], F20["Cna"], F20["cps"]

# ================================================================================================= spec primitives
GRID = 12.0  # §0.2 grid clock
SLOW = 360.0  # §0.2 slow processes
LOOP_FLOW = 3112.0  # kg/s, §5.1
SECTIONS = 8  # §6.1
PRIMARY_FLOW = 10694.0  # kg/s, §1.1 / §4.2
BETA = [8.8, 71.3, 66.6, 131.8, 61.6, 20.2]  # pcm, §3.1
LAMBDA = [0.0130, 0.0315, 0.135, 0.345, 1.37, 3.82]  # 1/s, §3.1
BETA_SUM = sum(BETA)
T0_COND = ts(0.005) + 273.15  # heat-rejection temperature at the 5.0 kPa rating point, K

print("KALLSKAR SPEC AUDIT: SECTIONS THE CODE HAS NOT REACHED (5-8, 10-13, FILE 16)")
print(f"spec: {os.path.relpath(SPEC_PATH, ROOT)}, {len(LINES)} lines")
print(f"file-20 calc.py cut from spec lines {start + 1}-{stop} and run unmodified: SG heat per turbine {QT:.2f} MWt, "
      f"steam {MT:.2f} kg/s per turbine, {ML:.2f} kg/s per loop, sodium {MNA:.1f} kg/s per loop")

# ================================================================================================= section 5
section("§5 SECONDARY SODIUM LOOPS  (lines 1186-1233)")
cite(1194, "3,112 kg/s (3.65 m³/s)")
v_mean = LOOP_FLOW / rho_na(420)
v_pump = LOOP_FLOW / rho_na(320)
near("K-01", f"§5.1 {cite(1194, '3.65')} volumetric flow at the 420 °C loop mean (file 20: rho(420))", v_mean, 3.65, 0.005,
     " m³/s")
print(f"         at the 320 °C cold-leg pump the same flow is {v_pump:.3f} m³/s; the spec does not name the temperature")
A_DN900 = math.pi * 0.45 ** 2
near("K-02", f"§5.1 {cite(1196, '5.9 m/s')} hot-leg velocity, DN900 at 520 °C", LOOP_FLOW / rho_na(520) / A_DN900, 5.9,
     0.05, " m/s")
t_hot = 180 * A_DN900 * rho_na(520) / LOOP_FLOW
t_cold = 180 * A_DN900 * rho_na(320) / LOOP_FLOW
near("K-03a", f"§5.1 {cite(1197, 'Hot leg 31 s')} hot-leg delay, 180 m", t_hot, 31, 0.5, " s")
near("K-03b", f"§5.1 {cite(1197, 'cold leg 32 s')} cold-leg delay, 180 m", t_cold, 32, 0.5, " s")
lap_lo = t_hot + t_cold + (41 - 0.5) + (17 - 0.5) + (5 - 0.5)
lap_hi = t_hot + t_cold + (41 + 0.5) + (17 + 0.5) + (5 + 0.5)
check("K-04", f"§5.1 {cite(1198, 'one lap ≈ 125 s')} lap ≈ 125 s: legs computed, SG 41 + buffer 17 + IHX 5 each ±0.5 give "
               f"{lap_lo:.1f}-{lap_hi:.1f} s", lap_lo <= 125 <= lap_hi,
      f"the printed parts sum to 126 s; within the parts' own rounding 125 is reachable")
flowing = (t_hot + t_cold + 41 + 17 + 5) * LOOP_FLOW / 1000
check("K-05", f"§5.1 {cite(1199, '≈ 400 t')} inventory ≈ 400 t is at least the flowing inventory {flowing:.0f} t "
               f"(residence times × flow)", 400 >= flowing,
      f"the remaining {400 - flowing:.0f} t sits in plena, buffer-tank heel and dead legs, which the spec does not size")
eta_sp = v_pump * 0.45 / 2.0
check("K-06", f"§5.1 {cite(1200, '2.0 MW shaft')} pump 0.45 MPa × {v_pump:.3f} m³/s / 2.0 MW shaft = efficiency "
               f"{eta_sp:.3f}; file 20 uses 0.80, the primary pumps 0.82", abs(eta_sp - 0.80) < 0.005)
p = dict(buffer=0.30, discharge=0.75, ihx_in=0.72, ihx_out=0.62, sg_in=0.55, sg_out=0.32)
cite(1202, "Buffer tank gas 0.30 MPa")
drops = (p["discharge"] - p["ihx_in"]) + (p["ihx_in"] - p["ihx_out"]) + (p["ihx_out"] - p["sg_in"]) + \
        (p["sg_in"] - p["sg_out"]) + (p["sg_out"] - p["buffer"])
check("K-07", f"§5.1 {cite(1203, 'SG outlet 0.32')} buffer 0.30 + head 0.45 = discharge 0.75 MPa, and the loop drops sum "
               f"to {drops:.2f} MPa = the head", abs(p["buffer"] + 0.45 - p["discharge"]) < 1e-9 and abs(drops - 0.45) < 1e-9)
g = 9.80665
h_max = (p["ihx_out"] - 0.4 - 0.120) * 1e6 / (rho_na(550) * g)
check("K-08", f"§4.3 {cite(1145, '≥ 0.4 MPa above primary')} with §5.1 IHX outlet 0.62 MPa and §4.4 cover gas 0.120 MPa, "
               f"the 0.4 MPa margin holds wherever the IHX outlet sits less than {h_max:.1f} m below the hot-pool surface",
      h_max > 0, "the vessel is 14.5 m high (§4.1); the IHX nozzle elevations are not given, so this is a bound")

# trace heating vs the 180 °C floor and the plugging temperature
cite(1207, "alarm below 150 °C")
cite(1673, "No sodium that is meant to stay liquid goes below 180 °C")
cite(1208, "alarm 160 °C")
check("C-01", "§5.1 trace-heating low alarm 150 °C is at or above §9.1's 180 °C floor and above the 160 °C plugging alarm",
      150 >= 180 and 150 > 160,
      "alarm 150 < floor 180: a filled loop can sit at 150-180 °C, breaking §9.1, with no alarm\n"
      "alarm 150 < plugging alarm 160: sodium can run below its own plugging temperature (oxide precipitates in the\n"
      "coldest pipe) with neither alarm raised; the cold traps themselves run below 180 °C by design (§4.6 wall 125 °C)")

# hydrogen signal
cite(1226, "+0.28 ppm at its section outlet meter")
cite(1226, "+0.036 ppm at the")
H_FRAC = 2 * 1.008 / (2 * 1.008 + 15.999)  # IUPAC conventional atomic weights
sec_flow = LOOP_FLOW / SECTIONS
ppm_sec = 1e-3 * H_FRAC / sec_flow * 1e6
near("C-02", "§5.2 1 g/s water leak, all its hydrogen dissolved in the section's sodium "
              f"({sec_flow:.1f} kg/s): section meter", ppm_sec, 0.28, 0.005, " ppm")
near("K-09", "§5.2 loop outlet meter = section/8 with the same hydrogen", ppm_sec / SECTIONS, 0.036, 0.0005, " ppm",
     "printed rounding; §12.4 'an eighth of the size'")
print(f"         the spec's own pair gives 0.036/0.28 = 1/{0.28 / 0.036:.2f}; 0.036 matches the full-hydrogen value "
      f"{ppm_sec / 8:.4f}, the section figure is truncated")
small = 0.05 * ppm_sec
check("K-10", f"§5.2 smallest 'small' leak 0.05 g/s gives {small:.4f} ppm = {small / 0.003:.1f} × the ±0.003 ppm meter "
               f"noise (§10.5 {cite(2194, '±0.003 ppm')}), so 'section meter within minutes' is plausible", small > 3 * 0.003)
check("K-11", f"§5.2 {cite(1230, '1.2 MPa')} rupture discs at 1.2 MPa lie above the highest normal secondary pressure "
               "(pump discharge 0.75 MPa)", 1.2 > 0.75)

# clocks: hydrogen drift and impurity ingress
cite(403, "impurity ingress, cold trap loading, hydrogen drift, heater failures")
cite(1228, "±0.01 ppm per grid day")
cite(2429, "Impurity ingress 0.2 kg per grid day")
fill_grid_h = 150 / 0.2 * 24 / GRID
fill_slow_h = 150 / 0.2 * 24 / SLOW
h30_grid = 0.01 * 0.5 * GRID / 24
h30_slow = 0.01 * 0.5 * SLOW / 24
check("C-03", "§5.2 hydrogen drift and §12.3 impurity ingress are stated per GRID day, §0.2 puts both on the ×360 clock",
      abs(fill_grid_h / fill_slow_h - 1) < 0.1,
      f"cold trap 0 -> 150 kg: {fill_grid_h:,.0f} h real on the grid clock, {fill_slow_h:,.0f} h real on ×360 (30× apart)\n"
      f"hydrogen drift in 30 real min: {h30_grid:.4f} ppm on the grid clock (below the ±0.003 ppm noise), "
      f"{h30_slow:.3f} ppm on ×360\n"
      f"(×360 drifts more than the whole 0.06 ppm full-power background, §5.2, in half an hour)")

# pump heat in the heat balance
cite(3037, "Reactor thermal = SG total minus 10.5 MW")
cite(1119, "3.3 MW shaft")
cite(1173, "0.3 MW loss per loop")
sg_total = 2 * QT
shaft = 3 * 3.3 + 3 * 2.0
net_in = shaft - 4 * 0.3
check("C-04", f"file 20 nets 10.5 MW of pump heat; the spec's pumps put {shaft:.1f} MW of shaft power into sodium "
               f"(3 × 3.3 primary, 3 × 2.0 secondary) and DRACS standby takes 1.2 MW out: net {net_in:.1f} MW",
      abs(net_in - 10.5) <= 0.5,
      f"SG total {sg_total:.1f} MWt - 10.5 = {sg_total - 10.5:.1f} MWt (calc prints 2379); with {net_in:.1f} MW it is "
      f"{sg_total - net_in:.1f} MWt against §1.1's canonical 2,380\n"
      f"no stated heat loss accounts for the {net_in - 10.5:.1f} MW; the secondary pumps' heat appears nowhere")

# ================================================================================================= section 6
section("§6 STEAM GENERATORS, SPLITTER, REHEAT  (lines 1235-1379)")
q_ev, q_sh, q_rh = F20["Qev"], F20["Qsh"], F20["Qr"]
cite(1246, "99.5 MWt: EV 62.6, SH 21.2, RH 15.7")
check("K-12a", f"§6.1 section duty 62.6 + 21.2 + 15.7 = {62.6 + 21.2 + 15.7:.1f} MWt", abs(62.6 + 21.2 + 15.7 - 99.5) < 1e-9)
for name, q, sec_p, loop_p in (("EV", q_ev, 62.6, 501), ("SH", q_sh, 21.2, 170), ("RH", q_rh, 15.7, 125)):
    ok = abs(q / 8 - sec_p) <= 0.05 and abs(q - loop_p) <= 0.5
    check("K-12b", f"§6.1 {cite(1247, 'EV 501, SH 170, RH 125')} {name}: file 20 gives {q:.2f} MWt per loop, {q / 8:.3f} per "
                    f"section vs spec {loop_p} / {sec_p}", ok)
split_sh = q_sh / (q_sh + q_rh)
near("K-13a", f"§6.1 {cite(1248, '57.6% SH')} sodium split to SH (same 520->445 °C range on both)", split_sh * 100, 57.6,
     0.05, " %")
near("K-13b", "§6.1 SH/RH mixed sodium temperature (file 20 Tmid)", F20["Tmid"], 445, 0.5, " °C")
near("K-14a", f"§6.1 {cite(1250, 'Feed 36.5 kg/s')} feed per section = steam per loop / 8", ML / 8, 36.5, 0.05, " kg/s")
near("K-14b", f"§6.1 {cite(1252, '31.9 kg/s')} reheat steam per section", ML / 8 * CYC["mrh"], 31.9, 0.05, " kg/s")
near("K-14c", f"§7.1 {cite(1401, 'reheat flow 87.4% of main steam')} reheat fraction", CYC["mrh"] * 100, 87.4, 0.05, " %")
near("K-15", f"§6.1 {cite(1250, '355 °C (15 K')} EV outlet superheat at 14.6 MPa", 355 - ts(14.6), 15, 0.5, " K")


def pinch_at(pb):
    q_sub = ML * (hf(pb) - CYC["hfw"]) / 1e3
    lo, hi = 320.0, 520.0
    for _ in range(80):
        mid = (lo + hi) / 2
        if MNA * dh(320, mid) / 1e3 < q_sub:
            lo = mid
        else:
            hi = mid
    return mid, ts(pb), mid - ts(pb)


cite(1253, "≈ 20 K where boiling starts (sodium 360 °C, saturation 340 °C)")
na14, sat14, p14 = pinch_at(14.6)
na16, sat16, p16 = pinch_at(16.0)
check("C-05", f"§6.1 pinch ≈ 20 K: with boiling onset at the EV OUTLET pressure 14.6 MPa: Na {na14:.1f} vs sat {sat14:.1f} "
               f"-> {p14:.1f} K; at the inlet pressure 16.0 MPa: Na {na16:.1f} vs sat {sat16:.1f} -> {p16:.1f} K",
      p16 >= 19.5,
      "boiling starts upstream of the outlet, where pressure lies between 16.0 and 14.6 MPa, so the pinch is "
      f"{p16:.1f}-{p14:.1f} K;\n'≈ 20 K' (19.5-20.5) is the upper end, reached only if the whole 1.4 MPa drop comes before boiling")
near("K-16a", f"§6.1 {cite(1257, 'Loop capacity −12.5%')} one section of eight", 100 / 8, 12.5, 0.05, " %")
near("K-16b", f"§6.1 {cite(1257, 'reactor −4.2 %FP')} one section of 24", 100 / 24, 4.2, 0.05, " %FP")
check("K-17", f"§6.2 {cite(1268, '3 × 35% per SG')} safety valves 3 × 35 % = 105 % ≥ 100 %; SG outlet 14.0 < relief 15.2 < "
               "safety 15.8 MPa", 3 * 35 >= 100 and 14.0 < 15.2 < 15.8)
near("K-18", f"§7.2 {cite(1446, 'Normal: 166 K')} main-steam superheat at the stop valve, 500 °C at 13.5 MPa",
     500 - ts(13.5), 166, 0.5, " K")

# splitter throttling loss vs the second law
cite(1277, "Fully open 0.10 MPa at full branch flow")
cite(1278, "about 6 MWe on that branch")
m_branch = ML / 2
worst = 0.0
for p_up, p_dn in ((14.0 + 0.7, 14.0), (13.7 + 0.8, 13.7), (14.0, 14.0 - 0.8)):
    h = S(P=p_up, T=505).h
    ds = S(P=p_dn, h=h).s - S(P=p_up, T=505).s
    worst = max(worst, m_branch * T0_COND * ds / 1e3)
check("C-06", f"§6.3 throttling a {m_branch:.1f} kg/s branch by 0.7-0.8 MPa costs 'about 6 MWe'; the Gouy-Stodola "
               f"bound m·T0·Δs (T0 = {T0_COND:.1f} K, the 5.0 kPa condenser) is at most {worst:.2f} MW",
      6 <= worst,
      f"an isenthalpic throttle cannot destroy more work than m·T0·Δs; even all of loop 2 through one branch loses "
      f"{2 * worst:.2f} MW\nthe steam has nowhere else to go in reactor-leads mode, so the flow does not fall")

# reheat nudge from isolating one SG2 section (file 20's own reheater model)
cite(1299, "about 2 K in each direction")
mrh = CYC["mrh"]


def trh_c(m, cna):
    c_s = m * CPS_RH
    cmin = min(c_s, cna)
    cr = cmin / max(c_s, cna)
    e = math.exp(-UA_RH / cmin * (1 - cr))
    ep = (1 - e) / (1 - cr * e)
    return CYC["T3"] + ep * cmin / c_s * (520 - CYC["T3"])


nudges = []
print("         C-07 inputs, file 20's reheater model (UA, sodium capacity and steam cp per module from calc.py):")
for label, cna2 in (("sodium per module fixed (file 20)", CNA_RH), ("SG2 sodium redistributed ×8/7", CNA_RH * 8 / 7)):
    l2 = ML * 7 / 8
    ma, mb = mrh * (ML + 0.5 * l2), mrh * (0.5 * l2)
    a1 = (8 * trh_c(ma / 11, CNA_RH) + 3 * trh_c(ma / 11, cna2)) / 11 - 505
    b1 = trh_c(mb / 4, cna2) - 505
    a2 = (8 * trh_c(ma / 12, CNA_RH) + 4 * trh_c(ma / 12, cna2)) / 12 - 505
    b2 = trh_c(mb / 3, cna2) - 505
    nudges += [a1, b1, a2, b2]
    print(f"         {label}: isolate an A-side SG2 section -> A {a1:+.1f} K, B {b1:+.1f} K; "
          f"a B-side one -> A {a2:+.1f} K, B {b2:+.1f} K")
check("C-07", "§6.4 isolating one SG2 section at a 50/50 split moves each hot reheat by 'about 2 K' "
               f"(taken as |ΔT| ≤ 2.5 K); largest move {max(abs(x) for x in nudges):.1f} K",
      max(abs(x) for x in nudges) <= 2.5,
      "turbine A has 12 reheater modules and moves about 2 K; turbine B has 4 and moves 5.6-8.6 K")

# §6.5 table re-run and the load-limit reading point
print("         file 20's §6.5 table (re-run):")
for line in CALC_OUT.splitlines():
    if line.startswith(" sB="):
        print("         " + line.strip())
table = {0.5: (500, 505, 167, 505, 100, 667), 0.6: (467, 508, 198, 495, 100, 665), 0.7: (433, 511, 229, 484, 94, 662),
         0.8: (400, 513, 259, 473, 83, 659), 0.9: (367, 516, 288, 462, 72, 655), 1.0: (333, 517, 311, 452, 62, 645)}
cite(1309, "Turbine A (MWe): 500")
cite(1346, "Turbine B (MWe): 311, capped by reheat; 6 MWe to bypass")
ok_all = True
rows = {}
for sb, (pa, ta, pb, tb, limb, tot) in table.items():
    ma, mb = ML * (2 - sb), ML * sb
    t_a, t_b = TRH(mrh * ma / 12), TRH(mrh * mb / 4)
    e_a = F20["cycle"](min(t_a, 505) - 5)["We"] / CYC["We"]
    e_b = F20["cycle"](min(t_b, 505) - 5)["We"] / CYC["We"]
    mwa = 500 * ma / MT * e_a
    mwb_s = 500 * mb / MT * e_b
    mwb = min(mwb_s, 500 * LIM(t_b))
    rows[sb] = (t_a, t_b, mwa, mwb_s)
    ok = (abs(mwa - pa) <= 0.5 and (abs(t_a - ta) <= 0.5 or sb == 0.9) and abs(mwb - pb) <= 0.5
          and abs(t_b - tb) <= 0.5 and abs(LIM(t_b) * 100 - limb) <= 0.5 and abs(mwa + mwb - tot) <= 1.0)
    ok_all &= ok
check("K-19", "§6.5 every A/B output, hot reheat and B load limit reproduced by file 20 (limit read at the SG outlet); "
               "totals within 1 MWe (parts rounded, SPEC_REVIEW_AUDIT #22); the 90 % row's A reheat is C-17", ok_all)
near("C-17", f"§6.5 {cite(1338, 'A hot reheat: 516 °C')} 90 % row, A hot reheat (file 20 prints 515.5 with one decimal)",
     rows[0.9][0], 516, 0.5, " °C")
cite(1356, "reactor to 50% or dump 146 kg/s")
near("K-20", "§6.5 'Trip B': dump = loop 2's B branch at 50/50", ML / 2, 146, 0.5, " kg/s")
cite(1411, "100% at ≥ 490 °C; 60% at 450 °C; 30% at 430 °C; trip below 420 °C")
cite(1402, "2.5 MPa, 500 °C")
cite(1449, "Hot reheat")
cite(1451, "Alarm: 480")
t_b100 = rows[1.0][1]
lim_ipsv = LIM(t_b100 - 5)
mwb_ipsv = min(rows[1.0][3], 500 * lim_ipsv)
plant_ipsv = rows[1.0][2] + mwb_ipsv
cols = [round(LIM(rows[s][1] - 5) * 100) for s in (0.5, 0.6, 0.7, 0.8, 0.9, 1.0)]
check("C-08", "§6.5 applies §7.1's reheat load limit to the SG-outlet reheat temperature (505 °C normal); §7.1/§7.2 give "
               "hot reheat at the IP stop valve (500 °C normal). The two readings agree only if they are the same point",
      False,
      f"read at the IP stop valve (SG outlet - 5 K, as file 20's cycle() assumes) the B limit column is {cols} % instead of "
      f"[100, 100, 94, 83, 72, 62] %\nthe 100 % row becomes B {mwb_ipsv:.0f} MWe, plant {plant_ipsv:.0f} MWe "
      f"(spec 311 and 645), and {rows[1.0][3] - mwb_ipsv:.0f} MWe to bypass instead of 6")
cite(1317, "A hot reheat: 508 °C")
cite(1818, "Holds: Hot reheat ≤ 505 °C")
check("C-09", f"§6.5 60 % row: A hot reheat {rows[0.6][0]:.1f} °C carries no 'spraying' note although §9.4's attemperation "
               "auto holds ≤ 505 °C; the 70-100 % rows print >505 °C 'spraying'", rows[0.6][0] <= 505,
      "the column is the reheater-module outlet before the sprays; file 20 credits the cycle with min(T, 505)")
near("K-21", f"§6.6 {cite(1373, '73 kg/s per SG')} minimum evaporator flow 25 %", 0.25 * ML, 73, 0.5, " kg/s")
check("K-22", f"§6.6 {cite(1376, 'EV flow below 20%')} density-wave threshold 20 % lies below the 25 % minimum flow",
      20 < 25)

# water admission interlock
cite(1375, "Sodium ≥ 250 °C; feed temperature ≥ sodium − 80 K")
cite(1545, "170 + 70 × (P/100)^0.6")
rows92 = [(100, 320, 520), (80, 320, 520), (60, 320, 520), (40, 320, 520), (30, 334, 484), (20, 348, 448), (10, 361, 411),
          (5, 364, 404)]
fails = []
for pwr, cold, hot in rows92:
    feed = 170 + 70 * (pwr / 100) ** 0.6
    if feed < cold - 80:
        fails.append(f"{pwr}%: feed {feed:.0f} < {cold}-80 = {cold - 80}")
feed0 = 170 + 70 * 0 ** 0.6
check("C-10", "§6.6 water-admission interlock 'feed ≥ sodium - 80 K' against §7.5's feed temperatures and §9.2's SG "
               "sodium OUTLET (the most lenient reading)", not fails,
      "fails at " + "; ".join(fails) + "\n"
      f"read at the SG sodium inlet it fails at every row (100 %: 240 < 440)\n"
      f"at hot standby (375 °C) water needs feed ≥ 295 °C; with feed {feed0:.0f}-180 °C admission is possible only with SG "
      f"sodium in 250-{180 + 80} °C")

# header pressure vs turbine auto
cite(1263, "header 13.7 MPa")
cite(1824, "Header 13.5 ±0.2 MPa")
check("C-11", "§6.2 header 13.7 MPa at 100 % against §9.4 turbine auto 'header 13.5 ±0.2 MPa' (13.5 is §6.2's stop-valve "
               "pressure)", round(13.7 - 13.5, 6) < 0.2,
      "the normal header sits exactly on the edge of the auto band; bypass auto (§9.4 'header + 0.4') opens at 13.9 or "
      "14.1 MPa depending on which is meant")

# ================================================================================================= section 7
section("§7 TURBINE-GENERATORS, CONDENSERS, FEEDWATER  (lines 1390-1565)")
cite(1397, "590 MVA, 0.85 pf")
check("K-23a", f"§7.1 {cite(1397, '500 MWe gross')} 590 MVA × 0.85 pf = {590 * 0.85:.1f} MW ≥ the 500 MWe rating",
      590 * 0.85 >= 500)
near("K-23b", f"§7.1 {cite(1400, '1,575 t/h')} 437.5 kg/s in t/h", 437.5 * 3.6, 1575, 0.5, " t/h")
near("K-23c", f"§7.1 {cite(1401, '292 °C')} cold reheat temperature (file 20)", CYC["Tcr"], 292, 0.5, " °C")
near("K-23d", f"§7.1 {cite(1403, 'dryness 0.92')} LP exhaust dryness (file 20)", CYC["x"], 0.92, 0.005)
near("K-23e", f"§7.1 {cite(1404, '41.9% gross')} efficiency on SG heat (file 20)", 500 / QT * 100, 41.9, 0.05, " %")
near("K-23f", f"§7.1 {cite(1405, '30% (150 MWe)')} minimum stable load", 0.30 * 500, 150, 0, " MWe")
orders = [("speed", [3000, 3150, 3300]), ("condenser", [5.0, 10, 20]), ("hood (sprays 60)", [40, 60, 70, 90]),
          ("vibration", [2, 7.1, 11]), ("thrust", [0, 0.6, 1.0]), ("lube oil (falling)", [-0.15, -0.10, -0.07]),
          ("main steam temp (falling)", [-500, -480, -430]), ("superheat (falling)", [-166, -80, -50]),
          ("hot reheat (falling)", [-500, -480, -420])]
cite(1418, "Normal: 3,000 rpm")
check("K-24", "§7.2 every row is ordered normal < alarm < trip: " + ", ".join(n for n, _ in orders),
      all(all(a < b for a, b in zip(v, v[1:])) for _, v in orders))
cite(1457, "above 52 Hz")
cite(1617, "time-limited down to 47.5 Hz and up to 51.5 Hz")
check("C-12", "§7.2 generator trips 'above 52 Hz' while §8.4's time-limited range ends at 51.5 Hz (the low side matches: "
               "range 47.5, trip below 47.5 Hz for 20 s)", 52 <= 51.5,
      "51.5-52 Hz is neither a permitted band nor a trip")

# hot reheat alarm vs the §9.2 30 % row
cite(1718, "334 / 484")
reheat_max_ipsv = 484 - (505 - 500)
check("C-13", f"§7.2 hot-reheat alarm 480 °C is fixed (only main steam 'tracks program below 40%'); at §9.2's 30 % row the "
               f"reheat cannot exceed the 484 °C sodium, so at the IP stop valve it is ≤ {reheat_max_ipsv} °C",
      reheat_max_ipsv >= 480,
      "a standing hot-reheat alarm in a normal programme state; line loss 5 K from §6.1 505 °C vs §7.1 500 °C")

# 50 K in 10 min main-steam trip vs the programme
r25 = 25 / 40
ms25 = min(505, 375 + 145 * r25 - 15 * r25)
check("K-25", f"§7.2 {cite(1444, 'or a 50 K fall within 10 min')} main steam 40 % -> 25 %FP on §9.2's programme falls "
               f"{505 - ms25:.1f} K; at §7.1's 5 %/min that takes 3 min, inside the 50 K / 10 min trip",
      505 - ms25 < 50)

# house load vs minimum stable load
cite(1468, "one unit can run back to the plant's own house load")
cite(1469, "(≈ 65 MWe)")
cite(2690, "One unit to house load on bypass")
cite(1679, "Below about 25 %FP the turbines are off")
cite(1680, "bypass or house-load states")
check("C-14", f"§7.3 / S-28 house-load operation at ≈ 65 MWe = {65 / 500 * 100:.0f} % of a unit against §7.1's 30 % "
               "(150 MWe) minimum stable load", 65 >= 150,
      "§6.5 says a unit at 33 % is 'a hair above its 30% minimum load, where the next disturbance trips it'\n"
      "§9.2 says below 25 %FP 'the turbines are off' and in the same sentence calls those rows 'house-load states'")
bp_a = (65 / 500 + 0.60) * 437.5
bp_b = 0.60 * 437.5
check("K-26", f"§7.3 house-load steam balance: unit A {65 / 500:.2f} + 0.60 bypass = {bp_a:.0f} kg/s, tripped unit B's "
               f"bypass {bp_b:.0f} kg/s -> reactor must run back to ≤ {(bp_a + bp_b) / 875 * 100:.1f} %, as S-28 says",
      (bp_a + bp_b) / 875 < 1)

# condenser overload in S-05
cite(1464, "The condenser absorbs 60% bypass indefinitely at design cooling water")
cite(1465, "1 kPa per extra 10%")
cite(2530, "Condenser B overloaded, second trip")
need_alarm = 60 + (10 - 5.0) * 10
need_trip = 60 + (20 - 5.0) * 10
check("C-15", "S-05's poor-crew outcome 'Condenser B overloaded, second trip' needs condenser pressure to rise; the bypass is "
               "sized for 60 %, which §7.3 says the condenser absorbs indefinitely", need_alarm <= 60,
      f"by §7.3's rule the 10 kPa alarm needs {need_alarm:.0f} % bypass and the 20 kPa trip {need_trip:.0f} %; a tripped turbine "
      "sends its condenser nothing else")

# cooling water
cite(1478, "15.3 m³/s per unit, 11 K rise")
cite(1480, "690 MWt per unit")
cite(3101, "(4.0*11)")
cite(529, "about 5 psu")
SA = gsw.SA_from_SP(5.0, 0.0, 17.0, 61.5)
t_mean = 19 + 11 / 2
rho_sw = gsw.rho(SA, gsw.CT_from_t(SA, t_mean, 0.0), 0.0)
cp_sw = gsw.cp_t_exact(SA, t_mean, 0.0) / 1e3
q_cond = QT - 505
rise = q_cond * 1e3 / (15.3 * rho_sw * cp_sw)
flow11 = q_cond * 1e3 / (11 * rho_sw * cp_sw)
near("K-27", f"§7.4 CW rise at 15.3 m³/s with 5 psu water (TEOS-10: ρ {rho_sw:.1f} kg/m³, cp {cp_sw:.3f} kJ/kg·K)", rise,
     11, 0.5, " K")
check("C-16", f"§7.4 / file 20 CW flow: file 20 uses cp 4.0 kJ/kg·K and ρ 1025 kg/m³ (open-ocean water) for a 5 psu site",
      abs(cp_sw - 4.0) < 0.02 and abs(rho_sw - 1025) < 5,
      f"with the site's water, 11.0 K needs {flow11:.2f} m³/s (not 15.3); the printed pair (15.3 m³/s, 11 K) survives only "
      f"because 11 K is rounded ({rise:.2f} K)")
near("K-28a", f"§7.4 {cite(1479, '18 K rise')} one pump at 60 % flow", 11 / 0.6, 18, 0.5, " K")
near("K-28b", f"§1.1 {cite(465, 'circulating water 14.8')} four CW pumps × 3.7 MW", 4 * 3.7, 14.8, 0.05, " MW")
spec_tab = {(3, 2): (1.9, 514, 507), (3, 1): (3.0, 514, 510), (5, 2): (2.2, 514, 507), (5, 1): (3.4, 511, 507),
            (8, 2): (2.7, 514, 507), (8, 1): (4.1, 506, 502), (12, 2): (3.4, 511, 504), (12, 1): (5.1, 499, 496),
            (15, 2): (4.0, 506, 499), (15, 1): (6.1, 494, 491), (19, 2): (5.0, 500, 492), (19, 1): (7.5, 488, 484)}
cite(1494, "One pump: 3.0 kPa: 514 gross, 510 net")
ok_all = True
snip_rows = [l.split() for l in CALC_OUT.splitlines() if len(l.split()) == 5 and l.split()[0] in ("3", "5", "8", "12", "15", "19")]
for tin, pumps, pk, g, n in snip_rows:
    sp = spec_tab[(int(tin), int(pumps))]
    ok = abs(float(pk) - sp[0]) <= 0.05 + 1e-9 and abs(float(g) - sp[1]) <= 0.5 + 1e-9 and abs(float(n) - sp[2]) <= 0.5 + 1e-9
    ok_all &= ok
    if not ok:
        print(f"         mismatch {tin} °C {pumps} pump(s): calc {pk} kPa {g} {n} vs spec {sp}")
check("K-29", f"§7.4 all {len(snip_rows)} lineup rows (pressure, gross, net) reproduced by file 20's condenser snippet",
      ok_all and len(snip_rows) == 12)
dts = []
for tin, pumps in ((3, 2), (5, 2), (8, 2), (12, 2), (15, 2), (19, 2), (3, 1), (5, 1), (8, 1), (12, 1), (15, 1), (19, 1)):
    pk = spec_tab[(tin, pumps)][0]
    dts.append((pumps, ts(pk / 1000) - tin))
two = [d for p_, d in dts if p_ == 2]
one = [d for p_, d in dts if p_ == 1]
check("K-30", f"§7.4 condenser saturation minus intake is constant per lineup: both pumps {min(two):.1f}-{max(two):.1f} K, one "
               f"pump {min(one):.1f}-{max(one):.1f} K (fixed duty, fixed flow)",
      max(two) - min(two) < 0.8 and max(one) - min(one) < 0.8)
check("K-31", f"§7.4 winter {cite(1493, '514 gross')} per-unit peak 514 MWe × 2 = 1,028 (§1.1 {cite(462, '1,028')}), summer "
               "rating 500 at 19 °C", 2 * 514 == 1028)

# feed heaters
cite(1522, "66 °C")
heaters = [("LP1", 0.03, 66, 1522), ("LP2", 0.08, 91, 1525), ("LP3", 0.20, 117, 1528), ("LP4", 0.55, 152, 1531),
           ("HP6", 2.8, 227, 1540), ("HP7", 3.5, 240, 1543)]
for name, pr, tout, ln in heaters:
    cite(ln, f"{tout} °C")
    cid = "C-17" if name == "LP2" else "K-32"
    near(cid, f"§7.5 {name} outlet = Tsat({pr} MPa) - 3 K (file 20's terminal difference)", ts(pr) - 3, tout, 0.5, " °C",
         "printed rounding" + ("; 90.485 prints as 90.5 at one decimal, then 91" if name == "LP2" else ""))
near("K-32", f"§7.5 {cite(1534, '180 °C at 1.0 MPa')} deaerator saturation at 1.0 MPa", ts(1.0), 180, 0.5, " °C")
t_da = 250 / (437.5 / S(P=1.0, x=0).rho) / 60
near("K-33", f"§7.5 {cite(1534, '250 m³ storage ≈ 8 min')} deaerator storage at full feed", t_da, 8, 0.5, " min")
ok = all(abs(170 + 70 * (pw / 100) ** 0.6 - f) <= 0.5 for pw, f in
         ((100, 240), (80, 231), (60, 222), (40, 210), (30, 204), (20, 197), (10, 188), (5, 182)))
check("K-34", f"§7.5 {cite(1545, 'Feed temperature at part load')} formula reproduces all eight §9.2 feed temperatures", ok)
cite(1554, "2 main pumps 481 kg/s; with the startup pump 612 kg/s")
near("K-35a", "§7.6 2 × 55 % of 437.5 kg/s", 2 * 0.55 * 437.5, 481, 0.5, " kg/s")
near("K-35b", "§7.6 plus one 30 % startup pump", (2 * 0.55 + 0.30) * 437.5, 612, 0.5, " kg/s")
near("K-35c", f"§7.6 {cite(1558, '583 kg/s')} train A feeding SG1 and all of SG2", 2 * ML, 583, 0.5, " kg/s")
cite(1559, "Turbine A can only take")
cite(1560, "437.5 kg/s, so the rest goes to bypass")
check("C-18", f"§7.6 'train B lost': of {2 * ML:.1f} kg/s from SG1 + SG2, turbine A takes 437.5 and 'the rest goes to bypass'; "
               f"the rest ({2 * ML - 437.5:.1f} kg/s) is exactly SG2's B branch at 50/50, which CV-2B/NRV-2B still route to "
               "turbine B", False,
      "bypass is forced only if turbine B is also out; §7.6 also leaves SG3 without any feed path (the crosstie serves SG2 "
      "only)\nand says nothing about the reactor power that follows")
cite(464, "main feed pumps 19.6, primary pumps 10.3")
cite(1552, "9.8 MW absorbed per")
r_pp = 10.3 / (3 * 3.3)
r_sp = 6.2 / (3 * 2.0)
r_fp = 19.6 / (2 * 9.8)
check("C-19", f"§1.1 house-load list vs §7.6: electrical/shaft ratios primary {r_pp:.3f}, secondary {r_sp:.3f}, feed "
               f"{r_fp:.3f}", abs(r_fp - r_pp) < 0.01,
      f"primary and secondary pumps are listed at electrical input, the feed pumps at absorbed power; on the primary pumps' "
      f"basis the feed pumps draw {19.6 * r_pp:.1f} MWe")

# ================================================================================================= section 8
section("§8 ELECTRICAL  (lines 1567-1640)")
check("K-36", f"§8.1 {cite(1576, '600 MVA')} generator transformer 600 MVA ≥ generator 590 MVA", 600 >= 590)
ub = 3.3 / 0.961 + 2.0 / 0.968 + 9.8 + 2 * 3.7
check("K-37", f"§8.1 {cite(1577, '50 MVA')} UAT 50 MVA ≥ one unit board's listed running load (PP, SP, two MFPs, two CW "
               f"pumps) ≈ {ub:.1f} MW plus condensate pumps", ub < 50)
cite(1579, "ST-1 400/11 kV 60 MVA")
cite(1581, "Fast transfer from UB to SB")
check("C-20", "§8.1 on a double unit trip both unit boards transfer to the station boards, but ST-1 (60 MVA) is smaller than "
               "the 65 MWe house load at any power factor", 65 <= 60,
      f"it fits only after the feed-pump load (19.6 MW) has run down, leaving {65 - 19.6:.1f} MW; the spec states no load "
      "shedding or runback on transfer")
q_500 = math.sqrt(590 ** 2 - 500 ** 2)
q_514 = math.sqrt(590 ** 2 - 514 ** 2)
check("K-38", f"§8.4 {cite(1621, '+300 / −150 MVAr')} +300 MVAr at 500 MW needs {math.hypot(500, 300):.0f} MVA ≤ 590 "
               f"(capability {q_500:.0f}); at 514 MW only {q_514:.0f} MVAr, the 'less above 500 MWe in winter'",
      math.hypot(500, 300) <= 590 and q_514 < 300)
check("K-39", f"§8.4 frequency ordering ({cite(1618, '48.8 Hz')}): trip 47.5 < shedding 48.8 < continuous 49.0 < FCR-D 49.5 < "
               "49.9 < 50 < 50.1 < 50.5 < 51.0 < 51.5", 47.5 < 48.8 < 49.0 < 49.5 < 49.9 < 50 < 50.1 < 50.5 < 51.0 < 51.5)
check("K-40", f"§8.4 {cite(1636, '±20 MWe for the plant, full within 5 min')} aFRR = {20 / 5 / 1000 * 100:.1f} %/min, inside "
               "LCO-10's 1 %/min", 20 / 5 / 10 <= 1)
check("K-41", f"§8.3 {cite(1599, 'rated voltage and frequency in ≤ 15 s')} EDG at speed in 15 s = S-15 window "
               f"{cite(2598, 'Window: 15 s')}; first load step at {cite(1599, 'load steps at 15')[0:0]}15 s", 15 == 15)

# ================================================================================================= section 9 cross-refs
section("§9 CROSS-REFERENCES FROM IN-SCOPE SECTIONS  (§9 has no subsections after 9.6)")
cite(1681, "150 MWe minimum stable load (§7.1) and their steam is below the reheat trip temperature")


def gross(pw):  # file 20's part-load MWe
    return 10 * pw * (0.8 + 0.2 * (pw / 100) ** 0.5)


lo, hi = 25.0, 40.0
for _ in range(60):
    mid = (lo + hi) / 2
    lo, hi = (mid, hi) if gross(mid) < 300 else (lo, mid)
check("C-21", "§9.2 (Rev A4 text of F22): 'the 20%, 10% and 5% rows ... because 178, 86 and 42 MWe are under the 150 MWe "
               "minimum ... and their steam is below the reheat trip'", 178 < 150,
      "178 MWe on one turbine is above 150; the 20 % row's main steam is 440 °C (435 °C at the stop valve), above both "
      "the 430 °C main-steam trip and the 420 °C reheat trip the sentence cites\n"
      f"meanwhile two turbines cannot both reach 150 MWe below {mid:.1f} %FP (gross 300 MWe), so the 30 % row, 'turbines on', "
      "is a one-turbine state")
t_tr = 32 + 17 + 5 + 8 + 52
check("K-42", f"§9.3 {cite(1798, 'about 1–2 minutes later')} turbine-leads delay vs §5.1/§4.1 transport: cold leg 32 + buffer "
               f"17 + IHX 5 + 8 s + cold pool 52 s = {t_tr} s = {t_tr / 60:.1f} min", 60 <= t_tr <= 120)

# ================================================================================================= section 10
section("§10 CONTROL ROOMS, DESKS AND CREW  (lines 1998-2260)")
counts = [("hydrogen meters", 27, 24 + 3, 2062), ("acoustic detectors", 24, 24, 2062), ("section isolations", 24, 3 * 8, 2059),
          ("condensate pumps", 6, 2 * 3, 2075), ("main feed pumps", 4, 2 * 2, 2076), ("startup feed pumps", 2, 2, 2076),
          ("DRACS dampers", 8, 4 * 2, 2042), ("IHX shutters", 6, 6, 2041), ("DND", 6, 6, 2038), ("rod positions", 30,
                                                                                                    3 + 18 + 9, 2037),
          ("core map", 331, 301 + 30, 2037), ("separators", 3, 3, 2060)]
check("K-43", "§10.2 desk counts match the plant: " + ", ".join(f"{n} {a}" for n, a, _, _ in counts),
      all(a == b for _, a, b, _ in counts))
check("K-44", f"§10.2 {cite(2089, '(≈ 180)')} ≈ 180 trace-heating zones ≥ the 3 × 42 = 126 secondary zones (§5.1) and = §14.3's "
               f"≈ 180 heater zones", 180 >= 126)
check("K-45", f"§10.4 crew 3 / 8 / 13: standard = SS RO PO SGO TO-A TO-B EO field = 8, full = +5 = 13 = the eleven "
               f"desks of §10.1 plus two field operators", 8 + 5 == 13 == 11 + 2)
cite(2029, "no two desks that have to talk during a fault can see each other")
check("C-22", "§10.1 'no two desks that have to talk during a fault can see each other' vs the same table putting reactor + "
               "primary + SS in the MCR, secondary sodium + SG in the SGCR, turbine A + B in the TCR", False,
      "reactor and primary desks share P/Q (§9.3) and talk in S-07; the rule can only mean rooms, not desks")
band_worth = 300 * ((0.75 - math.sin(2 * math.pi * 0.75) / (2 * math.pi)) - (0.25 - math.sin(2 * math.pi * 0.25) /
                                                                           (2 * math.pi)))
drift = 3.0 * SLOW / 1440
near("K-46", f"§10.5 {cite(2180, '≈ 2.7 h')} regulating band mid to edge: {band_worth / 2:.1f} pcm at {drift:.2f} pcm/min",
     band_worth / 2 / drift / 60, 2.7, 0.05, " h")
check("K-47", f"§10.3 90 s per damper, 8 dampers ({cite(2110, '90 s per damper, 8 dampers')}) = §4.5 handwheel 90 s each "
               f"({cite(1175, 'local handwheel 90 s each')}) and 4 loops × 2 dampers; all eight by hand = 12 min plus walking",
      8 * 90 == 720 and 4 * 2 == 8)

# ================================================================================================= section 11
section("§11 GRID DISPATCHER  (lines 2271-2337)")
check("K-48", f"§11.1 'reduce 300 MWe within 10 min' ({cite(2287, 'Reduce 300 MWe within 10 min')}) = 30 MWe/min = 3 %/min, LCO-10's approved maximum "
               f"({cite(1985, '≤ 3 %/min with supervisor approval')})", 300 / 10 / 1000 * 100 == 3)
cite(2294, "planned ones are announced a grid-hour ahead")
check("C-23", f"§11.1 a planned 200 MWe curtailment is announced one grid-hour = {60 / GRID:.0f} min real ahead; 200 MWe takes "
               f"{200 / 10:.0f} min at LCO-10's 1 %/min and {200 / 30:.1f} min at the approved 3 %/min",
      200 / 30 <= 60 / GRID, "if the limit bites when announced, the crew must breach LCO-10 or take dispatch error; the "
                             "deadline is not stated")
cite(2330, "max(0, abs(MW − target) − 10)")
check("C-24", "§11.3 dispatch error has a 10 MW deadband, but contracted reserves move the plant further: FCR-N ±20 MWe, "
               "FCR-D 50 MWe, aFRR ±20 MWe for the plant (§8.4)", max(20, 50, 20) <= 10,
      "unless 'target' includes activated reserves (not stated), delivering a contract scores as a dispatch miss")
check("K-49", f"§11.2 {cite(2303, 'σ √(2/τ) dW')} the Ornstein-Uhlenbeck form has stationary SD exactly σ "
               "(variance σ²·(2/τ)·(τ/2))", abs(0.05 ** 2 * (2 / 90) * (90 / 2) - 0.05 ** 2) < 1e-15)
for name, sig in (("Calm", 0.03), ("Standard", 0.05), ("Winter Peak", 0.07)):
    frac_out = math.erfc(0.1 / sig / math.sqrt(2))
    print(f"         {name}: σ {sig} Hz -> outside 49.9-50.1 Hz {frac_out * 100:.2f} % of the time")
check("K-50", f"§11.2 {cite(2322, 'nadir −0.2 to −0.45 Hz')} deepest nadir 49.55 Hz stays above the 48.8 Hz shedding",
      50 - 0.45 > 48.8)
cite(2618, "−0.4 Hz and an emergency instruction")
cite(2621, "Under-frequency trip")
check("C-25", "S-18's poor-crew outcome 'Under-frequency trip' needs < 47.5 Hz for 20 s (§7.2); the cue is 49.6 Hz, §11.2's "
               "events reach 49.55 Hz at most, and §8.4 sheds load from 48.8 Hz", 50 - 0.45 < 47.5,
      "no stated mechanism takes the frequency 2.1 Hz lower; nothing in the plant trips at 49.6 Hz")

# ================================================================================================= section 12
section("§12 DAMAGE AND DEGRADATION  (lines 2339-2453)")
alpha = 4e-6
walls = [("upper internals", 0.040, 200, 2358), ("IHX tubesheet", 0.100, 1250, 2365), ("SG inlet header", 0.060, 450, 2379),
         ("hot-leg thermowells", 0.025, 80, 2386), ("diagrid", 0.080, 800, 2400)]
for name, L, tau, ln in walls:
    cite(ln, f"τ_w: {tau:,}")
    near("K-51", f"§12.1 {name}: L²/(2α) with L {L * 1000:.0f} mm", L ** 2 / (2 * alpha), tau, 5 if tau == 80 else 0.5,
         " s", "printed rounding" + (", '80' read as two figures" if tau == 80 else ""))
print(f"         note: for a wall heated on one face the first conduction mode is 4L²/(π²α) = {4 / math.pi ** 2:.3f} L²/α, "
      "the spec's L²/(2α) is 0.5 L²/α; a stated model, not flagged")
lam = lambda u: 0.002 * math.exp(6 * u)
check("K-52", f"§12.1 {cite(2406, '0.807 per')} hazard: U 0.5 -> {lam(0.5):.4f}/grid day, {1 - math.exp(-lam(0.5)):.1%}; "
               f"U 1 -> {lam(1):.3f}/grid day, {1 - math.exp(-lam(1)):.1%} (D-008)",
      abs(lam(0.5) - 0.04) < 0.0005 and abs(lam(1) - 0.807) < 0.0005 and round((1 - math.exp(-lam(1))) * 100) == 55)
check("K-53", f"§12.1 {cite(2347, 'D = 0.5')} two half-cycles at ΔT_ref charge 2 × 0.5 × 1³ / N_ref = 1/N_ref, one cycle's "
               "share of N_ref", abs(2 * 0.5 * (120 / 120) ** 3 / 500 - 1 / 500) < 1e-15)
cite(2407, "Thermal striping: adjacent assembly outlets more than 40")
cite(2408, "1/5,000 per minute")
cite(741, "rod positions 1.5%")
m_rod = 0.015 * PRIMARY_FLOW / 30
q_rod = m_rod * dh(375, 559 - 40) / 1e3
check("C-26", "§12.1 striping rate '1/5,000 per minute' names no clock, and 'adjacent assembly outlets' does not say whether "
               "the 30 rod positions of the 331-position map count",
      bool(re.search(r"grid|real", LINES[2407].split("1/5,000")[1])),
      f"U 0 -> 1 in {5000 / 60:.1f} h real if real time, {5000 / 60 / GRID:.1f} h real on the grid clock (F26 bound "
      "degradation to the grid clock)\n"
      f"a rod position gets {m_rod:.2f} kg/s (§2.5) and needs {q_rod:.2f} MW of its own heat to sit within 40 K of a 559 °C "
      "fuel neighbour;\nthe spec gives rod positions no heat, so read literally the rule charges damage continuously at power")
cite(2415, "/ 100 grid hours")
check("K-54", f"§12.2 creep at 650 °C: D = 1 after 100 grid h = {100 / GRID:.1f} h real; it starts at §2.4's 650 °C "
               f"cladding alarm ({cite(715, 'Alarm: 650')})", abs(100 / GRID - 8.33) < 0.01)
cite(2417, "overpower multiplier")
n_om = sum("overpower multiplier" in l for l in LINES)
check("C-27", f"§12.2 random failure '× overpower multiplier': the phrase appears {n_om} time(s) in the spec and is never "
               "defined", n_om > 1)
cite(2420, "more than 8 grid-hours")
cite(1995, "Completion (grid time): 8 h")
check("K-55", f"§12.2 open failure 8 grid-h = LCO-12's 8 h = S-22's window ({cite(2647, '8 grid-hours')}) = {8 / GRID * 60:.0f} min real",
      8 == 8 and "8 grid-hours" in LINES[2419] + LINES[2646])
cite(2422, "one group of 7 assemblies")
cite(2423, "every 2 min")
cite(1994, "≤ 30 %FP and locate failed fuel")
groups = 301 / 7
check("C-28", f"§12.2 fuel location scans 301/7 = {groups:.0f} groups × 2 min = {groups * 2:.0f} min real (mean "
               f"{(groups + 1):.0f} min) against LCO-12's 8 grid-h = {8 / GRID * 60:.0f} min real to '≤ 30 %FP and locate'",
      groups * 2 <= 8 / GRID * 60,
      f"the scan finds the failed assembly inside the completion time with probability {20 / 43:.0%}; '2 min' is unmarked, "
      "so §0.2 reads it as real time")
cite(2433, "1 per 2,000 zone-hours real")
zones = 180
check("C-29", "§12.3 trace-heating failures are '1 per 2,000 zone-hours real', §0.2 puts 'heater failures' on ×360 "
               "(and src/shared/Config/Clocks.luau follows §0.2)", abs(SLOW - 1) < 0.1,
      f"≈ 180 zones: real time -> one failure every {2000 / zones:.1f} h; ×360 -> {zones * SLOW / 2000:.1f} per real hour, "
      f"one every {2000 / zones / SLOW * 60:.2f} min")
check("K-56", f"§12.3 {cite(2434, '10% thermocouple failure')} failure modes 60 + 30 + 10 = 100 %", 60 + 30 + 10 == 100)
cite(2431, "plugging temperature rises 2 K per 10% loading above")
cite(1182, "Plugging temperature normal ≤ 125 °C, alarm")
cite(1970, "≤ 60 %FP and restore")
cite(2586, "LCO-6 derate")
need = lambda d: 70 + d / 2 * 10
check("C-30", f"S-13 'poor crew: LCO-6 derate' needs primary plugging temperature 125 -> 180 °C; §12.3 raises it 2 K per 10 % "
               f"above 70 % loading: +{(100 - 70) / 10 * 2:.0f} K at 100 %", need(180 - 125) <= 100,
      f"LCO-6 needs {need(55):.0f} % loading, the 150 °C primary alarm {need(25):.0f} %, the 160 °C secondary alarm "
      f"{need(20):.0f} %;\nno stated mechanism raises plugging temperature once the trap is full")
cite(2435, "Drained line cooling with heater off")
cite(2574, "Heater fault on a drained line")
check("C-31", "§12.3 / S-12 'drained line ... to freezing': a drained line holds no sodium to freeze", False,
      "the 40 min DN50 figure and the thaw rules need a filled line (or a drain line)")
cite(2445, "10–30 min at 1 g/s, 1–3 min")
cite(404, "Fuel and tube degradation (§12.2, §12.4) run on the grid clock")
check("C-32", "§12.4 small-leak times '10–30 min at 1 g/s, 1–3 min at 10 g/s' are unmarked; §0.2 binds §12.4 to the grid "
               "clock but reads unmarked windows as real time", False,
      f"grid reading: {10 * 60 / GRID:.0f}-{30 * 60 / GRID:.0f} s real at 1 g/s, {60 / GRID:.0f}-{3 * 60 / GRID:.0f} s real at "
      "10 g/s; real reading: as printed (12× apart)")
dbl = (2 * 60 / GRID, 6 * 60 / GRID)
check("K-57", f"§12.4 micro doubling 2-6 grid-h = {dbl[0]:.0f}-{dbl[1]:.0f} min real, so S-01's 20-60 min window "
               f"({cite(2500, '20–60 min')}) is two doublings, as F26 intended", 2 * dbl[0] == 20 and 2 * dbl[1] == 60)

# ================================================================================================= section 13
section("§13 SCENARIOS  (lines 2455-2692)")
minor = [1, 6, 10, 12, 13, 14, 17, 23, 24, 26]
moderate = [3, 5, 7, 8, 11, 19, 20, 21, 22, 25]
major = [2, 4, 9, 15, 16, 18, 27, 28]
cite(2489, "Cost classes †")
check("K-58", f"§13.1 cost classes {len(minor)} + {len(moderate)} + {len(major)} cover S-01..S-28 once each",
      sorted(minor + moderate + major) == list(range(1, 29)))
bracket = lambda n: 0.5 if n <= 3 else (1.0 if n <= 8 else 1.5)
check("K-59", f"§13.1 {cite(2473, '×0.5 with 1–3 players')} scaling brackets put §10.4's minimum, standard and full crews "
               f"(3, 8, 13) in three different brackets: {[bracket(n) for n in (3, 8, 13)]}",
      [bracket(n) for n in (3, 8, 13)] == [0.5, 1.0, 1.5])
cite(2605, "≈ 6.5 h, ≈ 40 min with ×10 acceleration")
near("K-60", "S-16 window 6.5 h at ×10", 6.5 * 60 / 10, 40, 1.0, " min", "'≈ 40'")
check("K-61", f"S-12 40 min = §12.3 DN50; S-23 15 min = §3.2 vessel lag 900 s ({cite(840, '900 s')}); S-04 turbines to "
               f"{291.7 / 437.5:.0%}; S-01 'trim reactor 4%' = one section of 24",
      abs(900 / 60 - 15) < 1e-9 and round(291.7 / 437.5 * 100) == 67 and round(100 / 24) == 4)
cite(1605, "230 V AC per division, 2 h")
cite(1606, "220 V per division, 4 h")
cite(393, "Drives: Kinetics, thermal-hydraulics, pumps, valves, electrical, protection")
ups_out_x1 = 2.0 < 6.5
ups_out_x10 = 2.0 < 6.5 / 10
check("C-33", "S-16 at ×10: pool heatup runs ×10 (§0.2) but 'electrical' stays ×1, so batteries last 10× longer against the "
               "pool", ups_out_x1 == ups_out_x10,
      f"×1: UPS out at 2 h and DC at 4 h, before the 6.5 h pool limit; ×10: the pool limit comes at {6.5 * 60 / 10:.0f} min "
      "real and the 2 h UPS never runs out")
cite(2536, "field hydraulic reset")
cite(2627, "Kill drive power")
sec103 = "\n".join(LINES[2102:2144])
sec102 = "\n".join(LINES[2031:2101])
check("C-34", "S-06 'field hydraulic reset' and S-19 'kill drive power' name actions that §10.3 (local actions) and §10.2 "
               "(desk controls) do not list", "hydraulic" in sec103 and "drive power" in sec102,
      "the other scenarios' good-crew actions all map to listed controls or local actions")
cite(2479, "Frazil")
cite(2480, "ice needs winter and open water")
cite(605, "frazil ice risk from November")
winter = {12, 1, 2, 3}
fast_ice = {1, 2, 3, 4}  # §1.4 "Fast ice in the archipelago from January to April"
cite(531, "Fast ice in the archipelago from January to April")
elig_131 = winter - fast_ice
elig_17 = {11} | elig_131
check("C-35", f"§13.1 frazil needs 'winter and open water' -> months {sorted(elig_131)}; §1.7 puts frazil risk 'from "
               f"November' and §1.4 'before the ice forms' -> months {sorted(elig_17)}", elig_131 >= elig_17)

# ================================================================================================= file 16
section("FILE 16: ROBLOX IMPLEMENTATION AND APPENDICES B-C  (lines 2694-3002)")
check("K-62", f"§14.1 {cite(2725, '662 bytes')} 331 × 2 bytes = 662; u16 at 0.05 K spans {65535 * 0.05:,.0f} K", 331 * 2 == 662)
n_unk = 469 * 14 * 4
check("K-63", f"§14.2 {cite(2774, 'About 26,000 unknowns')} = §3.7's 469 × 14 × 4 = {n_unk:,}; × 4-8 sweeps × 2-3 passes = "
               f"{n_unk * 8:,}-{n_unk * 24:,} node updates, 'a few hundred thousand'", 200_000 <= n_unk * 8 and n_unk * 24 < 1e6)


def growth(scheme, rho_frac, dt=0.1, steps=2000):
    rho = rho_frac * BETA_SUM / 1e5
    beta = [b / 1e5 for b in BETA]
    s, n, logscale, hist = list(beta), 1.0, 0.0, []
    e = [math.exp(-l * dt) for l in LAMBDA]
    w = [(1 - ei) - (1 - ei - l * dt * ei) / (l * dt) for ei, l in zip(e, LAMBDA)]
    for _ in range(steps):
        if n > 1e100:
            s, logscale, n = [si / n for si in s], logscale + math.log(n), 1.0
        if scheme == "held":
            s = [si * ei + bi * n * (1 - ei) for si, ei, bi in zip(s, e, beta)]
            n = sum(s) / (sum(beta) - rho)
        elif scheme == "implicit":
            s = [si * ei for si, ei in zip(s, e)]
            n = sum(s) / (sum(bi * ei for bi, ei in zip(beta, e)) - rho)
            s = [si + bi * n * (1 - ei) for si, bi, ei in zip(s, beta, e)]
        else:
            num = sum(si * ei + bi * n * (1 - ei - wi) for si, ei, bi, wi in zip(s, e, beta, w))
            n1 = num / (sum(beta) - rho - sum(bi * wi for bi, wi in zip(beta, w)))
            s = [si * ei + bi * (n * (1 - ei - wi) + n1 * wi) for si, ei, bi, wi in zip(s, e, beta, w)]
            n = n1
        hist.append(logscale + math.log(n))
    return (steps // 2 - 1) * dt / (hist[-1] - hist[steps // 2])


def inhour_period(rho_pcm):
    lo_, hi_ = 1e-4, 1e6
    for _ in range(300):
        mid_ = math.sqrt(lo_ * hi_)
        lo_, hi_ = (mid_, hi_) if sum(b / (1 + l * mid_) for b, l in zip(BETA, LAMBDA)) > rho_pcm else (lo_, mid_)
    return math.sqrt(lo_ * hi_)


cite(2738, "holding n at its old value runs 11% slow at 0.8 beta")
cite(2739, "and 22% slow at 0.9 beta; a fully implicit form errs the same amount the other way")
errs = {}
for frac in (0.8, 0.9):
    exact = inhour_period(frac * BETA_SUM)
    errs[frac] = {k: (exact / growth(k, frac) - 1) * 100 for k in ("held", "implicit", "linear")}
    print(f"         ρ = {frac}β: held-n {errs[frac]['held']:+.1f} %, fully implicit {errs[frac]['implicit']:+.1f} %, "
          f"linear-n {errs[frac]['linear']:+.1f} % growth-rate error")
check("K-64", "§14.2 comment 'runs 11% slow at 0.8 beta and 22% slow at 0.9 beta' for held n",
      round(-errs[0.8]["held"]) == 11 and round(-errs[0.9]["held"]) == 22)
check("C-36", "§14.2 comment 'a fully implicit form errs the same amount the other way'",
      all(abs(errs[f]["implicit"] + errs[f]["held"]) <= 1.0 for f in (0.8, 0.9)),
      f"+{errs[0.8]['implicit']:.1f} % and +{errs[0.9]['implicit']:.1f} % against -{-errs[0.8]['held']:.1f} % and "
      f"-{-errs[0.9]['held']:.1f} % (SPEC_REVIEW_AUDIT #24 has the same figures)")
cite(2740, "local num, den = q, BETA - rho")
cite(2757, "s[i] = beta[i]  n")
q_defs = [i + 1 for i, l in enumerate(LINES) if re.search(r"(\bq\b\s*(=|is\b|:))|(\bq\b\s+\()", l)
          and i + 1 != 2740]
check("C-37", "§14.2 snippet reads 'q' (an external source) that the spec never defines; 's[i] = beta[i]  n' is steady only "
               "with q = 0 at ρ = 0", bool(q_defs), f"lines defining q: {q_defs or 'none'}")
cite(2796, "≈ 6,300 thermal states")
states = 301 * 10 * 2 + 3 + 6 * 3 + 24 * 3 * 2 + 2 * 2 + 2 * 5
near("C-38", "§14.3 total of the listed blocks (fuel 6,020 + pools 3 + IHX 18 + SG 144 + turbines 4 + feed 10)", states,
     6300, 50, " states", "'≈ 6,300' read to two figures")
cite(2926, "SYS-L-TYPE-NN")
cite(2952, "shim rods are tagged SM")
codes = " ".join(LINES[2930:2934])
check("C-39", "Appendix B: the glossary says shim rods are tagged 'SM', which is in neither code list; the 3 loop-outlet "
               "hydrogen meters (27 = 24 + 3) have no NN rule", bool(re.search(r"\bSM\b", codes)))
cite(2983, "* A5")
cite(2991, "* A4")
cite(10, "Design specification Rev A3")
n_hdr = sum("SPECIFICATION, REV A3" in l for l in LINES)
check("C-40", f"Appendix C lists A5 before A4, and {n_hdr} file headers plus the README still say 'Rev A3' while the text "
               "carries A4/A5 changes", 2991 < 2983 and n_hdr == 0)

# ================================================================================================= earlier documents
section("ERRORS IN THE EARLIER AUDIT DOCUMENTS")
w = lambda d: d - math.sin(2 * math.pi * d) / (2 * math.pi)
one_mid = 100 * (w(0.50) - w(0.25))
one_full = 100 * (w(0.75) - w(0.25))
gang_mid = 3 * one_mid
old_one = 100 * (w(1 - 0.55) - w(1 - 0.70))
print(f"         250-750 band: one RR mid->edge {one_mid:.1f} pcm = {one_mid / drift:.0f} min, full band {one_full:.1f} pcm = "
      f"{one_full / drift:.0f} min;\n         all three ganged mid->edge {gang_mid:.1f} pcm = {gang_mid / drift:.0f} min, "
      f"full band {3 * one_full / drift:.0f} min; old 400-700 band, one RR 550->700 mm: {old_one:.1f} pcm = "
      f"{old_one / drift:.0f} min")
check("P-01", "docs/DECISIONS.md D-028: 'ganging all three crosses the 250–750 mm band in about 33 minutes rather than 100'",
      abs(gang_mid / drift - 33) < 5 or abs(3 * one_full / drift - 33) < 5,
      "33 min is one rod on the pre-A4 400-700 band (D-006); ganging is the SLOWER case (164 min mid-to-edge)")
dp = 17.5 - 1.0
rho_fw = S(P=1.0, x=0).rho
shaft_train = 437.5 * dp * 1e6 / rho_fw / 0.82 / 1e6
check("P-02", "docs/DECISIONS.md F24 (and SPEC_REVIEW_AUDIT #10): 'independent hydraulic check ... ~14.5 MPa rise ... gives "
               "9.1 MW per train'", abs(dp - 14.5) < 0.5,
      f"file 20 and §7.5 give 1.0 -> 17.5 MPa = {dp:.1f} MPa; the same check then gives {shaft_train:.1f} MW shaft, "
      f"{shaft_train / 0.96:.1f} MW electrical per train;\nF24's conclusion (≈ 5 MW per pump, 12 MW motors wrong) stands")

# ================================================================================================= summary
section("SUMMARY")
if CITE_ERRORS:
    print("  CITATION ERRORS:")
    for e_ in CITE_ERRORS:
        print("   ", e_)
ids_fail = sorted({cid for cid, ok in RESULTS if not ok})
ids_pass = sorted({cid for cid, ok in RESULTS if ok} - set(ids_fail))
print(f"  {len(RESULTS)} checks: {sum(ok for _, ok in RESULTS)} PASS, {sum(not ok for _, ok in RESULTS)} FAIL")
print(f"  FAIL (findings reproduced): {', '.join(ids_fail)}")
print(f"  PASS (consistent): {', '.join(ids_pass)}")
unexpected = [c for c in ids_fail if c.startswith("K-")] + [c for c in ids_pass if c[0] in "CP"]
print(f"  citations checked: {'all quoted lines match' if not CITE_ERRORS else f'{len(CITE_ERRORS)} MISMATCHED'}")
print(f"  unexpected outcomes (a K that failed or a C/P that passed): {unexpected or 'none'}")

section("APPENDIX: FILE-20 calc.py OUTPUT (RE-RUN, UNMODIFIED)")
print(CALC_OUT.rstrip())
sys.exit(1 if CITE_ERRORS or unexpected else 0)
