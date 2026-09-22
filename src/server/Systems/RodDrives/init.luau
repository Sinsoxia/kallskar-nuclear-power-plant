--!strict
--[[
	RodDrives — the thirty control rod drives, their interlocks and the scram (spec §3.4, §9.5).
	==============================================================================================

	Three regulating rods, eighteen shim rods in banks A, B and C, and nine secondary shutdown rods. Position is
	mm withdrawn from fully inserted, 0–1,100 mm (§0.1), against a 1,000 mm active fuel height (§2.1), so the
	inserted fraction is d = (1,100 − position) / 1,000, clamped.

	This system owns the **mechanics**: where each rod is, how fast it may move, what may move at once, and how
	fast it falls on a scram. It does not own the reactivity. §3.4 is explicit that its integral worth curve is "a
	validation target, not a formula the code uses" — the plant's reactivity comes from the 3D solve, with rods
	entering through the absorber cross sections. What this system publishes as `rods.indicativeWorth_pcm` is the
	§3.4 curve evaluated at the live positions, for two honest uses: the withdrawal-rate interlock, and a readout
	to compare the 3D answer against. It is never the reactivity the core runs on.

	**Speeds are the interlock.** Differentiating §3.4's curve gives dW/dd = W_total(1 − cos 2πd), peaking at
	2·W_total at mid-stroke, so bank A's 6 × 400 pcm peaks at 4.8 pcm/mm and 4 ÷ 4.8 = 0.833 mm/s — which is why
	§3.4 gives bank A 0.8 mm/s where B and C get 1.0. Every speed in the table is the 4 pcm/s interlock divided by
	that bank's peak differential worth, rounded down (tools/derive/rod_speeds.py). The system still checks the
	live rate against the interlock and clamps rather than trusting the table, so a later speed change cannot
	quietly break the limit.

	**One rod or one bank at a time** (§3.4) is a single selection: starting a second movement is refused while one
	is running. A scram, a runback drive-in and a rod block all override the selection, because none of them is the
	operator's to negotiate with.

	**Scram** inserts at a constant rate sized to §3.4's "90 % in ≤ 1.2 s" for the PSS and "≤ 2.0 s" for the SSR —
	825 mm/s and 495 mm/s, so full travel takes 1.33 s and 2.22 s (D-023). Rods stay latched in until a deliberate
	reset, which is refused while any of them is still out.

	Boot state is §9.1 Mode 3, hot standby: every PSS rod fully inserted, the nine SSRs parked at 1,100 mm and
	latched (D-024). Getting from there to critical is the operator's job, not an initial condition.

	Inputs:  protection.rodWithdrawalBlock   §9.5 rod blocks; withdrawal is refused and any in-progress
	                                         withdrawal stops. Insertion is never blocked.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Types = require(Kallskar:WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local RodDrives = System.extend({
	name = "RodDrives",
	lane = "fast",
	reads = {},
	readsLagged = { "protection.rodWithdrawalBlock", "protection.scram", "protection.rodRunback" },
	writes = {
		"rods.position_mm",
		"rods.insertedFraction",
		"rods.indicativeWorth_pcm",
		"rods.withdrawalRate_pcmps",
		"rods.scrammed",
		"rods.allPssInserted",
		"rods.regulatingInBand",
		"rods.selection",
	},
})

local TAU = 2 * math.pi

-- §3.4: W(d) / W_total, the fraction of a rod's worth inserted at depth d
local function worthFraction(d: number): number
	return d - math.sin(TAU * d) / TAU
end

-- pcm per mm of travel at depth d, for a group worth `total` pcm. Peaks at 2·total/active at mid-stroke.
local function differentialPerMm(total: number, d: number, active_mm: number): number
	return total * (1 - math.cos(TAU * d)) / active_mm
end

function RodDrives.init(self: any, ctx: any)
	local cfg = ctx.config
	local rods = cfg.Rods
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.cfg = rods
	self.travel_mm = cfg.Units.rodTravel_mm
	self.active_mm = cfg.Core.geometry.fissileHeight_mm
	self.interlock_pcmps = rods.interlocks.maxWithdrawalRate_pcmps
	self.band = rods.regulating.normalBand_mm

	--[[
		Drive table, in the order Config.Core.rodLayout lists the sets, so a later RodModel can map drive → mesh
		position without a second convention. `bank` is the selection a bank move addresses; the RRs share the
		"RR" bank for a ganged move, but D-006 has rod auto move them one at a time.
	]]
	local shim = rods.shim
	local sets = {
		{ set = "RR", prefix = "RR", count = rods.regulating.count, worth = rods.regulating.worthEach_pcm,
			single = rods.regulating.speed_mmps, bank = rods.regulating.speed_mmps, system = "PSS" },
		{ set = "SM_A", prefix = "SMA", count = shim.banks.A.count, worth = shim.banks.A.worthEach_pcm,
			single = shim.speedSingle_mmps, bank = shim.speedBankA_mmps, system = "PSS" },
		{ set = "SM_B", prefix = "SMB", count = shim.banks.B.count, worth = shim.banks.B.worthEach_pcm,
			single = shim.speedSingle_mmps, bank = shim.speedBank_mmps, system = "PSS" },
		{ set = "SM_C", prefix = "SMC", count = shim.banks.C.count, worth = shim.banks.C.worthEach_pcm,
			single = shim.speedSingle_mmps, bank = shim.speedBank_mmps, system = "PSS" },
		{ set = "SSR", prefix = "SSR", count = rods.secondaryShutdown.count,
			worth = rods.secondaryShutdown.worthEach_pcm,
			single = rods.secondaryShutdown.speedWithdrawOnly_mmps,
			bank = rods.secondaryShutdown.speedWithdrawOnly_mmps, system = "SSR", withdrawOnly = true },
	}
	self.drives = {}
	self.banks = {}
	for _, s in sets do
		local bank = if s.prefix == "SMA" then "A" elseif s.prefix == "SMB" then "B"
			elseif s.prefix == "SMC" then "C" else s.prefix
		self.banks[bank] = { set = s.set, speed = s.bank, members = {} }
		for n = 1, s.count do
			local drive = {
				name = `{s.prefix}{n}`,
				set = s.set,
				bank = bank,
				worth_pcm = s.worth,
				speedSingle = s.single,
				system = s.system,
				withdrawOnly = s.withdrawOnly == true,
				-- D-024: boot in Mode 3, hot standby — PSS rods in, SSRs parked and latched
				position_mm = if s.system == "SSR" then rods.secondaryShutdown.parked_mm else 0,
				demand_mm = if s.system == "SSR" then rods.secondaryShutdown.parked_mm else 0,
				stuck = false,
			}
			table.insert(self.drives, drive)
			table.insert(self.banks[bank].members, #self.drives)
		end
	end
	self.count = #self.drives
	assert(self.count == cfg.Core.totals.regulating + cfg.Core.totals.shim + cfg.Core.totals.secondaryShutdown,
		`built {self.count} drives, §2.2 expects 30`)

	-- D-023: constant-rate scram, sized to §3.4's "90 % in ≤ t"
	self.scramRate = {
		PSS = 0.9 * self.travel_mm / rods.regulating.scram90Percent_s,
		SSR = 0.9 * self.travel_mm / rods.secondaryShutdown.scram90Percent_s,
	}
	self.runbackSpeed = shim.speedRunbackDriveIn_mmps

	self.position = table.create(self.count, 0)
	self.inserted = table.create(self.count, 0)
	self.port:write("rods.position_mm", self.position)
	self.port:write("rods.insertedFraction", self.inserted)
	self.selection = nil
	self.scrammed = {}
	self.runback = false
	self.commandedRunback = false
	self.rate_pcmps = 0
	self:publish()
end

function RodDrives.depthOf(self: any, position_mm: number): number
	return math.clamp((self.travel_mm - position_mm) / self.active_mm, 0, 1)
end

function RodDrives.indexOf(self: any, name: string?): number?
	for i, drive in self.drives do
		if drive.name == name then
			return i
		end
	end
	return nil
end

--[[
	The rods a movement would actually drive, and the speed for that movement. A bank moves at its own (slower)
	bank speed, a single rod at its single-rod speed (§3.4).
]]
function RodDrives.groupOf(self: any, kind: string, id: string): ({ number }?, number?)
	if kind == "bank" then
		local bank = self.banks[id]
		if not bank then
			return nil, nil
		end
		return bank.members, bank.speed
	end
	local i = self:indexOf(id)
	if not i then
		return nil, nil
	end
	return { i }, self.drives[i].speedSingle
end

--[[
	Speed this group may withdraw at, given §3.4's 4 pcm/s interlock. The configured speeds already satisfy it —
	tools/derive/rod_speeds.py shows each one IS the interlock divided by that group's peak differential worth —
	so this clamp should never bite. It is here so that a later speed change cannot silently break the limit.
]]
function RodDrives.interlockSpeed(self: any, group: { number }, speed: number): number
	local perMm = 0
	for _, i in group do
		local drive = self.drives[i]
		perMm += differentialPerMm(drive.worth_pcm, self:depthOf(drive.position_mm), self.active_mm)
	end
	if perMm <= 0 then
		return speed
	end
	return math.min(speed, self.interlock_pcmps / perMm)
end

function RodDrives.publish(self: any)
	local port = self.port
	local worth, allPssIn, inBand = 0, true, true
	for i, drive in self.drives do
		local d = self:depthOf(drive.position_mm)
		self.position[i] = drive.position_mm
		self.inserted[i] = d
		worth += drive.worth_pcm * worthFraction(d)
		if drive.system == "PSS" and drive.position_mm > 0 then
			allPssIn = false
		end
		if drive.set == "RR" and (drive.position_mm < self.band[1] or drive.position_mm > self.band[2]) then
			inBand = false
		end
	end
	port:write("rods.indicativeWorth_pcm", worth)
	port:write("rods.withdrawalRate_pcmps", self.rate_pcmps)
	port:write("rods.scrammed", self.scrammed.PSS == true or self.scrammed.SSR == true)
	port:write("rods.allPssInserted", allPssIn)
	port:write("rods.regulatingInBand", inBand)
	port:write("rods.selection", if self.selection then self.selection.id else "")
	self.worth_pcm = worth
end

-- Move one drive toward its demand, honouring a stuck rod. Returns the pcm/s of withdrawal it contributed.
local function driveStep(self: any, i: number, speed: number, dt: number): number
	local drive = self.drives[i]
	if drive.stuck or drive.position_mm == drive.demand_mm then
		return 0
	end
	local before = drive.position_mm
	local step = math.clamp(drive.demand_mm - before, -speed * dt, speed * dt)
	drive.position_mm = math.clamp(before + step, 0, self.travel_mm)
	if step <= 0 then
		return 0 -- insertion adds negative reactivity; the interlock is on withdrawal
	end
	local d = self:depthOf(0.5 * (before + drive.position_mm))
	return differentialPerMm(drive.worth_pcm, d, self.active_mm) * (drive.position_mm - before) / dt
end

function RodDrives.step(self: any, dt: number)
	local blocked = self.port:read("protection.rodWithdrawalBlock") == true
	local rate = 0

	-- Protection decides, these drives execute. `scram` is idempotent, so holding the channel at "PSS" simply
	-- keeps the rods in rather than re-firing anything.
	local demanded = self.port:read("protection.scram")
	if demanded and demanded ~= "none" then
		self:scram(demanded, "protection")
	end
	local runbackDemand = self.port:read("protection.rodRunback") == true
	if runbackDemand and not self.runback then
		self:stopSelection("runback drive-in")
	end
	self.runback = self.commandedRunback == true or runbackDemand

	-- A scram owns the drives outright: no selection, no block, no interlock — the rods are falling.
	for _, system in { "PSS", "SSR" } do
		if self.scrammed[system] then
			local speed = self.scramRate[system]
			for i, drive in self.drives do
				if drive.system == system then
					drive.demand_mm = 0
					driveStep(self, i, speed, dt)
				end
			end
		end
	end

	if self.runback then
		-- §9.5 runback: shim banks drive in at 10 mm/s. Insertion, so the withdrawal interlock does not apply.
		for i, drive in self.drives do
			if drive.set ~= "RR" and drive.system == "PSS" then
				drive.demand_mm = 0
				driveStep(self, i, self.runbackSpeed, dt)
			end
		end
	end

	local selection = self.selection
	if selection and not self.scrammed[selection.system] then
		local group, speed = self:groupOf(selection.kind, selection.id)
		if group and speed then
			local withdrawing = false
			for _, i in group do
				if self.drives[i].demand_mm > self.drives[i].position_mm then
					withdrawing = true
					break
				end
			end
			if withdrawing and blocked then
				self:stopSelection("rod withdrawal block")
			else
				local allowed = if withdrawing then self:interlockSpeed(group, speed) else speed
				local done = true
				for _, i in group do
					rate += driveStep(self, i, allowed, dt)
					if self.drives[i].position_mm ~= self.drives[i].demand_mm and not self.drives[i].stuck then
						done = false
					end
				end
				if done then
					self.selection = nil
				end
			end
		end
	end
	self.rate_pcmps = rate
	self:publish()
end

function RodDrives.stopSelection(self: any, reason: string?, actor: Actor?)
	local selection = self.selection
	if not selection then
		return false
	end
	local group = self:groupOf(selection.kind, selection.id)
	if group then
		for _, i in group do
			self.drives[i].demand_mm = self.drives[i].position_mm
		end
	end
	self.selection = nil
	if self.log and reason then
		self.log:record("rod.stop", actor, selection.id, reason, "stopped")
	end
	return true
end

--[[
	Scram. `system` is "PSS" (regulating and shim), "SSR" (secondary shutdown) or "both". Idempotent: scramming an
	already-scrammed system does nothing, so a second trip signal cannot restart the clock.
]]
function RodDrives.scram(self: any, system: string, reason: string, actor: Actor?): boolean
	local systems = if system == "both" then { "PSS", "SSR" } else { system }
	local fired = false
	for _, s in systems do
		if not self.scrammed[s] then
			self.scrammed[s] = true
			fired = true
			if self.log then
				self.log:record("rod.scram", actor, s, reason, "inserting")
			end
		end
	end
	if fired then
		self:stopSelection()
		self.selection = nil
		if self.bus then
			self.bus:publish("Trip", { system = "RodDrives", reason = reason, firstOut = system })
		end
	end
	return fired
end

--[[
	Reset the scram latch. Refused while any affected rod is still out: a reset with rods part-way in would leave
	the plant believing it is shut down when it is not.
]]
function RodDrives.resetScram(self: any, actor: Actor?): (boolean, string?)
	for _, drive in self.drives do
		if self.scrammed[drive.system] and drive.position_mm > 0 then
			return false, `{drive.name} is at {string.format("%.0f", drive.position_mm)} mm; every rod must be fully inserted first`
		end
	end
	if not (self.scrammed.PSS or self.scrammed.SSR) then
		return false, "not scrammed"
	end
	self.scrammed = {}
	if self.log then
		self.log:record("rod.reset", actor, "scram", nil, "reset")
	end
	return true
end

RodDrives.commands = {
	["rod.move"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		return self:request("rod", cmd.tag, cmd.value, actor)
	end,

	["rod.bank"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		return self:request("bank", cmd.tag, cmd.value, actor)
	end,

	["rod.stop"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		if not self:stopSelection("operator stop", actor) then
			return { ok = false, reason = "nothing is moving" }
		end
		return { ok = true }
	end,

	["rod.reset"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local ok, why = self:resetScram(actor)
		return { ok = ok, reason = why }
	end,

	["rod.runback"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local on = cmd.value ~= 0
		if on and not self.runback then
			self:stopSelection("runback drive-in", actor)
		end
		self.commandedRunback = on
		self.runback = on
		if self.log then
			self.log:record("rod.runback", actor, "shim banks", if on then "drive in" else "released", "set")
		end
		return { ok = true }
	end,
}

--[[
	Start a movement. Enforces §3.4's "one rod or one bank at a time", the SSRs' withdraw-only rule, and §9.5's
	rod withdrawal block. The 4 pcm/s interlock is applied per step rather than here, because it depends on where
	the rods are as they travel.
]]
function RodDrives.request(self: any, kind: string, id: string?, target: number?, actor: Actor?): CommandResult
	if self.scrammed.PSS or self.scrammed.SSR then
		return { ok = false, reason = "scrammed; reset first" }
	end
	if self.runback then
		return { ok = false, reason = "runback drive-in is in progress" }
	end
	if type(target) ~= "number" or target ~= target then
		return { ok = false, reason = "target position must be a number, in mm" }
	end
	if target < 0 or target > self.travel_mm then
		return { ok = false, reason = `target must be between 0 and {self.travel_mm} mm` }
	end
	local group, speed = self:groupOf(kind, id or "")
	if not group or not speed then
		return { ok = false, reason = `unknown {kind} '{tostring(id)}'` }
	end
	if self.selection then
		return { ok = false, reason = `{self.selection.id} is already moving; §3.4 allows one rod or one bank at a time` }
	end
	local withdrawing = false
	for _, i in group do
		local drive = self.drives[i]
		if target > drive.position_mm then
			withdrawing = true
		elseif target < drive.position_mm and drive.withdrawOnly then
			return { ok = false, reason = `{drive.name} is withdraw-only; it inserts on a scram` }
		end
	end
	if withdrawing and self.port:read("protection.rodWithdrawalBlock") == true then
		return { ok = false, reason = "rod withdrawal block is in" }
	end
	for _, i in group do
		self.drives[i].demand_mm = target
	end
	local system = self.drives[group[1]].system
	self.selection = { kind = kind, id = id, system = system }
	if self.log then
		self.log:record(if kind == "bank" then "rod.bank" else "rod.move", actor, id,
			string.format("to %.0f mm", target), "moving")
	end
	return { ok = true }
end

RodDrives.faults = {
	{
		id = "RD-STUCK",
		label = "Control rod stuck",
		cost = 3,
		eligible = function(_snapshot: any)
			return true
		end,
		--[[
			The drive stops responding where it stands, and stays there through a scram too — which is the case
			§3.4's shutdown margins are quoted for ("the most reactive rod stuck").
		]]
		arm = function(self: any, params: { [string]: any }?)
			local name = (params and params.rod) or self.drives[4].name
			local i = self:indexOf(name)
			if i then
				self.drives[i].stuck = true
				if self.log then
					self.log:record("rod.stuck", nil, name, "fault RD-STUCK", "stuck")
				end
			end
		end,
		clear = function(self: any, params: { [string]: any }?)
			local name = (params and params.rod) or self.drives[4].name
			local i = self:indexOf(name)
			if i then
				self.drives[i].stuck = false
			end
		end,
	},
}

function RodDrives.getState(self: any): { [string]: any }
	local drives = {}
	for i, drive in self.drives do
		drives[i] = {
			name = drive.name,
			set = drive.set,
			bank = drive.bank,
			position_mm = drive.position_mm,
			demand_mm = drive.demand_mm,
			insertedFraction = self.inserted[i],
			stuck = drive.stuck,
		}
	end
	return {
		drives = drives,
		selection = if self.selection then self.selection.id else nil,
		scrammed = { PSS = self.scrammed.PSS == true, SSR = self.scrammed.SSR == true },
		runback = self.runback,
		indicativeWorth_pcm = self.worth_pcm,
		withdrawalRate_pcmps = self.rate_pcmps,
	}
end

return RodDrives
