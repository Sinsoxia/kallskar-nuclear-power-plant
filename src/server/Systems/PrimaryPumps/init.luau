--!strict
--[[
	PrimaryPumps — the three primary sodium pumps PP1–PP3 (spec §4.2).
	===================================================================

	Each pump is a variable-speed centrifugal pump on the cold pool, discharging to the diagrid through a flap check
	valve. Flow follows the affinity law against the design system curve: on a fixed resistance the head rises as N²
	and the system loss as Q², so Q ∝ N and the rated 3,565 kg/s each lines up with 100 % speed.

	  running   speed ramps toward the demand at no more than Clocks-independent maxRamp_pctps (§4.2), inside the
	            25–105 % range; flow = rated × speed
	  tripped   the spec's own coastdown, Q(t) = Q₀ / (1 + t/10 s): 50 % at 10 s, 25 % at 30 s. The flywheel is what
	            makes that curve; it is not integrated separately. The check valve only prevents reverse flow — it
	            never adds flow, so a stopped pump contributes nothing rather than draining the diagrid
	  pony      250 kW pony motors on the essential boards hold 10 % speed, which is a floor under the coastdown
	  trip      on a pump trip the surviving pumps' drives ramp to 105 % at the 2 %/s limit, which keeps P/Q under
	            the 1.12 trip while RB-2 runs the power back, and hold there until RB-2 ends (§4.2, Rev A5's F27;
	            D-046+). This is the drives' own trip response, not §9.4's flow auto, which still ignores the trip
	  no pumps  natural circulation, Q_nc = 3.5 % × (P / 100 %FP)^⅓ (§4.2 as corrected in Rev A4), applied as a floor
	            on total flow rather than per pump

	Pump heat into the sodium is the shaft power, which scales as N³ and totals the §4.2 figure of ≈ 10 MWt at rated.

	Inputs:  core.thermalPower_pctFP for the natural-circulation floor: buoyancy comes from heat, so after a trip
	                                 it is decay heat that keeps the sodium moving, not the neutron power
	         pools.coverGas_MPa      start interlock (≥ 0.105 MPa)
	         pools.coldPool_K        start interlock (sodium ≥ 180 °C)
	         protection.runback      whether RB-2, the pump trip's runback, is running (lagged: Protection runs
	                                 after the pumps, so the survivors start their ramp a tick after the trip)
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
local Types = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local PrimaryPumps = System.extend({
	name = "PrimaryPumps",
	lane = "fast",
	reads = { "core.thermalPower_pctFP", "pools.coverGas_MPa", "pools.coldPool_K" },
	readsLagged = { "auto.flowOn", "auto.pumpSpeedDemand_pct", "protection.runback" },
	writes = {
		"primary.coreFlow_kgps",
		"primary.flowFraction",
		"primary.pumpFlow_kgps",
		"primary.pumpSpeed_pct",
		"primary.pumpsRunning",
		"primary.pumpHeat_MWt",
	},
})

local KELVIN = 273.15
local PUMP_TRIP_RUNBACK = "RB2" -- §9.5: one primary pump lost runs the plant back on RB-2

function PrimaryPumps.init(self: any, ctx: any)
	local cfg = ctx.config
	local p = cfg.Primary.pumps
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.cfg = p
	self.nc = cfg.Primary.naturalCirculation
	self.count = p.count
	self.ratedTotal = p.ratedFlowTotal_kgps
	-- §4.2's 3,565 kg/s per pump is the rounded third of the 10,694 kg/s total, which the §1.1 heat balance sets
	-- (3 × 3,565 = 10,695). The total is the authoritative figure, so the per-pump rating is derived from it (F30).
	self.ratedEach = self.ratedTotal / self.count
	self.minSpeed, self.maxSpeed = p.speedRange_pct[1], p.speedRange_pct[2]
	self.pumps = {}
	for i = 1, self.count do
		self.pumps[i] = {
			name = `PP{i}`,
			speed_pct = 100, -- initial condition: all three at rated, matching §1.1
			demand_pct = 100,
			tripped = false,
			pony = false,
			coastFlow0_kgps = 0,
			coastTime_s = 0,
		}
	end
	self.holding = false -- the survivors are held at the top of their range while RB-2 runs (§4.2, D-046+)
	self.flow = table.create(self.count, self.ratedEach)
	self.speed = table.create(self.count, 100)
	self.port:write("primary.pumpFlow_kgps", self.flow)
	self.port:write("primary.pumpSpeed_pct", self.speed)
	self:publish()
end

-- flow a pump delivers right now, kg/s
local function pumpFlow(self: any, pump: any): number
	if pump.tripped then
		local coast = pump.coastFlow0_kgps / (1 + pump.coastTime_s / self.cfg.coastdownTau_s)
		local floor = if pump.pony then self.ratedEach * self.cfg.ponySpeed_pct / 100 else 0
		return math.max(coast, floor)
	end
	return self.ratedEach * pump.speed_pct / 100
end

function PrimaryPumps.publish(self: any)
	local port = self.port
	local total, heat, running = 0, 0, 0
	for i, pump in self.pumps do
		local q = pumpFlow(self, pump)
		self.flow[i] = q
		self.speed[i] = if pump.tripped then q / self.ratedEach * 100 else pump.speed_pct
		total += q
		heat += (q / self.ratedEach) ^ 3
		if not pump.tripped then
			running += 1
		end
	end
	-- natural circulation is a floor on the whole loop, not an extra pump (§4.2), and heat drives it: on the
	-- neutron power it would fall to almost nothing a few minutes after a trip, with decay heat still at 1 %
	local power = self.port:read("core.thermalPower_pctFP") or 0
	local ref = self.nc.referencePower_pctFP
	local natural = self.ratedTotal * self.nc.coefficient_pct / 100 * (math.max(power, 0) / ref) ^ self.nc.exponent
	self.naturalCirculation_kgps = natural
	total = math.max(total, natural)
	port:write("primary.coreFlow_kgps", total)
	port:write("primary.flowFraction", total / self.ratedTotal)
	port:write("primary.pumpsRunning", running)
	port:write("primary.pumpHeat_MWt", self.cfg.pumpHeatToSodium_MWt * heat / self.count)
	self.total_kgps = total
end

function PrimaryPumps.step(self: any, dt: number)
	--[[
		§9.4's primary flow auto sets one speed demand for every running pump and, as that section states,
		ignores a pump trip: it does not raise the survivors to make up the flow a stopped pump is no longer
		delivering. The 25–105 % range and the 2 %/s ramp below still apply to it.
	]]
	if self.port:read("auto.flowOn") == true then
		local demand = self.port:read("auto.pumpSpeedDemand_pct")
		if demand ~= nil then
			local clamped = math.clamp(demand, self.minSpeed, self.maxSpeed)
			for _, pump in self.pumps do
				if not pump.tripped then
					pump.demand_pct = clamped
				end
			end
		end
	end

	--[[
		§4.2 (Rev A5, F27): "the surviving pumps ramp to 105 % on a pump trip, which keeps P/Q below the 1.12 trip
		while RB-2 runs power back". The drives do it, not flow auto, so it overrides flow auto's demand above, and
		holds for as long as RB-2 runs (D-046+). When RB-2 ends, flow auto takes the pumps back to its programme on
		the next tick; with flow auto out they stay at 105 % until the operator moves them. Flow auto's programme is
		for three pumps, so on two it gives the core about two thirds of the flow it means to (§9.4's weakness).
	]]
	local runback = self.port:read("protection.runback")
	self.holding = runback == PUMP_TRIP_RUNBACK and self:runningCount() < self.count
	if self.holding then
		for _, pump in self.pumps do
			if not pump.tripped then
				pump.demand_pct = self.maxSpeed
			end
		end
	end

	local maxStep = self.cfg.maxRamp_pctps * dt
	for _, pump in self.pumps do
		if pump.tripped then
			pump.coastTime_s += dt
		elseif pump.speed_pct ~= pump.demand_pct then
			local delta = math.clamp(pump.demand_pct - pump.speed_pct, -maxStep, maxStep)
			pump.speed_pct += delta
		end
	end
	self:publish()
end

--[[
	Seat all three pumps at one speed as an initial condition, with no ramp (plan: initial conditions). Refused
	with a pump tripped, because a coasting pump has no speed to seat.
]]
function PrimaryPumps.seat(self: any, speed_pct: number): (boolean, string?)
	for _, pump in self.pumps do
		if pump.tripped then
			return false, `{pump.name} is tripped; restart it first`
		end
	end
	local speed = math.clamp(speed_pct, self.minSpeed, self.maxSpeed)
	for _, pump in self.pumps do
		pump.speed_pct, pump.demand_pct = speed, speed
	end
	self:publish()
	return true
end

--[[
	Trip or stop a pump: both hand over to the §4.2 coastdown from whatever flow the pump had. `reason` is logged so
	the sequence of events can tell an operator stop from a fault trip.
]]
function PrimaryPumps.tripPump(self: any, index: number, reason: string, actor: Actor?)
	local pump = self.pumps[index]
	if pump.tripped then
		return false
	end
	pump.coastFlow0_kgps = pumpFlow(self, pump)
	pump.coastTime_s = 0
	pump.tripped = true
	pump.demand_pct = 0
	if self.log then
		self.log:record("pump.stop", actor, pump.name, reason, "stopped")
	end
	if self.bus then
		self.bus:publish("EquipmentTrip", {
			system = "PrimaryPumps",
			equipment = pump.name,
			reason = reason,
			running = self:runningCount(),
		})
	end
	return true
end

function PrimaryPumps.runningCount(self: any): number
	local n = 0
	for _, pump in self.pumps do
		if not pump.tripped then
			n += 1
		end
	end
	return n
end

function PrimaryPumps.startInterlocks(self: any): (boolean, string?)
	local port = self.port
	local gas = port:read("pools.coverGas_MPa")
	local cold = port:read("pools.coldPool_K")
	local limits = self.cfg.startInterlocks
	if gas == nil or cold == nil then
		return false, "start interlock inputs are not available"
	end
	if gas < limits.coverGasMin_MPa then
		return false, `cover gas {string.format("%.3f", gas)} MPa is below the {limits.coverGasMin_MPa} MPa start interlock`
	end
	if cold - KELVIN < limits.sodiumMin_C then
		return false, `sodium {string.format("%.0f", cold - KELVIN)} °C is below the {limits.sodiumMin_C} °C start interlock`
	end
	return true
end

local function pumpIndex(self: any, cmd: Command): (number?, string?)
	local tag = cmd.target
	for i, pump in self.pumps do
		if pump.name == tag then
			return i
		end
	end
	return nil, `unknown pump '{tostring(tag)}'`
end

PrimaryPumps.commands = {
	["pump.speed"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local i, why = pumpIndex(self, cmd)
		if not i then
			return { ok = false, reason = why }
		end
		local pump = self.pumps[i]
		local value = cmd.value
		if type(value) ~= "number" or value ~= value then
			return { ok = false, reason = "speed must be a number" }
		end
		if pump.tripped then
			return { ok = false, reason = `{pump.name} is stopped; start it first` }
		end
		if self.holding then
			return { ok = false, reason = `the drives hold {self.maxSpeed} % while RB-2 runs (§4.2)` }
		end
		if value < self.minSpeed or value > self.maxSpeed then
			return { ok = false, reason = `speed must be between {self.minSpeed} and {self.maxSpeed} %` }
		end
		pump.demand_pct = value
		return { ok = true }
	end,

	["pump.stop"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local i, why = pumpIndex(self, cmd)
		if not i then
			return { ok = false, reason = why }
		end
		if not self:tripPump(i, "operator stop", actor) then
			return { ok = false, reason = `{self.pumps[i].name} is already stopped` }
		end
		return { ok = true }
	end,

	["pump.start"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local i, why = pumpIndex(self, cmd)
		if not i then
			return { ok = false, reason = why }
		end
		local pump = self.pumps[i]
		if not pump.tripped then
			return { ok = false, reason = `{pump.name} is already running` }
		end
		local ok, reason = self:startInterlocks()
		if not ok then
			return { ok = false, reason = reason }
		end
		pump.tripped = false
		pump.pony = false
		pump.speed_pct = math.max(self.minSpeed, pumpFlow(self, pump) / self.ratedEach * 100)
		pump.demand_pct = self.minSpeed
		if self.log then
			self.log:record("pump.start", actor, pump.name, `demand {self.minSpeed} %`, "started")
		end
		return { ok = true }
	end,

	["pump.pony"] = function(self: any, actor: Actor, cmd: Command): CommandResult
		local i, why = pumpIndex(self, cmd)
		if not i then
			return { ok = false, reason = why }
		end
		local pump = self.pumps[i]
		if not pump.tripped then
			return { ok = false, reason = `{pump.name} is running on its main motor` }
		end
		pump.pony = cmd.value ~= 0
		return { ok = true }
	end,
}

PrimaryPumps.faults = {
	{
		id = "PP-TRIP",
		label = "Primary pump trip",
		cost = 3,
		eligible = function(_snapshot: any)
			return true
		end,
		arm = function(self: any, params: { [string]: any }?)
			local index = (params and params.pump) or 1
			self:tripPump(index, "fault PP-TRIP")
		end,
		clear = function(_self: any) end, -- a tripped pump is restarted with pump.start, not by clearing the fault
	},
}

-- §14.6 (D-053): which pumps are stopped or tripped, their pony motors and speed demands. A pump that was coasting
-- down carries on from where its coastdown had got to.
function PrimaryPumps.save(self: any): any
	local pumps = {}
	for i, p in self.pumps do
		pumps[i] = {
			speed_pct = p.speed_pct,
			demand_pct = p.demand_pct,
			tripped = p.tripped,
			pony = p.pony,
			coastFlow0_kgps = p.coastFlow0_kgps,
			coastTime_s = p.coastTime_s,
		}
	end
	return { pumps = pumps }
end

function PrimaryPumps.load(self: any, data: any, _version: number)
	self.holding = false -- a loaded plant is tripped, with no runback running
	if type(data.pumps) ~= "table" then
		return
	end
	for i, p in self.pumps do
		local s = data.pumps[i]
		if type(s) == "table" then
			for _, field in { "speed_pct", "demand_pct", "coastFlow0_kgps", "coastTime_s" } do
				if type(s[field]) == "number" then
					p[field] = s[field]
				end
			end
			p.tripped = s.tripped == true
			p.pony = s.pony == true
		end
	end
	self:publish()
end

function PrimaryPumps.getState(self: any): { [string]: any }
	local pumps = {}
	for i, pump in self.pumps do
		pumps[i] = {
			name = pump.name,
			speed_pct = self.speed[i],
			demand_pct = pump.demand_pct,
			flow_kgps = self.flow[i],
			tripped = pump.tripped,
			pony = pump.pony,
		}
	end
	return {
		pumps = pumps,
		totalFlow_kgps = self.total_kgps,
		flowFraction = self.total_kgps / self.ratedTotal,
		naturalCirculation_kgps = self.naturalCirculation_kgps,
		running = self:runningCount(),
	}
end

return PrimaryPumps
