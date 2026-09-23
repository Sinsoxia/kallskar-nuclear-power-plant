--!strict
--[[
	Persistence — plant condition per private server (spec §14.6, OD-9).
	=====================================================================
	- Private servers: load at start, autosave every Engineering.saveInterval_s, save on shutdown.
	  Key: "plant/<PrivateServerId>" in the DataStore "Kallskar". Public servers always start fresh (mode "public").
	- The save is versioned. Persistence.CURRENT_VERSION increases whenever any system's save layout changes, and a
	  migration function is added to MIGRATIONS[oldVersion] that upgrades a save by one version. load() walks the
	  chain, so any old plant can be brought forward.
	- Each system saves its own slice via System.save()/load(); the framework adds clock and event log. load(slice,
	  version) is given the slice after migration, so `version` is always CURRENT_VERSION.
	- Owner reset: requestReset(actor, phrase) checks the private server owner and the typed phrase
	  (Engineering.resetConfirmationPhrase), then counts down Access.reset.countdown_s, announcing on the Bus; at zero
	  it clears the save and publishes PlantReset (Main rebuilds the plant).
	Stores are pluggable: MemoryStore for Studio/tests, DataStoreBackend for live private servers.
	- One write at a time. A DataStore write yields, and Heartbeat keeps calling tick() meanwhile, so the autosave runs
	  on its own thread and every write (autosave, shutdown save, the reset's remove) waits for the one in flight.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Types"))

type Actor = Types.Actor
type CommandResult = Types.CommandResult

export type Store = {
	get: (self: Store, key: string) -> (boolean, any),
	set: (self: Store, key: string, value: any) -> (boolean, any),
	remove: (self: Store, key: string) -> (boolean, any),
}

local Persistence = {}
Persistence.__index = Persistence

Persistence.CURRENT_VERSION = 1
-- MIGRATIONS[v] upgrades a version-v save to version v + 1. Empty until the save layout first changes.
Persistence.MIGRATIONS = {} :: { [number]: (any) -> any }

-- Stores ---------------------------------------------------------------------------------------------------------

-- DataStore values are serialised copies; the memory store mimics that with a deep copy.
local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

local MemoryStore = {}
MemoryStore.__index = MemoryStore

function MemoryStore.new()
	return setmetatable({ data = {} }, MemoryStore)
end

function MemoryStore.get(self: any, key: string): (boolean, any)
	return true, deepCopy(self.data[key])
end

function MemoryStore.set(self: any, key: string, value: any): (boolean, any)
	self.data[key] = deepCopy(value)
	return true, nil
end

function MemoryStore.remove(self: any, key: string): (boolean, any)
	self.data[key] = nil
	return true, nil
end

Persistence.MemoryStore = MemoryStore

local DataStoreBackend = {}
DataStoreBackend.__index = DataStoreBackend

function DataStoreBackend.new(storeName: string)
	local DataStoreService = game:GetService("DataStoreService")
	return setmetatable({ ds = DataStoreService:GetDataStore(storeName), retries = 3, wait = task.wait }, DataStoreBackend)
end

local function withRetry(self: any, fn: () -> any): (boolean, any)
	local lastErr
	for attempt = 1, self.retries do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		lastErr = result
		if attempt < self.retries then -- back off between tries; after the last one there is nothing to wait for
			self.wait(2 ^ attempt)
		end
	end
	return false, lastErr
end

function DataStoreBackend.get(self: any, key: string): (boolean, any)
	return withRetry(self, function()
		return self.ds:GetAsync(key)
	end)
end

function DataStoreBackend.set(self: any, key: string, value: any): (boolean, any)
	return withRetry(self, function()
		return self.ds:SetAsync(key, value)
	end)
end

function DataStoreBackend.remove(self: any, key: string): (boolean, any)
	return withRetry(self, function()
		return self.ds:RemoveAsync(key)
	end)
end

Persistence.DataStoreBackend = DataStoreBackend

-- Persistence ----------------------------------------------------------------------------------------------------

export type Mode = "private" | "public"

function Persistence.new(opts: {
	config: any,
	registry: any,
	log: any,
	bus: any?,
	clock: Types.Clock,
	store: Store,
	mode: Mode,
	key: string,
	ownerUserId: number,
	migrations: { [number]: (any) -> any }?,
	currentVersion: number?,
})
	local self = setmetatable({}, Persistence)
	self.config = opts.config
	self.registry = opts.registry
	self.log = opts.log
	self.bus = opts.bus
	self.clock = opts.clock
	self.store = opts.store
	self.mode = opts.mode
	self.key = opts.key
	self.ownerUserId = opts.ownerUserId
	self.migrations = opts.migrations or Persistence.MIGRATIONS
	self.currentVersion = opts.currentVersion or Persistence.CURRENT_VERSION
	self.saveInterval = opts.config.Engineering.saveInterval_s
	self.writable = true -- false while the stored plant has not been read successfully (see load)
	self.phrase = opts.config.Engineering.resetConfirmationPhrase
	self.countdownLength = opts.config.Access.reset.countdown_s
	self.sinceSave = 0
	self.saving = false -- a write is in flight (see save)
	self.reset = nil :: { remaining: number, requestedBy: string, lastAnnounced: number }?
	return self
end

function Persistence.enabled(self: any): boolean
	return self.mode == "private"
end

function Persistence.snapshot(self: any): any
	local systems = {}
	for _, sys in self.registry.systems do
		local ok, data = pcall(sys.save, sys)
		if not ok then
			error(`{sys.spec.name}.save failed: {tostring(data)}`)
		end
		if data ~= nil then
			systems[sys.spec.name] = data
		end
	end
	return {
		version = self.currentVersion,
		savedAt = os.time(),
		clock = { sim = self.clock.sim, grid = self.clock.grid, slow = self.clock.slow },
		systems = systems,
		eventLog = self.log:export(),
	}
end

function Persistence.migrate(self: any, data: any): any
	local v = data.version
	if type(v) ~= "number" then
		error("save has no version")
	end
	if v > self.currentVersion then
		error(`save version {v} is newer than this server ({self.currentVersion})`)
	end
	while v < self.currentVersion do
		local step = self.migrations[v]
		if not step then
			error(`no migration from save version {v}`)
		end
		data = step(data)
		v += 1
		data.version = v
	end
	return data
end

function Persistence.save(self: any): (boolean, string?)
	if not self.writable then
		return false, "the stored plant could not be loaded, so nothing overwrites it"
	end
	if not self:enabled() then
		return false, "persistence disabled on this server"
	end
	--[[
		One write at a time, in the order they were asked for. A second write started while the first yields could
		land first and then be overwritten by the older snapshot, or land after an owner reset has removed the plant.
	]]
	while self.saving do
		task.wait()
	end
	self.saving = true
	local okSnap, data = pcall(self.snapshot, self)
	if not okSnap then
		self.saving = false
		self.log:record("save", nil, self.key, tostring(data), "error")
		return false, tostring(data)
	end
	local okCall, ok, err = pcall(self.store.set, self.store, self.key, data)
	self.saving = false
	if not okCall then
		ok, err = false, ok
	end
	self.sinceSave = 0
	if not ok then
		self.log:record("save", nil, self.key, tostring(err), "error")
		return false, tostring(err)
	end
	return true, nil
end

-- Returns "fresh" (nothing loaded) or "loaded", or raises on a corrupt/unmigratable save.
function Persistence.load(self: any): string
	if not self:enabled() then
		return "fresh"
	end
	-- Until this load succeeds nothing may overwrite what is stored: a save this server could not read (an outage, a
	-- newer version) is still the owner's plant, and Main halts rather than start fresh over it.
	self.writable = false
	local ok, data = self.store:get(self.key)
	if not ok then
		error(`could not read save: {tostring(data)}`)
	end
	if data == nil then
		self.writable = true
		return "fresh"
	end
	local fromVersion = data.version
	data = self:migrate(data)
	self.clock.sim = data.clock and data.clock.sim or 0
	self.clock.grid = data.clock and data.clock.grid or 0
	self.clock.slow = data.clock and data.clock.slow or 0
	for _, sys in self.registry.systems do
		local slice = data.systems and data.systems[sys.spec.name]
		if slice ~= nil then
			sys:load(slice, self.currentVersion) -- the slice has been migrated to this version above
		end
	end
	self.log:import(data.eventLog)
	self.log:record("load", nil, self.key, `save version {fromVersion} → {self.currentVersion}`, "ok")
	self.writable = true
	return "loaded"
end

function Persistence.requestReset(self: any, actor: Actor, phrase: string): CommandResult
	if not self:enabled() then
		return { ok = false, reason = "only private servers keep plant condition" }
	end
	if actor.userId ~= self.ownerUserId then
		return { ok = false, reason = "only the private server owner can reset the plant" }
	end
	if phrase ~= self.phrase then
		return { ok = false, reason = `type exactly "{self.phrase}" to confirm` }
	end
	if self.reset then
		return { ok = false, reason = "a reset countdown is already running" }
	end
	self.reset = { remaining = self.countdownLength, requestedBy = actor.name, lastAnnounced = math.huge }
	self.log:record("plant.reset.requested", actor, nil, `{self.countdownLength} s countdown`, "ok")
	return { ok = true }
end

function Persistence.cancelReset(self: any, actor: Actor): CommandResult
	if not self.reset then
		return { ok = false, reason = "no reset countdown running" }
	end
	if actor.userId ~= self.ownerUserId then
		return { ok = false, reason = "only the private server owner can cancel the reset" }
	end
	self.reset = nil
	self.log:record("plant.reset.cancelled", actor, nil, nil, "ok")
	return { ok = true }
end

function Persistence.tick(self: any, dt: number)
	if self:enabled() and not self.saving then
		self.sinceSave += dt
		if self.sinceSave >= self.saveInterval then
			-- on a thread of its own: the write yields, and this frame's caller must not wait for it
			self.sinceSave = 0
			task.spawn(self.save, self)
		end
	end
	local r = self.reset
	if r then
		r.remaining -= dt
		local whole = math.max(0, math.ceil(r.remaining))
		if whole < r.lastAnnounced then
			r.lastAnnounced = whole
			if self.bus then
				self.bus:publish("ResetCountdown", { secondsLeft = whole, requestedBy = r.requestedBy })
			end
		end
		if r.remaining <= 0 then
			self.reset = nil
			-- a save in flight holds the plant as it was: let it land first, and let no other write land after
			while self.saving do
				task.wait()
			end
			self.saving = true
			self.store:remove(self.key)
			self.saving = false
			self.log:record("plant.reset", nil, nil, `requested by {r.requestedBy}`, "ok")
			if self.bus then
				self.bus:publish("PlantReset", { requestedBy = r.requestedBy })
			end
			self.writable = true -- the owner chose to start over, so the fresh plant may now be saved
		end
	end
end

return Persistence
