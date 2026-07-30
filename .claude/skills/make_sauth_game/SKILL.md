---
name: make_sauth_game
description: Scaffold a new server-authoritative (SA) custom physics character game for Roblox from an empty baseplate — place settings, the four-file spawn/input/sim/client architecture, and playtest checkpoints. Use when the user wants to start a new SA physics game or invokes /make_sauth_game.
---

# Make a server-authoritative physics game

Scaffold a working SA physics character from verified templates in this repo. The output is
a character you can drive with WASD, camera-relative, predicted on the owning client, before
any game-specific features.

> **This file is a procedure, not doctrine.** The rules live in
> [`docs/reference/`](../../../docs/reference/) and are maintained there. Do not copy them
> back into this file — a second copy drifts, and has already done so twice. Link instead.

## 0. Read the rules first

Read [`docs/reference/rules.md`](../../../docs/reference/rules.md) before writing any code.
It is ~1,400 words and it is the whole set of invariants, the banned-inside-the-sim table,
and the silent-failure table.

**Almost every Server Authority failure mode is silent.** No error, no warning, no output —
just a character that feels laggy, or does not move, or mispredicts constantly. You cannot
debug your way to these; you have to not make them. That is what the tables are for.

Keep [`patterns.md`](../../../docs/reference/patterns.md) open for the code shapes.

## 1. Gather the concept (ask once, briefly)

- Character name and rough body plan (root part + what hangs off it).
- Where the synced script folder lives (ScriptSync root).

Default to a two-part rig — one dense root part plus one light part on a loose ball socket —
if the user has no strong opinion. It proves every pipeline stage and is trivially reshaped
later.

## 2. Place settings

These are place state, not code. `AuthorityMode` cannot be read or written from tooling Luau
(a script that tries gets `lacking capability RobloxScript`), so the user must do it by hand:

1. `Workspace.AuthorityMode = Server` in the Properties panel.
2. Untick `Players.CharacterAutoLoads`.
3. Save the place file.

The server script also sets `Players.CharacterAutoLoads = false` in code so the assumption is
visible in source control. Either alone is enough; do both.

No Humanoids, ever.

## 3. Generate the four files

**Scaffold from the cube set.** It is ~200 lines, has no rig complexity, and is verified
line-for-line against Chapter 1 of the tutorial:

| Template | Class | Role |
|---|---|---|
| `samples/cube/ServerScriptService/CubeServer.legacy.luau` | Script | Place settings, spawning, actuators, InputContext |
| `samples/cube/ReplicatedFirst/CubeSim.luau` | ModuleScript | The shared brain — velocity servo + steering |
| `samples/cube/ReplicatedFirst/CubeClient.local.luau` | LocalScript | Prediction bootstrap, camera, CameraDir feed |
| `samples/cube/ReplicatedFirst/CubePresent.luau` | ModuleScript | Presentation layer + the critically-damped spring |

Rename `Cube*` to the user's character. Keep the file-class suffixes: `.luau` ModuleScript,
`.local.luau` LocalScript, `.legacy.luau` Script.

The CakeMan set at the repo root (`ReplicatedFirst/CakeSim.luau`,
`ReplicatedFirst/Presentation.luau`, `ReplicatedFirst/Smoothing.luau`,
`ServerScriptService/CakeServer.legacy.luau`, `ServerScriptService/CakePunch.legacy.luau`,
`ServerStorage/GenerateRig.legacy.luau`) is the *next* step, not the scaffold — a ball-socket
ragdoll with a rig generator and a punch mechanic. Reach for it once the cube drives.

## 4. Scaffold decisions you have to make explicitly

Everything else is skinnable; these are the choices the templates encode that an adaptation
can silently get wrong. Each links to the reasoning.

- **`ModelStreamingMode`** — the cube uses `Persistent`. An instance the client was never sent
  cannot be predicted, which makes `Persistent` the stronger guarantee for a character;
  `Atomic` only promises you never see half a model.
  → [patterns.md §15](../../../docs/reference/patterns.md#model-streaming-for-characters)
- **Bind frequency** — pass `Enum.StepFrequency.Hz60`. The default is `Hz30` while physics
  runs at 60, so the servo corrects half as often as the world it is correcting.
  → [rules.md #2](../../../docs/reference/rules.md#the-non-negotiables)
- **Both sides initialize the sim module** — the server Script and the client LocalScript each
  `require` and `Initialize()` the same file. Miss one and nothing moves, with no error.
  → [rules.md #1](../../../docs/reference/rules.md#the-non-negotiables)
- **Tunables at the top of the sim file, in acceleration units**, each with a comment saying
  what it *feels* like. Knobs then keep their meaning when the rig's mass changes.
  → [physics-characters.md §2](../../../docs/reference/physics-characters.md#2-the-body-is-gameplay-mass-joints-assemblies)

## 5. Verify — checkpoint before features

Run single-process **Play**. It runs the real predict/resimulate loop and is accurate for
building and tuning. Switch to **Test → Server & Clients** (1 client) plus Network Simulation
when you specifically want behavior under real latency.

1. Character spawns, console clean.
2. `RunService:GetPredictionStatus(root)` returns `Enum.PredictionStatus.Predicted`. If it
   says `Authoritative`, a character part is anchored.
3. WASD drives it camera-relative; holding W while swinging the camera carves a curve.
4. Speed rises to ~`TARGET_SPEED` and holds. Trace it — numbers, not vibes:

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

Scaffold-stage symptoms. The full 19-row table is
[rules.md](../../../docs/reference/rules.md#silent-failures):

| Symptom | Cause |
|---|---|
| Nothing moves | Sim module not initialized on both sides |
| Input feels like full round-trip lag | `player.Character` not set — that is what pulls parts into the prediction loop |
| Character never rolls back, status `Authoritative` | A character part is `Anchored` |
| Stock camera pushes through the character | `player.Character` not set |
| Camera sits near the world origin | No `PlayerModule` in a characterless place — build it, and set `CameraType = Scriptable` |
| Steering ignores the camera | CameraDir action not firing, or the sim reads the camera directly |
| Accelerates forever / overshoots | Velocity set directly, or the negative gap term was dropped |
| An action does nothing | The `InputAction` has no `.Name` |
| Constant jitter/rubber-banding | A real prediction bug — chase it, don't switch test modes |

## 6. What comes next (point, don't build)

Wobble mass, gait and feet, and the presentation layer. Follow the chapter order in
[`docs/`](../../../docs/) rather than improvising it.

For anything past the scaffold — omni-surface traversal, gait, chains, steering math, feel
tuning — [`physics-characters.md`](../../../docs/reference/physics-characters.md) has the
doctrine and the measurements behind it.
