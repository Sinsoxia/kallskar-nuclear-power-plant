--!strict
--[[
	Channels — the shared plant state that systems exchange.
	=========================================================

	A channel is a named value ("core.power_pctFP", "fuel.averageTemp_K") owned by exactly one writer system. Values
	are numbers, booleans, strings, or arrays owned by the writer (per-node fields such as fuel temperatures).
	Readers must treat arrays as read-only.

	Each system gets a Port bound to its own spec. A port refuses to read a channel the system didn't declare, or to
	write one it doesn't own. That makes the declared data-flow graph — which the Registry uses to order systems —
	something the code actually obeys, not just documentation. Port checks are a single hash lookup; systems should
	cache array references at init rather than calling read() inside inner loops.

	Channels with no system writer (inputs from the framework or dev tools) are declared with declareExternal.
]]

export type Port = {
	read: (self: Port, name: string) -> any,
	write: (self: Port, name: string, value: any) -> (),
	has: (self: Port, name: string) -> boolean,
}

local Channels = {}
Channels.__index = Channels

function Channels.new()
	local self = setmetatable({}, Channels)
	self.values = {} :: { [string]: any }
	self.owner = {} :: { [string]: string }
	self.externalInitial = {} :: { [string]: any } -- what each external input was declared with
	return self
end

local VALID_NAME = "^[%a][%w]*[%.%w_]*$"

function Channels.declare(self: any, name: string, ownerName: string, initial: any)
	assert(type(name) == "string" and string.match(name, VALID_NAME), `invalid channel name '{tostring(name)}'`)
	local existing = self.owner[name]
	if existing and existing ~= ownerName then
		error(`channel '{name}' is written by both {existing} and {ownerName}`, 2)
	end
	self.owner[name] = ownerName
	if initial ~= nil then
		self.values[name] = initial
	end
end

function Channels.declareExternal(self: any, name: string, initial: any)
	self:declare(name, "<external>", initial)
	self.externalInitial[name] = initial
end

-- Put every external input back to the value it was declared with (an owner reset, §14.6).
function Channels.resetExternals(self: any)
	for name, initial in self.externalInitial do
		self.values[name] = initial
	end
end

-- The external inputs' present values, for a save (D-053): the mode, and whatever else stands in for an unbuilt system
function Channels.exportExternals(self: any): { [string]: any }
	local out = {}
	for name in self.externalInitial do
		out[name] = self.values[name]
	end
	return out
end

-- Put saved external inputs back. Names this plant does not declare as external are ignored.
function Channels.importExternals(self: any, saved: { [string]: any }?)
	if type(saved) ~= "table" then
		return
	end
	for name, value in saved do
		if self.externalInitial[name] ~= nil and type(value) == type(self.externalInitial[name]) then
			self.values[name] = value
		end
	end
end

function Channels.isDeclared(self: any, name: string): boolean
	return self.owner[name] ~= nil
end

function Channels.ownerOf(self: any, name: string): string?
	return self.owner[name]
end

-- Unchecked access for the framework itself (scheduler, replicator, persistence, tests).
function Channels.get(self: any, name: string): any
	return self.values[name]
end

function Channels.setExternal(self: any, name: string, value: any)
	assert(self.owner[name] == "<external>", `channel '{name}' is not an external input`)
	self.values[name] = value
end

-- Port ---------------------------------------------------------------------------------------------------------

local Port = {}
Port.__index = Port

function Port.read(self: any, name: string): any
	if not self._readable[name] then
		error(`{self._system} read undeclared channel '{name}' (add it to spec.reads or spec.readsLagged)`, 2)
	end
	return self._values[name]
end

function Port.write(self: any, name: string, value: any)
	if not self._writable[name] then
		error(`{self._system} wrote channel '{name}' it does not own (add it to spec.writes)`, 2)
	end
	self._values[name] = value
end

function Port.has(self: any, name: string): boolean
	return self._readable[name] == true
end

function Channels.port(self: any, spec: any): Port
	local readable, writable = {}, {}
	for _, ch in spec.reads do
		readable[ch] = true
	end
	for _, ch in spec.readsLagged do
		readable[ch] = true
	end
	for _, ch in spec.writes do
		readable[ch] = true
		writable[ch] = true
	end
	return setmetatable({
		_system = spec.name,
		_values = self.values,
		_readable = readable,
		_writable = writable,
	}, Port) :: any
end

return Channels
