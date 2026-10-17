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
	melee: boolean,
	weapons: { { any } },
	hitRadius: number,
	exp: number,
}
Config.Enemies = {} :: { [string]: EnemyDef }
Config.Enemies.scrapper = {
	kind = "scrapper",
	name = "Scrappy Goose",
	rig = "scrapper",
	hp = 35,
	dmgMul = 0.82,
	sight = 15,
	sightAngle = 100,
	reaction = 0.65,
	shootDelay = 0.35,
	shootTime = { 0.2, 0.5 },
	shootGap = { 1.0, 1.5 },
	walk = 4,
	run = 6,
	scatterMul = 0.65,
	bulletSpeedMul = 0.65,
	forget = 8,
	patrolRange = 8,
	combatMoveRange = 8,
	combatMoveTime = { 1, 3 },
	melee = false,
	weapons = { { "tt33", 0.3846 }, { "tt33", 0.3846 }, { "tt33", 0.2308 } }, -- pm / toz66 map to tt33 until their gunfeel rows are generated
	hitRadius = 0.5,
	exp = 15,
}
Config.Enemies.scav = table.clone(Config.Enemies.scrapper)
Config.Enemies.scav.kind = "scav"
Config.Enemies.scav.name = "Honker"
Config.Enemies.scav.rig = "scav"
Config.Enemies.scav.hp = 45
Config.Enemies.scav.dmgMul = 0.9
Config.Enemies.scav.bulletSpeedMul = 0.75
Config.Enemies.brute = table.clone(Config.Enemies.scrapper)
Config.Enemies.brute.kind = "brute"
Config.Enemies.brute.name = "Moose Brute"
Config.Enemies.brute.rig = "brute"
Config.Enemies.brute.hp = 60
Config.Enemies.brute.walk = 4 * 1.15
Config.Enemies.brute.run = 6 * 1.15
Config.Enemies.brute.melee = true
Config.Enemies.brute.forget = 7

-- Enemy AI limits (Enemy.ts AI const)
Config.AI = { trackRange = 20, meleeTrackRange = 24, activeDistance = 50, alertSightMul = 1.25, reacquireSightMul = 1.5, lostWait = 0.25 }

return Config
