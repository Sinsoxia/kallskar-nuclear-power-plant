--!strict
--[[
	AutoControls verification (spec §9.4, §9.2, D-003, D-006).

	§9.4's controllers are meant to be worse than a crew, so the weaknesses are tested as carefully as the
	behaviour: that flow auto's 10 s filter really does throw P/Q off on a fast change, that rod auto really does
	stop at the band rather than reaching for a shim, and that both track §9.2's programme rather than the flat
	numbers §9.4 quotes (D-003, finding F3).
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

local function make(power: number?, outlet_C: number?)
	local pctFP = power or 100
	local ch = Channels.new()
	ch:declareExternal("core.power_pctFP", pctFP)
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

return {
	["the setpoint follows §9.2's programme, not §9.4's flat 550 °C (D-003, F3)"] = function(t)
		for i, power in TABLE.power_pct do
			local flow = TABLE.flow_pct[i]
			local sys, ch = make(power)
			ch:setExternal("primary.flowFraction", flow / 100)
			run(sys, 1)
			t.near(ch:get("auto.coreOutletSetpoint_C"), TABLE.coreOutlet_C[i], 1.5,
				string.format("%d %%FP on %d %% flow", power, flow))
		end
		-- the rows that matter: below 40 %FP the programme is NOT 550, which is finding F3
		local low, lch = make(30)
		lch:setExternal("primary.flowFraction", 0.40)
		run(low, 1)
		t.near(lch:get("auto.coreOutletSetpoint_C"), 506, 1.5, "§9.2: 506 °C at 30 %FP, not 550")
		t.ok(lch:get("auto.coreOutletSetpoint_C") < 545, "a controller holding 550 here would fight the programme")
	end,

	["the flow programme follows §9.2, with its 40 % floor and D-007's ramp"] = function(t)
		local sys, ch = make(100)
		for i, power in TABLE.power_pct do
			ch:setExternal("core.power_pctFP", power)
			run(sys, 60) -- past the 10 s filter, so the demand is the programme rather than the lag
			t.near(ch:get("auto.flowProgram_pct"), TABLE.flow_pct[i], 1,
				string.format("%d %%FP asks for %d %% flow", power, TABLE.flow_pct[i]))
		end
		-- D-007: between 5 and 10 %FP the floor ramps from 25 % to 40 % rather than stepping
		ch:setExternal("core.power_pctFP", 7.5)
		run(sys, 60)
		t.near(ch:get("auto.flowProgram_pct"), 32.5, 0.5, "D-007: half way up the ramp")
	end,

	["flow auto's 10 s filter costs what §9.4 says, at the rates the plant can actually ramp"] = function(t)
		--[[
			An instantaneous step would drive P/Q to power_new / power_old and trip the plant outright — but rods
			move at no more than 4 pcm/s (§3.4), so power cannot step. The rate limit on the rods is what keeps this
			deliberately weak controller survivable, and the interesting question is what it costs at the rates the
			plant CAN ramp at. The flow lags power by τ × rate, so the excursion is (P + τ·rate) / P.
		]]
		local tau = PROGRAM.primaryFlowAuto.powerFilter_s
		local BLOCK = Config.Protection.pss.powerToFlow.alarm
		local TRIP = Config.Protection.pss.powerToFlow.trip

		local function rampFrom(start_pctFP: number, pctPerMin: number): number
			local sys, ch = make(start_pctFP)
			sys:applyCommand(OPERATOR, { kind = "auto.flow", value = 1 })
			run(sys, 60) -- settle on programme first
			local power, worst = start_pctFP, 0
			for _ = 1, 1200 do
				power = math.min(power + pctPerMin / 60 * DT, 100)
				ch:setExternal("core.power_pctFP", power)
				sys:step(DT)
				local flow = ch:get("auto.pumpSpeedDemand_pct") / 100
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
		t.ok(runbackRate > BLOCK, "§9.4's weakness has teeth: a 30 %/min change reaches the rod block")
		t.ok(runbackRate < TRIP, "though not the 1.12 trip")
		-- the lag itself, which is the whole of the stated weakness
		local predicted = (60 + tau * Config.Protection.runbacks.RB1.rate_pctpmin / 60) / 60
		t.near(runbackRate, predicted, 0.02, "the excursion is exactly the 10 s filter's lag")
	end,

	["rod auto holds the band and does nothing inside it (§9.4)"] = function(t)
		local sys, ch = make(100, 550)
		t.ok(sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 }).ok, "rod auto in")
		run(sys, 5)
		t.eq(ch:get("auto.rodSelected"), "", "on programme, so nothing moves")

		-- 1 K off is inside §9.4's ±2 K band
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 551 + KEL)
		run(sys, 5)
		t.eq(ch:get("auto.rodSelected"), "", "still nothing: 1 K is inside the band")

		-- 5 K hot: insert
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 555 + KEL)
		run(sys, 1)
		t.ok(ch:get("auto.rodSelected") ~= "", "too hot, so it acts")
		t.eq(ch:get("auto.rodDemand_mm"), BAND[1], "driving in, toward the bottom of the band")

		-- 5 K cold: withdraw
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 545 + KEL)
		run(sys, 1)
		t.eq(ch:get("auto.rodDemand_mm"), BAND[2], "and out again when it is cold")
	end,

	["rod auto moves one rod at a time, and keeps the three together (D-006, F6)"] = function(t)
		local sys, ch = make(100, 545) -- cold, so it withdraws
		sys:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		ch:setExternal("rods.position_mm", { 600, 400, 500 })
		run(sys, 1)
		t.eq(ch:get("auto.rodSelected"), "RR2", "withdrawing: it takes the most-inserted rod")

		ch:setExternal("pools.mixedCoreOutletMeasured_K", 555 + KEL) -- hot, so it inserts
		run(sys, 1)
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
		run(sys, 1)
		t.ok(ch:get("auto.rodSelected") ~= "", "but it may still bring power down")
		t.eq(ch:get("auto.rodDemand_mm"), BAND[1])
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
		advance(10)
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
		t.near(pos, 500 + 10 * Config.Rods.regulating.speed_mmps, 1, "at the §3.4 single-rod speed")

		-- once the plant is back on programme the auto lets go, and the drive stops where it stands
		ch:setExternal("pools.mixedCoreOutletMeasured_K", 550 + KEL)
		advance(1)
		t.eq(ch:get("auto.rodSelected"), "", "auto releases")
		local stopped = rods.drives[rods:indexOf("RR1")].position_mm
		advance(5)
		t.near(rods.drives[rods:indexOf("RR1")].position_mm, stopped, 1e-9, "and the rod stops")
		t.eq(rods:getState().selection, nil, "leaving the drives free for an operator")
	end,

	["PrimaryPumps takes the flow auto's demand, and ignores a pump trip as §9.4 says"] = function(t)
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

		-- §9.4: it ignores a pump trip. The demand does not rise to make up the lost flow.
		pumps:tripPump(3, "test")
		for _ = 1, 400 do
			pumps:step(DT)
		end
		local after = pumps:getState()
		t.near(after.pumps[1].speed_pct, 60, 0.5, "the survivors stay exactly where they were")
		t.ok(after.flowFraction < 0.45, "so the plant simply has less flow, which is the stated weakness")
		t.log(string.format("one pump lost under flow auto: flow %.0f %% of rated, and the demand still reads %.0f %%",
			after.flowFraction * 100, after.pumps[1].speed_pct))
	end,
}
