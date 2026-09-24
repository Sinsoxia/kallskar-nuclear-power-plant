# Decisions needed before these review findings can be fixed

Nine findings from `docs/review/CODE_REVIEW.md` cannot be fixed until someone decides how the plant should behave.
Each proposal below states what the code does today, what the spec says (section numbers only), the options, and a
recommendation. One further item came up while fixing L1, and one test the review asked for under L12 is deferred;
both are at the end. More came up later: D-046+ while implementing D-046, M7+ in the review of PR #5, and D-050+
while implementing the amended D-050.

| ID | Question | Recommendation |
|---|---|---|
| H5 | How does a runback settle at its target? | A power ramp at the table rate that ends at the target |
| M1 | Who counts as a developer on a live server? | Nobody (Studio only) |
| M5 | What does Persistence save under §14.6? | The §14.6 list, and a server close counts as a trip |
| M6 | How is a control bound to its panel? | A §10.2 desk map in Config, checked in Commands |
| M7 | Does `pss.bypass` need the critical-control playtime? | Yes, plus the §10.2 shift-supervisor authorisation |
| M8 | How should the IQS shape step coexist with fast ticks? | Double-buffer the shape |
| L2 | What exactly is the two-button manual trip? | Two distinct MCR buttons within a coincidence window |
| L4 | Should Detectors read `core.*` fresh? | Yes; decide separately whether lagged reads are snapshotted |
| L13 | Where do the unexplained test tolerances come from? | Derive most from the method; record the rest as decisions |
| L1+ | Should alarms have a reset deadband? | Yes, the channel's own noise |
| L12 (deferred) | Where can a whole-fast-lane P99 test run reliably? | In Studio, with the headless run logging it |
| D-046+ | What should flow auto do with two pumps once RB-2 ends? (RB-1 is open for the steam plant) | Leave it: §9.4's weakness |
| M7+ | Should the PROT-CHANNEL fault obey D-055's bypass limits? | No, but make it visible and keep its bypass its own |
| D-050+ | Should the DNDs' alarm wait longer than 5 s before it goes out? | Yes, 10 s |

---

## H5: How a runback settles at its target

**Today.** Protection publishes a runback's target and rate, but nothing reads either. RB-1 drives every shim to
0 mm at 10 mm/s, which is a slow shutdown rather than a runback to 64 %FP. RB-2 and RB-3 only stand rod auto down.
While the cause persists, the runback restarts on every tick, so `runback.clear` can't stick. RB-3 is refused for
now because its target is not a number (M3).

**Spec.** §9.5's runback table gives each runback a trigger, a target and a rate:
- RB-1: 64 %FP at 30 %/min, through the shim drive-in at 10 mm/s plus the flow programme.
- RB-2: 60 %FP at 60 %/min.
- RB-3: "bypass-limited power" at 20 %/min.

Other relevant sections: §3.4 gives the 10 mm/s drive-in, §7.3 the bypass capacity (60 % indefinitely), and OD-7
makes RB-2 automatic. §9.4's rod auto moves the regulating rods only.

**Options.**
- **A. Stop the drive-in at the target.** Protection clears the drive-in once neutron power is at or below the
  target, and starts runbacks only on the alarm's rising edge. The rate is then whatever the rods give, not the
  table's rate. RB-2 and RB-3 still have no actuator.
- **B. A runback demand.** Protection ramps a power demand from the present power down to the target at the table
  rate. RB-1's shims drive in only while measured power is above that ramp. The runback ends when power is within
  rod auto's band of the target, and rod auto then takes over. This follows the rate column, but it needs an
  actuator for RB-2 and RB-3.
- **C. A runback on the load.** RB-2 and RB-3 ramp the steam plant's load (the IHX sink) to the target at the
  table rate, and the reactor follows as it does for a load change (D-034). RB-1 does the same, plus the shim
  drive-in §9.5 names.

**Recommendation.** B for the shape of every runback, with C's load ramp as the actuator for RB-2 and RB-3. Start
runbacks on the alarm's rising edge. Keep RB-3 refused until the turbines exist and §7.3 gives its target a number.

## M1: Who counts as a developer on a live server

**Today.** `isDev` in `Main.server.luau` returns true in Studio, for the place creator, and for any private-server
owner. A dev actor skips the reach check and the critical-control playtime check. In M1 no panel has a position
yet, so on a live server these are the only players whose commands work.

**Spec.** §10.7 and §14.4 apply reach and, for critical controls, playtime to every player. §14.6 gives the
private-server owner one extra power: the reset, from a settings panel. The README makes `Dev/` Studio-only tooling.

**Options.**
- **A. Studio only.** Live servers have no dev actors. Until panels exist, nobody can operate a live plant; they can
  only watch it.
- **B. Studio plus an allowlist.** A Config list of developer user ids (`engineering` provenance) for live
  debugging, and they still pass the playtime check.
- **C. An `owner` actor kind** for private-server owners, carrying only the §14.6 powers (the reset already works
  this way through `Persistence.requestReset`), with no exemption from reach or playtime.

**Recommendation.** A now. Add B only if live debugging is needed, and keep C to the §14.6 reset. Nobody outside
Studio should skip the playtime check.

## M5: What Persistence must save under §14.6

**Today.** Only DecayHeat saves anything. A private server comes back as a fresh Mode 3 plant carrying the old decay
heat (about 220 MW if it was saved at full power).

**Spec.** §14.6 says plant condition persists per private server (OD-9), and names what it keeps: the cycle day and
burnup, fatigue usage for every component, failed, isolated and drained equipment, cold-trap loading, the LCO
clocks, and the sequence-of-events log. The reset returns the plant to "hot standby at beginning of cycle, as new".
Under D-037, decay heat is saved and offline time is not aged.

**Options.**
- **A. Save everything dynamic,** so the plant resumes exactly where it stopped, even at power. This is faithful,
  but a server can close at any moment, mid-transient.
- **B. Save exactly §14.6's list,** and boot the dynamic state into hot standby. In M1 that list means:
  - stuck rods and stopped loops and pumps,
  - shutter demands and trip bypasses,
  - active faults (`Faults.active`),
  - the LCO clocks, once they exist, and the event log.

  The restored decay heat then means "the plant tripped when the server closed", with nothing else consistent with
  that.
- **C. B, and treat a server close as a reactor trip.** Restore the rods in with the scram latched, plus the pool,
  fuel and cover-gas temperatures, so the saved decay heat lands in a plant that matches it.

**Recommendation.** C. Each system gets a `save`/`load` pair for its §14.6 items and thermal state, and a new test
saves and loads all ten systems in one round trip. The per-item list is the decision.

## M6: How a control is bound to its panel

**Today.** Commands checks that the player is within reach of whatever panel the client names. Nothing checks that
the named panel carries the control, so once panels exist, standing at any panel is enough to operate every
control.

**Spec.** §10.6's build rule says anything that changes plant state is a physical control on a panel. §10.2 lists
each desk's controls. For example, the RO desk carries the rods and trip buttons, the PO desk the pumps, pony motors,
IHX shutters and cover gas, and the SS desk the mode key and authorisations. §10.7 sets reach at about 10 studs, and
§14.4 has the server check distance.

**Options.**
- **A. A §10.2 desk map in Config** (`spec` provenance): command kind → the desks that carry it. Commands checks
  that `cmd.panel` is one of them. Trip buttons appear on both the MCR and BCR desks.
- **B. Attributes on the panel instances,** listing the kinds each panel hosts, read at run time. This needs the
  panels to exist.
- **C. Derive the panel from the target's Appendix B tag.** It only works for tagged equipment.

**Recommendation.** A now, behind a pluggable `panelHosts(panel, kind, target)` service like `panelPosition`.
Switch to B when the panels are built.

## M7: Whether `pss.bypass` needs the critical-control playtime

**Today.** A player with 0 h of playtime who is within reach can bypass every §9.5 trip row. A manual trip needs
3 h.

**Spec.** §10.7's critical list names the manual reactor trip, the SSS trip, turbine trips, breakers, loop drain,
SG section dump and mode changes. It has no bypass entry, because the spec has no bypass control. §10.2 gives the
shift supervisor's desk "authorisations for bypasses, isolations and fast ramps". §9.6's LCOs assume trips are
available.

**Options.**
- **A.** Add `pss.bypass` and `runback.clear` to `criticalControls` (the playtime gate).
- **B.** A bypass needs a prior authorisation issued from the SS desk (§10.2), so it takes two people.
- **C.** Cap the number of rows bypassed at once, for example to one, and never a neutron-flux row. The cap is a new
  `decision()` value.

**Recommendation.** A and B together, following §10.2, with C's cap. The cap's value is part of this decision.

## M8: The IQS shape step and the fast ticks (latent until IQS replaces the facade)

**Today.** The time-sliced shape step sweeps `self.psi` in place. Every fast tick between slices computes ρ from a
half-updated, un-normalised shape, and advances the node precursors with it. D-031 keeps IQS off the plant for now.

**Spec.** §14.2 has the shape step run in a coroutine that yields at 4 ms "while the amplitude keeps power moving",
and renormalised "so shape and amplitude stay consistent". D-014 records the shape-step method.

**Options.**
- **A. Double-buffer ψ.** Iterate on a copy and swap at the end. The cost is one extra 26,264-entry array, allocated
  once. Ticks use the previous shape until the swap.
- **B. Freeze the parameters** (ρ, β_eff, Λ) at the start of a shape step, and let the amplitude run on them. The
  ticks then ignore feedback for up to 2 s.
- **C. Finish the shape step in one frame.** This breaks §14.2's 4 ms slice.

**Recommendation.** A. Do it together with allocating the shape step's work arrays once (the part of L9 left for
this).

**Also measured (while doing the L12 follow-up).** `IQS.shapeStep` calls `Diffusion.assemble` before its first
budget check, and on the full K1 mesh (26,264 unknowns) that assembly takes 7.35–7.84 ms headless on the
development host (median 7.46 ms over seven runs). So every shape step's first slice overruns the 4 ms slice by
more than the slice itself. Whichever option is chosen, the assembly needs budget checks inside it too, for
example one per energy group, or it should run only when the cross sections have changed.

## L2: The two-button manual trip

**Today.** Protection counts MCR presses and trips on the second, whenever it comes and whoever makes it. Only a
trip reset clears the count, so a single stray press stays armed indefinitely.

**Spec.** §9.5's manual row calls for 2 buttons in the MCR and 1 in the backup control room. §10.2 puts the trip
buttons on the RO desk. §10.7 makes the manual trip a critical control, and allows a vote-kick after an unjustified
trip. §14.4 mentions hold durations for local actions.

**Options.**
- **A.** Two distinct buttons (`MCR-1`, `MCR-2`) pressed within a coincidence window. The window is a new
  `decision()` value.
- **B.** A, and the two presses must come from two different players (anti-solo, and a guard against griefing).
- **C.** Both buttons *held* at once, as hold-duration prompts, with no window needed.

**Recommendation.** A. The window is the decision (about 2 s would be typical). B is worth considering given
§10.7's vote-kick. Update `ProtectionSpec`'s two-button test to match.

## L4: Detectors' lagged reads, and lagged reads in general

**Today.** Detectors reads `core.power_pctFP` and `core.k` as lagged, although no cycle requires it. Every neutron
trip therefore reaches the rods at t+2 (0.2 s). Separately, four lagged reads (after L5) are fresh, because their
writer happens to run first.

**Spec.** §14.1 puts protection logic in the 10 Hz fast lane, and §9.5 gives setpoints but no response time. D-025
derived the instrument filters without reference to this delay.

**Options.**
- **A.** Keep 0.2 s, and document it as the modelled instrument and logic delay.
- **B.** Move Detectors' two reads to `reads`, giving t+1. This creates no cycle, and changes the timing of the
  PR-HIGH, flux-rate and period trips by one tick.
- **C.** Have the Scheduler snapshot lagged channels at the start of each tick, so "lagged" always means last tick's
  value. Protection's `rods.*` reads and AutoControls' `rods.position_mm` would each gain a tick.

**Recommendation.** B. Decide C on its own merits: L5 has already reworded the contract to match what the Registry
does today.

## L13: A stated basis for the remaining test tolerances

**Today.** The review's L13 table lists ten tolerances with no stated basis in published rounding or the method.

**Rule.** The README says no guesswork, and the project rule is that a tolerance comes from published rounding or
from the method. §3.7 gives its own validation tolerances, and those are not in question.

**Options for each item.**
1. Derive it from the method. For example, CoreSpec's D-030 floor comes from the prompt drop and the inhour decay,
   and the Detectors statistics come from the sample count.
2. Tighten it to the published rounding: AutoControls to 0.5 K, and IHX's six-unit total to 12 MW.
3. Keep it, and record why as a D-xxx decision. This fits timing and performance margins such as FrameworkSpec's 3×
   slice budget.

**Recommendation.** Options 1 and 2 for everything except the timing margins, which take option 3. The table in
CODE_REVIEW.md gives the derived value for each item.

## L1+: An alarm deadband (raised while fixing L1)

**Today.** An alarm goes in and out on every crossing. On the ±1 K CORE-OUT thermocouple it can chatter at 10 Hz
near 565 °C, and the PR alarm does the same near 105 %FP on 0.5 % noise.

**Spec.** §9.5 gives the alarm setpoints. §2.5 gives the thermocouples' ±1 K and 3 s lag. D-025 gives the neutron
channels' noise.

**Options.**
- **A.** Each row's alarm clears only once the signal is back by that channel's noise amplitude (1 K, 0.5 %FP,
  and so on). This is derived, not chosen.
- **B.** An alarm must persist for N seconds before it goes in or out, like the period block. N is a new number.
- **C.** Leave it.

**Recommendation.** A.

## L12 (deferred): A whole-fast-lane P99 test

**Today.** FuelThermalSpec's "full-plant step fits the fast-tick budget on average, with its P99 logged" times
FuelThermal alone. It asserts FuelThermal's mean step against `Engineering.fastTickBudgetP99_s` (5 ms) and only
logs its P99. No test runs the whole fast lane through the Scheduler and checks `Scheduler:report().fastP99_ms`
against that budget, and the budget is about the whole lane. The review asked for that test under L12, and
PR #4 does not add it.

**Why it is deferred.** A P99 over a few hundred headless samples is set by single garbage-collection pauses.
FuelThermal's own P99 ranged from 3.1 to 4.8 ms between runs on the development host (2.5 ms on the CI runner),
against 5 ms for the whole lane, so as an assertion it would fail at random rather than when the code gets slower.
Lune's timing is also not a Roblox server's (no native code generation, a different collector), so a headless
pass would not show that the budget holds in a live server.

**Options.**
- **A. Headless**, on the M1 plant as Main builds it, over enough fast ticks for a stable P99 (for example 3,000,
  or 300 s of simulated time). The CI runner's speed then becomes part of the test.
- **B. In Studio only**, with the headless run marking it pending and saying why. The harness reports `IsStudio`
  as true, so this needs its own flag.
- **C. Log only.** The P99 is logged headless and in Studio, and the budget is watched rather than asserted. The
  Scheduler's report already carries `fastP99_ms`.

**Recommendation.** B, with the headless run also logging the whole lane's P99 (C) so that CI shows the trend.

## D-046+: The runbacks' own triggers at full power (found while implementing D-046)

**Decided.** Aqua chose §4.2's mechanism (Rev A5, F27), recorded as the D-046 amendment in docs/DECISIONS.md. On a
primary pump trip the surviving pumps ramp to 105 % at 2 %/s and hold there while RB-2 runs, and flow auto takes them
back when the runback ends. A pump trip at full power with flow auto in now runs back without a trip: P/Q peaks at
1.040, against 1.122 and a PQ trip at 10.4 s before, and RB-2 completes at 40 s (PlantSpec).

**Still open: flow auto after RB-2.** §9.4's flow auto ignores a pump trip, so when RB-2 ends it takes the two
surviving pumps back to the three-pump programme's demand: 69 % at the end of the runback. That gives the core about
two thirds of the flow the programme means to. With flow auto left in, the plant trips on PQ 16.4 s after RB-2
completes. The crew has the 40 s of the runback and those 16 s to take flow auto out or set the pumps.
- **A. Leave it.** It is the weakness §9.4 builds in on purpose ("deliberately worse than a crew"), and a crew that
  leaves flow auto in after a pump trip should expect it.
- **B. Flow auto drops to manual on a pump trip,** as rod auto does on a reactor trip (D-035). The pumps then stay at
  105 % after RB-2. This softens the §9.4 weakness.
- **C. The drives hold 105 % until the crew acts** (a speed command, or flow auto selected again), rather than until
  RB-2 ends. This departs from "flow auto takes them back when the runback ends".

**Recommendation.** A, because it is what §9.4 says. If the trap is too sharp in playtesting, B.

**Open for the steam-plant milestone: RB-1.** Losing a secondary loop at full power still trips the reactor on
INLET-HIGH before RB-1 completes. That happens at 53.1 s and 72 %FP with flow auto in, and at 45.9 s and 76 %FP with
it out. The M1 heat sink has no secondary inventory, so a stopped loop's capacity goes at once. At 30 %/min, the
excess heat raises the core inlet past 405 °C before the power gets down to what two loops can carry. The IHX header
records this as an M1 limitation. It is fixed by the secondary loops' own model, their inventory and pump coastdown,
which is part of the steam-plant milestone. The table rates stay as they are.

## M7+: The PROT-CHANNEL fault and D-055's bypass limits (found in the review of PR #5)

**Today.** D-055 limits the `pss.bypass` command: it is a critical control, at most `bypassedRowsMax` (1) rows are
out at once, and a neutron row (PR-HIGH, PR-LOW-SP, PERIOD, FLUX-RATE, SSS-FLUX) is refused. The PROT-CHANNEL fault
does not go through the command. Its `arm` sets the row's bypass directly, so:
- it is not counted against the cap, so an operator's bypass and the fault's make two rows out at once;
- it bypasses a neutron row, and with no `signal` parameter it bypasses PR-HIGH, which is one;
- a row it holds does count against the operator's next bypass, whose refusal names that row ("PR-HIGH is already
  bypassed; restore it first"), so the refusal gives the fault away;
- an operator can restore the row with `pss.bypass` value 0, which ends the fault's effect while the fault stays
  active; and the fault's `clear` removes a bypass the operator set on the same row before the fault.

**Spec.** The spec has no bypass control and no PROT-CHANNEL fault. §9.6's LCOs assume the trips are available,
and §10.2 gives the shift supervisor's desk "authorisations for bypasses".

**Options.**
- **A. The fault is outside D-055,** as today. It stands for a bypass nobody authorised, which the cap and the
  neutron-row rule cannot stop because nobody asked them. A PR-HIGH default makes it the most serious one.
- **B. The fault obeys D-055:** it counts against the cap and never picks a neutron row, and its default becomes a
  process row (for example CORE-OUT).
- **C. A, but the fault's bypass is its own:** it is held apart from the operator's, so it neither takes the
  operator's one row nor gives itself away in a refusal, and a restore by command does not end it until the crew
  has found it (for example, a surveillance check that reveals it).

**Recommendation.** C. It keeps the fault's point, a trip missing without anyone deciding so, and removes the two
side effects a player can see.

## D-050+: The DNDs under the amended deadband rule (found while implementing it)

**Today.** The amended D-050 gives every channel with Gaussian noise a 3σ deadband and a 5 s off-delay.
`tools/derive/alarm_deadband.py` finds each row's worst steady level. PR-HIGH flickers once every 4.5 h there. The
DNDs flicker once every 50 min, at 89 cps (2.2 × background). The power range draws fresh noise every tick. The
DNDs' ratemeter (a 1 s filter) carries each reading into the next, so six readings stay back past the deadband for
5 s far more often than 50 fresh draws would. Only the DND-HIGH fault holds the DNDs near that level.

**Spec.** §3.5 gives the DND background (about 40 cps) and §9.5 the ×3 alarm. D-025 gives the ratemeter's 2 s
averaging.

**Options.**
- **A. Keep 5 s** for every Gaussian channel, as decided. The DNDs flicker once every 50 min, and only under a fault.
- **B. An off-delay per row,** long enough that the DNDs match PR-HIGH. With the same deadband, the derivation gives
  once every 4.0 h at 10 s, 20 h at 20 s and 53 h at 30 s.
- **C. A wider DND deadband,** in place of a longer off-delay.

**Recommendation.** B, with 10 s for the DNDs. It brings them in line with PR-HIGH without changing the deadband
rule.
