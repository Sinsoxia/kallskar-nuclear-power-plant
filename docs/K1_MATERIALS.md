# K1 material compositions for the cross-section model

Every material the OpenMC model needs, with its source. The spec (§2.1–§2.3) gives dimensions and names the
materials, but not their compositions, so each one is either cited from a published source or derived from spec data.
Nothing here is invented; anything still missing is listed under "Open" and blocks only the part of the model that
needs it.

References live in `references/` (git-ignored, third-party):
- `nsc-r2015-9.*` — OECD/NEA, *Benchmark for Neutronic Analysis of Sodium-cooled Fast Reactor Cores*, NEA/NSC/R(2015)9.
- `jrc105589-15-15ti.*` — European Commission JRC, *Determination of high temperature material properties of 15-15Ti
  steel*, JRC105589 (open access).
- `iaea-te-1978.*` — IAEA, *Structural Materials for Heavy Liquid Metal Cooled Fast Reactors*, TECDOC-1978 (open access).
- `tm2000-351.*` — Carbajo et al., ORNL/TM-2000/351 (fuel thermal properties; used by `tools/derive/pin_thermal.py`).

## Cladding: 15-15Ti (DIN 1.4970 / AIM1)

Spec §2.3 says "15-15Ti austenitic steel, OD 8.50 mm, wall 0.56 mm" and gives no composition.

JRC105589 Table 1 gives three columns: the classical 1.4970 specification, SCK·CEN's requirements, and the measured
analysis of the TASTE tube. The **measured tube** is used, because it is a real cladding tube and is complete
(including boron and nitrogen, which the specification ranges leave open):

| Element | TASTE tube (wt %) | 1.4970 specification (wt %) |
|---|---|---|
| C | 0.096 | 0.08–0.12 |
| Si | 0.57 | 0.3–0.5 |
| Mn | 1.86 | 1.6–2.0 |
| Cr | 15.06 | 15.0–16.0 |
| Mo | 1.21 | 1.05–1.25 |
| Ni | 15.05 | 14.5–15.5 |
| Ti | 0.44 | 0.35–0.55 |
| B | 0.0031 | 0.003–0.006 |
| P | 0.013 | ≤ 0.03 |
| S | < 0.001 | ≤ 0.015 |
| Co | 0.02 | – |
| N | 0.011 | – |
| V | 0.034 | – |
| Ta, Cu, Ca | < 0.02, < 0.05, < 0.03 | – |
| Fe | balance (≈ 65.6) | balance |

Cross-check: IAEA TECDOC-1978 §2.1 reports an independent 15-15Ti (1.4970) heat from SCK·CEN as 15.95 Cr, 15.40 Ni,
1.20 Mo, 1.49 Mn, 0.52 Si, 0.44 Ti, 0.1 C, balance Fe. Element by element that agrees with the TASTE tube inside
normal heat-to-heat variation, and both sit inside the 1.4970 ranges except Si, which runs high in both (0.52–0.57
against a 0.3–0.5 specification, and inside SCK·CEN's own 0.5–0.7 requirement).

Boron matters only because of ¹⁰B: at 31 ppm total boron, natural abundance gives ≈ 6 ppm ¹⁰B in the cladding. In a
fast spectrum its absorption cross section is a few tenths of a barn rather than the thermal 3,840 b, so the effect is
small — but it is in the model rather than assumed away.

**Open:** the density of 15-15Ti at operating temperature. Neither source gives one, and the number is needed to turn
weight percent into atom densities. Options, in order of preference: (a) find a cited density and thermal-expansion
correlation for 1.4970; (b) derive it from the measured composition by atomic-volume mixing and state the ±1 %
uncertainty. Until one is chosen, the cladding cannot be written into `XSData`.

## Still to source

| Material | Where it is used | Status |
|---|---|---|
| MOX fuel, Pu vector and U isotopics | inner (18 % Pu) and outer (23 % Pu) zones, §2.3 | D-012 proposes the NEA MOX-3600 BOC vector (Tables 2.11–2.12). Open question there: equilibrium composition with minor actinides and lumped fission products, or fresh MOX plus depletion |
| Wrapper, ferritic-martensitic steel | §2.3 names the class only | NEA Table 2.13 gives EM10, the ferritic-martensitic wrapper steel of the MOX-3600 benchmark — a direct, citable match for the same duty |
| Absorber, B₄C | §3.4 rod sets | NEA Table 2.14 gives natural B₄C (primary) and 90 % ¹⁰B (secondary) for the same rod design; §3.4 does not state K1's enrichment, so which set each K1 rod bank uses is a decision to record |
| Radial reflector, steel shield, in-vessel storage | §2.2 ring kinds | NEA MOX-1000 gives a reflector (84.5 % HT-9, 15.5 % Na) and a shield (natural B₄C + HT-9 + Na) for the same function; K1's own fractions are not specified |
| Sodium | everywhere | Spec Appendix A (already in `Config.Sodium`, implemented in `shared/Props/Sodium`) |
