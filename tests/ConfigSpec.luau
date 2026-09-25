--!strict
-- Config: loads, is frozen, every number has provenance, and the spec's own totals agree with each other.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ConfigModule = ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")
local Config = require(ConfigModule) :: any
local Provenance = require(ConfigModule:WaitForChild("Provenance")) :: any

local function numericLeaves(): { string }
	local out = {}
	local function walk(node: any, path: string)
		for k, v in node do
			local p = if path == "" then tostring(k) else `{path}.{tostring(k)}`
			if type(v) == "table" then
				walk(v, p)
			elseif type(v) == "number" then
				table.insert(out, p)
			end
		end
	end
	for name, mod in Config do
		if type(mod) == "table" and name ~= "provenance" then
			walk(mod, name)
		end
	end
	return out
end

return {
	["every numeric leaf has provenance"] = function(t)
		local leaves = numericLeaves()
		local missing = {}
		local kinds = {}
		for _, p in leaves do
			local e = Config.sourceOf(p)
			if e then
				kinds[e.kind] = (kinds[e.kind] or 0) + 1
			else
				table.insert(missing, p)
			end
		end
		local parts = {}
		for k, n in kinds do
			table.insert(parts, `{k}={n}`)
		end
		table.sort(parts)
		t.log(`{#leaves} numeric leaves: {table.concat(parts, ", ")}`)
		t.eq(#missing, 0, `numbers without provenance: {table.concat(missing, ", ")}`)
	end,

	["derived and decision provenance point at real records"] = function(t)
		-- The files themselves can't be read from inside Roblox; this checks the reference *format*.
		-- tools/check_provenance.ps1 checks that every referenced script / decision id exists on disk.
		for path, e in Config.provenance do
			if e.kind == "derived" then
				t.ok(string.find(e.ref, "tools/derive/", 1, true), `derived value {path} must cite a tools/derive script, got '{e.ref}'`)
			elseif e.kind == "decision" then
				t.ok(string.match(e.ref, "D%-%d%d%d"), `decision value {path} must cite a D-### record, got '{e.ref}'`)
			end
			t.ok(#e.ref > 0, `empty ref at {path}`)
		end
	end,

	["bare numbers are rejected at load"] = function(t)
		t.throws(function()
			Provenance.build("Bad", { x = 5 }, {})
		end, "bare number")
		t.throws(function()
			Provenance.build("Bad", { nested = { y = 1.5 } }, {})
		end, "bare number")
	end,

	["NaN and functions are rejected"] = function(t)
		t.throws(function()
			Provenance.build("Bad", { x = Provenance.spec(0 / 0, "test") }, {})
		end, "NaN")
		t.throws(function()
			Provenance.build("Bad", { f = function() end }, {})
		end, "unsupported")
	end,

	["config is deeply frozen"] = function(t)
		t.throws(function()
			Config.Kinetics.betaEff_pcm = 1
		end)
		t.throws(function()
			Config.Kinetics.groups.beta_pcm[1] = 1
		end)
		t.throws(function()
			Config.provenance["Kinetics.betaEff_pcm"] = nil
		end)
		t.eq(Config.Kinetics.betaEff_pcm, 360)
	end,

	["tuning flag follows the spec dagger"] = function(t)
		t.eq(Config.sourceOf("Clocks.gridRate").tuning, true, "grid clock is †")
		t.eq(Config.sourceOf("Clocks.fast_Hz").tuning, false, "10 Hz is not †")
		t.eq(Config.sourceOf("Kinetics.groups.beta_pcm.3").kind, "spec", "boxed table covers its elements")
	end,

	["the revision label matches the spec the values follow, and no setting is left unread"] = function(t)
		--[[
			A pin, not a derivation: the spec is not in the place, so nothing at run time can read its revision. The
			values carry Rev A4, A5 and A6 changes (Rods.regulating.normalBand_mm, Primary.ihx.primaryInlet_C, the
			§2.4 pin figures of D-018, and A6's §9.4 autos in Program.rodAutoModel and primaryFlowAutoTuning), so a
			label older than A6 misdescribes them.
		]]
		t.eq(Config.revision, "A6", "Config follows spec Rev A6")
		t.eq(Config.Engineering.devStrictState, nil, "no switch that nothing reads (System.record takes its own flag)")
	end,

	["core map totals agree (§2.2, §3.7, §2.1)"] = function(t)
		local all, r12, r10, fuel, inner, outer = 0, 0, 0, 0, 0, 0
		for _, r in Config.Core.rings do
			t.eq(r.positions, if r.ring == 0 then 1 else 6 * r.ring, `ring {r.ring} holds 6n positions`)
			all += r.positions
			if r.ring <= 12 then
				r12 += r.positions
			end
			if r.ring <= 10 then
				r10 += r.positions
			end
			if r.fuel then
				fuel += r.fuel
				if r.fuelZone == "inner" then
					inner += r.fuel
				else
					outer += r.fuel
				end
			end
		end
		t.eq(all, Config.Core.geometry.diagridPositions, "rings 0–16 = diagrid positions")
		t.eq(r12, Config.PhysicsModel.radialNodes, "rings 0–12 = radial mesh nodes")
		t.eq(r10, Config.Core.totals.corePositions, "rings 0–10 = core map")
		t.eq(fuel, Config.Core.totals.fuel, "fuel total")
		t.eq(inner, Config.Core.totals.fuelInner, "inner fuel")
		t.eq(outer, Config.Core.totals.fuelOuter, "outer fuel")
		t.eq(fuel * Config.Core.fuel.pinsPerAssembly, Config.Core.fuel.totalPins, "total pins")
	end,

	["rod layout fills exactly the non-fuel core positions"] = function(t)
		local bySet = {}
		local perRing = {}
		for _, s in Config.Core.rodLayout do
			bySet[s.set] = (bySet[s.set] or 0) + #s.angles_deg
			perRing[s.ring] = (perRing[s.ring] or 0) + #s.angles_deg
		end
		t.eq(bySet.RR, Config.Rods.regulating.count, "RR count")
		t.eq((bySet.SM_A or 0) + (bySet.SM_B or 0) + (bySet.SM_C or 0), Config.Rods.shim.count, "shim count")
		t.eq(bySet.SSR, Config.Rods.secondaryShutdown.count, "SSR count")
		for _, r in Config.Core.rings do
			if r.kind == "fuel" then
				t.eq(r.fuel + (perRing[r.ring] or 0), r.positions, `ring {r.ring}: fuel + rods = positions`)
			end
		end
	end,

	["flow zones agree (§2.5)"] = function(t)
		local n, weighted = 0, 0
		for _, z in Config.Core.flow.zones do
			local fuelInRings = 0
			for _, r in Config.Core.rings do
				if r.ring >= z.firstRing and r.ring <= z.lastRing then
					fuelInRings += r.fuel or 0
				end
			end
			t.eq(fuelInRings, z.fuel, `zone {z.name} fuel count`)
			n += z.fuel
			weighted += z.fuel * z.flowFactor
		end
		t.eq(n, 301)
		-- flow factors are given to 2 decimals (±0.005), so their weighted mean is known to ±0.005
		t.near(weighted / n, 1.0, 0.005, "flow factors conserve mass")
		local mean = Config.Core.flow.fractionFuel * Config.Primary.pumps.ratedFlowTotal_kgps / n
		t.near(mean, Config.Core.flow.meanFuelAssembly_kgps, 0.05, "mean assembly flow")
	end,

	["kinetics groups agree (§3.1)"] = function(t)
		local g = Config.Kinetics.groups
		local b, a, life = 0, 0, 0
		for i = 1, 6 do
			b += g.beta_pcm[i]
			a += g.abundance[i]
			life += g.abundance[i] / g.lambda_ps[i]
			-- abundance is given to 3 decimals (±0.0005 × 360 = ±0.18 pcm) and βᵢ to 0.1 pcm (±0.05)
			t.near(g.beta_pcm[i], g.abundance[i] * Config.Kinetics.betaEff_pcm, 0.23, `group {i} beta = abundance × β`)
		end
		t.near(a, 1.0, 1e-9, "abundances sum to 1")
		t.near(life, Config.Kinetics.meanDelayedLifetime_s, 0.05, "mean delayed lifetime")
		t.near(b, 360.3, 1e-9, "Σβᵢ is 360.3 pcm (D-011: amplitude uses this, not 360)")
	end,

	["reactivity budget and power defect add up (§3.2, §3.3)"] = function(t)
		local r = Config.Reactivity.budget_pcm
		t.eq(r.isothermal230to375 + r.powerDefect + r.burnupOverCycle + r.operatingMargin + r.uncertaintyAllowance, r.requiredExcessAt230AllRodsOut)
		t.near(Config.Reactivity.burnupRate_pcmpEFPD * Config.Core.fuel.cycleLength_EFPD, r.burnupOverCycle, 1e-9)
		local p = Config.Feedback.targets.powerDefectParts_pcm
		-- five parts each rounded to 1 pcm (±0.5 each) → ±2.5 on their sum
		t.near(p.doppler + p.axial + p.sodium + p.pads + p.drivelines, Config.Feedback.targets.powerDefect_pcm, 2.5)
		-- file 20: Doppler part from the §3.2 coefficient between the reference and full-power fuel temperatures
		local fb = Config.Feedback
		local dop = fb.doppler.constant_pcm * math.log(fb.fullPowerFuelAverage_K / fb.referenceTemperature_K)
		t.near(dop, p.doppler, 0.5, "Doppler part of power defect")
		local iso = fb.doppler.constant_pcm / fb.referenceTemperature_K
			+ fb.fuelAxialExpansion.coefficient_pcmpK
			+ fb.sodiumDensity.coefficient_pcmpK
			+ fb.loadPads.coefficient_pcmpK
			+ fb.diagrid.coefficient_pcmpK
			+ fb.drivelines.coefficient_pcmpK
			+ fb.vessel.coefficient_pcmpK
		t.near(iso, fb.targets.isothermalCoefficientAt375_pcmpK, 0.005, "isothermal coefficient at 375 °C")
		local k = 1 / (1 - r.requiredExcessAt230AllRodsOut * 1e-5)
		t.near(k, Config.Reactivity.kEffAt230AllRodsOut, 0.0005, "k_eff from excess reactivity")
	end,

	["rod worths add up (§3.4)"] = function(t)
		local s = Config.Rods.shim
		t.eq(s.banks.A.count * s.banks.A.worthEach_pcm + s.banks.B.count * s.banks.B.worthEach_pcm + s.banks.C.count * s.banks.C.worthEach_pcm, s.worthTotal_pcm)
		t.eq(Config.Rods.regulating.count * Config.Rods.regulating.worthEach_pcm, Config.Rods.regulating.worthTotal_pcm)
		t.eq(Config.Rods.secondaryShutdown.count * Config.Rods.secondaryShutdown.worthEach_pcm, Config.Rods.secondaryShutdown.worthTotal_pcm)
		-- the tabulated S-curve matches W(d) = d − sin(2πd)/2π
		local c = Config.Rods.worthCurve
		for i, d in c.insertedFraction do
			t.near(d - math.sin(2 * math.pi * d) / (2 * math.pi), c.worthFraction[i], 0.0006, `S-curve at d={d}`)
		end
	end,

	["thermal limits agree (§2.4)"] = function(t)
		local l = Config.Core.limits
		t.near(l.linearHeatRateAverage_kWpm * l.peaking.radial * l.peaking.pin * l.peaking.axial, l.linearHeatRatePeak_kWpm, 0.5, "peak LHR = average × peaking")
		t.ok(l.mixedCoreOutletAlarm_C < l.mixedCoreOutletTrip_C, "alarm below trip")
		t.eq(l.mixedCoreOutletTrip_C, Config.Protection.pss.coreOutletMixed.trip_C, "§2.4 and §9.5 agree on the outlet trip")
	end,

	["decay heat table follows the formula (§3.6)"] = function(t)
		local d = Config.DecayHeat
		local Top = d.referenceOperatingTime_EFPD * Config.Units.secondsPerDay_s
		for i, ts in d.table.time_s do
			local pct = 100 * d.coefficient * (ts ^ d.exponent - (ts + Top) ^ d.exponent)
			-- table gives % to 2 decimals (±0.005) and MW as integers (±0.5); small allowance for float error
			t.near(pct, d.table.percent[i], 0.0051, `decay heat at t={ts} s`)
			t.near(pct / 100 * Config.Units.ratedThermal_MWt, d.table.megawatts[i], 0.51, `decay heat MW at t={ts} s`)
		end
	end,

	["protection setpoints are ordered (§9.5)"] = function(t)
		local p = Config.Protection.pss
		t.ok(p.powerRangeHigh.alarm_pctFP < p.powerRangeHigh.trip_pctFP)
		t.ok(p.powerToFlow.alarm < p.powerToFlow.trip)
		t.ok(p.coreInlet.alarmHigh_C < p.coreInlet.tripHigh_C)
		t.ok(p.coreInlet.alarmLow_C > p.coreInlet.tripLow_C)
		t.ok(p.period.rodBlockBelow_s > p.period.tripBelow_s)
		t.ok(p.coverGas.alarm_MPa < p.coverGas.trip_MPa)
		t.ok(p.assemblyOutletDeviation.alarm_K < p.assemblyOutletDeviation.rodBlock_K)
		t.ok(p.assemblyOutletDeviation.rodBlock_K < p.assemblyOutletDeviation.trip_K)
		-- SSS setpoints sit above the PSS ones (diverse backup)
		t.ok(Config.Protection.sss.powerRange_pctFP > p.powerRangeHigh.trip_pctFP)
		t.ok(Config.Protection.sss.powerToFlowPumpSpeedDerived > p.powerToFlow.trip)
		t.ok(Config.Protection.sss.coreOutlet_C > p.coreOutletMixed.trip_C)
	end,
}
