--!strict
--[[
	IHX — the six intermediate heat exchangers, primary side, and the M1 secondary boundary (spec §4.3).
	=====================================================================================================

	Six counter-flow exchangers, 1A/1B on secondary loop 1 and so on: primary sodium down the shell from the hot
	pool, secondary sodium up the tubes. Each one's duty comes from **ε-NTU**, not from §4.3's 396 MWt, which is
	only the value at the design point:

	  C_p = ṁ_p·c_p,  C_s = ṁ_s·c_p,  NTU = UA / C_min,  Cr = C_min / C_max
	  ε   = (1 − e^(−NTU(1−Cr))) / (1 − Cr·e^(−NTU(1−Cr)))      (counter-flow; NTU/(1+NTU) when Cr → 1)
	  Q   = ε · C_min · (T_p,in − T_s,in)

	Driven by §4.3's UA alone, that reproduces every other figure in §4.3 — 396.9 MWt, 374.6 °C primary out,
	519.6 °C secondary out, LMTD 41.3 K — and it stays well behaved where `Q = UA·LMTD` cannot be solved: a stopped
	secondary loop (C_s = 0, so Q = 0), a shutter at its leak-by, and natural circulation, where ε reaches 1 and the
	primary leaves at the secondary inlet temperature. See tools/derive/ihx.py.

	That last regime is the reason for the method. At half primary flow the duty falls to 258 MWt but the primary
	outlet drops to 323 °C, because each kilogram spends twice as long against the same 2,000 m²: the exchanger is
	area-limited at power and thermodynamically limited on natural circulation. A model carrying a constant duty, or
	a constant 175 K drop, would get a station blackout exactly backwards.

	UA is held at §4.3's value (D-022). The published LMTD is Q/UA, which is its definition and is always finite;
	the log form of the four temperatures is a check in the tests, not a thing the system depends on.

	Primary flow splits between the units by their inlet shutters: equal parallel paths, weighted by shutter
	opening, always summing to the flow the pumps deliver. The shutter strokes over §4.3's 60 s between fully open
	and its 5 % leak-by. It exists so that a unit whose secondary loop is gone cannot dump hot pool sodium straight
	into the cold pool.

	The M1 secondary boundary (per the milestone plan): each loop holds its inlet temperature and per-unit flow at
	§4.3's 320 °C and 1,556 kg/s, adjustable by command so inlet-temperature feedback and loop loss can be driven
	from the debug panel. The real secondary loops, their pumps and the steam generators arrive in a later
	milestone; nothing here models them.

	Inputs:  pools.hotPool_K         primary inlet, the second hot-pool node
	         primary.coreFlow_kgps   total primary flow, split between the units
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Sodium = require(Kallskar:WaitForChild("Props"):WaitForChild("Sodium"))
local Types = require(Kallskar:WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local IHX = System.extend({
	name = "IHX",
	lane = "fast",
	reads = { "pools.hotPool_K", "primary.coreFlow_kgps" },
	writes = {
		"ihx.heatRemoved_W",
		"ihx.dutyEach_W",
		"ihx.primaryOutlet_K",
		"ihx.secondaryOutlet_K",
		"ihx.primaryFlow_kgps",
		"ihx.mixedPrimaryOutlet_K",
		"ihx.lmtd_K",
		"ihx.loopsRunning",
		"ihx.unitsInService",
	},
})

local MIN_FLOW_kgps = 1e-3 -- below this a stream is stopped, and a stopped stream carries no heat

--[[
	Counter-flow effectiveness. Cr → 1 is the balanced case, where the general form is 0/0; the two branches agree
	to within rounding at the crossover, so the cut point only has to avoid the singularity.
]]
local function effectiveness(ua: number, cHot: number, cCold: number): number
	local cMin = math.min(cHot, cCold)
	local cMax = math.max(cHot, cCold)
	if cMin <= 0 then
		return 0
	end
	local ntu = ua / cMin
	local cr = cMin / cMax
	if cr > 0.999999 then
		return ntu / (1 + ntu)
	end
	local e = math.exp(-ntu * (1 - cr))
	return (1 - e) / (1 - cr * e)
end

--[[
	Duty of one exchanger, W, with both outlet temperatures. c_p is taken at each stream's own mean temperature and
	converged by repetition: three passes settle it to well under a millikelvin over the 175 K primary drop.
]]
local function transfer(ua: number, mp: number, tpIn: number, ms: number, tsIn: number): (number, number, number, number, number)
	local tpOut, tsOut = tpIn, tsIn
	local q, cp, cs = 0, 0, 0
	for _ = 1, 3 do
		cp = mp * Sodium.specificHeat(0.5 * (tpIn + tpOut))
		cs = ms * Sodium.specificHeat(0.5 * (tsIn + tsOut))
		q = effectiveness(ua, cp, cs) * math.min(cp, cs) * (tpIn - tsIn)
		tpOut = if cp > 0 then tpIn - q / cp else tpIn
		tsOut = if cs > 0 then tsIn + q / cs else tsIn
	end
	return q, tpOut, tsOut, cp, cs
end

function IHX.init(self: any, ctx: any)
	local cfg = ctx.config
	local spec = cfg.Primary.ihx
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.cfg = spec
	self.kelvin = cfg.Units.kelvinOffset_K
	self.ua = spec.ua_MWpK * 1e6
	self.count = spec.count
	self.leakBy = spec.shutterLeakBy_frac
	-- §4.3's 60 s is the full stroke, from wide open to the leak-by; the model strokes linearly between the two
	self.shutterRate = (1 - self.leakBy) / spec.shutterClose_s

	-- Units 1A, 1B, 2A, … : the leading digit is the secondary loop that feeds the unit
	self.units = {}
	self.loopOf = {}
	local loops = 0
	for i, name in spec.names do
		local loop = tonumber(string.sub(name, 1, 1)) :: number
		self.units[i] = { name = name, loop = loop, shutter = 1, demand = 1 }
		self.loopOf[i] = loop
		loops = math.max(loops, loop)
	end
	self.loopCount = loops
	assert(self.count % loops == 0, `§4.3's {self.count} units do not divide between {loops} secondary loops`)

	-- M1 secondary boundary: one inlet temperature and one per-unit flow per loop, both commandable
	self.loops = {}
	for l = 1, loops do
		self.loops[l] = {
			inlet_K = spec.secondaryInlet_C + self.kelvin,
			flowEach_kgps = spec.secondaryFlowEach_kgps,
			running = true,
		}
	end

	self.duty = table.create(self.count, 0)
	self.primaryOut = table.create(self.count, spec.primaryOutlet_C + self.kelvin)
	self.secondaryOut = table.create(self.count, spec.secondaryOutlet_C + self.kelvin)
	self.primaryFlow = table.create(self.count, spec.primaryFlowEach_kgps)
	self.lmtd = table.create(self.count, 0)
	self.port:write("ihx.dutyEach_W", self.duty)
	self.port:write("ihx.primaryOutlet_K", self.primaryOut)
	self.port:write("ihx.secondaryOutlet_K", self.secondaryOut)
	self.port:write("ihx.primaryFlow_kgps", self.primaryFlow)
	self.port:write("ihx.lmtd_K", self.lmtd)
	self.total_W = 0
	self:solve(spec.primaryInlet_C + self.kelvin, spec.primaryFlowEach_kgps * self.count)
	self:publish()
end

--[[
	Solve all six units for the current hot pool temperature and total primary flow.

	The flow split is the one modelling choice §4.3 does not make for us: the units are equal parallel paths off the
	same pool, so each takes a share in proportion to how far its inlet shutter is open. Closing a shutter therefore
	pushes that unit's flow onto the others rather than throttling the pumps, which is what the pumps' own curve
	does over this small a resistance change.
]]
function IHX.solve(self: any, hotPool_K: number, totalFlow_kgps: number)
	local weight = 0
	for _, unit in self.units do
		weight += unit.shutter
	end
	local total, mixedFlow, mixedEnthalpyFlow = 0, 0, 0
	for i, unit in self.units do
		local flow = if weight > 0 then totalFlow_kgps * unit.shutter / weight else 0
		local loop = self.loops[unit.loop]
		local secondary = if loop.running then loop.flowEach_kgps else 0
		local q, tpOut, tsOut = 0, hotPool_K, loop.inlet_K
		if flow > MIN_FLOW_kgps and secondary > MIN_FLOW_kgps then
			q, tpOut, tsOut = transfer(self.ua, flow, hotPool_K, secondary, loop.inlet_K)
		end
		self.duty[i] = q
		self.primaryFlow[i] = flow
		self.primaryOut[i] = tpOut
		self.secondaryOut[i] = tsOut
		-- Q/UA is the log-mean temperature difference by definition, and unlike the log form it stays finite when
		-- an approach closes to zero on natural circulation (tools/derive/ihx.py)
		self.lmtd[i] = q / self.ua
		total += q
		mixedFlow += flow
		mixedEnthalpyFlow += flow * tpOut
	end
	self.total_W = total
	self.mixedOut_K = if mixedFlow > MIN_FLOW_kgps then mixedEnthalpyFlow / mixedFlow else hotPool_K
end

function IHX.publish(self: any)
	local port = self.port
	local running, inService = 0, 0
	for _, loop in self.loops do
		if loop.running then
			running += 1
		end
	end
	for i, unit in self.units do
		if unit.shutter > self.leakBy and self.loops[unit.loop].running then
			inService += 1
		end
	end
	port:write("ihx.heatRemoved_W", self.total_W)
	port:write("ihx.mixedPrimaryOutlet_K", self.mixedOut_K)
	port:write("ihx.loopsRunning", running)
	port:write("ihx.unitsInService", inService)
end

function IHX.step(self: any, dt: number)
	local port = self.port
	local hotPool = port:read("pools.hotPool_K")
	local flow = port:read("primary.coreFlow_kgps") or 0
	if hotPool == nil then
		return -- nothing to solve against before the pools have published
	end
	local rate = self.shutterRate * dt
	for _, unit in self.units do
		if unit.shutter ~= unit.demand then
			unit.shutter += math.clamp(unit.demand - unit.shutter, -rate, rate)
		end
	end
	self:solve(hotPool, flow)
	self:publish()
end

local function unitIndex(self: any, cmd: Command): (number?, string?)
	for i, unit in self.units do
		if unit.name == cmd.tag then
			return i
		end
	end
	return nil, `unknown IHX '{tostring(cmd.tag)}'`
end

local function loopIndex(self: any, cmd: Command): (number?, string?)
	local l = tonumber(cmd.tag)
	if l == nil or l < 1 or l > self.loopCount or l % 1 ~= 0 then
		return nil, `secondary loop must be 1–{self.loopCount}`
	end
	return l
end

IHX.commands = {
	-- Shutter demand: 1 fully open, 0 closed (which is the 5 % leak-by, not zero flow)
	["ihx.shutter"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local i, why = unitIndex(self, cmd)
		if not i then
			return { ok = false, reason = why }
		end
		local value = cmd.value
		if type(value) ~= "number" or value ~= value or value < 0 or value > 1 then
			return { ok = false, reason = "shutter demand runs from 0 (closed to the leak-by) to 1 (open)" }
		end
		local unit = self.units[i]
		unit.demand = self.leakBy + (1 - self.leakBy) * value
		if self.log then
			self.log:record("ihx.shutter", actor, unit.name, string.format("demand %.2f", value), "set")
		end
		return { ok = true }
	end,

	-- M1 secondary boundary, per loop
	["loop.secondary.inlet"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local l, why = loopIndex(self, cmd)
		if not l then
			return { ok = false, reason = why }
		end
		local value = cmd.value
		if type(value) ~= "number" or value ~= value then
			return { ok = false, reason = "inlet temperature must be a number, in °C" }
		end
		-- the secondary sodium has to stay liquid and below its own loop's limits; §A freezing is 97.8 °C
		if value < 150 or value > 500 then
			return { ok = false, reason = "secondary inlet must be between 150 and 500 °C" }
		end
		self.loops[l].inlet_K = value + self.kelvin
		if self.log then
			self.log:record("loop.secondary.inlet", actor, `loop {l}`, string.format("%.0f °C", value), "set")
		end
		return { ok = true }
	end,

	["loop.secondary.flow"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local l, why = loopIndex(self, cmd)
		if not l then
			return { ok = false, reason = why }
		end
		local value = cmd.value
		if type(value) ~= "number" or value ~= value or value < 0 then
			return { ok = false, reason = "secondary flow must be a number, kg/s per unit" }
		end
		self.loops[l].flowEach_kgps = value
		return { ok = true }
	end,

	["loop.stop"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local l, why = loopIndex(self, cmd)
		if not l then
			return { ok = false, reason = why }
		end
		-- stopLoop runs before the reason would be evaluated, so ask it whether it did anything
		if not self:stopLoop(l, "operator stop", actor) then
			return { ok = false, reason = `loop {l} is already stopped` }
		end
		return { ok = true }
	end,

	["loop.start"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local l, why = loopIndex(self, cmd)
		if not l then
			return { ok = false, reason = why }
		end
		if self.loops[l].running then
			return { ok = false, reason = `loop {l} is already running` }
		end
		self.loops[l].running = true
		if self.log then
			self.log:record("loop.start", actor, `loop {l}`, nil, "started")
		end
		return { ok = true }
	end,
}

--[[
	Stop a secondary loop: its two exchangers stop carrying heat at once, since there is no secondary flow to carry
	it. §9.5 counts lost loops for RB-1 (one loop, runback to 64 %FP) and the two-loop trip; Protection reads
	ihx.loopsRunning and makes that call.
]]
function IHX.stopLoop(self: any, l: number, reason: string, actor: Actor?): boolean
	local loop = self.loops[l]
	if not loop.running then
		return false
	end
	loop.running = false
	if self.log then
		self.log:record("loop.stop", actor, `loop {l}`, reason, "stopped")
	end
	if self.bus then
		local running = 0
		for _, other in self.loops do
			if other.running then
				running += 1
			end
		end
		self.bus:publish("EquipmentTrip", {
			system = "IHX",
			equipment = `secondary loop {l}`,
			reason = reason,
			running = running,
		})
	end
	return true
end

IHX.faults = {
	{
		id = "SL-LOST",
		label = "Secondary loop lost",
		cost = 3,
		eligible = function(_snapshot: any)
			return true
		end,
		arm = function(self: any, params: { [string]: any }?)
			local l = (params and params.loop) or 1
			self:stopLoop(l, "fault SL-LOST")
		end,
		clear = function(_self: any) end, -- a stopped loop is restarted with loop.start, not by clearing the fault
	},
	{
		id = "IHX-SHUT",
		label = "IHX inlet shutter drifts closed",
		cost = 1,
		eligible = function(_snapshot: any)
			return true
		end,
		--[[
			The shutter runs to its leak-by with no command behind it: the unit stops carrying its share of the
			duty, its flow moves to the other five, and the hot pool warms until the others take up the load.
		]]
		arm = function(self: any, params: { [string]: any }?)
			local i = (params and params.unit) or 1
			self.units[i].demand = self.leakBy
			if self.log then
				self.log:record("ihx.shutter", nil, self.units[i].name, "fault IHX-SHUT", "closing")
			end
		end,
		clear = function(self: any, params: { [string]: any }?)
			local i = (params and params.unit) or 1
			self.units[i].demand = 1
		end,
	},
}

function IHX.getState(self: any): { [string]: any }
	local units = {}
	for i, unit in self.units do
		units[i] = {
			name = unit.name,
			loop = unit.loop,
			shutter = unit.shutter,
			duty_MWt = self.duty[i] / 1e6,
			primaryFlow_kgps = self.primaryFlow[i],
			primaryOutlet_K = self.primaryOut[i],
			secondaryOutlet_K = self.secondaryOut[i],
			lmtd_K = self.lmtd[i],
		}
	end
	local loops = {}
	for l, loop in self.loops do
		loops[l] = {
			inlet_C = loop.inlet_K - self.kelvin,
			flowEach_kgps = loop.flowEach_kgps,
			running = loop.running,
		}
	end
	return {
		units = units,
		loops = loops,
		total_MWt = self.total_W / 1e6,
		mixedPrimaryOutlet_K = self.mixedOut_K,
	}
end

return IHX
