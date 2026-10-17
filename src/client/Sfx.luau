--!strict
-- Sound effects (Creator Store free audio; ids listed in docs/port-ledger.json). Positional sounds play from a world
-- point (metres), 2D sounds from SoundService. Volumes are tuned so gunfire leads, footsteps sit low.
local SoundService = game:GetService("SoundService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Units = require(ReplicatedStorage:WaitForChild("Shared").Units)

local S = Units.S
local Sfx = {}
local IDS: { [string]: { id: string, vol: number, pitch: { number }? } } = {
	pistol = { id = "800000246", vol = 0.55, pitch = { 0.95, 1.05 } },
	rifle = { id = "97312793139079", vol = 0.5, pitch = { 0.95, 1.05 } },
	reload = { id = "8302576808", vol = 0.5 },
	impact = { id = "131554175554758", vol = 0.35, pitch = { 0.9, 1.1 } },
	hitmarker = { id = "3748776946", vol = 0.45 },
	swoosh = { id = "12222200", vol = 0.6, pitch = { 0.9, 1.1 } },
	step = { id = "129956418693357", vol = 0.18, pitch = { 0.9, 1.1 } },
	honk = { id = "4139639790", vol = 0.6, pitch = { 0.85, 1.15 } },
	hurt = { id = "95887429435303", vol = 0.5, pitch = { 1.1, 1.3 } },
	door = { id = "7274931838", vol = 0.5 },
	bandage = { id = "9113266339", vol = 0.5 },
	pickup = { id = "4612374393", vol = 0.4 },
	click = { id = "87437544236708", vol = 0.4 },
	extract = { id = "1844016113", vol = 0.6 },
}

local holder = Instance.new("Part")
holder.Name = "SfxHolder"
holder.Anchored = true
holder.CanCollide = false
holder.CanQuery = false
holder.Transparency = 1
holder.Size = Vector3.one * 0.1
holder.Parent = Workspace

local function make(name: string): Sound?
	local d = IDS[name]
	if not d then
		return nil
	end
	local snd = Instance.new("Sound")
	snd.SoundId = "rbxassetid://" .. d.id
	snd.Volume = d.vol
	if d.pitch then
		snd.PlaybackSpeed = d.pitch[1] + (d.pitch[2] - d.pitch[1]) * math.random()
	end
	return snd
end

--- 2D sound (UI, own actions)
function Sfx.play(name: string)
	local snd = make(name)
	if not snd then
		return
	end
	snd.Parent = SoundService
	snd:Play()
	snd.Ended:Once(function()
		snd:Destroy()
	end)
	task.delay(8, function()
		if snd.Parent then
			snd:Destroy()
		end
	end)
end

--- 3D sound at a world point (metres)
function Sfx.at(name: string, at: Vector3, range: number?)
	local snd = make(name)
	if not snd then
		return
	end
	local a = Instance.new("Attachment")
	a.WorldPosition = Vector3.new(at.X * S, (at.Y + 1) * S, at.Z * S)
	a.Parent = holder
	snd.RollOffMode = Enum.RollOffMode.InverseTapered
	snd.RollOffMinDistance = 6 * S
	snd.RollOffMaxDistance = (range or 40) * S
	snd.Parent = a
	snd:Play()
	task.delay(8, function()
		a:Destroy()
	end)
end

-- preload so the first shot is not late
task.spawn(function()
	local list = {}
	for name in IDS do
		local snd = make(name)
		if snd then
			snd.Parent = holder
			table.insert(list, snd)
		end
	end
	pcall(function()
		game:GetService("ContentProvider"):PreloadAsync(list)
	end)
end)

return Sfx
