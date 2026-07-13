# 8. Feel: the knobs, in the order you should turn them

Everything works now. This chapter is about the difference between *works* and *good*,
which is most of the job.

## Tune in this order

One knob at a time, hands on the keyboard.

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

## The player is the final instrument

Traces prove mechanics. Only hands prove feel. Every number in this series came out of a
trace — and every one of the *decisions* came from Peter driving the thing and saying
"no, that's not it".

The most valuable thing I built in this whole project was not the character. It was the
**F6 debug view** and the habit of dumping traces at 1–2 Hz and reading the numbers.
Tuning a physics character blind, by print statement, is a way to lose a week. Budget a
tenth of your mechanic time for its visualisation and you get it back the same week.

---

**Next:** [Chapter 9 — going further](09-going-further.md).
