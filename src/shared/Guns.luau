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

--- the held gun's stats with its fitted parts (the "GunAtt" attribute "Slot=part,..."; Inv.gunFeel)
function Guns.rowWith(id: string, att: string?): any
	if not att or att == "" then
		return Guns.feel[id]
	end
	local map = {}
	for k, v in string.gmatch(att, "(%w+)=([^,]+)") do
		map[k] = v
	end
	return require(script.Parent.Inv).gunFeel({ id = id, att = map })
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

--- data.ts ammoTypesFor: every ammo item of the gun's caliber (sorted by id for a stable order)
local typesCache: { [string]: { string } } = {}
function Guns.ammoTypesFor(gunId: string): { string }
	local it = Guns.items[gunId]
	local cal = it and it.fire and it.fire.caliber
	if not cal then
		return {}
	end
	if typesCache[cal] then
		return typesCache[cal]
	end
	local out = {}
	for id, d in Guns.items do
		if d.ammo and d.ammo.caliber == cal then
			table.insert(out, id)
		end
	end
	table.sort(out)
	typesCache[cal] = out
	return out
end

--- Player.loadedType: the rounds in the magazine (loaded, else the selected type, else the gun's default)
function Guns.loadedType(g: any): string?
	return g.loaded or g.sel or Guns.ammoOf(g.id)
end

--- Player.ammoTypeFor: the type the next reload loads: the selected / loaded / default type when carried, else the
--- first carried type of the caliber, else the wanted one (count = a function counting an ammo id in the backpack)
function Guns.ammoTypeFor(g: any, count: (string) -> number): string?
	local want = g.sel or g.loaded or Guns.ammoOf(g.id)
	if want and count(want) > 0 then
		return want
	end
	for _, id in Guns.ammoTypesFor(g.id) do
		if count(id) > 0 then
			return id
		end
	end
	return want
end

-- body.ts KIND_MODEL: the right-hand socket per kind (gz_holdpose models, model space x right, y up, z forward)
local KIND_MODEL = { player = "player", scrapper = "human", scav = "human", brute = "human", contractor = "human", boss = "boss",
	bloater = "bloater", drone = "drone", stormling = "stormling", wolf = "wolf", giant = "human", operator = "human" }
function Guns.hand(kind: string?): Vector3
	local m = Items.holdModels[KIND_MODEL[kind or "player"] or "human"] or Items.holdModels.human
	local h = m.rightHand or { 0.29, 0.52, 0.23 }
	return Vector3.new(h[1], h[2], h[3])
end

--- the gun agent's Muzzle socket (agent frame on the hand socket: x right, y up, z forward); nil when undecoded
function Guns.muzzleLocal(id: string?): Vector3?
	local m = id and Items.muzzle[id]
	return if m then Vector3.new(m[1], m[2], m[3]) else nil
end

--- body.ts muzzleWorld: the hand socket follows the body yaw `facing`, the muzzle offset turns with the aim yaw.
--- Without a decoded muzzle: 0.8 m ahead of the shooter at the hand height (Player.ts MUZZLE fallback).
--- Handedness: the web build keeps the source's left-handed (Unity) coordinates in a right-handed world, so its "right"
--- hand (+x while facing +z) is anatomically the left one. The avatars here hold the gun in their real right hand
--- (Dress.holdGun), so the lateral offsets are mirrored to come out of the gun that is drawn.
function Guns.muzzle(id: string, x: number, z: number, facing: number, aimYaw: number?, kind: string?): Vector3
	local h = Guns.hand(kind)
	local m = Guns.muzzleLocal(id)
	local ay = aimYaw or facing
	if not m then
		return Vector3.new(x + math.sin(ay) * 0.8, h.Y, z + math.cos(ay) * 0.8)
	end
	local fs, fc = math.sin(facing), math.cos(facing)
	local as, ac = math.sin(ay), math.cos(ay)
	local hx = x + (-h.X * fc + h.Z * fs)
	local hz = z + (h.X * fs + h.Z * fc)
	return Vector3.new(hx + (-m.X * ac + m.Z * as), h.Y + m.Y, hz + (m.X * as + m.Z * ac))
end

return Guns
