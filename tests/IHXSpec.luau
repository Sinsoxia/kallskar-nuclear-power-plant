--!strict
--[[
	IHX verification (spec §4.3), including the primary loop closing on itself with Pools.

	§4.3 states five things about the same exchanger — 396 MWt, 550/375 °C primary, 320/520 °C secondary, LMTD 41 K
	and UA 9.6 MW/K — so the model is driven by UA alone and checked against the other four. The last test wires
	Pools and IHX together with nothing but the fuel-assembly outlet pinned at §2.5's 559 °C, and the loop finds
	§2.4's 550 °C hot pool and §4.3's 375 °C core inlet on its own.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Config = require(Kallskar:WaitForChild("Config")) :: any
local Sodium = require(Kallskar:WaitForChild("Props"):WaitForChild("Sodium")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local Systems = Root:WaitForChild("Systems")
local IHX = require(Systems:WaitForChild("IHX")) :: any
local Pools = require(Systems:WaitForChild("Pools")) :: any

local PRIMARY = Config.Primary
local SPEC = PRIMARY.ihx
local KEL = Config.Units.kelvinOffset_K
local RATED = PRIMARY.pumps.ratedFlowTotal_kgps
local DT = 1 / Config.Clocks.fast_Hz
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

local function make(opts: { [string]: any }?)
	local o = opts or {}
	local ch = Channels.new()
	ch:declareExternal("pools.hotPool_K", (o.hotPool_C or SPEC.primaryInlet_C) + KEL)
	ch:declareExternal("primary.coreFlow_kgps", o.flow or RATED)
	ch:declareExternal("protection.scram", "none")
	ch:declareExternal("protection.runback", "")
	ch:declareExternal("protection.runbackTarget_pctFP", 100)
	ch:declareExternal("protection.runbackRate_pctpmin", 0)
	ch:declareExternal("protection.runbackEnd", "")
	ch:declareExternal("primary.pumpHeat_MWt", if o.pumpHeat ~= nil then o.pumpHeat else PRIMARY.pumps.pumpHeatToSodium_MWt)
	local sys = System.new(IHX)
	local bus = Bus.new()
	sys:init({
		config = Config,
		channels = ch:port(IHX.spec),
		log = EventLog.new(Config, { sim = 0, grid = 0 }),
		bus = bus,
	})
	-- §4.3's figures are the full-load design point, so the heat sink is seated there unless a test says otherwise
	sys:setLoad(if o.load ~= nil then o.load else 100)
	return sys, ch, bus
end

local function run(sys: any, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
	end
end

-- Counter-flow log-mean temperature difference from the four temperatures, independent of how the model got them.
local function logMean(tpIn: number, tpOut: number, tsIn: number, tsOut: number): number
	local d1, d2 = tpIn - tsOut, tpOut - tsIn
	if math.abs(d1 - d2) < 1e-9 then
		return d1
	end
	return (d1 - d2) / math.log(d1 / d2)
end

return {
	["the design point reproduces every figure in §4.3"] = function(t)
		local sys, ch = make()
		sys:step(DT)
		local s = sys:getState()
		t.eq(#s.units, SPEC.count, "six units")
		t.eq(#s.loops, 3, "three secondary loops")
		local u = s.units[1]
		t.near(u.duty_MWt, SPEC.dutyAt100_MWt, 2, "§4.3: 396 MWt each at 100 %")
		t.near(u.primaryFlow_kgps, SPEC.primaryFlowEach_kgps, 1, "§4.3: 1,782 kg/s each")
		t.near(u.primaryOutlet_K - KEL, SPEC.primaryOutlet_C, 1, "§4.3: 375 °C primary out")
		t.near(u.secondaryOutlet_K - KEL, SPEC.secondaryOutlet_C, 1, "§4.3: 520 °C secondary out")
		t.near(u.lmtd_K, SPEC.lmtd_K, 0.5, "§4.3: LMTD ≈ 41 K")
		-- D-049: six times the 2 MW each unit is checked to above
		t.near(s.total_MWt, Config.Units.ratedThermal_MWt, 6 * 2, "six of them carry the core")
		t.near(ch:get("ihx.heatRemoved_W"), s.total_MWt * 1e6, 1e-6, "published duty matches state")
		t.eq(ch:get("ihx.loopsRunning"), 3)
		t.eq(ch:get("ihx.unitsInService"), 6)
		t.log(string.format("%.1f MWt each, primary %.1f → %.1f °C, secondary %.0f → %.1f °C, LMTD %.2f K",
			u.duty_MWt, SPEC.primaryInlet_C, u.primaryOutlet_K - KEL, SPEC.secondaryInlet_C,
			u.secondaryOutlet_K - KEL, u.lmtd_K))
	end,

	["the published LMTD is the log mean of the model's own four temperatures"] = function(t)
		local sys = make()
		sys:step(DT)
		local u = sys:getState().units[1]
		local independent = logMean(SPEC.primaryInlet_C + KEL, u.primaryOutlet_K,
			SPEC.secondaryInlet_C + KEL, u.secondaryOutlet_K)
		-- the system publishes Q/UA, which is the definition; the log form is the independent check
		t.near(u.lmtd_K, independent, independent * 1e-6, "Q/UA equals the log-mean form")
	end,

	["each unit's duty balances on both sides"] = function(t)
		local sys = make()
		sys:step(DT)
		local u = sys:getState().units[1]
		local tpIn = SPEC.primaryInlet_C + KEL
		local tsIn = SPEC.secondaryInlet_C + KEL
		local primary = u.primaryFlow_kgps * Sodium.specificHeat(0.5 * (tpIn + u.primaryOutlet_K))
			* (tpIn - u.primaryOutlet_K)
		local secondary = SPEC.secondaryFlowEach_kgps * Sodium.specificHeat(0.5 * (tsIn + u.secondaryOutlet_K))
			* (u.secondaryOutlet_K - tsIn)
		t.near(primary / 1e6, u.duty_MWt, u.duty_MWt * 1e-3, "primary side carries the duty")
		t.near(secondary / 1e6, u.duty_MWt, u.duty_MWt * 1e-3, "secondary side carries the same duty")
	end,

	["less primary flow means less duty but a colder primary outlet"] = function(t)
		--[[
			The exchanger's own physics, at §4.3's design secondary flow. The heat sink would otherwise bring the
			secondary down with the primary (D-032), so each loop's flow is held at design by override, which is
			the condition this test is about.
		]]
		local function atDesignSecondary(opts: { [string]: any }?)
			local sys = make(opts)
			for l = 1, 3 do
				sys:applyCommand(OPERATOR, { kind = "loop.secondary.flow", target = tostring(l), value = SPEC.secondaryFlowEach_kgps })
			end
			return sys
		end
		local design = atDesignSecondary()
		design:step(DT)
		local d = design:getState().units[1]
		local half = atDesignSecondary({ flow = RATED / 2 })
		half:step(DT)
		local h = half:getState().units[1]
		t.ok(h.duty_MWt < d.duty_MWt, "half the flow carries less heat")
		t.ok(h.primaryOutlet_K < d.primaryOutlet_K,
			"but each kilogram spends twice as long against the same area, so it leaves colder")
		-- at the natural-circulation floor the exchanger stops being area-limited: the primary leaves at the
		-- secondary inlet temperature, whatever UA is
		local trickle = atDesignSecondary({ flow = RATED * PRIMARY.naturalCirculation.coefficient_pct / 100 })
		trickle:step(DT)
		local n = trickle:getState().units[1]
		t.near(n.primaryOutlet_K - KEL, SPEC.secondaryInlet_C, 1, "natural circulation: thermodynamically limited")
		t.ok(n.duty_MWt > 0, "and it is still carrying heat")
		t.log(string.format("duty %.0f → %.0f → %.1f MWt and primary out %.0f → %.0f → %.0f °C at 100 / 50 / 3.5 %%",
			d.duty_MWt, h.duty_MWt, n.duty_MWt, d.primaryOutlet_K - KEL, h.primaryOutlet_K - KEL,
			n.primaryOutlet_K - KEL))
	end,

	["a warmer secondary inlet takes duty off its own two units only"] = function(t)
		local sys = make()
		sys:step(DT)
		local before = sys:getState().units
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.secondary.inlet", target = "1",
			value = SPEC.secondaryInlet_C + 10 }).ok, "raise loop 1's inlet by 10 K")
		sys:step(DT)
		local after = sys:getState().units
		-- ΔQ = ε·C_min·ΔT_in, and C_min is the secondary side here: ≈ 0.87 × 1.99 MW/K × 10 K
		local expected = 0.8677 * SPEC.secondaryFlowEach_kgps
			* Sodium.specificHeat(0.5 * (SPEC.secondaryInlet_C + SPEC.secondaryOutlet_C) + KEL) * 10 / 1e6
		t.near(before[1].duty_MWt - after[1].duty_MWt, expected, 1, "1A gives up ε·C_min·ΔT")
		t.near(before[2].duty_MWt - after[2].duty_MWt, expected, 1, "so does 1B")
		t.near(after[3].duty_MWt, before[3].duty_MWt, 1e-9, "2A is untouched")
		t.ok(after[1].primaryOutlet_K > before[1].primaryOutlet_K, "and 1A returns hotter sodium to the cold pool")
	end,

	["losing a secondary loop stops its two units and is announced"] = function(t)
		local sys, ch, bus = make()
		local seen = {}
		bus:subscribe("EquipmentTrip", function(payload)
			table.insert(seen, payload)
		end)
		sys:step(DT)
		local before = ch:get("ihx.heatRemoved_W")
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.stop", target = "2" }).ok, "stop loop 2")
		sys:step(DT)
		local s = sys:getState()
		t.near(s.units[3].duty_MWt, 0, 1e-12, "2A carries nothing without secondary flow")
		t.near(s.units[4].duty_MWt, 0, 1e-12, "nor does 2B")
		t.ok(s.units[1].duty_MWt > 0, "loop 1 is unaffected")
		t.eq(ch:get("ihx.loopsRunning"), 2, "§9.5 counts the running loops")
		t.eq(ch:get("ihx.unitsInService"), 4)
		t.ok(ch:get("ihx.heatRemoved_W") < before, "the plant is short of heat sink")
		t.eq(#seen, 1, "one EquipmentTrip")
		t.eq(seen[1].system, "IHX")
		t.eq(seen[1].running, 2)
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.stop", target = "2" }).ok, "stopping it twice is refused")
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.start", target = "2" }).ok, "and it can be restarted")
	end,

	["the inlet shutter strokes in §4.3's 60 s and moves its flow to the others"] = function(t)
		local sys, ch = make()
		sys:step(DT)
		local before = sys:getState().units
		t.ok(sys:applyCommand(OPERATOR, { kind = "ihx.shutter", target = "1A", value = 0 }).ok, "close 1A")
		run(sys, SPEC.shutterClose_s / 2)
		local mid = sys:getState().units[1]
		t.near(mid.shutter, 0.5 * (1 + SPEC.shutterLeakBy_frac), 1e-6, "half stroked at 30 s")
		run(sys, SPEC.shutterClose_s / 2)
		local s = sys:getState()
		t.near(s.units[1].shutter, SPEC.shutterLeakBy_frac, 1e-9, "§4.3: 5 % leak-by after 60 s")

		-- flow follows the shutters, and the pumps still deliver the same total
		local total = 0
		for _, u in s.units do
			total += u.primaryFlow_kgps
		end
		t.near(total, RATED, 1e-6, "total primary flow is conserved")
		local weight = SPEC.shutterLeakBy_frac + (SPEC.count - 1)
		t.near(s.units[1].primaryFlow_kgps, RATED * SPEC.shutterLeakBy_frac / weight, 1e-6, "1A is down to leak-by")
		t.ok(s.units[2].primaryFlow_kgps > before[2].primaryFlow_kgps, "the other five take up the flow")
		t.ok(s.units[1].duty_MWt < 0.2 * before[1].duty_MWt, "1A has stopped being a heat sink")
		t.ok(ch:get("ihx.unitsInService") == SPEC.count - 1, "and it is no longer counted in service")
	end,

	["faults: a lost loop and a shutter drifting closed"] = function(t)
		local sys, ch = make()
		local lost = IHX.faults[1]
		local shut = IHX.faults[2]
		t.eq(lost.id, "SL-LOST")
		t.eq(shut.id, "IHX-SHUT")
		lost.arm(sys, { loop = 3 })
		sys:step(DT)
		t.eq(ch:get("ihx.loopsRunning"), 2, "loop 3 is gone")
		t.near(sys:getState().units[5].duty_MWt, 0, 1e-12, "3A carries nothing")

		shut.arm(sys, { unit = 2 })
		run(sys, SPEC.shutterClose_s)
		t.near(sys:getState().units[2].shutter, SPEC.shutterLeakBy_frac, 1e-9, "1B has drifted shut")
		shut.clear(sys, { unit = 2 })
		run(sys, SPEC.shutterClose_s)
		t.near(sys:getState().units[2].shutter, 1, 1e-9, "and reopens when the fault is cleared")
	end,

	["commands are validated"] = function(t)
		local sys = make()
		t.ok(not sys:applyCommand(OPERATOR, { kind = "ihx.shutter", target = "4A", value = 1 }).ok, "unknown unit")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "ihx.shutter", target = "1A", value = 2 }).ok, "shutter is 0–1")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.secondary.inlet", target = "4", value = 320 }).ok,
			"there are only three loops")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.secondary.inlet", target = "1", value = 90 }).ok,
			"below sodium's freezing point")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.secondary.flow", target = "1", value = -1 }).ok,
			"flow cannot be negative")
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.secondary.flow", target = "1", value = 0 }).ok,
			"but zero is a stopped pump, which is allowed")
	end,

	["closed loop: Pools and IHX find §2.4's 550 °C and §4.3's 375 °C by themselves"] = function(t)
		--[[
			Nothing here imposes a duty or an inlet temperature. The fuel-assembly outlet is pinned at §2.5's
			559 °C, the pumps deliver rated flow and their 10 MWt, the secondary boundary sits at §4.3's 320 °C and
			1,556 kg/s per unit, and the two systems are stepped in registry order. Where the loop settles is the
			model's answer, not an input.
		]]
		local ch = Channels.new()
		ch:declareExternal("fuel.mixedOutlet_K", Config.Core.limits.assemblyOutletAverage_C + KEL)
		ch:declareExternal("fuel.heatToCoolant_W",
			Config.Core.powerSplit.fuelAssemblyCoolant * Config.Units.ratedThermal_MWt * 1e6)
		ch:declareExternal("primary.coreFlow_kgps", RATED)
		ch:declareExternal("primary.pumpHeat_MWt", PRIMARY.pumps.pumpHeatToSodium_MWt)
		local pools = System.new(Pools)
		local ihx = System.new(IHX)
		local ctx = { config = Config, log = EventLog.new(Config, { sim = 0, grid = 0 }), bus = Bus.new() }
		pools:init({ config = ctx.config, channels = ch:port(Pools.spec), log = ctx.log, bus = ctx.bus })
		ihx:init({ config = ctx.config, channels = ch:port(IHX.spec), log = ctx.log, bus = ctx.bus })
		ihx:setLoad(100)

		local function advance(seconds: number)
			for _ = 1, math.floor(seconds / DT + 0.5) do
				pools:step(DT) -- Pools writes pools.hotPool_K, IHX reads it; ihx.heatRemoved_W is the lagged edge
				ihx:step(DT)
			end
		end
		advance(2000)
		local mark = ch:get("pools.hotPool_K")
		advance(200)
		local p, i = pools:getState(), ihx:getState()
		t.near(ch:get("pools.hotPool_K"), mark, 0.01, "settled")
		t.near(p.hotPool_K - KEL, Config.Core.limits.mixedCoreOutlet_C, 1, "§2.4: 550 °C hot pool")
		t.near(p.coreInlet_K - KEL, SPEC.primaryOutlet_C, 1, "§4.3 and §2.5: 375 °C core inlet")
		t.near(i.units[1].secondaryOutlet_K - KEL, SPEC.secondaryOutlet_C, 1, "§4.3: 520 °C secondary out")
		t.near(i.total_MWt, Config.Units.ratedThermal_MWt + PRIMARY.pumps.pumpHeatToSodium_MWt, 25,
			"the IHXs carry the core and the pumps")
		-- the hot pool sits a fraction of a K above 550 because the 10 MWt of pump heat has to leave too
		t.ok(p.hotPool_K - KEL > Config.Core.limits.mixedCoreOutlet_C, "pump heat lifts it slightly above nominal")
		t.log(string.format("settled at hot pool %.2f °C, core inlet %.2f °C, %.0f MWt through the IHXs",
			p.hotPool_K - KEL, p.coreInlet_K - KEL, i.total_MWt))
	end,

	["the steam plant takes exactly its load at every row of §9.2, on the programme's own flow"] = function(t)
		--[[
			Each row's primary side, as §9.2 states it: the programme outlet in the hot pool on the programme flow.
			With the pumps' heat set to zero the load is the whole duty, so the IHXs must carry exactly it. The cold
			leg that does so is logged against the table's secondary column; the gap is F33.
		]]
		local tbl = Config.Program.partLoadTable
		local rated = Config.Units.ratedThermal_MWt
		for row, power in tbl.power_pct do
			local flow = tbl.flow_pct[row] / 100
			local sys = make({ load = power, pumpHeat = 0, flow = RATED * flow, hotPool_C = tbl.coreOutlet_C[row] })
			run(sys, 0.1)
			local s = sys:getState()
			-- the solve converges the cold leg to a nanokelvin, a part in 10¹¹ of a 100 K approach; 10⁻⁹ is headroom
			t.near(s.total_MWt, rated * power / 100, rated * power / 100 * 1e-9, `{power} %: takes {power} % of rated`)
			t.near(s.loops[1].flowEach_kgps / SPEC.secondaryFlowEach_kgps, flow, 1e-12,
				`{power} %: secondary flow follows the {tbl.flow_pct[row]} % primary column`)
			t.log(string.format("%3d %%: cold leg %.1f °C (§9.2 table %d °C, %+.1f K)", power, s.loops[1].inlet_C,
				tbl.secondaryCold_C[row], s.loops[1].inlet_C - tbl.secondaryCold_C[row]))
		end
	end,

	["the cold leg stays inside what the steam plant can give"] = function(t)
		local partLoad = Config.Program.partLoad
		-- a primary too cold to carry full load: the cold leg bottoms out at §9.2's 320 °C and carries what it can
		local cold = make({ load = 100, hotPool_C = 500 })
		run(cold, 0.1)
		t.near(cold:getState().loops[1].inlet_C, SPEC.secondaryInlet_C, 1e-9, "no colder than the full-load programme")
		t.ok(cold:getState().total_MWt < Config.Units.ratedThermal_MWt, "so the load is not met")
		-- no load and a plant above hot standby: the bypass pulls it back toward 375 °C
		local hot = make({ load = 0, hotPool_C = 390 })
		run(hot, 0.1)
		t.near(hot:getState().loops[1].inlet_C, partLoad.coreInlet_C, 1e-9, "no warmer than hot standby's 375 °C")
		t.ok(hot:getState().total_MWt > 0, "and it takes heat out of a pool above that")
		-- no load and a plant below hot standby: a steam generator cannot heat sodium
		local below = make({ load = 0, hotPool_C = 360 })
		run(below, 0.1)
		t.near(below:getState().loops[1].inlet_C, 360, 1e-9, "no warmer than the pool it faces")
		t.near(below:getState().total_MWt, 0, 1e-9, "so it neither takes heat nor gives it")
	end,

	["hot standby is not cooled: no load takes no heat out of a pool at its own temperature"] = function(t)
		-- The bug this pins: a boundary held at full-load conditions pulled 570 MWt out of a shut-down plant
		local sys = make({ load = 0, hotPool_C = Config.Program.partLoad.coreInlet_C })
		run(sys, 1)
		t.near(sys:getState().total_MWt, 0, 1e-9, "375 °C against 375 °C carries nothing")
	end,

	["a cleared runback ends the steam plant's runback too: the load holds, and later moves at LCO-10's rate (D-046)"] = function(t)
		local sys, ch = make({ load = 100 })
		local rb = Config.Protection.runbacks.RB2
		ch:setExternal("protection.runback", "RB2")
		ch:setExternal("protection.runbackTarget_pctFP", rb.target_pctFP)
		ch:setExternal("protection.runbackRate_pctpmin", rb.rate_pctpmin)
		run(sys, 10)
		local during = sys.sinkLoad
		t.near(during, 100 - rb.rate_pctpmin / 60 * 10, 1e-9, "RB-2 takes the load down at 60 %/min")

		-- the operator clears the runback part-way: Protection publishes no runback, and the load holds there
		ch:setExternal("protection.runback", "")
		ch:setExternal("protection.runbackTarget_pctFP", 100)
		ch:setExternal("protection.runbackRate_pctpmin", 0)
		ch:setExternal("protection.runbackEnd", "cleared")
		run(sys, 5)
		t.near(sys.sinkLoad, during, 1e-9, "the load holds where the cleared runback left it")
		t.near(sys:getState().sinkLoadDemand_pct, during, 1e-9, "with the demand there, for the operator to take")

		-- the operator raises it, then lowers it: both at LCO-10's 1 %/min above 40 %, never at the runback's rate
		t.ok(sys:applyCommand(OPERATOR, { kind = "sink.load", value = during + 5 }).ok)
		run(sys, 60)
		t.near(sys.sinkLoad, during + 1, 1e-9, "up a minute at 1 %/min")
		t.ok(sys:applyCommand(OPERATOR, { kind = "sink.load", value = rb.target_pctFP }).ok)
		run(sys, 60)
		t.near(sys.sinkLoad, during, 1e-9, "and down a minute at 1 %/min, not at RB-2's 60 %/min")
	end,

	["a completed runback's load finishes at the target at the runback's rate, and then lets go (D-046)"] = function(t)
		--[[
			Protection completes a runback when its demand reaches the target. The demand ramps from the noisy PR
			median and the load from the steam plant's own load, and the load reads Protection a tick late, so the load
			can still be a few ticks of the ramp above the target then. Studio caught it two ticks short (60.2 %),
			where the load used to freeze. It finishes at the runback's rate, and only then does the latch end.
		]]
		local sys, ch = make({ load = 100 })
		local rb = Config.Protection.runbacks.RB2
		local perTick = rb.rate_pctpmin / 60 * DT
		ch:setExternal("protection.runback", "RB2")
		ch:setExternal("protection.runbackTarget_pctFP", rb.target_pctFP)
		ch:setExternal("protection.runbackRate_pctpmin", rb.rate_pctpmin)
		local short = 2 -- ticks of the ramp still to go when Protection completes
		run(sys, (100 - rb.target_pctFP) / (rb.rate_pctpmin / 60) - short * DT)
		t.near(sys.sinkLoad, rb.target_pctFP + short * perTick, 1e-9, "two ticks of the ramp above the target")

		ch:setExternal("protection.runback", "")
		ch:setExternal("protection.runbackTarget_pctFP", 100)
		ch:setExternal("protection.runbackRate_pctpmin", 0)
		ch:setExternal("protection.runbackEnd", "complete")
		run(sys, DT)
		t.near(sys.sinkLoad, rb.target_pctFP + perTick, 1e-9, "the load carries on down at the runback's rate")
		run(sys, DT)
		t.near(sys.sinkLoad, rb.target_pctFP, 1e-9, "and reaches the target")
		run(sys, 1)
		t.near(sys.sinkLoad, rb.target_pctFP, 1e-9, "and stays there")

		-- the latch has ended: a later decrease runs at LCO-10's 1 %/min above 40 %, not at RB-2's rate
		t.ok(sys:applyCommand(OPERATOR, { kind = "sink.load", value = rb.target_pctFP - 5 }).ok)
		run(sys, 60)
		t.near(sys.sinkLoad, rb.target_pctFP - 1, 1e-9, "a minute later it is 1 % lower, not 5")
	end,

	["the load ramps at §7.1's 5 %/min, and at LCO-10's 1 %/min above 40 %"] = function(t)
		local sys = make({ load = 30 })
		t.ok(sys:applyCommand(OPERATOR, { kind = "sink.load", value = 50 }).ok, "ask for 50 %")
		run(sys, 60)
		t.near(sys:getState().sinkLoad_pct, 35, 1e-6, "a minute at 5 %/min")
		run(sys, 60)
		t.near(sys:getState().sinkLoad_pct, 40, 1e-6, "arriving at 40 % without carrying the fast rate over")
		run(sys, 60)
		t.near(sys:getState().sinkLoad_pct, 41, 1e-6, "then a minute at 1 %/min")
		t.ok(sys:applyCommand(OPERATOR, { kind = "sink.load", value = 30 }).ok, "and back down")
		run(sys, 60)
		t.near(sys:getState().sinkLoad_pct, 40, 1e-6, "1 %/min down to the limit")
		run(sys, 60)
		t.near(sys:getState().sinkLoad_pct, 35, 1e-6, "5 %/min below it")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "sink.load", value = 101 }).ok, "past rated is refused")
	end,

	["the steam plant's load does not hide the persistence load hook (§14.6)"] = function(t)
		local sys = make({ load = 40 })
		t.eq(sys.sinkLoad, 40, "the steam plant's load is held in sinkLoad")
		-- whether IHX keeps System's default hook or has its own, Persistence.load calls sys:load(slice, version)
		t.eq(type(sys.load), "function", "so IHX:load is still a method, not a number")
	end,

	["a reactor trip trips the turbines: the load goes to zero at once and stays there"] = function(t)
		local sys, ch = make({ load = 60 })
		run(sys, 1)
		ch:setExternal("protection.scram", "PSS")
		run(sys, 0.2)
		local s = sys:getState()
		t.near(s.sinkLoad_pct, 0, 1e-12, "no ramp: the turbines are off the line")
		t.near(s.loops[1].inlet_C, Config.Program.partLoad.coreInlet_C, 1e-9, "the cold leg is at hot standby")
		ch:setExternal("protection.scram", "none") -- reset
		run(sys, 60)
		t.near(sys:getState().sinkLoad_pct, 0, 1e-12, "and a reset does not bring the load back by itself")
	end,

	["secondary flow follows the primary flow the pumps deliver (D-032)"] = function(t)
		-- §9.2's table makes the two equal at every row; off the programme the heat sink keeps them together
		for _, fraction in { 1, 2 / 3, 0.4, PRIMARY.naturalCirculation.coefficient_pct / 100 } do
			local sys = make({ flow = RATED * fraction })
			run(sys, 0.1)
			for l, loop in sys:getState().loops do
				t.near(loop.flowEach_kgps, SPEC.secondaryFlowEach_kgps * fraction, 1e-9,
					string.format("loop %d on %.1f %% primary flow", l, fraction * 100))
			end
		end
	end,

	["an override holds one loop by hand until it is handed back to the programme"] = function(t)
		local sys = make()
		run(sys, 0.1)
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.secondary.inlet", target = "1", value = 330 }).ok, "hold loop 1 at 330 °C")
		local s = sys:getState()
		t.near(s.loops[1].inlet_C, 330, 1e-9, "loop 1 stays where it was put")
		-- the other two loops try to make up what loop 1 no longer carries, and bottom out at the programme
		t.near(s.loops[2].inlet_C, SPEC.secondaryInlet_C, 1e-9, "loop 2 is on the programme at full load")
		t.ok(s.loops[1].overridden and not s.loops[2].overridden, "and the state says which is which")
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.secondary.program", target = "1" }).ok, "hand loop 1 back")
		t.near(sys:getState().loops[1].inlet_C, SPEC.secondaryInlet_C, 1e-9, "it rejoins the programme at once")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.secondary.program", target = "1" }).ok,
			"handing back a loop that is not held is refused")
	end,
}
