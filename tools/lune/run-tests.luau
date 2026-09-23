--!strict
--[[
	Run the Kallskar test suite headless (see docs/HEADLESS_TESTS.md).

		lune run tools/lune/run-tests [--filter <text>] [--place <file.rbxl>] [--rojo <path>] [--no-audit] [--no-native]
		                              [--timeout <seconds>] [--out <dir>]

	Run it from the repository root. Steps:
	  1. `rojo build default.project.json` into <out>/place.rbxl (skipped with --place).
	  2. Deserialise the place with Lune's roblox library and boot the headless engine (lib/Engine.luau).
	  3. Do what a Studio Play session does for the tests: set RunTests (and TestFilter) on
	     ServerStorage.KallskarTests and start ServerScriptService.Kallskar.Dev.TestBoot, which requires
	     tests/Runner and runs every *Spec module. Main.server is not started: the specs build their own plants.
	  4. Wait for the Runner's LastDone attribute, read LastReport, and compare the outcome with
	     tools/lune/expectations.luau (known failures and why).
	  5. Audit: in a fresh copy of the place, require every ModuleScript under src/ and record which cannot load
	     headless and the engine API that stops them (informational; never fails the run).

	Writes <out>/report.txt (the Runner's LastReport), <out>/results.json, <out>/junit.xml and <out>/audit.txt.
	Exit code: 0 when every outcome matches expectations, 1 otherwise (an unexpected failure, an expected failure
	that now passes, a spec that failed to load, or no summary at all).
]]
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox") :: any
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")

local Engine = require("./lib/Engine")
local Expectations = require("./expectations")

-- Arguments ------------------------------------------------------------------------------------------------------
local args = {
	filter = nil :: string?,
	place = nil :: string?,
	rojo = nil :: string?,
	audit = true,
	native = true,
	timeout = 3600,
	out = "tools/lune/.out",
}
do
	local i = 1
	local argv = process.args
	while i <= #argv do
		local a = argv[i]
		if a == "--filter" then
			args.filter = argv[i + 1]
			i += 1
		elseif a == "--place" then
			args.place = argv[i + 1]
			i += 1
		elseif a == "--rojo" then
			args.rojo = argv[i + 1]
			i += 1
		elseif a == "--timeout" then
			args.timeout = assert(tonumber(argv[i + 1]), "--timeout expects seconds")
			i += 1
		elseif a == "--out" then
			args.out = argv[i + 1]
			i += 1
		elseif a == "--no-audit" then
			args.audit = false
		elseif a == "--no-native" then
			args.native = false
		elseif a == "--help" or a == "-h" then
			print("usage: lune run tools/lune/run-tests [--filter <text>] [--place <file.rbxl>] [--rojo <path>] [--no-audit] [--no-native] [--timeout <s>] [--out <dir>]")
			process.exit(0)
		else
			error(`unknown argument '{a}' (try --help)`)
		end
		i += 1
	end
end

if not fs.isFile("default.project.json") then
	stdio.ewrite("run-tests: run this from the repository root (default.project.json not found)\n")
	process.exit(2)
end
if not fs.isDir(args.out) then
	fs.writeDir(args.out)
end

local isCI = process.env.GITHUB_ACTIONS == "true"
local useColor = not isCI and process.env.NO_COLOR == nil

local function colored(color: any, text: string): string
	if not useColor then
		return text
	end
	return stdio.color(color) .. text .. stdio.color("reset")
end

-- 1. Build ------------------------------------------------------------------------------------------------------
local placePath = args.place
if not placePath then
	local exe = if process.os == "windows" then ".exe" else ""
	local rojo = args.rojo or process.env.ROJO
	if not rojo then
		local pinned = `tools/lune/.bin/rojo{exe}`
		rojo = if fs.isFile(pinned) then pinned else "rojo"
	end
	placePath = `{args.out}/place.rbxl`
	local built = process.exec(rojo :: string, { "build", "default.project.json", "--output", placePath :: string })
	if not built.ok then
		stdio.ewrite(`run-tests: '{rojo} build' failed (exit {built.code})\n{built.stdout}{built.stderr}\n`)
		process.exit(2)
	end
	print(`[harness] {string.gsub(built.stdout, "%s+$", "")}`)
end

local function loadPlace(): any
	return roblox.deserializePlace(fs.readFile(placePath :: string))
end

-- 2. Boot ---------------------------------------------------------------------------------------------------------
local function onOutput(kind: Engine.OutputKind, text: string)
	if kind == "warn" then
		print(colored("yellow", text))
	elseif kind == "error" then
		print(colored("red", text))
	else
		print(text)
	end
end

local game = loadPlace()
Engine.boot(game, { onOutput = onOutput, native = args.native })

local ServerStorage = game:GetService("ServerStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local root = ServerStorage:FindFirstChild("KallskarTests")
assert(root, "ServerStorage.KallskarTests missing from the built place (check default.project.json)")
local testBoot = ServerScriptService:FindFirstChild("Kallskar")
testBoot = testBoot and testBoot:FindFirstChild("Dev")
testBoot = testBoot and testBoot:FindFirstChild("TestBoot")
assert(testBoot and testBoot:IsA("Script"), "ServerScriptService.Kallskar.Dev.TestBoot (Script) missing from the built place")

-- 3. What Studio's Play does for the tests -----------------------------------------------------------------------
root:SetAttribute("RunTests", true)
if args.filter then
	root:SetAttribute("TestFilter", args.filter)
end
print(`[harness] starting {testBoot:GetFullName()}` .. (if args.filter then ` (TestFilter = "{args.filter}")` else ""))
local t0 = os.clock()
local bootOk = Engine.runScript(testBoot)
if not bootOk then
	stdio.ewrite("run-tests: TestBoot failed to start\n")
	process.exit(1)
end

-- 4. Wait for the Runner ------------------------------------------------------------------------------------------
while root:GetAttribute("LastDone") ~= true do
	if os.clock() - t0 > args.timeout then
		stdio.ewrite(`run-tests: no summary after {args.timeout} s\n`)
		process.exit(1)
	end
	task.wait(0.05)
end
local elapsed = os.clock() - t0
local longest = Engine.longestStretchWithoutYield()

local reportValue = root:FindFirstChild("LastReport")
local reportText: string = if reportValue then reportValue.Value else ""
fs.writeFile(`{args.out}/report.txt`, reportText .. "\n")

-- Parse the Runner's report lines ----------------------------------------------------------------------------------
type Result = { spec: string, name: string, status: string, message: string?, ms: number? }
local results: { Result } = {}
local current: Result? = nil
local summary: { pass: number, fail: number, pending: number }? = nil
for _, line in string.split(reportText, "\n") do
	local body = string.match(line, "^%[KSK%-TEST%] (.*)$")
	if body then
		current = nil
		local status, rest = string.match(body, "^(%u+)%s+(.*)$")
		if status == "PASS" then
			local spec, name, ms = string.match(rest :: string, "^(.-) :: (.*) %(([%d%.]+) ms%)$")
			current = { spec = spec :: string, name = name :: string, status = "pass", ms = tonumber(ms) }
		elseif status == "FAIL" or status == "PEND" then
			local spec, remainder = string.match(rest :: string, "^(.-) :: (.*)$")
			-- names never contain " :: ", messages may
			local name, message = string.match(remainder :: string, "^(.-) :: (.*)$")
			current = {
				spec = spec :: string,
				name = (name or remainder) :: string,
				status = if status == "FAIL" then "fail" else "pending",
				message = message,
			}
		elseif status == "SUMMARY" then
			local p, f, n = string.match(rest :: string, "pass=(%d+) fail=(%d+) pending=(%d+)")
			summary = { pass = tonumber(p) :: number, fail = tonumber(f) :: number, pending = tonumber(n) :: number }
		end
		if current then
			table.insert(results, current)
		end
	elseif current and current.message then
		current.message ..= "\n" .. line -- traceback continuation
	end
end

-- Compare with expectations ------------------------------------------------------------------------------------------
local function key(spec: string, name: string): string
	return `{spec} :: {name}`
end
local expected: { [string]: any } = {}
for _, e in Expectations.failures do
	expected[key(e.spec, e.test)] = e
end

local unexpected: { string } = {}
local knownFailures: { string } = {}
local fixed: { string } = {}
local seen: { [string]: boolean } = {}
for _, r in results do
	local k = key(r.spec, r.name)
	seen[k] = true
	local e = expected[k]
	if r.status == "fail" then
		if e then
			table.insert(knownFailures, `{k}  [{e.kind}] {e.why}`)
		else
			table.insert(unexpected, `FAIL {k} :: {string.split(r.message or "", "\n")[1]}`)
		end
	elseif r.status == "pass" and e then
		table.insert(fixed, `{k}  (listed as {e.kind}: {e.why})`)
	end
end
local missingExpectations: { string } = {}
if not args.filter then
	for k in expected do
		if not seen[k] then
			table.insert(missingExpectations, k)
		end
	end
	table.sort(missingExpectations)
end

-- Reports ----------------------------------------------------------------------------------------------------------
fs.writeFile(`{args.out}/results.json`, serde.encode("json", {
	summary = summary,
	elapsed_s = elapsed,
	longestStretchWithoutYield_s = longest.seconds,
	results = results,
	unexpected = unexpected,
	fixed = fixed,
}, true))

local function xmlEscape(s: string): string
	return (string.gsub(s, "[<>&\"']", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;", ['"'] = "&quot;", ["'"] = "&apos;" }))
end
do
	local bySpec: { [string]: { Result } } = {}
	local order: { string } = {}
	for _, r in results do
		if not bySpec[r.spec] then
			bySpec[r.spec] = {}
			table.insert(order, r.spec)
		end
		table.insert(bySpec[r.spec], r)
	end
	local x = { '<?xml version="1.0" encoding="UTF-8"?>', "<testsuites>" }
	for _, spec in order do
		local list = bySpec[spec]
		local f, s = 0, 0
		for _, r in list do
			if r.status == "fail" then
				f += 1
			elseif r.status == "pending" then
				s += 1
			end
		end
		table.insert(x, `  <testsuite name="{xmlEscape(spec)}" tests="{#list}" failures="{f}" skipped="{s}">`)
		for _, r in list do
			local time = string.format("%.3f", (r.ms or 0) / 1000)
			table.insert(x, `    <testcase classname="{xmlEscape(spec)}" name="{xmlEscape(r.name)}" time="{time}">`)
			if r.status == "fail" then
				local e = expected[key(r.spec, r.name)]
				local note = if e then `[known {e.kind}] ` else ""
				table.insert(x, `      <failure message="{xmlEscape(note .. string.split(r.message or "", "\n")[1])}">{xmlEscape(r.message or "")}</failure>`)
			elseif r.status == "pending" then
				table.insert(x, `      <skipped message="{xmlEscape(r.message or "")}"/>`)
			end
			table.insert(x, "    </testcase>")
		end
		table.insert(x, "  </testsuite>")
	end
	table.insert(x, "</testsuites>")
	fs.writeFile(`{args.out}/junit.xml`, table.concat(x, "\n") .. "\n")
end

-- 5. Audit ----------------------------------------------------------------------------------------------------------
local auditLines: { string } = {}
if args.audit then
	local audit = loadPlace()
	local quiet = function() end
	Engine.boot(audit, { onOutput = quiet, waitForChildTimeout = 1 })
	local modules = {}
	for _, service in { "ReplicatedStorage", "ServerScriptService", "StarterPlayer" } do
		for _, inst in audit:GetService(service):GetDescendants() do
			if inst:IsA("ModuleScript") then
				table.insert(modules, inst)
			end
		end
	end
	table.sort(modules, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	local okCount = 0
	for _, m in modules do
		local ok, err = pcall(Engine.require, m)
		if ok then
			okCount += 1
		else
			-- the first line of the innermost error names the blocking API
			local msg = string.gsub(tostring(err), "^Requested module experienced an error while loading: ", "")
			table.insert(auditLines, `LOAD-FAIL {m:GetFullName()} :: {string.split(msg, "\n")[1]}`)
		end
	end
	table.insert(auditLines, 1, `modules loaded headless: {okCount}/{#modules}`)

	-- Main.server, the real server bootstrap: start it and give it 10 s of 60 Hz Heartbeat frames.
	local main = audit:GetService("ServerScriptService"):FindFirstChild("Kallskar")
	main = main and main:FindFirstChild("Main")
	if main then
		local okMain, errMain = Engine.runScript(main)
		local plant = Engine.shared().Kallskar
		if okMain and plant then
			for _ = 1, 600 do
				Engine.heartbeat(1 / 60)
			end
			local sched = plant.scheduler
			table.insert(auditLines, string.format(
				"BOOT %s: %d systems, %.1f s simulated in 600 Heartbeat frames, halted: %s, %d remote fires recorded (no clients)",
				main:GetFullName(), #plant.registry.systems, sched.clock.sim, tostring(sched.halted or "no"), #Engine.remoteLog()))
		else
			table.insert(auditLines, `BOOT-FAIL {main:GetFullName()} :: {string.split(tostring(errMain or "shared.Kallskar not published"), "\n")[1]}`)
		end
	end

	local scripts = {}
	for _, service in { "ServerScriptService", "StarterPlayer" } do
		for _, inst in audit:GetService(service):GetDescendants() do
			if (inst:IsA("Script") or inst:IsA("LocalScript")) and inst ~= main and inst.Name ~= "TestBoot" then
				table.insert(scripts, inst)
			end
		end
	end
	for _, inst in scripts do
		local why = if inst:IsA("LocalScript") or inst.RunContext == roblox.Enum.RunContext.Client
			then "client script: needs a client (Players.LocalPlayer, PlayerGui), which a headless server does not have"
			else "not started by the harness"
		table.insert(auditLines, `NOT-RUN {inst.ClassName} {inst:GetFullName()} ({why})`)
	end
	fs.writeFile(`{args.out}/audit.txt`, table.concat(auditLines, "\n") .. "\n")
end

-- Console summary -----------------------------------------------------------------------------------------------------
print("")
print(string.rep("=", 100))
if summary then
	print(string.format("[harness] Runner summary: pass=%d fail=%d pending=%d  (%d cases, %.1f s)",
		summary.pass, summary.fail, summary.pending, #results, elapsed))
else
	print(colored("red", "[harness] the Runner produced no SUMMARY line"))
end
if #knownFailures > 0 then
	print(`[harness] known failures ({#knownFailures}, see tools/lune/expectations.luau):`)
	for _, l in knownFailures do
		print("  " .. l)
	end
end
if #fixed > 0 then
	print(colored("yellow", `[harness] listed as failing but passed ({#fixed}) — update tools/lune/expectations.luau:`))
	for _, l in fixed do
		print("  " .. l)
	end
end
if #missingExpectations > 0 then
	print(colored("yellow", `[harness] expectations naming cases that did not run ({#missingExpectations}):`))
	for _, l in missingExpectations do
		print("  " .. l)
	end
end
if #unexpected > 0 then
	print(colored("red", `[harness] unexpected failures ({#unexpected}):`))
	for _, l in unexpected do
		print("  " .. l)
	end
end
if args.audit then
	print(`[harness] audit: {auditLines[1]} (details in {args.out}/audit.txt)`)
	for i = 2, #auditLines do
		local tag = string.match(auditLines[i], "^(%S+)")
		if tag == "LOAD-FAIL" or tag == "BOOT" or tag == "BOOT-FAIL" then
			print("  " .. auditLines[i])
		end
	end
end
if longest.seconds > 0 then
	print(string.format("[harness] longest stretch a script ran without yielding: %.2f s (yield at %s, after \"%s\")",
		longest.seconds, longest.at or "?", string.sub(longest.after or "", 1, 120)))
end

local passed = summary ~= nil and #unexpected == 0 and #fixed == 0 and #missingExpectations == 0
print(if passed then colored("green", "[harness] OK: every outcome matches expectations") else colored("red", "[harness] FAILED"))
print(string.rep("=", 100))

-- GitHub Actions annotations and job summary ------------------------------------------------------------------------
if isCI then
	for _, r in results do
		if r.status == "fail" then
			local e = expected[key(r.spec, r.name)]
			local level = if e then "warning" else "error"
			local title = `{r.spec} :: {r.name}`
			local first = string.split(r.message or "", "\n")[1]
			local msg = if e then `known {e.kind}: {e.why} — {first}` else first
			print(`::{level} title={string.gsub(title, "[\r\n:,]", " ")}::{string.gsub(msg, "[\r\n%%]", " ")}`)
		end
	end
	local summaryFile = process.env.GITHUB_STEP_SUMMARY
	if summaryFile then
		local md = { "## Kallskar headless tests", "" }
		if summary then
			table.insert(md, `**pass {summary.pass} · fail {summary.fail} · pending {summary.pending}** in {string.format("%.1f", elapsed)} s`)
		end
		table.insert(md, "")
		table.insert(md, "| Spec | Case | Result |")
		table.insert(md, "|---|---|---|")
		for _, r in results do
			if r.status ~= "pass" then
				local e = expected[key(r.spec, r.name)]
				local label = if r.status == "pending" then "pending" elseif e then `known {e.kind}` else "**unexpected failure**"
				table.insert(md, `| {r.spec} | {string.gsub(r.name, "|", "\\|")} | {label} |`)
			end
		end
		local existing = if fs.isFile(summaryFile) then fs.readFile(summaryFile) else ""
		fs.writeFile(summaryFile, existing .. table.concat(md, "\n") .. "\n")
	end
end

process.exit(if passed then 0 else 1)
