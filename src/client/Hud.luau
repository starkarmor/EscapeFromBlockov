--!strict
-- The raid HUD, element for element from the web build (src/systems/Hud.ts, src/ui/duckov.css, which rebuild the
-- source's HUDCanvas prefab). Every size is reference px at 2560x1440 scaled by u = min(W/2560, H/1440) through one
-- UIScale; colours, timings and states are the web's. Typeface: the Roblox art brief's FredokaOne (digits Michroma).
-- Platform adaptation: the clock sits below Roblox's top bar instead of at the very top-left.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local Config = require(Shared.Config)
local Guns = require(Shared.Guns)
local PC = require(script.Parent.PlayerControl)
local Combat = require(script.Parent.Combat)
local Fx = require(script.Parent.Fx)
local CameraRig = require(script.Parent.CameraRig)

local player = Players.LocalPlayer
local S = Units.S
local Hud = {}

local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Regular)
local FONT_BOLD = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold)
local DIGITS = Font.fromEnum(Enum.Font.Michroma)
local INK = Color3.fromRGB(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local DARK_A = 0.282 -- --dark rgba(0,0,0,.718) as a Roblox transparency

local gui: ScreenGui
local root: Frame
local scale: UIScale
local u = 0.5
local R: { [string]: any } = {}

-- ------------------------------------------------------------------ builders
local function new(class: string, props: { [string]: any }, parent: Instance?): any
	local o = Instance.new(class)
	for k, v in props do
		(o :: any)[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function corner(o: Instance, r: number)
	new("UICorner", { CornerRadius = if r >= 999 then UDim.new(1, 0) else UDim.new(0, r) }, o)
end

local function box(parent: Instance, size: Vector2, color: Color3, alpha: number, r: number?): Frame
	local f = new("Frame", { Size = UDim2.fromOffset(size.X, size.Y), BackgroundColor3 = color, BackgroundTransparency = 1 - alpha, BorderSizePixel = 0 }, parent)
	if r then
		corner(f, r)
	end
	return f
end

local function text(parent: Instance, s: string, size: number, props: { [string]: any }?): TextLabel
	local t = new("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT,
		Text = s,
		TextSize = size,
		TextColor3 = WHITE,
		Size = UDim2.fromOffset(0, size * 1.22),
		AutomaticSize = Enum.AutomaticSize.X,
	}, parent)
	-- text-shadow 0.046em #000 -> a thin dark stroke
	new("UIStroke", { Thickness = math.max(1.5, size * 0.07), Color = INK, Transparency = 0.35 }, t)
	if props then
		for k, v in props do
			(t :: any)[k] = v
		end
	end
	return t
end

--- key cap: white .784 r10, text #1E272E bold, hard #7E878C 4 px drop
local function keycap(parent: Instance, key: string, h: number?): Frame
	local hh = h or 32.4
	local holder = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, hh + 4), AutomaticSize = Enum.AutomaticSize.X }, parent)
	local cap = new("TextLabel", {
		BackgroundColor3 = WHITE,
		BackgroundTransparency = 0.216,
		FontFace = FONT_BOLD,
		Text = key,
		TextSize = hh * 0.62,
		TextColor3 = Color3.fromHex("#1e272e"),
		Size = UDim2.fromOffset(0, hh),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 2,
	}, holder)
	corner(cap, 10)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, cap)
	local under = new("Frame", { BackgroundColor3 = Color3.fromHex("#7e878c"), BorderSizePixel = 0, Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, 0, 0, hh), ZIndex = 1 }, holder)
	corner(under, 10)
	return holder
end

-- ------------------------------------------------------------------ progress rings (conic fill from two clipped halves)
type Ring = { frame: Frame, halves: { { clip: Frame, grad: UIGradient, stroke: UIStroke } }, ccw: boolean }
local function ring(parent: Instance, size: number, thick: number, color: Color3, ccw: boolean): Ring
	local f = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size) }, parent)
	local halves = {}
	for i = 1, 2 do
		local right = i == 1
		local clip = new("Frame", { BackgroundTransparency = 1, ClipsDescendants = true, Size = UDim2.fromOffset(size / 2, size), Position = UDim2.fromOffset(if right then size / 2 else 0, 0) }, f)
		local c = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(size - thick, size - thick), Position = UDim2.fromOffset((if right then -size / 2 else 0) + thick / 2, thick / 2) }, clip)
		corner(c, 999)
		local st = new("UIStroke", { Thickness = thick, Color = color, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, c)
		local g = new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.499, 0), NumberSequenceKeypoint.new(0.5, 1), NumberSequenceKeypoint.new(1, 1) }) }, st)
		halves[i] = { clip = clip, grad = g, stroke = st }
	end
	return { frame = f, halves = halves, ccw = ccw }
end

local function setRing(r: Ring, p: number)
	p = math.clamp(p, 0, 1)
	local right, left = r.halves[1], r.halves[2]
	if not r.ccw then
		right.grad.Rotation = math.min(p, 0.5) * 360
		left.grad.Rotation = 180 + math.max(0, p - 0.5) * 360
	else
		left.grad.Rotation = 180 - math.min(p, 0.5) * 360
		right.grad.Rotation = -math.max(0, p - 0.5) * 360
	end
end

local function ringColor(r: Ring, c: Color3)
	for _, h in r.halves do
		h.stroke.Color = c
	end
end

--- a dark backing ring (border `thick`) behind a fill ring
local function backing(parent: Instance, size: number, thick: number): Frame
	local b = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(size - thick, size - thick), Position = UDim2.fromOffset(thick / 2, thick / 2) }, parent)
	corner(b, 999)
	new("UIStroke", { Thickness = thick, Color = INK, Transparency = DARK_A }, b)
	return b
end

-- quality colours (InventoryUI.ts: q0 white .. q5/q6 red)
Hud.QCOL = { [0] = Color3.fromHex("#ffffff"), Color3.fromHex("#8be913"), Color3.fromHex("#11b8f1"), Color3.fromHex("#990ff5"), Color3.fromHex("#ff7d25"), Color3.fromHex("#ff2f2f"), Color3.fromHex("#ff2f2f") }
Hud.text, Hud.box, Hud.keycap, Hud.corner = text, box, keycap, corner

-- ------------------------------------------------------------------ build
local function build()
	gui = new("ScreenGui", { Name = "RaidHud", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
	root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromOffset(2560, 1440) }, gui)
	scale = new("UIScale", { Scale = 0.5 }, root)

	-- hurt vignette (HurtVolume: URP vignette #670B0B): four edge gradients, weight set on hits, decays 4/s
	local vig = new("Frame", { Name = "Hurt", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, root)
	R.vig = {}
	for i, spec in { { UDim2.fromScale(1, 0.32), UDim2.fromScale(0, 0), 90 }, { UDim2.fromScale(1, 0.32), UDim2.fromScale(0, 0.68), -90 }, { UDim2.fromScale(0.26, 1), UDim2.fromScale(0, 0), 0 }, { UDim2.fromScale(0.26, 1), UDim2.fromScale(0.74, 0), 180 } } do
		local e = new("Frame", { Size = spec[1], Position = spec[2], BackgroundColor3 = Color3.fromHex("#670B0B"), BorderSizePixel = 0 }, vig)
		R.vig[i] = new("UIGradient", { Rotation = spec[3], Transparency = NumberSequence.new(1) }, e)
	end

	-- clock (TimeOfDayDisplay: left 15, top 15; clock 80 over a ghost 88:88) + storm line
	local clock = new("Frame", { Name = "Clock", BackgroundTransparency = 1, Position = UDim2.fromOffset(15, 15), Size = UDim2.fromOffset(600, 200) }, root)
	R.clock = clock
	local ghost = text(clock, "88:88", 80, { TextColor3 = Color3.fromHex("#071C30"), TextTransparency = 0.604, FontFace = DIGITS })
	ghost:FindFirstChildOfClass("UIStroke"):Destroy()
	R.clockTime = text(clock, "08:00", 80, { FontFace = DIGITS })
	R.clockPhase = text(clock, "Day", 24.46, { Position = UDim2.fromOffset(310, 14) })
	R.clockWeather = text(clock, "Sunny", 35, { Position = UDim2.fromOffset(310, 44) })
	local storm = box(clock, Vector2.new(0, 46), INK, 0.427, 15)
	storm.AutomaticSize = Enum.AutomaticSize.X
	storm.Position = UDim2.fromOffset(0, 112)
	new("UIStroke", { Thickness = 3, Color = Color3.fromHex("#DE31FF"), Transparency = 0.4 }, storm)
	new("UIPadding", { PaddingLeft = UDim.new(0, 15), PaddingRight = UDim.new(0, 20) }, storm)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) }, storm)
	text(storm, "Next Storm Arrives In:", 25)
	R.stormTime = text(storm, "216:00", 30, { TextColor3 = Color3.fromHex("#fdc6ff"), FontFace = DIGITS })

	-- controls hint (SimpleIndicators: right 25, top 100) + the panel toggled with O
	local hint = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -25, 0, 100), Size = UDim2.fromOffset(0, 58), AutomaticSize = Enum.AutomaticSize.X }, root)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) }, hint)
	text(hint, "Controls", 28)
	keycap(hint, "O", 38.5)
	local panel = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -25, 0, 168.5), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, Visible = false }, root)
	new("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, panel)
	for i, row in { { "WASD", "Move" }, { "Shift", "Run" }, { "Space", "Dodge" }, { "LMB", "Shoot" }, { "RMB", "Aim" }, { "R", "Reload" }, { "F", "Interact" }, { "Tab", "Backpack" }, { "1 2 V", "Weapons" }, { "3-8", "Items" }, { "X", "Cancel" } } do
		local e = box(panel, Vector2.new(0, 58), INK, 0.773, 999)
		e.AutomaticSize = Enum.AutomaticSize.X
		e.LayoutOrder = i
		new("UIPadding", { PaddingLeft = UDim.new(0, 25), PaddingRight = UDim.new(0, 25) }, e)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) }, e)
		keycap(e, row[1], 38.5)
		text(e, row[2], 28)
	end
	R.controls = panel

	-- the calm-dim group: weapons, hotbar, hp, rings, armor, ammo fade to .42 after 4 s without a change
	local dim = new("CanvasGroup", { Name = "Dimmable", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, root)
	R.dim = dim

	-- statuses (Buffs: left 51, bottom 53.95, stacked upward)
	local st = new("Frame", { Name = "Statuses", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 51, 1, -53.95), Size = UDim2.fromOffset(340, 400) }, root)
	new("UIListLayout", { VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, st)
	R.statuses = st

	-- HP box (260x50 pill, left centre - 854, bottom 53.6): heart, 205.4x34 track, white lag + #FF8D8D fill, "cur / max"
	local hp = box(dim, Vector2.new(260, 50), INK, 0.745, 999)
	hp.AnchorPoint = Vector2.new(0, 1)
	hp.Position = UDim2.new(0.5, -854, 1, -53.6)
	local heart = text(hp, "♥", 38, { TextColor3 = Color3.fromHex("#ff8d8d"), Position = UDim2.fromOffset(9, 2) })
	heart:FindFirstChildOfClass("UIStroke").Color = Color3.fromHex("#ff3c3c")
	local track = box(hp, Vector2.new(205.4, 34), INK, 1, 999)
	track.Position = UDim2.fromOffset(47.6, 8)
	track.ClipsDescendants = true
	local lag = box(track, Vector2.new(199.4, 28), WHITE, 1, 999)
	lag.Position = UDim2.fromOffset(3, 3)
	local fill = box(track, Vector2.new(199.4, 28), Color3.fromHex("#ff8d8d"), 1, 999)
	fill.Position = UDim2.fromOffset(3, 3)
	local hpText = text(track, "40 / 40", 22, { FontFace = DIGITS, AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1), ZIndex = 3 })
	R.hpTrack, R.hpLag, R.hpFill, R.hpText = track, lag, fill, hpText
	R.hpScale = new("UIScale", { Scale = 1 }, track)

	-- armor (ours: helmet / vest durability above the HP pill)
	local arm = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0.5, -854, 1, -112), Size = UDim2.fromOffset(260, 60) }, dim)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 40) }, arm)
	R.armHelmet = text(arm, "⛑ -", 22)
	R.armVest = text(arm, "🦺 -", 22)

	-- water / energy rings (100x100 at centre - 533.6 / - 419, bottom 53.6): dark ring 16, white fill 6, ccw, glow colour
	R.rings = {}
	for i, spec in { { -533.6, Color3.fromHex("#2aa0ff"), "💧" }, { -419, Color3.fromHex("#ff932a"), "⚡" } } do
		local holder = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, spec[1], 1, -53.6), Size = UDim2.fromOffset(100, 100) }, dim)
		local bk = backing(holder, 100, 16)
		local rg = ring(holder, 90, 6, WHITE, true)
		rg.frame.Position = UDim2.fromOffset(5, 5)
		local disc = box(holder, Vector2.new(58, 58), INK, 0.718, 999)
		disc.Position = UDim2.fromOffset(21, 21)
		local icon = text(disc, spec[3], 30, { AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.fromScale(1, 1) })
		icon:FindFirstChildOfClass("UIStroke").Color = spec[2]
		R.rings[i] = { ring = rg, back = bk }
	end

	-- weapon buttons (right edge at centre + 57, bottom 50: 128, 128, melee 80, gap 20)
	local wb = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0.5, -319, 1, -50), Size = UDim2.fromOffset(376, 128) }, dim)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 20), SortOrder = Enum.SortOrder.LayoutOrder }, wb)
	R.weapons = {}
	for i, spec in { { 128, "1" }, { 128, "2" }, { 80, "V" } } do
		local b = box(wb, Vector2.new(spec[1], spec[1]), INK, 0.455, 32)
		b.LayoutOrder = i
		local sel = new("UIStroke", { Thickness = 4, Color = Color3.fromHex("#ffece1"), Enabled = false }, b)
		local vp = new("ViewportFrame", { BackgroundTransparency = 1, Size = UDim2.fromScale(0.94, 0.94), Position = UDim2.fromScale(0.03, 0.03), Ambient = Color3.new(0.9, 0.9, 0.9), LightColor = WHITE }, b)
		local cam = new("Camera", { FieldOfView = 30 }, vp)
		vp.CurrentCamera = cam
		local name = text(b, "", 18, { AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.new(1, -8, 0, 22), Position = UDim2.new(0, 4, 1, -26), TextScaled = true })
		local kc = keycap(b, spec[2])
		kc.AnchorPoint = Vector2.new(0.5, 0)
		kc.Position = UDim2.new(0.5, 0, 1, 8.8)
		local punch = new("UIScale", { Scale = 1 }, b)
		R.weapons[i] = { frame = b, sel = sel, vp = vp, cam = cam, name = name, id = "", punch = punch }
	end

	-- hotbar (starts at centre + 75, gap 20, 100x100 slots, bottom 50, keys 3-8)
	local hb = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0.5, 75, 1, -50), Size = UDim2.fromOffset(720, 100) }, dim)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 20), SortOrder = Enum.SortOrder.LayoutOrder }, hb)
	R.hot = {}
	for i = 1, 6 do
		local b = box(hb, Vector2.new(100, 100), INK, 0.749, 16)
		b.LayoutOrder = i
		local ringIn = new("UIStroke", { Thickness = 2, Color = WHITE, Transparency = 0.702, Enabled = false, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
		local name = text(b, "", 18, { AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.new(1, -12, 1, -24), Position = UDim2.fromOffset(6, 4), TextWrapped = true, TextScaled = true })
		local ct = box(b, Vector2.new(0, 17.5), Color3.fromHex("#585f66"), 1, 999)
		ct.AnchorPoint = Vector2.new(1, 1)
		ct.Position = UDim2.fromScale(1, 1)
		ct.AutomaticSize = Enum.AutomaticSize.X
		new("UIPadding", { PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5) }, ct)
		local cts = text(ct, "", 16, { TextColor3 = Color3.fromHex("#f8f2ea"), Size = UDim2.fromOffset(0, 17.5) })
		local kc = keycap(b, tostring(i + 2))
		kc.AnchorPoint = Vector2.new(0.5, 0)
		kc.Position = UDim2.new(0.5, 0, 1, 8.8)
		R.hot[i] = { frame = b, ringIn = ringIn, name = name, ct = ct, cts = cts }
	end

	-- ammo (BulletTypeHUD at centre - 86, bottom 168.9): grey type pill + T key, black count box "08 / 30"
	local ammo = new("Frame", { BackgroundTransparency = 1, Position = UDim2.new(0.5, -86, 1, -168.9), Size = UDim2.fromOffset(0, 0) }, dim)
	local typ = box(ammo, Vector2.new(0, 30.6), Color3.fromHex("#a4a4a4"), 1, 10)
	typ.AutomaticSize = Enum.AutomaticSize.X
	typ.AnchorPoint = Vector2.new(0.5, 1)
	typ.Position = UDim2.fromOffset(0, -40)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, typ)
	local typT = text(typ, "", 18, { TextColor3 = Color3.fromRGB(0, 0, 0), Size = UDim2.fromOffset(0, 30.6) })
	typT:FindFirstChildOfClass("UIStroke").Enabled = false
	local tk = keycap(typ, "T", 30)
	tk.AnchorPoint = Vector2.new(0, 0.5)
	tk.Position = UDim2.new(1, 18, 0.5, 0)
	local cnt = box(ammo, Vector2.new(116, 35.2), INK, 1, 10.03)
	cnt.AnchorPoint = Vector2.new(0.5, 1)
	local cA = text(cnt, "08", 18, { FontFace = DIGITS, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(0.5, -8, 0, 4) })
	text(cnt, "/", 18, { FontFace = DIGITS, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4) })
	local cR = text(cnt, "30", 18, { FontFace = DIGITS, Position = UDim2.new(0.5, 8, 0, 4) })
	R.ammo, R.ammoType, R.ammoTypeT, R.ammoCount, R.ammoA, R.ammoR = ammo, typ, typT, cnt, cA, cR

	-- distance pill (right 30.8, bottom 52.2, 166.5x50.6)
	local mk = box(root, Vector2.new(166.5, 50.6), INK, 0.788, 999)
	mk.AnchorPoint = Vector2.new(1, 1)
	mk.Position = UDim2.new(1, -30.8, 1, -52.2)
	local mi = text(mk, "◎", 34, { Position = UDim2.fromOffset(15.3, 4) })
	mi:FindFirstChildOfClass("UIStroke").Color = Color3.fromHex("#ff5151")
	R.markerT = text(mk, "0.0m", 30, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -13.9, 0, 6), TextColor3 = Color3.fromHex("#d0ff99") })
	R.marker = mk

	-- hold / use progress (centred, bottom 300): 300x35 bar, fill inset 8 #F4FBFF, then "X Cancel"
	local prog = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -300), Size = UDim2.fromOffset(300, 90), Visible = false }, root)
	local bar = box(prog, Vector2.new(300, 35), INK, 0.718, 999)
	local bf = box(bar, Vector2.new(0, 19), Color3.fromHex("#f4fbff"), 1, 999)
	bf.Position = UDim2.fromOffset(8, 8)
	new("UIStroke", { Thickness = 2, Color = Color3.fromHex("#2DB5FF"), Transparency = 0.4 }, bf)
	local cancel = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 45), Size = UDim2.fromOffset(300, 40) }, prog)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) }, cancel)
	keycap(cancel, "X")
	text(cancel, "Cancel", 28)
	R.prog, R.progFill = prog, bf

	-- extraction countdown (top 105.4 centred, 209.19x74.07): green fill with rolling stripes, runner, "00:05. 000"
	local ex = box(root, Vector2.new(209.19, 74.07), INK, 0.6, 14)
	ex.AnchorPoint = Vector2.new(0.5, 0)
	ex.Position = UDim2.new(0.5, 0, 0, 105.4)
	ex.Visible = false
	local exClip = new("Frame", { BackgroundTransparency = 1, ClipsDescendants = true, Size = UDim2.fromScale(0, 1) }, ex)
	local exFill = box(exClip, Vector2.new(209.19, 74.07), Color3.fromHex("#aef19e"), 1, 16)
	local stripes = new("UIGradient", { Rotation = 60 }, exFill)
	new("UIStroke", { Thickness = 3, Color = Color3.fromHex("#12ff00"), Transparency = 0.3 }, exFill)
	local runner = text(ex, "🏃", 40, { Position = UDim2.fromOffset(16, 12) })
	runner:FindFirstChildOfClass("UIStroke").Color = Color3.fromHex("#00ad05")
	local exT = new("TextLabel", { BackgroundTransparency = 1, RichText = true, FontFace = DIGITS, TextSize = 23.4, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -20.9, 0, 0), Size = UDim2.fromOffset(112.14, 74.07), Text = "" }, ex)
	new("UIStroke", { Thickness = 2, Color = Color3.fromHex("#00ad05"), Transparency = 0.2 }, exT)
	local exL = text(ex, "Extracting", 20, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 1, 8) })
	exL:FindFirstChildOfClass("UIStroke").Color = Color3.fromHex("#00ad05")
	R.ex, R.exClip, R.exStripes, R.exT = ex, exClip, stripes, exT

	-- toast (NotificationText: top 218 centred, black .949 pill, text 40)
	local ban = box(root, Vector2.new(0, 40 * 1.22 + 21.3), INK, 0.949, 999)
	ban.AutomaticSize = Enum.AutomaticSize.X
	ban.AnchorPoint = Vector2.new(0.5, 0)
	ban.Position = UDim2.new(0.5, 0, 0, 218)
	ban.Visible = false
	new("UIPadding", { PaddingLeft = UDim.new(0, 42.7), PaddingRight = UDim.new(0, 42.7), PaddingTop = UDim.new(0, 10.7) }, ban)
	R.banT = text(ban, "", 40)
	R.ban = ban

	-- stamina ring at the character (x - 31.5): 45 ring 15 dark, fill 5 at 35, counter-clockwise
	local sr = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(45, 45), Visible = false }, root)
	backing(sr, 45, 15)
	local srr = ring(sr, 35, 5, Color3.fromHex("#a5ff86"), true)
	srr.frame.Position = UDim2.fromOffset(5, 5)
	R.stam, R.stamRing = sr, srr

	-- prompt (InteractHUD: white 20 dot on the point, option pills 13 to the right)
	local pr = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Visible = false }, root)
	local dot = box(pr, Vector2.new(20, 20), WHITE, 1, 999)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	local opts = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(13, 0), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY }, pr)
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, opts)
	R.prompt, R.promptOpts = pr, opts

	-- reticle at the software cursor: 4 x 25 blocks at +-45 rotated 45 deg, 11 dot, mag box, reload ring, hit marker
	local ret = new("Frame", { Name = "Reticle", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0) }, root)
	local xh = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Rotation = 45 }, ret)
	R.xhBlocks = {}
	for i, dir in { Vector2.new(0, -1), Vector2.new(0, 1), Vector2.new(-1, 0), Vector2.new(1, 0) } do
		local b = box(xh, Vector2.new(25, 25), WHITE, 0.659, 3)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		new("UIStroke", { Thickness = 2, Color = INK, Transparency = 0.5 }, b)
		R.xhBlocks[i] = { f = b, dir = dir }
	end
	local cdot = box(ret, Vector2.new(11, 11), WHITE, 1, 999)
	cdot.AnchorPoint = Vector2.new(0.5, 0.5)
	R.cdotStroke = new("UIStroke", { Thickness = 1.5, Color = INK, Transparency = 0.2 }, cdot)
	R.xh, R.cdot = xh, cdot
	local rd = box(ret, Vector2.new(61.7, 47.8), INK, 0.694, 10.03)
	rd.Position = UDim2.fromOffset(48.55, 35.8)
	R.readT = text(rd, "8", 30, { FontFace = DIGITS, Size = UDim2.fromScale(1, 1), AutomaticSize = Enum.AutomaticSize.None })
	R.read = rd
	local rr = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(60, 60), Visible = false }, ret)
	backing(rr, 60, 15)
	local rrf = ring(rr, 50, 5, Color3.fromHex("#f4fbff"), false)
	rrf.frame.Position = UDim2.fromOffset(5, 5)
	R.reload, R.reloadRing = rr, rrf
	local hm = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 0), Rotation = 45, Visible = false }, ret)
	R.hmBars = {}
	for i, dir in { Vector2.new(0, -1), Vector2.new(0, 1), Vector2.new(-1, 0), Vector2.new(1, 0) } do
		local b = box(hm, if i <= 2 then Vector2.new(10, 26.4) else Vector2.new(26.4, 10), Color3.fromHex("#ff6161"), 1, 999)
		b.AnchorPoint = Vector2.new(0.5, 0.5)
		R.hmBars[i] = { f = b, dir = dir }
	end
	R.hm = hm
	R.ret = ret
	-- cover marker (26 ring + 6 dot) where a wall cuts the shot
	local cv = box(root, Vector2.new(26, 26), WHITE, 0, 999)
	cv.AnchorPoint = Vector2.new(0.5, 0.5)
	new("UIStroke", { Thickness = 3, Color = Color3.fromHex("#f2f4f5") }, cv)
	local cvd = box(cv, Vector2.new(6, 6), Color3.fromHex("#f2f4f5"), 1, 999)
	cvd.AnchorPoint = Vector2.new(0.5, 0.5)
	cvd.Position = UDim2.fromScale(0.5, 0.5)
	cv.Visible = false
	R.cover = cv

	-- world-projected layer: damage numbers, sound markers
	R.wui = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, root)
end

-- ------------------------------------------------------------------ state
local hurtW = 0
local lastHp, lagHp, lagHold = -1, -1, 0
local hpFlash = 0
local hitT, hitDur, hitKind = 99, 1, "hit"
local kickT, kickA, lastMag = 99, 0, -1
local breath = 0
local wake = 0
local wakeSig = ""
local painUntil = 0
local toastQ: { string } = {}
local toastT, toastPhase = 0, "idle"
type Num = { lbl: TextLabel, pos: Vector3, v: Vector3, t: number, crit: boolean }
local nums: { Num } = {}
type Snd = { f: Frame, t: number }
local snds: { Snd } = {}
local coverParams = RaycastParams.new()
coverParams.CollisionGroup = "QBullet"

local hotbar: { string } = {}
function Hud.hotbarItem(i: number): string?
	return hotbar[i]
end

local function bagStacks(): { { id: string, n: number } }
	local out = {}
	local raw = player:GetAttribute("Bag")
	if typeof(raw) ~= "string" then
		return out
	end
	local counts, order = {}, {}
	for id, n in string.gmatch(raw, "([^:,]+):(%d+)") do
		if not counts[id] then
			table.insert(order, id)
			counts[id] = 0
		end
		counts[id] += tonumber(n) or 0
	end
	for _, id in order do
		table.insert(out, { id = id, n = counts[id] })
	end
	return out
end

local function equip(): { [string]: string }
	local eq = {}
	local raw = player:GetAttribute("Equip")
	if typeof(raw) == "string" then
		for k, v in string.gmatch(raw, "(%w+)=([^,]*)") do
			eq[k] = v
		end
	end
	return eq
end

local function toScreen(p: Vector3): (Vector2, boolean)
	local v, on = Workspace.CurrentCamera:WorldToViewportPoint(p * S)
	return Vector2.new(v.X / u, v.Y / u), on and v.Z > 0
end

-- ------------------------------------------------------------------ API
--- one pill at a time: fade 0.12 s, hold 1.2 s (0.65 s when another waits); a repeat of a waiting message is dropped
function Hud.toast(msg: string, _kind: string?)
	for _, q in toastQ do
		if q == msg then
			return
		end
	end
	table.insert(toastQ, msg)
end

export type PromptOpt = { label: string, sel: boolean, req: string?, reqOk: boolean? }
local promptKey = ""
--- interact options at a world point (nearest first); nil hides the prompt
function Hud.setPrompt(opts: { PromptOpt }?, at: Vector3?)
	local pr = R.prompt
	if not pr then
		return
	end
	if not opts or #opts == 0 or not at then
		pr.Visible = false
		promptKey = ""
		return
	end
	local sp, on = toScreen(at)
	pr.Visible = on
	pr.Position = UDim2.fromOffset(sp.X, sp.Y)
	local key = ""
	for _, o in opts do
		key ..= o.label .. (if o.sel then "*" else "") .. (o.req or "") .. "|"
	end
	if key == promptKey then
		return
	end
	promptKey = key
	for _, c in R.promptOpts:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for i, o in opts do
		local p = box(R.promptOpts, Vector2.new(0, 30 * 1.22 + 7), if o.sel then Color3.fromRGB(75, 162, 212) else Color3.fromRGB(0, 48, 75), 0.675, 999)
		p.AutomaticSize = Enum.AutomaticSize.X
		p.LayoutOrder = i
		new("UIPadding", { PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 15), PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 4) }, p)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, p)
		local cell = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(30, 30), LayoutOrder = 1 }, p)
		local dia = box(cell, Vector2.new(9, 9), WHITE, 1, 2)
		dia.AnchorPoint = Vector2.new(0.5, 0.5)
		dia.Position = UDim2.fromScale(0.5, 0.5)
		dia.Rotation = 45
		text(p, o.label, 30, { LayoutOrder = 2 })
		if o.sel then
			keycap(p, "F").LayoutOrder = 3
		end
		if o.req and (o.sel or not o.reqOk) then
			local rq = box(p, Vector2.new(0, 23.98 * 1.22 + 8), if o.reqOk then Color3.fromHex("#81c334") else Color3.fromHex("#ff6464"), 1, 999)
			rq.AutomaticSize = Enum.AutomaticSize.X
			rq.LayoutOrder = 4
			new("UIPadding", { PaddingLeft = UDim.new(0, 15), PaddingRight = UDim.new(0, 15), PaddingTop = UDim.new(0, 4) }, rq)
			text(rq, o.req, 23.98)
		end
	end
end

--- the hold / item-use bar; nil hides it
function Hud.setProgress(frac: number?)
	if not R.prog then
		return
	end
	if not frac then
		R.prog.Visible = false
		return
	end
	R.prog.Visible = true
	R.progFill.Size = UDim2.fromOffset(284 * math.clamp(frac, 0, 1), 19)
end

--- damage number (WorldUI): white bold 38, #222 outline, one decimal, crit lightning x1.2, launched 2 m above the hit
function Hud.damageNumber(at: Vector3, dmg: number, crit: boolean)
	if not R.wui then
		return
	end
	local s = if dmg >= 1000 then tostring(math.floor(dmg)) else string.format("%.1f", dmg)
	local lbl = text(R.wui, (if crit then "⚡" else "") .. s, 38, { AnchorPoint = Vector2.new(0.5, 0.5), FontFace = FONT_BOLD })
	local st = lbl:FindFirstChildOfClass("UIStroke")
	st.Color = Color3.fromHex("#222222")
	st.Thickness = 2
	st.Transparency = 0
	new("UIScale", { Scale = 1.869 }, lbl)
	local a = math.rad((math.random() - 0.5) * 20)
	table.insert(nums, { lbl = lbl, pos = at + Vector3.new(0, 2, 0), v = Vector3.new(math.sin(a) * 6, math.cos(a) * 6, 0), t = 0, crit = crit })
end

--- sound marker: an arc on a 400 px ring around the screen centre toward an unseen shot (1.5 s)
function Hud.soundMarker(at: Vector3)
	if not R.wui then
		return
	end
	local vp = Workspace.CurrentCamera.ViewportSize
	local sp = toScreen(at)
	local centre = Vector2.new(vp.X / 2 / u, vp.Y / 2 / u)
	local d = sp - centre
	if d.Magnitude < 1 then
		return
	end
	local p = centre + d.Unit * (400 * (vp.Y / 1080) / u)
	local f = box(R.wui, Vector2.new(70, 6), Color3.fromHex("#ffd0d0"), 0, 999)
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(p.X, p.Y)
	f.Rotation = math.deg(math.atan2(d.Y, d.X)) + 90
	table.insert(snds, { f = f, t = 0 })
end

local function hitMarker(kill: boolean, crit: boolean)
	hitT = 0
	hitKind = if kill then "kill" else "hit"
	hitDur = if kill then 1.083 else 0.833
	for i, b in R.hmBars do
		local w = if kill then 14 else 10
		b.f.Size = if i <= 2 then UDim2.fromOffset(w, 26.4) else UDim2.fromOffset(26.4, w)
		b.f.BackgroundColor3 = if crit then Color3.fromHex("#fff6ce") elseif kill then Color3.fromHex("#ff4d6d") else Color3.fromHex("#ff6161")
	end
end

local function lerpKeys(keys: { { number } }, t: number): (number, number)
	for i = 2, #keys do
		local a, b = keys[i - 1], keys[i]
		if t <= b[1] then
			local k = (t - a[1]) / math.max(1e-6, b[1] - a[1])
			return a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k
		end
	end
	local l = keys[#keys]
	return l[2], l[3]
end
-- hit marker keyframes: (time, offset px, opacity): hm 0.833 s, hmk 1.083 s
local HM = { { 0, 80, 0.65 }, { 0.1, 30, 1 }, { 0.66, 65, 0 }, { 1, 80, 0 } }
local HMK = { { 0, 100, 1 }, { 0.06, 30, 1 }, { 0.29, 25, 1 }, { 0.74, 50, 0 }, { 1, 50, 0 } }

local STATUS_GOOD = { Agile = true }
local function setStatuses(list: { { name: string, sub: string? } })
	local key = ""
	for _, s in list do
		key ..= s.name .. (s.sub or "") .. "|"
	end
	if R.statusKey == key then
		return
	end
	R.statusKey = key
	for _, c in R.statuses:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for i, s in list do
		local p = box(R.statuses, Vector2.new(0, 50), INK, 0.745, 999)
		p.AutomaticSize = Enum.AutomaticSize.X
		p.LayoutOrder = -i
		new("UIPadding", { PaddingLeft = UDim.new(0, 15), PaddingRight = UDim.new(0, 15) }, p)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12) }, p)
		box(p, Vector2.new(26, 26), if STATUS_GOOD[s.name] then WHITE else Color3.fromHex("#ff8d8d"), 1, 999)
		text(p, s.name, 22)
		if s.sub then
			text(p, s.sub, 20)
		end
	end
end

-- ------------------------------------------------------------------ frame
function Hud.update(dt: number)
	if not gui then
		return
	end
	local cam = Workspace.CurrentCamera
	local vp = cam.ViewportSize
	u = math.min(vp.X / 2560, vp.Y / 1440)
	scale.Scale = u
	root.Size = UDim2.fromOffset(vp.X / u, vp.Y / u)
	R.clock.Position = UDim2.fromOffset(15, 15 + GuiService:GetGuiInset().Y / u)
	local alive = player:GetAttribute("Alive") == true and player.Character ~= nil
	R.dim.Visible = alive
	R.marker.Visible = alive
	R.statuses.Visible = alive

	-- clock (40x from 08:00) and the storm countdown (9 days asleep)
	local secs = player:GetAttribute("RaidClock")
	if typeof(secs) == "number" then
		local h = (Config.Clock.start + secs * Config.Clock.scale / 3600) % 24
		R.clockTime.Text = string.format("%02d:%02d", math.floor(h), math.floor((h % 1) * 60))
		R.clockPhase.Text = if h >= 22 or h < 6 then "Night" elseif h >= 18 then "Dusk" else "Day"
		local left = 9 * 24 - secs * Config.Clock.scale / 3600
		R.stormTime.Text = string.format("%03d:%02d", math.floor(left), math.floor((left % 1) * 60))
	end

	-- HP: fill, white lag held 0.35 s then draining 1.5/s, pill flash 1.06 -> 1 over 0.25 s; hurt vignette on >= 1.5
	local hp, maxHp = player:GetAttribute("HP"), player:GetAttribute("MaxHP")
	if typeof(hp) == "number" and typeof(maxHp) == "number" then
		local f = math.clamp(hp / maxHp, 0, 1)
		if lastHp >= 0 and hp < lastHp - 1e-3 then
			lagHold = 0.35
			hpFlash = 0.25
			painUntil = os.clock() + 0.5
			if lastHp - hp >= 1.5 then
				hurtW = if f > 0.5 then 0.5 else 1.0
			end
			wake = 0
		end
		if lagHp < 0 or hp > lastHp then
			lagHp = f
		end
		lastHp = hp
		if lagHold > 0 then
			lagHold -= dt
		else
			lagHp = math.max(f, lagHp - 1.5 * dt)
		end
		R.hpFill.Size = UDim2.fromOffset(199.4 * f, 28)
		R.hpLag.Size = UDim2.fromOffset(199.4 * math.max(f, lagHp), 28)
		R.hpText.Text = string.format("%s / %s", (string.gsub(string.format("%.1f", hp), "%.0$", "")), tostring(maxHp))
		R.hpTrack.BackgroundColor3 = if hp <= 0 then Color3.fromRGB(209, 50, 50) else INK
		hpFlash = math.max(0, hpFlash - dt)
		R.hpScale.Scale = 1 + 0.06 * (hpFlash / 0.25)
	end
	hurtW = math.max(0, hurtW - 4 * dt)
	for _, g in R.vig do
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1 - 0.75 * hurtW), NumberSequenceKeypoint.new(0.7, 1 - 0.12 * hurtW), NumberSequenceKeypoint.new(1, 1) })
	end

	-- water / energy rings (red backing ring at 0)
	for i, attr in { "Water", "Energy" } do
		local v = player:GetAttribute(attr)
		if typeof(v) == "number" then
			setRing(R.rings[i].ring, v / 100)
			R.rings[i].back:FindFirstChildOfClass("UIStroke").Color = if v <= 0 then Color3.fromRGB(209, 50, 50) else INK
		end
	end
	-- armor
	local eq = equip()
	local ad, hd = player:GetAttribute("ArmorDur"), player:GetAttribute("HelmetDur")
	local hasVest, hasHelm = eq.armor ~= nil and eq.armor ~= "", eq.helmet ~= nil and eq.helmet ~= ""
	R.armVest.Text = if hasVest then string.format("🦺 %d", if typeof(ad) == "number" then math.floor(ad) else 0) else "🦺"
	R.armHelmet.Text = if hasHelm then string.format("⛑ %d", if typeof(hd) == "number" then math.floor(hd) else 0) else "⛑"
	R.armVest.TextColor3 = if hasVest then Color3.fromHex("#e9ecee") else Color3.fromRGB(255, 141, 141)
	R.armHelmet.TextColor3 = if hasHelm then Color3.fromHex("#e9ecee") else Color3.fromRGB(255, 141, 141)

	-- weapon buttons: the held gun's model in a viewport, selected ring #FFECE1 + punch
	local assets = ReplicatedStorage:FindFirstChild("CreatorAssets")
	for i, key in { "gun", "gun2", "melee" } do
		local w = R.weapons[i]
		local id = eq[key] or ""
		if id ~= w.id then
			w.id = id
			for _, c in w.vp:GetChildren() do
				if not c:IsA("Camera") then
					c:Destroy()
				end
			end
			local def = Guns.items[id]
			w.name.Text = if def then def.name else ""
			if def and def.fire and assets then
				local len = def.fire.length or 0.5
				local model = if def.fire.caliber == "SHT" or (def.fire.pellets or 1) > 1 then "GunShotgun" elseif string.sub(id, 1, 2) == "ak" or len >= 0.9 then "GunRifle" elseif len <= 0.55 then "GunPistol" else "GunSmg"
				local t = assets:FindFirstChild(model)
				if t then
					local m = t:Clone()
					m:PivotTo(CFrame.new())
					m.Parent = w.vp
					local cf, size = m:GetBoundingBox()
					local r = size.Magnitude
					w.cam.CFrame = CFrame.lookAt(cf.Position + Vector3.new(0, r * 0.15, r * 1.9), cf.Position)
				end
			end
		end
		local sel = (i == (PC.slot or 1))
		if sel and not w.sel.Enabled then
			w.punch.Scale = 1.1
		end
		w.sel.Enabled = sel
		w.punch.Scale += (1 - w.punch.Scale) * math.min(1, dt * 20)
	end
	-- hotbar: the backpack's usable items; the item in use gets the 3 px #FF9E3A ring
	table.clear(hotbar)
	local counts = {}
	for _, st in bagStacks() do
		local def = Guns.items[st.id]
		if def and def.use then
			table.insert(hotbar, st.id)
			counts[#hotbar] = st.n
		end
	end
	local usingId = player:GetAttribute("UseId")
	for k = 1, 6 do
		local hs = R.hot[k]
		local id = hotbar[k]
		local def = id and Guns.items[id]
		hs.name.Text = if def then def.name else ""
		hs.ringIn.Enabled = def ~= nil
		hs.frame.BackgroundTransparency = if def then 0.8 else 0.251
		hs.ct.Visible = def ~= nil
		hs.cts.Text = if def then tostring(counts[k]) else ""
		if def and usingId == id then
			hs.ringIn.Color = Color3.fromHex("#ff9e3a")
			hs.ringIn.Thickness = 3
			hs.ringIn.Transparency = 0
		else
			hs.ringIn.Color = WHITE
			hs.ringIn.Thickness = 2
			hs.ringIn.Transparency = 0.702
		end
	end

	-- ammo block + the mag count at the cursor
	local gid = player:GetAttribute("Gun")
	local isGun = typeof(gid) == "string" and PC.held == "gun"
	local mag = Combat.mag()
	R.ammo.Visible = isGun
	R.read.Visible = isGun
	if isGun then
		local ammoId = Guns.ammoOf(gid :: string)
		local adef = ammoId and Guns.items[ammoId]
		local reserve = player:GetAttribute("Reserve")
		local res = if typeof(reserve) == "number" then reserve else 0
		R.ammoTypeT.Text = if adef then adef.name else "-"
		R.ammoA.Text = string.format("%02d", mag)
		R.ammoR.Text = string.format("%02d", res)
		R.ammoCount.BackgroundColor3 = if mag <= 0 then Color3.fromHex("#b71919") else INK
		R.ammoType.BackgroundColor3 = if mag <= 0 and res <= 0 then Color3.fromHex("#d64848") else Color3.fromHex("#a4a4a4")
		R.readT.Text = tostring(mag)
	end

	-- distance pill colours vs the weapon range
	local d = (PC.aim - PC.pos).Magnitude
	R.markerT.Text = string.format("%.1fm", d)
	local g = if isGun then Guns.row(gid :: string) else nil
	R.markerT.TextColor3 = if g and d > Guns.range(g) then Color3.fromHex("#ff7c7c") elseif g and d > Guns.range(g) * 0.5 then Color3.fromHex("#ff9d4e") else Color3.fromHex("#d0ff99")

	-- reticle: diamonds pushed out by the spread, breathing 45 -> 50 -> 45 over 0.333 s, kick +-10 deg over 0.1 s per shot
	local c = Combat.cursor()
	R.ret.Position = UDim2.fromOffset(c.X / u, c.Y / u)
	R.ret.Visible = alive and not PC.blocked
	breath = (breath + dt / 0.333) % 1
	local sp = 0
	if g then
		local current = Combat.scatterDeg()
		local dur = player:GetAttribute("GunDur")
		local pct = if typeof(dur) == "number" then dur / 100 else 1
		local sc = current + math.max(1, current) * 1.5 * (1 - math.clamp(pct / 0.5, 0, 1))
		local off = math.tan(math.rad(sc * 0.5)) * math.max(2, d)
		local r = CameraRig.right
		local a = toScreen(Vector3.new(PC.aim.X, Config.Body.aimPlane, PC.aim.Y))
		local b = toScreen(Vector3.new(PC.aim.X + r.X * off, Config.Body.aimPlane, PC.aim.Y + r.Y * off))
		sp = math.clamp((b - a).Magnitude, 0, 140)
	end
	local dd = 45 + 5 * (1 - math.abs(breath * 2 - 1)) + sp
	for _, b in R.xhBlocks do
		b.f.Position = UDim2.fromOffset(b.dir.X * dd, b.dir.Y * dd)
		b.f.Visible = PC.held == "gun"
	end
	if lastMag >= 0 and mag < lastMag then
		kickT = 0
		kickA = (math.random() - 0.5) * 20
	end
	if mag ~= lastMag then
		wake = 0
	end
	lastMag = mag
	kickT += dt
	R.xh.Rotation = 45 + (if kickT < 0.1 then kickA * (1 - math.abs(kickT / 0.05 - 1)) else 0)
	if PC.held == "gun" then
		R.cdot.Size = UDim2.fromOffset(11, 11)
		R.cdot.BackgroundTransparency = 0
		R.cdotStroke.Color = INK
		R.cdotStroke.Thickness = 1.5
	else
		R.cdot.Size = UDim2.fromOffset(20, 20) -- melee: a 28 ring (4 px white border)
		R.cdot.BackgroundTransparency = 1
		R.cdotStroke.Color = WHITE
		R.cdotStroke.Thickness = 4
	end
	local reloading, frac = Combat.reloading()
	R.reload.Visible = reloading
	if reloading then
		setRing(R.reloadRing, frac)
		wake = 0
	end
	hitT += dt
	local k = hitT / hitDur
	if k < 1 then
		local o, a = lerpKeys(if hitKind == "kill" then HMK else HM, k)
		R.hm.Visible = true
		for _, b in R.hmBars do
			b.f.Position = UDim2.fromOffset(b.dir.X * o, b.dir.Y * o)
			b.f.BackgroundTransparency = 1 - a
		end
	else
		R.hm.Visible = false
	end
	-- cover marker
	R.cover.Visible = false
	if g and alive and not PC.blocked then
		local mz = Guns.muzzle(gid :: string, PC.pos.X, PC.pos.Y, PC.facing)
		local to = Vector3.new(PC.aim.X, mz.Y, PC.aim.Y)
		local hit = Workspace:Raycast(mz * S, (to - mz) * S, coverParams)
		if hit then
			local p = toScreen(hit.Position / S)
			R.cover.Position = UDim2.fromOffset(p.X, p.Y)
			R.cover.Visible = true
		end
	end

	-- stamina ring at the character (-31.5, +30), shown below 99.9 %
	local char = player.Character
	local rootPart = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if rootPart and alive then
		local p = toScreen(rootPart.Position / S)
		R.stam.Position = UDim2.fromOffset(p.X - 31.5, p.Y + 30)
		local f = PC.stamina / Config.Stamina.max
		R.stam.Visible = f < 0.999
		setRing(R.stamRing, f)
		ringColor(R.stamRing, if f <= 0.2 then Color3.fromHex("#ff7575") elseif f < 0.6 then Color3.fromHex("#fffb9b") else Color3.fromHex("#a5ff86"))
	else
		R.stam.Visible = false
	end

	-- item use progress (holds are set by Interact)
	local useUntil, useStart = player:GetAttribute("UseUntil"), player:GetAttribute("UseStart")
	if usingId and typeof(useUntil) == "number" and typeof(useStart) == "number" then
		Hud.setProgress((Workspace:GetServerTimeNow() - useStart) / math.max(0.01, useUntil - useStart))
		wake = 0
	elseif not player:GetAttribute("HoldId") then
		Hud.setProgress(nil)
	end

	-- extraction countdown
	local exLeft = player:GetAttribute("ExtractLeft")
	if typeof(exLeft) == "number" and exLeft > 0 then
		R.ex.Visible = true
		R.exClip.Size = UDim2.fromScale(1 - exLeft / Config.Extract.time, 1)
		local whole = math.floor(exLeft)
		R.exT.Text = string.format('%02d:%02d.<font size="12"> %03d</font>', whole // 60, whole % 60, math.floor((exLeft % 1) * 1000))
		local off = (os.clock() * 3) % 1
		local cs = { ColorSequenceKeypoint.new(0, Color3.fromHex("#aef19e")) }
		for j = 0, 3 do
			local x0 = ((j + off) / 4) % 1
			if x0 > 0.01 and x0 < 0.93 then
				table.insert(cs, { x0, Color3.fromHex("#aef19e") } :: any)
				table.insert(cs, { x0 + 0.005, Color3.fromHex("#cbf8c1") } :: any)
				table.insert(cs, { x0 + 0.06, Color3.fromHex("#cbf8c1") } :: any)
				table.insert(cs, { x0 + 0.065, Color3.fromHex("#aef19e") } :: any)
			end
		end
		local seq = { ColorSequenceKeypoint.new(0, Color3.fromHex("#aef19e")) }
		local raw = {}
		for idx = 2, #cs do
			table.insert(raw, cs[idx])
		end
		table.sort(raw, function(a: any, b: any)
			return a[1] < b[1]
		end)
		for _, kp in raw do
			table.insert(seq, ColorSequenceKeypoint.new((kp :: any)[1], (kp :: any)[2]))
		end
		table.insert(seq, ColorSequenceKeypoint.new(1, Color3.fromHex("#aef19e")))
		pcall(function()
			R.exStripes.Color = ColorSequence.new(seq)
		end)
	else
		R.ex.Visible = false
	end

	-- toasts
	if toastPhase == "idle" and #toastQ > 0 then
		R.banT.Text = toastQ[1]
		R.ban.Visible = true
		toastPhase, toastT = "in", 0
	end
	if toastPhase ~= "idle" then
		toastT += dt
		local a = 1
		if toastPhase == "in" then
			a = math.min(1, toastT / 0.12)
			if toastT >= 0.12 then
				toastPhase, toastT = "hold", 0
			end
		elseif toastPhase == "hold" then
			if toastT >= (if #toastQ > 1 then 0.65 else 1.2) then
				toastPhase, toastT = "out", 0
			end
		else
			a = 1 - math.min(1, toastT / 0.12)
			if toastT >= 0.12 then
				table.remove(toastQ, 1)
				toastPhase = "idle"
				R.ban.Visible = false
			end
		end
		R.ban.BackgroundTransparency = 1 - 0.949 * a
		R.banT.TextTransparency = 1 - a
		R.banT:FindFirstChildOfClass("UIStroke").Transparency = 1 - 0.65 * a
	end

	-- statuses
	local list = {}
	local bleed = player:GetAttribute("Bleed")
	if typeof(bleed) == "number" and bleed > 0 then
		table.insert(list, { name = "Bleeding", sub = "x" .. bleed })
	end
	if os.clock() < painUntil then
		table.insert(list, { name = "Pain", sub = string.format("%ds", math.ceil(painUntil - os.clock())) })
	end
	local load = player:GetAttribute("Load")
	if typeof(load) == "number" then
		if load > 1 then
			table.insert(list, { name = "Overloaded" })
		elseif load > 0.75 then
			table.insert(list, { name = "Overweight" })
		elseif load <= 0.25 then
			table.insert(list, { name = "Agile" })
		end
	end
	local water, energy = player:GetAttribute("Water"), player:GetAttribute("Energy")
	if typeof(water) == "number" then
		if water <= 0 then
			table.insert(list, { name = "Dehydrated" })
		elseif water < 25 then
			table.insert(list, { name = "Thirsty" })
		end
	end
	if typeof(energy) == "number" then
		if energy <= 0 then
			table.insert(list, { name = "Starving" })
		elseif energy < 25 then
			table.insert(list, { name = "Hungry" })
		end
	end
	setStatuses(list)

	-- calm-HUD dim after 4 s without a change (.42 over 0.6 s)
	local sig = string.format("%s|%s|%s|%s|%d|%d", tostring(gid), tostring(PC.held), tostring(PC.slot), tostring(player:GetAttribute("Bag")), math.floor((tonumber(water) or 0) / 5), math.floor((tonumber(energy) or 0) / 5))
	if sig ~= wakeSig or PC.blocked then
		wakeSig = sig
		wake = 0
	end
	wake += dt
	local targetT = if wake > 4 then 0.58 else 0
	R.dim.GroupTransparency += (targetT - R.dim.GroupTransparency) * math.min(1, dt * 5)

	-- damage numbers: launch 6 m/s, gravity -10, 0.9 s; scale 1.869 -> 1 over the first 16 %, fade over the second half
	for i = #nums, 1, -1 do
		local n = nums[i]
		n.t += dt
		if n.t >= 0.9 then
			n.lbl:Destroy()
			table.remove(nums, i)
		else
			n.v -= Vector3.new(0, 10 * dt, 0)
			n.pos += Vector3.new(n.v.X * dt * 0.3, n.v.Y * dt, 0)
			local p, on = toScreen(n.pos)
			n.lbl.Visible = on
			n.lbl.Position = UDim2.fromOffset(p.X, p.Y)
			local life = n.t / 0.9
			n.lbl:FindFirstChildOfClass("UIScale").Scale = (if life < 0.16 then 1.869 - 0.869 * (life / 0.16) else 1) * (if n.crit then 1.2 else 1)
			local a = if life < 0.5 then 1 else 1 - (life - 0.5) / 0.5
			n.lbl.TextTransparency = 1 - a
			n.lbl:FindFirstChildOfClass("UIStroke").Transparency = 1 - a
		end
	end
	for i = #snds, 1, -1 do
		local sm = snds[i]
		sm.t += dt
		if sm.t >= 1.5 then
			sm.f:Destroy()
			table.remove(snds, i)
		else
			sm.f.BackgroundTransparency = if sm.t < 0.1 then 1 - sm.t / 0.1 else (sm.t - 0.1) / 1.4
		end
	end
end

function Hud.start()
	build()
	Fx.onHitMarker = hitMarker
	Combat.onSound = Hud.soundMarker
	Fx.onDamage = function(at: Vector3, dmg: number, crit: boolean)
		Hud.damageNumber(at, dmg, crit)
	end
	Net.event("Toast").OnClientEvent:Connect(function(t: string, kind: string?)
		Hud.toast(t, kind)
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.O then
			R.controls.Visible = not R.controls.Visible
		end
	end)
end

return Hud
