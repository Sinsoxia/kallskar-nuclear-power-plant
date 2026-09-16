--!strict
-- Unit conventions and conversion constants. Spec §0.1.
-- Config keys carry their unit as a suffix (_K, _C, _pcm, _MPa, _s, _mm, _kgps, _MWt ...) so units are visible at
-- every use site. Physics code converts once at init.
local P = require(script.Parent.Provenance)
local spec, cited = P.spec, P.cited

return {
	kelvinOffset_K = cited(273.15, "SI: T[K] = T[°C] + 273.15"),
	secondsPerDay_s = cited(86400, "SI day"),
	secondsPerHour_s = cited(3600, "SI hour"),
	pcmPerUnit = spec(1e5, "§0.1: pcm = 1e-5 Δk/k"),
	dollar_pcm = spec(360, "§0.1: $1 = 360 pcm"),
	rodTravel_mm = spec(1100, "§0.1: rod position 0–1,100 mm withdrawn from fully inserted"),
	ratedThermal_MWt = spec(2380, "§0.1, §1.1: %FP is of 2,380 MWt"),
	grossRated_MWe = spec(1000, "§1.1: 2 × 500 MWe at 5.0 kPa"),
}
