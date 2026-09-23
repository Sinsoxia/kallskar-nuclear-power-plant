--!strict
-- Framework: System base class, Channels/ports, Registry ordering, Scheduler, Bus, EventLog, Commands, Faults,
-- Packets and Persistence. Each test builds its own tiny plant so tests never share state.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Kallskar")
local Framework = ServerScriptService:WaitForChild("Kallskar"):WaitForChild("Framework")
local Config = require(Shared:WaitForChild("Config")) :: any
local Packets = require(Shared:WaitForChild("Net"):WaitForChild("Packets")) :: any
local Tags = require(Shared:WaitForChild("Tags")) :: any
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local Registry = require(Framework:WaitForChild("Registry")) :: any
local Scheduler = require(Framework:WaitForChild("Scheduler")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Commands = require(Framework:WaitForChild("Commands")) :: any
local Faults = require(Framework:WaitForChild("Faults")) :: any
local Persistence = require(Framework:WaitForChild("Persistence")) :: any
local PlantReset = require(Framework:WaitForChild("PlantReset")) :: any

local SERVER: any = { kind = "auto", name = "test-auto", userId = 0 }

-- A minimal system class. `trace` records step order across systems in one plant.
local function makeClass(name: string, lane: string, reads: { string }, writes: { string }, lagged: { string }?)
	local C = System.extend({ name = name, lane = lane, reads = reads, writes = writes, readsLagged = lagged })
	function C:init(ctx)
		self.ctx = ctx
		self.io = ctx.channels
		self.steps = 0
		for _, ch in writes do
			self.io:write(ch, 0)
		end
	end
	function C:step(dt)
		self.steps += 1
		if self.trace then
			table.insert(self.trace, name)
		end
		for _, ch in writes do
			self.io:write(ch, self.steps)
		end
	end
	return C
end

local function plant(classes: { any })
	local ch = Channels.new()
	local reg = Registry.new(ch)
	local bus = Bus.new()
	local sched = Scheduler.new(reg, Config, bus, nil)
	local log = EventLog.new(Config, sched.clock)
	sched.log = log
	local instances = {}
	for _, c in classes do
		table.insert(instances, reg:add(System.new(c)))
	end
	return { channels = ch, registry = reg, bus = bus, scheduler = sched, log = log, systems = instances }
end

local function resolveAndInit(p: any)
	p.registry:resolve()
	p.registry:initAll({ config = Config, bus = p.bus, log = p.log, clock = p.scheduler.clock, isStudio = true })
end

return {
	-- System --------------------------------------------------------------------------------------------------
	["System.extend validates specs"] = function(t)
		t.throws(function()
			System.extend({ name = "lowercase", lane = "fast", reads = {}, writes = {} })
		end, "PascalCase")
		t.throws(function()
			System.extend({ name = "Bad", lane = "medium", reads = {}, writes = {} })
		end, "lane")
		t.throws(function()
			System.extend({ name = "Bad", lane = "fast", reads = { "a", "a" }, writes = {} })
		end, "twice")
		local C = System.extend({ name = "Good", lane = "slow", reads = {}, writes = { "x.y" } })
		t.eq(C.spec.lane, "slow")
		t.throws(function()
			C.spec.lane = "fast"
		end)
	end,

	["System defaults and command routing"] = function(t)
		local C = System.extend({ name = "Router", lane = "fast", reads = {}, writes = {} })
		C.commands = {
			["test.ok"] = function(self, actor, cmd)
				return { ok = true, reason = actor.name .. ":" .. tostring(cmd.value) }
			end,
			["test.throws"] = function()
				error("boom")
			end,
			["test.junk"] = function()
				return 42
			end,
		}
		local s = System.new(C)
		t.ok(System.isSystem(s))
		t.eq(next(s:getState()), nil, "default getState is empty")
		t.eq(s:save(), nil, "default save is nil")
		t.throws(function()
			s:step(0.1)
		end, "not implemented")
		t.eq(s:applyCommand(SERVER, { kind = "test.ok", value = 3 }).reason, "test-auto:3")
		local r1 = s:applyCommand(SERVER, { kind = "test.nope" })
		t.ok(not r1.ok and string.find(r1.reason, "unsupported"), "unknown kinds are refused")
		local r2 = s:applyCommand(SERVER, { kind = "test.throws" })
		t.ok(not r2.ok and string.find(r2.reason, "boom"), "handler errors become refusals")
		local r3 = s:applyCommand(SERVER, { kind = "test.junk" })
		t.ok(not r3.ok and string.find(r3.reason, "no CommandResult"), "bad handler results are refused")
	end,

	["System.new rejects non-classes and mixin never overrides"] = function(t)
		t.throws(function()
			System.new({})
		end)
		local C = System.extend({ name = "Mixed", lane = "fast", reads = {}, writes = {} })
		function C:getState()
			return { own = 1 }
		end
		System.mixin(C, {
			getState = function()
				return { mixin = 1 }
			end,
			extra = function()
				return "x"
			end,
		})
		local s = System.new(C)
		t.eq(s:getState().own, 1, "class method wins over mixin")
		t.eq(s:extra(), "x", "mixin adds missing methods")
	end,

	["strict records catch typos in Studio"] = function(t)
		local r = System.record({ a = 1 }, true)
		t.eq(r.a, 1)
		r.a = 2
		t.eq(r.a, 2)
		t.throws(function()
			local _ = r.b
		end, "unknown key")
		t.throws(function()
			r.c = 3
		end, "unknown key")
		local loose = System.record({ a = 1 }, false)
		t.eq(loose.b, nil)
	end,

	-- Channels and ports ---------------------------------------------------------------------------------------
	["ports enforce declared reads and writes"] = function(t)
		local A = makeClass("PortA", "fast", {}, { "a.value" })
		local B = makeClass("PortB", "fast", { "a.value" }, { "b.value" })
		local p = plant({ A, B })
		resolveAndInit(p)
		local a, b = p.systems[1], p.systems[2]
		a.io:write("a.value", 7)
		t.eq(b.io:read("a.value"), 7)
		t.throws(function()
			b.io:write("a.value", 1)
		end, "does not own")
		t.throws(function()
			a.io:read("b.value")
		end, "undeclared")
		t.throws(function()
			p.channels:declare("a.value", "SomeoneElse")
		end, "both")
	end,

	["external inputs can be read but only set externally"] = function(t)
		local R = makeClass("ExtReader", "fast", { "boundary.temp" }, {})
		local p = plant({ R })
		p.channels:declareExternal("boundary.temp", 320)
		resolveAndInit(p)
		t.eq(p.systems[1].io:read("boundary.temp"), 320)
		p.channels:setExternal("boundary.temp", 330)
		t.eq(p.systems[1].io:read("boundary.temp"), 330)
		t.throws(function()
			p.channels:setExternal("nope", 1)
		end)
	end,

	-- Registry -------------------------------------------------------------------------------------------------
	["registry orders writers before readers, ties by name"] = function(t)
		local C = makeClass("Consumer", "fast", { "m.out" }, { "c.out" })
		local M = makeClass("Middle", "fast", { "s.out" }, { "m.out" })
		local S = makeClass("Source", "fast", {}, { "s.out" })
		local Z = makeClass("Zed", "fast", {}, { "z.out" })
		local Y = makeClass("Alpha", "fast", {}, { "y.out" })
		local p = plant({ C, M, S, Z, Y })
		resolveAndInit(p)
		local order = table.concat(p.registry:orderNames("fast"), ",")
		t.eq(order, "Alpha,Source,Middle,Consumer,Zed")
	end,

	["registry reports cycles and accepts lagged back-edges"] = function(t)
		local P1 = makeClass("Power", "fast", { "fuel.temp" }, { "core.power" })
		local F1 = makeClass("Fuel", "fast", { "core.power" }, { "fuel.temp" })
		local p = plant({ P1, F1 })
		t.throws(function()
			p.registry:resolve()
		end, "cycle: .*Fuel.*Power")
		local P2 = makeClass("Power", "fast", {}, { "core.power" }, { "fuel.temp" })
		local F2 = makeClass("Fuel", "fast", { "core.power" }, { "fuel.temp" })
		local q = plant({ P2, F2 })
		resolveAndInit(q)
		t.eq(table.concat(q.registry:orderNames("fast"), ","), "Power,Fuel")
	end,

	["registry rejects unknown reads, double writers, duplicate commands and faults"] = function(t)
		local R = makeClass("Lonely", "fast", { "nobody.writes" }, {})
		t.throws(function()
			plant({ R }).registry:resolve()
		end, "no system writes")
		local W1 = makeClass("WriterOne", "fast", {}, { "same.channel" })
		local W2 = makeClass("WriterTwo", "slow", {}, { "same.channel" })
		t.throws(function()
			plant({ W1, W2 }).registry:resolve()
		end, "both")
		local H1 = makeClass("HandlerOne", "fast", {}, {})
		H1.commands = { ["x.do"] = function() return { ok = true } end }
		local H2 = makeClass("HandlerTwo", "fast", {}, {})
		H2.commands = { ["x.do"] = function() return { ok = true } end }
		t.throws(function()
			plant({ H1, H2 }).registry:resolve()
		end, "handled by both")
		local F1 = makeClass("FaultOne", "fast", {}, {})
		F1.faults = { { id = "F-1", label = "a", cost = 1, arm = function() end } }
		local F2 = makeClass("FaultTwo", "fast", {}, {})
		F2.faults = { { id = "F-1", label = "b", cost = 1, arm = function() end } }
		t.throws(function()
			plant({ F1, F2 }).registry:resolve()
		end, "declared by both")
		local D = makeClass("Dup", "fast", {}, {})
		local p = plant({ D })
		t.throws(function()
			p.registry:add(System.new(D))
		end, "duplicate")
	end,

	-- Scheduler ------------------------------------------------------------------------------------------------
	["scheduler clocks and slow lane cadence (§0.2, §14.1)"] = function(t)
		local Fa = makeClass("FastSys", "fast", {}, { "f.n" })
		local Sl = makeClass("SlowSys", "slow", {}, { "s.n" })
		local p = plant({ Fa, Sl })
		resolveAndInit(p)
		for _ = 1, 25 do
			t.ok(p.scheduler:stepFast())
		end
		local c = p.scheduler.clock
		t.near(c.sim, 2.5, 1e-9, "sim time")
		t.near(c.grid, 2.5 * Config.Clocks.gridRate, 1e-9, "grid clock ×12")
		t.near(c.slow, 2.5 * Config.Clocks.slowProcessRate, 1e-9, "slow clock ×360")
		t.eq(p.systems[1].steps, 25, "fast lane every tick")
		t.eq(p.systems[2].steps, 2, "slow lane every 10th tick")
	end,

	["scheduler fails stop on a system error"] = function(t)
		local Good = makeClass("GoodSys", "fast", {}, { "g.n" })
		local Bad = System.extend({ name = "BadSys", lane = "fast", reads = {}, writes = {} })
		function Bad:step()
			error("sensor exploded")
		end
		local p = plant({ Good, Bad })
		resolveAndInit(p)
		local halted = nil
		p.bus:subscribe("SimulationHalted", function(x)
			halted = x
		end)
		t.eq(p.scheduler:stepFast(), false)
		t.ok(p.scheduler.halted and string.find(p.scheduler.halted, "BadSys"), "halt names the system")
		t.ok(halted and halted.system == "BadSys", "SimulationHalted published")
		local stepsBefore = p.systems[1].steps
		p.scheduler:advance(1.0)
		t.eq(p.systems[1].steps, stepsBefore, "nothing runs after a halt")
	end,

	["an owner reset restarts a halted plant, forgets its faults and restores its inputs (§14.6)"] = function(t)
		local Flaky = System.extend({ name = "Flaky", lane = "fast", reads = { "program.mode" }, writes = {} })
		function Flaky:init()
			self.failing = false
		end
		function Flaky:step()
			if self.failing then
				error("sensor exploded")
			end
		end
		Flaky.faults = {
			{
				id = "FLAKY",
				label = "Flaky sensor",
				cost = 1,
				arm = function(self)
					self.failing = true
				end,
			},
		}
		local p = plant({ Flaky })
		p.channels:declareExternal("program.mode", 3)
		resolveAndInit(p)
		local faults = Faults.new(p.registry, p.log, p.bus)
		t.ok(faults:arm("FLAKY", nil, SERVER).ok)
		p.channels:setExternal("program.mode", 1) -- as the dev preset does when it seats the plant at power
		t.eq(p.scheduler:stepFast(), false, "the fault halts the plant")

		-- the handler Main builds, answering the event Persistence publishes when the countdown ends
		PlantReset.new({
			registry = p.registry,
			channels = p.channels,
			scheduler = p.scheduler,
			faults = faults,
			log = p.log,
			bus = p.bus,
			ctx = { config = Config, bus = p.bus, log = p.log, clock = p.scheduler.clock, isStudio = true },
		})
		p.bus:publish("PlantReset", { requestedBy = "Owner" })

		t.eq(p.scheduler.halted, nil, "no longer halted")
		t.eq(p.scheduler.clock.sim, 0, "the clocks start again from zero")
		t.ok(not faults:isActive("FLAKY"), "no fault stays marked active on a plant that was re-initialised")
		t.eq(p.channels:get("program.mode"), 3, "the external inputs are back at their boot values")
		t.ok(p.scheduler:stepFast(), "and the plant runs")
		t.ok(faults:arm("FLAKY", nil, SERVER).ok, "the fault can be armed again")
	end,

	["an owner reset whose init fails leaves the plant halted and says why (§14.6)"] = function(t)
		local Sound = makeClass("Sound", "fast", {}, { "s.n" })
		local Fragile = makeClass("Fragile", "fast", {}, { "f.n" })
		local broken = false
		local fragileInit = Fragile.init
		function Fragile:init(ctx)
			if broken then
				error("calibration table missing")
			end
			fragileInit(self, ctx)
		end
		local p = plant({ Sound, Fragile })
		resolveAndInit(p)
		local faults = Faults.new(p.registry, p.log, p.bus)
		local reset = PlantReset.new({
			registry = p.registry,
			channels = p.channels,
			scheduler = p.scheduler,
			faults = faults,
			log = p.log,
			bus = p.bus,
			ctx = { config = Config, bus = p.bus, log = p.log, clock = p.scheduler.clock, isStudio = true },
		})
		t.ok(p.scheduler:stepFast(), "the plant runs before the reset")

		broken = true
		p.bus:publish("PlantReset", { requestedBy = "Owner" })
		local halted = p.scheduler.halted
		t.ok(halted ~= nil and string.find(halted, "calibration table missing", 1, true) ~= nil,
			`the plant stays halted, with the reason ({halted})`)
		local steps = p.systems[1].steps
		t.eq(p.scheduler:stepFast(), false, "a half-initialised plant does not run")
		t.eq(p.systems[1].steps, steps, "not even the systems that did initialise")
		local last = p.log:latest(1)[1]
		t.eq(last.kind, "plant.reinitialised")
		t.eq(last.result, "error")
		t.ok(string.find(last.detail or "", "calibration table missing", 1, true) ~= nil, "the log says why")

		-- once the fault is put right, another reset brings the plant back
		broken = false
		t.ok(reset:reinitialise(), "a reset that initialises every system")
		t.eq(p.scheduler.halted, nil, "clears the halt")
		t.ok(p.scheduler:stepFast(), "and the plant runs")
	end,

	["an owner reset announces every alarm still in as out (§14.6)"] = function(t)
		local Panel = makeClass("Panel", "fast", {}, { "a.n" })
		local p = plant({ Panel })
		resolveAndInit(p)
		PlantReset.new({
			registry = p.registry,
			channels = p.channels,
			scheduler = p.scheduler,
			faults = Faults.new(p.registry, p.log, p.bus),
			log = p.log,
			bus = p.bus,
			ctx = { config = Config, bus = p.bus, log = p.log, clock = p.scheduler.clock, isStudio = true },
		})
		local lit = {} -- the annunciator's view: tag -> in
		local outs = {}
		p.bus:subscribe("Alarm", function(a)
			if a.state == "in" then
				lit[a.tag] = true
			elseif a.state == "out" then
				lit[a.tag] = nil
				table.insert(outs, a)
			end
		end)
		-- three alarms come in; one goes out again and one is acknowledged, which leaves it in
		p.bus:publish("Alarm", { tag = "INLET-LOW", priority = 2, state = "in", text = "Core inlet low" })
		p.bus:publish("Alarm", { tag = "AUTO-ROD-BAND", priority = 2, state = "in", text = "Rods at band edge" })
		p.bus:publish("Alarm", { tag = "CORE-PROMPT", priority = 1, state = "in", text = "Prompt critical" })
		p.bus:publish("Alarm", { tag = "CORE-PROMPT", priority = 1, state = "out", text = "Prompt critical" })
		p.bus:publish("Alarm", { tag = "INLET-LOW", priority = 2, state = "ack", text = "Core inlet low" })
		table.clear(outs)

		p.bus:publish("PlantReset", { requestedBy = "Owner" })
		t.eq(next(lit), nil, "nothing is left lit on a plant that starts again as new")
		t.eq(#outs, 2, "one out for each alarm that was in, and none for one already out")
		for _, a in outs do
			t.ok(a.tag == "INLET-LOW" or a.tag == "AUTO-ROD-BAND", `out for {a.tag}`)
			t.ok(a.priority == 2 and type(a.text) == "string", "with the priority and text it came in with")
		end
		-- a second reset has nothing more to clear
		p.bus:publish("PlantReset", { requestedBy = "Owner" })
		t.eq(#outs, 2, "and a second reset announces nothing again")
	end,

	["scheduler limits catch-up and counts dropped time"] = function(t)
		local Fa = makeClass("Catch", "fast", {}, { "c.n" })
		local p = plant({ Fa })
		resolveAndInit(p)
		p.scheduler:advance(3.0) -- 30 steps owed, limit is maxCatchUpStepsPerFrame
		local limit = Config.Engineering.maxCatchUpStepsPerFrame
		t.eq(p.systems[1].steps, limit)
		t.near(p.scheduler.dropped_s, 3.0 - limit * p.scheduler.fastDt, 1e-9, "dropped time accounted")
		p.scheduler:setRate(10)
		p.scheduler:advance(0.1) -- ×10 → 10 steps owed, limit ×10
		t.eq(p.systems[1].steps, limit + 10, "rate multiplies steps")
		t.throws(function()
			p.scheduler:setRate(0.5)
		end)
	end,

	["sliced tasks respect the frame budget and refuse re-entry"] = function(t)
		local p = plant({})
		resolveAndInit(p)
		local done, result = false, nil
		local started = p.scheduler:runSliced("work", function(budget, n)
			local acc = 0
			for i = 1, n do
				acc += math.sqrt(i)
				if i % 1000 == 0 then
					budget:check()
				end
			end
			return acc
		end, function(ok, r)
			done, result = ok, r
		end, 3e6)
		t.ok(started)
		t.eq(p.scheduler:runSliced("work", function() end), false, "second request while running is skipped")
		local frames = 0
		while not done and frames < 10000 do
			p.scheduler:resumeSliced()
			frames += 1
		end
		t.ok(done, "task finished")
		t.ok(result > 0)
		t.ok(frames > 1, `work was spread over frames ({frames})`)
		local budgetMs = Config.Clocks.shapeSliceBudget_s * 1000
		local worst = p.scheduler.stats.frameSliced:max() * 1000
		t.log(string.format("frames=%d worst slice=%.2f ms (budget %.1f ms)", frames, worst, budgetMs))
		t.ok(worst < budgetMs * 3, "a slice never runs far past its budget")
		t.ok(not p.scheduler:isSlicedRunning("work"))
	end,

	-- Bus and EventLog -----------------------------------------------------------------------------------------
	["bus delivers, isolates failures and rejects unknown topics"] = function(t)
		local bus = Bus.new()
		local got = {}
		bus:subscribe("Trip", function(x)
			error("listener bug")
		end)
		local unsub = bus:subscribe("Trip", function(x)
			table.insert(got, x.reason)
		end)
		bus:publish("Trip", { reason = "PR high flux" })
		t.eq(got[1], "PR high flux")
		t.eq(bus.errors, 1)
		unsub()
		bus:publish("Trip", { reason = "again" })
		t.eq(#got, 1, "unsubscribed")
		t.throws(function()
			bus:publish("Tirp", {})
		end, "unknown bus topic")
	end,

	["event log sequences, wraps and replays"] = function(t)
		local clock = { sim = 12.5, grid = 150, slow = 0, fastTicks = 0, rate = 1 }
		local cfg = { Engineering = { eventLogCapacity = 5, eventLogPersisted = 3 } }
		local log = EventLog.new(cfg, clock)
		for i = 1, 7 do
			log:record("k" .. i, SERVER, "RX-0-RD-01", nil, "ok")
		end
		t.eq(log.seq, 7)
		local all = log:latest()
		t.eq(#all, 5, "capacity respected")
		t.eq(all[1].kind, "k3")
		t.eq(all[5].kind, "k7")
		t.eq(all[5].actor, "test-auto")
		t.eq(all[5].simTime, 12.5)
		local newer = log:since(5)
		t.eq(#newer, 2)
		t.eq(newer[1].kind, "k6")
		t.eq(#log:since(7), 0)
		local exported = log:export()
		t.eq(#exported, 3)
		local log2 = EventLog.new(cfg, clock)
		log2:import(exported)
		t.eq(log2.seq, 7, "sequence continues after a load")
		t.eq(log2:record("next", nil).seq, 8)
	end,

	-- Commands ------------------------------------------------------------------------------------------------
	["command sanitising rejects hostile input"] = function(t)
		local L = { stringMax = 64, argsMax = 8 }
		local ok = Commands.sanitize({ kind = "rod.move", target = "RX-0-RD-01", value = 5, panel = "MCR-RO-1", args = { speed = 2, bank = "A", hold = true } }, L)
		t.ok(ok and ok.kind == "rod.move" and ok.args.bank == "A")
		local bad = {
			"not a table",
			{},
			{ kind = 5 },
			{ kind = "" },
			{ kind = string.rep("x", 65) },
			{ kind = "rod move" },
			{ kind = "a", value = 0 / 0 },
			{ kind = "a", value = math.huge },
			{ kind = "a", value = "5" },
			{ kind = "a", target = {} },
			{ kind = "a", args = "x" },
			{ kind = "a", args = { ["bad key"] = 1 } },
			{ kind = "a", args = { f = function() end } },
			{ kind = "a", args = { a = 1, b = 1, c = 1, d = 1, e = 1, f = 1, g = 1, h = 1, i = 1 } },
			{ kind = "a", args = { x = string.rep("y", 65) } },
		}
		for i, raw in bad do
			local cmd, why = Commands.sanitize(raw, L)
			t.ok(cmd == nil and type(why) == "string", `hostile input #{i} rejected`)
		end
		-- the sanitised command is a copy, never the client's table
		local raw = { kind = "a", args = { v = 1 } }
		local cmd = Commands.sanitize(raw, L)
		t.ok(cmd ~= raw and cmd.args ~= raw.args)
	end,

	["a player's rate-limit bucket goes when they leave, with any refused count noted"] = function(t)
		local p = plant({})
		resolveAndInit(p)
		local cmds = Commands.new({
			config = Config,
			registry = p.registry,
			log = p.log,
			bus = p.bus,
			now = function()
				return 0
			end,
		})
		local leaver = { kind = "player", name = "Leaver", userId = 77, player = {} :: any }
		-- malformed through the burst, then throttled: all refused before routing, the first noted at once and the
		-- rest counted
		local sent = Config.Engineering.commandBurst + 5
		for _ = 1, sent do
			cmds:submit(leaver, {})
		end
		t.ok(cmds.buckets[77] ~= nil, "a bucket while they play")
		cmds:forget(leaver)
		t.eq(cmds.buckets[77], nil, "none once they have gone")
		local last = p.log:latest(1)[1]
		t.eq(last.kind, "command.refused")
		t.eq(tonumber(string.match(last.detail or "", "^(%d+)")), sent - 1, `the ones still counted are noted ({last.detail})`)
		cmds:forget(leaver) -- a second PlayerRemoving for the same player is harmless
	end,

	["commands route, check access and log every attempt (§10.7)"] = function(t)
		local Rod = System.extend({ name = "RodDesk", lane = "fast", reads = {}, writes = {} })
		Rod.commands = {
			["rod.move"] = function()
				return { ok = true }
			end,
			["reactor.trip.manual"] = function()
				return { ok = true }
			end,
		}
		function Rod:step() end
		local p = plant({ Rod })
		resolveAndInit(p)
		local panelAt = Vector3.new(0, 0, 0)
		local playerPos = Vector3.new(3, 0, 0)
		local hours: number? = 10
		local fakePlayer = {} :: any
		local now = 0
		local cmds = Commands.new({
			config = Config,
			registry = p.registry,
			log = p.log,
			bus = p.bus,
			panelPosition = function(tag)
				return if tag == "MCR-RO-1" then panelAt else nil
			end,
			characterPosition = function()
				return playerPos
			end,
			playtimeHours = function()
				return hours
			end,
			now = function()
				return now
			end,
		})
		local actor = { kind = "player", name = "Tester", userId = 42, player = fakePlayer }

		t.ok(cmds:submit(actor, { kind = "rod.move", panel = "MCR-RO-1", value = 1 }).ok, "in reach")
		local r = cmds:submit(actor, { kind = "rod.move", value = 1 })
		t.ok(not r.ok and string.find(r.reason, "no panel"))
		r = cmds:submit(actor, { kind = "rod.move", panel = "NOWHERE" })
		t.ok(not r.ok and string.find(r.reason, "unknown panel"))
		playerPos = Vector3.new(Config.Access.panelReach_studs + 1, 0, 0)
		r = cmds:submit(actor, { kind = "rod.move", panel = "MCR-RO-1" })
		t.ok(not r.ok and string.find(r.reason, "out of reach"))
		playerPos = Vector3.new(1, 0, 0)
		r = cmds:submit(actor, { kind = "turbine.explode", panel = "MCR-RO-1" })
		t.ok(not r.ok and string.find(r.reason, "no system handles"))

		t.ok(cmds:isCritical("reactor.trip.manual"))
		t.ok(cmds:submit(actor, { kind = "reactor.trip.manual", panel = "MCR-RO-1" }).ok, "enough playtime")
		hours = Config.Access.criticalMinimumPlaytime_h - 0.5
		r = cmds:submit(actor, { kind = "reactor.trip.manual", panel = "MCR-RO-1" })
		t.ok(not r.ok and string.find(r.reason, "playtime"), "critical control needs playtime")
		t.ok(cmds:submit(actor, { kind = "rod.move", panel = "MCR-RO-1" }).ok, "non-critical control unaffected")

		-- server-internal actors skip reach and playtime
		t.ok(cmds:submit(SERVER, { kind = "reactor.trip.manual" }).ok)

		-- every attempt is in the log with the actor's name
		local entries = p.log:latest()
		t.eq(#entries, 9)
		local denied = 0
		for _, e in entries do
			if string.sub(e.result, 1, 6) == "denied" then
				denied += 1
				t.eq(e.actor, "Tester")
			end
		end
		t.eq(denied, 5)

		-- rate limit: burst then refuse, then refill with time
		now = 100
		local okCount = 0
		for _ = 1, Config.Engineering.commandBurst + 5 do
			if cmds:submit(actor, { kind = "rod.move", panel = "MCR-RO-1" }).ok then
				okCount += 1
			end
		end
		t.eq(okCount, Config.Engineering.commandBurst, "burst allowance")
		now += 1
		t.ok(cmds:submit(actor, { kind = "rod.move", panel = "MCR-RO-1" }).ok, "tokens refill over time")
	end,

	["a sustained flood writes one note per window for refusals, and the rate limit bounds the rest (§10.7)"] = function(t)
		-- one desk system, so part of the flood is routed: a control attempt refused at the panel is a §10.7 record
		local Rod = System.extend({ name = "RodDesk", lane = "fast", reads = {}, writes = {} })
		Rod.commands = {
			["rod.move"] = function()
				return { ok = true }
			end,
		}
		function Rod:step() end
		local p = plant({ Rod })
		resolveAndInit(p)
		local now = 0
		-- no panelPosition service, so every panel is unknown and every routed command is refused at the panel
		local cmds = Commands.new({
			config = Config,
			registry = p.registry,
			log = p.log,
			bus = p.bus,
			now = function()
				return now
			end,
		})
		local flooder = { kind = "player", name = "Flooder", userId = 66, player = {} :: any }
		local E = Config.Engineering
		local window = E.commandRefusalNote_s
		local seconds = 60

		-- a minute of refusals that are not control actions, a thousand a second: malformed, unhandled, rich text
		local before = p.log.seq
		local sent = 0
		for step = 0, seconds * 10 - 1 do
			now = step / 10
			for i = 1, 100 do
				local raw = if i % 3 == 0 then {} elseif i % 3 == 1 then { kind = "reactor.explode" } else { kind = "<b>tripped by Tester</b>" }
				cmds:submit(flooder, raw)
				sent += 1
			end
		end
		local written = p.log.seq - before
		local bound = math.floor(seconds / window) + 1 -- a note at the first refusal, then at most one per window
		t.ok(written <= bound, `{sent} refusals over {seconds} s wrote {written} records, not at most {bound}`)
		cmds:forget(flooder) -- the refusals of the last, unfinished window are noted as the player leaves
		local counted = 0
		for _, e in p.log:latest(p.log.seq - before) do
			t.eq(e.kind, "command.refused", "notes only: no record per refusal, and no client text")
			counted += tonumber(string.match(e.detail or "", "^(%d+)")) or 0
		end
		t.eq(counted, sent, "and the notes account for every refused command")

		-- a minute of control attempts refused at the panel: each one is a control attempt, so each is logged, and
		-- the rate limit is what bounds them (plus the notes for the commands it throttles)
		before = p.log.seq
		for step = 0, seconds * 10 - 1 do
			now = 1000 + step / 10
			for _ = 1, 100 do
				cmds:submit(flooder, { kind = "rod.move", panel = "NOWHERE" })
			end
		end
		written = p.log.seq - before
		bound = E.commandBurst + E.commandRate_perSecond * seconds + math.floor(seconds / window) + 1
		t.ok(written <= bound, `a minute of routed commands wrote {written} records, not at most {bound}`)
	end,

	["critical access policy when the playtime lookup fails"] = function(t)
		local required = Config.Access.criticalMinimumPlaytime_h
		t.eq(Commands.criticalAccess(required, required), true)
		local ok, reason = Commands.criticalAccess(required - 1, required)
		t.ok(not ok and type(reason) == "string")
		local okCall, allowed, why = pcall(Commands.criticalAccess, nil, required)
		if not okCall and string.find(tostring(allowed), "TODO%(human%)") then
			t.pending("waiting for Aqua's policy (TODO(human) in Framework/Commands.criticalAccess)")
		end
		t.ok(okCall, tostring(allowed))
		t.eq(type(allowed), "boolean", "policy returns a boolean")
		if not allowed then
			t.eq(type(why), "string", "a refusal explains itself")
		end
	end,

	-- Faults --------------------------------------------------------------------------------------------------
	["faults arm, clear and respect eligibility"] = function(t)
		local Pump = System.extend({ name = "PumpSys", lane = "fast", reads = {}, writes = {} })
		function Pump:step() end
		function Pump:init()
			self.tripped = false
		end
		local eligibleNow = true
		Pump.faults = {
			{
				id = "S-07",
				label = "Primary pump trip with stuck check valve",
				cost = 3,
				eligible = function()
					return eligibleNow
				end,
				arm = function(self)
					self.tripped = true
				end,
				clear = function(self)
					self.tripped = false
				end,
			},
		}
		local p = plant({ Pump })
		resolveAndInit(p)
		local faults = Faults.new(p.registry, p.log, p.bus)
		local armedEvents = 0
		p.bus:subscribe("FaultArmed", function()
			armedEvents += 1
		end)
		t.eq(#faults:list(), 1)
		t.eq(faults:list()[1].system, "PumpSys")
		eligibleNow = false
		t.ok(not faults:arm("S-07").ok, "ineligible fault refused")
		eligibleNow = true
		t.ok(faults:arm("S-07", nil, SERVER).ok)
		t.ok(p.systems[1].tripped, "arm started a real event in the system")
		t.ok(faults:isActive("S-07"))
		t.ok(not faults:arm("S-07").ok, "already active")
		t.eq(armedEvents, 1)
		t.ok(faults:clear("S-07").ok)
		t.ok(not p.systems[1].tripped)
		t.ok(not faults:clear("S-07").ok, "not active")
		t.ok(not faults:arm("S-99").ok, "unknown id")
	end,

	["a fault clears the target it was armed on, not a default (§13.1)"] = function(t)
		-- the shape of RD-STUCK, IHX-SHUT, NI-FAIL and PROT-CHANNEL: params name the target, with a default
		local Rack = System.extend({ name = "Rack", lane = "fast", reads = {}, writes = {} })
		function Rack:step() end
		function Rack:init()
			self.failed = {}
		end
		Rack.faults = {
			{
				id = "RACK-FAIL",
				label = "Channel failure",
				cost = 1,
				arm = function(self, params)
					self.failed[(params and params.channel) or "A"] = true
				end,
				clear = function(self, params)
					self.failed[(params and params.channel) or "A"] = nil
				end,
			},
		}
		local p = plant({ Rack })
		resolveAndInit(p)
		local faults = Faults.new(p.registry, p.log, p.bus)
		local rack = p.systems[1]
		t.ok(faults:arm("RACK-FAIL", { channel = "B" }, SERVER).ok)
		t.ok(rack.failed.B, "armed on channel B")
		t.ok(faults:clear("RACK-FAIL", SERVER).ok)
		t.eq(rack.failed.B, nil, "clearing the fault restores channel B")
		t.ok(not faults:isActive("RACK-FAIL"))
	end,

	-- Packets and tags ----------------------------------------------------------------------------------------
	["gauge packets round-trip and respect the byte budget"] = function(t)
		local ids, values = {}, {}
		for i = 1, 300 do
			ids[i] = i
			values[i] = i * 1.25 - 100
		end
		values[7] = 1e-8
		values[8] = 2380
		local budget = Config.Engineering.unreliablePacketBudget_bytes
		local packets = Packets.chunkGauges(9, ids, values, budget)
		local seen = 0
		for _, b in packets do
			t.ok(buffer.len(b) <= budget, "packet within budget")
			local version, pid, pval = Packets.unpackGauges(b)
			t.eq(version, 9)
			for k = 1, #pid do
				seen += 1
				local want = values[pid[k]]
				t.near(pval[k], want, math.abs(want) * 1e-6 + 1e-12, `gauge {pid[k]} value`)
			end
		end
		t.eq(seen, 300)
		t.log(`{#packets} packets for 300 gauges at {budget} bytes`)
	end,

	["core map packet matches §14.1 (331 × u16 at 0.05 K)"] = function(t)
		local res = Config.Engineering.coreMapResolution_K
		local temps = {}
		for i = 1, Config.Core.totals.corePositions do
			temps[i] = 648.15 + i * 0.37
		end
		temps[1] = -5 -- clamps
		temps[2] = 99999 -- clamps
		local b = Packets.packCoreMap(temps, res)
		t.eq(buffer.len(b) - Packets.COREMAP_HEADER, 662, "payload bytes")
		local back = Packets.unpackCoreMap(b, res)
		t.eq(#back, 331)
		t.eq(back[1], 0)
		t.near(back[2], 65535 * res, 1e-9)
		for i = 3, 331 do
			t.near(back[i], temps[i], res / 2 + 1e-9, `temperature {i}`)
		end
	end,

	["tags follow Appendix B"] = function(t)
		t.eq(Tags.format("SG", 2, "HM", 5), "SG-2-HM-05")
		local tag = Tags.parse("SG-2-HM-05")
		t.ok(tag and tag.system == "SG" and tag.loop == 2 and tag.kind == "HM" and tag.index == 5)
		t.ok(Tags.isValid("RX-0-TC-331"))
		t.ok(not Tags.isValid("XX-0-TC-01"), "unknown system")
		t.ok(not Tags.isValid("SG-2-ZZ-01"), "unknown type")
		t.ok(not Tags.isValid("sg-2-HM-05"))
		t.throws(function()
			Tags.format("SG", 10, "HM", 1)
		end)
	end,

	-- Persistence ---------------------------------------------------------------------------------------------
	["persistence saves, loads and migrates (§14.6)"] = function(t)
		local Keeper = System.extend({ name = "Keeper", lane = "slow", reads = {}, writes = {} })
		function Keeper:init()
			self.burnup = 0
		end
		function Keeper:step() end
		function Keeper:save()
			return { burnup = self.burnup }
		end
		function Keeper:load(data, version)
			self.burnup = data.burnup
			self.loadedAs = version
		end
		local p = plant({ Keeper })
		resolveAndInit(p)
		local store = Persistence.MemoryStore.new()
		local function persist(plantObj, extra)
			local o = {
				config = Config,
				registry = plantObj.registry,
				log = plantObj.log,
				bus = plantObj.bus,
				clock = plantObj.scheduler.clock,
				store = store,
				mode = "private",
				key = "plant/test",
				ownerUserId = 99,
			}
			for k, v in extra or {} do
				o[k] = v
			end
			return Persistence.new(o)
		end
		local pers = persist(p)
		p.systems[1].burnup = 42.5
		p.scheduler.clock.sim = 1234
		p.log:record("before-save", SERVER)
		t.ok(pers:save())

		local q = plant({ Keeper })
		resolveAndInit(q)
		t.eq(persist(q):load(), "loaded")
		t.eq(q.systems[1].burnup, 42.5, "system slice restored")
		t.eq(q.scheduler.clock.sim, 1234, "clock restored")
		-- load() records its own "load" entry, so a sequence number alone would pass with nothing imported
		local restored = false
		for _, e in q.log:latest() do
			if e.kind == "before-save" then
				restored = true
			end
		end
		t.ok(restored, "event log restored")

		-- a version-1 save migrated to a hypothetical version 3
		local migrated = plant({ Keeper })
		resolveAndInit(migrated)
		local pers3 = persist(migrated, {
			currentVersion = 3,
			migrations = {
				[1] = function(d)
					d.systems.Keeper.burnup += 1
					return d
				end,
				[2] = function(d)
					d.systems.Keeper.burnup *= 2
					return d
				end,
			},
		})
		t.eq(pers3:load(), "loaded")
		t.eq(migrated.systems[1].burnup, (42.5 + 1) * 2, "migrations applied in order")
		t.eq(migrated.systems[1].loadedAs, 3, "and the system is told the version its slice is now in, not the old one")
		local gap = persist(plant({}), { currentVersion = 3, migrations = {} })
		t.throws(function()
			gap:load()
		end, "no migration")

		-- public servers never persist
		local public = persist(plant({}), { mode = "public" })
		t.eq(public:load(), "fresh")
		t.eq(public:save(), false)
	end,

	["a plant that could not be loaded is never overwritten (§14.6)"] = function(t)
		local p = plant({})
		resolveAndInit(p)
		local writes = 0
		local stored: any = { version = Persistence.CURRENT_VERSION + 1, systems = {} } -- written by a newer server
		local store: any = {}
		function store.get(_self: any, _key: string)
			return true, stored
		end
		function store.set(_self: any, _key: string, value: any)
			writes += 1
			stored = value
			return true, nil
		end
		function store.remove(_self: any, _key: string)
			stored = nil
			return true, nil
		end
		local function persist(backing: any)
			return Persistence.new({
				config = Config,
				registry = p.registry,
				log = p.log,
				bus = p.bus,
				clock = p.scheduler.clock,
				store = backing,
				mode = "private",
				key = "plant/unreadable",
				ownerUserId = 7,
			})
		end
		local pers = persist(store)
		t.ok(not pcall(pers.load, pers), "a save from a newer server does not load")
		pers.sinceSave = Config.Engineering.saveInterval_s
		pers:tick(Config.Engineering.serverFrame_s)
		t.eq(writes, 0, "the autosave does not replace it")
		t.ok(not (pers:save()), "nor does any other save")
		t.eq(stored.version, Persistence.CURRENT_VERSION + 1, "the save this server could not read is still there")

		-- a store that cannot be read at all at boot is the same case
		local outage: any = {}
		function outage.get(_self: any, _key: string)
			return false, "DataStore outage"
		end
		function outage.set(_self: any, _key: string, _value: any)
			writes += 1
			return true, nil
		end
		function outage.remove(_self: any, _key: string)
			return true, nil
		end
		local blind = persist(outage)
		t.ok(not pcall(blind.load, blind), "an outage at boot does not load")
		t.ok(not (blind:save()), "and the fresh plant is not saved over the real one")
		t.eq(writes, 0)

		-- the owner can still choose to start over, and from then on the plant saves normally
		local owner = { kind = "player", name = "Owner", userId = 7 }
		t.ok(pers:requestReset(owner, Config.Engineering.resetConfirmationPhrase).ok)
		for _ = 1, Config.Access.reset.countdown_s do
			pers:tick(1)
		end
		t.eq(stored, nil, "the reset cleared the old save")
		t.ok((pers:save()), "and the new plant saves")
		t.eq(writes, 1)
	end,

	["owner reset needs the owner, the phrase and a countdown"] = function(t)
		local p = plant({})
		resolveAndInit(p)
		local store = Persistence.MemoryStore.new()
		store:set("plant/r", { version = 1, systems = {} })
		local pers = Persistence.new({
			config = Config,
			registry = p.registry,
			log = p.log,
			bus = p.bus,
			clock = p.scheduler.clock,
			store = store,
			mode = "private",
			key = "plant/r",
			ownerUserId = 7,
		})
		local owner = { kind = "player", name = "Owner", userId = 7 }
		local stranger = { kind = "player", name = "Stranger", userId = 8 }
		local phrase = Config.Engineering.resetConfirmationPhrase
		t.ok(not pers:requestReset(stranger, phrase).ok, "only the owner")
		t.ok(not pers:requestReset(owner, "reset").ok, "exact phrase required")
		local announced, resets = {}, 0
		p.bus:subscribe("ResetCountdown", function(x)
			table.insert(announced, x.secondsLeft)
		end)
		p.bus:subscribe("PlantReset", function()
			resets += 1
		end)
		t.ok(pers:requestReset(owner, phrase).ok)
		t.ok(not pers:requestReset(owner, phrase).ok, "no double countdown")
		local countdown = Config.Access.reset.countdown_s
		for _ = 1, countdown * 2 - 1 do
			pers:tick(0.5)
		end
		t.eq(resets, 0, "not yet")
		local _, stillThere = store:get("plant/r")
		t.ok(stillThere ~= nil, "save kept during the countdown")
		pers:tick(0.5)
		t.eq(resets, 1, "reset fires at zero")
		local _, gone = store:get("plant/r")
		t.eq(gone, nil, "save cleared")
		t.eq(announced[1], countdown, "countdown announced from the start")
		t.eq(announced[#announced], 0)
		t.eq(#announced, countdown + 1, "announced once per second")
		-- cancel path
		t.ok(pers:requestReset(owner, phrase).ok)
		t.ok(not pers:cancelReset(stranger).ok)
		t.ok(pers:cancelReset(owner).ok)
		for _ = 1, countdown * 3 do
			pers:tick(1)
		end
		t.eq(resets, 1, "cancelled reset never fires")
	end,

	["an autosave is one write at a time, however many frames the write takes (§14.6)"] = function(t)
		local p = plant({})
		resolveAndInit(p)
		-- SetAsync yields, and Heartbeat keeps firing while it does, each frame calling tick on a thread of its own
		local store: any = { data = {}, inFlight = 0, most = 0, writes = 0 }
		function store.get(self: any, key: string)
			return true, self.data[key]
		end
		function store.set(self: any, key: string, value: any)
			self.inFlight += 1
			self.most = math.max(self.most, self.inFlight)
			self.writes += 1
			task.wait()
			self.data[key] = value
			self.inFlight -= 1
			return true, nil
		end
		function store.remove(self: any, key: string)
			self.data[key] = nil
			return true, nil
		end
		local pers = Persistence.new({
			config = Config,
			registry = p.registry,
			log = p.log,
			bus = p.bus,
			clock = p.scheduler.clock,
			store = store,
			mode = "private",
			key = "plant/slow",
			ownerUserId = 7,
		})
		local frame = Config.Engineering.serverFrame_s
		pers.sinceSave = Config.Engineering.saveInterval_s
		for _ = 1, 10 do
			task.spawn(pers.tick, pers, frame)
		end
		t.eq(store.writes, 1, "the frames that ran during the write started no more writes of the key")
		local frames = 0
		while store.inFlight > 0 and frames < 100 do
			task.wait()
			frames += 1
		end
		t.eq(store.most, 1, "never two writes of the key at once")
		t.ok(store.data["plant/slow"] ~= nil, "and the one write landed")
	end,

	["a save in flight lands before an owner reset removes the plant, never after (§14.6)"] = function(t)
		local p = plant({})
		resolveAndInit(p)
		local store: any = { data = {}, inFlight = 0 }
		function store.get(self: any, key: string)
			return true, self.data[key]
		end
		function store.set(self: any, key: string, value: any)
			self.inFlight += 1
			task.wait()
			self.data[key] = value
			self.inFlight -= 1
			return true, nil
		end
		function store.remove(self: any, key: string)
			self.data[key] = nil
			return true, nil
		end
		local pers = Persistence.new({
			config = Config,
			registry = p.registry,
			log = p.log,
			bus = p.bus,
			clock = p.scheduler.clock,
			store = store,
			mode = "private",
			key = "plant/r2",
			ownerUserId = 7,
		})
		local owner = { kind = "player", name = "Owner", userId = 7 }
		local frame = Config.Engineering.serverFrame_s
		local reset = false
		p.bus:subscribe("PlantReset", function()
			reset = true
		end)
		t.ok(pers:requestReset(owner, Config.Engineering.resetConfirmationPhrase).ok)
		pers.sinceSave = Config.Engineering.saveInterval_s
		task.spawn(pers.tick, pers, frame) -- the autosave starts writing the plant as it stands
		t.eq(store.inFlight, 1, "a write is in flight")
		-- the countdown runs out on the very next frame, which is not itself an autosave frame
		pers.reset.remaining = 0
		pers.sinceSave = 0
		task.spawn(pers.tick, pers, frame)
		local frames = 0
		while (not reset or store.inFlight > 0) and frames < 100 do
			task.wait()
			frames += 1
		end
		t.eq(store.data["plant/r2"], nil, "the reset removed the plant after that write, so the old plant is gone")
	end,

	["an owner reset whose remove raises still frees the store for the next save (§14.6)"] = function(t)
		local p = plant({})
		resolveAndInit(p)
		local store: any = { data = { ["plant/r3"] = { old = true } } }
		function store.get(self: any, key: string)
			return true, self.data[key]
		end
		function store.set(self: any, key: string, value: any)
			self.data[key] = value
			return true, nil
		end
		function store.remove(_self: any, _key: string)
			error("RemoveAsync: 502 service unavailable")
		end
		local pers = Persistence.new({
			config = Config,
			registry = p.registry,
			log = p.log,
			bus = p.bus,
			clock = p.scheduler.clock,
			store = store,
			mode = "private",
			key = "plant/r3",
			ownerUserId = 7,
		})
		local owner = { kind = "player", name = "Owner", userId = 7 }
		local reset = false
		p.bus:subscribe("PlantReset", function()
			reset = true
		end)
		t.ok(pers:requestReset(owner, Config.Engineering.resetConfirmationPhrase).ok)
		pers.reset.remaining = 0
		local ok, err = pcall(pers.tick, pers, Config.Engineering.serverFrame_s)
		t.ok(ok, `the failed remove does not escape the tick ({err})`)
		t.eq(pers.saving, false, "no write is left marked in flight")
		local failed = false
		for _, e in p.log:latest() do
			failed = failed or (e.kind == "plant.reset" and e.result == "error" and string.find(e.detail or "", "502", 1, true) ~= nil)
		end
		t.ok(failed, "the log says the stored plant could not be removed, and why")
		t.ok(reset, "the owner's reset still happens")
		-- the next save is not held behind a write that never finished, and it replaces the old plant
		local done = false
		task.spawn(function()
			t.ok(pers:save(), "the next save goes through")
			done = true
		end)
		t.ok(done, "without waiting on anything")
		t.eq(store.data["plant/r3"].old, nil, "and the old plant is gone")
	end,

	["a DataStore call is retried with backoff, and nothing waits after the last try"] = function(t)
		local calls, waits = 0, {}
		local backend = setmetatable({
			ds = {
				GetAsync = function()
					calls += 1
					error("DataStore outage")
				end,
			},
			retries = 2,
			wait = function(s: number)
				table.insert(waits, s)
			end,
		}, Persistence.DataStoreBackend) :: any
		local ok = backend:get("plant/x")
		t.eq(ok, false, "the outage is reported")
		t.eq(calls, 2, "after every try")
		t.eq(#waits, 1, "with a backoff between the tries and none after the last")
		t.eq(waits[1], 2, "2 s before the second try")
	end,
}
