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

CharAnim.start()
Hud.start()
Combat.start()
Interact.start()
Results.start()

ContextActionService:BindActionAtPriority("CanuckDodge", function(_, state)
	if state == Enum.UserInputState.Begin then
		PC.requestDodge()
	end
	return Enum.ContextActionResult.Sink
end, false, 3000, Enum.KeyCode.Space)

local snapped = false
RunService:BindToRenderStep("Canuckov3C", Enum.RenderPriority.Camera.Value + 1, function(dt)
	dt = math.min(dt, 0.1)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
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
	CharAnim.localState = PC.animState()
	Hud.update(dt)
end)

player.CharacterAdded:Connect(function()
	snapped = false
end)
