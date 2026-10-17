--!strict
-- Ground Zero geese (src/entities/Enemy.ts + the decoded spawners in MapData.spawners).
-- Spawners: count [min, max] at random points of each spawner, rolled once at raid start, plus timed spawns (whenToSpawn).
-- AI states: patrol (wander within patrolRange, senses: sight cone sightAngle / sightDistance with walls that block sight,
-- hearing gunshots within SoundRange x hearingAbility, a 1.5 m 360 deg bubble), investigate (sight x1.25, walk to the last
-- noise / sighting, forget after forgetTime), combat (wait reactionTime, then fire bursts of shootTime seconds separated by
-- shootGap, strafe for combatMoveTime, track while in line within 20 m; melee geese chase and swing). AI beyond 50 m of every
-- player sleeps (activeDistance). Server-owned roots move by velocity like the players.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Guns = require(Shared.Guns)
local MapData = require(Shared.MapData)
local RigBuilder = require(Shared.RigBuilder)
local Weapons = require(script.Parent.Weapons)
local Raid = require(script.Parent.Raid)

local S = Units.S
local Enemies = {}

-- web roster kinds -> our defs (Roster.ts mapping; unported kinds fall back to the scav goose)
local KIND = {
	scav = "scrapper", -- spawner "type" field carries the web kind already; see below
}

type Enemy = {
	id: number,
	def: Config.EnemyDef,
	model: Model,
	root: BasePart,
	hp: number,
	state: string, -- "patrol" | "investigate" | "combat" | "dead"
	home: Vector2,
	target: Player?,
	lastSeen: Vector2?,
	lastSeenAt: number,
	reactAt: number,
	burstUntil: number,
	nextBurst: number,
	nextShot: number,
	strafeUntil: number,
	strafeDir: Vector2,
	moveTo: Vector2?,
	path: { Vector2 }?,
	pathAt: number,
	facing: number,
	gun: string,
	meleeCd: number,
	alertUntil: number,
	idleUntil: number,
}

local enemies: { [number]: Enemy } = {}
local nextId = 0
local folder = Workspace:WaitForChild("Characters")

local sightParams = RaycastParams.new()
sightParams.CollisionGroup = "QSight"
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.FilterDescendantsInstances = {}

local function pos2(e: Enemy): Vector2
	local p = e.root.Position
	return Vector2.new(p.X / S, p.Z / S)
end

local function canSee(from: Vector2, to: Vector2): boolean
	local a = Vector3.new(from.X, Config.View.eye, from.Y) * S
	local b = Vector3.new(to.X, Config.View.eye, to.Y) * S
	return Workspace:Raycast(a, b - a, sightParams) == nil
end

local function defFor(kind: string): Config.EnemyDef
	return Config.Enemies[kind] or Config.Enemies.scrapper
end

local function rand(a: number, b: number): number
	return a + (b - a) * math.random()
end

local corpseHook: ((Vector3, string, string) -> ())? = nil
function Enemies.onCorpse(fn: (Vector3, string, string) -> ())
	corpseHook = fn
end

local function die(e: Enemy, info: any)
	if e.state == "dead" then
		return
	end
	e.state = "dead"
	Weapons.targets[e] = nil
	local p = pos2(e)
	if corpseHook then
		corpseHook(Vector3.new(p.X, 0, p.Y), e.def.name, e.def.kind)
	end
	-- a short topple then remove (the loot stays as a corpse container)
	e.root.Anchored = true
	local cf = e.root.CFrame
	e.model:SetAttribute("Dead", true)
	task.spawn(function()
		for i = 1, 10 do
			e.root.CFrame = cf * CFrame.new(0, -i * 0.04 * S, 0) * CFrame.Angles(math.rad(i * 9), 0, 0)
			task.wait(1 / 30)
		end
		task.wait(1.5)
		e.model:Destroy()
	end)
	enemies[e.id] = nil
end

local function hurt(e: Enemy, dmg: number, info: any): boolean
	if e.state == "dead" then
		return false
	end
	e.hp -= dmg
	e.model:SetAttribute("HP", e.hp)
	-- getting shot reveals the shooter
	if info and info.from and e.state ~= "combat" then
		local r = Raid.posOf(info.from)
		if r then
			e.state = "combat"
			e.target = info.from
			e.lastSeen = Vector2.new(r.X, r.Z)
			e.lastSeenAt = os.clock()
			e.reactAt = os.clock() + e.def.reaction
		end
	end
	if e.hp <= 0 then
		die(e, info)
		return true
	end
	return false
end

function Enemies.spawn(kind: string, x: number, z: number): Enemy
	local def = defFor(kind)
	nextId += 1
	local model = RigBuilder.build(def.rig, def.name)
	model:SetAttribute("Enemy", true)
	model:SetAttribute("HP", def.hp)
	model:SetAttribute("MaxHP", def.hp)
	model:SetAttribute("Held", if def.melee then "melee" else "gun")
	model:PivotTo(CFrame.new(x * S, RigBuilder.ROOT_R + 0.2, z * S))
	model.Parent = folder
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	root:SetNetworkOwner(nil)
	local pick = def.weapons[math.random(1, #def.weapons)]
	local e: Enemy = {
		id = nextId,
		def = def,
		model = model,
		root = root,
		hp = def.hp,
		state = "patrol",
		home = Vector2.new(x, z),
		target = nil,
		lastSeen = nil,
		lastSeenAt = 0,
		reactAt = 0,
		burstUntil = 0,
		nextBurst = 0,
		nextShot = 0,
		strafeUntil = 0,
		strafeDir = Vector2.zero,
		moveTo = nil,
		path = nil,
		pathAt = 0,
		facing = math.random() * math.pi * 2,
		gun = pick and pick[1] or "tt33",
		meleeCd = 0,
		alertUntil = 0,
		idleUntil = os.clock() + rand(0, 3),
	}
	enemies[e.id] = e
	Weapons.targets[e] = {
		kind = "enemy",
		team = 1,
		pos = function()
			if e.state == "dead" or not e.root.Parent then
				return nil
			end
			local p = e.root.Position
			return Vector3.new(p.X / S, 0, p.Z / S)
		end,
		radius = def.hitRadius,
		height = Config.Body.hitHeight,
		hurt = function(dmg, info)
			return hurt(e, dmg, info)
		end,
		ref = e,
	}
	return e
end

-- players near a point (alive in raid)
local function livePlayers(): { { p: Player, pos: Vector2 } }
	local out = {}
	for _, p in Players:GetPlayers() do
		local r = Raid.raids[p]
		if r and r.alive then
			local pp = Raid.posOf(p)
			if pp then
				table.insert(out, { p = p, pos = Vector2.new(pp.X, pp.Z) })
			end
		end
	end
	return out
end

local function face(e: Enemy, want: number, dt: number, rate: number)
	local d = math.atan2(math.sin(want - e.facing), math.cos(want - e.facing))
	local step = math.rad(rate) * dt
	e.facing += math.clamp(d, -step, step)
end

local function moveToward(e: Enemy, goal: Vector2, speed: number, dt: number): boolean
	local p = pos2(e)
	-- path refresh every 1.5 s or when the goal moved far
	if not e.path or os.clock() - e.pathAt > 1.5 then
		e.pathAt = os.clock()
		local ok, path = pcall(function()
			local pth = PathfindingService:CreatePath({ AgentRadius = 0.3 * S, AgentHeight = 1 * S, AgentCanJump = false, WaypointSpacing = 2 * S })
			pth:ComputeAsync(Vector3.new(p.X, 0.2, p.Y) * S, Vector3.new(goal.X, 0.2, goal.Y) * S)
			return pth
		end)
		if ok and path and path.Status == Enum.PathStatus.Success then
			local wps = {}
			for _, w in path:GetWaypoints() do
				table.insert(wps, Vector2.new(w.Position.X / S, w.Position.Z / S))
			end
			table.remove(wps, 1)
			e.path = wps
		else
			e.path = { goal }
		end
	end
	local nextP = e.path and e.path[1] or goal
	while e.path and #e.path > 0 and (nextP - p).Magnitude < 0.5 do
		table.remove(e.path, 1)
		nextP = e.path[1] or goal
	end
	local d = nextP - p
	if (goal - p).Magnitude < 0.6 then
		e.root.AssemblyLinearVelocity = Vector3.new(0, math.min(0, e.root.AssemblyLinearVelocity.Y), 0)
		return true
	end
	local v = d.Unit * speed
	e.root.AssemblyLinearVelocity = Vector3.new(v.X * S, math.min(0, e.root.AssemblyLinearVelocity.Y), v.Y * S)
	return false
end

local function stop(e: Enemy)
	e.root.AssemblyLinearVelocity = Vector3.new(0, math.min(0, e.root.AssemblyLinearVelocity.Y), 0)
end

local function shoot(e: Enemy, at: Vector2)
	local row = Guns.row(e.gun) or Guns.row("tt33")
	local p = pos2(e)
	local mz = Guns.muzzle(e.gun, p.X, p.Y, e.facing)
	local base = math.atan2(at.X - mz.X, at.Y - mz.Z)
	-- AI scatter: the gun's hip scatter x gunScatterMultiplier (x3 vs a running target)
	local def, _ = Guns.scatterNow(row, 0)
	local tgtRun = e.target and e.target.Character and e.target.Character:FindFirstChild("HumanoidRootPart") and (e.target.Character.HumanoidRootPart :: BasePart).AssemblyLinearVelocity.Magnitude / S > 5
	local sc = math.rad(def * e.def.scatterMul * (if tgtRun then 3 else 1))
	local n = math.max(1, math.floor((row.ShotCount or 1) + 0.5))
	local yaws = {}
	for i = 1, n do
		local yaw = base + (math.random() - 0.5) * sc
		table.insert(yaws, yaw)
		local flat = math.max(1e-3, (at - Vector2.new(mz.X, mz.Z)).Magnitude)
		local slope = (Config.Body.aimPlane - mz.Y) / flat
		local dir = Vector3.new(math.sin(yaw), slope, math.cos(yaw)).Unit
		Weapons.spawn({
			pos = mz,
			dir = dir,
			speed = row.BulletSpeed * e.def.bulletSpeedMul,
			left = Guns.range(row),
			half = Guns.range(row) * 0.5,
			travelled = 0,
			team = 1,
			damage = row.Damage / n * e.def.dmgMul,
			dmgOver = row.DmgOverDistance or 0.5,
			crit = false,
			critMul = 1,
			from = nil,
			fromRef = e,
		})
	end
	for _, pl in Players:GetPlayers() do
		Net.event("Fx"):FireClient(pl, "shot", mz, yaws, (Config.Body.aimPlane - mz.Y) / math.max(1e-3, (at - Vector2.new(mz.X, mz.Z)).Magnitude), row.BulletSpeed * e.def.bulletSpeedMul, Guns.range(row))
	end
	e.nextShot = os.clock() + Guns.cooldown(row, 0)
end

local function think(e: Enemy, dt: number, players: { { p: Player, pos: Vector2 } })
	local now = os.clock()
	local p = pos2(e)
	-- sleep beyond activeDistance of every player
	local nearest, nd = nil :: { p: Player, pos: Vector2 }?, math.huge
	for _, pl in players do
		local d = (pl.pos - p).Magnitude
		if d < nd then
			nearest, nd = pl, d
		end
	end
	if nd > Config.AI.activeDistance then
		stop(e)
		return
	end
	-- senses
	local sightMul = if e.state == "investigate" then Config.AI.alertSightMul else 1
	local seen: { p: Player, pos: Vector2 }? = nil
	for _, pl in players do
		local d = (pl.pos - p).Magnitude
		local inBubble = d <= Config.View.bubble
		local ang = math.atan2(pl.pos.X - p.X, pl.pos.Y - p.Y)
		local off = math.abs(math.atan2(math.sin(ang - e.facing), math.cos(ang - e.facing)))
		local inCone = d <= e.def.sight * sightMul and off <= math.rad(e.def.sightAngle / 2)
		local tracking = e.state == "combat" and e.target == pl.p and d <= Config.AI.trackRange
		if (inBubble or inCone or tracking) and canSee(p, pl.pos) then
			seen = pl
			break
		end
	end
	if seen then
		if e.state ~= "combat" then
			e.state = "combat"
			e.reactAt = now + e.def.reaction
		end
		e.target = seen.p
		e.lastSeen = seen.pos
		e.lastSeenAt = now
	end

	if e.state == "combat" then
		local tp = e.lastSeen or p
		local want = math.atan2(tp.X - p.X, tp.Y - p.Y)
		face(e, want, dt, Config.Move.aimTurn)
		if not seen and now - e.lastSeenAt > e.def.forget then
			e.state = "patrol"
			e.target = nil
			stop(e)
			return
		end
		if e.def.melee then
			-- chase and swing (ButcherKnife: 27 dmg, 2.2 / s, range 1.55)
			local d = (tp - p).Magnitude
			if d > 1.3 then
				moveToward(e, tp, e.def.run, dt)
			else
				stop(e)
				if now >= e.meleeCd and seen then
					e.meleeCd = now + 1 / 2.2
					e.model:SetAttribute("MeleeAt", Workspace:GetServerTimeNow())
					task.delay(0.12, function()
						if e.state ~= "dead" and seen and Raid.raids[seen.p] then
							local np = Raid.posOf(seen.p)
							if np and (Vector2.new(np.X, np.Z) - pos2(e)).Magnitude <= 1.55 + 0.5 then
								Raid.hurt(seen.p, 27 * e.def.dmgMul, { fromName = e.def.name })
							end
						end
					end)
				end
			end
			return
		end
		-- ranged: strafe, burst fire after the reaction delay
		if now >= e.strafeUntil then
			e.strafeUntil = now + rand(e.def.combatMoveTime[1], e.def.combatMoveTime[2])
			local a = math.random() * math.pi * 2
			e.strafeDir = Vector2.new(math.cos(a), math.sin(a))
			e.path = nil
		end
		local goal = e.home + e.strafeDir * math.min(e.def.combatMoveRange, 3)
		if not seen then
			goal = tp
		end
		moveToward(e, goal, e.def.walk * 0.6, dt)
		if seen and now >= e.reactAt then
			if now >= e.nextBurst and now > e.burstUntil then
				e.burstUntil = now + rand(e.def.shootTime[1], e.def.shootTime[2])
				e.nextBurst = e.burstUntil + rand(e.def.shootGap[1], e.def.shootGap[2])
			end
			if now <= e.burstUntil and now >= e.nextShot and math.abs(math.atan2(math.sin(want - e.facing), math.cos(want - e.facing))) < 0.2 then
				shoot(e, tp)
			end
		end
	elseif e.state == "investigate" then
		local goal = e.lastSeen or e.home
		local arrived = moveToward(e, goal, e.def.walk, dt)
		local v = e.root.AssemblyLinearVelocity
		if v.Magnitude > 0.1 then
			face(e, math.atan2(v.X, v.Z), dt, Config.Move.turn)
		end
		if now > e.alertUntil or arrived and now > e.alertUntil - e.def.forget * 0.5 then
			e.state = "patrol"
		end
	else
		-- patrol: wander within patrolRange of home
		if now >= e.idleUntil then
			if not e.moveTo then
				local a = math.random() * math.pi * 2
				local r = math.random() * e.def.patrolRange
				e.moveTo = e.home + Vector2.new(math.cos(a), math.sin(a)) * r
				e.path = nil
			end
			if moveToward(e, e.moveTo :: Vector2, e.def.walk * 0.5, dt) then
				e.moveTo = nil
				e.idleUntil = now + rand(2, 5)
			end
			local v = e.root.AssemblyLinearVelocity
			if v.Magnitude > 0.1 then
				face(e, math.atan2(v.X, v.Z), dt, Config.Move.turn)
			end
		else
			stop(e)
		end
	end
end

function Enemies.noise(at: Vector3, range: number, src: any)
	for _, e in enemies do
		if e.state == "patrol" or e.state == "investigate" then
			if (pos2(e) - Vector2.new(at.X, at.Z)).Magnitude < range then
				e.state = "investigate"
				e.lastSeen = Vector2.new(at.X, at.Z)
				e.alertUntil = os.clock() + e.def.forget
				e.path = nil
			end
		end
	end
end

-- roll the decoded spawners: count [min, max] at distinct points, the per-point kind mix (`kinds`), the spawn delay
-- (whenToSpawn: raid seconds), minDist from every player; boss groups pick one option. Unported kinds are skipped and
-- listed in the port ledger (boss, contractor, wolf, giant, operator; bloater / stormling / drone need rain, storm, night).
local PORTED = { scrapper = true, scav = true, brute = true, scrapper_rifle = true }
local function rollSpawners()
	local n, skipped = 0, {}
	local groupPick: { [string]: number } = {}
	for _, sp in MapData.spawners or {} do
		if sp.group then
			if groupPick[sp.group] == nil then
				groupPick[sp.group] = math.random(0, 2)
			end
			if sp.option ~= groupPick[sp.group] then
				continue
			end
		end
		local kind = sp.type or "scrapper"
		if not PORTED[kind] then
			skipped[kind] = (skipped[kind] or 0) + 1
			continue
		end
		if (sp.prob or 1) < math.random() then
			continue
		end
		local lo, hi = sp.count and sp.count[1] or 1, sp.count and sp.count[2] or 1
		local count = math.random(lo, hi)
		task.delay(sp.delay or 0, function()
			local pts = table.clone(sp.points or {})
			local players = livePlayers()
			local placed = 0
			while placed < count and #pts > 0 do
				local pt = table.remove(pts, math.random(1, #pts))
				local far = true
				for _, pl in players do
					if (pl.pos - Vector2.new(pt.x, pt.z)).Magnitude < (sp.minDist or 0) then
						far = false
					end
				end
				if far then
					local k = kind
					if sp.kinds then
						local r, acc = math.random(), 0
						for _, kw in sp.kinds do
							acc += kw[2]
							if r <= acc then
								k = kw[1]
								break
							end
						end
					end
					if k == "scrapper_rifle" then
						local e = Enemies.spawn("scrapper", pt.x, pt.z)
						e.gun = "ak74u"
					elseif PORTED[k] then
						Enemies.spawn(k, pt.x, pt.z)
					end
					placed += 1
					n += 1
				end
			end
		end)
	end
	task.delay(4, function()
		print(string.format("[Canuckov] spawned %d geese at start; unported spawners: %s", n, game:GetService("HttpService"):JSONEncode(skipped)))
	end)
end

function Enemies.start()
	Weapons.onNoise = function(at, range, src)
		Enemies.noise(at, range, src)
	end
	local _ = KIND
	task.delay(1, rollSpawners)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		local players = livePlayers()
		for _, e in enemies do
			if e.state ~= "dead" and e.root.Parent then
				think(e, dt, players)
				local align = e.root:FindFirstChild("Facing") :: AlignOrientation?
				if align then
					align.CFrame = CFrame.Angles(0, e.facing + math.pi, 0)
				end
			end
		end
		acc += dt
	end)
end

return Enemies
