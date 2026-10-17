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
local Fx = require(script.Parent.Fx)

local player = Players.LocalPlayer
local Combat = {}

local held = false -- LMB down
local pressed = false -- a trigger press this frame
local fireCd = 0
local burstLeft = 0
local scatter = -1
local predictedMag: number? = nil
local predictUntil = 0

-- recoil state (Game.ts this.recoil)
local R = { x = 0, y = 0, v = 0, h = 0, time = 0.001, recoverTime = 0, recover = 0, timer = 0, fresh = false, needX = 0, needY = 0, shotX = 0, shotY = 0, opposite = 0, lastMx = 0 / 0, lastMy = 0 / 0 }

function Combat.triggerHeld(): boolean
	return held
end

local function mousePos(): Vector2
	local m = UserInputService:GetMouseLocation()
	-- GetMouseLocation includes the top bar inset; viewport rays want viewport pixels
	local inset = game:GetService("GuiService"):GetGuiInset()
	return Vector2.new(m.X, m.Y - inset.Y)
end

function Combat.cursor(): Vector2
	local m = mousePos()
	return Vector2.new(m.X + R.x, m.Y + R.y)
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
	local mz = Guns.muzzle(id, PC.pos.X, PC.pos.Y, PC.facing)
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
	Net.event("Fire"):FireServer(mz, yaws, slope)
	for _, a in yaws do
		Fx.tracer(mz, a, slope, g.BulletSpeed, Guns.range(g), true)
	end
	Fx.muzzle(mz, PC.facing)
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
	updateRecoil(dt)
	local id = player:GetAttribute("Gun")
	local g = if typeof(id) == "string" and PC.held == "gun" then Guns.row(id) else nil
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
	PC.actionRun = not reloading
	local auto = typeof(id) == "string" and Guns.auto(id)
	local want = if auto then held else pressed
	if g and want and fireCd <= 0 and PC.triggerLock <= 0 and not PC.dashing() and not reloading and not PC.blocked then
		if Combat.mag() > 0 then
			fire(g, id :: string)
		elseif pressed then
			Net.event("Reload"):FireServer()
		end
	end
	pressed = false
end

function Combat.start()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			held = true
			pressed = true
		elseif input.KeyCode == Enum.KeyCode.R then
			Net.event("Reload"):FireServer()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			held = false
		end
	end)
	Net.event("Fx").OnClientEvent:Connect(function(kind: string, a: any, b: any, c: any, d: any, e: any)
		if kind == "shot" then
			-- someone else's shot: a = muzzle (m), b = yaws, c = slope, d = speed, e = range
			for _, yaw in b do
				Fx.tracer(a, yaw, c, d, e, false)
			end
			Fx.muzzle(a, b[1])
		elseif kind == "impact" then
			Fx.impact(a, b)
		end
	end)
	Net.event("Hit").OnClientEvent:Connect(function(kill: boolean, crit: boolean, at: Vector3?, dmg: number?)
		Fx.hitMarker(kill, crit)
		if at and dmg then
			Fx.damageNumber(at, dmg, crit)
		end
	end)
end

return Combat
