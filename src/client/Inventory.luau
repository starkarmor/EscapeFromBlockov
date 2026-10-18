--!strict
-- The LootView (Tab / loot / looting a body), 1:1 with the web build's src/ui/InventoryUI.ts + inventory.css: the Tabs
-- chrome, EquipmentAndInventory (wallet, equipment SlotDisplays, the backpack grid with Sort, the weight bar, the dog's
-- bag), LootTarget (the open container), ShortcutEditor (the hotbar), ItemDetails (the selected item with its attachment
-- slots), ItemHoveringUI (tooltip + key hints), ItemOperationMenu (right click), ItemSplitDialogue and ItemDraggingUI.
-- Every number is a reference px of the 2560x1440 source canvas; one UIScale maps it to the screen.
--
-- Input (InventoryUI): drag an item 6 px to pick it up (a ghost at .5 follows the pointer); release over a cell to move /
-- merge / swap it (InventoryEntry.OnDrop), over a hotbar slot to bind it, over an attachment slot to fit it, over another
-- pane to transfer it; Ctrl + drag onto an empty cell splits. A click selects (ItemDetails), a second click within 0.3 s
-- (or F) takes / stores / equips / unequips. Right click: the operation menu. Hover keys: F transfer, U use, X drop,
-- L lock, N mark, 3-8 hotbar, Shift more info. The server applies every change (server/Inventory.luau).
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Items = require(Shared.gen.Items)
local Inv = require(Shared.Inv)
local PC = require(script.Parent.PlayerControl)
local Icon = require(script.Parent.Icon)

local player = Players.LocalPlayer
local Inventory = {}
Inventory.open = false

-- ------------------------------------------------------------------ style (inventory.css)
local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Regular)
local FONT_M = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Medium)
local FONT_B = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold)
local FONT_NUM = Font.new("rbxasset://fonts/families/Michroma.json", Enum.FontWeight.Bold) -- Orbitron stand-in
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local CREAM = Color3.fromHex("#f8f2ea")
local ORANGE = Color3.fromHex("#ff9e3a")
local RED = Color3.fromHex("#f85566")
-- TranslucentImage panels: the tint over a 12 px backdrop blur; Roblox GUI has no backdrop blur, so the tint sits on a
-- dark underlay that keeps the same contrast (navy20 inventory panels, grey20 weight bar / details, money pills)
local NAVY = { Color3.fromRGB(26, 50, 76), 0.3 }
local GREY = { Color3.fromRGB(52, 52, 52), 0.3 }
local MONEY = { Color3.fromRGB(34, 86, 122), 0.28 }
-- displayQualityLooks: quality only as a glow around the icon (white, green, blue, purple, orange, red)
local QUALITY_GLOW = { [0] = "#ffffff", "#8be913", "#11b8f1", "#990ff5", "#ff7d25", "#ff2f2f", "#ff2f2f" }
local DOUBLE_CLICK = 0.3
local MOD_LABEL = {
	damage = "DMG", rpm = "Fire Rate", mag = "Magazine Capacity", reload = "Reload Time", bulletSpeed = "Bullet Speed",
	range = "Range", critMul = "CRIT DMG Multiplier", soundRange = "Sound Range", adsTime = "ADS Time",
	moveMul = "Movement Speed", adsMoveMul = "ADS Movement Speed", hipSpread = "Hip Fire Spread", adsSpread = "ADS Spread",
	recoil = "Recoil", pellets = "Pellets", armorPen = "Armor Penetration Level", adsLook = "ADS Aim Distance",
}

type Ref = { src: string, i: string }
type InstV = { id: string, n: number, pos: number?, ammo: number?, dur: number?, loss: number?, uses: number?, att: { [string]: string }?, hidden: boolean? }

-- ------------------------------------------------------------------ state
local state: any = nil -- the server's view (server/Inventory.luau send)
local sel: Ref? = nil
local hover: Ref? = nil
local hoverAt = Vector2.zero
local lastClick: { key: string, t: number }? = nil
local shift = false
local drag: { ref: Ref, start: Vector2, moved: boolean, ghost: GuiObject? }? = nil
local split: { src: string, i: number, n: number, max: number, to: any }? = nil
local menuFor: Ref? = nil

local gui: ScreenGui
local root: Frame
local scale: UIScale
local overlay: ScreenGui
local oroot: Frame
local oscale: UIScale
local view: Frame -- rebuilt content
local tip: Frame
local menu: Frame
local splitDlg: Frame
local spinners: { ImageLabel } = {}
-- a rebuild destroys the hovered button (which fires MouseLeave): the hover survives it
local rendering = false
-- this render's cells, in creation order (later = drawn on top): the release falls back to the cell under the pointer
local cells: { { btn: GuiObject, ref: Ref } } = {}

local function cellAt(m: Vector2): Ref?
	for k = #cells, 1, -1 do
		local c = cells[k]
		local b = c.btn
		if b.Parent then
			local vis = b.Visible
			local x = b.Parent
			while vis and x and x:IsA("GuiObject") do
				vis = x.Visible
				x = x.Parent
			end
			local a0, a1 = b.AbsolutePosition, b.AbsolutePosition + b.AbsoluteSize
			if vis and m.X >= a0.X and m.X <= a1.X and m.Y >= a0.Y and m.Y <= a1.Y then
				return c.ref
			end
		end
	end
	return nil
end

local function def(id: string): any
	return Items.items[id]
end

-- AbsolutePosition is measured below the top-bar inset; the overlay (IgnoreGuiInset) and the mouse are screen space
local function screenPos(v: Vector2): Vector2
	return v + game:GetService("GuiService"):GetGuiInset()
end

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

--- decoration never takes the pointer (the tooltip sits under it, outlines and icons cover the cells)
local function passThrough(root: Instance)
	for _, x in root:GetDescendants() do
		if x:IsA("GuiObject") and not x:IsA("GuiButton") and not x:IsA("ScrollingFrame") then
			x.Interactable = false
		end
	end
end

local function corner(o: Instance, r: number)
	new("UICorner", { CornerRadius = UDim.new(0, r) }, o)
end

local function frame(parent: Instance, pos: UDim2, size: UDim2, color: Color3?, alpha: number?, r: number?): Frame
	local f = new("Frame", { Position = pos, Size = size, BorderSizePixel = 0, BackgroundColor3 = color or BLACK,
		BackgroundTransparency = if color then 1 - (alpha or 1) else 1 }, parent)
	if r then
		corner(f, r)
	end
	return f
end

local function panel(parent: Instance, pos: UDim2, size: UDim2, tint: { any }, r: number?): Frame
	local f = frame(parent, pos, size, tint[1], 1 - tint[2], r or 16)
	-- panels catch clicks (only the empty view area closes the view)
	f.Active = true
	return f
end

local function commas(n: number): string
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if string.sub(out, 1, 1) == "," then
		out = string.sub(out, 2)
	end
	return out
end

--- a TMP label with the "Shadow" material (0 2 3 px black .55): a dark copy 2 px below
local function label(parent: Instance, text: string, size: number, props: { [string]: any }?, shadow: boolean?): TextLabel
	local t = new("TextLabel", { BackgroundTransparency = 1, Text = text, TextSize = size, FontFace = FONT, TextColor3 = WHITE,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center, RichText = false }, nil)
	for k, v in props or {} do
		(t :: any)[k] = v
	end
	t.Parent = parent
	if shadow then
		local sh = t:Clone()
		sh.Name = "Shadow"
		sh.TextColor3 = BLACK
		sh.TextTransparency = 0.45
		sh.Position = t.Position + UDim2.fromOffset(0, 2)
		sh.ZIndex = t.ZIndex
		sh.Parent = parent
		t.ZIndex += 1
	end
	return t
end

local function glyph(parent: Instance, name: string, pos: UDim2, size: number, color: Color3?, alpha: number?): ImageLabel
	local l = new("ImageLabel", { BackgroundTransparency = 1, Position = pos, Size = UDim2.fromOffset(size, size),
		ImageColor3 = color or WHITE, ImageTransparency = 1 - (alpha or 1) }, parent)
	Icon.glyph(l, name)
	return l
end

local function stroke(o: Instance, thick: number, color: Color3, alpha: number?)
	new("UIStroke", { Thickness = thick, Color = color, Transparency = 1 - (alpha or 1), ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o)
end

local function f1(n: number): string
	return string.format("%.1f", n)
end

local function keycap(parent: Instance, key: string, h: number?, pos: UDim2?): Frame
	local hh = h or 32
	local k = new("Frame", { BackgroundColor3 = WHITE, BackgroundTransparency = 0.216, Size = UDim2.fromOffset(32, hh),
		AutomaticSize = Enum.AutomaticSize.X, Position = pos or UDim2.new() }, parent)
	corner(k, 10)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, k)
	label(k, key, 20, { FontFace = FONT_B, TextColor3 = Color3.fromHex("#1e272e"), Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X, TextXAlignment = Enum.TextXAlignment.Center })
	return k
end

local function stripesInto(parent: GuiObject, band: number, a: Color3, aa: number, b: Color3, ba: number, r: number)
	local img = Icon.stripes(band, a, aa, b, ba)
	if not img then
		return
	end
	local l = new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Tile,
		TileSize = UDim2.fromOffset(band * 2, band * 2), ImageContent = Content.fromObject(img), ZIndex = parent.ZIndex }, parent)
	corner(l, r)
end

-- ------------------------------------------------------------------ data helpers
local function listOf(src: string): ({ InstV }, number)
	if not state then
		return {}, 0
	end
	if src == "bag" then
		return state.bag, state.cap
	elseif src == "pet" then
		return state.pet.items, state.pet.cap
	elseif src == "loot" and state.loot then
		return state.loot.items, state.loot.slots
	end
	return {}, 0
end

local function at(list: { InstV }, pos: number): InstV?
	for _, t in list do
		if t.pos == pos then
			return t
		end
	end
	return nil
end

--- the item a ref points at (a fitted part is addressed "src~i|slot"); hidden loot is nothing
local function instAt(t: Ref): InstV?
	if not state then
		return nil
	end
	if t.src == "eq" then
		return state.eq[t.i]
	elseif t.src == "hot" then
		local id = state.hotbar[(tonumber(t.i) or -1) + 1]
		return if id and id ~= "" then { id = id, n = 1 } else nil
	elseif t.src == "mod" then
		local owner, key = string.match(t.i, "^(.*)|(.*)$")
		local osrc, oi = string.match(owner or "", "^(%a+)~(.*)$")
		local host = if osrc then instAt({ src = osrc :: string, i = oi :: string }) else nil
		local id = host and host.att and host.att[key :: string]
		return if id then { id = id, n = 1 } else nil
	end
	local list = listOf(t.src)
	local it = at(list, tonumber(t.i) or -1)
	return if it and not it.hidden then it else nil
end

local function sameRef(a: Ref?, b: Ref?): boolean
	return a ~= nil and b ~= nil and a.src == b.src and a.i == b.i
end

local function op(...)
	Net.event("InvOp"):FireServer(...)
end

local function usable(id: string): boolean
	local d = def(id)
	return Inv.consumable(id) ~= nil or (d ~= nil and d.kind == "throwable")
end

local function emptyFirst(list: { InstV }, cap: number): number
	local used = {}
	local count = 0
	for _, t in list do
		used[t.pos or -1] = true
		count = math.max(count, (t.pos or -1) + 1)
	end
	for i = 0, count - 1 do
		if not used[i] then
			return i
		end
	end
	return if count < cap then count else -1
end

-- ------------------------------------------------------------------ item stats (itemStats.ts itemProps)
local function gunStats(inst: InstV): any
	local d = def(inst.id)
	local f = d and d.fire
	if not f then
		return nil
	end
	local out = table.clone(f)
	local pct, add = {}, {}
	for _, pid in (inst.att or {}) :: { [string]: string } do
		for _, m in (Items.partMods[pid] or {}) do
			if m[2] == "pct" then
				pct[m[1]] = (pct[m[1]] or 0) + m[3]
			else
				add[m[1]] = (add[m[1]] or 0) + m[3]
			end
		end
	end
	for k, v in out do
		if typeof(v) == "number" and (pct[k] or add[k]) then
			out[k] = (v + (add[k] or 0)) * (1 + (pct[k] or 0))
		end
	end
	return out
end

local function num(v: number): string
	if v == math.floor(v) then
		return tostring(v)
	end
	return tostring(math.floor(v * 100 + 0.5) / 100)
end

local function itemProps(inst: InstV): ({ { string } }, { { string } }, { string }, string)
	local rows: { { string } } = {}
	local mods: { { string } } = {}
	local effects: { string } = {}
	local d = def(inst.id) or {}
	local f = gunStats(inst)
	local m, a, c, g = d.melee, d.ammo, d.use, d.gear
	local function row(k: string, v: any)
		table.insert(rows, { k, if typeof(v) == "number" then num(v) else tostring(v) })
	end
	if f then
		if inst.dur ~= nil then
			row("Durability", string.format("%d/%d", math.ceil(inst.dur), math.floor(100 * (1 - (inst.loss or 0)) + 0.5)))
		end
		row("Current Ammo", string.format("%d/%d", inst.ammo or 0, math.floor(f.mag)))
		row("DMG", if (f.pellets or 1) > 1 then num(f.damage) .. " x" .. num(f.pellets) else f.damage)
		row("Fire Rate", string.format("%.1f", f.rpm / 60))
		row("Magazine Capacity", math.floor(f.mag))
		row("Reload Time", f.reload)
		row("Bullet Speed", f.bulletSpeed)
		row("Range", f.range)
		row("CRIT DMG Multiplier", f.critMul)
		row("Sound Range", f.soundRange)
		row("ADS Time", f.adsTime)
		row("Movement Speed Coefficient", f.moveMul)
		row("ADS Movement Coefficient", f.adsMoveMul)
		row("Hip Fire Spread", f.hipSpread)
		row("ADS Spread", f.adsSpread)
		row("Recoil", f.recoil)
	elseif m then
		row("DMG", m.damage)
		row("Attack Range", m.range)
		row("Attack Speed", string.format("%.1f", 1 / m.interval))
		row("Stamina Cost", 0)
		row("Armor Penetration Level", m.armorPen or 0)
		row("Crit Chance", m.critChance or 0)
		row("CRIT DMG Multiplier", m.critMul or 1)
		row("Chance to Bleed", m.bleedChance or 0)
	elseif a then
		row("DMG Coefficient", a.dmgMul)
		row("Armor Penetration Level", a.armorPen)
		row("Armor Break", a.armorBreak)
		row("Chance to Bleed", a.bleedChance)
	elseif c then
		if c.uses then
			row("Uses", string.format("%s/%s", num(inst.uses or c.uses), num(c.uses)))
		end
		row("Use Time", num(c.useTime or 1) .. "s")
	end
	for _, md in (Items.partMods[inst.id] or {}) do
		local v = md[3]
		local s = if md[2] == "pct" then (if v > 0 then "+" else "") .. tostring(math.floor(v * 100 + 0.5)) .. "%"
			else (if v > 0 then "+" else "") .. num(math.floor(v * 100 + 0.5) / 100)
		table.insert(mods, { MOD_LABEL[md[1]] or md[1], s })
	end
	if f and inst.att then
		for k, id in inst.att do
			local pd = def(id)
			table.insert(rows, { Inv.SLOT_NAMES[k] or k, if pd then pd.name else id })
		end
	end
	if g and (g.armor or g.headArmor) then
		row(if g.armor then "Body Armor" else "Head Armor", g.armor or g.headArmor)
		row("Durability", string.format("%d/%d", math.ceil(inst.dur or g.dur or 0), math.floor((g.dur or 0) * (1 - (inst.loss or 0)) + 0.5)))
	end
	if g and g.slots then
		row("Inventory Slots", "+" .. g.slots)
	end
	if g and g.carry then
		row("Max Carry", "+" .. g.carry .. " kg")
	end
	if g and g.storm then
		row("Storm Protection", g.storm)
	end
	if g and g.hearing then
		row("Hearing", "+" .. math.floor(g.hearing * 100 + 0.5) .. "%")
	end
	if c then
		if c.heal then
			table.insert(effects, "Heal HP: " .. num(c.heal))
		end
		if c.bleedStacks then
			table.insert(effects, "Stops bleeding")
		end
		if c.energy then
			table.insert(effects, "Energy: " .. (if c.energy > 0 then "+" else "") .. num(c.energy))
		end
		if c.hydration then
			table.insert(effects, "Hydration: " .. (if c.hydration > 0 then "+" else "") .. num(c.hydration))
		end
		if c.buff then
			table.insert(effects, tostring(c.buff.name) .. ": " .. num(c.buff.secs) .. "s")
		end
	end
	return rows, mods, effects, (f and f.caliber) or (a and a.caliber) or ""
end

local function negValue(v: string): boolean
	return string.sub(v, 1, 1) == "-"
end

local function durColor(k: number): Color3
	return if k <= 0.1 then Color3.fromHex("#c53746") elseif k <= 0.33 then Color3.fromHex("#d19034") else Color3.fromHex("#5098b9")
end

-- ------------------------------------------------------------------ item display (ItemDisplay)
-- drop-shadow(0 0 1.5 qc) twice: a soft halo about 2 px wide, as 8 offset copies
local GLOW_OFFS = {}
for k = 0, 7 do
	local a = k * math.pi / 4
	table.insert(GLOW_OFFS, Vector2.new(math.cos(a), math.sin(a)) * 2.2)
end

--- the icon (inset `inset`) with its quality glow / q0 shadow, then the attachment dots, the wishlist mark and the
--- durability / count / name stack (bottom right)
local function display(slot: GuiObject, inst: InstV, src: string, inset: number)
	local d = def(inst.id) or {}
	local q = math.clamp(d.q or 0, 0, 6)
	local box = frame(slot, UDim2.fromOffset(inset, inset), UDim2.new(1, -2 * inset, 1, -2 * inset))
	box.Name = "IcoBox"
	box.ZIndex = slot.ZIndex + 1
	local under = frame(box, UDim2.new(), UDim2.fromScale(1, 1))
	under.ZIndex = box.ZIndex
	if q == 0 then
		Icon.underlay(under, inst.id, BLACK, { Vector2.new(5.92, 5.38) }, 0.722)
	else
		Icon.underlay(under, inst.id, Color3.fromHex(QUALITY_GLOW[q]), GLOW_OFFS, 0.55)
	end
	local ico = new("ImageLabel", { Name = "Ico", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = box.ZIndex + 1 }, box)
	Icon.apply(ico, inst.id)
	if ico:FindFirstChild("Render") then
		(ico:FindFirstChild("Render") :: ViewportFrame).ZIndex = ico.ZIndex
	end
	-- attachment dots: a 12 px black pill per gun slot, filled = a 6 px white dot
	local slots = if d.fire then Inv.gunSlots(inst.id) else {}
	if #slots > 0 then
		local row = frame(slot, UDim2.new(), UDim2.fromOffset(14 * #slots, 12))
		row.ZIndex = slot.ZIndex + 3
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 2) }, row)
		for _, s in slots do
			local dot = frame(row, UDim2.new(), UDim2.fromOffset(12, 12), BLACK, 1, 6)
			dot.ZIndex = row.ZIndex
			stroke(dot, 1, WHITE, 0.5)
			if inst.att and inst.att[s.key] then
				local f = frame(dot, UDim2.fromOffset(3, 3), UDim2.fromOffset(6, 6), WHITE, 1, 3)
				f.ZIndex = row.ZIndex + 1
			end
		end
	end
	if state and table.find(state.wish, inst.id) and src ~= "mod" then
		local h = glyph(slot, "heart", UDim2.new(1, -24, 0, 0), 24, RED)
		h.ZIndex = slot.ZIndex + 3
	end
	-- bottom-right stack
	local br = frame(slot, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0))
	br.AnchorPoint = Vector2.new(1, 1)
	br.AutomaticSize = Enum.AutomaticSize.XY
	br.ZIndex = slot.ZIndex + 3
	new("UIListLayout", { FillDirection = Enum.FillDirection.Vertical, HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }, br)
	local dMax = Inv.maxDurability(inst.id)
	local k: number? = nil
	if dMax > 0 and (d.gear and d.gear.dur or inst.dur ~= nil) then
		k = (inst.dur or dMax) / dMax
	elseif d.use and d.use.uses then
		k = (inst.uses or d.use.uses) / d.use.uses
	end
	if k then
		local kk = math.clamp(k, 0, 1)
		local bar = frame(br, UDim2.new(), UDim2.fromOffset(40, 12), Color3.fromHex("#414141"), 1, 6)
		bar.LayoutOrder = 1
		bar.ZIndex = br.ZIndex
		local fill = frame(bar, UDim2.fromOffset(4, 4), UDim2.fromOffset(32 * kk, 4), durColor(kk), 1, 2)
		fill.ZIndex = br.ZIndex + 1
		if (inst.loss or 0) > 0 then
			local lost = frame(bar, UDim2.new(1, -4, 0, 4), UDim2.fromOffset(32 * math.min(1, inst.loss or 0), 4), Color3.fromHex("#d04f6d"), 1, 2)
			lost.AnchorPoint = Vector2.new(1, 0)
			lost.ZIndex = br.ZIndex + 1
		end
	end
	if (d.maxStack or 1) > 1 or inst.n > 1 then
		local ct = frame(br, UDim2.new(), UDim2.fromOffset(0, 17.5), Color3.fromHex("#585f66"), 1, 9)
		ct.AutomaticSize = Enum.AutomaticSize.X
		ct.LayoutOrder = 2
		ct.ZIndex = br.ZIndex
		new("UIPadding", { PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5) }, ct)
		label(ct, tostring(inst.n), 16, { FontFace = FONT_B, TextColor3 = CREAM, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, ZIndex = br.ZIndex + 1 })
	end
	local nm = frame(br, UDim2.new(), UDim2.fromOffset(0, 19.5), BLACK, 0.749, 4)
	nm.AutomaticSize = Enum.AutomaticSize.X
	nm.LayoutOrder = 3
	nm.ZIndex = br.ZIndex
	nm.ClipsDescendants = true
	new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, nm)
	new("UISizeConstraint", { MaxSize = Vector2.new(112, 19.5) }, nm)
	label(nm, d.name or inst.id, 16, { Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, ZIndex = br.ZIndex + 1, TextTruncate = Enum.TextTruncate.AtEnd })
end

-- every interactive cell: hover / press / right click (the drag and click logic lives in the input handlers below)
local function cellButton(parent: Instance, ref: Ref, pos: UDim2, size: UDim2, empty: boolean): TextButton
	local b = new("TextButton", { Name = "Slot", Text = "", AutoButtonColor = false, Position = pos, Size = size,
		BackgroundColor3 = BLACK, BackgroundTransparency = if empty then 0.8 else 0.8, BorderSizePixel = 0 }, parent)
	corner(b, 16)
	b:SetAttribute("Src", ref.src)
	b:SetAttribute("I", ref.i)
	table.insert(cells, { btn = b, ref = ref })
	b.MouseEnter:Connect(function()
		hover = ref
		Inventory.renderTip()
	end)
	b.MouseLeave:Connect(function()
		if not rendering and sameRef(hover, ref) then
			hover = nil
			Inventory.renderTip()
		end
	end)
	b.MouseButton1Down:Connect(function()
		-- a press arms the drag (6 px makes it one) and the click; an empty cell only ever clicks
		drag = { ref = ref, start = UserInputService:GetMouseLocation(), moved = false, ghost = nil }
	end)
	b.MouseButton1Up:Connect(function()
		-- the release resolves on the cell under the pointer: a click (same cell, no drag) or a drop
		if drag then
			Inventory.endDrag(ref)
		end
	end)
	b.MouseButton2Click:Connect(function()
		Inventory.context(ref, b)
	end)
	return b
end

--- InventoryEntry (120 cell, item display inset 4)
local function entry(parent: Instance, src: string, i: number, inst: InstV?, opts: { unrev: boolean?, searching: boolean? }?)
	local ent = frame(parent, UDim2.new(), UDim2.fromOffset(120, 120))
	ent.LayoutOrder = i
	local ref = { src = src, i = tostring(i) }
	if opts and opts.unrev then
		local s = frame(ent, UDim2.fromOffset(4, 4), UDim2.fromOffset(112, 112), BLACK, 0.2, 16)
		stroke(s, 2, WHITE, 0.298)
		stripesInto(s, 14, Color3.fromHex("#666666"), 0.749, Color3.fromHex("#666666"), 0.45, 16)
		if opts.searching then
			local mag = glyph(s, "magnifier", UDim2.new(0.5, -20, 0.5, -28), 40)
			mag.ZIndex = s.ZIndex + 2
			table.insert(spinners, mag)
		end
		return
	end
	local b = cellButton(ent, ref, UDim2.fromOffset(4, 4), UDim2.fromOffset(112, 112), inst == nil)
	stroke(b, 2, WHITE, 0.298)
	if not inst then
		return
	end
	local locked = src == "bag" and state and table.find(state.locks, i) ~= nil
	local bound = src == "bag" and state and table.find(state.hotbar, inst.id) ~= nil
	if bound then
		local ring = frame(b, UDim2.fromOffset(2, 2), UDim2.new(1, -4, 1, -4), nil, nil, 14)
		stroke(ring, 2, WHITE, 0.494)
	end
	local dMax = Inv.maxDurability(inst.id)
	if dMax > 0 and inst.dur ~= nil and inst.dur <= 0 then
		local dz = frame(b, UDim2.new(), UDim2.fromScale(1, 1), Color3.new(1, 0, 0), 0.2, 16)
		dz.ZIndex = b.ZIndex + 4
	end
	display(b, inst, src, 12)
	if sameRef(sel, ref) then
		local s = frame(b, UDim2.new(), UDim2.fromScale(1, 1), nil, nil, 16)
		s.ZIndex = b.ZIndex + 6
		stroke(s, 3, ORANGE)
	end
	if locked then
		local l = glyph(ent, "lock", UDim2.new(0, 0, 1, -24), 24)
		l.ZIndex = b.ZIndex + 7
	end
	if drag and drag.moved and sameRef(drag.ref, ref) then
		b.BackgroundTransparency = 0.93
		for _, c in b:GetDescendants() do
			if c:IsA("GuiObject") then
				c.Visible = false
			end
		end
	end
	passThrough(ent)
end

--- SlotDisplay: the container (BG + the slot's faint icon) and the label under it
local function slotDisplay(parent: Instance, src: string, i: string, inst: InstV?, labelText: string, w: number, ch: number, lh: number, ghostId: string?)
	local sd = frame(parent, UDim2.new(), UDim2.fromOffset(w, ch + 2 + lh))
	local c = frame(sd, UDim2.new(), UDim2.fromOffset(w, ch), BLACK, 0.2, 16)
	local ref = { src = src, i = i }
	if inst then
		local b = cellButton(c, ref, UDim2.new(), UDim2.fromScale(1, 1), false)
		stroke(b, 2, WHITE, 0.298)
		display(b, inst, src, 8)
		if sameRef(sel, ref) then
			local s = frame(b, UDim2.new(), UDim2.fromScale(1, 1), nil, nil, 16)
			s.ZIndex = b.ZIndex + 6
			stroke(s, 3, ORANGE)
		end
		if drag and drag.moved and sameRef(drag.ref, ref) then
			for _, x in b:GetDescendants() do
				if x:IsA("GuiObject") then
					x.Visible = false
				end
			end
		end
	else
		local g = new("ImageLabel", { BackgroundTransparency = 1, Position = UDim2.new(0.5, -30, 0.5, -30), Size = UDim2.fromOffset(60, 60),
			ImageColor3 = WHITE, ImageTransparency = 0.8 }, c)
		if ghostId then
			Icon.apply(g, ghostId, true)
			g.ImageColor3 = WHITE
			g.ImageTransparency = 0.8
		else
			Icon.glyph(g, "box")
		end
		local b = cellButton(c, ref, UDim2.new(), UDim2.fromScale(1, 1), true)
		b.BackgroundTransparency = 1
	end
	label(sd, labelText, 20, { FontFace = FONT_B, TextColor3 = CREAM, Position = UDim2.fromOffset(0, ch + 2), Size = UDim2.fromOffset(w, lh),
		TextXAlignment = Enum.TextXAlignment.Center, TextScaled = true })
	new("UITextSizeConstraint", { MinTextSize = 8, MaxTextSize = 20 }, sd:FindFirstChildOfClass("TextLabel") :: Instance)
	passThrough(sd)
	return sd
end

--- striped title bar (Rect16 #000 .537 + RollingStripes #000 .176)
local function tbar(parent: Instance, h: number, pad: number): Frame
	local t = frame(parent, UDim2.new(), UDim2.new(1, 0, 0, h), BLACK, 0.537, 16)
	stripesInto(t, 12, BLACK, 0.176, BLACK, 0, 16)
	local row = frame(t, UDim2.fromOffset(pad, 0), UDim2.new(1, -pad * 2, 1, 0))
	row.Name = "Row"
	row.ZIndex = t.ZIndex + 2
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, row)
	return row
end

local function tbarText(row: Instance, s: string, order: number): TextLabel
	return label(row, s, 24, { FontFace = FONT_B, TextColor3 = WHITE, TextTransparency = 0.498, Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = order, ZIndex = (row :: any).ZIndex })
end

--- Store All / Sort: 150x48 #E1F5FF r12, glow #3AB8FF, text 20 #376F89
local function btn150(parent: Instance, text: string, order: number, onClick: () -> ()): TextButton
	local b = new("TextButton", { Text = text, TextSize = 20, FontFace = FONT_M, TextColor3 = Color3.fromHex("#376f89"),
		BackgroundColor3 = Color3.fromHex("#e1f5ff"), Size = UDim2.fromOffset(150, 48), LayoutOrder = order, AutoButtonColor = true,
		ZIndex = (parent :: any).ZIndex }, parent)
	corner(b, 12)
	stroke(b, 2, Color3.fromHex("#3ab8ff"), 0.6)
	local us = new("UIScale", {}, b)
	b.MouseButton1Down:Connect(function()
		us.Scale = 0.95
	end)
	b.MouseButton1Up:Connect(function()
		us.Scale = 1
	end)
	b.MouseLeave:Connect(function()
		us.Scale = 1
	end)
	b.MouseButton1Click:Connect(onClick)
	return b
end

local function igrid(parent: Instance, cols: number): Frame
	local g = frame(parent, UDim2.new(), UDim2.new(1, 0, 0, 0))
	g.AutomaticSize = Enum.AutomaticSize.Y
	new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, g)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(120, 120), CellPadding = UDim2.fromOffset(0, 0), FillDirectionMaxCells = cols,
		HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, g)
	return g
end

-- ------------------------------------------------------------------ render
local TAB_GLYPH = { { "inventory", "bag" }, { "stats", "person" }, { "quests", "quest" }, { "map", "map" }, { "keys", "key" }, { "notes", "notebook" } }
local function weightHudColor(r: number): Color3
	return if r > 1 then Color3.fromHex("#ff1216") elseif r > 0.75 then Color3.fromHex("#ff6f39") elseif r <= 0.25 then Color3.fromHex("#79d6ff") else WHITE
end

local function renderChrome(parent: Frame, W: number)
	-- Top / Bottom shades (Gradient128 #000 .627, 400 tall, 10 past the edge)
	for _, top in { true, false } do
		local sh = frame(parent, UDim2.fromOffset(0, if top then -10 else 1440 - 390), UDim2.fromOffset(W, 400), BLACK, 0.627)
		new("UIGradient", { Rotation = if top then 90 else -90, Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.2, 0.255), NumberSequenceKeypoint.new(0.4, 0.57),
			NumberSequenceKeypoint.new(0.6, 0.82), NumberSequenceKeypoint.new(0.8, 0.957), NumberSequenceKeypoint.new(1, 1) }) }, sh)
	end
	-- ViewButtons: 80 buttons, gap 40, centred at the top; the BG pill 120 wider (#000 .518); the light line 24 up
	local n = #TAB_GLYPH
	local w = n * 80 + (n - 1) * 40
	local nav = frame(parent, UDim2.fromOffset((W - w) / 2, 0), UDim2.fromOffset(w, 128))
	nav.ZIndex = 5
	nav.Active = true
	local bg = frame(nav, UDim2.fromOffset(-60, 0), UDim2.new(1, 120, 1, 0), BLACK, 0.518, 64)
	bg.ZIndex = 5
	local line = frame(nav, UDim2.new(0, -128, 1, -26), UDim2.new(1, 256, 0, 2), WHITE, 0.518, 1)
	line.ZIndex = 6
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.5),
		NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(0.7, 0.5), NumberSequenceKeypoint.new(1, 1) }) }, line)
	for k, t in TAB_GLYPH do
		local b = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = UDim2.fromOffset((k - 1) * 120, 24),
			Size = UDim2.fromOffset(80, 80), ZIndex = 7 }, nav)
		local on = t[1] == "inventory"
		local s = frame(b, UDim2.new(), UDim2.fromScale(1, 1), Color3.fromHex("#61caf9"), if on then 1 else 0, 40)
		s.ZIndex = 7
		local hv = frame(b, UDim2.new(), UDim2.fromScale(1, 1), WHITE, 0, 40)
		hv.ZIndex = 7
		b.MouseEnter:Connect(function()
			hv.BackgroundTransparency = 0.898
		end)
		b.MouseLeave:Connect(function()
			hv.BackgroundTransparency = 1
		end)
		local ic = glyph(b, t[2], UDim2.fromOffset(10, 10), 60)
		ic.ZIndex = 8
		if on then
			new("UIScale", { Scale = 0.9 }, ic)
			-- BackpackButton WeightBar: 80x15 pill, fill inset 5, the kg below in Orbitron 19
			local r = if state and state.carry > 0 then state.weight / state.carry else 0
			local wb = frame(b, UDim2.fromOffset(0, 70), UDim2.fromOffset(80, 15), BLACK, 0.588, 7.5)
			wb.ZIndex = 8
			local fi = frame(wb, UDim2.fromOffset(5, 5), UDim2.fromOffset(70 * math.min(1, r), 5), weightHudColor(r), 1, 2.5)
			fi.ZIndex = 9
			local wt = label(b, string.format("%s/%skg", f1(state and state.weight or 0), f1(state and state.carry or 0)), 19,
				{ FontFace = FONT_NUM, Position = UDim2.fromOffset(-28, 85), Size = UDim2.fromOffset(136, 24), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 8 })
			wt.TextSize = 15
		end
		b.MouseButton1Click:Connect(function()
			if t[1] == "map" then
				Inventory.toggle(false)
				local ok, MapUI = pcall(require, script.Parent:FindFirstChild("MapUI"))
				if ok and MapUI and MapUI.toggle then
					MapUI.toggle(true)
				end
			elseif t[1] == "notes" then
				Inventory.toggle(false)
			end
		end)
	end
end

local function renderLeft(parent: Frame)
	local p = state
	-- EquipmentAndInventory: x 80, 640 wide, top 150 to 120 above the bottom
	local eqinv = frame(parent, UDim2.fromOffset(80, 150), UDim2.new(0, 640, 1, -270))
	eqinv.Active = true
	-- wallet: Money / Cash chips (60 tall, pad 16, icon 60 + amount 36), right aligned in the 74 title
	local title = frame(eqinv, UDim2.fromOffset(5, 0), UDim2.fromOffset(630, 74))
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, title)
	for k, chip in { { "coin", p.money }, { "note", p.cash } } do
		local c = panel(title, UDim2.new(), UDim2.fromOffset(0, 60), MONEY, 16)
		c.AutomaticSize = Enum.AutomaticSize.X
		c.LayoutOrder = k
		new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, c)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 4) }, c)
		glyph(c, chip[1], UDim2.new(), 60)
		label(c, commas(chip[2]), 36,
			{ Size = UDim2.fromOffset(0, 60), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2 })
	end
	-- Content: x+5 from 84 below the top, pad 8, column
	local content = panel(eqinv, UDim2.fromOffset(5, 84), UDim2.new(0, 640, 1, -84), NAVY, 16)
	new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, content)
	local eqbar = frame(content, UDim2.new(), UDim2.new(1, 0, 0, 39.3))
	tbarText(tbar(eqbar, 39.3, 20), "Equipment", 1)
	-- equipment grid: 5 x (90 x 120), spacing 25 x 8, pad T16 B4, centred
	local eg = frame(content, UDim2.fromOffset(0, 39.3), UDim2.new(1, 0, 0, 16 + 120 * 2 + 8 + 4))
	new("UIPadding", { PaddingTop = UDim.new(0, 16), PaddingBottom = UDim.new(0, 4) }, eg)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(90, 120), CellPadding = UDim2.fromOffset(25, 8), FillDirectionMaxCells = 5,
		HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, eg)
	for k, s in Inv.EQUIP_SLOTS do
		local sd = slotDisplay(eg, "eq", s, p.eq[s], Inv.SLOT_LABEL[s], 90, 86.5, 31.5, Inv.SLOT_GHOST[s])
		sd.LayoutOrder = k
	end
	-- the items scroll view (fills the rest)
	local top = 39.3 + 16 + 248 + 4
	local isv = new("ScrollingFrame", { Position = UDim2.fromOffset(0, top), Size = UDim2.new(1, 0, 1, -top), BackgroundTransparency = 1,
		BorderSizePixel = 0, ScrollBarThickness = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y }, content)
	corner(isv, 16)
	local vc = frame(isv, UDim2.new(), UDim2.new(1, 0, 0, 0))
	vc.AutomaticSize = Enum.AutomaticSize.Y
	new("UIPadding", { PaddingTop = UDim.new(0, 10) }, vc)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, vc)
	local ib = frame(vc, UDim2.new(), UDim2.new(1, 0, 0, 80))
	ib.LayoutOrder = 1
	local row = tbar(ib, 80, 16)
	tbarText(row, "Items", 1)
	tbarText(row, string.format("(%d/%d)", #p.bag, p.cap), 2)
	local sp = frame(row, UDim2.new(), UDim2.fromOffset(640 - 16 * 2 - 8 - 8 * 3 - 150 - 260, 1))
	sp.LayoutOrder = 3
	btn150(row, "Sort", 4, function()
		op("btn", "sort")
	end)
	local g = igrid(vc, 5)
	g.LayoutOrder = 2
	for i = 0, p.cap - 1 do
		entry(g, "bag", i, at(p.bag, i))
	end
	-- weight bar: 16 under the panel, 340 x 48 grey r16, label 24, the area with 25 / 75 % marks and the kg pill
	local ratio = if p.carry > 0 then p.weight / p.carry else 0
	local wbar = panel(eqinv, UDim2.new(0, 5, 1, 16), UDim2.fromOffset(340, 48), GREY, 16)
	label(wbar, "Weight", 24, { Position = UDim2.fromOffset(16, 0), Size = UDim2.fromOffset(80, 48) }, true)
	local area = frame(wbar, UDim2.fromOffset(104, 8), UDim2.new(1, -112, 1, -16), Color3.fromRGB(87, 87, 87), 0.55, 16)
	local mask = frame(area, UDim2.fromOffset(4, 4), UDim2.new(1, -8, 1, -8), BLACK, 0.588, 12)
	mask.ClipsDescendants = true
	local mainCol = if ratio > 0.75 then RED elseif ratio <= 0.25 then Color3.fromHex("#cced98") else WHITE
	frame(mask, UDim2.new(), UDim2.new(math.min(1.2, ratio), 8 * math.min(1.2, ratio), 1, 0), mainCol, 1, 12)
	for _, m in { { 0.25, ratio > 0.25 }, { 0.75, ratio > 0.75 } } do
		glyph(area, "tri", UDim2.new(m[1], -12, 1, 0), 24, if m[2] then WHITE else Color3.fromRGB(26, 26, 26), if m[2] then 1 else 0.902)
	end
	local pill = frame(area, UDim2.new(1, 16, 0, -5), UDim2.fromOffset(200, 42), BLACK, 1, 21)
	label(pill, string.format("%s/%skg", f1(p.weight), f1(p.carry)), 20, { Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, TextTransparency = 0.412 }, true)
	-- the dog's bag: right of the panel (+8), 158.3 wide, a 120 column and the paw
	local pb = panel(eqinv, UDim2.fromOffset(653, 84), UDim2.fromOffset(158.32, 0), NAVY, 16)
	pb.AutomaticSize = Enum.AutomaticSize.Y
	new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 10), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, pb)
	new("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Center, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, pb)
	local pg = igrid(pb, 1)
	pg.LayoutOrder = 1
	for i = 0, math.max(1, p.pet.cap) - 1 do
		entry(pg, "pet", i, at(p.pet.items, i))
	end
	local paw = glyph(pb, "paw", UDim2.new(), 50)
	paw.LayoutOrder = 2
end

local function renderRight(parent: Frame, W: number)
	local loot = state.loot
	if not loot then
		return
	end
	-- LootTarget: right 80, 640 wide; title 74 (name 50 bold + capacity 24 bold, gap 16)
	local lt = frame(parent, UDim2.fromOffset(W - 80 - 640, 150), UDim2.fromOffset(640, 84))
	lt.Active = true
	local title = frame(lt, UDim2.fromOffset(5, 0), UDim2.fromOffset(630, 74))
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 16) }, title)
	local shown = string.format("(%d/%d)", #loot.items, loot.slots)
	label(title, loot.name, 50, { FontFace = FONT_B, TextColor3 = CREAM, Size = UDim2.fromOffset(0, 74), AutomaticSize = Enum.AutomaticSize.X })
	label(title, shown, 24, { FontFace = FONT_B, TextColor3 = CREAM, Size = UDim2.fromOffset(0, 74), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2 })
	local rows = math.ceil(loot.slots / 5)
	local gridH = 16 + rows * 120 + 10
	local isvH = math.min(980, 80 + gridH)
	local content = panel(lt, UDim2.fromOffset(-5, 84), UDim2.fromOffset(640, isvH + 16), NAVY, 16)
	new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, content)
	local isv = new("ScrollingFrame", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 0,
		CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y }, content)
	corner(isv, 16)
	local vc = frame(isv, UDim2.new(), UDim2.new(1, 0, 0, 0))
	vc.AutomaticSize = Enum.AutomaticSize.Y
	new("UIPadding", { PaddingTop = UDim.new(0, 10) }, vc)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, vc)
	local ib = frame(vc, UDim2.new(), UDim2.new(1, 0, 0, 80))
	ib.LayoutOrder = 1
	local row = tbar(ib, 80, 16)
	tbarText(row, loot.name, 1)
	tbarText(row, shown, 2)
	local g = igrid(vc, 5)
	g.LayoutOrder = 2
	for i = 0, loot.slots - 1 do
		local it = at(loot.items, i)
		if it and it.hidden then
			entry(g, "loot", i, nil, { unrev = true, searching = i == loot.firstHidden })
		else
			entry(g, "loot", i, it)
		end
	end
end

local function renderHotbarEditor(parent: Frame, W: number)
	-- ShortcutEditor: bottom centre, 176.8 tall, pad 8, gap 8; text 24 bold .502; entries 110 gap 16
	local w = 6 * 110 + 5 * 16 + 16
	local ed = panel(parent, UDim2.fromOffset((W - w) / 2, 1440 - 120 - 176.8), UDim2.fromOffset(w, 176.8), NAVY, 16)
	label(ed, "Drag items into slots to set up your hotbar.", 24, { FontFace = FONT_B, TextTransparency = 0.498, Position = UDim2.fromOffset(0, 8),
		Size = UDim2.new(1, 0, 0, 30), TextXAlignment = Enum.TextXAlignment.Center })
	for k = 0, 5 do
		local id = state.hotbar[k + 1]
		local inst: InstV? = nil
		if id and id ~= "" then
			local n = 0
			for _, s in state.bag do
				if s.id == id then
					n += s.n
				end
			end
			inst = { id = id, n = n }
		end
		local he = frame(ed, UDim2.fromOffset(8 + k * 126, 46), UDim2.fromOffset(110, 110))
		local b = cellButton(he, { src = "hot", i = tostring(k) }, UDim2.new(), UDim2.fromScale(1, 1), inst == nil)
		stroke(b, 2, WHITE, 0.298)
		if inst then
			display(b, inst, "hot", 12)
		end
		local kc = keycap(he, tostring(k + 3), 32, UDim2.new(0.5, 0, 1, 0))
		kc.AnchorPoint = Vector2.new(0.5, 0)
		passThrough(he)
	end
end

local function renderDetails(parent: Frame, W: number)
	local ref = sel
	local inst = ref and instAt(ref)
	if not ref or not inst then
		sel = nil
		return
	end
	local key = ref.src .. "~" .. ref.i
	local d = def(inst.id) or {}
	-- ItemDetails: 750 wide grey panel at top 235, pad 8
	local idet = panel(parent, UDim2.fromOffset((W - 750) / 2, 235), UDim2.fromOffset(750, 0), GREY, 16)
	idet.AutomaticSize = Enum.AutomaticSize.Y
	idet.ZIndex = 20
	new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, idet)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, idet)
	if d.typeID then
		label(idet, "#" .. d.typeID, 16, { FontFace = FONT_B, TextTransparency = 0.498, Position = UDim2.new(0, 16, 0, -32), Size = UDim2.fromOffset(200, 20), ZIndex = 21 })
	end
	label(idet, d.name or inst.id, 40, { FontFace = FONT_B, TextColor3 = CREAM, Size = UDim2.new(1, 0, 0, 48.8), TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, ZIndex = 21 }, false)
	local extra = frame(idet, UDim2.new(), UDim2.new(1, 0, 0, 36))
	extra.LayoutOrder = 2
	extra.ZIndex = 21
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8) }, extra)
	glyph(extra, "anvil", UDim2.new(), 28).ZIndex = 21
	label(extra, f1(d.weight or 0) .. "kg", 20, { Size = UDim2.fromOffset(0, 28), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 21 })
	-- basics: the 160 icon well, durability, description
	local basics = frame(idet, UDim2.new(), UDim2.new(1, 0, 0, 162.3))
	basics.LayoutOrder = 3
	basics.ZIndex = 21
	local well = frame(basics, UDim2.fromOffset(0, 2.3), UDim2.fromOffset(160, 160), BLACK, 0.2, 80)
	well.ZIndex = 21
	local ico = new("ImageLabel", { BackgroundTransparency = 1, Position = UDim2.fromOffset(20, 20), Size = UDim2.fromOffset(120, 120), ZIndex = 22 }, well)
	Icon.apply(ico, inst.id)
	local dMax = Inv.maxDurability(inst.id)
	if dMax > 0 and inst.dur ~= nil then
		local k = math.max(0, inst.dur / dMax)
		local bar = frame(basics, UDim2.fromOffset(160 - 115.9, 162.3 - 32), UDim2.fromOffset(115.9, 32), Color3.fromHex("#414141"), 1, 16)
		bar.ZIndex = 23
		frame(bar, UDim2.fromOffset(6, 6), UDim2.fromOffset(103.9 * math.min(1, k), 20), durColor(k), 1, 10).ZIndex = 24
		label(bar, string.format("%d / %d", math.floor(inst.dur + 0.5), math.floor(dMax * (1 - (inst.loss or 0)) + 0.5)), 18,
			{ FontFace = FONT_B, TextColor3 = CREAM, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 25 })
	end
	label(basics, d.desc or "", 20, { TextColor3 = CREAM, Position = UDim2.fromOffset(176, 2.2), Size = UDim2.new(1, -184, 0, 160.1),
		TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 21 })
	-- the attachment slots (ItemSlotsDisplay, editable: drag a part onto a slot, double click a fitted part to take it)
	local slots = if d.fire then Inv.gunSlots(inst.id) else {}
	if #slots > 0 and ref.src ~= "mod" then
		local sg = frame(idet, UDim2.new(), UDim2.new(1, 0, 0, 16 + 140 + 4))
		sg.LayoutOrder = 4
		sg.ZIndex = 21
		new("UIPadding", { PaddingTop = UDim.new(0, 16), PaddingBottom = UDim.new(0, 4) }, sg)
		new("UIGridLayout", { CellSize = UDim2.fromOffset(100, 140), CellPadding = UDim2.fromOffset(25, 8), FillDirectionMaxCells = 6,
			HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, sg)
		for k, s in slots do
			local part = inst.att and inst.att[s.key]
			local sd = slotDisplay(sg, "mod", key .. "|" .. s.key, if part then { id = part, n = 1 } else nil, Inv.SLOT_NAMES[s.key] or s.key, 100, 101.2, 36.8, nil)
			sd.LayoutOrder = k
		end
		sg.Size = UDim2.new(1, 0, 0, 16 + math.ceil(#slots / 6) * 148 + 4)
	end
	local rows, mods = itemProps(inst)
	for _, m in mods do
		table.insert(rows, m)
	end
	if #rows > 0 then
		local stats = new("ScrollingFrame", { Size = UDim2.new(1, 0, 0, math.min(535, #rows * 48 + 8)), BackgroundTransparency = 1, BorderSizePixel = 0,
			ScrollBarThickness = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, LayoutOrder = 5, ZIndex = 21 }, idet)
		new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, stats)
		new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, stats)
		for k, r in rows do
			local st = frame(stats, UDim2.new(), UDim2.new(1, 0, 0, 40), BLACK, 0.298, 20)
			st.LayoutOrder = k
			st.ZIndex = 21
			label(st, r[1], 27.6, { Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -32 - 32 - 256 - 32, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, ZIndex = 22, TextTruncate = Enum.TextTruncate.AtEnd })
			label(st, r[2], 28, { FontFace = FONT_M, Position = UDim2.new(1, -32 - 256, 0, 0), Size = UDim2.new(0, 256, 1, 0),
				TextColor3 = if negValue(r[2]) then RED else WHITE, ZIndex = 22 })
		end
	end
end

local function W(): number
	local vp = Workspace.CurrentCamera.ViewportSize
	return vp.X / math.max(1e-3, vp.Y / 1440)
end

function Inventory.render()
	if not Inventory.open or not state then
		return
	end
	local t0 = os.clock()
	rendering = true
	table.clear(cells)
	if view then
		Icon.recycle(view)
		-- out of the tree now, destroyed after this frame: the teardown is not paid on the rebuild's frame
		local old = view
		old.Parent = nil
		task.defer(old.Destroy, old)
	end
	rendering = false
	table.clear(spinners)
	local w = W()
	-- built detached and parented once: inserting ~500 instances into the live tree re-runs its layouts per insert
	view = frame(nil :: any, UDim2.new(), UDim2.fromOffset(w, 1440))
	view.Name = "View"
	-- CloseViewOnPointerClick: a click on the empty view area clears the selection, then closes the view
	local bg = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, view)
	bg.MouseButton1Click:Connect(function()
		if drag then
			return
		end
		if sel then
			sel = nil
			Inventory.render()
		else
			Inventory.toggle(false)
		end
	end)
	local parts = {}
	local function mark(name: string)
		table.insert(parts, string.format("%s=%.1f", name, (os.clock() - t0) * 1000))
	end
	mark("clear")
	renderChrome(view, w)
	mark("chrome")
	renderHotbarEditor(view, w)
	mark("hotbar")
	renderLeft(view)
	mark("left")
	renderRight(view, w)
	mark("right")
	renderDetails(view, w)
	mark("details")
	view.Parent = root
	mark("parent")
	Inventory.renderTip()
	mark("tip")
	-- Studio telemetry for the performance check: the rebuild's script time and its viewport count
	if RunService:IsStudio() then
		local vps = 0
		for _, d in view:GetDescendants() do
			if d:IsA("ViewportFrame") then
				vps += 1
			end
		end
		player:SetAttribute("InvRenderMs", math.floor((os.clock() - t0) * 10000 + 0.5) / 10)
		player:SetAttribute("InvViewports", vps)
		player:SetAttribute("InvRenderParts", table.concat(parts, " "))
	end
end

-- ------------------------------------------------------------------ tooltip (ItemHoveringUI)
function Inventory.renderTip()
	for _, c in tip:GetChildren() do
		if not c:IsA("UIListLayout") then
			c:Destroy()
		end
	end
	local inst = hover and instAt(hover)
	if not Inventory.open or not inst or split or (drag and drag.moved) then
		tip.Visible = false
		return
	end
	local d = def(inst.id) or {}
	local rows, mods, effects, caliber = itemProps(inst)
	for _, m in mods do
		table.insert(rows, m)
	end
	if shift then
		table.insert(rows, { "Rarity", ({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Exotic" })[(d.q or 0) + 1] })
		table.insert(rows, { "Sells For", "₿" .. tostring(math.floor((d.value or 0) * inst.n * 0.5)) })
		if inst.n > 1 then
			table.insert(rows, { "Stack Weight", string.format("%.2f kg", (d.weight or 0) * inst.n) })
		end
	end
	-- .tt: 382 wide #000 .949 r16, pad 8 / 16, gap 8, font 18
	local tt = frame(tip, UDim2.new(), UDim2.fromOffset(382, 0), BLACK, 0.949, 16)
	tt.AutomaticSize = Enum.AutomaticSize.Y
	tt.ZIndex = 50
	new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, tt)
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, tt)
	local order = 0
	local function line(text: string, size: number, props: { [string]: any }?): TextLabel
		order += 1
		local p = { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, LayoutOrder = order, ZIndex = 51 }
		for k, v in props or {} do
			p[k] = v
		end
		return label(tt, text, size, p)
	end
	local head = frame(tt, UDim2.new(), UDim2.new(1, 0, 0, 30))
	head.LayoutOrder = 0
	head.ZIndex = 51
	label(head, d.name or inst.id, 24, { FontFace = FONT_B, Size = UDim2.new(1, -60, 1, 0), TextWrapped = true, ZIndex = 51 })
	if d.typeID then
		label(head, "#" .. d.typeID, 12, { FontFace = FONT_B, TextTransparency = 0.498, Position = UDim2.new(1, -60, 0, 0), Size = UDim2.fromOffset(60, 16),
			TextXAlignment = Enum.TextXAlignment.Right, TextYAlignment = Enum.TextYAlignment.Top, ZIndex = 51 })
	end
	line(f1(d.weight or 0) .. " kg", 18)
	if state and table.find(state.wish, inst.id) then
		line("♥ Mark", 16, { TextColor3 = RED })
	end
	if d.desc and d.desc ~= "" then
		line(d.desc, 18)
	end
	if #effects > 0 then
		line("Effects", 24, { FontFace = FONT_B })
		for _, e in effects do
			line("•  " .. e, 18)
		end
	end
	if caliber ~= "" then
		order += 1
		local chip = frame(tt, UDim2.new(), UDim2.new(1, 0, 0, 24), WHITE, 1, 11.3)
		chip.LayoutOrder = order
		chip.ZIndex = 51
		label(chip, caliber, 12, { FontFace = FONT_B, TextColor3 = BLACK, Size = UDim2.fromScale(1, 1), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 52 })
	end
	if #rows > 0 then
		order += 1
		local props = frame(tt, UDim2.new(), UDim2.new(1, 0, 0, 0))
		props.AutomaticSize = Enum.AutomaticSize.Y
		props.LayoutOrder = order
		props.ZIndex = 51
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, props)
		for k, r in rows do
			local rr = frame(props, UDim2.new(), UDim2.new(1, 0, 0, 22))
			rr.LayoutOrder = k
			rr.ZIndex = 51
			label(rr, r[1], 18, { Size = UDim2.fromScale(0.62, 1), ZIndex = 52 })
			label(rr, r[2], 18, { FontFace = FONT_M, Position = UDim2.fromScale(0.62, 0), Size = UDim2.fromScale(0.38, 1),
				TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = if negValue(r[2]) then RED else WHITE, ZIndex = 52 })
		end
	end
	-- key hints: #000 .749 r8, pad 8, gap 8, 16 px
	local tk = frame(tip, UDim2.new(), UDim2.fromOffset(0, 0), BLACK, 0.749, 8)
	tk.AutomaticSize = Enum.AutomaticSize.XY
	tk.LayoutOrder = 2
	tk.ZIndex = 50
	new("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, tk)
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }, tk)
	for k, h in { { "F", "Pick Up / Place" }, { "U", "Use" }, { "X", "Drop" }, { "Ctrl+Drag", "Split" }, { "RMB", "Menu" },
		{ "L", "Lock / Unlock Sort" }, { "N", "Mark" }, { "3..8", "Hotbar" } } do
		local r = frame(tk, UDim2.new(), UDim2.fromOffset(0, if k == 1 then 41 else 25), WHITE, if k == 1 then 0.051 else 0, 8)
		r.AutomaticSize = Enum.AutomaticSize.X
		r.LayoutOrder = k
		r.ZIndex = 51
		new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, r)
		new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder }, r)
		local kc = keycap(r, h[1], 25)
		kc.ZIndex = 52
		label(r, h[2], 16, { FontFace = if k == 1 then FONT_B else FONT, Size = UDim2.fromOffset(0, 25), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = 2, ZIndex = 52 })
	end
	passThrough(tip)
	tip.Visible = true
	Inventory.placeTip()
end

function Inventory.placeTip()
	if not tip.Visible then
		return
	end
	local k = oscale.Scale
	local m = UserInputService:GetMouseLocation() / k
	local sz = tip.AbsoluteSize / k
	local vw = W()
	tip.Position = UDim2.fromOffset(math.clamp(m.X, 0, math.max(0, vw - sz.X)), math.clamp(m.Y, 0, math.max(0, 1440 - sz.Y)))
end

-- ------------------------------------------------------------------ operation menu (ItemOperationMenu)
local MENU_COLOR = { use = "#6ee77b", equip = "#6ee77b", split = "#ffa061", unload = "#ffa061", drop = "#f56262", wish = "#d04f6d" }
function Inventory.context(t: Ref, el: GuiObject)
	local inst = instAt(t)
	if not inst or not state then
		return
	end
	local d = def(inst.id) or {}
	local opts: { { string } } = {}
	if t.src == "bag" and Inv.consumable(inst.id) then
		table.insert(opts, { "use", "Use" })
	end
	if t.src == "bag" and usable(inst.id) then
		table.insert(opts, { "hotbar", "Add to Hotbar" })
	end
	if Inv.isEquippable(inst.id) and t.src ~= "eq" and t.src ~= "hot" and t.src ~= "mod" then
		table.insert(opts, { "equip", "Equip" })
	end
	if t.src == "bag" and inst.n > 1 then
		table.insert(opts, { "split", "Split" })
	end
	if d.fire and (inst.ammo or 0) > 0 and t.src ~= "loot" then
		table.insert(opts, { "unload", "Unload Ammo" })
	end
	if t.src == "bag" then
		table.insert(opts, { "drop", "Drop" })
	end
	if t.src == "bag" and emptyFirst(state.pet.items, state.pet.cap) >= 0 then
		table.insert(opts, { "pet", "Put in Dog's Bag" })
	end
	if t.src ~= "mod" and t.src ~= "hot" then
		table.insert(opts, { "wish", if table.find(state.wish, inst.id) then "Unmark" else "Mark" })
	end
	if #opts == 0 then
		return
	end
	menuFor = t
	for _, c in menu:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	for k, o in opts do
		local b = new("TextButton", { Text = o[2], TextSize = 32, FontFace = FONT_M, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left,
			BackgroundColor3 = Color3.fromHex(MENU_COLOR[o[1]] or "#5bd8f3"), Size = UDim2.fromOffset(0, 64), AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = k, AutoButtonColor = true, ZIndex = 60 }, menu)
		corner(b, 16)
		new("UIPadding", { PaddingLeft = UDim.new(0, 32), PaddingRight = UDim.new(0, 32) }, b)
		new("UIStroke", { Thickness = 2, Color = BLACK, Transparency = 0.7, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, b)
		local us = new("UIScale", {}, b)
		b.MouseButton1Down:Connect(function()
			us.Scale = 0.95
		end)
		b.MouseButton1Click:Connect(function()
			menu.Visible = false
			Inventory.onMenu(o[1])
		end)
	end
	menu.Visible = true
	-- RefreshPosition: pinned to the tile corner nearest the screen centre, opening away from the tile
	task.defer(function()
		local k = oscale.Scale
		local r0 = screenPos(el.AbsolutePosition) / k
		local r1 = screenPos(el.AbsolutePosition + el.AbsoluteSize) / k
		local mw, mh = menu.AbsoluteSize.X / k, menu.AbsoluteSize.Y / k
		local vw = W()
		local cx, cy = vw / 2, 720
		local right = math.abs(r1.X - cx) < math.abs(r0.X - cx)
		local below = math.abs(r1.Y - cy) < math.abs(r0.Y - cy)
		local x = if right then r1.X else r0.X - mw
		local y = if below then r1.Y else r0.Y - mh
		menu.Position = UDim2.fromOffset(math.clamp(x, 0, vw - mw), math.clamp(y, 0, 1440 - mh))
	end)
end

-- ------------------------------------------------------------------ split dialogue (ItemSplitDialogue)
local function renderSplit()
	for _, c in splitDlg:GetChildren() do
		if c:IsA("GuiObject") and c.Name ~= "Dim" then
			c:Destroy()
		end
	end
	local s = split
	splitDlg.Visible = s ~= nil
	if not s then
		return
	end
	local k = if s.max > 1 then (s.n - 1) / (s.max - 1) else 1
	local w = W()
	local box = frame(splitDlg, UDim2.fromOffset((w - 1150) / 2, 720), UDim2.fromOffset(1150, 0), BLACK, 0.633, 16)
	box.AnchorPoint = Vector2.new(0, 0.5)
	box.AutomaticSize = Enum.AutomaticSize.Y
	box.Name = "Box"
	box.ZIndex = 71
	new("UIPadding", { PaddingTop = UDim.new(0, 32), PaddingBottom = UDim.new(0, 32), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, box)
	new("UIListLayout", { HorizontalAlignment = Enum.HorizontalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, box)
	label(box, "Split Items", 36, { FontFace = FONT_M, Size = UDim2.fromOffset(1134, 43.9), TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, ZIndex = 72 })
	local sc = frame(box, UDim2.new(), UDim2.fromOffset(1134, 162.4))
	sc.LayoutOrder = 2
	sc.ZIndex = 72
	label(sc, tostring(s.n), 36, { Size = UDim2.new(1, 0, 0, 44), TextXAlignment = Enum.TextXAlignment.Center, ZIndex = 73 })
	local sl = new("TextButton", { Name = "Slider", Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Position = UDim2.fromOffset(266, 61.2),
		Size = UDim2.fromOffset(602, 40), ZIndex = 73 }, sc)
	frame(sl, UDim2.fromOffset(0, 10), UDim2.new(1, 0, 0, 20), BLACK, 0.502, 10).ZIndex = 73
	frame(sl, UDim2.fromOffset(0, 10), UDim2.new(k, 0, 0, 20), WHITE, 1, 10).ZIndex = 74
	local hd = frame(sl, UDim2.new(k, -50, 0, 0), UDim2.fromOffset(100, 40), WHITE, 1, 20)
	hd.ZIndex = 75
	local function setFrom(x: number)
		local kk = math.clamp((x - sl.AbsolutePosition.X) / math.max(1, sl.AbsoluteSize.X), 0, 1)
		local cur = split
		if cur then
			cur.n = math.clamp(math.floor(1 + kk * (cur.max - 1) + 0.5), 1, cur.max)
			renderSplit()
		end
	end
	sl.MouseButton1Down:Connect(function(x)
		setFrom(x)
		local con: RBXScriptConnection
		local up: RBXScriptConnection
		con = UserInputService.InputChanged:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseMovement then
				setFrom(input.Position.X)
			end
		end)
		up = UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				con:Disconnect()
				up:Disconnect()
			end
		end)
	end)
	local go = new("TextButton", { Text = "Split", TextSize = 24, FontFace = FONT, TextColor3 = Color3.fromHex("#323232"), BackgroundColor3 = WHITE,
		Size = UDim2.fromOffset(734, 80), LayoutOrder = 3, ZIndex = 72 }, box)
	corner(go, 16)
	go.MouseButton1Click:Connect(function()
		local cur = split
		if cur then
			op("split", cur.src, cur.i, cur.n, cur.to)
		end
		split = nil
		renderSplit()
	end)
end

local function openSplit(src: string, i: number, count: number, to: any)
	-- SplitDialogue.Setup: slider 1..count, value round-half-even((count - 1) / 2)
	local half = (count - 1) / 2
	local even
	if math.abs(half % 1) == 0.5 then
		even = if math.floor(half) % 2 == 0 then math.floor(half) else math.ceil(half)
	else
		even = math.floor(half + 0.5)
	end
	split = { src = src, i = i, n = math.clamp(even, 1, count), max = count, to = to }
	tip.Visible = false
	renderSplit()
end

function Inventory.onMenu(m: string)
	local t = menuFor
	if not t then
		return
	end
	if m == "split" then
		local inst = instAt(t)
		if inst and inst.n > 1 and (t.src == "bag" or t.src == "pet") then
			openSplit(t.src, tonumber(t.i) or 0, inst.n, nil)
		end
		return
	end
	op("menu", m, t)
	if m == "use" then
		Inventory.toggle(false)
	end
end

-- ------------------------------------------------------------------ drag, click, keys
local function onClick(t: Ref)
	if t.src == "hot" then
		op("act", t)
		return
	end
	-- Alt + left click on a fitted part unplugs it
	if t.src == "mod" and (UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt)) then
		op("unplug", t)
		if sel and sel.src == "mod" then
			sel = nil
		end
		return
	end
	-- ItemDisplay.OnPointerClick: within 0.3 s of the previous click on it -> the double-click action; else select it /
	-- clear the selection when it was already selected
	local key = t.src .. ":" .. t.i
	local now = os.clock()
	if lastClick and lastClick.key == key and now - lastClick.t <= DOUBLE_CLICK then
		lastClick = nil
		op("act", t)
		return
	end
	lastClick = { key = key, t = now }
	if not instAt(t) then
		return
	end
	sel = if sel and sameRef(sel, t) then nil else t
	Inventory.render()
end

--- the pointer released: over cell `to` (nil = no cell)
local function endDrag(to: Ref?)
	local d = drag
	drag = nil
	if not d then
		return
	end
	if d.ghost then
		d.ghost:Destroy()
	end
	if not d.moved then
		-- a click: pointer down and up on the same cell
		if to and sameRef(to, d.ref) then
			onClick(d.ref)
		end
		return
	end
	if to and not sameRef(to, d.ref) then
		local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		local cellSrc = to.src == "bag" or to.src == "pet" or to.src == "loot"
		if ctrl and cellSrc then
			-- Ctrl: SplitDialogue onto this index when it is empty, else "Target Location Occupied"
			local item = instAt(d.ref)
			if instAt(to) then
				require(script.Parent.Hud).toast("Target Location Occupied", "bad")
			elseif item and item.n > 1 and (d.ref.src == "bag" or d.ref.src == "pet") and (to.src == "bag" or to.src == "pet") then
				openSplit(d.ref.src, tonumber(d.ref.i) or 0, item.n, { src = to.src, pos = tonumber(to.i) or 0 })
			end
		else
			op("drop", d.ref, to)
		end
	end
	Inventory.render()
end
Inventory.endDrag = endDrag

local function startGhost(d: any)
	local inst = instAt(d.ref)
	if not inst then
		drag = nil
		return
	end
	d.moved = true
	-- ItemDraggingUI: the item display (no BG / frame) at the pointer, 100 square, alpha .5
	local g = new("CanvasGroup", { Name = "Ghost", BackgroundTransparency = 1, Size = UDim2.fromOffset(100, 100), AnchorPoint = Vector2.new(0.5, 0.5),
		GroupTransparency = 0.5, ZIndex = 80, Interactable = false }, oroot)
	local ico = new("ImageLabel", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 81, Interactable = false }, g)
	Icon.apply(ico, inst.id)
	d.ghost = g
	tip.Visible = false
	Inventory.render()
end

local function onKey(input: InputObject, down: boolean)
	if not Inventory.open then
		return
	end
	local kc = input.KeyCode
	if kc == Enum.KeyCode.LeftShift or kc == Enum.KeyCode.RightShift then
		if shift ~= down then
			shift = down
			Inventory.renderTip()
		end
	end
	if not down then
		return
	end
	if split then
		if kc == Enum.KeyCode.Escape then
			split = nil
			renderSplit()
		end
		return
	end
	local h = hover
	if not h or not state then
		return
	end
	if kc == Enum.KeyCode.F then
		op("act", h)
	elseif kc == Enum.KeyCode.U and h.src == "bag" then
		-- U: use the hovered item (closes the inventory, like the source)
		local inst = instAt(h)
		if inst and Inv.consumable(inst.id) then
			Net.event("UseItem"):FireServer(inst.id)
			Inventory.toggle(false)
		end
	elseif h.src == "bag" and kc.Value >= Enum.KeyCode.Three.Value and kc.Value <= Enum.KeyCode.Eight.Value then
		local inst = instAt(h)
		if inst and usable(inst.id) then
			op("hot", kc.Value - Enum.KeyCode.Three.Value, h)
		end
	elseif kc == Enum.KeyCode.L and h.src == "bag" then
		op("lock", h)
	elseif kc == Enum.KeyCode.N then
		op("wish", h)
	elseif kc == Enum.KeyCode.X and h.src == "bag" then
		op("dropx", h)
	end
end

-- ------------------------------------------------------------------ open / close
function Inventory.toggle(on: boolean?)
	local was = Inventory.open
	Inventory.open = if on == nil then not Inventory.open else on
	if Inventory.open == was then
		if Inventory.open then
			Inventory.render()
		end
		return
	end
	gui.Enabled = Inventory.open
	overlay.Enabled = Inventory.open
	PC.invOpen = Inventory.open
	UserInputService.MouseIconEnabled = Inventory.open
	op("view", Inventory.open)
	if not Inventory.open then
		sel = nil
		hover = nil
		split = nil
		menu.Visible = false
		tip.Visible = false
		renderSplit()
		if drag and drag.ghost then
			drag.ghost:Destroy()
		end
		drag = nil
		-- closing the view closes the container (World.openLoot = null)
		if state and state.loot then
			Net.event("InteractCancel"):FireServer()
		end
	else
		Inventory.render()
	end
end

local function fitScale()
	local vp = Workspace.CurrentCamera.ViewportSize
	local k = vp.Y / 1440
	scale.Scale = k
	oscale.Scale = k
	root.Size = UDim2.fromOffset(vp.X / k, 1440)
	oroot.Size = UDim2.fromOffset(vp.X / k, 1440)
	if Inventory.open then
		Inventory.render()
	end
end

function Inventory.start()
	local pg = player:WaitForChild("PlayerGui")
	gui = new("ScreenGui", { Name = "Inventory", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5, Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, pg)
	root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromOffset(2560, 1440) }, gui)
	scale = new("UIScale", {}, root)
	overlay = new("ScreenGui", { Name = "InventoryOverlay", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 6, Enabled = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, pg)
	oroot = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromOffset(2560, 1440) }, overlay)
	oscale = new("UIScale", {}, oroot)
	tip = new("Frame", { Name = "Tooltip", BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Visible = false, ZIndex = 50, Interactable = false }, oroot)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = Enum.VerticalAlignment.Top }, tip)
	menu = new("Frame", { Name = "Menu", BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Visible = false, ZIndex = 60 }, oroot)
	new("UIPadding", { PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4), PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, menu)
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, menu)
	splitDlg = new("Frame", { Name = "Split", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 70 }, oroot)
	local dim = new("TextButton", { Name = "Dim", Text = "", AutoButtonColor = false, BackgroundColor3 = BLACK, BackgroundTransparency = 0.251,
		Size = UDim2.fromScale(1, 1), ZIndex = 70 }, splitDlg)
	dim.MouseButton1Click:Connect(function()
		split = nil
		renderSplit()
	end)
	fitScale()
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fitScale)

	local lastLoot: string? = nil
	local lastHidden = 0
	Net.event("Inv").OnClientEvent:Connect(function(s: any)
		-- World.updateLoot: audio 'pickup' as each searched item is revealed
		local hidden = 0
		if s and s.loot then
			for _, it in s.loot.items do
				if it.hidden then
					hidden += 1
				end
			end
			if s.loot.id == lastLoot and hidden < lastHidden then
				require(script.Parent.Sfx).play("pickup")
			end
		end
		lastLoot = s and s.loot and s.loot.id or nil
		lastHidden = hidden
		state = s
		if not s then
			Inventory.toggle(false)
			return
		end
		if s.open and not Inventory.open then
			Inventory.toggle(true)
		elseif Inventory.open then
			Inventory.render()
		end
	end)

	-- Tab is the Roblox player list's key: the raid hides the core list so Tab opens the backpack like the web game (I is
	-- the web's quest log, not the backpack)
	pcall(function()
		game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
	end)
	game:GetService("ContextActionService"):BindActionAtPriority("BlockovInventory", function(_, st)
		if st == Enum.UserInputState.Begin then
			Inventory.toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, 3000, Enum.KeyCode.Tab)
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Escape and Inventory.open and not split then
			Inventory.toggle(false)
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.MouseButton2 then
			-- a press anywhere but the menu closes it
			if menu.Visible then
				local m = UserInputService:GetMouseLocation()
				local a0, a1 = screenPos(menu.AbsolutePosition), screenPos(menu.AbsolutePosition + menu.AbsoluteSize)
				if m.X < a0.X or m.X > a1.X or m.Y < a0.Y or m.Y > a1.Y then
					menu.Visible = false
				end
			end
		end
		-- typing in chat / a TextBox is not a hotkey (processed)
		if input.UserInputType == Enum.UserInputType.Keyboard and not processed then
			onKey(input, true)
		end
	end)
	-- focus lost mid-drag: drop nothing, clear the ghost; Shift may never report its release
	UserInputService.WindowFocusReleased:Connect(function()
		if drag and drag.ghost then
			drag.ghost:Destroy()
		end
		drag = nil
		if shift then
			shift = false
			Inventory.renderTip()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			-- released outside every cell: the cells' MouseButton1Up runs first when there is one
			local d = drag
			if d then
				local m = UserInputService:GetMouseLocation() - game:GetService("GuiService"):GetGuiInset()
				task.delay(0.05, function()
					if drag == d then
						endDrag(cellAt(m))
					end
				end)
			end
		elseif input.UserInputType == Enum.UserInputType.Keyboard then
			onKey(input, false)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement or not Inventory.open then
			return
		end
		local d = drag
		if d then
			local m = UserInputService:GetMouseLocation()
			if not d.moved and (m - d.start).Magnitude > 6 then
				startGhost(d)
			end
			if d.ghost then
				d.ghost.Position = UDim2.fromOffset(m.X / oscale.Scale, m.Y / oscale.Scale)
			end
		end
		Inventory.placeTip()
	end)
	-- the search magnifier spins at 80 rpm
	RunService.RenderStepped:Connect(function(dt)
		if not Inventory.open or not view then
			return
		end
		for _, d in spinners do
			d.Rotation = (d.Rotation + dt * 480) % 360
		end
	end)
	local _ = hoverAt
	local __ = menuFor
end

return Inventory
