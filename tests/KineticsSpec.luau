--!strict
--[[
	Kinetics: amplitude integrator (§14.2, D-011, D-015) and the point-kinetics oracle (§3.1, §3.2).
	Expected values are exact solutions of the prompt-jump equations or the spec's own derivation (file 20).
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local CoreDir = ServerScriptService:WaitForChild("Kallskar"):WaitForChild("Systems"):WaitForChild("Core")
local Kinetics = require(CoreDir:WaitForChild("Kinetics")) :: any

local PCM = 1e-5
local LAMBDA = Config.Kinetics.groups.lambda_ps
local BETA = {}
for i, b in Config.Kinetics.groups.beta_pcm do
	BETA[i] = b * PCM
end
local BETA_SUM = 0
for _, b in BETA do
	BETA_SUM += b
end

local function measurePeriod(rho: number, runFor: number, window: number, dt: number): number
	local a = Kinetics.newAmplitude(LAMBDA, BETA, 1)
	local steps = math.floor(runFor / dt + 0.5)
	local windowSteps = math.floor(window / dt + 0.5)
	local nStart = 0
	for i = 1, steps do
		Kinetics.step(a, dt, rho)
		if i == steps - windowSteps then
			nStart = a.n
		end
	end
	return window / math.log(a.n / nStart)
end

return {
	["critical steady state is exact (D-011: β = Σβᵢ)"] = function(t)
		local a = Kinetics.newAmplitude(LAMBDA, BETA, 1)
		t.near(a.betaSum, 360.3 * PCM, 1e-15)
		for _ = 1, 10000 do
			Kinetics.step(a, 0.1, 0)
		end
		t.near(a.n, 1, 1e-12, "no drift after 1000 s at ρ = 0")
		-- using the rounded 360 pcm instead would be a −0.3 pcm error: show the drift it would cause
		local bad = Kinetics.newAmplitude(LAMBDA, BETA, 1)
		for _ = 1, 3000 do
			Kinetics.step(bad, 0.1, (360.3 - 360) * PCM * -1)
		end
		t.log(string.format("with the rounded β the 'critical' core would drift to n = %.4f in 300 s", bad.n))
		t.ok(bad.n < 0.999, "the 0.3 pcm inconsistency is visible, which is why D-011 matters")
	end,

	["prompt jump matches β/(β − ρ)"] = function(t)
		for _, rho_pcm in { 50, 100, -300, -3000 } do
			local a = Kinetics.newAmplitude(LAMBDA, BETA, 1)
			Kinetics.step(a, 1e-7, rho_pcm * PCM)
			local expect = BETA_SUM / (BETA_SUM - rho_pcm * PCM)
			t.near(a.n, expect, 1e-6 * expect, `prompt jump at {rho_pcm} pcm`)
		end
	end,

	["positive period matches the inhour equation"] = function(t)
		for _, rho_pcm in { 20, 50, 100 } do
			local rho = rho_pcm * PCM
			local exact = Kinetics.inhourPeriod(LAMBDA, BETA, rho)
			local measured = measurePeriod(rho, 1200, 100, 0.1)
			t.log(string.format("ρ = %d pcm: inhour T = %.4f s, integrator %.4f s (rel. err %.2e)", rho_pcm, exact, measured, math.abs(measured / exact - 1)))
			-- D-015: discretisation error is O((dt/T)²) ≈ 4e-6 at T ≈ 50 s; slower modes have decayed by e^-(t/T) ≫ 1e-4
			t.near(measured, exact, 1e-4 * exact, `period at {rho_pcm} pcm`)
		end
	end,

	["negative period approaches the slowest delayed group"] = function(t)
		for _, rho_pcm in { -100, -500, -3000 } do
			local rho = rho_pcm * PCM
			local exact = Kinetics.inhourPeriod(LAMBDA, BETA, rho)
			t.ok(exact < -1 / LAMBDA[1], "dominant negative root lies below −1/λ₁")
			local measured = measurePeriod(rho, 2500, 200, 0.1)
			t.log(string.format("ρ = %d pcm: inhour T = %.3f s, integrator %.3f s", rho_pcm, exact, measured))
			t.near(measured, exact, 1e-3 * math.abs(exact), `negative period at {rho_pcm} pcm`)
		end
		t.near(Kinetics.inhourPeriod(LAMBDA, BETA, -1), -1 / LAMBDA[1], 0.5, "very deep subcriticality → −1/λ₁ ≈ −77 s")
	end,

	["an exactly critical core has an infinite period, not a negative one"] = function(t)
		t.eq(Kinetics.inhourPeriod(LAMBDA, BETA, 0), math.huge, "ρ = 0: the level holds")
		-- and the integrator agrees: at ρ = 0 the level does not move, so there is no finite period to find
		local a = Kinetics.newAmplitude(LAMBDA, BETA, 1)
		for _ = 1, 1000 do
			Kinetics.step(a, 0.1, 0)
		end
		t.near(a.n, 1, 1e-12, "no drift in 100 s")
	end,

	["all three RR out: period and prompt-jump margin (§3.4, S-19, F7, F12)"] = function(t)
		local rho = Config.Rods.interlocks.allRegulatingOutFromCritical_pcm * PCM
		local T = Kinetics.inhourPeriod(LAMBDA, BETA, rho)
		-- the reactivity whose inhour period is the spec's quoted figure
		local target = Config.Rods.interlocks.allRegulatingOutPeriod_s
		local lo, hi = 1 * PCM, 0.99 * BETA_SUM
		for _ = 1, 200 do
			local mid = (lo + hi) / 2
			if Kinetics.inhourPeriod(LAMBDA, BETA, mid) > target then
				lo = mid
			else
				hi = mid
			end
		end
		t.log(string.format("+%d pcm → inhour period %.3f s; the spec's %.1f s corresponds to %.0f pcm (F12: §3.4 is inconsistent with §3.1)",
			rho / PCM, T, target, lo / PCM))
		-- verify the solver's root really satisfies the inhour equation
		local sum = 0
		for i = 1, #BETA do
			sum += BETA[i] / (1 + LAMBDA[i] * T)
		end
		t.near(sum, rho, 1e-12, "inhour root satisfies ρ = Σβᵢ/(1 + λᵢT)")
		local limit = Config.Kinetics.promptJumpLimit_fracBeta * BETA_SUM
		t.ok(rho < limit, "S-19 stays inside the prompt-jump validity limit")
		t.log(string.format("margin to the 0.9β limit: %.1f pcm (F7)", (limit - rho) / PCM))
	end,

	["subcritical source multiplication and the prompt-critical guard"] = function(t)
		local rho = -1000 * PCM
		local q = 1e-9
		local a = Kinetics.newAmplitude(LAMBDA, BETA, q / -rho, rho, q)
		for _ = 1, 1000 do
			Kinetics.step(a, 0.1, rho, q)
		end
		t.near(a.n, q / -rho, 1e-12 * q / -rho, "equilibrium n = q/|ρ|")
		-- halve the subcriticality → level doubles (1/(1 − k) behaviour of the SR channel, §3.5)
		for _ = 1, 20000 do
			Kinetics.step(a, 0.1, rho / 2, q)
		end
		t.near(a.n, 2 * q / -rho, 1e-6 * q / -rho, "level doubles when subcriticality halves")
		local p = Kinetics.newAmplitude(LAMBDA, BETA, 1)
		Kinetics.step(p, 0.1, 0.95 * BETA_SUM)
		t.ok(p.promptCritical, "ρ ≥ 0.9β is flagged instead of integrated")
		t.eq(p.n, 1, "state held for the scripted event")
	end,

	["oracle reproduces the spec's power defect (file 20)"] = function(t)
		local Tref = Config.Feedback.referenceTemperature_K
		local hzp = {
			fuelAverage = Tref,
			coreAverageSodium = Tref,
			coreOutlet = Tref,
			coreInlet = Tref,
			upperHotPool = Tref,
			coldPool = Tref,
		}
		local pk = Kinetics.PointKinetics.new(Config, hzp, 1)
		t.near(pk.rho, 0, 1e-15, "starts critical")
		-- full-power driving temperatures used in spec file 20's REACTIVITY line
		local full = {
			fuelAverage = Config.Feedback.fullPowerFuelAverage_K,
			coreAverageSodium = Tref + 92,
			coreOutlet = Tref + 175,
			coreInlet = Tref,
			upperHotPool = Tref + 170,
			coldPool = Tref,
		}
		-- hold power fixed by feeding the drivers directly; step long enough for the 900 s vessel lag to settle
		for _ = 1, 20000 do
			pk:updateFeedback(0.5, full)
		end
		local parts = pk:breakdown_pcm()
		local total = pk.feedback / PCM
		t.log(string.format("doppler %.1f axial %.1f sodium %.1f pads %.1f drivelines %.1f diagrid %.1f vessel %.1f → %.1f pcm",
			parts.doppler, parts.fuelAxialExpansion, parts.sodiumDensity, parts.loadPads, parts.drivelines, parts.diagrid, parts.vessel, total))
		local target = Config.Feedback.targets
		t.near(parts.doppler, target.powerDefectParts_pcm.doppler, 0.5, "Doppler part")
		t.near(parts.fuelAxialExpansion, target.powerDefectParts_pcm.axial, 0.5, "axial part")
		t.near(parts.sodiumDensity, target.powerDefectParts_pcm.sodium, 0.5, "sodium part")
		t.near(parts.loadPads, target.powerDefectParts_pcm.pads, 0.5, "pads part")
		t.near(parts.drivelines, target.powerDefectParts_pcm.drivelines, 0.5, "drivelines part")
		t.near(total, target.powerDefect_pcm, 2.5, "total power defect (five parts rounded to 1 pcm)")
	end,

	["oracle lags follow their §3.2 time constants"] = function(t)
		local Tref = Config.Feedback.referenceTemperature_K
		local base = { fuelAverage = Tref, coreAverageSodium = Tref, coreOutlet = Tref, coreInlet = Tref, upperHotPool = Tref, coldPool = Tref }
		local pk = Kinetics.PointKinetics.new(Config, base, 1)
		local stepped = table.clone(base)
		stepped.coreInlet = Tref + 10
		local tau = Config.Feedback.diagrid.lag_s
		local elapsed = 0
		while elapsed < tau - 1e-9 do
			pk:updateFeedback(0.1, stepped)
			elapsed += 0.1
		end
		local expect = Config.Feedback.diagrid.coefficient_pcmpK * 10 * (1 - math.exp(-1))
		t.near(pk:breakdown_pcm().diagrid, expect, 1e-6, "diagrid term reaches 1 − 1/e after one lag")
	end,
}
