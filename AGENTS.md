# AGENTS.md

A guide for coding agents working in this repository. Humans should start with [README.md](README.md).

## What this is

Kallskär Nuclear Power Plant (unit K1) is a multiplayer Roblox simulator of a fictional Swedish 2,380 MWt pool-type
sodium-cooled fast reactor, the SFR-1000, written in Luau (`--!strict`). The developer is Aqua.

The design spec is the source of truth for every number. It comes in three copies of the same text, Rev A6:

- **`kallskar_handoff/`**, the handoff pack. Start at `00_README_START_HERE.txt`.
- **`KALLSKAR_ALL_IN_ONE.txt`**, the same pack as one file, in reading order.
- **`REACTOR SPEC/sfr-1000-spec.html`**, which covers the spec files (10–16) only. The text pack adds the README,
  the project brief, the design history and file 20's derivations.

`python tools/derive/apply_rev_a6.py --check` verifies that the copies agree. `docs/FINAL_DECISIONS_REV_A5.md`
records what took the spec from A4 to A5, and D-059 in docs/DECISIONS.md what took it to A6 (§9.4's automatic
controllers). `Config.revision` names the revision Config's values follow: still `"A5"`, because A6 changed no
Config value; it moves to A6 when AutoControls implements D-059.

Decisions made while building it are in [docs/DECISIONS.md](docs/DECISIONS.md), as `D-xxx` decisions and `Fxx` spec
findings. Read the relevant entries before changing behaviour, and cite them by number in code and commits.

## Layout (Rojo, `default.project.json`)

| Folder | In the game | What |
|---|---|---|
| `src/shared/` | `ReplicatedStorage.Kallskar` | Client-safe code: `Config/` (every number, with provenance), `Types`, `Tags`, `Net`, `Props` |
| `src/server/` | `ServerScriptService.Kallskar` | `Main.server.luau`, `Framework/`, `Systems/`, `Telemetry/`, and the Studio-only `Dev/` |
| `src/client/` | `StarterPlayer.StarterPlayerScripts.Kallskar` | Client rendering and input |
| `tests/` | `ServerStorage.KallskarTests` | `Runner.luau` and the `*Spec.luau` modules |

Rojo syncs only these four folders, and the disk is the source of truth. `tools/` holds:

- `lune/`, the headless harness
- `derive/`, the scripts behind `derived` values
- `audit/`, the spec-audit scripts, which need the `iapws` and `gsw` Python packages
- `xsgen/`, OpenMC cross sections
- `studio/`, the disk-to-Studio drift check
- `check_provenance.ps1`, the disk-side provenance check

## The System contract

Every plant system is a class made with `System.extend` (`src/server/Framework/System.luau`, spec §14.7):

```lua
local Pumps = System.extend({
	name = "PrimaryPumps", -- PascalCase, unique
	lane = "fast",         -- "fast" (10 Hz) or "slow" (1 Hz)
	reads = { "core.power_pctFP" },        -- channels read this tick; the Registry orders writers first
	readsLagged = { "protection.scram" },  -- unordered: may be this tick's or last tick's value (L5)
	writes = { "primary.flowFraction" },   -- each channel has exactly one writer
})
function Pumps:init(ctx) end   -- ctx.config, ctx.channels (the port), ctx.bus, ctx.log, ctx.clock, ctx.isStudio
function Pumps:step(dt) end
function Pumps:getState() return {} end
Pumps.commands = { ["pump.speed"] = function(self, actor, cmd) return { ok = true } end }
Pumps.faults = { { id = "PP-TRIP", label = "Primary pump trip", cost = 3, arm = function(self, params) end } }
-- optional: Pumps:save() / Pumps:load(slice, version) for Persistence (§14.6)
```

The rules that go with it:

- **Channels.** A system reads and writes only through its port, and only the channels it declares.
  `tests/ContractSpec` fails on a declared read that is never read.
- **Run order.** The Registry derives it from `reads` and `writes`. A cycle has to be broken with `readsLagged`.
- **`init`** must put the system back in its initial condition every time it runs, because an owner reset calls
  it again (`Framework/PlantReset`).
- **Errors.** A step that raises halts the plant (fail-stop), and the halt names the system.
- **Commands** arrive only through `Framework/Commands`. It rate-limits, sanitises, routes, checks access and
  logs, and handlers read `cmd.target`, `cmd.value` and `cmd.args`.

**Plugging in a new system.** Add its class to the list in `src/server/Systems/init.luau`. Declare any channel it
needs that nothing builds yet as an external in `Main.server.luau`. Add a `tests/<Name>Spec.luau`. Nothing else in
the core loop changes.

## Provenance: no guesswork

- **Every number in `Config`** is wrapped in its provenance (`src/shared/Config/Provenance.luau`). A bare number
  fails at load time and in `tests/ConfigSpec`. The kinds are:
  - `spec(v, "§x.y")`, or `tuning(v, "§x.y")` for a value the spec marks † (expected to change in playtesting)
  - `cited(v, "source")`, a real plant or a published source
  - `derived(v, "tools/derive/x.py")`, a calculation checked into the repo
  - `engineering(v, "reason")`, a software parameter rather than plant physics, with its reason
  - `decision(v, "D-xxx")`, a decision recorded in docs/DECISIONS.md
- **A test tolerance** comes from the spec's published rounding or from the method: counting statistics, a
  filter's settling, an integrator's error order, a measured timing granularity. It is never a guess, and the
  derivation goes in a comment beside it (D-049).
- **A conflict with the spec** is reported, never quietly adjusted. Record it as a finding in docs/DECISIONS.md
  or a review note, and say so in the PR.

## Tests: every PR must pass `tools/lune/test.sh`

```sh
tools/lune/test.sh                  # installs pinned Lune and Rojo, builds the place, runs every spec
tools/lune/test.sh --filter Core    # only spec modules whose name contains "Core"
```

It must end with `[harness] OK: every outcome matches expectations`. CI (`.github/workflows/tests.yml`) runs the
same script on every push and pull request. Never add an entry to `tools/lune/expectations.luau` to hide a
failure. If a test fails headless but you believe it passes in Studio, say so in the PR, with the reason.

Details, other operating systems and the output files are in [docs/HEADLESS_TESTS.md](docs/HEADLESS_TESTS.md).
In Studio, set `RunTests = true` on `ServerStorage.KallskarTests` and press Play.

## Hard rules

- **Leave the single `TODO(human)`** in `src/server/Framework/Commands.luau` (`Commands.criticalAccess`, the policy
  for a failed playtime lookup) exactly as it is. It is Aqua's decision, and its test stays pending.
- **Don't change the `ReplicatedStorage.KallskarDev.SnapshotServer` contract**: its name, when it fires (5 Hz,
  after a completed tick, `src/server/Telemetry/PlantSnapshot.luau`) or its payload. A script outside this repo
  depends on it.
- **Never edit the archived spec copy** under `REACTOR SPEC/3A SPEC REVIEW/`.
- **No metatables or per-tick allocations in hot loops.** Numeric kernels use flat arrays allocated once;
  metatables belong at system boundaries only.
- **Never add website code, API keys or secrets to the repository.**
- **Stage files by name** (`git add path/to/file`). Never use `git add .` or `git add -A`.
