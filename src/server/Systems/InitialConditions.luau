--!strict
--[[
	InitialConditions — seat the whole plant in steady state at a power (plan: initial conditions).
	==================================================================================================

	A real startup climbs ten decades and then takes the plant up in load over hours. Integration tests, the
	developer panel and, later, the scenario director all need to begin at power instead, and placing the rods
	alone does not do it: with the fuel still at hot zero power, the power defect the rods were placed against
	does not exist yet, and the core sees its absence as a reactivity step — at 20 %FP about three quarters of β.

	So every state is seated, each against what the systems before it have published:

	  1. the pumps at §9.2's flow for the power, and the heat sink at the same load
	  2. the decay heat on §3.6's reference history at that power (D-037), then the core at the power, so its
	     pin powers are spread with the decay heat already in them
	  3. the pools around §9.2's 375 °C core inlet, so the fuel sees its inlet
	  4. the fuel settled to its exact steady state (FuelThermal.settle)
	  5. the pools again, now mixing the settled fuel outlet into the hot pool
	  6. the exchangers solved against that hot pool
	  7. the feedback seated on those temperatures, and the rods placed where it is exactly cancelled
	  8. the rods latched, the core seated critical with equilibrium precursors, the flow auto's filter started on
	     the power, the period meter restarted, and the mode declared per §9.1

	Nothing here is a number of its own. The operating point is §9.2's, each steady state is its system's own,
	and the rod positions are wherever ρ comes out zero.
]]
local PartLoad = require(script.Parent.PartLoad)

local InitialConditions = {}

export type Seated = {
	power_pctFP: number,
	flow_pct: number,
	feedback_pcm: number,
	worth_pcm: number,
	mode: number,
}

local REQUIRED = { "Core", "FuelThermal", "Pools", "PrimaryPumps", "IHX", "RodDrives", "DecayHeat" }

function InitialConditions.seatAtPower(
	systems: { [string]: any },
	channels: any,
	config: any,
	power_pctFP: number
): (Seated?, string?)
	for _, name in REQUIRED do
		if not systems[name] then
			return nil, `the plant has no {name}`
		end
	end
	if not (power_pctFP > 0 and power_pctFP <= 100) then
		return nil, "a seat needs a power above 0 and up to 100 %FP"
	end
	if channels:get("protection.tripped") then
		return nil, "the reactor is tripped; reset it first"
	end
	local core, fuel, pools, pumps, ihx, rods =
		systems.Core, systems.FuelThermal, systems.Pools, systems.PrimaryPumps, systems.IHX, systems.RodDrives
	local flow_pct = PartLoad.flow_pct(config, power_pctFP)
	local inlet_K = config.Program.partLoad.coreInlet_C + config.Units.kelvinOffset_K

	-- 1–2: the flow, the load, the decay heat and the power. Decay heat first: thermal power is prompt fission
	-- heat plus decay heat, and it balances the load only when the decay heat is the reference history's share.
	local ok, why = pumps:seat(flow_pct)
	if not ok then
		return nil, why
	end
	ihx:setLoad(power_pctFP)
	systems.DecayHeat:seat(power_pctFP / 100)
	core:setPower(power_pctFP / 100)

	-- 3–6: the thermal state, inlet first, then the fuel, then the hot pool it feeds
	pools:seat(inlet_K)
	local _, converged = fuel:settle()
	if not converged then
		return nil, "the fuel did not settle to a steady state"
	end
	pools:seat(inlet_K)
	ihx:step(0)

	-- 7–8: the rods where the seated feedback is exactly cancelled, then the core critical on them
	local feedback = core:seatFeedback()
	local worth = core:criticalWorth_pcm()
	ok, why = rods:seatCritical(worth)
	if not ok then
		return nil, why
	end
	core:latchRods()
	core:seatPower(power_pctFP / 100)
	if systems.AutoControls then
		systems.AutoControls:seat(power_pctFP)
	end
	if systems.Detectors then
		systems.Detectors.started = false -- the period meter starts here rather than differentiating the seat
	end
	local mode = if power_pctFP > config.Program.modes[1].powerAbove_pctFP then 1 else 2
	channels:setExternal("program.mode", mode)
	return {
		power_pctFP = power_pctFP,
		flow_pct = flow_pct,
		feedback_pcm = feedback,
		worth_pcm = worth,
		mode = mode,
	}
end

return InitialConditions
