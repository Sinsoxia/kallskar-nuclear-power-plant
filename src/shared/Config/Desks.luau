--!strict
-- Which desk carries each control. Spec §10.1 (rooms and their desks), §10.2 (desk contents), D-054.
local P = require(script.Parent.Provenance)
local spec = P.spec

--[[
	A desk is named for its room and its §10.2 desk, and a panel for its desk and a number: MCR-RO-1 is a panel of
	the reactor operator's desk in the main control room. Commands.panelHosts reads this map until panels are built
	as instances, when the desk becomes an attribute on each panel (D-054).
]]
return {
	controls = spec({
		-- Reactor (RO): RR 1–3, shim rod or bank select, rod mode, the ECP calculator with its 1/M plot, trip buttons
		["rod.move"] = { "MCR-RO" },
		["rod.bank"] = { "MCR-RO" },
		["rod.stop"] = { "MCR-RO" },
		["rod.reset"] = { "MCR-RO" },
		["rod.runback"] = { "MCR-RO" },
		["auto.rod"] = { "MCR-RO" },
		["ni.reference"] = { "MCR-RO" },
		["runback.start"] = { "MCR-RO" },
		["runback.clear"] = { "MCR-RO" },
		["reactor.trip.reset"] = { "MCR-RO" },
		-- the trip bypasses sit with the trips; the shift supervisor's authorisation joins them with the desks (D-055)
		["pss.bypass"] = { "MCR-RO" },
		-- the trip buttons are also on the backup control room's emergency shutdown panel (§10.1); `buttons` says which
		["reactor.trip.manual"] = { "MCR-RO", "BCR-ESP" },
		["sss.trip.manual"] = { "MCR-RO", "BCR-ESP" },
		-- Primary (PO): PP1–3 start, stop, speed and mode; pony motors; IHX shutters ×6; cover gas admit and vent
		["pump.start"] = { "MCR-PO" },
		["pump.stop"] = { "MCR-PO" },
		["pump.speed"] = { "MCR-PO" },
		["pump.pony"] = { "MCR-PO", "BCR-ESP" }, -- §10.2 also puts the pony motors in the backup control room
		["auto.flow"] = { "MCR-PO" },
		["ihx.shutter"] = { "MCR-PO" },
		["covergas.auto"] = { "MCR-PO" },
		["covergas.valve"] = { "MCR-PO" },
		-- Shift supervisor (SS): the mode key and the plant load master
		["plant.mode.change"] = { "MCR-SS" },
		["sink.load"] = { "MCR-SS" },
		-- Secondary sodium (SSO), in the steam generator control room: SP1–3 and the loops
		["loop.start"] = { "SGCR-SSO" },
		["loop.stop"] = { "SGCR-SSO" },
		["loop.secondary.inlet"] = { "SGCR-SSO" },
		["loop.secondary.flow"] = { "SGCR-SSO" },
		["loop.secondary.program"] = { "SGCR-SSO" },
	}, "§10.2 desk contents, §10.1 rooms (D-054)"),

	-- The manual trip buttons by target: the MCR's two on the reactor desk (D-056), the BCR's one in the BCR (§9.5)
	buttons = spec({
		["MCR-1"] = "MCR-RO",
		["MCR-2"] = "MCR-RO",
		["BCR"] = "BCR-ESP",
	}, "§9.5, §10.2 (D-054, D-056)"),
}
