--!native
--!strict
--[[
	IQS — improved quasi-static coupling of the 3D diffusion shape and the prompt-jump amplitude
	(spec §3.7, §14.2; decisions D-011, D-014, D-015).
	=============================================================================================

	Flux φ(r,g,t) = n(t) · ψ(r,g,t), with the shape normalised so ⟨φ₀*, v⁻¹ψ⟩ = 1 (φ₀* is the initial adjoint).

	Every fast tick (frozen shape ψ, current cross sections):
		S(r)  = Σ_g νΣf ψ                         fission neutron production of the shape
		C*(r) = Σ_g χ_g φ₀*_g                      importance of a fission neutron born at r
		F_w   = ⟨C*, S⟩
		L_w   = ⟨φ₀*, A_leak ψ⟩ + ⟨φ₀*, Σr ψ⟩ − ⟨φ₀*, Σs ψ⟩     (leakage part frozen between shape steps)
		ρ     = 1 − L_w / F_w,        βᵢ,eff = ⟨C*, βᵢ(r) S⟩ / F_w,        Λ = ⟨φ₀*, v⁻¹ψ⟩ / F_w
		n     advanced by Kinetics.step (prompt jump, D-015) with these parameters; the amplitude precursors are
		      held at sᵢ = λᵢ⟨C*, cᵢ⟩ / F_w, so a change in F_w rescales them (generation-time change, D-017)
		cᵢ(r) node precursors: dcᵢ/dt = βᵢ(r) S(r) n(t) − λᵢcᵢ, integrated exactly for n linear over the step
		The leakage term only changes when D or the boundary changes; a caller that steps D between shape steps
		calls refreshLeakage() (a full operator assembly, too costly for every tick on the plant mesh).
	At the initial eigenstate this gives ρ = 1 − 1/k₀ exactly; a uniform perturbation leaves ψ unchanged, so the
	amplitude reproduces point kinetics (the §14.2 development check).

	Shape step (D-014): warm-started power iteration on the current cross sections with fission source
	χ·[(1 − β(r))·S(r) + μ·D(r)], where D(r) = Σᵢ λᵢcᵢ(r) is the actual delayed-emission map and μ rescales it to
	∫β S. Then ψ is renormalised, the leakage term is refreshed, the amplitude precursors are re-projected
	(sᵢ = λᵢ⟨C*, cᵢ⟩/F_w) and n follows from the prompt-jump relation with the updated parameters.

	The delayed-neutron spectrum is taken equal to the problem's χ until the cross-section data supplies a separate one.
]]
local Diffusion = require(script.Parent.Diffusion)
local Kinetics = require(script.Parent.Kinetics)

local IQS = {}
IQS.__index = IQS

export type Options = {
	lambda: { number }, -- 6 precursor decay constants (s⁻¹)
	beta: { { number } }, -- beta[i][node] delayed fractions (Δk/k)
	invV: { number }?, -- per group inverse speed (s/cm); defaults to 1 (only Λ uses it)
	tolerance: number,
	sweeps: number,
	omega: number,
	maxOuter: number,
	promptLimitFrac: number?,
}

function IQS.new(problem: any, opts: Options)
	local self = setmetatable({}, IQS)
	local G, N = problem.G, problem.N
	self.p = problem
	self.G, self.N = G, N
	self.lambda = table.clone(opts.lambda)
	self.beta = opts.beta
	self.I = #opts.lambda
	assert(#opts.beta == self.I, "beta must have one per-node array per precursor group")
	self.invV = opts.invV or table.create(G, 1)
	self.opts = opts
	self.psi = table.create(G * N, 0)
	self.adj = table.create(G * N, 0)
	self.Cstar = table.create(N, 0)
	self.S = table.create(N, 0)
	self.c = {} :: { { number } }
	for i = 1, self.I do
		self.c[i] = table.create(N, 0)
	end
	self.fissile = {} :: { number }
	self.leakW = 0
	self.rho = 0
	self.betaEff = table.create(self.I, 0)
	self.betaSum = 0
	self.Lambda = 0
	self.Fw = 0
	self.FwAmp = 0 -- the F_w that amp.s is currently expressed against
	self.q = 0
	self.powerScale = 1
	self.amp = nil :: any
	self.k0 = 1
	self.shapeOuter = 0
	self.shapeChange = 0
	return self
end

-- Leakage-only part of ⟨φ*, Aψ⟩. Assembles the operator first unless the caller just did.
function IQS.refreshLeakage(self: any, alreadyAssembled: boolean?)
	local p = self.p
	if not alreadyAssembled then
		Diffusion.assemble(p)
	end
	local G, N = self.G, self.N
	local diag, coef, nb, vol, sigR = p.diag, p.coef, p.nb, p.vol, p.sigR
	local psi, adj = self.psi, self.adj
	local total = 0
	for g = 1, G do
		local off = (g - 1) * N
		for node = 1, N do
			local s = (diag[off + node] - sigR[off + node] * vol[node]) * psi[off + node]
			local base = (node - 1) * 8
			local cbase = (off + node - 1) * 8
			for f = 1, 8 do
				local j = nb[base + f]
				if j ~= 0 then
					s += coef[cbase + f] * psi[off + j]
				end
			end
			total += adj[off + node] * s
		end
	end
	self.leakW = total
end

function IQS.updateImportance(self: any)
	local G, N, chi, adj, Cstar = self.G, self.N, self.p.chi, self.adj, self.Cstar
	for node = 1, N do
		local s = 0
		for g = 1, G do
			local i = (g - 1) * N + node
			s += chi[i] * adj[i]
		end
		Cstar[node] = s
	end
end

-- Fission production of the (frozen) shape with the current νΣf; also refreshes the list of fissile nodes.
function IQS.updateSource(self: any)
	local G, N, nu, psi, S = self.G, self.N, self.p.nuSigF, self.psi, self.S
	for node = 1, N do
		local s = 0
		for g = 1, G do
			local i = (g - 1) * N + node
			s += nu[i] * psi[i]
		end
		S[node] = s
	end
end

--[[
	Point-kinetics parameters for the frozen shape and current cross sections.
	Returns ρ, Σβ_eff and fills self.betaEff.
]]
function IQS.parameters(self: any): (number, number)
	local p = self.p
	local G, N = self.G, self.N
	local vol, sigR, psi, adj = p.vol, p.sigR, self.psi, self.adj
	self:updateSource()
	local S, Cstar = self.S, self.Cstar
	local Fw = 0
	for node = 1, N do
		Fw += vol[node] * Cstar[node] * S[node]
	end
	local rem = 0
	for g = 1, G do
		local off = (g - 1) * N
		for node = 1, N do
			local i = off + node
			rem += adj[i] * sigR[i] * vol[node] * psi[i]
		end
	end
	local scat = 0
	for to = 2, G do
		for from = 1, to - 1 do
			local arr = p.sigS[(from - 1) * G + to]
			if arr then
				local offFrom, offTo = (from - 1) * N, (to - 1) * N
				for node = 1, N do
					scat += adj[offTo + node] * arr[node] * vol[node] * psi[offFrom + node]
				end
			end
		end
	end
	local Lw = self.leakW + rem - scat
	local rho = 1 - Lw / Fw
	local bsum = 0
	for i = 1, self.I do
		local b = self.beta[i]
		local s = 0
		for node = 1, N do
			s += vol[node] * Cstar[node] * b[node] * S[node]
		end
		self.betaEff[i] = s / Fw
		bsum += self.betaEff[i]
	end
	local inv = 0
	local invV = self.invV
	for g = 1, G do
		local off = (g - 1) * N
		local w = invV[g]
		for node = 1, N do
			inv += adj[off + node] * w * vol[node] * psi[off + node]
		end
	end
	self.Fw, self.rho, self.betaSum, self.Lambda = Fw, rho, bsum, inv / Fw
	return rho, bsum
end

-- Normalise ψ to ⟨φ₀*, v⁻¹ψ⟩ = 1.
function IQS.normaliseShape(self: any)
	local G, N, psi, adj, vol, invV = self.G, self.N, self.psi, self.adj, self.p.vol, self.invV
	local s = 0
	for g = 1, G do
		local off = (g - 1) * N
		for node = 1, N do
			s += adj[off + node] * invV[g] * vol[node] * psi[off + node]
		end
	end
	assert(s > 0, "shape has no importance-weighted content")
	for i = 1, G * N do
		psi[i] /= s
	end
end

local function syncAmplitudeBeta(self: any)
	local a = self.amp
	for i = 1, self.I do
		a.beta[i] = self.betaEff[i]
	end
	a.betaSum = self.betaSum
	a.promptLimit = (self.opts.promptLimitFrac or 0.9) * self.betaSum
	a.dt = -1 -- invalidate cached coefficients
end

-- Re-project the amplitude precursors from the node precursors: sᵢ = λᵢ⟨C*, cᵢ⟩ / F_w
local function projectPrecursors(self: any)
	local vol, Cstar, N = self.p.vol, self.Cstar, self.N
	for i = 1, self.I do
		local ci = self.c[i]
		local s = 0
		for node = 1, N do
			s += vol[node] * Cstar[node] * ci[node]
		end
		self.amp.s[i] = self.lambda[i] * s / self.Fw
	end
	self.FwAmp = self.Fw
end

--[[
	Keep sᵢ = λᵢ⟨C*, cᵢ⟩ / F_w true when F_w changes between shape steps (D-017). ⟨C*, cᵢ⟩ is continuous, so a
	change in fission production rescales the amplitude precursors by F_old / F_new. This is the generation-time
	change Λ = ⟨φ*, v⁻¹ψ⟩ / F that constant-Λ point kinetics leaves out. O(I), exact: between shape steps the node and
	amplitude precursors obey the same update, so the invariant only breaks when F_w itself moves.
]]
local function rescalePrecursors(self: any)
	local Fw, FwAmp = self.Fw, self.FwAmp
	if Fw == FwAmp then
		return
	end
	local s, r = self.amp.s, FwAmp / Fw
	for i = 1, self.I do
		s[i] *= r
	end
	self.FwAmp = Fw
end

--[[
	Solve the initial forward and adjoint eigenproblems and put the core in equilibrium.
	opts.normaliseK  scale νΣf by 1/k₀ so the initial state is exactly critical (verification problems only)
	opts.n0          initial amplitude (relative power scale; default 1)
	opts.source      if true and the core is subcritical, start in source-driven equilibrium at n0
]]
function IQS.initialize(self: any, init: { normaliseK: boolean?, n0: number?, source: boolean? }?, budget: any?)
	local o = self.opts
	local p = self.p
	local eig = Diffusion.solveEigen(p, { tolerance = o.tolerance, sweeps = o.sweeps, omega = o.omega, maxOuter = o.maxOuter }, budget)
	assert(eig.converged, `initial eigenvalue did not converge (change {eig.sourceChange})`)
	local k0 = eig.k
	if init and init.normaliseK then
		for i = 1, #p.nuSigF do
			p.nuSigF[i] /= k0
		end
		for i = 1, #p.kapSigF do
			p.kapSigF[i] /= k0
		end
		k0 = 1
	end
	self.k0 = k0
	local adj = Diffusion.solveAdjoint(p, k0, { tolerance = o.tolerance, sweeps = o.sweeps, omega = o.omega, maxOuter = o.maxOuter }, budget)
	assert(adj.converged, `initial adjoint did not converge (change {adj.sourceChange})`)
	for i = 1, self.G * self.N do
		self.psi[i] = eig.phi[i]
		self.adj[i] = adj.phi[i]
	end
	self:updateImportance()
	self:normaliseShape()
	self:refreshLeakage()
	local rho = self:parameters()
	if init and init.normaliseK then
		-- ρ = 1 − L/F and F ∝ νΣf, so scaling νΣf by (1 − ρ) makes the adjoint-weighted state exactly critical,
		-- independent of how tightly k₀ itself converged
		local scale = 1 - rho
		for i = 1, #p.nuSigF do
			p.nuSigF[i] *= scale
		end
		for i = 1, #p.kapSigF do
			p.kapSigF[i] *= scale
		end
		rho = self:parameters()
	end
	local n0 = (init and init.n0) or 1
	-- equilibrium precursors
	self.fissile = {}
	for node = 1, self.N do
		if self.S[node] > 0 then
			table.insert(self.fissile, node)
		end
	end
	for i = 1, self.I do
		local ci, b, l = self.c[i], self.beta[i], self.lambda[i]
		for node = 1, self.N do
			ci[node] = b[node] * self.S[node] * n0 / l
		end
	end
	local q = 0
	if init and init.source and rho < 0 then
		q = -rho * n0
	else
		assert(math.abs(rho) < 10 * o.tolerance, `initial state is not critical (ρ = {rho}); use normaliseK or source`)
		rho = 0
	end
	self.q = q
	self.amp = Kinetics.newAmplitude(self.lambda, self.betaEff, n0, if q > 0 then rho else 0, q, o.promptLimitFrac)
	projectPrecursors(self)
	-- power scale: relative power 1 ↔ n0 with the initial shape
	local pow = self:shapePower()
	self.powerScale = if pow > 0 then 1 / (n0 * pow) else 1
	return eig, adj
end

-- κΣf if the cross sections provide it, otherwise νΣf (verification problems without energy data)
local function powerArray(p: any): { number }
	local kap = p.kapSigF
	for i = 1, #kap do
		if kap[i] ~= 0 then
			return kap
		end
	end
	return p.nuSigF
end

-- Σ κΣf ψ V of the current shape
function IQS.shapePower(self: any): number
	local p = self.p
	local G, N, vol, psi = self.G, self.N, p.vol, self.psi
	local src = powerArray(p)
	local s = 0
	for g = 1, G do
		local off = (g - 1) * N
		for node = 1, N do
			s += src[off + node] * psi[off + node] * vol[node]
		end
	end
	return s
end

function IQS.relativePower(self: any): number
	return self.amp.n * self:shapePower() * self.powerScale
end

--[[
	One fast tick: reactivity from the current cross sections, amplitude step, node precursor update.
	Returns n. If the amplitude flags prompt-criticality the state is held (Kinetics.step contract).
]]
function IQS.tick(self: any, dt: number): number
	local rho = self:parameters()
	syncAmplitudeBeta(self)
	rescalePrecursors(self)
	local a = self.amp
	local n0 = a.n
	local n1 = Kinetics.step(a, dt, rho, self.q)
	if a.promptCritical then
		return n0
	end
	-- node precursors (same e, w as the amplitude for this dt)
	local S, e, w = self.S, a.e, a.w
	for i = 1, self.I do
		local ci, b, l = self.c[i], self.beta[i], self.lambda[i]
		local ei, wi = e[i], w[i]
		local drive = (n0 * (1 - ei - wi) + n1 * wi) / l
		for node = 1, self.N do
			ci[node] = ci[node] * ei + b[node] * S[node] * drive
		end
	end
	return n1
end

--[[
	Shape step (D-014). Warm-started power iteration with the delayed-emission map, then renormalisation and
	re-projection. Returns true if the shape converged within opts.maxOuter.
]]
function IQS.shapeStep(self: any, budget: any?): boolean
	local p, o = self.p, self.opts
	local G, N = self.G, self.N
	Diffusion.assemble(p)
	local psi, chi, vol, nu = self.psi, p.chi, p.vol, p.nuSigF
	-- delayed emission map and per-node total β
	local D = table.create(N, 0)
	local btot = table.create(N, 0)
	for i = 1, self.I do
		local ci, b, l = self.c[i], self.beta[i], self.lambda[i]
		for node = 1, N do
			D[node] += l * ci[node]
			btot[node] += b[node]
		end
	end
	local src = table.create(G * N, 0)
	local S = table.create(N, 0)
	local Sold = table.create(N, 0)
	local function source(out: { number })
		for node = 1, N do
			local s = 0
			for g = 1, G do
				local i = (g - 1) * N + node
				s += nu[i] * psi[i]
			end
			out[node] = s
		end
	end
	source(S)
	local lam, change, outer = 1, math.huge, 0
	while outer < o.maxOuter do
		outer += 1
		-- rescale the delayed map to ∫β S of the current shape
		local bS, Dsum, total = 0, 0, 0
		for node = 1, N do
			bS += vol[node] * btot[node] * S[node]
			Dsum += vol[node] * D[node]
			total += vol[node] * S[node]
			Sold[node] = S[node]
		end
		local mu = if Dsum > 0 then bS / Dsum else 0
		for g = 1, G do
			local off = (g - 1) * N
			for node = 1, N do
				local fission = (1 - btot[node]) * S[node] + mu * D[node]
				src[off + node] = chi[off + node] * fission / lam
			end
			for from = 1, g - 1 do
				local arr = p.sigS[(from - 1) * G + g]
				if arr then
					local offFrom = (from - 1) * N
					for node = 1, N do
						src[off + node] += arr[node] * psi[offFrom + node]
					end
				end
			end
			Diffusion.sweep(p, g, psi, src, o.sweeps, o.omega, false, budget)
		end
		source(S)
		local newTotal = 0
		for node = 1, N do
			newTotal += vol[node] * S[node]
		end
		local lamOld = lam
		lam = lam * newTotal / total
		local diff2, norm2 = 0, 0
		for node = 1, N do
			local a = S[node] / newTotal
			local b = Sold[node] / total
			diff2 += (a - b) * (a - b) * vol[node]
			norm2 += a * a * vol[node]
		end
		change = math.max(math.sqrt(diff2 / norm2), math.abs(lam - lamOld) / lam)
		if change < o.tolerance then
			break
		end
	end
	self.shapeOuter, self.shapeChange = outer, change
	self:normaliseShape()
	self:refreshLeakage(true)
	local rho = self:parameters()
	syncAmplitudeBeta(self)
	projectPrecursors(self)
	-- prompt-jump consistency with the updated parameters
	local a = self.amp
	local sum = 0
	for i = 1, self.I do
		sum += a.s[i]
	end
	if rho < a.promptLimit then
		a.n = (sum + self.q) / (self.betaSum - rho)
		a.rho = rho
	else
		a.promptCritical = true
	end
	return change < o.tolerance
end

-- Relative power density per node (for fuel thermal coupling and the core map)
function IQS.powerDensity(self: any, out: { number })
	local p = self.p
	local G, N, psi = self.G, self.N, self.psi
	local kap = powerArray(p)
	local scale = self.amp.n * self.powerScale
	for node = 1, N do
		local s = 0
		for g = 1, G do
			local i = (g - 1) * N + node
			s += kap[i] * psi[i]
		end
		out[node] = s * scale
	end
end

return IQS
