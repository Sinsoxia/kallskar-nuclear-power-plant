--!strict
--[[
	Detectors verification (spec §3.5, §9.5).

	The statistical tests are the point of this file. They do not check that the noise matches a number someone
	picked — they check that it matches 1/√(Rτ), which is what counting statistics say it must be, and that with
	the D-025 filters no channel's noise can reach a §9.5 setpoint on its own.
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
local Detectors = require(Root:WaitForChild("Systems"):WaitForChild("Detectors")) :: any

local INST = Config.Instruments
local PSS = Config.Protection.pss
local DT = 1 / Config.Clocks.fast_Hz
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

-- §3.3 excess against §3.4's total rod worth: the state §3.5 quotes "about 250 cps" for
local ALL_RODS_IN_PCM = Config.Reactivity.budget_pcm.requiredExcessAt230AllRodsOut
	- (Config.Rods.regulating.worthTotal_pcm + Config.Rods.shim.worthTotal_pcm
		+ Config.Rods.secondaryShutdown.worthTotal_pcm)

--[[
	D-049: the ratemeters and filters are first-order lags, so a channel sampled every tick is an AR(1) series with
	φ = e^(−dt/τ). Over n ticks it carries n(1 − φ)/(1 + φ) independent values for its mean and n(1 − φ²)/(1 + φ²)
	for its variance or a correlation, and the tests take 3σ on those effective counts.
]]
local function effectiveMean(n: number, tau: number): number
	local phi = math.exp(-DT / tau)
	return n * (1 - phi) / (1 + phi)
end
local function effectiveVariance(n: number, tau: number): number
	local phi = math.exp(-2 * DT / tau)
	return n * (1 - phi) / (1 + phi)
end

local function kOf(rho_pcm: number): number
	return 1 / (1 - rho_pcm / 1e5)
end

local function make(power: number?, k: number?)
	local ch = Channels.new()
	ch:declareExternal("core.power_pctFP", power or 0)
	ch:declareExternal("core.k", k or kOf(ALL_RODS_IN_PCM))
	local sys = System.new(Detectors)
	sys:init({
		config = Config,
		channels = ch:port(Detectors.spec),
		log = EventLog.new(Config, { sim = 0, grid = 0 }),
		bus = Bus.new(),
	})
	return sys, ch
end

local function run(sys: any, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
	end
end

-- Mean and relative standard deviation of a channel over a run, sampled once per tick.
local function statistics(sys: any, ch: any, name: string, index: number, seconds: number)
	local n, sum, sumsq = 0, 0, 0
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
		local v = (ch:get(name) :: any)[index]
		n += 1
		sum += v
		sumsq += v * v
	end
	local mean = sum / n
	local variance = math.max(sumsq / n - mean * mean, 0)
	return mean, math.sqrt(variance) / mean
end

return {
	["§3.5's 250 cps with all rods in follows from §3.3 and §3.4"] = function(t)
		local sys, ch = make(0, kOf(ALL_RODS_IN_PCM))
		run(sys, 20)
		local rate = sys:trueCountRate(kOf(ALL_RODS_IN_PCM))
		t.log(string.format("ρ %.0f pcm → k %.5f → %.1f cps (§3.5 says about %d)",
			ALL_RODS_IN_PCM, kOf(ALL_RODS_IN_PCM), rate, INST.sourceRangeAllRodsIn_cps))
		t.near(rate, INST.sourceRangeAllRodsIn_cps, 5, "§3.5: about 250 cps")
		t.near(ch:get("detectors.srMedian_cps"), INST.sourceRangeAllRodsIn_cps, 40, "the channels read it, noisily")
		-- the formula's floor and ceiling
		t.near(sys:trueCountRate(0), INST.sourceRangeConstant_cps, 1e-9, "k = 0 is the bare source, 15 cps")
		t.near(sys:trueCountRate(1.0), INST.sourceRange.span_cps[2], 1e-9, "critical is off the top of the span")
	end,

	["source range noise is counting statistics, not a tuned figure"] = function(t)
		-- σ/R = 1/√(Rτ) with τ the ratemeter's averaging time. No parameter in this prediction is free.
		local tau = INST.noise.ratemeterAveraging_s
		local seconds = 400
		local lag = tau / 2 -- the ratemeter's first-order time constant (Detectors: ratemeterTau)
		local nMean = effectiveMean(seconds / DT, lag)
		local nVar = effectiveVariance(seconds / DT, lag)
		for _, rho in { ALL_RODS_IN_PCM, -2000 } do
			local sys, ch = make(0, kOf(rho))
			run(sys, 30) -- let the ratemeter settle before sampling
			local rate = sys:trueCountRate(kOf(rho))
			local mean, relative = statistics(sys, ch, "detectors.sr_cps", 1, seconds)
			local predicted = 1 / math.sqrt(rate * tau)
			t.log(string.format("%.0f cps: σ/R measured %.2f %%, counting statistics predict %.2f %% (%.0f and %.0f effective samples)",
				rate, relative * 100, predicted * 100, nMean, nVar))
			-- 3σ of the mean, and of a standard deviation (relative standard error 1/√(2n)), on the effective counts
			t.near(mean, rate, 3 * rate * predicted / math.sqrt(nMean), "unbiased")
			t.near(relative, predicted, 3 * predicted / math.sqrt(2 * nVar), "1/√(Rτ)")
		end
	end,

	["the three source range channels are independent, which is what voting needs"] = function(t)
		local sys, ch = make(0, kOf(ALL_RODS_IN_PCM))
		run(sys, 30)
		local n, sxy, sx, sy, sxx, syy = 0, 0, 0, 0, 0, 0
		for _ = 1, 2000 do
			sys:step(DT)
			local a = (ch:get("detectors.sr_cps") :: any)[1]
			local b = (ch:get("detectors.sr_cps") :: any)[2]
			n += 1
			sx += a
			sy += b
			sxy += a * b
			sxx += a * a
			syy += b * b
		end
		local cov = sxy / n - (sx / n) * (sy / n)
		local correlation = cov / math.sqrt(math.max(sxx / n - (sx / n) ^ 2, 1e-12)
			* math.max(syy / n - (sy / n) ^ 2, 1e-12))
		-- D-049: two independent AR(1) series correlate by chance with σ = 1/√(effective count) (Bartlett)
		local limit = 3 / math.sqrt(effectiveVariance(2000, INST.noise.ratemeterAveraging_s / 2))
		t.log(string.format("SR1 against SR2: correlation %.3f (3σ for independent channels: %.3f)", correlation, limit))
		t.ok(math.abs(correlation) < limit, "channels do not wander together")
	end,

	["the source range high voltage drops out above §3.5's 1e-3 %FP, with hysteresis"] = function(t)
		local sys, ch = make(0, kOf(-500))
		run(sys, 5)
		t.ok(ch:get("detectors.srEnergised"), "energised at zero power")
		ch:setExternal("core.power_pctFP", INST.sourceRangeHighVoltageOffAbove_pctFP * 2)
		run(sys, 1)
		t.ok(not ch:get("detectors.srEnergised"), "§3.5: off above 1e-3 %FP")
		t.eq((ch:get("detectors.sr_cps") :: any)[1], 0, "and reads nothing")
		-- coming back down, it does not re-energise at the same point, so it cannot chatter
		ch:setExternal("core.power_pctFP", INST.sourceRangeHighVoltageOffAbove_pctFP * 0.5)
		run(sys, 1)
		t.ok(not ch:get("detectors.srEnergised"), "still off just below the cut-off")
		ch:setExternal("core.power_pctFP", INST.sourceRangeHighVoltageOnBelow_pctFP * 0.5)
		run(sys, 1)
		t.ok(ch:get("detectors.srEnergised"), "back on a decade lower (D-025)")
	end,

	["1/M falls toward zero as the core approaches critical (§3.5)"] = function(t)
		local sys, ch = make(0, kOf(ALL_RODS_IN_PCM))
		run(sys, 20)
		t.ok(sys:applyCommand(OPERATOR, { kind = "ni.reference" }).ok, "latch the reference count rate")
		t.near(ch:get("detectors.oneOverM"), 1, 0.2, "1/M starts at 1")
		local previous = ch:get("detectors.oneOverM")
		for _, rho in { -4000, -2000, -1000, -400, -100 } do
			ch:setExternal("core.k", kOf(rho))
			run(sys, 30)
			local value = ch:get("detectors.oneOverM")
			t.ok(value < previous, string.format("1/M falls as ρ goes to %d pcm", rho))
			previous = value
		end
		t.ok(previous < 0.1, "and is heading for zero at critical")
		t.log(string.format("1/M at −100 pcm is %.3f", previous))
	end,

	["power range noise cannot reach §9.5's trip or its flux rate trip"] = function(t)
		local sys, ch = make(100, 1.0)
		run(sys, 20)
		local worstPower, worstRate = 0, 0
		for _ = 1, 3000 do
			sys:step(DT)
			for _, v in ch:get("detectors.pr_pctFP") :: any do
				worstPower = math.max(worstPower, v)
			end
			worstRate = math.max(worstRate, math.abs(ch:get("detectors.fluxRate_pctFPps")))
		end
		t.log(string.format("at 100 %%FP over five minutes: worst channel %.2f %%FP, worst flux rate %.3f %%FP/s",
			worstPower, worstRate))
		t.ok(worstPower < PSS.powerRangeHigh.trip_pctFP, "never reaches the 115 %FP trip")
		t.ok(worstPower < PSS.powerRangeHigh.alarm_pctFP, "nor even the 105 %FP alarm")
		-- Without D-025's filter, 0.5 % noise over a 0.1 s tick is 7 %FP/s of pure nothing. With it, σ is
		-- 1.0 %FP/s on the median of four channels, so the trip sits ten σ away and five minutes of sampling
		-- reaches about two.
		t.ok(worstRate < PSS.fluxRate.tripRise_pctFPps * 0.5,
			"the filtered flux rate stays inside half of §9.5's 10 %FP/s")
	end,

	["period noise cannot fake §9.5's period rod block"] = function(t)
		local sys, ch = make(50, 1.0)
		run(sys, 60) -- let the period filter settle at steady power
		local shortest = math.huge
		for _ = 1, 3000 do
			sys:step(DT)
			local p = ch:get("detectors.periodMedian_s")
			if p > 0 then
				shortest = math.min(shortest, p)
			end
		end
		--[[
			σ of the apparent period is 1/(√2 × 0.02 / 5 s) = 177 s. Five minutes of correlated ticks is only about
			thirty independent draws, so this samples roughly 3σ, or 59 s — which is why the assertion is against
			the §9.5 setpoint rather than against σ. A longer session samples deeper into the tail: at 4.5σ the
			apparent period reads 39 s, so Protection must require the period rod block to PERSIST rather than act
			on one sample (noted in D-025).
		]]
		t.log(string.format("steady power, five minutes: shortest apparent period %.0f s (σ is 177 s)", shortest))
		t.ok(shortest > PSS.period.rodBlockBelow_s * 1.5, "clear of §9.5's 30 s rod block")
		t.ok(shortest > PSS.period.tripBelow_s * 4, "and far clear of its 10 s trip")
	end,

	["a real power rise shows up as a period the meter can read"] = function(t)
		local sys, ch = make(1, 1.0)
		run(sys, 60)
		-- A true 30 s period sits 5.9σ above this channel's own noise, which is what makes it measurable at all.
		-- A 60 s period would be 2.9σ, where any single sample could be noise rather than signal.
		local truePeriod = 30
		local power, sum, n = 1, 0, 0
		for i = 1, 1200 do
			power *= math.exp(DT / truePeriod)
			ch:setExternal("core.power_pctFP", power)
			sys:step(DT)
			if i > 900 then -- past the filter's settling; average rather than trusting one reading
				sum += ch:get("detectors.periodMedian_s")
				n += 1
			end
		end
		local measured = sum / n
		--[[
			D-049: once settled (90 s is eighteen of the 5 s filter's time constants) the filter reads d(ln P)/dt =
			1/T exactly, so what is left is noise. Each wide range channel's 2 % (D-025) differenced and filtered
			gives the rate a σ of (α/dt)·σ_w·√(2/(1 + φ)), with α = 1 − φ; the median of three divides the variance by
			1/(1 − √3/π); and the period 1/rate turns that into T²σ, with a bias of T·(σ/ω)² from the curvature.
			The 300 averaged ticks are one AR(1) series through the filter, so their mean has n(1 − φ)/(1 + φ)
			independent values, and the bound is the bias plus 3σ of that mean.
		]]
		local phi = math.exp(-DT / INST.noise.periodFilter_s)
		local sigmaRate = (1 - phi) / DT * INST.noise.wideRangeRelative * math.sqrt(2 / (1 + phi))
			* math.sqrt(1 - math.sqrt(3) / math.pi)
		local relative = sigmaRate * truePeriod -- σ of the rate against the true rate 1/T
		local bound = truePeriod * relative ^ 2 + 3 * truePeriod * relative / math.sqrt(n * (1 - phi) / (1 + phi))
		t.log(string.format("a true %d s period reads as %.1f s (bound ±%.1f s)", truePeriod, measured, bound))
		t.near(measured, truePeriod, bound, "the period meter finds it")
		t.ok(ch:get("detectors.fluxRate_pctFPps") > 0, "and the flux rate is positive")
	end,

	["delayed neutron detectors: background, and DND-HIGH against §9.5's factors"] = function(t)
		local sys, ch = make(100, 1.0)
		run(sys, 30)
		local mean, relative = statistics(sys, ch, "detectors.dnd_cps", 1, 300)
		t.near(mean, INST.dndBackground_cps, INST.dndBackground_cps * 0.1, "§3.5: ≈ 40 cps background")
		t.near(relative, 1 / math.sqrt(INST.dndBackground_cps * INST.noise.ratemeterAveraging_s),
			0.35 / math.sqrt(INST.dndBackground_cps * INST.noise.ratemeterAveraging_s), "counting statistics again")

		local fault = Detectors.faults[2]
		t.eq(fault.id, "DND-HIGH")
		fault.arm(sys, { factor = PSS.delayedNeutrons.alarmFactor })
		run(sys, 60)
		t.near(ch:get("detectors.dndMedian_cps"), INST.dndBackground_cps * PSS.delayedNeutrons.alarmFactor,
			INST.dndBackground_cps * 0.5, "§9.5's alarm factor of 3 reads as three times background")
		fault.clear(sys)
		run(sys, 60)
		t.near(ch:get("detectors.dndMedian_cps"), INST.dndBackground_cps, INST.dndBackground_cps * 0.5,
			"and it comes back down")
	end,

	["NI-FAIL: a failed channel is outvoted, a frozen one is the dangerous kind"] = function(t)
		local sys, ch = make(100, 1.0)
		run(sys, 20)
		local fault = Detectors.faults[1]
		t.eq(fault.id, "NI-FAIL")

		fault.arm(sys, { channel = "PR1", mode = "low" })
		run(sys, 5)
		t.eq((ch:get("detectors.pr_pctFP") :: any)[1], 0, "PR1 reads nothing")
		t.near(ch:get("detectors.prMean_pctFP"), 100, 2, "the median of four survives one dead channel")

		fault.clear(sys, { channel = "PR1" })
		fault.arm(sys, { channel = "PR2", mode = "high" })
		run(sys, 5)
		t.near((ch:get("detectors.pr_pctFP") :: any)[2], INST.powerRange.span_pctFP[2], 1e-9,
			"a saturated channel pegs at the top of its span")
		t.near(ch:get("detectors.prMean_pctFP"), 100, 4, "and is still outvoted")

		fault.clear(sys, { channel = "PR2" })
		fault.arm(sys, { channel = "PR3", mode = "freeze" })
		local frozen = (ch:get("detectors.pr_pctFP") :: any)[3]
		ch:setExternal("core.power_pctFP", 40)
		run(sys, 5)
		t.near((ch:get("detectors.pr_pctFP") :: any)[3], frozen, 1e-9, "a frozen channel keeps its last reading")
		-- the frozen quadrant still reads full power with the plant at 40 %FP; the median of the four quadrants, which
		-- Detectors writes as prMean_pctFP, sets it aside, to within four standard deviations of one channel's D-025
		-- noise at 40 %FP
		t.near(ch:get("detectors.prMean_pctFP"), 40, 4 * INST.noise.powerRangeRelative * 40,
			"the median of four is not dragged by one frozen quadrant")
	end,

	["every channel count matches §3.5"] = function(t)
		local sys, ch = make(10, 1.0)
		sys:step(DT)
		t.eq(#(ch:get("detectors.sr_cps") :: any), INST.sourceRange.channels, "3 source range")
		t.eq(#(ch:get("detectors.wr_pctFP") :: any), INST.wideRange.channels, "3 wide range")
		t.eq(#(ch:get("detectors.pr_pctFP") :: any), INST.powerRange.channels, "4 power range quadrants")
		t.eq(#(ch:get("detectors.dnd_cps") :: any), INST.delayedNeutronDetectors.channels, "6 DNDs")
		-- §3.5: the wide range spans the whole range with no switching, so it reads at both ends
		ch:setExternal("core.power_pctFP", INST.wideRange.span_pctFP[1] * 10)
		run(sys, 2)
		t.ok((ch:get("detectors.wr_pctFP") :: any)[1] > 0, "reads near the bottom of its span")
		ch:setExternal("core.power_pctFP", 120)
		run(sys, 2)
		t.near((ch:get("detectors.wr_pctFP") :: any)[1], 120, 10, "and at full power, with no range switching")
	end,
}
