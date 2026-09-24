--!strict
--[[
	Checks instrument and equipment tags against spec Appendix B (KALLSKAR_ALL_IN_ONE.txt L2926).
	Validates that Appendix B systems and types are present, exact extended types are known,
	formatting/parsing logic is correct, and parsing respects canonical spelling for instance names.
]]
local Kallskar = game:GetService("ReplicatedStorage"):WaitForChild("Kallskar")
local Tags = require((Kallskar :: any).Tags)

-- Appendix B (KALLSKAR_ALL_IN_ONE.txt L2926)
-- "RX core; PN primary sodium; SN secondary sodium; SG steam generators; MS main steam; TG turbine-generator; CD condensate; FW feedwater; CW cooling water; EL electrical; DG diesels; DR DRACS; NS sodium services; CH chemistry; PR protection"
local APPENDIX_B_SYSTEMS = {
	{ code = "RX", meaning = "core" },
	{ code = "PN", meaning = "primary sodium" },
	{ code = "SN", meaning = "secondary sodium" },
	{ code = "SG", meaning = "steam generators" },
	{ code = "MS", meaning = "main steam" },
	{ code = "TG", meaning = "turbine-generator" },
	{ code = "CD", meaning = "condensate" },
	{ code = "FW", meaning = "feedwater" },
	{ code = "CW", meaning = "cooling water" },
	{ code = "EL", meaning = "electrical" },
	{ code = "DG", meaning = "diesels" },
	{ code = "DR", meaning = "DRACS" },
	{ code = "NS", meaning = "sodium services" },
	{ code = "CH", meaning = "chemistry" },
	{ code = "PR", meaning = "protection" },
}

-- "    P pump; CV control valve; IV isolation valve; NRV check valve; T temperature; PT pressure; F"
-- "    flow; L level; HM hydrogen meter; TC thermocouple; SPD speed; RD rod"
local APPENDIX_B_TYPES = {
	{ code = "P", meaning = "pump" },
	{ code = "CV", meaning = "control valve" },
	{ code = "IV", meaning = "isolation valve" },
	{ code = "NRV", meaning = "check valve" },
	{ code = "T", meaning = "temperature" },
	{ code = "PT", meaning = "pressure" },
	{ code = "F", meaning = "flow" },
	{ code = "L", meaning = "level" },
	{ code = "HM", meaning = "hydrogen meter" },
	{ code = "TC", meaning = "thermocouple" },
	{ code = "SPD", meaning = "speed" },
	{ code = "RD", meaning = "rod" },
}

-- The M1 instrument codes D-058 adds to Appendix B's list; another code needs a decision of its own
local KNOWN_EXTENDED_TYPES = {
	N = true,
	PER = true,
	RHO = true,
	DND = true,
	POS = true,
	PQ = true,
}

return {
	["Appendix B systems are present and correct"] = function(t)
		for _, sys in APPENDIX_B_SYSTEMS do
			t.ok(Tags.SYSTEMS[sys.code], `Missing system code {sys.code} (Appendix B)`)
			t.eq(Tags.SYSTEMS[sys.code], sys.meaning, `System {sys.code} has wrong meaning`)
		end
	end,

	["Appendix B types are present and correct"] = function(t)
		for _, typ in APPENDIX_B_TYPES do
			t.ok(Tags.TYPES[typ.code], `Missing type code {typ.code} (Appendix B)`)
			t.eq(Tags.TYPES[typ.code], typ.meaning, `Type {typ.code} has wrong meaning`)
		end
	end,

	["exact set of extension codes is known (D-058)"] = function(t)
		local appBTypes = {}
		for _, typ in APPENDIX_B_TYPES do
			appBTypes[typ.code] = true
		end

		for code, _ in Tags.TYPES do
			if not appBTypes[code] then
				t.ok(KNOWN_EXTENDED_TYPES[code], `Unexpected extended type code found: {code}`)
			end
		end

		for code, _ in KNOWN_EXTENDED_TYPES do
			t.ok(Tags.TYPES[code], `Expected extended type code not found in Tags.TYPES: {code}`)
		end
	end,

	["format, parse, isValid match spec example (SG-2-HM-05)"] = function(t)
		local formatted = Tags.format("SG", 2, "HM", 5)
		t.eq(formatted, "SG-2-HM-05", "Format does not match spec example")
		t.ok(Tags.isValid(formatted), "Should be valid")

		local parsed = Tags.parse(formatted)
		t.ok(parsed, "Failed to parse spec example")
		if parsed then
			t.eq(parsed.system, "SG", "Wrong system")
			t.eq(parsed.loop, 2, "Wrong loop")
			t.eq(parsed.kind, "HM", "Wrong kind")
			t.eq(parsed.index, 5, "Wrong index")
		end
	end,

	["round trips across every system and type (format -> parse)"] = function(t)
		for sysCode, _ in Tags.SYSTEMS do
			for typeCode, _ in Tags.TYPES do
				local formatted = Tags.format(sysCode, 1, typeCode, 10)
				t.ok(Tags.isValid(formatted), `Invalid formatted string: {formatted}`)
				local parsed = Tags.parse(formatted)
				t.ok(parsed, `Failed to parse formatted string: {formatted}`)
				if parsed then
					t.eq(parsed.system, sysCode)
					t.eq(parsed.loop, 1)
					t.eq(parsed.kind, typeCode)
					t.eq(parsed.index, 10)
				end
			end
		end
	end,

	["parse -> format round trips to reject non-canonical spelling"] = function(t)
		-- "SG-2-HM-005" and "RX-0-TC-0331" have non-canonical padding that Tags.format wouldn't produce for those indices.
		-- They must be rejected by Tags.parse because each tag needs exactly one spelling (it's the replication key).
		t.eq(Tags.parse("SG-2-HM-005"), nil, "Must reject SG-2-HM-005 (non-canonical padding)")
		t.eq(Tags.parse("RX-0-TC-0331"), nil, "Must reject RX-0-TC-0331 (non-canonical padding)")
		t.eq(Tags.parse("SG-2-HM-5"), nil, "Must reject SG-2-HM-5 (non-canonical padding)")
	end,

	["edges of loop and index ranges"] = function(t)
		-- Loop edges (0, 9)
		local L0 = Tags.format("RX", 0, "T", 0)
		t.eq(L0, "RX-0-T-00")
		local parsedL0 = Tags.parse(L0)
		t.ok(parsedL0, "L0 should parse")
		if parsedL0 then
			t.eq(parsedL0.loop, 0)
			t.eq(parsedL0.index, 0)
		end

		-- Appendix B says "NN" (2 digits); D-058 extends it to three digits from 100 to 999, for the 331-position core map.
		local L9 = Tags.format("RX", 9, "T", 999)
		t.eq(L9, "RX-9-T-999")
		local parsedL9 = Tags.parse(L9)
		t.ok(parsedL9, "L9 should parse")
		if parsedL9 then
			t.eq(parsedL9.loop, 9)
			t.eq(parsedL9.index, 999)
		end

		t.throws(function() Tags.format("RX", -1, "T", 0) end, "tag loop must be an integer 0–9")
		t.throws(function() Tags.format("RX", 10, "T", 0) end, "tag loop must be an integer 0–9")
		t.throws(function() Tags.format("RX", 0, "T", -1) end, "tag index must be an integer 0–999")
		t.throws(function() Tags.format("RX", 0, "T", 1000) end, "tag index must be an integer 0–999")
		t.throws(function() Tags.format("RX", 1.5, "T", 0) end, "tag loop must be an integer 0–9")
		t.throws(function() Tags.format("RX", 0, "T", 1.5) end, "tag index must be an integer 0–999")
	end,

	["invalid input handling for parsing"] = function(t)
		t.ok(not Tags.isValid("SG-2-HM"), "Missing index")
		t.ok(not Tags.isValid("SG-2-HM-05-XX"), "Extra parts")
		t.ok(not Tags.isValid("XX-2-HM-05"), "Unknown system")
		t.ok(not Tags.isValid("SG-2-XX-05"), "Unknown type")
		t.ok(not Tags.isValid("SG-10-HM-05"), "Loop too large (formatting)")
		t.ok(not Tags.isValid("SG-A-HM-05"), "Loop not integer")
		t.ok(not Tags.isValid("SG-2-HM-ABCD"), "Index not integer")
		t.ok(not Tags.isValid("SG-2-HM-1000"), "Index too large (formatting)")
		t.ok(not Tags.isValid("SG-2HM-05"), "Missing dash")
		t.ok(not Tags.isValid(""), "Empty string")

		-- Malformed format string shouldn't crash
		t.eq(Tags.parse("SG-2-HM"), nil)
	end,

	["property tests for validity (instance name / replication key)"] = function(t)
		-- As instance name and replication key, a tag must be unique for unique inputs,
		-- must roundtrip, and must only contain allowed characters (no spaces, control chars, etc.)
		local tag = Tags.format("SG", 2, "HM", 5)
		t.eq(string.match(tag, "^[%w%-]+$"), tag, "Tag contains invalid characters for instance names / replication keys")

		-- Note: There is an open audit finding (C-39) noting that shim rods are tagged SM in the spec's glossary,
		-- but SM is missing from the system and type lists, and hydrogen meters have no NN rule.
		-- This is for Aqua to decide, so no test assertions pin SM.
	end,
}
