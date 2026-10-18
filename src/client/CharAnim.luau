--!strict
-- Client-side body layers on every character near the camera (each client applies them locally; nothing replicates):
--   humanoids (the players' avatars, the store enemies): Roblox's Animate / the server's tracks play the clips; a player's
--   dodge plays the web's DodgeRoll_Forward clip (gen/RollClip, retargeted by tools/gen_roll.py) on every R15 joint, alone
--   (Beaver.ts BoneAnim: the roll replaces idle / walk / aim; enemies slide without it), through Motor6D.Transform after
--   the Animator; the death fall (on the back about the feet) on the Root joint the same way. The avatar's joints are
--   Motor6Ds or, after Roblox's joint upgrade, AnimationConstraints (swapped in after spawn, so they are looked up by
--   name each time): the Animator rewrites either one's Transform after every script phase, so while a pose drives the
--   body this client parks that character's Animator (Parent = nil) and puts it back after;
--   creatures (the store wolf mesh on a ball root): a procedural trot bob and the fall on its Body motor.
-- State comes from replicated attributes: DodgeAt / DeadAt = workspace:GetServerTimeNow() at the event; the local
-- player's own dodge comes from PlayerControl through CharAnim.localState.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Config = require(Shared.Config)
local RollClip = require(Shared.gen.RollClip)
local Fx = require(script.Parent.Fx)

local CharAnim = {}
local S = Units.S
local CULL = 70 * S

-- the local player's state this frame (PlayerControl.animState)
CharAnim.localState = nil :: { dodge: number, sprint: boolean? }?
local clock = 0

-- the clip's joints on the R15 parts (the ankles hold the rest pose through the roll)
local JOINT_PART = { Root = "LowerTorso", Waist = "UpperTorso", Neck = "Head", RightShoulder = "RightUpperArm",
	RightElbow = "RightLowerArm", RightWrist = "RightHand", LeftShoulder = "LeftUpperArm", LeftElbow = "LeftLowerArm",
	LeftWrist = "LeftHand", RightHip = "RightUpperLeg", RightKnee = "RightLowerLeg", LeftHip = "LeftUpperLeg",
	LeftKnee = "LeftLowerLeg", RightAnkle = "RightFoot", LeftAnkle = "LeftFoot" }
-- the samples as CFrames (rotation per joint; the Root also carries the pelvis offset, metres -> studs)
local FRAMES: { { [string]: CFrame } } = {}
for f, row in RollClip.frames do
	local out: { [string]: CFrame } = {}
	for joint, q in row :: any do
		if joint ~= "off" then
			local o = if joint == "Root" then (row :: any).off else { 0, 0, 0 }
			out[joint] = CFrame.new(o[1] * S, o[2] * S, o[3] * S, q[1], q[2], q[3], q[4])
		end
	end
	out.RightAnkle = CFrame.identity
	out.LeftAnkle = CFrame.identity
	FRAMES[f] = out
end

--- the roll pose at phase 0..1 (BoneAnim.add, non-looping: u = phase x (N - 1), slerp between neighbours)
local function rollPose(phase: number, joint: string): CFrame
	local u = math.clamp(phase, 0, 1) * (RollClip.samples - 1)
	local i0 = math.min(RollClip.samples - 1, math.floor(u))
	local i1 = math.min(RollClip.samples - 1, i0 + 1)
	return FRAMES[i0 + 1][joint]:Lerp(FRAMES[i1 + 1][joint], u - i0)
end

type Hum = { model: Model, root: BasePart, hum: Humanoid, stopped: boolean, player: boolean, rolling: boolean,
	animator: Animator?, posed: boolean, gun: { weld: Weld, part0: BasePart, c0: CFrame, rest: CFrame, grip: CFrame }? }
local hums: { [Model]: Hum } = {}
type Creature = { model: Model, root: BasePart, motor: Motor6D, phase: number }
local creatures: { [Model]: Creature } = {}

local function track(model: Model)
	local root = model:WaitForChild("HumanoidRootPart", 5) :: BasePart?
	if not root then
		return
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		if model:WaitForChild("LowerTorso", 5) then
			hums[model] = { model = model, root = root, hum = hum, stopped = false, rolling = false, animator = nil, posed = false,
				player = Players:GetPlayerFromCharacter(model) ~= nil, gun = nil }
		end
	elseif model:GetAttribute("Creature") then
		local motor = root:WaitForChild("Body", 5) :: Motor6D?
		if motor then
			creatures[model] = { model = model, root = root, motor = motor, phase = 0 }
		end
	end
end

local function untrack(model: Model)
	local h = hums[model]
	if h and h.animator and h.animator.Parent == nil then
		h.animator.Parent = h.hum
	end
	hums[model] = nil
	creatures[model] = nil
end

local function phaseOf(model: Model, attr: string, dur: number, now: number): number
	local at = model:GetAttribute(attr)
	if typeof(at) ~= "number" then
		return 0
	end
	local t = (now - at) / dur
	return if t >= 0 and t < 1 then math.max(t, 1e-3) else 0
end

--- the joint driving `part` (Motor6D or AnimationConstraint, whichever the avatar has right now)
local function joint(h: Hum, name: string): Instance?
	local p = h.model:FindFirstChild(JOINT_PART[name])
	local j = p and p:FindFirstChild(name)
	if j and (j:IsA("Motor6D") or j:IsA("AnimationConstraint")) then
		return j
	end
	return nil
end

local function setT(j: Instance, cf: CFrame)
	(j :: any).Transform = cf
end

--- take the body from the Animator (true) or give it back (false); the local Animate script pauses with it
local function pose(h: Hum, on: boolean, me: Model?)
	if on == h.posed then
		return
	end
	h.posed = on
	if on then
		local a = h.hum:FindFirstChildOfClass("Animator")
		h.animator = a
		if a then
			a.Parent = nil
		end
	else
		for name in JOINT_PART do
			local j = joint(h, name)
			if j then
				setT(j, CFrame.identity)
			end
		end
		if h.animator and h.animator.Parent == nil and h.hum.Parent then
			h.animator.Parent = h.hum
		end
		h.animator = nil
	end
	if h.model == me then
		local animate = h.model:FindFirstChild("Animate") :: LocalScript?
		if animate then
			animate.Enabled = not on
		end
	end
end

--- the torso-mounted gun's hand IK (Dress.holdGun) lets go while the clip moves the arms
local function setIK(h: Hum, on: boolean)
	for _, name in { "GunIK_R", "GunIK_L" } do
		local ik = h.hum:FindFirstChild(name) :: IKControl?
		if ik then
			ik.Enabled = on
		end
	end
end

--- World.update: burst(x, 0.15, z, '#9a8a6a', 1, 1.2) at the character's feet
function CharAnim.dust(at: Vector3)
	Fx.burst(Vector3.new(at.X / S, 0.15, at.Z / S), "#9a8a6a", 1, 1.2)
end

-- the arm chain from the HumanoidRootPart to the right hand
local CHAIN = { { "Root", "LowerTorso" }, { "Waist", "UpperTorso" }, { "RightShoulder", "RightUpperArm" },
	{ "RightElbow", "RightLowerArm" }, { "RightWrist", "RightHand" } }

--- the right hand's grip point in the HumanoidRootPart's frame for the joint transforms `T` (forward kinematics over
--- each joint's own frames, so it matches this frame's pose with no lag)
local function gripInRoot(h: Hum, T: (string) -> CFrame): Vector3?
	local cf = CFrame.identity
	for _, link in CHAIN do
		local j = joint(h, link[1])
		if not j then
			return nil
		end
		if j:IsA("Motor6D") then
			cf = cf * j.C0 * T(link[1]) * j.C1:Inverse()
		else
			local c = j :: AnimationConstraint
			local a0, a1 = c.Attachment0, c.Attachment1
			if not a0 or not a1 then
				return nil
			end
			cf = cf * a0.CFrame * T(link[1]) * a1.CFrame:Inverse()
		end
	end
	local hand = h.model:FindFirstChild("RightHand")
	local att = hand and hand:FindFirstChild("RightGripAttachment") :: Attachment?
	return (if att then cf * att.CFrame else cf).Position
end

--- Beaver.ts: the weapon holder rides the hand socket's position but keeps the rig root's orientation (level, along the
--- facing). While the roll moves the arm, the torso-mounted gun (Dress.holdGun) is pinned to the root there instead.
local function gunFollow(h: Hum, phase: number?)
	local gunModel = h.model:FindFirstChild("HeldGun")
	local rootPart = gunModel and (gunModel :: Model).PrimaryPart
	local weld = rootPart and rootPart:FindFirstChild("GunWeld") :: Weld?
	if phase == nil then
		local g = h.gun
		if g and g.weld.Parent then
			g.weld.Part0 = g.part0
			g.weld.C0 = g.c0
		end
		h.gun = nil
		return
	end
	if not weld or not rootPart then
		return
	end
	local g = h.gun
	if not g or g.weld ~= weld then
		local part0 = weld.Part0 :: BasePart
		local grip = rootPart:FindFirstChild("GunGripTarget") :: Attachment?
		if not part0 or not grip then
			return
		end
		-- the level gun in the root frame at rest (the aim pose it is mounted in)
		local rest = h.root.CFrame:ToObjectSpace(part0.CFrame * weld.C0 * weld.C1:Inverse())
		g = { weld = weld, part0 = part0, c0 = weld.C0, rest = rest, grip = grip.CFrame }
		h.gun = g
	end
	local gg = g :: any
	local hand = gripInRoot(h, function(name)
		return rollPose(phase :: number, name)
	end)
	if not hand then
		return
	end
	local R = gg.rest.Rotation
	local gunInRoot = CFrame.new(hand - R:VectorToWorldSpace(gg.grip.Position)) * R
	weld.Part0 = h.root
	weld.C0 = gunInRoot * weld.C1
end

local function stepHum(h: Hum, now: number, me: Model?)
	local model = h.model
	local deadAt = model:GetAttribute("DeadAt")
	if typeof(deadAt) == "number" then
		-- World.update / Enemy.update: the body tips onto its back about the feet over 1/3 s and rises 0.3 m, then holds
		if not h.stopped then
			h.stopped = true
			h.rolling = false
			gunFollow(h, nil)
			setIK(h, false)
			pose(h, true, me)
			for name in JOINT_PART do
				local j = joint(h, name)
				if j then
					setT(j, CFrame.identity)
				end
			end
		end
		local root = joint(h, "Root")
		if root then
			local t = math.clamp((now - deadAt) * 3, 0, 1)
			-- the Root joint's frame on the HumanoidRootPart, and its height over the floor
			local frame = if root:IsA("Motor6D") then h.root.CFrame * root.C0
				else ((root :: AnimationConstraint).Attachment0 :: Attachment).WorldCFrame
			local floorY = h.root.Position.Y - (h.hum.HipHeight + h.root.Size.Y / 2)
			local ph = frame.Position.Y - floorY
			setT(root, CFrame.new(0, 0.3 * S * t, 0) * CFrame.new(0, -ph, 0) * CFrame.Angles(math.rad(90) * t, 0, 0) * CFrame.new(0, ph, 0))
		end
		return
	elseif h.stopped then
		-- revived / respawned on the same model
		h.stopped = false
		pose(h, false, me)
		setIK(h, true)
	end
	local dodge = if model == me and CharAnim.localState then CharAnim.localState.dodge else phaseOf(model, "DodgeAt", Config.Dash.time, now)
	-- Studio fixture: workspace DevRollPhase (0..1) holds the local character at that phase of the roll
	local pin = if model == me and RunService:IsStudio() then Workspace:GetAttribute("DevRollPhase") else nil
	if typeof(pin) == "number" then
		dodge = math.clamp(pin, 1e-3, 1)
	end
	if not h.player then
		return
	end
	if dodge > 0 then
		if not h.rolling then
			h.rolling = true
			setIK(h, false)
			pose(h, true, me)
		end
		for name in JOINT_PART do
			local j = joint(h, name)
			if j then
				setT(j, rollPose(dodge, name))
			end
		end
		gunFollow(h, dodge)
		-- World.update: a dust puff at the feet every frame of the dodge
		CharAnim.dust(h.root.Position)
	elseif h.rolling then
		h.rolling = false
		gunFollow(h, nil)
		pose(h, false, me)
		setIK(h, true)
	end
end

local function stepCreature(c: Creature, dt: number, now: number)
	local deadAt = c.model:GetAttribute("DeadAt")
	if typeof(deadAt) == "number" then
		-- falls on its side
		local t = math.clamp((now - deadAt) * 3, 0, 1)
		c.motor.Transform = CFrame.Angles(0, 0, math.rad(90) * t)
		return
	end
	local v = c.root.AssemblyLinearVelocity
	local sp = Vector2.new(v.X, v.Z).Magnitude / S
	c.phase += dt * math.max(0.6, sp / 1.2) * 2 * math.pi
	local k = math.min(1, sp)
	local dodge = phaseOf(c.model, "DodgeAt", Config.Dash.time, now)
	local hop = if dodge > 0 then math.sin(dodge * math.pi) * 0.25 * S else 0
	c.motor.Transform = CFrame.new(0, math.abs(math.sin(c.phase)) * 0.05 * S * k + hop, 0) * CFrame.Angles(math.sin(c.phase * 2) * 0.06 * k, 0, 0)
end

function CharAnim.step(dt: number)
	local cam = Workspace.CurrentCamera
	local focus = cam and cam.Focus.Position or Vector3.zero
	local now = Workspace:GetServerTimeNow()
	local me = Players.LocalPlayer.Character
	-- World.update: running kicks up a puff six times a second
	local was = clock
	clock += dt
	local ls = CharAnim.localState
	if ls and ls.sprint and ls.dodge <= 0 and me and math.floor(clock * 6) ~= math.floor(was * 6) then
		local r = me:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r then
			CharAnim.dust(r.Position)
		end
	end
	for model, h in hums do
		if not model.Parent then
			hums[model] = nil
		elseif (h.root.Position - focus).Magnitude <= CULL then
			stepHum(h, now, me)
		end
	end
	for model, c in creatures do
		if not model.Parent then
			creatures[model] = nil
		elseif (c.root.Position - focus).Magnitude <= CULL then
			stepCreature(c, dt, now)
		end
	end
end

function CharAnim.start()
	game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
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
