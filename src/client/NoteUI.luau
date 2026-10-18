--!strict
-- A read note (NoteInteract -> NotesUI): a paper card with the title and text; any click, F or Escape closes it.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Net = require(ReplicatedStorage:WaitForChild("Shared").Net)
local PC = require(script.Parent.PlayerControl)

local NoteUI = {}
local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Heavy)
local BODY = Font.new("rbxasset://fonts/families/FredokaOne.json")

local gui = Instance.new("ScreenGui")
gui.Name = "Note"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 25
gui.Enabled = false
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
local shade = Instance.new("Frame")
shade.Size = UDim2.fromScale(1, 1)
shade.BackgroundColor3 = Color3.new(0, 0, 0)
shade.BackgroundTransparency = 0.45
shade.Parent = gui
local card = Instance.new("Frame")
card.AnchorPoint = Vector2.new(0.5, 0.5)
card.Position = UDim2.fromScale(0.5, 0.5)
card.Size = UDim2.fromOffset(560, 380)
card.BackgroundColor3 = Color3.fromHex("#f4ead2")
card.Parent = gui
local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 14)
corner.Parent = card
local st = Instance.new("UIStroke")
st.Thickness = 4
st.Color = Color3.fromHex("#1e272e")
st.Parent = card
local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Position = UDim2.fromOffset(32, 24)
title.Size = UDim2.new(1, -64, 0, 48)
title.FontFace = FONT
title.TextSize = 38
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromHex("#1e272e")
title.Parent = card
local body = Instance.new("TextLabel")
body.BackgroundTransparency = 1
body.Position = UDim2.fromOffset(32, 86)
body.Size = UDim2.new(1, -64, 1, -140)
body.FontFace = BODY
body.TextSize = 26
body.TextWrapped = true
body.TextXAlignment = Enum.TextXAlignment.Left
body.TextYAlignment = Enum.TextYAlignment.Top
body.TextColor3 = Color3.fromHex("#3a3328")
body.Parent = card
local hint = body:Clone()
hint.Position = UDim2.new(0, 32, 1, -46)
hint.Size = UDim2.new(1, -64, 0, 30)
hint.TextSize = 20
hint.TextXAlignment = Enum.TextXAlignment.Right
hint.TextColor3 = Color3.fromHex("#7a6e5a")
hint.Text = "Click to close"
hint.Parent = card

local openedAt = 0
local function close()
	gui.Enabled = false
	PC.noteOpen = false
	UserInputService.MouseIconEnabled = false
end

function NoteUI.start()
	Net.event("Note").OnClientEvent:Connect(function(t: string, text: string)
		title.Text = t
		body.Text = text
		gui.Enabled = true
		PC.noteOpen = true
		openedAt = os.clock()
	end)
	UserInputService.InputBegan:Connect(function(input)
		if not gui.Enabled or os.clock() - openedAt < 0.2 then
			return
		end
		-- a click / tap, Esc, F, or the gamepad's A / B / X
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.F or input.KeyCode == Enum.KeyCode.ButtonA
			or input.KeyCode == Enum.KeyCode.ButtonB or input.KeyCode == Enum.KeyCode.ButtonX then
			close()
		end
	end)
end

return NoteUI
