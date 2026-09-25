"""
D-059: the tuning of the two M1 autos, derived from the plant's own open-loop step responses.

The responses come from tests/TuningSpec: the whole plant as Main builds it, autos out, seated at 100, 60 and 30 %FP,
with one actuator stepped. `--measure` reruns that spec headless (WSL) and refreshes tools/derive/auto_tuning_steps.txt;
without it the committed responses are used.

Rod auto (D-059, option A: it models its own pending moves). RR1 out 20 mm at 5 mm/s gives the lagged outlet
thermocouple a fast rise (about half the final change within 10 s), a dip, and a slow climb over minutes: the heat sink
holds the load, so the extra power warms the whole pool until the isothermal feedback cancels the rod's reactivity.
  1. Each response is fitted with a sum of first-order modes, driven by the rod's actual ramp:
         ΔT(t) = Σ a_i·x_i(t),  dx_i/dt = (Δz(t) − x_i)/τ_i
     so a_i are K per mm of RR at 500 mm (depth 0.6 of the active height, 90 % of the S-curve's peak
     differential worth), and Σ a_i is the final gain.
  2. The controller keeps its own copy of those mode states, driven by the rods' actual positions. What its moves have
     yet to do to the outlet is Σ a_i·(Δz − x_i); it acts on the measured error plus that, so it never moves again for
     an effect that is still arriving.
  3. When that predicted error is outside §9.4's ±2 K band, it moves a regulating rod by f·(error)/G, where G is the
     final gain, and the move is solved in reactivity: the target position is the one whose S-curve worth
     differs from the rod's by the equivalent millimetres needed. f < 1 so the move never overshoots at the power where the
     plant's gain is highest while the model's is that of the power the controller interpolates to.
  4. It acts on the thermocouple through a first-order filter, and its copy of the modes runs through the same filter,
     so the prediction of its own moves stays exact. Unfiltered, a move sized on one reading of §2.5's ±1 K noise
     is off by up to 0.9 K, and against a ±2 K band that is enough to reverse. The filter is the shortest that keeps the
     noise, at D-025's 5σ, inside the margin f leaves: then noise alone never makes a band-edge move overshoot.
  5. A closed-loop simulation on the fitted plants, with the noise, checks the result. The cases are a setpoint step
     at each power, and a reactivity step (a shim move, which reaches the outlet on both timescales, so the controller
     sees only part of it at first): no crossing of the setpoint by more than the band, and every move the same way.

Flow auto. Every pump 5 % slower gives 5 % less flow within the pumps' 2 %/s ramp, at every power: a static plant,
flow = (Σ running speeds)/300. The controller asks directly for the speed that gives the programme's flow with the
pumps it has running (it commands those pumps, so that is its own sector), and the ramp does the rest; nothing
overshoots. What needs deriving is the filter on the power reading the programme is indexed on: the median of the four
PR channels carries D-025's noise, and unfiltered it would make the pumps chase noise.

Run (WSL, env kallskar-xs, for scipy): python tools/derive/auto_tuning.py [--measure]
"""
import math
import subprocess
import sys
from pathlib import Path

import numpy as np
from scipy.optimize import least_squares

sys.stdout.reconfigure(encoding="utf-8")
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
STEPS = HERE / "auto_tuning_steps.txt"
sys.path.insert(0, str(REPO / "tools" / "xsgen"))
import k1_materials as M  # noqa: E402  (reads Config/*.luau)

DT = 0.1                      # the fast lane (Config.Clocks.fast_Hz = 10)
BAND_K = M.luau_number("Program", "holdBand_K")                   # §9.4: rod auto holds the outlet ±2 K
TC_NOISE_K = M.luau_number("Core", "thermocoupleNoise_K")         # §2.5: ±1 K, uniform, every tick
RR_SPEED = M.luau_number("Rods", "speed_mmps")                    # §3.4: 5 mm/s
ACTIVE_MM = M.luau_number("Core", "fissileHeight_mm")
TRAVEL_MM = M.luau_number("Units", "rodTravel_mm")
MEASURED_AT_MM = 500.0                                             # tests/TuningSpec: RR1 as InitialConditions seats it
MODES = 4

checks = []


def check(label, ok):
    checks.append(bool(ok))
    print(f"  [{'ok' if ok else 'FAIL'}] {label}")


def load_steps():
    if "--measure" in sys.argv:
        run = subprocess.run(["bash", "tools/lune/test.sh", "--filter", "Tuning"], cwd=REPO, capture_output=True, text=True)
        assert "every outcome matches expectations" in run.stdout, run.stdout[-2000:]
        report = (REPO / "tools" / "lune" / ".out" / "report.txt").read_text(encoding="utf-8")
        lines = [ln[ln.index("TUNING "):] for ln in report.splitlines() if "TUNING " in ln]
        STEPS.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    out = {}
    for ln in STEPS.read_text(encoding="utf-8").splitlines():
        parts = ln.split()
        case, pct = parts[1], int(parts[2])
        meta = dict(p.split("=") for p in parts[3:] if "=" in p)
        values = np.array([float(p) for p in parts[3:] if "=" not in p])
        out[(case, pct)] = (meta, values)
    return out


# ------------------------------------------------------------------------------------------------ rod auto: the model
def ramp_response(t, tau, speed, dist):
    """x(t) of a first-order mode, dx/dt = (u − x)/τ, for u a ramp at `speed` up to `dist` (mm), from t = 0."""
    T = dist / speed
    early = speed * (t - tau * (1 - np.exp(-t / tau)))
    late = speed * (T - tau * (np.exp(-(t - T) / tau) - np.exp(-t / tau)))
    return np.where(t <= T, early, late)


# The modes' time bands. Left free, a sum of exponentials fitted to a delayed response collapses several modes onto
# one time constant with huge amplitudes of opposite sign (the optimiser building t·e^(−t/τ) terms), which fits but
# cancels catastrophically in the controller. Each mode is held to its own decade-scale band instead: the
# thermocouple and fuel lags (seconds), the load pads (tens of seconds), and the plant's energy balance (minutes).
BANDS = [(0.2, 2.5), (2.5, 8.0), (8.0, 40.0), (40.0, 3000.0)]


def fit_modes(t, y, speed, dist):
    """Least squares for the modes: τ_i by search (in logs) within their bands, a_i linear given the τ_i."""
    def basis(logtau):
        return np.column_stack([ramp_response(t, math.exp(p), speed, dist) for p in logtau])

    def resid(logtau):
        A = basis(logtau)
        a, *_ = np.linalg.lstsq(A, y, rcond=None)
        return A @ a - y

    lo = np.log([b[0] for b in BANDS])
    hi = np.log([b[1] for b in BANDS])
    best = None
    for frac in (0.3, 0.5, 0.7):
        r = least_squares(resid, lo + frac * (hi - lo), bounds=(lo, hi))
        if best is None or r.cost < best.cost:
            best = r
    tau = np.exp(best.x)
    a, *_ = np.linalg.lstsq(basis(best.x), y, rcond=None)
    rms = math.sqrt(np.mean(resid(best.x) ** 2))
    return a, tau, rms


def depth(pos_mm):
    """RodDrives.depthOf: the fraction of the active height a rod at this position is inserted."""
    return min(max((TRAVEL_MM - pos_mm) / ACTIVE_MM, 0.0), 1.0)


def worth_fraction(d):
    """§3.4's S-curve, W(d) = d − sin(2πd)/2π, as RodDrives has it: the fraction of a rod's worth inserted at depth d."""
    return d - math.sin(2 * math.pi * d) / (2 * math.pi)


NORM = (1 - math.cos(2 * math.pi * depth(MEASURED_AT_MM))) / ACTIVE_MM  # the S-curve's slope at 500 mm, per mm


def equivalent_mm(z_from, z_to):
    """
    A move's reactivity in "500-mm equivalent" millimetres: the millimetres at 500 mm that would add as much. The
    model is linear in reactivity, so this, not the millimetres, is its input: exact whatever the S-curve does.
    """
    return (worth_fraction(depth(z_from)) - worth_fraction(depth(z_to))) / NORM


def position_for(z_from, eq_mm, lo, hi):
    """The position that moves `eq_mm` equivalent millimetres from z_from, within [lo, hi] (bisection)."""
    a, b = (z_from, hi) if eq_mm > 0 else (lo, z_from)
    if (eq_mm > 0 and equivalent_mm(z_from, hi) <= eq_mm) or (eq_mm < 0 and equivalent_mm(z_from, lo) >= eq_mm):
        return hi if eq_mm > 0 else lo  # the band limits it
    for _ in range(50):
        m = (a + b) / 2
        if equivalent_mm(z_from, m) < eq_mm:  # the equivalent millimetres rise with position, either way
            a = m
        else:
            b = m
    return (a + b) / 2


# ----------------------------------------------------------------------------------- rod auto: closed-loop simulation
def simulate(plant, model, f, tau_m, setpoint_step_K=0.0, disturbance_mm=0.0, seconds=900.0, seed=1):
    """
    One regulating rod under the IMC controller as AutoControls has it, on a plant given by modes (a, τ) per 500-mm
    equivalent millimetre, with the thermocouple's uniform ±1 K noise. Both the plant and the controller's model are
    driven by the rod's reactivity in equivalent millimetres, the controller's through the measurement filter τ_m.
    At t = 0 the setpoint steps, or a reactivity the controller did not make (a shim move, in equivalent mm) enters
    the plant. Returns (t, true error, rod travel) per tick and the direction of each move (True: withdrawing).
    """
    rng = np.random.default_rng(seed)
    (pa, ptau), (ma, mtau) = plant, model
    band_lo, band_hi = 250.0, 750.0  # §9.4 / Rev A4's regulating band
    beta = 1 - math.exp(-DT / tau_m)
    z0 = z = MEASURED_AT_MM
    x = np.zeros(len(ptau))    # the plant's mode states, driven by the equivalent millimetres moved
    xm = np.zeros(len(mtau))   # the controller's copy
    ym = np.zeros(len(mtau))   # ... seen through its measurement filter
    filtered = 0.0             # settled on the steady plant before t = 0
    target, withdrawing = None, None
    trace, moves = [], []
    for k in range(int(seconds / DT)):
        u = equivalent_mm(z0, z)
        x += (u + disturbance_mm - x) * (1 - np.exp(-DT / ptau))
        xm += (u - xm) * (1 - np.exp(-DT / mtau))
        ym += (xm - ym) * beta
        true_err = float(np.dot(pa, x)) - setpoint_step_K
        measured = true_err + TC_NOISE_K * (2 * rng.random() - 1)
        filtered += (measured - filtered) * beta
        effective = filtered + float(np.dot(ma, u - ym))
        # a move is released on arriving, or when the error calls the other way beyond the band
        if target is not None and abs(effective) > BAND_K and (effective < 0) != withdrawing:
            target = None
        if target is None and abs(effective) > BAND_K:
            target = position_for(z, -f * effective / float(np.sum(ma)), band_lo, band_hi)
            withdrawing = effective < 0
            moves.append(withdrawing)
        if target is not None:
            step = math.copysign(min(RR_SPEED * DT, abs(target - z)), target - z)
            z += step
            if abs(target - z) < 1e-9:
                target = None
        trace.append((k * DT, true_err, z - z0))
    return trace, moves


def main():
    steps = load_steps()
    print("Rod auto: the modes fitted to each open-loop response (RR1 out 20 mm from 500 mm)")
    fits = {}
    for pct in (100, 60, 30):
        meta, v = steps[("rod", pct)]
        assert abs(float(meta["pos"]) - MEASURED_AT_MM) < 1e-6 and abs(float(meta["speed"]) - RR_SPEED) < 1e-9
        t = np.arange(len(v)) * float(1)
        y = v - v[0]
        a, tau, rms = fit_modes(t, y, RR_SPEED, 20.0)
        fits[pct] = (a, tau)
        print(f"  {pct:3d} %FP: final gain {a.sum():.5f} K/mm; modes " +
              ", ".join(f"{ai:+.5f} K/mm at {ti:.1f} s" for ai, ti in zip(a, tau)) +
              f"; fit RMS {rms * 1000:.1f} mK over {t[-1]:.0f} s (response {y.max():.3f} K at most)")
        check(f"{pct} %FP: the fit is within a tenth of the thermocouple's noise ({rms:.4f} K)", rms < TC_NOISE_K / 10)

    # The slow mode is the plant's energy balance, but it is not C·α_P/α_iso (235 s): that assumes a sink that takes a
    # fixed load, and the M1 IHX sink takes more heat as the pool warms, which shortens the mode and cuts the final
    # gain. The measured response is the one the controller has to live with, so it is taken as it is; the check is
    # that the slowest mode is at least five times the fastest, i.e. that the fit separated the two timescales.
    for pct in (100, 60, 30):
        a, tau = fits[pct]
        print(f"  {pct} %FP: slowest mode {tau[-1]:.0f} s holds {a[-1] / a.sum() * 100:.0f} % of the final gain")
        check(f"{pct} %FP: the energy-balance mode is separate from the fast ones ({tau[-1]:.0f} s vs {tau[0]:.1f} s)",
              tau[-1] > 5 * tau[0])

    # f: the controller interpolates its model in power between the three fits; the worst case is a plant whose gain
    # is higher than the model's. Between measured powers the gain is taken as varying linearly, so the largest ratio
    # of true to model gain is at a measured power, where the interpolated model equals the fit: 1. Then allow for the
    # §3.7 rod-worth tolerance (±10 %, the validation target the rods are held to): the S-curve the controller scales
    # by can be off by that much, so f = 1/1.1 keeps a move from overshooting when the worth is 10 % high.
    f = 1 / 1.10
    print(f"  correction fraction f = {f:.3f}: a move is sized for the error, less the §3.7 ±10 % rod-worth tolerance")

    # τ_m, the measurement filter. The thermocouple's noise is uniform ±1 K drawn every tick (Pools, §2.5): σ = 1/√3 K,
    # independent from tick to tick. On a rod of nominal worth a move sized f·(e + δ) for a true error e overshoots
    # when δ > (1 − f)/f·e, which at the band edge is 10 % of 2 K, 0.2 K: the margin f leaves for §3.7's tolerance.
    # Criterion: the filter is the shortest that keeps the noise it lets through, at D-025's 5σ, inside that margin.
    # A first-order filter of time constant τ passes σ·√(dt/2τ) of white noise sampled every dt (as flow auto's does).
    sigma_tc = TC_NOISE_K / math.sqrt(3)
    margin_K = (1 - f) / f * BAND_K
    tau_m = DT / 2 * (sigma_tc / (margin_K / 5)) ** 2
    print(f"  measurement filter τ = {tau_m:.2f} s: the thermocouple's σ {sigma_tc:.3f} K a tick comes through as "
          f"{sigma_tc * math.sqrt(DT / (2 * tau_m)):.3f} K, 5σ = the {margin_K:.2f} K margin f leaves at the band edge")

    print("Rod auto: closed loop on the fitted plants, IMC controller, ±2 K band, ±1 K thermocouple noise, five seeds")
    for pct in (100, 60, 30):
        gain = float(np.sum(fits[pct][0]))
        for label, plant in (("model = plant", fits[pct]),
                             ("rods 10 % stronger", (fits[pct][0] * 1.10, fits[pct][1]))):
            for case, step, dist in (("setpoint", -6.0, 0.0), ("setpoint", +6.0, 0.0),
                                     ("reactivity", 0.0, +6.0), ("reactivity", 0.0, -6.0)):
                beyond, reversals, most, last = 0.0, 0, 0, 0.0
                for seed in range(1, 6):
                    tr, moves = simulate(plant, fits[pct], f, tau_m, setpoint_step_K=step,
                                         disturbance_mm=dist / gain, seed=seed)
                    errs = np.array([e for _, e, _ in tr])
                    # how far past the setpoint, on the side the correction heads for
                    over = -errs.min() if (step < 0 or dist > 0) else errs.max()
                    beyond = max(beyond, over)
                    reversals += len(set(moves)) > 1
                    most = max(most, len(moves))
                    last = max(last, float(np.abs(errs[-600:]).max()))
                what = f"setpoint {step:+.0f} K" if case == "setpoint" else f"reactivity worth {dist:+.0f} K"
                print(f"  {pct:3d} %FP {label:19s} {what:24s}: past the setpoint by {max(beyond, 0):.2f} K at most; "
                      f"up to {most} move(s); {reversals}/5 runs reverse; last minute within {last:.2f} K")
                check(f"{pct} %FP, {label}, {what}: no crossing beyond the band ({max(beyond, 0):.2f} K ≤ {BAND_K} K)",
                      beyond <= BAND_K)
                check(f"{pct} %FP, {label}, {what}: every move the same way", reversals == 0)
                check(f"{pct} %FP, {label}, {what}: inside the band after 15 min ({last:.2f} K)", last <= BAND_K)

    # ------------------------------------------------------------------------------------------------- flow auto
    print("Flow auto: the plant")
    for pct in (100, 60, 30):
        _, v = steps[("flow", pct)]
        drop = v[0] - v[-1]
        ramp_s = next(i for i, x in enumerate(v) if abs(x - v[-1]) < 1e-9)
        print(f"  {pct:3d} %FP: 5 % slower gives {drop * 100:.2f} % less flow, there by {ramp_s} s")
        check(f"{pct} %FP: flow is (Σ running speeds)/300, 1:1 with speed", abs(drop - 0.05) < 1e-9)
    # The programme's flow is indexed on the PR median (D-059: the real measurement). Its noise: each channel is
    # Gaussian with σ = D-025's 0.5 % of the power, and the median of four has σ ≈ 1.2533·σ/√4·(correction for n = 4,
    # 1.092) = 0.684·σ (the median of four is the mean of the middle two). Above the 40 % flow floor the programme is
    # flow = power, so that noise goes straight into the demand, scaled by 3/running.
    prRel = 0.005
    sigma_median = 0.684 * prRel * 100   # % of rated flow at 100 %FP, per tick, independent
    sigma_demand = sigma_median * 3 / 2  # the worst case: two pumps left
    # Criterion (engineering): the noise a filter lets through must move the pumps by less than a quarter of what the
    # drives can move in one tick (2 %/s × 0.1 s = 0.2 %), so noise never shows as pump motion. A first-order filter
    # of time constant τ passes σ·√(dt/2τ) of white noise sampled every dt.
    tick_step = 2.0 * DT
    tau_f = DT / 2 * (sigma_demand / (tick_step / 4)) ** 2
    lag = 5 / 60 * tau_f  # §7.1's fastest routine power change, 5 %/min, lags the filter by rate × τ
    print(f"  PR median noise {sigma_median:.3f} % a tick; on two pumps {sigma_demand:.3f} % of speed")
    print(f"  power filter τ = {tau_f:.2f} s (noise through it {sigma_demand * math.sqrt(DT / (2 * tau_f)):.3f} % a tick, "
          f"a quarter of the {tick_step:.1f} % tick step); at §7.1's 5 %/min it lags the power by {lag:.2f} %FP")
    check("the filter's lag at §7.1's fastest routine change is well inside the P/Q alarm margin (5 %)", lag < 0.5)

    print(f"\nFor Config (D-059):\n  rod auto: correctionFraction = {f:.4f}; measurementFilter_s = {tau_m:.2f}; "
          f"modes at 100/60/30 %FP (K per mm at 500 mm, s):")
    for pct in (100, 60, 30):
        a, tau = fits[pct]
        print(f"    [{pct}] = {{ " + ", ".join(f"{{ gain_Kpmm = {ai:.6f}, tau_s = {ti:.3f} }}" for ai, ti in zip(a, tau)) + " },")
    print(f"  flow auto: powerFilter_s = {tau_f:.2f}")
    print(f"\n{sum(checks)}/{len(checks)} checks pass")
    sys.exit(0 if all(checks) else 1)


if __name__ == "__main__":
    main()
