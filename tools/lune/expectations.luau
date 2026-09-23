--!strict
--[[
	Known failures of the headless run. run-tests.luau fails the build on any failure NOT listed here, and on any
	case listed here that passes (so the list cannot go stale). Pending cases (t.pending) are never failures.

	Each entry says which kind of failure it is:
	  kind = "bug"      the code under test is wrong; `why` gives file:line and the failing scenario
	  kind = "harness"  the code is fine in Roblox; the headless emulation lacks something (say what)
	  kind = "host"     a timing budget the CI machine misses; not a property of the code

	Example:
		{ spec = "Perf", test = "shape step fits the §3.7/§14.2 time budget", kind = "host",
		  why = "GitHub's runner is slower than a Roblox server core" },

	As of 2026-09-23 every spec passes headless (docs/HEADLESS_TESTS.md), so the list is empty.
]]
export type Expectation = { spec: string, test: string, kind: "bug" | "harness" | "host", why: string }

return {
	failures = {} :: { Expectation },
}
