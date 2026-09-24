--!strict
-- Reactor protection, runbacks, rod blocks and the M1-relevant LCOs. Spec §9.5, §9.6.
local P = require(script.Parent.Provenance)
local spec, decision = P.spec, P.decision

return {
	-- Primary shutdown system coincidence logic
	pssVoting = spec({ required = 2, of = 3 }, "§9.5: PSS logic is 2-out-of-3 on independent channels"),
	powerRangeVoting = decision({ required = 2, of = 4 }, "D-005: four PR quadrant channels"),
	bypassedRowsMax = decision(1, "D-055: at most one §9.5 row may be bypassed at once"),
	manualTripWindow_s = decision(2, "D-056: the MCR's two trip buttons count together only when pressed within 2 s of each other"),

	pss = spec({
		powerRangeHigh = { normal_pctFP = 100, alarm_pctFP = 105, trip_pctFP = 115 },
		powerRangeLowSetpoint = { trip_pctFP = 25, activeBelowPermissive_pctFP = 10 },
		period = { rodBlockBelow_s = 30, tripBelow_s = 10, activeBelow_pctFP = 10 },
		fluxRate = { tripRise_pctFPps = 10, tripFall_pctFPps = -5 },
		powerToFlow = { normal = 1.00, alarm = 1.05, trip = 1.12, activeAbove_pctFP = 5 },
		coreOutletMixed = { normal_C = 550, alarm_C = 565, trip_C = 580 },
		assemblyOutletDeviation = { alarm_K = 20, rodBlock_K = 30, trip_K = 45, tripAdjacentChannels = 2 },
		coreInlet = { normal_C = 375, alarmHigh_C = 390, alarmLow_C = 360, tripHigh_C = 405, tripLow_C = 345 },
		hotPoolLevelDeviation = { alarm_m = 0.25, trip_m = -0.50 },
		coverGas = { normal_MPa = 0.120, alarm_MPa = 0.140, trip_MPa = 0.160 },
		delayedNeutrons = { alarmFactor = 3, tripFactor = 20 },
		primaryPumpsLost = { runback = 1, trip = 2 },
		secondaryLoopsLost = { runback = 1, trip = 2 },
		seismic = { alarm_g = 0.04, trip_g = 0.08 },
		manualButtons = { mainControlRoom = 2, backupControlRoom = 1 },
	}, "§9.5 protection table"),
	--[[
		Core-inlet-low trip gating, refined when D-004 was accepted (Rev A5, §9.5):
		  Modes 4 and 5        inhibited outright
		  Mode 3               inhibited when every PSS rod is fully inserted
		  Mode 2               inhibited below 350 °C during heatup
		  Mode 1, above 5 %FP  armed
		Every inhibit is annunciated, so the crew can see the trip is unavailable.
	]]
	coreInletLowInhibit = decision({
		modesAlways = { 4, 5 },
		modeWithPssRodsIn = 3,
		mode2BelowTemp_C = 350,
		armedAbove_pctFP = 5,
		annunciated = true,
	}, "D-004"),

	sss = spec({
		powerRange_pctFP = 118,
		powerToFlowPumpSpeedDerived = 1.15,
		coreOutlet_C = 590,
	}, "§9.5: secondary shutdown system, diverse sensors, plus manual"),

	runbacks = spec({
		RB1 = { trigger = "one secondary loop lost", target_pctFP = 64, rate_pctpmin = 30, shimDriveIn_mmps = 10 },
		RB2 = { trigger = "one primary pump lost", target_pctFP = 60, rate_pctpmin = 60 },
		RB3 = { trigger = "one or both turbines lost", target = "bypass-limited", rate_pctpmin = 20 },
	}, "§9.5 runback table"),

	rodBlocks = spec({
		periodBelow_s = 30,
		powerToFlowAbove = 1.05,
		reactivityBalanceBeyond_pcm = 50,
		anyAssemblyRodBlock = true,
		regulatingOutOfBandDuringBankMove = true,
		moreThanOneBankSelected = true,
	}, "§9.5 rod withdrawal blocks"),

	-- §9.6 operating limits relevant to the M1 slice (the rest arrive with their systems)
	lco = spec({
		["LCO-1"] = { limit = "SSS: at least 8 of 9 rods operable", operableMin = 8, action = "Hot shutdown", completion_gridh = 6 },
		["LCO-4"] = { limit = "DND: at least 4 of 6 channels", operableMin = 4, action = "<= 30 %FP", powerCap_pctFP = 30, completion_gridh = 12 },
		["LCO-5"] = { limit = "Reactivity balance within ±50 pcm", band_pcm = 50, action = "No power increase; explain", completion_gridh = 1 },
		["LCO-6"] = { limit = "Primary plugging temperature <= 180 °C", max_C = 180, action = "<= 60 %FP and restore", powerCap_pctFP = 60, completion_gridh = 24 },
		["LCO-10"] = { limit = "Ramp <= 1 %/min above 40%", rate_pctpmin = 1, rateApproved_pctpmin = 3, above_pctFP = 40, action = "Report" },
		["LCO-11"] = { limit = "Hot pool rate of change <= 1.5 K/min, trips excepted", rate_Kpmin = 1.5, action = "Report and fatigue review" },
	}, "§9.6"),
}
