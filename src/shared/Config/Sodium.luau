--!strict
--[[
	Sodium property correlation coefficients (Fink–Leibowitz). Spec Appendix A. T in kelvin.
	  density  ρ  = a + b(1 − T/Tc) + c(1 − T/Tc)^0.5                     [kg/m³]
	  cp          = a + bT + cT² + d/T²                                   [kJ/kg·K]
	  k           = a + bT + cT² + dT³                                    [W/m·K]
	  μ           = exp(a + b·ln T + c/T)                                 [Pa·s]
	  p_sat       = exp(a + b/T + c·ln T)                                 [MPa]
	The functions live in shared/Props/Sodium (Config holds data only).
]]
local P = require(script.Parent.Provenance)
local spec = P.spec

return {
	density = spec({ a = 219, b = 275.32, c = 511.58, criticalTemperature_K = 2503.7 }, "Appendix A"),
	specificHeat = spec({ a = 1.6582, b = -8.479e-4, c = 4.4541e-7, d = -2992.6 }, "Appendix A"),
	conductivity = spec({ a = 124.67, b = -0.11381, c = 5.5226e-5, d = -1.1842e-8 }, "Appendix A"),
	viscosity = spec({ a = -6.4406, b = -0.3958, c = 556.835 }, "Appendix A"),
	vapourPressure = spec({ a = 11.9463, b = -12633.73, c = -0.4672 }, "Appendix A"),

	-- Appendix A table, used to verify the functions
	table = spec({
		temperature_C = { 98, 200, 300, 375, 450, 520, 550, 600, 700, 800, 900, 950 },
		density_kgpm3 = { 925.6, 903.0, 880.5, 863.5, 846.2, 830.0, 822.9, 811.2, 787.3, 763.0, 738.3, 725.7 },
		specificHeat_kJpkgK = { 1.383, 1.343, 1.309, 1.289, 1.272, 1.261, 1.258, 1.254, 1.252, 1.259, 1.274, 1.286 },
		conductivity_WpmK = { 89.4, 81.9, 75.4, 70.9, 66.8, 63.2, 61.8, 59.5, 55.3, 51.5, 48.0, 46.4 },
		viscosity_mPas = { 0.688, 0.452, 0.341, 0.290, 0.254, 0.229, 0.220, 0.207, 0.186, 0.169, 0.156, 0.151 },
		vapourPressure_MPa = { 1.6e-11, 2.2e-8, 2.1e-6, 2.6e-5, 1.8e-4, 8.2e-4, 1.4e-3, 3.4e-3, 1.4e-2, 4.6e-2, 0.120, 0.182 },
	}, "Appendix A table"),
}
