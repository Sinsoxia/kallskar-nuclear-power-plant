--!strict
--[[
	Core verification (spec §3.1–§3.3, §2.4, §3.5, D-030).

	The plant-level tests at the end are the ones that matter: the whole plant wired together holding hot standby,
	a rod withdrawn at power and caught by its own Doppler feedback, a scram that leaves the decay heat on §3.6's
	curve, a seat that holds §9.2's operating point, and the reactor following the steam plant's load. Everything
	above them checks a piece of that.
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
local Kinetics = require(Systems:WaitForChild("Core"):WaitForChild("Kinetics")) :: any
local Sodium = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Props"):WaitForChild("Sodium")) :: any
local InitialConditions = require(Systems:WaitForChild("InitialConditions")) :: any

local KEL = Config.Units.kelvinOffset_K
local DT = 1 / Config.Clocks.fast_Hz
local T0 = Config.Feedback.referenceTemperature_K
local BUDGET = Config.Reactivity.budget_pcm
local EXCESS = BUDGET.requiredExcessAt230AllRodsOut - BUDGET.isothermal230to375
local PSS_WORTH = Config.Rods.regulating.worthTotal_pcm + Config.Rods.shim.worthTotal_pcm
local OPERATOR = { kind = "player" :: any, name = "Aqua", userId = 1 }

-- The delayed groups as fractions, and β, for the bounds the kinetics itself gives (D-049)
local PCM = 1e-5
local LAMBDA = Config.Kinetics.groups.lambda_ps
local BETAS, BETA = {}, 0
for i, b in Config.Kinetics.groups.beta_pcm do
	BETAS[i] = b * PCM
	BETA += b * PCM
end

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

--[[
	The whole M1 plant as Main registers it, with Main's external inputs, stepped in registry order. Returns the
	registry, its channels, an advance(seconds) and a lookup by system name.
]]
local function plant()
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
	for _, class in require(Systems) :: any do
		registry:add(System.new(class))
	end
	registry:resolve()
	local log = EventLog.new(Config, { sim = 0, grid = 0 })
	registry:initAll({ config = Config, log = log, bus = Bus.new() })

	--[[
		Yields every 10 s of plant time. The plant-level tests run for minutes of it, because that is how long a
		pool takes to mix at part flow, and Studio's script timeout would otherwise end a test for being honest.
	]]
	local function advance(seconds: number)
		for i = 1, math.floor(seconds / DT + 0.5) do
			-- the resolved order, as the Scheduler runs it, so a readsLagged edge means here what it means live
			for _, sys in registry.order.fast do
				sys:step(DT)
			end
			if i % 100 == 0 then
				task.wait()
			end
		end
	end
	local byName = {}
	for _, sys in registry.systems do
		byName[sys.spec.name] = sys
	end
	return registry, channels, advance, byName
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
		local settle = 200
		run(sys, settle) -- let the subcritical multiplication settle
		local floor = Config.Instruments.wideRange.span_pctFP[1]
		--[[
			D-049: the core boots at n = 0 with the D-030 source q. Its first step prompt-jumps to q/(β − ρ), which is
			−ρ/(β − ρ) of the equilibrium q/(−ρ), and the rest, β/(β − ρ), closes no slower than the slowest mode,
			the inhour period at the shut-down ρ of −3,826 pcm, so that decay bounds what is left from above.
		]]
		local rho = (EXCESS - PSS_WORTH) * PCM
		local period = Kinetics.inhourPeriod(LAMBDA, BETAS, rho)
		local left = BETA / (BETA - rho) * math.exp(-(settle - DT) / math.abs(period))
		t.near(ch:get("core.power_pctFP"), floor, floor * left, "on scale, and only just")
		t.ok(ch:get("core.power_pctFP") > 0, "an instrument reading zero would tell the crew nothing")
	end,

	["a loaded core runs the trip's delayed-neutron tail from the power it was saved at (D-053)"] = function(t)
		-- every PSS rod in and the temperatures held at the reference, so the reactivity after the load is constant
		local sys = make()
		local n0 = 0.3
		sys:load({ power_pctFP = n0 * 100 }, 2)
		local rho = (EXCESS - PSS_WORTH) * PCM
		-- the same trip as the kinetics sees it: a critical core at n0, stepped to that reactivity with the source
		local oracle = Kinetics.newAmplitude(LAMBDA, BETAS, n0)
		local worst, integral = 0, 0
		for _ = 1, math.floor(600 / DT + 0.5) do
			sys:step(DT)
			Kinetics.step(oracle, DT, rho, sys.source)
			worst = math.max(worst, math.abs(sys.n - oracle.n) / oracle.n)
			integral += sys.n * DT
		end
		-- for the prompt-jump equations with constant ρ, d/dt Σ sᵢ/λᵢ = ρ·n, so the whole tail is n0·Σ(βᵢ/λᵢ)/(−ρ)
		local tail = 0
		for i, b in BETAS do
			tail += b / LAMBDA[i]
		end
		tail *= n0 / -rho
		t.log(string.format("from %d %%FP: %.3f FP·s in the first 10 min; the continuous tail is %.3f FP·s",
			n0 * 100, integral, tail))
		-- the same arithmetic on the same state, so the two agree to rounding
		t.ok(worst <= 1e-12, `the loaded core runs the trip of a core critical at {n0 * 100} %FP, tail and all (worst {worst})`)
	end,

	["a save taken partway down a trip's tail comes back on the same tail (D-053)"] = function(t)
		--[[
			An autosave or a server close can land on a trip's delayed-neutron tail, where the precursors hold the power
			up and are far from βᵢ·n. Seated at βᵢ·n, the loaded core would take a second prompt drop, to about
			β/(β − ρ) ≈ 0.09 of the saved power, and lose nearly all of the rest of the tail. A core that never stopped
			is the oracle: the loaded core must follow it tick for tick, the same arithmetic on the same state.
		]]
		local before = make()
		before:load({ power_pctFP = 30 }, 2) -- the trip from 30 %FP, as in the previous case
		run(before, 30) -- 30 s down the tail
		local saved = before:save()
		t.ok(saved.precursors ~= nil and #saved.precursors == #BETAS, "the save carries all six precursor groups")

		local after = make()
		after:load(saved, 2)
		local worst = 0
		for _ = 1, math.floor(600 / DT + 0.5) do
			before:step(DT)
			after:step(DT)
			worst = math.max(worst, math.abs(after.n - before.n) / before.n)
		end
		t.log(string.format("30 s after the trip the save holds %.3e FP; the loaded core follows the one that never stopped to %.1e",
			saved.power_pctFP / 100, worst))
		t.ok(worst <= 1e-12, `the loaded core carries on down the same tail (worst {worst})`)
	end,

	["withdrawing worth raises reactivity, and the core answers (§3.1)"] = function(t)
		--[[
			D-049: each reading waits five of its state's slowest periods, so what is left of the approach is known.
			From boot, β/(β − ρ₁) of the equilibrium is still to close (see the D-030 floor). After the step, the prompt
			jump takes n₁ to n₁(β − ρ₁)/(β − ρ₂), which is short of q/(−ρ₂) by 1 − ρ₂(β − ρ₁)/(ρ₁(β − ρ₂)). Each
			closes on its inhour period, and the ratio of the two readings is off by at most the sum of what is left.
		]]
		local rho1 = (EXCESS - PSS_WORTH) * PCM
		local rho2 = rho1 + 3000 * PCM
		local T1 = math.abs(Kinetics.inhourPeriod(LAMBDA, BETAS, rho1))
		local T2 = math.abs(Kinetics.inhourPeriod(LAMBDA, BETAS, rho2))
		local wait1, wait2 = math.ceil(5 * T1), math.ceil(5 * T2)
		local left1 = BETA / (BETA - rho1) * math.exp(-(wait1 - DT) / T1)
		local left2 = (1 - rho2 * (BETA - rho1) / (rho1 * (BETA - rho2))) * math.exp(-(wait2 - DT) / T2)

		local sys, ch = make()
		run(sys, wait1)
		local before = ch:get("core.power_pctFP")
		-- take out 3,000 pcm of rod worth: still subcritical, but much closer
		ch:setExternal("rods.indicativeWorth_pcm", PSS_WORTH - 3000)
		run(sys, wait2)
		t.near(ch:get("core.rho_pcm"), EXCESS - PSS_WORTH + 3000, 1, "ρ follows the worth removed")
		-- equilibrium subcritical multiplication is n = q/(−ρ), so the power rises by the ratio of the two ρ
		local ratio = (PSS_WORTH - EXCESS) / (PSS_WORTH - 3000 - EXCESS)
		t.near(ch:get("core.power_pctFP") / before, ratio, ratio * (left1 + left2),
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

	["the fuel feedbacks take FuelThermal's fuel temperature as it is, lagged once (§3.2, D-060)"] = function(t)
		--[[
			§3.2's 4 s lag on Doppler and fuel axial expansion is the fuel's own thermal time constant, and the fuel
			average FuelThermal publishes already carries it (its pin model, 3.0–3.8 s by layer). So on the tick the
			Core reads a fuel temperature, both terms are §3.2's formulas of that temperature, with no second lag.
		]]
		local sys, ch = make(EXCESS)
		run(sys, 1)
		local fb = Config.Feedback
		local Tf = fb.fullPowerFuelAverage_K
		ch:setExternal("fuel.coreAverage_K", Tf)
		run(sys, DT)
		local breakdown = sys:getState().feedback
		t.near(breakdown.doppler, fb.doppler.constant_pcm * math.log(Tf / fb.referenceTemperature_K), 1e-9,
			"Doppler: −900 pcm × ln(T_f/T_ref) of the fuel as FuelThermal has it")
		t.near(breakdown.fuelAxialExpansion, fb.fuelAxialExpansion.coefficient_pcmpK * (Tf - fb.referenceTemperature_K),
			1e-9, "and the axial expansion likewise")
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
		-- D-049: the exact arithmetic, 1.12 × 301 / Σf (Σf = 301.36 over the three zones), to rounding
		local zones = Config.Core.flow.zones
		local assemblies, weight = 0, 0
		for _, z in zones do
			assemblies += z.fuel
			weight += z.fuel * z.flowFactor
		end
		local zoneI = zones[1].flowFactor * assemblies / weight
		t.near(share / perAssembly, zoneI, 1e-9 * zoneI,
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

	["the prompt-critical flag clears once ρ is back under the limit (§14.2)"] = function(t)
		local sys, ch = make(EXCESS)
		local states = {}
		sys.bus:subscribe("Alarm", function(p)
			if p.tag == "CORE-PROMPT" then
				table.insert(states, p.state)
			end
		end)
		run(sys, 5)
		ch:setExternal("rods.indicativeWorth_pcm", EXCESS - 1000)
		run(sys, 1)
		t.ok(ch:get("core.promptCritical"), "past 0.9β it is flagged")
		t.eq(states[#states], "in")
		-- the worth goes back in: critical again, far below the limit
		ch:setExternal("rods.indicativeWorth_pcm", EXCESS)
		run(sys, 1)
		t.ok(not ch:get("core.promptCritical"), "and the flag describes the core as it is now")
		t.eq(states[#states], "out", "the P1 alarm goes with it")
	end,

	["the whole plant, wired together: hot standby holds, and at power a rod out is caught by Doppler"] = function(t)
		--[[
			This is the test that says the physics is operable. Core, FuelThermal, Pools, PrimaryPumps, IHX and
			the rest, stepped in registry order with nothing imposed from outside except the heat sink's load.
			The plant boots and holds hot standby; seated at power, an operator withdraws one regulating rod, power
			climbs, the fuel heats, and Doppler arrests it.
		]]
		local _, channels, advance, byName = plant()
		t.ok(true, "every read has a writer: the plant resolves")

		advance(5)
		t.ok(channels:get("core.k") < 1, "the plant boots shut down")
		t.ok(channels:get("core.rho_pcm") < -3000, "deeply subcritical, as §3.4's margins say")
		t.ok(not channels:get("protection.tripped"), "and sits there quietly")
		local rods, ihx = byName.RodDrives, byName.IHX

		--[[
			Hot standby has to hold its own temperature. The heat sink boots with no load, which §9.2 puts at
			375 °C on the cold leg (D-032). A boundary held at full-load conditions instead pulled 570 MWt out of
			this shut-down plant and cooled it 20 K in a minute — and once the rods came out, D-004's Mode 3
			inhibit lifted and core-inlet-low tripped against the falling inlet.
		]]
		local inlet0 = channels:get("pools.coreInlet_K")
		advance(60)
		local inlet1 = channels:get("pools.coreInlet_K")
		--[[
			D-049: the heat sink holds the cold leg on §9.2's no-load programme, and the pumps' heat is what the inlet
			carries above it (§4.2), so the pump heat's own temperature rise bounds how far the inlet can move.
		]]
		local pumpRise = channels:get("primary.pumpHeat_MWt") * 1e6
			/ (channels:get("primary.coreFlow_kgps") * Sodium.specificHeat(inlet1))
		t.log(string.format("hot standby: the inlet moved %.3f K in a minute; the pumps' heat is %.3f K", inlet1 - inlet0, pumpRise))
		t.near(inlet1, inlet0, pumpRise, "a minute of hot standby leaves the core inlet where it was")
		local mode3 = Config.Program.modes[3].coreInlet_C
		t.ok(inlet1 - KEL >= mode3[1] and inlet1 - KEL <= mode3[2], "inside §9.1's Mode 3 band")
		--[[
			The boot has §14.6's beginning-of-cycle decay heat (D-036): §3.6's curve 30 min after 160 EFPD at full
			power, and 65 s of plant time further down it by now. The tolerance is the derivation's acceptance, the
			table's own precision at its finest entry (tests/DecayHeatSpec).
		]]
		local DH = Config.DecayHeat
		local elapsed = DH.boot.shutdown_s + 65
		local T_op = DH.referenceOperatingTime_EFPD * 86400
		local expect = DH.coefficient * (elapsed ^ DH.exponent - (elapsed + T_op) ^ DH.exponent)
		t.near(channels:get("decay.fraction"), expect, expect * 0.005 / DH.table.percent[1],
			"beginning of cycle, on §3.6's curve")
		local decay_MW = channels:get("decay.heat_W") / 1e6
		t.ok(ihx:getState().total_MWt <= channels:get("primary.pumpHeat_MWt") + decay_MW,
			"and the IHXs carry no more than the pumps and the decay heat put in")

		--[[
			At power, from a seat rather than from rods placed by hand (D-033). Placing the rods alone leaves the
			fuel at hot zero power, and the power defect the rods were set against does not exist yet; the core
			then spends minutes finding its own level while the pools drift, and a rod move made during that
			drift cannot be told apart from it. The seat starts everything in steady state, so the only thing
			that moves is what the operator moves. Autos stay out: this is the physics, not the controllers.
		]]
		t.ok(InitialConditions.seatAtPower(byName, channels, Config, 20) ~= nil, "seated at 20 %FP")
		advance(10)
		local seated = channels:get("core.power_pctFP")
		local feedback = channels:get("core.feedback_pcm")
		-- the same ±3 K on an 87.5 K core rise as the seat test below: ±3.4 % of the power
		local rise = Config.Program.partLoad.outletSlope_K * 0.2 / 0.4
		local band = Config.Program.rodAuto.holdBand_K + Config.Core.flow.thermocoupleNoise_K
		t.near(seated, 20, 20 * band / rise, "and sitting there")

		-- An operator withdraws one regulating rod 100 mm, at §3.4's 5 mm/s
		local worth0 = channels:get("rods.indicativeWorth_pcm")
		rods:applyCommand(OPERATOR, { kind = "rod.move", target = "RR1", value = 600 })
		advance(40)
		local power = channels:get("core.power_pctFP")
		t.log(string.format("100 mm of RR1 (%.1f pcm): power %.3f → %.3f %%FP, fuel %.1f K, feedback %.1f → %.1f pcm, ρ %.2f pcm",
			worth0 - channels:get("rods.indicativeWorth_pcm"), seated, power, channels:get("fuel.coreAverage_K"),
			feedback, channels:get("core.feedback_pcm"), channels:get("core.rho_pcm")))
		t.ok(power > seated, "power rose when the rod came out")
		t.ok(channels:get("core.feedback_pcm") < feedback, "the fuel heated and the feedback answered")
		local added = worth0 - channels:get("rods.indicativeWorth_pcm")
		t.ok(math.abs(channels:get("core.rho_pcm")) < 0.5 * added,
			"and caught it: the feedback has taken back most of what the rod added, so the core is not running away")
		t.ok(not channels:get("protection.tripped"), "without a trip")
	end,

	["after a scram the neutrons go and the decay heat stays, on §3.6's curve (D-037)"] = function(t)
		local _, channels, advance, byName = plant()
		advance(1)
		t.ok(InitialConditions.seatAtPower(byName, channels, Config, 20) ~= nil, "seated at 20 %FP")
		t.near(channels:get("core.thermalPower_pctFP"), 20, 20 * 1e-9, "seated: heat equals the load exactly")
		byName.Protection:applyCommand(OPERATOR, { kind = "reactor.trip.manual", target = "BCR" })

		--[[
			Superposition, which is what makes the group model trustworthy for any history: the decay heat after
			the trip is the seated history, closed off at the trip, plus whatever the fission tail since the trip
			has added. The first part is closed-form; the second is a fresh DecayHeat fed the same fission power
			tick by tick. Their sum must be the plant's to rounding, which says nothing else feeds decay heat —
			no second delayed-neutron term (§3.6), no double count.
		]]
		local tail = System.new(require(Systems:WaitForChild("DecayHeat")) :: any)
		local tailChannels = Channels.new()
		tailChannels:declareExternal("core.power_pctFP", 0)
		tail:init({ config = Config, channels = tailChannels:port(tail.spec), log = EventLog.new(Config, { sim = 0, grid = 0 }) })
		tail:seatHistory(0, 0, 0)
		local closed = System.new(require(Systems:WaitForChild("DecayHeat")) :: any)
		local closedChannels = Channels.new()
		closedChannels:declareExternal("core.power_pctFP", 0)
		closed:init({ config = Config, channels = closedChannels:port(closed.spec), log = EventLog.new(Config, { sim = 0, grid = 0 }) })
		local T_REF = Config.DecayHeat.referenceOperatingTime_EFPD * 86400
		local since = 0
		for _ = 1, 600 do -- 60 s of 0.1 s ticks
			advance(DT)
			since += DT
			tailChannels:setExternal("core.power_pctFP", channels:get("core.power_pctFP"))
			tail:step(DT)
		end
		-- the trip is commanded before the first tick after the seat, so every tick since belongs to the tail
		closed:seatHistory(0.2, T_REF, since)
		local plantDecay = channels:get("decay.fraction")
		local superposed = closedChannels:get("decay.fraction") + tailChannels:get("decay.fraction")
		t.near(plantDecay, superposed, superposed * 1e-9, "decay heat = the seated history + the fission tail, exactly")
		local curve = 0.2 * Config.DecayHeat.coefficient * (60 ^ Config.DecayHeat.exponent - (60 + T_REF) ^ Config.DecayHeat.exponent)
		t.log(string.format("60 s after the trip: neutron %.4f %%FP, thermal %.3f %%FP, decay %.3f %%FP (§3.6 for the history %.3f, tail %.4f)",
			channels:get("core.power_pctFP"), channels:get("core.thermalPower_pctFP"), plantDecay * 100, curve * 100,
			tailChannels:get("decay.fraction") * 100))
		t.ok(plantDecay >= curve, "the tail only ever adds to the history's own curve")
		t.ok(channels:get("decay.heat_W") > channels:get("core.power_pctFP") / 100 * 2380e6,
			"a minute on, the heat is mostly decay heat rather than fission")

		-- and the heat sink, with the turbines tripped, holds hot standby against it (D-032)
		advance(240)
		local inlet = channels:get("pools.coreInlet_K") - KEL
		t.log(string.format("5 min after the trip: core inlet %.2f °C, hot pool %.2f °C, decay %.1f MW, IHX %.1f MW",
			inlet, channels:get("pools.hotPool_K") - KEL, channels:get("decay.heat_W") / 1e6, channels:get("ihx.heatRemoved_W") / 1e6))
		--[[
			Five minutes on, the pools are still giving up the heat they held at 20 %FP: the exchangers carry more
			than the decay heat, which is the plant cooling toward hot standby, and the inlet stays clear of §9.5's
			390 °C alarm while it does. §9.1's 350–380 °C band is for hot standby once settled, not the approach.
		]]
		t.ok(channels:get("ihx.heatRemoved_W") > channels:get("decay.heat_W"), "the pools are cooling toward hot standby")
		t.ok(inlet < Config.Protection.pss.coreInlet.alarmHigh_C, "with the inlet below §9.5's high alarm")
		t.eq(channels:get("ihx.sinkLoad_pct"), 0, "the turbines tripped with the reactor")
		t.eq(channels:get("protection.firstOut"), "MANUAL", "and nothing tripped after the manual trip")
	end,

	["seated at 20 %FP with both autos in, the whole plant holds §9.2's operating point"] = function(t)
		local _, channels, advance, byName = plant()
		advance(1)
		local seated, why = InitialConditions.seatAtPower(byName, channels, Config, 20)
		t.ok(seated ~= nil, `seated ({why or "ok"})`)
		t.near(channels:get("core.rho_pcm"), 0, 1e-6, "critical by construction")
		byName.AutoControls:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		byName.AutoControls:applyCommand(OPERATOR, { kind = "auto.flow", value = 1 })
		advance(120)
		--[[
			Tolerances from §9.4 and §2.5, not from the result: rod auto holds the outlet within ±2 K on a
			thermocouple good to ±1 K, so the core rise — 87.5 K at 20 %FP on 40 % flow — is held within ±3 K,
			which is ±3.4 % of the power.
		]]
		local rise = Config.Program.partLoad.outletSlope_K * 0.2 / 0.4
		local band = Config.Program.rodAuto.holdBand_K + Config.Core.flow.thermocoupleNoise_K
		local power = channels:get("core.power_pctFP")
		local outlet = channels:get("pools.mixedCoreOutlet_K") - KEL
		local inlet = channels:get("pools.coreInlet_K") - KEL
		t.log(string.format("after 120 s: %.3f %%FP, inlet %.2f °C, outlet %.2f °C, ρ %+.2f pcm, cold leg %.1f °C, rods %.0f pcm",
			power, inlet, outlet, channels:get("core.rho_pcm"),
			(channels:get("ihx.secondaryInlet_K") :: { number })[1] - KEL, channels:get("rods.indicativeWorth_pcm")))
		t.near(power, 20, 20 * band / rise, "power stays on the load")
		t.near(inlet, Config.Program.partLoad.coreInlet_C, band, "§9.2's 375 °C core inlet")
		t.near(outlet, Config.Program.partLoad.coreInlet_C + rise, band, "and its 462 °C outlet")
		t.eq(channels:get("program.mode"), 1, "§9.1: above 5 %FP is Mode 1")
		t.ok(not channels:get("protection.tripped"), "without a trip")
		t.eq(#(channels:get("protection.active") :: { any }), 0, "or a single alarm")
	end,

	["the reactor follows the steam plant's load"] = function(t)
		local _, channels, advance, byName = plant()
		advance(1)
		t.ok(InitialConditions.seatAtPower(byName, channels, Config, 20) ~= nil, "seated at 20 %FP")
		byName.AutoControls:applyCommand(OPERATOR, { kind = "auto.rod", value = 1 })
		byName.AutoControls:applyCommand(OPERATOR, { kind = "auto.flow", value = 1 })
		local worth0 = channels:get("rods.indicativeWorth_pcm")
		t.ok(byName.IHX:applyCommand(OPERATOR, { kind = "sink.load", value = 25 }).ok, "the steam plant asks for 25 %")
		--[[
			A minute of ramp at §7.1's 5 %/min. Rod auto follows the load's setpoint at the regulating rods' pace, so
			the reactor lags the steam plant and the pools give up some heat: the inlet dips. Holding the outlet on
			the setpoint with a cold inlet means a bigger core rise, so the reactor then runs above the load until
			the pools are refilled — which takes the loop's own mixing time, its inventory over its flow: D-021's
			118 s of rated flow, on 40 % flow, is 295 s. Nine hundred seconds is the ramp and three of those.
		]]
		advance(60)
		local ramped = channels:get("ihx.sinkLoad_pct")
		advance(840)
		local rise = Config.Program.partLoad.outletSlope_K * 0.25 / 0.4
		local band = Config.Program.rodAuto.holdBand_K + Config.Core.flow.thermocoupleNoise_K
		local power = channels:get("core.power_pctFP")
		local inlet = channels:get("pools.coreInlet_K") - KEL
		t.log(string.format("after 900 s: %.3f %%FP, flow %.1f %%, inlet %.2f °C, outlet %.2f °C (setpoint %.2f), rods %.0f → %.0f pcm",
			power, channels:get("primary.flowFraction") * 100, inlet, channels:get("pools.mixedCoreOutlet_K") - KEL,
			channels:get("auto.coreOutletSetpoint_C"), worth0, channels:get("rods.indicativeWorth_pcm")))
		t.near(ramped, 25, 1e-6, "the load reached 25 % in the minute §7.1's rate allows")
		t.near(power, 25, 25 * band / rise, "power came up to meet the load, and settled on it")
		t.near(inlet, Config.Program.partLoad.coreInlet_C, band, "with the pools refilled to §9.2's inlet")
		t.ok(channels:get("rods.indicativeWorth_pcm") < worth0, "rod auto withdrew to pay the extra power defect")
		t.ok(not channels:get("protection.tripped"), "without a trip")
	end,
}
