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

-- ---------------------------------------------------------------------------
-- PREDICT THE PROPS, EXPLICITLY.
--
-- By default the engine predicts instances with simulation access NEAR THE LOCAL
-- CHARACTER, and decides for itself what "near" means (there's an engine-managed
-- simulation radius you don't get to set -- push Player.SimulationRadius and it just
-- drifts back). Which means a box you're about to hit may only have joined your
-- predicted world moments ago: you punch it, and the punch goes to the server and back
-- before it moves. That's the lag you feel on props, and no amount of network
-- ownership fiddling fixes it -- SetNetworkOwner is meaningless under Server Authority,
-- the server owns everything by definition.
--
-- RunService:SetPredictionMode(instance, PredictionMode.On) forces an instance to ALWAYS
-- be predicted and rolled back, near or far. It's client-only, and it's the knob for
-- exactly this: "for Instances critical to your experience, use this setting."
--
-- The cost is real -- every forced instance participates in every rollback -- so this
-- is a decision about which objects the game is ABOUT. Here that's the boxes: hitting
-- them is the whole verb.
-- ---------------------------------------------------------------------------
local CollectionService = game:GetService("CollectionService")

-- Verify with RunService:GetPredictionStatus(instance), which reports what the engine
-- is ACTUALLY doing rather than what you asked for:
--   Predicted     -- the client simulates it and rolls it back (what we want)
--   Authoritative -- this client is the authority for it
--   None          -- not predicted here; you're watching replicated results
-- A box 78 studs away reads `None` on Automatic and `Predicted` once forced On. Don't
-- trust that a prediction knob worked -- read it back.
local function predictAlways(inst: Instance)
	if inst:IsA("BasePart") then
		RunService:SetPredictionMode(inst, Enum.PredictionMode.On)
	end
end

for _, prop in CollectionService:GetTagged("Prop") do
	predictAlways(prop)
end
CollectionService:GetInstanceAddedSignal("Prop"):Connect(predictAlways)

-- And every CakeMan -- yours and everyone else's. Yours is the most critical instance
-- in the game and the engine would predict it anyway (it's your Character, it's right
-- here); saying so explicitly costs nothing and documents the intent. THEIRS is the
-- interesting one: a remote player's cake is a heavy object you can run into, and if
-- it isn't predicted locally, every collision with another player waits on the server.
task.spawn(function()
	local men = workspace:WaitForChild("CakeMen")
	local function predictCharacter(man: Instance)
		for _, p in man:GetDescendants() do
			predictAlways(p)
		end
		man.DescendantAdded:Connect(predictAlways)
	end
	for _, man in men:GetChildren() do
		predictCharacter(man)
	end
	men.ChildAdded:Connect(predictCharacter)
end)

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
	local target = base.Position + Vector3.new(0, CAM_HEIGHT, 0)
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
