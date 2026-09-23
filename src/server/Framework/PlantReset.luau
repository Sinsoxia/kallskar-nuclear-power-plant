--!strict
--[[
	PlantReset — what an owner reset does to the running plant (spec §14.6).
	=========================================================================
	Persistence runs the owner's countdown, removes the stored plant and publishes PlantReset. This answers it: §14.6
	asks for hot standby at beginning of cycle with every component as new, and the framework's own state goes with
	it (the clocks, any sliced work on the old plant, the faults, the external inputs).

	The plant is held halted while it is rebuilt, and the halt is cleared only once every system's init has run. An
	init that raises leaves the plant halted, with the reason in Scheduler.halted and the log, rather than running a
	plant some of whose systems are new and some are not. Another reset, once the cause is put right, recovers it.
]]
local PlantReset = {}
PlantReset.__index = PlantReset

function PlantReset.new(opts: { registry: any, channels: any, scheduler: any, faults: any, log: any, bus: any, ctx: any })
	local self = setmetatable({}, PlantReset)
	self.registry = opts.registry
	self.channels = opts.channels
	self.scheduler = opts.scheduler
	self.faults = opts.faults
	self.log = opts.log
	self.ctx = opts.ctx -- the context Main gave every system's init at boot
	opts.bus:subscribe("PlantReset", function()
		self:reinitialise()
	end)
	return self
end

-- Returns (true) once the plant runs again, or (false, why) when it stays halted.
function PlantReset.reinitialise(self: any): (boolean, string?)
	local scheduler = self.scheduler
	scheduler.halted = "re-initialising after an owner reset" -- nothing steps a plant while it is being rebuilt
	scheduler:restart()
	self.faults:forgetAll()
	self.channels:resetExternals()
	local ok, err = pcall(self.registry.initAll, self.registry, self.ctx)
	if not ok then
		scheduler.halted = `owner reset: a system failed to initialise: {tostring(err)}`
		warn(`[Kallskar] SIMULATION HALTED: {scheduler.halted}`)
		self.log:record("plant.reinitialised", nil, nil, tostring(err), "error")
		return false, scheduler.halted
	end
	scheduler.halted = nil
	self.log:record("plant.reinitialised", nil, nil, "hot standby, beginning of cycle", "ok")
	return true, nil
end

return PlantReset
