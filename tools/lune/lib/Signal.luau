--!strict
--[[
	Headless stand-in for RBXScriptSignal / RBXScriptConnection.

	Handlers are deferred (task.defer), as under Workspace.SignalBehavior = Deferred: firing never runs a handler
	inside the firing call. `Wait` parks the calling thread until the next fire.
	Engine events that need a real engine loop (RunService.Heartbeat, Players.PlayerAdded) exist so code can connect
	to them, but the harness never fires them: nothing in a headless run renders frames or admits players.
]]
local task = require("@lune/task")

local Connection = {}
Connection.__index = Connection

function Connection.Disconnect(self: any)
	if not self.Connected then
		return
	end
	self.Connected = false
	local list = self._signal._handlers
	local i = table.find(list, self)
	if i then
		table.remove(list, i)
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new(name: string)
	return setmetatable({ _name = name, _handlers = {}, _waiting = {}, fired = 0 }, Signal)
end

function Signal.Connect(self: any, fn: (...any) -> ())
	assert(type(fn) == "function", `{self._name}:Connect expects a function`)
	local c = setmetatable({ Connected = true, _fn = fn, _signal = self, _once = false }, Connection)
	table.insert(self._handlers, c)
	return c
end

Signal.ConnectParallel = Signal.Connect

function Signal.Once(self: any, fn: (...any) -> ())
	local c = Signal.Connect(self, fn)
	c._once = true
	return c
end

function Signal.Wait(self: any): ...any
	table.insert(self._waiting, coroutine.running())
	return coroutine.yield()
end

-- Harness-side: fire the signal. Not reachable from game code except through the owning instance's API
-- (BindableEvent:Fire), as in Roblox.
function Signal._fire(self: any, ...: any)
	self.fired += 1
	for _, c in table.clone(self._handlers) do
		if c.Connected then
			if c._once then
				c:Disconnect()
			end
			task.defer(c._fn, ...)
		end
	end
	local waiting = self._waiting
	self._waiting = {}
	for _, thread in waiting do
		task.defer(thread, ...)
	end
end

function Signal.__tostring(self: any): string
	return `Signal {self._name}`
end

return Signal
