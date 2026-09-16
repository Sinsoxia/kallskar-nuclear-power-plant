--!strict
-- Shared type definitions for the Kallskar simulation framework (spec §14.7 system contract).

export type Lane = "fast" | "slow"

--[[
	What a system declares about itself. The Registry uses reads/writes to order systems within a lane so that
	writers run before readers. A physical feedback loop (power → fuel temperature → Doppler → power) must be
	broken explicitly by listing the back-edge in `readsLagged`: those channels are read as last tick's value and
	don't constrain ordering. An undeclared cycle is a startup error.
]]
export type SystemSpec = {
	name: string,
	lane: Lane,
	reads: { string },
	readsLagged: { string }?,
	writes: { string },
}

-- Who issued a command. Players, automatic controllers, scenarios and dev tools all go through the same path.
export type ActorKind = "player" | "auto" | "scenario" | "dev"

export type Actor = {
	kind: ActorKind,
	name: string,
	userId: number,
	player: Player?,
}

export type Command = {
	kind: string, -- e.g. "rod.move", "pump.speed", "reactor.trip.manual"
	target: string?, -- SYS-L-TYPE-NN tag or a system-local id
	value: number?,
	args: { [string]: any }?,
	panel: string?, -- tag of the panel the control sits on (reach check)
}

export type CommandResult = {
	ok: boolean,
	reason: string?,
}

--[[
	A failure a system can be made to have. The scenario director (later milestone) picks from these; dev tools can
	arm them directly. `eligible` receives a read-only plant snapshot; `arm` starts a real initiating event inside
	the system (spec §13.1: the director never cheats).
]]
export type FaultSpec = {
	id: string,
	label: string,
	cost: number, -- 1 minor, 3 moderate, 8 major (§13.1)
	eligible: ((snapshot: any) -> boolean)?,
	arm: (sys: any, params: { [string]: any }?) -> (),
	clear: ((sys: any) -> ())?,
}

export type EventRecord = {
	seq: number,
	realTime: number, -- os.time() when recorded
	simTime: number, -- seconds of physics time since start
	gridTime: number, -- grid-clock seconds (×12)
	actor: string,
	actorKind: ActorKind | "system",
	kind: string,
	target: string?,
	detail: string?,
	result: string, -- "ok", "denied: <reason>", "info", ...
}

export type Clock = {
	sim: number,
	grid: number,
	slow: number,
	fastTicks: number,
	rate: number,
}

return nil
