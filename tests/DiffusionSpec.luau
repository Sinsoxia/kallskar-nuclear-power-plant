--!strict
--[[
	Diffusion solver verification against answers that are known exactly (no plant data needed):
	  1. plane waves are exact eigenvectors of the discrete hex-Z operator,
	  2. an infinite medium (all faces reflective) gives the algebraic k∞, including 4-group downscatter,
	  3. a 1D slab with Marshak vacuum faces converges to the continuous diffusion k at second order,
	  4. the adjoint operator is the exact transpose (also with D̂ corrections), and forward/adjoint k agree.
	The material numbers below are arbitrary test inputs, not plant data; every expected value is computed
	analytically from them.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local CoreDir = ServerScriptService:WaitForChild("Kallskar"):WaitForChild("Systems"):WaitForChild("Core")
local Mesh = require(CoreDir:WaitForChild("Mesh")) :: any
local Diffusion = require(CoreDir:WaitForChild("Diffusion")) :: any

-- A config shaped like the real one, with every ring fuel and a chosen axial layout.
local function fakeConfig(lastRing: number, fuelLayers: number, layerMm: number, pitchMm: number?)
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
			geometry = {
				assemblyPitch_mm = pitchMm or 179,
				lastCoreRing = lastRing,
				lowerReflector_mm = 0,
				fissileHeight_mm = fuelLayers * layerMm,
				upperPlenum_mm = 0,
			},
			rodLayout = {},
			flow = { zones = { { name = "all", firstRing = 0, lastRing = lastRing, fuel = 0, flowFactor = 1 } } },
		},
	}
end

local function fill(p: any, g: number, field: string, value: number)
	local arr = p[field]
	for node = 1, p.N do
		arr[(g - 1) * p.N + node] = value
	end
end

local function uniformBc(G: number, gamma: number)
	local r, b, tp = {}, {}, {}
	for g = 1, G do
		r[g], b[g], tp[g] = gamma, gamma, gamma
	end
	return { radial = r, bottom = b, top = tp }
end

-- 4-group test material (fast spectrum shape: fission neutrons born in groups 1–3, downscatter only)
local MAT = {
	D = { 2.2, 1.6, 1.2, 0.9 },
	sigR = { 0.012, 0.009, 0.010, 0.008 },
	nuSigF = { 0.010, 0.008, 0.012, 0.020 },
	chi = { 0.60, 0.35, 0.05, 0.0 },
	scat = { { 1, 2, 0.004 }, { 1, 3, 0.001 }, { 2, 3, 0.003 }, { 2, 4, 0.0005 }, { 3, 4, 0.002 } },
}

local function kInfinity(): number
	local phi = {}
	for g = 1, 4 do
		local s = MAT.chi[g]
		for _, e in MAT.scat do
			if e[2] == g then
				s += e[3] * phi[e[1]]
			end
		end
		phi[g] = s / MAT.sigR[g]
	end
	local k = 0
	for g = 1, 4 do
		k += MAT.nuSigF[g] * phi[g]
	end
	return k
end

local function loadMaterial(p: any)
	for g = 1, 4 do
		fill(p, g, "D", MAT.D[g])
		fill(p, g, "sigR", MAT.sigR[g])
		fill(p, g, "nuSigF", MAT.nuSigF[g])
		fill(p, g, "chi", MAT.chi[g])
	end
	for _, e in MAT.scat do
		local arr = Diffusion.scatter(p, e[1], e[2])
		for node = 1, p.N do
			arr[node] = e[3]
		end
	end
end

local function dot(a: { number }, b: { number }, n: number): number
	local s = 0
	for i = 1, n do
		s += a[i] * b[i]
	end
	return s
end

return {
	["plane waves are exact eigenvectors of the hex-Z operator"] = function(t)
		local m = Mesh.build(Config)
		local p = Diffusion.newProblem(m, 1, uniformBc(1, 0))
		local D = 1.3
		fill(p, 1, "D", D)
		Diffusion.assemble(p)
		local kx, ky, kz = 0.071, -0.043, 0.09
		local phi = table.create(p.N, 0)
		local zc = {}
		for k = 1, m.NK do
			zc[k] = m.zBottom_cm[k] + m.dz_cm[k] / 2
		end
		for k = 1, m.NK do
			for r = 1, m.NR do
				phi[(k - 1) * m.NR + r] = math.cos(kx * m.x_cm[r] + ky * m.y_cm[r]) * math.cos(kz * zc[k])
			end
		end
		local out = table.create(p.N, 0)
		Diffusion.applyLoss(p, 1, phi, out)
		-- exact discrete eigenvalue: radial (2D/3h²)·Σ(1 − cos(k·d)), axial (D/dz²)·(2 − 2cos(kz·dz))
		local h = m.pitch_cm
		local radial = 0
		for d = 0, 5 do
			local a = math.rad(60 * d)
			radial += 1 - math.cos(kx * h * math.cos(a) + ky * h * math.sin(a))
		end
		radial *= 2 * D / (3 * h * h)
		local dz = m.dz_cm[m.fuelLayers[1]]
		local axial = D / (dz * dz) * (2 - 2 * math.cos(kz * dz))
		local checked, worst = 0, 0
		for k = m.fuelLayers[2], m.fuelLayers[#m.fuelLayers - 1] do
			for r = 1, m.NR do
				if m.ring[r] < m.lastRing then
					local node = (k - 1) * m.NR + r
					local expect = (radial + axial) * phi[node]
					local err = math.abs(out[node] - expect)
					if err > worst then
						worst = err
					end
					checked += 1
				end
			end
		end
		t.log(string.format("%d interior nodes, worst |error| %.3e (eigenvalue %.6e)", checked, worst, radial + axial))
		t.ok(worst < 1e-12, "operator matches the exact plane-wave eigenvalue to machine precision")
	end,

	["infinite medium reproduces the algebraic 4-group k-infinity"] = function(t)
		local m = Mesh.build(fakeConfig(2, 3, 100))
		local p = Diffusion.newProblem(m, 4, uniformBc(4, 0))
		loadMaterial(p)
		local res = Diffusion.solveEigen(p, { tolerance = 1e-11, sweeps = 4, omega = 1, maxOuter = 500 })
		local exact = kInfinity()
		t.log(string.format("k = %.12f, exact %.12f, outers %d", res.k, exact, res.outer))
		t.ok(res.converged, "converged")
		t.near(res.k, exact, 1e-9, "k-infinity")
		-- flux is spatially flat and in the analytic group ratio
		local off2 = p.N
		t.near(res.phi[off2 + 5] / res.phi[5], res.phi[off2 + 1] / res.phi[1], 1e-9, "same spectrum everywhere")
	end,

	["slab with Marshak vacuum faces converges to the diffusion k at second order"] = function(t)
		local D, sigA, nuSigF, H = 1.5, 0.004, 0.0045, 100
		-- exact continuous answer: φ = cos(Bx), Marshak J = φ/2 at x = ±H/2  →  tan(BH/2) = 1/(2DB)
		local lo, hi = 1e-9, math.pi / H - 1e-12
		for _ = 1, 200 do
			local mid = (lo + hi) / 2
			if math.tan(mid * H / 2) - 1 / (2 * D * mid) > 0 then
				hi = mid
			else
				lo = mid
			end
		end
		local B = (lo + hi) / 2
		local kExact = nuSigF / (sigA + D * B * B)
		local function solve(layers: number): number
			local m = Mesh.build(fakeConfig(0, layers, H * 10 / layers))
			local bc = { radial = { 0 }, bottom = { 0.5 }, top = { 0.5 } }
			local p = Diffusion.newProblem(m, 1, bc)
			fill(p, 1, "D", D)
			fill(p, 1, "sigR", sigA)
			fill(p, 1, "nuSigF", nuSigF)
			fill(p, 1, "chi", 1)
			local r = Diffusion.solveEigen(p, { tolerance = 1e-12, sweeps = 8, omega = 1, maxOuter = 20000 })
			assert(r.converged, `slab with {layers} layers did not converge ({r.sourceChange})`)
			return r.k
		end
		local k1, k2, k4 = solve(25), solve(50), solve(100)
		local e1, e2, e4 = k1 - kExact, k2 - kExact, k4 - kExact
		local p12, p24 = math.log(math.abs(e1 / e2), 2), math.log(math.abs(e2 / e4), 2)
		t.log(string.format("kExact %.10f  errors %.3e %.3e %.3e  observed orders %.3f %.3f", kExact, e1, e2, e4, p12, p24))
		t.ok(math.abs(p24 - 2) < 0.1, "second-order convergence in the asymptotic range")
		local richardson = (4 * k4 - k2) / 3
		t.ok(math.abs(richardson - kExact) < math.abs(e4) / 10, "Richardson extrapolation lands on the exact answer")
	end,

	["adjoint operator is the exact transpose, with and without D-hat"] = function(t)
		local m = Mesh.build(fakeConfig(2, 4, 100))
		local p = Diffusion.newProblem(m, 1, { radial = { 0.5 }, bottom = { 0.3 }, top = { 0.1 } })
		-- deterministic but non-uniform D and Σr so the operator is not trivially symmetric in value
		for node = 1, p.N do
			p.D[node] = 1 + 0.5 * math.sin(node * 1.7)
			p.sigR[node] = 0.01 + 0.004 * math.cos(node * 0.9)
		end
		local function reciprocity(label: string)
			Diffusion.assemble(p)
			local x, y = table.create(p.N, 0), table.create(p.N, 0)
			for i = 1, p.N do
				x[i] = math.sin(i * 0.37) + 1.5
				y[i] = math.cos(i * 0.53) + 1.5
			end
			local Ax, ATy = table.create(p.N, 0), table.create(p.N, 0)
			Diffusion.applyLoss(p, 1, x, Ax)
			Diffusion.applyLoss(p, 1, y, ATy, true)
			-- applyLoss divides by volume, so compare ⟨y, V·Ax⟩ with ⟨x, V·A†y⟩
			for i = 1, p.N do
				Ax[i] *= p.vol[i]
				ATy[i] *= p.vol[i]
			end
			local lhs, rhs = dot(y, Ax, p.N), dot(x, ATy, p.N)
			t.log(string.format("%s: <y,Ax> = %.12e  <A'y,x> = %.12e", label, lhs, rhs))
			t.near(lhs, rhs, 1e-10 * math.abs(lhs), `{label}: transpose identity`)
		end
		reciprocity("finite difference")
		-- antisymmetric face corrections, each well inside |D̂| < D̃
		local dhat = table.create(p.N * 8, 0)
		for node = 1, p.N do
			for f = 1, 8 do
				local j = p.nb[(node - 1) * 8 + f]
				if j ~= 0 and node < j then
					local jf = p.opposite[f]
					local dtilde = 1 / (p.hSelf[(node - 1) * 8 + f] / p.D[node] + p.hOther[(node - 1) * 8 + f] / p.D[j])
					local v = 0.3 * dtilde * math.sin(node + f)
					dhat[(node - 1) * 8 + f] = v
					dhat[(j - 1) * 8 + jf] = -v
				end
			end
		end
		p.dhat = dhat
		reciprocity("with D-hat")
		-- a correction larger than D̃ is refused
		dhat[1] = 1e6
		t.throws(function()
			Diffusion.assemble(p)
		end, "exceeds")
	end,

	["forward and adjoint eigenvalues agree on a heterogeneous core"] = function(t)
		local m = Mesh.build(fakeConfig(3, 5, 100))
		local p = Diffusion.newProblem(m, 4, uniformBc(4, 0.5))
		loadMaterial(p)
		-- make the outer ring a non-fissile scatterer so the problem is genuinely heterogeneous
		for node = 1, p.N do
			local r = (node - 1) % m.NR + 1
			if m.ring[r] == m.lastRing then
				for g = 1, 4 do
					p.nuSigF[(g - 1) * p.N + node] = 0
					p.chi[(g - 1) * p.N + node] = 0
				end
			end
		end
		local opts = { tolerance = 1e-10, sweeps = 6, omega = 1, maxOuter = 5000 }
		local fwd = Diffusion.solveEigen(p, opts)
		local adj = Diffusion.solveAdjoint(p, fwd.k, table.clone(opts))
		t.log(string.format("k forward %.10f (%d outers), k adjoint %.10f (%d outers)", fwd.k, fwd.outer, adj.k, adj.outer))
		t.ok(fwd.converged and adj.converged, "both converged")
		t.ok(fwd.k < kInfinity(), "leakage lowers k below k-infinity")
		t.near(adj.k, fwd.k, 1e-7, "adjoint eigenvalue equals forward eigenvalue")
		for i = 1, 4 * p.N do
			t.ok(fwd.phi[i] >= 0 and adj.phi[i] >= 0, "fundamental mode is non-negative")
		end
	end,

	["albedo maps to the diffusion boundary parameter"] = function(t)
		t.near(Diffusion.gammaFromAlbedo(0), 0.5, 1e-15, "vacuum (Marshak)")
		t.near(Diffusion.gammaFromAlbedo(1), 0, 1e-15, "reflective")
		t.near(Diffusion.gammaFromAlbedo(0.5), 1 / 6, 1e-15)
		t.throws(function()
			Diffusion.gammaFromAlbedo(1.2)
		end)
	end,
}
