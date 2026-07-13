# 11. Feel: the knobs, in the order you should turn them

Everything works now. This chapter is about the difference between *works* and *good*,
which is most of the job.

## Tune in this order

One knob at a time, hands on the keyboard.

**Locomotion first — he has to feel like a body before he can feel like a fighter.**

1. **`TARGET_SPEED`** — pick the cruise. Everything else scales around it.
2. **`ACCEL_GAIN`** — snappiness. Too high reads as robotic, too low as mud.
3. **`FRICTION_FF`** — the launch shove. Raise it until starts feel eager. Remember it
   has to beat `µ × gravity` before he moves *at all*.
4. **`TURN_RATE` + the `AlignOrientation`'s `Responsiveness`** — these two are a pair.
   A fast turn rate behind a slow servo is just a slow turn rate.
5. **`COAST_DRAG`** — let go and he should *glide* to rest, not brake.
6. **The joints** — `MaxFrictionTorque` for doughiness, cone angles for the pose,
   densities for what wobbles.
7. **`SMOOTH_TIME`** in the presentation layer — as low as the latency allows.

**Then the fight.**

8. **`ARM_DELAY`** — the commit window. This is a *design* knob wearing a number's
   clothing: it decides whether grabbing is a decision or a reflex.
9. **`FIST_DAMAGE` / `BOX_DAMAGE`** — how long a fight lasts.
10. **`REGEN_RATE`** — **and it is not independent of 9.** See below; getting this wrong
    silently un-does 9 entirely.
11. **`DOWNED_TIME`** — how much a knockout is *worth* to the person who landed it.
12. **`GRIP_BREAK` / `Grip.MaxForce`** — how hard it is to hold a man who doesn't want
    to be held.

## Principles that survived contact

**Tune in acceleration units, multiply by mass at the last moment.** Then your knobs
keep their meaning when the rig changes. I changed the layer densities four times and
never retuned the locomotion.

**Prefer accelerations to snaps.** Ramps hide corrections and ramps feel good; these two
goals point the same direction, which is a gift — take it.

**Cap with a taper, not a wall.** And cap *somewhere*, because overspeed breaks
everything downstream.

**Couple knobs deliberately.** Fewer knobs, coherent feel.

**Blend, don't branch.** Thresholds pop; weights don't. This is worth a section.

## "Blend, don't branch" — a war story

In an earlier version, CakeMan was a **biped** with legs and a gait. His legs had a
horrible high-frequency jitter, and the cause was two boolean tests:

- the leg hard-switched between `planted` and `swinging` at the duty boundary;
- its ground-contact test was a yes/no raycast, so a foot hovering near the threshold
  **flickered in and out every single frame**, slamming its forces on and off with it.

I replaced both with continuous weights — stance eased in and out over the cycle,
contact faded in over distance — and the shake dropped by a factor of four. Measured:
peak angular velocity on the shin went from **55 rad/s to 13**.

A boolean in a physics loop is a jitter machine. If two rules meet, weight them.

## Things that look like power problems and aren't

Two from the biped era, both of which cost me hours, both of which generalise:

**"More thrust made him slower."** His legs were *tethering*: the plant distance
(stride × duty) had crept past how far a planted leg could physically sweep back, so
every step the leg went taut and dragged him like an anchor. Adding power just pulled
harder against his own leg. Shortening the stride gave a 40% speed increase at *the same
thrust*.

**"His feet won't leave the ground."** Doubling the lift force barely moved them. The
knee is what lifts a foot, and leg length is `2 × segment × cos(bend/2)` — so a 50° knee
fold shortens a 2.6-stud leg by all of 0.24 studs. **Clearance is a geometry budget, not
a force budget.** No amount of force beats trigonometry.

The general lesson: when a physical system refuses to respond to more force, **stop
adding force**. Something is constraining it, and the constraint is usually geometric.

And its exact sibling from the combat era — **when a number refuses to respond to being
changed, stop changing it.** Punches felt like being hit by a truck, so I cut every
damage constant by a factor of five. It changed almost nothing, because one swing was
landing four or five times (Chapter 8) and I was tuning the wrong term entirely. A 5×
cut that behaves like a 1.2× cut is not a tuning problem, it's a **modelling** problem,
and the correct response is to stop reaching for the knob and go and read the code.

## Knobs are not independent, and the pairs will get you

Three pairs in this project where turning one knob silently changed what another one
meant:

**`TURN_RATE` and `Responsiveness`.** A fast turn rate behind a slow actuator is just a
slow turn rate. The servo becomes the speed limit and the knob you're turning does
nothing.

**`FIST_DAMAGE` and `REGEN_RATE`.** Regen is a *race* against incoming damage, so it's
not an absolute quantity — it's a ratio. Cutting damage 5× while leaving regen at 6 hp/s
would have quietly meant "no damage at all": a softened punch is erased in about a
second, nobody can ever be worn down, and the only thing left that works is the instant
knockout. I scaled regen by the same fifth, and the *ratio* is exactly what it was —
fights simply take five times longer, which was the actual goal.

**`GRIP_BREAK` and your grab radius.** `GRIP_BREAK` must be comfortably larger than the
radius you search for targets in, or every grab is born already broken (Chapter 9). Mine
wasn't, and it looked exactly like a weak grip.

The habit worth building: **when you change a number, ask what other number was sized
against it.** Most "this knob doesn't work" bugs are really "this knob's partner is now
lying".

## Balance changes don't create bugs, they stop hiding them

The single most useful thing I learned in the tuning pass, and it's a debugging lesson
rather than a design one.

When I cut damage and dropped regen, a "new" bug appeared instantly: you'd climb out of
a death pit still knocked out, on 4 hp, and spend your whole next life crawling. Except
it wasn't new. Respawn had **never** restored health or the knockout state (Chapter 10).
Fast regen had been quietly refilling the health it failed to reset, and a 2-second
knockout usually expired somewhere on the way down the pit. The game had been papering
over its own broken respawn continuously, for weeks.

> Generous numbers hide broken logic. The day you tighten them, everything that was
> being carried by the slack falls on the floor at once.

So when a balance change surfaces a new bug: **suspect it was always there.** You didn't
break it. You stopped subsidising it.

## The player is the final instrument

Traces prove mechanics. Only hands prove feel. Every number in this series came out of a
trace — and every one of the *decisions* came from Peter driving the thing and saying
"no, that's not it".

The most valuable thing I built in this whole project was not the character. It was the
**F6 debug view** and the habit of dumping traces at 1–2 Hz and reading the numbers.
Tuning a physics character blind, by print statement, is a way to lose a week. Budget a
tenth of your mechanic time for its visualisation and you get it back the same week.

---

**Next:** [Chapter 12 — going further](12-going-further.md).
