# Server Authority — the platform

What the engine does, what enabling it changes, and what it costs. For the patterns you
build on top, see [patterns.md](patterns.md). For character-specific doctrine, see
[physics-characters.md](physics-characters.md).

> Status: full release, July 2026. Early Access Oct 2025 → Studio Beta Dec 2025 → Client
> Beta Apr 2026 → Full Release Jul 2026. Opt-in per experience.

## What it is

Server Authority makes the server the sole source of truth for simulation. Clients no
longer own physics for their own character or for nearby parts. Three mechanisms replace
that ownership:

1. **Client prediction.** The client runs the same simulation code locally, several frames
   ahead of the last known server state, so input feels instant. It aims to simulate just
   far enough ahead that its inputs land on the server at the intended frame, based on
   measured latency.
2. **Server validation.** The server independently simulates the same inputs and produces
   the authoritative state.
3. **Rollback and resimulation.** When the client's prediction diverges from the
   authoritative state, the client rewinds to the server state and resimulates forward,
   re-applying its buffered local inputs.

The result is that movement anticheat is structural rather than heuristic — speed hacks,
flings, wall clips and teleports stop being a client-side decision — and shared physics
(vehicle collisions, ball physics, constraint chains) is consistent for every player.

## Enabling it

Set `Workspace.AuthorityMode = Server` in the Properties panel. It is place state; a script
that tries to set it fails with `lacking capability RobloxScript`.

Setting it auto-enables five engine settings:

| Property | Value |
|---|---|
| `Workspace.NextGenerationReplication` | Enabled |
| `Workspace.PlayerScriptsUseInputActionSystem` | Enabled |
| `Workspace.SignalBehavior` | `Deferred` |
| `Workspace.UseFixedSimulation` | Enabled |
| `Workspace.StreamingEnabled` | Enabled |

Streaming is mandatory. It bounds how much prioritization and prediction work the server
does per player, and it defines the prediction radius around each character.

## The three pillars

### 1. Input Action System — the only input path into simulation

`UserInputService.InputBegan` and `ContextActionService` must not feed the core simulation.
`InputAction` values are sent to the server *and* replayed during client resimulation. That
replay is what makes rollback work.

| Instance | Role |
|---|---|
| `InputContext` | Container. `Enabled`, `Priority`, `Sink`. |
| `InputAction` | The mechanic. `Type` ∈ `Bool \| Direction1D \| Direction2D \| Direction3D \| ViewportPosition`. Events: `Pressed`, `Released`, `StateChanged`. |
| `InputBinding` | Hardware mapping. KeyCode, UIButton, analog thresholds. |

InputContexts must descend from a `Player` instance to replicate. The standard shape is to
author them under `ReplicatedStorage` and clone one into each `Player` from a server script.

Read action **state**, not events, inside the simulation callback, on both machines. Set
`.Name` on every action — lookups are by name, and an unnamed action is invisible to the
sim.

The server discards inputs that arrive too early or too late. Range-validate on the server
exactly as you would a RemoteEvent; the same shared code is the validation layer when it
runs server-side.

### 2. `RunService:BindToSimulation` — the only code path that resimulates

```lua
RunService:BindToSimulation(
    callback,   -- function(dt: number)
    frequency,  -- Enum.StepFrequency, default Hz30
    priority    -- default 2000
) -> RBXScriptConnection
```

Scripts do not execute during resimulation except through this callback. No Heartbeat, no
RenderStepped, no event connections fire during a rollback. So all core gameplay logic —
input processing, forces, state updates — lives in a `BindToSimulation` callback, in a
shared ModuleScript required by both a server Script and a client LocalScript, running
identical code.

**The default frequency is `Hz30` while the physics world runs at 60.** At the default your
servo corrects half as often as the world it is correcting. Pass `Enum.StepFrequency.Hz60`
explicitly unless you have a reason not to. Available: `Hz60 | Hz30 | Hz15 | Hz10 | Hz5 |
Hz1`.

### Simulation Access

Properties and methods marked **Simulation Access** in the API reference are engine-predicted,
and the relationship runs both ways:

- Only simulation-access members may be touched **inside** a `BindToSimulation` callback.
  `BindToSimulation` runs under a restricted capability set, which is the engine steering you
  into writing only synchronized simulation state.
- Simulation-access members may only be touched **from** a `BindToSimulation` callback.

Roblox does not publish a consolidated list. The label is applied per-member across the API
reference; the Server Authority guide, the techniques page, and the `RunService` reference all
name `BasePart.CFrame` as the example and point at the per-class pages for the rest. Broadly
it is the set directly tied to physics simulation: part transforms and velocities, constraint
targets and enablement, and attributes on predicted instances.

**Verified in use** — written inside `BindToSimulation` in this codebase and the rigs it came
from. Non-exhaustive; treat it as a known-good floor, not the boundary:

| Member | Notes |
|---|---|
| `Instance:SetAttribute(name, value)` | On predicted instances. The custom-state channel. |
| `Instance:GetAttribute(name)` | Reads rolled-back state. |
| `BasePart.AssemblyLinearVelocity` | Read and written. Rotating momentum during a surface transition rolls back correctly. |
| `VectorForce.Force` | The main drive channel. |
| `AlignOrientation.CFrame` | Facing target. |
| `AlignPosition.Position` | Position target. |
| `Constraint.Enabled` | On `AlignPosition` / `AlignOrientation`. |
| `BasePart.CFrame` | Roblox's cited example. Prefer forces over writing transforms directly. |

Explicitly **not** simulation access — from the techniques page: `Name`, `Size`, `Parent`.
These can be set freely on an instance before it is parented into the DataModel.

**To check any member**, write it once inside the callback and read the output. A
capability-gated write fails loudly rather than silently, which makes this a cheap one-off
test — unlike most of the failure modes in [rules.md](rules.md). The exact rejection behavior
for a non-simulation-access write inside the callback has not been separately measured here.

### 3. Attributes — custom predicted state

The engine syncs simulation-access properties itself. Your own state goes in **attributes on
predicted instances**, which roll back with resimulation exactly as positions do. An
attribute mismatch triggers rollback the same way a position mismatch does.

Rules:

- Write attributes only from inside `BindToSimulation` callbacks.
- The attribute must be among the **first 64** on the instance.
- Attribute name ≤ 50 characters; string values ≤ 50 characters.
- Attribute names cannot contain `.` — sanitize any name derived from a part name.

**Module-level Lua state does not roll back.** A table in your sim module is not simulation
state; it survives a rollback unchanged while the world around it rewinds, and it diverges
between the two machines within seconds. Anything the simulation reads on a later step has
to be an attribute or a simulation-access property. This is the single most common way a
working prototype fails to promote into a rollback-safe one.

## Prediction control

```lua
RunService:SetPredictionMode(instance, Enum.PredictionMode.Automatic) -- or On / Off
RunService:GetPredictionStatus(instance)
```

- **Automatic** (default): the engine predicts objects with simulation access near the local
  character, within the streaming/simulation radius. Correct for almost everything.
- **On**: always predict. Expensive — it grows the resimulation set. Reserve it for the
  vehicle or character the player controls.
- **Off**: server-owned, never predicted. For anything where input latency does not matter.

`GetPredictionStatus` is the tool for answering "why does this feel laggy" — it tells you
what is *actually* being predicted rather than what you intended.

**An anchored part is excluded from client prediction entirely.** The owning client reports
itself `Authoritative` for its own server-owned character and nothing is ever rolled back.
There is no error and no warning. Never anchor a character part; hand the solver a force and
let it move things. Verify with `GetPredictionStatus(root)`, which should return
`Enum.PredictionStatus.Predicted`.

## What mispredictions cost

- Positions are quantized into buckets. A mismatch of **≥ 0.1 studs** flags a misprediction.
  Floating-point noise at a bucket boundary can produce false positives — a part resting on
  flat ground is the usual case.
- Windows client and Linux server disagree in the last bits of floating point, so identical
  code drifts. Roblox quantizes positions and velocities to fight this, and that quantization
  is itself a source of drift in some BodyMovers and Constraints. Constraint-heavy rigs feel
  this most.
- Resimulation is expensive. At 100 ms latency the client re-runs the whole latency window of
  physics after a correction — roughly **6.25× a normal frame's simulation load** on that
  frame.
- **Player-versus-player contact essentially always mispredicts.** The other player's input
  cannot be known in advance. This is expected and fine as long as the corrections stay
  small.
- Zero mispredictions is not the goal; smooth gameplay is. Resim is the common case, not the
  exception — a 3-second single-process sample logged 105 resimulated steps against 91 live
  ones. Visible snapping means something is misconfigured, not that resim happened.

## Known limitations

As of the July 2026 full release:

- **Camera.** `InputContext`-based camera sync was removed. `Player:GetCameraState()` returns
  `{ CFrame, FieldOfView, ViewportSize }`. If aiming direction feeds simulation, route it
  through an explicit `InputAction` instead so it rolls back — see
  [patterns.md](patterns.md#13-camera).
- **Animation.** Maximum 8 actively playing tracks per `Animator`. Custom emotes, the default
  mood animation, and the Animate script's strafing animations are unsupported. Do not cache
  `AnimationTrack` references across frames — rollback invalidates them. Query fresh with
  `Animator:GetTrackByAnimationId()` or `GetPlayingAnimationTracks()`.
- **RemoteEvents.** Fine for discrete non-simulation data (score, pickups, UI). They have no
  shared timeline with the simulation; expect roughly 40–50 ms of ordering variance against
  property and attribute updates.
- **Tools and backpacks.** Supported. A tool weld can be deleted during a client-side
  misprediction; re-equipping recovers it.
- **Constraints, BodyMovers, and custom movement** (dash, flight, boost) work, but must be
  scripted identically on both machines through `BindToSimulation`. Quantization can cause
  drift. `LinearVelocity`-driven character movement has community reports of residual jitter.
- **Client build parity.** Mobile and console builds trail desktop by several days after an
  engine update; mismatched clients cannot connect until parity.
- Server CPU rises, because the server now simulates everything.

## Test modes

**Single-process Play is accurate.** It runs the real predict/resimulate loop — it
resimulates constantly, which is exactly what the 105-vs-91 measurement above came from — and
it is the right mode for building and tuning mechanics. Any jitter you see in single-process
Play is a real bug in the rig or the prediction; chase it rather than switching modes to hide
it.

**Test → Server & Clients**, with even one client, plus Studio's **Network Simulation** for
injected latency and packet loss, is what you reach for to observe behavior under real
latency: correction magnitude, remote rendering, cheat resistance.

### Debug overlay

Studio hotkeys:

| Keys | What it shows |
|---|---|
| `Ctrl+Shift+F6` | Base visualizer — prediction success rates, input acceptance, frame deltas |
| `Ctrl+Shift+I` | Timeline recording of mispredictions |
| `Ctrl+P` / `Ctrl+Scroll` | Pause recording / scrub it |
| `Ctrl+Y` | Pre/post-correction deviation |
| `Ctrl+U` | Bounding boxes |
| `Ctrl+L` | Property mismatch labels — which property actually diverged |
| `Alt+S` | Simulation-radius regions. Anything outside is not predicted under `Automatic`. |

Roblox's Racing, Soccer, and Laser Tag templates are the reference implementations.

## Sources

- [Server authority model — Creator Hub](https://create.roblox.com/docs/projects/server-authority)
- [Advanced techniques](https://create.roblox.com/docs/projects/server-authority/techniques)
- [Input Action System](https://create.roblox.com/docs/input/input-action-system)
- [Full Release announcement (DevForum)](https://devforum.roblox.com/t/full-release-ship-fair-and-competitive-games-with-server-authority/4727993)
- [Tech Deep Dive + Engineering Insights (DevForum)](https://devforum.roblox.com/t/server-authority-tech-deep-dive-engineering-insights/4624565)
- [Server Authority: How to Begin? (community tutorial)](https://devforum.roblox.com/t/server-authority-how-to-begin/4139185)
- [Roblox newsroom announcement](https://about.roblox.com/newsroom/2026/07/creating-responsive-cheat-resistant-games-roblox-server-authority)
