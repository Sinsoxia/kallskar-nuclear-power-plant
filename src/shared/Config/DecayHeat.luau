--!strict
--[[
	Decay heat. Spec §3.6:  P/P₀ = coefficient × (t^exponent − (t + T_op)^exponent), t and T_op in seconds.
	The delayed-neutron fission tail comes out of the kinetics model and must NOT be added here.
]]
local P = require(script.Parent.Provenance)
local spec, derived, decision = P.spec, P.derived, P.decision

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

	--[[
		The formula as a state model that follows any power history (D-037): dHᵢ/dt = λᵢ(Eᵢ·P − Hᵢ), fitted so the
		kernel Σ Eᵢλᵢe^(−λᵢτ) reproduces §3.6's 0.0132·τ^−1.2. A 0.4-decade grid from 0.4 s to 3.2 years; within
		6·10⁻⁵ of the formula over 1 s–7 d after 160 EFPD, against the table's own precision of 7.9·10⁻⁴, and
		within 5.3·10⁻⁴ for every history it was checked on, 10 s to 640 EFPD, including seven it was not fitted to.
	]]
	groups = derived({
		{ lambda_ps = 2.51188643150958, fraction = 0.016656132252857617 }, -- 1/λ 0.398 s
		{ lambda_ps = 1.0, fraction = 0.013107774676548778 }, -- 1 s
		{ lambda_ps = 0.3981071705534972, fraction = 0.011059336978483162 }, -- 2.51 s
		{ lambda_ps = 0.15848931924611134, fraction = 0.009140018973108179 }, -- 6.31 s
		{ lambda_ps = 0.0630957344480193, fraction = 0.007630275380384767 }, -- 15.8 s
		{ lambda_ps = 0.025118864315095794, fraction = 0.006331213332066559 }, -- 39.8 s
		{ lambda_ps = 0.01, fraction = 0.005275996797679278 }, -- 1.67 min
		{ lambda_ps = 0.003981071705534969, fraction = 0.004380555373232711 }, -- 4.19 min
		{ lambda_ps = 0.0015848931924611126, fraction = 0.003650456859968945 }, -- 10.5 min
		{ lambda_ps = 0.000630957344480193, fraction = 0.0030308630669138976 }, -- 26.4 min
		{ lambda_ps = 0.00025118864315095795, fraction = 0.0025248874789420128 }, -- 1.11 h
		{ lambda_ps = 0.0001, fraction = 0.0020969646127200954 }, -- 2.78 h
		{ lambda_ps = 3.9810717055349695e-05, fraction = 0.00174716268863891 }, -- 6.98 h
		{ lambda_ps = 1.5848931924611107e-05, fraction = 0.0014497394801063566 }, -- 17.5 h
		{ lambda_ps = 6.30957344480193e-06, fraction = 0.0012111036838068784 }, -- 1.83 d
		{ lambda_ps = 2.511886431509577e-06, fraction = 0.0009980801167816548 }, -- 4.61 d
		{ lambda_ps = 1e-06, fraction = 0.000846390601233005 }, -- 11.6 d
		{ lambda_ps = 3.981071705534969e-07, fraction = 0.00067854581073212 }, -- 29.1 d
		{ lambda_ps = 1.584893192461111e-07, fraction = 0.0006028764999226125 }, -- 73 d
		{ lambda_ps = 6.30957344480193e-08, fraction = 0.0004378198183462377 }, -- 183 d
		{ lambda_ps = 2.511886431509577e-08, fraction = 0.0004188866755305189 }, -- 461 d
		{ lambda_ps = 1e-08, fraction = 0.0005583063945271752 }, -- 1,160 d
	}, "tools/derive/decay_heat.py"),

	--[[
		What the core has at boot and after an owner reset: §14.6's "hot standby at beginning of cycle". That is the
		end of a 160 EFPD cycle at full power (§2.3, and §3.6's own reference history) followed by §2.3's refuelling
		outage, "a timed wait, 30 min real", on §0.2's ×1 physics clock: 1.23 % of rated, 29 MW (D-036).
	]]
	boot = decision({ historyPower_frac = 1, shutdown_s = 1800 }, "D-036"),
}
