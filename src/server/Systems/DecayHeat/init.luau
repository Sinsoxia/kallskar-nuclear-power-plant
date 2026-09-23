--!strict
--[[
	DecayHeat — fission-product decay heat that follows the plant's own power history (spec §3.6, D-037).
	=====================================================================================================

	§3.6 gives decay heat after a trip from constant power: P/P₀ = 0.066 (t^−0.2 − (t + T_op)^−0.2). A simulator has
	no constant power to trip from; it has whatever the operators did. The formula is the superposition of one
	kernel, 0.0132·τ^−1.2 per second of operation, so it is carried here as the 22 exponential groups
	tools/derive/decay_heat.py fits to that kernel:

	  dHᵢ/dt = λᵢ (Eᵢ·P − Hᵢ)          P the fission power, Hᵢ each group's decay power, both as fractions of rated

	After 160 EFPD at P₀ and a trip, Σ Hᵢ reproduces every §3.6 table entry to its printed precision. After any
	other history it gives what that history implies, which is the point. Each tick holds P over the tick and
	updates exactly, Hᵢ ← EᵢP + (Hᵢ − EᵢP)·e^(−λᵢ dt), so the 0.4 s group is stable at ×10 acceleration too.

	**What drives it.** The fission power, core.power_pctFP, which is the kinetics amplitude n. That already
	contains the delayed-neutron tail, so nothing here adds one (§3.6: "should not be added here").

	**Where the heat goes.** Core adds it to thermal power, so it reaches the pins, the coolant and the pools by
	the same path as fission heat. To keep steady thermal power at rated, Core scales prompt fission heat by
	(1 − f_ref), where f_ref = Σ Eᵢ(1 − e^(−λᵢ·160 EFPD)) = 9.28 % is the decay share of steady power on §3.6's
	reference history (DecayHeat.referenceFraction). That figure is larger than the 6.35 % §3.6 gives at 1 s,
	because it includes the groups below 1 s, where the formula has no value (it diverges at t → 0); it is the
	groups' own equilibrium, so the seat balances exactly.

	**Which clock.** The physics clock (§0.2), so the pools heat and cool on decay heat in real time, and ×10
	acceleration speeds it up with everything else. History built in one session reflects that session's physics
	time, not the ×360 burnup clock; the seat and the boot state carry §3.6's reference history instead (F35).

	**Boot.** Hot standby at beginning of cycle (§14.6): 160 EFPD at full power, then the refuelling outage (D-036).
]]
local System = require(script.Parent.Parent.Framework.System)

local DecayHeat = System.extend({
	name = "DecayHeat",
	lane = "fast",
	reads = { "core.power_pctFP" },
	writes = { "decay.heat_W", "decay.fraction" },
})

local EFPD_s = 86400

-- Σ Eᵢ(1 − e^(−λᵢ T_ref)): the decay share of steady thermal power on §3.6's reference history. Core needs it too.
function DecayHeat.referenceFraction(cfg: any): number
	local reference_s = cfg.DecayHeat.referenceOperatingTime_EFPD * EFPD_s
	local f = 0
	for _, group in cfg.DecayHeat.groups do
		f += group.fraction * (1 - math.exp(-group.lambda_ps * reference_s))
	end
	return f
end

function DecayHeat.init(self: any, ctx: any)
	local cfg = ctx.config
	self.port = ctx.channels
	self.log = ctx.log
	self.rated_W = cfg.Units.ratedThermal_MWt * 1e6
	self.lambda, self.E = {}, {}
	for i, group in cfg.DecayHeat.groups do
		self.lambda[i] = group.lambda_ps
		self.E[i] = group.fraction
	end
	self.N = #self.lambda
	self.H = table.create(self.N, 0)
	self.factor = table.create(self.N, 1)
	self.factorDt = -1
	self.reference_s = cfg.DecayHeat.referenceOperatingTime_EFPD * EFPD_s
	self.referenceFraction = DecayHeat.referenceFraction(cfg)
	local boot = cfg.DecayHeat.boot
	self:seatHistory(boot.historyPower_frac, self.reference_s, boot.shutdown_s)
end

--[[
	Seat the inventory as if the core had run at `power_frac` of rated for `operating_s` and then been shut down
	for `since_s`: the closed form of the group equations for that history.
]]
function DecayHeat.seatHistory(self: any, power_frac: number, operating_s: number, since_s: number)
	for i = 1, self.N do
		local l = self.lambda[i]
		self.H[i] = self.E[i] * power_frac * (1 - math.exp(-l * operating_s)) * math.exp(-l * since_s)
	end
	self:publish()
end

-- The seat at power (InitialConditions): §3.6's reference history held at that power, so decay is f_ref × P
function DecayHeat.seat(self: any, power_frac: number)
	self:seatHistory(power_frac, self.reference_s, 0)
end

function DecayHeat.publish(self: any)
	local total = 0
	for i = 1, self.N do
		total += self.H[i]
	end
	self.fraction = total
	self.port:write("decay.fraction", total)
	self.port:write("decay.heat_W", total * self.rated_W)
end

function DecayHeat.step(self: any, dt: number)
	if dt ~= self.factorDt then
		for i = 1, self.N do
			self.factor[i] = math.exp(-self.lambda[i] * dt)
		end
		self.factorDt = dt
	end
	local P = math.max((self.port:read("core.power_pctFP") or 0) / 100, 0)
	local H, E, factor = self.H, self.E, self.factor
	for i = 1, self.N do
		local target = E[i] * P
		H[i] = target + (H[i] - target) * factor[i]
	end
	self:publish()
end

--[[
	The inventory persists (§14.6), so a server that restarts in the middle of a shutdown carries on from the heat
	it had. The time the server was offline does not count: plant condition is kept as it was, not aged.
]]
function DecayHeat.save(self: any): any
	return { groups = table.clone(self.H) }
end

function DecayHeat.load(self: any, data: any, _fromVersion: number)
	if type(data) ~= "table" or type(data.groups) ~= "table" or #data.groups ~= self.N then
		return -- a save from a different group set: keep the boot state rather than guess a mapping
	end
	for i = 1, self.N do
		local v = data.groups[i]
		if type(v) == "number" and v == v and v >= 0 then
			self.H[i] = v
		end
	end
	self:publish()
end

function DecayHeat.getState(self: any): { [string]: any }
	return {
		fraction = self.fraction,
		heat_MW = self.fraction * self.rated_W / 1e6,
		referenceFraction = self.referenceFraction,
		groups = self.N,
	}
end

return DecayHeat
