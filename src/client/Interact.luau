--!strict
-- Interactions (World.gatherOptions / startOption):
-- every interactable within reach is an option, nearest first; the mouse wheel or up / down picks one, F uses it.
-- Labels: a container's name ("Toolbox"), "Loot" for bodies, doors "Open" / "Close", builds with their cost;
-- requirement tags in red (missing) or green (have, selected only), "Empty" on searched empty boxes.
-- Opening a container shows its items in the LootView's loot pane (client/Inventory.luau, server/Inventory.luau).
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local MapData = require(Shared.MapData)
local Items = require(Shared.gen.Items)
local PC = require(script.Parent.PlayerControl)
local Hud = require(script.Parent.Hud)
local Inventory = require(script.Parent.Inventory)
local Sfx = require(script.Parent.Sfx)
local Controls = require(script.Parent.Controls)

local player = Players.LocalPlayer
local S = Units.S
local Interact = {}

local FONT = Font.new("rbxasset://fonts/families/FredokaOne.json")
local WHITE = Color3.new(1, 1, 1)
local CREAM = Color3.fromHex("#f8f2ea")
local INK = Color3.new(0, 0, 0)

type Point = { id: string, kind: string, label: string, x: number, z: number, r: number, hold: number, flag: string?, cost: { any }?, key: string?, part: BasePart? }
local points: { [string]: Point } = {}
local selIndex = 1
local lastList: { Point } = {}

local function bagCount(id: string): number
	local raw = player:GetAttribute("Bag")
	local n = 0
	if typeof(raw) == "string" then
		for bid, c in string.gmatch(raw, "([^:,]+):(%d+)") do
			if bid == id then
				n += tonumber(c) or 0
			end
		end
	end
	return n
end

local function itemName(id: string): string
	local d = Items.items[id]
	return if d then d.name else (string.gsub(id, "_", " "))
end

local function refreshPoints()
	for _, d in MapData.doors or {} do
		points[d.id] = { id = d.id, kind = "door", label = "Open", x = d.x, z = d.z, r = 1.9, hold = d.interactTime or 0.2, key = d.key }
	end
	local all = table.clone(MapData.interacts)
	for _, it in require(Shared.CaveData).interacts do
		table.insert(all, it)
	end
	for _, it in all do
		if it.kind == "construct" then
			points[it.id] = { id = it.id, kind = "construct", label = it.label or "Build", x = it.x, z = it.z, r = it.r or 2.4, hold = it.hold or 0, flag = it.flag, cost = (it.cost and it.cost.items) or {} }
		elseif it.kind == "note" or it.kind == "beacon" or it.kind == "wall" or it.kind == "station" then
			points[it.id] = { id = it.id, kind = it.kind, label = it.label, x = it.x, z = it.z, r = math.max(it.r or 1.8, 1.8), hold = it.hold or 0, flag = it.flag }
		elseif it.kind == "hatch" or (it.kind == "teleport" and (it.label == "Go" or it.arrive ~= nil)) or it.kind == "loader" then
			points[it.id] = { id = it.id, kind = it.kind, label = it.label, x = it.x, z = it.z, r = math.max(it.r or 1.8, 1.8), hold = it.hold or 0 }
		end
	end
end

-- containers (Loot folder anchors) and bodies (character roots) carry a "Box" attribute
local function trackBox(p: Instance)
	if not p:IsA("BasePart") then
		return
	end
	local part = p :: BasePart
	local function add()
		local id = part:GetAttribute("Box")
		if typeof(id) ~= "string" or points[id] then
			return
		end
		local bodyName = part:GetAttribute("BoxName")
		local isBody = typeof(bodyName) == "string"
		local loose = part:GetAttribute("Loose")
		points[id] = {
			id = id,
			kind = if typeof(loose) == "string" then "loose" elseif isBody then "body" else "container",
			label = if typeof(loose) == "string" then loose elseif isBody then bodyName else part.Name,
			x = part.Position.X / S,
			z = part.Position.Z / S,
			-- World.gatherOptions: loose items within 1.4 m, containers 1.9
			r = if typeof(loose) == "string" then 1.4 else 1.9,
			hold = if part.Name == "tech" then 0.6 else 0,
			part = part,
		}
		part.AncestryChanged:Connect(function()
			if not part:IsDescendantOf(Workspace) then
				points[id] = nil
			end
		end)
	end
	add()
	part:GetAttributeChangedSignal("Box"):Connect(add)
	part:GetAttributeChangedSignal("Loose"):Connect(function()
		local id = part:GetAttribute("Box")
		local pt = typeof(id) == "string" and points[id]
		if pt then
			pt.label = tostring(part:GetAttribute("Loose"))
		end
	end)
end

local function optionFor(pt: Point): Hud.PromptOpt?
	if pt.kind == "construct" and Workspace:GetAttribute("Flag_" .. (string.gsub(tostring(pt.flag), "[^%w_]", "_"))) then
		return nil
	end
	if pt.kind == "beacon" and Workspace:GetAttribute("Flag_" .. (pt.flag or "beacon")) then
		return nil -- an unlocked beacon hides its interact
	end
	if pt.kind == "wall" then
		if Workspace:GetAttribute("Flag_" .. (pt.flag or "wall")) then
			return nil
		end
		return { label = pt.label, sel = false, req = "Requires Explosives", reqOk = false }
	end
	if pt.kind == "loose" then
		-- "Name xN"
		return { label = pt.label, sel = false }
	end
	if pt.kind == "container" or pt.kind == "body" then
		local typ = Items.types[pt.label]
		local name = if pt.kind == "body" then "Loot" else (if typ then typ.name else pt.label)
		local count = Workspace:GetAttribute("Box_" .. (string.gsub(pt.id, "[^%w_]", "_")))
		if Workspace:GetAttribute("BoxS_" .. (string.gsub(pt.id, "[^%w_]", "_"))) == true and count == 0 then
			if pt.kind == "body" then
				return nil -- an emptied body / tomb is hidden from interaction
			end
			return { label = name, sel = false, req = "Empty", reqOk = false }
		end
		return { label = name, sel = false }
	elseif pt.kind == "door" then
		local open = Workspace:GetAttribute("Door_" .. pt.id) == true
		if pt.key and not open then
			local have = bagCount(pt.key) > 0
			return { label = "Open", sel = false, req = if have then itemName(pt.key) else "Requires Key", reqOk = have }
		end
		return { label = if open then "Close" else "Open", sel = false }
	elseif pt.kind == "construct" then
		local parts, ok = {}, true
		for _, c in pt.cost or {} do
			table.insert(parts, string.format("%s x%d", itemName(c[1]), c[2]))
			if bagCount(c[1]) < c[2] then
				ok = false
			end
		end
		if #parts > 0 then
			return { label = pt.label, sel = false, req = (if ok then "" else "Requires ") .. table.concat(parts, ", "), reqOk = ok }
		end
		return { label = pt.label, sel = false }
	end
	return { label = pt.label, sel = false }
end

-- ------------------------------------------------------------------ loot pane
-- ------------------------------------------------------------------ loop
function Interact.update(_dt: number)
	local list: { Point } = {}
	for _, pt in points do
		if pt.part and pt.part.Parent then
			pt.x, pt.z = pt.part.Position.X / S, pt.part.Position.Z / S
		end
		if (Vector2.new(pt.x, pt.z) - PC.pos).Magnitude <= pt.r then
			table.insert(list, pt)
		end
	end
	table.sort(list, function(a, b)
		return (Vector2.new(a.x, a.z) - PC.pos).Magnitude < (Vector2.new(b.x, b.z) - PC.pos).Magnitude
	end)
	local opts: { Hud.PromptOpt } = {}
	local shown: { Point } = {}
	for _, pt in list do
		local o = optionFor(pt)
		if o then
			table.insert(opts, o)
			table.insert(shown, pt)
		end
	end
	-- a wheel selection stays while its target remains in reach
	local keep = lastList[selIndex]
	selIndex = 1
	for i, pt in shown do
		if pt == keep then
			selIndex = i
		end
	end
	lastList = shown
	if opts[selIndex] then
		opts[selIndex].sel = true
	end
	if #opts > 0 and not Inventory.open and not PC.blocked then
		local focus = shown[1]
		Hud.setPrompt(opts, Vector3.new(focus.x, 0.62, focus.z))
		Controls.prompt = opts[selIndex] and opts[selIndex].label
		Controls.promptCount = #opts
	else
		Hud.setPrompt(nil, nil)
		Controls.prompt = nil
		Controls.promptCount = 0
	end
	local holdId = player:GetAttribute("HoldId")
	if typeof(holdId) == "string" then
		local t0 = player:GetAttribute("HoldStart")
		local dur = player:GetAttribute("HoldTime")
		if typeof(t0) == "number" and typeof(dur) == "number" then
			Hud.setProgress((Workspace:GetServerTimeNow() - t0) / dur)
		end
	end
end

local function keyDown(kc: Enum.KeyCode)
	if kc == Enum.KeyCode.F then
		if lastList[selIndex] then
			Net.event("Interact"):FireServer(lastList[selIndex].id)
		end
	elseif kc == Enum.KeyCode.Up or kc == Enum.KeyCode.Down then
		if #lastList > 1 then
			selIndex = (selIndex + (if kc == Enum.KeyCode.Down then 1 else -1) - 1) % #lastList + 1
		end
	end
end

function Interact.start()
	refreshPoints()
	local lootFolder = Workspace:WaitForChild("Loot", 10)
	if lootFolder then
		for _, p in lootFolder:GetChildren() do
			trackBox(p)
		end
		lootFolder.ChildAdded:Connect(trackBox)
	end
	local chars = Workspace:WaitForChild("Characters")
	local function watchChar(m: Instance)
		local r = m:WaitForChild("HumanoidRootPart", 5)
		if r then
			trackBox(r)
		end
	end
	for _, m in chars:GetChildren() do
		task.spawn(watchChar, m)
	end
	chars.ChildAdded:Connect(function(m)
		task.spawn(watchChar, m)
	end)
	-- Escape is taken by the Roblox menu (processed): the LootView closes when the menu opens
	game:GetService("GuiService").MenuOpened:Connect(function()
		if Inventory.open then
			Inventory.toggle(false)
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		-- the LootView owns the keys while it is open (F there transfers the hovered item)
		if processed or Inventory.open then
			return
		end
		keyDown(input.KeyCode)
	end)
	-- the gamepad's X / D-pad and the touch Interact button (held for hold interactions)
	Controls.onKey(function(kc, down)
		if down then
			if not Inventory.open and not PC.blocked then
				keyDown(kc)
			end
		elseif kc == Enum.KeyCode.F and player:GetAttribute("HoldId") then
			Net.event("InteractCancel"):FireServer()
		end
	end)
	UserInputService.InputChanged:Connect(function(input, processed)
		if processed or Inventory.open then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and math.abs(input.Position.Z) > 0.5 then
			require(script.Parent.BulletList).switchInput(if input.Position.Z > 0 then 1 else -1)
		end
		if #lastList < 2 then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel and math.abs(input.Position.Z) > 0.5 then
			selIndex = (selIndex + (if input.Position.Z < 0 then 1 else -1) - 1) % #lastList + 1
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.F and player:GetAttribute("HoldId") then
			Net.event("InteractCancel"):FireServer()
		end
	end)
end

return Interact
