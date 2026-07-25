# 2. The cake with noodle arms

Chapter 1 built a cube that is server-owned, predicted and smooth. This chapter replaces
the cube with **CakeMan**: four cake layers stacked on ball sockets, a glacé cherry for a
head, and two five-segment arms ending in heavy fists. All of his animation is entirely physics, 
and he demands violence.

To drive him first, open [`samples/cakemanplace/`](../samples/cakemanplace/) and press
**Test → Server & Clients**.

Pay special note to spinning him to flail his arms around and knocking some boxes over. Server authority means everyone is seeing the same thing you are, and it will all interact exactly as you'd hope it would.

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

Server Authority let's us do the opposite: Just use the raw physics engine and server authority and let the solver work it out.

Our cake man is quite literally just a stack of unanchored parts with ball sockets holding it all together and some vector forces to make him move about. 

---

## Part 1 — build the rig

The rig is a real Model saved in the place: `ServerStorage.CakeManRig`. 
Spawning the cakeman character in is just a matter of cloning him on the server. Similar to last chapers box, but it's a clone vs Instance.new()

After that its assorted tuning and cleanup code to get the rig exactly how we want it.

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
