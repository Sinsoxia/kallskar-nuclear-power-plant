--!strict
-- Operating modes, part-load program and the M1 automatic controllers. Spec §9.1, §9.2, §9.4.
local P = require(script.Parent.Provenance)
local spec, decision, derived = P.spec, P.decision, P.derived

return {
	-- §9.1 operating modes
	modes = spec({
		{ mode = 1, name = "Power", powerAbove_pctFP = 5 },
		{ mode = 2, name = "Startup", kEffAtLeast = 0.99, powerUpTo_pctFP = 5 },
		{ mode = 3, name = "Hot standby", subcriticalAtLeast_pcm = 1000, coreInlet_C = { 350, 380 } },
		{ mode = 4, name = "Shutdown", subcriticalAtLeast_pcm = 1000, coreInlet_C = { 200, 350 } },
		{ mode = 5, name = "Refuelling", subcriticalAtLeast_pcm = 3000, coreInlet_C = { 210, 250 }, plugsUnlocked = true },
	}, "§9.1 (Mode 5 is 230 ± 20 °C)"),

	--[[
		§9.2 part-load program. Core inlet is held at 375 °C throughout. With r = P/Q:
		  core outlet   = coreInlet + outletSlope·r
		  secondary cold = coreInlet + secondaryColdSlope·r
		  secondary hot  = coreInlet + secondaryHotSlope·r
		  main steam     = min(mainSteamCap, secondaryHot + mainSteamSlope·r)
	]]
	partLoad = spec({
		coreInlet_C = 375,
		outletSlope_K = 175,
		secondaryColdSlope_K = -55,
		secondaryHotSlope_K = 145,
		mainSteamCap_C = 505,
		mainSteamSlope_K = -15,
		minimumFlowAtOrAbove10_pct = 40,
		minimumFlowAtOrBelow5_pct = 25,
		-- SG pressure: 14.0 MPa at or above 30 %FP, falling 0.25 MPa per %FP below (file 20 PART LOAD line)
		sgPressureFull_MPa = 14.0,
		sgPressureFullDownTo_pctFP = 30,
		sgPressureSlope_MPapPctFP = 0.25,
	}, "§9.2 and file 20 PART LOAD line"),
	-- Between 5 and 10 %FP flow rises linearly from 25% to 40% instead of stepping at 10 %FP
	partLoadFlowRamp_pctFP = decision({ 5, 10 }, "D-007"),

	-- The M1 heat sink's load moves no faster than §7.1's hot loading rate, and above 40 % no faster than LCO-10
	-- lets the plant move (the reactor sets the plant rate, §7.1). Both limits apply up and down.
	sinkLoading = spec({
		hot_pctPerMin = 5,
		aboveLimit_pctPerMin = 1,
		limitAbove_pct = 40,
	}, "§7.1 loading rate ≤ 5 %/min hot; §9.6 LCO-10 ramp ≤ 1 %/min above 40%"),

	-- §9.2 table, used as a validation target for the program functions
	partLoadTable = spec({
		power_pct = { 100, 80, 60, 40, 30, 20, 10, 5 },
		flow_pct = { 100, 80, 60, 40, 40, 40, 40, 25 },
		coreOutlet_C = { 550, 550, 550, 550, 506, 462, 419, 410 },
		secondaryCold_C = { 320, 320, 320, 320, 334, 348, 361, 364 },
		secondaryHot_C = { 520, 520, 520, 520, 484, 448, 411, 404 },
		mainSteam_C = { 505, 505, 505, 505, 472, 440, 408, 401 },
		sgPressure_MPa = { 14.0, 14.0, 14.0, 14.0, 14.0, 11.5, 9.0, 7.75 },
		feed_C = { 240, 231, 222, 210, 204, 197, 188, 182 },
		grossOutput_MWe = { 1000, 783, 573, 371, 273, 178, 86, 42 },
	}, "§9.2 table"),

	-- §9.4 automatic controllers relevant to M1: competent, local and reactive (Rev A6, D-059)
	rodAuto = spec({
		holdBand_K = 2,
		regulatingBand_mm = { 250, 750 }, -- Rev A4, matches Rods.regulating.normalBand_mm
		usesShims = false,
		stopsAndAlarmsOutsideBand = true,
		actsOnThermocouples = true,
	}, "§9.4: holds core outlet 550 ±2 K using RR only"),
	rodAutoTracksProgram = decision(true, "D-003"),
	--[[
		D-059, option A: rod auto's model of its own moves. The outlet thermocouple's response to a regulating rod is
		four first-order modes, fitted to tests/TuningSpec's open-loop steps at three powers, per millimetre at 500 mm
		(the position InitialConditions seats the rods at). Rod auto interpolates the modes in power, drives its copy of
		them with the regulating rods' actual moves in reactivity (500-mm equivalent millimetres, through §3.4's
		S-curve), and moves by correctionFraction of what the error plus the still-arriving effect calls for. The
		fraction allows for §3.7's ±10 % rod-worth tolerance.
	]]
	rodAutoModel = derived({
		measuredAt_mm = 500,
		correctionFraction = 0.9091,
		byPower = {
			{ power_pctFP = 30, modes = {
				{ gain_Kpmm = -0.037383, tau_s = 1.425 }, { gain_Kpmm = 0.116462, tau_s = 5.346 },
				{ gain_Kpmm = -0.041293, tau_s = 40.000 }, { gain_Kpmm = 0.053455, tau_s = 77.518 },
			} },
			{ power_pctFP = 60, modes = {
				{ gain_Kpmm = -0.032569, tau_s = 1.090 }, { gain_Kpmm = 0.104006, tau_s = 4.442 },
				{ gain_Kpmm = -0.047855, tau_s = 40.000 }, { gain_Kpmm = 0.068408, tau_s = 108.443 },
			} },
			{ power_pctFP = 100, modes = {
				{ gain_Kpmm = -0.010834, tau_s = 0.353 }, { gain_Kpmm = 0.068096, tau_s = 5.269 },
				{ gain_Kpmm = -0.035390, tau_s = 40.000 }, { gain_Kpmm = 0.068308, tau_s = 119.805 },
			} },
		},
	}, "tools/derive/auto_tuning.py (D-059: fitted to tests/TuningSpec's regulating-rod steps)"),
	-- D-059: rod auto reads the thermocouple through this filter, and runs its model through the same one. It is the
	-- shortest that keeps §2.5's ±1 K noise, at D-025's 5σ, inside the margin correctionFraction leaves at the band edge.
	rodAutoTuning = derived({ measurementFilter_s = 10.42 }, "tools/derive/auto_tuning.py (D-059: §2.5's thermocouple noise)"),

	primaryFlowAuto = spec({ targetPQ = 1.00 }, "§9.4: holds P/Q at 1.00"),
	-- D-059: flow auto asks for the speed that gives the programme's flow with the pumps running, and the ramp does the
	-- rest. The PR median it indexes the programme on is filtered so its noise moves the pumps by less than a quarter
	-- of one tick's 2 %/s ramp.
	primaryFlowAutoTuning = derived({ powerFilter_s = 5.26 }, "tools/derive/auto_tuning.py (D-059: D-025's PR noise)"),
	primaryFlowAutoTracksProgram = decision(true, "D-003"),

	coverGasAuto = spec({
		band_MPa = { 0.115, 0.125 },
		cyclesOnHeatup = true,
		ventsWithoutCheckingActivity = true,
	}, "§9.4"),
}
