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
	local sys = System.new(IHX)
	local bus = Bus.new()
	sys:init({
		config = Config,
		channels = ch:port(IHX.spec),
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
		t.near(s.total_MWt, Config.Units.ratedThermal_MWt, 30, "six of them carry the core")
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
		local design = make()
		design:step(DT)
		local d = design:getState().units[1]
		local half, _ = make({ flow = RATED / 2 })
		half:step(DT)
		local h = half:getState().units[1]
		t.ok(h.duty_MWt < d.duty_MWt, "half the flow carries less heat")
		t.ok(h.primaryOutlet_K < d.primaryOutlet_K,
			"but each kilogram spends twice as long against the same area, so it leaves colder")
		-- at the natural-circulation floor the exchanger stops being area-limited: the primary leaves at the
		-- secondary inlet temperature, whatever UA is
		local trickle = make({ flow = RATED * PRIMARY.naturalCirculation.coefficient_pct / 100 })
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
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.secondary.inlet", tag = "1",
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
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.stop", tag = "2" }).ok, "stop loop 2")
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
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.stop", tag = "2" }).ok, "stopping it twice is refused")
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.start", tag = "2" }).ok, "and it can be restarted")
	end,

	["the inlet shutter strokes in §4.3's 60 s and moves its flow to the others"] = function(t)
		local sys, ch = make()
		sys:step(DT)
		local before = sys:getState().units
		t.ok(sys:applyCommand(OPERATOR, { kind = "ihx.shutter", tag = "1A", value = 0 }).ok, "close 1A")
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
		t.ok(not sys:applyCommand(OPERATOR, { kind = "ihx.shutter", tag = "4A", value = 1 }).ok, "unknown unit")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "ihx.shutter", tag = "1A", value = 2 }).ok, "shutter is 0–1")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.secondary.inlet", tag = "4", value = 320 }).ok,
			"there are only three loops")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.secondary.inlet", tag = "1", value = 90 }).ok,
			"below sodium's freezing point")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "loop.secondary.flow", tag = "1", value = -1 }).ok,
			"flow cannot be negative")
		t.ok(sys:applyCommand(OPERATOR, { kind = "loop.secondary.flow", tag = "1", value = 0 }).ok,
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
}
