--!strict
-- Clocks and tick rates. Spec §0.2, §3.7, §14.1, §14.2.
local P = require(script.Parent.Provenance)
local spec, tuning = P.spec, P.tuning

return {
	-- §0.2 clock rates (multiples of real time)
	physicsRate = spec(1, "§0.2: physics ×1 real time, always"),
	lowPowerAccelRate = tuning(10, "§0.2: ×10 in Modes 3–5 only, no P1/P2 alarms, all manned desks agree"),
	lowPowerAccelModes = spec({ 3, 4, 5 }, "§0.2"),
	gridRate = tuning(12, "§0.2: one grid day = 2 h real"),
	slowProcessRate = tuning(360, "§0.2: burnup, impurity ingress, cold traps, hydrogen drift, heater failures"),

	-- §14.1 loop rates
	fast_Hz = spec(10, "§14.1: kinetic amplitude, fuel, pools, IHXs, pumps, valves, protection"),
	slow_Hz = spec(1, "§14.1: trace heating, cold traps, chemistry, fatigue, dispatcher, hydrogen"),
	replicateFast_Hz = spec(5, "§14.1: fast gauges over UnreliableRemoteEvent"),
	replicateSlow_Hz = spec(1, "§14.1: slow gauges and core map"),

	-- §3.7 / §14.2 flux shape cadence
	shapeSteady_s = tuning(2.0, "§3.7: shape step every 2 s at steady power"),
	shapeFast_s = tuning(0.5, "§3.7: every 0.5 s while reactivity changes faster than 5 pcm/s"),
	shapeFastTrigger_pcmps = tuning(5, "§3.7"),
	shapeAfterTrip_s = tuning(60, "§3.7: fast cadence for 60 s after any trip"),
	shapeSliceBudget_s = tuning(0.004, "§14.2: coroutine yields once the frame has used 4 ms"),
}
