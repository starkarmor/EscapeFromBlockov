--!strict
-- Studio-only telemetry to the output log (read by tools/cycle.sh): position, speed, facing, stamina, camera, fps.
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local player = Players.LocalPlayer
local frames, acc = 0, 0
RunService.RenderStepped:Connect(function(dt)
	frames += 1
	acc += dt
	if acc < 0.5 then
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local cam = Workspace.CurrentCamera
	if root then
		local p, v = root.Position / 3.5, root.AssemblyLinearVelocity / 3.5
		local look = root.CFrame.LookVector
		print(string.format("[tele] t=%.1f pos=(%.2f,%.2f,%.2f) spd=%.2f vy=%.2f look=(%.2f,%.2f) cam=(%.1f,%.1f,%.1f) fov=%.1f fps=%d hp=%s mag=%s",
			Workspace.DistributedGameTime, p.X, p.Y, p.Z, Vector2.new(v.X, v.Z).Magnitude, v.Y, look.X, look.Z,
			cam.CFrame.Position.X / 3.5, cam.CFrame.Position.Y / 3.5, cam.CFrame.Position.Z / 3.5, cam.FieldOfView, math.floor(frames / acc + 0.5),
			tostring(player:GetAttribute("HP")), tostring(player:GetAttribute("Mag"))))
	else
		print("[tele] no character")
	end
	frames, acc = 0, 0
end)
