--!native
--!strict
--[[
	FuelThermal — fuel, cladding and sodium temperatures in every fuel assembly layer (spec §2.4, §2.5, §3.2, §14.3).
	===============================================================================================================

	Nodes: 301 fuel assemblies × 10 fuel layers (Mesh order: assemblies by radial index, layers bottom to top).
	Per node, one dynamic state and two algebraic ones:
	  T_f   volume-average pellet temperature (drives Doppler and axial expansion)
	        C_f(T_f)·dT_f/dt = q' − Q,   updated as T = T_eq + (T − T_eq)·e^(−dt/τ) (§14.3), with
	        T_eq = T_na + q'·R,  τ = C_f·R,  R = R_pellet(T_s, q') + R_gap + R_clad→Na
	  T_c   cladding midwall, quasi-static (D-019): T_c = T_na + Q·R_clad→Na
	  T_na  sodium, algebraic (§14.3): mean of the layer's inlet and outlet, with the heat balance solved exactly for
	        the heat flow Q = (T_f − T_na)/R and the layer outlet T_out = T_in + (Q·N_pin·dz + D)/(ṁ·c_p)
	D is the power deposited directly in fuel-assembly coolant and structure (Core.powerSplit: 97 % − 95 %).
	Pellet resistance, gap and cladding-to-sodium resistances come from tools/derive/pin_thermal.py (Config.FuelPin).

	Hot-pin figures (§2.4): the hottest pin in an assembly carries the §2.4 pin factor; its cladding midwall and
	centreline are evaluated per node from the same heat flow scaled by that factor, and the plant maxima are
	published.

	Inputs:  core.fuelPinPower_W   array per fuel node: power deposited in that node's pins (W)
	         primary.coreFlow_kgps total core flow; fuel assemblies get Core.flow.fractionFuel of it, split by zone factor
	         pools.coreInlet_K     core inlet temperature
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local Mesh = require(script.Parent.Core.Mesh)
local Pin = require(script.Pin)
local Sodium = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Props"):WaitForChild("Sodium"))

local FuelThermal = System.extend({
	name = "FuelThermal",
	lane = "fast",
	reads = { "core.fuelPinPower_W", "primary.coreFlow_kgps", "pools.coreInlet_K" },
	writes = {
		"fuel.average_K",
		"fuel.cladMidwall_K",
		"fuel.sodium_K",
		"fuel.assemblyOutlet_K",
		"fuel.coreAverage_K",
		"fuel.coreAverageSodium_K",
		"fuel.mixedOutlet_K",
		"fuel.heatToCoolant_W",
		"fuel.cladHotSpot_K",
		"fuel.hotPinCentre_K",
		"fuel.peakLinearHeat_Wpm",
	},
})

local MIN_FLOW_kgps = 1e-3 -- keeps the algebraic sodium balance defined if an assembly loses all flow

function FuelThermal.init(self: any, ctx: any)
	local cfg = ctx.config
	self.port = ctx.channels
	local mesh = Mesh.get(cfg)
	self.pin = Pin.new(cfg)
	local core = cfg.Core
	self.nPins = core.fuel.pinsPerAssembly
	self.dz = cfg.PhysicsModel.axial.fuelLayerHeight_mm / 1000
	self.directFraction = core.powerSplit.fuelAssemblyCoolant / core.powerSplit.fuelPins - 1
	self.pinFactor = core.limits.peaking.pin

	-- fuel assemblies in radial order, their zone and their share of the fuel-assembly flow
	local radial, outer, flowShare = {}, {}, {}
	local zones = core.flow.zones
	local weight = 0
	for r = 1, mesh.NR do
		if mesh.kind[r] == "fuel" then
			table.insert(radial, r)
			table.insert(outer, mesh.fuelZone[r] == "outer")
			local f = zones[mesh.flowZone[r]].flowFactor
			table.insert(flowShare, f)
			weight += f
		end
	end
	for a = 1, #flowShare do
		flowShare[a] = flowShare[a] / weight * core.flow.fractionFuel
	end
	self.NA = #radial
	self.L = #mesh.fuelLayers
	self.radial, self.outer, self.flowShare = radial, outer, flowShare
	self.fuelLayerOfMeshLayer = {}
	for l, k in mesh.fuelLayers do
		self.fuelLayerOfMeshLayer[k] = l
	end

	local N = self.NA * self.L
	self.N = N
	local T0 = cfg.Feedback.referenceTemperature_K
	self.Tf = table.create(N, T0)
	self.Tc = table.create(N, T0)
	self.Tna = table.create(N, T0)
	self.Ts = table.create(N, T0)
	self.Tout = table.create(self.NA, T0)
	self.port:write("fuel.average_K", self.Tf)
	self.port:write("fuel.cladMidwall_K", self.Tc)
	self.port:write("fuel.sodium_K", self.Tna)
	self.port:write("fuel.assemblyOutlet_K", self.Tout)
	self:publish(T0, T0, T0, 0, T0, T0, 0)
end

function FuelThermal.publish(self: any, coreAvg: number, naAvg: number, mixed: number, heat: number, hotClad: number, hotCentre: number, peakQ: number)
	local port = self.port
	port:write("fuel.coreAverage_K", coreAvg)
	port:write("fuel.coreAverageSodium_K", naAvg)
	port:write("fuel.mixedOutlet_K", mixed)
	port:write("fuel.heatToCoolant_W", heat)
	port:write("fuel.cladHotSpot_K", hotClad)
	port:write("fuel.hotPinCentre_K", hotCentre)
	port:write("fuel.peakLinearHeat_Wpm", peakQ)
	self.last = {
		coreAverage_K = coreAvg,
		coreAverageSodium_K = naAvg,
		mixedOutlet_K = mixed,
		heatToCoolant_W = heat,
		cladHotSpot_K = hotClad,
		hotPinCentre_K = hotCentre,
		peakLinearHeat_Wpm = peakQ,
	}
end

function FuelThermal.step(self: any, dt: number)
	local port = self.port
	local power = port:read("core.fuelPinPower_W")
	local coreFlow = port:read("primary.coreFlow_kgps")
	local inlet = port:read("pools.coreInlet_K")
	local p = self.pin
	local Tf, Tc, Tna, Ts, Tout = self.Tf, self.Tc, self.Tna, self.Ts, self.Tout
	local NA, L, nPins, dz = self.NA, self.L, self.nPins, self.dz
	local pinLength = nPins * dz
	local direct, pf = self.directFraction, self.pinFactor
	local rGap, rCna = p.rGap, p.rCladNa
	local outer, flowShare = self.outer, self.flowShare
	local sumTf, sumNa, sumOut, sumFlow, heat = 0, 0, 0, 0, 0
	local hotClad, hotCentre, peakQ = -math.huge, -math.huge, 0
	for a = 1, NA do
		local flow = math.max(coreFlow * flowShare[a], MIN_FLOW_kgps)
		local isOuter = outer[a]
		local Tin = inlet
		local base = (a - 1) * L
		for l = 1, L do
			local i = base + l
			local P = power[i]
			local q = P / pinLength
			local D = P * direct
			local R = Pin.pelletResistance(p, Ts[i], q) + rGap + rCna
			local mcp = flow * Sodium.specificHeat(Tna[i])
			local half = 0.5 / mcp
			-- heat flow per metre of pin, with the layer's own sodium rise solved together
			local Q = (Tf[i] - Tin - D * half) / (R + pinLength * half)
			local rise = Q * pinLength + D
			local na = Tin + rise * half
			Tna[i] = na
			Tc[i] = na + Q * rCna
			Ts[i] = na + Q * (rCna + rGap)
			-- fuel: exponential update toward the steady temperature for the current power and sodium (§14.3)
			local Teq = na + q * R
			local tau = Pin.capacity(p, isOuter, Tf[i]) * R
			local f = Tf[i]
			f = Teq + (f - Teq) * math.exp(-dt / tau)
			Tf[i] = f
			sumTf += f
			sumNa += na
			heat += rise
			Tin += 2 * rise * half
			-- hottest pin in this layer (§2.4 pin factor)
			local Qh = Q * pf
			local cladHot = na + Qh * rCna
			if cladHot > hotClad then
				hotClad = cladHot
			end
			local centre = Pin.centre(p, na + Qh * (rCna + rGap), q * pf)
			if centre > hotCentre then
				hotCentre = centre
			end
			if q * pf > peakQ then
				peakQ = q * pf
			end
		end
		Tout[a] = Tin
		sumOut += flow * Tin
		sumFlow += flow
	end
	local N = self.N
	self:publish(sumTf / N, sumNa / N, sumOut / sumFlow, heat, hotClad, hotCentre, peakQ)
end

--[[
	Relax to the steady state for the current inputs (initial conditions and tests). The exponential update is exact
	for a frozen T_eq, so a long step lands on it; repeats settle the temperature-dependent resistances and the sodium
	heat capacity. Stops once no fuel temperature moves by more than 1e-9 K, or after maxPasses (default 200).
	Returns the passes used and whether it converged.
]]
local SETTLE_TOLERANCE_K = 1e-9

function FuelThermal.settle(self: any, maxPasses: number?): (number, boolean)
	local Tf, N = self.Tf, self.N
	local before = table.create(N, 0)
	local limit = maxPasses or 200
	for pass = 1, limit do
		table.move(Tf, 1, N, 1, before)
		self:step(1e6)
		local worst = 0
		for i = 1, N do
			local d = math.abs(Tf[i] - before[i])
			if d > worst then
				worst = d
			end
		end
		if worst < SETTLE_TOLERANCE_K then
			return pass, true
		end
	end
	return limit, false
end

-- Fuel node index for a mesh node (radial index r, mesh layer k), or nil if it is not a fuel node
function FuelThermal.fuelNodeOf(self: any, r: number, k: number): number?
	local l = self.fuelLayerOfMeshLayer[k]
	if not l then
		return nil
	end
	local a = table.find(self.radial, r)
	if not a then
		return nil
	end
	return (a - 1) * self.L + l
end

-- §14.6 (D-053): the fuel's thermal state, which the saved decay heat has to land in, and what it last published
function FuelThermal.save(self: any): any
	return {
		Tf = table.clone(self.Tf),
		Tc = table.clone(self.Tc),
		Tna = table.clone(self.Tna),
		Ts = table.clone(self.Ts),
		Tout = table.clone(self.Tout),
		last = table.clone(self.last),
	}
end

function FuelThermal.load(self: any, data: any, _version: number)
	-- into the tables the channels already hold, and only a field whose size matches this mesh
	for _, name in { "Tf", "Tc", "Tna", "Ts", "Tout" } do
		local saved, into = data[name], self[name]
		if type(saved) == "table" and #saved == #into then
			table.move(saved, 1, #into, 1, into)
		end
	end
	local last = data.last
	if type(last) == "table" then
		local fields = { "coreAverage_K", "coreAverageSodium_K", "mixedOutlet_K", "heatToCoolant_W", "cladHotSpot_K",
			"hotPinCentre_K", "peakLinearHeat_Wpm" }
		for _, f in fields do
			if type(last[f]) ~= "number" then
				return
			end
		end
		self:publish(last.coreAverage_K, last.coreAverageSodium_K, last.mixedOutlet_K, last.heatToCoolant_W,
			last.cladHotSpot_K, last.hotPinCentre_K, last.peakLinearHeat_Wpm)
	end
end

function FuelThermal.getState(self: any): { [string]: any }
	return table.clone(self.last)
end

return FuelThermal
