--!strict
-- Item icons (src/ui/icons.ts): one silhouette per category shape (64x64, white with the shape's darker inner details),
-- drawn once into an EditableImage and tinted per item with ImageColor3 (the item colour + 70 per channel).
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Icons = require(ReplicatedStorage:WaitForChild("Shared").gen.Icons)

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

--- show item `id`'s icon on an ImageLabel (clears it for nil)
function Icon.apply(label: ImageLabel, id: string?)
	if not id then
		label.ImageContent = Content.none
		label.Visible = false
		return
	end
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
