"""Import the Creator Store assets listed in docs/creator-assets.json into ReplicatedStorage/CreatorAssets of the open
Studio place (Edit). Strips every script, anchors, converts to a Model with a PrimaryPart at the bottom centre and
records the original bounding size (attribute "Size0") and longest axis ("Long").  Usage: python3 tools/import_assets.py
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp import Studio
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = json.load(open(os.path.join(ROOT, 'docs/creator-assets.json')))['assets']
s = Studio()
if 'Play' in s.call('get_studio_state')[0]:
    s.call('start_stop_play', is_start=False)
s.lua('Edit', 'local f=game.ReplicatedStorage:FindFirstChild("CreatorAssets") if not f then f=Instance.new("Folder") f.Name="CreatorAssets" f.Parent=game.ReplicatedStorage end local t=game.ServerStorage:FindFirstChild("ImportTmp") if t then t:Destroy() end t=Instance.new("Folder") t.Name="ImportTmp" t.Parent=game.ServerStorage return 1')
NORMALISE = r'''
local raw = game.ServerStorage.ImportTmp:FindFirstChild("RAW_%(name)s")
if not raw then return "insert failed" end
local dest = game.ReplicatedStorage.CreatorAssets
local old = dest:FindFirstChild("%(name)s") if old then old:Destroy() end
local m = Instance.new("Model") m.Name = "%(name)s"
local stripped = 0
for _, d in raw:GetDescendants() do if d:IsA("LuaSourceContainer") then d:Destroy() stripped += 1 end end
for _, c in raw:GetChildren() do c.Parent = m end
raw:Destroy()
local parts = 0
for _, d in m:GetDescendants() do
	if d:IsA("BasePart") then
		d.Anchored = true d.CanCollide = false d.CanQuery = false d.CanTouch = false d.Massless = true parts += 1
	end
end
local cf, size = m:GetBoundingBox()
local root = Instance.new("Part") root.Name = "AssetRoot" root.Transparency = 1 root.Anchored = true root.CanCollide = false root.CanQuery = false
root.Size = Vector3.new(0.2, 0.2, 0.2)
-- the bounding box is measured in the model's pivot frame: keep that frame so Size0 axes match the asset
root.CFrame = cf * CFrame.new(0, -size.Y / 2, 0)
root.Parent = m
m.PrimaryPart = root
m:PivotTo(CFrame.new())
m:SetAttribute("AssetId", "%(id)s")
m:SetAttribute("Size0", size)
local long = if size.X >= size.Y and size.X >= size.Z then "X" elseif size.Y >= size.Z then "Y" else "Z"
m:SetAttribute("Long", long)
m.Parent = dest
return string.format("%%s parts=%%d stripped=%%d size=(%%.2f,%%.2f,%%.2f) long=%%s", m.Name, parts, stripped, size.X, size.Y, size.Z, long)
'''
for name, a in spec.items():
    t, _ = s.call('insert_asset', assetId=a['id'], assetName='RAW_' + name, parentPath='game.ServerStorage.ImportTmp')
    print(s.lua('Edit', NORMALISE % {'name': name, 'id': a['id']}))
s.lua('Edit', 'game.ServerStorage.ImportTmp:Destroy() return 1')
s.close()
