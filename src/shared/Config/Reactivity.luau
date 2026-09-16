--!strict
-- Beginning-of-cycle reactivity budget and burnup. Spec §3.3.
local P = require(script.Parent.Provenance)
local spec = P.spec

return {
	budget_pcm = spec({
		isothermal230to375 = 376,
		powerDefect = 844,
		burnupOverCycle = 480,
		operatingMargin = 250,
		uncertaintyAllowance = 300,
		requiredExcessAt230AllRodsOut = 2250,
	}, "§3.3"),
	kEffAt230AllRodsOut = spec(1.023, "§3.3"),
	burnupRate_pcmpEFPD = spec(3.0, "§3.3: 160 EFPD × 3.0 pcm/EFPD = 480 pcm"),
}
