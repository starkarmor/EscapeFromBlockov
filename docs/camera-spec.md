# Camera spec: `src/systems/CameraRig.ts` (287 lines)

All paths are under `/Users/joel/Desktop/Vibecoding/Games/EscapeFromBlockov/`. Coordinates are Three.js world space: Y up, right-handed. The source game was Unity, so z is mirrored when data is imported (`CameraVolumes.ts:33`: `x - cx`, `-(z - cz)`). If your Roblox world uses these same x/y/z, every number below applies directly.

## 1. Position, look target and smoothing

**Constants** (`CameraRig.ts:14-27`)

| Constant | Value |
|---|---|
| Yaw | 30° (`:14`); stored as `armYaw = -30` (`:113`, Unity sign) |
| Pitch | 55° |
| Arm distance | 45 |
| FOV | 23.5 (vertical) |
| ADS FOV | 22.8 |
| `AIM_OFFSET` | 5 |
| `AIM_FACTOR` | 0.5 |
| `LERP_IDLE` | 12 |
| `LERP_FIRING` | 1.5 |
| `LERP_DRIFT` | 1 |
| `PLANE_Y` | 0.5 |
| `MID_SNAP` | 5 |

**Yaw direction.** `applyYaw` (`:143-150`) uses y = degToRad(-armYaw) = +30° and sets the ground basis:
- `right = (cos y, -sin y)` = (0.866, -0.5) in (x, z)
- `fwd = (-sin y, -cos y)` = (-0.5, -0.866). This is screen-up on the ground.

The camera sits at +X and +Z of the focus and looks toward -X, -Z. `viewToWorld` (`:36-38`) maps WASD through this basis: `x = ix·right.x − iz·fwd.x`, with ix = D−A and iz = S−W.

**Arm vector** (`setArm`, `:153-157`)
- `h = cos(pitch)·dist`
- `arm = (−fwd.x·h, sin(pitch)·dist, −fwd.z·h)`
- At the defaults, h = 25.81 and arm.y = 36.86.

**Camera pose** (`apply`, `:279-286`)
- `focus = target + right·offX + fwd·offZ`, where the player is `target = (x, 0, z)` taken from `w.viewPos(dt)`.
- `camera.position = (focus.x + arm.x, arm.y + 0.5, focus.z + arm.z)`. This is the Y-up arm plus 0.5 above the plane.
- `camera.lookAt(focus.x, 0.5, focus.z)` with the default up (0, 1, 0).
- There is no positional damping on the player: it is a hard follow. All smoothing is in `offX` and `offZ` (the look-ahead) and in the arm ease from volumes.

**Frame-rate dependence.** Every ease is explicit-Euler, `v += (goal − v)·min(1, dt·rate)`, not an exponential. It is frame-rate dependent. `dt` is clamped to [0, 0.05] s by `src/core/Loop.ts:30`. The scale is wall-clock dt, with no hit-stop.

**Lerp speed.** `lerpSpeed` drifts linearly at 1 per second (`:229-230`). The goal is 1.5 while `fireHeld()` and the UI is closed (`Game.ts:1649`), else 12. It starts at 12, so after firing it takes about 10.5 s to return to 12. It is not reset by `snapTo`.

**Focus and bias (the part that is easy to get wrong).** In `:241-260`:
1. The cursor ray is cast against the plane y = 0.5, from the pose that already includes the current offset but not the shake (`apply(null)` is called first).
2. It is cast at NDC (0,0) for `centre`, at NDC (0,+1) and (0,−1) for the top and bottom points, and at the cursor NDC for `mouse`.
3. `mid` is the average of the top and bottom plane points. `toMid = mid − centre` is clamped to length 5.
4. `bias = min(|mid − centre|, 5)`, and `midP = centre + clamped toMid`.
5. The mouse offset is `v = mouse − midP`, clamped to length `maxOff`.
6. The target offset is:
   - `tx = clamp(dot(v, right)·factor, ±maxOff)`
   - `tz = clamp(dot(v, fwd)·factor, ±maxOff) − bias`

So the focus is always pulled `bias` toward screen-down. I computed `bias` for the default camera: top 39.19, bottom 15.84, centre 25.81, so bias ≈ **1.700 m**. It is 1.596 at ADS FOV 22.8. It depends only on vertical FOV, pitch and distance, not on aspect.

At the screen centre the steady state is offZ ≈ −0.85 − 1.70 = −2.55. The cursor ray comes from the previous frame's pose, so all four plane points translate together and `v` is stable.

Per-axis hip maximum is 0.5 × 5 = 2.5 m. The ±maxOff clamp on the dot product only binds when ADS multiplies both the factor and maxOff.

**Blocked UI** (`:233-237`): `offX` and `offZ` decay to 0 at `min(1, dt·lerpSpeed)` and no ray is cast.

## 2. FOV and ADS

- `fov = lerp(23.5, 22.8, ads)` (`:218`). `updateProjectionMatrix` is called only when the change is greater than 1e-3.
- ADS never changes the arm distance. It changes FOV, `maxOff` and `factor`.
- `adsMul = gun.def.adsLook ?? 1.25` when there is no gun (`:223`).
  - `adsLook = ADS_AIM[id] ?? 1` (`src/game/data.ts:93`). Of the roughly 117 guns, 97 are 1 and the range is 1 to 3.68.
- `maxOff = lerp(sickMode ? 0 : 5, 5·adsMul, ads)` (`:225`).
  - `sickMode` is the DisableCameraOffset option, `options.ts:147`.
- `factor = lerp(0.5, 0.5·adsMul, ads)`. With no gun it is fixed at 0.5.
- `ads` source, with a gun: `Player.ads` (`Player.ts:897`) is stepped each frame by `+1/max(0.01, ADSTime)` while ADS is held, or by `−max(4, 1/ADSTime)` otherwise, clamped to 0..1.
- `ads` source, with no gun (`:215`): the camera ramps `adsValue` toward `adsInput` (0 or 1) at 10 per second.
- `adsInput = intent.ads && !action && !sprinting`.

## 3. Camera volumes (`src/systems/CameraVolumes.ts`)

**Data.** The data is `src/game/gz/gz_volumes.json`. The defaults are pitch 55, yaw −30, distance 45. Each volume has `go, x, z, global, priority, blend, weight, hide, sphere | box[3] + rotY, pitch|yaw|distance`, and each override may be null.

**Selection.** Volumes come from the level's main scene and its sub-scene. Volumes with `enabled` false, `active` false, a non-empty `inactive` list, or a name ending in `TopDownVolume` are dropped. The rest are sorted ascending by priority (`:24-37`).

**Blend** (`blendVolumes`, `:40-66`), starting from the defaults:
- For each volume in ascending priority order, skipped if `sick && hide`:
  - Global: `t = 1`.
  - Local: compute `d`, the distance from the player (x, z only) to the sphere, or to the box rotated by `rotY` (the local-space point is `lx = dx·c − dz·sn`, `lz = dx·sn + dz·c`). If `d² > blend²`, skip it. If `blend > 0`, `t = 1 − d²/blend²`. If `blend` is 0, then `t = 1` inside and the volume is skipped outside.
  - Then `t = clamp(t·weight, 0, 1)`, and for each non-null parameter `p += (volumeValue − p)·t`.

**Per-frame easing** (`update`, `:200-212`). Easing applies when the current values differ from the goal:
- `armPitch += (tp − armPitch)·min(1, 5dt)`
- `armYaw += (ty − armYaw)·min(1, 2dt)`
- `armDistance += (td − armDistance)·min(1, 2dt)`
- Each value snaps to its goal within 1e-3.

**Trigger.** The volume trigger is the player's position, not the camera or robot target. `World.viewPos` (`World.ts:2091-2094`) calls `CameraVolumes.use(map, player.x, player.z)` before returning the camera position.

**Map change.** When the map object changes, `generation` bumps and the arm resets to the defaults (`:193-199`). The reset happens inside the next `update`.

**Top-down toggle.** The Y key calls `CameraRig.toggleView()` (`World.ts:1248`). While it is on, the goal pitch is 80 and the goal distance is 53. Yaw still comes from the volumes.

**Example volume** (level10 `FarmVolume_MystRoom`): pitch 70, yaw −10, distance 33, a box with priority 9.

## 4. Shake (`CameraRig.ts:169-174, 265-274`; envelopes at `:51-67`)

**Impulses.** `addShake(amount, kind, dir)` stores an impulse `{x: dir.x/|dir|·amount, z: dir.z/|dir|·amount, t: 0}`. Up to 16 are kept; the oldest is dropped.

**Per frame**, for each impulse:
- The envelope is `k = t < dur ? sampleCurve(keys, t/dur) : 0`, sampled before `t += dt`, so the first frame shows t = 0.
- Add `im.x·k` and `im.z·k` to `shakeOff`.
- Remove the impulse once `t >= dur`.
- Displacement is `velocity × envelope`, in world metres, on the x/z plane only.

**How it is applied.** The shake is added to the camera position after `lookAt` (`:285`). It is a pure translation: the orientation is unchanged and the look target is not shifted. There is no rotation shake.

`sampleCurve` (`:70-84`) is a cubic Hermite, Unity AnimationCurve style: `(2s³−3s²+1)v0 + (s³−2s²+s)·out0·d + (−2s³+3s²)v1 + (s³−s²)·in1·d`, where d is the segment's time span, and it clamps outside the keys. Keys are `[time, value, inSlope, outSlope]`.

| Kind | dur | Keys |
|---|---|---|
| recoil | 0.5 | (0,0,15.929328,15.929328), (0.062777,1,0,0), (0.336861,−0.206638,0,0), (0.622401,0.038077,0.000338,0.000338), (1,0,0.062364,0.062364) |
| melee | 0.5 | (0,0,29.671616,29.671616), (0.033702,1,0,0), (0.261888,−0.571327,0,0), (0.368248,0.347639,0.000338,0.000338), (0.510468,−0.337255,0,0), (0.582382,0.090235,0,0), (0.675636,0,0,0), (1,0,0.062364,0.062364) |
| explosion | 1.0 | (0,−1.4,−7.9,−7.9), (0.27,0.78,23.4,23.4), (0.54,−0.12,22.6,22.6), (0.75,0.042,9.23,9.23), (0.9,−0.02,5.8,5.8), (0.95,−0.006,−3,−3), (1,0,0,0) |

**Callers** (all in `World.ts`):
- Gunshot (`:1785`): amount 0.07, kind recoil, dir `(−sin facing, −cos facing)`.
- Melee (`:1949`): amount 0.05, kind melee, dir `(cos f + 0.3·ux, −sin f + 0.3·uz)`, with (ux, uz) a random vector from a unit sphere.
- Explosion (`:2479`): amount `0.4·(o.shake ?? 1)`, kind explosion, dir `(dx/d, dz/d)` with (dx, dz) = blast − player. Fired only if d < 30.

## 5. Projection, near plane and cursor ray

- Camera: `PerspectiveCamera(23.5, 1, near 0.5, far 260)` at `Game.ts:85`.
- Aspect is `width/height`, set in `core/Renderer.ts:37`. FOV is vertical.
- The up vector is default Y up.
- The rig's own ray: `ray.setFromCamera(ndc)` intersected with `Plane(n=(0,1,0), const −0.5)`, i.e. y = 0.5 (`CameraRig.ts:128`).
  - If there is no intersection, the fallback is the target at y 0.5 (`:186`).
- The gameplay aim ray (`Game.ts:1343-1351`) uses the same plane: `aimPlane = Plane((0,1,0), −AIM_PLANE_Y)`, with `AIM_PLANE_Y = 0.5` (`gz_holdpose.json:4`, `body.ts:16`). It is cast at the same `aimNdc`.
  - A head-collider pull and the 45-ray height fan follow after that.
- Cursor NDC (`InputController.ts:70-76`): `ndc = (x/W·2−1, −(y/H)·2+1)`.
  - Mouse delta is scaled by `MouseSensitivity/10`.
  - `aimNdc = mouseNdc + recoil offset`: `(+rx·2/W, −ry·2/H)` (`Game.ts:1325`).
- Frame order in `Game.update`:
  1. `updateRecoil`, which sets `aimNdc` (`:1624`).
  2. `updateAim`, which casts from the camera pose left by the previous frame, including last frame's shake (`:1625`).
  3. `World.update`, with player movement and `viewPos` not yet called (`:1627`).
  4. `cameraRig.update(dt, w.viewPos(dt), {...})` (`:1646`).
- Inside `CameraRig.update` the order is:
  1. Volume or arm ease.
  2. `adsValue`, FOV, `maxOff`, `factor`.
  3. `lerpSpeed` drift.
  4. `target.set`.
  5. `apply(null)`, then the ray casts, then the `offX`/`offZ` lerp.
  6. Shake sum.
  7. `apply(shake)`.
  8. `focus.apply` (the scripted console VCam).

## 6. Snap

`snapTo(p)` (`:176-182`):
- It sets `offX = offZ = 0`, `target = (p.x, 0, p.z)`, and calls `apply(null)`. That places the camera directly on the target with no bias and no look-ahead.
- It calls `focus.reset()`.
- It does not reset `lerpSpeed`, `adsValue`, the arm values or the shake impulses.
- After the snap, the offset eases from 0 to the bias target at `dt·lerpSpeed`, so there is a short visible settle of about 1.7 to 2.5 m toward screen-down.

Callers:
- `Game.ts:738` on a new world set.
- `Game.ts:1067` on a same-map teleport.
- `Game.ts:1106` on a sub-scene change.
- `Game.ts:1813,1826` in the test setup.

A map change also resets the arm to 55 / −30 / 45 on the next `update`.

Not covered: the Takeover/robot camera, which `Takeover.viewPos` (`Takeover.ts:611`) lerps over `CAMERA_LERP` (cameraChangeTargetLerpTime) after a target change, and `CameraFocus.ts` (console VCam). `CAMERA_LERP` itself comes from a JSON file I did not open, so its value is NOT FOUND.

## Core update function (`CameraRig.ts:190-286`, comments trimmed)

```ts
update(dt: number, target: { x: number; z: number }, a: AimInput): void {
  if (this.volGen !== CameraVolumes.generation) {
    this.volGen = CameraVolumes.generation;
    this.armPitch = ARM_DEFAULT.pitch; this.armYaw = ARM_DEFAULT.yaw;
    this.armDistance = CAMERA_DISTANCE; this.applyYaw();
  }
  const armGoal = CameraVolumes.target();
  const tp = CameraRig.topDownView ? 80 : armGoal.pitch;
  const td = CameraRig.topDownView ? 53 : armGoal.distance;
  const ty = armGoal.yaw;
  if (this.armPitch !== tp || this.armDistance !== td || this.armYaw !== ty) {
    this.armPitch += (tp - this.armPitch) * Math.min(1, 5 * dt);
    this.armYaw += (ty - this.armYaw) * Math.min(1, 2 * dt);
    this.armDistance += (td - this.armDistance) * Math.min(1, 2 * dt);
    if (Math.abs(tp - this.armPitch) < 1e-3) this.armPitch = tp;
    if (Math.abs(ty - this.armYaw) < 1e-3) this.armYaw = ty;
    if (Math.abs(td - this.armDistance) < 1e-3) this.armDistance = td;
    this.applyYaw();
  }
  if (a.adsFactor === null) this.adsValue += clamp((a.adsInput ? 1 : 0) - this.adsValue, -10 * dt, 10 * dt);
  else this.adsValue = a.ads;
  const ads = this.adsValue;
  const fov = lerp(CAMERA_FOV, CAMERA_ADS_FOV, ads);
  if (Math.abs(this.camera.fov - fov) > 1e-3) { this.camera.fov = fov; this.camera.updateProjectionMatrix(); }
  const adsMul = a.adsFactor ?? 1.25;
  const maxOff = lerp(sickMode() ? 0 : AIM_OFFSET, AIM_OFFSET * adsMul, ads);
  const factor = a.adsFactor === null ? AIM_FACTOR : lerp(AIM_FACTOR, AIM_FACTOR * adsMul, ads);
  const goal = a.triggerHeld ? LERP_FIRING : LERP_IDLE;
  this.lerpSpeed += clamp(goal - this.lerpSpeed, -LERP_DRIFT * dt, LERP_DRIFT * dt);

  this.target.set(target.x, 0, target.z);
  if (a.inputBlocked) {
    const k = Math.min(1, dt * this.lerpSpeed);
    this.offX += (0 - this.offX) * k;  this.offZ += (0 - this.offZ) * k;
  } else {
    this.apply(null);
    this.camera.updateMatrixWorld();
    const mouse = this.onPlane(a.ndc.x, a.ndc.y, this.pMouse);
    const centre = this.onPlane(0, 0, this.pCentre);
    const mid = this.onPlane(0, 1, this.pTop).add(this.onPlane(0, -1, this.pBottom)).multiplyScalar(0.5);
    const toMid = mid.sub(centre);
    const len = toMid.length();
    if (len > MID_SNAP) toMid.multiplyScalar(MID_SNAP / len);
    const midP = toMid.add(centre);
    const bias = Math.min(len, MID_SNAP);
    let vx = mouse.x - midP.x;  let vz = mouse.z - midP.z;
    const vl = Math.hypot(vx, vz);
    if (vl > maxOff) { vx *= maxOff / vl; vz *= maxOff / vl; }
    const dotR = vx * VIEW.right.x + vz * VIEW.right.z;
    const dotF = vx * VIEW.fwd.x + vz * VIEW.fwd.z;
    const tx = clamp(dotR * factor, -maxOff, maxOff);
    const tz = clamp(dotF * factor, -maxOff, maxOff) - bias;
    const k = Math.min(1, dt * this.lerpSpeed);
    this.offX += (tx - this.offX) * k;  this.offZ += (tz - this.offZ) * k;
  }
  this.shakeOff.set(0, 0, 0);
  for (const im of this.impulses) {
    const k = im.t < im.env.dur ? sampleCurve(im.env.keys, im.t / im.env.dur) : 0;
    im.t += dt;
    this.shakeOff.x += im.x * k;  this.shakeOff.z += im.z * k;
  }
  for (let i = this.impulses.length - 1; i >= 0; i -= 1) if (this.impulses[i].t >= this.impulses[i].env.dur) this.impulses.splice(i, 1);
  this.apply(this.shakeOff);
  this.focus.apply(this.camera, dt);
}
```

## Porting pitfalls

- **Bias term.** It is easy to omit. It is `−bias` on `offZ`, about −1.70 m at the defaults, and it is measured through the real camera on the y = 0.5 plane. Re-derive it by casting rays rather than hard-coding it. Roblox `ViewportPointToRay` and the vertical FOV match this geometry.
- **Two ray casts.** The rig's ray starts from the pose with the current offset, no shake and this frame's arm. The gameplay aim ray (`updateAim`) uses the camera as left by the previous frame, shake included.
- **Easing form.** The rates are `min(1, dt·rate)` Euler steps. Use the same form for matching feel at variable dt, with the same 0.05 s dt clamp.