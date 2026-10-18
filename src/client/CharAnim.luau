--!strict
-- Client-side body layers on every character near the camera (each client applies them locally; nothing replicates):
--   humanoids (the players' avatars, the store enemies): Roblox's Animate / the server's tracks play the clips; this adds
--   the web's dodge roll and death fall on the LowerTorso Root motor (C0 is local to each client);
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

local CharAnim = {}
local S = Units.S
local CULL = 70 * S

-- the local player's state this frame (PlayerControl.animState)
CharAnim.localState = nil :: { dodge: number }?

type Hum = { model: Model, root: BasePart, motor: Motor6D, c0: CFrame, hum: Humanoid, stopped: boolean }
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
		local lower = model:WaitForChild("LowerTorso", 5)
		local motor = lower and lower:FindFirstChild("Root") :: Motor6D?
		if motor then
			hums[model] = { model = model, root = root, motor = motor, c0 = motor.C0, hum = hum, stopped = false }
		end
	elseif model:GetAttribute("Creature") then
		local motor = root:WaitForChild("Body", 5) :: Motor6D?
		if motor then
			creatures[model] = { model = model, root = root, motor = motor, phase = 0 }
		end
	end
end

local function untrack(model: Model)
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

local function stepHum(h: Hum, now: number, me: Model?)
	local model = h.model
	local deadAt = model:GetAttribute("DeadAt")
	if typeof(deadAt) == "number" then
		-- World.update: fall on the back about the feet over 0.333 s and hold
		if not h.stopped then
			h.stopped = true
			local animator = h.hum:FindFirstChildOfClass("Animator")
			if animator then
				for _, t in animator:GetPlayingAnimationTracks() do
					t:Stop(0.1)
				end
			end
			if model == me then
				local animate = model:FindFirstChild("Animate") :: LocalScript?
				if animate then
					animate.Enabled = false
				end
			end
		end
		local t = math.clamp((now - deadAt) * 3, 0, 1)
		local hgt = h.hum.HipHeight + h.root.Size.Y / 2
		local lift = h.root.Size.Z * 0.5 * t
		h.motor.C0 = CFrame.new(0, -hgt + lift, 0) * CFrame.Angles(math.rad(90) * t, 0, 0) * CFrame.new(0, hgt, 0) * h.c0
		return
	end
	-- the dodge (Config.Dash.time): a forward roll about the hips with a tuck
	local dodge = if model == me and CharAnim.localState then CharAnim.localState.dodge else phaseOf(model, "DodgeAt", Config.Dash.time, now)
	if dodge > 0 then
		local e = dodge * dodge * (3 - 2 * dodge)
		local tuck = math.sin(dodge * math.pi) * h.root.Size.Y * 0.45
		h.motor.C0 = CFrame.new(0, -tuck, 0) * CFrame.Angles(-2 * math.pi * e, 0, 0) * h.c0
	elseif h.motor.C0 ~= h.c0 then
		h.motor.C0 = h.c0
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
