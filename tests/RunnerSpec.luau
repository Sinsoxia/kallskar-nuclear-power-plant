--!strict
--[[
	The test runner's own assertions. Every numeric check in the suite goes through t.near or t.rel, so a tolerance
	check that passes on NaN would pass whatever a broken calculation produced.
]]
local Runner = require(script.Parent:WaitForChild("Runner")) :: any

local function fails(fn: () -> ()): boolean
	return not pcall(fn)
end

return {
	["near and rel fail on a NaN expectation or tolerance instead of passing"] = function(t)
		local check = Runner.makeT({})
		local nan = 0 / 0
		t.ok(fails(function()
			check.near(1, nan, 1)
		end), "near: NaN expected")
		t.ok(fails(function()
			check.near(1, 1, nan)
		end), "near: NaN tolerance")
		t.ok(fails(function()
			check.near(1, 1, -1)
		end), "near: negative tolerance")
		t.ok(fails(function()
			check.rel(1, nan, 0.1)
		end), "rel: NaN expected")
		t.ok(fails(function()
			check.rel(1, 1, nan)
		end), "rel: NaN relative tolerance")
		-- and what held before still holds
		t.ok(not fails(function()
			check.near(1.05, 1, 0.1)
		end), "near: inside the tolerance")
		t.ok(fails(function()
			check.near(1.2, 1, 0.1)
		end), "near: outside it")
		t.ok(not fails(function()
			check.rel(105, 100, 0.1)
		end), "rel: inside the tolerance")
		t.ok(fails(function()
			check.near(nan, 1, 1)
		end), "near: a NaN result still fails")
	end,

	["rel with an infinite expectation passes only that same infinity"] = function(t)
		local check = Runner.makeT({})
		local inf = math.huge
		-- |expected| × relTol is itself infinite, so without a rule of its own any number was "within" it
		t.ok(fails(function()
			check.rel(1, inf, 1e-6)
		end), "rel: a finite result against +inf")
		t.ok(fails(function()
			check.rel(-inf, inf, 1e-6)
		end), "rel: -inf against +inf")
		t.ok(fails(function()
			check.rel(0, -inf, 1e-6)
		end), "rel: a finite result against -inf")
		t.ok(fails(function()
			check.rel(0 / 0, inf, 1e-6)
		end), "rel: NaN against +inf")
		t.ok(not fails(function()
			check.rel(inf, inf, 1e-6)
		end), "rel: +inf against +inf")
		t.ok(not fails(function()
			check.rel(-inf, -inf, 0)
		end), "rel: -inf against -inf")
	end,
}
