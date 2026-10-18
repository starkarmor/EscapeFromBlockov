# Ground Zero spec: weather, day/night, five enemy kinds, map screen

Paths are under `/Users/joel/Desktop/Vibecoding/Games/EscapeFromBlockov`. There is no purple wall, shrinking zone or moving front anywhere. The "storm" is a time-based damage-over-time status with a purple screen tint (section 1.4).

Important data caveat: Ground Zero's real spawn tables are in `src/world/levels/ground_zero.json`, `subScenes[0].spawners`. `LevelMap.ts:884-947` reads them. The `spawners` array in `src/world/gz/gz_spawns.json` is legacy and unused. `src/world/levels.ts:104` only reads its `.containers`. It wrongly shows UltraMan as `brute` and USEC as `contractor`.

## 1. Weather

### 1.1 States and how they are decided
- **States:** `Sunny | Cloudy | Rainy | Storm | Snow` (`Weather.ts:26`). Snow only applies in winter levels, so it never occurs in Ground Zero. The Ground Zero level config has `season: 0`.
- **No timers or dice:** weather is a pure function of the game clock and a per-save seed, recomputed every frame (`Game.ts:416-457`).
  - `weatherAt(clockMin, seed, stormLevel)` (`Weather.ts:89-95`):
    - if stormLevel > 0 then `Storm`
    - else p > 0.68 gives `Rainy`
    - else p > 0.66 gives `Cloudy`
    - else `Sunny`
- **Constants** (`Weather.ts:28`): `{cloudy 0.66, rainy 0.68, frequency 0.05, offset 0.13, contrast 1.17}`.
- **Seed:** `Math.floor(rand()*100000)`, created once and stored on the profile as `weatherSeed` (`Weather.ts:98`, `Game.ts:463-469`).
- **Precipitation** (`Weather.ts:76-86`):
  - `days = floor(clockMin/1440)`, `hours = floor(inDay/60)`, `minutes = floor(inDay − hours*60)`.
  - `x = ((days % 3650)*24 + hours + minutes/60) * 0.05`.
  - `y = seed + floor(days/3650)`.
  - `p = (P(x,y) + P(x+0.5+123.4, y−567.8)) / 2`.
  - `v = clamp01((p − 0.5)*1.17 + 0.5 + 0.13)`.
  - `P` is Unity `Mathf.PerlinNoise`: improved noise at z=0 on |x|,|y|, remapped as `(n+0.69)/1.483` (`Weather.ts:30-73`).
  - Port `unityPerlin` verbatim, with its 256-entry permutation table doubled to 512 (`Weather.ts:30-33`). Roblox `math.noise` is not equivalent.
- **Measured (200 days, 4 seeds, via the TS functions):**
  - About 72% Sunny, 5% Cloudy, 22-23% Rainy.
  - Rain spells average 10.7-12.1 game hours, about 7 real minutes.
  - Clock 480 (08:00 day 0) gives Cloudy for seed 0, Rainy for seed 1, Sunny for seeds 12345 and 99999.

### 1.2 Clock and storm schedule
- **Clock rate:** `CLOCK_SCALE = 40` (`data.ts:1177`).
  - The clock advances `dt*40/60` game minutes per real second (`Game.ts:1592`), whenever state is not `'result'`. That includes the bunker.
  - One game hour is 90 real seconds. One day is 36 real minutes.
- **Raid start time:** `clock: 8*60` is the profile default (`Profile.ts:208`). The clock persists across raids. Ground Zero has no `forceTime` (`timeOfDay.forceTime = null`). Sleeping adds minutes or jumps to 06:00 (`Game.ts:647-663`).
- **Storm timing** (`data.ts:1185`, `Game.ts:78-80`):
  - `STORM = {sleepDays:9, stageHours:12, stages:[{every:3, need:0.9, dps:1}, {every:1.5, need:1.9, dps:2}], layerSecs:5, maxLayers:12}`.
  - `STORM_START = 9*1440 = 12960` min and `STORM_CYCLE = 12960 + 2*12*60 = 14400` min.
  - `cyc = clock % 14400`. Storm is active when `cyc >= 12960`. Stage 1 lasts 12 h, then Stage 2 lasts 12 h (`Game.ts:426-428`).
  - Real time: asleep 324 min, then 18 min per stage.
- **HUD countdown** (`Game.ts:435-438`, `Hud.ts:319-327`):
  - Idle label: `"Next Storm Arrives In:"`, value `H:MM` = `floor(min/60):floor(min%60)` of `STORM_START − cyc`, hours not capped (for example `135:52`).
  - Start value: clock 480 gives `12960 − 480 = 12480` min, shown as `208:00`.
  - During a storm: label `"Storm Phase I Ends In:"` or `"Storm Phase II Ends In:"`, value `STORM_CYCLE − cyc`.
  - Progress bar `--p` is `stormPct*100`. `stormPct` is `cyc/STORM_START` idle, else `(cyc−STORM_START)/(STORM_CYCLE−STORM_START)`.
  - Other HUD fields: `clock-time` = `HH:MM`, `clock-phase` = `Day|Dusk|Night`, `clock-weather` = the weather string.
- **Forced weather:** `TimeOfDayConfig.forceWeather` replaces both weather and storm stage (`Game.ts:904-907`, `428`). Ground Zero has none (`forceWeather: null`).

### 1.3 Rain effects on gameplay
- **Enemy spawns:** the `MushroomGroups` root creates bloaters (section 3).
- **Element factors:** outside the base, while Rainy, every receiver (player and AI) gets fire −0.15 and electricity +0.2 (`Elements.ts:98-106`, `gz/gz_elements.json:67`). `rainyWeatherValue` is 2. Wired at `Game.ts:443`.
- **Sight:** only the TimeOfDayPost "wet" factors in 2.2 apply. Cloudy uses the same factors as Rainy.
- **Fishing:** Rainy = weather 2 (`Fishing.ts:318`). The `Fish_OnlyRainDay` tag requires weather 2 or 22 (`Fishing.ts:322-330`).
- **Speed:** NOT FOUND.
- **Sound:** NOT FOUND. No rain audio or sound-radius change exists.

### 1.4 Storm effects
- **Damage (StormWeather)** (`World.ts:1212-1229`, `Player.ts:1049`):
  - Only in a zone raid and not `sheltered`. Sheltered means the player is inside a `map.shelters` box: indoor sub-scenes, or building footprints (`LevelMap.ts:1169-1176`, `Builder.ts:515`).
  - If `player.stormProtection() < stage.need`, add one layer every `stage.every` s (3 s in Stage I, 1.5 s in Stage II), max 12.
  - All layers expire 5 s after the last one was added.
  - DPS = `layers * stage.dps` (1 or 2 HP/s per layer), then × the `damageTakenMul` ruleset factor. It ignores armor.
  - Protection is the sum of `GEAR[slot].storm` over head, face and body (`Player.ts:606-609`). Only `helmet_storm` (storm 1, `data.ts:501`) and `gasmask` (storm 1, `data.ts:502`) have it.
  - In practice: Stage I needs 1 point, Stage II needs 2.
  - HUD status "Distortion" shows when `stormProtection() < stormPhase` and unsheltered (`Hud.ts:497`).
- **Storm creatures:** `stormling` spawns (section 3). The AK-47 blueprint cache is active only in Stage II (`Game.ts:1084-1091`).
- **Visuals:**
  - Screen tint (`ui/duckov.css:34-35`): `#storm-tint` is `rgba(120,60,170,0.22)` with a 2 s opacity fade. It is on when `clock.storm && zone`.
  - Sky and fog: see 2.3.
  - Sight: Storm I factors 0.8, Storm II factors 0.6 (2.2).
  - Torch: `env.torch` 0.6 (2.3).

### 1.5 Rain visuals (`Game.ts:690-722`, `styles.css:92-93`)
- A 2D canvas overlay with 220 streaks.
- Fall speed 700 + rand×500 px/s, drifting left at 0.15 of the fall speed.
- Streak is a line from (x, y) to (x+3, y−14). Stroke is `rgba(190,210,235,0.35)`, width 1.
- A streak that passes the bottom respawns at y = −20, with x = rand×(width+100).
- Overlay fades in over 1.5 s.
- Active only when `weather==='Rainy' && mode==='zone' && !map.indoor` (`Game.ts:1609`). It is not shown in the cave.
- Scene lighting does not change for rain.

## 2. Day and night

### 2.1 Phases
- **Hour and phases:** `hour = (clock/60) % 24`, fractional (`Game.ts:417`).
  - `TIME_OF_DAY = {morning:6, dusk:18, night:22}` (`data.ts:1179`).
  - Day is 06:00-18:00, dusk 18:00-22:00, night 22:00-06:00 (`Game.ts:423-424`).
- **Base alert text:** shown near 22:00 and at night (`todAlert.ts:14-17`, `gz/gz_todalert.json`): `nearNightHours 4`, `stayTime 5`.

### 2.2 Player view (fog-of-war cone)
- **Base values** (`World.ts:255-257`): `VIEW = {angle:100, dist:37, bubble:1.5, ease:180, senseEase:15, distEase:30, senseGap:2.5}`. `NIGHT.flashlight = 0.3`.
- **TimeOfDayPost factors `[angle, dist, sense]`** (`World.ts:266-277`, `todPost()` at `:279`):

| State | Factors |
|---|---|
| Sunny day / dusk | 1, 1, 1 |
| Sunny night | 0.4, 0.4, 0.5 |
| Cloudy or Rainy, day | 0.8, 0.8, 0.8 |
| Cloudy or Rainy, dusk | 0.7, 0.7, 0.7 |
| Cloudy or Rainy, night | 0.35, 0.35, 0.4 |
| Storm I, any hour | 0.8, 0.8, 0.8 |
| Storm II, any hour | 0.6, 0.6, 0.6 |

- **Selection order:** Storm II, then Storm I (or `weather==='Storm'`), then Sunny vs wet by phase. The phase boundaries here are 18 and 22 (`World.ts:281`).
- **Blend:** the active factors blend over `TOD_BLEND = 8` s with smoothstep weight `3s²−2s³`, `s = t/8`. A new target waits until the running blend ends (`World.ts:3519-3534`).
- **Per-frame cone** (`World.ts:3486-3515`):
  - `t = clamp01(NightVisionAbility + 0.3 if held gun has a light)`. `NightVisionAbility` is the sum of gear and perks.
    - Gear: night vision goggles +1 (toggled with N), thermal goggles +1, `head_lantern` +0.25, `helmet_storm` +0.3, `helmat_pumpkin_light` +0.4 (`data.ts:376-382`).
    - Perks add on top (`Player.ts:526-537`).
  - `lerp(f,1,t) = f + (1−f)t`.
  - Angle = (100 + perk bonus) × lerp(f.angle,1,t).
  - Sense = (1.5 + perk bonus) × lerp(f.sense,1,t).
  - Distance = max((37 + perk bonus) × lerp(f.dist,1,t), sense − 2.5).
  - Current values ease toward target at 180°/s, 30 m/s (distance) and 15 m/s (sense). The first frame snaps.
  - Aiming down sights multiplies the drawn range by 1.15 when ADS > 0.5 (`World.ts:1315`).
- **Sunny night, t=0:** 40°, 14.8 m, bubble 0.75 m.
- **Rainy night, t=0:** 35°, 12.95 m, bubble 0.6 m.
- **Flashlight (t=0.3), Sunny night:** 58°, 21.46 m, 0.975 m.

### 2.3 Lighting
Lighting is set in `Game.ts:471-508`, called each frame at `:1595`.
- **Base or bunker:** hemisphere `#cfd8e0` / ground `#1d2226` at 0.8, sun 0, background `#0d1013`, no fog.
- **Cave (`indoor`):** hemisphere `#8a9cb0` / `#1a1f24` at 0.6, sun 0, background `#040608`, fog `#040608` from `CAMERA_DISTANCE+4` to `+34`.
- **Outdoor zone, with `CAMERA_DISTANCE = 45` (`CameraRig.ts:16`):**
  - `k = clamp(sin(((hour−5.5)/15)·π), 0, 1)`.
  - **Sun colour:** if k>0.05, `lerp('#ffb070','#fff3d6', min(1,1.6k))`; otherwise `'#8fa6d8'`.
  - **Sun intensity:** `(k>0.05 ? 0.4+2k : 0.35) × (storm ? 0.5 : 1)`.
  - **Sun position:** `ang = ((hour−6)/14)π`; position (px − cos(ang)·30, 50, pz+18), target = player.
  - **Hemisphere colour:** `k>0.05 ? '#fff6e0' : '#6d7fae'`; ground `k>0.05 ? '#4a5a3a' : '#1c2333'`.
  - **Hemisphere intensity:** `(0.55+0.95k) × (storm ? 0.6 : 1)`.
  - **Sky or background:** storm `#5a4a72`, otherwise `lerp('#202a3a','#9fb8c9',k)`.
  - **Fog colour:** the sky colour.
  - **Fog range:** storm: near 45−26 = 19, far 45+11 = 56, always on. Non-storm: near 46, far 111, only if the Fog option (`SunFogSetting === 1`) is on.
- **Player torch** (`Game.ts:453`, `World.ts:696`, `:1415-1416`):
  - `env.torch = night ? 1 : dusk ? 0.45 : storm ? 0.6 : 0`.
  - SpotLight `('#fff0d0', 0, 30, 0.75, 0.55, 1)`.
  - Intensity without a gun light = `env.torch*35`. With a gun light: 90 if `env.torch>0`, else 25. Cone angle 0.5 with a light, else 0.75.
  - NVG fill is a HemisphereLight `('#d8ffd8','#2a3a2a')` at `env.torch*0.9`.
- **Vestigial:** `Env.visionRange` and `halfAngle` (14/20/26 and 0.72/1.0) are set at `Game.ts:444-445` but never read.

### 2.4 AI at night
- **Reaction time:**
  - Each second the enemy's reaction is `def.react × (env.night ? def.nightReact : 1)`, with `night` = 22:00-06:00 (`Enemy.ts:1090`).
  - `nightReact` is the preset `nightReactionTimeFactor`: 1.5 for scrapper, scav, brute, contractor, wolf, bloater, giant and operator; 1 for drone and stormling.
  - Melee combat uses a fixed 0.2 s wait (`Enemy.ts:1172`), so the giant is unaffected.
  - Turrets do the same (`Turrets.ts:672`).
- **Sight angle (`searchNow`, `Enemy.ts:955-962`):**
  - `angle = fov × (nf + (1−nf)·nightVision)`.
  - `nf` is the blended `todPost.angle` (`World.ts:1331`), and `nightVision` defaults to 0.5.
  - Example: Sunny night, scav: 100° × (0.4 + 0.6×0.5) = 70°. Stormling `nightVision 1` is never narrowed.
  - The factor is applied only in Patrol searches (`Enemy.ts:1230` passes `night=true`). Alert searches use sight ×1.25 and Combat re-acquire ×1.5, with no angle factor (`AI` at `Enemy.ts:391`).
  - Because `nf` is the live weather/time factor, it also narrows AI cones by day in Cloudy or Rain (0.8) and in storms.
- **Sight distance:** NOT scaled by time or weather. `enemyVisionMul = 1` (`Game.ts:444-451`).
- **Night-only spawn:** the drone (section 3).

## 3. Enemy kinds (Ground Zero)

### 3.1 Shared rules
- **Base movement:** walk 4, run 6 × `moveSpeedFactor` (`Enemy.ts:157`, `Roster.ts:384`).
- **Difficulty:** per-spawn HP = `hp × enemyHealth`. Reaction, burst and gap are scaled by ruleset (default `survival`, all ×1.0, `data.ts`).
- **Shot damage per bullet** = `Damage × preset damageMultiplier / ShotCount` (`Enemy.ts:752-776`).
- **Range** = `(BulletDistance × gunDistanceMultiplier + 0.4) × 1.05`. Half damage past half of the pre-1.05 distance.
- **Bullet speed** = `BulletSpeed × bulletSpeedMultiplier`.
- **Team rule:** `Team.IsEnemy` (`Enemy.ts:446`): team 5 is hostile to nobody, team 7 to everyone, otherwise hostile if the teams differ. AI targets other hostile AI as well as the player.
- **Per-gun numbers** come from `gz/gz_gunfeel.json`, which overrides `data.ts`.
- **EXP on kill:** drone 250, bloater 100, stormling 100 (`data.ts:1116`); giant 100 and operator 150 via `XP[kind] = p.exp` (`Roster.ts:1226`).

### 3.2 Spawner rows (authoritative: `levels/ground_zero.json` subScenes[0].spawners)

| Root | Preset | Kind | Chance | Count | Points | minDist | Delay | Condition |
|---|---|---|---|---|---|---|---|---|
| `EnemySpawner_UltraMan` | `Melee_UltraMan` | giant | 1 | [1,1] | 2 | 25 | 0 s | none, always |
| `EnemySpawner_MoveUsec` | `USEC_HiddenWareHouse` (weight 0.7) | operator | 0.3 | [1,2] | 13 | 25 | 3 s | none |
| `MushroomGroups` | `Mushroom` | bloater | 1 | [3,5] per group | 6/8/8/7 | 10 | 5 s | weathers `["Rainy","Snow"]` |
| `EnemySpawner_StormCreature` | `StormCreature` | stormling | 1 | [8,12] | 38 | 20 | 3 s | weathers `["Stormy_I","Stormy_II"]` |
| `EnemySpawner_Spider_Night` | `Spider_Rifle` | drone | 1 | [4,6] | 43 | 25 | none | timeOfDay from 22 to 5, use=true |

- `MushroomGroups` is a selector with `pick [1,2]` of 4 groups. Each group has a leader (`hasLeader: true`, `firstIsLeader`), with 3-5 bloaters from the group's own point list. The points are in the level JSON.
- **Condition tags:** `LevelMap.ts:892-897` sets `when` to `storm` if all weathers start with `Stormy`, `rain` if weathers include `Rainy`, else `night` if timeOfDay.use and from ≥ 18 or to ≤ 6.
- **Trigger in-game** (`World.ts:624`, `:1208-1210`):
  - `night` runs once when `env.night` (22:00-06:00) first holds, or at raid start if it is already night.
  - `rain` runs once on the first frame with `env.rain`.
  - `storm` runs once on the first frame with `env.storm` (Stage I or II).
  - Each condition spawns at most once per raid world (`conditionSpawned` / `nightSpawned`).
- **Point selection:** `runSpawners` (`World.ts:896-940`) rolls `prob`, then `count`, then random points with `minDist < d < maxDist`, never reusing a point.
  - Roots with a delay or trigger wait in `SpawnRoots` (`SpawnRoots.ts:52-57`).
  - The delay is raid seconds, and characters spawn 0.1 s apart (`spawnTimeSpace`).
  - The night root uses no delay because `delay` is dropped when `timeOfDay.use`.
- **Operator note:** only one preset appears in the decoded list. If a null preset was dropped at decode, the real in-game odds may be lower than the 30% chance.
- **Patrol:** each spawned enemy patrols between its point and up to two other points of the same spawner within 28 m. If there is no other point it gets two invented offsets (`World.ts:922-926`).

### 3.3 Giant (`EnemyPreset_Melee_UltraMan`, kind `giant`)
Source: `gz/gz_presets.json` pathId 76513, built by `defFromPreset` (`Roster.ts:387`).
- **Team and role:** team 7 ("all"), boss, `showName`, health bar, EXP 100.
- **Stats:** HP 400.
- **Movement:** `moveSpeedFactor 1.3`, so walk 5.2 and run 7.8. `canDash false`.
- **Sight and timing:** sight 13 m / 100°, react 0.2, nightVision 0.5, hearing 1, forget 8, trace 1.0-1.0.
- **Combat ranges:** patrolRange 8, combatMoveRange 8.
- **Turn speeds:** 600 patrol / 1200 combat.
- **Melee weapon:** `battle_axe` from the drop table (`gz/gz_items.json`).
  - Damage 40 × preset MeleeDamageMultiplier 1.0, attack rate 1.2/s (interval 0.83 s), range 1.5 m (+0.05 hit reach), crit 0.2 × 1.4, bleed 0.35, armor pen 1, deal time 0.12 s.
  - `setStats MeleeDamageMultiplier 1.2` is overwritten by the preset's 1.0 (`Roster.ts` header).
- **Resists and factors:** `buffResist ['Pain']`, element factors all 1.0, `aiCombatFactor 2.0` (AI-vs-AI damage).
- **Body:** model `0_CharacterModel_Custom_Enemy_Large`, scale 1.3, receiver radius 0.7 (`ENEMY_HIT_RADIUS`, `Enemy.ts:277`), body radius 0.5.
- **AI:** `AIController_UltraMan` = Patrol_Scare / Alert_Normal / Combat_Melee / Combat_Attack_Melee (archetype `brawler`).
  - Patrol (`Roster.ts:903-914`): it stands still and never searches or alerts (`noticed=false`, `alert=false`). It targets an attacker only when hit by a character for ≥ 2 damage within 0.25 s (`Patrol_Scare`: `hurtTime 0.25`, `hurtDamage 2`).
  - Combat (`Enemy.ts:1672-1760`): wait 0.2 s, run to within 1.5 m (trace times out at 8 s), wait 0.1 s, alert FX 0.2 s, swing, wait 0.25 s, then gap 0.2 s (`shootTimeSpace [0.2,0.2]`). It forgets the target if blocked or farther than 24 m for 7 s (`AI.meleeTrackRange 24`, `meleeForget 7`).
- **Loot:**
  - `battle_axe` 100% (durability 0.2-0.6) and `feather` ×3-6 at 100%.
  - `cold_core` ×2-5 at 30%, a healing item at 15%, and miscellaneous items ×1-2 at 10%.
  - Bullets: quality-1 AR_S, count 0.5-1 of 30.

### 3.4 Operator (`EnemyPreset_USEC_HiddenWareHouse`, kind `operator`)
- **Team and role:** team 3 ("usec"), the same team as boss and contractor. Not a boss. EXP 150.
- **Stats:** HP 60, `damageMultiplier 1`, walk 4 / run 6 (`moveSpeedFactor 1`).
- **Sight and timing:** sight 16 m / 100°, react 0.45, nightReact 1.5, nightVision 0.5, shootDelay 0.25, hearing 1.
- **Shooting:** `shootCanMove true`, burst 0.25-0.55 s, gap 0.8-2.2 s.
  - `bulletSpeedMultiplier 0.8`, `gunDistanceMultiplier 1.3`, scatter 0.6 (running ×3, off-screen ×3), `aiCombatFactor 1.5`.
- **Movement and traits:** patrolRange 25, combatMoveRange 8, combatMoveTime 1-3 s, trace chance 0.1-0.8, forget 8, `canDash false`, `canTalk true`.
- **Turn speeds:** 500 patrol / 1200 combat.
- **AI:** `AIControllerTemplate`, archetype `gun` (Patrol_Normal / Alert_Normal / Combat_Normal / Combat_Attack_Nomral).
- **Weapon pool (weights):** `mp7` .2759, `m4a1` .1724, `aug_a1` .1724, `mp155` .1379, `ump45` .1379, `vector` .0690, `mdr556` .0345. Gun durability 0.4-0.6, integrity 0.5-0.95. Ammo is quality-2 AR, count 0.5-1 of 30.
- **Body armor:** always rolled, from `armor_l2` (.80) down to `armor_lv5_2`.
- **Gear rolls:** helmet 30%, backpack 80%.
- **Loot:** 30% `flaming_core`, 50% `feather` ×1-3, 30% grenades ×1-2, 100% `blackdogtag` (dog tag), cash 100-400 (`hasCashChance 1.0`), plus miscellaneous and healing rolls.
- **Skills:** none. Model `0_CharacterModel_Custom_Enemy`, receiver radius 0.5, body radius 0.3.

### 3.5 Bloater (`EnemyPreset_Mushroom`, hand-built in `ENEMY_DEFS`, `Enemy.ts:221-228`)
- **Team and role:** team 8 ("wolf"), same team as wolf and stormling. HP 80.
- **Speed:** walk 4 / run 6. EXP 100.
- **Sight and timing:** sight 19 m / 100°, react 0.4, nightReact 1.5, shootDelay 0.2, forget 10.
- **Shooting:** `shootCanMove false`, burst 0.2-0.5 s, gap 1.0-1.5 s.
- **Traits:** trace chance 0.25, `canTalk false`, `aiCombatFactor 1.5`, no armor, no dash, `fire 1.35`, `poison 0.6`.
- **Turn speeds:** 1000 patrol / 1200 combat.
- **Weapon:** `RING_GUN` (`Enemy.ts:153`, item `egun_magic_ring_mushroom`; world poison ring):
  - 8 pellets in a full 360° ring (the ring angle is reduced by `angle/n`, giving 45° steps, then shifted half a step because the count is even).
  - Rate 3/s, magazine 80, reload 2.3 s, crit 0, poison element.
  - Pellet damage = 10 × 12 / 8 = **15**.
  - Pellet speed 14 × 0.75 = 10.5 m/s. Range (24×1.2 + 0.4) × 1.05 = 30.66 m.
  - Pellet pen 1, armorBreak 0.65, bleed 0.06 (`World.ts:1849`).
  - The poison buff 1061 would be 1 dmg per 1.5 s per layer for 15 s, max 10 layers. The comment at `Enemy.ts:148-152` says the buff never procs (`buffChance 0`).
- **Loot:** `mushroom` 100%, no gun drop. Bullets are quality-1 "Enemy" bullet.
- **Our art:** spore mesh `ringBulletGeo` icosahedron r 0.17, colour `#b8f060` (`World.ts:566-568`). Muzzle flash `#b8f060`.
- **Spawn size note:** leader group spawn (section 3.2). Fallback non-decoded spawn is 2 groups of 3-5 (`World.ts:1209`).

### 3.6 Stormling (`EnemyPreset_StormCreature`, `Enemy.ts:229-237`)
- **Team and role:** team 8, HP 150, no health bar. EXP 100.
- **Speed:** `moveSpeedFactor 1.6`, walk 6.4 / run 9.6.
- **Sight and timing:** sight 18 m, react 0.1, nightReact 1, nightVision 1, shootDelay 0.25.
- **Traits:** trace chance 1.0, forget 8, `canTalk false`, `aiCombatFactor 1.5`, scale 1.05.
- **Shooting:** burst 0.4-1.0 s, gap 1.1-1.8 s, `shootCanMove false`, `combatMoveTime [0,0]`, `canDash true` with cooldown 2-4 s.
- **Element factors:** physics 0.8, fire 1.5, space 1.35.
- **Weapon `egun_storm`** (`egun_ar_storm_no_graphic`, `gz_gunfeel.json`):
  - Damage 10 × 1.1 = 11 per bullet, space element.
  - ShootSpeed 9/s, BurstCount 3, CritRate 0.1, crit factor 1.6.
  - BulletSpeed 40 × 1.25 = 50 m/s. Range (14 + 0.4) × 1.05 = 15.12 m.
  - Its Space buff 1117 ("Shatter") would be 1 real dmg per 1 s per layer for 5 s, max 12 layers. `buffChanceStat 0`, so it never procs.
- **Loot:** `space_crystal` 100%, `weapon_parts_polluted` 20%. Bullets quality 1-5 "Enemy".
- **Look:** purple humanoid `#6a4a8a / #3a2a5a / #2a1a3a`, hat `#8a6aff` (our art).

### 3.7 Drone (Spider Drone, `EnemyPreset_Spider_Rifle`, `Enemy.ts:213-221`)
- **Team and role:** team 6 ("lab"), HP 75. EXP 250.
- **Speed:** walk 4 / run 6, `canDash false`. The `dashSpeed 8` setting is inert without `canDash`.
- **Sight and timing:** sight 17 m / 100°, react 0.3, nightReact 1.0, shootDelay 0.2.
- **Shooting:** `shootCanMove true`, burst 0.5-1.0 s, gap 2.0-3.0 s.
- **Traits:** trace chance 1.0, `damageMultiplier 1.2`, `aiCombatFactor 1.5`, armor 4 body + 4 head (setStats), `canTalk true`.
- **Resists:** buffResist Poison and Bleeding, poison factor 0, electricity factor 2.0. Patrol turn speed 300.
- **Weapon `egun_spider`** (`enemy_gun_spider_rifle`):
  - Damage 10 × 1.2 = 12 per bullet.
  - ShootSpeed 12/s, BurstCount 3, BulletSpeed 25, BulletDistance 27, ShotCount 1.
  - Range (27 + 0.4) × 1.05 = 28.77 m.
  - CritRate 0.1, crit factor 1.6. No element buff.
- **Special:** hackable (`AISpecialAttachment_Hackable`: requireLevel 2, range 2.5 m, needVision). The takeover mechanic is in `Takeover.ts`.
- **Loot:** `compute_core` 100%, electrical junk ×1-3 at 50%. Bullets: none.
- **Look:** creature rig `look: 'drone'` (our art).

## 4. Map screen (M key)

There is no corner minimap. M opens the full-screen "MiniMapView" tab: `MapUI` (`src/ui/MapUI.ts`) opened at `Game.ts:1520-1525`.
- **Base image:** a one-time 1024-wide top-down orthographic render of the static map geometry (`Game.ts:1683-1740`), cached per map id.
  - Camera is 120 m above the map centre, looking down.
  - Noon lighting: hemisphere 1.5 (1.6 indoors), sun 1.6 (0 indoors). Background `#1c2228`. No fog. All non-map objects hidden.
- **Layout:** `fit = min(W*0.84/boundsW, H*0.72/boundsH)`. Zoom 1-4 (`MapUI.ts:118-125`).
  - Wheel steps are ×1.15 per tick and zoom around the cursor.
  - Drag pans. The slider maps y to zoom: handle slide area 65 below the slider top, 700 tall, bottom = 1, top = 4.
- **Ground Zero data:** bounds in source coordinates `minX −153.203, maxX 242.891, minZ −102.532, maxZ 240.82`. The minimap config has `combinedSize 600` and a scene size of 560. Our frame is `x = worldX − 329`, `z = −(worldZ − 241)`.
- **Shown:**
  - Region names: Bunker Hatch, Wood Trail, Road Camp, Northwest Camp, Middle Hill, River House, Cave Mouth, North Hill (`levels.ts:105-106`). Style: weight 800, size `max(11, 30u)`, fill `#f4f1e6`, 4 px stroke `rgba(0,0,0,0.65)`.
  - This raid's active exits: green ring `#46e08c` (r 10, 3 px) plus an inner dot (r 4) and a label chip (`MapUI.ts:257-264`, `World.ts:845`). The hatch is labelled "Bunker Entry".
  - Cave teleporters: violet `#b48cff` ring (r 8) and dot (r 3).
  - Quest points: white ring and `rgba(255,255,255,0.251)` fill for areas, a teardrop pin in the quest colour with a "!" mark, and a label chip.
  - Corpse: blue dot `#7fd0ff` (r 7).
  - Player: yellow `#ffd23f` triangle with black outline, rotated by `−facing + π`.
  - User markers: right-click places or removes. Icons are pin / star / target / skull / box / exit. Colours are `#ffffff #f85566 #ff9e3a #cced98 #61caf9`. Saved per map in `profile.mapMarkers`.
  - Overlay chrome: map name (115u), region of the nearest region point, compass, zoom slider, and a marker toolbox.
- **Not shown:** enemies, loot, or the fog-of-war cone. NOT FOUND for any enemy markers.
- **Label chip style:** `rgba(0,0,0,0.306)` background, text 24u white.
- **Background styling:** full-screen `#041522` translucent blur plus top and bottom black gradient shades (`ui/inventory.css:276-288`).