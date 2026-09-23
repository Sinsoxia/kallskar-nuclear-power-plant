--!strict
--[[
	Kallskar server bootstrap.
	Builds the plant from Systems (the class list), resolves run order, wires the framework services, and drives
	everything from one Heartbeat connection in a fixed order: simulate → replicate → persist.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Kallskar")
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")

local Config = require(Shared:WaitForChild("Config")) :: any
local Remotes = require(Shared:WaitForChild("Net"):WaitForChild("Remotes"))
local System = require(Framework:WaitForChild("System"))
local Channels = require(Framework:WaitForChild("Channels"))
local Registry = require(Framework:WaitForChild("Registry"))
local Scheduler = require(Framework:WaitForChild("Scheduler"))
local Bus = require(Framework:WaitForChild("Bus"))
local EventLog = require(Framework:WaitForChild("EventLog"))
local Commands = require(Framework:WaitForChild("Commands"))
local Faults = require(Framework:WaitForChild("Faults"))
local Replicator = require(Framework:WaitForChild("Replicator"))
local Persistence = require(Framework:WaitForChild("Persistence"))
local SystemClasses = require(Root:WaitForChild("Systems")) :: { any }

local isStudio = RunService:IsStudio()
local isPrivate = game.PrivateServerId ~= "" and game.PrivateServerOwnerId ~= 0

-- Plant ----------------------------------------------------------------------------------------------------------
local channels = Channels.new()

--[[
	Inputs that belong to systems this milestone does not build. Declaring them here is what lets the Registry
	insist that every other read has a real writer: anything missing is a wiring error, not a shrug. Each sits at
	the value that keeps the plant quiet until something drives it — Mode 3 because that is where D-024 boots the
	rods, and no earthquake, no lost boards, a turbine bypass available and a hot pool on programme.
]]
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
for _, class in SystemClasses do
	registry:add(System.new(class))
end
registry:resolve()

local bus = Bus.new()
local scheduler = Scheduler.new(registry, Config, bus, nil)
local log = EventLog.new(Config, scheduler.clock)
scheduler.log = log

local ctx = {
	config = Config,
	bus = bus,
	log = log,
	clock = scheduler.clock,
	isStudio = isStudio,
	scheduler = scheduler,
}
registry:initAll(ctx)

local faults = Faults.new(registry, log, bus, function()
	return table.freeze(table.clone(channels.values))
end)

-- Persistence ----------------------------------------------------------------------------------------------------
local store = if isPrivate and not isStudio then Persistence.DataStoreBackend.new("Kallskar") else Persistence.MemoryStore.new()
local persistence = Persistence.new({
	config = Config,
	registry = registry,
	log = log,
	bus = bus,
	clock = scheduler.clock,
	store = store :: any,
	mode = if isPrivate then "private" else "public",
	key = `plant/{game.PrivateServerId}`,
	ownerUserId = game.PrivateServerOwnerId,
})
local okLoad, loadResult = pcall(persistence.load, persistence)
if not okLoad then
	-- Never silently start fresh over a save we couldn't read: stop the plant and say why.
	warn(`[Kallskar] could not load plant condition: {loadResult}`)
	scheduler.halted = `load failed: {loadResult}`
	log:record("load", nil, nil, tostring(loadResult), "error")
end

bus:subscribe("PlantReset", function()
	-- §14.6: hot standby at beginning of cycle with every component as new, and the framework's own state with it
	scheduler:restart()
	faults:forgetAll()
	channels:resetExternals()
	registry:initAll(ctx)
	log:record("plant.reinitialised", nil, nil, "hot standby, beginning of cycle", "ok")
end)

-- Network --------------------------------------------------------------------------------------------------------
local remotes = Remotes.server()

local function isDev(player: Player): boolean
	if isStudio then
		return true
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	return isPrivate and player.UserId == game.PrivateServerOwnerId
end

local commands = Commands.new({ config = Config, registry = registry, log = log, bus = bus })
commands:bindRemote(remotes.Command, isDev)

local replicator = Replicator.new({ config = Config, registry = registry, log = log, remotes = remotes })
replicator:buildManifest()
Players.PlayerAdded:Connect(function(player)
	replicator:sendManifestTo(player)
	log:record("player.joined", { kind = "player", name = player.Name, userId = player.UserId }, nil, nil, "info")
end)
for _, player in Players:GetPlayers() do
	replicator:sendManifestTo(player)
end
Players.PlayerRemoving:Connect(function(player)
	log:record("player.left", { kind = "player", name = player.Name, userId = player.UserId }, nil, nil, "info")
end)

--[[
	The plant snapshot (plan: Telemetry/PlantSnapshot): the plant's state as one table at 5 Hz, on every server,
	for server-side consumers — the developer panel in Studio and the website telemetry everywhere.
]]
local PlantSnapshot = require(Root:WaitForChild("Telemetry"):WaitForChild("PlantSnapshot"))
local plantSnapshot = PlantSnapshot.new({ registry = registry, channels = channels, clock = scheduler.clock })

-- The developer panel (plan: Dev/DebugPanelServer). Studio only: its Action remote can seat and scram the plant.
local devPanel = nil
if isStudio then
	local DebugPanelServer = require(Root.Dev:WaitForChild("DebugPanelServer"))
	local panel = DebugPanelServer.new({
		registry = registry,
		channels = channels,
		config = Config,
		log = log,
		clock = scheduler.clock,
		commands = commands,
		plantSnapshot = plantSnapshot,
	})
	devPanel = panel
	log:record("dev.panel", nil, nil, "developer panel listening on KallskarDev", "info")
end

-- Main loop ------------------------------------------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt)
	scheduler:advance(dt)
	replicator:tick(dt)
	persistence:tick(dt)
	plantSnapshot:step(dt) -- after the plant, so a snapshot is always of a completed tick
end)

game:BindToClose(function()
	if persistence:enabled() and not scheduler.halted then
		persistence:save()
	end
end)

-- Expose the running plant to Studio-only tooling (dev panel, integration tests). Nothing reads this in live games.
if isStudio then
	shared.Kallskar = {
		registry = registry,
		channels = channels,
		scheduler = scheduler,
		bus = bus,
		log = log,
		commands = commands,
		faults = faults,
		replicator = replicator,
		persistence = persistence,
		devPanel = devPanel,
		plantSnapshot = plantSnapshot,
	}
end

log:record("server.started", nil, nil, `{#registry.systems} systems; {if isPrivate then "private" else "public"} server`, "info")
