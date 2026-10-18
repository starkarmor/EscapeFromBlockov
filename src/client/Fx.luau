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
	-- stop at the first character capsule on the line (hit3d radius 0.5 m), like the server's bullet
	local chars = Workspace:FindFirstChild("Characters")
	if chars and not mine then
		-- someone else's shot can end on anyone, our own character included
	end
	if chars then
		local d2 = Vector2.new(d.X, d.Z)
		local dl = d2.Magnitude
		if dl > 1e-6 then
			d2 /= dl
			for _, m in chars:GetChildren() do
				local r = m:FindFirstChild("HumanoidRootPart") :: BasePart?
				if r and not m:GetAttribute("Dead") then
					local rel = Vector2.new(r.Position.X / S - o.X, r.Position.Z / S - o.Z)
					local along = rel:Dot(d2)
					if along > 0.9 and along / dl < dist and (rel - d2 * along).Magnitude <= 0.5 then
						dist = math.min(dist, along / dl)
					end
				end
			end
		end
	end
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

--- explosion (VFX grammar: white core, gold body, coral chunks, an expanding ring, clean decay)
function Fx.explode(at: Vector3, radius: number)
	local cf = CFrame.new(at.X * S, 0.6 * S, at.Z * S)
	local core = neon(Vector3.one * 1.5, cf, WHITE)
	core.Shape = Enum.PartType.Ball
	TweenService:Create(core, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * radius * S * 1.2, Transparency = 1 }):Play()
	local body = neon(Vector3.one * 2, cf, GOLD, 0.15)
	body.Shape = Enum.PartType.Ball
	TweenService:Create(body, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * radius * S * 1.8, Transparency = 1 }):Play()
	local ring = neon(Vector3.new(0.2, 2, 2), CFrame.new(at.X * S, 0.1 * S, at.Z * S) * CFrame.Angles(0, 0, math.pi / 2), Color3.fromRGB(255, 248, 233), 0.2)
	ring.Shape = Enum.PartType.Cylinder
	TweenService:Create(ring, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.05, radius * S * 2.4, radius * S * 2.4), Transparency = 1 }):Play()
	for i = 1, 10 do
		local chunk = neon(Vector3.one * 0.6, cf, if i % 2 == 0 then CORAL else GOLD)
		local dir = Vector3.new(math.random() - 0.5, math.random() * 0.8 + 0.2, math.random() - 0.5).Unit * radius * S
		TweenService:Create(chunk, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = cf + dir, Transparency = 1, Size = Vector3.one * 0.1 }):Play()
		task.delay(0.55, function()
			chunk:Destroy()
		end)
	end
	task.delay(0.5, function()
		core:Destroy()
		body:Destroy()
		ring:Destroy()
	end)
end

-- ------------------------------------------------------------------ blood (World.burst / addDecal, Character flash)
type Cube = { part: Part, v: Vector3, life: number, t: number }
local cubes: { Cube } = {}
local cubePool: { Part } = {}
local function cube(at: Vector3, color: Color3, speed: number)
	local p = table.remove(cubePool) or neon(Vector3.one * 0.13 * S, CFrame.new(), color)
	p.Material = Enum.Material.SmoothPlastic
	p.Color = color
	p.Transparency = 0
	p.Size = Vector3.one * 0.13 * S
	p.CFrame = CFrame.new(at * S)
	p.Parent = folder
	-- vx, vz = +-speed / 2, vy = rand * 0.8 * speed + 1; life 0.3-0.6 s; gravity 14; floor 0.05 m
	local v = Vector3.new((math.random() - 0.5) * speed, math.random() * 0.8 * speed + 1, (math.random() - 0.5) * speed)
	table.insert(cubes, { part = p, v = v, life = 0.3 + math.random() * 0.3, t = 0 })
end

function Fx.burst(at: Vector3, color: Color3, n: number, speed: number)
	for _ = 1, n do
		if #cubes < 100 then
			cube(at, color, speed)
		end
	end
end

-- 40 ground decals (r 0.45 m circles, #5a1410), round-robin, life 25 s, opacity min(0.75, life / 5)
local DECAL = Color3.fromHex("#5a1410")
local decals: { { part: Part, life: number } } = {}
local decalNext = 1
function Fx.decal(x: number, z: number, scale: number)
	local d = decals[decalNext]
	if not d then
		local p = Instance.new("Part")
		p.Shape = Enum.PartType.Cylinder
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p.Material = Enum.Material.SmoothPlastic
		p.Color = DECAL
		p.Parent = folder
		d = { part = p, life = 0 }
		decals[decalNext] = d
	end
	local k = scale * (0.7 + math.random() * 0.6)
	d.part.Size = Vector3.new(0.02 * S, 0.9 * S * k, 0.9 * S * k)
	d.part.CFrame = CFrame.new(x * S, 0.05 * S, z * S) * CFrame.Angles(0, 0, math.pi / 2)
	d.life = 25
	decalNext = decalNext % 40 + 1
end

--- hit flash: a white (enemy) / orange #ffb347 (player) overlay for 0.125 s, then the emissive decay at 8 / s
function Fx.flash(model: Model?, color: Color3)
	if not model or not model.Parent then
		return
	end
	local h = model:FindFirstChild("HitFlash") :: Highlight?
	if not h then
		h = Instance.new("Highlight")
		h.Name = "HitFlash"
		h.OutlineTransparency = 1
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Parent = model
	end
	h.FillColor = color
	h.FillTransparency = 0.15
	h.Enabled = true
	local token = os.clock()
	h:SetAttribute("T", token)
	task.spawn(function()
		task.wait(0.125)
		local a = 0.6
		while a > 0 and h.Parent and h:GetAttribute("T") == token do
			local dt = task.wait()
			a -= dt * 8 * 0.6
			h.FillTransparency = 1 - math.max(0, a)
		end
		if h.Parent and h:GetAttribute("T") == token then
			h.Enabled = false
		end
	end)
end

local ENEMY_BLOOD = Color3.fromHex("#b0161b")
local PLAYER_BLOOD = Color3.fromHex("#c8392f")
--- one hit as World.applyHit draws it
function Fx.hit(h: any)
	local at: Vector3 = h.at
	if h.kind == "enemy" then
		local n = if h.kill then 26 elseif h.crit then 10 else 6
		Fx.burst(at, ENEMY_BLOOD, n, if h.kill then 6 else 4)
		if not h.kill then
			Fx.flash(h.model, Color3.new(1, 1, 1))
		end
		if h.byPlayer then
			if h.kill then
				Fx.decal(at.X, at.Z, 1.6)
				for _ = 1, 6 do
					Fx.decal(at.X + (math.random() - 0.5) * 2.4, at.Z + (math.random() - 0.5) * 2.4, 0.7 + math.random() * 1.1)
				end
			else
				Fx.decal(at.X + (math.random() - 0.5) * 0.6, at.Z + (math.random() - 0.5) * 0.6, 0.8)
			end
		end
	elseif h.kind == "player" then
		Fx.burst(at, PLAYER_BLOOD, 5, 4)
		Fx.flash(h.model, Color3.fromHex("#ffb347"))
		if h.bullet then
			Fx.decal(at.X, at.Z, 0.7)
		end
	end
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
	for i = #cubes, 1, -1 do
		local c = cubes[i]
		c.t += dt
		if c.t >= c.life then
			c.part.Parent = nil
			table.insert(cubePool, c.part)
			table.remove(cubes, i)
		else
			c.v -= Vector3.new(0, 14 * dt, 0)
			local p = c.part.Position / S + c.v * dt
			if p.Y < 0.05 then
				p = Vector3.new(p.X, 0.05, p.Z)
				c.v = Vector3.new(c.v.X * 0.5, 0, c.v.Z * 0.5)
			end
			c.part.CFrame = CFrame.new(p * S)
		end
	end
	for _, d in decals do
		if d.life > 0 then
			d.life -= dt
			d.part.Transparency = 1 - math.min(0.75, math.max(0, d.life) / 5)
		end
	end
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
