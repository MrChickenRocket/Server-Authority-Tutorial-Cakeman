# 2. The cake with noodle arms

Chapter 1 built a cube that is server-owned, predicted and smooth. This chapter replaces the
cube with **CakeMan**: four cake layers stacked on ball sockets, a glacé cherry for a head,
and two five-segment arms ending in heavy fists. He is entirely physics. Nothing about him is
animated.

## What changes, and what doesn't

Here is the whole point of doing it in this order:

| File from Chapter 1 | What happens to it |
|---|---|
| `CubePresent` → `Presentation` | **Nothing.** It presents anything tagged `Presented`. A cake is 15 tagged parts instead of 1. |
| `CubeClient` → `CakeClient` | **Nothing structural.** Same camera, same `CameraDir` feed. |
| `CubeServer` → `CakeServer` | Spawns by **cloning a rig** instead of building a Part. |
| `CubeSim` → `CakeSim` | Same velocity servo. It gains a feed-forward term, a hop, and has to haul a whole stack. |

Note what is *not* in that table. The cube already handed a force to the solver every step,
so chapter 2 changes no technique at all — it changes the body the technique is pointed at.
Parts 1, 2 and 3 of the method are done; everything below is character work.

One file is genuinely new, and it arrives at the very end: `CakePunch`, which is what makes
two of them worth putting in a room together.

The finished character, the arena and the punching are in
[`samples/cakemanplace/`](../samples/cakemanplace/) — open it in Studio and press
**Test → Server & Clients** if you want to drive him before you build him.

## The thesis: the ragdoll is the character

There is a tempting way to build a character like this: simulate a tidy invisible capsule,
then hang a wobbly puppet off it for show. The result *looks* physical and isn't. It can't be
knocked over, its arms can't catch on anything, and every interesting collision has to be
faked.

Do the opposite. The parts you see are the parts the solver is working on. When one CakeMan
walks into another, nothing decides what happens.

The mechanism is one property of ball sockets: **they don't merge assemblies.** Every part
stays its own rigid body, connected by a constraint. Shove the bottom layer and the layers
above it get dragged along through the joints — *late*. That lag is the wobble. Nothing
animates it.

You pay for this decision up front, in understanding your rig. What you get back shows up at
the end of the chapter.

---

## Part 1 — build the rig

### Step 1 — Bake the rig as an artefact, with the recipe beside it

The rig is a real Model saved in the place: `ServerStorage.CakeManRig`. The script that
*produced* it lives in source control as
[`ServerStorage/GenerateRig.legacy.luau`](../ServerStorage/GenerateRig.legacy.luau), and it
is **never part of the running game** — keep it `Disabled` if you sync it into the place at
all.

Run the recipe by hand when you want to change the character, then **stop and save the
place**. Small shape changes you can make directly on the saved Model, but the recipe is
what you edit if you want the change to survive a rebuild.

Building everything at boot from `Instance.new` calls is the obvious alternative, and it has
one genuinely excellent property: the whole game is in source control and you can diff it.

It is also opaque. You cannot inspect a character that doesn't exist until the server runs.
You cannot select a joint and look at its cone in the gizmo — which matters enormously in
Step 3, where a gizmo is the only thing that reveals a week-old bug. You cannot hand the model
to an artist.

So keep both halves: an inspectable artefact in the place, and a diffable, commented,
reproducible description of how it was made.

The cost is a new rule: **an instance in the place can be wrong in ways code cannot.** Someone
deletes an attachment. An edit goes unsaved. A constraint loses a reference.

### Step 2 — Check the rig at spawn, out loud

The most expensive failure in a baked rig, stated before you can hit it:

> **A constraint with a nil `Attachment` does not error.** It does not warn. It applies
> exactly zero force, forever, in silence — and every symptom points at tuning ("that servo's
> too soft") rather than at wiring.

So `CakeServer` states the contract and checks it every time it clones a man:

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
			.. "Re-run ServerStorage.GenerateRig and SAVE THE PLACE.")
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

A clone remaps its own internal references: every constraint in the copy points at the copy's
attachments. That is what makes cloning work at all, and it is why the rig has to be built as
**one Model** rather than wired up after parenting.

**Check:** the output window is silent at spawn. If it isn't, fix the rig before you tune
anything — the warning is telling you a number will have no effect.

> **Corollary:** an asymmetry in a symmetrical rig is a wiring bug until proven otherwise.
> A genuine strength problem is weak on *both* sides, so one weak side means a nil
> attachment somewhere.

### Step 3 — Write the socket helper, and get two details right

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

**Parent the attachment before you position it.** An `Attachment` with no parent has no world
to be positioned in, so setting `WorldCFrame` first is **silently discarded**. Every joint
ends up at its part's origin and the character collapses into a pile of itself the instant it
spawns. No error, no warning, and every clue points away from the wiring.

**Point the cone axis down the chain.** `BallSocketConstraint` measures its cone (`UpperAngle`)
around the attachment's **X axis**, and twist about the same axis. An attachment built with
`CFrame.new(pos)` has identity rotation, so its X axis points along world **+X**. If your limb
chains along **Y** — as most rigs do — the cone is lying on its side. The joint bends on its
twist axis and twists on its bend axis, `UpperAngle` and `TwistUpperAngle` do not mean what
their names say, and nothing tells you.

```lua
local function axisFrame(pos: Vector3, axis: Vector3): CFrame
	local x = axis.Unit
	local helper = if math.abs(x.Y) > 0.9 then Vector3.zAxis else Vector3.yAxis
	local y = (helper - x * helper:Dot(x)).Unit
	return CFrame.fromMatrix(pos, x, y)
end
```

Pass `Vector3.yAxis` for the cake stack (it chains upward) and `-Vector3.yAxis` for the arms
(they hang down).

**Check, in code:**

```lua
print(joint.Attachment0.WorldCFrame.RightVector) -- should be (0, 1, 0) up the stack
```

**Check, visually — do this one.** Turn the joint gizmos on and look at them. This bug is
invisible in code review and obvious in a screenshot, and it is the strongest argument for
baking the rig into the place. Corrected, the arms go from stiff chains that hinge one way to
noodles that sweep in any direction, and the stack stands visibly straighter.

### Step 4 — Set the cone angles, because the cone angle is the pose

The fact that decides the whole rig:

> **Every joint in the body is an inverted pendulum.** The socket sits *below* its layer's
> centre of mass. With no restoring force, a layer will always topple to its cone limit and
> rest there. Nothing is holding it up.

So the cone limit sets his resting pose. A fully-slumped CakeMan still has to look like a
standing cake, which means a tight cone:

```lua
local JOINT_ANGLE = 6   -- degrees, per joint. Three joints. He leans ~18 at worst.
local JOINT_TWIST = 10
```

He is always falling over, and always already caught. That is the wobble.

The arms are the exception, and it is the same fact inverted: **a hanging chain is a normal
pendulum**, which is stable. Arms can be as floppy as you like — 45° cones, five segments, a
fist on the end.

### Step 5 — Give him a waist

Uniform slabs read as a column. Scale the middle two layers out and he reads as a cake, and
his silhouette tells you which way up he is from across the arena:

```lua
local LAYER_WIDTH = { 1, 1.3, 1.2, 1 } -- bottom to top
```

Scale **X and Z only**. Leave the pitch alone and every joint, the head and the shoulders
stay exactly where they were — the taper costs you nothing structurally.

Two things follow from it, and the second is a gameplay change, not a cosmetic one:

- **Mass follows width squared.** The bulge adds weight up high, which is the direction that
  hurts. At these densities it is nothing next to the base (the upper layers total about 1.5
  against the base's 8), but widen much further and you should take density back out.
- **The widest part of him is now at chest height**, so he catches on scenery his base would
  have cleared. Measured: driving into a cover block, contact is `Layer2` rather than
  `Layer1`. He snags on things he used to slide past, and he pivots around the snag because
  it is up high.

Then pull the shoulders back in from the point that merely clears the fist:

```lua
local SHOULDER_INSET = 0.5 -- studs, off each side
```

Clearing the fist is the constraint — any less and the arms spawn inside the cake. The
inset is taste: at zero the arms hang off him like handles.

### Step 6 — Use joint friction, not springs

A frictionless ball socket is a perfect bearing. It rattles, swings forever, and sags to its
limit and stays there.

Springs are the tempting fix — a restoring torque per layer — and for this look they are the
wrong tool. A torque strong enough to stand him up also cancels the lag that reads as cake.
Too weak and the stack slumps and never recovers; too strong and it's a welded pillar. **There
is no spring value that wobbles and stands up.**

One property does the job:

```lua
local BODY_FRICTION = 700 -- the stack: firm, doughy, holds its shape
local NECK_FRICTION = 90  -- the head: bobbles more freely
-- ...passed through to each joint as j.MaxFrictionTorque
```

Friction makes a joint **hold its pose until something bigger than gravity comes along**, then
deform, and *stay* deformed. That plastic behaviour is what cake does. He stands straight at
rest, gets shoved out of shape when you drive or turn, and stays shoved.

> **Friction is expensive.** Sizing it against gravity directly (2200) effectively welds the
> joints: the solver burns the thrust fighting the character's own constraints. He lurched and
> stalled at 3 studs/s while the thrust force ran past 14,000.

The fix is **lighter upper layers** — densities 8 / 0.5 / 0.35 / 0.2, bottom to top — so there
is less gravity torque to resist and cheap friction (700) is enough. More power makes it worse.

Heavy at the bottom is the whole stability plan, and it is also the fun knob. Make the top
layers heavier and he becomes genuinely unruly.

### Step 7 — Keep the mesh a costume and the physics a box

The layers and the head are `MeshPart`s, cloned from meshes and resized.

**`AssetService:CreateMeshPartAsync` is the only way a Script can choose collision fidelity.**
You cannot assign `CollisionFidelity` on a MeshPart from a Script — that needs plugin
capability. You can only ask for it at creation:

```lua
local mesh = AssetService:CreateMeshPartAsync(assetId, {
	CollisionFidelity = Enum.CollisionFidelity.Box,
	RenderFidelity = Enum.RenderFidelity.Precise,
})
```

`Box` is deliberate. Precise collision on a wobbly cake buys nothing except a solver that has
to think about icing.

**Check what a mesh's bounding box actually contains.** The cherry is mostly stem — authored
size 4.11 × 7.06 × 4.00, and more than half that height is foliage nobody will ever hit. Size
it by width and let the rest follow:

```lua
local CHERRY_WIDTH = 1.9 -- the only number we choose; the rest follows
local HEAD_SIZE = CHERRY_SOURCE * (CHERRY_WIDTH / CHERRY_SOURCE.X)
```

The head is light (density 0.3) on a loose neck (12° cone, friction 90). A heavy head on a
loose socket drags the whole stack around. This one bobbles.

### Step 8 — Pre-wire every actuator, switched off

This step exists purely because of Server Authority.

**The simulation may not create instances.** It re-runs several times a frame during
reconciliation, so an `Instance.new` in there runs again on every replayed step.

So the rig is built with **every actuator the character could ever want already in place and
`Enabled = false`**. The simulation's entire job is to flip switches and write targets.

| Instance | On | What it does |
|---|---|---|
| `DriveAtt` | base | the one attachment everything drives through |
| `Thrust` (`VectorForce`) | base | walking (Step 10) |
| `Heading` (`AlignOrientation`) | base | keeps him upright and pointed (Step 12) |

Two rules for anything you add to that list.

**Build the attachments before the constraints that point at them.** A constraint whose
`Attachment1` is assigned before that attachment exists comes up nil, applies zero force
forever, and is silent about it — Step 2's check exists because of exactly this.

**Anchor a servo to the body, never to the world.** A `OneAttachment` `AlignPosition` drags
its part toward a world coordinate, and the equal-and-opposite force goes **nowhere** — it
is reacted by the universe. Nothing else feels it, so the body never recoils and players
read the conjured momentum as *floaty* long before they can name it.

Use `TwoAttachment` with `ReactionForceEnabled = true`, anchored to another part of the
character, and the force has to pay for itself out of his own posture. Measured on the arm
servo when it was converted: recoil appeared (2.9 rad/s of spin on the shoulders), and the
required `MaxForce` **collapsed from 26,000 to 4,000 while arriving faster** — 0.30 s,
where before it strained permanently short of its target.

> **A number that has to be enormous is often a number that's pushing against nothing.** A
> 26,000 never looks suspicious until you ask what's on the other end of it.

### Step 9 — Tag every part, and make the model persistent

```lua
CollectionService:AddTag(part, "Presented")
model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
```

`Presented` is the same tag from Chapter 1, so `Presentation.luau` needs no changes at all — a
cake is just 15 tagged parts instead of one. Bake the tag into the template rather than
applying it at spawn, and the presentation layer never needs to know that spawning exists.

`Persistent` is a correctness requirement under Server Authority: **an instance the client was
never sent cannot be predicted.** If your character can be streamed out, the client's
simulation and the server's are running on different worlds.

---

## Part 2 — replace the brain's drive step

`CakeSim` keeps the exact shape of `CubeSim` — owner reads input into attributes, every peer
drives actuators from those attributes — and obeys the same four rules. Only `drive()` changes.

### Step 10 — Write the velocity servo

The cube set a CFrame. The cake applies a force:

```lua
local along = vFlat:Dot(moveDir)
local ffScale = math.clamp(1 - (along - TARGET_SPEED) / (TARGET_SPEED * (FF_TAPER_END - 1)), 0, 1)
thrust.Force = (moveDir * (FRICTION_FF * ffScale)
	+ (moveDir * TARGET_SPEED - vFlat) * ACCEL_GAIN) * mass
```

Two terms:

- **Feed-forward** (`FRICTION_FF`) — a shove big enough to break the drag holding him still.
  Size it against the friction it has to beat: sliding needs roughly `µ × gravity` of
  acceleration.
- **The gap term** — closes toward `TARGET_SPEED`, and *goes negative above it*. That is what
  makes it a **cap and not a motor**. It cannot run away.

> **Size the feed-forward against a physical quantity.** On a grippy base (µ 0.3) the
> requirement is ~59, so a feed-forward of 45 meant he sat there humming and never moved. The
> shipped character glides on a base of µ **0.05**, needs about 10, and runs a `FRICTION_FF`
> of **30**.

The feed-forward **tapers off** past the target (`FF_TAPER_END`) so the two terms don't fight
at cruise. Untapered, it overruns the cap on smooth ground.

Then multiply by `mass` — the thrust has to haul **the entire stack**. The layers above hang
off the base through joints and every one of them is dead weight.

**Everything is tuned in acceleration units and multiplied by mass at the last moment.** The
knobs keep their meaning when you change the rig. Change a density and you don't retune the
character.

**Check:** hold W. Speed climbs to `TARGET_SPEED` and holds. If it overshoots, the taper is
wrong. If he never starts, the feed-forward is below `µ × gravity`.

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

**The clock advances by distance travelled.** Two things follow, and both are load-bearing:

- it **resimulates identically** — a wall clock does not, and this code re-runs several times
  a frame;
- the cadence **tracks his speed for free**. Slow down and he hops slower, with no extra code.
  Speed and rhythm cannot drift apart, because they are the same number.

Measured: 0.64 studs high, **4.3 hops/second** at a cruise of 9.6 — which is
`speed / HOP_STRIDE` to within measurement noise. The rhythm falls out of the arithmetic.

The grounded check does more work than it looks. Without it he boosts himself in mid-air every
cycle and floats away.

**Put a floor under the clock while he's driving.** A pure distance clock stops dead the
moment he's blocked, so shoved up against a wall he stands there silent and still — at
exactly the moment the player is mashing a key, which reads as the game having hung.
`HOP_MIN_SPEED = 4` keeps him bouncing against whatever he's stuck on, and above that speed
the clock is distance again and the cadence tracks him for free.

Gate it on **driving**, not on speed, or he never settles. Measured pinned against a wall:
the clock advanced 1.79 cycles and he bounced through 1.47 studs. Measured at rest after
releasing the key: 0.0003 cycles, 0.0002 studs. Both terms are rolled-back state, so it
still replays identically.

> **Hop frequency costs top speed.** Doubling the hop rate took cruise from 12.9 to 9.6. Every
> landing bleeds a little horizontal momentum, so twice as many landings is twice the bleed.

The free part: the base hops, and everything above it is dragged into the air a beat later
through the joints. The cake squashes on the way up and the cherry keeps going after he lands.
Nobody animated that — it's the same lag that makes him wobble, working vertically.

### Step 12 — Split facing from movement

Movement uses the target direction **immediately**. The facing slews toward it separately:

```lua
base:SetAttribute("DriveDir", slewDir(cur, tdir, TURN_RATE * dt))
```

You strafe the moment you press the key; the cake swings around afterwards. That split is most
of what makes him feel like a heavy object rather than a turret.

Crank `TURN_RATE` up (720°/s here) and the arms, which obey nothing but physics, get flung out
sideways. The fists swing from 2.4 studs out to **6.1** and rise as they go.

> **A fast turn rate is worthless behind a slow actuator.** The `AlignOrientation` that applies
> the rotation was set to `Responsiveness = 12` and simply became the new speed limit. Both
> numbers have to be quick. It runs at 40.

---

## The numbers

| | |
|---|---|
| Layers | 4 MeshParts, 1.55 thick, on a 1.65 pitch (a 0.10 seam) |
| Layer widths | **4 / 5.2 / 4.8 / 4** studs — the middle two bulge, so he reads as a cake rather than a column |
| Densities | 8 / 0.5 / 0.35 / 0.2, bottom to top |
| Body cones | 6° bend, 10° twist, friction 700 |
| Head | cherry MeshPart, 1.9 wide, density 0.3, 12° cone, friction 90 |
| Arms | 5 segments, 45° cones, friction 8, fist ×1.5 and dense (1.2) |
| Base friction | **0.05**, `FrictionWeight` 5 — he has no legs, he glides |
| `TARGET_SPEED` / `ACCEL_GAIN` | 12 / 6 |
| `FRICTION_FF` / `FF_TAPER_END` | 30 / 1.3 |
| `HOP_STRIDE` / `HOP_WINDOW` / `HOP_ACCEL` | 2.75 / 0.14 / 520 |
| `TURN_RATE` | 720°/s, behind `Responsiveness = 40` |

That base friction row matters more than it looks. He is a heavy box sliding on a plane. At
normal friction an edge catches, he stops dead, and thrust piles up until he lurches free.

Measured at normal friction: speed swinging between **0.0 and 16.2** in a straight line,
thrust spiking to **19,017**. Averages hid it completely. Make the base genuinely slippery,
with a high `FrictionWeight` so his number wins on other geometry: **12.7 avg, min 11.2, max
12.8**.

## Tune in this order

One knob at a time, hands on the keyboard.

1. **`TARGET_SPEED`** — pick the cruise. Everything else scales around it.
2. **`ACCEL_GAIN`** — snappiness. Too high reads as robotic, too low as mud.
3. **`FRICTION_FF`** — the launch shove. It has to beat `µ × gravity` before he moves at all.
4. **`TURN_RATE` + `Responsiveness`** — a pair. Both have to be fast.
5. **`COAST_DRAG`** — let go and he should glide to rest.
6. **The joints** — friction for doughiness, cone angles for the pose, densities for wobble.
7. **`SMOOTH_TIME`** in the presentation layer — as low as the latency allows.

**Blend, don't branch.** A boolean in a physics loop is a jitter machine. An earlier biped
version hard-switched its legs between `planted` and `swinging` at the duty boundary, and used
a yes/no ground raycast, so a foot near the threshold flickered every frame. Replacing both
with continuous weights dropped peak shin angular velocity from **55 rad/s to 13**.

**Knobs are not independent.** When you change a number, ask what other number was sized
against it. Most "this knob doesn't work" bugs are "this knob's partner is now lying".

---

## Part 3 — punching, and the return on the thesis

Chapter 2 opened by claiming the ragdoll should *be* the character rather than a puppet hung
off a capsule. Here is the bill for that, paid back.

**There is no attack button, and no attack animation.** The arms already have mass, and a
`TURN_RATE` of 720°/s already whips them out to arm's length. So a punch is just a fist that
arrived somewhere fast, and the only question worth asking is how fast:

```lua
-- CakePunch.legacy.luau, on the server
local relSpeed = (approachVel(other) - approachVel(victimPart)).Magnitude
if relSpeed < HIT_SPEED_MIN then return end

local push = (otherVel.Unit + Vector3.yAxis * KNOCKBACK_LIFT).Unit
victim.PrimaryPart:ApplyImpulse(push * (relSpeed - HIT_SPEED_MIN) * KNOCKBACK)
attacker.PrimaryPart:ApplyImpulse(-push * ... * KNOCKBACK_REACTION)
```

Measured: a clean hit puts **37.6 studs/s** into the victim and displaces him about 12
studs. The impulse lands on the *base*, so the man skids while the cake above him lags and
flails behind — the wobble is doing the knockback animation, for free, and nobody keyframed
it.

### Where punching lives, and why it is not in the sim

`CakeSim` is the movement brain. It runs on both machines and re-runs during
reconciliation, so it may only read input and write actuator targets.

A punch is a **consequence**: the server watches a collision and decides one man's fist
arrived at another. The client gets no vote. Movement is predicted; consequences are
authoritative. That line is the whole reason `CakePunch` is a separate server script, and it
is the one to hold when you add anything else to this character.

### Three things that will bite

**`Touched` hands you the wrong velocity.** It fires *after* the solver resolved the
contact, so you read what's left over — measured, a part thrown at 50 studs/s reports 2.1 by
the time `Touched` sees it. Cache each part's velocity on `Heartbeat` and read that instead,
or every clean hit registers as a tap.

**A cake is five slabs.** Key your hit cooldown to the *victim*, not to the part you clipped
— a fist sweeping through a man catches his sponge, his strawberry and his icing on the way
past and bills him separately for each.

**Only fists should hurt.** Without a name check, barging someone with your body launches
them, and the game becomes about walking into people.

### The architectural line to carry forward

**An attribute cannot hold a reference to an instance.** Attributes are the state that rolls
back, so they are the only state your simulation can own. That draws the boundary for you:
"I am moving in this direction" is predicted and instant, while "I hit *that* man" is a fact
about the world and belongs to the server. Put intent in the sim and consequences on the
server, and prediction stops fighting you.

---

## The diagnostic rule to take away

Server-authoritative physics has a characteristic failure mode: **most problems present as
tuning problems.**

Floaty hands look like a force that should be bigger. A punch billed five times looks like a
damage number that should be smaller. A constraint with a nil attachment — no error, no
warning, zero force, forever — looks exactly like a servo that's too weak.

The tell is always the same:

> **You reach for the knob, you turn it a long way, and the result moves less than the
> arithmetic says it should. Stop tuning. The model is wrong.** Go and look at the geometry,
> or go and read the code.

The same instinct covers the physical version: when a system refuses to respond to more force,
something is constraining it, and the constraint is usually geometric. Doubling a biped's lift
force barely moved its feet, because leg length is `2 × segment × cos(bend/2)` and a 50° knee
fold shortens a 2.6-stud leg by 0.24 studs. No amount of force beats trigonometry.

## What's unproven

Every number in this article came out of a trace in the running place, and **all of it was
measured in single-process Play.** The rig, the driving, the prediction and the presentation
layer are all real.

The **Server & Clients latency pass is outstanding**: reconcile quality under real lag, how a
*remote* CakeMan reads to another player, how player-vs-player collisions mispredict.
Single-process play looks falsely jittery under Server Authority and cannot show you any of
that. Run that pass before you take these numbers into a shipping game.

Now go and knock something over.
