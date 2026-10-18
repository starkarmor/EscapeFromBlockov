--!strict
-- Explosive oil barrels (src/game/Breakables.ts, ExplosionManager.CreateExplosion): each spawns with its decoded chance
-- (0.7), 22 HP, takes bullets / melee / blasts from anyone; at 0 it explodes: flat 45 damage (AP 1, armor break 1) to every
-- character within 3.6 m once, the shooter included, chaining into other barrels; the body stump keeps blocking.
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Units = require(Shared.Units)
local Net = require(Shared.Net)
local MapData = require(Shared.MapData)
local Weapons = require(script.Parent.Weapons)

local S = Units.S
local Breakables = {}

function Breakables.explode(at: Vector3, radius: number, damage: number, info: any)
	-- team 7: the barrel hurts everyone, the shooter included (queued after the current blast)
	require(script.Parent.Explosion).blast(at.X, at.Z, radius, damage, { team = 7, ap = info.ap or 1, armorBreak = info.armorBreak or 1, from = info.from, fromName = "Explosion", shake = 1 })
end

function Breakables.start()
	local folder = Instance.new("Folder")
	folder.Name = "Breakables"
	folder.Parent = Workspace
	local n = 0
	for _, b in MapData.breakables or {} do
		if math.random() > (b.chance or 1) then
			continue
		end
		n += 1
		local size = b.size or { 0.79, 1.37, 0.79 }
		local barrel = Instance.new("Part")
		barrel.Name = "OilBarrel"
		barrel.Shape = Enum.PartType.Cylinder
		barrel.Anchored = true
		barrel.Size = Vector3.new(size[2], size[1], size[1]) * S
		barrel.CFrame = CFrame.new(b.x * S, size[2] * S / 2, b.z * S) * CFrame.Angles(0, 0, math.pi / 2)
		barrel.Color = Color3.fromHex("#F34543")
		barrel.Material = Enum.Material.Plastic
		barrel.CollisionGroup = "M27"
		barrel:SetAttribute("Cat", 27)
		local band = barrel:Clone()
		band.Size = Vector3.new(0.12 * S, size[1] * S * 1.04, size[1] * S * 1.04)
		band.Color = Color3.fromHex("#FFF8E9")
		band.CanCollide = false
		band.CanQuery = false
		band.CFrame = barrel.CFrame
		band.Parent = barrel
		barrel.Parent = folder
		-- the Creator Store barrel look when imported (server/Dress.luau); the cylinder stays as the collider
		local look = require(script.Parent.Dress).barrel(CFrame.new(b.x * S, 0, b.z * S), size[2] * S)
		if look then
			look.Parent = barrel
			barrel.Transparency = 1
			band.Transparency = 1
		end
		local hp = b.hp
		local key = {}
		local dead = false
		Weapons.targets[key] = {
			kind = "breakable",
			team = 7,
			pos = function()
				return if dead then nil else Vector3.new(b.x, 0, b.z)
			end,
			radius = size[1] / 2 + 0.1,
			height = size[2],
			hurt = function(dmg, info)
				if dead then
					return false
				end
				hp -= dmg
				if hp <= 15 then
					barrel.Color = Color3.fromHex("#FF8A2B") -- dangerHealth: the burning look
				end
				if hp <= 0 then
					dead = true
					Weapons.targets[key] = nil
					-- the body stump keeps blocking characters
					barrel.Size = Vector3.new(0.25 * S, size[1] * S, size[1] * S)
					barrel.CFrame = CFrame.new(b.x * S, 0.125 * S, b.z * S) * CFrame.Angles(0, 0, math.pi / 2)
					barrel.Color = Color3.fromHex("#2A2420")
					barrel.Transparency = 0
					band:Destroy()
					if look then
						look:Destroy()
					end
					task.delay(0.05, Breakables.explode, Vector3.new(b.x, 0, b.z), b.radius, b.damage, { ap = b.ap, armorBreak = b.armorBreak, from = info and info.from })
					return true
				end
				return false
			end,
			ref = barrel,
		}
	end
	print(string.format("[Blockov] %d explosive barrels", n))
end

return Breakables
