# 2. The rig: a cake made of ball sockets

CakeMan is four cake layers stacked on ball sockets, a box head on top, and two arms
made of five segments each ending in a heavy fist. Every joint in him is the same
three-line construction. Learn it once and you've learned the whole character.

Here's the entire idea: **ball sockets don't merge assemblies.** Every part stays its
own rigid body, connected by a constraint. So when you shove the bottom layer, the
layers above it get dragged along through the joints — *late*. That lag is the wobble.
Nothing animates it. It's just what a stack of blocks on loose joints does.

## The socket helper

```lua
local function socket(name, lower, upper, jointPos, axis, angle, twist, friction)
	local frame = axisFrame(jointPos, axis)

	local a0 = Instance.new("Attachment")
	a0.Parent = lower
	a0.WorldCFrame = frame
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

Two things in there will bite you. Both did.

## Footgun 1: parent the attachment *before* you position it

```lua
a0.Parent = lower
a0.WorldCFrame = frame   -- this order. Not the other one.
```

An `Attachment` with no parent has no world to be positioned in, so setting
`WorldCFrame` before parenting is **silently discarded**. Every joint then ends up at
its part's origin, and your character collapses into a pile of itself the instant it
spawns. No error. No warning. Ask me how I know.

## Footgun 2: the cone axis (this one is invisible)

`BallSocketConstraint` measures its cone — `UpperAngle` — around the attachment's
**primary axis**, which is the attachment's **X axis**. Twist is measured about the
*same* axis.

An attachment built with `CFrame.new(pos)` has identity rotation. Its X axis points
along world **+X**. So if your limb chains along **Y** — as every limb in every normal
rig does — **the cone is lying on its side.** The joint bends on its twist axis and
twists on its bend axis. `UpperAngle` and `TwistUpperAngle` do not mean what their
names say, and nothing tells you.

I had this on every joint in the character and didn't notice. Peter spotted it in the
joint gizmo: the arms were chained along the wrong axis, hinging where they should
have been twisting.

The fix is to point the attachment's X axis **down the chain**:

```lua
local function axisFrame(pos: Vector3, axis: Vector3): CFrame
	local x = axis.Unit
	local helper = if math.abs(x.Y) > 0.9 then Vector3.zAxis else Vector3.yAxis
	local y = (helper - x * helper:Dot(x)).Unit
	return CFrame.fromMatrix(pos, x, y)
end
```

`Vector3.yAxis` for the cake stack (it chains upward), `-Vector3.yAxis` for the arms
(they hang down). Verify by reading it back — `Attachment.WorldCFrame.RightVector`
must point along the limb:

```lua
print(joint.Attachment0.WorldCFrame.RightVector) -- should be (0, 1, 0) up the stack
```

The difference is dramatic. The arms went from stiff, kinked chains that could only
hinge one way to proper noodles that sweep in any direction, and the stack visibly
stood up straighter. **Turn the joint gizmos on. Look at them.** This bug is invisible
in code review and obvious in a screenshot.

## The cone angle IS the pose

Here's the fact that decides the whole rig:

> **Every joint in the body is an inverted pendulum.** The socket sits *below* its
> layer's centre of mass. With no restoring force, a layer will *always* topple to its
> cone limit and rest there. Nothing is holding it up.

So the cone limit is not a safety rail. It's the pose. A fully-slumped CakeMan has to
still look like a standing cake, which means the cone has to be tight:

```lua
local JOINT_ANGLE = 6   -- degrees, per joint. Three joints. He leans ~18 at worst.
local JOINT_TWIST = 10
```

He is always falling over, and always already caught. **That's the wobble.**

The arms are the exception, and it's the same insight inverted: **a hanging chain is a
normal pendulum**, which is stable. So arms can be as floppy as you like — 45° cones,
five segments, and a fist on the end.

## Joint friction is the best knob in the rig

A frictionless ball socket is a *perfect bearing*. It rattles, it swings forever, and
it sags to its limit and stays there like a sad soufflé. I spent an embarrassing
amount of time trying to fix that with springs — a restoring torque per layer — and
discovered that `AlignOrientation` has no useful middle setting: too weak and the stack
slumps and never recovers, too strong and the cake is a welded pillar with no wobble at
all. **There is no value that wobbles AND stands up.**

The answer was one property:

```lua
j.MaxFrictionTorque = 700
```

Friction makes a joint **hold its pose until something bigger than gravity comes
along** — and then deform, and *stay* deformed. That's not elastic, it's **plastic**.
Which is exactly what cake is. He stands up straight at rest, gets shoved out of shape
when you drive or turn, and stays shoved.

One trap: **friction is expensive.** My first pass sized it against gravity directly
(2200) and effectively welded the joints — the solver burned all the thrust fighting
the character's own constraints, and he lurched and stalled at 3 studs/s while the
thrust force screamed past 14,000. The fix wasn't more power, it was **lighter upper
layers** (densities 8 / 0.5 / 0.35 / 0.2), so there's less gravity torque to resist and
cheap friction (700) does the job.

Heavy at the bottom is the whole stability plan, and it's also the fun knob: make the
top layers heavier and he becomes genuinely unruly.

## The numbers

| | |
|---|---|
| Layers | 4, `4 × 1.55 × 4` studs, on a 1.65 pitch (so a 0.10 seam) |
| Densities | 8 / 0.5 / 0.35 / 0.2, bottom to top |
| Body cones | 6° bend, 10° twist, friction 700 |
| Head | one box, 12° cone, friction 90 |
| Arms | 5 segments, 45° cones, friction 8, fist ×1.5 and dense |
| Base friction | **0.05** — he has no legs, he *glides* |

That last one matters more than it looks. He's a heavy box sliding on a plane, and at
normal friction an edge catches, he stops dead, and thrust piles up until he lurches
free. I measured it before I understood it: speed swinging between **0.0 and 16.2** in
a straight line, with thrust spiking to **19,017**. Averages hid it completely. Make
the base genuinely slippery (with a high `FrictionWeight`, so his number wins on
anyone's geometry) and he flows: **12.7 avg, min 11.2, max 12.8**.

---

**Next:** [Chapter 3 — input and the brain](03-input-and-the-brain.md). Making him move.
