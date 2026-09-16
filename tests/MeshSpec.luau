--!strict
-- Mesh: hex-Z geometry and topology (spec §2.1, §2.2, §3.7; decisions D-001, D-010).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local CoreDir = ServerScriptService:WaitForChild("Kallskar"):WaitForChild("Systems"):WaitForChild("Core")
local Mesh = require(CoreDir:WaitForChild("Mesh")) :: any

local m = Mesh.build(Config)

return {
	["sizes match §3.7"] = function(t)
		t.eq(m.NR, Config.PhysicsModel.radialNodes)
		t.eq(m.NK, 14)
		t.eq(m.N * Config.PhysicsModel.energyGroups, Config.PhysicsModel.flowUnknowns, "469 × 14 × 4 = 26,264")
		local total = 0
		for _, h in m.dz_cm do
			total += h
		end
		local g = Config.Core.geometry
		t.near(total, (g.lowerReflector_mm + g.fissileHeight_mm + g.upperPlenum_mm) / 10, 1e-9, "axial extent")
		t.eq(#m.fuelLayers, 10)
		t.near(m.zBottom_cm[m.fuelLayers[1]], 0, 1e-9, "fuel starts at z = 0")
		t.near(m.area_cm2, math.sqrt(3) / 2 * 17.9 ^ 2, 1e-9, "hex cell area from the 179 mm pitch")
		t.near(6 * m.side_cm * m.pitch_cm / 2 / 2, m.area_cm2, 1e-9, "area = 6 triangles of base side, height pitch/2")
	end,

	["ring bookkeeping (§2.2)"] = function(t)
		local perRing = {}
		for r = 1, m.NR do
			perRing[m.ring[r]] = (perRing[m.ring[r]] or 0) + 1
			local n = m.ring[r]
			local first = if n == 0 then 1 else 2 + 3 * (n - 1) * n
			t.eq(r - first, m.posInRing[r], `index {r} is position {m.posInRing[r]} of ring {n}`)
			local hexDistance = (math.abs(m.q[r]) + math.abs(m.rq[r]) + math.abs(m.q[r] + m.rq[r])) / 2
			t.eq(hexDistance, n, `node {r} lies on ring {n}`)
		end
		for n = 0, m.lastRing do
			t.eq(perRing[n], if n == 0 then 1 else 6 * n, `ring {n} size`)
		end
		t.eq(m.corePositions, Config.Core.totals.corePositions, "rings 0–10 = 331")
	end,

	["neighbours are symmetric, one pitch apart, and the boundary has 6(2n+1) faces"] = function(t)
		for r = 1, m.NR do
			local count = 0
			for d = 0, 5 do
				local nb = m.nbr[(r - 1) * 6 + d + 1]
				if nb ~= 0 then
					count += 1
					local back = m.nbr[(nb - 1) * 6 + ((d + 3) % 6) + 1]
					t.eq(back, r, `neighbour of {r} in direction {d} points back`)
					local dist = math.sqrt((m.x_cm[r] - m.x_cm[nb]) ^ 2 + (m.y_cm[r] - m.y_cm[nb]) ^ 2)
					t.near(dist, m.pitch_cm, 1e-9, "centre distance = pitch")
				end
			end
			if m.ring[r] < m.lastRing then
				t.eq(count, 6, `interior node {r} has 6 neighbours`)
			else
				t.ok(count == 3 or count == 4, `outer-ring node {r} has 3 (corner) or 4 (edge) neighbours, got {count}`)
			end
		end
		t.eq(m.boundaryFaces, 6 * (2 * m.lastRing + 1), "boundary face count of a hexagon of rings 0..n")
	end,

	["three-colouring is proper radially and axially (D-001)"] = function(t)
		local sizes = {}
		for c = 1, 3 do
			sizes[c] = #m.colourNodes[c]
			for _, node in m.colourNodes[c] do
				t.eq(Mesh.nodeColour(m, node), c - 1, "node listed under its own colour")
			end
		end
		t.eq(sizes[1] + sizes[2] + sizes[3], m.N, "every node has exactly one colour")
		local clashes = 0
		for k = 1, m.NK do
			for r = 1, m.NR do
				local c = (m.radialColour[r] + k) % 3
				for d = 0, 5 do
					local nb = m.nbr[(r - 1) * 6 + d + 1]
					if nb ~= 0 and (m.radialColour[nb] + k) % 3 == c then
						clashes += 1
					end
				end
				if k < m.NK and (m.radialColour[r] + k + 1) % 3 == c then
					clashes += 1
				end
			end
		end
		t.eq(clashes, 0, "no two neighbouring nodes share a colour")
		-- and a red-black (2-colour) split really is impossible: rings 0 and 1 contain a triangle
		local a, b = 1, 2
		local c3 = 0
		for d = 0, 5 do
			local nb = m.nbr[(a - 1) * 6 + d + 1]
			if nb ~= b and nb ~= 0 then
				for e = 0, 5 do
					if m.nbr[(nb - 1) * 6 + e + 1] == b then
						c3 = nb
					end
				end
			end
		end
		t.ok(c3 ~= 0, "centre, a ring-1 node and another node are mutually adjacent (a triangle)")
	end,

	["rods sit where D-010 says and leave the right fuel counts"] = function(t)
		local bySet, fuelInner, fuelOuter, zoneCount = {}, 0, 0, { 0, 0, 0 }
		for r = 1, m.NR do
			if m.kind[r] == "rod" then
				bySet[m.rodSet[r]] = (bySet[m.rodSet[r]] or 0) + 1
				t.ok(m.rodId[r] >= 1 and m.rodPosition[m.rodId[r]] == r, "rod id round-trips")
			elseif m.kind[r] == "fuel" then
				if m.fuelZone[r] == "inner" then
					fuelInner += 1
				else
					fuelOuter += 1
				end
				zoneCount[m.flowZone[r]] += 1
			end
		end
		t.eq(bySet.RR, 3)
		t.eq(bySet.SM_A, 6)
		t.eq(bySet.SM_B, 6)
		t.eq(bySet.SM_C, 6)
		t.eq(bySet.SSR, 9)
		t.eq(#m.rodPosition, 30)
		t.eq(fuelInner, Config.Core.totals.fuelInner)
		t.eq(fuelOuter, Config.Core.totals.fuelOuter)
		for zi, z in Config.Core.flow.zones do
			t.eq(zoneCount[zi], z.fuel, `flow zone {z.name}`)
		end
		-- rod ids run RR, SM_A, SM_B, SM_C, SSR
		t.eq(m.rodSet[m.rodPosition[1]], "RR")
		t.eq(m.rodSet[m.rodPosition[4]], "SM_A")
		t.eq(m.rodSet[m.rodPosition[10]], "SM_B")
		t.eq(m.rodSet[m.rodPosition[16]], "SM_C")
		t.eq(m.rodSet[m.rodPosition[22]], "SSR")
		-- spec §2.2: RR at 0/120/240 on ring 2; bank B exactly 30° from bank A
		for i = 1, 3 do
			t.eq(m.ring[m.rodPosition[i]], 2)
		end
		local aAngle = m.angle_deg[m.rodPosition[4]]
		local bAngle = m.angle_deg[m.rodPosition[10]]
		t.near((bAngle - aAngle) % 60, 30, 1e-6, "bank B is offset 30° from bank A")
		-- 3-fold symmetry of every rod set
		for _, set in { "RR", "SM_A", "SM_B", "SM_C", "SSR" } do
			local angles = {}
			for r = 1, m.NR do
				if m.rodSet[r] == set then
					angles[string.format("%d:%.3f", m.ring[r], m.angle_deg[r])] = true
				end
			end
			for r = 1, m.NR do
				if m.rodSet[r] == set then
					local rotated = string.format("%d:%.3f", m.ring[r], (m.angle_deg[r] + 120) % 360)
					t.ok(angles[rotated], `{set} is 3-fold symmetric`)
				end
			end
		end
	end,

	["material sets follow position kind and layer"] = function(t)
		local id = m.materialSetId
		local counts = {}
		for node = 1, m.N do
			local name = m.materialSetNames[m.matSet[node]]
			counts[name] = (counts[name] or 0) + 1
		end
		t.eq(counts.innerFuel, 145 * 10)
		t.eq(counts.outerFuel, 156 * 10)
		t.eq(counts.sodiumFollower, 30 * 10)
		t.eq(counts.steelReflector, (66 + 72) * 14)
		t.eq(counts.lowerStructure, 331 * 2)
		t.eq(counts.upperPlenum, 331 * 2)
		t.ok(id.regulatingAbsorber and id.shimAbsorber and id.ssrAbsorber, "absorber sets exist for RodModel")
	end,
}
