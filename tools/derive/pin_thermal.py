"""
Kallskar derivation: fuel-pin thermal parameters for FuelThermal (spec §2.3, §2.4, §3.2, §14.3).
Writes src/shared/Config/FuelPin.luau (do not edit by hand) and prints a report (kept in pin_thermal.out.txt).

Run (WSL, env kallskar-xs):  python tools/derive/pin_thermal.py > tools/derive/pin_thermal.out.txt

Inputs
  spec §2.3   pellet OD 7.28 mm, hole 2.0 mm, 95 % TD; Pu 18 % inner / 23 % outer; 145 inner + 156 outer assemblies;
              discharge ≈ 51 GWd/tHM with a quarter of the core replaced per outage
  spec §2.4   average 27.7 kW/m; peak 42 kW/m = 1.20 radial × 1.04 pin × 1.22 axial; assembly outlet 559 °C average,
              580–585 °C hottest; cladding midwall hot spot ≈ 620 °C; MOX melts ≈ 2,700 °C.
              NOTE (Rev A5, D-018 accepted): §2.4's hot-pin centreline (2,140 °C) and melting linear heat rate
              (≈ 57 kW/m) are now this script's own results, so they are no longer independent checks on it. The
              checks that remain independent are the 620 °C cladding hot spot (which fixes R_cna, one equation one
              unknown) and the §3.2 Doppler lag of 4 s, which nothing calibrates.
  spec §3.2   fuel average ≈ 1,107 °C at 100 % (file 20: 1,380 K); Doppler lag 4 s; core inlet 375 °C (file 20)
  Carbajo, Yoder, Popov, Ivanov, ORNL/TM-2000/351 (2001) ("Carbajo" below):
              eq. 6.1, 6.3–6.7 thermal conductivity of irradiated MOX (Duriez lattice + Ronchi polaron, Lucuta factors)
              eq. 4.2, 4.3, 4.6 and Table 4.2 heat capacity (Fink; Kopp–Neumann rule for MOX)
              §3.3 density at 273 K: 10,970 + 490·y kg/m³

Method
  1. Pellet conduction, uniform heat generation in an annulus with an adiabatic hole (Kirchhoff transform):
         Θ(T(r)) − Θ(T_s) = q'·g(r),   g(r) = [(r_o² − r²)/2 − r_i² ln(r_o/r)] / (2π(r_o² − r_i²)),   Θ(T) = ∫k dT
     g depends only on r/r_o, so uniform thermal expansion does not change it. The fuel temperature that drives
     Doppler is the volume average over the annulus (Gauss–Legendre in r).
  2. Axial shape: chopped cosine whose peak/average is the spec's 1.22. Sodium enthalpy rises along the channel in
     proportion to the cumulative power (algebraic, §14.3), with the Appendix A heat capacity the game also uses.
     The 10-layer fixture repeats FuelThermal's own layer algebra so the tests can compare to numerical precision.
  3. Two unknown resistances, each fixed by one spec figure, and the other spec figures used as checks:
       R_cna  cladding midwall → sodium (film + outer half wall): the hottest channel (outlet 582.5 °C, midpoint of
              580–585) must peak at the §2.4 cladding hot spot, 620 °C. This keeps the spec's 30 K margin to the
              650 °C alarm.
       R_gap  pellet surface → cladding midwall (helium gap + inner half wall): the core-average fuel temperature must
              be the §3.2 value, 1,380 K. The §3.2 power defect (Doppler −680 pcm) is computed from that value, so
              the thermal model has to reproduce it.
     Check (not fitted, and not fed back into the spec): the fuel time constant against the §3.2 Doppler lag of 4 s.
     The centreline and melting figures are printed too, but since Rev A5 adopted them they only confirm the spec
     still matches this script — they cannot falsify it.
  4. Burnup: cycle-average burnup of the spec's equilibrium core, 51/2 = 25.5 GWd/tHM (a quarter replaced per
     outage, so the core spans 0–51 GWd/tHM at a uniform rate), converted with Carbajo's 1 at.% = 9.375 MWd/kgHM.
     O/M = 2.00 (the spec writes (U,Pu)O₂). Porosity 5 % (95 % TD).

Known limits, reported below rather than hidden: Carbajo's MOX equation is stated for 3–15 % Pu (K1 has 18–23 %);
Carbajo notes it agrees with Philipponneau's equation for stoichiometric fast-reactor MOX (≈ 20 % Pu), and Duriez
found no Pu dependence. The average channel stands in for the core average (radial non-linearity is estimated).
"""
import math
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np
from scipy.optimize import brentq

REPO = Path(__file__).resolve().parents[2]
OUT_LUAU = REPO / "src" / "shared" / "Config" / "FuelPin.luau"
REF = "tools/derive/pin_thermal.py"

# ---------------------------------------------------------------- spec inputs
R_O = 7.28e-3 / 2
R_I = 2.00e-3 / 2
DENSITY_FRACTION = 0.95
PU = {"inner": 0.18, "outer": 0.23}
ASSEMBLIES = {"inner": 145, "outer": 156}
LHR_AVG = 27.7e3  # W/m
PEAK_RADIAL, PEAK_PIN, PEAK_AXIAL = 1.20, 1.04, 1.22
T_IN = 375.0 + 273.15
T_OUT_AVG = 559.0 + 273.15
T_OUT_HOT = 582.5 + 273.15
T_CLAD_HOTSPOT = 620.0 + 273.15
T_FUEL_AVG = 1380.0
T_CENTRE_HOT = 2140.0 + 273.15  # Rev A5 (D-018): now the model's own figure, not an independent check
T_MELT = 2700.0 + 273.15
LHR_MELT = 57e3  # Rev A5 (D-018): the spec now carries the model's melting point
DOPPLER_LAG = 4.0
DISCHARGE_GWD = 51.0
GWD_PER_ATPCT = 9.375
BURNUP = DISCHARGE_GWD / 2 / GWD_PER_ATPCT  # at.%
POROSITY = 1 - DENSITY_FRACTION
X_STOICH = 0.0


# ---------------------------------------------------------------- Carbajo correlations
def k_mox(T, B=BURNUP, p=POROSITY, x=X_STOICH, radiation=True):
    """W/(m·K). Carbajo eq. 6.1 with 6.3–6.7."""
    A = 2.85 * x + 0.035
    C = (-7.15 * x + 2.86) * 1e-4
    k0 = 1.1579 / (A + C * T) + 2.3434e11 * T ** -2.5 * math.exp(-16350.0 / T)
    if B > 0:
        w = 1.09 / B ** 3.265 + 0.0643 * math.sqrt(T / B)
        fd = w * math.atan(1 / w)
        fp = 1 + 0.019 * B / (3 - 0.019 * B) / (1 + math.exp(-(T - 1200) / 100))
    else:
        fd = fp = 1.0
    fm = (1 - p) / (1 + 2 * p)
    fr = 1 - 0.2 / (1 + math.exp((T - 900) / 80)) if radiation else 1.0
    return k0 * fd * fp * fm * fr


CP = {  # Carbajo Table 4.2
    "UO2": dict(C1=302.27, C2=8.463e-3, C3=8.741e7, theta=548.68, Ea=18531.7),
    "PuO2": dict(C1=322.49, C2=1.4679e-2, C3=0.0, theta=587.41, Ea=18531.7),
}


def cp_oxide(T, c, B):
    e = math.exp(c["theta"] / T)
    c2 = c["C2"] * (1 + 0.011 * B)  # eq. 4.3
    return (c["C1"] * (c["theta"] / T) ** 2 * e / (e - 1) ** 2 + 2 * c2 * T
            + c["C3"] * c["Ea"] * math.exp(-c["Ea"] / T) / T ** 2)


def cp_mox(T, y, B=BURNUP):
    """J/(kg·K). Kopp–Neumann rule, Carbajo eq. 4.6."""
    return (1 - y) * cp_oxide(T, CP["UO2"], B) + y * cp_oxide(T, CP["PuO2"], B)


def rho_273(y):
    return 10970.0 + 490.0 * y  # kg/m³, Carbajo §3.3


# ---------------------------------------------------------------- self-checks against Carbajo's own tables
def self_check():
    table63 = {673: (4.40, 3.57, 3.04, 2.79, 2.48), 1273: (2.52, 2.51, 2.30, 2.19, 2.04),
               1873: (1.97, 1.97, 1.86, 1.80, 1.71), 2473: (2.24, 2.24, 2.15, 2.10, 2.02)}
    worst = 0.0
    for T, (b0, b0r, b2, b3, b5) in table63.items():
        for got, want in ((k_mox(T, 0, radiation=False), b0), (k_mox(T, 0), b0r), (k_mox(T, 2), b2),
                          (k_mox(T, 3), b3), (k_mox(T, 5), b5)):
            worst = max(worst, abs(got - want))
    assert worst <= 0.006, f"conductivity differs from Carbajo Table 6.3 by {worst}"
    # Table 4.3 was tabulated from Fink's polynomial, not from eq. 4.2 itself; the two agree within the stated
    # heat-capacity uncertainty (±2 % to 1,800 K, ±13 % above), which is therefore the tolerance here
    table43 = {300: 236.98, 1000: 312.86, 1400: 321.39, 2000: 374.75, 2400: 464.86}  # MOX, 5 % PuO2
    worst_cp = 0.0
    for T, v in table43.items():
        rel = abs(cp_mox(T, 0.05, 0) - v) / v
        assert rel <= (0.02 if T <= 1800 else 0.13), f"heat capacity at {T} K differs from Carbajo Table 4.3 by {rel:.2%}"
        worst_cp = max(worst_cp, rel)
    return worst, worst_cp


# ---------------------------------------------------------------- pellet conduction
T_GRID = np.arange(300.0, 3200.0 + 1e-9, 20.0)


def theta_table(B=BURNUP):
    th = np.zeros_like(T_GRID)
    for i in range(1, len(T_GRID)):
        a, b = T_GRID[i - 1], T_GRID[i]
        # Simpson on each 20 K interval: exact enough for a smooth k(T)
        th[i] = th[i - 1] + (b - a) / 6 * (k_mox(a, B) + 4 * k_mox((a + b) / 2, B) + k_mox(b, B))
    return th


def g_of(r):
    return ((R_O ** 2 - r ** 2) / 2 - R_I ** 2 * math.log(R_O / r)) / (2 * math.pi * (R_O ** 2 - R_I ** 2))


def quadrature(n):
    """Nodes (as r/r_o), g at the nodes, and area weights summing to 1 for the annulus volume average."""
    x, w = np.polynomial.legendre.leggauss(n)
    r = (R_O - R_I) / 2 * x + (R_O + R_I) / 2
    wr = w * (R_O - R_I) / 2 * 2 * math.pi * r / (math.pi * (R_O ** 2 - R_I ** 2))
    return r / R_O, np.array([g_of(v) for v in r]), wr


G_CENTRE = g_of(R_I)


class Pellet:
    def __init__(self, B=BURNUP, n=4):
        self.theta = theta_table(B)
        self.q = quadrature(n)

    def T_of(self, th):
        return float(np.interp(th, self.theta, T_GRID))

    def th_of(self, T):
        return float(np.interp(T, T_GRID, self.theta))

    def average(self, T_s, lhr):
        _, g, w = self.q
        base = self.th_of(T_s)
        return float(sum(wk * self.T_of(base + lhr * gk) for gk, wk in zip(g, w)))

    def centre(self, T_s, lhr):
        return self.T_of(self.th_of(T_s) + lhr * G_CENTRE)


# ---------------------------------------------------------------- axial shape
U = brentq(lambda u: math.sin(u) / u - 1 / PEAK_AXIAL, 1e-6, 1.5)
ZETA = np.linspace(-1, 1, 201)  # fuel height, bottom to top


def shape(z):
    return math.cos(U * z) * U / math.sin(U)  # q'(z)/q'_avg


def cumulative(z):
    return (math.sin(U * z) + math.sin(U)) / (2 * math.sin(U))


# ---------------------------------------------------------------- sodium (spec Appendix A, the same correlation the game uses)
NA_CP = (1.6582, -8.479e-4, 4.4541e-7, -2992.6)  # kJ/(kg·K): a + bT + cT² + d/T²


def cp_na(T):
    a, b, c, d = NA_CP
    return 1000 * (a + b * T + c * T * T + d / (T * T))


def h_na(T):
    """Specific enthalpy relative to an arbitrary zero, J/kg (exact integral of cp_na)."""
    a, b, c, d = NA_CP
    return 1000 * (a * T + b * T * T / 2 + c * T ** 3 / 3 - d / T)


def enthalpy_temperature(h):
    return brentq(lambda T: h_na(T) - h, 300.0, 3000.0)


@lru_cache(maxsize=None)
def sodium_profile(T_out):
    """Sodium along a channel with constant flow: the enthalpy rise follows the cumulative power."""
    h0, h1 = h_na(T_IN), h_na(T_out)
    return tuple(enthalpy_temperature(h0 + cumulative(z) * (h1 - h0)) for z in ZETA)


def outlet_at_scale(T_out, s):
    """Channel outlet when its power is scaled by s at unchanged flow."""
    h0 = h_na(T_IN)
    return enthalpy_temperature(h0 + s * (h_na(T_out) - h0))


def channel(pellet, lhr_avg, T_out, R_cna, R_gap, what):
    """Profiles along one channel: returns the max cladding midwall, the mean fuel average, or the max centreline."""
    vals = []
    na_profile = sodium_profile(T_out)
    for iz, z in enumerate(ZETA):
        q = lhr_avg * shape(z)
        T_na = na_profile[iz]
        T_c = T_na + q * R_cna
        if what == "clad":
            vals.append(T_c)
            continue
        T_s = T_c + q * R_gap
        vals.append(pellet.average(T_s, q) if what == "fuel" else pellet.centre(T_s, q))
    if what == "fuel":
        return float(np.trapezoid(vals, ZETA) / 2)
    return float(max(vals))


def main():
    kerr, cperr = self_check()
    print(f"Carbajo self-check: conductivity within {kerr:.3f} W/m/K of Table 6.3; heat capacity within {cperr:.2%} of Table 4.3")
    print(f"burnup {BURNUP:.3f} at.% ({DISCHARGE_GWD / 2} GWd/tHM), porosity {POROSITY:.2f}, O/M 2.00")
    print(f"axial shape: chopped cosine u = {U:.5f} (peak/avg {PEAK_AXIAL})")
    pellet = Pellet()
    exact = Pellet(n=16)
    lhr_hot = LHR_AVG * PEAK_RADIAL * PEAK_PIN  # average of the hottest pin's axial profile
    # the hottest channel carries the radial × pin factors; its sodium rise is the spec's hottest outlet
    R_cna = brentq(lambda R: channel(pellet, lhr_hot, T_OUT_HOT, R, 0, "clad") - T_CLAD_HOTSPOT, 0.0, 0.02)
    R_gap = brentq(lambda R: channel(pellet, LHR_AVG, T_OUT_AVG, R_cna, R, "fuel") - T_FUEL_AVG, 0.0, 0.05)
    print(f"\nR_cna (clad midwall → sodium)      = {R_cna * 1e3:.4f} K per kW/m   [fixed by the 620 °C hot spot]")
    print(f"R_gap (pellet surface → midwall)   = {R_gap * 1e3:.4f} K per kW/m   [fixed by the 1,380 K core average]")
    h_equiv = 1 / (R_gap * 2 * math.pi * R_O)
    print(f"  equivalent conductance at the pellet surface: {h_equiv:.0f} W/m²K (gap plus inner half wall)")

    # quadrature accuracy (4 points in the game vs 16 here)
    T_avg4 = channel(pellet, LHR_AVG, T_OUT_AVG, R_cna, R_gap, "fuel")
    T_avg16 = channel(exact, LHR_AVG, T_OUT_AVG, R_cna, R_gap, "fuel")
    print(f"core-average fuel temperature: 4-point {T_avg4:.2f} K, 16-point {T_avg16:.2f} K")

    print("\nFigures the spec now takes from this script (Rev A5, D-018) — they confirm agreement, not correctness:")
    centre_hot = channel(pellet, lhr_hot, T_OUT_HOT, R_cna, R_gap, "centre")
    print(f"  hot-pin centreline at {lhr_hot * PEAK_AXIAL / 1e3:.0f} kW/m: {centre_hot - 273.15:.0f} °C   "
          f"(spec §2.4 ≈ {T_CENTRE_HOT - 273.15:.0f} °C; difference {centre_hot - T_CENTRE_HOT:+.0f} K)")
    # overpower: scale power (and the sodium rise with it, flow unchanged) until the hottest pin peaks at the §2.4 figure
    scale = LHR_MELT / (lhr_hot * PEAK_AXIAL)
    centre_60 = channel(pellet, lhr_hot * scale, outlet_at_scale(T_OUT_HOT, scale), R_cna, R_gap, "centre")
    print(f"  hot-pin centreline at {LHR_MELT / 1e3:.0f} kW/m peak ({scale * 100:.0f} %FP): {centre_60 - 273.15:.0f} °C   "
          f"(spec: melting ≈ 2,700 °C above ≈ {LHR_MELT / 1e3:.0f} kW/m; difference {centre_60 - T_MELT:+.0f} K)")
    lhr_melt = brentq(lambda s: channel(pellet, lhr_hot * s, outlet_at_scale(T_OUT_HOT, s), R_cna, R_gap, "centre") - T_MELT, 0.5, 3.0)
    print(f"  peak linear heat rate at which the centreline reaches 2,700 °C: {lhr_hot * PEAK_AXIAL * lhr_melt / 1e3:.1f} kW/m")

    # time constant of the core-average fuel temperature for a small power change (coolant held)
    y_avg = sum(PU[z] * ASSEMBLIES[z] for z in PU) / sum(ASSEMBLIES.values())
    area = math.pi * (R_O ** 2 - R_I ** 2)
    mass = rho_273(y_avg) * DENSITY_FRACTION * area  # kg/m, conserved through expansion
    T_mid_na = sodium_profile(T_OUT_AVG)[len(ZETA) // 2]
    Ts = T_mid_na + LHR_AVG * (R_cna + R_gap)
    Tf = pellet.average(Ts, LHR_AVG)
    dq = 50.0
    Tf2 = pellet.average(Ts + dq * (R_cna + R_gap), LHR_AVG + dq)
    R_inc = (Tf2 - Tf) / dq
    R_sec = (Tf - T_mid_na) / LHR_AVG
    C = mass * cp_mox(Tf, y_avg)
    print(f"  fuel time constant at the average midplane (T_f {Tf:.0f} K, C_f {C:.1f} J/m/K): "
          f"incremental {C * R_inc:.2f} s, secant {C * R_sec:.2f} s   (spec §3.2 Doppler lag 4 s)")

    # sensitivities of the derived resistances and checks
    print("\nSensitivity (what each uncertain input does to the result):")
    for label, kw in (("hottest outlet 580 °C", dict(T_hot=580 + 273.15)), ("hottest outlet 585 °C", dict(T_hot=585 + 273.15)),
                      ("burnup 0 (fresh core)", dict(B=0.0)), ("burnup 5.44 at.% (discharge)", dict(B=2 * BURNUP)),
                      ("conductivity −7 % (Carbajo 1σ)", dict(kscale=0.93)), ("conductivity +7 %", dict(kscale=1.07))):
        T_hot = kw.get("T_hot", T_OUT_HOT)
        p = Pellet(B=kw.get("B", BURNUP))
        if "kscale" in kw:
            p.theta = p.theta * kw["kscale"]
        rc = brentq(lambda R: channel(p, lhr_hot, T_hot, R, 0, "clad") - T_CLAD_HOTSPOT, 0.0, 0.02)
        rg = brentq(lambda R: channel(p, LHR_AVG, T_OUT_AVG, rc, R, "fuel") - T_FUEL_AVG, -0.01, 0.05)
        ch = channel(p, lhr_hot, T_hot, rc, rg, "centre")
        print(f"  {label:32} R_cna {rc * 1e3:.3f}  R_gap {rg * 1e3:.3f}  hot centreline {ch - 273.15:.0f} °C")

    # radial non-linearity: the core average over assemblies with ±20 % power at the same average
    lo = channel(pellet, LHR_AVG * 0.8, T_OUT_AVG, R_cna, R_gap, "fuel")  # flow follows power: same outlet
    hi = channel(pellet, LHR_AVG * 1.2, T_OUT_AVG, R_cna, R_gap, "fuel")
    print(f"\nRadial non-linearity: mean of ±20 % channels {0.5 * (lo + hi):.1f} K vs average channel {T_avg4:.1f} K "
          f"(flow follows power in each channel)")
    write_luau(pellet, R_cna, R_gap, y_avg)
    write_fixture(pellet, R_cna, R_gap, lhr_hot, y_avg)


def discrete_sodium(shapes, T_out):
    """
    The game's sodium algebra (FuelThermal.step at steady state): each layer adds heat ∝ its shape; the layer
    temperature is the mean of its inlet and outlet, with c_p taken at that mean; the flow puts the outlet at T_out.
    """
    def run(heat_per_flow):
        T_in, mids = T_IN, []
        for s in shapes:
            mid = T_in
            for _ in range(200):
                new = T_in + heat_per_flow * s / (2 * cp_na(mid))
                done = abs(new - mid) < 1e-13
                mid = new
                if done:
                    break
            mids.append(mid)
            T_in = T_in + heat_per_flow * s / cp_na(mid)
        return mids, T_in

    k = brentq(lambda x: run(x)[1] - T_out, 1.0, 1e7, xtol=1e-12, rtol=1e-15)
    return run(k)[0]


def discrete(pellet, lhr_avg, T_out, R_cna, R_gap, layers=10):
    """The same channel on the game's axial mesh: layer-average power, sodium as FuelThermal computes it."""
    edges = np.linspace(-1, 1, layers + 1)
    shapes = [(math.sin(U * edges[l + 1]) - math.sin(U * edges[l])) / (U * (edges[l + 1] - edges[l])) * U / math.sin(U)
              for l in range(layers)]
    sodium = discrete_sodium(shapes, T_out)
    out = []
    for l, s in enumerate(shapes):
        q = lhr_avg * s
        T_na = sodium[l]
        T_c = T_na + q * R_cna
        T_s = T_c + q * R_gap
        out.append({"shape": s, "q": q, "Tna": T_na, "Tc": T_c, "Tf": pellet.average(T_s, q), "Tcentre": pellet.centre(T_s, q)})
    return out


def write_fixture(pellet, R_cna, R_gap, lhr_hot, y_avg):
    """tests/PinThermalExpected.luau: the 10-layer values FuelThermalSpec compares against (not a Spec itself)."""
    avg = discrete(pellet, LHR_AVG, T_OUT_AVG, R_cna, R_gap)
    hot = discrete(pellet, lhr_hot, T_OUT_HOT, R_cna, R_gap)
    area = math.pi * (R_O ** 2 - R_I ** 2)
    mass = rho_273(y_avg) * DENSITY_FRACTION * area
    taus = []
    for layer in avg:  # incremental time constant with the coolant held, per layer
        dq = 50.0
        T_s = layer["Tc"] + layer["q"] * R_gap
        T2 = pellet.average(T_s + dq * (R_cna + R_gap), layer["q"] + dq)
        taus.append(mass * cp_mox(layer["Tf"], y_avg) * (T2 - layer["Tf"]) / dq)
    core_avg = sum(l["Tf"] for l in avg) / len(avg)
    print(f"10-layer average channel: core-average fuel {core_avg:.3f} K; hot channel: clad max "
          f"{max(l['Tc'] for l in hot) - 273.15:.2f} °C, centre max {max(l['Tcentre'] for l in hot) - 273.15:.1f} °C; "
          f"layer time constants {min(taus):.3f}–{max(taus):.3f} s")

    def arr(key, rows):
        return "{ " + ", ".join(f"{r[key]:.9g}" for r in rows) + " }"

    text = f"""--!strict
-- GENERATED by {REF} — do not edit. Expected values for FuelThermalSpec on the game's 10-layer mesh.
-- Average channel: every assembly at 27.7 kW/m average with outlet 559 °C. Hot channel: hottest pin (radial × pin
-- factors) with its assembly outlet at 582.5 °C. q is the pin linear heat rate (W/m), temperatures in K.
return {{
	inletTemperature_K = {T_IN:.9g},
	average = {{
		outlet_K = {T_OUT_AVG:.9g},
		q_Wpm = {arr("q", avg)},
		sodium_K = {arr("Tna", avg)},
		fuel_K = {arr("Tf", avg)},
		coreAverageFuel_K = {core_avg:.9g},
		layerTimeConstantMin_s = {min(taus):.9g},
		layerTimeConstantMax_s = {max(taus):.9g},
	}},
	hot = {{
		outlet_K = {T_OUT_HOT:.9g},
		hotPinQ_Wpm = {arr("q", hot)},
		cladMidwallMax_K = {max(l["Tc"] for l in hot):.9g},
		centreMax_K = {max(l["Tcentre"] for l in hot):.9g},
	}},
}}
"""
    path = REPO / "tests" / "PinThermalExpected.luau"
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {path.relative_to(REPO)}")


def fmt(values, per_line=10, digits=6):
    items = [f"{v:.{digits}g}" for v in values]
    lines = [", ".join(items[i:i + per_line]) for i in range(0, len(items), per_line)]
    return "{\n\t\t\t" + ",\n\t\t\t".join(lines) + ",\n\t\t}"


def write_luau(pellet, R_cna, R_gap, y_avg):
    rq, gq, wq = pellet.q
    cp_grid = np.arange(300.0, 3100.0 + 1e-9, 100.0)
    area = math.pi * (R_O ** 2 - R_I ** 2)
    heat = {}
    for zone, y in PU.items():
        mass = rho_273(y) * DENSITY_FRACTION * area
        heat[zone] = [mass * cp_mox(T, y) for T in cp_grid]
    text = f"""--!strict
-- GENERATED by {REF} — do not edit. Re-run the script to change these values.
-- Fuel-pin thermal model inputs (spec §2.3, §2.4, §3.2, §14.3; Carbajo et al., ORNL/TM-2000/351).
local P = require(script.Parent.Provenance)
local derived, spec = P.derived, P.spec

return {{
	-- pellet: annulus with an adiabatic hole; g factors are dimensionless (Θ(T) − Θ(T_s) = q'·g)
	pellet = spec({{
		outerRadius_m = {R_O:.6g},
		innerRadius_m = {R_I:.6g},
		densityFraction = {DENSITY_FRACTION},
	}}, "§2.3"),
	conduction = derived({{
		burnup_atPct = {BURNUP:.6g},
		centreG = {G_CENTRE:.8g},
		-- 4-point Gauss–Legendre volume average over the annulus
		quadratureG = {{ {", ".join(f"{v:.8g}" for v in gq)} }},
		quadratureWeight = {{ {", ".join(f"{v:.8g}" for v in wq)} }},
		-- conductivity integral Θ(T) = ∫k dT (W/m) on a uniform temperature grid
		thetaT0_K = {T_GRID[0]:.6g},
		thetaStep_K = {T_GRID[1] - T_GRID[0]:.6g},
		theta_Wpm = {fmt(pellet.theta, per_line=8, digits=10)},
	}}, "{REF}"),
	-- heat capacity per metre of pellet (J/(m·K)) on a uniform grid, per zone Pu fraction
	heatCapacity = derived({{
		T0_K = {cp_grid[0]:.6g},
		step_K = {cp_grid[1] - cp_grid[0]:.6g},
		inner_JpmK = {fmt(heat["inner"])},
		outer_JpmK = {fmt(heat["outer"])},
	}}, "{REF}"),
	-- thermal resistances per unit length (K per W/m)
	resistance = derived({{
		gap_mKpW = {R_gap:.10g}, -- pellet surface → cladding midwall (fixed by the §3.2 core-average 1,380 K)
		cladToSodium_mKpW = {R_cna:.10g}, -- cladding midwall → sodium (fixed by the §2.4 620 °C hot spot)
	}}, "{REF}"),
	-- the spec figures the derivation reproduces or checks, for tests
	targets = spec({{
		coreAverageFuel_K = {T_FUEL_AVG:.6g},
		cladHotSpot_K = {T_CLAD_HOTSPOT:.6g},
		hotPinCentre_K = {T_CENTRE_HOT:.6g},
		averageLinearHeat_Wpm = {LHR_AVG:.6g},
	}}, "§2.4, §3.2"),
}}
"""
    OUT_LUAU.write_text(text, encoding="utf-8", newline="\n")
    print(f"\nwrote {OUT_LUAU.relative_to(REPO)} (Pu average {y_avg:.4f})")


if __name__ == "__main__":
    main()
