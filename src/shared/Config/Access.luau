--!strict
-- Multiplayer access rules, accountability and resets. Spec §10.7, §14.4, §14.6, file 01 §3.
local P = require(script.Parent.Provenance)
local spec, tuning = P.spec, P.tuning

return {
	panelReach_studs = tuning(10, "§10.7: any player within reach of the panel (≈ 10 studs)"),
	criticalMinimumPlaytime_h = tuning(3, "§10.7: suggested 3 h, not final"),

	-- Controls that also require the minimum playtime (§10.7). Command kinds are matched against this list.
	criticalControls = {
		"reactor.trip.manual",
		"sss.trip.manual",
		"turbine.trip",
		"breaker.open.400kV",
		"breaker.open.11kV",
		"loop.drain",
		"sg.section.dump",
		"plant.mode.change",
		-- D-055: taking a trip out of service, or overriding a runback, is as consequential as a trip
		"pss.bypass",
		"runback.clear",
	},

	voteKick = tuning({ minimumVoters = 3, majorityOfOthers = true, onlyIfTripUnjustified = true }, "§10.7 (safeguard proposed, not confirmed)"),

	reset = spec({ countdown_s = 60, typedConfirmation = true, ownerOnly = true }, "§14.6, file 01 §3"),
	resetReturnsTo = tuning("hotStandbyBOCAsNew", "§14.6"),
	saveFormatVersioned = spec(true, "§14.6: version the save format so later spec changes can migrate old plants"),
}
