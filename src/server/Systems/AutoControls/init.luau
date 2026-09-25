--!strict
--[[
	AutoControls — rod auto and primary flow auto: competent, local and reactive (spec §9.4 Rev A6, §9.2, D-059).
	===============================================================================================================

	Each controller holds its own variable by feedback on its own measurement, moving its own actuator as fast as the
	error needs within the equipment's limits, and settles without overshooting. Neither anticipates a disturbance,
	coordinates with the other, or sees a fault outside its loop: those are what a crew does better (D-059).

	**Rod auto** holds the core outlet within §9.4's ±2 K, using the regulating rods only.
	  - It acts on the mixed-outlet thermocouple, with §2.5's 3 s lag and ±1 K noise: the real measurement. It reads
	    it through a short filter (Config.Program.rodAutoTuning), because a move sized on one noisy reading is off by
	    up to 0.9 K, and against a ±2 K band that is enough to make the next move reverse.
	  - It knows what its own moves are still going to do (D-059, option A). A regulating rod's effect on the outlet
	    has two timescales: about half arrives within 10 s as the core's power moves, and the rest over minutes as the
	    plant's heat balance settles against the heat sink. Watching the thermocouple alone, it would see too little,
	    move again, and overshoot once the slow part landed. So it keeps a copy of the four modes
	    tools/derive/auto_tuning.py fitted to the plant's measured response (Config.Program.rodAutoModel),
	    interpolated in power and driven by the regulating rods' actual moves, and acts on the measured error plus
	    what those moves have yet to do. The copy runs through the same filter as the reading, so the filter delays
	    what it sees of a disturbance but never what it expects of its own moves.
	  - Outside the band it moves one regulating rod by correctionFraction of what that predicted error calls for,
	    solved in reactivity through §3.4's S-curve: the target is the position whose worth differs from the rod's by
	    the reactivity needed. Then it lets the move arrive. The fraction allows for §3.7's ±10 % rod-worth tolerance.
	  - It moves ONE regulating rod at a time (D-006, finding F6), picking the one that keeps the three together: the
	    most-inserted rod when withdrawing, the most-withdrawn when inserting.
	  - It never moves a shim. When the regulating rods reach the 250–750 mm band it stops and alarms, and the crew
	    re-shims (§9.4, §10.5).

	**Primary flow auto** holds P/Q on the §9.2 programme.
	  - The flow is (Σ running speeds)/300, one to one with speed and limited only by §4.2's 2 %/s ramp, so it asks
	    the pumps it has running for the speed that gives the programme's flow, and the ramp does the rest. When a
	    pump trips it sees one fewer running and asks the others for more, within their 105 % (§4.2's drives hold them
	    at 105 % first, D-046).
	  - The programme is indexed on the PR median, the real measurement, through a short filter derived from D-025's
	    noise (Config.Program.primaryFlowAutoTuning), so noise never shows as pump motion.

	**Both track the §9.2 programme rather than fixed values** (D-003, finding F3). §9.4 says rod auto holds
	550 °C and flow auto holds P/Q = 1.00, but §9.2's programme holds neither below 40 %FP: the core outlet falls
	to 506 °C at 30 %FP and the flow floors at 40 %, so P/Q rises above 1. The setpoint is therefore 375 + 175·(P/Q),
	which reproduces every row of §9.2's table, and the flow demand is the programme's own flow curve.

	**The setpoint's P is the steam plant's load, not the reactor's power** (D-034). On the 40 % flow floor a
	setpoint computed from measured power rises with power exactly as fast as the outlet does, so the error collapses
	to (inlet − 375 °C). Indexing the programme on load is how real plants do it (a PWR's T_ref is programmed on
	turbine load). With no steam plant on the channels, as in unit tests of this system alone, it falls back to the
	measured power.

	Neither controller touches another system's state directly. They publish demands, and RodDrives and PrimaryPumps
	read them like any other input, so every §3.4 interlock and §9.5 rod block applies to the automatic controllers
	exactly as it does to an operator.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local PartLoad = require(script.Parent.PartLoad)
local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Types = require(Kallskar:WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local AutoControls = System.extend({
	name = "AutoControls",
	lane = "fast",
	reads = {
		"pools.mixedCoreOutletMeasured_K",
		"core.power_pctFP",
		"detectors.prMean_pctFP",
		"primary.flowFraction",
		"primary.pumpsRunning",
		"ihx.sinkLoad_pct",
	},
	readsLagged = {
		"rods.position_mm",
		"protection.rodWithdrawalBlock",
		"protection.runback",
		"protection.scram",
	},
	writes = {
		"auto.rodOn",
		"auto.rodSelected",
		"auto.rodDemand_mm",
		"auto.rodOutOfBand",
		"auto.flowOn",
		"auto.pumpSpeedDemand_pct",
		"auto.coreOutletSetpoint_C",
		"auto.flowProgram_pct",
		"auto.filteredPower_pctFP",
	},
})

local KELVIN = 273.15
local TAU = 2 * math.pi
local BAND_ALARM = "Rod auto at the regulating band limit"

-- §9.2's programme lives in PartLoad, shared with the heat sink. Holding its outlet rather than §9.4's flat 550 °C
-- is what keeps the 30 %FP row on 40 % flow at 506 °C (D-003).
local programOutlet = PartLoad.outlet_C
local programFlow = PartLoad.flow_pct

-- §3.4's S-curve, as RodDrives has it: the fraction of a rod's worth inserted at depth d
local function worthFraction(d: number): number
	return d - math.sin(TAU * d) / TAU
end

function AutoControls.init(self: any, ctx: any)
	local cfg = ctx.config
	self.cfg = cfg
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.rodCfg = cfg.Program.rodAuto
	self.flowTuning = cfg.Program.primaryFlowAutoTuning
	self.model = cfg.Program.rodAutoModel
	self.filter_s = cfg.Program.rodAutoTuning.measurementFilter_s
	self.band = cfg.Program.rodAuto.regulatingBand_mm
	self.regulatingCount = cfg.Rods.regulating.count
	self.pumpCount = cfg.Primary.pumps.count
	self.speedRange = cfg.Primary.pumps.speedRange_pct
	self.travel_mm = cfg.Units.rodTravel_mm
	self.active_mm = cfg.Core.geometry.fissileHeight_mm
	-- the S-curve's slope at the position the model was measured at, per mm: one "equivalent millimetre" of reactivity
	self.slopeAtModel = (1 - math.cos(TAU * self:depth(self.model.measuredAt_mm))) / self.active_mm

	self.rodOn = false
	self.flowOn = false
	self.selected = ""
	self.demand_mm = 0
	self.target_mm = nil :: number?
	self.outOfBand = false
	self.direction = nil
	self.filteredPower = 0
	self.started = false

	-- rod auto's model of its own moves (D-059): the modes' gains and time constants at the present power, and its
	-- copy of their states, all driven by the regulating rods' moves in 500-mm equivalent millimetres
	local n = #self.model.byPower[1].modes
	self.modeGain = table.create(n, 0)
	self.modeTau = table.create(n, 1)
	self.imcX = table.create(n, 0)
	self.imcY = table.create(n, 0) -- the mode states as the measurement filter passes them
	self.imcU = 0
	self.filtered_K = 0 -- the thermocouple through the filter
	self.filterSamples = 0 -- readings since the filter last started
	self.lastRR = table.create(self.regulatingCount, -1) -- -1: not yet seen
	self.pending_K = 0
	self.effective_K = 0
	self:publish()
end

function AutoControls.publish(self: any)
	local port = self.port
	port:write("auto.rodOn", self.rodOn)
	port:write("auto.rodSelected", self.selected)
	port:write("auto.rodDemand_mm", self.demand_mm)
	port:write("auto.rodOutOfBand", self.outOfBand)
	port:write("auto.flowOn", self.flowOn)
	port:write("auto.pumpSpeedDemand_pct", self.speedDemand or 100)
	port:write("auto.coreOutletSetpoint_C", self.setpoint_C or 0)
	port:write("auto.flowProgram_pct", self.flowProgram or 100)
	port:write("auto.filteredPower_pctFP", self.filteredPower)
end

-- RodDrives.depthOf: the fraction of the active height a rod at this position is inserted
function AutoControls.depth(self: any, z_mm: number): number
	return math.clamp((self.travel_mm - z_mm) / self.active_mm, 0, 1)
end

-- A regulating rod's move in reactivity, in the millimetres at the model's 500 mm that would add as much
function AutoControls.equivalentMm(self: any, fromZ: number, toZ: number): number
	return (worthFraction(self:depth(fromZ)) - worthFraction(self:depth(toZ))) / self.slopeAtModel
end

-- The position that moves `eq` equivalent millimetres from `fromZ`, within the regulating band (bisection)
function AutoControls.positionFor(self: any, fromZ: number, eq: number): number
	local lo, hi = self.band[1], self.band[2]
	if eq > 0 and self:equivalentMm(fromZ, hi) <= eq then
		return hi
	elseif eq < 0 and self:equivalentMm(fromZ, lo) >= eq then
		return lo
	end
	local a, b = if eq > 0 then fromZ else lo, if eq > 0 then hi else fromZ
	for _ = 1, 40 do
		local m = (a + b) / 2
		if self:equivalentMm(fromZ, m) < eq then -- the equivalent millimetres rise with position, either way
			a = m
		else
			b = m
		end
	end
	return (a + b) / 2
end

-- The model's modes at a power: linear between the fitted powers, and held at the ends
function AutoControls.interpolateModes(self: any, power: number)
	local byPower = self.model.byPower
	local lo, hi, w = byPower[1], byPower[#byPower], 0
	if power <= lo.power_pctFP then
		hi = lo
	elseif power >= hi.power_pctFP then
		lo = hi
	else
		for k = 1, #byPower - 1 do
			if power <= byPower[k + 1].power_pctFP then
				lo, hi = byPower[k], byPower[k + 1]
				break
			end
		end
		w = (power - lo.power_pctFP) / (hi.power_pctFP - lo.power_pctFP)
	end
	for i, mode in lo.modes do
		local other = hi.modes[i]
		self.modeGain[i] = mode.gain_Kpmm + w * (other.gain_Kpmm - mode.gain_Kpmm)
		self.modeTau[i] = mode.tau_s + w * (other.tau_s - mode.tau_s)
	end
end

--[[
	Drive the model with the regulating rods' actual moves, whoever made them, so the prediction is always of what
	really moved: interlocks, stops and an operator's moves before auto went in included.
]]
function AutoControls.trackOwnMoves(self: any, dt: number)
	local positions = self.port:read("rods.position_mm")
	if positions ~= nil then
		for i = 1, self.regulatingCount do
			local z = positions[i] -- the regulating rods are the first drives RodDrives builds (§2.2 order)
			if z ~= nil then
				local was = self.lastRR[i]
				if was >= 0 and z ~= was then
					self.imcU += self:equivalentMm(was, z)
				end
				self.lastRR[i] = z
			end
		end
	end
	--[[
		The filter. It starts as the running mean of the readings since it last started, so its first value is not
		one reading's noise, and becomes first order once that mean spans the time constant. The mode states pass
		through the same gains, which keeps "filtered reading + pending" exactly what the plant will show once the
		moves have arrived.
	]]
	local measured = self.port:read("pools.mixedCoreOutletMeasured_K")
	local gain = 1 - math.exp(-dt / self.filter_s)
	if measured ~= nil then
		self.filterSamples += 1
		gain = math.max(gain, 1 / self.filterSamples)
		self.filtered_K += (measured - self.filtered_K) * gain
	end
	local pending = 0
	for i, tau in self.modeTau do
		self.imcX[i] += (self.imcU - self.imcX[i]) * (1 - math.exp(-dt / tau))
		self.imcY[i] += (self.imcX[i] - self.imcY[i]) * gain
		pending += self.modeGain[i] * (self.imcU - self.imcY[i])
	end
	self.pending_K = pending
end

-- Nothing of the rods' past moves is still to come: after a seat, a load or a reset
function AutoControls.forgetMoves(self: any)
	for i in self.imcX do
		self.imcX[i] = self.imcU
		self.imcY[i] = self.imcU
	end
	self.filterSamples = 0 -- and the filter starts again on what the thermocouple reads now
	for i in self.lastRR do
		self.lastRR[i] = -1
	end
	self.pending_K = 0
end

--[[
	Pick the regulating rod to move. Moving them one at a time is D-006, and choosing the one that is furthest behind
	in the direction of travel keeps the three roughly together, which is what a rod sequencer does.
]]
function AutoControls.chooseRod(self: any, withdrawing: boolean): (string?, number?)
	local positions = self.port:read("rods.position_mm")
	if positions == nil then
		return nil, nil
	end
	local bestName, bestPos = nil, nil
	for i = 1, self.regulatingCount do
		local pos = positions[i]
		if pos == nil then
			continue
		end
		local usable = if withdrawing then pos < self.band[2] else pos > self.band[1]
		if usable then
			-- withdrawing: take the most-inserted rod; inserting: take the most-withdrawn
			if bestPos == nil or (withdrawing and pos < bestPos) or (not withdrawing and pos > bestPos) then
				bestName, bestPos = `RR{i}`, pos
			end
		end
	end
	return bestName, bestPos
end

-- Where the named regulating rod stands, if RodDrives has said
function AutoControls.rodPosition(self: any, name: string): number?
	local positions = self.port:read("rods.position_mm")
	local index = tonumber(string.sub(name, 3))
	return if positions ~= nil and index ~= nil then positions[index] else nil
end

-- Rod auto has authority again, or is out of service: the band alarm goes, and the annunciator is told so
function AutoControls.clearOutOfBand(self: any)
	if self.outOfBand then
		self.outOfBand = false
		if self.bus then
			self.bus:publish("Alarm", { tag = "AUTO-ROD-BAND", priority = 2, state = "out", text = BAND_ALARM })
		end
	end
end

function AutoControls.raiseOutOfBand(self: any)
	if not self.outOfBand then
		self.outOfBand = true
		if self.log then
			self.log:record("auto.rod", nil, "rod auto", "regulating rods at the band limit", "ALARM")
		end
		if self.bus then
			self.bus:publish("Alarm", { tag = "AUTO-ROD-BAND", priority = 2, state = "in", text = BAND_ALARM })
		end
	end
end

function AutoControls.stopRods(self: any, reason: string?)
	if self.selected ~= "" then
		self.selected = ""
		self.target_mm = nil
		if reason and self.log then
			self.log:record("auto.rod", nil, "rod auto", reason, "stopped")
		end
	end
end

-- Seat on a steady plant (plan: initial conditions): the filter on the power it finds, and no move still to come
function AutoControls.seat(self: any, power_pctFP: number)
	self.filteredPower = power_pctFP
	self.started = true
	self.flowProgram = programFlow(self.cfg, power_pctFP)
	self:forgetMoves()
end

-- Rod auto, once it is in and neither a trip nor a runback has it stood down
function AutoControls.rodAuto(self: any)
	local port = self.port
	if self.filterSamples == 0 then
		return -- no reading yet
	end
	-- the error it will have once its moves have arrived: what the thermocouple shows, plus what is still to come
	local effective = (self.filtered_K - KELVIN) - self.setpoint_C + self.pending_K
	self.effective_K = effective
	local band = self.rodCfg.holdBand_K
	local block = port:read("protection.rodWithdrawalBlock") == true

	if self.selected ~= "" then
		-- a move is on its way: let it arrive, unless it is done, blocked, or the error now calls the other way
		local at = self:rodPosition(self.selected)
		local done = at == nil or self.target_mm == nil or math.abs(at - (self.target_mm :: number)) < 1e-6
		local reversed = math.abs(effective) > band and (effective < 0) ~= self.direction
		if done or reversed or (self.direction and block) then
			self:stopRods(if self.direction and block then "rod withdrawal block" else nil)
		else
			return
		end
	end

	if math.abs(effective) <= band then
		self:clearOutOfBand()
		return
	end
	-- too hot: insert to bring power down. Too cold: withdraw.
	local withdrawing = effective < 0
	if withdrawing and block then
		return
	end
	local name, pos = self:chooseRod(withdrawing)
	if name == nil or pos == nil then
		-- §9.4: it stops and alarms at the band edge, and it never reaches for a shim to get itself out of trouble
		self:raiseOutOfBand()
		return
	end
	local gain = 0
	for _, g in self.modeGain do
		gain += g
	end
	local target = self:positionFor(pos, -self.model.correctionFraction * effective / gain)
	if math.abs(target - pos) < 1e-6 then
		self:raiseOutOfBand() -- the band leaves this rod nothing to give
		return
	end
	self:clearOutOfBand()
	self.selected = name
	self.direction = withdrawing
	self.target_mm = target
	self.demand_mm = target
end

function AutoControls.step(self: any, dt: number)
	local port = self.port
	-- flow auto's measurement is the PR median; without Detectors (a unit test of this system alone), the power
	local power = port:read("core.power_pctFP") or 0
	local measured = port:read("detectors.prMean_pctFP") or power
	if not self.started then
		self.filteredPower = measured
		self.started = true
	else
		self.filteredPower += (measured - self.filteredPower) * (1 - math.exp(-dt / self.flowTuning.powerFilter_s))
	end

	local flowFraction = port:read("primary.flowFraction") or 1
	local load = port:read("ihx.sinkLoad_pct") or self.filteredPower -- D-034: the programme is indexed on load
	self.setpoint_C = programOutlet(self.cfg, load / 100, flowFraction)
	self.flowProgram = programFlow(self.cfg, self.filteredPower)

	-- Primary flow auto: the speed that gives the programme's flow with the pumps running
	local running = port:read("primary.pumpsRunning") or self.pumpCount
	if self.flowOn then
		self.speedDemand = if running > 0
			then math.clamp(self.flowProgram * self.pumpCount / running, self.speedRange[1], self.speedRange[2])
			else self.flowProgram
	end

	-- Rod auto's model of its own moves runs whether or not rod auto is in, so it is current when it goes in
	self:interpolateModes(self.filteredPower)
	self:trackOwnMoves(dt)

	local scrammed = port:read("protection.scram")
	local runback = port:read("protection.runback")
	if self.rodOn then
		if scrammed and scrammed ~= "none" then
			--[[
				A trip drops rod auto to manual, as it does on real plants (D-035). Standing down and waiting is not
				enough: once the trip is reset, a controller still in auto would find the outlet below its hot standby
				setpoint and start withdrawing regulating rods from a shut-down core, which is a startup and has to be
				the crew's decision.
			]]
			self:stopRods("reactor trip")
			self.rodOn = false
			self:clearOutOfBand()
			if self.log then
				self.log:record("auto.rod", nil, "rod auto", `reactor trip ({scrammed})`, "manual")
			end
		elseif runback and runback ~= "" then
			-- a runback is not something to negotiate with, but it ends, and rod auto takes over again after it
			self:stopRods("runback in progress")
		else
			self:rodAuto()
		end
	end
	self:publish()
end

AutoControls.commands = {
	["auto.rod"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local on = cmd.value ~= 0
		self.rodOn = on
		if not on then
			self:stopRods()
			self:clearOutOfBand()
		end
		if self.log then
			self.log:record("auto.rod", actor, "rod auto", nil, if on then "auto" else "manual")
		end
		self:publish()
		return { ok = true }
	end,

	["auto.flow"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local on = cmd.value ~= 0
		self.flowOn = on
		if self.log then
			self.log:record("auto.flow", actor, "primary flow auto", nil, if on then "auto" else "manual")
		end
		self:publish()
		return { ok = true }
	end,
}

--[[
	D-053: which controllers were in, and flow auto's speed demand, which the pumps read a tick late: without it the
	first tick after a load would publish the boot default of 100 % and every running pump would step toward it. A
	loaded plant is tripped, and a trip drops rod auto to manual (D-035), so nothing of its model needs keeping.
]]
function AutoControls.save(self: any): any
	return { rodOn = self.rodOn, flowOn = self.flowOn, speedDemand = self.speedDemand }
end

function AutoControls.load(self: any, data: any, _version: number)
	self.flowOn = data.flowOn == true
	if type(data.speedDemand) == "number" then
		self.speedDemand = data.speedDemand
	end
	if data.rodOn == true and self.log then
		self.log:record("auto.rod", nil, "rod auto", "reactor trip (server close)", "manual")
	end
	self.rodOn = false
	self.started = false -- flow auto's power filter starts again on the power it finds
	self:forgetMoves()
	self:publish()
end

function AutoControls.getState(self: any): { [string]: any }
	return {
		rodOn = self.rodOn,
		rodSelected = self.selected,
		rodDemand_mm = self.demand_mm,
		rodOutOfBand = self.outOfBand,
		rodOutletFiltered_C = self.filtered_K - KELVIN,
		rodPending_K = self.pending_K,
		rodEffectiveError_K = self.effective_K,
		flowOn = self.flowOn,
		speedDemand_pct = self.speedDemand,
		coreOutletSetpoint_C = self.setpoint_C,
		flowProgram_pct = self.flowProgram,
		filteredPower_pctFP = self.filteredPower,
	}
end

return AutoControls
