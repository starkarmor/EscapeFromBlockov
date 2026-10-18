--!strict
-- Throwables (World.launchGrenade / Grenade.Update, GrenadePhysics.ts; spec docs/grenades-cover-ai-items-spec.md §1).
--   Launch: Skill_Grenade.CalculateVelocity, a fixed vertical speed lob (vy) to the clamped target under g = 15.
--   Body: our own 0.02 s step (gravity 15, sphere sweep against ground / walls / doors / foliage; no restitution, friction
--   0.6, each new contact halves the horizontal speed), drawn by a server part.
--   Fuse: from release, or from the first contact (delayFromCollide); multi-blast items fan out and stagger.
--   Explode: the shared flat blast (server/Explosion), or a zone (fire / poison / ice ticks 1 / s) or a smoke cloud that
--   blocks sight; the bear trap arms as a landmine. Contacts are heard by the AI (20 m; "danger" for live grenades).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Items = require(Shared.gen.Items)
local Weapons = require(script.Parent.Weapons)
local Explosion = require(script.Parent.Explosion)

local S = Units.S
local Grenades = {}

local G = 15
local STEP = 0.02
local SOUND_RADIUS = 20
local HAND = Vector3.new(0.2594, 0.5491, 0.2883) -- right-hand socket (body.ts), facing frame
local THROW = Items.throw :: { [string]: any }

local cast = RaycastParams.new()
cast.CollisionGroup = "Grenade"
cast.FilterType = Enum.RaycastFilterType.Exclude

type Nade = {
	id: string,
	row: any,
	pos: Vector3, -- metres
	vel: Vector3,
	r: number,
	fuse: number,
	delay: number,
	touched: boolean,
	contact: boolean,
	sounds: number,
	lastSound: number,
	t: number,
	still: number,
	team: number,
	from: Player?,
	fromRef: any,
	part: BasePart,
	armed: boolean,
	done: boolean,
}
local nades: { Nade } = {}
local zones: { any } = {}
local folder: Folder

Grenades.hear = nil :: ((number, number, number, number, number) -> ())? -- Enemies.hear
Grenades.danger = nil :: ((Nade) -> ())? -- Enemies.setDanger

function Grenades.row(id: string): any
	return THROW[id]
end

function Grenades.alive(n: any): boolean
	return not n.done
end

local function look(id: string): (Color3, Vector3)
	if id == "smoke_grenade" then
		return Color3.fromHex("#9aa3a8"), Vector3.new(0.2, 0.46, 0.2)
	elseif id == "pipebomb" or id == "dynamite_multiple" then
		return Color3.fromHex("#c4402f"), Vector3.new(0.12, 0.42, 0.12)
	elseif id == "flash_grenade" then
		return Color3.fromHex("#d9dde0"), Vector3.new(0.2, 0.42, 0.2)
	elseif id == "trap" then
		return Color3.fromHex("#5c5f63"), Vector3.new(0.7, 0.1, 0.7)
	elseif id == "stone" then
		return Color3.fromHex("#8a847a"), Vector3.new(0.24, 0.2, 0.24)
	end
	return Color3.fromHex("#55613f"), Vector3.new(0.3, 0.4, 0.3)
end

--- World.launchGrenade: from the thrower's hand to (tx, tz), clamped to castRange unless `free`
function Grenades.launch(id: string, x: number, z: number, facing: number, tx: number, tz: number, owner: { team: number, from: Player?, fromRef: any, free: boolean? })
	local row = THROW[id]
	if not row then
		return
	end
	local s, c = math.sin(facing), math.cos(facing)
	local hand = Vector3.new(x + HAND.Z * s + HAND.X * c, HAND.Y, z + HAND.Z * c - HAND.X * s)
	local n = math.max(1, row.blastCount or 1)
	local d0 = Vector2.new(tx - hand.X, tz - hand.Z)
	local dist = d0.Magnitude
	if not owner.free then
		dist = math.min(dist, row.castRange)
	end
	local yaw0 = math.atan2(d0.X, d0.Y)
	local ang = row.blastAngle or 0
	local step = if n > 1 then (if ang < 359 then ang / (n - 1) else ang / n) else 0
	for i = 0, n - 1 do
		local yaw = yaw0 + math.rad(if n > 1 then -ang / 2 + step * i else 0)
		local dir = Vector2.new(math.sin(yaw), math.cos(yaw))
		-- CalculateVelocity: up = V / g, down = sqrt(|2 (up V / 2 + startY - endY)| / g), h = dist / T
		local V = row.vy or 5
		local up = V / G
		local down = math.sqrt(math.abs(2 * (up * V * 0.5 + hand.Y - 0.5)) / G)
		local T = up + down
		local h = dist / T
		local color, size = look(id)
		local part = Instance.new("Part")
		part.Name = "Grenade_" .. id
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Size = size * S
		part.Color = color
		part.Material = Enum.Material.SmoothPlastic
		part.CFrame = CFrame.new(hand * S)
		part.Parent = folder
		local nade: Nade = {
			id = id,
			row = row,
			pos = hand,
			vel = Vector3.new(dir.X * h, V, dir.Y * h),
			r = row.radius or 0.18,
			fuse = 0,
			delay = (row.delay or 1) + (row.blastSpace or 0.2) * i,
			touched = false,
			contact = false,
			sounds = 0,
			lastSound = -math.huge,
			t = 0,
			still = 0,
			team = owner.team,
			from = owner.from,
			fromRef = owner.fromRef,
			part = part,
			armed = false,
			done = false,
		}
		table.insert(nades, nade)
	end
end

local function finish(n: Nade)
	n.done = true
	task.delay(0.05, function()
		n.part:Destroy()
	end)
end

local function zone(kind: string, x: number, z: number, radius: number, hold: number, owner: Nade)
	local color = if kind == "fire" then Color3.fromHex("#ff7a2b") elseif kind == "poison" then Color3.fromHex("#8be04e") elseif kind == "ice" then Color3.fromHex("#8fd8ff") else Color3.fromHex("#c9ced2")
	local disc = Instance.new("Part")
	disc.Name = "Zone_" .. kind
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.Shape = Enum.PartType.Cylinder
	disc.Material = Enum.Material.Neon
	disc.Color = color
	disc.Transparency = 0.6
	disc.Size = Vector3.new(0.1, 0.1, 0.1)
	disc.CFrame = CFrame.new(x * S, 0.06 * S, z * S) * CFrame.Angles(0, 0, math.pi / 2)
	disc.Parent = folder
	table.insert(zones, { kind = kind, x = x, z = z, radius = radius, hold = hold, t = 0, tick = 0, part = disc, owner = owner })
end

-- smoke: 8 thin boxes on an octagon at 4 m plus 8 spheres r 1.66 (Grenades.ts), in the Smoke group (sight only)
local function smoke(x: number, z: number)
	local m = Instance.new("Model")
	m.Name = "Smoke"
	local pieces = {}
	for i = 0, 7 do
		local a = i / 8 * math.pi * 2
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball
		ball.Anchored = true
		ball.CanCollide = false
		ball.CanQuery = true
		ball.CanTouch = false
		ball.CollisionGroup = "Smoke"
		ball.Material = Enum.Material.SmoothPlastic
		ball.Color = Color3.fromHex("#d8dcdf")
		ball.Transparency = 0.25
		ball.CastShadow = false
		ball.Size = Vector3.one * 0.1
		ball.CFrame = CFrame.new((x + math.sin(a) * 2) * S, 1.5 * S, (z + math.cos(a) * 2) * S)
		ball.Parent = m
		table.insert(pieces, { part = ball, size = Vector3.one * 3.32 * S })
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.CanCollide = false
		wall.CanQuery = true
		wall.CanTouch = false
		wall.CollisionGroup = "Smoke"
		wall.Transparency = 1
		wall.Size = Vector3.one * 0.1
		wall.CFrame = CFrame.new((x + math.sin(a) * 4) * S, 1.5 * S, (z + math.cos(a) * 4) * S) * CFrame.Angles(0, a, 0)
		wall.Parent = m
		table.insert(pieces, { part = wall, size = Vector3.new(3.31, 3, 0.15) * S })
	end
	m.Parent = folder
	table.insert(zones, { kind = "smoke", x = x, z = z, t = 0, model = m, pieces = pieces })
end

local function explode(n: Nade)
	local row = n.row
	local x, z = n.pos.X, n.pos.Z
	finish(n)
	local id = n.id
	if id == "smoke_grenade" then
		smoke(x, z)
		return
	elseif id == "fire_grenade" then
		zone("fire", x, z, 3.5, 8, n)
	elseif id == "tox_grenade" then
		zone("poison", x, z, 3.5, 10, n)
	elseif id == "ice_grenade" then
		zone("ice", x, z, 4.25, 10, n)
	end
	if row.createExplosion == false then
		return
	end
	local team = if row.canHurtSelf ~= false then 7 else n.team
	Explosion.blast(x, z, row.effectRange, row.damage or 0, {
		team = team,
		ap = row.ap,
		armorBreak = row.armorBreak,
		ignoreArmor = row.ignoreArmor,
		from = n.from,
		fromRef = n.fromRef,
		fromName = if n.from then n.from.DisplayName else (n.fromRef and n.fromRef.def and n.fromRef.def.name) or "Explosion",
		weaponId = id,
		shake = row.shake,
		stun = if id == "flash_grenade" then 7 elseif id == "trap" then 1.5 else nil,
		ai = n.fromRef ~= nil and n.from == nil,
		fx = if id == "flash_grenade" then "flash" else "explode",
	})
end

local function sound(n: Nade)
	local row = n.row
	if n.sounds >= (row.makeSoundCount or 3) or n.t - n.lastSound <= 0.3 then
		return
	end
	n.sounds += 1
	n.lastSound = n.t
	local danger = row.dangerForAi ~= false
	if Grenades.hear then
		Grenades.hear(n.pos.X, n.pos.Z, SOUND_RADIUS, if danger then 2 else 0, if n.from then 7 else n.team)
	end
	if danger and Grenades.danger then
		Grenades.danger(n)
	end
end

local function stepNade(n: Nade, dt: number)
	n.t += dt
	if not n.still or n.still < 0.4 then
		local v = n.vel - Vector3.new(0, G * dt, 0)
		local move = v * dt
		local hit = if move.Magnitude > 1e-5 then Workspace:Spherecast(n.pos * S, n.r * S, move * S, cast) else nil
		local touching = false
		if hit then
			touching = true
			local travel = hit.Distance / S
			local nrm = hit.Normal
			n.pos += move.Unit * math.max(0, travel - 0.01)
			-- no restitution: drop the velocity into the surface; a new contact halves the horizontal speed
			local vn = v:Dot(nrm)
			if vn < 0 then
				v -= nrm * vn
			end
			if not n.contact then
				v = Vector3.new(v.X * 0.5, v.Y, v.Z * 0.5)
				sound(n)
			end
			-- friction 0.6 while resting on a floor
			if nrm.Y > 0.6 then
				local vt = Vector3.new(v.X, 0, v.Z)
				local l = vt.Magnitude
				local dec = 0.6 * G * dt
				v = if l > dec then Vector3.new(v.X - v.X / l * dec, math.max(0, v.Y), v.Z - v.Z / l * dec) else Vector3.new(0, math.max(0, v.Y), 0)
			end
			n.touched = true
		else
			n.pos += move
		end
		-- never under the floor
		if n.pos.Y < n.r then
			n.pos = Vector3.new(n.pos.X, n.r, n.pos.Z)
			if v.Y < 0 then
				v = Vector3.new(v.X, 0, v.Z)
			end
		end
		n.contact = touching
		n.vel = v
		if v.Magnitude < 0.07 then
			n.still += dt
		else
			n.still = 0
		end
		n.part.CFrame = CFrame.new(n.pos * S) * n.part.CFrame.Rotation * CFrame.Angles(v.Z * dt * 2, 0, -v.X * dt * 2)
	end
	-- fuse
	if not n.row.delayFromCollide or n.touched then
		n.fuse += dt
	end
	if n.row.isLandmine then
		if not n.armed and n.fuse > n.delay then
			n.armed = true
		end
		if n.armed then
			for key, t in Weapons.targets do
				if t.kind ~= "breakable" and (t.team ~= n.team or n.team == 7) and key ~= n.from then
					local tp = t.pos()
					if tp and (Vector2.new(tp.X, tp.Z) - Vector2.new(n.pos.X, n.pos.Z)).Magnitude <= (n.row.landmineRange or 0.5) + t.radius then
						explode(n)
						return
					end
				end
			end
		end
		return
	end
	if n.fuse > n.delay and n.delay < 9999 then
		explode(n)
	elseif n.delay >= 9999 and n.still > 3 then
		finish(n) -- stones and balls: gone once they settle
	end
end

local acc = 0
local function step(dt: number)
	acc += dt
	while acc >= STEP do
		acc -= STEP
		for i = #nades, 1, -1 do
			local n = nades[i]
			if not n.done then
				stepNade(n, STEP)
			end
			if n.done then
				table.remove(nades, i)
			end
		end
	end
	-- zones: damage ticks (1 per s, 1 damage) and the smoke cloud scale
	for i = #zones, 1, -1 do
		local zn = zones[i]
		zn.t += dt
		if zn.kind == "smoke" then
			local age = zn.t
			local k = if age < 1 then math.max(0.01, age) elseif age < 12 then 1 else math.max(0, 1 - (age - 12) / 2.5)
			for _, pc in zn.pieces do
				pc.part.Size = pc.size * math.max(0.01, k)
			end
			if age >= 14.5 then
				zn.model:Destroy()
				table.remove(zones, i)
			end
		else
			local grow = math.min(1, zn.t)
			local fade = if zn.t > 1 + zn.hold then math.max(0, 1 - (zn.t - 1 - zn.hold) / 2.5) else 1
			local r = zn.radius * grow
			zn.part.Size = Vector3.new(0.1, r * 2 * S, r * 2 * S)
			zn.part.Transparency = 1 - 0.4 * fade
			zn.tick += dt
			if zn.tick >= 1 and fade > 0 then
				zn.tick = 0
				for _, t in Weapons.targets do
					if t.kind ~= "breakable" then
						local tp = t.pos()
						if tp and (Vector2.new(tp.X, tp.Z) - Vector2.new(zn.x, zn.z)).Magnitude <= r then
							task.spawn(t.hurt, 1, { direct = true, fromName = "Hazard", element = zn.kind })
						end
					end
				end
			end
			if fade <= 0 then
				zn.part:Destroy()
				table.remove(zones, i)
			end
		end
	end
end

function Grenades.start()
	folder = Instance.new("Folder")
	folder.Name = "Grenades"
	folder.Parent = Workspace
	RunService.Heartbeat:Connect(step)
end

return Grenades
