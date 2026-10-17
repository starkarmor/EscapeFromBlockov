--!strict
-- Held slot, melee and item use (Player.ts ACTIONS, World.startMelee / updateMelee, applyUse):
-- 1 = firearm, V = melee (stick: 18 dmg, 2 swings/s, 1.55 m + 0.05 reach, damage at 0.12 s, crit 40% x1.4, cleaves the
-- front half-plane or anything within 0.5 + target radius); 3-8 = hotbar items with their decoded useTime (bandage 0.8 s:
-- +5 HP, -2 bleed; aspirin 1 s: +10 HP, -15 water; carrot / cocoa 2 s: energy and water). A dodge or a new action cancels.
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Net = require(Shared.Net)
local Items = require(Shared.gen.Items)
local Raid = require(script.Parent.Raid)
local Weapons = require(script.Parent.Weapons)

local Actions = {}
local using: { [Player]: { id: string, at: number, done: number } } = {}
local lastSwing: { [Player]: number } = {}

local function setHeld(p: Player, held: string)
	local r = Raid.raids[p]
	if not r or not r.alive then
		return
	end
	(r :: any).held = held
	if p.Character then
		p.Character:SetAttribute("Held", held)
	end
	Weapons.cancelReload(p)
end

local function melee(p: Player)
	local r = Raid.raids[p]
	if not r or not r.alive or (r :: any).held ~= "melee" then
		return
	end
	local m = Config.Melee[r.melee] or Config.Melee.stick
	local now = os.clock()
	if now - (lastSwing[p] or -math.huge) < (1 / m.attackSpeed) * 0.85 then
		return
	end
	lastSwing[p] = now
	if p.Character then
		p.Character:SetAttribute("MeleeAt", Workspace:GetServerTimeNow())
	end
	task.delay(m.dealTime, function()
		local rr = Raid.raids[p]
		local root = Raid.rootOf(p)
		local pos = Raid.posOf(p)
		if not rr or not rr.alive or not root or not pos then
			return
		end
		local look = root.CFrame.LookVector
		local fwd = Vector2.new(look.X, look.Z).Unit
		for key, t in Weapons.targets do
			if t.team == 0 then
				continue
			end
			local tp = t.pos()
			if not tp then
				continue
			end
			local d = Vector2.new(tp.X - pos.X, tp.Z - pos.Z)
			local dist = d.Magnitude
			local inFront = dist <= m.range + m.reach + t.radius and (dist < 1e-3 or d.Unit:Dot(fwd) >= 0)
			if inFront or dist <= 0.5 + t.radius then
				local crit = math.random() < m.critRate
				local dmg = m.damage * (if crit then m.critMul else 1)
				local killed = t.hurt(dmg, { from = p, crit = crit })
				Net.event("Hit"):FireClient(p, killed, crit, tp + Vector3.new(0, 1, 0), dmg)
			end
		end
	end)
end

local function useItem(p: Player, id: any)
	local r = Raid.raids[p]
	if not r or not r.alive or typeof(id) ~= "string" or using[p] then
		return
	end
	local def = Items.items[id]
	if not def or not def.use or Raid.count(r.bag, id) <= 0 then
		return
	end
	local t = def.use.useTime or 1
	local now = Workspace:GetServerTimeNow()
	using[p] = { id = id, at = os.clock(), done = os.clock() + t }
	p:SetAttribute("UseId", id)
	p:SetAttribute("UseStart", now)
	p:SetAttribute("UseUntil", now + t)
	Weapons.cancelReload(p)
end

function Actions.cancelUse(p: Player)
	if using[p] then
		using[p] = nil
		p:SetAttribute("UseId", nil)
	end
end

local function finishUse(p: Player, id: string)
	local r = Raid.raids[p]
	local def = Items.items[id]
	if not r or not def or not def.use then
		return
	end
	if Raid.take(r.bag, id, 1) <= 0 then
		return
	end
	local u = def.use
	if u.heal then
		r.hp = math.min(r.maxHp, r.hp + u.heal)
	end
	if u.energy then
		r.energy = math.clamp(r.energy + u.energy, 0, 100)
	end
	if u.hydration then
		r.water = math.clamp(r.water + u.hydration, 0, 100)
	end
	if u.bleedStacks then
		(r :: any).bleed = math.max(0, ((r :: any).bleed or 0) - u.bleedStacks)
	end
	Raid.syncVitals(p)
	Raid.sendBag(p)
	Weapons.syncAmmo(p)
	Net.event("Toast"):FireClient(p, "Used " .. (def.name or id), "good")
end

function Actions.start()
	Net.event("SelectSlot").OnServerEvent:Connect(function(p, slot)
		if slot == "gun" or slot == "gun2" or slot == "melee" then
			Actions.cancelUse(p)
			setHeld(p, slot)
			if p.Character then
				p.Character:SetAttribute("Held", if slot == "melee" then "melee" else "gun")
			end
			Weapons.syncAmmo(p)
		end
	end)
	Net.event("Equip").OnServerEvent:Connect(function(p, index)
		local r = Raid.raids[p]
		if not r or not r.alive or typeof(index) ~= "number" then
			return
		end
		local x = r :: any
		local st = r.bag[index]
		if not st then
			return
		end
		local def = Items.items[st.id]
		if not def then
			return
		end
		local function take()
			Raid.take(r.bag, st.id, 1)
		end
		if def.kind == "firearm" then
			take()
			local inst = { id = st.id, ammo = 0, dur = 100 }
			if not r.gun then
				r.gun = inst
			elseif not x.gun2 then
				x.gun2 = inst
			else
				local slot = if x.held == "gun2" then "gun2" else "gun"
				local old = if slot == "gun2" then x.gun2 else r.gun
				Raid.addItem(r.bag, old.id, 1)
				if old.ammo > 0 then
					Raid.addItem(r.bag, require(ReplicatedStorage.Shared.Guns).ammoOf(old.id) or "ammo_s_rusty", old.ammo)
				end
				if slot == "gun2" then x.gun2 = inst else r.gun = inst end
			end
		elseif def.kind == "armor" or def.kind == "helmet" then
			take()
			local key = def.kind
			if x[key] then
				Raid.addItem(r.bag, x[key].id, 1)
			end
			local g = def.gear or {}
			x[key] = { id = st.id, armor = g.armor or g.headArmor or 0, dur = g.dur or 50 }
		elseif def.kind == "melee" then
			take()
			Raid.addItem(r.bag, r.melee, 1)
			r.melee = st.id
		elseif def.use then
			useItem(p, st.id)
			return
		else
			return
		end
		Weapons.cancelReload(p)
		Raid.syncVitals(p)
		Raid.sendBag(p)
		Weapons.syncAmmo(p)
		Net.event("Toast"):FireClient(p, "Equipped " .. (def.name or st.id), "good")
	end)
	Net.event("Unequip").OnServerEvent:Connect(function(p, slot)
		local r = Raid.raids[p]
		if not r or not r.alive then
			return
		end
		local x = r :: any
		local key = if slot == "gun" or slot == "gun2" or slot == "armor" or slot == "helmet" then slot else nil
		if not key then
			return
		end
		local inst = if key == "gun" then r.gun else x[key]
		if not inst then
			return
		end
		Raid.addItem(r.bag, inst.id, 1)
		if inst.ammo and inst.ammo > 0 then
			Raid.addItem(r.bag, require(ReplicatedStorage.Shared.Guns).ammoOf(inst.id) or "ammo_s_rusty", inst.ammo)
		end
		if key == "gun" then r.gun = nil else x[key] = nil end
		Weapons.cancelReload(p)
		Raid.syncVitals(p)
		Raid.sendBag(p)
		Weapons.syncAmmo(p)
	end)
	Net.event("Melee").OnServerEvent:Connect(melee)
	Net.event("UseItem").OnServerEvent:Connect(useItem)
	Net.event("Dodge").OnServerEvent:Connect(function(p)
		Actions.cancelUse(p)
	end)
	RunService.Heartbeat:Connect(function()
		local now = os.clock()
		for p, u in using do
			local r = Raid.raids[p]
			if not r or not r.alive then
				using[p] = nil
			elseif now >= u.done then
				using[p] = nil
				p:SetAttribute("UseId", nil)
				finishUse(p, u.id)
			end
		end
	end)
end

return Actions
