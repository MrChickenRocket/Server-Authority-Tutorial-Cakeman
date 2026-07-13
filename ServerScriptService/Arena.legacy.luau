--!strict
-- Arena — builds the level (walls, ramps, death pits) and the props at boot.
--
-- WHY THIS IS A SCRIPT AND NOT PART OF THE SIM, which is the whole Server Authority
-- lesson of this file:
--
--   The sim (CakeSim, via BindToSimulation) is re-run several times per frame during
--   reconciliation. Anything it CREATES, it would create again on every re-run. So
--   instance creation is forbidden in there -- it belongs in ordinary boot code like
--   this, which runs exactly once, on the server, before anyone is playing.
--
--   Everything below is built by the SERVER and simply replicates. There is no
--   client-side "spawn the boxes" step, and there are no RemoteEvents anywhere: the
--   boxes are just physics objects the server owns. A client near them predicts them
--   for free and reconciles against the server exactly like it does for its own CakeMan.
--
--   The layout comes from a FIXED SEED, so every server builds a byte-identical arena.
--   Never seed from the clock: two servers would disagree about where the world is.
--
--   And the level lives in code, not in the place file. Place geometry is invisible to
--   source control; a script that rebuilds it is not.
local CollectionService = game:GetService("CollectionService")

local LAYOUT_SEED = 20260713

local ARENA_SIZE = 160
local WALL_HEIGHT = 24
local WALL_THICK = 4
local FLOOR_Y = 0

-- Death pits. Falling in is how you lose a cake, and the arena is built AROUND them --
-- the floor is not one slab with holes cut in it, it's slabs arranged so the holes are
-- what's left over. Anything that isn't floor is a long way down.
local PIT_DEPTH = 200 -- how far below the floor the kill plane sits
local KILL_Y = -40 -- fall past this and you're out (see CakeServer's respawn watch)

local BOX_SIZE = 3
local BOX_PITCH = BOX_SIZE + 0.15
local BOX_DENSITY = 0.008 -- EMPTY cardboard. He doesn't push these, he detonates them.
local BOX_FRICTION = 0.6
local BOX_ELASTICITY = 0.15

local WALL_COLOR = Color3.fromRGB(96, 104, 120)
local FLOOR_COLOR = Color3.fromRGB(140, 146, 158)
local RAMP_COLOR = Color3.fromRGB(120, 128, 145)
local EDGE_COLOR = Color3.fromRGB(210, 90, 70) -- pit lips, so you can SEE the danger
local BOX_COLOR = Color3.fromRGB(193, 154, 107)

local rng = Random.new(LAYOUT_SEED)

-- The default baseplate goes: the level owns the ground.
local baseplate = workspace:FindFirstChild("Baseplate")
if baseplate then
	baseplate:Destroy()
end
for _, name in { "Arena", "Props" } do
	local old = workspace:FindFirstChild(name)
	if old then
		old:Destroy()
	end
end

-- ModelStreamingMode.Persistent: keep the level loaded on every client regardless of
-- distance. With streaming on (and you often don't get to turn it off), the client is
-- only sent what's near it -- and a prop the client hasn't been sent cannot be
-- predicted. Folders have no such setting, so these are Models.
local arena = Instance.new("Model")
arena.Name = "Arena"
arena.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
arena.Parent = workspace

local props = Instance.new("Model")
props.Name = "Props"
props.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
props.Parent = workspace

-- ---------------------------------------------------------------------------
-- Static geometry. ANCHORED, so the physics engine never simulates one of these: they
-- cost nothing, can't drift, and can't disagree between server and client. Anything
-- that doesn't need to move should be anchored -- the cheapest correctness there is.
-- ---------------------------------------------------------------------------
local function block(name: string, size: Vector3, cf: CFrame, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.Color = color
	p.Material = Enum.Material.Concrete
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = arena
	return p
end

local half = ARENA_SIZE / 2

-- FLOOR SLABS, laid out so the gaps between them ARE the pits. Four quadrant slabs and
-- a central cross of walkways: you can always get anywhere, but never in a straight
-- line, and the routes between are exactly wide enough to shove someone off.
local function floorSlab(name: string, x: number, z: number, sx: number, sz: number)
	local p = block(name, Vector3.new(sx, 2, sz), CFrame.new(x, FLOOR_Y - 1, z), FLOOR_COLOR)
	p.Material = Enum.Material.Pebble
	-- A red lip around every slab, so a pit edge is something you can see coming rather
	-- than something you discover.
	block(name .. "_LipN", Vector3.new(sx, 0.4, 1), CFrame.new(x, FLOOR_Y + 0.1, z - sz / 2 + 0.5), EDGE_COLOR)
	block(name .. "_LipS", Vector3.new(sx, 0.4, 1), CFrame.new(x, FLOOR_Y + 0.1, z + sz / 2 - 0.5), EDGE_COLOR)
	block(name .. "_LipE", Vector3.new(1, 0.4, sz), CFrame.new(x + sx / 2 - 0.5, FLOOR_Y + 0.1, z), EDGE_COLOR)
	block(name .. "_LipW", Vector3.new(1, 0.4, sz), CFrame.new(x - sx / 2 + 0.5, FLOOR_Y + 0.1, z), EDGE_COLOR)
end

-- four corner platforms
floorSlab("SlabNW", -45, -45, 62, 62)
floorSlab("SlabNE", 45, -45, 62, 62)
floorSlab("SlabSW", -45, 45, 62, 62)
floorSlab("SlabSE", 45, 45, 62, 62)
-- the crossroads in the middle, and the bridges to it
floorSlab("Centre", 0, 0, 30, 30)
floorSlab("BridgeN", 0, -45, 16, 62)
floorSlab("BridgeS", 0, 45, 16, 62)
floorSlab("BridgeW", -45, 0, 62, 16)
floorSlab("BridgeE", 45, 0, 62, 16)

-- The outer walls. Tall, because CakeMen get launched.
block("WallN", Vector3.new(ARENA_SIZE + WALL_THICK * 2, WALL_HEIGHT, WALL_THICK), CFrame.new(0, WALL_HEIGHT / 2, -half), WALL_COLOR)
block("WallS", Vector3.new(ARENA_SIZE + WALL_THICK * 2, WALL_HEIGHT, WALL_THICK), CFrame.new(0, WALL_HEIGHT / 2, half), WALL_COLOR)
block("WallE", Vector3.new(WALL_THICK, WALL_HEIGHT, ARENA_SIZE), CFrame.new(half, WALL_HEIGHT / 2, 0), WALL_COLOR)
block("WallW", Vector3.new(WALL_THICK, WALL_HEIGHT, ARENA_SIZE), CFrame.new(-half, WALL_HEIGHT / 2, 0), WALL_COLOR)

-- RAMPS up to a raised centre platform: high ground, and a great place to be shoved off.
local RAISED_Y = 9
block("Podium", Vector3.new(26, 2, 26), CFrame.new(0, RAISED_Y, 0), RAMP_COLOR)
block("PodiumLipN", Vector3.new(26, 0.5, 1), CFrame.new(0, RAISED_Y + 1.2, -12.5), EDGE_COLOR)
block("PodiumLipS", Vector3.new(26, 0.5, 1), CFrame.new(0, RAISED_Y + 1.2, 12.5), EDGE_COLOR)

-- A ramp is just a rotated slab. Keep them SHALLOW -- CakeMan slides on his bottom layer
-- with almost no friction (that's how he glides), so a steep ramp is a slide, not a
-- climb, and he'll never get up it.
local RAMP_RISE = math.rad(14)
block("RampW", Vector3.new(24, 1.5, 20), CFrame.new(-22, RAISED_Y / 2 + 0.5, 0) * CFrame.Angles(0, 0, -RAMP_RISE), RAMP_COLOR)
block("RampE", Vector3.new(24, 1.5, 20), CFrame.new(22, RAISED_Y / 2 + 0.5, 0) * CFrame.Angles(0, 0, RAMP_RISE), RAMP_COLOR)

-- Kill plane. Anything that falls this far is gone; CakeServer watches for it.
local void = block("Void", Vector3.new(ARENA_SIZE * 2, 2, ARENA_SIZE * 2), CFrame.new(0, -PIT_DEPTH, 0), Color3.fromRGB(20, 20, 26))
void.CanCollide = false
void.Transparency = 1
arena:SetAttribute("KillY", KILL_Y)

-- ---------------------------------------------------------------------------
-- The props. Ordinary dynamic parts: the server simulates them, they replicate, and
-- clients near them predict them. No networking code, and NO RemoteEvents -- "the box
-- moved" is not a message, it's physics.
-- ---------------------------------------------------------------------------
local function box(position: Vector3, angle: number): Part
	local b = Instance.new("Part")
	b.Name = "Box"
	b.Size = Vector3.new(BOX_SIZE, BOX_SIZE, BOX_SIZE)
	b.CFrame = CFrame.new(position) * CFrame.Angles(0, angle, 0)
	b.Color = BOX_COLOR
	b.Material = Enum.Material.Cardboard
	b.TopSurface = Enum.SurfaceType.Smooth
	b.BottomSurface = Enum.SurfaceType.Smooth
	b.CustomPhysicalProperties = PhysicalProperties.new(BOX_DENSITY, BOX_FRICTION, BOX_ELASTICITY, 1, 1)
	b.Parent = props

	-- Two tags, because they mean two different things, and conflating them is how you
	-- end up with a tag called "Prop" that secretly also means "smooth me":
	--   Prop      -- what it IS (gameplay)
	--   Presented -- what should be DONE to it (rendering)
	--   Grabbable -- what can be done TO it (a fist can grab this)
	CollectionService:AddTag(b, "Prop")
	CollectionService:AddTag(b, "Presented")
	CollectionService:AddTag(b, "Grabbable")

	-- A grab needs somewhere to attach to, and you cannot create an Attachment inside
	-- the sim. So every grabbable thing carries one from birth. Pre-wire what the sim
	-- will need; the sim only ever sets targets.
	local att = Instance.new("Attachment")
	att.Name = "GrabAtt"
	att.Parent = b

	return b
end

local function pile(centre: Vector3, baseWidth: number)
	for row = 0, baseWidth - 1 do
		local perSide = baseWidth - row
		local y = BOX_SIZE / 2 + row * BOX_PITCH
		for ix = 0, perSide - 1 do
			for iz = 0, perSide - 1 do
				local spread = (perSide - 1) * BOX_PITCH / 2
				box(
					centre
						+ Vector3.new(
							ix * BOX_PITCH - spread + rng:NextNumber(-0.05, 0.05),
							y,
							iz * BOX_PITCH - spread + rng:NextNumber(-0.05, 0.05)
						),
					rng:NextNumber(-0.05, 0.05)
				)
			end
		end
	end
end

-- Piles sit ON the slabs, never over a pit.
local PILES = {
	{ centre = Vector3.new(-45, 0, -45), width = 3 },
	{ centre = Vector3.new(45, 0, -45), width = 4 },
	{ centre = Vector3.new(-45, 0, 45), width = 4 },
	{ centre = Vector3.new(45, 0, 45), width = 3 },
	{ centre = Vector3.new(0, 0, -45), width = 2 },
	{ centre = Vector3.new(0, 0, 45), width = 2 },
	{ centre = Vector3.new(0, RAISED_Y + 1, 0), width = 2 }, -- on the podium, as bait
}
for _, p in PILES do
	pile(p.centre, p.width)
end

print(string.format("[Arena] built: %d parts, %d boxes", #arena:GetChildren(), #props:GetChildren()))
