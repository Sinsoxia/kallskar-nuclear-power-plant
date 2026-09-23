"""
15-15Ti (DIN 1.4970) cladding density, from a measured austenitic steel and the two certified compositions.

The spec names the cladding (§2.3: "15-15Ti austenitic steel") and docs/K1_MATERIALS.md has its measured composition
(JRC105589 Table 1, the TASTE tube), but no source at hand gives its density, and the OpenMC model needs one to turn
weight percent into atom densities.

Method. Both 15-15Ti and 316L are austenitic stainless steels: face-centred cubic solid solutions of Fe, Cr, Ni and
Mo on one lattice, with C, N and B in the interstices. If the two have the same density of lattice sites, each
steel's density is that site density times the mass carried per site, and the ratio of the two needs only their
compositions:

    ρ_x / ρ_ref = Σ_sub,ref (wᵢ / Aᵢ) / Σ_sub,x (wᵢ / Aᵢ)

where the sums run over the substitutional elements (moles of lattice sites per gram) and the interstitials add mass
but no sites. The reference is NIST SRM 1155a (316L), whose density is measured and whose composition is certified,
both in one paper:
  P. Pichler, B. J. Simonds, J. W. Sowards, G. Pottlacher, "Measurements of thermophysical properties of solid and
  liquid NIST SRM 316L stainless steel", J. Mater. Sci. 55 (2020) 4081–4093, doi:10.1007/s10853-019-04261-6:
  Table 1 (certified mass fractions of SRM 1155a) and the room-temperature density (7904 ± 25) kg/m³.

What the method leaves out is the difference between the two steels' lattice parameters: 316L carries 2.2 % Mo and
17.8 % Cr against 15-15Ti's 1.2 % and 15.1 %. No source at hand gives the lattice parameters, so that difference
is not derived. The ±1 % quoted is an allowance for it, not a derived bound. For that reason the K1 model measures
what +1 % on the cladding density does to k (tools/xsgen/k1_model.py --case clad-density) instead of assuming it is
negligible.

Atomic weights: IUPAC standard atomic weights (abridged, 2021).
Run: python tools/derive/cladding_density.py
"""
import sys

sys.stdout.reconfigure(encoding="utf-8")  # the output has ρ, ±, … (a default Windows console is cp1252)

# IUPAC 2021 abridged standard atomic weights
A = {
    "Fe": 55.845, "Cr": 51.996, "Ni": 58.693, "Mo": 95.95, "Mn": 54.938, "Si": 28.085, "Ti": 47.867,
    "Co": 58.933, "Cu": 63.546, "V": 50.942, "W": 183.84, "Nb": 92.906, "P": 30.974, "S": 32.06, "Ta": 180.95,
    "Ca": 40.078, "C": 12.011, "N": 14.007, "B": 10.81, "O": 15.999,
}
INTERSTITIAL = {"C", "N", "B", "O"}  # in the octahedral interstices of austenite, or bound in inclusions: mass only

# Pichler et al. 2020, Table 1: certified mass fractions of SRM 1155a (%)
SRM_1155A = {
    "C": 0.0260, "Co": 0.225, "Cr": 17.803, "Cu": 0.2431, "Fe": 64.71, "Mn": 1.593, "Mo": 2.188, "Nb": 0.0082,
    "Ni": 12.471, "P": 0.0271, "Si": 0.521, "Ti": 0.0039, "V": 0.0725, "W": 0.0809, "O": 0.003,
}
RHO_SRM = 7904.0  # kg/m³ at room temperature, Pichler et al. 2020
RHO_SRM_U = 25.0

# JRC105589 Table 1, TASTE tube (docs/K1_MATERIALS.md). Entries given as "< x" are listed separately.
TASTE = {
    "C": 0.096, "Si": 0.57, "Mn": 1.86, "Cr": 15.06, "Mo": 1.21, "Ni": 15.05, "Ti": 0.44, "B": 0.0031, "P": 0.013,
    "Co": 0.02, "N": 0.011, "V": 0.034,
}
TASTE_BELOW = {"S": 0.001, "Ta": 0.02, "Cu": 0.05, "Ca": 0.03}  # reported as "< x"


def with_balance(comp):
    """Fe is the balance of the listed elements."""
    out = dict(comp)
    out["Fe"] = 100.0 - sum(v for k, v in comp.items() if k != "Fe")
    return out


def sites_per_gram(comp):
    """Moles of substitutional lattice sites per gram of steel (mass fractions in %)."""
    return sum(w / 100.0 / A[el] for el, w in comp.items() if el not in INTERSTITIAL)


checks = []


def check(label, ok):
    checks.append(ok)
    print(f"  [{'ok' if ok else 'FAIL'}] {label}")


print("15-15Ti density from NIST SRM 1155a (316L), equal lattice-site density")
srm_total = sum(SRM_1155A.values())
print(f"  SRM 1155a: certified fractions sum to {srm_total:.3f} %; used as certified (Fe is measured, not balance)")
check("the certified SRM 1155a fractions account for the whole sample to within 0.1 %", abs(srm_total - 100) < 0.1)

s_ref = sites_per_gram(SRM_1155A) / (srm_total / 100.0)  # renormalise the tiny remainder
taste_lo = with_balance(TASTE)                            # "< x" entries at zero
taste_hi = with_balance({**TASTE, **TASTE_BELOW})         # "< x" entries at their bound
print(f"  15-15Ti (TASTE): Fe by balance {taste_lo['Fe']:.3f} % (below-limit entries at zero) "
      f"or {taste_hi['Fe']:.3f} % (at their limits)")

rho_lo = RHO_SRM * s_ref / sites_per_gram(taste_lo)
rho_hi = RHO_SRM * s_ref / sites_per_gram(taste_hi)
rho = 0.5 * (rho_lo + rho_hi)
print(f"  mass per lattice site: SRM {1 / s_ref:.4f} g/mol, 15-15Ti {1 / sites_per_gram(taste_lo):.4f} g/mol")
print(f"  ρ(15-15Ti, room temperature) = {rho_lo:.1f} (below-limit at zero) … {rho_hi:.1f} (at limits) kg/m³")
print(f"  adopted: {rho:.0f} kg/m³ ± 1 % (an allowance for the lattice difference, not derived), "
      f"± {RHO_SRM_U / RHO_SRM * 100:.2f} % from the SRM measurement")
check("the below-limit entries move the result by far less than the ±1 % allowance", abs(rho_hi - rho_lo) / rho < 1e-3)
check("the result is an austenitic-steel density: within 2 % of the measured 316L it is scaled from",
      abs(rho / RHO_SRM - 1) < 0.02)

# atom density of the cladding for the OpenMC model, atoms/(b·cm)
N_A = 6.02214076e23
per_bcm = {}
comp = taste_lo
for el, w in comp.items():
    per_bcm[el] = rho * 1e-3 * (w / 100.0) / A[el] * N_A * 1e-24
total = sum(per_bcm.values())
print(f"  total atom density {total:.5e} atoms/(b·cm) at {rho:.0f} kg/m³")

print()
print("Config-ready (Python, tools/xsgen/k1_materials.py)")
print(f"CLAD_DENSITY_KGPM3 = {rho:.1f}  # tools/derive/cladding_density.py, ±1 %")
print()
print(f"{sum(checks)}/{len(checks)} checks pass")
raise SystemExit(0 if all(checks) else 1)
