--!strict
--[[
	The whole M1 plant as Main builds it, driven by the Scheduler tick by tick (spec §14.1). The unit specs step one
	system with its inputs held; what they cannot show is what the lane order does to a signal on its way from one
	system to the next, or how the systems behave together over minutes of plant time.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local Registry = require(Framework:WaitForChild("Registry")) :: any
local Scheduler = require(Framework:WaitForChild("Scheduler")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local Faults = require(Framework:WaitForChild("Faults")) :: any
local Persistence = require(Framework:WaitForChild("Persistence")) :: any
local Sodium = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Props"):WaitForChild("Sodium")) :: any
local Systems = Root:WaitForChild("Systems")
local InitialConditions = require(Systems:WaitForChild("InitialConditions")) :: any
local Kinetics = require(Systems:WaitForChild("Core"):WaitForChild("Kinetics")) :: any

local DT = 1 / Config.Clocks.fast_Hz
local AUTO = { kind = "auto" :: any, name = "PlantSpec", userId = 0 }

-- The plant with Main's external inputs, its Scheduler, Bus and EventLog, and every system initialised as at boot
local function plant()
	local channels = Channels.new()
	for name, initial in {
		["program.mode"] = 3,
		["site.seismic_g"] = 0,
		["electrical.boards11kV"] = 3,
		["turbine.bypassAvailable"] = true,
		["pools.levelDeviation_m"] = 0,
	} do
		channels:declareExternal(name, initial)
	end
	local registry = Registry.new(channels)
	for _, class in require(Systems) :: any do
		registry:add(System.new(class))
	end
	registry:resolve()
	local bus = Bus.new()
	local scheduler = Scheduler.new(registry, Config, bus, nil)
	local log = EventLog.new(Config, scheduler.clock)
	scheduler.log = log
	registry:initAll({ config = Config, bus = bus, log = log, clock = scheduler.clock, isStudio = true, scheduler = scheduler })
	local byName = {}
	for _, sys in registry.systems do
		byName[sys.spec.name] = sys
	end
	local faults = Faults.new(registry, log, bus)
	return {
		channels = channels,
		registry = registry,
		scheduler = scheduler,
		bus = bus,
		log = log,
		byName = byName,
		faults = faults,
	}
end

--[[
	Run whole fast ticks (and the slow lane with them), yielding now and then so a long run does not hog the thread.
	`each` sees every tick, and returning true from it ends the run there.
]]
local function run(p: any, seconds: number, each: ((tick: number) -> boolean?)?)
	for tick = 1, math.floor(seconds / DT + 0.5) do
		assert(p.scheduler:stepFast(), p.scheduler.halted)
		if each and each(tick) then
			return
		end
		if tick % 100 == 0 then
			task.wait()
		end
	end
end

-- Seated at 100 %FP with rod auto and flow auto in, as the plant runs at full power, and left to settle for 5 s
local function atFullPower(t: any): any
	local p = plant()
	t.ok(InitialConditions.seatAtPower(p.byName, p.channels, Config, 100) ~= nil, "seated at 100 %FP")
	t.ok(p.byName.AutoControls:applyCommand(AUTO, { kind = "auto.rod", value = 1 }).ok)
	t.ok(p.byName.AutoControls:applyCommand(AUTO, { kind = "auto.flow", value = 1 }).ok)
	run(p, 5)
	t.eq(p.channels:get("protection.tripped"), false, "steady at full power")
	return p
end

--[[
	A runback from full power (D-046), started the way its row starts it, and followed tick by tick until it is
	complete and then for four minutes more. The bounds each come from the mechanism:
	  - the demand falls at exactly the table rate, from the PR median at the start to the target
	  - the PR median stays within a band of the demand. Above it: one tick of the demand's fall, since the drive-in
	    starts the tick the power is over the demand, plus 5σ of one power range channel's D-025 noise (the median of
	    four is quieter than one channel; 5σ as D-025 uses). Below it: one tick of drive-in at the shims' steepest
	    worth (10 mm/s at §3.4's peak differential of twice the average, D-046's 10.8 pcm), which drops the power
	    promptly by Δρ/(β + Δρ); then the slow fall on that step's inhour period until the demand catches up; and the
	    same 5σ of noise
	  - the steam plant's load falls at the same rate, starting one tick later because IHX reads Protection lagged
	  - four minutes on, the core's thermal power is within rod auto's reach of the target: its ±2 K band on an
	    outlet measured through the thermocouple's ±1 K, where at flow fraction Q one %FP moves the outlet 1.75/Q K
	    (the 175 K rise at full power and flow of §9.2's programme, 375 + 175·P/Q)
]]
local function runback(t: any, id: string)
	local p = atFullPower(t)
	local prot = p.byName.Protection
	local spec = Config.Protection.runbacks[id]
	local target, perSecond = spec.target_pctFP, spec.rate_pctpmin / 60
	local load0 = p.channels:get("ihx.sinkLoad_pct")

	local beta = 0
	for _, b in Config.Kinetics.groups.beta_pcm do
		beta += b
	end
	local shim = Config.Rods.shim
	local dRho = 2 * shim.worthTotal_pcm / Config.Core.geometry.fissileHeight_mm * shim.speedRunbackDriveIn_mmps * DT
	local drop = 100 * dRho / (beta + dRho)
	local groups = Config.Kinetics.groups
	local betaFrac = {}
	for i, b in groups.beta_pcm do
		betaFrac[i] = b * 1e-5
	end
	local period = Kinetics.inhourPeriod(groups.lambda_ps, betaFrac, -dRho * 1e-5)
	local tail = 100 * (drop / perSecond) / math.abs(period)
	local noise = 5 * Config.Instruments.noise.powerRangeRelative * 100
	local below, above = drop + tail + noise, perSecond * DT + noise

	local demand0 = p.channels:get("detectors.prMean_pctFP") -- where the demand starts: the PR median now
	t.ok(prot:applyCommand(AUTO, { kind = "runback.start", target = id }).ok, `{id} starts`)
	local worstBelow, worstAbove, demandOff, done, tripped = 0, 0, 0, nil, false
	local loadOff = 0
	run(p, 900, function(tick)
		tripped = tripped or p.channels:get("protection.tripped")
		local rb = prot.runback
		if rb and not done then
			local expected = math.max(target, demand0 - perSecond * DT * tick)
			local demand = rb.demand or math.huge
			demandOff = math.max(demandOff, math.abs(demand - expected))
			local off = p.channels:get("detectors.prMean_pctFP") - demand
			worstBelow, worstAbove = math.min(worstBelow, off), math.max(worstAbove, off)
		elseif not done then
			done = tick
		end
		local load = math.max(target, load0 - perSecond * DT * math.max(0, tick - 1))
		loadOff = math.max(loadOff, math.abs(p.channels:get("ihx.sinkLoad_pct") - load))
		return done ~= nil and tick >= done + 2400 -- four minutes after the runback is complete
	end)
	t.log(string.format("%s: complete after %.1f s (the demand reaches %d %%FP at %.1f s); PR median %.2f to +%.2f %%FP of the demand (band −%.2f to +%.2f)",
		id, (done or 0) * DT, target, (demand0 - target) / perSecond, worstBelow, worstAbove, below, above))
	t.eq(tripped, false, `{id} runs the plant back, not into a shutdown`)
	t.ok(done ~= nil, `{id} completes`)
	t.ok(demandOff <= 1e-9 * demand0, `{id}'s demand falls at {spec.rate_pctpmin} %/min from the power at its start`)
	t.ok(-worstBelow <= below and worstAbove <= above, `the power follows {id}'s demand within its band`)
	t.ok(loadOff <= 1e-9 * load0, `the steam plant's load runs back with it, at the same rate to the same target ({loadOff})`)
	return p, target
end

-- Four minutes after a runback is complete: the plant holds the target, with the load there too
local function settled(t: any, p: any, target: number, id: string)
	local thermal = p.channels:get("core.thermalPower_pctFP")
	local flow = p.channels:get("primary.flowFraction")
	local reach = (Config.Program.rodAuto.holdBand_K + Config.Core.flow.thermocoupleNoise_K) * flow / 1.75
	t.log(string.format("%s settled: thermal %.2f %%FP, neutron %.2f %%FP, load %.2f %%, rod auto's reach ±%.2f %%FP",
		id, thermal, p.channels:get("core.power_pctFP"), p.channels:get("ihx.sinkLoad_pct"), reach))
	t.eq(p.channels:get("ihx.sinkLoad_pct"), target, "the load stays at the target after the runback")
	t.near(thermal, target, reach, `{id} settles at {target} %FP`)
	t.eq(p.channels:get("protection.runback"), "", "and the runback is over, with rod auto holding the plant")
end

-- Persistence for a private server's plant under `key`, in `store`
local function persist(p: any, store: any, key: string): any
	return Persistence.new({
		config = Config,
		registry = p.registry,
		log = p.log,
		bus = p.bus,
		clock = p.scheduler.clock,
		store = store,
		mode = "private",
		key = key,
		ownerUserId = 7,
		channels = p.channels,
		faults = p.faults,
	})
end

-- The first place two saved slices differ, as a path with both values, or nil when they are the same
local function difference(want: any, got: any, path: string): string?
	if type(want) ~= "table" or type(got) ~= "table" then
		return if want == got then nil else `{path}: saved {tostring(want)}, loaded {tostring(got)}`
	end
	for k, v in want do
		local d = difference(v, got[k], `{path}.{tostring(k)}`)
		if d then
			return d
		end
	end
	for k, v in got do
		if want[k] == nil then
			return `{path}.{tostring(k)}: saved nil, loaded {tostring(v)}`
		end
	end
	return nil
end

--[[
	Straight after a load, before any tick, every system saves again exactly what it saved, except for what the load
	itself changes (D-053): the PSS trips, keeping its first out if it had one and taking SERVER-CLOSE if not; the PSS
	rods go in, except a stuck one, and the SSRs too if the SSS had tripped them; rod auto drops to manual (D-035).
	Core is left out: it saves its power to re-seat the precursors from, which it does on its first step, and the
	delayed-neutron tail after the load is what shows it did.
]]
local function loadsWhatItSaved(t: any, b: any, store: any, key: string)
	local _, saved = store:get(key) -- a copy, to write the load's changes into
	local expected = saved.systems
	local prot, rods = expected.Protection, expected.RodDrives
	local ssrIn = rods.scrammed.SSR == true
	prot.tripped = { PSS = true, SSS = if prot.tripped.SSS then true else nil }
	if prot.firstOut == "" then
		prot.firstOut = "SERVER-CLOSE"
	end
	for _, drive in b.byName.RodDrives.drives do
		if not rods.stuck[drive.name] and (drive.system == "PSS" or ssrIn) then
			rods.positions[drive.name] = 0
		end
	end
	rods.scrammed = { PSS = true, SSR = if ssrIn then true else nil }
	expected.AutoControls.rodOn = false
	t.eq(b.byName.Core.reseatPower, expected.Core.power_pctFP / 100, "the core re-seats at the power it was saved at")
	expected.Core = nil
	for _, sys in b.registry.systems do
		local name = sys.spec.name
		if expected[name] ~= nil then
			local d = difference(expected[name], sys:save(), name)
			t.ok(d == nil, d or `{name} comes back as it was saved, with only the trip's changes`)
		end
	end
end

-- How many times the log records a server close as a reactor trip
local function serverCloses(log: any): number
	local n = 0
	for _, rec in log:export() do
		if rec.kind == "reactor.trip" and rec.target == "SERVER-CLOSE" then
			n += 1
		end
	end
	return n
end

return {
	["a private server saves §14.6's list and comes back tripped: all ten systems in one round trip (D-053)"] = function(t)
		local store = Persistence.MemoryStore.new()
		local function persistence(p: any): any
			return persist(p, store, "plant/d053")
		end

		-- a plant at 30 %FP with one of each §14.6 item in it, and the 1/M reference its start-up took at hot
		-- standby, while the source range was energised
		local a = plant()
		run(a, 1)
		t.ok(a.byName.Detectors:applyCommand(AUTO, { kind = "ni.reference" }).ok, "a 1/M reference is taken")
		local reference = a.byName.Detectors.reference_cps
		t.ok(InitialConditions.seatAtPower(a.byName, a.channels, Config, 30) ~= nil, "seated at 30 %FP")
		run(a, 2)
		local rods, pumps, ihx, prot = a.byName.RodDrives, a.byName.PrimaryPumps, a.byName.IHX, a.byName.Protection
		t.ok(a.faults:arm("RD-STUCK", { rod = "SMA1" }, AUTO).ok, "a stuck rod (an active fault)")
		t.ok(pumps:applyCommand(AUTO, { kind = "pump.stop", target = "PP3" }).ok, "a stopped pump")
		t.ok(ihx:applyCommand(AUTO, { kind = "loop.stop", target = "2" }).ok, "a stopped loop")
		t.ok(ihx:applyCommand(AUTO, { kind = "ihx.shutter", target = "1A", value = 0.5 }).ok, "a shutter demand")
		t.ok(prot:applyCommand(AUTO, { kind = "pss.bypass", target = "COVER-GAS", value = 1 }).ok, "a trip bypass")
		t.ok(a.byName.AutoControls:applyCommand(AUTO, { kind = "auto.flow", value = 1 }).ok, "flow auto in")
		t.ok(a.byName.AutoControls:applyCommand(AUTO, { kind = "auto.rod", value = 1 }).ok, "rod auto in")
		run(a, 1)
		t.eq(a.channels:get("protection.tripped"), false, "still at power when the server closes")
		local stuckAt = rods.drives[rods:indexOf("SMA1")].position_mm
		local shutter = ihx.units[1].demand
		local mode = a.channels:get("program.mode")
		local pools, fuel, decay = a.byName.Pools, a.byName.FuelThermal, a.byName.DecayHeat
		local hot1, cold, gas = pools.hot[1], pools.cold, pools.gas_mol
		local Tf, H = table.clone(fuel.Tf), table.clone(decay.H)

		t.ok((persistence(a):save()), "saved")
		local saved = store.data["plant/d053"]
		for _, sys in a.registry.systems do
			t.ok(saved.systems[sys.spec.name] ~= nil, `{sys.spec.name} saves its slice`)
		end
		t.ok(saved.systems.Detectors.reference_cps ~= nil, "the reference is in Detectors' slice")

		-- a new server, a fresh plant, the same store
		local b = plant()
		t.eq(persistence(b):load(), "loaded")
		loadsWhatItSaved(t, b, store, "plant/d053")
		local rodsB, protB = b.byName.RodDrives, b.byName.Protection
		-- a server close counts as a reactor trip: rods in, scram latched, in the mode it was in
		t.ok(protB.tripped.PSS, "the reactor comes back tripped")
		t.eq(protB.tripped.SSS, nil, "by the PSS alone")
		t.eq(protB.firstOut, "SERVER-CLOSE", "with the server close as its first out")
		t.eq(serverCloses(b.log), 1, "logged once, as a reactor trip")
		t.ok(rodsB.scrammed.PSS, "the scram is latched")
		for _, drive in rodsB.drives do
			if drive.name == "SMA1" then
				t.eq(drive.position_mm, stuckAt, "the stuck rod is where it stuck")
				t.eq(drive.stuck, true)
			elseif drive.system == "PSS" then
				t.eq(drive.position_mm, 0, `{drive.name} is in`)
			end
		end
		t.eq(b.byName.Detectors.reference_cps, reference, "the 1/M reference is kept")
		t.eq(b.channels:get("program.mode"), mode, "in the mode it was in")
		-- §14.6's list
		t.eq(b.byName.PrimaryPumps.pumps[3].tripped, true, "the stopped pump is stopped")
		t.eq(b.byName.IHX.loops[2].running, false, "the stopped loop is stopped")
		t.eq(b.byName.IHX.units[1].demand, shutter, "the shutter demand is kept")
		t.eq(protB.bypassed["COVER-GAS"], true, "the bypass is kept")
		t.ok(b.faults:isActive("RD-STUCK"), "the active fault is active")
		t.eq(b.byName.AutoControls.flowOn, true, "flow auto stays in")
		t.eq(b.byName.AutoControls.rodOn, false, "rod auto drops to manual on the trip (D-035)")
		t.eq(b.byName.IHX.sinkLoad, 0, "and the turbines tripped with the reactor")
		-- the thermal state the decay heat needs, with it
		t.eq(b.byName.Pools.hot[1], hot1, "the hot pool")
		t.eq(b.byName.Pools.cold, cold, "the cold pool")
		t.eq(b.byName.Pools.gas_mol, gas, "the cover gas")
		local fuelOff, decayOff = 0, 0
		for i, v in b.byName.FuelThermal.Tf do
			fuelOff = math.max(fuelOff, math.abs(v - Tf[i]))
		end
		for i, v in b.byName.DecayHeat.H do
			decayOff = math.max(decayOff, math.abs(v - H[i]))
		end
		t.eq(fuelOff, 0, "the fuel temperatures")
		t.eq(decayOff, 0, "and the decay heat (D-037)")

		-- and the loaded plant runs on, shut down, from where it was: over its first tick no heat flow in the plant
		-- exceeds rated power, so the hot pool's first node moves by no more than that could move it
		run(b, DT)
		local node = b.byName.Pools.hotMass[1] * Sodium.specificHeat(hot1)
		local oneTick = Config.Units.ratedThermal_MWt * 1e6 * DT / node
		t.ok(math.abs(b.byName.Pools.hot[1] - hot1) <= oneTick,
			string.format("the hot pool carries on from its saved temperature (moved %.3f K, bound %.3f K)", b.byName.Pools.hot[1] - hot1, oneTick))
		run(b, 10)
		t.ok(protB.tripped.PSS, "still tripped")
		t.ok(b.channels:get("core.k") < 1, "subcritical")
		--[[
			The trip happened at the load, so ten seconds on the core is on its delayed-neutron tail. It is below the
			prompt drop from the saved power, n₀·β/(β − ρ), because the precursors only decay from there, and above
			the level the source alone would hold, q/(−ρ).
		]]
		local beta = 0
		for _, b in Config.Kinetics.groups.beta_pcm do
			beta += b
		end
		local rho = b.channels:get("core.rho_pcm")
		local n = b.channels:get("core.power_pctFP")
		local prompt = saved.systems.Core.power_pctFP * beta / (beta - rho)
		local sourceOnly = b.byName.Core.source * 100 / (-rho * 1e-5)
		t.ok(n < prompt and n > sourceOnly,
			string.format("on the trip's tail: %.3g %%FP, between the source's %.3g and the prompt drop's %.3g", n, sourceOnly, prompt))
	end,

	["a fault comes back active but is not fired again, and its own effects come back with it (D-053)"] = function(t)
		local store = Persistence.MemoryStore.new()
		local function persistence(p: any): any
			return persist(p, store, "plant/faults")
		end
		local a = plant()
		t.ok(InitialConditions.seatAtPower(a.byName, a.channels, Config, 30) ~= nil, "seated at 30 %FP")
		run(a, 1)
		local pumps, ihx, prot, det, pools = a.byName.PrimaryPumps, a.byName.IHX, a.byName.Protection,
			a.byName.Detectors, a.byName.Pools
		-- the faults whose arm is the event itself, each then answered by the crew
		t.ok(a.faults:arm("PP-TRIP", { pump = 2 }, AUTO).ok, "PP2 trips")
		t.ok(pumps:applyCommand(AUTO, { kind = "pump.start", target = "PP2" }).ok, "and the crew restarts it")
		t.ok(a.faults:arm("SL-LOST", { loop = 3 }, AUTO).ok, "loop 3 is lost")
		t.ok(ihx:applyCommand(AUTO, { kind = "loop.start", target = "3" }).ok, "and restarted")
		t.ok(a.faults:arm("IHX-SHUT", { unit = 2 }, AUTO).ok, "unit 2's shutter drifts shut")
		t.ok(ihx:applyCommand(AUTO, { kind = "ihx.shutter", target = "1B", value = 1 }).ok, "and is opened again")
		t.ok(a.faults:arm("PROT-CHANNEL", { signal = "COVER-GAS" }, AUTO).ok, "a row is left bypassed")
		t.ok(prot:applyCommand(AUTO, { kind = "pss.bypass", target = "COVER-GAS", value = 0 }).ok, "and restored")
		-- the faults whose effect is a standing condition, which only the system's own slice can carry
		t.ok(a.faults:arm("NI-FAIL", { channel = "PR2", mode = "freeze" }, AUTO).ok, "PR2 freezes")
		t.ok(a.faults:arm("DND-HIGH", { factor = 5 }, AUTO).ok, "the DNDs rise")
		t.ok(a.faults:arm("CG-LEAK", { rate_molps = 0.5 }, AUTO).ok, "the cover gas leaks")
		run(a, 1)
		local frozen = det.pr[2]
		local shutter = ihx.units[2].demand
		t.eq(ihx.units[2].name, "1B")
		t.eq(shutter, 1, "unit 1B's shutter is open again before the save")
		t.ok(frozen > 0, "PR2 is frozen at a reading")
		t.ok((persistence(a):save()), "saved")

		local b = plant()
		t.eq(persistence(b):load(), "loaded")
		for _, id in { "PP-TRIP", "SL-LOST", "IHX-SHUT", "PROT-CHANNEL", "NI-FAIL", "DND-HIGH", "CG-LEAK" } do
			t.ok(b.faults:isActive(id), `{id} is still active`)
		end
		t.eq(b.byName.PrimaryPumps.pumps[2].tripped, false, "the pump the crew restarted is still running")
		t.eq(b.byName.IHX.loops[3].running, true, "the loop they restarted is still running")
		t.eq(b.byName.IHX.units[2].demand, shutter, "the shutter they opened is still open")
		t.eq(b.byName.Protection.bypassed["COVER-GAS"], nil, "the row they restored is still in service")
		t.eq(b.byName.Detectors.failed.PR2, "freeze", "PR2 is still frozen")
		t.eq(b.byName.Detectors.pr[2], frozen, "at the reading it froze at")
		t.eq(b.byName.Detectors.dndFactor, 5, "the DNDs still read five times background")
		t.eq(b.byName.Pools.leak_molps, 0.5, "and the cover gas still leaks at the same rate")
		run(b, 1)
		t.eq(b.byName.Detectors.pr[2], frozen, "a tick later PR2 still reads what it froze at")
	end,

	["a plant saved after a trip keeps its own first out, and the load finishes the rods' insertion (D-053)"] = function(t)
		local store = Persistence.MemoryStore.new()
		local a = plant()
		t.ok(InitialConditions.seatAtPower(a.byName, a.channels, Config, 30) ~= nil, "seated at 30 %FP")
		run(a, 1)
		t.ok(a.byName.Protection:applyCommand(AUTO, { kind = "reactor.trip.manual", target = "BCR" }).ok, "tripped from the BCR")
		run(a, 2 * DT) -- the server closes while the PSS rods are still on their way in
		local moving = 0
		for _, drive in a.byName.RodDrives.drives do
			if drive.system == "PSS" and drive.position_mm > 0 then
				moving += 1
			end
		end
		t.ok(moving > 0, `the server closes with {moving} PSS rods still out`)
		t.ok((persist(a, store, "plant/tripped"):save()), "saved")

		local b = plant()
		t.eq(persist(b, store, "plant/tripped"):load(), "loaded")
		loadsWhatItSaved(t, b, store, "plant/tripped")
		local prot = b.byName.Protection
		t.eq(prot.firstOut, "MANUAL", "the first out is the trip it had, not the server close")
		t.eq(serverCloses(b.log), 0, "and the close is not logged as a second trip")
		for _, drive in b.byName.RodDrives.drives do
			if drive.system == "PSS" then
				t.eq(drive.position_mm, 0, `{drive.name} is in`)
			end
		end
	end,

	["a plant saved after an SSS trip comes back with the SSS tripped and the SSRs in (D-053)"] = function(t)
		local store = Persistence.MemoryStore.new()
		local a = plant()
		t.ok(InitialConditions.seatAtPower(a.byName, a.channels, Config, 30) ~= nil, "seated at 30 %FP")
		run(a, 1)
		t.ok(a.byName.Protection:applyCommand(AUTO, { kind = "sss.trip.manual" }).ok, "the SSS is tripped")
		run(a, 0.5) -- the server closes while the SSRs are dropping
		for _, drive in a.byName.RodDrives.drives do
			if drive.system == "SSR" then
				t.ok(drive.position_mm > 0, `{drive.name} is still at {math.floor(drive.position_mm)} mm when the server closes`)
			end
		end
		t.ok((persist(a, store, "plant/sss"):save()), "saved")

		local b = plant()
		t.eq(persist(b, store, "plant/sss"):load(), "loaded")
		loadsWhatItSaved(t, b, store, "plant/sss")
		local prot, rods = b.byName.Protection, b.byName.RodDrives
		t.ok(prot.tripped.SSS and prot.tripped.PSS, "the SSS is still tripped, and the PSS trips with the close")
		t.eq(prot.firstOut, "SSS-MANUAL", "with the SSS trip as the first out")
		t.ok(rods.scrammed.SSR and rods.scrammed.PSS, "both scrams are latched")
		for _, drive in rods.drives do
			t.eq(drive.position_mm, 0, `{drive.name} is in`)
		end
	end,

	["an SSR the crew was withdrawing stays where it was, since a server close is a PSS trip (D-053)"] = function(t)
		local store = Persistence.MemoryStore.new()
		-- at hot standby after an SSS trip, reset, with SSR1 on its way back out at the withdraw-only speed (§3.4)
		local a = plant()
		local prot, rods = a.byName.Protection, a.byName.RodDrives
		t.ok(prot:applyCommand(AUTO, { kind = "sss.trip.manual" }).ok, "the SSS is tripped")
		run(a, 3)
		t.ok(prot:applyCommand(AUTO, { kind = "reactor.trip.reset" }).ok, "the trip is reset")
		run(a, DT)
		t.ok(rods:applyCommand(AUTO, { kind = "rod.reset" }).ok, "and the scram")
		t.ok(rods:applyCommand(AUTO, { kind = "rod.move", target = "SSR1", value = Config.Units.rodTravel_mm }).ok,
			"SSR1 is withdrawn")
		run(a, 20)
		local at = rods.drives[rods:indexOf("SSR1")].position_mm
		t.ok(at > 0 and at < Config.Rods.secondaryShutdown.parked_mm, `SSR1 is part way out ({at} mm), neither in nor parked`)
		t.ok((persist(a, store, "plant/ssr"):save()), "saved")

		local b = plant()
		t.eq(persist(b, store, "plant/ssr"):load(), "loaded")
		loadsWhatItSaved(t, b, store, "plant/ssr")
		local rodsB = b.byName.RodDrives
		t.eq(rodsB.scrammed.SSR, nil, "the SSRs are not scrammed")
		for _, drive in rodsB.drives do
			if drive.name == "SSR1" then
				t.eq(drive.position_mm, at, "SSR1 is where it was")
				t.eq(drive.demand_mm, at, "and stopped there")
			else
				t.eq(drive.position_mm, 0, `{drive.name} is in`)
			end
		end
	end,

	["flow auto's demand comes back with it, so the pumps do not reach for 100 % on the first tick (D-053)"] = function(t)
		local store = Persistence.MemoryStore.new()
		local function persistence(p: any): any
			return persist(p, store, "plant/flow")
		end
		local a = plant()
		t.ok(InitialConditions.seatAtPower(a.byName, a.channels, Config, 30) ~= nil, "seated at 30 %FP")
		t.ok(a.byName.AutoControls:applyCommand(AUTO, { kind = "auto.flow", value = 1 }).ok, "flow auto in")
		run(a, 5)
		local demand = a.byName.PrimaryPumps.pumps[1].demand_pct
		t.ok(demand < 100, `the programme holds the pumps below full speed at 30 %FP ({demand} %)`)
		t.ok((persistence(a):save()), "saved")

		local b = plant()
		t.eq(persistence(b):load(), "loaded")
		run(b, DT)
		for _, pump in b.byName.PrimaryPumps.pumps do
			t.eq(pump.demand_pct, demand, `{pump.name}'s demand is still the programme's on the first tick`)
		end
	end,

	["a version-1 save, from before D-053, also comes back tripped (D-053)"] = function(t)
		local store = Persistence.MemoryStore.new()
		-- version 1 saved the decay heat and nothing else of the plant
		local a = plant()
		t.ok(InitialConditions.seatAtPower(a.byName, a.channels, Config, 30) ~= nil, "seated at 30 %FP")
		store:set("plant/v1", {
			version = 1,
			clock = { sim = 0, grid = 0, slow = 0 },
			systems = { DecayHeat = a.byName.DecayHeat:save() },
			eventLog = {},
		})
		local b = plant()
		t.eq(persist(b, store, "plant/v1"):load(), "loaded")
		t.ok(b.byName.Protection.tripped.PSS and b.byName.RodDrives.scrammed.PSS, "tripped, with the scram latched")
		run(b, 1)
		t.ok(b.channels:get("core.k") < 1, "and shut down")
	end,

	["RB-2 runs a full-power plant back to 60 %FP at 60 %/min and settles there (§9.5, D-046)"] = function(t)
		local p, target = runback(t, "RB2")
		settled(t, p, target, "RB2")
	end,

	["a pump trip at full power with flow auto in runs back on RB-2 without a trip: the survivors hold 105 % (§4.2, D-046+)"] = function(t)
		local p = atFullPower(t)
		local pumps = p.byName.PrimaryPumps
		local cfg = Config.Primary.pumps
		local maxSpeed, ramp = cfg.speedRange_pct[2], cfg.maxRamp_pctps
		local pqTrip = Config.Protection.pss.powerToFlow.trip
		t.ok(p.faults:arm("PP-TRIP", { pump = 3 }, AUTO).ok, "PP3 trips at full power")
		local started, done, tripped, firstOut = nil, nil, false, ""
		local peak, peakAt, reached, heldBelow, demand = 0, nil, nil, math.huge, nil
		local function pq(): number
			return p.channels:get("core.power_pctFP") / 100 / p.channels:get("primary.flowFraction")
		end
		run(p, 300, function(tick)
			if p.channels:get("protection.tripped") and not tripped then
				tripped, firstOut = true, p.channels:get("protection.firstOut")
			end
			local rb = p.channels:get("protection.runback")
			if rb == "RB2" and not started then
				started = tick
			elseif started and not done and rb == "" then
				done = tick
				demand = p.channels:get("auto.pumpSpeedDemand_pct") -- what the pumps read on the next tick
			end
			if started and not done then
				if pq() > peak then
					peak, peakAt = pq(), tick
				end
				local slowest = math.huge
				for i = 1, 2 do
					slowest = math.min(slowest, pumps.pumps[i].speed_pct)
				end
				if reached then
					heldBelow = math.min(heldBelow, slowest)
				elseif slowest >= maxSpeed then
					reached = tick
				end
			end
			return done ~= nil and tick >= done + 1
		end)
		t.log(string.format("RB-2 from tick %s to %s (%.1f s); survivors at %d %% after %.1f s; P/Q peak %.3f at %.1f s (trip %.2f); tripped %s %s",
			tostring(started), tostring(done), ((done or 0) - (started or 0)) * DT, maxSpeed, (reached or 0) * DT, peak,
			(peakAt or 0) * DT, pqTrip, tostring(tripped), firstOut))
		t.ok(started ~= nil and started <= 2, "RB-2 starts from its own trigger, the PUMPS row, within a tick of the trip")
		-- the drives ramp from 100 % at the 2 %/s limit, starting the tick after RB-2 shows (the pumps read it late)
		t.ok(reached ~= nil and reached * DT <= (maxSpeed - 100) / ramp + 3 * DT,
			`the surviving pumps reach {maxSpeed} % at the {ramp} %/s ramp`)
		t.eq(heldBelow, maxSpeed, `and hold {maxSpeed} % while RB-2 runs`)
		t.ok(peak < pqTrip, string.format("P/Q stays below the %.2f trip (peak %.3f)", pqTrip, peak))
		t.eq(tripped, false, "the plant runs back without a trip")
		t.ok(done ~= nil, "and RB-2 completes")
		-- once RB-2 is over, flow auto has the pumps again, a tick later as they read it (§9.4: it ignores the trip, so
		-- its demand is the three-pump programme's)
		for i = 1, 2 do
			t.eq(pumps.pumps[i].demand_pct, demand, `{pumps.pumps[i].name} is back on flow auto's demand`)
		end
		-- what flow auto does with two pumps is §9.4's weakness: log it rather than assert it (D-046+)
		local after, afterFirstOut = nil, ""
		run(p, 120, function(tick)
			if p.channels:get("protection.tripped") then
				after, afterFirstOut = tick, p.channels:get("protection.firstOut")
				return true
			end
			return false
		end)
		t.log(string.format("after RB-2, with flow auto left in on two pumps at %.1f %%: %s", demand or 0,
			if after then string.format("the plant trips on %s %.1f s later", afterFirstOut, after * DT) else "no trip in 120 s"))
	end,

	["RB-1 runs a full-power plant back to 64 %FP at 30 %/min and settles there (§9.5, D-046)"] = function(t)
		local p, target = runback(t, "RB1")
		settled(t, p, target, "RB1")
	end,

	["a neutron trip reaches the rods on the tick after the core's power crosses it (D-048)"] = function(t)
		local p = plant()
		t.ok(InitialConditions.seatAtPower(p.byName, p.channels, Config, 100) ~= nil, "seated at 100 %FP")
		--[[
			PQ reads the core's power directly, so it would scram the PSS rods on the first tick whatever the order.
			It is bypassed (D-055 allows the one row). SSS-PQ does the same for the secondary shutdown rods, which
			this test does not watch: it follows PR-HIGH, the neutron trip, and the PSS rods it drops.
		]]
		local prot, rods = p.byName.Protection, p.byName.RodDrives
		t.ok(prot:applyCommand(AUTO, { kind = "pss.bypass", target = "PQ", value = 1 }).ok, "PQ bypassed")
		run(p, 1)
		t.eq(p.channels:get("protection.tripped"), false, "steady at full power")

		-- +100 pcm between two ticks, as a rod ejection would be: the rods are placed, and the core prompt-jumps to
		-- β/(β − ρ) ≈ 139 %FP on its next step, past §9.5's 115 %FP by far more than the D-025 channel noise
		t.ok(rods:seatCritical(p.channels:get("rods.indicativeWorth_pcm") - 100), "a +100 pcm step")
		local before = {}
		for i, drive in rods.drives do
			before[i] = drive.position_mm
		end
		local trip = Config.Protection.pss.powerRangeHigh.trip_pctFP
		local crossed: number?, tripped: number?, moved: number?
		run(p, 1, function(tick): boolean?
			if crossed == nil and p.channels:get("core.power_pctFP") > trip then
				crossed = tick
			end
			if tripped == nil and prot.state["PR-HIGH"].trip then
				tripped = tick
			end
			for i, drive in rods.drives do
				if moved == nil and drive.system == "PSS" and drive.position_mm ~= before[i] then
					moved = tick
				end
			end
			return nil
		end)
		t.eq(crossed, 1, "the core's power crosses the trip setpoint on the first tick")
		t.eq(tripped, crossed, "PR-HIGH trips on the same tick, because Detectors measured this tick's power")
		-- RodDrives reads protection.scram lagged (it runs before Protection), which is the one tick left
		t.eq(moved, (crossed or 0) + 1, "and the PSS rods move on the next tick, at t + 0.1 s")
	end,
}
