--!strict
-- Unity AnimationCurve.Evaluate for non-weighted keys {time, value, inSlope, outSlope}: cubic Hermite, clamped outside.
-- Same as sampleCurve in src/systems/CameraRig.ts.
local Curve = {}

function Curve.sample(keys: { { number } }, t: number): number
	if t <= keys[1][1] then
		return keys[1][2]
	end
	for i = 2, #keys do
		local k1, k0 = keys[i], keys[i - 1]
		local t1, v1, in1 = k1[1], k1[2], k1[3]
		local t0, v0, out0 = k0[1], k0[2], k0[4]
		if t <= t1 then
			local d = t1 - t0
			local s = (t - t0) / d
			local s2 = s * s
			local s3 = s2 * s
			return (2 * s3 - 3 * s2 + 1) * v0 + (s3 - 2 * s2 + s) * out0 * d + (-2 * s3 + 3 * s2) * v1 + (s3 - s2) * in1 * d
		end
	end
	return keys[#keys][2]
end

return Curve
