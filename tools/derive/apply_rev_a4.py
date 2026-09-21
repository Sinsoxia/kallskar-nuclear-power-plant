"""
Apply the Rev A4 corrections to the spec.

Every edit below comes from a confirmed finding in docs/SPEC_REVIEW_AUDIT.md (recomputed by
tools/derive/spec_review_check.py). Each replacement asserts its expected hit count, so a missed or ambiguous match
fails loudly instead of silently doing nothing.

Targets:
  REACTOR SPEC/sfr-1000-spec.html          the canonical document (the ARCHIVED copy is never touched)
  KALLSKAR_ALL_IN_ONE.txt                  the text pack the simulator's Config cites
  kallskar_handoff/*.txt                   the split copies of the same text

Run: python tools/derive/apply_rev_a4.py [--check]
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
HTML = REPO / "REACTOR SPEC" / "sfr-1000-spec.html"
TXT = REPO / "KALLSKAR_ALL_IN_ONE.txt"
HANDOFF = sorted((REPO / "kallskar_handoff").glob("*.txt"))

# (finding, old, new, expected hits) — applied to the HTML
HTML_EDITS = [
    ("rev", "SFR-1000 design specification, Rev A3", "SFR-1000 design specification, Rev A4", 1),
    ("F29", "Every number here is a starting value that agrees with every other number.",
     "Every number here is a starting value meant to agree with every other number. Values marked † are tuning "
     "values, and a few plant-level figures are rounded (the steam generator section duty, for one). §1.1 is the "
     "canonical thermal power; everything else derives from it. Appendix C lists what Rev A4 corrected.", 1),
    ("F26", "Burnup, impurity ingress, cold trap loading, hydrogen drift, heater failures, fuel failure hazard",
     "Burnup, impurity ingress, cold trap loading, hydrogen drift, heater failures. Fuel and tube degradation "
     "(§12.2, §12.4) run on the grid clock, not here", 1),
    ("F26", "×10, Modes 3–5 only, no P1/P2 alarms, all manned desks agree",
     "×10, Modes 3–5 only, no P1/P2 alarms, all manned desks agree; also allowed in a station blackout once "
     "the reactor is confirmed subcritical", 1),
    ("tidy", "core 375 → 550 °C, 10,690 kg/s", "core 375 → 550 °C, 10,694 kg/s", 1),
    ("tidy", "3 loops, 3,110 kg/s each", "3 loops, 3,112 kg/s each", 1),
    ("F24", "≈ 935 MWe (house load ≈ 65 MWe)",
     "≈ 935 MWe (house load ≈ 65 MWe: main feed pumps 19.6, primary pumps 10.3, secondary pumps 6.2, "
     "circulating water 14.8, everything else ≈ 14)", 1),
    ("F28", "<td>Average linear heat rate</td>\n              <td>27.7 kW/m</td>",
     "<td>Average linear heat rate</td>\n              <td>27.7 kW/m (95% of fission energy is deposited in the pins; "
     "the rest heats coolant and structure)</td>", 1),
    ("F12", "which gives a period near 2.5 s",
     "which gives a period near 0.47 s on the §3.1 kinetics data (2.5 s would be about 210 pcm)", 1),
    ("F19", "<td>400–700 mm band</td>", "<td>250–750 mm band</td>", 1),
    ("F19", "stops and alarms when RR leave the 400–700 mm band",
     "stops and alarms when RR leave the 250–750 mm band", 1),
    ("F18", "2 mm/s single; 1 mm/s bank; 10 mm/s drive-in on runback",
     "2 mm/s single; 1 mm/s bank, except bank A at 0.8 mm/s so its mid-stroke differential worth stays inside the "
     "4 pcm/s interlock; 10 mm/s drive-in on runback", 1),
    ("F23", "Q_nc ≈ 3.5% × (P / 1 %FP)^(1/3)", "Q_nc ≈ 3.5% × (P / 100 %FP)^(1/3)", 1),
    ("F27", "flywheel J ≈ 5,500 kg·m²",
     "flywheel J ≈ 5,500 kg·m². The flap check valve seats once the tripped pump's developed head falls "
     "below diagrid pressure; the surviving pumps ramp to 105% on a pump trip, which keeps P/Q below the 1.12 trip "
     "while RB-2 runs power back", 1),
    ("F16", "1,782 kg/s each; 545 °C in from hot pool, 375 °C out to cold pool",
     "1,782 kg/s each; 550 °C in from the hot pool, 375 °C out to cold pool", 1),
    ("F16", "6 (1A, 1B, 2A, 2B, 3A, 3B), 400 MWt each",
     "6 (1A, 1B, 2A, 2B, 3A, 3B), 396 MWt each at 100% (400 MWt rating)", 1),
    ("F16", "LMTD ≈ 40 K; UA ≈ 10 MW/K", "LMTD ≈ 41 K; UA ≈ 9.6 MW/K", 1),
    ("F27", "Secondary side stays ≥ 0.4 MPa above primary, so a tube leak runs secondary into primary",
     "Secondary side stays ≥ 0.4 MPa above primary in a running loop, so a tube leak runs secondary into primary; "
     "LCO-7's ≥ 0.2 MPa is the operating limit and applies to running loops only", 1),
    ("F17", "the pool rises 200 K in ≈ 5 h after a trip from 100%",
     "the pool rises 200 K in ≈ 6.5 h after a trip from 100% (the §3.6 curve integrated into 1,250 t of sodium "
     "and 1,500 t of steel)", 1),
    ("F21", "450 m³, gravity drain in 20 min, electrically heated",
     "500 m³, gravity drain in 20 min, electrically heated; 400 t occupies 443 m³ at the 200 °C idle "
     "setpoint and 469 m³ at 420 °C, so a hot drain needs the larger tank", 1),
    ("F24", "2 × 55% main feed pumps (12 MW motors on VFDs, 9.8 MW absorbed at 100%)",
     "2 × 55% main feed pumps on VFDs (9.8 MW absorbed per train at 100%, ≈ 4.9 MW per pump; 6 MW motors)", 1),
    ("F22", "main steam <code>min(505, secondary hot − 15r)</code>.</p>",
     "main steam <code>min(505, secondary hot − 15r)</code>. Below about 25 %FP the turbines are off and steam goes "
     "to the bypass: the 20%, 10% and 5% rows are bypass or house-load states, because 178, 86 and 42 MWe are under "
     "the 150 MWe minimum stable load (§7.1) and their steam is below the reheat trip temperature.</p>", 1),
    ("F20", "<td>≈ 20 min</td>\n              <td>Burnup drift at ×360</td>",
     "<td>≈ 2.5 h</td>\n              <td>Burnup drift at ×360: 0.75 pcm per real minute against a 250 pcm "
     "band</td>", 1),
    ("F26", "/ 100 h</code>; failure at D = 1", "/ 100 grid hours</code>; failure at D = 1", 1),
    ("F17", "≈ 5 h, ≈ 30 min with ×10 acceleration", "≈ 6.5 h, ≈ 40 min with ×10 acceleration", 1),
    ("F25", """-- amplitude, once per 0.1 s tick
for i = 1, 6 do
  local e = math.exp(-lambda[i] * dt)
  s[i] = s[i] * e + beta[i] * n * (1 - e)
end
n = (s[1] + s[2] + s[3] + s[4] + s[5] + s[6]) / (BETA - rho)
""",
     """-- amplitude, once per 0.1 s tick: n is taken linear across the step, which keeps the
-- growth rate right at high reactivity (holding n at its old value runs 11% slow at 0.8 beta
-- and 22% slow at 0.9 beta; a fully implicit form errs the same amount the other way)
local num, den = q, BETA - rho
for i = 1, 6 do
  local x = lambda[i] * dt
  local e = math.exp(-x)
  local w = (1 - e) - (1 - e - x * e) / x
  num = num + s[i] * e + beta[i] * n * (1 - e - w)
  den = den - beta[i] * w
end
local n1 = num / den
for i = 1, 6 do
  local x = lambda[i] * dt
  local e = math.exp(-x)
  local w = (1 - e) - (1 - e - x * e) / x
  s[i] = s[i] * e + beta[i] * (n * (1 - e - w) + n1 * w)
end
n = n1
""", 1),
    ("tidy", "<ul></ul>", "", 3),
    ("A4 log", """            <tr>
              <td>A3</td>""", """            <tr>
              <td>A4</td>
              <td>21 Sep 2026</td>
              <td>Corrections from the eight-reviewer audit, each recomputed from the spec's own data
              (tools/derive/spec_review_check.py). Period for +300 pcm 0.47 s, not 2.5 s (§3.4). IHX inlet 550 °C
              and 396 MWt duty (§4.3). DRACS coping 6.5 h (§4.5). Shim bank A 0.8 mm/s to respect the 4 pcm/s
              interlock (§3.4). Regulating band widened to 250–750 mm to match the 250 pcm reserved in §3.3,
              and the §10.5 drift time corrected to 2.5 h. Secondary dump tank 500 m³ (§5.1).
              Natural-circulation formula referenced to 100 %FP (§4.2). Part-load rows below 25 %FP marked as
              bypass or house-load states (§9.2). Degradation models bound to the grid clock and ×10 allowed in a
              blackout (§0.2, §12.2). Feed-pump power stated per train (§7.6). Amplitude update replaced with the
              linear-n form (§14.2). Check-valve and surviving-pump behaviour on a pump trip stated (§4.2)</td>
            </tr>
            <tr>
              <td>A3</td>""", 1),
]

# the text pack wraps differently, so a few edits need their own strings; None = same as the HTML edit
TXT_EDITS = [
    ("F29", "Every number here is a starting value that agrees with every other number.",
     "Every number here is a starting value meant to agree with every other number. Values marked † are tuning\n"
     "values, and a few plant-level figures are rounded (the steam generator section duty, for one). §1.1 is the\n"
     "canonical thermal power; everything else derives from it. Appendix C lists what Rev A4 corrected.", 1),
    ("F26", "Burnup, impurity ingress, cold trap loading, hydrogen drift, heater failures, fuel\n      failure hazard",
     "Burnup, impurity ingress, cold trap loading, hydrogen drift, heater failures.\n"
     "      Fuel and tube degradation (§12.2, §12.4) run on the grid clock, not here", 1),
    ("F26", "Rate: ×10, Modes 3–5 only, no P1/P2 alarms, all manned desks agree",
     "Rate: ×10, Modes 3–5 only, no P1/P2 alarms, all manned desks agree; also allowed in a\n"
     "      station blackout once the reactor is confirmed subcritical", 1),
    ("tidy", "core 375 → 550 °C, 10,690 kg/s", "core 375 → 550 °C, 10,694 kg/s", 1),
    ("tidy", "3 loops, 3,110 kg/s each", "3 loops, 3,112 kg/s each", 1),
    ("F24", "≈ 935 MWe (house load ≈ 65 MWe)",
     "≈ 935 MWe (house load ≈ 65 MWe: main feed pumps 19.6, primary pumps 10.3,\n"
     "                     secondary pumps 6.2, circulating water 14.8, everything else ≈ 14)", 1),
    ("F28", "* Average linear heat rate\n    At 100%: 27.7 kW/m",
     "* Average linear heat rate (95% of fission energy is deposited in the pins)\n    At 100%: 27.7 kW/m", 1),
    ("F12", "which gives a period near 2.5 s",
     "which gives a period near 0.47 s on the §3.1 kinetics data (2.5 s would be about 210 pcm)", 1),
    ("F19", "Normal position: 400–700 mm band", "Normal position: 250–750 mm band", 1),
    ("F19", "stops and alarms when RR leave the 400–700 mm band",
     "stops and alarms when RR leave the 250–750 mm band", 1),
    ("F18", "Drive speed: 2 mm/s single; 1 mm/s bank; 10 mm/s drive-in on runback",
     "Drive speed: 2 mm/s single; 1 mm/s bank, except bank A at 0.8 mm/s so its mid-stroke\n"
     "                  differential worth stays inside the 4 pcm/s interlock; 10 mm/s drive-in on runback", 1),
    ("F23", "Q_nc ≈ 3.5% × (P / 1 %FP)^(1/3)", "Q_nc ≈ 3.5% × (P / 100 %FP)^(1/3)", 1),
    ("F27", "5,500 kg·m²",
     "5,500 kg·m². The flap check valve seats once the tripped\n"
     "                                pump's developed head falls below diagrid pressure; the surviving pumps ramp to\n"
     "                                105% on a pump trip, which keeps P/Q below the 1.12 trip while RB-2 runs power back", 1),
    ("F16", "1,782 kg/s each; 545 °C in from hot pool, 375 °C out to cold pool",
     "1,782 kg/s each; 550 °C in from the hot pool, 375 °C out to cold pool", 1),
    ("F16", "6 (1A, 1B, 2A, 2B, 3A, 3B), 400 MWt each",
     "6 (1A, 1B, 2A, 2B, 3A, 3B), 396 MWt each at 100% (400 MWt rating)", 1),
    ("F16", "LMTD ≈ 40 K; UA ≈ 10 MW/K", "LMTD ≈ 41 K; UA ≈ 9.6 MW/K", 1),
    ("F27", "Pressure rule             : Secondary side stays ≥ 0.4 MPa above primary, so a tube leak runs\n"
            "                            secondary into primary",
     "Pressure rule             : Secondary side stays ≥ 0.4 MPa above primary in a running loop, so a\n"
     "                            tube leak runs secondary into primary; LCO-7's ≥ 0.2 MPa is the operating\n"
     "                            limit and applies to running loops only", 1),
    ("F17", "With no heat sink at all, the pool rises 200 K in ≈ 5 h after a trip from 100%",
     "With no heat sink at all, the pool rises 200 K in ≈ 6.5 h after a trip from 100%\n"
     "              (the §3.6 curve integrated into 1,250 t of sodium and 1,500 t of steel)", 1),
    ("F21", "Dump tank        : 450 m³, gravity drain in 20 min, electrically heated",
     "Dump tank        : 500 m³, gravity drain in 20 min, electrically heated; 400 t occupies 443 m³ at\n"
     "                   the 200 °C idle setpoint and 469 m³ at 420 °C, so a hot drain needs the larger tank", 1),
    ("F24", "2 × 55% main feed pumps (12 MW motors on VFDs, 9.8 MW\n"
            "                                     absorbed at 100%)",
     "2 × 55% main feed pumps on VFDs (9.8 MW absorbed per\n"
     "                                     train at 100%, ≈ 4.9 MW per pump; 6 MW motors)", 1),
    ("F22", "main steam min(505, secondary hot − 15r).",
     "main steam min(505, secondary hot − 15r). Below about 25 %FP the turbines are off and steam goes to the\n"
     "bypass: the 20%, 10% and 5% rows are bypass or house-load states, because 178, 86 and 42 MWe are under the\n"
     "150 MWe minimum stable load (§7.1) and their steam is below the reheat trip temperature.", 1),
    ("F20", "* Regulating rod band\n    Drifts out of band in about: ≈ 20 min\n    Why: Burnup drift at ×360",
     "* Regulating rod band\n    Drifts out of band in about: ≈ 2.5 h\n"
     "    Why: Burnup drift at ×360: 0.75 pcm per real minute against a 250 pcm band", 1),
    ("F26", "/ 100 h; failure at D = 1", "/ 100 grid hours; failure at D = 1", 1),
    ("F17", "≈ 5 h, ≈ 30 min with ×10 acceleration", "≈ 6.5 h, ≈ 40 min with ×10 acceleration", 1),
    ("F25", """    -- amplitude, once per 0.1 s tick
    for i = 1, 6 do
      local e = math.exp(-lambda[i] * dt)
      s[i] = s[i] * e + beta[i] * n * (1 - e)
    end
    n = (s[1] + s[2] + s[3] + s[4] + s[5] + s[6]) / (BETA - rho)
""",
     """    -- amplitude, once per 0.1 s tick: n is taken linear across the step, which keeps the
    -- growth rate right at high reactivity (holding n at its old value runs 11% slow at 0.8 beta
    -- and 22% slow at 0.9 beta; a fully implicit form errs the same amount the other way)
    local num, den = q, BETA - rho
    for i = 1, 6 do
      local x = lambda[i] * dt
      local e = math.exp(-x)
      local w = (1 - e) - (1 - e - x * e) / x
      num = num + s[i] * e + beta[i] * n * (1 - e - w)
      den = den - beta[i] * w
    end
    local n1 = num / den
    for i = 1, 6 do
      local x = lambda[i] * dt
      local e = math.exp(-x)
      local w = (1 - e) - (1 - e - x * e) / x
      s[i] = s[i] * e + beta[i] * (n * (1 - e - w) + n1 * w)
    end
    n = n1
""", 1),
    ("A4 log", """§14.2). Former lumped values became validation targets; point kinetics kept as fallback
""",
     """§14.2). Former lumped values became validation targets; point kinetics kept as fallback
* A4
    Date: 21 Sep 2026
    Change: Corrections from the eight-reviewer audit, each recomputed from the spec's own data
      (tools/derive/spec_review_check.py). Period for +300 pcm 0.47 s, not 2.5 s (§3.4). IHX inlet
      550 °C and 396 MWt duty (§4.3). DRACS coping 6.5 h (§4.5). Shim bank A 0.8 mm/s to respect
      the 4 pcm/s interlock (§3.4). Regulating band widened to 250–750 mm to match the 250 pcm
      reserved in §3.3, and the §10.5 drift time corrected to 2.5 h. Secondary dump tank 500 m³
      (§5.1). Natural-circulation formula referenced to 100 %FP (§4.2). Part-load rows below 25 %FP
      marked as bypass or house-load states (§9.2). Degradation models bound to the grid clock and
      ×10 allowed in a blackout (§0.2, §12.2). Feed-pump power stated per train (§7.6). Amplitude
      update replaced with the linear-n form (§14.2). Check-valve and surviving-pump behaviour on a
      pump trip stated (§4.2)
""", 1),
]


def distinctive(old: str, new: str) -> str:
    """
    The part of `new` that `old` does not already contain, used to detect an edit that has run before.
    Comparing the START of the replacement is not enough: most of these edits keep the original sentence and add to
    it, so their first characters are identical to the original and every edit would look 'already applied'.
    """
    i = 0
    while i < min(len(old), len(new)) and old[i] == new[i]:
        i += 1
    j = 0
    while j < min(len(old), len(new)) - i and old[len(old) - 1 - j] == new[len(new) - 1 - j]:
        j += 1
    return new[i:len(new) - j].strip()[:60]


def apply(path: Path, edits, check_only: bool):
    text = original = path.read_text(encoding="utf-8")
    missed, already, applied = [], 0, 0
    for finding, old, new, expected in edits:
        # Idempotency first: many replacements CONTAIN the original text, so after one run the old string is still
        # there and a second run would append the addition again. Checking for the new text has to come first.
        hits = text.count(old)
        if old in new and new != old:
            # the replacement keeps the original text, so a second run would append the addition again:
            # detect the addition itself, and insist it is long enough to be unambiguous
            probe = distinctive(old, new)
            if len(probe) < 12:
                raise SystemExit(f"edit [{finding}] needs a longer distinctive addition to stay idempotent: {probe!r}")
            if probe in text:
                already += 1
                continue
        elif hits == 0:
            # the original text is gone, so the replacement has run (applying it twice is impossible)
            already += 1
            continue
        if hits != expected:
            missed.append((finding, hits, expected, old[:70].replace("\n", "\\n")))
            continue
        text = text.replace(old, new)
        applied += 1
    if not check_only and text != original:
        path.write_text(text, encoding="utf-8", newline="")
    return applied, already, missed


def add_scope(path: Path, check_only: bool):
    """Accessibility: mark header cells as column headers (all <th> in this document sit inside <thead>)."""
    text = path.read_text(encoding="utf-8")
    heads = re.findall(r"<thead>.*?</thead>", text, re.S)
    total = sum(h.count("<th>") for h in heads)
    if text.count("<th>") != total:
        return 0, f"{text.count('<th>') - total} <th> outside <thead>; left alone"
    if not check_only:
        text = re.sub(r"<thead>.*?</thead>", lambda m: m.group(0).replace("<th>", '<th scope="col">'), text, flags=re.S)
        path.write_text(text, encoding="utf-8", newline="")
    return total, None


# (label, snippet, expected count in the HTML, expected count in the text pack); None = do not check there.
# The changelog entry repeats several phrases, which is why some counts are 2.
VERIFY = [
    ("Rev A4 title", "design specification, Rev A4", 1, 0),
    ("A4 changelog row", "<td>A4</td>", 1, None),
    ("A4 changelog (txt)", "* A4", None, 1),
    ("period 0.47 s", "period near 0.47 s", 1, 1),
    ("IHX inlet 550", "550 °C in from the hot pool", 1, 1),
    ("IHX duty 396", "396 MWt each at 100%", 1, 1),
    ("LMTD 41 / UA 9.6", "LMTD ≈ 41 K; UA ≈ 9.6 MW/K", 1, 1),
    ("bank A 0.8 mm/s", "bank A at 0.8 mm/s", 1, 1),
    ("RR band 250-750", "250–750 mm band", 2, 2),
    ("natural circulation", "(P / 100 %FP)^(1/3)", 1, 1),
    ("dump tank 500", "500 m³, gravity drain", 1, 1),
    ("coping 6.5 h", "200 K in ≈ 6.5 h", 1, 1),
    ("S-16 6.5 h", "≈ 6.5 h, ≈ 40 min", 1, 1),
    ("creep grid hours", "100 grid hours", 1, 1),
    ("feed pump per train", "9.8 MW absorbed per", 1, 1),
    ("house load split", "main feed pumps 19.6", 1, 1),
    ("LHR 95 % basis", "95% of fission energy", 1, 1),
    ("part-load note", "bypass or house-load states", 2, 2),
    ("drift 2.5 h", "≈ 2.5 h", 1, 1),
    ("check valve", "flap check valve seats", 1, 1),
    ("LCO-7 scope", "applies to running loops only", 1, 1),
    ("x10 in blackout", "confirmed subcritical", 1, 1),
    ("degradation clock", "run on the grid clock, not here", 1, 1),
    ("linear-n amplitude", "linear across the step", 1, 1),
    ("empty <ul> gone", "<ul></ul>", 0, None),
    ("old IHX 545 gone", "545 °C in from hot pool", 0, 0),
    ("old 2.5 s gone", "period near 2.5 s", 0, 0),
    ("old drift 20 min gone", "<td>≈ 20 min</td>", 0, None),
]


def verify():
    html, txt = HTML.read_text(encoding="utf-8"), TXT.read_text(encoding="utf-8")
    bad = 0
    for label, snippet, want_html, want_txt in VERIFY:
        gh, gt = html.count(snippet), txt.count(snippet)
        ok = (want_html is None or gh == want_html) and (want_txt is None or gt == want_txt)
        bad += not ok
        if not ok:
            print(f"   WRONG {label}: html {gh} (want {want_html}), text pack {gt} (want {want_txt})")
    print(f"verify: {len(VERIFY) - bad}/{len(VERIFY)} checks pass")
    return bad


if __name__ == "__main__":
    check = "--check" in sys.argv
    for path, edits in [(HTML, HTML_EDITS), (TXT, TXT_EDITS)] + [
            (f, [e for e in TXT_EDITS if e[1] in f.read_text(encoding="utf-8")]) for f in HANDOFF]:
        if not edits:
            continue
        applied, already, missed = apply(path, edits, check)
        print(f"{path.name}: {applied} applied, {already} already there, {len(missed)} missed")
        for finding, hits, expected, snippet in missed:
            print(f"   MISSED [{finding}] {hits} hits (expected {expected}): {snippet}")
        if path is HTML:
            n, note = add_scope(HTML, check)
            print(f"{HTML.name}: scope=\"col\" on {n} header cells" + (f" — {note}" if note else ""))
    sys.exit(1 if verify() else 0)
