"""
Kallskar xsgen: the D-051 Pu search. It finds the shift of both zones' Pu content that puts the equilibrium BOC
core's excess reactivity (230 °C, all rods out) at §3.3's 2,250 pcm.

Each trial is a variant (paths.KALLSKAR_VARIANT) with its Pu moved by KALLSKAR_PU_SHIFT_PCT percentage points in
both zones. It repeats D-043's depletion of both zones and runs D-044's BOC core at 230 °C, in runs and results of
its own, so the committed reference results are never touched.
  first trial  from the Pu worth the fresh lattices imply: the inner (18 %) and outer (23 %) k∞ at 0 EFPD in
               results/k1_depletion.json, divided by the 5-point step between them
  next trials  the secant through the last two points, starting from the reference core (shift 0)
  stop         when the excess is within 3σ of its own statistics of the target; it cannot be told apart from it
The search is resumable: each finished stage of a trial leaves a marker, so a rerun skips it.
Writes results/k1_pusearch.json with every trial.

Usage (WSL, env kallskar-xs):  python tools/xsgen/k1_pusearch.py [--max-trials 4]
"""
import argparse
import glob
import json
import math
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths  # noqa: E402
import k1_materials as M  # noqa: E402

HERE = Path(__file__).resolve().parent
SUMMARY = paths.RESULTS / "k1_pusearch.json"
BOC_RUN = ["--case", "boc-cold230", "--particles", "50000", "--batches", "130", "--inactive", "30"]


def target() -> tuple[float, float]:
    m = re.search(r"excessReactivity230BOC_pcm\s*=\s*\{\s*target\s*=\s*(\d+),\s*absTol\s*=\s*(\d+)", M._luau("PhysicsModel"))
    return float(m.group(1)), float(m.group(2))


def reference() -> tuple[float, float, float]:
    """(excess, σ, Pu worth per percentage point) from the committed reference results."""
    fresh = json.loads((paths.RESULTS / "k1_fresh_results.json").read_text(encoding="utf-8"))
    e = fresh["forInformation"]["excessReactivity230BOC_pcm"]
    dep = json.loads((paths.RESULTS / "k1_depletion.json").read_text(encoding="utf-8"))
    k_in = dep["zones"]["inner"]["points"][0]["kinf"]
    k_out = dep["zones"]["outer"]["points"][0]["kinf"]
    pu = M.pu_fraction()
    worth = 1e5 * (1 / k_in - 1 / k_out) / (100 * (pu["outer"] - pu["inner"]))
    return e["value"], e["sigma"], worth


def trial(shift: float) -> tuple[float, float]:
    """Run (or resume) one trial; returns (excess pcm, σ)."""
    name = f"pusearch/pu{shift:+.2f}"
    runs = paths.RUNS / "variants" / name
    runs.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, KALLSKAR_VARIANT=name, KALLSKAR_PU_SHIFT_PCT=f"{shift:.2f}", PYTHONIOENCODING="utf-8")
    py = sys.executable
    stages = [
        ("deplete-inner", [py, str(HERE / "k1_deplete.py"), "--zone", "inner"]),
        ("deplete-outer", [py, str(HERE / "k1_deplete.py"), "--zone", "outer"]),
        ("export", [py, str(HERE / "k1_deplete.py"), "--export"]),
        ("boc-cold230", [py, str(HERE / "k1_model.py"), *BOC_RUN]),
    ]
    for stage, cmd in stages:
        done = runs / f".done_{stage}"
        if done.exists():
            print(f"  {name} {stage}: done earlier", flush=True)
            continue
        print(f"  {name} {stage} …", flush=True)
        with open(runs / f"{stage}.log", "w", encoding="utf-8") as log:
            subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, cwd=paths.REPO)
        done.touch()
    import openmc
    sp = openmc.StatePoint(sorted(glob.glob(str(runs / "k1_fresh" / "boc-cold230" / "statepoint.*.h5")))[-1])
    k, s = sp.keff.nominal_value, sp.keff.std_dev
    return 1e5 * (1 - 1 / k), 1e5 * s / k ** 2


def main(max_trials: int):
    goal, tol = target()
    e0, s0, worth = reference()
    base = M.pu_fraction()
    print(f"target {goal:.0f} ± {tol:.0f} pcm; reference core {e0:+.0f} ± {s0:.0f} pcm at Pu "
          f"{100 * base['inner']:.2f}/{100 * base['outer']:.2f} %; lattice Pu worth {worth:.0f} pcm per point")
    points = [(0.0, e0, s0)]
    shift = round(-(e0 - goal) / worth, 2)
    for n in range(1, max_trials + 1):
        e, s = trial(shift)
        points.append((shift, e, s))
        print(f"trial {n}: shift {shift:+.2f} points → excess {e:+.0f} ± {s:.0f} pcm", flush=True)
        converged = abs(e - goal) <= 3 * s
        SUMMARY.write_text(json.dumps({
            "method": "tools/xsgen/k1_pusearch.py (D-051): both zones shifted together, secant on the BOC 230 °C excess",
            "target_pcm": goal, "targetTolerance_pcm": tol, "latticeWorth_pcmPerPoint": worth,
            "basePu": base,
            "trials": [{"shift_points": d, "puInner": base["inner"] + d / 100, "puOuter": base["outer"] + d / 100,
                        "excess_pcm": ee, "sigma_pcm": ss} for d, ee, ss in points],
            "converged": converged,
            "result": {"shift_points": shift, "puInner": base["inner"] + shift / 100,
                       "puOuter": base["outer"] + shift / 100} if converged else None,
        }, indent=1), encoding="utf-8")
        if converged:
            print(f"converged: Pu {100 * (base['inner'] + shift / 100):.2f} % inner, "
                  f"{100 * (base['outer'] + shift / 100):.2f} % outer (excess {e:+.0f} ± {s:.0f})")
            return
        (d1, e1, _), (d2, e2, _) = points[-2], points[-1]
        shift = round(d2 + (goal - e2) * (d2 - d1) / (e2 - e1), 2)
    print("not converged within", max_trials, "trials; see", SUMMARY)
    sys.exit(1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--max-trials", type=int, default=4)
    main(ap.parse_args().max_trials)
