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
-- THE PREDICTION BUBBLE.
--
-- By default the engine predicts instances with simulation access NEAR THE LOCAL
-- CHARACTER, and decides for itself what "near" means -- there's an engine-managed
-- simulation radius you don't get to set (push Player.SimulationRadius and it drifts
-- straight back). So a box you're about to hit may have joined your predicted world
-- only moments ago: you punch it, the punch round-trips to the server, and THEN it
-- moves. That's the lag you feel on props. No amount of network-ownership fiddling
-- helps -- SetNetworkOwner is meaningless under Server Authority, the server owns
-- everything by definition.
--
-- The real knob is RunService:SetPredictionMode(instance, mode) -- client-only:
--   On        -- always predicted and rolled back, near or far
--   Off       -- never; you just watch replicated results
--   Automatic -- the engine's radius decides (the default)
--
-- But `On` is not free: every forced instance joins the resimulation set, and the sim
-- re-runs several times per frame. Force all 122 boxes on and you're re-simulating a
-- warehouse to punch one box.
--
-- So we do it AD-HOC: keep a bubble around the player, wider than the engine's own
-- radius, and force prediction On for what's inside it and back to Automatic for what
-- leaves. You pay only for the props you could plausibly touch in the next second or
-- two, and anything you can reach is already predicted by the time you reach it.
--
-- Two details that matter:
--   * HYSTERESIS. Enter the bubble at one radius, leave at a larger one, or props
--     sitting exactly on the boundary flip mode every frame.
--   * LEAD TIME. The bubble is much bigger than arm's reach on purpose: a prop needs to
--     be predicted BEFORE you arrive, not as you hit it. At ~12 studs/s, a 55-stud
--     bubble is about four seconds of warning.
-- ---------------------------------------------------------------------------
local CollectionService = game:GetService("CollectionService")

-- The bubble is SMALL, and it can afford to be: prediction switches on the same frame
-- you ask for it (measured -- SetPredictionMode(On) -> GetPredictionStatus == Predicted
-- in 0 ms, no warm-up), so a prop doesn't need a long run-up to be ready. It only needs
-- to be predicted before you TOUCH it, and 8 studs is already arm's reach for a cake.
-- Keep it tight: everything inside this bubble is paying for itself on every rollback.
local BUBBLE_IN = 8 -- start predicting a prop once it's this close...
local BUBBLE_OUT = 12 -- ...and stop only once it's this far. The gap is the hysteresis.
local BUBBLE_HZ = 15 -- how often we re-evaluate. A tight bubble MUST be checked often:
-- at 12 studs/s he covers 8 studs in under a second, and a lazy tick would have him
-- arriving at a box the bubble hasn't noticed yet. Small radius, fast tick.

-- Verify with RunService:GetPredictionStatus(instance), which reports what the engine
-- is ACTUALLY doing rather than what you asked for:
--   Predicted     -- the client simulates it and rolls it back (what we want)
--   Authoritative -- this client is the authority for it
--   None          -- not predicted here; you're watching replicated results
-- Don't trust that a prediction knob worked. Read it back.
local predicted: { [BasePart]: boolean } = {}

local function setPredicted(part: BasePart, on: boolean)
	if predicted[part] == on then
		return -- don't re-issue the same mode every tick
	end
	predicted[part] = on
	RunService:SetPredictionMode(part, if on then Enum.PredictionMode.On else Enum.PredictionMode.Automatic)
end

local function localRoot(): BasePart?
	local men = workspace:FindFirstChild("CakeMen")
	local man = men and men:FindFirstChild("CakeMan_" .. localPlayer.UserId)
	return man and man:FindFirstChild("Layer1") :: BasePart?
end

task.spawn(function()
	while true do
		task.wait(1 / BUBBLE_HZ)
		local root = localRoot()
		if root then
			local here = root.Position
			for _, prop in CollectionService:GetTagged("Prop") do
				if prop:IsA("BasePart") then
					local d = (prop.Position - here).Magnitude
					if d < BUBBLE_IN then
						setPredicted(prop, true)
					elseif d > BUBBLE_OUT then
						setPredicted(prop, false)
					end
					-- between IN and OUT: leave it however it already is. That's the hysteresis.
				end
			end
		end
	end
end)

-- ---------------------------------------------------------------------------
-- F6: PAINT THE PREDICTION BUBBLE.
--
-- You cannot tune a bubble you cannot see. This colours every prop by what the ENGINE
-- says it's doing -- read back live from GetPredictionStatus, never from what we think
-- we set -- so a bug in the bubble shows up as a wrongly-coloured box rather than as a
-- vague feeling that punching things is sticky:
--
--   GREEN  Predicted     -- the client simulates and rolls it back. Punch it, it moves NOW.
--   RED    None          -- not predicted. Punch it and you wait for the server.
--   BLUE   Authoritative -- this client is the authority for it.
--
-- Purely a render concern: colour is client-local and touches no physics, so this is
-- SA-inert -- it cannot cause a misprediction, which is exactly what a debug view for a
-- prediction system had better not do.
-- ---------------------------------------------------------------------------
local STATUS_COLOR: { [Enum.PredictionStatus]: Color3 } = {
	[Enum.PredictionStatus.Predicted] = Color3.fromRGB(70, 220, 110),
	[Enum.PredictionStatus.None] = Color3.fromRGB(225, 70, 70),
	[Enum.PredictionStatus.Authoritative] = Color3.fromRGB(80, 150, 255),
}

local debugPrediction = false
local trueColor: { [BasePart]: Color3 } = {}

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if processed or input.KeyCode ~= Enum.KeyCode.F6 then
		return
	end
	debugPrediction = not debugPrediction
	if not debugPrediction then
		for part, c in trueColor do
			if part.Parent then
				part.Color = c
			end
		end
		table.clear(trueColor)
	end
	print("[CakeClient] prediction debug:", debugPrediction and "ON (green=predicted, red=not)" or "off")
end)

RunService.RenderStepped:Connect(function()
	if not debugPrediction then
		return
	end
	for _, prop in CollectionService:GetTagged("Prop") do
		if prop:IsA("BasePart") then
			if not trueColor[prop] then
				trueColor[prop] = prop.Color -- remember it so F6 can put it back
			end
			local c = STATUS_COLOR[RunService:GetPredictionStatus(prop)]
			if c then
				prop.Color = c
			end
		end
	end
end)

-- CHARACTERS ARE ALWAYS ON, bubble or no bubble. Yours is the most critical instance in
-- the game. Everyone else's is a heavy object you can run into -- and an opponent who
-- isn't predicted locally means every player-vs-player collision waits on the server,
-- which in a game about hitting each other is the worst possible thing to make people
-- wait for. There are only ever a handful of them, so they're cheap to keep on.
task.spawn(function()
	local men = workspace:WaitForChild("CakeMen")
	local function predictCharacter(man: Instance)
		local function force(p: Instance)
			if p:IsA("BasePart") then
				RunService:SetPredictionMode(p, Enum.PredictionMode.On)
			end
		end
		for _, p in man:GetDescendants() do
			force(p)
		end
		man.DescendantAdded:Connect(force)
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
