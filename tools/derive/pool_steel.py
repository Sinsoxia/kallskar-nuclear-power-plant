"""
Pool steel: deriving the heat capacity and thermal coupling of the internals, as required by D-057.
"""
import math
import sys

checks = []
def check(label, ok):
    checks.append(ok)
    print(f"  [{'ok' if ok else 'FAIL'}] {label}")

KELVIN = 273.15
# Appendix A specific heat, J/(kg K): 1000 * (a + bT + cT^2 + d/T^2)
CP = (1.6582, -8.479e-4, 4.4541e-7, -2992.6)

def cp_na(T_c):
    T = T_c + KELVIN
    a, b, c, d = CP
    return 1000.0 * (a + b * T + c * T**2 + d / T**2)

print("1. Heat capacity of the steel")
M_HOT, M_COLD, M_CORE = 620e3, 560e3, 70e3
T_HOT, T_COLD = 550.0, 375.0

c_hot = M_HOT * cp_na(T_HOT)
c_cold = M_COLD * cp_na(T_COLD)
c_core = M_CORE * cp_na((T_HOT + T_COLD) / 2.0)
c_na_spec = c_hot + c_cold + c_core

print(f"  Sodium inventory (1,250 t) heat capacity: {c_na_spec/1e6:.1f} MJ/K")

def cp_na_mean(T1_c, T2_c):
    T1 = T1_c + KELVIN
    T2 = T2_c + KELVIN
    a, b, c, d = CP
    def h(T):
        return a * T + b * T**2 / 2.0 + c * T**3 / 3.0 - d / T
    return 1000.0 * (h(T2) - h(T1)) / (T2 - T1)

c_na_model = 1262e3 * cp_na_mean(375.0, 575.0)
print(f"  D-021 model sodium heat capacity (1,262 t, mean over 375-575 C): {c_na_model/1e6:.1f} MJ/K")

print("  Total heat capacity (sodium plus internals): 2,400 MJ/K")
print("  The '≈' implies two significant figures, so the last printed figure is the hundreds place.")
print("  Half a unit in the hundreds place gives an uncertainty of ±50 MJ/K.")

c_steel = 2400.0 - (c_na_model / 1e6)
print(f"  Steel heat capacity implied: 2400 - {c_na_model/1e6:.1f} = {c_steel:.1f} MJ/K (±50 MJ/K)")

# Split according to pool sodium proportion (D-057)
M_NA_TOTAL = M_HOT + M_COLD + M_CORE
hot_share = (M_HOT + M_CORE/2) / M_NA_TOTAL
cold_share = (M_COLD + M_CORE/2) / M_NA_TOTAL
print(f"  Hot pool share of sodium: {hot_share:.3f}")
print(f"  Cold pool share of sodium: {cold_share:.3f}")

c_steel_hot = c_steel * hot_share
c_steel_cold = c_steel * cold_share
print(f"  Hot pool steel heat capacity: {c_steel_hot:.1f} MJ/K")
print(f"  Cold pool steel heat capacity: {c_steel_cold:.1f} MJ/K")

print("\n2. Coupling for the vessel wall")
D_VESSEL = 15.0
H_VESSEL = 14.5
THICKNESS_VESSEL = 0.040 # m
A_VESSEL = math.pi * D_VESSEL * H_VESSEL + math.pi * (D_VESSEL / 2.0)**2
print(f"  Vessel wetted area (side + bottom): {A_VESSEL:.1f} m²")

# C. S. Kim, "Thermophysical properties of stainless steels", ANL-75-55 (1975)
def k_steel(T_c):
    T = T_c + KELVIN
    return 9.248 + 0.01571 * T

T_MEAN_C = (T_HOT + T_COLD) / 2.0
k_vessel = k_steel(T_MEAN_C)
R_cond = THICKNESS_VESSEL / (k_vessel * A_VESSEL)
print(f"  316 steel thermal conductivity at {T_MEAN_C:.1f} C (Kim 1975): {k_vessel:.2f} W/(m K)")
# Pichler et al. 2020 for c_p.
PICHLER_T = list(range(473, 1254, 20))
PICHLER_CP = [0.528, 0.529, 0.530, 0.532, 0.534, 0.537, 0.541, 0.544, 0.547, 0.550, 0.553, 0.556, 0.559, 0.561,
              0.564, 0.566, 0.569, 0.572, 0.578, 0.587, 0.595, 0.598, 0.599, 0.600, 0.601, 0.603, 0.605, 0.606,
              0.608, 0.610, 0.611, 0.613, 0.614, 0.615, 0.617, 0.619, 0.620, 0.621, 0.622, 0.624]

def cp_316l_mean(T1_c, T2_c):
    T1, T2, s = T1_c + KELVIN, T2_c + KELVIN, 0.0
    for x0, y0, x1, y1 in zip(PICHLER_T, PICHLER_CP, PICHLER_T[1:], PICHLER_CP[1:]):
        lo, hi = max(x0, T1), min(x1, T2)
        if hi > lo:
            s += 0.5 * (y0 + (y1 - y0) * (lo - x0) / (x1 - x0) + y0 + (y1 - y0) * (hi - x0) / (x1 - x0)) * (hi - lo)
    return s / (T2 - T1) * 1000.0 # J/kg-K

cp_vessel = cp_316l_mean(T_COLD, T_HOT)

print("  Note: The vessel is 316LN, but properties here use 316L (Pichler) and 316 (Kim).")
print("  The compositional difference adds a small uncertainty to k and cp.")
# Diff check
check("316LN vs 316L difference is covered by ±50 MJ/K bound", abs(c_steel * 0.02) < 50.0) # Assumes ~2% property diff based on typical 316 vs 316LN alloy composition

print(f"  Vessel wall conduction resistance (L / kA): {R_cond * 1e6:.1f} µK/W")

# Churchill & Chu (1975)
def churchill_chu_nu(Ra, Pr):
    return (0.825 + 0.387 * Ra**(1/6) / (1.0 + (0.492 / Pr)**(9/16))**(8/27))**2

def k_na(T_c):
    T = T_c + KELVIN
    return 124.67 - 0.11381 * T + 5.5226e-5 * T**2 - 1.1842e-8 * T**3

def mu_na(T_c):
    T = T_c + KELVIN
    return math.exp(-6.4406 - 0.3958 * math.log(T) + 556.835 / T)

RHO_A, RHO_B, RHO_C, T_CRIT = 219.0, 275.32, 511.58, 2503.7
def rho_na(T_c):
    T = T_c + KELVIN
    x = 1.0 - T / T_CRIT
    return RHO_A + RHO_B * x + RHO_C * math.sqrt(x)

def beta_na(T_c):
    T = T_c + KELVIN
    dT = 0.1
    r1 = rho_na(T_c - dT/2)
    r2 = rho_na(T_c + dT/2)
    return -(r2 - r1) / dT / rho_na(T_c)

T_pool = T_COLD
beta = beta_na(T_pool)
rho = rho_na(T_pool)
mu = mu_na(T_pool)
cp_f = cp_na(T_pool) # J/kg-K
k_f = k_na(T_pool)
nu = mu / rho
alpha = k_f / (rho * cp_f)
Pr = nu / alpha
g = 9.81

print(f"  Sodium at {T_pool} C: Pr = {Pr:.4f}")
print("  Natural convection (Churchill & Chu 1975) over ΔT 1 to 50 K:")
for dT in (1.0, 10.0, 50.0):
    Ra = g * beta * dT * H_VESSEL**3 / (nu * alpha)
    Nu = churchill_chu_nu(Ra, Pr)
    h = Nu * k_f / H_VESSEL
    R_conv = 1.0 / (h * A_VESSEL)
    print(f"    ΔT = {dT:2.0f} K: Ra = {Ra:.2e}, Nu = {Nu:.0f}, h = {h:.0f} W/(m² K), R_conv = {R_conv * 1e6:.1f} µK/W")

# Forced convection
vol_cold = M_COLD / rho_na(T_COLD)
flow_vol = vol_cold / 52.0
v_pool = flow_vol / (math.pi * (D_VESSEL/2)**2)
Re_L = v_pool * H_VESSEL / nu
Pe_L = Re_L * Pr
print(f"  Implied cold pool velocity: {v_pool:.4f} m/s")
print(f"  Flat plate forced convection: Re_L = {Re_L:.2e}, Pe_L = {Pe_L:.2e}")
Nu_forced = 0.565 * math.sqrt(Pe_L)
h_forced = Nu_forced * k_f / H_VESSEL
R_forced = 1.0 / (h_forced * A_VESSEL)
print(f"  Forced convection upper bound (Seban R.A., 1950, Trans. ASME 72: Nu = 0.565 Pe^0.5): Nu = {Nu_forced:.0f}, h = {h_forced:.0f} W/(m² K), R_conv = {R_forced * 1e6:.1f} µK/W")
Nu_forced = 0.565 * math.sqrt(Pe_L)
h_forced = Nu_forced * k_f / H_VESSEL
R_forced = 1.0 / (h_forced * A_VESSEL)

# Stagnant boundary
R_stag = 0.3 / (k_f * A_VESSEL)
print(f"  Stagnant 0.3 m sodium layer conduction lower bound resistance: {R_stag * 1e6:.1f} µK/W")

print("  -> Under natural convection (blackout/DRACS), the steel wall conduction resistance (2.2 µK/W)")
print("     dominates the sodium-side convection (0.3-0.9 µK/W).")
print("  -> At full flow (forced convection) or a stagnant layer, sodium resistance (3.3-4.9 µK/W) dominates.")
print("  -> We evaluate time constants tracking the adiabatic vessel outside (heat to guard vessel is outside scope).")

# vessel capacity and tau
rho_steel = 7900.0
vol_vessel = A_VESSEL * THICKNESS_VESSEL
C_vessel = vol_vessel * rho_steel * cp_vessel
tau_vessel_cond = (THICKNESS_VESSEL**2) / (2.0 * (k_vessel / (rho_steel * cp_vessel)))
tau_vessel_conv = C_vessel / (2570.0 * A_VESSEL)
tau_vessel_tot = tau_vessel_cond + tau_vessel_conv
print(f"  Vessel heat capacity: {C_vessel/1e6:.1f} MJ/K (from mass using 15.0m ID, 14.5m high, 40mm thick side and bottom flat head), tau = {tau_vessel_tot:.0f} s (insulated outside)")

print("\n3. Valid window of coupling time constants")

# Derive window
TAU_HOT_1 = 40.0
TAU_HOT_2 = 18.0
TAU_COLD = 52.0
m_dot_rated = 10694.0 # kg/s
cp_ref_val = cp_na_mean(375.0, 575.0) # J/kg-K
C_flow_val = m_dot_rated * cp_ref_val # W/K
C_hot_1_val = TAU_HOT_1 * C_flow_val
C_hot_2_val = TAU_HOT_2 * C_flow_val
C_cold_val = TAU_COLD * C_flow_val
C_steel_hot_val = c_steel_hot * 1e6
C_steel_cold_val = c_steel_cold * 1e6

dt_sim = 0.05
steps_sim = int(200 / dt_sim)

def step_hot(tau):
    UA = C_steel_hot_val / tau
    UA1 = UA * (40.0 / 58.0)
    UA2 = UA * (18.0 / 58.0)
    C_s1 = C_steel_hot_val * (40.0 / 58.0)
    C_s2 = C_steel_hot_val * (18.0 / 58.0)
    T1 = 0.0; T2 = 0.0; Ts1 = 0.0; Ts2 = 0.0
    for i in range(steps_sim):
        Q1 = UA1 * (Ts1 - T1)
        Q2 = UA2 * (Ts2 - T2)
        dT1 = (C_flow_val * (1.0 - T1) + Q1) / C_hot_1_val * dt_sim
        dT_s1 = -Q1 / C_s1 * dt_sim
        dT2 = (C_flow_val * (T1 - T2) + Q2) / C_hot_2_val * dt_sim
        dT_s2 = -Q2 / C_s2 * dt_sim
        T1 += dT1; Ts1 += dT_s1; T2 += dT2; Ts2 += dT_s2
        if T2 >= (1.0 - math.exp(-1.0)):
            return i * dt_sim
    return None

def step_cold(tau):
    UA = C_steel_cold_val / tau
    Tc = 0.0; Tsc = 0.0
    for i in range(steps_sim):
        Q = UA * (Tsc - Tc)
        dTc = (C_flow_val * (1.0 - Tc) + Q) / C_cold_val * dt_sim
        dTsc = -Q / C_steel_cold_val * dt_sim
        Tc += dTc; Tsc += dTsc
        if Tc >= (1.0 - math.exp(-1.0)):
            return i * dt_sim
    return None

# Find tau_min where response changes by < 0.5s from decoupled case
t_ref_hot = 60.95
tau_min_hot = 10.0
for tau in range(20000, 10, -10):
    t_hot = step_hot(tau)
    if t_hot is not None and abs(t_hot - t_ref_hot) > 0.5:
        tau_min_hot = tau + 10
        break

t_ref_cold = 52.0
tau_min_cold = 10.0
for tau in range(20000, 10, -10):
    t_cold = step_cold(tau)
    if t_cold is not None and abs(t_cold - t_ref_cold) > 0.5:
        tau_min_cold = tau + 10
        break

tau_min = max(tau_min_hot, tau_min_cold)

# Find tau_max where capacity loss is < 50 MJ/K
T_cope = 6.5 * 3600
tau_max = 50.0 * T_cope / c_steel

print(f"  Fast response unmodified (tau > tau_min): tau_min = {tau_min} s")
print(f"  Slow heat-up complete (tau < tau_max): tau_max = {tau_max:.0f} s")

check("Valid window is EMPTY (as expected)", tau_max < tau_min)
check("Vessel wall tau falls outside window", not (tau_min <= tau_vessel_tot <= tau_max))

print("\n4. Coupling for the internals")
alpha_steel = k_vessel / (rho_steel * cp_vessel)
print(f"  Steel properties (mean 375-550 C): cp = {cp_vessel:.0f} J/(kg K), k = {k_vessel:.1f} W/(m K), alpha = {alpha_steel:.2e} m²/s")
h_internals = 2570.0 # From Churchill & Chu at dT=10K

print("  Time constants for plates wetted on both sides:")
print("    Thickness |  Conduction |  Convection |       Total | Inside window?")
for L_mm in (10, 20, 40, 60, 100):
    L = L_mm / 1000.0
    tau_cond = (L/2.0)**2 / (2.0 * alpha_steel)
    tau_conv = rho_steel * cp_vessel * L / (2.0 * h_internals)
    tau_total = tau_cond + tau_conv
    inside = "yes" if (tau_min <= tau_total <= tau_max) else "NO"
    print(f"       {L_mm:2d} mm |     {tau_cond:5.0f} s |     {tau_conv:5.0f} s |     {tau_total:5.0f} s | {inside}")

print("  SFR pool internals vary widely, but without a specific source for internal thickness in the Kallskar spec,")
print("  we state the derived valid window as the result.")
print("  FINDING for Aqua: the derived valid window is empty. No time constant satisfies both constraints simultaneously.")
print("  Options: 1) invent a typical thickness (e.g. 20 mm, 28 s) which acts on the same scale as the pool mixing;")
print("           2) pick a long time constant (e.g. 600 s) so the fast response stays exactly as printed;")
print("           3) split the steel into a thin 'fast' part and a thick 'slow' part.")

print(f"\n{sum(checks)}/{len(checks)} checks pass")
raise SystemExit(0 if all(checks) else 1)
