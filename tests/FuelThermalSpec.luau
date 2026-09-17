--!strict
--[[
	FuelThermal verification (spec §2.4, §2.5, §3.2, §14.3; tools/derive/pin_thermal.py).
	Expected values come from the derivation evaluated on the same 10-layer mesh (tests/PinThermalExpected.luau), so
	the tolerances are the ones the two implementations can legitimately differ by, stated at each check.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any
local Sodium = require(ReplicatedStorage.Kallskar:WaitForChild("Props"):WaitForChild("Sodium")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local FuelThermal = require(Root:WaitForChild("Systems"):WaitForChild("FuelThermal")) :: any
local Pin = require(Root.Systems.FuelThermal:WaitForChild("Pin")) :: any
local Expected = require(script.Parent:WaitForChild("PinThermalExpected")) :: any

local INPUTS = { "core.fuelPinPower_W", "primary.coreFlow_kgps", "pools.coreInlet_K" }

local function make()
	local ch = Channels.new()
	for _, name in INPUTS do
		ch:declareExternal(name, nil)
	end
	local sys = System.new(FuelThermal)
	sys:init({ config = Config, channels = ch:port(FuelThermal.spec) })
	local power = table.create(sys.N, 0)
	ch:setExternal("core.fuelPinPower_W", power)
	ch:setExternal("primary.coreFlow_kgps", Config.Primary.pumps.ratedFlowTotal_kgps)
	ch:setExternal("pools.coreInlet_K", Expected.inletTemperature_K)
	return sys, ch, power
end

local function pinLength(sys: any): number
	return sys.nPins * sys.dz
end

-- every assembly the same: pin linear heat rates q[l] (W/m) per layer
local function uniform(sys: any, power: { number }, q: { number })
	for a = 1, sys.NA do
		for l = 1, sys.L do
			power[(a - 1) * sys.L + l] = q[l] * pinLength(sys)
		end
	end
end

--[[
	Test-only: give every assembly the flow that puts its outlet exactly at `outlet` (the derivation fixes the channel
	by its outlet temperature, not by its flow). Uses coreFlow = 1 so flowShare holds kg/s directly.
]]
local function tuneFlow(sys: any, ch: any, outlet: number)
	ch:setExternal("primary.coreFlow_kgps", 1)
	for a = 1, sys.NA do
		sys.flowShare[a] = 30
	end
	local inlet = Expected.inletTemperature_K
	for _ = 1, 30 do
		local _, converged = sys:settle()
		assert(converged, "FuelThermal did not settle")
		local worst = 0
		for a = 1, sys.NA do
			local rise = sys.Tout[a] - inlet
			worst = math.max(worst, math.abs(sys.Tout[a] - outlet))
			sys.flowShare[a] *= rise / (outlet - inlet)
		end
		if worst < 1e-9 then
			return
		end
	end
	error("flow tuning did not converge")
end

return {
	["sodium properties reproduce the Appendix A table"] = function(t)
		local tab = Config.Sodium.table
		for i, Tc in tab.temperature_C do
			local T = Tc + 273.15
			-- tolerances: half of the last printed digit of each table column
			t.near(Sodium.density(T), tab.density_kgpm3[i], 0.05, `density at {Tc} °C`)
			-- F15: the table prints 1.286 at 950 °C, but the Appendix A correlation gives 1.28547 (rounds to 1.285);
			-- the correlation is authoritative, so that one entry is held to a whole last digit
			local cpTol = if Tc == 950 then 0.001 else 0.0005
			t.near(Sodium.specificHeat(T) / 1000, tab.specificHeat_kJpkgK[i], cpTol, `cp at {Tc} °C`)
			t.near(Sodium.conductivity(T), tab.conductivity_WpmK[i], 0.05, `conductivity at {Tc} °C`)
			t.near(Sodium.viscosity(T) * 1000, tab.viscosity_mPas[i], 0.0005, `viscosity at {Tc} °C`)
			local pv = tab.vapourPressure_MPa[i]
			local digit = 10 ^ math.floor(math.log10(pv))
			t.near(Sodium.vapourPressure(T) / 1e6, pv, 0.05 * digit, `vapour pressure at {Tc} °C`)
		end
	end,

	["pellet kernel: exact Θ inverse and the derivation's layer temperatures"] = function(t)
		local p = Pin.new(Config)
		for T = 300, 3200, 7.3 do
			t.near(Pin.tempOf(p, Pin.thetaOf(p, T)), T, 1e-9, `Θ round trip at {T} K`)
		end
		local e = Expected.average
		local rG, rC = p.rGap, p.rCladNa
		for l, q in e.q_Wpm do
			local Ts = e.sodium_K[l] + q * (rC + rG)
			-- same table and quadrature as the derivation; the generated Θ has 10 significant figures
			t.near(Pin.average(p, Ts, q), e.fuel_K[l], 1e-4, `layer {l} fuel average`)
		end
		-- low-power limit of the pellet resistance is Σwg / k(T_s) (mid-segment, where the table slope is single-valued)
		local Ts = 905
		local k = (Pin.thetaOf(p, Ts + 0.01) - Pin.thetaOf(p, Ts - 0.01)) / 0.02
		local sum = 0
		for i = 1, p.nq do
			sum += p.wq[i] * p.gq[i]
		end
		t.rel(Pin.pelletResistance(p, Ts, 0), sum / k, 1e-6, "zero-power pellet resistance")
	end,

	["average channel at full power matches the derivation (§3.2 1,380 K)"] = function(t)
		local sys, ch, power = make()
		t.eq(sys.NA, 301, "fuel assemblies")
		t.eq(sys.L, 10, "fuel layers")
		local e = Expected.average
		uniform(sys, power, e.q_Wpm)
		tuneFlow(sys, ch, e.outlet_K)
		-- the fixture repeats FuelThermal's layer algebra with the same Appendix A cp, so the only differences are the
		-- settle and flow-tuning convergence and the 10-figure tables: 0.01 K is generous for all of them
		for l = 1, sys.L do
			t.near(sys.Tna[l], e.sodium_K[l], 0.01, `layer {l} sodium`)
			t.near(sys.Tf[l], e.fuel_K[l], 0.01, `layer {l} fuel`)
		end
		local s = sys:getState()
		t.log(string.format("core-average fuel %.3f K (derivation %.3f K, spec 1,380 K); sodium %.2f K; outlet %.3f K",
			s.coreAverage_K, e.coreAverageFuel_K, s.coreAverageSodium_K, s.mixedOutlet_K))
		t.near(s.coreAverage_K, e.coreAverageFuel_K, 0.01, "core-average fuel temperature")
		-- steady state: all generated heat reaches the coolant, plus the direct share
		local generated = 0
		for i = 1, sys.N do
			generated += power[i]
		end
		local split = Config.Core.powerSplit
		t.rel(s.heatToCoolant_W, generated * split.fuelAssemblyCoolant / split.fuelPins, 1e-9, "heat balance")
	end,

	["hottest channel reproduces the §2.4 cladding hot spot"] = function(t)
		local sys, ch, power = make()
		local e = Expected.hot
		local q = {}
		for l, v in e.hotPinQ_Wpm do
			q[l] = v / Config.Core.limits.peaking.pin -- nodes carry the assembly-average pin
		end
		uniform(sys, power, q)
		tuneFlow(sys, ch, e.outlet_K)
		local s = sys:getState()
		t.log(string.format("hot spot %.2f °C (derivation %.2f, spec 620); hot-pin centre %.1f °C (derivation %.1f, spec ≈ 1,950, finding F14); peak %.2f kW/m",
			s.cladHotSpot_K - 273.15, e.cladMidwallMax_K - 273.15, s.hotPinCentre_K - 273.15, e.centreMax_K - 273.15, s.peakLinearHeat_Wpm / 1000))
		t.near(s.cladHotSpot_K, e.cladMidwallMax_K, 0.01, "cladding midwall hot spot")
		t.near(s.hotPinCentre_K, e.centreMax_K, 0.01, "hot-pin centreline")
		t.near(s.peakLinearHeat_Wpm, math.max(table.unpack(e.hotPinQ_Wpm)), 1e-6, "peak linear heat rate")
	end,

	["full power with spec flow zoning gives the §2.4 outlet and heat balance"] = function(t)
		local sys, ch, power = make()
		local split = Config.Core.powerSplit
		local pins = split.fuelPins * Config.Units.ratedThermal_MWt * 1e6
		-- power follows flow (p = f), axial shape from the derivation
		local shapeSum = 0
		for _, q in Expected.average.q_Wpm do
			shapeSum += q
		end
		local shareSum = 0
		for a = 1, sys.NA do
			shareSum += sys.flowShare[a]
		end
		for a = 1, sys.NA do
			for l = 1, sys.L do
				power[(a - 1) * sys.L + l] = pins * sys.flowShare[a] / shareSum * Expected.average.q_Wpm[l] / shapeSum
			end
		end
		local passes, converged = sys:settle()
		t.ok(converged, `settled to 1e-9 K (took {passes} passes)`)
		local s = sys:getState()
		t.log(string.format("outlet %.2f °C, core-average fuel %.2f K, sodium %.2f K, hot spot %.1f °C, centre %.0f °C, heat %.1f MW",
			s.mixedOutlet_K - 273.15, s.coreAverage_K, s.coreAverageSodium_K, s.cladHotSpot_K - 273.15, s.hotPinCentre_K - 273.15, s.heatToCoolant_W / 1e6))
		t.rel(s.heatToCoolant_W, split.fuelAssemblyCoolant * Config.Units.ratedThermal_MWt * 1e6, 1e-9, "97 % of rated power reaches fuel-assembly coolant")
		-- file 20: 375 °C + 0.97·Pth/(ṁ_f·1.27 kJ/kg·K) = 559 °C; Appendix A cp(T) instead of the rounded 1.27 moves it
		-- by less than 0.5 K, plus 0.5 K for the spec's rounding to whole degrees
		t.near(s.mixedOutlet_K, Config.Core.limits.assemblyOutletAverage_C + 273.15, 1.0, "average fuel assembly outlet")
		-- zones spread power by +12 %/−8 %; the derivation bounds the radial non-linearity at +3 K for ±20 %
		t.near(s.coreAverage_K, Expected.average.coreAverageFuel_K, 3, "core-average fuel temperature")
	end,

	["power step: fuel lag lies within the derivation's layer time constants"] = function(t)
		local sys, ch, power = make()
		local e = Expected.average
		uniform(sys, power, e.q_Wpm)
		tuneFlow(sys, ch, e.outlet_K)
		local T0 = sys:getState().coreAverage_K
		for i = 1, sys.N do
			power[i] *= 1.01
		end
		local times, values = {}, {}
		local dt = (1 / Config.Clocks.fast_Hz)
		for n = 1, 300 do
			sys:step(dt)
			times[n] = n * dt
			values[n] = sys:getState().coreAverage_K
		end
		local probe = sys.Tf[1]
		sys:settle()
		local T1 = sys:getState().coreAverage_K
		t.ok(math.abs(sys.Tf[1] - probe) < 0.01, "30 s is long enough to settle (bottom layer within 0.01 K)")
		local target = T0 + (1 - math.exp(-1)) * (T1 - T0)
		local lag = 0
		for n = 2, #values do
			if values[n] >= target then
				local f = (target - values[n - 1]) / (values[n] - values[n - 1])
				lag = times[n - 1] + f * dt
				break
			end
		end
		t.log(string.format("+1 %% power: core-average fuel +%.2f K; 63 %% response after %.3f s (layer τ %.3f–%.3f s; spec §3.2 Doppler lag 4 s)",
			T1 - T0, lag, e.layerTimeConstantMin_s, e.layerTimeConstantMax_s))
		-- a mix of layer time constants responds between the fastest and slowest; the 5 % margins cover the sodium
		-- rising with the heat flow (≈ 2 % of R) and the step discretisation of the lag measurement
		t.ok(lag > 0.95 * e.layerTimeConstantMin_s and lag < 1.05 * e.layerTimeConstantMax_s, "lag within the layer time constants")
	end,

	["no power and no flow stays finite and isothermal"] = function(t)
		local sys, ch = make()
		local T0 = Config.Feedback.referenceTemperature_K -- the initial condition set by init
		ch:setExternal("primary.coreFlow_kgps", 0)
		ch:setExternal("pools.coreInlet_K", T0)
		for _ = 1, 50 do
			sys:step((1 / Config.Clocks.fast_Hz))
		end
		local s = sys:getState()
		for _, v in { s.coreAverage_K, s.mixedOutlet_K, s.cladHotSpot_K, s.hotPinCentre_K } do
			t.near(v, T0, 1e-6, "isothermal at the inlet temperature")
		end
	end,

	["full-plant step fits the fast-tick budget"] = function(t)
		local sys, _, power = make()
		uniform(sys, power, Expected.average.q_Wpm)
		sys:settle()
		local dt = (1 / Config.Clocks.fast_Hz)
		local worst, total = 0, 0
		local n = 200
		for _ = 1, n do
			local c = os.clock()
			sys:step(dt)
			local e = os.clock() - c
			total += e
			worst = math.max(worst, e)
		end
		t.log(string.format("FuelThermal step over %d nodes: mean %.3f ms, worst %.3f ms", sys.N, total / n * 1000, worst * 1000))
		-- necessary, not sufficient: this one system must fit inside the whole fast-tick budget
		t.ok(total / n < Config.Engineering.fastTickBudgetP99_s, "mean step inside Engineering.fastTickBudgetP99_s")
	end,
}
