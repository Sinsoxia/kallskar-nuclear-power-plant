--!strict
--[[
	EventLog — the sequence-of-events log (spec §10.7 accountability, §14.6 persistence).
	=====================================================================================
	Every control action (accepted or refused), trip, alarm and framework event is recorded with a monotonic sequence
	number, the actor's name, real time, simulation time and grid time. Stored in a fixed-size ring
	(Config.Engineering.eventLogCapacity); since(seq) lets the replicator send only new entries.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Types"))

type Actor = Types.Actor
type EventRecord = Types.EventRecord

local EventLog = {}
EventLog.__index = EventLog

function EventLog.new(config: any, clock: Types.Clock)
	local self = setmetatable({}, EventLog)
	self.capacity = config.Engineering.eventLogCapacity
	self.persisted = config.Engineering.eventLogPersisted
	self.clock = clock
	self.buf = table.create(self.capacity) :: { EventRecord }
	self.head = 0 -- index of the newest record in buf
	self.count = 0
	self.seq = 0
	return self
end

function EventLog.record(self: any, kind: string, actor: Actor?, target: string?, detail: string?, result: string?): EventRecord
	self.seq += 1
	local rec: EventRecord = {
		seq = self.seq,
		realTime = os.time(),
		simTime = self.clock.sim,
		gridTime = self.clock.grid,
		actor = if actor then actor.name else "plant",
		actorKind = if actor then actor.kind else "system",
		kind = kind,
		target = target,
		detail = detail,
		result = result or "info",
	}
	self.head = self.head % self.capacity + 1
	self.buf[self.head] = rec
	if self.count < self.capacity then
		self.count += 1
	end
	return rec
end

-- Oldest-first list of the most recent `n` records (all retained records if n is nil).
function EventLog.latest(self: any, n: number?): { EventRecord }
	local take = math.min(n or self.count, self.count)
	local out = table.create(take)
	local start = self.head - take + 1
	for i = 0, take - 1 do
		local idx = (start + i - 1) % self.capacity + 1
		out[i + 1] = self.buf[idx]
	end
	return out
end

-- Records with seq greater than `seq`, oldest first (only those still retained).
function EventLog.since(self: any, seq: number): { EventRecord }
	local newer = self.seq - seq
	if newer <= 0 then
		return {}
	end
	return self:latest(math.min(newer, self.count))
end

function EventLog.export(self: any): { EventRecord }
	return self:latest(self.persisted)
end

function EventLog.import(self: any, records: { EventRecord }?)
	if not records then
		return
	end
	for _, rec in records do
		self.head = self.head % self.capacity + 1
		self.buf[self.head] = rec
		if self.count < self.capacity then
			self.count += 1
		end
		if rec.seq > self.seq then
			self.seq = rec.seq
		end
	end
end

return EventLog
