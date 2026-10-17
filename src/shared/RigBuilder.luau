--!strict
-- Character models from gen/Rigs.luau (the web build's beaver and goose rigs, bone-mounted boxes).
-- Root: a 0.3 m-radius ball (the web's circle body, PLAYER_RADIUS) that slides along walls; every visual part rides a
-- Motor6D off the root (C0 = bind pose) whose Transform the client animator (CharAnim) drives from the source clips.
local Rigs = require(script.Parent.gen.Rigs)
local Skel = require(script.Parent.Skel)
local Units = require(script.Parent.Units)

local RigBuilder = {}
local S = Units.S
RigBuilder.ROOT_R = 0.3 * S -- studs
-- model space (metres, feet at y = 0, +z forward) -> root space (studs; root centre at ROOT_R, faces -Z)
RigBuilder.FLIP = CFrame.Angles(0, math.pi, 0)

local function hex(c: string): Color3
	return Color3.fromHex(c)
end

export type RigPart = { part: BasePart, joint: Motor6D, bone: number, rel: CFrame, weapon: boolean }

--- model-space CFrame (studs, root-relative) of a part on a posed skeleton
function RigBuilder.partCFrame(world: { CFrame }, bone: number, rel: CFrame, k: number): CFrame
	local m = if bone > 0 then world[bone] * rel else rel
	local p = m.Position * (k * S)
	local local_ = CFrame.new(p.X, p.Y - RigBuilder.ROOT_R, p.Z) * m.Rotation
	return RigBuilder.FLIP * local_
end

function RigBuilder.build(key: string, name: string?): Model
	local spec = Rigs[key]
	assert(spec, "no rig " .. key)
	local model = Instance.new("Model")
	model.Name = name or spec.name
	model:SetAttribute("Rig", key)
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Shape = Enum.PartType.Ball
	root.Size = Vector3.one * (RigBuilder.ROOT_R * 2)
	root.Transparency = 1
	root.CanCollide = true
	root.CanTouch = false
	root.CanQuery = false
	root.CollisionGroup = "Chars"
	root.CustomPhysicalProperties = PhysicalProperties.new(1, 0, 0, 100, 100)
	root.Parent = model
	model.PrimaryPart = root
	local att = Instance.new("Attachment")
	att.Name = "RootAttachment"
	att.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Name = "Facing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = true
	align.Parent = root

	local k = spec.rootScale
	local world = Skel.fk(Skel.bindPose())
	for i, p in spec.parts do
		local part = Instance.new("Part")
		part.Name = if p.weapon then "Weapon" elseif p.head then "Head" else ("P" .. i)
		part.Size = Vector3.new(p.size[1], p.size[2], p.size[3]) * (k * S)
		part.Color = hex(p.c)
		-- the shared world stud pitch on the big body blocks (art brief: studs repeat across floors and animals);
		-- eyes, beaks, teeth and other small identity pieces stay smooth
		local sz = part.Size
		if math.min(sz.X, sz.Y, sz.Z) >= 0.6 and math.max(sz.X, sz.Y, sz.Z) >= 1.2 and not p.weapon then
			part.Material = Enum.Material.Plastic
			part.MaterialVariant = "CanuckStuds"
		else
			part.Material = Enum.Material.SmoothPlastic
		end
		part.Transparency = if p.o then 1 - p.o else 0
		part.Massless = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = true
		local rel = CFrame.new(p.p[1], p.p[2], p.p[3], p.q[1], p.q[2], p.q[3], p.q[4])
		local cf = RigBuilder.partCFrame(world, p.bone, rel, k)
		part.CFrame = root.CFrame * cf
		local j = Instance.new("Motor6D")
		j.Name = "J" .. i
		j.Part0 = root
		j.Part1 = part
		-- C0 holds the bind pose (unanimated rigs stand right); CharAnim sets Transform = C0:Inverse() * posed
		j.C0 = cf
		j.C1 = CFrame.identity
		j.Parent = root
		part:SetAttribute("Bone", p.bone)
		part:SetAttribute("I", i)
		part.Parent = model
	end
	return model
end

RigBuilder.spec = function(key: string)
	return Rigs[key]
end

return RigBuilder
