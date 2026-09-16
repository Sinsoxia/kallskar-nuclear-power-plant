--!strict
--[[
	The plant's system classes, in no particular order (the Registry decides run order from each spec).
	Adding a system to the plant = add its class here. Nothing else in the core loop changes.

	Contract reminder (Framework/System): init(ctx) must put the system in its initial condition every time it is
	called; Main calls it again after an owner reset.
]]
local classes: { any } = {
	-- M1 reactor slice systems are added here as they are built (Core, FuelThermal, Pools, PrimaryPumps, IHX,
	-- RodDrives, Protection, AutoControls, DecayHeat).
}

return classes
