--!strict
--[[
	Protection — the reactor protection system: trips, rod blocks, runbacks and first-out (spec §9.5, §9.6).
	==========================================================================================================

	§9.5 is a table with three action columns — normal, alarm or first action, trip — so this system is a table
	too. Each MONITOR below is one row of §9.5, and one executor evaluates them all: vote the channels, check the
	permissives, raise the alarm, set the rod block, fire the trip. A new protective signal is a new row, and the
	spec's table can be read against this one line by line, which is the point.

	**Voting.** §9.5's header says the PSS is 2-out-of-3 on independent channels, and §3.5 gives the power range
	four quadrant channels rather than three, so those vote 2-out-of-4 (D-005, finding F5). Every monitor declares
	its own vote, and a signal the plant only has one of declares 1-of-1 — honestly, rather than pretending three
	instruments exist. Triplicating the process thermocouples is a later refinement; the neutron channels §9.5
	names explicitly are triplicated now (D-026).

	**Permissives and inhibits.** A trip that fires when it should not is not a safe failure: it fills the
	first-out and the event log with noise and teaches the crew to ignore both. §9.5's permissives are therefore
	part of each row, and D-004's mode-based inhibit on the core-inlet-low trip is implemented exactly as Rev A5
	states it — inhibited in Modes 4 and 5, in Mode 3 with every PSS rod fully inserted, and in Mode 2 below
	350 °C, armed in Mode 1 above 5 %FP — with every inhibit annunciated, so an unavailable trip is visible.

	**Persistence.** D-025 found that the period channel's own noise reaches an apparent 39 s at 4.5σ against a
	30 s rod block, so a session long enough will eventually see one sample dip under it. Rows may therefore
	declare `persist_s`, and the period rod block requires the condition to hold rather than acting on one sample.

	**Alarm deadband (D-050, as amended).** An alarm comes in at its setpoint and goes out only once the signal is back
	past the setpoint by the row's `deadband`, so a noisy signal sitting near the setpoint does not chatter in and out.
	The deadband comes from the channel's own noise. A channel with bounded noise, the thermocouple's §2.5 ±1 K, gets
	its full peak-to-peak span, 2 K: a steady signal then can never be both past the setpoint and back past the
	deadband, so it cannot flicker at all. A channel with Gaussian noise gets 3σ of it at the setpoint (D-025's
	relative noise for the power range, the Poisson σ = √(R/τ) for the DNDs), plus an off-delay, `offDelay_s`: the
	alarm goes out only once every channel has stayed back past the deadband for 5 s. tools/derive/alarm_deadband.py
	gives what is left at each row's worst steady level: PR-HIGH once every 4.5 h, the DNDs once every 50 min (their
	ratemeter carries each reading into the next). A row whose signal carries no modelled noise cannot chatter and has
	no deadband.

	**Runbacks (D-046).** §9.5 gives each runback a target and a rate, and §3.4 the mechanism: the shims drive in at
	10 mm/s. The rate is a demand, not a rod speed. A runback ramps a power demand from the neutron power at its start
	down to its target at its table rate, and asks for the shim drive-in (`protection.rodRunback`) only while the
	measured power, the PR median, is above that demand, so the shims follow the ramp rather than running the core
	down into a shutdown. The steam plant runs back alongside: IHX reads the target and rate and ramps its load the
	same way. Rod auto stands down while a runback runs (AutoControls). The runback is complete once the demand has
	reached the target and the measured power is at or below the target plus one PR channel's D-025 noise there; rod
	auto, if it was in auto, then takes over at the new load. The pump and loop rows start their runback on the
	alarm's rising edge, so a runback that has been cleared or has finished does not restart until the trigger has
	reset and come back; one refused because a deeper runback was running starts once that one is out of the way. RB-3's target, "bypass-limited", is not a number yet, so RB-3 is refused (M3).

	**First-out.** The first monitor to reach its trip level latches, and stays latched through the reset, because
	the question after a trip is always which signal went first. Later trips are recorded but do not overwrite it.

	This system does not move the rods itself: it writes `protection.scram`, and RodDrives reads it. Splitting the
	decision from the mechanism means a scram can be tested without drives, and drives without protection.

	Signals that belong to systems M1 does not build yet — seismic, the 11 kV boards, the reactivity balance and the
	hot pool level programme — are declared as external inputs and stay inert at their safe values until something
	writes them. They are wired, not invented. Turbine availability is declared too (Main), but no row reads it until
	RB-3 has a target to run to.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Types = require(Kallskar:WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local Protection = System.extend({
	name = "Protection",
	lane = "fast",
	reads = {
		"detectors.pr_pctFP",
		"detectors.period_s",
		"detectors.fluxRate_pctFPps",
		"detectors.dnd_cps",
		"pools.mixedCoreOutletMeasured_K",
		"pools.coreInlet_K",
		"pools.coverGas_MPa",
		"fuel.assemblyOutlet_K",
		"primary.pumpsRunning",
		"primary.flowFraction",
		"primary.pumpSpeed_pct",
		"ihx.loopsRunning",
		"core.power_pctFP",
		"detectors.prMean_pctFP",
		"program.mode",
		"site.seismic_g",
		"electrical.boards11kV",
		"core.reactivityBalance_pcm",
		"pools.levelDeviation_m",
	},
	readsLagged = {
		"rods.allPssInserted",
		"rods.regulatingInBand",
		"rods.selectionKind",
	},
	writes = {
		"protection.scram",
		"protection.rodWithdrawalBlock",
		"protection.rodRunback",
		"protection.tripped",
		"protection.firstOut",
		"protection.active",
		"protection.inhibited",
		"protection.runback",
		"protection.runbackTarget_pctFP",
		"protection.runbackRate_pctpmin",
	},
})

local KELVIN = 273.15

--[[
	Count the channels past a setpoint. `sense` is which side is dangerous. A monitor with one channel votes 1-of-1
	rather than pretending to be triplicated.

	`inclusive` is for the rows §9.5 states as counts rather than as thresholds — "1 lost", "2 lost" — where the
	setpoint is a value to reach, not one to exceed.
]]
local function voted(
	values: { number },
	sense: string,
	setpoint: number,
	required: number,
	inclusive: boolean?
): (boolean, number)
	local n = 0
	for _, v in values do
		local hit
		if sense == "above" then
			hit = if inclusive then v >= setpoint else v > setpoint
		else
			hit = if inclusive then v <= setpoint else v < setpoint
		end
		if hit then
			n += 1
		end
	end
	return n >= required, n
end

local function single(value: number?): { number }
	return { value or 0 }
end

--[[
	§9.5, row for row. Each monitor reads its channels, declares its vote, and carries whichever of the three
	action levels the spec gives it. `armed` is the permissive: false means the row is not evaluated, and if it
	names a reason the row is annunciated as inhibited rather than silently skipped.
]]
local function buildMonitors(cfg: any): { any }
	local pss = cfg.Protection.pss
	local sss = cfg.Protection.sss
	local vote3 = cfg.Protection.pssVoting.required
	local votePR = cfg.Protection.powerRangeVoting.required
	local noise = cfg.Instruments.noise
	local gaussian = cfg.Protection.alarmDeadband
	local dnd = cfg.Instruments.dndBackground_cps
	local inhibit = cfg.Protection.coreInletLowInhibit

	return {
		{
			id = "PR-HIGH", label = "Power range high flux", system = "PSS", sense = "above",
			signal = function(self)
				return self.port:read("detectors.pr_pctFP") or { 0 }
			end,
			vote = votePR, alarm = pss.powerRangeHigh.alarm_pctFP, trip = pss.powerRangeHigh.trip_pctFP,
			neutron = true, -- D-055: the pss.bypass command refuses it (the PROT-CHANNEL fault does not; see below)
			-- D-050 as amended: Gaussian, so 3σ of one quadrant's D-025 noise at the alarm setpoint, and the off-delay
			deadband = gaussian.gaussianSigmas * noise.powerRangeRelative * pss.powerRangeHigh.alarm_pctFP,
			offDelay_s = gaussian.offDelay_s,
		},
		{
			--[[
				§9.5 calls this a permissive, not an operator action, so it bypasses itself above 10 %FP and
				re-arms below — which is what makes it a startup protection rather than a nuisance (D-026).
			]]
			id = "PR-LOW-SP", label = "Power range high flux, low setpoint", system = "PSS", sense = "above",
			signal = function(self)
				return self.port:read("detectors.pr_pctFP") or { 0 }
			end,
			vote = votePR, trip = pss.powerRangeLowSetpoint.trip_pctFP, neutron = true,
			armed = function(self)
				return self.power < pss.powerRangeLowSetpoint.activeBelowPermissive_pctFP
			end,
		},
		{
			id = "PERIOD", label = "Period", system = "PSS", sense = "below",
			signal = function(self)
				-- only a positive period is a rising power; §3.5's negative periods are a power fall
				local out = {}
				for i, p in self.port:read("detectors.period_s") or {} do
					out[i] = if p > 0 then p else math.huge
				end
				return out
			end,
			vote = vote3, block = pss.period.rodBlockBelow_s, trip = pss.period.tripBelow_s, neutron = true,
			blockPersist_s = 2, -- D-025: the channel's own noise touches 39 s at 4.5σ, so one sample is not enough
			armed = function(self)
				return self.power < pss.period.activeBelow_pctFP
			end,
		},
		{
			--[[
				The flux rate comes off the median of the four power range channels, so no single failed channel
				can drive it. §9.5's ±: a fall faster than −5 %FP/s is as much a fault as a rise past +10.
			]]
			id = "FLUX-RATE", label = "Flux rate", system = "PSS", sense = "above",
			signal = function(self)
				local rate = self.port:read("detectors.fluxRate_pctFPps") or 0
				-- fold the asymmetric window into one signal: 1.0 means "at the limit", either way
				local up = rate / pss.fluxRate.tripRise_pctFPps
				local down = rate / pss.fluxRate.tripFall_pctFPps
				return { math.max(up, down) }
			end,
			vote = 1, trip = 1.0, neutron = true,
		},
		{
			id = "PQ", label = "Power to flow", system = "PSS", sense = "above",
			signal = function(self)
				local flow = self.port:read("primary.flowFraction") or 1
				return { if flow > 1e-3 then (self.power / 100) / flow else 0 }
			end,
			vote = 1, alarm = pss.powerToFlow.alarm, block = pss.powerToFlow.alarm, trip = pss.powerToFlow.trip,
			armed = function(self)
				return self.power > pss.powerToFlow.activeAbove_pctFP
			end,
		},
		{
			id = "CORE-OUT", label = "Core outlet, mixed", system = "PSS", sense = "above",
			signal = function(self)
				return single((self.port:read("pools.mixedCoreOutletMeasured_K") or 0) - KELVIN)
			end,
			vote = 1, alarm = pss.coreOutletMixed.alarm_C, trip = pss.coreOutletMixed.trip_C,
			-- D-050 as amended: bounded, so the full span of the thermocouple's §2.5 ±1 K, and no off-delay
			deadband = 2 * cfg.Core.flow.thermocoupleNoise_K,
		},
		{
			--[[
				§2.5's flow zoning is designed to level the assembly outlets, so the median of the 301 is what
				each one is expected to read. A pin or a blockage shows up as a deviation from its neighbours,
				and §9.5 wants two of them before tripping.
			]]
			id = "ASSY-DEV", label = "Assembly outlet deviation", system = "PSS", sense = "above",
			signal = function(self)
				local outlets = self.port:read("fuel.assemblyOutlet_K")
				if outlets == nil or #outlets == 0 then
					return { 0 }
				end
				-- two buffers per Protection, refilled every tick: a fresh copy of the 301 outlets to sort and a fresh
				-- deviations table would be 600 slots of garbage every fast tick
				local n = #outlets
				local sorted = self.assySorted
				if #sorted ~= n then
					table.clear(sorted)
					table.clear(self.assyDeviations)
				end
				table.move(outlets, 1, n, 1, sorted)
				table.sort(sorted)
				local expected = sorted[(#sorted + 1) // 2] -- the median; the lower middle of an even count
				local deviations = self.assyDeviations
				for i, v in outlets do
					deviations[i] = v - expected
				end
				return deviations
			end,
			-- §9.5 wants two ADJACENT thermocouples; adjacency needs the mesh neighbour map, so for now any two
			-- count, which trips a little more readily rather than a little less (D-026)
			vote = pss.assemblyOutletDeviation.tripAdjacentChannels,
			alarm = pss.assemblyOutletDeviation.alarm_K,
			block = pss.assemblyOutletDeviation.rodBlock_K,
			trip = pss.assemblyOutletDeviation.trip_K,
		},
		{
			id = "INLET-HIGH", label = "Core inlet high", system = "PSS", sense = "above",
			signal = function(self)
				return single((self.port:read("pools.coreInlet_K") or 0) - KELVIN)
			end,
			vote = 1, alarm = pss.coreInlet.alarmHigh_C, trip = pss.coreInlet.tripHigh_C,
		},
		{
			--[[
				D-004, as Rev A5 states it. Every path through this returns a reason when it inhibits, so
				`protection.inhibited` can annunciate exactly which rule is holding the trip off.
			]]
			id = "INLET-LOW", label = "Core inlet low", system = "PSS", sense = "below",
			signal = function(self)
				return single((self.port:read("pools.coreInlet_K") or 1e4) - KELVIN)
			end,
			vote = 1, alarm = pss.coreInlet.alarmLow_C, trip = pss.coreInlet.tripLow_C,
			armed = function(self): (boolean, string?)
				local mode = self.mode
				for _, m in inhibit.modesAlways do
					if mode == m then
						return false, `Mode {mode}`
					end
				end
				if mode == inhibit.modeWithPssRodsIn and self.port:read("rods.allPssInserted") == true then
					return false, "Mode 3 with every PSS rod in"
				end
				local inlet = (self.port:read("pools.coreInlet_K") or 0) - KELVIN
				if mode == 2 and inlet < inhibit.mode2BelowTemp_C then
					return false, `Mode 2 below {inhibit.mode2BelowTemp_C} °C`
				end
				if mode == 1 and self.power <= inhibit.armedAbove_pctFP then
					return false, `below {inhibit.armedAbove_pctFP} %FP`
				end
				return true
			end,
		},
		{
			id = "LEVEL", label = "Hot pool level against programme", system = "PSS", sense = "below",
			signal = function(self)
				return single(self.port:read("pools.levelDeviation_m"))
			end,
			vote = 1, alarm = -pss.hotPoolLevelDeviation.alarm_m, trip = pss.hotPoolLevelDeviation.trip_m,
		},
		{
			id = "COVER-GAS", label = "Cover gas pressure", system = "PSS", sense = "above",
			signal = function(self)
				return single(self.port:read("pools.coverGas_MPa"))
			end,
			vote = 1, alarm = pss.coverGas.alarm_MPa, trip = pss.coverGas.trip_MPa,
		},
		{
			id = "DND", label = "Delayed neutron detectors", system = "PSS", sense = "above",
			signal = function(self)
				return self.port:read("detectors.dnd_cps") or { 0 }
			end,
			vote = vote3,
			alarm = dnd * pss.delayedNeutrons.alarmFactor,
			trip = dnd * pss.delayedNeutrons.tripFactor,
			-- D-050 as amended: Gaussian, so 3σ of a counting channel's noise at the alarm setpoint, σ = √(R/τ) over
			-- D-025's ratemeter averaging, and the off-delay
			deadband = gaussian.gaussianSigmas * math.sqrt(dnd * pss.delayedNeutrons.alarmFactor / noise.ratemeterAveraging_s),
			offDelay_s = gaussian.offDelay_s,
		},
		{
			id = "PUMPS", label = "Primary pumps lost", system = "PSS", sense = "above",
			signal = function(self)
				local running = self.port:read("primary.pumpsRunning")
				return single(if running then 3 - running else 0)
			end,
			vote = 1, inclusive = true, alarm = pss.primaryPumpsLost.runback, trip = pss.primaryPumpsLost.trip,
			runback = "RB2", -- §9.5's "alarm or first action" column
		},
		{
			id = "LOOPS", label = "Secondary loops lost", system = "PSS", sense = "above",
			signal = function(self)
				local running = self.port:read("ihx.loopsRunning")
				return single(if running then 3 - running else 0)
			end,
			vote = 1, inclusive = true, alarm = pss.secondaryLoopsLost.runback, trip = pss.secondaryLoopsLost.trip,
			runback = "RB1",
		},
		{
			id = "SEISMIC", label = "Seismic", system = "PSS", sense = "above",
			signal = function(self)
				return single(self.port:read("site.seismic_g"))
			end,
			vote = 1, alarm = pss.seismic.alarm_g, trip = pss.seismic.trip_g,
		},
		{
			id = "ELEC-11KV", label = "All 11 kV boards lost", system = "PSS", sense = "below",
			signal = function(self)
				return single(self.port:read("electrical.boards11kV") or 3)
			end,
			vote = 1, trip = 1, -- §9.5: immediate, with no permissive
		},
		-- Secondary shutdown system: diverse sensors, §9.5
		{
			id = "SSS-FLUX", label = "SSS power range", system = "SSS", sense = "above",
			signal = function(self)
				return self.port:read("detectors.pr_pctFP") or { 0 }
			end,
			vote = votePR, trip = sss.powerRange_pctFP, neutron = true,
		},
		{
			--[[
				Diverse by design: the SSS takes its flow from pump speed rather than from the flowmeters the PSS
				uses, so one failed measurement cannot defeat both systems.
			]]
			id = "SSS-PQ", label = "SSS power to flow", system = "SSS", sense = "above",
			signal = function(self)
				local speeds = self.port:read("primary.pumpSpeed_pct")
				local flow = 0
				if speeds then
					for _, s in speeds do
						flow += s / 100
					end
					flow /= 3
				end
				return { if flow > 1e-3 then (self.power / 100) / flow else 0 }
			end,
			vote = 1, trip = sss.powerToFlowPumpSpeedDerived,
		},
		{
			id = "SSS-OUT", label = "SSS core outlet", system = "SSS", sense = "above",
			signal = function(self)
				return single((self.port:read("pools.mixedCoreOutletMeasured_K") or 0) - KELVIN)
			end,
			vote = 1, trip = sss.coreOutlet_C,
		},
	}
end

function Protection.init(self: any, ctx: any)
	local cfg = ctx.config
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.cfg = cfg.Protection
	self.curie = cfg.Rods.curieLatch
	self.monitors = buildMonitors(cfg)
	self.state = {}
	for _, m in self.monitors do
		self.state[m.id] = { alarm = false, block = false, trip = false, blockFor = 0, tripFor = 0, backFor = 0, runbackRan = false }
	end
	self.power = 0
	self.measured = 0
	self.prNoise = cfg.Instruments.noise.powerRangeRelative -- a runback ends within one PR channel's noise (D-046)
	self.mode = 1
	self.tripped = {}
	self.firstOut = ""
	self.pressed = {} :: { [string]: number } -- MCR trip button -> when it was pressed (D-056)
	self.manualWindow = cfg.Protection.manualTripWindow_s
	-- the buttons are two people's hands, so their window is real time, not plant time (which runs at the clock
	-- rate); ctx.realTime lets a test drive it
	self.realTime = ctx.realTime or os.clock
	self.active = {}
	self.inhibited = {}
	self.runback = nil
	self.curieTemp_C = 0
	self.curieStarted = false
	self.bypassed = {} :: { [string]: boolean }
	self.bypassedMax = cfg.Protection.bypassedRowsMax
	self.neutronRow = {} :: { [string]: boolean }
	for _, m in self.monitors do
		self.neutronRow[m.id] = m.neutron == true
	end
	self.assySorted, self.assyDeviations = {}, {} -- ASSY-DEV's working buffers
	self:publish()
end

function Protection.publish(self: any)
	local port = self.port
	local scram = "none"
	if self.tripped.PSS and self.tripped.SSS then
		scram = "both"
	elseif self.tripped.PSS then
		scram = "PSS"
	elseif self.tripped.SSS then
		scram = "SSR"
	end
	port:write("protection.scram", scram)
	port:write("protection.tripped", scram ~= "none")
	port:write("protection.firstOut", self.firstOut)
	port:write("protection.active", self.active)
	port:write("protection.inhibited", self.inhibited)
	port:write("protection.rodWithdrawalBlock", self.blocked == true)
	port:write("protection.rodRunback", self.runback ~= nil and self.runback.driveIn == true)
	port:write("protection.runback", if self.runback then self.runback.id else "")
	port:write("protection.runbackTarget_pctFP", if self.runback then self.runback.target else 100)
	port:write("protection.runbackRate_pctpmin", if self.runback then self.runback.rate else 0)
end

--[[
	Fire a trip. The first one latches as first-out and is not overwritten: after any shutdown the question is
	which signal went first, and a later consequence of the first trip must not be allowed to claim it.
]]
function Protection.fire(self: any, id: string, label: string, system: string, actor: Actor?)
	local key = if system == "SSS" then "SSS" else "PSS"
	local firstEver = self.firstOut == ""
	if firstEver then
		self.firstOut = id
	end
	if not self.tripped[key] then
		self.tripped[key] = true
		if self.log then
			self.log:record("reactor.trip", actor, id, label, if firstEver then "TRIP (first out)" else "TRIP")
		end
		if self.bus then
			self.bus:publish("Trip", { system = "Protection", reason = label, firstOut = self.firstOut })
		end
	end
end

--[[
	Start a runback (§9.5, D-046). A more severe one replaces a milder one; the same one twice does nothing. Its power
	demand starts at the measured neutron power, and `driveIn` is set each tick while the power is above it.
]]
function Protection.startRunback(self: any, id: string, actor: Actor?)
	local spec = self.cfg.runbacks[id]
	-- a runback runs to a depth; RB-3's is "bypass-limited", which M1 cannot evaluate (no turbines, no bypass yet)
	if spec == nil or type(spec.target_pctFP) ~= "number" then
		return false
	end
	if self.runback and self.runback.target <= spec.target_pctFP then
		return false -- already running something at least as deep
	end
	self.runback = {
		id = id,
		target = spec.target_pctFP,
		rate = spec.rate_pctpmin,
		demand = self.measured,
		driveIn = false,
	}
	if self.log then
		self.log:record("runback", actor, id, spec.trigger, `to {spec.target_pctFP} %FP at {spec.rate_pctpmin} %/min`)
	end
	if self.bus then
		self.bus:publish("Runback", {
			id = id,
			target_pctFP = spec.target_pctFP,
			rate_pctpmin = spec.rate_pctpmin,
			reason = spec.trigger,
		})
	end
	return true
end

--[[
	One tick of a running runback (D-046): ramp the demand toward the target at the table rate, ask for the shim
	drive-in while the measured power is above the demand, and finish once the demand is at the target and the power
	is within one PR channel's noise of it.
]]
function Protection.followRunback(self: any, dt: number)
	local rb = self.runback
	if rb == nil then
		return
	end
	if rb.demand > rb.target then
		rb.demand = math.max(rb.target, rb.demand - rb.rate / 60 * dt)
	end
	local measured = self.measured
	rb.driveIn = measured > rb.demand
	if rb.demand <= rb.target and measured <= rb.target * (1 + self.prNoise) then
		if self.log then
			self.log:record("runback", nil, rb.id, string.format("%.1f %%FP", measured), "complete")
		end
		self.runback = nil
	end
end

function Protection.step(self: any, dt: number)
	local port = self.port
	self.power = port:read("core.power_pctFP") or 0
	self.measured = port:read("detectors.prMean_pctFP") or self.power -- the neutron power a runback follows (D-046)
	-- D-056: an MCR trip button's press counts toward the trip only within the window, in real time
	local now = self.realTime()
	for button, at in self.pressed do
		if now - at > self.manualWindow then
			self.pressed[button] = nil
		end
	end
	self.mode = port:read("program.mode") or 1
	local active, inhibited = {}, {}
	local blocked = false

	for _, m in self.monitors do
		local st = self.state[m.id]
		local armed, why = true, nil
		if m.armed then
			armed, why = m.armed(self)
		end
		if not armed then
			if st.alarm and self.bus then
				-- the row stops being watched, so its alarm has gone: say so, or the annunciator shows it forever
				self.bus:publish("Alarm", { tag = m.id, priority = 2, state = "out", text = m.label })
			end
			st.alarm, st.block, st.trip = false, false, false
			st.blockFor, st.tripFor, st.backFor = 0, 0, 0
			if why then
				table.insert(inhibited, `{m.id}: {why}`)
			end
			continue
		end
		local values = m.signal(self)

		if m.alarm then
			--[[
				One channel past an alarm setpoint is what an annunciator is for: only the TRIP waits for the
				coincidence vote. An alarm that needed two channels would hide the first failing instrument. Once in,
				it holds while any channel is short of the row's deadband, and goes out once every channel has been
				back past it for the row's off-delay (D-050 as amended). `backFor` is a sum of whole ticks, so it is
				compared at the nearest tick: with no off-delay the alarm goes out on the first tick back.
			]]
			local hit
			if not st.alarm then
				hit = voted(values, m.sense, m.alarm, 1, m.inclusive)
			else
				local edge = m.alarm
				if m.deadband then
					edge = if m.sense == "above" then edge - m.deadband else edge + m.deadband
				end
				local held = voted(values, m.sense, edge, 1, m.inclusive)
				st.backFor = if held then 0 else st.backFor + dt
				hit = held or st.backFor < (m.offDelay_s or 0) - dt / 2
			end
			if hit ~= st.alarm then
				st.alarm = hit
				st.backFor = 0
				if self.bus then
					self.bus:publish("Alarm", {
						tag = m.id,
						priority = 2,
						state = if hit then "in" else "out",
						text = m.label,
					})
				end
			end
			if hit then
				table.insert(active, m.id)
			end
		end

		if m.block then
			-- a rod block is a mild, reversible action, so any one channel raises it (D-025's persistence,
			-- not the vote, is what keeps instrument noise out)
			local hit = voted(values, m.sense, m.block, 1, m.inclusive)
			-- D-025: a row may require the condition to persist, so instrument noise cannot raise a block alone
			st.blockFor = if hit then st.blockFor + dt else 0
			st.block = hit and st.blockFor >= (m.blockPersist_s or 0)
			blocked = blocked or st.block
		end

		if m.trip and not self.bypassed[m.id] then
			local hit = voted(values, m.sense, m.trip, m.vote, m.inclusive)
			st.tripFor = if hit then st.tripFor + dt else 0
			if hit and st.tripFor >= (m.tripPersist_s or 0) then
				if not st.trip then
					st.trip = true
					self:fire(m.id, m.label, m.system)
				end
			else
				st.trip = false
			end
		end

		--[[
			§9.5's "alarm or first action" column is a runback for the pump and loop rows. Once a row's runback has
			run, cleared or finished, it waits for the trigger to reset and come back (D-046). One refused because a
			deeper runback was already running has not run, so it starts once that one is out of the way, if its
			trigger is still there.
		]]
		if m.runback then
			if not st.alarm then
				st.runbackRan = false
			elseif not st.runbackRan and self:startRunback(m.runback) then
				st.runbackRan = true
			end
		end
	end

	self:followRunback(dt)

	-- §9.5's other rod withdrawal blocks, which are conditions rather than measured signals
	--[[
		§9.5: "RR out of band during a BANK move". The bank part is load-bearing. Blocking whenever anything is
		selected would block the operator's own regulating-rod move — and since the rods boot fully inserted, at
		0 mm, they start outside the 250–750 mm band, so the block would prevent the one move that clears it. The
		plant could never be started. The rule is about moving a bank while the regulating rods have no authority
		left to trim with.
	]]
	if self.port:read("rods.regulatingInBand") == false and self.port:read("rods.selectionKind") == "bank" then
		blocked = true
	end
	local balance = self.port:read("core.reactivityBalance_pcm")
	if balance and math.abs(balance) > self.cfg.rodBlocks.reactivityBalanceBeyond_pcm then
		blocked = true
	end
	self.blocked = blocked

	-- §9.5: each SSR has a Curie-point latch that releases at 640 °C local sodium, with a thermal lag
	local outlets = port:read("fuel.assemblyOutlet_K")
	if outlets and #outlets > 0 then
		local hottest = 0
		for _, v in outlets do
			hottest = math.max(hottest, v)
		end
		local target = hottest - KELVIN
		if not self.curieStarted then
			-- the latch sits at the local sodium temperature; starting it at zero would invent a 20 s head start
			self.curieTemp_C = target
			self.curieStarted = true
		end
		self.curieTemp_C += (target - self.curieTemp_C) * (1 - math.exp(-dt / self.curie.thermalLag_s))
		if self.curieTemp_C > self.curie.releaseSodium_C and not self.tripped.SSS then
			self:fire("CURIE", "SSR Curie-point latch released", "SSS")
		end
	end

	self.active = active
	self.inhibited = inhibited
	self:publish()
end

--[[
	Reset. Refused while any trip condition is still present, because a reset that leaves the plant tripping again
	on the next tick teaches the crew that the reset button is noise.
]]
function Protection.reset(self: any, actor: Actor?): (boolean, string?)
	if not (self.tripped.PSS or self.tripped.SSS) then
		return false, "not tripped"
	end
	for _, m in self.monitors do
		if self.state[m.id].trip then
			return false, `{m.id} is still present`
		end
	end
	self.tripped = {}
	self.firstOut = ""
	table.clear(self.pressed)
	for _, st in self.state do
		st.trip, st.tripFor = false, 0
	end
	if self.log then
		self.log:record("reactor.trip.reset", actor, "protection", nil, "reset")
	end
	self:publish()
	return true
end

Protection.commands = {
	--[[
		§9.5: two buttons in the main control room, or one in the backup. In the MCR they are two different
		buttons, MCR-1 and MCR-2, pressed within D-056's window of each other: one operator leaning on one button
		does not trip the plant, and nor do two presses that are not one act. The window is real time, since it is
		about two people's hands; plant time runs at the clock rate. A press older than the window is forgotten
		(Protection.step). The BCR's one button trips on its own.
	]]
	["reactor.trip.manual"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local button = cmd.target
		if button == "BCR" then
			self:fire("MANUAL", "Manual trip (BCR)", "PSS", actor)
			return { ok = true }
		end
		local needed = self.cfg.pss.manualButtons.mainControlRoom
		local index = if button then tonumber(string.match(button, "^MCR%-(%d+)$")) else nil
		if index == nil or index < 1 or index > needed then
			return { ok = false, reason = `no trip button '{tostring(button)}': MCR-1 to MCR-{needed}, or BCR` }
		end
		local now = self.realTime()
		self.pressed[button :: string] = now
		local held = 0
		for _, at in self.pressed do
			if now - at <= self.manualWindow then
				held += 1
			end
		end
		if held >= needed then
			self:fire("MANUAL", "Manual trip (MCR)", "PSS", actor)
			return { ok = true }
		end
		return { ok = true, reason = `{held} of {needed} buttons` }
	end,

	["sss.trip.manual"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		self:fire("SSS-MANUAL", "Manual secondary shutdown", "SSS", actor)
		return { ok = true }
	end,

	["reactor.trip.reset"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local ok, why = self:reset(actor)
		return { ok = ok, reason = why }
	end,

	--[[
		A bypass is a deliberate, logged, visible act: §9.6's LCOs are written around which protection is
		available, so a bypassed trip has to be something an auditor can find afterwards. D-055 limits it: the
		command is a critical control (the §10.7 playtime, Access.criticalControls); at most bypassedRowsMax rows
		are out of service at once; and the command refuses a row the neutron instruments drive (the power range
		high and low setpoint, flux rate, period, and the SSS power range), because those are the trips that answer
		a reactivity excursion. Once the desks exist a bypass will also need §10.2's shift-supervisor authorisation.
		These limits are the command's. The PROT-CHANNEL fault below bypasses a row without them, and restoring the
		row here takes the fault's bypass away too (docs/review/DECISIONS_NEEDED.md, M7+).
	]]
	["pss.bypass"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local id = cmd.target
		if id == nil or self.state[id] == nil then
			return { ok = false, reason = `unknown protective signal '{tostring(id)}'` }
		end
		local on = cmd.value ~= 0
		if on and not self.bypassed[id] then
			if self.neutronRow[id] then
				return { ok = false, reason = `{id} is a neutron trip and cannot be bypassed` }
			end
			local out = {}
			for row in self.bypassed do
				table.insert(out, row)
			end
			if #out >= self.bypassedMax then
				table.sort(out)
				return { ok = false, reason = `{table.concat(out, ", ")} is already bypassed; restore it first` }
			end
		end
		self.bypassed[id] = on or nil
		if self.log then
			self.log:record("pss.bypass", actor, id, nil, if on then "BYPASSED" else "restored")
		end
		return { ok = true }
	end,

	["runback.start"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local id = cmd.target
		if id == nil or self.cfg.runbacks[id] == nil then
			return { ok = false, reason = `unknown runback '{tostring(id)}'` }
		end
		if type(self.cfg.runbacks[id].target_pctFP) ~= "number" then
			return { ok = false, reason = `{id} runs to a {tostring(self.cfg.runbacks[id].target)} target the plant does not model yet` }
		end
		if not self:startRunback(id, actor) then
			return { ok = false, reason = "a runback at least this deep is already running" }
		end
		return { ok = true }
	end,

	["runback.clear"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		if self.runback == nil then
			return { ok = false, reason = "no runback is running" }
		end
		if self.log then
			self.log:record("runback", actor, self.runback.id, nil, "cleared")
		end
		self.runback = nil
		self:publish()
		return { ok = true }
	end,
}

Protection.faults = {
	{
		id = "PROT-CHANNEL",
		label = "Protection channel bypassed",
		cost = 3,
		eligible = function(_snapshot: any)
			return true
		end,
		--[[
			A protective signal left bypassed — the way a real plant finds out it has been running without a trip
			is usually the surveillance that trips over it, not the event itself.

			The fault sets the bypass directly, not through pss.bypass, so none of D-055's limits applies to it: it
			is not counted against bypassedRowsMax (though a row it holds does count against the operator's next
			bypass), it bypasses a neutron row as readily as any other, and with no `signal` it bypasses PR-HIGH,
			which is a neutron row. Its clear removes the row's bypass whoever set it. Whether that is right is open
			for Aqua (docs/review/DECISIONS_NEEDED.md, M7+); until then the behaviour is left as it is.
		]]
		arm = function(self: any, params: { [string]: any }?)
			local id = (params and params.signal) or "PR-HIGH"
			self.bypassed[id] = true
			if self.log then
				self.log:record("pss.bypass", nil, id, "fault PROT-CHANNEL", "BYPASSED")
			end
		end,
		clear = function(self: any, params: { [string]: any }?)
			local id = (params and params.signal) or "PR-HIGH"
			self.bypassed[id] = nil
		end,
	},
}

--[[
	§14.6 (D-053): the trip bypasses, and the trip itself. A server close counts as a reactor trip, so a loaded plant
	comes back with the PSS tripped: with the first out it had if it was already tripped, SERVER-CLOSE otherwise.
	A bypass the PROT-CHANNEL fault holds is in the slice like any other; Faults.restore marks the fault active and
	does not bypass the row again.
]]
function Protection.save(self: any): any
	local bypassed = {}
	for id in self.bypassed do
		table.insert(bypassed, id)
	end
	table.sort(bypassed)
	return { bypassed = bypassed, tripped = table.clone(self.tripped), firstOut = self.firstOut }
end

function Protection.load(self: any, data: any, _version: number)
	table.clear(self.bypassed)
	if type(data.bypassed) == "table" then
		for _, id in data.bypassed do
			if type(id) == "string" and self.state[id] ~= nil then
				self.bypassed[id] = true
			end
		end
	end
	local was = if type(data.tripped) == "table" then data.tripped else {}
	self.tripped = { PSS = true, SSS = if was.SSS == true then true else nil }
	self.firstOut = if type(data.firstOut) == "string" and data.firstOut ~= "" then data.firstOut else "SERVER-CLOSE"
	if self.log and was.PSS ~= true then
		self.log:record("reactor.trip", nil, "SERVER-CLOSE", "the server closed, which counts as a reactor trip (D-053)",
			if self.firstOut == "SERVER-CLOSE" then "TRIP (first out)" else "TRIP")
	end
	self.runback = nil
	table.clear(self.pressed)
	self:publish()
end

function Protection.getState(self: any): { [string]: any }
	local rows = {}
	for _, m in self.monitors do
		local st = self.state[m.id]
		rows[m.id] = {
			label = m.label,
			system = m.system,
			alarm = st.alarm,
			block = st.block,
			trip = st.trip,
			bypassed = self.bypassed[m.id] == true,
		}
	end
	return {
		monitors = rows,
		tripped = { PSS = self.tripped.PSS == true, SSS = self.tripped.SSS == true },
		firstOut = self.firstOut,
		active = table.clone(self.active),
		inhibited = table.clone(self.inhibited),
		blocked = self.blocked == true,
		runback = self.runback,
		manual = table.clone(self.pressed),
		curieTemp_C = self.curieTemp_C,
	}
end

return Protection
