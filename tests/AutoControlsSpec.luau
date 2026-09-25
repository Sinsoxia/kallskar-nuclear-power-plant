--!strict
--[[
	AutoControls verification (spec §9.4 Rev A6, §9.2, D-003, D-006, D-059).

	§9.4's controllers are competent, local and reactive (D-059), so what is tested is that each holds its own
	variable without overshooting and within its own sector: rod auto's model of its own moves, flow auto asking the
	pumps it has for the programme's flow, rod auto stopping at the band rather than reaching for a shim, and both
	tracking §9.2's programme rather than the flat numbers §9.4 quotes (D-003, finding F3).
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
local Systems = Root:WaitForChild("Systems")
local AutoControls = require(Systems:WaitForChild("AutoControls")) :: any
local RodDrives = require(Systems:WaitForChild("RodDrives")) :: any

local PROGRAM = Config.Program
local PART = PROGRAM.partLoad
local TABLE = PROGRAM.partLoadTable
local KEL = Config.Units.kelvinOffset_K
local DT = 1 / Config.Clocks.fast_Hz
local BAND = Config.Rods.regulating.normalBand_mm
local PROGRAM_LCO = Config.Protection.lco["LCO-10"]
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

-- §3.4's S-curve in the 500-mm equivalent millimetres rod auto sizes its moves in (D-059), as AutoControls has it
local ACTIVE = Config.Core.geometry.fissileHeight_mm
local TRAVEL = Config.Units.rodTravel_mm
local MODEL = PROGRAM.rodAutoModel
local function depth(z: number): number
	return math.clamp((TRAVEL - z) / ACTIVE, 0, 1)
end
local function worthFraction(d: number): number
	return d - math.sin(2 * math.pi * d) / (2 * math.pi)
end
local function equivalentMm(fromZ: number, toZ: number): number
	local slope = (1 - math.cos(2 * math.pi * depth(MODEL.measuredAt_mm))) / ACTIVE
	return (worthFraction(depth(fromZ)) - worthFraction(depth(toZ))) / slope
end
-- the model's final gain, K per equivalent millimetre, at full power (where make() seats its plant)
local GAIN_100 = 0
for _, mode in MODEL.byPower[#MODEL.byPower].modes do
	GAIN_100 += mode.gain_Kpmm
end

local function make(power: number?, outlet_C: number?)
	local pctFP = power or 100
	local ch = Channels.new()
	ch:declareExternal("core.power_pctFP", pctFP)
	ch:declareExternal("detectors.prMean_pctFP", pctFP) -- flow auto's measurement (D-059)
	ch:declareExternal("primary.pumpsRunning", 3)
	ch:declareExternal("ihx.sinkLoad_pct", pctFP) -- the steam plant on the same load, as at steady state
	ch:declareExternal("primary.flowFraction", pctFP / 100)
	ch:declareExternal("pools.mixedCoreOutletMeasured_K", (outlet_C or 550) + KEL)
	ch:declareExternal("rods.position_mm", { 500, 500, 500 })
	ch:declareExternal("rods.selection", "")
	ch:declareExternal("protection.rodWithdrawalBlock", false)
	ch:declareExternal("protection.runback", "")
	ch:declareExternal("protection.scram", "none")
	ch:declareExternal("protection.runbackTarget_pctFP", 100)
	local sys = System.new(AutoControls)
	local bus = Bus.new()
	sys:init({
		config = Config,
		channels = ch:port(AutoControls.spec),
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

--[[
	Rod auto reads the thermocouple through a first-order filter (D-059), so a reading changed in one tick reaches its
	decisions over the filter's time constant. Five of them leave e^−5, under 1 %, of a step: long enough for any
	change these tests make to have come through.
]]
local FILTER_S = PROGRAM.rodAutoTuning.measurementFilter_s
local SETTLE_S = 5 * FILTER_S

-- Step until `done` holds, for at most `seconds`; the time it took, or nil if it never did
local function runUntil(sys: any, seconds: number, done: () -> boolean): number?
	for n = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
		if done() then
			return n * DT
		end
	end
	return nil
end

return {
	["the setpoint follows §9.2's programme, not §9.4's flat 550 °C (D-003, F3)"] = function(t)
		for i, power in TABLE.power_pct do
			local flow = TABLE.flow_pct[i]
			local sys, ch = make(power)
			ch:setExternal("primary.flowFraction", flow / 100)
			run(sys, 1)
			-- D-049: §9.2 prints whole degrees, so a row is only good to its 0.5 K rounding
			t.near(ch:get("auto.coreOutletSetpoint_C"), TABLE.coreOutlet_C[i], 0.5,
				string.format("%d %%FP on %d %% flow", power, flow))
		end
		-- the rows that matter: below 40 %FP the programme is NOT 550, which is finding F3
		local low, lch = make(30)
		lch:setExternal("primary.flowFraction", 0.40)
		run(low, 1)
		t.near(lch:get("auto.coreOutletSetpoint_C"), 506, 0.5, "§9.2: 506 °C at 30 %FP, not 550")
		t.ok(lch:get("auto.coreOutletSetpoint_C") < 545, "a controller holding 550 here would fight the programme")
	end,

	["the flow programme follows §9.2, with its 40 % floor and D-007's ramp"] = function(t)
		local sys, ch = make(100)
		for i, power in TABLE.power_pct do
			ch:setExternal("detectors.prMean_pctFP", power)
			run(sys, 60) -- past the power filter, so the demand is the programme rather than the lag
			t.near(ch:get("auto.flowProgram_pct"), TABLE.flow_pct[i], 1,
				string.format("%d %%FP asks for %d %% flow", power, TABLE.flow_pct[i]))
		end
		-- D-007: between 5 and 10 %FP the floor ramps from 25 % to 40 % rather than stepping
		ch:setExternal("detectors.prMean_pctFP", 7.5)
		run(sys, 60)
		t.near(ch:get("auto.flowProgram_pct"), 32.5, 0.5, "D-007: half way up the ramp")
	end,

	["flow auto follows the power through only its noise filter, at the rates the plant can ramp (D-059)"] = function(t)
		--[[
			Flow auto asks for the programme's flow from the PR median, filtered only against D-025's noise
			(tools/derive/auto_tuning.py), so the flow lags the power by τ × rate and P/Q by (P + τ·rate)/P. The rods
			move at no more than 4 pcm/s (§3.4), so the power cannot step, and at the rates it can ramp at the lag is
			what is left: §9.4's 10 s filter, and the rod block it could reach, are gone.
		]]
		local tau = PROGRAM.primaryFlowAutoTuning.powerFilter_s
		local BLOCK = Config.Protection.pss.powerToFlow.alarm

		local function rampFrom(start_pctFP: number, pctPerMin: number): number
			local sys, ch = make(start_pctFP)
			sys:applyCommand(OPERATOR, { kind = "auto.flow", value = 1 })
			run(sys, 60) -- settle on programme first
			local power, worst = start_pctFP, 0
			for _ = 1, 1200 do
				power = math.min(power + pctPerMin / 60 * DT, 100)
				ch:setExternal("detectors.prMean_pctFP", power)
				sys:step(DT)
				local flow = ch:get("auto.pumpSpeedDemand_pct") / 100 -- three pumps, so the flow is the speed
				ch:setExternal("primary.flowFraction", flow)
				worst = math.max(worst, (power / 100) / flow)
			end
			return worst
		end

		local normal = rampFrom(60, PROGRAM_LCO.rate_pctpmin)
		local approved = rampFrom(60, PROGRAM_LCO.rateApproved_pctpmin)
		local runbackRate = rampFrom(60, Config.Protection.runbacks.RB1.rate_pctpmin)
		t.log(string.format("worst P/Q: %.3f at LCO-10's %d %%/min, %.3f at its approved %d, %.3f at RB-1's %d",
			normal, PROGRAM_LCO.rate_pctpmin, approved, PROGRAM_LCO.rateApproved_pctpmin,
			runbackRate, Config.Protection.runbacks.RB1.rate_pctpmin))
		t.ok(normal < 1.01, "inside LCO-10's 1 %/min the filter costs almost nothing")
		t.ok(approved < BLOCK, "and the approved 3 %/min stays clear of §9.5's 1.05 rod block")
		t.ok(runbackRate < BLOCK, "even a 30 %/min change stays clear of it now")
		-- the lag itself: the filter's, and nothing else
		local predicted = (60 + tau * Config.Protection.runbacks.RB1.rate_pctpmin / 60) / 60
		t.near(runbackRate, predicted, 0.02, "the excursion is the noise filter's lag")
	end,

	["flow auto asks the pumps it has for the programme's flow: one lost, the others go up by half (D-059)"] = function(t)
		local sys, ch = make(60)
		sys:applyCommand(OPERATOR, { kind = "auto.flow", value = 1 })
		run(sys, 1)
		t.near(ch:get("auto.pumpSpeedDemand_pct"), 60, 1e-9, "three pumps at the programme's 60 %")
		ch:setExternal("primary.pumpsRunning", 2)
		run(sys, DT)
		t.near(ch:get("auto.pumpSpeedDemand_pct"), 90, 1e-9, "one lost: the other two asked for 3/2 of it at once")
		-- at full power two pumps cannot make up the loss: the demand stops at §4.2's 105 %
		local full, fch = make(100)
		full:applyCommand(OPERATOR, { kind = "auto.flow", value = 1 })
		fch:setExternal("primary.pumpsRunning", 2)
		run(full, 1)
		t.eq(fch:get("auto.pumpSpeedDemand_pct"), Config.Primary.pumps.speedRange_pct[2], "the top of the range")
	end,

	["rod auto holds the band and does nothing inside it (§9.4)"] = function(t)
		local sys, ch = make(100, 550)
		t.ok(sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 }).ok, "rod auto in")
		run(sys, 5)
		t.eq(ch:get("auto.rodSelected"), "", "on programme, so nothing moves")

		-- 1 K off is inside §9.4's ±2 K band, even once the filter has taken all of it in
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 551 + KEL)
		run(sys, SETTLE_S)
		t.eq(ch:get("auto.rodSelected"), "", "still nothing: 1 K is inside the band")

		--[[
			5 K hot. It acts on the tick its filter carries the reading past the band: a first-order filter closes
			the gap to a step as e^(−t/τ), so from a filtered F₀ toward 555 °C it reaches 550 + band after
			τ·ln((555 − F₀)/(555 − 550 − band)). It inserts by the reactivity that filtered error calls for, less the
			rod-worth tolerance (D-059).
		]]
		local f, band = MODEL.correctionFraction, PROGRAM.rodAuto.holdBand_K
		local before = sys:getState().rodOutletFiltered_C
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 555 + KEL)
		local crossing = FILTER_S * math.log((555 - before) / (555 - 550 - band))
		local waited = runUntil(sys, SETTLE_S, function()
			return ch:get("auto.rodSelected") ~= ""
		end)
		t.ok(waited ~= nil, "too hot, so it acts")
		t.near(waited or 0, crossing, DT, `when its filter carries the reading past the band ({crossing} s)`)
		local effective = sys:getState().rodEffectiveError_K
		t.near(equivalentMm(500, ch:get("auto.rodDemand_mm")), -f * effective / GAIN_100, 1e-6,
			"sent in by the reactivity its filtered error calls for, through the S-curve")

		-- 5 K cold: once the move under way calls the wrong way beyond the band, it stops and withdraws
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 545 + KEL)
		t.ok(runUntil(sys, SETTLE_S, function()
			return ch:get("auto.rodDemand_mm") > 500
		end) ~= nil, "and out again when it is cold")
		effective = sys:getState().rodEffectiveError_K
		t.ok(effective < -band, "on an error beyond the band the other way")
		t.near(equivalentMm(500, ch:get("auto.rodDemand_mm")), -f * effective / GAIN_100, 1e-6, "by what that error calls for")
	end,

	["rod auto decides on its predicted error, the thermocouple plus what its moves have still to do (D-059)"] = function(t)
		--[[
			The model's arithmetic, with no plant: the thermocouple is held 5 K hot, and the rod is put at its target
			in one tick. Straight after, the model says nearly all of the move's effect is still to come, so the
			predicted error is inside the band although the raw one is 5 K, and rod auto does not move. With nothing
			answering, the prediction leaves the band as the model's modes run their course, and only then does it move
			again. That it waits long enough on a real plant is PlantSpec's to show, where the plant answers.
		]]
		local band = PROGRAM.rodAuto.holdBand_K
		local sys, ch = make(100, 555)
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		run(sys, DT)
		local target = ch:get("auto.rodDemand_mm")
		t.eq(ch:get("auto.rodSelected"), "RR1", "it inserts the most-withdrawn rod")
		ch:setExternal("rods.position_mm", { target, 500, 500 })
		run(sys, DT * 2)
		t.eq(ch:get("auto.rodSelected"), "", "at its target it lets the rod go")
		local state = sys:getState()
		-- what is still to come, from the modes: an instant move of Δ equivalent mm leaves Σ aᵢ·Δ·e^(−t/τᵢ)
		local moved = equivalentMm(500, target)
		t.log(string.format("just after an instant move of %.1f equivalent mm: %.2f K still to come, predicted error %.2f K",
			moved, state.rodPending_K, state.rodEffectiveError_K))
		t.near(state.rodEffectiveError_K, 5 + state.rodPending_K, 1e-9, "the predicted error is the raw one plus what is still to come")
		t.ok(math.abs(state.rodEffectiveError_K) <= band, "inside the band, although the raw error is 5 K")
		local waited, predictedThen = 0, nil
		for _ = 1, math.floor(900 / DT) do
			local before = sys:getState().rodEffectiveError_K
			sys:step(DT)
			if ch:get("auto.rodSelected") ~= "" then
				predictedThen = sys:getState().rodEffectiveError_K
				break
			end
			t.ok(math.abs(before) <= band + 1e-9, "while it waits, its prediction is inside the band")
			waited += 1
		end
		t.log(string.format("with nothing answering it waited %.1f s, then moved again on a predicted %.2f K", waited * DT, predictedThen or 0))
		t.ok(waited > 0 and predictedThen ~= nil and math.abs(predictedThen :: number) > band,
			"it moves again only once its prediction leaves the band")
	end,

	["rod auto moves one rod at a time, and keeps the three together (D-006, F6)"] = function(t)
		local sys, ch = make(100, 545) -- cold, so it withdraws
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		ch:setExternal("rods.position_mm", { 600, 400, 500 })
		run(sys, 1)
		t.eq(ch:get("auto.rodSelected"), "RR2", "withdrawing: it takes the most-inserted rod")

		ch:setExternal("pools.mixedCoreOutletMeasured_K", 555 + KEL) -- hot, so it inserts
		runUntil(sys, SETTLE_S, function()
			return ch:get("auto.rodSelected") ~= "RR2"
		end)
		t.eq(ch:get("auto.rodSelected"), "RR1", "inserting: it takes the most-withdrawn")
		-- one rod, never a bank: §9.4 says it never moves a shim
		t.ok(string.sub(ch:get("auto.rodSelected"), 1, 2) == "RR", "and only ever a regulating rod")
	end,

	["rod auto stops and alarms at the band rather than reaching for a shim (§9.4)"] = function(t)
		local sys, ch, bus = make(100, 545)
		local alarms = {}
		bus:subscribe("Alarm", function(p)
			table.insert(alarms, p)
		end)
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		-- every regulating rod already at the top of the band, and the plant still wants more power
		ch:setExternal("rods.position_mm", { BAND[2], BAND[2], BAND[2] })
		run(sys, 1)
		t.eq(ch:get("auto.rodSelected"), "", "it has no rod left to move")
		t.ok(ch:get("auto.rodOutOfBand"), "so it says so")
		t.eq(#alarms, 1, "§9.4: it stops and alarms")
		t.eq(alarms[1].tag, "AUTO-ROD-BAND")
		run(sys, 10)
		t.eq(#alarms, 1, "and does not repeat the alarm every tick")
		-- the weakness in one line: a crew would move a shim bank here, and this controller never will
		t.ok(ch:get("auto.rodSelected") == "", "it never reaches for a shim")
	end,

	["the band alarm goes out once rod auto has authority again, or is switched off"] = function(t)
		local sys, ch, bus = make(100, 545)
		local states = {}
		bus:subscribe("Alarm", function(p)
			if p.tag == "AUTO-ROD-BAND" then
				table.insert(states, p.state)
			end
		end)
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		ch:setExternal("rods.position_mm", { BAND[2], BAND[2], BAND[2] })
		run(sys, 1)
		t.eq(states[#states], "in", "out of authority, it alarms")
		-- the outlet comes back onto the 550 °C setpoint: nothing to do, and nothing to alarm about
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 550 + KEL)
		runUntil(sys, SETTLE_S, function()
			return states[#states] == "out"
		end)
		t.eq(states[#states], "out", "and the annunciator is told when that is over")
		t.ok(not ch:get("auto.rodOutOfBand"))
		-- in again, then switched to manual: the alarm goes with the controller
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 545 + KEL)
		runUntil(sys, SETTLE_S, function()
			return states[#states] == "in"
		end)
		t.eq(states[#states], "in")
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 0 })
		t.eq(states[#states], "out", "switching rod auto off clears its alarm too")
	end,

	["rod auto stands down for a scram or a runback"] = function(t)
		local sys, ch = make(100, 555)
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		run(sys, 1)
		t.ok(ch:get("auto.rodSelected") ~= "", "it is acting")
		ch:setExternal("protection.runback", "RB1")
		run(sys, 1)
		t.eq(ch:get("auto.rodSelected"), "", "a runback is not something to negotiate with")
		ch:setExternal("protection.runback", "")
		run(sys, 1)
		t.ok(ch:get("auto.rodOn"), "after a runback it is still in auto")
		ch:setExternal("protection.scram", "PSS")
		run(sys, 1)
		t.eq(ch:get("auto.rodSelected"), "", "nor a scram")
		-- D-035: a trip drops it to manual, so a reset does not hand a shut-down core to a controller
		t.ok(not ch:get("auto.rodOn"), "and a trip drops it to manual")
		ch:setExternal("protection.scram", "none")
		run(sys, 1)
		t.ok(not ch:get("auto.rodOn"), "where it stays after the reset until the crew puts it back")
		t.eq(ch:get("auto.rodSelected"), "", "moving nothing")
	end,

	["a rod withdrawal block stops rod auto withdrawing, but not inserting (§9.5)"] = function(t)
		local sys, ch = make(100, 545) -- cold: it wants to withdraw
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		ch:setExternal("protection.rodWithdrawalBlock", true)
		run(sys, 1)
		t.eq(ch:get("auto.rodSelected"), "", "blocked")
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 555 + KEL) -- now hot: inserting is always allowed
		runUntil(sys, SETTLE_S, function()
			return ch:get("auto.rodSelected") ~= ""
		end)
		t.ok(ch:get("auto.rodSelected") ~= "", "but it may still bring power down")
		t.ok(ch:get("auto.rodDemand_mm") < 500, "inserting")
	end,

	["switching auto off releases the rods"] = function(t)
		local sys, ch = make(100, 555)
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		run(sys, 1)
		t.ok(ch:get("auto.rodSelected") ~= "")
		t.ok(sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 0 }).ok, "back to manual")
		t.eq(ch:get("auto.rodSelected"), "", "and it lets go")
		run(sys, 5)
		t.eq(ch:get("auto.rodSelected"), "", "and stays let go")
	end,

	["RodDrives obeys rod auto through the same interlocks as an operator"] = function(t)
		--[[
			The auto and the drives wired together. Nothing here gives the controller a special path: it asks for
			a rod through the same request() an operator's command uses, so §3.4's one-at-a-time rule and the
			4 pcm/s interlock apply to it unchanged.
		]]
		local ch = Channels.new()
		ch:declareExternal("core.power_pctFP", 100)
		ch:declareExternal("primary.flowFraction", 1)
		ch:declareExternal("pools.mixedCoreOutletMeasured_K", 545 + KEL) -- cold: withdraw
		ch:declareExternal("protection.rodWithdrawalBlock", false)
		ch:declareExternal("protection.runback", "")
		ch:declareExternal("protection.scram", "none")
		ch:declareExternal("protection.rodRunback", false)
		ch:declareExternal("protection.runbackTarget_pctFP", 100)
		local auto = System.new(AutoControls)
		local rods = System.new(RodDrives)
		local log = EventLog.new(Config, { sim = 0, grid = 0 })
		local bus = Bus.new()
		rods:init({ config = Config, channels = ch:port(RodDrives.spec), log = log, bus = bus })
		auto:init({ config = Config, channels = ch:port(AutoControls.spec), log = log, bus = bus })
		auto:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		-- put the regulating rods in the middle of their band to start from
		for _, drive in rods.drives do
			if drive.set == "RR" then
				drive.position_mm = 500
				drive.demand_mm = 500
			end
		end
		rods:publish()

		local function advance(seconds: number)
			for _ = 1, math.floor(seconds / DT + 0.5) do
				auto:step(DT)
				rods:step(DT)
			end
		end
		advance(4) -- the move is about 50 mm at 5 mm/s, so still under way
		local moved = 0
		for _, d in rods:getState().drives do
			if d.set == "RR" and d.position_mm > 500 then
				moved += 1
			end
		end
		t.eq(moved, 1, "§3.4: exactly one regulating rod is moving")
		t.eq(rods:getState().selection, ch:get("auto.rodSelected"), "and it is the one the auto asked for")
		-- §3.4's 5 mm/s for a single regulating rod
		local pos = rods.drives[rods:indexOf(ch:get("auto.rodSelected"))].position_mm
		t.near(pos, 500 + 4 * Config.Rods.regulating.speed_mmps, 1, "at the §3.4 single-rod speed")

		-- switched to manual, the auto lets go, and the drive stops where it stands
		auto:applyCommand(OPERATOR, { kind = "auto.rod", value = 0 })
		advance(1)
		t.eq(ch:get("auto.rodSelected"), "", "auto releases")
		local stopped = rods.drives[rods:indexOf("RR1")].position_mm
		advance(5)
		t.near(rods.drives[rods:indexOf("RR1")].position_mm, stopped, 1e-9, "and the rod stops")
		t.eq(rods:getState().selection, nil, "leaving the drives free for an operator")
	end,

	["PrimaryPumps takes the flow auto's demand, and holds its survivors at 105 % after a trip first (§4.2)"] = function(t)
		local PrimaryPumps = require(Systems:WaitForChild("PrimaryPumps")) :: any
		local ch = Channels.new()
		ch:declareExternal("core.power_pctFP", 100)
		ch:declareExternal("pools.coverGas_MPa", Config.Primary.coverGas.setpoint_MPa)
		ch:declareExternal("pools.coldPool_K", Config.Feedback.referenceTemperature_K)
		ch:declareExternal("auto.flowOn", true)
		ch:declareExternal("auto.pumpSpeedDemand_pct", 60)
		local pumps = System.new(PrimaryPumps)
		pumps:init({
			config = Config,
			channels = ch:port(PrimaryPumps.spec),
			log = EventLog.new(Config, { sim = 0, grid = 0 }),
			bus = Bus.new(),
		})
		for _ = 1, 400 do
			pumps:step(DT)
		end
		local s = pumps:getState()
		t.near(s.pumps[1].speed_pct, 60, 0.5, "the pumps follow the auto's demand")
		t.near(s.flowFraction, 0.6, 0.01, "so flow is 60 %")

		--[[
			§9.4: it ignores a pump trip. Its demand does not rise to make up the lost flow. §4.2's drives do answer the
			trip: they hold the survivors at 105 % for D-046's hold (no RB-2 runs here, so its minimum), and then
			flow auto has them back at its unchanged demand, each way at §4.2's 2 %/s.
		]]
		pumps:tripPump(3, "test")
		local P = Config.Primary.pumps
		local top, hold = P.speedRange_pct[2], Config.Primary.survivorHold.minimum_s
		local ramp = (top - 60) / P.maxRamp_pctps
		for _ = 1, math.floor((ramp + 1) / DT + 0.5) do
			pumps:step(DT)
		end
		t.near(pumps:getState().pumps[1].speed_pct, top, 1e-9, `the drives hold the survivors at {top} % (§4.2)`)
		for _ = 1, math.floor((hold - (ramp + 1) + ramp + 1) / DT + 0.5) do
			pumps:step(DT)
		end
		local after = pumps:getState()
		t.near(after.pumps[1].speed_pct, 60, 0.5, "after the hold the survivors are back on flow auto's demand")
		t.ok(after.flowFraction < 0.45, "so the plant simply has less flow, which is the stated weakness")
		t.log(string.format("one pump lost under flow auto: flow %.0f %% of rated, and the demand still reads %.0f %%",
			after.flowFraction * 100, after.pumps[1].speed_pct))
	end,
}
