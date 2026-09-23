--!strict
--[[
	Headless stand-in for Roblox's `Random` datatype.

	Roblox does not document its generator (it is PCG-based), so the sequence for a given seed is NOT the one
	Studio produces. What is kept: determinism per seed, independent streams per object, uniform [0, 1) doubles
	with 53 bits, and the method surface (NextNumber, NextInteger, NextUnitVector, Shuffle, Clone).
	Anything that depends on the exact Roblox sequence (a test asserting one specific noisy sample) cannot be
	reproduced headless; statistical assertions can.

	Generator: xoshiro128** (Blackman & Vigna), seeded through a murmur3 finaliser. All arithmetic stays inside
	32-bit words so doubles never lose precision.
]]

local TWO32 = 4294967296

-- (a * b) mod 2^32 for 32-bit unsigned a, b, without exceeding 2^53 in any partial product
local function mul32(a: number, b: number): number
	local ah, al = a // 65536, a % 65536
	local bh, bl = b // 65536, b % 65536
	local mid = (ah * bl + al * bh) % 65536
	return (mid * 65536 + al * bl) % TWO32
end

local function rotl(x: number, k: number): number
	return bit32.lrotate(x, k)
end

local function fmix32(h: number): number
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x85EBCA6B)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = mul32(h, 0xC2B2AE35)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h
end

type State = { s0: number, s1: number, s2: number, s3: number }

local Random = {}
Random.__index = Random
Random.__type = "Random"

local function nextU32(self: State): number
	local s0, s1, s2, s3 = self.s0, self.s1, self.s2, self.s3
	local result = mul32(rotl(mul32(s1, 5), 7), 9)
	local t = bit32.lshift(s1, 9)
	s2 = bit32.bxor(s2, s0)
	s3 = bit32.bxor(s3, s1)
	s1 = bit32.bxor(s1, s2)
	s0 = bit32.bxor(s0, s3)
	s2 = bit32.bxor(s2, t)
	s3 = rotl(s3, 11)
	self.s0, self.s1, self.s2, self.s3 = s0, s1, s2, s3
	return result
end

local function unit(self: State): number
	local a = bit32.rshift(nextU32(self), 5) -- 27 bits
	local b = bit32.rshift(nextU32(self), 6) -- 26 bits
	return (a * 67108864 + b) / 9007199254740992
end

local entropy = 0

function Random.new(seed: number?)
	local s: number
	if seed == nil then
		entropy += 1
		s = math.floor(os.clock() * 1e6) + os.time() * 1000 + entropy
	else
		assert(type(seed) == "number", "Random.new: seed must be a number")
		s = seed
	end
	s = math.floor(s)
	local lo = s % TWO32
	local hi = math.floor(s / TWO32) % TWO32
	local self = setmetatable({
		s0 = fmix32(bit32.bxor(lo, 0x9E3779B9)),
		s1 = fmix32(bit32.bxor(hi, 0x7F4A7C15)),
		s2 = fmix32(bit32.bxor(lo, 0x6A09E667)),
		s3 = fmix32(bit32.bxor(hi, 0xBB67AE85)),
	}, Random)
	if self.s0 == 0 and self.s1 == 0 and self.s2 == 0 and self.s3 == 0 then
		self.s0 = 1
	end
	return self
end

function Random.NextNumber(self: any, min: number?, max: number?): number
	local u = unit(self)
	if min == nil and max == nil then
		return u
	end
	local a, b = min or 0, max or 1
	return a + (b - a) * u
end

function Random.NextInteger(self: any, min: number, max: number): number
	assert(type(min) == "number" and type(max) == "number", "Random:NextInteger expects two numbers")
	min, max = math.floor(min), math.floor(max)
	if max < min then
		error("Random:NextInteger: max must be greater than or equal to min", 2)
	end
	return min + math.floor(unit(self) * (max - min + 1))
end

function Random.NextUnitVector(self: any): any
	-- Vector3 is supplied by the engine (Lune's roblox library); looked up lazily to keep this module standalone
	local Vector3 = (Random :: any).Vector3
	local x, y, z, m
	repeat
		x, y, z = unit(self) * 2 - 1, unit(self) * 2 - 1, unit(self) * 2 - 1
		m = math.sqrt(x * x + y * y + z * z)
	until m > 1e-6 and m <= 1
	return Vector3.new(x / m, y / m, z / m)
end

function Random.Shuffle(self: any, t: { any })
	for i = #t, 2, -1 do
		local j = 1 + math.floor(unit(self) * i)
		t[i], t[j] = t[j], t[i]
	end
end

function Random.Clone(self: any)
	return setmetatable({ s0 = self.s0, s1 = self.s1, s2 = self.s2, s3 = self.s3 }, Random)
end

return Random
