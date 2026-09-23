--!strict
--[[
	PartLoad — §9.2's part-load programme as the functions its table is generated from.
	====================================================================================

	One module, because two systems act on the same programme: AutoControls holds the core outlet and primary flow
	to it, and the M1 heat sink in IHX sets the secondary cold leg and secondary flow from it. If each carried its
	own copy, the reactor and the steam plant could disagree about what 20 %FP means.

	With r = P/Q, the ratio of power to programmed primary flow:

	  core outlet     = 375 + 175·r        550 °C at full load, 462 °C at 20 %FP on the 40 % floor
	  secondary cold  = 375 −  55·r        320 °C at full load, 348 °C at 20 %FP, 375 °C with no load

	Every row of the §9.2 table follows from those two lines and the flow programme below; PartLoadSpec checks
	each one.

	**Secondary flow follows primary flow.** §9.2 gives the secondary hot and cold legs but not the secondary
	flow, and the heat balance supplies it: ṁ_s ∝ P / (T_hot − T_cold), and T_hot − T_cold = (145 + 55)·r = 200·r,
	so ṁ_s / ṁ_s,rated = P / r = Q. Checked against the table's own temperature columns: at 20 %FP,
	0.2 × 200 / (448 − 348) = 0.40, and at 5 %FP, 0.05 × 200 / (404 − 364) = 0.25 — the primary column both times.
	That is what §6.6's 25 % minimum evaporator flow looks like from the sodium side.
]]
local PartLoad = {}

--[[
	§9.2's flow programme: flow follows power down to the 40 % floor, and D-007 ramps it from 25 % to 40 %
	between 5 and 10 %FP rather than stepping.
]]
function PartLoad.flow_pct(cfg: any, power_pctFP: number): number
	local p = cfg.Program.partLoad
	local ramp = cfg.Program.partLoadFlowRamp_pctFP
	if power_pctFP >= ramp[2] then
		return math.clamp(power_pctFP, p.minimumFlowAtOrAbove10_pct, 100)
	end
	if power_pctFP <= ramp[1] then
		return p.minimumFlowAtOrBelow5_pct
	end
	local t = (power_pctFP - ramp[1]) / (ramp[2] - ramp[1])
	return p.minimumFlowAtOrBelow5_pct + t * (p.minimumFlowAtOrAbove10_pct - p.minimumFlowAtOrBelow5_pct)
end

-- Core outlet for a power and a flow, both as fractions of rated. It takes the actual flow, not the programmed
-- one, so a plant on the wrong flow gets the outlet its P/Q really implies (D-003).
function PartLoad.outlet_C(cfg: any, powerFraction: number, flowFraction: number): number
	local p = cfg.Program.partLoad
	local r = if flowFraction > 1e-3 then powerFraction / flowFraction else 0
	return p.coreInlet_C + p.outletSlope_K * r
end

-- The secondary cold leg, which is the IHX secondary inlet, for a steam-plant load on the programmed flow
function PartLoad.secondaryCold_C(cfg: any, load_pct: number): number
	local p = cfg.Program.partLoad
	local r = (load_pct / 100) / (PartLoad.flow_pct(cfg, load_pct) / 100)
	return p.coreInlet_C + p.secondaryColdSlope_K * r
end

-- Secondary flow as a fraction of rated: the programmed primary flow, by the heat balance in the header
function PartLoad.secondaryFlow_frac(cfg: any, load_pct: number): number
	return PartLoad.flow_pct(cfg, load_pct) / 100
end

return PartLoad
