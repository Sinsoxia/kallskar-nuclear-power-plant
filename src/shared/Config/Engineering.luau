--!strict
-- Software parameters that are not plant physics. Each carries its reasoning (provenance kind "engineering").
local P = require(script.Parent.Provenance)
local spec, engineering = P.spec, P.engineering

return {
	serverFrame_s = engineering(1 / 60, "Roblox servers step at 60 Hz"),
	fastTickBudgetP99_s = engineering(0.005, "16.7 ms frame − 4 ms shape slice (§14.2) leaves >half the frame for replication, engine physics and players"),
	maxCatchUpStepsPerFrame = engineering(5, "needing more than 0.5 s of simulated time in one frame means the server is badly overloaded; drop and log instead of spiralling"),
	unreliablePacketBudget_bytes = engineering(800, "conservative ceiling for one UnreliableRemoteEvent payload until the real limit is measured"),

	-- §14.1: 331 core-map temperatures as u16 at 0.05 K → 662 bytes. Stored in kelvin with zero offset:
	-- 65535 × 0.05 = 3276.75 K covers everything from frozen sodium to fuel melting.
	coreMapResolution_K = spec(0.05, "§14.1"),
	coreMapBytesPerValue = spec(2, "§14.1: u16"),

	-- Sequence-of-events log (§10.7, §14.6)
	eventLogCapacity = engineering(5000, "bounded memory; a busy 13-player crew at one action per 10 s fills ~720 per grid day (2 h), so this holds several grid days plus alarms"),
	eventLogPersisted = engineering(500, "most recent entries kept in the private-server save; keeps the save well under DataStore's 4 MB value limit"),

	-- Command intake (anti-spam and input hygiene at the network boundary)
	commandRate_perSecond = engineering(10, "sustained rate per player; faster than anyone can operate physical panel controls"),
	commandBurst = engineering(20, "short bursts, e.g. stepping a rod selector quickly"),
	commandStringMax = engineering(64, "longest command kind / tag / panel id accepted from a client"),
	commandArgsMax = engineering(8, "most extra arguments any control needs"),
	commandRefusalNote_s = engineering(10, "commands refused before routing (throttled, malformed, unhandled) are counted and noted at most once per 10 s per player, so a player adds at most commandRate_perSecond + 0.1 = 10.1 log records/s, all but 0.1/s of them control attempts §10.7 requires recorded, and one who sends only refused commands adds 0.1/s"),

	-- Persistence (§14.6)
	saveInterval_s = engineering(60, "one DataStore write per minute per server stays far inside Roblox's 60 + 10×players per-minute budget"),
	resetConfirmationPhrase = engineering("RESET KALLSKAR", "typed confirmation required by §14.6 before the owner reset countdown starts"),
}
