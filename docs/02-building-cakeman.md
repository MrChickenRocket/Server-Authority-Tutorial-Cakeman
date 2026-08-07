# 2. The cake with noodle arms

Chapter 1 built a cube that is server-owned, predicted and smooth. This chapter replaces the
cube with **CakeMan**: four cake layers stacked on ball sockets, a glacé cherry for a head,
and two five-segment arms ending in heavy fists. Every bit of his animation comes out of the
physics solver.

![A CakeMan blundering around the arena, knocking boxes over](assets/02-cakeman-arena.webp)

To drive him first, open [`samples/cakemanplace/`](../samples/cakemanplace/) and press
**Test → Server & Clients**.

Try spinning on the spot to flail his arms around, and knock some boxes over. Under Server
Authority everyone sees the same thing you do, and it all interacts consistently on every
client.

## What changes, and what doesn't

| File from Chapter 1 | What happens to it |
|---|---|
| `CubePresent` → `Presentation` | **Nothing.** It presents anything tagged `Presented`. A cake is 15 tagged parts instead of 1. |
| `CubeClient` → `CakeClient` | **Nothing structural.** Same camera, same `CameraDir` feed. |
| `CubeServer` → `CakeServer` | Spawns by **cloning a rig** instead of building a Part. |
| `CubeSim` → `CakeSim` | Same velocity servo, now hauling a whole stack. It gains a hop and a slewed facing. |

The cube was already handing a force to the solver every step, so this chapter applies the
same idea to a whole floppy rig. One file is added for combat: `CakePunch`.

## The ragdoll is the character

The usual way to build a floppy character controller is to simulate a tidy invisible capsule
and hang a wobbly puppet off it for show. The collisions and the flopping are then local
only, and moving that work to the server costs you input latency.

Server Authority with physics supports the direct approach: use the raw physics engine, let
the solver work it out, and let the server own the result.

CakeMan is a stack of unanchored parts held together with ball sockets, with vector forces to
move him about. Visual smoothing handles resimulation and mispredictions. Everything else is
stock Roblox Server Authority.

---

## Part 1 — build the rig

The rig is a real Model saved in the place: `ServerStorage.CakeManRig`. Spawning a CakeMan is
a matter of cloning him on the server — the same as last chapter's box, but a clone rather
than `Instance.new()`.

**The rig is where the tuning lives.** Every mass, cone angle, joint friction and stance
offset is a property on an instance you can select in the explorer, so you change one, press
Play, and feel the difference — no rebuild, no script edit. That is worth more than it sounds:
joint behaviour is much easier to judge from a gizmo than from a number in source.

![CakeMan in Studio with the joint gizmos turned on](assets/rigSetup.png)

That is the whole character: four cake layers and a cherry, each its own part, with a ball
socket at every seam. The green boxes are the parts; the gizmos on the joints are the cones
they are allowed to move inside.

Two quirks to watch when building your own rigs:

- A `BallSocketConstraint` measures its cone around the attachment's **X axis**. Build the
  attachment with `CFrame.new(pos)` and X points along world +X, so a limb chaining along Y
  bends on its twist axis and twists on its bend axis.
- If you are scripting one, an `Attachment` must be **parented before you position it**, or
  `WorldCFrame` is discarded.

Turn the joint gizmos on and look at them, as in the shot above. Both mistakes are hard to
spot in source and immediately visible in the viewport.

The reasoning behind the values — why the cone angle is the rest pose, how to size joint
friction against gravity's torque, what happens when you overshoot it — is in
[the physics-character reference](reference/physics-characters.md#stacked-bodies-the-cone-is-the-pose-the-friction-is-the-material).
You will be building your own body anyway; the numbers matter less than knowing which knob
does what.

---

## Part 2 — replace the brain's drive step

`CakeSim` keeps the exact shape of `CubeSim` — owner reads input into attributes, every peer
drives actuators from those attributes — and obeys the same four rules. Only `drive()`
changes.

**The movement tuning lives on the rig too**, as attributes on the model, which every clone
inherits. `tuned(man, "TargetSpeed")` reads one, falling back to a default in the file if the
rig doesn't carry it, so you adjust how he moves from the Properties panel mid-playtest rather
than editing a script and waiting for a sync.

Keep the two kinds of attribute straight, because only one of them rolls back. Config sits on
the **model** and the sim only ever reads it. Intent — `Driving`, `TargetDir`, `DriveDir`,
`HopPhase` — sits on the **base part**, is written inside the sim, and rolls back with
resimulation. Writing config inside the sim, or reading intent as though it were config, is
how this goes wrong.

### Add the hop, on a distance clock

He has no legs, so he bounces. One clock and one force:

```lua
-- owner, each step: advance the clock by distance travelled, but never slower than
-- HopMinSpeed while he is actually driving
local speed = (v - UP * v.Y).Magnitude
if driving then
	speed = math.max(speed, tuned(man, "HopMinSpeed"))
end
base:SetAttribute("HopPhase", (hop + speed * dt / tuned(man, "HopStride")) % 1)

-- every peer: push off during the early slice of each cycle, if he's on the ground
if driving and hopPhase < tuned(man, "HopWindow") and math.abs(vy) < tuned(man, "HopGroundedVY") then
	force += UP * (tuned(man, "HopAccel") * mass)
end
```

**The clock advances by distance travelled.** It resimulates identically, and the cadence
tracks his speed with no extra code — slow down and he hops slower.

**The grounded check is required.** Without it he boosts himself in mid-air every cycle and
floats away.

**Put a floor under the clock while driving.** A pure distance clock stops dead the moment he
is blocked, so shoved against a wall he stands there motionless while the player is holding a
key. Gate the floor on `driving`, not on speed, so releasing the key still stops him.

The base hops, and everything above it is dragged into the air a beat later through the
joints, so the cake squashes on the way up and the cherry keeps going after he lands. None of
that is animated.

### Split facing from movement

Movement uses the target direction immediately. The facing slews toward it separately:

```lua
base:SetAttribute("DriveDir", slewDir(cur, tdir, math.rad(tuned(man, "TurnRate")) * dt))
```

You strafe the moment you press the key; the cake swings around afterwards. That split is
most of what makes him feel like a heavy object with flaily arms. Raise `TurnRate` and the
arms, which are driven by nothing but physics, get flung out sideways.

**A fast turn rate doesn't work with a slow actuator.** The `AlignOrientation` that applies
the rotation becomes the speed limit, so both numbers have to be quick.

---

## Part 3 — punching

There is no attack button and no attack animation. The arms already have mass, and a fast
turn already whips them out to arm's length, so a punch is a fist that arrived somewhere fast.
What remains is measuring how fast.

### Put it on the server, outside the simulation

`CakeSim` is the movement brain. It runs on both machines and re-runs during reconciliation,
so it may only read input and write actuator targets.

A punch is a **consequence**: the server watches a collision and decides that one man's fist
arrived at another. Movement is predicted; consequences are authoritative. That is why
`CakePunch` is a separate server script.

### Cache the pre-impact velocity

`Touched` fires *after* the solver resolved the contact, so the velocity you read there is
what's left over — for a light thing hitting a heavy thing, nearly nothing.

Keep last frame's velocity yourself:

```lua
-- Heartbeat runs after physics, so what we store is the velocity each part carried into the
-- next step, which is the pre-impact one. Weak keys, so destroyed parts drop out.
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

### Apply the shove

```lua
local relSpeed = (approachVel(other) - approachVel(victimPart)).Magnitude
if relSpeed < HIT_SPEED_MIN then return end

-- Renormalised: the lift changes the direction of the shove, not its size.
local push = (otherVel.Unit + Vector3.yAxis * KNOCKBACK_LIFT).Unit
victim.PrimaryPart:ApplyImpulse(push * (relSpeed - HIT_SPEED_MIN) * KNOCKBACK)
attacker.PrimaryPart:ApplyImpulse(-push * (relSpeed - HIT_SPEED_MIN) * KNOCKBACK * KNOCKBACK_REACTION)
```

Relative speed is the right measure for two fighters: it's the same number whether you swung
into someone or they ran onto your fist.

The impulse goes on the **root**, so the man skids while the cake above him lags and flails
behind. The wobble supplies the knockback animation.

Bias the shove upward so a hit lifts as well as slides, and push the attacker back by a
fraction so the punch rocks both men.

**Key the hit cooldown to the victim, not the part you clipped.** A cake is five slabs, so a
fist sweeping through a man catches his sponge, his strawberry and his icing on the way past
and bills him separately for each.

**Only fists punch:**

```lua
if not string.match(other.Name, "^Arm[LR]5$") then return end
```

Without it, barging someone with your body launches them and the game becomes about walking
into people.

---

## Where the mispredictions land

Punches are resolved only on the server, so the knockback arrives as a correction rather than
a prediction. That is the right trade here: the hit is a contested outcome between two
players, and the server is the only place that can settle it. The presentation layer from
Chapter 1 smooths the correction, so what the player sees is a shove with a few milliseconds
of give in it.

## Conclusion

You now have a wobbly cake man, and the netcode underneath him is the same four files from
Chapter 1. The presentation layer is the part most worth extending — it takes the
authoritative transforms and can render them any way you like, including driving the bones of
a skinned mesh from where the parts are.
