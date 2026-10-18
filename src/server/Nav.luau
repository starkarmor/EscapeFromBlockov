--!strict
-- The decoded Ground Zero navmesh and the web's path search, 1:1 with src/game/Nav.ts (AstarPath recast graph):
--   nodes = triangles, A* between triangle centres (2D, Euclidean heuristic to the end point), 30000 expansions max;
--   StartEndModifier ClosestOnNode on both ends; RaycastModifier "Medium" (greedy, subdivide 3 + reverse + greedy,
--   reverse) with graph linecasts. Metres in the web / map frame (x, z ground; y height). Triangle ids are 1-based here.
local NavData = require(script.Parent.gen.NavData)

local Nav = {}

local EPS = 1e-7
local BS = 4 -- spatial hash bucket (m)
local MAX_EXPAND = 30000
local MAX_NEAREST = 100
local RINGS = { 4, 8, 16, 32, 64, MAX_NEAREST }

local NT = NavData.tris
local vx: { number }, vz: { number }, vy: { number } = {}, {}, {}
local t: { number } = {} -- 3 per triangle, 1-based vertex ids
local cx: { number }, cz: { number }, cy: { number } = {}, {}, {}
local adj: { number } = {} -- 3 per triangle: the neighbour across edge k (vertex k -> k+1), 0 = open
local bucket: { [number]: { number } } = {}

-- base64 -> buffer
local function b64decode(s: string): buffer
	local map = table.create(256, -1)
	local abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, 64 do
		map[string.byte(abc, i) + 1] = i - 1
	end
	local n = #s
	local pad = 0
	if string.byte(s, n) == 61 then
		pad += 1
	end
	if string.byte(s, n - 1) == 61 then
		pad += 1
	end
	local out = buffer.create(n // 4 * 3 - pad)
	local o = 0
	local size = buffer.len(out)
	for i = 1, n, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = bit32.bor(bit32.lshift(map[a + 1], 18), bit32.lshift(map[b + 1], 12), bit32.lshift(math.max(0, map[(c or 61) + 1]), 6), math.max(0, map[(d or 61) + 1]))
		if o < size then
			buffer.writeu8(out, o, bit32.rshift(v, 16))
		end
		if o + 1 < size then
			buffer.writeu8(out, o + 1, bit32.band(bit32.rshift(v, 8), 255))
		end
		if o + 2 < size then
			buffer.writeu8(out, o + 2, bit32.band(v, 255))
		end
		o += 3
	end
	return out
end

local function build()
	local raw = b64decode(NavData.data)
	local nv = NavData.verts
	for i = 0, nv - 1 do
		vx[i + 1] = buffer.readi32(raw, i * 12) / 100
		vz[i + 1] = buffer.readi32(raw, i * 12 + 4) / 100
		vy[i + 1] = buffer.readi32(raw, i * 12 + 8) / 100
	end
	local base = nv * 12
	for i = 0, NT * 3 - 1 do
		t[i + 1] = buffer.readu16(raw, base + i * 2) + 1
	end
	local edges: { [number]: number } = {}
	for i = 1, NT do
		local a, b, c = t[i * 3 - 2], t[i * 3 - 1], t[i * 3]
		cx[i] = (vx[a] + vx[b] + vx[c]) / 3
		cz[i] = (vz[a] + vz[b] + vz[c]) / 3
		cy[i] = (vy[a] + vy[b] + vy[c]) / 3
		adj[i * 3 - 2], adj[i * 3 - 1], adj[i * 3] = 0, 0, 0
		for k = 0, 2 do
			local p = t[i * 3 - 2 + k]
			local q = t[i * 3 - 2 + (k + 1) % 3]
			local key = if p < q then p * 65537 + q else q * 65537 + p
			local o = edges[key]
			if o then
				adj[i * 3 - 2 + k] = (o - 1) // 3 + 1
				adj[o] = i
			else
				edges[key] = i * 3 - 2 + k
			end
		end
		-- spatial hash over the triangle's x/z bounds
		local x0, x1 = math.min(vx[a], vx[b], vx[c]), math.max(vx[a], vx[b], vx[c])
		local z0, z1 = math.min(vz[a], vz[b], vz[c]), math.max(vz[a], vz[b], vz[c])
		for gx = math.floor(x0 / BS), math.floor(x1 / BS) do
			for gz = math.floor(z0 / BS), math.floor(z1 / BS) do
				local key = gx * 100003 + gz
				local l = bucket[key]
				if not l then
					l = {}
					bucket[key] = l
				end
				table.insert(l, i)
			end
		end
	end
end

local function inside(i: number, x: number, z: number): boolean
	local pos, neg = false, false
	for k = 0, 2 do
		local a = t[i * 3 - 2 + k]
		local b = t[i * 3 - 2 + (k + 1) % 3]
		local c = (vx[b] - vx[a]) * (z - vz[a]) - (vz[b] - vz[a]) * (x - vx[a])
		if c > EPS then
			pos = true
		elseif c < -EPS then
			neg = true
		end
	end
	return not (pos and neg)
end

--- the closest point of triangle i to (x, z)
local function closest(i: number, x: number, z: number): (number, number)
	if inside(i, x, z) then
		return x, z
	end
	local bx, bz, bd = cx[i], cz[i], math.huge
	for k = 0, 2 do
		local a = t[i * 3 - 2 + k]
		local b = t[i * 3 - 2 + (k + 1) % 3]
		local ex, ez = vx[b] - vx[a], vz[b] - vz[a]
		local l2 = ex * ex + ez * ez
		if l2 == 0 then
			l2 = 1
		end
		local u = math.clamp(((x - vx[a]) * ex + (z - vz[a]) * ez) / l2, 0, 1)
		local px, pz = vx[a] + ex * u, vz[a] + ez * u
		local d = (px - x) ^ 2 + (pz - z) ^ 2
		if d < bd then
			bd, bx, bz = d, px, pz
		end
	end
	return bx, bz
end

--- the triangle under (x, z) (the layer nearest hintY, else the lowest), else the nearest within 100 m; 0 = none
function Nav.locate(x: number, z: number, hintY: number?): number
	local best, bestDy = 0, math.huge
	local l = bucket[math.floor(x / BS) * 100003 + math.floor(z / BS)]
	if l then
		for _, i in l do
			if inside(i, x, z) then
				local dy = if hintY == nil then cy[i] else math.abs(cy[i] - hintY)
				if dy < bestDy then
					bestDy, best = dy, i
				end
			end
		end
	end
	if best > 0 then
		return best
	end
	for _, r in RINGS do
		local bd = r * r
		for gx = math.floor((x - r) / BS), math.floor((x + r) / BS) do
			for gz = math.floor((z - r) / BS), math.floor((z + r) / BS) do
				local b = bucket[gx * 100003 + gz]
				if b then
					for _, i in b do
						local px, pz = closest(i, x, z)
						local d = (px - x) ^ 2 + (pz - z) ^ 2
						if d < bd then
							bd, best = d, i
						end
					end
				end
			end
		end
		if best > 0 then
			return best
		end
	end
	return 0
end

function Nav.height(i: number): number
	return cy[i]
end

--- NavmeshBase.Linecast: walk the triangles the segment crosses; leaving through an open edge is a hit
function Nav.clear(ax: number, az: number, bx: number, bz: number): boolean
	local i = Nav.locate(ax, az)
	if i == 0 then
		return false
	end
	local from = -1
	local rx, rz = bx - ax, bz - az
	for _ = 1, 4096 do
		if inside(i, bx, bz) then
			return true
		end
		local nextI, bestT = -2, -1
		for k = 0, 2 do
			local m = adj[i * 3 - 2 + k]
			if not (m == from and m > 0) then
				local a = t[i * 3 - 2 + k]
				local b = t[i * 3 - 2 + (k + 1) % 3]
				local sx, sz = vx[b] - vx[a], vz[b] - vz[a]
				local den = rx * sz - rz * sx
				if math.abs(den) >= 1e-12 then
					local qx, qz = vx[a] - ax, vz[a] - az
					local tt = (qx * sz - qz * sx) / den
					local uu = (qx * rz - qz * rx) / den
					if not (uu < -1e-6 or uu > 1 + 1e-6 or tt < -1e-6) and tt > bestT then
						bestT, nextI = tt, m
					end
				end
			end
		end
		if nextI <= 0 then
			return false
		end
		from, i = i, nextI
	end
	return false
end

-- binary heap keyed by f
local hIds: { number }, hKeys: { number } = {}, {}
local hn = 0
local function hpush(id: number, key: number)
	hn += 1
	local i = hn
	while i > 1 do
		local p = i // 2
		if hKeys[p] <= key then
			break
		end
		hIds[i], hKeys[i] = hIds[p], hKeys[p]
		i = p
	end
	hIds[i], hKeys[i] = id, key
end
local function hpop(): number
	local top = hIds[1]
	local lastId, lastKey = hIds[hn], hKeys[hn]
	hn -= 1
	if hn > 0 then
		local i = 1
		while true do
			local l = 2 * i
			if l > hn then
				break
			end
			local r = l + 1
			local c = if r <= hn and hKeys[r] < hKeys[l] then r else l
			if hKeys[c] >= lastKey then
				break
			end
			hIds[i], hKeys[i] = hIds[c], hKeys[c]
			i = c
		end
		hIds[i], hKeys[i] = lastId, lastKey
	end
	return top
end

local seen: { number } = {}
local gScore: { number } = {}
local parent: { number } = {}
local stamp = 0

local function astar(s: number, goal: number, bx: number, bz: number): { number }?
	stamp += 1
	hn = 0
	seen[s] = stamp
	gScore[s] = 0
	parent[s] = 0
	hpush(s, math.sqrt((cx[s] - bx) ^ 2 + (cz[s] - bz) ^ 2))
	local expanded = 0
	while hn > 0 do
		local n = hpop()
		if n == goal then
			local out = {}
			local k = n
			while k > 0 do
				table.insert(out, 1, k)
				k = parent[k]
			end
			return out
		end
		expanded += 1
		if expanded > MAX_EXPAND then
			return nil
		end
		local gn = gScore[n]
		local nx, nz = cx[n], cz[n]
		for k = 0, 2 do
			local m = adj[n * 3 - 2 + k]
			if m > 0 then
				local ng = gn + math.sqrt((cx[m] - nx) ^ 2 + (cz[m] - nz) ^ 2)
				if not (seen[m] == stamp and ng >= gScore[m]) then
					seen[m] = stamp
					gScore[m] = ng
					parent[m] = n
					hpush(m, ng + math.sqrt((cx[m] - bx) ^ 2 + (cz[m] - bz) ^ 2))
				end
			end
		end
	end
	return nil
end

local function greedy(points: { Vector2 }): { Vector2 }
	local out = {}
	local n = #points
	local i = 1
	while i <= n do
		local a = points[i]
		table.insert(out, a)
		local mn, mx = 1, 2
		while true do
			local j = i + mx
			if j > n then
				mx = n - i + 1
				break
			end
			if not Nav.clear(a.X, a.Y, points[j].X, points[j].Y) then
				break
			end
			mn = mx
			mx *= 2
		end
		while mn + 1 < mx do
			local mid = (mn + mx) // 2
			local p = points[i + mid]
			if Nav.clear(a.X, a.Y, p.X, p.Y) then
				mn = mid
			else
				mx = mid
			end
		end
		i += mn
	end
	return out
end

local function subdivide(points: { Vector2 }, parts: number): { Vector2 }
	local out = {}
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		for k = 0, parts - 1 do
			table.insert(out, a + (b - a) * (k / parts))
		end
	end
	if #points > 0 then
		table.insert(out, points[#points])
	end
	return out
end

local function reverse(p: { Vector2 }): { Vector2 }
	local out = table.create(#p)
	for i = #p, 1, -1 do
		table.insert(out, p[i])
	end
	return out
end

--- the web's findPath: a list of x/z points (metres) starting at the snapped start, or nil when there is no path
function Nav.findPath(ax: number, az: number, bx: number, bz: number, hintY: number?): { Vector2 }?
	local s = Nav.locate(ax, az, hintY)
	local g = Nav.locate(bx, bz, hintY)
	if s == 0 or g == 0 then
		return nil
	end
	local nodes = astar(s, g, bx, bz)
	if not nodes then
		return nil
	end
	local pts: { Vector2 } = table.create(#nodes)
	for _, n in nodes do
		table.insert(pts, Vector2.new(cx[n], cz[n]))
	end
	local fx, fz = closest(s, ax, az)
	pts[1] = Vector2.new(fx, fz)
	local lx, lz = closest(g, bx, bz)
	if #pts == 1 then
		table.insert(pts, Vector2.new(lx, lz))
	else
		pts[#pts] = Vector2.new(lx, lz)
	end
	local first, last = pts[1], pts[#pts]
	if Nav.clear(first.X, first.Y, last.X, last.Y) then
		return { first, last }
	end
	-- RaycastModifier quality Medium: 2 iterations
	pts = greedy(pts)
	pts = reverse(subdivide(pts, 3))
	pts = greedy(pts)
	return reverse(pts)
end

local t0 = os.clock()
build()
Nav.buildMs = (os.clock() - t0) * 1000
Nav.triangles = NT

return Nav
