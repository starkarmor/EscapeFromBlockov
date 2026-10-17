--!strict
-- Local effects in the art brief's VFX grammar (white core, coloured body, timed expansion, clean decay):
-- bullet tracers that fly at the real bullet speed, muzzle flash, impact stars, hit marker, damage numbers.
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)

local S = Units.S
local Fx = {}
local folder = Instance.new("Folder")
folder.Name = "LocalFx"
folder.Parent = Workspace

local bulletParams = RaycastParams.new()
bulletParams.CollisionGroup = "QBullet"
bulletParams.FilterType = Enum.RaycastFilterType.Exclude
bulletParams.FilterDescendantsInstances = { folder }

local GOLD = Color3.fromRGB(255, 216, 61)
local WHITE = Color3.new(1, 1, 1)
local CORAL = Color3.fromRGB(243, 69, 67)

local function neon(size: Vector3, cf: CFrame, color: Color3, transparency: number?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Size = size
	p.CFrame = cf
	p.Transparency = transparency or 0
	p.Parent = folder
	return p
end

type Tracer = { part: Part, o: Vector3, d: Vector3, speed: number, len: number, t: number, maxT: number }
local tracers: { Tracer } = {}

--- a bullet: from muzzle `o` (metres) along yaw / slope at `speed` m/s for `range` m (capped at the first wall)
function Fx.tracer(o: Vector3, yaw: number, slope: number, speed: number, range: number, mine: boolean)
	local d = Vector3.new(math.sin(yaw), slope, math.cos(yaw)).Unit
	local hit = Workspace:Raycast(o * S, d * range * S, bulletParams)
	local dist = if hit then (hit.Position / S - o).Magnitude else range
	local part = neon(Vector3.new(0.12, 0.12, 1.4) * S * 0.5, CFrame.lookAt(o * S, (o + d) * S), Color3.fromRGB(255, 244, 196))
	table.insert(tracers, { part = part, o = o, d = d, speed = speed, len = 0.7, t = 0, maxT = dist / speed })
	if hit and mine then
		task.delay(dist / speed, function()
			Fx.impact(hit.Position / S, hit.Normal)
		end)
	end
end

function Fx.muzzle(o: Vector3, facing: number)
	local cf = CFrame.new(o * S) * CFrame.Angles(0, facing, 0)
	local core = neon(Vector3.one * 0.55, cf, WHITE)
	local rays = neon(Vector3.new(1.4, 0.25, 0.25), cf * CFrame.Angles(0, math.pi / 2, math.rad(45)), GOLD)
	local rays2 = neon(Vector3.new(1.4, 0.25, 0.25), cf * CFrame.Angles(0, math.pi / 2, math.rad(-45)), GOLD)
	local light = Instance.new("PointLight")
	light.Color = GOLD
	light.Range = 12
	light.Brightness = 3
	light.Parent = core
	task.delay(1 / 30, function()
		rays:Destroy()
		rays2:Destroy()
	end)
	task.delay(2 / 30, function()
		core:Destroy()
	end)
end

function Fx.impact(at: Vector3, normal: Vector3?)
	local cf = CFrame.new(at * S)
	local star = neon(Vector3.one * 0.7, cf * CFrame.Angles(0, 0, math.rad(45)), WHITE)
	TweenService:Create(star, TweenInfo.new(0.15), { Size = Vector3.one * 0.05, Transparency = 1 }):Play()
	for i = 1, 4 do
		local chunk = neon(Vector3.one * 0.3, cf, if i % 2 == 0 then CORAL else GOLD)
		local dir = (Vector3.new(math.random() - 0.5, math.random(), math.random() - 0.5)).Unit * 3
		TweenService:Create(chunk, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = cf + dir, Transparency = 1, Size = Vector3.one * 0.05 }):Play()
		task.delay(0.26, function()
			chunk:Destroy()
		end)
	end
	task.delay(0.16, function()
		star:Destroy()
	end)
end

-- hit marker + damage numbers live in the HUD gui (Hud.luau owns the ScreenGui; it registers these)
Fx.onHitMarker = nil :: ((boolean, boolean) -> ())?
Fx.onDamage = nil :: ((Vector3, number, boolean) -> ())?

function Fx.hitMarker(kill: boolean, crit: boolean)
	if Fx.onHitMarker then
		Fx.onHitMarker(kill, crit)
	end
end

function Fx.damageNumber(at: Vector3, dmg: number, crit: boolean)
	if Fx.onDamage then
		Fx.onDamage(at, dmg, crit)
	end
end

RunService.RenderStepped:Connect(function(dt)
	for i = #tracers, 1, -1 do
		local t = tracers[i]
		t.t += dt
		if t.t >= t.maxT then
			t.part:Destroy()
			table.remove(tracers, i)
		else
			local head = t.o + t.d * (t.t * t.speed)
			local tailD = math.min(t.len, t.t * t.speed)
			local tail = head - t.d * tailD
			local mid = (head + tail) * 0.5
			t.part.Size = Vector3.new(0.09 * S, 0.09 * S, math.max(0.05, tailD) * S)
			t.part.CFrame = CFrame.lookAt(mid * S, head * S)
		end
	end
end)

local _ = Players
return Fx
