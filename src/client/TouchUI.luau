--!strict
-- Touch controls for the web game's keyboard + mouse actions (Controls.luau owns the action map):
-- - fingers: one on the left half drives a floating move stick, one on the right half a floating aim stick that fires
--   pushed past half (a quick tap fires once at the current aim); a finger that starts on a button never moves a stick
-- - right cluster (above the HUD row): Roll (Space), Reload (R), Aim toggle (RMB), Interact (F, held; its label is the
--   selected option, the arrows step through several); left: Run latch (Shift)
-- - top right: Backpack (Tab), Map (M), More (the quick menu: night vision, whistle, holster, top-down view, photo mode,
--   controls); the HUD's weapons, hotbar, ammo type and Cancel rows are tappable (Hud.luau)
-- - photo mode keeps the sticks (move / look) and shows Capture, Up, Down, Hide UI and Exit
-- Laid out on the 2560 x 1440 reference canvas inside the device safe area; shown only while touch is the input.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")

local Controls = require(script.Parent.Controls)

local player = Players.LocalPlayer
local TouchUI = {}

local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold)
local WHITE = Color3.new(1, 1, 1)
local INK = Color3.new(0, 0, 0)
local ON = Color3.fromRGB(75, 162, 212)
local STICK_R = 130 -- reference px

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

local gui: ScreenGui
local root: Frame
local scale: UIScale
local sticksGui: ScreenGui
local sroot: Frame
local sscale: UIScale
local play: Frame -- gameplay buttons
local photo: Frame -- photo mode buttons
local interactBtn: TextButton
local cycleBtn: TextButton
local adsBtn: TextButton
local runBtn: TextButton
local quick: Frame
local quickFirst: GuiObject? = nil

--- a round (or pill) touch button at an anchor point of `parent`
local function button(parent: Instance, text: string, anchor: Vector2, pos: UDim2, size: Vector2, textSize: number?): TextButton
	local b = new("TextButton", {
		Text = text, FontFace = FONT, TextSize = textSize or 30, TextColor3 = WHITE, AutoButtonColor = false,
		BackgroundColor3 = INK, BackgroundTransparency = 0.45, AnchorPoint = anchor, Position = pos,
		Size = UDim2.fromOffset(size.X, size.Y), Selectable = false,
	}, parent)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, b)
	new("UIStroke", { Thickness = 3, Color = WHITE, Transparency = 0.55, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
	-- pressed feedback
	b.MouseButton1Down:Connect(function()
		b.BackgroundTransparency = 0.2
	end)
	b.MouseButton1Up:Connect(function()
		b.BackgroundTransparency = 0.45
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundTransparency = 0.45
	end)
	return b
end

--- a button that presses a key while held (began on press, ended on release)
local function holdKey(b: TextButton, kc: Enum.KeyCode)
	local down = false
	b.MouseButton1Down:Connect(function()
		down = true
		Controls.press(kc, true)
	end)
	local function up()
		if down then
			down = false
			Controls.press(kc, false)
		end
	end
	b.MouseButton1Up:Connect(up)
	b.MouseLeave:Connect(up)
end

local function tapKey(b: TextButton, kc: Enum.KeyCode)
	b.Activated:Connect(function()
		Controls.tap(kc)
	end)
end

-- ------------------------------------------------------------------ sticks
type Stick = { base: Frame, knob: Frame, rest: UDim2, key: any, origin: Vector2, t0: number, peak: number }
local function stickVisual(rest: UDim2): Stick
	local base = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = INK, BackgroundTransparency = 0.75,
		Size = UDim2.fromOffset(STICK_R * 2, STICK_R * 2), Interactable = false }, sroot)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, base)
	new("UIStroke", { Thickness = 3, Color = WHITE, Transparency = 0.6 }, base)
	local knob = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = WHITE, BackgroundTransparency = 0.45,
		Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(110, 110), Interactable = false }, base)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, knob)
	return { base = base, knob = knob, rest = rest, key = nil, origin = Vector2.zero, t0 = 0, peak = 0 }
end
local moveStick: Stick
local aimStick: Stick

local function k(): number
	return sscale.Scale
end

--- the stick vector for a finger at `p` (GUI px), the origin following a finger that leaves the ring
local function stickAt(s: Stick, p: Vector2): Vector2
	local r = STICK_R * k()
	local d = p - s.origin
	if d.Magnitude > r then
		s.origin = p - d.Unit * r
		d = p - s.origin
	end
	local local0 = (s.origin - sroot.AbsolutePosition) / k()
	s.base.Position = UDim2.fromOffset(local0.X, local0.Y)
	s.base.BackgroundTransparency = 0.6
	s.knob.Position = UDim2.new(0.5, d.X / k(), 0.5, d.Y / k())
	local v = d / r
	s.peak = math.max(s.peak, v.Magnitude)
	return v
end

local function stickRelease(s: Stick)
	s.key = nil
	s.base.Position = s.rest
	s.base.BackgroundTransparency = 0.75
	s.knob.Position = UDim2.fromScale(0.5, 0.5)
end

local function sticksLive(): boolean
	return Controls.mode == "touch" and (not Controls.blocked or Controls.photo)
end

--- a finger went down / moved / lifted (`key` identifies it: the InputObject, or a fixture id)
function TouchUI.finger(key: any, state: string, p: Vector2, processed: boolean)
	if state == "began" then
		if processed or not sticksLive() then
			return
		end
		local half = sroot.AbsolutePosition.X + sroot.AbsoluteSize.X / 2
		local s = if p.X < half then moveStick else aimStick
		if s.key ~= nil then
			return
		end
		s.key = key
		s.origin = p
		s.t0 = os.clock()
		s.peak = 0
		local v = stickAt(s, p)
		if s == moveStick then
			Controls.setTouchMove(v)
		else
			Controls.setTouchAim(v, true)
		end
	elseif state == "moved" then
		for _, s in { moveStick, aimStick } do
			if s.key == key then
				local v = stickAt(s, p)
				if s == moveStick then
					Controls.setTouchMove(v)
				else
					Controls.setTouchAim(v, true)
				end
			end
		end
	else
		if moveStick.key == key then
			stickRelease(moveStick)
			Controls.setTouchMove(Vector2.zero)
		end
		if aimStick.key == key then
			-- a quick tap that barely moved: one shot at the current aim
			if os.clock() - aimStick.t0 < 0.25 and aimStick.peak < 0.35 and not Controls.blocked then
				Controls.pulseFire()
			end
			stickRelease(aimStick)
			Controls.setTouchAim(Vector2.zero, false)
		end
	end
end

-- ------------------------------------------------------------------ quick menu (touch More, gamepad held View)
local QUICK = {
	{ "Map", Enum.KeyCode.M }, { "Night Vision", Enum.KeyCode.N }, { "Whistle", Enum.KeyCode.F1 },
	{ "Holster", Enum.KeyCode.C }, { "Top-down View", Enum.KeyCode.Y }, { "Photo Mode", Enum.KeyCode.P },
	{ "Controls", Enum.KeyCode.O },
}
local function closeQuick()
	quick.Visible = false
	Controls.quickOpen = false
	if GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(quick) then
		GuiService.SelectedObject = nil
	end
end
local function openQuick()
	quick.Visible = true
	Controls.quickOpen = true
	if Controls.mode == "gamepad" and quickFirst then
		GuiService.SelectedObject = quickFirst
	end
end

local function build()
	local pg = player:WaitForChild("PlayerGui")
	sticksGui = new("ScreenGui", { Name = "TouchSticks", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 3, Enabled = false }, pg)
	sroot = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(2560, 1440), Interactable = false }, sticksGui)
	sscale = new("UIScale", {}, sroot)
	gui = new("ScreenGui", { Name = "TouchControls", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 4, Enabled = false,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, pg)
	root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromOffset(2560, 1440) }, gui)
	scale = new("UIScale", {}, root)

	moveStick = stickVisual(UDim2.new(0, 300, 1, -420))
	aimStick = stickVisual(UDim2.new(1, -300, 1, -420))
	stickRelease(moveStick)
	stickRelease(aimStick)

	play = new("Frame", { Name = "Play", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, root)
	local BR = Vector2.new(0.5, 0.5)
	local roll = button(play, "Roll", BR, UDim2.new(1, -560, 1, -330), Vector2.new(148, 148), 32)
	tapKey(roll, Enum.KeyCode.Space)
	local reload = button(play, "Reload", BR, UDim2.new(1, -620, 1, -530), Vector2.new(120, 120), 26)
	tapKey(reload, Enum.KeyCode.R)
	adsBtn = button(play, "Aim", BR, UDim2.new(1, -470, 1, -690), Vector2.new(112, 112), 28)
	adsBtn.Activated:Connect(function()
		Controls.toggleAds()
	end)
	interactBtn = button(play, "", Vector2.new(1, 0.5), UDim2.new(1, -150, 1, -820), Vector2.new(0, 96), 30)
	interactBtn.AutomaticSize = Enum.AutomaticSize.X
	new("UIPadding", { PaddingLeft = UDim.new(0, 34), PaddingRight = UDim.new(0, 34) }, interactBtn)
	holdKey(interactBtn, Enum.KeyCode.F)
	cycleBtn = button(play, "⇅", BR, UDim2.new(1, -80, 1, -820), Vector2.new(96, 96), 36)
	tapKey(cycleBtn, Enum.KeyCode.Down)
	runBtn = button(play, "Run", BR, UDim2.new(0, 560, 1, -420), Vector2.new(112, 112), 28)
	runBtn.Activated:Connect(function()
		Controls.toggleRun()
	end)
	-- top right: Backpack, Map, More (where the keyboard's Controls hint sits)
	local top = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -25, 0, 90),
		Size = UDim2.fromOffset(0, 104), AutomaticSize = Enum.AutomaticSize.X }, play)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 18), SortOrder = Enum.SortOrder.LayoutOrder }, top)
	for i, spec in { { "Bag", Enum.KeyCode.Tab }, { "Map", Enum.KeyCode.M }, { "•••", nil :: Enum.KeyCode? } } do
		local b = button(top, spec[1], Vector2.zero, UDim2.new(), Vector2.new(104, 104), 28)
		b.LayoutOrder = i
		if spec[2] then
			tapKey(b, spec[2] :: Enum.KeyCode)
		else
			b.Activated:Connect(function()
				if quick.Visible then
					closeQuick()
				else
					openQuick()
				end
			end)
		end
	end

	-- photo mode: the sticks move / look; Capture (Space), Up (E), Down (Q), Hide UI (O), Exit (P)
	photo = new("Frame", { Name = "Photo", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, root)
	local cap = button(photo, "●", BR, UDim2.new(1, -560, 1, -360), Vector2.new(150, 150), 64)
	tapKey(cap, Enum.KeyCode.Space)
	local up = button(photo, "Up", BR, UDim2.new(1, -620, 1, -560), Vector2.new(110, 110), 26)
	holdKey(up, Enum.KeyCode.E)
	local dn = button(photo, "Down", BR, UDim2.new(1, -470, 1, -690), Vector2.new(110, 110), 26)
	holdKey(dn, Enum.KeyCode.Q)
	local ptop = new("Frame", { BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -25, 0, 90),
		Size = UDim2.fromOffset(0, 104), AutomaticSize = Enum.AutomaticSize.X }, photo)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 18), SortOrder = Enum.SortOrder.LayoutOrder }, ptop)
	local hide = button(ptop, "UI", Vector2.zero, UDim2.new(), Vector2.new(104, 104), 28)
	hide.LayoutOrder = 1
	tapKey(hide, Enum.KeyCode.O)
	local exit = button(ptop, "Exit", Vector2.zero, UDim2.new(), Vector2.new(104, 104), 28)
	exit.LayoutOrder = 2
	tapKey(exit, Enum.KeyCode.P)

	-- the quick menu
	quick = new("Frame", { Name = "Quick", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(560, 0),
		AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = INK, BackgroundTransparency = 0.25, Visible = false, ZIndex = 20 }, root)
	new("UICorner", { CornerRadius = UDim.new(0, 24) }, quick)
	new("UIPadding", { PaddingTop = UDim.new(0, 20), PaddingBottom = UDim.new(0, 20), PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 20) }, quick)
	new("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }, quick)
	for i, q in QUICK do
		local b = new("TextButton", { Text = q[1], FontFace = FONT, TextSize = 34, TextColor3 = WHITE, AutoButtonColor = true,
			BackgroundColor3 = Color3.fromRGB(0, 48, 75), BackgroundTransparency = 0.2, Size = UDim2.new(1, 0, 0, 84), LayoutOrder = i,
			ZIndex = 21, Selectable = true }, quick)
		new("UICorner", { CornerRadius = UDim.new(0, 18) }, b)
		b.Activated:Connect(function()
			closeQuick()
			Controls.tap(q[2])
		end)
		if i == 1 then
			quickFirst = b
		end
	end
	local close = new("TextButton", { Text = "Close", FontFace = FONT, TextSize = 30, TextColor3 = WHITE, AutoButtonColor = true,
		BackgroundColor3 = Color3.fromRGB(90, 90, 90), BackgroundTransparency = 0.2, Size = UDim2.new(1, 0, 0, 72), LayoutOrder = 99,
		ZIndex = 21, Selectable = true }, quick)
	new("UICorner", { CornerRadius = UDim.new(0, 18) }, close)
	close.Activated:Connect(closeQuick)
	Controls.setQuickMenu({ open = openQuick, close = closeQuick })
end

local function fit()
	local abs = gui.AbsoluteSize
	if abs.Y <= 0 then
		return
	end
	local kk = abs.Y / 1440
	scale.Scale = kk
	root.Size = UDim2.fromOffset(abs.X / kk, 1440)
	local sabs = sticksGui.AbsoluteSize
	if sabs.Y > 0 then
		local ks = sabs.Y / 1440
		sscale.Scale = ks
		sroot.Size = UDim2.fromOffset(sabs.X / ks, 1440)
	end
end

function TouchUI.start()
	build()
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	sticksGui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	task.defer(fit)
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Touch then
			TouchUI.finger(input, "began", Vector2.new(input.Position.X, input.Position.Y), processed)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			TouchUI.finger(input, "moved", Vector2.new(input.Position.X, input.Position.Y), false)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch then
			TouchUI.finger(input, "ended", Vector2.new(input.Position.X, input.Position.Y), false)
		end
	end)
	RunService.RenderStepped:Connect(function()
		local touchMode = Controls.mode == "touch"
		gui.Enabled = touchMode
		sticksGui.Enabled = touchMode and sticksLive()
		play.Visible = not Controls.blocked
		photo.Visible = Controls.photo
		if not touchMode and quick.Visible and Controls.mode ~= "gamepad" then
			closeQuick()
		end
		-- the quick menu is shared with the gamepad: it needs the GUI even when touch is not the input
		if quick.Visible and not touchMode then
			gui.Enabled = true
			play.Visible = false
			photo.Visible = false
		end
		if Controls.blocked and not Controls.photo then
			-- a view took over: lift every finger off the sticks
			if moveStick.key ~= nil then
				stickRelease(moveStick)
				Controls.setTouchMove(Vector2.zero)
			end
			if aimStick.key ~= nil then
				stickRelease(aimStick)
				Controls.setTouchAim(Vector2.zero, false)
			end
		end
		local label = Controls.prompt
		interactBtn.Visible = label ~= nil
		interactBtn.Text = label or ""
		cycleBtn.Visible = label ~= nil and Controls.promptCount > 1
		adsBtn.BackgroundColor3 = if Controls.touchAds() then ON else INK
		runBtn.BackgroundColor3 = if Controls.runHeld() then ON else INK
	end)
	if RunService:IsStudio() then
		-- Studio fixture (touches cannot be injected): DevTouch = "id,began|moved|ended,x,y" in GUI px
		player:GetAttributeChangedSignal("DevTouch"):Connect(function()
			local v = player:GetAttribute("DevTouch")
			local id, st, x, y = string.match(if typeof(v) == "string" then v else "", "^(%w+),(%a+),([-%d.]+),([-%d.]+)$")
			if id then
				Controls.setMode("touch")
				TouchUI.finger("dev" .. id, st :: string, Vector2.new(tonumber(x) or 0, tonumber(y) or 0), false)
			end
		end)
	end
end

return TouchUI
