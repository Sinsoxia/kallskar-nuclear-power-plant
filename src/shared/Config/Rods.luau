--!strict
-- Rod systems. Spec §3.4 (and the Curie latch from §9.5).
-- Positions are mm withdrawn from fully inserted, 0–1,100 mm (§0.1). Active fuel height is 1,000 mm (§2.1).
local P = require(script.Parent.Provenance)
local spec, decision = P.spec, P.decision

return {
	regulating = spec({
		count = 3,
		worthEach_pcm = 100,
		worthTotal_pcm = 300,
		normalBand_mm = { 250, 750 }, -- Rev A4: the old 400–700 band was 163 pcm against the 250 pcm §3.3 reserves
		speed_mmps = 5,
		scramSystem = "PSS",
		scram90Percent_s = 1.2,
	}, "§3.4"),

	shim = spec({
		count = 18,
		banks = {
			A = { count = 6, worthEach_pcm = 400 },
			B = { count = 6, worthEach_pcm = 300 },
			C = { count = 6, worthEach_pcm = 200 },
		},
		worthTotal_pcm = 5400,
		speedSingle_mmps = 2,
		speedBank_mmps = 1,
		-- Rev A4: bank A (6 × 400 pcm) peaks at 4.8 pcm/s at 1 mm/s, above the 4 pcm/s interlock
		speedBankA_mmps = 0.8,
		speedRunbackDriveIn_mmps = 10,
		scramSystem = "PSS",
		scram90Percent_s = 1.2,
	}, "§3.4"),

	secondaryShutdown = spec({
		count = 9,
		worthEach_pcm = 330,
		worthTotal_pcm = 2970,
		parked_mm = 1100,
		speedWithdrawOnly_mmps = 5,
		scram90Percent_s = 2.0,
	}, "§3.4"),
	curieLatch = spec({ releaseSodium_C = 640, thermalLag_s = 20 }, "§9.5: SSR Curie-point latch"),

	shutdownMargins_pcm = spec({
		pssAllInMostReactiveStuck230BOC = -3050,
		sssAloneAt375 = -1100,
		sssOneStuckAt375 = -770,
	}, "§3.4"),

	interlocks = spec({
		maxWithdrawalRate_pcmps = 4,
		allRegulatingOutFromCritical_pcm = 300,
		allRegulatingOutPeriod_s = 2.5,
	}, "§3.4: one rod or one bank moves at a time"),
	regulatingMoveOneAtATime = decision(true, "D-006"),

	-- W(d) = W_total × (d − sin(2πd)/2π), d = inserted fraction of the 1,000 mm active height.
	-- In the 3D model this is a validation target, not a formula the code uses.
	worthCurve = spec({
		insertedFraction = { 0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0 },
		worthFraction = { 0.0, 0.006, 0.049, 0.149, 0.306, 0.500, 0.694, 0.851, 0.951, 0.994, 1.0 },
	}, "§3.4 table (0 and 1 end points from the formula)"),
}
