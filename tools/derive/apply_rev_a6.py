"""
Apply Rev A6 to the spec: §9.4's automatic controllers become competent, local and reactive (D-059).

Aqua, 2026-09-24, after playing the M1 plant: each auto holds its own variable by feedback on its own measurement,
tuned not to overshoot, and nothing more. None anticipates, coordinates with another, or sees a fault outside its
loop, and that is what still makes a crew worth having. So:
  §9.4     the heading and the "Weakness built in" column become "competent, local and reactive" and "Limits"; five
           rows whose limit was a handicap built into the controller are rewritten (rod auto, primary flow auto,
           secondary flow auto, feed auto, bypass auto); the other eight rows describe a real limit and keep it
  brief    file 01's sentence on the autos says the same (it is not in the HTML, which covers files 10-16)
  labels   README and spec-file headers Rev A6, 24 September 2026; the HTML title; Appendix C gains A6

The spec audit (tools/audit/spec_audit_unbuilt.py) cites lines of KALLSKAR_ALL_IN_ONE.txt, two of them inside §9.4
(1818, attemperation; 1824, turbine auto). Every rewritten row therefore keeps its number of lines, and those two
rows are untouched, so no cited line moves except the two after Appendix C, which the A6 entry pushes down.

Machinery (assertions, idempotency, verification) is reused from apply_rev_a4.py.
Run: python tools/derive/apply_rev_a6.py [--check]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_rev_a4 import HANDOFF, HTML, TXT, apply  # noqa: E402

OLD_HEAD = "9.4 Automatic controllers, deliberately worse than a crew"
NEW_HEAD = "9.4 Automatic controllers: competent, local and reactive"
OLD_ID = "94-automatic-controllers-deliberately-worse-than-a-crew"
NEW_ID = "94-automatic-controllers-competent-local-and-reactive"

# (row, old limit, new limit): the text copies wrap each at the same number of lines as the old one
ROWS = [
    ("rod auto",
     "    Weakness built in: Never moves shims; stops and alarms when RR leave the 250–750 mm band; reacts\n"
     "      after thermocouples move\n",
     "    Limits: Moves the RR only, so it stops and alarms when they leave the 250–750 mm band and the\n"
     "      crew re-shims; acts on the outlet thermocouples, so it corrects after they move\n",
     "Never moves shims; stops and alarms when RR leave the 250–750 mm band; reacts after thermocouples move",
     "Moves the RR only, so it stops and alarms when they leave the 250–750 mm band and the crew re-shims; acts on "
     "the outlet thermocouples, so it corrects after they move"),
    ("primary flow auto",
     "    Weakness built in: 10 s filter on power, so P/Q swings ±5% on fast changes; ignores a pump trip\n",
     "    Limits: Acts on measured P/Q alone; after a pump trip it gets back what the pumps left can give\n",
     "10 s filter on power, so P/Q swings ±5% on fast changes; ignores a pump trip",
     "Acts on measured P/Q alone; after a pump trip it gets back what the pumps left can give"),
    ("secondary flow auto",
     "    Weakness built in: Drives all three loops equally even with isolated sections; 60 s integral\n"
     "      time\n",
     "    Limits: Drives all three loops equally even with isolated sections: it sees the inlet, not\n"
     "      the loops\n",
     "Drives all three loops equally even with isolated sections; 60 s integral time",
     "Drives all three loops equally even with isolated sections: it sees the inlet, not the loops"),
    ("feed auto",
     "    Weakness built in: Overshoots ±8 K on 10% steps; no turbine feedforward; off in separator mode\n",
     "    Limits: No turbine feedforward, so a load step moves main steam first; off in separator mode\n",
     "Overshoots ±8 K on 10% steps; no turbine feedforward; off in separator mode",
     "No turbine feedforward, so a load step moves main steam first; off in separator mode"),
    ("bypass auto",
     "    Weakness built in: Slow; pressure swings ±0.3 MPa\n",
     "    Limits: Acts on header pressure alone, so a fast load drop swings it before the valves open\n",
     "Slow; pressure swings ±0.3 MPa",
     "Acts on header pressure alone, so a fast load drop swings it before the valves open"),
]
UNCHANGED_ROWS = 8  # the other eight keep their limit and only take the new label

A6_CHANGE = ("§9.4's automatic controllers become competent, local and reactive (D-059). Each holds its own loop on "
             "its own measurement, tuned not to overshoot, and the built-in handicaps go: flow auto's 10 s power "
             "filter, the secondary flow auto's 60 s integral time, the feed auto's ±8 K overshoot and the bypass "
             "auto's slowness. What stays is what a local controller cannot do: anticipate, coordinate with another, "
             "or see a fault. Rod auto keeps to the regulating rods, and the crew re-shims")
A6_TXT = """* A6
    Date: 24 Sep 2026
    Change: §9.4's automatic controllers become competent, local and reactive (D-059). Each holds its own
      loop on its own measurement, tuned not to overshoot, and the built-in handicaps go: flow auto's 10 s
      power filter, the secondary flow auto's 60 s integral time, the feed auto's ±8 K overshoot and the
      bypass auto's slowness. What stays is what a local controller cannot do: anticipate, coordinate
      with another, or see a fault. Rod auto keeps to the regulating rods, and the crew re-shims
"""
A5_TXT_END = "      LCO-7 gains the idle-loop case (F27)\n"
A5_HTML_END = "LCO-7 gains the idle-loop case (F27)</td>\n            </tr>\n          </tbody>"

README_LABEL = ("Design specification Rev A5, 21 September 2026", "Design specification Rev A6, 24 September 2026")
HEADER_LABEL = ("SFR-1000 DESIGN SPECIFICATION, REV A5", "SFR-1000 DESIGN SPECIFICATION, REV A6")
BRIEF = ("Automatic controllers are deliberately worse than a good crew (spec file 14, section 9.4): slower,\n"
         "less efficient, blind to faults. Small servers survive on auto; full crews do better.",
         "Automatic controllers are competent but local (spec file 14, section 9.4): each holds its own loop,\n"
         "but none anticipates, coordinates or sees faults. Small servers survive on auto; full crews do better.")

HTML_EDITS = [
    ("rev", "SFR-1000 design specification, Rev A5", "SFR-1000 design specification, Rev A6", 1),
    ("heading", f'<h3 id="{OLD_ID}">{OLD_HEAD}</h3>', f'<h3 id="{NEW_ID}">{NEW_HEAD}</h3>', 1),
    ("contents", f'<a href="#{OLD_ID}">{OLD_HEAD}</a>', f'<a href="#{NEW_ID}">{NEW_HEAD}</a>', 1),
    ("column", '<th scope="col">Weakness built in</th>', '<th scope="col">Limits</th>', 1),
] + [(row, f"<td>{old}</td>", f"<td>{new}</td>", 1) for row, _, _, old, new in ROWS] + [
    ("A6 log", A5_HTML_END, A5_HTML_END.replace("          </tbody>", "") + f"""            <tr>
              <td>A6</td>
              <td>24 Sep 2026</td>
              <td>{A6_CHANGE}</td>
            </tr>
          </tbody>""", 1),
]


def txt_edits(path: Path):
    """Rev A6's edits for one text file, each with the number of times it must match there."""
    whole, n = path == TXT, path.name[:2]
    edits = []
    if whole or n == "01":
        edits.append(("brief", *BRIEF, 1))
    if whole or n == "00":
        edits.append(("label", *README_LABEL, 1))
    if whole or "10" <= n <= "16":
        edits.append(("header", *HEADER_LABEL, 7 if whole else 1))
    if whole or n == "14":
        edits.append(("heading", f"{OLD_HEAD}\n{'-' * len(OLD_HEAD)}\n", f"{NEW_HEAD}\n{'-' * len(NEW_HEAD)}\n", 1))
        edits += [(row, old, new, 1) for row, old, new, _, _ in ROWS]
        edits.append(("labels", "    Weakness built in: ", "    Limits: ", UNCHANGED_ROWS))
    if whole or n == "16":
        edits.append(("A6 log", A5_TXT_END, A5_TXT_END + A6_TXT, 1))
    return edits


# (label, snippet, expected count in the HTML, expected count in the text pack); None = do not check there
VERIFY = [
    ("Rev A6 title", "design specification, Rev A6", 1, 0),
    ("new heading", NEW_HEAD, 2, 1),
    ("old heading gone", "deliberately worse than", 0, 0),
    ("new anchor", NEW_ID, 2, 0),
    ("old anchor gone", OLD_ID, 0, 0),
    ("Limits column", '<th scope="col">Limits</th>', 1, None),
    ("Limits labels", "    Limits: ", None, len(ROWS) + UNCHANGED_ROWS),
    ("no Weakness label", "Weakness built in", 0, 0),
    ("rod auto re-shims", "crew re-shims", 2, 2),
    ("no power filter row", "10 s filter on power", 0, 0),
    ("no overshoot row", "Overshoots ±8 K", 0, 0),
    ("no slow bypass row", "Slow; pressure swings", 0, 0),
    ("brief", "Automatic controllers are competent but local", 0, 1),
    ("A6 log row", "<td>A6</td>", 1, None),
    ("A6 log (txt)", "* A6\n", None, 1),
    ("README label", README_LABEL[1], 0, 1),
    ("spec-file headers", HEADER_LABEL[1], 0, 7),
    ("no Rev A5 label left", "Design specification Rev A5", 0, 0),
    ("no REV A5 header left", "SPECIFICATION, REV A5", 0, 0),
]


def verify():
    html, txt = HTML.read_text(encoding="utf-8"), TXT.read_text(encoding="utf-8")
    checks = []
    for label, snippet, want_html, want_txt in VERIFY:
        gh, gt = html.count(snippet), txt.count(snippet)
        ok = (want_html is None or gh == want_html) and (want_txt is None or gt == want_txt)
        checks.append((ok, f"{label}: html {gh} (want {want_html}), text pack {gt} (want {want_txt})"))
    # every revision log runs A3 to A6 in order, and every handoff file is still verbatim in the text pack
    logs = [("HTML", html, "<td>{}</td>"), ("text pack", txt, "\n* {}\n")]
    logs += [(f.name, f.read_text(encoding="utf-8"), "\n* {}\n") for f in HANDOFF if f.name.startswith("16_")]
    for where, text, fmt in logs:
        at = [text.find(fmt.format(r)) for r in ("A3", "A4", "A5", "A6")]
        checks.append((-1 not in at and at == sorted(at), f"{where} log runs A3 to A6 (at {at})"))
    for f in HANDOFF:
        checks.append((f.read_text(encoding="utf-8") in txt, f"{f.name} is verbatim in the text pack"))
    # the audit's two cited lines inside §9.4 still read the same, where they were
    lines = txt.splitlines()
    checks.append((lines[1817] == "    Holds: Hot reheat ≤ 505 °C", "audit line 1818 (attemperation) in place"))
    checks.append((lines[1823].startswith("    Holds: Header 13.5 ±0.2 MPa"), "audit line 1824 (turbine auto) in place"))
    bad = 0
    for ok, what in checks:
        bad += not ok
        if not ok:
            print(f"   WRONG {what}")
    print(f"verify: {len(checks) - bad}/{len(checks)} checks pass")
    return bad


if __name__ == "__main__":
    check = "--check" in sys.argv
    for path, edits in [(HTML, HTML_EDITS), (TXT, txt_edits(TXT))] + [(f, txt_edits(f)) for f in HANDOFF]:
        if not edits:
            continue
        applied, already, missed = apply(path, edits, check)
        print(f"{path.name}: {applied} applied, {already} already there, {len(missed)} missed")
        for finding, hits, expected, snippet in missed:
            print(f"   MISSED [{finding}] {hits} hits (expected {expected}): {snippet}")
    sys.exit(1 if verify() else 0)
