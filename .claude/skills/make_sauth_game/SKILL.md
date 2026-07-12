---
name: make_sauth_game
description: Scaffold a new server-authoritative (SA) custom physics character game for Roblox from an empty baseplate — place settings, the four-file spawn/input/sim/client architecture, and playtest checkpoints. Use when the user wants to start a new SA physics game or invokes /make_sauth_game.
---

# Make a server-authoritative physics game

Scaffold a working SA physics character using this repo's files as **verified
templates**. The output is a character you can drive with WASD, camera-relative,
predicted on the owning client, before any game-specific features.

## 1. Gather the concept (ask once, briefly)

- Character name and rough body plan (root part + what hangs off it).
- Where the synced script folder lives (ScriptSync root).

Default to a two-part rig — one dense root part + one light part on a loose
ball socket — if the user has no strong opinion. It proves every pipeline stage
and is trivially reshaped later.

## 2. Place settings — the ones that break silently

Tell the user to do these manually in Studio (they are place state, not code,
and `AuthorityMode` cannot be read or written from tooling Luau):

1. `Workspace.AuthorityMode = Server` (Properties panel).
2. Save the place file.

Everything else is code. `Players.CharacterAutoLoads = false` is set in the
server script (visible in source control) — no Humanoids, ever.

## 3. Generate the four files

Copy and adapt the templates in this repo, renaming `Cake*` to the user's
character. Keep the file-class suffixes: `.luau` ModuleScript, `.local.luau`
LocalScript, `.legacy.luau` Script.

| Template | Role |
|---|---|
| `ServerScriptService/CakeServer.legacy.luau` | rig factory, actuators, InputContext, spawn/despawn |
| `ReplicatedFirst/CakeSim.luau` | the shared brain — velocity servo + steering |
| `ReplicatedFirst/CakeClient.local.luau` | prediction bootstrap, camera, CameraDir feed |
| `ReplicatedFirst/Smoothing.luau` | SmoothDamp helper (copy verbatim) |

## 4. Rules that must survive any adaptation

These are the load-bearing patterns; everything else is skinnable.

- **State contract**: the owner (server for all characters; a client for its
  own) reads live input and writes *intent* as attributes on the root part.
  Every peer drives the actuators from those attributes, identically.
  Attributes written inside the sim roll back with resimulation.
- **The sim is deterministic**: no wall-clock, no unseeded randomness, no
  instance creation, no effects, no yielding inside the `BindToSimulation`
  callback. It re-runs ~6x during reconcile. Timers are countdown attributes
  decremented by `dt`; progress clocks advance by distance, not time.
- **Actuators are pre-wired at spawn**; the sim only sets targets
  (`.Force`, `.CFrame`) — that's what makes a re-simulated frame idempotent.
- **`player.ReplicationFocus = root part`** — without it (no Humanoid) nothing
  near the player gets predicted and every input feels like round-trip latency.
- **Input via `InputContext`/`InputAction` under the Player**, never
  RemoteEvents — actions replicate AND roll back. The camera direction is fed
  in as a `Direction3D` action the client fires (on change > 0.02, plus a
  0.5 s keep-alive); the sim must never read the camera directly.
- **Steering recomputed every frame** from the live camera dir; movement uses
  the target direction immediately while a separate facing direction slews
  toward it — the body carves, the nose catches up.
- **Forces, never velocity snaps**: velocity servo = tapered feed-forward +
  gap term that goes negative above target (a cap, not a motor). Coast with
  light drag on release, no hard brakes.
- **`ModelStreamingMode.Atomic`** on the character model.
- **`BeanSim.Initialize()` equivalent must run on BOTH sides** — server script
  and client script each `require` and initialize the same module.
- All tunables at the top of the sim file, in acceleration units, each with a
  comment saying what it *feels* like.

## 5. Verify — checkpoint before features

Run **Test → Server & Clients** (1 client). Single-process Play looks falsely
jittery under SA — never judge networking with it. Confirm:

1. Character spawns, console clean.
2. WASD drives it camera-relative; holding W while swinging the camera carves
   a curve.
3. Speed rises to ~TARGET_SPEED and holds (trace it — numbers, not vibes):

```lua
-- client command bar, while driving
local root = workspace.<Folder>["<Name>_" .. game.Players.LocalPlayer.UserId].<Root>
task.spawn(function()
	for i = 1, 10 do
		local v = root.AssemblyLinearVelocity
		print(string.format("v=%.1f", (v - Vector3.yAxis * v.Y).Magnitude))
		task.wait(0.5)
	end
end)
```

Symptom table:

| Symptom | Cause |
|---|---|
| Input feels like full round-trip lag | `ReplicationFocus` not set |
| Constant jitter/rubber-banding | Single-process Play — use Server & Clients |
| Steering ignores the camera | CameraDir action not firing, or sim reads the camera directly |
| Accelerates forever / overshoots | Velocity set directly, or the negative gap term was dropped |
| Nothing moves | Sim module not initialized on both sides |

## 6. What comes next (point, don't build)

Wobble mass, gait/feet, and polite rendering (hiding correction jitter behind a
client-only smoothed proxy — remember `CanQuery = false` on every client-side
visual part, or sim raycasts hit client-only geometry and mispredict). Follow
the chapter order in this repo's tutorial rather than improvising the order.
