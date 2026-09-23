# Code review: Kallskär K1, M1 slice

**Reviewed:** commit `8a2a982` (`main`), 23 Sep 2026. Everything under `src/` and `tests/`, plus the parts of
`docs/DECISIONS.md`, `KALLSKAR_ALL_IN_ONE.txt` (§9.5, §10.7, §14) and `default.project.json` that the code relies on.
**Method:** static reading only (no Roblox Studio). Two checks were scripted over the source: (1) each system's
declared `reads`/`readsLagged`/`writes` against the `port:read`/`port:write` calls it actually makes, and (2) the fast
lane order the Registry resolves, used to classify every lagged read as fresh or one tick old. That order is
`Detectors, Pools, RodDrives, Core, DecayHeat, PrimaryPumps, FuelThermal, IHX, AutoControls, Protection`.
**Not reported, by instruction:** the `TODO(human)` in `Commands.criticalAccess`, and running point kinetics
behind the Core facade (D-031).

Nothing in this document has been applied. Each diff shows the direction of a fix. It is not a patch that has
been tested.

**Severity**
- **High:** wrong plant behaviour, lost data, or an exploit, any of which can happen in normal play today.
- **Medium:** wrong behaviour in one specific situation, a gap in access control, or a latent defect that the
  next planned milestone will expose.
- **Low:** small errors, per-tick performance, drift in the declared contracts, and test quality.

---

## 1. Findings, ranked

| # | Sev. | Where | Failure scenario (input/state → wrong result) | Fix |
|---|---|---|---|---|
| H1 | High | `src/server/Framework/Commands.luau:101`; handlers `PrimaryPumps/init.luau:225`, `RodDrives/init.luau:467,471`, `IHX/init.luau:445,453`, `Protection/init.luau:613,638,651` | Client sends `{kind="rod.move", target="RR1", value=600}` → `sanitize` keeps `target` and drops everything else → `RodDrives` reads `cmd.tag` = nil → "unknown rod 'nil'". So no tagged command (rods, banks, pumps, IHX, loops, bypass, runbacks) can succeed through the network, and every networked manual trip counts as MCR. | [H1](#h1) |
| H2 | High | `src/server/Framework/Commands.luau:208-219`; `Replicator.luau:156-159` | An exploit client calls `Command:InvokeServer({})` in a loop → each malformed call is logged *before* any rate limit, and rate-limited calls are logged too → the 5,000-entry SOE log is wiped within seconds (which also destroys §10.7's record of who tripped the plant), and up to 5,000 records/s go reliably to every player. | [H2](#h2) |
| H3 | High | `src/server/Framework/Persistence.luau:270-275, 203-204, 289`; `Main.server.luau:158-163` | Private server at the 60 s autosave → `SetAsync` yields, and `sinceSave` is only reset after it returns → every Heartbeat during the yield starts another save → dozens of concurrent writes to one key, which throttle and fail, and an older snapshot can land last. A save in flight can also land after the reset's `RemoveAsync` and bring back the pre-reset plant. | [H3](#h3) |
| H4 | High | `src/server/Main.server.luau:90-96`; `Persistence.luau:270-275` | Boot during a DataStore outage (or with a save from a newer version) → `load` raises → `halted` is set → 60 s later the autosave writes the fresh boot plant over the save it could not read. The comment at `Main.server.luau:92` promises the opposite. | [H4](#h4) |
| H5 | High | `src/server/Systems/Protection/init.luau:438-464, 533-537`; `RodDrives/init.luau:310-318` | At 100 %FP, one secondary loop is lost → RB-1 (target 64 %FP) → the shims drive in at 10 mm/s all the way to 0 mm, because nothing reads the target → the reactor is shut down on shims instead of settling at 64 %FP. `runback.clear` is undone on the next tick while the loop is still out. RB-2 and RB-3 only stand rod auto down. | [H5](#h5) |
| M1 | Med | `src/server/Main.server.luau:107-118`; `Commands.luau:217-231, 245-253` | On a live server, anyone who owns a private server sends `args.dev = true` → they become a `dev` actor → the reach check and the critical-control playtime check are both skipped. So a player with 0 h of playtime can fire `sss.trip.manual` from anywhere on the map. | [M1](#m1) |
| M2 | Med | `src/server/Framework/Faults.luau:93`; clears at `Protection/init.luau:693`, `RodDrives/init.luau:571`, `IHX/init.luau:643`, `Detectors/init.luau:346` | Arm `PROT-CHANNEL {signal="COVER-GAS"}`, then clear it through `Faults` → `clear` gets no params → PR-HIGH is "restored" instead, and the COVER-GAS trip stays bypassed with nothing showing it. The same happens with RD-STUCK (the rod stays stuck, so a scram reset can be refused for good), IHX-SHUT and NI-FAIL. | [M2](#m2) |
| M3 | Med | `src/shared/Config/Protection.luau:53`; `Protection/init.luau:443` | `runback.start RB3` → `runback.target = nil` → a later pump trip calls `startRunback("RB2")` → `nil <= 60` errors inside `Protection.step` → the Scheduler fail-stops, and the simulation stays halted. | [M3](#m3) |
| M4 | Med | `src/server/Main.server.luau:98-102` | The owner reset after a halt re-initialises every system but never clears `scheduler.halted`, so the plant stays stopped. `faults.active` survives the reset, so the fault can't be re-armed ("already active"). `program.mode` stays wherever it was, so D-004 applies Mode 1 rules to a Mode 3 plant. | [M4](#m4) |
| M5 | Med | `src/server/Framework/Persistence.luau:154-172`; only `DecayHeat/init.luau:121-136` saves | Leave a private server at 100 %FP with a stuck rod and a lost loop → next session: rods, trips, pumps, loops, faults and temperatures are all back to boot state, but about 220 MW of decay heat is restored into a Mode 3 plant. §14.6's "failed, isolated and drained equipment, LCO clocks" are not kept. | [M5](#m5) |
| M6 | Med | `src/server/Framework/Commands.luau:181-205` | (Latent until panels exist.) The client chooses `cmd.panel` → a player at any panel sends `reactor.trip.manual` naming *that* panel → the reach check passes. §10.7's proximity and anti-solo rule is defeated. | [M6](#m6) |
| M7 | Med | `src/server/Systems/Protection/init.luau:637-648`; `Config/Access.luau:168-177` | A 0 h player in reach sends `pss.bypass` once for each of the 19 rows → every trip is disabled. A manual trip needs 3 h of playtime; disabling all protection needs none. | [M7](#m7) |
| M8 | Med | `src/server/Systems/Core/IQS.luau:393, 445` vs `141-194, 362-383` | (Latent until IQS replaces the facade.) The shape step sweeps `self.psi` in place and yields between slices → the next `IQS.tick` computes ρ from a half-swept, un-normalised shape, using a leakage term frozen from the old one → spurious reactivity, which is then integrated into the node precursors. | [M8](#m8) |
| L1 | Low | `src/server/Systems/Protection/init.luau:479-486`; `AutoControls/init.luau:219, 233, 276, 296` | INLET-LOW alarms at 30 %FP → a trip takes power below 5 %FP → the row disarms → `st.alarm` is cleared without an "out" event → the annunciator shows it forever. The same happens to PQ after every trip and to AUTO-ROD-BAND. CORE-OUT on the ±1 K thermocouple chatters in and out at 10 Hz near 565 °C. | [L1](#l1) |
| L2 | Low | `src/server/Systems/Protection/init.luau:612-621` | One MCR press at 10:00 and another at 13:00, or one player double-clicking → trip. The count never times out and can't tell buttons apart. §9.5 asks for two buttons. | [L2](#l2) |
| L3 | Low | `src/server/Systems/Core/Kinetics.luau:101-104`; `Core/init.luau:226-242` | ρ touches 0.9β once → `amp.promptCritical` stays true for good → `core.promptCritical` never clears, and Core's clearing branch is dead code. While ρ stays ≥ 0.9β, power is held flat and no trip fires. | [L3](#l3) |
| L4 | Low | `src/server/Systems/Detectors/init.luau:50-51` | `core.*` is read lagged although no cycle requires it → Detectors runs first and measures the previous tick → every neutron trip reaches the rods at t+2 rather than t+1. That is about 24 % more overshoot on a 0.47 s period. | [L4](#l4) |
| L5 | Low | `src/server/Systems/AutoControls/init.luau:65-72`; `Protection/init.luau:68, 71-76` | Four declared reads are never read. Four "lagged" reads that are used are actually fresh, because the writer happens to run first. An unrelated new read can silently flip D-004's `rods.allPssInserted` between this tick and the last. | [L5](#l5) |
| L6 | Low | `src/server/Systems/Protection/init.luau:224` | ASSY-DEV's "median" is `sorted[#sorted // 2]`, which for 301 outlets is the 150th, not the 151st. Every deviation is measured against the neighbour below the median. | [L6](#l6) |
| L7 | Low | `src/server/Systems/IHX/init.luau:178` | `self.load` (the sink load, a number) shadows `System.load`. The day IHX saves anything, `Persistence.load` calls `sys:load(...)` → "attempt to call a number value" → load fails. | [L7](#l7) |
| L8 | Low | `src/server/Framework/Replicator.luau:51-57, 88-107` | Gauge tags are the bare `getState()` keys, so two systems exposing the same key would share one id. Every 0.2 s send also builds every system's full `getState()` (about 80 nested tables) just to keep the top-level numbers. | [L8](#l8) |
| L9 | Low | `Protection/init.luau:122-124, 222-229`; `Detectors/init.luau:101-109, 231, 252, 271, 288`; `FuelThermal/init.luau:113-121`; `Core/IQS.luau:219, 395-416`; `Commands.luau:157` | Tables and strings are allocated on every tick and in the native IQS kernel. The worst is ASSY-DEV: a clone and sort of 301 values plus a 301-entry table each tick. The IQS shape step allocates about 250 KB per step. Rate-limit buckets are never evicted. | [L9](#l9) |
| L10 | Low | `src/server/Framework/Persistence.luau:224-232` | A v1 save is migrated to v2, then `sys:load(slice, 1)` hands the system v2 data labelled v1. Any system that branches on `fromVersion` migrates it a second time. | [L10](#l10) |
| L11 | Low | `tests/Runner.luau:59-69` | `t.near(x, NaN, tol)` or `t.near(x, y, NaN)` passes, because `abs(x − NaN) > tol` is false. | [L11](#l11) |
| L12 | Low | tests (see list) | Several tests don't check what their names claim. For example, "event log restored" passes even if nothing was imported. | [L12](#l12) |
| L13 | Low | tests (see list) | Several tolerances have no stated basis in published rounding or the method. | [L13](#l13) |
| L14 | Low | `src/server/Systems/Core/Kinetics.luau:134-143` | `inhourPeriod(λ, β, 0)` returns about −76.9 s (−1/λ₁) instead of an infinite period. Only tests use it. | [L14](#l14) |
| L15 | Low | `src/shared/Config/init.luau:44`; `Config/Engineering.luau:17` | `Config.revision = "A3"` although Config carries Rev A4 and A5 values. `Engineering.devStrictState` is never read. | [L15](#l15) |

---

## 2. Details and suggested fixes

### H1

**Commands deliver `target`, but every handler reads `cmd.tag`.**

`Commands.sanitize` returns `{ kind, target, panel, value, args }` (`Commands.luau:101`). `Types.Command` has
`target` and no `tag`. The EventLog and the `CommandApplied` bus event also use `target`. Every system handler reads
`cmd.tag` instead. A client that sends `tag` has it stripped by `sanitize`, because the sanitised command is a fresh
copy. So on the real network path:

- `rod.move`, `rod.bank`, `pump.*`, `ihx.shutter`, `loop.*`, `pss.bypass`, and `runback.start` are always refused
  with "unknown … 'nil'".
- `reactor.trip.manual` is always counted as an MCR press (`where = if cmd.tag == "BCR" …`), so the backup control
  room's one-button trip can't be reached.

This is invisible in Studio for two reasons. The dev panel calls `applyCommand` directly with `tag`. Every spec does
the same (`RodDrivesSpec`, `PrimaryPumpsSpec`, `IHXSpec`, `ProtectionSpec`, `CoreSpec`), and the one test that goes
through `Commands.submit` (`FrameworkSpec` "commands route…") uses a stub system that ignores the target.

The fix is to use one name everywhere. `target` is the name the type, the log and the bus already use:

```diff
--- src/server/Systems/PrimaryPumps/init.luau
 local function pumpIndex(self: any, cmd: Command): (number?, string?)
-	local tag = cmd.tag
+	local tag = cmd.target
--- src/server/Systems/RodDrives/init.luau
 	["rod.move"] = function(self: any, actor: Actor, cmd: Command): CommandResult
-		return self:request("rod", cmd.tag, cmd.value, actor)
+		return self:request("rod", cmd.target, cmd.value, actor)
```

Make the same change in `IHX/init.luau:445,449,453`, `Protection/init.luau:613,638,651` and
`Dev/DebugPanelServer.luau:118,141`, and in the specs. Then add one end-to-end test that pushes a raw client table
through `Commands.submit` into a real system (see §3).

### H2

**Refusals are logged without a rate limit, then broadcast to everyone.**

`submit` sanitises first, and `refuse()` writes an EventLog record (`Commands.luau:208-215`). The token bucket is
only consulted afterwards (`:217-219`), and a rate-limited attempt is *also* recorded (`:219`). So neither a
malformed command nor a throttled one costs the sender anything. With `eventLogCapacity = 5000` the ring is
overwritten in seconds. `Replicator.tick` then sends every new record reliably to every client (`:156-159`), which
multiplies one client's traffic by the number of players. The record's `kind` is up to 64 characters of
client-chosen text (`kindForLog`), which is echoed to every client's SOE view.

```diff
--- src/server/Framework/Commands.luau
 function Commands.submit(self: any, actor: Actor, raw: any): CommandResult
+	-- throttle before doing any work or writing anything, so a flood costs the sender, not the log
+	if (actor.kind == "player" or actor.kind == "dev") and not takeToken(self, actor.userId) then
+		return self:refuseQuietly(actor, "too many commands; slow down") -- counts; logs at most once per window
+	end
 	local cmd, why = Commands.sanitize(raw, self.limits)
 	...
-	if actor.kind == "player" or actor.kind == "dev" then
-		if not takeToken(self, actor.userId) then
-			return refuse("too many commands; slow down")
-		end
-	end
```

`refuseQuietly` would keep a per-player count, and log one "N refused commands" record per player per few seconds.
§10.7 wants accountability for control actions, not for noise.

### H3

**The autosave re-enters itself while a DataStore write is yielding.**

Roblox runs each Heartbeat invocation on its own thread. `Persistence.tick → save → store:set` yields inside
`SetAsync`, and `sinceSave` is only reset after it returns (`Persistence.luau:203-204`). Every frame during the
yield (60/s) therefore starts another `save()`. Once the per-key write limit (one write every 6 s) is exceeded,
requests queue up and fail. `withRetry` then sleeps 2 + 4 + 8 s, and it sleeps even after its final attempt has
failed (`:80-91`), which lengthens the window further. The same yield sits in the reset path (`:289`): an autosave
already in flight can finish after `RemoveAsync` and restore the pre-reset plant at the next boot.

```diff
--- src/server/Framework/Persistence.luau
 function Persistence.tick(self: any, dt: number)
-	if self:enabled() then
+	if self:enabled() and not self.saving then
 		self.sinceSave += dt
 		if self.sinceSave >= self.saveInterval then
-			self:save()
+			self.sinceSave = 0
+			self.saving = true
+			task.spawn(function()
+				self:save() -- snapshot is taken synchronously inside, before the first yield
+				self.saving = false
+			end)
 		end
 	end
@@
 		if r.remaining <= 0 then
 			self.reset = nil
+			while self.saving do -- never let an older save land after the remove
+				task.wait()
+			end
 			self.store:remove(self.key)
@@ local function withRetry(self: any, fn: () -> any): (boolean, any)
 		lastErr = result
-		task.wait(2 ^ attempt)
+		if attempt < self.retries then
+			task.wait(2 ^ attempt)
+		end
```

### H4

**A failed load halts the plant, and the autosave then overwrites the save.**

`Main` catches the load error and sets `scheduler.halted` (`Main.server.luau:90-96`). `Persistence` is never told.
Sixty seconds later, `tick → save()` snapshots the freshly initialised systems and `SetAsync` replaces the stored
plant. `BindToClose` checks `halted` (`:166`); the autosave doesn't. The two realistic triggers are a DataStore
outage at boot (three failed `GetAsync` calls), and a save written by a newer place version ("save version N is
newer than this server").

```diff
--- src/server/Framework/Persistence.luau
 function Persistence.save(self: any): (boolean, string?)
 	if not self:enabled() then
 		return false, "persistence disabled on this server"
 	end
+	if self.writable == false then
+		return false, "the stored plant could not be loaded; refusing to overwrite it"
+	end
@@ function Persistence.load(self: any): string
+	self.writable = false -- until this load succeeds, never overwrite what is stored
 	local ok, data = self.store:get(self.key)
 	...
 	if data == nil then
+		self.writable = true
 		return "fresh"
 	end
 	...
+	self.writable = true
 	return "loaded"
@@ (reset branch of tick)
 			self.store:remove(self.key)
+			self.writable = true -- the owner chose to start over
```

### H5

**Runback targets are published, but nothing acts on them.**

`protection.runbackTarget_pctFP` and `runbackRate_pctpmin` have no reader. `AutoControls` declares the target but
never reads it. `RodDrives` drives every shim toward 0 mm at 10 mm/s for as long as `protection.rodRunback` is
true, with no stop condition (`RodDrives/init.luau:310-318`). `Protection.step` restarts the runback on every tick
while the pump or loop alarm is in (`:533-537`), so `runback.clear` holds for one tick. The result: a lost
secondary loop at power (fault SL-LOST, cost 3) ends with the reactor shut down on its shims, instead of held at
64 %FP. RB-2 and RB-3 do nothing except stand rod auto down. `RodDrivesSpec` checks the 10 mm/s drive-in, but
nothing checks that a runback *stops* at its target.

```diff
--- src/server/Systems/Protection/init.luau
-		if m.id == "PUMPS" and st.alarm then
-			self:startRunback("RB2")
-		elseif m.id == "LOOPS" and st.alarm then
-			self:startRunback("RB1")
-		end
+		-- a runback starts on the alarm's rising edge, so an operator can clear it once it has done its job
+		if st.alarm and not st.runbackStarted then
+			if m.id == "PUMPS" then self:startRunback("RB2") elseif m.id == "LOOPS" then self:startRunback("RB1") end
+		end
+		st.runbackStarted = st.alarm
 	end
+	-- §9.5: a runback runs TO its target; stop driving shims in once the power has got there
+	if self.runback and self.runback.driveIn and self.power <= self.runback.target then
+		self.runback.driveIn = false
+		if self.log then self.log:record("runback", nil, self.runback.id, nil, "target reached") end
+	end
```

The runback rate (30 or 60 %/min) needs a consumer too. Either RodDrives modulates the drive-in speed, or rod
auto, instead of standing down, drives power down along the rate. That is a design decision.

### M1

**Dev actors on live servers.**

`isDev` returns true in Studio. It also returns true on any live server for the place creator (when the place is
user-owned) and for the private server owner (`Main.server.luau:107-115`). A dev actor skips the whole of
`checkPlayerAccess`: reach, and the §10.7 critical-control playtime rule (`Commands.luau:226-231`). Anyone can buy a
private server, so this is a purchasable bypass of §10.7 and §14.4. In M1, `panelPosition` returns nil for every
panel, so on live servers the creator and private-server owners are also the *only* players whose commands work at
all. Refused `args.dev` attempts return before `submit` and are never logged (`:249-251`). The header comment
says dev actors "come only from the Studio/owner-gated debug panel", and the plan says `Dev/` is Studio-only.

```diff
--- src/server/Main.server.luau
 local function isDev(player: Player): boolean
-	if isStudio then
-		return true
-	end
-	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
-		return true
-	end
-	return isPrivate and player.UserId == game.PrivateServerOwnerId
+	return isStudio -- dev actors skip reach and playtime; they must not exist on a live server
 end
```

If private-server owners are meant to get extra powers, give them their own actor kind that still passes the
playtime check. The owner reset already works that way, through `Persistence.requestReset`.

### M2

**`Faults.clear` drops the parameters the fault was armed with.**

`Faults.arm` stores `params` (`Faults.luau:76`), but `clear` calls `entry.fault.clear(entry.system)` with nothing
else (`:93`). Four faults select their target from `params` and fall back to a default. A clear therefore resets
the default target (PR-HIGH, `drives[4]`, unit 1A, PR1), not the one that was armed, and the registry still marks
the fault cleared. The specs don't catch this because they call `fault.clear(sys, params)` directly
(`DetectorsSpec:255,262`, `RodDrivesSpec:246`, `IHXSpec:228`). `Types.FaultSpec.clear` is even typed without
params.

```diff
--- src/server/Framework/Faults.luau
 	if entry.fault.clear then
-		local ok, err = pcall(entry.fault.clear, entry.system)
+		local ok, err = pcall(entry.fault.clear, entry.system, self.active[id].params)
--- src/shared/Types.luau
-	clear: ((sys: any) -> ())?,
+	clear: ((sys: any, params: { [string]: any }?) -> ())?,
```

### M3

**RB-3 has no numeric target.**

`RB3 = { target = "bypass-limited", rate_pctpmin = 20 }` has no `target_pctFP`. `startRunback("RB3")` stores
`target = nil`. The next `startRunback` then compares `nil <= number` (`Protection/init.luau:443`), which throws.
When the next call comes from `Protection.step` (a pump or loop alarm), the Scheduler halts the whole plant. H1
currently blocks the command path to this; fixing H1 opens it. RB-3's depth depends on `turbine.bypassAvailable`,
which Protection declares and never reads (L5).

```diff
--- src/server/Systems/Protection/init.luau
 	local spec = self.cfg.runbacks[id]
-	if spec == nil then
+	if spec == nil or type(spec.target_pctFP) ~= "number" then
 		return false
 	end
```

To make RB-3 usable, give it a numeric bypass-limited target: the bypass capacity in %FP, read from
`turbine.bypassAvailable`. That is a spec decision for Aqua.

### M4

**The owner reset leaves framework state behind.**

The `PlantReset` handler zeroes the clock and runs `registry:initAll`, and does nothing else
(`Main.server.luau:98-102`). It misses three things:

1. **`scheduler.halted`.** Persistence ticks outside the scheduler, so a halted plant can still be reset, but it
   stays halted. The §14.6 reset is the owner's only recovery tool.
2. **`faults.active`.** Systems re-initialise their fault state (a stuck rod is un-stuck), but the registry still
   lists the fault, so re-arming it is refused.
3. **The external inputs.** After the dev preset has declared Mode 1, a reset puts the rods back in hot standby
   while `program.mode` stays 1. D-004's INLET-LOW then stays inhibited ("below 5 %FP") through a Mode 3 startup,
   where Rev A5 arms it as soon as a PSS rod is out.

```diff
--- src/server/Main.server.luau
-for name, initial in {
+local EXTERNAL_INPUTS = {
 	["program.mode"] = 3,
 	...
-} do
+}
+for name, initial in EXTERNAL_INPUTS do
 	channels:declareExternal(name, initial)
 end
@@
 bus:subscribe("PlantReset", function()
 	scheduler.clock.sim, scheduler.clock.grid, scheduler.clock.slow, scheduler.clock.fastTicks = 0, 0, 0, 0
+	scheduler.halted, scheduler.acc = nil, 0
+	table.clear(faults.active) -- "every component as new" (§14.6); systems reset their side in init
+	for name, initial in EXTERNAL_INPUTS do
+		channels:setExternal(name, initial)
+	end
 	registry:initAll(ctx)
```

### M5

**Only decay heat persists.**

`System.save` returns nil by default, and only `DecayHeat` overrides it. After a private-server restart, the
§14.6 plant condition is gone: rod positions, scram latches, stuck rods, pumps, loops, shutters, the IHX load,
bypasses and runbacks, pool, fuel and cover-gas state, the Core amplitude and feedback lags, and the active faults.
The one thing restored is decay heat. A plant saved at power therefore comes back as Mode 3 hot standby carrying
9.3 % of rated (about 220 MW) of decay heat and no load. `FrameworkSpec`'s persistence test uses a toy `Keeper`
system, so nothing checks a real round trip. Each system needs its own `save`/`load` pair. For example:

```diff
--- src/server/Systems/RodDrives/init.luau
+function RodDrives.save(self: any): any
+	local drives = table.create(self.count)
+	for i, d in self.drives do
+		drives[i] = { p = d.position_mm, s = d.stuck }
+	end
+	return { drives = drives, scrammed = table.clone(self.scrammed), runback = self.commandedRunback }
+end
+
+function RodDrives.load(self: any, data: any, _fromVersion: number)
+	if type(data) ~= "table" or type(data.drives) ~= "table" or #data.drives ~= self.count then
+		return
+	end
+	for i, d in data.drives do
+		local drive = self.drives[i]
+		drive.position_mm = math.clamp(tonumber(d.p) or drive.position_mm, 0, self.travel_mm)
+		drive.demand_mm, drive.stuck = drive.position_mm, d.s == true
+	end
+	local s = if type(data.scrammed) == "table" then data.scrammed else {}
+	self.scrammed = { PSS = s.PSS == true, SSR = s.SSR == true }
+	self.commandedRunback = data.runback == true
+	self:publish()
+end
```

Also persist `faults.active`, which `Persistence` would need to receive. Until every system saves, consider not
restoring `DecayHeat` either, so that a restored plant is at least self-consistent.

### M6

**The reach check trusts the client's choice of panel.**

`checkPlayerAccess` measures the distance to `panelPosition(cmd.panel)`, and `cmd.panel` is whatever the client
sent. Nothing checks that the panel carries `cmd.kind` or `cmd.target`. Once panels exist, standing next to *any*
panel is enough to operate *every* control. This is latent in M1, where no panel has a position.

```diff
--- src/server/Framework/Commands.luau
 	if not cmd.panel then
 		return false, "control has no panel"
 	end
+	if not self.panelHosts(cmd.panel, cmd.kind, cmd.target) then
+		return false, `'{cmd.kind}' is not a control on panel '{cmd.panel}'`
+	end
 	local panelPos = self.panelPosition(cmd.panel)
```

`panelHosts` would be a pluggable service like `panelPosition`, defaulting to `false`, and backed by the panel
instances' tags once they exist.

### M7

**Trip bypass is an ordinary control.**

`pss.bypass` needs only reach. It has no playtime gate and no limit on how many rows can be bypassed at once, and
the §10.7 critical list predates it, since the spec has no such control. Among `criticalControls`, a manual scram
needs 3 h of playtime; disabling all 19 trip rows needs none. `runback.clear` has the same gap. This is a decision
for Aqua; the smallest change is:

```diff
--- src/shared/Config/Access.luau
 	criticalControls = {
 		"reactor.trip.manual",
 		"sss.trip.manual",
+		"pss.bypass", -- not in §10.7's list because the spec has no bypass control; disabling a trip is at least as critical as firing one
+		"runback.clear",
```

Pair it with a limit in `Protection` on how many rows may be bypassed at once, as real tech specs have.

### M8

**The IQS shape step mutates the shape that ticks read.**

`shapeStep` sweeps `self.psi` in place (`IQS.luau:393, 445`), and `Diffusion.sweep` calls `budget:check()`, which
yields after each colour pass. Between slices, `IQS.tick → parameters()` reads `self.psi`:

- `Fw`, `rem` and `scat` come from the partially swept, un-normalised iterate.
- `leakW` is a number frozen from the *previous* normalised shape.

So ρ = 1 − (leakW + rem − scat)/Fw is wrong by roughly the leakage fraction times the iterate's change per slice.
`tick` then advances the node precursors with `S` taken from that iterate, so the error stays in state after the
step ends. `IQSSpec` "shape step runs time-sliced…" never interleaves ticks, so it can't see this. D-031 keeps IQS
off the plant for now; this has to be fixed before it replaces the facade.

```diff
--- src/server/Systems/Core/IQS.luau
 	self.psi = table.create(G * N, 0)
+	self.psiNext = table.create(G * N, 0) -- the shape step iterates here; ticks keep reading self.psi
@@ function IQS.shapeStep(self: any, budget: any?): boolean
-	local psi, chi, vol, nu = self.psi, p.chi, p.vol, p.nuSigF
+	local psi = self.psiNext
+	table.move(self.psi, 1, G * N, 1, psi) -- warm start
+	local chi, vol, nu = p.chi, p.vol, p.nuSigF
@@
 	self.shapeOuter, self.shapeChange = outer, change
+	self.psi, self.psiNext = psi, self.psi -- publish the new shape atomically, between ticks
 	self:normaliseShape()
```

### L1

**Alarms can come in without ever going out.**

When a row disarms, `Protection.step` clears `st.alarm` without publishing `state = "out"` (`:479-486`). PQ
(armed above 5 %FP) is left "in" after every trip that happened while it was alarming. INLET-LOW is left "in" once
power falls below 5 %FP. `AutoControls` clears `outOfBand` in four places (`:219, 233, 276, 296`), and none of
them publishes "out" for AUTO-ROD-BAND. Separately, the alarm comparison has no deadband. CORE-OUT reads a thermocouple with ±1 K of uniform
noise per tick (`Pools/init.luau:384`), so within 1 K of 565 °C it can toggle in and out at 10 Hz.

```diff
--- src/server/Systems/Protection/init.luau
 		if not armed then
+			if st.alarm and self.bus then
+				self.bus:publish("Alarm", { tag = m.id, priority = 2, state = "out", text = m.label })
+			end
 			st.alarm, st.block, st.trip = false, false, false
```

For the chatter, add a small reset deadband per row, for example the channel's noise: `hit = v > alarm`, and the
alarm only clears once `v < alarm − deadband`.

### L2

**The manual trip counts presses, not buttons.**

`self.manual.mcr` goes up on every press and is only cleared by a trip reset (`:612-621`). One stray press arms
the plant for a trip on the next press, whenever that comes and whoever makes it. The same operator pressing twice
also trips it, although the header comment says "one operator leaning on one button does not trip the plant".
`ProtectionSpec:296-299` presses the same button twice and calls that two buttons.

```diff
-		local where = if cmd.tag == "BCR" then "bcr" else "mcr"
-		self.manual[where] += 1
-		local needed = self.cfg.pss.manualButtons.mainControlRoom
-		if where == "bcr" or self.manual.mcr >= needed then
+		local button = cmd.target or "MCR-1" -- "MCR-1", "MCR-2" or "BCR"
+		self.manual[button] = self.clock.sim -- ctx.clock, stored in init
+		local both = (self.manual["MCR-1"] or -math.huge) > self.clock.sim - COINCIDENCE_s
+			and (self.manual["MCR-2"] or -math.huge) > self.clock.sim - COINCIDENCE_s
+		if button == "BCR" or both then
```

`COINCIDENCE_s` would be a new `decision()` value, since §9.5 gives no window.

### L3

**The prompt-critical flag latches, and Core's clearing branch is dead.**

`Kinetics.step` sets `a.promptCritical = true` and nothing ever sets it back to false. So the branch
`elseif not self.pk.amp.promptCritical then self.promptCritical = false` in `Core.step` can never run. Once
tripped, `core.promptCritical` stays true after ρ falls back below the limit. While ρ ≥ 0.9β the amplitude holds
its value, so the plant sits at constant power with no trip, and only the P1 alarm marks the event. Holding is
§14.2's documented contract, pending a scripted event. The latch is the part to decide on. Either clear it, or
delete Core's branch and say that it latches:

```diff
--- src/server/Systems/Core/Kinetics.luau
 	cache(a, dt)
+	a.promptCritical = false -- a valid step: the prompt-jump form holds again
```

### L4

**Detectors reads `core.*` as lagged although no cycle requires it.**

Core doesn't read `detectors.*`, so declaring `core.power_pctFP` and `core.k` in `reads` creates no cycle. It
orders Detectors after Core. As things stand:

1. Core computes power at tick t.
2. Detectors measures it at t+1, and Protection trips at t+1.
3. RodDrives, which reads `protection.scram` lagged (that one is necessary), moves at t+2.

With the change, the rods move at t+1. The change also removes an inconsistency inside `Protection.step`: PQ uses
this tick's `core.power_pctFP`, while PR-HIGH votes on detectors that measured last tick.

```diff
--- src/server/Systems/Detectors/init.luau
-	reads = {},
-	readsLagged = { "core.power_pctFP", "core.k" },
+	reads = { "core.power_pctFP", "core.k" },
```

### L5

**The declared contracts have drifted.**

Declared reads that are never read:

- AutoControls: `protection.runbackTarget_pctFP` and `rods.selection`.
- Protection: `rods.selection` and `turbine.bypassAvailable`.

"Lagged" reads that are actually fresh, because in the resolved order RodDrives runs before both readers:

- AutoControls: `rods.position_mm`.
- Protection: `rods.allPssInserted`, `rods.regulatingInBand` and `rods.selectionKind` (and `rods.selection`, which
  it never reads).

`Types.luau:9-10` says lagged channels are "read as last tick's value". In practice they are just unordered, so an
unrelated new read that reorders the lane can silently change D-004's Mode 3 inhibit input from this tick's value
to last tick's. Remove the unused declarations. Then either reword the contract ("lagged = not ordered; may be this
tick's or last tick's value"), or snapshot lagged channels at the start of the tick in the Scheduler.

```diff
--- src/server/Systems/AutoControls/init.luau
 	readsLagged = {
 		"rods.position_mm",
-		"rods.selection",
 		"protection.rodWithdrawalBlock",
 		"protection.runback",
 		"protection.scram",
-		"protection.runbackTarget_pctFP",
 	},
```

### L6

```diff
--- src/server/Systems/Protection/init.luau
-				local expected = sorted[#sorted // 2]
+				local expected = sorted[(#sorted + 1) // 2] -- the median for odd n; the upper middle for even n
```

With today's facade, every outlet is equal (power share = flow share), so the bias is zero. It becomes a real,
one-rank bias once the 3D power map arrives.

### L7

```diff
--- src/server/Systems/IHX/init.luau
-	self.load = 0
+	self.sinkLoad = 0 -- not `load`: that name is the System persistence hook
```

Rename it in `setLoad`, `tripLoad`, `rampLoad`, `publish`, `getState`, `solveAtProgramme`, `applyFlows` and
`setColdLeg`. This must land before, or together with, IHX's part of M5.

### L8

```diff
--- src/server/Framework/Replicator.luau
 			if type(key) == "string" and type(value) == "number" then
-				table.insert(tags, key)
+				table.insert(tags, `{sys.spec.name}.{key}`)
```

Change `collect` the same way. No two systems collide today, but nothing prevents it. For the allocation cost, add
an optional `getGauges()` that returns a cached flat table of numbers, and fall back to `getState()` when a system
has none.

### L9

**Allocation in fast-lane systems and the native IQS kernel.**

This is not a correctness issue, and at 10 Hz the budgets hold. But it breaks the "none in hot kernels" rule and
creates garbage the server has to collect.

- **Protection:** every row's `signal` builds a fresh table each tick (`single()`, the PERIOD and SSS-PQ tables).
  ASSY-DEV clones and sorts all 301 outlets and builds a 301-entry deviations table every tick (`:222-229`).
  `inhibited` formats strings every tick. Fix: keep one reusable scratch array per monitor, and a reusable
  `sorted` buffer filled with `table.move`.
- **Detectors:** `` `SR{i}` ``, `` `WR{i}` ``, `` `PR{i}` `` and `` `DND{i}` `` are built per channel per tick
  (`:231, 252, 271, 288`). `medianOf` clones and sorts three times per tick (`:101-109`). Fix: precompute the name
  tables in `init`, and use a fixed 4-value median network for PR plus a reusable buffer for the DNDs.
- **FuelThermal:** `publish` allocates a new `self.last` table every tick (`:113`). Fix: create it once in `init`
  and assign its fields.
- **IQS:** `shapeStep` allocates `D`, `btot`, `src` (26,264 entries), `S`, `Sold` and a closure on every shape step
  (`:395-416`), about 250 KB per step. `syncAmplitudeBeta` sets `a.dt = -1` every tick (`:219`), which forces
  six `exp` calls. Fix: allocate the work arrays once in `IQS.new`, and only invalidate the cache when β has
  actually changed.
- **Commands:** `buckets[userId]` is never evicted (`Commands.luau:157`). Fix: drop the bucket on `PlayerRemoving`.

### L10

```diff
--- src/server/Framework/Persistence.luau
-			sys:load(slice, fromVersion)
+			sys:load(slice, self.currentVersion) -- the slice has already been migrated to this version
```

Alternatively, stop migrating system slices centrally and let each system upgrade from `fromVersion` itself. What
matters is not doing both.

### L11

```diff
--- tests/Runner.luau
 	function t.near(actual: number, expected: number, tol: number, msg: string?)
-		if type(actual) ~= "number" or actual ~= actual or math.abs(actual - expected) > tol then
+		if type(actual) ~= "number" or actual ~= actual or expected ~= expected or not (tol >= 0)
+			or math.abs(actual - expected) > tol then
```

Do the same in `t.rel`, where `expected = NaN` makes `tol` NaN.

### L12

**Tests that don't assert what their names say:**

- **`FrameworkSpec:656`, "event log restored".** It asserts `q.log.seq >= 1`, but `Persistence.load` itself records
  a "load" entry, so the check passes even if `import` did nothing. Assert instead that the pre-save record came
  back:
  ```diff
  -		t.ok(q.log.seq >= 1, "event log restored")
  +		local kinds = {}
  +		for _, e in q.log:latest() do kinds[e.kind] = true end
  +		t.ok(kinds["before-save"], "event log restored")
  ```
- **`DetectorsSpec:266-269`, "…which drags the median until §9.5's voting throws it out".** Three channels read 40
  and one is frozen near 100, so the median of four is 40. The assertion `|median − 40| < 25` is satisfied without
  any dragging or voting. Say what is really true: one frozen quadrant is outvoted. Use a tolerance taken from
  D-025's 0.5 % PR noise, for example `t.near(median, 40, 40 * 4 * INST.noise.powerRangeRelative)`.
- **`IQSSpec:296-316`, "shape step runs time-sliced inside the scheduler budget".** It asserts convergence only. The
  worst slice is logged but never compared with `shapeSliceBudget_s`.
- **`FuelThermalSpec:240-256`, "full-plant step fits the fast-tick budget".** It compares a single system's *mean*
  against the whole lane's *P99* budget. No test runs the whole fast lane through the Scheduler and checks
  `fastP99_ms` against `Engineering.fastTickBudgetP99_s`.
- **`ProtectionSpec:293-307`, "…two buttons in the control room".** One button is pressed twice (L2).
- **Fault clear parameters.** `DetectorsSpec:255,262`, `RodDrivesSpec:246` and `IHXSpec:228` call
  `fault.clear(sys, params)` directly. The framework never does that, which is how M2 got past the tests.

### L13

**Tolerances with no stated basis in published rounding or the method:**

| Test | Tolerance | What a derived one would be |
|---|---|---|
| `CoreSpec:121` D-030 floor | 5 % | The deviation left after 200 s from the prompt-drop start: `(β/(β−ρ)) · e^(−200/|T|)`, with T the inhour period at −3,826 pcm (about 0.6 %) |
| `CoreSpec:135` subcritical multiplication | 10 % | The first reading is taken 50 s after boot, before equilibrium. Wait several \|T\| instead, then bound it as above |
| `CoreSpec:199` zone I share | 0.01 | Exact: 1.12 × 301 / Σ f = 1.1187. Use the arithmetic, or 0.005 for §2.5's two-decimal factors |
| `CoreSpec:238` hot-standby inlet | 1 K | Not stated. §9.1's band, or the pump heat's 0.7 K, would give it a basis |
| `DetectorsSpec:96-97` Poisson mean and σ | 5 %, 35 % | Standard error of the mean and of σ for about 20 independent samples (400 ticks, 2 s ratemeter), so 3σ ≈ 3/√20 and 3/√40 |
| `DetectorsSpec:120` correlation | 0.15 | 3/√(effective N) for 2,000 correlated ticks |
| `DetectorsSpec:220` period | 15 % | From the filter: a 5 s first-order lag on d(ln P)/dt reads T exactly once settled. The noise term is σ/√n of the 300 averaged ticks |
| `AutoControlsSpec:71,78` setpoint | 1.5 K | §9.2 prints whole degrees, so the rounding is 0.5 K. 375 + 175·r is within 0.5 K of every row |
| `IHXSpec:81` six-unit total | 30 MW | 6 × the 2 MW per-unit rounding used on line 76 = 12 MW |
| `FrameworkSpec:323` slice overrun | 3 × budget | Budget plus one colour pass (the granularity of `budget:check()`), measured |

### L14

```diff
--- src/server/Systems/Core/Kinetics.luau
 function Kinetics.inhourPeriod(lambda: { number }, beta: { number }, rho: number): number
+	if rho == 0 then
+		return math.huge -- critical: no asymptotic period
+	end
```

### L15

`Config.revision` says "A3", but Config carries Rev A4 and A5 corrections (`Rods.regulating.normalBand_mm`,
`Core.limits`, `Primary.ihx.primaryInlet_C`). Either bump it to "A5" or delete it; nothing reads it.
`Engineering.devStrictState` is never read. `System.record` takes its own `strict` argument, and no system calls it.

---

## 3. Important behaviour with no test

- **A client command end to end.** A raw client table through `Commands.submit` into each real system's handler.
  This would have caught H1.
- **Command intake under abuse.** A malformed flood and a throttled flood, checking what reaches the EventLog and
  the Replicator (H2). `bindRemote` and `isDev` gating: a non-dev `args.dev`, and dev outside Studio (M1).
- **Replicator.** No test at all: manifest build and versioning, id stability, `collect` or chunking through
  `packLane`, the event feed after a load, or the manifest for late joiners.
- **PlantSnapshot.** No test at all.
- **Main's `PlantReset` handler.** Re-initialisation, `halted`, `faults.active` and the external inputs (M4).
- **Persistence against the real plant.** A save and load round trip of all ten systems (M5). No autosave after a
  failed load (H4). No overlapping writes (H3).
- **`Faults.clear` through the framework** for a fault armed with params (M2).
- **Runbacks.** RB-1 stopping at 64 %FP, a runback clearing once its cause is gone, and RB-3 (H5, M3).
- **Alarm pairing.** Every "in" on the Bus is eventually matched by an "out" (L1).
- **The fast lane's P99** with all ten systems through `Scheduler.stepFast`, against
  `Engineering.fastTickBudgetP99_s`.
- **IQS ticks between slices** of a sliced shape step (M8).

---

## 4. Reviewed and found sound

**Framework**
- `System`: one inheritance level, class specs frozen, `mixin` copies without overriding, and `applyCommand`
  pcall-wraps handlers and rejects results that aren't `CommandResult`s.
- `Registry`: rejects double writers and reads that have no writer. The topological sort is deterministic, ties
  broken by name. Cycles are reported with names, and lagged edges are left out of the ordering. Duplicate command
  kinds and fault ids are rejected.
- `Channels`: ports enforce declared reads and writes with one hash lookup. Externals can only be set externally.
- `Scheduler`: the accumulator counts in ticks with `TICK_EPS`, so 0.1 s doesn't drift. Catch-up is capped at
  `maxCatchUpStepsPerFrame × rate`, and dropped time is counted. The slow lane runs every 10th fast tick. It
  fail-stops with the system named. Sliced tasks run under a budget and refuse re-entry.
- `Bus`: a closed topic list, subscribers isolated, iteration over a copy.
- `EventLog`: ring arithmetic in `record`, `latest` and `since`, checked by hand across a wrap. `import` continues
  the sequence.
- `Commands.sanitize`: rejects non-tables, NaN and ±inf, wrong types, over-length strings, non-identifier arg keys
  and too many args, and always returns a fresh copy.
- `Packets`: the header sizes match the formats. Core-map values are clamped to u16, and packet lengths are checked
  on unpack.
- `Persistence`: migrations run one version at a time and refuse gaps and newer saves. The reset needs the owner,
  the exact phrase and the countdown, and a cancel works.
- The debug panel's remotes and `shared.Kallskar` are created only when `RunService:IsStudio()` is true.
  `TestBoot` returns early outside Studio. The client panel quits cleanly when its remotes never appear. The
  snapshot BindableEvent can be seen by clients but not fired by them.

**Numerics**
- `Mesh`: `axialOf` walks each ring edge by `dir[e+2]`, and dir[e+1] − dir[e] = dir[e+2] holds for all six. The
  first index of ring n is 2 + 3n(n−1). Cartesian coordinates put corners at 60°k and even-ring mid-edges at 30°.
  (q − r) mod 3 is a proper colouring (neighbour steps change it by ±1), and adding k separates axial neighbours.
  The `opposite` map is {4,5,6,1,2,3,8,7}.
- `Diffusion`: D̃ = 1/(hᵢ/Dᵢ + hⱼ/Dⱼ). The hex face area is side × dz, with the apothem pitch/2 as h. The albedo
  boundary term is correct. `coefT` is the exact transpose, so the diagonal is unchanged under transposition.
  Three-colour SOR is correct. The adjoint sweeps groups in reverse with transposed downscatter.
- `Kinetics`: the linear-n precursor integral was derived independently: w = 1 − (1 − e)/x, which matches the code
  and D-015. Σβᵢwᵢ ≈ 10 pcm at 0.1 s, so the denominator stays positive below 0.9β. Each feedback lag is an exact
  exponential for a constant driver.
- `IQS` formulas: ρ, β_eff and Λ are adjoint-weighted as their headers state, the leakage/removal/downscatter split
  is correct, and so are the equilibrium precursors cᵢ = βᵢSn/λᵢ, the projection sᵢ = λᵢ⟨C*, cᵢ⟩/F_w and the
  rescaling for F_w (D-017). The node precursor update uses the same exact linear-n integral.
- `DecayHeat`: the update is exact per tick, `referenceFraction` and the seat are in closed form, `load`
  validates its data, and a negative power reading is clamped.
- `FuelThermal` and `Pin`: units were checked through the algebraic sodium balance (Q per metre of pin, rise in W,
  mean of inlet and outlet), T_eq and τ = C·R. The Θ table's inverse bins are correct, including extrapolation.
  Heat capacity is interpolated with clamping.
- `Pools`: each node's exponential update is an exact energy balance for τ = m/ṁ. The transport ring buffer
  indices are right (`near`/`far` wrap, delay clamped to n − 2). `afterHeat` uses the midpoint c_p. The level tilt
  conserves volume. The gas law and the D-020 first-order valve correction are correct.
- `PrimaryPumps`: the §4.2 coastdown, the pony floor, the 2 %/s ramp, natural circulation on thermal power, and the
  start interlocks.
- `IHX`: ε-NTU with the Cr → 1 branch, the secant solve for the cold leg, clamped between the programme cold leg
  and the pool, the load ramp splitting a tick exactly at the 40 % limit (both directions checked), and the flow
  split by shutter weight.
- `RodDrives`: the worth curve and its derivative, the interlock clamp, one selection at a time, withdraw-only
  SSRs, the constant-rate scram (D-023), and the `seatCritical` bisection.
- `Detectors`: Knuth and Gaussian Poisson sampling, independent seeded streams per channel, the HV hysteresis, the
  period taken from filtered d(ln P)/dt, and the flux rate on the PR median.
- `Protection`: the voting (inclusive counts for the pump and loop rows), permissives with annunciated inhibits,
  first-out latching, block persistence (D-025), the reset refused while a trip is present, and the Curie latch
  with its lag.
- `AutoControls`: D-028 sequencing (hold the rod, choose a new one to keep the three together), D-035's
  drop-to-manual on a trip, and the D-034 load-indexed setpoint.
- `PartLoad` and `InitialConditions`: the programme functions, and the seat order. NaN and out-of-range powers are
  refused.

**NaN safety.** Every numeric command handler rejects NaN, `sanitize` rejects NaN and ±inf, and `seatAtPower`
refuses NaN. The dev panel's `tonumber(arg)` paths are covered because the handlers they reach check for NaN.
