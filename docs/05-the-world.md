# 5. The world: an arena, and 122 things to knock over

CakeMan needs somewhere to be and something to hit. This chapter is short on theory and
carries one genuinely important Server Authority rule.

## Where instances are allowed to be created

**Not in the simulation.** Ever.

`CakeSim` re-runs several times per frame during reconciliation. Anything it *creates*,
it would create again on every re-run. So the level, the props, and anything else that
needs to exist gets built in **ordinary boot code** — a plain `Script`, running once, on
the server, before anyone is playing.

```
ServerScriptService/Arena.legacy.luau   -- runs once. Builds walls and boxes. Done.
```

That's the whole rule, and it's the reason the arena is a separate script instead of
part of the character. (There *is* a way to spawn instances predictively — create them
on both sides inside the simulation with a deterministic GUID so the engine can
reconcile them. That's an advanced move and we don't need it here.)

## Anchored is free

Walls, floor, pillars: **anchored**. The physics engine never simulates a single one of
them. They cost nothing, they can't drift, and they cannot possibly disagree between
server and client. Anything that doesn't need to move should be anchored — it's the
cheapest correctness you will ever buy.

## The props are just... parts

```lua
b.CustomPhysicalProperties = PhysicalProperties.new(BOX_DENSITY, 0.6, 0.15, 1, 1)
b.Parent = props
CollectionService:AddTag(b, "Prop")
```

That's it. No networking code. **No RemoteEvents** — *"the box moved"* is not a message,
it's physics. The server simulates them, they replicate, and clients near them predict
them automatically. This is the part of Server Authority that just works, and it's worth
sitting with for a second: the interaction you'd normally write a whole netcode layer
for is *nothing at all*.

The tag is for the presentation layer (chapter 7) to find them later.

## The number that makes it funny

```lua
local BOX_DENSITY = 0.008
```

CakeMan's base layer is density **8**. So he outweighs a box about a thousand to one per
unit volume. He doesn't push these boxes. **He detonates them.** One charge into a pile
scattered 14 boxes and launched one **16.9 studs** across the room.

Set it to 1.0 and he's shoving crates around a warehouse, which is a different and much
worse game. The single most valuable knob in the level is the one that decides how
pathetic the obstacles are.

## The lighter the prop, the more carefully it must be placed

Here's the bug that fell out of that density, and it's a good one.

Boxes were quietly *disappearing*. The server built 126 and, seconds later, had 121 —
before anyone had touched them.

They weren't being streamed out (my first, wrong, theory). They were being **destroyed**.
A loose box that spawned overlapping a pile or a wall got separated by the solver, and
an impulse that would merely *nudge* a crate **launches** a box this light. They were
sailing clean over the 20-stud walls, out of the arena, and falling until
`FallenPartsDestroyHeight` ate them. Five boxes a match, gone before the match started.

The fix is placement, not physics:

- stack boxes on a **pitch slightly wider than they are** (3.15 for a 3-stud box), so
  neighbours never quite touch;
- **rejection-sample** loose boxes clear of the piles and walls.

## Seed your layout

```lua
local rng = Random.new(20260713)
```

**Never seed from the clock.** Every server must build a byte-identical arena, or two
servers disagree about where the world is and a rejoining player arrives in a different
level to everyone else.

And build the level **in code, not in the place file**. Place geometry is invisible to
source control; a script that rebuilds it can be diffed, reviewed and reverted. Mine
even deletes the default baseplate, so there's exactly one source of truth about where
the ground is.

---

**Next:** [Chapter 6 — prediction](06-prediction.md). The chapter where I was wrong twice.
