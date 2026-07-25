--!strict
-- CubeServer -- place settings, spawning, and the InputActions.
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

Players.CharacterAutoLoads = false -- no Humanoids; the cube IS the character

local cubes = Instance.new("Folder")
cubes.Name = "Cubes"
cubes.Parent = workspace

local SPAWNS = {
	Vector3.new(0, 4, -16),
	Vector3.new(16, 4, 0),
	Vector3.new(0, 4, 16),
	Vector3.new(-16, 4, 0),
}
local spawnIndex = 0

local function buildInputContext(player: Player)
	if player:FindFirstChild("PlayContext") then
		return
	end

	local ctx = Instance.new("InputContext")
	ctx.Name = "PlayContext"
	ctx.Enabled = true

	local steer = Instance.new("InputAction")
	steer.Name = "Steer" -- the sim looks these up BY NAME
	steer.Type = Enum.InputActionType.Direction2D
	steer.Parent = ctx

	local kb = Instance.new("InputBinding")
	kb.Name = "Keyboard"
	kb.Up, kb.Down = Enum.KeyCode.W, Enum.KeyCode.S
	kb.Left, kb.Right = Enum.KeyCode.A, Enum.KeyCode.D
	kb.Parent = steer

	local pad = Instance.new("InputBinding")
	pad.Name = "Gamepad"
	pad.KeyCode = Enum.KeyCode.Thumbstick1
	pad.Parent = steer

	-- The camera direction rides in as an input too: the server has no camera, and a
	-- replayed step needs the direction AS IT WAS on that frame.
	local cameraDir = Instance.new("InputAction")
	cameraDir.Name = "CameraDir"
	cameraDir.Type = Enum.InputActionType.Direction3D
	cameraDir.Parent = ctx

	ctx.Parent = player -- parented to the Player, so BOTH machines can read it
end

local function spawnCubeFor(player: Player)
	buildInputContext(player)

	local name = "Cube_" .. player.UserId
	if cubes:FindFirstChild(name) then
		return
	end
	spawnIndex += 1

	local spawnAt = SPAWNS[((spawnIndex - 1) % #SPAWNS) + 1]

	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(4, 4, 4)
	root.Color = Color3.fromRGB(220, 150, 60)
	root.Position = spawnAt

	-- UNANCHORED, and this is load-bearing. An ANCHORED part is excluded from client
	-- prediction entirely: the owning client reports itself Authoritative for its own
	-- server-owned character, and nothing is ever rolled back. See samples/repro.
	root.Anchored = false

	-- A bit slippery, so the servo is fighting the floor rather than the other way round.
	root.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.1, 0.2, 1, 5)
	root.Parent = model
	model.PrimaryPart = root

	-- ACTUATORS ARE PRE-WIRED HERE, NOT IN THE SIM. The sim may not create instances (it
	-- re-runs on every replayed step), so everything it could ever need exists up front
	-- and the sim only writes TARGETS onto it.
	local att = Instance.new("Attachment")
	att.Name = "DriveAtt"
	att.Parent = root

	local thrust = Instance.new("VectorForce")
	thrust.Name = "Thrust"
	thrust.Attachment0 = att
	thrust.RelativeTo = Enum.ActuatorRelativeTo.World
	thrust.ApplyAtCenterOfMass = true
	thrust.Force = Vector3.zero
	thrust.Parent = root

	local heading = Instance.new("AlignOrientation")
	heading.Name = "Heading"
	heading.Mode = Enum.OrientationAlignmentMode.OneAttachment
	heading.Attachment0 = att
	heading.MaxTorque = 1e6
	heading.Responsiveness = 40
	heading.CFrame = CFrame.identity
	heading.Parent = root

	-- Intent lives in attributes, because attributes roll back with resimulation.
	root:SetAttribute("MoveDir", Vector3.zero)
	root:SetAttribute("FaceDir", Vector3.new(0, 0, -1))

	-- Part 3 renders a smoothed copy of anything with this tag.
	CollectionService:AddTag(root, "Presented")

	-- An instance the client was never sent cannot be predicted.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	model.Parent = cubes

	-- THE TWO LINES EVERYONE FORGETS. Neither is discoverable.
	player.ReplicationFocus = root -- what replication and PREDICTION centre on
	player.Character = model -- what the camera knows not to push through

	print("[CubeServer] spawned", name)
end

Players.PlayerAdded:Connect(spawnCubeFor)
Players.PlayerRemoving:Connect(function(player)
	local model = cubes:FindFirstChild("Cube_" .. player.UserId)
	if model then
		model:Destroy()
	end
end)
for _, p in Players:GetPlayers() do
	spawnCubeFor(p)
end

require(ReplicatedFirst:WaitForChild("CubeSim")).Initialize()
print("[CubeServer] ready")
