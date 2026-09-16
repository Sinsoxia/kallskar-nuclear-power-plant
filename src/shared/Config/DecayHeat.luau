--!strict
--[[
	Decay heat. Spec §3.6:  P/P₀ = coefficient × (t^exponent − (t + T_op)^exponent), t and T_op in seconds.
	The delayed-neutron fission tail comes out of the kinetics model and must NOT be added here.
]]
local P = require(script.Parent.Provenance)
local spec = P.spec

return {
	coefficient = spec(0.066, "§3.6"),
	exponent = spec(-0.2, "§3.6"),
	referenceOperatingTime_EFPD = spec(160, "§3.6: table computed for T_op = 160 EFPD"),

	-- Validation table (% of 2,380 MWt) for T_op = 160 EFPD
	table = spec({
		time_s = { 1, 10, 60, 600, 1800, 3600, 14400, 86400, 259200, 604800 },
		percent = { 6.35, 3.92, 2.66, 1.59, 1.23, 1.04, 0.73, 0.43, 0.30, 0.22 },
		megawatts = { 151, 93, 63, 38, 29, 25, 17, 10, 7, 5 },
	}, "§3.6 table"),
}
