--!strict
-- CakeServer -- spawns one authoritative CakeMan per player under Server Authority.
--
-- It clones the character rather than building it. The rig is a real Model living in
-- ServerStorage.CakeManRig in the place file, joints and actuators and attachments and all,
-- so you can open it in the explorer, inspect it, and tune it there. The rig is the
-- authoritative copy of every mass, cone angle and joint friction in the character.
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")

Players.CharacterAutoLoads = false -- no Humanoids; CakeMan is the character

local rigTemplate = ServerStorage:WaitForChild("CakeManRig") :: Model

-- Check the rig before trusting it. Because the character is an artefact in the place
-- rather than something this script builds, it can be wrong in ways code cannot: a deleted
-- attachment, an unsaved edit, a constraint that lost its reference. A constraint with a nil
-- Attachment does not error -- it applies no force, silently, forever. One comparison per
-- player turns "he feels sluggish" into "Thrust.Attachment0 is nil".
local function checkRig(man: Model)
	local base = man:FindFirstChild("Layer1") :: BasePart?
	local thrust = base and base:FindFirstChild("Thrust") :: VectorForce?
	local heading = base and base:FindFirstChild("Heading") :: AlignOrientation?

	if not (base and thrust and heading) then
		warn("[CakeServer] rig is missing Layer1/Thrust/Heading -- he will not move at all")
		return
	end
	if thrust.Attachment0 == nil then
		warn(
			"[CakeServer] Thrust has no Attachment0 -- it will apply zero force, forever. "
				.. "Fix it on ServerStorage.CakeManRig and save the place."
		)
	end
	if heading.Attachment0 == nil then
		warn("[CakeServer] Heading has no Attachment0 -- nothing is holding him upright")
	end
end

local function buildInputContext(player: Player)
	if player:FindFirstChild("PlayContext") then
		return
	end
	local ctx = Instance.new("InputContext")
	ctx.Name = "PlayContext"
	ctx.Enabled = true

	local steer = Instance.new("InputAction")
	steer.Name = "Steer"
	steer.Type = Enum.InputActionType.Direction2D
	steer.Parent = ctx
	local kb = Instance.new("InputBinding")
	kb.Name = "Keyboard"
	kb.Up = Enum.KeyCode.W
	kb.Down = Enum.KeyCode.S
	kb.Left = Enum.KeyCode.A
	kb.Right = Enum.KeyCode.D
	kb.Parent = steer
	local pad = Instance.new("InputBinding")
	pad.Name = "Gamepad"
	pad.KeyCode = Enum.KeyCode.Thumbstick1
	pad.Parent = steer

	-- The camera direction rides in as an input action the client fires, so the server and
	-- the rollback both see the same camera-relative intent.
	local cameraDir = Instance.new("InputAction")
	cameraDir.Name = "CameraDir"
	cameraDir.Type = Enum.InputActionType.Direction3D
	cameraDir.Parent = ctx

	ctx.Parent = player
end

-- One authoritative CakeMan per player.
local menFolder = Instance.new("Folder")
menFolder.Name = "CakeMen"
menFolder.Parent = workspace

-- One home base each, on the compass points. Everything between the bases is a bridge over
-- a pit, which is where the game happens. Declared before the spawn function that reads it:
-- a local defined later resolves inside the function as a global instead, so you get a nil
-- index at spawn time.
local SPAWN_POINTS = {
	Vector3.new(0, 6, -54), -- North base
	Vector3.new(54, 6, 0), -- East base
	Vector3.new(0, 6, 54), -- South base
	Vector3.new(-54, 6, 0), -- West base
}
local KILL_Y = -40

local spawnIndex = 0
local function spawnCakeManFor(player: Player)
	buildInputContext(player)
	local name = "CakeMan_" .. player.UserId
	if menFolder:FindFirstChild(name) then
		return
	end
	spawnIndex += 1

	-- Joints, actuators, attachments, tags and streaming mode all exist in the template, so
	-- there is nothing to assemble here. A clone remaps its own internal references -- every
	-- constraint in the copy points at the copy's attachments -- which is why the rig has to
	-- be built as one model rather than wired up after parenting.
	local man = rigTemplate:Clone()
	man.Name = name
	checkRig(man)

	man:PivotTo(CFrame.new(SPAWN_POINTS[((spawnIndex - 1) % #SPAWN_POINTS) + 1]))

	man.Parent = menFolder
	-- With no Humanoid character, prediction has no centre without this: your own CakeMan
	-- won't be predicted and every input feels like full round-trip latency.
	player.ReplicationFocus = man.PrimaryPart

	-- And the camera needs this one. The stock camera pushes itself in whenever something
	-- blocks its view of the subject, and the only thing it knows not to shove past is
	-- Player.Character. Nothing sets it for us here, since we have no Humanoid, so without
	-- this the camera treats CakeMan as scenery and rams through his own cake. Setting it
	-- does not summon a Humanoid; it just identifies the model as the player.
	player.Character = man
	print("[CakeServer] spawned", name)
end

local function despawnCakeManFor(player: Player)
	local man = menFolder:FindFirstChild("CakeMan_" .. player.UserId)
	if man then
		man:Destroy()
	end
end

-- Fall in a pit and you come back. Teleport the existing cake rather than destroying and
-- rebuilding it: swapping the model out invalidates every reference the client holds (its
-- presentation copies, its prediction, its camera subject) and costs a visible hitch.
--
-- Anything a respawn doesn't explicitly clear, it keeps. The only state a CakeMan carries
-- right now is his physics, so zeroing every velocity is the whole job -- otherwise he
-- arrives at his base still falling at terminal velocity and goes straight back through the
-- floor. Add state to the character later (health, a stun) and it has to be reset here too.
local function respawn(man: Model, index: number)
	local point = SPAWN_POINTS[(index % #SPAWN_POINTS) + 1]
	man:PivotTo(CFrame.new(point))
	for _, p in man:GetDescendants() do
		if p:IsA("BasePart") then
			p.AssemblyLinearVelocity = Vector3.zero
			p.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

local fallIndex = 0
RunService.Heartbeat:Connect(function()
	for _, man in menFolder:GetChildren() do
		local root = (man :: Model).PrimaryPart
		if root and root.Position.Y < KILL_Y then
			fallIndex += 1
			respawn(man :: Model, fallIndex)
		end
	end
end)

Players.PlayerAdded:Connect(spawnCakeManFor)
Players.PlayerRemoving:Connect(despawnCakeManFor)
for _, p in Players:GetPlayers() do
	spawnCakeManFor(p)
end

require(ReplicatedFirst:WaitForChild("CakeSim")).Initialize()
print("[CakeServer] CakeSim bound (server)")
