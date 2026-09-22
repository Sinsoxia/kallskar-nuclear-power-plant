--!strict
--[[
	Pools verification (spec §4.1, §4.4, §2.4, §2.5).

	The expected values are the spec's own: §2.4's 550 °C mixed core outlet out of §2.5's 559 °C fuel-assembly
	average, §2.5's 183.7 K core rise, §4.1's 58 s and 52 s mixing times and 8 s transport delay, the ΔL = 1.5 m tilt
	with its 0.32/0.68 shares, and §4.4's 90 m³ gas swing and 0.074 MPa fixed-inventory cooldown. The level rises are
	checked with the wider tolerance F31 explains: §4.1's 0.26 m and 0.64 m were computed at the pre-Rev-A4 545 °C
	hot pool, and the same calculation at Rev A4's 550 °C gives 0.266 m and 0.645 m.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Config = require(Kallskar:WaitForChild("Config")) :: any
local Sodium = require(Kallskar:WaitForChild("Props"):WaitForChild("Sodium")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local Bus = require(Framework:WaitForChild("Bus")) :: any
local Pools = require(Root:WaitForChild("Systems"):WaitForChild("Pools")) :: any

local PRIMARY = Config.Primary
local POOL = PRIMARY.pools
local GAS = PRIMARY.coverGas
local LIMITS = Config.Core.limits
local KEL = Config.Units.kelvinOffset_K
local RATED = PRIMARY.pumps.ratedFlowTotal_kgps
local DT = 1 / Config.Clocks.fast_Hz
local T0 = Config.Feedback.referenceTemperature_K -- 648 K, hot zero power isothermal
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

local function make(opts: { [string]: any }?)
	local o = opts or {}
	local ch = Channels.new()
	ch:declareExternal("fuel.mixedOutlet_K", o.fuelOutlet or T0)
	ch:declareExternal("fuel.heatToCoolant_W", o.coolantHeat or 0)
	ch:declareExternal("primary.coreFlow_kgps", o.flow or RATED)
	ch:declareExternal("primary.pumpHeat_MWt", o.pumpHeat or 0)
	ch:declareExternal("ihx.heatRemoved_W", o.ihx or 0)
	local sys = System.new(Pools)
	sys:init({
		config = Config,
		channels = ch:port(Pools.spec),
		log = EventLog.new(Config, { sim = 0, grid = 0 }),
		bus = Bus.new(),
	})
	return sys, ch
end

local function run(sys: any, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
	end
end

-- Put the pools at a stated pair of temperatures. The transient path is exercised by the tests above this one; the
-- cover gas and level tests care only about where the sodium ends up.
local function setPools(sys: any, hot_C: number, cold_C: number)
	sys.hot[1], sys.hot[2] = hot_C + KEL, hot_C + KEL
	sys.cold = cold_C + KEL
	sys:publish()
end

-- The inventory the make-up controller would be holding at the current state.
local function reseat(sys: any)
	local hotMean = sys:hotMean()
	sys.gas_mol = GAS.setpoint_MPa * 1e6 * sys:gasVolume(hotMean, sys.cold)
		/ (sys.R * sys:gasTemperature(hotMean))
	sys:publish()
end

return {
	["boots at hot zero power with the cover gas on its setpoint"] = function(t)
		local sys, ch = make()
		local s = sys:getState()
		t.near(s.hotPool_K, T0, 1e-12, "hot pool")
		t.near(s.coldPool_K, T0, 1e-12, "cold pool")
		t.near(s.coreInlet_K, T0, 1e-12, "core inlet")
		t.near(ch:get("pools.coverGas_MPa"), GAS.setpoint_MPa, 1e-12, "cover gas at the §4.4 setpoint")
		-- the level datum is the 375 °C isothermal state, which is this state to within 0.15 K
		t.near(s.meanLevel_m, 0, 1e-3, "mean level sits on the §4.1 datum")
		-- §4.1: ΔL = 1.5 m at rated flow, hot +0.32ΔL and cold −0.68ΔL
		t.near(s.hotLevel_m - s.coldLevel_m, POOL.headDifferenceAtRated_m, 1e-9, "tilt at rated flow")
		t.near(s.hotLevel_m, POOL.hotShare * POOL.headDifferenceAtRated_m, 1e-3, "hot pool above the mean")
	end,

	["§4.1's mixing times are the pools' own residence times"] = function(t)
		local sodium = PRIMARY.sodium
		t.near(sodium.hotPool_t * 1e3 / RATED, POOL.hotPoolMixing_s, 0.5, "620 t / 10,694 kg/s = 58 s")
		t.near(sodium.coldPool_t * 1e3 / RATED, POOL.coldPoolMixing_s, 0.5, "560 t / 10,694 kg/s = 52 s")
		local sys = make()
		local m1, m2 = sys.hotMass[1], sys.hotMass[2]
		t.near((m1 + m2) / 1e3, sodium.hotPool_t, 1e-9, "the two nodes hold the whole hot pool")
		t.near(m1 / RATED, POOL.hotPoolNodes_s[1], 0.05, "node 1 is 40 s of rated flow")
		t.near(m2 / RATED, POOL.hotPoolNodes_s[2], 0.05, "node 2 is 18 s of rated flow")
	end,

	["full power settles on §2.4's 550 °C mixed outlet and §2.5's 375 °C inlet"] = function(t)
		local power = Config.Units.ratedThermal_MWt * 1e6
		local sys, ch = make({
			fuelOutlet = LIMITS.assemblyOutletAverage_C + KEL, -- §2.5: 559 °C fuel-assembly average
			coolantHeat = Config.Core.powerSplit.fuelAssemblyCoolant * power,
			pumpHeat = PRIMARY.pumps.pumpHeatToSodium_MWt,
			ihx = power + PRIMARY.pumps.pumpHeatToSodium_MWt * 1e6, -- the IHX carries core plus pump heat
		})
		run(sys, 3000)
		local s = sys:getState()
		t.near(s.mixedCoreOutlet_K - KEL, LIMITS.mixedCoreOutlet_C, 1, "§2.4 mixed core outlet")
		t.near(s.hotPool_K - KEL, LIMITS.mixedCoreOutlet_C, 1, "hot pool follows the mixed outlet")
		t.near(s.coreInlet_K - KEL, PRIMARY.ihx.primaryOutlet_C, 1, "§2.5 core inlet")
		t.near(LIMITS.assemblyOutletAverage_C - (s.coreInlet_K - KEL), Config.Core.flow.outletRise_K, 1,
			"§2.5's 183.7 K fuel-assembly rise")
		-- the bypass streams carry 3 % of the power in 7.5 % of the flow, which is what pulls 559 °C down to 550
		t.ok(s.mixedCoreOutlet_K < LIMITS.assemblyOutletAverage_C + KEL, "mixing cools the fuel-assembly average")
		t.near(ch:get("pools.coldPool_K"), s.coldPool_K, 1e-12, "published cold pool matches state")
	end,

	["the hot pool's first node is 40 s of flow, and that scales as 1/flow"] = function(t)
		-- Over the first 10 s the returning sodium has not come round yet (8 s of transport plus a 52 s lag), so
		-- node 1 sees a clean step in the mixed core outlet.
		local sys = make({ fuelOutlet = T0 + 10 })
		run(sys, 10)
		local s = sys:getState()
		local fraction = (s.hotPoolFirstNode_K - T0) / (s.mixedCoreOutlet_K - T0)
		t.near(fraction, 1 - math.exp(-10 / POOL.hotPoolNodes_s[1]), 1e-3, "40 s node at rated flow")

		local half = make({ fuelOutlet = T0 + 10, flow = RATED / 2 })
		run(half, 10)
		local h = half:getState()
		local halfFraction = (h.hotPoolFirstNode_K - T0) / (h.mixedCoreOutlet_K - T0)
		t.near(halfFraction, 1 - math.exp(-10 / (2 * POOL.hotPoolNodes_s[1])), 1e-3, "80 s node at half flow")
	end,

	["the cold pool sees nothing for the §4.1 transport delay"] = function(t)
		local sys = make({ fuelOutlet = T0 + 50 })
		run(sys, POOL.ihxOutletToPumpInletTransport_s - 0.1)
		t.near(sys:getState().coldPool_K, T0, 1e-12, "still untouched just before 8 s")
		run(sys, 0.1)
		t.near(sys:getState().coldPool_K, T0, 1e-12, "and at exactly 8 s")
		run(sys, 0.2)
		t.ok(sys:getState().coldPool_K > T0, "moving once the sodium has travelled")

		local slow = make({ fuelOutlet = T0 + 50, flow = RATED / 2 })
		run(slow, 2 * POOL.ihxOutletToPumpInletTransport_s - 0.2)
		t.near(slow:getState().coldPool_K, T0, 1e-12, "half flow doubles the transport to 16 s")
		run(slow, 0.4)
		t.ok(slow:getState().coldPool_K > T0, "and it arrives after that")
	end,

	["pump heat lifts the core inlet above the IHX outlet (§4.2)"] = function(t)
		local sys = make({ pumpHeat = PRIMARY.pumps.pumpHeatToSodium_MWt })
		sys:step(DT)
		local s = sys:getState()
		local expected = PRIMARY.pumps.pumpHeatToSodium_MWt * 1e6 / (RATED * Sodium.specificHeat(T0))
		t.near(s.coreInlet_K - s.coldPool_K, expected, 1e-3, "10 MWt over the rated flow is ≈ 0.7 K")
		t.ok(expected < 1, "which is inside the rounding of §4.1's and §4.3's 375 °C")
	end,

	["energy is conserved, counting the sodium in the transport line"] = function(t)
		-- The fuel assemblies are adiabatic here (their outlet follows the inlet), so the pumps are the only source.
		local sys, ch = make({ pumpHeat = PRIMARY.pumps.pumpHeatToSodium_MWt })
		local function meanTemp(): number
			return (PRIMARY.sodium.hotPool_t * sys:hotMean() + PRIMARY.sodium.coldPool_t * sys.cold)
				/ (PRIMARY.sodium.hotPool_t + PRIMARY.sodium.coldPool_t)
		end
		local function advance(seconds: number)
			for _ = 1, math.floor(seconds / DT + 0.5) do
				ch:setExternal("fuel.mixedOutlet_K", ch:get("pools.coreInlet_K"))
				sys:step(DT)
			end
		end
		advance(200) -- past the transport line's own start-up
		local before = meanTemp()
		advance(100)
		local rate = (meanTemp() - before) / 100
		-- The model is parameterised by time constants, not masses, so its inventory is the sum of them times the
		-- flow: the two pools (40 + 18 + 52 s) plus the transport line (8 s), or 118 s of rated flow (D-021).
		local residence = POOL.hotPoolNodes_s[1] + POOL.hotPoolNodes_s[2] + POOL.coldPoolMixing_s
			+ POOL.ihxOutletToPumpInletTransport_s
		local mass = residence * RATED
		local expected = PRIMARY.pumps.pumpHeatToSodium_MWt * 1e6 / (mass * Sodium.specificHeat(before))
		t.log(string.format("10 MWt into %.0f t (%.0f s of rated flow) warms the loop at %.4f mK/s (expected %.4f)",
			mass / 1e3, residence, rate * 1e3, expected * 1e3))
		-- the 0.3 % band is c_p: the model takes it at one temperature per stream, not per node
		t.near(rate, expected, expected * 3e-3, "Q/(m·c_p) over the pools plus the transport line")
		-- §4.1 puts 70 t in the core and diagrid, which no node carries (D-021); the transport line stands in for it
		t.near(mass / 1e3, PRIMARY.sodium.total_t, 20, "within 20 t of §4.1's 1,250 t inventory")
	end,

	["cover gas: the §4.4 90 m³ swing and the 0.074 MPa fixed-inventory cooldown"] = function(t)
		local sys = make()
		setPools(sys, LIMITS.mixedCoreOutlet_C, PRIMARY.ihx.primaryOutlet_C)
		reseat(sys)
		local hot = sys:getState()
		t.near(hot.coverGasVolume_m3, GAS.volumeAt100_m3, 1e-9, "§4.4's 320 m³ at 100 %")
		t.near(hot.coverGas_MPa, GAS.setpoint_MPa, 1e-12, "held on the setpoint")
		local molesAt100 = sys.gas_mol

		-- cool the whole plant to the 230 °C isothermal state without touching the argon inventory
		sys.auto = false
		setPools(sys, GAS.volumeSwingFrom_C, GAS.volumeSwingFrom_C)
		local cold = sys:getState()
		t.near(sys.gas_mol, molesAt100, 1e-9, "inventory unchanged")
		t.near(cold.coverGasVolume_m3 - hot.coverGasVolume_m3, GAS.volumeSwing230To100_m3, 1,
			"§4.4: ≈ 90 m³ between 230 °C and full power")
		t.near(cold.coverGas_MPa, GAS.fixedInventoryCooldown_MPa, 1e-3,
			"§4.4: a fixed inventory falls to ≈ 0.074 MPa")
		t.ok(cold.coverGas_MPa < GAS.neverBelow_MPa, "which is why argon has to be admitted on a cooldown")

		-- §4.1 levels, at the tolerance F31 explains
		t.near(hot.meanLevel_m, POOL.meanLevelRise375To100_m, 0.01, "§4.1: +0.26 m from the 375 °C datum")
		t.near(hot.meanLevel_m - cold.meanLevel_m, POOL.meanLevelRise230To100_m, 0.01, "§4.1: +0.64 m from 230 °C")
		-- the tilt moves sodium sideways between the two surfaces, so it never changes the gas volume
		t.near(POOL.hotShare * POOL.hotPoolFreeSurface_m2, POOL.coldShare * POOL.coldPoolFreeSurface_m2, 0.5,
			"0.32 × 95 m² balances 0.68 × 45 m²")
	end,

	["the make-up valves open fully, then close in at the D-020 time constant"] = function(t)
		local sys, ch = make()
		local tau = PRIMARY.coverGasControl.correctionTau_s
		sys.gas_mol *= 0.95 -- vent 5 %, which drops the pressure below the 0.115 MPa band
		sys:publish()
		t.ok(ch:get("pools.coverGas_MPa") < GAS.autoBand_MPa[1], "outside the auto band")
		sys:step(DT)
		t.near(sys:getState().makeup_molps, sys.valveRate_molps, 1e-9,
			"an excursion wider than the band asks for more than the valves have, so they sit wide open")

		-- hand the still-latched controller an error it can serve, where the approach is first-order
		local hotMean = sys:hotMean()
		sys.gas_mol = 0.99 * GAS.setpoint_MPa * 1e6 * sys:gasVolume(hotMean, sys.cold)
			/ (sys.R * sys:gasTemperature(hotMean))
		sys:publish()
		local e0 = GAS.setpoint_MPa - ch:get("pools.coverGas_MPa")
		run(sys, tau)
		local e1 = GAS.setpoint_MPa - ch:get("pools.coverGas_MPa")
		t.near(e1 / e0, math.exp(-1), 1e-6, "one time constant of first-order correction")
		t.ok(sys:getState().correcting, "the valves stay open past the band edge, rather than parking on it")
		run(sys, 4 * tau)
		t.near(ch:get("pools.coverGas_MPa"), GAS.setpoint_MPa, 1e-4, "back on the setpoint")
		t.ok(not sys:getState().correcting, "and the valves reseat")
		t.ok(sys:getState().admitted_mol > 0, "argon was admitted, not vented")
	end,

	["CG-LEAK: make-up holds a leak it can match, and loses one it cannot"] = function(t)
		local sys, ch = make()
		local fault = Pools.faults[1]
		t.eq(fault.id, "CG-LEAK")
		fault.arm(sys) -- default rate: exactly the valves' authority
		run(sys, 1800)
		local held = ch:get("pools.coverGas_MPa")
		t.ok(held > GAS.alarmLow_MPa, "auto make-up keeps it above the 0.105 MPa alarm")
		t.ok(held < GAS.setpoint_MPa, "but it settles below the setpoint, with the valves standing open")
		t.near(sys:getState().makeup_molps, sys.leak_molps, 1e-3, "make-up matches the leak")
		local before = ch:get("pools.coverGas_MPa")
		run(sys, 300)
		t.near(ch:get("pools.coverGas_MPa"), before, 1e-5, "and it has stopped moving")

		fault.arm(sys, { rate_molps = 3 * sys.valveRate_molps })
		run(sys, 300)
		t.ok(ch:get("pools.coverGas_MPa") < PRIMARY.pumps.startInterlocks.coverGasMin_MPa,
			"three times the valves' authority walks it past the §4.2 pump start interlock in five minutes")
		fault.clear(sys)
		-- the valves are wide open for most of the way back, so the recovery takes far longer than the leak
		run(sys, 1800)
		t.near(ch:get("pools.coverGas_MPa"), GAS.setpoint_MPa, 1e-3, "clearing the leak lets make-up recover")
	end,

	["cover gas commands: manual valve needs manual control"] = function(t)
		local sys, ch = make()
		local refused = sys:applyCommand(OPERATOR, { kind = "covergas.valve", value = 0.5 })
		t.ok(not refused.ok, "refused while in auto")
		t.ok(sys:applyCommand(OPERATOR, { kind = "covergas.auto", value = 0 }).ok, "switch to manual")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "covergas.valve", value = 2 }).ok, "demand is −1 … +1")
		t.ok(sys:applyCommand(OPERATOR, { kind = "covergas.valve", value = 1 }).ok, "full make-up")
		local before = ch:get("pools.coverGas_MPa")
		run(sys, 60)
		t.ok(ch:get("pools.coverGas_MPa") > before, "manual make-up raises the pressure")
		t.near(sys:getState().makeup_molps, sys.valveRate_molps, 1e-9, "at the valves' full rate")
		t.ok(sys:applyCommand(OPERATOR, { kind = "covergas.auto", value = 1 }).ok, "back to auto")
		t.eq(sys:getState().valve, 0, "which closes the manual demand")
	end,
}
