--!strict
-- Gameplay tuning, 1:1 with the web build (metres, seconds, degrees). Each value names its web source.
-- Units.S converts distances to studs at the point of use; times never convert.
local Config = {}

-- src/entities/Player.ts MOVE / STAMINA / DASH
Config.Move = { walk = 4, run = 6, walkAcc = 50, runAcc = 70, turn = 200, aimTurn = 1200 }
Config.Stamina = { max = 100, drain = 7, recover = 20, recoverDelay = 1.5, runStartFrac = 0.2 }
Config.Dash = {
	time = 0.5,
	cooldown = 0.5,
	cost = 10,
	speed = 10,
	triggerLock = 0.6,
	-- DASH_KEYS (Player.ts:226): time, value, inSlope, outSlope (Unity AnimationCurve, Hermite)
	keys = { { -0.0012, 0.6136, 0, 0 }, { 0.1927, 1.0, 0, 0 }, { 0.7638, 0.7851, 0, 0 }, { 1, 0.546, 0, 0 } },
}
-- Player.ts PLAYER_RADIUS / PLAYER_HIT_RADIUS, hit3d.ts capsule; body.ts MODEL_TOP
Config.Body = { radius = 0.3, hitRadius = 0.5, hitHeight = 1.4, modelTop = 1.107, aimPlane = 0.5, muzzle = 0.8, maxHp = 40 }

-- src/systems/CameraRig.ts
Config.Camera = {
	distance = 45,
	pitch = 55,
	yaw = -30, -- Unity arm yaw; view basis = rotate by +30 deg
	fov = 23.5,
	adsFov = 22.8,
	aimOffset = 5,
	aimFactor = 0.5,
	lerpIdle = 12,
	lerpFiring = 1.5,
	lerpDrift = 1,
	planeY = 0.5,
	midSnap = 5,
	noGunAdsFactor = 1.25,
	shakePerShot = 0.07,
}
-- CameraRig.ts ENVELOPES (time, value, inSlope, outSlope)
Config.Shake = {
	recoil = { dur = 0.5, keys = { { 0, 0, 15.929328, 15.929328 }, { 0.062777, 1, 0, 0 }, { 0.336861, -0.206638, 0, 0 }, { 0.622401, 0.038077, 0.000338, 0.000338 }, { 1, 0, 0.062364, 0.062364 } } },
	melee = { dur = 0.5, keys = { { 0, 0, 29.671616, 29.671616 }, { 0.033702, 1, 0, 0 }, { 0.261888, -0.571327, 0, 0 }, { 0.368248, 0.347639, 0.000338, 0.000338 }, { 0.510468, -0.337255, 0, 0 }, { 0.582382, 0.090235, 0, 0 }, { 0.675636, 0, 0, 0 }, { 1, 0, 0.062364, 0.062364 } } },
	explosion = { dur = 1, keys = { { 0, -1.4, -7.9, -7.9 }, { 0.27, 0.78, 23.4, 23.4 }, { 0.54, -0.12, 22.6, 22.6 }, { 0.75, 0.042, 9.23, 9.23 }, { 0.9, -0.02, 5.8, 5.8 }, { 0.95, -0.006, -3, -3 }, { 1, 0, 0, 0 } } },
}

-- CameraVolumes (gz_volumes.json level14, our frame x = wx - 329, z = -(wz - 241)); hide = off in Motion Sickness mode.
-- Blend: t = 1 - (d / blend)^2 outside the sphere, pitch eases 5/s, yaw and distance 2/s.
-- the cave sub-scene (level15): a global volume (15, -8, 20) and the close-up sphere at its mouth (priority 11)
Config.CaveVolumes = {
	global = { pitch = 15, yaw = -8, distance = 20 },
	{ x = 582.733 - 329, z = -(552.069 - 241), sphere = 9, blend = 17.23, pitch = 35, yaw = -15, distance = 50 },
}
Config.CameraVolumes = {
	{ x = 221.193 - 329, z = -(304.179 - 241), sphere = 10, blend = 10, pitch = 19.58, yaw = -7.8, distance = 35 },
	{ x = 453.363 - 329, z = -(103.589 - 241), sphere = 6, blend = 8, pitch = 25, yaw = -45, distance = 35 },
	{ x = 322.743 - 329, z = -(192.869 - 241), sphere = 10, blend = 10, pitch = 12, yaw = -8, distance = 35 },
	{ x = 322.393 - 329, z = -(182.739 - 241), sphere = 10, blend = 10, pitch = 12, yaw = -8, distance = 35 },
	{ x = 346.023 - 329, z = -(231.929 - 241), sphere = 4, blend = 8.15, pitch = 9.2, yaw = 52.2, distance = 34.83 },
}
-- data.ts WEIGHT_BANDS / BASE_CARRY_KG, STARVE, THIRST
Config.Weight = { carry = 45, light = 0.25, lightSpeed = 0.15, heavy = 0.75, heavySpeed = -0.4, over = 1, overSpeed = -1, starveSpeed = -0.1, thirstMoveability = -0.2 }

-- World.ts VIEW (fog of war), night multipliers
Config.View = { angle = 100, dist = 37, bubble = 1.5, eye = 1.25, nightMul = { 0.4, 0.4, 0.5 } }

-- World.ts EXTRACT_TIME / pad radius; data.ts INSPECT_TIMES; loot reach
Config.Extract = { time = 5, padRadius = 3 }
Config.Loot = { inspect = { 1, 1, 1, 1, 1.5, 2, 1 }, closeDistance = 2.8, interactRadius = 1.8 }
-- data.ts clock: CLOCK_SCALE 40 (36 real minutes a day), raid starts 08:00
Config.Clock = { scale = 40, start = 8 }

-- Firearms: src/game/gz/gz_items.json + gz_gunfeel.json (BulletSpeed, BulletDistance are gunfeel's)
export type Gun = {
	id: string,
	name: string,
	caliber: string,
	damage: number,
	mag: number,
	shootSpeed: number,
	burst: number,
	auto: boolean,
	reload: number,
	bulletSpeed: number,
	range: number,
	dmgOverDistance: number,
	critMul: number,
	adsTime: number,
	moveMul: number,
	adsWalkMul: number,
	scatterHip: number,
	scatterAds: number,
	scatterMax: number,
	scatterGrow: number,
	scatterRecover: number,
	recoilV: { number },
	recoilH: { number },
	recoilScaleV: number,
	recoilScaleH: number,
	soundRange: number,
	adsFactor: number,
	maxDurability: number,
	pellets: number,
	shotAngle: number,
}
Config.Guns = {} :: { [string]: Gun }
Config.Guns.tt33 = {
	id = "tt33",
	name = "TT-33",
	caliber = "S",
	damage = 11,
	mag = 8,
	shootSpeed = 6,
	burst = 1,
	auto = false,
	reload = 1.8,
	bulletSpeed = 79,
	range = 16.5,
	dmgOverDistance = 0.5,
	critMul = 1.2,
	adsTime = 0.3,
	moveMul = 1,
	adsWalkMul = 0.5,
	scatterHip = 0.349 * 17.5,
	scatterAds = 0.313 * 11.5,
	scatterMax = 1.28 * 17.5,
	scatterGrow = 0.629 * 17.5,
	scatterRecover = 0, -- filled from gunfeel by tools/gen_items.py (TODO); recover = ScatterRecover * grow * ShootSpeed
	recoilV = { 0.918, 1.082 },
	recoilH = { -0.348, 0.652 },
	recoilScaleV = 38,
	recoilScaleH = 29,
	soundRange = 20.3,
	adsFactor = 1,
	maxDurability = 100,
	pellets = 1,
	shotAngle = 0,
}

-- Melee: gz_melee.json "stick"
Config.Melee = {
	stick = { damage = 18, attackSpeed = 2, range = 1.55, reach = 0.05, dealTime = 0.12, actionTime = 0.25, critRate = 0.4, critMul = 1.4, bleedChance = 0.05 },
}

-- Ammo: gz_items.json ammo_s_rusty
Config.Ammo = {
	ammo_s_rusty = { name = "Rusty S Rounds", caliber = "S", dmgMul = 1, pen = -1, armorBreak = 0.55, bleedChance = 0.03, durCost = 0.1 },
}

-- Enemies: gz_presets.json via src/entities/Enemy.ts ENEMY_DEFS (metres, seconds, degrees)
export type EnemyDef = {
	kind: string,
	name: string,
	rig: string,
	hp: number,
	dmgMul: number,
	sight: number,
	sightAngle: number,
	reaction: number,
	shootDelay: number,
	shootTime: { number },
	shootGap: { number },
	walk: number,
	run: number,
	scatterMul: number,
	bulletSpeedMul: number,
	forget: number,
	patrolRange: number,
	combatMoveRange: number,
	combatMoveTime: { number },
	melee: any,
	weapons: { { any } },
	team: number,
	turnPatrol: number,
	turnCombat: number,
	mv: number?,
	critGain: number?,
	patrolScare: boolean?,
	ring: boolean?,
	canTalk: boolean?,
	tint: Color3?,
	fixedArmor: number?,
	fixedHelmet: number?,
	bodyLen: number?,
	boss: boolean?,
	aiCombat: number?,
	armorRoll: { any }?,
	helmetRoll: { any }?,
	runScatter: number?,
	offScreenScatter: number?,
	reloadGain: number?,
	nightReact: number?,
	nightVision: number?,
	traceChance: { number }?,
	dash: { number }?,
	shootCanMove: boolean?,
	rangeMul: number?,
	hearing: number?,
	scale: number?,
	hitRadius: number,
	exp: number,
}
Config.Enemies = {} :: { [string]: EnemyDef }
-- src/entities/Enemy.ts ENEMY_DEFS (sight m, sightAngle deg, reaction s, shootTime = burst, shootGap = gap, walk/run = mv(k))
local function def(t: any): EnemyDef
	t.walk = 4 * (t.mv or 1)
	t.run = 6 * (t.mv or 1)
	t.hitRadius = t.hitRadius or 0.5
	t.melee = t.melee or false
	t.exp = t.exp or 15
	t.turnPatrol = t.turnPatrol or 400
	t.turnCombat = t.turnCombat or 1200
	-- Enemy.ts: traceChance rolled once per spawn; melee kinds always follow the noise
	t.traceChance = t.traceChance or (if t.melee then { 1, 1 } else { 0.3, 0.7 })
	return t
end
Config.Enemies.scrapper = def({ kind = "scrapper", name = "Scav Grunt", rig = "NPC_scrapper", critGain = -0.3, scale = 0.88, aiCombat = 1, hp = 35, dmgMul = 0.82, sight = 15, sightAngle = 100, reaction = 0.65, shootDelay = 0.35,
	shootTime = { 0.2, 0.5 }, shootGap = { 1.0, 1.5 }, scatterMul = 0.65, bulletSpeedMul = 0.65, forget = 8, patrolRange = 8, combatMoveRange = 8, combatMoveTime = { 1, 3 },
	weapons = { { "toz66", 15 }, { "tt33", 25 }, { "pm", 25 } }, team = 1 })
Config.Enemies.scav = def({ kind = "scav", name = "Scav", rig = "NPC_scav", scale = 0.92, aiCombat = 1, armorRoll = { 0.5, { 250, 50, 5, 0 } }, helmetRoll = { 0.3, { 150, 40, 15, 0 } }, hp = 45, dmgMul = 0.9, sight = 15, sightAngle = 100, reaction = 0.65, shootDelay = 0.35,
	shootTime = { 0.2, 0.5 }, shootGap = { 1.1, 1.8 }, scatterMul = 0.65, bulletSpeedMul = 0.75, forget = 8, patrolRange = 8, combatMoveRange = 8, combatMoveTime = { 1, 3 },
	weapons = { { "shotgun_homemade", 10 }, { "mp155", 10 }, { "g17", 10 }, { "bow", 3 }, { "ak47", 5 }, { "ak103", 1 }, { "ak74u", 8 }, { "adar", 4 } }, team = 1 })
Config.Enemies.brute = def({ kind = "brute", name = "Brute", rig = "NPC_brute", scale = 1.0, aiCombat = 1, hp = 60, dmgMul = 1, sight = 15, sightAngle = 100, reaction = 1.0, shootDelay = 0.2, mv = 1.15,
	shootTime = { 0.3, 0.75 }, shootGap = { 0.5, 1.5 }, scatterMul = 0.35, bulletSpeedMul = 0.75, forget = 8, patrolRange = 8, combatMoveRange = 3.5, combatMoveTime = { 1, 3 },
	weapons = {}, melee = { damage = 27, range = 1.55, interval = 1 / 2.2, bleed = 0.5, critRate = 0.2, critMul = 1.6 }, team = 1 })
Config.Enemies.contractor = def({ kind = "contractor", name = "Contractor", rig = "NPC_contractor", scale = 0.95, aiCombat = 1.5, traceChance = { 0.1, 0.8 }, armorRoll = { 1, { 10, 300, 50, 4 } }, helmetRoll = { 0.3, { 0, 200, 50, 4 } }, hp = 60, dmgMul = 1, sight = 16, sightAngle = 100, reaction = 0.55, shootDelay = 0.25,
	shootTime = { 0.4, 0.8 }, shootGap = { 0.8, 2.2 }, scatterMul = 0.5, bulletSpeedMul = 1, forget = 8, patrolRange = 8, combatMoveRange = 8, combatMoveTime = { 1, 3 }, turnPatrol = 600,
	weapons = { { "m4a1", 10 }, { "mp7", 8 }, { "ump45", 8 }, { "mp155", 8 }, { "mp5", 10 }, { "vector", 8 } }, team = 3 })
Config.Enemies.boss = def({ kind = "boss", name = "Warlord", rig = "NPC_boss", scale = 1.2, aiCombat = 2, traceChance = { 0.5, 0.5 }, runScatter = 2, offScreenScatter = 2, rangeMul = 1.25, reloadGain = 1, dash = { 4, 7 }, armorRoll = { 1, { 0, 0, 1, 0 } }, hp = 160, dmgMul = 1, sight = 17, sightAngle = 140, reaction = 0.45, shootDelay = 0.15,
	shootTime = { 1, 2 }, shootGap = { 1.3, 2.3 }, scatterMul = 0.4, bulletSpeedMul = 0.9, forget = 8, patrolRange = 8, combatMoveRange = 8, combatMoveTime = { 1, 3 }, turnPatrol = 600,
	weapons = { { "ak47", 1 } }, hitRadius = 0.7, team = 3, exp = 100 })
Config.Enemies.wolf = def({ kind = "wolf", name = "Wolf", rig = "NPC_wolf", aiCombat = 1.2, hp = 40, dmgMul = 1, sight = 15, sightAngle = 100, reaction = 0.2, shootDelay = 0.2, mv = 1.3,
	shootTime = { 0.2, 0.2 }, shootGap = { 0, 0 }, scatterMul = 0.35, bulletSpeedMul = 1, forget = 8, patrolRange = 8, combatMoveRange = 8, combatMoveTime = { 1, 3 }, turnPatrol = 600,
	weapons = {}, melee = { damage = 25, range = 2, interval = 1 / 1.3, bleed = 0.5, critRate = 0.15, critMul = 1.15 }, hitRadius = 0.65, team = 8,
	dash = { 1, 1.2 }, shootCanMove = true })

-- EnemyPreset_Melee_UltraMan (gz_presets 76513): team 7 boss, battle axe, Patrol_Scare (stands until hurt for 2 in 0.25 s)
Config.Enemies.giant = def({ kind = "giant", name = "Giant", rig = "NPC_giant", hp = 400, dmgMul = 1, sight = 13, sightAngle = 100, reaction = 0.2, shootDelay = 0.2, mv = 1.3,
	shootTime = { 0.2, 0.2 }, shootGap = { 0.2, 0.2 }, scatterMul = 0.35, bulletSpeedMul = 1, forget = 8, patrolRange = 8, combatMoveRange = 8, combatMoveTime = { 1, 3 }, turnPatrol = 600,
	weapons = {}, melee = { damage = 40, range = 1.5, interval = 0.83, bleed = 0.35, critRate = 0.2, critMul = 1.4, weapon = "battle_axe" }, hitRadius = 0.7, team = 7, aiCombat = 2,
	scale = 1.3, patrolScare = true, exp = 100, boss = true })
-- EnemyPreset_USEC_HiddenWareHouse: team 3, grenades 30% x1-2, armor always (armor_l2 .80 ...), helmet 30%
Config.Enemies.operator = def({ kind = "operator", name = "Operator", rig = "NPC_operator", hp = 60, dmgMul = 1, sight = 16, sightAngle = 100, reaction = 0.45, shootDelay = 0.25,
	shootTime = { 0.25, 0.55 }, shootGap = { 0.8, 2.2 }, scatterMul = 0.6, runScatter = 3, offScreenScatter = 3, bulletSpeedMul = 0.8, rangeMul = 1.3, forget = 8, patrolRange = 25,
	combatMoveRange = 8, combatMoveTime = { 1, 3 }, turnPatrol = 500, traceChance = { 0.1, 0.8 }, shootCanMove = true, aiCombat = 1.5, scale = 0.95,
	weapons = { { "mp7", 0.2759 }, { "m4a1", 0.1724 }, { "aug_a1", 0.1724 }, { "mp155", 0.1379 }, { "ump45", 0.1379 }, { "vector", 0.069 }, { "mdr556", 0.0345 } },
	armorRoll = { 1, { 0, 80, 15, 4 } }, helmetRoll = { 0.3, { 0, 200, 50, 4 } }, team = 3, exp = 150 })
-- EnemyPreset_Mushroom: the 8-pellet ring gun (15 per pellet: 10 x 12 / 8), rain spawns
Config.Enemies.bloater = def({ kind = "bloater", name = "Bloater", rig = "NPC_bloater", hp = 80, dmgMul = 12, sight = 19, sightAngle = 100, reaction = 0.4, shootDelay = 0.2,
	shootTime = { 0.2, 0.5 }, shootGap = { 1.0, 1.5 }, scatterMul = 0.65, bulletSpeedMul = 0.75, rangeMul = 1.2, forget = 10, patrolRange = 8, combatMoveRange = 8, combatMoveTime = { 1, 3 },
	traceChance = { 0.25, 0.25 }, turnPatrol = 1000, aiCombat = 1.5, weapons = { { "egun_ring", 1 } }, ring = true, canTalk = false, team = 8, exp = 100, bodyLen = 1.3 })
-- EnemyPreset_StormCreature: storm spawns, canDash 2-4 s, never strafes (combatMoveTime 0)
Config.Enemies.stormling = def({ kind = "stormling", name = "Stormling", rig = "NPC_scav", hp = 150, dmgMul = 1.1, sight = 18, sightAngle = 100, reaction = 0.1, nightReact = 1, nightVision = 1,
	shootDelay = 0.25, mv = 1.6, shootTime = { 0.4, 1.0 }, shootGap = { 1.1, 1.8 }, scatterMul = 0.35, bulletSpeedMul = 1.25, forget = 8, patrolRange = 8, combatMoveRange = 8,
	combatMoveTime = { 0, 0 }, traceChance = { 1, 1 }, turnPatrol = 500, aiCombat = 1.5, weapons = { { "egun_storm", 1 } }, dash = { 2, 4 }, canTalk = false, team = 8, exp = 100,
	scale = 1.05, tint = Color3.fromHex("#6a4a8a") })
-- EnemyPreset_Spider_Rifle: night spawns, armor 4 / 4, hackable (not ported)
Config.Enemies.drone = def({ kind = "drone", name = "Spider Drone", rig = "NPC_drone", hp = 75, dmgMul = 1.2, sight = 17, sightAngle = 100, reaction = 0.3, nightReact = 1, shootDelay = 0.2,
	shootTime = { 0.5, 1.0 }, shootGap = { 2.0, 3.0 }, scatterMul = 0.35, offScreenScatter = 3, bulletSpeedMul = 1, forget = 8, patrolRange = 8, combatMoveRange = 8, combatMoveTime = { 1, 3 },
	traceChance = { 1, 1 }, turnPatrol = 300, shootCanMove = true, aiCombat = 1.5, weapons = { { "egun_spider", 1 } }, fixedArmor = 4, fixedHelmet = 4, team = 6, exp = 250, bodyLen = 1.1 })

-- Enemy AI limits (Enemy.ts AI const)
Config.AI = { trackRange = 20, meleeTrackRange = 24, activeDistance = 50, alertSightMul = 1.25, reacquireSightMul = 1.5, lostWait = 0.25 }

return Config
