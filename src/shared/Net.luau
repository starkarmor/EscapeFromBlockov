--!strict
-- One folder of remotes, created by the server and waited on by clients.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = {}
local EVENTS = { "StopAction", "Equip", "Unequip", "Melee", "Fire", "Reload", "Dodge", "Interact", "InteractCancel", "SelectSlot", "Sprint", "Aim", "UseItem", "Hit", "Fx", "Toast", "RaidState", "LootOpen", "LootTake", "Extracted", "Died", "Throw", "Note", "Inv", "InvOp", "SetAmmo", "Whistle", "NightVision" }
local FUNCTIONS = { "Deploy" }

local folder: Folder
if RunService:IsServer() then
	folder = Instance.new("Folder")
	folder.Name = "Net"
	for _, n in EVENTS do
		local r = Instance.new("RemoteEvent")
		r.Name = n
		r.Parent = folder
	end
	local u = Instance.new("UnreliableRemoteEvent")
	u.Name = "Look"
	u.Parent = folder
	for _, n in FUNCTIONS do
		local r = Instance.new("RemoteFunction")
		r.Name = n
		r.Parent = folder
	end
	folder.Parent = ReplicatedStorage
else
	folder = ReplicatedStorage:WaitForChild("Net") :: Folder
end

function Net.event(name: string): RemoteEvent
	return folder:WaitForChild(name) :: RemoteEvent
end

function Net.unreliable(name: string): UnreliableRemoteEvent
	return folder:WaitForChild(name) :: UnreliableRemoteEvent
end

function Net.func(name: string): RemoteFunction
	return folder:WaitForChild(name) :: RemoteFunction
end

return Net
