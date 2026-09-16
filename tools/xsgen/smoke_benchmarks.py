"""
Kallskar xsgen, step 3 of the plan: fast-spectrum smoke tests.

Before trusting this OpenMC + ENDF/B-VIII.1 setup on K1 (which has no measured answer), it must reproduce two
fast critical assemblies whose answer is known:

  Godiva  (ICSBEP HEU-MET-FAST-001, case 2, simplified bare HEU sphere)
  Jezebel (ICSBEP PU-MET-FAST-001, bare Pu sphere)

Model data (radii, atom densities) are copied from the OpenMC team's benchmark models:
  https://github.com/mit-crpg/benchmarks  icsbep/heu-met-fast-001/openmc/case-2, icsbep/pu-met-fast-001/openmc
Benchmark k_eff and 1σ uncertainty from the OpenMC validation suite:
  https://github.com/openmc-dev/validation  benchmarking/uncertainties.csv
  heu-met-fast-001 case-2: 1.0 ± 0.001     pu-met-fast-001: 1.0 ± 0.0020

Pass criterion: |k_calc − k_bench| ≤ sqrt(σ_bench² + σ_stat²)  (1σ combined). Anything within 3σ but outside
1σ is reported as WARN; beyond 3σ is FAIL. The pipeline does not proceed past a FAIL.

Run (WSL):  micromamba run -n kallskar-xs python tools/xsgen/smoke_benchmarks.py [--batches N --particles N]
"""
import argparse
import json
import math
import sys
import time

import paths

BENCHMARKS = {
    "godiva": {
        "icsbep": "HEU-MET-FAST-001 case 2 (simplified)",
        "radius_cm": 8.7407,
        "atom_densities": {"U234": 4.9184e-04, "U235": 4.4994e-02, "U238": 2.4984e-03},
        "k_bench": 1.0,
        "sigma_bench": 0.001,
    },
    "jezebel": {
        "icsbep": "PU-MET-FAST-001",
        "radius_cm": 6.3849,
        "atom_densities": {
            "Pu239": 0.037047,
            "Pu240": 0.0017512,
            "Pu241": 0.00011674,
            "Ga69": 0.0008266052159999999,
            "Ga71": 0.000548594784,
        },
        "k_bench": 1.0,
        "sigma_bench": 0.0020,
    },
}


def run_one(openmc, name, spec, batches, inactive, particles):
    mat = openmc.Material(name=name)
    for nuc, ao in spec["atom_densities"].items():
        mat.add_nuclide(nuc, ao)
    mat.set_density("sum")
    sphere = openmc.Sphere(r=spec["radius_cm"], boundary_type="vacuum")
    cell = openmc.Cell(fill=mat, region=-sphere)
    model = openmc.Model()
    model.materials = openmc.Materials([mat])
    model.geometry = openmc.Geometry([cell])
    s = openmc.Settings()
    s.run_mode = "eigenvalue"
    s.batches = batches
    s.inactive = inactive
    s.particles = particles
    s.source = openmc.IndependentSource(space=openmc.stats.Box((-1, -1, -1), (1, 1, 1)))
    s.output = {"tallies": False}
    model.settings = s

    d = paths.run_dir(f"smoke/{name}")
    t0 = time.time()
    sp_path = model.run(cwd=d, threads=paths.THREADS, output=False)
    wall = time.time() - t0
    with openmc.StatePoint(sp_path) as sp:
        k = sp.keff
    k_mean, k_std = float(k.nominal_value), float(k.std_dev)
    combined = math.hypot(spec["sigma_bench"], k_std)
    dev = k_mean - spec["k_bench"]
    status = "PASS" if abs(dev) <= combined else ("WARN" if abs(dev) <= 3 * combined else "FAIL")
    return {
        "benchmark": spec["icsbep"],
        "k_calc": k_mean,
        "sigma_stat": k_std,
        "k_bench": spec["k_bench"],
        "sigma_bench": spec["sigma_bench"],
        "deviation_pcm": dev * 1e5,
        "combined_sigma_pcm": combined * 1e5,
        "status": status,
        "batches": batches,
        "inactive": inactive,
        "particles": particles,
        "wall_s": round(wall, 1),
        "statepoint": str(sp_path),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--batches", type=int, default=520)
    ap.add_argument("--inactive", type=int, default=20)
    ap.add_argument("--particles", type=int, default=20000)
    args = ap.parse_args()

    openmc = paths.configure_openmc()
    out = {
        "openmc_version": openmc.__version__,
        "cross_sections": str(paths.CROSS_SECTIONS),
        "threads": paths.THREADS,
        "results": {},
    }
    worst = "PASS"
    for name, spec in BENCHMARKS.items():
        r = run_one(openmc, name, spec, args.batches, args.inactive, args.particles)
        out["results"][name] = r
        print(
            f"{r['status']}  {name:8s} k = {r['k_calc']:.5f} ± {r['sigma_stat']:.5f}   "
            f"bench {r['k_bench']:.4f} ± {r['sigma_bench']:.4f}   "
            f"dev {r['deviation_pcm']:+.0f} pcm (1σ combined {r['combined_sigma_pcm']:.0f})   {r['wall_s']} s",
            flush=True,
        )
        if r["status"] == "FAIL" or (r["status"] == "WARN" and worst == "PASS"):
            worst = r["status"]
    out["overall"] = worst
    (paths.RESULTS / "smoke_benchmarks.json").write_text(json.dumps(out, indent=2) + "\n")
    print(f"overall: {worst}  (written to tools/xsgen/results/smoke_benchmarks.json)")
    return 1 if worst == "FAIL" else 0


if __name__ == "__main__":
    sys.exit(main())
