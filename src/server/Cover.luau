--!strict
-- Half cover and breakable walls (World.damageCover / Breakables.ts, spec docs/grenades-cover-ai-items-spec.md §2).
--   Half cover (MapData.covers, 75 HP): blocks bodies and bullets, not sight or explosions. Player bullets deal their
--   damage x falloff, enemy bullets x0.5, player melee its damage (x crit), AI melee x0.5, explosions their flat damage
--   (x0.5 from AI throwers) when the nearest point of the box is within the radius. At 0 HP the pieces drop to rubble:
--   y x0.3, rubble colour, no longer bullet blocking (rubble taller than the 0.25 m step still blocks bodies).
--   Breakable walls (MapData.walls, 30 HP, explosions only): at 0 the wall opens (flag wall / wall2, toast).
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local MapData = require(Shared.MapData)

local S = Units.S
local Cover = {}

type CoverRec = { id: number, boxes: { any }, hp: number, parts: { BasePart }, dead: boolean }
type WallRec = { id: number, name: string, flag: string, hp: number, cf: CFrame, size: Vector3, parts: { BasePart }, dead: boolean }
local covers: { CoverRec } = {}
local walls: { WallRec } = {}
local RUBBLE = Color3.fromHex("#6b645a")
local STEP = 0.25

Cover.onFlag = nil :: ((string) -> ())? -- Loot: persist the opened wall flag

local function breakCover(c: CoverRec)
	c.dead = true
	for _, p in c.parts do
		local h = p.Size.Y * 0.3
		local base = p.Position.Y - p.Size.Y / 2
		p.Size = Vector3.new(p.Size.X, h, p.Size.Z)
		p.CFrame = p.CFrame.Rotation + Vector3.new(p.Position.X, base + h / 2, p.Position.Z)
		p.Color = RUBBLE
		p.CanQuery = false
		-- rubble: grenades rest on it (Grenade group); bodies only while it stands taller than the step offset
		p.CollisionGroup = if h / S > STEP then "M1" else "M0"
		p.CanCollide = h / S > STEP
		p:SetAttribute("Cover", nil)
	end
	for _, pl in Players:GetPlayers() do
		Net.event("Fx"):FireClient(pl, "debris", Vector3.new((c.boxes[1].minX + c.boxes[1].maxX) / 2, 0.5, (c.boxes[1].minZ + c.boxes[1].maxZ) / 2))
	end
end

function Cover.damage(id: number, dmg: number)
	local c = covers[id]
	if not c or c.dead or dmg <= 0 then
		return
	end
	c.hp -= dmg
	if c.hp <= 0 then
		breakCover(c)
	end
end

--- the cover a map part belongs to (bullet hits)
function Cover.of(part: Instance?): number?
	local id = part and part:GetAttribute("Cover")
	return if typeof(id) == "number" then id else nil
end

local function nearestDist(c: CoverRec, x: number, z: number): number
	local best = math.huge
	for _, b in c.boxes do
		local px, pz = math.clamp(x, b.minX, b.maxX), math.clamp(z, b.minZ, b.maxZ)
		best = math.min(best, math.sqrt((px - x) ^ 2 + (pz - z) ^ 2))
	end
	return best
end

--- melee into cover: within reach and in the frontal half
function Cover.melee(x: number, z: number, facing: number, reach: number, dmg: number)
	local fwd = Vector2.new(math.sin(facing), math.cos(facing))
	for _, c in covers do
		if not c.dead and nearestDist(c, x, z) <= reach then
			local b = c.boxes[1]
			local d = Vector2.new((b.minX + b.maxX) / 2 - x, (b.minZ + b.maxZ) / 2 - z)
			if d.Magnitude < 1e-3 or d.Unit:Dot(fwd) >= 0 then
				Cover.damage(c.id, dmg)
			end
		end
	end
end

local function breakWall(w: WallRec)
	w.dead = true
	for _, p in w.parts do
		p.CanCollide = false
		p.CanQuery = false
		p.Transparency = 1
		p.CollisionGroup = "M0"
	end
	-- the rubble left at the foot of the opening
	local rubble = Instance.new("Part")
	rubble.Name = "WallRubble"
	rubble.Anchored = true
	rubble.CanCollide = false
	rubble.CanQuery = false
	rubble.Size = Vector3.new(w.size.X, 0.25 * S, w.size.Z * 1.6)
	rubble.CFrame = w.cf.Rotation + Vector3.new(w.cf.Position.X, 0.125 * S, w.cf.Position.Z)
	rubble.Color = RUBBLE
	rubble.Parent = Workspace:FindFirstChild("GroundZero") or Workspace
	if Cover.onFlag then
		Cover.onFlag(w.flag)
	end
	for _, pl in Players:GetPlayers() do
		Net.event("Toast"):FireClient(pl, "Wall Destroyed", "good")
		Net.event("Fx"):FireClient(pl, "debris", Vector3.new(w.cf.Position.X / S, 1, w.cf.Position.Z / S))
	end
end

--- an explosion (flat damage) into every cover and wall in range; `ai` halves cover damage (AI thrower)
function Cover.blast(x: number, z: number, radius: number, dmg: number, ai: boolean)
	for _, c in covers do
		if not c.dead and nearestDist(c, x, z) <= radius then
			Cover.damage(c.id, dmg * (if ai then 0.5 else 1))
		end
	end
	for _, w in walls do
		if not w.dead then
			-- distance from the blast to the receiver box (in its own frame)
			local lp = w.cf:PointToObjectSpace(Vector3.new(x * S, w.cf.Position.Y, z * S))
			local hx, hz = w.size.X / 2, w.size.Z / 2
			local dx = math.max(0, math.abs(lp.X) - hx)
			local dz = math.max(0, math.abs(lp.Z) - hz)
			if math.sqrt(dx * dx + dz * dz) / S <= radius then
				w.hp -= dmg
				if w.hp <= 0 then
					breakWall(w)
				end
			end
		end
	end
end

function Cover.start(flags: { [string]: boolean }?)
	local map = Workspace:WaitForChild("GroundZero")
	local candidates: { BasePart } = {}
	for _, d in map:GetDescendants() do
		if d:IsA("BasePart") and d.CanCollide then
			local k = d:GetAttribute("Kind")
			if k == "cover" or k == "body" or k == "full" or k == "wall" or k == "prop" then
				table.insert(candidates, d)
			end
		end
	end
	-- covers: the collider pieces whose centre lies in the cover box and that stay under its top
	local bound = 0
	for i, c in MapData.covers or {} do
		local rec: CoverRec = { id = i, boxes = c.boxes, hp = c.maxHp or 75, parts = {}, dead = false }
		for _, p in candidates do
			local x, z = p.Position.X / S, p.Position.Z / S
			local top = (p.Position.Y + p.Size.Y / 2) / S
			for _, b in c.boxes do
				if x >= b.minX - 0.1 and x <= b.maxX + 0.1 and z >= b.minZ - 0.1 and z <= b.maxZ + 0.1 and top <= (b.h or c.h or 1.2) + 0.35 then
					table.insert(rec.parts, p)
					p:SetAttribute("Cover", i)
					p.CollisionGroup = "MCover"
					break
				end
			end
		end
		if #rec.parts > 0 then
			bound += 1
		else
			-- no drawn piece found: an invisible collider of the decoded box
			for _, b in c.boxes do
				local p = Instance.new("Part")
				p.Name = "CoverBox"
				p.Anchored = true
				p.Transparency = 1
				p.Size = Vector3.new(b.maxX - b.minX, b.h or 1.17, b.maxZ - b.minZ) * S
				p.CFrame = CFrame.new((b.minX + b.maxX) / 2 * S, (b.h or 1.17) * S / 2, (b.minZ + b.maxZ) / 2 * S)
				p.CollisionGroup = "MCover"
				p:SetAttribute("Cover", i)
				p.Parent = map
				table.insert(rec.parts, p)
			end
		end
		covers[i] = rec
	end
	-- breakable walls: the pieces inside the receiver box; an invisible obstacle when none was drawn
	for i, w in MapData.walls or {} do
		local size = Vector3.new(w.size[1], w.size[2], w.size[3]) * S
		local cf = CFrame.new(w.x * S, size.Y / 2, w.z * S) * CFrame.Angles(0, math.rad(w.yaw), 0)
		local rec: WallRec = { id = i, name = w.name, flag = w.flag, hp = w.hp, cf = cf, size = size, parts = {}, dead = false }
		for _, p in candidates do
			local lp = cf:PointToObjectSpace(p.Position)
			if math.abs(lp.X) <= size.X / 2 + 0.2 and math.abs(lp.Z) <= size.Z / 2 + 0.6 then
				table.insert(rec.parts, p)
			end
		end
		if #rec.parts == 0 then
			local body = w.body or w.size
			local p = Instance.new("Part")
			p.Name = "BreakableWall"
			p.Anchored = true
			p.Size = Vector3.new(body[1], 2.6, body[3]) * S
			p.CFrame = cf.Rotation + Vector3.new(cf.Position.X, 1.3 * S, cf.Position.Z)
			p.Color = Color3.fromHex("#8a8378")
			p.CollisionGroup = "M31"
			p:SetAttribute("Cat", 31)
			p.Parent = map
			table.insert(rec.parts, p)
		end
		walls[i] = rec
		if flags and flags[w.flag] then
			breakWall(rec)
		end
	end
	print(string.format("[Blockov] %d half covers (%d bound to drawn pieces), %d breakable walls", #covers, bound, #walls))
end

return Cover
