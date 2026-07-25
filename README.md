# Server-authoritative physics characters in Roblox

A two-chapter article on building a custom physics character under Roblox **Server
Authority** (`Workspace.AuthorityMode = Server`) from an empty baseplate. No Humanoid, no
animation-driven movement.

**[Chapter 1 — the method, built on a sliding cube](docs/01-the-method.md)**
The three-part method end to end: a server-owned character, client prediction, and a
presentation layer. Four files, about 200 lines, runnable. Start here.

**[Chapter 2 — the cake with noodle arms](docs/02-building-cakeman.md)**
The same four files, with the cube replaced by a floppy cake on ball sockets. The netcode
doesn't change; only the character does.

**Prior reading:** [Roblox Server Authority documentation](https://create.roblox.com/docs/projects/server-authority)

## Open a place and drive it

| Place | What's in it |
|---|---|
| [`samples/chapter1place/`](samples/chapter1place/) | Chapter 1 finished: the driveable cube, predicted and smoothed |
| [`samples/cakemanplace/`](samples/cakemanplace/) | Chapter 2 finished: CakeMan, the arena, and punching |

Download the `.rbxl`, open it in Studio, and press **Test → Server & Clients**. Both places
already have `Workspace.AuthorityMode = Server` set.

WASD drives. In the CakeMan place, walk into someone and swing — the arms do the rest.

## The scripts on their own

[`samples/cube/`](samples/cube/) — the finished Chapter 1 scripts, if you'd rather build up
from an empty baseplate than read a finished place. Drop them in at these paths:

| File | Goes to | Class |
|---|---|---|
| `CubeSim.luau` | `ReplicatedFirst` | ModuleScript |
| `CubePresent.luau` | `ReplicatedFirst` | ModuleScript |
| `CubeClient.local.luau` | `ReplicatedFirst` | LocalScript |
| `CubeServer.legacy.luau` | `ServerScriptService` | Script |

Then set `Workspace.AuthorityMode = Server` by hand in the Properties panel. That one is
place state and cannot be scripted — a script that tries gets `lacking capability
RobloxScript`.

`samples/cube.rbxm` is the same thing as a drag-and-drop model.

## Repo layout

```
docs/                    the article
  assets/                screenshots and clips, named for the step that uses them
samples/
  chapter1place/         Chapter 1 finished, as a place file
  cakemanplace/          Chapter 2 finished, as a place file
  cube/                  Chapter 1's four scripts on their own
  repro/                 four-cube minimal repro: anchored parts are not predicted
ReplicatedFirst/         the CakeMan source that Chapter 2 draws on
ServerScriptService/
ServerStorage/
```

Script suffixes are a file-sync convention: `.luau` is a ModuleScript, `.local.luau` a
LocalScript, `.legacy.luau` a Script.

## Verified

Chapter 1's cube was built and driven in a live Studio session with
`AuthorityMode = Server`: spawn, InputActions, shared sim on both machines, camera-relative
steering, and the smoothed presentation copy with `CanQuery = false`. Holding W for 1.5 s
moved it 35.2 studs — **23.5 studs/s** against a `SPEED` of 24.

Smoothness was measured rather than eyeballed. At the default `Enum.StepFrequency.Hz30` the
visible copy's speed swung 8.5–37.2 studs/s — **27%** wobble around its own mean. At `Hz60`
with a continuous lead velocity: 23.3–24.5 studs/s, **1.1%**.

The character part is **unanchored**, and that is not cosmetic. An anchored part is excluded
from client prediction entirely — the owning client reports itself `Authoritative` for its
own server-owned character, and nothing is ever rolled back. `samples/repro/` isolates the
variable across four cubes and is written up as a bug report.

Not yet verified: the **Server & Clients latency pass**. Single-process Play looks falsely
jittery under Server Authority and cannot show reconcile quality, remote-character
readability, or player-vs-player mispredicts. Both chapters say so where it matters.
