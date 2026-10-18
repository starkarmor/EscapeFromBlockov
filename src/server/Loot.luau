--!strict
-- Containers, corpses and the other Ground Zero interacts (World.rollContainer / updateLoot, Builder interacts):
-- each container exists this raid with its decoded chance; first open rolls its table (fixed rows by chance, then
-- draws[0..1] weighted pool picks, SPAWN_COUNT stacks, capped at slots); items reveal one at a time (INSPECT_TIMES by
-- quality); the window closes past 2.8 m. Corpses hold a dead player's gear or an enemy's body table roll.
-- Interacts: container (instant), hatch "Enter Bunker" (hold 1 s, ends the raid like extraction), simple teleports.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Items = require(Shared.gen.Items)
local Inv = require(Shared.Inv)
local MapData = require(Shared.MapData)
local Raid = require(script.Parent.Raid)
local Enemies = require(script.Parent.Enemies)

local S = Units.S
local Loot = {}

-- a container's items are positional Insts (src/shared/Inv.luau) with `revealed`; `slots` is its capacity
type Item = Inv.Inst
type Box = { id: string, kind: string, x: number, z: number, r: number, label: string, hold: number, table: string?, container: string?, rolled: boolean, items: { Item }, part: BasePart?, data: any, slots: number? }
-- the main map's interacts plus the cave sub-scene's (src/shared/CaveData.luau, ids prefixed cave_)
local INTERACTS = table.clone(MapData.interacts)
for _, it in require(Shared.CaveData).interacts do
	table.insert(INTERACTS, it)
end
local boxes: { [string]: Box } = {}
-- interact ids become attribute names: anything outside [%w_] is replaced (some decoded ids carry ':' and '/')
local function akey(id: string): string
	return (string.gsub(id, "[^%w_]", "_"))
end
Loot.boxes = boxes
local open: { [Player]: { box: Box, searchT: number } } = {}
local holds: { [Player]: { box: Box, t: number } } = {}

-- web data.ts SPAWN_COUNT (ammo 30, shells 20, sniper 10, bandage 3, default 1)
local function spawnCount(id: string): number
	local it = Items.items[id]
	if not it then
		return 1
	end
	if it.kind == "ammo" or it.cat == "Bullet" then
		local cal = it.ammo and it.ammo.caliber or ""
		if cal == "SHT" or cal == "Shotgun" then
			return 20
		elseif cal == "SNP" or cal == "Sniper" then
			return 10
		end
		return 30
	end
	if id == "bandage" then
		return 3
	end
	return 1
end

local function pick(pool: { { any } }): string?
	local r, acc = math.random(), 0
	for _, row in pool do
		acc += row[2]
		if r <= acc then
			return row[1]
		end
	end
	return nil -- leftover probability = nothing
end

local function roll(row: any): { Item }
	local out: { Item } = {}
	local slots = row.slots or 5
	local function add(id: string, n: number)
		if #out >= slots then
			return
		end
		local it = Items.items[id]
		local max = (it and it.maxStack) or 1
		for _, s in out do
			if s.id == id and s.n < max then
				local k = math.min(max - s.n, n)
				s.n += k
				n -= k
			end
		end
		while n > 0 and #out < slots do
			local k = math.min(max, n)
			local item: Item = { id = id, n = k, revealed = false }
			if it and it.fire then
				item.ammo = math.random(0, 5)
			end
			table.insert(out, item)
			n -= k
		end
	end
	for _, f in row.fixed or {} do
		if math.random() < (f.chance or 1) then
			local c = f.count or { 1, 1 }
			add(f.id, math.random(c[1], c[2]))
		end
	end
	local pool = Items.pools[row.pool]
	if pool then
		local d = row.draws or { 1, 1 }
		local draws = d[1] + math.floor(math.random() * (d[2] - d[1] + 1))
		for _ = 1, draws do
			local id = pick(pool)
			if id then
				add(id, spawnCount(id))
			end
		end
	end
	return out
end

-- container footprint (data.ts CONTAINER_LOOK sizes, metres: w along x, h, d along z); the look is the Creator Store
-- model "C_<type>" (docs/creator-assets.json) fitted to this footprint, else a plain block in the web colour
local LOOK: { [string]: { size: Vector3, color: Color3 } } = {
	crate = { size = Vector3.new(1.1, 0.8, 1.1), color = Color3.fromHex("#a77d48") },
	toolbox = { size = Vector3.new(0.9, 0.5, 0.5), color = Color3.fromHex("#c2412f") },
	cooler = { size = Vector3.new(0.9, 0.6, 0.6), color = Color3.fromHex("#3f8fc0") },
	medbox = { size = Vector3.new(0.9, 0.6, 0.6), color = Color3.fromHex("#d9dcd8") },
	ammobox = { size = Vector3.new(0.8, 0.45, 0.5), color = Color3.fromHex("#5a6b3a") },
	weaponcase = { size = Vector3.new(1.4, 0.5, 0.7), color = Color3.fromHex("#3f4a3a") },
	weaponcrate = { size = Vector3.new(1.5, 0.75, 0.8), color = Color3.fromHex("#4a5a36") },
	cabinet = { size = Vector3.new(1.0, 1.7, 0.6), color = Color3.fromHex("#6d7a86") },
	clothes = { size = Vector3.new(1.2, 1.6, 0.4), color = Color3.fromHex("#8a6d5a") },
	toilet = { size = Vector3.new(0.5, 0.8, 0.7), color = Color3.fromHex("#e4e4dc") },
	trash = { size = Vector3.new(0.6, 0.9, 0.6), color = Color3.fromHex("#4c5a4c") },
	luxury = { size = Vector3.new(0.8, 0.4, 0.5), color = Color3.fromHex("#7a4a8a") },
	tech = { size = Vector3.new(1.0, 0.6, 0.6), color = Color3.fromHex("#3a6f8a") },
	explorer = { size = Vector3.new(0.7, 0.5, 0.5), color = Color3.fromHex("#b89a4a") },
	hidden = { size = Vector3.new(1.0, 0.25, 1.0), color = Color3.fromHex("#6e5536") },
	daily = { size = Vector3.new(0.9, 0.7, 0.6), color = Color3.fromHex("#b8a07a") },
	starter = { size = Vector3.new(0.9, 0.6, 0.6), color = Color3.fromHex("#8a9a5a") },
	cardoor = { size = Vector3.new(1.2, 1.0, 0.15), color = Color3.fromHex("#5a6470") },
	-- World.dropItem / makeContainer('pile'): a low box with a yellow beacon, hidden while empty
	pile = { size = Vector3.new(0.9, 0.3, 0.9), color = Color3.fromHex("#6d6a52") },
}
local DEFAULT_LOOK = { size = Vector3.new(0.9, 0.6, 0.7), color = Color3.fromHex("#D0BA78") }

local folder = Instance.new("Folder")
folder.Name = "Loot"
folder.Parent = Workspace

local mapParams = OverlapParams.new()
mapParams.FilterType = Enum.RaycastFilterType.Include
mapParams.RespectCanCollide = false

--- a model fitted to a footprint (studs): uniform scale so it fills the footprint's larger horizontal side, its long
--- horizontal axis turned onto the footprint's long axis, height capped at 1.4x the footprint height
local function fitted(name: string, foot: Vector3): Model?
	local assets = ReplicatedStorage:FindFirstChild("CreatorAssets")
	local t = assets and assets:FindFirstChild(name) :: Model?
	if not t then
		return nil
	end
	local m = t:Clone()
	local s0 = m:GetAttribute("Size0") :: Vector3
	local modelLong, footLong = math.max(s0.X, s0.Z), math.max(foot.X, foot.Z)
	local k = footLong / modelLong
	if s0.Y * k > foot.Y * 1.4 then
		k = foot.Y * 1.4 / s0.Y
	end
	m:ScaleTo(k)
	local turn = (s0.X >= s0.Z) ~= (foot.X >= foot.Z)
	m:SetAttribute("Turn", turn)
	return m
end

local function makeProp(b: Box)
	local kind = b.container or b.kind
	local look = LOOK[kind] or DEFAULT_LOOK
	local foot = look.size * S
	-- the interact anchor: invisible, non-colliding (the web's containers block nothing), queryable for nobody
	local p = Instance.new("Part")
	p.Name = b.label ~= "" and b.label or kind
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = foot
	p.CFrame = CFrame.new(b.x * S, foot.Y / 2, b.z * S)
	p:SetAttribute("Box", b.id)
	-- nudge the visual out of map props it would sit inside (source spots stand in stalls, on shelves, under desks)
	local map = Workspace:FindFirstChild("GroundZero")
	local props = map and map:FindFirstChild("Props")
	local center = p.CFrame
	if props then
		mapParams.FilterDescendantsInstances = { props }
		local probe = foot * 0.9
		for step = 0, 10 do
			local hits = Workspace:GetPartBoundsInBox(center, probe, mapParams)
			local push = Vector3.zero
			for _, h in hits do
				if h.Transparency < 1 and h.Position.Y - h.Size.Y / 2 < foot.Y then
					local d = center.Position - h.Position
					push += Vector3.new(d.X, 0, d.Z)
				end
			end
			if push.Magnitude < 1e-3 then
				break
			end
			if step == 10 then
				center = p.CFrame -- could not clear it: stay at the source spot
				break
			end
			center = center + push.Unit * 0.1 * S
		end
	end
	local model = fitted("C_" .. kind, foot)
	if model then
		local yaw = if model:GetAttribute("Turn") then math.pi / 2 else 0
		-- 0.02-stud lift: the model's base never shares a plane with the ground (no z-fighting)
		model:PivotTo(CFrame.new(center.X, 0.02, center.Z) * CFrame.Angles(0, yaw, 0))
		model.Name = "Look"
		model.Parent = p
	else
		local blk = Instance.new("Part")
		blk.Name = "Look"
		blk.Anchored = true
		blk.CanCollide = false
		blk.CanQuery = false
		blk.Size = foot
		blk.Color = look.color
		blk.Material = Enum.Material.Plastic
		blk.CFrame = CFrame.new(center.X, foot.Y / 2 + 0.02, center.Z)
		blk.Parent = p
	end
	p.Parent = folder
	b.part = p
end

local function publish(b: Box)
	Workspace:SetAttribute("Box_" .. akey(b.id), b.rolled and #b.items or -1)
	local searched = b.rolled
	for _, it in b.items do
		if not it.revealed then
			searched = false
		end
	end
	Workspace:SetAttribute("BoxS_" .. akey(b.id), searched)
end

local function view(b: Box): { any }
	local out = {}
	for i, it in b.items do
		local def = Items.items[it.id]
		out[i] = if it.revealed
			then { id = it.id, n = it.n, name = def and def.name or it.id, q = def and def.q or 0, color = def and def.color or "#888888" }
			else { hidden = true }
	end
	return out
end

--- the container's display name (World.makeContainer: the type's name, Body, Lost Items, Dropped Items)
function Loot.nameOf(b: Box): string
	local t = b.container and Items.types[b.container]
	if b.kind == "corpse" or b.kind == "body" or b.kind == "pile" then
		return b.label
	end
	return if b.label ~= "" then b.label elseif t and t.name then t.name else (b.container or b.kind)
end

--- the container's capacity (its table / type slots, 16 for bodies and piles)
function Loot.slotsOf(b: Box): number
	if b.slots then
		return b.slots
	end
	local row = (b.table and Items.tables[b.table]) or (b.container and Items.types[b.container])
	b.slots = math.max((row and row.slots) or 16, #b.items)
	return b.slots :: number
end

-- server/Inventory.luau listens: a player opened a container / its contents changed / it closed for them
Loot.onOpen = nil :: ((Player) -> ())?
Loot.onChange = nil :: ((Player) -> ())?
Loot.onClose = nil :: ((Player) -> ())?

--- the container a player has open (and whether an item is still being searched)
function Loot.openOf(p: Player): (Box?, boolean)
	local o = open[p]
	if not o then
		return nil, false
	end
	for _, it in o.box.items do
		if not it.revealed then
			return o.box, true
		end
	end
	return o.box, false
end

--- after any change to a box's items: positions, beacons, the world attributes, every player looking into it
function Loot.changed(b: Box)
	Inv.layout(b.items)
	if #b.items == 0 and b.data and b.data.beacon and b.kind ~= "pile" then
		b.data.beacon:Destroy()
		b.data.beacon = nil
	end
	if b.kind == "pile" and b.part then
		for _, d in b.part:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
				d.Transparency = if #b.items > 0 then (if d.Name == "Beacon" then 0.3 else 0) else 1
			end
		end
	end
	publish(b)
	for q, o in open do
		if o.box == b and Loot.onChange then
			Loot.onChange(q)
		end
	end
end

function Loot.addBox(kind: string, x: number, z: number, label: string, items: { Item }?, data: any, model: Model?): Box
	local id = "c" .. tostring(math.random(1e9))
	local b: Box = { id = id, kind = kind, x = x, z = z, r = 1.9, label = label, hold = 0, table = nil, container = kind, rolled = items ~= nil, items = items or {}, part = nil, data = data }
	Inv.layout(b.items)
	boxes[id] = b
	local root = model and model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		-- the fallen body itself is the container (World.dropBody: no mesh of its own)
		root:SetAttribute("BoxName", label) -- before Box: the client reads the label when Box appears
		root:SetAttribute("Box", id)
		b.part = root
	else
		makeProp(b)
	end
	publish(b)
	return b
end

local function openBox(p: Player, b: Box)
	if not b.rolled then
		b.rolled = true
		local row = (b.table and Items.tables[b.table]) or (b.container and Items.types[b.container])
		b.items = if row then roll(row) else {}
		Inv.layout(b.items)
	end
	Loot.slotsOf(b)
	open[p] = { box = b, searchT = 0 }
	if Loot.onOpen then
		Loot.onOpen(p)
	end
end

-- ------------------------------------------------------------------ loose items (World.spawnLoose / pick up)
local function looseLabel(id: string, n: number): string
	local d = Items.items[id]
	return (if d then d.name else id) .. (if n > 1 then " x" .. n else "")
end

--- World: the loose item spawners [DB item-spawn], each Random.Range(draws) (upper bound exclusive) items at distinct
--- points; a roll in the leftover probability spawns nothing; the stack is SPAWN_COUNT
local function spawnLoose()
	local n = 0
	for _, sp in Items.loose or {} do
		local pts = table.clone(sp.points)
		local d0, d1 = sp.draws[1], sp.draws[2]
		local draws = math.min(#pts, d0 + (if d1 > d0 then math.floor(math.random() * (d1 - d0)) else 0))
		for _ = 1, draws do
			local at = table.remove(pts, math.random(1, #pts))
			local id = pick(sp.pool)
			if id and Items.items[id] then
				local count = spawnCount(id)
				local b: Box = { id = "l" .. tostring(math.random(1e9)), kind = "loose", x = at[1], z = at[2], r = 1.4, label = looseLabel(id, count),
					hold = 0, table = nil, container = nil, rolled = true, items = {}, part = nil, data = { id = id, n = count } }
				-- LOOSE_GEO: a 0.42 x 0.18 x 0.3 box in the item's colour, 0.1 m up, a random yaw
				local part = Instance.new("Part")
				part.Name = "Loose"
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.Size = Vector3.new(0.42, 0.18, 0.3) * S
				part.Color = Color3.fromHex(Items.items[id].color or "#999999")
				part.Material = Enum.Material.SmoothPlastic
				part.CFrame = CFrame.new(at[1] * S, 0.1 * S, at[2] * S) * CFrame.Angles(0, math.random() * math.pi, 0)
				part:SetAttribute("Loose", b.label)
				part:SetAttribute("Box", b.id)
				part.Parent = folder
				b.part = part
				boxes[b.id] = b
				n += 1
			end
		end
	end
	return n
end

--- World.interact on a loose item: AddItem into the backpack; "Name xN" + the pickup sound for what went in, "Backpack
--- full" when some stays on the ground
local function pickUp(p: Player, b: Box)
	local r = Raid.raids[p]
	if not r then
		return
	end
	local id, n = b.data.id, b.data.n
	local left = Inv.addItem(r.bag, id, n, Raid.cap(r))
	local got = n - left
	if got > 0 then
		Net.event("Toast"):FireClient(p, looseLabel(id, got), "obtained")
	end
	if left > 0 then
		b.data.n = left
		b.label = looseLabel(id, left)
		if b.part then
			b.part:SetAttribute("Loose", b.label)
		end
		Net.event("Toast"):FireClient(p, "Backpack full", "bad")
	else
		boxes[b.id] = nil
		if b.part then
			b.part:Destroy()
		end
	end
	Raid.sendBag(p)
	require(script.Parent.Weapons).syncAmmo(p)
end

local function interact(p: Player, id: any)
	if typeof(id) ~= "string" then
		return
	end
	local r = Raid.raids[p]
	local pos = Raid.posOf(p)
	local b = boxes[id]
	if not r or not r.alive or not pos or not b then
		return
	end
	if (Vector2.new(pos.X, pos.Z) - Vector2.new(b.x, b.z)).Magnitude > b.r + 1.2 then
		return
	end
	-- World.startDoor: a locked door without its key refuses before the hold starts ("Requires <Key>")
	if b.kind == "door" and b.data and b.data.key and not b.data.unlocked and Raid.count(r.bag, b.data.key) <= 0 then
		local def = Items.items[b.data.key]
		Net.event("Toast"):FireClient(p, "Requires " .. (def and def.name or "Key"), "bad")
		return
	end
	if b.hold > 0 then
		holds[p] = { box = b, t = 0 }
		p:SetAttribute("HoldId", b.id)
		p:SetAttribute("HoldTime", b.hold)
		p:SetAttribute("HoldStart", Workspace:GetServerTimeNow())
		return
	end
	if b.kind == "loose" then
		pickUp(p, b)
	elseif b.kind == "container" or b.kind == "corpse" or b.kind == "body" or b.kind == "pile" then
		openBox(p, b)
	else
		Loot.finish(p, b)
	end
end

local flags: { [string]: boolean } = {}
Loot.flags = flags
local TweenService = game:GetService("TweenService")

local function doorToggle(p: Player, b: Box)
	local d = b.data
	local r = Raid.raids[p]
	if d.key and not d.unlocked then
		if not r or Raid.count(r.bag, d.key) <= 0 then
			local def = Items.items[d.key]
			-- missing key: PopText, the interaction does not start
			Net.event("Toast"):FireClient(p, "Requires " .. (def and def.name or "Key"), "bad")
			return
		end
		d.unlocked = true
		Net.event("Toast"):FireClient(p, "Door unlocked", "good")
		if d.keyUse == "finish" then
			Raid.take(r.bag, d.key, 1)
			Raid.sendBag(p)
		end
	end
	d.open = not d.open
	Workspace:SetAttribute("Door_" .. b.id, d.open)
	local leaf: BasePart = d.part
	leaf.CanCollide = not d.open
	TweenService:Create(leaf, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { CFrame = if d.open then d.openCf else d.closedCf }):Play()
end

local function build(p: Player, b: Box)
	local d = b.data
	if flags[d.flag] then
		return
	end
	local r = Raid.raids[p]
	if not r then
		return
	end
	for _, c in d.cost.items do
		if Raid.count(r.bag, c[1]) < c[2] then
			local def = Items.items[c[1]]
			Net.event("Toast"):FireClient(p, string.format("Needs %d %s", c[2], def and def.name or c[1]), "bad")
			return
		end
	end
	for _, c in d.cost.items do
		Raid.take(r.bag, c[1], c[2])
	end
	Raid.sendBag(p)
	flags[d.flag] = true
	Workspace:SetAttribute("Flag_" .. string.gsub(d.flag, "[^%w_]", "_"), true)
	local site = Workspace:FindFirstChild("GroundZero") and Workspace.GroundZero:FindFirstChild("Sites") and Workspace.GroundZero.Sites:FindFirstChild(d.flag)
	if site then
		for _, f in { "Block", "NotBuilt" } do
			local fo = site:FindFirstChild(f)
			if fo then
				fo:Destroy()
			end
		end
		local built = site:FindFirstChild("Built")
		if built then
			for _, part in built:GetChildren() do
				if part:IsA("BasePart") then
					part.Transparency = 0
				end
			end
		end
	end
	Net.event("Toast"):FireClient(p, if #d.cost.items > 0 then "Built!" else "Opened", "good")
	boxes[b.id] = nil
	Workspace:SetAttribute("Box_" .. akey(b.id), nil)
end

function Loot.finish(p: Player, b: Box)
	if b.kind == "container" then
		openBox(p, b) -- a held open (tech boxes, LOOTBOX_OPEN 0.6 s)
	elseif b.kind == "door" then
		doorToggle(p, b)
	elseif b.kind == "construct" then
		build(p, b)
	elseif b.kind == "hatch" and b.label == "Go Down" and not flags["site:GroundZero_ManHole"] then
		Net.event("Toast"):FireClient(p, "The manhole is closed", "bad")
	elseif b.kind == "hatch" then
		-- SceneLoaderProxy to the bunker: the raid ends like an extraction
		Raid.extract(p)
	elseif b.kind == "teleport" and b.data and b.data.to then
		local c = p.Character
		if c then
			c:PivotTo(CFrame.new(b.data.to.X * S, 0.6 * S, b.data.to.Y * S))
		end
	elseif b.kind == "loader" then
		Net.event("Toast"):FireClient(p, b.label .. ": not in this slice yet", "bad")
	elseif b.kind == "note" then
		local t = require(Shared.Notes)[b.data.note]
		if t then
			Net.event("Note"):FireClient(p, t[1], t[2])
		end
		-- World: reading a note records it ("Note added")
		Net.event("Toast"):FireClient(p, "Note added", "info")
	elseif b.kind == "beacon" then
		local flag = b.data.flag or "beacon"
		flags[flag] = true
		Workspace:SetAttribute("Flag_" .. flag, true)
		Net.event("Toast"):FireClient(p, "Beacon Activated", "good")
		boxes[b.id] = nil
		Workspace:SetAttribute("Box_" .. akey(b.id), nil)
	elseif b.kind == "wall" then
		-- the cracked wall's interact never opens it: explosions break it (World.ts "Requires Explosives")
		if not flags[b.data.flag or "wall"] then
			Net.event("Toast"):FireClient(p, "Requires Explosives", "bad")
		end
	elseif b.kind == "station" then
		Net.event("Toast"):FireClient(p, "The workbench is not in this slice yet", "bad")
	else
		Net.event("Toast"):FireClient(p, b.label, nil)
	end
end

local function step(dt: number)
	for p, o in open do
		local r = Raid.raids[p]
		local pos = Raid.posOf(p)
		if not r or not r.alive or not pos or (Vector2.new(pos.X, pos.Z) - Vector2.new(o.box.x, o.box.z)).Magnitude > Config.Loot.closeDistance then
			open[p] = nil
			if Loot.onClose then
				Loot.onClose(p)
			end
			continue
		end
		-- reveal the next hidden item after its quality's inspect time
		for _, it in o.box.items do
			if not it.revealed then
				o.searchT += dt
				local def = Items.items[it.id]
				local q = math.clamp((def and def.q or 0), 0, 6)
				if o.searchT >= Config.Loot.inspect[q + 1] then
					o.searchT = 0
					it.revealed = true
					Loot.changed(o.box)
				end
				break
			end
		end
	end
	for p, h in holds do
		local pos = Raid.posOf(p)
		local r = Raid.raids[p]
		if not r or not r.alive or not pos or (Vector2.new(pos.X, pos.Z) - Vector2.new(h.box.x, h.box.z)).Magnitude > h.box.r + 1.2 then
			holds[p] = nil
			p:SetAttribute("HoldId", nil)
			continue
		end
		h.t += dt
		if h.t >= h.box.hold then
			holds[p] = nil
			p:SetAttribute("HoldId", nil)
			Loot.finish(p, h.box)
		end
	end
end

function Loot.start()
	-- containers and interacts from the export (each container exists with its decoded chance)
	local n = 0
	for _, it in INTERACTS do
		if it.kind == "container" then
			local function spawnBox()
				local b: Box = { id = it.id, kind = "container", x = it.x, z = it.z, r = 1.9, label = "", hold = if it.container == "tech" then 0.6 else 0, table = it.table, container = it.container, rolled = false, items = {}, part = nil, data = nil }
				boxes[b.id] = b
				makeProp(b)
				publish(b)
			end
			if math.random() <= (it.chance or 1) then
				if it.weather == "storm2" then
					-- the cave's formula box exists only in Storm Phase II (weathers ["Stormy_II"])
					local Weather = require(script.Parent.Weather)
					table.insert(Weather.listeners, function(name)
						if name == "storm2" then
							spawnBox()
						end
					end)
				else
					spawnBox()
					n += 1
				end
			end
		elseif it.kind == "hatch" or it.kind == "teleport" or it.kind == "loader" then
			local data = nil
			if it.kind == "teleport" and it.label == "Go" then
				-- the SimpleTeleporter pair
				for _, o in INTERACTS do
					if o.kind == "teleport" and o.label == "Go" and o ~= it then
						data = { to = Vector2.new(o.x + 1.5, o.z) }
					end
				end
			end
			if it.kind == "teleport" and not data and it.arrive then
				-- MultiSceneTeleporter: the cave entrance / exit, to the other sub-scene's arrival point
				data = { to = Vector2.new(it.arrive.x, it.arrive.z) }
			end
			if it.kind == "teleport" and not data then
				continue
			end
			local b: Box = { id = it.id, kind = it.kind, x = it.x, z = it.z, r = math.max(it.r or 1.8, 1.8), label = it.label or it.kind, hold = it.hold or 0, table = nil, container = nil, rolled = true, items = {}, part = nil, data = data }
			boxes[b.id] = b
			publish(b)
		end
	end
	-- doors: the decoded leaf box, swinging openAngle about its hinge end (Builder.door: lerp 0.5 s)
	local doorFolder = Instance.new("Folder")
	doorFolder.Name = "Doors"
	doorFolder.Parent = folder
	for _, d in MapData.doors or {} do
		local bx = d.box
		local w, dz = bx.maxX - bx.minX, bx.maxZ - bx.minZ
		local h = 1.5 -- drawn at the wall cut like the rooms (Builder.wallCut)
		local leaf = Instance.new("Part")
		leaf.Name = "Door"
		leaf.Anchored = true
		leaf.Size = Vector3.new(w, h, dz) * S
		leaf.Color = if d.key then Color3.fromHex("#E8322E") else Color3.fromHex("#8A5A2B")
		leaf.Material = Enum.Material.Plastic
		leaf.CollisionGroup = "M31"
		leaf:SetAttribute("Cat", 31)
		local cx, cz = (bx.minX + bx.maxX) / 2, (bx.minZ + bx.maxZ) / 2
		local closed = CFrame.new(cx * S, h * S / 2, cz * S)
		local hinge = if d.axis == "x" then Vector3.new(bx.minX, 0, cz) else Vector3.new(cx, 0, bx.minZ)
		local hingeCf = CFrame.new(hinge.X * S, h * S / 2, hinge.Z * S)
		local openCf = hingeCf * CFrame.Angles(0, d.openAngle or math.pi / 2, 0) * hingeCf:Inverse() * closed
		leaf.CFrame = closed
		leaf.Parent = doorFolder
		local b: Box = { id = d.id, kind = "door", x = d.x, z = d.z, r = 1.8, label = if d.key then "Unlock" else "Open", hold = d.interactTime or 0.2, table = nil, container = nil, rolled = true, items = {}, part = nil,
			data = { open = false, key = d.key, keyUse = d.keyUse, part = leaf, closedCf = closed, openCf = openCf, box = bx } }
		boxes[b.id] = b
		Workspace:SetAttribute("Door_" .. b.id, false)
	end
	-- World.aiOpenDoor: an AI walking into a closed, unlocked, unkeyed door opens it (within width / 2 + r along the
	-- leaf and 0.36 + r across)
	local aiDoors = {}
	for _, b in boxes do
		if b.kind == "door" and not b.data.key then
			table.insert(aiDoors, b)
		end
	end
	Enemies.openDoor = function(pos: Vector2, r: number)
		for _, b in aiDoors do
			local d = b.data
			if d.open then
				continue
			end
			local bx = d.box
			local w, dz = bx.maxX - bx.minX, bx.maxZ - bx.minZ
			local cx, cz = (bx.minX + bx.maxX) / 2, (bx.minZ + bx.maxZ) / 2
			local along, across = if w >= dz then math.abs(pos.X - cx) else math.abs(pos.Y - cz), if w >= dz then math.abs(pos.Y - cz) else math.abs(pos.X - cx)
			if along <= math.max(w, dz) / 2 + r and across <= 0.36 + r then
				d.open = true
				Workspace:SetAttribute("Door_" .. b.id, true)
				local leaf: BasePart = d.part
				leaf.CanCollide = false
				TweenService:Create(leaf, TweenInfo.new(0.5, Enum.EasingStyle.Quad), { CFrame = d.openCf }):Play()
				publish(b)
			end
		end
	end
	for _, it in INTERACTS do
		if it.kind == "note" or it.kind == "beacon" or it.kind == "wall" or it.kind == "station" then
			local b: Box = { id = it.id, kind = it.kind, x = it.x, z = it.z, r = math.max(it.r or 1.8, 1.8), label = it.label or it.kind, hold = it.hold or 0, table = nil, container = nil, rolled = true, items = {}, part = nil,
				data = { note = it.note, flag = it.flag } }
			-- TeleportBeacon.Start: an unlocked beacon hides its interact
			if not (it.kind == "beacon" and flags[it.flag or "beacon"]) then
				boxes[b.id] = b
				publish(b)
			end
		end
		if it.kind == "construct" then
			local b: Box = { id = it.id, kind = "construct", x = it.x, z = it.z, r = it.r or 2.4, label = it.label or "Build", hold = it.hold or 0, table = nil, container = nil, rolled = true, items = {}, part = nil,
				data = { flag = it.flag, cost = it.cost or { money = 0, items = {} } } }
			boxes[b.id] = b
		end
	end
	-- markers: the bunker hatch and the extraction pad (web: a translucent column; art brief: violet extraction column)
	local function column(x: number, z: number, r: number, h: number, label: string)
		local m = Instance.new("Model")
		m.Name = label
		local col = Instance.new("Part")
		col.Shape = Enum.PartType.Cylinder
		col.Anchored = true
		col.CanCollide = false
		col.CanQuery = false
		col.CastShadow = false
		col.Material = Enum.Material.Neon
		col.Color = Color3.fromHex("#9938F2")
		col.Transparency = 0.6
		col.Size = Vector3.new(h * S, r * 2 * S, r * 2 * S)
		col.CFrame = CFrame.new(x * S, h * S / 2, z * S) * CFrame.Angles(0, 0, math.pi / 2)
		col.Parent = m
		local pad = col:Clone()
		pad.Transparency = 0.15
		pad.Material = Enum.Material.Neon
		pad.Color = Color3.fromHex("#FFF8E9")
		pad.Size = Vector3.new(0.08 * S, r * 2 * S + 0.6, r * 2 * S + 0.6)
		pad.CFrame = CFrame.new(x * S, 0.04 * S, z * S) * CFrame.Angles(0, 0, math.pi / 2)
		pad.Parent = m
		local bb = Instance.new("BillboardGui")
		bb.Size = UDim2.fromOffset(160, 40)
		bb.StudsOffsetWorldSpace = Vector3.new(0, h * S + 2, 0)
		bb.AlwaysOnTop = true
		bb.LightInfluence = 0
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.FontFace = Font.new("rbxasset://fonts/families/FredokaOne.json")
		t.TextSize = 24
		t.TextColor3 = Color3.fromHex("#FFF8E9")
		t.Text = label
		local st = Instance.new("UIStroke")
		st.Thickness = 3
		st.Color = Color3.fromHex("#16151D")
		st.Parent = t
		t.Parent = bb
		bb.Adornee = col
		bb.Parent = col
		m.Parent = folder
		-- slow spin of the pad ring so it reads as live
		task.spawn(function()
			local a = 0
			while m.Parent do
				a += 0.03
				col.Transparency = 0.55 + 0.1 * math.sin(a * 3)
				task.wait(1 / 20)
			end
		end)
	end
	for _, ex in MapData.exits or {} do
		column(ex.x, ex.z, ex.r or 3, 4, "EXTRACT")
	end
	for _, it in INTERACTS do
		if it.kind == "hatch" and it.label == "Enter Bunker" then
			column(it.x, it.z, 1.2, 3.5, "BUNKER")
		end
	end
	print(string.format("[Blockov] %d containers, %d loose items this raid", n, spawnLoose()))
	-- the dead player's body: "Lost Items", everything pre-revealed (the tomb), a cyan beacon over it
	Raid.onCorpse(function(pos, name, items, model)
		local list = {}
		for _, st in items do
			local c = table.clone(st)
			c.pos = nil
			c.revealed = true
			table.insert(list, c)
		end
		local b = Loot.addBox("corpse", pos.X, pos.Z, "Lost Items", list, nil, model)
		local beacon = Instance.new("Part")
		beacon.Name = "Beacon"
		beacon.Anchored = true
		beacon.CanCollide = false
		beacon.CanQuery = false
		beacon.CastShadow = false
		beacon.Material = Enum.Material.Neon
		beacon.Color = Color3.fromHex("#7fd0ff")
		beacon.Transparency = 0.3
		beacon.Size = Vector3.new(0.12, 2.4, 0.12) * S
		beacon.CFrame = CFrame.new(pos.X * S, 1.2 * S, pos.Z * S)
		beacon.Parent = if model then model else folder
		b.data = { beacon = beacon }
	end)
	-- enemy bodies: "Body", the carried loot unrevealed (the gun with what is left in its magazine + the body table)
	Enemies.onCorpse(function(pos, name, kind, model, gun, worn, carried)
		local body = Items.bodies[kind]
		local list: { Item } = {}
		-- the armor / helmet the enemy wore drops with its remaining durability
		for _, g in worn or {} do
			table.insert(list, { id = g.id, n = 1, revealed = false, dur = g.dur } :: any)
		end
		if gun and Items.items[gun] then
			local cap = (Items.gunFeel[gun] or {}).Capacity or 8
			table.insert(list, { id = gun, n = 1, revealed = false, ammo = math.random(0, cap) })
		end
		-- what the enemy still carries (rolled at spawn from its body table; heals and grenades it used are gone)
		if carried then
			for _, st in carried do
				table.insert(list, { id = st.id, n = st.n, revealed = false, ammo = if Items.items[st.id] and Items.items[st.id].fire then math.random(0, 5) else nil })
			end
			body = nil
		end
		if body then
			for _, d in body.drops do
				if not d.weapon and math.random() < (d.chance or 1) then
					local c = d.count or { 1, 1 }
					for _ = 1, math.random(c[1], c[2]) do
						local id = pick(d.pool or {})
						if id then
							table.insert(list, { id = id, n = spawnCount(id), revealed = false, ammo = if Items.items[id] and Items.items[id].fire then math.random(0, 5) else nil })
						end
					end
				end
			end
		end
		if #list > 0 then
			Loot.addBox("body", pos.X, pos.Z, "Body", list, nil, model)
		end
	end)
	Net.event("Interact").OnServerEvent:Connect(interact)
	Net.event("InteractCancel").OnServerEvent:Connect(function(p)
		holds[p] = nil
		p:SetAttribute("HoldId", nil)
		if open[p] then
			open[p] = nil
			if Loot.onClose then
				Loot.onClose(p)
			end
		end
	end)
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(p)
		open[p] = nil
		holds[p] = nil
	end)
end

--- World.dropItem: into a pile within 1.5 m of (x, z), else a new one ("Dropped Items", searched)
function Loot.dropPile(x: number, z: number, inst: Item)
	local pile: Box? = nil
	for _, b in boxes do
		if b.kind == "pile" and (Vector2.new(b.x, b.z) - Vector2.new(x, z)).Magnitude < 1.5 then
			pile = b
			break
		end
	end
	if not pile then
		local nb = Loot.addBox("pile", x, z, "Dropped Items", {}, nil, nil)
		nb.slots = 16
		local beacon = Instance.new("Part")
		beacon.Name = "Beacon"
		beacon.Anchored = true
		beacon.CanCollide = false
		beacon.CanQuery = false
		beacon.CastShadow = false
		beacon.Material = Enum.Material.Neon
		beacon.Color = Color3.fromHex("#ffd23f")
		beacon.Transparency = 0.3
		beacon.Size = Vector3.new(0.12, 2.4, 0.12) * S
		beacon.CFrame = CFrame.new(x * S, 1.2 * S, z * S)
		beacon.Parent = nb.part
		nb.data = { beacon = beacon }
		pile = nb
	end
	local b = pile :: Box
	local c = table.clone(inst)
	c.pos = nil
	c.revealed = true
	-- takes the pile's first empty position (past its capacity it still goes in)
	if not Inv.addFirstEmpty(b.items, c, Loot.slotsOf(b)) then
		table.insert(b.items, c)
	end
	Loot.changed(b)
end

--- interact points the client can use (id, kind, label, x, z, r, hold)
function Loot.points(): { any }
	local out = {}
	for _, b in boxes do
		table.insert(out, { id = b.id, kind = b.kind, label = b.label, x = b.x, z = b.z, r = b.r, hold = b.hold })
	end
	return out
end

return Loot
