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
local Controls = require(script.Parent.Controls)

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
-- every key hint: the keyboard key; the platform's button image on a gamepad (UserInputService:GetImageForKeyCode);
-- hidden on touch (the touch buttons carry their own labels)
type Cap = { holder: Frame, cap: TextLabel, under: Frame, img: ImageLabel, key: string }
local caps: { Cap } = {}
local HOT_KEYS = { ["3"] = 1, ["4"] = 2, ["5"] = 3, ["6"] = 4, ["7"] = 5, ["8"] = 6 }
local function applyCap(c: Cap)
	local m = Controls.mode
	local pad = if m == "gamepad" then Controls.PAD_FOR[c.key] else nil
	if m == "gamepad" and HOT_KEYS[c.key] then
		-- the hotbar: LB on the D-pad's pick only
		pad = if HOT_KEYS[c.key] == Controls.padSlot then Enum.KeyCode.ButtonL1 else nil
	end
	if m == "touch" or (m == "gamepad" and not pad) then
		c.holder.Visible = false
		return
	end
	c.holder.Visible = true
	if pad then
		c.cap.Text = ""
		c.cap.BackgroundTransparency = 1
		c.under.Visible = false
		c.img.Image = UserInputService:GetImageForKeyCode(pad)
		c.img.Visible = true
		c.cap.Size = UDim2.fromOffset(c.img.Size.X.Offset, c.cap.Size.Y.Offset)
		c.cap.AutomaticSize = Enum.AutomaticSize.None
	else
		c.cap.Text = c.key
		c.cap.BackgroundTransparency = 0.216
		c.under.Visible = true
		c.img.Visible = false
		c.cap.AutomaticSize = Enum.AutomaticSize.X
		c.cap.Size = UDim2.fromOffset(0, c.cap.Size.Y.Offset)
	end
end
local function applyCaps()
	for i = #caps, 1, -1 do
		local c = caps[i]
		if c.holder.Parent == nil then
			table.remove(caps, i)
		else
			applyCap(c)
		end
	end
end

--- a transparent touch target over a HUD element (touch only)
local taps: { GuiButton } = {}
local function tappable(over: GuiObject, fn: () -> ())
	local b = new("TextButton", { Name = "Tap", Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 50,
		Visible = Controls.mode == "touch", Selectable = false }, over)
	b.Activated:Connect(fn)
	table.insert(taps, b)
	return b
end

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
	local img = new("ImageLabel", { Name = "Pad", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(hh * 1.15, hh * 1.15), ZIndex = 3, Visible = false }, holder)
	local entry = { holder = holder, cap = cap, under = under, img = img, key = key }
	table.insert(caps, entry)
	applyCap(entry)
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
-- the Controls panel rows per device (the web's keyboard list; the gamepad's map from Controls.luau)
local CONTROL_ROWS = {
	kbm = { { "WASD", "Move" }, { "Shift", "Run" }, { "Space", "Dodge" }, { "LMB", "Shoot" }, { "RMB", "Aim" }, { "R", "Reload" }, { "F", "Interact" },
		{ "Tab", "Backpack" }, { "1 2 V", "Weapons" }, { "3-8", "Items" }, { "X", "Cancel" } },
	gamepad = { { Enum.KeyCode.Thumbstick1, "Move" }, { Enum.KeyCode.ButtonL3, "Run" }, { Enum.KeyCode.ButtonA, "Dodge" },
		{ Enum.KeyCode.ButtonR2, "Shoot" }, { Enum.KeyCode.Thumbstick2, "Aim" }, { Enum.KeyCode.ButtonL2, "Aim Down Sights" },
		{ Enum.KeyCode.ButtonY, "Reload" }, { Enum.KeyCode.ButtonX, "Interact" }, { Enum.KeyCode.ButtonSelect, "Backpack (hold: menu)" },
		{ Enum.KeyCode.ButtonR1, "Weapons" }, { Enum.KeyCode.DPadLeft, "Pick item" }, { Enum.KeyCode.ButtonL1, "Use item" },
		{ Enum.KeyCode.ButtonR3, "Ammo type" }, { Enum.KeyCode.ButtonB, "Cancel" } },
}
local function fillControls()
	local panel = R.controls
	if not panel then
		return
	end
	for _, c in panel:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for i, row in CONTROL_ROWS[if Controls.mode == "gamepad" then "gamepad" else "kbm"] do
		local e = box(panel, Vector2.new(0, 58), INK, 0.773, 999)
		e.AutomaticSize = Enum.AutomaticSize.X
		e.LayoutOrder = i
		new("UIPadding", { PaddingLeft = UDim.new(0, 25), PaddingRight = UDim.new(0, 25) }, e)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) }, e)
		if typeof(row[1]) == "EnumItem" then
			new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromOffset(46, 46), Image = UserInputService:GetImageForKeyCode(row[1]) }, e)
		else
			keycap(e, row[1], 38.5)
		end
		text(e, row[2], 28)
	end
end

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
	R.stormLabel = text(storm, "Next Storm Arrives In:", 25)
	R.stormTime = text(storm, "216:00", 30, { TextColor3 = Color3.fromHex("#fdc6ff"), FontFace = DIGITS })

	-- controls hint (SimpleIndicators: right 25, top 100) + the panel toggled with O
	local hint = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -25, 0, 100), Size = UDim2.fromOffset(0, 58), AutomaticSize = Enum.AutomaticSize.X }, root)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 10) }, hint)
	text(hint, "Controls", 28)
	keycap(hint, "O", 38.5)
	R.hint = hint
	local panel = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -25, 0, 168.5), Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, Visible = false }, root)
	new("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, panel)
	R.controls = panel
	fillControls()

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

	-- #armor (left centre - 854, bottom 112, 260 wide, gap 40): .arm = a 34 helmet / vest icon #e9ecee over "cur/max" 17;
	-- .none (nothing worn) the icon rgba(255,141,141,.85) and no text; .broken (0 durability) the icon #8c8f92
	local arm = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0.5, -854, 1, -112), Size = UDim2.fromOffset(260, 54) }, dim)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 40) }, arm)
	local function armBox(glyphName: string, order: number): (ImageLabel, TextLabel)
		local b = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(60, 54), LayoutOrder = order }, arm)
		local ic = new("ImageLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.fromOffset(34, 34) }, b)
		require(script.Parent.Icon).glyph(ic, glyphName)
		local t = text(b, "", 17, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 34), Size = UDim2.fromOffset(60, 20), TextXAlignment = Enum.TextXAlignment.Center })
		return ic, t
	end
	R.armHelmetIc, R.armHelmet = armBox("arm_head", 1)
	R.armVestIc, R.armVest = armBox("arm_body", 2)

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
		local icon = new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.new(0.9, 0, 0.7, 0), Position = UDim2.fromScale(0.05, 0.08), Visible = false }, b)
		local name = text(b, "", 18, { AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.new(1, -8, 0, 22), Position = UDim2.new(0, 4, 1, -26), TextScaled = true })
		local kc = keycap(b, spec[2])
		kc.AnchorPoint = Vector2.new(0.5, 0)
		kc.Position = UDim2.new(0.5, 0, 1, 8.8)
		local key = ({ Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.V })[i]
		tappable(b, function()
			Controls.tap(key)
		end)
		local punch = new("UIScale", { Scale = 1 }, b)
		R.weapons[i] = { frame = b, sel = sel, icon = icon, name = name, id = "", punch = punch }
	end

	-- hotbar (starts at centre + 75, gap 20, 100x100 slots, bottom 50, keys 3-8)
	local hb = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0.5, 75, 1, -50), Size = UDim2.fromOffset(720, 100) }, dim)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 20), SortOrder = Enum.SortOrder.LayoutOrder }, hb)
	R.hot = {}
	for i = 1, 6 do
		local b = box(hb, Vector2.new(100, 100), INK, 0.749, 16)
		b.LayoutOrder = i
		local ringIn = new("UIStroke", { Thickness = 2, Color = WHITE, Transparency = 0.702, Enabled = false, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
		local name = text(b, "", 18, { AutomaticSize = Enum.AutomaticSize.None, Size = UDim2.new(1, -12, 1, -24), Position = UDim2.fromOffset(6, 4), TextWrapped = true, TextScaled = true, Visible = false })
		local icon = new("ImageLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.46), Size = UDim2.fromOffset(72, 72), Visible = false }, b)
		local ct = box(b, Vector2.new(0, 17.5), Color3.fromHex("#585f66"), 1, 999)
		ct.AnchorPoint = Vector2.new(1, 1)
		ct.Position = UDim2.fromScale(1, 1)
		ct.AutomaticSize = Enum.AutomaticSize.X
		new("UIPadding", { PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5) }, ct)
		local cts = text(ct, "", 16, { TextColor3 = Color3.fromHex("#f8f2ea"), Size = UDim2.fromOffset(0, 17.5) })
		local kc = keycap(b, tostring(i + 2))
		kc.AnchorPoint = Vector2.new(0.5, 0)
		kc.Position = UDim2.new(0.5, 0, 1, 8.8)
		local hk = ({ Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six, Enum.KeyCode.Seven, Enum.KeyCode.Eight })[i]
		tappable(b, function()
			Controls.tap(hk)
		end)
		R.hot[i] = { frame = b, ringIn = ringIn, name = name, icon = icon, ct = ct, cts = cts, iconId = "" }
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
	tappable(typ, function()
		Controls.tap(Enum.KeyCode.T)
	end)
	local tk = keycap(typ, "T", 30)
	tk.AnchorPoint = Vector2.new(0, 0.5)
	tk.Position = UDim2.new(1, 18, 0.5, 0)
	local cnt = box(ammo, Vector2.new(116, 35.2), INK, 1, 10.03)
	cnt.AnchorPoint = Vector2.new(0.5, 1)
	local cA = text(cnt, "08", 18, { FontFace = DIGITS, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(0.5, -8, 0, 4) })
	text(cnt, "/", 18, { FontFace = DIGITS, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4) })
	local cR = text(cnt, "30", 18, { FontFace = DIGITS, Position = UDim2.new(0.5, 8, 0, 4) })
	R.ammo, R.ammoType, R.ammoTypeT, R.ammoCount, R.ammoA, R.ammoR = ammo, typ, typT, cnt, cA, cR
	-- the SelectList over the type pill while BulletTypeHUD's list is open: one pill per entry (name + count), the
	-- selected one white
	R.blist = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromOffset(0, -80),
		Size = UDim2.fromOffset(0, 0), AutomaticSize = Enum.AutomaticSize.XY, Visible = false }, ammo)
	new("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Bottom,
		Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, R.blist)

	-- distance pill (right 30.8, bottom 52.2, 166.5x50.6)
	local mk = box(root, Vector2.new(166.5, 50.6), INK, 0.788, 999)
	R.marker = mk
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
	tappable(cancel, function()
		Controls.tap(Enum.KeyCode.X)
	end)
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
type Snd = { f: GuiObject, t: number, at: Vector3? }
local snds: { Snd } = {}
local coverParams = RaycastParams.new()
coverParams.CollisionGroup = "QBullet"

local hotbar: { string } = {}

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

--- the id bound to hotbar slot i (nil when empty) and how many the backpack holds
function Hud.hotbarItem(i: number): (string?, number)
	local id = hotbar[i]
	if not id or id == "" then
		return nil, 0
	end
	local n = 0
	for _, st in bagStacks() do
		if st.id == id then
			n += st.n
		end
	end
	return id, n
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
	local key = Controls.mode
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
	-- WorldUI: 6 m/s within 10 degrees of straight up, toward a random side
	local a = math.rad((math.random() - 0.5) * 2 * 10)
	local side = math.random() * math.pi * 2
	local v = Vector3.new(math.sin(a) * math.cos(side), math.cos(a), math.sin(a) * math.sin(side)) * 6
	table.insert(nums, { lbl = lbl, pos = at + Vector3.new(0, 2, 0), v = v, t = 0, crit = crit })
end

--- sound marker: an arc on a 400 px ring around the screen centre toward an unseen shot (1.5 s)
-- WorldUI sound marker (.snd): a 120 circle drawing only its top border (6 px; #fff steps, #ffd0d0 shots), on the 400 px
-- ring toward the sound, unrotated; 0.1 s fade in, then fades over its 1.5 s life; a marker within 1.5 m of a fresh one
-- (past half its life left) is skipped
local arcImg: any = nil
local function arc(): any
	if arcImg ~= nil then
		return arcImg
	end
	arcImg = false
	local ok, img = pcall(function()
		return game:GetService("AssetService"):CreateEditableImage({ Size = Vector2.new(120, 120) })
	end)
	if not ok or not img then
		return false
	end
	local px = buffer.create(120 * 120 * 4)
	for y = 0, 119 do
		for x = 0, 119 do
			local cover = 0
			for sy = 0, 1 do
				for sx = 0, 1 do
					local dx, dy = x + (sx + 0.5) / 2 - 60, y + (sy + 0.5) / 2 - 60
					local r = math.sqrt(dx * dx + dy * dy)
					local th = math.deg(math.atan2(math.abs(dx), -dy)) -- 0 at the top
					-- border-top of a round box: full width over the top, tapering to nothing at the 45 deg corner joins
					local w = if th <= 30 then 6 elseif th < 45 then 6 * (45 - th) / 15 else 0
					if r <= 60 and r >= 60 - w then
						cover += 1
					end
				end
			end
			local o = (y * 120 + x) * 4
			buffer.writeu8(px, o, 255)
			buffer.writeu8(px, o + 1, 255)
			buffer.writeu8(px, o + 2, 255)
			buffer.writeu8(px, o + 3, math.floor(cover / 4 * 255 + 0.5))
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(120, 120), px)
	arcImg = img
	return img
end

function Hud.soundMarker(at: Vector3, kind: string?)
	if not R.wui then
		return
	end
	for _, m in snds do
		if m.at and (Vector2.new(m.at.X, m.at.Z) - Vector2.new(at.X, at.Z)).Magnitude < 1.5 and m.t < 0.75 then
			return
		end
	end
	local vp = Workspace.CurrentCamera.ViewportSize
	local sp = toScreen(at)
	local centre = Vector2.new(vp.X / 2 / u, vp.Y / 2 / u)
	local d = sp - centre
	if d.Magnitude < 1 then
		return
	end
	local p = centre + d.Unit * (400 * (vp.Y / 1080) / u)
	local img = arc()
	local f = new("ImageLabel", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(120, 120),
		Position = UDim2.fromOffset(p.X, p.Y), ImageColor3 = if kind == "step" then WHITE else Color3.fromHex("#ffd0d0"), ImageTransparency = 1 }, R.wui)
	if img then
		f.ImageContent = Content.fromObject(img)
	end
	table.insert(snds, { f = f, t = 0, at = at })
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

-- .st rows (#statuses, bottom-left, column-reverse, gap 10): a 50 pill (pad 2 / 15, #000 .745, shadow), a 40 icon (white,
-- .bad #ff8d8d) with its layers badge, the name 22 and the seconds 20; every rebuild pops in (st-in: scale .2 -> 1 with
-- the cubic-bezier(.2, 1.6, .5, 1) overshoot, 0.2 s)
type Status = { icon: string, name: string, bad: boolean, layers: number?, secs: number? }
local statusPops: { { s: UIScale, g: CanvasGroup, t: number } } = {}
local function setStatuses(list: { Status })
	local key = ""
	for _, s in list do
		key ..= s.name .. "|" .. tostring(s.layers) .. "|" .. tostring(s.secs and math.ceil(s.secs)) .. ";"
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
	table.clear(statusPops)
	local Icon = require(script.Parent.Icon)
	for i, s in list do
		local g = new("CanvasGroup", { BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 50), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = -i, GroupTransparency = 1 }, R.statuses)
		local p = box(g, Vector2.new(0, 50), INK, 0.745, 999)
		p.AutomaticSize = Enum.AutomaticSize.X
		new("UIPadding", { PaddingLeft = UDim.new(0, 15), PaddingRight = UDim.new(0, 15), PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2) }, p)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, p)
		local icf = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(40, 40), LayoutOrder = 1 }, p)
		local sh = new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Position = UDim2.fromOffset(5.66, 5.66), ImageColor3 = INK, ImageTransparency = 0.4 }, icf)
		Icon.glyph(sh, "st_" .. s.icon)
		local ic = new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ImageColor3 = if s.bad then Color3.fromHex("#ff8d8d") else WHITE }, icf)
		Icon.glyph(ic, "st_" .. s.icon)
		if s.layers and s.layers > 1 then
			local lay = box(icf, Vector2.new(0, 18), INK, 0.902, 999)
			lay.AutomaticSize = Enum.AutomaticSize.X
			lay.AnchorPoint = Vector2.new(1, 1)
			lay.Position = UDim2.fromScale(1, 1)
			new("UIPadding", { PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5) }, lay)
			text(lay, tostring(s.layers), 18, { Size = UDim2.fromOffset(0, 18) })
		end
		local nm = text(p, s.name, 22)
		nm.LayoutOrder = 2
		if s.secs then
			local em = text(p, string.format("%ds", math.ceil(s.secs)), 20)
			em.LayoutOrder = 3
		end
		local us = new("UIScale", { Scale = 0.2 }, g)
		table.insert(statusPops, { s = us, g = g, t = 0 })
	end
end

--- cubic-bezier(.2, 1.6, .5, 1) at time fraction x (solved for t by bisection)
local function stIn(x: number): number
	local function bz(t: number, a: number, b: number): number
		local u = 1 - t
		return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
	end
	local lo, hi = 0, 1
	for _ = 1, 20 do
		local mid = (lo + hi) / 2
		if bz(mid, 0.2, 0.5) < x then
			lo = mid
		else
			hi = mid
		end
	end
	return bz((lo + hi) / 2, 1.6, 1)
end

local function stepStatusPops(dt: number)
	for _, sp in statusPops do
		if sp.t < 0.2 then
			sp.t = math.min(0.2, sp.t + dt)
			local k = stIn(sp.t / 0.2)
			sp.s.Scale = 0.2 + 0.8 * k
			sp.g.GroupTransparency = 1 - math.clamp(k, 0, 1)
		end
	end
end

-- ------------------------------------------------------------------ frame
local updateCore: (number) -> ()
local lastPadSlot = 0
--- #hud.inv-open (duckov.css): weapons, hotbar, ammo, distance marker, stamina ring, statuses, clock, controls hint,
--- HP, rings and armor hide while the LootView is open; the reticle too (uiOpen)
function Hud.update(dt: number)
	updateCore(dt)
	if PC.invOpen then
		for _, o in { R.dim, R.clock, R.hint, R.controls, R.statuses, R.marker, R.stam, R.ret } do
			if o then
				o.Visible = false
			end
		end
	else
		-- updateCore sets the alive-dependent groups itself
		for _, o in { R.clock, R.hint, R.ret } do
			if o then
				o.Visible = true
			end
		end
		-- touch: the Backpack / Map / More buttons sit where the Controls hint is
		R.hint.Visible = Controls.mode ~= "touch"
		if Controls.mode == "touch" then
			R.controls.Visible = false
		end
	end
end

function updateCore(dt: number)
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

	-- clock, phase, weather and the storm countdown (Game.clockInfo: H:MM of STORM_START - cyc, hours uncapped;
	-- during a storm "Storm Phase I / II Ends In:" STORM_CYCLE - cyc)
	local cm = workspace:GetAttribute("ClockMin")
	if typeof(cm) == "number" then
		local h = (cm / 60) % 24
		R.clockTime.Text = string.format("%02d:%02d", math.floor(h), math.floor(cm % 60))
		R.clockPhase.Text = if h >= 22 or h < 6 then "Night" elseif h >= 18 then "Dusk" else "Day"
		local w = workspace:GetAttribute("Weather")
		R.clockWeather.Text = if typeof(w) == "string" then w else "Sunny"
		local START, CYCLE = 9 * 1440, 9 * 1440 + 1440
		local cyc = cm % CYCLE
		local storm = cyc >= START
		local phase = workspace:GetAttribute("StormPhase")
		R.stormLabel.Text = if storm then (if phase == 2 then "Storm Phase II Ends In:" else "Storm Phase I Ends In:") else "Next Storm Arrives In:"
		local left = if storm then CYCLE - cyc else START - cyc
		R.stormTime.Text = string.format("%d:%02d", math.floor(left / 60), math.floor(left % 60))
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
	for _, a in { { R.armVest, R.armVestIc, hasVest, ad, eq.armor }, { R.armHelmet, R.armHelmetIc, hasHelm, hd, eq.helmet } } do
		local lbl, ic, has, dur, id = a[1], a[2], a[3], a[4], a[5]
		local g = has and Guns.items[id] and Guns.items[id].gear
		local max = (g and g.dur) or 0
		local cur = if has then math.ceil(if typeof(dur) == "number" then dur else max) else 0
		lbl.Text = if has then string.format("%d/%d", cur, max) else ""
		ic.ImageColor3 = if not has then Color3.fromRGB(255, 141, 141) elseif cur <= 0 then Color3.fromHex("#8c8f92") else Color3.fromHex("#e9ecee")
		ic.ImageTransparency = if not has then 0.15 else 0
	end

	-- weapon buttons: the weapon's own model (Icon.render), selected ring #FFECE1 + punch
	for i, key in { "gun", "gun2", "melee" } do
		local w = R.weapons[i]
		local id = eq[key] or ""
		if id ~= w.id then
			w.id = id
			local def = Guns.items[id]
			w.name.Text = if def then def.name else ""
			require(script.Parent.Icon).apply(w.icon, if def then id else nil)
		end
		local sel = (i == (PC.slot or 1))
		if sel and not w.sel.Enabled then
			w.punch.Scale = 1.1
		end
		w.sel.Enabled = sel
		w.punch.Scale += (1 - w.punch.Scale) * math.min(1, dt * 20)
	end
	-- hotbar (Hud.ts): the bound ids (Profile hotbar, set in the LootView); the icon at .35 when none are left, the count
	-- pill above 1, the selected throwable's 3 px orange ring
	table.clear(hotbar)
	local counts: { [string]: number } = {}
	for _, st in bagStacks() do
		counts[st.id] = (counts[st.id] or 0) + st.n
	end
	local rawHot = player:GetAttribute("Hotbar")
	local k0 = 0
	if typeof(rawHot) == "string" then
		for id in string.gmatch(rawHot .. ",", "([^,]*),") do
			k0 += 1
			hotbar[k0] = id
		end
	end
	for k = 1, 6 do
		local hs = R.hot[k]
		local id = if hotbar[k] and hotbar[k] ~= "" then hotbar[k] else nil
		local def = id and Guns.items[id]
		local n = if id then counts[id] or 0 else 0
		hs.name.Text = ""
		if (id or "") ~= hs.iconId then
			hs.iconId = id or ""
			require(script.Parent.Icon).apply(hs.icon, id)
		end
		hs.icon.ImageTransparency = if n > 0 then 0 else 0.65
		local render = hs.icon:FindFirstChild("Render") :: ViewportFrame?
		if render then
			render.ImageTransparency = if n > 0 then 0 else 0.65
		end
		hs.ringIn.Enabled = def ~= nil
		hs.frame.BackgroundTransparency = if def then 0.8 else 0.251
		hs.ct.Visible = def ~= nil and n > 1
		hs.cts.Text = if def then tostring(n) else ""
		local throwSel = def ~= nil and PC.held == "throw" and require(script.Parent.Throw).id == id
		if throwSel then
			hs.ringIn.Color = Color3.fromHex("#ff9e3a")
			hs.ringIn.Thickness = 3
			hs.ringIn.Transparency = 0
		elseif Controls.mode == "gamepad" and k == Controls.padSlot then
			-- the D-pad's pick (LB uses it)
			hs.ringIn.Enabled = true
			hs.ringIn.Color = WHITE
			hs.ringIn.Thickness = 3
			hs.ringIn.Transparency = 0
		else
			hs.ringIn.Color = WHITE
			hs.ringIn.Thickness = 2
			hs.ringIn.Transparency = 0.702
		end
	end
	if Controls.padSlot ~= lastPadSlot then
		lastPadSlot = Controls.padSlot
		applyCaps()
	end

	-- the open ammo type list
	local BL = require(script.Parent.BulletList)
	BL.tick()
	local bkey = if BL.open then tostring(BL.index) .. "|" .. #BL.entries else ""
	for _, e in BL.entries do
		bkey ..= (e.id or "-") .. e.count
	end
	if bkey ~= R.blistKey then
		R.blistKey = bkey
		for _, c in R.blist:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		R.blist.Visible = BL.open
		if BL.open then
			for i, e in BL.entries do
				local selE = i == BL.index
				local p = box(R.blist, Vector2.new(0, 30.6), if selE then WHITE else Color3.fromHex("#a4a4a4"), if selE then 1 else 0.85, 999)
				p.AutomaticSize = Enum.AutomaticSize.X
				p.LayoutOrder = -i
				new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, p)
				local d = e.id and Guns.items[e.id]
				local t = text(p, (if d then d.name else "Not Assigned") .. (if e.id then "  " .. e.count else ""), 18,
					{ Size = UDim2.fromOffset(0, 30.6), TextColor3 = if selE then INK else WHITE })
				local st = t:FindFirstChildOfClass("UIStroke")
				if st and selE then
					st.Enabled = false
				end
				-- touch: an entry applies itself
				tappable(p, function()
					BL.index = i
					Controls.tap(Enum.KeyCode.T)
				end)
			end
		end
	end

	-- ammo block + the mag count at the cursor
	local gid = player:GetAttribute("Gun")
	local isGun = typeof(gid) == "string" and PC.held == "gun"
	local mag = Combat.mag()
	R.ammo.Visible = isGun
	R.read.Visible = isGun
	if isGun then
		-- the loaded type's name (Player.loadedType)
		local at = player:GetAttribute("AmmoType")
		local ammoId = if typeof(at) == "string" then at else Guns.ammoOf(gid :: string)
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
	local g = if isGun then Guns.rowWith(gid :: string, player:GetAttribute("GunAtt")) else nil
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
		local mz = Guns.muzzle(gid :: string, PC.pos.X, PC.pos.Y, PC.facing, math.atan2(PC.aim.X - PC.pos.X, PC.aim.Y - PC.pos.Y))
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
	local usingId = player:GetAttribute("UseId")
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

	-- statuses (Hud.updateStatuses order): bleeding, pain, weight, thirst, hunger, distortion
	local list: { Status } = {}
	local bleed = player:GetAttribute("Bleed")
	if typeof(bleed) == "number" and bleed > 0 then
		table.insert(list, { icon = "bleed", name = "Bleeding", bad = true, layers = bleed })
	end
	if os.clock() < painUntil then
		table.insert(list, { icon = "pain", name = "Pain", bad = true, secs = painUntil - os.clock() })
	end
	local load = player:GetAttribute("Load")
	if typeof(load) == "number" then
		if load > 1 then
			table.insert(list, { icon = "weight", name = "Overloaded", bad = true })
		elseif load > 0.75 then
			table.insert(list, { icon = "weight", name = "Overweight", bad = true })
		elseif load <= 0.25 then
			table.insert(list, { icon = "agile", name = "Agile", bad = false })
		end
	end
	local water, energy = player:GetAttribute("Water"), player:GetAttribute("Energy")
	if typeof(water) == "number" then
		if water <= 0 then
			table.insert(list, { icon = "thirst", name = "Dehydrated", bad = true })
		elseif water < 25 then
			table.insert(list, { icon = "thirst", name = "Thirsty", bad = true })
		end
	end
	if typeof(energy) == "number" then
		if energy <= 0 then
			table.insert(list, { icon = "hunger", name = "Starving", bad = true })
		elseif energy < 25 then
			table.insert(list, { icon = "hunger", name = "Hungry", bad = true })
		end
	end
	if player:GetAttribute("Distortion") then
		local layers = player:GetAttribute("StormLayers")
		table.insert(list, { icon = "storm", name = "Distortion", bad = true, layers = if typeof(layers) == "number" then layers else nil })
	end
	setStatuses(list)
	stepStatusPops(dt)

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
			n.pos += n.v * dt
			local p, on = toScreen(n.pos)
			n.lbl.Visible = on
			n.lbl.Position = UDim2.fromOffset(p.X, p.Y)
			local life = n.t / 0.9
			n.lbl:FindFirstChildOfClass("UIScale").Scale = (if life < 0.1616 then 1.869 - 0.869 * (life / 0.1616) else 1) * (if n.crit then 1.2 else 1)
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
			local tr = if sm.t < 0.1 then 1 - sm.t / 0.1 else (sm.t - 0.1) / 1.4
			if sm.f:IsA("ImageLabel") then
				(sm.f :: ImageLabel).ImageTransparency = tr
			else
				sm.f.BackgroundTransparency = tr
			end
		end
	end
end

function Hud.start()
	build()
	Fx.onHitMarker = hitMarker
	Combat.onSound = function(at: Vector3)
		Hud.soundMarker(at, "shot")
	end
	require(script.Parent.Vision).onStep = function(at: Vector3)
		Hud.soundMarker(at, "step")
	end
	Fx.onDamage = function(at: Vector3, dmg: number, crit: boolean)
		Hud.damageNumber(at, dmg, crit)
	end
	Net.event("Toast").OnClientEvent:Connect(function(t: string, kind: string?)
		Hud.toast(t, kind)
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.O and not PC.photoOpen then
			R.controls.Visible = not R.controls.Visible
		end
	end)
	-- the quick menu's Controls entry (gamepad / touch)
	Controls.onKey(function(kc, down)
		if down and kc == Enum.KeyCode.O and not PC.photoOpen then
			R.controls.Visible = not R.controls.Visible
		end
	end)
	Controls.onMode(function()
		applyCaps()
		fillControls()
		for i = #taps, 1, -1 do
			if taps[i].Parent == nil then
				table.remove(taps, i)
			else
				taps[i].Visible = Controls.mode == "touch"
			end
		end
		promptKey = ""
	end)
end

return Hud
