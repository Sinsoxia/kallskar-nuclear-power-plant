--!strict
--[[
	DebugPanelServer — the developer screen's server half (plan: Dev/DebugPanelServer).
	====================================================================================

	Studio only. This is scaffolding: §10.6's rule that screens never change plant state is about the in-game
	control rooms, and this panel is not one of them. It exists so a human can watch the plant run before the real
	panels are built, and it gets deleted when they are.

	It does not use the Replicator. That path packs numeric gauges into unreliable buffers for the real UI, which
	is the right design for hundreds of gauges at 5 Hz and the wrong one for a panel that wants strings, booleans
	and nested rod positions. A dev panel sends a plain table down its own remote instead, and nothing in the
	production replication contract bends to accommodate it.

	**The preset.** A plant that boots in Mode 3 with every rod in is correct (D-024) and shows nothing: power sits
	at 10⁻⁸ %FP and a real startup climbs ten decades over hours. So on request the panel seats the whole plant in
	steady state at a watchable power (Systems/InitialConditions) and puts both §9.4 autos in. Everything after
	that is the plant's own doing — including following the steam plant's load when the panel changes it.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InitialConditions = require(script.Parent.Parent.Systems.InitialConditions)

local DebugPanelServer = {}
DebugPanelServer.__index = DebugPanelServer

local FOLDER = "KallskarDev"
local KELVIN = 273.15

local function remotes(): (RemoteEvent, RemoteEvent)
	local folder = ReplicatedStorage:FindFirstChild(FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER
		folder.Parent = ReplicatedStorage
	end
	local function ensure(name: string): RemoteEvent
		local r = folder:FindFirstChild(name)
		if not r then
			r = Instance.new("RemoteEvent")
			r.Name = name
			r.Parent = folder
		end
		return r :: RemoteEvent
	end
	return ensure("Snapshot"), ensure("Action")
end

function DebugPanelServer.new(opts: { registry: any, channels: any, config: any, log: any, clock: any, commands: any? })
	local self = setmetatable({}, DebugPanelServer)
	self.registry = opts.registry
	self.channels = opts.channels
	self.config = opts.config
	self.log = opts.log
	self.clock = opts.clock
	self.commands = opts.commands
	self.snapshot, self.action = remotes()
	self.accumulator = 0
	self.period = 0.2 -- 5 Hz, the same cadence §14.1 gives the real gauges

	self.systems = {}
	for _, sys in self.registry.systems do
		self.systems[sys.spec.name] = sys
	end

	self.action.OnServerEvent:Connect(function(player, kind, arg)
		self:onAction(player, kind, arg)
	end)
	Players.PlayerAdded:Connect(function()
		self.accumulator = self.period -- send the newcomer a frame promptly
	end)
	return self
end

-- Mean position of one rod set, which is what a panel wants rather than thirty individual numbers
local function meanPosition(rods: any, set: string): number
	local sum, n = 0, 0
	for _, drive in rods.drives do
		if drive.set == set or (set == "SM" and string.sub(drive.set, 1, 2) == "SM") then
			sum += drive.position_mm
			n += 1
		end
	end
	return if n > 0 then sum / n else 0
end

function DebugPanelServer.build(self: any): { [string]: any }
	local ch = self.channels
	local function g(name: string, fallback: any): any
		local v = ch:get(name)
		return if v == nil then fallback else v
	end
	local rods = self.systems.RodDrives
	local core = self.systems.Core
	local feedback = if core then core.pk:breakdown_pcm() else {}

	local alarms = {}
	for _, id in g("protection.active", {}) do
		table.insert(alarms, id)
	end
	local inhibited = {}
	for _, text in g("protection.inhibited", {}) do
		table.insert(inhibited, text)
	end

	return {
		t = self.clock.sim,
		mode = g("program.mode", 0),
		-- reactor
		power = g("core.power_pctFP", 0),
		mwt = g("core.thermalPower_W", 0) / 1e6,
		rho = g("core.rho_pcm", 0),
		k = g("core.k", 0),
		period = g("detectors.periodMedian_s", 0),
		promptCritical = g("core.promptCritical", false),
		feedback = {
			doppler = feedback.doppler or 0,
			axial = feedback.fuelAxialExpansion or 0,
			sodium = feedback.sodiumDensity or 0,
			pads = feedback.loadPads or 0,
			drivelines = feedback.drivelines or 0,
			diagrid = feedback.diagrid or 0,
			vessel = feedback.vessel or 0,
		},
		-- thermal
		fuel = g("fuel.coreAverage_K", 0) - KELVIN,
		clad = g("fuel.cladHotSpot_K", 0) - KELVIN,
		centre = g("fuel.hotPinCentre_K", 0) - KELVIN,
		outlet = g("pools.mixedCoreOutlet_K", 0) - KELVIN,
		inlet = g("pools.coreInlet_K", 0) - KELVIN,
		hotPool = g("pools.hotPool_K", 0) - KELVIN,
		coldPool = g("pools.coldPool_K", 0) - KELVIN,
		coverGas = g("pools.coverGas_MPa", 0),
		-- flow and heat sink
		flow = g("primary.flowFraction", 0) * 100,
		pumps = g("primary.pumpsRunning", 0),
		pq = if g("primary.flowFraction", 0) > 1e-3 then (g("core.power_pctFP", 0) / 100) / g("primary.flowFraction", 1) else 0,
		ihx = g("ihx.heatRemoved_W", 0) / 1e6,
		loops = g("ihx.loopsRunning", 0),
		secondaryOut = (g("ihx.secondaryOutlet_K", { KELVIN }) :: { number })[1] - KELVIN, -- unit 1; all six match while the M1 secondary boundary is uniform
		secondaryIn = (g("ihx.secondaryInlet_K", { KELVIN }) :: { number })[1] - KELVIN,
		load = g("ihx.sinkLoad_pct", 0),
		loadDemand = g("ihx.sinkLoadDemand_pct", 0),
		-- rods
		rr = if rods then meanPosition(rods, "RR") else 0,
		sm = if rods then meanPosition(rods, "SM") else 0,
		ssr = if rods then meanPosition(rods, "SSR") else 0,
		worth = g("rods.indicativeWorth_pcm", 0),
		selection = g("rods.selection", ""),
		rodRate = g("rods.withdrawalRate_pcmps", 0),
		-- instruments
		sr = g("detectors.srMedian_cps", 0),
		srOn = g("detectors.srEnergised", false),
		wr = g("detectors.wrMedian_pctFP", 0),
		pr = g("detectors.prMean_pctFP", 0),
		dnd = g("detectors.dndMedian_cps", 0),
		oneOverM = g("detectors.oneOverM", 1),
		fluxRate = g("detectors.fluxRate_pctFPps", 0),
		-- protection and control
		scram = g("protection.scram", "none"),
		firstOut = g("protection.firstOut", ""),
		block = g("protection.rodWithdrawalBlock", false),
		runback = g("protection.runback", ""),
		alarms = alarms,
		inhibited = inhibited,
		autoRod = g("auto.rodOn", false),
		autoFlow = g("auto.flowOn", false),
		setpoint = g("auto.coreOutletSetpoint_C", 0),
		rodBand = g("auto.rodOutOfBand", false),
	}
end

function DebugPanelServer.step(self: any, dt: number)
	self.accumulator += dt
	if self.accumulator < self.period then
		return
	end
	self.accumulator = 0
	self.snapshot:FireAllClients(self:build())
end

local DEV = { kind = "dev" :: any, name = "DebugPanel", userId = 0 }

--[[
	Seat the whole plant in steady state at a power, then put both autos in. The seat is an initial condition,
	never a drive: moving rods that far in one tick is a step §9.5 trips on, and rightly so.
]]
function DebugPanelServer.preset(self: any, power_pctFP: number): (boolean, string?)
	local seated, why = InitialConditions.seatAtPower(self.systems, self.channels, self.config, power_pctFP)
	if not seated then
		if self.log then
			self.log:record("dev.preset", DEV, "plant", why, "refused")
		end
		return false, why
	end
	local auto = self.systems.AutoControls
	if auto then
		auto:applyCommand(DEV, { kind = "auto.rod", value = 1 })
		auto:applyCommand(DEV, { kind = "auto.flow", value = 1 })
	end
	if self.log then
		self.log:record("dev.preset", DEV, "plant", string.format(
			"%.0f %%FP on %.0f %% flow, feedback %.0f pcm against %.0f pcm of rods, Mode %d, autos in",
			seated.power_pctFP, seated.flow_pct, seated.feedback_pcm, seated.worth_pcm, seated.mode), "seated")
	end
	return true
end

function DebugPanelServer.onAction(self: any, player: Player, kind: string, arg: any)
	local protection, rods, auto = self.systems.Protection, self.systems.RodDrives, self.systems.AutoControls
	if kind == "preset" then
		self:preset(tonumber(arg) or 20)
	elseif kind == "scram" and protection then
		protection:applyCommand(DEV, { kind = "reactor.trip.manual", tag = "BCR" })
	elseif kind == "reset" and protection then
		if protection:applyCommand(DEV, { kind = "reactor.trip.reset" }).ok then
			if rods then
				rods:applyCommand(DEV, { kind = "rod.reset" })
			end
			-- every rod is in after a scram, so the panel, standing in for the crew, declares hot standby (§9.1)
			self.channels:setExternal("program.mode", 3)
		end
	elseif kind == "load" then
		-- nudge the steam plant's load demand; the load itself then ramps at §7.1's and LCO-10's rates
		local ihx = self.systems.IHX
		if ihx then
			local demand = math.clamp(ihx.loadDemand + (tonumber(arg) or 0), 0, 100)
			ihx:applyCommand(DEV, { kind = "sink.load", value = demand })
		end
	elseif kind == "autoRod" and auto then
		auto:applyCommand(DEV, { kind = "auto.rod", value = if arg then 1 else 0 })
	elseif kind == "autoFlow" and auto then
		auto:applyCommand(DEV, { kind = "auto.flow", value = if arg then 1 else 0 })
	elseif kind == "rod" and rods then
		-- nudge one regulating rod, at its own §3.4 speed, through the same interlocks as any other move
		local target = math.clamp((rods.drives[1].position_mm) + (tonumber(arg) or 0), 0, 1100)
		rods:applyCommand(DEV, { kind = "rod.move", tag = "RR1", value = target })
	elseif kind == "pumpTrip" then
		local pumps = self.systems.PrimaryPumps
		if pumps then
			pumps:tripPump(tonumber(arg) or 3, "debug panel", DEV)
		end
	end
end

return DebugPanelServer
