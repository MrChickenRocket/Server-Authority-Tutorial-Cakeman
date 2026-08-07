--!strict
-- CubeClient -- prediction bootstrap, camera, and the CameraDir feed.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

if not game:IsLoaded() then
	game.Loaded:Wait()
end
local player = Players.LocalPlayer

local CubePresent = require(ReplicatedFirst:WaitForChild("CubePresent"))
CubePresent.Initialize()

-- Run the same sim locally. This is client-side prediction.
require(ReplicatedFirst:WaitForChild("CubeSim")).Initialize()

-- The camera is yours to drive here. In a characterless Server Authority place there is no
-- PlayerModule, so CameraType = Custom gets you nothing: no controller runs and the camera
-- sits wherever it was born.
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable -- without this, your CFrame is overwritten

local CAM_HEIGHT = 6
local CAM_SMOOTH = 0.12 -- follow lag (s)
local CAM_SENS = 0.006 -- mouse radians per pixel
local PITCH_MIN, PITCH_MAX = math.rad(-70), math.rad(35)
local ZOOM_MIN, ZOOM_MAX = 12, 80

local yaw, pitch, zoom = 0, math.rad(-18), 34
local focus: Vector3? = nil
local focusVel = Vector3.zero
local orbiting = false

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		orbiting = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	end
end)
UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		orbiting = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end)
UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement and orbiting then
		yaw -= input.Delta.X * CAM_SENS
		pitch = math.clamp(pitch - input.Delta.Y * CAM_SENS, PITCH_MIN, PITCH_MAX)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		zoom = math.clamp(zoom - input.Position.Z * 4, ZOOM_MIN, ZOOM_MAX)
	end
end)

local function myRoot(): BasePart?
	local cubes = workspace:FindFirstChild("Cubes")
	local model = cubes and cubes:FindFirstChild("Cube_" .. player.UserId)
	return model and (model :: Model).PrimaryPart or nil
end

RunService:BindToRenderStep("CubeCamera", Enum.RenderPriority.Camera.Value, function(dt: number)
	local root = myRoot()
	if not root then
		return
	end

	-- Follow the smoothed copy. The truth is what snaps on a correction, and a camera pointed
	-- at it turns every correction into a flick of the whole screen.
	local follow = CubePresent.GetSmoothed(root) or root
	local target = follow.Position + Vector3.new(0, CAM_HEIGHT, 0)
	if not focus then
		focus = target -- snap on frame 1, or it sails in from the world origin
	end
	focus, focusVel = CubePresent.damp(focus :: Vector3, target, focusVel, CAM_SMOOTH, math.min(dt, 0.05))

	local dir = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	local eye = (focus :: Vector3) + dir:VectorToWorldSpace(Vector3.new(0, 0, zoom))
	camera.CFrame = CFrame.lookAt(eye, focus :: Vector3)
end)

-- Feed the camera direction in as an input. Fire on change, plus a slow keep-alive.
local playContext = player:WaitForChild("PlayContext")
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
