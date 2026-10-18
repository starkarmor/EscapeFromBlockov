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
local Inv = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Inv)
local Guns = require(Shared.Guns)
local Net = require(Shared.Net)
local Units = require(Shared.Units)
local Config = require(Shared.Config)
local Cover = require(script.Parent.Cover)

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
	model: Model?,
	stun: ((number) -> ())?,
}
-- registered by Raid (players) and Enemies
Weapons.targets = {} :: { [any]: Target }

export type Bullet = { weaponId: string?, pen: number?, armorBreak: number?, fromName: string?, bleed: number?, pos: Vector3, dir: Vector3, speed: number, left: number, half: number, travelled: number, team: number, damage: number, dmgOver: number, crit: boolean, critMul: number, from: Player?, fromRef: any }
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
Weapons.giveAmmo = nil :: ((Player, string, number) -> ())? -- Raid: rounds back into the backpack (an ammo swap)

local function nextType(p: Player, g: any): string?
	return Guns.ammoTypeFor(g, function(id)
		return if Weapons.countAmmo then Weapons.countAmmo(p, id) else 0
	end)
end
Weapons.isDodging = nil :: ((Player) -> boolean)?
Weapons.onBag = nil :: ((Player) -> ())?
Weapons.busy = nil :: ((Player) -> boolean)?

local function syncAmmo(p: Player)
	local g = Weapons.getGun and Weapons.getGun(p)
	if Weapons.onBag then
		Weapons.onBag(p)
	end
	if g then
		p:SetAttribute("Gun", g.id)
		-- the fitted parts (the client's feel uses the same Inv.gunFeel): "Slot=part,..."
		local att = {}
		for k, v in (g.att or {}) :: { [string]: string } do
			table.insert(att, k .. "=" .. v)
		end
		table.sort(att)
		p:SetAttribute("GunAtt", table.concat(att, ","))
		p:SetAttribute("Mag", g.ammo)
		p:SetAttribute("GunDur", g.dur or 100)
		-- Hud: the reserve of the type the next reload takes, the name of the loaded type
		local ammoId = nextType(p, g)
		p:SetAttribute("Reserve", if ammoId and Weapons.countAmmo then Weapons.countAmmo(p, ammoId) else 0)
		p:SetAttribute("AmmoType", Guns.loadedType(g))
		p:SetAttribute("AmmoSel", g.sel or Guns.loadedType(g))
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

local function onFire(p: Player, muzzle: any, yaws: any, slope: any, head: any)
	if typeof(muzzle) ~= "Vector3" or typeof(yaws) ~= "table" or typeof(slope) ~= "number" then
		return
	end
	local char = p.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local g = Weapons.getGun and Weapons.getGun(p)
	if not root or not g then
		return
	end
	local row = Inv.gunFeel(g)
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
	if (g.dur or 1) <= 0 then
		-- durability 0: "Gun broken!" re-shows at most every 2 s while the trigger is pressed (World.fireGun)
		if now - ((st :: any).brokenToast or -math.huge) > 2 then
			(st :: any).brokenToast = now
			Net.event("Toast"):FireClient(p, "Gun broken!", "bad")
		end
		return
	end
	if g.ammo <= 0 then
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
	local ammoId = Guns.loadedType(g)
	local ammo = ammoId and Guns.items[ammoId] and Guns.items[ammoId].ammo
	g.dur = math.max(0, (g.dur or 100) - ((ammo and ammo.durCost) or 0.1))
	local n = math.max(1, math.floor((row.ShotCount or 1) + 0.5))
	local per = row.Damage * ((ammo and ammo.dmgMul) or 1) / n
	if row.Damage > 1 and per < 1 then
		per = 1
	end
	local range = Guns.range(row)
	-- a head claim holds only with an enemy near the shot line within range (the client saw the cursor on its head)
	local crit = false
	if head == true and typeof(yaws[1]) == "number" then
		local dir2 = Vector2.new(math.sin(yaws[1]), math.cos(yaws[1]))
		for _, t in Weapons.targets do
			local tp = t.team ~= 0 and t.pos()
			if tp then
				local rel = Vector2.new(tp.X - muzzle.X, tp.Z - muzzle.Z)
				local along = rel:Dot(dir2)
				if along > 0 and along <= range and (rel - dir2 * along).Magnitude <= t.radius + 0.6 then
					crit = true
				end
			end
		end
	end
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
			crit = crit,
			critMul = row.CritDamageFactor or 1,
			pen = ammo and ammo.armorPen or 0,
			armorBreak = ammo and ammo.armorBreak or 0.55,
			from = p,
			fromRef = p,
			weaponId = g.id,
			fromName = p.DisplayName,
		})
	end
	-- everyone else draws the tracers
	for _, other in Players:GetPlayers() do
		if other ~= p then
			Net.event("Fx"):FireClient(other, "shot", muzzle, clean, slope, row.BulletSpeed, range, "#ffd27a")
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
	local row = Inv.gunFeel(g)
	local st = state[p] or { lastShot = -math.huge }
	state[p] = st
	-- Player.startReload: a different type to load counts as a reload even with a full magazine (the swap)
	local ammoId = nextType(p, g)
	local swapping = ammoId ~= Guns.loadedType(g) and (g.ammo or 0) > 0
	if st.reloadAt or not row or (g.ammo >= row.Capacity and not swapping) then
		return
	end
	if Weapons.busy and Weapons.busy(p) then
		return -- an item use / interaction runs (Player.startReload 'busy')
	end
	if not ammoId or not Weapons.countAmmo or Weapons.countAmmo(p, ammoId) <= 0 then
		-- 'noammo' is the only refusal with feedback (World: toast "Out of ammo")
		if g.ammo <= 0 then
			Net.event("Toast"):FireClient(p, "Out of ammo", "bad")
		end
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

--- everyone sees blood, flashes and decals; the shooter and the victim also get the damage number / hit marker
function Weapons.broadcastHit(t: Target, at: Vector3, dmg: number, crit: boolean, killed: boolean, from: Player?, bullet: boolean)
	local victim = if t.kind == "player" then t.ref else nil
	for _, pl in Players:GetPlayers() do
		Net.event("Fx"):FireClient(pl, "hit", {
			model = t.model,
			kind = t.kind,
			at = at,
			dmg = dmg,
			crit = crit,
			kill = killed,
			byPlayer = from ~= nil,
			mine = pl == from,
			me = pl == victim,
			bullet = bullet,
		})
	end
	if from and from.Parent and t.kind ~= "player" then
		Net.event("Hit"):FireClient(from, killed, crit, at, dmg)
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
			local killed = t.hurt(dmg, { weaponId = b.weaponId, pen = b.pen or 0, armorBreak = b.armorBreak or 0.55, from = b.from, fromRef = b.fromRef, fromName = b.fromName, bleed = b.bleed, crit = b.crit, dir = b.dir, at = at })
			Weapons.broadcastHit(t, at, dmg, b.crit, killed, b.from, true)
			table.remove(bullets, i)
		elseif wall then
			local at = wall.Position / S
			-- half cover takes the bullet's damage (x falloff; enemy bullets x0.5)
			local cid = Cover.of(wall.Instance)
			if cid then
				local travelled = b.travelled + (at - a).Magnitude
				local dmg = b.damage * (if travelled > b.half then b.dmgOver else 1)
				Cover.damage(cid, dmg * (if b.team ~= 0 then 0.5 else 1))
			end
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
				-- Player.finishReload: a different type swaps (the old rounds back to the bag), then fill the magazine
				local row = Inv.gunFeel(g)
				local ammoId = nextType(p, g)
				local cur = Guns.loadedType(g)
				if row and ammoId then
					if ammoId ~= cur and (g.ammo or 0) > 0 and cur and Weapons.giveAmmo then
						Weapons.giveAmmo(p, cur, g.ammo)
						g.ammo = 0
					end
					g.loaded = ammoId
					g.sel = ammoId
					g.ammo += Weapons.takeAmmo(p, ammoId, math.floor(row.Capacity) - g.ammo)
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
	-- BulletTypeHUD.SetBulletType: a different type becomes the target and the character tries to reload
	Net.event("SetAmmo").OnServerEvent:Connect(function(p, id)
		local g = Weapons.getGun and Weapons.getGun(p)
		if not g or typeof(id) ~= "string" or not table.find(Guns.ammoTypesFor(g.id), id) then
			return
		end
		if id == (g.sel or Guns.loadedType(g)) then
			return
		end
		g.sel = id
		Weapons.cancelReload(p)
		onReload(p)
		syncAmmo(p)
	end)
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(p)
		state[p] = nil
	end)
	local _ = Config
end

return Weapons
