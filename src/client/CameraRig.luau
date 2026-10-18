--!strict
-- src/systems/CameraRig.ts on a Roblox camera: 45 m arm at 55 deg pitch, view yawed 30 deg, vertical FOV 23.5 -> 22.8 with
-- ADS, hard follow; all smoothing lives in the cursor look-ahead (0.5 x (cursor - screen mid-point) on the y = 0.5 m plane,
-- clamped to 5 m, eased at a lerp speed that drifts toward 1.5/s while firing and back toward 12/s), recoil / melee /
-- explosion impulse envelopes. Metres internally; studs only when placing the camera.
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Units = require(Shared.Units)
local Curve = require(Shared.Curve)

local C = Config.Camera
local S = Units.S
local CameraRig = {}

-- ground basis of the view (x/z, metres): right = screen-right, fwd = screen-up
local yawRad = math.rad(-C.yaw)
CameraRig.right = Vector2.new(math.cos(yawRad), -math.sin(yawRad))
CameraRig.fwd = Vector2.new(-math.sin(yawRad), -math.cos(yawRad))

local pitch, dist, armYaw = C.pitch, C.distance, C.yaw

local function applyYaw()
	local y = math.rad(-armYaw)
	CameraRig.right = Vector2.new(math.cos(y), -math.sin(y))
	CameraRig.fwd = Vector2.new(-math.sin(y), -math.cos(y))
end

--- CameraVolumes.blendVolumes for the character's point
local CaveB = require(Shared.CaveData).bounds
CameraRig.topDown = false -- Y: Switch View (TopDownVolume: pitch 80, distance 53; yaw from the volumes)
local function armGoal(px: number, pz: number): (number, number, number)
	local gp, gy, gd = C.pitch, C.yaw, C.distance
	local list = Config.CameraVolumes
	if px >= CaveB.minX and px <= CaveB.maxX and pz >= CaveB.minZ and pz <= CaveB.maxZ then
		-- the cave scene's own stack: its global volume, then its local sphere
		local g = Config.CaveVolumes.global
		gp, gy, gd = g.pitch, g.yaw, g.distance
		list = Config.CaveVolumes
	end
	for _, v in ipairs(list) do
		local d = math.max(0, math.sqrt((px - v.x) ^ 2 + (pz - v.z) ^ 2) - v.sphere)
		if d * d <= v.blend * v.blend then
			local t = if v.blend > 0 then 1 - (d * d) / (v.blend * v.blend) else 1
			t = math.clamp(t, 0, 1)
			gp += (v.pitch - gp) * t
			gy += (v.yaw - gy) * t
			gd += (v.distance - gd) * t
		end
	end
	return gp, gy, gd
end
local offX, offZ = 0, 0
local lerpSpeed = C.lerpIdle
local adsValue = 0
local target = Vector2.zero
local impulses: { { x: number, z: number, t: number, env: any } } = {}

--- screen-relative input (x right, z down) -> world x/z
function CameraRig.viewToWorld(ix: number, iz: number): Vector2
	local r, f = CameraRig.right, CameraRig.fwd
	return Vector2.new(ix * r.X - iz * f.X, ix * r.Y - iz * f.Y)
end

local function armOffset(): Vector3
	local p = math.rad(pitch)
	local h = math.cos(p) * dist
	return Vector3.new(-CameraRig.fwd.X * h, math.sin(p) * dist, -CameraRig.fwd.Y * h)
end

local function place(cam: Camera, shake: Vector3?)
	local fx = target.X + CameraRig.right.X * offX + CameraRig.fwd.X * offZ
	local fz = target.Y + CameraRig.right.Y * offX + CameraRig.fwd.Y * offZ
	local arm = armOffset()
	local eye = Vector3.new(fx + arm.X, arm.Y + 0.5, fz + arm.Z)
	local at = Vector3.new(fx, 0.5, fz)
	if shake then
		eye += shake
		at += shake
	end
	cam.CFrame = CFrame.lookAt(eye * S, at * S)
	cam.Focus = CFrame.new(at * S)
end

-- the camera-space ray through a viewport point, hit on the y = planeY metres plane (metres)
local function onPlane(cam: Camera, px: number, py: number): Vector3
	local ray = cam:ViewportPointToRay(px, py)
	local o, d = ray.Origin / S, ray.Direction
	if math.abs(d.Y) < 1e-6 then
		return Vector3.new(target.X, C.planeY, target.Y)
	end
	local t = (C.planeY - o.Y) / d.Y
	return o + d * t
end

function CameraRig.snapTo(x: number, z: number)
	offX, offZ = 0, 0
	-- a new map starts at the defaults, then eases into the volumes (CameraRig.update volGen reset)
	pitch, dist, armYaw = C.pitch, C.distance, C.yaw
	applyYaw()
	target = Vector2.new(x, z)
	local cam = Workspace.CurrentCamera
	if cam then
		place(cam, nil)
	end
end

--- GenerateImpulseWithVelocity: displacement = velocity x envelope(t); amount in metres
function CameraRig.shake(amount: number, kind: string, dir: Vector2?)
	local d = dir or Vector2.new(0, 1)
	if d.Magnitude < 1e-6 then
		d = Vector2.new(0, 1)
	end
	d = d.Unit
	table.insert(impulses, { x = d.X * amount, z = d.Y * amount, t = 0, env = Config.Shake[kind] })
	if #impulses > 16 then
		table.remove(impulses, 1)
	end
end

export type AimInput = {
	cursor: Vector2, -- viewport pixels (software cursor incl. recoil)
	triggerHeld: boolean,
	ads: number, -- 0..1 held gun ramp
	adsInput: boolean,
	adsFactor: number?, -- gun ADSAimDistanceFactor or nil with no gun
	inputBlocked: boolean,
}

function CameraRig.update(dt: number, tx: number, tz: number, a: AimInput)
	local cam = Workspace.CurrentCamera
	if not cam then
		return
	end
	cam.CameraType = Enum.CameraType.Scriptable
	-- CameraArm.Update: ease to the blended volumes (pitch 5/s, yaw and distance 2/s)
	local tp, ty, td = armGoal(tx, tz)
	if CameraRig.topDown then
		tp, td = 80, 53
	end
	-- Studio-only inspection fixture: the "DevZoom" attribute (metres) pulls the arm in for close captures
	local devZoom = game:GetService("Players").LocalPlayer:GetAttribute("DevZoom")
	if typeof(devZoom) == "number" and game:GetService("RunService"):IsStudio() then
		td = devZoom
	end
	if pitch ~= tp or dist ~= td or armYaw ~= ty then
		pitch += (tp - pitch) * math.min(1, 5 * dt)
		armYaw += (ty - armYaw) * math.min(1, 2 * dt)
		dist += (td - dist) * math.min(1, 2 * dt)
		if math.abs(tp - pitch) < 1e-3 then pitch = tp end
		if math.abs(ty - armYaw) < 1e-3 then armYaw = ty end
		if math.abs(td - dist) < 1e-3 then dist = td end
		applyYaw()
	end
	if a.adsFactor == nil then
		adsValue += math.clamp((if a.adsInput then 1 else 0) - adsValue, -10 * dt, 10 * dt)
	else
		adsValue = a.ads
	end
	local ads = adsValue
	local fov = C.fov + (C.adsFov - C.fov) * ads
	if math.abs(cam.FieldOfView - fov) > 1e-3 then
		cam.FieldOfView = fov
	end
	local adsMul = a.adsFactor or C.noGunAdsFactor
	local maxOff = C.aimOffset + (C.aimOffset * adsMul - C.aimOffset) * ads
	local factor = if a.adsFactor == nil then C.aimFactor else C.aimFactor + (C.aimFactor * adsMul - C.aimFactor) * ads

	local goal = if a.triggerHeld then C.lerpFiring else C.lerpIdle
	lerpSpeed += math.clamp(goal - lerpSpeed, -C.lerpDrift * dt, C.lerpDrift * dt)

	target = Vector2.new(tx, tz)
	if a.inputBlocked then
		local k = math.min(1, dt * lerpSpeed)
		offX += (0 - offX) * k
		offZ += (0 - offZ) * k
	else
		place(cam, nil)
		local vp = cam.ViewportSize
		local mouse = onPlane(cam, a.cursor.X, a.cursor.Y)
		local centre = onPlane(cam, vp.X / 2, vp.Y / 2)
		local mid = (onPlane(cam, vp.X / 2, 0) + onPlane(cam, vp.X / 2, vp.Y)) * 0.5
		local toMid = mid - centre
		local len = toMid.Magnitude
		if len > C.midSnap then
			toMid *= C.midSnap / len
		end
		local midP = toMid + centre
		local bias = math.min(len, C.midSnap)
		local vx, vz = mouse.X - midP.X, mouse.Z - midP.Z
		local vl = math.sqrt(vx * vx + vz * vz)
		if vl > maxOff then
			vx *= maxOff / vl
			vz *= maxOff / vl
		end
		local dotR = vx * CameraRig.right.X + vz * CameraRig.right.Y
		local dotF = vx * CameraRig.fwd.X + vz * CameraRig.fwd.Y
		local gx = math.clamp(dotR * factor, -maxOff, maxOff)
		local gz = math.clamp(dotF * factor, -maxOff, maxOff) - bias
		local k = math.min(1, dt * lerpSpeed)
		offX += (gx - offX) * k
		offZ += (gz - offZ) * k
	end
	local sx, sz = 0, 0
	for _, im in impulses do
		local kk = if im.t < im.env.dur then Curve.sample(im.env.keys, im.t / im.env.dur) else 0
		im.t += dt
		sx += im.x * kk
		sz += im.z * kk
	end
	for i = #impulses, 1, -1 do
		if impulses[i].t >= impulses[i].env.dur then
			table.remove(impulses, i)
		end
	end
	place(cam, Vector3.new(sx, 0, sz))
end

--- the cursor on the y = h metres plane (metres, x/z)
function CameraRig.cursorOnPlane(px: number, py: number, h: number): Vector3
	local cam = Workspace.CurrentCamera
	local ray = cam:ViewportPointToRay(px, py)
	local o, d = ray.Origin / S, ray.Direction
	local t = (h - o.Y) / d.Y
	return o + d * t
end

return CameraRig
