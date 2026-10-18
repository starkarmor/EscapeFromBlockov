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

local S = Units.S
local Raid = {}

export type Stack = { id: string, n: number }
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
	gun: { id: string, ammo: number, dur: number }?,
	melee: string,
	bag: { Stack },
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
local function starterKit(): (any, { Stack })
	local gun = { id = "tt33", ammo = 8, dur = 100 }
	local bag = {
		{ id = "ammo_s_rusty", n = 30 },
		{ id = "bandage", n = 3 },
		{ id = "aspirin", n = 1 },
		{ id = "carrot", n = 1 },
		{ id = "cocoa", n = 1 },
	}
	return gun, bag
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
	return prof
end

local function saveProfile(p: Player)
	local prof = profiles[p]
	if not prof or not store or p.UserId <= 0 then
		return
	end
	pcall(function()
		(store :: DataStore):SetAsync("u" .. p.UserId, prof)
	end)
end

-- backpack helpers (stacks honour maxStack)
function Raid.addItem(bag: { Stack }, id: string, n: number): number
	local it = Guns.items[id]
	local max = (it and it.maxStack) or 1
	local left = n
	for _, s in bag do
		if s.id == id and s.n < max then
			local k = math.min(max - s.n, left)
			s.n += k
			left -= k
			if left <= 0 then
				return n
			end
		end
	end
	while left > 0 do
		local k = math.min(max, left)
		table.insert(bag, { id = id, n = k })
		left -= k
	end
	return n
end

function Raid.count(bag: { Stack }, id: string): number
	local c = 0
	for _, s in bag do
		if s.id == id then
			c += s.n
		end
	end
	return c
end

function Raid.take(bag: { Stack }, id: string, n: number): number
	local taken = 0
	for i = #bag, 1, -1 do
		local s = bag[i]
		if s.id == id and taken < n then
			local k = math.min(s.n, n - taken)
			s.n -= k
			taken += k
			if s.n <= 0 then
				table.remove(bag, i)
			end
		end
	end
	return taken
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
	if r.gun and Guns.items[r.gun.id] then
		w += Guns.items[r.gun.id].weight or 0
	end
	if Guns.items[r.melee] then
		w += Guns.items[r.melee].weight or 0
	end
	for _, k in { "gun2", "armor", "helmet" } do
		local inst = (r :: any)[k]
		if inst and Guns.items[inst.id] then
			w += Guns.items[inst.id].weight or 0
		end
	end
	for _, s in r.bag do
		local def = Guns.items[s.id]
		w += (def and def.weight or 0) * s.n
	end
	p:SetAttribute("Load", w / Config.Weight.carry)
	local xa = r :: any
	p:SetAttribute("ArmorDur", xa.armor and xa.armor.dur or nil)
	p:SetAttribute("HelmetDur", xa.helmet and xa.helmet.dur or nil)
	p:SetAttribute("Weight", w)
	p:SetAttribute("InRaid", r.inRaid)
end
Raid.syncVitals = syncVitals

function Raid.sendBag(p: Player)
	local r = raids[p]
	-- worn equipment for the inventory screen
	if r then
		local x = r :: any
		p:SetAttribute("Equip", string.format("gun=%s,gun2=%s,melee=%s,armor=%s,helmet=%s",
			r.gun and r.gun.id or "", x.gun2 and x.gun2.id or "", r.melee or "", x.armor and x.armor.id or "", x.helmet and x.helmet.id or ""))
	end
	-- the hotbar reads the backpack from this attribute (id:count pairs)
	local parts = {}
	for _, s in (r and r.bag or {}) do
		table.insert(parts, s.id .. ":" .. s.n)
	end
	p:SetAttribute("Bag", table.concat(parts, ","))
end

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
	local gun, bag = starterKit()
	local r: RaidState = {
		hp = Config.Body.maxHp,
		maxHp = Config.Body.maxHp,
		energy = 50,
		water = 50,
		gun = gun,
		melee = "stick",
		bag = bag,
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
		ref = p,
		model = model,
	}
	(r :: any).held = "gun"
	syncVitals(p)
	Weapons.syncAmmo(p)
	Raid.sendBag(p)
	Net.event("RaidState"):FireClient(p, "deployed")
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
	-- KillInfo for the result screen's "I was killed by" (Killer.ts): name, weapon, headshot, explosion
	if info then
		(r :: any).lastKill = { name = info.fromName, weaponId = info.weaponId, crit = info.crit, explosion = info.explosion, self = info.from == p }
	end
	-- armorMultiplier (Player.ts): dmg x 2 / (clamp(armor - pen, 0, 999) + 2); a crit hits the helmet, else the body armor
	local x = r :: any
	local worn = if info and info.crit then x.helmet else x.armor
	if worn and (worn.dur or 0) > 0 and (worn.armor or 0) > 0 and not (info and info.direct) then
		dmg *= 2 / (math.clamp(worn.armor - ((info and info.pen) or 0), 0, 999) + 2)
		worn.dur = math.max(0, worn.dur - ((info and info.armorBreak) or 0.55))
	end
	r.hp = math.max(0, r.hp - dmg)
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
	if r.gun then
		table.insert(loot, { id = r.gun.id, n = 1 })
		if r.gun.ammo > 0 then
			Raid.addItem(loot, Guns.ammoOf(r.gun.id) or "ammo_s_rusty", r.gun.ammo)
		end
	end
	local x = r :: any
	for _, k in { "gun2", "armor", "helmet" } do
		if x[k] then
			table.insert(loot, { id = x[k].id, n = 1 })
		end
	end
	for _, s in r.bag do
		table.insert(loot, { id = s.id, n = s.n })
	end
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
		if r.gun then
			Raid.addItem(prof.stash, r.gun.id, 1)
			table.insert(banked, { id = r.gun.id, n = 1 })
		end
		local x = r :: any
		for _, k in { "gun2", "armor", "helmet" } do
			if x[k] then
				Raid.addItem(prof.stash, x[k].id, 1)
				table.insert(banked, { id = x[k].id, n = 1 })
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
		Raid.hurt(p, 1, { fromName = "Starvation", direct = true })
	end
	if (x.bleed or 0) > 0 then
		x.bleedLeft = (x.bleedLeft or 25) - dt
		x.bleedT = (x.bleedT or 0) + dt
		if x.bleedT >= 1.5 then
			x.bleedT = 0
			Raid.hurt(p, x.bleed, { fromName = "Bleeding", direct = true })
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
			if r.extractT == 0 then
				Net.event("Toast"):FireClient(p, "Extracting...", "good")
			end
			r.extractT += dt
			p:SetAttribute("ExtractLeft", math.max(0, Config.Extract.time - r.extractT))
			if r.extractT >= Config.Extract.time then
				p:SetAttribute("ExtractLeft", nil)
				Raid.extract(p)
			end
		elseif r.extractT > 0 then
			r.extractT = 0
			p:SetAttribute("ExtractLeft", nil)
			Net.event("Toast"):FireClient(p, "Extraction cancelled", "bad")
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
			return x.gun2
		elseif x.held == "melee" then
			return nil
		end
		return r.gun
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
						Raid.addItem(r.bag, id, tonumber(n) or 1)
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
