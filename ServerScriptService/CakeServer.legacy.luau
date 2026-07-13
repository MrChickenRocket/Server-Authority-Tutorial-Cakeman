--!strict
-- CakeServer — spawns one authoritative CakeMan per player under Server Authority.
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local CollectionService = game:GetService("CollectionService")

Players.CharacterAutoLoads = false -- no Humanoids; CakeMan IS the character

-- Anything the physics MOVES gets tagged for the presentation layer, which hides the
-- real part and shows a smoothed copy instead (see Presentation.luau). The server
-- decides what deserves presenting; the client never has to know what a CakeMan is.
-- Don't tag anchored scenery -- there's nothing to smooth, and you'd lerp a wall
-- toward itself sixty times a second forever.
local PRESENTED_TAG = "Presented"

-- CakeMan is a walking cake: a stack of layers on loose ball sockets, with noodly
-- arms and a little box head hung off the same joints. The BOTTOM layer is the
-- root -- the only part we drive -- and everything else just wobbles along behind.
-- No legs, no gait, no balance controller. The wobble is free: it's what a stack of
-- blocks on loose joints does all by itself, and the physics engine does all the
-- work we would otherwise have written (badly).
--
-- Every limb here is the SAME construction: a chain of parts, ball socket between
-- each, a gap so they don't grind, and a spring pulling each back toward its rest
-- pose. Learn it once, and arms, head and body are all the same three lines.
-- The body layers are built from a cake MESH, created straight from its asset id --
-- no template lying around in Workspace, nothing to lose, nothing for a reader to have
-- to insert by hand. `AssetService:CreateMeshPartAsync` is the supported way to do this
-- at runtime, and it takes the one property a Script is otherwise forbidden to write:
-- CollisionFidelity. (Assigning `meshPart.CollisionFidelity` from a Script throws
-- "lacking capability Plugin"; passing it in here is allowed.)
--
-- It yields, so it happens once at boot -- never inside the sim.
local CAKE_MESH_ID = "rbxassetid://97264442734279"

local LAYERS = 4
-- Slab thickness and joint gap are ONE budget, not two. The layer pitch (thickness +
-- gap) is what sets how tall he is, so to tighten the seams without growing him, every
-- stud you add to the slab comes straight off the gap. Keep this sum constant (1.65)
-- and you can slide the seam from "sliced cake" to "hairline" without touching anything
-- else in the rig -- the joints, the head and the shoulders all key off the pitch.
local LAYER_SIZE = Vector3.new(4, 1.55, 4)
local LAYER_GAP = 0.1 -- the seam. The joints still need SOMEWHERE to move, so it can't
-- be zero -- with no gap at all the slabs grind on each other and the stack buzzes.
local GAP = 0.25 -- air between every OTHER jointed pair (head, arms).
local LAYER_STEP = LAYER_SIZE.Y + LAYER_GAP -- the layer pitch: hold this at 1.65

-- Density per layer, bottom to top. HEAVY AT THE BOTTOM is the entire stability
-- plan: a bottom-heavy stack rights itself, a top-heavy one falls over. It's also
-- the fun knob -- make the top layers heavier and he gets genuinely unruly.
-- Keep the upper layers LIGHT. It's not just about not toppling: the lighter they
-- are, the less gravity torque the joints have to resist, and so the less joint
-- friction you need to hold him up -- and joint friction is expensive. Wound up too
-- high (2200) it effectively welds the joints, and the solver burns the thrust
-- fighting the character's own constraints: he lurches, stalls, and crawls at 3
-- studs/s while the thrust force screams up past 14,000. Light on top, cheap joints.
local LAYER_DENSITY = { 8, 0.5, 0.35, 0.2 }
local LAYER_COLOR = {
	Color3.fromRGB(120, 72, 48), -- chocolate base
	Color3.fromRGB(240, 226, 200), -- sponge
	Color3.fromRGB(226, 128, 150), -- strawberry
	Color3.fromRGB(250, 245, 235), -- icing
}

-- THE CONE ANGLE IS THE POSE, not a safety rail -- and with no springs anywhere it
-- has to be, because every one of these joints is an INVERTED PENDULUM: the socket
-- sits below its layer's centre of mass, so the layer will always topple to its cone
-- limit and rest there. Nothing is holding it up. So the cone must be tight enough
-- that "fully toppled" still reads as a standing cake: 6 degrees a joint, three
-- joints, and a fully-slumped CakeMan is still only leaning about 18. He is always
-- falling over, and always already caught. That IS the wobble.
local JOINT_ANGLE = 6
local JOINT_TWIST = 10
-- The head is a CHERRY. It's a mesh, and its authored size is 4.11 x 7.06 x 4.00 --
-- nearly twice as tall as it is wide, because most of that height is STEM. Scale it
-- like a cube and you get a squashed cherry with a stubby stem, so we pick a width and
-- let the authored aspect ratio decide the rest. Always check what a mesh's bounding
-- box actually contains before you size it: "tall" here means "mostly empty air".
local CHERRY_MESH_ID = "rbxassetid://112675249551309"
local CHERRY_SOURCE = Vector3.new(4.111819, 7.056720, 4.0) -- as authored
local CHERRY_WIDTH = 1.9 -- the only number we choose; the rest follows
local HEAD_SIZE = CHERRY_SOURCE * (CHERRY_WIDTH / CHERRY_SOURCE.X)

local HEAD_ANGLE = 12 -- the head is light and sits on top, so it can lean further
local HEAD_DENSITY = 0.3 -- keep it light: a heavy head on a loose socket drags the
-- whole stack around instead of bobbling on top of it

-- Arms are the exception: they HANG. A hanging chain is a normal pendulum, not an
-- inverted one -- it's stable, so it can be as floppy as we like. Hence noodles.
local ARM_SEGMENTS = 5 -- more segments = noodlier. This is the whole trick.
-- Five is long enough that the fists drag on the floor, which is a feature: they
-- scuff and trail behind him like a knuckle-dragger.
local ARM_SIZE = Vector3.new(0.85, 0.88, 0.85) -- chunky noodles: thin ones read as
-- twigs and vanish at any distance. Fat and floppy is the look. (Arm length is tuned
-- against his HEIGHT -- the fists should just reach the floor -- so if you ever do
-- change the layer pitch, the arms have to follow or he loses his knuckle-drag.)
local FIST_SCALE = 1.5 -- the last segment is a FIST: a heavy blob on the end of a
-- noodle. Mass at the end of a whip is what gives it something to throw around --
-- and it's what makes a fast turn fling his arms out instead of just rotating them.
local FIST_DENSITY = 1.2 -- and it's dense: this is the business end
local ARM_ANGLE = 45 -- floppy: wide cones, four of them in series

-- Joint friction. A frictionless ball socket is a perfect bearing -- it rattles and
-- swings forever, like a skeleton hung on fishing wire. A little friction in each
-- joint is what makes the character feel like it's made of CAKE: it resists being
-- moved, and it stops moving when you stop. This is the single best-value knob in
-- the whole rig, and it costs one property.
-- Size the body's friction against GRAVITY'S torque on a layer (roughly mass x
-- gravity x half a stud of lever -- about 2000 here). Under that, the stack simply
-- sags to its cone limits and stays slumped; at about that value, friction HOLDS
-- the pose until something bigger than gravity comes along -- which is to say, until
-- you accelerate, turn, or hit something. Then it deforms, and STAYS deformed.
-- That's not a spring, it's PLASTIC, and plastic is exactly what cake is.
local BODY_FRICTION = 700 -- the stack: firm, doughy, holds its shape
local NECK_FRICTION = 90 -- the head: bobbles more freely
local ARM_FRICTION = 8 -- the noodles: barely any, so they still flail

local function makePart(name: string, size: Vector3, color: Color3, density: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	-- density, friction, elasticity (+weights). Low friction: this thing SLIDES on
	-- its bottom layer (it has no legs -- it's a cake). High friction just means the
	-- thrust fights the floor forever. Density is a FEEL knob.
	p.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0.1, 1, 1)
	return p
end

-- Build the cake mesh once, at boot, and keep it as the template every layer clones.
-- BOX collision, deliberately: the mesh is a costume, and the thing the physics engine
-- actually wrestles with should stay a cheap, well-behaved box -- especially the bottom
-- layer, which is sliding across the floor all game. Detailed collision geometry on a
-- part that slides is how you get it snagging on nothing.
local function buildMesh(assetId: string, label: string): MeshPart?
	local ok, result = pcall(function()
		return game:GetService("AssetService"):CreateMeshPartAsync(
			assetId,
			{ CollisionFidelity = Enum.CollisionFidelity.Box, RenderFidelity = Enum.RenderFidelity.Precise }
		)
	end)
	if ok and result then
		print("[CakeServer] built " .. label .. " mesh from", assetId)
		return result
	end
	-- Falls back to plain parts, and everything still works: the meshes are a costume,
	-- not a mechanism, and no physics depends on them.
	warn("[CakeServer] couldn't build the " .. label .. " mesh -- falling back to a box:", result)
	return nil
end

local cakeTemplate: MeshPart? = buildMesh(CAKE_MESH_ID, "cake")
local cherryTemplate: MeshPart? = buildMesh(CHERRY_MESH_ID, "cherry")

local function makeLayer(name: string, size: Vector3, color: Color3, density: number): BasePart
	if not cakeTemplate then
		return makePart(name, size, color, density)
	end
	local layer = (cakeTemplate :: MeshPart):Clone()
	layer.Name = name
	layer.Size = size -- MeshParts scale to whatever Size you give them
	layer.Color = color
	layer.Material = Enum.Material.SmoothPlastic
	-- (CollisionFidelity came from CreateMeshPartAsync above -- clones inherit it, and a
	-- Script can't assign it directly anyway.)
	layer.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0.1, 1, 1)
	return layer
end

-- Ball-socket two parts together at the point BETWEEN them, and never let them
-- collide (adjacent jointed parts grind on each other and jitter).
-- A BallSocketConstraint's cone opens around its attachment's PRIMARY AXIS -- which
-- is the attachment's X axis -- and its twist is measured about that same axis.
-- An attachment built from CFrame.new(pos) has identity rotation, so its X axis
-- points along world +X... which means if your limb chains along Y (like every limb
-- here does), the cone is lying on its side. The joint then bends on its TWIST axis
-- and twists on its BEND axis: your ragdoll folds in directions you never asked for
-- and refuses to fold in the ones you did.
--
-- So: point the attachment's X axis DOWN THE CHAIN. `axis` is the direction the
-- limb runs (up the cake, down an arm). Then UpperAngle really is "how far this
-- link may bend away from straight", and twist really is twist.
local function axisFrame(pos: Vector3, axis: Vector3): CFrame
	local x = axis.Unit
	-- any vector not parallel to x, to build a stable perpendicular from
	local helper = if math.abs(x.Y) > 0.9 then Vector3.zAxis else Vector3.yAxis
	local y = (helper - x * helper:Dot(x)).Unit
	return CFrame.fromMatrix(pos, x, y)
end

local function socket(
	name: string,
	lower: BasePart,
	upper: BasePart,
	jointPos: Vector3,
	axis: Vector3,
	angle: number,
	twist: number,
	friction: number
)
	-- PARENT FIRST, then set WorldCFrame. An Attachment with no parent has no world
	-- to be positioned in, so assigning WorldCFrame early is silently thrown away --
	-- every joint then sits at its part's origin and the whole character collapses
	-- into itself on spawn. (Ask me how I know.)
	local frame = axisFrame(jointPos, axis)
	local a0 = Instance.new("Attachment")
	a0.Name = name .. "_A0"
	a0.Parent = lower
	a0.WorldCFrame = frame
	local a1 = Instance.new("Attachment")
	a1.Name = name .. "_A1"
	a1.Parent = upper
	a1.WorldCFrame = frame

	-- Ball sockets DON'T merge assemblies: every part stays its own body, so a force
	-- on the base drags the rest along through the joint chain. That lag IS the wobble.
	local j = Instance.new("BallSocketConstraint")
	j.Name = name
	j.Attachment0 = a0
	j.Attachment1 = a1
	j.LimitsEnabled = true
	j.UpperAngle = angle
	j.TwistLimitsEnabled = true
	j.TwistLowerAngle = -twist
	j.TwistUpperAngle = twist
	j.MaxFrictionTorque = friction -- the doughiness. See the constants above.
	j.Parent = lower

	local nc = Instance.new("NoCollisionConstraint")
	nc.Part0 = lower
	nc.Part1 = upper
	nc.Parent = lower
end

-- NO SPRINGS ANYWHERE. Nothing holds these joints up: the sockets and their limits
-- ARE the character. Everything above the base is free to flop as far as its cone
-- allows and no further, which is why the cone angles below are the real tuning
-- knobs -- they're not safety rails, they're the pose.
--
-- (I did build a sprung version first, with a restoring torque per part. It stood up
-- straighter and it was strictly worse: the springs quietly cancelled the very lag
-- that makes the thing look like a cake. Raw joints, one driven part, done.)
local function buildCakeMan(): Model
	local man = Instance.new("Model")
	man.Name = "CakeMan"

	-- The body: four cake layers.
	local layers: { BasePart } = {}
	for i = 1, LAYERS do
		local layer = makeLayer("Layer" .. i, LAYER_SIZE, LAYER_COLOR[i], LAYER_DENSITY[i])
		layer.CFrame = CFrame.new(0, (i - 1) * LAYER_STEP, 0)
		layer.Parent = man
		layers[i] = layer
	end

	-- The base GLIDES. He has no legs -- he's a cake -- so the bottom layer is the
	-- only thing between him and the floor, and it is a heavy BOX sliding on a plane.
	-- At normal friction it grabs: an edge catches, he stops dead mid-stride, and the
	-- thrust piles up until he lurches free. Make the base genuinely slippery and he
	-- flows. The FrictionWeight (the 5) makes HIS number win the argument with
	-- whatever surface he's on, so he glides on other people's geometry too.
	layers[1].CustomPhysicalProperties = PhysicalProperties.new(LAYER_DENSITY[1], 0.05, 0, 5, 1)
	man.PrimaryPart = layers[1] -- the bottom layer is the root. Forward is -Z.

	for i = 1, LAYERS - 1 do
		local jointY = (i - 1) * LAYER_STEP + LAYER_SIZE.Y / 2 + LAYER_GAP / 2
		-- The stack chains UPWARD, so the cone opens around +Y: UpperAngle is now how
		-- far a layer may LEAN in any direction, and twist is how far it may rotate
		-- about its own vertical. Which is what those names should have meant all along.
		socket("Joint" .. i, layers[i], layers[i + 1], Vector3.new(0, jointY, 0), Vector3.yAxis, JOINT_ANGLE, JOINT_TWIST, BODY_FRICTION)
	end

	-- The head: a cherry on top, on the same kind of socket as everything else.
	local topY = (LAYERS - 1) * LAYER_STEP
	local head: BasePart
	if cherryTemplate then
		local c = (cherryTemplate :: MeshPart):Clone()
		c.Name = "Head"
		c.Size = HEAD_SIZE
		-- CreateMeshPartAsync hands back a mesh in default grey, not in whatever colour
		-- it was wearing in the place you copied it from. Colour it, or you get a very
		-- sad-looking cherry.
		c.Color = Color3.fromRGB(200, 30, 40)
		c.Material = Enum.Material.SmoothPlastic
		c.Reflectance = 0.25 -- glacé. It should catch the light like a wet sweet.
		c.CustomPhysicalProperties = PhysicalProperties.new(HEAD_DENSITY, 0.3, 0.1, 1, 1)
		head = c
	else
		head = makePart("Head", HEAD_SIZE, Color3.fromRGB(200, 60, 70), HEAD_DENSITY)
	end
	-- The socket goes at the BOTTOM of the head, as always -- which for a cherry means
	-- at the bottom of the fruit, with the stem waving about above it. Because the mesh
	-- is mostly stem, the head's centre sits much higher than you'd expect for a "head":
	-- that's fine, but it does mean the thing has real leverage on the stack, which is
	-- why HEAD_DENSITY is low.
	head.CFrame = CFrame.new(0, topY + LAYER_SIZE.Y / 2 + GAP + HEAD_SIZE.Y / 2, 0)
	head.Parent = man
	socket(
		"Neck",
		layers[LAYERS],
		head,
		Vector3.new(0, topY + LAYER_SIZE.Y / 2 + GAP / 2, 0),
		Vector3.yAxis, -- the head sits on top: chain runs up
		HEAD_ANGLE,
		20,
		NECK_FRICTION
	)

	-- The arms: noodles. Same construction as the body, just thinner, floppier, and
	-- sideways -- a chain of segments, each socketed to the last, each sprung back
	-- toward rest. They are pure passive theatre: nothing drives them, they just get
	-- dragged around by the body and flail, which is exactly what we want.
	local fistSize = ARM_SIZE * FIST_SCALE
	for _, side in { { suffix = "L", x = -1 }, { suffix = "R", x = 1 } } do
		-- Shoulders on the TOP layer, so the noodles dangle clear of the floor.
		-- (Hung lower, they scrape the ground and the poor man walks around
		-- dragging his knuckles through the baseplate.)
		-- Set high on the layer rather than through its middle: shoulders belong at
		-- the top of a shoulder, and the higher hang gives the arms more room to
		-- swing before the fists reach the floor.
		local shoulderY = (LAYERS - 1) * LAYER_STEP + 0.5
		-- Hang the whole arm clear of the widest thing on it (the fist), so it can
		-- swing past the cake instead of spawning halfway inside it.
		local x = side.x * (LAYER_SIZE.X / 2 + fistSize.X / 2 + GAP)
		local prev: BasePart = layers[LAYERS]
		local jointY = shoulderY -- walks DOWN the arm, joint by joint

		for seg = 1, ARM_SEGMENTS do
			local isFist = seg == ARM_SEGMENTS
			local size = if isFist then fistSize else ARM_SIZE
			local arm = makePart(
				"Arm" .. side.suffix .. seg,
				size,
				if isFist then Color3.fromRGB(225, 175, 140) else Color3.fromRGB(235, 200, 170),
				if isFist then FIST_DENSITY else 0.4
			)
			-- Each segment hangs a gap below the joint above it.
			local y = jointY - GAP / 2 - size.Y / 2
			arm.CFrame = CFrame.new(x, y, 0)
			-- Arms DO collide -- with the cake, the floor, and other players. They're
			-- not decoration, they're flails. (They still can't hit the segment they're
			-- jointed to: socket() adds a NoCollisionConstraint for that pair, and
			-- without it adjacent parts grind on each other and the arm buzzes.)
			arm.CanCollide = true
			arm.Parent = man

			-- Arms chain DOWNWARD, so the cone opens around -Y: each link may bend
			-- ARM_ANGLE away from hanging straight down, in any direction. That's a
			-- noodle. (With the cone left lying on its side, the arm could only really
			-- hinge one way and twisted freely the other -- which is what you can see
			-- happening if you look at the joint gizmo.)
			socket(
				"Arm" .. side.suffix .. "J" .. seg,
				prev,
				arm,
				Vector3.new(x, jointY, 0),
				-Vector3.yAxis,
				ARM_ANGLE,
				20,
				ARM_FRICTION
			)
			prev = arm
			jointY = y - size.Y / 2 - GAP / 2 -- next joint: below this segment
		end
	end

	return man
end

-- Actuators. There are only TWO in the whole character, and they're both on the base:
--   Thrust.Force   (world VectorForce on the base, at its centre of mass)
--   Heading.CFrame (AlignOrientation: face the drive direction, stay upright)
-- Nothing else is driven. Everything above the base is joints and gravity.
local function addActuators(man: Model)
	local base = man.PrimaryPart :: BasePart -- a MeshPart once the cake mesh is in play
	local att = Instance.new("Attachment")
	att.Name = "DriveAtt"
	att.Parent = base

	local thrust = Instance.new("VectorForce")
	thrust.Name = "Thrust"
	thrust.Attachment0 = att
	thrust.RelativeTo = Enum.ActuatorRelativeTo.World
	thrust.ApplyAtCenterOfMass = true
	thrust.Force = Vector3.zero
	thrust.Parent = base

	-- The base is the ONE part that's actively held upright and pointed where you're
	-- going. Everything above it is springs and sockets.
	local align = Instance.new("AlignOrientation")
	align.Name = "Heading"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = false -- springy facing: it CATCHES UP, it doesn't snap
	-- Punchy: a fast TURN_RATE in the sim is worthless if the thing that actually
	-- applies the rotation is a slow servo -- it just becomes the new speed limit.
	-- Both have to be quick before he can whip around.
	align.Responsiveness = 40
	align.MaxTorque = 9e5
	align.Parent = base
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
	-- One corner slab each. (The corners are the safe ground; everything between them is
	-- a bridge over a pit, which is where the game happens.)
	local corners = {
		Vector3.new(-45, 6, -45),
		Vector3.new(45, 6, -45),
		Vector3.new(-45, 6, 45),
		Vector3.new(45, 6, 45),
	}
	man:PivotTo(CFrame.new(corners[((spawnIndex - 1) % 4) + 1]))
	-- Persistent, not merely Atomic. Atomic promises you'll never be sent HALF a
	-- character; Persistent promises you'll always be sent the character AT ALL. In a
	-- game about hitting each other, an opponent who streams out at range -- and so
	-- can't be predicted when he comes back -- is not a character, he's a rumour.
	man.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	addActuators(man)

	-- Every part of him is physics, so every part of him gets presented.
	for _, p in man:GetDescendants() do
		if p:IsA("BasePart") then
			CollectionService:AddTag(p, PRESENTED_TAG)
		end
	end

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
local KILL_Y = -40
local SPAWN_POINTS = {
	Vector3.new(-45, 6, -45),
	Vector3.new(45, 6, -45),
	Vector3.new(-45, 6, 45),
	Vector3.new(45, 6, 45),
}

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
