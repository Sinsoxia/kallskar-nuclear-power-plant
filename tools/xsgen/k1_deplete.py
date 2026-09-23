"""
Kallskar xsgen: burnup-dependent K1 fuel, by assembly-level depletion (plan step 5; D-012, D-043).

One fuel assembly per zone (inner 18 %, outer 23 % Pu), built by k1_model exactly as in the core, with explicit
pins. It is reflective on its hexagonal cell and axially, so it stands for an infinite lattice of itself, the
standard lattice approach. It runs at the full-power temperatures (D-039) and is depleted with the ENDF/B-VIII.1
chain at the core's specific power.

  specific power  rated thermal / heavy metal: Config.Units.ratedThermal_MWt over k1_model's fresh inventory (the
                  --check figure, 29.11 t)
  normalisation   energy deposition (D-043): the flux is scaled so that the lattice's total heating-local tally
                  equals that power. OpenMC's heating-local counts fission as fragments + prompt and delayed photons +
                  delayed betas, deposited locally, and adds every capture's photon energy, the same heat a thermal
                  rating counts. fission-q would leave the capture energy out and burn a few percent too fast
  fission yields  the chain's 500 keV sets (FAST_YIELD_EV), ENDF/B's fast-reactor yields. The chain also carries
                  thermal sets for U-235 and Pu-239/240/241, and OpenMC's default would pick those
  steps           the equilibrium four-batch core's burnups land on step boundaries: 0, 160, 320 and 480 EFPD at
                  BOC and 640 EFPD at discharge (§2.3: 160 EFPD cycles, a quarter of the core per outage).
                  Steps are at most 80 EFPD (6.5 GWd/t) with the CECM predictor-corrector: a fast MOX spectrum has
                  no xenon, samarium or gadolinium swings to resolve. That is checked, not assumed: every "coarse"
                  step is exactly two "fine" steps, and CECM's error falls as Δt², so (fine − coarse) / 3 is the
                  Richardson correction to the fine result (--export reports it with its own σ)
  output          depletion_results.h5 under xs-runs/k1_deplete/<zone>/; --export writes the compositions at those
                  five points to tools/xsgen/results/k1_depletion.json, keeping nuclides above 1e-10 atoms/(b·cm),
                  the cut-off NEA/NSC/R(2015)9 uses for its own tables

The infinite lattice has no leakage, so its spectrum is slightly softer than the core's. That is the usual
lattice-depletion approximation; D-043 records it.

Usage (WSL, env kallskar-xs):
    python tools/xsgen/k1_deplete.py --zone inner [--scheme fine|coarse] [--particles 5000 --batches 40 --inactive 15]
    python tools/xsgen/k1_deplete.py --export
"""
import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths  # noqa: E402
import k1_materials as M  # noqa: E402
import k1_model  # noqa: E402

RESULTS = paths.RESULTS / "k1_depletion.json"
CYCLE_EFPD = 160.0  # §2.3 (Config.Core.fuel.cycleLength_EFPD, asserted below)
SCHEMES = {  # EFPD, one list per 160 EFPD cycle; the first steps are short while Np-239 and Pu-239 settle.
    # Each coarse step is two fine steps, so the fine grid nests in the coarse one (Richardson needs that).
    "fine": ([5.0, 5.0, 15.0, 15.0, 60.0, 60.0], [80.0, 80.0], [80.0, 80.0], [80.0, 80.0]),
    "coarse": ([10.0, 30.0, 120.0], [160.0], [160.0], [160.0]),
}
FAST_YIELD_EV = 5.0e5  # the chain's fast (500 keV) fission-yield sets, D-043
STEP_CHECK_NUCLIDES = ("U235", "U238", "Pu238", "Pu239", "Pu240", "Pu241", "Pu242", "Am241", "Am243", "Cm244")
BATCH_POINTS_EFPD = (*k1_model.BOC_BATCH_EFPD, k1_model.DISCHARGE_EFPD)  # the points the BOC core reads
KEEP_ABOVE = 1e-10  # atoms/(b·cm), NEA/NSC/R(2015)9 §2.1.1.4.1
SLAB_CM = (40.0, 60.0)  # the axial slice kept, inside the fuel; reflective at both planes


def specific_power_W_per_g() -> tuple[float, float]:
    """(W/gHM, tHM) from Config's rated power and the fresh inventory k1_model --check reports."""
    g = M.spec_geometry()
    fr = M.cell_fractions(g)
    counts = {"inner": 0, "outer": 0}
    for kind in k1_model.core_map().values():
        if kind in counts:
            counts[kind] += 1
    hm_g = 0.0
    for zone, n in counts.items():
        _, facts = M.fresh_mox(g["puFraction"][zone], g["pelletTD"])
        hm_g += facts["heavyMetal_gpcm3"] * fr["fuel"]["pellet"] * fr["cell_cm2"] * g["fissileHeight"] * n
    return M.luau_number("Units", "ratedThermal_MWt") * 1e6 / hm_g, hm_g / 1e6


def assembly_model(zone: str):
    openmc = paths.configure_openmc()
    import openmc.model
    model, _, _, g, fr, parts = k1_model.build("nominal")
    fuel = parts["fuel"][zone]
    fuel.depletable = True
    fuel.volume = fr["fuel"]["pellet"] * fr["cell_cm2"] * (SLAB_CM[1] - SLAB_CM[0])
    cell = openmc.model.HexagonalPrism(edge_length=g["assemblyPitch"] / math.sqrt(3), orientation="y",
                                       boundary_type="reflective")
    lo = openmc.ZPlane(z0=SLAB_CM[0], boundary_type="reflective")
    hi = openmc.ZPlane(z0=SLAB_CM[1], boundary_type="reflective")
    root = openmc.Universe(cells=[openmc.Cell(name=f"lattice_{zone}", fill=parts["universes"][zone],
                                              region=-cell & +lo & -hi)])
    settings = openmc.Settings()
    settings.run_mode = "eigenvalue"
    settings.temperature = {"method": "interpolation"}
    half = g["wrapperInnerFlats"] / 2
    settings.source = openmc.IndependentSource(
        space=openmc.stats.Box((-half, -half, SLAB_CM[0]), (half, half, SLAB_CM[1])),
        constraints={"fissionable": True})
    used = [fuel] + parts["structureMaterials"]
    return openmc.model.Model(geometry=openmc.Geometry(root), materials=openmc.Materials(used), settings=settings)


def run_subdir(scheme: str) -> str:
    return {"fine": "k1_deplete", "coarse": "k1_deplete_coarse", "smoke": "k1_deplete_smoke"}[scheme]


def deplete(zone, particles, batches, inactive, scheme="fine"):
    import openmc.deplete
    assert M.luau_number("Core", "cycleLength_EFPD") == CYCLE_EFPD
    if scheme == "smoke":  # two 1-day steps, to prove the pipeline before a multi-hour run
        steps = [1.0, 1.0]
    else:
        cycles = SCHEMES[scheme]
        assert all(abs(sum(c) - CYCLE_EFPD) < 1e-9 for c in cycles)
        steps = [s for cycle in cycles for s in cycle]
    power, hm_t = specific_power_W_per_g()
    print(f"{zone}: {power:.3f} W/gHM ({hm_t:.2f} tHM); {len(steps)} steps to {sum(steps):.0f} EFPD "
          f"= {power * sum(steps) / 1e3:.2f} GWd/tHM")
    model = assembly_model(zone)
    s = model.settings
    s.particles, s.batches, s.inactive = particles, batches, inactive
    cwd = paths.run_dir(f"{run_subdir(scheme)}/{zone}")
    import os
    os.chdir(cwd)
    op = openmc.deplete.CoupledOperator(model, chain_file=str(paths.CHAIN_FAST),
                                        normalization_mode="energy-deposition",
                                        fission_yield_mode="constant", fission_yield_opts={"energy": FAST_YIELD_EV})
    integrator = openmc.deplete.CECMIntegrator(op, steps, power_density=power, timestep_units="d")
    integrator.integrate()
    print("results:", cwd / "depletion_results.h5")


def load_points(scheme, zone, points=None):
    """[(EFPD, k∞, σ, {nuclide: atoms/(b·cm)})] at the given points (all steps if None), or None if not run."""
    import numpy as np
    import openmc.deplete
    path = paths.RUNS / run_subdir(scheme) / zone / "depletion_results.h5"
    if not path.exists():
        print("missing", path)
        return None
    res = openmc.deplete.Results(str(path))
    days, keff = res.get_keff(time_units="d")  # keff rows are (value, σ)
    mat_id = next(iter(res[0].index_mat))
    series = {nuc: res.get_atoms(mat_id, nuc, nuc_units="atom/b-cm")[1] for nuc in res[0].index_nuc}
    out = []
    for t in (tuple(days) if points is None else points):
        i = int(np.argmin(abs(days - t)))
        assert abs(days[i] - t) < 1e-6, (scheme, zone, t, days)
        out.append((float(days[i]), float(keff[i][0]), float(keff[i][1]),
                    {nuc: float(v[i]) for nuc, v in series.items() if v[i] > KEEP_ABOVE}))
    return out


def export(smoke=False):
    power, hm_t = specific_power_W_per_g()
    out = {"meta": {"model": "tools/xsgen/k1_deplete.py (single assembly, infinite lattice, D-043)",
                    "specificPower_WpgHM": power, "heavyMetal_t": hm_t, "units": "atoms/(b·cm) in the pellet",
                    "keptAbove": KEEP_ABOVE, "points_EFPD": list(BATCH_POINTS_EFPD)},
           "zones": {}}
    for zone in ("inner", "outer"):
        pts = load_points("smoke" if smoke else "fine", zone, None if smoke else BATCH_POINTS_EFPD)
        if pts is None:
            continue
        zone_out = {"points": []}
        for t, k, ks, dens in pts:
            zone_out["points"].append({"EFPD": t, "burnup_GWdpt": power * t / 1e3, "kinf": k, "kinfSigma": ks,
                                       "densities": dens})
            print(f"{zone} {t:5.0f} EFPD {power * t / 1e3:6.2f} GWd/t  k∞ {k:.5f} ± {ks:.5f}  {len(dens)} nuclides kept")
        coarse = None if smoke else load_points("coarse", zone, BATCH_POINTS_EFPD)
        if coarse:
            check = []
            for (t, k, ks, dens), (_, kc, kcs, dc) in zip(pts, coarse):
                # Richardson: exact ≈ fine + (fine − coarse)/3 for a second-order method and a step ratio of 2
                rel = {n: (dens.get(n, 0.0) - dc.get(n, 0.0)) / dens[n] / 3 for n in STEP_CHECK_NUCLIDES if n in dens}
                worst = max(rel, key=lambda n: abs(rel[n])) if rel else None
                dk = 1e5 * (k - kc) / 3
                sig = 1e5 * math.hypot(ks, kcs) / 3
                check.append({"EFPD": t, "richardsonCorrection_kinf_pcm": dk, "richardsonCorrectionSigma_pcm": sig,
                              "richardsonCorrection_rel": rel})
                if worst:
                    print(f"  step check {t:5.0f} EFPD: correction to the fine k∞ {dk:+.0f} ± {sig:.0f} pcm; "
                          f"largest nuclide correction {worst} {100 * rel[worst]:+.2f} %")
            zone_out["stepCheck"] = check
        out["zones"][zone] = zone_out
    if smoke:
        return
    RESULTS.write_text(json.dumps(out, indent=1))
    print("wrote", RESULTS)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--zone", choices=("inner", "outer"))
    ap.add_argument("--scheme", choices=("fine", "coarse"), default="fine")
    ap.add_argument("--particles", type=int, default=5000)
    ap.add_argument("--batches", type=int, default=40)
    ap.add_argument("--inactive", type=int, default=15)
    ap.add_argument("--export", action="store_true")
    ap.add_argument("--smoke", action="store_true", help="two 1-day steps into k1_deplete_smoke/, nothing written")
    a = ap.parse_args()
    if a.zone:
        deplete(a.zone, a.particles, a.batches, a.inactive, "smoke" if a.smoke else a.scheme)
    if a.export:
        export(a.smoke)
