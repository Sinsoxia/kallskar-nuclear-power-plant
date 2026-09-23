# Audit of the external spec review (REACTOR SPEC/3A SPEC REVIEW)

Eight reviewers looked at Rev A3 (`sfr-1000-spec.html`, md5 `06a38b11…`, identical to the archived copy they read).
Their file says outright: *"DO NOT TAKE THIS AS ABSOLUTE TRUTH"*. So every numeric claim below was recomputed from the
spec's own primitives — Appendix A sodium correlations, §3.1 kinetics data, §3.4 rod worths, §2.1/§2.3 geometry, and the
spec's own file-20 `calc.py` — by `tools/derive/spec_review_check.py` (output in `spec_review_check.out.txt`).

Verdicts: **CONFIRMED** = the spec is wrong and should change. **REFUTED** = the spec is right and the reviewer is
wrong. **PARTLY** = the concern is real but the reviewer's numbers or reasoning are not.

## Summary

| # | Claim (reviewer) | Verdict | My recomputation |
|---|---|---|---|
| 1 | +300 pcm gives 2.5 s, not ~0.46 s (E1, E4) | **CONFIRMED** | 0.467 s; 2.5 s ↔ 211 pcm (already F12/D-016) |
| 2 | IHX 545 °C in gives ~385 MW, not 400 (E1, E3, E4) | **CONFIRMED** | 385.2 MW; 6 × = 2,311 vs 2,390 needed. At 550 °C: 396.4 MW, 6 × = 2,378 |
| 3 | Shim bank A at 1 mm/s breaks the 4 pcm/s interlock (E1, E4) | **CONFIRMED** | 4.80 pcm/s peak; B 3.60, C 2.40, single rod 1.60, RR bank 3.00 |
| 4 | DRACS coping is ~6.5 h, not ~5 h (E1) | **CONFIRMED** | 6.60 h with the full §3.6 formula; the spec's calc dropped a term and got 4.81 h |
| 5 | Dump tank too small for 400 t (E1) | **CONFIRMED** | 443 m³ at 200 °C (98 % of 450); 469 m³ at 420 °C — will not fit hot |
| 6 | RR band is 163 pcm but §3.3 reserves 250 (E1) | **CONFIRMED** | 163.5 pcm for 400–700 mm; a 250–750 mm band is 245.5 pcm |
| 7 | §10.5 "RR band drifts out in ~20 min" (E1) | **CONFIRMED** | 0.75 pcm/real-min at ×360 → 109 min to the band edge (164 min for a 250 pcm band) |
| 8 | 10 % and 5 % part-load rows sit below the turbine minimum (E1) | **CONFIRMED** | 86 and 42 MWe gross vs 150 MWe minimum — below it even on one turbine; main steam 408/401 °C is under the 420 °C reheat trip |
| 9 | Natural-circulation formula gives 16 % at full power (E3) | **CONFIRMED** | 3.5 % × 100^⅓ = 16.25 %; intended form (P/100 %FP)^⅓ = 3.5 % |
| 10 | House load 65 MWe vs listed auxiliaries (E3) | **REFUTED** | §7.6's 9.8 MW is per feed *train* (the spec's calc prints "MFP power/train 9.8 MW"; a hydraulic check on the 16.5 MPa rise gives 9.9 MW shaft per train; corrected from 9.1, P-02 of docs/audit/SPEC_AUDIT_UNBUILT.md). Listed major drives then total 51.0 MWe of the 65 MWe house load. E3 read it per pump and doubled it |
| 10a | (found while checking #10) §7.6 says "2 × 55 % main feed pumps (12 MW motors on VFDs, 9.8 MW absorbed at 100 %)" | **CONFIRMED** | 9.8 MW per train means 4.9 MW per pump, which cannot sit behind a 12 MW motor. The parenthetical needs rewording |
| 11 | §14.2 amplitude snippet lags at high ρ (E1) | **CONFIRMED** | −11.4 % growth rate at 0.8β, −21.7 % at 0.9β (E1 said 11 % and 21 %) |
| 12 | ×360 "fuel failure hazard" vs grid-hour degradation models (E6) | **CONFIRMED** | §0.2 lists fuel failure under ×360; §12.2/§12.4 define it per grid day / grid hour (×12) — 30× conflict |
| 13 | S-16 says "×10 → 30 min" but ×10 is barred with P1/P2 alarms (E6) | **CONFIRMED** | Rules conflict in the text; a blackout raises P1 alarms by definition |
| 14 | LCO-7 (≥0.2 MPa) is violated by an idle loop (E6) | **PARTLY** | §4.3 states ≥0.4 MPa while LCO-7 says ≥0.2 — the spec disagrees with itself; the idle-loop case needs a stated datum |
| 15 | RB-2 trips the reactor on P/Q (E6) | **PARTLY** | Peak P/Q 1.08 vs 1.12 trip while the flap valve is open — no trip. But at check-valve seating flow steps to 2/3 and P/Q ≈ 1.35. E6's "power > 98 % at 8 s" is wrong (shims sit mid-stroke at BOC, where bank A gives 48 pcm/s at 10 mm/s) |
| 16 | S-19 reaches the period trip in ~40 s (E1) | **PARTLY** | With §3.4's one-rod-at-a-time interlock it takes ~270 s; E1 assumed the three RRs gang together |
| 17 | Average LHR should be 29.2 kW/m, not 27.7 (E3) | **REFUTED** | 27.72 kW/m with the 95 % pin fraction the spec's own calc uses. E3 put all 2,380 MWt in the pins |
| 18 | Bundle velocity is 3.6–3.7 m/s, transit 0.27 s (E3) | **REFUTED** | 5.13 m/s and 0.195 s. E3 used the 173 mm **outer** across-flats; the 4.5 mm wrapper wall leaves 164 mm inner |
| 19 | SR count rate should be 492 cps, not 250 (E4) | **REFUTED** | "All rods in" = PSS + SSS = 8,670 pcm → k = 0.9397 → 249 cps. E4 used the stuck-rod shutdown margin |
| 20 | Decay heat formula gives 156 MW at 1 s, not 151 (E7) | **REFUTED** | 151.2 MW. E7 dropped the −(t + T_op)^−0.2 term |
| 21 | Cover gas 0.074 MPa is temperature-only; real answer 0.057 (E4) / 0.094 (E1) | **REFUTED** | 0.0741 MPa including both the 90 m³ swing and the gas cooling 300 → 180 °C. Both reviewers mis-stated it |
| 22 | Splitter row should total 644, not 645 (E2) | **REFUTED** | Parts are 333.x + 311.x; rounding the parts loses 1 MWe. Presentation only |
| 23 | Phénix 1989–90 were positive reactivity insertions (E7) | **REFUTED** | They were the four negative-reactivity trips (AURN). The spec is right |
| 24 | Use a fully implicit amplitude update (E6) | **REFUTED** | It is worse: +15.3 % at 0.8β and +45.5 % at 0.9β. The linear-n form already implemented (D-015) gives +0.4 % and +2.2 % |
| 25 | Mermaid never loads, diagram shows as raw text (E1, E4) | **REFUTED** | The file imports mermaid 10 from jsdelivr and calls `initialize`. It needs internet, but the script is there |
| 26 | Six text typos, e.g. "fo r", "bypas s", "til t" (E7) | **REFUTED** | None of them exist in the file; "til t" only matches inside "until the…". Artefacts of their own text extraction |
| 27 | 2,380 vs 2,388 MWt is a real inconsistency (E3, E4, E7, Qwen-A) | **PARTLY** | 24 × 99.5 = 2,388 vs core + pump heat 2,390: the section duty is rounded (exact 99.583). Worth one sentence, not a redesign |
| 28 | 3 empty `<ul></ul>`, no `scope="col"` on 343 `<th>` (E4) | **CONFIRMED** (cosmetic) | Both verified in the file |

## The two Qwen PDFs

Neither contains a verifiable numerical finding about this spec.

- **"Architectural Integrity…" (Qwen3.7-Plus)** is narrative. Its one quantitative remark is the same 2 MWt rounding gap
  (#27). Its decay-heat table lists "Unknown — not specified in provided sources" for every row after 1 s, so it was
  not working from the whole spec. Its claim that rising cover-gas pressure "compresses the sodium surface, reducing
  the hydrostatic head that drives natural circulation" is **wrong physics**: the cover gas presses equally on the hot
  and cold free surfaces, so it cannot change the buoyancy head; raising it actually increases the margin to boiling.
  Its reference list contains items like a US federal court case and a college history course, matched on the string
  "2380" — the citations are not trustworthy.
- **"Verifying the Integrity…" (Qwen3.8-Max)** is a methodology essay on how one would audit an SFR spec, benchmarked
  against BN-600/BN-800. It never evaluates Kallskär's numbers. Its one useful data point is correct and supportive:
  BN-800 is 2,100 MWt → 880 MWe = 41.9 %, the same efficiency class as this plant's 42 %.

Both are worth keeping as checklists, not as findings.

## What the simulator should do about the confirmed items

Already recorded and implemented: the period error (F12/D-016), three-colour SOR instead of red-black (F1/D-001),
T_ref = 648 K (Config `Feedback.referenceTemperature_K`, spec file 20), assembly flow factors vs the hottest-outlet
figure (F11/D-013), and the amplitude integrator (D-015), which this audit shows is the most accurate of the three
schemes proposed.

New findings recorded in `docs/DECISIONS.md` as F16–F27. The ones that change plant behaviour and need Aqua's
decision are: the IHX inlet temperature (#2), the shim bank speed vs the interlock (#3), the coping time (#4), the RR
band width (#6, #7), the low part-load rows (#8), the natural-circulation exponent (#9), and the check-valve/P–Q
interaction during RB-2 (#15).

**Correction, made while writing this audit:** my first pass accepted E3's reading of the feed-pump power and recorded
the house load as an error. It is not: 9.8 MW is the per-train figure, so the listed drives come to 51 MWe, not 70.
The real defect there is the motor rating in §7.6's parenthetical (#10a). The recomputation script and F24 now say so.

## Reproducing this

```bash
python3 tools/derive/spec_review_check.py > tools/derive/spec_review_check.out.txt
```

Every number in the table above comes from that script, which reads only the spec's own constants.

## Applied

Rev A4 (21 Sep 2026) applies every confirmed item above to `REACTOR SPEC/sfr-1000-spec.html`, `KALLSKAR_ALL_IN_ONE.txt`
and `kallskar_handoff/*.txt` through `tools/derive/apply_rev_a4.py`, which asserts each replacement and re-verifies the
result (28/28 checks). The archived copy the reviewers read is left untouched. Config followed: IHX inlet 550 °C with
396 MWt duty, LMTD 41 K, UA 9.6 MW/K; regulating band 250–750 mm (also in the rod-auto program); shim bank A at
0.8 mm/s; the natural-circulation reference power. Full test suite after the change: 74 pass, 1 pending.
