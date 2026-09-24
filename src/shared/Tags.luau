--!strict
--[[
	Instrument and equipment tags. Spec Appendix B.
	Format SYS-L-TYPE-NN, e.g. SG-2-HM-05 = loop 2, section 5 hydrogen meter. The tag is the Roblox instance name
	and the replication key. L is a loop/train/division number, or 0 for plant-wide equipment.
]]

local SYSTEMS = table.freeze({
	RX = "core",
	PN = "primary sodium",
	SN = "secondary sodium",
	SG = "steam generators",
	MS = "main steam",
	TG = "turbine-generator",
	CD = "condensate",
	FW = "feedwater",
	CW = "cooling water",
	EL = "electrical",
	DG = "diesels",
	DR = "DRACS",
	NS = "sodium services",
	CH = "chemistry",
	PR = "protection",
})

local TYPES = table.freeze({
	P = "pump",
	CV = "control valve",
	IV = "isolation valve",
	NRV = "check valve",
	T = "temperature",
	PT = "pressure",
	F = "flow",
	L = "level",
	HM = "hydrogen meter",
	TC = "thermocouple",
	SPD = "speed",
	RD = "rod",
	-- Additions for M1 instruments not in the Appendix B list. Kept short and unambiguous.
	N = "neutron flux", -- SR / WR / PR channels
	PER = "reactor period",
	RHO = "reactivity",
	DND = "delayed neutron detector",
	POS = "position",
	PQ = "power-to-flow ratio",
})

export type Tag = {
	system: string,
	loop: number,
	kind: string,
	index: number,
}

local Tags = {}
Tags.SYSTEMS = SYSTEMS
Tags.TYPES = TYPES

function Tags.format(system: string, loop: number, kind: string, index: number): string
	assert(SYSTEMS[system], `unknown tag system '{system}'`)
	assert(TYPES[kind], `unknown tag type '{kind}'`)
	assert(loop >= 0 and loop <= 9 and loop % 1 == 0, "tag loop must be an integer 0–9")
	assert(index >= 0 and index <= 999 and index % 1 == 0, "tag index must be an integer 0–999")
	return string.format("%s-%d-%s-%02d", system, loop, kind, index)
end

function Tags.parse(tag: string): Tag?
	local sys, loopStr, kind, idxStr = string.match(tag, "^(%u%u)%-(%d)%-(%u+)%-(%d%d%d?)$")
	if not sys or not SYSTEMS[sys] or not TYPES[kind :: string] then
		return nil
	end
	local loop = tonumber(loopStr) :: number
	local idx = tonumber(idxStr) :: number

	if Tags.format(sys :: string, loop, kind :: string, idx) ~= tag then
		return nil
	end

	return { system = sys :: string, loop = loop, kind = kind :: string, index = idx }
end

function Tags.isValid(tag: string): boolean
	return Tags.parse(tag) ~= nil
end

return table.freeze(Tags)
