--!strict
-- Throwing (World.handleThrow / throwAim, spec docs/grenades-cover-ai-items-spec.md §1): a hotbar throwable (keys 3-8)
-- becomes the held item; LMB held aims (throwAim: can move, cannot run), release throws once the item's readyTime has
-- passed (else it cancels and the item is kept), 0.5 s cooldown; X cancels. While selected / aiming the 3D preview shows
-- 14 white dots along the arc to the clamped target and a blue ring of the blast radius (0.35 selected, 0.6 aiming,
-- 0.95 ready).
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Items = require(Shared.gen.Items)
local PC = require(script.Parent.PlayerControl)

local S = Units.S
local Throw = {}
Throw.id = nil :: string?

local G = 15
local HAND = Vector3.new(0.2594, 0.5491, 0.2883)
local DOTS = 14
local aimT = -1
local wasHeld = false
local cd = 0
local dots: { Part } = {}
local ring: Part? = nil

local function bagCount(id: string): number
	local raw = Players.LocalPlayer:GetAttribute("Bag")
	if typeof(raw) ~= "string" then
		return 0
	end
	local n = 0
	for part in string.gmatch(raw, "[^,]+") do
		local iid, cnt = string.match(part, "^([^:]+):(%d+)")
		if iid == id then
			n += tonumber(cnt) or 0
		end
	end
	return n
end
Throw.count = bagCount

local function folder(): Instance
	return Workspace:FindFirstChild("LocalFx") or Workspace
end

local function ensure()
	if ring then
		return
	end
	for i = 1, DOTS do
		local d = Instance.new("Part")
		d.Name = "ThrowDot"
		d.Shape = Enum.PartType.Ball
		d.Anchored = true
		d.CanCollide = false
		d.CanQuery = false
		d.CanTouch = false
		d.CastShadow = false
		d.Material = Enum.Material.Neon
		d.Color = Color3.new(1, 1, 1)
		d.Size = Vector3.one * 0.18 * S
		dots[i] = d
	end
	local r = Instance.new("Part")
	r.Name = "ThrowRing"
	r.Shape = Enum.PartType.Cylinder
	r.Anchored = true
	r.CanCollide = false
	r.CanQuery = false
	r.CanTouch = false
	r.CastShadow = false
	r.Material = Enum.Material.Neon
	r.Color = Color3.fromHex("#3c8cff")
	ring = r
end

local function hide()
	for _, d in dots do
		d.Parent = nil
	end
	if ring then
		ring.Parent = nil
	end
end

function Throw.select(id: string)
	if bagCount(id) <= 0 then
		return false
	end
	Throw.id = id
	PC.held = "throw"
	aimT = -1
	return true
end

function Throw.cancel()
	aimT = -1
end

function Throw.aiming(): boolean
	return aimT >= 0
end

--- per frame: lmb = the fire button is held
function Throw.update(dt: number, lmb: boolean)
	cd = math.max(0, cd - dt)
	local id = Throw.id
	local row = id and Items.throw[id]
	if PC.held ~= "throw" or not row or not id then
		aimT = -1
		wasHeld = lmb
		hide()
		return
	end
	if bagCount(id) <= 0 then
		-- the last one is gone: back to firearm 1
		PC.held = "gun"
		PC.slot = 1
		Net.event("SelectSlot"):FireServer("gun")
		hide()
		return
	end
	if lmb and not wasHeld and cd <= 0 and not PC.blocked and not PC.dashing() then
		aimT = 0
	end
	if aimT >= 0 then
		aimT += dt
		PC.actionRun = false
		if PC.blocked or PC.dashing() then
			aimT = -1
		end
	end
	if not lmb and wasHeld and aimT >= 0 then
		if aimT >= row.readyTime then
			Net.event("Throw"):FireServer(id, PC.aim)
			-- World.handleThrow: audio 'melee' (the swing whoosh)
			require(script.Parent.Sfx).play("throw")
			cd = 0.5
		end
		aimT = -1
	end
	wasHeld = lmb
	-- preview: the launch maths of the server (Grenades.launch) from the hand to the clamped target
	ensure()
	local f = PC.facing
	local s, c = math.sin(f), math.cos(f)
	local hand = Vector3.new(PC.pos.X + HAND.Z * s + HAND.X * c, HAND.Y, PC.pos.Y + HAND.Z * c - HAND.X * s)
	local to = PC.aim - Vector2.new(hand.X, hand.Z)
	local dist = math.min(to.Magnitude, row.castRange)
	local dir = if to.Magnitude > 1e-3 then to.Unit else Vector2.new(s, c)
	local target = Vector2.new(hand.X, hand.Z) + dir * dist
	local V = row.vy or 5
	local up = V / G
	local down = math.sqrt(math.abs(2 * (up * V * 0.5 + hand.Y - 0.5)) / G)
	local T = up + down
	local h = dist / T
	local aiming = aimT >= 0
	for i, d in dots do
		if aiming then
			local t = (i / (DOTS + 1)) * T
			local p = Vector3.new(hand.X + dir.X * h * t, hand.Y + V * t - 0.5 * G * t * t, hand.Z + dir.Y * h * t)
			d.CFrame = CFrame.new(p * S)
			d.Parent = folder()
		else
			d.Parent = nil
		end
	end
	local r = ring :: Part
	local rr = row.effectRange or 1
	r.Size = Vector3.new(0.05, rr * 2 * S, rr * 2 * S)
	r.CFrame = CFrame.new(target.X * S, 0.08 * S, target.Y * S) * CFrame.Angles(0, 0, math.pi / 2)
	r.Transparency = 1 - (if not aiming then 0.35 elseif aimT >= row.readyTime then 0.95 else 0.6) * 0.5
	r.Parent = folder()
end

return Throw
