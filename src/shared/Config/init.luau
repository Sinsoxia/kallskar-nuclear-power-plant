--!strict
--[[
	Config
	======
	The single home for every number in the spec (spec §14.7). The simulation, guide boards and tests all read this.

	- Pure data. Requires nothing from the simulation, so client-side guide boards can use it freely.
	- Deep-frozen with table.freeze: any write throws, and reads cost nothing extra (no proxy metatables).
	- Every number has a provenance entry (see Provenance.luau). Config.provenance["Kinetics.betaEff_pcm"] tells you
	  where a value came from; Config.sourceOf(path) also resolves values nested inside a boxed table.

	Usage:
		local Config = require(ReplicatedStorage.Kallskar.Config)
		local beta = Config.Kinetics.betaEff_pcm
]]
local Provenance = require(script.Provenance)

local prov: { [string]: Provenance.Entry } = {}

local function load<T>(name: string, tree: T): T
	return Provenance.build(name, tree, prov)
end

local Config = {
	Units = load("Units", require(script.Units)),
	Clocks = load("Clocks", require(script.Clocks)),
	Core = load("Core", require(script.Core)),
	FuelPin = load("FuelPin", require(script.FuelPin)),
	Kinetics = load("Kinetics", require(script.Kinetics)),
	Feedback = load("Feedback", require(script.Feedback)),
	Reactivity = load("Reactivity", require(script.Reactivity)),
	Rods = load("Rods", require(script.Rods)),
	Instruments = load("Instruments", require(script.Instruments)),
	DecayHeat = load("DecayHeat", require(script.DecayHeat)),
	PhysicsModel = load("PhysicsModel", require(script.PhysicsModel)),
	Primary = load("Primary", require(script.Primary)),
	Program = load("Program", require(script.Program)),
	Protection = load("Protection", require(script.Protection)),
	Sodium = load("Sodium", require(script.Sodium)),
	Access = load("Access", require(script.Access)),
	Desks = load("Desks", require(script.Desks)),
	Engineering = load("Engineering", require(script.Engineering)),

	provenance = table.freeze(prov),
	revision = "A5", -- the spec revision these values follow (REACTOR SPEC/sfr-1000-spec.html)
}

--[[
	Where did the value at `path` come from? `path` is dot-separated, e.g. "Rods.regulating.speed_mmps".
	Returns nil if no entry covers it (which the provenance test treats as a failure).
]]
function Config.sourceOf(path: string): Provenance.Entry?
	return Provenance.lookup(prov, path)
end

Provenance.deepFreeze(Config)

return Config
