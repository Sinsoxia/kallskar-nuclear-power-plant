--!strict
--[[
	The plant's system classes, in no particular order (the Registry decides run order from each spec).
	Adding a system to the plant = add its class here. Nothing else in the core loop changes.

	Contract reminder (Framework/System): init(ctx) must put the system in its initial condition every time it is
	called; Main calls it again after an owner reset.
]]
local classes: { any } = {
	require(script.Core),
	require(script.FuelThermal),
	require(script.Pools),
	require(script.PrimaryPumps),
	require(script.IHX),
	require(script.RodDrives),
	require(script.Detectors),
	require(script.Protection),
	require(script.AutoControls),
	require(script.DecayHeat),
}

return classes
