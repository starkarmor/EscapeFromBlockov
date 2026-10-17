--!strict
-- Raid end (Game.finishRaid -> StationUI result, then LoadingScreen curtains), from the web build:
-- result: full-screen #0d0d0d, a 1002.56 column #1a1a1a; "YOU DIED" #f85566 128 (extraction: "Extracted" white);
-- "I was killed by" 32 + a box outlined 2.85 #f85566 with "Name (Weapon) [Headshot]"; EXP block 858 wide (bar 40,
-- old fill #eee, new #cced98 over 2 s smoothstep, "Lv.N" 36, punch on level-up); Continue 858x104.88 #7ae58f r16.
-- Continue -> curtain: death "You went down" / "The bunker will patch you up" on #7a3140 with a random tip and
-- "Click to Continue" (pulsing 80 disc); extraction "Extracted" on #d99a2e without a click. Then the redeploy.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local PC = require(script.Parent.PlayerControl)

local player = Players.LocalPlayer
local Results = {}
local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json")
local INK = Color3.new(0, 0, 0)
local TIPS = {
	"Bleeding? A bandage will stop it.",
	"Common supplies sell for more as cash than they weigh in your bag. Sell what you do not need.",
	"A worn gun is a worse gun. Below 50% durability, both damage and spread suffer.",
	"A hit hurts: it drains stamina and slows you for a moment. Painkillers cancel that.",
	"With a gun in hand, press T to change ammo type.",
	"In the backpack, drag attachments onto your weapon to fit them quickly. Check that they are compatible.",
	"When a brute goose flashes red, roll out of the way.",
	"You move slower while a weapon is in your hands.",
	"The storm is deadly. Sit it out in the bunker and sleep through the day.",
}

local gui: ScreenGui?
local root: Frame?

local function clear()
	if gui then
		gui:Destroy()
		gui = nil
	end
end

local function screen(order: number): (ScreenGui, Frame)
	local g = Instance.new("ScreenGui")
	g.Name = "Results"
	g.IgnoreGuiInset = true
	g.ResetOnSpawn = false
	g.DisplayOrder = order
	g.Parent = player:WaitForChild("PlayerGui")
	local r = Instance.new("Frame")
	r.BackgroundTransparency = 1
	r.Size = UDim2.fromScale(1, 1)
	r.Parent = g
	local us = Instance.new("UIScale")
	us.Parent = r
	local function fit()
		local vp = Workspace.CurrentCamera.ViewportSize
		local u = math.min(vp.X / 2560, vp.Y / 1440)
		us.Scale = u
		r.Size = UDim2.fromOffset(vp.X / u, vp.Y / u)
	end
	fit()
	Workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	return g, r
end

local function label(parent: Instance, s: string, size: number, color: Color3, props: { [string]: any }?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.FontFace = FONT
	t.Text = s
	t.TextSize = size
	t.TextColor3 = color
	t.RichText = true
	t.AutomaticSize = Enum.AutomaticSize.XY
	t.Size = UDim2.fromOffset(0, 0)
	if props then
		for k, v in props do
			(t :: any)[k] = v
		end
	end
	t.Parent = parent
	return t
end

local function curtain(kind: string, onDone: () -> ())
	clear()
	local g, r = screen(20)
	gui = g
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = if kind == "dead" then Color3.fromHex("#7a3140") else Color3.fromHex("#d99a2e")
	bg.Parent = r
	local head = label(bg, if kind == "dead" then "You went down" else "Extracted", 150, Color3.new(1, 1, 1), { Position = UDim2.fromOffset(220, 300), FontFace = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Heavy) })
	label(bg, if kind == "dead" then "The bunker will patch you up" else "Back to the bunker", 48, Color3.new(1, 1, 1), { Position = UDim2.fromOffset(226, 300 + 190), TextTransparency = 0.1 })
	-- the voxel figure bob (1.1 s alternate): a blocky beaver silhouette
	local fig = Instance.new("Frame")
	fig.AnchorPoint = Vector2.new(0.5, 1)
	fig.Position = UDim2.new(0.72, 0, 0.62, 0)
	fig.Size = UDim2.fromOffset(220, 260)
	fig.BackgroundColor3 = Color3.fromHex("#a56a32")
	fig.BorderSizePixel = 0
	fig.Parent = bg
	local belly = Instance.new("Frame")
	belly.AnchorPoint = Vector2.new(0.5, 1)
	belly.Position = UDim2.new(0.5, 0, 1, -20)
	belly.Size = UDim2.fromOffset(120, 140)
	belly.BackgroundColor3 = Color3.fromHex("#e8c898")
	belly.BorderSizePixel = 0
	belly.Parent = fig
	TweenService:Create(fig, TweenInfo.new(1.1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Position = UDim2.new(0.72, 0, 0.6, 0) }):Play()
	-- tips pill: black .682 r60, 800 wide, text 20, bottom 67
	local tip = Instance.new("TextLabel")
	tip.AnchorPoint = Vector2.new(0.5, 1)
	tip.Position = UDim2.new(0.5, 0, 1, -67)
	tip.Size = UDim2.fromOffset(800, 60)
	tip.BackgroundColor3 = INK
	tip.BackgroundTransparency = 0.318
	tip.FontFace = FONT
	tip.TextSize = 20
	tip.TextColor3 = Color3.new(1, 1, 1)
	tip.TextWrapped = true
	tip.Text = TIPS[math.random(1, #TIPS)]
	local tc = Instance.new("UICorner")
	tc.CornerRadius = UDim.new(0, 60)
	tc.Parent = tip
	tip.Parent = bg
	local _ = head
	local loading = label(bg, "Loading...", 36, Color3.new(1, 1, 1), { AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -80, 1, -165) })
	task.delay(3.0, function()
		loading.Visible = false
		if kind ~= "dead" then
			onDone()
			clear()
			return
		end
		-- "Click to Continue": an 80 disc pulsing 1 s + text 36; any mouse button continues
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.AnchorPoint = Vector2.new(1, 1)
		row.Position = UDim2.new(1, -80, 1, -150)
		row.Size = UDim2.fromOffset(460, 90)
		row.Parent = bg
		local disc = Instance.new("Frame")
		disc.AnchorPoint = Vector2.new(0.5, 0.5)
		disc.Position = UDim2.fromOffset(40, 45)
		disc.Size = UDim2.fromOffset(80, 80)
		disc.BackgroundColor3 = Color3.new(1, 1, 1)
		local dc = Instance.new("UICorner")
		dc.CornerRadius = UDim.new(1, 0)
		dc.Parent = disc
		disc.Parent = row
		local ds = Instance.new("UIScale")
		ds.Parent = disc
		TweenService:Create(ds, TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), { Scale = 1.5 }):Play()
		TweenService:Create(disc, TweenInfo.new(1, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, -1), { BackgroundTransparency = 1, BackgroundColor3 = INK }):Play()
		local ct = label(row, "Click to Continue", 36, Color3.new(1, 1, 1), { Position = UDim2.fromOffset(100, 20) })
		UserInputService.MouseIconEnabled = true
		local conn: RBXScriptConnection
		conn = UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.MouseButton2 then
				conn:Disconnect()
				local s = Instance.new("UIScale")
				s.Scale = 0.9
				s.Parent = ct
				task.wait(0.6)
				onDone()
				clear()
			end
		end)
	end)
end

local function redeploy()
	if Net.func("Deploy"):InvokeServer() then
		UserInputService.MouseIconEnabled = false
	end
	-- the continue click must not become a shot
	task.delay(0.3, function()
		PC.resultOpen = false
	end)
end

local function result(dead: boolean, info: any, lines: { string }?)
	clear()
	local g, r = screen(10)
	gui = g
	root = r
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromHex("#0d0d0d")
	bg.BackgroundTransparency = 1
	bg.Parent = r
	TweenService:Create(bg, TweenInfo.new(0.2), { BackgroundTransparency = 0 }):Play()
	local col = Instance.new("Frame")
	col.AnchorPoint = Vector2.new(0.5, 0)
	col.Position = UDim2.fromScale(0.5, 0)
	col.Size = UDim2.new(0, 1002.56, 1, 0)
	col.BackgroundColor3 = Color3.fromHex("#1a1a1a")
	col.BorderSizePixel = 0
	col.Parent = bg
	local list = Instance.new("UIListLayout")
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, 40)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = col
	label(col, if dead then "YOU DIED" else "Extracted", 128, if dead then Color3.fromHex("#f85566") else Color3.new(1, 1, 1), { LayoutOrder = 1 })
	if dead then
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.AutomaticSize = Enum.AutomaticSize.XY
		row.LayoutOrder = 2
		row.Parent = col
		local rl = Instance.new("UIListLayout")
		rl.FillDirection = Enum.FillDirection.Horizontal
		rl.VerticalAlignment = Enum.VerticalAlignment.Center
		rl.Padding = UDim.new(0, 24)
		rl.Parent = row
		label(row, "I was killed by  →", 32, Color3.fromHex("#e7e7e7"))
		local kb = label(row, info.killer or "?", 32, Color3.new(1, 1, 1))
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 24)
		pad.PaddingRight = UDim.new(0, 24)
		pad.PaddingTop = UDim.new(0, 10)
		pad.PaddingBottom = UDim.new(0, 10)
		pad.Parent = kb
		local ks = Instance.new("UIStroke")
		ks.Thickness = 2.85
		ks.Color = Color3.fromHex("#f85566")
		ks.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		ks.Parent = kb
		local kc = Instance.new("UICorner")
		kc.CornerRadius = UDim.new(0, 16)
		kc.Parent = kb
	end
	if lines and #lines > 0 then
		label(col, table.concat(lines, "\n"), 28, Color3.fromHex("#cfcfcf"), { LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Center })
	end
	-- EXP block
	local exp = Instance.new("Frame")
	exp.Size = UDim2.fromOffset(858, 150)
	exp.BackgroundColor3 = Color3.new(1, 1, 1)
	exp.BackgroundTransparency = 0.9725
	exp.LayoutOrder = 4
	exp.Parent = col
	label(exp, "EXP", 36, Color3.new(1, 1, 1), { Position = UDim2.fromOffset(24, 16) })
	local need = math.max(1, info.need or 2000)
	local into0 = info.into or 0
	local gained = (info.xpAfter or 0) - (info.xpBefore or 0)
	local nums = label(exp, string.format("%d/<sub>%d</sub>", into0, need), 32, Color3.new(1, 1, 1), { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -24, 0, 18) })
	local lv = label(exp, "Lv." .. tostring(info.level or 1), 36, Color3.fromHex("#e7e7e7"), { Position = UDim2.fromOffset(24, 90) })
	local bar = Instance.new("Frame")
	bar.Position = UDim2.fromOffset(150, 92)
	bar.Size = UDim2.fromOffset(684, 40)
	bar.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0, 8)
	bc.Parent = bar
	bar.Parent = exp
	local newF = Instance.new("Frame")
	newF.BackgroundColor3 = Color3.fromHex("#cced98")
	newF.Size = UDim2.fromScale(math.clamp(into0 / need, 0, 1), 1)
	newF.Parent = bar
	bc:Clone().Parent = newF
	local oldF = Instance.new("Frame")
	oldF.BackgroundColor3 = Color3.fromHex("#eeeeee")
	oldF.Size = UDim2.fromScale(math.clamp(into0 / need, 0, 1), 1)
	oldF.Parent = bar
	bc:Clone().Parent = oldF
	-- Continue
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.fromOffset(858, 104.88)
	btn.BackgroundColor3 = Color3.fromHex("#7ae58f")
	btn.FontFace = FONT
	btn.Text = "Continue"
	btn.TextSize = 40
	btn.TextColor3 = Color3.fromHex("#e5e5e5")
	btn.LayoutOrder = 5
	local btc = Instance.new("UICorner")
	btc.CornerRadius = UDim.new(0, 16)
	btc.Parent = btn
	local bts = Instance.new("UIStroke")
	bts.Thickness = 2
	bts.Color = INK
	bts.Transparency = 0.5
	bts.Parent = btn
	btn.Parent = col
	local bscale = Instance.new("UIScale")
	bscale.Parent = btn
	UserInputService.MouseIconEnabled = true
	-- EXP animation: 2.0 s smoothstep from the old to the new total; Lv punches on a level-up; then the button punches
	task.spawn(function()
		local t0 = os.clock()
		local level = info.level or 1
		local into, nd = into0, need
		while true do
			local k = math.clamp((os.clock() - t0) / 2, 0, 1)
			local s = k * k * (3 - 2 * k)
			local cur = into0 + gained * s
			into, nd = cur, need
			if cur >= need and gained > 0 then
				-- simple level step (the server's table decides the real level on the next screen)
				into = cur - need
				if lv.Text ~= "Lv." .. (level + 1) then
					lv.Text = "Lv." .. (level + 1)
					local p = Instance.new("UIScale")
					p.Scale = 1.5
					p.Parent = lv
					TweenService:Create(p, TweenInfo.new(0.2), { Scale = 1 }):Play()
				end
			end
			newF.Size = UDim2.fromScale(math.clamp(into / nd, 0, 1), 1)
			nums.Text = string.format("%d/<sub>%d</sub>", math.floor(into), nd)
			if k >= 1 then
				break
			end
			task.wait()
		end
		bscale.Scale = 1.1
		TweenService:Create(bscale, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	end)
	btn.MouseButton1Click:Connect(function()
		curtain(if dead then "dead" else "extract", redeploy)
	end)
end

function Results.start()
	Net.event("Died").OnClientEvent:Connect(function(info: any)
		PC.resultOpen = true
		result(true, info, nil)
	end)
	Net.event("Extracted").OnClientEvent:Connect(function(banked: { any }, info: any)
		-- the source's result screen lists no items (kills / items are passed but not displayed)
		local _ = banked
		PC.resultOpen = true
		result(false, info, nil)
	end)
end

return Results
