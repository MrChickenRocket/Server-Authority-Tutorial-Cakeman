# 2. The cake with noodle arms

Chapter 1 built a cube that is server-owned, predicted and smooth. This chapter replaces
the cube with **CakeMan**: four cake layers stacked on ball sockets, a glacé cherry for a
head, and two five-segment arms ending in heavy fists. He is entirely physics. Nothing
about him is animated.

To drive him first, open [`samples/cakemanplace/`](../samples/cakemanplace/) and press
**Test → Server & Clients**.

## What changes, and what doesn't

| File from Chapter 1 | What happens to it |
|---|---|
| `CubePresent` → `Presentation` | **Nothing.** It presents anything tagged `Presented`. A cake is 15 tagged parts instead of 1. |
| `CubeClient` → `CakeClient` | **Nothing structural.** Same camera, same `CameraDir` feed. |
| `CubeServer` → `CakeServer` | Spawns by **cloning a rig** instead of building a Part. |
| `CubeSim` → `CakeSim` | Same velocity servo. It gains a feed-forward term, a hop, and has to haul a whole stack. |

The cube already handed a force to the solver every step, so this chapter changes no
technique — it changes the body the technique is pointed at. One file is genuinely new, and
it arrives at the end: `CakePunch`.

## The thesis: the ragdoll is the character

There is a tempting way to build a character like this: simulate a tidy invisible capsule,
then hang a wobbly puppet off it for show. The result *looks* physical and isn't. It can't
be knocked over, its arms can't catch on anything, and every collision has to be faked.

Do the opposite. The parts you see are the parts the solver is working on.

The mechanism is one property of ball sockets: **they don't merge assemblies.** Every part
stays its own rigid body, connected by a constraint. Shove the bottom layer and the layers
above it get dragged along through the joints — *late*. That lag is the wobble.

---

## Part 1 — build the rig

### Step 1 — Bake the rig as an artefact, with the recipe beside it

The rig is a real Model saved in the place: `ServerStorage.CakeManRig`. The script that
*produced* it lives in source control as
[`ServerStorage/GenerateRig.legacy.luau`](../ServerStorage/GenerateRig.legacy.luau) and is
never part of the running game — keep it `Disabled` if you sync it into the place.

Run the recipe by hand when you want to change the character, then **stop and save the
place**.

You get both halves: an inspectable artefact you can select and look at in the explorer,
and a diffable, commented description of how it was made. The alternative — building
everything at boot from `Instance.new` — gives you the second without the first, and you
cannot point a joint gizmo at a character that doesn't exist yet.

The cost is that **an instance in the place can be wrong in ways code cannot**: someone
deletes an attachment, an edit goes unsaved, a constraint loses a reference. Which is Step 2.

### Step 2 — Check the rig at spawn, out loud

**A constraint with a nil `Attachment` does not error.** It does not warn. It applies
exactly zero force, forever, in silence — and every symptom points at tuning rather than at
wiring.

So state the contract and check it every time you clone a man:

```lua
-- CakeServer: spawning is now a CLONE. Joints, actuators, attachments, tags and
-- streaming mode all already exist in the template.
local rigTemplate = ServerStorage:WaitForChild("CakeManRig") :: Model

local function checkRig(man: Model)
	local base = man.PrimaryPart
	local att = base and base:FindFirstChild("DriveAtt") :: Attachment?
	local thrust = base and base:FindFirstChild("Thrust") :: VectorForce?
	local heading = base and base:FindFirstChild("Heading") :: AlignOrientation?

	if not (att and thrust and heading) then
		warn("[CakeServer] rig is missing DriveAtt/Thrust/Heading -- he will not move at all")
		return
	end
	if thrust.Attachment0 == nil then
		warn("[CakeServer] Thrust has NO Attachment0 -- it will apply zero force, forever. "
			.. "Re-run GenerateRig and SAVE THE PLACE.")
	end
	if heading.Attachment0 == nil then
		warn("[CakeServer] Heading has NO Attachment0 -- nothing is holding him upright")
	end
end

local function spawnCakeManFor(player: Player)
	buildInputContext(player) -- unchanged from Chapter 1

	local man = rigTemplate:Clone()
	man.Name = "CakeMan_" .. player.UserId
	checkRig(man)
	man:PivotTo(CFrame.new(SPAWNS[((spawnIndex - 1) % #SPAWNS) + 1]))
	man.Parent = menFolder

	-- The same two lines from Chapter 1. They do not change.
	player.ReplicationFocus = man.PrimaryPart
	player.Character = man
end
```

A clone remaps its own internal references: every constraint in the copy points at the
copy's attachments. That is why the rig has to be built as **one Model** rather than wired
up after parenting.

**Check:** the output window is silent at spawn.

### Step 3 — Write the socket helper

Every joint in the character is the same construction:

```lua
local function socket(name, lower, upper, jointPos, axis, angle, twist, friction)
	local frame = axisFrame(jointPos, axis)

	local a0 = Instance.new("Attachment")
	a0.Parent = lower        -- PARENT FIRST
	a0.WorldCFrame = frame   -- then position. This order, not the other one.
	local a1 = Instance.new("Attachment")
	a1.Parent = upper
	a1.WorldCFrame = frame

	local j = Instance.new("BallSocketConstraint")
	j.Attachment0, j.Attachment1 = a0, a1
	j.LimitsEnabled = true
	j.UpperAngle = angle
	j.TwistLimitsEnabled = true
	j.TwistLowerAngle, j.TwistUpperAngle = -twist, twist
	j.MaxFrictionTorque = friction
	j.Parent = lower

	-- Adjacent jointed parts grind on each other and buzz. Never let them collide.
	local nc = Instance.new("NoCollisionConstraint")
	nc.Part0, nc.Part1 = lower, upper
	nc.Parent = lower
end
```

**Parent the attachment before you position it.** An `Attachment` with no parent has no
world to be positioned in, so setting `WorldCFrame` first is silently discarded, every
joint ends up at its part's origin, and the character collapses into a pile of itself.

**Point the cone axis down the chain.** `BallSocketConstraint` measures its cone
(`UpperAngle`) around the attachment's **X axis**, and twist about the same axis. An
attachment built with `CFrame.new(pos)` points its X axis along world **+X**, so if your
limb chains along **Y** the cone is lying on its side — the joint bends on its twist axis
and twists on its bend axis, and nothing tells you.

```lua
local function axisFrame(pos: Vector3, axis: Vector3): CFrame
	local x = axis.Unit
	local helper = if math.abs(x.Y) > 0.9 then Vector3.zAxis else Vector3.yAxis
	local y = (helper - x * helper:Dot(x)).Unit
	return CFrame.fromMatrix(pos, x, y)
end
```

Pass `Vector3.yAxis` for the cake stack and `-Vector3.yAxis` for the arms.

**Check:** `joint.Attachment0.WorldCFrame.RightVector` should point along the limb — `(0, 1,
0)` up the stack. Then turn the joint gizmos on and look at them. This one is invisible in
code review and obvious in a picture.

### Step 4 — Set the cone angles

**Every joint in the body is an inverted pendulum.** The socket sits *below* its layer's
centre of mass, so with no restoring force a layer will always topple to its cone limit and
rest there.

The cone limit is therefore his resting pose, and a fully-slumped CakeMan still has to look
like a standing cake:

```lua
local JOINT_ANGLE = 6   -- degrees, per joint. Three joints. He leans ~18 at worst.
local JOINT_TWIST = 10
```

He is always falling over, and always already caught. That is the wobble.

The arms are the exception, and it is the same fact inverted: a hanging chain is a normal
pendulum, which is stable. Arms can be as floppy as you like — 45° cones, five segments, a
fist on the end.

### Step 5 — Give him a waist

Uniform slabs read as a column. Scale the middle two layers out and he reads as a cake:

```lua
local LAYER_WIDTH = { 1, 1.3, 1.2, 1 } -- bottom to top
```

Scale **X and Z only**. Leave the pitch alone and every joint, the head and the shoulders
stay exactly where they were.

Then pull the shoulders back in from the point that merely clears the fist:

```lua
local SHOULDER_INSET = 0.5 -- studs, off each side
```

Clearing the fist is the constraint — any less and the arms spawn inside the cake. The
inset is taste.

Two consequences. **Mass follows width squared**, so the bulge adds weight up high; widen
much further and take density back out. And **the widest part of him is now at chest
height**, so he catches on scenery his base would have cleared.

### Step 6 — Use joint friction, not springs

A frictionless ball socket is a perfect bearing: it rattles, swings forever, and sags to
its limit.

Springs are the tempting fix, and for this look they are the wrong tool — a torque strong
enough to stand him up also cancels the lag that reads as cake. There is no spring value
that wobbles *and* stands up.

One property does the job:

```lua
local BODY_FRICTION = 700 -- the stack: firm, doughy, holds its shape
local NECK_FRICTION = 90  -- the head: bobbles more freely
-- ...passed through to each joint as j.MaxFrictionTorque
```

Friction makes a joint hold its pose until something bigger than gravity comes along, then
deform, and *stay* deformed. That plastic behaviour is what cake does.

**Keep the upper layers light** — densities 8 / 0.5 / 0.35 / 0.2, bottom to top. Less
gravity torque to resist means cheaper friction, and joint friction is expensive: wound up
too high it effectively welds the joints and the solver burns your thrust fighting the
character's own constraints.

### Step 7 — Keep the mesh a costume and the physics a box

The layers and the head are `MeshPart`s, cloned from meshes and resized.

**`AssetService:CreateMeshPartAsync` is the only way a Script can choose collision
fidelity** — you cannot assign `CollisionFidelity` on a MeshPart from a Script, only ask
for it at creation:

```lua
local mesh = AssetService:CreateMeshPartAsync(assetId, {
	CollisionFidelity = Enum.CollisionFidelity.Box,
	RenderFidelity = Enum.RenderFidelity.Precise,
})
```

`Box` is deliberate. Precise collision on a wobbly cake buys nothing except a solver that
has to think about icing.

**Check what a mesh's bounding box actually contains.** The cherry is mostly stem, so
sizing it by height gives a comically tall head. Size by width and let the rest follow:

```lua
local CHERRY_WIDTH = 1.9 -- the only number we choose; the rest follows
local HEAD_SIZE = CHERRY_SOURCE * (CHERRY_WIDTH / CHERRY_SOURCE.X)
```

Keep the head light on a loose neck. A heavy head on a loose socket drags the whole stack
around.

### Step 8 — Pre-wire every actuator, switched off

**The simulation may not create instances.** It re-runs several times a frame during
reconciliation, so an `Instance.new` in there runs again on every replayed step.

So build the rig with every actuator already in place and `Enabled = false`. The
simulation's entire job is to flip switches and write targets.

| Instance | On | What it does |
|---|---|---|
| `DriveAtt` | base | the one attachment everything drives through |
| `Thrust` (`VectorForce`) | base | walking (Step 10) |
| `Heading` (`AlignOrientation`) | base | keeps him upright and pointed (Step 12) |

Two rules for anything you add to that list.

**Build the attachments before the constraints that point at them.** A constraint whose
`Attachment1` is assigned before that attachment exists comes up nil and applies zero force
forever, silently.

**Anchor a servo to the body, never to the world.** A `OneAttachment` `AlignPosition` drags
its part toward a world coordinate and the equal-and-opposite force goes nowhere — nothing
else feels it, so the body never recoils and players read the conjured momentum as floaty.
Use `TwoAttachment` with `ReactionForceEnabled = true`, anchored to another part of the
character, and the force pays for itself out of his own posture.

### Step 9 — Tag every part, and make the model persistent

```lua
CollectionService:AddTag(part, "Presented")
model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
```

`Presented` is the same tag from Chapter 1, so `Presentation.luau` needs no changes at all.
Bake the tag into the template rather than applying it at spawn.

`Persistent` is a correctness requirement: **an instance the client was never sent cannot
be predicted.**

---

## Part 2 — replace the brain's drive step

`CakeSim` keeps the exact shape of `CubeSim` — owner reads input into attributes, every
peer drives actuators from those attributes — and obeys the same four rules. Only `drive()`
changes.

### Step 10 — Add a feed-forward term to the servo

```lua
local along = vFlat:Dot(moveDir)
local ffScale = math.clamp(1 - (along - TARGET_SPEED) / (TARGET_SPEED * (FF_TAPER_END - 1)), 0, 1)
thrust.Force = (moveDir * (FRICTION_FF * ffScale)
	+ (moveDir * TARGET_SPEED - vFlat) * ACCEL_GAIN) * mass
```

The gap term is chapter 1's servo, unchanged: it closes toward `TARGET_SPEED` and goes
negative above it, which makes it a cap rather than a motor.

The new term is **feed-forward** — a shove big enough to break the drag holding him still.
Size it against the friction it has to beat: sliding needs roughly `µ × gravity` of
acceleration. Chapter 1's cube settles below its target for exactly this reason; this is
the term that closes the gap.

It **tapers off** past the target (`FF_TAPER_END`) so the two terms don't fight at cruise.
Untapered, it overruns the cap on smooth ground.

Then multiply by `mass` — the thrust has to haul the **entire stack**, and every layer
above the base is dead weight it drags.

**Everything is tuned in acceleration units and multiplied by mass at the last moment**, so
the knobs keep their meaning when you change the rig.

**Check:** hold W. Speed climbs to `TARGET_SPEED` and holds.

### Step 11 — Add the hop, on a distance clock

He has no legs, so he bounces. One clock and one force:

```lua
-- owner, each step: advance the clock by DISTANCE TRAVELLED, but never slower than
-- HOP_MIN_SPEED while he is actually driving
local speed = (v - UP * v.Y).Magnitude
if driving then
	speed = math.max(speed, HOP_MIN_SPEED)
end
base:SetAttribute("HopPhase", (hop + speed * dt / HOP_STRIDE) % 1)

-- every peer: push off during the early slice of each cycle, if he's on the ground
if driving and hopPhase < HOP_WINDOW and math.abs(vy) < HOP_GROUNDED_VY then
	force += UP * (HOP_ACCEL * mass)
end
```

**The clock advances by distance travelled.** It resimulates identically, and the cadence
tracks his speed for free — slow down and he hops slower, with no extra code.

**The grounded check is required.** Without it he boosts himself in mid-air every cycle and
floats away.

**Put a floor under the clock while driving.** A pure distance clock stops dead the moment
he's blocked, so shoved against a wall he stands there silent and still while the player is
mashing a key. Gate the floor on `driving`, not on speed, so releasing the key still stops
him.

The free part: the base hops, and everything above it is dragged into the air a beat later
through the joints. The cake squashes on the way up and the cherry keeps going after he
lands.

### Step 12 — Split facing from movement

Movement uses the target direction immediately. The facing slews toward it separately:

```lua
base:SetAttribute("DriveDir", slewDir(cur, tdir, TURN_RATE * dt))
```

You strafe the moment you press the key; the cake swings around afterwards. That split is
most of what makes him feel like a heavy object rather than a turret.

Crank `TURN_RATE` up and the arms, which obey nothing but physics, get flung out sideways.

**A fast turn rate is worthless behind a slow actuator.** The `AlignOrientation` that
applies the rotation becomes the speed limit, so both numbers have to be quick.

---

## Part 3 — punching

There is no attack button and no attack animation. The arms already have mass, and a fast
turn already whips them out to arm's length, so a punch is a fist that arrived somewhere
fast. The only question is how fast.

### Step 13 — Put it on the server, outside the simulation

`CakeSim` is the movement brain. It runs on both machines and re-runs during
reconciliation, so it may only read input and write actuator targets.

A punch is a **consequence**: the server watches a collision and decides that one man's
fist arrived at another. Movement is predicted; consequences are authoritative. That is why
`CakePunch` is a separate server script.

### Step 14 — Cache the pre-impact velocity

`Touched` fires *after* the solver resolved the contact, so the velocity you read there is
what's left over — for a light thing hitting a heavy thing, nearly nothing.

Keep last frame's velocity yourself:

```lua
-- Heartbeat runs AFTER physics, so what we store is the velocity each part carried INTO
-- the next step -- which is the pre-impact one. Weak keys, so destroyed parts drop out.
local prevVel: { [BasePart]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any

RunService.Heartbeat:Connect(function()
	for _, man in menFolder:GetChildren() do
		for _, p in (man :: Model):GetDescendants() do
			if p:IsA("BasePart") then
				prevVel[p :: BasePart] = (p :: BasePart).AssemblyLinearVelocity
			end
		end
	end
end)

local function approachVel(part: BasePart): Vector3
	return prevVel[part] or part.AssemblyLinearVelocity
end
```

Without this, every clean hit registers as a tap.

### Step 15 — Apply the shove

```lua
local relSpeed = (approachVel(other) - approachVel(victimPart)).Magnitude
if relSpeed < HIT_SPEED_MIN then return end

-- Renormalised: the lift changes the DIRECTION of the shove, not its size.
local push = (otherVel.Unit + Vector3.yAxis * KNOCKBACK_LIFT).Unit
victim.PrimaryPart:ApplyImpulse(push * (relSpeed - HIT_SPEED_MIN) * KNOCKBACK)
attacker.PrimaryPart:ApplyImpulse(-push * (relSpeed - HIT_SPEED_MIN) * KNOCKBACK * KNOCKBACK_REACTION)
```

Relative speed is the right measure for two fighters: it's the same number whether you
swung into someone or they ran onto your fist.

The impulse goes on the **root**, so the man skids while the cake above him lags and flails
behind. The wobble does the knockback animation for you.

Bias the shove upward so a hit lifts as well as slides, and push the attacker back by a
fraction so the punch rocks both men.

**Key the hit cooldown to the victim, not the part you clipped.** A cake is five slabs, so
a fist sweeping through a man catches his sponge, his strawberry and his icing on the way
past and bills him separately for each.

**Only fists punch:**

```lua
if not string.match(other.Name, "^Arm[LR]5$") then return end
```

Without it, barging someone with your body launches them and the game becomes about walking
into people.

---

## The line to carry forward

**An attribute cannot hold a reference to an instance.** Attributes are the state that
rolls back, so they are the only state your simulation can own.

That draws the boundary for you: "I am moving in this direction" is predicted and instant,
while "I hit *that* man" is a fact about the world and belongs to the server. Put intent in
the sim and consequences on the server, and prediction stops fighting you.

Now go and knock something over.
