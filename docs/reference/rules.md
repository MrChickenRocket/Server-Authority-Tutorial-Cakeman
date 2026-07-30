# Server Authority — the rules

The condensed invariant list. Load this first; it is the whole doctrine compressed to the
things that break code if you get them wrong. Each rule links to the full explanation.

Written to be read by an agent building Server Authority code from scratch. If you follow
only this file you will build something that works; the other three explain *why* and cover
the character-specific depth.

---

## The non-negotiables

1. **All simulation logic lives in one shared ModuleScript**, required and initialized by
   both a server `Script` and a client `LocalScript`, running inside
   `RunService:BindToSimulation`. Nothing else resimulates.
   → [server-authority.md](server-authority.md#2-runservicebindtosimulation--the-only-code-path-that-resimulates)

2. **Pass `Enum.StepFrequency.Hz60`.** The default is `Hz30` while physics runs at 60.
   → [server-authority.md](server-authority.md#2-runservicebindtosimulation--the-only-code-path-that-resimulates)

3. **Input comes in through `InputContext` / `InputAction` parented to the `Player`.** Never
   RemoteEvents, never `UserInputService`, never `ContextActionService` for anything that
   feeds simulation. Actions replicate *and roll back*; RemoteEvents have no shared timeline.
   → [server-authority.md](server-authority.md#1-input-action-system--the-only-input-path-into-simulation)

4. **Custom state lives in attributes on predicted instances**, written only from inside the
   sim callback. Attributes roll back with resimulation. Module-level Lua tables do not.
   → [server-authority.md](server-authority.md#3-attributes--custom-predicted-state)

5. **The owner writes intent; every peer drives actuators from it.** The server owns every
   character; a client owns only its own. Both run the identical drive step.
   → [patterns.md](patterns.md#2-the-shared-simulation-module)

6. **Pre-wire every actuator at spawn. The sim only writes targets** (`.Force`, `.CFrame`,
   `.Position`, `.Enabled`). Setting a target is idempotent; creating an instance is not.
   → [physics-characters.md](physics-characters.md#actuators-are-pre-wired-the-sim-only-sets-targets)

7. **Never anchor a character part**, and drive movement with forces rather than by writing
   velocity every frame. Anchoring is a hard prohibition — it removes the part from
   prediction. Preferring forces is a *feel* rule: ramps hide corrections, snaps expose them.

   Writing `AssemblyLinearVelocity` is **legal** — it is a Simulation Access property and it
   rolls back correctly. Rotating momentum during a surface transition is a legitimate use.
   Use it deliberately, not as the movement channel.
   → [physics-characters.md](physics-characters.md#the-velocity-servo)

8. **Set `player.Character` to the model.** It is what pulls parts into the client
   prediction and rollback loop. Set `player.ReplicationFocus` to the root part as well, but
   know what each does: `Character` drives prediction, `ReplicationFocus` governs the
   streaming radius.
   → [patterns.md](patterns.md#15-characterless-setups-characterautoloads--false)

9. **`CanQuery = false` on every client-side visual part.**
   → [patterns.md](patterns.md#the-visual-copy-is-still-a-part)

10. **`dt` and `time()` are the only clocks.** Every other clock is a wall clock and will
    desync from the simulation during a replay. Accumulate `dt` into attributes and count
    timers down; prefer distance to time for anything tied to movement.
    → [patterns.md](patterns.md#5-clocks-dt-and-time-and-nothing-else)

11. **Only Simulation Access members may be touched inside the callback, and they may only be
    touched from inside it.** Roblox publishes no consolidated list; the known-good set is
    attributes, `AssemblyLinearVelocity`, `VectorForce.Force`, `AlignOrientation.CFrame`,
    `AlignPosition.Position`, `Constraint.Enabled`, `BasePart.CFrame`.
    → [server-authority.md](server-authority.md#simulation-access)

---

## Banned inside `BindToSimulation`

| Never | Because | Instead |
|---|---|---|
| `os.clock()`, `tick()`, `os.time()`, `DistributedGameTime`, `GetServerTimeNow()` | Wall clocks stop agreeing with `dt` during a replay. `DistributedGameTime` freezes across a resim burst — it is **not** the same clock as `time()` | `dt` accumulated into an attribute, or `time()` ([§5](patterns.md#5-clocks-dt-and-time-and-nothing-else)) |
| `math.random()` with an unsynced seed | Diverges between peers | Seed from a rolled-back attribute, or design it out |
| Sounds, particles, camera shake, any effect | The step re-runs; the effect double-fires | Render-side, keyed off state transitions ([§4](patterns.md#4-effects-sync-state-render-transitions)), or guard with `IsResimulating()` ([§6](patterns.md#6-isresimulating-rollback-misprediction)) |
| `task.wait()` or any yield | The step must complete synchronously | Restructure as a countdown attribute |
| `Instance.new()` | Non-idempotent across replays | Pre-wire at spawn, or use instance stitching ([§9](patterns.md#9-instance-stitching-predicted-spawning)) |
| Reading `workspace.CurrentCamera` | The server has none; a replay needs the value *as it was* | Feed it in as a `Direction3D` action ([§13](patterns.md#13-camera)) |
| Reading or writing module-level Lua tables | They do not roll back | Attributes |
| Branching on `IsServer()` / `IsClient()` for *simulation outcomes* | The two machines then compute different worlds | Branch only on **who owns this character** |
| Anchoring a character part | Excludes it from prediction entirely, silently | Leave it unanchored; drive it with forces |

---

## Silent failures

None of these produce an error or a warning. This table is the reason this document exists.

| Symptom | Cause | Fix |
|---|---|---|
| Input feels like full round-trip lag | `player.Character` not set, so nothing is pulled into the prediction and rollback loop | Set it to the model |
| Nothing moves at all | Sim module initialized on only one side | `require(...).Initialize()` in **both** the server Script and the client LocalScript |
| Character never rolls back; `GetPredictionStatus` says `Authoritative` | A character part is `Anchored` | Unanchor it |
| Character is never predicted | The client was never sent the model | Set `ModelStreamingMode` (`Persistent` for characters) |
| Camera sits near the world origin and ignores you | No `PlayerModule` in a characterless place | Build the camera; set `CameraType = Scriptable` |
| Camera writes are silently overwritten | `CameraType` is not `Scriptable` | Set it |
| Stock camera pushes through your character | `player.Character` not set | Set it to the model |
| A servo applies zero force forever | A constraint has a nil `Attachment0`/`Attachment1` | Parent attachments *before* referencing them; assert both at spawn and `warn()` |
| A limb moves but the body never reacts; motion reads as floaty | `OneAttachment` mode — the reaction force goes to the universe | `TwoAttachment` + `ReactionForceEnabled = true` ([§7](patterns.md#7-constraints-reaction-forces-and-silent-failure)) |
| Constant mispredictions near your own character | Client-only visuals have `CanQuery = true` and answer sim raycasts | `CanQuery = false`, or mask a collision group |
| An action does nothing | The `InputAction` has no `.Name`, so name lookup misses | Name every action |
| InputContext never replicates | It does not descend from a `Player` | Parent it to the Player |
| An attribute silently stops replicating | Past the first 64 attributes, or name > 50 chars, or string value > 50 chars | Budget attributes; shorten names |
| An attribute is never set | Name contains `.` | Sanitize names derived from part names |
| An effect fires twice | It is inside the sim and firing on replayed steps | Move it out, or gate on `not RunService:IsResimulating()` |
| Works in Play, diverges under real prediction | State kept in a module-level Lua table | Move it into attributes |
| A tooling/command-bar toggle does not reach your module | Command-bar VMs get a *different copy* of the module on `require` | Toggle via a workspace attribute |
| Servo overshoots / accelerates forever | Feed-forward is untapered, or the negative gap term was dropped | Taper FF with a knee; keep the gap term ([§3](physics-characters.md#the-velocity-servo)) |
| Steering ignores the camera | The camera-direction action is not firing, or the sim reads the camera directly | Fire on change > 0.02 with a 0.5 s keep-alive |

---

## Setup checklist

Place state, by hand in Studio — `AuthorityMode` cannot be scripted (`lacking capability
RobloxScript`):

- [ ] `Workspace.AuthorityMode = Server`
- [ ] `Players.CharacterAutoLoads = false` (also set it in the server script, so the
      assumption is visible in source control)
- [ ] Save the place

In code, per player, on `PlayerAdded`:

- [ ] Build or clone the `InputContext` and parent it to the `Player`
- [ ] Spawn the character model, parts **unanchored**
- [ ] Pre-wire every actuator (`VectorForce`, `AlignOrientation`, `AlignPosition`, …)
- [ ] Seed intent attributes on the root part
- [ ] Set `ModelStreamingMode`
- [ ] Set `player.Character = model` — this is the one that drives prediction
- [ ] Set `player.ReplicationFocus = root` — streaming radius
- [ ] Destroy the model on `PlayerRemoving`

Both sides:

- [ ] `require(Sim).Initialize()` in the server `Script`
- [ ] `require(Sim).Initialize()` in the client `LocalScript`

Client only:

- [ ] `camera.CameraType = Enum.CameraType.Scriptable`
- [ ] Camera built and following a **smoothed proxy**
- [ ] Camera direction fired into the `Direction3D` action on change, with a keep-alive
- [ ] Presentation layer, with `CanQuery = false` on every visual

---

## Verification

Run **Play** (single-process is accurate; it runs the real predict/resimulate loop). Confirm
in order:

1. The character spawns and the console is clean.
2. `RunService:GetPredictionStatus(root)` returns `Enum.PredictionStatus.Predicted`.
3. WASD drives it camera-relative; holding W while swinging the camera carves a curve.
4. Speed rises to the target and holds — check the numbers, not the feel:

```lua
-- client command bar, while driving
local root = workspace.<Folder>["<Name>_" .. game.Players.LocalPlayer.UserId].<Root>
task.spawn(function()
	for _ = 1, 10 do
		local v = root.AssemblyLinearVelocity
		print(string.format("v=%.1f", (v - Vector3.yAxis * v.Y).Magnitude))
		task.wait(0.5)
	end
end)
```

Then switch to **Test → Server & Clients** (1 client) plus **Network Simulation** to check
behavior under real latency: correction magnitude, remote rendering, cheat resistance.

Jitter in single-process Play is a real bug in the rig or the prediction. Chase it; do not
switch modes to hide it.

---

## Costs to design around

- Resimulation at 100 ms latency is roughly **6.25× a normal frame's** simulation load.
- Resim is the common case: a 3-second single-process sample logged **105 resimulated steps
  against 91 live ones**.
- A position mismatch of **≥ 0.1 studs** flags a misprediction.
- **Player-versus-player contact always mispredicts.** Design collisions soft and springy so
  corrections read as physics rather than teleports.
- Zero mispredictions is not the goal. Visible *snapping* is the thing to chase.
