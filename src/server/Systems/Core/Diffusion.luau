--!native
--!strict
--[[
	Diffusion — multigroup neutron diffusion on the hex-Z mesh (spec §3.7, §14.2; decisions D-001, D-002).
	========================================================================================================

	Finite-volume, mesh-centred discretisation. For group g and node i (volume V, faces f with area A_f):

		Σ_f A_f J_f + Σr_g,i φ_g,i V_i = Q_g,i V_i

	Net current from i to neighbour j across face f (D-002, CMFD form; D̂ = 0 gives plain finite difference):

		J_ij = −D̃_ij (φ_j − φ_i) + D̂_ij (φ_i + φ_j),     D̃_ij = 1 / (h_i/D_i + h_j/D_j)

	h_i, h_j are the centre-to-face distances. At an outer face with albedo parameter γ = J_out/φ_surface
	(γ = 0 reflective, γ = ½ Marshak vacuum):  J = (D̃_b + D̂_b) φ_i  with  D̃_b = 1 / (h_i/D_i + 1/γ).

	Groups are ordered fastest first. A fast spectrum has no upscatter, so each group's scattering source only
	needs groups already solved (§14.2). Inner iterations are successive over-relaxation in the three-colour
	order of Mesh.colourNodes (D-001). Outer iterations are power iterations on the fission source until its
	relative change is below PhysicsModel.solver.fissionSourceTolerance (§14.2).

	Data layout (all flat arrays, no metatables — this module runs under --!native):
		node data     [(g − 1)·N + node]
		face data     [((g − 1)·N + node − 1)·8 + f]   f = 1..6 radial directions, 7 = below, 8 = above
		neighbours    [(node − 1)·8 + f]  (0 = outer boundary)
		downscatter   sigS[(from − 1)·G + to][node]  (only from < to is used)
	The adjoint uses the transposed coupling: coefT at (i, f) = coef at (j, opposite f).
]]

export type Boundary = {
	radial: { number }, -- γ per group
	bottom: { number },
	top: { number },
}

export type Problem = {
	mesh: any,
	G: number,
	N: number,
	vol: { number },
	nb: { number },
	faceArea: { number }, -- [(node−1)·8 + f]
	hSelf: { number }, -- centre-to-face distance on this node's side
	hOther: { number }, -- centre-to-face distance on the neighbour's side
	opposite: { number }, -- [f] → face index seen from the neighbour
	-- cross sections, [(g−1)·N + node]
	D: { number },
	sigR: { number },
	nuSigF: { number },
	kapSigF: { number },
	chi: { number },
	sigS: { { number } }, -- sigS[(from−1)·G + to] = per-node array (nil when zero everywhere)
	dhat: { number }?, -- optional face corrections, same layout as coef
	bc: Boundary,
	-- assembled operator
	diag: { number },
	coef: { number },
	coefT: { number },
	assembled: boolean,
}

local Diffusion = {}

local FACES = 8

function Diffusion.newProblem(mesh: any, G: number, bc: Boundary): Problem
	local N = mesh.N
	local NR, NK = mesh.NR, mesh.NK
	local vol = table.create(N, 0)
	local nb = table.create(N * FACES, 0)
	local faceArea = table.create(N * FACES, 0)
	local hSelf = table.create(N * FACES, 0)
	local hOther = table.create(N * FACES, 0)
	local halfPitch = mesh.pitch_cm / 2
	for k = 1, NK do
		local dz = mesh.dz_cm[k]
		for r = 1, NR do
			local node = (k - 1) * NR + r
			local base = (node - 1) * FACES
			vol[node] = mesh.area_cm2 * dz
			for d = 1, 6 do
				local rn = mesh.nbr[(r - 1) * 6 + d]
				nb[base + d] = if rn ~= 0 then (k - 1) * NR + rn else 0
				faceArea[base + d] = mesh.side_cm * dz
				hSelf[base + d] = halfPitch
				hOther[base + d] = halfPitch
			end
			-- below
			nb[base + 7] = if k > 1 then node - NR else 0
			faceArea[base + 7] = mesh.area_cm2
			hSelf[base + 7] = dz / 2
			hOther[base + 7] = if k > 1 then mesh.dz_cm[k - 1] / 2 else 0
			-- above
			nb[base + 8] = if k < NK then node + NR else 0
			faceArea[base + 8] = mesh.area_cm2
			hSelf[base + 8] = dz / 2
			hOther[base + 8] = if k < NK then mesh.dz_cm[k + 1] / 2 else 0
		end
	end
	local total = G * N
	local p: Problem = {
		mesh = mesh,
		G = G,
		N = N,
		vol = vol,
		nb = nb,
		faceArea = faceArea,
		hSelf = hSelf,
		hOther = hOther,
		opposite = { 4, 5, 6, 1, 2, 3, 8, 7 },
		D = table.create(total, 0),
		sigR = table.create(total, 0),
		nuSigF = table.create(total, 0),
		kapSigF = table.create(total, 0),
		chi = table.create(total, 0),
		sigS = {},
		dhat = nil,
		bc = bc,
		diag = table.create(total, 0),
		coef = table.create(total * FACES, 0),
		coefT = table.create(total * FACES, 0),
		assembled = false,
	}
	return p
end

-- Downscatter array for from → to, created on first use.
function Diffusion.scatter(p: Problem, from: number, to: number): { number }
	assert(from < to, "only downscatter is modelled (no upscatter in a fast spectrum)")
	local idx = (from - 1) * p.G + to
	local arr = p.sigS[idx]
	if not arr then
		arr = table.create(p.N, 0)
		p.sigS[idx] = arr
	end
	return arr
end

--[[
	Build diag/coef/coefT from the current D, Σr, D̂ and boundary conditions. Call again whenever D or Σr change.
	D̂ is checked: a face correction larger than its D̃ would make the operator non-positive (the known CMFD
	failure), so it is refused rather than silently producing garbage.
]]
function Diffusion.assemble(p: Problem)
	local G, N = p.G, p.N
	local D, sigR, vol = p.D, p.sigR, p.vol
	local nb, area, hS, hO = p.nb, p.faceArea, p.hSelf, p.hOther
	local diag, coef = p.diag, p.coef
	local dhat = p.dhat
	for g = 1, G do
		local off = (g - 1) * N
		local gr, gb, gt = p.bc.radial[g], p.bc.bottom[g], p.bc.top[g]
		for node = 1, N do
			local Di = D[off + node]
			assert(Di > 0, "diffusion coefficient must be positive")
			local dsum = sigR[off + node] * vol[node]
			local base = (node - 1) * FACES
			local cbase = (off + node - 1) * FACES
			for f = 1, FACES do
				local j = nb[base + f]
				local A = area[base + f]
				local dh = if dhat then dhat[cbase + f] else 0
				if j ~= 0 then
					local Dj = D[off + j]
					local dt = 1 / (hS[base + f] / Di + hO[base + f] / Dj)
					assert(math.abs(dh) <= dt, "face correction D̂ exceeds D̃ (non-positive operator)")
					coef[cbase + f] = A * (dh - dt)
					dsum += A * (dt + dh)
				else
					local gamma
					if f <= 6 then
						gamma = gr
					elseif f == 7 then
						gamma = gb
					else
						gamma = gt
					end
					local db = if gamma > 0 then 1 / (hS[base + f] / Di + 1 / gamma) else 0
					coef[cbase + f] = 0
					dsum += A * (db + dh)
				end
			end
			diag[off + node] = dsum
		end
	end
	-- transpose for the adjoint
	local coefT, opp = p.coefT, p.opposite
	for g = 1, G do
		local off = (g - 1) * N
		for node = 1, N do
			local base = (node - 1) * FACES
			local cbase = (off + node - 1) * FACES
			for f = 1, FACES do
				local j = nb[base + f]
				coefT[cbase + f] = if j ~= 0 then coef[(off + j - 1) * FACES + opp[f]] else 0
			end
		end
	end
	p.assembled = true
end

--[[
	Apply the loss operator (leakage + removal) of group g to phi: out[node] = (Aφ)[node] / V[node].
	With adjoint = true the transposed operator A† is applied. Used by tests and residual checks.
]]
function Diffusion.applyLoss(p: Problem, g: number, phi: { number }, out: { number }, adjoint: boolean?)
	local N, off = p.N, (g - 1) * p.N
	local diag, nb, vol = p.diag, p.nb, p.vol
	local coef = if adjoint then p.coefT else p.coef
	for node = 1, N do
		local s = diag[off + node] * phi[off + node]
		local base = (node - 1) * FACES
		local cbase = (off + node - 1) * FACES
		for f = 1, FACES do
			local j = nb[base + f]
			if j ~= 0 then
				s += coef[cbase + f] * phi[off + j]
			end
		end
		out[node] = s / vol[node]
	end
end

--[[
	`sweeps` SOR sweeps for group g. phi and src are full G·N arrays; src is the volumetric source density.
	Uses coefT when adjoint is true. Calls budget:check() once per colour pass when a budget is given.
]]
function Diffusion.sweep(p: Problem, g: number, phi: { number }, src: { number }, sweeps: number, omega: number, adjoint: boolean, budget: any?)
	local off = (g - 1) * p.N
	local diag, nb, vol = p.diag, p.nb, p.vol
	local coef = if adjoint then p.coefT else p.coef
	local classes = p.mesh.colourNodes
	for _ = 1, sweeps do
		for c = 1, 3 do
			local nodes = classes[c]
			for n = 1, #nodes do
				local node = nodes[n]
				local s = src[off + node] * vol[node]
				local base = (node - 1) * FACES
				local cbase = (off + node - 1) * FACES
				for f = 1, FACES do
					local j = nb[base + f]
					if j ~= 0 then
						s -= coef[cbase + f] * phi[off + j]
					end
				end
				local old = phi[off + node]
				phi[off + node] = old + omega * (s / diag[off + node] - old)
			end
			if budget then
				budget:check()
			end
		end
	end
end

-- Fission source density S[node] = Σ_g νΣf φ
function Diffusion.fissionSource(p: Problem, phi: { number }, out: { number })
	local G, N, nuSigF = p.G, p.N, p.nuSigF
	for node = 1, N do
		out[node] = 0
	end
	for g = 1, G do
		local off = (g - 1) * N
		for node = 1, N do
			out[node] += nuSigF[off + node] * phi[off + node]
		end
	end
end

local function weightedSum(v: { number }, w: { number }, n: number): number
	local s = 0
	for i = 1, n do
		s += v[i] * w[i]
	end
	return s
end

export type EigenOptions = {
	tolerance: number, -- relative change of the fission source (§14.2)
	sweeps: number,
	omega: number,
	maxOuter: number,
	phi: { number }?, -- warm start (G·N)
	k: number?,
}

export type EigenResult = {
	k: number,
	phi: { number },
	outer: number,
	sourceChange: number,
	converged: boolean,
}

--[[
	Forward eigenvalue problem  Aφ = (1/k) χ S(φ) + scattering.  Returns the fundamental mode, normalised so the
	volume-integrated fission source equals 1.
]]
function Diffusion.solveEigen(p: Problem, opts: EigenOptions, budget: any?): EigenResult
	if not p.assembled then
		Diffusion.assemble(p)
	end
	local G, N, vol, chi = p.G, p.N, p.vol, p.chi
	local phi = opts.phi or table.create(G * N, 1)
	local k = opts.k or 1
	local src = table.create(G * N, 0)
	local S = table.create(N, 0)
	local Sold = table.create(N, 0)
	Diffusion.fissionSource(p, phi, S)
	local total = weightedSum(S, vol, N)
	assert(total > 0, "no fission source: check νΣf and the initial flux")
	for i = 1, G * N do
		phi[i] /= total
	end
	for i = 1, N do
		S[i] /= total
	end
	local change, outer = math.huge, 0
	while outer < opts.maxOuter do
		outer += 1
		for i = 1, N do
			Sold[i] = S[i]
		end
		for g = 1, G do
			local off = (g - 1) * N
			for node = 1, N do
				src[off + node] = chi[off + node] * S[node] / k
			end
			for from = 1, g - 1 do
				local arr = p.sigS[(from - 1) * G + g]
				if arr then
					local offFrom = (from - 1) * N
					for node = 1, N do
						src[off + node] += arr[node] * phi[offFrom + node]
					end
				end
			end
			Diffusion.sweep(p, g, phi, src, opts.sweeps, opts.omega, false, budget)
		end
		Diffusion.fissionSource(p, phi, S)
		local newTotal = weightedSum(S, vol, N)
		local oldTotal = weightedSum(Sold, vol, N)
		local kOld = k
		k = k * newTotal / oldTotal
		-- normalise to unit source; the source "changes" in shape and in magnitude (∝ k), so both are measured
		local diff2, norm2 = 0, 0
		for node = 1, N do
			S[node] /= newTotal
			local d = S[node] - Sold[node]
			diff2 += d * d * vol[node]
			norm2 += S[node] * S[node] * vol[node]
		end
		for i = 1, G * N do
			phi[i] /= newTotal
		end
		change = math.max(math.sqrt(diff2 / norm2), math.abs(k - kOld) / k)
		if change < opts.tolerance then
			break
		end
	end
	return { k = k, phi = phi, outer = outer, sourceChange = change, converged = change < opts.tolerance }
end

--[[
	Adjoint eigenvalue problem  A†φ† = (1/k) νΣf (χ·φ†) + scattering†.  Groups run slowest first (adjoint
	"upscatter" is the transpose of downscatter). Normalised so Σ_node V·Σ_g χ_g φ†_g = 1.
]]
function Diffusion.solveAdjoint(p: Problem, k: number, opts: EigenOptions, budget: any?): EigenResult
	if not p.assembled then
		Diffusion.assemble(p)
	end
	local G, N, vol, chi, nuSigF = p.G, p.N, p.vol, p.chi, p.nuSigF
	local adj = opts.phi or table.create(G * N, 1)
	local src = table.create(G * N, 0)
	local C = table.create(N, 0) -- adjoint fission "importance source": Σ_g χ_g φ†_g
	local Cold = table.create(N, 0)
	local function importance(out: { number })
		for node = 1, N do
			out[node] = 0
		end
		for g = 1, G do
			local off = (g - 1) * N
			for node = 1, N do
				out[node] += chi[off + node] * adj[off + node]
			end
		end
	end
	importance(C)
	local total = weightedSum(C, vol, N)
	assert(total > 0, "adjoint start vector has no importance")
	for i = 1, G * N do
		adj[i] /= total
	end
	for i = 1, N do
		C[i] /= total
	end
	local change, outer, kAdj = math.huge, 0, k
	while outer < opts.maxOuter do
		outer += 1
		for i = 1, N do
			Cold[i] = C[i]
		end
		for g = G, 1, -1 do
			local off = (g - 1) * N
			for node = 1, N do
				src[off + node] = nuSigF[off + node] * C[node] / kAdj
			end
			for to = g + 1, G do
				local arr = p.sigS[(g - 1) * G + to]
				if arr then
					local offTo = (to - 1) * N
					for node = 1, N do
						src[off + node] += arr[node] * adj[offTo + node]
					end
				end
			end
			Diffusion.sweep(p, g, adj, src, opts.sweeps, opts.omega, true, budget)
		end
		importance(C)
		local newTotal = weightedSum(C, vol, N)
		local oldTotal = weightedSum(Cold, vol, N)
		local kOld = kAdj
		kAdj = kAdj * newTotal / oldTotal
		local diff2, norm2 = 0, 0
		for node = 1, N do
			C[node] /= newTotal
			local d = C[node] - Cold[node]
			diff2 += d * d * vol[node]
			norm2 += C[node] * C[node] * vol[node]
		end
		for i = 1, G * N do
			adj[i] /= newTotal
		end
		change = math.max(math.sqrt(diff2 / norm2), math.abs(kAdj - kOld) / kAdj)
		if change < opts.tolerance then
			break
		end
	end
	return { k = kAdj, phi = adj, outer = outer, sourceChange = change, converged = change < opts.tolerance }
end

--[[
	Albedo α (fraction of the outgoing partial current returned) → γ = J_net/φ_surface in diffusion theory:
	γ = (1 − α) / (2 (1 + α)).  α = 0 is Marshak vacuum (γ = ½); α = 1 is reflective (γ = 0).
]]
function Diffusion.gammaFromAlbedo(alpha: number): number
	assert(alpha >= 0 and alpha <= 1, "albedo must be in [0, 1]")
	return (1 - alpha) / (2 * (1 + alpha))
end

return table.freeze(Diffusion)
