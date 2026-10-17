--!strict
-- Visual dressing with the imported Creator Store assets (ReplicatedStorage/CreatorAssets, docs/creator-assets.json).
-- Only visuals change: every collider, sight blocker and gameplay value stays the generated map's. Missing assets are
-- skipped, so a fresh place without the import still plays with the block stand-ins.
--   trees:   the pine mesh on each terrain tree, sized to the web tree height (4.65 m x scale), random yaw; the trunk
--            collider stays (invisible), the stand-in leaves go
--   bushes:  bush meshes tiled along each foliage (fow) box; the box stays as the invisible sight blocker
--   guns:    the held gun model welded to every character's Weapon part (pistol / rifle / shotgun / SMG by gun id)
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Guns = require(Shared.Guns)

local S = Units.S
local Dress = {}
local assets = ReplicatedStorage:FindFirstChild("CreatorAssets")

local function template(name: string): Model?
	return assets and assets:FindFirstChild(name) :: Model?
end

--- a clone scaled so its bounding size along `axis` equals `target` studs
local function sized(name: string, target: number, axis: string?): Model?
	local t = template(name)
	if not t then
		return nil
	end
	local m = t:Clone()
	local size0 = m:GetAttribute("Size0") :: Vector3
	local ax = axis or "Y"
	local cur = (size0 :: any)[ax] :: number
	if cur > 0 then
		m:ScaleTo(target / cur)
	end
	return m
end

local function dressTrees(map: Instance)
	local trees = map:FindFirstChild("Trees")
	if not trees or not template("Pine") then
		return 0
	end
	local folder = Instance.new("Folder")
	folder.Name = "PineMeshes"
	local n = 0
	for _, tree in trees:GetChildren() do
		local trunk = tree:FindFirstChild("Trunk") :: BasePart?
		if not trunk then
			continue
		end
		local top = 0
		for _, p in tree:GetChildren() do
			if p:IsA("BasePart") then
				top = math.max(top, p.Position.Y + p.Size.Y / 2)
				if p.Name == "Leaves" then
					p:Destroy()
				end
			end
		end
		trunk.Transparency = 1
		local m = sized("Pine", math.max(2 * S, top), "Y")
		if m then
			m:PivotTo(CFrame.new(trunk.Position.X, 0, trunk.Position.Z) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
			m.Parent = folder
			n += 1
		end
	end
	folder.Parent = map
	return n
end

local function dressBushes(map: Instance)
	local bushes = map:FindFirstChild("Bushes")
	if not bushes or not template("Bush") then
		return 0
	end
	local folder = Instance.new("Folder")
	folder.Name = "BushMeshes"
	local n = 0
	for _, box in bushes:GetChildren() do
		if not box:IsA("BasePart") then
			continue
		end
		local size = box.Size
		local longX = size.X >= size.Z
		local len = if longX then size.X else size.Z
		local wid = if longX then size.Z else size.X
		local h = math.clamp(size.Y, 0.6 * S, 1.8 * S)
		local step = math.max(1.2 * S, h * 1.1)
		local count = math.max(1, math.floor(len / step + 0.5))
		local axis = if longX then box.CFrame.RightVector else box.CFrame.LookVector
		local base = box.Position - Vector3.new(0, size.Y / 2, 0)
		for i = 1, count do
			local off = (i - 0.5) / count * len - len / 2
			local m = sized("Bush", h, "Y")
			if m then
				local yaw = math.random() * math.pi * 2
				m:PivotTo(CFrame.new(base + axis * off) * CFrame.Angles(0, yaw, 0))
				-- keep the bush inside the box's width
				local _, bs = m:GetBoundingBox()
				local w = math.max(bs.X, bs.Z)
				if w > wid * 1.6 and wid > 0.5 then
					m:ScaleTo(m:GetScale() * math.max(0.5, (wid * 1.6) / w))
				end
				m.Parent = folder
				n += 1
			end
		end
		box.Transparency = 1
	end
	folder.Parent = map
	return n
end

-- rocks: the band nearest the floor (the web's 1.3 m stand-ins) becomes low-poly rock meshes tiled along each rect;
-- the grid colliders are untouched (rock blocks never collided)
local ROCK1 = Color3.fromRGB(0x8A, 0x84, 0x7A)
local function dressRocks(map: Instance): number
	local rocks = map:FindFirstChild("Rocks")
	if not rocks or not (template("Rock") or template("Rock2")) then
		return 0
	end
	local folder = Instance.new("Folder")
	folder.Name = "RockMeshes"
	local n = 0
	for _, r in rocks:GetChildren() do
		if not r:IsA("BasePart") or (r.Color.R - ROCK1.R) ^ 2 + (r.Color.G - ROCK1.G) ^ 2 > 0.002 then
			continue
		end
		local size = r.Size
		local longX = size.X >= size.Z
		local len = if longX then size.X else size.Z
		local wid = if longX then size.Z else size.X
		local step = math.max(wid, 1.2 * S)
		local count = math.clamp(math.floor(len / step + 0.5), 1, 12)
		local axis = if longX then r.CFrame.RightVector else r.CFrame.LookVector
		for i = 1, count do
			local off = (i - 0.5) / count * len - len / 2
			local name = if (n % 2 == 0 and template("Rock2")) then "Rock2" else "Rock"
			local m = sized(name, size.Y * 1.15, "Y")
			if m then
				local _, bs = m:GetBoundingBox()
				local foot = math.max(bs.X, bs.Z)
				local want = math.max(step, wid) * 1.25
				if foot > 0 then
					m:ScaleTo(m:GetScale() * want / foot)
				end
				local base = r.Position - Vector3.new(0, size.Y / 2, 0) + axis * off
				m:PivotTo(CFrame.new(base) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
				-- the rock bands' colours (the store mesh is near-white and read as snow)
				local tone = ({ Color3.fromRGB(0x8A, 0x84, 0x7A), Color3.fromRGB(0x76, 0x70, 0x67), Color3.fromRGB(0x9A, 0x94, 0x8A) })[math.random(1, 3)]
				for _, d in m:GetDescendants() do
					if d:IsA("MeshPart") then
						d.TextureID = "" -- the store texture overrides Color
					end
					if d:IsA("SurfaceAppearance") or d:IsA("Texture") or d:IsA("Decal") then
						d:Destroy()
					elseif d:IsA("BasePart") and d.Transparency < 1 then
						d.Color = tone
						d.Material = Enum.Material.Plastic
					end
				end
				m.Parent = folder
				n += 1
			end
		end
		r.Transparency = 1
	end
	folder.Parent = map
	return n
end

-- gun id -> model by the decoded item: shotguns (SHT / pellets), pistols (length <= 0.55 m), SMGs (0.7 m), rifles
-- (>= 0.9 m and every AK-family id)
local function gunModel(id: string): string
	local it = Guns.items[id]
	local f = it and it.fire
	if not f then
		return "GunPistol"
	end
	if f.caliber == "SHT" or (f.pellets or 1) > 1 then
		return "GunShotgun"
	end
	if string.sub(id, 1, 2) == "ak" then
		return "GunRifle"
	end
	local len = f.length or 0.5
	if len <= 0.55 then
		return "GunPistol"
	elseif len < 0.9 then
		return "GunSmg"
	end
	return "GunRifle"
end

--- weld the held gun's model to a character's Weapon part (replaces the previous one)
function Dress.arm(char: Model, gunId: string?)
	local weapon = char:FindFirstChild("Weapon") :: BasePart?
	if not weapon then
		return
	end
	local old = char:FindFirstChild("HeldModel")
	if old then
		old:Destroy()
	end
	if not gunId or char:GetAttribute("Held") ~= "gun" then
		weapon.Transparency = 0
		return
	end
	local it = Guns.items[gunId]
	local lenStuds = ((it and it.fire and it.fire.length) or 0.5) * S
	local m = sized(gunModel(gunId), lenStuds, "X")
	if not m then
		return
	end
	m.Name = "HeldModel"
	-- the model's long +X axis (muzzle) onto the Weapon part's +Z (the facing): a -90 deg turn about Y
	m:PivotTo(weapon.CFrame * CFrame.Angles(0, -math.pi / 2, 0))
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.Massless = true
			p.CanCollide = false
			p.CanQuery = false
			p.CastShadow = false
			local w = Instance.new("WeldConstraint")
			w.Part0 = weapon
			w.Part1 = p
			w.Parent = p
		end
	end
	m.Parent = char
	weapon.Transparency = 1
end

--- oil barrel look for Breakables (returns the visual model, nil when the asset is missing)
function Dress.barrel(at: CFrame, height: number): Model?
	local m = sized("Barrel", height, "Y")
	if m then
		m:PivotTo(at)
	end
	return m
end

function Dress.start()
	if not assets then
		print("[Canuckov] no CreatorAssets folder: block stand-ins kept (run tools/import_assets.py)")
		return
	end
	local map = Workspace:WaitForChild("GroundZero")
	local t = dressTrees(map)
	local b = dressBushes(map)
	local rk = dressRocks(map)
	print(string.format("[Canuckov] dressed %d pines, %d bushes, %d rocks", t, b, rk))
	-- held guns on every character (players: the player's Gun attribute; enemies: their own "Gun" attribute)
	local function watch(char: Model)
		local function refresh()
			local plr = Players:GetPlayerFromCharacter(char)
			local id = if plr then plr:GetAttribute("Gun") else char:GetAttribute("Gun")
			Dress.arm(char, if typeof(id) == "string" then id else nil)
		end
		char:GetAttributeChangedSignal("Held"):Connect(refresh)
		char:GetAttributeChangedSignal("Gun"):Connect(refresh)
		local plr = Players:GetPlayerFromCharacter(char)
		if plr then
			plr:GetAttributeChangedSignal("Gun"):Connect(function()
				if char.Parent then
					refresh()
				end
			end)
		end
		task.defer(refresh)
	end
	local chars = Workspace:WaitForChild("Characters")
	for _, c in chars:GetChildren() do
		if c:IsA("Model") then
			watch(c)
		end
	end
	chars.ChildAdded:Connect(function(c)
		if c:IsA("Model") then
			task.wait(0.1)
			watch(c)
		end
	end)
end

return Dress
