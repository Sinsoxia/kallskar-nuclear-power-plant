--!native
--!strict
--[[
	Pin — fuel-pellet conduction kernel for FuelThermal (spec §14.3; Config.FuelPin from tools/derive/pin_thermal.py).
	================================================================================================================

	Steady conduction in an annular pellet with uniform heating and an adiabatic hole (Kirchhoff transform):
		Θ(T(r)) = Θ(T_s) + q'·g(r),    Θ(T) = ∫k dT    (Carbajo et al. MOX conductivity, integrated by the script)
	The volume-average temperature uses 4-point Gauss–Legendre in r; the centre (hole surface) uses g at r_i.
	Θ is tabulated on a uniform temperature grid and is piecewise linear between grid points; its inverse is exact
	(the same piecewise-linear function) and O(1) through a bin index built once here.

	Flat arrays only; no metatables (numeric kernel rule).
]]

local Pin = {}

export type Tables = {
	theta: { number },
	n: number,
	T0: number,
	step: number,
	invStep: number,
	-- inverse: bin b covers Θ in [binStart + (b−1)·binWidth, …); binIdx[b] = first segment that can contain it
	binIdx: { number },
	binWidth: number,
	nBins: number,
	gq: { number },
	wq: { number },
	nq: number,
	gc: number,
	capInner: { number },
	capOuter: { number },
	capT0: number,
	capInvStep: number,
	capN: number,
	rGap: number,
	rCladNa: number,
}

function Pin.new(config: any): Tables
	local fp = config.FuelPin
	local c = fp.conduction
	local theta = table.clone(c.theta_Wpm)
	local n = #theta
	for i = 2, n do
		assert(theta[i] > theta[i - 1], "Θ table must increase")
	end
	local nBins = 4 * n
	local binWidth = theta[n] / nBins
	local binIdx = table.create(nBins, 1)
	local seg = 1
	for b = 1, nBins do
		local start = (b - 1) * binWidth
		while seg < n - 1 and theta[seg + 1] <= start do
			seg += 1
		end
		binIdx[b] = seg
	end
	local hc = fp.heatCapacity
	assert(#hc.inner_JpmK == #hc.outer_JpmK, "heat capacity tables differ in length")
	local gq, wq = table.clone(c.quadratureG), table.clone(c.quadratureWeight)
	assert(#gq == #wq, "quadrature tables differ in length")
	-- the printed weights sum to 1 only to their printed precision; normalise so a uniform field averages exactly
	local wsum = 0
	for k = 1, #wq do
		wsum += wq[k]
	end
	assert(math.abs(wsum - 1) < 1e-6, "quadrature weights must sum to 1")
	for k = 1, #wq do
		wq[k] /= wsum
	end
	return {
		theta = theta,
		n = n,
		T0 = c.thetaT0_K,
		step = c.thetaStep_K,
		invStep = 1 / c.thetaStep_K,
		binIdx = binIdx,
		binWidth = binWidth,
		nBins = nBins,
		gq = gq,
		wq = wq,
		nq = #gq,
		gc = c.centreG,
		capInner = table.clone(hc.inner_JpmK),
		capOuter = table.clone(hc.outer_JpmK),
		capT0 = hc.T0_K,
		capInvStep = 1 / hc.step_K,
		capN = #hc.inner_JpmK,
		rGap = fp.resistance.gap_mKpW,
		rCladNa = fp.resistance.cladToSodium_mKpW,
	}
end

-- Θ(T) in W/m; linear extrapolation outside the table
function Pin.thetaOf(p: Tables, T: number): number
	local x = (T - p.T0) * p.invStep
	local i = math.floor(x)
	local th = p.theta
	if i < 0 then
		i = 0
	elseif i > p.n - 2 then
		i = p.n - 2
	end
	local a = th[i + 1]
	return a + (x - i) * (th[i + 2] - a)
end

-- inverse of thetaOf
function Pin.tempOf(p: Tables, value: number): number
	local th = p.theta
	local seg
	if value <= 0 then
		seg = 1
	else
		local b = math.floor(value / p.binWidth) + 1
		if b > p.nBins then
			seg = p.n - 1
		else
			seg = p.binIdx[b]
			local last = p.n - 1
			while seg < last and th[seg + 1] <= value do
				seg += 1
			end
		end
	end
	local a, b2 = th[seg], th[seg + 1]
	return p.T0 + (seg - 1 + (value - a) / (b2 - a)) * p.step
end

--[[
	Steady rise of the volume-average pellet temperature above the surface temperature Ts (K) at linear heat rate
	q (W/m). Summed as differences so the result stays exact as q → 0 (no cancellation against Ts).
]]
function Pin.averageRise(p: Tables, Ts: number, q: number): number
	local base = Pin.thetaOf(p, Ts)
	local gq, wq = p.gq, p.wq
	local s = 0
	for k = 1, p.nq do
		s += wq[k] * (Pin.tempOf(p, base + q * gq[k]) - Ts)
	end
	return s
end

-- steady volume-average pellet temperature
function Pin.average(p: Tables, Ts: number, q: number): number
	return Ts + Pin.averageRise(p, Ts, q)
end

-- steady hole-surface ("centreline") temperature
function Pin.centre(p: Tables, Ts: number, q: number): number
	return Pin.tempOf(p, Pin.thetaOf(p, Ts) + q * p.gc)
end

--[[
	Pellet resistance from the volume average to the surface, (T_avg − T_s)/q, in K per W/m. At very low power the
	secant tends to Σwg/k(T_s); a 1 W/m floor keeps the quotient well defined and inside one table segment.
]]
function Pin.pelletResistance(p: Tables, Ts: number, q: number): number
	if q < 1 then
		q = 1
	end
	return Pin.averageRise(p, Ts, q) / q
end

-- heat capacity per metre of pellet, J/(m·K)
function Pin.capacity(p: Tables, outer: boolean, T: number): number
	local cap = if outer then p.capOuter else p.capInner
	local x = (T - p.capT0) * p.capInvStep
	local i = math.floor(x)
	if i < 0 then
		return cap[1]
	elseif i > p.capN - 2 then
		return cap[p.capN]
	end
	local a = cap[i + 1]
	return a + (x - i) * (cap[i + 2] - a)
end

return table.freeze(Pin)
