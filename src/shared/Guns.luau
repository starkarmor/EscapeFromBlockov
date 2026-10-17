--!strict
-- Gun math shared by client prediction and server authority, from the raw gz_gunfeel rows (gen/Items.luau gunFeel):
-- scatterNow (src/game/data.ts), cadence (World.fireGun), bullet speed / range / damage falloff, the muzzle.
local Items = require(script.Parent.gen.Items)

local Guns = {}
Guns.feel = Items.gunFeel :: { [string]: any }
Guns.items = Items.items :: { [string]: any }

function Guns.row(id: string): any
	return Guns.feel[id]
end

--- data.ts scatterNow: degrees (full cone width)
function Guns.scatterNow(g: any, ads: number): (number, number, number, number)
	local t = math.clamp(ads, 0, 1)
	local function L(a: number, b: number): number
		return a + (b - a) * t
	end
	local grow = L(g.ScatterGrow * g.ScatterFactor, g.ScatterGrowADS * g.ScatterFactorADS)
	local def = L(g.DefaultScatter * g.ScatterFactor, g.DefaultScatterADS * g.ScatterFactorADS)
	local max = L(g.MaxScatter * g.ScatterFactor, g.MaxScatterADS * g.ScatterFactorADS)
	local recover = L(g.ScatterRecover, g.ScatterRecoverADS) * grow * g.ShootSpeed
	return def, max, grow, recover
end

--- seconds to the next trigger event after a shot (World.fireGun cadence)
function Guns.cooldown(g: any, burstLeft: number): number
	local B = math.max(1, math.floor((g.BurstCount or 1) + 0.5))
	local ss = g.ShootSpeed
	return if burstLeft > 0 then (1 / ss) * (B / (B + 2)) else (1 / ss) * ((3 * B) / (B + 2))
end

function Guns.range(g: any): number
	return g.BulletDistance + 0.4
end

--- automatic fire: gz_gunagent trigger mode is not generated yet; rpm-based guess matches the web's FIREARMS.auto
function Guns.auto(id: string): boolean
	local it = Guns.items[id]
	return it ~= nil and it.fire ~= nil and it.fire.auto == true
end

function Guns.ammoOf(id: string): string?
	local it = Guns.items[id]
	return it and it.fire and it.fire.ammo
end

--- muzzle in model space (metres): the decoded right-hand socket (gz_holdpose models.player) + the gun's length
local HAND = Vector3.new(0.2904, 0.5244, 0.2347)
function Guns.muzzle(id: string, x: number, z: number, facing: number): Vector3
	local it = Guns.items[id]
	local len = (it and it.fire and it.fire.length) or 0.5
	local lx, ly, lz = HAND.X * 0, HAND.Y, HAND.Z + len
	local s, c = math.sin(facing), math.cos(facing)
	-- model +z = facing (sin f, cos f); model +x = (cos f, -sin f)
	return Vector3.new(x + lz * s + lx * c, ly, z + lz * c - lx * s)
end

return Guns
