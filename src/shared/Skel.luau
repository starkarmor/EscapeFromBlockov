--!strict
-- The source skeleton (gen/Skeleton.luau) and the BoneAnim blend of src/entities/Beaver.ts:
-- Idle + four Walk clips by move direction, DodgeRoll, MeleeAttack_RightSlash on the upper body, gun-hold overlay.
-- Bone space is metres in the web frame (model +z forward); rigs scale at the end.
local Skeleton = require(script.Parent.gen.Skeleton)

local Skel = {}
Skel.data = Skeleton
Skel.count = #Skeleton.bones

local N = Skeleton.samples
local byName: { [string]: number } = {}
for i, b in Skeleton.bones do
	byName[b.n] = i
end
Skel.index = byName

-- bones the melee slash replaces (Beaver.ts MELEE_BONES)
local meleeMask: { boolean } = {}
for i, b in Skeleton.bones do
	meleeMask[i] = string.match(b.n, "^Spine") ~= nil
		or string.match(b.n, "^UpperArm") ~= nil
		or string.match(b.n, "^Elbow") ~= nil
		or string.match(b.n, "^ForeArm") ~= nil
		or string.match(b.n, "^Hand") ~= nil
		or string.match(b.n, "^Head") ~= nil
end

export type Pose = {
	q: { { number } }, -- per bone {x,y,z,w}
	p: { { number } }, -- per bone {x,y,z}
}

local function bindPose(): Pose
	local pose: Pose = { q = {}, p = {} }
	for i, b in Skeleton.bones do
		pose.q[i] = { b.r[1], b.r[2], b.r[3], b.r[4] }
		pose.p[i] = { b.p[1], b.p[2], b.p[3] }
	end
	return pose
end
Skel.bindPose = bindPose
local BIND = bindPose()

local function qcf(q: { number }): CFrame
	return CFrame.new(0, 0, 0, q[1], q[2], q[3], q[4])
end

--- World (model-space, metres) CFrame of every bone for a pose.
function Skel.fk(pose: Pose, out: { CFrame }?): { CFrame }
	local w = out or table.create(Skel.count)
	for i, b in Skeleton.bones do
		local q, p = pose.q[i], pose.p[i]
		local l = CFrame.new(p[1], p[2], p[3], q[1], q[2], q[3], q[4])
		w[i] = if b.par > 0 then w[b.par] * l else l
	end
	return w
end

local function slerp(ax, ay, az, aw, bx, by, bz, bw, t)
	local d = ax * bx + ay * by + az * bz + aw * bw
	if d < 0 then
		bx, by, bz, bw, d = -bx, -by, -bz, -bw, -d
	end
	if d > 0.9995 then
		local x, y, z, w = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, aw + (bw - aw) * t
		local l = math.sqrt(x * x + y * y + z * z + w * w)
		return x / l, y / l, z / l, w / l
	end
	local th = math.acos(d)
	local s = math.sin(th)
	local k0, k1 = math.sin((1 - t) * th) / s, math.sin(t * th) / s
	return ax * k0 + bx * k1, ay * k0 + by * k1, az * k0 + bz * k1, aw * k0 + bw * k1
end

export type AnimState = {
	dt: number,
	speed: number, -- m/s on the ground
	dirX: number, -- move direction in the body frame: x right, z forward
	dirZ: number,
	aiming: boolean,
	melee: number, -- 0..1 through a swing, 0 = none
	dodge: number, -- 0..1 through a roll, 0 = none
}

export type Anim = {
	idlePhase: number,
	walkPhase: number,
	pose: Pose,
	rs: { { number } },
	ps: { { number } },
	rw: { number },
	pw: { number },
}

function Skel.newAnim(): Anim
	local a: Anim = { idlePhase = math.random(), walkPhase = 0, pose = bindPose(), rs = {}, ps = {}, rw = {}, pw = {} }
	for i = 1, Skel.count do
		a.rs[i] = { 0, 0, 0, 0 }
		a.ps[i] = { 0, 0, 0 }
		a.rw[i] = 0
		a.pw[i] = 0
	end
	return a
end

local function addClip(a: Anim, name: string, phase: number, w: number, only: { boolean }?)
	local c = Skeleton.clips[name]
	if not c or w <= 0 then
		return
	end
	local u = if c.loop then (phase - math.floor(phase)) * N else math.clamp(phase, 0, 1) * (N - 1)
	local i0 = math.min(N - 1, math.floor(u))
	local i1 = if c.loop then (i0 + 1) % N else math.min(N - 1, i0 + 1)
	local f = u - i0
	local f0, f1 = c.rf[i0 + 1], c.rf[i1 + 1]
	for k, b in c.rot do
		if only and not only[b] then
			continue
		end
		local o = (k - 1) * 4
		local x, y, z, ww = slerp(f0[o + 1], f0[o + 2], f0[o + 3], f0[o + 4], f1[o + 1], f1[o + 2], f1[o + 3], f1[o + 4], f)
		local bq = BIND.q[b]
		local s = if x * bq[1] + y * bq[2] + z * bq[3] + ww * bq[4] < 0 then -w else w
		local r = a.rs[b]
		r[1] += x * s
		r[2] += y * s
		r[3] += z * s
		r[4] += ww * s
		a.rw[b] += w
	end
	local g0, g1 = c.pf[i0 + 1], c.pf[i1 + 1]
	for k, b in c.pos do
		if only and not only[b] then
			continue
		end
		local o = (k - 1) * 3
		local p = a.ps[b]
		p[1] += (g0[o + 1] + (g1[o + 1] - g0[o + 1]) * f) * w
		p[2] += (g0[o + 2] + (g1[o + 2] - g0[o + 2]) * f) * w
		p[3] += (g0[o + 3] + (g1[o + 3] - g0[o + 3]) * f) * w
		a.pw[b] += w
	end
end

local function clear(a: Anim)
	for i = 1, Skel.count do
		local r, p = a.rs[i], a.ps[i]
		r[1], r[2], r[3], r[4] = 0, 0, 0, 0
		p[1], p[2], p[3] = 0, 0, 0
		a.rw[i] = 0
		a.pw[i] = 0
	end
end

--- BoneAnim.update (Beaver.ts): writes a.pose.
function Skel.update(a: Anim, s: AnimState)
	clear(a)
	local amt = math.min(1, s.speed / 2)
	a.idlePhase += s.dt / Skeleton.clips.Idle.len
	a.walkPhase += s.dt * math.clamp(s.speed / 3, 0.6, 2.2) / Skeleton.clips.Walk_Forward.len
	if s.dodge > 0 then
		addClip(a, "DodgeRoll_Forward", s.dodge, 1)
	else
		addClip(a, "Idle", a.idlePhase, 1 - amt)
		local wf, wb = math.max(0, s.dirZ), math.max(0, -s.dirZ)
		local wr, wl = math.max(0, s.dirX), math.max(0, -s.dirX)
		local sum = wf + wb + wr + wl
		if sum == 0 then
			sum = 1
		end
		addClip(a, "Walk_Forward", a.walkPhase, amt * wf / sum)
		addClip(a, "Walk_Backward", a.walkPhase, amt * wb / sum)
		addClip(a, "Walk_Right", a.walkPhase, amt * wr / sum)
		addClip(a, "Walk_Left", a.walkPhase, amt * wl / sum)
	end
	local pose = a.pose
	for i = 1, Skel.count do
		local q, p = pose.q[i], pose.p[i]
		if a.rw[i] > 0 then
			local r = a.rs[i]
			local l = math.sqrt(r[1] * r[1] + r[2] * r[2] + r[3] * r[3] + r[4] * r[4])
			q[1], q[2], q[3], q[4] = r[1] / l, r[2] / l, r[3] / l, r[4] / l
		else
			local bq = BIND.q[i]
			q[1], q[2], q[3], q[4] = bq[1], bq[2], bq[3], bq[4]
		end
		if a.pw[i] > 0 then
			local r = a.ps[i]
			p[1], p[2], p[3] = r[1] / a.pw[i], r[2] / a.pw[i], r[3] / a.pw[i]
		else
			local bp = BIND.p[i]
			p[1], p[2], p[3] = bp[1], bp[2], bp[3]
		end
	end
	if s.melee > 0 and s.dodge <= 0 then
		clear(a)
		addClip(a, "MeleeAttack_RightSlash", s.melee, 1, meleeMask)
		for i = 1, Skel.count do
			if a.rw[i] > 0 then
				local r = a.rs[i]
				local l = math.sqrt(r[1] * r[1] + r[2] * r[2] + r[3] * r[3] + r[4] * r[4])
				local q = pose.q[i]
				q[1], q[2], q[3], q[4] = r[1] / l, r[2] / l, r[3] / l, r[4] / l
			end
		end
	elseif s.aiming and s.dodge <= 0 then
		for k, q in Skeleton.aim do
			local t = pose.q[k]
			t[1], t[2], t[3], t[4] = q[1], q[2], q[3], q[4]
		end
		for k, p in Skeleton.aimPos do
			local t = pose.p[k]
			t[1], t[2], t[3] = p[1], p[2], p[3]
		end
	end
end

Skel.qcf = qcf
return Skel
