--!strict
--[[
	Packets — binary formats for replication (spec §14.1). Shared by server (pack) and client (unpack).

	Gauge packet (UnreliableRemoteEvent, 5 Hz fast / 1 Hz slow):
		u8  type = 1
		u16 manifest version   (clients drop packets for a manifest they don't have)
		u16 count
		count × { u16 gauge id, f32 value }                      6 bytes each

	Core map packet (1 Hz), spec §14.1: temperatures as u16 at Engineering.coreMapResolution_K, in kelvin with zero
	offset (0–3276.75 K):
		u8  type = 2
		u16 count (331)
		count × u16                                              2 bytes each → 662 bytes of payload
]]

local Packets = {}

Packets.GAUGES = 1
Packets.COREMAP = 2
Packets.GAUGE_HEADER = 5
Packets.GAUGE_ENTRY = 6
Packets.COREMAP_HEADER = 3

function Packets.packGauges(version: number, ids: { number }, values: { number }, first: number, last: number): buffer
	local n = last - first + 1
	assert(n >= 0 and n <= 65535, "gauge count out of range")
	local b = buffer.create(Packets.GAUGE_HEADER + n * Packets.GAUGE_ENTRY)
	buffer.writeu8(b, 0, Packets.GAUGES)
	buffer.writeu16(b, 1, version)
	buffer.writeu16(b, 3, n)
	local off = Packets.GAUGE_HEADER
	for i = first, last do
		buffer.writeu16(b, off, ids[i])
		buffer.writef32(b, off + 2, values[i])
		off += Packets.GAUGE_ENTRY
	end
	return b
end

-- Split a gauge list into packets no larger than budgetBytes.
function Packets.chunkGauges(version: number, ids: { number }, values: { number }, budgetBytes: number): { buffer }
	local per = math.floor((budgetBytes - Packets.GAUGE_HEADER) / Packets.GAUGE_ENTRY)
	assert(per >= 1, "packet budget too small for one gauge")
	local out = {}
	local i = 1
	while i <= #ids do
		local last = math.min(#ids, i + per - 1)
		table.insert(out, Packets.packGauges(version, ids, values, i, last))
		i = last + 1
	end
	return out
end

function Packets.unpackGauges(b: buffer): (number, { number }, { number })
	assert(buffer.readu8(b, 0) == Packets.GAUGES, "not a gauge packet")
	local version = buffer.readu16(b, 1)
	local n = buffer.readu16(b, 3)
	assert(buffer.len(b) == Packets.GAUGE_HEADER + n * Packets.GAUGE_ENTRY, "gauge packet length mismatch")
	local ids, values = table.create(n), table.create(n)
	local off = Packets.GAUGE_HEADER
	for i = 1, n do
		ids[i] = buffer.readu16(b, off)
		values[i] = buffer.readf32(b, off + 2)
		off += Packets.GAUGE_ENTRY
	end
	return version, ids, values
end

function Packets.packCoreMap(temps_K: { number }, resolution_K: number): buffer
	local n = #temps_K
	local b = buffer.create(Packets.COREMAP_HEADER + n * 2)
	buffer.writeu8(b, 0, Packets.COREMAP)
	buffer.writeu16(b, 1, n)
	local off = Packets.COREMAP_HEADER
	for i = 1, n do
		local q = math.floor(temps_K[i] / resolution_K + 0.5)
		buffer.writeu16(b, off, math.clamp(q, 0, 65535))
		off += 2
	end
	return b
end

function Packets.unpackCoreMap(b: buffer, resolution_K: number): { number }
	assert(buffer.readu8(b, 0) == Packets.COREMAP, "not a core map packet")
	local n = buffer.readu16(b, 1)
	assert(buffer.len(b) == Packets.COREMAP_HEADER + n * 2, "core map packet length mismatch")
	local out = table.create(n)
	local off = Packets.COREMAP_HEADER
	for i = 1, n do
		out[i] = buffer.readu16(b, off) * resolution_K
		off += 2
	end
	return out
end

return table.freeze(Packets)
