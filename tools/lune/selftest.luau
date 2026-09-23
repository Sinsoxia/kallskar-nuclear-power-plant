--!strict
--[[
	Checks the headless engine itself, on throwaway instances (never on the project's place):
	require semantics and error texts, line numbers through the prelude, native-code detection, bindables,
	WaitForChild, RunService answers and the Random stand-in's statistics.

		lune run tools/lune/selftest

	test.sh runs it before the suite, so a harness regression shows up as a harness failure, not as a spec failure.
]]
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local task = require("@lune/task")

local Engine = require("./lib/Engine")
local Random = require("./lib/Random")

local game = roblox.Instance.new("DataModel")
local outputs: { string } = {}
Engine.boot(game, {
	waitForChildTimeout = 0.2,
	onOutput = function(_kind, text)
		table.insert(outputs, text)
	end,
})

local failures = 0
local function check(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	print(`{if ok then "ok  " else "FAIL"} {name}{if ok then "" else " :: " .. tostring(err)}`)
	if not ok then
		failures += 1
	end
end

local folder = roblox.Instance.new("Folder")
folder.Name = "Self"
folder.Parent = game:GetService("ReplicatedStorage")

local function module(name: string, source: string, parent: any?): any
	local m = roblox.Instance.new("ModuleScript")
	m.Name = name
	m.Source = source
	m.Parent = parent or folder
	return m
end

check("require runs a module once and caches its value", function()
	local m = module("Once", "shared.count = (shared.count or 0) + 1\nreturn { n = shared.count }")
	local a, b = Engine.require(m), Engine.require(m)
	assert(a == b and a.n == 1, "cached")
end)

check("script and script.Parent resolve inside a module", function()
	module("Leaf", "return 42")
	local m = module("Uses", "return require(script.Parent.Leaf) + #script.Name")
	assert(Engine.require(m) == 42 + 4)
end)

check("errors keep the file's own line numbers and Roblox's chunk name", function()
	local m = module("Boom", "--!strict\n--!native\nlocal x = 1\n\nerror('kaput')\nreturn x")
	local ok, err = pcall(Engine.require, m)
	assert(not ok, "should fail")
	assert(string.find(tostring(err), "ReplicatedStorage.Self.Boom:5: kaput", 1, true), tostring(err))
	assert(string.find(tostring(err), "^.-Requested module experienced an error while loading"), tostring(err))
	local again = select(2, pcall(Engine.require, m))
	assert(string.find(tostring(again), "Requested module experienced an error while loading", 1, true), "failed modules stay failed")
end)

check("recursive requires are refused with Roblox's message", function()
	module("CycleA", "return require(script.Parent.CycleB)")
	local b = module("CycleB", "return require(script.Parent.CycleA)")
	local ok, err = pcall(Engine.require, b)
	assert(not ok and string.find(tostring(err), "required recursively", 1, true), tostring(err))
end)

check("a module must return exactly one value", function()
	local ok, err = pcall(Engine.require, module("TwoValues", "return 1, 2"))
	assert(not ok and string.find(tostring(err), "exactly one value", 1, true), tostring(err))
	ok, err = pcall(Engine.require, module("NoValue", "local _ = 1"))
	assert(not ok and string.find(tostring(err), "exactly one value", 1, true), tostring(err))
end)

check("require rejects non-ModuleScripts", function()
	assert(not pcall(Engine.require, folder))
	assert(not pcall(Engine.require, "ReplicatedStorage.Self.Leaf"))
end)

check("--!native modules run as native code, others interpreted", function()
	local body = "return function() local a = 0 for i = 1, 3e6 do a += math.sqrt(i) * math.abs(math.sin(i)) end return a end"
	local native = Engine.require(module("Native", "--!native\n--!strict\n" .. body))
	local plain = Engine.require(module("Plain", "--!strict\n" .. body))
	local function time(fn: () -> number): number
		local best = math.huge
		for _ = 1, 3 do
			local t0 = os.clock()
			fn()
			best = math.min(best, os.clock() - t0)
		end
		return best
	end
	assert(native() == plain(), "same result")
	local tn, tp = time(native), time(plain)
	assert(tn < 0.7 * tp, string.format("native %.0f ms is not clearly faster than interpreted %.0f ms", tn * 1000, tp * 1000))
end)

check("Roblox globals reach modules; datatypes work", function()
	local m = module("Globals", [[
		local rs = game:GetService("RunService")
		assert(rs:IsStudio() == true and rs:IsServer() == true and rs:IsClient() == false)
		assert(typeof(game) == "Instance" and typeof(Random.new(1)) == "Random")
		assert((Vector3.new(3, 4, 0) - Vector3.new(0, 0, 0)).Magnitude == 5)
		assert(table.isfrozen(task) and type(task.wait) == "function")
		local f = Instance.new("Folder", workspace)
		f.Name = "Made"
		f:SetAttribute("Answer", 42)
		return workspace:FindFirstChild("Made"):GetAttribute("Answer")
	]])
	assert(Engine.require(m) == 42)
end)

check("BindableEvent delivers copies, deferred", function()
	local e = roblox.Instance.new("BindableEvent")
	local got: any = nil
	e.Event:Connect(function(payload)
		got = payload
	end)
	local sent = setmetatable({ a = { 1, 2 }, f = function() end }, { __index = function() return "mt" end })
	e:Fire(sent)
	assert(got == nil, "handlers are deferred")
	task.wait()
	assert(type(got) == "table" and got ~= sent and got.a[2] == 2, "a copy arrived")
	assert(got.f == nil and getmetatable(got) == nil, "functions and metatables do not cross")
end)

check("WaitForChild returns existing children, times out with nil, and gives up without a timeout", function()
	assert(folder:WaitForChild("Leaf").Name == "Leaf")
	assert(folder:WaitForChild("Nope", 0.05) == nil)
	local ok, err = pcall(function()
		return folder:WaitForChild("Nope")
	end)
	assert(not ok and string.find(tostring(err), "Infinite yield", 1, true), tostring(err))
end)

check("Random: deterministic per seed, independent, uniform", function()
	local a, b = Random.new(7), Random.new(7)
	for _ = 1, 100 do
		assert(a:NextNumber() == b:NextNumber())
	end
	local r = Random.new(12345)
	local n, sum, sumSq, below = 200000, 0, 0, 0
	for _ = 1, n do
		local u = r:NextNumber()
		assert(u >= 0 and u < 1)
		sum += u
		sumSq += u * u
		if u < 0.1 then
			below += 1
		end
	end
	local mean, var = sum / n, sumSq / n - (sum / n) ^ 2
	assert(math.abs(mean - 0.5) < 0.005, `mean {mean}`)
	assert(math.abs(var - 1 / 12) < 0.002, `variance {var}`)
	assert(math.abs(below / n - 0.1) < 0.004, `P(u<0.1) {below / n}`)
	local x, y = Random.new(1), Random.new(2)
	local sxy, sx, sy, sxx, syy = 0, 0, 0, 0, 0
	for _ = 1, 50000 do
		local u, v = x:NextNumber(), y:NextNumber()
		sxy += u * v
		sx += u
		sy += v
		sxx += u * u
		syy += v * v
	end
	local m = 50000
	local corr = (sxy / m - sx / m * sy / m) / math.sqrt((sxx / m - (sx / m) ^ 2) * (syy / m - (sy / m) ^ 2))
	assert(math.abs(corr) < 0.02, `neighbouring seeds correlate: {corr}`)
	local seen = {}
	for _ = 1, 1000 do
		local k = r:NextInteger(3, 5)
		assert(k == 3 or k == 4 or k == 5)
		seen[k] = true
	end
	assert(seen[3] and seen[4] and seen[5])
end)

print(if failures == 0 then "selftest: all checks passed" else `selftest: {failures} check(s) failed`)
process.exit(if failures == 0 then 0 else 1)
