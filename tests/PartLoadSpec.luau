--!strict
--[[
	PartLoad verification (spec §9.2). The core outlet and the flow programme are checked where AutoControls acts
	on them (AutoControlsSpec); this file checks the two functions the heat sink stands on.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Kallskar = ReplicatedStorage:WaitForChild("Kallskar")
local Config = require(Kallskar:WaitForChild("Config")) :: any
local Systems = ServerScriptService:WaitForChild("Kallskar"):WaitForChild("Systems")
local PartLoad = require(Systems:WaitForChild("PartLoad")) :: any

local TABLE = Config.Program.partLoadTable

return {
	["the secondary cold leg regenerates §9.2's column, and is 375 °C with no load"] = function(t)
		for row, power in TABLE.power_pct do
			-- the table is printed to whole degrees, so half a degree is its own rounding
			t.near(PartLoad.secondaryCold_C(Config, power), TABLE.secondaryCold_C[row], 0.5,
				`{power} %: {TABLE.secondaryCold_C[row]} °C`)
		end
		t.near(PartLoad.secondaryCold_C(Config, 0), Config.Program.partLoad.coreInlet_C, 1e-12,
			"no load: the cold leg sits at the core inlet")
	end,

	["secondary flow is the primary flow column, which is what §9.2's own heat balance gives"] = function(t)
		for row, power in TABLE.power_pct do
			-- ṁ_s ∝ P / (T_hot − T_cold), from the table's own temperature columns and its full-load row
			local dFull = TABLE.secondaryHot_C[1] - TABLE.secondaryCold_C[1]
			local dRow = TABLE.secondaryHot_C[row] - TABLE.secondaryCold_C[row]
			local balance = (power / 100) * dFull / dRow
			local flow = TABLE.flow_pct[row] / 100
			t.near(PartLoad.secondaryFlow_frac(Config, power), flow, 1e-12, `{power} %: {TABLE.flow_pct[row]} % flow`)
			-- each difference of two whole-degree figures is good to ±1 K, which bounds the ratio's relative error
			t.near(balance, flow, flow * (1 / dRow + 1 / dFull), `{power} %: the table's heat balance agrees`)
		end
	end,
}
