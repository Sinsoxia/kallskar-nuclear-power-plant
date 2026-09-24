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

	**The M1 heat sink** (D-032). The real secondary loops, their pumps, the steam generators and the turbines
	arrive in a later milestone; until then this system stands in for all of them with one number, the steam
	plant's load, and the steam plant TAKES that load: each tick the cold leg is solved so that the exchangers
	carry the load plus the pumps' heat. Q = ε·C_min·(T_hot − T_cold) with ε fixed by the flows, so that is a
	one-dimensional solve (a few secant passes, for c_p).

	The cold leg is kept inside what the steam plant can give. It is never colder than §9.2's programme cold leg
	for the load (320 °C at full load, 348 °C at 20 %FP; Systems/PartLoad), never warmer than 375 °C, which is
	the no-load programme and hot standby's own temperature, and never warmer than the pool it faces, because a
	steam generator cannot heat sodium. Secondary flow follows the primary flow the pumps deliver, which §9.2's
	table makes equal to it at every row (Systems/PartLoad); holding them together keeps each exchanger at its
	design capacity ratio when the pumps are off the programme. On the programme alone, a trip with flow auto
	out would leave the secondary on its 25 % no-load flow against primary at 100 %; the primary would then
	barely cool across the exchangers, and the whole pool would have to rise to shed the decay heat. The load
	moves at §7.1's 5 %/min, and at LCO-10's 1 %/min above 40 %. A per-loop command overrides the inlet or flow
	of one loop, which is how inlet-temperature feedback and a lost loop are driven by hand; the programme loops
	then carry whatever the held loop does not.

	Why solve for the load rather than pin §9.2's cold leg (F33): with §4.3's UA held constant (D-022) the
	exchangers are far more effective at part flow than §9.2's temperatures imply — its 40 % row repeats the
	full-load temperatures at 40 % of the duty, which needs UA ∝ flow. A pinned cold leg would pull the core
	inlet 5.5–23 K below the programme at part load. Taking the load holds the reactor's side of §9.2 exactly and
	lets the cold leg sit 6–23 K warmer than the table's secondary column instead, on the side of the plant M1
	does not model (tools/derive/heat_sink.py).

	A reactor trip takes the load to zero at once: the turbines trip with the reactor and §7.3's bypass, open in
	2 s, holds the steam side while decay heat comes down — which from the sodium is the no-load programme, 375 °C
	on the cold leg. Without that, a sink left at load would go on pulling rated heat out of a core making decay
	heat and cool the plant through its own inlet-low trip. The stand-in has no secondary inventory, so the cold
	leg steps where the real loops would take their transit time to follow; that arrives with them.

	The plant follows the sink the way a fast reactor does: a heavier load cools the cold leg, the inlet
	temperature coefficient adds reactivity, and power rises to meet it with rod auto trimming the outlet.

	Inputs:  pools.hotPool_K         primary inlet, the second hot-pool node
	         primary.coreFlow_kgps   total primary flow, split between the units
	         primary.pumpHeat_MWt    the pumps' heat, which the steam plant carries away with the load
	         protection.scram        a trip takes the turbines off with it
	         protection.runback…     a runback takes the load back with the reactor: to the runback's target, at its
	                                 rate rather than §7.1's (D-046)
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local PartLoad = require(script.Parent.PartLoad)
local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Sodium = require(Kallskar:WaitForChild("Props"):WaitForChild("Sodium"))
local Types = require(Kallskar:WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local IHX = System.extend({
	name = "IHX",
	lane = "fast",
	reads = { "pools.hotPool_K", "primary.coreFlow_kgps", "primary.pumpHeat_MWt" },
	-- Protection runs after the pools it watches, so a trip or a runback arrives next tick
	readsLagged = {
		"protection.scram",
		"protection.runback",
		"protection.runbackTarget_pctFP",
		"protection.runbackRate_pctpmin",
		"protection.runbackEnd",
	},
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
		"ihx.sinkLoad_pct",
		"ihx.sinkLoadDemand_pct",
		"ihx.secondaryInlet_K",
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
	self.config = cfg
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

	-- M1 heat sink. It boots with no load because the plant boots in hot standby (D-024).
	local loading = cfg.Program.sinkLoading
	self.loadRateLow = loading.hot_pctPerMin / 60
	self.loadRateHigh = loading.aboveLimit_pctPerMin / 60
	self.loadLimitAbove = loading.limitAbove_pct
	self.rated_W = cfg.Units.ratedThermal_MWt * 1e6
	self.warmest_K = cfg.Program.partLoad.coreInlet_C + self.kelvin -- the no-load programme: hot standby
	self.ratedPrimary_kgps = cfg.Primary.pumps.ratedFlowTotal_kgps -- F30: the total is the authoritative figure
	self.sinkLoad = 0 -- not `load`: that name is the System persistence hook (Framework/System)
	self.loadDemand = 0
	-- the runback the load is following down (D-046): its target, and its rate in % per second
	self.runbackTarget = nil :: number?
	self.runbackRate = 0
	self.lastScram = "none"
	self.coldLeg_K = self.warmest_K
	self.loops = {}
	for l = 1, loops do
		self.loops[l] = {
			inlet_K = self.warmest_K,
			flowEach_kgps = 0,
			running = true,
			inletOverride_K = nil :: number?,
			flowOverride_kgps = nil :: number?,
		}
	end
	self.secondaryInlet = table.create(loops, self.warmest_K)
	self.port:write("ihx.secondaryInlet_K", self.secondaryInlet)
	self:applyFlows()

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
	self:solveAtProgramme()
	self:publish()
end

--[[
	Solve against the hot pool and primary flow the programme expects at the current load. That is only the first
	frame's answer, before Pools has published a real hot pool; it is chosen so the first frame agrees with the
	state the rest of the plant boots in rather than with §4.3's full-power design point.
]]
function IHX.solveAtProgramme(self: any)
	local flow = PartLoad.flow_pct(self.config, self.sinkLoad) / 100
	local hotPool = PartLoad.outlet_C(self.config, self.sinkLoad / 100, flow) + self.kelvin
	self:applyFlows(self.ratedPrimary_kgps * flow)
	self:solve(hotPool, self.ratedPrimary_kgps * flow)
end

-- Solve again against the last hot pool and flow, so a command shows in the state at once rather than next tick
function IHX.resolve(self: any)
	if self.lastHot_K then
		self:solve(self.lastHot_K, self.lastFlow_kgps)
		self:publish()
	end
end

--[[
	Every loop's secondary flow, except where an override holds it by hand: the primary flow's fraction of rated,
	applied to §4.3's secondary flow (see the header). With no primary flow given, as before the pools have
	published, it is the programme's flow for the load, which is the same number on the programme.
]]
function IHX.applyFlows(self: any, primaryFlow_kgps: number?)
	local fraction = if primaryFlow_kgps then primaryFlow_kgps / self.ratedPrimary_kgps
		else PartLoad.secondaryFlow_frac(self.config, self.sinkLoad)
	local flow = fraction * self.cfg.secondaryFlowEach_kgps
	for _, loop in self.loops do
		loop.flowEach_kgps = loop.flowOverride_kgps or flow
	end
end

-- Duty the programme loops carry at one cold leg, W
local function programmeDuty(self: any, hotPool_K: number, cold_K: number): number
	local q = 0
	for i, unit in self.units do
		local loop = self.loops[unit.loop]
		local mp, ms = self.primaryFlow[i], if loop.running then loop.flowEach_kgps else 0
		if loop.inletOverride_K == nil and mp > MIN_FLOW_kgps and ms > MIN_FLOW_kgps then
			q += (transfer(self.ua, mp, hotPool_K, ms, cold_K))
		end
	end
	return q
end

--[[
	The steam plant takes its load. Find the cold leg at which the programme loops carry the load and the pumps'
	heat, less whatever the held loops carry, then keep it inside the steam plant's range (see the header). Each
	pass is a secant through T_cold = T_hot: at fixed ε the duty is proportional to T_hot − T_cold, so the first
	pass lands within the c_p variation, and each one after shrinks the error by the few per cent that c_p and ε
	move over the approach. Passes stop when the cold leg moves by less than a nanokelvin, which is the solve
	converged rather than a tolerance on the plant.
]]
local SINK_TOLERANCE_K = 1e-9
local SINK_MAX_PASSES = 30

function IHX.setColdLeg(self: any, hotPool_K: number)
	local held, free = 0, false
	for i, unit in self.units do
		local loop = self.loops[unit.loop]
		local mp, ms = self.primaryFlow[i], if loop.running then loop.flowEach_kgps else 0
		if mp > MIN_FLOW_kgps and ms > MIN_FLOW_kgps then
			if loop.inletOverride_K then
				held += (transfer(self.ua, mp, hotPool_K, ms, loop.inletOverride_K))
			else
				free = true
			end
		end
	end
	-- a steam generator cannot heat sodium, so the cold leg never sits above the pool it faces
	local warmest = math.min(self.warmest_K, hotPool_K)
	local coldest = math.min(PartLoad.secondaryCold_C(self.config, self.sinkLoad) + self.kelvin, warmest)
	local need = self.sinkLoad / 100 * self.rated_W + (self.port:read("primary.pumpHeat_MWt") or 0) * 1e6 - held
	local cold = warmest
	if free and need > 0 and warmest - coldest > 0 then
		cold = math.clamp(hotPool_K - 1, coldest, warmest)
		for _ = 1, SINK_MAX_PASSES do
			local q = programmeDuty(self, hotPool_K, cold)
			if q <= 0 then
				break
			end
			local nextCold = math.clamp(hotPool_K - need * (hotPool_K - cold) / q, coldest, warmest)
			local moved = math.abs(nextCold - cold)
			cold = nextCold
			if moved < SINK_TOLERANCE_K then
				break
			end
		end
	end
	self.coldLeg_K = cold
	for l, loop in self.loops do
		loop.inlet_K = loop.inletOverride_K or cold
		self.secondaryInlet[l] = loop.inlet_K
	end
end

--[[
	Seat the heat sink at a load as an initial condition, the way Core.setPower seats the core: no ramp, and the
	demand goes with it so nothing moves afterwards. Commands ramp; this is for tests and the developer panel.
]]
function IHX.setLoad(self: any, load_pct: number)
	self.sinkLoad = math.clamp(load_pct, 0, 100)
	self.loadDemand = self.sinkLoad
	self:solveAtProgramme()
	self:publish()
end

-- The turbines trip with the reactor: no ramp, and the demand goes with it so the load stays down after a reset
function IHX.tripLoad(self: any, scram: string)
	if self.sinkLoad == 0 and self.loadDemand == 0 then
		return
	end
	self.sinkLoad = 0
	self.loadDemand = 0
	self.runbackTarget = nil
	if self.log then
		self.log:record("sink.trip", nil, "steam plant", `reactor trip ({scram}): turbines tripped, bypass holding`, "tripped")
	end
end

--[[
	Move the load toward its demand at §7.1's rate, or LCO-10's above 40 %. A tick that crosses 40 % is split
	there, and the rest of it runs at the rate of the side it ends on, so each rate applies only on its own side
	of the limit and the ramp does not depend on where the ticks happen to fall.
]]
function IHX.rampLoad(self: any, dt: number)
	local load, demand, limit = self.sinkLoad, self.loadDemand, self.loadLimitAbove
	if load == demand then
		return
	end
	local rising = demand > load
	-- D-046: above a runback's target the load falls at the runback's rate, not at the operating limits
	local floor = self.runbackTarget
	if floor and not rising and load > floor then
		self.sinkLoad = math.max(demand, floor, load - self.runbackRate * dt)
		return
	end
	local high = if rising then load >= limit else load > limit
	local rate = if high then self.loadRateHigh else self.loadRateLow
	local step = rate * dt
	local crosses = if rising
		then not high and demand > limit and load + step > limit
		else high and demand < limit and load - step < limit
	if crosses then
		local left = dt - math.abs(limit - load) / rate
		load = limit
		step = (if high then self.loadRateLow else self.loadRateHigh) * left
	end
	self.sinkLoad = if rising then math.min(demand, load + step) else math.max(demand, load - step)
end

--[[
	Solve all six units for the current hot pool temperature and total primary flow.

	The flow split is the one modelling choice §4.3 does not make for us: the units are equal parallel paths off the
	same pool, so each takes a share in proportion to how far its inlet shutter is open. Closing a shutter therefore
	pushes that unit's flow onto the others rather than throttling the pumps, which is what the pumps' own curve
	does over this small a resistance change.
]]
function IHX.solve(self: any, hotPool_K: number, totalFlow_kgps: number)
	self.lastHot_K, self.lastFlow_kgps = hotPool_K, totalFlow_kgps
	local weight = 0
	for _, unit in self.units do
		weight += unit.shutter
	end
	for i, unit in self.units do
		self.primaryFlow[i] = if weight > 0 then totalFlow_kgps * unit.shutter / weight else 0
	end
	self:setColdLeg(hotPool_K)
	local total, mixedFlow, mixedEnthalpyFlow = 0, 0, 0
	for i, unit in self.units do
		local flow = self.primaryFlow[i]
		local loop = self.loops[unit.loop]
		local secondary = if loop.running then loop.flowEach_kgps else 0
		local q, tpOut, tsOut = 0, hotPool_K, loop.inlet_K
		if flow > MIN_FLOW_kgps and secondary > MIN_FLOW_kgps then
			q, tpOut, tsOut = transfer(self.ua, flow, hotPool_K, secondary, loop.inlet_K)
		end
		self.duty[i] = q
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
	port:write("ihx.sinkLoad_pct", self.sinkLoad)
	port:write("ihx.sinkLoadDemand_pct", self.loadDemand)
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
	local scram = port:read("protection.scram") or "none"
	if scram ~= "none" and self.lastScram == "none" then
		self:tripLoad(scram)
	end
	self.lastScram = scram
	-- a runback (D-046): the demand goes down to its target, and the load follows at its rate
	local runback = port:read("protection.runback") or ""
	local target = port:read("protection.runbackTarget_pctFP") or 100
	local perMinute = port:read("protection.runbackRate_pctpmin") or 0
	local ended = port:read("protection.runbackEnd") or ""
	if runback ~= "" then
		self.runbackTarget, self.runbackRate = target, perMinute / 60
		self.loadDemand = math.min(self.loadDemand, target)
	elseif self.runbackTarget then
		--[[
			The runback is over, and Protection says how.
			  complete  its demand reached the target, but the load can still be above it: the load reads Protection a
			            tick late, and it ramps from the steam plant's own load while the demand ramped from the noisy
			            PR median, so the gap is a few ticks of the ramp and differs run to run. The load finishes at the
			            runback's rate to the target (rampLoad, on the latch kept here), unless the operator raises the
			            demand first, which ends the latch.
			  cleared   the steam plant's runback ends with it: the demand holds at the load, for the operator to take
			            from there at the operating rates.
			Either way the latch ends, so no later load change takes a runback's rate (D-046).
		]]
		local finishing = ended == "complete" and self.sinkLoad > self.runbackTarget and self.loadDemand <= self.runbackTarget
		if not finishing then
			if ended ~= "complete" then
				self.loadDemand = self.sinkLoad
			end
			self.runbackTarget, self.runbackRate = nil, 0
		end
	end
	self:rampLoad(dt)
	self:applyFlows(flow)
	self:solve(hotPool, flow)
	self:publish()
end

local function unitIndex(self: any, cmd: Command): (number?, string?)
	for i, unit in self.units do
		if unit.name == cmd.target then
			return i
		end
	end
	return nil, `unknown IHX '{tostring(cmd.target)}'`
end

local function loopIndex(self: any, cmd: Command): (number?, string?)
	local l = tonumber(cmd.target)
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

	-- M1 heat sink: the steam plant's load demand, which the load then follows at its ramp limits
	["sink.load"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local value = cmd.value
		if type(value) ~= "number" or value ~= value or value < 0 or value > 100 then
			return { ok = false, reason = "steam plant load runs from 0 to 100 % of rated" }
		end
		self.loadDemand = value
		if self.log then
			self.log:record("sink.load", actor, "steam plant", string.format("demand %.1f %%", value), "set")
		end
		return { ok = true }
	end,

	-- Per-loop overrides of the programme, held until loop.secondary.program hands the loop back
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
		self.loops[l].inletOverride_K = value + self.kelvin
		self:applyFlows(self.lastFlow_kgps)
		self:resolve()
		if self.log then
			self.log:record("loop.secondary.inlet", actor, `loop {l}`, string.format("%.0f °C", value), "override")
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
		self.loops[l].flowOverride_kgps = value
		self:applyFlows(self.lastFlow_kgps)
		self:resolve()
		if self.log then
			self.log:record("loop.secondary.flow", actor, `loop {l}`, string.format("%.0f kg/s per unit", value), "override")
		end
		return { ok = true }
	end,

	["loop.secondary.program"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local l, why = loopIndex(self, cmd)
		if not l then
			return { ok = false, reason = why }
		end
		local loop = self.loops[l]
		if loop.inletOverride_K == nil and loop.flowOverride_kgps == nil then
			return { ok = false, reason = `loop {l} is already on the programme` }
		end
		loop.inletOverride_K = nil
		loop.flowOverride_kgps = nil
		self:applyFlows(self.lastFlow_kgps)
		self:resolve()
		if self.log then
			self.log:record("loop.secondary.program", actor, `loop {l}`, nil, "on programme")
		end
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

-- §14.6 (D-053): the shutter demands, and the secondary loops, stopped or running, with any overrides. The steam
-- plant tripped with the reactor when the server closed, so the load comes back at nothing.
function IHX.save(self: any): any
	local units, loops = {}, {}
	for i, u in self.units do
		units[i] = { shutter = u.shutter, demand = u.demand }
	end
	for l, loop in self.loops do
		loops[l] = {
			running = loop.running,
			inletOverride_K = loop.inletOverride_K,
			flowOverride_kgps = loop.flowOverride_kgps,
		}
	end
	return { units = units, loops = loops }
end

function IHX.load(self: any, data: any, _version: number)
	if type(data.units) == "table" then
		for i, u in self.units do
			local s = data.units[i]
			if type(s) == "table" and type(s.shutter) == "number" and type(s.demand) == "number" then
				u.shutter, u.demand = s.shutter, s.demand
			end
		end
	end
	if type(data.loops) == "table" then
		for l, loop in self.loops do
			local s = data.loops[l]
			if type(s) == "table" then
				loop.running = s.running ~= false
				loop.inletOverride_K = if type(s.inletOverride_K) == "number" then s.inletOverride_K else nil
				loop.flowOverride_kgps = if type(s.flowOverride_kgps) == "number" then s.flowOverride_kgps else nil
			end
		end
	end
	self.sinkLoad, self.loadDemand, self.runbackTarget = 0, 0, nil
	self.lastScram = "PSS"
end

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
			overridden = loop.inletOverride_K ~= nil or loop.flowOverride_kgps ~= nil,
		}
	end
	return {
		units = units,
		loops = loops,
		sinkLoad_pct = self.sinkLoad,
		sinkLoadDemand_pct = self.loadDemand,
		total_MWt = self.total_W / 1e6,
		mixedPrimaryOutlet_K = self.mixedOut_K,
	}
end

return IHX
