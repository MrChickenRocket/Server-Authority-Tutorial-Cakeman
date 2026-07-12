# CakeMan — a server-authoritative physics character, from scratch

The companion repo for the CakeMan tutorial series: building a fully
physics-driven character under Roblox **Server Authority**
(`Workspace.AuthorityMode = Server`) from an empty baseplate. No Humanoid, no
animation-driven movement — the ragdoll IS the character. CakeMan is a pair of
legs carrying a large dinner plate; each round, cakes get stacked on the plate
and your job is to keep them there.

## Layout

Scripts sync into the place via ScriptSync. Naming conventions:

| Suffix | Class |
|---|---|
| `.luau` | ModuleScript |
| `.local.luau` | LocalScript |
| `.legacy.luau` | Script |

```
ReplicatedFirst/
├── CakeSim.luau           -- the shared brain: runs on BOTH server and client
├── Smoothing.luau         -- analytic SmoothDamp helper
└── CakeClient.local.luau  -- prediction bootstrap, camera, CameraDir feed
ServerScriptService/
└── CakeServer.legacy.luau -- rig factory, actuators, input contexts, spawning
```

## Place settings (manual, not in this repo)

- `Workspace.AuthorityMode = Server` — must be set in Studio's Properties panel.
- `Players.CharacterAutoLoads = false` — set in Studio AND in `CakeServer` so
  the assumption is visible in source control.
- Test with **Test → Server & Clients**, never single-process Play, when
  judging anything network-related.

## Status

Checkpoint 1 (spawn → input → shared sim → camera-relative driving) verified
in-place. Legs, polite rendering, and the cake round are in progress.

## Starting your own SA game

This repo ships a Claude Code skill: run `/make_sauth_game` in a Claude Code
session opened at this repo to scaffold a new server-authoritative physics
character game using these files as verified templates.
