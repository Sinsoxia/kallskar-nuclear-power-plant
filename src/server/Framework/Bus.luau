--!strict
--[[
	Bus — synchronous, typed plant-wide events.
	============================================
	Topics are a closed list, so a typo in publish/subscribe is an error instead of a message nobody hears.
	A subscriber that throws is isolated (warned and counted) so one faulty listener can't break a tick.
	Add a topic here when a new kind of plant-wide event appears (e.g. a scenario director milestone).
]]

local TOPICS = table.freeze({
	Trip = true, -- { system, reason, firstOut }
	EquipmentTrip = true, -- { system, equipment, reason, running } — a pump, fan or drive stopping, not a reactor trip
	Runback = true, -- { id = "RB-1".."RB-3", target_pctFP, rate_pctpmin, reason }
	Alarm = true, -- { tag, priority = 1|2|3, state = "in"|"out"|"ack", text }
	ModeChange = true, -- { from, to }
	CommandApplied = true, -- { actor, kind, target, result }
	FaultArmed = true, -- { id, system, params }
	FaultCleared = true, -- { id, system }
	SimulationHalted = true, -- { system, error }
	ResetCountdown = true, -- { secondsLeft, requestedBy }
	PlantReset = true, -- { requestedBy }
})

local Bus = {}
Bus.__index = Bus
Bus.TOPICS = TOPICS

function Bus.new()
	local self = setmetatable({}, Bus)
	self.subs = {} :: { [string]: { (any) -> () } }
	self.errors = 0
	return self
end

function Bus.subscribe(self: any, topic: string, fn: (any) -> ()): () -> ()
	assert(TOPICS[topic], `unknown bus topic '{topic}'`)
	assert(type(fn) == "function", "subscriber must be a function")
	local list = self.subs[topic]
	if not list then
		list = {}
		self.subs[topic] = list
	end
	table.insert(list, fn)
	return function()
		local i = table.find(list, fn)
		if i then
			table.remove(list, i)
		end
	end
end

function Bus.publish(self: any, topic: string, payload: any)
	assert(TOPICS[topic], `unknown bus topic '{topic}'`)
	local list = self.subs[topic]
	if not list then
		return
	end
	-- iterate a copy so subscribers may unsubscribe while handling
	for _, fn in table.clone(list) do
		local ok, err = pcall(fn, payload)
		if not ok then
			self.errors += 1
			warn(`[Kallskar] bus subscriber for '{topic}' failed: {tostring(err)}`)
		end
	end
end

return Bus
