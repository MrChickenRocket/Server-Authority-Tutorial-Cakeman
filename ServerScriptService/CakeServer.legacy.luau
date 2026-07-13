--!strict
-- CakeServer — spawns one authoritative CakeMan per player under Server Authority.
--
-- IT DOES NOT BUILD THE CHARACTER. It clones him.
--
-- The rig is a real Model that lives in ServerStorage.CakeManRig, in the place file --
-- joints, actuators, attachments and all. You can open it in the explorer and look at it.
-- The code that produced it is ServerStorage.GenerateRig, which is DISABLED: it's the
-- recipe, not the runtime.
--
-- This is a deliberate reversal of how the project started. Everything used to be built
-- from scratch at boot, which is elegant and completely opaque -- you cannot inspect a
-- character that doesn't exist until the server runs, you cannot see a joint's cone in a
-- gizmo, and you cannot hand the thing to an artist. Now the artefact is in the place and
-- the recipe is in a disabled script, and you get both.
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local RunService = game:GetService("RunService")

Players.CharacterAutoLoads = false -- no Humanoids; CakeMan IS the character

local rigTemplate = ServerStorage:WaitForChild("CakeManRig") :: Model

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

	-- The camera direction rides in as an INPUT ACTION the client fires -- so the
	-- server and rollback both see the same camera-relative intent.
	local cameraDir = Instance.new("InputAction")
	cameraDir.Name = "CameraDir"
	cameraDir.Type = Enum.InputActionType.Direction3D
	cameraDir.Parent = ctx

	-- Hold left mouse to throw your fists out. Same path as everything else -- an
	-- InputAction, so it replicates AND rolls back. (A RemoteEvent here would mean the
	-- server and your rollback disagreed about exactly when you punched, which for a
	-- game whose whole verb is punching is not a small problem.)
	local grab = Instance.new("InputAction")
	grab.Name = "Grab"
	grab.Type = Enum.InputActionType.Bool
	grab.Parent = ctx
	local mouse = Instance.new("InputBinding")
	mouse.Name = "Mouse"
	mouse.KeyCode = Enum.KeyCode.MouseLeftButton
	mouse.Parent = grab
	local pad2 = Instance.new("InputBinding")
	pad2.Name = "Gamepad"
	pad2.KeyCode = Enum.KeyCode.ButtonR2
	pad2.Parent = grab

	ctx.Parent = player
end

-- One authoritative CakeMan per player.
local menFolder = Instance.new("Folder")
menFolder.Name = "CakeMen"
menFolder.Parent = workspace

-- One home base each, on the compass points. (Everything between the bases is a bridge
-- over a pit, which is where the game actually happens.) Must be declared BEFORE the
-- spawn function that reads it, or Luau captures it as a nil global instead of an
-- upvalue and you get a very confusing "attempt to index nil" at spawn time.
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

	-- CLONE THE RIG. Joints, actuators, attachments, tags, streaming mode -- all of it
	-- already exists in the template, so there is nothing to assemble here. Note that a
	-- clone remaps its own internal references: every constraint in the copy points at
	-- the copy's attachments, not the template's. That's what makes this work at all, and
	-- it's why the rig has to be built as ONE model rather than wired up after parenting.
	local man = rigTemplate:Clone()
	man.Name = name

	-- One home base each. (Everything between the bases is a bridge over a pit, which is
	-- where the game actually happens.)
	man:PivotTo(CFrame.new(SPAWN_POINTS[((spawnIndex - 1) % #SPAWN_POINTS) + 1]))

	-- Health lives on the root as attributes, because that's where the sim can see it.
	local root = man.PrimaryPart :: BasePart
	root:SetAttribute("Health", 100)
	root:SetAttribute("Downed", false)
	root:SetAttribute("DownedFor", 0) -- counts DOWN by dt. Never a timestamp.

	man.Parent = menFolder
	-- THE line everyone forgets. With no Humanoid character, prediction has no
	-- centre without this -- your own CakeMan won't be predicted and every input
	-- feels like full round-trip latency.
	player.ReplicationFocus = man.PrimaryPart

	-- And THE line everyone forgets second. The stock camera pushes itself in
	-- whenever something blocks its view of the subject -- and the only thing it
	-- knows not to shove past is `Player.Character`. We never set that (we have no
	-- Humanoid, so nothing set it for us), so the camera treated CakeMan as scenery
	-- and rammed itself through his own cake. Setting it costs nothing and doesn't
	-- summon a Humanoid: it just tells the camera "this pile of parts is HIM".
	player.Character = man
	print("[CakeServer] spawned", name)
end

local function despawnCakeManFor(player: Player)
	local man = menFolder:FindFirstChild("CakeMan_" .. player.UserId)
	if man then
		man:Destroy()
	end
end

-- Fall in a pit and you come back. We TELEPORT the existing cake rather than destroying
-- and rebuilding it: a respawn that swaps the model out invalidates every reference the
-- client is holding (its presentation copies, its prediction, its camera subject), and
-- you get a visible hitch for no reason. Move him instead, and zero his velocity so he
-- doesn't arrive still falling.
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
game:GetService("RunService").Heartbeat:Connect(function()
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
