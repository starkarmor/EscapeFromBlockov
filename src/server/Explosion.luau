--!strict
-- ExplosionManager.CreateExplosion (World.blast, spec docs/grenades-cover-ai-items-spec.md §1 "Blast"): flat damage, no
-- distance falloff. Characters within radius + their hit radius are hit once, with a clear line from the blast centre
-- (walls, doors, ground; half cover does not shield), skipping dodging characters and allied teams (team 7 = everyone,
-- the thrower included). Armor applies unless ignoreArmor (the targets' own hurt does the armor and AI-vs-AI maths).
-- Barrels and covers / walls in range take the blast too; the clients draw it and shake within 30 m.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Weapons = require(script.Parent.Weapons)
local Cover = require(script.Parent.Cover)

local S = Units.S
local Explosion = {}

local los = RaycastParams.new()
los.CollisionGroup = "QBlast"
los.FilterType = Enum.RaycastFilterType.Exclude

local function isEnemyTeam(a: number, b: number): boolean
	if a == 5 or b == 5 then
		return false
	end
	if a == 7 then
		return true
	end
	return a ~= b
end

export type Opts = {
	team: number?, -- 7 (default) hurts everyone
	ap: number?,
	armorBreak: number?,
	ignoreArmor: boolean?,
	from: Player?,
	fromRef: any,
	fromName: string?,
	weaponId: string?,
	shake: number?,
	stun: number?, -- seconds of Stun (Moveability -0.85)
	ai: boolean?, -- an AI thrower: cover takes half
	fx: string?, -- "explode" (default), "flash", "none"
}

function Explosion.blast(x: number, z: number, radius: number, damage: number, o: Opts)
	local team = o.team or 7
	for _, p in Players:GetPlayers() do
		Net.event("Fx"):FireClient(p, o.fx or "explode", Vector3.new(x, 0, z), radius, o.shake or 1)
	end
	local centre = Vector3.new(x, 0.5, z) * S
	for key, t in Weapons.targets do
		if t.kind == "breakable" then
			local tp = t.pos()
			if tp and (Vector2.new(tp.X, tp.Z) - Vector2.new(x, z)).Magnitude <= radius + t.radius then
				task.spawn(t.hurt, damage, { explosion = true, from = o.from, fromRef = o.fromRef })
			end
			continue
		end
		if not isEnemyTeam(team, t.team) then
			continue
		end
		if typeof(key) == "Instance" and Weapons.isDodging and Weapons.isDodging(key) then
			continue
		end
		local tp = t.pos()
		if not tp then
			continue
		end
		local d = (Vector2.new(tp.X, tp.Z) - Vector2.new(x, z)).Magnitude
		if d > radius + t.radius then
			continue
		end
		local target = Vector3.new(tp.X, 0.5, tp.Z) * S
		if d > 0.05 and Workspace:Raycast(centre, target - centre, los) then
			continue
		end
		if damage > 0 then
			local info = {
				explosion = true,
				pen = o.ap or 0,
				armorBreak = o.armorBreak or 0,
				direct = o.ignoreArmor,
				from = o.from,
				fromRef = o.fromRef,
				fromName = o.fromName or "Explosion",
				weaponId = o.weaponId,
				stun = o.stun,
			}
			task.spawn(function()
				local killed = t.hurt(damage, info)
				Weapons.broadcastHit(t, Vector3.new(tp.X, 0.7, tp.Z), damage, false, killed, o.from, false)
			end)
		elseif o.stun and t.stun then
			t.stun(o.stun)
		end
	end
	if damage > 0 then
		Cover.blast(x, z, radius, damage, o.ai == true)
	end
end

return Explosion
