--!strict
-- BulletTypeHUD's type list (web src/game/bulletList.ts; source BulletTypeHUD.Update / OpenList / CloseList /
-- RefreshContent / OnSwitchInput / SetBulletType):
-- - T with the list closed opens it (a gun in hand, no action running); with it open it applies the selected entry and
--   closes it. The list closes by itself when it can no longer be open.
-- - entries: the gun's ammo types in the backpack with their counts, plus the target type with count 0 when it is not
--   carried, or one "Not Assigned" entry when the list would be empty; the current type starts selected.
-- - Up / Down / the wheel ("Switch Ammo/Interact"): only while open, index -= dir, wrapping.
-- - SetBulletType: a different type becomes the target and the character reloads (the server's SetAmmo).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Guns = require(Shared.Guns)
local Net = require(Shared.Net)
local PC = require(script.Parent.PlayerControl)

local player = Players.LocalPlayer
local BulletList = {}
BulletList.open = false
BulletList.index = 1
BulletList.entries = {} :: { { id: string?, count: number } }

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

local function canOpen(): boolean
	local gid = player:GetAttribute("Gun")
	return PC.held == "gun" and typeof(gid) == "string" and player:GetAttribute("ReloadUntil") == nil
		and player:GetAttribute("UseId") == nil and player:GetAttribute("HoldId") == nil and not PC.blocked
end

local function refresh()
	local gid = player:GetAttribute("Gun")
	table.clear(BulletList.entries)
	BulletList.index = 1
	if typeof(gid) ~= "string" then
		return
	end
	local target = player:GetAttribute("AmmoSel")
	for _, id in Guns.ammoTypesFor(gid) do
		local n = bagCount(id)
		if n > 0 then
			table.insert(BulletList.entries, { id = id, count = n })
		end
	end
	if typeof(target) == "string" then
		local found = false
		for _, e in BulletList.entries do
			if e.id == target then
				found = true
			end
		end
		if not found then
			table.insert(BulletList.entries, { id = target, count = 0 })
		end
	end
	if #BulletList.entries == 0 then
		table.insert(BulletList.entries, { id = nil, count = 0 })
	end
	for i, e in BulletList.entries do
		if e.id == target then
			BulletList.index = i
		end
	end
end

--- the SwitchBulletType press; true when a new type was applied
function BulletList.press(): boolean
	if not BulletList.open then
		if canOpen() then
			BulletList.open = true
			refresh()
		end
		return false
	end
	local e = BulletList.entries[BulletList.index]
	BulletList.open = false
	if not e or not e.id then
		return false
	end
	if e.id == player:GetAttribute("AmmoSel") then
		return false
	end
	Net.event("SetAmmo"):FireServer(e.id)
	return true
end

--- OnSwitchInput
function BulletList.switchInput(dir: number)
	if not BulletList.open then
		return
	end
	local n = #BulletList.entries
	if n == 0 then
		BulletList.index = 1
		return
	end
	BulletList.index -= dir
	if BulletList.index > n then
		BulletList.index = 1
	elseif BulletList.index < 1 then
		BulletList.index = n
	end
end

function BulletList.tick()
	if BulletList.open and not canOpen() then
		BulletList.open = false
	end
end

return BulletList
