--!strict
-- CakeServer — spawns one authoritative CakeMan per player under Server Authority.
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

Players.CharacterAutoLoads = false -- no Humanoids; CakeMan IS the character

local function makePart(name: string, size: Vector3, color: Color3, density: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	-- density, friction, elasticity (+weights). Density is a FEEL knob: the whole
	-- character tunes in acceleration units, but relative mass decides what wobbles.
	p.CustomPhysicalProperties = PhysicalProperties.new(density, 0.4, 0.2, 1, 1)
	return p
end

local function buildCakeMan(): Model
	local man = Instance.new("Model")
	man.Name = "CakeMan"

	-- Hips: the root everything drives through, and the ballast — most of the
	-- character's mass lives down here so the plate up top can wobble without
	-- dragging the body around. Forward is -Z. (The legs arrive in a later
	-- chapter; for now the hips block IS the lower body.)
	local hips = makePart("Hips", Vector3.new(1.8, 1.4, 1.2), Color3.fromRGB(70, 90, 160), 4)
	hips.Parent = man
	man.PrimaryPart = hips

	-- Plate: a wide, LIGHT dinner plate perched above the hips. Light is the
	-- point -- a heavy plate drags the body around; a light one rides the motion.
	-- Cylinders are long on local X, so stand X up to make a disc.
	local plate = makePart("Plate", Vector3.new(0.3, 5, 5), Color3.fromRGB(240, 240, 235), 0.4)
	plate.Shape = Enum.PartType.Cylinder
	plate.CFrame = hips.CFrame * CFrame.new(0, 1.6, 0) * CFrame.Angles(0, 0, math.rad(90))
	plate.Parent = man

	-- The wobble joint: a ball socket with limits tight enough that the plate
	-- tips and recovers instead of dumping. This tension IS the game later --
	-- the cakes ride on this plate.
	local a0 = Instance.new("Attachment")
	a0.Name = "NeckA0"
	a0.Parent = hips
	local a1 = Instance.new("Attachment")
	a1.Name = "NeckA1"
	a1.Parent = plate
	-- Set socket point in WORLD space (just above the hips) so we don't have to
	-- reason about the rotated cylinder's local axes.
	local socketWorld = hips.CFrame * CFrame.new(0, 0.9, 0)
	a0.WorldCFrame = socketWorld
	a1.WorldCFrame = socketWorld
	local neck = Instance.new("BallSocketConstraint")
	neck.Name = "Neck"
	neck.Attachment0 = a0
	neck.Attachment1 = a1
	neck.LimitsEnabled = true
	neck.UpperAngle = 25
	neck.TwistLimitsEnabled = true
	neck.TwistLowerAngle = -20
	neck.TwistUpperAngle = 20
	neck.Parent = hips

	-- Adjacent jointed parts grind on each other and jitter: never let them collide.
	local nc = Instance.new("NoCollisionConstraint")
	nc.Part0 = hips
	nc.Part1 = plate
	nc.Parent = hips

	return man
end

-- Locomotion actuators. The sim writes ONLY these targets:
--   Thrust.Force   (world VectorForce at the hips' center of mass)
--   Heading.CFrame (AlignOrientation: face the drive direction, stay upright)
--   PlateBalance.Force (a little lift + damping so the plate settles instead of flailing)
local function addActuators(man: Model)
	local hips = man.PrimaryPart :: Part
	local att = Instance.new("Attachment")
	att.Name = "DriveAtt"
	att.Parent = hips

	local thrust = Instance.new("VectorForce")
	thrust.Name = "Thrust"
	thrust.Attachment0 = att
	thrust.RelativeTo = Enum.ActuatorRelativeTo.World
	thrust.ApplyAtCenterOfMass = true
	thrust.Force = Vector3.zero
	thrust.Parent = hips

	local align = Instance.new("AlignOrientation")
	align.Name = "Heading"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = false -- springy facing: it CATCHES UP, it doesn't snap
	align.Responsiveness = 20
	align.MaxTorque = 1e6
	align.Parent = hips

	local plate = man:FindFirstChild("Plate") :: Part
	local patt = Instance.new("Attachment")
	patt.Name = "PlateAtt"
	patt.Parent = plate
	local balance = Instance.new("VectorForce")
	balance.Name = "PlateBalance"
	balance.Attachment0 = patt
	balance.RelativeTo = Enum.ActuatorRelativeTo.World
	balance.ApplyAtCenterOfMass = true
	balance.Force = Vector3.zero
	balance.Parent = plate
end

-- Input lives in InputContexts under the Player (they replicate AND roll back --
-- this is the SA-correct input path, not RemoteEvents).
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

	ctx.Parent = player
end

-- One authoritative CakeMan per player.
local menFolder = Instance.new("Folder")
menFolder.Name = "CakeMen"
menFolder.Parent = workspace

local spawnIndex = 0
local function spawnCakeManFor(player: Player)
	buildInputContext(player)
	local name = "CakeMan_" .. player.UserId
	if menFolder:FindFirstChild(name) then
		return
	end
	spawnIndex += 1
	local man = buildCakeMan()
	man.Name = name
	man:PivotTo(CFrame.new(spawnIndex * 8, 4, 0))
	man.ModelStreamingMode = Enum.ModelStreamingMode.Atomic -- never stream half a character
	addActuators(man)
	man.Parent = menFolder
	-- THE line everyone forgets. With no Humanoid character, prediction has no
	-- center without this -- your own CakeMan won't be predicted and every input
	-- feels like full round-trip latency.
	player.ReplicationFocus = man.PrimaryPart
	print("[CakeServer] spawned", name)
end

local function despawnCakeManFor(player: Player)
	local man = menFolder:FindFirstChild("CakeMan_" .. player.UserId)
	if man then
		man:Destroy()
	end
end

Players.PlayerAdded:Connect(spawnCakeManFor)
Players.PlayerRemoving:Connect(despawnCakeManFor)
for _, p in Players:GetPlayers() do
	spawnCakeManFor(p)
end

require(ReplicatedFirst:WaitForChild("CakeSim")).Initialize()
print("[CakeServer] CakeSim bound (server)")
