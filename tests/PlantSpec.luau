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
	return { channels = channels, registry = registry, scheduler = scheduler, bus = bus, log = log, byName = byName }
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

return {
	["RB-2 runs a full-power plant back to 60 %FP at 60 %/min and settles there (§9.5, D-046)"] = function(t)
		local p, target = runback(t, "RB2")
		settled(t, p, target, "RB2")
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
