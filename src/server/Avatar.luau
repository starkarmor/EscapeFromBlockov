--!strict
-- Humanoid characters (the player's own Roblox avatar and the Creator Store enemy models) set up for the web game's
-- rules: our own hp (the Humanoid never dies or ragdolls), no jump / climb / swim, facing through an AlignOrientation
-- (AutoRotate off; PlayerControl and the enemy AI turn at the decoded rates), every part in the Chars collision group,
-- and the body scaled to the web character's height.
local Avatar = {}

local Units = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared").Units)
local S = Units.S

-- the web character stands 1.107 m (Config.Body.modelTop): the avatar is fitted to exactly that, so the decoded hand
-- socket, muzzles and head line up with the body that is drawn
Avatar.HEIGHT = 1.107 * S

local OFF = {
	Enum.HumanoidStateType.Jumping,
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.Swimming,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.PlatformStanding,
	Enum.HumanoidStateType.Dead,
	Enum.HumanoidStateType.Flying,
}

local function group(d: Instance)
	if d:IsA("BasePart") then
		d.CollisionGroup = "Chars"
		d.CanTouch = false
		if d.Parent and d.Parent:IsA("Accessory") then
			d.CanCollide = false
			d.CanQuery = false
			d.Massless = true
		end
	end
end

--- height from the root's centre down to the floor (studs)
function Avatar.rootHeight(model: Model): number
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root then
		return 2
	end
	return hum.HipHeight + root.Size.Y / 2
end

function Avatar.prepare(model: Model, height: number?)
	local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	-- fit the height first (Model:ScaleTo scales the Humanoid's hip height with the body)
	-- the body's height from the feet to the top of the head (hats and hair do not count)
	local want = height or Avatar.HEIGHT
	local head = model:FindFirstChild("Head") :: BasePart?
	local bodyH: number
	if head then
		local feet = root.Position.Y - (hum.HipHeight + root.Size.Y / 2)
		bodyH = head.Position.Y + head.Size.Y / 2 - feet
	else
		local _, size = model:GetBoundingBox()
		bodyH = size.Y
	end
	if bodyH > 0.1 then
		model:ScaleTo(model:GetScale() * want / bodyH)
	end
	hum.BreakJointsOnDeath = false
	hum.RequiresNeck = false
	hum.AutoRotate = false
	hum.UseJumpPower = true
	hum.JumpPower = 0
	hum.MaxHealth = 100
	hum.Health = 100
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.MaxSlopeAngle = 60
	for _, s in OFF do
		hum:SetStateEnabled(s, false)
	end
	for _, d in model:GetDescendants() do
		group(d)
	end
	model.DescendantAdded:Connect(group)
	local att = root:FindFirstChild("RootAttachment") :: Attachment?
	if not att then
		att = Instance.new("Attachment")
		att.Name = "RootAttachment"
		att.Parent = root
	end
	local align = Instance.new("AlignOrientation")
	align.Name = "Facing"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = true
	align.CFrame = root.CFrame.Rotation
	align.Parent = root
end

--- place the character standing at (x, z) metres, facing `facing` (atan2(x, z), 0 = +z)
function Avatar.place(model: Model, x: number, z: number, facing: number)
	local h = Avatar.rootHeight(model)
	local cf = CFrame.new(x * S, h + 0.05, z * S) * CFrame.Angles(0, facing + math.pi, 0)
	model:PivotTo(cf)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local align = root and root:FindFirstChild("Facing") :: AlignOrientation?
	if align then
		align.CFrame = cf.Rotation
	end
end

return Avatar
