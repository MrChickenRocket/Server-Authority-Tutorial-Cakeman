# Server-authoritative physics characters in Roblox

A mini article on building a custom physics character under Roblox **Server
Authority** (`Workspace.AuthorityMode = Server`) from an empty baseplate. 

**[Chapter 1 — the method, built on a sliding cube](docs/01-the-method.md)**
The three-part method end to end: a server-owned character, client prediction, and a
presentation layer. Four files, about 200 lines, runnable. Start here.

This one doesn't use a Humanoid or a CharacterController - just straight parts and forces to get you started.

**[Chapter 2 — the cake with noodle arms](docs/02-building-cakeman.md)**
The natural extension of part 1 - The same four files, with the cube replaced by a floppy cake man made from ball sockets. 
The netcode doesn't change; only the character does.

**Prior reading:** [Roblox Server Authority documentation](https://create.roblox.com/docs/projects/server-authority)

<!-- HERO CLIPS -----------------------------------------------------------------
     Drop the two MP4s into a GitHub issue comment (don't post it), copy the
     https://github.com/user-attachments/... URL each one turns into, and paste
     them below as bare URLs on their own line. GitHub renders those as players.
     See docs/assets/README.md for the full procedure.

     Chapter 1 — the cube:
     Chapter 2 — CakeMan:
------------------------------------------------------------------------------ -->

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
ReplicatedFirst/         the CakeMan source that Chapter 2 draws on
ServerScriptService/
ServerStorage/
```

Script suffixes are a file-sync convention: `.luau` is a ModuleScript, `.local.luau` a
LocalScript, `.legacy.luau` a Script.
**Test → Server & Clients** before taking any of this into a shipping game.
