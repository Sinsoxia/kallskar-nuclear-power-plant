--!strict
--[[
	Detectors — the neutron instrumentation: source, wide and power range, period, and the DNDs (spec §3.5, §9.5).
	================================================================================================================

	Sixteen independent channels, because §9.5 votes on them: three source range, three wide range, four power
	range quadrants and six delayed-neutron detectors. Independent means each carries its own noise stream — a
	shared one would make 2-of-3 voting meaningless, since every channel would wander together.

	**The noise is physics, not a knob.** SR and DND are pulse-counting channels, so their noise is Poisson: over a
	window τ the relative precision is 1/√(Rτ), with no free parameter. At §3.5's own reference of 250 cps that is
	4.5 % on a 2 s ratemeter, and at 15 cps — the unmultiplied source — it is 18 %. That is why an approach to
	critical feels jittery at the start and settles as the count rate climbs, and it falls out of the model rather
	than being painted on.

	The wide and power range channels are analogue (Campbell-mode mean-square voltage, and DC ionisation chamber
	current), so they get a fractional precision instead: 2 % and 0.5 % (D-025). Those two numbers are choices. The
	three filter time constants are not — each is the shortest that keeps noise 5σ short of the §9.5 setpoint it
	could otherwise fake (tools/derive/detectors.py). Without filtering, 0.5 % power-range noise differentiated
	over one 0.1 s tick is 7 %FP/s against a 10 %FP/s flux-rate trip: the plant would trip on nothing at all.

	**Source range** reads §3.5's 15/(1−k) cps directly. That formula is checkable against the rest of the spec:
	with §3.3's 2,250 pcm of excess and every §3.4 rod in — the secondary shutdown rods included — ρ is −6,420 pcm,
	k is 0.9397, and the count rate is 249 cps against §3.5's "about 250". It also floors at 15 cps (k = 0, the
	bare source) and reaches the top of its 10⁶ cps span at ρ = −1.5 pcm, which is why the handover to the wide
	range happens before criticality rather than at it. The HV drops out above §3.5's 10⁻³ %FP and comes back a
	decade lower, so it cannot chatter across the threshold.

	**Period** is derived from the wide range, as §3.5 says, by filtering d(ln P)/dt. A consequence worth stating:
	with the 5 s filter the period channel is the *slow* protection. A 0.47 s excursion rises e-fold every 0.47 s,
	so §9.5's overpower and flux-rate trips reach their setpoints long before the period meter catches up — which
	is why §9.5 carries all three rather than relying on period alone.

	Inputs:  core.power_pctFP   the true power, which the instruments measure imperfectly
	         core.k             multiplication factor, for the source range's subcritical count rate
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Types = require(Kallskar:WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local Detectors = System.extend({
	name = "Detectors",
	lane = "fast",
	reads = {},
	readsLagged = { "core.power_pctFP", "core.k" },
	writes = {
		"detectors.sr_cps",
		"detectors.srMedian_cps",
		"detectors.srEnergised",
		"detectors.wr_pctFP",
		"detectors.wrMedian_pctFP",
		"detectors.pr_pctFP",
		"detectors.prMean_pctFP",
		"detectors.period_s",
		"detectors.periodMedian_s",
		"detectors.fluxRate_pctFPps",
		"detectors.dnd_cps",
		"detectors.dndMedian_cps",
		"detectors.oneOverM",
	},
})

local BIG_PERIOD_s = 1e6 -- stands in for an infinite period; §3.5's scale ends at ±100 s anyway

-- Standard normal, Box–Muller. One value per call; the second is discarded, which costs nothing measurable here.
local function gaussian(rng: Random): number
	local u1 = math.max(rng:NextNumber(), 1e-12)
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * rng:NextNumber())
end

--[[
	One Poisson sample. Knuth's product method below 30, where the integer nature of counts matters and the loop is
	short; a Gaussian above it, where the two are indistinguishable and the loop would not be.
]]
local function poisson(rng: Random, lambda: number): number
	if lambda <= 0 then
		return 0
	end
	if lambda < 30 then
		local limit = math.exp(-lambda)
		local k, p = 0, 1
		repeat
			k += 1
			p *= rng:NextNumber()
		until p <= limit
		return k - 1
	end
	return math.max(0, lambda + math.sqrt(lambda) * gaussian(rng))
end

local function median3(a: number, b: number, c: number): number
	return math.max(math.min(a, b), math.min(math.max(a, b), c))
end

local function medianOf(values: { number }): number
	local sorted = table.clone(values)
	table.sort(sorted)
	local n = #sorted
	if n % 2 == 1 then
		return sorted[(n + 1) // 2]
	end
	return 0.5 * (sorted[n // 2] + sorted[n // 2 + 1])
end

function Detectors.init(self: any, ctx: any)
	local cfg = ctx.config
	local inst = cfg.Instruments
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.cfg = inst
	self.noise = inst.noise
	self.srConstant = inst.sourceRangeConstant_cps
	self.srSpan = inst.sourceRange.span_cps
	self.wrSpan = inst.wideRange.span_pctFP
	self.prSpan = inst.powerRange.span_pctFP
	self.hvOffAbove = inst.sourceRangeHighVoltageOffAbove_pctFP
	self.hvOnBelow = inst.sourceRangeHighVoltageOnBelow_pctFP
	self.background_cps = inst.dndBackground_cps

	--[[
		A first-order filter has the noise-averaging of a boxcar twice as long, so the configured *averaging* time
		maps to a filter constant of half it. The tests check the achieved precision against 1/√(Rτ) directly.
	]]
	self.ratemeterTau = self.noise.ratemeterAveraging_s / 2

	-- Deterministic seeds: reproducible in tests, and independent between channels, which is what voting needs.
	self.rng = {}
	local function streams(prefix: string, n: number)
		local list = {}
		for i = 1, n do
			list[i] = Random.new(string.byte(prefix) * 1000 + i)
		end
		self.rng[prefix] = list
		return list
	end
	self.srCount = inst.sourceRange.channels
	self.wrCount = inst.wideRange.channels
	self.prCount = inst.powerRange.channels
	self.dndCount = inst.delayedNeutronDetectors.channels
	streams("S", self.srCount)
	streams("W", self.wrCount)
	streams("P", self.prCount)
	streams("D", self.dndCount)

	self.sr = table.create(self.srCount, 0)
	self.wr = table.create(self.wrCount, 0)
	self.pr = table.create(self.prCount, 0)
	self.dnd = table.create(self.dndCount, 0)
	self.period = table.create(self.wrCount, BIG_PERIOD_s)
	self.lnRate = table.create(self.wrCount, 0) -- filtered d(ln P)/dt per wide range channel
	self.lastLn = table.create(self.wrCount, 0)
	self.failed = {} :: { [string]: string }

	self.energised = true
	self.fluxRate = 0
	self.lastPr = 0
	self.dndFactor = 1
	self.reference_cps = nil
	self.started = false
	self.port:write("detectors.sr_cps", self.sr)
	self.port:write("detectors.wr_pctFP", self.wr)
	self.port:write("detectors.pr_pctFP", self.pr)
	self.port:write("detectors.dnd_cps", self.dnd)
	self.port:write("detectors.period_s", self.period)
	self:publish()
end

-- §3.5: the subcritical count rate the source range sees, before its own statistics
function Detectors.trueCountRate(self: any, k: number): number
	local gap = 1 - k
	if gap <= self.srConstant / self.srSpan[2] then
		return self.srSpan[2] -- off the top of the §3.5 span, which happens a whisker below critical
	end
	return math.clamp(self.srConstant / gap, self.srSpan[1], self.srSpan[2])
end

-- A channel knocked out by NI-FAIL reads its failure value instead of the measurement.
function Detectors.faultValue(self: any, name: string, measured: number): number
	local mode = self.failed[name]
	if mode == nil then
		return measured
	elseif mode == "low" then
		return 0
	elseif mode == "high" then
		return math.huge
	end
	return measured -- "freeze" is handled by the caller, which simply does not update
end

function Detectors.publish(self: any)
	local port = self.port
	port:write("detectors.srMedian_cps", median3(self.sr[1], self.sr[2], self.sr[3]))
	port:write("detectors.srEnergised", self.energised)
	port:write("detectors.wrMedian_pctFP", median3(self.wr[1], self.wr[2], self.wr[3]))
	port:write("detectors.prMean_pctFP", medianOf(self.pr))
	port:write("detectors.periodMedian_s", median3(self.period[1], self.period[2], self.period[3]))
	port:write("detectors.fluxRate_pctFPps", self.fluxRate)
	port:write("detectors.dndMedian_cps", medianOf(self.dnd))
	local reference = self.reference_cps
	local current = median3(self.sr[1], self.sr[2], self.sr[3])
	port:write("detectors.oneOverM", if reference and current > 0 then reference / current else 1)
end

function Detectors.step(self: any, dt: number)
	local port = self.port
	local power = port:read("core.power_pctFP") or 0
	local k = port:read("core.k") or 0

	-- Source range: §3.5's HV cut-off, with a decade of hysteresis so it cannot chatter (D-025)
	if self.energised and power > self.hvOffAbove then
		self.energised = false
		if self.log then
			self.log:record("sr.hv", nil, "source range", "above 1e-3 %FP", "de-energised")
		end
	elseif not self.energised and power < self.hvOnBelow then
		self.energised = true
		if self.log then
			self.log:record("sr.hv", nil, "source range", "below 1e-4 %FP", "energised")
		end
	end
	local trueRate = self:trueCountRate(k)
	local alpha = 1 - math.exp(-dt / self.ratemeterTau)
	for i = 1, self.srCount do
		local name = `SR{i}`
		if self.failed[name] == "freeze" then
			continue
		end
		if not self.energised then
			self.sr[i] = 0
		else
			local counts = poisson(self.rng.S[i], trueRate * dt)
			local raw = counts / dt
			local shown = self.sr[i] + (raw - self.sr[i]) * alpha
			if not self.started then
				shown = raw -- no ramp-up from zero on the first tick
			end
			self.sr[i] = math.clamp(self:faultValue(name, shown), 0, self.srSpan[2])
		end
	end

	-- Wide range: log channel over the whole span, with its Campbell-mode fractional noise
	local wrNoise = self.noise.wideRangeRelative
	local periodAlpha = 1 - math.exp(-dt / self.noise.periodFilter_s)
	for i = 1, self.wrCount do
		local name = `WR{i}`
		if self.failed[name] ~= "freeze" then
			local measured = power * (1 + wrNoise * gaussian(self.rng.W[i]))
			self.wr[i] = math.clamp(self:faultValue(name, measured), self.wrSpan[1], self.wrSpan[2])
		end
		-- §3.5: period comes from the wide range, as a filtered d(ln P)/dt
		local ln = math.log(math.max(self.wr[i], self.wrSpan[1]))
		if self.started then
			local rate = (ln - self.lastLn[i]) / dt
			self.lnRate[i] += (rate - self.lnRate[i]) * periodAlpha
		end
		self.lastLn[i] = ln
		local rate = self.lnRate[i]
		self.period[i] = if math.abs(rate) < 1 / BIG_PERIOD_s then BIG_PERIOD_s else 1 / rate
	end

	-- Power range: four linear quadrant channels on DC ionisation chambers
	local prNoise = self.noise.powerRangeRelative
	for i = 1, self.prCount do
		local name = `PR{i}`
		if self.failed[name] == "freeze" then
			continue
		end
		local measured = power * (1 + prNoise * gaussian(self.rng.P[i]))
		self.pr[i] = math.clamp(self:faultValue(name, measured), self.prSpan[1], self.prSpan[2])
	end
	-- §9.5's flux rate trip works on the power range, filtered so noise cannot reach its setpoint (D-025)
	local prNow = medianOf(self.pr)
	if self.started then
		local raw = (prNow - self.lastPr) / dt
		self.fluxRate += (raw - self.fluxRate) * (1 - math.exp(-dt / self.noise.fluxRateFilter_s))
	end
	self.lastPr = prNow

	-- Delayed neutron detectors: counting channels on the IHX primary inlets
	for i = 1, self.dndCount do
		local name = `DND{i}`
		if self.failed[name] == "freeze" then
			continue
		end
		local counts = poisson(self.rng.D[i], self.background_cps * self.dndFactor * dt)
		local raw = counts / dt
		local shown = if self.started then self.dnd[i] + (raw - self.dnd[i]) * alpha else raw
		self.dnd[i] = math.max(self:faultValue(name, shown), 0)
	end

	self.started = true
	self:publish()
end

Detectors.commands = {
	--[[
		Latch the count rate an approach to critical is measured against. The 1/M plot is CR₀/CR against rod
		position: it falls toward zero as k approaches 1, and extrapolating the line is how the approach is flown
		(§3.5). Taking the reference is the operator's first action of a startup.
	]]
	["ni.reference"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local current = median3(self.sr[1], self.sr[2], self.sr[3])
		if not self.energised then
			return { ok = false, reason = "the source range is de-energised" }
		end
		if current <= 0 then
			return { ok = false, reason = "no source range indication to reference" }
		end
		self.reference_cps = current
		if self.log then
			self.log:record("ni.reference", actor, "source range",
				string.format("%.0f cps", current), "latched")
		end
		return { ok = true }
	end,
}

Detectors.faults = {
	{
		id = "NI-FAIL",
		label = "Neutron channel failure",
		cost = 1,
		eligible = function(_snapshot: any)
			return true
		end,
		--[[
			One channel fails low (dead), high (saturated) or frozen (stuck at its last reading). Frozen is the
			nastiest, because a channel that agrees with the others until the plant moves is the one that survives
			a casual glance — and §9.5's voting is what catches it.
		]]
		arm = function(self: any, params: { [string]: any }?)
			local name = (params and params.channel) or "PR1"
			local mode = (params and params.mode) or "low"
			self.failed[name] = mode
			if self.log then
				self.log:record("ni.fail", nil, name, `fault NI-FAIL ({mode})`, "failed")
			end
		end,
		clear = function(self: any, params: { [string]: any }?)
			local name = (params and params.channel) or "PR1"
			self.failed[name] = nil
		end,
	},
	{
		id = "DND-HIGH",
		label = "Delayed neutron signal rising",
		cost = 8,
		eligible = function(_snapshot: any)
			return true
		end,
		--[[
			The signature of a failed fuel pin: delayed-neutron precursors reaching the IHX inlets. §9.5 alarms at
			three times background and trips at twenty.
		]]
		arm = function(self: any, params: { [string]: any }?)
			self.dndFactor = (params and params.factor) or 5
			if self.log then
				self.log:record("dnd.high", nil, "DND", `×{self.dndFactor} background`, "rising")
			end
		end,
		clear = function(self: any)
			self.dndFactor = 1
		end,
	},
}

function Detectors.getState(self: any): { [string]: any }
	return {
		sr_cps = table.clone(self.sr),
		srMedian_cps = median3(self.sr[1], self.sr[2], self.sr[3]),
		srEnergised = self.energised,
		reference_cps = self.reference_cps,
		wr_pctFP = table.clone(self.wr),
		pr_pctFP = table.clone(self.pr),
		prMean_pctFP = medianOf(self.pr),
		period_s = table.clone(self.period),
		periodMedian_s = median3(self.period[1], self.period[2], self.period[3]),
		fluxRate_pctFPps = self.fluxRate,
		dnd_cps = table.clone(self.dnd),
		dndMedian_cps = medianOf(self.dnd),
		failed = table.clone(self.failed),
	}
end

return Detectors
