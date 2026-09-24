--!strict
--[[
	The open-loop step responses the D-059 auto tuning is derived from (tools/derive/auto_tuning.py). The whole plant
	runs as Main builds it, with both autos out, and one actuator steps:
	  rod   RR1 withdrawn 20 mm at its drive speed, and the lagged outlet thermocouple (without its noise) recorded:
	        what rod auto sees, through the core's feedbacks, the pools and the thermocouple's §2.5 lag
	  flow  every pump's speed stepped down 5 %, and the flow and P/Q recorded: what flow auto sees
	Each response is logged as one line, "TUNING <case> <power> dt=<s> <values...>", every second, which the derivation
	parses from the harness report. The asserts only check that each step moved its signal the right way.
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
local Systems = Root:WaitForChild("Systems")
local InitialConditions = require(Systems:WaitForChild("InitialConditions")) :: any

local DT = 1 / Config.Clocks.fast_Hz
local KEL = 273.15
local AUTO = { kind = "auto" :: any, name = "TuningSpec", userId = 0 }
local SAMPLE_S = 1 -- one logged value a second
-- long enough for the rod to show its slow energy-balance mode (minutes); the flow settles within its 2 %/s ramp
local RECORD_ROD_S, RECORD_FLOW_S = 240, 10

-- Every system as Main builds it, seated at a power with both autos out and left 10 s to settle
local function seated(pct: number): any
	local channels = Channels.new()
	for name, initial in {
		["program.mode"] = 1,
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
	assert(InitialConditions.seatAtPower(byName, channels, Config, pct) ~= nil, `seated at {pct} %FP`)
	local p = { channels = channels, scheduler = scheduler, byName = byName }
	for _ = 1, math.floor(10 / DT + 0.5) do
		assert(scheduler:stepFast(), scheduler.halted)
	end
	return p
end

-- Run, sampling `read` every SAMPLE_S; returns the samples, the first taken before the first step
local function record(p: any, seconds: number, read: () -> number): { number }
	local out = { read() }
	local every = math.floor(SAMPLE_S / DT + 0.5)
	for tick = 1, math.floor(seconds / DT + 0.5) do
		assert(p.scheduler:stepFast(), p.scheduler.halted)
		if tick % every == 0 then
			table.insert(out, read())
		end
		if tick % 100 == 0 then
			task.wait()
		end
	end
	return out
end

local function line(case: string, pct: number, values: { number }): string
	local parts = table.create(#values)
	for i, v in values do
		parts[i] = string.format("%.5f", v)
	end
	return `TUNING {case} {pct} dt={SAMPLE_S} {table.concat(parts, " ")}`
end

local cases = {}
for _, pct in { 100, 60, 30 } do
	cases[`rod auto's plant at {pct} %FP: RR1 out 20 mm, the lagged outlet thermocouple recorded`] = function(t)
		local p = seated(pct)
		local rods, pools = p.byName.RodDrives, p.byName.Pools
		local rr1 = rods.drives[rods:indexOf("RR1")]
		t.ok(rods:applyCommand(AUTO, { kind = "rod.move", target = "RR1", value = rr1.position_mm + 20 }).ok, "RR1 moves")
		local samples = record(p, RECORD_ROD_S, function()
			return pools.measuredOutlet_K - KEL
		end)
		t.log(line("rod", pct, samples))
		t.ok(samples[#samples] > samples[1], "withdrawing a rod raises the outlet")
		t.eq(p.channels:get("protection.tripped"), false, "and trips nothing")
	end
	cases[`flow auto's plant at {pct} %FP: every pump 5 % slower, the flow recorded`] = function(t)
		local p = seated(pct)
		local pumps = p.byName.PrimaryPumps
		for _, pump in pumps.pumps do
			t.ok(pumps:applyCommand(AUTO, { kind = "pump.speed", target = pump.name, value = pump.speed_pct - 5 }).ok)
		end
		local samples = record(p, RECORD_FLOW_S, function()
			return p.channels:get("primary.flowFraction")
		end)
		t.log(line("flow", pct, samples))
		t.ok(samples[#samples] < samples[1], "slower pumps give less flow")
	end
end
return cases
