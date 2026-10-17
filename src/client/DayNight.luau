--!strict
-- The raid clock (08:00 start, 40x: a day is 36 real minutes) drives Lighting locally: bright toy day, warm dusk at
-- 18:00, navy night from 22:00 to 06:00 (art brief: night is navy, never black).
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)

local DayNight = {}
local player = Players.LocalPlayer
local DAY = { amb = Color3.fromRGB(140, 140, 153), bright = 2.5 }
local NIGHT = { amb = Color3.fromRGB(70, 82, 130), bright = 0.6 }

function DayNight.update()
	local secs = player:GetAttribute("RaidClock")
	if typeof(secs) ~= "number" then
		return
	end
	local h = (Config.Clock.start + secs * Config.Clock.scale / 3600) % 24
	Lighting.ClockTime = h
	-- night weight: 0 by day, 1 deep night, ramps around dusk / dawn
	local n = 0
	if h >= 22 or h < 5 then
		n = 1
	elseif h >= 18 then
		n = (h - 18) / 4
	elseif h < 6 then
		n = 1 - (h - 5)
	end
	Lighting.OutdoorAmbient = DAY.amb:Lerp(NIGHT.amb, n)
	Lighting.Brightness = DAY.bright + (NIGHT.bright - DAY.bright) * n
end

return DayNight
