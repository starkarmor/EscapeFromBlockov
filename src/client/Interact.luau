--!strict
-- Interactions and the loot pane (World.gatherOptions / startOption / updateLoot, InventoryUI loot target):
-- every interactable within reach is an option, nearest first; the mouse wheel or up / down picks one, F uses it.
-- Labels: a container's name ("Toolbox"), "Loot" for bodies, doors "Open" / "Close", builds with their cost;
-- requirement tags in red (missing) or green (have, selected only), "Empty" on searched empty boxes.
-- The loot pane (right 80, top 150, 640 wide): title 50 + (count/slots), 5 columns of 120 cells; unrevealed slots are
-- striped, the one being searched spins a magnifier (0.75 s); quality shows as the item's glow colour; double-click or
-- F takes the selected item. The backpack opens beside it.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local MapData = require(Shared.MapData)
local Items = require(Shared.gen.Items)
local PC = require(script.Parent.PlayerControl)
local Hud = require(script.Parent.Hud)
local Inventory = require(script.Parent.Inventory)
local Sfx = require(script.Parent.Sfx)

local player = Players.LocalPlayer
local S = Units.S
local Interact = {}

local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json")
local WHITE = Color3.new(1, 1, 1)
local CREAM = Color3.fromHex("#f8f2ea")
local INK = Color3.new(0, 0, 0)

type Point = { id: string, kind: string, label: string, x: number, z: number, r: number, hold: number, flag: string?, cost: { any }?, key: string?, part: BasePart? }
local points: { [string]: Point } = {}
local openBox: string? = nil
local selIndex = 1
local lastList: { Point } = {}

local function bagCount(id: string): number
	local raw = player:GetAttribute("Bag")
	local n = 0
	if typeof(raw) == "string" then
		for bid, c in string.gmatch(raw, "([^:,]+):(%d+)") do
			if bid == id then
				n += tonumber(c) or 0
			end
		end
	end
	return n
end

local function itemName(id: string): string
	local d = Items.items[id]
	return if d then d.name else (string.gsub(id, "_", " "))
end

local function refreshPoints()
	for _, d in MapData.doors or {} do
		points[d.id] = { id = d.id, kind = "door", label = "Open", x = d.x, z = d.z, r = 1.9, hold = d.interactTime or 0.2, key = d.key }
	end
	local all = table.clone(MapData.interacts)
	for _, it in require(Shared.CaveData).interacts do
		table.insert(all, it)
	end
	for _, it in all do
		if it.kind == "construct" then
			points[it.id] = { id = it.id, kind = "construct", label = it.label or "Build", x = it.x, z = it.z, r = it.r or 2.4, hold = it.hold or 0, flag = it.flag, cost = (it.cost and it.cost.items) or {} }
		elseif it.kind == "note" or it.kind == "beacon" or it.kind == "wall" or it.kind == "station" then
			points[it.id] = { id = it.id, kind = it.kind, label = it.label, x = it.x, z = it.z, r = math.max(it.r or 1.8, 1.8), hold = it.hold or 0, flag = it.flag }
		elseif it.kind == "hatch" or (it.kind == "teleport" and (it.label == "Go" or it.arrive ~= nil)) or it.kind == "loader" then
			points[it.id] = { id = it.id, kind = it.kind, label = it.label, x = it.x, z = it.z, r = math.max(it.r or 1.8, 1.8), hold = it.hold or 0 }
		end
	end
end

-- containers (Loot folder anchors) and bodies (character roots) carry a "Box" attribute
local function trackBox(p: Instance)
	if not p:IsA("BasePart") then
		return
	end
	local part = p :: BasePart
	local function add()
		local id = part:GetAttribute("Box")
		if typeof(id) ~= "string" or points[id] then
			return
		end
		local bodyName = part:GetAttribute("BoxName")
		local isBody = typeof(bodyName) == "string"
		points[id] = {
			id = id,
			kind = if isBody then "body" else "container",
			label = if isBody then bodyName else part.Name,
			x = part.Position.X / S,
			z = part.Position.Z / S,
			r = 1.9,
			hold = if part.Name == "tech" then 0.6 else 0,
			part = part,
		}
		part.AncestryChanged:Connect(function()
			if not part:IsDescendantOf(Workspace) then
				points[id] = nil
			end
		end)
	end
	add()
	part:GetAttributeChangedSignal("Box"):Connect(add)
end

local function optionFor(pt: Point): Hud.PromptOpt?
	if pt.kind == "construct" and Workspace:GetAttribute("Flag_" .. (string.gsub(tostring(pt.flag), "[^%w_]", "_"))) then
		return nil
	end
	if pt.kind == "beacon" and Workspace:GetAttribute("Flag_" .. (pt.flag or "beacon")) then
		return nil -- an unlocked beacon hides its interact
	end
	if pt.kind == "wall" then
		if Workspace:GetAttribute("Flag_" .. (pt.flag or "wall")) then
			return nil
		end
		return { label = pt.label, sel = false, req = "Requires Explosives", reqOk = false }
	end
	if pt.kind == "container" or pt.kind == "body" then
		local typ = Items.types[pt.label]
		local name = if pt.kind == "body" then "Loot" else (if typ then typ.name else pt.label)
		local count = Workspace:GetAttribute("Box_" .. (string.gsub(pt.id, "[^%w_]", "_")))
		if Workspace:GetAttribute("BoxS_" .. (string.gsub(pt.id, "[^%w_]", "_"))) == true and count == 0 then
			if pt.kind == "body" then
				return nil -- an emptied body / tomb is hidden from interaction
			end
			return { label = name, sel = false, req = "Empty", reqOk = false }
		end
		return { label = name, sel = false }
	elseif pt.kind == "door" then
		local open = Workspace:GetAttribute("Door_" .. pt.id) == true
		if pt.key and not open then
			local have = bagCount(pt.key) > 0
			return { label = "Open", sel = false, req = if have then itemName(pt.key) else "Requires Key", reqOk = have }
		end
		return { label = if open then "Close" else "Open", sel = false }
	elseif pt.kind == "construct" then
		local parts, ok = {}, true
		for _, c in pt.cost or {} do
			table.insert(parts, string.format("%s x%d", itemName(c[1]), c[2]))
			if bagCount(c[1]) < c[2] then
				ok = false
			end
		end
		if #parts > 0 then
			return { label = pt.label, sel = false, req = (if ok then "" else "Requires ") .. table.concat(parts, ", "), reqOk = ok }
		end
		return { label = pt.label, sel = false }
	end
	return { label = pt.label, sel = false }
end

-- ------------------------------------------------------------------ loot pane
local panel: Frame
local grid: Frame
local title: TextLabel
local selSlot: number? = nil
local lastItems: { any } = {}
local lastClick = 0
local spinners: { TextLabel } = {}
local curLabel, curSlots = "", 0

local function stroke(o: Instance, t: number, c: Color3, tr: number)
	local s = Instance.new("UIStroke")
	s.Thickness = t
	s.Color = c
	s.Transparency = tr
	s.ApplyStrokeMode = if o:IsA("TextLabel") then Enum.ApplyStrokeMode.Contextual else Enum.ApplyStrokeMode.Border
	s.Parent = o
	return s
end

local function corner(o: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
end

local function buildUi()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Loot"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 6
	gui.Parent = player:WaitForChild("PlayerGui")
	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui
	local us = Instance.new("UIScale")
	us.Parent = root
	panel = Instance.new("Frame")
	panel.Name = "LootPanel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
	panel.BackgroundTransparency = 0.15
	panel.Visible = false
	corner(panel, 16)
	panel.Parent = root
	title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.FontFace = FONT
	title.TextSize = 50
	title.TextColor3 = CREAM
	title.RichText = true
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromOffset(20, 10)
	title.Size = UDim2.new(1, -40, 0, 62)
	stroke(title, 2.5, INK, 0.35)
	title.Parent = panel
	grid = Instance.new("Frame")
	grid.Name = "BoxGrid"
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromOffset(20, 84)
	grid.Size = UDim2.new(1, -40, 1, -100)
	grid.Parent = panel
	local g = Instance.new("UIGridLayout")
	g.CellSize = UDim2.fromOffset(112, 112)
	g.CellPadding = UDim2.fromOffset(8, 8)
	g.SortOrder = Enum.SortOrder.LayoutOrder
	g.Parent = grid
	RunService.RenderStepped:Connect(function(dt)
		local vp = Workspace.CurrentCamera.ViewportSize
		local u = math.min(vp.X / 2560, vp.Y / 1440)
		us.Scale = u
		root.Size = UDim2.fromOffset(vp.X / u, vp.Y / u)
		panel.Position = UDim2.new(1, -80, 0, 150)
		panel.Size = UDim2.new(0, 640, 1, -270)
		for _, sp in spinners do
			sp.Rotation = (sp.Rotation + dt * 480) % 360
		end
	end)
end

-- diagonal stripes for unrevealed slots: 135 deg bands of rgba(102,102,102,.749) / .45
local function stripes(f: Instance)
	local gr = Instance.new("UIGradient")
	gr.Rotation = 135
	local ks = {}
	local n = 8
	for i = 0, n - 1 do
		local t = if i % 2 == 0 then 0.251 else 0.55
		table.insert(ks, NumberSequenceKeypoint.new(i / n, t))
		table.insert(ks, NumberSequenceKeypoint.new((i + 1) / n - 0.001, t))
	end
	ks[#ks] = NumberSequenceKeypoint.new(1, ks[#ks].Value)
	gr.Transparency = NumberSequence.new(ks)
	gr.Parent = f
end

local function take(i: number)
	if openBox then
		Net.event("LootTake"):FireServer(openBox, i)
	end
end

local function render(items: { any })
	panel.Visible = true
	title.Text = string.format('%s <font size="24">(%d/%d)</font>', curLabel, #items, math.max(curSlots, #items))
	for _, c in grid:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	table.clear(spinners)
	local firstHidden: number? = nil
	for i, it in items do
		if it.hidden and not firstHidden then
			firstHidden = i
		end
		local was = lastItems[i]
		if was and was.hidden and not it.hidden then
			Sfx.play("pickup") -- each reveal plays 'pickup'
		end
	end
	lastItems = items
	for i, it in items do
		local b = Instance.new("TextButton")
		b.Name = "Slot" .. i
		b.LayoutOrder = i
		b.Text = ""
		b.AutoButtonColor = false
		b.BackgroundColor3 = if it.hidden then Color3.fromRGB(102, 102, 102) else INK
		b.BackgroundTransparency = if it.hidden then 0.25 else 0.8
		corner(b, 16)
		stroke(b, 2, WHITE, 0.702)
		if it.hidden then
			stripes(b)
			if i == firstHidden then
				local mag = Instance.new("TextLabel")
				mag.BackgroundTransparency = 1
				mag.Text = "🔍"
				mag.TextSize = 40
				mag.FontFace = FONT
				mag.AnchorPoint = Vector2.new(0.5, 0.5)
				mag.Position = UDim2.new(0.5, 0, 0.5, -8)
				mag.Size = UDim2.fromOffset(40, 40)
				mag.Parent = b
				table.insert(spinners, mag)
			end
		else
			local q = math.clamp(it.q or 0, 0, 6)
			local name = Instance.new("TextLabel")
			name.BackgroundTransparency = 1
			name.FontFace = FONT
			name.TextScaled = true
			name.TextWrapped = true
			name.Text = it.name
			name.TextColor3 = WHITE
			name.Size = UDim2.new(1, -12, 0, 22)
			name.Position = UDim2.new(0, 6, 1, -28)
			local icon = Instance.new("ImageLabel")
			icon.BackgroundTransparency = 1
			icon.AnchorPoint = Vector2.new(0.5, 0)
			icon.Position = UDim2.new(0.5, 0, 0, 4)
			icon.Size = UDim2.new(0.62, 0, 0.62, 0)
			icon.SizeConstraint = Enum.SizeConstraint.RelativeYY
			icon.Parent = b
			require(script.Parent.Icon).apply(icon, it.id)
			stroke(name, 2, if q == 0 then INK else Hud.QCOL[q], if q == 0 then 0.3 else 0)
			name.Parent = b
			if (it.n or 1) > 1 then
				local ct = Instance.new("TextLabel")
				ct.BackgroundColor3 = Color3.fromHex("#585f66")
				ct.FontFace = FONT
				ct.TextSize = 16
				ct.TextColor3 = CREAM
				ct.Text = tostring(it.n)
				ct.AutomaticSize = Enum.AutomaticSize.X
				ct.AnchorPoint = Vector2.new(1, 1)
				ct.Position = UDim2.fromScale(1, 1)
				ct.Size = UDim2.fromOffset(0, 17.5)
				local pad = Instance.new("UIPadding")
				pad.PaddingLeft = UDim.new(0, 5)
				pad.PaddingRight = UDim.new(0, 5)
				pad.Parent = ct
				local cc = Instance.new("UICorner")
				cc.CornerRadius = UDim.new(1, 0)
				cc.Parent = ct
				ct.Parent = b
			end
			if selSlot == i then
				stroke(b, 3, Color3.fromHex("#ff9e3a"), 0)
			end
			b.MouseButton1Click:Connect(function()
				local now = os.clock()
				if selSlot == i and now - lastClick < 0.4 then
					take(i)
					selSlot = nil
				else
					selSlot = i
					render(lastItems)
				end
				lastClick = now
			end)
		end
		b.Parent = grid
	end
end

local function closeUi()
	panel.Visible = false
	openBox = nil
	selSlot = nil
	lastItems = {}
	Inventory.side(false)
	if Inventory.open then
		Inventory.toggle(false)
	end
	UserInputService.MouseIconEnabled = false
end

-- ------------------------------------------------------------------ loop
function Interact.update(_dt: number)
	local list: { Point } = {}
	for _, pt in points do
		if pt.part and pt.part.Parent then
			pt.x, pt.z = pt.part.Position.X / S, pt.part.Position.Z / S
		end
		if (Vector2.new(pt.x, pt.z) - PC.pos).Magnitude <= pt.r then
			table.insert(list, pt)
		end
	end
	table.sort(list, function(a, b)
		return (Vector2.new(a.x, a.z) - PC.pos).Magnitude < (Vector2.new(b.x, b.z) - PC.pos).Magnitude
	end)
	local opts: { Hud.PromptOpt } = {}
	local shown: { Point } = {}
	for _, pt in list do
		local o = optionFor(pt)
		if o then
			table.insert(opts, o)
			table.insert(shown, pt)
		end
	end
	-- a wheel selection stays while its target remains in reach
	local keep = lastList[selIndex]
	selIndex = 1
	for i, pt in shown do
		if pt == keep then
			selIndex = i
		end
	end
	lastList = shown
	if opts[selIndex] then
		opts[selIndex].sel = true
	end
	if #opts > 0 and not openBox and not PC.blocked then
		local focus = shown[1]
		Hud.setPrompt(opts, Vector3.new(focus.x, 0.62, focus.z))
	else
		Hud.setPrompt(nil, nil)
	end
	local holdId = player:GetAttribute("HoldId")
	if typeof(holdId) == "string" then
		local t0 = player:GetAttribute("HoldStart")
		local dur = player:GetAttribute("HoldTime")
		if typeof(t0) == "number" and typeof(dur) == "number" then
			Hud.setProgress((Workspace:GetServerTimeNow() - t0) / dur)
		end
	end
	PC.lootOpen = openBox ~= nil
end

function Interact.start()
	refreshPoints()
	buildUi()
	local lootFolder = Workspace:WaitForChild("Loot", 10)
	if lootFolder then
		for _, p in lootFolder:GetChildren() do
			trackBox(p)
		end
		lootFolder.ChildAdded:Connect(trackBox)
	end
	local chars = Workspace:WaitForChild("Characters")
	local function watchChar(m: Instance)
		local r = m:WaitForChild("HumanoidRootPart", 5)
		if r then
			trackBox(r)
		end
	end
	for _, m in chars:GetChildren() do
		task.spawn(watchChar, m)
	end
	chars.ChildAdded:Connect(function(m)
		task.spawn(watchChar, m)
	end)
	-- Escape is taken by the Roblox menu (processed): close the loot pane on it, and when the menu opens
	game:GetService("GuiService").MenuOpened:Connect(function()
		if openBox then
			Net.event("InteractCancel"):FireServer()
			closeUi()
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Escape and openBox then
			Net.event("InteractCancel"):FireServer()
			closeUi()
			return
		end
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.F then
			if openBox then
				if selSlot then
					take(selSlot)
					selSlot = nil
				end
			elseif lastList[selIndex] then
				Net.event("Interact"):FireServer(lastList[selIndex].id)
			end
		elseif input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.X then
			if openBox then
				Net.event("InteractCancel"):FireServer()
				closeUi()
			end
		elseif input.KeyCode == Enum.KeyCode.Up or input.KeyCode == Enum.KeyCode.Down then
			if #lastList > 1 then
				selIndex = (selIndex + (if input.KeyCode == Enum.KeyCode.Down then 1 else -1) - 1) % #lastList + 1
			end
		end
	end)
	UserInputService.InputChanged:Connect(function(input, processed)
		if processed or openBox or #lastList < 2 then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and math.abs(input.Position.Z) > 0.5 then
			selIndex = (selIndex + (if input.Position.Z < 0 then 1 else -1) - 1) % #lastList + 1
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F and player:GetAttribute("HoldId") then
			Net.event("InteractCancel"):FireServer()
		end
	end)
	Net.event("LootOpen").OnClientEvent:Connect(function(id: string?, label: any, items: any, _bag: any, slots: any)
		if id == nil then
			closeUi()
			return
		end
		if id == "bag" then
			return
		end
		if openBox ~= id then
			selSlot = nil
			lastItems = {}
		end
		openBox = id
		curLabel = tostring(label)
		curSlots = tonumber(slots) or #items
		render(items)
		Inventory.side(true)
		if not Inventory.open then
			Inventory.toggle(true)
		end
		UserInputService.MouseIconEnabled = true
	end)
end

return Interact
