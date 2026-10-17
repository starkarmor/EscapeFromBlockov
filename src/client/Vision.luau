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

type Tag = { gui: Frame, fill: Frame, lag: Frame, blink: Frame, pop: UIScale, bubble: Frame, root: BasePart, shown: boolean?, hp: number, lagF: number, lagHold: number, blinkT: number, popT: number, alertT: number }
local tags: { [Model]: Tag } = {}
-- WorldUI nameplates: name 20 over a 109x20 bar (dark .718; white lag; fill #FFE3C6, glow #FF4545); a hit blinks the bar
-- #FF5D5D for 0.1 s and pops it to 1.5x (0.25 s), the lag trails 0.35 s; "!" bubble for 1.6 s on entering combat
local plateGui = Instance.new("ScreenGui")
plateGui.Name = "Nameplates"
plateGui.IgnoreGuiInset = true
plateGui.ResetOnSpawn = false
plateGui.DisplayOrder = -1
plateGui.Parent = player:WaitForChild("PlayerGui")
local plateRoot = Instance.new("Frame")
plateRoot.BackgroundTransparency = 1
plateRoot.Size = UDim2.fromScale(1, 1)
plateRoot.Parent = plateGui
local plateScale = Instance.new("UIScale")
plateScale.Parent = plateRoot
local U = 0.5

local function rounded(f: GuiObject)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = f
end

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
	bb.Size = UDim2.fromOffset(0, 0)
	bb.Visible = false
	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.AnchorPoint = Vector2.new(0.5, 1)
	name.Position = UDim2.fromOffset(0, -26)
	name.AutomaticSize = Enum.AutomaticSize.X
	name.Size = UDim2.fromOffset(0, 24)
	name.FontFace = FONT
	name.TextSize = 20
	name.TextColor3 = Color3.fromRGB(255, 255, 255)
	name.Text = m.Name
	local st = Instance.new("UIStroke")
	st.Thickness = 2
	st.Color = Color3.new(0, 0, 0)
	st.Transparency = 0.35
	st.Parent = name
	name.Parent = bb
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Size = UDim2.fromOffset(109, 20)
	bar.BackgroundColor3 = Color3.new(0, 0, 0)
	bar.BackgroundTransparency = 0.282
	bar.ClipsDescendants = true
	rounded(bar)
	local pop = Instance.new("UIScale")
	pop.Parent = bar
	local lag = Instance.new("Frame")
	lag.Position = UDim2.fromOffset(6, 6)
	lag.Size = UDim2.fromOffset(97, 8)
	lag.BackgroundColor3 = Color3.new(1, 1, 1)
	rounded(lag)
	lag.Parent = bar
	local fill = Instance.new("Frame")
	fill.Position = UDim2.fromOffset(6, 6)
	fill.Size = UDim2.fromOffset(97, 8)
	fill.BackgroundColor3 = Color3.fromHex("#ffe3c6")
	rounded(fill)
	local gl = Instance.new("UIStroke")
	gl.Thickness = 1.5
	gl.Color = Color3.fromHex("#ff4545")
	gl.Parent = fill
	fill.Parent = bar
	local blink = Instance.new("Frame")
	blink.Size = UDim2.fromScale(1, 1)
	blink.BackgroundColor3 = Color3.fromHex("#ff5d5d")
	blink.BackgroundTransparency = 1
	rounded(blink)
	blink.Parent = bar
	bar.Parent = bb
	local bubble = Instance.new("TextLabel")
	bubble.AnchorPoint = Vector2.new(0.5, 1)
	bubble.Position = UDim2.fromOffset(0, -56)
	bubble.Size = UDim2.fromOffset(34, 38)
	bubble.BackgroundColor3 = Color3.new(1, 1, 1)
	bubble.FontFace = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Heavy)
	bubble.Text = "!"
	bubble.TextSize = 26
	bubble.TextColor3 = Color3.fromHex("#1e272e")
	bubble.Visible = false
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 17)
	bc.Parent = bubble
	bubble.Parent = bb
	bb.Parent = plateRoot
	t = { gui = bb, fill = fill, lag = lag, blink = blink, pop = pop, bubble = bubble :: any, root = root, hp = 1, lagF = 1, lagHold = 0, blinkT = 99, popT = 99, alertT = 99 }
	tags[m] = t
	m:GetAttributeChangedSignal("AlertAt"):Connect(function()
		local tt = tags[m]
		if tt then
			tt.alertT = 0
		end
		if m:GetAttribute("Kind") ~= "wolf" then
			require(script.Parent.Sfx).at("honk", root.Position / S, 35)
		end
	end)
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
			t.gui.Position = UDim2.fromOffset(sp.X / U, sp.Y / U)
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

local lastT = os.clock()
function Vision.update()
	local nowC = os.clock()
	local dt = math.min(0.1, nowC - lastT)
	lastT = nowC
	local vpS = Workspace.CurrentCamera.ViewportSize
	U = math.min(vpS.X / 2560, vpS.Y / 1440)
	plateScale.Scale = U
	plateRoot.Size = UDim2.fromOffset(vpS.X / U, vpS.Y / U)
	for _, t in tags do
		t.blinkT += dt
		t.popT += dt
		t.alertT += dt
		if t.lagHold > 0 then
			t.lagHold -= dt
		else
			t.lagF = math.max(t.hp, t.lagF - 1.5 * dt)
		end
		t.lagF = math.max(t.lagF, t.hp)
		t.lag.Size = UDim2.fromOffset(97 * t.lagF, 8)
		t.blink.BackgroundTransparency = if t.blinkT < 0.1 then t.blinkT / 0.1 else 1
		t.pop.Scale = if t.popT < 0.25 then 1 + 0.5 * (1 - t.popT / 0.25) else 1
		t.bubble.Visible = t.alertT < 1.6
	end
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
				local f = math.clamp(hp / max, 0, 1)
				if f < t.hp - 1e-4 then
					t.blinkT, t.popT, t.lagHold = 0, 0, 0.35
				end
				t.hp = f
				t.fill.Size = UDim2.fromOffset(97 * f, 8)
				t.fill.BackgroundColor3 = Color3.fromRGB(255, 132, 119):Lerp(Color3.fromRGB(255, 227, 198), f)
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
-- view cone dims). One flat part under the beaver carries a SurfaceGui disc; the dark sector outside the cone is cut
-- from two clipped halves with stepped gradients (exact sector, no triangle seams), turned to the facing.
local FAN_R = 40 -- metres
local fanPart: Part? = nil
local fanHalves: { UIGradient } = {}

local function buildFan()
	local part = Instance.new("Part")
	part.Name = "VisionFan"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(FAN_R * 2 * S, 0.05, FAN_R * 2 * S)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top
	sg.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	sg.CanvasSize = Vector2.new(1024, 1024)
	sg.LightInfluence = 0
	sg.AlwaysOnTop = false
	sg.Parent = part
	for i = 1, 2 do
		local right = i == 1
		local clip = Instance.new("Frame")
		clip.BackgroundTransparency = 1
		clip.ClipsDescendants = true
		clip.Size = UDim2.fromOffset(512, 1024)
		clip.Position = UDim2.fromOffset(if right then 512 else 0, 0)
		clip.Parent = sg
		local disc = Instance.new("Frame")
		disc.BorderSizePixel = 0
		disc.BackgroundColor3 = Color3.fromRGB(16, 18, 40)
		disc.BackgroundTransparency = 0.5
		disc.Size = UDim2.fromOffset(1024, 1024)
		disc.Position = UDim2.fromOffset(if right then -512 else 0, 0)
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(1, 0)
		c.Parent = disc
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.499, 0), NumberSequenceKeypoint.new(0.5, 1), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = disc
		disc.Parent = clip
		fanHalves[i] = g
	end
	part.Parent = Workspace:FindFirstChild("LocalFx") or Workspace
	fanPart = part
end

function Vision.fan(alive: boolean)
	if not fanPart then
		buildFan()
	end
	local part = fanPart :: Part
	if not alive then
		part.Parent = nil
		return
	end
	part.Parent = Workspace:FindFirstChild("LocalFx") or Workspace
	local V = Config.View
	local nm = if night() then V.nightMul else { 1, 1, 1 }
	local cone = V.angle * nm[1]
	-- dark fraction clockwise from the gui top, starting at the cone's clockwise edge
	local p = (360 - cone) / 360
	fanHalves[1].Rotation = math.min(p, 0.5) * 360
	fanHalves[2].Rotation = 180 + math.max(0, p - 0.5) * 360
	-- measured in Studio: this turn puts the lit sector on the facing (checked with the cursor right and up-left)
	local yaw = PC.facing
	part.CFrame = CFrame.new(PC.pos.X * S, 0.08 * S, PC.pos.Y * S) * CFrame.Angles(0, yaw + math.pi / 2 - math.rad(cone / 2), 0)
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
