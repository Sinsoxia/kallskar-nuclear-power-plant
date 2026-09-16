--!strict
--[[
	Provenance
	==========
	Every number in Config must say where it came from. Aqua's rule: no guesswork.

	Declare each value with one of these constructors:

		spec(value, "§3.1")                          from the design spec
		tuning(value, "§4.5")                        from the spec, marked † (expected to change in playtesting)
		cited(value, "Carbajo et al. 2001, eq. 5")   from a real plant or a published source
		derived(value, "tools/derive/x.py")          reproducible calculation checked into the repo
		engineering(value, "why")                    software parameter, not plant physics
		decision(value, "D-004")                     design decision recorded in docs/DECISIONS.md

	`build(name, tree)` turns the declared tree into plain values (fast to read, no metatables) and records a
	provenance entry for every declared path. A bare number anywhere in the tree is a load-time error, so an
	untraceable value cannot ship. A constructor can wrap a whole table; every number inside inherits its entry.

	The constructors are typed as returning their input, so `typeof(require(Config.Kinetics))` has the right shape
	for --!strict users even though the runtime value is a box until `build` unwraps it.
]]

export type Kind = "spec" | "cited" | "derived" | "engineering" | "decision"

export type Entry = {
	kind: Kind,
	ref: string,
	tuning: boolean,
}

local MARK = {} -- private sentinel: only boxes made here carry it

type Box = {
	value: any,
	kind: Kind,
	ref: string,
	tuning: boolean,
}

local function isBox(x: any): boolean
	return type(x) == "table" and rawget(x, MARK) == true
end

local function box(kind: Kind, value: any, ref: string, tuningFlag: boolean): any
	if type(ref) ~= "string" or #ref == 0 then
		error(`provenance ref must be a non-empty string (got {typeof(ref)})`, 3)
	end
	if value == nil then
		error(`provenance constructor '{kind}' was given nil (ref {ref})`, 3)
	end
	if isBox(value) then
		error(`nested provenance box (ref {ref})`, 3)
	end
	local b = { value = value, kind = kind, ref = ref, tuning = tuningFlag }
	rawset(b, MARK, true)
	return b
end

local Provenance = {}

function Provenance.spec<T>(value: T, ref: string): T
	return box("spec", value, ref, false)
end

function Provenance.tuning<T>(value: T, ref: string): T
	return box("spec", value, ref, true)
end

function Provenance.cited<T>(value: T, ref: string): T
	return box("cited", value, ref, false)
end

function Provenance.derived<T>(value: T, ref: string): T
	return box("derived", value, ref, false)
end

function Provenance.engineering<T>(value: T, ref: string): T
	return box("engineering", value, ref, false)
end

function Provenance.decision<T>(value: T, ref: string): T
	return box("decision", value, ref, false)
end

-- Copy a boxed payload into a plain table, rejecting anything that isn't data.
local function copyPayload(v: any, path: string): any
	local t = type(v)
	if t == "number" then
		if v ~= v then
			error(`Config {path}: NaN`, 0)
		end
		return v
	elseif t == "string" or t == "boolean" then
		return v
	elseif t == "table" then
		if isBox(v) then
			error(`Config {path}: nested provenance box`, 0)
		end
		local out = {}
		for k, child in v do
			out[k] = copyPayload(child, `{path}.{tostring(k)}`)
		end
		return out
	end
	error(`Config {path}: unsupported value type '{t}' (Config holds data only)`, 0)
end

local function unwrap(node: any, path: string, prov: { [string]: Entry }): any
	local out = {}
	for k, v in node do
		local p = `{path}.{tostring(k)}`
		if isBox(v) then
			out[k] = copyPayload(v.value, p)
			prov[p] = table.freeze({ kind = v.kind, ref = v.ref, tuning = v.tuning })
		elseif type(v) == "number" then
			error(`Config {p}: bare number {v} has no provenance (wrap it in spec/cited/derived/engineering/decision)`, 0)
		elseif type(v) == "table" then
			out[k] = unwrap(v, p, prov)
		elseif type(v) == "string" or type(v) == "boolean" then
			out[k] = v
		else
			error(`Config {p}: unsupported value type '{type(v)}' (Config holds data only)`, 0)
		end
	end
	return out
end

local function deepFreeze(t: any): any
	if type(t) ~= "table" or table.isfrozen(t) then
		return t
	end
	for _, v in t do
		deepFreeze(v)
	end
	return table.freeze(t)
end

--[[
	Unwrap one declared module into plain data. `prov` collects entries keyed by "Name.path.to.value".
]]
function Provenance.build<T>(name: string, tree: T, prov: { [string]: Entry }): T
	return unwrap(tree, name, prov)
end

Provenance.deepFreeze = deepFreeze

--[[
	Look up the provenance entry that covers `path`. A boxed table covers every path beneath it, so walk up
	until an entry is found. Returns nil if nothing covers the path.
]]
function Provenance.lookup(prov: { [string]: Entry }, path: string): Entry?
	local p: string? = path
	while p do
		local e = prov[p]
		if e then
			return e
		end
		p = string.match(p, "^(.*)%.[^%.]+$")
	end
	return nil
end

return Provenance
