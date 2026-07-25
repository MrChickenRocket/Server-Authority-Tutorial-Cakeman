--!strict
-- CakeClient — prediction bootstrap, camera, and the CameraDir feed.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local UserInputService = game:GetService("UserInputService")

if not game:IsLoaded() then
	game.Loaded:Wait()
end
local localPlayer = Players.LocalPlayer
local smoothDamp = require(ReplicatedFirst:WaitForChild("Smoothing")).damp

-- Run the SAME sim locally: this is client-side prediction.
require(ReplicatedFirst:WaitForChild("CakeSim")).Initialize()

-- Hide the raw physics and show the player a smoothed copy of it instead. Everything
-- you actually SEE from here on is the presentation layer; the physics is just truth.
local Presentation = require(ReplicatedFirst:WaitForChild("Presentation"))
Presentation.Initialize()

-- ---------------------------------------------------------------------------
-- PREDICTION: WE DON'T MANAGE IT. THE ENGINE DOES.
--
-- The engine predicts instances with simulation access NEAR THE LOCAL CHARACTER, and
-- it maintains that bubble itself -- measured here at roughly 10-20 studs, adaptive.
--
-- IT ONLY WORKS IF THE ENGINE KNOWS WHERE YOU ARE. Two things must be set, and both
-- are done server-side in CakeServer at spawn:
--
--   player.ReplicationFocus = <root part>   -- what to replicate around
--   player.Character        = <the model>   -- what to PREDICT around
--
-- Miss those and the engine has no centre to work from: nothing gets predicted and your
-- own input feels like full round-trip latency. That is the actual fix, and it's two
-- lines.
--
-- We DID build a hand-rolled bubble here (SetPredictionMode On/Off by distance, with
-- hysteresis) and it was a mistake worth recording: it fought the engine's own bubble,
-- flipping modes underneath it. If you find yourself micromanaging prediction, check
-- ReplicationFocus and Character first -- you are probably solving a problem you created
-- by not setting them. A rival close enough to punch is inside your bubble by
-- definition, so there is nothing here to force.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- THE CAMERA IS YOURS NOW.
--
-- In a Server Authority place with no Humanoid, Roblox does not give you the stock
-- PlayerModule -- check PlayerScripts and you'll find it simply isn't there. So
-- `CameraType = Custom` gets you nothing: no controller ever runs, the camera sits
-- wherever it was born, and you spend twenty minutes convinced your character failed
-- to spawn while you stare at an empty baseplate. The character was fine. Nobody was
-- driving the camera.
--
-- So we drive it. Orbit on right-drag, zoom on the wheel, and follow a SMOOTHED
-- position rather than the character itself -- a wobbling cake is nauseating to
-- track directly, and the smoothing is also what will hide correction pops later.
-- ---------------------------------------------------------------------------
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable

local CAM_HEIGHT = 3.5 -- look at his middle, not his feet
local CAM_SMOOTH = 0.14 -- follow lag (s): filters the wobble out of the view
local CAM_SENS = 0.006 -- mouse radians per pixel
local PITCH_MIN, PITCH_MAX = math.rad(-70), math.rad(60)
local ZOOM_MIN, ZOOM_MAX = 8, 45

local yaw, pitch, zoom = 0, math.rad(-15), 20
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
		zoom = math.clamp(zoom - input.Position.Z * 3, ZOOM_MIN, ZOOM_MAX)
	end
end)

local function subject(): BasePart?
	local men = workspace:FindFirstChild("CakeMen")
	local man = men and men:FindFirstChild("CakeMan_" .. localPlayer.UserId)
	return man and man:FindFirstChild("Layer1") :: BasePart?
end

RunService:BindToRenderStep("CakeCamera", Enum.RenderPriority.Camera.Value, function(dt: number)
	local base = subject()
	if not base then
		return
	end
	-- Follow the SMOOTHED copy, not the truth. The truth is the thing that snaps when a
	-- misprediction lands -- point a camera at it and every correction becomes a flick of
	-- the whole screen, which is far more sickening than a character twitching.
	local follow = Presentation.GetSmoothed(base) or base
	local target = follow.Position + Vector3.new(0, CAM_HEIGHT, 0)
	if not focus then
		focus = target -- snap on the first frame, don't fly in from the origin
	end
	focus, focusVel = smoothDamp(focus :: Vector3, target, focusVel, CAM_SMOOTH, math.min(dt, 0.05))

	local dir = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	local eye = (focus :: Vector3) + dir:VectorToWorldSpace(Vector3.new(0, 0, zoom))
	camera.CFrame = CFrame.lookAt(eye, focus :: Vector3)
end)

-- Feed camera-forward into the CameraDir action: fire on CHANGE plus a slow
-- keep-alive (a still camera doesn't need re-sending every frame). This is what
-- makes steering camera-relative on BOTH sides -- the sim must never read the
-- camera directly, or the server and rollback will disagree with you.
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
