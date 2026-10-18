"""Import the Creator Store gun pack (docs/creator-assets.json "gunpack") into ReplicatedStorage/CreatorAssets/Guns of the
open place (Edit): every script deleted, each gun normalised to a Model whose long axis is +X (muzzle at +X after the
per-model flip in docs/creator-assets.json "gunFlip"), pivot at the bounding-box centre, attributes Size0 (bounding size)
and Src (the pack path). Usage: python3 tools/import_gunpack.py"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp import Studio
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = json.load(open(os.path.join(ROOT, 'docs/creator-assets.json')))
pack = spec['gunpack']
flip = spec.get('gunFlip', {})
s = Studio()
if 'Play' in s.call('get_studio_state')[0]:
    s.call('start_stop_play', is_start=False)
s.lua('Edit', 'local t=game.ServerStorage:FindFirstChild("ImportTmp") if t then t:Destroy() end t=Instance.new("Folder") t.Name="ImportTmp" t.Parent=game.ServerStorage return 1')
s.call('insert_asset', assetId=pack['id'], assetName='RAW_GunPack', parentPath='game.ServerStorage.ImportTmp')
FLIP = '{' + ','.join('[%s]=true' % json.dumps(k) for k, v in flip.items() if v) + '}'
print(s.lua('Edit', r'''
local FLIP = %s
local raw = game.ServerStorage.ImportTmp:FindFirstChild("RAW_GunPack")
if not raw then return "insert failed" end
local stripped = 0
for _, d in raw:GetDescendants() do if d:IsA("LuaSourceContainer") then d:Destroy() stripped += 1 end end
local assets = game.ReplicatedStorage:FindFirstChild("CreatorAssets")
local dest = assets:FindFirstChild("Guns") if dest then dest:Destroy() end
dest = Instance.new("Folder") dest.Name = "Guns" dest.Parent = assets
local n = 0
for _, cat in raw:GetChildren() do
	for _, g in cat:GetChildren() do
		if g:IsA("Model") and cat.Name ~= "Attachments" then
			local m = g:Clone()
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") then d.Anchored = true d.CanCollide = false d.CanQuery = false d.CanTouch = false d.Massless = true d.CastShadow = false end
			end
			-- the long axis of the bounding box becomes +X
			local cf, size = m:GetBoundingBox()
			local rot = cf.Rotation
			if size.Z >= size.X and size.Z >= size.Y then
				rot = rot * CFrame.Angles(0, math.pi / 2, 0)
			elseif size.Y >= size.X and size.Y >= size.Z then
				rot = rot * CFrame.Angles(0, 0, math.pi / 2)
			end
			-- the pack's muzzles point along -X after the long-axis turn: half a turn puts them on +X (gunFlip lists exceptions)
			if not FLIP[g.Name] then
				rot = rot * CFrame.Angles(0, math.pi, 0)
			end
			local centre = Instance.new("Part")
			centre.Name = "GunRoot"
			centre.Transparency = 1
			centre.Size = Vector3.new(0.1, 0.1, 0.1)
			centre.Anchored = true
			centre.CanCollide = false
			centre.CanQuery = false
			centre.CFrame = CFrame.new(cf.Position) * rot
			centre.Parent = m
			m.PrimaryPart = centre
			m:PivotTo(CFrame.new())
			local _, s2 = m:GetBoundingBox()
			m:SetAttribute("Size0", s2)
			m:SetAttribute("Src", cat.Name .. "/" .. g.Name)
			m.Name = g.Name
			m.Parent = dest
			n += 1
		end
	end
end
raw:Destroy()
return string.format("guns=%%d stripped=%%d", n, stripped)
''' % FLIP))
s.lua('Edit', 'game.ServerStorage.ImportTmp:Destroy() local t=game.ServerStorage:FindFirstChild("ScoutTmp") if t then t:Destroy() end return 1')
s.close()
