# Server Authority — patterns and code

Working patterns for building under `Workspace.AuthorityMode = Server`. Concepts are in
[server-authority.md](server-authority.md); the condensed invariant list is
[rules.md](rules.md).

Every code block here is runnable as written and self-contained.

## 1. Project shape

```
ReplicatedStorage (or ReplicatedFirst)
├── Simulation (ModuleScript)        ALL core gameplay logic
└── Inputs (Folder)
    └── PlayContext (InputContext)
        ├── Steer (InputAction, Direction2D)
        │   ├── Keyboard (InputBinding)
        │   ├── Gamepad  (InputBinding)
        │   └── Touch    (InputBinding)
        └── Boost (InputAction, Bool)

ServerScriptService
└── SimulationServer (Script)        require(Simulation).Initialize()
                                     + clone Inputs/PlayContext into each Player
                                     + spawn/despawn characters

StarterPlayerScripts (or ReplicatedFirst)
└── SimulationClient (LocalScript)   require(Simulation).Initialize()
                                     + camera + camera-direction feed
```

The same module, initialized on both sides, is what makes prediction and resimulation
agree. **If only one side initializes it, nothing moves and there is no error.**

## 2. The shared simulation module

```lua
--!strict
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Simulation = {}

local function readAction(player: Player, name: string): any
	local ctx = player:FindFirstChild("PlayContext")
	local action = ctx and ctx:FindFirstChild(name)
	return action and (action :: any):GetState() or nil
end

function Simulation.Initialize()
	local isServer = RunService:IsServer()
	local localPlayer = Players.LocalPlayer -- nil on the server

	RunService:BindToSimulation(function(dt: number)
		for _, player in Players:GetPlayers() do
			local root = resolveRoot(player)
			if not root then continue end

			-- OWNER ONLY: live input -> intent attributes.
			-- The server owns every character; a client owns only its own.
			if isServer or player == localPlayer then
				readInput(root, player)
			end

			-- EVERY PEER: drive actuators from those attributes, identically.
			drive(root, dt)
		end
	end, Enum.StepFrequency.Hz60)
end

return Simulation
```

The owner/every-peer split is the state contract. The owner reads live input and writes
*intent* as attributes; every peer — server, owning client, spectating clients — drives the
actuators from those attributes with the same code. A remote character is driven from its
last replicated attributes, which extrapolates it as though the player kept doing what they
were doing.

Rules inside the callback:

- **Deterministic only.** No `math.random()` without a seed that rolls back, no wall clocks
  (§5), no branching on client-only or server-only state.
- **No effects.** No sounds, particles, or camera shake — the step re-runs during rollback.
  See §4 for the correct place, and §6 for the escape hatch.
- **No yielding.** Never `task.wait()` or any async call inside the step.
- **No instance creation** unless you are doing instance stitching (§9).
- **Validate inputs like RemoteEvents.** Clamp magnitudes, reject impossible values. The
  same code is the validation layer when it runs on the server.
- **No module-level Lua state that the sim reads back.** It does not roll back. Use
  attributes.

## 3. Cloning InputContexts per player

```lua
-- ServerScriptService.SimulationServer (Script)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

Players.PlayerAdded:Connect(function(player)
	local ctx = ReplicatedStorage.Inputs.PlayContext:Clone()
	ctx.Parent = player -- MUST descend from the Player to replicate
end)
```

Or build them in code, which keeps the contract visible in source control:

```lua
local function buildInputContext(player: Player)
	if player:FindFirstChild("PlayContext") then return end

	local ctx = Instance.new("InputContext")
	ctx.Name = "PlayContext"
	ctx.Enabled = true

	local steer = Instance.new("InputAction")
	steer.Name = "Steer" -- the sim looks these up BY NAME
	steer.Type = Enum.InputActionType.Direction2D
	steer.Parent = ctx

	local kb = Instance.new("InputBinding")
	kb.Name = "Keyboard"
	kb.Up, kb.Down = Enum.KeyCode.W, Enum.KeyCode.S
	kb.Left, kb.Right = Enum.KeyCode.A, Enum.KeyCode.D
	kb.Parent = steer

	local pad = Instance.new("InputBinding")
	pad.Name = "Gamepad"
	pad.KeyCode = Enum.KeyCode.Thumbstick1
	pad.Parent = steer

	-- The camera direction rides in as an input too (§13).
	local cameraDir = Instance.new("InputAction")
	cameraDir.Name = "CameraDir"
	cameraDir.Type = Enum.InputActionType.Direction3D
	cameraDir.Parent = ctx

	ctx.Parent = player
end
```

InputContexts are unaffected by `CharacterAutoLoads` — they descend from the `Player`, not
the character. Use `task.spawn` if per-player setup yields; do not block the `PlayerAdded`
handler chain.

## 4. Effects: sync state, render transitions

Write *state* in the simulation; play *effects* outside it, keyed off state transitions:

```lua
-- inside BindToSimulation, both sides: state only
grenade:SetAttribute("State", "Lit")

-- client-only render script
RunService.RenderStepped:Connect(function()
	local state = grenade:GetAttribute("State")
	if state ~= lastState then
		if state == "Lit" then fuseSound:Play() end
		if state == "Exploded" then emitExplosion() end
		lastState = state
	end
end)
```

Rollback can revisit a state, so keying off *transitions of the current attribute value* is
what stops a rolled-back "Exploded" from leaving orphaned particles behind.

## 5. Clocks: `dt` and `time()`, and nothing else

`BindToSimulation` passes `dt` and nothing else — no simulation time, no step id, no frame
counter. The callback takes exactly one argument.

Of the clocks reachable from inside it, two are safe and the rest are traps:

| API | Exists | Safe inside the sim |
|---|---|---|
| `dt` (the callback argument) | yes | **Yes** — the only quantity that always replays identically |
| `time()` | yes | **Yes** — verified to roll back; a replayed step reports that simulated frame's time |
| `workspace:GetServerTimeNow()` | yes | **No** — creeps by replay wall-time during resim |
| `workspace.DistributedGameTime` | yes | **No** — frozen across a resim burst |
| `os.clock()` / `tick()` / `os.time()` | yes | **No** — wall clocks |
| `RunService:Time()` | **no, not a member** | n/a |

**`time()` and `DistributedGameTime` are not the same clock under Server Authority**, whatever
the general folklore says. The trace below has DGT frozen across a resim burst; `time()` rolls
back and replays. Do not substitute one for the other.

`RunService:Time()` comes up often enough to state flatly: it does not exist. Not in Studio
0.729, not in the API dump, not in `creator-docs`. The engine does internally revert state
and time on rollback, which is probably where the folklore comes from, but it exposes no
handle on that clock.

**Why a wall clock fails, and it is not the way you would guess.** A wall clock is never
rewound — it is monotonic across a rollback, as it is everywhere else. The problem is that it
**stops agreeing with `dt`**. A real resim burst, captured inside `BindToSimulation` on the
client with `IsResimulating()` labelling each step (Studio 0.729):

```
  live  dt=0.0333  DGT=99.2167  ServerTimeNow=13.7870
  live  dt=0.0333  DGT=99.2500  ServerTimeNow=13.8205
  RESIM dt=0.0333  DGT=99.2667  ServerTimeNow=13.8381
  RESIM dt=0.0333  DGT=99.2667  ServerTimeNow=13.8398   <- DGT frozen; STN creeping ~1.6ms
  RESIM dt=0.0333  DGT=99.2667  ServerTimeNow=13.8414
  RESIM dt=0.0333  DGT=99.2667  ServerTimeNow=13.8429
  live  dt=0.0333  DGT=99.2833  ServerTimeNow=13.8537
```

Four simulation steps, each advancing physics by a full 33 ms. `DistributedGameTime` does not
move at all across them, while `GetServerTimeNow()` inches forward by however long the
*replay* took to execute. The server, simulating those same four steps for real, saw its clock
advance 133 ms. A wall clock hands the client and the server different answers for the same
simulation step, which is the definition of a misprediction. `dt` is the only quantity that
replays identically.

**`dt` accumulation is still the portable pattern** for anything you want to reason about as
simulation state — a countdown you can inspect, seed, or reset is easier to debug than a
timestamp comparison, and it rolls back visibly as an attribute. Reach for `time()` when you
need an absolute simulated frame time rather than an interval.

**The pattern — accumulate `dt` into rolled-back state:**

```lua
-- a simulation clock (rolls back and resimulates identically)
local t = (root:GetAttribute("SimTime") :: number?) or 0
root:SetAttribute("SimTime", t + dt)

-- a timer: count DOWN by dt. Never compare a timestamp against "now".
local cd = (root:GetAttribute("Cooldown") :: number?) or 0
root:SetAttribute("Cooldown", math.max(cd - dt, 0))
```

**Prefer distance to time for anything tied to movement.** A gait, hop, or stride clock
advanced by distance travelled resimulates identically *and* makes cadence track speed for
free:

```lua
phase += speed * dt / STRIDE
```

Time clocks are for things that should happen at a rate independent of movement: cooldowns,
i-frames, respawns.

## 6. `IsResimulating`, `Rollback`, `Misprediction`

Three `RunService` members that are not on the Server Authority documentation page:

| Member | What it gives you |
|---|---|
| `RunService:IsResimulating()` | `true` while the current step is a replay. Call it *inside* the sim callback. |
| `RunService.Rollback` | Fires after the engine reverts state, before it resimulates the rolled-back steps. |
| `RunService.Misprediction` | Fires when a misprediction is detected. Carries a `stats` table including `ResimulationTime`. |

`IsResimulating()` is the sharp version of §4's effects rule. "No effects in the sim" is safe
blanket advice; the precise rule is that **an effect must not fire on a replayed step**,
because that step already happened and its sound already played.

```lua
if not RunService:IsResimulating()
   and state == "Exploded" and lastState ~= "Exploded" then
	emitExplosion() -- a live step, and a genuine transition
end
```

It is also the diagnostic for "this fires twice sometimes". Log it and count: if the
duplicate steps are all `IsResimulating() == true`, that is an effect in the simulation, not
a logic bug. It is equally how you measure how much resim you are actually eating.

It does not buy you a clock. A replayed step gets the same honest `dt`; `IsResimulating()`
tells you *that* you are replaying, never *which* step you are replaying.

## 7. Constraints: reaction forces and silent failure

### `OneAttachment` servos push against the world

An `AlignPosition` or `AlignOrientation` in `OneAttachment` mode drags its part toward a
world coordinate. The equal-and-opposite force goes nowhere — it is reacted by the universe.
The part is shoved with up to `MaxForce` and nothing else in the world feels it.

That is sometimes what you want: a stand-up servo or a heading servo, where the ground is
implicitly the thing being pushed against. It is almost never what you want for a **limb**.
Hands that shoot out without the body rocking back read as floaty, because the momentum was
conjured.

Anchor the servo between two attachments and turn the reaction on:

```lua
-- BEFORE: a fist hauled to a world point, by nothing, for free
reach.Mode = Enum.PositionAlignmentMode.OneAttachment
reach.Attachment0 = fistAttachment
reach.MaxForce = 26000
reach.Position = stanceWorldPosition   -- recomputed every step, in the sim

-- AFTER: the fist pulls itself forward by pulling the shoulders back
reach.Mode = Enum.PositionAlignmentMode.TwoAttachment
reach.Attachment0 = fistAttachment     -- the end that gets moved
reach.Attachment1 = shoulderStance     -- an attachment ON the body: it eats the recoil
reach.ReactionForceEnabled = true
reach.MaxForce = 4000                  -- 6x less, and it arrives FASTER
```

Three things fall out, and the second is the reason to do it even if physical honesty is not
the goal:

1. Throwing your hands out rocks you backwards. Holding a heavy guard costs you posture.
2. **The target rides the body's own frame for free.** `Attachment1` lives on the torso, so it
   leans, lags and wobbles with the body — the shoulders stay square to the hands by
   construction. The simulation stops recomputing a world position every step, which removes
   an entire class of bug where the pose and the body disagree.
3. `MaxForce` collapses. Measured, the same servo reached the pose in 0.30 s at 4,000 where it
   had needed 26,000 before. A number that has to be enormous is often a number pushing
   against nothing.

### A constraint with a nil attachment does not error

It applies zero force, forever, quietly. Every symptom points at tuning — "the grab feels
weak", "the servo's too soft" — rather than at wiring.

- Create attachments and **parent them before** referencing them. Re-read the reference back
  before trusting a same-frame write.
- If the rig is an artifact in the place rather than something code builds, **assert the
  contract at spawn**: check every constraint has both attachments and `warn()` loudly. One
  comparison per player converts a week-long mystery into a line in the output window.

## 8. Presentation: hiding correction snaps

The authoritative state is correct and has no regard for visual fluidity. When a prediction
misses, it snaps. Hide the authoritative copy on the client, show a client-only copy, and
ease that copy toward the truth.

1. Hide the simulated part with `LocalTransparencyModifier = 1` — client-side only, so nobody
   else's view changes.
2. Create a massless, non-collidable, **non-queryable** visual clone in a client-only folder.
3. Each `RenderStepped`, SmoothDamp the clone toward the truth with a velocity feed-forward
   lead (`target + v * LEAD`) so the smoothing does not trail; lerp rotation separately.

```lua
-- critically-damped spring. `st` is roughly the time to arrive.
-- Returns (newPos, newVel); thread `vel` back in on the next call.
local function damp(cur: Vector3, tgt: Vector3, vel: Vector3, st: number, dt: number)
	st = math.max(st, 1e-4)
	local omega = 2 / st
	local e = math.exp(-omega * dt)
	local change = cur - tgt
	local temp = (vel + change * omega) * dt
	return tgt + (change + temp) * e, (vel - temp * omega) * e
end
```

Three details in the render step are load-bearing: the **velocity lead**, so moving objects
do not trail; a **snap distance** past which you teleport instead of smoothing, because
smoothing a teleport looks like a bug; and a **clamped `dt`**, so one hitched frame does not
fling the copy across the map.

Point the camera at the smoothed copy, not the truth. A camera tracking the truth turns every
correction into a flick of the whole screen.

The simulation stays exact. Only the rendering is smoothed, with no server round trip.

### The visual copy is still a Part

A clone inherits everything. Left alone it will collide, answer raycasts, fire `Touched`,
take part in fluid forces, occlude audio, and carry every tag and attribute the original had.

```lua
copy.Anchored = true
copy.CanCollide = false
copy.CanQuery = false      -- the expensive one
copy.CanTouch = false
copy.AudioCanCollide = false
copy.EnableFluidForces = false
copy.Massless = true
-- and strip every tag and attribute it inherited, or a tag-driven presentation
-- layer will present its own output and eat itself
```

**`CanQuery` is the one that costs you.** An anchored client-only visual answers your own
sim's raycasts on the client only — geometry the server does not have. That is a
hand-built, guaranteed misprediction.

Three defenses; use at least one deliberately:

1. **Per-part opt-out** — `CanQuery = false, CanTouch = false` on every client-side visual.
   Simple and local, but it is a flag you must remember on every visual you ever create.
2. **Collision-group masking** — register a `ClientVisuals` collision group server-side
   (registration replicates), assign local parts to it on the client, and mask it out of the
   group your sim's `RaycastParams` uses. Central policy instead of a per-part flag; scales
   better, slightly more setup.
3. **`RaycastParams.RespectCanCollide = true`** on sim probes — skips anything
   `CanCollide = false`, which visuals already are. One line, but it couples query semantics
   to collision semantics, so any legitimate probe target that happens to be non-collidable
   (climbable decor, ghost platforms) silently vanishes from the probes.

On anything serious: the group policy as the safety net, plus `CanQuery = false` in your
visual-construction helpers so intent is legible at the creation site.

## 9. Instance stitching (predicted spawning)

To spawn an object client-side without waiting for the server: create the instance inside the
`BindToSimulation` callback **on both sides**, with a deterministic GUID so the engine can
reconcile the client's predicted copy against the server's authoritative one. The instance
must be parented into the DataModel **before the end of that simulation frame**.

This is the only sanctioned instance creation inside the sim.

## 10. Prediction mode tuning

```lua
-- the thing the player controls: always predict
for _, part in myCharacter:GetChildren() do
	if part:IsA("BasePart") then
		RunService:SetPredictionMode(part, Enum.PredictionMode.On)
	end
end

-- ambient debris: never predict
RunService:SetPredictionMode(workspace.Debris, Enum.PredictionMode.Off)

-- everything else: leave Automatic (radius-based)
print(RunService:GetPredictionStatus(somePart)) -- verify what is ACTUALLY predicted
```

`On` grows the resimulation set. Profile before applying it broadly.

## 11. Predicting other players

By default other players' objects are extrapolated from replicated state. For
input-dependent smoothness — racing games are the clear case — the server writes each
player's inputs as **attributes**, which replicate and are readable inside the client's
simulation callback. The client then simulates opponents from their actual inputs instead of
extrapolating positions.

## 12. Animation

- Maximum 8 actively playing tracks per `Animator`.
- Never cache `AnimationTrack` references across frames; rollback invalidates them. Query
  fresh with `Animator:GetTrackByAnimationId(id)` or `GetPlayingAnimationTracks()`.
- Drive animation *choice* from synced attributes (a state machine in the sim), and
  play/stop in render-side code.

## 13. Camera

`Player:GetCameraState()` returns `{ CFrame, FieldOfView, ViewportSize }`. The old
`InputContexts.CameraContext.CameraAction` path is gone.

**If aiming or steering direction matters to the simulation, feed it in as an
`InputAction`.** The simulation cannot read `workspace.CurrentCamera`: the server has not got
one, and a replayed step needs the direction *as it was on that frame*.

```lua
-- client: fire on change, plus a slow keep-alive
local cameraDir = player:WaitForChild("PlayContext"):WaitForChild("CameraDir")
local lastFired, sinceFire = Vector3.zero, 0

RunService.RenderStepped:Connect(function(dt)
	local dir = workspace.CurrentCamera.CFrame.LookVector
	sinceFire += dt
	if (dir - lastFired).Magnitude > 0.02 or sinceFire > 0.5 then
		cameraDir:Fire(dir)
		lastFired, sinceFire = dir, 0
	end
end)
```

In a characterless place there is no `PlayerModule`, so `CameraType = Custom` does nothing
and the camera sits near the origin. You build the camera yourself, and
`camera.CameraType = Enum.CameraType.Scriptable` is load-bearing — without it something else
writes `camera.CFrame` after you do and your camera silently does nothing.

Follow a **camera proxy**: an invisible anchored part SmoothDamped toward the character over
~0.35 s. A body that wiggles as it moves is nauseating to track directly.

To force a default orbit zoom, pin `CameraMinZoomDistance = CameraMaxZoomDistance = desired`
for two `RenderStepped` frames at boot, then reopen the range.

## 14. Designing for latency

- **Prefer acceleration over instant velocity changes.** Ramps hide corrections; snaps expose
  them.
- **Prefer delayed-fuse mechanics** — wind-ups, charge-ups — over instant hits.
- **Keep server-exclusive logic out of anything the client predicts.** If the client cannot
  know it, it will mispredict it.
- **Make player-versus-player contact soft.** It always mispredicts, so design collisions to
  be springy rather than hard bounces; the corrections then read as physics rather than
  teleports.

## 15. Characterless setups (`CharacterAutoLoads = false`)

With no Humanoid character, the automatic prediction radius and streaming prioritization
have nothing to centre on. Four consequences:

1. **The server must spawn the character itself** on `PlayerAdded` and clean it up on
   `PlayerRemoving`.
2. **Set `player.ReplicationFocus`** to the character's root part. Miss this and
   `PredictionMode.Automatic` has no radius to predict around: the player's own character is
   not predicted and every input feels like a full round trip. There is no error.
3. **Set `player.Character`** to the model. It is what the camera knows not to push through;
   with no Humanoid nothing sets it, and the stock camera treats the character as scenery.
4. **Anything assuming a character exists silently does nothing** — default camera and
   control scripts, `CharacterAdded` hooks, `Player.Character` reads. Custom camera and input
   are mandatory.

`Players.CharacterAutoLoads = false` is a place-level toggle that is invisible to source
control, so set it in the server script as well. Either alone is enough; both make the
assumption explicit.

### Model streaming for characters

- `ModelStreamingMode.Atomic` — the model streams in as a unit; clients never see half a
  character.
- `ModelStreamingMode.Persistent` — the model is always replicated to every client
  regardless of streaming distance. An instance the client was never sent cannot be
  predicted, so this is the stronger guarantee for a character, and it subsumes the
  half-a-model concern.

Chapter 1's cube uses `Persistent`. Pick deliberately; the failure mode of getting it wrong
is a remote character that pops in and cannot be predicted.

## 16. Debug workflow

1. Build and tune in single-process **Play** — it runs the real predict/resimulate loop.
   Switch to **Server & Clients** (1 client) plus Network Simulation to test behavior under
   real latency.
2. `Ctrl+Shift+F6` for the visualizer: prediction success rate and input acceptance.
3. `Ctrl+Shift+I` timeline and `Ctrl+Scroll` scrubbing to inspect individual mispredictions;
   `Ctrl+L` shows which property mismatched.
4. `Alt+S` to see the simulation radius — anything outside it is not predicted under
   `Automatic`.
5. **Trace tables, not vibes.** Sample `t, position, normal, velocity, state-attributes` at
   1–2 Hz into a table and read the numbers.
6. **Build a gizmo overlay** — draw probe rays, normals, and state, attribute-driven and
   render-only so it stays simulation-inert. Expose its toggle as a workspace attribute, not
   as module state: **command-bar and tooling VMs get a different copy of your module on
   `require`**, so module-level state is not reachable from outside.
7. **Check for a human at the wheel** before debugging ghost motion in a shared Studio
   session.
