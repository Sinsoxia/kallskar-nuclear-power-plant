"""
Kallskar xsgen: OECD/NEA MOX-1000 benchmark core (NEA/NSC/R(2015)9 §2.1.2.3–2.1.2.4), homogeneous-assembly model.

Pipeline validation: before trusting OpenMC + ENDF/B-VIII.1 on K1 (which has no reference answers), reproduce a
published core whose multi-code results are known (Table 4.4). MOX-1000 is used rather than MOX-3600 because the
report specifies it completely; MOX-3600 lacks the radial-reflector composition and the rod parking position.

Specification sources (all in references/nsc-r2015-9.pdf):
  layout        Figure 2.12, transcribed by tools/xsgen/mox1000_layout.py (counts checked against the legend)
  geometry      Tables 2.24–2.27, Figure 2.16 (rods fully withdrawn: empty duct over the active core)
  fractions     Table 2.28 (homogenised per region, fractions of the hexagonal cell at 16.2471 cm pitch)
  densities     Table 2.21 (structure, coolant, absorbers), Tables 2.29–2.31 (fuel pins, 5 axial zones, BOC)
  conditions    §2.1.2.3: fuel 1027 °C; coolant and structure 432.5 °C (Table 2.15, same as MET-1000)
  boundaries    vacuum on all outer surfaces (§2.1.2.3)
  results       Table 4.4 (BOC averages and code-to-code SD); definitions §2.2 (void, Doppler) and §5.6 (rods)

Report inconsistencies and how they are resolved:
  • §2.1.2.3 text gives the outer zone 92 assemblies; the Figure 2.12 legend gives 60, and only 30 + 90 + 60 matches
    the stated 180 drivers. The figure is used.
  • Tables 2.25/2.26 list a 40.70 cm upper structure for reflector and shield (476.20 cm overall against the stated
    480.20 cm); the text says those upper structures are identical to the driver's, 44.70 cm, which is used.
  • Table 2.21's text layout puts a carbon line under HT-9; the B:C = 4 stoichiometry and the stated boron
    enrichments (19.1 %, 65 %) show both carbon lines belong to the B4C materials (asserted below).
  • A homogenised region has one temperature in OpenMC, so the whole active-core mixture is at the fuel temperature,
    and the Doppler state heats all of it. Homogeneous participants did the same: Table 5.10 lists 23Na, 56Fe and 16O
    Doppler contributions for the homogeneous CEA-4/CEA-5 models (56Fe −50/−41 pcm of −670/−628).
  • The Doppler state uses 2500 K, the library's highest temperature, rather than 2 × 1300 K;
    K_D = Δρ / ln(T_high / T_nominal) is the same constant under the benchmark's logarithmic definition (§2.2).

Usage (WSL, env kallskar-xs):
    python tools/xsgen/mox1000_model.py --check
    python tools/xsgen/mox1000_model.py --case nominal --particles 200000 --batches 250 --inactive 50
    python tools/xsgen/mox1000_model.py --summarise
Cases: nominal (with IFP kinetics tallies), void, doppler, rods.
"""
import argparse
import glob
import json
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths  # noqa: E402

REPORT_TXT = paths.REPO / "references" / "nsc-r2015-9.txt"
LAYOUT = paths.RESULTS / "mox1000_layout.json"
RESULTS = paths.RESULTS / "mox1000_results.json"
CASES = ("nominal", "void", "doppler", "rods")

PITCH = 16.2471
T_FUEL = 1027.0 + 273.15
T_STRUCT = 432.5 + 273.15
T_DOPPLER = 2500.0

# axial planes (cm from the bottom of the subassembly), Tables 2.24–2.27 and Figure 2.16
Z_LOWER_STRUCT_TOP = 35.76
Z_CORE_BOTTOM = Z_LOWER_STRUCT_TOP + 112.39
ZONE_TOPS = [22.99, 45.98, 68.96, 91.95, 114.94]  # Tables 2.29–2.31 headers, from the active core bottom
Z_CORE_TOP = Z_CORE_BOTTOM + ZONE_TOPS[-1]
Z_PLENUM_TOP = Z_CORE_TOP + 172.41
Z_TOP = Z_PLENUM_TOP + 44.70
ABSORBER_LENGTH = 119.97
assert abs(Z_TOP - 480.20) < 1e-9, Z_TOP
assert abs(Z_CORE_BOTTOM + 287.35 - Z_PLENUM_TOP) < 1e-9  # reflector/shield column ends where the driver plenum ends
assert abs(Z_CORE_TOP + ABSORBER_LENGTH + 97.14 - Z_TOP) < 1e-9  # Figure 2.16, rods withdrawn

# Table 2.21 (atoms/b-cm)
LOWER_STRUCTURE = {"Na23": 1.5591e-02, "Fe": 1.5878e-02, "Ni": 3.2604e-03, "Cr": 3.2355e-03, "Mn55": 5.0846e-04, "Mo": 4.3524e-04}
COOLANT = {"Na23": 2.2272e-02}
HT9 = {"Fe": 6.9715e-02, "Ni": 4.2984e-04, "Cr": 1.0366e-02, "Mn55": 4.5921e-04, "Mo": 4.9007e-04}
B4C_NATURAL = {"C": 1.9657e-02, "B10": 1.5018e-02, "B11": 6.3609e-02}
B4C_ENRICHED = {"C": 2.0632e-02, "B10": 5.3642e-02, "B11": 2.8884e-02}
for _b4c, _enrichment in ((B4C_NATURAL, 0.191), (B4C_ENRICHED, 0.65)):
    _boron = _b4c["B10"] + _b4c["B11"]
    assert abs(_boron / _b4c["C"] - 4) < 1e-3, "B4C stoichiometry"
    assert abs(_b4c["B10"] / _boron - _enrichment) < 1e-3, "boron enrichment"
assert abs(LOWER_STRUCTURE["Na23"] - 0.70 * COOLANT["Na23"]) < 1e-6  # 70 % sodium, as stated

# Table 2.28 volume fractions
FRACTIONS = {
    "driver_active": {"coolant": 0.3327, "ht9": 0.2564, "fuel": 0.4109},
    "driver_plenum": {"coolant": 0.3327, "ht9": 0.2564},  # the remaining 41.09 % is gas, ignored (§2.1.2.1)
    "lower_reflector": {"coolant": 0.3327, "ht9": 0.6673},  # also the upper structure
    "radial_reflector": {"coolant": 0.1550, "ht9": 0.8450},
    "radial_shield": {"coolant": 0.1710, "ht9": 0.2968, "b4c_nat": 0.5322},
    "absorber": {"coolant": 0.2883, "ht9": 0.2077, "b4c_enr": 0.5040},
    "empty_duct": {"coolant": 0.9074, "ht9": 0.0926},
}
for _name, _parts in FRACTIONS.items():
    if _name != "driver_plenum":
        assert abs(sum(_parts.values()) - 1) < 2e-4, (_name, sum(_parts.values()))
SOURCES = {"coolant": COOLANT, "ht9": HT9, "b4c_nat": B4C_NATURAL, "b4c_enr": B4C_ENRICHED}

BENCHMARK = {  # Table 4.4, BOC: average and code-to-code standard deviation
    "keff": (1.0287, 0.0062),
    "betaEff_pcm": (333, 15),
    "sodiumVoid_pcm": (1831, 228),
    "doppler_pcm": (-731, 70),
    "controlRods_pcm": (21605, 2021),
}


def nuclide_name(label: str) -> str:
    """'234U' → 'U234', '242mAm' → 'Am242_m1', '16O' → 'O16', 'Mo' → element 'Mo'."""
    m = re.fullmatch(r"(\d+)(m?)([A-Z][a-z]?)", label)
    if not m:
        assert re.fullmatch(r"[A-Z][a-z]?", label), label
        return label
    mass, meta, sym = m.groups()
    return f"{sym}{mass}" + ("_m1" if meta else "")


def parse_fuel_table(number: str) -> list[dict]:
    """Five axial-zone pin compositions from Table 2.<number> of the pdftotext output."""
    lines = REPORT_TXT.read_text(encoding="utf-8").splitlines()
    start = next(i for i, l in enumerate(lines) if re.match(rf"\s*Table 2\.{number}\.\s", l))
    zones = [dict() for _ in range(5)]
    row = re.compile(r"^\s*(?:a\))?(\d{1,3}m?[A-Z][a-z]?|[A-Z][a-z]?)\s+((?:\d\.\d{4}E[-+]\d{2}\s*){5})$")
    header = False
    for l in lines[start + 1:start + 60]:
        if not header and re.search(r"22\.99\s+45\.98\s+68\.96\s+91\.95\s+114\.94", l):
            header = True
            continue
        m = row.match(l)
        if header and m:
            values = [float(v) for v in m.group(2).split()]
            for z in range(5):
                zones[z][nuclide_name(m.group(1))] = values[z]
        elif header and zones[0] and "representative" in l:
            break
    assert header, f"Table 2.{number}: axial header not found"
    expected = {"U234", "U235", "U236", "U238", "Np237", "Pu236", "Pu238", "Pu239", "Pu240", "Pu241", "Pu242",
                "Am241", "Am242_m1", "Am243", "Cm242", "Cm243", "Cm244", "Cm245", "Cm246", "O16", "Mo"}
    for z in zones:
        assert set(z) == expected, f"Table 2.{number}: nuclides differ: {sorted(set(z) ^ expected)}"
    for z in zones:
        heavy = sum(v for k, v in z.items() if re.match(r"(U|Np|Pu|Am|Cm)\d", k))
        # oxide fuel: O/M ≈ 2 (the pseudo fission product carries part of the burnt metal)
        assert 1.85 < z["O16"] / heavy < 2.25, (number, z["O16"] / heavy)
    return zones


def ring_of(q, r):
    return max(abs(q), abs(r), abs(q + r))


def build(case: str):
    assert case in CASES, case
    openmc = paths.configure_openmc()
    import openmc.model

    def material(name, temperature, densities):
        mat = openmc.Material(name=name, temperature=temperature)
        for k, v in sorted(densities.items()):
            if re.fullmatch(r"[A-Z][a-z]?", k):
                mat.add_element(k, v, "ao")
            else:
                mat.add_nuclide(k, v, "ao")
        mat.set_density("sum")
        return mat

    def mixture(parts, skip=()):
        out = {}
        for part, frac in parts.items():
            if part in SOURCES and part not in skip:
                for k, v in SOURCES[part].items():
                    out[k] = out.get(k, 0.0) + frac * v
        return out

    mats = {"lower_structure": material("lower_structure", T_STRUCT, LOWER_STRUCTURE)}
    for key in ("driver_plenum", "lower_reflector", "radial_reflector", "radial_shield", "absorber", "empty_duct"):
        mats[key] = material(key, T_STRUCT, mixture(FRACTIONS[key]))

    fuel_T = T_DOPPLER if case == "doppler" else T_FUEL
    fuel = {}
    for zone, table in (("inner", "29"), ("middle", "30"), ("outer", "31")):
        for z, comp in enumerate(parse_fuel_table(table)):
            dens = mixture(FRACTIONS["driver_active"], skip=("coolant",) if case == "void" else ())
            for k, v in comp.items():
                dens[k] = dens.get(k, 0.0) + FRACTIONS["driver_active"]["fuel"] * v
            fuel[(zone, z)] = material(f"{zone}_zone{z + 1}", fuel_T, dens)

    planes = {}

    def plane(z):
        key = round(z, 6)
        if key not in planes:
            planes[key] = openmc.ZPlane(z0=z)
        return planes[key]

    def column(name, segments):
        """segments: [(z_top, material)] from the bottom (z = 0) up."""
        u = openmc.Universe(name=name)
        z_lo = None
        for z_top, mat in segments:
            region = -plane(z_top) if z_lo is None else (+plane(z_lo) & -plane(z_top))
            u.add_cell(openmc.Cell(name=f"{name}:{mat.name}", fill=mat, region=region))
            z_lo = z_top
        # above the top plane: the root cell ends there, but keep the universe complete
        u.add_cell(openmc.Cell(name=f"{name}:above", fill=mats["lower_reflector"], region=+plane(z_lo)))
        return u

    base = [(Z_LOWER_STRUCT_TOP, mats["lower_structure"]), (Z_CORE_BOTTOM, mats["lower_reflector"])]
    universes = {}
    for zone in ("inner", "middle", "outer"):
        universes[zone] = column(zone, base
                                 + [(Z_CORE_BOTTOM + ZONE_TOPS[z], fuel[(zone, z)]) for z in range(5)]
                                 + [(Z_PLENUM_TOP, mats["driver_plenum"]), (Z_TOP, mats["lower_reflector"])])
    universes["reflector"] = column("reflector", base + [(Z_PLENUM_TOP, mats["radial_reflector"]), (Z_TOP, mats["lower_reflector"])])
    universes["shield"] = column("shield", base + [(Z_PLENUM_TOP, mats["radial_shield"]), (Z_TOP, mats["lower_reflector"])])
    if case == "rods":  # §5.6: all primary and secondary rods completely inserted (absorber from the core bottom up)
        rod = base + [(Z_CORE_BOTTOM + ABSORBER_LENGTH, mats["absorber"]), (Z_TOP, mats["empty_duct"])]
    else:  # Figure 2.16: fully withdrawn
        rod = base + [(Z_CORE_TOP, mats["empty_duct"]), (Z_CORE_TOP + ABSORBER_LENGTH, mats["absorber"]), (Z_TOP, mats["empty_duct"])]
    universes["primary"] = column("primary", rod)
    universes["secondary"] = column("secondary", rod)

    layout = {(q, r): kind for q, r, kind in json.loads(LAYOUT.read_text())["cells"]}
    maxring = max(ring_of(q, r) for q, r in layout)
    void = openmc.Universe(name="void", cells=[openmc.Cell(name="void")])
    h = PITCH * math.sqrt(3) / 2

    def xy(q, r):
        return PITCH * (q + r / 2), h * r

    rings = []
    for n in range(maxring, -1, -1):
        members = [(q, r) for q in range(-n, n + 1) for r in range(-n, n + 1) if ring_of(q, r) == n]
        # OpenMC 'x' orientation: each ring starts on the +x axis and runs clockwise (HexLattice.show_indices)
        members.sort(key=lambda qr: (-math.atan2(xy(*qr)[1], xy(*qr)[0])) % (2 * math.pi))
        rings.append([universes[layout[m]] if m in layout else void for m in members])
    lattice = openmc.HexLattice(name="core")
    lattice.orientation = "x"
    lattice.center = (0.0, 0.0)
    lattice.pitch = (PITCH,)
    lattice.universes = rings
    lattice.outer = void

    radius = maxring * PITCH + PITCH  # beyond the farthest hexagon corner; the gap is void
    cyl = openmc.ZCylinder(r=radius, boundary_type="vacuum")
    bottom = openmc.ZPlane(z0=0.0, boundary_type="vacuum")
    top = openmc.ZPlane(z0=Z_TOP, boundary_type="vacuum")
    root = openmc.Universe(name="root", cells=[openmc.Cell(name="core", fill=lattice, region=-cyl & +bottom & -top)])
    geometry = openmc.Geometry(root)

    settings = openmc.Settings()
    settings.run_mode = "eigenvalue"
    settings.temperature = {"method": "interpolation"}
    settings.source = openmc.IndependentSource(
        space=openmc.stats.Box((-radius / 2, -radius / 2, Z_CORE_BOTTOM), (radius / 2, radius / 2, Z_CORE_TOP)),
        constraints={"fissionable": True},
    )
    model = openmc.model.Model(geometry=geometry, settings=settings)
    all_mats = list(mats.values()) + list(fuel.values())
    model.materials = openmc.Materials(all_mats)
    return model, layout, xy, universes


def check():
    counts = {}
    for case in CASES:
        model, layout, xy, universes = build(case)
        geom = model.geometry
        z_mid = (Z_CORE_BOTTOM + Z_CORE_TOP) / 2
        bad = 0
        for (q, r), kind in layout.items():
            path = geom.find((*xy(q, r), z_mid))
            names = [getattr(p, "name", "") for p in path]
            if kind not in names:
                bad += 1
                if bad < 5:
                    print("  mismatch at", (q, r), kind, names)
        # (11, 0) is a cut corner of ring 11 (Figure 2.12): inside the root cylinder but void
        assert (11, 0) not in layout
        outside = geom.find((PITCH * 11, 0.0, z_mid))
        assert outside and getattr(outside[-1], "fill", None) is None, "outside the core must be void"
        assert bad == 0, f"{case}: {bad} lattice positions hold the wrong universe"
        # axial spot checks through a centre-ring fuel column and a control column
        fuel_q = next(k for k, v in layout.items() if v == "inner")
        mats_along = [geom.find((*xy(*fuel_q), z))[-1].fill.name for z in (10, 100, Z_CORE_BOTTOM + 1, Z_CORE_TOP - 1, 300, 470)]
        rod_q = next(k for k, v in layout.items() if v == "primary")
        rod_along = [geom.find((*xy(*rod_q), z))[-1].fill.name for z in (Z_CORE_BOTTOM + 1, Z_CORE_TOP - 1, Z_CORE_TOP + 1, 470)]
        print(f"{case}: all {len(layout)} positions correct; fuel column {mats_along}; rod column {rod_along}")
        counts[case] = len(model.materials)
    # hand-checkable number: sodium void removes exactly the active-core sodium
    nominal, _, _, _ = build("nominal")
    void, _, _, _ = build("void")
    na = lambda m: dict((n.name, n.percent) for n in m.nuclides).get("Na23", 0.0)
    n_nom = [na(m) for m in nominal.materials if "zone" in m.name]
    n_void = [na(m) for m in void.materials if "zone" in m.name]
    assert all(abs(v - 0.3327 * COOLANT["Na23"]) < 1e-12 for v in n_nom) and all(v == 0 for v in n_void)
    print("sodium in the active core: nominal", n_nom[0], "void", n_void[0])
    print("geometry and material checks passed")


def run(case, particles, batches, inactive):
    model, *_ = build(case)
    model.settings.particles = particles
    model.settings.batches = batches
    model.settings.inactive = inactive
    # Shannon entropy of the fission source, to show the inactive batches were enough (checked in --summarise)
    import openmc
    mesh = openmc.RegularMesh()
    mesh.lower_left = (-11 * PITCH, -11 * PITCH, Z_CORE_BOTTOM)
    mesh.upper_right = (11 * PITCH, 11 * PITCH, Z_CORE_TOP)
    mesh.dimension = (10, 10, 5)
    model.settings.entropy_mesh = mesh
    if case == "nominal":
        model.settings.ifp_n_generation = 10
        model.add_kinetics_parameters_tallies()
    cwd = paths.run_dir(f"mox1000/{case}")
    for old in glob.glob(str(cwd / "statepoint.*.h5")):
        Path(old).unlink()
    sp = model.run(cwd=cwd, threads=paths.THREADS, output=True)
    print("statepoint:", sp)


def summarise():
    import openmc

    def load(case):
        files = sorted(glob.glob(str(paths.RUNS / "mox1000" / case / "statepoint.*.h5")))
        if not files:
            return None
        return openmc.StatePoint(files[-1])

    sp = {c: load(c) for c in CASES}
    if sp["nominal"] is None:
        sys.exit("nominal case has not been run")

    def k(c):
        return sp[c].keff.nominal_value, sp[c].keff.std_dev

    def worth(c):  # ρ(c) − ρ(nominal) in pcm (benchmark pcm = 1e5·Δk/(k₁k₂))
        (k1, s1), (k2, s2) = k("nominal"), k(c)
        return 1e5 * (1 / k1 - 1 / k2), 1e5 * math.hypot(s1 / k1 ** 2, s2 / k2 ** 2)

    ours = {"keff": k("nominal")}
    kin = sp["nominal"].get_kinetics_parameters()
    if kin.beta_effective is not None:
        ours["betaEff_pcm"] = (1e5 * kin.beta_effective.nominal_value, 1e5 * kin.beta_effective.std_dev)
    if kin.generation_time is not None:
        ours["generationTime_s"] = (kin.generation_time.nominal_value, kin.generation_time.std_dev)
    if sp["void"]:
        ours["sodiumVoid_pcm"] = worth("void")
    if sp["doppler"]:
        d, s = worth("doppler")
        f = math.log(T_DOPPLER / T_FUEL)
        ours["doppler_pcm"] = (d / f, s / f)
    if sp["rods"]:
        d, s = worth("rods")
        ours["controlRods_pcm"] = (-d, s)

    import numpy as np
    convergence = {}
    for c in CASES:
        if sp[c] is None:
            continue
        try:
            ent = np.asarray(sp[c].entropy)
        except KeyError:
            convergence[c] = {"converged": None, "note": "run had no entropy mesh"}
            print(f"entropy {c}: not recorded")
            continue
        active = ent[sp[c].n_inactive:]
        # the source is converged if the entropy entering the active batches already sits inside the active band
        first = ent[sp[c].n_inactive]
        ok = bool(active.min() <= first <= active.max() and abs(first - active.mean()) < 3 * active.std())
        convergence[c] = {"activeMean": float(active.mean()), "activeStd": float(active.std()), "firstActive": float(first), "converged": ok}
        print(f"entropy {c}: first active {first:.4f}, active {active.mean():.4f} ± {active.std():.4f} → {'converged' if ok else 'NOT CONVERGED'}")

    rows = {}
    print(f"{'quantity':18} {'OpenMC (ENDF/B-VIII.1)':>26} {'Table 4.4 avg ± SD':>22} {'z':>6}")
    for key, (v, s) in ours.items():
        row = {"value": v, "sigma": s}
        if key in BENCHMARK:
            avg, sd = BENCHMARK[key]
            z = (v - avg) / math.hypot(sd, s)
            row.update({"benchmarkAverage": avg, "benchmarkSD": sd, "z": z, "withinTwoSD": abs(z) <= 2})
            print(f"{key:18} {v:>18.5g} ± {s:<7.2g} {avg:>12g} ± {sd:<8g} {z:>6.2f}")
        else:
            print(f"{key:18} {v:>18.5g} ± {s:<7.2g}")
        rows[key] = row
    meta = {
        "model": "tools/xsgen/mox1000_model.py (homogeneous assemblies)",
        "library": "ENDF/B-VIII.1 (OpenMC HDF5)",
        "openmc": openmc.__version__,
        "runs": {c: {"particles": int(sp[c].n_particles), "batches": int(sp[c].n_batches), "inactive": int(sp[c].n_inactive)}
                 for c in CASES if sp[c]},
        "acceptance": "|z| <= 2 with z = (ours − average) / sqrt(SD² + σ²); SD is the code-to-code spread of Table 4.4",
        "notes": [
            "Homogeneous models give 10–17 % higher rod worth than heterogeneous ones (§5.6); compare controlRods with ANL-4/ANL-5/CEA-5.",
            "Doppler state at 2500 K; K_D = Δρ/ln(2500/1300.15).",
        ],
    }
    RESULTS.write_text(json.dumps({"meta": meta, "sourceConvergence": convergence, "results": rows}, indent=1))
    print("wrote", RESULTS)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--case", choices=CASES)
    ap.add_argument("--particles", type=int, default=100000)
    ap.add_argument("--batches", type=int, default=150)
    ap.add_argument("--inactive", type=int, default=50)
    ap.add_argument("--summarise", action="store_true")
    a = ap.parse_args()
    if a.check:
        check()
    if a.case:
        run(a.case, a.particles, a.batches, a.inactive)
    if a.summarise:
        summarise()
