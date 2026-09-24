--!strict
-- Which desk carries each control. Spec §10.1 (rooms and their desks), §10.2 (desk contents), D-054.
local P = require(script.Parent.Provenance)
local spec, decision = P.spec, P.decision

--[[
	A desk is named for its room and its §10.2 desk, and a panel for its desk and a number: MCR-RO-1 is a panel of
	the reactor operator's desk in the main control room. Commands.panelHosts reads this map until panels are built
	as instances, when the desk becomes an attribute on each panel (D-054).
]]
return {
	-- The controls §10.2 lists, on the desks it lists them on
	controls = spec({
		-- Reactor (RO): RR 1–3, shim rod or bank select and in/out, rod mode, the ECP calculator with its 1/M plot,
		-- trip buttons
		["rod.move"] = { "MCR-RO" },
		["rod.bank"] = { "MCR-RO" },
		["rod.stop"] = { "MCR-RO" },
		["auto.rod"] = { "MCR-RO" },
		["ni.reference"] = { "MCR-RO" },
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
		-- Secondary sodium (SSO), in the steam generator control room: SP1–3, which run the loops
		["loop.start"] = { "SGCR-SSO" },
		["loop.stop"] = { "SGCR-SSO" },
		["loop.secondary.flow"] = { "SGCR-SSO" },
	}, "§10.2 desk contents, §10.1 rooms (D-054)"),

	--[[
		Controls §10.2 does not list, placed by D-054 on the desk that runs the equipment they act on. The runbacks
		and the shim drive-in move the reactor's rods; the trip reset and the rod drives' scram reset follow the
		trip buttons; a trip bypass sits with the trips, and §10.2 gives its authorisation to the shift supervisor,
		which joins it when the desks exist (D-055). The secondary loops' inlet override and its release are the M1
		heat sink's stand-ins for the steam plant, run from the loops' own desk.
	]]
	placed = decision({
		["runback.start"] = { "MCR-RO" },
		["runback.clear"] = { "MCR-RO" },
		["rod.runback"] = { "MCR-RO" },
		["reactor.trip.reset"] = { "MCR-RO" },
		["rod.reset"] = { "MCR-RO" },
		["pss.bypass"] = { "MCR-RO" },
		["loop.secondary.inlet"] = { "SGCR-SSO" },
		["loop.secondary.program"] = { "SGCR-SSO" },
	}, "D-054: controls §10.2 does not list, on the desk that runs what they act on"),

	-- The manual trip buttons by target: the MCR's two on the reactor desk (D-056), the BCR's one in the BCR (§9.5)
	buttons = spec({
		["MCR-1"] = "MCR-RO",
		["MCR-2"] = "MCR-RO",
		["BCR"] = "BCR-ESP",
	}, "§9.5, §10.2 (D-054, D-056)"),
}
