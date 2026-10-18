--!strict
-- The LootView's item operations, server-authoritative, 1:1 with the web build's src/ui/InventoryUI.ts (the source's
-- InventoryEntry / SlotDisplay / ItemOperationMenu / ItemSplitDialogue handlers): every mutation the web UI makes on the
-- player's lists happens here on the raid state, and the full view state goes back to the owner ("Inv").
--
-- Refs name a cell: { src = "bag" | "eq" | "loot" | "pet" | "hot" | "mod", i = string } (bag / loot / pet: the 0-based
-- position; eq: the slot; hot: 0..5; mod: "<src>~<i>|<slotKey>", a slot of the item at that ref).
-- Client -> server: InvOp(op, ...):
--   "act", ref                       double click / F (InventoryUI.act)
--   "drop", from, to, ctrl           a drag released over a cell (onUp: hotbar bind, attach, dropOnEntry, transfer)
--   "menu", m, ref                   ItemOperationMenu: use / hotbar / equip / unload / pet / drop / wish
--   "split", src, i, n, to?          ItemSplitDialogue.DoSplit (to = { src, pos } after a Ctrl + drag)
--   "unplug", ref                    Alt + click on a fitted part
--   "hot", k, ref                    hover + 3..8 on a bag item
--   "lock", ref | "wish", ref | "dropx", ref | "btn", name ("sort" / "takeall")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Config = require(Shared.Config)
local Items = require(Shared.gen.Items)
local Inv = require(Shared.Inv)
local Guns = require(Shared.Guns)
local Raid = require(script.Parent.Raid)
local Loot = require(script.Parent.Loot)
local Weapons = require(script.Parent.Weapons)
local Actions = require(script.Parent.Actions)

type Inst = Inv.Inst
type Ref = { src: string, i: string }

local Inventory = {}

local function def(id: string): any
	return Items.items[id]
end

local function toast(p: Player, msg: string)
	Net.event("Toast"):FireClient(p, msg, "bad")
end

-- client intent is untrusted: a ref is a known source and a short index string; numbers must be finite integers
local SOURCES = { bag = true, eq = true, loot = true, pet = true, hot = true, mod = true }
local function refOf(v: any): Ref?
	if typeof(v) ~= "table" or typeof(v.src) ~= "string" or not SOURCES[v.src] then
		return nil
	end
	if typeof(v.i) ~= "string" and typeof(v.i) ~= "number" then
		return nil
	end
	local i = tostring(v.i)
	if #i > 64 then
		return nil
	end
	return { src = v.src, i = i }
end

local function int(v: any): number?
	if typeof(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge or v ~= math.floor(v) then
		return nil
	end
	return v
end

local function profileOf(p: Player): any
	return Raid.profiles[p]
end

--- the dog's bag (a secure container that survives death): the profile's petBag, 1 + perk slots
local function pet(p: Player): ({ Inst }, number)
	local prof = profileOf(p)
	if not prof then
		return {}, 1
	end
	prof.petBag = prof.petBag or {}
	return prof.petBag, 1
end

local function lootBox(p: Player): any
	local b = Loot.openOf(p)
	return b
end

-- ------------------------------------------------------------------ lists and grids
--- the Inst list behind a source: backpack, dog's bag
local function listOf(p: Player, src: string): ({ Inst }?, number)
	local r = Raid.raids[p]
	if not r then
		return nil, 0
	end
	if src == "bag" then
		return r.bag, Raid.cap(r)
	elseif src == "pet" then
		return pet(p)
	end
	return nil, 0
end

type Grid = { cap: number, at: (number) -> Inst?, add: (Inst, number) -> boolean, remove: (Inst) -> () }

--- an inventory grid as positions (InventoryUI.grid): the item at a position, AddAt a position, remove an item
local function grid(p: Player, src: string): Grid?
	local list, cap = listOf(p, src)
	if list then
		local l = list :: { Inst }
		return {
			cap = cap,
			at = function(k)
				return Inv.itemAt(l, k)
			end,
			add = function(inst, k)
				inst.pos = nil
				inst.revealed = nil
				return Inv.addAt(l, inst, k, cap)
			end,
			remove = function(inst)
				Inv.removeInst(l, inst)
			end,
		}
	end
	local b = if src == "loot" then lootBox(p) else nil
	if not b then
		return nil
	end
	return {
		cap = Loot.slotsOf(b),
		at = function(k)
			local s = Inv.itemAt(b.items, k)
			return if s and s.revealed then s else nil
		end,
		add = function(inst, k)
			inst.pos = nil
			inst.revealed = true
			return Inv.addAt(b.items, inst, k, Loot.slotsOf(b))
		end,
		remove = function(inst)
			Inv.removeInst(b.items, inst)
		end,
	}
end

--- ItemUtilities.AddAndMerge into a list; past its capacity the item still goes in
local function put(list: { Inst }, inst: Inst, cap: number)
	inst.pos = nil
	inst.revealed = nil
	if not Inv.addAndMerge(list, inst, cap) then
		table.insert(list, inst)
	end
end

--- an item into a loot container's first empty position (Inventory.AddItem)
local function putLoot(b: any, inst: Inst)
	inst.pos = nil
	inst.revealed = true
	if not Inv.addFirstEmpty(b.items, inst, Loot.slotsOf(b)) then
		table.insert(b.items, inst)
	end
end

-- ------------------------------------------------------------------ the held weapon
local HELD_OF = { firearm1 = "gun", firearm2 = "gun2", melee = "melee" }
local SLOT_OF = { gun = "firearm1", gun2 = "firearm2", melee = "melee" }

--- Player.switchTo after an equipment change: the active slot emptied -> firearm1, firearm2, else melee
local function syncHeld(p: Player, prefer: string?)
	local r = Raid.raids[p]
	if not r then
		return
	end
	local x = r :: any
	local cur = SLOT_OF[x.held or "gun"]
	if prefer and r.eq[prefer] and not (cur and r.eq[cur]) then
		Actions.setHeld(p, HELD_OF[prefer])
	elseif cur and not r.eq[cur] then
		local nxt = if r.eq.firearm1 then "firearm1" elseif r.eq.firearm2 then "firearm2" else "melee"
		Actions.setHeld(p, HELD_OF[nxt])
	end
	if p.Character then
		p.Character:SetAttribute("Held", if x.held == "melee" then "melee" else "gun")
	end
end

local function unequip(p: Player, slot: string)
	local r = Raid.raids[p]
	if not r then
		return
	end
	r.eq[slot] = nil
	syncHeld(p)
end

--- equip one of `inst`: `remove` takes it out of its inventory, `place` puts the item it replaces back there
local function equipFrom(p: Player, inst: Inst, remove: () -> (), place: (Inst) -> ())
	local r = Raid.raids[p]
	if not r then
		return
	end
	local slot = Inv.slotFor(r.eq, inst.id)
	if not slot then
		return
	end
	local prev = r.eq[slot]
	local worn = table.clone(inst)
	worn.n = 1
	worn.pos = nil
	worn.revealed = nil
	local d = def(inst.id)
	if d and d.gear and d.gear.dur and worn.dur == nil then
		worn.dur = d.gear.dur
	end
	if d and d.fire then
		worn.ammo = worn.ammo or 0
		worn.dur = worn.dur or 100
		worn.loaded = worn.loaded or d.fire.ammo
	end
	r.eq[slot] = worn
	if inst.n > 1 then
		inst.n -= 1
	else
		remove()
	end
	if prev then
		place(prev)
	end
	if slot == "firearm1" or slot == "firearm2" or slot == "melee" then
		syncHeld(p, slot)
	end
end

-- ------------------------------------------------------------------ attachments
local function ownerOf(p: Player, key: string): Inst?
	local src, i = string.match(key, "^(%a+)~(.*)$")
	if not src then
		return nil
	end
	local r = Raid.raids[p]
	if not r then
		return nil
	end
	if src == "eq" then
		return r.eq[i :: string]
	end
	local g = grid(p, src :: string)
	return g and g.at(tonumber(i) or -1)
end

--- smaller magazine: rounds that no longer fit go back to the backpack
local function clampMag(p: Player, inst: Inst)
	local r = Raid.raids[p]
	local f = Inv.gunFeel(inst)
	if not r or not f or (inst.ammo or 0) <= f.Capacity then
		return
	end
	local extra = (inst.ammo or 0) - math.floor(f.Capacity)
	inst.ammo = math.floor(f.Capacity)
	local ammoId = inst.loaded or Guns.ammoOf(inst.id)
	if ammoId then
		Inv.addItem(r.bag, ammoId, extra, Raid.cap(r))
	end
end

--- fit a part from a list into a gun slot (swapping out what was there)
local function attach(p: Player, list: { Inst }, part: Inst?, gun: Inst?, slotKey: string?): boolean
	local r = Raid.raids[p]
	if not r or not part or not gun or not def(gun.id) or not def(gun.id).fire then
		return false
	end
	local target = nil
	for _, s in Inv.gunSlots(gun.id) do
		if Inv.partFits(s, part.id) and (slotKey == nil or s.key == slotKey) then
			if slotKey or not (gun.att and gun.att[s.key]) then
				target = s
				break
			end
			target = target or s
		end
	end
	if not target then
		return false
	end
	local att = table.clone(gun.att or {})
	local prev = att[target.key]
	att[target.key] = part.id
	gun.att = att
	if part.n > 1 then
		part.n -= 1
	else
		Inv.removeInst(list, part)
	end
	if prev then
		put(list, { id = prev, n = 1 }, Raid.cap(r))
	end
	clampMag(p, gun)
	return true
end

local function detach(p: Player, gun: Inst?, slotKey: string)
	local r = Raid.raids[p]
	if not r or not gun or not gun.att or not gun.att[slotKey] then
		return
	end
	if Inv.firstEmpty(r.bag, Raid.cap(r)) < 0 then
		return toast(p, "Backpack full")
	end
	local att = table.clone(gun.att)
	local id = att[slotKey]
	att[slotKey] = nil
	gun.att = att
	Inv.addInst(r.bag, { id = id, n = 1 }, Raid.cap(r))
	clampMag(p, gun)
end

--- Alt + click on a fitted part: to the inventory, else it falls at the character
local function unplugAlt(p: Player, gun: Inst?, slotKey: string)
	local r = Raid.raids[p]
	if not r or not gun or not gun.att or not gun.att[slotKey] then
		return
	end
	local att = table.clone(gun.att)
	local id = att[slotKey]
	att[slotKey] = nil
	gun.att = att
	local part: Inst = { id = id, n = 1 }
	if not Inv.addInst(r.bag, part, Raid.cap(r)) then
		local pos = Raid.posOf(p)
		if pos then
			Loot.dropPile(pos.X, pos.Z, { id = id, n = 1 })
		end
		toast(p, "Backpack full. Dropped on the ground")
	end
	clampMag(p, gun)
end

--- the gun that can take this part: the active one first
local function gunFor(p: Player, partId: string): Inst?
	local r = Raid.raids[p]
	if not r or not Inv.isPart(partId) then
		return nil
	end
	local order = if (r :: any).held == "gun2" then { "firearm2", "firearm1" } else { "firearm1", "firearm2" }
	for _, k in order do
		local g = r.eq[k]
		if g then
			for _, s in Inv.gunSlots(g.id) do
				if Inv.partFits(s, partId) then
					return g
				end
			end
		end
	end
	return nil
end

-- ------------------------------------------------------------------ the double click / F action
local function act(p: Player, t: Ref)
	local r = Raid.raids[p]
	if not r then
		return
	end
	local i = tonumber(t.i) or -1
	local b = lootBox(p)
	local cap = Raid.cap(r)
	if t.src == "bag" then
		local inst = Inv.itemAt(r.bag, i)
		if not inst then
			return
		end
		if b then
			if Inv.firstEmpty(b.items, Loot.slotsOf(b)) < 0 then
				return toast(p, "Container is full")
			end
			Inv.removeInst(r.bag, inst)
			putLoot(b, inst)
		elseif Inv.isEquippable(inst.id) then
			equipFrom(p, inst, function()
				Inv.removeInst(r.bag, inst)
			end, function(prev)
				put(r.bag, prev, cap)
			end)
		elseif Inv.isPart(inst.id) then
			local gun = gunFor(p, inst.id)
			if not gun or not attach(p, r.bag, inst, gun) then
				return toast(p, "No compatible firearm")
			end
		end
	elseif t.src == "mod" then
		local owner, key = string.match(t.i, "^(.*)|(.*)$")
		if owner and key then
			detach(p, ownerOf(p, owner), key)
		end
	elseif t.src == "eq" then
		local slot = t.i
		local inst = r.eq[slot]
		if not inst then
			return
		end
		-- no capacity check on a backpack / vest: what no longer fits is repacked or dropped (Inv.shrink below)
		local copy = table.clone(inst)
		if Inv.addInst(r.bag, copy, cap) then
			r.eq[slot] = nil
		else
			local pos = Raid.posOf(p)
			if pos then
				Loot.dropPile(pos.X, pos.Z, inst)
			end
			r.eq[slot] = nil
			toast(p, "Backpack full. Dropped on the ground")
		end
		syncHeld(p)
	elseif t.src == "loot" then
		if not b then
			return
		end
		local s = Inv.itemAt(b.items, i)
		if not s or not s.revealed then
			return
		end
		-- LootView quick-move: an equippable goes straight into an empty matching slot
		local slot = if Inv.isEquippable(s.id) then Inv.slotFor(r.eq, s.id) else nil
		if slot and not r.eq[slot] then
			equipFrom(p, s, function()
				Inv.removeInst(b.items, s)
			end, function(prev)
				putLoot(b, prev)
			end)
		else
			local copy = table.clone(s)
			copy.revealed = nil
			if Inv.addInst(r.bag, copy, cap) then
				Inv.removeInst(b.items, s)
			else
				s.n = copy.n
				return toast(p, "Backpack full")
			end
		end
	elseif t.src == "hot" then
		if i >= 0 and i <= 5 then
			r.hotbar[i + 1] = ""
		end
	elseif t.src == "pet" then
		local list, _ = pet(p)
		local inst = Inv.itemAt(list, i)
		if not inst then
			return
		end
		local copy = table.clone(inst)
		if Inv.addInst(r.bag, copy, cap) then
			Inv.removeInst(list, inst)
		else
			return toast(p, "Backpack full")
		end
	end
end

-- ------------------------------------------------------------------ drag and drop
--- InventoryEntry.OnDrop: an empty entry -> AddAt(index); the same id and stackable -> Combine; else, from an inventory,
--- the two swap indexes; a slotted (equipped) item dropped on an occupied entry does nothing
local function dropOnEntry(p: Player, from: Ref, to: Ref)
	local r = Raid.raids[p]
	local tb = grid(p, to.src)
	local pos = tonumber(to.i) or -1
	if not r or not tb or not (pos >= 0 and pos < tb.cap) then
		return
	end
	local fromEq = from.src == "eq"
	local fb = if fromEq then nil else grid(p, from.src)
	local item = if fromEq then r.eq[from.i] else (fb and fb.at(tonumber(from.i) or -1))
	if not item then
		return
	end
	local content = tb.at(pos)
	local function takeOut()
		if fromEq then
			unequip(p, from.i)
		elseif fb then
			fb.remove(item :: Inst)
		end
	end
	if not content then
		takeOut()
		tb.add(item :: Inst, pos)
		return
	end
	if content == item then
		return
	end
	if content.id == item.id and Inv.maxStackOf(item.id) > 1 then
		Inv.combine(content, item)
		if item.n <= 0 then
			takeOut()
		end
		return
	end
	if not fb then
		return
	end
	local back = item.pos :: number
	fb.remove(item)
	tb.remove(content)
	fb.add(content, back)
	tb.add(item, pos)
end

local function usable(id: string): boolean
	local d = def(id)
	return Inv.consumable(id) ~= nil or (d ~= nil and d.kind == "throwable")
end

local function bindHot(r: any, k: number, id: string)
	local prev = table.find(r.hotbar, id)
	if prev then
		r.hotbar[prev] = ""
	end
	r.hotbar[k + 1] = id
end

local function onDrop(p: Player, from: Ref, to: Ref)
	local r = Raid.raids[p]
	if not r then
		return
	end
	if to.src == "hot" then
		local inst = if from.src == "bag" then Inv.itemAt(r.bag, tonumber(from.i) or -1) else nil
		local k = tonumber(to.i) or -1
		if inst and usable(inst.id) and k >= 0 and k <= 5 then
			bindHot(r, k, inst.id)
		end
	elseif to.src == "mod" and from.src == "bag" then
		local owner, key = string.match(to.i, "^(.*)|(.*)$")
		local inst = Inv.itemAt(r.bag, tonumber(from.i) or -1)
		local target = owner and ownerOf(p, owner)
		if not target or not attach(p, r.bag, inst, target, key) then
			toast(p, "Does not fit")
		end
	elseif (to.src == "bag" or to.src == "pet" or to.src == "loot") and from.src ~= "mod" then
		dropOnEntry(p, from, to)
	elseif to.src ~= from.src then
		act(p, from)
	end
end

-- ------------------------------------------------------------------ the operation menu
local function onMenu(p: Player, m: string, t: Ref)
	local r = Raid.raids[p]
	if not r then
		return
	end
	local i = tonumber(t.i) or -1
	local list, cap = listOf(p, t.src)
	local b = lootBox(p)
	local target: Inst? = if t.src == "eq" then r.eq[t.i]
		elseif t.src == "loot" then (b and Inv.itemAt(b.items, i))
		elseif list then Inv.itemAt(list, i)
		else nil
	if t.src == "loot" and target and not target.revealed then
		return
	end
	if m == "unload" and target and def(target.id) and def(target.id).fire then
		-- ItemOperationMenu Unload: the rounds back to the bag as their ammo type
		local n = target.ammo or 0
		local ammoId = target.loaded or Guns.ammoOf(target.id)
		if n > 0 and ammoId then
			local left = Inv.addItem(r.bag, ammoId, n, Raid.cap(r))
			target.ammo = left
			if left > 0 then
				toast(p, "Backpack full")
			end
		end
	elseif m == "wish" and target then
		local prof = profileOf(p)
		if prof then
			prof.wish = prof.wish or {}
			local at = table.find(prof.wish, target.id)
			if at then
				table.remove(prof.wish, at)
			else
				table.insert(prof.wish, target.id)
			end
		end
	elseif m == "equip" and target then
		if list then
			local l = list :: { Inst }
			equipFrom(p, target, function()
				Inv.removeInst(l, target :: Inst)
			end, function(prev)
				put(l, prev, cap)
			end)
		elseif t.src == "loot" and b then
			equipFrom(p, target, function()
				Inv.removeInst(b.items, target :: Inst)
			end, function(prev)
				putLoot(b, prev)
			end)
		end
	elseif m == "hotbar" and list and target then
		if not table.find(r.hotbar, target.id) then
			local free = table.find(r.hotbar, "")
			r.hotbar[free or 6] = target.id
		end
	elseif m == "use" and list and target then
		Actions.useItem(p, target.id)
	elseif m == "pet" and list and target and t.src == "bag" then
		local pl, pcap = pet(p)
		if Inv.firstEmpty(pl, pcap) >= 0 then
			Inv.removeInst(list, target)
			put(pl, target, pcap)
		end
	elseif m == "drop" and list and target and t.src == "bag" then
		Inv.removeInst(list, target)
		local pos = Raid.posOf(p)
		if pos then
			Loot.dropPile(pos.X, pos.Z, target)
		end
	end
end

-- ------------------------------------------------------------------ split
--- SplitDialogue.DoSplit: the new stack goes to the dropped-on index (Ctrl + drag onto an empty entry) or else the first
--- empty position
local function split(p: Player, src: string, i: number, n: number, to: any)
	local list, cap = listOf(p, src)
	local inst = list and Inv.itemAt(list, i)
	if not list or not inst or n < 1 or inst.n <= n then
		return
	end
	local part: Inst = { id = inst.id, n = math.floor(n) }
	local ok
	if typeof(to) == "table" and typeof(to.src) == "string" and typeof(to.pos) == "number" then
		local dest, dcap = listOf(p, to.src)
		ok = dest ~= nil and Inv.addAt(dest :: { Inst }, part, to.pos, dcap)
	else
		ok = Inv.addFirstEmpty(list, part, cap)
	end
	if not ok then
		toast(p, "Backpack full")
	else
		inst.n -= part.n
	end
end

-- ------------------------------------------------------------------ state
local function view(t: Inst): any
	return { id = t.id, n = t.n, pos = t.pos, ammo = t.ammo, dur = t.dur, loss = t.loss, uses = t.uses, att = t.att, loaded = t.loaded }
end

-- the owners looking at the LootView get its state, at most once a frame
local viewing: { [Player]: boolean } = {}
local dirty: { [Player]: boolean } = {}
local opening: { [Player]: boolean } = {}

--- the LootView's state for its owner (InventoryUI.refresh's inputs)
local function sendNow(p: Player, openLoot: boolean?)
	local r = Raid.raids[p]
	if not r then
		Net.event("Inv"):FireClient(p, nil)
		return
	end
	local prof = profileOf(p) or {}
	local eq = {}
	for _, k in Inv.EQUIP_SLOTS do
		if r.eq[k] then
			eq[k] = view(r.eq[k] :: Inst)
		end
	end
	local bag = {}
	Inv.layout(r.bag)
	for _, s in r.bag do
		table.insert(bag, view(s))
	end
	local pl, pcap = pet(p)
	Inv.layout(pl)
	local petView = {}
	for _, s in pl do
		table.insert(petView, view(s))
	end
	local cash = Inv.count(r.bag, "cash") + Inv.count(pl, "cash")
	local loot = nil
	local b, searching = Loot.openOf(p)
	if b then
		local items = {}
		local firstHidden = nil
		for _, s in b.items do
			if s.revealed then
				table.insert(items, view(s))
			else
				firstHidden = firstHidden or s.pos
				table.insert(items, { pos = s.pos, hidden = true })
			end
		end
		loot = { id = b.id, name = Loot.nameOf(b), slots = Loot.slotsOf(b), items = items, searching = searching, firstHidden = firstHidden }
	end
	Net.event("Inv"):FireClient(p, {
		eq = eq,
		bag = bag,
		cap = Raid.cap(r),
		hotbar = table.clone(r.hotbar),
		locks = table.clone(r.locks),
		wish = table.clone(prof.wish or {}),
		pet = { items = petView, cap = pcap },
		money = prof.money or 0,
		cash = cash,
		weight = p:GetAttribute("Weight") or 0,
		carry = p:GetAttribute("Carry") or Config.Weight.carry,
		held = (r :: any).held or "gun",
		loot = loot,
		open = openLoot,
	})
end

--- after a change: repack past a shrunk capacity (UpdateInventoryCapacity), sync the held gun / ammo / HUD attributes
--- queue the state for its owner (opening a container shows the LootView with the loot pane)
function Inventory.send(p: Player, openLoot: boolean?)
	if openLoot then
		opening[p] = true
		viewing[p] = true
	end
	if viewing[p] then
		dirty[p] = true
	end
end

local function changed(p: Player)
	local r = Raid.raids[p]
	if not r then
		return
	end
	for _, s in Inv.shrink(r.bag, Raid.cap(r)) do
		local pos = Raid.posOf(p)
		if pos then
			Loot.dropPile(pos.X, pos.Z, s)
		end
	end
	local b = Loot.openOf(p)
	if b then
		Loot.changed(b) -- also refreshes this player
	end
	Weapons.cancelReload(p)
	Weapons.syncAmmo(p) -- -> Raid.sendBag -> Inventory.send
end

-- a token bucket per player: 20 ops a second sustained, bursts of 40 (a fast drag-and-drop session stays well under)
local buckets: { [Player]: { t: number, n: number } } = {}
local function allow(p: Player): boolean
	local now = os.clock()
	local b = buckets[p] or { t = now, n = 40 }
	b.n = math.min(40, b.n + (now - b.t) * 20)
	b.t = now
	buckets[p] = b
	if b.n < 1 then
		return false
	end
	b.n -= 1
	return true
end

local function onOp(p: Player, op: any, a: any, b: any, c: any, d: any)
	if not allow(p) then
		return
	end
	local r = Raid.raids[p]
	if not r or not r.alive or typeof(op) ~= "string" then
		return
	end
	if op == "act" then
		local t = refOf(a)
		if t then
			act(p, t)
		end
	elseif op == "drop" then
		local f, t = refOf(a), refOf(b)
		if f and t then
			onDrop(p, f, t)
		end
	elseif op == "menu" then
		local t = refOf(b)
		if typeof(a) == "string" and t then
			onMenu(p, a, t)
		end
	elseif op == "split" then
		local to = nil
		if typeof(d) == "table" and (d.src == "bag" or d.src == "pet") and int(d.pos) then
			to = { src = d.src, pos = d.pos }
		end
		if (a == "bag" or a == "pet") and int(b) and int(c) and (c :: number) >= 1 then
			split(p, a, b, c, to)
		end
	elseif op == "unplug" then
		local t = refOf(a)
		local owner, key = if t then string.match(t.i, "^(.*)|(.*)$") else nil, nil
		if owner and key then
			unplugAlt(p, ownerOf(p, owner), key)
		end
	elseif op == "hot" then
		local t = refOf(b)
		local inst = if t and t.src == "bag" then Inv.itemAt(r.bag, tonumber(t.i) or -1) else nil
		if int(a) and a >= 0 and a <= 5 and inst and usable(inst.id) then
			bindHot(r, a, inst.id)
		end
	elseif op == "lock" then
		local t = refOf(a)
		if t and t.src == "bag" then
			Inv.toggleLock(r.locks, tonumber(t.i) or -1)
		end
	elseif op == "wish" then
		local t = refOf(a)
		if t then
			onMenu(p, "wish", t)
		end
	elseif op == "dropx" then
		local t = refOf(a)
		if t and t.src == "bag" then
			onMenu(p, "drop", t)
		end
	elseif op == "view" then
		-- the LootView opened / closed on the client
		viewing[p] = a == true or nil
		if viewing[p] then
			dirty[p] = true
		end
		return
	elseif op == "btn" then
		if a == "sort" then
			-- InventoryDisplay.OnSortButtonClicked -> Inventory.Sort
			Inv.sort(r.bag, r.locks, Raid.cap(r))
		elseif a == "takeall" then
			local box = lootBox(p)
			if box then
				local k = 1
				while k <= #box.items do
					local s = box.items[k]
					if s.revealed then
						local copy = table.clone(s)
						copy.revealed = nil
						if Inv.addInst(r.bag, copy, Raid.cap(r)) then
							table.remove(box.items, k)
							continue
						else
							s.n = copy.n
						end
					end
					k += 1
				end
			end
		end
	else
		return
	end
	changed(p)
end

function Inventory.start()
	Raid.onInv = function(p)
		Inventory.send(p)
	end
	Loot.onOpen = function(p)
		Inventory.send(p, true)
	end
	Loot.onChange = function(p)
		Inventory.send(p)
	end
	Loot.onClose = function(p)
		Inventory.send(p)
	end
	Net.event("InvOp").OnServerEvent:Connect(onOp)
	game:GetService("RunService").Heartbeat:Connect(function()
		for p in dirty do
			dirty[p] = nil
			if p.Parent then
				local o = opening[p]
				opening[p] = nil
				sendNow(p, o)
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(p)
		buckets[p] = nil
		viewing[p] = nil
		dirty[p] = nil
		opening[p] = nil
	end)
end

return Inventory
