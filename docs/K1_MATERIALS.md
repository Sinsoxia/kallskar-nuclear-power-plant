# K1 material compositions for the cross-section model

Every material the OpenMC model needs, with its source. The spec (§2.1–§2.3) gives dimensions and names the
materials, but not their compositions. Each composition is therefore cited from a published source, derived from
spec data, or set by a recorded decision (docs/DECISIONS.md, D-038 to D-042). §3.7 itself names the OECD/NEA sodium
fast reactor benchmark's large oxide core as "a realistic starting point", so the NEA MOX-3600 core is the first
source wherever it has the material.

The model that uses all of this is `tools/xsgen/k1_model.py`, with the numbers in `tools/xsgen/k1_materials.py`.
That module reads every spec dimension from `src/shared/Config/Core.luau` instead of copying it. Its `--check`
re-reads the NEA tables from `references/` to confirm each transcription.

References (in `references/`, git-ignored, third-party, except where noted):
- `nsc-r2015-9.*`: OECD/NEA, *Benchmark for Neutronic Analysis of Sodium-cooled Fast Reactor Cores*,
  NEA/NSC/R(2015)9.
- `jrc105589-15-15ti.*`: European Commission JRC, *Determination of high temperature material properties of
  15-15Ti steel*, JRC105589 (open access).
- `iaea-te-1978.*`: IAEA, *Structural Materials for Heavy Liquid Metal Cooled Fast Reactors*, TECDOC-1978 (open
  access).
- `tm2000-351.*`: Carbajo et al., ORNL/TM-2000/351, the MOX fuel property review.
- Not in `references/`: P. Pichler, B. J. Simonds, J. W. Sowards, G. Pottlacher, "Measurements of thermophysical
  properties of solid and liquid NIST SRM 316L stainless steel", *J. Mater. Sci.* 55 (2020) 4081–4093,
  doi:10.1007/s10853-019-04261-6. There is an open copy on tsapps.nist.gov (pub_id 928362). It has not been copied
  into the repo; that needs Aqua's OK.

## Reference state (D-039)

The spec's dimensions are read as **as-fabricated**. Solids take their room-temperature densities, and sodium takes
its density at the operating temperature. Nuclear data are evaluated at the operating temperatures:

| State | Fuel | Coolant and structure | Used for |
|---|---|---|---|
| Full power (nominal) | 1,380 K (file 20, `Feedback.fullPowerFuelAverage_K`) | 740.15 K, the mean of the 375 °C inlet and §2.4's 559 °C fuel-assembly outlet (the temperature §3.2's +37 pcm sodium term implies) | the reference cross sections |
| Hot zero power | 648 K | 648 K | the feedback reference (`Feedback.referenceTemperature_K`) |
| Refuelling | 503.15 K | 503.15 K | §3.3's excess reactivity at 230 °C |

The spec supports this reading. As fabricated, the pellets hold **29.11 tHM** against §2.3's "≈ 29". If the
dimensions were instead the hot ones at 1,380 K, the pellets would hold 28.1 t, because Carbajo's expansion gives
+3.5 % in volume. Thermal expansion is therefore not in the cross sections. §3.7's expansion feedbacks carry it, relative to this reference state.

Four cited materials are the exception, entering at their benchmark's operating-state densities because that is how
the sources give them:
- EM10: the wrapper, the lower-reflector slugs, the rod structure and the follower duct.
- The NEA B₄C of both rod systems.
- MOX-1000's HT-9 and natural B₄C: rings 11–14 and 16.
How far each sits from room temperature is not quantified, since no cited expansion data for them is at hand (D-039).

## Fuel: fresh (U,Pu)O₂ (D-012, D-038)

| Quantity | Value | Source |
|---|---|---|
| Pu isotopics (at. %) | 238: 2.48, 239: 53.77, 240: 28.84, 241: 5.84, 242: 9.06 | NEA Table 2.11, inner-core midplane zone (D-012) |
| U isotopics (at. %) | 234: 0.009, 235: 0.159, 236: 0.026, 238: 99.806 | the same column (D-038) |
| Pu content | 18 % inner, 23 % outer, **by mass of heavy metal** | §2.3 (the basis is D-038) |
| O/M | 2.00 | §2.3's formula, (U,Pu)O₂ |
| Density | 95 % of TD(273 K) = 10,970 + 490·y kg/m³, y = PuO₂ mole fraction (±1 %) | §2.3; Carbajo §3.3 |
| Result | inner 10.505 g/cm³ (y = 0.1790), outer 10.528 g/cm³ (y = 0.2288) | `k1_materials.fresh_mox` |

Both vectors are **irradiated**, not a fabrication feed. Table 2.11 is the equilibrium core's batch-averaged
composition at BOC, and its own axial profile shows which way irradiation moves each vector:
- **Uranium:** U-235 is burnt down (0.159 % of the uranium at the midplane, 0.178–0.189 % at the core ends) and U-236
  builds up (0.026 % against 0.019–0.022 %).
- **Plutonium:** goes the other way, because U-238 breeds Pu-239 in a fast spectrum. The more irradiated midplane
  has 53.8 % Pu-239 against 52.1–52.3 % at the ends, with Pu-238/240/241/242 all lower. A feed was therefore
  probably poorer still.
The report gives no feed vector, so these stand in for one (D-012, D-038). The Pu side dominates, so the fresh
model fuel is, if anything, slightly **more** reactive than a real feed of the same Pu content.

The model's fresh fuel holds U and Pu only. The Am, Cm, Np and fission products in the same NEA column are left
out, and D-012's depletion to the equilibrium four-batch core generates its own. Am-241 from Pu-241 decay during
storage before loading is not modelled.

## Cladding and wire: 15-15Ti (DIN 1.4970) (D-040)

Spec §2.3 says "15-15Ti austenitic steel, OD 8.50 mm, wall 0.56 mm" and gives no composition.

JRC105589 Table 1 gives three columns: the classical 1.4970 specification, SCK·CEN's requirements, and the measured
analysis of the TASTE tube. The **measured tube** is used, because it is a real cladding tube and its analysis is
complete, including the boron and nitrogen that the specification ranges leave open:

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
| Fe | balance (65.63) | balance |

Cross-check: IAEA TECDOC-1978 §2.1 reports an independent 15-15Ti (1.4970) heat from SCK·CEN: 15.95 Cr, 15.40 Ni,
1.20 Mo, 1.49 Mn, 0.52 Si, 0.44 Ti, 0.1 C, balance Fe.
- **TASTE tube:** inside the classical 1.4970 ranges except Si (0.57 against 0.3–0.5).
- **IAEA heat:** outside the 1.4970 ranges in Si (0.52) and in Mn (1.49 against 1.6–2.0). It is inside
  SCK·CEN's Si and Mn requirements (0.5–0.7 and 1.0–2.0) but above its Cr requirement (15.95 against 14.5–15.5).
The two heats differ by 0.89 wt % Cr and 0.37 wt % Mn. So the cross-check shows the TASTE analysis is a plausible
15-15Ti, not that heats agree closely.

Boron matters only because of ¹⁰B. At 31 ppm total boron, natural abundance gives about 6 ppm ¹⁰B in the cladding.
Its (n,α) cross section follows 1/v, σ ≈ 3,840 b × √(0.0253 eV / E): 6 b at 10 keV and 1.9 b at 100 keV, so a few
barns in a fast spectrum. The effect is small next to the steel's own capture, but it is in the model rather than
assumed away.

**Density: 7,888 kg/m³ ± 1 %** (`tools/derive/cladding_density.py`, 3/3 checks). Neither source gives one, so it
is derived from a measured austenitic steel of certified composition, NIST SRM 1155a (316L). Pichler et al. 2020
measured that steel at (7,904 ± 25) kg/m³ at room temperature. The two steels are taken to have the same density of
face-centred-cubic lattice sites, and the ratio of their masses per site gives the density. C, N, B and O sit in
the interstices, so they add mass but no sites. The ±1 % is an allowance for the lattice-parameter difference that
method leaves out. No source at hand gives that difference, so the ±1 % is not derived.
`k1_model.py --case clad-density` measures what +1 % does to k rather than assuming it is small. The "< x"
entries are left out; at their limits they move the density by less than 0.01 %.

**Wire:** §2.3 gives a 1.2 mm helical wire on a 200 mm pitch but names no material. It is taken as the cladding
steel (D-040). Its volume is smeared into the cladding by raising the cladding OD (the convention of NEA
Table 2.4 note a, for the MOX-3600 fuel pin), which gives 8.585 mm. The helix is 1.2 % longer than its
axial run, so the wire holds 1.12 % of the cell.

## Wrapper: EM10 (D-040)

§2.3 says only "ferritic-martensitic steel". NEA Table 2.13 gives EM10, the ferritic-martensitic duct steel of the
MOX-3600 core. It is a direct, citable match for the same duty. Atom densities, as given (b⁻¹·cm⁻¹): C 3.8254e-4,
Si 4.9089e-4, Ti 1.9203e-5, Cr 7.5122e-3, Fe 7.3230e-2, Ni 3.9162e-4, Mo 4.7925e-4, Mn 4.1817e-4.

These are at the benchmark's operating state, not room temperature, which departs from D-039. EM10 fills the
wrapper, the lower-reflector slugs, the rod structure and the follower duct. How far its density sits from room
temperature is not quantified here, and the model uses the numbers as the benchmark gives them.

## Lower steel reflector and plenum (D-040)

- **Lower reflector (300 mm):** §2.1 says "lower steel reflector 300 mm". This follows NEA Table 2.5's axial
  reflector, where the fuel column is replaced by EM10 inside the same cladding. In K1, the cladding holds EM10
  slugs of the pellet's 7.28 mm outer diameter.
- **Plenum (1,100 mm):** the cladding, wire and wrapper continue. The gas inside is void, as in both NEA cores.
  The plenum spring is not modelled.

## Rods (D-041)

| Rod set | System | Absorber | Assembly fractions |
|---|---|---|---|
| RR, shim A/B/C | PSS | NEA primary B₄C: C 2.70e-2, ¹⁰B 2.32e-2, ¹¹B 8.49e-2 | NEA Table 2.8 oxide primary: B₄C 25.24 %, Na 56.83 %, EM10 17.93 % |
| SSR | SSS | NEA secondary B₄C: C 2.70e-2, ¹⁰B 9.81e-2, ¹¹B 9.91e-3 | NEA Table 2.8 oxide secondary: B₄C 21.96 %, Na 65.52 %, EM10 12.52 % |

- **Absorber length:** 1,000 mm. §3.4's worth curve is defined over the 1,000 mm active height. Fully out at
  §0.1's 1,100 mm, the absorber's top reaches the top of the modelled plenum: 1,100 + 1,000 = 2,100 mm, §2.1's fuel
  plus plenum. That leaves 100 mm of follower between the fuel and the absorber.
- **Follower:** an empty duct. It is K1's own wrapper (9.47 %) filled with sodium, as in MOX-1000's withdrawn-rod
  duct.
- **Below the core:** the fuel assemblies' lower reflector. The NEA 1000 MWt cores (§2.1.2) give every assembly
  type the driver's lower structure and reflector, and `Systems/Core/Mesh` does the same.
- **"All rods out":** every tip at 1,100 mm, which is §0.1's full stroke and the SSR's park position.

## Ex-core rings (D-042)

| Ring | §2.2 | Model | Source |
|---|---|---|---|
| 11–12 | steel reflector | 84.5 % HT-9, 15.5 % Na | NEA MOX-1000 radial reflector (Tables 2.21, 2.28) |
| 13–14 | B₄C shield | 53.22 % natural B₄C, 29.68 % HT-9, 17.1 % Na | NEA MOX-1000 radial shield |
| 15 | in-vessel storage | fresh outer-zone fuel in all 90 positions, at the coolant temperature (it makes no power); discharged fuel in the BOC core | a bound on its effect; the `storage-empty` case measures it |
| 16 | steel shield | as the steel reflector | – |
| outside | – | vacuum beyond ring 16 and beyond the §2.1 lengths | the `axial-reflective` case bounds the axial ends |

The MOX-1000 fractions are fractions of the cell, so they carry over to K1's 179 mm cell unchanged. The sodium in
them is K1's own, at K1's temperature.

## Sodium

Spec Appendix A (Config.Sodium): ρ = 219 + 275.32(1 − T/Tc) + 511.58(1 − T/Tc)^0.5 kg/m³, Tc = 2,503.7 K.
That gives 842.3 kg/m³ at 467.0 °C, 863.5 at 375 °C and 896.3 at 230 °C.

## Volume fractions of the 179 mm fuel cell (277.48 cm²)

| Section | Pellet / slug | Hole | Gap | Cladding | Wire | Wrapper | Sodium | Gas |
|---|---|---|---|---|---|---|---|---|
| Fuel (1,000 mm) | 37.58 | 3.07 | 1.12 | 13.64 | 1.12 | 9.47 | 34.00 | – |
| Lower reflector (300 mm) | 40.65 (EM10) | – | 1.12 | 13.64 | 1.12 | 9.47 | 34.00 | – |
| Plenum (1,100 mm) | – | – | – | 13.64 | 1.12 | 9.47 | 34.00 | 41.78 |

Hole, gap and gas are void. `k1_model.py --check` confirms that the outer pin row clears the wrapper by 2.15 mm,
enough for the 1.2 mm wire. It also confirms that 271 × 301 = 81,571 pins, matching §2.3.

## Open

- **Primary B₄C enrichment:** NEA Table 2.14's primary set is 21.5 % ¹⁰B, although Table 2.6 calls it "natural".
  Natural boron is 19.9 % ¹⁰B (IUPAC's representative isotopic composition), and the MOX-1000 shield's "natural"
  set is 19.1 %. The numbers are used as printed.
- **No outage decay at BOC:** the equilibrium core uses end-of-cycle compositions directly (D-044). §3.1's
  Np-239 → Pu-239 gain (+30 pcm) waits on F34, the outage length.
- **Homogeneous rods overestimate worth.** NEA §5.6 finds homogeneous rod models 10–17 % above heterogeneous ones.
  K1 has no rod pin design to model heterogeneously. Keep this in mind when the §3.7 bank worths (±10 %) are
  compared.
- **Mesh upper layers at rod positions:** `Systems/Core/Mesh` gives rod positions' upper layers the upperPlenum set.
  The physical model has the withdrawn absorber there. If the rod worth near full withdrawal needs it, the collapse
  can supply an "absorber in plenum" set.
