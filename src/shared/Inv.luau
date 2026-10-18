--!strict
-- The inventory model, 1:1 with the web build's src/game/inventory.ts (the source's ItemStatsSystem.Inventory and the
-- helpers on it: ItemUtilities.AddAndMerge, Inventory.Sort / TryMerge, CharacterMainControl.UpdateInventoryCapacity) and
-- the stack / equipment helpers of src/game/Profile.ts. Shared by the server (authority) and the client (the LootView).
--
-- Every list is a dense array of Insts; each Inst carries `pos`, its slot index (0-based, = inventoryPosition). `layout`
-- keeps a list sorted by pos and gives an item without a valid pos the first empty position (Inventory.AddItem).
-- Loot containers keep their items as Insts too, with `revealed` on each.
local Items = require(script.Parent.gen.Items)

local Inv = {}

export type Inst = {
	id: string,
	n: number,
	pos: number?,
	ammo: number?,
	loaded: string?,
	dur: number?,
	loss: number?,
	uses: number?,
	att: { [string]: string }?,
	revealed: boolean?,
}

local function def(id: string): any
	return Items.items[id]
end

-- ---------------------------------------------------------------- positions
local function validPos(p: any): boolean
	return typeof(p) == "number" and p == math.floor(p) and p >= 0
end

--- Normalise a list: items whose pos is valid and above the previous one keep it; any other item takes the first empty
--- position, in array order (Inventory.AddItem -> GetFirstEmptyPosition(0)). The array ends sorted by pos.
function Inv.layout(list: { Inst }): { Inst }
	local last = -1
	local loose = false
	local taken: { [number]: boolean } = {}
	for _, t in list do
		local p = t.pos
		if validPos(p) and (p :: number) > last then
			taken[p :: number] = true
			last = p :: number
		else
			loose = true
		end
	end
	if not loose then
		return list
	end
	last = -1
	local hole = 0
	for _, t in list do
		local p = t.pos
		if validPos(p) and (p :: number) > last and taken[p :: number] then
			last = p :: number
			continue
		end
		while taken[hole] do
			hole += 1
		end
		t.pos = hole
		taken[hole] = true
	end
	table.sort(list, function(a, b)
		return (a.pos :: number) < (b.pos :: number)
	end)
	return list
end

--- content.Count: the last occupied position + 1
function Inv.contentCount(list: { Inst }): number
	local n = 0
	for _, t in list do
		n = math.max(n, (t.pos or -1) + 1)
	end
	return n
end

--- Inventory.GetItemAt
function Inv.itemAt(list: { Inst }, pos: number): Inst?
	for _, t in list do
		if t.pos == pos then
			return t
		end
	end
	return nil
end

--- the list's items by position: cells[pos + 1] (nil = empty cell), `n` cells
function Inv.cells(list: { Inst }, n: number): { [number]: Inst }
	Inv.layout(list)
	local out: { [number]: Inst } = {}
	for _, t in list do
		local p = t.pos :: number
		if p >= 0 and p < n then
			out[p + 1] = t
		end
	end
	return out
end

--- Inventory.GetFirstEmptyPosition(start): start < 0 -> 0; Count <= start -> start; the first hole in [start, Count);
--- else Count when Count < Capacity; else the first hole in [0, start); else -1
function Inv.firstEmpty(list: { Inst }, cap: number, start: number?): number
	Inv.layout(list)
	local s = math.max(0, start or 0)
	local count = Inv.contentCount(list)
	if count <= s then
		return s
	end
	local used: { [number]: boolean } = {}
	for _, t in list do
		used[t.pos :: number] = true
	end
	for i = s, count - 1 do
		if not used[i] then
			return i
		end
	end
	if count < cap then
		return count
	end
	for i = 0, s - 1 do
		if not used[i] then
			return i
		end
	end
	return -1
end

--- Inventory.AddAt: refused when pos >= Capacity or occupied
function Inv.addAt(list: { Inst }, t: Inst, pos: number, cap: number): boolean
	if pos < 0 or pos >= cap then
		return false
	end
	Inv.layout(list)
	if Inv.itemAt(list, pos) then
		return false
	end
	t.pos = pos
	local k = 1
	while k <= #list and (list[k].pos :: number) < pos do
		k += 1
	end
	table.insert(list, k, t)
	return true
end

--- Inventory.AddItem: AddAt(GetFirstEmptyPosition(0)); no merging. False when full.
function Inv.addFirstEmpty(list: { Inst }, t: Inst, cap: number): boolean
	local at = Inv.firstEmpty(list, cap, 0)
	return at >= 0 and Inv.addAt(list, t, at, cap)
end

--- Inventory.RemoveAt / RemoveItem: the cell becomes empty, the others keep their positions
function Inv.removeInst(list: { Inst }, t: Inst): boolean
	local k = table.find(list, t)
	if not k then
		return false
	end
	table.remove(list, k)
	return true
end

function Inv.maxStackOf(id: string): number
	local d = def(id)
	return (d and d.maxStack) or 1
end

--- Item.Combine: move min(room, other count) onto `onto`; returns the count moved
function Inv.combine(onto: Inst, from: Inst): number
	if onto == from or onto.id ~= from.id or Inv.maxStackOf(onto.id) <= 1 then
		return 0
	end
	local room = Inv.maxStackOf(onto.id) - onto.n
	if room <= 0 then
		return 0
	end
	local n = math.min(room, from.n)
	onto.n += n
	from.n -= n
	return n
end

--- ItemUtilities.AddAndMerge(inventory, item, start): a stackable item first combines into the stacks with the same id
--- (position order) that have room, then the rest goes to GetFirstEmptyPosition(start) (false when there is none: the
--- rest stays in `inst`)
function Inv.addAndMerge(list: { Inst }, inst: Inst, cap: number, start: number?): boolean
	Inv.layout(list)
	if Inv.maxStackOf(inst.id) > 1 then
		for _, s in list do
			if inst.n <= 0 then
				break
			end
			if s ~= inst and s.id == inst.id and s.n < Inv.maxStackOf(s.id) then
				Inv.combine(s, inst)
			end
		end
		if inst.n <= 0 then
			return true
		end
	end
	local at = Inv.firstEmpty(list, cap, start)
	if at < 0 then
		return false
	end
	inst.pos = nil
	return Inv.addAt(list, inst, at, cap)
end

-- ---------------------------------------------------------------- locks
--- Inventory.ToggleLockIndex
function Inv.toggleLock(locks: { number }, pos: number)
	local at = table.find(locks, pos)
	if at then
		table.remove(locks, at)
	else
		table.insert(locks, pos)
	end
end

-- ---------------------------------------------------------------- sort
local SORT = Items.sortMeta :: { [string]: { any } }
local TAG_PRIORITY = Items.tagPriority :: { [string]: number }
local function sortMeta(id: string): (number, number, string?)
	local d = def(id)
	local m = SORT[id]
	return (d and d.typeID) or math.huge, (m and m[1]) or 0, m and m[2]
end

--- Inventory.TryMerge on one id group (list order): popped from the end; each target takes Combine from the next popped
--- items until full; leftovers carry on
local function tryMerge(group: { Inst }): { Inst }
	local stack = table.clone(group)
	local out: { Inst } = {}
	local target: Inst? = nil
	while #stack > 0 do
		if not target then
			target = table.remove(stack)
			if #stack <= 0 then
				table.insert(out, target :: Inst)
				break
			end
		end
		local t = target :: Inst
		local nextOne: Inst? = nil
		while t.n < Inv.maxStackOf(t.id) and #stack > 0 do
			nextOne = table.remove(stack)
			Inv.combine(t, nextOne :: Inst)
		end
		table.insert(out, t)
		if nextOne and nextOne.n > 0 then
			if #stack <= 0 then
				table.insert(out, nextOne)
				break
			end
			target = nextOne
		else
			target = nil
		end
	end
	return out
end

--- Inventory.Sort: every item not at a locked index is taken out, grouped by first tag (Tag.priority, no tag = -1, then
--- the tag name ignoring case), inside a group by id (Item.order, then TypeID); stackable groups merge with TryMerge; then
--- each goes back with AddItem (the first empty position)
function Inv.sort(list: { Inst }, locks: { number }, cap: number)
	Inv.layout(list)
	local locked: { [number]: boolean } = {}
	for _, l in locks do
		locked[l] = true
	end
	local moving: { Inst } = {}
	for _, s in list do
		if not locked[s.pos :: number] then
			table.insert(moving, s)
		end
	end
	for _, s in moving do
		Inv.removeInst(list, s)
	end
	local byTag: { [string]: { Inst } } = {}
	local tagOrder: { string } = {}
	local NONE = "\0"
	for _, s in moving do
		local _, _, tag = sortMeta(s.id)
		local k = tag or NONE
		if not byTag[k] then
			byTag[k] = {}
			table.insert(tagOrder, k)
		end
		table.insert(byTag[k], s)
	end
	local function prio(k: string): number
		return if k == NONE then -1 else (TAG_PRIORITY[k] or 0)
	end
	table.sort(tagOrder, function(a, b)
		local pa, pb = prio(a), prio(b)
		if pa ~= pb then
			return pa < pb
		end
		local x = if a == NONE then "" else string.upper(a)
		local y = if b == NONE then "" else string.upper(b)
		return x < y
	end)
	local result: { Inst } = {}
	for _, k in tagOrder do
		local byType: { [string]: { Inst } } = {}
		local typeOrder: { string } = {}
		for _, s in byTag[k] do
			if not byType[s.id] then
				byType[s.id] = {}
				table.insert(typeOrder, s.id)
			end
			table.insert(byType[s.id], s)
		end
		table.sort(typeOrder, function(a, b)
			local ta, oa = sortMeta(a)
			local tb, ob = sortMeta(b)
			if oa ~= ob then
				return oa < ob
			end
			if ta ~= tb then
				return ta < tb
			end
			return a < b
		end)
		for _, id in typeOrder do
			local g = byType[id]
			for _, s in (if Inv.maxStackOf(id) > 1 then tryMerge(g) else g) do
				table.insert(result, s)
			end
		end
	end
	for _, s in result do
		if s.n > 0 then
			s.pos = nil
			if not Inv.addFirstEmpty(list, s, math.max(cap, Inv.contentCount(list) + 1)) then
				table.insert(list, s)
			end
		end
	end
end

-- ---------------------------------------------------------------- capacity
--- the repack of CharacterMainControl.UpdateInventoryCapacity: when content.Count >= the new capacity, every item at an
--- index >= capacity is taken out and put back with AddAndMerge(inventory, item, 0); what does not fit is returned (the
--- caller drops it at the character)
function Inv.shrink(list: { Inst }, cap: number): { Inst }
	Inv.layout(list)
	if Inv.contentCount(list) < cap then
		return {}
	end
	local out: { Inst } = {}
	for _, s in list do
		if (s.pos :: number) >= cap then
			table.insert(out, s)
		end
	end
	for _, s in out do
		Inv.removeInst(list, s)
	end
	local dropped: { Inst } = {}
	for _, s in out do
		s.pos = nil
		if not Inv.addAndMerge(list, s, cap, 0) then
			table.insert(dropped, s)
		end
	end
	return dropped
end

-- ---------------------------------------------------------------- stacks (Profile.ts)
--- a fresh instance of `id` (firearms carry their magazine)
function Inv.new(id: string, n: number, ammo: number?): Inst
	local t: Inst = { id = id, n = n }
	local d = def(id)
	if d and d.fire then
		t.ammo = ammo or 0
		-- the rounds in the magazine are the gun's default type until a reload loads another
		t.loaded = d.fire.ammo
	end
	return t
end

--- Profile.addItem: AddAndMerge per new stack (existing stacks in position order, then the first empty position);
--- returns the count that did not fit
function Inv.addItem(list: { Inst }, id: string, count: number, cap: number, ammo: number?): number
	local max = Inv.maxStackOf(id)
	local left = count
	Inv.layout(list)
	if max > 1 then
		for _, s in list do
			if s.id == id and s.n < max then
				local put = math.min(max - s.n, left)
				s.n += put
				left -= put
				if left <= 0 then
					return 0
				end
			end
		end
	end
	while left > 0 do
		local at = Inv.firstEmpty(list, cap, 0)
		if at < 0 or at >= cap then
			break
		end
		local put = math.min(max, left)
		local t = Inv.new(id, put, ammo)
		Inv.addAt(list, t, at, cap)
		left -= put
	end
	return left
end

--- Profile.addInst: a copy of `inst` into the list (single items keep their state; stacks merge). Sets inst.n to what
--- did not fit; true when everything went in
function Inv.addInst(list: { Inst }, inst: Inst, cap: number): boolean
	local d = def(inst.id)
	if (d and d.kind == "firearm") or Inv.maxStackOf(inst.id) == 1 then
		local copy = table.clone(inst)
		copy.pos = nil
		copy.revealed = nil
		local ok = Inv.addAndMerge(list, copy, cap)
		if ok then
			inst.n = 0
		end
		return ok
	end
	local left = Inv.addItem(list, inst.id, inst.n, cap)
	inst.n = left
	return left == 0
end

function Inv.count(list: { Inst }, id: string): number
	local c = 0
	for _, s in list do
		if s.id == id then
			c += s.n
		end
	end
	return c
end

--- Profile.removeItem: from the last stack backwards; returns the count removed
function Inv.remove(list: { Inst }, id: string, count: number): number
	local left = count
	for i = #list, 1, -1 do
		if left <= 0 then
			break
		end
		local s = list[i]
		if s.id == id then
			local take = math.min(s.n, left)
			s.n -= take
			left -= take
			if s.n <= 0 then
				table.remove(list, i)
			end
		end
	end
	return count - left
end

-- ---------------------------------------------------------------- equipment
Inv.EQUIP_SLOTS = { "firearm1", "firearm2", "melee", "head", "body", "face", "headset", "backpack", "totem1", "totem2" }
Inv.SLOT_KIND = { firearm1 = "firearm", firearm2 = "firearm", melee = "melee", head = "helmet", body = "armor", face = "face",
	headset = "headset", backpack = "backpack", totem1 = "totem", totem2 = "totem" }
Inv.SLOT_LABEL = { firearm1 = "Firearm", firearm2 = "Firearm", melee = "Melee Weapon", head = "Head", body = "Body",
	face = "Face", headset = "Headphones", backpack = "Backpack", totem1 = "Totem", totem2 = "Totem" }
-- empty equipment slots show a faint silhouette of what goes there (Slot.SlotIcon)
Inv.SLOT_GHOST = { firearm1 = "tt33", firearm2 = "tt33", melee = "stick", head = "helmet_l1", body = "armor_l1", face = "gasmask",
	headset = "headphones", backpack = "pack_school", totem1 = "totem_hp", totem2 = "totem_hp" }

--- Profile.slotFor: the first empty slot of the item's kind, else the first of them
function Inv.slotFor(eq: { [string]: Inst? }, id: string): string?
	local d = def(id)
	local kind = d and d.kind
	local first: string? = nil
	for _, s in Inv.EQUIP_SLOTS do
		if Inv.SLOT_KIND[s] == kind then
			if not eq[s] then
				return s
			end
			first = first or s
		end
	end
	return first
end

function Inv.isEquippable(id: string): boolean
	local d = def(id)
	local kind = d and d.kind
	for _, s in Inv.EQUIP_SLOTS do
		if Inv.SLOT_KIND[s] == kind then
			return true
		end
	end
	return false
end

--- Profile.bagCapacity: 10 base slots + the backpack's + the body armor's + a bonus
function Inv.bagCapacity(eq: { [string]: Inst? }, bonus: number?): number
	local function slots(t: Inst?): number
		local d = t and def(t.id)
		return (d and d.gear and d.gear.slots) or 0
	end
	return Items.basePocketSlots + slots(eq.backpack) + slots(eq.body) + (bonus or 0)
end

--- extra carry from the backpack (GEAR.carry, kg)
function Inv.carryBonus(eq: { [string]: Inst? }): number
	local d = eq.backpack and def((eq.backpack :: Inst).id)
	return (d and d.gear and d.gear.carry) or 0
end

--- durability maximum: guns 100, gear its dur, else 0 (data.ts maxDurability)
function Inv.maxDurability(id: string): number
	local d = def(id)
	if d and d.fire then
		return 100
	end
	return (d and d.gear and d.gear.dur) or 0
end

--- consumables (data.ts CONSUMABLES): the item's use row
function Inv.consumable(id: string): any
	local d = def(id)
	return d and d.use
end

-- ---------------------------------------------------------------- attachments (data.ts GUN_SLOTS / PARTS)
Inv.SLOT_NAMES = { Scope = "Scope", Muzzle = "Muzzle", Grip = "Grip", Stock = "Stock", Mag = "Magazine", Tec = "Tactical" }
local GUN_SLOTS = Items.gunSlots :: { [string]: { { key: string, req: { string }, exc: { string } } } }
local PARTS = Items.parts :: { [string]: { string } }

function Inv.gunSlots(id: string): { { key: string, req: { string }, exc: { string } } }
	return GUN_SLOTS[id] or {}
end

function Inv.isPart(id: string): boolean
	return PARTS[id] ~= nil
end

--- partFits: the part has every required tag and none of the excluded ones
function Inv.partFits(slot: { key: string, req: { string }, exc: { string } }, partId: string): boolean
	local tags = PARTS[partId]
	if not tags then
		return false
	end
	for _, t in slot.req do
		if not table.find(tags, t) then
			return false
		end
	end
	for _, t in slot.exc do
		if table.find(tags, t) then
			return false
		end
	end
	return true
end

--- data.ts gunFeel: the raw gun stats with the fitted parts' mods (type 0 add, 100 percentage add, else multiply)
local feelCache: { [string]: any } = {}
function Inv.gunFeel(inst: { id: string, att: { [string]: string }? }): any
	local base = Items.gunFeel[inst.id]
	if not base then
		return nil
	end
	local parts: { string } = {}
	for _, pid in (inst.att or {}) :: { [string]: string } do
		if Items.feelParts[pid] then
			table.insert(parts, pid)
		end
	end
	if #parts == 0 then
		return base
	end
	table.sort(parts)
	local key = inst.id .. "|" .. table.concat(parts, ",")
	local hit = feelCache[key]
	if hit then
		return hit
	end
	local add, pct, mul = {}, {}, {}
	for _, pid in parts do
		for _, m in Items.feelParts[pid] do
			local k, t, v = m[1], m[2], m[3]
			if t == 0 then
				add[k] = (add[k] or 0) + v
			elseif t == 100 then
				pct[k] = (pct[k] or 0) + v
			else
				mul[k] = (mul[k] or 1) * math.max(0, 1 + v)
			end
		end
	end
	local out = {}
	for k, v in base do
		if typeof(v) == "number" then
			out[k] = (v + (add[k] or 0)) * math.max(0, 1 + (pct[k] or 0)) * (mul[k] or 1)
		else
			out[k] = v
		end
	end
	feelCache[key] = out
	return out
end

return Inv
