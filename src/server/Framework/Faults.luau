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

-- The active faults and what each was armed with, in id order, for a save (D-053)
function Faults.export(self: any): { { id: string, params: any } }
	local out = {}
	for id, a in self.active do
		table.insert(out, { id = id, params = a.params })
	end
	table.sort(out, function(x, y)
		return x.id < y.id
	end)
	return out
end

--[[
	Mark saved faults active on a plant being loaded (D-053), with the params they were armed with, so they can be
	listed and cleared as before. A fault's arm is the event itself (a pump trips, a loop stops, a shutter drifts
	shut, a row is left bypassed), and the crew may have answered it before the save, so arm is not called again.
	What a fault leaves standing is its system's state, and comes back in that system's slice (the stopped pump, a
	frozen channel, a leak rate). A fault whose effect no slice could hold may give an optional
	restore(system, params); none needs one today. A fault this plant does not have is skipped and logged.
]]
function Faults.restore(self: any, saved: { { id: string, params: any } }?)
	if type(saved) ~= "table" then
		return
	end
	for _, s in saved do
		local entry = type(s) == "table" and self.registry.faultIndex[s.id]
		if not entry then
			self.log:record("fault.restore", nil, tostring(type(s) == "table" and s.id), "no such fault in this plant", "skipped")
		elseif not self.active[s.id] then
			local ok, err = true, nil
			if entry.fault.restore then
				ok, err = pcall(entry.fault.restore, entry.system, s.params)
			end
			if ok then
				self.active[s.id] = { params = s.params, armedAt = self.log.clock.sim }
				self.log:record("fault.restore", nil, s.id, entry.fault.label, "ok")
			else
				self.log:record("fault.restore", nil, s.id, tostring(err), "error")
			end
		end
	end
end

--[[
	Forget every active fault, for an owner reset (§14.6). The systems are re-initialised by the same reset, which
	puts their side of each fault back, so the faults' own clear() is not called; each is still logged and announced.
]]
function Faults.forgetAll(self: any, actor: Actor?)
	for id in self.active do
		local entry = self.registry.faultIndex[id]
		self.active[id] = nil
		self.log:record("fault.clear", actor, id, "plant reset", "ok")
		if self.bus and entry then
			self.bus:publish("FaultCleared", { id = id, system = entry.system.spec.name })
		end
	end
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
		-- with the params it was armed with: a fault that picked its target from them must clear that target
		local ok, err = pcall(entry.fault.clear, entry.system, self.active[id].params)
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
