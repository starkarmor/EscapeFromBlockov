--!strict
-- Collision groups for the map's Block flags (shared/Block.luau). Map parts are grouped by their "Cat":
-- M31 everything, M27 body+bullet (no sight), M1 bodies only, M4 sight only (foliage), M0 nothing. Queries use
-- QBullet (what stops a bullet) and QSight (what stops a look); characters use Chars.
local PhysicsService = game:GetService("PhysicsService")

local Physics = {}
local GROUPS = { "Ground", "M0", "M1", "M4", "M27", "M31", "MCover", "Chars", "QBullet", "QSight", "QSightHard", "QBody", "QBlast", "Grenade", "Smoke" }

function Physics.setup()
	for _, g in GROUPS do
		if not PhysicsService:IsCollisionGroupRegistered(g) then
			PhysicsService:RegisterCollisionGroup(g)
		end
	end
	local all = table.clone(GROUPS)
	table.insert(all, "Default")
	local function only(g: string, with: { string })
		for _, o in all do
			PhysicsService:CollisionGroupSetCollidable(g, o, table.find(with, o) ~= nil)
		end
	end
	-- characters pass through each other (World.ts resolveCircle: bodies collide with boxes only)
	only("Chars", { "Ground", "M1", "M27", "M31", "Default" })
	only("QBullet", { "M27", "M31" })
	only("QSight", { "M4", "M31" })
	only("QSightHard", { "M31" }) -- hurt searches see through foliage
	only("QBody", { "M1", "M27", "M31" })
	-- half cover (MCover): bodies and bullets, not sight, not explosions (CheckObsticle); grenades pass live cover
	only("MCover", { "Chars", "QBullet", "QBody" })
	-- explosion line of sight: walls, doors, ground (no half cover)
	only("QBlast", { "M27", "M31", "Ground" })
	-- grenade bodies: ground, walls, doors, foliage (World.grenadeSolid), not characters or live cover
	only("Grenade", { "Ground", "M1", "M4", "M27", "M31", "Default" })
	-- smoke clouds block sight only (the fan, AI searches and shoot checks), not bullets or explosions
	only("Smoke", { "QSight", "QSightHard" })
	only("M0", {})
	only("M4", { "QSight", "Grenade" })
end

return Physics
