"""Import the enemy characters (Creator Store R15 models) listed under "npcs" in docs/creator-assets.json into
ReplicatedStorage/CreatorAssets/NPC_<kind> of the open Studio place (Edit). Every script is deleted before the model
leaves the isolated ServerStorage folder (several listings ship backdoor-pattern scripts), extra rigs in the package
are dropped, parts are unanchored and the Humanoid is kept so the server can clone it as a live NPC.
Usage: python3 tools/import_npcs.py
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp import Studio
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = json.load(open(os.path.join(ROOT, 'docs/creator-assets.json')))['npcs']
s = Studio()
if 'Play' in s.call('get_studio_state')[0]:
    s.call('start_stop_play', is_start=False)
s.lua('Edit', 'local f=game.ReplicatedStorage:FindFirstChild("CreatorAssets") if not f then f=Instance.new("Folder") f.Name="CreatorAssets" f.Parent=game.ReplicatedStorage end local t=game.ServerStorage:FindFirstChild("ImportTmp") if t then t:Destroy() end t=Instance.new("Folder") t.Name="ImportTmp" t.Parent=game.ServerStorage return 1')
NORMALISE = r'''
local raw = game.ServerStorage.ImportTmp:FindFirstChild("RAW_%(name)s")
if not raw then return "insert failed" end
local stripped = 0
for _, d in raw:GetDescendants() do if d:IsA("LuaSourceContainer") then d:Destroy() stripped += 1 end end
local dest = game.ReplicatedStorage.CreatorAssets
local old = dest:FindFirstChild("%(name)s") if old then old:Destroy() end
local rig
local kind = "%(kind)s"
if kind == "humanoid" then
	for _, h in raw:GetDescendants() do
		if h:IsA("Humanoid") and h.RigType == Enum.HumanoidRigType.R15 and h.Parent:IsA("Model") and h.Parent:FindFirstChild("HumanoidRootPart") then
			rig = h.Parent
			break
		end
	end
	if not rig then return "%(name)s: no R15 rig" end
	for _, d in rig:GetDescendants() do
		if d:IsA("BasePart") then d.Anchored = false end
		if d:IsA("Tool") or d:IsA("HopperBin") then d:Destroy() end
	end
	local hum = rig:FindFirstChildOfClass("Humanoid")
	if not hum:FindFirstChildOfClass("Animator") then Instance.new("Animator").Parent = hum end
	rig.PrimaryPart = rig.HumanoidRootPart
else
	-- a static creature model: one Model of anchored-free parts, pivoted at the bottom centre
	rig = Instance.new("Model")
	for _, c in raw:GetChildren() do c.Parent = rig end
	for _, d in rig:GetDescendants() do if d:IsA("BasePart") then d.Anchored = false d.CanCollide = false d.CanQuery = false d.Massless = true end end
	local cf, size = rig:GetBoundingBox()
	rig.WorldPivot = cf * CFrame.new(0, -size.Y / 2, 0)
	rig:SetAttribute("Size0", size)
end
rig.Name = "%(name)s"
rig:SetAttribute("AssetId", "%(id)s")
rig.Parent = dest
raw:Destroy()
local parts = 0
for _, d in rig:GetDescendants() do if d:IsA("BasePart") then parts += 1 end end
local _, size = rig:GetBoundingBox()
return string.format("%%s parts=%%d stripped=%%d size=(%%.2f,%%.2f,%%.2f)", rig.Name, parts, stripped, size.X, size.Y, size.Z)
'''
for name, a in spec.items():
    s.call('insert_asset', assetId=a['id'], assetName='RAW_' + name, parentPath='game.ServerStorage.ImportTmp')
    print(s.lua('Edit', NORMALISE % {'name': name, 'id': a['id'], 'kind': a.get('kind', 'humanoid')}))
s.lua('Edit', 'game.ServerStorage.ImportTmp:Destroy() return 1')
s.close()
