--!strict
--[[
	DebugPanel — the developer screen (plan: src/client/Dev/DebugPanel).
	======================================================================

	Studio-only scaffolding, and deliberately plain: it renders what the server sends and nothing else. Clients
	never compute plant state (§14.5), so every number here arrived over the wire already decided.

	Colours are the plant's: light blue #328bf0 on light purple #b482fa. The two are only about 1.5:1 against each
	other, so the purple carries headings, rules and section titles at large sizes, the blue carries live values,
	and body text sits on a dark slate that both read cleanly against — which is the same reason a real control
	room is dark with bright indications rather than the other way round.
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BLUE = Color3.fromHex("328bf0")
local PURPLE = Color3.fromHex("b482fa")
local INK = Color3.fromRGB(232, 236, 245)
local DIM = Color3.fromRGB(140, 150, 170)
local SLATE = Color3.fromRGB(14, 16, 24)
local PANEL = Color3.fromRGB(22, 25, 36)
local WARN = Color3.fromRGB(255, 176, 64)
local TRIP = Color3.fromRGB(255, 92, 92)
local GOOD = Color3.fromRGB(96, 224, 160)

--[[
	The folder exists on every server, because the plant snapshot lives there too (Telemetry/PlantSnapshot), but
	the panel's own remotes exist only in Studio. On a live server they never appear, and the panel does not exist.
]]
local folder = ReplicatedStorage:WaitForChild("KallskarDev", 30)
local snapshotRemote = folder and folder:WaitForChild("Snapshot", 10) :: RemoteEvent?
local actionRemote = folder and folder:WaitForChild("Action", 10) :: RemoteEvent?
if not snapshotRemote or not actionRemote then
	return -- not a dev build; the panel simply does not exist
end

local gui = Instance.new("ScreenGui")
gui.Name = "KallskarDebugPanel"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

-- A scrolling frame, so a short window scrolls the panel instead of cutting its last rows off
local root = Instance.new("ScrollingFrame")
root.Size = UDim2.new(0, 560, 1, -40)
root.Position = UDim2.new(0, 20, 0, 20)
root.BackgroundColor3 = SLATE
root.BackgroundTransparency = 0.08
root.BorderSizePixel = 0
root.CanvasSize = UDim2.new(0, 0, 0, 0)
root.AutomaticCanvasSize = Enum.AutomaticSize.Y
root.ScrollingDirection = Enum.ScrollingDirection.Y
root.ScrollBarThickness = 4
root.ScrollBarImageColor3 = PURPLE
root.Parent = gui
local rootCorner = Instance.new("UICorner")
rootCorner.CornerRadius = UDim.new(0, 10)
rootCorner.Parent = root
local rootStroke = Instance.new("UIStroke")
rootStroke.Color = PURPLE
rootStroke.Thickness = 1.5
rootStroke.Transparency = 0.45
rootStroke.Parent = root

local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 6)
list.SortOrder = Enum.SortOrder.LayoutOrder
list.Parent = root
local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 12)
pad.PaddingLeft = UDim.new(0, 14)
pad.PaddingRight = UDim.new(0, 14)
pad.PaddingBottom = UDim.new(0, 12)
pad.Parent = root

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local function label(parent: Instance, text: string, size: number, colour: Color3, bold: boolean?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = if bold then Enum.Font.GothamBold else Enum.Font.Gotham
	l.TextSize = size
	l.TextColor3 = colour
	l.Text = text
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Size = UDim2.new(1, 0, 0, size + 6)
	l.Parent = parent
	return l
end

-- A titled block with a purple rule above it, which is what separates the sections
local function section(title: string): Frame
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 0)
	holder.AutomaticSize = Enum.AutomaticSize.Y
	holder.LayoutOrder = nextOrder()
	holder.Parent = root
	local inner = Instance.new("UIListLayout")
	inner.Padding = UDim.new(0, 2)
	inner.SortOrder = Enum.SortOrder.LayoutOrder
	inner.Parent = holder
	local rule = Instance.new("Frame")
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.BackgroundColor3 = PURPLE
	rule.BackgroundTransparency = 0.6
	rule.BorderSizePixel = 0
	rule.LayoutOrder = 0
	rule.Parent = holder
	local t = label(holder, string.upper(title), 11, PURPLE, true)
	t.LayoutOrder = 1
	return holder
end

--[[
	One reading. The value sits in its own label so updates touch one string rather than rebuilding the row, and
	the colour of the value is where a panel says "this one needs you" without any extra furniture.
]]
local function row(parent: Instance, name: string): TextLabel
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 17)
	holder.LayoutOrder = nextOrder()
	holder.Parent = parent
	local n = label(holder, name, 12, DIM)
	n.Size = UDim2.new(0.45, 0, 1, 0)
	local v = label(holder, "—", 12, INK, true)
	v.Position = UDim2.new(0.45, 0, 0, 0)
	v.Size = UDim2.new(0.55, 0, 1, 0)
	return v
end

local function button(parent: Instance, text: string, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(0, 96, 0, 26)
	b.BackgroundColor3 = PANEL
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 11
	b.TextColor3 = BLUE
	b.Text = text
	b.AutoButtonColor = true
	b.LayoutOrder = nextOrder() -- the grid lays buttons out in the order they were made
	b.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	local s = Instance.new("UIStroke")
	s.Color = BLUE
	s.Transparency = 0.6
	s.Parent = b
	b.MouseButton1Click:Connect(onClick)
	return b
end

-- Header -----------------------------------------------------------------------------------------------------
local header = Instance.new("Frame")
header.BackgroundTransparency = 1
header.Size = UDim2.new(1, 0, 0, 34)
header.LayoutOrder = nextOrder()
header.Parent = root
local title = label(header, "KALLSKÄR K1", 18, PURPLE, true)
title.Size = UDim2.new(0.6, 0, 0, 20)
local subtitle = label(header, "SFR-1000 · developer panel", 10, DIM)
subtitle.Position = UDim2.new(0, 0, 0, 20)
local clock = label(header, "", 11, BLUE, true)
clock.TextXAlignment = Enum.TextXAlignment.Right
clock.Size = UDim2.new(0.4, 0, 0, 20)
clock.Position = UDim2.new(0.6, 0, 0, 0)

-- Banner: the one line that says whether the plant is in trouble
local banner = Instance.new("TextLabel")
banner.Size = UDim2.new(1, 0, 0, 24)
banner.BackgroundColor3 = PANEL
banner.BorderSizePixel = 0
banner.Font = Enum.Font.GothamBold
banner.TextSize = 12
banner.TextColor3 = GOOD
banner.Text = "waiting for the plant"
banner.TextXAlignment = Enum.TextXAlignment.Left
banner.LayoutOrder = nextOrder()
banner.Parent = root
local bannerCorner = Instance.new("UICorner")
bannerCorner.CornerRadius = UDim.new(0, 6)
bannerCorner.Parent = banner

-- Controls, straight under the banner so they stay in reach however far the readings scroll -----------------
local controls = Instance.new("Frame")
controls.BackgroundTransparency = 1
controls.Size = UDim2.new(1, 0, 0, 58)
controls.LayoutOrder = nextOrder()
controls.Parent = root
local grid = Instance.new("UIGridLayout")
grid.CellSize = UDim2.new(0, 96, 0, 26)
grid.CellPadding = UDim2.new(0, 6, 0, 6)
grid.SortOrder = Enum.SortOrder.LayoutOrder
grid.Parent = controls

local latest: { [string]: any } = {}
button(controls, "SEAT 20 %FP", function()
	actionRemote:FireServer("preset", 20)
end)
button(controls, "LOAD −5 %", function()
	actionRemote:FireServer("load", -5)
end)
button(controls, "LOAD +5 %", function()
	actionRemote:FireServer("load", 5)
end)
button(controls, "ROD AUTO", function()
	actionRemote:FireServer("autoRod", not latest.autoRod)
end)
button(controls, "FLOW AUTO", function()
	actionRemote:FireServer("autoFlow", not latest.autoFlow)
end)
button(controls, "ROD OUT 50", function()
	actionRemote:FireServer("rod", 50)
end)
button(controls, "ROD IN 50", function()
	actionRemote:FireServer("rod", -50)
end)
button(controls, "TRIP PUMP", function()
	actionRemote:FireServer("pumpTrip", 3)
end)
button(controls, "SCRAM", function()
	actionRemote:FireServer("scram")
end)
button(controls, "RESET", function()
	actionRemote:FireServer("reset")
end)

local reactor = section("reactor")
local vPower = row(reactor, "Neutron power")
local vThermal = row(reactor, "Thermal / decay heat")
local vRho = row(reactor, "Reactivity ρ")
local vK = row(reactor, "k effective")
local vPeriod = row(reactor, "Period")
local vFeedback = row(reactor, "Feedback (D/ax/Na)")

local thermal = section("thermal")
local vFuel = row(thermal, "Fuel average")
local vClad = row(thermal, "Cladding hot spot")
local vOutlet = row(thermal, "Core outlet (mixed)")
local vInlet = row(thermal, "Core inlet")
local vPools = row(thermal, "Hot / cold pool")
local vGas = row(thermal, "Cover gas")

local primary = section("primary and heat sink")
local vFlow = row(primary, "Primary flow")
local vPQ = row(primary, "Power to flow")
local vIHX = row(primary, "IHX duty")
local vLoad = row(primary, "Steam plant load")
local vLoops = row(primary, "Pumps / loops")

local rodsSection = section("rods")
local vRR = row(rodsSection, "Regulating")
local vSM = row(rodsSection, "Shim banks")
local vSSR = row(rodsSection, "Secondary shutdown")
local vWorth = row(rodsSection, "Worth inserted")
local vSel = row(rodsSection, "Moving")

local instruments = section("instrumentation")
local vSR = row(instruments, "Source range")
local vWR = row(instruments, "Wide range")
local vPR = row(instruments, "Power range")
local vDND = row(instruments, "Delayed neutrons")

local control = section("protection and control")
local vScram = row(control, "Shutdown system")
local vFirst = row(control, "First out")
local vAuto = row(control, "Rod / flow auto")
local vSetpoint = row(control, "Outlet setpoint")
local vAlarms = row(control, "Alarms in")
local vInhibit = row(control, "Inhibited")

-- Rendering ---------------------------------------------------------------------------------------------------
local function fmt(n: number, places: number): string
	return string.format("%." .. places .. "f", n)
end

--[[
	Power spans ten decades between a shut-down plant and full load, so a fixed format is useless: below a tenth
	of a percent it is read as an exponent, above it as a percentage, which is how the real instruments are
	scaled too (§3.5's source, wide and power ranges).
]]
local function power(p: number): string
	if p < 0.1 then
		return string.format("%.2e %%FP", p)
	end
	return string.format("%.2f %%FP", p)
end

local function periodText(s: number): string
	if s == nil or math.abs(s) > 1e5 then
		return "∞"
	end
	return string.format("%+.0f s", s)
end

snapshotRemote.OnClientEvent:Connect(function(d)
	latest = d
	clock.Text = string.format("t + %.0f s", d.t or 0)

	if d.scram ~= "none" then
		banner.TextColor3 = TRIP
		banner.Text = string.format("  SHUTDOWN — %s   first out: %s", d.scram, if d.firstOut ~= "" then d.firstOut else "—")
	elseif d.promptCritical then
		banner.TextColor3 = TRIP
		banner.Text = "  PROMPT CRITICAL"
	elseif #d.alarms > 0 then
		banner.TextColor3 = WARN
		banner.Text = "  ALARM — " .. table.concat(d.alarms, ", ")
	elseif d.runback ~= "" then
		banner.TextColor3 = WARN
		banner.Text = "  RUNBACK " .. d.runback
	else
		banner.TextColor3 = GOOD
		banner.Text = string.format("  plant normal · %s · mode %d", power(d.power), d.mode)
	end

	vPower.Text = power(d.power)
	-- after a trip these part company: the neutrons are gone in minutes, the heat stays for hours (§3.6)
	vThermal.Text = string.format("%.2f %%FP  %.0f MWt   (decay %.1f MW)", d.thermal, d.mwt, d.decayMW)
	vRho.Text = string.format("%+.1f pcm", d.rho)
	vRho.TextColor3 = if math.abs(d.rho) > 200 then WARN else INK
	vK.Text = fmt(d.k, 5)
	vPeriod.Text = periodText(d.period)
	vFeedback.Text = string.format("%+.0f / %+.0f / %+.0f pcm",
		d.feedback.doppler, d.feedback.axial, d.feedback.sodium)

	vFuel.Text = string.format("%.0f °C", d.fuel)
	vClad.Text = string.format("%.0f °C", d.clad)
	vClad.TextColor3 = if d.clad > 650 then TRIP elseif d.clad > 620 then WARN else INK
	vOutlet.Text = string.format("%.1f °C", d.outlet)
	vOutlet.TextColor3 = if d.outlet > 580 then TRIP elseif d.outlet > 565 then WARN else INK
	vInlet.Text = string.format("%.1f °C", d.inlet)
	vPools.Text = string.format("%.0f / %.0f °C", d.hotPool, d.coldPool)
	vGas.Text = string.format("%.4f MPa", d.coverGas)

	vFlow.Text = string.format("%.1f %% of rated", d.flow)
	vPQ.Text = fmt(d.pq, 3)
	vPQ.TextColor3 = if d.pq > 1.12 then TRIP elseif d.pq > 1.05 then WARN else INK
	vIHX.Text = string.format("%.0f MWt   (secondary %.0f → %.0f °C)", d.ihx, d.secondaryIn, d.secondaryOut)
	if math.abs(d.load - d.loadDemand) > 0.05 then
		vLoad.Text = string.format("%.1f %%  → %.0f %%", d.load, d.loadDemand)
		vLoad.TextColor3 = BLUE
	else
		vLoad.Text = string.format("%.1f %%", d.load)
		vLoad.TextColor3 = INK
	end
	vLoops.Text = string.format("%d pumps · %d loops", d.pumps, d.loops)
	vLoops.TextColor3 = if d.pumps < 3 or d.loops < 3 then WARN else INK

	vRR.Text = string.format("%.0f mm", d.rr)
	vSM.Text = string.format("%.0f mm", d.sm)
	vSSR.Text = string.format("%.0f mm", d.ssr)
	vWorth.Text = string.format("%.0f pcm   (%+.2f pcm/s)", d.worth, d.rodRate)
	vSel.Text = if d.selection ~= "" then d.selection else "—"
	vSel.TextColor3 = if d.selection ~= "" then BLUE else DIM

	vSR.Text = if d.srOn then string.format("%.0f cps   (1/M %.3f)", d.sr, d.oneOverM) else "de-energised"
	vSR.TextColor3 = if d.srOn then INK else DIM
	vWR.Text = power(d.wr)
	vPR.Text = string.format("%.2f %%FP   (%+.2f %%FP/s)", d.pr, d.fluxRate)
	vDND.Text = string.format("%.0f cps", d.dnd)
	vDND.TextColor3 = if d.dnd > 120 then WARN else INK

	vScram.Text = if d.scram == "none" then "available" else d.scram
	vScram.TextColor3 = if d.scram == "none" then GOOD else TRIP
	vFirst.Text = if d.firstOut ~= "" then d.firstOut else "—"
	vAuto.Text = string.format("%s / %s", if d.autoRod then "IN" else "out", if d.autoFlow then "IN" else "out")
	vAuto.TextColor3 = if d.autoRod or d.autoFlow then BLUE else DIM
	vSetpoint.Text = string.format("%.1f °C   (error %+.1f K)", d.setpoint, d.outlet - d.setpoint)
	if d.rodBand then
		vSetpoint.TextColor3 = WARN
		vSetpoint.Text ..= "  · rod auto at band limit"
	else
		vSetpoint.TextColor3 = INK
	end
	vAlarms.Text = if #d.alarms > 0 then table.concat(d.alarms, ", ") else "none"
	vAlarms.TextColor3 = if #d.alarms > 0 then WARN else DIM
	vInhibit.Text = if #d.inhibited > 0 then table.concat(d.inhibited, "; ") else "none"
	vInhibit.TextColor3 = if #d.inhibited > 0 then WARN else DIM
	if d.block then
		vSel.Text ..= "  · rod block"
		vSel.TextColor3 = WARN
	end
end)
