--!strict
-- Server-owned guns and bullets (World.fireGun / spawnBullet / Projectile): validates each trigger event (cadence,
-- magazine, muzzle near the shooter), flies every bullet at its real speed in 3D, stops it on walls that block bullets
-- (QBullet: the map's Cat bullet flag) and on character hit capsules (hit3d: radius, 1.4 m tall), applies the damage
-- falloff past half range (DmgOverDistance), reloads on the ReloadTime timer from the backpack.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Guns = require(Shared.Guns)
local Net = require(Shared.Net)
local Units = require(Shared.Units)
local Config = require(Shared.Config)

local S = Units.S
local Weapons = {}

export type Target = {
	kind: string, -- "player" | "enemy"
	team: number,
	pos: () -> Vector3?, -- feet position, metres
	radius: number,
	height: number,
	hurt: (dmg: number, info: any) -> boolean, -- returns true on a kill
	ref: any,
}
-- registered by Raid (players) and Enemies
Weapons.targets = {} :: { [any]: Target }

export type Bullet = { pos: Vector3, dir: Vector3, speed: number, left: number, half: number, travelled: number, team: number, damage: number, dmgOver: number, crit: boolean, critMul: number, from: Player?, fromRef: any }
local bullets: { Bullet } = {}

local params = RaycastParams.new()
params.CollisionGroup = "QBullet"
params.FilterType = Enum.RaycastFilterType.Exclude
params.FilterDescendantsInstances = {}

-- player gun state, owned by Raid's profile: { id, ammo, dur } plus timers here
type GunState = { lastShot: number, reloadAt: number?, reloadStart: number? }
local state: { [Player]: GunState } = {}
Weapons.getGun = nil :: ((Player) -> any)? -- Raid: the player's held firearm instance {id, ammo, dur}
Weapons.takeAmmo = nil :: ((Player, string, number) -> number)? -- Raid: remove up to n rounds of an ammo id, returns taken
Weapons.countAmmo = nil :: ((Player, string) -> number)?
Weapons.isDodging = nil :: ((Player) -> boolean)?

local function syncAmmo(p: Player)
	local g = Weapons.getGun and Weapons.getGun(p)
	if g then
		p:SetAttribute("Gun", g.id)
		p:SetAttribute("Mag", g.ammo)
		local ammoId = Guns.ammoOf(g.id)
		p:SetAttribute("Reserve", if ammoId and Weapons.countAmmo then Weapons.countAmmo(p, ammoId) else 0)
	else
		p:SetAttribute("Gun", nil)
		p:SetAttribute("Mag", 0)
		p:SetAttribute("Reserve", 0)
	end
end
Weapons.syncAmmo = syncAmmo

--- spawn one bullet (metres); used by players and enemies
function Weapons.spawn(b: Bullet)
	table.insert(bullets, b)
end

local function onFire(p: Player, muzzle: any, yaws: any, slope: any)
	if typeof(muzzle) ~= "Vector3" or typeof(yaws) ~= "table" or typeof(slope) ~= "number" then
		return
	end
	local char = p.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local g = Weapons.getGun and Weapons.getGun(p)
	if not root or not g then
		return
	end
	local row = Guns.row(g.id)
	if not row then
		return
	end
	local st = state[p] or { lastShot = -math.huge }
	state[p] = st
	local now = os.clock()
	if st.reloadAt then
		return
	end
	-- cadence: allow 80% of the gap for network jitter
	local gap = Guns.cooldown(row, 0) * ((row.BurstCount or 1) > 1 and 0.3 or 1)
	if now - st.lastShot < gap * 0.8 then
		return
	end
	if g.ammo <= 0 or (g.dur or 1) <= 0 then
		return
	end
	local rp = root.Position / S
	if (Vector2.new(muzzle.X, muzzle.Z) - Vector2.new(rp.X, rp.Z)).Magnitude > 2.5 then
		return
	end
	if Weapons.isDodging and Weapons.isDodging(p) then
		return
	end
	st.lastShot = now
	g.ammo -= 1
	local ammoId = Guns.ammoOf(g.id)
	local ammo = ammoId and Guns.items[ammoId] and Guns.items[ammoId].ammo
	g.dur = math.max(0, (g.dur or 100) - ((ammo and ammo.durCost) or 0.1))
	local n = math.max(1, math.floor((row.ShotCount or 1) + 0.5))
	local per = row.Damage * ((ammo and ammo.dmgMul) or 1) / n
	if row.Damage > 1 and per < 1 then
		per = 1
	end
	local range = Guns.range(row)
	local clean = {}
	for i = 1, math.min(#yaws, n) do
		local yaw = yaws[i]
		if typeof(yaw) ~= "number" then
			continue
		end
		table.insert(clean, yaw)
		local dir = Vector3.new(math.sin(yaw), math.clamp(slope, -2, 2), math.cos(yaw)).Unit
		Weapons.spawn({
			pos = muzzle,
			dir = dir,
			speed = row.BulletSpeed,
			left = range,
			half = range * 0.5,
			travelled = 0,
			team = 0,
			damage = per,
			dmgOver = row.DmgOverDistance or 0.5,
			crit = false,
			critMul = row.CritDamageFactor or 1,
			from = p,
			fromRef = p,
		})
	end
	-- everyone else draws the tracers
	for _, other in Players:GetPlayers() do
		if other ~= p then
			Net.event("Fx"):FireClient(other, "shot", muzzle, clean, slope, row.BulletSpeed, range)
		end
	end
	if Weapons.onNoise then
		Weapons.onNoise(rp, row.SoundRange or 20, p)
	end
	syncAmmo(p)
end

Weapons.onNoise = nil :: ((Vector3, number, any) -> ())?

local function onReload(p: Player)
	local g = Weapons.getGun and Weapons.getGun(p)
	if not g then
		return
	end
	local row = Guns.row(g.id)
	local st = state[p] or { lastShot = -math.huge }
	state[p] = st
	if st.reloadAt or not row or g.ammo >= row.Capacity then
		return
	end
	local ammoId = Guns.ammoOf(g.id)
	if not ammoId or not Weapons.countAmmo or Weapons.countAmmo(p, ammoId) <= 0 then
		Net.event("Toast"):FireClient(p, "No ammo", "bad")
		return
	end
	local now = os.clock()
	st.reloadStart = now
	st.reloadAt = now + row.ReloadTime
	local sNow = Workspace:GetServerTimeNow()
	p:SetAttribute("ReloadStart", sNow)
	p:SetAttribute("ReloadUntil", sNow + row.ReloadTime)
end

function Weapons.cancelReload(p: Player)
	local st = state[p]
	if st and st.reloadAt then
		st.reloadAt = nil
		p:SetAttribute("ReloadUntil", nil)
	end
end

-- closest hit of a segment (metres) against vertical capsules
local function hitCapsule(a: Vector3, b: Vector3, team: number): (number?, Target?)
	local best, bestT = nil :: number?, nil :: Target?
	local ab = Vector2.new(b.X - a.X, b.Z - a.Z)
	local len2 = ab:Dot(ab)
	for _, t in Weapons.targets do
		if t.team == team then
			continue
		end
		local fp = t.pos()
		if not fp then
			continue
		end
		local ac = Vector2.new(fp.X - a.X, fp.Z - a.Z)
		local u = if len2 > 0 then math.clamp(ac:Dot(ab) / len2, 0, 1) else 0
		local closest = Vector2.new(a.X, a.Z) + ab * u
		local d = (closest - Vector2.new(fp.X, fp.Z)).Magnitude
		if d <= t.radius then
			-- step back to the circle's entry point
			local back = math.sqrt(math.max(0, t.radius * t.radius - d * d))
			local ul = math.sqrt(len2)
			local uu = if ul > 0 then math.max(0, u - back / ul) else 0
			local y = a.Y + (b.Y - a.Y) * uu
			if y >= fp.Y - 0.05 and y <= fp.Y + t.height then
				if not best or uu < best then
					best, bestT = uu, t
				end
			end
		end
	end
	return best, bestT
end

local function step(dt: number)
	for i = #bullets, 1, -1 do
		local b = bullets[i]
		local stepLen = math.min(b.speed * dt, b.left)
		local a = b.pos
		local e = a + b.dir * stepLen
		local wall = Workspace:Raycast(a * S, b.dir * stepLen * S, params)
		local wallU = if wall then (wall.Position / S - a).Magnitude / math.max(1e-6, stepLen) else math.huge
		local u, t = hitCapsule(a, e, b.team)
		if t and u and u <= wallU then
			local at = a + (e - a) * u
			local travelled = b.travelled + stepLen * u
			local dmg = b.damage * (if travelled > b.half then b.dmgOver else 1) * (if b.crit then b.critMul else 1)
			local killed = t.hurt(dmg, { from = b.from, fromRef = b.fromRef, crit = b.crit, dir = b.dir, at = at })
			if b.from and b.from.Parent then
				Net.event("Hit"):FireClient(b.from, killed, b.crit, at + Vector3.new(0, 1, 0), dmg)
			end
			table.remove(bullets, i)
		elseif wall then
			local at = wall.Position / S
			for _, pl in Players:GetPlayers() do
				if pl ~= b.from then
					Net.event("Fx"):FireClient(pl, "impact", at, wall.Normal)
				end
			end
			table.remove(bullets, i)
		else
			b.pos = e
			b.left -= stepLen
			b.travelled += stepLen
			if b.left <= 1e-4 then
				table.remove(bullets, i)
			end
		end
	end
	-- reload completion: rounds move only when the timer finishes
	for p, st in state do
		if st.reloadAt and os.clock() >= st.reloadAt then
			st.reloadAt = nil
			local g = Weapons.getGun and Weapons.getGun(p)
			if g and Weapons.takeAmmo then
				local row = Guns.row(g.id)
				local ammoId = Guns.ammoOf(g.id)
				if row and ammoId then
					g.ammo += Weapons.takeAmmo(p, ammoId, row.Capacity - g.ammo)
				end
			end
			p:SetAttribute("ReloadUntil", nil)
			syncAmmo(p)
		end
	end
end

function Weapons.start()
	Net.event("Fire").OnServerEvent:Connect(onFire)
	Net.event("Reload").OnServerEvent:Connect(onReload)
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(p)
		state[p] = nil
	end)
	local _ = Config
end

return Weapons
