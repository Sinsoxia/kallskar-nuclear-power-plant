--!strict
--[[
	The command path end to end (spec §10.6, §10.7, §14.4).

	A player's control action arrives as a plain table through a RemoteFunction, and Commands.submit is what turns
	it into the Command a system's handler reads. The unit specs call applyCommand directly with a table they built
	themselves, so they cannot show that the two agree. This spec sends raw client tables through submit into the
	real plant, wired the way Main wires it.
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
local Commands = require(Framework:WaitForChild("Commands")) :: any

local PANEL = "MCR-RO-1"
local PLAYER = { kind = "player" :: any, name = "Tester", userId = 42, player = {} :: any }

-- The whole M1 plant as Main registers it, with Main's external inputs
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
	for _, class in require(Root:WaitForChild("Systems")) :: any do
		registry:add(System.new(class))
	end
	registry:resolve()
	local log = EventLog.new(Config, { sim = 0, grid = 0 })
	local bus = Bus.new()
	registry:initAll({ config = Config, log = log, bus = bus })
	local byName = {}
	for _, sys in registry.systems do
		byName[sys.spec.name] = sys
	end
	return registry, byName, log, bus
end

--[[
	Commands as Main builds it, with the three services M1 has no instances for yet filled in: one panel, a player
	standing beside it, and enough playtime for the critical controls.
]]
local function intake(registry: any, log: any, bus: any, hours: number?)
	return Commands.new({
		config = Config,
		registry = registry,
		log = log,
		bus = bus,
		panelPosition = function(tag: string): Vector3?
			return if tag == PANEL then Vector3.zero else nil
		end,
		characterPosition = function(_player: Player): Vector3?
			return Vector3.new(1, 0, 0)
		end,
		playtimeHours = function(_player: Player): number?
			return hours or Config.Access.criticalMinimumPlaytime_h + 1
		end,
		now = function()
			return 0
		end,
	})
end

return {
	["a client's rod, pump, exchanger, loop and bypass commands reach the systems that own them"] = function(t)
		local registry, byName, log, bus = plant()
		local commands = intake(registry, log, bus)
		local function send(raw: any): any
			return commands:submit(PLAYER, raw)
		end

		local r = send({ kind = "rod.move", target = "RR1", value = 600, panel = PANEL })
		t.ok(r.ok, `rod.move refused: {r.reason}`)
		local rods = byName.RodDrives
		t.eq(rods.selection and rods.selection.id, "RR1", "RodDrives is moving the rod the client named")
		t.eq(rods.drives[1].demand_mm, 600, "toward the position the client asked for")

		r = send({ kind = "pump.speed", target = "PP1", value = 60, panel = PANEL })
		t.ok(r.ok, `pump.speed refused: {r.reason}`)
		t.eq(byName.PrimaryPumps.pumps[1].demand_pct, 60, "PP1 takes the speed demand")

		r = send({ kind = "ihx.shutter", target = "1A", value = 0, panel = PANEL })
		t.ok(r.ok, `ihx.shutter refused: {r.reason}`)
		t.eq(byName.IHX.units[1].demand, Config.Primary.ihx.shutterLeakBy_frac, "1A's shutter heads for its leak-by")

		r = send({ kind = "loop.stop", target = "2", panel = PANEL })
		t.ok(r.ok, `loop.stop refused: {r.reason}`)
		t.eq(byName.IHX.loops[2].running, false, "secondary loop 2 stopped")

		r = send({ kind = "pss.bypass", target = "COVER-GAS", value = 1, panel = PANEL })
		t.ok(r.ok, `pss.bypass refused: {r.reason}`)
		t.eq(byName.Protection.bypassed["COVER-GAS"], true, "the cover gas trip is bypassed")

		-- the sequence-of-events log names the player and what they operated (§10.7)
		local last = log:latest(1)[1]
		t.eq(last.actor, "Tester")
		t.eq(last.target, "COVER-GAS")
	end,

	["a client's runback runs the runback it names, and the client can clear it (§9.5)"] = function(t)
		local registry, byName, log, bus = plant()
		local commands = intake(registry, log, bus)
		local announced: any = nil
		bus:subscribe("Runback", function(r)
			announced = r
		end)
		local r = commands:submit(PLAYER, { kind = "runback.start", target = "RB2", panel = PANEL })
		t.ok(r.ok, `runback.start refused: {r.reason}`)
		local running = byName.Protection:getState().runback
		t.eq(running and running.id, "RB2", "Protection is running the runback the client named")
		t.eq(running.target, Config.Protection.runbacks.RB2.target_pctFP, "to that runback's depth")
		t.eq(announced and announced.id, "RB2", "and announces it on the Bus")

		r = commands:submit(PLAYER, { kind = "runback.clear", panel = PANEL })
		t.ok(r.ok, `runback.clear refused: {r.reason}`)
		t.eq(byName.Protection:getState().runback, nil, "the client's clear ends it")
	end,

	["bypassing a trip and clearing a runback need the critical-control playtime (D-055)"] = function(t)
		local registry, byName, log, bus = plant()
		local commands = intake(registry, log, bus, Config.Access.criticalMinimumPlaytime_h - 0.5)
		for _, raw in {
			{ kind = "pss.bypass", target = "COVER-GAS", value = 1, panel = PANEL },
			{ kind = "runback.clear", panel = PANEL },
		} do
			local r = commands:submit(PLAYER, raw)
			t.ok(not r.ok and string.find(r.reason or "", "playtime", 1, true) ~= nil, `{raw.kind} needs the playtime ({r.reason})`)
		end
		t.eq(byName.Protection.bypassed["COVER-GAS"], nil, "so nothing was bypassed")
	end,

	["a client's backup control room trip is one button (§9.5)"] = function(t)
		local registry, byName, log, bus = plant()
		local commands = intake(registry, log, bus)
		local r = commands:submit(PLAYER, { kind = "reactor.trip.manual", target = "BCR", panel = PANEL })
		t.ok(r.ok, `reactor.trip.manual refused: {r.reason}`)
		local state = byName.Protection:getState()
		t.ok(state.tripped.PSS, "one press in the backup control room trips the reactor")
		t.eq(state.firstOut, "MANUAL")
	end,
}
