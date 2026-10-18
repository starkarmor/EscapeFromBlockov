--!strict
-- Ground Zero enemies, 1:1 with the web build's src/entities/Enemy.ts + World.ts AI driver (spec: docs/enemy-ai-spec.md).
--   FSM init -> patrol <-> alert -> combat (combat drops straight to patrol when the foe is lost).
--   Perception: one queued sight search / line check per enemy, the brain answers 3 + 3 per frame (AIMainBrain quotas);
--   cone = fov 100 deg within sight x (1 patrol, 1.25 alert, 1.5 combat re-acquire, x2 for 1.5 s after a hit), a 1.5 m
--   bubble with no cone or line test; hearing (footsteps 8 / 16 m, gunfire SoundRange) sets noticed / noticeFrom.
--   Movement: move / trace tasks (8 s time-out, trace repath 0.15 s) on paths from the decoded navmesh (server/Nav.luau,
--   one frame latency), waypoints at 0.6 m, stop at 0.2 m, walk 4 / run 6 m/s x mv with 50 / 70 m/s^2 acceleration.
--   Combat: reaction delay, strafe within 2..combatMoveRange of the foe, pursue the last seen point when blocked, attack
--   loop gate -> range -> delay -> shoot burst -> gap; melee kinds trace to 1.5 m and swing. Enemies of other teams fight
--   each other (wolves vs scavs). Activation within 50 m of a player.
-- Bodies are Creator Store characters (ReplicatedStorage/CreatorAssets/NPC_<kind>) driven through their Humanoid; the
-- wolf is a static store mesh on a ball root.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Guns = require(Shared.Guns)
local Curve = require(Shared.Curve)
local MapData = require(Shared.MapData)
local Weapons = require(script.Parent.Weapons)
local Raid = require(script.Parent.Raid)
local Nav = require(script.Parent.Nav)
local Avatar = require(script.Parent.Avatar)
local Cover = require(script.Parent.Cover)
local Grenades = require(script.Parent.Grenades)
local Weather = require(script.Parent.Weather)
local Items = require(Shared.gen.Items)

local S = Units.S
local Enemies = {}
-- TimeOfDayPost angle factor for AI sight (the weather sets it; Sunny night 0.4)
Enemies.nightAngle = 1

-- Enemy.ts AI constants
local SENSE = 1.5
local SEARCH_EVERY = 0.05
local TRACE_REPATH = 0.15
local STOP_DIST = 0.2
local SLOW_IN = 0.6
local TASK_OVER = 8
local NOTICE_FRESH = 0.4
local LOST_SNAP = 0.25
local SIGHT_ALERT, SIGHT_COMBAT = 1.25, 1.5
local TRACK_RANGE = 20
local MELEE_LOST_RANGE, MELEE_LOST_T = 24, 7
local ACTIVE = 50
local MAX_SEARCH, MAX_CHECK = 3, 3
local SEMI_PRESS = 0.35
local RUN_SCATTER, OFF_SCATTER = 3, 4
local EYE, LOW = 1.5, 0.4
local STAMINA_MAX, STAMINA_DRAIN, STAMINA_RECOVER, STAMINA_DELAY = 100, 7, 20, 1.5
local WALK_ACC, RUN_ACC = 50, 70
local WALK_SOUND, RUN_SOUND = 8, 16
local STEP_WALK, STEP_RUN = 3.3, 5.5
local PATH_BUDGET = 0.004 -- s of path search per frame (the web searches every queued request in one frame)
local HURT_FRESH = 1.5
local DEALT = 0.12
local SWING = 0.25

local DASH = Config.Dash

type Task = {
	target: Vector2,
	t: number,
	over: number,
	trace: (() -> Vector2?)?,
	stopDist: number,
	repath: number,
	aimAt: Vector2?,
	pending: boolean,
	done: boolean,
}

export type Enemy = {
	id: number,
	def: any,
	model: Model,
	root: BasePart,
	hum: Humanoid?,
	align: AlignOrientation?,
	team: number,
	hp: number,
	maxHp: number,
	dead: boolean,
	pos: Vector2,
	vel: Vector2,
	facing: number,
	spawn: Vector2,
	patrolPos: Vector2,
	group: { Enemy }?,
	leader: Enemy?,
	active: boolean,
	fsm: string,
	fsmT: number,
	turnT: number,
	turnStat: number,
	reaction: number,
	traceChance: number,
	foe: any,
	alert: boolean,
	noticed: boolean,
	noticeT: number,
	noticeFrom: Vector2,
	lastHurt: number,
	lastHurtDmg: number,
	lastHurtByChar: boolean,
	searchT: number,
	searchPending: boolean,
	checkPending: boolean,
	checkBlocked: boolean,
	waitT: number,
	loopStep: number,
	loopRoll: boolean,
	alertForget: number,
	reactT: number,
	atk: string,
	atkT: number,
	shootT: number,
	semiT: number,
	gapT: number,
	wantAttack: boolean,
	wantT: number,
	atkSeq: number,
	lostT: number,
	hasTarget: boolean,
	hasTargetT: number,
	hasObstacle: boolean,
	runInput: boolean,
	running: boolean,
	wasRunning: boolean,
	aimTarget: string?,
	aimPos: Vector2?,
	task: Task?,
	taskTimedOut: boolean,
	path: { Vector2 }?,
	wp: number,
	pathReq: number,
	navY: number?,
	moveIn: Vector2,
	stamina: number,
	lastSpend: number,
	dashT: number,
	dashDir: Vector2,
	dashTaskT: number,
	dashNext: number,
	dashEnd: number,
	gun: string,
	row: any,
	ammo: number,
	reloadT: number,
	reloads: number,
	cdLeft: number,
	burstLeft: number,
	gunScatter: number,
	trigger: boolean,
	press: boolean,
	pressBuf: boolean,
	aiming: boolean,
	swingT: number,
	lastSwing: number,
	stepT: number,
	tracks: { [string]: AnimationTrack },
	armor: { id: string, value: number, dur: number }?,
	stunUntil: number?,
	lastAttacker: any,
	items: { { id: string, n: number } },
	useT: number,
	useId: string?,
	useStand: boolean,
	healCheckT: number,
	skillCheckT: number,
	throwT: number,
	throwId: string?,
	throwAt: Vector2?,
	danger: any,
	fleeT: number,
	dangerSaid: number,
	helmet: { id: string, value: number, dur: number }?,
	anim: string,
}

local enemies: { [number]: Enemy } = {}
local nextId = 0
local folder = Workspace:WaitForChild("Characters")
local clock = 0 -- World.time (s)

local sightParams = RaycastParams.new()
sightParams.CollisionGroup = "QSight"
sightParams.FilterType = Enum.RaycastFilterType.Exclude
local hardParams = RaycastParams.new()
hardParams.CollisionGroup = "QSightHard"
hardParams.FilterType = Enum.RaycastFilterType.Exclude

local rng = Random.new()
local function U(a: number, b: number): number
	return a + (b - a) * rng:NextNumber()
end
local function angleDiff(a: number, b: number): number
	return math.atan2(math.sin(a - b), math.cos(a - b))
end

--- aiSight: no sight-blocking box (QSight: walls + foliage; hurt searches see through foliage) between a and b at y
local function aiSight(a: Vector2, b: Vector2, y: number, throughFoliage: boolean): boolean
	local A = Vector3.new(a.X, y, a.Y) * S
	local B = Vector3.new(b.X, y, b.Y) * S
	return Workspace:Raycast(A, B - A, if throughFoliage then hardParams else sightParams) == nil
end

-- Enemy.ts isEnemyTeam
local function isEnemyTeam(a: number, b: number): boolean
	if a == 5 or b == 5 then
		return false
	end
	if a == 7 then
		return true
	end
	return a ~= b
end

local function targetOf(key: any): Weapons.Target?
	return if key ~= nil then Weapons.targets[key] else nil
end
local function posOf(key: any): Vector2?
	local t = targetOf(key)
	local p = t and t.pos()
	return if p then Vector2.new(p.X, p.Z) else nil
end

-- players' movement state for hearing and AI scatter (the client reports run / ADS; positions are the server's)
local pState: { [Player]: { sprint: boolean, ads: boolean, stepT: number } } = {}

local function say(e: Enemy, text: string)
	if e.def.canTalk == false then
		return
	end
	e.model:SetAttribute("Say", text)
	e.model:SetAttribute("SayAt", Workspace:GetServerTimeNow())
end

------------------------------------------------------------------------------------------------------------------------
-- hearing / damage

--- Enemy.hear: types 0 footstep / noise, 1 gunfire, 2 grenade; same-team 0 / 1 are ignored
local function hear(e: Enemy, x: number, z: number, radius: number, kind: number, team: number)
	if e.dead then
		return
	end
	if (kind == 0 or kind == 1) and team == e.team then
		return
	end
	if (e.pos - Vector2.new(x, z)).Magnitude < radius * (e.def.hearing or 1) then
		e.noticed = true
		e.noticeT = clock
		e.noticeFrom = Vector2.new(x, z)
	end
end

function Enemies.hear(x: number, z: number, radius: number, kind: number, team: number)
	for _, e in enemies do
		hear(e, x, z, radius, kind, team)
	end
end

local corpseHook: ((Vector3, string, string, Model, string?, { any }?, { any }?) -> ())? = nil
function Enemies.onCorpse(fn: (Vector3, string, string, Model, string?, { any }?, { any }?) -> ())
	corpseHook = fn
end
Enemies.openDoor = nil :: ((Vector2, number) -> ())? -- Loot: aiOpenDoor

local XP = { scrapper = 15, scav = 20, brute = 40, contractor = 250, boss = 1000, wolf = 50 }

local function stopTracks(e: Enemy)
	for _, t in e.tracks do
		t:Stop(0.1)
	end
end

local function die(e: Enemy, info: any)
	if e.dead then
		return
	end
	e.dead = true
	e.fsm = "dead"
	Weapons.targets[e] = nil
	enemies[e.id] = nil
	-- the body falls on its back (clients animate from DeadAt) and stays for the raid as the loot container
	if e.hum then
		e.hum:Move(Vector3.zero)
		e.hum.WalkSpeed = 0
	end
	e.root.AssemblyLinearVelocity = Vector3.zero
	e.root.Anchored = true
	stopTracks(e)
	e.model:SetAttribute("Dead", true)
	e.model:SetAttribute("DeadAt", Workspace:GetServerTimeNow())
	e.model:SetAttribute("HP", 0)
	if info and info.from and Raid.addXp then
		Raid.addXp(info.from, XP[e.def.kind] or 0)
	end
	-- the group's lead passes to the last living member
	if e.group then
		for i = #e.group, 1, -1 do
			if e.group[i] == e then
				table.remove(e.group, i)
			end
		end
	end
	if corpseHook then
		local worn = {}
		for _, g in { e.armor, e.helmet } do
			if g and g.id ~= "" then
				table.insert(worn, { id = g.id, dur = g.dur })
			end
		end
		corpseHook(Vector3.new(e.pos.X, 0, e.pos.Y), e.def.name, e.def.kind, e.model, if e.def.melee or Guns.items[e.gun] == nil then nil else e.gun, worn, e.items)
	end
end

--- Enemy.takeDamage: records the hit, notices the attacker's position (no direct acquisition: the alert / hurt search
--- finds it); dashing is immune
local function hurt(e: Enemy, dmg: number, info: any): boolean
	if e.dead or e.dashT > 0 then
		return false
	end
	-- Health.Hurt: AI-vs-AI x attacker.aiCombatFactor / victim.aiCombatFactor
	local attacker = info and info.fromRef
	if attacker and typeof(attacker) == "table" and attacker.def and not info.from then
		dmg *= (attacker.def.aiCombat or 1) / (e.def.aiCombat or 1)
	end
	-- armorMultiplier: a crit hits the helmet, else the body armor: x 2 / (clamp(armor - AP, 0, 999) + 2)
	local worn = if info and info.crit then e.helmet else e.armor
	if worn and worn.dur > 0 and worn.value > 0 and not (info and info.direct) then
		dmg *= 2 / (math.clamp(worn.value - ((info and info.pen) or 0), 0, 999) + 2)
		worn.dur = math.max(0, worn.dur - ((info and info.armorBreak) or 0.55))
	end
	e.hp -= dmg
	e.model:SetAttribute("HP", math.max(0, e.hp))
	local src = info and (info.from or info.fromRef)
	local at = src and posOf(src)
	if info and info.stun then
		e.stunUntil = clock + info.stun
	end
	e.lastHurt = clock
	e.lastHurtDmg = dmg
	e.lastHurtByChar = at ~= nil
	if src then
		e.lastAttacker = src
	end
	if at then
		e.noticed = true
		e.noticeT = clock
		e.noticeFrom = at
	end
	if e.hp <= 0 then
		die(e, info)
		return true
	end
	return false
end

local function hurtWithin(e: Enemy, minDmg: number, within: number): boolean
	return clock - e.lastHurt < within and e.lastHurtByChar and e.lastHurtDmg >= minDmg
end

------------------------------------------------------------------------------------------------------------------------
-- brain queues (searches and line checks, 3 + 3 per frame) and path requests

type SearchReq = { e: Enemy, pos: Vector2, facing: number, mult: number, night: boolean }
local searchQ: { SearchReq } = {}
local checkQ: { Enemy } = {}
type PathReq = { e: Enemy, task: Task, req: number, a: Vector2, b: Vector2 }
local pathQ: { PathReq } = {}
local pathDone: { { e: Enemy, task: Task, req: number, path: { Vector2 } } } = {}

local function searchNow(r: SearchReq)
	local e = r.e
	if e.dead then
		return
	end
	local hurtSearch = hurtWithin(e, 1, HURT_FRESH)
	local dist = e.def.sight * r.mult * (if hurtSearch then 2 else 1)
	local angle = e.def.sightAngle
	if r.night then
		-- patrol searches narrow at night: fov x lerp(NightViewAngleFactor, 1, nightVisionAbility)
		local nf = Weather.tod[1]
		angle *= nf + (1 - nf) * (e.def.nightVision or 0.5)
	end
	local best, bestD = nil, math.huge
	for key, t in Weapons.targets do
		if key == e or (t.kind ~= "player" and t.kind ~= "enemy") or not isEnemyTeam(e.team, t.team) then
			continue
		end
		local tp = t.pos()
		if not tp then
			continue
		end
		local p = Vector2.new(tp.X, tp.Z)
		local d = (p - r.pos).Magnitude
		if d >= bestD or d > dist then
			continue
		end
		if d > SENSE then
			local dir = math.atan2(p.X - r.pos.X, p.Y - r.pos.Y)
			if math.abs(angleDiff(dir, r.facing)) > math.rad(angle) / 2 then
				continue
			end
			if not aiSight(r.pos, p, EYE, hurtSearch) then
				continue
			end
		end
		best, bestD = key, d
	end
	if best ~= nil then
		e.foe = best
	end
end

local function search(e: Enemy, mult: number, night: boolean)
	if e.searchPending then
		return
	end
	e.searchPending = true
	table.insert(searchQ, { e = e, pos = e.pos, facing = e.facing, mult = mult, night = night })
end

local function lineBlocked(e: Enemy): boolean
	if not e.checkPending then
		e.checkPending = true
		table.insert(checkQ, e)
	end
	return e.checkBlocked
end

local function runBrain()
	for _ = 1, MAX_SEARCH do
		local r = table.remove(searchQ, 1)
		if not r then
			break
		end
		r.e.searchPending = false
		r.e.searchT = SEARCH_EVERY
		searchNow(r)
	end
	for _ = 1, MAX_CHECK do
		local e = table.remove(checkQ, 1)
		if not e then
			break
		end
		e.checkPending = false
		local fp = posOf(e.foe)
		if fp and not e.dead then
			e.checkBlocked = not aiSight(e.pos, fp, LOW, hurtWithin(e, 1, HURT_FRESH))
		end
	end
end

local function runPaths()
	local t0 = os.clock()
	while #pathQ > 0 and os.clock() - t0 < PATH_BUDGET do
		local r = table.remove(pathQ, 1) :: PathReq
		if r.e.dead or r.e.task ~= r.task or r.e.pathReq ~= r.req then
			continue
		end
		-- World.findPath: the start triangle with the previous height hint, its height kept as the next hint
		local s = Nav.locate(r.a.X, r.a.Y, r.e.navY)
		if s > 0 then
			r.e.navY = Nav.height(s)
		end
		local path = Nav.findPath(r.a.X, r.a.Y, r.b.X, r.b.Y, r.e.navY)
		if path then
			table.insert(pathDone, { e = r.e, task = r.task, req = r.req, path = path })
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- tasks

local function stopMove(e: Enemy)
	e.task = nil
	e.path = nil
	e.moveIn = Vector2.zero
end

local function moveTo(e: Enemy, p: Vector2, over: number, aimAt: Vector2?)
	e.task = { target = p, t = 0, over = over, trace = nil, stopDist = 0, repath = 0, aimAt = aimAt, pending = true, done = false }
	e.taskTimedOut = false
end

local function traceTo(e: Enemy, getter: () -> Vector2?, stopDist: number, over: number)
	local p = getter() or e.pos
	e.task = { target = p, t = 0, over = over, trace = getter, stopDist = stopDist, repath = TRACE_REPATH, aimAt = nil, pending = true, done = false }
	e.taskTimedOut = false
end

--- true when the task is over (time-out, trace target gone / reached, arrived)
local function tickTask(e: Enemy, dt: number): boolean
	local k = e.task
	if not k then
		return true
	end
	k.t += dt
	if k.t > k.over then
		e.taskTimedOut = true
		stopMove(e)
		return true
	end
	if k.trace then
		local p = k.trace()
		if not p then
			stopMove(e)
			return true
		end
		if (p - e.pos).Magnitude < k.stopDist then
			stopMove(e)
			return true
		end
		k.repath -= dt
		if k.repath <= 0 then
			k.repath = TRACE_REPATH
			k.target = p
			k.pending = true
		end
	end
	if k.done or (k.target - e.pos).Magnitude < STOP_DIST then
		stopMove(e)
		return true
	end
	return false
end

--- Enemy.randomPoint: on the agent's side of c, `avoid`..`radius` away, within angleDeg
local function randomPoint(e: Enemy, c: Vector2, radius: number, avoid: number, angleDeg: number): Vector2
	local d = c - e.pos
	local dir: Vector2
	if d.Magnitude < 0.1 then
		local a = rng:NextNumber() * math.pi * 2
		dir = Vector2.new(math.sin(a), math.cos(a))
	else
		dir = d.Unit
	end
	local a = (rng:NextNumber() - 0.5) * math.rad(angleDeg)
	local r = avoid + rng:NextNumber() * (radius - avoid)
	local dx, dz = dir.X, dir.Y
	local u = Vector2.new(-dx * math.cos(a) - dz * math.sin(a), dx * math.sin(a) - dz * math.cos(a))
	return c + u * r
end

------------------------------------------------------------------------------------------------------------------------
-- guns

local function aimRange(e: Enemy): number
	if not e.row then
		return 8
	end
	return e.row.BulletDistance * (e.def.rangeMul or 1) - 0.4
end

local function startReload(e: Enemy)
	local row = e.row
	if not row or e.ammo >= row.Capacity or e.dashT > 0 or e.reloadT > 0 or e.atk == "shoot" then
		return
	end
	e.reloadT = math.max(1e-6, row.ReloadTime / (1 + (e.def.reloadGain or 0)))
end

local function reloadIfEmpty(e: Enemy, speak: boolean)
	if e.row and e.ammo <= 0 then
		if speak then
			e.reloads += 1
			if e.reloads >= 2 then
				say(e, "Reloading!")
			end
		end
		startReload(e)
	end
end

local function playerRunning(key: any): boolean
	if typeof(key) == "Instance" and key:IsA("Player") then
		local st = pState[key]
		return st ~= nil and st.sprint
	end
	return false
end

local function onScreen(p: Vector2): boolean
	-- the shooter is inside some player's view (the gameplay camera frames about 18 m around its player)
	for _, pl in Players:GetPlayers() do
		local pp = Raid.posOf(pl)
		if pp and (Vector2.new(pp.X, pp.Z) - p).Magnitude < 18 then
			return true
		end
	end
	return false
end

local function shootOnce(e: Enemy)
	local row = e.row
	local at = posOf(e.foe) or e.aimPos
	if not row or not at then
		return
	end
	local mz = Guns.muzzle(e.gun, e.pos.X, e.pos.Y, e.facing)
	local base = math.atan2(at.X - mz.X, at.Y - mz.Z)
	-- Enemy.scatterDeg: gunScatter x max(0.1, scatter x (1 + m)); m = 3 vs a running player, >= 4 off screen
	local m = 1
	local t = targetOf(e.foe)
	if t and t.kind == "player" then
		m = if playerRunning(e.foe) then (e.def.runScatter or RUN_SCATTER) else 1
		if not onScreen(e.pos) then
			m = math.max(m, e.def.offScreenScatter or OFF_SCATTER)
		end
	end
	local cone = math.rad(e.gunScatter * math.max(0.1, e.def.scatterMul * (1 + m)))
	local n = math.max(1, math.floor((row.ShotCount or 1) + 0.5))
	local range = (row.BulletDistance * (e.def.rangeMul or 1) + 0.4) * 1.05
	local half = (row.BulletDistance * (e.def.rangeMul or 1) + 0.4) * 0.5
	local flat = math.max(1e-3, (at - Vector2.new(mz.X, mz.Z)).Magnitude)
	local slope = (Config.Body.aimPlane - mz.Y) / flat
	local critRate = (row.CritRate or 0) * (1 + (e.def.critGain or 0))
	local yaws = {}
	-- a fanned gun (ShotAngle): pellets spread over the fan; a full ring loses one step and shifts half a step when even
	local fan = row.ShotAngle or 0
	local span, step0 = 0, 0
	if n > 1 and fan > 0 then
		span = if fan >= 360 then fan - fan / n else fan
		step0 = span / (n - 1)
	end
	for i = 1, n do
		local off = if n > 1 and fan > 0 then math.rad(-span / 2 + step0 * (i - 1) + (if fan >= 360 and n % 2 == 0 then step0 / 2 else 0)) else 0
		local yaw = base + off + (rng:NextNumber() - 0.5) * cone
		table.insert(yaws, yaw)
		local crit = rng:NextNumber() < critRate
		Weapons.spawn({
			pos = mz,
			dir = Vector3.new(math.sin(yaw), slope, math.cos(yaw)).Unit,
			speed = row.BulletSpeed * e.def.bulletSpeedMul,
			left = range,
			half = half,
			travelled = 0,
			team = e.team,
			damage = row.Damage * e.def.dmgMul / n,
			dmgOver = row.DmgOverDistance or 0.5,
			crit = crit,
			critMul = row.CritDamageFactor or 1,
			from = nil,
			fromRef = e,
			fromName = e.def.name,
			weaponId = e.gun,
			bleed = 0.03,
		})
	end
	for _, pl in Players:GetPlayers() do
		Net.event("Fx"):FireClient(pl, "shot", mz, yaws, slope, row.BulletSpeed * e.def.bulletSpeedMul, range)
	end
	-- AI gunfire is heard by every other team (World.ts: hear type 1)
	Enemies.hear(mz.X, mz.Z, row.SoundRange or 20, 1, e.team)
	e.ammo -= 1
	-- cadence and the scatter bloom
	if e.burstLeft <= 0 then
		e.burstLeft = math.max(1, math.floor((row.BurstCount or 1) + 0.5))
	end
	e.burstLeft -= 1
	e.cdLeft = Guns.cooldown(row, e.burstLeft)
	local _, max, grow = Guns.scatterNow(row, 0)
	e.gunScatter = math.min(max, e.gunScatter + grow)
end

--- Enemy.fireGun
local function fireGun(e: Enemy, dt: number)
	local row = e.row
	if not row then
		return
	end
	e.cdLeft = math.max(0, e.cdLeft - dt)
	local def, _, _, recover = Guns.scatterNow(row, 0)
	if e.gunScatter > def then
		e.gunScatter = math.max(def, e.gunScatter - recover * dt)
	elseif e.gunScatter < def then
		e.gunScatter = math.min(def, e.gunScatter + recover * 6 * dt)
	end
	if e.reloadT > 0 then
		e.reloadT -= dt
		if e.reloadT <= 0 then
			e.reloadT = 0
			e.ammo = row.Capacity
		end
		return
	end
	if e.dashT > 0 or e.ammo <= 0 or e.useT > 0 or e.atk == "throw" then
		return
	end
	local held = e.trigger and not e.running
	if e.press and row.ShootSpeed >= 5 and e.cdLeft > 0 then
		e.pressBuf = true
	end
	if e.cdLeft > 0 then
		return
	end
	local auto = Guns.auto(e.gun)
	if (auto and held) or (not auto and (e.press or (e.pressBuf and held))) then
		e.pressBuf = false
		shootOnce(e)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- melee

local function meleeHit(e: Enemy)
	local m = e.def.melee
	if not m then
		return
	end
	-- AI melee into half cover: x0.5
	Cover.melee(e.pos.X, e.pos.Y, e.facing, m.range + 0.05, m.damage * e.def.dmgMul * 0.5)
	for key, t in Weapons.targets do
		if key == e or (t.kind ~= "player" and t.kind ~= "enemy") or not isEnemyTeam(e.team, t.team) then
			continue
		end
		if typeof(key) == "Instance" and Weapons.isDodging and Weapons.isDodging(key) then
			continue
		end
		local tp = t.pos()
		if not tp then
			continue
		end
		local p = Vector2.new(tp.X, tp.Z)
		local d = (p - e.pos).Magnitude
		local reach = m.range + 0.05 + t.radius
		if d > reach then
			continue
		end
		local dir = math.atan2(p.X - e.pos.X, p.Y - e.pos.Y)
		if math.abs(angleDiff(dir, e.facing)) > math.rad(90) and d > 0.5 + t.radius then
			continue
		end
		local crit = rng:NextNumber() < m.critRate
		local dmg = m.damage * e.def.dmgMul * (if crit then m.critMul else 1)
		local killed = t.hurt(dmg, { fromRef = e, fromName = e.def.name, weaponId = if e.def.kind == "wolf" then "animal_weapon" else "butcher_knife", crit = crit, bleed = m.bleed })
		Weapons.broadcastHit(t, Vector3.new(p.X, 0.7, p.Y), dmg, crit, killed, nil, false)
	end
end

local function startSwing(e: Enemy)
	local m = e.def.melee
	if not m or clock - e.lastSwing < m.interval or e.dashT > 0 then
		return
	end
	e.lastSwing = clock
	e.swingT = 0
	e.model:SetAttribute("MeleeAt", Workspace:GetServerTimeNow())
	local slash = e.tracks.slash
	if slash then
		slash:Play(0.05)
	end
end

local function tickMelee(e: Enemy, dt: number)
	if e.swingT < 0 then
		return
	end
	local before = e.swingT
	e.swingT += dt
	if before <= DEALT and e.swingT > DEALT then
		meleeHit(e)
	end
	if e.swingT >= SWING then
		e.swingT = -1
	end
end

local function startDash(e: Enemy, dir: Vector2)
	if e.stamina < DASH.cost or clock - e.dashEnd < DASH.cooldown or e.dashT > 0 then
		return
	end
	e.stamina -= DASH.cost
	e.lastSpend = clock
	e.dashT = 1e-6
	e.dashDir = dir.Unit
	e.facing = math.atan2(e.dashDir.X, e.dashDir.Y)
	e.dashTaskT = clock
	e.dashNext = U(e.def.dash[1], e.def.dash[2])
	e.model:SetAttribute("DodgeAt", Workspace:GetServerTimeNow())
end

------------------------------------------------------------------------------------------------------------------------
-- carried items (Roster.rollBody), item use (Enemy.startUse / finishUse), danger (hear type 2 -> fleeDanger)

local SPAWN_COUNT = { bandage = 3 }
local function rollItems(kind: string): { { id: string, n: number } }
	local out = {}
	local body = Items.bodies[kind]
	if not body then
		return out
	end
	local function pickPool(pool: { any }): string?
		local total = 0
		for _, r in pool do
			total += r[2]
		end
		local roll = rng:NextNumber() * total
		for _, r in pool do
			roll -= r[2]
			if roll <= 0 then
				return r[1]
			end
		end
		return nil
	end
	local function add(id: string)
		if not Items.items[id] then
			return
		end
		local n = SPAWN_COUNT[id] or 1
		for _, st in out do
			if st.id == id then
				st.n += n
				return
			end
		end
		table.insert(out, { id = id, n = n })
	end
	for _, d in body.drops do
		if d.weapon then
			continue
		end
		local c = d.count or { 1, 1 }
		local count = c[1] + math.floor(rng:NextNumber() * (c[2] - c[1] + 1))
		if d.each then
			for _ = 1, count do
				if rng:NextNumber() < (d.chance or 1) then
					local id = pickPool(d.pool or {})
					if id then
						add(id)
					end
				end
			end
		elseif rng:NextNumber() < (d.chance or 1) then
			for _ = 1, count do
				local id = pickPool(d.pool or {})
				if id then
					add(id)
				end
			end
		end
	end
	return out
end

local function takeItem(e: Enemy, id: string)
	for i, st in e.items do
		if st.id == id then
			st.n -= 1
			if st.n <= 0 then
				table.remove(e.items, i)
			end
			return
		end
	end
end

local function healItem(e: Enemy): string?
	for _, st in e.items do
		local it = Items.items[st.id]
		if it and it.use and (it.use.heal or 0) > 0 then
			return st.id
		end
	end
	return nil
end

local function throwItem(e: Enemy): string?
	for _, st in e.items do
		if Grenades.row(st.id) and Items.items[st.id] and Items.items[st.id].kind == "throwable" then
			return st.id
		end
	end
	return nil
end

--- Enemy.startUse: the first carried heal; refused while reloading or dashing; `stand` stops moving (combat heal)
local function startUse(e: Enemy, stand: boolean): boolean
	local id = healItem(e)
	if not id or e.reloadT > 0 or e.dashT > 0 or e.useT > 0 then
		return false
	end
	e.useId = id
	e.useT = Items.items[id].use.useTime or 1
	e.useStand = stand
	e.model:SetAttribute("UseId", id)
	return true
end

local function tickUse(e: Enemy, dt: number)
	if e.useT <= 0 then
		return
	end
	if e.dashT > 0 then
		e.useT = 0
		e.useId = nil
		e.model:SetAttribute("UseId", nil)
		return
	end
	if e.useStand then
		stopMove(e)
	end
	e.useT -= dt
	if e.useT <= 0 then
		local id = e.useId :: string
		local heal = Items.items[id].use.heal or 0
		e.hp = math.min(e.maxHp, e.hp + heal)
		e.model:SetAttribute("HP", e.hp)
		takeItem(e, id)
		e.useId = nil
		e.model:SetAttribute("UseId", nil)
	end
end

--- calm heal (Patrol / Alert): every 1.5 s, unhurt (>= 2) for 5 s and at <= 80% hp -> use a heal while walking
local function calmHeal(e: Enemy, dt: number)
	e.healCheckT -= dt
	if e.healCheckT > 0 then
		return
	end
	e.healCheckT = 1.5
	if not hurtWithin(e, 2, 5) and e.hp <= 0.8 * e.maxHp then
		startUse(e, false)
	end
end

function Enemies.setDanger(n: any)
	for _, e in enemies do
		if not e.dead then
			e.danger = n
		end
	end
end

local function dangerNear(e: Enemy): Vector2?
	local n = e.danger
	if not n then
		return nil
	end
	if not Grenades.alive(n) then
		e.danger = nil
		return nil
	end
	local p = Vector2.new(n.pos.X, n.pos.Z)
	return if (p - e.pos).Magnitude <= 8 then p else nil
end

--- Enemy.fleeDanger: one move away from the grenade (8 s), "Danger!" at most every 5 s
local function fleeDanger(e: Enemy, dt: number, at: Vector2, radius: number, avoid: number, angle: number, face: boolean)
	if e.fleeT <= 0 then
		moveTo(e, randomPoint(e, at, radius, avoid, angle), TASK_OVER)
		e.fleeT = 8
		if clock - e.dangerSaid >= 5 then
			e.dangerSaid = clock
			say(e, "Danger!")
		end
	end
	e.fleeT -= dt
	if face then
		e.aimPos = at
	end
	if tickTask(e, dt) then
		e.fleeT = 0
	end
end

------------------------------------------------------------------------------------------------------------------------
-- FSM

local function enter(e: Enemy, state: string)
	e.fsm = state
	e.waitT = 0
	e.loopStep = 0
	stopMove(e)
	e.trigger = false
	e.atk = "gate" -- a burst cut short by losing the foe does not carry over (it would block the patrol reload)
	if state == "patrol" then
		e.runInput = false
		e.noticed = false
		e.alert = false
		e.aimTarget = nil
		e.aimPos = nil
		e.waitT = 0.2
		e.loopStep = -1
		reloadIfEmpty(e, false)
	elseif state == "alert" then
		say(e, "?")
		e.runInput = false
		e.waitT = 0.1
		e.loopStep = -1
		e.loopRoll = rng:NextNumber() <= e.traceChance
		e.alertForget = e.def.forget
	elseif state == "combat" then
		e.reactT = if e.def.melee then 0.2 else e.reaction
		e.atk = "gate"
		e.atkT = 0
		e.hasTarget = false
		e.hasObstacle = false
		e.lostT = 0
		e.hasTargetT = 0
		e.wantAttack = false
		e.wantT = U(e.def.shootGap[1], e.def.shootGap[2])
		e.atkSeq = -1
		e.model:SetAttribute("AlertAt", Workspace:GetServerTimeNow())
	end
	e.model:SetAttribute("AIState", if state == "alert" then "investigate" elseif state == "combat" then "combat" else "patrol")
end

local function tickPatrol(e: Enemy, dt: number)
	if e.def.patrolScare then
		-- Patrol_Scare (the giant): stands still, never searches; a character hit (>= 2 within 0.25 s) makes it the foe
		e.noticed = false
		e.alert = false
		stopMove(e)
		if hurtWithin(e, 2, 0.25) and e.lastAttacker ~= nil then
			e.foe = e.lastAttacker
		end
		return
	end
	calmHeal(e, dt)
	e.searchT -= dt
	if e.searchT <= 0 then
		search(e, 1, true)
	end
	if e.noticed then
		e.alert = true
	end
	local leader = e.leader
	if leader and leader ~= e and not leader.dead then
		-- grouped: keep up with the leader, else wander near it
		local far = (e.patrolPos - e.pos).Magnitude > 5
		local branch = if far then 10 else 20
		if (e :: any).branch ~= branch then
			(e :: any).branch = branch
			stopMove(e)
			e.loopStep = 0
			e.waitT = 0
		end
		if far then
			e.runInput = true
			if not e.task then
				traceTo(e, function()
					return if leader.dead then nil else leader.pos
				end, 3.5, TASK_OVER)
			else
				tickTask(e, dt)
			end
			return
		end
		e.runInput = false
		if e.waitT > 0 then
			e.waitT -= dt
			return
		end
		if e.loopStep == 0 then
			moveTo(e, randomPoint(e, e.patrolPos, 3, 2, 150), TASK_OVER)
			e.loopStep = 1
		elseif tickTask(e, dt) then
			e.waitT = U(1.5, 6)
			e.loopStep = 0
		end
		return
	end
	if e.waitT > 0 then
		e.waitT -= dt
		return
	end
	if e.loopStep == -1 then
		e.waitT = 1
		e.loopStep = -2
		return
	elseif e.loopStep == -2 then
		e.loopStep = 0
	end
	if e.loopStep == 0 then
		moveTo(e, randomPoint(e, e.patrolPos, e.def.patrolRange, 2, 360), TASK_OVER)
		e.loopStep = 1
	elseif tickTask(e, dt) then
		e.waitT = U(1.5, 6)
		e.loopStep = 0
	end
end

local function tickAlert(e: Enemy, dt: number)
	e.searchT -= dt
	if e.searchT <= 0 then
		search(e, SIGHT_ALERT, false)
	end
	calmHeal(e, dt)
	if e.loopStep == -1 and e.waitT > 0 then
		e.waitT -= dt
		return
	end
	local dz = dangerNear(e)
	if dz then
		fleeDanger(e, dt, dz, 16, 10, 90, true)
		return
	end
	local fresh = hurtWithin(e, 2, 0.1) or (e.noticed and clock - e.noticeT < NOTICE_FRESH)
	if fresh then
		e.noticed = false
		e.runInput = false
		e.aimTarget = nil
		e.aimPos = e.noticeFrom
		stopMove(e)
		e.waitT = 0.1
		e.loopStep = 0
		e.loopRoll = rng:NextNumber() <= e.traceChance
		e.alertForget = e.def.forget
		return
	end
	e.alertForget -= dt
	if e.alertForget <= 0 then
		e.alert = false
	end
	if e.waitT > 0 then
		e.waitT -= dt
		return
	end
	if not e.loopRoll then
		e.aimPos = e.noticeFrom
		return
	end
	if e.loopStep <= 0 then
		moveTo(e, randomPoint(e, e.noticeFrom, 3, 0.2, 360), TASK_OVER)
		e.loopStep = 1
	elseif tickTask(e, dt) then
		e.waitT = 3
		e.loopStep = 0
	end
end

local function lostLogic(e: Enemy, fp: Vector2, dt: number, melee: boolean)
	local dist = (fp - e.pos).Magnitude
	if melee then
		if e.hasObstacle or dist > MELEE_LOST_RANGE then
			e.lostT += dt
			if e.lostT >= MELEE_LOST_T then
				e.foe = nil
			end
		else
			e.lostT = 0
		end
		return
	end
	if not e.hasObstacle and dist <= TRACK_RANGE then
		e.lostT = 0
		e.noticeFrom = fp
		e.hasTarget = true
		e.hasTargetT = 0
	else
		local before = e.lostT
		e.lostT += dt
		if before < LOST_SNAP and e.lostT >= LOST_SNAP then
			e.noticeFrom = fp
		end
		if e.lostT >= LOST_SNAP + e.def.forget then
			e.foe = nil
		end
	end
end

local function combatMove(e: Enemy, dt: number)
	local dz = dangerNear(e)
	if dz then
		fleeDanger(e, dt, dz, 15, 9, 10, false)
		return
	end
	-- hurt dodge (dash-capable kinds)
	if e.def.dash and hurtWithin(e, 3, 0.2) and e.reloadT <= 0 and clock - e.dashTaskT >= e.dashNext then
		stopMove(e)
		local a = rng:NextNumber() * math.pi * 2
		startDash(e, Vector2.new(math.sin(a), math.cos(a)))
		e.waitT = 0.2
		return
	end
	e.aimTarget = "foe"
	e.runInput = false
	if e.atk == "shoot" and not e.def.shootCanMove then
		stopMove(e)
		return
	end
	if e.waitT > 0 then
		e.waitT -= dt
		return
	end
	if e.hasObstacle and e.hasTarget then
		e.hasTargetT += dt
		if e.hasTargetT >= e.def.forget then
			e.hasTarget = false
		end
		if e.loopStep == 0 or e.loopStep == 9 then
			stopMove(e)
			e.loopRoll = rng:NextNumber() <= e.traceChance
			if e.loopRoll then
				e.waitT = 0.2
				e.loopStep = 1
			else
				moveTo(e, randomPoint(e, e.noticeFrom, e.def.combatMoveRange, 2, 360), TASK_OVER)
				e.loopStep = 2
			end
			return
		elseif e.loopStep == 1 then
			local target = e.noticeFrom
			traceTo(e, function()
				return target
			end, 1, TASK_OVER)
			e.loopStep = 3
			return
		end
		if tickTask(e, dt) then
			e.waitT = if e.loopStep == 3 then 0.5 else U(e.def.combatMoveTime[1], e.def.combatMoveTime[2])
			e.loopStep = 0
		end
		return
	end
	if e.loopStep ~= 9 then
		moveTo(e, randomPoint(e, e.noticeFrom, e.def.combatMoveRange, 2, 360), TASK_OVER)
		e.loopStep = 9
		return
	end
	if tickTask(e, dt) then
		e.waitT = U(e.def.combatMoveTime[1], e.def.combatMoveTime[2])
		e.loopStep = 0
	end
end

local function attackLoop(e: Enemy, dt: number, fp: Vector2)
	e.atkT += dt
	local dist = (fp - e.pos).Magnitude
	if e.atk == "gate" then
		local go = not e.hasObstacle or hurtWithin(e, 3, 8)
		if not go then
			-- combat heal: behind an obstacle, every 1.5 s at <= 30% hp with a drug
			e.healCheckT -= dt
			if e.healCheckT <= 0 then
				e.healCheckT = 1.5
				if e.useT <= 0 and e.hp <= 0.3 * e.maxHp and healItem(e) and not hurtWithin(e, 3, 8) then
					e.atk = "healWait"
					e.atkT = 0
				end
			end
		elseif dist <= aimRange(e) * 1.5 then
			-- the grenade check (6 s itemCooldown, 30%): a clear line, a carried throwable, nothing else running
			local threw = false
			if not e.hasObstacle and clock - e.skillCheckT >= 6 then
				e.skillCheckT = clock
				local tid = throwItem(e)
				if tid and rng:NextNumber() <= 0.3 and e.reloadT <= 0 and e.useT <= 0 and e.swingT < 0 and e.dashT <= 0 then
					e.throwId = tid
					e.throwAt = fp
					e.throwT = (Grenades.row(tid).readyTime or 0.25) + 0.1
					e.atk = "throw"
					e.atkT = 0
					threw = true
				end
			end
			if not threw then
				e.atk = "range"
				e.atkT = 0
			end
		end
	elseif e.atk == "healWait" then
		if e.atkT >= 0.5 then
			startUse(e, true)
			e.atk = "heal"
			e.atkT = 0
		end
	elseif e.atk == "heal" then
		if e.useT <= 0 then
			e.atk = "gate"
			e.atkT = 0
		end
	elseif e.atk == "throw" then
		e.aimPos = e.throwAt
		e.aimTarget = nil
		e.throwT -= dt
		if e.throwT <= 0 then
			local tid = e.throwId :: string
			local at = e.throwAt :: Vector2
			takeItem(e, tid)
			Grenades.launch(tid, e.pos.X, e.pos.Y, e.facing, at.X, at.Y, { team = e.team, fromRef = e, free = true })
			e.atk = "gap"
			e.atkT = 0
			e.gapT = U(e.def.shootGap[1], e.def.shootGap[2])
		end
	elseif e.atk == "range" then
		e.aimTarget = "foe"
		if dist <= aimRange(e) then
			e.atk = "delay"
			e.atkT = 0
		end
	elseif e.atk == "delay" then
		e.aiming = true
		if e.atkT >= e.def.shootDelay then
			e.atk = "reloadWait"
			e.atkT = 0
		end
	elseif e.atk == "reloadWait" then
		e.aiming = true
		if e.reloadT <= 0 then
			if e.ammo <= 0 then
				reloadIfEmpty(e, true)
			else
				e.atk = "shoot"
				e.atkT = 0
				e.shootT = U(e.def.shootTime[1], e.def.shootTime[2])
				e.semiT = SEMI_PRESS
			end
		end
	elseif e.atk == "shoot" then
		e.aiming = true
		e.trigger = true
		e.semiT += dt
		if e.semiT >= SEMI_PRESS then
			e.semiT = 0
			e.press = true
		end
		if e.atkT >= e.shootT then
			e.trigger = false
			e.atk = "gap"
			e.atkT = 0
			e.gapT = U(e.def.shootGap[1], e.def.shootGap[2])
			reloadIfEmpty(e, true)
		end
	elseif e.atk == "gap" then
		if e.atkT >= e.gapT then
			e.atk = "gate"
			e.atkT = 0
		end
	end
end

local function tickGunCombat(e: Enemy, dt: number)
	if e.reactT > 0 then
		e.reactT -= dt
		stopMove(e)
		return
	end
	local fp = posOf(e.foe)
	if not fp then
		e.foe = nil
		return
	end
	e.hasObstacle = lineBlocked(e)
	if e.hasObstacle then
		e.searchT -= dt
		if e.searchT <= 0 then
			search(e, SIGHT_COMBAT, false)
		end
	end
	lostLogic(e, fp, dt, false)
	if not e.foe then
		return
	end
	combatMove(e, dt)
	attackLoop(e, dt, fp)
end

local function tickMeleeCombat(e: Enemy, dt: number)
	if e.reactT > 0 then
		e.reactT -= dt
		stopMove(e)
		return
	end
	local fp = posOf(e.foe)
	if not fp then
		e.foe = nil
		return
	end
	e.hasObstacle = lineBlocked(e)
	if e.hasObstacle then
		e.searchT -= dt
		if e.searchT <= 0 then
			search(e, 1, false)
		end
	end
	lostLogic(e, fp, dt, true)
	if not e.foe then
		return
	end
	local foe = e.foe
	if not e.wantAttack then
		e.runInput = false
		if e.def.dash and hurtWithin(e, 3, 0.2) and clock - e.dashTaskT >= e.dashNext then
			local d = (fp - e.pos)
			local side = if rng:NextNumber() < 0.5 then 1 else -1
			startDash(e, Vector2.new(-d.Y, d.X) * side)
		end
		e.wantT -= dt
		if e.wantT <= 0 then
			e.wantAttack = true
			e.atkSeq = 0
			stopMove(e)
			return
		end
		if e.waitT > 0 then
			e.waitT -= dt
			return
		end
		if not e.task then
			moveTo(e, randomPoint(e, fp, e.def.combatMoveRange, 0, 360), TASK_OVER)
		elseif tickTask(e, dt) then
			e.waitT = U(e.def.combatMoveTime[1], e.def.combatMoveTime[2])
		end
		return
	end
	e.atkT += dt
	if e.atkSeq == 0 then
		e.runInput = true
		traceTo(e, function()
			return posOf(foe)
		end, 1.5, TASK_OVER)
		e.atkSeq = 1
	elseif e.atkSeq == 1 then
		if tickTask(e, dt) then
			if e.taskTimedOut then
				e.atkSeq = 0
			else
				e.runInput = false
				e.aimTarget = "foe"
				e.atkSeq = 2
				e.atkT = 0
			end
		end
	elseif e.atkSeq == 2 then
		e.aimTarget = "foe"
		if e.atkT >= 0.1 then
			e.model:SetAttribute("AlertAt", Workspace:GetServerTimeNow())
			e.atkSeq = 3
			e.atkT = 0
		end
	elseif e.atkSeq == 3 then
		e.aimTarget = "foe"
		if e.atkT >= 0.2 then
			startSwing(e)
			e.atkSeq = 4
			e.atkT = 0
		end
	elseif e.atkSeq == 4 then
		if e.atkT >= SWING then
			e.wantAttack = false
			e.wantT = U(e.def.shootGap[1], e.def.shootGap[2])
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- movement (Enemy.integrate)

local function aimPoint(e: Enemy): Vector2?
	if e.aimTarget == "foe" then
		local p = posOf(e.foe)
		if p then
			return p
		end
	end
	if e.task and e.task.aimAt then
		return e.task.aimAt
	end
	return e.aimPos
end

local function integrate(e: Enemy, dt: number)
	-- path requests for a pending task
	local k = e.task
	if k and k.pending then
		k.pending = false
		e.path = nil
		e.wp = 1
		e.pathReq += 1
		table.insert(pathQ, { e = e, task = k, req = e.pathReq, a = e.pos, b = k.target })
	end
	local input = Vector2.zero
	if k then
		if e.path == nil then
			input = e.moveIn
		else
			local path = e.path :: { Vector2 }
			local i = e.wp
			local d = (path[i] - e.pos).Magnitude
			local isEnd = false
			while d < SLOW_IN do
				if i < #path then
					i += 1
					d = (path[i] - e.pos).Magnitude
				else
					isEnd = true
					break
				end
			end
			e.wp = i
			if isEnd and d < STOP_DIST then
				e.path = nil
				k.done = true
				input = Vector2.zero
			else
				local dir = if d > 1e-6 then (path[i] - e.pos) / d else Vector2.zero
				input = dir * (if isEnd then math.sqrt(d / SLOW_IN) else 1)
			end
			e.moveIn = input
		end
	end
	local moving = input.Magnitude > 0.02
	e.running = moving and e.runInput and (e.stamina / STAMINA_MAX >= 0.2 or (e.wasRunning and e.stamina > 0))
	e.wasRunning = e.running
	local held = if e.row and (e.row.MoveSpeedMultiplier or 0) > 0 then e.row.MoveSpeedMultiplier else 1
	local mob = if e.stunUntil and clock < e.stunUntil then 0.15 else 1
	local speed = (if e.running then e.def.run else e.def.walk) * held * mob
	local vel = e.vel
	if e.dashT > 0 then
		e.dashT += dt
		if e.dashT > DASH.time then
			e.dashT = 0
			e.dashEnd = clock
		else
			vel = e.dashDir * DASH.speed * Curve.sample(DASH.keys, math.clamp(e.dashT / DASH.time, 0, 1))
		end
	end
	if e.dashT <= 0 then
		local want = input * speed
		local acc = (if e.running then RUN_ACC else WALK_ACC) * dt
		local dv = want - vel
		local l = dv.Magnitude
		vel = if l <= acc then want else vel + dv / l * acc
	end
	e.vel = vel
	-- stamina
	if e.running then
		e.stamina = math.max(0, e.stamina - STAMINA_DRAIN * dt)
		e.lastSpend = clock
	elseif clock - e.lastSpend >= STAMINA_DELAY then
		e.stamina = math.min(STAMINA_MAX, e.stamina + STAMINA_RECOVER * dt)
	end
	-- facing: the aim point when not running, else the velocity
	local ap = aimPoint(e)
	local want: number? = nil
	if not e.running and ap and (ap - e.pos).Magnitude > 0.6 then
		want = math.atan2(ap.X - e.pos.X, ap.Y - e.pos.Y)
	elseif vel.Magnitude > 0.02 then
		want = math.atan2(vel.X, vel.Y)
	end
	if want and e.dashT <= 0 then
		local d = angleDiff(want, e.facing)
		local step = math.rad(e.turnStat) * mob * dt
		e.facing += math.clamp(d, -step, step)
	end
	-- drive the body
	local sp = vel.Magnitude
	if e.hum then
		e.hum.WalkSpeed = sp * S
		e.hum:Move(if sp > 1e-3 then Vector3.new(vel.X / sp, 0, vel.Y / sp) else Vector3.zero, false)
	else
		local cur = e.root.AssemblyLinearVelocity
		e.root.AssemblyLinearVelocity = Vector3.new(vel.X * S, math.min(cur.Y, 0), vel.Y * S)
	end
	if e.align then
		e.align.CFrame = CFrame.Angles(0, e.facing + math.pi, 0)
	end
	-- footsteps heard by other teams' AI
	if sp > 0.5 then
		e.stepT -= dt
		if e.stepT <= 0 then
			e.stepT = 1 / (if e.running then STEP_RUN else STEP_WALK)
			Enemies.hear(e.pos.X, e.pos.Y, if e.running then RUN_SOUND else WALK_SOUND, 0, e.team)
		end
	end
end

------------------------------------------------------------------------------------------------------------------------
-- body animation (server-played default R15 clips; they replicate)

local ANIM = {
	idle = "rbxassetid://507766388",
	walk = "rbxassetid://507777826",
	run = "rbxassetid://507767714",
	hold = "rbxassetid://507768375",
	slash = "rbxassetid://522635514",
}

local function loadTracks(e: Enemy)
	local hum = e.hum
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for name, id in ANIM do
		local a = Instance.new("Animation")
		a.AnimationId = id
		local ok, tr = pcall(function()
			return animator:LoadAnimation(a)
		end)
		if ok and tr then
			tr.Priority = if name == "hold" or name == "slash" then Enum.AnimationPriority.Action else Enum.AnimationPriority.Core
			tr.Looped = name ~= "slash"
			e.tracks[name] = tr
		end
	end
	if e.tracks.idle then
		e.tracks.idle:Play()
	end
	if e.tracks.hold and not e.def.melee then
		e.tracks.hold:Play()
	end
	e.anim = "idle"
end

local function animate(e: Enemy)
	if not e.hum then
		return
	end
	local sp = e.vel.Magnitude * S
	local scale = e.model:GetScale()
	local want = if sp < 0.5 then "idle" elseif sp < 13 * scale then "walk" else "run"
	if want ~= e.anim then
		local old = e.tracks[e.anim]
		if old then
			old:Stop(0.2)
		end
		local t = e.tracks[want]
		if t then
			t:Play(0.2)
		end
		e.anim = want
	end
	local t = e.tracks[e.anim]
	if t and e.anim ~= "idle" then
		t:AdjustSpeed(sp / (if e.anim == "walk" then 14.5 else 22) / scale)
	end
end

------------------------------------------------------------------------------------------------------------------------
-- spawning

local function pickGun(def: any): string
	local total = 0
	for _, w in def.weapons do
		total += w[2]
	end
	local roll = rng:NextNumber() * total
	for _, w in def.weapons do
		roll -= w[2]
		if roll <= 0 then
			return w[1]
		end
	end
	return "tt33"
end

local assets = ReplicatedStorage:FindFirstChild("CreatorAssets")

local function buildBody(def: any): (Model, BasePart, Humanoid?)
	local tpl = assets and assets:FindFirstChild(def.rig)
	if tpl and tpl:FindFirstChildOfClass("Humanoid") then
		local m = (tpl :: Model):Clone()
		if def.tint then
			-- the stormling: the store body recoloured to the storm purple (no clothing), the hat in the light violet
			for _, d in m:GetDescendants() do
				if d:IsA("Shirt") or d:IsA("Pants") or d:IsA("ShirtGraphic") then
					d:Destroy()
				elseif d:IsA("BasePart") then
					d.Color = if d.Parent and d.Parent:IsA("Accessory") then Color3.fromHex("#8a6aff") else def.tint
					if d:IsA("MeshPart") then
						d.TextureID = ""
					end
				elseif d:IsA("SpecialMesh") then
					d.TextureId = ""
				elseif d:IsA("SurfaceAppearance") then
					d:Destroy()
				end
			end
		end
		Avatar.prepare(m, Avatar.HEIGHT * (def.scale or 1))
		return m, m:FindFirstChild("HumanoidRootPart") :: BasePart, m:FindFirstChildOfClass("Humanoid")
	end
	-- a creature (the wolf) or a missing import: a ball root carrying the mesh
	local m = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Shape = Enum.PartType.Ball
	root.Size = Vector3.one * (0.3 * S * 2)
	root.Transparency = 1
	root.CollisionGroup = "Chars"
	root.CanTouch = false
	root.CanQuery = false
	root.CustomPhysicalProperties = PhysicalProperties.new(1, 0, 0, 100, 100)
	root.Parent = m
	m.PrimaryPart = root
	local att = Instance.new("Attachment")
	att.Name = "RootAttachment"
	att.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "Facing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = true
	align.Parent = root
	if tpl then
		local body = (tpl :: Model):Clone()
		local size0 = body:GetAttribute("Size0") :: Vector3
		-- the wolf: 1.15 m nose to tail along its long axis
		local long = math.max(size0.X, size0.Z)
		body:ScaleTo((def.bodyLen or 1.15) * S / long)
		local mesh = body:FindFirstChildWhichIsA("BasePart", true) :: BasePart
		body:PivotTo(root.CFrame * CFrame.new(0, -0.3 * S, 0) * (if size0.X > size0.Z then CFrame.Angles(0, math.pi / 2, 0) else CFrame.identity))
		for _, p in body:GetDescendants() do
			if p:IsA("BasePart") then
				p.Anchored = false
				p.Massless = true
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				if p ~= mesh then
					local w = Instance.new("WeldConstraint")
					w.Part0 = mesh
					w.Part1 = p
					w.Parent = p
				end
			end
		end
		local motor = Instance.new("Motor6D")
		motor.Name = "Body"
		motor.Part0 = root
		motor.Part1 = mesh
		motor.C0 = root.CFrame:ToObjectSpace(mesh.CFrame)
		motor.Parent = root
		body.Parent = m
		m:SetAttribute("Creature", true)
	end
	return m, root, nil
end

local function spawnEnemy(kind: string, x: number, z: number, group: { Enemy }?): Enemy
	local def = Config.Enemies[kind] or Config.Enemies.scrapper
	nextId += 1
	local model, root, hum = buildBody(def)
	model.Name = def.name
	model:SetAttribute("Enemy", true)
	model:SetAttribute("HP", def.hp)
	model:SetAttribute("MaxHP", def.hp)
	model:SetAttribute("Held", if def.melee then (if kind == "wolf" then "none" else "melee") else "gun")
	model:SetAttribute("Kind", def.kind)
	local facing = rng:NextNumber() * math.pi * 2
	if hum then
		Avatar.place(model, x, z, facing)
	else
		model:PivotTo(CFrame.new(x * S, 0.3 * S + 0.2, z * S) * CFrame.Angles(0, facing + math.pi, 0))
	end
	model.Parent = folder
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	local gun = if def.melee then "" else pickGun(def)
	local e: Enemy = {
		id = nextId,
		def = def,
		model = model,
		root = root,
		hum = hum,
		align = root:FindFirstChild("Facing") :: AlignOrientation?,
		team = def.team,
		hp = def.hp,
		maxHp = def.hp,
		dead = false,
		pos = Vector2.new(x, z),
		vel = Vector2.zero,
		facing = facing,
		spawn = Vector2.new(x, z),
		patrolPos = Vector2.new(x, z),
		group = group,
		leader = nil,
		active = false,
		fsm = "init",
		fsmT = 0,
		turnT = 0,
		turnStat = def.turnPatrol,
		reaction = def.reaction,
		traceChance = U((def.traceChance or { 0.3, 0.7 })[1], (def.traceChance or { 0.3, 0.7 })[2]),
		foe = nil,
		alert = false,
		noticed = false,
		noticeT = -math.huge,
		noticeFrom = Vector2.new(x, z),
		lastHurt = -math.huge,
		lastHurtDmg = 0,
		lastHurtByChar = false,
		searchT = 0,
		searchPending = false,
		checkPending = false,
		checkBlocked = false,
		waitT = 0,
		loopStep = 0,
		loopRoll = false,
		alertForget = 0,
		reactT = 0,
		atk = "gate",
		atkT = 0,
		shootT = 0,
		semiT = 0,
		gapT = 0,
		wantAttack = false,
		wantT = 0,
		atkSeq = -1,
		lostT = 0,
		hasTarget = false,
		hasTargetT = 0,
		hasObstacle = false,
		runInput = false,
		running = false,
		wasRunning = false,
		aimTarget = nil,
		aimPos = nil,
		task = nil,
		taskTimedOut = false,
		path = nil,
		wp = 1,
		pathReq = 0,
		navY = nil,
		moveIn = Vector2.zero,
		stamina = STAMINA_MAX,
		lastSpend = -math.huge,
		dashT = 0,
		dashDir = Vector2.new(0, 1),
		dashTaskT = -math.huge,
		dashNext = 0,
		dashEnd = -math.huge,
		gun = gun,
		row = if gun ~= "" then Guns.row(gun) else nil,
		ammo = 0, -- guns spawn empty; the init / patrol entry reload fills them
		reloadT = 0,
		reloads = 0,
		cdLeft = 0,
		burstLeft = 0,
		gunScatter = 0,
		trigger = false,
		press = false,
		pressBuf = false,
		aiming = false,
		swingT = -1,
		lastSwing = -math.huge,
		stepT = 0,
		tracks = {},
		anim = "",
		lastAttacker = nil,
		items = rollItems(def.kind),
		useT = 0,
		useId = nil,
		useStand = false,
		healCheckT = 1.5,
		skillCheckT = -99,
		throwT = 0,
		throwId = nil,
		throwAt = nil,
		danger = nil,
		fleeT = 0,
		dangerSaid = -math.huge,
	}
	if e.row then
		e.gunScatter = (Guns.scatterNow(e.row, 0))
	end
	-- the preset's armor / helmet quality roll picks the worn item (it drops with the body)
	local function rollLevel(roll: { any }?): number
		if not roll or rng:NextNumber() >= roll[1] then
			return 0
		end
		local total = 0
		for _, w in roll[2] do
			total += w
		end
		local pick = rng:NextNumber() * total
		for i, w in roll[2] do
			pick -= w
			if pick <= 0 then
				return i
			end
		end
		return #roll[2]
	end
	if def.fixedArmor then
		e.armor = { id = "", value = def.fixedArmor, dur = 9999 }
	end
	if def.fixedHelmet then
		e.helmet = { id = "", value = def.fixedHelmet, dur = 9999 }
	end
	local al, hl = rollLevel(def.armorRoll), rollLevel(def.helmetRoll)
	if al > 0 then
		local id = "armor_l" .. al
		local g = Guns.items[id] and Guns.items[id].gear
		e.armor = { id = id, value = g and g.armor or al, dur = g and g.dur or 50 }
	end
	if hl > 0 then
		local id = if hl <= 3 then "helmet_l" .. hl else "helmat_lv4"
		local g = Guns.items[id] and Guns.items[id].gear
		e.helmet = { id = id, value = g and g.headArmor or hl, dur = g and g.dur or 40 }
	end
	enemies[e.id] = e
	if group then
		table.insert(group, e)
	end
	if gun ~= "" then
		model:SetAttribute("Gun", gun)
	end
	model:SetAttribute("AIState", "patrol")
	Weapons.targets[e] = {
		kind = "enemy",
		team = def.team,
		pos = function()
			if e.dead or not e.root.Parent then
				return nil
			end
			return Vector3.new(e.pos.X, 0, e.pos.Y)
		end,
		radius = def.hitRadius,
		height = Config.Body.hitHeight,
		hurt = function(dmg, info)
			return hurt(e, dmg, info)
		end,
		ref = e,
		model = model,
		stun = function(secs)
			e.stunUntil = clock + secs
		end,
	}
	task.defer(loadTracks, e)
	return e
end
Enemies.spawn = spawnEnemy

------------------------------------------------------------------------------------------------------------------------
-- per-frame driver (World.update AI section)

local function updateGroups()
	local seenGroups: { [any]: boolean } = {}
	for _, e in enemies do
		local g = e.group
		if g and not seenGroups[g] then
			seenGroups[g] = true
			local leader = g[1]
			for _, m in g do
				m.leader = leader
			end
			if leader then
				for _, m in g do
					if m ~= leader then
						if leader.foe ~= nil and m.foe == nil then
							m.foe = leader.foe
						elseif m.foe ~= nil and leader.foe == nil then
							leader.foe = m.foe
						end
					end
				end
			end
		end
	end
end

local function nearestPlayer(p: Vector2): number
	local best = math.huge
	for pl, _ in pState do
		local r = Raid.raids[pl]
		local pp = r and r.alive and Raid.posOf(pl)
		if pp then
			best = math.min(best, (Vector2.new(pp.X, pp.Z) - p).Magnitude)
		end
	end
	return best
end

local function update(e: Enemy, dt: number)
	-- foe gone / dead
	if e.foe ~= nil and not posOf(e.foe) then
		e.foe = nil
	end
	e.turnT -= dt
	if e.turnT <= 0 then
		e.turnT = 1
		e.turnStat = if e.foe ~= nil then e.def.turnCombat else e.def.turnPatrol
		e.reaction = e.def.reaction * (if Raid.isNight() then (e.def.nightReact or 1.5) else 1)
	end
	-- patrol anchor: the leader (members), self (leader), else the spawn
	if e.foe == nil and e.leader and not e.leader.dead then
		e.patrolPos = if e.leader == e then e.pos else e.leader.pos
	end
	-- FSM transitions
	if e.fsm == "init" then
		if e.fsmT == 0 then
			reloadIfEmpty(e, false)
		end
		e.fsmT += dt
		if e.fsmT >= 0.2 then
			enter(e, "patrol")
		end
	elseif e.fsm == "patrol" then
		if e.alert then
			enter(e, "alert")
		elseif e.foe ~= nil then
			enter(e, "combat")
		end
	elseif e.fsm == "alert" then
		if e.foe ~= nil then
			enter(e, "combat")
		elseif not e.alert then
			enter(e, "patrol")
		end
	elseif e.fsm == "combat" then
		if e.foe == nil then
			enter(e, "patrol")
		end
	end
	e.aiming = false
	e.trigger = false
	e.press = false
	if e.fsm == "patrol" then
		tickPatrol(e, dt)
	elseif e.fsm == "alert" then
		tickAlert(e, dt)
	elseif e.fsm == "combat" then
		if e.def.melee then
			tickMeleeCombat(e, dt)
		else
			tickGunCombat(e, dt)
		end
	end
	tickUse(e, dt)
	fireGun(e, dt)
	tickMelee(e, dt)
	integrate(e, dt)
	animate(e)
	if Enemies.openDoor then
		Enemies.openDoor(e.pos, 0.3)
	end
end

local function playerSteps(dt: number)
	-- the players' footsteps (World.ts: 16 m sprinting / 8 walking, x1.5 at >= 75% load, silent while aiming)
	for pl, st in pState do
		local r = Raid.raids[pl]
		local root = r and r.alive and Raid.rootOf(pl)
		if not root then
			continue
		end
		local v = root.AssemblyLinearVelocity
		local sp = Vector2.new(v.X, v.Z).Magnitude / S
		if sp < 0.5 then
			st.stepT = 0
			continue
		end
		st.stepT -= dt
		if st.stepT <= 0 then
			st.stepT = 1 / (if st.sprint then STEP_RUN else STEP_WALK)
			if not st.ads then
				local radius = if st.sprint then RUN_SOUND else WALK_SOUND
				local load = pl:GetAttribute("Load")
				if typeof(load) == "number" and load >= 0.75 then
					radius *= 1.5
				end
				local p = root.Position / S
				Enemies.hear(p.X, p.Z, radius, 0, 0)
			end
		end
	end
end

local stepMs, stepMax, queueMax = 0, 0, 0
local function step(dt: number)
	local t0 = os.clock()
	clock += dt
	updateGroups()
	-- last frame's finished paths
	for _, d in pathDone do
		if d.e.task == d.task and d.e.pathReq == d.req then
			d.e.path = d.path
			d.e.wp = 1
		end
	end
	table.clear(pathDone)
	for _, e in enemies do
		if e.dead or not e.root.Parent then
			continue
		end
		local rp = e.root.Position
		e.pos = Vector2.new(rp.X / S, rp.Z / S)
		local active = nearestPlayer(e.pos) < ACTIVE
		if active and not e.active then
			e.fsm = "init"
			e.fsmT = 0
			stopMove(e)
			e.trigger = false
		end
		e.active = active
		if active then
			update(e, dt)
		else
			e.vel = Vector2.zero
			if e.hum then
				e.hum:Move(Vector3.zero)
			else
				e.root.AssemblyLinearVelocity = Vector3.zero
			end
			animate(e)
		end
	end
	playerSteps(dt)
	runBrain()
	runPaths()
	local ms = (os.clock() - t0) * 1000
	stepMs = stepMs * 0.95 + ms * 0.05
	stepMax = math.max(stepMax * 0.995, ms)
	queueMax = math.max(queueMax, #pathQ)
end

------------------------------------------------------------------------------------------------------------------------
-- spawners: count [min, max] at random points, the kind mix, the spawn delay, minDist from every player; boss groups
-- pick one option. Each spawner batch is one AI group (the first spawned leads).

local PORTED = { scrapper = true, scav = true, brute = true, scrapper_rifle = true, contractor = true, boss = true, wolf = true,
	giant = true, operator = true, bloater = true, stormling = true, drone = true }
local spawnedCount = 0
local deferred: { [string]: { any } } = {}

--- World.runSpawners for one root: roll prob, then count, then distinct random points between minDist and maxDist of
--- every player, 0.1 s apart; the batch is one AI group (the first spawned leads)
local function runSpawner(sp: any, delay: number)
	local kind = sp.type or "scrapper"
	if (sp.prob or 1) < math.random() then
		return
	end
	local lo, hi = sp.count and sp.count[1] or 1, sp.count and sp.count[2] or 1
	local count = math.random(lo, hi)
	task.delay(delay, function()
		local pts = table.clone(sp.points or {})
		local group: { Enemy }? = if count > 1 then {} else nil
		local placed = 0
		while placed < count and #pts > 0 do
			local pt = table.remove(pts, math.random(1, #pts))
			local d = nearestPlayer(Vector2.new(pt.x, pt.z))
			if d < (sp.minDist or 0) or d > (sp.maxDist or 9999) then
				continue
			end
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
				local e = spawnEnemy("scrapper", pt.x, pt.z, group)
				e.gun = "ak74u"
				e.row = Guns.row("ak74u")
				e.gunScatter = (Guns.scatterNow(e.row, 0))
				e.model:SetAttribute("Gun", "ak74u")
			elseif PORTED[k] then
				spawnEnemy(k, pt.x, pt.z, group)
			end
			placed += 1
			spawnedCount += 1
			task.wait(sp.interval or 0.1)
		end
	end)
end

--- night / rain / storm roots run once, the first frame their condition holds (World.ts conditionSpawned)
function Enemies.onCondition(name: string)
	local list = deferred[name]
	if not list then
		return
	end
	deferred[name] = nil
	for _, sp in list do
		runSpawner(sp, if name == "night" then 0 else (sp.delay or 0))
	end
	print(string.format("[Blockov] %s spawners: %d roots", name, #list))
end

local function rollSpawners()
	local skipped = {}
	-- selector groups: pick [min, max] distinct options of the group
	local options: { [string]: { number } } = {}
	local pickOf: { [string]: { number } } = {}
	for _, sp in MapData.spawners or {} do
		if sp.group then
			options[sp.group] = options[sp.group] or {}
			if not table.find(options[sp.group], sp.option or 0) then
				table.insert(options[sp.group], sp.option or 0)
			end
			pickOf[sp.group] = sp.pick or { 1, 1 }
		end
	end
	local chosen: { [string]: { [number]: boolean } } = {}
	for g, opts in options do
		local pk = pickOf[g]
		local n = math.random(pk[1], pk[2])
		local pool = table.clone(opts)
		chosen[g] = {}
		for _ = 1, math.min(n, #pool) do
			chosen[g][table.remove(pool, math.random(1, #pool))] = true
		end
	end
	for _, sp in MapData.spawners or {} do
		if sp.group and not chosen[sp.group][sp.option or 0] then
			continue
		end
		local kind = sp.type or "scrapper"
		if not PORTED[kind] then
			skipped[kind] = (skipped[kind] or 0) + 1
			continue
		end
		if sp.when then
			deferred[sp.when] = deferred[sp.when] or {}
			table.insert(deferred[sp.when], sp)
			continue
		end
		runSpawner(sp, sp.delay or 0)
	end
	task.delay(4, function()
		print(string.format("[Blockov] spawned %d enemies at start (navmesh %d tris, %d ms); unported spawners: %s", spawnedCount, Nav.triangles, math.floor(Nav.buildMs), game:GetService("HttpService"):JSONEncode(skipped)))
	end)
end

function Enemies.start()
	Weapons.onNoise = function(at, range, src)
		-- player gunfire (team 0), heard by every AI team
		Enemies.hear(at.X, at.Z, range, 1, 0)
	end
	local function st(p: Player)
		local s = pState[p]
		if not s then
			s = { sprint = false, ads = false, stepT = 0 }
			pState[p] = s
		end
		return s
	end
	Players.PlayerAdded:Connect(st)
	for _, p in Players:GetPlayers() do
		st(p)
	end
	Players.PlayerRemoving:Connect(function(p)
		pState[p] = nil
	end)
	Net.event("Sprint").OnServerEvent:Connect(function(p, on)
		st(p).sprint = on == true
	end)
	Net.event("Aim").OnServerEvent:Connect(function(p, on)
		st(p).ads = on == true
	end)
	task.delay(1, rollSpawners)
	RunService.Heartbeat:Connect(step)
	if RunService:IsStudio() then
		-- Studio-only test fixtures: player attribute DevSpawn = "kind,dx,dz" spawns next to that player;
		-- Workspace attribute AIDump lists the AI near players (state, attack phase, task, path)
		local function watch(p: Player)
			p:GetAttributeChangedSignal("DevSpawn"):Connect(function()
				local v = p:GetAttribute("DevSpawn")
				local pp = Raid.posOf(p)
				if typeof(v) == "string" and pp then
					local kind, dx, dz, item, hpPct = string.match(v, "^(%w+),([%-%d%.]+),([%-%d%.]+),?([%w_]*),?([%d%.]*)")
					if kind then
						local sx, sz = Nav.snap(pp.X + tonumber(dx) :: number, pp.Z + tonumber(dz) :: number)
						local e = spawnEnemy(kind, sx, sz, nil)
						if item and item ~= "" then
							e.items = { { id = item, n = 3 } }
						end
						if hpPct and hpPct ~= "" then
							e.hp = e.maxHp * (tonumber(hpPct) :: number)
							e.model:SetAttribute("HP", e.hp)
						end
					end
				end
			end)
		end
		Players.PlayerAdded:Connect(watch)
		for _, p in Players:GetPlayers() do
			watch(p)
		end
		task.spawn(function()
			local last: { [Enemy]: Vector2 } = {}
			local stuckFor: { [Enemy]: number } = {}
			while true do
				task.wait(0.5)
				local rows = {}
				local nActive, nMoving, nStuck = 0, 0, 0
				for _, e in enemies do
					if e.active then
						nActive += 1
						local lp = last[e]
						if e.vel.Magnitude > 1 then
							nMoving += 1
							if lp and (e.pos - lp).Magnitude < 0.2 then
								stuckFor[e] = (stuckFor[e] or 0) + 0.5
							else
								stuckFor[e] = 0
							end
						else
							stuckFor[e] = 0
						end
						if (stuckFor[e] or 0) >= 1.5 then
							nStuck += 1
						end
					end
					last[e] = e.pos
				end
				table.insert(rows, string.format("active=%d moving=%d stuck=%d stepMs=%.2f max=%.1f pathQ=%d qmax=%d", nActive, nMoving, nStuck, stepMs, stepMax, #pathQ, queueMax))
				for _, e in enemies do
					local d = nearestPlayer(e.pos)
					if d < 60 then
						table.insert(rows, string.format("%s%s#%d %s/%s d=%.1f hp=%d foe=%s task=%s path=%s ammo=%d obst=%s v=%.1f items=%d use=%s", if (stuckFor[e] or 0) >= 1.5 then "STUCK " else "", e.def.kind, e.id, e.fsm, e.atk, d, e.hp,
							tostring(e.foe ~= nil), if e.task then string.format("%.1f,%.1f", e.task.target.X, e.task.target.Y) else "-", if e.path then tostring(#e.path) else "-", e.ammo, tostring(e.hasObstacle), e.vel.Magnitude, #e.items, tostring(e.useId)))
					end
				end
				Workspace:SetAttribute("AIDump", table.concat(rows, "\n"))
			end
		end)
	end
end

return Enemies
