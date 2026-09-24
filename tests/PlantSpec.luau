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
local Systems = Root:WaitForChild("Systems")
local InitialConditions = require(Systems:WaitForChild("InitialConditions")) :: any

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
	return { channels = channels, registry = registry, scheduler = scheduler, bus = bus, log = log, byName = byName }
end

-- Run whole fast ticks (and the slow lane with them), yielding now and then so a long run does not hog the thread
local function run(p: any, seconds: number, each: ((tick: number) -> ())?)
	for tick = 1, math.floor(seconds / DT + 0.5) do
		assert(p.scheduler:stepFast(), p.scheduler.halted)
		if each then
			each(tick)
		end
		if tick % 100 == 0 then
			task.wait()
		end
	end
end

return {
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
