"""
Kallskar xsgen: the K1 (SFR-1000) core in OpenMC, fresh as-fabricated fuel, pin by pin.

Built from spec §2.1–§2.3 through Config (tools/xsgen/k1_materials.py reads Config/Core.luau), with the materials of
docs/K1_MATERIALS.md and the choices D-038 to D-042. It reuses the patterns tools/xsgen/mox1000_model.py validated on
the NEA MOX-1000 core (hexagonal lattice ordering, entropy mesh, IFP kinetics tallies).

Geometry
  radial   rings 0–16 on the 179 mm pitch (817 positions, §2.1), rod positions from Config.Core.rodLayout (D-010),
           vacuum outside ring 16 (D-042)
  axial    z = 0 at the bottom of the fissile column, as in Systems/Core/Mesh: 300 mm lower steel reflector below,
           1,000 mm fuel, 1,100 mm plenum above; vacuum beyond (D-042; the axial-reflective case bounds it)
  fuel     271 explicit pins per assembly (annular pellet, gap, 15-15Ti cladding with the wire smeared in, D-040) in
           an EM10 wrapper; below the fuel the cladding holds EM10 slugs, above it the plenum gas (void)
  rods     homogeneous absorber columns (NEA MOX-3600 Table 2.8), 1,000 mm long, over an empty-duct follower (D-041);
           "all rods out" puts every tip at 1,100 mm (§0.1's full stroke; SSR parked there, §3.4)
  ex-core  reflector and steel shield: NEA MOX-1000 reflector; B4C shield: MOX-1000 shield; ring 15 storage holds
           outer-zone fuel as a bound on its effect, measured by the storage-empty case (D-042)

Cases (state; what it is for)
  nominal          full power: fuel 1,380 K, coolant and structure at the 462.5 °C core mean, IFP kinetics
  hzp              hot zero power, isothermal 648 K (the feedback reference, Config.Feedback)
  cold230          isothermal 230 °C, the state of §3.3's excess reactivity
  clad-density     nominal with the cladding density +1 %, the uncertainty tools/derive/cladding_density.py states
  storage-empty    nominal with ring 15 empty (sodium-filled ducts)
  axial-reflective nominal with reflective top and bottom, an upper bound on what lies beyond the §2.1 lengths
  boc              the equilibrium four-batch core at beginning of cycle, full power, IFP kinetics (D-012, D-044):
                   each fuel position holds the burnup of its batch from k1_deplete, ring 15 holds discharged fuel
  boc-cold230      the same core isothermal at 230 °C: §3.3's excess reactivity, the §3.7 target 2,250 ± 150 pcm

Usage (WSL, env kallskar-xs):
    python tools/xsgen/k1_model.py --check
    python tools/xsgen/k1_model.py --case nominal --particles 100000 --batches 150 --inactive 50
    python tools/xsgen/k1_model.py --summarise
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
import k1_materials as M  # noqa: E402
import mox1000_model as mox1000  # noqa: E402  (NEA MOX-1000 HT-9, natural B4C and assembly fractions)

RESULTS = paths.RESULTS / "k1_fresh_results.json"
DEPLETION = paths.RESULTS / "k1_depletion.json"
CASES = ("nominal", "hzp", "cold230", "clad-density", "storage-empty", "axial-reflective", "boc", "boc-cold230")
BOC_CASES = ("boc", "boc-cold230")
BOC_BATCH_EFPD = (0.0, 160.0, 320.0, 480.0)  # a batch's burnup at BOC: 0–3 cycles of §2.3's 160 EFPD (D-043)
DISCHARGE_EFPD = 640.0
ROD_OUT_CM = M.luau_number("Rods", "parked_mm") / 10.0  # §0.1 full stroke, 1,100 mm; the SSR park position (§3.4)
ABSORBER_CM = M.luau_number("Core", "fissileHeight_mm") / 10.0  # D-041
DIRS = ((1, 0), (0, 1), (-1, 1), (-1, 0), (0, -1), (1, -1))  # Systems/Core/Mesh, anticlockwise from 0°


def axial_of(n: int, j: int) -> tuple[int, int]:
    """Ring n, position j → axial (q, r), exactly as Systems/Core/Mesh.axialOf."""
    if n == 0:
        return 0, 0
    e, s = divmod(j, n)
    d, t = DIRS[e], DIRS[(e + 2) % 6]
    return n * d[0] + s * t[0], n * d[1] + s * t[1]


def core_map() -> dict:
    """{(q, r): kind} for all 817 positions. Kinds: inner, outer, RR, SM_A, SM_B, SM_C, SSR, reflector, shieldB4C,
    storage, shieldSteel."""
    rings = M.core_rings()
    out, angle = {}, {}
    for info in rings:
        n = info["ring"]
        for j in range(1 if n == 0 else 6 * n):
            q, r = axial_of(n, j)
            x, y = q + r / 2, r * math.sqrt(3) / 2
            angle[(q, r)] = 0.0 if n == 0 else math.degrees(math.atan2(y, x)) % 360
            out[(q, r)] = info["fuelZone"] if info["kind"] == "fuel" else info["kind"]
    for rod in M.rod_layout():
        for a in rod["angles"]:
            hits = [k for k in out if max(abs(k[0]), abs(k[1]), abs(k[0] + k[1])) == rod["ring"]
                    and abs((angle[k] - a + 180) % 360 - 180) < 1e-6]
            assert len(hits) == 1 and out[hits[0]] in ("inner", "outer"), (rod, a, hits)
            out[hits[0]] = rod["set"]
    return out


# D-044: sublattice colour (q mod 2) + 2·(r mod 2) → batch. Colour 0 is the one 60° rotations leave fixed; the rods
# thin it unevenly (31 inner / 48 outer against 38 / 36 for the others), so it takes a batch next to the core-average
# burnup (1.5 cycles), where that imbalance moves the least reactivity. Batches 1 and 2 tie; the lower is taken.
SUBLATTICE_BATCH = (1, 0, 2, 3)


def batch_of(q: int, r: int) -> int:
    """D-044: batch (0 = fresh … 3 = third cycle) by the 2 × 2 sublattice of (q, r). Each position's six neighbours
    are then two of each other batch, the most even scatter a four-batch hexagonal core allows."""
    return SUBLATTICE_BATCH[(q % 2) + 2 * (r % 2)]


def state(case: str) -> dict:
    T = M.temperatures()
    if case == "hzp":
        return {"fuel": T["hotZeroPower"], "struct": T["hotZeroPower"]}
    if case in ("cold230", "boc-cold230"):
        return {"fuel": T["refuelling"], "struct": T["refuelling"]}
    return {"fuel": T["fuelAverage"], "struct": T["coolantMean"]}


def depleted_fuel(openmc) -> dict:
    """Pellet compositions for the BOC core from k1_deplete's export: '<zone>_b<batch>' and 'outer_discharged'.
    Nuclides the library has no neutron data for cannot be transported and are dropped; the dropped share is printed."""
    dep = json.loads(DEPLETION.read_text(encoding="utf-8"))
    lib = openmc.data.DataLibrary.from_xml(str(paths.CROSS_SECTIONS))
    have = {n for entry in lib.libraries if entry["type"] == "neutron" for n in entry["materials"]}
    out = {}
    for zone in ("inner", "outer"):
        points = {p["EFPD"]: p["densities"] for p in dep["zones"][zone]["points"]}
        wanted = [(f"{zone}_b{b}", t) for b, t in enumerate(BOC_BATCH_EFPD)]
        if zone == "outer":
            wanted.append(("outer_discharged", DISCHARGE_EFPD))
        for key, t in wanted:
            dens = points[t]
            kept = {k: v for k, v in dens.items() if k in have}
            dropped = 1 - sum(kept.values()) / sum(dens.values())
            print(f"  {key}: {len(kept)} nuclides, {len(dens) - len(kept)} without data ({dropped:.1e} of the atoms)")
            out[key] = kept
    return out


def build(case: str):
    assert case in CASES, case
    openmc = paths.configure_openmc()
    import openmc.model

    g = M.spec_geometry()
    fr = M.cell_fractions(g)
    st = state(case)
    Ts = st["struct"]

    def material(name, T, dens):
        mat = openmc.Material(name=name, temperature=T)
        for k, v in sorted(dens.items()):
            if re.fullmatch(r"[A-Z][a-z]?", k):
                mat.add_element(k, v, "ao")
            else:
                mat.add_nuclide(k, v, "ao")
        mat.set_density("sum")
        return mat

    def atoms(mat):
        return dict(mat.get_nuclide_atom_densities())

    def mixture(name, parts):
        """parts: [(fraction, material)]; fractions of the cell, void where they do not add to 1."""
        dens = {}
        for f, mat in parts:
            for k, v in atoms(mat).items():
                dens[k] = dens.get(k, 0.0) + f * v
        mat = openmc.Material(name=name, temperature=Ts)
        for k, v in sorted(dens.items()):
            mat.add_nuclide(k, v, "ao")
        mat.set_density("sum")
        return mat

    # pure materials
    fuel = {}
    boc = case in BOC_CASES
    if boc:
        for key, dens in depleted_fuel(openmc).items():
            fuel[key] = material(f"fuel_{key}", st["fuel"], dens)
    else:
        for zone in ("inner", "outer"):
            dens, _ = M.fresh_mox(g["puFraction"][zone], g["pelletTD"])
            fuel[zone] = material(f"fuel_{zone}", st["fuel"], dens)
    clad = openmc.Material(name="clad_15-15Ti", temperature=Ts)
    for el, w in M.clad_weight_percent().items():
        clad.add_element(el, w, "wo")
    clad.set_density("g/cm3", M.clad_density() * (1.01 if case == "clad-density" else 1.0))
    em10 = material("EM10", Ts, M.NEA_EM10)
    na = material("sodium", Ts, M.sodium(Ts))
    b4c_primary = material("B4C_primary", Ts, M.NEA_B4C_PRIMARY)
    b4c_secondary = material("B4C_secondary", Ts, M.NEA_B4C_SECONDARY)
    ht9 = material("HT9_mox1000", Ts, mox1000.HT9)
    b4c_nat = material("B4C_natural_mox1000", Ts, mox1000.B4C_NATURAL)

    # homogeneous mixtures (fractions of the 179 mm cell)
    lo = fr["lower"]
    lower_mix = mixture("lower_reflector_mix", [(lo["slug"] + lo["wrapper"], em10), (lo["clad"] + lo["wire"], clad),
                                                (lo["sodium"], na)])
    follower = mixture("follower", [(fr["follower"]["wrapper"], em10), (fr["follower"]["sodium"], na)])
    absorber = {}
    for system, b4c in (("primary", b4c_primary), ("secondary", b4c_secondary)):
        f = M.NEA_ROD_FRACTIONS[system]
        absorber[system] = mixture(f"absorber_{system}", [(f["b4c"], b4c), (f["sodium"], na), (f["em10"], em10)])
    rf = mox1000.FRACTIONS["radial_reflector"]
    reflector = mixture("reflector_mox1000", [(rf["coolant"], na), (rf["ht9"], ht9)])
    sf = mox1000.FRACTIONS["radial_shield"]
    shield = mixture("shield_mox1000", [(sf["coolant"], na), (sf["ht9"], ht9), (sf["b4c_nat"], b4c_nat)])

    # axial planes: z = 0 at the bottom of the fuel
    z_bottom = -g["lowerReflector"]
    z_fuel_top = g["fissileHeight"]
    z_top = z_fuel_top + g["upperPlenum"]
    planes = {}

    def plane(z):
        key = round(z, 6)
        if key not in planes:
            planes[key] = openmc.ZPlane(z0=z)
        return planes[key]

    # the fuel pin: one universe, stacked lower slug / fuel / plenum
    c_hole = openmc.ZCylinder(r=g["pelletHole"] / 2)
    c_pel = openmc.ZCylinder(r=g["pelletOD"] / 2)
    c_ci = openmc.ZCylinder(r=g["cladID"] / 2)
    c_co = openmc.ZCylinder(r=M.smeared_clad_od(g) / 2)
    z0, z1 = plane(0.0), plane(z_fuel_top)

    def pin(zone):  # zone: a key of `fuel`
        u = openmc.Universe(name=f"pin_{zone}")
        u.add_cells([
            openmc.Cell(name=f"pin_{zone}:fuel", fill=fuel[zone], region=+c_hole & -c_pel & +z0 & -z1),
            openmc.Cell(name=f"pin_{zone}:hole", region=-c_hole & +z0 & -z1),
            openmc.Cell(name=f"pin_{zone}:slug", fill=em10, region=-c_pel & -z0),
            openmc.Cell(name=f"pin_{zone}:gap", region=+c_pel & -c_ci & -z1),
            openmc.Cell(name=f"pin_{zone}:plenum", region=-c_ci & +z1),
            openmc.Cell(name=f"pin_{zone}:clad", fill=clad, region=+c_ci & -c_co),
            openmc.Cell(name=f"pin_{zone}:sodium", fill=na, region=+c_co),
        ])
        return u

    na_u = openmc.Universe(name="sodium", cells=[openmc.Cell(name="sodium", fill=na)])
    inner_prism = openmc.model.HexagonalPrism(edge_length=g["wrapperInnerFlats"] / math.sqrt(3), orientation="y")
    outer_prism = openmc.model.HexagonalPrism(edge_length=g["wrapperFlats"] / math.sqrt(3), orientation="y")

    def fuel_assembly(zone):
        p = pin(zone)
        lat = openmc.HexLattice(name=f"bundle_{zone}")
        lat.orientation = "y"  # pin rows parallel to the wrapper flats, which face ±x in the core lattice
        lat.center = (0.0, 0.0)
        lat.pitch = (g["pinPitch"],)
        lat.universes = [[p] * (6 * n) if n else [p] for n in range(g["pinRings"], -1, -1)]
        lat.outer = na_u
        u = openmc.Universe(name=zone)
        u.add_cells([
            openmc.Cell(name=f"{zone}:bundle", fill=lat, region=-inner_prism),
            openmc.Cell(name=f"{zone}:wrapper", fill=em10, region=+inner_prism & -outer_prism),
            openmc.Cell(name=f"{zone}:gap", fill=na, region=+outer_prism),
        ])
        return u

    def column(name, segments):
        """segments: [(z_top, material)] from the bottom up; the last one runs to infinity."""
        u = openmc.Universe(name=name)
        z_lo = None
        for i, (zt, mat) in enumerate(segments):
            last = i == len(segments) - 1
            region = None
            if z_lo is not None:
                region = +plane(z_lo)
            if not last:
                region = -plane(zt) if region is None else region & -plane(zt)
            u.add_cell(openmc.Cell(name=f"{name}:{mat.name}", fill=mat, region=region))
            z_lo = zt
        return u

    def rod(name, system, tip):
        segs = [(0.0, lower_mix)]
        if tip > 0:
            segs.append((tip, follower))
        segs.append((tip + ABSORBER_CM, absorber[system]))
        segs.append((None, follower))
        return column(name, segs)

    universes = {key: fuel_assembly(key) for key in fuel}
    for s in ("RR", "SM_A", "SM_B", "SM_C"):
        universes[s] = rod(s, "primary", ROD_OUT_CM)
    universes["SSR"] = rod("SSR", "secondary", ROD_OUT_CM)
    universes["reflector"] = column("reflector", [(None, reflector)])
    universes["shieldB4C"] = column("shieldB4C", [(None, shield)])
    universes["shieldSteel"] = column("shieldSteel", [(None, reflector)])
    if case == "storage-empty":
        universes["storage"] = column("storage", [(None, follower)])
    else:
        universes["storage"] = universes["outer_discharged" if boc else "outer"]

    layout = core_map()
    pitch = g["assemblyPitch"]
    h = pitch * math.sqrt(3) / 2

    def xy(q, r):
        return pitch * (q + r / 2), h * r

    def universe_at(m):
        kind = layout[m]
        if boc and kind in ("inner", "outer"):
            return universes[f"{kind}_b{batch_of(*m)}"]
        return universes[kind]

    if boc:
        counts = {}
        for m, kind in layout.items():
            if kind in ("inner", "outer"):
                counts[(kind, batch_of(*m))] = counts.get((kind, batch_of(*m)), 0) + 1
        print("BOC batches (zone, batch): count", dict(sorted(counts.items())))

    maxring = 16
    rings = []
    for n in range(maxring, -1, -1):
        members = [k for k in layout if max(abs(k[0]), abs(k[1]), abs(k[0] + k[1])) == n]
        # OpenMC 'x' orientation: each ring starts on the +x axis and runs clockwise (as in mox1000_model)
        members.sort(key=lambda qr: (-math.atan2(xy(*qr)[1], xy(*qr)[0])) % (2 * math.pi))
        rings.append([universe_at(m) for m in members])
    void = openmc.Universe(name="void", cells=[openmc.Cell(name="void")])
    lattice = openmc.HexLattice(name="core")
    lattice.orientation = "x"
    lattice.center = (0.0, 0.0)
    lattice.pitch = (pitch,)
    lattice.universes = rings
    lattice.outer = void

    ends = "reflective" if case == "axial-reflective" else "vacuum"
    radius = (maxring + 1) * pitch  # beyond the farthest hexagon corner; the gap is void
    cyl = openmc.ZCylinder(r=radius, boundary_type="vacuum")
    bottom = openmc.ZPlane(z0=z_bottom, boundary_type=ends)
    top = openmc.ZPlane(z0=z_top, boundary_type=ends)
    root = openmc.Universe(name="root", cells=[openmc.Cell(name="core", fill=lattice, region=-cyl & +bottom & -top)])

    settings = openmc.Settings()
    settings.run_mode = "eigenvalue"
    settings.temperature = {"method": "interpolation"}
    r_core = 11 * pitch
    settings.source = openmc.IndependentSource(
        space=openmc.stats.Box((-r_core, -r_core, 0.0), (r_core, r_core, z_fuel_top)),
        constraints={"fissionable": True},
    )
    model = openmc.model.Model(geometry=openmc.Geometry(root), settings=settings)
    mats = list(fuel.values()) + [clad, em10, na, lower_mix, follower, absorber["primary"], absorber["secondary"],
                                  reflector, shield]
    model.materials = openmc.Materials(mats)
    parts = {"universes": universes, "fuel": fuel, "assemblyMaterials": list(fuel.values()) + [clad, em10, na]}
    return model, layout, xy, g, fr, parts


def check():
    """Geometry, map and inventory checks against Config; no transport."""
    fails = []

    def ok(label, cond, detail=""):
        print(f"  [{'ok' if cond else 'FAIL'}] {label}{(': ' + detail) if detail else ''}")
        if not cond:
            fails.append(label)

    print("NEA transcriptions")
    for f in M.parse_nea_checks():
        print("   ", f)
    ok("Tables 2.8, 2.11, 2.13 and 2.14 as transcribed", not M.parse_nea_checks())

    model, layout, xy, g, fr, _ = build("nominal")
    print("core map (Config.Core.rings and rodLayout)")
    counts = {}
    for kind in layout.values():
        counts[kind] = counts.get(kind, 0) + 1
    ok("817 positions in rings 0–16", len(layout) == 817, str(len(layout)))
    core_txt = M._luau("Core")
    tot = dict((k, int(v)) for k, v in re.findall(r"\b(fuel|fuelInner|fuelOuter|regulating|shim|secondaryShutdown)"
                                                  r"\s*=\s*(\d+),", core_txt.split("totals = spec")[1].split("}")[0]))
    ok("fuel 145 inner + 156 outer = 301", counts["inner"] == tot["fuelInner"] and counts["outer"] == tot["fuelOuter"]
       and counts["inner"] + counts["outer"] == tot["fuel"], f"{counts['inner']} + {counts['outer']}")
    ok("3 RR, 18 shim, 9 SSR", counts["RR"] == tot["regulating"] and counts["SSR"] == tot["secondaryShutdown"]
       and counts["SM_A"] + counts["SM_B"] + counts["SM_C"] == tot["shim"],
       f"RR {counts['RR']}, A/B/C {counts['SM_A']}/{counts['SM_B']}/{counts['SM_C']}, SSR {counts['SSR']}")

    print("geometry (point location)")
    geom = model.geometry
    bad = []
    for (q, r), kind in layout.items():
        name = "outer" if kind == "storage" else kind
        path = [getattr(p, "name", "") for p in geom.find((*xy(q, r), 150.0))]
        if name not in path:
            bad.append(((q, r), kind, path[-3:]))
    ok("every position holds its universe (at z = 150 cm)", not bad, f"{len(bad)} wrong {bad[:3]}")
    fuel_q = next(k for k, v in layout.items() if v == "inner" and k != (0, 0))
    x0, y0 = xy(*fuel_q)
    probe = lambda dx, dy, z: geom.find((x0 + dx, y0 + dy, z))[-1]
    fill = lambda c: getattr(c.fill, "name", None) if c.fill is not None else "void"
    ok("pin at the assembly centre: slug / fuel / hole / plenum by height",
       [fill(probe(0.25, 0, z)) for z in (-15, 50, 150)] == ["EM10", "fuel_inner", "void"]
       and fill(probe(0.0, 0.0, 50)) == "void", str([fill(probe(0.25, 0, z)) for z in (-15, 50, 150)]))
    ok("pin at the assembly centre: cladding and sodium", fill(probe(0.40, 0, 50)) == "clad_15-15Ti"
       and fill(probe(0.47, 0.0, 50)) == "sodium", f"{fill(probe(0.40, 0, 50))}, {fill(probe(0.47, 0, 50))}")
    flat_in, flat_out = g["wrapperInnerFlats"] / 2, g["wrapperFlats"] / 2
    ok("wrapper flats face ±x (the core lattice's neighbour direction)",
       fill(probe(0.5 * (flat_in + flat_out), 0, 50)) == "EM10" and fill(probe(0, 0.5 * (flat_in + flat_out), 50)) != "EM10")
    corner = g["pinRings"] * g["pinPitch"]
    ok("pin lattice corner sits on +y, inside the wrapper corner", fill(probe(0.25, corner, 50)) == "fuel_inner",
       fill(probe(0.25, corner, 50)))
    clearance = flat_in - (corner * math.sqrt(3) / 2 + g["cladOD"] / 2)
    ok("outer pin row clears the wrapper by at least the wire", clearance >= g["wireD"] - 1e-9,
       f"{clearance * 10:.2f} mm against a {g['wireD'] * 10:.1f} mm wire")
    rod_q = next(k for k, v in layout.items() if v == "SSR")
    xr, yr = xy(*rod_q)
    along = [fill(geom.find((xr, yr, z))[-1]) for z in (-15, 50, 105, 115, 205)]
    ok("SSR column: lower reflector / follower / follower / absorber / absorber", along ==
       ["lower_reflector_mix", "follower", "follower", "absorber_secondary", "absorber_secondary"], str(along))

    print("fractions and inventory (§2.3)")
    f = fr["fuel"]
    print("    fuel cell: " + ", ".join(f"{k} {100 * v:.2f} %" for k, v in f.items()))
    ok("pins × assemblies = §2.3 total pins", g["pins"] * tot["fuel"] == g["totalPins"],
       f"{g['pins']} × {tot['fuel']} = {g['pins'] * tot['fuel']}")
    hm = 0.0
    for zone in ("inner", "outer"):
        _, facts = M.fresh_mox(g["puFraction"][zone], g["pelletTD"])
        vol = f["pellet"] * fr["cell_cm2"] * g["fissileHeight"] * counts[zone]
        hm += facts["heavyMetal_gpcm3"] * vol / 1e6
        print(f"    {zone}: Pu {100 * g['puFraction'][zone]:.0f} wt % (y = {facts['puAtomFraction']:.4f}), "
              f"TD {facts['TD_gpcm3']:.4f}, ρ {facts['density_gpcm3']:.4f} g/cm³")
    # "≈ 29" is printed to two figures: anything that rounds to 29 agrees
    ok("heavy metal matches §2.3's ≈ 29 tHM", round(hm) == round(g["heavyMetal_t"]), f"{hm:.2f} t")
    print(f"    sodium at {state('nominal')['struct'] - 273.15:.1f} °C: {M.sodium_density(state('nominal')['struct']):.4f} g/cm³")

    print()
    print(f"{'all checks pass' if not fails else f'{len(fails)} FAILED: ' + '; '.join(fails)}")
    if fails:
        sys.exit(1)


def run(case, particles, batches, inactive):
    model, *_ = build(case)
    s = model.settings
    s.particles, s.batches, s.inactive = particles, batches, inactive
    import openmc
    pitch = M.spec_geometry()["assemblyPitch"]
    mesh = openmc.RegularMesh()  # covers ring 15's stored fuel too, so every fission site is counted
    mesh.lower_left = (-17 * pitch, -17 * pitch, 0.0)
    mesh.upper_right = (17 * pitch, 17 * pitch, M.spec_geometry()["fissileHeight"])
    mesh.dimension = (17, 17, 5)
    s.entropy_mesh = mesh
    if case in ("nominal", "boc"):
        s.ifp_n_generation = 10
        model.add_kinetics_parameters_tallies()
    cwd = paths.run_dir(f"k1_fresh/{case}")
    for old in glob.glob(str(cwd / "statepoint.*.h5")):
        Path(old).unlink()
    sp = model.run(cwd=cwd, threads=paths.THREADS, output=True)
    print("statepoint:", sp)


def summarise():
    import numpy as np
    import openmc

    def load(case):
        files = sorted(glob.glob(str(paths.RUNS / "k1_fresh" / case / "statepoint.*.h5")))
        return openmc.StatePoint(files[-1]) if files else None

    sp = {c: load(c) for c in CASES}
    if sp["nominal"] is None:
        sys.exit("nominal case has not been run")
    k = lambda c: (sp[c].keff.nominal_value, sp[c].keff.std_dev)

    def drho(c, ref="nominal"):  # ρ(c) − ρ(ref), pcm
        (k1, s1), (k2, s2) = k(ref), k(c)
        return 1e5 * (1 / k1 - 1 / k2), 1e5 * math.hypot(s1 / k1 ** 2, s2 / k2 ** 2)

    rows = {}
    for c in CASES:
        if sp[c] is None:
            continue
        kv, ks = k(c)
        row = {"keff": kv, "sigma": ks, "rho_pcm": 1e5 * (1 - 1 / kv), "runtime_s": float(sp[c].runtime["total"])}
        ent = np.asarray(sp[c].entropy)
        active = ent[sp[c].n_inactive:]
        first = ent[sp[c].n_inactive]
        row["sourceConverged"] = bool(active.min() <= first <= active.max() and abs(first - active.mean()) < 3 * active.std())
        row["run"] = {"particles": int(sp[c].n_particles), "batches": int(sp[c].n_batches), "inactive": int(sp[c].n_inactive)}
        if c != "nominal":
            d, s = drho(c)
            row["deltaRhoFromNominal_pcm"] = {"value": d, "sigma": s}
        rows[c] = row
        print(f"{c:17} k = {kv:.5f} ± {ks:.5f}  (ρ {row['rho_pcm']:+8.0f} pcm)"
              + (f"  Δρ vs nominal {row['deltaRhoFromNominal_pcm']['value']:+7.0f} ± {row['deltaRhoFromNominal_pcm']['sigma']:.0f}"
                 if c != "nominal" else "")
              + ("" if row["sourceConverged"] else "  SOURCE NOT CONVERGED"))
    for c in ("nominal", "boc"):
        if sp[c] is None:
            continue
        kin = sp[c].get_kinetics_parameters()
        if kin.beta_effective is None:
            continue
        rows[c]["betaEff_pcm"] = {"value": 1e5 * kin.beta_effective.nominal_value, "sigma": 1e5 * kin.beta_effective.std_dev}
        rows[c]["generationTime_s"] = {"value": kin.generation_time.nominal_value, "sigma": kin.generation_time.std_dev}
        print(f"{c}: β_eff {rows[c]['betaEff_pcm']['value']:.1f} ± {rows[c]['betaEff_pcm']['sigma']:.1f} pcm "
              f"(§3.1 360); Λ {rows[c]['generationTime_s']['value']:.3e} s (§3.1 4.0e-7)")

    info = {}
    T = M.temperatures()
    kd = M.luau_number("Feedback", "constant_pcm")
    m = re.search(r"sodiumDensity\s*=\s*spec\(\{\s*coefficient_pcmpK\s*=\s*([\d.]+)", M._luau("Feedback"))
    na = float(m.group(1))
    if sp["hzp"]:
        d, s = drho("nominal", "hzp")
        expect = kd * math.log(T["fuelAverage"] / T["hotZeroPower"]) + na * (T["coolantMean"] - T["hotZeroPower"])
        info["hzpToFullPower_pcm"] = {"value": d, "sigma": s, "specFixedGeometryParts_pcm": expect,
                                      "note": "fresh core; §3.2 Doppler + sodium-density terms only, no expansion"}
        print(f"HZP → full power, fixed geometry: {d:+.0f} ± {s:.0f} pcm (for information: §3.2's Doppler and sodium "
              f"terms give {expect:+.0f})")
    if sp["cold230"] and sp["hzp"]:
        d, s = drho("hzp", "cold230")
        expect = kd * math.log(T["hotZeroPower"] / T["refuelling"]) + na * (T["hotZeroPower"] - T["refuelling"])
        info["cold230ToHzp_pcm"] = {"value": d, "sigma": s, "specFixedGeometryParts_pcm": expect,
                                    "note": "fresh core; §3.3 isothermal 376 pcm includes the expansion terms"}
        print(f"230 °C → HZP, fixed geometry: {d:+.0f} ± {s:.0f} pcm (for information: §3.2's Doppler and sodium "
              f"terms give {expect:+.0f}; §3.3's whole isothermal defect is −376)")

    if sp["boc-cold230"]:
        m = re.search(r"excessReactivity230BOC_pcm\s*=\s*\{\s*target\s*=\s*(\d+),\s*absTol\s*=\s*(\d+)",
                      M._luau("PhysicsModel"))
        target, tol = float(m.group(1)), float(m.group(2))
        kv, ks = k("boc-cold230")
        v, s = 1e5 * (1 - 1 / kv), 1e5 * ks / kv ** 2
        info["excessReactivity230BOC_pcm"] = {"value": v, "sigma": s, "target": target, "absTol": tol,
                                              "withinTolerance": abs(v - target) <= tol + 3 * s}
        print(f"excess reactivity, BOC, 230 °C, all rods out: {v:+.0f} ± {s:.0f} pcm against §3.3's {target:.0f} ± {tol:.0f}")
    meta = {
        "model": "tools/xsgen/k1_model.py (explicit pins, fresh as-fabricated fuel; D-038 to D-042)",
        "library": "ENDF/B-VIII.1 (OpenMC HDF5)",
        "openmc": openmc.__version__,
        "quality": "preliminary: fresh core, not the equilibrium BOC core §3.3 and D-012 refer to",
    }
    RESULTS.write_text(json.dumps({"meta": meta, "cases": rows, "forInformation": info}, indent=1))
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
