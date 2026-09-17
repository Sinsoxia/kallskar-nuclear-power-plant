--!strict
--[[
	Liquid sodium properties (spec Appendix A, Fink–Leibowitz). T in kelvin, SI units out.
	The coefficients live in Config.Sodium; these are the pure functions over them.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Config")) :: any

local D = Config.Sodium.density
local CP = Config.Sodium.specificHeat
local K = Config.Sodium.conductivity
local MU = Config.Sodium.viscosity
local PV = Config.Sodium.vapourPressure

local Da, Db, Dc, Tc = D.a, D.b, D.c, D.criticalTemperature_K
local CPa, CPb, CPc, CPd = CP.a, CP.b, CP.c, CP.d
local Ka, Kb, Kc, Kd = K.a, K.b, K.c, K.d

local Sodium = {}

-- kg/m³
function Sodium.density(T: number): number
	local x = 1 - T / Tc
	return Da + Db * x + Dc * math.sqrt(x)
end

-- J/(kg·K)
function Sodium.specificHeat(T: number): number
	return 1000 * (CPa + T * (CPb + T * CPc) + CPd / (T * T))
end

-- W/(m·K)
function Sodium.conductivity(T: number): number
	return Ka + T * (Kb + T * (Kc + T * Kd))
end

-- Pa·s
function Sodium.viscosity(T: number): number
	return math.exp(MU.a + MU.b * math.log(T) + MU.c / T)
end

-- Pa
function Sodium.vapourPressure(T: number): number
	return 1e6 * math.exp(PV.a + PV.b / T + PV.c * math.log(T))
end

return table.freeze(Sodium)
