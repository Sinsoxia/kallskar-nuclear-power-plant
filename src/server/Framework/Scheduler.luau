--!strict
--[[
	Scheduler — fixed-step simulation loop (spec §14.1).
	=====================================================

	- Fast lane at Config.Clocks.fast_Hz (10 Hz); slow lane every (fast_Hz / slow_Hz) fast steps (1 Hz).
	- Heartbeat feeds an accumulator. At most Engineering.maxCatchUpStepsPerFrame × rate steps run per frame; any
	  time beyond that is dropped and counted (logged), so an overloaded server degrades instead of spiralling.
	- Sliced lane: long computations (the 3D flux shape solve, §14.2) run as coroutines resumed every frame with a
	  time budget of Clocks.shapeSliceBudget_s. They call budget:check() in their loops, which yields once the budget
	  is spent. Requesting a sliced task that is still running is refused (skipped, not queued).
	- Fail-stop: if any system errors during a step, the scheduler halts with the system name and error, because a
	  half-updated plant state is worse than a stopped one. `halted` holds the reason.
	- stepFast()/advance() can be driven manually (no Heartbeat) for deterministic tests.
]]
local RunService = game:GetService("RunService")

local Scheduler = {}
Scheduler.__index = Scheduler

-- Rolling timing window with percentile queries (sorting happens only when stats are requested).
local Window = {}
Window.__index = Window

function Window.new(size: number)
	return setmetatable({ size = size, n = 0, i = 0, data = table.create(size, 0) }, Window)
end

function Window.push(self: any, v: number)
	self.i = self.i % self.size + 1
	self.data[self.i] = v
	if self.n < self.size then
		self.n += 1
	end
end

function Window.percentile(self: any, p: number): number
	if self.n == 0 then
		return 0
	end
	local copy = table.move(self.data, 1, self.n, 1, table.create(self.n))
	table.sort(copy)
	local idx = math.clamp(math.ceil(p * self.n), 1, self.n)
	return copy[idx]
end

function Window.max(self: any): number
	local m = 0
	for k = 1, self.n do
		if self.data[k] > m then
			m = self.data[k]
		end
	end
	return m
end

-- Budget handed to sliced tasks
local Budget = {}
Budget.__index = Budget

function Budget.check(self: any)
	if os.clock() > self.deadline then
		self.yields += 1
		coroutine.yield()
	end
end

function Scheduler.new(registry: any, config: any, bus: any?, log: any?)
	local self = setmetatable({}, Scheduler)
	local clocks = config.Clocks
	self.registry = registry
	self.bus = bus
	self.log = log
	self.fastDt = 1 / clocks.fast_Hz
	self.slowEvery = math.floor(clocks.fast_Hz / clocks.slow_Hz + 0.5)
	self.slowDt = self.fastDt * self.slowEvery
	self.gridRate = clocks.gridRate
	self.slowRate = clocks.slowProcessRate
	self.sliceBudget = clocks.shapeSliceBudget_s
	self.maxCatchUp = config.Engineering.maxCatchUpStepsPerFrame
	self.clock = { sim = 0, grid = 0, slow = 0, fastTicks = 0, rate = 1 }
	self.acc = 0
	self.dropped_s = 0
	self.halted = nil :: string?
	self.stats = {
		fast = Window.new(600),
		slow = Window.new(60),
		frameSliced = Window.new(600),
	}
	self.systemTime = {} :: { [string]: number }
	self.sliced = {} :: { [string]: any }
	self.connection = nil :: RBXScriptConnection?
	return self
end

--[[
	Start the clocks again from zero, for an owner reset (§14.6). A sliced task still working on the old plant is
	dropped. The clock rate is a session setting, not plant state, and is kept. A halt is not cleared here: the reset
	is how an owner recovers a halted plant, but only once every system has initialised again (Framework/PlantReset).
]]
function Scheduler.restart(self: any)
	local clock = self.clock
	clock.sim, clock.grid, clock.slow, clock.fastTicks = 0, 0, 0, 0
	self.acc = 0
	table.clear(self.sliced)
end

function Scheduler.setRate(self: any, rate: number)
	assert(rate >= 1 and rate % 1 == 0, "rate must be a positive integer multiple of real time")
	self.clock.rate = rate
end

local function runLane(self: any, lane: string, dt: number): boolean
	local systems = self.registry.order[lane]
	local times = self.systemTime
	for i = 1, #systems do
		local sys = systems[i]
		local t0 = os.clock()
		local ok, err = pcall(sys.step, sys, dt)
		local name = sys.spec.name
		times[name] = (times[name] or 0) + (os.clock() - t0)
		if not ok then
			self.halted = `{name}.step failed at sim t={string.format("%.1f", self.clock.sim)} s: {tostring(err)}`
			warn(`[Kallskar] SIMULATION HALTED: {self.halted}`)
			if self.log then
				self.log:record("sim.halted", nil, name, tostring(err), "error")
			end
			if self.bus then
				self.bus:publish("SimulationHalted", { system = name, error = tostring(err) })
			end
			return false
		end
	end
	return true
end

function Scheduler.stepFast(self: any): boolean
	if self.halted then
		return false
	end
	local dt = self.fastDt
	local clock = self.clock
	clock.sim += dt
	clock.grid += dt * self.gridRate
	clock.slow += dt * self.slowRate
	clock.fastTicks += 1

	local t0 = os.clock()
	if not runLane(self, "fast", dt) then
		return false
	end
	self.stats.fast:push(os.clock() - t0)

	if clock.fastTicks % self.slowEvery == 0 then
		local t1 = os.clock()
		if not runLane(self, "slow", self.slowDt) then
			return false
		end
		self.stats.slow:push(os.clock() - t1)
	end
	return true
end

-- Sliced tasks ------------------------------------------------------------------------------------------------

--[[
	Start a sliced computation. `fn(budget, ...)` runs in a coroutine and should call budget:check() regularly.
	`onDone(ok, result)` is called when it finishes. Returns false (and does nothing) if a task with this name is
	still running.
]]
function Scheduler.runSliced(self: any, name: string, fn: (any, ...any) -> any, onDone: ((boolean, any) -> ())?, ...: any): boolean
	if self.sliced[name] then
		return false
	end
	local budget = setmetatable({ deadline = 0, yields = 0 }, Budget)
	local args = table.pack(...)
	local co = coroutine.create(function()
		return fn(budget, table.unpack(args, 1, args.n))
	end)
	self.sliced[name] = { co = co, budget = budget, onDone = onDone, started = self.clock.sim, frames = 0 }
	return true
end

function Scheduler.isSlicedRunning(self: any, name: string): boolean
	return self.sliced[name] ~= nil
end

function Scheduler.resumeSliced(self: any)
	local frameStart = os.clock()
	for name, task in self.sliced do
		task.budget.deadline = frameStart + self.sliceBudget
		task.frames += 1
		local ok, result = coroutine.resume(task.co)
		if not ok then
			self.sliced[name] = nil
			warn(`[Kallskar] sliced task '{name}' failed: {tostring(result)}`)
			if task.onDone then
				task.onDone(false, result)
			end
		elseif coroutine.status(task.co) == "dead" then
			self.sliced[name] = nil
			if task.onDone then
				task.onDone(true, result)
			end
		end
		if os.clock() - frameStart > self.sliceBudget then
			break -- remaining tasks get their turn next frame
		end
	end
	self.stats.frameSliced:push(os.clock() - frameStart)
end

-- Frame driver --------------------------------------------------------------------------------------------------

-- The accumulator counts in fast ticks, not seconds: repeatedly subtracting 0.1 s drifts in floating point
-- (1.0 − 9 × 0.1 = 0.0999…), which would silently lose steps. TICK_EPS absorbs that rounding.
local TICK_EPS = 1e-9

function Scheduler.advance(self: any, frameDt: number)
	if self.halted then
		return
	end
	local rate = self.clock.rate
	self.acc += frameDt * rate / self.fastDt
	local limit = self.maxCatchUp * rate
	local n = 0
	while self.acc >= 1 - TICK_EPS and n < limit do
		if not self:stepFast() then
			return
		end
		self.acc -= 1
		n += 1
	end
	if self.acc >= 1 - TICK_EPS then
		local lostTicks = math.floor(self.acc + TICK_EPS)
		local lost = lostTicks * self.fastDt
		self.dropped_s += lost
		self.acc = math.max(0, self.acc - lostTicks)
		if self.log then
			self.log:record("sim.overrun", nil, nil, string.format("dropped %.2f s of simulated time", lost), "warn")
		end
	end
	self:resumeSliced()
end

function Scheduler.start(self: any)
	assert(self.connection == nil, "scheduler already started")
	self.connection = RunService.Heartbeat:Connect(function(dt)
		self:advance(dt)
	end)
end

function Scheduler.stop(self: any)
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
end

function Scheduler.report(self: any): { [string]: any }
	return {
		simTime = self.clock.sim,
		fastTicks = self.clock.fastTicks,
		rate = self.clock.rate,
		fastP50_ms = self.stats.fast:percentile(0.5) * 1000,
		fastP99_ms = self.stats.fast:percentile(0.99) * 1000,
		fastMax_ms = self.stats.fast:max() * 1000,
		slowP99_ms = self.stats.slow:percentile(0.99) * 1000,
		slicedP99_ms = self.stats.frameSliced:percentile(0.99) * 1000,
		dropped_s = self.dropped_s,
		halted = self.halted,
	}
end

return Scheduler
