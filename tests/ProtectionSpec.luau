--!strict
--[[
	Protection verification (spec §9.5, D-004, D-025).

	Two things matter here and both are tested: that every §9.5 trip fires when its signal reaches its setpoint,
	and — harder — that none of them fires when it should not. A protection system that trips readily is not
	safe, it is unusable: it fills the first-out with noise and teaches the crew to ignore the annunciator.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Config = require(Kallskar:WaitForChild("Config")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local Protection = require(Root:WaitForChild("Systems"):WaitForChild("Protection")) :: any

local PSS = Config.Protection.pss
local KEL = Config.Units.kelvinOffset_K
local DT = 1 / Config.Clocks.fast_Hz
local DND = Config.Instruments.dndBackground_cps
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

--[[
	A plant sitting quietly at `power` %FP (full power by default), with every signal where §9.5 says normal.
	The power range channels are set from the same number: a test that moves the plant's power without moving
	its instruments is describing a plant whose PR channels have all failed high, which trips on PR-HIGH before
	it reaches whatever the test meant to check.
]]
-- The real-time clock Protection times the MCR trip buttons on (D-056), which the tests move by hand
local realNow = 0

local function make(power: number?)
	local pctFP = power or 100
	local ch = Channels.new()
	ch:declareExternal("detectors.pr_pctFP", { pctFP, pctFP, pctFP, pctFP })
	ch:declareExternal("detectors.prMean_pctFP", pctFP)
	ch:declareExternal("detectors.period_s", { 1e6, 1e6, 1e6 })
	ch:declareExternal("detectors.fluxRate_pctFPps", 0)
	ch:declareExternal("detectors.dnd_cps", { DND, DND, DND, DND, DND, DND })
	ch:declareExternal("pools.mixedCoreOutletMeasured_K", PSS.coreOutletMixed.normal_C + KEL)
	ch:declareExternal("pools.coreInlet_K", PSS.coreInlet.normal_C + KEL)
	ch:declareExternal("pools.coverGas_MPa", PSS.coverGas.normal_MPa)
	ch:declareExternal("fuel.assemblyOutlet_K", { 832, 832, 832, 832, 832 })
	ch:declareExternal("primary.pumpsRunning", 3)
	ch:declareExternal("primary.flowFraction", 1)
	ch:declareExternal("primary.pumpSpeed_pct", { 100, 100, 100 })
	ch:declareExternal("ihx.loopsRunning", 3)
	ch:declareExternal("core.power_pctFP", pctFP)
	ch:declareExternal("program.mode", 1)
	ch:declareExternal("site.seismic_g", 0)
	ch:declareExternal("electrical.boards11kV", 3)
	ch:declareExternal("core.reactivityBalance_pcm", 0)
	ch:declareExternal("turbine.bypassAvailable", true)
	ch:declareExternal("pools.levelDeviation_m", 0)
	ch:declareExternal("rods.allPssInserted", false)
	ch:declareExternal("rods.regulatingInBand", true)
	ch:declareExternal("rods.selection", "")
	local sys = System.new(Protection)
	local bus = Bus.new()
	sys:init({
		config = Config,
		channels = ch:port(Protection.spec),
		log = EventLog.new(Config, { sim = 0, grid = 0 }),
		bus = bus,
		realTime = function()
			return realNow
		end,
	})
	return sys, ch, bus
end

local function run(sys: any, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
	end
end

local function fill(n: number, value: number): { number }
	local t = table.create(n, value)
	return t
end

-- A standard normal draw, as Detectors makes one (Box–Muller)
local function gaussian(rng: Random): number
	local u1 = math.max(rng:NextNumber(), 1e-12)
	return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * rng:NextNumber())
end

--[[
	The standard normal upper tail, 1 − Φ(z) = erfc(z/√2)/2, through Numerical Recipes' erfcc (Press et al., 2nd ed.,
	§6.2), whose fractional error is under 1.2e-7 everywhere: far inside what a bound on a few events needs.
]]
local function upper(z: number): number
	local x = z / math.sqrt(2)
	local a = math.abs(x)
	local t = 1 / (1 + 0.5 * a)
	local erfc = t * math.exp(-a * a - 1.26551223 + t * (1.00002368 + t * (0.37409196 + t * (0.09678418 + t * (-0.18628806
		+ t * (0.27886807 + t * (-1.13520398 + t * (1.48851587 + t * (-0.82215223 + t * 0.17087277)))))))))
	return (if x >= 0 then erfc else 2 - erfc) / 2
end

-- The smallest k with P(Poisson(μ) > k) ≤ ε, the pmf summed in logs so a large μ does not underflow
local function poissonBound(mu: number, eps: number): number
	if mu <= 0 then
		return 0
	end
	local logp, k = -mu, 0
	local cdf = math.exp(logp)
	while 1 - cdf > eps do
		k += 1
		logp += math.log(mu / k)
		cdf += math.exp(logp)
	end
	return k
end

return {
	["a plant at §9.5's normal column does not trip, alarm or block"] = function(t)
		local sys, ch = make()
		run(sys, 60)
		local s = sys:getState()
		t.eq(ch:get("protection.scram"), "none", "no scram")
		t.ok(not ch:get("protection.tripped"))
		t.eq(ch:get("protection.firstOut"), "", "nothing has gone first")
		t.ok(not ch:get("protection.rodWithdrawalBlock"), "no rod block")
		t.eq(#s.active, 0, "and no alarms in")
		-- nothing is INHIBITED here either: the rows §9.5 arms only below 10 %FP are simply not evaluated at
		-- power, and only a rule that holds a trip off when its signal is present annunciates itself
		t.eq(#s.inhibited, 0, "and nothing is holding a trip off")
	end,

	["the assembly outlet row refills its buffers rather than allocating every tick"] = function(t)
		local sys, ch = make()
		local row = nil
		for _, m in sys.monitors do
			if m.id == "ASSY-DEV" then
				row = m
			end
		end
		local first = row.signal(sys)
		t.ok(first == row.signal(sys), "the deviations table is the same table, tick after tick")
		-- a different number of outlets refills it to the new length, with nothing left over from the old one
		ch:setExternal("fuel.assemblyOutlet_K", { 830, 840, 850 })
		local resized = row.signal(sys)
		t.eq(#resized, 3, "sized to the outlets it was given")
		t.eq(resized[3] - resized[1], 20, "holding the deviations of these three outlets")
	end,

	["PR high flux trips 2-out-of-4, not 1 (§9.5, D-005)"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		-- one quadrant reading high is a channel failure, not an overpower
		ch:setExternal("detectors.pr_pctFP", { 117, 100, 100, 100 })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "one channel is outvoted")
		t.ok(sys:getState().monitors["PR-HIGH"].alarm, "but it does raise the alarm")
		ch:setExternal("detectors.pr_pctFP", { 117, 117, 100, 100 })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "PSS", "two of four trips")
		t.eq(ch:get("protection.firstOut"), "PR-HIGH", "and is the first out")
	end,

	["first-out latches the signal that went first, not the loudest"] = function(t)
		local sys, ch, bus = make()
		local trips = {}
		bus:subscribe("Trip", function(p)
			table.insert(trips, p)
		end)
		run(sys, 1)
		ch:setExternal("pools.coverGas_MPa", PSS.coverGas.trip_MPa * 1.1)
		run(sys, 0.5)
		t.eq(ch:get("protection.firstOut"), "COVER-GAS")
		-- a second, bigger signal arrives: the first-out must not move
		-- 117 %FP is past the PSS's 115 but short of the SSS's 118, so this stays one shutdown system
		ch:setExternal("detectors.pr_pctFP", fill(4, 117))
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "COVER-GAS", "still the first one")
		t.ok(sys:getState().monitors["PR-HIGH"].trip, "even though PR-HIGH is now tripped too")
		t.eq(#trips, 1, "one Trip on the bus, not one per signal")
	end,

	["a trip latches until reset, and reset is refused while the signal is present"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		ch:setExternal("pools.mixedCoreOutletMeasured_K", PSS.coreOutletMixed.trip_C + 5 + KEL)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "PSS")
		local early = sys:applyCommand(OPERATOR, { kind = "reactor.trip.reset" })
		t.ok(not early.ok, "refused while the core outlet is still high")
		ch:setExternal("pools.mixedCoreOutletMeasured_K", PSS.coreOutletMixed.normal_C + KEL)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "PSS", "the trip stays latched even once the signal clears")
		t.ok(sys:applyCommand(OPERATOR, { kind = "reactor.trip.reset" }).ok, "now it resets")
		t.eq(ch:get("protection.scram"), "none")
		t.eq(ch:get("protection.firstOut"), "", "and first-out clears with it")
	end,

	["D-004: the core inlet low trip is inhibited by mode, and says so"] = function(t)
		local sys, ch = make()
		ch:setExternal("pools.coreInlet_K", PSS.coreInlet.tripLow_C - 10 + KEL)

		-- Mode 1 above 5 %FP: armed, and it trips
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "INLET-LOW", "armed in Mode 1 at power")
		t.ok(sys:applyCommand(OPERATOR, { kind = "reactor.trip.reset" }).ok == false, "still present, so no reset")

		for _, case in {
			{ mode = 4, label = "Mode 4" },
			{ mode = 5, label = "Mode 5" },
		} do
			local fresh, fch = make()
			fch:setExternal("pools.coreInlet_K", PSS.coreInlet.tripLow_C - 10 + KEL)
			fch:setExternal("program.mode", case.mode)
			run(fresh, 1)
			t.eq(fch:get("protection.scram"), "none", `inhibited in {case.label}`)
			local inhibited = table.concat(fresh:getState().inhibited, "; ")
			t.ok(string.find(inhibited, "INLET-LOW", 1, true) ~= nil, "and annunciated as inhibited, not silently skipped")
		end

		-- Mode 3 is inhibited only while every PSS rod is in
		local three, tch = make()
		tch:setExternal("pools.coreInlet_K", PSS.coreInlet.tripLow_C - 10 + KEL)
		tch:setExternal("program.mode", 3)
		tch:setExternal("rods.allPssInserted", true)
		run(three, 1)
		t.eq(tch:get("protection.scram"), "none", "Mode 3 with the rods in")
		tch:setExternal("rods.allPssInserted", false)
		run(three, 1)
		t.eq(tch:get("protection.scram"), "PSS", "but armed in Mode 3 with a rod out")

		-- Mode 2 below 350 °C during heatup
		local two, twoCh = make(0)
		twoCh:setExternal("program.mode", 2)
		twoCh:setExternal("pools.coreInlet_K", 300 + KEL)
		run(two, 1)
		t.eq(twoCh:get("protection.scram"), "none", "Mode 2 during heatup")
	end,

	["an alarm on a row that stops being watched goes out on the annunciator"] = function(t)
		local sys, ch, bus = make(30)
		local states = {}
		bus:subscribe("Alarm", function(p)
			if p.tag == "INLET-LOW" then
				table.insert(states, p.state)
			end
		end)
		-- below §9.5's 360 °C alarm and above its 345 °C trip, in Mode 1 at 30 %FP where D-004 arms the row
		ch:setExternal("pools.coreInlet_K", PSS.coreInlet.alarmLow_C - 5 + KEL)
		run(sys, 1)
		t.eq(states[#states], "in", "the low inlet alarms")
		-- the power falls under D-004's 5 %FP arming point, and the row is no longer evaluated
		ch:setExternal("core.power_pctFP", 2)
		ch:setExternal("detectors.pr_pctFP", fill(4, 2))
		run(sys, 1)
		t.eq(states[#states], "out", "so its alarm is announced as gone, not left showing")
		t.eq(#sys:getState().active, 0)
	end,

	["an alarm on a noisy channel does not flicker at the worst steady level (D-050 as amended)"] = function(t)
		--[[
			tools/derive/alarm_deadband.py, computed here from Config for the power range, whose noise is fresh every
			tick (D-025): the alarm is out for 1/p ticks, where p is the chance a tick has a channel past the setpoint,
			and in until r ticks running have every channel back past the deadband, each with chance q. Its flicker
			rate, changes of state per second, is 2 / (tick (1/p + (1 − qʳ)/((1 − q) qʳ))).
		]]
		local noise = Config.Instruments.noise
		local rule = Config.Protection.alarmDeadband
		local alarm = PSS.powerRangeHigh.alarm_pctFP
		local channels = Config.Protection.powerRangeVoting.of
		local r = math.floor(rule.offDelay_s / DT + 0.5)
		local function pq(m: number, deadband: number): (number, number)
			local sigma = noise.powerRangeRelative * m
			local p = 1 - (1 - upper((alarm - m) / sigma)) ^ channels
			local q = upper((m - alarm + deadband) / sigma) ^ channels
			return p, q
		end
		local function rate(m: number, deadband: number, ticks: number): number
			local p, q = pq(m, deadband)
			if p <= 0 or q ^ ticks <= 0 then
				return 0
			end
			return 2 / (DT * (1 / p + (1 - q ^ ticks) / ((1 - q) * q ^ ticks)))
		end
		local function worst(deadband: number, ticks: number): number
			local at, best = 0, -1
			for i = 0, 11000 do
				local m = 95 + i * 0.001
				local v = rate(m, deadband, ticks)
				if v > best then
					at, best = m, v
				end
			end
			return at
		end
		local amended = rule.gaussianSigmas * noise.powerRangeRelative * alarm
		local worstNow = worst(amended, r)
		-- D-050 as it stood: 1σ at the setpoint, out on the first tick back
		local worstBefore = worst(noise.powerRangeRelative * alarm, 1)

		--[[
			The bound on the count C over n ticks, starting out. C is at most twice the ins I, and at most one more
			than twice the outs O. A tick brings an in with chance p at most, whatever came before, so I is no worse
			than Binomial(n, p): expected count n·p. An out ends a run of r back ticks that follows a tick not back,
			with chance (1 − q)·qʳ a tick: expected count n(1 − q)qʳ. Each count is held to its Poisson tail at 5σ's
			one-sided chance, as D-025 bounds noise.
		]]
		local n = math.floor(600 / DT + 0.5)
		local eps = upper(5)
		local function flickers(m: number, seed: number): number
			local sys, ch, bus = make(m)
			local count = 0
			bus:subscribe("Alarm", function(a)
				if a.tag == "PR-HIGH" then
					count += 1
				end
			end)
			local rng = Random.new(seed)
			local pr = table.create(channels, m)
			for _ = 1, n do
				for i = 1, channels do
					pr[i] = m * (1 + noise.powerRangeRelative * gaussian(rng)) -- as Detectors draws a quadrant
				end
				ch:setExternal("detectors.pr_pctFP", pr)
				sys:step(DT)
			end
			return count
		end
		for _, level in { { m = worstNow, what = "the amended rule's worst level" }, { m = worstBefore, what = "the old rule's worst level" } } do
			local p, q = pq(level.m, amended)
			local outs = n * (1 - q) * q ^ r
			local bound = math.min(2 * poissonBound(n * p, eps), 1 + 2 * poissonBound(outs, eps))
			local count = flickers(level.m, 20050 + math.floor(level.m * 100))
			t.log(string.format("PR-HIGH at %.3f %%FP (%s): %d flickers in %d s; expected %.3g (ins ≤ %.3g, outs ≤ %.3g), bound %d",
				level.m, level.what, count, n * DT, rate(level.m, amended, r) * n * DT, n * p, outs, bound))
			t.ok(count <= bound, `PR-HIGH flickers at most {bound} times in {n * DT} s at {level.what}`)
		end

		-- The thermocouple's noise is bounded, so its 2 K deadband is its whole span: once in, the reading is never
		-- back past the deadband. The old rule's worst level, 564.5 °C, is where the 1 K deadband flickered 2.5 times
		-- a second.
		local tc = Config.Core.flow.thermocoupleNoise_K
		local sys, ch, bus = make()
		local count = 0
		bus:subscribe("Alarm", function(a)
			if a.tag == "CORE-OUT" then
				count += 1
			end
		end)
		local rng = Random.new(20051)
		local held = PSS.coreOutletMixed.alarm_C - tc / 2
		for _ = 1, n do
			ch:setExternal("pools.mixedCoreOutletMeasured_K", held + KEL + tc * (rng:NextNumber() * 2 - 1)) -- as Pools
			sys:step(DT)
		end
		t.ok(count <= 1, `CORE-OUT at {held} °C comes in and stays in ({count} changes of state)`)
	end,

	["an alarm goes out once its signal has stayed back for the off-delay, and a row with no noise has neither (D-050 as amended)"] = function(t)
		local noise = Config.Instruments.noise
		local rule = Config.Protection.alarmDeadband
		local dndAlarm = DND * PSS.delayedNeutrons.alarmFactor
		local ticks = math.floor(rule.offDelay_s / DT + 0.5)
		local rows = {
			{
				-- one power range quadrant: 3σ of D-025's relative noise at the setpoint, and the off-delay
				id = "PR-HIGH", alarm = PSS.powerRangeHigh.alarm_pctFP, delay = ticks,
				band = rule.gaussianSigmas * noise.powerRangeRelative * PSS.powerRangeHigh.alarm_pctFP,
				set = function(ch: any, v: number)
					ch:setExternal("detectors.pr_pctFP", { v, 100, 100, 100 })
				end,
			},
			{
				-- one DND: 3σ of its Poisson noise at the setpoint, σ = √(R/τ) over the ratemeter's averaging, and the
				-- off-delay
				id = "DND", alarm = dndAlarm, delay = ticks,
				band = rule.gaussianSigmas * math.sqrt(dndAlarm / noise.ratemeterAveraging_s),
				set = function(ch: any, v: number)
					ch:setExternal("detectors.dnd_cps", { v, DND, DND, DND, DND, DND })
				end,
			},
			{
				-- the mixed outlet thermocouple: the whole span of §2.5's ±1 K, and no off-delay
				id = "CORE-OUT", alarm = PSS.coreOutletMixed.alarm_C, delay = 1,
				band = 2 * Config.Core.flow.thermocoupleNoise_K,
				set = function(ch: any, v: number)
					ch:setExternal("pools.mixedCoreOutletMeasured_K", v + KEL)
				end,
			},
		}
		for _, row in rows do
			local sys, ch, bus = make()
			local states = {}
			bus:subscribe("Alarm", function(a)
				if a.tag == row.id then
					table.insert(states, a.state)
				end
			end)
			local inside, back = row.alarm - row.band / 2, row.alarm - 1.01 * row.band
			row.set(ch, row.alarm + row.band / 2)
			run(sys, DT)
			t.eq(states[#states], "in", `{row.id} comes in at its setpoint`)
			row.set(ch, inside)
			run(sys, 10)
			t.eq(#states, 1, `{row.id} stays in while the signal is inside its deadband`)
			if row.delay > 1 then
				row.set(ch, back)
				run(sys, (row.delay - 1) * DT)
				row.set(ch, inside)
				run(sys, DT)
				t.eq(#states, 1, `{row.id} stays in when the signal comes back inside a tick before the off-delay ends`)
				row.set(ch, back)
				run(sys, (row.delay - 1) * DT)
				t.eq(#states, 1, `{row.id} counts the off-delay again from there`)
			else
				row.set(ch, back)
			end
			run(sys, DT)
			t.eq(states[#states], "out", `{row.id} goes out on the {row.delay}th tick back past its deadband`)
			t.eq(#states, 2, `{row.id}: one in and one out`)
		end

		-- the cover gas pressure has no modelled noise, so it cannot chatter, and it has no deadband or off-delay
		local sys, ch, bus = make()
		local states = {}
		bus:subscribe("Alarm", function(a)
			if a.tag == "COVER-GAS" then
				table.insert(states, a.state)
			end
		end)
		local nudge = 1e-6 * PSS.coverGas.alarm_MPa
		for _ = 1, 5 do
			ch:setExternal("pools.coverGas_MPa", PSS.coverGas.alarm_MPa + nudge)
			run(sys, DT)
			ch:setExternal("pools.coverGas_MPa", PSS.coverGas.alarm_MPa - nudge)
			run(sys, DT)
		end
		t.eq(#states, 10, "COVER-GAS goes in and out on every crossing: with no noise there is no deadband")
	end,

	["the 25 %FP low setpoint protects a startup and bypasses itself above the permissive"] = function(t)
		local sys, ch = make(2)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "quiet at 2 %FP")
		-- a fast excursion while still under the permissive
		ch:setExternal("detectors.pr_pctFP", fill(4, 30))
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "PR-LOW-SP", "§9.5's low setpoint catches it at 25 %FP")

		-- above the permissive it is bypassed, so a normal ascension past 25 % does not trip
		local up, uch = make(40)
		run(up, 1)
		t.eq(uch:get("protection.scram"), "none", "40 %FP is normal operation, not a trip")
	end,

	["the period trip and rod block are armed only below 10 %FP, and the block persists (D-025)"] = function(t)
		local sys, ch = make()
		ch:setExternal("detectors.period_s", { 20, 20, 20 })
		run(sys, 5)
		t.ok(not ch:get("protection.rodWithdrawalBlock"), "a 20 s period at full power is not even evaluated")

		local low, lch = make(5)
		lch:setExternal("detectors.period_s", { 20, 20, 20 })
		run(low, 1)
		t.ok(not low:getState().monitors["PERIOD"].block, "one second is not enough to raise the block")
		run(low, 3)
		t.ok(low:getState().monitors["PERIOD"].block, "but it holds, so the block comes in")
		t.ok(lch:get("protection.rodWithdrawalBlock"))
		t.eq(lch:get("protection.scram"), "none", "20 s is a block, not the 10 s trip")
		lch:setExternal("detectors.period_s", { 8, 8, 8 })
		run(low, 1)
		t.eq(lch:get("protection.firstOut"), "PERIOD", "8 s trips")
	end,

	["losing pumps and loops: one is a runback, two is a trip (§9.5)"] = function(t)
		local sys, ch, bus = make()
		local runbacks = {}
		bus:subscribe("Runback", function(p)
			table.insert(runbacks, p)
		end)
		run(sys, 1)
		ch:setExternal("primary.pumpsRunning", 2)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "one pump lost is not a trip")
		t.eq(ch:get("protection.runback"), "RB2", "§9.5: RB-2")
		t.eq(ch:get("protection.runbackTarget_pctFP"), Config.Protection.runbacks.RB2.target_pctFP, "to 60 %FP")
		t.eq(ch:get("protection.runbackRate_pctpmin"), Config.Protection.runbacks.RB2.rate_pctpmin, "at 60 %/min")
		t.eq(#runbacks, 1)
		ch:setExternal("primary.pumpsRunning", 1)
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "PUMPS", "two lost trips")

		local loops, lch, lbus = make()
		local seen = {}
		lbus:subscribe("Runback", function(p)
			table.insert(seen, p)
		end)
		lch:setExternal("ihx.loopsRunning", 2)
		run(loops, 1)
		t.eq(lch:get("protection.runback"), "RB1", "§9.5: one secondary loop lost is RB-1")
		t.ok(lch:get("protection.rodRunback"), "which drives the shim banks in")
		lch:setExternal("ihx.loopsRunning", 1)
		run(loops, 1)
		t.eq(lch:get("protection.firstOut"), "LOOPS", "two lost trips")
	end,

	["a runback starts on its trigger's rising edge, so a clear sticks and a finished one stays finished (D-046)"] = function(t)
		local sys, ch, bus = make()
		local starts = 0
		bus:subscribe("Runback", function()
			starts += 1
		end)
		run(sys, 1)
		ch:setExternal("primary.pumpsRunning", 2)
		run(sys, DT)
		t.eq(ch:get("protection.runback"), "RB2", "one pump lost starts RB-2")
		t.ok(sys:applyCommand(OPERATOR, { kind = "runback.clear" }).ok, "the operator clears it")
		run(sys, 10)
		t.eq(ch:get("protection.runback"), "", "and it stays cleared while the pump is still lost")
		t.eq(starts, 1, "nothing restarted it")

		-- the pump comes back, which resets the trigger, and the next loss is a new event
		ch:setExternal("primary.pumpsRunning", 3)
		run(sys, 1)
		t.eq(ch:get("protection.runback"), "", "a trigger resetting starts nothing")
		ch:setExternal("primary.pumpsRunning", 2)
		run(sys, DT)
		t.eq(ch:get("protection.runback"), "RB2", "the next loss starts RB-2 again")
		t.eq(starts, 2)

		-- the power runs back: the demand takes 40 s from 100 to 60 %FP at 60 %/min, and the runback then ends
		local rb = Config.Protection.runbacks.RB2
		ch:setExternal("detectors.pr_pctFP", fill(4, rb.target_pctFP))
		ch:setExternal("detectors.prMean_pctFP", rb.target_pctFP)
		t.eq(ch:get("protection.rodRunback"), true, "the drive-in runs while the power is above the demand")
		run(sys, DT)
		t.eq(ch:get("protection.rodRunback"), false, "and stops once the power is below it")
		run(sys, (100 - rb.target_pctFP) / (rb.rate_pctpmin / 60) + 1)
		t.eq(ch:get("protection.runback"), "", "RB-2 is complete once its demand and the power are at its target")
		run(sys, 10)
		t.eq(ch:get("protection.runback"), "", "and, with the pump still lost, it does not start again")
		t.eq(starts, 2)
	end,

	["a milder runback refused while a deeper one runs starts once that one is cleared (D-046)"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		ch:setExternal("primary.pumpsRunning", 2)
		run(sys, DT)
		t.eq(ch:get("protection.runback"), "RB2", "a pump lost starts RB-2, to 60 %FP")
		ch:setExternal("ihx.loopsRunning", 2)
		run(sys, 1)
		t.eq(ch:get("protection.runback"), "RB2", "a loop lost as well: RB-1's 64 %FP is milder, so RB-2 runs on")
		t.ok(sys:applyCommand(OPERATOR, { kind = "runback.clear" }).ok, "the operator clears RB-2")
		run(sys, DT)
		t.eq(ch:get("protection.runback"), "RB1", "RB-1, which never ran, starts: its trigger is still there")
		t.ok(sys:applyCommand(OPERATOR, { kind = "runback.clear" }).ok, "and once it too is cleared")
		run(sys, 5)
		t.eq(ch:get("protection.runback"), "", "neither restarts while their triggers persist")
	end,

	["a runback with no depth to run to is refused, so it cannot halt the plant later (§9.5 RB-3)"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		local r = sys:applyCommand(OPERATOR, { kind = "runback.start", target = "RB3" })
		t.ok(not r.ok, "RB-3's bypass-limited target is not a power the plant can run to")
		t.eq(ch:get("protection.runback"), "", "so no runback is running")
		-- a pump lost afterwards starts RB-2 as usual, instead of failing on RB-3's missing target
		ch:setExternal("primary.pumpsRunning", 2)
		local ok, err = pcall(run, sys, 1)
		t.ok(ok, `the protection step survives: {tostring(err)}`)
		t.eq(ch:get("protection.runback"), "RB2")
	end,

	["power to flow: alarm and rod block at 1.05, trip at 1.12, armed above 5 %FP"] = function(t)
		local sys, ch = make()
		ch:setExternal("primary.flowFraction", 1 / (PSS.powerToFlow.alarm * 1.001))
		run(sys, 1)
		t.ok(sys:getState().monitors["PQ"].alarm, "§9.5: 1.05 alarms")
		t.ok(ch:get("protection.rodWithdrawalBlock"), "and blocks rod withdrawal")
		t.eq(ch:get("protection.scram"), "none")
		ch:setExternal("primary.flowFraction", 1 / (PSS.powerToFlow.trip * 1.01))
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "PQ", "1.12 trips")

		-- below the 5 %FP permissive, a low flow is a normal shutdown state rather than a fault
		local cold, cch = make(1)
		cch:setExternal("primary.flowFraction", 0.03)
		run(cold, 1)
		t.eq(cch:get("protection.scram"), "none", "not armed below 5 %FP")
	end,

	["the SSS is diverse: it trips on pump-speed flow when the flowmeter says otherwise"] = function(t)
		local sys, ch = make()
		-- the PSS flow signal reads healthy, but the pumps have actually slowed: the SSS sees it
		ch:setExternal("primary.flowFraction", 1.0)
		ch:setExternal("primary.pumpSpeed_pct", { 50, 50, 50 })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "SSR", "§9.5: the SSS uses pump-speed-derived flow")
		t.eq(ch:get("protection.firstOut"), "SSS-PQ")
		t.ok(not sys:getState().monitors["PQ"].trip, "while the PSS's own power-to-flow is happy")
	end,

	["the Curie latch releases the SSRs at 640 °C with its thermal lag (§9.5)"] = function(t)
		local sys, ch = make()
		local latch = Config.Rods.curieLatch
		run(sys, 1) -- let the latch settle at the normal sodium temperature before anything moves
		ch:setExternal("fuel.assemblyOutlet_K", fill(5, latch.releaseSodium_C + 40 + KEL))
		run(sys, latch.thermalLag_s * 0.3)
		t.eq(ch:get("protection.scram"), "none", "the lag holds it off at first")
		run(sys, latch.thermalLag_s * 2)
		t.eq(ch:get("protection.firstOut"), "CURIE", "and then it releases")
		t.eq(ch:get("protection.scram"), "SSR", "the secondary shutdown rods, not the PSS")
	end,

	["the MCR trip is MCR-1 and MCR-2 within 2 s of each other; the BCR is one button (§9.5, D-056)"] = function(t)
		local window = Config.Protection.manualTripWindow_s
		local function press(sys: any, button: string): any
			return sys:applyCommand(OPERATOR, { kind = "reactor.trip.manual", target = button })
		end

		local sys, ch = make()
		run(sys, 1)
		t.ok(press(sys, "MCR-1").ok and press(sys, "MCR-1").ok, "both presses taken")
		run(sys, 0.1)
		t.eq(ch:get("protection.scram"), "none", "one button pressed twice is not a trip")

		sys, ch = make()
		run(sys, 1)
		press(sys, "MCR-1")
		realNow += window + 0.5
		run(sys, 0.1)
		t.eq(next(sys:getState().manual), nil, "a single press is forgotten once the window has passed")
		press(sys, "MCR-2")
		run(sys, 0.1)
		t.eq(ch:get("protection.scram"), "none", "so two presses further apart than the window are not a trip")

		sys, ch = make()
		run(sys, 1)
		press(sys, "MCR-2")
		realNow += window - 0.5
		press(sys, "MCR-1")
		run(sys, 0.1)
		t.eq(ch:get("protection.firstOut"), "MANUAL", "MCR-1 and MCR-2 within the window trip the reactor")
		t.ok(not press(sys, "MCR").ok, "a button the control room does not have is refused")

		local backup, bch = make()
		backup:applyCommand(OPERATOR, { kind = "reactor.trip.manual", target = "BCR" })
		run(backup, 0.1)
		t.eq(bch:get("protection.scram"), "PSS", "one button in the backup control room is enough")
	end,

	["the MCR trip window is real time, so a faster plant clock does not shrink it (D-056)"] = function(t)
		local window = Config.Protection.manualTripWindow_s
		local function press(sys: any, button: string): any
			return sys:applyCommand(OPERATOR, { kind = "reactor.trip.manual", target = button })
		end
		-- the plant clock at ×10: five plant seconds pass while two people take half a real second
		local sys, ch = make()
		run(sys, 1)
		press(sys, "MCR-1")
		realNow += 0.5
		run(sys, 5)
		press(sys, "MCR-2")
		run(sys, 0.1)
		t.eq(ch:get("protection.firstOut"), "MANUAL", "half a second apart is one act, however far the plant ran")
		-- and a slow pair of presses is two acts, however little plant time passed between them
		sys, ch = make()
		run(sys, 1)
		press(sys, "MCR-1")
		realNow += window + 0.5
		press(sys, "MCR-2")
		run(sys, 0.1)
		t.eq(ch:get("protection.scram"), "none", `{window + 0.5} real seconds apart is not a trip`)
	end,

	["a bypass is one row at a time, and never a row the neutron instruments drive (D-055)"] = function(t)
		local sys = make()
		local function bypass(id: string, on: boolean): any
			return sys:applyCommand(OPERATOR, { kind = "pss.bypass", target = id, value = if on then 1 else 0 })
		end
		for _, id in { "PR-HIGH", "PR-LOW-SP", "FLUX-RATE", "PERIOD", "SSS-FLUX" } do
			local r = bypass(id, true)
			t.ok(not r.ok, `{id} cannot be bypassed ({r.reason})`)
			t.eq(sys:getState().monitors[id].bypassed, false)
		end
		t.ok(bypass("COVER-GAS", true).ok, "a process row can be")
		local r = bypass("SEISMIC", true)
		t.ok(not r.ok and string.find(r.reason or "", "COVER-GAS", 1, true) ~= nil,
			`but only one at a time, and the refusal names the row to restore first ({r.reason})`)
		t.eq(sys:getState().monitors["SEISMIC"].bypassed, false)
		t.ok(bypass("COVER-GAS", true).ok, "bypassing the same row again changes nothing")
		t.ok(bypass("COVER-GAS", false).ok, "restored")
		t.ok(bypass("SEISMIC", true).ok, "and then another row can be bypassed")
	end,

	["a bypassed signal cannot trip, and the bypass is logged"] = function(t)
		local sys, ch = make()
		t.ok(sys:applyCommand(OPERATOR, { kind = "pss.bypass", target = "COVER-GAS", value = 1 }).ok)
		ch:setExternal("pools.coverGas_MPa", PSS.coverGas.trip_MPa * 1.2)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "bypassed")
		t.ok(sys:getState().monitors["COVER-GAS"].alarm, "but the alarm still comes in, so it is visible")
		t.ok(sys:applyCommand(OPERATOR, { kind = "pss.bypass", target = "COVER-GAS", value = 0 }).ok)
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "COVER-GAS", "and restoring it trips immediately")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "pss.bypass", target = "NOT-A-SIGNAL", value = 1 }).ok)
	end,

	["assembly outlet deviation needs two channels, not one (§9.5)"] = function(t)
		local sys, ch = make()
		local normal = 832
		local trip = PSS.assemblyOutletDeviation.trip_K
		ch:setExternal("fuel.assemblyOutlet_K", { normal + trip + 5, normal, normal, normal, normal })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "one hot assembly is not a trip")
		t.ok(sys:getState().monitors["ASSY-DEV"].alarm, "it alarms")
		t.ok(ch:get("protection.rodWithdrawalBlock"), "and blocks withdrawal at +30 K")
		ch:setExternal("fuel.assemblyOutlet_K", { normal + trip + 5, normal + trip + 5, normal, normal, normal })
		run(sys, 1)
		t.eq(ch:get("protection.firstOut"), "ASSY-DEV", "two is")
	end,

	["assembly outlets are compared with their median, so the majority is never the deviation (§9.5)"] = function(t)
		local sys, ch = make()
		local normal = 832
		local step = PSS.assemblyOutletDeviation.trip_K + 5
		-- three of five read the same, two read cooler: the three are what the core is doing, not a blockage
		ch:setExternal("fuel.assemblyOutlet_K", { normal, normal, normal + step, normal + step, normal + step })
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "the majority reading is the expected outlet")
		t.ok(not sys:getState().monitors["ASSY-DEV"].alarm, "and nothing deviates above it")
	end,

	["every §9.5 trip row exists, and the ones M1 cannot drive yet sit at safe values"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		local rows = sys:getState().monitors
		for _, id in {
			"PR-HIGH", "PR-LOW-SP", "PERIOD", "FLUX-RATE", "PQ", "CORE-OUT", "ASSY-DEV",
			"INLET-HIGH", "INLET-LOW", "LEVEL", "COVER-GAS", "DND", "PUMPS", "LOOPS",
			"SEISMIC", "ELEC-11KV", "SSS-FLUX", "SSS-PQ", "SSS-OUT",
		} do
			t.ok(rows[id] ~= nil, `§9.5 row {id} is implemented`)
		end
		-- the externals that belong to systems M1 does not build: wired, inert, and safe until written
		ch:setExternal("site.seismic_g", PSS.seismic.trip_g * 1.1)
		run(sys, 0.5)
		t.eq(ch:get("protection.firstOut"), "SEISMIC", "seismic is wired, and trips when something writes it")
		t.ok(sys:applyCommand(OPERATOR, { kind = "reactor.trip.reset" }).ok == false, "still shaking")
	end,

	["flux rate trips on a fall as well as a rise (§9.5, Phénix-style)"] = function(t)
		local sys, ch = make()
		ch:setExternal("detectors.fluxRate_pctFPps", PSS.fluxRate.tripRise_pctFPps * 0.9)
		run(sys, 1)
		t.eq(ch:get("protection.scram"), "none", "inside the rise limit")
		ch:setExternal("detectors.fluxRate_pctFPps", PSS.fluxRate.tripRise_pctFPps * 1.1)
		run(sys, 0.5)
		t.eq(ch:get("protection.firstOut"), "FLUX-RATE", "a rise past +10 %FP/s")

		local down, dch = make()
		dch:setExternal("detectors.fluxRate_pctFPps", PSS.fluxRate.tripFall_pctFPps * 0.9)
		run(down, 1)
		t.eq(dch:get("protection.scram"), "none", "inside the fall limit")
		dch:setExternal("detectors.fluxRate_pctFPps", PSS.fluxRate.tripFall_pctFPps * 1.1)
		run(down, 0.5)
		t.eq(dch:get("protection.firstOut"), "FLUX-RATE", "and a fall past −5 %FP/s")
	end,
}
