--!strict
--[[
	Core — the facade that turns rod positions into power, and power into heat (spec §3.1–§3.3, §2.4).
	====================================================================================================

	This is the piece that closes the plant. Until it existed, withdrawing a rod moved `rods.position_mm` and
	nothing else happened: every system downstream read `core.*` channels that nobody wrote. With it, the loop
	runs all the way round —

	    rods → reactivity → power → pin power → fuel temperature → Doppler → back to reactivity
	                                     ↓
	                            pools → IHX → protection → autos

	**Point kinetics, for now.** The plan has the 3D multigroup IQS as the plant physics and point kinetics as
	"the spec-required fallback and the test oracle". The cross sections the 3D solve needs come from Track X and
	do not exist yet, so this facade runs the fallback: `Kinetics.PointKinetics`, already tested against the
	inhour equation and already reproducing §3.3's −844 pcm power defect. When `XSData` lands, the 3D path
	replaces the innards of this system and every channel it publishes stays exactly the same — which is the
	point of putting a facade here rather than wiring kinetics into the plant directly.

	**Reactivity is absolute, not relative to an assumed critical state.** The oracle balances itself at whatever
	state it starts in, which suits it as an oracle and not as a plant: a plant that boots in hot standby is
	deeply subcritical, and it has to know that. So the external term is set from the §3.3 budget instead:

	    ρ(t) = excess − rod worth inserted + feedback
	    excess at 375 °C = 2,250 − 376 = 1,874 pcm     (§3.3's budget line and its isothermal swing)

	At the §9.1 Mode 3 boot state, with every PSS rod in, that gives −3,826 pcm and k = 0.963 — which the source
	range then reads as §3.5's 15/(1−k), around 400 cps, without anything being told to say so.

	**Where the power goes.** The radial shape is §2.5's flow zoning read backwards: zone flow factors exist to
	level the assembly outlets, so an assembly's share of the power is its flow factor. The axial shape is the
	chopped cosine whose peak-to-average is §2.4's 1.22, the same one `tools/derive/pin_thermal.py` used to
	generate FuelThermal's expected temperatures. Both are spec-derived, and both are placeholders for the 3D
	flux: the zone factors give a radial peak of 1.12 where §3.7's validation target is 1.20, and that gap is a
	property of the fallback rather than an error in it.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local DecayHeat = require(script.Parent.DecayHeat)
local Kinetics = require(script.Kinetics)
local Mesh = require(script.Mesh)
local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Types = require(Kallskar:WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local Core = System.extend({
	name = "Core",
	lane = "fast",
	reads = {
		"rods.indicativeWorth_pcm",
		"pools.mixedCoreOutlet_K",
		"pools.coreInlet_K",
		"pools.hotPool_K",
		"pools.coldPool_K",
	},
	-- decay heat is driven by this system's own power, so it arrives a tick late: 0.1 s against a 0.4 s fastest group
	readsLagged = { "fuel.coreAverage_K", "fuel.coreAverageSodium_K", "decay.heat_W" },
	writes = {
		"core.power_pctFP",
		"core.thermalPower_W",
		"core.thermalPower_pctFP",
		"core.k",
		"core.rho_pcm",
		"core.feedback_pcm",
		"core.fuelPinPower_W",
		"core.reactivityBalance_pcm",
		"core.promptCritical",
	},
})

--[[
	The chopped cosine q'(z)/q'_avg = cos(Uz)·U/sin(U) on z ∈ [−½, ½], with U fixed by the peak-to-average the
	spec states: sin(U)/U = 1/peak. Solved by bisection at init, so the shape follows §2.4's number rather than
	carrying a hard-coded constant beside it.
]]
local function axialShapeParameter(peak: number): number
	local lo, hi = 1e-6, 1.5
	for _ = 1, 200 do
		local mid = 0.5 * (lo + hi)
		if math.sin(mid) / mid > 1 / peak then
			lo = mid
		else
			hi = mid
		end
	end
	return 0.5 * (lo + hi)
end

function Core.init(self: any, ctx: any)
	local cfg = ctx.config
	self.cfg = cfg
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.pcmPerUnit = cfg.Units.pcmPerUnit
	self.rated_W = cfg.Units.ratedThermal_MWt * 1e6
	self.pinShare = cfg.Core.powerSplit.fuelPins

	--[[
		§3.3's budget: the excess is quoted at 230 °C, and the same budget gives the 230 → 375 °C isothermal swing,
		so the excess at the §3.2 reference temperature is the difference. `tools/derive/rod_speeds.py` shows the
		§3.4 shutdown margins agree with this to 1.1 %.
	]]
	local budget = cfg.Reactivity.budget_pcm
	self.excess_pcm = budget.requiredExcessAt230AllRodsOut - budget.isothermal230to375

	local mesh = Mesh.get(cfg)
	self.L = cfg.PhysicsModel.axial.fuelLayers
	self.assemblies = {}
	local zones = cfg.Core.flow.zones
	local weight = 0
	for r = 1, mesh.NR do
		if mesh.kind[r] == "fuel" then
			-- §2.5's flow zoning levels the outlets, so an assembly's flow factor is its share of the power
			local f = zones[mesh.flowZone[r]].flowFactor
			table.insert(self.assemblies, f)
			weight += f
		end
	end
	for i, f in self.assemblies do
		self.assemblies[i] = f / weight
	end
	self.NA = #self.assemblies

	-- axial shape, normalised so the layer fractions sum to 1
	local u = axialShapeParameter(cfg.Core.limits.peaking.axial)
	self.axial = table.create(self.L, 0)
	local sum = 0
	for l = 1, self.L do
		-- z over [−1, 1], which is the interval on which the mean of cos(Uz) is sin(U)/U — the same convention
		-- tools/derive/pin_thermal.py used to generate FuelThermal's expected temperatures
		local z = 2 * ((l - 0.5) / self.L) - 1
		local v = math.cos(u * z) * u / math.sin(u)
		self.axial[l] = v
		sum += v
	end
	for l = 1, self.L do
		self.axial[l] /= sum
	end

	self.pinPower = table.create(self.NA * self.L, 0)
	self.port:write("core.fuelPinPower_W", self.pinPower)

	-- the drivers the §3.2 feedbacks act on, at the hot zero power reference until the plant publishes its own
	local T0 = cfg.Feedback.referenceTemperature_K
	self.drivers = {
		fuelAverage = T0,
		coreAverageSodium = T0,
		coreOutlet = T0,
		coreInlet = T0,
		upperHotPool = T0,
		coldPool = T0,
	}
	self.pk = Kinetics.PointKinetics.new(cfg, self.drivers, 0)

	--[[
		D-030: the startup source. §3.5 gives no source strength, but it does give the wide range a span whose
		bottom is 10⁻⁸ %FP, and an instrument that reads zero in Mode 3 would be telling the crew nothing. The
		source is therefore sized so a shut-down plant — every PSS rod in, at the reference temperature — sits at
		exactly that bottom of span. Subcritical multiplication then carries it up the scale on its own.
	]]
	local shutdown_pcm = self.excess_pcm - (cfg.Rods.regulating.worthTotal_pcm + cfg.Rods.shim.worthTotal_pcm)
	self.nFloor = cfg.Instruments.wideRange.span_pctFP[1] / 100
	self.source = self.nFloor * (-shutdown_pcm / self.pcmPerUnit)

	--[[
		Thermal power is prompt fission heat plus decay heat (D-037). The prompt share is 1 − f_ref, the part of
		fission energy that is not deferred into §3.6's decay groups at steady state on the reference history, so
		that a plant seated there makes exactly its rated heat at n = 1.
	]]
	self.promptShare = 1 - DecayHeat.referenceFraction(cfg)
	self.thermal_W = 0

	self.worth0_pcm = nil -- latched on the first step, when RodDrives has published
	self.n = 0
	self.rho_pcm = 0
	self.promptCritical = false
	self:updateThermal()
	self:publish()
end

function Core.publish(self: any)
	local port = self.port
	port:write("core.power_pctFP", self.n * 100)
	port:write("core.thermalPower_W", self.thermal_W)
	port:write("core.thermalPower_pctFP", self.thermal_W / self.rated_W * 100)
	port:write("core.rho_pcm", self.rho_pcm)
	port:write("core.feedback_pcm", (self.pk.feedback or 0) * self.pcmPerUnit)
	-- ρ = (k − 1)/k, so k = 1/(1 − ρ)
	port:write("core.k", 1 / (1 - self.rho_pcm / self.pcmPerUnit))
	port:write("core.promptCritical", self.promptCritical)
	--[[
		§9.5's ±50 pcm rod block compares the reactivity the core HAS with the reactivity its rod positions,
		temperatures and burnup say it SHOULD have. In this fallback those are the same number by construction,
		so the balance is zero and the block never fires on it. It becomes a real signal when the 3D solve and
		burnup tracking can disagree with the bookkeeping.
	]]
	port:write("core.reactivityBalance_pcm", 0)
end

function Core.step(self: any, dt: number)
	local port = self.port
	local worth = port:read("rods.indicativeWorth_pcm") or 0
	if self.worth0_pcm == nil then
		--[[
			Latch the starting rod worth and set the oracle's external term so that ρ is the plant's ABSOLUTE
			reactivity rather than a perturbation from an assumed critical state. After this, ρ = excess − worth
			+ feedback at every moment.
		]]
		self.worth0_pcm = worth
		self.pk.external = (self.excess_pcm - worth) / self.pcmPerUnit
	end

	local drivers = self:readDrivers()
	if self.reseat then
		--[[
			D-053: a loaded plant comes back tripped, and the trip happens now. The rods were latched just above as
			they now stand, and the §3.2 feedback is seated on the loaded temperatures. The amplitude is seated as the
			plant was when it closed: the saved power and the six saved precursor groups, so a save taken partway
			down a trip's delayed-neutron tail carries on down the same tail. A save with the power but no
			precursors (from before they were saved) seats every group in equilibrium at that power (sᵢ = βᵢ·n₀),
			which is exact for a plant that was steady when it closed. Without a saved power (a version-1 save), it is
			seated at the equilibrium the source drives for that reactivity, n = q/(−ρ).
		]]
		self.reseat = false
		self.pk:updateFeedback(0, drivers)
		local rho = self.pk.external + self.pk.feedback
		local amp = self.pk.amp
		local n = self.reseatPower or (if rho < 0 then self.source / -rho else self.nFloor)
		local saved = if self.reseatPower then self.reseatPrecursors else nil
		self.reseatPower, self.reseatPrecursors = nil, nil
		amp.n = n
		for i = 1, #amp.s do
			amp.s[i] = if saved then saved[i] else amp.beta[i] * n
		end
		self.n = n
	end

	-- withdrawing a rod REMOVES inserted worth, which is positive reactivity
	local external_pcm = -(worth - self.worth0_pcm)
	self.n = self.pk:step(dt, external_pcm, drivers, self.source)
	self.rho_pcm = self.pk.rho * self.pcmPerUnit

	if self.pk.amp.promptCritical and not self.promptCritical then
		self.promptCritical = true
		if self.log then
			self.log:record("core.promptCritical", nil, "core",
				string.format("ρ %.0f pcm", self.rho_pcm), "PROMPT CRITICAL")
		end
		if self.bus then
			self.bus:publish("Alarm", {
				tag = "CORE-PROMPT",
				priority = 1,
				state = "in",
				text = "Prompt critical",
			})
		end
	elseif not self.pk.amp.promptCritical and self.promptCritical then
		-- back under the limit: the prompt-jump form holds again, and the alarm goes with the condition
		self.promptCritical = false
		if self.bus then
			self.bus:publish("Alarm", { tag = "CORE-PROMPT", priority = 1, state = "out", text = "Prompt critical" })
		end
	end

	self:spreadPower()
	self:publish()
end

-- The temperatures the §3.2 feedbacks act on, from whatever the plant has published
function Core.readDrivers(self: any): Kinetics.Drivers
	local port, drivers = self.port, self.drivers
	drivers.fuelAverage = port:read("fuel.coreAverage_K") or drivers.fuelAverage
	drivers.coreAverageSodium = port:read("fuel.coreAverageSodium_K") or drivers.coreAverageSodium
	drivers.coreOutlet = port:read("pools.mixedCoreOutlet_K") or drivers.coreOutlet
	drivers.coreInlet = port:read("pools.coreInlet_K") or drivers.coreInlet
	drivers.upperHotPool = port:read("pools.hotPool_K") or drivers.upperHotPool
	drivers.coldPool = port:read("pools.coldPool_K") or drivers.coldPool
	return drivers
end

-- Thermal power: prompt fission heat plus the decay heat DecayHeat published last tick
function Core.updateThermal(self: any)
	local decay_W = self.port:read("decay.heat_W") or 0
	self.thermal_W = self.n * self.rated_W * self.promptShare + decay_W
end

-- Spread the thermal power over the mesh: assembly share × axial shape. Decay heat goes where fission heat does.
function Core.spreadPower(self: any)
	self:updateThermal()
	local pinTotal = self.thermal_W * self.pinShare
	local power, axial, L = self.pinPower, self.axial, self.L
	for a = 1, self.NA do
		local share = self.assemblies[a] * pinTotal
		local base = (a - 1) * L
		for l = 1, L do
			power[base + l] = share * axial[l]
		end
	end
end

--[[
	Seat every feedback term on the plant's present temperatures and return the total in pcm (plan: initial
	conditions). The §3.2 lags make feedback follow the plant late; an initial condition has no history to be late
	about, so each term starts at its driver — which is updateFeedback at dt = 0.
]]
function Core.seatFeedback(self: any): number
	self.pk:updateFeedback(0, self:readDrivers())
	return self.pk.feedback * self.pcmPerUnit
end

-- The inserted worth at which the core is exactly critical with the feedback it has now: ρ = excess − W + feedback
function Core.criticalWorth_pcm(self: any): number
	return self.excess_pcm + self.pk.feedback * self.pcmPerUnit
end

--[[
	Take the rods where they now stand as the external term's reference, as the first step's latch does at boot,
	so ρ = excess − worth + feedback holds from here on.
]]
function Core.latchRods(self: any)
	local worth = self.port:read("rods.indicativeWorth_pcm") or 0
	self.worth0_pcm = worth
	self.pk.external = (self.excess_pcm - worth) / self.pcmPerUnit
	self.pk.rho = self.pk.external + self.pk.feedback
	self.rho_pcm = self.pk.rho * self.pcmPerUnit
end

--[[
	Seat the core at a stated relative power with its precursors in equilibrium there. A real startup climbs ten
	decades over hours, which is the right behaviour and the wrong thing to make a test — or a person looking at a
	screen — sit through. The debug panel and the integration tests use this to begin somewhere useful.
]]
function Core.setPower(self: any, n: number)
	--[[
		A rescale, not a new equilibrium. `newAmplitude` rightly insists that a source-driven state satisfies
		n = q/(−ρ), which a preset cannot promise; multiplying the amplitude and its precursors by the same factor
		keeps the state internally consistent and simply moves the whole thing up the scale. The startup source
		becomes negligible against a power worth watching, which is exactly what happens in the plant.
	]]
	local amp = self.pk.amp
	if amp.n > 0 then
		local ratio = n / amp.n
		for i = 1, #amp.s do
			amp.s[i] *= ratio
		end
	else
		for i = 1, #amp.s do
			amp.s[i] = amp.beta[i] * n
		end
	end
	amp.n = n
	self.n = n
	self:spreadPower()
	self:publish()
end

--[[
	Seat the core critical at a power with its precursors exactly in equilibrium there, sᵢ = βᵢ·n — the state
	`newAmplitude` builds, which only a critical core can hold. InitialConditions calls this after it has placed
	the rods to make ρ zero; setPower is the rescale for everything else.
]]
function Core.seatPower(self: any, n: number)
	local amp = self.pk.amp
	for i = 1, #amp.s do
		amp.s[i] = amp.beta[i] * n
	end
	amp.n = n
	amp.rho = self.pk.rho
	self.n = n
	self:spreadPower()
	self:publish()
end

--[[
	D-053: nothing on §14.6's list is the core's, but a loaded plant comes back tripped, so the core is re-seated on
	its first step after a load (Core.step): the rods latched as they stand, the feedback on the loaded temperatures,
	and the amplitude as it was, power and precursors both, so a trip's delayed-neutron tail carries on from where
	the save caught it. The precursors are the kinetics' state as much as the power is: on a tail they, not the
	power, hold the power up, and an autosave or a server close can come at any point on one.
]]
function Core.save(self: any): any
	return { power_pctFP = self.n * 100, precursors = table.clone(self.pk.amp.s) }
end

-- The saved precursor groups, if they are a usable set for this kinetics: one finite, non-negative value per group
local function savedPrecursors(data: any, groups: number): { number }?
	local s = data.precursors
	if type(s) ~= "table" or #s ~= groups then
		return nil
	end
	for i = 1, groups do
		local v = s[i]
		if type(v) ~= "number" or v ~= v or v < 0 or v == math.huge then
			return nil
		end
	end
	return table.clone(s)
end

function Core.load(self: any, data: any, _version: number)
	self.worth0_pcm = nil -- latched again on the first step
	self.reseat = true
	self.reseatPower = if type(data.power_pctFP) == "number" and data.power_pctFP > 0 then data.power_pctFP / 100 else nil
	self.reseatPrecursors = savedPrecursors(data, #self.pk.amp.s)
	self.promptCritical = false
end

function Core.getState(self: any): { [string]: any }
	local breakdown = self.pk:breakdown_pcm()
	return {
		power_pctFP = self.n * 100,
		thermalPower_MWt = self.thermal_W / 1e6,
		rho_pcm = self.rho_pcm,
		k = 1 / (1 - self.rho_pcm / self.pcmPerUnit),
		rodWorth_pcm = self.worth0_pcm,
		feedback = breakdown,
		promptCritical = self.promptCritical,
		source = self.source,
	}
end

return Core
