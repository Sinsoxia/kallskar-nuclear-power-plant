--!strict
--[[
	Headless engine: the parts of the Roblox runtime the Kallskar sources touch, emulated on Lune.

	The DataModel itself is real: `rojo build` produces the place and Lune's roblox library deserialises it, so
	instance names, hierarchy, classes, attributes and ModuleScript sources are exactly what Studio would load.
	What this file adds on top:

	- `require(ModuleScript)`: compiles the module's Source with luau.load and runs it once, caching the result
	  per ModuleScript, with Roblox's error texts for recursive requires, failed modules and wrong return counts.
	- Script globals (`script`, `game`, `workspace`, `task`, `Instance`, `Enum`, `Random`, `tick`, datatypes, ...).
	  They are passed to each chunk as locals through a one-line prelude inserted on the first line after the
	  hot comments, so line numbers in errors match the file on disk, `--!native` stays a directive, and the
	  chunk keeps Luau's safe global environment (a custom environment table would disable the fast builtin
	  calls and native code, making timing tests meaningless).
	- Instance methods and members Lune does not implement: WaitForChild, BindableEvent/BindableFunction,
	  RemoteEvent/RemoteFunction (no network: fires are recorded, never delivered), RunService, Players,
	  HttpService JSON, and a DataStoreService that refuses every call.

	Differences from Roblox that matter when reading results are listed in docs/HEADLESS_TESTS.md.
]]
local DateTime = require("@lune/datetime")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")
local task = require("@lune/task")

local Random = require("./Random")
local Signal = require("./Signal")

export type OutputKind = "print" | "warn" | "error" | "info"

export type Options = {
	-- RunService:IsStudio(). TestBoot only runs the suite in Studio, and specs rely on Studio-only checks
	-- (System.record's strict mode), so the harness answers true unless told otherwise.
	isStudio: boolean?,
	-- Seconds an unresolved WaitForChild keeps polling before it raises. Roblox would wait forever (and warn
	-- "Infinite yield possible" after 5 s); a headless run must end.
	waitForChildTimeout: number?,
	-- Compile `--!native` modules to native code, as Roblox servers do. Off only to measure what it buys.
	native: boolean?,
	-- Where print/warn and module load errors go.
	onOutput: ((kind: OutputKind, text: string) -> ())?,
}

local Engine = {}

-- One engine per process: Lune's instance registry (implementMethod/implementProperty) is global to the VM, so
-- the hooks are installed once and read the current state through this table. boot() swaps the state for a
-- fresh DataModel.
local state: any = nil

local function out(kind: OutputKind, text: string)
	if state then
		state.lastOutput = text
	end
	if state and state.options.onOutput then
		state.options.onOutput(kind, text)
	else
		print(text)
	end
end

local function joinArgs(...: any): string
	local n = select("#", ...)
	local parts = table.create(n)
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	return table.concat(parts, " ")
end

-- typeof that also honours __type on the harness's own table-based objects (Random, signals, connections)
local builtinTypeof = typeof
local function typeofRoblox(v: any): string
	local t = builtinTypeof(v)
	if t == "table" then
		local mt = getmetatable(v)
		if type(mt) == "table" and type(rawget(mt, "__type")) == "string" then
			return rawget(mt, "__type")
		end
	end
	return t
end

-- Per-instance signals, created on first access. Keys are Lune's canonical instance userdata.
local function signalOf(inst: any, name: string): any
	local byInst = state.signals[inst]
	if not byInst then
		byInst = {}
		state.signals[inst] = byInst
	end
	local s = byInst[name]
	if not s then
		s = Signal.new(`{inst.Name}.{name}`)
		byInst[name] = s
	end
	return s
end

-- Bindables copy their arguments: tables arrive as fresh tables without metatables, functions and threads as nil.
local function bindableCopy(v: any, seen: { [any]: any }?): any
	local t = type(v)
	if t == "function" or t == "thread" then
		return nil
	elseif t ~= "table" then
		return v
	end
	local memo = seen or {}
	if memo[v] then
		return memo[v]
	end
	local c = {}
	memo[v] = c
	for k, x in v do
		c[bindableCopy(k, memo)] = bindableCopy(x, memo)
	end
	return c
end

local function bindableArgs(...: any): ...any
	local n = select("#", ...)
	local args = table.pack(...)
	for i = 1, n do
		args[i] = bindableCopy(args[i])
	end
	return table.unpack(args, 1, n)
end

--[[
	task.wait, measured. Studio aborts a script that runs past its script timeout without yielding; headless has
	no such limit, so the harness records the longest stretch between yields instead and reports it.
]]
local function trackedWait(seconds: number?): number
	local now = os.clock()
	local stretch = now - state.lastResume
	if stretch > state.longest.seconds then
		local source, line = debug.info(2, "sl")
		state.longest = { seconds = stretch, at = `{source}:{line}`, after = state.lastOutput }
	end
	local waited = task.wait(seconds)
	state.lastResume = os.clock()
	return waited
end

local hooksInstalled = false

local function installHooks()
	if hooksInstalled then
		return
	end
	hooksInstalled = true
	local implementMethod, implementProperty = roblox.implementMethod, roblox.implementProperty

	-- Instance -------------------------------------------------------------------------------------------------
	implementMethod("Instance", "WaitForChild", function(self: any, name: string, timeout: number?)
		local child = self:FindFirstChild(name)
		if child then
			return child
		end
		local limit = timeout or state.options.waitForChildTimeout
		local deadline = os.clock() + limit
		repeat
			trackedWait()
			child = self:FindFirstChild(name)
			if child then
				return child
			end
		until os.clock() >= deadline
		if timeout then
			return nil
		end
		error(`Infinite yield on {self:GetFullName()}:WaitForChild("{name}") (the headless harness gave up after {limit} s)`, 2)
	end)

	-- BindableEvent / BindableFunction -------------------------------------------------------------------------
	implementProperty("BindableEvent", "Event", function(self: any)
		return signalOf(self, "Event")
	end)
	implementMethod("BindableEvent", "Fire", function(self: any, ...: any)
		signalOf(self, "Event"):_fire(bindableArgs(...))
	end)
	implementProperty("BindableFunction", "OnInvoke", function(self: any)
		return state.callbacks[self]
	end, function(self: any, fn: any)
		state.callbacks[self] = fn
	end)
	implementMethod("BindableFunction", "Invoke", function(self: any, ...: any)
		local fn = state.callbacks[self]
		if not fn then
			error("BindableFunction has no OnInvoke callback (the call would yield forever in Roblox)", 2)
		end
		return bindableArgs(fn(bindableArgs(...)))
	end)

	-- RemoteEvent / RemoteFunction: no clients exist headless. Fires are recorded, never delivered.
	local function record(self: any, method: string, ...: any)
		table.insert(state.remoteLog, { remote = self:GetFullName(), method = method, n = select("#", ...) })
	end
	for _, event in { "OnServerEvent", "OnClientEvent" } do
		implementProperty("RemoteEvent", event, function(self: any)
			return signalOf(self, event)
		end)
		implementProperty("UnreliableRemoteEvent", event, function(self: any)
			return signalOf(self, event)
		end)
	end
	for _, method in { "FireAllClients", "FireClient", "FireServer" } do
		implementMethod("RemoteEvent", method, function(self: any, ...: any)
			record(self, method, ...)
		end)
		implementMethod("UnreliableRemoteEvent", method, function(self: any, ...: any)
			record(self, method, ...)
		end)
	end
	for _, cb in { "OnServerInvoke", "OnClientInvoke" } do
		implementProperty("RemoteFunction", cb, function(self: any)
			return state.callbacks[self]
		end, function(self: any, fn: any)
			state.callbacks[self] = fn
		end)
	end
	for _, method in { "InvokeServer", "InvokeClient" } do
		implementMethod("RemoteFunction", method, function(self: any)
			error(`RemoteFunction:{method} needs a client; none exists in a headless run`, 2)
		end)
	end

	-- RunService -----------------------------------------------------------------------------------------------
	implementMethod("RunService", "IsStudio", function()
		return state.options.isStudio
	end)
	implementMethod("RunService", "IsServer", function()
		return true
	end)
	implementMethod("RunService", "IsClient", function()
		return false
	end)
	implementMethod("RunService", "IsRunning", function()
		return true
	end)
	implementMethod("RunService", "IsRunMode", function()
		return false
	end)
	implementMethod("RunService", "IsEdit", function()
		return false
	end)
	for _, event in { "Heartbeat", "Stepped", "RenderStepped", "PreSimulation", "PostSimulation", "PreAnimation", "PreRender" } do
		implementProperty("RunService", event, function(self: any)
			return signalOf(self, event)
		end)
	end

	-- Players: a server nobody has joined -----------------------------------------------------------------------
	implementMethod("Players", "GetPlayers", function()
		return {}
	end)
	implementMethod("Players", "GetPlayerByUserId", function()
		return nil
	end)
	for _, event in { "PlayerAdded", "PlayerRemoving" } do
		implementProperty("Players", event, function(self: any)
			return signalOf(self, event)
		end)
	end

	-- HttpService (JSON only; no requests) ------------------------------------------------------------------------
	implementMethod("HttpService", "JSONEncode", function(_self: any, value: any)
		return serde.encode("json", value)
	end)
	implementMethod("HttpService", "JSONDecode", function(_self: any, text: string)
		return serde.decode("json", text)
	end)
	implementMethod("HttpService", "GenerateGUID", function(_self: any, wrap: boolean?)
		local rng = state.guidRng
		local hex = string.gsub("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx", "[xy]", function(c)
			local v = if c == "x" then rng:NextInteger(0, 15) else rng:NextInteger(8, 11)
			return string.format("%X", v)
		end)
		return if wrap == false then hex else `\{{hex}\}`
	end)

	-- DataStoreService: refuses, so persistence code falls back or fails visibly ---------------------------------
	for _, method in { "GetDataStore", "GetGlobalDataStore", "GetOrderedDataStore", "ListDataStoresAsync" } do
		implementMethod("DataStoreService", method, function()
			error(`DataStoreService:{method} is not available in a headless run (no Roblox backend)`, 2)
		end)
	end

	-- DataModel: close callbacks are kept (a headless server never shuts down through the engine) -----------------
	implementMethod("DataModel", "BindToClose", function(_self: any, fn: () -> ())
		assert(type(fn) == "function", "BindToClose expects a function")
		table.insert(state.closeCallbacks, fn)
	end)
end

--[[
	DataModel members Lune's reflection database has no default for, set to what Studio reports for an
	unpublished place running a Play session: not published, not a private server, created by a user.
]]
local DATAMODEL_DEFAULTS = {
	PlaceId = 0,
	GameId = 0,
	CreatorId = 0,
	JobId = "",
	PrivateServerId = "",
	PrivateServerOwnerId = 0,
}

local function applyDataModelDefaults(dataModel: any)
	for name, value in DATAMODEL_DEFAULTS do
		if not pcall(function()
			return dataModel[name]
		end) then
			dataModel[name] = value
		end
	end
	if not pcall(function()
		return dataModel.CreatorType
	end) then
		dataModel.CreatorType = roblox.Enum.CreatorType.User
	end
end

-- Globals ------------------------------------------------------------------------------------------------------

local DATATYPES = {
	"Axes", "BrickColor", "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "Faces", "Font",
	"NumberRange", "NumberSequence", "NumberSequenceKeypoint", "PhysicalProperties", "Ray", "Rect", "Region3",
	"Region3int16", "UDim", "UDim2", "Vector2", "Vector2int16", "Vector3", "Vector3int16",
}

-- Order of the prelude locals. `script` and `require` differ per chunk; the rest are shared.
local PRELUDE_NAMES = {
	"script", "require", "game", "Game", "workspace", "Workspace", "task", "Instance", "Enum", "Random",
	"tick", "time", "elapsedTime", "wait", "delay", "spawn", "print", "warn", "shared", "typeof",
}
for _, name in DATATYPES do
	table.insert(PRELUDE_NAMES, name)
end
local PRELUDE = `local {table.concat(PRELUDE_NAMES, ", ")} = ...; `

Engine.PRELUDE_NAMES = PRELUDE_NAMES

local function makeGlobals(dataModel: any, startClock: number): { [string]: any }
	local g: { [string]: any } = {}
	g.game = dataModel
	g.Game = dataModel
	local ws = dataModel:GetService("Workspace")
	g.workspace = ws
	g.Workspace = ws

	local taskLib = {
		spawn = task.spawn,
		defer = task.defer,
		delay = task.delay,
		wait = trackedWait,
		cancel = task.cancel,
		-- Parallel Luau: a single-threaded run is already "synchronized"
		synchronize = function() end,
		desynchronize = function() end,
	}
	g.task = table.freeze(taskLib)

	g.Instance = table.freeze({
		new = function(className: string, parent: any?)
			local inst = roblox.Instance.new(className)
			if parent ~= nil then
				inst.Parent = parent
			end
			return inst
		end,
	})
	g.Enum = roblox.Enum

	Random.Vector3 = roblox.Vector3
	g.Random = table.freeze({ new = Random.new })

	g.tick = function()
		return DateTime.now().unixTimestampMillis / 1000
	end
	g.time = function()
		return os.clock() - startClock
	end
	g.elapsedTime = g.time
	g.wait = function(s: number?)
		local waited = trackedWait(s)
		return waited, g.time()
	end
	g.delay = function(s: number, fn: () -> ())
		task.delay(s, fn)
	end
	g.spawn = function(fn: () -> ())
		task.defer(fn)
	end
	g.print = function(...: any)
		out("print", joinArgs(...))
	end
	g.warn = function(...: any)
		out("warn", joinArgs(...))
	end
	g.shared = {}
	g.typeof = typeofRoblox
	for _, name in DATATYPES do
		g[name] = roblox[name]
	end
	return g
end

-- Inserts the prelude at the start of the first line that is not a `--!` hot comment.
local function withPrelude(source: string): string
	local pos = 1
	while string.sub(source, pos, pos + 2) == "--!" do
		local nl = string.find(source, "\n", pos, true)
		if not nl then
			return source .. "\n" .. PRELUDE
		end
		pos = nl + 1
	end
	return string.sub(source, 1, pos - 1) .. PRELUDE .. string.sub(source, pos)
end

local function isNative(source: string): boolean
	local pos = 1
	while string.sub(source, pos, pos + 2) == "--!" do
		local nl = string.find(source, "\n", pos, true) or (#source + 1)
		if string.match(string.sub(source, pos, nl - 1), "^%-%-!native%s*$") then
			return true
		end
		pos = nl + 1
	end
	return false
end

local LOAD_FAILED = "Requested module experienced an error while loading"

-- Compile a script's Source into a function taking the prelude values.
local function compile(inst: any): (any, string?)
	local source = inst.Source
	local ok, fnOrErr = pcall(luau.load, withPrelude(source), {
		debugName = "@" .. inst:GetFullName(),
		codegenEnabled = state.options.native and isNative(source),
	})
	if not ok then
		return nil, tostring(fnOrErr)
	end
	return fnOrErr, nil
end

local function preludeArgs(inst: any, requireFn: any): ...any
	local g = state.globals
	local n = #PRELUDE_NAMES
	local args = table.create(n)
	args[1] = inst
	args[2] = requireFn
	for i = 3, n do
		args[i] = g[PRELUDE_NAMES[i]]
	end
	return table.unpack(args, 1, n)
end

local function requireModule(module: any): any
	if typeofRoblox(module) ~= "Instance" then
		error("Attempted to call require with invalid argument(s).", 2)
	end
	if not module:IsA("ModuleScript") then
		error(`require: {module:GetFullName()} is a {module.ClassName}, not a ModuleScript`, 2)
	end
	local cache = state.modules
	local entry = cache[module]
	if entry then
		if entry.status == "loading" then
			error("Requested module was required recursively", 2)
		elseif entry.status == "failed" then
			error(`{LOAD_FAILED}: {entry.err}`, 2)
		end
		return entry.value
	end
	entry = { status = "loading" }
	cache[module] = entry
	local t0 = os.clock()
	local fn, compileErr = compile(module)
	local ok, results
	if fn then
		results = table.pack(xpcall(fn, function(e)
			return if type(e) == "string" then e else tostring(e)
		end, preludeArgs(module, requireModule)))
		ok = results[1]
	else
		ok, results = false, { false, compileErr, n = 2 }
	end
	state.loadTimes[module:GetFullName()] = os.clock() - t0
	if not ok then
		entry.status = "failed"
		entry.err = results[2]
		out("error", `{results[2]}`)
		error(`{LOAD_FAILED}: {entry.err}`, 2)
	end
	if results.n ~= 2 then
		entry.status = "failed"
		entry.err = "Module code did not return exactly one value"
		error(entry.err, 2)
	end
	entry.status = "loaded"
	entry.value = results[2]
	return entry.value
end

--[[
	Start a headless "server" on `dataModel`. Replaces any previous state (module cache, signals), so the audit
	can boot a fresh place after the tests.
]]
function Engine.boot(dataModel: any, options: Options?)
	local o = options or {}
	state = {
		options = {
			isStudio = if o.isStudio == nil then true else o.isStudio,
			waitForChildTimeout = o.waitForChildTimeout or 10,
			native = if o.native == nil then true else o.native,
			onOutput = o.onOutput,
		},
		dataModel = dataModel,
		modules = {},
		loadTimes = {},
		signals = {},
		callbacks = {},
		remoteLog = {},
		closeCallbacks = {},
		guidRng = Random.new(1),
		lastResume = os.clock(),
		lastOutput = nil,
		longest = { seconds = 0 },
	}
	installHooks()
	applyDataModelDefaults(dataModel)
	state.globals = makeGlobals(dataModel, os.clock())
	return Engine
end

Engine.require = requireModule

-- Run a Script (server or client) the way the engine starts one: once, in its own thread.
function Engine.runScript(inst: any): (boolean, string?)
	local fn, compileErr = compile(inst)
	if not fn then
		out("error", compileErr :: string)
		return false, compileErr
	end
	local ok, err = xpcall(fn, function(e)
		return tostring(e)
	end, preludeArgs(inst, requireModule))
	if not ok then
		out("error", err)
	end
	return ok, if ok then nil else err
end

function Engine.moduleStatus(module: any): (string?, string?)
	local entry = state.modules[module]
	if not entry then
		return nil, nil
	end
	return entry.status, entry.err
end

function Engine.remoteLog(): { any }
	return state.remoteLog
end

function Engine.loadTimes(): { [string]: number }
	return state.loadTimes
end

-- The `shared` table scripts see (Main.server publishes the running plant there in Studio).
function Engine.shared(): { [string]: any }
	return state.globals.shared
end

-- One engine frame: RunService.Heartbeat fires with `dt`, then the harness yields so deferred handlers run.
function Engine.heartbeat(dt: number)
	local runService = state.dataModel:GetService("RunService")
	signalOf(runService, "Heartbeat"):_fire(dt)
	task.wait()
end

-- Longest time any script ran between two yields: { seconds, at = "source:line" of the yield, after = last output }
function Engine.longestStretchWithoutYield(): { seconds: number, at: string?, after: string? }
	return state.longest
end

return Engine
