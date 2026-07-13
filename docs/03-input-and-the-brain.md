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

Built **on the server**, in `CakeServer`, when a player joins — parented to the Player,
so it exists on both machines and can be read from inside the simulation on either.

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

-- Hold left mouse to put your guard up. The whole back half of this game hangs off
-- one Bool. (Chapter 9.)
local grab = Instance.new("InputAction")
grab.Type = Enum.InputActionType.Bool
grab.Parent = ctx
local mouse = Instance.new("InputBinding")
mouse.KeyCode = Enum.KeyCode.MouseLeftButton
mouse.Parent = grab

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

## There is no clock. Build one.

Worth stating plainly, because it's the first thing people reach for and it isn't there:

**`BindToSimulation` hands you `dt` and nothing else.** No simulation time, no step ID,
no frame counter.

**And `RunService:Time()` does not exist.** I mention it because it comes up constantly
— someone will tell you it's the resim-safe clock. It isn't a member of `RunService`, in
any Studio build, and it isn't in the API dump or the docs. The engine does internally
revert "state and time" on a rollback, which is probably where the folklore comes from,
but it hands you no way to read that clock.

The clocks that *do* exist are traps. `workspace:GetServerTimeNow()` and
`DistributedGameTime` are real, and they *are* on a shared timebase across server and
client — but they are **wall clocks, and wall clocks are not resim-safe**.

The failure mode is not the one you'd guess, and I had it wrong in an earlier draft. A
wall clock is never *rewound* — it stays perfectly monotonic across a rollback. It just
**stops agreeing with `dt`**. Here's a real resim burst, captured from inside
`BindToSimulation`:

```
live   dt=0.0333  DGT=99.2167  ServerTimeNow=13.7870
RESIM  dt=0.0333  DGT=99.2667  ServerTimeNow=13.8381
RESIM  dt=0.0333  DGT=99.2667  ServerTimeNow=13.8398
RESIM  dt=0.0333  DGT=99.2667  ServerTimeNow=13.8414
RESIM  dt=0.0333  DGT=99.2667  ServerTimeNow=13.8429
live   dt=0.0333  DGT=99.2833  ServerTimeNow=13.8537
```

Four replayed steps, each advancing physics by a full 33 ms — and `DistributedGameTime`
**does not move at all** across them, while `GetServerTimeNow()` creeps forward by the
1.6 ms the *replay itself* took to execute. The server, simulating those same four steps
for real, saw its clock advance 133 ms.

Same step, different reading on each machine. That **is** a misprediction, and you built
it by hand. `dt` is the only quantity that replays identically.

The pattern that works is to **accumulate `dt` into rolled-back state**:

```lua
-- the guard timer (Chapter 9): how long have the hands been up?
local held = (base:GetAttribute("GuardTime") :: number?) or 0
held = if reaching then held + dt else 0
base:SetAttribute("GuardTime", held)
```

Attributes written inside the sim roll back with resimulation, so a re-run restores the
previous value and re-accumulates — identical every time. **That is your simulation
clock.** The engine doesn't give you one; you build it from the only two things you have
(`dt`, and state that rolls back).

Same trick for timers: a countdown attribute decremented by `dt` (`DownedFor`, in
Chapter 10). Never a timestamp compared against "now".

### The one thing the engine *does* give you: `IsResimulating()`

Absent from the Server Authority docs page, and genuinely useful:

```lua
RunService:IsResimulating()  -- true while the current step is a REPLAY
```

(Along with `RunService.Rollback` and `RunService.Misprediction`, which fire around the
event and carry stats.)

This is the missing half of rule 4 below. "No effects in the simulation" is blanket
advice standing in for the real rule, which is: **an effect must not fire on a replayed
step** — that step already happened, and its sound already played. Guard on it and
effects can live in the sim legally:

```lua
if not RunService:IsResimulating() and state == "Exploded" and lastState ~= "Exploded" then
	emitExplosion() -- a live step, and a genuine transition
end
```

It does **not** give you a clock. A replayed step still gets an honest `dt`, and you are
never told *which* step you're replaying — only that you are.

And the corollary, which is the one people miss: **if the thing you're timing is tied to
movement, use distance instead of time.** A distance clock gives you
cadence-tracks-speed for free (see the hop, below), which a time clock has to
reconstruct. Time clocks are for things that should happen at a rate *independent* of
movement — cooldowns, i-frames, respawn timers.

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
  of acceleration. Back when his base was grippy (µ 0.3) that was ~59 — so a feed-forward
  of 45 meant **he sat there humming and never moved**, which was a very confusing five
  minutes. The shipped character glides on a base of µ **0.05**, needs about 10, and runs
  a `FRICTION_FF` of **30**. The number is small now because the *rig* changed, not
  because the servo did — which is the point of sizing it against a physical quantity
  instead of tuning it by feel.
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

## The hop, and why its clock runs on distance

He has no legs, so he bounces — little bird hops as he trundles along. The whole thing
is one clock and one force:

```lua
-- owner, each step: advance the clock by DISTANCE TRAVELLED
local speed = (v - UP * v.Y).Magnitude
base:SetAttribute("HopPhase", (hop + speed * dt / HOP_STRIDE) % 1)

-- every peer: push off during the early slice of each cycle, if he's on the ground
if driving and hopPhase < HOP_WINDOW and math.abs(vy) < HOP_GROUNDED_VY then
	force += UP * (HOP_ACCEL * mass)
end
```

**The clock advances by distance, not by time.** That isn't a stylistic choice, it's the
only thing that works:

- it **resimulates identically** — a wall clock does not, and this code re-runs several
  times a frame;
- and the cadence **tracks his speed for free**. Slow down and he hops slower, with no
  extra code. Speed and rhythm cannot drift apart, because they are the same number.

Measured: 0.64 studs high, **4.3 hops/second** at a cruise of 9.6 — which is
`speed / HOP_STRIDE` to within measurement noise. The rhythm is not tuned. It's derived.

The grounded check (`math.abs(vy) < HOP_GROUNDED_VY`) is doing more work than it looks.
Without it he boosts himself in mid-air on every cycle and floats away like a balloon.

**Hop frequency costs top speed**, and it's worth knowing why rather than being surprised
by it. Doubling the hop rate (halving `HOP_STRIDE`) took his cruise from 12.9 to 9.6.
That's not a bug — **every landing bleeds a little horizontal momentum**, so twice as
many landings is twice as much bleed. If you want both, pay for it with feed-forward.

And the best part is free: the base hops, and everything above it is **dragged into the
air a beat later through the joints**. The cake squashes on the way up, and the cherry
keeps going after he's landed. Nobody animated that. It's the same lag that makes him
wobble, now working vertically.

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
and simply became the new speed limit. **Both** have to be quick. (It runs at 40 now.)

## Everything else the brain does

By the end of the series `CakeSim` has grown three more jobs, and they're all the same
shape — read intent, read truth, drive actuators — so they're worth listing here as a
map of where you're going:

| Job | Reads | Writes / drives | Chapter |
|---|---|---|---|
| **Locomotion** | `Steer`, `CameraDir` | `TargetDir`, `DriveDir`, `HopPhase` → `Thrust`, `Heading` | this one |
| **The guard** | `Grab` | `Reaching`, `GuardTime` → `Reach.Enabled`, `ArmedL`/`ArmedR` | 9 |
| **The limp** | `Downed` (server-written) | `Heading.Enabled`, every joint's `MaxFrictionTorque` | 10 |

Notice what's *not* in that table: anything the simulation has to be told by a message,
and anything it has to create. The brain reads attributes and flips switches. That's the
whole shape of a Server Authority character, and if you find yourself wanting to break
it, the thing you want almost certainly belongs on the server (Chapter 8) or in the
render layer (Chapter 7).

---

**Next:** [Chapter 4 — the camera](04-camera.md). Which Roblox is not going to give you.
