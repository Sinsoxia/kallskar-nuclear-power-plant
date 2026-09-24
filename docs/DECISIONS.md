# Design decisions log

Config values with `decision("D-xxx")` provenance point here. Every entry records **what** was decided, **why**, the
spec text it rests on, and its **status**. "Proposed" entries were made by Claude to unblock M1 and are waiting for
Aqua's review; Aqua can overrule any of them, and the spec wins wherever it is explicit.

Status key: **Proposed** (awaiting Aqua) · **Accepted** (Aqua confirmed) · **Superseded**.

**All entries below were resolved on 21 Sep 2026** — see `docs/FINAL_DECISIONS_REV_A5.md` for the final choice and
reasoning on each one. Every proposal was accepted; six carry a refinement, noted in the heading. Rev A5 of the spec
applies the document changes those refinements asked for (`tools/derive/apply_rev_a5.py`).

---

## D-001 Three-colour SOR on the hex-Z mesh (finding F1) — Accepted
**Spec:** §14.2 says the inner solver is "red-black successive over-relaxation".
**Problem:** a hexagonal tiling cannot be 2-coloured. Any three hexes meeting at a corner are mutually adjacent (a
triangle), so a red-black ordering always puts two neighbours in the same colour and the sweep stops being a proper
Gauss-Seidel/SOR ordering.
**Decision:** colour each node `(c + k) mod 3`, where `c ∈ {0,1,2}` is the standard 3-colouring of the hexagonal
lattice (axial coordinates `(q − r) mod 3`) and `k` is the axial layer. Same-layer neighbours differ in `c`; axial
neighbours differ in `k` by one. Both change the colour, so the colouring is proper (proof in `tests/Mesh.spec.luau`).
Same per-sweep cost and the same "all nodes of one colour are independent" property the spec wanted.

## D-002 Finite-difference kernel with D̂ face corrections (finding F2) — Accepted
**Spec:** §3.7 "hexagonal-Z nodal diffusion", "one node per hexagonal position".
**Problem:** one mesh-centred node per 179 mm hex is coarse finite difference; plain FD shifts the power shape by a
few percent in a large fast core.
**Decision:** FD kernel with a per-face current-coupling correction D̂ (CMFD-style), default 0. D̂ comes from OpenMC
partial currents (`tools/xsgen/dhat.py`). Fallback: equivalence factors from OpenMC supercells. Never fitted to the
§3.7 targets without asking Aqua first.

## D-003 Auto controllers track the §9.2 part-load program (finding F3) — Accepted
**Spec:** §9.4 rod auto "holds core outlet 550 ±2 K"; primary flow auto "holds P/Q at 1.00".
**Problem:** below 40 %FP the §9.2 program itself lowers core outlet and P/Q (flow floor 40%). Fixed setpoints would
fight the program.
**Decision:** both autos take their setpoint from the §9.2 program at the current power. Above 40 %FP this is exactly
550 °C and P/Q = 1.00, as specified.

## D-004 Core-inlet-low trip gated by mode (finding F4) — Accepted with refinement (mode-based inhibits, Rev A5)
**Spec:** §9.5 core inlet trip low 345 °C; §9.1 Mode 4 is 200–350 °C.
**Problem:** an ordinary cooldown to Mode 4 crosses 345 °C and would raise a trip and first-out while the reactor is
already shut down, polluting the event log and the planned "was this trip justified" vote-kick check.
**Decision:** the core-inlet-low trip is bypassed while the plant is in Mode 3, 4 or 5 **and** every PSS rod is fully
inserted. All permissives the spec states explicitly (P/Q above 5 %FP, PR 25% setpoint below 10%) are unchanged.
**Refined on acceptance (Rev A5):** disabled in Modes 4 and 5 outright; disabled in Mode 3 with every PSS rod fully
inserted; disabled in Mode 2 below 350 °C during heatup; armed in Mode 1 and above 5 %FP. Every inhibit is
annunciated, so the crew can see the trip is not available. §9.5 now states this.

## D-005 PR high-flux voting is 2-out-of-4 (finding F5) — Accepted
**Spec:** §9.5 "PSS logic is 2-out-of-3"; §3.5 PR has 4 quadrant channels.
**Decision:** 2-of-4 for the four PR quadrant channels (the natural coincidence for four channels), 2-of-3 for every
other three-channel parameter.

## D-006 Regulating rods move one at a time (finding F6) — Accepted
**Spec:** §3.4 interlock "only one rod or one bank moves at a time"; the RRs are not a bank.
**Consequence reported to Aqua:** at 3.0 pcm/EFPD and the ×360 slow clock, burnup drift is 0.75 pcm per real minute.
One RR from mid-band (550 mm) to the band edge is ≈ 25 pcm ≈ 33 min, not the ≈ 20 min in §10.5. The ×360 clock is a
† tuning value; changing it is Aqua's call.

## D-007 Part-load flow program is continuous between 5 and 10 %FP (finding F10) — Accepted
**Spec:** §9.2 table rows 5% (flow 25%) and 10% (flow 40%); file 20 computes `Q = max(P, 40) if P >= 10 else 25`.
**Problem:** that rule steps flow from 25% to 40% at exactly 10 %FP, which makes core outlet jump from ≈ 445 °C to
419 °C. A real flow program does not step.
**Decision:** flow is 25% up to 5 %FP, rises linearly to 40% at 10 %FP, then follows `max(P, 40)`. Both tabulated rows
(5% and 10%) are reproduced exactly; only the undefined interval between them changes.

## D-008 Hazard is a rate (finding F8) — Accepted
**Spec:** §12.1 λ = 0.002·e^(6U) per grid day, "about 80% at U = 1".
**Decision:** λ is a hazard rate; per-step failure probability is `1 − exp(−λ·Δt)`. At U = 1, λ = 0.807/day means a
55% chance of failing within one grid day. The spec's "80%" reads the rate as a probability; the formula is kept.

## D-009 Frequency response comes from turbine valves (finding F9) — Accepted
**Spec:** §8.4 FCR-N ±10 MWe per unit, 63% within 60 s; LCO-10 ramp ≤ 1 %/min.
**Decision:** FCR is delivered by turbine control valves on stored energy; frequency response is exempt from LCO-10,
which governs deliberate load changes.

## D-010 Rod set placement within rings (derived, see tools/derive/rod_layout.py) — Accepted
**Spec:** §2.2 "space each rod set evenly so it is 3-fold symmetric, and offset bank B by 30° from bank A so they
don't shadow each other"; RR at 0°, 120°, 240°.
**Derivation:** ring 3 has no position at an exact 30° angle, so the spec's exact 30° A→B offset forces bank A onto the
ring-3 corners (0° + 60°k) and bank B onto ring-6 mid-edges (30° + 60°k). The spec leaves the SSR (rings 4, 7) and
bank C (ring 8) angles open; the script applies the spec's own anti-shadowing rule, maximising the angular separation
from rod sets in the adjacent rings: SSR ring 4 at 30° + 120°k, SSR ring 7 at 0° + 60°k, bank C at 30° + 60°k.

## D-012 MOX plutonium isotopic vector from the OECD/NEA MOX-3600 benchmark — Accepted with implementation choice (equilibrium four-batch core from fresh-MOX depletion)
**Spec:** §2.3 gives Pu/(U+Pu) ≈ 18% inner, ≈ 23% outer, but no Pu isotopics or uranium composition. §3.7 names the
OECD/NEA SFR benchmark's large oxide core as "a realistic starting point".
**Decision:** take the Pu isotopic vector from NSC/R(2015)9 Tables 2.11–2.12 (MOX-3600 BOC). At the inner-core
midplane: Pu-238 2.5%, Pu-239 53.8%, Pu-240 28.8%, Pu-241 5.8%, Pu-242 9.1%. The K1 Pu fractions stay as the spec
gives them; if the 3D model's excess reactivity then misses §3.3 (2,250 ± 150 pcm), the Pu fraction is adjusted within
the spec's "≈" by a documented search script, and the result is reported to Aqua.
**Resolved on acceptance (Rev A5):** neither a fully fresh core nor a pasted equilibrium composition. Deplete the
fresh MOX vector to generate burnup-dependent cross sections, then initialise the canonical BOC core as an
equilibrium four-batch core at roughly 0 / 13 / 25 / 38 GWd/tHM, discharging near 51 GWd/tHM. K1 is a 38-year-old
plant, so an equilibrium core is the realistic state, but the simulator still needs the depletion path for burnup
feedback. Minor actinides and lumped fission products are included if practical; if they are too heavy for M1 they are
excluded as a stated simplification and the reactivity shift is reported.

## D-013 Assembly flow factors vs the hottest-outlet figure (finding F11) — Accepted as interim (recalibrate from the OpenMC power map)
**Spec:** §2.5 orifice zones f = 1.12 / 1.00 / 0.92 and `T_out = T_in + 183.7 × (p/f) × (P/Q)`; §2.4 hottest assembly
outlet 580–585 °C.
**Problem:** spec file 20 computed the 580–585 °C figure with f = 1.08 (inner hot assembly) and f = 0.925 (outer), not
the §2.5 table values. With the §2.5 factors, a radial-peak assembly (p = 1.20) in zone II would read ≈ 595 °C; in zone
I ≈ 572 °C. The real hottest outlet will come from the 3D power map.
**Proposal:** keep §2.5 as written for M1. Once OpenMC power shapes exist, check the hottest outlet; if it falls outside
580–585 °C, re-derive the orifice factors from the computed power map (how real orifice zoning is designed) and ask
Aqua before changing them.

## D-014 IQS shape step is a normalised (power-iteration) solve with a lagged delayed-source map — Accepted
**Spec:** §14.2 "One implicit time step of the multigroup diffusion equations over the whole mesh, renormalised so
shape and amplitude stay consistent"; outer loop "usually 2–3 passes with a warm start"; Λ = 4 × 10⁻⁷ s (§3.1).
**Problem:** with Λ this small, the time-derivative term (1/v)/Δt is ~10⁻⁷ of the removal term, so the shape
equation is effectively [A − (1−β)χF]ψ = (delayed source). Solved literally as a fixed-source problem, its iteration
converges at rate (1−β)·k ≈ 0.996, i.e. thousands of passes, not the 2–3 the spec expects. Only a normalised
iteration (power iteration, converging at the dominance ratio) reaches 10⁻⁴ in a few warm-started passes.
**Decision:** each shape step is a warm-started power iteration on the current cross sections, with the fission
source split into its prompt part (1−β)·S(ψ) and the actual delayed-emission distribution Σᵢ λᵢ cᵢ(r) from the
node precursors, rescaled to the same total magnitude. The spatial lag of the delayed neutrons — the thing IQS adds
over an adiabatic model — is kept. The magnitude, and the reactivity that drives power, come from the adjoint-weighted
point-kinetics parameters, exactly as in IQS. The (1/v) terms are dropped, with the order-of-magnitude reason above.
The §14.2 development check (uniform perturbation ⇒ 3D amplitude = point kinetics) still applies unchanged.

## D-015 Amplitude integrator treats n as linear over each step — Accepted
**Spec:** §14.2 snippet `s[i] = s[i]·e + beta[i]·n·(1 − e)`; `n = Σs / (BETA − rho)`.
**Problem:** the snippet holds n at its old value while integrating the precursors, which lags the delayed source
by one 0.1 s step (a period error of order dt/T, about 0.2% at T = 50 s).
**Decision:** the same prompt-jump form, with the precursor integral taken exactly for n varying linearly across the
step: sᵢ¹ = sᵢ⁰eᵢ + βᵢn⁰(1 − eᵢ − wᵢ) + βᵢn¹wᵢ, with wᵢ = (1 − eᵢ) − (1 − eᵢ − xᵢeᵢ)/xᵢ and xᵢ = λᵢdt. n¹ then follows
algebraically, n¹ = Σ[sᵢ⁰eᵢ + βᵢn⁰(1 − eᵢ − wᵢ)] / (β − ρ − Σβᵢwᵢ), which is still explicit, still unconditionally
exact at steady state, and has a period error of order (dt/T)². At dt = 0.1 s, Σβᵢwᵢ ≈ 10 pcm, so the denominator
stays positive for every ρ below the 0.9β prompt-jump limit.

## D-016 The "+300 pcm gives a period near 2.5 s" figure (finding F12) — Accepted
**Spec:** §3.4 "All three RR fully withdrawn from critical is +300 pcm, about $0.83, which gives a period near 2.5 s";
§3.1 delayed-neutron groups (βᵢ, λᵢ) and Λ = 4 × 10⁻⁷ s.
**Problem:** with the §3.1 constants, the inhour equation gives a period of about 0.46 s for +300 pcm (Λ changes
this by less than a millisecond). A 2.5 s period corresponds to about 211 pcm. `tests/KineticsSpec` computes both.
**Proposal:** the simulation follows the §3.1 physics, so a +300 pcm step really gives ~0.46 s. Nothing in M1 depends
on the 2.5 s figure; it only matters for how S-19 is described and for the trip-timing narrative. Aqua to decide
whether §3.4's sentence should say "≈ 0.5 s" or "+210 pcm".

## D-011 Kinetics uses β = Σβᵢ, not the rounded 360 pcm — Accepted
**Spec:** §3.1 β_eff = 360 pcm; the six group βᵢ sum to 360.3 pcm.
**Decision:** the amplitude equation's `BETA` is computed as Σβᵢ from the group table. Using the rounded 360 while the
groups sum to 360.3 would leave a "critical" reactor sitting at ρ = −0.3 pcm and drifting. Config keeps both numbers
with their spec provenance; the validation target (360 ± 5%) is unaffected.

## D-017 The §14.2 "uniform perturbation" check and the generation-time change (finding F13) — Accepted
**Spec:** §14.2 "For a uniform perturbation, the 3D amplitude must match the point-kinetics fallback"; §3.1 Λ.
**Problem:** in adjoint-weighted kinetics Λ = ⟨φ*, v⁻¹ψ⟩ / F, where F is the weighted fission production. A uniform
change on the *fission* side (νΣf × 1/(1 − ρ)) leaves the shape alone but raises F by the same factor, so Λ drops by
(1 − ρ). The prompt-jump precursor amplitudes sᵢ = λᵢΛCᵢ drop with it, and the exact 3D answer is point kinetics
started from sᵢ = (1 − ρ)βᵢn₀, about 5 × 10⁻⁴ below constant-Λ point kinetics at +50 pcm. A uniform change on the
*loss* side (D, Σr, Σs and the boundary γ all × (1 − ρ)) leaves both the shape and F unchanged, so constant-Λ point
kinetics is exact. The first IQS version kept sᵢ against the old F until the next shape step, which matched neither.
**Decision:** the IQS keeps sᵢ = λᵢ⟨C*, cᵢ⟩ / F_w on every tick by rescaling sᵢ by F_old / F_new whenever F_w moves,
which is the physics above and costs O(6). `tests/IQSSpec` runs the §14.2 check with a loss-side perturbation, which must
agree with constant-Λ point kinetics to the solver tolerance, and a fission-side one, which must agree with point
kinetics including the (1 − ρ) change. The point-kinetics fallback keeps constant Λ: rods and most feedback act
mainly on the loss side, and the error is O(ρ), below 1% for any sub-prompt-critical state.

## D-018 Fuel-pin thermal model fixed by the core-average fuel temperature (finding F14) — Accepted with spec update (Rev A5 carries the model's figures)
**Spec:** §3.2 fuel average ≈ 1,107 °C (file 20: 1,380 K) at 100 %; §2.4 cladding midwall hot spot ≈ 620 °C,
hot-pin centreline ≈ 1,950 °C at 42 kW/m, centreline melting above ≈ 60 kW/m; §3.2 Doppler lag 4 s.
**Problem:** the pin model needs a gap conductance and a cladding-to-sodium resistance, and no local cited source gives
them for this pin. With Carbajo et al.'s MOX conductivity (ORNL/TM-2000/351) and a power-independent gap, the four
spec figures cannot all be met: fixing the core average at 1,380 K gives a hot-pin centreline of 2,141 °C (+191 K;
still +150 K with Carbajo's +7 % conductivity), melting at 57.4 kW/m (spec ≈ 60) and a fuel time constant of 3.0–3.8 s
(spec 4 s). A real gap closes as the pellet heats, which a single constant cannot represent.
**Decision:** `tools/derive/pin_thermal.py` fixes the cladding-to-sodium resistance from the 620 °C hot spot (which also
keeps the spec's 30 K margin to the 650 °C alarm) and the gap resistance from the 1,380 K core average (which the
§3.2 power defect, Doppler −680 pcm, is computed from). The centreline, melting and lag figures are reported as checks,
not fitted. Consequence in play: the hot-pin centreline reads about 2,140 °C at 100 % instead of about 1,950 °C (no
alarm is attached to it), and centreline melting is reached at 57 kW/m peak (≈ 137 %FP) instead of ≈ 60 kW/m.
Aqua to decide whether §2.4's centreline figure should change, or whether a power-dependent gap model should be added
once a cited gap-conductance source is available.

## D-019 Cladding temperature is quasi-static — Accepted
**Spec:** §14.3 suggests fuel and cladding temperature states per layer (301 × 10 × 2).
**Problem:** the cladding's own time constant is its heat capacity times the parallel resistance to fuel and sodium.
With the derived resistances (gap 5.87, cladding-to-sodium 1.83 K per kW/m) and the heat capacity of any steel wall of
this size (≈ 55–60 J/(m·K), from a volumetric heat capacity near 4 MJ/(m³·K)), it is about 0.1 s — one fast tick. The
repository has no cited 15-15Ti property set yet, and the cladding's stored heat is under 3 % of the fuel's.
**Decision:** FuelThermal keeps one dynamic state per layer (fuel average) and computes the cladding midwall
algebraically from the current heat flow. The cladding temperature is still published per layer. A dynamic cladding
node can be added once a cited 15-15Ti heat capacity is in Config; nothing else changes.

## F15 Appendix A table entry (spec wording note) — Accepted (correlation is canonical)
The Appendix A table gives c_p = 1.286 kJ/(kg·K) at 950 °C; the Appendix A correlation gives 1.28547, which rounds to
1.285. Every other table entry matches the correlation to half its last digit. The correlation is used;
`tests/FuelThermalSpec` holds that one entry to a whole last digit.

---

# Findings from the external spec review (Rev A3), audited 2026-09-21

Eight reviewers read Rev A3; their notes are in `REACTOR SPEC/3A SPEC REVIEW/reactor spec review.txt`. Every numeric
claim was recomputed from the spec's own primitives by `tools/derive/spec_review_check.py`; the claim-by-claim
verdicts (including the ones where the reviewers were wrong and the spec is right) are in `docs/SPEC_REVIEW_AUDIT.md`.
F16–F29 are the confirmed ones. All are open questions for Aqua.

## F16 IHX inlet temperature (§4.3) — Accepted
1,782 kg/s from 545 → 375 °C carries **385.2 MWt** (Appendix A enthalpy), so six units remove 2,311 MWt against the
2,390 MWt the core and pumps put in — a 79 MWt shortfall. With the hot pool's own 550 °C the duty is 396.4 MWt and six
units give 2,378 MWt. LMTD is 38.0 K at 545 °C and 41.2 K at 550 °C against the stated "≈ 40 K"; UA is 10.1 and
9.6 MW/K against "≈ 10 MW/K". **Proposal:** change the IHX inlet to 550 °C, or state the 5 K hot-pool-to-IHX loss and
restate the rating. The 400 MWt per unit is then a rating with ~1 % margin, not the duty.

## F17 DRACS coping time (§4.5) — Accepted
"The pool rises 200 K in ≈ 5 h" comes from the spec's own file-20 calc, which integrates only the first term of the
§3.6 decay-heat formula. Integrating the formula as written (both terms) over the same 2,412 MJ/K pool (1,250 t sodium
+ 1,500 t steel) gives **6.60 h**. **Proposal:** say ≈ 6.5 h, which also moves S-16 at ×10 from ≈ 30 to ≈ 40 min.

## F18 Shim bank A vs the 4 pcm/s interlock (§3.4) — Accepted
W(d) = W_total(d − sin 2πd/2π) has peak differential worth 2·W_total per stroke. Bank A (6 × 400 pcm) at the 1 mm/s
bank speed peaks at **4.80 pcm/s**, above the stated 4 pcm/s interlock. Bank B 3.60, bank C 2.40, a single shim rod at
2 mm/s 1.60, the RR bank at 5 mm/s 3.00 — all inside it. **Proposal:** 0.8 mm/s for bank A, or state that the drive
controller limits commanded speed near mid-stroke.

## F19 Regulating band worth vs the reactivity budget (§3.3, §3.4) — Accepted
The 400–700 mm band is **163.5 pcm** on the spec's own S-curve, but §3.3 reserves 250 pcm for "RR band, load
following". A 250–750 mm band is 245.5 pcm. **Proposal:** widen the band to 250–750 mm, or reduce the reservation to
165 pcm.

## F20 Regulating band drift time (§10.5) — Accepted with correction (2.7 h)
3.0 pcm/EFPD at the ×360 slow clock is **0.75 pcm per real minute**. Mid-band to the edge of the 163 pcm band is
therefore **109 real minutes**, not the ≈ 20 min in §10.5 (164 min if the band is widened per F19). **Proposal:**
restate §10.5, or raise the burnup drift rate if 20 min is the intended pacing.

## F21 Secondary dump tank size (§5.1) — Accepted
400 t of sodium occupies 443 m³ at the 200 °C idle setpoint (98 % of the 450 m³ tank), 457 m³ at the 320 °C SG outlet
and **469 m³ at 420 °C**. A hot dump does not fit. **Proposal:** 500 m³, or state that the drain follows a cooldown to
the trace-heating setpoint.

## F22 Low part-load rows vs the turbine (§9.2, §7.1) — Accepted
The 10 % and 5 % rows are 86 and 42 MWe gross — below the 150 MWe minimum stable load **even on one turbine** — and
their main steam (408 and 401 °C) is below the 420 °C hot-reheat trip. The 20 % and 30 % rows are below the minimum if
both turbines are online. **Proposal:** state that below ~25 %FP the plant is on bypass/house load with the turbines
off, and give the bypass path for those rows.

## F23 Natural-circulation formula (§4.2) — Accepted
Q_nc ≈ 3.5 % × (P / 1 %FP)^⅓ gives **16.25 %** rated flow at 100 %FP. The intended form is (P / 100 %FP)^⅓, which
gives 3.5 % at full power and 0.75 % at 1 %FP. **Proposal:** fix the denominator.

## F24 Feed-pump motor rating (§7.6) — Accepted
§7.6 reads "2 × 55 % main feed pumps (12 MW motors on VFDs, 9.8 MW absorbed at 100 %)". The 9.8 MW is the **per-train**
figure: the spec's own file-20 calc prints "MFP power/train 9.8 MW" from the pump enthalpy rise, and an independent
hydraulic check (437.5 kg/s, a 16.5 MPa rise from the 1.0 MPa deaerator to 17.5 MPa, feedwater at ~887 kg/m³,
82 % pump efficiency) gives 9.9 MW of shaft power per train, 10.3 MW electrical at 96 % motor efficiency. (Corrected
2026-09-23, P-02 of `docs/audit/SPEC_AUDIT_UNBUILT.md`: this had used a ~14.5 MPa rise, and 9.1 MW.) Each of the two pumps therefore absorbs about **4.9 MW**, which cannot sit behind a 12 MW motor.
With that reading the listed major drives total **51.0 MWe** (feed 19.6, primary 10.3, secondary 6.2, circulating
water 14.8), leaving 14 MWe of the 65 MWe house load for condensate pumps, heater drains, sodium trace heating and
cold traps, HVAC, lighting and transformer losses — so the ≈ 65 MWe house load and ≈ 935 MWe net are consistent.
One reviewer read 9.8 MW per pump and concluded the house load was too low; that is refuted.
**Proposal:** reword to "2 × 55 % main feed pumps on VFDs; 9.8 MW absorbed per train at 100 % (≈ 4.9 MW per pump);
6 MW motors", and state the auxiliary balance in §1.1 so the reading cannot be mistaken again.

## F25 Amplitude update in §14.2 — Accepted
The §14.2 snippet uses the previous step's n in the precursor update. Measured growth-rate error at dt = 0.1 s:
**−3.4 % at 0.5β, −11.4 % at 0.8β, −21.7 % at 0.9β**. A fully implicit form (suggested by one reviewer) errs the other
way: +3.6 %, +15.3 %, +45.5 %. The linear-n integrator already implemented (D-015) gives +0.0 %, +0.4 %, +2.2 %.
**Proposal:** replace the snippet in §14.2 with the D-015 form.

## F26 Clock assignments (§0.2 vs §12.2, §12.4, §13.2) — Accepted
§0.2 puts "fuel failure hazard" on the ×360 slow clock, while §12.2 defines random failure per **grid day** and §12.4
leak doubling per **grid hour** (×12) — a 30× difference that would collapse S-01's 20–60 min response window. §13.2
also says S-16 takes "≈ 30 min with ×10", but §0.2 bars ×10 whenever P1/P2 alarms are active, which a blackout
guarantees. §12.2's creep law "per 100 h" does not say real or grid hours (12× either way). **Proposal:** bind all
degradation models to the grid clock, keep ×360 for burnup, impurity ingress and cold-trap loading only, and add the
blackout exemption for ×10 once the reactor is confirmed subcritical.

## F27 Secondary-over-primary pressure and the pump-trip transient (§4.3, §5.1, §9.5, LCO-7) — Accepted with idle-loop clarification (Rev A5)
§4.3 says the secondary stays ≥ 0.4 MPa above the primary; LCO-7 says ≥ 0.2 MPa. On an idle loop the secondary falls
to the 0.30 MPa buffer-tank cushion, which is close to the primary pressure at the IHX, so the LCO reads violated
unless its scope is "running loops" or the buffer tank sits at a stated elevation. Separately, a primary pump trip
with RB-2 running at 60 %/min peaks at **P/Q = 1.08** against the 1.12 trip while the flap valve is open, but flow
steps to 2/3 when the valve seats, which would put P/Q at ≈ 1.35 unless the surviving pumps ramp up. **Proposal:**
reconcile the two pressure limits, and state the check-valve seating condition and the surviving pumps' VFD response.

## F28 Linear-heat-rate basis (§2.4) — Accepted
27.7 kW/m is correct **because 95 % of fission energy is deposited in the pins** (the spec's file-20 calc uses that
split; the remaining 5 % heats coolant and structure). Two reviewers recomputed 29.2 kW/m by putting all 2,380 MWt in
the pins. **Proposal:** state the 95 % split in §2.4 next to the linear heat rate.

## F29 Canonical power and section duty (§1.1, §6) — Accepted
24 × 99.5 MWt = 2,388 MWt is the rounded section duty; the exact figure for core plus pump heat is 99.583 MWt per
section. **Proposal:** name §1.1 as the canonical thermal power, mark the section duty as derived and rounded, and
soften the "every number agrees with every other number" sentence.

## F30 Per-pump rated flow is a rounded third of the total (§4.2) — Resolved in code; not in the Rev A5 list
(found after the decision log was written, so it still needs Aqua's eye on the §4.2 wording)
§4.2 gives 3,565 kg/s per primary pump and 10,694 kg/s total, but 3 × 3,565 = 10,695. The total is the figure the
§1.1 heat balance produces (file 20: `mp = Pth/dh` → 10,694, `mp/3` → 3,564.67), so the per-pump number is the rounded
one. `PrimaryPumps` derives the per-pump rating as total/3 and keeps the loop total exactly on the heat balance;
§4.2's 3,565 is then correct to its own rounding. **Proposal:** print the per-pump figure as ≈ 3,565 kg/s, or state
3,564.7.

## F31 §4.1's level rises are pre-Rev-A4 (hot pool 545 °C) — Resolved in code; not in the Rev A5 list
(found while building `Pools`, after the decision log was written)
§4.1 states the mean sodium level rises **+0.26 m** from the 375 °C isothermal state to 100 %, and **+0.64 m** from
230 °C. Recomputing both from the Appendix A density correlation and the §4.1 inventory (620 t hot, 560 t cold, 70 t
core and diagrid, 140 m² of free surface) reproduces them **only with the hot pool at ≈ 546 °C**. That is the
pre-Rev-A4 IHX primary inlet of 545 °C, which Rev A4 replaced with **550 °C** because 545 carried only 385 MWt per
unit and left the primary 79 MWt short. At 550 °C the same calculation gives **0.266 m and 0.645 m**. The 90 m³ cover
gas swing survives the change (89.2 → 90.3 m³) because it is quoted to the nearest 10 m³.
`Pools` computes levels from the density correlation and the live pool temperatures, so it produces the Rev A5-
consistent figures; `tools/derive/pool_gas.py` checks both against §4.1 with a tolerance that spans the two hot-pool
temperatures, and prints the 545 °C values alongside. **Proposal:** restate §4.1 as +0.27 m and +0.65 m, or state the
hot-pool temperature the figures assume.

## D-020 Cover gas make-up and vent controller — Accepted (2026-09-24)
§4.4 gives the argon setpoint (0.120 MPa), the automatic band (0.115–0.125), the alarms (0.105 / 0.140), the trip
(0.160) and the floor the pumps need (0.102 MPa), but no valve capacity or control law: it says only that argon is
admitted on cooldown and vented to the decay tanks on heatup. **Decision:** whenever pressure leaves the auto band,
the controller moves the inventory back toward the setpoint as a first-order lag with **τ = 60 s**, and that same
authority is the manual valves' full-open rate.
**Why 60 s:** it is not a free parameter once the band is fixed. At the band edge the correction rate is
(n_set − n_edge)/τ ≈ **5.6 mol/s** (`tools/derive/pool_gas.py`). The duty it has to cover runs from **0.18 mol/s**,
which holds the setpoint while the pool changes at LCO-11's 1.5 K/min limit (a ×31 margin), up to **3.8 mol/s**, which
is the entire 90 m³ swing inside ten minutes — about as fast as the pools can physically move after a trip. A τ much
larger than 60 s would let a trip push the pressure out of the band; much smaller and the valves would chase
measurement noise. **Alternative rejected:** a fixed mol/s valve rating, which would have been a guess.

## D-021 Where the 70 t of core and diagrid sodium lives — Accepted (2026-09-24)
§4.1 splits the 1,250 t of primary sodium into 620 t hot pool, 560 t cold pool and **70 t in the core and diagrid**,
and prescribes mixing nodes for the two pools only. `FuelThermal` treats the coolant in the assemblies algebraically
(§14.3 allows it: the 0.19 s core transit is far shorter than any node's time constant), so no node carries that 70 t
directly. **Decision:** keep the spec's node structure as written, and use the 70 t only where it belongs — in the
sodium *volume*, which sets the levels and the cover gas space.
**What the model's heat capacity then is,** which the energy-conservation test in `tests/PoolsSpec.luau` measures
rather than assumes: the model is parameterised by *time constants*, so its inventory is their sum times the flow —
40 + 18 s of hot pool, 52 s of cold pool and the **8 s transport line between the IHX outlets and the pump inlets**,
which is 118 s, or **1,262 t at rated flow**. That is **0.95 % above §4.1's 1,250 t**, not 5.6 % below it as a count
of the pool nodes alone would suggest: the transport line (86 t) stands in for the core and diagrid sodium (70 t).
Note that using §4.1's rounded 58 s and 52 s rather than its masses is itself worth 1,176 t against 1,180 t.
**Why accept it:** folding the 70 t into the pool nodes instead would change §4.1's prescribed 58 s and 52 s mixing
times to 61 s and 55 s — overriding spec-given model parameters to chase a 1.2 % inventory difference. Note that the
transport line's contribution scales with flow (86 t at rated, 3 t at the natural-circulation floor), so on a station
blackout the model's inventory falls back to the 1,180 t of pools; the §4.5 coping calculation has its own
2,400 MJ/K "with internals" figure and does not use this model.

## D-022 IHX UA is held constant; the film coefficients' flow dependence is not modelled — Accepted (2026-09-24)
§4.3 gives one UA, 9.6 MW/K over about 2,000 m², so U ≈ 4,800 W/m²K — a sensible sodium-to-sodium overall
coefficient. **Decision:** the `IHX` system uses that UA at every flow, and gets its duty from ε-NTU, so the duty,
both outlet temperatures and the LMTD all follow from the live temperatures and flows rather than from §4.3's
396 MWt. `tools/derive/ihx.py` shows that reproduces every stated figure at the design point.
**What is not modelled:** in reality the two film coefficients fall with flow, so UA falls too. For liquid metals
that dependence is much weaker than for water — the tube-side Nusselt number is Nu = 4.82 + 0.0185·Pe^0.827
(Skupinski), whose conduction floor of 4.82 survives when the convective term collapses — but it is not zero.
Splitting the 4,800 W/m²K between shell film, tube wall and tube film needs tube count, diameter and wall
thickness, which §4.3 does not give, so any flow exponent here would be invented rather than derived.
**Consequence, stated rather than hidden:** at low flow the model transfers slightly more heat than the plant
would, so the primary outlet approaches the secondary inlet sooner than reality. That flatters natural circulation
and a station blackout, which is the wrong direction to be optimistic in. Revisit when the secondary and steam
generator milestone brings tube geometry; until then the error sits in a regime where the pool time constants
(28 minutes at the natural-circulation floor, D-021) dominate the response anyway.

## D-023 Scram inserts at a constant rate — Accepted (2026-09-24)
§3.4 gives one point on the scram curve for each system: 90 % inserted in ≤ 1.2 s (PSS) and ≤ 2.0 s (SSR). One
point does not define a curve. **Decision:** insert at a constant rate sized to hit exactly that point —
0.9 × 1,100 mm ÷ 1.2 s = **825 mm/s** for the PSS and **495 mm/s** for the SSR, so full travel takes 1.33 s and
2.22 s. A rod already part-way in arrives sooner, at the same rate.
**Why not something more shaped:** a real scram accelerates under gravity and then decelerates into a dashpot over
the last part of the stroke, which is why the specification quotes 90 % rather than 100 %. Reproducing that needs
the dashpot's entry point and damping constant, neither of which the spec gives, so any S-curve would be invented.
The constant rate is exact where the spec constrains it and honest about being a straight line where it does not.
**Consequence:** the model reaches full insertion slightly sooner than a dashpot-equipped drive would, by a margin
of order 0.1 s, against delayed-neutron time constants of seconds. Worth revisiting only if a scenario turns on the
last 10 % of rod travel.

## D-024 The plant boots in Mode 3, hot standby — Accepted (2026-09-24)
Something has to decide where the rods are when a server starts. **Decision:** every PSS rod fully inserted, the
nine SSRs parked at 1,100 mm and latched, which is §3.4's stated normal position for them and §9.1's Mode 3.
`FuelThermal` and `Pools` already boot isothermal at the §3.2 reference temperature of 375 °C with the pumps
running, so the whole plant starts as a coherent hot standby.
**Why not critical at power:** the shim positions that hold a critical core depend on burnup, temperature and the
3D solve, so picking them now would be a guess — and worse, it would hand players a running reactor they did not
start. Taking the plant from hot standby to power is the game. **Alternative if it proves tedious:** a scenario
preset that fast-forwards a startup, which belongs to the scenario director rather than to these systems.

## D-025 Neutron instrument noise, and the filters that follow from it — Accepted (2026-09-24)
The spec gives noise figures for thermocouples (§2.5: ±1 K, 3 s lag) but none for the neutron channels, while §9.5
votes 2-of-3 and 2-of-4 on them — which only means anything if the channels are independently noisy.

**Two of these numbers are choices; the rest are consequences.**

*Not choices.* The source range and the delayed-neutron detectors are pulse-counting channels, so their noise is
Poisson: σ/R = 1/√(Rτ), with no free parameter at all. At §3.5's own reference of 250 cps that is 4.5 % on a 2 s
ratemeter, and at 15 cps — the bare unmultiplied source — it is 18 %. `tests/DetectorsSpec.luau` measures 4.51 %
against the predicted 4.48 %. An approach to critical is jittery at the start and settles as the count rate climbs
because of arithmetic, not because anyone tuned it.

*Choices.* The wide range (Campbell-mode mean-square voltage) and power range (DC ionisation chamber current) are
analogue, so they need a fractional precision: **2 %** and **0.5 %**, representative of those instrument classes.

*Consequences.* Given those, the three filter time constants are the shortest that keep noise **5σ short of the
§9.5 setpoint it could otherwise fake** (`tools/derive/detectors.py`):
  - flux rate: **0.5 s** (needs ≥ 0.35 s). Unfiltered, 0.5 % noise differentiated over one 0.1 s tick is 7 %FP/s
    against a 10 %FP/s trip — the plant would trip on nothing.
  - period: **5 s** (needs ≥ 4.24 s against the 30 s rod block).
  - ratemeter: **2 s**, which gives the 1/M plot 4.5 % precision at the §3.5 reference rate.
Plus a decade of hysteresis under §3.5's 10⁻³ %FP source-range cut-off, so the HV cannot chatter at the threshold.

**Two consequences worth stating rather than discovering later.** First, with a 5 s filter the period channel is
the *slow* protection: a 0.47 s excursion e-folds faster than the filter settles, so §9.5's overpower and
flux-rate trips are what catch it — which is presumably why §9.5 carries all three. Second, σ of the apparent
period is 177 s, so a *sample* of it drifts lower the longer a session runs (3σ is 59 s, 4.5σ is 39 s, against a
30 s rod block). **Protection must require the period rod block to persist rather than act on a single sample.**
That is a note for the Protection system, not a reason to lengthen the filter, which would blunt the real trips.

## D-026 Where the protection system votes, and where it cannot yet — Accepted (2026-09-24)
§9.5's header says the PSS is 2-out-of-3 on independent channels, and every row of its table is written as though
three instruments exist. For the neutron channels they do: §3.5 gives three source range, three wide range, four
power range quadrants and six DNDs, so those vote — 2-of-4 on the power range (D-005, finding F5) and 2-of-3
elsewhere. The process signals are a different matter. M1 has one mixed core outlet temperature, one core inlet,
one cover gas pressure. **Decision:** every monitor declares its own vote, and a signal the plant has one of
declares **1-of-1** rather than pretending to be triplicated. Triplicating the process thermocouples is a later
refinement, and because the vote is per row it will be a config change rather than a rewrite.

**Three related rules, each of which a test caught rather than a review:**
- **An alarm is per channel, a trip is a vote.** One quadrant reading 117 %FP is what the annunciator exists for;
  an alarm that waited for two channels would hide the first instrument to fail. Only the trip takes the
  coincidence. Rod blocks follow the alarm, being mild and reversible — D-025's persistence, not the vote, is
  what keeps instrument noise out of them.
- **Counts are inclusive.** §9.5 says "1 lost: RB-2" and "2 lost: trip", so reaching the count is the condition.
  Comparing strictly meant one pump lost never started RB-2 at all.
- **Adjacency is not modelled.** §9.5 wants +45 K on two *adjacent* assembly thermocouples; adjacency needs the
  mesh neighbour map, so for now any two count. That trips a little more readily rather than a little less.

**The 25 %FP low setpoint** bypasses itself above the 10 %FP permissive and re-arms below it, because §9.5 calls
it a permissive rather than an operator action. A plant that required a deliberate bypass during every startup is
the other defensible reading; this one follows the spec's wording.

## D-027 The core outlet thermocouple, and who is allowed to read the sodium — Accepted (2026-09-24)
§2.5 gives the core outlet instruments **±1 K of noise and a 3 s lag**, and nothing had implemented them: every
system read the true sodium temperature. That matters more than it sounds. §9.4's rod auto is supposed to be
limited by "reacts after thermocouples move", and a controller acting on an instantaneous, noiseless signal is
simply not the controller §9.4 describes — its characteristic hunting comes entirely from that lag.

**Decision:** `Pools` publishes `pools.mixedCoreOutletMeasured_K`, the same sodium seen through a §2.5
thermocouple, and **everything outside Pools reads the instrument rather than the sodium**. Protection's
core-outlet trip and the SSS's diverse one now act on the measurement, which is what a protection channel
actually has, and it gives that trip a real 3 s sensor lag.
**The small assumption, stated:** §2.5 quotes those characteristics for the *assembly outlet* thermocouples. The
mixed core outlet is the same class of instrument in the hot pool, so it carries the same figures.
**Still ideal:** the 301 assembly outlet thermocouples themselves, which Protection's ASSY-DEV row votes on. Same
treatment, not yet applied.

## D-028 Rod auto sequences one rod, and holds it — Accepted (2026-09-24)
D-006 has rod auto move one regulating rod at a time, and finding F6 is why. On the 250–750 mm band, one rod
reaches the band edge from mid-band in about 55 minutes, against about 164 minutes for all three ganged. (Corrected
2026-09-23, P-01 of `docs/audit/SPEC_AUDIT_UNBUILT.md`: this sentence had the comparison backwards, with the old
400–700 mm band's figures.) That leaves the question of *which* rod, which the first
implementation answered every tick — take the most-inserted when withdrawing, the most-withdrawn when inserting,
so the three stay together. A test caught what that actually does: as soon as the chosen rod moves ahead of the
others it stops being the most-inserted, so the controller hops to the next one, every tick.
**Decision:** hold the selected rod until it reaches the band limit or the direction reverses, and apply the
keep-them-together rule when choosing a **new** rod. That is what a rod sequencer does, and it keeps the three
within roughly one band-crossing of each other without thrashing between them.

## D-029 §9.4's flow auto is safe inside LCO-10 and not outside it — Accepted (2026-09-24)
§9.4 gives primary flow auto a 10 s filter on power and says P/Q swings ±5 % on fast changes. Testing that
against an instantaneous power step is meaningless: the step drives P/Q to P_new/P_old and trips the plant, but
rods move at no more than 4 pcm/s (§3.4), so **power cannot step**. The rate limit on the rods is what keeps this
deliberately weak controller survivable, and the flow lags power by τ × rate, so the excursion is (P + τ·rate)/P.

Measured, at 60 %FP: **1.003** at LCO-10's 1 %/min, **1.008** at its approved 3 %/min, **1.067** at RB-1's
30 %/min — against §9.5's 1.05 rod block and 1.12 trip. So the weakness is invisible inside the operating limit
and bites immediately outside it, which makes LCO-10 the thing that keeps flow auto usable rather than a
formality. Worth knowing before someone "fixes" the filter.

## D-030 The startup source, sized by the instrument that has to see it — Accepted (2026-09-24)
Point kinetics needs an external source term or a shut-down core reads exactly zero power, which is both wrong and
useless: subcritical multiplication is what an approach to critical is flown on (§3.5). §3.5 gives no source
strength. **Decision:** size it so that a shut-down plant — every PSS rod in, at the §3.2 reference temperature —
sits at exactly the bottom of §3.5's wide-range span, 10⁻⁸ %FP. Subcritical multiplication then carries the
indication up the scale on its own as rods come out, and the source range reads §3.5's own 15/(1−k) throughout.
**Why that anchor:** both numbers in it are the spec's — the span bottom and the shutdown reactivity — and it
encodes a real design property: an instrument that reads zero in Mode 3 tells the crew nothing, so the source and
the instrument are specified against each other. **Alternative rejected:** a neutron source strength in n/s, which
would need a detector efficiency the spec does not give to connect to anything observable.

## D-031 Core is a facade, and it runs point kinetics until the cross sections exist — Accepted (2026-09-24)
The plan makes 3D multigroup IQS the plant physics and point kinetics "the spec-required fallback and the test
oracle". The cross sections come from Track X and do not exist yet. **Decision:** put a facade at `Systems/Core`
that publishes the `core.*` channels and runs the fallback inside, so the plant is operable now and the 3D path
replaces the innards later without a single channel changing.

Two consequences, both stated rather than discovered later:
- **Reactivity is absolute.** The oracle balances itself at whatever state it starts in, which is right for an
  oracle and wrong for a plant that boots deeply subcritical. The facade sets the external term from §3.3's
  budget instead: ρ = excess − rod worth + feedback, with the excess at the §3.2 reference being
  2,250 − 376 = 1,874 pcm. At the Mode 3 boot state that is −3,826 pcm, k = 0.963, and the source range reads
  407 cps — none of which is told to it.
- **The power shape is a placeholder with a known error.** Radially it is §2.5's flow zoning read backwards
  (zone factors exist to level the outlets, so an assembly's share of power is its flow factor), which gives a
  radial peak of **1.12** where §3.7's validation target is **1.20**. Axially it is the chopped cosine whose
  peak-to-average is §2.4's 1.22, the same shape `tools/derive/pin_thermal.py` used. The radial gap is a property
  of the fallback, and it closes when the 3D flux arrives.

## F32 §9.5's rod block is for a BANK move, and the word matters — Resolved in code
§9.5 lists "RR out of band during a bank move" among the rod withdrawal blocks. Implemented as "RR out of band
while anything is selected", it bricks the plant: D-024 boots the rods fully inserted at 0 mm, which is outside
the 250–750 mm band, so the block fires on the operator's first withdrawal — the very move that would clear it.
Every unit test passed, because each set up a plant whose regulating rods were already in band; only running all
nine systems together showed it. `RodDrives` now publishes `rods.selectionKind` so Protection can tell a bank
move from a single rod, which is what the spec actually says.

## D-032 The M1 heat sink takes its load, inside what the steam plant can give — Accepted (2026-09-24)
The plan's M1 boundary held every secondary loop at §4.3's full-load 320 °C and 1,556 kg/s per unit. Running the
plant showed what that means: at hot standby the IHXs pulled **570 MWt out of a core making nothing**, cooled the
pools 20 K in a minute, and left core-inlet-low armed against a falling inlet the moment the rods came out.
**Decision:** `Systems/IHX` stands in for the secondary loops, steam generators and turbines with one number, the
steam plant's load, and the steam plant takes that load:
- Each tick the cold leg is solved so the exchangers carry the load plus the pumps' heat.
- The cold leg stays between §9.2's programme cold leg for the load (the coldest the steam plant gives, 320 °C
  at full load) and 375 °C, the no-load programme and hot standby's own temperature. It never goes above the pool
  it faces, because a steam generator cannot heat sodium.
- Secondary flow follows §9.2's flow column, which the table's own heat balance gives (`tests/PartLoadSpec`).
- The load ramps at §7.1's 5 %/min, and at LCO-10's 1 %/min above 40 %.
- A reactor trip takes the load to zero at once, because the turbines trip with the reactor and §7.3's bypass
  holds the steam side.
- Per-loop overrides of inlet or flow stay available for driving inlet-temperature feedback and a lost loop by hand.

**Why take the load rather than pin a temperature:** see F33. It is also how a fast reactor is run. A heavier load
cools the cold leg, the inlet temperature coefficient adds reactivity, and power rises to meet it. At steady state
the reactor makes exactly the load, and rod auto trims the outlet to the programme. **Known simplification:** the
stand-in has no secondary inventory, so the cold leg steps where the real loops would take their transit time;
that arrives with them. **Alternatives rejected:** the fixed full-load boundary (above); pinning §9.2's cold leg
(F33); a temperature controller on the cold leg, which would need gains the spec does not give.

## F33 §9.2's secondary temperatures need a UA that falls with flow; §4.3's is held constant — Resolved (Aqua, 2026-09-24): §9.2's secondary column is indicative; D-032 keeps the reactor side exact
§9.2 holds the core inlet at 375 °C at every load and gives the secondary legs. Its 40–100 % rows repeat the
full-load temperatures at part duty, which needs **UA ∝ flow**. The implied UA is 0.401 of §4.3's at 40 % and
0.250 at 5 %FP (`tools/derive/heat_sink.py`). D-022 holds §4.3's UA constant. The two cannot both hold. If the cold
leg is pinned to the table, the core inlet settles 5.5–23 K below the programme at part load (−23 K at 40 %). The
M1 sink (D-032) instead holds the reactor's side of §9.2 exactly and lets its cold leg run 6–23 K warmer than the
table's column, on the side of the plant M1 does not model. **For Aqua:** either §9.2's secondary column is
indicative, or the IHX needs a flow-dependent UA (real sodium film coefficients fall with velocity, though far
less than in proportion). The answer decides what the real secondary loops aim at when they are built.

## D-033 Initial conditions seat every state, not only the rods — Accepted (2026-09-24)
Integration tests and the developer panel need a plant already at power. Placing only the rods is wrong in a way
the plant notices at once. With the fuel still at hot zero power, the power defect the rods were placed against
does not exist yet, and the core sees its absence as a reactivity step. At 20 %FP that is about 270 pcm, three
quarters of β. **Decision:** `Systems/InitialConditions` seats the whole plant in steady state. It sets the pumps
and the load to §9.2's point, the core at the power, the pools around 375 °C, the fuel settled exactly, the
feedback lags at equilibrium, and the rods (regulating mid-band, shims together) wherever ρ comes out zero,
found by bisecting RodDrives' own worth curve. The mode is then declared per §9.1. None of these numbers are its own.

## D-034 Rod auto's programme is indexed on the steam plant's load, not the reactor's power — Accepted (2026-09-24)
D-003 has rod auto hold §9.2's programme outlet, 375 + 175·P/Q. Computed from **measured** power, that fails on
the 40 % flow floor. There the setpoint rises with power exactly as fast as the outlet does, so the error collapses
to (inlet − 375 °C). Rod auto becomes an inlet controller acting through minutes of pool transport, and it
overshoots. The load-following test found it: a 20 → 25 % load step took the core to **34.9 %FP**, with 142 pcm
withdrawn. **Decision:** index the programme on the steam plant's load (`ihx.sinkLoad_pct`), keeping the actual
flow for Q. That is how real plants are built: a PWR's T_ref is programmed on turbine load, for the same reason.
It leaves rod auto a fast loop on the outlet, and the heat sink's energy balance holds power on the load. Above
40 % flow auto keeps P/Q at 1, so the setpoint is 550 °C either way and nothing changes there. With no steam
plant on the channels (a unit test of AutoControls alone), the programme falls back to the reactor's own power.

## D-035 A reactor trip drops rod auto to manual — Accepted (2026-09-24)
§9.4's rod auto stood down during a scram and resumed when the trip was reset. Running the plant showed what that
means. After a reset in hot standby, the outlet sits below the no-load setpoint, so rod auto began **withdrawing a
regulating rod from a shut-down core**. That is a startup, and it has to be the crew's decision. **Decision:** a
trip switches rod auto to manual (logged), and it stays there until someone puts it back in, as rod control does on
real plants. A runback is different: rod auto stands down during it and takes over again afterwards. Flow auto is
unaffected, because it only follows the §9.2 flow programme down to its floor.

## D-036 The plant boots with beginning-of-cycle decay heat: 1.23 %, 29 MW — Accepted (2026-09-24)
§14.6 returns the plant, at boot and on an owner reset, to "hot standby at beginning of cycle". Beginning of cycle
is the state after §2.3's refuelling outage, following a 160 EFPD cycle, which is also §3.6's own reference history.
§2.3 gives the outage as "Timed wait (OD-8), 30 min real", and §0.2 puts the physics on "×1 real time, always".
**Decision:** boot with 160 EFPD at full power followed by 30 min of shutdown: **1.228 % of rated, 29.2 MW**
(§3.6's 30 min row). It is the most literal reading, and it is the upper bound of the post-outage readings. The
reset lands in Mode 3 at 375 °C, not Mode 5 at 230 °C, so any heat-up time would only lengthen it. See F34 for the
alternatives.

## D-037 Decay heat is 22 exponential groups driven by fission power, and thermal = prompt + decay — Accepted (2026-09-24)
§3.6 gives decay heat after a trip from constant power. A plant needs it for any history. **Decision:**
`Systems/DecayHeat` carries the formula as 22 groups, dHᵢ/dt = λᵢ(Eᵢ·P − Hᵢ), fitted to its kernel
(0.0132·τ^−1.2) by non-negative least squares on a fixed 0.4-decade grid (`tools/derive/decay_heat.py`, 47/47
checks). After a trip from 160 EFPD the groups reproduce every §3.6 table entry to its printed precision (within
6·10⁻⁵ of the formula over 1 s–7 d). Every other history checked, 10 s to 640 EFPD, stays within 5.3·10⁻⁴,
including seven it was not fitted to.
- **Driver:** the fission power `core.power_pctFP`, which already contains the delayed-neutron tail. Nothing adds
  a second one (§3.6).
- **Energy:** Core's thermal power is n·rated·(1 − f_ref) + decay heat. f_ref = Σ Eᵢ(1 − e^(−λᵢ·160 EFPD)) = 9.28 %
  is the decay share of steady power on the reference history, so a seated plant makes exactly its rated heat. It is
  above §3.6's 6.35 % at 1 s because it includes the groups below 1 s, where the formula has no value.
- **Split of power channels:** `core.power_pctFP` stays the neutron power, which Detectors, Protection's P/Q and
  permissives, and flow auto read. `core.thermalPower_W` and `_pctFP` are the heat. The pins carry thermal power,
  so decay heat reaches the fuel, coolant and pools by the same path as fission heat. §4.2's natural circulation now
  reads thermal power: buoyancy comes from heat, and on the neutron power it collapsed within minutes of a trip.
- **Clock:** the physics clock (§0.2), exact update per tick, so ×10 acceleration speeds it with everything else.
- **Seat and persistence:** InitialConditions seats the groups on the reference history at the seated power. The
  inventory is saved per §14.6. Offline time is not aged.

## D-032 amendment — secondary flow follows the primary flow the pumps deliver
Before decay heat existed it did not matter that the stand-in ran secondary flow on the load's programme. With
decay heat, a trip with flow auto out left the secondary on its 25 % no-load flow against primary at 100 %. The
primary barely cooled across the exchangers, and the whole pool had to rise to shed the heat. **Decision:** each
loop's secondary flow is the primary flow's fraction of rated, times §4.3's 1,556 kg/s per unit. §9.2's table makes
the two equal at every row (`tests/PartLoadSpec`), so nothing changes on the programme. **Known simplification:** a
primary pump trip now slows the secondary too, which the real secondary pumps would not do. The real loops replace
this stand-in.

## F34 How long §2.3's refuelling outage lasts physically is not stated — Resolved (Aqua, 2026-09-24): the outage is 30 min of real time, so D-036's 1.23 % stands
"30 min real" is the player's timed wait (OD-8). What it stands for physically decides the decay heat at beginning of
cycle, and so at every boot and reset:
- ×1 physics (D-036): 1.23 %, 29 MW
- ×10 acceleration: 0.68 %, 16 MW
- ×12 grid clock: 0.65 %, 16 MW
- ×360 slow-process clock, the one burnup runs on: 7.5 d, 0.21 %, 5 MW
- a real weeks-long outage: about 0.1 %, 2.5 MW
**For Aqua:** choose one. It is a single Config number (`DecayHeat.boot.shutdown_s`).

## F35 Decay-heat history follows physics time, burnup follows the ×360 clock — Resolved (Aqua, 2026-09-24): decay heat follows physics time, as now
Long-lived groups fill over days of physics time. One real hour at a new power moves them only an hour's worth,
while burnup advances 15 EFPD in that same hour. The seat and the boot carry §3.6's full reference history, so
trips from a seated plant follow §3.6 exactly. A plant run for hours of real time at a new power carries a long
tail that still reflects its seated history. **For Aqua:** accept this, or have the slowest groups fill on the
slow-process clock (which makes their post-trip decay ambiguous).

## F36 The pool model has no steel heat capacity, so a pool with no sink heats 1.7× too fast — Resolved (Aqua, 2026-09-24): the internals are split between the pools in proportion to their sodium (D-057)
D-021 keeps only the sodium inventory: 1,262 t, which is 1,602 MJ/K at Appendix A's mean c_p over 375–575 °C.
§4.1 gives "sodium plus internals ≈ 2,400 MJ/K", and §4.5's coping time integrates into it.
`tools/derive/decay_heat.py` confirms the §3.6 curve delivers 477 GJ in 6.5 h, which is 2,386 MJ/K × 200 K. With
decay heat now in the plant and no sink (a station blackout, S-15, S-16), the model's pool would rise 200 K in
**3.8 h instead of 6.5 h** (the same integral, solved for 1,602 MJ/K). **To do before DRACS and the blackout
scenarios:** add the internals' heat capacity to the pools without changing §4.1's mixing times. Two related effects
remain unmodelled: §3.1's Np-239 +30 pcm over the week after shutdown, and §2.2 ring 15's stored assemblies, which
hold a quarter of the vessel's decay heat outside the pins.

## D-038 Fresh K1 MOX: NEA isotopics, Pu content by mass, stoichiometric, Carbajo's density — Accepted (2026-09-24)
§2.3 gives "(U,Pu)O₂, 95 % TD" with "≈ 18 %" and "≈ 23 %" Pu, and no isotopics. D-012 took the Pu vector from NEA
Table 2.11's inner-core midplane. **Decision:** (a) the uranium vector comes from the same column, all four isotopes
as printed. **Both vectors are irradiated.** Table 2.11 is the equilibrium core's batch-averaged BOC composition,
not a fabrication feed, and its axial profile shows the direction. The uranium is burnt: U-235 0.159 % of the
uranium at the midplane against 0.178–0.189 % at the core ends, U-236 0.026 % against 0.019–0.022 %. The Pu vector
goes the other way, because U-238 breeds Pu-239 in a fast spectrum: 53.8 % Pu-239 at the midplane against
52.1–52.3 % at the ends, so a feed was probably poorer. The NEA report gives no feed vector, so the BOC vectors
stand in for one. The Pu side dominates, so the fresh fuel is, if anything, slightly more reactive than a true feed
of the same Pu content, and D-043 then depletes it as if it were fresh. (b) §2.3's Pu content is **Pu/(U+Pu) by mass**, the convention fuel is specified in. The
mole fraction Carbajo's density needs follows from it: 17.90 % and 22.88 %. (c) O/M = 2.00, from §2.3's own formula.
(d) Density = 0.95 × (10,970 + 490·y) kg/m³ at 273 K (Carbajo et al. §3.3, ±1 %). The model's fuel starts with U
and Pu only. The Am, Cm, Np and fission products in the same NEA column are left out, and D-012's depletion
supplies its own.

## D-039 The cross sections' reference state is as-fabricated geometry at operating temperatures — Accepted (2026-09-24)
The spec gives dimensions without saying whether they are cold or hot. **Decision:** they are **as-fabricated**,
and solids keep their room-temperature densities. Sodium takes its Appendix A density at the state's temperature,
and nuclear data take the state's temperatures. At full power the fuel is at 1,380 K (file 20), and everything
else is at 740.15 K, the mean of the 375 °C inlet and §2.4's 559 °C fuel-assembly outlet. §3.2's own power defect
fixes that choice: its sodium term, +0.40 pcm/K × (T − 648 K) = +37 pcm, needs T ≈ 740.5 K. The 550 °C mixed outlet
would give +35. The spec's heavy-metal figure supports this: as fabricated, the pellets hold 29.11 t
against §2.3's "≈ 29", while read as 1,380 K dimensions they would hold 28.1 t. Thermal expansion therefore stays
out of the cross sections, and §3.7's expansion feedbacks apply it relative to this state. That reference has to be
matched when XSData is wired into the 3D model. **Exceptions:** four cited materials enter at their benchmark's
operating-state densities, because that is how the sources give them:
- EM10 (NEA Table 2.13): the wrapper (9.47 % of every fuel cell), the lower-reflector slugs (40.65 %), 17.93 % and
  12.52 % of the PSS and SSR cells, and the follower duct.
- The PSS and SSR B₄C (NEA Table 2.14).
- MOX-1000's HT-9 and natural B₄C (Table 2.21, given at 432.5 °C): rings 11–14 and 16.
How far each sits from room temperature is not quantified here, since no cited expansion data for these materials is
at hand. It is an open item for the XSData wiring.

## D-040 Cladding, wire, wrapper, lower reflector and plenum materials — Accepted (2026-09-24)
- **Cladding:** 15-15Ti per the measured JRC105589 TASTE tube, at 7,888 kg/m³ ± 1 %
  (`tools/derive/cladding_density.py`). That value scales the measured density of NIST SRM 1155a, 316L at
  7,904 ± 25 kg/m³ (Pichler et al. 2020), by mass per lattice site. The ±1 % is an allowance for the two steels'
  lattice difference, which no source at hand gives, not a derived bound; the `clad-density` case measures its
  effect on k.
- **Wire:** the cladding steel, which §2.3 does not name. It is smeared into the cladding as NEA Table 2.4 note (a)
  does for the MOX-3600 fuel pin (OD 8.585 mm).
- **Wrapper:** EM10 per NEA Table 2.13, the MOX-3600 core's ferritic-martensitic duct steel.
- **Lower steel reflector:** EM10 slugs of the pellet's outer diameter inside the cladding, following NEA
  Table 2.5's axial reflector.
- **Plenum:** gas as void, with no spring, as in both NEA cores.

## D-041 Rod assemblies: NEA MOX-3600 control assemblies, a 1,000 mm absorber over an empty duct — Accepted (2026-09-24)
§3.4 gives worths and speeds but no rod design. **Decision:**
- **PSS rods (RR and shim A/B/C):** NEA MOX-3600's primary control assembly, with Table 2.8's oxide fractions and
  Table 2.14's B₄C.
- **SSR:** the secondary assembly, 90.8 % ¹⁰B.
- **Rod model:** each rod is homogeneous over its cell. The absorber is 1,000 mm long, the height §3.4's worth curve
  is defined over. Fully out at §0.1's 1,100 mm, its top reaches the top of §2.1's plenum (1,100 + 1,000 =
  2,100 mm), leaving 100 mm of follower between the fuel and the absorber.
- **Follower:** an empty duct, meaning K1's wrapper filled with sodium, as MOX-1000 models a withdrawn rod.
- **Below the rod:** the fuel assemblies' lower reflector.

The §3.7 worths (±10 %) are validation targets this design is measured against, never fitted. NEA §5.6 finds that
homogeneous rods read 10–17 % high.

## D-042 Rings 11–16 and the model's outer boundaries — Accepted (2026-09-24)
- **Steel reflector (rings 11–12):** NEA MOX-1000's radial reflector, 84.5 % HT-9 and 15.5 % Na.
- **Steel shield (ring 16):** the same material as the steel reflector.
- **B₄C shield (rings 13–14):** MOX-1000's radial shield.
- **In-vessel storage (ring 15):** fresh outer-zone fuel in all 90 positions, at the coolant temperature because it
  makes no power. That bounds its effect, since the real store holds a quarter core of spent fuel. The
  `storage-empty` case measures it; behind two rings of B₄C it is expected to be small, but that is not assumed.
- **Boundaries:** vacuum beyond ring 16 and beyond §2.1's 300 mm reflector and 1,100 mm plenum, as in the NEA
  benchmarks. The `axial-reflective` case makes both axial ends reflective, which bounds what lies beyond.

## D-043 Burnup comes from single-assembly depletion at the core's specific power, in EFPD — Accepted (2026-09-24)
D-012 needs burnup-dependent fuel for the equilibrium four-batch core. **Decision:**
- **Model:** deplete one assembly of each zone as an infinite lattice of itself, using explicit pins at the
  full-power temperatures and the ENDF/B-VIII.1 chain `chain_endfb81_fast.xml` (`tools/xsgen/k1_deplete.py`). This
  is the standard lattice approach, and its known bias is a slightly softer spectrum than a leaking core's.
- **Power:** the specific power is Config's 2,380 MWt over the model's 29.11 tHM, 81.8 W/g, with
  **energy-deposition** normalisation. The flux is scaled so that the lattice's total `heating-local` tally equals
  that power. OpenMC's `heating-local` counts fission as fragments + prompt γ + delayed γ + delayed β, deposited
  locally, and adds every capture's γ energy: the same heat a thermal rating counts, decay energy included.
  (Amended after review: fission-q leaves out the capture energy and would have burnt the fuel a few percent faster
  than 2,380 MWt.)
- **Fission yields:** the chain's 500 keV sets, ENDF/B's fast-reactor yields. The chain also carries 0.0253 eV sets
  for U-235 and Pu-239/240/241, and OpenMC's default ("constant" at 0.0253 eV) would have used those for most of the
  fissions. (Amended after review.)
- **Batch points:** 0, 160, 320 and 480 EFPD at BOC and 640 at discharge, stepped in §2.3's 160 EFPD cycles.
  These land on step boundaries.
- **Steps:** at most 80 EFPD (6.5 GWd/t) with the CECM predictor-corrector. A fast MOX spectrum has no xenon,
  samarium or gadolinium to resolve. A coarse scheme checks this. Every coarse step is exactly two fine ones (fine:
  5, 5, 15, 15, 60, 60, then 80s; coarse: 10, 30, 120, then 160s), and CECM's error falls as Δt². So
  (fine − coarse) / 3 is the Richardson correction to the fine result, reported with its own σ
  (`k1_deplete.py --export`).
- **Statistics:** 5,000 particles × 25 active batches per transport. With about 230 nuclides in the fuel, OpenMC
  runs at about 800 particles/s instead of 14,000 for fresh fuel. Reaction rates summed over the whole bundle are
  still far more precise than k∞.
- **Output:** nuclides above NEA's own 10⁻¹⁰ cut-off are kept.
- **Step check (run 2026-09-24):** for the inner zone, the Richardson corrections to the fine k∞ are −53 to +32 pcm,
  each within its own σ of 75–89 pcm. The ten checked actinides move by at most 0.13 % (Cm-244), so the 80 EFPD
  steps are converged. The outer zone uses the same scheme; only the inner was double-run.

## F37 160 EFPD × 4 cycles at 2,380 MWt is 52.3 GWd/tHM, against §2.3's "≈ 51" — Resolved (Aqua, 2026-09-24): 52.3 GWd/tHM is what "≈ 51" means
On §2.3's own numbers, a cycle burns 160 × 2,380 / 29.11 = 13.08 GWd/t, so four cycles discharge at **52.3**. On
the round 29 t it would be 52.5. §2.3's "≈ 51" would need about 156 EFPD cycles or 29.9 tHM. D-043 follows power
and time, the quantities the plant runs on, so the equilibrium core's batches sit at 0 / 13.1 / 26.2 / 39.2 GWd/t.
**For Aqua:** accept 52.3 as what "≈ 51" means, or name which of the three inputs should move.

## D-044 The equilibrium core scatters its four batches on the 2 × 2 sublattice — Accepted (2026-09-24)
D-012's equilibrium BOC core needs a loading pattern, and the spec gives none. **Decision:**
- **Pattern:** each fuel position's batch (0 fresh, then 1, 2 or 3 cycles burnt) follows its colour
  (q mod 2) + 2·(r mod 2) in the mesh's axial coordinates, mapped 0→1, 1→0, 2→2, 3→3. Every assembly's six neighbours are then two of each other batch, which is as even a
  scatter as four batches allow on a hexagonal lattice. Scatter loading is the usual way to flatten a multi-batch
  core's power.
- **Symmetry:** a 60° rotation fixes one colour and permutes the other three, so no four-batch sublattice pattern
  is exactly 3-fold symmetric. Because the pattern repeats every two pitches, it is not expected to tilt the core
  as a whole. That is to be checked on the BOC core's power map (quadrant tilt) when it is tallied, not assumed.
- **Uneven colour:** the rods thin the fixed colour unevenly, leaving it 31 inner and 48 outer positions against
  38 and 36 for each of the others (79 against 74 overall, all "a quarter"). No mapping from colour to batch
  removes that. The fixed colour therefore takes batch 1: next to the core-average burnup of 1.5 cycles, a
  zone imbalance moves the least reactivity. Batches 1 and 2 tie, and the lower was taken. The fresh batch then
  holds 74 assemblies, 38 inner and 36 outer.
- **Compositions:** each batch takes D-043's composition at 0, 160, 320 or 480 EFPD for its zone. These are
  end-of-cycle compositions with **no outage decay**. That is consistent with D-036's 30 min outage, but it leaves
  out §3.1's Np-239 → Pu-239 gain (+30 pcm over a week), which a longer outage (F34) would add.
- **Ring 15:** holds outer-zone fuel at discharge (640 EFPD) in all 90 positions, at the coolant temperature. That
  is realistic content in bounding quantity (90 positions against a quarter core). The fresh-fuel bound of D-042
  applies to the fresh-core cases.

## F38 Audit of the spec sections the code has not reached (§5–§8, §10–§13, file 16) — Deferred (Aqua, 2026-09-24): reviewed before the steam-plant milestone
A cloud session audited the unbuilt sections, recomputing every number from the spec's own primitives:
`docs/audit/SPEC_AUDIT_UNBUILT.md`, reproduced by `tools/audit/spec_audit_unbuilt.py` (IAPWS-IF97 steam, TEOS-10
seawater, and file 20's `calc.py` run unmodified). Findings C-01 to C-40: 1 high, 15 medium and 24 low, plus 64
groups of checks that passed. It also found two errors in this log, P-01 (D-028) and P-02 (F24), both confirmed and
corrected above. **C-29 is the high one**, and I confirmed it against the text: §0.2 puts heater failures on the
×360 slow-process clock (so does `Config/Clocks.luau`), while §12.3 gives "1 per 2,000 zone-hours real". Read on ×360,
about 180 zones would fail every couple of minutes. Nothing in these sections is built yet, so none of this affects
M1. **For Aqua:** review before the steam-plant milestone, starting with C-29 and the medium findings.

**C-40 fixed (2026-09-24, Aqua's OK).** The text pack's README and seven spec-file headers said Rev A3, so a coding
agent read it as older than the HTML, although all three copies carried the same A5 text. The labels now say Rev A5,
and both revision logs run A3, A4, A5 (the text had A5 before A4, and the HTML table ran A5, A4, A3).
`tools/derive/apply_rev_a5.py` makes the change and checks it: 31/31 checks, including that every handoff file is
still verbatim in `KALLSKAR_ALL_IN_ONE.txt`. The audit script now expects C-40 to pass. `apply_rev_a4.py --check` now
reports its three checks that A5 replaced as superseded, where before it called them wrong.

## D-045 The prompt-critical flag describes the core as it is now, not what happened this session — Accepted (2026-09-24)
§14.2 has the amplitude hand over to a scripted core-damage event once ρ reaches 0.9β, "rather than integrating
through it". Before PR #4, `Kinetics` set `amp.promptCritical` on the first crossing and never cleared it, although
Core already had a branch meant to clear it. That made the latch a bug rather than a design. The code review (L3)
left the choice open. **Decision:** the flag clears on the first step back below 0.9β, and the CORE-PROMPT alarm
goes out with it (commit 4dcbe6c). The one-way hand-over §14.2 describes belongs to the scripted event, which will
latch its own trigger on the flag's rising edge once it exists. **Effect outside the plant:** the SnapshotServer
payload keeps its `promptCritical` field, with the same name and type. It now means "prompt-critical on this tick",
not "at some point this session", so a display reading it (KallskarWeb) will see it drop back to false.

## F39 K1's Pu content gives about 2,450 pcm more excess reactivity than §3.3 budgets — Resolved (Aqua, 2026-09-24): lower the Pu content until the excess is 2,250 pcm (D-051)
The equilibrium BOC core (D-043, D-044), in OpenMC with ENDF/B-VIII.1 (`tools/xsgen/results/k1_fresh_results.json`),
gives an excess of **+4,695 ± 24 pcm** at 230 °C with all rods out. §3.3 (and §3.7's target) require
**2,250 ± 150**.

| Case | k | ρ (pcm) |
|---|---|---|
| Fresh core, full power | 1.05762 ± 0.00019 | +5,448 |
| Fresh core, hot zero power | 1.06481 ± 0.00021 | +6,086 |
| Fresh core, 230 °C | 1.06801 ± 0.00023 | +6,368 |
| Equilibrium BOC, full power | 1.03961 ± 0.00032 | +3,810 |
| Equilibrium BOC, 230 °C | 1.04927 ± 0.00027 | **+4,695** |

**The sensitivity cases rule out the model's own assumptions as the cause:**
- Cladding density +1 %: −28 ± 24 pcm.
- Ring 15 empty: +12 ± 25 pcm.
- Reflective axial ends: **+892 ± 25**. The vacuum beyond §2.1's lengths is therefore the *less* reactive bound, and
  real structure there could only add reactivity.

So the gap is a lower bound. The Pu worth these runs imply (the fresh inner and outer lattices, 18 % against 23 % Pu)
is about 2,150 pcm per percentage point of Pu. Closing the gap would take Pu at **about 17 % and 22 %**, which is
outside §2.3's "≈ 18" and "≈ 23". D-012 allows a search only within the "≈", so nothing has been changed.

**For Aqua, one of:**
- (a) lower §2.3's Pu to about 17/22 %, fixed exactly by a search script;
- (b) keep 18/23 % and choose a more degraded Pu vector than NEA's BOC one;
- (c) raise §3.3's excess to what the core has, which also moves the rod-worth and shutdown-margin budget;
- (d) another change to the core.

Every §3.7 comparison of the reference core waits on this choice.

Other results from the same runs:
- **Power defect:** hot zero power → full power at fixed geometry is −639 ± 25 pcm, against §3.2's Doppler + sodium
  terms, −643.
- **β_eff (BOC):** 349.5 ± 11.6 pcm, inside §3.1's 360 ± 5 %.

## F40 The model's prompt generation time is 4.56 × 10⁻⁷ s, 14 % above §3.1's 4.0 × 10⁻⁷ — Resolved (Aqua, 2026-09-24): the computed Λ is used once XSData lands
IFP tallies give Λ = 4.56 × 10⁻⁷ s for the equilibrium BOC core, and 4.53 × 10⁻⁷ s for the fresh core. §3.7's
target is 4.0 × 10⁻⁷ ± 5 %. Lowering the Pu content for F39 would lengthen Λ slightly further. The point-kinetics
facade uses §3.1's value today (D-031), and the 3D model will compute its own from the shape. **For Aqua:** accept
the computed Λ once XSData lands, or keep §3.1's 4.0 × 10⁻⁷ as a tuning value (†) and record the difference.

## D-046 A runback follows a power demand at its table rate, driven by the shims (review H5) — Accepted (2026-09-24)
§9.5 gives each runback a target and a rate: RB-1 64 %FP at 30 %/min, RB-2 60 %FP at 60 %/min, RB-3
bypass-limited at 20 %/min. §3.4 gives the mechanism: the shims drive in at 10 mm/s on a runback. The rate is a
demand, not a rod speed. At 10 mm/s, eighteen shims insert up to about 108 pcm/s at mid-stroke (5,400 pcm over
1,000 mm, peak differential worth twice the average). The steepest runback, 60 %/min, needs about 8.4 pcm/s, which
is §3.3's 844 pcm power defect spread over 100 %FP. So a drive-in with nothing to follow overshoots into a shutdown,
which is the defect H5 found. **Decision:**
- **Start:** a runback starts on its trigger's rising edge. Once it is cleared or complete, it does not restart
  until the trigger has reset and come back.
- **Demand:** it ramps a power demand from the neutron power at its start down to its target, at its table rate.
- **Actuator:** the shim banks drive in at §3.4's 10 mm/s while the measured power (the PR median,
  `detectors.prMean_pctFP`) is above the demand, and hold otherwise.
- **Rod auto:** stands down during the runback (D-035 is unchanged).
- **Heat sink:** the IHX load ramps to the same target at the same rate, so the M1 stand-in for the turbines runs
  back with the reactor. Flow auto follows §9.2 as usual; that is RB-1's "plus flow program".
- **End:** the runback is complete once the demand has reached the target and the measured power is at or below the
  target plus one PR channel's D-025 noise at that power. It is logged, and rod auto, if it was in auto, takes over
  at the new load.
- **RB-3:** stays refused until turbines give its target a number (M3).

## D-047 The IQS shape step works on a copy of the shape (review M8) — Accepted (2026-09-24)
A time-sliced shape step that sweeps `psi` in place lets the fast ticks between slices compute ρ from a half-swept,
un-normalised shape. **Decision:**
- **Copy:** the shape step iterates on a working copy, allocated once, and swaps it in only when a step converges.
  Ticks use the last complete shape until then. That is what §14.2's "the amplitude keeps power moving" needs.
- **Allocations:** the shape step's other work arrays are also allocated once (the rest of L9).
- **Assembly:** the assembly is sliced too, since on its own it overruns the 4 ms slice (DECISIONS_NEEDED, 899086a).
This stays latent until IQS replaces the point-kinetics facade (D-031), and is done then.

## D-048 Detectors reads the core's power fresh (review L4) — Accepted (2026-09-24)
Detectors declared `core.*` as lagged although no cycle requires it. It runs first in the lane, so every neutron trip
reached the rods a tick late, at t + 0.2 s. That is about 24 % more overshoot on the 0.47 s period of §3.4's
all-RR-out case. A fission chamber answers at neutron speed; the only delays the plant models are D-025's filters.
**Decision:** Detectors reads `core.power_pctFP` and `core.k` as ordinary reads, so the trips act at t + 0.1 s. The
Registry puts Core ahead of Detectors, and that makes no cycle. Lagged reads keep L5's meaning ("last tick's or this
tick's, and the code must be right either way"); no snapshot of lagged channels is added.

## D-049 Test tolerances take the bases the review derived (review L13) — Accepted (2026-09-24)
Every tolerance CODE_REVIEW.md L13 lists takes the value its table derives, with the derivation in a comment:
- **CoreSpec's D-030 floor:** the prompt drop and the inhour decay at −3,826 pcm.
- **Subcritical multiplication:** read after several |T|, and bounded the same way.
- **Zone I share:** the exact arithmetic, 1.12 × 301 / Σf.
- **Hot-standby inlet:** the pump heat's 0.7 K.
- **The Detectors statistics:** 3σ for the effective sample count.
- **The period:** from the 5 s filter, plus σ/√n of the averaged ticks.
- **The AutoControls setpoint:** 0.5 K, §9.2's whole-degree rounding.
- **IHX's six-unit total:** 12 MW, six times the per-unit rounding.
- **FrameworkSpec's and IQSSpec's slice overrun:** the budget plus twice the measured longest piece. The budget is
  checked between pieces of work, so the piece running when the deadline passes finishes first: that is one piece
  past the budget. The slice as the Scheduler times it also includes its own resume before the first piece and its
  yield after the last. These are a few statements, and one more piece bounds them from what the test measures,
  without guessing a margin.

## D-050 An alarm clears only once its signal is back past the setpoint by the channel's noise — Accepted (2026-09-24)
With no deadband, an alarm chatters in and out every tick when a noisy signal sits at its setpoint. The CORE-OUT
thermocouple does it near 565 °C (±1 K, §2.5), and PR near 105 %FP (D-025's noise). **Decision:** each §9.5 row's
alarm comes in at its setpoint as now, and goes out only once the signal is back past the setpoint by that channel's
own noise amplitude: 1 K for the thermocouples (§2.5), and D-025's relative noise times the setpoint for the neutron
channels. Channels with no modelled noise keep no deadband, since they cannot chatter. The deadband comes from
figures the plant already has; no new number is introduced.

## Aqua's choices of 2026-09-24
Aqua took the recommended option on every open item: F33–F40, the code review's policy questions, and acceptance of
D-020 to D-050. The findings' headings above record their resolutions. The entries below turn the choices that need
code into decisions to implement.

## D-051 The Pu search: both zones move together until the BOC excess is 2,250 pcm (F39) — Accepted
- **What moves:** both zones shift by the same amount Δ, in percentage points of Pu/(U+Pu) by mass. That keeps §2.3's
  five-point step between the zones, which is what flattens the radial power (§3.7's 1.20 peaking target).
- **Method:** each trial repeats D-043's depletion of both zones and D-044's BOC core at 230 °C
  (`tools/xsgen/k1_pusearch.py`). The first trial takes Δ from the Pu worth the fresh lattices imply, about
  2,150 pcm per point. Further trials use the secant through the last two.
- **Stop:** when the excess is within 3σ of its own statistics of 2,250 pcm, where it cannot be told apart from
  the target.
- **Result:** replaces Config.Core.fuel.plutoniumFraction, with this decision as its provenance in place of §2.3's
  "≈".
- **D-012:** its search was limited to the "≈"; F39's choice lifts that limit.

## D-052 Developer powers are Studio only (review M1) — Accepted
`isDev` is true only in Studio. A private-server owner is an ordinary player with one extra power, the §14.6 reset
through `Persistence.requestReset`, and gets no exemption from reach or playtime.

That reset has no caller yet: no remote or panel routes a request to `Persistence.requestReset`, and only
FrameworkSpec calls it. The Studio debug panel's RESET is a separate control; it resets the trips. The owner's
reset therefore stays open until the panels exist and one of them carries it.

## D-053 A private server saves §14.6's list, and a server close counts as a reactor trip (review M5) — Accepted
Each system saves its §14.6 items: stuck rods, stopped pumps and loops, shutter demands, trip bypasses, active
faults, and the LCO clocks once they exist, alongside the event log already saved. It also saves the thermal state
the restored decay heat needs to match: the pool, fuel and cover-gas temperatures. On load, the plant comes back
tripped: rods in, scram latched, in the mode it was in. The saved decay heat (D-037) then lands in a plant consistent
with it. A test saves and loads all ten systems in one round trip.

## D-054 A control is operated only from a desk that carries it (review M6) — Accepted
A desk map in Config (spec provenance, §10.2) lists, for each command kind, the desks that carry it: the RO desk has
the rods and trip buttons, the PO desk the pumps, pony motors, IHX shutters and cover gas, the SS desk the mode key
and authorisations. The trip buttons also sit in the BCR. Commands checks that the named panel is one of those desks,
through a pluggable `panelHosts(panel, kind, target)` beside `panelPosition`. It changes to attributes on the panel
instances when panels are built.

## D-055 Bypassing a trip needs the critical playtime, one row at a time, never a neutron row (review M7) — Accepted
- **Playtime:** `pss.bypass` and `runback.clear` join the critical controls, so they need
  `Access.criticalMinimumPlaytime_h`.
- **One at a time:** at most one §9.5 row may be bypassed at once. That is a new `decision("D-055")` value of 1.
- **Neutron rows:** a row driven by the neutron instruments (PR high and low, flux rate, period) cannot be bypassed.
- **Authorisation:** once the desks exist, a bypass also needs §10.2's shift-supervisor authorisation.

## D-056 The MCR manual trip is two different buttons within 2 s (review L2) — Accepted
A trip from the main control room needs `MCR-1` and `MCR-2` pressed within 2 s of each other, where 2 s is a new
`decision("D-056")` value. One button pressed twice does not trip, and nor do two presses further apart. A single
press is forgotten after the window. The BCR keeps its one button (§9.5).

## D-057 The pools get the internals' heat capacity, split in proportion to their sodium (F36) — Accepted
§4.1's "sodium plus internals ≈ 2,400 MJ/K", less the 1,602 MJ/K of sodium (D-021), leaves about 800 MJ/K of steel.
It is split between the hot and cold pools in proportion to each pool's sodium. How the steel couples to the sodium,
so that §4.1's mixing times stay as they are while the hours-long heat-up uses all of it, is derived before it is
built (`tools/derive/pool_steel.py`). It is needed before DRACS and the blackout scenarios.

## D-058 Tags: three-digit indices and six M1 type codes (TagsSpec findings) — Accepted (Aqua, 2026-09-24)
Appendix B's tag is `SYS-L-TYPE-NN`. Jules' TagsSpec (9ec03e3) found two extensions already in `Tags.luau` with no
decision behind them. Both stay:
- **Index:** two digits up to 99, and three from 100 to 999. The 331-position core map (§2.2, rings 0–10) needs
  three, for example `RX-0-TC-331`. Each tag still has one spelling: `Tags.parse` rejects any spelling `Tags.format`
  would not produce, so `RX-0-TC-05` is valid and `RX-0-TC-005` is not.
- **Types:** `N` neutron flux (the SR, WR and PR channels), `PER` reactor period, `RHO` reactivity, `DND` delayed
  neutron detector, `POS` position and `PQ` power-to-flow ratio. These are M1 instruments that Appendix B has no
  code for.

`tests/TagsSpec` pins the exact set of extension codes, so adding another needs a decision of its own. C-39 (the
glossary's `SM`, and the hydrogen meters' index rule) is separate and stays open.
