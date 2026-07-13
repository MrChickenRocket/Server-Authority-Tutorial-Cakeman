--!strict
-- GenerateArena — BUILDS the level, once, as real instances in the Workspace.
--
-- THIS SCRIPT IS DISABLED. See ServerStorage.GenerateRig for the reasoning; the short
-- version is that a level you can open in the explorer, select, nudge, and recolour beats
-- a level that only exists while the server is running.
--
-- What it makes:
--   workspace.Arena  -- the slabs, bridges, walls and cover. Anchored, Persistent.
--   workspace.Props  -- the cardboard boxes. Dynamic, Persistent, tagged.
--
-- The boxes' RUNTIME behaviour (falling into the void, going to limbo, being restocked)
-- is NOT here -- it lives in ServerScriptService.BoxRecycle, which is enabled and runs
-- every game. Generation and behaviour are different jobs and belong in different files:
-- one runs once when a designer says so, the other runs forever while people play.
--
-- To rebuild the level: set Disabled = false, press Play, stop, and SAVE THE PLACE.
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

-- A lip is PAINT, not architecture. The first version made them solid, and they were
-- half a stud tall, and CakeMan is a legless slab that glides -- so he couldn't get over
-- one. Every player was hard-stuck in their own base by a decorative kerb, which took an
-- embarrassingly long time to work out because it looks exactly like "the character is
-- broken" rather than "the floor has a fence around it".
-- If a thing exists to be LOOKED at, it should not be able to stop anybody.
local function lip(name: string, size: Vector3, cf: CFrame, color: Color3)
	local p = block(name, size, cf, color)
	p.CanCollide = false
	p.CanTouch = false
	p.Material = Enum.Material.SmoothPlastic
end

local half = ARENA_SIZE / 2

-- THE LAYOUT.
--
-- One central platform, four home bases on the compass points, and four short bridges
-- joining them. Everything else -- the whole diagonal -- is a pit. So every base is an
-- island, the only way in or out is a bridge, and the bridge is exactly wide enough for
-- two cakes to have a disagreement on.
--
-- The mistake in the first version was making the gaps *narrow*. A 6-stud slot doesn't
-- read as a pit, it reads as a crack in the floor, and you don't fear it. Give the void
-- room: if a player can't see that a fall would be a long one, they won't play around
-- it, and then the level has no shape.
local CENTRE = 44 -- the central platform: 44 x 44, everyone's problem
local BASE = 38 -- each home base
local BASE_DIST = 54 -- how far out the bases sit (the gap is what's left over)
local BRIDGE_W = 13 -- narrow. This is the interesting part of the map.

-- One colour per base, so you always know whose ground you're standing on -- and, in a
-- free-for-all, which way is home when you're upside down and on fire.
local BASES = {
	{ name = "North", pos = Vector3.new(0, 0, -BASE_DIST), color = Color3.fromRGB(214, 78, 84) },
	{ name = "East", pos = Vector3.new(BASE_DIST, 0, 0), color = Color3.fromRGB(78, 138, 214) },
	{ name = "South", pos = Vector3.new(0, 0, BASE_DIST), color = Color3.fromRGB(96, 190, 106) },
	{ name = "West", pos = Vector3.new(-BASE_DIST, 0, 0), color = Color3.fromRGB(222, 182, 72) },
}

local function slab(name: string, size: Vector3, cf: CFrame, color: Color3, lipColor: Color3)
	local p = block(name, size, cf, color)
	p.Material = Enum.Material.Pebble
	-- A lip around every edge, so a pit is something you SEE COMING rather than
	-- something you discover.
	local x, y, z = cf.Position.X, cf.Position.Y + size.Y / 2 + 0.05, cf.Position.Z
	lip(name .. "_LipN", Vector3.new(size.X, 0.2, 1.2), CFrame.new(x, y, z - size.Z / 2), lipColor)
	lip(name .. "_LipS", Vector3.new(size.X, 0.2, 1.2), CFrame.new(x, y, z + size.Z / 2), lipColor)
	lip(name .. "_LipE", Vector3.new(1.2, 0.2, size.Z), CFrame.new(x + size.X / 2, y, z), lipColor)
	lip(name .. "_LipW", Vector3.new(1.2, 0.2, size.Z), CFrame.new(x - size.X / 2, y, z), lipColor)
end

-- The central platform.
slab("Centre", Vector3.new(CENTRE, 2, CENTRE), CFrame.new(0, FLOOR_Y - 1, 0), FLOOR_COLOR, EDGE_COLOR)

-- The four bases, each in its own colour, and the bridge that connects it to the middle.
-- The bridge spans the void between the centre platform's edge and the base's edge.
for _, b in BASES do
	slab("Base" .. b.name, Vector3.new(BASE, 2, BASE), CFrame.new(b.pos + Vector3.new(0, FLOOR_Y - 1, 0)), b.color, b.color)

	local dir = b.pos.Unit -- outward from the middle
	local innerEdge = CENTRE / 2 -- where the centre platform stops
	local baseEdge = BASE_DIST - BASE / 2 -- where the base starts
	local span = baseEdge - innerEdge
	local mid = dir * (innerEdge + span / 2)
	local size = if math.abs(dir.X) > 0.5
		then Vector3.new(span, 1.5, BRIDGE_W)
		else Vector3.new(BRIDGE_W, 1.5, span)
	slab("Bridge" .. b.name, size, CFrame.new(mid + Vector3.new(0, FLOOR_Y - 0.75, 0)), RAMP_COLOR, b.color)
end

-- The outer walls. Tall, because CakeMen get launched.
block("WallN", Vector3.new(ARENA_SIZE + WALL_THICK * 2, WALL_HEIGHT, WALL_THICK), CFrame.new(0, WALL_HEIGHT / 2, -half), WALL_COLOR)
block("WallS", Vector3.new(ARENA_SIZE + WALL_THICK * 2, WALL_HEIGHT, WALL_THICK), CFrame.new(0, WALL_HEIGHT / 2, half), WALL_COLOR)
block("WallE", Vector3.new(WALL_THICK, WALL_HEIGHT, ARENA_SIZE), CFrame.new(half, WALL_HEIGHT / 2, 0), WALL_COLOR)
block("WallW", Vector3.new(WALL_THICK, WALL_HEIGHT, ARENA_SIZE), CFrame.new(-half, WALL_HEIGHT / 2, 0), WALL_COLOR)

-- COVER, in the middle. A few blunt walls, no ramps.
--
-- There WAS a raised podium with ramps up to it, and it was a lot of geometry to
-- maintain for very little: you have to build a ramp per entrance or players from the
-- wrong side just drive into a wall, the ramp angle is bounded by the fact that CakeMan
-- has no friction and climbs by thrust alone, and none of it changed the fight. Walls do
-- the same job -- break sightlines, give you something to shove people into, stop the
-- middle being a featureless dinner plate -- and they're four lines.
--
-- Cut the thing that costs you geometry and gives you nothing.
local WALL_H = 9
block("CoverA", Vector3.new(3, WALL_H, 20), CFrame.new(-13, WALL_H / 2, -6), RAMP_COLOR)
block("CoverB", Vector3.new(3, WALL_H, 20), CFrame.new(13, WALL_H / 2, 6), RAMP_COLOR)
block("CoverC", Vector3.new(16, WALL_H, 3), CFrame.new(6, WALL_H / 2, -14), RAMP_COLOR)
block("CoverD", Vector3.new(16, WALL_H, 3), CFrame.new(-6, WALL_H / 2, 14), RAMP_COLOR)

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

-- Piles sit ON the slabs, never over a pit. Ammunition, basically: every box is a thing
-- you can launch at somebody, and the piles are where you go to get some.
for _, b in BASES do
	pile(b.pos + Vector3.new(-11, 0, -11), 2) -- a small stack in each base's back corner
	pile(b.pos + Vector3.new(11, 0, 11), 2)
end
pile(Vector3.new(-15, 0, 8), 3) -- and bigger heaps in the middle, tucked behind cover
pile(Vector3.new(15, 0, -8), 3)
pile(Vector3.new(0, 0, 0), 2) -- and one right in the centre, as bait


print(string.format("[GenerateArena] baked %d arena parts and %d boxes -- now STOP and SAVE THE PLACE",
	#arena:GetChildren(), #props:GetChildren()))
