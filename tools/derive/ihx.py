"""
Intermediate heat exchangers: check the epsilon-NTU model against §4.3's own figures.

§4.3 states six IHXs, each 396 MWt at 100 %, with 1,782 kg/s of primary sodium entering at 550 °C and leaving at
375 °C, 1,556 kg/s of secondary sodium entering at 320 °C and leaving at 520 °C, LMTD about 41 K and UA about
9.6 MW/K over roughly 2,000 m2. Those are five statements about the same exchanger, so four of them are checks on
the fifth. This script shows they agree, and that a counter-flow epsilon-NTU model driven by UA alone reproduces all
of them -- which is what lets the Luau system compute duty from the live temperatures instead of carrying 396 MWt
as a constant.

epsilon-NTU is used rather than iterating on LMTD because it is closed-form for counter-flow, needs no initial
guess, and stays well behaved at the operating points a simulator actually visits: one side stopped, natural
circulation, a shutter at its 5 % leak-by.

Sodium properties are Appendix A, as in shared/Props/Sodium.luau.
Run: python tools/derive/ihx.py
"""
import math

KELVIN = 273.15
# Appendix A specific heat, J/(kg K): 1000 * (a + bT + cT^2 + d/T^2)
CP = (1.6582, -8.479e-4, 4.4541e-7, -2992.6)

# §4.3
UNITS = 6
UA = 9.6e6                    # W/K
DUTY_EACH = 396e6             # W at 100 %
M_PRIMARY = 1782.0            # kg/s each
M_SECONDARY = 1556.0          # kg/s each
T_P_IN, T_P_OUT = 550.0, 375.0
T_S_IN, T_S_OUT = 320.0, 520.0
LMTD_SPEC = 41.0
# §1.1 / §4.2
CORE_MWT = 2380.0
PUMP_MWT = 10.0


def cp(T):
    a, b, c, d = CP
    return 1000.0 * (a + T * (b + T * c) + d / (T * T))


def effectiveness(ua, c_hot, c_cold):
    """Counter-flow effectiveness. Returns 0 if either stream has stopped."""
    c_min, c_max = min(c_hot, c_cold), max(c_hot, c_cold)
    if c_min <= 0.0:
        return 0.0
    ntu = ua / c_min
    cr = c_min / c_max
    if cr > 0.999999:                      # balanced flow: the general form is 0/0 here
        return ntu / (1.0 + ntu)
    e = math.exp(-ntu * (1.0 - cr))
    return (1.0 - e) / (1.0 - cr * e)


def duty(ua, m_p, t_p_in, m_s, t_s_in, passes=3):
    """Heat transferred, W. c_p is taken at each stream's own mean temperature, converged by repetition."""
    t_p_out, t_s_out = t_p_in, t_s_in
    q = 0.0
    for _ in range(passes):
        c_p_ = m_p * cp(0.5 * (t_p_in + t_p_out) + KELVIN)
        c_s_ = m_s * cp(0.5 * (t_s_in + t_s_out) + KELVIN)
        c_min = min(c_p_, c_s_)
        q = effectiveness(ua, c_p_, c_s_) * c_min * (t_p_in - t_s_in)
        t_p_out = t_p_in - (q / c_p_ if c_p_ > 0 else 0.0)
        t_s_out = t_s_in + (q / c_s_ if c_s_ > 0 else 0.0)
    return q, t_p_out, t_s_out


def lmtd(t_p_in, t_p_out, t_s_in, t_s_out):
    """
    Counter-flow log-mean temperature difference, from the four temperatures alone. Degenerate once an approach
    reaches zero: at very low primary flow epsilon rounds to exactly 1 in double precision, the primary leaves at
    the secondary inlet temperature, and the log form divides by zero even though the duty is perfectly finite.
    The exchanger is then thermodynamically limited rather than area limited, so the honest report is Q / UA, which
    is what the Luau system publishes. Returns None here so the caller can say so.
    """
    d1, d2 = t_p_in - t_s_out, t_p_out - t_s_in     # counter-flow: hot end, cold end
    if d1 <= 0.0 or d2 <= 0.0:
        return None
    if abs(d1 - d2) < 1e-9:
        return d1
    return (d1 - d2) / math.log(d1 / d2)


checks = []


def check(label, got, want, tol, unit=""):
    ok = abs(got - want) <= tol
    checks.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {label:<50} {got:10.4f} vs {want:9.3f} {unit:<5} (tol {tol:g})")


print("The five §4.3 statements against each other")
lmtd_spec_temps = lmtd(T_P_IN, T_P_OUT, T_S_IN, T_S_OUT)
check("LMTD from the four stated temperatures", lmtd_spec_temps, LMTD_SPEC, 0.5, "K")
check("UA implied by 396 MWt / that LMTD", DUTY_EACH / lmtd_spec_temps / 1e6, UA / 1e6, 0.1, "MW/K")
c_p_spec = M_PRIMARY * cp(0.5 * (T_P_IN + T_P_OUT) + KELVIN)
c_s_spec = M_SECONDARY * cp(0.5 * (T_S_IN + T_S_OUT) + KELVIN)
check("duty from the primary stream", c_p_spec * (T_P_IN - T_P_OUT) / 1e6, DUTY_EACH / 1e6, 4, "MW")
check("duty from the secondary stream", c_s_spec * (T_S_OUT - T_S_IN) / 1e6, DUTY_EACH / 1e6, 4, "MW")

print("\nThe model: duty from UA and the two inlets alone")
q, t_p_out, t_s_out = duty(UA, M_PRIMARY, T_P_IN, M_SECONDARY, T_S_IN)
c_hot = M_PRIMARY * cp(0.5 * (T_P_IN + t_p_out) + KELVIN)
c_cold = M_SECONDARY * cp(0.5 * (T_S_IN + t_s_out) + KELVIN)
print(f"       C_primary {c_hot/1e6:.4f} MW/K, C_secondary {c_cold/1e6:.4f} MW/K, "
      f"NTU {UA/min(c_hot,c_cold):.3f}, Cr {min(c_hot,c_cold)/max(c_hot,c_cold):.4f}, "
      f"epsilon {effectiveness(UA, c_hot, c_cold):.4f}")
check("duty per unit", q / 1e6, DUTY_EACH / 1e6, 2, "MW")
check("primary outlet", t_p_out, T_P_OUT, 1, "C")
check("secondary outlet", t_s_out, T_S_OUT, 1, "C")
check("LMTD of the model's own temperatures", lmtd(T_P_IN, t_p_out, T_S_IN, t_s_out), LMTD_SPEC, 0.5, "K")
check("Q = UA x LMTD holds for the model", UA * lmtd(T_P_IN, t_p_out, T_S_IN, t_s_out) / 1e6, q / 1e6, 0.5, "MW")
check("six units carry the core", UNITS * q / 1e6, CORE_MWT + PUMP_MWT, 30, "MW")

print("\nWhere the loop actually settles (core + pump heat, secondary held at 320 C)")
lo, hi = 500.0, 600.0
for _ in range(80):
    mid = 0.5 * (lo + hi)
    if UNITS * duty(UA, M_PRIMARY, mid, M_SECONDARY, T_S_IN)[0] < (CORE_MWT + PUMP_MWT) * 1e6:
        lo = mid
    else:
        hi = mid
q_bal, tp_bal, ts_bal = duty(UA, M_PRIMARY, mid, M_SECONDARY, T_S_IN)
print(f"       hot pool {mid:.2f} C -> {UNITS*q_bal/1e6:.1f} MWt removed, primary out {tp_bal:.2f} C, "
      f"secondary out {ts_bal:.2f} C")
check("balance point is just above §2.4's 550 C", mid, 550.0, 1.5, "C")

print("\nOff design (one unit; primary flow as a fraction of its share, secondary held at design)")
print("       flow    duty MW   primary out   secondary out   LMTD   (* = Q/UA; the log form has degenerated)")
for frac in (1.0, 0.75, 0.5, 0.25, 0.035):
    qf, tp, ts = duty(UA, M_PRIMARY * frac, T_P_IN, M_SECONDARY, T_S_IN)
    lm = lmtd(T_P_IN, tp, T_S_IN, ts)
    shown = f"{lm:6.2f} " if lm is not None else f"{qf / UA:6.2f}*"
    print(f"       {frac:5.3f}  {qf/1e6:8.1f}   {tp:10.2f}    {ts:11.2f}   {shown}")
print("       a shutter at its 5 % leak-by, and a stopped secondary loop:")
q_leak = duty(UA, M_PRIMARY * 0.05, T_P_IN, M_SECONDARY, T_S_IN)
q_none = duty(UA, M_PRIMARY, T_P_IN, 0.0, T_S_IN)
print(f"       leak-by {q_leak[0]/1e6:.1f} MW, primary out {q_leak[1]:.2f} C   |   "
      f"secondary stopped {q_none[0]/1e6:.1f} MW, primary out {q_none[1]:.2f} C")
checks.append(abs(q_none[0]) < 1e-9)
print(f"  {'ok  ' if checks[-1] else 'FAIL'} a stopped secondary side removes nothing")

print(f"\n{sum(checks)}/{len(checks)} checks pass")
raise SystemExit(0 if all(checks) else 1)
