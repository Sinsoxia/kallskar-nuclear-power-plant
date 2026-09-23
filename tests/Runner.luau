--!strict
--[[
	Kallskar test runner
	====================
	Finds every ModuleScript under ServerStorage.KallskarTests whose name ends in "Spec" (e.g. ConfigSpec, from
	tests/ConfigSpec.luau) and runs it. No dots in module names: MCP tools address scripts by dotted path.
	A spec module returns a table of named test functions:

		return {
			["frozen config rejects writes"] = function(t) t.throws(function() ... end) end,
			["bank worth A"] = function(t) t.pending("needs OpenMC cross sections (Track X)") end,
		}

	Output lines are prefixed "[KSK-TEST]" so they can be filtered from the Studio output log:
		[KSK-TEST] PASS  <spec> :: <test>
		[KSK-TEST] FAIL  <spec> :: <test> :: <message>
		[KSK-TEST] PEND  <spec> :: <test> :: <reason>
		[KSK-TEST] SUMMARY pass=N fail=N pending=N
	Pending is never counted as a pass (plan: validation targets without data are reported as pending).

	Started by ServerScriptService.Kallskar.Dev.TestBoot in Studio when ServerStorage.KallskarTests has the
	attribute RunTests = true.

	The same lines are also kept in a StringValue `LastReport` under the test root, and the counts in attributes
	LastPass / LastFail / LastPending / LastDone, so tools that can't read the output log can still read results.
]]

export type T = {
	ok: (cond: any, msg: string?) -> (),
	eq: (actual: any, expected: any, msg: string?) -> (),
	near: (actual: number, expected: number, tol: number, msg: string?) -> (),
	rel: (actual: number, expected: number, relTol: number, msg: string?) -> (),
	throws: (fn: () -> (), pattern: string?, msg: string?) -> (),
	pending: (reason: string) -> (),
	log: (msg: string) -> (),
}

local PENDING = {} -- sentinel error value

local function fmt(v: any): string
	if type(v) == "number" then
		return string.format("%.10g", v)
	end
	return tostring(v)
end

local function makeT(logs: { string }): T
	local t = {}
	function t.ok(cond: any, msg: string?)
		if not cond then
			error(msg or "expected truthy value", 2)
		end
	end
	function t.eq(actual: any, expected: any, msg: string?)
		if actual ~= expected then
			error(`{msg or "not equal"}: got {fmt(actual)}, expected {fmt(expected)}`, 2)
		end
	end
	-- |x − NaN| > tol and |x − y| > NaN are both false, so a NaN expectation or tolerance would pass anything
	local function unusable(expected: number, tol: number): boolean
		return type(expected) ~= "number" or expected ~= expected or not (tol >= 0)
	end
	function t.near(actual: number, expected: number, tol: number, msg: string?)
		if type(actual) ~= "number" or actual ~= actual or unusable(expected, tol) or math.abs(actual - expected) > tol then
			error(`{msg or "not within tolerance"}: got {fmt(actual)}, expected {fmt(expected)} ± {fmt(tol)}`, 2)
		end
	end
	function t.rel(actual: number, expected: number, relTol: number, msg: string?)
		-- an infinite expectation would make |expected| × relTol infinite too, and every number would be inside it:
		-- only that same infinity matches
		local infinite = expected == math.huge or expected == -math.huge
		local tol = if infinite then 0 else math.abs(expected) * relTol
		if
			type(actual) ~= "number"
			or actual ~= actual
			or unusable(expected, tol)
			or not (relTol >= 0)
			or (if infinite then actual ~= expected else math.abs(actual - expected) > tol)
		then
			error(`{msg or "outside relative tolerance"}: got {fmt(actual)}, expected {fmt(expected)} ± {relTol * 100}%`, 2)
		end
	end
	function t.throws(fn: () -> (), pattern: string?, msg: string?)
		local ok, err = pcall(fn)
		if ok then
			error(msg or "expected an error, none was raised", 2)
		end
		if pattern and not string.find(tostring(err), pattern) then
			error(`{msg or "wrong error"}: '{tostring(err)}' does not match '{pattern}'`, 2)
		end
	end
	function t.pending(reason: string)
		error({ [PENDING] = true, reason = reason }, 0)
	end
	function t.log(msg: string)
		table.insert(logs, msg)
	end
	return t :: any
end

local Runner = {}
Runner.makeT = makeT -- the assertions themselves, for RunnerSpec

function Runner.run(root: Instance, filter: string?): (number, number, number)
	local specs = {}
	for _, inst in root:GetDescendants() do
		if inst:IsA("ModuleScript") and #inst.Name > 4 and string.sub(inst.Name, -4) == "Spec" then
			if not filter or string.find(inst.Name, filter, 1, true) then
				table.insert(specs, inst)
			end
		end
	end
	table.sort(specs, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)

	local report: { string } = {}
	local function emit(line: string, isWarning: boolean?)
		table.insert(report, line)
		if isWarning then
			warn(line)
		else
			print(line)
		end
	end

	root:SetAttribute("LastDone", false)
	local pass, fail, pend = 0, 0, 0
	for _, specModule in specs do
		local specName = string.sub(specModule.Name, 1, -5)
		local okLoad, cases = pcall(require, specModule)
		if not okLoad then
			fail += 1
			emit(`[KSK-TEST] FAIL  {specName} :: <load> :: {cases}`, true)
			continue
		end
		local names = {}
		for name in cases do
			table.insert(names, name)
		end
		table.sort(names)
		for _, name in names do
			local logs = {}
			local t = makeT(logs)
			local t0 = os.clock()
			local ok, err = xpcall(cases[name], function(e)
				if type(e) == "table" and e[PENDING] then
					return e
				end
				return `{tostring(e)}\n{debug.traceback(nil, 2)}`
			end, t)
			local ms = string.format("%.1f ms", (os.clock() - t0) * 1000)
			if ok then
				pass += 1
				emit(`[KSK-TEST] PASS  {specName} :: {name} ({ms})`)
			elseif type(err) == "table" and err[PENDING] then
				pend += 1
				emit(`[KSK-TEST] PEND  {specName} :: {name} :: {err.reason}`)
			else
				fail += 1
				emit(`[KSK-TEST] FAIL  {specName} :: {name} :: {err}`, true)
			end
			for _, line in logs do
				emit(`[KSK-TEST]   log {specName} :: {name} :: {line}`)
			end
			-- yield between cases so Studio's script timeout applies to each test, not to the whole suite at once
			task.wait()
		end
	end
	emit(`[KSK-TEST] SUMMARY pass={pass} fail={fail} pending={pend}`)

	local store = root:FindFirstChild("LastReport")
	if not store then
		store = Instance.new("StringValue")
		store.Name = "LastReport"
		store.Parent = root
	end
	(store :: StringValue).Value = table.concat(report, "\n")
	root:SetAttribute("LastPass", pass)
	root:SetAttribute("LastFail", fail)
	root:SetAttribute("LastPending", pend)
	root:SetAttribute("LastDone", true)
	return pass, fail, pend
end

return Runner
