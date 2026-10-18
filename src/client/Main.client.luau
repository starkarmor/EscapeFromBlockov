--!strict
-- Client entry: software cursor, the 3C loop (PlayerControl -> CameraRig -> CharAnim), HUD.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local PC = require(script.Parent.PlayerControl)
local CameraRig = require(script.Parent.CameraRig)
local CharAnim = require(script.Parent.CharAnim)
local Hud = require(script.Parent.Hud)
local Combat = require(script.Parent.Combat)
local Interact = require(script.Parent.Interact)
local Results = require(script.Parent.Results)
local Vision = require(script.Parent.Vision)
local DayNight = require(script.Parent.DayNight)
local Sfx = require(script.Parent.Sfx)
local Inventory = require(script.Parent.Inventory)
local Throw = require(script.Parent.Throw)
local stepT = 0

local player = Players.LocalPlayer
local S = Units.S

-- the default Roblox controls and camera are replaced by the web game's 3C
local ok, controls = pcall(function()
	local pm = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript) :: any
	return pm:GetControls()
end)
if ok and controls then
	controls:Disable()
end
UserInputService.MouseIconEnabled = false
-- the chat window would sit over the web HUD's top-left clock and swallow clicks there: dock it right-centre
pcall(function()
	local cw = game:GetService("TextChatService"):WaitForChild("ChatWindowConfiguration", 5)
	if cw then
		cw.HorizontalAlignment = Enum.HorizontalAlignment.Right
		cw.VerticalAlignment = Enum.VerticalAlignment.Center
	end
end)

CharAnim.start()
Hud.start()
Combat.start()
Interact.start()
Results.start()
Inventory.start()
require(script.Parent.MapUI).start()

ContextActionService:BindActionAtPriority("BlockovDodge", function(_, state)
	if state == Enum.UserInputState.Begin then
		PC.requestDodge()
	end
	return Enum.ContextActionResult.Sink
end, false, 3000, Enum.KeyCode.Space)

local Net = require(Shared.Net)
local SLOT_KEYS = { [Enum.KeyCode.Three] = 1, [Enum.KeyCode.Four] = 2, [Enum.KeyCode.Five] = 3, [Enum.KeyCode.Six] = 4, [Enum.KeyCode.Seven] = 5, [Enum.KeyCode.Eight] = 6 }
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or PC.blocked then
		return
	end
	if input.KeyCode == Enum.KeyCode.One then
		PC.held = "gun"
		PC.slot = 1
		Net.event("SelectSlot"):FireServer("gun")
	elseif input.KeyCode == Enum.KeyCode.Two then
		PC.held = "gun"
		PC.slot = 2
		Net.event("SelectSlot"):FireServer("gun2")
	elseif input.KeyCode == Enum.KeyCode.V then
		PC.held = "melee"
		PC.slot = 3
		Net.event("SelectSlot"):FireServer("melee")
	elseif SLOT_KEYS[input.KeyCode] then
		local id = Hud.hotbarItem(SLOT_KEYS[input.KeyCode])
		if id then
			-- a throwable becomes the held item (World: switchTo('throw', id)); "No X left" when the stack is gone
			local it = require(Shared.gen.Items).items[id]
			if it and it.kind == "throwable" then
				if Throw.select(id) then
					PC.slot = SLOT_KEYS[input.KeyCode] + 3
					Net.event("SelectSlot"):FireServer("throw")
				end
			else
				Net.event("UseItem"):FireServer(id)
			end
		end
	end
end)

local snapped = false
RunService:BindToRenderStep("Blockov3C", Enum.RenderPriority.Camera.Value + 1, function(dt)
	dt = math.min(dt, 0.1)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		Vision.fan(false)
		Vision.update()
		DayNight.update(dt)
		Hud.update(dt)
		return
	end
	local cursor = Combat.cursor()
	if not snapped then
		snapped = true
		PC.snap(root.Position.X / S, root.Position.Z / S)
		CameraRig.snapTo(root.Position.X / S, root.Position.Z / S)
	end
	PC.update(dt, cursor)
	Combat.update(dt)
	local gun = if PC.held == "gun" then PC.gun else nil
	CameraRig.update(dt, PC.pos.X, PC.pos.Y, {
		cursor = cursor,
		triggerHeld = Combat.triggerHeld(),
		ads = PC.ads,
		adsInput = PC.adsInput,
		adsFactor = if gun then gun.ADSAimDistanceFactor else nil,
		inputBlocked = PC.blocked,
	})
	Interact.update(dt)
	Vision.update()
	Vision.fan(true)
	DayNight.update(dt)
	-- footsteps: the walk cycle bands (gz_holdpose thresholds 0.5 / 1 / 2 m/s -> 1.25 / 0.714 / 0.476 s per cycle, 2 steps)
	local sp = PC.vel.Magnitude
	if sp > 0.5 and not PC.dashing() then
		stepT -= dt
		if stepT <= 0 then
			stepT = (if sp >= 2 then 0.476 elseif sp >= 1 then 0.714 else 1.25) / 2
			Sfx.play("step")
		end
	end
	CharAnim.localState = PC.animState()
	Hud.update(dt)
end)

player.CharacterAdded:Connect(function()
	snapped = false
end)
