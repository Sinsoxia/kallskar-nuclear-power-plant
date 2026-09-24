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
     so a_i are K per mm of RR at 500 mm (mid-stroke), and Σ a_i is the final gain.
  2. The controller keeps its own copy of those mode states, driven by the rods' actual positions. What its moves have
     yet to do to the outlet is Σ a_i·(Δz − x_i); it acts on the measured error plus that, so it never moves again for
     an effect that is still arriving.
  3. When that predicted error is outside §9.4's ±2 K band, it moves a regulating rod by f·(error)/G, where G is the
     final gain at the rod's position on the §3.4 S-curve. f < 1 so the move never overshoots at the power where the
     plant's gain is highest while the model's is that of the power the controller interpolates to.
  4. A closed-loop simulation on the fitted plants (with the thermocouple's ±1 K noise) checks the result: a setpoint
     step at each power, with no crossing of the new setpoint by more than the noise and the band allow.

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


def worth_scale(pos_mm):
    """The §3.4 S-curve's differential worth at a position, relative to mid-stroke (where the model was measured)."""
    d = min(max(pos_mm / ACTIVE_MM, 0.0), 1.0)
    return (1 - math.cos(2 * math.pi * d)) / 2


# ----------------------------------------------------------------------------------- rod auto: closed-loop simulation
def simulate(plant, model, f, setpoint_step_K, seconds=900.0, seed=1):
    """
    One regulating rod under the IMC controller, on a plant given by modes (a, τ) per mm at mid-stroke, scaled by the
    S-curve at the rod's position, with the thermocouple's uniform ±1 K noise. The setpoint steps at t = 0; returns the
    true outlet error trace (outlet − new setpoint) and the rod travel.
    """
    rng = np.random.default_rng(seed)
    (pa, ptau), (ma, mtau) = plant, model
    z0 = z = 500.0
    x = np.zeros(len(ptau))    # the plant's mode states, driven by position change
    xm = np.zeros(len(mtau))   # the controller's copy
    target = None
    trace = []
    for k in range(int(seconds / DT)):
        u = z - z0
        # the plant: each mode relaxes toward the position change; its gain follows the S-curve at the rod's position
        x += (u - x) * (1 - np.exp(-DT / ptau))
        xm += (u - xm) * (1 - np.exp(-DT / mtau))
        true_err = float(np.dot(pa, x)) * worth_scale(z) - setpoint_step_K
        measured = true_err + TC_NOISE_K * (2 * rng.random() - 1)
        pending = float(np.dot(ma, u - xm)) * worth_scale(z)
        if target is None:
            effective = measured + pending
            if abs(effective) > BAND_K:
                gain = float(np.sum(ma)) * worth_scale(z)
                target = z - f * effective / gain
        if target is not None:
            step = math.copysign(min(RR_SPEED * DT, abs(target - z)), target - z)
            z += step
            if abs(target - z) < 1e-9:
                target = None
        trace.append((k * DT, true_err, z - z0))
    return trace


def main():
    steps = load_steps()
    print("Rod auto: the modes fitted to each open-loop response (RR1 out 20 mm at mid-stroke)")
    fits = {}
    for pct in (100, 60, 30):
        meta, v = steps[("rod", pct)]
        assert abs(float(meta["pos"]) - 500) < 1e-6 and abs(float(meta["speed"]) - RR_SPEED) < 1e-9
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

    print("Rod auto: closed loop on the fitted plants, IMC controller, ±2 K band, ±1 K thermocouple noise")
    for pct in (100, 60, 30):
        for label, plant in (("model = plant", fits[pct]),
                             ("rods 10 % stronger", (fits[pct][0] * 1.10, fits[pct][1]))):
            for step in (-6.0, +6.0):
                tr = simulate(plant, fits[pct], f, step)
                errs = np.array([e for _, e, _ in tr])
                beyond = -errs.min() if step < 0 else errs.max()   # how far past the new setpoint the outlet went
                inside = next((tt for tt, e, _ in tr if abs(e) <= BAND_K and all(abs(ee) <= BAND_K + TC_NOISE_K for _, ee, _ in tr[int(tt / DT):])), None)
                moves = sum(1 for i in range(1, len(tr)) if tr[i][2] != tr[i - 1][2] and tr[i - 1][2] == tr[max(i - 2, 0)][2])
                print(f"  {pct:3d} %FP {label:19s} setpoint {step:+.0f} K: past the setpoint by {max(beyond, 0):.2f} K at most; "
                      f"inside the band from {inside if inside is None else round(inside)} s; {moves} move(s)")
                check(f"{pct} %FP, {label}, {step:+.0f} K: no crossing beyond the band ({max(beyond, 0):.2f} K ≤ {BAND_K} K)",
                      beyond <= BAND_K)

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

    print(f"\nFor Config (D-059):\n  rod auto: correctionFraction = {f:.4f}; modes at 100/60/30 %FP (K per mm at 500 mm, s):")
    for pct in (100, 60, 30):
        a, tau = fits[pct]
        print(f"    [{pct}] = {{ " + ", ".join(f"{{ gain_Kpmm = {ai:.6f}, tau_s = {ti:.3f} }}" for ai, ti in zip(a, tau)) + " },")
    print(f"  flow auto: powerFilter_s = {tau_f:.2f}")
    print(f"\n{sum(checks)}/{len(checks)} checks pass")
    sys.exit(0 if all(checks) else 1)


if __name__ == "__main__":
    main()
