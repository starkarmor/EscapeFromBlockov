--!strict
-- F to interact (the web's prompt + hold progress) and the loot window: container slots that reveal one by one while
-- searching, click a revealed item to take it, the backpack beside it. Interact points come from MapData plus server-made
-- boxes (corpses) published as Workspace attributes "Box_<id>"; their props carry a "Box" attribute.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local MapData = require(Shared.MapData)
local PC = require(script.Parent.PlayerControl)
local Hud = require(script.Parent.Hud)

local player = Players.LocalPlayer
local S = Units.S
local Interact = {}

local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json")
local INK = Color3.fromRGB(22, 21, 29)
local WHITE = Color3.fromRGB(255, 248, 233)
local QCOL = { [0] = Color3.fromRGB(150, 150, 160), Color3.fromRGB(230, 230, 230), Color3.fromRGB(128, 222, 37), Color3.fromRGB(19, 160, 244), Color3.fromRGB(153, 56, 242), Color3.fromRGB(255, 216, 61), Color3.fromRGB(243, 69, 67) }

type Point = { id: string, kind: string, label: string, x: number, z: number, r: number, hold: number }
local points: { [string]: Point } = {}
local current: Point? = nil
local openBox: string? = nil

local LABEL = { container = "Search", corpse = "Search", hatch = "Enter Bunker", teleport = "Go", loader = "Enter" }

local function refreshPoints()
	for _, it in MapData.interacts do
		if it.kind == "hatch" or (it.kind == "teleport" and it.label == "Go") or it.kind == "loader" then
			points[it.id] = { id = it.id, kind = it.kind, label = it.label, x = it.x, z = it.z, r = math.max(it.r or 1.8, 1.8), hold = it.hold or 0 }
		end
	end
end

local function trackProp(p: Instance)
	local id = p:GetAttribute("Box")
	if typeof(id) == "string" and p:IsA("BasePart") then
		local kind = if string.find(p.Name, "Remains") or p.Name == "corpse" then "corpse" else "container"
		points[id] = { id = id, kind = kind, label = p.Name, x = p.Position.X / S, z = p.Position.Z / S, r = 1.8, hold = 0 }
		p.AncestryChanged:Connect(function()
			if not p.Parent then
				points[id] = nil
			end
		end)
	end
end

-- ------------------------------------------------------------------ loot window
local gui: ScreenGui
local panel: Frame
local boxGrid: Frame
local bagGrid: Frame
local title: TextLabel

local function stroke(o: Instance, t: number)
	local s = Instance.new("UIStroke")
	s.Thickness = t
	s.Color = INK
	s.ApplyStrokeMode = if o:IsA("TextLabel") or o:IsA("TextButton") then Enum.ApplyStrokeMode.Contextual else Enum.ApplyStrokeMode.Border
	s.Parent = o
end

local function corner(o: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = o
end

local function grid(parent: Instance, y: number): Frame
	local f = Instance.new("Frame")
	f.BackgroundTransparency = 1
	f.Position = UDim2.fromOffset(16, y)
	f.Size = UDim2.new(1, -32, 0, 150)
	f.Parent = parent
	local g = Instance.new("UIGridLayout")
	g.CellSize = UDim2.fromOffset(84, 70)
	g.CellPadding = UDim2.fromOffset(8, 8)
	g.SortOrder = Enum.SortOrder.LayoutOrder
	g.Parent = f
	return f
end

local function buildUi()
	gui = Instance.new("ScreenGui")
	gui.Name = "Loot"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = player:WaitForChild("PlayerGui")
	panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(1, 0.5)
	panel.Position = UDim2.new(1, -24, 0.5, 0)
	panel.Size = UDim2.fromOffset(500, 420)
	panel.BackgroundColor3 = Color3.fromRGB(44, 44, 58)
	panel.Visible = false
	corner(panel, 16)
	stroke(panel, 4)
	panel.Parent = gui
	title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.FontFace = FONT
	title.TextSize = 26
	title.TextColor3 = WHITE
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Position = UDim2.fromOffset(16, 8)
	title.Size = UDim2.new(1, -32, 0, 34)
	stroke(title, 2.5)
	title.Parent = panel
	boxGrid = grid(panel, 48)
	local bagTitle = title:Clone()
	bagTitle.Text = "Backpack"
	bagTitle.TextSize = 20
	bagTitle.Position = UDim2.fromOffset(16, 206)
	bagTitle.Parent = panel
	bagGrid = grid(panel, 240)
end

local function slot(parent: Instance, i: number, it: any, onClick: (() -> ())?)
	local b = Instance.new("TextButton")
	b.LayoutOrder = i
	b.AutoButtonColor = onClick ~= nil
	b.Text = ""
	b.BackgroundColor3 = if it.hidden then Color3.fromRGB(30, 30, 40) else Color3.fromHex(it.color or "#888888"):Lerp(Color3.fromRGB(44, 44, 58), 0.45)
	corner(b, 10)
	stroke(b, 3)
	local st = b:FindFirstChildOfClass("UIStroke") :: UIStroke
	st.Color = if it.hidden then INK else (QCOL[it.q or 0] or INK)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.FontFace = FONT
	t.TextScaled = true
	t.TextColor3 = WHITE
	t.Text = if it.hidden then "?" else it.name
	t.Size = UDim2.new(1, -8, 0.62, 0)
	t.Position = UDim2.fromOffset(4, 4)
	stroke(t, 1.5)
	t.Parent = b
	if not it.hidden and (it.n or 1) > 1 then
		local n = t:Clone()
		n.TextScaled = false
		n.TextSize = 16
		n.Text = "x" .. it.n
		n.TextXAlignment = Enum.TextXAlignment.Right
		n.Position = UDim2.new(0, 4, 1, -22)
		n.Size = UDim2.new(1, -10, 0, 18)
		n.Parent = b
	end
	if onClick then
		b.MouseButton1Click:Connect(onClick)
	end
	b.Parent = parent
end

local function clear(f: Frame)
	for _, c in f:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
end

local function render(id: string, label: string, items: { any }, bag: { any })
	panel.Visible = true
	title.Text = label
	clear(boxGrid)
	clear(bagGrid)
	for i, it in items do
		slot(boxGrid, i, it, if it.hidden then nil else function()
			Net.event("LootTake"):FireServer(id, i)
		end)
	end
	for i, it in bag do
		slot(bagGrid, i, it, nil)
	end
	UserInputService.MouseIconEnabled = true
end

local function closeUi()
	panel.Visible = false
	openBox = nil
	UserInputService.MouseIconEnabled = false
end

-- ------------------------------------------------------------------ loop
function Interact.update(_dt: number)
	local best, bd = nil :: Point?, math.huge
	for _, pt in points do
		local d = (Vector2.new(pt.x, pt.z) - PC.pos).Magnitude
		if d <= pt.r and d < bd then
			best, bd = pt, d
		end
	end
	current = best
	local holdId = player:GetAttribute("HoldId")
	if best and not openBox then
		Hud.setPrompt(best.label ~= "" and best.kind ~= "container" and best.label or LABEL[best.kind] or "Use", Vector3.new(best.x, 1.0, best.z))
	else
		Hud.setPrompt(nil, nil)
	end
	if typeof(holdId) == "string" then
		local t0 = player:GetAttribute("HoldStart")
		local dur = player:GetAttribute("HoldTime")
		local pt = points[holdId]
		if typeof(t0) == "number" and typeof(dur) == "number" and pt then
			Hud.setProgress((Workspace:GetServerTimeNow() - t0) / dur, Vector3.new(PC.pos.X, 1, PC.pos.Y))
		end
	else
		Hud.setProgress(nil, nil)
	end
	PC.blocked = openBox ~= nil
end

function Interact.start()
	refreshPoints()
	buildUi()
	local lootFolder = Workspace:WaitForChild("Loot", 10)
	if lootFolder then
		for _, p in lootFolder:GetChildren() do
			trackProp(p)
		end
		lootFolder.ChildAdded:Connect(trackProp)
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.F then
			if openBox then
				Net.event("InteractCancel"):FireServer()
				closeUi()
			elseif current then
				Net.event("Interact"):FireServer(current.id)
			end
		elseif input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.Tab then
			if openBox then
				Net.event("InteractCancel"):FireServer()
				closeUi()
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F and player:GetAttribute("HoldId") then
			Net.event("InteractCancel"):FireServer()
		end
	end)
	Net.event("LootOpen").OnClientEvent:Connect(function(id: string?, label: any, items: any, bag: any)
		if id == nil then
			closeUi()
			return
		end
		if id == "bag" then
			return
		end
		openBox = id
		render(id, label, items, bag)
	end)
end

return Interact
