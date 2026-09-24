--!strict
--[[
	The system contract (spec §14.7): a system reads what it declares it reads.

	The Registry orders each lane from the declared reads, and a Port refuses a read that was not declared, so an
	undeclared read cannot happen. The other direction can: a declaration nothing uses still adds an ordering edge,
	or claims a data dependency that is not there, and the review of the two drifts apart silently. This spec runs
	the whole plant through a session that reaches every branch a read sits behind, and checks each one was made.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local Registry = require(Framework:WaitForChild("Registry")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local Systems = Root:WaitForChild("Systems")
local InitialConditions = require(Systems:WaitForChild("InitialConditions")) :: any

local DT = 1 / Config.Clocks.fast_Hz
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

--[[
	The whole M1 plant as Main registers it, with every system's reads recorded. Each system's port is wrapped on the
	way in; the wrapper notes the channel name and hands the read to the real port, so nothing a system sees changes.
]]
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
	local seen: { [string]: { [string]: boolean } } = {}
	local basePort = channels.port
	channels.port = function(self: any, spec: any): any
		local port = basePort(self, spec)
		local reads = {}
		seen[spec.name] = reads
		return setmetatable({
			read = function(p: any, name: string): any
				reads[name] = true
				return port.read(p, name)
			end,
		}, { __index = port })
	end
	local registry = Registry.new(channels)
	for _, class in require(Systems) :: any do
		registry:add(System.new(class))
	end
	registry:resolve()
	registry:initAll({ config = Config, log = EventLog.new(Config, { sim = 0, grid = 0 }), bus = Bus.new() })
	local function advance(seconds: number)
		for i = 1, math.floor(seconds / DT + 0.5) do
			for _, sys in registry.order.fast do
				sys:step(DT)
			end
			if i % 100 == 0 then
				task.wait()
			end
		end
	end
	local byName = {}
	for _, sys in registry.systems do
		byName[sys.spec.name] = sys
	end
	return registry, channels, advance, byName, seen
end

return {
	["every channel a system declares, it reads (§14.7)"] = function(t)
		local registry, channels, advance, byName, seen = plant()
		-- hot standby: Mode 3 with the rods in, where §9.5's low-power rows and D-004's Mode 3 inhibit are evaluated
		advance(2)
		-- at power, with both autos in: the rows armed above 5 %FP, flow auto's demand and rod auto's inputs
		t.ok(InitialConditions.seatAtPower(byName, channels, Config, 20) ~= nil, "seated at 20 %FP")
		byName.AutoControls:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		byName.AutoControls:applyCommand(OPERATOR, { kind = "auto.flow", value = 1 })
		-- the load ramps ahead of the outlet, so rod auto has to choose a rod and withdraw it through RodDrives
		t.ok(byName.IHX:applyCommand(OPERATOR, { kind = "sink.load", value = 25 }).ok)
		advance(30)
		-- and a pump start, which is where the pumps read their start interlocks
		local pumps = byName.PrimaryPumps
		pumps:tripPump(3, "contract test")
		t.ok((pumps:startInterlocks()), "the start interlocks are satisfied")

		for _, sys in registry.systems do
			local reads = seen[sys.spec.name]
			for _, list in { sys.spec.reads, sys.spec.readsLagged } do
				for _, ch in list do
					t.ok(reads[ch], `{sys.spec.name} declares '{ch}' but never read it`)
				end
			end
		end
	end,
}
