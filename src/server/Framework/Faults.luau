--!strict
--[[
	Faults — every failure the plant can be given (spec §13.1, §14.7).
	===================================================================
	Systems declare faults in their class (`Class.faults = { {id, label, cost, eligible?, arm, clear?}, ... }`); the
	Registry indexes them. This module arms and clears them and remembers which are active. The scenario director
	(later milestone) and the dev panel both come through here, so every fault start is logged and published, and
	the director never "cheats": arm() starts a real initiating event inside the owning system.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Types"))

type Actor = Types.Actor
type CommandResult = Types.CommandResult

local Faults = {}
Faults.__index = Faults

function Faults.new(registry: any, log: any, bus: any?, snapshot: (() -> any)?)
	local self = setmetatable({}, Faults)
	self.registry = registry
	self.log = log
	self.bus = bus
	self.snapshot = snapshot or function()
		return nil
	end
	self.active = {} :: { [string]: { params: any, armedAt: number } }
	return self
end

function Faults.list(self: any): { any }
	local out = {}
	for id, entry in self.registry.faultIndex do
		local f = entry.fault
		table.insert(out, {
			id = id,
			label = f.label,
			cost = f.cost,
			system = entry.system.spec.name,
			active = self.active[id] ~= nil,
		})
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function Faults.isActive(self: any, id: string): boolean
	return self.active[id] ~= nil
end

function Faults.arm(self: any, id: string, params: { [string]: any }?, actor: Actor?): CommandResult
	local entry = self.registry.faultIndex[id]
	if not entry then
		return { ok = false, reason = `unknown fault '{id}'` }
	end
	if self.active[id] then
		return { ok = false, reason = `fault '{id}' is already active` }
	end
	local f = entry.fault
	if f.eligible then
		local okE, eligible = pcall(f.eligible, self.snapshot())
		if not okE then
			return { ok = false, reason = `eligibility check failed: {tostring(eligible)}` }
		end
		if not eligible then
			return { ok = false, reason = `fault '{id}' is not eligible in the current plant state` }
		end
	end
	local ok, err = pcall(f.arm, entry.system, params)
	if not ok then
		self.log:record("fault.arm", actor, id, tostring(err), "error")
		return { ok = false, reason = `arming '{id}' failed: {tostring(err)}` }
	end
	self.active[id] = { params = params, armedAt = self.log.clock.sim }
	self.log:record("fault.arm", actor, id, f.label, "ok")
	if self.bus then
		self.bus:publish("FaultArmed", { id = id, system = entry.system.spec.name, params = params })
	end
	return { ok = true }
end

function Faults.clear(self: any, id: string, actor: Actor?): CommandResult
	local entry = self.registry.faultIndex[id]
	if not entry then
		return { ok = false, reason = `unknown fault '{id}'` }
	end
	if not self.active[id] then
		return { ok = false, reason = `fault '{id}' is not active` }
	end
	if entry.fault.clear then
		local ok, err = pcall(entry.fault.clear, entry.system)
		if not ok then
			self.log:record("fault.clear", actor, id, tostring(err), "error")
			return { ok = false, reason = `clearing '{id}' failed: {tostring(err)}` }
		end
	end
	self.active[id] = nil
	self.log:record("fault.clear", actor, id, nil, "ok")
	if self.bus then
		self.bus:publish("FaultCleared", { id = id, system = entry.system.spec.name })
	end
	return { ok = true }
end

return Faults
