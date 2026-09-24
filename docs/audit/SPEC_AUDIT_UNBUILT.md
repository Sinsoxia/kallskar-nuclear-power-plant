# Spec audit: the sections the code has not reached

Audited text: `KALLSKAR_ALL_IN_ONE.txt` at commit `8a2a982` (Rev A5 content; the split files in `kallskar_handoff/`
are byte-identical to it). Line numbers below are lines of that file.

**Scope:** §5–§8, §10–§13 and file 16 (except Appendix A), plus every cross-reference from those sections into
§0–§4 and §9.1–§9.6. §9 has no subsections after 9.6, so §9 appears here only through cross-references. Already
reported, and not repeated: F1–F37 and D-001–D-044 (`docs/DECISIONS.md`), every claim in `docs/SPEC_REVIEW_AUDIT.md`,
and `docs/FINAL_DECISIONS_REV_A5.md`. P-01 and P-02 are errors in those documents.

**Method:** every number was recomputed by `tools/audit/spec_audit_unbuilt.py` (output in
`spec_audit_unbuilt.out.txt`) from the spec's own primitives:
- the Appendix A sodium correlations;
- IAPWS-IF97 steam (`iapws`, the package file 20 names);
- TEOS-10 seawater (`gsw`) for the site's "about 5 psu" water (§1.4);
- file 20's `calc.py`, which the script cuts out of the spec text and runs unmodified.

The script checks every quoted line against the spec before it reports, so a wrong line number fails the run.
Tolerances are half a unit in the last printed digit unless the finding says otherwise. Values marked † are
flagged only where they contradict something else.

**Verdicts:** INCONSISTENT means two parts of the spec disagree. WRONG means the spec's number is off against its
own inputs or against physics. UNSUPPORTED means the spec relies on something it never defines, or on something
that cannot happen under its own rules. CHECKED-CONSISTENT means the number holds.

**Result:** 40 findings: 1 high, 15 medium, 24 low. C-40 has been fixed since (2026-09-24), and the script now checks that it stays fixed. There are also 2 errors in the earlier audit documents, and
64 groups of checks (89 individual checks) that came out consistent.

## Summary

| ID | Location | Claim | Recomputation | Verdict | Sev. | Suggested resolution |
|---|---|---|---|---|---|---|
| C-01 | §5.1 L1207; §9.1 L1673; §5.1 L1208 | Trace-heating low alarm 150 °C | Below §9.1's 180 °C floor and below the 160 °C plugging-temperature alarm | INCONSISTENT | medium | Alarm at ≥ 180 °C, above the plugging alarm; state that cold traps are exempt from the 180 °C rule |
| C-02 | §5.2 L1226 | 1 g/s leak adds +0.28 ppm at the section meter | 0.2877 ppm (all hydrogen dissolved, 389 kg/s); the spec's own 0.036 ppm loop value implies 0.288 | WRONG (rounding) | low | Print 0.29 ppm |
| C-03 | §5.2 L1228, §12.3 L2429 vs §0.2 L403 | Hydrogen drift and impurity ingress "per grid day" | §0.2 puts both on ×360; the two readings are 30× apart (cold trap fills in 1,500 h or 50 h real) | INCONSISTENT | medium | Choose one clock per process and reword whichever section loses |
| C-04 | file 20 L3037 (feeds §5.1, §6.1) | Reactor = SG total − 10.5 MW | Pumps put 15.9 MW of shaft power into sodium (3 × 3.3 + 3 × 2.0) and DRACS standby takes out 1.2 MW, a net 14.7 MW; the secondary pumps' heat appears nowhere | UNSUPPORTED | low | Add the secondary pumps' heat, or state the 4.2 MW of losses that offset it |
| C-05 | §6.1 L1253 | Pinch ≈ 20 K (sodium 360, saturation 340 °C) | Saturation is taken at the EV outlet pressure (14.6 MPa); with boiling onset between 16.0 and 14.6 MPa the pinch is 16.9–20.2 K | UNSUPPORTED | low | "≈ 17–20 K", or evaluate saturation at the local pressure |
| C-06 | §6.3 L1278 † | Throttling a branch to 50 % costs about 6 MWe | Second-law maximum m·T₀·Δs ≤ 1.08 MW for 145.8 kg/s and 0.7–0.8 MPa (2.2 MW for all of loop 2) | WRONG | low | ≈ 1 MWe, or name the mechanism that costs 6 MWe |
| C-07 | §6.4 L1299 | Isolating one SG2 section nudges each reheat by about 2 K | File 20's reheater model: A moves 1.8–2.4 K, B moves 5.6–8.6 K (B has 4 modules, A has 12) | INCONSISTENT | low | "≈ 2 K on A, 6–9 K on B" |
| C-08 | §6.5 L1303–1356; §7.1 L1402, L1411; §7.2 L1449 | B load limits 100/100/94/83/72/62 % | These read §7.1's curve at the SG-outlet reheat temperature. At the IP stop valve (−5 K, where §7.2's 500 °C normal is) they are 100/100/89/78/67/56 %, and the 100 % row becomes 613 MWe, not 645 | INCONSISTENT | medium | State where the limit and the 420 °C trip read, then recompute the column |
| C-09 | §6.5 L1317; §9.4 L1818 | 60 % row: A hot reheat 508 °C, not spraying | Attemperation auto holds ≤ 505 °C; the column is the unsprayed module outlet (file 20 credits min(T, 505)) | INCONSISTENT | low | Label the column "before sprays" and mark the 60 % row as spraying |
| C-10 | §6.6 L1375; §7.5 L1545; §9.2 | Water admission: sodium ≥ 250 °C; feed ≥ sodium − 80 K | Even at the SG sodium outlet it passes only at 100 %. At hot standby (375 °C) it needs feed ≥ 295 °C, so with 170–180 °C feed water can enter only with sodium at 250–260 °C | INCONSISTENT | medium | Name the sodium location, state that the rule is first admission only, and give a hot re-admission path |
| C-11 | §6.2 L1263; §9.4 L1824 | Header 13.7 MPa; turbine auto holds header 13.5 ±0.2 | The normal header sits on the edge of the auto band; 13.5 is §6.2's stop-valve pressure | INCONSISTENT | low | Header setpoint 13.7 ±0.2, or say the auto holds stop-valve pressure |
| C-12 | §7.2 L1456–1457; §8.4 L1617 | Generator trips above 52 Hz | The time-limited range ends at 51.5 Hz, so 51.5–52 Hz is neither permitted nor tripped (the low side matches at 47.5 Hz) | INCONSISTENT | low | Trip at 51.5 Hz with a delay, or extend the range |
| C-13 | §7.2 L1451; §9.2 L1718 | Hot-reheat alarm fixed at 480 °C | At the 30 % row reheat is ≤ 484 °C at the SG, ≤ 479 °C at the IP stop valve: a standing alarm in a normal state | INCONSISTENT | medium | Let the hot-reheat alarm track the programme below 40 %, as main steam's does |
| C-14 | §7.3 L1468–1469; S-28 L2690; §7.1 L1405; §9.2 L1679–1680 | One unit runs at house load ≈ 65 MWe | 65 MWe is 13 % of a unit, against a 30 % (150 MWe) minimum stable load; §9.2 calls the same rows both "turbines off" and "house-load states" | INCONSISTENT | medium | Exempt house-load operation from the minimum for a stated time, and fix §9.2's sentence |
| C-15 | S-05 L2530; §7.3 L1464–1465 | Poor crew: "Condenser B overloaded, second trip" | The bypass is sized 60 %, which the condenser absorbs indefinitely. Its rule needs 110 % bypass for the 10 kPa alarm and 210 % for the trip | UNSUPPORTED | medium | Change the outcome (SG relief, reactor trip), or add the mechanism, e.g. degraded CW |
| C-16 | §7.4 L1478; file 20 L3101 | 15.3 m³/s, 11 K rise, 690 MWt | File 20 uses cp 4.0 and ρ 1025 (ocean water). With 5 psu water (TEOS-10: 4.153, 1,001), 11.0 K needs 15.08 m³/s; the pair survives only through rounding (10.84 K) | WRONG (method) | low | Use 5 psu properties; print 15.1 m³/s or 10.8 K |
| C-17 | §7.5 L1525; §6.5 L1338 | LP2 feed out 91 °C; 90 % row A reheat 516 °C | 90.49 °C and 515.46 °C: file 20 printed them at one decimal (90.5, 515.5), then rounded again | WRONG (rounding) | low | 90 °C and 515 °C |
| C-18 | §7.6 L1558–1560 | Train B lost: turbine A takes 437.5 kg/s, "the rest goes to bypass" | The rest (145.9 kg/s) is exactly SG2's B branch, which CV-2B still routes to turbine B. SG3 is left with no feed path, and no reactor power is stated | INCONSISTENT | low | State turbine B's status, SG3's feed source and the runback |
| C-19 | §1.1 L464; §7.6 L1552 | House load: feed pumps 19.6, primary 10.3, secondary 6.2 | Primary and secondary are electrical (shaft × 1.04, × 1.03); feed is absorbed power (× 1.00). On one basis feed draws 20.4 MWe | INCONSISTENT | low | List the feed pumps at electrical input and trim "everything else" |
| C-20 | §8.1 L1579–1581 | Unit boards fast-transfer to station boards via ST-1, 60 MVA | A double unit trip puts the full 65 MWe house load on 60 MVA (76 MVA at 0.85 pf). It fits only after the feed pumps (19.6 MW) run down | UNSUPPORTED | low | Size ST-1 ≥ 77 MVA, or state the load shedding on transfer |
| C-21 | §9.2 L1679–1681 (Rev A4 text of F22) | "178, 86 and 42 MWe are under the 150 MWe minimum … their steam is below the reheat trip" | 178 > 150 on one turbine; the 20 % row's main steam 440 °C (435 °C at the stop valve) is above both trips. Two turbines both reach 150 MWe only above 32.8 %FP, so the "turbines on" 30 % row is a one-turbine state | WRONG | medium | Give the true reason: below ≈ 33 %FP two turbines cannot both hold 150 MWe; the ≈ 25 %FP cut-off for the last turbine is F22's decision, not a consequence of 150 MWe |
| C-22 | §10.1 L2029 | "No two desks that have to talk during a fault can see each other" | The same table seats reactor, primary and SS together (MCR), secondary sodium and SG together (SGCR), and turbine A and B together (TCR) | INCONSISTENT | low | "No two rooms whose desks…" |
| C-23 | §11.1 L2294 | Planned curtailment (e.g. −200 MWe) announced a grid-hour ahead | A grid-hour is 5 min real; 200 MWe takes 20 min at 1 %/min and 6.7 min at the approved 3 %/min | UNSUPPORTED | low | State the deadline; notice ≥ 4 grid-hours for 200 MWe |
| C-24 | §11.3 L2330; §8.4 L1626–1636 | Dispatch error counts \|MW − target\| beyond 10 MW | Contracted reserves move the plant up to FCR-N ±20, FCR-D 50 and aFRR ±20 MWe; "target" is not said to include them | UNSUPPORTED | medium | Target = dispatch setpoint + expected reserve response (§11.2) |
| C-25 | S-18 L2618, L2621 | Poor crew: under-frequency trip | That needs < 47.5 Hz for 20 s. The cue is 49.6 Hz, §11.2's worst nadir is 49.55 Hz, and load shedding starts at 48.8 Hz | UNSUPPORTED | medium | Add the collapse path below 47.5 Hz, or change the outcome |
| C-26 | §12.1 L2407–2408 | Striping: adjacent outlets > 40 K apart add 1/5,000 per minute | No clock: U = 1 after 83 h (real) or 6.9 h (grid). "Assemblies" is undefined: a rod position (5.35 kg/s) would need 0.98 MW of its own heat to sit within 40 K of a 559 °C neighbour | UNSUPPORTED | medium | Mark the clock and say "fuel assemblies", or give rod positions an outlet temperature |
| C-27 | §12.2 L2416–2417 | Random failure × "overpower multiplier" | The phrase appears once in the spec and is never defined | UNSUPPORTED | low | Define it |
| C-28 | §12.2 L2422–2423; LCO-12 L1992–1995 | Scan one group of 7 every 2 min; LCO-12: ≤ 30 %FP and locate within 8 grid-h | 301/7 = 43 groups: 86 min real (mean 44) against 40 min real; found in time with probability 47 % | INCONSISTENT | medium | ≤ 55 s per group, "2 grid-min", or a longer completion time |
| C-29 | §12.3 L2433 vs §0.2 L403 | Trace-heating failures "1 per 2,000 zone-hours real" | §0.2 (and `src/shared/Config/Clocks.luau`) put heater failures on ×360. For ≈ 180 zones that is one failure every 1.85 min instead of every 11.1 h | INCONSISTENT | **high** | Remove "heater failures" from §0.2's ×360 list |
| C-30 | §12.3 L2431; S-13 L2586; LCO-6 L1968–1971 | Plugging temperature +2 K per 10 % loading above 70 %; S-13 ends in an LCO-6 derate | +6 K at 100 %. LCO-6 (125 → 180 °C) needs 345 % loading; the alarms need 195 % and 170 % | INCONSISTENT | medium | Add the mechanism (ingress with a full trap), or change S-13's outcome |
| C-31 | §12.3 L2435; S-12 L2574 | "Drained line" freezes in ≈ 40 min | A drained line holds no sodium | INCONSISTENT | low | "Filled line with heater off" or "drain line" |
| C-32 | §12.4 L2445–2446 vs §0.2 L404–406 | Small leak: neighbour penetrated in 10–30 min at 1 g/s, 1–3 min at 10 g/s | §0.2 binds §12.4 to the grid clock but reads unmarked windows as real time: 50–150 s or 10–30 min real (12×) | INCONSISTENT | medium | Mark each figure grid or real |
| C-33 | S-16 L2605; §8.3 L1605–1606; §0.2 L393–396 | SBO window ≈ 6.5 h, ≈ 40 min at ×10 | At ×1 the UPS (2 h) and DC (4 h) run out before the pool limit. At ×10 electrical stays ×1 (§0.2), so they never run out | INCONSISTENT | medium | State which clock drains batteries, and put exhaustion in S-16 |
| C-34 | S-06 L2536; S-19 L2627 | "Field hydraulic reset"; "kill drive power" | Neither appears in §10.3 (local actions) or §10.2 (desk controls) | UNSUPPORTED | low | Add both |
| C-35 | §13.1 L2479–2480; §1.7 L605; §1.4 L531–532 | Frazil needs "winter and open water" | That leaves December only; §1.7 has frazil risk from November | INCONSISTENT | low | Align the months |
| C-36 | §14.2 L2738–2739 | "A fully implicit form errs the same amount the other way" | +15.3 % and +45.5 %, against −11.4 % and −21.7 % for held n | WRONG | low | "…errs the other way, by more" |
| C-37 | §14.2 L2740, L2757 | Snippet starts `num = q`; "initialise with s[i] = beta[i] n" | `q` (an external source) is never defined; that initialisation is steady only with q = 0 at ρ = 0 | UNSUPPORTED | low | Define q and the steady state with a source |
| C-38 | §14.3 L2796 | ≈ 6,300 thermal states | The listed blocks sum to 6,199 | WRONG | low | ≈ 6,200 |
| C-39 | App. B L2926–2933, L2952 | Shim rods tagged SM; SG-2-HM-05 | SM is in neither code list; the 3 loop-outlet meters (27 = 24 + 3) have no NN rule | UNSUPPORTED | low | Add SM, and an NN for loop meters |
| C-40 | App. C L2983, L2991; headers L10, L361… | Revision log; "Rev A3" | A5 is listed before A4; the README and 7 file headers still say Rev A3 | INCONSISTENT | low | Reorder, and update the headers. **Fixed 2026-09-24** (`tools/derive/apply_rev_a5.py`) |

**Errors in the earlier audit documents**

| ID | Document | Claim | Recomputation | Resolution |
|---|---|---|---|---|
| P-01 | `docs/DECISIONS.md` D-028 | "ganging all three crosses the 250–750 mm band in about 33 minutes rather than 100" | On the 250–750 mm band, one rod from mid-band to edge takes 55 min and three ganged take 164 min. 33 min is one rod on the old 400–700 mm band (D-006), and ganging is the slower case | "one rod reaches the band edge in ≈ 55 min, against ≈ 164 min for all three ganged" |
| P-02 | `docs/DECISIONS.md` F24; `SPEC_REVIEW_AUDIT.md` #10 | Hydraulic check with "~14.5 MPa rise … gives 9.1 MW per train" | File 20 and §7.5 give 1.0 → 17.5 MPa = 16.5 MPa, so the same check gives 9.9 MW shaft and 10.3 MW electrical per train. F24's conclusion stands | Use 16.5 MPa |

## Evidence

**C-01.** §5.1 idles the secondary at 200 °C with a trace-heating alarm "below 150 °C". §9.1 says no sodium meant
to stay liquid goes below 180 °C, so a filled loop can sit between 150 and 180 °C, breaking §9.1 without an alarm.
The same loop's cold trap alarms at a plugging temperature of 160 °C. The sodium can therefore sit 10 K below its
own plugging temperature, where oxide precipitates in the coldest pipe, with neither alarm raised. Separately, the
cold traps run below 180 °C by design (§4.6 trap wall 125 °C), so §9.1's wording needs an exception for them.

**C-02.** Water is 11.19 % hydrogen by mass (IUPAC atomic weights). A section's sodium flow is 3,112/8 =
389.0 kg/s. 1 g/s of water therefore adds 0.2877 ppm if all its hydrogen dissolves, and 0.0360 ppm at the loop
meter after eightfold dilution. The spec's loop figure, 0.036, matches the full-hydrogen case exactly. Its section
figure, 0.28, is that value truncated: 0.036/0.28 is 1/7.78, not the 1/8 that §12.4 states.

**C-03.** §0.2 lists "impurity ingress, cold trap loading, hydrogen drift" under ×360. §12.3 states ingress as
"0.2 kg per grid day", and §5.2 states the hydrogen drift as "±0.01 ppm per grid day". Filling the 150 kg trap
takes 750 days: 1,500 h real on the grid clock, 50 h real on ×360. For hydrogen, 30 real minutes drift 0.0025 ppm
on the grid clock (below the ±0.003 ppm meter noise, §10.5) or 0.075 ppm on ×360. The ×360 figure exceeds the whole
0.06 ppm full-power background. §10.5 ("drifts out of band in 30 min or more") does not settle which is meant,
because it gives no band.

**C-04.** File 20 sets reactor = SG total − 10.5 MW. The spec's pumps put 3 × 3.3 MW (primary, §4.2) plus
3 × 2.0 MW (secondary, §5.1) of shaft power into sodium, and the four DRACS loops lose 4 × 0.3 MW on standby
(§4.5): a net 14.7 MW. File 20's SG total is 2,389.0 MWt, so the reactor would be 2,374.3 MWt against §1.1's
canonical 2,380. No stated loss accounts for the 4.2 MW. This is not F29, which compared 24 × 99.5 with core plus
*primary* pump heat; the secondary pumps' heat appears nowhere in the balance.

**C-05.** File 20 finds the pinch at hf(14.6 MPa), the EV *outlet* pressure. Boiling starts upstream of the
outlet, since the outlet is 15 K superheated, so the local pressure lies between 16.0 and 14.6 MPa. Re-running
file 20's bisection at those two pressures gives sodium 364.2 against saturation 347.4 °C (16.9 K) at 16.0 MPa, and
360.2 against 340.0 °C (20.2 K) at 14.6 MPa. "≈ 20 K" holds only if the whole 1.4 MPa drop lies ahead of the
boiling point.

**C-06.** The throttle is isenthalpic, and the steam has nowhere else to go in reactor-leads mode, so the flow
stays the same. The work lost is at most m·T₀·Δs (Gouy–Stodola), with T₀ = 306.0 K, the saturation temperature at
the 5.0 kPa rating point. With IAPWS-IF97, 145.8 kg/s at 505 °C throttled by 0.7–0.8 MPa near 14 MPa loses
0.89–1.08 MW. Even if all of loop 2 went through one branch the loss would be 2.2 MW. "About 6 MWe" (†) is about
six times the thermodynamic maximum. S-06's poor-crew "throttling losses" inherits that figure.

**C-07.** This uses file 20's own reheater model: ε-NTU with UA = 264 kW/K and sodium capacity 209 kW/K per module,
at a 50/50 split. Isolating an SG2 section on A's side (A has 12 modules, now 11) moves A by −2.2 K and B by
+5.6 K. On B's side (B has 4 modules, now 3) A moves +2.0 K and B −8.6 K. If the isolated section's sodium
redistributes to the other seven (×8/7), the moves are −1.8/+6.5 K and +2.4/−6.5 K. B always moves 3–4× as far as
A, because it has a third as many modules.

**C-08.** §7.1 gives hot reheat 500 °C "at IP stop valve", and §7.2's hot-reheat row (normal 500, alarm 480,
trip 420) is at the same point. §6.1 puts the SG reheat outlet at 505 °C. §6.5 and file 20 (`lim(TB)`) apply
§7.1's load-limit curve to the SG-outlet temperature, while file 20's own `cycle()` uses SG outlet − 5 K for the
turbine. Read at the IP stop valve, B's limits become 100, 100, 89, 78, 67 and 56 %. The 100 % row changes: B is
capped at 279 MWe, the plant makes 613 MWe instead of 645, and 38 MWe go to bypass instead of 6. The recommended
60–70 % split is unaffected.

**C-09.** At the 60 % split file 20 gives A's reheater outlet 508.1 °C, printed without "spraying", while the
70–100 % rows (511–517 °C) say "spraying". §9.4's attemperation auto holds hot reheat ≤ 505 °C, and file 20
credits turbine A with min(T, 505). So the column is the pre-spray module outlet, and the 60 % row needs spray too.

**C-10.** The rule names no sodium location. At the SG sodium *inlet* it fails at every §9.2 row (100 %:
240 < 440). At the *outlet*, the most lenient reading, it holds only at 100 % (240 = 320 − 80). It then fails at
80 % (231 < 240), 60 % (222 < 240), 40 % (210 < 240), 30 % (204 < 254), 20 % (197 < 268), 10 % (188 < 281) and
5 % (182 < 284). Read as a first-admission permissive only, it still means water enters only with SG sodium
between 250 and feed + 80 = 250–260 °C. That is never at hot standby (375 °C, the D-024 boot state), and never for
returning a section to service at power after S-01's isolation.

**C-11.** §6.2 has SG outlet 14.0, header 13.7 and stop valve 13.5 MPa. §9.4's turbine auto "holds header
13.5 ±0.2 MPa", so the normal header sits on the edge of its own band. Bypass auto opens at "header + 0.4 MPa":
13.9 MPa if the setpoint is 13.5, 14.1 MPa if it is 13.7.

**C-12.** §8.4 allows continuous operation at 49.0–51.0 Hz and time-limited operation down to 47.5 Hz and up to
51.5 Hz. §7.2 trips below 47.5 Hz for 20 s, which matches, but above 52 Hz, which leaves 51.5–52 Hz neither allowed
nor tripped.

**C-13.** Only the main-steam alarm "tracks program below 40 %". At §9.2's 30 % row the secondary hot leg is
484 °C, so reheat cannot exceed 484 °C at the SG, or 479 °C at the IP stop valve after the 5 K line loss that
§6.1 (505 °C) and §7.1 (500 °C) imply. The hot-reheat alarm is 480 °C. Even with no line loss, reheat clears 480 °C
only if the reheater approach is under 4 K; it is 15 K at full load.

**C-14.** 65/500 = 13 % of a unit, against §7.1's 30 % (150 MWe) minimum stable load. §6.5 says a unit at 33 % is
"a hair above its 30% minimum load, where the next disturbance trips it". The steam side itself balances (K-26).
§9.2's Rev A4 sentence says below ≈ 25 %FP "the turbines are off" and, in the same sentence, calls those rows
"bypass or house-load states"; a house-load state needs a turbine running.

**C-15.** §7.3 sizes each bypass for 60 % of turbine flow and says the condenser "absorbs 60 % bypass
indefinitely at design cooling water", then 1 kPa per extra 10 %. After a turbine trip the condenser gets only
bypass steam. Reaching the 10 kPa alarm from 5.0 kPa would take 110 % bypass, and the 20 kPa trip 210 %. S-05's
poor-crew outcome cannot happen at design cooling water.

**C-16.** File 20 computes the CW flow as (Qt − 505)/(4.0 × 11)/1025: ocean-water cp and density. TEOS-10 at
SP = 5 and the 24.5 °C mean temperature gives ρ = 1,001.0 kg/m³ and cp = 4.153 kJ/kg·K. Then 689.5 MWt at
15.3 m³/s is a 10.84 K rise, and exactly 11 K needs 15.08 m³/s. The printed pair (15.3 m³/s, "11 K") survives
only because 10.84 rounds to 11. The one-pump 18 K rise (= 11/0.6) is unaffected.

**C-17.** File 20's rule, outlet = Tsat − 3 K, gives LP2 at 0.08 MPa = 90.485 °C. The §6.5 90 % row's A reheat is
515.463 °C. Both were evidently printed at one decimal (90.5, 515.5) and rounded again (91, 516). The other five
heater outlets and every other §6.5 cell reproduce (K-19, K-32).

**C-18.** Train A feeding SG1 and all of SG2 makes 2 × 291.7 = 583.4 kg/s. Turbine A takes 437.5 kg/s, and the
remaining 145.9 kg/s is exactly loop 2's B branch at 50/50, which CV-2B/NRV-2B still send to header B. So bypass is
forced only if turbine B is also out, which §7.6 does not say. The XV-2A/2B crosstie serves SG2 only, so SG3 has no
feed unless train B's own startup pump runs (131 kg/s, 45 % of SG3). Neither the section nor S-20 gives the power
the reactor must reach.

**C-19.** §1.1's house-load list divides by the shaft powers as follows. Primary pumps: 10.3/(3 × 3.3) = 1.040.
Secondary pumps: 6.2/(3 × 2.0) = 1.033. Both are electrical input at a motor-plus-drive efficiency of about 0.96.
Feed pumps: 19.6/(2 × 9.8) = 1.000, the absorbed power §7.6 and file 20 give. On the same basis the feed pumps draw
about 20.4 MWe, and "everything else ≈ 14" becomes ≈ 13.

**C-20.** On a reactor trip both turbines trip, and both unit boards fast-transfer to SB-1/SB-2, which ST-1
(60 MVA) feeds. The house load is 65 MWe, more than 60 MVA at any power factor (76 MVA at 0.85). It fits only once
the feed pumps (19.6 MW) have run down, leaving 45.4 MW. The spec states no load shedding on transfer. ST-2
(40 MVA) could take even less.

**C-21.** One turbine at the 20 % row's 178 MWe is above 150 MWe. That row's main steam, 440 °C at the SG and
≈ 435 °C at the stop valve, is above both the 430 °C main-steam trip and the 420 °C reheat trip the sentence cites.
The accepted F22 resolution says these are "not normal two-turbine online states", which is right; the Rev A4 text
says something stronger and wrong. Solving file 20's MWe formula for 300 MWe shows two turbines can both be at
150 MWe only above 32.8 %FP. So the 30 % row (273 MWe), which the sentence leaves "turbines on", is a one-turbine
state as well. One turbine could carry the 20 % row. Taking reheat at the main-steam value (440 °C at the SG), §7.1's limit is
38–45 % depending on C-08's reading point, above 178 MWe = 36 %; any hotter reheat widens the margin.
The ≈ 25 %FP cut-off therefore stands as F22's operating decision, but the reason printed for it is wrong.

**C-22.** The rule forbids desks that must talk during a fault from seeing each other. The same table puts three
desks in the MCR, two in the SGCR and two in the TCR. Reactor and primary share P/Q (§9.3) and must talk in S-07.
The rule can only mean rooms.

**C-23.** One grid-hour is 5 min real. A 200 MWe cut takes 20 min at LCO-10's 1 %/min and 6.7 min at the approved
3 %/min. If the limit bites at the announced time, the crew must either breach LCO-10 or take dispatch error. The
instruction's deadline is not stated.

**C-24.** Dispatch error integrates max(0, |MW − target| − 10). Delivering contracted reserves moves the plant by
up to ±20 MWe (FCR-N, 2 × ±10), 50 MWe (FCR-D, 2 × 25) or ±20 MWe (aFRR). §11.2 defines "expected plant response"
for the frequency score, but not whether "target" includes it. As written, correct reserve delivery scores as a
dispatch miss.

**C-25.** S-18's cue is −0.4 Hz (49.6 Hz). The generator's under-frequency trip is below 47.5 Hz for 20 s. §11.2's
loss events bottom out at −0.45 Hz, and §8.4 sheds load from 48.8 Hz. Nothing in the spec takes the frequency the
extra 2.1 Hz, and no plant trip is set at 49.6 Hz.

**C-26.** "1/5,000 per minute" is a rate, not a window, so §0.2's "response windows are real time" rule does not
cover it. F26's resolution binds degradation to the grid clock. U goes 0 → 1 in 83.3 h real on real time, or
6.9 h real on the grid clock. "Adjacent assembly outlets" does not say whether the 30 rod positions of the
331-position map count. Each gets 1.5 % × 10,694/30 = 5.35 kg/s (§2.5), and the spec gives it no heat. To sit
within 40 K of a 559 °C fuel neighbour (§2.4 average outlet), a rod position would need 0.98 MW of its own. Read
literally, the rule charges damage all the time at power.

**C-27.** "overpower multiplier" occurs once in the whole spec, in §12.2, without a formula or table.

**C-28.** 301 = 7 × 43, so a full scan is 43 × 2 = 86 min, 44 min on average; "2 min" is unmarked, hence real by
§0.2. LCO-12 requires "≤ 30 %FP and locate failed fuel" within 8 grid-hours = 40 min real. A failed assembly at a
uniformly random position is found in time with probability 20/43 = 47 %.

**C-29.** §0.2 lists "heater failures" under the ×360 slow clock, and `src/shared/Config/Clocks.luau` already
encodes that list. §12.3 gives "1 per 2,000 zone-hours real". With ≈ 180 zones (§10.2, §14.3) the real-time
reading is one failure every 11.1 h. On ×360 it is 32.4 per real hour, one every 1.85 min, which would bury the
sodium-services desk. Rated high because the implemented Config already takes the ×360 side.

**C-30.** The primary plugging temperature is normally ≤ 125 °C, with the alarm at 150 °C and LCO-6 at 180 °C
(§4.6). §12.3's only mechanism adds 2 K per 10 % loading above 70 %, which is +6 K at a full trap. Reaching LCO-6
needs 70 + 55/2 × 10 = 345 % loading, the primary alarm 195 %, and the secondary alarm (140 → 160 °C) 170 %. S-13's
poor-crew LCO-6 derate cannot happen, and nothing says what happens after the trap is full.

**C-31.** §12.3 "Drained line cooling with heater off … to freezing" and S-12 "Heater fault on a drained line" both
describe freezing a line that, being drained, holds no sodium. The 40 min DN50 figure and the thaw rules (§10.3,
§12.3) need a filled line, or a drain line.

**C-32.** Rev A4 bound §12.4 to the grid clock in §0.2, while §0.2 also says unmarked windows are real time.
§12.4's small-leak times carry no unit. On the grid clock they are 50–150 s real at 1 g/s and 5–15 s at 10 g/s; on
real time they are as printed, 12× longer. The micro stage says "grid-hours", and K-57 shows that reading fits
S-01; the next stage needs the same marking.

**C-33.** §0.2 keeps "electrical" on ×1 "always" while ×10 drives "heatup, cooldown, long waits in blackout
scenarios". At ×1 the UPS (2 h) and DC (4 h) run out before the 6.5 h pool limit, so the crew goes blind first. At
×10 the pool limit arrives at 39 min real and the 2 h UPS never runs out. S-16 therefore plays as a different
scenario depending on the clock, and its window mentions neither battery.

**C-34.** S-06's good crew does a "field hydraulic reset" of CV-2B, which fails as-is on hydraulic pressure loss
(§6.3). S-19's good crew will "kill drive power". Neither action is in §10.3's local-only list or in any §10.2
desk. The good-crew actions of the other scenarios all map to a listed control or local action.

**C-35.** §13.1 needs "winter and open water". Winter is December–March and fast ice lasts January–April (§1.4),
which leaves December. §1.7 puts frazil risk "from November" (autumn), and §1.4 "before the ice forms".

**C-36.** Re-running the prior audit's comparison at dt = 0.1 s with §3.1's data gives the growth-rate errors
below. The comment's first half is right; its "same amount the other way" is not, and the gap widens toward the
0.9β handover.

| Reactivity | n held at its old value | Fully implicit | Linear n (D-015) |
|---|---|---|---|
| 0.8β | −11.4 % | +15.3 % | +0.4 % |
| 0.9β | −21.7 % | +45.5 % | +2.2 % |

**C-37.** `local num, den = q, BETA - rho` reads a `q` that no line of the spec defines; the script searched the
whole text. With a source, the steady state is ρ = −q/n, not the s[i] = β[i]·n, ρ = 0 state the next paragraph
initialises. The code has one (D-030), the spec does not.

**C-38.** The listed blocks are fuel 301 × 10 × 2 = 6,020, pools 3, IHX 18, SG 144, turbines 4 and feed trains 10:
6,199 states (6,205 if the 6 delay lines count as states). "≈ 6,300" rounds from 6,250–6,349.

**C-39.** Appendix B's glossary says shim rods are tagged SM "to avoid a clash", but SM is in neither the system nor
the type code list (RD is the rod type). The example SG-2-HM-05 covers section meters; the 3 loop-outlet meters
(§10.2 lists 27 = 24 + 3) have no stated NN.

**C-40.** Appendix C runs A, A1, A2, A3, **A5, A4**. The README (L10, "Rev A3, 15 September 2026") and the seven
spec-file headers ("SFR-1000 DESIGN SPECIFICATION, REV A3") predate the A4 and A5 changes the text now carries. **Fixed 2026-09-24:** the labels say Rev A5 and both logs run A3, A4, A5.

**P-01.** On §3.4's S-curve, one 100 pcm rod from 500 to 750 mm is worth 40.9 pcm, 55 min at the ×360 drift of
0.75 pcm per real minute; over the full 250–750 mm band it is worth 81.8 pcm, 109 min. Three ganged rods from
mid-band to edge are worth 122.7 pcm, 164 min, which is §10.5's 2.7 h. D-006's "≈ 25 pcm ≈ 33 min" was one rod,
550 → 700 mm, on the old 400–700 mm band (25.2 pcm, 34 min). D-028 gives ganging 33 min against 100, which is
reversed and uses the old band: moving one rod at a time is the faster way to reach the band edge.

**P-02.** F24 checks the feed pumps with a "~14.5 MPa rise". File 20 (`hfp = hda + v·16.5e3/0.83`) and §7.5 give
1.0 → 17.5 MPa, a 16.5 MPa rise. With F24's other inputs (887 kg/m³, 82 % pump, 96 % motor) that gives 9.9 MW
shaft and 10.3 MW electrical per train, which confirms file 20's 9.8 MW. F24's conclusions stand: about 5 MW per
pump, and the old 12 MW motor rating was wrong. C-19 covers the resulting house-load bookkeeping.

## Checked and consistent

Each item names its check in the script output; tolerances are printed rounding unless stated.

- **§5.1:**
  - K-01: 3.65 m³/s is the flow at the 420 °C loop mean, as file 20 computes it; it is 3.55 m³/s at the 320 °C
    pump, and the spec names no temperature.
  - K-02: hot-leg velocity 5.9 m/s.
  - K-03: hot- and cold-leg delays 31 and 32 s.
  - K-04: lap ≈ 125 s, within the parts' rounding; the parts print 126.
  - K-05: inventory ≈ 400 t, at least the 391 t that is flowing.
  - K-06: pump efficiency 0.80, file 20's value.
  - K-07: buffer 0.30 + head 0.45 = discharge 0.75 MPa, and the loop drops sum to the head.
  - K-08: §4.3's ≥ 0.4 MPa margin holds if the IHX outlet sits within 12.4 m of the hot-pool surface.
- **§5.2:**
  - K-09: loop meter = section meter/8.
  - K-10: a 0.05 g/s leak is 4.8× the meter noise.
  - K-11: rupture discs (1.2 MPa) sit above every normal secondary pressure.
- **§6.1:**
  - K-12: section and loop duties (file 20: 62.64/21.24/15.66 and 501.1/169.9/125.3 MWt).
  - K-13: SH/RH split 57.55 % and mixing temperature 445.1 °C.
  - K-14: feed 36.46 and reheat 31.86 kg/s per section; reheat fraction 87.38 %.
  - K-15: EV outlet superheat 15.0 K.
  - K-16: one section is −12.5 % of a loop and −4.17 %FP (S-01's "trim reactor 4 %").
- **§6.2:**
  - K-17: safety valves 3 × 35 %; normal 14.0 < relief 15.2 < safety 15.8 MPa.
  - K-18: 166.2 K main-steam superheat at the stop valve.
- **§6.5:**
  - K-19: every other cell reproduces with file 20, including the B load limits read at the SG outlet and the
    totals to within 1 MWe.
  - K-20: "Trip B" dump 145.8 kg/s.
- **§6.6:**
  - K-21: minimum EV flow 72.9 kg/s.
  - K-22: the density-wave threshold (20 %) is below the minimum flow (25 %).
- **§7.1:**
  - K-23: 590 MVA × 0.85 = 501.5 MW; 1,575 t/h; cold reheat 292.2 °C; LP dryness 0.919; 41.86 % gross;
    minimum stable load 150 MWe.
- **§7.2:**
  - K-24: every row is ordered normal < alarm < trip.
  - K-25: 40 → 25 %FP on the programme drops main steam 48.8 K in 3 min at 5 %/min, inside the 50 K per 10 min
    trip.
- **§7.3:**
  - K-26: house-load steam balance: the reactor must run back to ≤ 66.5 %, as S-28 says.
- **§7.4:**
  - K-27: a 10.84 K CW rise with 5 psu water rounds to "11 K".
  - K-28: one-pump rise 18.3 K; four CW pumps = 14.8 MW (§1.1).
  - K-29: all 12 lineup rows (pressure, gross, net) reproduce with file 20's condenser snippet.
  - K-30: condenser saturation minus intake is constant per lineup (13.7–14.3 K with two pumps, 21.1–21.5 K with
    one).
  - K-31: winter 2 × 514 = 1,028 MWe; summer rating 500.
- **§7.5:**
  - K-32: five heater outlets and the 180 °C deaerator = Tsat − 3 K.
  - K-33: deaerator storage 8.45 min.
  - K-34: the part-load feed formula reproduces all eight §9.2 feed temperatures.
- **§7.6:**
  - K-35: capacities 481.3, 612.5 and 583.4 kg/s.
- **§8:**
  - K-36: generator transformer 600 ≥ 590 MVA.
  - K-37: UAT 50 MVA ≥ a unit board's running load, ≈ 22.7 MW plus condensate pumps.
  - K-38: +300 MVAr fits at 500 MW (583 MVA); only 290 MVAr fits at 514 MW, the "less in winter".
  - K-39: frequency thresholds are ordered.
  - K-40: aFRR is 0.4 %/min, inside LCO-10.
  - K-41: EDG at speed in 15 s = S-15's window.
- **§9 cross-references:**
  - K-42: turbine-leads delay 114 s = "1–2 minutes" (transport and pool mixing).
- **§10:**
  - K-43: desk counts: 27 hydrogen meters, 24 acoustic detectors, 24 section isolations, 6 condensate pumps, 4 main
    and 2 startup feed pumps, 8 dampers, 6 shutters, 6 DND, 30 rods, 331-position map, 3 separators.
  - K-44: ≈ 180 heater zones ≥ 3 × 42.
  - K-45: crews of 3, 8 and 13, and the 11 desks plus 2 field operators.
  - K-46: regulating band mid to edge 2.73 h.
  - K-47: 8 dampers × 90 s.
- **§11:**
  - K-48: 300 MWe in 10 min = 3 %/min = LCO-10's approved maximum.
  - K-49: the OU process has stationary SD σ, and is outside 49.9–50.1 Hz 0.09 % (Calm), 4.55 % (Standard) and
    15.3 % (Winter Peak) of the time.
  - K-50: the worst nadir, 49.55 Hz, stays above the 48.8 Hz shedding.
- **§12:**
  - K-51: τ_w = L²/(2α) reproduces all five walls. For a wall heated on one face the first conduction mode is
    4L²/(π²α) = 0.405 L²/α, against the spec's 0.5 L²/α; it is a stated model, so it is noted, not flagged.
  - K-52: hazard 0.0402 and 0.807 per grid day, 3.9 % and 55.4 % (D-008).
  - K-53: fatigue charge per cycle.
  - K-54: creep begins at the 650 °C alarm and takes 8.3 h real to D = 1.
  - K-55: 8 grid-hours in §12.2, LCO-12 and S-22.
  - K-56: failure-mode fractions sum to 100 %.
  - K-57: micro-leak doubling of 10–30 min real makes S-01's 20–60 min window two doublings.
- **§13:**
  - K-58: cost classes cover S-01..S-28 once each (10/10/8).
  - K-59: the player-scaling brackets fit the 3/8/13 crews.
  - K-60: S-16 at ×10 is 39 min.
  - K-61: S-12 40 min, S-23 = 900 s lag, S-04 67 %, S-01 4 %.
- **File 16:**
  - K-62: 662 bytes; u16 at 0.05 K spans 3,277 K.
  - K-63: 26,264 unknowns; 0.21–0.63 M node updates per shape step.
  - K-64: the held-n errors quoted in §14.2 (11 % and 22 %).

## Not checked, and why

Each of these needs data the spec does not give:
- **§12.3 freeze times** (DN50 in 40 min, DN900 in 20 h): needs insulation data.
- **§12.3 sodium's 2.5 % expansion on melting:** needs a solid-sodium density, which Appendix A does not have.
- **§6.3 equal-percentage trim:** 0.10 → 0.8 MPa implies a rangeability of 8 at unchanged flow, but the spec states
  no rangeability to compare against.
- **§5.1 SG shell, buffer-tank and IHX residence times** (41, 17 and 5 s): no volumes.
- **§7.1 critical speeds and run-up:** no rotor data.
- **§8.3 EDG sizing against essential loads:** no load ratings for DRACS fans, chargers or HVAC.
- **§12.1 α = 4 × 10⁻⁶ m²/s** is a stainless-steel value. The ferritic SG steels would need cited properties the
  repository does not hold.
- **S-07 check-valve dynamics:** no valve data.

Two items were left to the reports that already cover them: S-19's timing (SPEC_REVIEW_AUDIT #16) and the
plant-level heat-balance rounding (F16, F29).

## Reproducing

```bash
pip install iapws numpy gsw
python tools/audit/spec_audit_unbuilt.py > tools/audit/spec_audit_unbuilt.out.txt
```

The script exits non-zero if any quoted line has moved or any check changes outcome, meaning a K check failing or
a C/P check passing. It ends with file 20's own output, re-run.
