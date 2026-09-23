--!strict
--[[
	DecayHeat verification (spec §3.6, D-036, D-037).

	§3.7 makes §3.6 a target the model must reproduce, not an input to it, so the first test runs the groups
	through a trip from §3.6's own reference history and compares every table entry. Two tolerances are used, and
	neither is chosen here:
	  - the table's printed precision, ±0.005 percentage points
	  - tools/derive/decay_heat.py's acceptance, 0.005 / 6.35 = 7.87·10⁻⁴ relative to the formula: the table's
	    precision at its finest entry, which the fit was required to meet for every history it was checked on
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Config = require(Kallskar:WaitForChild("Config")) :: any
local Root = ServerScriptService:WaitForChild("Kallskar")
local Framework = Root:WaitForChild("Framework")
local System = require(Framework:WaitForChild("System")) :: any
local Channels = require(Framework:WaitForChild("Channels")) :: any
local EventLog = require(Framework:WaitForChild("EventLog")) :: any
local DecayHeat = require(Root:WaitForChild("Systems"):WaitForChild("DecayHeat")) :: any

local DH = Config.DecayHeat
local EFPD = 86400
local T_REF = DH.referenceOperatingTime_EFPD * EFPD
local FIT = 0.005 / DH.table.percent[1] -- the derivation's acceptance: the table's precision at its finest entry
local DT = 1 / Config.Clocks.fast_Hz

-- §3.6 as written, for a trip from constant power after T_op seconds
local function formula(t: number, T_op: number): number
	return DH.coefficient * (t ^ DH.exponent - (t + T_op) ^ DH.exponent)
end

local function make(power_pctFP: number?)
	local ch = Channels.new()
	ch:declareExternal("core.power_pctFP", power_pctFP or 0)
	local sys = System.new(DecayHeat)
	sys:init({ config = Config, channels = ch:port(DecayHeat.spec), log = EventLog.new(Config, { sim = 0, grid = 0 }) })
	return sys, ch
end

-- Advance to an absolute time since `from`, in ticks of `dt`
local function runTo(sys: any, now: number, target: number, dt: number): number
	while now < target - 1e-9 do
		local step = math.min(dt, target - now)
		sys:step(step)
		now += step
	end
	return now
end

return {
	["a trip after §3.6's 160 EFPD at full power reproduces every entry of its table"] = function(t)
		local sys, ch = make(0)
		sys:seatHistory(1, T_REF, 0)
		local now = 0
		for i, time_s in DH.table.time_s do
			-- 0.1 s ticks through the first hour, as the plant runs; the exact update is exact at any tick with P
			-- held, so beyond an hour a minute's tick reaches seven days without a million steps
			now = runTo(sys, now, time_s, if time_s <= 3600 then DT else 60)
			local got = ch:get("decay.fraction") * 100
			t.near(got, DH.table.percent[i], 0.005, `{time_s} s: §3.6 table {DH.table.percent[i]} %`)
			t.near(got, formula(time_s, T_REF) * 100, formula(time_s, T_REF) * 100 * FIT, `{time_s} s: the formula`)
			t.near(ch:get("decay.heat_W") / 1e6, DH.table.megawatts[i], 0.5, `{time_s} s: {DH.table.megawatts[i]} MW`)
		end
	end,

	["it follows any history, not only §3.6's: an hour at full power from nothing, then a trip"] = function(t)
		local sys, ch = make(100)
		sys:seatHistory(0, 0, 0)
		local now = runTo(sys, 0, 3600, DT)
		ch:setExternal("core.power_pctFP", 0)
		local trip = now
		for _, after in { 1, 10, 60, 600 } do
			now = runTo(sys, now, trip + after, DT)
			local expect = formula(after, 3600)
			t.near(ch:get("decay.fraction"), expect, expect * FIT, `{after} s after an hour at power`)
		end
	end,

	["steady power on the reference history holds decay at f_ref of that power"] = function(t)
		local sys, ch = make(20)
		sys:seat(0.2)
		local fRef = DecayHeat.referenceFraction(Config)
		t.near(ch:get("decay.fraction"), 0.2 * fRef, 1e-15, "seated at f_ref × P")
		runTo(sys, 0, 10, DT)
		-- only the groups slower than 160 EFPD are still filling, at λ·E·P ≲ 10⁻¹² of rated per second
		t.near(ch:get("decay.fraction"), 0.2 * fRef, 0.2 * fRef * 1e-8, "and stays there while the power does")
		t.log(string.format("f_ref = %.6f: %.3f %% of steady thermal power is decay heat", fRef, fRef * 100))
	end,

	["the exact update is the same on a 1 s tick as on ten 0.1 s ticks (§0.2's ×10)"] = function(t)
		local fine, fch = make(50)
		local coarse, cch = make(50)
		fine:seat(0.2)
		coarse:seat(0.2)
		runTo(fine, 0, 30, DT)
		runTo(coarse, 0, 30, 1)
		t.near(cch:get("decay.fraction"), fch:get("decay.fraction"), fch:get("decay.fraction") * 1e-12,
			"power held over the tick, so the tick length does not matter")
	end,

	["it boots at beginning of cycle, after the outage (§14.6, D-036)"] = function(t)
		local _, ch = make(0)
		local expect = formula(DH.boot.shutdown_s, T_REF)
		t.near(ch:get("decay.fraction"), expect, expect * FIT, "the §3.6 curve 30 min after 160 EFPD at full power")
		t.near(ch:get("decay.fraction") * 100, 1.23, 0.005, "the table's 30 min row")
		t.log(string.format("boot decay heat %.3f %% = %.1f MW", ch:get("decay.fraction") * 100, ch:get("decay.heat_W") / 1e6))
	end,

	["a negative power reading drives nothing"] = function(t)
		local sys, ch = make(-5)
		sys:seatHistory(0, 0, 0)
		runTo(sys, 0, 10, DT)
		t.near(ch:get("decay.fraction"), 0, 0, "no negative decay heat")
	end,

	["the inventory saves and loads, and a save from another group set is left alone"] = function(t)
		local sys, ch = make(0)
		sys:seat(0.6)
		local saved = sys:save()
		local before = ch:get("decay.fraction")
		local other, och = make(0)
		other:load(saved, 1)
		t.near(och:get("decay.fraction"), before, 0, "restored exactly")
		local third, tch = make(0)
		local bootFraction = tch:get("decay.fraction")
		third:load({ groups = { 1, 2, 3 } }, 1)
		t.near(tch:get("decay.fraction"), bootFraction, 0, "a different group count keeps the boot state")
	end,
}
