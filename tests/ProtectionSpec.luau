--!strict
--[[
	Protection verification (spec §9.5, D-004, D-025).

	Two things matter here and both are tested: that every §9.5 trip fires when its signal reaches its setpoint,
	and — harder — that none of them fires when it should not. A protection system that trips readily is not
	safe, it is unusable: it fills the first-out with noise and teaches the crew to ignore the annunciator.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Config = require(Kallskar:WaitForChild("Config")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local Protection = require(Root:WaitForChild("Systems"):WaitForChild("Protection")) :: any

local PSS = Config.Protection.pss
local KEL = Config.Units.kelvinOffset_K
local DT = 1 / Config.Clocks.fast_Hz
local DND = Config.Instruments.dndBackground_cps
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

--[[
	A plant sitting quietly at `power` %FP (full power by default), with every signal where §9.5 says normal.
	The power range channels are set from the same number: a test that moves the plant's power without moving
	its instruments is describing a plant whose PR channels have all failed high, which trips on PR-HIGH before
	it reaches whatever the test meant to check.
]]
local function make(power: number?)
	local pctFP = power or 100
	local ch = Channels.new()
	ch:declareExternal("detectors.pr_pctFP", { pctFP, pctFP, pctFP, pctFP })
	ch:declareExternal("detectors.period_s", { 1e6, 1e6, 1e6 })
	ch:declareExternal("detectors.fluxRate_pctFPps", 0)
	ch:declareExternal("detectors.dnd_cps", { DND, DND, DND, DND, DND, DND })
	ch:declareExternal("pools.mixedCoreOutletMeasured_K", PSS.coreOutletMixed.normal_C + KEL)
	ch:declareExternal("pools.coreInlet_K", PSS.coreInlet.normal_C + KEL)
	ch:declareExternal("pools.coverGas_MPa", PSS.coverGas.normal_MPa)
	ch:declareExternal("fuel.assemblyOutlet_K", { 832, 832, 832, 832, 832 })
	ch:declareExternal("primary.pumpsRunning", 3)
	ch:declareExternal("primary.flowFraction", 1)
	ch:declareExternal("primary.pumpSpeed_pct", { 100, 100, 100 })
	ch:declareExternal("ihx.loopsRunning", 3)
	ch:declareExternal("core.power_pctFP", pctFP)
	ch:declareExternal("program.mode", 1)
	ch:declareExternal("site.seismic_g", 0)
	ch:declareExternal("electrical.boards11kV", 3)
	ch:declareExternal("core.reactivityBalance_pcm", 0)
	ch:declareExternal("turbine.bypassAvailable", true)
	ch:declareExternal("pools.levelDeviation_m", 0)
	ch:declareExternal("rods.allPssInserted", false)
	ch:declareExternal("rods.regulatingInBand", true)
	ch:declareExternal("rods.selection", "")
	local sys = System.new(Protection)
	local bus = Bus.new()
	sys:init({
		config = Config,
		channels = ch:port(Protection.spec),
		log = EventLog.new(Config, { sim = 0, grid = 0 }),
		bus = bus,
	})
	return sys, ch, bus
end

local function run(sys: any, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
	end
end

local function fill(n: number, value: number): { number }
	local t = table.create(n, value)
	return t
end

return {
	["a plant at §9.5's normal column does not trip, alarm or block"] = function(t)
		local sys, ch = make()
		run(sys, 60)
		local s = sys:getState()
		t.eq(ch:get("protection.scram"), "none", "no scram")
		t.ok(not ch:get("protection.tripped"))
		t.eq(ch:get("protection.firstOut"), "", "nothing has gone first")
		t.ok(not ch:get("protection.rodWithdrawalBlock"), "no rod block")
		t.eq(#s.active, 0, "and no alarms in")
		-- nothing is INHIBITED here either: the rows §9.5 arms only below 10 %FP are simply not evaluated at
		-- power, and only a rule that holds a trip off when its signal is present annunciates itself
		t.eq(#s.inhibited, 0, "and nothing is holding a trip off")
	end,

	["PR high flux trips 2-out-of-4, not 1 (§9.5, D-005)"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		-- one quadrant reading high is a channel failure, not an overpower
		ch:setExternal("detectors.pr_pctFP", { 117, 100, 100, 100 })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "one channel is outvoted")
		t.ok(sys:getState().monitors["PR-HIGH"].alarm, "but it does raise the alarm")
		ch:setExternal("detectors.pr_pctFP", { 117, 117, 100, 100 })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "PSS", "two of four trips")
		t.eq(ch:get("protection.firstOut"), "PR-HIGH", "and is the first out")
	end,

	["first-out latches the signal that went first, not the loudest"] = function(t)
		local sys, ch, bus = make()
		local trips = {}
		bus:subscribe("Trip", function(p)
			table.insert(trips, p)
		end)
		run(sys, 1)
		ch:setExternal("pools.coverGas_MPa", PSS.coverGas.trip_MPa * 1.1)
		run(sys, 0.5)
		t.eq(ch:get("protection.firstOut"), "COVER-GAS")
		-- a second, bigger signal arrives: the first-out must not move
		-- 117 %FP is past the PSS's 115 but short of the SSS's 118, so this stays one shutdown system
		ch:setExternal("detectors.pr_pctFP", fill(4, 117))
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "COVER-GAS", "still the first one")
		t.ok(sys:getState().monitors["PR-HIGH"].trip, "even though PR-HIGH is now tripped too")
		t.eq(#trips, 1, "one Trip on the bus, not one per signal")
	end,

	["a trip latches until reset, and reset is refused while the signal is present"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		ch:setExternal("pools.mixedCoreOutletMeasured_K", PSS.coreOutletMixed.trip_C + 5 + KEL)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "PSS")
		local early = sys:applyCommand(OPERATOR, { kind = "reactor.trip.reset" })
		t.ok(not early.ok, "refused while the core outlet is still high")
		ch:setExternal("pools.mixedCoreOutletMeasured_K", PSS.coreOutletMixed.normal_C + KEL)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "PSS", "the trip stays latched even once the signal clears")
		t.ok(sys:applyCommand(OPERATOR, { kind = "reactor.trip.reset" }).ok, "now it resets")
		t.eq(ch:get("protection.scram"), "none")
		t.eq(ch:get("protection.firstOut"), "", "and first-out clears with it")
	end,

	["D-004: the core inlet low trip is inhibited by mode, and says so"] = function(t)
		local sys, ch = make()
		ch:setExternal("pools.coreInlet_K", PSS.coreInlet.tripLow_C - 10 + KEL)

		-- Mode 1 above 5 %FP: armed, and it trips
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "INLET-LOW", "armed in Mode 1 at power")
		t.ok(sys:applyCommand(OPERATOR, { kind = "reactor.trip.reset" }).ok == false, "still present, so no reset")

		for _, case in {
			{ mode = 4, label = "Mode 4" },
			{ mode = 5, label = "Mode 5" },
		} do
			local fresh, fch = make()
			fch:setExternal("pools.coreInlet_K", PSS.coreInlet.tripLow_C - 10 + KEL)
			fch:setExternal("program.mode", case.mode)
			run(fresh, 1)
			t.eq(fch:get("protection.scram"), "none", `inhibited in {case.label}`)
			local inhibited = table.concat(fresh:getState().inhibited, "; ")
			t.ok(string.find(inhibited, "INLET-LOW", 1, true) ~= nil, "and annunciated as inhibited, not silently skipped")
		end

		-- Mode 3 is inhibited only while every PSS rod is in
		local three, tch = make()
		tch:setExternal("pools.coreInlet_K", PSS.coreInlet.tripLow_C - 10 + KEL)
		tch:setExternal("program.mode", 3)
		tch:setExternal("rods.allPssInserted", true)
		run(three, 1)
		t.eq(tch:get("protection.scram"), "none", "Mode 3 with the rods in")
		tch:setExternal("rods.allPssInserted", false)
		run(three, 1)
		t.eq(tch:get("protection.scram"), "PSS", "but armed in Mode 3 with a rod out")

		-- Mode 2 below 350 °C during heatup
		local two, twoCh = make(0)
		twoCh:setExternal("program.mode", 2)
		twoCh:setExternal("pools.coreInlet_K", 300 + KEL)
		run(two, 1)
		t.eq(twoCh:get("protection.scram"), "none", "Mode 2 during heatup")
	end,

	["the 25 %FP low setpoint protects a startup and bypasses itself above the permissive"] = function(t)
		local sys, ch = make(2)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "quiet at 2 %FP")
		-- a fast excursion while still under the permissive
		ch:setExternal("detectors.pr_pctFP", fill(4, 30))
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "PR-LOW-SP", "§9.5's low setpoint catches it at 25 %FP")

		-- above the permissive it is bypassed, so a normal ascension past 25 % does not trip
		local up, uch = make(40)
		run(up, 1)
		t.eq(uch:get("protection.scram"), "none", "40 %FP is normal operation, not a trip")
	end,

	["the period trip and rod block are armed only below 10 %FP, and the block persists (D-025)"] = function(t)
		local sys, ch = make()
		ch:setExternal("detectors.period_s", { 20, 20, 20 })
		run(sys, 5)
		t.ok(not ch:get("protection.rodWithdrawalBlock"), "a 20 s period at full power is not even evaluated")

		local low, lch = make(5)
		lch:setExternal("detectors.period_s", { 20, 20, 20 })
		run(low, 1)
		t.ok(not low:getState().monitors["PERIOD"].block, "one second is not enough to raise the block")
		run(low, 3)
		t.ok(low:getState().monitors["PERIOD"].block, "but it holds, so the block comes in")
		t.ok(lch:get("protection.rodWithdrawalBlock"))
		t.eq(lch:get("protection.scram"), "none", "20 s is a block, not the 10 s trip")
		lch:setExternal("detectors.period_s", { 8, 8, 8 })
		run(low, 1)
		t.eq(lch:get("protection.firstOut"), "PERIOD", "8 s trips")
	end,

	["losing pumps and loops: one is a runback, two is a trip (§9.5)"] = function(t)
		local sys, ch, bus = make()
		local runbacks = {}
		bus:subscribe("Runback", function(p)
			table.insert(runbacks, p)
		end)
		run(sys, 1)
		ch:setExternal("primary.pumpsRunning", 2)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "one pump lost is not a trip")
		t.eq(ch:get("protection.runback"), "RB2", "§9.5: RB-2")
		t.eq(ch:get("protection.runbackTarget_pctFP"), Config.Protection.runbacks.RB2.target_pctFP, "to 60 %FP")
		t.eq(ch:get("protection.runbackRate_pctpmin"), Config.Protection.runbacks.RB2.rate_pctpmin, "at 60 %/min")
		t.eq(#runbacks, 1)
		ch:setExternal("primary.pumpsRunning", 1)
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "PUMPS", "two lost trips")

		local loops, lch, lbus = make()
		local seen = {}
		lbus:subscribe("Runback", function(p)
			table.insert(seen, p)
		end)
		lch:setExternal("ihx.loopsRunning", 2)
		run(loops, 1)
		t.eq(lch:get("protection.runback"), "RB1", "§9.5: one secondary loop lost is RB-1")
		t.ok(lch:get("protection.rodRunback"), "which drives the shim banks in")
		lch:setExternal("ihx.loopsRunning", 1)
		run(loops, 1)
		t.eq(lch:get("protection.firstOut"), "LOOPS", "two lost trips")
	end,

	["power to flow: alarm and rod block at 1.05, trip at 1.12, armed above 5 %FP"] = function(t)
		local sys, ch = make()
		ch:setExternal("primary.flowFraction", 1 / (PSS.powerToFlow.alarm * 1.001))
		run(sys, 1)
		t.ok(sys:getState().monitors["PQ"].alarm, "§9.5: 1.05 alarms")
		t.ok(ch:get("protection.rodWithdrawalBlock"), "and blocks rod withdrawal")
		t.eq(ch:get("protection.scram"), "none")
		ch:setExternal("primary.flowFraction", 1 / (PSS.powerToFlow.trip * 1.01))
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "PQ", "1.12 trips")

		-- below the 5 %FP permissive, a low flow is a normal shutdown state rather than a fault
		local cold, cch = make(1)
		cch:setExternal("primary.flowFraction", 0.03)
		run(cold, 1)
		t.eq(cch:get("protection.scram"), "none", "not armed below 5 %FP")
	end,

	["the SSS is diverse: it trips on pump-speed flow when the flowmeter says otherwise"] = function(t)
		local sys, ch = make()
		-- the PSS flow signal reads healthy, but the pumps have actually slowed: the SSS sees it
		ch:setExternal("primary.flowFraction", 1.0)
		ch:setExternal("primary.pumpSpeed_pct", { 50, 50, 50 })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "SSR", "§9.5: the SSS uses pump-speed-derived flow")
		t.eq(ch:get("protection.firstOut"), "SSS-PQ")
		t.ok(not sys:getState().monitors["PQ"].trip, "while the PSS's own power-to-flow is happy")
	end,

	["the Curie latch releases the SSRs at 640 °C with its thermal lag (§9.5)"] = function(t)
		local sys, ch = make()
		local latch = Config.Rods.curieLatch
		run(sys, 1) -- let the latch settle at the normal sodium temperature before anything moves
		ch:setExternal("fuel.assemblyOutlet_K", fill(5, latch.releaseSodium_C + 40 + KEL))
		run(sys, latch.thermalLag_s * 0.3)
		t.eq(ch:get("protection.scram"), "none", "the lag holds it off at first")
		run(sys, latch.thermalLag_s * 2)
		t.eq(ch:get("protection.firstOut"), "CURIE", "and then it releases")
		t.eq(ch:get("protection.scram"), "SSR", "the secondary shutdown rods, not the PSS")
	end,

	["manual trip needs two buttons in the control room, or one in the backup"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		local first = sys:applyCommand(OPERATOR, { kind = "reactor.trip.manual", tag = "MCR" })
		t.ok(first.ok)
		t.eq(ch:get("protection.scram"), "none", "§9.5: one button is not a trip")
		sys:applyCommand(OPERATOR, { kind = "reactor.trip.manual", tag = "MCR" })
		run(sys, 0.1)
		t.eq(ch:get("protection.firstOut"), "MANUAL", "two are")

		local backup, bch = make()
		backup:applyCommand(OPERATOR, { kind = "reactor.trip.manual", tag = "BCR" })
		run(backup, 0.1)
		t.eq(bch:get("protection.scram"), "PSS", "one button in the backup control room is enough")
	end,

	["a bypassed signal cannot trip, and the bypass is logged"] = function(t)
		local sys, ch = make()
		t.ok(sys:applyCommand(OPERATOR, { kind = "pss.bypass", tag = "COVER-GAS", value = 1 }).ok)
		ch:setExternal("pools.coverGas_MPa", PSS.coverGas.trip_MPa * 1.2)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "bypassed")
		t.ok(sys:getState().monitors["COVER-GAS"].alarm, "but the alarm still comes in, so it is visible")
		t.ok(sys:applyCommand(OPERATOR, { kind = "pss.bypass", tag = "COVER-GAS", value = 0 }).ok)
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "COVER-GAS", "and restoring it trips immediately")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "pss.bypass", tag = "NOT-A-SIGNAL", value = 1 }).ok)
	end,

	["assembly outlet deviation needs two channels, not one (§9.5)"] = function(t)
		local sys, ch = make()
		local normal = 832
		local trip = PSS.assemblyOutletDeviation.trip_K
		ch:setExternal("fuel.assemblyOutlet_K", { normal + trip + 5, normal, normal, normal, normal })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "one hot assembly is not a trip")
		t.ok(sys:getState().monitors["ASSY-DEV"].alarm, "it alarms")
		t.ok(ch:get("protection.rodWithdrawalBlock"), "and blocks withdrawal at +30 K")
		ch:setExternal("fuel.assemblyOutlet_K", { normal + trip + 5, normal + trip + 5, normal, normal, normal })
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "ASSY-DEV", "two is")
	end,

	["every §9.5 trip row exists, and the ones M1 cannot drive yet sit at safe values"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		local rows = sys:getState().monitors
		for _, id in {
			"PR-HIGH", "PR-LOW-SP", "PERIOD", "FLUX-RATE", "PQ", "CORE-OUT", "ASSY-DEV",
			"INLET-HIGH", "INLET-LOW", "LEVEL", "COVER-GAS", "DND", "PUMPS", "LOOPS",
			"SEISMIC", "ELEC-11KV", "SSS-FLUX", "SSS-PQ", "SSS-OUT",
		} do
			t.ok(rows[id] ~= nil, `§9.5 row {id} is implemented`)
		end
		-- the externals that belong to systems M1 does not build: wired, inert, and safe until written
		ch:setExternal("site.seismic_g", PSS.seismic.trip_g * 1.1)
		run(sys, 0.5)
		t.eq(ch:get("protection.firstOut"), "SEISMIC", "seismic is wired, and trips when something writes it")
		t.ok(sys:applyCommand(OPERATOR, { kind = "reactor.trip.reset" }).ok == false, "still shaking")
	end,

	["flux rate trips on a fall as well as a rise (§9.5, Phénix-style)"] = function(t)
		local sys, ch = make()
		ch:setExternal("detectors.fluxRate_pctFPps", PSS.fluxRate.tripRise_pctFPps * 0.9)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "inside the rise limit")
		ch:setExternal("detectors.fluxRate_pctFPps", PSS.fluxRate.tripRise_pctFPps * 1.1)
		run(sys, 0.5)
		t.eq(ch:get("protection.firstOut"), "FLUX-RATE", "a rise past +10 %FP/s")

		local down, dch = make()
		dch:setExternal("detectors.fluxRate_pctFPps", PSS.fluxRate.tripFall_pctFPps * 0.9)
		run(down, 1)
		t.eq(dch:get("protection.scram"), "none", "inside the fall limit")
		dch:setExternal("detectors.fluxRate_pctFPps", PSS.fluxRate.tripFall_pctFPps * 1.1)
		run(down, 0.5)
		t.eq(dch:get("protection.firstOut"), "FLUX-RATE", "and a fall past −5 %FP/s")
	end,
}
