--!strict
-- Item icons. Firearms show their own Creator Store model (Shared/GunModels -> CreatorAssets/Guns) rendered in a
-- ViewportFrame: a near-orthographic side view, muzzle to the right like the web's weapon silhouettes, framed to the slot.
-- Everything else uses src/ui/icons.ts: one silhouette per category shape (64x64, white with the shape's darker inner
-- details), drawn once into an EditableImage and tinted per item with ImageColor3 (the item colour + 70 per channel).
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Icons = require(ReplicatedStorage:WaitForChild("Shared").gen.Icons)
local GunModels = require(ReplicatedStorage:WaitForChild("Shared").GunModels)

local Icon = {}
local cache: { [string]: any } = {}
local failed = false

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = table.create(256, 0)
for i = 1, 64 do
	DEC[string.byte(B64, i) + 1] = i - 1
end

local function decode(s: string): buffer
	local n = #s
	local pad = (if string.byte(s, n) == 61 then 1 else 0) + (if string.byte(s, n - 1) == 61 then 1 else 0)
	local out = buffer.create(n // 4 * 3 - pad)
	local size = buffer.len(out)
	local o = 0
	for i = 1, n, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = DEC[a + 1] * 262144 + DEC[b + 1] * 4096 + DEC[(c or 65) + 1] * 64 + DEC[(d or 65) + 1]
		for k = 2, 0, -1 do
			if o < size then
				buffer.writeu8(out, o, bit32.band(bit32.rshift(v, 8 * k), 255))
			end
			o += 1
		end
	end
	return out
end

local function image(shape: string): any
	if cache[shape] then
		return cache[shape]
	end
	local mask = Icons.masks[shape] or Icons.masks.material
	if failed or not mask then
		return nil
	end
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(Icons.size, Icons.size) })
	end)
	if not ok or not img then
		failed = true
		return nil
	end
	local raw = decode(mask)
	local n = Icons.size * Icons.size
	local px = buffer.create(n * 4)
	for i = 0, n - 1 do
		local a = buffer.readu8(raw, i * 2)
		local l = buffer.readu8(raw, i * 2 + 1)
		buffer.writeu8(px, i * 4, l)
		buffer.writeu8(px, i * 4 + 1, l)
		buffer.writeu8(px, i * 4 + 2, l)
		buffer.writeu8(px, i * 4 + 3, a)
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(Icons.size, Icons.size), px)
	cache[shape] = img
	return img
end

-- ------------------------------------------------------------------ weapon renders
local FOV = 8 -- degrees: far and narrow, close to an orthographic product shot
local PAD = 0.86 -- the model's extent as a share of the slot
local watched: { [GuiObject]: boolean } = setmetatable({} :: any, { __mode = "k" })

local function gunTemplate(id: string): Model?
	local name = GunModels[id]
	local assets = ReplicatedStorage:FindFirstChild("CreatorAssets")
	local guns = assets and assets:FindFirstChild("Guns")
	local t = name and guns and guns:FindFirstChild(name)
	return if t and t:IsA("Model") then t else nil
end

--- frame the camera on the model for the slot's aspect (side view from +Z: +X, the muzzle, is screen right)
local function frame(vp: ViewportFrame)
	local cam = vp.CurrentCamera
	local m = vp:FindFirstChildOfClass("Model")
	if not cam or not m then
		return
	end
	local cf, size = m:GetBoundingBox()
	local abs = vp.AbsoluteSize
	local aspect = if abs.X > 1 and abs.Y > 1 then abs.X / abs.Y else 1
	-- a slight tilt from above shows the top of the receiver without hiding the profile
	local tilt = math.rad(10)
	local w = size.X
	local h = size.Y * math.cos(tilt) + size.Z * math.sin(tilt)
	local visH = math.max(h, w / aspect) / PAD
	local dist = visH / (2 * math.tan(math.rad(FOV) / 2)) + size.Z
	local dir = Vector3.new(0, math.sin(tilt), math.cos(tilt))
	cam.FieldOfView = FOV
	cam.CFrame = CFrame.lookAt(cf.Position + dir * dist, cf.Position)
end

-- rendered viewports are pooled per item (and per underlay colour): a rebuilt slot reuses one that has already drawn,
-- so icons never flash blank for a frame (a new ViewportFrame draws nothing on its first frame)
local pool: { [string]: { ViewportFrame } } = {}
local function fromPool(key: string): ViewportFrame?
	local list = pool[key]
	return list and table.remove(list) or nil
end

--- keep the rendered viewports under `root` for reuse before `root` is destroyed
function Icon.recycle(root: Instance)
	for _, d in root:GetDescendants() do
		if d:IsA("ViewportFrame") then
			local key = d:GetAttribute("PoolKey")
			if typeof(key) == "string" then
				pool[key] = pool[key] or {}
				if #pool[key] < 24 then
					d.Parent = nil
					table.insert(pool[key], d)
				end
			end
		end
	end
end

local function clearRender(label: GuiObject)
	local old = label:FindFirstChild("Render")
	if old then
		old:Destroy()
	end
end

--- true when item `id` shows a rendered model (callers give it a wide slot)
function Icon.isRender(id: string?): boolean
	return id ~= nil and gunTemplate(id) ~= nil
end

--- render firearm `id`'s model into `label` (true when it has one)
function Icon.render(label: GuiObject, id: string): boolean
	local t = gunTemplate(id)
	if not t then
		clearRender(label)
		return false
	end
	local vp = label:FindFirstChild("Render") :: ViewportFrame?
	if not vp then
		local pooled = fromPool("R|" .. id)
		if pooled then
			pooled.Position = UDim2.new()
			pooled.ImageTransparency = 0
			pooled.Parent = label
			vp = pooled
		end
	end
	if not vp then
		local v = Instance.new("ViewportFrame")
		v:SetAttribute("PoolKey", "R|" .. id)
		v.Name = "Render"
		v.BackgroundTransparency = 1
		v.Size = UDim2.fromScale(1, 1)
		-- bright studio light: the pack's dark finishes stay readable on the dark slots
		v.Ambient = Color3.fromRGB(210, 210, 216)
		v.LightColor = Color3.new(1, 1, 1)
		v.LightDirection = Vector3.new(-0.3, -0.6, -1)
		-- above its slot in Global ZIndex guis (the panel and slot backgrounds share ZIndex 1)
		v.ZIndex = label.ZIndex + 2
		local cam = Instance.new("Camera")
		cam.Parent = v
		v.CurrentCamera = cam
		v.Parent = label
		vp = v
	end
	local v = vp :: ViewportFrame
	v.ZIndex = label.ZIndex + 2
	v:SetAttribute("PoolKey", "R|" .. id)
	if v:GetAttribute("Id") ~= id then
		v:SetAttribute("Id", id)
		for _, c in v:GetChildren() do
			if c:IsA("Model") then
				c:Destroy()
			end
		end
		local m = t:Clone()
		m:PivotTo(CFrame.new())
		m.Parent = v
	end
	frame(v)
	if not v:GetAttribute("Watched") then
		v:SetAttribute("Watched", true)
		v:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			frame(v)
		end)
	end
	return true
end

--- the silhouette image for item `id` (its category shape)
function Icon.mask(id: string): any
	return image(Icons.shape[id] or "material")
end

--- a UI glyph (src/ui/invIcons.ts / icons.ts GLYPHS, rasterized as g_<name>) on an ImageLabel, white
function Icon.glyph(label: ImageLabel, name: string)
	local img = image("g_" .. name)
	if img then
		label.ImageContent = Content.fromObject(img)
	end
end

local function recolor(m: Model, color: Color3)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.Color = color
			d.Material = Enum.Material.Neon
			if d:IsA("MeshPart") then
				pcall(function()
					(d :: any).TextureID = ""
				end)
			end
		elseif d:IsA("SurfaceAppearance") or d:IsA("Decal") or d:IsA("Texture") then
			d:Destroy()
		end
	end
end

--- layers under an icon (siblings below it): the quality glow (ItemDisplay .ico drop-shadow 1.5 px x2 in the quality
--- colour) or the q0 drop shadow (5.92, 5.38, black .722). `host` is a transparent frame covering the icon's box.
function Icon.underlay(host: GuiObject, id: string, color: Color3, offsets: { Vector2 }, alpha: number, silhouette: boolean?)
	local t = if silhouette then nil else gunTemplate(id)
	for k, o in offsets do
		if t then
			local key = string.format("U|%s|%s|%d", id, color:ToHex(), k)
			local pooled = fromPool(key)
			if pooled then
				pooled.Position = UDim2.fromOffset(o.X, o.Y)
				pooled.ImageTransparency = 1 - alpha
				pooled.ZIndex = host.ZIndex
				pooled.Parent = host
				continue
			end
			local v = Instance.new("ViewportFrame")
			v:SetAttribute("PoolKey", key)
			v.Name = "U" .. k
			v.BackgroundTransparency = 1
			v.Size = UDim2.fromScale(1, 1)
			v.Position = UDim2.fromOffset(o.X, o.Y)
			v.Ambient = Color3.new(1, 1, 1)
			v.LightColor = Color3.new(0, 0, 0)
			v.ImageTransparency = 1 - alpha
			v.ZIndex = host.ZIndex
			local cam = Instance.new("Camera")
			cam.Parent = v
			v.CurrentCamera = cam
			local m = t:Clone()
			m:PivotTo(CFrame.new())
			if color == Color3.new(0, 0, 0) then
				v.ImageColor3 = color
			else
				recolor(m, color)
			end
			m.Parent = v
			v.Parent = host
			frame(v)
			v:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				frame(v)
			end)
		else
			local img = image(Icons.shape[id] or "material")
			if not img then
				return
			end
			local l = Instance.new("ImageLabel")
			l.Name = "U" .. k
			l.BackgroundTransparency = 1
			l.Size = UDim2.fromScale(1, 1)
			l.Position = UDim2.fromOffset(o.X, o.Y)
			l.ImageContent = Content.fromObject(img)
			l.ImageColor3 = color
			l.ImageTransparency = 1 - alpha
			l.ZIndex = host.ZIndex
			l.Parent = host
		end
	end
end

--- a tiled diagonal-stripes texture (135 deg bands of `band` px: colour a / colour b), for title bars and unsearched cells
local stripeCache: { [string]: any } = {}
function Icon.stripes(band: number, a: Color3, aAlpha: number, b: Color3, bAlpha: number): any
	local key = string.format("%d|%s|%g|%s|%g", band, a:ToHex(), aAlpha, b:ToHex(), bAlpha)
	if stripeCache[key] then
		return stripeCache[key]
	end
	local n = band * 2
	local ok, img = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(n, n) })
	end)
	if not ok or not img then
		return nil
	end
	local px = buffer.create(n * n * 4)
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			-- repeating-linear-gradient(135deg): bands along x + y
			local inA = ((x + y) % n) < band
			local c, al = if inA then a else b, if inA then aAlpha else bAlpha
			local o = (y * n + x) * 4
			buffer.writeu8(px, o, math.floor(c.R * 255 + 0.5))
			buffer.writeu8(px, o + 1, math.floor(c.G * 255 + 0.5))
			buffer.writeu8(px, o + 2, math.floor(c.B * 255 + 0.5))
			buffer.writeu8(px, o + 3, math.floor(al * 255 + 0.5))
		end
	end
	img:WritePixelsBuffer(Vector2.zero, Vector2.new(n, n), px)
	stripeCache[key] = img
	return img
end

--- show item `id`'s icon on an ImageLabel (clears it for nil)
function Icon.apply(label: ImageLabel, id: string?, silhouette: boolean?)
	if not id then
		clearRender(label)
		label.ImageContent = Content.none
		label.Visible = false
		return
	end
	if not silhouette and Icon.render(label, id) then
		label.ImageContent = Content.none
		label.Visible = true
		return
	end
	clearRender(label)
	local img = image(Icons.shape[id] or "material")
	if not img then
		label.Visible = false
		return
	end
	label.ImageContent = Content.fromObject(img)
	label.ImageColor3 = Color3.fromHex(Icons.tint[id] or "#bbbbbb")
	label.Visible = true
end

return Icon
