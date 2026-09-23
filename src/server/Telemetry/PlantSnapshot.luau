--!strict
--[[
	PlantSnapshot — one plain table of the plant's state, five times a second, for consumers on the server
	(plan: Telemetry/PlantSnapshot).
	=======================================================================================================

	It runs on every server, Studio or live. It reads the channels and the systems and changes nothing. Two things
	consume it today:
	  - the developer panel (Dev/DebugPanelServer), Studio only, which forwards each snapshot to its clients
	  - KallskarWeb, Aqua's website telemetry script at the ServerScriptService root, outside the Rojo tree
	Both listen on ReplicatedStorage.KallskarDev.SnapshotServer, a BindableEvent. The folder keeps its "Dev" name
	because KallskarWeb waits for exactly that path. A BindableEvent never crosses the network, so a client can
	see this one but cannot fire it at the server.

	It lives apart from the dev panel for the same reason. The panel exists only in Studio, but the website needs
	snapshots from live servers. Before this split, a live server never made the folder, KallskarWeb's 30 s wait
	for it returned nil, and the script errored, taking the player-count telemetry down with it.

	This is not the production replication path. The Replicator packs gauges for the real UI; this is a plain
	table for tools that want strings, booleans and nested rod positions.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlantSnapshot = {}
PlantSnapshot.__index = PlantSnapshot

local FOLDER = "KallskarDev" -- KallskarWeb waits for this exact path
local EVENT = "SnapshotServer"
local KELVIN = 273.15

local function event(): BindableEvent
	local folder = ReplicatedStorage:FindFirstChild(FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER
		folder.Parent = ReplicatedStorage
	end
	local e = folder:FindFirstChild(EVENT)
	if not e then
		e = Instance.new("BindableEvent")
		e.Name = EVENT
		e.Parent = folder
	end
	return e :: BindableEvent
end

function PlantSnapshot.new(opts: { registry: any, channels: any, clock: any })
	local self = setmetatable({}, PlantSnapshot)
	self.channels = opts.channels
	self.clock = opts.clock
	self.event = event()
	self.accumulator = 0
	self.period = 0.2 -- 5 Hz, the same cadence §14.1 gives the real gauges
	self.systems = {}
	for _, sys in opts.registry.systems do
		self.systems[sys.spec.name] = sys
	end
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

function PlantSnapshot.build(self: any): { [string]: any }
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
		power = g("core.power_pctFP", 0), -- neutron (fission) power, what the instruments read
		mwt = g("core.thermalPower_W", 0) / 1e6, -- heat: prompt fission plus decay (D-037)
		thermal = g("core.thermalPower_pctFP", 0),
		decayMW = g("decay.heat_W", 0) / 1e6,
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

-- Publish at 5 Hz. Stepped after the plant in the same Heartbeat, so a snapshot is always of a completed tick.
function PlantSnapshot.step(self: any, dt: number)
	self.accumulator += dt
	if self.accumulator < self.period then
		return
	end
	self.accumulator = 0
	self.event:Fire(self:build())
end

-- Publish on the next step rather than waiting out the period, e.g. for a player who has just joined
function PlantSnapshot.soon(self: any)
	self.accumulator = self.period
end

return PlantSnapshot
