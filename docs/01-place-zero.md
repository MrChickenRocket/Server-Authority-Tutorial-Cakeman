# 1. Place zero

Almost nothing, and then two lines that everybody forgets.

## The place settings

Three things, and only the first is interesting.

1. **`Workspace.AuthorityMode = Server`** — set it in the Properties panel. This is
   the whole point of the exercise. (You can't set it from a script; it needs
   privileges a Script doesn't have. Same for `StreamingEnabled` and a few others we
   meet later — they'll accept the assignment and silently ignore you, which is a
   great way to lose an afternoon.)
2. **`Players.CharacterAutoLoads = false`** — we're spawning our own character, so we
   don't want Roblox making one. Set it in code too, so the assumption is visible in
   source control:

```lua
Players.CharacterAutoLoads = false -- no Humanoids; CakeMan IS the character
```

3. A baseplate. We'll delete it in chapter 5 and build a real arena.

## Test properly, or don't bother

**Use `Test → Server & Clients`, not single-process Play**, for anything that touches
networking. Single-process play under Server Authority looks *falsely* jittery — you
will spend a day chasing a stutter that doesn't exist. Single-process is fine for
"does the rig stand up"; it is worthless for "does this feel good".

## The file layout

Four files, and one of them is eight lines.

```
ReplicatedFirst/
├── CakeSim.luau           -- the shared brain. Runs on the server AND the client.
├── Presentation.luau      -- the visual layer (chapter 7)
├── Smoothing.luau         -- one function: a critically-damped spring
└── CakeClient.local.luau  -- prediction bootstrap, camera, debug views
ServerScriptService/
├── CakeServer.legacy.luau -- builds the rig, spawns it, wires input
└── Arena.legacy.luau      -- builds the level (chapter 5)
```

The shape to notice: **the brain is in `ReplicatedFirst`**, because both machines need
it. The server requires it. The client requires it. Same module, same code, same
results — that's what makes prediction possible at all.

## The two lines everyone forgets

When the player spawns, on the server:

```lua
player.ReplicationFocus = man.PrimaryPart  -- what to replicate around
player.Character        = man              -- what to PREDICT around
```

Without a Humanoid, nothing sets these for you, and **the engine has no idea where you
are.** The symptoms are miserable and don't obviously point at the cause:

| Symptom | Cause |
|---|---|
| Your own input feels like full round-trip lag | `ReplicationFocus` unset — nothing near you is predicted |
| Props seem to "join the world late" when you hit them | `Character` unset — the prediction bubble has no centre |
| The camera rams straight through your own character | `Character` unset — the camera only refuses to shove past `Player.Character` |

That last one is real and I lost time to it. All three are the same two lines.

Chapter 6 is entirely about what happens when you *don't* trust these two lines and
try to be clever instead. Spoiler: don't.

---

**Next:** [Chapter 2 — the rig](02-the-rig.md). A cake made of ball sockets.
