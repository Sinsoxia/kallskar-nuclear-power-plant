--!strict
-- Studio-only: runs the Kallskar test suite when ServerStorage.KallskarTests has attribute RunTests = true.
-- Optional attribute TestFilter (string) runs only spec modules whose name contains it.
-- Never does anything on a live server.
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

if not RunService:IsStudio() then
	return
end

local root = ServerStorage:FindFirstChild("KallskarTests")
if not root or root:GetAttribute("RunTests") ~= true then
	return
end

local Runner = require(root:WaitForChild("Runner")) :: any
local filter = root:GetAttribute("TestFilter")
task.defer(function()
	Runner.run(root, if type(filter) == "string" and #filter > 0 then filter else nil)
end)
