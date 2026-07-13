# 10. The knockout, and what a respawn silently keeps

There is no ragdoll system in this game.

I want to be precise about that, because "ragdoll" is usually a *feature* — a second
skeleton, a physics avatar, a state machine that swaps one for the other and prays the
transition doesn't explode. Here it's four lines, and they don't add anything. They
**take things away**.

## Ragdoll by subtraction

CakeMan is already a ragdoll. He's a stack of loose ball sockets that is permanently
falling over, and the only reasons he's standing are:

1. `Heading` — an `AlignOrientation` on the base, holding him upright and pointed;
2. `MaxFrictionTorque` on every joint — the doughiness that makes him hold his shape.

So the knockout is: **stop doing those.**

```lua
-- CakeSim.luau -- in the sim, because every peer must see him go limp at the same time
if downed then
	heading.Enabled = false                    -- stop standing him up
	for _, j in man:GetDescendants() do
		if j:IsA("BallSocketConstraint") then
			j.MaxFrictionTorque = 0            -- stop holding his shape
			j.UpperAngle = 75                  -- and let him fold
		end
	end
end
```

That's it. He collapses in a heap, arms everywhere, cherry rolling around on a loose
neck. It is *by far* the best-looking thing in the game and it took about ten minutes,
because the rig was already doing all the work — the standing was the special case, and
the knockout is just the absence of it.

This is the payoff for the thesis in Chapter 0. **If your character is genuinely
physical, "unconscious" is not a feature you build. It's a feature you stop
suppressing.**

To get back up, you put the numbers back — which is why Chapter 2 stashed them on the
joints themselves at build time:

```lua
j:SetAttribute("RestAngle", angle)
j:SetAttribute("RestFriction", friction)
```

A joint that knows its own resting values can always be restored from any state, by
anyone, without a table of magic numbers living somewhere else. It's a small thing and
it makes the whole system idempotent.

## Consequences are authoritative, but the *limp* is predicted

Worth being careful here, because it looks like a contradiction with Chapter 8.

- **Deciding you're knocked out** is the server's job. It owns damage, and `Downed` is
  an attribute only it writes.
- **Going limp** happens in the simulation, on every peer, driven by reading that
  attribute.

That split is the whole state contract doing its job. The server says *what is true*;
the simulation, running identically everywhere, turns that truth into forces. Nobody
replicates a ragdoll pose across the network. Every machine independently stops holding
him up, and physics does the rest — and because it's a rolled-back attribute, a
mispredicted knockout un-knocks-out cleanly, with no special handling at all.

## The countdown that isn't a timestamp

```lua
root:SetAttribute("DownedFor", DOWNED_TIME)  -- and every step: DownedFor -= dt
```

Not `wakeAt = now + 5`. There is no clock in the simulation (Chapter 3), and even on
the server, a countdown that ticks down by `dt` is a value that can be *read* by a
predicted system without either machine having to agree what time it is. Count down.
Never compare a timestamp against "now".

## Five seconds, because two was barely a stumble

`DOWNED_TIME` was 2. It felt fine and it was pointless: you were back on your feet
before anyone could do anything *about* you, so landing a knockout won you nothing, and
being knocked out cost you nothing.

At **5 seconds**, a limp cake becomes **cargo**. There's time for someone to walk over,
put their guard up, grab you by whatever bit of you is nearest, drag you across a
bridge and drop you in a pit.

> The knockout was never the punishment. It's the *setup* for the punishment.

That's the sentence that turned a damage system into a game. Being knocked out isn't
the failure state — being knocked out **next to a pit, near someone with hands** is.
And it means a player who is losing a fight has something to do about it other than
die: back away from the edge.

The cherry shot (Chapter 8) is what makes this actually happen, because it's *instant*.
No health bar to whittle down, no telegraph: one connection and you are five seconds of
inert cake in a room full of people who want you in a hole.

## What a respawn silently keeps

Fall in a pit and you come back. We **teleport** the existing man rather than destroying
and rebuilding him — a respawn that swaps the model out invalidates every reference the
client is holding (its presentation copies, its prediction, its camera subject) and
gives you a visible hitch for nothing.

But moving him was only ever the *visible* half of a respawn. Here's the bug I shipped:

You climb out of the pit **still knocked out**. Still on 4 hp. Stand-up servo still
switched off. A knockout countdown still running against you. Because `respawn()` moved
his coordinates and zeroed his velocity, and that was all — and *the two states you tend
to fall into a pit in are "nearly dead" and "unconscious"*.

```lua
local function respawn(man: Model, index: number)
	man:PivotTo(CFrame.new(point))
	-- ...zero every velocity...

	local root = man.PrimaryPart :: BasePart
	root:SetAttribute("Health", MAX_HEALTH)
	root:SetAttribute("Downed", false)   -- back on your feet: the servo comes back
	root:SetAttribute("DownedFor", 0)    -- no leftover countdown ticking against you
	root:SetAttribute("GuardTime", 0)    -- you don't arrive mid-commit to a grab you
	                                     -- began while falling to your death

	-- And let go of whatever you were carrying.
	for _, side in { "L", "R" } do
		local grip = ...
		if grip then grip.Enabled = false end
	end
end
```

That last one matters more than it looks: the grip is a **spring** between your fist and
a box. Teleport the fist across the arena and that spring is suddenly stretched the
width of the map — it either drags the crate after you or snaps with a bang. CakeGrab's
tension rule (Chapter 9) would break it a frame later anyway, but a frame of a box being
hauled across the level at 55,000 studs of force is one frame too many.

> **Anything a respawn doesn't explicitly clear, it silently keeps.**

## The bug was always there

Here's the part I actually want you to take away, and it's about *when* this surfaced.

This bug shipped weeks before anyone saw it, because the numbers were forgiving. Regen
was 6 hp/sec, which quietly refilled the health a respawn had failed to restore. The
knockout was 2 seconds, which usually expired somewhere on the way down the pit. The
game was papering over its own broken respawn, continuously, and I had no idea.

Then I cut damage to a fifth and — because regen has to scale with damage or "5× less
damage" quietly means "no damage" — dropped regen to 1.2. And the bug came out of the
woodwork instantly: now you *stayed* on 4 hp, and a 5-second knockout *didn't* expire on
the way down, and suddenly you were spending an entire life crawling.

The tuning change didn't cause the bug. **It stopped concealing it.**

> When a balance change surfaces a "new" bug, suspect it was always there. Generous
> numbers hide broken logic, and the day you tighten them, everything that was being
> carried by the slack falls on the floor at once.

## The UI has to write its way back out

A small one, and a good habit.

The health bar wrote `OUT COLD` when you went down. It never wrote anything else. So you
got up, walked off, and carried on brawling with a sign over your head insisting you
were unconscious — for the rest of the round.

```lua
if downed then
	bar.label.Text = string.format("OUT COLD (%.1f)", left)
	bar.label.TextColor3 = OUT
else
	bar.label.Text = bar.name       -- what it says when he's on his feet
	bar.label.TextColor3 = bar.color
end
```

The label had no *resting state* to return to, so I gave it one — captured at build
time. **Any UI that writes a state must also write its way back out of it**, and the
cheapest way to guarantee that is to make every state a total function of the current
truth, rather than a thing you *set* when an event happens.

Verified over a full cycle: `YOU` → `OUT COLD (4.7 … 0.1)` → `YOU`.

## The numbers

| | | |
|---|---|---|
| `DOWNED_TIME` | 5 | long enough to become cargo |
| `WAKE_HEALTH` | 35 | you come back with a boost, not on 1 hp |
| `REGEN_RATE` | 1.2 | ...and climb back slowly. **Scaled with damage, on purpose.** |
| `KILL_Y` | −40 | past this you're out of the world |
| joints when downed | friction 0, cone 75° | restored from `RestFriction` / `RestAngle` |

---

**Next:** [Chapter 11 — feel](11-feel.md). The knobs, in the order you should turn them.
