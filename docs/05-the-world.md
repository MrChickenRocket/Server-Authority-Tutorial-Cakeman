# 5. The world: four bases, three bridges, and a hole

CakeMan needs somewhere to be and something to hit. This chapter carries one genuinely
important Server Authority rule, one reversal I had to make, and a level whose entire
design is **negative space**.

## Where instances are allowed to be created

**Not in the simulation.** Ever.

`CakeSim` re-runs several times per frame during reconciliation — I measured 105
resimulated steps against 91 live ones in a quiet single-process test. Anything it
*creates*, it would create again on every replayed step.

So nothing in this game is ever created by the simulation. Not the level, not the
props, and — the one that catches people — **not the constraints**. When CakeMan
throws his hands up, no `AlignPosition` is born: `Reach` and `Grip` already exist in
the rig, `Enabled = false`, waiting (Chapter 2). The sim's entire job is to flip
switches and write targets.

(There *is* a way to spawn instances predictively — create them on both sides inside
the simulation with a deterministic GUID so the engine can reconcile them. It's an
advanced move, and the fact that a game with punching, grabbing, carrying and
knockouts never needed it is, I think, the more useful lesson.)

## The reversal: the level lives in the place

The previous draft of this chapter argued, at length, that you should **build your
level in code, not in the place file** — because place geometry is invisible to source
control, and a script that rebuilds the world can be diffed and reviewed.

I no longer believe that, and the arena is now a set of real, baked instances:
`workspace.Arena` and `workspace.Props`, saved in the place. `GenerateArena.legacy.luau`
lives in **ServerStorage** and is **`Disabled = true`**.

The argument that changed my mind is the same one from Chapter 1: **you cannot look at
a level that doesn't exist yet.** You can't drag a wall six studs to the left and see
if it plays better. You can't hand it to anyone. Every iteration is an edit-compile-run
cycle on a thing whose entire nature is spatial. The diffability was real, and it was
worth *less* than being able to see the thing.

So: the artefact is in the place, the recipe is in a disabled script beside it, and
you get both. Run the recipe when you want to change the layout, then **stop and save
the place**.

## Anchored is free

Walls, floor, bridges: **anchored**. The physics engine never simulates a single one of
them. They cost nothing, they can't drift, and they cannot possibly disagree between
server and client. Anything that doesn't need to move should be anchored — it's the
cheapest correctness you will ever buy.

## The shape of the level, which is mostly a hole

Four colour-coded home bases on the compass points, a big central platform, and narrow
bridges between them.

| | |
|---|---|
| Centre | 44 × 44 |
| Bases | 38 × 38, at `BASE_DIST = 54` — one per player, four corners |
| Bridges | **13 studs wide** |
| Walls | 24 high, around the outside |
| Cover | four blocks (`CoverA`–`CoverD`) in the middle, to break sightlines |
| Everything else | **nothing. A drop to `KILL_Y = -40`.** |

The gaps between those platforms are not decoration. They're the *game*. A brawler
whose characters are heavy, slow, hard to steer and easy to shove is a brawler where
the most powerful weapon in the world is **an edge**, and this level is mostly edges.

I built ramps first. They were a mistake — fiddly to walk, ambiguous to fight on, and
they made the level read as terrain rather than as a set of *places you can be pushed
off*. Cutting them and replacing them with plain walls made everything better. **When a
level element is complicating the fight rather than framing it, delete it.**

## The lip that hard-stuck every player in their own base

The pit edges are painted. Each platform gets a bright kerb, so you can *see* the
danger:

```lua
local function lip(name, size, cf, color)
	local p = block(name, size, cf, color)
	p.CanCollide = false   -- THIS LINE
	p.CanTouch = false
	p.Material = Enum.Material.SmoothPlastic
end
```

Without `CanCollide = false`, those "warning stripes" are 0.5-stud solid kerbs around
the rim of every platform — and CakeMan is a heavy box that *slides* (base friction
0.05, Chapter 2). He has no legs. He cannot step over anything.

Every single player was hard-stuck inside their own base, bumping helplessly against a
decorative line, and it took me far too long to stop looking at the movement code. **A
character with no legs treats every decoration as a wall.** Decoration must be
non-colliding by default in a game like this, not as an afterthought.

## The props are just... parts

```lua
b.CustomPhysicalProperties = PhysicalProperties.new(BOX_DENSITY, 0.6, 0.15, 1, 1)
b.Parent = props
CollectionService:AddTag(b, "Prop")
CollectionService:AddTag(b, "Grabbable")
CollectionService:AddTag(b, "Presented")
local att = Instance.new("Attachment")
att.Name = "GrabAtt"   -- the handle. Baked in, because the sim can't make one.
att.Parent = b
```

That's it. No networking code. **No RemoteEvents** — *"the box moved"* is not a message,
it's physics. The server simulates them, they replicate, and clients near them predict
them automatically. This is the part of Server Authority that just works, and it's worth
sitting with for a second: the interaction you'd normally write an entire netcode layer
for is *nothing at all*.

`BOX_DENSITY = 0.008`. They're empty cardboard. He doesn't push them, he *detonates*
them — which is exactly the right reward for a slow, heavy character. There are **73** of
them, in piles, and the arena keeps that number for the life of the server (below).

### Three tags, three different questions

The tags are not a naming convention, they're a discipline, and it's worth being
explicit about what each one answers:

| Tag | Question it answers | Who reads it |
|---|---|---|
| `Prop` | **what is it?** | `CakeCombat` (may it hurt someone?), `BoxRecycle` |
| `Presented` | **what is done to it?** | `Presentation` (render a smoothed copy) |
| `Grabbable` | **what can be done to it?** | `CakeGrab` |

A part is not "a box". It's a thing that is inert, and rendered smoothly, and can be
picked up — three independent facts, three tags, three consumers who don't know about
each other. Adding the health bars later cost nothing precisely because nothing was
coupled.

## Streaming: an instance the client never got cannot be predicted

```lua
arena.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
props.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
```

This is load-bearing, and it's a Server Authority rule, not a performance tweak. If a
prop can be streamed out from under a client, then that client's simulation is running
on a *different world* than the server's. It cannot predict a box it was never sent.
You will see props that lag, stutter, or arrive late into the predicted world, and you
will blame the netcode, and it will be streaming.

We're not allowed to turn streaming off, so we mark what must always be there.

## Boxes come back (and go to limbo first)

Left alone, a box knocked into the pit falls forever and Roblox eventually destroys it
at `FallenPartsDestroyHeight`. Nothing leaks — but the arena quietly runs out of
ammunition over a match, and that's a slow, invisible degradation of the game nobody
will ever report as a bug.

So `BoxRecycle.legacy.luau` (90 lines, ordinary server code, not simulation) watches
for boxes below `KILL_Y`, freezes and hides them for `LIMBO_TIME = 6` seconds, and then
puts them back exactly where they started.

Two decisions in there worth stealing:

**Limbo, rather than an instant respawn.** A box that reappears the *instant* it falls
teaches players that the void is meaningless. Knocking someone's ammunition into the pit
should cost them something, even if it's only six seconds.

**Home is where it was baked.** The boxes are placed by the (disabled) generator and
saved into the place, so a box's home is simply *where it was when the server booted*:

```lua
local function adopt(b: Instance)
	if b:IsA("BasePart") then
		boxes[b] = { home = b.CFrame }
	end
end
```

No seed, no layout code, no duplicating the generator's maths. **The world IS the record
of where things go.** That's the artefact pattern paying rent: once the level is a real
thing in the place, the runtime doesn't need to know how it was made — only what it is.

---

**Next:** [Chapter 6 — prediction](06-prediction.md), the chapter I got wrong twice.
