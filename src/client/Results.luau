--!strict
-- Raid end screens (the web's result screen): "Killed by" on death, the banked items on extraction, then Redeploy.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Items = require(Shared.gen.Items)

local player = Players.LocalPlayer
local Results = {}
local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json")
local INK = Color3.fromRGB(22, 21, 29)

local gui: ScreenGui

local function text(parent: Instance, s: string, size: number, color: Color3, y: number): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.FontFace = FONT
	t.Text = s
	t.TextSize = size
	t.TextColor3 = color
	t.AnchorPoint = Vector2.new(0.5, 0)
	t.Position = UDim2.new(0.5, 0, 0, y)
	t.Size = UDim2.new(1, -40, 0, size + 8)
	t.TextWrapped = true
	local st = Instance.new("UIStroke")
	st.Thickness = math.max(2, size / 10)
	st.Color = INK
	st.Parent = t
	t.Parent = parent
	return t
end

local function show(titleText: string, color: Color3, lines: { string })
	if gui then
		gui:Destroy()
	end
	gui = Instance.new("ScreenGui")
	gui.Name = "Results"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Parent = player:WaitForChild("PlayerGui")
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(16, 18, 30)
	bg.BackgroundTransparency = 0.25
	bg.Parent = gui
	text(bg, titleText, 64, color, 120)
	for i, l in lines do
		text(bg, l, 22, Color3.fromRGB(255, 248, 233), 210 + i * 30)
	end
	local b = Instance.new("TextButton")
	b.AnchorPoint = Vector2.new(0.5, 1)
	b.Position = UDim2.new(0.5, 0, 1, -80)
	b.Size = UDim2.fromOffset(260, 64)
	b.BackgroundColor3 = Color3.fromRGB(128, 222, 37)
	b.FontFace = FONT
	b.Text = "Redeploy"
	b.TextSize = 32
	b.TextColor3 = Color3.fromRGB(255, 248, 233)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 16)
	c.Parent = b
	local st = Instance.new("UIStroke")
	st.Thickness = 4
	st.Color = INK
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	st.Parent = b
	local st2 = Instance.new("UIStroke")
	st2.Thickness = 3
	st2.Color = INK
	st2.Parent = b
	b.Parent = bg
	UserInputService.MouseIconEnabled = true
	b.MouseButton1Click:Connect(function()
		if Net.func("Deploy"):InvokeServer() then
			gui:Destroy()
			UserInputService.MouseIconEnabled = false
		end
	end)
end

function Results.start()
	Net.event("Died").OnClientEvent:Connect(function(by: string, secs: number)
		show("YOU DIED", Color3.fromRGB(232, 50, 46), { "Killed by " .. tostring(by), string.format("Survived %d:%02d", secs // 60, secs % 60), "Your gear stays on your body." })
	end)
	Net.event("Extracted").OnClientEvent:Connect(function(banked: { any }, secs: number)
		local lines = { string.format("Raid time %d:%02d", secs // 60, secs % 60) }
		for _, s in banked do
			local def = Items.items[s.id]
			table.insert(lines, string.format("+%d %s", s.n, def and def.name or s.id))
			if #lines > 9 then
				break
			end
		end
		show("EXTRACTED", Color3.fromRGB(128, 222, 37), lines)
	end)
end

return Results
