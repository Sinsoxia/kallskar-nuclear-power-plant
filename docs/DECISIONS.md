# Design decisions log

Config values with `decision("D-xxx")` provenance point here. Every entry records **what** was decided, **why**, the
spec text it rests on, and its **status**. "Proposed" entries were made by Claude to unblock M1 and are waiting for
Aqua's review; Aqua can overrule any of them, and the spec wins wherever it is explicit.

Status key: **Proposed** (awaiting Aqua) · **Accepted** (Aqua confirmed) · **Superseded**.

---

## D-001 Three-colour SOR on the hex-Z mesh (finding F1) — Proposed
**Spec:** §14.2 says the inner solver is "red-black successive over-relaxation".
**Problem:** a hexagonal tiling cannot be 2-coloured. Any three hexes meeting at a corner are mutually adjacent (a
triangle), so a red-black ordering always puts two neighbours in the same colour and the sweep stops being a proper
Gauss-Seidel/SOR ordering.
**Decision:** colour each node `(c + k) mod 3`, where `c ∈ {0,1,2}` is the standard 3-colouring of the hexagonal
lattice (axial coordinates `(q − r) mod 3`) and `k` is the axial layer. Same-layer neighbours differ in `c`; axial
neighbours differ in `k` by one. Both change the colour, so the colouring is proper (proof in `tests/Mesh.spec.luau`).
Same per-sweep cost and the same "all nodes of one colour are independent" property the spec wanted.

## D-002 Finite-difference kernel with D̂ face corrections (finding F2) — Proposed
**Spec:** §3.7 "hexagonal-Z nodal diffusion", "one node per hexagonal position".
**Problem:** one mesh-centred node per 179 mm hex is coarse finite difference; plain FD shifts the power shape by a
few percent in a large fast core.
**Decision:** FD kernel with a per-face current-coupling correction D̂ (CMFD-style), default 0. D̂ comes from OpenMC
partial currents (`tools/xsgen/dhat.py`). Fallback: equivalence factors from OpenMC supercells. Never fitted to the
§3.7 targets without asking Aqua first.

## D-003 Auto controllers track the §9.2 part-load program (finding F3) — Proposed
**Spec:** §9.4 rod auto "holds core outlet 550 ±2 K"; primary flow auto "holds P/Q at 1.00".
**Problem:** below 40 %FP the §9.2 program itself lowers core outlet and P/Q (flow floor 40%). Fixed setpoints would
fight the program.
**Decision:** both autos take their setpoint from the §9.2 program at the current power. Above 40 %FP this is exactly
550 °C and P/Q = 1.00, as specified.

## D-004 Core-inlet-low trip gated by mode (finding F4) — Proposed
**Spec:** §9.5 core inlet trip low 345 °C; §9.1 Mode 4 is 200–350 °C.
**Problem:** an ordinary cooldown to Mode 4 crosses 345 °C and would raise a trip and first-out while the reactor is
already shut down, polluting the event log and the planned "was this trip justified" vote-kick check.
**Decision:** the core-inlet-low trip is bypassed while the plant is in Mode 3, 4 or 5 **and** every PSS rod is fully
inserted. All permissives the spec states explicitly (P/Q above 5 %FP, PR 25% setpoint below 10%) are unchanged.

## D-005 PR high-flux voting is 2-out-of-4 (finding F5) — Proposed
**Spec:** §9.5 "PSS logic is 2-out-of-3"; §3.5 PR has 4 quadrant channels.
**Decision:** 2-of-4 for the four PR quadrant channels (the natural coincidence for four channels), 2-of-3 for every
other three-channel parameter.

## D-006 Regulating rods move one at a time (finding F6) — Proposed
**Spec:** §3.4 interlock "only one rod or one bank moves at a time"; the RRs are not a bank.
**Consequence reported to Aqua:** at 3.0 pcm/EFPD and the ×360 slow clock, burnup drift is 0.75 pcm per real minute.
One RR from mid-band (550 mm) to the band edge is ≈ 25 pcm ≈ 33 min, not the ≈ 20 min in §10.5. The ×360 clock is a
† tuning value; changing it is Aqua's call.

## D-007 Part-load flow program is continuous between 5 and 10 %FP (finding F10) — Proposed
**Spec:** §9.2 table rows 5% (flow 25%) and 10% (flow 40%); file 20 computes `Q = max(P, 40) if P >= 10 else 25`.
**Problem:** that rule steps flow from 25% to 40% at exactly 10 %FP, which makes core outlet jump from ≈ 445 °C to
419 °C. A real flow program does not step.
**Decision:** flow is 25% up to 5 %FP, rises linearly to 40% at 10 %FP, then follows `max(P, 40)`. Both tabulated rows
(5% and 10%) are reproduced exactly; only the undefined interval between them changes.

## D-008 Hazard is a rate (finding F8) — Proposed (later milestone)
**Spec:** §12.1 λ = 0.002·e^(6U) per grid day, "about 80% at U = 1".
**Decision:** λ is a hazard rate; per-step failure probability is `1 − exp(−λ·Δt)`. At U = 1, λ = 0.807/day means a
55% chance of failing within one grid day. The spec's "80%" reads the rate as a probability; the formula is kept.

## D-009 Frequency response comes from turbine valves (finding F9) — Proposed (later milestone)
**Spec:** §8.4 FCR-N ±10 MWe per unit, 63% within 60 s; LCO-10 ramp ≤ 1 %/min.
**Decision:** FCR is delivered by turbine control valves on stored energy; frequency response is exempt from LCO-10,
which governs deliberate load changes.

## D-010 Rod set placement within rings (derived, see tools/derive/rod_layout.py) — Proposed
**Spec:** §2.2 "space each rod set evenly so it is 3-fold symmetric, and offset bank B by 30° from bank A so they
don't shadow each other"; RR at 0°, 120°, 240°.
**Derivation:** ring 3 has no position at an exact 30° angle, so the spec's exact 30° A→B offset forces bank A onto the
ring-3 corners (0° + 60°k) and bank B onto ring-6 mid-edges (30° + 60°k). The spec leaves the SSR (rings 4, 7) and
bank C (ring 8) angles open; the script applies the spec's own anti-shadowing rule, maximising the angular separation
from rod sets in the adjacent rings: SSR ring 4 at 30° + 120°k, SSR ring 7 at 0° + 60°k, bank C at 30° + 60°k.

## D-012 MOX plutonium isotopic vector from the OECD/NEA MOX-3600 benchmark — Proposed (pending sourcing review)
**Spec:** §2.3 gives Pu/(U+Pu) ≈ 18% inner, ≈ 23% outer, but no Pu isotopics or uranium composition. §3.7 names the
OECD/NEA SFR benchmark's large oxide core as "a realistic starting point".
**Decision:** take the Pu isotopic vector from NSC/R(2015)9 Tables 2.11–2.12 (MOX-3600 BOC). At the inner-core
midplane: Pu-238 2.5%, Pu-239 53.8%, Pu-240 28.8%, Pu-241 5.8%, Pu-242 9.1%. The K1 Pu fractions stay as the spec
gives them; if the 3D model's excess reactivity then misses §3.3 (2,250 ± 150 pcm), the Pu fraction is adjusted within
the spec's "≈" by a documented search script, and the result is reported to Aqua.
**Open:** whether K1 fuel should carry the benchmark's minor actinides and lumped fission products (it's an
equilibrium-cycle composition) or be modelled as fresh MOX plus depletion. `docs/K1_MATERIALS.md` will compare sources.

## D-013 Assembly flow factors vs the hottest-outlet figure (finding F11) — Open question for Aqua
**Spec:** §2.5 orifice zones f = 1.12 / 1.00 / 0.92 and `T_out = T_in + 183.7 × (p/f) × (P/Q)`; §2.4 hottest assembly
outlet 580–585 °C.
**Problem:** spec file 20 computed the 580–585 °C figure with f = 1.08 (inner hot assembly) and f = 0.925 (outer), not
the §2.5 table values. With the §2.5 factors, a radial-peak assembly (p = 1.20) in zone II would read ≈ 595 °C; in zone
I ≈ 572 °C. The real hottest outlet will come from the 3D power map.
**Proposal:** keep §2.5 as written for M1. Once OpenMC power shapes exist, check the hottest outlet; if it falls outside
580–585 °C, re-derive the orifice factors from the computed power map (how real orifice zoning is designed) and ask
Aqua before changing them.

## D-014 IQS shape step is a normalised (power-iteration) solve with a lagged delayed-source map — Proposed
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

## D-015 Amplitude integrator treats n as linear over each step — Proposed (accuracy refinement)
**Spec:** §14.2 snippet `s[i] = s[i]·e + beta[i]·n·(1 − e)`; `n = Σs / (BETA − rho)`.
**Problem:** the snippet holds n at its old value while integrating the precursors, which lags the delayed source
by one 0.1 s step (a period error of order dt/T, about 0.2% at T = 50 s).
**Decision:** the same prompt-jump form, with the precursor integral taken exactly for n varying linearly across the
step: sᵢ¹ = sᵢ⁰eᵢ + βᵢn⁰(1 − eᵢ − wᵢ) + βᵢn¹wᵢ, with wᵢ = (1 − eᵢ) − (1 − eᵢ − xᵢeᵢ)/xᵢ and xᵢ = λᵢdt. n¹ then follows
algebraically, n¹ = Σ[sᵢ⁰eᵢ + βᵢn⁰(1 − eᵢ − wᵢ)] / (β − ρ − Σβᵢwᵢ), which is still explicit, still unconditionally
exact at steady state, and has a period error of order (dt/T)². At dt = 0.1 s, Σβᵢwᵢ ≈ 10 pcm, so the denominator
stays positive for every ρ below the 0.9β prompt-jump limit.

## D-016 The "+300 pcm gives a period near 2.5 s" figure (finding F12) — Open question for Aqua
**Spec:** §3.4 "All three RR fully withdrawn from critical is +300 pcm, about $0.83, which gives a period near 2.5 s";
§3.1 delayed-neutron groups (βᵢ, λᵢ) and Λ = 4 × 10⁻⁷ s.
**Problem:** with the §3.1 constants, the inhour equation gives a period of about 0.46 s for +300 pcm (Λ changes
this by less than a millisecond). A 2.5 s period corresponds to about 211 pcm. `tests/KineticsSpec` computes both.
**Proposal:** the simulation follows the §3.1 physics, so a +300 pcm step really gives ~0.46 s. Nothing in M1 depends
on the 2.5 s figure; it only matters for how S-19 is described and for the trip-timing narrative. Aqua to decide
whether §3.4's sentence should say "≈ 0.5 s" or "+210 pcm".

## D-011 Kinetics uses β = Σβᵢ, not the rounded 360 pcm — Proposed (consistency fix)
**Spec:** §3.1 β_eff = 360 pcm; the six group βᵢ sum to 360.3 pcm.
**Decision:** the amplitude equation's `BETA` is computed as Σβᵢ from the group table. Using the rounded 360 while the
groups sum to 360.3 would leave a "critical" reactor sitting at ρ = −0.3 pcm and drifting. Config keeps both numbers
with their spec provenance; the validation target (360 ± 5%) is unaffected.
