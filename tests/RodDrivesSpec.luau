--!strict
--[[
	RodDrives verification (spec §3.4, §9.5).

	Every expected number is §3.4's: the worth table, the six drive speeds, the 4 pcm/s withdrawal interlock, the
	90 %-in-1.2 s PSS scram and 2.0 s SSR scram, and the shutdown-margin case of "the most reactive rod stuck".
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
local Bus = require(Framework:WaitForChild("Bus")) :: any
local RodDrives = require(Root:WaitForChild("Systems"):WaitForChild("RodDrives")) :: any

local RODS = Config.Rods
local TRAVEL = Config.Units.rodTravel_mm
local ACTIVE = Config.Core.geometry.fissileHeight_mm
local DT = 1 / Config.Clocks.fast_Hz
local PSS_WORTH = RODS.regulating.worthTotal_pcm + RODS.shim.worthTotal_pcm
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

local function make(block: boolean?)
	local ch = Channels.new()
	ch:declareExternal("protection.rodWithdrawalBlock", block == true)
	ch:declareExternal("protection.runback", "")
	ch:declareExternal("protection.rodRunback", false)
	local sys = System.new(RodDrives)
	local bus = Bus.new()
	sys:init({
		config = Config,
		channels = ch:port(RodDrives.spec),
		log = EventLog.new(Config, { sim = 0, grid = 0 }),
		bus = bus,
	})
	return sys, ch, bus
end

local function run(sys: any, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
	end
end

-- Put a set of drives at a stated position without driving them there.
local function place(sys: any, set: string, position_mm: number)
	for _, drive in sys.drives do
		if drive.set == set then
			drive.position_mm = position_mm
			drive.demand_mm = position_mm
		end
	end
	sys:publish()
end

local function find(sys: any, name: string)
	return sys.drives[sys:indexOf(name)]
end

return {
	["boots in hot standby with all thirty drives where §3.4 parks them"] = function(t)
		local sys, ch = make()
		local s = sys:getState()
		t.eq(#s.drives, 30, "§2.2: 3 regulating, 18 shim, 9 secondary shutdown")
		local counts = {}
		for _, d in s.drives do
			counts[d.set] = (counts[d.set] or 0) + 1
		end
		t.eq(counts.RR, RODS.regulating.count)
		t.eq(counts.SM_A + counts.SM_B + counts.SM_C, RODS.shim.count)
		t.eq(counts.SSR, RODS.secondaryShutdown.count)
		t.eq(find(sys, "RR1").position_mm, 0, "D-024: PSS rods boot fully inserted")
		t.eq(find(sys, "SSR1").position_mm, RODS.secondaryShutdown.parked_mm, "§3.4: SSRs parked at 1,100 mm")
		t.ok(ch:get("rods.allPssInserted"), "which is Mode 3, hot standby")
		t.ok(not ch:get("rods.scrammed"), "and not a scram")
		-- every PSS rod fully in, every SSR fully out: the indicative worth is the whole PSS worth
		t.near(ch:get("rods.indicativeWorth_pcm"), PSS_WORTH, 1e-9, "§3.4: 300 + 5,400 pcm")
	end,

	["the worth curve reproduces §3.4's table"] = function(t)
		local sys = make()
		local curve = RODS.worthCurve
		local rr = find(sys, "RR1")
		for i, d in curve.insertedFraction do
			-- d is the inserted fraction of the 1,000 mm active height; position is withdrawal from 1,100 mm
			rr.position_mm = math.clamp(TRAVEL - d * ACTIVE, 0, TRAVEL)
			rr.demand_mm = rr.position_mm
			sys:publish()
			local worth = sys.worth_pcm - PSS_WORTH + RODS.regulating.worthEach_pcm -- isolate RR1's contribution
			t.near(worth / RODS.regulating.worthEach_pcm, curve.worthFraction[i], 0.0006,
				string.format("W(%.1f)", d))
		end
	end,

	["a single rod moves at its §3.4 speed, and only one thing moves at a time"] = function(t)
		local sys = make()
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 500 }).ok, "withdraw RR1")
		local second = sys:applyCommand(OPERATOR, { kind = "rod.move", target = "SMA1", value = 100 })
		t.ok(not second.ok, "§3.4: one rod or one bank at a time")
		run(sys, 10)
		t.near(find(sys, "RR1").position_mm, 10 * RODS.regulating.speed_mmps, 1e-9, "5 mm/s for ten seconds")
		run(sys, 90)
		t.near(find(sys, "RR1").position_mm, 500, 1e-9, "arrives at the demand")
		t.eq(sys:getState().selection, nil, "and releases the selection")
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.move", target = "SMA1", value = 100 }).ok, "freeing the next move")
	end,

	["rod auto changing rods in one tick stops the rod it let go of (D-059)"] = function(t)
		--[[
			Rod auto can release a move and start another in the same tick: a move whose error has turned round
			beyond the band is released, and the rod for the other direction chosen at once. Its selection then goes
			from one rod to another with no empty tick between, and that is still a release: the first rod stops
			where it is, and the second gets the selection.
		]]
		local ch = Channels.new()
		ch:declareExternal("protection.rodWithdrawalBlock", false)
		ch:declareExternal("protection.runback", "")
		ch:declareExternal("protection.rodRunback", false)
		ch:declareExternal("auto.rodSelected", "")
		ch:declareExternal("auto.rodDemand_mm", 0)
		local sys = System.new(RodDrives)
		sys:init({
			config = Config,
			channels = ch:port(RodDrives.spec),
			log = EventLog.new(Config, { sim = 0, grid = 0 }),
			bus = Bus.new(),
		})
		place(sys, "RR", 500)
		ch:setExternal("auto.rodSelected", "RR2")
		ch:setExternal("auto.rodDemand_mm", 470)
		run(sys, 1)
		local rr2 = find(sys, "RR2").position_mm
		t.ok(rr2 < 500 and rr2 > 470, `RR2 on its way in ({rr2} mm)`)
		ch:setExternal("auto.rodSelected", "RR1")
		ch:setExternal("auto.rodDemand_mm", 520)
		run(sys, 1)
		t.eq(find(sys, "RR2").position_mm, rr2, "RR2 stopped the tick rod auto let it go")
		t.ok(find(sys, "RR1").position_mm > 500, "and RR1 is moving instead")
	end,

	["a bank moves at its own slower speed (§3.4)"] = function(t)
		for bank, speed in { A = RODS.shim.speedBankA_mmps, B = RODS.shim.speedBank_mmps, C = RODS.shim.speedBank_mmps } do
			local sys = make()
			t.ok(sys:applyCommand(OPERATOR, { kind = "rod.bank", target = bank, value = 1000 }).ok, `withdraw bank {bank}`)
			run(sys, 10)
			local moved = 0
			for _, d in sys:getState().drives do
				if d.bank == bank then
					t.near(d.position_mm, 10 * speed, 1e-9, `bank {bank} rod at {speed} mm/s`)
					moved += 1
				end
			end
			t.eq(moved, 6, `all six of bank {bank} move together`)
		end
	end,

	["§3.4's speeds keep the withdrawal rate inside the 4 pcm/s interlock"] = function(t)
		-- mid-stroke is where differential worth peaks: d = 0.5 is position 1,100 − 500 = 600 mm
		local sys, ch = make()
		place(sys, "SM_A", TRAVEL - 0.5 * ACTIVE)
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.bank", target = "A", value = TRAVEL }).ok, "withdraw bank A")
		local worst = 0
		for _ = 1, 100 do
			sys:step(DT)
			worst = math.max(worst, ch:get("rods.withdrawalRate_pcmps"))
		end
		-- 6 × 400 pcm peaks at 2 × 2,400 / 1,000 mm = 4.8 pcm/mm, and 4.8 × 0.8 mm/s = 3.84 pcm/s
		t.near(worst, 4.8 * RODS.shim.speedBankA_mmps, 0.02, "bank A peaks at 3.84 pcm/s")
		t.ok(worst < RODS.interlocks.maxWithdrawalRate_pcmps, "inside §3.4's 4 pcm/s")
		t.log(string.format("bank A peak withdrawal rate %.2f pcm/s against the %.0f pcm/s interlock",
			worst, RODS.interlocks.maxWithdrawalRate_pcmps))
	end,

	["the interlock clamps a speed that would break it, rather than trusting the table"] = function(t)
		local sys, ch = make()
		place(sys, "SM_A", TRAVEL - 0.5 * ACTIVE)
		sys.banks.A.speed = 2 -- far above §3.4's 0.8 mm/s
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.bank", target = "A", value = TRAVEL }).ok, "withdraw bank A")
		local before = find(sys, "SMA1").position_mm
		local worst = 0
		for _ = 1, 20 do
			sys:step(DT)
			worst = math.max(worst, ch:get("rods.withdrawalRate_pcmps"))
		end
		local achieved = (find(sys, "SMA1").position_mm - before) / (20 * DT)
		t.ok(worst <= RODS.interlocks.maxWithdrawalRate_pcmps + 1e-6, "the rate is still inside the interlock")
		-- 4 pcm/s ÷ 4.8 pcm/mm = 0.833 mm/s, which is exactly why §3.4 rounds bank A down to 0.8
		t.near(achieved, RODS.interlocks.maxWithdrawalRate_pcmps / 4.8, 0.01, "clamped to 0.833 mm/s")
	end,

	["a rod withdrawal block refuses withdrawal and stops one in progress (§9.5)"] = function(t)
		local sys, ch = make()
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 800 }).ok, "start withdrawing")
		run(sys, 5)
		local caught = find(sys, "RR1").position_mm
		ch:setExternal("protection.rodWithdrawalBlock", true)
		run(sys, 5)
		t.near(find(sys, "RR1").position_mm, caught, 1e-9, "stopped where the block found it")
		t.eq(sys:getState().selection, nil, "and the selection is dropped")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR2", value = 500 }).ok,
			"no new withdrawal while blocked")
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 0 }).ok,
			"but insertion is never blocked")
	end,

	["the SSRs withdraw only (§3.4)"] = function(t)
		local sys = make()
		t.ok(not sys:applyCommand(OPERATOR, { kind = "rod.move", target = "SSR1", value = 500 }).ok,
			"they cannot be driven in")
		local ssr = find(sys, "SSR1")
		ssr.position_mm = 600
		ssr.demand_mm = 600
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.move", target = "SSR1", value = 900 }).ok,
			"but they can be withdrawn")
	end,

	["scram: 90 % in §3.4's 1.2 s for the PSS and 2.0 s for the SSR"] = function(t)
		local sys, ch, bus = make()
		local trips = {}
		bus:subscribe("Trip", function(p)
			table.insert(trips, p)
		end)
		place(sys, "RR", TRAVEL)
		place(sys, "SM_A", TRAVEL)
		place(sys, "SM_B", TRAVEL)
		place(sys, "SM_C", TRAVEL)
		t.ok(sys:scram("both", "test"), "scram fires")
		t.ok(not sys:scram("both", "again"), "and is idempotent, so a second signal cannot restart it")
		t.eq(#trips, 1, "one Trip on the bus")

		run(sys, RODS.regulating.scram90Percent_s)
		local ninety = 0.1 * TRAVEL -- 90 % inserted means 10 % of travel left
		t.near(find(sys, "RR1").position_mm, ninety, 1, "PSS is 90 % in at 1.2 s")
		t.near(find(sys, "SMA1").position_mm, ninety, 1, "shim with it")
		t.ok(find(sys, "SSR1").position_mm > ninety, "the SSR is slower, as §3.4 allows")
		run(sys, RODS.secondaryShutdown.scram90Percent_s - RODS.regulating.scram90Percent_s)
		t.near(find(sys, "SSR1").position_mm, ninety, 1, "SSR is 90 % in at 2.0 s")
		run(sys, 0.5)
		t.eq(find(sys, "RR1").position_mm, 0, "and everything is fully in shortly after")
		t.eq(find(sys, "SSR1").position_mm, 0)
		t.ok(ch:get("rods.scrammed"))
		t.ok(ch:get("rods.allPssInserted"))
		t.near(ch:get("rods.indicativeWorth_pcm"), PSS_WORTH + RODS.secondaryShutdown.worthTotal_pcm, 1e-9,
			"all 8,670 pcm of rod worth is in the core")
	end,

	["a scram cannot be withdrawn from until it is reset, and reset needs every rod in"] = function(t)
		local sys = make()
		place(sys, "RR", TRAVEL)
		sys:scram("PSS", "test")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 500 }).ok, "no withdrawal")
		local early = sys:applyCommand(OPERATOR, { kind = "rod.reset" })
		t.ok(not early.ok, "reset is refused while rods are still out")
		run(sys, 2)
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.reset" }).ok, "allowed once they are all in")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "rod.reset" }).ok, "and not twice")
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 100 }).ok, "rods move again")
	end,

	["RD-STUCK: the most reactive rod stuck is §3.4's shutdown margin case"] = function(t)
		local sys, ch = make()
		for _, drive in sys.drives do
			drive.position_mm = TRAVEL
			drive.demand_mm = TRAVEL
		end
		local fault = RodDrives.faults[1]
		t.eq(fault.id, "RD-STUCK")
		fault.arm(sys, { rod = "SMA1" }) -- a bank A rod: 400 pcm, the most reactive single rod
		sys:scram("PSS", "test")
		run(sys, 2)
		t.eq(find(sys, "SMA1").position_mm, TRAVEL, "the stuck rod has not moved")
		t.ok(not ch:get("rods.allPssInserted"), "so the PSS is not fully in")
		-- §3.4 quotes its margin for exactly this case: 5,700 − 400 = 5,300 pcm of the PSS gets in
		t.near(ch:get("rods.indicativeWorth_pcm"), PSS_WORTH - RODS.shim.banks.A.worthEach_pcm, 1e-9,
			"5,300 pcm inserted, which with §3.3's 2,250 pcm excess is §3.4's −3,050 pcm margin")
		fault.clear(sys, { rod = "SMA1" })
		run(sys, 2)
		t.eq(find(sys, "SMA1").position_mm, 0, "clearing the fault lets it finish falling")
	end,

	["runback drives the shim banks in at 10 mm/s and takes the plant off the operator"] = function(t)
		local sys = make()
		for _, drive in sys.drives do
			if drive.system == "PSS" then
				drive.position_mm = 800
				drive.demand_mm = 800
			end
		end
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 1000 }).ok, "an operator move")
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.runback", value = 1 }).ok, "then a runback")
		run(sys, 10)
		t.near(find(sys, "SMA1").position_mm, 800 - 10 * RODS.shim.speedRunbackDriveIn_mmps, 1e-9,
			"§3.4: shim drives in at 10 mm/s")
		t.near(find(sys, "RR1").position_mm, 800, 1e-9, "the regulating rods are not part of a runback")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 900 }).ok,
			"and the operator cannot move rods during one")
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.runback", value = 0 }).ok, "release it")
		run(sys, 10)
		t.near(find(sys, "SMA1").position_mm, 700, 1e-9, "the drive-in stops where it was released")
	end,

	["a Protection runback holds the operator off for its whole length, and drives in only when asked (D-046)"] = function(t)
		local sys, ch = make()
		place(sys, "RR", 800)
		for _, drive in sys.drives do
			if drive.system == "PSS" then
				drive.position_mm, drive.demand_mm = 800, 800
			end
		end
		ch:setExternal("protection.runback", "RB2")
		ch:setExternal("protection.rodRunback", true)
		run(sys, 1)
		t.near(find(sys, "SMA1").position_mm, 800 - RODS.shim.speedRunbackDriveIn_mmps, 1e-9, "a second of drive-in")
		-- a hold tick: the power is under the runback's demand, so the shims hold, and the runback is still on
		ch:setExternal("protection.rodRunback", false)
		run(sys, 1)
		t.near(find(sys, "SMA1").position_mm, 800 - RODS.shim.speedRunbackDriveIn_mmps, 1e-9, "the shims hold")
		t.ok(not sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 900 }).ok,
			"and the operator is held off between drive-in ticks")
		ch:setExternal("protection.runback", "")
		run(sys, DT)
		t.ok(sys:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 900 }).ok,
			"once the runback is over the rods are the operator's again")
	end,

	["the regulating band is published for §9.5's rod block"] = function(t)
		local sys, ch = make()
		place(sys, "RR", 500)
		t.ok(ch:get("rods.regulatingInBand"), "500 mm is inside the 250–750 mm band")
		place(sys, "RR", 800)
		t.ok(not ch:get("rods.regulatingInBand"), "800 mm is not")
		place(sys, "RR", RODS.regulating.normalBand_mm[1])
		t.ok(ch:get("rods.regulatingInBand"), "the band edge counts as in")
	end,
}
