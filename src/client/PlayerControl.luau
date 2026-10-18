--!strict
-- The local player's movement, 1:1 with src/entities/Player.ts update(): walk 4 / run 6 m/s with 50 / 70 m/s^2
-- acceleration, Shift held to run (stamina >= 20% to start, drains 7/s, recovers 20/s after 1.5 s), Space dodge roll
-- (0.5 s on the DASH speed curve, 10 stamina, 0.5 s cooldown from the end, i-frames, 0.6 s trigger lock), RMB ADS slows
-- the walk by the gun's AdsWalkSpeedMultiplier, facing turns toward the aim point at 1200 deg/s (200 while running /
-- moving). The velocity drives the avatar's Humanoid (client-owned); Roblox physics resolves walls.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Units = require(Shared.Units)
local Curve = require(Shared.Curve)
local Net = require(Shared.Net)
local CameraRig = require(script.Parent.CameraRig)
local Controls = require(script.Parent.Controls)

local S = Units.S
local M, ST, D = Config.Move, Config.Stamina, Config.Dash

local PC = {}
PC.pos = Vector2.zero -- metres
PC.vel = Vector2.zero
PC.facing = 0 -- radians, atan2(x, z) (0 = +z)
PC.stamina = ST.max
PC.sprinting = false
PC.ads = 0
PC.adsInput = false
PC.dodgeT = 0 -- time into the current roll, 0 = none
PC.dodgeDir = Vector2.new(0, 1)
PC.triggerLock = 0
PC.aim = Vector2.zero -- aim point on the plane (metres)
PC.gun = nil :: any -- the held gun's raw gz_gunfeel row (Combat sets it)
PC.held = "gun"
PC.slot = 1 -- 1 / 2 firearms, 3 melee (the HUD highlight)
PC.blocked = false -- a UI panel owns input (loot window or inventory)
PC.lootOpen = false
PC.invOpen = false
PC.photoOpen = false
PC.resultOpen = false
PC.mapOpen = false
PC.noteOpen = false
PC.actionMove = true -- the running action allows moving (reload yes, interact no)
PC.actionRun = true
PC.moveability = 1
PC.meleeAnim = 0 -- 1 at a swing, decays 5/s (Player.ts meleeAnim)

local clock = 0
local dashEnd = -math.huge
local lastSpend = -math.huge
local wasRunning = false
local runToggle = false
local handoff = false
local dodgeQueued = false
local dodgeSent = 0
local sentSprint = false
local sentAds = false

local function root(): BasePart?
	local c = Players.LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function spend(n: number)
	PC.stamina = math.max(0, PC.stamina - n)
	lastSpend = clock
end

function PC.dashing(): boolean
	return PC.dodgeT > 0
end

function PC.requestDodge()
	dodgeQueued = true
end

local function moveIntent(): Vector2
	if PC.blocked or UserInputService:GetFocusedTextBox() then
		return Vector2.zero
	end
	local x, z = 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.D) then x += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) then x -= 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) then z += 1 end
	if UserInputService:IsKeyDown(Enum.KeyCode.W) then z -= 1 end
	-- the left stick / touch move stick when no key is down (analog: a partial push walks slower)
	if x == 0 and z == 0 then
		local a = Controls.move()
		x, z = a.X, a.Y
	end
	local v = CameraRig.viewToWorld(x, z)
	if v.Magnitude > 1 then
		v = v.Unit
	end
	return v
end

function PC.update(dt: number, cursor: Vector2)
	local r = root()
	if not r then
		return
	end
	clock += dt
	PC.blocked = PC.lootOpen or PC.invOpen or PC.resultOpen or PC.mapOpen or PC.noteOpen or PC.photoOpen
	Controls.blocked = PC.blocked
	PC.meleeAnim = math.max(0, PC.meleeAnim - dt * 5)
	local p = r.Position
	PC.pos = Vector2.new(p.X / S, p.Z / S)
	local intent = moveIntent()
	local mag = intent.Magnitude
	local gun = if PC.held == "gun" then PC.gun else nil

	-- ADS (ItemAgent_Gun.UpdateAds): ramp 1 / ADSTime in, at least 4/s out
	local adsHeld = not PC.blocked and (UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) or Controls.adsHeld())
	PC.adsInput = adsHeld and PC.actionMove and not PC.sprinting and PC.dodgeT <= 0
	if gun then
		local adsIn = 1 / math.max(0.01, gun.ADSTime)
		PC.ads = math.clamp(PC.ads + (if PC.adsInput then adsIn else -math.max(4, adsIn)) * dt, 0, 1)
	else
		PC.ads = 0
	end

	local held = if gun and gun.MoveSpeedMultiplier > 0 then gun.MoveSpeedMultiplier else 1
	-- raid-only percentage adds: weight band (Buff 1021 / 1023 / 1024), Starve -10% (Player.ts speeds)
	local Wt = Config.Weight
	local plr = Players.LocalPlayer
	local load = plr:GetAttribute("Load")
	local energy = plr:GetAttribute("Energy")
	local water = plr:GetAttribute("Water")
	local pct = 0
	if typeof(load) == "number" then
		if load <= Wt.light then
			pct += Wt.lightSpeed
		elseif load > Wt.over then
			pct += Wt.overSpeed
		elseif load > Wt.heavy then
			pct += Wt.heavySpeed
		end
	end
	if typeof(energy) == "number" and energy <= 0 then
		pct += Wt.starveSpeed
	end
	PC.moveability = if typeof(water) == "number" and water <= 0 then math.max(0, 1 + Wt.thirstMoveability) else 1
	-- Stun (flashbang / bear trap): Moveability -0.85
	local stunUntil = plr:GetAttribute("StunUntil")
	if typeof(stunUntil) == "number" and Workspace:GetServerTimeNow() < stunUntil then
		PC.moveability = math.max(0, PC.moveability - 0.85)
	end
	local mob = PC.moveability
	local walkEff = M.walk * math.max(0, 1 + pct) * mob * held
	local runEff = M.run * math.max(0, 1 + pct) * mob * held
	local adsMul = if PC.adsInput then (if gun then math.min(1, gun.AdsWalkSpeedMultiplier) else 0.5) else 1

	-- CA_Dash
	PC.triggerLock = math.max(0, PC.triggerLock - dt)
	if dodgeQueued and clock - dashEnd >= D.cooldown and PC.dodgeT <= 0 and not PC.blocked then
		if PC.stamina >= D.cost then
			spend(D.cost)
			PC.dodgeT = 1e-6
			PC.dodgeDir = if mag > 0 then intent / mag else Vector2.new(math.sin(PC.facing), math.cos(PC.facing))
			PC.facing = math.atan2(PC.dodgeDir.X, PC.dodgeDir.Y)
			PC.triggerLock = math.max(PC.triggerLock, D.triggerLock)
			Net.event("Dodge"):FireServer(PC.dodgeDir)
			dodgeSent = clock
		end
	end
	dodgeQueued = false

	-- run (Sprint Key Mode Hold): the key held; ADS clears
	local runHeld = not PC.blocked and (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) or Controls.runHeld())
	runToggle = runHeld and not adsHeld

	local moving = mag > 0.02 and PC.actionMove and walkEff > 0
	local ratio = PC.stamina / ST.max
	local canRun = PC.actionRun and runToggle and (ratio >= ST.runStartFrac or wasRunning) and PC.stamina > 0
	PC.sprinting = moving and canRun and PC.dodgeT <= 0
	wasRunning = PC.sprinting

	local vel = PC.vel
	if PC.dodgeT > 0 then
		PC.dodgeT += dt
		if PC.dodgeT > D.time then
			PC.dodgeT = 0
			dashEnd = clock
			handoff = true
		else
			local v = D.speed * Curve.sample(D.keys, math.clamp(PC.dodgeT / D.time, 0, 1))
			vel = PC.dodgeDir * v
		end
	end
	if PC.dodgeT <= 0 then
		if handoff then
			handoff = false
			vel = PC.dodgeDir * runEff
		else
			local speed = if PC.sprinting then runEff else walkEff * adsMul
			local want = if moving then intent / math.max(mag, 1) * speed * math.min(1, mag) else Vector2.zero
			if moving and mag > 0 then
				want = intent.Unit * speed * math.min(1, mag)
			end
			local acc = (if PC.sprinting then M.runAcc else M.walkAcc) * dt
			local dv = want - vel
			local l = dv.Magnitude
			vel = if l <= acc then want else vel + dv / l * acc
		end
	end
	PC.vel = vel

	-- the server hears footsteps from the run / ADS state (World.ts step radius; silent while aiming)
	if PC.sprinting ~= sentSprint then
		sentSprint = PC.sprinting
		Net.event("Sprint"):FireServer(sentSprint)
	end
	if PC.adsInput ~= sentAds then
		sentAds = PC.adsInput
		Net.event("Aim"):FireServer(sentAds)
	end

	-- stamina: run drain, recover after the delay (Player.ts STAMINA)
	if PC.sprinting then
		spend(ST.drain * dt)
	elseif clock - lastSpend >= ST.recoverDelay then
		PC.stamina = math.min(ST.max, PC.stamina + ST.recover * dt)
	end

	-- aim point on the character plane, facing
	local aim3 = CameraRig.cursorOnPlane(cursor.X, cursor.Y, Config.Body.aimPlane)
	PC.aim = Vector2.new(aim3.X, aim3.Z)
	local a = PC.aim - PC.pos
	local dAim = a.Magnitude
	local controlAim = PC.dodgeT <= 0 and PC.actionMove
	local isAiming = not PC.sprinting and controlAim
	local want: number? = nil
	if dAim > 0.6 and isAiming then
		if dAim >= Config.Body.muzzle + 0.25 then
			want = math.atan2(a.X, a.Y)
		end
	elseif moving and vel.Magnitude > 0.02 then
		want = math.atan2(vel.X, vel.Y)
	end
	if want then
		local d = math.atan2(math.sin(want - PC.facing), math.cos(want - PC.facing))
		local step = math.rad(if isAiming then M.aimTurn else M.turn) * (PC.moveability or 1) * dt
		PC.facing += math.clamp(d, -step, step)
	end

	-- drive the avatar's Humanoid with the computed velocity (the ramp, dodge curve and speeds above are the web's;
	-- the Humanoid resolves walls, steps and slopes) and turn it through the AlignOrientation at the decoded rate
	local hum = (r.Parent :: Instance):FindFirstChildOfClass("Humanoid")
	if hum then
		local sp = vel.Magnitude
		hum.WalkSpeed = sp * S
		hum:Move(if sp > 1e-3 then Vector3.new(vel.X / sp, 0, vel.Y / sp) else Vector3.zero, false)
	else
		local cur = r.AssemblyLinearVelocity
		r.AssemblyLinearVelocity = Vector3.new(vel.X * S, math.min(cur.Y, 0), vel.Y * S)
		r.AssemblyAngularVelocity = Vector3.zero
	end
	local align = r:FindFirstChild("Facing") :: AlignOrientation?
	if align then
		-- the root's LookVector (-Z) carries the facing (atan2(x, z), 0 = +z)
		align.CFrame = CFrame.Angles(0, PC.facing + math.pi, 0)
	end
end

--- for CharAnim: velocity in the body frame
function PC.animState(): any
	local sp = PC.vel.Magnitude
	local dx, dz = 0, 1
	if sp > 0.02 then
		local h = PC.vel.Unit
		local fx, fz = math.sin(PC.facing), math.cos(PC.facing)
		-- body right = (cos f, -sin f) in (x, z) for atan2(x, z) facing
		dx, dz = h.X * fz - h.Y * fx, h.X * fx + h.Y * fz
	end
	return {
		dt = 0,
		speed = sp,
		dirX = dx,
		dirZ = dz,
		aiming = PC.held == "gun" and PC.meleeAnim <= 0,
		melee = if PC.meleeAnim > 0 then math.max(1e-3, 1 - PC.meleeAnim) else 0,
		dodge = if PC.dodgeT > 0 then math.max(1e-3, PC.dodgeT / D.time) else 0,
		sprint = PC.sprinting,
	}
end

function PC.snap(x: number, z: number, facing: number?)
	PC.pos = Vector2.new(x, z)
	PC.vel = Vector2.zero
	if facing then
		PC.facing = facing
	end
end

return PC
