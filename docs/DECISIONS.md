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

## D-011 Kinetics uses β = Σβᵢ, not the rounded 360 pcm — Proposed (consistency fix)
**Spec:** §3.1 β_eff = 360 pcm; the six group βᵢ sum to 360.3 pcm.
**Decision:** the amplitude equation's `BETA` is computed as Σβᵢ from the group table. Using the rounded 360 while the
groups sum to 360.3 would leave a "critical" reactor sitting at ρ = −0.3 pcm and drifting. Config keeps both numbers
with their spec provenance; the validation target (360 ± 5%) is unaffected.
