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
  C-40   (docs/audit/SPEC_AUDIT_UNBUILT.md, done 2026-09-24) the text pack says which revision it is: its README
         and the seven spec-file headers move from Rev A3 to A5, and both revision logs run A3, A4, A5 in order
         (the text had A5 before A4; the HTML table ran A5, A4, A3)

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
from apply_rev_a4 import HTML_EDITS as A4_HTML_EDITS, TXT_EDITS as A4_TXT_EDITS  # noqa: E402

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


def _entry(edits, finding: str) -> str:
    """The text an insertion edit added: its replacement less the anchor it kept."""
    _, old, new, _ = next(e for e in edits if e[0] == finding)
    return new[len(old):] if new.startswith(old) else new[: len(new) - len(old)]


# C-40: the log entries are taken from the edits that wrote them, so the swap moves exactly that text
TXT_A4, TXT_A5 = _entry(A4_TXT_EDITS, "A4 log"), _entry(TXT_EDITS, "A5 log")
HTML_A4, HTML_A5 = _entry(A4_HTML_EDITS, "A4 log"), _entry(HTML_EDITS, "A5 log")
HTML_A3 = """            <tr>
              <td>A3</td>
              <td>15 Sep 2026</td>
              <td>Reactor physics raised to real-time 3D multigroup space-time kinetics: hexagonal-Z nodal diffusion, improved quasi-static method, per-assembly thermal-hydraulic coupling (§3.7, §14.2). Former lumped values became validation targets; point kinetics kept as fallback</td>
            </tr>
"""
README_LABEL = ("Design specification Rev A3, 15 September 2026", "Design specification Rev A5, 21 September 2026")
HEADER_LABEL = ("SFR-1000 DESIGN SPECIFICATION, REV A3", "SFR-1000 DESIGN SPECIFICATION, REV A5")
C40_HTML = [("C-40", HTML_A5 + HTML_A4 + HTML_A3, HTML_A3 + HTML_A4 + HTML_A5, 1)]


def c40_txt(path: Path):
    """C-40's edits for one text file, each with the number of times it must match there."""
    whole, n = path == TXT, path.name[:2]
    edits = []
    if whole or n == "00":
        edits.append(("C-40", *README_LABEL, 1))
    if whole or "10" <= n <= "16":
        edits.append(("C-40", *HEADER_LABEL, 7 if whole else 1))
    if whole or n == "16":
        edits.append(("C-40", TXT_A5 + TXT_A4, TXT_A4 + TXT_A5, 1))
    return edits


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
    ("C-40 README label", README_LABEL[1], 0, 1),
    ("C-40 spec-file headers", HEADER_LABEL[1], 0, 7),
    ("C-40 no Rev A3 label left", "Design specification Rev A3", 0, 0),
    ("C-40 no REV A3 header left", "SPECIFICATION, REV A3", 0, 0),
]


# Checks whose text Rev A6 replaced on purpose. apply_rev_a6.py verifies what took their place, so here they are
# reported as superseded, not wrong: a check that fails on a correct tree invites someone to "fix" the spec back.
SUPERSEDED = {
    "Rev A5 title": "Rev A6 retitled the spec",
    "C-40 README label": "Rev A6 relabelled the README",
    "C-40 spec-file headers": "Rev A6 relabelled the spec-file headers",
}


def verify():
    html, txt = HTML.read_text(encoding="utf-8"), TXT.read_text(encoding="utf-8")
    checks = []
    superseded = 0
    for label, snippet, want_html, want_txt in VERIFY:
        gh, gt = html.count(snippet), txt.count(snippet)
        ok = (want_html is None or gh == want_html) and (want_txt is None or gt == want_txt)
        if not ok and label in SUPERSEDED:
            superseded += 1
            print(f"   superseded {label}: {SUPERSEDED[label]}; apply_rev_a6.py checks it")
            continue
        checks.append((ok, f"{label}: html {gh} (want {want_html}), text pack {gt} (want {want_txt})"))
    # C-40: every revision log runs A3, A4, A5 in order, and every handoff file is still verbatim in the text pack
    logs = [("HTML", html, "<td>{}</td>"), ("text pack", txt, "\n* {}\n")]
    logs += [(f.name, f.read_text(encoding="utf-8"), "\n* {}\n") for f in HANDOFF if f.name.startswith("16_")]
    for where, text, fmt in logs:
        at = [text.find(fmt.format(r)) for r in ("A3", "A4", "A5")]
        checks.append((-1 not in at and at == sorted(at), f"C-40 {where} log runs A3, A4, A5 (at {at})"))
    for f in HANDOFF:
        checks.append((f.read_text(encoding="utf-8") in txt, f"{f.name} is verbatim in the text pack"))
    bad = 0
    for ok, what in checks:
        bad += not ok
        if not ok:
            print(f"   WRONG {what}")
    print(f"verify: {len(checks) - bad}/{len(checks)} checks pass"
          + (f", {superseded} superseded by Rev A6" if superseded else ""))
    return bad


if __name__ == "__main__":
    check = "--check" in sys.argv
    for path, edits in [(HTML, HTML_EDITS + C40_HTML), (TXT, TXT_EDITS + c40_txt(TXT))] + [
            (f, [e for e in TXT_EDITS if e[1] in f.read_text(encoding="utf-8")] + c40_txt(f)) for f in HANDOFF]:
        if not edits:
            continue
        applied, already, missed = apply(path, edits, check)
        print(f"{path.name}: {applied} applied, {already} already there, {len(missed)} missed")
        for finding, hits, expected, snippet in missed:
            print(f"   MISSED [{finding}] {hits} hits (expected {expected}): {snippet}")
    sys.exit(1 if verify() else 0)
