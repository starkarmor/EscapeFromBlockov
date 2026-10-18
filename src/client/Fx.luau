--!strict
-- Local effects as the web build draws them (World.ts): bullet tracers at the real bullet speed, the shared particle pool
-- (blood, dust, sparks, shells, blasts), the muzzle light, blood decals, the hit flash, hit marker and damage numbers.
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")
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

-- ------------------------------------------------------------------ particles (World.burst / updateParticles)
-- 100 pooled 0.13 m cubes in flat unlit colours (MeshBasicMaterial): each colour is a Model whose Highlight fills its
-- cubes with exactly that colour (Highlight fill is unlit), occluded by the world like the web's depth-tested meshes.
local POOL = 100
type Particle = { part: Part, life: number, v: Vector3, hex: string? }
local particles: { Particle } = {}
type Group = { model: Model, hl: Highlight, n: number }
local groups: { [string]: Group } = {}
for i = 1, POOL do
	local p = Instance.new("Part")
	p.Name = "P"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.Size = Vector3.one * 0.13 * S
	particles[i] = { part = p, life = 0, v = Vector3.zero, hex = nil }
end

local function groupOf(hex: string): Group
	local g = groups[hex]
	if g then
		return g
	end
	local m = Instance.new("Model")
	m.Name = "P_" .. hex
	m.Parent = folder
	local hl = Instance.new("Highlight")
	hl.FillColor = Color3.fromHex(hex)
	hl.FillTransparency = 0
	hl.OutlineTransparency = 1
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Enabled = false
	hl.Adornee = m
	hl.Parent = m
	g = { model = m, hl = hl, n = 0 }
	groups[hex] = g
	return g
end

local function release(q: Particle)
	q.life = 0
	q.part.Parent = nil
	local g = q.hex and groups[q.hex]
	if g then
		g.n -= 1
		if g.n <= 0 then
			g.n = 0
			g.hl.Enabled = false
		end
	end
	q.hex = nil
end

local function spawnParticle(q: Particle, at: Vector3, hex: string, life: number, v: Vector3)
	if q.life > 0 then
		release(q)
	end
	local g = groupOf(hex)
	q.life = life
	q.v = v
	q.hex = hex
	q.part.Color = Color3.fromHex(hex)
	q.part.CFrame = CFrame.new(at * S)
	q.part.Parent = g.model
	g.n += 1
	g.hl.Enabled = true
end

--- World.burst(x, y, z, color, n, speed = 4): n free cubes, life 0.3-0.6 s, vx / vz +-speed / 2, vy 1 + rand x 0.8 speed
function Fx.burst(at: Vector3, hex: string, n: number, speed: number?)
	local sp = speed or 4
	local spawned = 0
	for _, q in particles do
		if q.life <= 0 then
			spawnParticle(q, at, hex, 0.3 + math.random() * 0.3,
				Vector3.new((math.random() - 0.5) * sp, math.random() * sp * 0.8 + 1, (math.random() - 0.5) * sp))
			spawned += 1
			if spawned >= n then
				break
			end
		end
	end
end

--- World.ejectShell: one brass cube thrown out of the gun's side at 1.2 m for 0.6 s (the web's (cos f, -sin f), mirrored
--- to the avatar's real right hand like Guns.muzzle)
function Fx.shell(x: number, z: number, facing: number)
	for _, q in particles do
		if q.life <= 0 then
			local rx, rz = -math.cos(facing), math.sin(facing)
			spawnParticle(q, Vector3.new(x + rx * 0.3, 1.2, z + rz * 0.3), "#d9a440", 0.6,
				Vector3.new(rx * (2 + math.random() * 1.5), 3, rz * (2 + math.random() * 1.5)))
			return
		end
	end
end

-- ------------------------------------------------------------------ bullets (World.spawnBullet / updateProjectiles)
-- a 0.06 x 0.06 x 2.2 m unlit box centred on the bullet, turned to its yaw only: the player's #ffe08a, the enemies'
-- #ffc04a; the bloater's ring shots are a 0.17 m icosahedron #b8f060
type Tracer = { part: Part, hex: string, o: Vector3, d: Vector3, yaw: number, speed: number, t: number, maxT: number }
local tracers: { Tracer } = {}

--- a bullet: from muzzle `o` (metres) along yaw / slope at `speed` m/s for `range` m (capped at the first wall or body)
function Fx.tracer(o: Vector3, yaw: number, slope: number, speed: number, range: number, mine: boolean, hex: string?)
	local d = Vector3.new(math.sin(yaw), slope, math.cos(yaw))
	local hit = Workspace:Raycast(o * S, d.Unit * range * S * d.Magnitude, bulletParams)
	local dist = if hit then Vector2.new(hit.Position.X / S - o.X, hit.Position.Z / S - o.Z).Magnitude else range
	local wallDist = dist
	-- stop at the first character capsule on the line (hit3d radius 0.5 m), like the server's bullet
	local chars = Workspace:FindFirstChild("Characters")
	if chars then
		local d2 = Vector2.new(d.X, d.Z)
		for _, m in chars:GetChildren() do
			local r = m:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r and not m:GetAttribute("Dead") and not (mine and m == Players.LocalPlayer.Character) then
				local rel = Vector2.new(r.Position.X / S - o.X, r.Position.Z / S - o.Z)
				local along = rel:Dot(d2)
				if along > 0.9 and along < dist and (rel - d2 * along).Magnitude <= 0.5 then
					dist = along
				end
			end
		end
	end
	local ring = hex == "#b8f060"
	local col = if mine then "#ffe08a" elseif ring then "#b8f060" else "#ffc04a"
	local g = groupOf(col)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromHex(col)
	if ring then
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.one * 0.34 * S
	else
		part.Size = Vector3.new(0.06, 0.06, 2.2) * S
	end
	part.CFrame = CFrame.new(o * S) * CFrame.Angles(0, yaw + math.pi, 0)
	part.Parent = g.model
	g.n += 1
	g.hl.Enabled = true
	table.insert(tracers, { part = part, hex = col, o = o, d = d, yaw = yaw, speed = speed, t = 0, maxT = dist / speed })
	-- every bullet that ends on the world bursts there (the bodies' own hits come from the server's hit events)
	if hit and dist >= wallDist - 1e-3 then
		local inst = hit.Instance
		task.delay(dist / speed, function()
			Fx.impact(hit.Position / S, inst)
		end)
	end
end

-- the muzzle light (World.flash: one PointLight, distance 9 m, 0.06 s linear fade from full)
local flashPart = Instance.new("Part")
flashPart.Name = "MuzzleLight"
flashPart.Anchored = true
flashPart.CanCollide = false
flashPart.CanQuery = false
flashPart.CanTouch = false
flashPart.Transparency = 1
flashPart.Size = Vector3.one * 0.1
flashPart.Parent = folder
local flashLight = Instance.new("PointLight")
flashLight.Range = 9 * S
flashLight.Brightness = 0
flashLight.Shadows = false
flashLight.Parent = flashPart
local flashT = 0
local FLASH_BRIGHT = 6

--- World.muzzleFlash (light + 2 #ffe08a cubes at speed 1.5); the shooter's own shot also ejects a shell and throws
--- 2 #ffd36b cubes 0.3 m ahead at speed 2 (World.fireGun)
function Fx.muzzle(o: Vector3, facing: number, hex: string?, mine: boolean?, from: Vector3?)
	flashPart.CFrame = CFrame.new(o.X * S, (o.Y + 0.1) * S, o.Z * S)
	flashLight.Color = Color3.fromHex(hex or "#ffd27a")
	flashT = 0.06
	flashLight.Brightness = FLASH_BRIGHT
	Fx.burst(o, "#ffe08a", 2, 1.5)
	if mine then
		local p = from or o
		Fx.shell(p.X, p.Z, facing)
		Fx.burst(Vector3.new(o.X + math.sin(facing) * 0.3, o.Y, o.Z + math.cos(facing) * 0.3), "#ffd36b", 2, 2)
	end
end

--- a bullet ending on the world (World.updateProjectiles): the ground #9a8a6a x2 at speed 2 on the floor, a wall
--- #cfc9b8 x3 at speed 3 at the bullet's height; half cover also takes the hit (#b8a77e x3 at 0.9 m)
function Fx.impact(at: Vector3, inst: Instance?)
	local ground = at.Y <= 0.06 or (inst ~= nil and inst:IsA("BasePart") and inst.CollisionGroup == "Ground")
	if ground then
		Fx.burst(Vector3.new(at.X, 0.05, at.Z), "#9a8a6a", 2, 2)
		return
	end
	Fx.burst(Vector3.new(at.X, math.max(0.05, at.Y), at.Z), "#cfc9b8", 3, 3)
	if inst and inst:GetAttribute("Cover") ~= nil then
		Fx.burst(Vector3.new(at.X, 0.9, at.Z), "#b8a77e", 3, 3)
	end
end

--- half cover or a wall knocked down (World.damageCover): #8a8270 x14 at speed 5, 0.6 m up
function Fx.debris(at: Vector3)
	Fx.burst(Vector3.new(at.X, 0.6, at.Z), "#8a8270", 14, 5)
end

--- World.blast: every explosion (the flashbang too) is 28 #ffb347 cubes at speed 9 and 18 #555555 at speed 6, 0.8 m up
function Fx.explode(at: Vector3, _radius: number?)
	local c = Vector3.new(at.X, 0.8, at.Z)
	Fx.burst(c, "#ffb347", 28, 9)
	Fx.burst(c, "#555555", 18, 6)
end

-- ------------------------------------------------------------------ blood decals (World.decal / updateDecals)
-- 40 round-robin octagons (CircleGeometry(0.45, 8): corners on the axes), #5a1410, unlit, opacity min(0.75, life / 5),
-- 25 s. Each is an unlit SurfaceGui (LightInfluence 0) on the top of a thin invisible plate; the plates sit a hair apart
-- in height so overlapping splats blend instead of z-fighting (the web draws them without depth writes).
local OCT_N = 64
local octImage: any = nil
do
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(OCT_N, OCT_N) })
	end)
	if ok and img then
		-- coverage of the regular octagon (circumradius = half the image) by 4x4 supersampling
		local px = buffer.create(OCT_N * OCT_N * 4)
		local R = OCT_N / 2
		local apo = R * math.cos(math.pi / 8)
		for y = 0, OCT_N - 1 do
			for x = 0, OCT_N - 1 do
				local cover = 0
				for sy = 0, 3 do
					for sx = 0, 3 do
						local dx = x + (sx + 0.5) / 4 - R
						local dy = y + (sy + 0.5) / 4 - R
						local inside = true
						for k = 0, 7 do
							-- edge normals at 22.5 + 45k degrees (corners at 0, 45, 90 ...)
							local a = math.pi / 8 + k * math.pi / 4
							if dx * math.cos(a) + dy * math.sin(a) > apo then
								inside = false
								break
							end
						end
						if inside then
							cover += 1
						end
					end
				end
				local o = (y * OCT_N + x) * 4
				buffer.writeu8(px, o, 255)
				buffer.writeu8(px, o + 1, 255)
				buffer.writeu8(px, o + 2, 255)
				buffer.writeu8(px, o + 3, math.floor(cover / 16 * 255 + 0.5))
			end
		end
		img:WritePixelsBuffer(Vector2.zero, Vector2.new(OCT_N, OCT_N), px)
		octImage = img
	end
end

local DECAL = Color3.fromHex("#5a1410")
type Decal = { part: Part, img: ImageLabel, life: number }
local decals: { Decal } = {}
local decalNext = 1
local function makeDecal(slot: number): Decal
	local p = Instance.new("Part")
	p.Name = "Blood"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(0.9 * S, 0.02, 0.9 * S)
	p.Parent = folder
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0
	gui.Brightness = 1
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(OCT_N, OCT_N)
	gui.ClipsDescendants = false
	gui.Adornee = p
	gui.Parent = p
	local img = Instance.new("ImageLabel")
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.ImageColor3 = DECAL
	img.ImageTransparency = 1
	if octImage then
		img.ImageContent = Content.fromObject(octImage)
	else
		-- no EditableImage: a round splat
		img.BackgroundColor3 = DECAL
		Instance.new("UICorner", img).CornerRadius = UDim.new(0.5, 0)
	end
	img.Parent = gui
	local _ = slot
	return { part = p, img = img, life = 0 }
end

function Fx.decal(x: number, z: number, size: number)
	local slot = decalNext
	local d = decals[slot]
	if not d then
		d = makeDecal(slot)
		decals[slot] = d
	end
	decalNext = decalNext % 40 + 1
	local k = size * (0.7 + math.random() * 0.6)
	d.part.Size = Vector3.new(0.9 * S * k, 0.02, 0.9 * S * k)
	d.part.CFrame = CFrame.new(x * S, (0.05 + slot * 0.0006) * S - 0.01, z * S)
	d.life = 25
end

local function setDecalAlpha(d: Decal, a: number)
	if octImage then
		d.img.ImageTransparency = 1 - a
	else
		d.img.BackgroundTransparency = 1 - a
	end
end

-- ------------------------------------------------------------------ hit flash (World.flashModel)
-- every mesh of the model swaps to a flat unlit white (enemy hit) / #ffb347 (player hurt) for 0.125 s; a new hit
-- restarts the time. (The red emissive under it, hurtFlash x 0.6 at 8 / s, has decayed to 0 exactly when it ends.)
local flashes: { [Model]: { hl: Highlight, t: number } } = {}
function Fx.hitFlash(model: Model?, color: Color3)
	if not model or not model.Parent then
		return
	end
	local f = flashes[model]
	if not f then
		local hl = model:FindFirstChild("HitFlash") :: Highlight?
		if not hl then
			hl = Instance.new("Highlight")
			hl.Name = "HitFlash"
			hl.OutlineTransparency = 1
			hl.FillTransparency = 0
			hl.DepthMode = Enum.HighlightDepthMode.Occluded
			hl.Parent = model
		end
		f = { hl = hl :: Highlight, t = 0 }
		flashes[model] = f
	end
	f.hl.FillColor = color
	f.hl.Enabled = true
	f.t = 0.125
end

local ENEMY_BLOOD = "#b0161b"
local PLAYER_BLOOD = "#c8392f"
--- one hit as World.damageEnemy / the player's takeHit draw it: everything on the victim's body position at BODY_FX_Y
--- (1.2 x RIG_SCALE = 0.615 m), not the bullet's contact point; h.at is rewritten to it for the damage number
local BODY_FX_Y = 1.2 * 1.107 / 2.16
function Fx.hit(h: any)
	local root = h.model and h.model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		h.at = Vector3.new(root.Position.X / S, BODY_FX_Y, root.Position.Z / S)
	else
		h.at = Vector3.new(h.at.X, BODY_FX_Y, h.at.Z)
	end
	local at: Vector3 = h.at
	if h.kind == "enemy" then
		Fx.burst(at, ENEMY_BLOOD, if h.kill then 26 elseif h.crit then 10 else 6, if h.kill then 6 else 4)
		if not h.kill then
			Fx.hitFlash(h.model, Color3.new(1, 1, 1))
		end
		if h.byPlayer then
			Fx.decal(at.X + (math.random() - 0.5) * 0.6, at.Z + (math.random() - 0.5) * 0.6, if h.kill then 1.6 else 0.8)
			-- death: a wide splatter of several overlapping decals around the body
			if h.kill then
				for _ = 1, 6 do
					Fx.decal(at.X + (math.random() - 0.5) * 2.4, at.Z + (math.random() - 0.5) * 2.4, 0.7 + math.random() * 1.1)
				end
			end
		end
	elseif h.kind == "player" then
		Fx.burst(at, PLAYER_BLOOD, 5, 4)
		Fx.hitFlash(h.model, Color3.fromHex("#ffb347"))
		if h.bullet then
			Fx.decal(at.X + (math.random() - 0.5), at.Z + (math.random() - 0.5), 0.7)
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
	for _, q in particles do
		if q.life > 0 then
			q.life -= dt
			if q.life <= 0 then
				release(q)
			else
				q.v -= Vector3.new(0, 14 * dt, 0)
				local p = q.part.Position / S
				q.part.CFrame = CFrame.new(p.X * S + q.v.X * dt * S, math.max(0.05, p.Y + q.v.Y * dt) * S, p.Z * S + q.v.Z * dt * S)
			end
		end
	end
	if flashT > 0 then
		flashT -= dt
		flashLight.Brightness = math.max(0, flashT / 0.06) * FLASH_BRIGHT
	end
	for _, d in decals do
		if d.life > 0 then
			d.life -= dt
			setDecalAlpha(d, math.min(0.75, math.max(0, d.life) / 5))
		end
	end
	for model, f in flashes do
		f.t -= dt
		if f.t <= 0 or not model.Parent then
			f.hl.Enabled = false
			flashes[model] = nil
		end
	end
	for i = #tracers, 1, -1 do
		local t = tracers[i]
		t.t += dt
		if t.t >= t.maxT then
			t.part:Destroy()
			local g = groups[t.hex]
			if g then
				g.n -= 1
				if g.n <= 0 then
					g.n = 0
					g.hl.Enabled = false
				end
			end
			table.remove(tracers, i)
		else
			local p = t.o + t.d * (t.t * t.speed)
			t.part.CFrame = CFrame.new(p * S) * CFrame.Angles(0, t.yaw + math.pi, 0)
		end
	end
end)

local _ = Players
return Fx
