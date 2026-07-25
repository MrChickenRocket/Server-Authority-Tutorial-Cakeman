# Repro: `Anchored` parts are excluded from client prediction under Server Authority

A player's own server-owned character part reports
`RunService:GetPredictionStatus() == Authoritative` **on the owning client** when the part
is `Anchored`, and `Predicted` when it is not. The drive method makes no difference; only
`Anchored` does.

There is no error, no warning, and no observable difference in single-process `Play`.

## Environment

| | |
|---|---|
| `Workspace.AuthorityMode` | `Server` |
| `Players.CharacterAutoLoads` | `false` (no Humanoid anywhere) |
| Character | plain `Model` + `Part`, set via `player.Character` |
| `player.ReplicationFocus` | set to the model's `PrimaryPart` |
| `ModelStreamingMode` | `Persistent` |
| Sim | `RunService:BindToSimulation(fn, Enum.StepFrequency.Hz60)`, on server **and** client |
| Tested in | Studio, single-process `Play` |

## Repro

The quickest route is to open [`../chapter1place/`](../chapter1place/), which already has
these three scripts in it (disabled, alongside the chapter 1 cube). Enable `ReproServer` and
`ReproClient`, disable `CubeServer` and `CubeClient` so the two don't fight over
`player.Character`, and press Play.

To build it from scratch instead:

1. New baseplate. Set `Workspace.AuthorityMode = Server`.
2. Drop in the three scripts from this folder:

   | File | Location | Class |
   |---|---|---|
   | `ReproServer.legacy.luau` | `ServerScriptService` | `Script` |
   | `ReproSim.luau` | `ReplicatedFirst` | `ModuleScript` |
   | `ReproClient.local.luau` | `ReplicatedFirst` | `LocalScript` |

3. Press Play. Four cubes spawn in a row under an overhead pinned camera, each labelled
   with its live prediction status. Drive them all with WASD.

All four cubes belong to the same `Model`, that model is the local player's
`player.Character`, and its `PrimaryPart` is the `ReplicationFocus`. All four are
dead-reckoned from the same `InputAction` to the same position by the same code. **The
only thing that differs is how that position reaches the instance.**

## Result

| # | Cube | `Anchored` | How it is moved | `GetPredictionStatus` |
|---|---|---|---|---|
| 1 | `Cube1_AlignPosition` | false | `AlignPosition` + `AlignOrientation` targets | **`Predicted`** |
| 2 | `Cube2_AnchoredCFrame` | **true** | `part.CFrame = …` in the sim | **`Authoritative`** |
| 3 | `Cube3_UnanchoredCFrame` | false | `part.CFrame = …` in the sim, plus velocities zeroed each step | **`Predicted`** |
| 4 | `Cube4_AttributeRender` | **true** | sim writes a `Pos` attribute; client sets `CFrame` on `RenderStepped` | **`Authoritative`** |

**Cube 3 is the control.** It writes `CFrame` directly, exactly like Cube 2, and it is
predicted. So direct `CFrame` assignment inside `BindToSimulation` is not the problem.
`Anchored` is the only variable that changes the outcome.

Cube 4 shows the same exclusion applies to *attributes*: a rolled-back attribute on an
anchored carrier is on an instance the client already considers itself authoritative for.

## Expected

An instance that is (a) parented under the local player's `Character`, (b) within the
`ReplicationFocus`, and (c) owned and written by the server, should participate in
prediction and rollback regardless of whether it is `Anchored` — or should say why it does
not.

## Observed

The owning client reports itself `Authoritative` for a part the **server** owns and
writes. Nothing is rolled back and no resimulation occurs for it.

## Why this is easy to ship by accident

An anchored part you `CFrame` from `BindToSimulation` produces a character that spawns,
drives, replicates, and — in single-process `Play` — matches the server exactly, to the
last decimal. Both machines run the same deterministic code with zero latency, so they
agree for reasons that have nothing to do with prediction.

`Play` cannot reveal this. `GetPredictionStatus` is the only signal, and you have to
already suspect the problem to go looking for it.

The practical request is a diagnostic: a warning when an instance under `player.Character`
is excluded from the prediction set, or documentation stating that `Anchored` instances are
never predicted.

## What this repro does not establish

- Everything above is single-process `Play`. A **Server & Clients** run under real latency
  has not been done, and would be needed to characterise the downstream behaviour of the
  unpredicted cubes.
- Whether `Authoritative` here means "client owns it" or is a fallback value for
  "not tracked" is not something this repro can distinguish from the outside.
- No claim is made that this is unintentional. `Anchored` parts are not simulated, so
  "nothing to predict" is a coherent design position. The report is about the silence, not
  the policy.

## Smoothness numbers (secondary)

Measured over 1.6 s of driving at a true 24 studs/s, sampling the visible frame-to-frame
speed:

| Cube | avg | deviation |
|---|---|---|
| 1 AlignPosition | 23.3 | 6.1% |
| 2 CFrame / anchored | 23.3 | 6.1% |
| 3 CFrame / unanchored + stomp | 23.3 | 6.1% |
| 4 attribute → RenderStepped | 23.0 | 8.3% |

Cubes 1–3 are identical because all three are moved during the simulation step and sampled
afterwards. Cube 4 is moved in a `RenderStepped` handler whose ordering against the
sampling handler is not guaranteed, so its higher figure is at least partly a measurement
artifact rather than real jitter. Render rate during capture was ~15 fps (unfocused Studio
window), so treat these as relative, not absolute.
