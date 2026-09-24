--!strict
--[[
	The developer panel's server half (src/server/Dev/DebugPanelServer). Only its actions are tested, through
	onAction on a panel that has systems but no remotes: DebugPanelServer.new would create the KallskarDev remotes,
	which a live Studio server already owns, and would connect a second handler to them.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local Registry = require(Framework:WaitForChild("Registry")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local Scheduler = require(Framework:WaitForChild("Scheduler")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Systems = Root:WaitForChild("Systems")
local InitialConditions = require(Systems:WaitForChild("InitialConditions")) :: any
local DebugPanelServer = require(Root:WaitForChild("Dev"):WaitForChild("DebugPanelServer")) :: any

-- Every system as Main builds it, seated at 20 %FP so the shim banks stand clear of the bottom
local function seated(): (any, any)
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
	assert(InitialConditions.seatAtPower(byName, channels, Config, 20) ~= nil, "seated at 20 %FP")
	local panel = setmetatable({ systems = byName, channels = channels }, DebugPanelServer)
	return panel, byName.RodDrives
end

local function demands(rods: any, bank: string): { number }
	local out = {}
	for _, i in rods.banks[bank].members do
		table.insert(out, rods.drives[i].demand_mm)
	end
	return out
end

local function same(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for i, v in a do
		if v ~= b[i] then
			return false
		end
	end
	return true
end

return {
	["a shim button moves the selected bank, and only that bank, through RodDrives' own rod.bank command"] = function(t)
		local panel, rods = seated()
		t.eq(rods.selection, nil, "nothing is moving before the button")
		local at = rods.drives[rods.banks.B.members[1]].position_mm
		t.ok(at >= 50, `bank B stands clear of the bottom ({at} mm)`)
		local a0, c0 = demands(rods, "A"), demands(rods, "C")

		panel:onAction(nil, "bank", { bank = "B", delta = -50 })
		t.ok(rods.selection ~= nil and rods.selection.kind == "bank" and rods.selection.id == "B",
			"bank B is the one selection §3.4 allows")
		for _, d in demands(rods, "B") do
			t.eq(d, at - 50, "every rod in bank B is sent 50 mm in")
		end
		t.ok(same(demands(rods, "A"), a0), "bank A is not touched")
		t.ok(same(demands(rods, "C"), c0), "nor is bank C")

		-- a second press while B is still moving is refused by RodDrives, not by the panel (§3.4)
		panel:onAction(nil, "bank", { bank = "A", delta = -50 })
		t.eq(rods.selection.id, "B", "one bank at a time")
		t.ok(same(demands(rods, "A"), a0), "and bank A still is not touched")
	end,

	["the shim action ignores anything that is not a shim bank and a number of millimetres"] = function(t)
		local panel, rods = seated()
		for _, arg in {
			{ bank = "RR", delta = 50 }, -- the regulating rods are rod auto's, and are not a bank here
			{ bank = "SSR", delta = 50 },
			{ bank = "Z", delta = 50 },
			{ bank = "A", delta = "fifty" },
			{ bank = "A" },
			"A",
		} :: { any } do
			panel:onAction(nil, "bank", arg)
			t.eq(rods.selection, nil, `ignored: {typeof(arg) == "table" and tostring(arg.bank) or tostring(arg)}`)
		end
	end,
}
