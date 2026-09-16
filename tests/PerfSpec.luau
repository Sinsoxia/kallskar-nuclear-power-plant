--!strict
--[[
	Performance budgets on the full K1 mesh (469 × 14 × 4 = 26,264 unknowns).

	Budget derivation (all from the spec): a shape step may use at most Clocks.shapeSliceBudget_s per frame
	(§14.2, 4 ms) and must finish inside its fastest cadence Clocks.shapeFast_s (§3.7, 0.5 s). At a 60 Hz server
	(Engineering.serverFrame_s) that is 30 frames × 4 ms = 120 ms of solver time. A warm-started step costs
	sweepsPerGroup (4–8) × groups (4) × outer passes (2–3, §14.2) group-sweeps; the worst case (8 × 4 × 3 = 96)
	must fit in 120 ms.

	The material is an arbitrary uniform test medium (not plant data); only timing matters here.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local CoreDir = ServerScriptService:WaitForChild("Kallskar"):WaitForChild("Systems"):WaitForChild("Core")
local Mesh = require(CoreDir:WaitForChild("Mesh")) :: any
local Diffusion = require(CoreDir:WaitForChild("Diffusion")) :: any

local function fullProblem()
	local m = Mesh.build(Config)
	local G = Config.PhysicsModel.energyGroups
	local gamma = {}
	for g = 1, G do
		gamma[g] = 0.5
	end
	local p = Diffusion.newProblem(m, G, { radial = gamma, bottom = gamma, top = gamma })
	for g = 1, G do
		for node = 1, p.N do
			local i = (g - 1) * p.N + node
			p.D[i] = 2.2 - 0.4 * g
			p.sigR[i] = 0.008 + 0.001 * g
			p.nuSigF[i] = 0.004 + 0.002 * g
			p.chi[i] = if g == 1 then 0.6 elseif g == 2 then 0.35 elseif g == 3 then 0.05 else 0
		end
	end
	for g = 2, G do
		local arr = Diffusion.scatter(p, g - 1, g)
		for node = 1, p.N do
			arr[node] = 0.003
		end
	end
	Diffusion.assemble(p)
	return p
end

local function median(xs: { number }): number
	table.sort(xs)
	return xs[math.ceil(#xs / 2)]
end

return {
	["shape step fits the §3.7/§14.2 time budget"] = function(t)
		local p = fullProblem()
		local G, N = p.G, p.N
		local phi = table.create(G * N, 1)
		local src = table.create(G * N, 0.001)
		-- warm up (native code, caches)
		for g = 1, G do
			Diffusion.sweep(p, g, phi, src, 1, 1, false)
		end
		local samples = {}
		for _ = 1, 15 do
			local t0 = os.clock()
			for g = 1, G do
				Diffusion.sweep(p, g, phi, src, 1, 1, false)
			end
			table.insert(samples, (os.clock() - t0) / G)
		end
		local perGroupSweep = median(samples)
		local solver = Config.PhysicsModel.solver
		local worstSweeps = solver.sweepsPerGroup[2] * G * solver.typicalOuterPasses[2]
		local worst = worstSweeps * perGroupSweep
		local frames = Config.Clocks.shapeFast_s / Config.Engineering.serverFrame_s
		local budget = frames * Config.Clocks.shapeSliceBudget_s
		t.log(string.format("unknowns %d; one group-sweep %.2f ms (median of 15); worst shape step %d sweeps = %.1f ms; budget %.0f ms",
			G * N, perGroupSweep * 1000, worstSweeps, worst * 1000, budget * 1000))
		t.ok(worst <= budget, "worst-case shape step fits inside the fast cadence")
		t.ok(perGroupSweep <= Config.Clocks.shapeSliceBudget_s, "one group-sweep fits inside one frame slice")
	end,

	["full-core eigenvalue from a cold start (logged)"] = function(t)
		local p = fullProblem()
		local t0 = os.clock()
		local res = Diffusion.solveEigen(p, {
			tolerance = Config.PhysicsModel.solver.fissionSourceTolerance,
			sweeps = Config.PhysicsModel.solver.sweepsPerGroup[1],
			omega = 1,
			maxOuter = 2000,
		})
		local dt = os.clock() - t0
		t.log(string.format("k = %.6f after %d outers in %.2f s (converged %s, change %.2e)", res.k, res.outer, dt, tostring(res.converged), res.sourceChange))
		t.ok(res.converged, "cold-start eigenvalue converges")
	end,
}
