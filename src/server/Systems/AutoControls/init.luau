--!strict
--[[
	AutoControls — rod auto and primary flow auto, deliberately worse than a crew (spec §9.4, §9.2).
	==================================================================================================

	§9.4's title is the design brief: these controllers are meant to be beatable. Each one holds its variable
	adequately in steady state and badly in a transient, and the weaknesses are not bugs to be fixed later — they
	are why a human operator is worth having. They are implemented here on purpose, and each is named.

	**Rod auto** holds the core outlet within ±2 K using the regulating rods only.
	  - it never moves a shim, so it runs out of authority and says so rather than fixing itself
	  - it stops and alarms when the regulating rods reach the 250–750 mm band (§9.4)
	  - it acts on the core outlet THERMOCOUPLE, which §2.5 gives a 3 s lag and ±1 K of noise, so it is always
	    responding to where the plant was rather than where it is — this is the "reacts after thermocouples move"
	    weakness, and it is what makes the controller hunt
	  - it moves ONE regulating rod at a time (D-006, finding F6), picking the one that keeps the three together:
	    the most-inserted rod when withdrawing, the most-withdrawn when inserting

	**Primary flow auto** holds P/Q on the §9.2 programme.
	  - the power signal it uses is filtered with a 10 s lag (§9.4), so on a fast power change the flow lags and
	    P/Q swings. That is the stated weakness, and it has teeth: §9.5 raises a rod block at P/Q 1.05 and trips
	    at 1.12, so a large enough step under flow auto trips the plant. The tests measure the excursion rather
	    than assuming it
	  - it ignores a pump trip (§9.4): it sets a speed demand from the programme and does not raise the surviving
	    pumps to make up the lost flow

	**Both track the §9.2 programme rather than fixed values** (D-003, finding F3). §9.4 says rod auto holds
	550 °C and flow auto holds P/Q = 1.00, but §9.2's programme holds neither below 40 %FP: the core outlet falls
	to 506 °C at 30 %FP and the flow floors at 40 %, so P/Q rises above 1. A controller holding the §9.4 numbers
	would fight the programme all the way down. The setpoint is therefore 375 + 175·(P/Q), which reproduces every
	row of §9.2's table, and the flow demand is the programme's own flow curve.

	Neither controller touches another system's state directly. They publish demands, and RodDrives and
	PrimaryPumps read them like any other input — so every §3.4 interlock and §9.5 rod block applies to the
	automatic controllers exactly as it does to an operator, without a line of code to make that true.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local System = require(script.Parent.Parent.Framework.System)
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
		"primary.flowFraction",
	},
	readsLagged = {
		"rods.position_mm",
		"rods.selection",
		"protection.rodWithdrawalBlock",
		"protection.runback",
		"protection.scram",
		"protection.runbackTarget_pctFP",
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

--[[
	§9.2's programme, as the two functions the table is generated from. Core inlet is held at 375 °C throughout,
	and with r = P/Q the core outlet is 375 + 175r — which reproduces 550 °C at full load and 506 °C at 30 %FP on
	40 % flow, the row where holding §9.4's flat 550 would be wrong (D-003).
]]
local function programOutlet(cfg: any, powerFraction: number, flowFraction: number): number
	local p = cfg.Program.partLoad
	local r = if flowFraction > 1e-3 then powerFraction / flowFraction else 0
	return p.coreInlet_C + p.outletSlope_K * r
end

--[[
	§9.2's flow programme: flow follows power down to the 40 % floor, and D-007 ramps it from 25 % to 40 %
	between 5 and 10 %FP rather than stepping.
]]
local function programFlow(cfg: any, power_pctFP: number): number
	local p = cfg.Program.partLoad
	local ramp = cfg.Program.partLoadFlowRamp_pctFP
	if power_pctFP >= ramp[2] then
		return math.clamp(power_pctFP, p.minimumFlowAtOrAbove10_pct, 100)
	end
	if power_pctFP <= ramp[1] then
		return p.minimumFlowAtOrBelow5_pct
	end
	local t = (power_pctFP - ramp[1]) / (ramp[2] - ramp[1])
	return p.minimumFlowAtOrBelow5_pct + t * (p.minimumFlowAtOrAbove10_pct - p.minimumFlowAtOrBelow5_pct)
end

function AutoControls.init(self: any, ctx: any)
	local cfg = ctx.config
	self.cfg = cfg
	self.port = ctx.channels
	self.log = ctx.log
	self.bus = ctx.bus
	self.rodCfg = cfg.Program.rodAuto
	self.flowCfg = cfg.Program.primaryFlowAuto
	self.band = cfg.Program.rodAuto.regulatingBand_mm
	self.regulatingCount = cfg.Rods.regulating.count

	self.rodOn = false
	self.flowOn = false
	self.selected = ""
	self.demand_mm = 0
	self.outOfBand = false
	self.direction = nil
	-- §9.4's stated weakness: the flow demand follows a 10 s filter on power, not power itself
	self.filteredPower = 0
	self.started = false
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

--[[
	Pick the regulating rod to move. Moving them one at a time is D-006, and choosing the one that is furthest
	behind in the direction of travel keeps the three roughly together, which is what a rod sequencer does — and
	it is why the band takes about half an hour to cross rather than a few minutes (finding F6).
]]
function AutoControls.chooseRod(self: any, withdrawing: boolean): (string?, number?)
	local positions = self.port:read("rods.position_mm")
	if positions == nil then
		return nil, nil
	end
	local bestName, bestPos = nil, nil
	for i = 1, self.regulatingCount do
		local pos = positions[i] -- the regulating rods are the first drives RodDrives builds (§2.2 order)
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

-- Is this rod still able to move the way the controller needs it to?
function AutoControls.rodUsable(self: any, name: string, withdrawing: boolean): boolean
	local positions = self.port:read("rods.position_mm")
	local index = tonumber(string.sub(name, 3))
	if positions == nil or index == nil or positions[index] == nil then
		return false
	end
	local pos = positions[index]
	return if withdrawing then pos < self.band[2] else pos > self.band[1]
end

function AutoControls.stopRods(self: any, reason: string?)
	if self.selected ~= "" then
		self.selected = ""
		if reason and self.log then
			self.log:record("auto.rod", nil, "rod auto", reason, "stopped")
		end
	end
end

function AutoControls.step(self: any, dt: number)
	local port = self.port
	local power = port:read("core.power_pctFP") or 0
	local flowFraction = port:read("primary.flowFraction") or 1

	-- §9.4: the flow demand follows a 10 s filter on power, which is the whole of its stated weakness
	if not self.started then
		self.filteredPower = power
		self.started = true
	else
		self.filteredPower += (power - self.filteredPower) * (1 - math.exp(-dt / self.flowCfg.powerFilter_s))
	end

	self.setpoint_C = programOutlet(self.cfg, power / 100, flowFraction)
	self.flowProgram = programFlow(self.cfg, self.filteredPower)

	-- Primary flow auto. §9.4 says it ignores a pump trip, so the demand is the programme and nothing else:
	-- it never raises the surviving pumps to make up flow a stopped pump is no longer delivering.
	if self.flowOn then
		self.speedDemand = self.flowProgram
	end

	-- Rod auto
	local scrammed = port:read("protection.scram")
	local runback = port:read("protection.runback")
	if self.rodOn then
		if (scrammed and scrammed ~= "none") or (runback and runback ~= "") then
			-- a scram or a runback is not something to negotiate with
			self:stopRods("scram or runback in progress")
		else
			local measured = port:read("pools.mixedCoreOutletMeasured_K")
			if measured ~= nil then
				local error_K = (measured - KELVIN) - self.setpoint_C
				local band = self.rodCfg.holdBand_K
				if math.abs(error_K) <= band then
					self:stopRods()
					self.outOfBand = false
				else
					-- too hot: insert to bring power down. Too cold: withdraw.
					local withdrawing = error_K < 0
					if withdrawing and port:read("protection.rodWithdrawalBlock") == true then
						self:stopRods("rod withdrawal block")
					else
						--[[
							Stay on the rod already moving. Re-picking every tick would hop between the three
							as soon as one got ahead, which is thrash rather than sequencing: a real sequencer
							runs one rod until it reaches its limit and then takes the next. The "keep them
							together" rule therefore applies when a NEW rod is chosen, not continuously.
						]]
						local name = nil
						if self.selected ~= "" and self.direction == withdrawing then
							local held = self:rodUsable(self.selected, withdrawing)
							name = if held then self.selected else nil
						end
						name = name or self:chooseRod(withdrawing)
						self.direction = withdrawing
						if name == nil then
							--[[
								§9.4: it stops and alarms at the band edge, and it never reaches for a shim to
								get itself out of trouble. This is the controller running out of authority, and
								the crew noticing is the point.
							]]
							self:stopRods()
							if not self.outOfBand then
								self.outOfBand = true
								if self.log then
									self.log:record("auto.rod", nil, "rod auto",
										"regulating rods at the band limit", "ALARM")
								end
								if self.bus then
									self.bus:publish("Alarm", {
										tag = "AUTO-ROD-BAND",
										priority = 2,
										state = "in",
										text = "Rod auto at the regulating band limit",
									})
								end
							end
						else
							self.outOfBand = false
							self.selected = name
							-- drive toward the band edge in the needed direction; the band is the limit of
							-- this controller's authority, not a target
							self.demand_mm = if withdrawing then self.band[2] else self.band[1]
						end
					end
				end
			end
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
			self.outOfBand = false
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

function AutoControls.getState(self: any): { [string]: any }
	return {
		rodOn = self.rodOn,
		rodSelected = self.selected,
		rodDemand_mm = self.demand_mm,
		rodOutOfBand = self.outOfBand,
		flowOn = self.flowOn,
		speedDemand_pct = self.speedDemand,
		coreOutletSetpoint_C = self.setpoint_C,
		flowProgram_pct = self.flowProgram,
		filteredPower_pctFP = self.filteredPower,
	}
end

return AutoControls
