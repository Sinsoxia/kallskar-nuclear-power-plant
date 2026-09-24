--!strict
--[[
	Commands — the single path by which anything changes plant state (spec §10.6 build rule, §10.7, §14.4).
	========================================================================================================

	submit(actor, raw) does, in order:
	  1. rate limit — token bucket per player (Engineering.commandRate_perSecond / commandBurst), before any other work
	  2. sanitise   — copy the client's table into a fresh Command, rejecting wrong types, oversized strings, NaN/inf
	  3. route      — the system that declared this command kind (Registry), or refuse
	  4. access     — players only: on a panel of a desk that carries the control (Config.Desks, §10.2, D-054),
	                  within reach of it (Access.panelReach_studs) and, for critical controls, the minimum total
	                  playtime (Access.criticalMinimumPlaytime_h)
	  5. apply      — system:applyCommand(actor, cmd)
	  6. log        — every control attempt that reaches a system's desk, accepted or refused, goes to the EventLog
	                  with the actor's name (§10.7). A player's commands refused before that (throttled, malformed,
	                  or of a kind no system handles) are not control actions: they are counted, and the count is
	                  noted at most once per Engineering.commandRefusalNote_s. The rate limit bounds the rest, so a
	                  player adds at most commandRate_perSecond + 1 / commandRefusalNote_s records a second (plus
	                  up to commandBurst after a quiet spell), and one who sends only refused commands adds
	                  1 / commandRefusalNote_s

	Actors of kind "auto" and "scenario" are server-internal and skip reach/playtime. "dev" actors come only from the
	debug panel, which is Studio only (D-052, devGate), and skip reach (there are no physical panels yet in M1).

	Pluggable services (so tests and later milestones can swap them):
	  panelPosition(panelTag) -> Vector3?      where the control panel is (nil = unknown panel)
	  panelHosts(panel, kind, target) -> bool  whether that panel's desk carries the control: by default Config.Desks,
	                                           with the desk read from the tag (desk-n), until panels are instances
	  characterPosition(player) -> Vector3?    where the player is standing
	  playtimeHours(player) -> number?         total playtime; nil when the lookup failed
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Kallskar"):WaitForChild("Types"))

type Actor = Types.Actor
type Command = Types.Command
type CommandResult = Types.CommandResult

local Commands = {}
Commands.__index = Commands

local NAME_PATTERN = "^[%w%.%-_]+$"

local function isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

--[[
	Turn untrusted client input into a Command. Returns (command, nil) or (nil, reason).
]]
function Commands.sanitize(raw: any, limits: { stringMax: number, argsMax: number }): (Command?, string?)
	if type(raw) ~= "table" then
		return nil, "command must be a table"
	end
	local function name(v: any, field: string, required: boolean): (string?, string?)
		if v == nil then
			return nil, if required then `{field} is required` else nil
		end
		if type(v) ~= "string" or #v == 0 or #v > limits.stringMax or not string.match(v, NAME_PATTERN) then
			return nil, `{field} must be 1–{limits.stringMax} characters of letters, digits, '.', '-' or '_'`
		end
		return v, nil
	end
	local kind, e1 = name(raw.kind, "kind", true)
	if e1 then
		return nil, e1
	end
	local target, e2 = name(raw.target, "target", false)
	if e2 then
		return nil, e2
	end
	local panel, e3 = name(raw.panel, "panel", false)
	if e3 then
		return nil, e3
	end
	local value = raw.value
	if value ~= nil and not isFiniteNumber(value) then
		return nil, "value must be a finite number"
	end
	local args = nil
	if raw.args ~= nil then
		if type(raw.args) ~= "table" then
			return nil, "args must be a table"
		end
		args = {}
		local n = 0
		for k, v in raw.args do
			n += 1
			if n > limits.argsMax then
				return nil, `at most {limits.argsMax} args`
			end
			if type(k) ~= "string" or #k == 0 or #k > 32 or not string.match(k, "^[%a][%w_]*$") then
				return nil, "arg names must be identifiers of at most 32 characters"
			end
			local t = type(v)
			if t == "number" then
				if not isFiniteNumber(v) then
					return nil, `arg '{k}' must be finite`
				end
			elseif t == "string" then
				if #v > limits.stringMax then
					return nil, `arg '{k}' is too long`
				end
			elseif t ~= "boolean" then
				return nil, `arg '{k}' must be a number, string or boolean`
			end
			args[k] = v
		end
	end
	return { kind = kind :: string, target = target, panel = panel, value = value, args = args }, nil
end

--[[
	Decide whether a player may operate a critical control (§10.7: minimum total playtime).
	`hours` is nil when the playtime lookup failed (for example a DataStore outage).
	Returns (allowed, reason-if-refused).
]]
function Commands.criticalAccess(hours: number?, requiredHours: number): (boolean, string?)
	if hours ~= nil then
		if hours >= requiredHours then
			return true, nil
		end
		return false, string.format("needs %.1f h total playtime (you have %.1f h)", requiredHours, hours)
	end
	-- TODO(human): the playtime lookup failed. Decide the policy and return (allowed, reason).
	error("TODO(human): criticalAccess policy for a failed playtime lookup is not decided yet")
end

function Commands.new(opts: {
	config: any,
	registry: any,
	log: any,
	bus: any?,
	panelPosition: ((string) -> Vector3?)?,
	panelHosts: ((string, string, string?) -> boolean)?,
	characterPosition: ((Player) -> Vector3?)?,
	playtimeHours: ((Player) -> number?)?,
	now: (() -> number)?,
})
	local self = setmetatable({}, Commands)
	local eng = opts.config.Engineering
	local access = opts.config.Access
	self.registry = opts.registry
	self.log = opts.log
	self.bus = opts.bus
	self.limits = { stringMax = eng.commandStringMax, argsMax = eng.commandArgsMax }
	self.rate = eng.commandRate_perSecond
	self.burst = eng.commandBurst
	self.noteEvery = eng.commandRefusalNote_s
	self.reach = access.panelReach_studs
	self.requiredHours = access.criticalMinimumPlaytime_h
	self.critical = {} :: { [string]: boolean }
	for _, kind in access.criticalControls do
		self.critical[kind] = true
	end
	self.panelPosition = opts.panelPosition or function(_tag: string): Vector3?
		return nil
	end
	local desks = opts.config.Desks
	self.panelHosts = opts.panelHosts or function(panel: string, kind: string, target: string?): boolean
		local desk = string.match(panel, "^(.-)%-%d+$")
		local button = if target then desks.buttons[target] else nil
		if kind == "reactor.trip.manual" and button then
			return desk == button -- a trip button is on one desk, the MCR's or the BCR's
		end
		local carriers = desks.controls[kind] or desks.placed[kind]
		return desk ~= nil and carriers ~= nil and table.find(carriers, desk) ~= nil
	end
	self.characterPosition = opts.characterPosition or function(player: Player): Vector3?
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return if root and root:IsA("BasePart") then root.Position else nil
	end
	self.playtimeHours = opts.playtimeHours or function(_player: Player): number?
		return nil
	end
	self.now = opts.now or os.clock
	self.buckets = {} :: { [number]: { tokens: number, t: number, refused: number, why: string, noted: number } }
	return self
end

function Commands.isCritical(self: any, kind: string): boolean
	return self.critical[kind] == true
end

local function takeToken(self: any, userId: number): boolean
	local now = self.now()
	local b = self.buckets[userId]
	if not b then
		b = { tokens = self.burst, t = now, refused = 0, why = "", noted = -math.huge }
		self.buckets[userId] = b
	end
	b.tokens = math.min(self.burst, b.tokens + (now - b.t) * self.rate)
	b.t = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

local THROTTLED = "too many commands; slow down"

--[[
	A command refused before it reaches a system (throttled, malformed, or of a kind nothing handles) costs its sender
	nothing and operates nothing, so it must cost the log nothing either. Logged one by one, a flood would overwrite
	the sequence-of-events ring and the eventLogPersisted entries the save keeps (and with them §10.7's record of who did what), and
	the Replicator would send every record to every player. So a player's are counted, and the count is written at
	most once per commandRefusalNote_s, with the latest reason. Only the rate-limited control attempts are then
	logged one by one, which bounds a player at commandRate_perSecond + 1 / commandRefusalNote_s records a second.
]]
local function noteRefused(self: any, actor: Actor, why: string)
	local b = self.buckets[actor.userId]
	b.refused += 1
	b.why = why
	local now = self.now()
	if now - b.noted >= self.noteEvery then
		self.log:record("command.refused", actor, nil, `{b.refused} commands refused before routing since the last note`, `denied: {why}`)
		b.refused, b.noted = 0, now
	end
end

local function checkPlayerAccess(self: any, actor: Actor, cmd: Command): (boolean, string?)
	local player = actor.player
	if not player then
		return false, "player actor without a Player"
	end
	if not cmd.panel then
		return false, "control has no panel"
	end
	local panelPos = self.panelPosition(cmd.panel)
	if not panelPos then
		return false, `unknown panel '{cmd.panel}'`
	end
	if not self.panelHosts(cmd.panel, cmd.kind, cmd.target) then
		return false, `{cmd.kind}{if cmd.target then " " .. cmd.target else ""} is not on the desk of panel '{cmd.panel}'`
	end
	local pos = self.characterPosition(player)
	if not pos then
		return false, "no character"
	end
	local distance = (pos - panelPos).Magnitude
	if distance > self.reach then
		return false, string.format("out of reach (%.1f studs, limit %d)", distance, self.reach)
	end
	if self.critical[cmd.kind] then
		return Commands.criticalAccess(self.playtimeHours(player), self.requiredHours)
	end
	return true, nil
end

function Commands.submit(self: any, actor: Actor, raw: any): CommandResult
	if actor.kind == "player" or actor.kind == "dev" then
		if not takeToken(self, actor.userId) then
			noteRefused(self, actor, THROTTLED)
			return { ok = false, reason = THROTTLED }
		end
	end
	local cmd, why = Commands.sanitize(raw, self.limits)
	-- every client is sent the log, so a refused command's kind goes in only if it is a plain name
	local kindForLog = if cmd then cmd.kind
		elseif type(raw) == "table" and type(raw.kind) == "string" and string.match(raw.kind, NAME_PATTERN) then string.sub(raw.kind, 1, 64)
		else "?"
	local function refuse(reason: string): CommandResult
		self.log:record(kindForLog, actor, if cmd then cmd.target else nil, nil, `denied: {reason}`)
		return { ok = false, reason = reason }
	end
	-- refused before routing: a player's are counted into the note, a server actor's logged as they come
	local function refuseUnrouted(reason: string): CommandResult
		if actor.kind == "player" or actor.kind == "dev" then
			noteRefused(self, actor, reason)
			return { ok = false, reason = reason }
		end
		return refuse(reason)
	end
	if not cmd then
		return refuseUnrouted(why :: string)
	end
	local owner = self.registry:ownerOfCommand(cmd.kind)
	if not owner then
		return refuseUnrouted(`no system handles '{cmd.kind}'`)
	end
	if actor.kind == "player" then
		local ok, reason = checkPlayerAccess(self, actor, cmd)
		if not ok then
			return refuse(reason or "access denied")
		end
	end
	local result = owner:applyCommand(actor, cmd)
	local detail = if cmd.value ~= nil then tostring(cmd.value) else nil
	self.log:record(cmd.kind, actor, cmd.target, detail, if result.ok then "ok" else `denied: {result.reason or "refused"}`)
	if self.bus then
		self.bus:publish("CommandApplied", { actor = actor.name, kind = cmd.kind, target = cmd.target, result = result })
	end
	return result
end

--[[
	Who may send dev-panel commands (args.dev == true): everyone in Studio, and nobody on a live server (D-052). The
	place's creator and a private server's owner are ordinary players there. The owner's one extra power is the
	§14.6 reset, which Persistence.requestReset checks for itself, and neither gets any exemption from the panel
	reach or the critical-control playtime.
]]
function Commands.devGate(place: { isStudio: boolean }): (Player) -> boolean
	local isStudio = place.isStudio
	return function(_player: Player): boolean
		return isStudio
	end
end

--[[
	Hook a RemoteFunction up to submit(). isDev(player) decides who may send dev-panel commands
	(args.dev == true); everyone else is a normal player actor.
]]
function Commands.bindRemote(self: any, remote: RemoteFunction, isDev: (Player) -> boolean)
	remote.OnServerInvoke = function(player: Player, raw: any)
		local kind: Types.ActorKind = "player"
		if type(raw) == "table" and type(raw.args) == "table" and raw.args.dev == true then
			if not isDev(player) then
				return { ok = false, reason = "dev controls are not available to you" }
			end
			kind = "dev"
		end
		local actor: Actor = { kind = kind, name = player.Name, userId = player.UserId, player = player }
		local ok, result = pcall(self.submit, self, actor, raw)
		if not ok then
			warn(`[Kallskar] command from {player.Name} failed internally: {tostring(result)}`)
			return { ok = false, reason = "internal error" }
		end
		return result
	end
end

--[[
	Drop a player's bucket when they leave (Main, PlayerRemoving), so the table does not grow with everyone who has
	ever joined the server. Refused commands not yet noted are noted now.
]]
function Commands.forget(self: any, actor: Actor)
	local b = self.buckets[actor.userId]
	if b and b.refused > 0 then
		self.log:record("command.refused", actor, nil, `{b.refused} commands refused before routing since the last note`,
			`denied: {b.why}`)
	end
	self.buckets[actor.userId] = nil
end

return Commands
