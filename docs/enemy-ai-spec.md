# Enemy AI spec for the Luau port (Nav.ts, Enemy.ts, World.ts)

The game uses a Three.js-style frame: X and Z are the ground plane, Y is height, and facing 0 points along +Z. Facing is `atan2(dx, dz)` everywhere. Paths are `src/game/Nav.ts:N`, `src/entities/Enemy.ts:N` and `src/game/World.ts:N`. I read all three files in full.

Two code comments are wrong:
- The activeDistance comment says "3D"; the code at `World.ts:1365` is 2D `hypot`.
- `AI.searchHeight` (4) is declared but never used.

---

## A. Nav.ts

### A1. Navmesh file
- `src/world/gz/navmesh_ground_zero.json` has keys: `map`, `source` ("AstarPath cache GroundZeroPathChche"), `characterRadius` 0.3, `walkableClimb` 0.2, `pieces` ("4 kept of 3130"), `verts`, `tris`.
- `verts` is a flat int array of 153864 numbers, so 51288 vertices. Each is `[x, z, y]` in centimetres. The order is x, ground-z, height-y (`Nav.ts:216-219`).
  - Extents: x −22044..30057, z −41450..20940, y −801..3085 cm.
  - Metres: x −220.4..300.6, z −414.5..209.4, y −8.0..30.85.
- `tris` is a flat int array of 200550 indices, so 66850 triangles. The vertex indices are into `verts`. Winding is not relied on: the inside test is sign-agnostic.
- Frame: metres = cm/100, X→X, Z→Z, Y→height. The constructor does `vx = verts[3i]/100; vz = verts[3i+1]/100; vy = verts[3i+2]/100` (`Nav.ts:243-247`). Pathing is purely 2D (x, z); height is used only to pick between overlapping layers.

### A2. Loading
- `loadNavMesh(map)` (`:546`) dynamically imports the JSON and builds `new NavMesh(data)`. It caches the result in `meshes` and returns null on error.
- It is kicked off at world construction (`World.ts:591`).
- `World.navGraph()` (`World.ts:398`) returns the NavMesh once loaded. Until then it returns a fallback `NavGrid` (see A9).

### A3. Build (`Nav.ts:238-293`)
- Triangle centre = mean of the 3 vertices, for x, z and y (`:260-262`). These are the A* node positions.
- Adjacency array `adj[tri*3+k]` is the neighbour across edge k, which runs from vertex k to vertex (k+1)%3. It is −1 when the edge is open.
- Edge matching uses a Map keyed by the sorted pair `"min,max"` of vertex indices, so triangles must share vertex indices, not just coordinates.
  - First sighting stores `i*3+k` in the map.
  - Second sighting sets `adj[i*3+k] = floor(o/3)` and `adj[o] = i`.
  - The map entry is never updated. A third triangle on the same edge links to the first and overwrites the first's link, which orphans the second. This is irrelevant for a manifold mesh.
- Spatial hash: bucket size `bs = 4` m. Key = `gx*100003 + gz`, with `gx = floor(x/4)` and `gz = floor(z/4)`. Each triangle is inserted into every bucket its x/z bounding box touches (`:274-291`).

### A4. Point-in-triangle (`inside`, `:295`)
- For each edge, compute `c = (bx−ax)*(z−az) − (bz−az)*(x−ax)`.
- Set `pos = true` if `c > 1e-7` and `neg = true` if `c < −1e-7`.
- Inside means `!(pos && neg)`. Edges and corners are inclusive within the epsilon.

### A5. Snapping a point to the mesh: `locate(x, z, hintY?)` (`:309-345`)
1. Look only at the single bucket containing (x, z).
   - Among triangles with `inside(i, x, z)`, score `dy = hintY === undefined ? cy[i] : |cy[i] − hintY|`.
   - Take the smallest `dy`, so with no hint it picks the lowest-centre-height triangle.
   - Strict `<` keeps the first on ties. If any hit exists, return it.
2. Otherwise run an expanding fallback over rings r ∈ [4, 8, 16, 32, 64, 100]. 100 is `MAX_NEAREST`, AstarPath.maxNearestNodeDistance.
   - For each r, start with `bd = r*r`.
   - Scan every bucket from `floor((x−r)/4)..floor((x+r)/4)` in both axes.
   - For each triangle there, compute `closest(i, x, z)` and the squared distance `d`. If `d < bd`, set `bd = d` and `best = i`.
   - Return `best` at the first r that finds anything. This ignores `hintY`.
3. Return −1 if nothing is found within 100 m.

### A6. `closest(i, x, z)` (`:356`)
- If the point is inside the triangle, return it unchanged.
- Otherwise take the nearest point over the 3 edge segments: clamp `u = clamp(dot/len², 0, 1)`, with `l2 = |e|² || 1`. The centre is the initial best, but it is always replaced.

### A7. A* (`astar`, `:99-141`)
- Nodes are triangles. Node position = triangle centre (2D).
- Cost: `g(m) = g(n) + hypot(cm.x − cn.x, cm.z − cn.z)`, the 2D centre-to-centre distance.
- Heuristic: `h(n) = hypot(c.x − bx, c.z − bz)`, the 2D distance from the centre to the actual end point (not the end triangle's centre). Scale 1, so it is Euclidean, as in the source's "heuristic 2, scale 1".
- Open list: a binary min-heap keyed by `f = g + h` (`Heap`, `:39`). There is no tie-break rule and no closed set.
  - A `stamp` array marks visited nodes.
  - Relax rule: if `seen[m] === stamp && ng >= gScore[m]` then skip. Otherwise set `gScore`, `parent`, and push `(m, ng + h(m))`.
  - There is no decrease-key: stale duplicates stay in the heap and are expanded when popped. The code does not skip them, but they are harmless.
- Start: `gScore[s] = 0`, `parent[s] = −1`, push `(s, h(s))`.
- Goal test happens at pop (`n === t`): rebuild the path via `parent` and reverse it.
- Budget: `++expanded > MAX_EXPAND (30000)` returns null. This is counted per pop, including stale pops. An exhausted heap also returns null.
- Neighbours come from `neighbours()`: the up-to-3 `adj` entries ≥ 0.

### A8. Path post-processing (`findPath`, `:190-213`)
1. `s = locate(ax, az, hintY)` and `t = locate(bx, bz, hintY)`, both with the same hint. If either is < 0, return null.
2. `nodes = astar(...)`. If null, return null.
3. `pts` = the centre of every node on the path.
   - `pts[0] = closest(s, ax, az)` (the start point).
   - If `pts.length == 1`, push `closest(t, bx, bz)`; otherwise `pts[last] = closest(t, bx, bz)`. This is StartEndModifier "ClosestOnNode" on both ends.
4. If `clear(first, last)` (graph linecast, see below), return `[first, last]`.
5. Otherwise run RaycastModifier "Medium" (`RAYCAST_QUALITY = 1`, `ITER_BY_QUALITY = [1, 2, 1, 3]`), so `iters = 2`:
   - Iteration 0: `pts = greedy(pts)`.
   - Iteration 1: `pts = subdivide(pts, 3)`, then `reverse()`, then `greedy(pts)`.
   - Because `iters % 2 === 0`, reverse once more at the end so the path starts at the start point.
   - The result is an ordered list of x/z points beginning with the (snapped) start.
   - There is no string-pulling or funnel: it is polyline-through-triangle-centres plus greedy line-of-sight shortcuts.

`greedy(g, points)` (`:144`):
- `i = 0`, loop while `i < len`:
  - Push `points[i]`.
  - Set `mn = 1`, `mx = 2`.
  - Exponential phase:
    - `j = i + mx`.
    - If `j >= len`, set `mx = len − i` and break.
    - If `!clear(a, points[j])`, break.
    - Otherwise `mn = mx; mx *= 2`.
  - Binary phase: while `mn + 1 < mx`, `mid = (mn + mx) >> 1`; if `clear(a, points[i + mid])` then `mn = mid`, else `mx = mid`.
  - Then `i += mn`.
- The adjacent point (i+1) is always assumed visible, and the final point is always emitted.

`subdivide(points, 3)` (`:174`):
- For each consecutive pair (a, b), emit `a + (b−a)*k/3` for k = 0, 1, 2.
- Then push the last point.

### A9. Graph linecast `clear(ax, az, bx, bz)` (`NavMesh`, `:388-423`)
- `i = locate(ax, az)`. This has no hint, so it takes the lowest layer. If `i < 0`, return false. Set `from = −1`.
- Repeat up to 4096 times:
  - If `inside(i, bx, bz)`, return true.
  - For each edge k of triangle i:
    - Skip it if `adj[k] === from && adj[k] >= 0`.
    - Compute `r = B − A`, `s = vb − va`, `den = rx*sz − rz*sx`. Skip if `|den| < 1e-12`.
    - Compute `q = va − A`, `tt = (qx*sz − qz*sx)/den`, `uu = (qx*rz − qz*rx)/den`.
    - Skip if `uu < −1e-6 || uu > 1 + 1e-6 || tt < −1e-6`. There is no upper bound on `tt`.
    - Among accepted edges, pick the one with the largest `tt` (the farthest crossing). Set `next = adj` of that edge.
  - If no edge was accepted, or `next < 0` (an open edge, which means the segment leaves the mesh), return false.
  - Set `from = i; i = next`.
- If the loop runs out of iterations, return false.

### A10. Fallback `NavGrid` (used until the mesh loads)
Source: `Nav.ts:430-535`.
- 0.5 m cells over `map.bounds`.
- A cell is free unless its centre lies inside a body-blocking box grown by 0.3. Boxes are those with `blocks(b, Block.body)`; door boxes are treated as passable.
- 8-neighbour graph with no corner cutting. Node centre = cell centre.
- `locate`: the cell if it is free, else expanding rings out to 100/0.5 cells, nearest by squared cell distance.
- `closest`: clamp to the cell rectangle.
- `clear`: sample every 0.125 m (`CELL*0.25`) and require every sampled cell to be free.
- Same A* and post-processing.

### A11. Path requests: queueing and budget (`World.ts:387-422, 1344-1357, 1400-1401`)
- `ctx.requestPath` just pushes `{e, ax, az, bx, bz, done}` onto `pathQ`.
- There is no per-frame budget. `runPaths()` runs at the end of each frame after all AI updates and searches every queued request, limited only by `MAX_EXPAND`.
- Each successful result queues a callback in `pathDone`. Failed searches (null) never call back (`:392`).
- At the start of the next frame, before any `Enemy.update`, all `pathDone` callbacks run (`:1357`). The callback is dropped if the task or request id changed (`Enemy.ts:2064`).
- So path latency is exactly one frame.
- `World.findPath` (`:410`) keeps a per-enemy height hint: it locates the start triangle with the previous hint, stores `height(s)` in `navY`, and passes that hint into `findPath`.
- When a request returns null, the enemy keeps its previous move input. That input is persisted in `moveIn` (`Enemy.ts:2074`) and is not zeroed. The task only ends by its time-out (8 s) or by other task logic. An unreachable or off-mesh target therefore makes the AI keep walking in its old direction, colliding with walls, until the time-out.
- If no `requestPath`/`findPath` exists (unit checks), the path is the straight line `[pos, target]` (`Enemy.ts:2069`).

---

## B. Enemy.ts

### B1. Presets (`ENEMY_DEFS`, `:171-245`)
Common to all: sight 15, fov 100° (full cone), `nightReact` 1.5, forget 8, `canTalk`, bodyRadius 0.3. Walk = 4×factor, run = 6×factor (`mv()`, `:157`). The per-spawn copy (`:701`) multiplies react by `RULES.enemyReaction`, burst by `enemyAttackTime`, gap by `enemyAttackGap`, and hp by `enemyHealth`. For default "survival" these are all 1; "standard" is 1.1/0.9/1.1/0.8.

| | scrapper | scav | brute | wolf |
|---|---|---|---|---|
| hp | 35 | 45 | 60 | 40 |
| dmgMul | 0.82 | 0.9 | 1 | 1 |
| react | 0.65 | 0.65 | 1.0 (melee entry actually 0.2) | 0.2 (melee entry 0.2) |
| move factor | 1 (walk 4 / run 6) | 1 | 1.15 (4.6 / 6.9) | 1.3 (5.2 / 7.8) |
| burst | [0.2, 0.5] | [0.2, 0.5] | [0.3, 0.75] (unused) | [0.2, 0.2] (unused) |
| gap | [1.0, 1.5] | [1.1, 1.8] | [0.5, 1.5] | [0, 0] |
| scatter / run / offscreen | 0.65 / 3 / 4 | 0.65 / 3 / 4 | n/a | n/a |
| bulletSpeedMul | 0.65 | 0.75 | n/a | n/a |
| rangeMul | 1 | 1 | n/a | n/a |
| shootDelay | 0.35 | 0.35 | 0.2 | 0.2 |
| patrolRange | 8 | 8 | 8 | 8 |
| combatMoveRange | 8 | 8 | 3.5 | 8 |
| combatMoveTime | [1, 3] | [1, 3] | [1, 3] | [1, 3] |
| traceChance | [0.3, 0.7] | [0.3, 0.7] | [1, 1] | [1, 1] |
| turnPatrol / turnCombat (deg/s) | 400 / 1200 | 400 / 1200 | 400 / 1200 | 600 / 1200 |
| team | 1 | 1 | 1 | 8 |
| hit radius | 0.5 | 0.5 | 0.5 | 0.65 |
| other | critGain −0.3 | | melee: dmg 27, range 1.55, speed 2.2, AP 1.5, bleed 0.5, crit 0.2×1.6, knife `dealTime` 0.12 | melee: dmg 25, 1.3/s, range 2, AP 1, bleed 0.5, crit 0.15×1.15; `dash` [1, 1.2]; `shootCanMove` |

- Scrapper weapons: toz66 15, tt33 25, pm 25.
- Scav weapons: shotgun_homemade 10, mp155 10, g17 10, bow 3, ak47 5, ak103 1, ak74u 8, adar 4.
- Gun stats are in `src/game/gz/gz_gunfeel.json`, for example `tt33`: Damage 11, ShootSpeed 6, BulletSpeed 79, BulletDistance 16.5, DefaultScatter 0.349, MaxScatter 1.28, ScatterGrow 0.629, ScatterRecover 0.5, ScatterFactor 17.5, MoveSpeedMultiplier 1, ReloadTime 1.8, Capacity 8, SoundRange 20.3.
- `Roster.ts:1207-1235` keeps these defs for the 9 Ground Zero kinds. It only adds `brain` hooks (armor stats, buffs, skills) and `bodyRadius` from the model. Plain gun and melee archetypes get no `patrol` or `combat` override.
- Teams (`:440`): scrapper, scav and brute are 1; contractor and boss are 3; drone is 6; wolf, bloater and stormling are 8. The player is 0.
  - `isEnemyTeam(a, b)` (`:444`): false if either is 5; true if `a === 7`; otherwise `a !== b`.
  - Wolves (team 8) and scavs (team 1) are therefore enemies of each other.

### B2. Per-frame `update` (`:1067-1143`)
Order:
1. If dead: advance the death animation and return.
2. `now = ctx.now` (World.time). Tick buffs and the speech-bubble timers.
3. Every 1 s (`turnT`): `turnStat = foe ? turnCombat : turnPatrol`; `reaction = def.react * (ctx.night ? nightReact : 1)`.
4. If `foe` is dead or gone, set `foe = null`.
5. If `forceTrace > 0.5` and the player is within `forceTrace` and is an enemy of this team, set `foe = 'player'`.
6. `patrolPos` handling:
   - A member with a living leader and no foe: `patrolPos = leader.pos`.
   - A leader with no foe: `patrolPos = own pos`.
   - Otherwise it stays at the spawn point.
7. `target = foe position`. Clear `danger` if it is dead. Run `updateGunState`, then `brain.tick`.
8. FSM transitions (checked before the state tick):
   - init: `fsmT += dt`; reload if empty on the first tick; at `fsmT >= 0.2` enter patrol.
   - patrol: `alert` → alert; else `foe` → combat.
   - alert: `foe` → combat; else `!alert` → patrol.
   - combat: `!foe` → patrol (it goes straight to patrol, not alert).
9. Reset `aiming`, `trigger` and `press` to false. Run the state tick (`tickPatrol`, `tickAlert`, `tickMeleeCombat` if `def.melee`, else `tickGunCombat`).
10. `tickTools`, `fireGun`, `tickMelee`, `integrate` (movement and facing).

The HUD state is `combat`, `investigate` (alert) or `patrol` (also covers init).

State entry (`enter`, `:1145-1183`):
- All states: `waitT = 0`, `loopStep = 0`, `stopMove()`, `trigger = false`.
- patrol: `runInput = false`, `noticed = false`, `alert = false`, `aimTarget = null`, `aimPos = null`, `waitT = 0.2`, `loopStep = −1`, reload if empty.
- alert: say "?", `runInput = false`, `waitT = 0.1`, `loopStep = −1`, `loopRoll = rand() <= traceChance`, `alertForget = def.forget`.
- combat: `reactT = melee ? 0.2 : reaction`; `atk = 'gate'`; clear `hasTarget`, `hasObstacle`, `lostT` and `hasTargetT`; `wantAttack = false`; `wantT = U(gap)`; `atkSeq = −1`.
  - During `reactT` nothing happens: no aim and no move, the AI just decelerates.

`traceChance` is rolled once per spawn: `U(rand, def.traceChance)` (`:720`). Initial facing is `rand() * 2π`.

### B3. Perception

**Search queue.** `search()` (`:937`) queues one request per enemy at a time (`searchPending`).
- A request captures `{pos, facing, now}` at request time.
- When answered by `runBrain`, `searchT = 0.05` and `searchNow` runs from the captured values.
- Requesters call it when `searchT` has counted down to ≤ 0, then reset `searchT = 0.05`:
  - Patrol every tick.
  - Alert every tick.
  - Combat only while `hasObstacle`.

**`searchNow`** (`:955`):
- `hurt = (at − lastHurt < 1.5) && lastHurtByChar && lastHurtDmg >= 1`.
- `dist = def.sight * mult * ctx.visionMul * (hurt ? 2 : 1)`.
- `mult` is 1 for patrol, 1.25 for alert (`sightAlert`), 1.5 for combat re-acquire (`sightCombat`), and 1 for the melee re-acquire.
- Cone angle = `def.fov` (100°). Only patrol passes `night = true`, which does `angle *= nf + (1 − nf)*nightVision` with `nf = ctx.nightAngle ?? 1` and `nightVision` default 0.5.
- Candidates are the player (if alive) plus every other living enemy-team AI that is not `noReceiver`.
  - Reject if not `isEnemyTeam`.
  - `d = hypot` in 2D.
  - Reject if `d >= bestD` (the nearest wins), or `d > dist`.
  - If `d > 1.5` (`AI.sense`, the 1.5 m bubble):
    - Reject if `|angleDiff(atan2(dx, dz), facing)| > angle/2`.
    - Reject if there is no line of sight (`aiSight`, ray at y = 1.5).
  - Inside 1.5 m, only the distance check applies: no cone and no LOS.
- If found, `foe = best`. A miss keeps the old foe.
- The foe is not cleared by the search itself.

**`aiSight`** (`:460`):
- Fails if `index.firstBlock(..., Block.sight, y) < 1`.
- `blocks(b, kind, y)` (geometry:35) needs `!b.off`, the box's `cat` to include sight, and `b.y0 <= y <= b.h`. Without `cat`, a box blocks sight only if `h >= 2`.
- A ray that starts inside a box ignores that box.
- Smoke also blocks (`smokeRayT < 1`), including for hurt searches.
- Foliage boxes (`nearFoliage`, those within 34 m of the player) block unless it is a hurt search or the viewer stands inside the box.
- Sight ray heights: 1.5 for searches, 0.4 for the combat obstacle check.

**Reaction time.** There is no per-sighting delay; the only delay is `reactT` on combat entry (B2). `react` includes `RULES.enemyReaction` and the night factor, refreshed once per second.

**Hearing.** `hear(x, z, radius, type, team)` (`:864`):
- Ignored if dead.
- Types 0 (footstep or noise) and 1 (gunfire) from the same team are ignored. The player's team is 0.
- If `2D distance < radius * def.hearing (default 1)`, set `noticed = true`, `noticeT = now`, and `noticeFrom = (x, z)`.
- Sound sources:
  - Player footsteps (`World.ts:1281`): radius 16 sprinting or 8 walking, ×1.5 if load ≥ 0.75, 0 while ADS is held. Cadence is from `gz_steps.json`: `walkFrequence` 3.3 and `runFrequence` 5.5 (steps per second), `minTimeSpace` 0.08.
  - Player gunfire (`World.ts:1784`): the gun's `SoundRange`.
  - Whistle: 15.
  - AI footsteps: `walkSound 8` or `runSound 16`, sent to other-team AI only (`World.ts:1391`).
  - AI gunfire: the gun's `sound`, `hear(..., type 1, e.teamId)` to all other enemies (`World.ts:1873`).
  - Grenade landing (type 2): radius 20, sets `danger` regardless of distance.
- `takeDamage` (`:891`) also sets `noticed`/`noticeFrom` = the attacker's position and records `lastHurt`, `lastHurtDmg` and `lastHurtByChar`. Buff and effect damage does not count.
- A hurt AI does not acquire the target directly. It goes to alert, turns to the attacker, and its hurt search (×2 sight, through foliage, for 1.5 s) finds it.

**Lost-target rules.**
- Gun combat (`:1417-1458`): each frame compute `hasObstacle = lineBlocked(...)`.
  - If `!hasObstacle && dist <= 20` (`trackRange`): `lostT = 0`, `noticeFrom = target position`, `hasTarget = true`, `hasTargetT = 0`.
  - Else `lostT += dt`. When `lostT` crosses 0.25 (`lostSnap`), `noticeFrom` is snapped to the target's current position once. At `lostT >= 0.25 + def.forget` (8.25 s), `foe = null`, which puts the AI in patrol.
- Melee combat (`:1688-1696`): if blocked or `dist > 24`, then `lostT += dt`; at ≥ 7 s `foe = null`. Otherwise `lostT = 0`.
- There is no direct "go look at last position" state. While blocked, `noticeFrom` stays at the last-seen position and the pursuit logic (B6) uses it.

**`lineBlocked`** (`:1396`): with the brain queue, a check is queued (only one pending per enemy) and answered later. `checkBlocked` keeps its previous value until the next answer; it starts false. The check is `!aiSight(selfPos, targetPos, y = 0.4, hurt-through-foliage)`.

### B4. Movement and path following (`integrate`, `:2041-2188`)
- Move tasks (`MoveTask`, `:520`): `{x, z, t, over, trace, stopDist, repath, aimAt}`.
  - `moveTo(x, z, over)` (usually over = 8 s) sets `pending = true`.
  - `traceTo(getter, stopDist, over)` re-reads the target position every 0.15 s (`tickTask`, `:1197`): `repath` resets to 0.15, and `pending = true` again.
- `tickTask` (`:1189`) ends the task (returns true) when:
  - `t > over` (time-out), or
  - the trace getter returns null, or
  - trace tasks only: distance to the target is `< stopDist`, or
  - `t.done`, or the distance to the task target `< 0.2` (`stopDistance`).
- Path request (pending): `path = null`, `wp = 0`, `pathReq++`, then `ctx.requestPath`. The answer assigns `path`/`wp` only if the same task and request id are still current.
- Path following (`:2071-2105`):
  - While `path == null`, reuse the previous `moveIn` (no braking).
  - Otherwise `i = wp`, `d = dist(path[i])`. While `d < 0.6` (`slowIn`, which equals `nextWaypointDistance`): advance `i` (recomputing `d`), or set `end = true` if `i` is already the last waypoint.
  - Input = unit vector toward `path[i]`. If `end` (last waypoint within 0.6), input magnitude = `sqrt(l/0.6)`. Otherwise magnitude 1.
  - If `end && l < 0.2` (`stopDistance`): `path = null`, `done = true`, input 0.
- Waypoint arrival radius is therefore 0.6 for intermediate points and 0.2 for the final stop.
- With no task, input is 0 (`stopMove`).
- `moving = |input| > 0.02`. Running = `moving && runInput && (stamina/100 >= 0.2 || (wasRunning && stamina > 0))`.
- Stamina (Player.ts:221): max 100, drain 7/s while running, recover 20/s after a 1.5 s delay. Dashing costs 10.
- Velocity:
  - Target velocity = `input * speed`.
  - `speed = max(0, (walk|run + buff adds)) * walkRunPct * moveability * heldMoveMul`.
  - `heldMoveMul` is the gun's `MoveSpeedMultiplier` if > 0 (ak47 0.85, ak74u 0.95, shotgun_homemade 0.98).
  - Acceleration is `MOVE.walkAcc 50` or `MOVE.runAcc 70` (m/s²). Velocity moves toward the target by at most `acc*dt` per frame, as a vector.
  - `pos += vel*dt`.
- Facing:
  - Not running and aim point more than 0.6 m away: face the aim point.
  - Else if speed > 0.02: face the velocity direction.
  - Turn per frame = `turnStat * moveability * DEG * dt`, clamped via `angleDiff`.
- Aim point (`aimPoint`): the foe if `aimTarget === 'foe'`, else `task.aimAt`, else `aimPos`, else none.
- Wall collision: `resolveCircle(pos, bodyRadius (0.3), ctx.bodyAround(pos.x, pos.z, 1.5) ?? ctx.boxes)`.
- No stuck detection. `lastX`/`lastZ` are stored but unused. Recovery relies only on the 8 s task time-out and the new random point on the next cycle.

### B5. Patrol (`tickPatrol`, `:1226-1299`)
- Each tick: `searchT -= dt` and search when due (night on). `if (noticed) alert = true`. `calmHeal` (below).
- Entry waits: `waitT 0.2`, then a fixed `waitT = 1`, then the loop starts (`loopStep` −1 → −2 → 0).
- **Solo or no-leader loop**:
  - `loopStep 0`: `p = randomPoint(patrolPos (= spawn), patrolRange 8, avoid 2, 360°)`; `moveTo(p, 8)`.
  - `loopStep 1`: when `tickTask` returns true, `waitT = U(1.5, 6)` and `loopStep = 0`.
- **With a leader** (grouped AI): each tick compute `far = leader !== this && dist(patrolPos, pos) > 5`. A change of branch stops movement and resets the loop.
  - `far`: `runInput = true`; `traceTo(leader.pos, stopDist 3.5, over 8)`.
  - Otherwise: wait `U(1.5, 6)`, `runInput = false`, move to `randomPoint(patrolPos (= leader pos), 3, 2, 150°)` with over 8.
- `randomPoint(c, radius, avoid, angleDeg)` (`:1001`):
  - `dir` = unit vector from the agent to `c` (a random direction if the distance is under 0.1).
  - `a = (rand − 0.5) * angleDeg` in radians; `r = avoid + rand*(radius − avoid)`.
  - Rotate −dir by `a`: `u = (−dx*cos a − dz*sin a, dx*sin a − dz*cos a)`.
  - The result is `c + u*r`. This is on the agent's side of `c`, and 360° means any direction. The point is not snapped to the navmesh; the path end is snapped (A8).
- Spawn `patrol[]` arrays passed to the constructor are ignored (`:698`).

### B6. Alert (`tickAlert`, `:1314-1377`)
- Each tick: search with ×1.25 and night off; `calmHeal`.
- While `loopStep === −1 && waitT > 0`, count `waitT` down and return (entry wait 0.1).
- If `danger` is within 8 m: `fleeDanger(radius 16, avoid 10, angle 90, faceIt)`, then return.
- A fresh stimulus is `(hurt ≥ 2 within 0.1 s and by a character) || noticed within 0.4 s`.
  - It consumes `noticed` (if noticed within 0.4 s).
  - It sets `runInput = false`, `aimTarget = null`, `aimPos = noticeFrom`, stops movement, `waitT = 0.1`, `loopStep = 0`, `loopRoll = rand() <= traceChance`, `alertForget = def.forget` (8).
  - Then return.
- Otherwise `alertForget -= dt`; at ≤ 0 set `alert = false` (the FSM then enters patrol).
- While `waitT > 0`, count down and return.
- If `loopRoll` is false: stay still, facing `noticeFrom`, until the forget timer ends.
- If `loopRoll` is true:
  - `loopStep <= 0`: move to `randomPoint(noticeFrom, 3, 0.2, 360°)` (over 8), `loopStep = 1`.
  - When `tickTask` returns true: `waitT = 3`, `loopStep = 0`.

### B7. Combat, gun (`tickGunCombat` `:1417`, `combatMove` `:1461`, `attackLoop` `:1535`)
Order each tick: `reactT` countdown (returns); `foePos`; `hasObstacle = lineBlocked`; if obstacle, re-search ×1.5 every 0.05 s; track or forget logic (B3); `combatMove`; `attackLoop`.

**`combatMove`:**
- If `danger` is within 8 m: `fleeDanger(15, 9, 10°)` and return.
- Hurt-dodge: if `def.dash` and hit ≥ 3 within 0.2 s by a character, and not reloading, and `now − dashTaskT >= dashNext`: stop, dash in a random direction, `waitT = 0.2`, return. Dash costs 10 stamina, lasts `DASH.time 0.5` at `DASH.speed 10` (or `dashSpeed`) × the speed curve, and cooldown is 0.5. Dashing makes the AI immune to bullets and melee.
- `aimTarget = 'foe'`, `runInput = false`.
- `shootHold`: while `atk === 'shoot'` and not `shootCanMove`, `stopMove()` every frame and return.
- `waitT` countdown, then return.
- If `hasObstacle && hasTarget`, the pursuit branch:
  - `hasTargetT += dt`; at `>= forget`, `hasTarget = false`.
  - `loopStep 0`: roll `loopRoll = rand() <= traceChance`.
    - If true: `waitT = 0.2`, `loopStep = 1`, return. Next tick `loopStep 1` runs `traceTo(noticeFrom, stopDist 1, over 8)` and sets `loopStep 3`.
    - If false: move to `randomPoint(noticeFrom, combatMoveRange, 2, 360°)` (`loopStep 2`).
  - When the task ends: `waitT = (loopStep === 3 ? 0.5 : U(combatMoveTime))`, `loopStep = 0`.
- Otherwise (target visible, or no target tracked), the strafe branch:
  - If `loopStep !== 9`: move to `randomPoint(noticeFrom, combatMoveRange (8), avoid 2, 360°)` with over 8, `loopStep = 9`.
  - When `tickTask` ends: `waitT = U(combatMoveTime [1, 3])`, `loopStep = 0`.
  - `noticeFrom` tracks the live target position while it is in clear line, so this strafes within 2..8 m of the target. After a burst freezes movement (task null), `tickTask` returns true and a 1-3 s wait follows.
- There is no cover-seeking, no retreat, and no distance-keeping beyond this ring. Chasing happens only through the pursuit branch.

**Attack loop** (`attackLoop`, `atk` phases; `atkT += dt` each tick):
- `gate`:
  - `go = !hasObstacle || (hurt ≥ 3 within 8 s && by a character)`.
  - If not `go`: heal check every 1.5 s. If `useT <= 0`, `hp <= 0.3 * maxHp`, and the AI has a drug, go to `healWait` for 0.5 s then `startUse(true)` (stands still).
  - If `go`:
    - If `dist > aimRange() * 1.5`, wait at the gate.
    - Grenade throw: needs no obstacle, 6 s cooldown since the last check (`itemCooldown`), a carried throwable, `rand() <= 0.3`, and no reload/use/swing/dash in progress. It then enters `throw` for the skill's ready time + 0.1.
    - Otherwise `brain.skill` if the preset has one.
    - Otherwise `atk = 'range'`.
- `range`: wait until `dist <= aimRange()`, with `aimTarget = 'foe'`. `aimRange = BulletDistance * rangeMul − 0.4`, or 8 for no gun. There is no time-out, and no LOS recheck.
- `delay`: wait `shootDelay` (0.35 scrapper/scav).
- `reloadWait`: wait until `reloadT <= 0`. Then enter `shoot` with `shootT = U(burst)`, `semiT = 0.35`.
- `shoot`:
  - `aiming = true`, `trigger = true`, `semiT += dt`.
  - When `semiT >= 0.35` (`semiPress`): `semiT = 0`, `press = true`.
  - At `atkT >= shootT` → `endBurst`.
  - A 0.2-0.5 s burst of a semi-auto gun therefore gets one press at the start and a second only if the burst exceeds 0.35 s. Auto guns hold the trigger.
- `endBurst`: `trigger = false`, `reloadIfEmpty(true)`, `atk = 'gap'`, `gapT = U(gap)`.
- `gap`: wait `gapT`, then back to `gate`.
- `throw`, `skill`, `healWait`, `heal`: wait for the action to complete; throw and skill are followed by a `gap` of `U(gap)`.

**Firing** (`fireGun` `:1939`, `shootOnce` `:1995`):
- No fire while reloading, using an item, throwing, or dashing. `held = trigger && !running`.
- Gate: no fire while `cdLeft > 0 || fireFrame || readyFrame`.
- Trigger mode: `gunAgent(id).trigger === 'auto'` fires on `held`. Otherwise it fires on a `press` or a buffered press. If `ShootSpeed >= 5`, a press is buffered and fires when the cooldown clears.
- Each shot:
  - `burstLeft` is initialised from `BurstCount`.
  - Aim point = target position. The shot angle is `atan2(aim − muzzle)` if `moveability > 0.5`; the aim point is also used for slope.
  - `cdLeft = (1/ShootSpeed) * (B/(B+2))` mid-burst, else `(1/ShootSpeed) * (3B/(B+2))`. With B = 1 the normal interval is 1/ShootSpeed.
  - Scatter then grows (see below).
- Scatter (`scatterDeg`, `:1988`) for a player target:
  - Full cone in degrees = `gunScatter * max(0.1, def.scatter * (1 + m))`.
  - `m = runScatter` (3) if the player is running (`ctx.playerRunning`), else 1. If the AI is off-screen, `m = max(m, offScreenScatter)` (4). For other AI targets `m = 1`.
  - `gunScatter` starts at `DefaultScatter*ScatterFactor` (`scatterNow(feel, 0).def`).
  - After each shot it grows by `ScatterGrow*ScatterFactor`, clamped to `MaxScatter*ScatterFactor`.
  - It recovers toward default at `ScatterRecover*grow*ShootSpeed` per second (×6 when below default), no ADS.
  - Example: scrapper with tt33 starts at 0.349×17.5 = 6.1°, so about 7.9° cone at m = 1.
- World pellets (`World.ts:1827`): each pellet angle = `angle + fanOffset + (rand − 0.5) * radians(shotScatter)`. This is uniform within the cone.
- Bullet parameters (`gun()`, `:752`):
  - speed = `BulletSpeed * bulletSpeedMul` (scrapper tt33: 79 × 0.65 = 51.35).
  - range = `(BulletDistance*rangeMul + 0.4) * 1.05`; half damage past `(BulletDistance*rangeMul + 0.4) * 0.5` (`halfAt`).
  - damage per pellet = `Damage * dmgMul * (1 + buff gunDamagePct) / ShotCount`.
  - crit rate = `CritRate * (1 + critGain)`.
- Reload (`startReload` `:1823`):
  - Time = `ReloadTime / (1 + reloadGain)`. Single-bullet guns load one round per cycle and chain.
  - Reload is refused if `ammo >= mag`, no `reserve`, dashing, or mid-burst. When there is no reserve and the magazine is empty, it says "Out of ammo!".
  - Guns spawn empty (`setAmmo`), so the first reload fills them at init or on patrol entry.
  - "Reloading!" (`reloadIfEmpty`, `:1812`): `reloads` increments each time `endBurst` starts a reload on an empty gun, and the text is spoken from the second such reload onward. Entering patrol or init reloads do not count.

### B8. Combat, melee (brute and wolf) (`tickMeleeCombat`, `:1672-1781`)
- Entry `reactT = 0.2`. Each tick: line check, re-search ×1 if blocked every 0.05 s, lost logic (B3, 7 s / 24 m).
- Not attacking (`wantAttack` false):
  - `runInput = false`.
  - Dash on hit (wolf): hurt ≥ 3 within 0.2 s and cooldown ready → dash perpendicular to the target, random side.
  - `wantT -= dt`; at ≤ 0, `wantAttack = true`, `atkSeq = 0`, stop moving.
  - Otherwise strafe: after `waitT`, move to `randomPoint(fp (target), combatMoveRange, avoid 0, 360°)` (brute 3.5, wolf 8), over 8; on completion `waitT = U(combatMoveTime)`.
  - After each attack, `wantT = U(gap)` (brute 0.5-1.5, wolf 0).
- Attack sequence:
  - `atkSeq 0`: `runInput = true`; `traceTo(foe, stopDist 1.5, over 8)`; `atkSeq 1`.
  - `atkSeq 1`: `tickTask`. If it ended with `t > 8`, retry from 0. Otherwise `runInput = false`, `aimTarget = 'foe'`, `atkSeq 2`, `atkT = 0`.
  - `atkSeq 2`: optional preset skill; after 0.1 s set `alertFx = 0.2` ("!"), `atkSeq 3`.
  - `atkSeq 3`: after 0.2 s call `startSwing()`, `atkSeq 4`.
  - `atkSeq 4`: after 0.25 s, `wantAttack = false`, `wantT = U(gap)`.
- `startSwing`: needs `now − lastSwing >= 1/attackSpeed`, not dashing, not using an item. It sets `swingT = 0`. The hit is dealt when `swingT > dealTime` (0.12 for the knife, default 0.12 when unlisted), via `ctx.melee(e)`. The swing lasts 0.25 s.
- Hit test (`World.ts:1882`): reach = `m.range + 0.05` (brute 1.6, wolf 2.05), plus the target's hit radius. The target must be within 90° of the facing, or closer than `0.5 + its hit radius`. Same-team targets and dashing targets are skipped. Damage = `damage * meleeStatMul`. The AI-vs-AI factor is `aiCombat(attacker)/aiCombat(victim)`.
- `blockBullet > 0.5` (the butcher knife) also creates a 0.2 s bullet blocker.

### B9. Wolf specifics
- Melee archetype with canDash. Dash [1, 1.2] only triggers on being hurt (B7/B8).
- `shootCanMove` is irrelevant for melee.
- Hit radius 0.65.
- Wolf `traceChance` 1, so alert always moves toward the noise.
- Wolf `gap` 0 means it re-attacks immediately.

### B10. Groups
- `updateGroups` (`World.ts:1450`) runs each frame before AI:
  - The first spawned member of a group leads. When it dies, the last living member (list order) takes over.
  - Every living member's `leader` is set (the leader's is itself).
  - If the leader has a foe and a member does not, the member gets it (`shareFoe`). If the member has a foe and the leader does not, the leader gets it. This applies at any distance, every frame.
- Beyond foe sharing, there is no explicit "call for help". Allies of different teams react to gunfire through `hear`. Same-team gunfire and noise are ignored.
- Patrol follows the leader (B5).

### B11. Heal
- Calm heal (`:1302`): in patrol and alert, every 1.5 s, if not hurt ≥ 2 within 5 s and `hp <= 0.8*maxHp`, `startUse(false)`. It keeps walking.
- Combat heal is only reached at the gate when the target is behind an obstacle: `hp <= 0.3`, wait 0.5, `startUse(true)` (stands still).
- A heal is only started if the AI carries a healing consumable.

### B12. Activation (`World.ts:1358-1374`)
- Each frame per enemy: `active = hypot(e.pos − control.sourcePos) < 50`. The source is the player's position, or the controlled robot's position.
- If it newly becomes active: `awake.add(e); e.reactivate()` (fsm = 'init', `fsmT = 0`, stop move, trigger off).
- If inactive: the FSM does not run. Only `tickBuffs(dt)` runs; the AI does not move.

---

## C. World.ts per-frame driver

Order inside `update` (`World.ts:1186`), AI section (`:1318-1401`):
1. Build `ctx` once per frame:
   - `boxes`: those within 34 m of the player.
   - `bodyAround`: a local box query.
   - `sightIndex`: a `BoxIndex` (cell size 8) over all boxes whose `cat` has `Block.sight`.
   - `foliage`, `smoke`, `time`, `now = this.time`, `visionMul`, `nightAngle`, `night`, `playerRunning = p.sprinting`, `others = this.enemies`, and the callbacks `shoot`, `melee`, `requestPath`, `findPath`, `brain`.
2. `camera.updateMatrixWorld()`, and set the frustum.
3. `updateGroups()`.
4. `this.brainCtx = ctx`.
5. Run last frame's finished path callbacks (`pathDone`).
6. For each enemy, in array order:
   - `onScreen` = the point (x, 1.2, z) is inside the camera frustum (used for the off-screen scatter multiplier).
   - Activation check (B12).
   - If the enemy is player-controlled: `tickControlled`. Else if active: `e.update(dt, ctx)`, then `aiOpenDoor(e)`. Else `tickBuffs`.
   - Apply DoT damage; drop the body once on death.
   - Visibility, footstep sound dispatch (`stepRadius` to other teams' AI), bar and laser.
7. `runBrain()` (`:424`): answer up to 3 queued search requests (`maxSearch`), then up to 3 queued line-check requests (`maxCheck`), each in FIFO order. These are the `AIMainBrain` quotas (ASSET #94110). Results apply at the next frame's update.
8. `runPaths()`: compute all queued path requests (no cap).
9. Then projectiles, grenades, etc.

**Sight queue budget.** The queues are global FIFO across all enemies. An enemy keeps only one search and one check pending, so latency grows with the number of waiting enemies. Each answer uses the captured start position/facing and the current frame's `ctx`.

**LOS checks per frame**: at most 3 searches + 3 obstacle checks. Each search tests the player and every other AI candidate within sight range and cone, using `BoxIndex.firstBlock` (a grid walk with cell size 8; hits use segment-vs-box tests).

**Wall collision**: only `resolveCircle` (geometry:132) with radius 0.3.
- 2 passes over boxes within 1.5 m of the enemy.
- Skips boxes that are `off`, or that have `cat` without `Block.body`.
- Closest point on the box rectangle to the centre. If the squared distance is ≥ r², no collision.
- If the centre is exactly inside the box (squared distance < 1e-8), eject along the shallowest axis; this applies when the push-out margin is the smallest of left, right, up, down.
- Otherwise push to `closest + (pos − closest)/|…| * r`.
- It is applied after each frame's position update, not sub-stepped. There is no enemy-enemy collision and no height handling in body collision (y is ignored; `blocks` is called without y for body).

**Doors**: `aiOpenDoor` opens any unlocked, unkeyed, closed door the enemy walks into: within `width/2 + bodyRadius` along the door and `0.36 + bodyRadius` across (`DOOR_TRIGGER_HALF = 0.36`, `World.ts:302`). The navmesh itself does not model doors (the grid fallback treats doors as passable).

---

## Porting notes (traps)
- The path result is delayed by one frame (A11). Sight and obstacle answers are delayed by the 3-per-frame FIFO queues.
- Persisting `moveIn` while `path == null` (B4) is intentional behaviour in the source.
- `locate` without a hint chooses the lowest layer, and the end point uses the start's hint. `clear` always starts with an unhinted `locate`.
- Heap stale entries are not filtered. `MAX_EXPAND` counts those pops too.
- All timer values (0.05 searches, 0.15 trace repath, 0.2 init, 0.4 notice, 0.25 `lostSnap`, 8 s task time-out) are in seconds of game time (`World.time`).