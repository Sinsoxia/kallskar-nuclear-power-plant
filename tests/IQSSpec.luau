--!strict
--[[
	IQS verification (spec §3.7, §14.2; D-014).
	  • §14.2 development check: a uniform perturbation leaves the shape unchanged, so the 3D amplitude must equal
	    point kinetics with the same reactivity — run at the production solver tolerance. A loss-side perturbation
	    must match constant-Λ point kinetics; a fission-side one must match it once the generation-time change is
	    included (D-017).
	  • Static consistency: with delayed neutrons off, a converged shape step is the new fundamental mode, and then
	    ρ = 1 − L/F equals 1 − 1/k₁ from an independent eigen solve for ANY weight function.
	  • Precursor equilibrium and a local absorber transient (direction of the tilt, logged magnitudes).
	Materials are arbitrary test inputs, not plant data.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local CoreDir = Root:WaitForChild("Systems"):WaitForChild("Core")
local Mesh = require(CoreDir:WaitForChild("Mesh")) :: any
local Diffusion = require(CoreDir:WaitForChild("Diffusion")) :: any
local Kinetics = require(CoreDir:WaitForChild("Kinetics")) :: any
local IQS = require(CoreDir:WaitForChild("IQS")) :: any
local Scheduler = require(Root:WaitForChild("Framework"):WaitForChild("Scheduler")) :: any

local PCM = 1e-5
local LAMBDA = Config.Kinetics.groups.lambda_ps

local function fakeConfig(lastRing: number, fuelLayers: number, layerMm: number)
	local rings = {}
	for n = 0, lastRing do
		rings[n + 1] = { ring = n, positions = if n == 0 then 1 else 6 * n, kind = "fuel", fuelZone = "inner", fuel = 0 }
	end
	return {
		PhysicsModel = {
			radialLastRing = lastRing,
			radialNodes = 1 + 3 * lastRing * (lastRing + 1),
			axial = { lowerLayers = 0, fuelLayers = fuelLayers, fuelLayerHeight_mm = layerMm, upperLayers = 0 },
			materialSets = Config.PhysicsModel.materialSets,
		},
		Core = {
			rings = rings,
			geometry = { assemblyPitch_mm = 179, lastCoreRing = lastRing, lowerReflector_mm = 0, fissileHeight_mm = fuelLayers * layerMm, upperPlenum_mm = 0 },
			rodLayout = {},
			flow = { zones = { { name = "all", firstRing = 0, lastRing = lastRing, fuel = 0, flowFactor = 1 } } },
		},
	}
end

local MAT = {
	D = { 2.2, 1.6, 1.2, 0.9 },
	sigR = { 0.012, 0.009, 0.010, 0.008 },
	nuSigF = { 0.010, 0.008, 0.012, 0.020 },
	chi = { 0.60, 0.35, 0.05, 0.0 },
	scat = { { 1, 2, 0.004 }, { 1, 3, 0.001 }, { 2, 3, 0.003 }, { 2, 4, 0.0005 }, { 3, 4, 0.002 } },
}

-- 3-ring, 6-layer core unless told otherwise; the outer ring is a non-fissile scatterer. Returns problem and mesh.
local function buildProblem(lastRing: number?, layers: number?)
	local m = Mesh.build(fakeConfig(lastRing or 3, layers or 6, 100))
	local gamma = { 0.5, 0.5, 0.5, 0.5 }
	local p = Diffusion.newProblem(m, 4, { radial = gamma, bottom = gamma, top = gamma })
	for g = 1, 4 do
		for node = 1, p.N do
			local r = (node - 1) % m.NR + 1
			local i = (g - 1) * p.N + node
			local fissile = m.ring[r] < m.lastRing
			p.D[i] = MAT.D[g]
			p.sigR[i] = MAT.sigR[g]
			p.nuSigF[i] = if fissile then MAT.nuSigF[g] else 0
			p.kapSigF[i] = p.nuSigF[i] / 2.5
			p.chi[i] = if fissile then MAT.chi[g] else 0
		end
	end
	for _, e in MAT.scat do
		local arr = Diffusion.scatter(p, e[1], e[2])
		for node = 1, p.N do
			arr[node] = e[3]
		end
	end
	return p, m
end

local function uniformBeta(N: number, scale: number)
	local beta = {}
	for i, b in Config.Kinetics.groups.beta_pcm do
		beta[i] = table.create(N, b * PCM * scale)
	end
	return beta
end

local function betaVector()
	local beta = {}
	for i, b in Config.Kinetics.groups.beta_pcm do
		beta[i] = b * PCM
	end
	return beta
end

-- Scale the whole loss operator (leakage, removal, scattering) by c; the eigenvector is unchanged and k → k/c.
local function scaleLossSide(p: any, c: number)
	for i = 1, #p.D do
		p.D[i] *= c
		p.sigR[i] *= c
	end
	for _, arr in p.sigS do
		for node = 1, #arr do
			arr[node] *= c
		end
	end
	-- boundary leakage 1/(h/D + 1/γ) is homogeneous in (D, γ) only if γ scales too; the three sides may share a table
	local seen = {}
	for _, side in { p.bc.radial, p.bc.bottom, p.bc.top } do
		if not seen[side] then
			seen[side] = true
			for g = 1, #side do
				side[g] *= c
			end
		end
	end
end

-- 60 s at the fast cadence with a shape step every 2 s; returns the worst relative amplitude difference
local function runAgainst(iqs: any, pk: any, rho: number, extra: any?): (number, number)
	local worst, shapeSteps = 0, 0
	for step = 1, 600 do
		iqs:tick(0.1)
		Kinetics.step(pk, 0.1, rho)
		if extra then
			Kinetics.step(extra, 0.1, rho)
		end
		if step % 20 == 0 then
			iqs:shapeStep()
			shapeSteps += 1
		end
		worst = math.max(worst, math.abs(iqs.amp.n / pk.n - 1))
	end
	return worst, shapeSteps
end

local function options(p: any, tolerance: number, betaScale: number)
	return {
		lambda = LAMBDA,
		beta = uniformBeta(p.N, betaScale),
		tolerance = tolerance,
		sweeps = Config.PhysicsModel.solver.sweepsPerGroup[1],
		omega = 1,
		maxOuter = 20000,
		promptLimitFrac = Config.Kinetics.promptJumpLimit_fracBeta,
	}
end

return {
	["initial state is critical with equilibrium precursors"] = function(t)
		local p = buildProblem()
		local iqs = IQS.new(p, options(p, Config.PhysicsModel.solver.fissionSourceTolerance, 1))
		iqs:initialize({ normaliseK = true })
		t.near(iqs.rho, 0, 1e-14, "adjoint-weighted state is exactly critical")
		t.near(iqs.betaSum, 360.3 * PCM, 1e-12, "uniform β → β_eff = Σβᵢ")
		t.near(iqs:relativePower(), 1, 1e-12)
		for node = 1, p.N do
			local D = 0
			for i = 1, 6 do
				D += LAMBDA[i] * iqs.c[i][node]
			end
			t.near(D, iqs.betaSum * iqs.S[node], 1e-12 * math.max(1, iqs.S[node]), "delayed emission = β·S at equilibrium")
		end
		for _ = 1, 600 do
			iqs:tick(0.1)
		end
		t.near(iqs.amp.n, 1, 1e-10, "no drift in 60 s")
	end,

	["§14.2 development check: uniform loss-side perturbation matches point kinetics"] = function(t)
		-- D, Σr, Σs and γ all scaled by (1 − ρ): the shape and the fission production F are unchanged, so the
		-- generation time Λ = ⟨φ*, v⁻¹ψ⟩/F is unchanged and constant-Λ point kinetics is the exact answer (D-017)
		local tol = Config.PhysicsModel.solver.fissionSourceTolerance
		local p = buildProblem()
		local iqs = IQS.new(p, options(p, tol, 1))
		iqs:initialize({ normaliseK = true })
		local rhoStep = 50 * PCM
		scaleLossSide(p, 1 - rhoStep)
		iqs:refreshLeakage() -- a step change in D: the caller refreshes the (otherwise frozen) leakage term
		local pk = Kinetics.newAmplitude(LAMBDA, betaVector(), 1)
		local worst, shapeSteps = runAgainst(iqs, pk, rhoStep)
		t.log(string.format("after 60 s: IQS n = %.8f, point kinetics n = %.8f, worst rel. diff %.2e over %d shape steps (last shape: %d outers)",
			iqs.amp.n, pk.n, worst, shapeSteps, iqs.shapeOuter))
		-- shape and adjoint are each converged to tol, so the weighted reactivity is good to about tol² (their product)
		t.near(iqs.rho, rhoStep, 10 * tol * tol, "IQS reactivity equals the imposed uniform step")
		t.ok(worst < tol, "amplitudes agree within the §14.2 solver tolerance")
	end,

	["uniform fission-side perturbation includes the generation-time change (D-017)"] = function(t)
		-- νΣf scaled by 1/(1 − ρ): F rises by the same factor, Λ falls by (1 − ρ), and the prompt-jump precursor
		-- amplitudes λᵢΛCᵢ start (1 − ρ) lower than constant-Λ point kinetics assumes
		local tol = Config.PhysicsModel.solver.fissionSourceTolerance
		local p = buildProblem()
		local iqs = IQS.new(p, options(p, tol, 1))
		iqs:initialize({ normaliseK = true })
		local rhoStep = 50 * PCM
		for i = 1, #p.nuSigF do
			p.nuSigF[i] /= 1 - rhoStep
		end
		local exact = Kinetics.newAmplitude(LAMBDA, betaVector(), 1)
		for i = 1, #exact.s do
			exact.s[i] *= 1 - rhoStep
		end
		local fixedLambda = Kinetics.newAmplitude(LAMBDA, betaVector(), 1)
		local worst = runAgainst(iqs, exact, rhoStep, fixedLambda)
		t.log(string.format("after 60 s: IQS n = %.8f, PK with Λ(t) %.8f (worst rel. diff %.2e), constant-Λ PK %.8f (rel. diff %.2e)",
			iqs.amp.n, exact.n, worst, fixedLambda.n, math.abs(iqs.amp.n / fixedLambda.n - 1)))
		t.near(iqs.rho, rhoStep, 10 * tol * tol, "IQS reactivity equals the imposed uniform step")
		t.ok(worst < tol, "amplitude matches point kinetics with the generation-time change")
		t.near(iqs.amp.n / fixedLambda.n, 1 - rhoStep, tol, "and differs from constant-Λ point kinetics by exactly (1 − ρ)")
	end,

	["static consistency: converged shape gives the exact eigenvalue reactivity"] = function(t)
		local p, m = buildProblem()
		local iqs = IQS.new(p, options(p, 1e-11, 0)) -- no delayed neutrons: the shape step is a pure eigen iteration
		iqs:initialize({ normaliseK = true })
		-- local absorber: raise removal in every group of one off-centre column
		local target = 0
		for r = 1, m.NR do
			if m.ring[r] == 2 then
				target = r
				break
			end
		end
		for k = 1, m.NK do
			local node = (k - 1) * m.NR + target
			for g = 1, 4 do
				p.sigR[(g - 1) * p.N + node] *= 1.3
			end
		end
		local firstOrder = iqs:parameters()
		for _ = 1, 50 do
			if iqs:shapeStep() and iqs.shapeOuter <= 1 then
				break
			end
		end
		local rhoIQS = iqs:parameters()
		-- independent eigen solve of the perturbed problem
		local check = Diffusion.solveEigen(p, { tolerance = 1e-12, sweeps = 8, omega = 1, maxOuter = 50000 })
		local exact = 1 - 1 / check.k
		t.log(string.format("exact ρ %.4f pcm; IQS after shape convergence %.4f pcm; frozen-shape first order %.4f pcm",
			exact / PCM, rhoIQS / PCM, firstOrder / PCM))
		t.ok(exact < 0, "an absorber lowers reactivity")
		t.near(rhoIQS, exact, 1e-9, "converged-shape IQS reactivity equals the eigenvalue reactivity")
		t.ok(math.abs(firstOrder - exact) < math.abs(exact), "first-order (frozen shape) estimate has the right sign and size")
	end,

	["absorber transient tilts power away from the absorber"] = function(t)
		local p, m = buildProblem()
		-- tight tolerance: the colour-ordered sweeps break symmetry only at the tolerance level
		local iqs = IQS.new(p, options(p, 1e-9, 1))
		iqs:initialize({ normaliseK = true })
		-- absorber in one ring-2 column; compare with the ring-2 column opposite it
		local a, b = 0, 0
		for r = 1, m.NR do
			if m.ring[r] == 2 then
				if a == 0 then
					a = r
				elseif math.abs(((m.angle_deg[r] - m.angle_deg[a]) % 360) - 180) < 1e-6 then
					b = r
				end
			end
		end
		t.ok(a ~= 0 and b ~= 0, "found opposite columns")
		local dens = table.create(p.N, 0)
		iqs:powerDensity(dens)
		local mid = m.NK // 2
		local ratio0 = dens[(mid - 1) * m.NR + a] / dens[(mid - 1) * m.NR + b]
		for k = 1, m.NK do
			local node = (k - 1) * m.NR + a
			for g = 1, 4 do
				p.sigR[(g - 1) * p.N + node] *= 1.2
			end
		end
		local nBefore = iqs.amp.n
		iqs:tick(0.1)
		local promptDrop = iqs.amp.n / nBefore
		for step = 2, 200 do
			iqs:tick(0.1)
			if step % 5 == 0 then
				iqs:shapeStep()
			end
		end
		iqs:powerDensity(dens)
		local ratio1 = dens[(mid - 1) * m.NR + a] / dens[(mid - 1) * m.NR + b]
		t.log(string.format("ρ %.2f pcm; prompt drop %.4f; power(absorber column)/power(opposite) %.4f → %.4f; n after 20 s %.4f",
			iqs.rho / PCM, promptDrop, ratio0, ratio1, iqs.amp.n))
		t.near(ratio0, 1, 1e-6, "symmetric before the perturbation")
		t.ok(ratio1 < ratio0, "power shifts away from the absorber")
		t.ok(iqs.rho < 0 and promptDrop < 1 and iqs.amp.n < promptDrop, "negative reactivity: prompt drop then decay")
	end,

	["shape step runs time-sliced inside the scheduler budget"] = function(t)
		-- a core big enough that the whole step is many slices of work on any host this runs on, while each piece of
		-- it (a colour pass, an assembly) stays far below one slice
		local p = buildProblem(5, 10)
		local iqs = IQS.new(p, options(p, 1e-9, 1))
		iqs:initialize({ normaliseK = true })
		for i = 1, #p.sigR do
			p.sigR[i] *= 1.0005
		end
		local sched = Scheduler.new({ order = { fast = {}, slow = {} } }, Config)
		local done, ok = false, false
		--[[
			The budget is checked between pieces of work, so a slice can overrun it by the piece that is running when
			the deadline passes. Every piece (each stretch between two checks) is timed, so the bound comes from the
			method rather than from a guessed margin.
		]]
		local longest, mark = 0, 0
		sched:runSliced("shape", function(budget)
			local timed = {}
			function timed.check(_self: any)
				longest = math.max(longest, os.clock() - mark)
				budget:check()
				mark = os.clock()
			end
			mark = os.clock()
			local converged = iqs:shapeStep(timed)
			longest = math.max(longest, os.clock() - mark)
			return converged
		end, function(success, converged)
			done, ok = true, success and converged
		end)
		local frames = 0
		while not done and frames < 100000 do
			sched:resumeSliced()
			frames += 1
		end
		local worst = sched.stats.frameSliced:max()
		local sliceBudget = Config.Clocks.shapeSliceBudget_s
		t.log(string.format("shape step finished in %d frames, %d outers, worst slice %.2f ms, longest piece %.3f ms",
			frames, iqs.shapeOuter, worst * 1000, longest * 1000))
		t.ok(ok, "sliced shape step converged")
		t.ok(frames > 1, `the step yielded to the frame rather than running to the end in one go ({frames} frames)`)
		t.ok(longest < sliceBudget,
			string.format("each piece (longest %.3f ms) is finer than one %.1f ms slice", longest * 1000, sliceBudget * 1000))
		-- one piece past the budget if the deadline falls inside it, and at most one more for the scheduler's own
		-- resume and yield around it: a handful of statements, against a piece that is a colour pass of node updates
		t.ok(worst <= sliceBudget + 2 * longest,
			string.format("worst slice %.3f ms is inside the %.1f ms budget plus two pieces", worst * 1000, sliceBudget * 1000))
	end,
}
