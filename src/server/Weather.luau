--!strict
-- The game clock, weather and storm (Game.clockInfo, src/game/Weather.ts; spec docs/weather-night-enemies-spec.md).
--   Clock: game minutes, +40 / 60 per real second (CLOCK_SCALE 40), from the first deploying player's profile clock
--   (default 08:00 day 0); saved back to every profile.
--   Weather: WeatherManager.M_GetWeather: the storm stage first, then the Perlin precipitation thresholds (Rainy > 0.68,
--   Cloudy > 0.66), Unity Mathf.PerlinNoise ported bit for bit (single precision after every operation).
--   Storm: every 14400 min the last 1440 are the storm: Stage I 12 h then Stage II 12 h; outside a shelter a player whose
--   storm protection is below the stage's need gains a layer every 3 / 1.5 s (max 12, all gone 5 s after the last) and
--   loses layers x 1 / 2 HP per second, armor ignored.
--   TimeOfDayPost [angle, dist, sense] factors blend over 8 s (smoothstep); the AI sight angle uses the angle factor.
--   Published on Workspace: ClockMin, Weather, StormPhase, Night, Dusk, Rain, TodAngle / TodDist / TodSense.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapData = require(Shared.MapData)

local Weather = {}

local CLOCK_SCALE = 40
local STORM_START = 9 * 1440
local STORM_CYCLE = STORM_START + 2 * 12 * 60
local STAGES = { { every = 3, need = 0.9, dps = 1 }, { every = 1.5, need = 1.9, dps = 2 } }
local LAYER_SECS, MAX_LAYERS = 5, 12
local TOD_BLEND = 8
local P = { cloudy = 0.66, rainy = 0.68, frequency = 0.05, offset = 0.13, contrast = 1.17 }

-- single precision like the native code (Math.fround)
local fb = buffer.create(4)
local function f32(x: number): number
	buffer.writef32(fb, 0, x)
	return buffer.readf32(fb, 0)
end

-- stylua: ignore
local PERM_BASE = {151,160,137,91,90,15,131,13,201,95,96,53,194,233,7,225,140,36,103,30,69,142,8,99,37,240,21,10,23,190,6,148,247,120,234,75,0,26,197,62,94,252,219,203,117,35,11,32,57,177,33,88,237,149,56,87,174,20,125,136,171,168,68,175,74,165,71,134,139,48,27,166,77,146,158,231,83,111,229,122,60,211,133,230,220,105,92,41,55,46,245,40,244,102,143,54,65,25,63,161,1,216,80,73,209,76,132,187,208,89,18,169,200,196,135,130,116,188,159,86,164,100,109,198,173,186,3,64,52,217,226,250,124,123,5,202,38,147,118,126,255,82,85,212,207,206,59,227,47,16,58,17,182,189,28,42,223,183,170,213,119,248,152,2,44,154,163,70,221,153,101,155,167,43,172,9,129,22,39,253,19,98,108,110,79,113,224,232,178,185,112,104,218,246,97,228,251,34,242,193,238,210,144,12,191,179,162,241,81,51,145,235,249,14,239,107,49,192,214,31,181,199,106,157,184,84,204,176,115,121,50,45,127,4,150,254,138,236,205,93,222,114,67,29,24,72,243,141,128,195,78,66,215,61,156,180}
local PERM = table.create(512, 0)
for i = 0, 511 do
	PERM[i + 1] = PERM_BASE[bit32.band(i, 255) + 1]
end
local function perm(i: number): number
	return PERM[i + 1]
end
local function fade(tIn: number): number
	local t = math.min(1, tIn)
	local t3 = f32(f32(t * t) * t)
	return f32(f32(f32(f32(f32(t * 6) - 15) * t) + 10) * t3)
end
local function lerp(t: number, a: number, b: number): number
	return f32(f32(f32(b - a) * t) + a)
end
local function grad(hash: number, x: number, y: number): number
	local h = bit32.band(hash, 15)
	local u = if h < 8 then x else y
	local v = if h < 4 then y elseif h == 12 or h == 14 then x else 0
	return f32((if bit32.band(h, 2) == 0 then v else -v) + (if bit32.band(h, 1) == 0 then u else -u))
end

--- Unity Mathf.PerlinNoise(x, y)
function Weather.unityPerlin(xIn: number, yIn: number): number
	local x = math.abs(f32(xIn))
	local y = math.abs(f32(yIn))
	local fx = if x >= 0 then math.floor(x) else math.ceil(x)
	local fy = if y >= 0 then math.floor(y) else math.ceil(y)
	local X = bit32.band(fx, 255)
	local Y = bit32.band(fy, 255)
	x = f32(x - fx)
	y = f32(y - fy)
	local u = fade(x)
	local v = fade(y)
	local A = perm(X) + Y
	local AA = perm(A)
	local AB = perm(A + 1)
	local B = perm(X + 1) + Y
	local BA = perm(B)
	local BB = perm(B + 1)
	local x1 = f32(x - 1)
	local y1 = f32(y - 1)
	local n = lerp(v, lerp(u, grad(perm(AA), x, y), grad(perm(BA), x1, y)), lerp(u, grad(perm(AB), x, y1), grad(perm(BB), x1, y1)))
	return f32(f32(n + f32(0.69)) / f32(1.483))
end

function Weather.precipitation(clockMin: number, seed: number): number
	local days = math.floor(clockMin / 1440)
	local inDay = clockMin - days * 1440
	local hours = math.floor(inDay / 60)
	local minutes = math.floor(inDay - hours * 60)
	local x = f32(f32(f32((days % 3650) * 24) + hours + f32(minutes / 60)) * f32(P.frequency))
	local y = f32(seed + math.floor(days / 3650))
	local p = f32((Weather.unityPerlin(x, y) + Weather.unityPerlin(f32(f32(x + 0.5) + f32(123.4)), f32(y - f32(567.8)))) / 2)
	local v = f32(f32(f32(p - 0.5) * f32(P.contrast)) + 0.5 + f32(P.offset))
	return math.clamp(v, 0, 1)
end

function Weather.weatherAt(clockMin: number, seed: number, stormLevel: number): string
	if stormLevel > 0 then
		return "Storm"
	end
	local p = Weather.precipitation(clockMin, seed)
	if p > P.rainy then
		return "Rainy"
	elseif p > P.cloudy then
		return "Cloudy"
	end
	return "Sunny"
end

local function todPost(weather: string, hour: number, stage: number): { number }
	if stage >= 2 then
		return { 0.6, 0.6, 0.6 }
	elseif stage == 1 or weather == "Storm" then
		return { 0.8, 0.8, 0.8 }
	end
	local phase = if hour >= 22 or hour < 6 then "night" elseif hour >= 18 then "dusk" else "day"
	if weather == "Sunny" then
		return if phase == "night" then { 0.4, 0.4, 0.5 } else { 1, 1, 1 }
	end
	return if phase == "night" then { 0.35, 0.35, 0.4 } elseif phase == "dusk" then { 0.7, 0.7, 0.7 } else { 0.8, 0.8, 0.8 }
end

-- state
Weather.clock = 8 * 60
Weather.seed = 0
Weather.started = false
Weather.weather = "Sunny"
Weather.stage = 0
Weather.night = false
Weather.dusk = false
Weather.tod = { 1, 1, 1 }
local todFrom, todTo, todT = { 1, 1, 1 }, { 1, 1, 1 }, TOD_BLEND
Weather.onCondition = nil :: ((string) -> ())? -- Enemies: night / rain / storm spawners (once per raid world)
Weather.hurt = nil :: ((Player, number) -> ())? -- Raid: storm damage (armor ignored)
Weather.protection = nil :: ((Player) -> number)? -- Raid: worn storm protection
Weather.posOf = nil :: ((Player) -> Vector3?)?
local fired: { [string]: boolean } = {}
local layers: { [Player]: { n: number, addT: number, last: number } } = {}

--- the world clock starts from the first deploying player's profile (clock minutes, weather seed)
function Weather.begin(clockMin: number?, seed: number?)
	if Weather.started then
		return
	end
	Weather.started = true
	Weather.clock = clockMin or 8 * 60
	Weather.seed = seed or 0
end

function Weather.hour(): number
	return (Weather.clock / 60) % 24
end

local CaveB = require(Shared.CaveData).bounds
local function sheltered(p: Vector3): boolean
	-- indoor sub-scenes shelter (the cave), then the building footprints
	if p.X >= CaveB.minX and p.X <= CaveB.maxX and p.Z >= CaveB.minZ and p.Z <= CaveB.maxZ then
		return true
	end
	for _, b in MapData.shelters or {} do
		if p.X >= b.minX and p.X <= b.maxX and p.Z >= b.minZ and p.Z <= b.maxZ then
			return true
		end
	end
	return false
end

local pubT = 0
local function step(dt: number)
	if not Weather.started then
		return
	end
	Weather.clock += dt * CLOCK_SCALE / 60
	local c = Weather.clock
	local hour = Weather.hour()
	local cyc = c % STORM_CYCLE
	local storm = cyc >= STORM_START
	Weather.stage = if not storm then 0 elseif cyc - STORM_START < 12 * 60 then 1 else 2
	Weather.night = hour >= 22 or hour < 6
	Weather.dusk = hour >= 18 and hour < 22
	Weather.weather = Weather.weatherAt(c, Weather.seed, Weather.stage)
	-- TimeOfDayPost blend (a new target waits for the running blend)
	local target = todPost(Weather.weather, hour, Weather.stage)
	todT += dt
	if todT >= TOD_BLEND and (target[1] ~= todTo[1] or target[2] ~= todTo[2] or target[3] ~= todTo[3]) then
		todFrom = table.clone(Weather.tod)
		todTo = target
		todT = 0
	end
	local s = math.clamp(todT / TOD_BLEND, 0, 1)
	local w = s * s * (3 - 2 * s)
	for i = 1, 3 do
		Weather.tod[i] = todFrom[i] + (todTo[i] - todFrom[i]) * w
	end
	-- conditional spawners, once each
	local function cond(name: string, on: boolean)
		if on and not fired[name] then
			fired[name] = true
			if Weather.onCondition then
				Weather.onCondition(name)
			end
		end
	end
	cond("night", Weather.night)
	cond("rain", Weather.weather == "Rainy")
	cond("storm", Weather.stage > 0)
	-- storm damage
	if Weather.stage > 0 then
		local st = STAGES[Weather.stage]
		for _, p in Players:GetPlayers() do
			local pos = Weather.posOf and Weather.posOf(p)
			local prot = Weather.protection and Weather.protection(p) or 0
			local l = layers[p] or { n = 0, addT = 0, last = -math.huge }
			layers[p] = l
			local exposed = pos ~= nil and not sheltered(pos) and prot < st.need
			p:SetAttribute("Distortion", exposed or nil)
			if exposed then
				l.addT += dt
				if l.addT >= st.every then
					l.addT = 0
					l.n = math.min(MAX_LAYERS, l.n + 1)
					l.last = os.clock()
				end
			end
			if os.clock() - l.last > LAYER_SECS then
				l.n = 0
			end
			p:SetAttribute("StormLayers", if l.n > 0 then l.n else nil)
			if l.n > 0 and Weather.hurt then
				Weather.hurt(p, l.n * st.dps * dt)
			end
		end
	end
	pubT -= dt
	if pubT <= 0 then
		pubT = 0.1
		Workspace:SetAttribute("ClockMin", c)
		Workspace:SetAttribute("Weather", Weather.weather)
		Workspace:SetAttribute("StormPhase", Weather.stage)
		Workspace:SetAttribute("Night", Weather.night)
		Workspace:SetAttribute("Dusk", Weather.dusk)
		Workspace:SetAttribute("Rain", Weather.weather == "Rainy")
		Workspace:SetAttribute("TodAngle", Weather.tod[1])
		Workspace:SetAttribute("TodDist", Weather.tod[2])
		Workspace:SetAttribute("TodSense", Weather.tod[3])
	end
end

function Weather.start()
	RunService.Heartbeat:Connect(step)
	if RunService:IsStudio() then
		-- Studio test fixture: Workspace attribute DevClock = game minutes jumps the clock
		Workspace:GetAttributeChangedSignal("DevClock"):Connect(function()
			local v = Workspace:GetAttribute("DevClock")
			if typeof(v) == "number" then
				Weather.started = true
				Weather.clock = v
				todT = TOD_BLEND
			end
		end)
	end
end

return Weather
