--!strict
-- Arena — builds the level (walls) and the props (cardboard boxes) at boot.
--
-- WHY THIS IS A SCRIPT AND NOT PART OF THE SIM, which is the whole Server Authority
-- lesson of this file:
--
--   The sim (CakeSim, via BindToSimulation) is re-run several times per frame during
--   reconciliation. Anything it CREATES, it would create again on every re-run. So
--   instance creation is forbidden in there -- it belongs in ordinary boot code like
--   this, which runs exactly once, on the server, before anyone is playing.
--
--   Everything below is therefore built by the SERVER and simply replicates. There is
--   no client-side "spawn the boxes" step, and there are no RemoteEvents anywhere:
--   the boxes are just physics objects the server owns. A client near them predicts
--   them for free (they're inside its ReplicationFocus radius) and reconciles against
--   the server exactly like it does for its own CakeMan.
--
--   The layout is generated from a FIXED SEED, so every server builds a byte-identical
--   arena. Never seed from the clock: two servers would disagree about where the world
--   is, and a rejoining player would arrive in a different level to everyone else.
--
--   And the level lives in code, not in the place file. Place-level geometry is
--   invisible to source control; a script that rebuilds it is not. You can diff it,
--   review it, and revert it.
local CollectionService = game:GetService("CollectionService")

local LAYOUT_SEED = 20260713

local ARENA_SIZE = 160 -- floor is ARENA_SIZE x ARENA_SIZE studs
local WALL_HEIGHT = 20
local WALL_THICK = 4

local BOX_SIZE = 3
local BOX_DENSITY = 0.008 -- CARDBOARD. Actually, EMPTY cardboard. This is the number
-- that makes the game funny, and it wants to be absurd: CakeMan's base layer is
-- density 8, so he now outweighs a box a thousand to one per unit volume. He doesn't
-- push these. He detonates them. Crank it to 1 and he's shoving crates around a
-- warehouse instead, which is a different (worse) game.
local BOX_FRICTION = 0.6 -- they tumble and skid to a stop rather than sliding forever
local BOX_ELASTICITY = 0.15 -- a little bounce; cardboard isn't a superball

local WALL_COLOR = Color3.fromRGB(96, 104, 120)
local FLOOR_COLOR = Color3.fromRGB(140, 146, 158)
local BOX_COLOR = Color3.fromRGB(193, 154, 107)

local rng = Random.new(LAYOUT_SEED)

-- The level owns the ground, so the default baseplate goes. (Same principle: the
-- script is the source of truth, not whatever happens to be sitting in the place.)
local baseplate = workspace:FindFirstChild("Baseplate")
if baseplate then
	baseplate:Destroy()
end

-- STREAMING, AND WHY THESE ARE MODELS AND NOT FOLDERS.
--
-- StreamingEnabled is on (and in a lot of places you don't get to turn it off). With
-- it on, the client is only sent the parts near it -- so half the level and a third of
-- the boxes simply DON'T EXIST on your machine until you walk over there. A prop the
-- client hasn't been sent cannot be predicted by the client, and that's what makes
-- props feel like they join the world late: you're not fighting prediction, you're
-- fighting the fact that the box wasn't there a moment ago.
--
-- There is no "local prediction" flag to flip -- I went looking, and prediction is
-- governed entirely by ReplicationFocus and an engine-managed simulation radius that
-- you don't get to set (nudge Player.SimulationRadius and the engine drifts it back).
--
-- What you CAN do is refuse to let the level stream out at all:
-- ModelStreamingMode.Persistent keeps a model loaded on every client, always,
-- regardless of distance -- with streaming still on for everything else. Folders have
-- no such setting, so the arena and the props become MODELS.
local arena = workspace:FindFirstChild("Arena")
if arena then
	arena:Destroy() -- rebuild cleanly on every boot; the script is the source of truth
end
arena = Instance.new("Model")
arena.Name = "Arena"
arena.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
arena.Parent = workspace

local oldProps = workspace:FindFirstChild("Props")
if oldProps then
	oldProps:Destroy()
end
local props = Instance.new("Model")
props.Name = "Props"
props.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
props.Parent = workspace

-- ---------------------------------------------------------------------------
-- Static geometry. ANCHORED, so the physics engine never simulates a single one of
-- these: they cost nothing, they can't drift, and they can't disagree between server
-- and client. Anything that doesn't need to move should be anchored -- it's the
-- cheapest correctness you will ever buy.
-- ---------------------------------------------------------------------------
local function wall(name: string, size: Vector3, position: Vector3)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Position = position
	p.Anchored = true
	p.Color = WALL_COLOR
	p.Material = Enum.Material.Concrete
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = arena
	return p
end

local half = ARENA_SIZE / 2

local floor = wall("Floor", Vector3.new(ARENA_SIZE, 2, ARENA_SIZE), Vector3.new(0, -1, 0))
floor.Color = FLOOR_COLOR
floor.Material = Enum.Material.Pebble
-- The floor gets the same low friction the rest of the world has for him: CakeMan is
-- a slab sliding on his bottom layer, and he's already deliberately slippery (his own
-- FrictionWeight wins the argument), so this is really just belt and braces.

wall("WallN", Vector3.new(ARENA_SIZE, WALL_HEIGHT, WALL_THICK), Vector3.new(0, WALL_HEIGHT / 2, -half))
wall("WallS", Vector3.new(ARENA_SIZE, WALL_HEIGHT, WALL_THICK), Vector3.new(0, WALL_HEIGHT / 2, half))
wall("WallE", Vector3.new(WALL_THICK, WALL_HEIGHT, ARENA_SIZE), Vector3.new(half, WALL_HEIGHT / 2, 0))
wall("WallW", Vector3.new(WALL_THICK, WALL_HEIGHT, ARENA_SIZE), Vector3.new(-half, WALL_HEIGHT / 2, 0))

-- A few interior walls so it's a level and not a car park: something to chase people
-- around, and something to pin them against.
wall("Pillar1", Vector3.new(10, WALL_HEIGHT, 10), Vector3.new(-40, WALL_HEIGHT / 2, -40))
wall("Pillar2", Vector3.new(10, WALL_HEIGHT, 10), Vector3.new(40, WALL_HEIGHT / 2, 40))
wall("Divider1", Vector3.new(WALL_THICK, WALL_HEIGHT, 50), Vector3.new(30, WALL_HEIGHT / 2, -35))
wall("Divider2", Vector3.new(50, WALL_HEIGHT, WALL_THICK), Vector3.new(-35, WALL_HEIGHT / 2, 30))

-- ---------------------------------------------------------------------------
-- The props. Ordinary dynamic parts: the server simulates them, they replicate, and
-- clients predict the ones near them automatically. No special networking code, and
-- crucially NO RemoteEvents -- "the box moved" is not a message, it's just physics.
--
-- They're tagged "Prop" so the presentation layer can find them later and smooth them
-- the same way it smooths characters (a client-side visual proxy chasing the truth).
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
	CollectionService:AddTag(b, "Prop")
	return b
end

-- A pyramid of boxes: wide at the bottom, one on top, so it collapses satisfyingly.
-- Boxes are stacked on a PITCH slightly wider than they are, so neighbours never quite
-- touch and the jitter below can't overlap them. At this density even a hair of
-- interpenetration gets resolved as a launch.
local BOX_PITCH = BOX_SIZE + 0.15

local function pile(centre: Vector3, baseWidth: number)
	for row = 0, baseWidth - 1 do
		local perSide = baseWidth - row
		local y = BOX_SIZE / 2 + row * BOX_PITCH
		for ix = 0, perSide - 1 do
			for iz = 0, perSide - 1 do
				local spread = (perSide - 1) * BOX_PITCH / 2
				-- A whisper of jitter so the stacks look hand-piled rather than
				-- extruded, and so they topple asymmetrically. From the SEEDED rng,
				-- so it's the same whisper on every server -- and small enough to stay
				-- inside the pitch's slack.
				local jx = rng:NextNumber(-0.05, 0.05)
				local jz = rng:NextNumber(-0.05, 0.05)
				box(
					centre + Vector3.new(ix * BOX_PITCH - spread + jx, y, iz * BOX_PITCH - spread + jz),
					rng:NextNumber(-0.05, 0.05)
				)
			end
		end
	end
end

local PILES = {
	{ centre = Vector3.new(-20, 0, -20), width = 3 },
	{ centre = Vector3.new(25, 0, -30), width = 4 },
	{ centre = Vector3.new(-45, 0, 15), width = 3 },
	{ centre = Vector3.new(50, 0, 20), width = 3 },
	{ centre = Vector3.new(0, 0, 45), width = 4 },
	{ centre = Vector3.new(-15, 0, 60), width = 2 },
	{ centre = Vector3.new(60, 0, -55), width = 2 },
}
for _, p in PILES do
	pile(p.centre, p.width)
end

-- Loose boxes scattered about, to be tripped over.
--
-- SPAWN THEM CLEAR OF EVERYTHING, and this matters far more than it looks. A box that
-- spawns overlapping a pile or a wall has to be pushed apart by the solver, and an
-- impulse that would merely nudge a crate LAUNCHES a box this light: they were sailing
-- over the 20-stud walls, out of the arena, and falling until FallenPartsDestroyHeight
-- ate them. Five boxes a match, quietly vanishing before anyone touched them.
-- The lighter the prop, the more carefully it has to be placed.
local KEEP_CLEAR = 14 -- studs from any pile centre / interior wall
local INTERIOR = { Vector3.new(-40, 0, -40), Vector3.new(40, 0, 40), Vector3.new(30, 0, -35), Vector3.new(-35, 0, 30) }

local function isClear(pos: Vector3): boolean
	for _, p in PILES do
		if (Vector3.new(pos.X, 0, pos.Z) - p.centre).Magnitude < KEEP_CLEAR + p.width * BOX_SIZE / 2 then
			return false
		end
	end
	for _, w in INTERIOR do
		if (Vector3.new(pos.X, 0, pos.Z) - w).Magnitude < KEEP_CLEAR + 25 then
			return false
		end
	end
	return true
end

local placed = 0
local attempts = 0
while placed < 14 and attempts < 400 do
	attempts += 1
	local pos = Vector3.new(rng:NextNumber(-half + 20, half - 20), BOX_SIZE / 2, rng:NextNumber(-half + 20, half - 20))
	if isClear(pos) then
		box(pos, rng:NextNumber(0, math.pi * 2))
		placed += 1
	end
end

print(string.format("[Arena] built: %d walls, %d boxes", #arena:GetChildren(), #props:GetChildren()))
