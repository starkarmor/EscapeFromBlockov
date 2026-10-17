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
local RigBuilder = require(Shared.RigBuilder)
local Weapons = require(script.Parent.Weapons)

local S = Units.S
local Raid = {}

export type Stack = { id: string, n: number }
export type Profile = {
	stash: { Stack },
	money: number,
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
	p:SetAttribute("InRaid", r.inRaid)
end
Raid.syncVitals = syncVitals

function Raid.sendBag(p: Player)
	local r = raids[p]
	Net.event("LootOpen"):FireClient(p, "bag", r and r.bag or {})
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

local corpseHook: ((Vector3, string, { Stack }) -> ())? = nil
function Raid.onCorpse(fn: (Vector3, string, { Stack }) -> ())
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
	local model = RigBuilder.build("player", p.DisplayName)
	model:SetAttribute("Held", "gun")
	model:SetAttribute("UserId", p.UserId)
	model:PivotTo(CFrame.new(spot.X * S, RigBuilder.ROOT_R + 0.2, spot.Y * S) * CFrame.Angles(0, math.pi, 0))
	model.Parent = charFolder
	p.Character = model
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	root:SetNetworkOwner(p)
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
	}
	syncVitals(p)
	Weapons.syncAmmo(p)
	Net.event("RaidState"):FireClient(p, "deployed")
end

function Raid.hurt(p: Player, dmg: number, info: any): boolean
	local r = raids[p]
	if not r or not r.alive then
		return false
	end
	-- dodge roll: fully invulnerable (Player.ts dashing)
	if os.clock() - r.dodgeAt < Config.Dash.time then
		return false
	end
	r.hp = math.max(0, r.hp - dmg)
	syncVitals(p)
	if r.hp <= 0 then
		Raid.die(p, info)
		return true
	end
	return false
end

function Raid.die(p: Player, info: any)
	local r = raids[p]
	if not r or not r.alive then
		return
	end
	r.alive = false
	r.inRaid = false
	local prof = profiles[p]
	if prof then
		prof.deaths += 1
	end
	local pos = Raid.posOf(p)
	-- everything carried goes to the corpse (one recovery attempt)
	local loot: { Stack } = {}
	if r.gun then
		table.insert(loot, { id = r.gun.id, n = 1 })
		if r.gun.ammo > 0 then
			Raid.addItem(loot, Guns.ammoOf(r.gun.id) or "ammo_s_rusty", r.gun.ammo)
		end
	end
	for _, s in r.bag do
		table.insert(loot, { id = s.id, n = s.n })
	end
	if pos and corpseHook then
		corpseHook(pos, p.DisplayName, loot)
	end
	Weapons.targets[p] = nil
	Weapons.cancelReload(p)
	syncVitals(p)
	if p.Character then
		p.Character:Destroy()
		p.Character = nil
	end
	local by = info and info.fromName or "?"
	Net.event("Died"):FireClient(p, by, os.clock() - r.startedAt)
	saveProfile(p)
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
	end
	Weapons.targets[p] = nil
	syncVitals(p)
	if p.Character then
		p.Character:Destroy()
		p.Character = nil
	end
	Net.event("Extracted"):FireClient(p, banked, os.clock() - r.startedAt)
	saveProfile(p)
end

-- extraction pad + clock + vitals drain each frame
local function tick(dt: number)
	local clock = os.clock() - raidStart
	for p, r in raids do
		p:SetAttribute("RaidClock", clock)
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
		return r and r.alive and r.gun or nil
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
