--!strict
-- Reactor core: geometry, core map, fuel, thermal limits, flow zoning. Spec §2.1–§2.5.
local P = require(script.Parent.Provenance)
local spec, tuning, derived = P.spec, P.tuning, P.derived

return {
	-- §2.1 geometry
	geometry = spec({
		assemblyPitch_mm = 179,
		wrapperAcrossFlats_mm = 173,
		wrapperWall_mm = 4.5,
		assemblyLength_m = 4.80,
		fissileHeight_mm = 1000,
		lowerReflector_mm = 300,
		upperPlenum_mm = 1100,
		coreEquivalentDiameter_m = 3.42,
		coreVolume_m3 = 9.18,
		powerDensityAverage_MWpm3 = 259,
		diagridPositions = 817,
		lastRing = 16,
		lastCoreRing = 10, -- rings 0–10 hold fuel and rods (the 331-position core map)
	}, "§2.1"),

	--[[
		§2.2 core map. Ring n holds 6n positions (ring 0 holds 1).
		kind: fuel | reflector | shieldB4C | storage | shieldSteel
		Rod sets occupy some positions in fuel rings; `fuel` is the number of fuel assemblies left in the ring.
	]]
	rings = spec({
		{ ring = 0, positions = 1, kind = "fuel", fuelZone = "inner", fuel = 1 },
		{ ring = 1, positions = 6, kind = "fuel", fuelZone = "inner", fuel = 6 },
		{ ring = 2, positions = 12, kind = "fuel", fuelZone = "inner", fuel = 9 },
		{ ring = 3, positions = 18, kind = "fuel", fuelZone = "inner", fuel = 12 },
		{ ring = 4, positions = 24, kind = "fuel", fuelZone = "inner", fuel = 21 },
		{ ring = 5, positions = 30, kind = "fuel", fuelZone = "inner", fuel = 30 },
		{ ring = 6, positions = 36, kind = "fuel", fuelZone = "inner", fuel = 30 },
		{ ring = 7, positions = 42, kind = "fuel", fuelZone = "inner", fuel = 36 },
		{ ring = 8, positions = 48, kind = "fuel", fuelZone = "outer", fuel = 42 },
		{ ring = 9, positions = 54, kind = "fuel", fuelZone = "outer", fuel = 54 },
		{ ring = 10, positions = 60, kind = "fuel", fuelZone = "outer", fuel = 60 },
		{ ring = 11, positions = 66, kind = "reflector" },
		{ ring = 12, positions = 72, kind = "reflector" },
		{ ring = 13, positions = 78, kind = "shieldB4C" },
		{ ring = 14, positions = 84, kind = "shieldB4C" },
		{ ring = 15, positions = 90, kind = "storage" },
		{ ring = 16, positions = 96, kind = "shieldSteel" },
	}, "§2.2"),

	totals = spec({
		fuel = 301,
		fuelInner = 145,
		fuelOuter = 156,
		regulating = 3,
		shim = 18,
		secondaryShutdown = 9,
		corePositions = 331,
	}, "§2.2 totals; 331 = positions in rings 0–10 (§14.1 core map)"),

	--[[
		Rod positions, as angles measured from the ring's 0° corner. Every angle listed lands exactly on a position:
		corners are at 60°k on every ring, mid-edges at 30° + 60°k on even rings. See docs/DECISIONS.md D-010.
		set: RR (regulating), SM_A/SM_B/SM_C (shim banks; "SM" avoids the clash with source range SR), SSR.
	]]
	rodLayout = derived({
		{ set = "RR", ring = 2, angles_deg = { 0, 120, 240 } },
		{ set = "SM_A", ring = 3, angles_deg = { 0, 60, 120, 180, 240, 300 } },
		{ set = "SSR", ring = 4, angles_deg = { 30, 150, 270 } },
		{ set = "SM_B", ring = 6, angles_deg = { 30, 90, 150, 210, 270, 330 } },
		{ set = "SSR", ring = 7, angles_deg = { 0, 60, 120, 180, 240, 300 } },
		{ set = "SM_C", ring = 8, angles_deg = { 30, 90, 150, 210, 270, 330 } },
	}, "tools/derive/rod_layout.py (D-010; RR angles and the A→B 30° offset are §2.2)"),

	-- §2.3 fuel pin and assembly
	fuel = spec({
		pinsPerAssembly = 271,
		pinPitch_mm = 9.7,
		cladOuterDiameter_mm = 8.50,
		cladWall_mm = 0.56,
		pelletOuterDiameter_mm = 7.28,
		pelletHoleDiameter_mm = 2.0,
		pelletDensity_fracTD = 0.95,
		plutoniumFraction = { inner = 0.18, outer = 0.23 },
		wireDiameter_mm = 1.2,
		wirePitch_mm = 200,
		totalPins = 81571,
		heavyMetal_t = 29,
		cycleLength_EFPD = 160,
		fractionReplacedPerOutage = 0.25,
		dischargeBurnup_GWdpt = 51,
	}, "§2.3 (cladding 15-15Ti; pellet annular (U,Pu)O2; wrapper ferritic-martensitic)"),
	refuellingOutage_min = tuning(30, "§2.3, OD-8: timed wait, reactor held in Mode 5"),

	-- §2.4 thermal limits
	limits = spec({
		linearHeatRateAverage_kWpm = 27.7,
		linearHeatRatePeak_kWpm = 42,
		linearHeatRatePeakAlarm_kWpm = 44,
		linearHeatRatePeakLimit_kWpm = 45,
		centrelineMeltingAbove_kWpm = 60,
		peaking = { radial = 1.20, pin = 1.04, axial = 1.22 },
		hotPinCentreline_C = 1950,
		moxMelting_C = 2700,
		cladMidwallHotSpot_C = 620,
		cladMidwallAlarm_C = 650,
		cladMidwallShortTermLimit_C = 700,
		assemblyOutletAverage_C = 559,
		hottestAssemblyOutlet_C = { 580, 585 },
		mixedCoreOutlet_C = 550,
		mixedCoreOutletAlarm_C = 565,
		mixedCoreOutletTrip_C = 580,
		sodiumBoilingAtCoreOutlet_C = 950,
		sodiumBoilingAt1atm_C = 881,
		sodiumFreezing_C = 97.8,
	}, "§2.4"),
	cladBurstLikelyAbove_C = tuning(850, "§2.4: above 850 °C burst likely within minutes"),

	-- §2.5 flow zoning
	flow = spec({
		fractionFuel = 0.925,
		fractionRods = 0.015,
		fractionReflectorShieldStorage = 0.03,
		fractionLeakage = 0.03,
		meanFuelAssembly_kgps = 32.9,
		bundleVelocity_mps = 5.4,
		coreTransit_s = 0.19,
		assemblyPressureDrop_MPa = 0.45,
		zones = {
			{ name = "I", firstRing = 0, lastRing = 5, fuel = 79, flowFactor = 1.12 },
			{ name = "II", firstRing = 6, lastRing = 8, fuel = 108, flowFactor = 1.00 },
			{ name = "III", firstRing = 9, lastRing = 10, fuel = 114, flowFactor = 0.92 },
		},
		-- T_out = T_in + outletRise_K × (p / f) × (P/Q)
		outletRise_K = 183.7,
		thermocoupleNoise_K = 1,
		thermocoupleLag_s = 3,
	}, "§2.5"),
}
