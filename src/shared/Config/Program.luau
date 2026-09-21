--!strict
-- Operating modes, part-load program and the M1 automatic controllers. Spec §9.1, §9.2, §9.4.
local P = require(script.Parent.Provenance)
local spec, decision = P.spec, P.decision

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

	-- §9.4 automatic controllers relevant to M1 (deliberately worse than a crew)
	rodAuto = spec({
		holdBand_K = 2,
		regulatingBand_mm = { 250, 750 }, -- Rev A4, matches Rods.regulating.normalBand_mm
		usesShims = false,
		stopsAndAlarmsOutsideBand = true,
		actsOnThermocouples = true,
	}, "§9.4: holds core outlet 550 ±2 K using RR only"),
	rodAutoTracksProgram = decision(true, "D-003"),

	primaryFlowAuto = spec({
		targetPQ = 1.00,
		powerFilter_s = 10,
		swingOnFastChanges_frac = 0.05,
		ignoresPumpTrip = true,
	}, "§9.4: holds P/Q at 1.00"),
	primaryFlowAutoTracksProgram = decision(true, "D-003"),

	coverGasAuto = spec({
		band_MPa = { 0.115, 0.125 },
		cyclesOnHeatup = true,
		ventsWithoutCheckingActivity = true,
	}, "§9.4"),
}
