"""
Pools and cover gas: check the §4.1 / §4.4 model against the spec's own figures.

The Pools system models the primary sodium as four well-mixed nodes (hot pool 40 s + 18 s, cold pool 52 s, plus an
8 s transport delay) sharing one argon cover gas space. Every one of those numbers is in the spec, but the spec does
not say *why* they are consistent with each other. This script shows that they are, and pins down the two figures the
model needs that §4.1 does not state directly:

  1. the mixing times are residence times, m_pool / m_dot at rated flow, so they must scale as 1/flow in the model
  2. the node masses follow from the same identity (40 s and 18 s of flow)
  3. the hot/cold level tilt shares conserve sodium volume across the two free surfaces
  4. the cover gas behaves as an ideal gas over the volume the sodium vacates, which reproduces the stated
     90 m3 swing, the 0.26 m and 0.64 m mean level rises, and the 0.074 MPa fixed-inventory cooldown pressure
  5. the make-up / vent controller time constant of D-020, and the valve capacity it implies

Sodium density is Appendix A (Fink & Leibowitz), the same correlation shared/Props/Sodium.luau implements.
Run: python tools/derive/pool_gas.py
"""
import math

KELVIN = 273.15
R_GAS = 8.314462618  # J/(mol K), exact in SI since the 2019 redefinition

# Appendix A density: rho(T) = a + b x + c sqrt(x),  x = 1 - T/Tc
RHO_A, RHO_B, RHO_C, T_CRIT = 219.0, 275.32, 511.58, 2503.7

# §4.1 inventory
M_HOT, M_COLD, M_CORE = 620e3, 560e3, 70e3          # kg
M_TOTAL = 1250e3
A_HOT, A_COLD = 95.0, 45.0                          # m2 of free surface
HOT_NODES_S = (40.0, 18.0)
COLD_MIXING_S = 52.0
TRANSPORT_S = 8.0
HOT_SHARE, COLD_SHARE = 0.32, 0.68
DELTA_L_RATED_M = 1.5

# §1.1 / §4.2 / §4.3 operating point
FLOW_RATED = 10694.0                                # kg/s
T_HOT_100 = 550.0 + KELVIN                          # mixed core outlet (§2.4, IHX primary inlet §4.3)
T_COLD_100 = 375.0 + KELVIN                         # core inlet, IHX primary outlet
T_ISO_230 = 230.0 + KELVIN                          # the refuelling / cold-standby isothermal state of §4.4
T_ISO_375 = 375.0 + KELVIN                          # the isothermal datum §4.1 quotes level rises from

# §4.4 cover gas
V_GAS_100 = 320.0
P_SET = 0.120e6
BAND = (0.115e6, 0.125e6)
GAS_T_POWER, GAS_T_COLD = 300.0 + KELVIN, 180.0 + KELVIN
CONTROL_TAU_S = 60.0                                # D-020
LCO11_RATE_KPMIN = 1.5                              # §9.6 LCO-11: hot pool rate of change limit


def rho(T):
    x = 1.0 - T / T_CRIT
    return RHO_A + RHO_B * x + RHO_C * math.sqrt(x)


def sodium_volume(T_hot, T_cold):
    """Pool volumes at their own temperatures; the core and diagrid sit at the mean of the two."""
    return M_HOT / rho(T_hot) + M_COLD / rho(T_cold) + M_CORE / rho(0.5 * (T_hot + T_cold))


def isothermal_volume(T):
    return M_TOTAL / rho(T)


def gas_temperature(T_hot):
    """Linear in the hot pool temperature between the two points the spec's own calc gives (file 20)."""
    f = (T_hot - T_ISO_230) / (T_HOT_100 - T_ISO_230)
    return GAS_T_COLD + f * (GAS_T_POWER - GAS_T_COLD)


checks = []


def check(label, got, want, tol, unit=""):
    ok = abs(got - want) <= tol
    checks.append(ok)
    mark = "ok  " if ok else "FAIL"
    print(f"  {mark} {label:<52} {got:10.4f} vs {want:8.3f} {unit:<6} (tol {tol:g})")


print("Node masses and residence times (§4.1)")
# m_pool / m_dot at rated flow
check("hot pool residence time", M_HOT / FLOW_RATED, sum(HOT_NODES_S), 0.5, "s")
check("cold pool residence time", M_COLD / FLOW_RATED, COLD_MIXING_S, 0.5, "s")
m1 = HOT_NODES_S[0] * FLOW_RATED
m2 = HOT_NODES_S[1] * FLOW_RATED
check("40 s + 18 s of rated flow = hot pool mass", (m1 + m2) / 1e3, M_HOT / 1e3, 1.0, "t")
print(f"       -> node masses {m1/1e3:.1f} t and {m2/1e3:.1f} t; the model splits M_HOT by tau_i / sum(tau)")

print("\nLevel tilt (§4.1)")
# hot pool rises by hotShare*dL over A_HOT, cold pool falls by coldShare*dL over A_COLD: the sodium has to balance
check("tilt conserves volume: hotShare*A_hot = coldShare*A_cold",
      HOT_SHARE * A_HOT, COLD_SHARE * A_COLD, 0.5, "m3/m")
print(f"       -> at rated flow the tilt moves {HOT_SHARE * A_HOT * DELTA_L_RATED_M:.1f} m3 from cold pool to hot pool")

print("\nThermal expansion, levels and cover gas volume (§4.1, §4.4)")
V100 = sodium_volume(T_HOT_100, T_COLD_100)
V230 = isothermal_volume(T_ISO_230)
V375 = isothermal_volume(T_ISO_375)
check("gas volume swing, 230 C isothermal to 100 %", V100 - V230, 90.0, 1.0, "m3")
# F31: §4.1's 0.26 m and 0.64 m were computed with the hot pool at 545 C, the IHX primary inlet Rev A4 replaced
# with 550 C (545 carried only 385 MWt per unit and left the primary 79 MWt short). At 550 C the same calculation
# gives 0.266 m and 0.645 m. The tolerance below spans the two, because the spec figure is the stale one.
V100_545 = sodium_volume(545.0 + KELVIN, T_COLD_100)
print(f"       (at the pre-Rev-A4 545 C hot pool the same model gives "
      f"{(V100_545 - V375) / (A_HOT + A_COLD):.4f} m and {(V100_545 - V230) / (A_HOT + A_COLD):.4f} m — F31)")
check("mean level rise, 375 C isothermal to 100 %", (V100 - V375) / (A_HOT + A_COLD), 0.26, 0.01, "m")
check("mean level rise, 230 C isothermal to 100 %", (V100 - V230) / (A_HOT + A_COLD), 0.64, 0.01, "m")

print("\nCover gas pressure (§4.4)")
n_ref = P_SET * V_GAS_100 / (R_GAS * gas_temperature(T_HOT_100))
check("gas temperature at 100 %", gas_temperature(T_HOT_100) - KELVIN, 300.0, 0.5, "C")
check("gas temperature at the 230 C state", gas_temperature(T_ISO_230) - KELVIN, 180.0, 0.5, "C")
print(f"       -> inventory at the setpoint {n_ref:.0f} mol = {n_ref * 39.948e-3:.0f} kg of argon")
V_cold = V_GAS_100 + (V100 - V230)
P_cold = n_ref * R_GAS * gas_temperature(T_ISO_230) / V_cold
check("cooldown to 230 C on a fixed inventory", P_cold / 1e6, 0.074, 0.001, "MPa")

print("\nMake-up and vent controller (D-020)")
# authority at the band edge: dn/dt = (n_setpoint - n_edge)/tau
n_edge = BAND[0] * V_GAS_100 / (R_GAS * gas_temperature(T_HOT_100))
capacity = (n_ref - n_edge) / CONTROL_TAU_S
# the duty it has to cover: holding pressure while the pool expands at LCO-11's limit
dVdT = (V100 - V230) / (T_HOT_100 - T_ISO_230)  # m3 per K of pool temperature
need_lco11 = P_SET * (dVdT * LCO11_RATE_KPMIN / 60.0) / (R_GAS * gas_temperature(T_HOT_100))
print(f"       capacity at the band edge          {capacity:8.2f} mol/s")
print(f"       needed to hold 1.5 K/min (LCO-11)  {need_lco11:8.2f} mol/s  -> margin x{capacity / need_lco11:.0f}")
# the fastest volume change the plant can make: a trip collapses the hot pool toward the cold pool in minutes
for minutes in (5, 10, 20):
    rate = P_SET * ((V100 - V230) / (minutes * 60.0)) / (R_GAS * gas_temperature(T_HOT_100))
    print(f"       the whole {V100 - V230:.0f} m3 swing in {minutes:2d} min      {rate:8.2f} mol/s"
          f"  -> {'covered' if rate <= capacity else 'NOT covered'}")

print(f"\n{sum(checks)}/{len(checks)} checks pass")
raise SystemExit(0 if all(checks) else 1)
