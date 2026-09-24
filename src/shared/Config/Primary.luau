--!strict
-- Primary system: vessel, pools, pumps, IHX primary side, cover gas, DRACS, purification. Spec §4.1–§4.6.
local P = require(script.Parent.Provenance)
local spec, tuning, engineering, decision = P.spec, P.tuning, P.engineering, P.decision

return {
	-- §4.1 vessel and pools
	vessel = spec({
		mainInnerDiameter_m = 15.0,
		mainHeight_m = 14.5,
		mainWall_mm = 40,
		guardInnerDiameter_m = 15.6,
		guardGap_m = 0.3,
		roofSlab_m = 2.5,
	}, "§4.1 (main vessel 316LN)"),

	sodium = spec({
		total_t = 1250,
		hotPool_t = 620,
		coldPool_t = 560,
		coreAndDiagrid_t = 70,
		perThermalMW_t = 0.53,
		heatCapacityWithInternals_MJpK = 2400,
	}, "§4.1"),

	pools = spec({
		hotPoolFreeSurface_m2 = 95,
		coldPoolFreeSurface_m2 = 45,
		hotPoolMixing_s = 58,
		hotPoolNodes_s = { 40, 18 },
		coldPoolMixing_s = 52,
		ihxOutletToPumpInletTransport_s = 8,
		-- ΔL = headDifferenceAtRated_m × (Q/Q₀)²; hot = L_mean + hotShare·ΔL; cold = L_mean − coldShare·ΔL
		headDifferenceAtRated_m = 1.5,
		hotShare = 0.32,
		coldShare = 0.68,
		meanLevelRise375To100_m = 0.26,
		meanLevelRise230To100_m = 0.64,
	}, "§4.1"),

	-- §4.2 primary pumps PP1–PP3
	pumps = spec({
		count = 3,
		ratedFlowEach_kgps = 3565,
		ratedVolumeEach_m3ps = 4.13,
		ratedFlowTotal_kgps = 10694,
		head_MPa = 0.65,
		head_mSodium = 77,
		ratedSpeed_rpm = 740,
		shaftPower_MW = 3.3,
		motorPower_MW = 4.0,
		speedRange_pct = { 25, 105 },
		maxRamp_pctps = 2,
		ponyMotorPower_kW = 250,
		ponySpeed_pct = 10,
		ponyBoardDivisions = { 1, 2, 3 },
		-- Q(t) = Q₀ / (1 + t / coastdownTau_s)
		coastdownTau_s = 10,
		flywheelInertia_kgm2 = 5500,
		startInterlocks = { coverGasMin_MPa = 0.105, sodiumMin_C = 180 },
		pumpHeatToSodium_MWt = 10,
	}, "§4.2"),
	--[[
		How long §4.2's survivor ramp holds after a pump trip: at least this long, and for as long as RB-2 still runs.
		40 s is RB-2 from full power, §9.5's 40 %FP (100 to 60) at 60 %/min, so the crew has the same window whatever
		the power was when the pump tripped.
	]]
	survivorHold = decision({ minimum_s = 40 }, "D-046 (amended 2026-09-24): the survivors hold for RB-2's full-power length at any power"),
	-- Q_nc ≈ coefficient × (P / referencePower)^(1/3), no pumps running. Rev A4 fixed the reference from 1 %FP to
	-- 100 %FP: as written the formula gave 16 % rated flow at full power.
	naturalCirculation = tuning({ coefficient_pct = 3.5, exponent = 1 / 3, referencePower_pctFP = 100 }, "§4.2"),
	cavitation = tuning({ coverGasBelow_MPa = 0.108, speedAbove_pct = 90 }, "§4.2"),
	gasEntrainment = tuning({ coldPoolBelowProgram_m = 1.3, speedAbove_pct = 95 }, "§4.2 (scenario S-10)"),

	-- §4.3 intermediate heat exchangers, primary side
	ihx = spec({
		count = 6,
		names = { "1A", "1B", "2A", "2B", "3A", "3B" },
		dutyEach_MWt = 400, -- nameplate rating; Rev A4 states the duty at 100 % separately
		dutyAt100_MWt = 396,
		primaryFlowEach_kgps = 1782,
		primaryInlet_C = 550, -- Rev A4: was 545, which carried only 385 MWt and left the primary 79 MWt short
		primaryOutlet_C = 375,
		secondaryFlowEach_kgps = 1556,
		secondaryInlet_C = 320,
		secondaryOutlet_C = 520,
		lmtd_K = 41,
		ua_MWpK = 9.6,
		area_m2 = 2000,
		shutterClose_s = 60,
		shutterLeakBy_frac = 0.05,
		secondaryAbovePrimary_MPa = 0.4,
	}, "§4.3"),

	-- §4.4 cover gas (argon)
	coverGas = spec({
		volumeAt100_m3 = 320,
		setpoint_MPa = 0.120,
		autoBand_MPa = { 0.115, 0.125 },
		alarmLow_MPa = 0.105,
		alarmHigh_MPa = 0.140,
		trip_MPa = 0.160,
		neverBelow_MPa = 0.102,
		volumeSwing230To100_m3 = 90,
		volumeSwingFrom_C = 230, -- the isothermal state §4.4 measures the 90 m³ swing and the 0.074 MPa from
		fixedInventoryCooldown_MPa = 0.074,
	}, "§4.4"),
	coverGasTemperature_C = spec({ atPower = 300, cold = 180 }, "file 20 POOL/cover gas line"),
	-- Make-up and vent valves: first-order correction back to the setpoint whenever pressure leaves the auto band.
	coverGasControl = decision({ correctionTau_s = 60 }, "D-020"),
	-- Ring buffer length for the IHX→pump transport delay, which grows as 1/flow. 600 s covers flow down to 1.3 %
	-- of rated; below that the pool mixing times are already tens of minutes and the pipe delay stops mattering.
	poolTransportTracked_s = engineering(600, "ring buffer length; the delay is clamped to it at very low flow"),
	decayTanks = tuning({ count = 3, volumeEach_m3 = 50, holdUp_h = 72 }, "§4.4"),

	-- §4.5 DRACS (not simulated in M1; values here for guide boards and later milestones)
	dracs = spec({
		loops = 4,
		ratedEach_MWt = 20,
		ratedAtHotPool_C = 550,
		standbyDamperOpen_frac = 0.05,
		standbyLossEach_MW = 0.3,
		dampersPerLoop = 2,
		handwheelPerDamper_s = 90,
		copingRise_K = 200,
		copingTime_h = 5,
	}, "§4.5"),
	-- Q = rated × ((T_hot − ambientOffset) / span)^exponent
	dracsCurve = tuning({ ambientOffset_C = 30, span_K = 520, exponent = 1.4 }, "§4.5"),

	-- §4.6 purification
	coldTraps = spec({ count = 2, wall_C = 125 }, "§4.6"),
	coldTrapFlowEach_kgps = tuning(8, "§4.6"),
	pluggingTemperature_C = spec({ normalMax = 125, alarm = 150, lco = 180 }, "§4.6"),

	minimumLiquidSodium_C = spec(180, "§9.1: no sodium meant to stay liquid goes below 180 °C"),
}
