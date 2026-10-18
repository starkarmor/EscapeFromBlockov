--!strict
-- The world clock and weather drive Lighting locally (Game.ts lighting, spec docs/weather-night-enemies-spec.md §2.3):
--   k = clamp(sin((hour - 5.5) / 15 pi), 0, 1); sun colour lerp(#ffb070, #fff3d6, min(1, 1.6 k)) by day, #8fa6d8 at night;
--   sun intensity (0.4 + 2 k by day, 0.35 at night) x 0.5 in a storm; sky / hemisphere #fff6e0 day, #6d7fae night at
--   (0.55 + 0.95 k) x 0.6 in a storm; storm sky #5a4a72 with fog 19..56 m from the camera. Rain: 220 screen streaks
--   (700-1200 px/s, drifting left 0.15, rgba(190,210,235,.35)), faded in over 1.5 s. Storm: the purple screen tint
--   rgba(120,60,170,.22) with a 2 s fade.
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local DayNight = {}
local player = Players.LocalPlayer

local function hex(h: string): Color3
	return Color3.fromHex(h)
end

-- screen layers
local gui = Instance.new("ScreenGui")
gui.Name = "Weather"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = -5
gui.Parent = player:WaitForChild("PlayerGui")
local tint = Instance.new("Frame")
tint.Size = UDim2.fromScale(1, 1)
tint.BackgroundColor3 = Color3.fromRGB(120, 60, 170)
tint.BackgroundTransparency = 1
tint.BorderSizePixel = 0
tint.Parent = gui
local rainLayer = Instance.new("Frame")
rainLayer.Size = UDim2.fromScale(1, 1)
rainLayer.BackgroundTransparency = 1
rainLayer.Parent = gui
type Streak = { f: Frame, x: number, y: number, v: number }
local streaks: { Streak } = {}
local rainAlpha = 0
local tintAlpha = 0

local function makeStreaks(w: number, h: number)
	for _ = 1, 220 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.fromRGB(190, 210, 235)
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		-- the line (x, y) -> (x + 3, y - 14): 14.3 px long, tilted 12 deg
		f.Size = UDim2.fromOffset(1, 14.3)
		f.Rotation = 12
		f.Parent = rainLayer
		table.insert(streaks, { f = f, x = math.random() * (w + 100), y = math.random() * h, v = 700 + math.random() * 500 })
	end
end

local function lerpC(a: Color3, b: Color3, t: number): Color3
	return a:Lerp(b, math.clamp(t, 0, 1))
end

function DayNight.update(dt: number?)
	local step = dt or 1 / 60
	local cm = Workspace:GetAttribute("ClockMin")
	if typeof(cm) ~= "number" then
		return
	end
	local hour = (cm / 60) % 24
	local storm = (Workspace:GetAttribute("StormPhase") or 0) > 0
	-- the cave (an indoor sub-scene): hemisphere #8a9cb0 / #1a1f24 at 0.6, no sun, fog, no rain or storm tint
	local PC = require(script.Parent.PlayerControl)
	local CB = require(game:GetService("ReplicatedStorage").Shared.CaveData).bounds
	local indoor = PC.pos.X >= CB.minX and PC.pos.X <= CB.maxX and PC.pos.Y >= CB.minZ and PC.pos.Y <= CB.maxZ
	if indoor then
		-- the web's fog starts past the camera distance (45 + 4 m), so the play area stays clear: thin atmosphere only
		Lighting.ClockTime = 12
		Lighting.Brightness = 0
		Lighting.OutdoorAmbient = hex("#8a9cb0")
		Lighting.Ambient = hex("#8a9cb0"):Lerp(hex("#1a1f24"), 0.3)
		local atm0 = Lighting:FindFirstChildOfClass("Atmosphere")
		if atm0 then
			atm0.Color = hex("#040608")
			atm0.Decay = hex("#040608")
			atm0.Density = 0.05
			atm0.Haze = 0
		end
		tint.BackgroundTransparency = 1
		rainLayer.Visible = false
		return
	end
	local k = math.clamp(math.sin(((hour - 5.5) / 15) * math.pi), 0, 1)
	local dayLit = k > 0.05
	local sunColor = if dayLit then lerpC(hex("#ffb070"), hex("#fff3d6"), math.min(1, 1.6 * k)) else hex("#8fa6d8")
	local sunI = (if dayLit then 0.4 + 2 * k else 0.35) * (if storm then 0.5 else 1)
	local hemi = if dayLit then hex("#fff6e0") else hex("#6d7fae")
	local ground = if dayLit then hex("#4a5a3a") else hex("#1c2333")
	local hemiI = (0.55 + 0.95 * k) * (if storm then 0.6 else 1)
	local sky = if storm then hex("#5a4a72") else lerpC(hex("#202a3a"), hex("#9fb8c9"), k)
	Lighting.ClockTime = hour
	Lighting.Brightness = sunI * 1.05
	Lighting.ColorShift_Top = sunColor
	-- the hemisphere light as Roblox's ambients (the toy brief keeps the day bright, the night navy)
	Lighting.OutdoorAmbient = Color3.new(0, 0, 0):Lerp(hemi, math.clamp(hemiI, 0, 1))
	Lighting.Ambient = Color3.new(0, 0, 0):Lerp(ground:Lerp(hemi, 0.5), math.clamp(hemiI, 0, 1) * 0.8)
	local atm = Lighting:FindFirstChildOfClass("Atmosphere")
	if atm then
		atm.Color = sky
		atm.Decay = sky:Lerp(Color3.new(0, 0, 0), 0.3)
		atm.Density = if storm then 0.45 else 0.25
		atm.Haze = if storm then 2.5 else 0
	end
	-- the player's torch (env.torch: night 1, dusk 0.45, storm 0.6): a warm spot ahead of the character
	local torch = if hour >= 22 or hour < 6 then 1 elseif hour >= 18 then 0.45 elseif storm then 0.6 else 0
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		local light = root:FindFirstChild("Torch", true) :: SpotLight?
		if not light then
			local att = Instance.new("Attachment")
			att.Name = "TorchAtt"
			att.CFrame = CFrame.new(0, 1, 0) * CFrame.Angles(math.rad(-35), 0, 0)
			att.Parent = root
			local l = Instance.new("SpotLight")
			l.Name = "Torch"
			l.Color = hex("#fff0d0")
			l.Range = 60
			l.Angle = 75
			l.Face = Enum.NormalId.Front
			l.Shadows = true
			l.Parent = att
			light = l
		end
		local l = light :: SpotLight
		l.Enabled = torch > 0
		l.Brightness = torch * 3
	end
	-- storm tint and rain streaks
	tintAlpha += ((if storm then 0.22 else 0) - tintAlpha) * math.min(1, step / 2 * 4)
	tint.BackgroundTransparency = 1 - tintAlpha
	local raining = Workspace:GetAttribute("Rain") == true
	rainAlpha = math.clamp(rainAlpha + (if raining then step / 1.5 else -step / 1.5), 0, 1)
	rainLayer.Visible = rainAlpha > 0.001
	if rainLayer.Visible then
		local vp = (Workspace.CurrentCamera :: Camera).ViewportSize
		if #streaks == 0 then
			makeStreaks(vp.X, vp.Y)
		end
		for _, s in streaks do
			s.y += s.v * step
			s.x -= s.v * 0.15 * step
			if s.y > vp.Y + 20 then
				s.y = -20
				s.x = math.random() * (vp.X + 100)
			end
			s.f.Position = UDim2.fromOffset(s.x + 1.5, s.y - 7)
			s.f.BackgroundTransparency = 1 - 0.35 * rainAlpha
		end
	end
end

return DayNight
