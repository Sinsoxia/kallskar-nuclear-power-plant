--!strict
-- Neutron instrumentation. Spec §3.5 (OD-3: log wide-range, no range switching).
local P = require(script.Parent.Provenance)
local spec, tuning = P.spec, P.tuning

return {
	sourceRange = spec({ channels = 3, span_cps = { 1, 1e6 } }, "§3.5: pulse-counting fission chambers"),
	-- SR count rate ≈ K / (1 − k)
	sourceRangeConstant_cps = tuning(15, "§3.5: SR ≈ 15/(1−k) cps"),
	sourceRangeAllRodsIn_cps = spec(250, "§3.5: about 250 cps with all rods in"),
	sourceRangeHighVoltageOffAbove_pctFP = spec(1e-3, "§3.5: SR HV off once WR reads above 1e-3 %FP"),

	wideRange = spec({ channels = 3, span_pctFP = { 1e-8, 150 } }, "§3.5: fission chambers, pulse + Campbell, log output"),
	powerRange = spec({ channels = 4, span_pctFP = { 0, 125 } }, "§3.5: DC ionisation chambers, 4 quadrants"),
	period = spec({ span_s = { -100, 3 } }, "§3.5: derived from SR and WR"),

	delayedNeutronDetectors = spec({ channels = 6 }, "§3.5: one at each IHX primary inlet"),
	dndBackground_cps = tuning(40, "§3.5: background ≈ 40 cps"),
}
