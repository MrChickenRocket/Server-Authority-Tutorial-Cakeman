# 3. Input, and the brain that runs on both machines

This is the chapter that is actually about Server Authority. The rig was just a rig.

## The state contract

Read this before the code. Everything else follows from it.

> The **owner** of a character — the server for all of them; a client for its own —
> reads live input and writes *intent* as **attributes** on the root part.
> **Every peer** then drives the actuators from those attributes, identically.

Attributes written inside the simulation **roll back with resimulation**. That's the
magic. The server, your predicting client, and every spectator all reach the same
result from the same intent, and a remote CakeMan extrapolates as "he kept doing what
he was doing".

## Input: InputActions, not RemoteEvents

```lua
local ctx = Instance.new("InputContext")
ctx.Name = "PlayContext"

local steer = Instance.new("InputAction")
steer.Type = Enum.InputActionType.Direction2D
steer.Parent = ctx
-- ...WASD + thumbstick bindings...

local cameraDir = Instance.new("InputAction")
cameraDir.Type = Enum.InputActionType.Direction3D
cameraDir.Parent = ctx

ctx.Parent = player
```

**Not RemoteEvents.** InputActions replicate *and roll back*. A RemoteEvent is a message
that arrives whenever it arrives; there's no shared timeline, so the server and your
client's rollback can't agree on when you pressed the key.

The camera direction goes in the **same way** — as a `Direction3D` action the client
fires. This is the bit people get wrong: it is extremely tempting for the simulation to
just read `workspace.CurrentCamera` and be done. **It can't.** The server has no camera,
and your rollback needs the camera direction *as it was on that frame*. So it's an
input, like any other:

```lua
-- client, every frame: fire on change plus a slow keep-alive
if (dir - lastFired).Magnitude > 0.02 or sinceFire > 0.5 then
	cameraDir:Fire(dir)
end
```

## The four rules of the simulation

`CakeSim` runs through `RunService:BindToSimulation` on **both** sides. It re-runs
several times per frame during reconciliation. So, inside that callback:

1. **No wall-clock, no `os.time`, no `tick()`.** Time is `dt`, passed in.
2. **No randomness** (unless seeded and rolled back).
3. **No instance creation.** It would create it again on every re-run. Instances get
   created in ordinary boot code — chapter 5.
4. **No yielding, no effects.** Don't play a sound in there; it'll play six times. Key
   effects off attribute *transitions* in render code.

Timers are countdown attributes decremented by `dt`. Progress clocks advance by
*distance travelled*, not time. Both of those resimulate identically; a clock does not.

## The velocity servo

The one piece of real control theory in the whole project, and it's six lines:

```lua
local along = vFlat:Dot(moveDir)
local ffScale = math.clamp(1 - (along - TARGET_SPEED) / (TARGET_SPEED * (FF_TAPER_END - 1)), 0, 1)
thrust.Force = (moveDir * (FRICTION_FF * ffScale)
	+ (moveDir * TARGET_SPEED - vFlat) * ACCEL_GAIN) * mass
```

Two terms:

- **Feed-forward** (`FRICTION_FF`) — a shove big enough to break the drag holding him
  still. Size it against the friction it has to beat: sliding needs roughly `µ × gravity`
  of acceleration. At µ 0.3 that's ~59, so a feed-forward of 45 means **he sits there
  humming and never moves**, which is a very confusing five minutes.
- **The gap term** — closes toward `TARGET_SPEED`, and *goes negative above it*. That's
  what makes it a **cap and not a motor**. It cannot run away.

The feed-forward **tapers off** past the target (`FF_TAPER_END`), so the two terms don't
fight at cruise. Untapered, it overruns the cap on smooth ground.

And then the whole thing is multiplied by `mass` — because the thrust has to haul **the
entire stack**, not just the layer it's applied to. The layers above hang off the base
through joints and every one of them is dead weight the base has to drag.

**Everything in this file is tuned in acceleration units and multiplied by mass at the
last moment.** That means the knobs keep their meaning when you change the rig. Change
a density, and you don't have to retune the character.

## Facing: the body carves, the nose catches up

Movement uses the target direction **immediately**. The *facing* slews toward it
separately:

```lua
body:SetAttribute("DriveDir", slewDir(cur, tdir, TURN_RATE * dt))
```

You strafe the moment you press the key; the cake swings around afterwards. That split
is most of what makes him feel like a heavy object rather than a turret. And the
steering is recomputed **every frame** from the live camera direction — hold W and swing
the camera and he carves a curve. (Committing the direction only on keypress feels dead.
I've tried it. Don't.)

Crank `TURN_RATE` up (we run 720°/s) and the arms — which obey nothing but physics —
get flung out sideways by centrifugal force. Nothing animates that. The fists swing from
2.4 studs out to **6.1** and *rise* as they go. It's free, and it's the best thing in
the character.

One gotcha there: a fast turn rate in the sim is worthless behind a slow actuator. The
`AlignOrientation` that actually applies the rotation was set to `Responsiveness = 12`
and simply became the new speed limit. **Both** have to be quick.

---

**Next:** [Chapter 4 — the camera](04-camera.md). Which Roblox is not going to give you.
