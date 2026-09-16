-- Kallskar: run inside Studio (Edit data model) via the MCP execute_luau tool.
-- Prints "<path>\t<class>\t<bytes>\t<fnv1a32>" for every script under the four Kallskar roots, sorted, in the same
-- format as tools/studio/manifest.ps1, so the two can be diffed. Not synced into the game (lives under tools/).
local roots = {
	{ game:GetService("ReplicatedStorage"), "Kallskar" },
	{ game:GetService("ServerScriptService"), "Kallskar" },
	{ game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"), "Kallskar" },
	{ game:GetService("ServerStorage"), "KallskarTests" },
}

local function fnv1a(s: string): string
	local h = 2166136261
	for i = 1, #s do
		h = bit32.bxor(h, string.byte(s, i))
		-- h * 16777619 mod 2^32, split as (h << 24) + h * 403 to stay exact in doubles
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	return string.format("%08x", h)
end

local lines = {}
for _, r in roots do
	local parent, name = r[1], r[2]
	local top = parent and parent:FindFirstChild(name)
	if top then
		local list = top:GetDescendants()
		table.insert(list, top)
		for _, inst in list do
			if inst:IsA("LuaSourceContainer") then
				local src = (inst :: any).Source
				local path = inst:GetFullName()
				path = string.gsub(path, "^StarterPlayer%.StarterPlayerScripts", "StarterPlayer.StarterPlayerScripts")
				table.insert(lines, `{path}\t{inst.ClassName}\t{#src}\t{fnv1a(src)}`)
			end
		end
	end
end
table.sort(lines)
return table.concat(lines, "\n")
