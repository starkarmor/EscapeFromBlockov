--!strict
-- The map screen (M: MiniMapView, src/ui/MapUI.ts; spec docs/weather-night-enemies-spec.md §4). The web renders the static
-- map once from 120 m above at noon; here the client casts rays straight down over the map bounds into an EditableImage
-- (one pass, spread over frames). Fit = min(W x 0.84 / bw, H x 0.72 / bh), zoom 1-4 (wheel x1.15 around the cursor),
-- drag pans. Shown: region names, this raid's exits (green ring + dot + label chip, the hatch "Bunker Entry"), the player
-- (yellow triangle), user markers (right-click places / removes). Not shown: enemies, loot, the fog of war.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local MapData = require(Shared.MapData)
local PC = require(script.Parent.PlayerControl)

local S = Units.S
local MapUI = {}
MapUI.open = false

local player = Players.LocalPlayer
local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Heavy)
local B = MapData.bounds
local BW, BH = B.maxX - B.minX, B.maxZ - B.minZ
local RES = 0.75 -- metres per pixel
local IW, IH = math.ceil(BW / RES), math.ceil(BH / RES)

local gui = Instance.new("ScreenGui")
gui.Name = "MapScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 30
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")
local bg = Instance.new("Frame")
bg.Size = UDim2.fromScale(1, 1)
bg.BackgroundColor3 = Color3.fromHex("#041522")
bg.BackgroundTransparency = 0.12
bg.BorderSizePixel = 0
bg.Parent = gui
local viewport = Instance.new("Frame")
viewport.Size = UDim2.fromScale(1, 1)
viewport.BackgroundTransparency = 1
viewport.ClipsDescendants = true
viewport.Parent = bg
local mapFrame = Instance.new("ImageLabel")
mapFrame.Name = "Map"
mapFrame.BackgroundColor3 = Color3.fromHex("#1c2228")
mapFrame.BorderSizePixel = 0
mapFrame.ScaleType = Enum.ScaleType.Stretch
mapFrame.ResampleMode = Enum.ResamplerMode.Default
mapFrame.Parent = viewport
local overlay = Instance.new("Frame")
overlay.Name = "Marks"
overlay.BackgroundTransparency = 1
overlay.Size = UDim2.fromScale(1, 1)
overlay.Parent = mapFrame
local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 60, 0, 40)
title.Size = UDim2.fromOffset(800, 80)
title.TextXAlignment = Enum.TextXAlignment.Left
title.FontFace = FONT
title.TextColor3 = Color3.fromHex("#f4f1e6")
title.TextSize = 64
title.Text = MapData.name or "Ground Zero"
title.Parent = bg
local sub = title:Clone()
sub.Position = UDim2.new(0, 64, 0, 112)
sub.TextSize = 28
sub.Text = ""
sub.Parent = bg
local hint = title:Clone()
hint.AnchorPoint = Vector2.new(1, 1)
hint.Position = UDim2.new(1, -40, 1, -30)
hint.TextXAlignment = Enum.TextXAlignment.Right
hint.TextSize = 22
hint.Text = "Wheel: zoom   Drag: pan   Right-click: marker   M: close"
hint.Parent = bg

local zoom, pan = 1, Vector2.zero
local built = false
local building = false
local markers: { { x: number, z: number, ui: Frame } } = {}

local function worldToMap(x: number, z: number): UDim2
	return UDim2.fromScale((x - B.minX) / BW, (z - B.minZ) / BH)
end

local function chip(parent: Instance, text: string, color: Color3?): TextLabel
	local t = Instance.new("TextLabel")
	t.AnchorPoint = Vector2.new(0.5, 0)
	t.Position = UDim2.new(0.5, 0, 1, 4)
	t.AutomaticSize = Enum.AutomaticSize.X
	t.Size = UDim2.fromOffset(0, 30)
	t.BackgroundColor3 = Color3.new(0, 0, 0)
	t.BackgroundTransparency = 0.694
	t.FontFace = FONT
	t.TextSize = 24
	t.TextColor3 = color or Color3.new(1, 1, 1)
	t.Text = " " .. text .. " "
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = t
	t.Parent = parent
	return t
end

local function ring(parent: Instance, at: UDim2, r: number, color: Color3, dot: number?): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = at
	f.Size = UDim2.fromOffset(r * 2, r * 2)
	f.BackgroundTransparency = 1
	local st = Instance.new("UIStroke")
	st.Color = color
	st.Thickness = 3
	st.Parent = f
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = f
	if dot then
		local d = Instance.new("Frame")
		d.AnchorPoint = Vector2.new(0.5, 0.5)
		d.Position = UDim2.fromScale(0.5, 0.5)
		d.Size = UDim2.fromOffset(dot * 2, dot * 2)
		d.BackgroundColor3 = color
		local dc = Instance.new("UICorner")
		dc.CornerRadius = UDim.new(1, 0)
		dc.Parent = d
		d.Parent = f
	end
	f.Parent = parent
	return f
end

local playerMark: ImageLabel
local function buildMarks()
	for _, rg in MapData.regions or {} do
		local t = Instance.new("TextLabel")
		t.AnchorPoint = Vector2.new(0.5, 0.5)
		t.Position = worldToMap(rg.x, rg.z)
		t.Size = UDim2.fromOffset(300, 40)
		t.BackgroundTransparency = 1
		t.FontFace = FONT
		t.TextSize = 30
		t.TextColor3 = Color3.fromHex("#f4f1e6")
		t.Text = rg.name
		local st = Instance.new("UIStroke")
		st.Thickness = 4
		st.Transparency = 0.35
		st.Parent = t
		t.Parent = overlay
	end
	local green = Color3.fromHex("#46e08c")
	for _, ex in MapData.exits or {} do
		local f = ring(overlay, worldToMap(ex.x, ex.z), 10, green, 4)
		chip(f, ex.label or "Exit")
	end
	for _, it in MapData.interacts or {} do
		if it.kind == "hatch" and not it.flag then
			local f = ring(overlay, worldToMap(it.x, it.z), 10, green, 4)
			chip(f, "Bunker Entry")
		end
	end
	-- the player: a yellow triangle with a black outline
	playerMark = Instance.new("ImageLabel")
	playerMark.AnchorPoint = Vector2.new(0.5, 0.5)
	playerMark.Size = UDim2.fromOffset(30, 30)
	playerMark.BackgroundTransparency = 1
	playerMark.Image = "rbxasset://textures/ui/Controls/TouchTapIcon.png"
	playerMark.ImageTransparency = 1
	local tri = Instance.new("TextLabel")
	tri.BackgroundTransparency = 1
	tri.Size = UDim2.fromScale(1, 1)
	tri.Text = "▲"
	tri.TextScaled = true
	tri.TextColor3 = Color3.fromHex("#ffd23f")
	tri.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
	local st = Instance.new("UIStroke")
	st.Thickness = 2
	st.Parent = tri
	tri.Parent = playerMark
	playerMark.ZIndex = 5
	playerMark.Parent = overlay
end

--- the top-down render: rays straight down per pixel, the hit part's colour shaded by height
local function build()
	if built or building then
		return
	end
	building = true
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(IW, IH) })
	end)
	if not ok or not img then
		warn("[Blockov] map image unavailable: " .. tostring(img))
		building = false
		return
	end
	local buf = buffer.create(IW * IH * 4)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excl = {}
	for _, n in { "Characters", "LocalFx", "Grenades" } do
		local f = Workspace:FindFirstChild(n)
		if f then
			table.insert(excl, f)
		end
	end
	params.FilterDescendantsInstances = excl
	local down = Vector3.new(0, -120 * S, 0)
	local t0 = os.clock()
	for y = 0, IH - 1 do
		local z = B.minZ + (y + 0.5) * RES
		for x = 0, IW - 1 do
			local wx = B.minX + (x + 0.5) * RES
			-- invisible colliders (rock grid, foliage sight volumes, trunk stand-ins) are not drawn: cast on through them
			local from = Vector3.new(wx * S, 60 * S, z * S)
			local hit = Workspace:Raycast(from, down, params)
			for _ = 1, 4 do
				if not hit or (hit.Instance :: BasePart).Transparency < 0.99 then
					break
				end
				from = hit.Position - Vector3.new(0, 0.05, 0)
				hit = Workspace:Raycast(from, down, params)
			end
			local c = Color3.fromHex("#1c2228")
			if hit then
				local inst = hit.Instance :: BasePart
				c = inst.Color
				local h = hit.Position.Y / S
				local k = math.clamp(0.82 + h * 0.06, 0.6, 1.15)
				c = Color3.new(math.min(1, c.R * k), math.min(1, c.G * k), math.min(1, c.B * k))
			end
			local o = (y * IW + x) * 4
			buffer.writeu8(buf, o, math.floor(c.R * 255))
			buffer.writeu8(buf, o + 1, math.floor(c.G * 255))
			buffer.writeu8(buf, o + 2, math.floor(c.B * 255))
			buffer.writeu8(buf, o + 3, 255)
		end
		if os.clock() - t0 > 0.008 then
			task.wait()
			t0 = os.clock()
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(IW, IH), buf)
	mapFrame.ImageContent = Content.fromObject(img)
	built = true
	building = false
end

local function layout()
	local vp = (Workspace.CurrentCamera :: Camera).ViewportSize
	local fit = math.min(vp.X * 0.84 / BW, vp.Y * 0.72 / BH)
	local w, h = BW * fit * zoom, BH * fit * zoom
	mapFrame.Size = UDim2.fromOffset(w, h)
	mapFrame.Position = UDim2.fromOffset(vp.X / 2 - w / 2 + pan.X, vp.Y / 2 - h / 2 + pan.Y)
end

local function nearestRegion(x: number, z: number): string
	local best, bd = "", math.huge
	for _, rg in MapData.regions or {} do
		local d = (rg.x - x) ^ 2 + (rg.z - z) ^ 2
		if d < bd then
			bd, best = d, rg.name
		end
	end
	return best
end

function MapUI.toggle(on: boolean?)
	MapUI.open = if on == nil then not MapUI.open else on
	gui.Enabled = MapUI.open
	PC.mapOpen = MapUI.open
	UserInputService.MouseIconEnabled = MapUI.open
	if MapUI.open then
		if not playerMark then
			buildMarks()
		end
		task.spawn(build)
		zoom, pan = 1, Vector2.zero
		layout()
	end
end

local dragging = false
local dragFrom = Vector2.zero
local panFrom = Vector2.zero

function MapUI.start()
	ContextActionService:BindActionAtPriority("BlockovMap", function(_, state)
		if state == Enum.UserInputState.Begin then
			MapUI.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.M)
	UserInputService.InputBegan:Connect(function(input)
		if not MapUI.open then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			MapUI.toggle(false)
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = true
			dragFrom = Vector2.new(input.Position.X, input.Position.Y)
			panFrom = pan
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			-- user marker: right-click places, right-click on one removes it
			local abs, size = mapFrame.AbsolutePosition, mapFrame.AbsoluteSize
			local m = Vector2.new(input.Position.X, input.Position.Y)
			local u = (m - abs) / size
			if u.X < 0 or u.Y < 0 or u.X > 1 or u.Y > 1 then
				return
			end
			local wx, wz = B.minX + u.X * BW, B.minZ + u.Y * BH
			for i, mk in markers do
				if (Vector2.new(mk.x, mk.z) - Vector2.new(wx, wz)).Magnitude < 4 / zoom then
					mk.ui:Destroy()
					table.remove(markers, i)
					return
				end
			end
			local f = ring(overlay, worldToMap(wx, wz), 9, Color3.fromHex("#f85566"), 4)
			table.insert(markers, { x = wx, z = wz, ui = f })
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			dragging = false
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if not MapUI.open then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			local m = Vector2.new(input.Position.X, input.Position.Y)
			local old = zoom
			zoom = math.clamp(zoom * (if input.Position.Z > 0 then 1.15 else 1 / 1.15), 1, 4)
			-- zoom around the cursor
			local vp = (Workspace.CurrentCamera :: Camera).ViewportSize
			local c = vp / 2 + pan
			pan += (c - m) * (zoom / old - 1)
			layout()
		elseif input.UserInputType == Enum.UserInputType.MouseMovement and dragging then
			pan = panFrom + (Vector2.new(input.Position.X, input.Position.Y) - dragFrom)
			layout()
		end
	end)
	RunService.RenderStepped:Connect(function()
		if not MapUI.open or not playerMark then
			return
		end
		playerMark.Position = worldToMap(PC.pos.X, PC.pos.Y)
		-- facing atan2(x, z): map +x right, +z down; the triangle points up at rotation 0 (-z)
		playerMark.Rotation = 180 - math.deg(PC.facing)
		sub.Text = nearestRegion(PC.pos.X, PC.pos.Y)
		layout()
	end)
end

return MapUI
