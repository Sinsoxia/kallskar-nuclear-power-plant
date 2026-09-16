--!strict
--[[
	Remotes — the network endpoints. Created at runtime by the server in ReplicatedStorage.KallskarRemotes (outside the
	Rojo-managed Kallskar folder, so syncing never fights with runtime instances). Clients wait for them.

	Command   RemoteFunction          client → server control actions (Framework/Commands)
	Manifest  RemoteEvent             server → client gauge tag list and version
	Gauges    UnreliableRemoteEvent   server → client gauge and core-map packets (Net/Packets)
	Events    RemoteEvent             server → client sequence-of-events records and alarms
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FOLDER = "KallskarRemotes"
local SPEC = table.freeze({
	Command = "RemoteFunction",
	Manifest = "RemoteEvent",
	Gauges = "UnreliableRemoteEvent",
	Events = "RemoteEvent",
})

export type Set = {
	Command: RemoteFunction,
	Manifest: RemoteEvent,
	Gauges: UnreliableRemoteEvent,
	Events: RemoteEvent,
}

local Remotes = {}
Remotes.FOLDER = FOLDER
Remotes.SPEC = SPEC

function Remotes.server(): Set
	local folder = ReplicatedStorage:FindFirstChild(FOLDER)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = FOLDER
		folder.Parent = ReplicatedStorage
	end
	local set = {}
	for name, className in SPEC do
		local r = (folder :: Instance):FindFirstChild(name)
		if not r then
			r = Instance.new(className)
			r.Name = name
			r.Parent = folder
		end
		assert((r :: Instance).ClassName == className, `{FOLDER}.{name} must be a {className}`)
		set[name] = r
	end
	return set :: any
end

function Remotes.client(timeout: number?): Set
	local folder = ReplicatedStorage:WaitForChild(FOLDER, timeout or 30)
	assert(folder, `{FOLDER} did not appear`)
	local set = {}
	for name in SPEC do
		set[name] = (folder :: Instance):WaitForChild(name, timeout or 30)
	end
	return set :: any
end

return table.freeze(Remotes)
