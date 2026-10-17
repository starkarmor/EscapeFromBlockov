--!strict
-- What a collider stops (src/utils/geometry.ts Block). Map parts carry the flags in their "Cat" attribute.
local Block = {
	body = 1,
	bullet = 2,
	sight = 4,
	grenade = 8,
	obstacle = 16,
}

function Block.has(part: Instance, flag: number): boolean
	local cat = part:GetAttribute("Cat")
	if typeof(cat) ~= "number" then
		return true
	end
	return bit32.band(cat :: number, flag) ~= 0
end

return Block
