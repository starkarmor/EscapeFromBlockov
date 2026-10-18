--!strict
-- Photo Mode (web src/game/photoMode.ts; source CameraMode + CameraModeController, the "CameraMode" action map):
-- P toggles it while no view is open; opening the Roblox menu (Esc) leaves it. While it is active the HUD is hidden, the
-- player's input is off and the cursor is locked.
-- - Activate: a free camera at the render camera with its yaw / pitch and FOV.
-- - Move (WASD): forward / right flattened to the ground, Q / E down / up along the world up; x (Shift ? 16 : 4) m/s.
-- - Look (mouse delta): pitch += dy x 4.5 x dt (clamped +-89.9), yaw += dx x 4.5 x dt (degrees).
-- - FOV (wheel): clamp(fov - 1 per notch, 5, 60).
-- - Focus (RMB held): a 100 m ray from the camera puts the focus marker (0.3 m, shrinking over 1 s) 0.2 m back from the hit.
-- - Capture (Space): the screen punch (white .7 -> 0 over 0.3 s), the shutter sound, 0.3 s lock.
-- Gamepad: left stick move, right stick look (90 deg/s), LB / RB down / up, LS fast, D-pad up / down FOV, LT focus,
-- A / RT capture, X hide UI, B leaves. Touch: the move / aim sticks move / look, a pinch sets the FOV, buttons for
-- Capture, Up, Down, Hide UI and Exit (TouchUI).
-- Roblox adaptations: the world cannot be paused in a shared server (the web sets timeScale 0), so only this player's
-- input stops; the photo goes to the player's Roblox captures (CaptureService) instead of a downloaded PNG.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Units = require(ReplicatedStorage:WaitForChild("Shared").Units)
local PC = require(script.Parent.PlayerControl)
local Controls = require(script.Parent.Controls)

local S = Units.S
local player = Players.LocalPlayer
local PhotoMode = {}
PhotoMode.active = false
local padHeld: { [Enum.KeyCode]: boolean } = {} -- gamepad buttons and touch holds while active
local fastLatch = false
local pinchFov = 30

local PHOTO = { moveSpeed = 4, fastMoveSpeed = 16, aimSpeed = 4.5, fovMin = 5, fovMax = 60, focusRay = 100, focusBack = 0.2,
	focusMeshSize = 0.3, focusMeshAppearTime = 1, captureLock = 0.3 }
local ROWS = { { "WASD", "Move" }, { "Q", "Camera Down" }, { "E", "Camera Up" }, { "Wheel", "Zoom" }, { "RMB", "Focal Point" },
	{ "Shift", "Move Faster" }, { "Space", "Take Photo" }, { "K", "Copy Screenshot Path" } }
-- the same list for the gamepad / touch paths
local PAD_ROWS = { { Enum.KeyCode.Thumbstick1, "Move" }, { Enum.KeyCode.Thumbstick2, "Look" }, { Enum.KeyCode.ButtonL1, "Camera Down" },
	{ Enum.KeyCode.ButtonR1, "Camera Up" }, { Enum.KeyCode.DPadUp, "Zoom" }, { Enum.KeyCode.ButtonL2, "Focal Point" },
	{ Enum.KeyCode.ButtonL3, "Move Faster" }, { Enum.KeyCode.ButtonA, "Take Photo" }, { Enum.KeyCode.ButtonX, "Photo Instructions" },
	{ Enum.KeyCode.ButtonB, "Exit" } }
local TOUCH_ROWS = { { "Left stick", "Move" }, { "Right stick", "Look" }, { "Pinch", "Zoom" }, { "Up / Down", "Camera Up / Down" },
	{ "●", "Take Photo" }, { "UI", "Photo Instructions" }, { "Exit", "Leave" } }
local fillRows: () -> () = function() end

local pos = Vector3.zero
local yaw, pitch, fov = 0, 0, 45
local lookX, lookY, wheel = 0, 0, 0
local shooting = false
local focusTimer = 0
local indicator = true
local saved: { cf: CFrame, fov: number }? = nil
local hiddenGuis: { ScreenGui } = {}
local gui: ScreenGui
local ui: Frame
local flash: Frame
local marker: Part

local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Medium)
local FONT_B = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold)

local function build()
	gui = Instance.new("ScreenGui")
	gui.Name = "PhotoMode"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 40
	gui.Enabled = false
	gui.Parent = player:WaitForChild("PlayerGui")
	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui
	local us = Instance.new("UIScale")
	us.Parent = root
	local function fit()
		local vp = Workspace.CurrentCamera.ViewportSize
		us.Scale = vp.Y / 1440
		root.Size = UDim2.fromOffset(vp.X / us.Scale, 1440)
	end
	fit()
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	-- #photo-ui: bottom-left 48, pad 20 / 28, r20, #000 .62, rows of a white key cap (64 min) + the action (28)
	ui = Instance.new("Frame")
	ui.BackgroundColor3 = Color3.new(0, 0, 0)
	ui.BackgroundTransparency = 0.38
	ui.AnchorPoint = Vector2.new(0, 1)
	ui.Position = UDim2.new(0, 48, 1, -48)
	ui.AutomaticSize = Enum.AutomaticSize.XY
	ui.Parent = root
	Instance.new("UICorner", ui).CornerRadius = UDim.new(0, 20)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom, pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 20), UDim.new(0, 20), UDim.new(0, 28), UDim.new(0, 28)
	pad.Parent = ui
	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 8)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = ui
	local function label(parent: Instance, text: string, size: number, font: Font, order: number, color: Color3?, alpha: number?): TextLabel
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Text = text
		t.TextSize = size
		t.FontFace = font
		t.TextColor3 = color or Color3.new(1, 1, 1)
		t.TextTransparency = alpha or 0
		t.AutomaticSize = Enum.AutomaticSize.XY
		t.LayoutOrder = order
		t.Parent = parent
		return t
	end
	label(ui, "Photo Mode", 34, FONT_B, 0)
	local function row(key: any, text: string, order: number, small: boolean?)
		local r = Instance.new("Frame")
		r.Name = "Row"
		r.BackgroundTransparency = 1
		r.AutomaticSize = Enum.AutomaticSize.XY
		r.LayoutOrder = order
		r.Parent = ui
		local rl = Instance.new("UIListLayout")
		rl.FillDirection = Enum.FillDirection.Horizontal
		rl.VerticalAlignment = Enum.VerticalAlignment.Center
		rl.Padding = UDim.new(0, 16)
		rl.SortOrder = Enum.SortOrder.LayoutOrder
		rl.Parent = r
		if typeof(key) == "EnumItem" then
			-- a gamepad button: the platform's image
			local im = Instance.new("ImageLabel")
			im.BackgroundTransparency = 1
			im.Size = UDim2.fromOffset(44, 44)
			im.Image = UserInputService:GetImageForKeyCode(key)
			im.Parent = r
			label(r, text, if small then 24 else 28, FONT, 2, nil, if small then 0.3 else 0)
			return
		end
		local k = Instance.new("TextLabel")
		k.BackgroundColor3 = Color3.new(1, 1, 1)
		k.Text = key
		k.TextSize = 24
		k.FontFace = FONT_B
		k.TextColor3 = Color3.fromHex("#1d2428")
		k.Size = UDim2.fromOffset(64, 34)
		k.AutomaticSize = Enum.AutomaticSize.X
		k.Parent = r
		Instance.new("UICorner", k).CornerRadius = UDim.new(0, 10)
		local kp = Instance.new("UIPadding")
		kp.PaddingLeft, kp.PaddingRight = UDim.new(0, 12), UDim.new(0, 12)
		kp.Parent = k
		label(r, text, if small then 24 else 28, FONT, 2, nil, if small then 0.3 else 0)
	end
	fillRows = function()
		for _, c in ui:GetChildren() do
			if c.Name == "Row" then
				c:Destroy()
			end
		end
		local rows = if Controls.mode == "gamepad" then PAD_ROWS elseif Controls.mode == "touch" then TOUCH_ROWS else ROWS
		for i, rw in rows do
			row(rw[1], rw[2], i)
		end
		if Controls.mode == "kbm" then
			row("O", "Photo Instructions", 99, true)
		end
	end
	fillRows()
	-- #photo-flash: the capture punch
	flash = Instance.new("Frame")
	flash.BackgroundColor3 = Color3.new(1, 1, 1)
	flash.BackgroundTransparency = 1
	flash.Size = UDim2.fromScale(1, 1)
	flash.BorderSizePixel = 0
	flash.ZIndex = 10
	flash.Parent = gui
	-- the focus marker (white .55, always on top in the web)
	marker = Instance.new("Part")
	marker.Name = "PhotoFocus"
	marker.Shape = Enum.PartType.Ball
	marker.Anchored = true
	marker.CanCollide = false
	marker.CanQuery = false
	marker.CanTouch = false
	marker.CastShadow = false
	marker.Material = Enum.Material.Neon
	marker.Color = Color3.new(1, 1, 1)
	marker.Transparency = 1
	marker.Parent = Workspace
end

-- the key press that opened photo mode reaches this module's handler in the same frame: ignore input until it has passed
-- (Roblox reuses one InputObject per key, so the object itself cannot tell the presses apart)
local activatedAt = -math.huge

--- CameraMode.Activate (refused while a view is open: the caller checks)
function PhotoMode.activate(_by: InputObject?)
	if PhotoMode.active then
		return
	end
	activatedAt = os.clock()
	PhotoMode.active = true
	fillRows()
	PC.photoOpen = true
	local cam = Workspace.CurrentCamera
	saved = { cf = cam.CFrame, fov = cam.FieldOfView }
	pos = cam.CFrame.Position
	local x, y = cam.CFrame:ToEulerAnglesYXZ()
	pitch = math.deg(-x)
	yaw = math.deg(-y)
	fov = cam.FieldOfView
	lookX, lookY, wheel = 0, 0, 0
	shooting = false
	focusTimer = 0
	-- the HUD hides (HUDManager.ShouldDisplay)
	table.clear(hiddenGuis)
	Controls.photo = true
	for _, g in player.PlayerGui:GetChildren() do
		if g:IsA("ScreenGui") and g ~= gui and g.Enabled and g.Name ~= "TouchControls" and g.Name ~= "TouchSticks" then
			g.Enabled = false
			table.insert(hiddenGuis, g)
		end
	end
	gui.Enabled = true
	ui.Visible = indicator
	if Controls.mode == "kbm" then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	end
	UserInputService.MouseIconEnabled = false
end

--- CameraMode.Deactivate
function PhotoMode.deactivate()
	if not PhotoMode.active then
		return
	end
	PhotoMode.active = false
	PC.photoOpen = false
	Controls.photo = false
	padHeld = {}
	marker.Transparency = 1
	gui.Enabled = false
	for _, g in hiddenGuis do
		if g.Parent then
			g.Enabled = true
		end
	end
	table.clear(hiddenGuis)
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	local cam = Workspace.CurrentCamera
	if saved then
		cam.CFrame = saved.cf
		cam.FieldOfView = saved.fov
	end
	saved = nil
end

function PhotoMode.toggle()
	if PhotoMode.active then
		PhotoMode.deactivate()
	else
		PhotoMode.activate()
	end
end

local function capture()
	shooting = true
	ui.Visible = false
	task.defer(function()
		pcall(function()
			game:GetService("CaptureService"):CaptureScreenshot(function() end)
		end)
		task.wait(0.05)
		ui.Visible = indicator
		flash.BackgroundTransparency = 0.3
		TweenService:Create(flash, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
		require(script.Parent.Sfx).play("click")
		task.wait(PHOTO.captureLock)
		shooting = false
	end)
end

--- CameraModeController.Update + LateUpdate
function PhotoMode.update(dt: number)
	if not PhotoMode.active then
		return
	end
	local ax, ay = lookX, lookY
	lookX, lookY = 0, 0
	local wh = wheel
	wheel = 0
	local function down(k: Enum.KeyCode): boolean
		return UserInputService:IsKeyDown(k)
	end
	local function held(k: Enum.KeyCode): boolean
		return padHeld[k] == true
	end
	local mx = (if down(Enum.KeyCode.D) then 1 else 0) - (if down(Enum.KeyCode.A) then 1 else 0)
	local my = (if down(Enum.KeyCode.W) then 1 else 0) - (if down(Enum.KeyCode.S) then 1 else 0)
	local stick = Controls.move()
	if mx == 0 and my == 0 then
		mx, my = stick.X, -stick.Y
	end
	local ud = (if down(Enum.KeyCode.E) or held(Enum.KeyCode.ButtonR1) or held(Enum.KeyCode.E) then 1 else 0)
		- (if down(Enum.KeyCode.Q) or held(Enum.KeyCode.ButtonL1) or held(Enum.KeyCode.Q) then 1 else 0)
	local fast = down(Enum.KeyCode.LeftShift) or down(Enum.KeyCode.RightShift) or fastLatch
	local focus = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) or held(Enum.KeyCode.ButtonL2)
	-- the right stick / touch aim stick looks at 90 deg/s; the D-pad steps the FOV
	local look = Controls.aimStick()
	ax += look.X * 90 / PHOTO.aimSpeed
	ay += look.Y * 90 / PHOTO.aimSpeed
	wh += ((if held(Enum.KeyCode.DPadUp) then 1 else 0) - (if held(Enum.KeyCode.DPadDown) then 1 else 0)) * 20 * dt
	if not shooting then
		-- UpdateMove: forward / right on the ground plane, up / down after the normalise
		local fwd = Vector3.new(math.sin(math.rad(yaw)), 0, -math.cos(math.rad(yaw)))
		local right = Vector3.new(-fwd.Z, 0, fwd.X)
		local dir = fwd * my + right * mx
		if dir.Magnitude > 0 then
			dir = dir.Unit
		end
		dir += Vector3.new(0, ud, 0)
		pos += dir * dt * (if fast then PHOTO.fastMoveSpeed else PHOTO.moveSpeed) * S
		-- UpdateLook / UpdateFov
		pitch = math.clamp(pitch + ay * PHOTO.aimSpeed * dt, -89.9, 89.9)
		yaw += ax * PHOTO.aimSpeed * dt
		fov = math.clamp(fov - wh, PHOTO.fovMin, PHOTO.fovMax)
	end
	local cam = Workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = CFrame.new(pos) * CFrame.fromEulerAnglesYXZ(-math.rad(pitch), -math.rad(yaw), 0)
	cam.FieldOfView = fov
	-- UpdateFocus: a ray from the camera; the marker 0.2 m back along it, shrinking over 1 s
	if focus then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { marker }
		local hit = Workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * PHOTO.focusRay * S, params)
		if hit then
			marker.Position = hit.Position - cam.CFrame.LookVector * PHOTO.focusBack * S
			focusTimer = PHOTO.focusMeshAppearTime
		end
	end
	if focusTimer > 0 then
		focusTimer = math.max(0, focusTimer - dt)
		local k = focusTimer / PHOTO.focusMeshAppearTime
		marker.Size = Vector3.one * PHOTO.focusMeshSize * S * math.max(0.01, k)
		marker.Transparency = if k > 0 then 0.45 else 1
	else
		marker.Transparency = 1
	end
end

function PhotoMode.start()
	build()
	UserInputService.InputChanged:Connect(function(input)
		if not PhotoMode.active then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			lookX += input.Delta.X
			lookY += input.Delta.Y
		elseif input.UserInputType == Enum.UserInputType.MouseWheel then
			wheel += input.Position.Z
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not PhotoMode.active or os.clock() - activatedAt < 0.05 then
			return
		end
		local kc = input.KeyCode
		if string.sub(kc.Name, 1, 6) == "Button" or string.sub(kc.Name, 1, 4) == "DPad" then
			padHeld[kc] = true
			if (kc == Enum.KeyCode.ButtonA or kc == Enum.KeyCode.ButtonR2) and not shooting then
				capture()
			elseif kc == Enum.KeyCode.ButtonX then
				indicator = not indicator
				ui.Visible = indicator
			elseif kc == Enum.KeyCode.ButtonL3 then
				fastLatch = not fastLatch
			elseif kc == Enum.KeyCode.ButtonB then
				PhotoMode.deactivate()
			end
			return
		end
		if input.KeyCode == Enum.KeyCode.Space and not shooting then
			capture()
		elseif input.KeyCode == Enum.KeyCode.O then
			-- UI_ToggleIndicatorHUD
			indicator = not indicator
			ui.Visible = indicator
		elseif input.KeyCode == Enum.KeyCode.K then
			require(script.Parent.Hud).toast("Photos are saved to your Roblox captures.", "info")
		elseif input.KeyCode == Enum.KeyCode.P then
			PhotoMode.deactivate()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		padHeld[input.KeyCode] = nil
	end)
	UserInputService.TouchPinch:Connect(function(_points, sc, _vel, state)
		if not PhotoMode.active then
			return
		end
		if state == Enum.UserInputState.Begin then
			pinchFov = fov
		end
		fov = math.clamp(pinchFov / math.max(0.1, sc), PHOTO.fovMin, PHOTO.fovMax)
	end)
	-- the touch buttons: Capture (Space), Up (E) / Down (Q) held, Hide UI (O), Exit (P)
	Controls.onKey(function(kc, isDown)
		if not PhotoMode.active then
			return
		end
		if kc == Enum.KeyCode.E or kc == Enum.KeyCode.Q then
			padHeld[kc] = if isDown then true else nil
		elseif not isDown then
			return
		elseif kc == Enum.KeyCode.Space and not shooting then
			capture()
		elseif kc == Enum.KeyCode.O then
			indicator = not indicator
			ui.Visible = indicator
		elseif kc == Enum.KeyCode.P and os.clock() - activatedAt > 0.05 then
			PhotoMode.deactivate()
		end
	end)
	-- the UI Cancel input (Esc opens the Roblox menu) leaves photo mode
	GuiService.MenuOpened:Connect(function()
		PhotoMode.deactivate()
	end)
end

return PhotoMode
