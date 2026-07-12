--!strict
-- CakeClient — prediction bootstrap, camera, and CameraDir feed.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

if not game:IsLoaded() then
	game.Loaded:Wait()
end
local localPlayer = Players.LocalPlayer

-- Run the SAME sim locally: this is client-side prediction.
require(ReplicatedFirst:WaitForChild("CakeSim")).Initialize()

local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Custom -- stock orbit/zoom camera

-- Point the stock camera at our CakeMan once it exists. (A smoothed camera
-- proxy arrives with the polite-rendering chapter; direct-follow is fine to
-- start with.)
task.spawn(function()
	local men = workspace:WaitForChild("CakeMen")
	local man = men:WaitForChild("CakeMan_" .. localPlayer.UserId)
	local hips = man:WaitForChild("Hips")
	camera.CameraSubject = hips :: BasePart
end)

-- Default zoom: pin min=max for two frames to force the distance, then reopen.
local DEFAULT_ZOOM = 18
task.defer(function()
	local minD, maxD = localPlayer.CameraMinZoomDistance, localPlayer.CameraMaxZoomDistance
	localPlayer.CameraMinZoomDistance = DEFAULT_ZOOM
	localPlayer.CameraMaxZoomDistance = DEFAULT_ZOOM
	RunService.RenderStepped:Wait()
	RunService.RenderStepped:Wait()
	localPlayer.CameraMinZoomDistance = minD
	localPlayer.CameraMaxZoomDistance = maxD
end)

-- Feed camera-forward into the CameraDir action: fire on CHANGE plus a slow
-- keep-alive (a still camera doesn't need re-sending every frame).
local playContext = localPlayer:WaitForChild("PlayContext")
local cameraDir = playContext:WaitForChild("CameraDir")
local lastFired = Vector3.zero
local sinceFire = 0
RunService.RenderStepped:Connect(function(dt: number)
	local dir = camera.CFrame.LookVector
	sinceFire += dt
	if (dir - lastFired).Magnitude > 0.02 or sinceFire > 0.5 then
		cameraDir:Fire(dir)
		lastFired = dir
		sinceFire = 0
	end
end)
