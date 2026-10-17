--!strict
-- Server entry: collision groups, then the raid services.
local Physics = require(script.Parent.Physics)
Physics.setup()
local Weapons = require(script.Parent.Weapons)
local Raid = require(script.Parent.Raid)
Weapons.start()
Raid.start()
local okE, Enemies = pcall(require, script.Parent:FindFirstChild("Enemies"))
if okE and Enemies then
	Enemies.start()
end
local okL, Loot = pcall(require, script.Parent:FindFirstChild("Loot"))
if okL and Loot then
	Loot.start()
end
require(script.Parent.Actions).start()
require(script.Parent.Breakables).start()
print("[Canuckov] server ready")
