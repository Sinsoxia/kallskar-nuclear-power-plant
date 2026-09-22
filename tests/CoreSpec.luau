--!strict
--[[
	Core verification (spec §3.1–§3.3, §2.4, §3.5, D-030).

	The last test in this file is the one that matters: the whole plant wired together, a rod withdrawn, and
	power rising and then being arrested by its own Doppler feedback. Everything above it checks a piece of that.
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
local Systems = Root:WaitForChild("Systems")
local Core = require(Systems:WaitForChild("Core")) :: any

local KEL = Config.Units.kelvinOffset_K
local DT = 1 / Config.Clocks.fast_Hz
local T0 = Config.Feedback.referenceTemperature_K
local BUDGET = Config.Reactivity.budget_pcm
local EXCESS = BUDGET.requiredExcessAt230AllRodsOut - BUDGET.isothermal230to375
local PSS_WORTH = Config.Rods.regulating.worthTotal_pcm + Config.Rods.shim.worthTotal_pcm
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

local function make(worth_pcm: number?)
	local ch = Channels.new()
	ch:declareExternal("rods.indicativeWorth_pcm", worth_pcm or PSS_WORTH)
	ch:declareExternal("fuel.coreAverage_K", T0)
	ch:declareExternal("fuel.coreAverageSodium_K", T0)
	ch:declareExternal("pools.mixedCoreOutlet_K", T0)
	ch:declareExternal("pools.coreInlet_K", T0)
	ch:declareExternal("pools.hotPool_K", T0)
	ch:declareExternal("pools.coldPool_K", T0)
	local sys = System.new(Core)
	sys:init({
		config = Config,
		channels = ch:port(Core.spec),
		log = EventLog.new(Config, { sim = 0, grid = 0 }),
		bus = Bus.new(),
	})
	return sys, ch
end

local function run(sys: any, seconds: number)
	for _ = 1, math.floor(seconds / DT + 0.5) do
		sys:step(DT)
	end
end

return {
	["the plant boots subcritical, where §3.3's budget says it should"] = function(t)
		local sys, ch = make()
		run(sys, 1)
		-- ρ = excess − inserted worth, with the excess at the §3.2 reference from §3.3's own budget line
		t.near(ch:get("core.rho_pcm"), EXCESS - PSS_WORTH, 1, "every PSS rod in is −3,826 pcm")
		t.near(ch:get("core.k"), 1 / (1 - (EXCESS - PSS_WORTH) / 1e5), 1e-6, "k = 0.963")
		t.ok(ch:get("core.power_pctFP") > 0, "but not zero power: the startup source is multiplied")
		t.log(string.format("boot: ρ %.0f pcm, k %.5f, power %.2e %%FP, SR would read %.0f cps",
			ch:get("core.rho_pcm"), ch:get("core.k"), ch:get("core.power_pctFP"),
			Config.Instruments.sourceRangeConstant_cps / (1 - ch:get("core.k"))))
	end,

	["D-030: a shut-down plant sits at the bottom of §3.5's wide range span"] = function(t)
		local sys, ch = make()
		run(sys, 200) -- let the subcritical multiplication settle
		local floor = Config.Instruments.wideRange.span_pctFP[1]
		t.near(ch:get("core.power_pctFP"), floor, floor * 0.05, "on scale, and only just")
		t.ok(ch:get("core.power_pctFP") > 0, "an instrument reading zero would tell the crew nothing")
	end,

	["withdrawing worth raises reactivity, and the core answers (§3.1)"] = function(t)
		local sys, ch = make()
		run(sys, 50)
		local before = ch:get("core.power_pctFP")
		-- take out 3,000 pcm of rod worth: still subcritical, but much closer
		ch:setExternal("rods.indicativeWorth_pcm", PSS_WORTH - 3000)
		run(sys, 50)
		t.near(ch:get("core.rho_pcm"), EXCESS - PSS_WORTH + 3000, 1, "ρ follows the worth removed")
		-- equilibrium subcritical multiplication is n = q/(−ρ), so the power rises by the ratio of the two ρ
		local ratio = (PSS_WORTH - EXCESS) / (PSS_WORTH - 3000 - EXCESS)
		t.near(ch:get("core.power_pctFP") / before, ratio, ratio * 0.1,
			string.format("subcritical multiplication lifts the power %.1f×", ratio))
		t.ok(ch:get("core.k") < 1, "still subcritical")

		-- exactly critical: worth equals the excess
		ch:setExternal("rods.indicativeWorth_pcm", EXCESS)
		run(sys, 5)
		t.near(ch:get("core.rho_pcm"), 0, 1, "critical when the inserted worth equals the excess")
		t.near(ch:get("core.k"), 1, 1e-5)
	end,

	["Doppler pushes back when the fuel heats up (§3.2)"] = function(t)
		local sys, ch = make(EXCESS) -- critical
		run(sys, 10)
		t.near(ch:get("core.rho_pcm"), 0, 1, "on the critical point")
		-- the fuel heats toward its full power average; §3.2's Doppler constant is negative
		ch:setExternal("fuel.coreAverage_K", Config.Feedback.fullPowerFuelAverage_K)
		run(sys, 60) -- past the Doppler lag
		local rho = ch:get("core.rho_pcm")
		t.ok(rho < -300, "hot fuel is a large negative reactivity")
		local breakdown = sys:getState().feedback
		t.ok(breakdown.doppler < 0, "and it is the Doppler term that did it")
		t.log(string.format("fuel at %.0f K: ρ %.0f pcm, of which Doppler %.0f",
			Config.Feedback.fullPowerFuelAverage_K, rho, breakdown.doppler))
		-- §3.3's power defect is the whole feedback at full power conditions, −844 pcm
		t.ok(math.abs(breakdown.doppler) < BUDGET.powerDefect, "Doppler is most of the power defect, not all")
	end,

	["the pin power adds up, and is shaped the way §2.4 says"] = function(t)
		local sys, ch = make(EXCESS)
		run(sys, 1)
		-- seat it at a power worth looking at; the shape is what is under test, not the kinetics
		sys:setPower(1.0)
		sys:step(DT)
		local power = ch:get("core.fuelPinPower_W")
		local total = 0
		for _, p in power do
			total += p
		end
		-- whatever the kinetics says the power is, 95 % of it lands in the pins (§2.4)
		local expected = ch:get("core.thermalPower_W") * Config.Core.powerSplit.fuelPins
		t.near(total / expected, 1, 1e-6, "§2.4: 95 % of thermal power is deposited in the pins")
		t.eq(#power, 301 * Config.PhysicsModel.axial.fuelLayers, "one value per fuel node")

		-- axial peak-to-average is §2.4's 1.22
		local L = Config.PhysicsModel.axial.fuelLayers
		local peak, mean = 0, 0
		for l = 1, L do
			peak = math.max(peak, power[l])
			mean += power[l] / L
		end
		--[[
			§2.4's 1.22 is the CONTINUOUS peak-to-average, which the shape hits exactly at z = 0. Ten layer
			averages cannot quite reach it, because the hottest layer is centred 0.1 of the height off the peak
			rather than on it — 1.211 against 1.22, and that 0.8 % is discretisation, not a wrong shape.
		]]
		t.near(peak / mean, Config.Core.limits.peaking.axial, 0.02, "§2.4: axial peaking 1.22")

		-- radial shape is §2.5's flow zoning: assembly 1 is ring 0, in zone I
		local perAssembly = expected / 301
		local share = 0
		for l = 1, L do
			share += power[l]
		end
		t.near(share / perAssembly, Config.Core.flow.zones[1].flowFactor, 0.01,
			"§2.5's zone I factor of 1.12 is that assembly's share of the power")
	end,

	["the prompt jump limit is reported rather than silently exceeded (§14.2)"] = function(t)
		local sys, ch = make(EXCESS)
		run(sys, 5)
		t.ok(not ch:get("core.promptCritical"))
		-- yank out far more worth than §3.4's rods could ever remove at once
		ch:setExternal("rods.indicativeWorth_pcm", EXCESS - 1000)
		run(sys, 1)
		t.ok(ch:get("core.promptCritical"), "§14.2: the prompt jump form stops being valid, and says so")
	end,

	["the whole plant, wired together: a rod out, power up, Doppler catches it"] = function(t)
		--[[
			This is the test that says the physics is operable. Core, FuelThermal, Pools, PrimaryPumps, IHX and
			RodDrives, stepped in registry order with nothing imposed from outside except the secondary boundary.
			An operator withdraws one regulating rod; power climbs, the fuel heats, and Doppler arrests it.
		]]
		local Registry = require(Framework:WaitForChild("Registry")) :: any
		local channels = Channels.new()
		for name, initial in {
			["program.mode"] = 3,
			["site.seismic_g"] = 0,
			["electrical.boards11kV"] = 3,
			["turbine.bypassAvailable"] = true,
			["pools.levelDeviation_m"] = 0,
		} do
			channels:declareExternal(name, initial)
		end
		local registry = Registry.new(channels)
		for _, class in {
			Core,
			require(Systems:WaitForChild("FuelThermal")) :: any,
			require(Systems:WaitForChild("Pools")) :: any,
			require(Systems:WaitForChild("PrimaryPumps")) :: any,
			require(Systems:WaitForChild("IHX")) :: any,
			require(Systems:WaitForChild("RodDrives")) :: any,
			require(Systems:WaitForChild("Detectors")) :: any,
			require(Systems:WaitForChild("Protection")) :: any,
			require(Systems:WaitForChild("AutoControls")) :: any,
		} do
			registry:add(System.new(class))
		end
		registry:resolve()
		local log = EventLog.new(Config, { sim = 0, grid = 0 })
		registry:initAll({ config = Config, log = log, bus = Bus.new() })
		t.ok(true, "every read has a writer: the plant resolves")

		local function advance(seconds: number)
			for _ = 1, math.floor(seconds / DT + 0.5) do
				for _, sys in registry.systems do
					if sys.spec.lane == "fast" then
						sys:step(DT)
					end
				end
			end
		end

		advance(5)
		t.ok(channels:get("core.k") < 1, "the plant boots shut down")
		t.ok(channels:get("core.rho_pcm") < -3000, "deeply subcritical, as §3.4's margins say")
		t.ok(not channels:get("protection.tripped"), "and sits there quietly")

		local function systemNamed(name: string)
			for _, sys in registry.systems do
				if sys.spec.name == name then
					return sys
				end
			end
			return nil
		end
		local rods, core, ihx = systemNamed("RodDrives"), systemNamed("Core"), systemNamed("IHX")

		--[[
			Throttle the secondary first. At hot standby the core makes no power, but six IHXs pulling toward a
			320 °C secondary cool the plant about 5 K a minute — and once the rods come out, D-004's Mode 3
			inhibit lifts and the core-inlet-low trip is armed against a falling inlet. Cooling yourself into a
			trip is exactly what the plant does if you skip this, which is worth knowing and not worth testing
			around.
		]]
		for l = 1, 3 do
			ihx:applyCommand(OPERATOR, { kind = "loop.secondary.flow", tag = tostring(l), value = 60 })
		end

		--[[
			Place the rods as an INITIAL CONDITION rather than moving them there. Teleporting them is a 3,745 pcm
			step in one tick, which the wide range reads as a 0.04 s period and §9.5 trips on — correctly, since
			rods move at 5 mm/s and 410 mm of travel takes 82 seconds. The plant cannot make that step, so neither
			should the test. Regulating rods mid-band and shims at 700 mm is 1,863 pcm of worth against 1,874 of
			excess: eleven pcm from critical.
		]]
		for _, drive in rods.drives do
			if drive.set == "RR" then
				drive.position_mm = 500
				drive.demand_mm = 500
			elseif drive.set ~= "SSR" then
				drive.position_mm = 700
				drive.demand_mm = 700
			end
		end
		rods:publish()
		core:setPower(0.2) -- 20 %FP, with fuel that has not caught up yet
		for _, sys in registry.systems do
			if sys.spec.name == "Detectors" then
				sys.started = false -- the period meter starts here rather than differentiating a jump
			end
		end
		advance(1)
		t.near(channels:get("core.rho_pcm"), 0, 30, "seated within thirty pcm of critical")

		--[[
			First half: the fuel is still at hot zero power temperature, so there is no power defect holding the
			core down yet. As it heats, Doppler answers — and the core settles where the rods and the feedback
			balance. That fall IS the feedback working, and it is the same −844 pcm power defect §3.3 budgets for.
		]]
		advance(240)
		local settled = channels:get("core.power_pctFP")
		local feedback = channels:get("core.feedback_pcm")
		t.log(string.format("fuel heated to %.0f K: power settled at %.3f %%FP, feedback %.0f pcm, ρ %.1f",
			channels:get("fuel.coreAverage_K"), settled, feedback, channels:get("core.rho_pcm")))
		--[[
			The core settles where the rods' eleven pcm is cancelled by feedback, which at this power is only a
			few tens of pcm: §3.3's −844 pcm power defect is the value at FULL power, and the Doppler term is
			logarithmic in fuel temperature. A small excess buys a small power, and that is the whole shape of
			the reactivity balance an operator works with.
		]]
		t.ok(feedback < -10, "its own feedback pushed back as the fuel heated")
		t.ok(settled < 20, "so the core came down off the power it was seated at")
		t.ok(not channels:get("protection.tripped"), "without tripping")

		-- Second half: an operator withdraws one regulating rod, at §3.4's 5 mm/s
		rods:applyCommand(OPERATOR, { kind = "rod.move", tag = "RR1", value = 600 })
		advance(180)
		local power = channels:get("core.power_pctFP")
		t.log(string.format("100 mm of RR1 (%.0f pcm): power %.3f → %.3f %%FP, fuel %.0f K, ρ %.1f pcm",
			channels:get("rods.indicativeWorth_pcm"), settled, power, channels:get("fuel.coreAverage_K"),
			channels:get("core.rho_pcm")))
		t.ok(power > settled, "power rose when the rod came out")
		t.ok(channels:get("core.feedback_pcm") < feedback, "and the feedback answered again, harder")
		t.ok(math.abs(channels:get("core.rho_pcm")) < 50, "the core is holding near critical, not running away")
		t.ok(not channels:get("protection.tripped"), "and it is still not tripping")
	end,
}
