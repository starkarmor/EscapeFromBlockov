--!strict
-- Local gun handling with server authority: the software cursor with the source's recoil kick (Game.updateRecoil,
-- InputManager.ProcessMousePosViaRecoil), the trigger and cadence gate (World.fireGun), scatter grow / recover
-- (Player.update), predicted tracer + muzzle flash + camera kick; the server validates and owns ammo, hits and damage.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Guns = require(Shared.Guns)
local Net = require(Shared.Net)
local Config = require(Shared.Config)
local PC = require(script.Parent.PlayerControl)
local CameraRig = require(script.Parent.CameraRig)
local S = require(Shared.Units).S
local Fx = require(script.Parent.Fx)
local Vision = require(script.Parent.Vision)
local Sfx = require(script.Parent.Sfx)
local Controls = require(script.Parent.Controls)

local player = Players.LocalPlayer
local Combat = {}
Combat.onSound = function(_at: Vector3) end

local held = false -- LMB down
local padHeld = false -- RT / the touch aim stick (Controls)
local pressed = false -- a trigger press this frame
local fireCd = 0
local meleeCd = 0
local burstLeft = 0
local scatter = -1
local predictedMag: number? = nil
local predictUntil = 0

-- recoil state (Game.ts this.recoil)
local R = { x = 0, y = 0, v = 0, h = 0, time = 0.001, recoverTime = 0, recover = 0, timer = 0, fresh = false, needX = 0, needY = 0, shotX = 0, shotY = 0, opposite = 0, lastMx = 0 / 0, lastMy = 0 / 0 }

function Combat.triggerHeld(): boolean
	return held or padHeld
end

local function mousePos(): Vector2
	-- GetMouseLocation is already in viewport pixels (top bar included), the space ViewportPointToRay and the
	-- IgnoreGuiInset HUD use
	-- a gamepad / touch aim is a virtual cursor at the aim point (Controls)
	return Controls.cursor or UserInputService:GetMouseLocation()
end

function Combat.cursor(): Vector2
	local m = mousePos()
	return Vector2.new(m.X + R.x, m.Y + R.y)
end

--- current scatter in degrees (full cone) for the reticle spread
function Combat.scatterDeg(): number
	return math.max(0, scatter)
end

function Combat.mag(): number
	local m = player:GetAttribute("Mag")
	if predictedMag and os.clock() < predictUntil then
		return predictedMag
	end
	predictedMag = nil
	return if typeof(m) == "number" then m else 0
end

function Combat.reloading(): (boolean, number)
	local u = player:GetAttribute("ReloadUntil")
	local s = player:GetAttribute("ReloadStart")
	if typeof(u) == "number" and typeof(s) == "number" then
		local now = Workspace:GetServerTimeNow()
		if now < u then
			return true, (now - s) / math.max(0.01, u - s)
		end
	end
	return false, 0
end

local function updateRecoil(dt: number)
	local cam = Workspace.CurrentCamera
	local vp = cam.ViewportSize
	local W, H = vp.X, vp.Y
	local sc = H / 1440
	local m = mousePos()
	local mx, my = m.X, m.Y
	local ddx = if R.lastMx == R.lastMx then mx - R.lastMx else 0
	local ddy = if R.lastMy == R.lastMy then my - R.lastMy else 0
	R.lastMx, R.lastMy = mx, my
	local cx, cy = mx + R.x, my + R.y
	if R.fresh then
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local ps = if root then cam:WorldToViewportPoint(root.Position + Vector3.new(0, 1.75, 0)) else Vector3.new(W / 2, H / 2, 0)
		local dx, dy = cx - ps.X, cy - ps.Y
		local l = math.sqrt(dx * dx + dy * dy)
		if l == 0 then
			l = 1
		end
		dx /= l
		dy /= l
		R.shotX = dx * R.v - dy * R.h
		R.shotY = dy * R.v + dx * R.h
	end
	local kdt = dt
	if R.timer + kdt >= R.time then
		kdt = R.time - R.timer
	end
	if kdt > 0 then
		local sx = (R.shotX * kdt / R.time) * sc
		local sy = (R.shotY * kdt / R.time) * sc
		cx += sx
		cy += sy
		R.needX += sx
		R.needY += sy
		local kx = math.clamp(cx, 0, W) - cx
		local ky = math.clamp(cy, 0, H) - cy
		cx += kx
		cy += ky
		R.needX += kx
		R.needY += ky
	elseif R.timer > R.recoverTime and (R.needX ~= 0 or R.needY ~= 0) then
		local rdt = dt
		if R.timer - rdt < R.recoverTime then
			rdt = R.timer - R.recoverTime
		end
		local l = math.sqrt(R.needX * R.needX + R.needY * R.needY)
		local k = math.max(0, l - rdt * R.recover * sc) / l
		cx += R.needX * k - R.needX
		cy += R.needY * k - R.needY
		R.needX *= k
		R.needY *= k
	end
	local nl = math.sqrt(R.needX * R.needX + R.needY * R.needY)
	local against = if nl > 0 then -(R.needX * ddx + R.needY * ddy) / nl else 0
	if against > 0 then
		R.opposite = 0
		local k = math.max(0, nl - against) / nl
		R.needX *= k
		R.needY *= k
	else
		R.opposite += math.sqrt(ddx * ddx + ddy * ddy)
		if R.opposite > 15 * sc then
			R.opposite = 0
			R.needX, R.needY = 0, 0
		end
	end
	R.timer += dt
	R.fresh = false
	R.x = math.clamp(cx, 0, W) - mx
	R.y = math.clamp(cy, 0, H) - my
end

local function fire(g: any, id: string)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local B = math.max(1, math.floor((g.BurstCount or 1) + 0.5))
	if burstLeft <= 0 then
		burstLeft = B
	end
	burstLeft -= 1
	local aimYaw = math.atan2(PC.aim.X - PC.pos.X, PC.aim.Y - PC.pos.Y)
	local mz = Guns.muzzle(id, PC.pos.X, PC.pos.Y, PC.facing, aimYaw)
	local toAim = (PC.aim - PC.pos).Magnitude
	local aimed = toAim > (Vector2.new(mz.X, mz.Z) - PC.pos).Magnitude + 0.1
	local base = if aimed then math.atan2(PC.aim.X - mz.X, PC.aim.Y - mz.Z) else aimYaw
	local flat = math.max(1e-3, (PC.aim - Vector2.new(mz.X, mz.Z)).Magnitude)
	local slope = if aimed then (Config.Body.aimPlane - mz.Y) / flat else 0
	-- shotScatter: durability extra is the server's; the client uses the clean value for its prediction
	local scatterRad = math.rad(math.max(0, scatter))
	local n = math.max(1, math.floor((g.ShotCount or 1) + 0.5))
	local fanDeg = (g.ShotAngle or 0) * (if PC.adsInput then 0.5 else 1)
	local fan = math.rad(fanDeg)
	local step = if n > 1 then fan / (n - 1) else 0
	local yaws = {}
	for i = 0, n - 1 do
		local off = if n > 1 then -fan / 2 + i * step else 0
		yaws[i + 1] = base + off + (math.random() - 0.5) * scatterRad
	end
	-- crit: the cursor on an enemy head collider (InputManager.AimingEnemyHead)
	local c = Combat.cursor()
	local head = Vision.headUnder(c.X, c.Y) ~= nil
	Net.event("Fire"):FireServer(mz, yaws, slope, head)
	for _, a in yaws do
		Fx.tracer(mz, a, slope, g.BulletSpeed, Guns.range(g), true)
	end
	Fx.muzzle(mz, PC.facing, "#ffd27a", true, Vector3.new(PC.pos.X, 0, PC.pos.Y))
	-- World.fireGun: 'shotgun' for a multi-pellet shot
	Sfx.play(if n > 1 then "shotgun" elseif (g.ShootSpeed or 1) >= 8 then "rifle" else "pistol")
	predictedMag = math.max(0, Combat.mag() - 1)
	predictUntil = os.clock() + 0.5
	-- scatter grow, recoil, camera kick
	local def, max, grow = Guns.scatterNow(g, PC.ads)
	scatter = math.clamp(scatter + grow, def, max)
	local rv = (g.RecoilVMin + (g.RecoilVMax - g.RecoilVMin) * math.random()) * g.RecoilScaleV
	local rh = (g.RecoilHMin + (g.RecoilHMax - g.RecoilHMin) * math.random()) * g.RecoilScaleH
	R.v, R.h = rv, rh
	R.time = math.max(0.001, math.min(g.RecoilTime, 1 / g.ShootSpeed))
	R.recoverTime = g.RecoilRecoverTime
	R.recover = g.RecoilRecover
	R.timer = 0
	R.fresh = true
	CameraRig.shake(Config.Camera.shakePerShot, "recoil", Vector2.new(-math.sin(PC.facing), -math.cos(PC.facing)))
	if predictedMag <= 0 then
		burstLeft = 0
	end
	fireCd = Guns.cooldown(g, burstLeft)
end

function Combat.update(dt: number)
	-- RT / the touch aim stick: a press on its rising edge, held like LMB
	local pf = Controls.fireHeld()
	if pf and not padHeld then
		pressed = true
	end
	padHeld = pf
	updateRecoil(dt)
	local id = player:GetAttribute("Gun")
	local g = if typeof(id) == "string" and PC.held == "gun" then Guns.rowWith(id, game:GetService("Players").LocalPlayer:GetAttribute("GunAtt")) else nil
	PC.gun = g
	if g then
		local def, max, _, recover = Guns.scatterNow(g, PC.ads)
		if scatter < 0 then
			scatter = def
		end
		scatter = math.min(scatter, max)
		local rate = recover * (if scatter < def then 6 else 1)
		scatter += math.clamp(def - scatter, -rate * dt, rate * dt)
	end
	fireCd = math.max(0, fireCd - dt)
	local reloading = Combat.reloading()
	local using = player:GetAttribute("UseId") ~= nil
	-- ACTIONS: reload allows moving and running; an item use allows moving, not running
	PC.actionRun = not using
	if PC.held == "throw" then
		require(script.Parent.Throw).update(dt, (held or padHeld) and not PC.blocked)
		pressed = false
		return
	end
	if PC.held == "melee" then
		meleeCd = math.max(0, meleeCd - dt)
		if pressed and meleeCd <= 0 and not PC.dashing() and not PC.blocked and not using then
			local m = Config.Melee.stick
			meleeCd = 1 / m.attackSpeed
			PC.meleeAnim = 1
			Net.event("Melee"):FireServer()
			Sfx.play("swoosh")
			-- World.ts melee shake: dir (cos f + 0.3 ux, -sin f + 0.3 uz), (ux, uz) from a random unit sphere point
			local u = Vector3.new(math.random() * 2 - 1, math.random() * 2 - 1, math.random() * 2 - 1)
			u = if u.Magnitude > 1e-3 then u.Unit else Vector3.xAxis
			CameraRig.shake(0.05, "melee", Vector2.new(math.cos(PC.facing) + 0.3 * u.X, -math.sin(PC.facing) + 0.3 * u.Z))
		end
		pressed = false
		return
	end
	local auto = typeof(id) == "string" and Guns.auto(id)
	local want = if auto then (held or padHeld) else pressed
	if g and want and fireCd <= 0 and PC.triggerLock <= 0 and not PC.dashing() and not reloading and not PC.blocked and not using then
		if Combat.mag() > 0 then
			fire(g, id :: string)
		elseif pressed then
			Net.event("Reload"):FireServer()
		end
	end
	pressed = false
end

local function onKey(kc: Enum.KeyCode)
	if kc == Enum.KeyCode.R then
		Net.event("Reload"):FireServer()
	elseif kc == Enum.KeyCode.X then
		-- StopAction: cancels a reload, an item use, a hold or a throw aim
		Net.event("StopAction"):FireServer()
		require(script.Parent.Throw).cancel()
	end
end

function Combat.start()
	player:GetAttributeChangedSignal("ReloadUntil"):Connect(function()
		if player:GetAttribute("ReloadUntil") then
			Sfx.play("reload")
		end
	end)
	-- World.requestUse: audio 'use' when an item use starts
	player:GetAttributeChangedSignal("UseId"):Connect(function()
		if player:GetAttribute("UseId") then
			Sfx.play(if player:GetAttribute("UseId") == "bandage" then "bandage" else "use")
		end
	end)
	Workspace.AttributeChanged:Connect(function(name)
		if string.sub(name, 1, 5) == "Door_" then
			Sfx.play("door")
		end
	end)
	Net.event("Extracted").OnClientEvent:Connect(function()
		Sfx.play("extract")
	end)
	Net.event("Toast").OnClientEvent:Connect(function(_text: string, kind: string?)
		-- World: audio 'pickup' with every obtained item (the loose pick up)
		if kind == "obtained" then
			Sfx.play("pickup")
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			held = true
			pressed = true
		elseif input.KeyCode == Enum.KeyCode.R or input.KeyCode == Enum.KeyCode.X then
			onKey(input.KeyCode)
		end
	end)
	-- the gamepad's Y / B and the touch Reload / Cancel buttons
	Controls.onKey(function(kc, down)
		if down and not PC.blocked then
			onKey(kc)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			held = false
		end
	end)
	-- a release outside the window never arrives as InputEnded: losing focus lets go of the trigger
	UserInputService.WindowFocusReleased:Connect(function()
		held = false
	end)
	Net.event("Fx").OnClientEvent:Connect(function(kind: string, a: any, b: any, c: any, d: any, e: any, f: any)
		if kind == "hit" then
			-- World: the player hit by a bullet / blow plays 'death' when it killed, else 'hurt' (ticks stay silent)
			if a.me then
				Sfx.play(if a.kill then "death" else "hurt")
			end
			Fx.hit(a)
			if a.mine or a.me then
				Fx.damageNumber(a.at, a.dmg, a.crit)
			end
			return
		end
		if kind == "tick" then
			-- a = the tick's damage: the number over the player at 3.2 m
			local r = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r and typeof(a) == "number" then
				Fx.damageNumber(Vector3.new(r.Position.X / S, 1.2, r.Position.Z / S), a, false)
			end
			return
		elseif kind == "phurt" then
			-- a = the hurt character, b = damage, c = it is me: the orange flash (+ the number for its owner)
			if typeof(a) == "Instance" and a:IsA("Model") then
				Fx.hitFlash(a, Color3.fromHex("#ffb347"))
				local r = a:FindFirstChild("HumanoidRootPart") :: BasePart?
				if c and r and typeof(b) == "number" then
					Fx.damageNumber(Vector3.new(r.Position.X / S, 0.615, r.Position.Z / S), b, false)
				end
			end
			return
		end
		if kind == "shot" then
			-- someone else's shot: a = muzzle (m), b = yaws, c = slope, d = speed, e = range, f = the muzzle flash colour
			for _, yaw in b do
				Fx.tracer(a, yaw, c, d, e, false, f)
			end
			-- a shot outside the view cone shows as a sound marker (WorldUI sound markers)
			local rel = Vector2.new(a.X, a.Z) - PC.pos
			if rel.Magnitude > 2 and rel.Magnitude < e * 2 then
				local ang = math.atan2(rel.X, rel.Y)
				local off = math.abs(math.atan2(math.sin(ang - PC.facing), math.cos(ang - PC.facing)))
				if off > math.rad(50) or rel.Magnitude > 37 then
					Combat.onSound(a)
				end
			end
			Fx.muzzle(a, b[1], f, false)
			Sfx.at(if #b > 1 then "shotgun" elseif d >= 100 then "rifle" else "pistol", a, 60)
		elseif kind == "explode" or kind == "flash" then
			-- a = centre (m), b = radius, c = the item's shake factor (World.blast: 0.4 x shake within 30 m)
			Fx.explode(a, b)
			local dist = (Vector2.new(a.X, a.Z) - PC.pos).Magnitude
			if dist < 30 and (c or 1) > 0 then
				CameraRig.shake(0.4 * (c or 1), "explosion", Vector2.new(a.X - PC.pos.X, a.Z - PC.pos.Y))
			end
			local snd = Instance.new("Sound")
			snd.SoundId = "rbxasset://sounds/impact_explosion_03.mp3"
			snd.Volume = 0.8
			snd.Parent = game:GetService("SoundService")
			snd:Play()
			task.delay(4, function()
				snd:Destroy()
			end)
		elseif kind == "impact" then
			-- the burst comes from the local bullet arriving there (Fx.tracer)
			Sfx.at("impact", a, 25)
		elseif kind == "debris" then
			Fx.debris(a)
			Sfx.at("impact", a, 25)
		end
	end)
	-- hit marker for the player's own hits (damage > 1.01 or a kill); the number comes with the "hit" fx
	Net.event("Hit").OnClientEvent:Connect(function(kill: boolean, crit: boolean, _at: Vector3?, dmg: number?)
		-- World.damageEnemy: audio 'kill' / 'hit'
		Sfx.play(if kill then "kill" else "hitmarker")
		if kill or (dmg or 0) > 1.01 then
			Fx.hitMarker(kill, crit)
		end
	end)
end

return Combat
