# Kallskär SFR-1000 — Final Resolved Decision Log
**New standalone decision file — Rev A5 resolution**  
**Prepared for:** Aqua  
**Based on:** Rev A4 spec, `DECISIONS.md`, `SPEC_REVIEW_AUDIT.md`, `K1_MATERIALS.md`, `KALLSKAR_ALL_IN_ONE.txt`

---

## 1. Purpose of this file

This file resolves all open design decisions and audit findings relevant to the SFR-1000 specification at Rev A4.

It is intended to be a **new standalone decision record**, separate from the original `DECISIONS.md`, and it records:

1. The final chosen option for every decision.
2. The reasoning behind each choice.
3. Any required spec wording changes.
4. Any remaining implementation caveats.

Unless otherwise stated, the decisions below preserve the design intent of the spec while correcting only the points that were physically inconsistent, numerically inaccurate, or ambiguous.

---

## 2. Overall verdict

The Rev A4 specification is extremely strong. Almost all proposed decisions should be accepted.

Only a small number of items require refinement:

- **D-004** needs a clearer low-temperature trip permissive.
- **D-012** should be resolved as an equilibrium four-batch fuel model generated from fresh MOX depletion.
- **D-018** should update the derived fuel centreline and melting figures to match the constant-gap thermal model.
- **F20** should use approximately **2.7 h** for regulating-band drift rather than 2.5 h if exact arithmetic is desired.
- **F27** needs explicit scope for idle loops.

Everything else is accepted as realistic and internally consistent.

---

# 3. Final decision status table

| ID | Topic | Final decision | Status |
|---|---|---|---|
| D-001 | Hex mesh SOR colouring | Use 3-colour SOR | Accepted |
| D-002 | FD kernel with D-hat corrections | Use CMFD-style D-hat corrections | Accepted |
| D-003 | Auto controllers follow part-load program | Autos track §9.2 program | Accepted |
| D-004 | Core-inlet-low trip gating | Mode-gated with startup/low-temp inhibit | Accepted with refinement |
| D-005 | PR high-flux voting | 2-out-of-4 for PR quadrants | Accepted |
| D-006 | Regulating rod motion | One RR at a time | Accepted |
| D-007 | Part-load flow continuity | Continuous flow between 5% and 10% FP | Accepted |
| D-008 | Hazard interpretation | λ is a hazard rate, not a probability | Accepted with wording correction |
| D-009 | Frequency response source | FCR delivered by turbine valves | Accepted |
| D-010 | Rod set placement | Use derived 3-fold symmetric layout | Accepted |
| D-011 | β in kinetics solver | Use exact Σβᵢ, not rounded 360 | Accepted |
| D-012 | MOX vector and fuel state | Use MOX-3600 vector; equilibrium four-batch core via depletion | Accepted with implementation choice |
| D-013 | Flow factors vs hottest outlet | Keep §2.5 for M1; recalibrate later from OpenMC | Accepted as interim |
| D-014 | IQS shape step | Normalised power iteration with lagged delayed source | Accepted |
| D-015 | Amplitude integrator | Use linear-n form | Accepted |
| D-016 | Period for +300 pcm | Use ~0.47 s | Accepted |
| D-017 | Uniform perturbation check | Rescale precursors with weighted fission production | Accepted |
| D-018 | Fuel-pin thermal model | Keep constant-gap model; update derived figures | Accepted with spec update |
| D-019 | Cladding thermal treatment | Quasi-static cladding | Accepted |
| F15 | Sodium cp table at 950 °C | Use correlation value, 1.285 | Accepted |
| F16 | IHX inlet temperature | Use 550 °C | Accepted |
| F17 | DRACS coping time | Use ~6.5–6.6 h | Accepted |
| F18 | Shim bank A speed | Use 0.8 mm/s | Accepted |
| F19 | Regulating band | Use 250–750 mm | Accepted |
| F20 | Regulating band drift time | Use ~2.7 h from mid-band to edge | Accepted with correction |
| F21 | Secondary dump tank | Use 500 m³ | Accepted |
| F22 | Low part-load rows | Treat below ~25% FP as bypass/house-load | Accepted |
| F23 | Natural circulation formula | Use `(P / 100%FP)^(1/3)` | Accepted |
| F24 | Feed pump power wording | State 9.8 MW per train, 6 MW motors | Accepted |
| F25 | §14.2 amplitude snippet | Replace with linear-n form | Accepted |
| F26 | Clock assignments | Degradation on grid clock; ×360 only for very slow processes | Accepted |
| F27 | Secondary-over-primary pressure scope | Clarify running-loop scope and idle-loop handling | Accepted with clarification |
| F28 | LHR basis | State 95% pin energy deposition | Accepted |
| F29 | Canonical power vs section duty | §1.1 canonical; section duty rounded | Accepted |

---

# 4. Detailed decision resolutions

---

## D-001 — Three-colour SOR on the hex-Z mesh

### Final decision
**Accepted.**

Use a **three-colour SOR** ordering instead of red-black.

### Reasoning
A hexagonal mesh cannot be correctly 2-coloured because three neighbouring hexes can meet at a corner, forming a mutually adjacent triangle. A red-black ordering would therefore place at least two neighbours in the same colour, breaking the independence property required for a proper Gauss-Seidel/SOR sweep.

A valid 3-colouring preserves the required property that all nodes of one colour are independent of each other.

### Recommended implementation
Use:

```lua
colour = (c + k) % 3```

where `c` is the standard hexagonal 3-colouring and `k` is the axial layer.

**Verdict:** Accepted.

---

## D-002 — Finite-difference kernel with D-hat face corrections

**Final decision: Accepted.** Use a coarse finite-difference kernel with CMFD-style face-current corrections `D̂`,
derived from OpenMC partial currents where possible; fallback to equivalence factors from OpenMC supercells. Do not
hand-tune `D̂` purely to hit validation targets unless Aqua explicitly approves it.

**Reasoning:** a single node per hexagonal assembly is coarse, and plain finite difference would distort the power
shape in a large fast core. CMFD-style nonlinear corrections are the standard, realistic way to preserve interface
currents and improve coarse-mesh accuracy.

---

## D-003 — Auto controllers track the §9.2 part-load program

**Final decision: Accepted.** Rod auto and primary flow auto both take their setpoint from the §9.2 program. Above
40 %FP that reduces to core outlet ≈ 550 °C and P/Q ≈ 1.00; below 40 %FP the autos follow the programmed lower outlet
temperature and the flow floor.

**Reasoning:** real plants do not hold 100 %-power setpoints at low load. Below the flow floor the plant runs on a
coordinated program, and the controllers should follow it rather than fight it.

---

## D-004 — Core-inlet-low trip gated by mode

**Final decision: Accepted with refinement.** Gate the trip so it cannot nuisance-trip during cooldown or
low-temperature startup, while still protecting at power:

- disabled in Modes 4 and 5;
- disabled in Mode 3 when all PSS rods are fully inserted;
- disabled in Mode 2 below about 350 °C during startup heatup;
- enabled in Mode 1 / above 5 %FP, or any state where a genuine cold-slug transient is a real threat.

**Reasoning:** a low inlet temperature is a real concern at power but meaningless as a trip during ordinary cooldown
or low-temperature startup. Real protection systems use mode-based or permissive-based suppression for exactly this.

---

## D-005 — PR high-flux voting is 2-out-of-4

**Final decision: Accepted.** 2-out-of-4 on the four PR quadrant channels; 2-out-of-3 for other three-channel
protections. With four quadrant power channels this is the natural coincidence logic, balancing spurious-trip
resistance, redundancy and quadrant tilt detection.

---

## D-006 — Regulating rods move one at a time

**Final decision: Accepted.** Only one regulating rod moves at a time, matching the "one rod or one bank at a time"
interlock, avoiding unnecessary flux tilting and keeping the reactivity insertion rate manageable.

---

## D-007 — Part-load flow program is continuous between 5 and 10 %FP

**Final decision: Accepted.** 25 % flow up to 5 %FP, a linear rise from 25 % to 40 % between 5 % and 10 %FP, then
`max(P, 40)` above 10 %FP. Real flow programs do not step abruptly, and a continuous transition avoids an artificial
core-outlet temperature jump.

---

## D-008 — Hazard is a rate

**Final decision: Accepted, with wording correction.** Treat `λ = 0.002 × e^(6U)` as a hazard rate and compute the
per-step probability as `P = 1 − exp(−λ·Δt)`.

Do not say "about 80 % at U = 1" as if the rate were a probability: at U = 1, λ ≈ 0.807 per grid day, so the
probability of failing within one grid day is `1 − exp(−0.807) ≈ 55 %`. If an 80 % per-grid-day probability is
actually wanted, the rate must be ≈ 1.61/day, not 0.807/day.

---

## D-009 — Frequency response comes from turbine valves

**Final decision: Accepted.** FCR-N / FCR-D response comes from turbine control valves and stored energy, not from
immediate reactor power changes, and frequency response is exempt from LCO-10 ramp limits (which govern deliberate
load changes). This is how real plants behave: the governor responds quickly, the reactor primary side does not.

---

## D-010 — Rod set placement within rings

**Final decision: Accepted.** Use the derived layout: 3-fold symmetry preserved, RR at 0°/120°/240°, bank B offset
30° from bank A as far as the lattice permits, SSRs and bank C placed to maximise angular separation and minimise
shadowing. This follows the spec's own anti-shadowing rule and is the most physically reasonable reading of the ring
geometry.

---

## D-011 — Kinetics uses β = Σβᵢ, not the rounded 360 pcm

**Final decision: Accepted.** The solver uses the exact group sum; 360 pcm stays as the rounded headline and
validation value. Using 360 while the groups sum to 360.3 would introduce a small artificial reactivity bias, and a
real-time solver is better off exactly self-consistent.

---

## D-012 — MOX plutonium vector, equilibrium vs fresh fuel

**Final decision: Accepted with a specific implementation choice.** Neither model the whole core as fresh fuel nor
paste an equilibrium composition with no depletion path. Instead:

1. use the OECD/NEA MOX-3600 BOC Pu vector;
2. keep K1's spec Pu fractions (≈ 18 % inner, ≈ 23 % outer);
3. generate burnup-dependent cross sections by depleting that fresh MOX;
4. initialise the canonical beginning-of-cycle core as an equilibrium four-batch core, approximately
   0 / 13 / 25 / 38 GWd/tHM batch states, discharging near 51 GWd/tHM;
5. include minor actinides and lumped fission products if practical; if too heavy for M1, exclude them temporarily,
   treat that as a simplification and report the reactivity shift.

**Reasoning:** K1 is a 38-year-old plant, so its BOC core would realistically be an equilibrium-cycle core — but a
simulator still needs a depletion path for burnup feedback and cycle mechanics. Fresh MOX vector → depletion →
equilibrium four-batch BOC is the realistic implementation.

---

## D-013 — Assembly flow factors vs the hottest-outlet figure

**Final decision: Accepted as interim.** Keep the §2.5 orifice factors (1.12 / 1.00 / 0.92) and the algebraic
thermocouple map for M1. Once a 3D OpenMC power shape exists, recompute the hottest outlet; if it lands outside
≈ 580–585 °C, re-derive the orifice factors from the computed power map. Real orifice zoning is ultimately designed
against the actual power distribution.

---

## D-014 — IQS shape step is a normalised solve with a lagged delayed source

**Final decision: Accepted.** Warm-started power iteration; prompt fission source treated normally; delayed source
taken from the actual spatial precursor distribution and rescaled consistently with the prompt source; the `(1/v)`
time-derivative term dropped because Λ is extremely small. With Λ = 4 × 10⁻⁷ s a literal fixed-source time-step shape
solve would converge very poorly.

---

## D-015 — Amplitude integrator treats n as linear over each step

**Final decision: Accepted.** Use the linear-`n` prompt-jump integrator, not the old constant-`n` explicit form and
not a fully implicit form. The explicit form lags too much at high reactivity; the fully implicit form overcorrects
near prompt-critical. Linear-`n` balances stability, accuracy, simplicity and exactness at steady state.

---

## D-016 — The "+300 pcm gives a period near 2.5 s" figure

**Final decision: Accepted — use 0.47 s.** Keep RR total at +300 pcm and correct the period; do not reduce the rod
worth to +210 pcm to preserve the 2.5 s narrative. With the stated kinetics constants the inhour equation gives
roughly 0.46–0.47 s, and 2.5 s corresponds to ≈ 210 pcm.

---

## D-017 — Uniform perturbation check and the generation-time change

**Final decision: Accepted.** Implement adjoint-weighted kinetics parameters, rescale the scaled precursor amplitudes
when weighted fission production changes, and keep both development checks: a uniform loss-side perturbation must
match constant-Λ point kinetics, and a uniform fission-side perturbation must match point kinetics including the
generation-time scaling.

---

## D-018 — Fuel-pin thermal model fixed by the core-average fuel temperature

**Final decision: Accepted, with the spec numbers updated.** Keep the derived constant-gap model (cladding-to-sodium
resistance from the 620 °C hot spot, gap resistance from the 1,380 K core average) and update the derived figures:

- hot-pin centreline ≈ 2,140 °C;
- centreline melting onset ≈ 57 kW/m, not ≈ 60 kW/m;
- fuel time constant: use the derived ≈ 3–4 s range as appropriate.

**Reasoning:** with currently citable sources, a constant-gap model cannot satisfy all four original pin figures at
once. Keeping the defensible model and updating the derived numbers is more honest than retaining inconsistent
headline values. A power-dependent gap model is more physical, but without a citable gap-conductance source it would
be an invented tuning layer.

---

## D-019 — Cladding temperature is quasi-static

**Final decision: Accepted.** One dynamic state per axial layer for fuel temperature; cladding midwall computed
algebraically from the current heat flow and still published per layer. Add a dynamic cladding node later only if
proper 15-15Ti thermal properties are sourced. The cladding time constant is about one fast tick and its stored heat
is small compared with the fuel's.

---

# 5. Audit findings F15–F29

## F15 — Appendix A cp table entry at 950 °C
**Accepted: the correlation wins.** Use cp ≈ 1.285 kJ/kg·K at 950 °C, or keep the correlation canonical and relax the
table tolerance.

## F16 — IHX inlet temperature
**Accepted.** IHX inlet = hot pool = 550 °C; duty ≈ 396 MWt; LMTD ≈ 41 K; UA ≈ 9.6 MW/K; 400 MWt remains the rating,
not the duty. Keeping 545 °C would create a ≈ 79 MWt shortfall unless a very large hot-pool heat loss is invented.

## F17 — DRACS coping time
**Accepted.** Use ≈ 6.5 h (exact recomputation ≈ 6.6 h) and update S-16 pacing to ≈ 40 min at ×10. The original ≈ 5 h
came from dropping the second term of the decay-heat formula.

## F18 — Shim bank A speed vs the 4 pcm/s interlock
**Accepted.** Bank A at 0.8 mm/s; banks B and C unchanged; the 4 pcm/s withdrawal interlock stays.

## F19 — Regulating band worth vs the reactivity budget
**Accepted.** Widen the band to 250–750 mm, which gives roughly the 250 pcm operating margin reserved in §3.3.

## F20 — Regulating band drift time
**Accepted with correction to ≈ 2.7 h.** With 3.0 pcm/EFPD, the ×360 clock (0.75 pcm per real minute) and a half-band
worth of ≈ 123 pcm, the drift is about 164 minutes. "20 min" was definitely wrong; 2.5 h is close, 2.7 h is exact.
"≈ 2.5–3 h" is acceptable as a tuning-friendly phrase.

## F21 — Secondary dump tank size
**Accepted.** 500 m³, so a hot drain stays credible without requiring cooldown first (400 t occupies ≈ 443 m³ at
200 °C and ≈ 469 m³ at 420 °C).

## F22 — Low part-load rows vs turbine minimum load
**Accepted.** Below ≈ 25 %FP the turbines are not in normal service; steam goes to bypass or supports house load. The
20 %, 10 % and 5 % rows are not normal two-turbine online states.

## F23 — Natural-circulation formula reference power
**Accepted.** `Q_nc ≈ 3.5 % × (P / 100 %FP)^(1/3)`, giving ≈ 3.5 % at full power and ≈ 0.75 % at 1 %FP, instead of the
absurd 16 % the original denominator produced.

## F24 — Feed-pump motor rating wording
**Accepted.** "2 × 55 % main feed pumps on VFDs; 9.8 MW absorbed per train at 100 %; ≈ 4.9 MW per pump; 6 MW motors."
The original wording allowed a per-pump misreading that would break the house-load balance.

## F25 — Amplitude update in §14.2
**Accepted.** Replace the snippet with the D-015 linear-`n` form.

## F26 — Clock assignments for degradation models
**Accepted.** Grid clock for fuel failure hazard, cladding creep, SG tube leak growth and other degradation models;
×360 only for burnup, impurity ingress, cold-trap loading and similar very slow inventory processes. Also allow ×10
acceleration in a station blackout once the reactor is confirmed subcritical.

## F27 — Secondary-over-primary pressure and the pump-trip transient
**Accepted with idle-loop clarification.** §4.3's design rule (secondary ≥ 0.4 MPa above primary) applies to a running
loop; LCO-7's ≥ 0.2 MPa applies to running or hot-standby loops. An idle or isolated loop must either be drained or
held at a stated pressure/elevation that still prevents primary-to-secondary leakage. Keep the Rev A4 pump-trip
wording: the flap check valve seats as the tripped pump's head decays, the surviving pumps ramp to 105 %, and P/Q
stays below the 1.12 trip during RB-2.

## F28 — Linear-heat-rate basis
**Accepted.** Keep 27.7 kW/m and state the basis: 95 % of fission energy is deposited in the pins, the remaining 5 %
heats coolant and structure. That removes the apparent discrepancy with the ≈ 29.2 kW/m "all power in pins" figure.

## F29 — Canonical power vs section duty rounding
**Accepted.** §1.1's 2,380 MWt is canonical; the 99.5 MWt section duty is understood as rounded (exact ≈ 99.58 MWt).
This is rounding, not a design inconsistency: the fix is wording.

---

# 6. Original OD decisions — realism check

| ID | Topic | Verdict |
|---|---|---|
| OD-1 | Names and setting (Kallskär, Hälsingland coast, SFR-1000) | Keep closed — coherent for the alternate-history Swedish plant |
| OD-2 | No sodium plenum above the core | Keep closed — deliberately preserves a large positive void worth; physically coherent |
| OD-3 | Log wide-range neutron channels, no range switching | Keep closed — realistic modern instrumentation, simplifies the source-to-power transition |
| OD-4 | Loop 2 reheaters split 4 sections to A, 4 to B | Keep closed — invented but thermodynamically plausible, and it creates meaningful decisions |
| OD-5 | Default control mode: reactor leads | Keep closed — more realistic for an SFR than turbine leads |
| OD-6 | DRACS dampers fail as-is | Keep closed — realistic for motor-operated dampers, and it creates the blackout field action |
| OD-7 | Primary pump trip at power causes RB-2 | Keep closed — realistic, and better than an immediate trip in this design |
| OD-8 | Refuelling outage as a timed wait | Keep closed as a placeholder — right practical choice for current development |
| OD-9 | Persistence per private server, owner can reset | Keep closed — a game-structure decision, and a sensible one |

---

# 7. Implementation status (Claude, 21 Sep 2026)

Applied in Rev A5 and in code: D-004 (fuller mode logic below), D-008 wording, D-018 figures, F20 (2.7 h), F27
(idle-loop clause). Everything else was already implemented at Rev A4 or earlier, or is scheduled work
(D-002 D̂ corrections, D-012 depletion path, D-013 recalibration).

Two notes recorded rather than silently absorbed:

- **D-018 costs an independent check.** Once §2.4 carries the model's own centreline and melting figures, the only
  §2.4/§3.2 pin figure that can still falsify `tools/derive/pin_thermal.py` is the 4 s Doppler lag (model: 3.57 s
  incremental). The 620 °C hot spot calibrates one resistance and the 1,380 K core average the other, so neither can
  disagree. The spec's 4 s has therefore been left alone rather than replaced by the derived 3.6 s.
- **F30 is not in this list.** `3 × 3,565 = 10,695` against the 10,694 kg/s total the heat balance sets; the code
  derives the per-pump rating from the total. See `docs/DECISIONS.md`.
