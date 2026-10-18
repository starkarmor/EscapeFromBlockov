Findings from reading the source, with the tuning numbers copied from the code.

## 1. DODGE ROLL

**It is a keyframed skeletal clip.** The clip is `DodgeRoll_Forward`, from the source game's `0_CharacterModel_Custom_Template`. It is baked into `src/game/gz/gz_charclips.json` (`clips.DodgeRoll_Forward`). The real clip is 0.8 s (`len 0.8`, non-looping), but it is time-stretched to the 0.5 s dash.

**Timing (`src/entities/Player.ts`)**
- Constants: `DASH = { time: 0.5, cooldown: 0.5, cost: 10 (stamina), speed: 10, triggerLock: 0.6 }` (`Player.ts:224`).
- The dash is invulnerable (`dashing`), with no knockback.
- The clip phase is `1 - dodgeT/DASH.time` (`Player.ts:1139`), so it runs linearly 0 to 1 over the 0.5 s dash.
- Each frame's phase is mapped to `u = phase * 23`, then slerped between neighbouring samples (`Beaver.ts` `add()`).
- The clip has 24 samples (`samples: 24`), so sample `i` plays at `t = i/23 * 0.5 s`, about 21.7 ms per sample.

**Blending: none.**
- `Beaver.ts:217`: `if (a.dodge > 0) this.add('DodgeRoll_Forward', a.dodge, 1); else { idle + 4 walk dirs }`.
- Idle and walk are removed completely while dodging, then return instantly when the dash ends.
- Melee and the gun-hold overlay are both skipped while `dodge > 0` (`Beaver.ts:238` and `Beaver.ts:245`).
- The last frame is close to the bind pose, so the exit is seamless.

**Whole-body motion.** There is no extra procedural rotation on the beaver rig. Only the fallback blocky rig (`rig.anim` absent) uses `rig.group.rotation.x = (1 - dodgeT/0.5) * 2π` (`Player.ts:1141`). The player group's yaw snaps to the dash direction at dash start (`Player.ts:956`).

**Per-bone curves.** Format: `rot` lists 25 bones, `rf[frame]` is 100 floats (25 quaternions xyzw in `rot` order), `pf[frame]` is 75 floats (25 positions). Values below are from my own decode of the JSON, not copied from comments.

- **Root (bone 2)** does the somersault, a forward flip.
  - Pitch about model X, absolute degrees (bind is 90°): f0 90, f1 90, f2 91, f3 106, f4 135, f5 173, f6 220, f7 275, f8 329, f9 377, f10 419, f11 446, f12 450.
  - That is +360° total, spread over f2 to f12 (t = 0.043 to 0.26 s). It then holds the bind pose (450° is the same as 90°) for f12 to f23.
  - Root position is in Armature space, which is rotated −90° about X, so up = the z value and forward = −(the y value). The listed numbers are (y, z) in Armature space.
  - Samples as (y, z): f3 (0.101, 0.181); f4 (0.236, 0.425); f5 (0.317, 0.569); f6 (0.26, 0.578); f7 (0.101, 0.541); f8 (−0.05, 0.353); f9 (−0.081, 0.138); f10 (−0.046, 0.032); f11 (−0.008, 0.001); f12 onward (0, 0).
  - Read as a hop, the body lifts about 0.58 m, peaking at f6 (t ≈ 0.13 s). It is airborne from about f2 to f11 (0.04 to 0.24 s) and lands at about f11. It is about 0.3 m off in the model's rear/forward axis at the peak.
- **Pelvis (3)** pitch: bind −11°, then −5 at f1, +5 at f2, +10 at f3 to f4, a slow fall to −11° by f16, then it holds.
  - Pelvis y dips from 0.151 to 0.112 around f12 (t ≈ 0.26 s).
- **Spine.001 (15)** pitch: 4° at f0, 16 at f1, 36 at f2, peak 45 at f3 to f4, then it decays to about 3° by f18 to f23. It also has a small yaw/roll of a few degrees.
- **Spine.002 (16)** pitch: 11° at f0, 22, 43, peak 52 at f3, then it decays to 9 to 11° by f18.
- **Spine.003, Spine.004, Tail, Tail.001, Thigh.L/R, HeadTip** are unchanged (bind).
- **Head (30)** pitch: −10° at f0, 41 at f1, peak 72 at f2 to f3 (chin tuck), about 70 to 54 through f8, 34 at f10, −6 at f11, −38 at f12 (the over-rotate), then it recovers 7 at f15, 16 at f16 and drifts to −13 at f23.
  - Head position shifts too: (0, 0.2, −0.017) at f0 goes to (−0.022, −0.021, 0.147) at f3, then back to about (−0.003, 0.208, 0.001) at f23.
- **Arms:** both arms are flung in a tuck-and-spin.
  - UpperArm R/L rotate about 135 to 165° from bind during f3 to f12, then ease back to about 16°.
  - Hand R/L rotate about 150 to 176° from bind while rolling, then settle to 65 to 88°.
  - Elbow/ForeArm bend about 25 to 55° (sign flips with phase).
  - Foot.L/R rotate 21° at f3, 18° at f6, about 12° at f9 and about 5° at f12, then back to bind. The feet also shift slightly: foot z goes from −0.085 to about −0.124 at f3 and returns to −0.085 by f18 (0.8 s clip) / f23.
- Bones are written by a hemisphere-aligned weighted sum of quaternions, then normalized (`Beaver.ts:add` and `update`).

**Translation during the dash.**
- Velocity is `DASH.speed * dashCurve(t/0.5)` along the locked direction (`Player.ts:993-996`).
- `dashCurve` is a Hermite curve over `[time, value, inSlope, outSlope]`: `[-0.0012, 0.6136, 4.267, 4.267], [0.1927, 1, 0, 0], [0.7638, 0.7851, -0.917, -0.917], [1, 0.546, -0.812, -0.812]`.
- At dash end there is one frame at run speed.
- A dust puff is emitted every frame while dodging: `burst(x, 0.15, z, '#9a8a6a', 1, 1.2)` (`World.ts:1435`).

**Enemies that dash.** They do not play the roll clip. `Enemy.ts:2184` always passes `dodge: 0` to `anim.update`. They only get the same 0.5 s speed-curve slide (`Enemy.ts:2121-2133`, using `def.dashSpeed ?? 10`), invulnerable, with facing snapped unless `dashCanControl`. Per-preset dash intervals (seconds between dashes):
- Wolf: 1 to 1.2.
- Stormling: 2 to 4.
- Eagle boss: 4 to 7.
- Spider: `dashSpeed 8`, `dashCanControl true`.

## 2. BLOOD AND HIT FX

**Particle pool (`World.ts:569, 668-672`).**
- 100 cubes of `BoxGeometry(0.13, 0.13, 0.13)`, each with its own unlit `MeshBasicMaterial`.
- Shared by blood, sparks, shells and dust. If the pool is exhausted, extra particles are dropped.

```ts
private burst(x, y, z, color, n, speed = 4): void {
  let spawned = 0;
  for (const q of this.particles) {
    if (q.life > 0) continue;
    q.life = 0.3 + this.rand() * 0.3;
    q.vx = (this.rand() - 0.5) * speed;
    q.vy = this.rand() * speed * 0.8 + 1;
    q.vz = (this.rand() - 0.5) * speed;
    q.mesh.position.set(x, y, z);
    (q.mesh.material as THREE.MeshBasicMaterial).color.set(color);
    q.mesh.visible = true;
    if (++spawned >= n) break;
  }
}
// updateParticles: q.vy -= 14*dt; pos += v*dt; y = max(0.05, y+vy*dt); no fade, no shrink, no bounce; hidden at life<=0
```

**Hit and kill particles on enemies (`World.ts:2210-2219`).**

| Case | Count | Speed arg | Colour |
|---|---|---|---|
| Non-kill | 6 | 4 | `#b0161b` |
| Crit | 10 | 4 | `#b0161b` |
| Kill | 26 | 6 | `#b0161b` |
| Enemy hit by another AI (`byPlayer` false) | 6 or 26 | same | `#b0161b` |

- Origin is the hit point x/z at `y = BODY_FX_Y = 1.2 * RIG_SCALE = 0.615 m` (`body.ts:25`).
- Particle life is 0.3 to 0.6 s.
- Horizontal velocity is ±speed/2 on x and z, so ±2 for speed 4 and ±3 for speed 6.
- Vertical velocity is `1 + rand * 0.8 * speed`, so 1 to 4.2 (speed 4) or 1 to 5.8 (speed 6).
- Gravity is 14 m/s². The floor clamp is y 0.05. Horizontal velocity is never damped.

**Player hit (`World.ts:2732-2734`, bullet).** 5 particles in `#c8392f` at speed 4, at `BODY_FX_Y`. Also one decal of size 0.7 with ±0.5 m jitter around the player. A melee hit on the player (`World.ts:1899`) bursts the same 5 particles but spawns no decal.

**Other impact bursts**
- Ground impact: `#9a8a6a`, 2 particles, speed 2.
- Wall impact: `#cfc9b8`, 3 particles, speed 3.
- Block/bullet-block: `#ffe08a`, 4 particles, speed 3, at y 1.2.
- Robot hit: `#ffd27a`, 4 particles, at y 1.0.
- Breakable chip: `#9c3b2a`, 2 particles, speed 3, at y 0.8.
- Muzzle burst: `#ffd36b`, 2 particles, speed 2.
- Muzzle flash: `#ffe08a`, 2 particles, speed 1.5.
- Explosion: `#ffb347` ×28 at speed 9, plus `#555555` ×18 at speed 6.

**Ground decals (`World.ts:709-716, 2955-2972`).**

```ts
const decalGeo = new THREE.CircleGeometry(0.45, 8);   // octagon, radius 0.45 m
for (i<40) mesh = Mesh(decalGeo, MeshBasicMaterial({color:'#5a1410', transparent:true, opacity:0, depthWrite:false}));
  m.rotation.x = -Math.PI/2; m.visible=false;
private decal(x, z, size) {
  const d = this.decals[this.decalIdx]; this.decalIdx = (this.decalIdx+1) % this.decals.length;   // ring buffer, max 40
  d.life = 25;
  d.mesh.position.set(x, 0.05, z);
  d.mesh.scale.setScalar(size * (0.7 + this.rand() * 0.6));
  d.mesh.visible = true;
}
updateDecals: life -= dt; opacity = Math.min(0.75, life/5); hide at life<=0
```

- Opacity holds at 0.75 until 3.75 s remain, then fades linearly to 0 (total life 25 s).
- Resulting diameter is about `0.9 * size * (0.7 to 1.3)` m.
- On an enemy hit by the player: 1 decal at enemy position ±0.3 m, size 0.8 (1.6 on kill).
- On kill: 6 more decals at ±1.2 m around the body, size 0.7 to 1.8. That is 7 decals per kill, and the 40-slot ring buffer overwrites the oldest.
- No decal appears when an enemy is hit by another AI. There are no persistent corpse pools beyond these.

**Model flash (`World.ts:344-345, 2837-2853`).**
- Enemy hit: every mesh in the model gets its material replaced by an unlit `MeshBasicMaterial` white `#ffffff` for 0.125 s (`FLASH_HIT`). It is skipped on the killing blow.
- Player hurt: the same swap with orange `#ffb347` for 0.125 s (`FLASH_HURT`, `World.ts:2175`).
- Prop hits also use the orange flash (`World.ts:3677`).
- There is also an additive emissive red tint. On damage `flash` is set to 1 (`Enemy.ts:894`, `Player.ts:866`), decays at `dt*8`, and is applied as `emissive.setRGB(a, a*0.1, a*0.1)` via `flashCharacter()`. The multiplier `a` is 0.7 for enemies and 0.6 for the player (`Enemy.ts:2186-2187`, `Player.ts:1145-1146`).

**Death pose.**
- Enemy (`Enemy.ts:1068-1072`): `deathT += dt*3` to 1, so it takes 0.33 s. `rig.group.rotation.x = -deathT * π/2` (falls over to −90° pitch) and `position.y = deathT * 0.3`.
- Player (`World.ts:1286-1290`): the same fall, 1.5 s before the dead state is set.

**Damage numbers (`WorldUI.ts:42-47, 178-195, 244-257`; `duckov.css:353-355`).**
- Text is `v.toFixed(1)`, or a rounded integer at 1000 and above.
- CSS: bold 38 px (× `--u`), white `#fff`, with a 2 px `#222` outline in 4 directions plus `0 3px 4px rgba(0,0,0,.6)`. Crits add a white lightning-bolt glyph before the number (a `clip-path` polygon, 0.6 em square).
- Spawn is 2 m above the hit: `y = BODY_FX_Y + 2`.
- Motion: initial speed 6 m/s, random angle ±10° and random azimuth, gravity −10, lifetime 0.9 s.
- Scale starts at 1.869 and eases to 1.0 over the first 16.16% of life; crits are ×1.2.
- It stays opaque for the first 50% of life, then fades linearly to 0.
- The player's numbers (`.me`) and DoT ticks (`.tick`) use the same style. I found no separate CSS rule for `.me` or `.tick`.

**Screen effects.**
- Hurt vignette (`Hud.ts:263-312`, drawn by `src/systems/HurtPost.ts`): colour (0.40566, 0.04401, 0.04401), intensity 0.35, smoothness 0.6, multiply-blended, not rounded. Weight is set (not added) to 0.5 above 50% HP, or 1.0 at or below 50% HP, and only when the damage is at least 1.5. It decays at `4 * dt`.
- HP pill pop: `hpflash` scales 1.06 to 1 over 0.25 s.
- HP bar follow-fill: 0.35 s. The healthbar punch lasts 0.25 s.
- Hit marker: 0.833 s on a hit, 1.083 s on a kill.
- Camera shake on firing: 0.07 amplitude, opposite the muzzle direction.
- Sound-ping markers at a ring 400 px from screen centre, 1.5 s life.

## 3. GUN HOLD POSE

**Which hand.** Only the RIGHT hand carries the gun. The left arm just plays the idle/walk clip with no two-hand grip. The weapon mesh is a single box.

**Aim pose.** `MagicBlend_Gun` overlays `Armature_Pose_Aim` on the right-arm chain. It is applied unblended and instantly in `Beaver.ts:245-248`, overwriting these bones' local quaternions and positions from `d.aim` / `d.aimPos` (`gz_charclips.json`):

| Bone | Local quaternion (xyzw) | Local position |
|---|---|---|
| UpperArm.R | (−0.144, −0.759, −0.261, 0.580) | (0.295, −0.305, −0.083) |
| Elbow.R | (−0.025, −0.057, −0.044, 0.997) | bind |
| ForeArm.R | (0.025, 0.057, 0.044, 0.997) | bind |
| Hand.R | (−0.291, −0.349, −0.484, 0.748) | (0.286, 0.031, 0.114) |
| Hand.Soket.R | identity | zero |

- The spine chain (Spine.001 to 004), Pelvis and Root are re-set to their bind quaternions and positions. The bind values include the small forward pitches: Pelvis −11°, Spine.001 4°, Spine.002 11°, Spine.003 1°, Spine.004 4°.
- Aim switches on when a non-melee, non-"none" weapon is active (`Player.ts:1135`, `gun = active !== 'melee' && active !== 'none'`). It is skipped during the roll.
- The overlay is not blended in or out in `BoneAnim`; there is no transition time.

**Hand socket positions (`gz_holdpose.json`, model space: x right, y up, z forward, metres from the feet).**
- Player and human, aim pose (`rightHand`): **(0.2904, 0.5244, 0.2347)**.
- Throw pose (`rightHandNormal`): (0.2594, 0.5491, 0.2883).
- Run pose (`rightHandRun`): (0.346, 0.7172, 0.0571).
- Head is at y 0.9515. Model top is 1.107 m.
- Bloater: aim (0.2614, 0.472, 0.2112).
- Boss: (0.2799, 0.3656, 0.1932).
- Stormling: (0, 0.8515, 0.334).
- Wolf: (0.0001, 0.7912, 0.6929).
- Drone: (0, 0.6533, 0).
- Aim plane is 0.5 m above the feet. Capsule radius is 0.3 and height 1.0.

**Gun-to-run hand blend (`body.ts`, `GunPose`).**
- Moves to the run socket when MoveSpeed exceeds 1.5 (`enterRun`) and back below 1.49.
- Blend time is 0.2 s on a Hermite curve: aim blend `[0,0,0,0] → [1,1,0,0]`; run blend `[0,0,2,2] → [1,1,0,0]`.
- A locomotion-offset additive of 0.2 is applied (`runAdditive`), sampled over a 24-sample walk cycle (`handDelta`).
- This blend only drives the muzzle and bullet origin. The drawn gun uses the live bone position of `Hand.Soket.R`.

**Gun mesh placement (`Beaver.ts:98-104, 252-259`; `Character.ts:123-129`).**
- Mesh: a box of 0.1 × 0.16 × 0.6 rig units, times `RIG_SCALE = 1.107/2.16 = 0.5125`. That is 0.051 × 0.082 m cross-section.
- The z scale is set to `len / 0.6`, where `len` is the muzzle forward offset from the data (`setWeaponReach`).
- The holder sits at `hand.xyz + (0, 0, len/2)`, so the rear of the box is at the hand and the front is `len` metres ahead.
- It always points along the character's facing (+z). It is NOT pitched or yawed separately to the aim, because the body turns toward the aim.
- Colour is `ITEMS[id].color`, default `#444`. Enemies use `#3d3a36` for guns and `#b0b6bc` for melee (`Enemy.ts:742`).
- Throwables use scale (1.4, 1.4, 0.5) and the item colour, default `#c4402f`.
- There is no separate geometry or pose per class. Pistols, rifles and shotguns share one pose and differ only by the muzzle offset, which sets the box length.

**Muzzle offsets (`gz_holdpose.json` `muzzle`, 123 entries, metres in the gun-agent frame sitting on the hand socket, `[x, y, z]`).**
- Pistols: Makarov/PM (0, 0.1692, 0.3078); TT33 (0, 0.1474, 0.3581).
- SMGs and smaller: MP5 (0, 0.1468, 0.4822); UZI (0, 0.1511, 0.2455).
- Rifles: AK47 Lv2 (0, 0.1328, 0.7171); M14 (0, 0.1511, 1.0092).
- Snipers: Mosin (0, 0.0856, 1.0354); Barrett-style `Sniper_Balett` (0, 0.1406, 1.122).
- Shotguns: MP155 (0, 0.1204, 0.9386) and Saiga12 (0, 0.152, 0.667).
- Bows: about (−0.038, −0.016, 0.048).
- Many enemy guns are (0, 0, 0).
- A weapon with no entry falls back to (0, 0, 0). `Player.ts:1175` ties mesh length to the muzzle z, or to `f.length/0.6` if there is no entry.
- Firearm `length` values in `data.ts` are tt33 0.5, pm 0.45, mp7 0.7, ak47 1.05, sks 1.1, toz66 1.0, mp155 1.05.

**Bullet spawn point (`body.ts:55-69`).** `muzzleWorld(kind, gunId, x, z, facing, aimYaw, scale, hand)`:
- Hand offset `h` is `GunPose.hand()` (blended aim or run socket). Muzzle offset `m` is from the table.
- `x = px + (h.x*cos(facing) + h.z*sin(facing))*s + (m.x*cos(aimYaw) + m.z*sin(aimYaw))*s`
- `z = pz + (-h.x*sin(facing) + h.z*cos(facing))*s + (-m.x*sin(aimYaw) + m.z*cos(aimYaw))*s`
- `y = (h.y + m.y) * s`
- The hand offset rotates with the body yaw. The muzzle offset rotates with the aim yaw.
- Bullet direction (`World.ts:1725-1731`): if the aim point is beyond the muzzle by more than 0.1 m and Moveability exceeds 0.5, the bullet is aimed muzzle-to-cursor. Otherwise it uses the aim yaw, level. Slope is `(AIM_PLANE_Y - muzzle.y) / flatDistance`, with `AIM_PLANE_Y = 0.5`.
- Fallback when no decoded muzzle is given: `MUZZLE = 0.8` m ahead of the shooter at y = 0.5244 (`Player.ts:234`, `World.ts:2136-2138`).
- Turret fallback: the barrel tip is `hitRadius + 0.6` out.
- Facing rule: the body only turns to the aim if the cursor is beyond `muzzleReach + 0.25` m, where `muzzleReach = hypot(h.x + m.x, h.z + m.z)`.

**Muzzle flash.** A point light, colour `#ffd27a` for the player, range 9, intensity `14 * (t/0.06)`, 0.06 s long, at the muzzle y + 0.1. Shell ejection: one particle, life 0.6 s, speed 2 to 3.5 to the right, vy 3, at y 1.2, colour `#d9a440`.

**Not found:** per-class (pistol, rifle, shotgun) arm-pose variants and a left-hand grip. Aim is blended instantly, so there is no gun raise or lower animation.

Key files, all under `/Users/joel/Desktop/Vibecoding/Games/EscapeFromBlockov/`:
- `src/entities/Beaver.ts`
- `src/entities/Player.ts`
- `src/entities/Enemy.ts`
- `src/entities/Character.ts`
- `src/game/World.ts`
- `src/game/body.ts`
- `src/systems/Hud.ts`
- `src/ui/WorldUI.ts`
- `src/ui/duckov.css`
- `src/game/gz/gz_charclips.json`
- `src/game/gz/gz_holdpose.json`