--!strict
-- Player lifecycle in the Ground Zero raid (Game.deploy / resolveDeath / resolveExtract, World.handleExtraction):
-- deploy at Special/BunkerEntry (the entrance) with the starting kit (Profile.defaultProfile: TT-33 with 8 rusty rounds,
-- stick, bandages and the guide starter items), HP 40, the raid clock from 08:00 at 40x, the extraction pad (3 m, stand
-- 5 s, leaving cancels), the bunker hatch (hold 1 s) as the other way out; death drops everything in a lootable corpse
-- for one recovery; extraction banks the backpack into the stash (DataStore when available).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Guns = require(Shared.Guns)
local MapData = require(Shared.MapData)
local Avatar = require(script.Parent.Avatar)
local Weapons = require(script.Parent.Weapons)
local Inv = require(Shared.Inv)

local S = Units.S
local Raid = {}

export type Stack = Inv.Inst
export type Profile = {
	stash: { Stack },
	money: number,
	xp: number?,
	raids: number,
	extracts: number,
	deaths: number,
}
export type RaidState = {
	hp: number,
	maxHp: number,
	energy: number,
	water: number,
	-- Profile.ts Equipment: firearm1 firearm2 melee head body face headset backpack totem1 totem2 -> Inst
	eq: { [string]: Stack? },
	-- the backpack: positional Insts (src/shared/Inv.luau)
	bag: { Stack },
	-- hotbar shortcuts 3..8: item ids ("" = empty); locks (Inventory.lockedIndexes); wishlist ids
	hotbar: { string },
	locks: { number },
	wish: { string },
	alive: boolean,
	inRaid: boolean,
	dodgeAt: number,
	extractT: number,
	startedAt: number,
}

local profiles: { [Player]: Profile } = {}
local raids: { [Player]: RaidState } = {}
Raid.raids = raids
Raid.profiles = profiles

local store: DataStore? = nil
pcall(function()
	store = DataStoreService:GetDataStore("Canuckov_Profiles_v1")
end)

local charFolder = Workspace:FindFirstChild("Characters") or Instance.new("Folder")
charFolder.Name = "Characters"
charFolder.Parent = Workspace

local raidStart = os.clock()

-- the starting kit (Profile.ts defaultProfile + the guide starter boxes)
local function starterKit(): ({ [string]: Stack? }, { Stack })
	local eq: { [string]: Stack? } = { firearm1 = { id = "tt33", n = 1, ammo = 8, dur = 100, loaded = "ammo_s_rusty" }, melee = { id = "stick", n = 1 } }
	local bag: { Stack } = {
		{ id = "ammo_s_rusty", n = 30, pos = 0 },
		{ id = "bandage", n = 3, pos = 1 },
		{ id = "aspirin", n = 1, pos = 2 },
		{ id = "carrot", n = 1, pos = 3 },
		{ id = "cocoa", n = 1, pos = 4 },
	}
	return eq, bag
end

--- the backpack capacity (Profile.bagCapacity: 10 + backpack + body armor slots)
function Raid.cap(r: RaidState): number
	return Inv.bagCapacity(r.eq)
end

local function loadProfile(p: Player): Profile
	local prof: Profile = { stash = {}, money = 0, raids = 0, extracts = 0, deaths = 0 }
	if store and p.UserId > 0 then
		local ok, data = pcall(function()
			return (store :: DataStore):GetAsync("u" .. p.UserId)
		end)
		if ok and typeof(data) == "table" then
			for k, v in data do
				(prof :: any)[k] = v
			end
		end
	end
	-- the game clock (minutes, 08:00 day 0) and the weather seed persist per save (Profile.ts clock, weatherSeed)
	local x = prof :: any
	x.clock = x.clock or 8 * 60
	x.weatherSeed = x.weatherSeed or math.random(0, 99999)
	return prof
end

local function saveProfile(p: Player)
	local prof0 = profiles[p]
	if prof0 then
		(prof0 :: any).clock = require(script.Parent.Weather).clock
	end
	local prof = profiles[p]
	if not prof or not store or p.UserId <= 0 then
		return
	end
	pcall(function()
		(store :: DataStore):SetAsync("u" .. p.UserId, prof)
	end)
end

-- backpack helpers (Profile.addItem / countItem / removeItem on positional lists); `cap` defaults to unlimited
-- (the warehouse, corpse lists). Returns the count added.
function Raid.addItem(bag: { Stack }, id: string, n: number, cap: number?): number
	return n - Inv.addItem(bag, id, n, cap or 100000)
end

function Raid.count(bag: { Stack }, id: string): number
	return Inv.count(bag, id)
end

function Raid.take(bag: { Stack }, id: string, n: number): number
	return Inv.remove(bag, id, n)
end

-- data.ts NIGHT_VISION (face goggles toggle with N; head lamps always on) and NIGHT.flashlight (+0.3 from a light on the
-- held gun)
local NIGHT_VISION = {
	night_vision_goggles = { ability = 1, type = 1, toggle = true },
	thermal_vision_goggles = { ability = 1, type = 2, toggle = true },
	head_lantern = { ability = 0.25, type = 0, toggle = false },
	helmet_storm = { ability = 0.3, type = 0, toggle = false },
	helmat_pumpkin_light = { ability = 0.4, type = 0, toggle = false },
}
local FLASHLIGHT_PARTS = { tec_flashlight_non_1 = true }

--- Player.nightVision(nvgOn): ability, type, and whether the face item is a toggled goggle
function Raid.nightVision(r: RaidState): (number, number, boolean)
	local ability, kind = 0, 0
	local face = r.eq.face and NIGHT_VISION[r.eq.face.id]
	local on = (r :: any).nvgOn ~= false
	if face and (not face.toggle or on) then
		ability += face.ability
		kind = face.type
	end
	local head = r.eq.head and NIGHT_VISION[r.eq.head.id]
	if head then
		ability += head.ability
	end
	local x = r :: any
	local g = if x.held == "gun2" then r.eq.firearm2 elseif x.held == "gun" or x.held == nil then r.eq.firearm1 else nil
	if g and g.att then
		for _, id in g.att do
			if FLASHLIGHT_PARTS[id] then
				ability += 0.3
				break
			end
		end
	end
	return ability, kind, face ~= nil and face.toggle
end

--- the armor value of worn gear (GEAR armor / headArmor)
local function armorOf(inst: Stack?): number
	local d = inst and Guns.items[inst.id]
	local g = d and d.gear
	return (g and (g.armor or g.headArmor)) or 0
end

local function syncVitals(p: Player)
	local r = raids[p]
	if not r then
		return
	end
	p:SetAttribute("HP", r.hp)
	p:SetAttribute("MaxHP", r.maxHp)
	p:SetAttribute("Energy", r.energy)
	p:SetAttribute("Water", r.water)
	p:SetAttribute("Alive", r.alive)
	local w = 0
	for _, inst in r.eq do
		local def = Guns.items[inst.id]
		w += (def and def.weight or 0) * inst.n
	end
	for _, s in r.bag do
		local def = Guns.items[s.id]
		w += (def and def.weight or 0) * s.n
	end
	local carry = Config.Weight.carry + Inv.carryBonus(r.eq)
	p:SetAttribute("Load", w / carry)
	p:SetAttribute("Carry", carry)
	-- GEAR hearing (headphones +30 %): widens the footstep pings (World: hearR = 9 x (1 + hearing x 1.5))
	local hs = r.eq.headset and Guns.items[r.eq.headset.id]
	p:SetAttribute("Hearing", (hs and hs.gear and hs.gear.hearing) or 0)
	-- World.updateVision: the night-vision ability lifts the night view factors; the goggles' tint while on
	local nv, nvType, toggled = Raid.nightVision(r)
	p:SetAttribute("NightVision", math.clamp(nv, 0, 1))
	p:SetAttribute("NvgView", if toggled and (r :: any).nvgOn ~= false then nvType else nil)
	p:SetAttribute("ArmorDur", r.eq.body and r.eq.body.dur or nil)
	p:SetAttribute("HelmetDur", r.eq.head and r.eq.head.dur or nil)
	p:SetAttribute("Weight", w)
	p:SetAttribute("InRaid", r.inRaid)
end
Raid.syncVitals = syncVitals

function Raid.sendBag(p: Player)
	local r = raids[p]
	-- worn equipment for the inventory screen
	if r then
		local e = r.eq
		local function id(k: string): string
			return if e[k] then (e[k] :: Stack).id else ""
		end
		p:SetAttribute("Equip", string.format("gun=%s,gun2=%s,melee=%s,armor=%s,helmet=%s",
			id("firearm1"), id("firearm2"), id("melee"), id("body"), id("head")))
		p:SetAttribute("Hotbar", table.concat(r.hotbar, ","))
		syncVitals(p)
	end
	-- the hotbar reads the backpack from this attribute (id:count pairs)
	local parts = {}
	for _, s in (r and r.bag or {}) do
		table.insert(parts, s.id .. ":" .. s.n)
	end
	p:SetAttribute("Bag", table.concat(parts, ","))
	-- the LootView's full state (server/Inventory.luau)
	if Raid.onInv then
		Raid.onInv(p)
	end
end
Raid.onInv = nil :: ((Player) -> ())?

local function rootOf(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end
Raid.rootOf = rootOf

function Raid.posOf(p: Player): Vector3?
	local r = rootOf(p)
	if not r then
		return nil
	end
	return Vector3.new(r.Position.X / S, 0, r.Position.Z / S)
end

-- spawn spots: the entrance (Special/BunkerEntry) with a small spread per player
local function spawnSpot(i: number): Vector2
	local e = MapData.spawn
	local a = i * 2.39996
	local r = if i == 0 then 0 else 1.2 + 0.4 * i
	return Vector2.new(e.x + math.cos(a) * r, e.z + math.sin(a) * r)
end

local corpseHook: ((Vector3, string, { Stack }, Model?) -> ())? = nil
function Raid.onCorpse(fn: (Vector3, string, { Stack }, Model?) -> ())
	corpseHook = fn
end

function Raid.deploy(p: Player)
	local prof = profiles[p]
	if not prof then
		return
	end
	local eq, bag = starterKit()
	require(script.Parent.Weather).begin((prof :: any).clock, (prof :: any).weatherSeed)
	local r: RaidState = {
		hp = Config.Body.maxHp,
		maxHp = Config.Body.maxHp,
		energy = 50,
		water = 50,
		eq = eq,
		bag = bag,
		hotbar = { "bandage", "", "", "", "", "" },
		locks = {},
		wish = {},
		alive = true,
		inRaid = true,
		dodgeAt = -math.huge,
		extractT = 0,
		startedAt = os.clock(),
	}
	raids[p] = r
	prof.raids += 1
	(r :: any).xpAtStart = prof.xp or 0
	local n = 0
	for _, other in Players:GetPlayers() do
		if other ~= p and raids[other] and raids[other].alive then
			n += 1
		end
	end
	local spot = spawnSpot(n)
	if p.Character then
		p.Character:Destroy()
	end
	-- the player's own Roblox avatar (R15, the experience's Animate), fitted to the web character's size and rules
	p:LoadCharacter()
	local model = p.Character
	if not model or not raids[p] then
		return
	end
	Avatar.prepare(model)
	model:SetAttribute("Held", "gun")
	model:SetAttribute("UserId", p.UserId)
	Avatar.place(model, spot.X, spot.Y, 0)
	model.Parent = charFolder
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	-- a name tag in the brief's style
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(160, 30)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 1.5 * S, 0)
	bb.AlwaysOnTop = true
	bb.MaxDistance = 200
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.FontFace = Font.new("rbxasset://fonts/families/FredokaOne.json")
	t.TextColor3 = Color3.fromRGB(255, 248, 233)
	t.TextSize = 18
	t.Text = p.DisplayName
	local st = Instance.new("UIStroke")
	st.Thickness = 2
	st.Parent = t
	t.Parent = bb
	bb.Parent = root
	Weapons.targets[p] = {
		kind = "player",
		team = 0,
		pos = function()
			return Raid.posOf(p)
		end,
		radius = Config.Body.hitRadius,
		height = Config.Body.hitHeight,
		hurt = function(dmg, info)
			return Raid.hurt(p, dmg, info)
		end,
		stun = function(secs)
			Raid.stun(p, secs)
		end,
		ref = p,
		model = model,
	}
	(r :: any).held = "gun"
	syncVitals(p)
	Weapons.syncAmmo(p)
	Raid.sendBag(p)
	Net.event("RaidState"):FireClient(p, "deployed")
end

--- StormWeather protection: the worn gear's storm points (helmet_storm, gasmask: 1 each)
function Raid.stormProtection(p: Player): number
	local r = raids[p] :: any
	if not r then
		return 0
	end
	local n = 0
	for _, k in { "helmet", "armor", "face" } do
		local g = r[k]
		if g and (g.id == "helmet_storm" or g.id == "gasmask") then
			n += 1
		end
	end
	return n
end

function Raid.stun(p: Player, secs: number)
	p:SetAttribute("StunUntil", Workspace:GetServerTimeNow() + secs)
end

function Raid.hurt(p: Player, dmg: number, info: any): boolean
	local r = raids[p]
	if not r or not r.alive then
		return false
	end
	-- Studio test fixture only (tools/mcp tests set it); never active in a live server
	if RunService:IsStudio() and p:GetAttribute("DevGod") then
		return false
	end
	-- dodge roll: fully invulnerable (Player.ts dashing)
	if os.clock() - r.dodgeAt < Config.Dash.time and not (info and info.direct) then
		return false
	end
	-- Stun (buff 1041 / 1042): Moveability -0.85 for its time
	if info and info.stun then
		Raid.stun(p, info.stun)
	end
	-- KillInfo for the result screen's "I was killed by" (Killer.ts): name, weapon, headshot, explosion
	if info then
		(r :: any).lastKill = { name = info.fromName, weaponId = info.weaponId, crit = info.crit, explosion = info.explosion, self = info.from == p }
	end
	-- armorMultiplier (Player.ts): dmg x 2 / (clamp(armor - pen, 0, 999) + 2); a crit hits the helmet, else the body armor
	local worn = if info and info.crit then r.eq.head else r.eq.body
	local av = armorOf(worn)
	if worn and (worn.dur or 0) > 0 and av > 0 and not (info and info.direct) then
		dmg *= 2 / (math.clamp(av - ((info and info.pen) or 0), 0, 999) + 2)
		worn.dur = math.max(0, worn.dur - ((info and info.armorBreak) or 0.55))
	end
	r.hp = math.max(0, r.hp - dmg)
	-- World: damage over time (bleed, starvation, storm) shows its number over the player at 3.2 m (WorldUI 'tick');
	-- a hazard's hit (playerHurt) shows the number and the orange flash, without blood
	if info and info.tick then
		Net.event("Fx"):FireClient(p, "tick", dmg)
	elseif info and info.hazard then
		for _, other in Players:GetPlayers() do
			Net.event("Fx"):FireClient(other, "phurt", p.Character, dmg, other == p)
		end
	end
	if info and info.bleed and math.random() < info.bleed then
		Raid.addBleed(p)
	end
	syncVitals(p)
	if r.hp <= 0 then
		Raid.die(p, info)
		return true
	end
	return false
end

-- data.ts LEVEL_EXP / levelForXp (cumulative; Lv2 at 2000, then +1000 per level step)
local LEVEL_EXP = { 0, 0, 2000, 5000, 9000, 14000, 20000, 27000, 35000, 44000, 54000, 65000, 77000, 90000, 104000, 119000, 135000, 152000, 170000, 189000, 209000, 230000, 252000, 275000, 299000, 324000, 350000, 377000, 405000, 434000, 464000 }
function Raid.levelForXp(xp: number): (number, number, number)
	local level = 1
	while level + 1 < #LEVEL_EXP and xp >= LEVEL_EXP[level + 2] do
		level += 1
	end
	local next = LEVEL_EXP[level + 2] or (LEVEL_EXP[level + 1] + 1000 * (level + 1))
	return level, xp - LEVEL_EXP[level + 1], next - LEVEL_EXP[level + 1]
end

function Raid.addXp(p: Player, n: number)
	local prof = profiles[p]
	if prof and n > 0 then
		prof.xp = (prof.xp or 0) + n
	end
end

-- Killer.ts killerText: "Name (Weapon)" + " Headshot"; "Myself"; "Explosion"; "?" for hunger / thirst / bleeding
local function killerText(k: any): string
	if not k then
		return "?"
	end
	local name = if k.self then "Myself" else (k.name or "")
	if name == "Starvation" or name == "Bleeding" then
		return "?"
	end
	local weapon = ""
	if k.explosion then
		weapon = "Explosion"
	elseif k.weaponId and Guns.items[k.weaponId] then
		weapon = Guns.items[k.weaponId].name
	elseif k.weaponId == "butcher_knife" then
		weapon = "Butcher Knife"
	elseif k.weaponId == "animal_weapon" then
		weapon = "Bare Hands"
	end
	if name ~= "" and weapon ~= "" then
		return string.format("%s (%s)%s", name, weapon, if k.crit then " Headshot" else "")
	end
	return if name ~= "" then name elseif weapon ~= "" then weapon else "?"
end

function Raid.die(p: Player, info: any)
	local r = raids[p]
	if not r or not r.alive then
		return
	end
	r.alive = false
	r.inRaid = false
	local prof = profiles[p]
	local xpBefore = prof and prof.xp or 0
	if prof then
		prof.deaths += 1
	end
	local pos = Raid.posOf(p)
	-- splitOnDeath (deathKeep.ts): everything goes to the body except the kept melee slot
	local loot: { Stack } = {}
	for _, k in Inv.EQUIP_SLOTS do
		local inst = r.eq[k]
		if inst and k ~= "melee" then
			local c = table.clone(inst)
			c.pos = nil
			table.insert(loot, c)
		end
	end
	for _, s in r.bag do
		local c = table.clone(s)
		c.pos = nil
		table.insert(loot, c)
	end
	local x = r :: any
	Weapons.targets[p] = nil
	Weapons.cancelReload(p)
	syncVitals(p)
	-- World.update: the player falls on its back (0.333 s, clients animate from DeadAt) and stays; its body holds
	-- the gear ("Lost Items", pre-revealed, cyan beacon) for one recovery
	local char = p.Character
	if char then
		local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			root.AssemblyLinearVelocity = Vector3.zero
			root.Anchored = true
			local tag = root:FindFirstChildOfClass("BillboardGui")
			if tag then
				tag:Destroy()
			end
		end
		char:SetAttribute("Dead", true)
		char:SetAttribute("DeadAt", Workspace:GetServerTimeNow())
		char.Name = p.DisplayName .. " (dead)"
	end
	if pos and corpseHook then
		corpseHook(pos, p.DisplayName, loot, char)
	end
	local kt = killerText(x.lastKill)
	local secs = os.clock() - r.startedAt
	saveProfile(p)
	-- World.dead 1.5 s after the death, then resolveDeath -> the result screen
	task.delay(1.5, function()
		if p.Parent and p.Character == char then
			p.Character = nil
		end
		local lv, into, need = Raid.levelForXp(xpBefore)
		Net.event("Died"):FireClient(p, { killer = kt, secs = secs, xpBefore = xpBefore, xpAfter = prof and prof.xp or xpBefore, level = lv, into = into, need = need })
	end)
end

function Raid.extract(p: Player)
	local r = raids[p]
	if not r or not r.alive then
		return
	end
	r.inRaid = false
	r.alive = false
	local prof = profiles[p]
	local banked: { Stack } = {}
	if prof then
		prof.extracts += 1
		for _, s in r.bag do
			Raid.addItem(prof.stash, s.id, s.n)
			table.insert(banked, s)
		end
		for _, k in Inv.EQUIP_SLOTS do
			local inst = r.eq[k]
			if inst then
				Raid.addItem(prof.stash, inst.id, 1)
				table.insert(banked, { id = inst.id, n = 1 })
			end
		end
	end
	Weapons.targets[p] = nil
	syncVitals(p)
	if p.Character then
		p.Character:Destroy()
		p.Character = nil
	end
	local xpNow = prof and prof.xp or 0
	local lv, into, need = Raid.levelForXp(xpNow)
	Net.event("Extracted"):FireClient(p, banked, { secs = os.clock() - r.startedAt, xpBefore = (r :: any).xpAtStart or 0, xpAfter = xpNow, level = lv, into = into, need = need })
	saveProfile(p)
end

-- data.ts NEEDS (energy 8 / water 9 per real minute in a raid), STARVE (1 dmg / 2 s at 0 energy), BLEED (1 dmg / 1.5 s
-- per layer, max 3 layers, 25 s; a new bleeding hit adds a layer and resets the timer)
local function drains(p: Player, r: RaidState, dt: number)
	local x = r :: any
	r.energy = math.max(0, r.energy - 8 / 60 * dt)
	r.water = math.max(0, r.water - 9 / 60 * dt)
	x.starveT = (x.starveT or 0) + dt
	if r.energy <= 0 and x.starveT >= 2 then
		x.starveT = 0
		Raid.hurt(p, 1, { fromName = "Starvation", direct = true, tick = true })
	end
	if (x.bleed or 0) > 0 then
		x.bleedLeft = (x.bleedLeft or 25) - dt
		x.bleedT = (x.bleedT or 0) + dt
		if x.bleedT >= 1.5 then
			x.bleedT = 0
			Raid.hurt(p, x.bleed, { fromName = "Bleeding", direct = true, tick = true })
		end
		if x.bleedLeft <= 0 then
			x.bleed = 0
		end
	end
	p:SetAttribute("Bleed", x.bleed or 0)
	x.vitalsT = (x.vitalsT or 0) + dt
	if x.vitalsT > 0.5 then
		x.vitalsT = 0
		syncVitals(p)
	end
end

function Raid.addBleed(p: Player)
	local r = raids[p] :: any
	if not r then
		return
	end
	r.bleed = math.min(3, (r.bleed or 0) + 1)
	r.bleedLeft = 25
end

--- the world's hour of day (server/Weather.luau clock)
function Raid.hour(): number
	return require(script.Parent.Weather).hour()
end

--- TimeOfDayController: night 22:00-06:00
function Raid.isNight(): boolean
	return require(script.Parent.Weather).night
end

-- extraction pad + clock + vitals drain each frame
local function tick(dt: number)
	local clock = os.clock() - raidStart
	for p, r in raids do
		p:SetAttribute("RaidClock", clock)
		if not r.alive then
			continue
		end
		drains(p, r, dt)
		if not r.alive then
			continue
		end
		local pos = Raid.posOf(p)
		if not pos then
			continue
		end
		local inPad = false
		for _, ex in MapData.exits do
			if (Vector2.new(pos.X, pos.Z) - Vector2.new(ex.x, ex.z)).Magnitude <= (ex.r or Config.Extract.padRadius) then
				inPad = true
			end
		end
		if inPad then
			r.extractT += dt
			p:SetAttribute("ExtractLeft", math.max(0, Config.Extract.time - r.extractT))
			if r.extractT >= Config.Extract.time then
				p:SetAttribute("ExtractLeft", nil)
				Raid.extract(p)
			end
		elseif r.extractT > 0 then
			-- World: leaving the zone resets the countdown; "Extraction cancelled" only past 0.5 s
			if r.extractT > 0.5 then
				Net.event("Toast"):FireClient(p, "Extraction cancelled", "bad")
			end
			r.extractT = 0
			p:SetAttribute("ExtractLeft", nil)
		end
	end
end

function Raid.start()
	Players.CharacterAutoLoads = false
	Weapons.getGun = function(p)
		local r = raids[p]
		if not r or not r.alive then
			return nil
		end
		local x = r :: any
		if x.held == "gun2" then
			return r.eq.firearm2
		elseif x.held == "melee" or x.held == "none" or x.held == "throw" then
			return nil
		end
		return r.eq.firearm1
	end
	Weapons.countAmmo = function(p, id)
		local r = raids[p]
		return r and Raid.count(r.bag, id) or 0
	end
	Weapons.takeAmmo = function(p, id, n)
		local r = raids[p]
		if not r then
			return 0
		end
		local k = Raid.take(r.bag, id, n)
		return k
	end
	Weapons.giveAmmo = function(p, id, n)
		local r = raids[p]
		if r then
			Raid.addItem(r.bag, id, n, Raid.cap(r))
		end
	end
	Weapons.onBag = Raid.sendBag
	Weapons.busy = function(p)
		return p:GetAttribute("UseId") ~= nil or p:GetAttribute("HoldId") ~= nil
	end
	Weapons.isDodging = function(p)
		local r = raids[p]
		return r ~= nil and os.clock() - r.dodgeAt < Config.Dash.time
	end
	Net.event("Dodge").OnServerEvent:Connect(function(p, dir)
		local r = raids[p]
		if not r or not r.alive then
			return
		end
		if os.clock() - r.dodgeAt < Config.Dash.time + Config.Dash.cooldown * 0.8 then
			return
		end
		r.dodgeAt = os.clock()
		Weapons.cancelReload(p)
		if p.Character then
			p.Character:SetAttribute("DodgeAt", Workspace:GetServerTimeNow())
		end
	end)
	Net.func("Deploy").OnServerInvoke = function(p)
		local r = raids[p]
		if r and r.alive then
			return false
		end
		Raid.deploy(p)
		return true
	end
	local function join(p: Player)
		profiles[p] = loadProfile(p)
		p:SetAttribute("Stash", nil)
		Raid.deploy(p)
	end
	Players.PlayerAdded:Connect(function(p)
		if RunService:IsStudio() then
			p:GetAttributeChangedSignal("DevGive"):Connect(function()
				local v = p:GetAttribute("DevGive")
				local r = raids[p]
				if typeof(v) == "string" and r then
					local id, n = string.match(v, "([^:]+):(%d+)")
					if id then
						Raid.addItem(r.bag, id, tonumber(n) or 1, Raid.cap(r))
						Raid.sendBag(p)
					end
				end
			end)
		end
	end)
	Players.PlayerAdded:Connect(join)
	for _, p in Players:GetPlayers() do
		task.spawn(join, p)
	end
	Players.PlayerRemoving:Connect(function(p)
		saveProfile(p)
		Weapons.targets[p] = nil
		raids[p] = nil
		profiles[p] = nil
	end)
	game:BindToClose(function()
		for _, p in Players:GetPlayers() do
			saveProfile(p)
		end
	end)
	RunService.Heartbeat:Connect(tick)
end

return Raid
