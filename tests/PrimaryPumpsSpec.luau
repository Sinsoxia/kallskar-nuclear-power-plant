--!strict
--[[
	PrimaryPumps verification (spec §4.2, as corrected in Rev A4).
	Expected values come straight from §4.2: 3,565 kg/s per pump at 100 % speed, the coastdown curve Q₀/(1 + t/10 s)
	with its stated 50 % at 10 s and 25 % at 30 s, the 2 %/s ramp limit, the 10 % pony speed, the start interlocks,
	and Q_nc = 3.5 % × (P/100 %FP)^⅓.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local PrimaryPumps = require(Root:WaitForChild("Systems"):WaitForChild("PrimaryPumps")) :: any

local P = Config.Primary.pumps
local DT = 1 / Config.Clocks.fast_Hz
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

local function make(power_pctFP: number?)
	local ch = Channels.new()
	-- natural circulation follows heat, so the floor reads thermal power (D-037)
	ch:declareExternal("core.thermalPower_pctFP", power_pctFP or 100)
	ch:declareExternal("pools.coverGas_MPa", Config.Primary.coverGas.setpoint_MPa)
	ch:declareExternal("pools.coldPool_K", Config.Feedback.referenceTemperature_K)
	ch:declareExternal("protection.runback", "")
	local sys = System.new(PrimaryPumps)
	local log = EventLog.new(Config, { sim = 0, grid = 0 })
	local bus = Bus.new()
	sys:init({ config = Config, channels = ch:port(PrimaryPumps.spec), log = log, bus = bus })
	return sys, ch, log, bus
end

local function run(sys: any, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
	end
end

return {
	["rated flow and pump heat at 100 % speed (§4.2)"] = function(t)
		local sys, ch = make()
		sys:step(DT)
		local s = sys:getState()
		t.eq(#s.pumps, 3, "three pumps")
		-- §4.2's 3,565 kg/s per pump is the rounded third of the 10,694 kg/s total; the total is authoritative (F30)
		t.near(s.pumps[1].flow_kgps, P.ratedFlowTotal_kgps / P.count, 1e-9, "per pump")
		t.near(s.pumps[1].flow_kgps, P.ratedFlowEach_kgps, 0.5, "within the rounding of §4.2's per-pump figure")
		t.near(s.totalFlow_kgps, P.ratedFlowTotal_kgps, 1e-9, "total")
		t.near(s.flowFraction, 1, 1e-12, "P/Q flow basis")
		t.near(ch:get("primary.pumpHeat_MWt"), P.pumpHeatToSodium_MWt, 1e-9, "pump heat at rated")
		t.eq(ch:get("primary.pumpsRunning"), 3)
	end,

	["speed ramp is limited to §4.2's 2 %/s"] = function(t)
		local sys = make()
		local res = sys:applyCommand(OPERATOR, { kind = "pump.speed", target = "PP1", value = 60 })
		t.ok(res.ok, res.reason)
		run(sys, 1)
		t.near(sys:getState().pumps[1].speed_pct, 100 - P.maxRamp_pctps, 1e-9, "one second of ramp")
		run(sys, 19)
		t.near(sys:getState().pumps[1].speed_pct, 60, 1e-9, "reaches demand after 20 s")
		run(sys, 5)
		t.near(sys:getState().pumps[1].speed_pct, 60, 1e-9, "and stops there")
	end,

	["on a pump trip the survivors ramp to 105 % and hold it while RB-2 runs, then let go (§4.2, D-046+)"] = function(t)
		local sys, ch = make()
		local top = P.speedRange_pct[2]
		-- RB-2 by command, with every pump running, is no pump trip: nothing to make up
		ch:setExternal("protection.runback", "RB2")
		run(sys, 1)
		t.eq(sys.pumps[1].demand_pct, 100, "no hold without a pump down")
		t.ok(sys:tripPump(3, "test"), "PP3 trips")
		run(sys, 1)
		for i = 1, 2 do
			t.near(sys.pumps[i].speed_pct, 100 + P.maxRamp_pctps, 1e-9, `PP{i} ramps at {P.maxRamp_pctps} %/s`)
		end
		run(sys, 2)
		for i = 1, 2 do
			t.near(sys.pumps[i].speed_pct, top, 1e-9, `PP{i} reaches {top} % and stops there`)
		end
		local r = sys:applyCommand(OPERATOR, { kind = "pump.speed", target = "PP1", value = 80 })
		t.ok(not r.ok, `an operator speed change waits for RB-2 ({r.reason})`)
		ch:setExternal("protection.runback", "")
		run(sys, 1)
		t.eq(sys.pumps[1].demand_pct, top, "with flow auto out the survivors stay where RB-2 left them")
		t.ok(sys:applyCommand(OPERATOR, { kind = "pump.speed", target = "PP1", value = 80 }).ok, "and the operator takes them")
	end,

	["coastdown follows Q₀/(1 + t/10 s)"] = function(t)
		local sys = make()
		sys:step(DT)
		local q0 = sys:getState().pumps[1].flow_kgps
		t.ok(sys:tripPump(1, "test"), "trip accepted")
		t.ok(not sys:tripPump(1, "test"), "a second trip of the same pump is refused")
		run(sys, 10)
		t.near(sys:getState().pumps[1].flow_kgps, 0.5 * q0, 1e-6, "50 % at 10 s")
		run(sys, 20)
		t.near(sys:getState().pumps[1].flow_kgps, 0.25 * q0, 1e-6, "25 % at 30 s")
		-- the other two are untouched, so the loop keeps (2 + 0.25)/3 of rated
		t.near(sys:getState().flowFraction, (2 + 0.25) / 3, 1e-6, "loop flow after one pump trips")
		t.eq(sys:getState().running, 2, "two pumps running")
	end,

	["pony motor holds 10 % speed under the coastdown"] = function(t)
		local sys = make()
		sys:step(DT)
		sys:tripPump(1, "test")
		local res = sys:applyCommand(OPERATOR, { kind = "pump.pony", target = "PP1", value = 1 })
		t.ok(res.ok, res.reason)
		run(sys, 600)
		t.near(sys:getState().pumps[1].flow_kgps, P.ratedFlowTotal_kgps / P.count * P.ponySpeed_pct / 100, 1e-6, "pony floor")
	end,

	["natural circulation is the floor with no pumps (§4.2, Rev A4)"] = function(t)
		local nc = Config.Primary.naturalCirculation
		for _, power in { 100, 10, 1 } do
			local sys = make(power)
			for i = 1, 3 do
				sys:tripPump(i, "test")
			end
			run(sys, 3600) -- long enough that the coastdown is far below the floor
			local expect = P.ratedFlowTotal_kgps * nc.coefficient_pct / 100 * (power / nc.referencePower_pctFP) ^ nc.exponent
			local s = sys:getState()
			t.near(s.totalFlow_kgps, expect, 1e-6, `natural circulation at {power} %FP`)
			if power == 100 then
				t.log(string.format("at 100 %%FP natural circulation is %.0f kg/s = %.2f %% of rated", expect, expect / P.ratedFlowTotal_kgps * 100))
				t.near(expect / P.ratedFlowTotal_kgps * 100, nc.coefficient_pct, 1e-9, "3.5 % at full power, not 16 %")
			end
		end
	end,

	["start interlocks follow §4.2"] = function(t)
		local sys, ch = make()
		sys:tripPump(1, "test")
		ch:setExternal("pools.coverGas_MPa", P.startInterlocks.coverGasMin_MPa - 0.001)
		local res = sys:applyCommand(OPERATOR, { kind = "pump.start", target = "PP1" })
		t.ok(not res.ok and string.find(res.reason :: string, "cover gas", 1, true), "cover gas blocks the start")
		ch:setExternal("pools.coverGas_MPa", P.startInterlocks.coverGasMin_MPa)
		ch:setExternal("pools.coldPool_K", P.startInterlocks.sodiumMin_C - 1 + 273.15)
		res = sys:applyCommand(OPERATOR, { kind = "pump.start", target = "PP1" })
		t.ok(not res.ok and string.find(res.reason :: string, "sodium", 1, true), "cold sodium blocks the start")
		ch:setExternal("pools.coldPool_K", P.startInterlocks.sodiumMin_C + 273.15)
		res = sys:applyCommand(OPERATOR, { kind = "pump.start", target = "PP1" })
		t.ok(res.ok, res.reason)
		t.near(sys:getState().pumps[1].demand_pct, P.speedRange_pct[1], 1e-9, "starts at the minimum speed")
		ch:setExternal("pools.coverGas_MPa", nil)
		sys:tripPump(1, "test")
		res = sys:applyCommand(OPERATOR, { kind = "pump.start", target = "PP1" })
		t.ok(not res.ok, "a missing interlock input refuses the start rather than assuming it is satisfied")
	end,

	["commands are validated"] = function(t)
		local sys = make()
		local cases = {
			{ { kind = "pump.speed", target = "PP9", value = 50 }, "unknown pump" },
			{ { kind = "pump.speed", target = "PP1", value = P.speedRange_pct[2] + 1 }, "above the range" },
			{ { kind = "pump.speed", target = "PP1", value = P.speedRange_pct[1] - 1 }, "below the range" },
			{ { kind = "pump.speed", target = "PP1", value = 0 / 0 }, "NaN" },
			{ { kind = "pump.speed", target = "PP1" }, "missing value" },
			{ { kind = "pump.pony", target = "PP1", value = 1 }, "pony while running" },
			{ { kind = "pump.fly", target = "PP1" }, "unsupported kind" },
		}
		for _, case in cases do
			local res = sys:applyCommand(OPERATOR, case[1] :: any)
			t.ok(not res.ok, `refused: {case[2]}`)
			t.ok(type(res.reason) == "string" and #res.reason > 0, `reason given for {case[2]}`)
		end
		local ok = sys:applyCommand(OPERATOR, { kind = "pump.speed", target = "PP2", value = 105 })
		t.ok(ok.ok, "105 % is inside the §4.2 range")
	end,

	["a pump trip is logged and published on the bus"] = function(t)
		local sys, _, log, bus = make()
		local seen = {}
		bus:subscribe("EquipmentTrip", function(payload)
			table.insert(seen, payload)
		end)
		sys:step(DT)
		local res = sys:applyCommand(OPERATOR, { kind = "pump.stop", target = "PP3" })
		t.ok(res.ok, res.reason)
		t.eq(#seen, 1, "one bus event")
		t.eq(seen[1].equipment, "PP3")
		t.eq(seen[1].running, 2, "running count after the stop")
		local latest = log:latest(1)[1]
		t.eq(latest.kind, "pump.stop")
		t.eq(latest.target, "PP3")
		t.eq(latest.actor, "Aqua", "the operator is recorded, not the plant")
		-- the fault route reaches the same place
		local fault = PrimaryPumps.faults[1]
		t.eq(fault.id, "PP-TRIP")
		fault.arm(sys, { pump = 2 })
		t.eq(sys:getState().running, 1, "two pumps stopped")
		t.eq(seen[2].reason, "fault PP-TRIP")
	end,
}
