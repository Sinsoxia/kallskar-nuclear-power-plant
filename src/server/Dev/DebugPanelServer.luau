--!strict
--[[
	DebugPanelServer — the developer screen's server half (plan: Dev/DebugPanelServer).
	====================================================================================

	Studio only. This is scaffolding: §10.6's rule that screens never change plant state is about the in-game
	control rooms, and this panel is not one of them. It exists so a human can watch the plant run before the real
	panels are built, and it gets deleted when they are.

	It does not use the Replicator. It forwards Telemetry/PlantSnapshot's table to its clients on its own remote,
	so nothing in the production replication contract bends to accommodate it. The snapshot itself runs on every
	server, because the website telemetry needs it live; only this panel, whose Action remote can seat and scram
	the plant with no permission check, is confined to Studio.

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

function DebugPanelServer.new(opts: {
	registry: any,
	channels: any,
	config: any,
	log: any,
	clock: any,
	commands: any?,
	plantSnapshot: any,
})
	local self = setmetatable({}, DebugPanelServer)
	self.registry = opts.registry
	self.channels = opts.channels
	self.config = opts.config
	self.log = opts.log
	self.clock = opts.clock
	self.commands = opts.commands
	self.snapshot, self.action = remotes()

	self.systems = {}
	for _, sys in self.registry.systems do
		self.systems[sys.spec.name] = sys
	end

	-- every snapshot the plant publishes goes on to the panel's clients
	local plantSnapshot = opts.plantSnapshot
	plantSnapshot.event.Event:Connect(function(frame)
		self.snapshot:FireAllClients(frame)
	end)
	self.action.OnServerEvent:Connect(function(player, kind, arg)
		self:onAction(player, kind, arg)
	end)
	Players.PlayerAdded:Connect(function()
		plantSnapshot:soon() -- send the newcomer a frame promptly
	end)
	return self
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
		protection:applyCommand(DEV, { kind = "reactor.trip.manual", target = "BCR" })
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
		rods:applyCommand(DEV, { kind = "rod.move", target = "RR1", value = target })
	elseif kind == "pumpTrip" then
		local pumps = self.systems.PrimaryPumps
		if pumps then
			pumps:tripPump(tonumber(arg) or 3, "debug panel", DEV)
		end
	end
end

return DebugPanelServer
