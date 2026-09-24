# Decisions needed for the unbuilt sections audit

`132 checks: 90 PASS, 42 FAIL`
`FAIL (findings reproduced): C-01, C-02, C-03, C-04, C-05, C-06, C-07, C-08, C-09, C-10, C-11, C-12, C-13, C-14, C-15, C-16, C-17, C-18, C-19, C-20, C-21, C-22, C-23, C-24, C-25, C-26, C-27, C-28, C-29, C-30, C-31, C-32, C-33, C-34, C-35, C-36, C-37, C-38, C-39, P-01, P-02`
`PASS (consistent): K-01, K-02, K-03a, K-03b, K-04, K-05, K-06, K-07, K-08, K-09, K-10, K-11, K-12a, K-12b, K-13a, K-13b, K-14a, K-14b, K-14c, K-15, K-16a, K-16b, K-17, K-18, K-19, K-20, K-21, K-22, K-23a, K-23b, K-23c, K-23d, K-23e, K-23f, K-24, K-25, K-26, K-27, K-28a, K-28b, K-29, K-30, K-31, K-32, K-33, K-34, K-35a, K-35b, K-35c, K-36, K-37, K-38, K-39, K-40, K-41, K-42, K-43, K-44, K-45, K-46, K-47, K-48, K-49, K-50, K-51, K-52, K-53, K-54, K-55, K-56, K-57, K-58, K-59, K-60, K-61, K-62, K-63, K-64`
`PASS (fixed since the audit): C-40 (2026-09-24, tools/derive/apply_rev_a5.py)`

These are the open findings (C-01 to C-39) from `docs/audit/SPEC_AUDIT_UNBUILT.md` (the unbuilt sections: §5–§8, §10–§13, file 16). They are prepared here for Aqua's decision.

| ID | Sev. | Question | Recommendation | Blocks steam plant? |
|---|---|---|---|---|
| C-29 | high | Trace-heating failures "1 per 2,000 zone-hours real" | Remove "heater failures" from §0.2's ×360 list (L403). | Yes |
| C-01 | medium | Trace-heating low alarm 150 °C | Alarm at ≥ 180 °C, above the plugging alarm; state that cold traps are exempt from the 180 °C rule. | Yes |
| C-02 | low | 1 g/s leak adds +0.28 ppm at the section meter | Print 0.29 ppm | Yes |
| C-03 | medium | Hydrogen drift and impurity ingress "per grid day" | Bind both to the ×360 clock. | Yes |
| C-04 | low | Reactor = SG total − 10.5 MW | Add the secondary pumps' heat | Yes |
| C-05 | low | Pinch ≈ 20 K (sodium 360, saturation 340 °C) | "≈ 17–20 k" | Yes |
| C-06 | low | Throttling a branch to 50 % costs about 6 MWe | ≈ 1 mwe | Yes |
| C-07 | low | Isolating one SG2 section nudges each reheat by about 2 K | "≈ 2 k on a, 6–9 k on b" | Yes |
| C-08 | medium | B load limits 100/100/94/83/72/62 % | State where the limit and the 420 °C trip read (at the IP stop valve), then recompute the column. | Yes |
| C-09 | low | 60 % row: A hot reheat 508 °C, not spraying | Label the column "before sprays" and mark the 60 % row as spraying | Yes |
| C-10 | medium | Water admission: sodium ≥ 250 °C; feed ≥ sodium − 80 K | Name the sodium location (SG inlet), state that the rule is first admission only, and give a hot re-admission path. | Yes |
| C-11 | low | Header 13.7 MPa; turbine auto holds header 13.5 ±0.2 | Header setpoint 13.7 ±0.2 | Yes |
| C-12 | low | Generator trips above 52 Hz | Trip at 51.5 hz with a delay | Yes |
| C-13 | medium | Hot-reheat alarm fixed at 480 °C | Let the hot-reheat alarm track the programme below 40 %, as main steam's does. | Yes |
| C-14 | medium | One unit runs at house load ≈ 65 MWe | Exempt house-load operation from the minimum for a stated time. | Yes |
| C-15 | medium | Poor crew: "Condenser B overloaded, second trip" | Add a mechanism, e.g. degraded cooling water. | Yes |
| C-16 | low | 15.3 m³/s, 11 K rise, 690 MWt | Use 5 psu properties; print 15.1 m³/s | Yes |
| C-17 | low | LP2 feed out 91 °C; 90 % row A reheat 516 °C | 90 °c and 515 °c | Yes |
| C-18 | low | Train B lost: turbine A takes 437.5 kg/s, "the rest goes to bypass" | State turbine b's status, sg3's feed source and the runback | Yes |
| C-19 | low | House load: feed pumps 19.6, primary 10.3, secondary 6.2 | List the feed pumps at electrical input and trim "everything else" | Yes |
| C-20 | low | Unit boards fast-transfer to station boards via ST-1, 60 MVA | Size st-1 ≥ 77 mva | Yes |
| C-21 | medium | "178, 86 and 42 MWe are under the 150 MWe minimum … their steam is below the reheat trip" | Give the true reason: below ≈ 33 %FP two turbines cannot both hold 150 MWe. | Yes |
| C-22 | low | "No two desks that have to talk during a fault can see each other" | "no two rooms whose desks…" | No |
| C-23 | low | Planned curtailment (e.g. −200 MWe) announced a grid-hour ahead | State the deadline; notice ≥ 4 grid-hours for 200 mwe | No |
| C-24 | medium | Dispatch error counts |MW − target| beyond 10 MW | Target = dispatch setpoint + expected reserve response. | No |
| C-25 | medium | Poor crew: under-frequency trip | Change the outcome in S-18. | Yes |
| C-26 | medium | Striping: adjacent outlets > 40 K apart add 1/5,000 per minute | Mark the clock (grid) and say "fuel assemblies". | No |
| C-27 | low | Random failure × "overpower multiplier" | Define it | No |
| C-28 | medium | Scan one group of 7 every 2 min; LCO-12: ≤ 30 %FP and locate within 8 grid-h | ≤ 55 s per group, "2 grid-min". | No |
| C-30 | medium | Plugging temperature +2 K per 10 % loading above 70 %; S-13 ends in an LCO-6 derate | Add the mechanism (ingress with a full trap). | Yes |
| C-31 | low | "Drained line" freezes in ≈ 40 min | "filled line with heater off" | Yes |
| C-32 | medium | Small leak: neighbour penetrated in 10–30 min at 1 g/s, 1–3 min at 10 g/s | Mark each figure real time. | Yes |
| C-33 | medium | SBO window ≈ 6.5 h, ≈ 40 min at ×10 | State that batteries drain on the grid clock, and put exhaustion in S-16. | Yes |
| C-34 | low | "Field hydraulic reset"; "kill drive power" | Add both | Yes |
| C-35 | low | Frazil needs "winter and open water" | Align the months | Yes |
| C-36 | low | "A fully implicit form errs the same amount the other way" | "…errs the other way, by more" | No |
| C-37 | low | Snippet starts `num = q`; "initialise with s[i] = beta[i] n" | Define q and the steady state with a source | No |
| C-38 | low | ≈ 6,300 thermal states | ≈ 6,200 | No |
| C-39 | low | Shim rods tagged SM; SG-2-HM-05 | Add sm, and an nn for loop meters | No |

---

## C-29: Trace-heating failures "1 per 2,000 zone-hours real"

**Inconsistency:** §0.2 (and `src/shared/Config/Clocks.luau`) put heater failures on ×360. For ≈ 180 zones that is one failure every 1.85 min instead of every 11.1 h (against §12.3 L2433 vs §0.2 L403).

**Type:** Physics
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Remove "heater failures" from §0.2's ×360 list (L403).
  - *Changes:* §0.2 L403
  - *Numbers:* Heater failure rate remains 1 per 2,000 zone-hours real, but is no longer scaled by 360x. Sourced from the audit script showing 1 every 1.85 min under 360x vs 1 every 11.1 h in real time.
  - *Costs:* None, as Config already uses the x360 side correctly.
- **B.** Keep heater failures on the ×360 clock, but reduce the base rate to '1 per 720,000 zone-hours real'.
  - *Changes:* §12.3 L2433
  - *Numbers:* Failure rate drops by a factor of 360 to match the intended playable rate when multiplied by the grid clock.
  - *Costs:* Requires an extremely low real-time failure rate to be printed in the spec, which might look physically unrealistic.

**Recommendation.** ★ A. Config already follows option A to avoid burying the operator, so this aligns the spec with the playable implementation without publishing an absurdly low physical failure rate.

## C-01: Trace-heating low alarm 150 °C

**Inconsistency:** Below §9.1's 180 °C floor and below the 160 °C plugging-temperature alarm (against §5.1 L1207; §9.1 L1673; §5.1 L1208).

**Type:** Physics
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Alarm at ≥ 180 °C, above the plugging alarm; state that cold traps are exempt from the 180 °C rule.
  - *Changes:* §5.1 L1207; §9.1 L1673; §5.1 L1208
  - *Numbers:* Secondary trace-heating alarm moves to ≥ 180 °C (from 150 °C). Sourced from §9.1 L1673 rule.
  - *Costs:* Adds a specific exception to §9.1 for cold traps (which run at 125 °C).
- **B.** Lower the plugging-temperature alarm to 140 °C.
  - *Changes:* §4.6
  - *Numbers:* Plugging-temperature alarm moves from 160 °C to 140 °C to sit below the trace-heating low alarm of 150 °C.
  - *Costs:* Requires normal operation at a tighter plugging margin or lower cold trap temperature, reducing impurity capture efficiency.

**Recommendation.** ★ A. It enforces the intended physics of avoiding precipitation in lines, matching §9.1's floor.

## C-02: 1 g/s leak adds +0.28 ppm at the section meter

**Inconsistency:** 0.2877 ppm (all hydrogen dissolved, 389 kg/s); the spec's own 0.036 ppm loop value implies 0.288 (against §5.2 L1226).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Print 0.29 ppm.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-03: Hydrogen drift and impurity ingress "per grid day"

**Inconsistency:** §0.2 puts both on ×360; the two readings are 30× apart (cold trap fills in 1,500 h or 50 h real) (against §5.2 L1228, §12.3 L2429 vs §0.2 L403).

**Type:** Gameplay
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Bind both to the real-time clock.
  - *Changes:* §0.2 L403; §12.3 L2429; §5.2 L1228
  - *Numbers:* Remove impurity ingress and hydrogen drift from the ×360 list. Impurity ingress remains 0.2 kg per real day. Sourced from the audit logic.
  - *Costs:* Reduces the frequency of trap filling and hydrogen drift, potentially making them non-factors during a normal play session.
- **B.** Bind both to the ×360 clock.
  - *Changes:* §12.3 L2429; §5.2 L1228
  - *Numbers:* Ingress becomes 0.2 kg per grid day (×360), trap fills in 50 h real. Sourced from §0.2's list.
  - *Costs:* Drift exceeds the whole 0.06 ppm full-power background rapidly, requiring active management.

**Recommendation.** ★ B. Option B is better because placing them on the fast clock makes these processes relevant to gameplay within a typical session.

## C-04: Reactor = SG total − 10.5 MW

**Inconsistency:** Pumps put 15.9 MW of shaft power into sodium (3 × 3.3 + 3 × 2.0) and DRACS standby takes out 1.2 MW, a net 14.7 MW; the secondary pumps' heat appears nowhere (against file 20 L3037 (feeds §5.1, §6.1)).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Add the secondary pumps' heat.
- **B.** State the 4.2 MW of losses that offset it.

**Recommendation.** ★ A.

## C-05: Pinch ≈ 20 K (sodium 360, saturation 340 °C)

**Inconsistency:** Saturation is taken at the EV outlet pressure (14.6 MPa); with boiling onset between 16.0 and 14.6 MPa the pinch is 16.9–20.2 K (against §6.1 L1253).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** "≈ 17–20 K".
- **B.** Evaluate saturation at the local pressure.

**Recommendation.** ★ A.

## C-06: Throttling a branch to 50 % costs about 6 MWe

**Inconsistency:** Second-law maximum m·T₀·Δs ≤ 1.08 MW for 145.8 kg/s and 0.7–0.8 MPa (2.2 MW for all of loop 2) (against §6.3 L1278 †).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** ≈ 1 MWe.
- **B.** Name the mechanism that costs 6 MWe.

**Recommendation.** ★ A.

## C-07: Isolating one SG2 section nudges each reheat by about 2 K

**Inconsistency:** File 20's reheater model: A moves 1.8–2.4 K, B moves 5.6–8.6 K (B has 4 modules, A has 12) (against §6.4 L1299).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** "≈ 2 K on A, 6–9 K on B".
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-08: B load limits 100/100/94/83/72/62 %

**Inconsistency:** These read §7.1's curve at the SG-outlet reheat temperature. At the IP stop valve (−5 K, where §7.2's 500 °C normal is) they are 100/100/89/78/67/56 %, and the 100 % row becomes 613 MWe, not 645 (against §6.5 L1303–1356; §7.1 L1402, L1411; §7.2 L1449).

**Type:** Physics
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** State where the limit and the 420 °C trip read (at the IP stop valve), then recompute the column.
  - *Changes:* §6.5 L1303–1356; §7.1 L1402, L1411; §7.2 L1449
  - *Numbers:* B load limits become 100/100/89/78/67/56 % (from 100/100/94/83/72/62 %). 100 % row becomes 613 MWe (from 645). Sourced from audit file 20 recomputation.
  - *Costs:* Lowers the stated 100% row capacity, but the recommended 60–70% split remains unaffected.
- **B.** Move the reading point to the SG outlet.
  - *Changes:* §7.1 L1402, L1411; §7.2 L1449
  - *Numbers:* Normal becomes 505 °C, alarm 485 °C, trip 425 °C at SG. Sourced from §6.1 SG reheat outlet.
  - *Costs:* The turbine control logic reading point moves, which might impact other interlocks.

**Recommendation.** ★ A. It keeps the spec consistent with file 20's actual cycle model and thermodynamics.

## C-09: 60 % row: A hot reheat 508 °C, not spraying

**Inconsistency:** Attemperation auto holds ≤ 505 °C; the column is the unsprayed module outlet (file 20 credits min(T, 505)) (against §6.5 L1317; §9.4 L1818).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Label the column "before sprays" and mark the 60 % row as spraying.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-10: Water admission: sodium ≥ 250 °C; feed ≥ sodium − 80 K

**Inconsistency:** Even at the SG sodium outlet it passes only at 100 %. At hot standby (375 °C) it needs feed ≥ 295 °C, so with 170–180 °C feed water can enter only with sodium at 250–260 °C (against §6.6 L1375; §7.5 L1545; §9.2).

**Type:** Gameplay
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Name the sodium location (SG inlet), state that the rule is first admission only, and give a hot re-admission path.
  - *Changes:* §6.6 L1375; §7.5 L1545; §9.2
  - *Numbers:* None, but clarifies that sodium ≥ 250 °C and feed ≥ sodium - 80 K applies to the inlet and only for first admission.
  - *Costs:* Requires creating a new hot re-admission procedure for returning a section to service at power.
- **B.** Change the limit to 'feed ≥ 170 °C' regardless of sodium temperature.
  - *Changes:* §6.6 L1375; §7.5 L1545; §9.2
  - *Numbers:* Removes the 80 K relative limit and replaces it with an absolute floor of 170 °C for feedwater admission.
  - *Costs:* Reduces realism by ignoring the thermal shock risk to the steam generator if cold feed hits hot sodium.

**Recommendation.** ★ A. It fixes a major functional hole by providing a valid path to recover from isolation while preserving the initial admission safety margins.

## C-11: Header 13.7 MPa; turbine auto holds header 13.5 ±0.2

**Inconsistency:** The normal header sits on the edge of the auto band; 13.5 is §6.2's stop-valve pressure (against §6.2 L1263; §9.4 L1824).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Header setpoint 13.7 ±0.2.
- **B.** Say the auto holds stop-valve pressure.

**Recommendation.** ★ A.

## C-12: Generator trips above 52 Hz

**Inconsistency:** The time-limited range ends at 51.5 Hz, so 51.5–52 Hz is neither permitted nor tripped (the low side matches at 47.5 Hz) (against §7.2 L1456–1457; §8.4 L1617).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Trip at 51.5 Hz with a delay.
- **B.** Extend the range.

**Recommendation.** ★ A.

## C-13: Hot-reheat alarm fixed at 480 °C

**Inconsistency:** At the 30 % row reheat is ≤ 484 °C at the SG, ≤ 479 °C at the IP stop valve: a standing alarm in a normal state (against §7.2 L1451; §9.2 L1718).

**Type:** Physics
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Let the hot-reheat alarm track the programme below 40 %, as main steam's does.
  - *Changes:* §7.2 L1451; §9.2 L1718
  - *Numbers:* Hot-reheat alarm becomes a programmed curve tracking below 40% instead of a fixed 480 °C. Sourced from the main-steam alarm logic.
  - *Costs:* Adds slight complexity to the alarm logic implementation.
- **B.** Raise the hot-reheat alarm to 495 °C and keep it fixed.
  - *Changes:* §7.2 L1451; §9.2 L1718
  - *Numbers:* Hot-reheat alarm becomes 495 °C fixed, clearing the 484 °C state at 30% load.
  - *Costs:* Provides very little margin below the 500 °C normal state at full load, leading to frequent nuisance alarms during small transients.

**Recommendation.** ★ A. It eliminates a false standing alarm in a normal operating state without causing nuisance alarms at high power.

## C-14: One unit runs at house load ≈ 65 MWe

**Inconsistency:** 65 MWe is 13 % of a unit, against a 30 % (150 MWe) minimum stable load; §9.2 calls the same rows both "turbines off" and "house-load states" (against §7.3 L1468–1469; S-28 L2690; §7.1 L1405; §9.2 L1679–1680).

**Type:** Gameplay
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Exempt house-load operation from the minimum for a stated time.
  - *Changes:* §7.3 L1468–1469; §9.2 L1679–1680
  - *Numbers:* Exempts 65 MWe from the 30% (150 MWe) minimum. Rewords §9.2 to not call 65 MWe "turbines off". Sourced from audit logic.
  - *Costs:* Allows a turbine to operate below its minimum stable load during specific house-load scenarios.
- **B.** Increase house load electrical draw to ~150 MWe by adding dummy load banks.
  - *Changes:* §1.1; §7.3 L1468–1469
  - *Numbers:* Adds ~85 MWe of artificial house load to keep the turbine above its 150 MWe minimum stable load.
  - *Costs:* Completely changes the plant design by requiring massive load banks and altering the emergency power balance.

**Recommendation.** ★ A. It allows the house-load scenario (a core operational feature) to function without tripping the turbine or radically changing plant design.

## C-15: Poor crew: "Condenser B overloaded, second trip"

**Inconsistency:** The bypass is sized 60 %, which the condenser absorbs indefinitely. Its rule needs 110 % bypass for the 10 kPa alarm and 210 % for the trip (against S-05 L2530; §7.3 L1464–1465).

**Type:** Physics
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Add a mechanism, e.g. degraded cooling water.
  - *Changes:* S-05 L2530
  - *Numbers:* Specifies that S-05 includes a cooling water failure. Sourced from audit analysis showing normal CW absorbs 60% bypass indefinitely.
  - *Costs:* Makes S-05 a more complex scenario involving CW degradation instead of just a crew error.
- **B.** Change the outcome (SG relief, reactor trip).
  - *Changes:* S-05 L2530
  - *Numbers:* Removes the condenser overload trip. Sourced from the bypass sizing rules.
  - *Costs:* Changes the S-05 scenario narrative significantly.

**Recommendation.** ★ A. Adding a degraded CW mechanism keeps the scenario's intended outcome (condenser overload) intact while making it physically possible.

## C-16: 15.3 m³/s, 11 K rise, 690 MWt

**Inconsistency:** File 20 uses cp 4.0 and ρ 1025 (ocean water). With 5 psu water (TEOS-10: 4.153, 1,001), 11.0 K needs 15.08 m³/s; the pair survives only through rounding (10.84 K) (against §7.4 L1478; file 20 L3101).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Use 5 psu properties; print 15.1 m³/s.
- **B.** 10.8 K.

**Recommendation.** ★ A.

## C-17: LP2 feed out 91 °C; 90 % row A reheat 516 °C

**Inconsistency:** 90.49 °C and 515.46 °C: file 20 printed them at one decimal (90.5, 515.5), then rounded again (against §7.5 L1525; §6.5 L1338).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** 90 °C and 515 °C.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-18: Train B lost: turbine A takes 437.5 kg/s, "the rest goes to bypass"

**Inconsistency:** The rest (145.9 kg/s) is exactly SG2's B branch, which CV-2B still routes to turbine B. SG3 is left with no feed path, and no reactor power is stated (against §7.6 L1558–1560).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** State turbine B's status, SG3's feed source and the runback.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-19: House load: feed pumps 19.6, primary 10.3, secondary 6.2

**Inconsistency:** Primary and secondary are electrical (shaft × 1.04, × 1.03); feed is absorbed power (× 1.00). On one basis feed draws 20.4 MWe (against §1.1 L464; §7.6 L1552).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** List the feed pumps at electrical input and trim "everything else".
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-20: Unit boards fast-transfer to station boards via ST-1, 60 MVA

**Inconsistency:** A double unit trip puts the full 65 MWe house load on 60 MVA (76 MVA at 0.85 pf). It fits only after the feed pumps (19.6 MW) run down (against §8.1 L1579–1581).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Size ST-1 ≥ 77 MVA.
- **B.** State the load shedding on transfer.

**Recommendation.** ★ A.

## C-21: "178, 86 and 42 MWe are under the 150 MWe minimum … their steam is below the reheat trip"

**Inconsistency:** 178 > 150 on one turbine; the 20 % row's main steam 440 °C (435 °C at the stop valve) is above both trips. Two turbines both reach 150 MWe only above 32.8 %FP, so the "turbines on" 30 % row is a one-turbine state (against §9.2 L1679–1681 (Rev A4 text of F22)).

**Type:** Physics
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Give the true reason: below ≈ 33 %FP two turbines cannot both hold 150 MWe.
  - *Changes:* §9.2 L1679–1681
  - *Numbers:* Updates the rationale for the cut-off. Sourced from file 20's MWe formula showing 300 MWe needs 32.8 %FP.
  - *Costs:* None, it corrects the explanation without changing the accepted F22 operational decision (the ~25% cut-off).
- **B.** Change the minimum stable load of the turbines to 40 MWe.
  - *Changes:* §7.1 L1405; §9.2 L1679-1681
  - *Numbers:* Turbine minimum load moves from 150 MWe to 40 MWe.
  - *Costs:* Violates the physical realities of large steam turbines which cannot run stably at 8% capacity, breaking realism.

**Recommendation.** ★ A. It provides the correct physical justification for the operational rule without breaking turbine realism.

## C-22: "No two desks that have to talk during a fault can see each other"

**Inconsistency:** The same table seats reactor, primary and SS together (MCR), secondary sodium and SG together (SGCR), and turbine A and B together (TCR) (against §10.1 L2029).

**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** "No two rooms whose desks…".
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-23: Planned curtailment (e.g. −200 MWe) announced a grid-hour ahead

**Inconsistency:** A grid-hour is 5 min real; 200 MWe takes 20 min at 1 %/min and 6.7 min at the approved 3 %/min (against §11.1 L2294).

**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** State the deadline; notice ≥ 4 grid-hours for 200 MWe.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-24: Dispatch error counts |MW − target| beyond 10 MW

**Inconsistency:** Contracted reserves move the plant up to FCR-N ±20, FCR-D 50 and aFRR ±20 MWe; "target" is not said to include them (against §11.3 L2330; §8.4 L1626–1636).

**Type:** Gameplay
**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** Target = dispatch setpoint + expected reserve response.
  - *Changes:* §11.3 L2330
  - *Numbers:* Redefines "target" to include reserve response. Sourced from §11.2 logic.
  - *Costs:* Makes the dispatch error calculation slightly more complex.
- **B.** Keep the spec text and document it.
  - *Changes:* None
  - *Numbers:* None
  - *Costs:* Penalizes the player's dispatch score when they correctly provide contracted frequency reserves. This is acceptable only if the game intends to force the operator to constantly manually offset frequency response to maintain their dispatch score (adds difficulty).

**Recommendation.** ★ A. It ensures players are not penalized for correctly delivering requested grid reserves, providing a fairer challenge.

## C-25: Poor crew: under-frequency trip

**Inconsistency:** That needs < 47.5 Hz for 20 s. The cue is 49.6 Hz, §11.2's worst nadir is 49.55 Hz, and load shedding starts at 48.8 Hz (against S-18 L2618, L2621).

**Type:** Physics
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Change the outcome in S-18.
  - *Changes:* S-18 L2618, L2621
  - *Numbers:* Removes the under-frequency trip from the S-18 poor crew outcome. Sourced from §8.4 limits.
  - *Costs:* Changes the penalty for a poor crew in S-18.
- **B.** Add a collapse path below 47.5 Hz.
  - *Changes:* §11.2
  - *Numbers:* Extends grid events to include a nadir below 47.5 Hz. Sourced from the generator trip setting.
  - *Costs:* Introduces deeper grid frequency collapses than currently planned.

**Recommendation.** ★ A. It is cleaner to fix the scenario than to rewrite the entire grid frequency simulation bounds.

## C-26: Striping: adjacent outlets > 40 K apart add 1/5,000 per minute

**Inconsistency:** No clock: U = 1 after 83 h (real) or 6.9 h (grid). "Assemblies" is undefined: a rod position (5.35 kg/s) would need 0.98 MW of its own heat to sit within 40 K of a 559 °C neighbour (against §12.1 L2407–2408).

**Type:** Gameplay
**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** Mark the clock (grid) and say "fuel assemblies".
  - *Changes:* §12.1 L2407–2408
  - *Numbers:* Specifies grid clock (6.9 h real to U=1) and clarifies it applies to fuel assemblies. Sourced from F26 resolution.
  - *Costs:* Removes ambiguity but still charges damage rapidly during normal power gradients.
- **B.** Give rod positions an outlet temperature.
  - *Changes:* §12.1 L2407–2408
  - *Numbers:* Assigns a simulated heat to rod positions to match fuel neighbours. Sourced from audit analysis (0.98 MW).
  - *Costs:* Requires new thermal simulation logic for non-fuel positions.

**Recommendation.** ★ A. It resolves the ambiguity using the simplest textual clarification without adding new simulation systems.

## C-27: Random failure × "overpower multiplier"

**Inconsistency:** The phrase appears once in the spec and is never defined (against §12.2 L2416–2417).

**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** Define it.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-28: Scan one group of 7 every 2 min; LCO-12: ≤ 30 %FP and locate within 8 grid-h

**Inconsistency:** 301/7 = 43 groups: 86 min real (mean 44) against 40 min real; found in time with probability 47 % (against §12.2 L2422–2423; LCO-12 L1992–1995).

**Type:** Gameplay
**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** ≤ 55 s per group, "2 grid-min".
  - *Changes:* §12.2 L2422–2423
  - *Numbers:* Scan time reduces to 55 s per group (2 grid-min). Sourced from audit calculation (43 groups in 40 min).
  - *Costs:* Speeds up the simulated scanning process significantly.
- **B.** Specify a longer completion time in LCO-12.
  - *Changes:* LCO-12 L1992–1995
  - *Numbers:* Extends the locate time beyond 8 grid-hours. Sourced from the 86 min real required for a full scan.
  - *Costs:* Alters the LCO compliance window, making the fault more lenient.

**Recommendation.** ★ A. It ensures the scan can actually complete within the LCO-12 window (100% probability) rather than failing half the time by pure chance.

## C-30: Plugging temperature +2 K per 10 % loading above 70 %; S-13 ends in an LCO-6 derate

**Inconsistency:** +6 K at 100 %. LCO-6 (125 → 180 °C) needs 345 % loading; the alarms need 195 % and 170 % (against §12.3 L2431; S-13 L2586; LCO-6 L1968–1971).

**Type:** Physics
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Add the mechanism (ingress with a full trap).
  - *Changes:* §12.3 L2431
  - *Numbers:* Specifies that the +2 K rule applies when the trap is full. Sourced from audit logic.
  - *Costs:* Requires tracking trap capacity strictly to trigger the S-13 derate.
- **B.** Change S-13's outcome.
  - *Changes:* S-13 L2586
  - *Numbers:* Removes the LCO-6 derate from the S-13 poor crew outcome.
  - *Costs:* Simplifies S-13 but loses the intended penalty.

**Recommendation.** ★ A. It provides the missing physical link for how a trap reaches LCO-6 limits without breaking the scenario.

## C-31: "Drained line" freezes in ≈ 40 min

**Inconsistency:** A drained line holds no sodium (against §12.3 L2435; S-12 L2574).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** "Filled line with heater off".
- **B.** "drain line".

**Recommendation.** ★ A.

## C-32: Small leak: neighbour penetrated in 10–30 min at 1 g/s, 1–3 min at 10 g/s

**Inconsistency:** §0.2 binds §12.4 to the grid clock but reads unmarked windows as real time: 50–150 s or 10–30 min real (12×) (against §12.4 L2445–2446 vs §0.2 L404–406).

**Type:** Gameplay
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Mark each figure real time.
  - *Changes:* §12.4 L2445–2446
  - *Numbers:* Times become 10-30 min real (1 g/s) and 1-3 min real (10 g/s). Sourced from spec text context.
  - *Costs:* Overrules §0.2's grid clock binding for this section.
- **B.** Mark each figure grid clock.
  - *Changes:* §12.4 L2445–2446
  - *Numbers:* Times become 50-150 s real (1 g/s) and 5-15 s real (10 g/s). Sourced from §0.2.
  - *Costs:* Makes the leak progression extremely fast, giving operators very little real time to react.

**Recommendation.** ★ A. It gives players a reasonable real-time window to respond to leaks, which aligns with S-01's 20-60 min window.

## C-33: SBO window ≈ 6.5 h, ≈ 40 min at ×10

**Inconsistency:** At ×1 the UPS (2 h) and DC (4 h) run out before the pool limit. At ×10 electrical stays ×1 (§0.2), so they never run out (against S-16 L2605; §8.3 L1605–1606; §0.2 L393–396).

**Type:** Gameplay
**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** State that batteries drain on the grid clock, and put exhaustion in S-16.
  - *Changes:* §8.3 L1605–1606; S-16 L2605
  - *Numbers:* Batteries run out based on grid time, meaning they exhaust before the pool limit at ×10. Sourced from audit logic.
  - *Costs:* Changes the SBO scenario to include battery exhaustion.
- **B.** State that batteries drain on real time.
  - *Changes:* §8.3 L1605–1606
  - *Numbers:* Batteries last for their real-time rating regardless of simulation speed. Sourced from §0.2 electrical x1 rule.
  - *Costs:* The crew never goes blind during a ×10 blackout before the pool limit is reached.

**Recommendation.** ★ A. It makes the S-16 SBO scenario play consistently regardless of the time multiplier used.

## C-34: "Field hydraulic reset"; "kill drive power"

**Inconsistency:** Neither appears in §10.3 (local actions) or §10.2 (desk controls) (against S-06 L2536; S-19 L2627).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Add both.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-35: Frazil needs "winter and open water"

**Inconsistency:** That leaves December only; §1.7 has frazil risk from November (against §13.1 L2479–2480; §1.7 L605; §1.4 L531–532).

**Blocks steam plant:** Yes, concerns secondary systems or infrastructure built with the steam plant.

**Options.**
- **A.** Align the months.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-36: "A fully implicit form errs the same amount the other way"

**Inconsistency:** +15.3 % and +45.5 %, against −11.4 % and −21.7 % for held n (against §14.2 L2738–2739).

**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** "…errs the other way, by more".
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-37: Snippet starts `num = q`; "initialise with s[i] = beta[i] n"

**Inconsistency:** `q` (an external source) is never defined; that initialisation is steady only with q = 0 at ρ = 0 (against §14.2 L2740, L2757).

**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** Define q and the steady state with a source.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-38: ≈ 6,300 thermal states

**Inconsistency:** The listed blocks sum to 6,199 (against §14.3 L2796).

**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** ≈ 6,200.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-39: Shim rods tagged SM; SG-2-HM-05

**Inconsistency:** SM is in neither code list; the 3 loop-outlet meters (27 = 24 + 3) have no NN rule (against App. B L2926–2933, L2952).

**Blocks steam plant:** No, does not concern systems built with the steam plant.

**Options.**
- **A.** Add SM, and an NN for loop meters.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.
