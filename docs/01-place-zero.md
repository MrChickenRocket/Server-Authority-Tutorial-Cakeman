# 1. Place zero

Two settings, one deletion, and a decision about where your game actually lives.

## The two settings

**`Workspace.AuthorityMode = Server`.** This is the whole series. The server owns
the truth; clients predict it and get rolled back when they're wrong. Set it in the
Workspace properties — it's a place setting, not a script.

**`Players.CharacterAutoLoads = false`.** We have no Humanoid and no R15. CakeMan
*is* the character, and we spawn him ourselves. Roblox will otherwise cheerfully
give every player a stock avatar you didn't ask for and can't use.

```lua
-- CakeServer.legacy.luau
Players.CharacterAutoLoads = false -- no Humanoids; CakeMan IS the character
```

That second one has a consequence people don't see coming, and it's Chapter 4: with
no Humanoid, **there is no camera**. Not "a camera you need to configure" — no
camera module at all. You will write your own or you will stare at the sky.

## Test with Server & Clients, not Play

`Play` runs one process and hides the entire point of the exercise. Use
**Test → Server & Clients**, with two clients if you can bear it. Prediction only
exists because of latency; a setup with no latency will happily let you ship a
character whose brain is subtly wrong.

I'll be honest about the limits of my own testing here: nearly every trace in this
series was taken in a single-process Play, because that's what I could drive from a
script. The numbers are real, but a **full latency pass under Server & Clients is
the one thing in this project I have not done**, and I say so again in Chapter 12
rather than pretending otherwise.

## What's in the place, and what's in the code

Here's the project. Eleven files, about 2,600 lines, and — importantly — **some real
instances that are not code at all**.

```
ReplicatedFirst/
  CakeSim.luau            336  THE BRAIN. Runs on server AND client. The only file
                               bound to the simulation. Read it first.
  CakeClient.local.luau   216  Client boot: the camera, the CameraDir feed, F6 debug.
  Presentation.luau       225  The smoothed visual layer (Chapter 7).
  Smoothing.luau           17  SmoothDamp. Seventeen lines.
  HealthUI.local.luau     138  Health bars, parented to the smoothed copies.

ServerScriptService/
  CakeServer.legacy.luau  244  Spawns players by CLONING the rig. Input contexts.
                               Respawn. Checks the rig's wiring at spawn.
  CakeCombat.legacy.luau  317  Damage, the cherry shot, the knockout, regen (Ch 8, 10).
  CakeGrab.legacy.luau    219  What you caught, and how long you keep it (Ch 9).
  BoxRecycle.legacy.luau   90  Boxes that fall in the pit come back (Ch 5).

ServerStorage/
  GenerateRig.legacy.luau    566  DISABLED. The recipe that bakes the rig.
  GenerateArena.legacy.luau  279  DISABLED. The recipe that bakes the arena.

...and in the place file itself:
  ServerStorage.CakeManRig    the actual character. A Model. You can open it.
  workspace.Arena             the actual level.
  workspace.Props             the actual 73 boxes.
```

## The artefact and the recipe

That last block is a reversal, and it's worth stopping on, because I built this
project the other way round first and spent a long time defending it.

Originally **everything was built at boot**. The character was assembled from
`Instance.new` calls when the server started; so was the arena. It's an elegant way
to work and it has one genuinely excellent property: the whole game is in source
control, and you can diff it.

It's also completely opaque. You cannot inspect a character that doesn't exist until
the server runs. You cannot select a joint and look at its cone in the gizmo — which
matters enormously, because in Chapter 2 a *gizmo* is what finally shows me that
every joint in my rig has been wrong for a week. You cannot hand the thing to an
artist. And you cannot answer the question "what is actually in my game right now?"
without running it.

So now: **the artefact lives in the place, and the recipe lives in a disabled script
next to it.**

- `ServerStorage.CakeManRig` is a real Model, saved in the place. `CakeServer` clones
  it. You can open it in the explorer and look at every joint.
- `ServerStorage.GenerateRig` is the script that *produced* that Model. It is
  `Disabled = true`. It is not part of the running game. It's the recipe: run it once
  when you want to change the character, then **stop and save the place**.

You get both halves — an inspectable artefact, and a diffable, commented,
reproducible description of how it was made. The cost is a rule you must now
remember: **an instance in the place can be wrong in ways code cannot.** Someone can
delete an attachment. An edit can go unsaved. A constraint can quietly lose a
reference.

Which brings us to the most expensive lesson in the project, stated early so you have
it before you need it:

> **A constraint with a nil `Attachment` does not error.** It does not warn. It
> applies exactly zero force, forever, in silence — and every symptom points at
> tuning ("the grip feels weak", "that servo's too soft") rather than at wiring.

It cost me hours on three separate occasions. So `CakeServer` now states the contract
and checks it, out loud, every time it clones a man:

```lua
-- CakeServer.legacy.luau
local function checkRig(man: Model)
	for _, side in { "L", "R" } do
		local fist = man:FindFirstChild("Arm" .. side .. "5") :: BasePart?
		local reach = fist and fist:FindFirstChild("Reach") :: AlignPosition?
		if not reach then
			warn("[CakeServer] rig is missing Arm" .. side .. "5.Reach -- the guard will not go up")
			continue
		end
		if reach.Attachment1 == nil then
			warn("[CakeServer] Arm" .. side .. "5.Reach has NO Attachment1 -- the guard servo has "
				.. "nothing to pull against and will apply zero force. Re-run ServerStorage.GenerateRig "
				.. "and SAVE THE PLACE.")
		elseif not reach.ReactionForceEnabled then
			warn("[CakeServer] Arm" .. side .. "5.Reach has no reaction force -- his hands are pulling against the sky")
		end
	end
end
```

It costs one comparison per player, and it converts a week-long mystery into a line
in the output window. If you take one habit from this chapter, take that one.

There's a corollary I learned the hard way in Chapter 9, so here it is in advance:
**an asymmetry in a symmetrical rig is a wiring bug until proven otherwise.** When
only his left arm could lift, I went looking for a strength problem. There wasn't
one. The right arm's servo had no attachment and was applying zero force, exactly as
promised above. A real strength problem would have been weak on *both* sides.

## The two lines everyone forgets

When you spawn a character with no Humanoid, two things that normally happen for you
do not happen, and both failures are baffling.

```lua
-- CakeServer.legacy.luau
player.ReplicationFocus = man.PrimaryPart
player.Character = man
```

**`ReplicationFocus`** is what the server replicates around, and — the part that
matters — what prediction is *centred* on. Without it, your own CakeMan isn't
predicted, and every input you make feels like it's travelling to another country and
back. Because it is.

**`player.Character`** is what the camera knows not to shove itself through. We have
no Humanoid, so nothing sets it for us, and until I did, the stock camera treated
CakeMan as scenery and rammed itself straight through his own cake. Setting it costs
nothing and does not summon a Humanoid. It just tells the engine: *this pile of parts
is him.*

Two lines. Neither is discoverable. Both are load-bearing.
