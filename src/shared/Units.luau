--!strict
-- Web build metres <-> Roblox studs (docs/art-brief.md "Units"). Time values never convert.
local Units = {}
Units.S = 3.5 -- studs per metre

function Units.m(v: number): number
	return v * Units.S
end

function Units.toStuds(x: number, z: number, y: number?): Vector3
	return Vector3.new(x * Units.S, (y or 0) * Units.S, z * Units.S)
end

function Units.toMetres(v: Vector3): (number, number)
	return v.X / Units.S, v.Z / Units.S
end

return Units
