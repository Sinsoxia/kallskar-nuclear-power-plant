"""
Apply the Rev A5 corrections to the spec.

Rev A5 carries the refinements from `docs/FINAL_DECISIONS_REV_A5.md` (Aqua's resolved decision log), which accepted
every proposed decision and asked for five changes to the document itself:

  D-018  the hot-pin centreline and the melting linear heat rate become the constant-gap model's own figures
         (2,140 °C at 42 kW/m; melting near 57 kW/m), replacing 1,950 °C and 60 kW/m
  D-008  the §12.1 hazard sentence stops reading the rate as a probability (0.807/grid day → 55 % in a grid day)
  D-004  the §9.5 core-inlet-low trip states its permissive rather than leaving the gating implicit
  F20    the regulating-band drift time is 2.7 h, not the 2.5 h Rev A4 rounded to
  F27    the LCO-7 scope note gains the idle-loop case

Honest consequence of D-018, recorded here and in the derivation: the centreline and melting figures are now OUTPUTS
of `tools/derive/pin_thermal.py`, not independent checks on it. After this revision the only §2.4/§3.2 figures the pin
model is still checked against are the 620 °C cladding hot spot (which calibrates one resistance) and the 4 s Doppler
lag (which nothing calibrates).

Machinery (assertions, idempotency, verification) is reused from apply_rev_a4.py.
Run: python tools/derive/apply_rev_a5.py [--check]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_rev_a4 import HANDOFF, HTML, TXT, add_scope, apply  # noqa: E402

HTML_EDITS = [
    ("rev", "SFR-1000 design specification, Rev A4", "SFR-1000 design specification, Rev A5", 1),
    ("D-018", "<td>45 steady; centreline melting above ≈ 60</td>",
     "<td>45 steady; centreline melting above ≈ 57</td>", 1),
    ("D-018", "<td>Fuel centreline, hot pin</td>\n              <td>≈ 1,950 °C</td>",
     "<td>Fuel centreline, hot pin</td>\n              <td>≈ 2,140 °C</td>", 1),
    ("F20", "<td>≈ 2.5 h</td>", "<td>≈ 2.7 h</td>", 1),
    ("D-008", "That's about 4% per grid day at U = 0.5 and about 80% at U = 1.",
     "That is a rate, not a probability: at U = 0.5 it is 0.04 per grid day, so about 4 % of components fail in a "
     "grid day; at U = 1 it is 0.807 per grid day, which is about 55 %.", 1),
    ("D-004", "<td>Core inlet</td>\n              <td>375 °C</td>\n              <td>390 high, 360 low</td>\n"
              "              <td>405 high, 345 low</td>",
     "<td>Core inlet</td>\n              <td>375 °C</td>\n              <td>390 high, 360 low</td>\n"
     "              <td>405 high, 345 low; the low trip is inhibited in Modes 4 and 5, in Mode 3 with every PSS rod "
     "fully inserted, and in Mode 2 below 350 °C during heatup; it is armed in Mode 1 and above 5 %FP, and every "
     "inhibit is annunciated</td>", 1),
    ("F27", "LCO-7's ≥ 0.2 MPa is the operating limit and applies to running loops only",
     "LCO-7's ≥ 0.2 MPa is the operating limit and applies to running and hot-standby loops; an idle or isolated "
     "loop is either drained or held at a pressure and elevation that still keeps the secondary above the primary", 1),
    ("A5 log", """            <tr>
              <td>A4</td>""", """            <tr>
              <td>A5</td>
              <td>21 Sep 2026</td>
              <td>Refinements from the resolved decision log (docs/FINAL_DECISIONS_REV_A5.md), which accepted every
              proposed decision. The hot-pin centreline (2,140 °C) and melting linear heat rate (≈ 57 kW/m) now carry
              the constant-gap pin model's own figures, so they are derived outputs rather than independent checks
              (D-018). §12.1's hazard sentence reads λ as a rate (D-008). The §9.5 core-inlet-low trip states its
              mode-based inhibits (D-004). Regulating-band drift 2.7 h (F20). LCO-7 gains the idle-loop case (F27)</td>
            </tr>
            <tr>
              <td>A4</td>""", 1),
]

TXT_EDITS = [
    ("D-018", "Limit: 45 steady; centreline melting above ≈ 60", "Limit: 45 steady; centreline melting above ≈ 57", 1),
    ("D-018", "* Fuel centreline, hot pin\n    At 100%: ≈ 1,950 °C",
     "* Fuel centreline, hot pin\n    At 100%: ≈ 2,140 °C", 1),
    ("F20", "Drifts out of band in about: ≈ 2.5 h", "Drifts out of band in about: ≈ 2.7 h", 1),
    ("D-008", "That's about 4% per\ngrid day at U = 0.5 and about 80% at U = 1.",
     "That is a rate, not a probability: at\nU = 0.5 it is 0.04 per grid day, so about 4 % of components fail in a grid "
     "day; at U = 1 it is 0.807 per\ngrid day, which is about 55 %.", 1),
    ("D-004", "* Core inlet\n    Normal: 375 °C\n    Alarm or first action: 390 high, 360 low\n"
              "    Trip: 405 high, 345 low",
     "* Core inlet\n    Normal: 375 °C\n    Alarm or first action: 390 high, 360 low\n"
     "    Trip: 405 high, 345 low; the low trip is inhibited in Modes 4 and 5, in Mode 3 with every\n"
     "      PSS rod fully inserted, and in Mode 2 below 350 °C during heatup; it is armed in Mode 1 and\n"
     "      above 5 %FP, and every inhibit is annunciated", 1),
    ("F27", "LCO-7's ≥ 0.2 MPa is the operating\n                            limit and applies to running loops only",
     "LCO-7's ≥ 0.2 MPa is the operating\n                            limit and applies to running and hot-standby "
     "loops; an idle or isolated loop is\n                            either drained or held at a pressure and "
     "elevation that still keeps the secondary\n                            above the primary", 1),
    ("A5 log", "* A4\n    Date: 21 Sep 2026",
     """* A5
    Date: 21 Sep 2026
    Change: Refinements from the resolved decision log (docs/FINAL_DECISIONS_REV_A5.md), which accepted
      every proposed decision. The hot-pin centreline (2,140 °C) and melting linear heat rate (≈ 57
      kW/m) now carry the constant-gap pin model's own figures, so they are derived outputs rather than
      independent checks (D-018). §12.1's hazard sentence reads λ as a rate (D-008). The §9.5
      core-inlet-low trip states its mode-based inhibits (D-004). Regulating-band drift 2.7 h (F20).
      LCO-7 gains the idle-loop case (F27)
* A4
    Date: 21 Sep 2026""", 1),
]

VERIFY = [
    ("Rev A5 title", "design specification, Rev A5", 1, 0),
    ("A5 changelog row", "<td>A5</td>", 1, None),
    ("A5 changelog (txt)", "* A5", None, 1),
    ("centreline 2,140", "≈ 2,140 °C", 1, 1),
    ("melting 57", "centreline melting above ≈ 57", 1, 1),
    ("drift 2.7 h", "≈ 2.7 h", 1, 1),
    ("hazard is a rate", "That is a rate, not a probability", 1, 1),
    ("core inlet inhibit", "inhibited in Modes 4 and 5, in Mode 3 with every", 1, 1),
    ("idle loop rule", "either drained or held at a pressure and", 1, 1),
    ("old centreline gone", "≈ 1,950 °C", 0, 0),
    ("old melting gone", "melting above ≈ 60", 0, 0),
    ("old drift gone", "≈ 2.5 h", 0, 0),
    ("old hazard wording gone", "about 80% at U = 1", 0, 0),
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
    sys.exit(1 if verify() else 0)
