--!strict
-- Neutron instrumentation. Spec §3.5 (OD-3: log wide-range, no range switching).
local P = require(script.Parent.Provenance)
local spec, tuning, decision = P.spec, P.tuning, P.decision

return {
	sourceRange = spec({ channels = 3, span_cps = { 1, 1e6 } }, "§3.5: pulse-counting fission chambers"),
	-- SR count rate ≈ K / (1 − k)
	sourceRangeConstant_cps = tuning(15, "§3.5: SR ≈ 15/(1−k) cps"),
	sourceRangeAllRodsIn_cps = spec(250, "§3.5: about 250 cps with all rods in"),
	sourceRangeHighVoltageOffAbove_pctFP = spec(1e-3, "§3.5: SR HV off once WR reads above 1e-3 %FP"),

	wideRange = spec({ channels = 3, span_pctFP = { 1e-8, 150 } }, "§3.5: fission chambers, pulse + Campbell, log output"),
	powerRange = spec({ channels = 4, span_pctFP = { 0, 125 } }, "§3.5: DC ionisation chambers, 4 quadrants"),
	period = spec({ span_s = { -100, 3 } }, "§3.5: derived from SR and WR"),

	--[[
		The spec gives no noise figures for the neutron channels. The counting channels need none — their noise is
		Poisson, σ = √(R/τ), with no free parameter at all. The two analogue channel types do need a fractional
		precision, and those two numbers are the only choices here. The three filter time constants are then
		derived, not chosen: each is the shortest that keeps instrument noise 5σ short of the §9.5 setpoint it
		could otherwise fake (tools/derive/detectors.py). Unfiltered, 0.5 % power-range noise differentiated over
		one 0.1 s tick is 7 %FP/s against a 10 %FP/s flux-rate trip — the plant would trip on nothing.
	]]
	noise = decision({
		wideRangeRelative = 0.02,      -- Campbell-mode MSV: roughly constant fraction across the range
		powerRangeRelative = 0.005,    -- DC ionisation chamber current
		ratemeterAveraging_s = 2,      -- effective averaging time of the SR and DND ratemeters
		fluxRateFilter_s = 0.5,        -- ≥ 0.35 s keeps noise 5σ below the §9.5 10 %FP/s trip
		periodFilter_s = 5,            -- ≥ 4.24 s keeps noise 5σ outside the §9.5 30 s rod block
	}, "D-025"),
	sourceRangeHighVoltageOnBelow_pctFP = decision(1e-4, "D-025: a decade of hysteresis under §3.5's cut-off"),

	delayedNeutronDetectors = spec({ channels = 6 }, "§3.5: one at each IHX primary inlet"),
	dndBackground_cps = tuning(40, "§3.5: background ≈ 40 cps"),
}
