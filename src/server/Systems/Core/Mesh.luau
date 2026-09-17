--!strict
--[[
	Mesh — hexagonal-Z geometry and topology for the 3D multigroup diffusion model (spec §3.7, §2.1, §2.2).
	=========================================================================================================

	Radial: one node per hexagonal position in rings 0..PhysicsModel.radialLastRing (469 nodes).
	Axial:  PhysicsModel.axial layers (2 lower structure + 10 fuel + 2 upper plenum = 14).
	Node index (1-based): node = (k − 1) · NR + r, with r the radial index and k the layer.
	Flux unknown index (used by the solver): (g − 1) · N + node.

	Geometry uses axial hex coordinates (q, r). Neighbour directions, anticlockwise from 0°:
		dir0 (1,0)  dir1 (0,1)  dir2 (−1,1)  dir3 (−1,0)  dir4 (0,−1)  dir5 (1,−1)
	Ring n position j lies on edge e = ⌊j/n⌋ at step s = j mod n:  n·dir[e] + s·dir[e+2].
	Cartesian (in pitches): x = q + r/2, y = r·√3/2, so ring corners sit at angles 60°·e, matching the angles in
	Config.Core.rodLayout (D-010).

	Colouring (D-001): radial colour c = (q − r) mod 3 is a proper 3-colouring of the hex lattice; node colour is
	(c + k) mod 3, which also separates axial neighbours. All nodes of one colour can be updated independently.

	Everything here is computed once, from Config, into flat arrays. No metatables; safe to read from --!native code.
]]

export type Mesh = {
	NR: number,
	NK: number,
	N: number,
	lastRing: number,
	-- radial
	q: { number },
	rq: { number },
	ring: { number },
	posInRing: { number },
	angle_deg: { number },
	x_cm: { number },
	y_cm: { number },
	nbr: { number }, -- nbr[(r − 1)·6 + d + 1] = radial neighbour in direction d (0..5), or 0 at the boundary
	radialColour: { number },
	kind: { string }, -- "fuel" | "rod" | "reflector"
	fuelZone: { string? }, -- "inner" | "outer" for fuel positions
	flowZone: { number }, -- 1..3 for fuel positions (§2.5), 0 otherwise
	rodSet: { string? }, -- "RR" | "SM_A" | "SM_B" | "SM_C" | "SSR"
	rodId: { number }, -- 1..30 for rod positions, 0 otherwise
	rodPosition: { number }, -- rodId → radial index
	corePositions: number, -- radial indices 1..corePositions are rings 0..lastCoreRing (the 331-position map)
	-- axial
	layerKind: { string }, -- "lower" | "fuel" | "upper"
	dz_cm: { number },
	zBottom_cm: { number }, -- bottom of each layer, measured from the bottom of the fuel (negative below)
	fuelLayers: { number }, -- layer indices of the fuel region, bottom to top
	-- geometry
	pitch_cm: number,
	side_cm: number,
	area_cm2: number,
	-- material set per node (index into PhysicsModel.materialSets)
	materialSetNames: { string },
	materialSetId: { [string]: number },
	matSet: { number },
	-- colour classes: nodes of each colour 1..3
	colourNodes: { { number } },
	boundaryFaces: number,
}

local DIRS = {
	{ 1, 0 },
	{ 0, 1 },
	{ -1, 1 },
	{ -1, 0 },
	{ 0, -1 },
	{ 1, -1 },
}
local SQRT3 = math.sqrt(3)

local Mesh = {}

local function key(q: number, r: number): number
	-- unique integer key for |q|,|r| < 1000
	return (q + 1000) * 4096 + (r + 1000)
end

function Mesh.axialOf(n: number, j: number): (number, number)
	if n == 0 then
		return 0, 0
	end
	local e = j // n
	local s = j % n
	local d, t = DIRS[e + 1], DIRS[(e + 2) % 6 + 1]
	return n * d[1] + s * t[1], n * d[2] + s * t[2]
end

function Mesh.build(config: any): Mesh
	local pm = config.PhysicsModel
	local core = config.Core
	local lastRing = pm.radialLastRing
	local NR = 1 + 3 * lastRing * (lastRing + 1)
	assert(NR == pm.radialNodes, `rings 0–{lastRing} hold {NR} positions, config says {pm.radialNodes}`)

	local ringInfo = {}
	for _, info in core.rings do
		ringInfo[info.ring] = info
	end

	local pitch = core.geometry.assemblyPitch_mm / 10
	local m: any = {
		NR = NR,
		lastRing = lastRing,
		q = table.create(NR, 0),
		rq = table.create(NR, 0),
		ring = table.create(NR, 0),
		posInRing = table.create(NR, 0),
		angle_deg = table.create(NR, 0),
		x_cm = table.create(NR, 0),
		y_cm = table.create(NR, 0),
		nbr = table.create(NR * 6, 0),
		radialColour = table.create(NR, 0),
		kind = table.create(NR, ""),
		fuelZone = {},
		flowZone = table.create(NR, 0),
		rodSet = {},
		rodId = table.create(NR, 0),
		rodPosition = {},
		pitch_cm = pitch,
		side_cm = pitch / SQRT3,
		area_cm2 = SQRT3 / 2 * pitch * pitch,
	}

	-- Radial positions, ring by ring
	local index = {}
	local rIdx = 0
	local corePositions = 0
	for n = 0, lastRing do
		local count = if n == 0 then 1 else 6 * n
		for j = 0, count - 1 do
			rIdx += 1
			local q, r = Mesh.axialOf(n, j)
			m.q[rIdx], m.rq[rIdx] = q, r
			m.ring[rIdx], m.posInRing[rIdx] = n, j
			local x, y = q + r / 2, r * SQRT3 / 2
			m.x_cm[rIdx], m.y_cm[rIdx] = x * pitch, y * pitch
			m.angle_deg[rIdx] = if n == 0 then 0 else (math.deg(math.atan2(y, x)) % 360)
			m.radialColour[rIdx] = (q - r) % 3
			index[key(q, r)] = rIdx
			local info = ringInfo[n]
			assert(info, `Config.Core.rings has no entry for ring {n}`)
			if info.kind == "fuel" then
				m.kind[rIdx] = "fuel"
				m.fuelZone[rIdx] = info.fuelZone
			elseif info.kind == "reflector" then
				m.kind[rIdx] = "reflector"
			else
				error(`ring {n} of kind '{info.kind}' is inside the radial mesh; only fuel and reflector rings are modelled`)
			end
		end
		if n <= core.geometry.lastCoreRing then
			corePositions = rIdx
		end
	end
	assert(rIdx == NR)
	m.corePositions = corePositions

	-- Neighbours
	local boundary = 0
	for r = 1, NR do
		for d = 0, 5 do
			local dir = DIRS[d + 1]
			local nb = index[key(m.q[r] + dir[1], m.rq[r] + dir[2])] or 0
			m.nbr[(r - 1) * 6 + d + 1] = nb
			if nb == 0 then
				boundary += 1
			end
		end
	end
	m.boundaryFaces = boundary

	-- Rods (D-010 angles), numbered by set then angle: RR, SM_A, SM_B, SM_C, SSR
	local ORDER = { RR = 1, SM_A = 2, SM_B = 3, SM_C = 4, SSR = 5 }
	local rods = {}
	for _, layout in core.rodLayout do
		for _, angle in layout.angles_deg do
			local found = 0
			local count = if layout.ring == 0 then 1 else 6 * layout.ring
			-- rings 0..n−1 hold 1 + 3n(n−1) positions, so ring n starts right after them
			local first = if layout.ring == 0 then 1 else 2 + 3 * (layout.ring - 1) * layout.ring
			for r = first, first + count - 1 do
				local diff = math.abs(((m.angle_deg[r] - angle + 180) % 360) - 180)
				if diff < 1e-6 then
					found = r
					break
				end
			end
			assert(found ~= 0, `no position at {angle}° on ring {layout.ring} for {layout.set}`)
			assert(m.kind[found] == "fuel", `two rods placed at ring {layout.ring}, {angle}°`)
			m.kind[found] = "rod"
			m.fuelZone[found] = nil
			m.rodSet[found] = layout.set
			table.insert(rods, { r = found, set = layout.set, angle = angle })
		end
	end
	table.sort(rods, function(a, b)
		if ORDER[a.set] ~= ORDER[b.set] then
			return ORDER[a.set] < ORDER[b.set]
		end
		if a.angle ~= b.angle then
			return a.angle < b.angle
		end
		return a.r < b.r
	end)
	for id, rod in rods do
		m.rodId[rod.r] = id
		m.rodPosition[id] = rod.r
	end

	-- Flow zones (§2.5)
	for r = 1, NR do
		if m.kind[r] == "fuel" then
			for zi, z in core.flow.zones do
				if m.ring[r] >= z.firstRing and m.ring[r] <= z.lastRing then
					m.flowZone[r] = zi
				end
			end
			assert(m.flowZone[r] ~= 0, `fuel position {r} (ring {m.ring[r]}) is in no flow zone`)
		end
	end

	-- Axial layers (§3.7 counts; heights from the §2.1 lengths)
	local ax = pm.axial
	local g = core.geometry
	local layerKind, dz, zb = {}, {}, {}
	local z = -g.lowerReflector_mm / 10
	for _ = 1, ax.lowerLayers do
		table.insert(layerKind, "lower")
		table.insert(dz, g.lowerReflector_mm / 10 / ax.lowerLayers)
	end
	for _ = 1, ax.fuelLayers do
		table.insert(layerKind, "fuel")
		table.insert(dz, ax.fuelLayerHeight_mm / 10)
	end
	for _ = 1, ax.upperLayers do
		table.insert(layerKind, "upper")
		table.insert(dz, g.upperPlenum_mm / 10 / ax.upperLayers)
	end
	local fuelLayers = {}
	for k, h in dz do
		zb[k] = z
		z += h
		if layerKind[k] == "fuel" then
			table.insert(fuelLayers, k)
		end
	end
	assert(math.abs(ax.fuelLayers * ax.fuelLayerHeight_mm - g.fissileHeight_mm) < 1e-9, "fuel layers must span the fissile height")
	m.NK = #dz
	m.N = NR * m.NK
	m.layerKind, m.dz_cm, m.zBottom_cm, m.fuelLayers = layerKind, dz, zb, fuelLayers

	-- Static material sets (rods start as sodium follower in the fuel region; RodModel mixes absorber in per tick)
	local names = pm.materialSets
	local id = {}
	for i, nm in names do
		id[nm] = i
	end
	m.materialSetNames, m.materialSetId = names, id
	local mat = table.create(m.N, 0)
	for k = 1, m.NK do
		local lk = layerKind[k]
		for r = 1, NR do
			local set
			if m.kind[r] == "reflector" then
				set = "steelReflector"
			elseif lk == "lower" then
				set = "lowerStructure"
			elseif lk == "upper" then
				set = "upperPlenum"
			elseif m.kind[r] == "fuel" then
				set = if m.fuelZone[r] == "inner" then "innerFuel" else "outerFuel"
			else
				set = "sodiumFollower"
			end
			mat[(k - 1) * NR + r] = assert(id[set], `material set '{set}' missing from PhysicsModel.materialSets`)
		end
	end
	m.matSet = mat

	-- Colour classes for SOR
	local classes = { {}, {}, {} }
	for k = 1, m.NK do
		for r = 1, NR do
			local c = (m.radialColour[r] + k) % 3
			table.insert(classes[c + 1], (k - 1) * NR + r)
		end
	end
	m.colourNodes = classes

	return m :: Mesh
end

--[[
	The plant mesh for a given (frozen) Config, built once and shared by every system that needs the geometry
	(Core, FuelThermal, the debug map). Callers must treat it as read-only.
]]
local cache: { [any]: Mesh } = setmetatable({}, { __mode = "k" }) :: any

function Mesh.get(config: any): Mesh
	local m = cache[config]
	if not m then
		m = Mesh.build(config)
		cache[config] = m
	end
	return m
end

-- Node helpers (plain functions; inner loops should inline the arithmetic instead)
function Mesh.node(m: Mesh, r: number, k: number): number
	return (k - 1) * m.NR + r
end

function Mesh.split(m: Mesh, node: number): (number, number)
	local k = (node - 1) // m.NR + 1
	return node - (k - 1) * m.NR, k
end

function Mesh.nodeColour(m: Mesh, node: number): number
	local r, k = Mesh.split(m, node)
	return (m.radialColour[r] + k) % 3
end

return table.freeze(Mesh)
