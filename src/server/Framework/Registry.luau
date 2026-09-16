--!strict
--[[
	Registry — collects systems, checks their contracts, and decides the order they run in.
	=========================================================================================

	resolve() fails loudly (with the exact offending names) when:
	  - two systems write the same channel
	  - a system reads a channel nobody writes and it isn't a declared external input
	  - same-lane systems form a read/write cycle not broken by readsLagged (the cycle is printed)
	  - two systems claim the same command kind
	  - two faults share an id

	Order within a lane is a topological sort of "writer before same-lane reader", ties broken by name so the order
	is deterministic between runs.
]]
local System = require(script.Parent.System)

local Registry = {}
Registry.__index = Registry

function Registry.new(channels: any)
	local self = setmetatable({}, Registry)
	self.channels = channels
	self.systems = {} :: { any }
	self.byName = {} :: { [string]: any }
	self.order = { fast = {}, slow = {} } :: { [string]: { any } }
	self.commandOwner = {} :: { [string]: any }
	self.faultIndex = {} :: { [string]: { system: any, fault: any } }
	self.resolved = false
	return self
end

function Registry.add(self: any, sys: any)
	assert(not self.resolved, "cannot add systems after resolve()")
	assert(System.isSystem(sys), "Registry.add expects a System instance")
	local name = sys.spec.name
	assert(not self.byName[name], `duplicate system name '{name}'`)
	self.byName[name] = sys
	table.insert(self.systems, sys)
	return sys
end

function Registry.get(self: any, name: string): any
	return self.byName[name]
end

local function findCycle(nodes: { any }, edges: { [any]: { any } }): { string }
	local WHITE, GREY, BLACK = 0, 1, 2
	local colour = {}
	local stack = {}
	local found: { string }? = nil
	local function visit(n: any)
		if found then
			return
		end
		colour[n] = GREY
		table.insert(stack, n)
		for _, m in edges[n] or {} do
			if found then
				return
			end
			if colour[m] == GREY then
				local cyc = {}
				local start = table.find(stack, m) :: number
				for i = start, #stack do
					table.insert(cyc, stack[i].spec.name)
				end
				table.insert(cyc, m.spec.name)
				found = cyc
				return
			elseif (colour[m] or WHITE) == WHITE then
				visit(m)
			end
		end
		table.remove(stack)
		colour[n] = BLACK
	end
	for _, n in nodes do
		if (colour[n] or WHITE) == WHITE then
			visit(n)
		end
	end
	return found or {}
end

function Registry.resolve(self: any)
	assert(not self.resolved, "resolve() called twice")
	local channels = self.channels

	-- 1. Declare every written channel (detects double writers)
	for _, sys in self.systems do
		for _, ch in sys.spec.writes do
			channels:declare(ch, sys.spec.name)
		end
	end

	-- 2. Every read must have a writer
	for _, sys in self.systems do
		for _, list in { sys.spec.reads, sys.spec.readsLagged } do
			for _, ch in list do
				if not channels:isDeclared(ch) then
					error(`{sys.spec.name} reads channel '{ch}' but no system writes it and it is not an external input`, 0)
				end
			end
		end
	end

	-- 3. Order each lane
	local writerOf = {}
	for _, sys in self.systems do
		for _, ch in sys.spec.writes do
			writerOf[ch] = sys
		end
	end
	for _, lane in { "fast", "slow" } do
		local nodes = {}
		for _, sys in self.systems do
			if sys.spec.lane == lane then
				table.insert(nodes, sys)
			end
		end
		table.sort(nodes, function(a, b)
			return a.spec.name < b.spec.name
		end)
		local edges: { [any]: { any } } = {}
		local indeg: { [any]: number } = {}
		for _, n in nodes do
			edges[n] = {}
			indeg[n] = 0
		end
		for _, reader in nodes do
			local seen = {}
			for _, ch in reader.spec.reads do
				local w = writerOf[ch]
				if w and w ~= reader and w.spec.lane == lane and not seen[w] then
					seen[w] = true
					table.insert(edges[w], reader)
					indeg[reader] += 1
				end
			end
		end
		local ready = {}
		for _, n in nodes do
			if indeg[n] == 0 then
				table.insert(ready, n)
			end
		end
		local ordered = {}
		while #ready > 0 do
			table.sort(ready, function(a, b)
				return a.spec.name < b.spec.name
			end)
			local n = table.remove(ready, 1)
			table.insert(ordered, n)
			for _, m in edges[n] do
				indeg[m] -= 1
				if indeg[m] == 0 then
					table.insert(ready, m)
				end
			end
		end
		if #ordered ~= #nodes then
			local cyc = findCycle(nodes, edges)
			error(
				`{lane} lane has a read/write cycle: {table.concat(cyc, " -> ")}. Break it by moving one read into readsLagged.`,
				0
			)
		end
		self.order[lane] = ordered
	end

	-- 4. Command kinds and faults
	for _, sys in self.systems do
		for kind in sys.commands do
			local owner = self.commandOwner[kind]
			if owner then
				error(`command '{kind}' is handled by both {owner.spec.name} and {sys.spec.name}`, 0)
			end
			self.commandOwner[kind] = sys
		end
		for _, f in sys.faults do
			assert(type(f.id) == "string" and #f.id > 0, `{sys.spec.name}: fault without id`)
			if self.faultIndex[f.id] then
				error(`fault id '{f.id}' declared by both {self.faultIndex[f.id].system.spec.name} and {sys.spec.name}`, 0)
			end
			self.faultIndex[f.id] = { system = sys, fault = f }
		end
	end

	self.resolved = true
	return self.order
end

function Registry.initAll(self: any, ctxBase: any)
	assert(self.resolved, "resolve() before initAll()")
	for _, lane in { "fast", "slow" } do
		for _, sys in self.order[lane] do
			local ctx = table.clone(ctxBase)
			ctx.channels = self.channels:port(sys.spec)
			sys:init(ctx)
		end
	end
end

function Registry.ownerOfCommand(self: any, kind: string): any
	return self.commandOwner[kind]
end

function Registry.orderNames(self: any, lane: string): { string }
	local out = {}
	for i, sys in self.order[lane] do
		out[i] = sys.spec.name
	end
	return out
end

return Registry
