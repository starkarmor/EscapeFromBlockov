--!strict
-- Plays the source clips on every character rig near the camera (each client animates every rig locally; nothing here
-- replicates). State comes from the root's velocity and facing plus replicated attributes:
--   Held = "gun" | "melee" | "none", DodgeAt / MeleeAt = workspace:GetServerTimeNow() at the action start.
-- The local player's own state overrides through CharAnim.localState.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Skel = require(Shared.Skel)
local RigBuilder = require(Shared.RigBuilder)
local Units = require(Shared.Units)
local Config = require(Shared.Config)

local CharAnim = {}
local S = Units.S
local HAND = Skel.index["Hand.Soket.R"]
local CULL = 70 * S

type Joint = { j: Motor6D, c0inv: CFrame, bone: number, rel: CFrame, weapon: boolean, len: number }
type Entry = { model: Model, root: BasePart, anim: Skel.Anim, joints: { Joint }, k: number, world: { CFrame }, skeletal: boolean, phase: number }
local entries: { [Model]: Entry } = {}

-- the local player's state this frame (PlayerControl writes it)
CharAnim.localState = nil :: Skel.AnimState?

local function track(model: Model)
	if entries[model] then
		return
	end
	local root = model:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	local key = model:GetAttribute("Rig")
	if not root or typeof(key) ~= "string" then
		return
	end
	local spec = RigBuilder.spec(key)
	if not spec then
		return
	end
	local joints: { Joint } = {}
	for i, p in spec.parts do
		local j = root:FindFirstChild("J" .. i) :: Motor6D?
		if j then
			table.insert(joints, {
				j = j,
				c0inv = j.C0:Inverse(),
				bone = p.bone,
				rel = CFrame.new(p.p[1], p.p[2], p.p[3], p.q[1], p.q[2], p.q[3], p.q[4]),
				weapon = p.weapon == true,
				len = p.size[3],
			})
		end
	end
	entries[model] = { model = model, root = root, anim = Skel.newAnim(), joints = joints, k = spec.rootScale, world = {}, skeletal = spec.skeletal, phase = 0 }
end

local function untrack(model: Model)
	entries[model] = nil
end

local function phaseOf(model: Model, attr: string, dur: number, now: number): number
	local at = model:GetAttribute(attr)
	if typeof(at) ~= "number" then
		return 0
	end
	local t = (now - at) / dur
	return if t >= 0 and t < 1 then math.max(t, 1e-3) else 0
end

function CharAnim.step(dt: number)
	local cam = Workspace.CurrentCamera
	local focus = cam and cam.Focus.Position or Vector3.zero
	local now = Workspace:GetServerTimeNow()
	local me = Players.LocalPlayer.Character
	for model, e in entries do
		if not model.Parent then
			entries[model] = nil
			continue
		end
		local rp = e.root.Position
		if (rp - focus).Magnitude > CULL then
			continue
		end
		local st: Skel.AnimState
		if model == me and CharAnim.localState then
			st = CharAnim.localState
			st.dt = dt
		else
			local v = e.root.AssemblyLinearVelocity
			local look = e.root.CFrame.LookVector
			local right = e.root.CFrame.RightVector
			local sp = Vector2.new(v.X, v.Z).Magnitude / S
			local dx, dz = 0, 1
			if sp > 0.02 then
				local h = Vector3.new(v.X, 0, v.Z).Unit
				-- web localDir: x along the model's +x (the root's -RightVector, RigBuilder.FLIP), z along the facing
				dx, dz = -h:Dot(right), h:Dot(look)
			end
			st = {
				dt = dt,
				speed = sp,
				dirX = dx,
				dirZ = dz,
				aiming = model:GetAttribute("Held") == "gun",
				melee = phaseOf(model, "MeleeAt", 1 / 5, now),
				dodge = phaseOf(model, "DodgeAt", Config.Dash.time, now),
			}
		end
		if not e.skeletal then
			-- quadruped (wolverine): its own skeleton is not ported; a procedural trot bob on the bind pose
			e.phase += dt * math.max(0.6, st.speed / 1.2) * 2 * math.pi
			local bob = CFrame.new(0, math.abs(math.sin(e.phase)) * 0.05 * S * math.min(1, st.speed), 0)
			for _, jt in e.joints do
				jt.j.Transform = jt.c0inv * bob * RigBuilder.partCFrame(e.world, 0, jt.rel, e.k)
			end
			continue
		end
		Skel.update(e.anim, st)
		local world = Skel.fk(e.anim.pose, e.world)
		local hand = world[HAND]
		for _, jt in e.joints do
			local cf: CFrame
			if jt.weapon then
				-- the gun at the hand socket, pointing along the facing (BoneAnim: holder at the socket + len / 2 forward)
				local hp = hand.Position
				local m = CFrame.new(hp.X, hp.Y, hp.Z + jt.len / 2)
				cf = RigBuilder.partCFrame({ m }, 1, CFrame.identity, e.k)
			else
				cf = RigBuilder.partCFrame(world, jt.bone, jt.rel, e.k)
			end
			jt.j.Transform = jt.c0inv * cf
		end
	end
end

function CharAnim.start()
	local folder = Workspace:WaitForChild("Characters")
	for _, m in folder:GetChildren() do
		if m:IsA("Model") then
			task.spawn(track, m)
		end
	end
	folder.ChildAdded:Connect(function(m)
		if m:IsA("Model") then
			task.spawn(track, m)
		end
	end)
	folder.ChildRemoved:Connect(function(m)
		if m:IsA("Model") then
			untrack(m)
		end
	end)
	RunService.PreSimulation:Connect(CharAnim.step)
end

return CharAnim
