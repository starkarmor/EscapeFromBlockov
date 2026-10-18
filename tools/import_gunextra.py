"""Import the extra held-weapon models (docs/creator-assets.json "gunExtra": weapons the 43-gun pack lacks) into
ReplicatedStorage/CreatorAssets/Guns, normalised like tools/import_gunpack.py: scripts deleted, a GunRoot PrimaryPart at
the bounding-box centre with the muzzle / arrow direction on +X and up on +Y, pivot at the origin, attributes Size0 and
Src (plus Upright for a bow: its limbs stay vertical). axis "long" turns the longest bbox axis to X, "depth" the axis
that is neither longest nor thinnest (a bow's draw direction); flip adds half a turn about Y.
Usage: python3 tools/import_gunextra.py"""
import json, os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mcp import Studio
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = json.load(open(os.path.join(ROOT, 'docs/creator-assets.json')))
s = Studio()
if 'Play' in s.call('get_studio_state')[0]:
    s.call('start_stop_play', is_start=False)
    time.sleep(2)
s.lua('Edit', 'local t=game.ServerStorage:FindFirstChild("ImportTmp") if t then t:Destroy() end t=Instance.new("Folder") t.Name="ImportTmp" t.Parent=game.ServerStorage return 1')
for e in spec['gunExtra']:
    s.call('insert_asset', assetId=e['id'], assetName='RAW_' + e['id'], parentPath='game.ServerStorage.ImportTmp')
    print(e['name'], s.lua('Edit', r'''
local e = game:GetService("HttpService"):JSONDecode(%s)
local raw = game.ServerStorage.ImportTmp:FindFirstChild("RAW_" .. e.id)
if not raw then return "insert failed" end
local stripped = 0
for _, d in raw:GetDescendants() do if d:IsA("LuaSourceContainer") then d:Destroy() stripped += 1 end end
local m = Instance.new("Model")
m.Name = e.name
for _, d in (if raw:IsA("Model") or raw:IsA("Folder") then raw:GetChildren() else { raw }) do d.Parent = m end
-- tools / accessories / sounds and anything without geometry go; the parts are kept with their welds
for _, d in m:GetDescendants() do
	if d:IsA("Sound") or d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("ClickDetector") or d:IsA("ProximityPrompt") then d:Destroy() end
end
for _, d in m:GetDescendants() do
	if d:IsA("BasePart") then d.Anchored = true d.CanCollide = false d.CanQuery = false d.CanTouch = false d.Massless = true d.CastShadow = false end
end
local cf, size = m:GetBoundingBox()
local axes = { { "X", size.X }, { "Y", size.Y }, { "Z", size.Z } }
table.sort(axes, function(a, b) return a[2] > b[2] end)
local want = if e.axis == "depth" then axes[2][1] else axes[1][1]
local rot = cf.Rotation
if want == "Z" then rot = rot * CFrame.Angles(0, math.pi / 2, 0) elseif want == "Y" then rot = rot * CFrame.Angles(0, 0, math.pi / 2) end
if e.upright then
	-- keep the limbs (the longest axis) vertical: roll the model about the new X until that axis is Y
	local probe = CFrame.new(cf.Position) * rot
	local long = axes[1][1]
	local lv = if long == "X" then cf.RightVector elseif long == "Y" then cf.UpVector else cf.LookVector
	if math.abs(probe.UpVector:Dot(lv)) < 0.7 then rot = rot * CFrame.Angles(math.pi / 2, 0, 0) end
end
if e.flip then rot = rot * CFrame.Angles(0, math.pi, 0) end
local root = Instance.new("Part")
root.Name = "GunRoot"
root.Transparency = 1
root.Size = Vector3.new(0.1, 0.1, 0.1)
root.Anchored = true
root.CanCollide = false
root.CanQuery = false
root.CFrame = CFrame.new(cf.Position) * rot
root.Parent = m
m.PrimaryPart = root
m:PivotTo(CFrame.new())
local _, s2 = m:GetBoundingBox()
m:SetAttribute("Size0", s2)
m:SetAttribute("Src", "Extra/" .. e.name .. " (" .. e.id .. ")")
if e.upright then m:SetAttribute("Upright", true) end
local dest = game.ReplicatedStorage.CreatorAssets.Guns
local old = dest:FindFirstChild(e.name) if old then old:Destroy() end
m.Parent = dest
raw:Destroy()
return string.format("size0=%%.2f,%%.2f,%%.2f stripped=%%d", s2.X, s2.Y, s2.Z, stripped)
''' % json.dumps(json.dumps(e))))
s.lua('Edit', 'game.ServerStorage.ImportTmp:Destroy() local r=workspace:FindFirstChild("ScoutRow") if r then r:Destroy() end return 1')
s.close()
