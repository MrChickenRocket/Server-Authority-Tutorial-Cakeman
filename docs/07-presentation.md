# 7. The presentation layer

The most important idea in the whole project, and it fits in one sentence:

> **The physics is the truth. It is allowed to be ugly. Don't show it to anyone.**

## Why the truth has to be ugly

Under Server Authority your client is constantly running ahead of the server, guessing.
When the server disagrees, the client rolls back and re-simulates, and the result is
that **the truth snaps**. Corrections are not a bug. They're the design.

You cannot smooth that away in the simulation, because the simulation has to stay
*correct*. Smooth the physics and you have simply made your character wrong — it now
disagrees with the server on purpose, which is the one thing it must never do.

So don't touch it. Hide it, and show the player **a copy** that lags a few milliseconds
behind and eases toward it. Corrections land on the truth; the copy glides through them.
The player never sees the snap. The physics stays honest.

## What gets presented? Whatever is tagged.

```lua
CollectionService:GetInstanceAddedSignal("Presented"):Connect(adopt)
```

That's the whole subscription. `Presentation.luau` knows nothing about CakeMen, cakes,
boxes or arenas — **it knows about a tag.** The server decides what deserves presenting;
adding a new smoothed thing later never touches the presentation layer again.

It's worth being deliberate about *two* tags rather than one, because they mean
different things and conflating them is how you end up with a tag called `Prop` that
secretly also means "smooth me" and "predict me" and "score me":

| Tag | Means |
|---|---|
| `Prop` | what it **is** — gameplay |
| `Presented` | what should be **done** to it — rendering |

And the rule for what to tag: **things the physics moves.** The walls are not tagged.
They never move, so there is nothing to smooth, and you'd be paying to lerp a wall
toward itself sixty times a second, forever.

### The recursion that eats your framerate

The instant I moved to tags, this appeared:

```
tagged Presented: 1459 | visual copies: 1322
```

**A clone inherits the tags of the thing it copied.** So each visual copy arrived
already tagged `Presented`, the layer faithfully presented *it*, that copy arrived
tagged too, and away it went. It had also inherited `Prop`, which quietly doubled the
prop count and poisoned every system that counts props — including the prediction debug
view from the last chapter.

Strip every tag off the clone, first thing:

```lua
for _, tag in CollectionService:GetTags(copy) do
	CollectionService:RemoveTag(copy, tag)
end
```

A visual copy is a picture. **It participates in nothing.**

## The pipeline

**Copy A** — the authoritative parts. Replicated, simulated, and locally invisible:

```lua
truth.LocalTransparencyModifier = 1
```

`LocalTransparencyModifier` is a **client-only** property. The server's copy is
untouched; nobody else's view changes. This is exactly the tool for "I want to hide
something from myself only".

**Copy B** — a client-only, anchored clone with every constraint stripped out. It is a
*picture*, not a participant. It is never simulated; we set its CFrame every frame.

```lua
local copy = truth:Clone()
for _, d in copy:GetDescendants() do
	if d:IsA("Constraint") or d:IsA("Attachment") or d:IsA("Script") then d:Destroy() end
end
copy.Anchored = true
copy.CanCollide = false
copy.CanQuery = false   -- read the next section. Twice.
copy.CanTouch = false
copy.Massless = true
```

And then, every `RenderStepped`:

```lua
local target = truth.Position + truth.AssemblyLinearVelocity * LEAD
f.pos, f.vel = smoothDamp(f.pos, target, f.vel, SMOOTH_TIME, dt)
copy.CFrame = CFrame.new(f.pos) * copy.CFrame.Rotation:Lerp(truth.CFrame.Rotation, rotAlpha)
```

Three details that are load-bearing:

- **The velocity lead.** Aim at where the truth is *going*, not where it *is*. Without
  it, smoothing leaves every moving object trailing behind itself on a rubber band.
- **A snap distance.** If the truth teleports — a respawn, a huge correction — don't
  sail gracefully across the map. Give up and snap. Smoothing a teleport looks like a
  bug, because it is one.
- **Clamp `dt`.** One hitched frame must not fling the copy into the next postcode.

## The footgun that will get everybody

This is a Server Authority footgun specifically, and it is *silent*:

> **Client-only parts default to `CanQuery = true`.**

Your anchored visual copy is therefore visible to **your own raycasts** — on the client
only. That's geometry the server does not have. Your client is now simulating a world
the server disagrees with, which is the literal definition of a misprediction.

**The visual layer would silently break the physics it exists to flatter.** Every clone
gets `CanQuery = false` and `CanTouch = false`.

At scale, prefer a **collision-group policy**: put all client visuals in a
`ClientVisuals` group and mask it out of the group your simulation queries against. One
central rule beats a flag you have to remember on every new visual you ever add — and
you *will* forget one.

## Point the camera at the copy

```lua
local follow = Presentation.GetSmoothed(base) or base
```

The truth is the thing that snaps. Point a camera at it and every correction becomes a
flick of the *entire screen*, which is far more sickening than a character twitching.
Follow the copy.

## Shift+0

Overlay the raw physics in red, semi-transparent, straight over the polished copy. You
will use this constantly. It is the fastest way to convince yourself — or a sceptic —
that the smoothing is doing anything at all: the red truth jitters and snaps, and the
cake glides serenely through it.

## It isn't character-specific

The same pipeline runs on the cardboard boxes. Nothing in `Presentation.luau` knows what
a CakeMan is. **Anything the physics moves can be presented this way**, and the moment
you have this layer, the temptation to "just smooth the physics a bit" disappears
forever, which is the real prize.

---

**Next:** [Chapter 8 — feel](08-feel.md). The knobs, in the order you should turn them.
