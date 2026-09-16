--!strict
--[[
	Whole-core reactivity feedback. Spec §3.2.
	In the 3D model these act through node cross sections and geometry; the coefficients below are the whole-core
	values the 3D model must reproduce, and the point-kinetics oracle uses them directly.
	Reference state for the oracle is hot zero power, isothermal at 375 °C (648 K), as in spec file 20's derivation.
]]
local P = require(script.Parent.Provenance)
local spec = P.spec

return {
	-- ρ_Doppler = constant × ln(T_fuel / T_ref), temperatures in K, driven by fuel average temperature
	doppler = spec({ constant_pcm = -900, lag_s = 4, drivenBy = "fuelAverage" }, "§3.2"),
	fuelAxialExpansion = spec({ coefficient_pcmpK = -0.12, lag_s = 4, drivenBy = "fuelAverage" }, "§3.2"),
	sodiumDensity = spec({ coefficient_pcmpK = 0.40, lag_s = 0.2, drivenBy = "coreAverageSodium" }, "§3.2"),
	loadPads = spec({ coefficient_pcmpK = -0.35, lag_s = 15, drivenBy = "coreOutlet" }, "§3.2"),
	diagrid = spec({ coefficient_pcmpK = -0.80, lag_s = 120, drivenBy = "coreInlet" }, "§3.2"),
	drivelines = spec({ coefficient_pcmpK = -0.30, lag_s = 90, drivenBy = "upperHotPool" }, "§3.2"),
	vessel = spec({ coefficient_pcmpK = 0.15, lag_s = 900, drivenBy = "coldPool" }, "§3.2: rods effectively withdraw"),

	-- Reference state of the oracle (hot zero power, isothermal)
	referenceTemperature_K = spec(648, "file 20 REACTIVITY line: T_ref = 648 K (375 °C)"),
	fullPowerFuelAverage_K = spec(1380, "file 20 REACTIVITY line: 1,380 K = §3.2 fuel average ≈ 1,107 °C"),

	-- Derived whole-core quantities (validation targets)
	targets = spec({
		voidWorth_pcm = 1800,
		isothermalCoefficientAt375_pcmpK = -2.41,
		isothermalDefect230to375_pcm = -376,
		fuelAverageAt100_C = 1107,
		powerDefect_pcm = -844,
		powerDefectParts_pcm = { doppler = -680, axial = -88, sodium = 37, pads = -61, drivelines = -51 },
		powerCoefficientFirst5s_pcmpPctFP = -5.3,
		powerCoefficientAfter2min_pcmpPctFP = -6.4,
		inletSensitivity_pctFPpK = -0.4,
		inletSensitivitySettle_min = { 2, 3 },
		vesselDriftAfterLongSpell_min = 15,
	}, "§3.2 derived-quantity table"),
}
