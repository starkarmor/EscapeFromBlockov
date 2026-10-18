--!strict
-- DamageZone hazards (the Ground Zero campfires, MapData.hazards): every 0.5 s, 1 fire damage ignoring armor to any
-- character whose body overlaps the zone sphere; a flame marks each one.
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local MapData = require(Shared.MapData)
local Weapons = require(script.Parent.Weapons)

local S = Units.S
local Hazards = {}

function Hazards.start()
	local folder = Instance.new("Folder")
	folder.Name = "Hazards"
	folder.Parent = Workspace
	local zones = {}
	for _, h in MapData.hazards or {} do
		local p = Instance.new("Part")
		p.Name = "Campfire"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.Transparency = 1
		p.Size = Vector3.one * 0.5
		p.Position = Vector3.new(h.x, math.max(0, h.y0 + 0.9), h.z) * S
		local fire = Instance.new("Fire")
		fire.Size = 4
		fire.Heat = 6
		fire.Parent = p
		local light = Instance.new("PointLight")
		light.Color = Color3.fromHex("#ffb070")
		light.Range = 14
		light.Brightness = 1.5
		light.Parent = p
		p.Parent = folder
		table.insert(zones, { h = h, t = 0 })
	end
	RunService.Heartbeat:Connect(function(dt)
		for _, z in zones do
			z.t += dt
			if z.t < z.h.every then
				continue
			end
			z.t = 0
			for _, t in Weapons.targets do
				if t.kind == "breakable" then
					continue
				end
				local tp = t.pos()
				if tp and (Vector2.new(tp.X, tp.Z) - Vector2.new(z.h.x, z.h.z)).Magnitude <= z.h.r + 0.3 then
					task.spawn(t.hurt, z.h.damage, { direct = z.h.ignoreArmor, fromName = "Campfire", element = "fire" })
				end
			end
		end
	end)
	print(string.format("[Blockov] %d hazard zones", #zones))
end

return Hazards
