--!strict
-- Native gamepad and touch paths for the web game's keyboard + mouse controls (the web build has no others).
-- Every action keeps its keyboard meaning: a gamepad or touch button presses the keyboard key it stands for, and the
-- Controls.onKey listeners run the code the keyboard path runs. Analog input feeds the same movement / aim / trigger
-- state the keys and the mouse do:
-- - move: WASD, the left stick, or the touch move stick (view space: x right, z down)
-- - aim: the mouse, else a virtual cursor at the aim point (right stick / touch aim stick direction, 2.5-8 m out;
--   facing follows the move direction while the aim is idle), in the viewport pixels Combat.cursor uses
-- - trigger: LMB, RT, or the touch aim stick pushed past half (a quick tap fires once); ADS: RMB, LT, the touch Aim toggle;
--   run: Shift held, the left-stick click / touch Run latch (released when movement stops)
-- Gamepad buttons (gameplay): A Space roll, X F interact (hold), Y R reload, B X cancel, RB Right next weapon, RS T ammo
-- type, D-pad up / down the Up / Down keys, D-pad left / right pick a hotbar slot and LB uses it (3-8), View: tap Tab,
-- hold the quick menu (map, night vision, whistle, holster, top-down view, photo mode, controls).
-- The current device follows the last input (hybrid devices switch); views (LootView, map) own their own gamepad keys.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local S = require(Shared.Units).S
local CameraRig = require(script.Parent.CameraRig)

local player = Players.LocalPlayer
local Controls = {}
Controls.mode = "kbm" -- "kbm" | "gamepad" | "touch"
Controls.blocked = false -- a view owns input (PlayerControl sets it every frame)
Controls.padSlot = 1 -- the gamepad's hotbar pick (1-6 = keys 3-8)
Controls.cursor = nil :: Vector2? -- the virtual cursor in viewport pixels; nil while the mouse aims
Controls.prompt = nil :: string? -- the selected interact option (Interact sets it; the touch Interact button shows it)
Controls.promptCount = 0
Controls.quickOpen = false
Controls.photo = false -- photo mode is up (the touch sticks move / look there)

-- ------------------------------------------------------------------ listeners
local modeListeners: { (string) -> () } = {}
function Controls.onMode(fn: (string) -> ())
	table.insert(modeListeners, fn)
end
local devLock: string? = nil -- Studio fixture: DevInputMode pins the device (injected mouse clicks would switch it)
local function setMode(m: string)
	if m == Controls.mode or (devLock and m ~= devLock) then
		return
	end
	Controls.mode = m
	-- Roblox's own touch thumbstick / jump button would sit under ours
	pcall(function()
		GuiService.TouchControlsEnabled = m ~= "touch"
	end)
	for _, fn in modeListeners do
		task.spawn(fn, m)
	end
end
Controls.setMode = setMode

local keyListeners: { (Enum.KeyCode, boolean) -> () } = {}
--- a gamepad / touch press of the keyboard key `kc` (down true = began, false = ended)
function Controls.onKey(fn: (Enum.KeyCode, boolean) -> ())
	table.insert(keyListeners, fn)
end
function Controls.press(kc: Enum.KeyCode, down: boolean)
	for _, fn in keyListeners do
		task.spawn(fn, kc, down)
	end
end
function Controls.tap(kc: Enum.KeyCode)
	Controls.press(kc, true)
	Controls.press(kc, false)
end

-- ------------------------------------------------------------------ analog state
local pad = { move = Vector2.zero, aim = Vector2.zero, fire = false, ads = false }
local touch = { move = Vector2.zero, aim = Vector2.zero, aimOn = false, ads = false }
local runLatch = false
local stillT = 0
local firePulse = 0
local devPad: Vector2? = nil
local devAim: Vector2? = nil

local DEAD = 0.18
local function deadzone(v: Vector2): Vector2
	local m = v.Magnitude
	if m < DEAD then
		return Vector2.zero
	end
	return v.Unit * math.min(1, (m - DEAD) / (1 - DEAD))
end

--- movement in view space (x right, z down), magnitude <= 1
function Controls.move(): Vector2
	if Controls.mode == "gamepad" then
		return Vector2.new(pad.move.X, -pad.move.Y)
	elseif Controls.mode == "touch" then
		return touch.move
	end
	return Vector2.zero
end

--- the aim stick in view space (x right, y down)
function Controls.aimStick(): Vector2
	if Controls.mode == "gamepad" then
		return Vector2.new(pad.aim.X, -pad.aim.Y)
	elseif Controls.mode == "touch" then
		return if touch.aimOn then touch.aim else Vector2.zero
	end
	return Vector2.zero
end

function Controls.fireHeld(): boolean
	if firePulse > 0 then
		return true
	end
	if Controls.mode == "gamepad" then
		return pad.fire
	elseif Controls.mode == "touch" then
		return touch.aimOn and touch.aim.Magnitude > 0.5
	end
	return false
end

function Controls.adsHeld(): boolean
	if Controls.mode == "gamepad" then
		return pad.ads
	elseif Controls.mode == "touch" then
		return touch.ads
	end
	return false
end

function Controls.runHeld(): boolean
	return Controls.mode ~= "kbm" and runLatch
end

function Controls.toggleRun()
	runLatch = not runLatch
	stillT = 0
end
function Controls.toggleAds()
	touch.ads = not touch.ads
end
function Controls.touchAds(): boolean
	return touch.ads
end

-- touch sticks report here (TouchUI owns the fingers)
function Controls.setTouchMove(v: Vector2)
	touch.move = v
end
function Controls.setTouchAim(v: Vector2, on: boolean)
	touch.aim = v
	touch.aimOn = on
end
--- a quick tap on the aim stick: one trigger press
function Controls.pulseFire()
	firePulse = 2
end

-- ------------------------------------------------------------------ virtual cursor
local viewDir = Vector2.new(0, 1) -- last aim direction (view space)
local aimDist = 3

--- per frame, before PlayerControl / Combat read input
function Controls.update(dt: number)
	-- sticks: Gamepad1's state (a held stick sends no more events), or the Studio fixture
	if devPad or devAim then
		pad.move = devPad or Vector2.zero
		pad.aim = devAim or Vector2.zero
	elseif UserInputService:GetGamepadConnected(Enum.UserInputType.Gamepad1) then
		for _, st in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
			if st.KeyCode == Enum.KeyCode.Thumbstick1 then
				pad.move = deadzone(Vector2.new(st.Position.X, st.Position.Y))
			elseif st.KeyCode == Enum.KeyCode.Thumbstick2 then
				pad.aim = deadzone(Vector2.new(st.Position.X, st.Position.Y))
			end
		end
		if Controls.mode ~= "gamepad" and (pad.move.Magnitude > 0 or pad.aim.Magnitude > 0) then
			setMode("gamepad")
		end
	else
		pad.move, pad.aim = Vector2.zero, Vector2.zero
	end
	firePulse = math.max(0, firePulse - 1)
	-- the run latch lets go once the character stops for a moment
	if Controls.move().Magnitude < 0.1 then
		stillT += dt
		if stillT > 0.25 then
			runLatch = false
		end
	else
		stillT = 0
	end

	if Controls.mode == "kbm" then
		Controls.cursor = nil
		return
	end
	local a = Controls.aimStick()
	local m = a.Magnitude
	local goal = 3
	if m > 0.05 then
		viewDir = a.Unit
		goal = 2.5 + 5.5 * math.min(1, m)
	else
		local mv = Controls.move()
		if mv.Magnitude > 0.1 then
			viewDir = mv.Unit
		end
	end
	aimDist += (goal - aimDist) * math.min(1, dt * 10)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local cam = Workspace.CurrentCamera
	if not root or not cam then
		Controls.cursor = nil
		return
	end
	local w = CameraRig.viewToWorld(viewDir.X, viewDir.Y)
	if w.Magnitude > 0 then
		w = w.Unit
	end
	local p = root.Position / S
	local sp = cam:WorldToViewportPoint(Vector3.new(p.X + w.X * aimDist, 0.5, p.Z + w.Y * aimDist) * S)
	Controls.cursor = Vector2.new(sp.X, sp.Y)
end

-- ------------------------------------------------------------------ gamepad buttons
local PAD_KEY: { [Enum.KeyCode]: Enum.KeyCode } = {
	[Enum.KeyCode.ButtonA] = Enum.KeyCode.Space,
	[Enum.KeyCode.ButtonX] = Enum.KeyCode.F,
	[Enum.KeyCode.ButtonY] = Enum.KeyCode.R,
	[Enum.KeyCode.ButtonB] = Enum.KeyCode.X,
	[Enum.KeyCode.ButtonR1] = Enum.KeyCode.Right,
	[Enum.KeyCode.ButtonR3] = Enum.KeyCode.T,
	[Enum.KeyCode.DPadUp] = Enum.KeyCode.Up,
	[Enum.KeyCode.DPadDown] = Enum.KeyCode.Down,
}
Controls.PAD_KEY = PAD_KEY
--- the gamepad button shown for a keyboard key in hints (nil = no single button)
Controls.PAD_FOR = {
	Space = Enum.KeyCode.ButtonA, F = Enum.KeyCode.ButtonX, R = Enum.KeyCode.ButtonY, X = Enum.KeyCode.ButtonB,
	T = Enum.KeyCode.ButtonR3, Tab = Enum.KeyCode.ButtonSelect, ["1"] = Enum.KeyCode.ButtonR1, Shift = Enum.KeyCode.ButtonL3, LMB = Enum.KeyCode.ButtonR2, RMB = Enum.KeyCode.ButtonL2,
	WASD = Enum.KeyCode.Thumbstick1, ["3-8"] = Enum.KeyCode.ButtonL1, O = Enum.KeyCode.ButtonSelect,
} :: { [string]: Enum.KeyCode }

local function isPadKey(kc: Enum.KeyCode): boolean
	local n = kc.Name
	return string.sub(n, 1, 6) == "Button" or string.sub(n, 1, 4) == "DPad" or string.sub(n, 1, 10) == "Thumbstick"
end

local quick: any = nil -- the quick menu (TouchUI builds it; shared with the gamepad's held View)
function Controls.setQuickMenu(q: any)
	quick = q
end

local selectAt = 0
local selectUsed = false
local selectHeld = false
UserInputService.InputBegan:Connect(function(input, processed)
	local kc = input.KeyCode
	local ut = input.UserInputType
	if ut == Enum.UserInputType.Touch then
		setMode("touch")
	elseif isPadKey(kc) or string.sub(ut.Name, 1, 7) == "Gamepad" then
		setMode("gamepad")
	elseif ut == Enum.UserInputType.Keyboard or ut == Enum.UserInputType.MouseButton1 or ut == Enum.UserInputType.MouseButton2 then
		setMode("kbm")
	end
	if not isPadKey(kc) then
		return
	end
	if Controls.quickOpen then
		if kc == Enum.KeyCode.ButtonB or kc == Enum.KeyCode.ButtonSelect then
			quick.close()
		end
		return
	end
	if kc == Enum.KeyCode.ButtonSelect then
		-- View: a tap toggles the backpack, a hold opens the quick menu (gameplay only)
		selectAt = os.clock()
		selectUsed = false
		selectHeld = true
		local at = selectAt
		task.delay(0.4, function()
			if selectAt == at and not selectUsed and selectHeld and not Controls.blocked and quick then
				selectUsed = true
				quick.open()
			end
		end)
		return
	end
	-- a selected GUI button consumed it (menus), or a view owns the pad
	if processed or Controls.blocked then
		return
	end
	if kc == Enum.KeyCode.ButtonR2 then
		pad.fire = true
	elseif kc == Enum.KeyCode.ButtonL2 then
		pad.ads = true
	elseif kc == Enum.KeyCode.ButtonL3 then
		Controls.toggleRun()
	elseif kc == Enum.KeyCode.DPadLeft or kc == Enum.KeyCode.DPadRight then
		Controls.padSlot = (Controls.padSlot - 1 + (if kc == Enum.KeyCode.DPadRight then 1 else -1)) % 6 + 1
	elseif kc == Enum.KeyCode.ButtonL1 then
		Controls.tap(Enum.KeyCode[({ "Three", "Four", "Five", "Six", "Seven", "Eight" })[Controls.padSlot]])
	elseif PAD_KEY[kc] then
		Controls.press(PAD_KEY[kc], true)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	local kc = input.KeyCode
	if kc == Enum.KeyCode.ButtonR2 then
		pad.fire = false
	elseif kc == Enum.KeyCode.ButtonL2 then
		pad.ads = false
	elseif kc == Enum.KeyCode.ButtonSelect then
		selectHeld = false
		if not selectUsed and os.clock() - selectAt < 0.4 then
			selectUsed = true
			Controls.tap(Enum.KeyCode.Tab)
		end
	elseif PAD_KEY[kc] then
		Controls.press(PAD_KEY[kc], false)
	end
end)

UserInputService.InputChanged:Connect(function(input)
	local ut = input.UserInputType
	if ut == Enum.UserInputType.MouseMovement and input.Delta.Magnitude > 2 then
		setMode("kbm")
	elseif ut == Enum.UserInputType.Touch then
		setMode("touch")
	end
end)

-- focus lost: nothing stays held
UserInputService.WindowFocusReleased:Connect(function()
	pad.fire, pad.ads = false, false
	touch.aimOn, touch.move = false, Vector2.zero
end)

function Controls.start()
	-- View is the backpack key; Roblox would use it to toggle GUI selection mode
	pcall(function()
		GuiService.AutoSelectGuiEnabled = false
	end)
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		setMode("touch")
	elseif string.sub(last.Name, 1, 7) == "Gamepad" then
		setMode("gamepad")
	elseif UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		setMode("touch")
	end
	if RunService:IsStudio() then
		-- Studio fixtures (Studio's input tools send gamepad buttons as keys and cannot send touches or stick values):
		-- DevInputMode = "kbm" | "gamepad" | "touch"; DevPad = "lx,ly,rx,ry" (stick values, "" releases)
		player:GetAttributeChangedSignal("DevInputMode"):Connect(function()
			local m = player:GetAttribute("DevInputMode")
			if m == "kbm" or m == "gamepad" or m == "touch" then
				devLock = nil
				setMode(m)
				devLock = m
			else
				devLock = nil
			end
		end)
		player:GetAttributeChangedSignal("DevPad"):Connect(function()
			local v = player:GetAttribute("DevPad")
			local a, b, c, d = string.match(if typeof(v) == "string" then v else "", "^([-%d.]+),([-%d.]+),([-%d.]+),([-%d.]+)$")
			if a then
				devPad = Vector2.new(tonumber(a) or 0, tonumber(b) or 0)
				devAim = Vector2.new(tonumber(c) or 0, tonumber(d) or 0)
				setMode("gamepad")
			else
				devPad, devAim = nil, nil
			end
		end)
	end
end

return Controls
