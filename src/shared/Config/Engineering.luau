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

	devStrictState = engineering(true, "Studio-only strict metatable on system state catches key typos; disabled on live servers"),
}
