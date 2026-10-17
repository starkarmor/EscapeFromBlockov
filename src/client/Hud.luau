--!strict
-- The raid HUD (web index.html / src/systems/Hud.ts layout) in the Roblox art brief's language: chunky rounded type with
-- a near-black stroke, colored toy plates with thick borders. Elements: clock (top-left), HP pill + hydration / energy
-- badges (bottom-left), weapon slots + hotbar + ammo (bottom), stamina bar under the beaver, reticle with reload ring and
-- hit marker at the software cursor, interact prompt, hold progress, extraction countdown, toasts, hurt vignette.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Config = require(Shared.Config)
local Guns = require(Shared.Guns)
local PC = require(script.Parent.PlayerControl)
local Combat = require(script.Parent.Combat)
local Fx = require(script.Parent.Fx)

local player = Players.LocalPlayer
local S = Units.S
local Hud = {}

local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Regular)
local INK = Color3.fromRGB(22, 21, 29)
local WHITE = Color3.fromRGB(255, 248, 233)
local MAPLE = Color3.fromRGB(232, 50, 46)
local LIME = Color3.fromRGB(128, 222, 37)
local GOLD = Color3.fromRGB(255, 216, 61)
local CYAN = Color3.fromRGB(19, 213, 244)
local VIOLET = Color3.fromRGB(153, 56, 242)

local gui: ScreenGui
local refs: { [string]: any } = {}

local function stroke(parent: Instance, thick: number, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thick
	s.Color = color or INK
	s.ApplyStrokeMode = if parent:IsA("TextLabel") then Enum.ApplyStrokeMode.Contextual else Enum.ApplyStrokeMode.Border
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.Parent = parent
	return s
end

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function label(parent: Instance, text: string, size: number, color: Color3?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.FontFace = FONT
	t.Text = text
	t.TextSize = size
	t.TextColor3 = color or WHITE
	t.Size = UDim2.fromOffset(0, size + 4)
	t.AutomaticSize = Enum.AutomaticSize.X
	stroke(t, math.max(2, size / 10))
	t.Parent = parent
	return t
end

local function plate(parent: Instance, size: UDim2, color: Color3, r: number?): Frame
	local f = Instance.new("Frame")
	f.Size = size
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	corner(f, r or 10)
	stroke(f, 3)
	f.Parent = parent
	return f
end

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "RaidHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")

	-- hurt vignette
	local hurt = Instance.new("ImageLabel")
	hurt.Size = UDim2.fromScale(1, 1)
	hurt.BackgroundTransparency = 1
	hurt.Image = "rbxasset://textures/ui/TopBar/WhiteOverlayAsset.png"
	hurt.ImageColor3 = MAPLE
	hurt.ImageTransparency = 1
	hurt.Parent = gui
	refs.hurt = hurt

	-- clock (top-left)
	local clock = Instance.new("Frame")
	clock.BackgroundTransparency = 1
	clock.Position = UDim2.fromOffset(18, 14)
	clock.Size = UDim2.fromOffset(300, 80)
	clock.Parent = gui
	refs.clockTime = label(clock, "08:00", 44)
	local sub = label(clock, "Day  Sunny", 18)
	sub.Position = UDim2.fromOffset(130, 6)
	refs.clockSub = sub

	-- vitals (bottom-left)
	local vit = Instance.new("Frame")
	vit.BackgroundTransparency = 1
	vit.AnchorPoint = Vector2.new(0, 1)
	vit.Position = UDim2.new(0, 22, 1, -22)
	vit.Size = UDim2.fromOffset(330, 64)
	vit.Parent = gui
	local hp = plate(vit, UDim2.fromOffset(170, 36), Color3.fromRGB(60, 22, 26), 18)
	hp.Position = UDim2.fromOffset(0, 14)
	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = MAPLE
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(1, 1)
	corner(fill, 18)
	fill.Parent = hp
	refs.hpFill = fill
	local hpText = label(hp, "40 / 40", 22)
	hpText.AnchorPoint = Vector2.new(0.5, 0.5)
	hpText.Position = UDim2.fromScale(0.5, 0.5)
	refs.hpText = hpText
	local heart = label(hp, "♥", 26)
	heart.AnchorPoint = Vector2.new(0.5, 0.5)
	heart.Position = UDim2.new(0, 0, 0.5, 0)
	heart.TextColor3 = WHITE
	local function badge(x: number, color: Color3, glyph: string): (Frame, TextLabel)
		local b = plate(vit, UDim2.fromOffset(52, 52), Color3.fromRGB(30, 30, 40), 26)
		b.Position = UDim2.fromOffset(x, 6)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0, 1)
		f.Position = UDim2.fromScale(0, 1)
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundColor3 = color
		f.BorderSizePixel = 0
		corner(f, 26)
		f.Parent = b
		local g = label(b, glyph, 22)
		g.AnchorPoint = Vector2.new(0.5, 0.5)
		g.Position = UDim2.fromScale(0.5, 0.5)
		return f, g
	end
	refs.hydFill = badge(186, CYAN, "💧")
	refs.engFill = badge(248, GOLD, "⚡")

	-- weapons + hotbar (bottom centre)
	local bar = Instance.new("Frame")
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -18)
	bar.Size = UDim2.fromOffset(620, 78)
	bar.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = bar
	refs.slots = {}
	for i, key in { "1", "2", "V", "3", "4", "5", "6", "7", "8" } do
		local big = i <= 2
		local s = plate(bar, UDim2.fromOffset(if big then 72 else 56, if big then 66 else 56), Color3.fromRGB(44, 44, 58), 12)
		s.LayoutOrder = i
		local k = plate(s, UDim2.fromOffset(22, 20), WHITE, 5)
		k.AnchorPoint = Vector2.new(0.5, 0.5)
		k.Position = UDim2.new(0.5, 0, 1, 2)
		local kl = label(k, key, 14, INK)
		kl.AnchorPoint = Vector2.new(0.5, 0.5)
		kl.Position = UDim2.fromScale(0.5, 0.5)
		local uiStroke = kl:FindFirstChildOfClass("UIStroke")
		if uiStroke then
			uiStroke.Enabled = false
		end
		local name = label(s, "", 13)
		name.AnchorPoint = Vector2.new(0.5, 0.5)
		name.Position = UDim2.fromScale(0.5, 0.45)
		refs.slots[i] = { frame = s, name = name }
	end
	local ammo = label(gui, "", 24)
	ammo.AnchorPoint = Vector2.new(0.5, 1)
	ammo.Position = UDim2.new(0.5, -270 + 36, 1, -100)
	refs.ammo = ammo

	-- stamina bar under the beaver
	local stam = plate(gui, UDim2.fromOffset(64, 10), Color3.fromRGB(30, 30, 40), 5)
	stam.AnchorPoint = Vector2.new(0.5, 0)
	local sf = Instance.new("Frame")
	sf.BackgroundColor3 = LIME
	sf.BorderSizePixel = 0
	sf.Size = UDim2.fromScale(1, 1)
	corner(sf, 5)
	sf.Parent = stam
	refs.stam, refs.stamFill = stam, sf

	-- reticle
	local ret = Instance.new("Frame")
	ret.BackgroundTransparency = 1
	ret.AnchorPoint = Vector2.new(0.5, 0.5)
	ret.Size = UDim2.fromOffset(44, 44)
	ret.Parent = gui
	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(26, 26)
	ring.BackgroundTransparency = 1
	corner(ring, 13)
	stroke(ring, 3, WHITE)
	ring.Parent = ret
	local rs = ring:FindFirstChildOfClass("UIStroke") :: UIStroke
	local outer = Instance.new("Frame")
	outer.AnchorPoint = Vector2.new(0.5, 0.5)
	outer.Position = UDim2.fromScale(0.5, 0.5)
	outer.Size = UDim2.fromOffset(32, 32)
	outer.BackgroundTransparency = 1
	corner(outer, 16)
	stroke(outer, 2, INK)
	outer.Parent = ret
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(5, 5)
	dot.BackgroundColor3 = WHITE
	corner(dot, 3)
	stroke(dot, 1)
	dot.Parent = ret
	refs.ret, refs.retRing, refs.retStroke = ret, ring, rs
	local hm = label(ret, "✕", 30, WHITE)
	hm.AnchorPoint = Vector2.new(0.5, 0.5)
	hm.Position = UDim2.fromScale(0.5, 0.5)
	hm.TextTransparency = 1
	refs.hit = hm
	local readout = label(ret, "", 16, LIME)
	readout.Position = UDim2.fromOffset(40, 26)
	refs.readout = readout

	-- interact prompt + progress
	local prompt = plate(gui, UDim2.fromOffset(0, 34), WHITE, 17)
	prompt.AutomaticSize = Enum.AutomaticSize.X
	prompt.AnchorPoint = Vector2.new(0, 0.5)
	prompt.Visible = false
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = prompt
	local pl = Instance.new("UIListLayout")
	pl.FillDirection = Enum.FillDirection.Horizontal
	pl.VerticalAlignment = Enum.VerticalAlignment.Center
	pl.Padding = UDim.new(0, 8)
	pl.Parent = prompt
	local ptext = label(prompt, "Search", 20, INK)
	local st = ptext:FindFirstChildOfClass("UIStroke")
	if st then
		st.Enabled = false
	end
	local key = plate(prompt, UDim2.fromOffset(24, 22), INK, 5)
	local kt = label(key, "F", 15, WHITE)
	kt.AnchorPoint = Vector2.new(0.5, 0.5)
	kt.Position = UDim2.fromScale(0.5, 0.5)
	refs.prompt, refs.promptText = prompt, ptext
	local prog = plate(gui, UDim2.fromOffset(200, 16), Color3.fromRGB(30, 30, 40), 8)
	prog.AnchorPoint = Vector2.new(0.5, 0.5)
	prog.Visible = false
	local pf = Instance.new("Frame")
	pf.BackgroundColor3 = GOLD
	pf.BorderSizePixel = 0
	pf.Size = UDim2.fromScale(0, 1)
	corner(pf, 8)
	pf.Parent = prog
	refs.prog, refs.progFill = prog, pf

	-- extraction countdown (top centre)
	local ex = label(gui, "", 34, WHITE)
	ex.AnchorPoint = Vector2.new(0.5, 0)
	ex.Position = UDim2.new(0.5, 0, 0, 70)
	ex.Visible = false
	refs.extract = ex

	-- toasts
	local toasts = Instance.new("Frame")
	toasts.BackgroundTransparency = 1
	toasts.AnchorPoint = Vector2.new(0.5, 0)
	toasts.Position = UDim2.new(0.5, 0, 0, 120)
	toasts.Size = UDim2.fromOffset(600, 200)
	toasts.Parent = gui
	local tl = Instance.new("UIListLayout")
	tl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	tl.Padding = UDim.new(0, 6)
	tl.Parent = toasts
	refs.toasts = toasts
end

function Hud.toast(text: string, kind: string?)
	if not refs.toasts then
		return
	end
	local color = if kind == "bad" then MAPLE elseif kind == "good" then LIME elseif kind == "rare" then VIOLET else Color3.fromRGB(44, 44, 58)
	local p = plate(refs.toasts, UDim2.fromOffset(0, 36), color, 12)
	p.AutomaticSize = Enum.AutomaticSize.X
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 14)
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = p
	local t = label(p, text, 20)
	t.Position = UDim2.fromOffset(0, 4)
	task.delay(2.6, function()
		p:Destroy()
	end)
end

function Hud.setPrompt(text: string?, at: Vector3?)
	local p = refs.prompt
	if not p then
		return
	end
	if not text or not at then
		p.Visible = false
		return
	end
	local cam = Workspace.CurrentCamera
	local sp, on = cam:WorldToViewportPoint(at * S)
	p.Visible = on
	refs.promptText.Text = text
	p.Position = UDim2.fromOffset(sp.X + 18, sp.Y)
end

function Hud.setProgress(frac: number?, at: Vector3?)
	local p = refs.prog
	if not p then
		return
	end
	if not frac or not at then
		p.Visible = false
		return
	end
	local cam = Workspace.CurrentCamera
	local sp = cam:WorldToViewportPoint(at * S)
	p.Visible = true
	p.Position = UDim2.fromOffset(sp.X, sp.Y - 70)
	refs.progFill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
end

local hitT = 0
local hurtT = 0
local lastHp = -1

function Hud.update(dt: number)
	if not gui then
		return
	end
	local cam = Workspace.CurrentCamera
	-- clock (40x game time from 08:00)
	local secs = player:GetAttribute("RaidClock")
	if typeof(secs) == "number" then
		local h = (Config.Clock.start + secs * Config.Clock.scale / 3600) % 24
		refs.clockTime.Text = string.format("%02d:%02d", math.floor(h), math.floor((h % 1) * 60))
		local phase = if h >= 22 or h < 6 then "Night" elseif h >= 18 then "Dusk" else "Day"
		refs.clockSub.Text = phase .. "  Sunny"
	end
	-- vitals
	local hp = player:GetAttribute("HP")
	local maxHp = player:GetAttribute("MaxHP")
	if typeof(hp) == "number" and typeof(maxHp) == "number" then
		refs.hpFill.Size = UDim2.fromScale(math.clamp(hp / maxHp, 0, 1), 1)
		refs.hpText.Text = string.format("%d / %d", math.ceil(hp), maxHp)
		if lastHp >= 0 and hp < lastHp then
			hurtT = 1
		end
		lastHp = hp
	end
	local water = player:GetAttribute("Water")
	local energy = player:GetAttribute("Energy")
	if typeof(water) == "number" then
		refs.hydFill.Size = UDim2.fromScale(1, math.clamp(water / 100, 0, 1))
	end
	if typeof(energy) == "number" then
		refs.engFill.Size = UDim2.fromScale(1, math.clamp(energy / 100, 0, 1))
	end
	hurtT = math.max(0, hurtT - dt * 2)
	refs.hurt.ImageTransparency = 1 - hurtT * 0.6
	-- weapon slots + ammo
	local gid = player:GetAttribute("Gun")
	local slots = refs.slots
	slots[1].name.Text = if typeof(gid) == "string" and Guns.items[gid] then Guns.items[gid].name else ""
	slots[3].name.Text = "Stick"
	for i, s in slots do
		local active = (i == 1 and PC.held == "gun") or (i == 3 and PC.held == "melee")
		local st = s.frame:FindFirstChildOfClass("UIStroke")
		if st then
			st.Color = if active then WHITE else INK
		end
	end
	if typeof(gid) == "string" and PC.held == "gun" then
		local reserve = player:GetAttribute("Reserve")
		local mag = Combat.mag()
		local cap = (Guns.row(gid) or {}).Capacity or 0
		refs.ammo.Text = string.format("%02d/%02d   %s", mag, cap, if typeof(reserve) == "number" then tostring(reserve) else "")
		refs.ammo.TextColor3 = if mag == 0 then MAPLE else WHITE
	else
		refs.ammo.Text = ""
	end
	-- stamina under the beaver
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		local sp = cam:WorldToViewportPoint(root.Position - Vector3.new(0, 0.4 * S, 0))
		refs.stam.Position = UDim2.fromOffset(sp.X, sp.Y + 14)
		refs.stamFill.Size = UDim2.fromScale(PC.stamina / Config.Stamina.max, 1)
		refs.stam.Visible = PC.stamina < Config.Stamina.max - 0.01
	end
	-- reticle at the software cursor; reload ring; distance readout
	local c = Combat.cursor()
	refs.ret.Position = UDim2.fromOffset(c.X, c.Y)
	local reloading, frac = Combat.reloading()
	refs.retStroke.Color = if reloading then GOLD else WHITE
	refs.retRing.Size = if reloading then UDim2.fromOffset(18 + 14 * frac, 18 + 14 * frac) else UDim2.fromOffset(26, 26)
	local d = (PC.aim - PC.pos).Magnitude
	refs.readout.Text = string.format("%.1fm", d)
	local g = if typeof(gid) == "string" then Guns.row(gid) else nil
	refs.readout.TextColor3 = if g and d > Guns.range(g) then MAPLE elseif g and d > Guns.range(g) * 0.5 then GOLD else LIME
	hitT = math.max(0, hitT - dt * 4)
	refs.hit.TextTransparency = 1 - hitT
	-- extraction countdown
	local exT = player:GetAttribute("ExtractLeft")
	if typeof(exT) == "number" and exT > 0 then
		refs.extract.Visible = true
		refs.extract.Text = string.format("Extracting %06.3f", exT)
	else
		refs.extract.Visible = false
	end
end

function Hud.start()
	build()
	Fx.onHitMarker = function(kill: boolean, crit: boolean)
		hitT = 1
		refs.hit.TextColor3 = if kill then MAPLE elseif crit then GOLD else WHITE
		refs.hit.Rotation = if kill then 0 else 45
	end
	Fx.onDamage = function(at: Vector3, dmg: number, crit: boolean)
		local cam = Workspace.CurrentCamera
		local sp, on = cam:WorldToViewportPoint(at * S)
		if not on then
			return
		end
		local t = label(gui, tostring(math.floor(dmg + 0.5)), if crit then 30 else 24, if crit then GOLD else WHITE)
		t.AnchorPoint = Vector2.new(0.5, 0.5)
		t.Position = UDim2.fromOffset(sp.X + math.random(-10, 10), sp.Y - 30)
		TweenService:Create(t, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = t.Position - UDim2.fromOffset(0, 40), TextTransparency = 1 }):Play()
		local s = t:FindFirstChildOfClass("UIStroke")
		if s then
			TweenService:Create(s, TweenInfo.new(0.6), { Transparency = 1 }):Play()
		end
		task.delay(0.65, function()
			t:Destroy()
		end)
	end
	Net.event("Toast").OnClientEvent:Connect(function(text: string, kind: string?)
		Hud.toast(text, kind)
	end)
end

return Hud
