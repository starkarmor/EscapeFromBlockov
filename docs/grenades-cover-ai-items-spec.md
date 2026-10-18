# Porting spec: grenades, covers/breakables, AI item use, aiCombat (Ground Zero)

All paths are relative to `/Users/joel/Desktop/Vibecoding/Games/EscapeFromBlockov`. Units are metres and seconds; the web game uses z mirrored from Unity.

## 1. Player throwables

### Item ids
These ids exist in `src/game/gz/gz_items.json` with `throw` blocks. The stat rows are `src/game/gz/gz_throw.json` `skills[key]` (key = item key), loaded via `throwData()` at `src/game/combat.ts:136`. Items for hotbar throwing must have kind `throwable` (`World.ts:1547`).

| id | castRange | readyTime | fuse (delay) | radius | dmg | AP | shake | note |
|---|---|---|---|---|---|---|---|---|
| grenade | 16 | 0.25 | 1.2 from first contact | 5.5 | 75 | 1.5 | 1.0 | |
| pipebomb (Dynamite) | 10 | 0.5 | 3.5 from release | 4.5 | 75 | 0 | 1.0 | |
| dynamite_multiple | 9 | 0.5 | 3.5 from release | 12 | 75 | 4 | 1.0 | |
| flash_grenade | 16 | 0.5 | 1.8 from release | 8 | 1 | 0 | 0.25 | ignoreArmor, Stun 1041 chance 1 |
| smoke_grenade | 16 | 0.5 | 2.0 from contact | 4.2 | 0 | 0 | 0 | spawns GrenadeZone_Smoke |
| fire_grenade | 15 | 0.5 | 0 from contact | 3.5 | no blast | 0 | n/a | `createExplosion=false`, spawns GrenadeZone_Fire |
| tox_grenade | 15 | 0.5 | 0 from contact | 3.7 | no blast | 0 | n/a | spawns GrenadeZone_Poison |
| ice_grenade | 15 | 0.5 | 0 from contact | 3.7 | 20 (listed) | 2 | n/a | `createExplosion=false`, spawns GrenadeZone_Ice |
| elec_grenade | 15 | 0.5 | 0 from contact | 3.5 | 20 | 0 | 0.1 | element 3, buff 1073 chance 1, ignoreArmor |
| trap (Bear Trap) | 5 | 0.5 | 1.2 from release, then landmine | 0.8 | 10 | 9 | 1.0 | armorBreak 1, Stun 1041, `isLandmine`, trigger r 0.5, no danger flag |
| stone | 13.5 | 0.2 | never (99999) | 0.1 | 1 | 0 | 1.0 | vy 4 |
| basketball | 12 | 0.2 | never | 0.1 | 0 | 0 | 1.0 | vy 12, bounce 0.8, bounceCombine 3 |
| shit_ball / shit_939 / shit_940 | 16 / 16 / 15 | 0.5 | 0 from contact | 4.2 | 5 | 0 | 0.1 | element 2 (poison), buff 1122 |
| grenade_space_boss (+_1153) | 12 / 16 | 0.5 | 0 from contact | 4.2 | 65 | 3 | 0.15 | armorBreak 8, blastCount 12 over 360°, blastSpace 0.05, `canHurtSelf=false`, buff 1117 |
| snow_ball, snow_ball_with_stone | n/a | n/a | n/a | n/a | n/a | n/a | n/a | item kind is `ammo`, so not hotbar-throwable. Skill rows: 6 / 10 dmg, r 4.2, element 6, buff 1126. |

Fields shared by all rows:
- `cooldown` 0.5 (Grenade_SpaceBoss 1.0).
- `stamina` 0.
- `vy` 5 (stone 4, basketball 12).
- `critRate` 0.
- `canHurtSelf` true except Grenade_SpaceBoss.
- `blastCount` 1 and `blastSpace` 0.2 unless noted.
- `dangerForAi` is false for basketball, smoke, stone and trap; true otherwise.

Stacks: grenade 8, pipebomb 10, dynamite_multiple 3, flash 8, smoke 5, trap 4, stone 12 (`gz_items.json`).

### Input and state machine
- Select: hotbar keys Digit3..Digit8 (`ItemShortcut3..8`). The handler is `World.ts:1539-1550`. It calls `p.switchTo('throw', id)` and shows a "No X left" toast if the count is 0.
- Aim and throw: the fire button is left mouse (`InputController.ts:149`, `mouseLeft`). It is hold-to-aim, release-to-throw (`World.ts:1624`, `handleThrow` at `World.ts:2355-2379`).
  - Press with `throwCd<=0` and `stamina>=0` starts action `throwAim` with `total=Infinity`.
  - `throwAim` is priority 5, can move (`move:true`), cannot run, and aims (`Player.ts:112`).
  - On release: if `action.t >= readyTime` the throw happens, otherwise it cancels and the item is kept.
  - A throw removes 1 item, sets `throwCd = 0.5`, and calls `launchGrenade`. If the count reaches 0 it switches to firearm1, then firearm2, then melee.
- Cancel: key X (`World.ts:1522`) calls `stopAction`.
- Weapon switching is refused while an action is running (`Player.ts:630-640`, `canEditInventory`).

### Aim point and launch velocity
- Target (`World.ts:2396`): the cursor point on the plane y = feet + 0.5 (`AIM_PLANE_Y = 0.5`, `gz_holdpose.json`). Its flat distance from the player is clamped to `castRange`.
- Release point (`World.ts:2425`): the right-hand socket `[0.2594, 0.5491, 0.2883]` for player and human, rotated by the thrower's facing (`body.ts:84`, `bodyPoint` at `body.ts:90`).
- Spin (`World.ts:2447`): random vector in the unit sphere, plus (1,1,1), times 7, then `y = 0`.
- Velocity (`launchVelocity`, `World.ts:2406-2414`, source `Skill_Grenade.CalculateVelocity`):
  ```
  g = 15; up = V/g; down = sqrt(|2*(up*V*0.5 + startY - endY)| / g)   // startY = hand y 0.5491, endY = 0.5
  T = up + down; h = dist/T; v = (dir*h, V, ...)                       // V = vy
  ```
  This is a fixed-vertical-speed lob. For vy 5, T ≈ 0.676 s, so a 16 m throw is about 23.7 m/s horizontal.
- Multi-blast (`World.ts:2432-2437`):
  - `step = blastAngle<359 ? blastAngle/(n-1) : blastAngle/n`.
  - Grenade i is aimed at `yaw + (-blastAngle/2 + step*i)` at the same distance.
  - Its fuse is `delay + blastSpace*i`.

### Rigid body (`GrenadePhysics.ts`)
- Global (`gz_throw.json` `physics`): gravity 15, fixed step 0.02, bounceThreshold 2, sleepThreshold 0.005, max angular speed 50, contact offset 0.01, 6 solver iterations, default friction 0.6, default bounce 0.
- Per item: mass 1, linear drag 0, angular drag 0.2 (grenade, dynamite) / 0.05 (flash, fire, tox, ice, elec, smoke) / 0.15 (stone), 0.15 (basketball).
- Collider (`gz_throw.json` per row): capsule r 0.18, height 0.46, centreY 0.02. Spheres: snowball r 0.18, stone r 0.12, basketball r 0.25. Trap is a box 0.7 × 0.1 × 0.7 at centreY 0.025 (`gz_throw.json`).
- Material: friction 0.6 Maximum-combine, so pair mu = 0.6. Bounciness 0 Average-combine, so restitution is 0. Basketball is the exception: bounce 0.8, Maximum-combine.
- `OnCollisionEnter` (`GrenadePhysics.ts:278-285`, source `Grenade.OnCollisionEnter`): on every NEW contact pair, `v.x *= 0.5`, `v.z *= 0.5`, and angular velocity `*= 0.3`.
- Sleep (`GrenadePhysics.ts:287-295`): asleep after 0.4 s below the energy threshold. Continuous collision sweep is used (`collisionDetection=1`).
- What it collides with (`World.ts:2600-2605`, `grenadeSolid`): ground, walls, doors and FowBlock foliage boxes. It does not hit live half cover or characters. Dead cover rubble is solid.
- **Simplify for Roblox:** the 0.5 factor on v.xz and 0.3 on spin at first contact, restitution 0 and friction 0.6 are the load-bearing parts. A native Roblox part with matching gravity is acceptable.

### Fuse and explode (`World.ts:2547-2597`, source `Grenade.Update`)
- `fuseT += dt` always, or only after the first contact when `delayFromCollide`.
- It explodes when `fuseT > delay + blastSpace*i`.
- Landmine (trap): arms at that moment. It is then tripped by any enemy-team character within `landmineRange 0.5` plus the body radius, and explodes once.
- `explode` (`World.ts:2527-2545`):
  - It calls the explosion listeners first (zone and smoke spawn, `World.ts:2013-2018`).
  - It then returns if `!createExplosion` (fire, tox, ice grenades make no blast and no shake).
  - Otherwise it calls `blast(x, z, effectRange, damage, ...)`.
  - Team is 7 (everyone, including the thrower) when `canHurtSelf`, else the thrower's team.

### Blast (`World.ts:2469-2525`, source `ExplosionManager.CreateExplosion`)
- **Damage is flat.** There is no distance falloff and no facing scaling (`gz_grenades.json` `rules.explosion.facts.noDistanceFalloff`).
- Camera shake: if the flat distance to the player is under 30, `shake(0.4 * item.shake, 'explosion', dirFromPlayerToBlast)` (`World.ts:2479`).
- Envelope (`CameraRig.ts:44-65`): 1 s duration, keys `[0,-1.4],[.27,.78],[.54,-0.12],[.75,.042],[.9,-0.02],[.95,-0.006],[1,0]`. The displacement is velocity-like in metres.
- Targets:
  - Enemy: in range if `dist(centre, enemy) <= radius + hitRadius`. `hitRadius` is `ENEMY_RADIUS` 0.5; boss 0.7 and wolf 0.65 (`Enemy.ts:275-278`).
  - Player: `<= radius + 0.5` (`PLAYER_HIT_RADIUS`, `Player.ts:98`).
- Line-of-sight (CheckObsticle): a ray from the blast centre to the target centre at world y 0.5, against wall, door and ground boxes only. Half cover does not block it.
- Skipped targets:
  - Dashing (rolling) characters.
  - Teams that are not enemies. `isEnemyTeam(a,b)`: false if either is 5; true if a is 7; else `a != b` (`Enemy.ts:447`).
  - Each Health is hit once.
- Damage applied: `armorFactor = 2/(clamp(armor - AP, 0, 999) + 2)` unless `ignoreArmor` (`Elements.ts:112,136`). `armorBreak` damages worn-armor durability.
- Element list, buff and chance come from `grenadeHit()` (`Grenades.ts:40`).
  - Stun 1041 lasts 7 s (1042 lasts 1.5 s). It adds Moveability -0.85, so walk, run and turn speed are ×0.15, one layer, exclusive tag Stun (`Grenades.ts:24-27`).
  - **No whiteout, blind or input lock exists** (`gz_grenades.json` `effects.flash.notModelled`).
  - Other buff ids: shock 1073, droppings 1122, snow 1126, rift boss 1117.
- Breakables, cover and robots in radius are also hit; see section 2.
- No AI sound is posted for the explosion itself (`World.ts:2464-2468`).

### AI sound from the grenade body (`World.ts:2578-2589, 2611-2616`)
- Each new contact posts a sound if `g.sounds < makeSoundCount` (3; basketball 8) and `t - lastSound > 0.3`.
- Radius is 20 (`GRENADE.soundRadius`, `World.ts:217`). Type is 2 (grenadeDrop) if `dangerForAi`, else 0. Team is the thrower's, or 7 for the player.
- See section 3 for the danger rules.

### Zones and smoke
- GrenadeZone_Fire (`gz_hazards.json` `prefabs[0]`):
  - Tick every 1.0 s with 1 damage (fire element), buff 1121.
  - Sphere radius 3.5. Grows over 1 s, holds 8 s, fades over 2.5 s.
- GrenadeZone_Poison (`prefabs[1]`):
  - Tick every 1.0 s with 1 damage (poison element), buff 1061.
  - Sphere radius 3.5. Grows over 1 s, holds 10 s, fades over 2.5 s.
  - The gas-mask check applies.
- GrenadeZone_Ice (`prefabs[2]`):
  - Tick every 1.0 s with 1 damage (ice element), buff 1126.
  - Sphere radius 4.25. Hold 10 s.
  - The gas-mask check applies.
- Smoke (`Grenades.ts:51-56`, `smokeRayT` at `Grenades.ts:125`):
  - Blocker scale: `age<1 ? max(0.01, age/1) : age<12 ? 1 : max(0, 1-(age-12)/2.5)`. The cloud is gone at 14.5 s.
  - Blockers: 8 boxes 3.31 × 3 × 0.15 on an octagon at 4 m, plus 8 spheres r 1.66.
  - Smoke blocks the player's fog of war (ray y 1.25, `World.ts:1314`), AI sight search (y 1.5) and AI shoot check (y 0.4). It does not block bullets or explosions.
  - Thermal vision ignores it.

### HUD
- Hotbar (`Hud.ts:529-543`): six slots, each showing the item icon, a `.ct` count if more than 1, a `.sel` class when it is the active throw item, and a key cap.
- 3D preview (`World.ts:743-758, 2902-2923`):
  - 14 white dots of r 0.09 along the ballistic arc from the player to the clamped target. They are visible only while aiming.
  - A blue ring (`#3c8cff`) of radius `effectRange` at the target.
  - Ring opacity is 0.35 when the throwable is selected, 0.6 while aiming, and 0.95 once ready.
- `World.throwAim()` (`World.ts:2925`) returns `{x, z, ready: min(1, t/readyTime)}`. **NOT FOUND: any consumer** in `Hud.ts` or `Game.ts`. The Hud progress bar reads only `p.use` (`Hud.ts:430-435`), so there is no throw progress bar.

## 2. Half cover and breakable walls

### Half cover
- Source: 72 pieces in `src/world/levels/ground_zero.json` `subScenes[0].covers[]`. All have `hp: 75`. Box height is 1.17 for 67 of them (range 1.17 to 2.14); length 3.31 to 3.51; width about 1.0 to 1.31.
- Placement: `LevelMap.ts:683-693`, with `coverHp = c.hp ?? 75` and collider height `clamp(k.h, 0.8, 1.9)`. The default is 75 at `Builder.ts:303`. A box counts as cover only if its collider height is in [0.8, 2) (`Builder.ts:361`).
- Block properties:
  - Cover blocks bodies and bullets, but not sight.
  - A bullet whose y is at or above the box top passes over (`World.ts:3406-3425`).
  - Grenades pass through live cover.
- Damage sources (`damageCover`, `World.ts:3433-3449`). HealthSimpleBase takes full damage with no armor.

| source | amount | ref |
|---|---|---|
| Player bullet | `damage × falloff` (falloff `dmgOver` or 0.5 past `halfAt`) | `World.ts:2703, 2760` |
| Enemy bullet | same × `COVER_AI_MUL` 0.5 | `World.ts:219` |
| Player melee | `damage × critMul if crit`, within reach and in the frontal arc | `World.ts:1966` |
| AI melee | `damage × 0.5` | `World.ts:1908` |
| Explosion | flat `damage` (×0.5 for AI throwers) | `World.ts:2493-2502` |

- Explosion test for cover: the nearest point of the cover box to the blast centre is within `radius`. There is no line-of-sight check, and `isEnemyTeam(team, 7)` must hold (false only for team 5).
- On break (`hp <= 0`):
  - Intact boxes get `off = true`.
  - Rubble boxes from `gz_coverdead.json` (the DeadVisuals colliders) switch on. A rubble piece no higher than the step offset 0.25 stops blocking bodies.
  - The mesh turns to a rubble material and scales y by 0.3.
- Cover is restored per raid (`World.ts:770`).

### Oil barrels (Explosive_OilBarrel)
Data is `src/world/gz/gz_breakables.json`, 31 barrels, built by `src/game/Breakables.ts:63-109`.
- HP 22; `danger` threshold at ≤ 15, which turns emissive.
- `onlyExplosion` false; `aiMul` 1.0; spawn chance 0.7 (`resetBreakables`, `Breakables.ts:112`).
- Receiver box 0.788 × 1.365 × 0.788. Body collider is a capsule r 0.48 on layer 0, which stops characters only. It remains after breaking.
- Explosion: `blast(pos, 3.6, damage 45, ap 1, armorBreak 1, shake 1, team 7)`, queued and run after the current blast (`World.ts:2001`, `pendingBlasts`).
- Receiver hit with damage `d` at HP loss `d × critMul × (byPlayer ? 1 : aiMul)` (`Breakables.ts:196-213`). Breakables are skipped for non-explosion hits only when `onlyExplosion`.
- Breakables are also hit by bullets (3D check `World.ts:2716-2721`), melee (`World.ts:1969-1974`) and explosions (`World.ts:2503`, distance to receiver box ≤ radius, no LOS).

### Breakable walls (the "dynamite" target)
- Three rows in `gz_breakables.json`: `BreakableWall` at (97.63, 112.71) yaw -178.53; `BreakableWall_2` at (-103.54, 15.61) yaw -130.43; `BreakableWall_1` at (5.97, 84.65) y -8.05. `BreakableWall_1` is skipped (`Breakables.ts:72`, `r.y < -2`).
- Stats: HP 30, `onlyExplosion: true`, `aiMul 1.0`, `save: true`. Receiver box 5.111 × 3.247 × 0.672. Obstacle body 5.001 × 3.057 × 0.5, built at collider height 2.6.
- Flag mapping (`src/world/levels.ts:103`): `BreakableWall_2 → 'wall'`, `BreakableWall → 'wall2'`.
- Damage: only `isExplosion` hits count. Pipe bomb and grenade (75) break it in one hit. Cumulative damage ≥ 30 also breaks it, for example two 20-damage shock grenades, or one barrel blast (45).
- Break (`World.ts:1994-2001`):
  - `setFlag(wallFlag)` (persisted in the profile via `hooks.flag`).
  - Toast "Wall Destroyed".
  - `applyFlags` (`World.ts:857`) turns the obstacle boxes off, hides the cracked mesh and shows the rubble mesh.
  - `resetBreakables` keeps it inactive on later raids.
- **There is no dynamite placement or interaction flow.** The "Cracked Wall" interact (`LevelMap.ts:1070`, `hold 0`, `r 2.4`) always reports "Requires Explosives" (`World.ts:3566`) and never fires. The wall breaks only by thrown or barrel explosions (pipebomb description: "Breaks cracked walls", `data.ts:335`). A placement flow is NOT FOUND.

## 3. AI inventories and item use

### What enemies carry
Real path: `Roster.ts:1121` `rollBody(e, preset, rand)`, wired at `Roster.ts:527` and called from `World.ts:877, 2249-2253`. It follows `gz_presets.json` `presets[*].drops`.

Roll rules (`Roster.ts:1127-1137`):
- `n = count[0] + floor(rand × (count[1] - count[0] + 1))`.
- `fromPool` true: one chance roll, then `n` items.
- `fromPool` false: `n` items, each with an independent chance roll.
- Pick is weighted.
- Stack size is `SPAWN_COUNT[id] ?? 1` (bandage 3).
- Stackable items merge.

**Grenades:** among Ground Zero's spawn presets, only `EnemyPreset_USEC_HiddenWareHouse` carries them.
- It appears at spawner `EnemySpawner_MoveUsec`: 13 points, count [1,2], weight 0.7 (`ground_zero.json` `subScenes[0].spawners[17]`). Its Enemy kind is `operator` (`Roster.ts:134`).
- Its drop entry: `{chance 0.3, count [1,2], fromPool true, pool [['grenade', 1.0]]}`.
- Other Ground Zero presets (Scav, Scav_low, Scav_low_ak74, Scav_Melee, Boss_ShortEagle and `_Elete`, Melee_UltraMan, Wolf, Mushroom, Spider_Rifle, StormCreature) have no throwables in their drops.

**Heal items:** two drop entries per preset roll them.
- Generic pool with 203 entries (heal share ≈ 0.14, or 0.07 / 0.056 for elites / boss) and a small med pool.
- Med pool weights: fak_s .448, bandage .224, aspirin .224, fak .067, first_aid_kit_l .028.

| preset | generic: chance, count | med pool: chance, count |
|---|---|---|
| Scav_low | 0.2, [1,2] | 0.2, [1,1] |
| Scav | 0.5, [1,2] | 0.25, [1,1] |
| Scav_Melee | 0.1, [1,1] | 0.15, [1,1] |
| Boss_ShortEagle | 0.5, [2,3] | 0.5, [1,2] |
| Boss_ShortEagle_Elete | 0.3, [1,2] | 0.5, [1,2] |
| USEC_HiddenWareHouse | 0.3, [1,2] | 0.5, [1,1] |

All preset defaults (`gz_presets.json`): `itemSkillChance 0.3`, `itemSkillCoolTime 6.0`.

### Heal (`Enemy.ts:1783-1809`)
- Constants `AI` (`Enemy.ts:414-433`): `healCheck 1.5`, `healBelowCombat 0.3`, `healBelowCalm 0.8`, `healWaitCombat 0.5`, `healHurtCombat [8,3]`, `healHurtCalm [5,2]`.
- Item choice: `startUse` picks the first carried item with `heal > 0`, in body order. It refuses while reloading or dashing. A dash cancels it (`Enemy.ts:1834`).
- Use time: `useT = CONSUMABLES[id].useTime` (from `gz_items.json`): bandage 0.8, aspirin 1, fak_s 2.5, fak 2.5, first_aid_kit_l 3, cola 2.5.
- Heal amounts: bandage 5, aspirin 10, fak_s 12, fak 20, first_aid_kit_l 35, cola 60, moon_shine 100.
- Effect: heal is applied once at the end (`finishUse`): `hp += min(heal, maxHp - hp)`.
  - Medkits with `uses` lose `heal / c.heal` of a use; the item is removed at `uses <= 0`.
  - Other stacks lose 1.
  - **No bleed removal and no buffs are applied for AI.**
  - Damage does not interrupt it.
- Calm heal (Patrol and Alert, `calmHeal` at `Enemy.ts:1302`, called from `Enemy.ts:1233, 1320`): the check timer is 1.5 s. If not hurt for ≥ 2 damage in the last 5 s and `hp <= 0.8 × max`, `startUse(false)` runs and the AI keeps walking.
- Combat heal (attack `gate` phase, `Enemy.ts:1536-1546`): applies only when there is an obstacle to the target and the AI was not hurt for ≥ 3 in the last 8 s. Every 1.5 s, if `hp <= 0.3 × max` and it has a drug: `atk='healWait'` for 0.5 s, then `startUse(true)` (stands still), then `atk='heal'` until `useT <= 0`, then back to `gate`.

### Throw (attack loop, `Enemy.ts:1548-1569`, tick at `Enemy.ts:1895-1906`)
1. In phase `gate` the AI first needs `!hasObstacle`, or hurt ≥ 3 in 8 s. It then requires `dist <= aimRange() × 1.5` (`throwRangeMul`, `Enemy.ts:1556`; `aimRange = BulletDistance × rangeMul - 0.4`, `Enemy.ts:778`).
2. If `!hasObstacle && now - skillCheckT >= 6 && ctx.throwGrenade` (`skillCheckT` starts at -99): set `skillCheckT = now`. This stamps the 6 s timer whether or not the roll succeeds.
3. It picks the first carried item that is a throwable. It throws if `rand() <= 0.3` and not reloading, using, swinging or dashing.
4. `throwT = throwSkill(id).ready + 0.1`, so a grenade takes 0.35 s. `throwAt = foe position (fp)` is frozen. `atk='throw'`. `aimPos = throwAt` every tick.
5. When `throwT <= 0`: remove 1 item and call `ctx.throwGrenade(e, id, x, z)` (`World.ts:1341`), which is `launchGrenade(..., owner=e)`. The hand socket and rotation use the enemy's kind and facing. Then `atk='gap'` with `gapT = U(def.gap)`.
- Aim point: the raw foe position, with **no castRange clamp** in the AI path. There is no lead or prediction (NOT FOUND).
- Gun fire is blocked during the wind-up (`Enemy.ts:1941`).
- Blast of AI grenades: `canHurtSelf=true` gives team 7, so AI grenades hurt the thrower and its own team. The `aiCombat` ratio applies, cover and breakables take ×0.5, `byPlayer=false`, and `fromPos` is the thrower.

### Danger and fleeDanger
- Set (`Enemy.ts:864-876`, `hear`): an incoming sound of type 2 sets `danger = {pos: live grenade pos, alive: () => grenade exists && !done}`.
  - This happens for every living enemy, regardless of distance or team.
  - The sound is "noticed" only if `dist < radius 20 × hearing`.
  - The type-2 branch exists because type 0 and 1 are ignored from the same team, but type 2 is not.
  - `Enemy.flee()` (`Enemy.ts:918`) is a legacy helper with no callers.
- Cleared: `alive()` false clears `danger = null` (`Enemy.ts:1107`).
- Trigger: flee only when flat distance to the grenade is ≤ 8, in Alert and Combat only (not Patrol).

| state | call | radius | avoid | angle | face danger |
|---|---|---|---|---|---|
| Alert (`Enemy.ts:1327`) | `fleeDanger(dt, ctx, 16, 10, 90, true)` | 16 | 10 | 90 | yes |
| Combat (`Enemy.ts:1465`) | `fleeDanger(dt, ctx, 15, 9, 10, false)` | 15 | 9 | 10 | no |

- `fleeDanger` (`Enemy.ts:1380-1393`):
  - Only if `fleeT <= 0`: `p = randomPoint(danger, radius, avoid, angle)`, then `moveTo(p, over 8)` and `fleeT = 8`.
  - `fleeT -= dt` each tick; `fleeT = 0` when `tickTask` finishes (arrival or timeout).
  - Says "Danger!" at most once per 5 s if `canTalk !== false`.
- `randomPoint` (`Enemy.ts:1001`):
  - Direction: from the AI toward the danger, reversed.
  - Angle: `(rand - 0.5) × angleDeg`.
  - Radius: `avoid + rand × (radius - avoid)`.
  - The point is `danger + (-dir rotated by angle) × r`.

## 4. aiCombat (AI-vs-AI damage factor)

**Formula:** `damage_out = base_damage × aiCombat(attacker) / aiCombat(victim)`, applied before armor, element factors and crit.
- Applied to bullets (`World.ts:2724-2726`, only when the shooter is an AI and `!b.byMain`), AI melee (`World.ts:1905`) and AI explosions (`World.ts:2511`, `o.from` set).
- It is ratio 1 when the attacker is the player or a player-controlled AI, and it never applies to AI-to-player damage.
- The source says it sits inside the armor branch (`gz_hazards.json` `rules.hurt`: `if (damageType != realDamage && !ignoreArmor) {... AI vs AI aiCombatFactor ratio}`). `Elements.ts:136` implements that gated form via `hit.aiCombatRatio`, but nothing sets it. The shipped code applies the ratio ungated in `World.ts`. A port should decide: the faithful form is ratio only when armor applies.

Per-kind values:

| kind (preset) | aiCombat | ref |
|---|---|---|
| scrapper, scav, brute | 1 | `Enemy.ts:176, 184, 193` |
| contractor (Boss_ShortEagle_Elete) | 1.5 | `Enemy.ts:201` |
| wolf | 1.2 | `Enemy.ts:210` |
| drone, bloater, stormling | 1.5 | `Enemy.ts:217, 226, 233` |
| boss (Boss_ShortEagle) | 2 | `Enemy.ts:241` |
| operator (USEC_HiddenWareHouse) | 1.5 | `gz_presets.json` `aiCombatFactor`, via `Roster.ts:406` |
| brute spawned as Melee_UltraMan | 2 (`Melee_UltraMan` preset) | `gz_presets.json` |

The default when undefined is 1 (`World.ts:1905, 2511`).

## NOT FOUND
- A player-placed dynamite item or plant interaction (breakable walls break only by explosion damage).
- A consumer of `throwAim()` or a throw-aim progress UI.
- A flash whiteout, blindness or AI perception change. The source assets do not contain one either.
- AI throw lead or prediction, and a castRange clamp in the AI throw path.
- The Unity 8-collider cap on blasts (not implemented in the web code).