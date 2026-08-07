--!strict
-- GenerateRig -- how ServerStorage.CakeManRig was originally assembled.
--
-- Kept for reference, not for running. The rig in the place is the authoritative copy and has
-- been tuned there since; these constants are the seed values it started from and have already
-- drifted. Running this rebuilds the model and discards that tuning.
--
-- Worth reading for the construction details that a finished rig doesn't show you: the layer
-- pitch budget, the joint axis convention in axisFrame(), and the order things have to be
-- created in. The reasoning behind the values is in docs/reference/physics-characters.md §2.
local ServerStorage = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local PRESENTED_TAG = "Presented"

-- CakeMan is a stack of layers on loose ball sockets, with noodly arms and a box head hung off
-- the same kind of joints. The bottom layer is the root and the only part we drive; everything
-- else wobbles along behind it. There are no legs, no gait, and no balance controller.
--
-- Every limb is the same construction: a chain of parts, a ball socket between each, and a gap
-- so they don't grind. Learn it once and arms, head and body are all the same three lines.
--
-- The body layers use a cake mesh created straight from its asset id, so there is no template
-- in Workspace to lose. AssetService:CreateMeshPartAsync is the supported way to do this at
-- runtime, and it takes the one property a Script cannot otherwise write: CollisionFidelity.
-- (Assigning meshPart.CollisionFidelity from a Script throws "lacking capability Plugin";
-- passing it in here is allowed.) It yields, so it happens once at boot, never inside the sim.
local CAKE_MESH_ID = "rbxassetid://97264442734279"

local LAYERS = 4
-- Slab thickness and joint gap are one budget, not two. The layer pitch (thickness + gap) sets
-- how tall he is, so every stud added to the slab comes off the gap. Hold this sum at 1.65 and
-- you can slide the seam from "sliced cake" to "hairline" without touching anything else --
-- the joints, the head and the shoulders all key off the pitch.
local LAYER_SIZE = Vector3.new(4, 1.55, 4)
local LAYER_GAP = 0.1 -- the seam. Can't be zero, or the slabs grind and the stack buzzes.
local GAP = 0.25 -- air between every other jointed pair (head, arms)
local LAYER_STEP = LAYER_SIZE.Y + LAYER_GAP -- the layer pitch: hold this at 1.65

local LAYER_DENSITY = { 8, 0.5, 0.35, 0.2 } -- bottom to top; heavy at the bottom
local LAYER_WIDTH = { 1, 1.3, 1.2, 1 } -- X/Z only, so the pitch and every joint stay put

-- How far to pull each shoulder back in from the point that just clears the fist. Clearing the
-- fist is the ceiling, so the arms can swing past the cake instead of spawning inside it; the
-- inset itself is silhouette.
local SHOULDER_INSET = 0.5
local LAYER_COLOR = {
	Color3.fromRGB(120, 72, 48), -- chocolate base
	Color3.fromRGB(240, 226, 200), -- sponge
	Color3.fromRGB(226, 128, 150), -- strawberry
	Color3.fromRGB(250, 245, 235), -- icing
}

local JOINT_ANGLE = 6 -- degrees of lean per body joint
local JOINT_TWIST = 10 -- degrees of rotation about the layer's own vertical

-- The head is a cherry mesh, authored at 4.11 x 7.06 x 4.00 -- nearly twice as tall as it is
-- wide, because most of that height is stem. Scale it like a cube and you get a squashed cherry
-- with a stubby stem, so pick a width and let the authored aspect ratio decide the rest.
local CHERRY_MESH_ID = "rbxassetid://112675249551309"
local CHERRY_SOURCE = Vector3.new(4.111819, 7.056720, 4.0) -- as authored
local CHERRY_WIDTH = 1.9 -- the only number we choose; the rest follows
local HEAD_SIZE = CHERRY_SOURCE * (CHERRY_WIDTH / CHERRY_SOURCE.X)

local HEAD_ANGLE = 12 -- the head is light and sits on top, so it can lean further
local HEAD_DENSITY = 0.3

local ARM_SEGMENTS = 5 -- more segments = noodlier. Five puts the fists at floor height.
local ARM_SIZE = Vector3.new(0.85, 0.88, 0.85) -- thin noodles read as twigs at any distance.
-- Arm length is tuned against his height so the fists just reach the floor, so if you change
-- the layer pitch the arms have to follow.
local FIST_SCALE = 1.5 -- the last segment is a fist: a heavy blob on the end of a noodle
local FIST_DENSITY = 1.2
local ARM_ANGLE = 45 -- floppy: wide cones, four of them in series

local BODY_FRICTION = 700 -- the stack: firm, doughy, holds its shape
local NECK_FRICTION = 90 -- the head: bobbles more freely
local ARM_FRICTION = 8 -- the noodles: barely any, so they still flail

-- The guard: where the hands are held when you hold the grab button, in the shoulder layer's
-- own frame. The pose is a property of the body, so it is baked into the body as a pair of
-- attachments rather than living in the simulation.
--
-- It is bounded by arm length. The arm is 5 segments of about 1.1, so about 5.6 studs; a stance
-- 6 forward and 5 down wants sqrt(6^2 + 5.2^2) = 7.9 studs of arm. The fist then strains at full
-- extension, permanently short of where you sent it, and every grab misses by the amount you
-- overreached. The vertical drop eats the reach.
local STANCE_DIST = 4.4 -- how far in front of the shoulders the hands are held
local STANCE_WIDTH = 1.6 -- and how far apart. Inboard of the shoulders (±2.39), so the hands
-- close toward each other: a grappler's guard rather than a lunge.
local STANCE_RISE = -0.1 -- just under the shoulder line

local REACH_FORCE = 4000 -- both arms loaded weigh about 690, so this is a few times the load

local function makePart(name: string, size: Vector3, color: Color3, density: number): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	-- density, friction, elasticity (+weights)
	p.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0.1, 1, 1)
	return p
end

-- Build the cake mesh once, at boot, and keep it as the template every layer clones. Box
-- collision is deliberate: the mesh is a costume, and what the physics engine wrestles with
-- should stay a cheap box -- especially the bottom layer, which slides across the floor all
-- game. Detailed collision geometry on a part that slides snags on nothing.
local function buildMesh(assetId: string, label: string): MeshPart?
	local ok, result = pcall(function()
		return game:GetService("AssetService"):CreateMeshPartAsync(
			assetId,
			{ CollisionFidelity = Enum.CollisionFidelity.Box, RenderFidelity = Enum.RenderFidelity.Precise }
		)
	end)
	if ok and result then
		print("[GenerateRig] built " .. label .. " mesh from", assetId)
		return result
	end
	-- Falls back to plain parts and everything still works: the meshes are a costume, not a
	-- mechanism, and no physics depends on them.
	warn("[GenerateRig] couldn't build the " .. label .. " mesh -- falling back to a box:", result)
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
	-- CollisionFidelity came from CreateMeshPartAsync above; clones inherit it, and a Script
	-- can't assign it directly anyway.
	layer.CustomPhysicalProperties = PhysicalProperties.new(density, 0.3, 0.1, 1, 1)
	return layer
end

-- Ball-socket two parts together at the point between them, and never let them collide --
-- adjacent jointed parts grind on each other and jitter.
--
-- A BallSocketConstraint's cone opens around its attachment's primary axis, which is the
-- attachment's X axis, and its twist is measured about that same axis. An attachment built from
-- CFrame.new(pos) has identity rotation, so its X axis points along world +X, which means that
-- if your limb chains along Y (as every limb here does) the cone is lying on its side. The
-- joint then bends on its twist axis and twists on its bend axis, so the ragdoll folds in
-- directions you never asked for and refuses to fold in the ones you did.
--
-- So point the attachment's X axis down the chain. `axis` is the direction the limb runs (up
-- the cake, down an arm). Then UpperAngle really is how far this link may bend away from
-- straight, and twist really is twist.
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
	-- Parent first, then set WorldCFrame. An Attachment with no parent has no world to be
	-- positioned in, so assigning WorldCFrame early is silently discarded -- every joint then
	-- sits at its part's origin and the character collapses into itself on spawn.
	local frame = axisFrame(jointPos, axis)
	local a0 = Instance.new("Attachment")
	a0.Name = name .. "_A0"
	a0.Parent = lower
	a0.WorldCFrame = frame
	local a1 = Instance.new("Attachment")
	a1.Name = name .. "_A1"
	a1.Parent = upper
	a1.WorldCFrame = frame

	-- Ball sockets don't merge assemblies: every part stays its own body, so a force on the
	-- base drags the rest along through the joint chain, and that lag is the wobble.
	local j = Instance.new("BallSocketConstraint")
	j.Name = name
	j.Attachment0 = a0
	j.Attachment1 = a1
	j.LimitsEnabled = true
	j.UpperAngle = angle
	j.TwistLimitsEnabled = true
	j.TwistLowerAngle = -twist
	j.TwistUpperAngle = twist
	j.MaxFrictionTorque = friction
	j.Parent = lower

	local nc = Instance.new("NoCollisionConstraint")
	nc.Part0 = lower
	nc.Part1 = upper
	nc.Parent = lower
end

-- No springs anywhere. The sockets and their limits are the character, and everything above the
-- base is free to flop as far as its cone allows and no further.
local function buildCakeMan(): Model
	local man = Instance.new("Model")
	man.Name = "CakeMan"

	-- The body: four cake layers.
	local layers: { BasePart } = {}
	for i = 1, LAYERS do
		local w = LAYER_WIDTH[i]
		local size = Vector3.new(LAYER_SIZE.X * w, LAYER_SIZE.Y, LAYER_SIZE.Z * w)
		local layer = makeLayer("Layer" .. i, size, LAYER_COLOR[i], LAYER_DENSITY[i])
		layer.CFrame = CFrame.new(0, (i - 1) * LAYER_STEP, 0)
		layer.Parent = man
		layers[i] = layer
	end

	-- The base glides: a heavy box sliding on a plane, deliberately slippery. The FrictionWeight
	-- (the 5) makes his number win against whatever surface he is on.
	layers[1].CustomPhysicalProperties = PhysicalProperties.new(LAYER_DENSITY[1], 0.05, 0, 5, 1)
	man.PrimaryPart = layers[1] -- the bottom layer is the root. Forward is -Z.

	for i = 1, LAYERS - 1 do
		local jointY = (i - 1) * LAYER_STEP + LAYER_SIZE.Y / 2 + LAYER_GAP / 2
		-- The stack chains upward, so the cone opens around +Y: UpperAngle is how far a layer
		-- may lean in any direction, and twist is rotation about its own vertical.
		socket("Joint" .. i, layers[i], layers[i + 1], Vector3.new(0, jointY, 0), Vector3.yAxis, JOINT_ANGLE, JOINT_TWIST, BODY_FRICTION)
	end

	-- The head: a cherry on top, on the same kind of socket as everything else.
	local topY = (LAYERS - 1) * LAYER_STEP
	local head: BasePart
	if cherryTemplate then
		local c = (cherryTemplate :: MeshPart):Clone()
		c.Name = "Head"
		c.Size = HEAD_SIZE
		-- CreateMeshPartAsync hands back a mesh in default grey, not in whatever colour it was
		-- wearing in the place you copied it from, so colour it explicitly.
		c.Color = Color3.fromRGB(200, 30, 40)
		c.Material = Enum.Material.SmoothPlastic
		c.Reflectance = 0.25 -- glacé: it should catch the light like a wet sweet
		c.CustomPhysicalProperties = PhysicalProperties.new(HEAD_DENSITY, 0.3, 0.1, 1, 1)
		head = c
	else
		head = makePart("Head", HEAD_SIZE, Color3.fromRGB(200, 60, 70), HEAD_DENSITY)
	end
	-- The socket goes at the bottom of the head, which for a cherry means the bottom of the
	-- fruit, with the stem waving about above it. Because the mesh is mostly stem, the head's
	-- centre sits higher than you would expect and it has real leverage on the stack.
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

	-- The arms: noodles. Same construction as the body, just thinner, floppier and sideways.
	-- Nothing drives them; they get dragged around by the body and flail.
	--
	-- A grab needs an attachment to grab by, and you cannot create one inside the sim, so every
	-- part a fist could plausibly seize carries one from birth. These have to exist before the
	-- actuators are wired, because the fists' Grip and Reach constraints point at them -- and an
	-- AlignPosition with a nil attachment does not error, warn, or do anything.
	local function addGrabAttachments(m: Model)
		for _, p in m:GetDescendants() do
			if p:IsA("BasePart") and p.Name ~= "Head" and not p:FindFirstChild("GrabAtt") then
				local att = Instance.new("Attachment")
				att.Name = "GrabAtt"
				att.Parent = p
			end
		end
	end

	local fistSize = ARM_SIZE * FIST_SCALE
	for _, side in { { suffix = "L", x = -1 }, { suffix = "R", x = 1 } } do
		-- Shoulders on the top layer, set high on it, so the noodles dangle clear of the floor
		-- and have room to swing before the fists reach the ground.
		local shoulderY = (LAYERS - 1) * LAYER_STEP + 0.5
		-- Hang the whole arm clear of the widest thing on it (the fist), then pull it back in by
		-- SHOULDER_INSET so the arms sit on him rather than held out at arm's length.
		local x = side.x * (LAYER_SIZE.X * LAYER_WIDTH[LAYERS] / 2 + fistSize.X / 2 + GAP - SHOULDER_INSET)
		local prev: BasePart = layers[LAYERS]
		local jointY = shoulderY -- walks down the arm, joint by joint

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
			-- Arms collide -- with the cake, the floor and other players. They are flails, not
			-- decoration. They still can't hit the segment they're jointed to, because socket()
			-- adds a NoCollisionConstraint for that pair.
			arm.CanCollide = true
			arm.Parent = man

			-- Arms chain downward, so the cone opens around -Y: each link may bend ARM_ANGLE away
			-- from hanging straight down, in any direction.
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

	addGrabAttachments(man) -- before the actuators are wired. See the note above.
	return man
end

-- Actuators. There are only two in the whole character and they are both on the base:
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

	-- The fists: two actuators each, both pre-created and both disabled, because you cannot
	-- create an instance inside the simulation -- it would be created again on every resimulated
	-- frame. Pre-wire everything the sim could need; the sim only sets targets and flips Enabled.
	local shoulders = man:FindFirstChild("Layer" .. LAYERS) :: BasePart

	for _, side in { "L", "R" } do
		local fist = man:FindFirstChild("Arm" .. side .. ARM_SEGMENTS) :: BasePart
		local grabAtt = fist:FindFirstChild("GrabAtt") :: Attachment

		-- The guard is an attachment on the top cake rather than a world position recomputed
		-- every step, so it leans, lags and wobbles with him and the simulation does no CFrame
		-- maths.
		local stance = Instance.new("Attachment")
		stance.Name = "Stance" .. side
		stance.Parent = shoulders
		stance.Position = Vector3.new(
			if side == "L" then -STANCE_WIDTH else STANCE_WIDTH,
			STANCE_RISE,
			-STANCE_DIST -- forward is -Z, same as everything else in this rig
		)

		-- Reach: hauls the fist out to the guard. The arm is a noodle, so dragging the fist
		-- somewhere drags the whole arm after it.
		--
		-- Two attachments rather than one, deliberately. A OneAttachment AlignPosition pulls its
		-- part toward a world coordinate and pulls against nothing, so the force has no source:
		-- throwing your hands forward doesn't rock your body back. That is free momentum, and
		-- players read free momentum as floaty long before they can say why. Anchored to the
		-- shoulders with ReactionForceEnabled, the same servo shoves the top cake the other way
		-- by exactly as much.
		local reach = Instance.new("AlignPosition")
		reach.Name = "Reach"
		reach.Mode = Enum.PositionAlignmentMode.TwoAttachment
		reach.Attachment0 = grabAtt -- the fist: this is the end that gets moved
		reach.Attachment1 = stance -- toward the guard, and the shoulders eat the recoil
		reach.ReactionForceEnabled = true
		reach.RigidityEnabled = false
		reach.MaxForce = REACH_FORCE
		reach.Responsiveness = 22
		reach.Enabled = false
		reach.Parent = fist

		-- Grip: what holds the thing you caught.
		--
		-- Attachment0 is the target (set when you grab something) and Attachment1 is the fist.
		-- That order matters, because AlignPosition drags Attachment0 toward Attachment1, and we
		-- want the box to come to the hand rather than the hand to the box.
		--
		-- MaxForce is the grip mechanic. Roblox doesn't expose the reaction force in a
		-- constraint, so you can't read tension directly -- but you don't need to. Give the grip
		-- a finite strength and it fails to hold anything too heavy or too determined: the gap
		-- between fist and target opens up, and that gap is the tension. Watch the gap, break the
		-- grip when it gets too wide, and a struggling opponent tears himself out of your hand.
		local grip = Instance.new("AlignPosition")
		grip.Name = "Grip"
		grip.Mode = Enum.PositionAlignmentMode.TwoAttachment
		grip.Attachment1 = grabAtt
		grip.RigidityEnabled = false
		grip.MaxForce = 55000 -- enough to hoist a limp cake, not enough to hold a fighting one
		grip.Responsiveness = 25
		grip.ReactionForceEnabled = true -- what you're carrying weighs on you, too
		grip.Enabled = false
		grip.Parent = fist
	end

	-- The base is the one part actively held upright and pointed where you're going.
	local align = Instance.new("AlignOrientation")
	align.Name = "Heading"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = false -- springy facing: it catches up, it doesn't snap
	-- A fast TURN_RATE in the sim is worthless if the servo that applies the rotation is slow,
	-- because the servo just becomes the new speed limit. Both have to be quick.
	align.Responsiveness = 40
	align.MaxTorque = 9e5
	align.Parent = base
end


-- Bake it.
local old = ServerStorage:FindFirstChild("CakeManRig")
if old then
	old:Destroy()
end

local rig = buildCakeMan()
rig.Name = "CakeManRig"
addActuators(rig)

-- Everything the spawner would otherwise do at runtime is baked in here instead: the tags, the
-- streaming mode, the lot. The spawner's job becomes "clone this".
for _, p in rig:GetDescendants() do
	if p:IsA("BasePart") then
		CollectionService:AddTag(p, PRESENTED_TAG)
	end
end
rig.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
rig.Parent = ServerStorage

print("[GenerateRig] baked ServerStorage.CakeManRig -- now stop the run and save the place")
