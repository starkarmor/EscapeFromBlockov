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
local MapData = require(Shared.MapData)
local Raid = require(script.Parent.Raid)
local Enemies = require(script.Parent.Enemies)

local S = Units.S
local Loot = {}

type Item = { id: string, n: number, revealed: boolean, ammo: number? }
type Box = { id: string, kind: string, x: number, z: number, r: number, label: string, hold: number, table: string?, container: string?, rolled: boolean, items: { Item }, part: BasePart?, data: any }
local boxes: { [string]: Box } = {}
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

-- container look (data.ts CONTAINER_LOOK sizes, art-brief colours)
local LOOK: { [string]: { size: Vector3, color: Color3 } } = {
	crate = { size = Vector3.new(1.1, 0.8, 1.1), color = Color3.fromHex("#C28A4A") },
	toolbox = { size = Vector3.new(0.9, 0.5, 0.5), color = Color3.fromHex("#E8322E") },
	cooler = { size = Vector3.new(0.9, 0.6, 0.6), color = Color3.fromHex("#13A5F4") },
	medbox = { size = Vector3.new(0.9, 0.6, 0.6), color = Color3.fromHex("#FFF8E9") },
	ammobox = { size = Vector3.new(0.8, 0.45, 0.5), color = Color3.fromHex("#6E8A3A") },
	weaponcase = { size = Vector3.new(1.4, 0.5, 0.7), color = Color3.fromHex("#4A5A4A") },
	weaponcrate = { size = Vector3.new(1.4, 0.7, 0.8), color = Color3.fromHex("#5C6E4A") },
	cabinet = { size = Vector3.new(0.9, 1.6, 0.5), color = Color3.fromHex("#B9BCC4") },
	luxury = { size = Vector3.new(1.0, 0.6, 0.7), color = Color3.fromHex("#FFD83D") },
	hidden = { size = Vector3.new(0.7, 0.4, 0.7), color = Color3.fromHex("#8A5A2B") },
	corpse = { size = Vector3.new(1.0, 0.35, 1.0), color = Color3.fromHex("#9938F2") },
}
local DEFAULT_LOOK = { size = Vector3.new(0.9, 0.6, 0.7), color = Color3.fromHex("#D0BA78") }

local folder = Instance.new("Folder")
folder.Name = "Loot"
folder.Parent = Workspace

local function makeProp(b: Box)
	local look = LOOK[b.container or b.kind] or DEFAULT_LOOK
	local p = Instance.new("Part")
	p.Name = b.label ~= "" and b.label or (b.container or b.kind)
	p.Anchored = true
	p.Size = look.size * S
	p.Color = look.color
	p.Material = Enum.Material.Plastic
	p.MaterialVariant = "CanuckStuds"
	p.CFrame = CFrame.new(b.x * S, look.size.Y * S / 2, b.z * S)
	p.CollisionGroup = "M27"
	p:SetAttribute("Cat", 27)
	p:SetAttribute("Box", b.id)
	-- a dark lid band so the box reads at the top-down camera
	local lid = Instance.new("Part")
	lid.Anchored = true
	lid.CanCollide = false
	lid.CanQuery = false
	lid.Size = Vector3.new(look.size.X * 1.04, 0.08, look.size.Z * 1.04) * S
	lid.Color = Color3.fromHex("#16151D")
	lid.CFrame = p.CFrame * CFrame.new(0, look.size.Y * S / 2 - 0.04 * S, 0)
	lid.Parent = p
	p.Parent = folder
	b.part = p
end

local function publish(b: Box)
	Workspace:SetAttribute("Box_" .. b.id, b.rolled and #b.items or -1)
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

local function sendBox(p: Player, b: Box)
	local r = Raid.raids[p]
	Net.event("LootOpen"):FireClient(p, b.id, b.label ~= "" and b.label or (b.container or b.kind), view(b), r and Loot.bagView(r.bag) or {})
end

function Loot.bagView(bag: { any }): { any }
	local out = {}
	for i, s in bag do
		local def = Items.items[s.id]
		out[i] = { id = s.id, n = s.n, name = def and def.name or s.id, q = def and def.q or 0, color = def and def.color or "#888888" }
	end
	return out
end

function Loot.addBox(kind: string, x: number, z: number, label: string, items: { Item }?, data: any): Box
	local id = "c" .. tostring(#folder:GetChildren() + 1) .. "_" .. tostring(math.random(1e6))
	local b: Box = { id = id, kind = kind, x = x, z = z, r = Config.Loot.interactRadius, label = label, hold = 0, table = nil, container = kind, rolled = items ~= nil, items = items or {}, part = nil, data = data }
	boxes[id] = b
	makeProp(b)
	publish(b)
	return b
end

local function openBox(p: Player, b: Box)
	if not b.rolled then
		b.rolled = true
		local row = (b.table and Items.tables[b.table]) or (b.container and Items.types[b.container])
		b.items = if row then roll(row) else {}
	end
	open[p] = { box = b, searchT = 0 }
	sendBox(p, b)
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
	if b.hold > 0 then
		holds[p] = { box = b, t = 0 }
		p:SetAttribute("HoldId", b.id)
		p:SetAttribute("HoldTime", b.hold)
		p:SetAttribute("HoldStart", Workspace:GetServerTimeNow())
		return
	end
	if b.kind == "container" or b.kind == "corpse" then
		openBox(p, b)
	else
		Loot.finish(p, b)
	end
end

function Loot.finish(p: Player, b: Box)
	if b.kind == "hatch" then
		-- SceneLoaderProxy to the bunker: the raid ends like an extraction
		Raid.extract(p)
	elseif b.kind == "teleport" and b.data and b.data.to then
		local c = p.Character
		if c then
			c:PivotTo(CFrame.new(b.data.to.X * S, 0.6 * S, b.data.to.Y * S))
		end
	elseif b.kind == "loader" then
		Net.event("Toast"):FireClient(p, b.label .. ": not in this slice yet", "bad")
	else
		Net.event("Toast"):FireClient(p, b.label, nil)
	end
end

local function take(p: Player, boxId: any, index: any)
	local o = open[p]
	local r = Raid.raids[p]
	if not o or not r or typeof(index) ~= "number" or o.box.id ~= boxId then
		return
	end
	local it = o.box.items[index]
	if not it or not it.revealed then
		return
	end
	table.remove(o.box.items, index)
	local def = Items.items[it.id]
	if def and def.fire and not r.gun then
		r.gun = { id = it.id, ammo = it.ammo or 0, dur = 100 }
	else
		Raid.addItem(r.bag, it.id, it.n)
	end
	Net.event("Toast"):FireClient(p, string.format("+%d %s", it.n, def and def.name or it.id), if def and (def.q or 0) >= 4 then "rare" else "good")
	publish(o.box)
	require(script.Parent.Weapons).syncAmmo(p)
	sendBox(p, o.box)
end

local function step(dt: number)
	for p, o in open do
		local r = Raid.raids[p]
		local pos = Raid.posOf(p)
		if not r or not r.alive or not pos or (Vector2.new(pos.X, pos.Z) - Vector2.new(o.box.x, o.box.z)).Magnitude > Config.Loot.closeDistance then
			open[p] = nil
			Net.event("LootOpen"):FireClient(p, nil)
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
					sendBox(p, o.box)
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
	for _, it in MapData.interacts do
		if it.kind == "container" then
			if math.random() <= (it.chance or 1) then
				local b: Box = { id = it.id, kind = "container", x = it.x, z = it.z, r = it.r or Config.Loot.interactRadius, label = "", hold = 0, table = it.table, container = it.container, rolled = false, items = {}, part = nil, data = nil }
				boxes[b.id] = b
				makeProp(b)
				publish(b)
				n += 1
			end
		elseif it.kind == "hatch" or it.kind == "teleport" or it.kind == "loader" then
			local data = nil
			if it.kind == "teleport" and it.label == "Go" then
				-- the SimpleTeleporter pair
				for _, o in MapData.interacts do
					if o.kind == "teleport" and o.label == "Go" and o ~= it then
						data = { to = Vector2.new(o.x + 1.5, o.z) }
					end
				end
			end
			if it.kind == "teleport" and not data then
				continue -- sub-scene teleports (the cave) are not in this slice
			end
			local b: Box = { id = it.id, kind = it.kind, x = it.x, z = it.z, r = math.max(it.r or 1.8, 1.8), label = it.label or it.kind, hold = it.hold or 0, table = nil, container = nil, rolled = true, items = {}, part = nil, data = data }
			boxes[b.id] = b
			publish(b)
		end
	end
	print(string.format("[Canuckov] %d containers this raid", n))
	Raid.onCorpse(function(pos, name, items)
		local list = {}
		for _, s in items do
			table.insert(list, { id = s.id, n = s.n, revealed = false })
		end
		Loot.addBox("corpse", pos.X, pos.Z, name .. "'s Remains", list)
	end)
	Enemies.onCorpse(function(pos, name, kind)
		local body = Items.bodies[kind]
		local list: { Item } = {}
		if body then
			for _, d in body.drops do
				if math.random() < (d.chance or 1) then
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
		Loot.addBox("corpse", pos.X, pos.Z, name, list)
	end)
	Net.event("Interact").OnServerEvent:Connect(interact)
	Net.event("InteractCancel").OnServerEvent:Connect(function(p)
		holds[p] = nil
		p:SetAttribute("HoldId", nil)
		if open[p] then
			open[p] = nil
		end
	end)
	Net.event("LootTake").OnServerEvent:Connect(take)
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(function(p)
		open[p] = nil
		holds[p] = nil
	end)
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
