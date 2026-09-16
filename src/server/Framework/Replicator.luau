--!strict
--[[
	Replicator — sends plant state to clients (spec §14.1, §14.5).
	================================================================
	- Gauges: every numeric field a system returns from getState() is a gauge, keyed by its tag. A manifest maps
	  tags to u16 ids and is sent once per player (and again, with a new version, if the set of tags changes).
	- Lanes: a system's gauges go out at 5 Hz if its class sets `replicateLane = "fast"` (default: the system's own
	  lane: fast systems 5 Hz, slow systems 1 Hz).
	- Every gauge in a lane is sent on every send (no diffing), chunked to Engineering.unreliablePacketBudget_bytes.
	  Unreliable packets can drop; sending full values means a drop costs one update, never a stuck gauge.
	- Core map: the first system with a getCoreMap() method supplies the 331 temperatures, sent at 1 Hz (Net/Packets).
	- Events: new EventLog records are sent reliably at 1 Hz.
	Clients only render; they never compute plant state (§14.5).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packets = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Net"):WaitForChild("Packets"))

local Replicator = {}
Replicator.__index = Replicator

function Replicator.new(opts: { config: any, registry: any, log: any, remotes: any? })
	local self = setmetatable({}, Replicator)
	local c = opts.config
	self.registry = opts.registry
	self.log = opts.log
	self.remotes = opts.remotes
	self.fastPeriod = 1 / c.Clocks.replicateFast_Hz
	self.slowPeriod = 1 / c.Clocks.replicateSlow_Hz
	self.budget = c.Engineering.unreliablePacketBudget_bytes
	self.coreMapResolution = c.Engineering.coreMapResolution_K
	self.version = 0
	self.ids = {} :: { [string]: number }
	self.tags = {} :: { string }
	self.laneOf = {} :: { [any]: string }
	self.fastAcc = 0
	self.slowAcc = 0
	self.lastEventSeq = 0
	self.sent = { fast = 0, slow = 0, coreMap = 0, events = 0, bytes = 0 }
	return self
end

local function laneFor(sys: any): string
	local l = sys.replicateLane
	if l == "fast" or l == "slow" then
		return l
	end
	return sys.spec.lane
end

-- Rebuild the tag→id manifest from the current system states. Returns true if it changed.
function Replicator.buildManifest(self: any): boolean
	local tags = {}
	for _, sys in self.registry.systems do
		self.laneOf[sys] = laneFor(sys)
		for key, value in sys:getState() do
			if type(key) == "string" and type(value) == "number" then
				table.insert(tags, key)
			end
		end
	end
	table.sort(tags)
	assert(#tags <= 65535, "too many gauges for u16 ids")
	local changed = #tags ~= #self.tags
	if not changed then
		for i, t in tags do
			if self.tags[i] ~= t then
				changed = true
				break
			end
		end
	end
	if changed then
		self.version = (self.version % 65535) + 1
		self.tags = tags
		self.ids = {}
		for i, t in tags do
			self.ids[t] = i
		end
	end
	return changed
end

function Replicator.manifest(self: any): { version: number, tags: { string } }
	return { version = self.version, tags = table.clone(self.tags) }
end

-- Gather id/value arrays for one lane. Unknown tags (new since the manifest) trigger a manifest rebuild.
function Replicator.collect(self: any, lane: string): ({ number }, { number }, boolean)
	local ids, values = {}, {}
	local unknown = false
	for _, sys in self.registry.systems do
		if self.laneOf[sys] == lane then
			for key, value in sys:getState() do
				if type(key) == "string" and type(value) == "number" then
					local id = self.ids[key]
					if id then
						table.insert(ids, id)
						table.insert(values, value)
					else
						unknown = true
					end
				end
			end
		end
	end
	return ids, values, unknown
end

function Replicator.packLane(self: any, lane: string): { buffer }
	local ids, values, unknown = self:collect(lane)
	if unknown and self:buildManifest() and self.remotes then
		self.remotes.Manifest:FireAllClients(self:manifest())
		ids, values = self:collect(lane)
	end
	return Packets.chunkGauges(self.version, ids, values, self.budget)
end

function Replicator.coreMapPacket(self: any): buffer?
	for _, sys in self.registry.systems do
		if type(sys.getCoreMap) == "function" then
			local temps = sys:getCoreMap()
			if temps then
				return Packets.packCoreMap(temps, self.coreMapResolution)
			end
		end
	end
	return nil
end

local function send(self: any, packets: { buffer }, counter: string)
	local gauges = self.remotes.Gauges
	for _, p in packets do
		gauges:FireAllClients(p)
		self.sent.bytes += buffer.len(p)
	end
	self.sent[counter] += 1
end

function Replicator.tick(self: any, dt: number)
	if not self.remotes then
		return
	end
	self.fastAcc += dt
	self.slowAcc += dt
	if self.fastAcc >= self.fastPeriod then
		self.fastAcc %= self.fastPeriod
		send(self, self:packLane("fast"), "fast")
	end
	if self.slowAcc >= self.slowPeriod then
		self.slowAcc %= self.slowPeriod
		send(self, self:packLane("slow"), "slow")
		local map = self:coreMapPacket()
		if map then
			send(self, { map }, "coreMap")
		end
		local records = self.log:since(self.lastEventSeq)
		if #records > 0 then
			self.lastEventSeq = records[#records].seq
			self.remotes.Events:FireAllClients(records)
			self.sent.events += #records
		end
	end
end

function Replicator.sendManifestTo(self: any, player: Player)
	if self.remotes then
		self.remotes.Manifest:FireClient(player, self:manifest())
	end
end

return Replicator
