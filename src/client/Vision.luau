--!strict
-- Fog of war (World.ts VIEW): an enemy shows only inside the player's 100 deg view cone within 37 m, or within the 1.5 m
-- bubble, with a clear line of sight from eye height (QSight: walls and foliage that block sight). Night narrows it
-- (x0.4 angle and distance, x0.5 bubble). Visible enemies carry the web's name + red health bar overhead.
-- Also answers "is the cursor on an enemy head" (InputManager.AimingEnemyHead -> crit).
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Units = require(Shared.Units)
local PC = require(script.Parent.PlayerControl)

local S = Units.S
local Vision = {}
local player = Players.LocalPlayer
local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json")

local params = RaycastParams.new()
params.CollisionGroup = "QSight"
params.FilterType = Enum.RaycastFilterType.Exclude

type Tag = { gui: Frame, fill: Frame, root: BasePart, shown: boolean? }
local tags: { [Model]: Tag } = {}
-- screen-projected name + health plates (the web's DOM overlays), one ScreenGui for all
local plateGui = Instance.new("ScreenGui")
plateGui.Name = "Nameplates"
plateGui.IgnoreGuiInset = true
plateGui.ResetOnSpawn = false
plateGui.DisplayOrder = -1
plateGui.Parent = player:WaitForChild("PlayerGui")

local function tagFor(m: Model): Tag?
	local t = tags[m]
	if t then
		return t
	end
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local bb = Instance.new("Frame")
	bb.BackgroundTransparency = 1
	bb.AnchorPoint = Vector2.new(0.5, 1)
	bb.Size = UDim2.fromOffset(120, 34)
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Size = UDim2.new(1, 0, 0, 16)
	name.FontFace = FONT
	name.TextSize = 14
	name.TextColor3 = Color3.fromRGB(255, 248, 233)
	name.Text = m.Name
	local st = Instance.new("UIStroke")
	st.Thickness = 2
	st.Color = Color3.fromRGB(22, 21, 29)
	st.Parent = name
	name.Parent = bb
	local bar = Instance.new("Frame")
	bar.Position = UDim2.new(0.5, -27, 0, 19)
	bar.Size = UDim2.fromOffset(54, 8)
	bar.BackgroundColor3 = Color3.fromRGB(40, 20, 24)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 4)
	c.Parent = bar
	local bs = Instance.new("UIStroke")
	bs.Thickness = 2
	bs.Color = Color3.fromRGB(22, 21, 29)
	bs.Parent = bar
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(243, 69, 67)
	local c2 = c:Clone()
	c2.Parent = fill
	fill.Parent = bar
	bar.Parent = bb
	bb.Visible = false
	bb.Parent = plateGui
	t = { gui = bb, fill = fill, root = root }
	m:GetAttributeChangedSignal("AlertAt"):Connect(function()
		local kind = m:GetAttribute("Kind")
		if kind ~= "wolf" then
			require(script.Parent.Sfx).at("honk", root.Position / S, 35)
		end
	end)
	tags[m] = t
	return t
end

local function setVisible(m: Model, on: boolean)
	local t = tagFor(m)
	local want = if on then 0 else 1
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.LocalTransparencyModifier ~= want then
			d.LocalTransparencyModifier = want
		end
	end
	if t then
		t.shown = on
		local show = on and not m:GetAttribute("Dead")
		if show then
			local sp, inView = Workspace.CurrentCamera:WorldToViewportPoint(t.root.Position + Vector3.new(0, 1.35 * S, 0))
			show = inView
			t.gui.Position = UDim2.fromOffset(sp.X, sp.Y)
		end
		t.gui.Visible = show
	end
end

local function night(): boolean
	local secs = player:GetAttribute("RaidClock")
	if typeof(secs) ~= "number" then
		return false
	end
	local h = (Config.Clock.start + secs * Config.Clock.scale / 3600) % 24
	return h >= 22 or h < 6
end

function Vision.update()
	local folder = Workspace:FindFirstChild("Characters")
	if not folder then
		return
	end
	local me = player.Character
	params.FilterDescendantsInstances = { folder }
	local V = Config.View
	local nm = if night() then V.nightMul else { 1, 1, 1 }
	local half = math.rad(V.angle * nm[1] / 2)
	local dist = V.dist * nm[2]
	local bubble = V.bubble * nm[3]
	local eye = Vector3.new(PC.pos.X, V.eye, PC.pos.Y)
	for _, m in folder:GetChildren() do
		if not m:IsA("Model") or m == me or not m:GetAttribute("Enemy") then
			continue
		end
		local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			continue
		end
		local p = Vector2.new(root.Position.X / S, root.Position.Z / S)
		local d = p - PC.pos
		local len = d.Magnitude
		local vis = false
		if len <= bubble then
			vis = true
		elseif len <= dist then
			local ang = math.atan2(d.X, d.Y)
			local off = math.abs(math.atan2(math.sin(ang - PC.facing), math.cos(ang - PC.facing)))
			if off <= half then
				local to = Vector3.new(p.X, V.eye, p.Y)
				vis = Workspace:Raycast(eye * S, (to - eye) * S, params) == nil
			end
		end
		if m:GetAttribute("Dead") then
			vis = true
		end
		setVisible(m, vis)
		local t = tags[m]
		if t then
			local hp, max = m:GetAttribute("HP"), m:GetAttribute("MaxHP")
			if typeof(hp) == "number" and typeof(max) == "number" then
				t.fill.Size = UDim2.fromScale(math.clamp(hp / max, 0, 1), 1)
			end
		end
	end
	for m, t in tags do
		if not m.Parent then
			t.gui:Destroy()
			tags[m] = nil
		end
	end
end

-- ------------------------------------------------------------------ vision fan (VisionFan.ts: the ground outside the
-- view cone darkens). A disc of triangle sectors around the beaver; sectors inside the cone are clear.
local FAN_N = 72
local FAN_R = 40 -- metres (beyond the visible screen at the 45 m arm)
local fanModel: Model? = nil
local sectors: { { a: WedgePart, b: WedgePart, ang: number } } = {}

local function triangle(w1: WedgePart, w2: WedgePart, a: Vector3, b: Vector3, c: Vector3)
	-- the standard two-wedge triangle (a, b, c in studs)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local right = ac:Cross(ab).Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	w1.Size = Vector3.new(0.05, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
	w2.Size = Vector3.new(0.05, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
end

local function buildFan()
	local m = Instance.new("Model")
	m.Name = "VisionFan"
	local function wedge(): WedgePart
		local w = Instance.new("WedgePart")
		w.Anchored = true
		w.CanCollide = false
		w.CanQuery = false
		w.CanTouch = false
		w.CastShadow = false
		w.Material = Enum.Material.SmoothPlastic
		w.Color = Color3.fromRGB(16, 18, 40)
		w.Transparency = 0.5
		w.Parent = m
		return w
	end
	local y = 0.06 * S
	for i = 1, FAN_N do
		local a0 = (i - 1) / FAN_N * math.pi * 2
		local a1 = i / FAN_N * math.pi * 2
		local w1, w2 = wedge(), wedge()
		local c = Vector3.new(0, y, 0)
		local p0 = Vector3.new(math.sin(a0) * FAN_R * S, y, math.cos(a0) * FAN_R * S)
		local p1 = Vector3.new(math.sin(a1) * FAN_R * S, y, math.cos(a1) * FAN_R * S)
		triangle(w1, w2, c, p0, p1)
		table.insert(sectors, { a = w1, b = w2, ang = (a0 + a1) / 2 })
	end
	local pivot = Instance.new("Part")
	pivot.Name = "Pivot"
	pivot.Anchored = true
	pivot.CanCollide = false
	pivot.CanQuery = false
	pivot.Transparency = 1
	pivot.Size = Vector3.one * 0.1
	pivot.CFrame = CFrame.new()
	pivot.Parent = m
	m.PrimaryPart = pivot
	m.Parent = Workspace:FindFirstChild("LocalFx") or Workspace
	fanModel = m
end

function Vision.fan(alive: boolean)
	if not fanModel then
		buildFan()
	end
	local m = fanModel :: Model
	if not alive then
		m.Parent = nil
		return
	end
	m.Parent = Workspace:FindFirstChild("LocalFx") or Workspace
	local V = Config.View
	local nm = if night() then V.nightMul else { 1, 1, 1 }
	local half = math.rad(V.angle * nm[1] / 2)
	m:PivotTo(CFrame.new(PC.pos.X * S, 0, PC.pos.Y * S))
	for _, sc in sectors do
		local off = math.abs(math.atan2(math.sin(sc.ang - PC.facing), math.cos(sc.ang - PC.facing)))
		local t = if off <= half then 1 else 0.5
		if sc.a.Transparency ~= t then
			sc.a.Transparency = t
			sc.b.Transparency = t
		end
	end
end

--- the enemy head under a viewport point, if any (ray vs each visible enemy's Head part box)
function Vision.headUnder(px: number, py: number): Model?
	local cam = Workspace.CurrentCamera
	local ray = cam:ViewportPointToRay(px, py)
	local folder = Workspace:FindFirstChild("Characters")
	if not folder then
		return nil
	end
	for _, m in folder:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("Enemy") and not m:GetAttribute("Dead") then
			local t = tags[m]
			local head = m:FindFirstChild("Head") :: BasePart?
			if head and t and t.shown then
				local o = head.CFrame:PointToObjectSpace(ray.Origin)
				local dir = head.CFrame:VectorToObjectSpace(ray.Direction)
				local h = head.Size / 2 * 1.15
				local tmin, tmax = -math.huge, math.huge
				local hit = true
				for _, ax in { "X", "Y", "Z" } do
					local oo, dd, hh = (o :: any)[ax], (dir :: any)[ax], (h :: any)[ax]
					if math.abs(dd) < 1e-9 then
						if math.abs(oo) > hh then
							hit = false
						end
					else
						local t1, t2 = (-hh - oo) / dd, (hh - oo) / dd
						tmin = math.max(tmin, math.min(t1, t2))
						tmax = math.min(tmax, math.max(t1, t2))
					end
				end
				if hit and tmax >= math.max(tmin, 0) then
					return m
				end
			end
		end
	end
	return nil
end

return Vision
