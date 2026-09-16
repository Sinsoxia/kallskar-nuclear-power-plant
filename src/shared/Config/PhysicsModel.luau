--!strict
-- 3D multigroup space-time kinetics model: mesh, solver settings and validation targets. Spec §3.7, §14.2.
local P = require(script.Parent.Provenance)
local spec, tuning, decision = P.spec, P.tuning, P.decision

return {
	energyGroups = tuning(4, "§3.7: 4 groups, raised to 6 once performance allows"),
	energyGroupsGoal = spec(6, "§3.7"),
	precursorGroups = spec(6, "§3.7: 6 precursor groups in every fuel node"),

	-- Radial mesh: one node per hexagonal position in rings 0–12
	radialLastRing = spec(12, "§3.7"),
	radialNodes = spec(469, "§3.7: 469 positions (fuel, rods, reflector)"),
	albedoOutsideLastRing = tuning(true, "§3.7: albedo boundary outside ring 12"),

	-- Axial mesh: 2 lower reflector, 10 fuel at 100 mm, 2 upper plenum and structure
	axial = tuning({
		lowerLayers = 2,
		fuelLayers = 10,
		fuelLayerHeight_mm = 100,
		upperLayers = 2,
	}, "§3.7: 14 layers"),

	flowUnknowns = spec(26264, "§3.7: 469 × 14 × 4"),

	solver = {
		colours = decision(3, "D-001: hex mesh needs 3 colours, not red-black"),
		sweepsPerGroup = tuning({ 4, 8 }, "§14.2: 4–8 SOR sweeps per group, warm-started"),
		fissionSourceTolerance = spec(1e-4, "§14.2: repeat until the fission source changes by less than 1e-4"),
		typicalOuterPasses = spec({ 2, 3 }, "§14.2: usually 2–3 passes with a warm start"),
		faceCorrection = decision("dhat", "D-002: FD kernel + D-hat face corrections, default 0"),
	},

	materialSets = {
		"innerFuel",
		"outerFuel",
		"regulatingAbsorber",
		"shimAbsorber",
		"ssrAbsorber",
		"sodiumFollower",
		"steelReflector",
		"lowerStructure",
		"upperPlenum",
	},

	feedbackGrid = tuning({
		fuelTemperatureRange_K = { 600, 2000 },
		fuelTemperaturePoints = 4,
		sodiumDensityPoints = 3, -- including voided
		burnupPoints = 3,
	}, "§3.7 feedback tables"),

	-- §3.7 validation targets (the whole table is marked †)
	validation = tuning({
		betaEff_pcm = { target = 360, relTol = 0.05 },
		generationTime_s = { target = 4.0e-7, relTol = 0.05 },
		bankWorth_pcm = {
			A = { target = 2400, relTol = 0.10 },
			B = { target = 1800, relTol = 0.10 },
			C = { target = 1200, relTol = 0.10 },
			RR = { target = 300, relTol = 0.10 },
			SSR = { target = 2970, relTol = 0.10 },
		},
		singleRodCurve_absTolOfTotal = 0.05,
		peakingRadial = { target = 1.20, absTol = 0.03 },
		peakingAxial = { target = 1.22, absTol = 0.03 },
		dopplerConstant_pcm = { target = -900, relTol = 0.10 },
		voidWorth_pcm = { target = 1800, relTol = 0.15, centralRingsPositive = true, outerRingsNegative = true },
		powerDefect_pcm = { target = -844, relTol = 0.10 },
		isothermalCoefficient_pcmpK = { target = -2.41, relTol = 0.10 },
		excessReactivity230BOC_pcm = { target = 2250, absTol = 150 },
	}, "§3.7 validation targets"),
}
