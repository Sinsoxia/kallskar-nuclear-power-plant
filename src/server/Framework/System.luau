--!strict
--[[
	System — base class for every simulated plant system (spec §14.7).
	===================================================================

	Defining a system:

		local System = require(Framework.System)
		local PrimaryPumps = System.extend({
			name = "PrimaryPumps",
			lane = "fast",
			reads = { "core.power" },
			readsLagged = { "pools.coldTemp" },
			writes = { "primary.flow" },
		})

		PrimaryPumps.commands = {
			["pump.speed"] = function(self, actor, cmd) ... return { ok = true } end,
		}
		PrimaryPumps.faults = { { id = "PP-TRIP", label = "Primary pump trip", cost = 3, arm = function(self, p) ... end } }

		function PrimaryPumps:init(ctx) ... end      -- ctx.config, ctx.channels, ctx.bus, ctx.log, ctx.clock
		function PrimaryPumps:step(dt) ... end
		function PrimaryPumps:getState() return { ... } end

		return PrimaryPumps

	Metatable rules (see README): the lookup chain is at most instance → class → System. Shared behaviour is added
	with System.mixin, which copies functions into the class once at definition time instead of adding another
	inheritance level. Nothing here is touched inside a numeric inner loop.
]]
local Types = require(game:GetService("ReplicatedStorage"):WaitForChild("Kallskar"):WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult
type SystemSpec = Types.SystemSpec

export type Context = {
	config: any, -- the frozen Config
	channels: any, -- Channels store
	bus: any, -- Bus
	log: any, -- EventLog
	clock: Types.Clock,
	isStudio: boolean,
}

local RunService = game:GetService("RunService")

local System = {}
System.__index = System

local LANES = { fast = true, slow = true }
local EMPTY = table.freeze({})

local function copyList(list: { string }?, field: string, name: string): { string }
	local out = {}
	if list == nil then
		return table.freeze(out)
	end
	assert(type(list) == "table", `{name}: spec.{field} must be a list of channel names`)
	local seen = {}
	for i, ch in list do
		assert(type(ch) == "string" and #ch > 0, `{name}: spec.{field}[{i}] must be a non-empty string`)
		assert(not seen[ch], `{name}: channel '{ch}' listed twice in spec.{field}`)
		seen[ch] = true
		out[i] = ch
	end
	return table.freeze(out)
end

--[[
	Create a new system class from its spec. The returned class inherits every default below.
]]
function System.extend(spec: SystemSpec)
	assert(type(spec) == "table", "System.extend expects a spec table")
	local name = spec.name
	assert(type(name) == "string" and string.match(name, "^%u%w*$"), "spec.name must be PascalCase")
	assert(LANES[spec.lane], `{name}: spec.lane must be "fast" or "slow"`)

	local frozen = table.freeze({
		name = name,
		lane = spec.lane,
		reads = copyList(spec.reads, "reads", name),
		readsLagged = copyList(spec.readsLagged, "readsLagged", name),
		writes = copyList(spec.writes, "writes", name),
	})

	local class = setmetatable({}, System)
	class.__index = class
	class.spec = frozen
	class.name = name
	class.commands = EMPTY
	class.faults = EMPTY
	return class
end

--[[
	Copy functions from a mixin table into a class (no extra inheritance level). Existing class members win, so a
	class can override a mixin method by defining it before or after mixing in.
]]
function System.mixin(class: any, mixin: { [string]: any })
	for k, v in mixin do
		if rawget(class, k) == nil then
			rawset(class, k, v)
		end
	end
	return class
end

--[[
	Instantiate a class. Construction is separate from init so the Registry can check every spec before any system
	touches shared state.
]]
function System.new(class: any, ...: any)
	assert(getmetatable(class) == System, "System.new expects a class made by System.extend (no deeper inheritance)")
	local self = setmetatable({}, class)
	if class.construct then
		class.construct(self, ...)
	end
	return self
end

function System.isSystem(x: any): boolean
	if type(x) ~= "table" then
		return false
	end
	local mt = getmetatable(x)
	while mt do
		if mt == System then
			return true
		end
		mt = getmetatable(mt)
	end
	return false
end

-- Defaults ----------------------------------------------------------------------------------------------------

function System.init(_self: any, _ctx: Context) end

function System.step(self: any, _dt: number)
	error(`{self.name}: step(dt) is not implemented`, 2)
end

function System.getState(_self: any): { [string]: any }
	return {}
end

--[[
	Route a command to the handler in class.commands. Handlers return CommandResult. Unknown kinds are refused, never
	ignored silently.
]]
function System.applyCommand(self: any, actor: Actor, cmd: Command): CommandResult
	local handler = self.commands[cmd.kind]
	if not handler then
		return { ok = false, reason = `unsupported command '{cmd.kind}' for {self.name}` }
	end
	local ok, result = pcall(handler, self, actor, cmd)
	if not ok then
		return { ok = false, reason = `internal error in {self.name}: {tostring(result)}` }
	end
	if type(result) ~= "table" or type(result.ok) ~= "boolean" then
		return { ok = false, reason = `{self.name} handler for '{cmd.kind}' returned no CommandResult` }
	end
	return result
end

-- Persistence hooks (spec §14.6). Return nil to persist nothing. load() gets its slice already migrated by
-- Persistence.MIGRATIONS, together with the version it is now in, so a system never upgrades a slice itself.
function System.save(_self: any): any
	return nil
end

function System.load(_self: any, _data: any, _version: number) end

--[[
	Development aid: a record whose unknown keys throw on read and write. Only active in Studio, and only when the
	caller passes strict = true; on live servers it returns the plain table unchanged.
	Use it for per-system state records (touched once per tick), never for per-node arrays.
]]
local STRICT_MT = {
	__index = function(t, k)
		error(`strict record: read of unknown key '{tostring(k)}'`, 2)
	end,
	__newindex = function(t, k)
		error(`strict record: write of unknown key '{tostring(k)}' (declare it when the record is created)`, 2)
	end,
}

function System.record<T>(fields: T, strict: boolean?): T
	if strict and RunService:IsStudio() then
		return setmetatable(fields :: any, STRICT_MT)
	end
	return fields
end

return System
