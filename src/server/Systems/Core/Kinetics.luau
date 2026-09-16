--!native
--!strict
--[[
	Kinetics — prompt-jump amplitude integration and the point-kinetics oracle (spec §3.1, §3.2, §14.2).
	======================================================================================================

	Amplitude (§14.2, with D-015 and D-011):
		scaled precursors sᵢ obey dsᵢ/dt = λᵢ(βᵢ n − sᵢ); prompt jump gives n = (Σsᵢ + q) / (β − ρ)
		with β = Σβᵢ and q an external-source term (subcritical multiplication: n → q/(−ρ) at equilibrium).
		Each step integrates sᵢ exactly for n varying linearly across the step (D-015):
			sᵢ¹ = sᵢ⁰eᵢ + βᵢn⁰(1 − eᵢ − wᵢ) + βᵢn¹wᵢ,  eᵢ = exp(−λᵢdt),  wᵢ = (1 − eᵢ) − (1 − eᵢ − xᵢeᵢ)/xᵢ,  xᵢ = λᵢdt
		so  n¹ = (Σ[sᵢ⁰eᵢ + βᵢn⁰(1 − eᵢ − wᵢ)] + q¹) / (β − ρ¹ − Σβᵢwᵢ).
		At ρ ≥ Kinetics.promptJumpLimit_fracBeta · β the form is no longer valid (§14.2); step() reports it and holds.

	Point-kinetics oracle (§3.2): whole-core feedback coefficients, each driven by its own temperature through its
	own first-order lag, relative to the hot-zero-power reference (Feedback.referenceTemperature_K). It is the
	spec-required fallback and the §14.2 development check for the 3D model — not the plant physics (plan).

	Reactivity is in absolute Δk/k inside this module; Config values in pcm are converted once.
]]

local Kinetics = {}

export type Amplitude = {
	lambda: { number },
	beta: { number },
	betaSum: number,
	s: { number },
	n: number,
	rho: number,
	q: number,
	promptLimit: number,
	promptCritical: boolean,
	-- per-dt cached coefficients
	dt: number,
	e: { number },
	w: { number },
	betaW: number,
}

local function cache(a: Amplitude, dt: number)
	if a.dt == dt then
		return
	end
	local bw = 0
	for i = 1, #a.lambda do
		local x = a.lambda[i] * dt
		local e = math.exp(-x)
		local w = (1 - e) - (1 - e - x * e) / x
		a.e[i], a.w[i] = e, w
		bw += a.beta[i] * w
	end
	a.betaW = bw
	a.dt = dt
end

--[[
	New amplitude state in equilibrium at level n0 with reactivity rho0 and source q0.
	For q0 = 0 the reactor must be exactly critical (rho0 = 0); with a source, n0 must equal q0 / (−rho0).
]]
function Kinetics.newAmplitude(lambda: { number }, beta: { number }, n0: number, rho0: number?, q0: number?, promptLimitFrac: number?): Amplitude
	assert(#lambda == #beta and #lambda > 0, "lambda and beta must have the same group count")
	local sum = 0
	for i = 1, #beta do
		sum += beta[i]
	end
	local rho, q = rho0 or 0, q0 or 0
	if q == 0 then
		assert(math.abs(rho) < 1e-12, "a source-free equilibrium must be exactly critical")
	else
		assert(rho < 0, "a source-driven equilibrium must be subcritical")
		assert(math.abs(n0 * -rho - q) <= 1e-12 * math.max(1, q), "n0 must equal q / (−rho) at equilibrium")
	end
	local s = table.create(#beta, 0)
	for i = 1, #beta do
		s[i] = beta[i] * n0
	end
	return {
		lambda = table.clone(lambda),
		beta = table.clone(beta),
		betaSum = sum,
		s = s,
		n = n0,
		rho = rho,
		q = q,
		promptLimit = (promptLimitFrac or 0.9) * sum,
		promptCritical = false,
		dt = -1,
		e = table.create(#beta, 0),
		w = table.create(#beta, 0),
		betaW = 0,
	}
end

--[[
	Advance one step to reactivity rho1 (at the end of the step) with source q1. Returns the new n.
	If rho1 reaches the prompt-jump limit, the state is left unchanged and a.promptCritical is set; the caller
	hands over to a scripted prompt-critical event (§14.2).
]]
function Kinetics.step(a: Amplitude, dt: number, rho1: number, q1: number?): number
	if rho1 >= a.promptLimit then
		a.promptCritical = true
		return a.n
	end
	cache(a, dt)
	local q = q1 or 0
	local n0 = a.n
	local num = q
	local s, beta, e, w = a.s, a.beta, a.e, a.w
	for i = 1, #s do
		num += s[i] * e[i] + beta[i] * n0 * (1 - e[i] - w[i])
	end
	local n1 = num / (a.betaSum - rho1 - a.betaW)
	for i = 1, #s do
		s[i] = s[i] * e[i] + beta[i] * (n0 * (1 - e[i] - w[i]) + n1 * w[i])
	end
	a.n, a.rho, a.q = n1, rho1, q
	return n1
end

--[[
	Asymptotic period for a constant reactivity step under the prompt-jump approximation (Λ → 0):
	ρ = Σ βᵢ / (1 + λᵢT). Returns the root that dominates at long times: the positive root for ρ > 0; for ρ < 0 the
	slowest-decaying root, which lies below the most negative pole −1/λ_min (f → −ρ > 0 as T → −∞, → −∞ at the pole).
]]
function Kinetics.inhourPeriod(lambda: { number }, beta: { number }, rho: number): number
	local function f(T: number): number
		local s = 0
		for i = 1, #beta do
			s += beta[i] / (1 + lambda[i] * T)
		end
		return s - rho
	end
	local lo, hi
	if rho > 0 then
		lo, hi = 1e-9, 1e12
	else
		local lmin = math.huge
		for _, l in lambda do
			lmin = math.min(lmin, l)
		end
		lo, hi = -1e12, -1 / lmin - 1e-9
	end
	local flo = f(lo)
	for _ = 1, 300 do
		local mid = (lo + hi) / 2
		local fm = f(mid)
		if (fm > 0) == (flo > 0) then
			lo, flo = mid, fm
		else
			hi = mid
		end
	end
	return (lo + hi) / 2
end

-- Point-kinetics oracle ---------------------------------------------------------------------------------------

local FEEDBACKS = { "doppler", "fuelAxialExpansion", "sodiumDensity", "loadPads", "diagrid", "drivelines", "vessel" }
Kinetics.FEEDBACKS = FEEDBACKS

export type Drivers = {
	fuelAverage: number, -- K
	coreAverageSodium: number, -- K
	coreOutlet: number, -- K
	coreInlet: number, -- K
	upperHotPool: number, -- K
	coldPool: number, -- K
}

local PointKinetics = {}
PointKinetics.__index = PointKinetics
Kinetics.PointKinetics = PointKinetics

function PointKinetics.new(config: any, drivers: Drivers, n0: number)
	local kin, fb = config.Kinetics, config.Feedback
	local pcm = 1 / config.Units.pcmPerUnit
	local beta = {}
	for i, b in kin.groups.beta_pcm do
		beta[i] = b * pcm
	end
	local self = setmetatable({}, PointKinetics)
	self.pcm = pcm
	self.Tref = fb.referenceTemperature_K
	self.terms = {}
	for _, name in FEEDBACKS do
		local spec = fb[name]
		self.terms[name] = {
			driver = spec.drivenBy,
			lag = spec.lag_s,
			coef = if name == "doppler" then spec.constant_pcm * pcm else spec.coefficient_pcmpK * pcm,
			log = name == "doppler",
			T = (drivers :: any)[spec.drivenBy],
			rho = 0,
		}
	end
	self.amp = Kinetics.newAmplitude(kin.groups.lambda_ps, beta, n0, 0, 0, kin.promptJumpLimit_fracBeta)
	self.external = 0
	self.rho = 0
	self:updateFeedback(0, drivers)
	-- start in equilibrium: the external (rod) reactivity balances the feedback at the initial state
	self.external = -self.feedback
	self.rho = 0
	return self
end

function PointKinetics.updateFeedback(self: any, dt: number, drivers: Drivers)
	local total = 0
	for _, term in self.terms do
		local target = (drivers :: any)[term.driver]
		if dt > 0 then
			term.T = target + (term.T - target) * math.exp(-dt / term.lag)
		else
			term.T = target
		end
		if term.log then
			term.rho = term.coef * math.log(term.T / self.Tref)
		else
			term.rho = term.coef * (term.T - self.Tref)
		end
		total += term.rho
	end
	self.feedback = total
end

--[[
	Advance dt with an external reactivity change (rods, faults) given relative to the initial critical state, in pcm.
	Returns relative power n.
]]
function PointKinetics.step(self: any, dt: number, externalDelta_pcm: number, drivers: Drivers, q: number?): number
	self:updateFeedback(dt, drivers)
	self.rho = self.external + externalDelta_pcm * self.pcm + self.feedback
	return Kinetics.step(self.amp, dt, self.rho, q)
end

function PointKinetics.breakdown_pcm(self: any): { [string]: number }
	local out = {}
	for name, term in self.terms do
		out[name] = term.rho / self.pcm
	end
	out.total = self.rho / self.pcm
	return out
end

return table.freeze(Kinetics)
