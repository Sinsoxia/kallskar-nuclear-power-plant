"""
Kallskar xsgen: K1 (SFR-1000) materials and volume fractions for the OpenMC model.

Every number here is read from Config (the spec), cited, derived, or a recorded decision. docs/K1_MATERIALS.md is the
readable version, and docs/DECISIONS.md D-038 to D-042 hold the choices. Spec dimensions are read from
src/shared/Config/Core.luau rather than copied, so the OpenMC model cannot drift from the Luau side.

Units: atom densities in atoms/(b·cm), lengths in cm, temperatures in K, mass densities in g/cm³.
Needs OpenMC (for atomic masses), so run it inside the kallskar-xs environment.
"""
import math
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import paths  # noqa: E402

N_A = 6.02214076e23
CONFIG = paths.REPO / "src" / "shared" / "Config"
NEA_TXT = paths.REPO / "references" / "nsc-r2015-9.txt"
CLAD_OUT = paths.REPO / "tools" / "derive" / "cladding_density.out.txt"


# --- Config (spec) values -------------------------------------------------------------------------------------------

def _luau(name: str) -> str:
    return (CONFIG / f"{name}.luau").read_text(encoding="utf-8")


def luau_number(name: str, key: str) -> float:
    """The one `key = <number>` (or `key = spec(<number>, …)`) in Config/<name>.luau; asserts it is unique."""
    found = re.findall(rf"\b{re.escape(key)}\s*=\s*(?:\w+\()?(-?[\d.]+(?:e-?\d+)?)\b", _luau(name))
    assert len(found) == 1, f"Config.{name}: expected one '{key}', found {found}"
    return float(found[0])


def core_rings() -> list[dict]:
    """Config.Core.rings as a list of dicts (ring, positions, kind, fuelZone?, fuel?)."""
    out = []
    for body in re.findall(r"\{\s*(ring\s*=\s*\d+[^{}]*)\}", _luau("Core")):
        entry = {}
        for k, v in re.findall(r"(\w+)\s*=\s*(\"[^\"]*\"|[\d.]+)", body):
            entry[k] = v.strip('"') if v.startswith('"') else int(v)
        out.append(entry)
    assert [e["ring"] for e in out] == list(range(17)), "Config.Core.rings must list rings 0–16 in order"
    return out


def rod_layout() -> list[dict]:
    """Config.Core.rodLayout: [{set, ring, angles}]."""
    out = []
    for s, ring, angles in re.findall(r"\{\s*set\s*=\s*\"(\w+)\",\s*ring\s*=\s*(\d+),\s*angles_deg\s*=\s*\{([^}]*)\}",
                                      _luau("Core")):
        out.append({"set": s, "ring": int(ring), "angles": [float(a) for a in angles.split(",")]})
    assert len(out) == 6, out
    return out


def pu_fraction() -> dict:
    m = re.search(r"plutoniumFraction\s*=\s*(?:\w+\()?\{\s*inner\s*=\s*([\d.]+),\s*outer\s*=\s*([\d.]+)\s*\}", _luau("Core"))
    assert m, "Config.Core.fuel.plutoniumFraction not found"
    # a D-051 search trial moves both zones by the same number of percentage points
    shift = float(os.environ.get("KALLSKAR_PU_SHIFT_PCT") or 0) / 100
    return {"inner": float(m.group(1)) + shift, "outer": float(m.group(2)) + shift}


def spec_geometry() -> dict:
    """§2.1 and §2.3 dimensions in cm (or as stated), straight from Config.Core."""
    mm = lambda key: luau_number("Core", key) / 10.0
    g = {
        "assemblyPitch": mm("assemblyPitch_mm"),
        "wrapperFlats": mm("wrapperAcrossFlats_mm"),
        "wrapperWall": mm("wrapperWall_mm"),
        "fissileHeight": mm("fissileHeight_mm"),
        "lowerReflector": mm("lowerReflector_mm"),
        "upperPlenum": mm("upperPlenum_mm"),
        "pins": int(luau_number("Core", "pinsPerAssembly")),
        "pinPitch": mm("pinPitch_mm"),
        "cladOD": mm("cladOuterDiameter_mm"),
        "cladWall": mm("cladWall_mm"),
        "pelletOD": mm("pelletOuterDiameter_mm"),
        "pelletHole": mm("pelletHoleDiameter_mm"),
        "pelletTD": luau_number("Core", "pelletDensity_fracTD"),
        "wireD": mm("wireDiameter_mm"),
        "wirePitch": mm("wirePitch_mm"),
        "heavyMetal_t": luau_number("Core", "heavyMetal_t"),
        "totalPins": int(luau_number("Core", "totalPins")),
        "puFraction": pu_fraction(),
    }
    g["cladID"] = g["cladOD"] - 2 * g["cladWall"]
    g["wrapperInnerFlats"] = g["wrapperFlats"] - 2 * g["wrapperWall"]
    # a hexagonal bundle with rings 0..n holds 1 + 3n(n+1) pins
    g["pinRings"] = next(n for n in range(30) if 1 + 3 * n * (n + 1) == g["pins"])
    return g


def temperatures() -> dict:
    """Reference temperatures (K) from Config: §9.2 core inlet, §2.4 fuel-assembly outlet, file 20 fuel average."""
    t_in = luau_number("Program", "coreInlet_C") + 273.15
    t_out = luau_number("Core", "assemblyOutletAverage_C") + 273.15
    return {
        "coreInlet": t_in,
        "fuelAssemblyOutlet": t_out,
        # D-039: the sodium in the fuel assemblies, 375 → 559 °C. §3.2's power defect implies it: its sodium term,
        # +0.40 pcm/K × (T − 648 K) = +37 pcm, needs T ≈ 740.5 K, and (375 + 559)/2 °C is 740.15 K
        "coolantMean": 0.5 * (t_in + t_out),
        "fuelAverage": luau_number("Feedback", "fullPowerFuelAverage_K"),
        "hotZeroPower": luau_number("Feedback", "referenceTemperature_K"),
        "refuelling": 230.0 + 273.15,                                 # §3.3 "Required excess reactivity, 230 °C"
    }


# --- Volume fractions of the fuel-assembly cell (derived from the spec geometry) -----------------------------------

def hex_area(flats: float) -> float:
    return math.sqrt(3) / 2 * flats * flats


def wire_length_factor(g: dict) -> float:
    """Helix length per unit of axial length: the wire's centre runs on a circle of diameter (clad OD + wire D)."""
    return math.hypot(1.0, math.pi * (g["cladOD"] + g["wireD"]) / g["wirePitch"])


def smeared_clad_od(g: dict) -> float:
    """Cladding OD with the wire's volume added to it (NEA/NSC/R(2015)9 Table 2.4 note a, the MOX-3600 fuel pin; D-040)."""
    wire = math.pi / 4 * g["wireD"] ** 2 * wire_length_factor(g)
    return math.sqrt(g["cladOD"] ** 2 + 4 * wire / math.pi)


def cell_fractions(g: dict) -> dict:
    """Fractions of one hexagonal cell (assembly pitch), for the fuel, lower-reflector and plenum sections."""
    cell = hex_area(g["assemblyPitch"])
    n = g["pins"]
    circle = lambda d: math.pi / 4 * d * d
    wrapper = hex_area(g["wrapperFlats"]) - hex_area(g["wrapperInnerFlats"])
    between = cell - hex_area(g["wrapperFlats"])
    inside = hex_area(g["wrapperInnerFlats"])
    clad = n * (circle(g["cladOD"]) - circle(g["cladID"]))
    wire = n * circle(g["wireD"]) * wire_length_factor(g)
    pin_envelope = n * circle(g["cladOD"]) + wire
    sodium = (inside - pin_envelope) + between
    f = lambda a: a / cell
    fuel = {
        "pellet": f(n * (circle(g["pelletOD"]) - circle(g["pelletHole"]))),
        "hole": f(n * circle(g["pelletHole"])),
        "gap": f(n * (circle(g["cladID"]) - circle(g["pelletOD"]))),
        "clad": f(clad), "wire": f(wire), "wrapper": f(wrapper), "sodium": f(sodium),
    }
    lower = {  # D-040: the cladding holds EM10 slugs of the pellet's outer diameter
        "slug": f(n * circle(g["pelletOD"])),
        "gap": fuel["gap"], "clad": fuel["clad"], "wire": fuel["wire"], "wrapper": fuel["wrapper"],
        "sodium": fuel["sodium"],
    }
    plenum = {
        "gas": f(n * circle(g["cladID"])),
        "clad": fuel["clad"], "wire": fuel["wire"], "wrapper": fuel["wrapper"], "sodium": fuel["sodium"],
    }
    follower = {"wrapper": fuel["wrapper"], "sodium": 1.0 - fuel["wrapper"]}  # D-041: an empty duct
    for name, parts in (("fuel", fuel), ("lower", lower), ("plenum", plenum), ("follower", follower)):
        assert abs(sum(parts.values()) - 1.0) < 1e-12, (name, sum(parts.values()))
    return {"fuel": fuel, "lower": lower, "plenum": plenum, "follower": follower, "cell_cm2": cell}


# --- Compositions ---------------------------------------------------------------------------------------------------

# NEA/NSC/R(2015)9 Table 2.11: MOX-3600 inner-core fuel pin, BOC, midplane zone (40.22–60.33 cm), atoms/(b·cm).
# Only the isotopic vectors are used (D-012, D-038); the magnitudes are the benchmark's, not K1's.
NEA_T211_MIDPLANE = {
    "U234": 1.6555e-06, "U235": 2.9137e-05, "U236": 4.7679e-06, "U238": 1.8322e-02,
    "Pu238": 8.6992e-05, "Pu239": 1.8845e-03, "Pu240": 1.0108e-03, "Pu241": 2.0474e-04, "Pu242": 3.1762e-04,
}
# Table 2.13: EM10 (ferritic-martensitic duct steel) and sodium, atoms/(b·cm), at the benchmark's nominal state
NEA_EM10 = {"C": 3.8254e-04, "Si": 4.9089e-04, "Ti": 1.9203e-05, "Cr": 7.5122e-03, "Fe": 7.3230e-02,
            "Ni": 3.9162e-04, "Mo": 4.7925e-04, "Mn": 4.1817e-04}
# Table 2.14: B4C of the primary (PSS) and secondary control rods, atoms/(b·cm)
NEA_B4C_PRIMARY = {"C": 2.70e-02, "B10": 2.32e-02, "B11": 8.49e-02}
NEA_B4C_SECONDARY = {"C": 2.70e-02, "B10": 9.81e-02, "B11": 9.91e-03}
# Table 2.8, oxide core: control subassembly volume fractions (structure is EM10)
NEA_ROD_FRACTIONS = {
    "primary": {"b4c": 0.2524, "sodium": 0.5683, "em10": 0.1793},
    "secondary": {"b4c": 0.2196, "sodium": 0.6552, "em10": 0.1252},
}

# JRC105589 Table 1, TASTE 15-15Ti tube, wt % (docs/K1_MATERIALS.md). Entries reported as "< x" are left out
# (tools/derive/cladding_density.py shows they move the density by < 0.01 %); Fe is the balance.
TASTE_WT = {"C": 0.096, "Si": 0.57, "Mn": 1.86, "Cr": 15.06, "Mo": 1.21, "Ni": 15.05, "Ti": 0.44, "B": 0.0031,
            "P": 0.013, "Co": 0.02, "N": 0.011, "V": 0.034}

# Carbajo et al., ORNL/TM-2000/351 §3.3: ρ(273 K) = 10,970 + 490·y kg/m³, y the PuO2 mole fraction (±1 %)
MOX_TD_273 = (10970.0, 490.0)


def clad_density() -> float:
    """g/cm³, from tools/derive/cladding_density.out.txt (the derivation's own output, not a copy)."""
    m = re.search(r"CLAD_DENSITY_KGPM3 = ([\d.]+)", CLAD_OUT.read_text(encoding="utf-8"))
    assert m, f"{CLAD_OUT} has no CLAD_DENSITY_KGPM3 line; run tools/derive/cladding_density.py"
    return float(m.group(1)) / 1000.0


def clad_weight_percent() -> dict:
    wt = dict(TASTE_WT)
    wt["Fe"] = 100.0 - sum(wt.values())
    return wt


def sodium_density(T: float) -> float:
    """g/cm³, spec Appendix A (Config.Sodium): ρ = a + b(1 − T/Tc) + c(1 − T/Tc)^0.5 kg/m³."""
    m = re.search(r"density\s*=\s*spec\(\{\s*a\s*=\s*([\d.]+),\s*b\s*=\s*([\d.]+),\s*c\s*=\s*([\d.]+),"
                  r"\s*criticalTemperature_K\s*=\s*([\d.]+)", _luau("Sodium"))
    assert m, "Config.Sodium.density not found"
    a, b, c, tc = (float(v) for v in m.groups())
    x = 1.0 - T / tc
    return (a + b * x + c * math.sqrt(x)) / 1000.0


def sodium(T: float) -> dict:
    from openmc.data import atomic_mass
    return {"Na23": sodium_density(T) * N_A / atomic_mass("Na23") * 1e-24}


def _vector(prefix: str) -> dict:
    v = {k: x for k, x in NEA_T211_MIDPLANE.items() if k.startswith(prefix)}
    s = sum(v.values())
    return {k: x / s for k, x in v.items()}


def fresh_mox(pu_mass_fraction: float, td_fraction: float) -> tuple[dict, dict]:
    """
    As-fabricated (U,Pu)O2 at 273 K (D-038, D-039): NEA isotopic vectors, O/M = 2 (§2.3's formula), density
    td_fraction × Carbajo's theoretical density. Returns (atoms/(b·cm) by nuclide, facts).
    """
    from openmc.data import atomic_mass
    u, pu = _vector("U"), _vector("Pu")
    a_u = sum(f * atomic_mass(k) for k, f in u.items())      # atom-fraction-weighted molar masses
    a_pu = sum(f * atomic_mass(k) for k, f in pu.items())
    a_o = atomic_mass("O16") * 0.99757 + atomic_mass("O17") * 0.00038 + atomic_mass("O18") * 0.00205  # IUPAC abundances
    w = pu_mass_fraction
    y = (w / a_pu) / (w / a_pu + (1 - w) / a_u)                # PuO2 mole fraction = Pu atom fraction of the metal
    td = (MOX_TD_273[0] + MOX_TD_273[1] * y) / 1000.0
    rho = td_fraction * td
    m_oxide = (1 - y) * a_u + y * a_pu + 2 * a_o
    n_metal = rho * N_A / m_oxide * 1e-24
    dens = {k: (1 - y) * n_metal * f for k, f in u.items()}
    dens.update({k: y * n_metal * f for k, f in pu.items()})
    dens["O"] = 2.0 * n_metal                                   # natural oxygen, added as an element
    facts = {"puAtomFraction": y, "TD_gpcm3": td, "density_gpcm3": rho, "metalAtoms_pbcm": n_metal,
             "heavyMetal_gpcm3": n_metal * 1e24 / N_A * ((1 - y) * a_u + y * a_pu)}
    return dens, facts


def parse_nea_checks() -> list[str]:
    """Re-read the NEA tables from references/ and confirm the transcriptions above. Returns failure messages."""
    text = NEA_TXT.read_text(encoding="utf-8")
    fails = []
    t211 = text[text.index("Table 2.11. Number densities of inner core fuel pin"):]
    t211 = t211[:t211.index("Table 2.12")]
    for nuc, val in NEA_T211_MIDPLANE.items():
        sym, mass = re.match(r"([A-Z][a-z]?)(\d+)", nuc).groups()
        m = re.search(rf"^\s*{mass}{sym}\s+((?:\d\.\d{{4}}E[-+]\d\d\s+){{4}}\d\.\d{{4}}E[-+]\d\d)", t211, re.M)
        if not m or abs(float(m.group(1).split()[2]) - val) > 1e-12:
            fails.append(f"Table 2.11 {nuc}: transcribed {val}, report {m.group(1).split()[2] if m else 'not found'}")
    t213 = text[text.index("Table 2.13. Structure and coolant"):]
    t213 = t213[:t213.index("Table 2.14")]
    for el, val in NEA_EM10.items():
        m = re.search(rf"^\s*{el}\s+(\d\.\d{{4}}E[-+]\d\d)", t213, re.M)
        if not m or abs(float(m.group(1)) - val) > 1e-12:
            fails.append(f"Table 2.13 EM10 {el}: transcribed {val}, report {m.group(1) if m else 'not found'}")
    t214 = text[text.index("Table 2.14. Absorber material"):]
    t214 = t214[:600]
    for label, key in (("C", "C"), ("10B", "B10"), ("11B", "B11")):
        m = re.search(rf"^\s*{label}\s+(\d\.\d\dE[-+]\d\d)\s+(\d\.\d\dE[-+]\d\d)", t214, re.M)
        got = (float(m.group(1)), float(m.group(2))) if m else None
        if got != (NEA_B4C_PRIMARY[key], NEA_B4C_SECONDARY[key]):
            fails.append(f"Table 2.14 {key}: transcribed {(NEA_B4C_PRIMARY[key], NEA_B4C_SECONDARY[key])}, report {got}")
    t28 = text[text.index("Table 2.8. Volume fraction of primary and secondary"):][:600]
    for label, key in (("B4C", "b4c"), ("Coolant", "sodium"), (r"Structure \(EM10\)", "em10")):
        m = re.search(rf"{label}\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)", t28)
        got = (float(m.group(2)) / 100, float(m.group(4)) / 100) if m else None  # oxide columns
        want = (NEA_ROD_FRACTIONS["primary"][key], NEA_ROD_FRACTIONS["secondary"][key])
        if not got or any(abs(a - b) > 1e-9 for a, b in zip(got, want)):
            fails.append(f"Table 2.8 {key}: transcribed {want}, report {got}")
    return fails
