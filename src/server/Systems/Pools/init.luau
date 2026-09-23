--!strict
--[[
	Pools — the primary sodium pools, their levels and the argon cover gas (spec §4.1, §4.4, §14.3).
	=================================================================================================

	The 1,250 t of primary sodium is modelled as four well-mixed nodes in a loop, in the order the sodium travels:

	  core outlet → hot pool (40 s, 18 s) → IHX → transport (8 s) → cold pool (52 s) → pumps → core inlet

	§4.1's mixing times are residence times: 620 t / 10,694 kg/s = 58.0 s and 560 t / 10,694 kg/s = 52.4 s, which is
	where the spec's 58 s and 52 s come from (tools/derive/pool_gas.py). That identity is the reason every time
	constant here scales as 1/flow: at the 3.5 % natural-circulation floor the hot pool's 58 s becomes 28 minutes.
	The two hot-pool nodes split the 620 t in proportion to their time constants, which is the same statement —
	40 s and 18 s of rated flow are 428 t and 192 t.

	Each node is the §14.3 exponential update toward its inflow temperature, which for τ = m/ṁ is exactly the energy
	balance ṁ·c_p·(T_in − T) = m·c_p·dT/dt. Nothing is added to a node's stored energy except through its inflow, so
	the loop conserves energy by construction:

	  mixed core outlet   the fuel-assembly outlet (92.5 % of flow) mixed with the bypass streams — rods, reflector,
	                      shield, storage and diagrid leakage — which carry the 3 % of power that does not reach
	                      fuel-assembly coolant (Core.powerSplit). At 100 % this turns §2.5's 559 °C fuel-assembly
	                      average into §2.4's 550 °C mixed core outlet
	  IHX                 ihx.heatRemoved_W is subtracted from the hot pool outflow. Until the IHX system exists that
	                      channel is an external input, and with no heat removed the pools simply heat up
	  pumps               primary.pumpHeat_MWt is added to the flow at the pumps, so the core inlet sits ≈ 0.7 K above
	                      the IHX outlet at rated — both are quoted as 375 °C in §4.1/§4.3, which rounds that away

	The loop's thermal inventory is the two pools (1,180 t) plus the 8 s of sodium in transit between the IHX
	outlets and the pump inlets (86 t at rated flow), so 1,266 t against §4.1's 1,250 t — see D-021, which is where
	the 70 t of core and diagrid sodium went.

	Vessel heat loss is not modelled: the spec gives no figure for it, and inventing one would be a guess. The IHX
	closes the balance instead — 10 MW of pump heat raises the hot pool until the IHX ΔT grows enough to carry it,
	which at 57.6 MW/K of UA is a fraction of a kelvin. The 2,400 MJ/K "with internals" of §4.1 belongs to the DRACS
	and station-blackout coping calculation (§4.5), not to the mixing model, and is deliberately not used here.

	Levels (§4.1) are the sodium's own thermal expansion, from the Appendix A density correlation: the mean level is
	the volume change over the 140 m² of free surface, measured from the 375 °C isothermal datum the spec quotes its
	rises from. Flow tilts the two pools apart by ΔL = 1.5 m × (Q/Q₀)², hot +0.32ΔL and cold −0.68ΔL; those shares
	conserve volume across the two surfaces (0.32 × 95 m² ≈ 0.68 × 45 m²), so the tilt never moves the cover gas.

	Cover gas (§4.4): argon as an ideal gas in the space the sodium vacates, at a temperature interpolated between the
	two states the spec's own calculation gives (180 °C gas at the 230 °C isothermal pool, 300 °C at full power).
	Outside the 0.115–0.125 MPa band the make-up and vent valves drive the inventory back to the 0.120 MPa setpoint as
	a first-order lag (D-020). Alarms and the 0.160 MPa trip are Protection's to declare; this system publishes the
	measurement, and the pumps' own start interlocks read it.

	Inputs:  fuel.mixedOutlet_K      flow-weighted fuel-assembly outlet
	         fuel.heatToCoolant_W    heat into fuel-assembly coolant (97 % of core power)
	         primary.coreFlow_kgps   total primary flow
	         primary.pumpHeat_MWt    pump shaft power into the sodium
	         ihx.heatRemoved_W       primary-side IHX duty (external until the IHX system exists)
	All five are lagged reads: FuelThermal and PrimaryPumps read this system's outputs in the same tick, and one fast
	tick of lag against time constants of 52 s and more is immaterial.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Sodium = require(Kallskar:WaitForChild("Props"):WaitForChild("Sodium"))
local Types = require(Kallskar:WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local Pools = System.extend({
	name = "Pools",
	lane = "fast",
	reads = {},
	readsLagged = {
		"fuel.mixedOutlet_K",
		"fuel.heatToCoolant_W",
		"primary.coreFlow_kgps",
		"primary.pumpHeat_MWt",
		"ihx.heatRemoved_W",
	},
	writes = {
		"pools.coreInlet_K",
		"pools.hotPool_K",
		"pools.coldPool_K",
		"pools.mixedCoreOutlet_K",
		"pools.mixedCoreOutletMeasured_K",
		"pools.ihxOutlet_K",
		"pools.coverGas_MPa",
		"pools.coverGasVolume_m3",
		"pools.hotLevel_m",
		"pools.coldLevel_m",
		"pools.meanLevel_m",
	},
})

local MIN_FLOW_kgps = 1e-3 -- keeps the residence times finite if every pump stops and natural circulation is off
-- The make-up and vent valves latch shut once the error falls under this fraction of the band half-width. At 5 kPa
-- that is 0.1 kPa, finer than any real pressure transmitter, and it stops the valves chattering at the band edge.
local RESEAT_FRACTION = 0.02

--[[
	Temperature after adding heat Q (W) to a stream of `flow` kg/s starting at T. c_p is taken at the midpoint of the
	rise, which the repeated passes converge: c_p moves by under 2 % across the 175 K core rise, so two passes are
	exact to better than a millikelvin.
]]
local function afterHeat(T: number, flow: number, Q: number): number
	local out = T + Q / (flow * Sodium.specificHeat(T))
	for _ = 1, 2 do
		out = T + Q / (flow * Sodium.specificHeat(0.5 * (T + out)))
	end
	return out
end

-- Pool volumes at their own temperatures; the core and diagrid sit at the mean of the two (file 20 uses 460 °C).
function Pools.sodiumVolume(self: any, hotMean: number, cold: number): number
	return self.mHot / Sodium.density(hotMean)
		+ self.mCold / Sodium.density(cold)
		+ self.mCore / Sodium.density(0.5 * (hotMean + cold))
end

function Pools.gasVolume(self: any, hotMean: number, cold: number): number
	return self.gasRefVolume + (self.naRefVolume - self:sodiumVolume(hotMean, cold))
end

function Pools.gasTemperature(self: any, hotMean: number): number
	local f = (hotMean - self.gasPoolLow) / (self.gasPoolHigh - self.gasPoolLow)
	local T = self.gasTempLow + f * (self.gasTempHigh - self.gasTempLow)
	-- the gas cannot be hotter than the sodium surface heating it; below the cold point the line simply continues
	return math.min(T, hotMean)
end

function Pools.hotMean(self: any): number
	local m1, m2 = self.hotMass[1], self.hotMass[2]
	return (m1 * self.hot[1] + m2 * self.hot[2]) / (m1 + m2)
end

function Pools.init(self: any, ctx: any)
	local cfg = ctx.config
	local primary = cfg.Primary
	local pools, sodium, gas = primary.pools, primary.sodium, primary.coverGas
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.cfg = pools
	self.gasCfg = gas
	self.kelvin = cfg.Units.kelvinOffset_K
	self.R = cfg.Units.molarGasConstant_JpmolK

	self.ratedFlow = primary.pumps.ratedFlowTotal_kgps
	self.fuelFraction = cfg.Core.flow.fractionFuel
	-- Heat that misses fuel-assembly coolant heats the bypass streams. Per watt of fuel.heatToCoolant_W, which is
	-- the 97 % share, that is (1 − 0.97) / 0.97.
	local coolantShare = cfg.Core.powerSplit.fuelAssemblyCoolant
	self.bypassHeatRatio = (1 - coolantShare) / coolantShare

	-- masses: the hot pool splits by time constant, because τ_i = m_i / ṁ (tools/derive/pool_gas.py)
	local taus = pools.hotPoolNodes_s
	local tauSum = 0
	for _, t in taus do
		tauSum += t
	end
	self.hotTau = { taus[1], taus[2] }
	self.mHot = sodium.hotPool_t * 1e3
	self.mCold = sodium.coldPool_t * 1e3
	self.mCore = sodium.coreAndDiagrid_t * 1e3
	self.mTotal = sodium.total_t * 1e3
	self.hotMass = { self.mHot * taus[1] / tauSum, self.mHot * taus[2] / tauSum }
	self.coldTau = pools.coldPoolMixing_s
	self.transport = pools.ihxOutletToPumpInletTransport_s
	self.areaTotal = pools.hotPoolFreeSurface_m2 + pools.coldPoolFreeSurface_m2

	-- Reference states: the gas space is 320 m³ at the 100 % condition, and levels are measured from the 375 °C
	-- isothermal datum §4.1 quotes its rises from.
	local hotRef = cfg.Core.limits.mixedCoreOutlet_C + self.kelvin
	local coldRef = primary.ihx.primaryOutlet_C + self.kelvin
	self.naRefVolume = self:sodiumVolume(hotRef, coldRef)
	self.gasRefVolume = gas.volumeAt100_m3
	self.datumVolume = self.mTotal / Sodium.density(coldRef)
	-- gas temperature: linear in the hot pool between the spec's own two states (file 20)
	self.gasPoolLow = gas.volumeSwingFrom_C + self.kelvin
	self.gasPoolHigh = hotRef
	self.gasTempLow = primary.coverGasTemperature_C.cold + self.kelvin
	self.gasTempHigh = primary.coverGasTemperature_C.atPower + self.kelvin

	-- transport delay ring buffer, sampled at the fast tick
	self.dtNominal = 1 / cfg.Clocks.fast_Hz
	self.bufferN = math.ceil(primary.poolTransportTracked_s / self.dtNominal) + 2
	self.buffer = table.create(self.bufferN, 0)
	self.head = 0

	-- Boot state: hot zero power with the pumps running — isothermal at the §3.2 reference temperature, which is
	-- what FuelThermal starts from, and a cover gas the controller has already brought to its setpoint.
	local T0 = cfg.Feedback.referenceTemperature_K
	self.hot = { T0, T0 }
	self.cold = T0
	self.coreInlet = T0
	self.ihxOutlet = T0
	self.mixedOutlet = T0
	self.flowFraction = 1
	for i = 1, self.bufferN do
		self.buffer[i] = T0
	end
	--[[
		The mixed core outlet thermocouple. §2.5 gives the assembly outlet instruments ±1 K of noise and a 3 s
		lag; this is the same class of thermocouple in the hot pool, so it carries the same characteristics.
		Nothing outside this system should read the sodium temperature directly — Protection trips on the
		instrument, and §9.4's rod auto is deliberately limited by it ("reacts after thermocouples move").
	]]
	self.tcLag_s = cfg.Core.flow.thermocoupleLag_s
	self.tcNoise_K = cfg.Core.flow.thermocoupleNoise_K
	self.tcRng = Random.new(20005)
	self.measuredOutlet_K = T0

	self.gas_mol = gas.setpoint_MPa * 1e6 * self:gasVolume(T0, T0) / (self.R * self:gasTemperature(T0))
	self.controlTau = primary.coverGasControl.correctionTau_s
	-- The valves' authority follows from the band and τ (D-020): full open moves this many mol/s.
	self.valveRate_molps = (gas.setpoint_MPa - gas.autoBand_MPa[1]) * 1e6 * self.gasRefVolume
		/ (self.R * self.gasTempHigh * self.controlTau)
	self.auto = true
	self.correcting = false
	self.valve = 0 -- manual demand, −1 full vent … +1 full make-up
	self.leak_molps = 0
	self.makeup_molps = 0
	self.admitted_mol = 0
	self.vented_mol = 0
	self:publish()
end

-- Push one sample and read the value `delay` seconds old, interpolating between the two samples either side.
function Pools.transportStep(self: any, value: number, delay: number, dt: number): number
	local n = self.bufferN
	self.head = self.head % n + 1
	self.buffer[self.head] = value
	local steps = math.clamp(delay / dt, 0, n - 2)
	local whole = math.floor(steps)
	local frac = steps - whole
	local near = (self.head - whole - 1) % n + 1
	local far = (near - 2) % n + 1
	return self.buffer[near] * (1 - frac) + self.buffer[far] * frac
end

function Pools.controlGas(self: any, dt: number, vGas: number, tGas: number)
	local gas = self.gasCfg
	if self.leak_molps > 0 then
		self.gas_mol = math.max(self.gas_mol - self.leak_molps * dt, 0)
	end
	local pressure = self.gas_mol * self.R * tGas / vGas
	local demand = 0
	if self.auto then
		local band = gas.autoBand_MPa
		local setpoint = gas.setpoint_MPa * 1e6
		local reseat = RESEAT_FRACTION * (setpoint - band[1] * 1e6)
		-- The valves open when pressure leaves the band and stay open until it is back at the setpoint, rather than
		-- shutting the moment it re-enters and parking the plant on the band edge (D-020).
		if pressure < band[1] * 1e6 or pressure > band[2] * 1e6 then
			self.correcting = true
		elseif math.abs(pressure - setpoint) <= reseat then
			self.correcting = false
		end
		if self.correcting then
			-- first-order back to the inventory that gives the setpoint at this volume and temperature (D-020)
			local target = setpoint * vGas / (self.R * tGas)
			demand = (target - self.gas_mol) * (1 - math.exp(-dt / self.controlTau)) / dt
		end
	else
		demand = self.valve * self.valveRate_molps
	end
	demand = math.clamp(demand, -self.valveRate_molps, self.valveRate_molps)
	local moved = demand * dt
	self.gas_mol += moved
	if moved > 0 then
		self.admitted_mol += moved
	else
		self.vented_mol -= moved
	end
	self.makeup_molps = demand
end

function Pools.publish(self: any)
	local port = self.port
	local hotMean = self:hotMean()
	local vGas = self:gasVolume(hotMean, self.cold)
	local tGas = self:gasTemperature(hotMean)
	self.pressure_MPa = self.gas_mol * self.R * tGas / vGas / 1e6
	self.gasVolume_m3 = vGas
	local meanLevel = (self:sodiumVolume(hotMean, self.cold) - self.datumVolume) / self.areaTotal
	local tilt = self.cfg.headDifferenceAtRated_m * self.flowFraction ^ 2
	self.meanLevel_m = meanLevel
	self.hotLevel_m = meanLevel + self.cfg.hotShare * tilt
	self.coldLevel_m = meanLevel - self.cfg.coldShare * tilt
	port:write("pools.coreInlet_K", self.coreInlet)
	port:write("pools.hotPool_K", self.hot[2])
	port:write("pools.coldPool_K", self.cold)
	port:write("pools.mixedCoreOutlet_K", self.mixedOutlet)
	port:write("pools.mixedCoreOutletMeasured_K", self.reading_K or self.mixedOutlet)
	port:write("pools.ihxOutlet_K", self.ihxOutlet)
	port:write("pools.coverGas_MPa", self.pressure_MPa)
	port:write("pools.coverGasVolume_m3", vGas)
	port:write("pools.hotLevel_m", self.hotLevel_m)
	port:write("pools.coldLevel_m", self.coldLevel_m)
	port:write("pools.meanLevel_m", meanLevel)
end

-- The mixed core outlet: fuel-assembly sodium and the bypass streams, which carry the heat the fuel coolant does not
function Pools.mixOutlet(self: any, flow: number, fuelOutlet: number, coolantHeat: number): number
	local fuelFlow = flow * self.fuelFraction
	local bypassFlow = flow - fuelFlow
	local bypassOutlet = afterHeat(self.coreInlet, bypassFlow, coolantHeat * self.bypassHeatRatio)
	local cpFuel = Sodium.specificHeat(0.5 * (self.coreInlet + fuelOutlet))
	local cpBypass = Sodium.specificHeat(0.5 * (self.coreInlet + bypassOutlet))
	local wf, wb = fuelFlow * cpFuel, bypassFlow * cpBypass
	return (wf * fuelOutlet + wb * bypassOutlet) / (wf + wb)
end

--[[
	Seat the pools in steady state around a core inlet temperature, for the flow, core heat and pump heat now on
	the channels (plan: initial conditions). A well-mixed node in steady state sits at whatever flows into it, so
	the hot pool is the mixed core outlet, the cold pool and the whole transport line hold IHX outlet sodium, and
	the IHX outlet is the temperature the pumps then heat to the inlet — found by inverting the same afterHeat the
	step uses. The cover gas is put back on its setpoint in the gas space the new temperatures leave, and the
	thermocouple starts on the sodium it measures.

	Call it once before FuelThermal settles, so the fuel sees the inlet, and once after, so the hot pool mixes the
	settled fuel outlet.
]]
function Pools.seat(self: any, inlet_K: number)
	local port = self.port
	local flow = math.max(port:read("primary.coreFlow_kgps") or 0, MIN_FLOW_kgps)
	local pumpHeat = (port:read("primary.pumpHeat_MWt") or 0) * 1e6
	self.flowFraction = flow / self.ratedFlow
	self.coreInlet = inlet_K
	local cold = inlet_K
	for _ = 1, 4 do
		cold = inlet_K - (afterHeat(cold, flow, pumpHeat) - cold)
	end
	self.cold = cold
	self.ihxOutlet = cold
	for i = 1, self.bufferN do
		self.buffer[i] = cold
	end
	local mixed = self:mixOutlet(flow, port:read("fuel.mixedOutlet_K") or inlet_K, port:read("fuel.heatToCoolant_W") or 0)
	self.hot[1], self.hot[2] = mixed, mixed
	self.mixedOutlet = mixed
	self.measuredOutlet_K = mixed
	self.reading_K = mixed
	local hotMean = self:hotMean()
	self.gas_mol = self.gasCfg.setpoint_MPa * 1e6 * self:gasVolume(hotMean, cold) / (self.R * self:gasTemperature(hotMean))
	self.correcting = false
	self:publish()
end

function Pools.step(self: any, dt: number)
	local port = self.port
	local flow = math.max(port:read("primary.coreFlow_kgps") or 0, MIN_FLOW_kgps)
	local fuelOutlet = port:read("fuel.mixedOutlet_K") or self.hot[1]
	local coolantHeat = port:read("fuel.heatToCoolant_W") or 0
	local pumpHeat = (port:read("primary.pumpHeat_MWt") or 0) * 1e6
	local ihxHeat = port:read("ihx.heatRemoved_W") or 0
	self.flowFraction = flow / self.ratedFlow
	local scale = self.ratedFlow / flow -- residence times grow as flow falls

	-- 1. mix the fuel-assembly outlet with the bypass streams (§2.5 flow zoning, Core.powerSplit)
	local mixed = self:mixOutlet(flow, fuelOutlet, coolantHeat)
	self.mixedOutlet = mixed

	-- 2. hot pool: two mixing nodes in series (§4.1, §14.3). Node 2 sees node 1's updated temperature, which is what
	--    a well-mixed node discharges.
	local hot = self.hot
	hot[1] = mixed + (hot[1] - mixed) * math.exp(-dt / (self.hotTau[1] * scale))
	hot[2] = hot[1] + (hot[2] - hot[1]) * math.exp(-dt / (self.hotTau[2] * scale))

	-- 3. the IHX takes its duty out of the flow leaving the hot pool
	self.ihxOutlet = afterHeat(hot[2], flow, -ihxHeat)

	-- 4. transport from the IHX outlets to the pump inlets, then the cold pool's own mixing (§4.1). A delay and a
	--    lag in series commute, so which of the two comes first does not change the response.
	local arriving = self:transportStep(self.ihxOutlet, self.transport * scale, dt)
	self.cold = arriving + (self.cold - arriving) * math.exp(-dt / (self.coldTau * scale))

	-- 5. the pumps add their shaft power to the flow on its way to the diagrid (§4.2)
	self.coreInlet = afterHeat(self.cold, flow, pumpHeat)

	-- 6. the thermocouple follows the sodium, late and imprecisely (§2.5)
	local drift = 1 - math.exp(-dt / self.tcLag_s)
	self.measuredOutlet_K += (mixed - self.measuredOutlet_K) * drift
	self.reading_K = self.measuredOutlet_K + self.tcNoise_K * (self.tcRng:NextNumber() * 2 - 1)

	-- 7. cover gas: the space the sodium vacated, and the make-up/vent controller (§4.4, D-020)
	local hotMean = self:hotMean()
	self:controlGas(dt, self:gasVolume(hotMean, self.cold), self:gasTemperature(hotMean))
	self:publish()
end

Pools.commands = {
	["covergas.auto"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local on = cmd.value ~= 0
		self.auto = on
		-- either way the manual demand is dropped: coming back to auto must not leave a valve wide open, waiting
		-- for the next switch to manual to reopen it
		self.valve = 0
		if self.log then
			self.log:record("covergas.auto", actor, "cover gas", if on then "auto" else "manual", "set")
		end
		return { ok = true }
	end,

	["covergas.valve"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local value = cmd.value
		if type(value) ~= "number" or value ~= value then
			return { ok = false, reason = "valve demand must be a number" }
		end
		if self.auto then
			return { ok = false, reason = "cover gas control is in auto; switch it to manual first" }
		end
		if value < -1 or value > 1 then
			return { ok = false, reason = "valve demand runs from −1 (vent) to +1 (make-up)" }
		end
		self.valve = value
		return { ok = true }
	end,
}

Pools.faults = {
	{
		id = "CG-LEAK",
		label = "Cover gas leak",
		cost = 3,
		eligible = function(_snapshot: any)
			return true
		end,
		--[[
			Argon escapes past the roof penetrations. The default rate is the make-up valves' full authority, so auto
			control just holds the setpoint while the operator sees a standing make-up flow; anything above it walks
			the pressure down toward the 0.108 MPa cavitation limit and the 0.105 MPa pump start interlock (§4.2).
		]]
		arm = function(self: any, params: { [string]: any }?)
			local rate = params and params.rate_molps
			self.leak_molps = if type(rate) == "number" and rate > 0 then rate else self.valveRate_molps
		end,
		clear = function(self: any)
			self.leak_molps = 0
		end,
	},
}

function Pools.getState(self: any): { [string]: any }
	return {
		hotPool_K = self.hot[2],
		hotPoolFirstNode_K = self.hot[1],
		coldPool_K = self.cold,
		coreInlet_K = self.coreInlet,
		mixedCoreOutlet_K = self.mixedOutlet,
		ihxOutlet_K = self.ihxOutlet,
		coverGas_MPa = self.pressure_MPa,
		coverGasVolume_m3 = self.gasVolume_m3,
		coverGas_mol = self.gas_mol,
		makeup_molps = self.makeup_molps,
		auto = self.auto,
		correcting = self.correcting,
		valve = self.valve,
		admitted_mol = self.admitted_mol,
		vented_mol = self.vented_mol,
		meanLevel_m = self.meanLevel_m,
		hotLevel_m = self.hotLevel_m,
		coldLevel_m = self.coldLevel_m,
	}
end

return Pools
