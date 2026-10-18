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
	local mid = if r.eq.melee then (r.eq.melee :: any).id else "stick"
	local m = Config.Melee[mid] or Config.Melee.stick
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
		do
			local crit = math.random() < m.critRate
			require(script.Parent.Cover).melee(pos.X, pos.Z, math.atan2(fwd.X, fwd.Y), m.range + m.reach, m.damage * (if crit then m.critMul else 1))
		end
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
				local killed = t.hurt(dmg, { from = p, crit = crit, weaponId = mid, fromName = p.DisplayName })
				Weapons.broadcastHit(t, tp + Vector3.new(0, 0.7, 0), dmg, crit, killed, p, false)
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
	-- Player.usable: energy / hydration / buff items always; heals below max HP; bandages while bleeding; else "Not usable"
	local u = def.use
	local ok = (u.energy or u.hydration or u.buff) ~= nil
		or (u.heal ~= nil and u.heal > 0 and r.hp < r.maxHp)
		or (u.bleedStacks ~= nil and ((r :: any).bleed or 0) > 0)
	if not ok then
		Net.event("Toast"):FireClient(p, "Not usable", "info")
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

Actions.useItem = useItem

--- the held slot follows equipment changes (InventoryUI.equipFrom / unequip: Player.switchTo)
Actions.setHeld = setHeld

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
	-- throwing (World.handleThrow): the held throwable, 0.5 s cooldown, one item per throw, never while rolling
	local lastThrow: { [Player]: number } = {}
	Net.event("Throw").OnServerEvent:Connect(function(p, id, aim)
		local r = Raid.raids[p]
		if not r or not r.alive or typeof(id) ~= "string" or typeof(aim) ~= "Vector2" then
			return
		end
		local Grenades = require(script.Parent.Grenades)
		local row = Grenades.row(id)
		local now = os.clock()
		if not row or now - (lastThrow[p] or -math.huge) < 0.45 or Raid.count(r.bag, id) <= 0 then
			return
		end
		if Weapons.isDodging and Weapons.isDodging(p) then
			return
		end
		local root = Raid.rootOf(p)
		local pos = Raid.posOf(p)
		if not root or not pos then
			return
		end
		lastThrow[p] = now
		Raid.take(r.bag, id, 1)
		Raid.sendBag(p)
		local look = root.CFrame.LookVector
		Grenades.launch(id, pos.X, pos.Z, math.atan2(look.X, look.Z), aim.X, aim.Y, { team = 0, from = p })
		if Raid.count(r.bag, id) <= 0 then
			setHeld(p, "gun")
			if p.Character then
				p.Character:SetAttribute("Held", "gun")
			end
			Weapons.syncAmmo(p)
		end
	end)
	Net.event("SelectSlot").OnServerEvent:Connect(function(p, slot)
		if slot == "throw" then
			Actions.cancelUse(p)
			if p.Character then
				p.Character:SetAttribute("Held", "throw")
			end
			return
		end
		if slot == "gun" or slot == "gun2" or slot == "melee" or slot == "none" then
			Actions.cancelUse(p)
			setHeld(p, slot)
			if p.Character then
				p.Character:SetAttribute("Held", if slot == "melee" then "melee" elseif slot == "none" then "none" else "gun")
			end
			Weapons.syncAmmo(p)
		end
	end)
	-- Key N (World.toggleNightVision): the face goggles on / off; "No night vision" without them
	Net.event("NightVision").OnServerEvent:Connect(function(p)
		local r = Raid.raids[p]
		if not r or not r.alive then
			return
		end
		local _, _, toggled = Raid.nightVision(r)
		if not toggled then
			Net.event("Toast"):FireClient(p, "No night vision", "info")
			return
		end
		local x = r :: any
		x.nvgOn = x.nvgOn == false
		Net.event("Toast"):FireClient(p, if x.nvgOn then "Night vision on" else "Night vision off", "info")
		Raid.syncVitals(p)
	end)
	-- the whistle: an AI noise of radius 15 at the character (World.whistle -> noise), no cooldown
	Net.event("Whistle").OnServerEvent:Connect(function(p)
		local pos = Raid.posOf(p)
		local r = Raid.raids[p]
		if pos and r and r.alive then
			require(script.Parent.Enemies).hear(pos.X, pos.Z, 15, 0, 0)
		end
	end)
	Net.event("Melee").OnServerEvent:Connect(function(p)
		-- a melee swing (priority 2) stops a reload (priority 1)
		Weapons.cancelReload(p)
		melee(p)
	end)
	Net.event("StopAction").OnServerEvent:Connect(function(p)
		Weapons.cancelReload(p)
		Actions.cancelUse(p)
	end)
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
