--!strict
-- Server entry: collision groups, then the raid services.
local Physics = require(script.Parent.Physics)
Physics.setup()
local Weapons = require(script.Parent.Weapons)
local Raid = require(script.Parent.Raid)
local Weather = require(script.Parent.Weather)
Weapons.start()
Raid.start()
Weather.start()
Weather.posOf = Raid.posOf
Weather.hurt = function(p, dmg)
	Raid.hurt(p, dmg, { direct = true, fromName = "Storm", weaponId = "storm" })
end
Weather.protection = Raid.stormProtection
local okE, Enemies = pcall(require, script.Parent:FindFirstChild("Enemies"))
if okE and Enemies then
	Enemies.start()
	Weather.onCondition = Enemies.onCondition
end
local okL, Loot = pcall(require, script.Parent:FindFirstChild("Loot"))
if okL and Loot then
	Loot.start()
end
require(script.Parent.Actions).start()
require(script.Parent.Dress).start()
require(script.Parent.Breakables).start()
require(script.Parent.Hazards).start()
do
	local Grenades = require(script.Parent.Grenades)
	Grenades.start()
	if okE and Enemies then
		Grenades.hear = Enemies.hear
		Grenades.danger = Enemies.setDanger
	end
end
do
	local Cover = require(script.Parent.Cover)
	local flags = if okL and Loot then Loot.flags else nil
	Cover.onFlag = function(flag)
		if flags then
			flags[flag] = true
		end
		workspace:SetAttribute("Flag_" .. flag, true)
	end
	Cover.start(flags)
end
print("[Blockov] server ready")
