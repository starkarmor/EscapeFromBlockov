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
local Controls = require(script.Parent.Controls)
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

Controls.start()
require(script.Parent.TouchUI).start()
CharAnim.start()
Hud.start()
Combat.start()
Interact.start()
Results.start()
Inventory.start()
require(script.Parent.PhotoMode).start()
require(script.Parent.MapUI).start()
require(script.Parent.NoteUI).start()

ContextActionService:BindActionAtPriority("BlockovDodge", function(_, state)
	if state == Enum.UserInputState.Begin then
		PC.requestDodge()
	end
	return Enum.ContextActionResult.Sink
end, false, 3000, Enum.KeyCode.Space)

local Net = require(Shared.Net)
local BulletList = require(script.Parent.BulletList)
local SLOT_KEYS = { [Enum.KeyCode.Three] = 1, [Enum.KeyCode.Four] = 2, [Enum.KeyCode.Five] = 3, [Enum.KeyCode.Six] = 4, [Enum.KeyCode.Seven] = 5, [Enum.KeyCode.Eight] = 6 }
local function onKey(kc: Enum.KeyCode)
	if PC.blocked then
		return
	end
	-- World.handleSlots: 1 / 2 / V switch, "Empty slot" / "No melee weapon" when there is nothing there; V on the melee
	-- goes back to the gun
	local eq: { [string]: string } = {}
	local rawEq = player:GetAttribute("Equip")
	if typeof(rawEq) == "string" then
		for k, v in string.gmatch(rawEq, "(%w+)=([^,]*)") do
			eq[k] = v
		end
	end
	local function has(k: string): boolean
		return eq[k] ~= nil and eq[k] ~= ""
	end
	if kc == Enum.KeyCode.One or kc == Enum.KeyCode.Two then
		local key = if kc == Enum.KeyCode.One then "gun" else "gun2"
		if not has(key) then
			Hud.toast("Empty slot", "info")
			return
		end
		PC.held = "gun"
		PC.slot = if key == "gun" then 1 else 2
		Net.event("SelectSlot"):FireServer(key)
	elseif kc == Enum.KeyCode.Left or kc == Enum.KeyCode.Right then
		-- World.switchWeapon: the equipped firearm1 / firearm2 / melee in order, Left = previous, wrapping
		local list = {}
		for _, k in { "gun", "gun2", "melee" } do
			if has(k) then
				table.insert(list, k)
			end
		end
		if #list > 0 then
			local cur = if PC.held == "melee" then "melee" elseif PC.slot == 2 then "gun2" else "gun"
			local i = (table.find(list, cur) or 1) - (if kc == Enum.KeyCode.Left then 1 else -1)
			if i < 1 then
				i = #list
			elseif i > #list then
				i = 1
			end
			local key = list[i]
			PC.held = if key == "melee" then "melee" else "gun"
			PC.slot = if key == "gun" then 1 elseif key == "gun2" then 2 else 3
			Net.event("SelectSlot"):FireServer(key)
		end
	elseif kc == Enum.KeyCode.C then
		-- World: C puts the weapon away / takes it back out
		if PC.held == "none" then
			local key = if has("gun") then "gun" elseif has("gun2") then "gun2" else "melee"
			PC.held = if key == "melee" then "melee" else "gun"
			PC.slot = if key == "gun" then 1 elseif key == "gun2" then 2 else 3
			Net.event("SelectSlot"):FireServer(key)
		else
			PC.held = "none"
			Net.event("SelectSlot"):FireServer("none")
		end
	elseif kc == Enum.KeyCode.T then
		-- SwitchBulletType: open the type list / apply its selection (audio 'reload' when a new type is applied)
		if BulletList.press() then
			require(script.Parent.Sfx).play("reload")
		end
	elseif kc == Enum.KeyCode.Up or kc == Enum.KeyCode.Down then
		BulletList.switchInput(if kc == Enum.KeyCode.Up then 1 else -1)
	elseif kc == Enum.KeyCode.P then
		-- UI_ToggleCameraMode: Photo Mode, only while no view is open (PC.blocked)
		require(script.Parent.PhotoMode).activate()
	elseif kc == Enum.KeyCode.N then
		-- World.toggleNightVision (the server answers with the toast)
		Net.event("NightVision"):FireServer()
	elseif kc == Enum.KeyCode.F1 then
		-- CharacterMainControl.Quack (our Whistle): the voice and an AI noise of radius 15 at the character
		require(script.Parent.Sfx).play("whistle")
		Net.event("Whistle"):FireServer()
	elseif kc == Enum.KeyCode.Y then
		-- World.ts: Y toggles the top-down view
		CameraRig.topDown = not CameraRig.topDown
	elseif kc == Enum.KeyCode.V then
		if PC.held == "melee" then
			local key = if has("gun") then "gun" elseif has("gun2") then "gun2" else nil
			if key then
				PC.held = "gun"
				PC.slot = if key == "gun" then 1 else 2
				Net.event("SelectSlot"):FireServer(key)
			end
		elseif not has("melee") then
			Hud.toast("No melee weapon", "info")
		else
			PC.held = "melee"
			PC.slot = 3
			Net.event("SelectSlot"):FireServer("melee")
		end
	elseif SLOT_KEYS[kc] then
		local id, count = Hud.hotbarItem(SLOT_KEYS[kc])
		if id and count <= 0 then
			-- World: "No <item> left"
			local it = require(Shared.gen.Items).items[id]
			Hud.toast("No " .. (if it then it.name else id) .. " left", "bad")
		elseif id then
			-- a throwable becomes the held item (World: switchTo('throw', id)); "No X left" when the stack is gone
			local it = require(Shared.gen.Items).items[id]
			if it and it.kind == "throwable" then
				if Throw.select(id) then
					PC.slot = SLOT_KEYS[kc] + 3
					Net.event("SelectSlot"):FireServer("throw")
				end
			else
				Net.event("UseItem"):FireServer(id)
			end
		end
	end
end
UserInputService.InputBegan:Connect(function(input, processed)
	if not processed then
		onKey(input.KeyCode)
	end
end)
-- the same actions from the gamepad / touch controls
Controls.onKey(function(kc, down)
	if not down then
		return
	end
	if kc == Enum.KeyCode.Space then
		PC.requestDodge()
	else
		onKey(kc)
	end
end)

local snapped = false
RunService:BindToRenderStep("Blockov3C", Enum.RenderPriority.Camera.Value + 1, function(dt)
	dt = math.min(dt, 0.05) -- core/Loop.ts clamps the frame dt to 0.05 s
	Controls.update(dt)
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
	local Photo = require(script.Parent.PhotoMode)
	if Photo.active then
		Photo.update(dt)
	else
		CameraRig.update(dt, PC.pos.X, PC.pos.Y, {
		cursor = cursor,
		triggerHeld = Combat.triggerHeld(),
		ads = PC.ads,
		adsInput = PC.adsInput,
		adsFactor = if gun then gun.ADSAimDistanceFactor else nil,
		inputBlocked = PC.blocked,
	})
	end
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
