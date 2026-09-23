# Headless tests (Lune)

The Luau test suite (`tests/*Spec.luau`, run by `tests/Runner.luau`) runs outside Roblox Studio on
[Lune](https://github.com/lune-org/lune), on a developer machine and in GitHub Actions. Nothing in `src/` or `tests/`
was changed to make that work: the harness builds the same place Studio would load and starts the suite the way a
Studio Play session does.

## Run it

Linux or macOS, from the repository root:

```sh
tools/lune/test.sh                  # everything: install tools, self-test the harness, build, run all specs
tools/lune/test.sh --filter Core    # only spec modules whose name contains "Core" (the Runner's TestFilter)
```

`test.sh` installs the Lune and Rojo versions pinned in `rokit.toml` into `tools/lune/.bin/`, checking each download
against `tools/lune/tools.sha256` (needs `bash`, `curl`, `unzip`, `sha256sum` or `shasum`). Later runs reuse them.

Any OS with [rokit](https://github.com/rojo-rbx/rokit), including Windows:

```sh
rokit install
lune run tools/lune/selftest
lune run tools/lune/run-tests
```

`run-tests` options: `--filter <text>`, `--place <file.rbxl>` (skip the Rojo build), `--rojo <path>`,
`--no-audit`, `--no-native` (interpreter only, to measure what native code buys), `--timeout <s>` (default 3600),
`--out <dir>` (default `tools/lune/.out`). It exits 0 when every outcome matches `tools/lune/expectations.luau`,
and 1 otherwise.

Each run writes these files to `tools/lune/.out/` (gitignored):

| File | Contents |
|---|---|
| `report.txt` | The Runner's own report, read back from `ServerStorage.KallskarTests.LastReport` |
| `results.json` | Every case with its status, time and message, plus the summary |
| `junit.xml` | The same results in JUnit format, for CI viewers |
| `audit.txt` | Which `src/` modules and scripts can run headless |
| `place.rbxl` | The place Rojo built |

## Result

Final run in the development container (Linux x86_64, 4 vCPU Xeon 2.8 GHz), on commit
`5b68d01` plus this document, with `tools/lune/test.sh`:

```
====================================================================================================
[harness] Runner summary: pass=180 fail=0 pending=1  (181 cases, 48.1 s)
[harness] audit: modules loaded headless: 54/54 (details in tools/lune/.out/audit.txt)
  BOOT ServerScriptService.Kallskar.Main: 10 systems, 10.0 s simulated in 600 Heartbeat frames, halted: no, 97 remote fires recorded (no clients)
[harness] longest stretch a script ran without yielding: 2.00 s (yield at ServerStorage.KallskarTests.CoreSpec:93, after "[KSK-TEST]   log Core :: Doppler pushes back when the fuel heats up (§3.2) :: fuel at 1380 K: ρ -768 pcm, of which Dop")
[harness] OK: every outcome matches expectations
====================================================================================================
```

The same suite in GitHub Actions (`ubuntu-24.04`, first run of `.github/workflows/tests.yml`): **pass=180 fail=0
pending=1**, 40.6 s for the specs and about 45 s for the whole job, tool installation included.

**No case fails headless.** So there is no failure to classify as a code bug or a harness gap, and
`tools/lune/expectations.luau` (the list of known failures) is empty.

| Spec module | Cases | Pass | Fail | Pending | Time here |
|---|--:|--:|--:|--:|--:|
| `tests/AutoControlsSpec.luau` | 11 | 11 | 0 | 0 | 36 ms |
| `tests/ConfigSpec.luau` | 15 | 15 | 0 | 0 | 2 ms |
| `tests/CoreSpec.luau` | 10 | 10 | 0 | 0 | 39.02 s |
| `tests/DecayHeatSpec.luau` | 7 | 7 | 0 | 0 | 0.20 s |
| `tests/DetectorsSpec.luau` | 11 | 11 | 0 | 0 | 1.12 s |
| `tests/DiffusionSpec.luau` | 6 | 6 | 0 | 0 | 0.14 s |
| `tests/FrameworkSpec.luau` | 24 | 23 | 0 | 1 | 94 ms |
| `tests/FuelThermalSpec.luau` | 8 | 8 | 0 | 0 | 1.98 s |
| `tests/IHXSpec.luau` | 17 | 17 | 0 | 0 | 1.12 s |
| `tests/IQSSpec.luau` | 6 | 6 | 0 | 0 | 1.74 s |
| `tests/KineticsSpec.luau` | 8 | 8 | 0 | 0 | 56 ms |
| `tests/MeshSpec.luau` | 6 | 6 | 0 | 0 | 11 ms |
| `tests/PartLoadSpec.luau` | 2 | 2 | 0 | 0 | 0 ms |
| `tests/PerfSpec.luau` | 2 | 2 | 0 | 0 | 1.34 s |
| `tests/PoolsSpec.luau` | 11 | 11 | 0 | 0 | 0.64 s |
| `tests/PrimaryPumpsSpec.luau` | 8 | 8 | 0 | 0 | 0.22 s |
| `tests/ProtectionSpec.luau` | 16 | 16 | 0 | 0 | 39 ms |
| `tests/RodDrivesSpec.luau` | 13 | 13 | 0 | 0 | 26 ms |
| **Total** | **181** | **180** | **0** | **1** | **47.8 s** |

The one pending case is pending by design, and it is not a failure (the Runner never counts pending as a pass):

- `Framework :: critical access policy when the playtime lookup fails`. `tests/FrameworkSpec.luau:498` calls
  `t.pending` because `Commands.criticalAccess` (`src/server/Framework/Commands.luau:116-117`) still raises
  `TODO(human)` when the playtime lookup returns nil. One thing to know when that policy gets decided:
  the error escapes `Commands.submit` from `checkPlayerAccess` (`Commands.luau:202`) before `refuse()` logs the
  attempt. `bindRemote`'s `pcall` (`Commands.luau:255`) turns it into "internal error", so that attempt never
  reaches the EventLog, and §10.7 says every attempt should. Players cannot reach this path today, because
  `Main.server` passes no `panelPosition` and every player command stops at "unknown panel". It becomes
  reachable once panels exist while `playtimeHours` is still the default (`Commands.luau:153`, which always
  returns nil).

<details><summary>Every case, by spec module</summary>

**AutoControlsSpec**

- PASS PrimaryPumps takes the flow auto's demand, and ignores a pump trip as §9.4 says
- PASS RodDrives obeys rod auto through the same interlocks as an operator
- PASS a rod withdrawal block stops rod auto withdrawing, but not inserting (§9.5)
- PASS flow auto's 10 s filter costs what §9.4 says, at the rates the plant can actually ramp
- PASS rod auto holds the band and does nothing inside it (§9.4)
- PASS rod auto moves one rod at a time, and keeps the three together (D-006, F6)
- PASS rod auto stands down for a scram or a runback
- PASS rod auto stops and alarms at the band rather than reaching for a shim (§9.4)
- PASS switching auto off releases the rods
- PASS the flow programme follows §9.2, with its 40 % floor and D-007's ramp
- PASS the setpoint follows §9.2's programme, not §9.4's flat 550 °C (D-003, F3)

**ConfigSpec**

- PASS NaN and functions are rejected
- PASS bare numbers are rejected at load
- PASS config is deeply frozen
- PASS core map totals agree (§2.2, §3.7, §2.1)
- PASS decay heat table follows the formula (§3.6)
- PASS derived and decision provenance point at real records
- PASS every numeric leaf has provenance
- PASS flow zones agree (§2.5)
- PASS kinetics groups agree (§3.1)
- PASS protection setpoints are ordered (§9.5)
- PASS reactivity budget and power defect add up (§3.2, §3.3)
- PASS rod layout fills exactly the non-fuel core positions
- PASS rod worths add up (§3.4)
- PASS thermal limits agree (§2.4)
- PASS tuning flag follows the spec dagger

**CoreSpec**

- PASS D-030: a shut-down plant sits at the bottom of §3.5's wide range span
- PASS Doppler pushes back when the fuel heats up (§3.2)
- PASS after a scram the neutrons go and the decay heat stays, on §3.6's curve (D-037)
- PASS seated at 20 %FP with both autos in, the whole plant holds §9.2's operating point
- PASS the pin power adds up, and is shaped the way §2.4 says
- PASS the plant boots subcritical, where §3.3's budget says it should
- PASS the prompt jump limit is reported rather than silently exceeded (§14.2)
- PASS the reactor follows the steam plant's load
- PASS the whole plant, wired together: hot standby holds, and at power a rod out is caught by Doppler
- PASS withdrawing worth raises reactivity, and the core answers (§3.1)

**DecayHeatSpec**

- PASS a negative power reading drives nothing
- PASS a trip after §3.6's 160 EFPD at full power reproduces every entry of its table
- PASS it boots at beginning of cycle, after the outage (§14.6, D-036)
- PASS it follows any history, not only §3.6's: an hour at full power from nothing, then a trip
- PASS steady power on the reference history holds decay at f_ref of that power
- PASS the exact update is the same on a 1 s tick as on ten 0.1 s ticks (§0.2's ×10)
- PASS the inventory saves and loads, and a save from another group set is left alone

**DetectorsSpec**

- PASS 1/M falls toward zero as the core approaches critical (§3.5)
- PASS NI-FAIL: a failed channel is outvoted, a frozen one is the dangerous kind
- PASS a real power rise shows up as a period the meter can read
- PASS delayed neutron detectors: background, and DND-HIGH against §9.5's factors
- PASS every channel count matches §3.5
- PASS period noise cannot fake §9.5's period rod block
- PASS power range noise cannot reach §9.5's trip or its flux rate trip
- PASS source range noise is counting statistics, not a tuned figure
- PASS the source range high voltage drops out above §3.5's 1e-3 %FP, with hysteresis
- PASS the three source range channels are independent, which is what voting needs
- PASS §3.5's 250 cps with all rods in follows from §3.3 and §3.4

**DiffusionSpec**

- PASS adjoint operator is the exact transpose, with and without D-hat
- PASS albedo maps to the diffusion boundary parameter
- PASS forward and adjoint eigenvalues agree on a heterogeneous core
- PASS infinite medium reproduces the algebraic 4-group k-infinity
- PASS plane waves are exact eigenvectors of the hex-Z operator
- PASS slab with Marshak vacuum faces converges to the diffusion k at second order

**FrameworkSpec**

- PASS System defaults and command routing
- PASS System.extend validates specs
- PASS System.new rejects non-classes and mixin never overrides
- PASS bus delivers, isolates failures and rejects unknown topics
- PASS command sanitising rejects hostile input
- PASS commands route, check access and log every attempt (§10.7)
- PASS core map packet matches §14.1 (331 × u16 at 0.05 K)
- PEND critical access policy when the playtime lookup fails — waiting for Aqua's policy (TODO(human) in Framework/Commands.criticalAccess)
- PASS event log sequences, wraps and replays
- PASS external inputs can be read but only set externally
- PASS faults arm, clear and respect eligibility
- PASS gauge packets round-trip and respect the byte budget
- PASS owner reset needs the owner, the phrase and a countdown
- PASS persistence saves, loads and migrates (§14.6)
- PASS ports enforce declared reads and writes
- PASS registry orders writers before readers, ties by name
- PASS registry rejects unknown reads, double writers, duplicate commands and faults
- PASS registry reports cycles and accepts lagged back-edges
- PASS scheduler clocks and slow lane cadence (§0.2, §14.1)
- PASS scheduler fails stop on a system error
- PASS scheduler limits catch-up and counts dropped time
- PASS sliced tasks respect the frame budget and refuse re-entry
- PASS strict records catch typos in Studio
- PASS tags follow Appendix B

**FuelThermalSpec**

- PASS average channel at full power matches the derivation (§3.2 1,380 K)
- PASS full power with spec flow zoning gives the §2.4 outlet and heat balance
- PASS full-plant step fits the fast-tick budget
- PASS hottest channel reproduces the §2.4 cladding hot spot
- PASS no power and no flow stays finite and isothermal
- PASS pellet kernel: exact Θ inverse and the derivation's layer temperatures
- PASS power step: fuel lag lies within the derivation's layer time constants
- PASS sodium properties reproduce the Appendix A table

**IHXSpec**

- PASS a reactor trip trips the turbines: the load goes to zero at once and stays there
- PASS a warmer secondary inlet takes duty off its own two units only
- PASS an override holds one loop by hand until it is handed back to the programme
- PASS closed loop: Pools and IHX find §2.4's 550 °C and §4.3's 375 °C by themselves
- PASS commands are validated
- PASS each unit's duty balances on both sides
- PASS faults: a lost loop and a shutter drifting closed
- PASS hot standby is not cooled: no load takes no heat out of a pool at its own temperature
- PASS less primary flow means less duty but a colder primary outlet
- PASS losing a secondary loop stops its two units and is announced
- PASS secondary flow follows the primary flow the pumps deliver (D-032)
- PASS the cold leg stays inside what the steam plant can give
- PASS the design point reproduces every figure in §4.3
- PASS the inlet shutter strokes in §4.3's 60 s and moves its flow to the others
- PASS the load ramps at §7.1's 5 %/min, and at LCO-10's 1 %/min above 40 %
- PASS the published LMTD is the log mean of the model's own four temperatures
- PASS the steam plant takes exactly its load at every row of §9.2, on the programme's own flow

**IQSSpec**

- PASS absorber transient tilts power away from the absorber
- PASS initial state is critical with equilibrium precursors
- PASS shape step runs time-sliced inside the scheduler budget
- PASS static consistency: converged shape gives the exact eigenvalue reactivity
- PASS uniform fission-side perturbation includes the generation-time change (D-017)
- PASS §14.2 development check: uniform loss-side perturbation matches point kinetics

**KineticsSpec**

- PASS all three RR out: period and prompt-jump margin (§3.4, S-19, F7, F12)
- PASS critical steady state is exact (D-011: β = Σβᵢ)
- PASS negative period approaches the slowest delayed group
- PASS oracle lags follow their §3.2 time constants
- PASS oracle reproduces the spec's power defect (file 20)
- PASS positive period matches the inhour equation
- PASS prompt jump matches β/(β − ρ)
- PASS subcritical source multiplication and the prompt-critical guard

**MeshSpec**

- PASS material sets follow position kind and layer
- PASS neighbours are symmetric, one pitch apart, and the boundary has 6(2n+1) faces
- PASS ring bookkeeping (§2.2)
- PASS rods sit where D-010 says and leave the right fuel counts
- PASS sizes match §3.7
- PASS three-colouring is proper radially and axially (D-001)

**PartLoadSpec**

- PASS secondary flow is the primary flow column, which is what §9.2's own heat balance gives
- PASS the secondary cold leg regenerates §9.2's column, and is 375 °C with no load

**PerfSpec**

- PASS full-core eigenvalue from a cold start (logged)
- PASS shape step fits the §3.7/§14.2 time budget

**PoolsSpec**

- PASS CG-LEAK: make-up holds a leak it can match, and loses one it cannot
- PASS boots at hot zero power with the cover gas on its setpoint
- PASS cover gas commands: manual valve needs manual control
- PASS cover gas: the §4.4 90 m³ swing and the 0.074 MPa fixed-inventory cooldown
- PASS energy is conserved, counting the sodium in the transport line
- PASS full power settles on §2.4's 550 °C mixed outlet and §2.5's 375 °C inlet
- PASS pump heat lifts the core inlet above the IHX outlet (§4.2)
- PASS the cold pool sees nothing for the §4.1 transport delay
- PASS the hot pool's first node is 40 s of flow, and that scales as 1/flow
- PASS the make-up valves open fully, then close in at the D-020 time constant
- PASS §4.1's mixing times are the pools' own residence times

**PrimaryPumpsSpec**

- PASS a pump trip is logged and published on the bus
- PASS coastdown follows Q₀/(1 + t/10 s)
- PASS commands are validated
- PASS natural circulation is the floor with no pumps (§4.2, Rev A4)
- PASS pony motor holds 10 % speed under the coastdown
- PASS rated flow and pump heat at 100 % speed (§4.2)
- PASS speed ramp is limited to §4.2's 2 %/s
- PASS start interlocks follow §4.2

**ProtectionSpec**

- PASS D-004: the core inlet low trip is inhibited by mode, and says so
- PASS PR high flux trips 2-out-of-4, not 1 (§9.5, D-005)
- PASS a bypassed signal cannot trip, and the bypass is logged
- PASS a plant at §9.5's normal column does not trip, alarm or block
- PASS a trip latches until reset, and reset is refused while the signal is present
- PASS assembly outlet deviation needs two channels, not one (§9.5)
- PASS every §9.5 trip row exists, and the ones M1 cannot drive yet sit at safe values
- PASS first-out latches the signal that went first, not the loudest
- PASS flux rate trips on a fall as well as a rise (§9.5, Phénix-style)
- PASS losing pumps and loops: one is a runback, two is a trip (§9.5)
- PASS manual trip needs two buttons in the control room, or one in the backup
- PASS power to flow: alarm and rod block at 1.05, trip at 1.12, armed above 5 %FP
- PASS the 25 %FP low setpoint protects a startup and bypasses itself above the permissive
- PASS the Curie latch releases the SSRs at 640 °C with its thermal lag (§9.5)
- PASS the SSS is diverse: it trips on pump-speed flow when the flowmeter says otherwise
- PASS the period trip and rod block are armed only below 10 %FP, and the block persists (D-025)

**RodDrivesSpec**

- PASS RD-STUCK: the most reactive rod stuck is §3.4's shutdown margin case
- PASS a bank moves at its own slower speed (§3.4)
- PASS a rod withdrawal block refuses withdrawal and stops one in progress (§9.5)
- PASS a scram cannot be withdrawn from until it is reset, and reset needs every rod in
- PASS a single rod moves at its §3.4 speed, and only one thing moves at a time
- PASS boots in hot standby with all thirty drives where §3.4 parks them
- PASS runback drives the shim banks in at 10 mm/s and takes the plant off the operator
- PASS scram: 90 % in §3.4's 1.2 s for the PSS and 2.0 s for the SSR
- PASS the SSRs withdraw only (§3.4)
- PASS the interlock clamps a speed that would break it, rather than trusting the table
- PASS the regulating band is published for §9.5's rod block
- PASS the worth curve reproduces §3.4's table
- PASS §3.4's speeds keep the withdrawal rate inside the 4 pcm/s interlock

</details>

### What else runs headless (the audit)

After the specs, the harness boots a fresh copy of the place and checks the rest of `src/` (this never fails the run):

- **All 54 ModuleScripts under `src/` load**: every `require` succeeds.
- **`ServerScriptService.Kallskar.Main` (the real server bootstrap) boots.** It builds all 10 systems, wires
  commands, replication, persistence and the dev panel, and connects to `RunService.Heartbeat`. The harness then
  fires 600 Heartbeat frames at 1/60 s. The plant simulates 10.0 s without halting, and the replicator's 97
  remote fires are recorded (no client exists to receive them).
- **One script cannot run headless:** `StarterPlayer.StarterPlayerScripts.Kallskar.Dev.DebugPanel`
  (`src/client/Dev/DebugPanel.client.luau`), a LocalScript. It is blocked at line 42 by
  `Players.LocalPlayer:WaitForChild("PlayerGui")`: `Players.LocalPlayer` is nil on a server, so the error reads
  `attempt to index nil with 'WaitForChild'`. It needs a client, which a headless server does not have. No test
  depends on it.

## How it works

```
rojo build default.project.json ──► place.rbxl ──► roblox.deserializePlace ──► DataModel (real instances)
                                                                                    │
  Engine.boot: Roblox globals, require, the instance members Lune lacks ◄───────────┘
                                                                                    │
  set RunTests (+ TestFilter) on ServerStorage.KallskarTests, start Dev/TestBoot ◄──┘  (what Play does)
      └► TestBoot: RunService:IsStudio() ─► require(Runner) ─► task.defer(Runner.run)
            └► Runner: every *Spec ─► LastReport, LastPass/LastFail/LastPending, LastDone
  harness waits for LastDone, reads LastReport, compares with expectations.luau, writes reports, runs the audit
```

- **The DataModel is real.** Rojo 7.7.0 builds `default.project.json` exactly as `rojo serve` syncs it, and Lune's
  `roblox` library deserialises the place. Instance names, classes, hierarchy, attributes, `StringValue.Value` and
  every ModuleScript's `Source` are what Studio would have. The suite's own entry points, `TestBoot` and `Runner`,
  run unchanged. They find the specs, write `LastReport`, and set the attributes the harness reads back.
- **`require(ModuleScript)`** (`tools/lune/lib/Engine.luau`) compiles the module's `Source` with `luau.load` and runs
  it once, caching the value per ModuleScript. It uses Roblox's error texts: `Requested module was required
  recursively`, `Requested module experienced an error while loading`, `Module code did not return exactly one
  value`. Chunks are named with the instance's full name, so errors and tracebacks read
  `ServerScriptService.Kallskar.Framework.System:123: ...` as they would in Studio.
- **Globals come in through a one-line prelude.** `script`, `require`, `game`, `workspace`, `task`, `Instance`,
  `Enum`, `Random`, `tick`, the datatypes and the rest are passed to each chunk as locals, by
  `local script, require, game, ... = ...;`. That line is inserted at the start of the first line after the `--!`
  hot comments, which has three effects:
  - line numbers match the file on disk;
  - `--!strict`/`--!native` stay directives;
  - the chunk keeps Luau's safe global environment.

  The obvious alternative, a custom environment table per chunk, turns off Luau's fast builtin calls and native
  code. Measured on this suite, that made the numeric kernels about 5× slower, and `PerfSpec` and `FuelThermalSpec`
  missed their time budgets.
- **`--!native` modules compile to native code**, as they do on Roblox servers (`Diffusion`, `IQS`, `Kinetics`,
  `FuelThermal`, `FuelThermal/Pin`). The PerfSpec shape-step budget depends on this: 84.6 ms native against
  370.5 ms interpreted, where the budget is 120 ms (`--no-native` reproduces the failure).
- **`tools/lune/selftest.luau`** checks the engine layer before every run: require semantics and messages, line
  numbers through the prelude, native codegen, globals, bindables, WaitForChild and the Random stand-in's
  statistics. Its checks were confirmed to fail when the prelude shifts a line or codegen is off.

### Engine surface emulated

| Roblox API | Headless behaviour |
|---|---|
| `game`, `workspace`, `game:GetService` | Lune's DataModel; services are created on first `GetService` |
| `game.PlaceId/GameId/CreatorId/CreatorType/JobId/PrivateServerId/PrivateServerOwnerId` | Studio's values for an unpublished place (0 / User / ""), because Lune's reflection database has no defaults for them |
| `game:BindToClose` | Callback kept, never called (the headless server never shuts down through the engine) |
| `Instance:WaitForChild` | Returns the child once it exists. With a timeout, returns nil after it. Without one, raises after 10 s, where Roblox would wait forever |
| `Instance.new(class, parent?)`, children, attributes, `IsA`, `GetFullName`, … | Lune's own implementation |
| `BindableEvent.Event` / `:Fire`, `BindableFunction` | Handlers deferred (`task.defer`). Arguments deep-copied: tables arrive without metatables, functions as nil |
| `RemoteEvent`, `UnreliableRemoteEvent`, `RemoteFunction` | No clients: fires are recorded and never delivered; `Invoke*` raises |
| `RunService:IsStudio()` | `true` (TestBoot only runs the suite in Studio; `System.record`'s strict mode needs it) |
| `RunService:IsServer/IsClient/IsRunning`, `.Heartbeat`/`.Stepped`/… | Server, running. Frame events exist but fire only when the audit drives Main |
| `Players` | An empty server: `GetPlayers()` is `{}`, and `PlayerAdded`/`PlayerRemoving` never fire |
| `DataStoreService` | Every call raises (no backend). The specs use `Persistence.MemoryStore` |
| `HttpService:JSONEncode/JSONDecode/GenerateGUID` | Lune's serde (no HTTP requests) |
| `task.*`, `wait`/`delay`/`spawn`, `tick`, `time` | Lune's scheduler. `task.synchronize/desynchronize` are no-ops |
| `Random.new` | Stand-in generator (next section) |
| `Vector3`, `CFrame`, `Color3`, `UDim2`, `Enum`, … | Lune's `roblox` datatypes |
| `table.freeze`, `buffer`, `os.clock`, `string`, `math`, `bit32`, `debug.traceback` | Luau itself (Luau 0.709, as bundled in Lune 0.10.5) |

## Where headless can differ from Studio

None of these changes a result in the current suite, but they are the places to look first if Studio and the
headless run ever disagree:

1. **`Random` produces a different sequence.** Roblox's generator is undocumented, so the harness uses
   xoshiro128**. It is deterministic per seed, keeps independent streams per object, and returns uniform 53-bit
   doubles (checked by the self-test). DetectorsSpec and PoolsSpec only assert statistics, so they pass either
   way. An assertion on one specific noisy sample would not carry over.
2. **There is no script timeout.** Studio aborts a script that runs too long without yielding, and the headless
   run cannot. Instead, the harness reports the longest stretch any script ran between yields. It was 2.00 s in the final run here
   and 1.67 s in CI, at `tests/CoreSpec.luau:93` (the first yield of a whole-plant test, which includes building
   the plant). Compare that with your Studio script-timeout setting.
3. **Timing assertions measure the host.** Four cases time real work with `os.clock`. The results below are
   properties of the machine running them, not of a Roblox server:

   | Case | Assertion | Here | GitHub runner |
   |---|---|--:|--:|
   | `Perf :: shape step fits the §3.7/§14.2 time budget` | worst shape step ≤ 120 ms; one sweep ≤ 4 ms | 84.1 ms; 0.88 ms | 63.8 ms; 0.66 ms |
   | `FuelThermal :: full-plant step fits the fast-tick budget` | mean step < 5 ms | 2.20 ms | 2.11 ms |
   | `Framework :: sliced tasks respect the frame budget and refuse re-entry` | worst slice < 12 ms | 4.06 ms | 4.02 ms |
   | `IQS :: shape step runs time-sliced inside the scheduler budget` | converges (slice logged) | 4.02 ms | 4.02 ms |

   If a slower runner ever misses one, list it in `tools/lune/expectations.luau` with `kind = "host"` rather than
   loosening the spec.
4. **Globals are shared.** Roblox gives every script its own global table; headless chunks share Lune's. This only
   matters for code that assigns globals. A full suite run with a recording environment found no global writes in
   `src/` or `tests/`.
5. **Signals are deferred** (like `SignalBehavior.Deferred`), and Heartbeat fires only when the audit drives Main.
   The specs do not use engine signals.
6. **Studio's Play also starts `Main.server`** next to the tests. The headless suite runs without it, because the
   specs build their own plants. The audit boots Main separately.
7. **Luau version.** Lune 0.10.5 bundles Luau 0.709. Roblox ships its own build, which is usually newer. Nothing in
   this code base depends on the difference.
8. **`typeof`** reports `"Random"`, `"RBXScriptSignal"` and `"RBXScriptConnection"` for the harness's table-based
   objects, as Roblox does for its own. `Vector3` values are Lune userdata, not Luau's native `vector`, so the
   `vector` library cannot operate on them. Nothing here uses it.

## How sensitive the suite is

To check that headless passes are not vacuous, three bugs were planted in a throwaway copy of `src/` (never
committed) and the suite was run on that copy:

| Planted bug | Caught? |
|---|---|
| `Protection/init.luau:111`: inclusive setpoints compare with `>` instead of `>=` | **Yes.** `Protection :: losing pumps and loops: one is a runback, two is a trip (§9.5)`: `RB-2: got , expected RB2` |
| `Detectors/init.luau:74`: gaussian noise halved | **Yes.** `Detectors :: source range noise is counting statistics…`: σ/R 0.0125 against 0.0256 |
| `Framework/Scheduler.luau:75`: slow lane every 11 fast ticks instead of 10 | **No** |

The third is a gap in the spec, not in the harness. `tests/FrameworkSpec.luau:247-255` steps 25 fast ticks and
expects 2 slow steps, which any cadence from 9 to 12 ticks also gives. No other spec runs the slow lane through the
Scheduler (CoreSpec steps `registry.order.fast` itself). A tick count that tells the cadences apart would close it,
for example 30 ticks expecting 3 slow steps.

## Tools and checksums

- **`rokit.toml`** (repository root) pins **Lune 0.10.5** and **Rojo 7.7.0**. Run `rokit install` for rokit users.
- **`tools/lune/bootstrap.sh`** reads the same `rokit.toml` lines and downloads the matching release archive for the
  platform from GitHub. It checks the archive's SHA-256 against **`tools/lune/tools.sha256`** before extracting,
  then installs the binary into `tools/lune/.bin/`. A missing or different checksum stops the install.
- **Neither lune-org/lune nor rojo-rbx/rojo publishes checksums** with its releases: their release workflows upload
  only the zips. So the hashes in `tools.sha256` were computed from the archives downloaded on 2026-09-23, for
  linux/macOS x86_64 and aarch64 and windows x86_64, and they are pinned from here on.
- **CI uses `bootstrap.sh`, not `rokit install`.** Rokit resolves releases through the GitHub API and checks no
  checksums, while `bootstrap.sh` reads the same manifest and does check them.
- **To bump a tool,** change `rokit.toml`, download the new archives, and replace their lines in `tools.sha256`.

## CI

`.github/workflows/tests.yml` runs `tools/lune/test.sh` on every push and pull request, on `ubuntu-24.04`, with a
20-minute limit and `contents: read` permissions. The actions are pinned by commit
(`actions/checkout` v7.0.1, `actions/upload-artifact` v7.0.1).

- A failing case becomes an error annotation on the run, and a known failure a warning.
- The step summary lists every case that did not pass.
- `report.txt`, `results.json`, `junit.xml` and `audit.txt` are uploaded as the `headless-test-reports` artifact.
- The job fails on:
  - any failure not listed in `tools/lune/expectations.luau`;
  - a listed failure that now passes, so the list cannot go stale;
  - a spec that fails to load;
  - a missing `SUMMARY` line.

## Files

| Path | Purpose |
|---|---|
| `rokit.toml` | Tool versions |
| `tools/lune/test.sh` | The one command |
| `tools/lune/bootstrap.sh`, `tools/lune/tools.sha256` | Checksum-verified tool install |
| `tools/lune/run-tests.luau` | Build, boot, run, compare, report, audit |
| `tools/lune/lib/Engine.luau` | The headless engine (require, globals, instance members) |
| `tools/lune/lib/Signal.luau`, `tools/lune/lib/Random.luau` | RBXScriptSignal and Random stand-ins |
| `tools/lune/selftest.luau` | Checks of the engine layer itself |
| `tools/lune/expectations.luau` | Known failures, with their kind (`bug`, `harness`, `host`) and reason |
| `.github/workflows/tests.yml` | CI |
