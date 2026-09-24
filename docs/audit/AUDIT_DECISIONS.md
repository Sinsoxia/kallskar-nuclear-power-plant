# Decisions needed for the unbuilt sections audit

These are the open findings (C-01 to C-39) from `docs/audit/SPEC_AUDIT_UNBUILT.md` (the unbuilt sections: §5–§8, §10–§13, file 16). They are prepared here for Aqua's decision.

| ID | Sev. | Question | Recommendation | Blocks steam plant? |
|---|---|---|---|---|
| C-29 | high | Trace-heating failures "1 per 2,000 zone-hours real" | Remove "heater failures" from §0.2's ×360 list | No |
| C-01 | medium | Trace-heating low alarm 150 °C | Alarm at ≥ 180 °C, above the plugging alarm; state that cold traps are exempt from the 180 °C rule | Yes |
| C-02 | low | 1 g/s leak adds +0.28 ppm at the section meter | Print 0.29 ppm | Yes |
| C-03 | medium | Hydrogen drift and impurity ingress "per grid day" | Choose one clock per process and reword whichever section loses | Yes |
| C-04 | low | Reactor = SG total − 10.5 MW | Add the secondary pumps' heat | Yes |
| C-05 | low | Pinch ≈ 20 K (sodium 360, saturation 340 °C) | "≈ 17–20 K" | Yes |
| C-06 | low | Throttling a branch to 50 % costs about 6 MWe | ≈ 1 MWe | Yes |
| C-07 | low | Isolating one SG2 section nudges each reheat by about 2 K | "≈ 2 K on A, 6–9 K on B" | Yes |
| C-08 | medium | B load limits 100/100/94/83/72/62 % | State where the limit and the 420 °C trip read, then recompute the column | Yes |
| C-09 | low | 60 % row: A hot reheat 508 °C, not spraying | Label the column "before sprays" and mark the 60 % row as spraying | Yes |
| C-10 | medium | Water admission: sodium ≥ 250 °C; feed ≥ sodium − 80 K | Name the sodium location, state that the rule is first admission only, and give a hot re-admission path | Yes |
| C-11 | low | Header 13.7 MPa; turbine auto holds header 13.5 ±0.2 | Header setpoint 13.7 ±0.2 | Yes |
| C-12 | low | Generator trips above 52 Hz | Trip at 51.5 Hz with a delay | Yes |
| C-13 | medium | Hot-reheat alarm fixed at 480 °C | Let the hot-reheat alarm track the programme below 40 %, as main steam's does | Yes |
| C-14 | medium | One unit runs at house load ≈ 65 MWe | Exempt house-load operation from the minimum for a stated time, and fix §9.2's sentence | Yes |
| C-15 | medium | Poor crew: "Condenser B overloaded, second trip" | Change the outcome (SG relief, reactor trip) | Yes |
| C-16 | low | 15.3 m³/s, 11 K rise, 690 MWt | Use 5 psu properties; print 15.1 m³/s | Yes |
| C-17 | low | LP2 feed out 91 °C; 90 % row A reheat 516 °C | 90 °C and 515 °C | Yes |
| C-18 | low | Train B lost: turbine A takes 437.5 kg/s, "the rest goes to bypass" | State turbine B's status, SG3's feed source and the runback | Yes |
| C-19 | low | House load: feed pumps 19.6, primary 10.3, secondary 6.2 | List the feed pumps at electrical input and trim "everything else" | Yes |
| C-20 | low | Unit boards fast-transfer to station boards via ST-1, 60 MVA | Size ST-1 ≥ 77 MVA | Yes |
| C-21 | medium | "178, 86 and 42 MWe are under the 150 MWe minimum … their steam is below the reheat trip" | Give the true reason: below ≈ 33 %FP two turbines cannot both hold 150 MWe; the ≈ 25 %FP cut-off for the last turbine is F22's decision, not a consequence of 150 MWe | No |
| C-22 | low | "No two desks that have to talk during a fault can see each other" | "No two rooms whose desks…" | No |
| C-23 | low | Planned curtailment (e.g. −200 MWe) announced a grid-hour ahead | State the deadline; notice ≥ 4 grid-hours for 200 MWe | No |
| C-24 | medium | Dispatch error counts |MW − target| beyond 10 MW | Target = dispatch setpoint + expected reserve response (§11.2) | Yes |
| C-25 | medium | Poor crew: under-frequency trip | Add the collapse path below 47.5 Hz | No |
| C-26 | medium | Striping: adjacent outlets > 40 K apart add 1/5,000 per minute | Mark the clock and say "fuel assemblies" | No |
| C-27 | low | Random failure × "overpower multiplier" | Define it | No |
| C-28 | medium | Scan one group of 7 every 2 min; LCO-12: ≤ 30 %FP and locate within 8 grid-h | ≤ 55 s per group, "2 grid-min" | No |
| C-30 | medium | Plugging temperature +2 K per 10 % loading above 70 %; S-13 ends in an LCO-6 derate | Add the mechanism (ingress with a full trap) | No |
| C-31 | low | "Drained line" freezes in ≈ 40 min | "Filled line with heater off" | No |
| C-32 | medium | Small leak: neighbour penetrated in 10–30 min at 1 g/s, 1–3 min at 10 g/s | Mark each figure grid | No |
| C-33 | medium | SBO window ≈ 6.5 h, ≈ 40 min at ×10 | State which clock drains batteries, and put exhaustion in S-16 | Yes |
| C-34 | low | "Field hydraulic reset"; "kill drive power" | Add both | No |
| C-35 | low | Frazil needs "winter and open water" | Align the months | No |
| C-36 | low | "A fully implicit form errs the same amount the other way" | "…errs the other way, by more" | No |
| C-37 | low | Snippet starts `num = q`; "initialise with s[i] = beta[i] n" | Define q and the steady state with a source | No |
| C-38 | low | ≈ 6,300 thermal states | ≈ 6,200 | No |
| C-39 | low | Shim rods tagged SM; SG-2-HM-05 | Add SM, and an NN for loop meters | No |

---

## C-29: Trace-heating failures "1 per 2,000 zone-hours real"

**Inconsistency:** §0.2 (and `src/shared/Config/Clocks.luau`) put heater failures on ×360. For ≈ 180 zones that is one failure every 1.85 min instead of every 11.1 h (against §12.3 L2433 vs §0.2 L403).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Remove "heater failures" from §0.2's ×360 list.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-01: Trace-heating low alarm 150 °C

**Inconsistency:** Below §9.1's 180 °C floor and below the 160 °C plugging-temperature alarm (against §5.1 L1207; §9.1 L1673; §5.1 L1208).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Alarm at ≥ 180 °C, above the plugging alarm; state that cold traps are exempt from the 180 °C rule.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-02: 1 g/s leak adds +0.28 ppm at the section meter

**Inconsistency:** 0.2877 ppm (all hydrogen dissolved, 389 kg/s); the spec's own 0.036 ppm loop value implies 0.288 (against §5.2 L1226).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Print 0.29 ppm.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-03: Hydrogen drift and impurity ingress "per grid day"

**Inconsistency:** §0.2 puts both on ×360; the two readings are 30× apart (cold trap fills in 1,500 h or 50 h real) (against §5.2 L1228, §12.3 L2429 vs §0.2 L403).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Choose one clock per process and reword whichever section loses.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-04: Reactor = SG total − 10.5 MW

**Inconsistency:** Pumps put 15.9 MW of shaft power into sodium (3 × 3.3 + 3 × 2.0) and DRACS standby takes out 1.2 MW, a net 14.7 MW; the secondary pumps' heat appears nowhere (against file 20 L3037 (feeds §5.1, §6.1)).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Add the secondary pumps' heat.
- **B.** State the 4.2 MW of losses that offset it.

**Recommendation.** ★ A.

## C-05: Pinch ≈ 20 K (sodium 360, saturation 340 °C)

**Inconsistency:** Saturation is taken at the EV outlet pressure (14.6 MPa); with boiling onset between 16.0 and 14.6 MPa the pinch is 16.9–20.2 K (against §6.1 L1253).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** "≈ 17–20 K".
- **B.** Evaluate saturation at the local pressure.

**Recommendation.** ★ A.

## C-06: Throttling a branch to 50 % costs about 6 MWe

**Inconsistency:** Second-law maximum m·T₀·Δs ≤ 1.08 MW for 145.8 kg/s and 0.7–0.8 MPa (2.2 MW for all of loop 2) (against §6.3 L1278 †).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** ≈ 1 MWe.
- **B.** Name the mechanism that costs 6 MWe.

**Recommendation.** ★ A.

## C-07: Isolating one SG2 section nudges each reheat by about 2 K

**Inconsistency:** File 20's reheater model: A moves 1.8–2.4 K, B moves 5.6–8.6 K (B has 4 modules, A has 12) (against §6.4 L1299).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** "≈ 2 K on A, 6–9 K on B".
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-08: B load limits 100/100/94/83/72/62 %

**Inconsistency:** These read §7.1's curve at the SG-outlet reheat temperature. At the IP stop valve (−5 K, where §7.2's 500 °C normal is) they are 100/100/89/78/67/56 %, and the 100 % row becomes 613 MWe, not 645 (against §6.5 L1303–1356; §7.1 L1402, L1411; §7.2 L1449).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** State where the limit and the 420 °C trip read, then recompute the column.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-09: 60 % row: A hot reheat 508 °C, not spraying

**Inconsistency:** Attemperation auto holds ≤ 505 °C; the column is the unsprayed module outlet (file 20 credits min(T, 505)) (against §6.5 L1317; §9.4 L1818).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Label the column "before sprays" and mark the 60 % row as spraying.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-10: Water admission: sodium ≥ 250 °C; feed ≥ sodium − 80 K

**Inconsistency:** Even at the SG sodium outlet it passes only at 100 %. At hot standby (375 °C) it needs feed ≥ 295 °C, so with 170–180 °C feed water can enter only with sodium at 250–260 °C (against §6.6 L1375; §7.5 L1545; §9.2).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Name the sodium location, state that the rule is first admission only, and give a hot re-admission path.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-11: Header 13.7 MPa; turbine auto holds header 13.5 ±0.2

**Inconsistency:** The normal header sits on the edge of the auto band; 13.5 is §6.2's stop-valve pressure (against §6.2 L1263; §9.4 L1824).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Header setpoint 13.7 ±0.2.
- **B.** Say the auto holds stop-valve pressure.

**Recommendation.** ★ A.

## C-12: Generator trips above 52 Hz

**Inconsistency:** The time-limited range ends at 51.5 Hz, so 51.5–52 Hz is neither permitted nor tripped (the low side matches at 47.5 Hz) (against §7.2 L1456–1457; §8.4 L1617).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Trip at 51.5 Hz with a delay.
- **B.** Extend the range.

**Recommendation.** ★ A.

## C-13: Hot-reheat alarm fixed at 480 °C

**Inconsistency:** At the 30 % row reheat is ≤ 484 °C at the SG, ≤ 479 °C at the IP stop valve: a standing alarm in a normal state (against §7.2 L1451; §9.2 L1718).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Let the hot-reheat alarm track the programme below 40 %, as main steam's does.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-14: One unit runs at house load ≈ 65 MWe

**Inconsistency:** 65 MWe is 13 % of a unit, against a 30 % (150 MWe) minimum stable load; §9.2 calls the same rows both "turbines off" and "house-load states" (against §7.3 L1468–1469; S-28 L2690; §7.1 L1405; §9.2 L1679–1680).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Exempt house-load operation from the minimum for a stated time, and fix §9.2's sentence.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-15: Poor crew: "Condenser B overloaded, second trip"

**Inconsistency:** The bypass is sized 60 %, which the condenser absorbs indefinitely. Its rule needs 110 % bypass for the 10 kPa alarm and 210 % for the trip (against S-05 L2530; §7.3 L1464–1465).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Change the outcome (SG relief, reactor trip).
- **B.** Add the mechanism, e.g. degraded CW.

**Recommendation.** ★ A.

## C-16: 15.3 m³/s, 11 K rise, 690 MWt

**Inconsistency:** File 20 uses cp 4.0 and ρ 1025 (ocean water). With 5 psu water (TEOS-10: 4.153, 1,001), 11.0 K needs 15.08 m³/s; the pair survives only through rounding (10.84 K) (against §7.4 L1478; file 20 L3101).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Use 5 psu properties; print 15.1 m³/s.
- **B.** 10.8 K.

**Recommendation.** ★ A.

## C-17: LP2 feed out 91 °C; 90 % row A reheat 516 °C

**Inconsistency:** 90.49 °C and 515.46 °C: file 20 printed them at one decimal (90.5, 515.5), then rounded again (against §7.5 L1525; §6.5 L1338).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** 90 °C and 515 °C.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-18: Train B lost: turbine A takes 437.5 kg/s, "the rest goes to bypass"

**Inconsistency:** The rest (145.9 kg/s) is exactly SG2's B branch, which CV-2B still routes to turbine B. SG3 is left with no feed path, and no reactor power is stated (against §7.6 L1558–1560).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** State turbine B's status, SG3's feed source and the runback.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-19: House load: feed pumps 19.6, primary 10.3, secondary 6.2

**Inconsistency:** Primary and secondary are electrical (shaft × 1.04, × 1.03); feed is absorbed power (× 1.00). On one basis feed draws 20.4 MWe (against §1.1 L464; §7.6 L1552).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** List the feed pumps at electrical input and trim "everything else".
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-20: Unit boards fast-transfer to station boards via ST-1, 60 MVA

**Inconsistency:** A double unit trip puts the full 65 MWe house load on 60 MVA (76 MVA at 0.85 pf). It fits only after the feed pumps (19.6 MW) run down (against §8.1 L1579–1581).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Size ST-1 ≥ 77 MVA.
- **B.** State the load shedding on transfer.

**Recommendation.** ★ A.

## C-21: "178, 86 and 42 MWe are under the 150 MWe minimum … their steam is below the reheat trip"

**Inconsistency:** 178 > 150 on one turbine; the 20 % row's main steam 440 °C (435 °C at the stop valve) is above both trips. Two turbines both reach 150 MWe only above 32.8 %FP, so the "turbines on" 30 % row is a one-turbine state (against §9.2 L1679–1681 (Rev A4 text of F22)).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Give the true reason: below ≈ 33 %FP two turbines cannot both hold 150 MWe; the ≈ 25 %FP cut-off for the last turbine is F22's decision, not a consequence of 150 MWe.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-22: "No two desks that have to talk during a fault can see each other"

**Inconsistency:** The same table seats reactor, primary and SS together (MCR), secondary sodium and SG together (SGCR), and turbine A and B together (TCR) (against §10.1 L2029).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** "No two rooms whose desks…".
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-23: Planned curtailment (e.g. −200 MWe) announced a grid-hour ahead

**Inconsistency:** A grid-hour is 5 min real; 200 MWe takes 20 min at 1 %/min and 6.7 min at the approved 3 %/min (against §11.1 L2294).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** State the deadline; notice ≥ 4 grid-hours for 200 MWe.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-24: Dispatch error counts |MW − target| beyond 10 MW

**Inconsistency:** Contracted reserves move the plant up to FCR-N ±20, FCR-D 50 and aFRR ±20 MWe; "target" is not said to include them (against §11.3 L2330; §8.4 L1626–1636).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** Target = dispatch setpoint + expected reserve response (§11.2).
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-25: Poor crew: under-frequency trip

**Inconsistency:** That needs < 47.5 Hz for 20 s. The cue is 49.6 Hz, §11.2's worst nadir is 49.55 Hz, and load shedding starts at 48.8 Hz (against S-18 L2618, L2621).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Add the collapse path below 47.5 Hz.
- **B.** Change the outcome.

**Recommendation.** ★ A.

## C-26: Striping: adjacent outlets > 40 K apart add 1/5,000 per minute

**Inconsistency:** No clock: U = 1 after 83 h (real) or 6.9 h (grid). "Assemblies" is undefined: a rod position (5.35 kg/s) would need 0.98 MW of its own heat to sit within 40 K of a 559 °C neighbour (against §12.1 L2407–2408).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Mark the clock and say "fuel assemblies".
- **B.** Give rod positions an outlet temperature.

**Recommendation.** ★ A.

## C-27: Random failure × "overpower multiplier"

**Inconsistency:** The phrase appears once in the spec and is never defined (against §12.2 L2416–2417).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Define it.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-28: Scan one group of 7 every 2 min; LCO-12: ≤ 30 %FP and locate within 8 grid-h

**Inconsistency:** 301/7 = 43 groups: 86 min real (mean 44) against 40 min real; found in time with probability 47 % (against §12.2 L2422–2423; LCO-12 L1992–1995).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** ≤ 55 s per group, "2 grid-min".
- **B.** A longer completion time.

**Recommendation.** ★ A.

## C-30: Plugging temperature +2 K per 10 % loading above 70 %; S-13 ends in an LCO-6 derate

**Inconsistency:** +6 K at 100 %. LCO-6 (125 → 180 °C) needs 345 % loading; the alarms need 195 % and 170 % (against §12.3 L2431; S-13 L2586; LCO-6 L1968–1971).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Add the mechanism (ingress with a full trap).
- **B.** Change S-13's outcome.

**Recommendation.** ★ A.

## C-31: "Drained line" freezes in ≈ 40 min

**Inconsistency:** A drained line holds no sodium (against §12.3 L2435; S-12 L2574).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** "Filled line with heater off".
- **B.** "drain line".

**Recommendation.** ★ A.

## C-32: Small leak: neighbour penetrated in 10–30 min at 1 g/s, 1–3 min at 10 g/s

**Inconsistency:** §0.2 binds §12.4 to the grid clock but reads unmarked windows as real time: 50–150 s or 10–30 min real (12×) (against §12.4 L2445–2446 vs §0.2 L404–406).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Mark each figure grid.
- **B.** Real.

**Recommendation.** ★ A.

## C-33: SBO window ≈ 6.5 h, ≈ 40 min at ×10

**Inconsistency:** At ×1 the UPS (2 h) and DC (4 h) run out before the pool limit. At ×10 electrical stays ×1 (§0.2), so they never run out (against S-16 L2605; §8.3 L1605–1606; §0.2 L393–396).

**Blocks steam plant:** Yes, affects the §5–§8 sections to be built next.

**Options.**
- **A.** State which clock drains batteries, and put exhaustion in S-16.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-34: "Field hydraulic reset"; "kill drive power"

**Inconsistency:** Neither appears in §10.3 (local actions) or §10.2 (desk controls) (against S-06 L2536; S-19 L2627).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Add both.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-35: Frazil needs "winter and open water"

**Inconsistency:** That leaves December only; §1.7 has frazil risk from November (against §13.1 L2479–2480; §1.7 L605; §1.4 L531–532).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Align the months.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-36: "A fully implicit form errs the same amount the other way"

**Inconsistency:** +15.3 % and +45.5 %, against −11.4 % and −21.7 % for held n (against §14.2 L2738–2739).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** "…errs the other way, by more".
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-37: Snippet starts `num = q`; "initialise with s[i] = beta[i] n"

**Inconsistency:** `q` (an external source) is never defined; that initialisation is steady only with q = 0 at ρ = 0 (against §14.2 L2740, L2757).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Define q and the steady state with a source.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-38: ≈ 6,300 thermal states

**Inconsistency:** The listed blocks sum to 6,199 (against §14.3 L2796).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** ≈ 6,200.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.

## C-39: Shim rods tagged SM; SG-2-HM-05

**Inconsistency:** SM is in neither code list; the 3 loop-outlet meters (27 = 24 + 3) have no NN rule (against App. B L2926–2933, L2952).

**Blocks steam plant:** No, can wait.

**Options.**
- **A.** Add SM, and an NN for loop meters.
- **B.** Keep the spec text and document the inconsistency.

**Recommendation.** ★ A.
