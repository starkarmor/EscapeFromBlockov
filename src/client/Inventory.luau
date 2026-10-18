--!strict
-- Tab: the backpack and worn equipment (web InventoryUI, restyled): Firearm 1 / 2, Melee, Helmet, Body Armor; click a
-- backpack item to equip or use it, click a worn slot to take it off. Weight against the 45 kg carry limit.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Items = require(Shared.gen.Items)
local Config = require(Shared.Config)
local PC = require(script.Parent.PlayerControl)

local player = Players.LocalPlayer
local Inventory = {}
local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json")
local INK = Color3.fromRGB(22, 21, 29)
local WHITE = Color3.fromRGB(255, 248, 233)
local QCOL = { [0] = Color3.fromRGB(150, 150, 160), Color3.fromRGB(230, 230, 230), Color3.fromRGB(128, 222, 37), Color3.fromRGB(19, 160, 244), Color3.fromRGB(153, 56, 242), Color3.fromRGB(255, 216, 61), Color3.fromRGB(243, 69, 67) }

local gui: ScreenGui
local panel: Frame
local equipGrid: Frame
local bagGrid: Frame
local weightLabel: TextLabel
Inventory.open = false

local function deco(o: GuiObject, r: number, t: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
	local s = Instance.new("UIStroke")
	s.Thickness = t
	s.Color = INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = o
end

local function text(parent: Instance, s: string, size: number): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.FontFace = FONT
	t.TextSize = size
	t.TextColor3 = WHITE
	t.Text = s
	t.Size = UDim2.new(1, 0, 0, size + 6)
	t.TextXAlignment = Enum.TextXAlignment.Left
	local st = Instance.new("UIStroke")
	st.Thickness = 2
	st.Color = INK
	st.Parent = t
	t.Parent = parent
	return t
end

local function grid(parent: Instance, y: number, h: number): Frame
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Position = UDim2.fromOffset(16, y)
	f.Size = UDim2.new(1, -32, 0, h)
	f.Parent = parent
	local g = Instance.new("UIGridLayout")
	g.CellSize = UDim2.fromOffset(84, 70)
	g.CellPadding = UDim2.fromOffset(8, 8)
	g.SortOrder = Enum.SortOrder.LayoutOrder
	g.Parent = f
	return f
end

local function slot(parent: Instance, order: number, caption: string, id: string?, n: number?, onClick: () -> ())
	local def = id and Items.items[id]
	local b = Instance.new("TextButton")
	b.Name = (if parent == equipGrid then "Equip" else "Bag") .. order
	b.LayoutOrder = order
	b.Text = ""
	b.BackgroundColor3 = if def then Color3.fromHex(def.color or "#888888"):Lerp(Color3.fromRGB(44, 44, 58), 0.45) else Color3.fromRGB(30, 30, 40)
	deco(b, 10, 3)
	if def then
		(b:FindFirstChildOfClass("UIStroke") :: UIStroke).Color = QCOL[def.q or 0] or INK
	end
	local t = text(b, if def then def.name else caption, 14)
	t.TextScaled = true
	t.TextXAlignment = Enum.TextXAlignment.Center
	t.Size = UDim2.new(1, -8, 0.6, 0)
	t.Position = UDim2.fromOffset(4, 4)
	if def then
		local icon = Instance.new("ImageLabel")
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0)
		icon.Position = UDim2.new(0.5, 0, 0, 2)
		icon.Size = UDim2.fromOffset(44, 44)
		icon.Parent = b
		require(script.Parent.Icon).apply(icon, id)
		t.Size = UDim2.new(1, -8, 0, 16)
		t.Position = UDim2.new(0, 4, 1, -20)
	end
	if def and n and n > 1 then
		local c = text(b, "x" .. n, 14)
		c.TextXAlignment = Enum.TextXAlignment.Right
		c.Position = UDim2.new(0, 0, 0, 3)
		c.Size = UDim2.new(1, -6, 0, 18)
	elseif not def then
		t.TextTransparency = 0.5
	end
	b.MouseButton1Click:Connect(onClick)
	b.Parent = parent
end

local function clear(f: Frame)
	for _, c in f:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function render()
	if not Inventory.open then
		return
	end
	clear(equipGrid)
	clear(bagGrid)
	local eq: { [string]: string } = {}
	local raw = player:GetAttribute("Equip")
	if typeof(raw) == "string" then
		for k, v in string.gmatch(raw, "(%w+)=([^,]*)") do
			eq[k] = v
		end
	end
	for i, s in { { "gun", "Firearm 1" }, { "gun2", "Firearm 2" }, { "melee", "Melee" }, { "helmet", "Helmet" }, { "armor", "Body Armor" } } do
		local id = eq[s[1]]
		slot(equipGrid, i, s[2], if id and id ~= "" then id else nil, 1, function()
			if s[1] ~= "melee" then
				Net.event("Unequip"):FireServer(s[1])
			end
		end)
	end
	local bag = player:GetAttribute("Bag")
	local i = 0
	if typeof(bag) == "string" then
		for id, n in string.gmatch(bag, "([^:,]+):(%d+)") do
			i += 1
			local index = i
			slot(bagGrid, i, "", id, tonumber(n), function()
				Net.event("Equip"):FireServer(index)
			end)
		end
	end
	local w = player:GetAttribute("Weight")
	weightLabel.Text = string.format("Weight %.1f / %d kg", typeof(w) == "number" and w or 0, Config.Weight.carry)
end

--- the loot window opens the backpack beside it (left of centre), like the web's inventory + loot pane
function Inventory.side(on: boolean)
	panel.AnchorPoint = if on then Vector2.new(0, 0.5) else Vector2.new(0.5, 0.5)
	panel.Position = if on then UDim2.new(0, 60, 0.5, 0) else UDim2.fromScale(0.5, 0.5)
end

function Inventory.toggle(on: boolean?)
	Inventory.open = if on == nil then not Inventory.open else on
	panel.Visible = Inventory.open
	PC.invOpen = Inventory.open
	UserInputService.MouseIconEnabled = Inventory.open
	render()
end

function Inventory.start()
	gui = Instance.new("ScreenGui")
	gui.Name = "Inventory"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.Parent = player:WaitForChild("PlayerGui")
	panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(560, 520)
	panel.BackgroundColor3 = Color3.fromRGB(44, 44, 58)
	panel.Name = "Panel"
	panel.Visible = false
	deco(panel, 16, 4)
	panel.Parent = gui
	local title = text(panel, "Backpack", 28)
	title.Position = UDim2.fromOffset(16, 8)
	weightLabel = text(panel, "", 18)
	weightLabel.TextXAlignment = Enum.TextXAlignment.Right
	weightLabel.Position = UDim2.new(0, -16, 0, 14)
	local eqTitle = text(panel, "Equipped", 18)
	eqTitle.Position = UDim2.fromOffset(16, 48)
	equipGrid = grid(panel, 76, 80)
	equipGrid.Name = "EquipGrid"
	local bagTitle = text(panel, "Carried  (click to equip or use)", 18)
	bagTitle.Position = UDim2.fromOffset(16, 166)
	bagGrid = grid(panel, 194, 320)
	bagGrid.Name = "BagGrid"
	player:GetAttributeChangedSignal("Bag"):Connect(render)
	player:GetAttributeChangedSignal("Equip"):Connect(render)
	-- Tab is the Roblox player list's key: the raid hides the core list (a squad panel replaces it later) so Tab opens the
	-- backpack like the web game; I is an alias
	pcall(function()
		game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
	game:GetService("ContextActionService"):BindActionAtPriority("BlockovInventory", function(_, state)
		if state == Enum.UserInputState.Begin then
			Inventory.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Tab, Enum.KeyCode.I)
	UserInputService.InputBegan:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.Escape and Inventory.open then
			Inventory.toggle(false)
		end
	end)
end

return Inventory
