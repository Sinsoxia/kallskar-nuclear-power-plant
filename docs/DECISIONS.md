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
hydraulic check (437.5 kg/s, ~14.5 MPa rise, feedwater at ~887 kg/m³, 82 % pump and 96 % motor efficiency) gives
9.1 MW per train. Each of the two pumps therefore absorbs about **4.9 MW**, which cannot sit behind a 12 MW motor.
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

## D-020 Cover gas make-up and vent controller — Proposed
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

## D-021 Where the 70 t of core and diagrid sodium lives — Proposed
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

## D-022 IHX UA is held constant; the film coefficients' flow dependence is not modelled — Proposed
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

## D-023 Scram inserts at a constant rate — Proposed
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

## D-024 The plant boots in Mode 3, hot standby — Proposed
Something has to decide where the rods are when a server starts. **Decision:** every PSS rod fully inserted, the
nine SSRs parked at 1,100 mm and latched, which is §3.4's stated normal position for them and §9.1's Mode 3.
`FuelThermal` and `Pools` already boot isothermal at the §3.2 reference temperature of 375 °C with the pumps
running, so the whole plant starts as a coherent hot standby.
**Why not critical at power:** the shim positions that hold a critical core depend on burnup, temperature and the
3D solve, so picking them now would be a guess — and worse, it would hand players a running reactor they did not
start. Taking the plant from hot standby to power is the game. **Alternative if it proves tedious:** a scenario
preset that fast-forwards a startup, which belongs to the scenario director rather than to these systems.

## D-025 Neutron instrument noise, and the filters that follow from it — Proposed
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

## D-026 Where the protection system votes, and where it cannot yet — Proposed
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
