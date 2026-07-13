# 12. Going further

## What's still owed

I want to be honest about what this series has and hasn't proven.

**Everything here was verified in single-process Play.** The rig, the driving, the
prediction, the presentation layer — all measured in the running place, all real. But
the **Server & Clients latency pass is still outstanding**: reconcile quality under real
lag, how a *remote* CakeMan reads to another player, how player-vs-player collisions
mispredict. Single-process play looks falsely jittery under Server Authority and can't
show you any of that.

So: the architecture is server-authoritative and provably free of the usual
anti-patterns, but the *feel* under latency is not yet proven. If you take one thing
from this series, don't let it be a false sense of completeness.

## The character that isn't in this tutorial

CakeMan started life as a **biped** — hips, two legs, knees, feet, a gait clock, a
balance controller, the lot. I built it, tuned it for a long time, and then Peter said
*"not feeling it for a tutorial, too complex"*, and we tore it out and replaced it with
a stack of cake on ball sockets.

That was the right call. The cake is a better character *and* a better teacher. But the
legs taught things that survived the deletion, and if you want to build one, here's
what I'd tell you:

**Support is a force couple, not a hover.** A hover spring under the hips makes a
hovercraft wearing legs as jewellery. The honest version: push **up at the hip** and an
equal amount **down at the planted foot**. Net zero — the ground's reaction up the leg
is what actually carries the body. No planted foot means real gravity, immediately.

**The legs can't level the body.** Hip ball sockets transmit no torque, so support
applied at the centre of mass can never right a torso. Apply each leg's support **at
that leg's hip attachment** (off-centre) and unequal support between the legs *becomes*
a righting torque. That single change is what let the plate stay level.

**The rock is the weight shift.** To lift a leg you must first get your weight off it,
which means leaning over the other one. Command that lean — don't wait for it to emerge.
And here's the counterintuitive part: I'd made the posture servo *sluggish* to feel
weighty, and that was killing the rock. A slow servo can't track a 1.3 Hz sway, so a
commanded 22° came out as 6°. **Weight comes from the slow turn rate and low
acceleration gain; the posture servo needs to be quick.**

**Any force you put on a limb shows up on the body.** The swing leg's forward reach
reacts back through the hip — the legs were literally *paddling him along*, straight
through the velocity servo's cap. He cruised at 8.3 against a cap of 5.5. A cap that
only governs torso thrust is a lie.

**Grip, speed and shake are the same knob.** Gripping feet make him calm but slow;
thrust to overcome the grip is exactly what rattles the legs. There's no setting where
you get all three. Choose.

## Two predictions I made, and how they turned out

An earlier draft of this chapter listed things that would "graft straight onto" the rig.
Two of them have since been built, and both taught me something by being *wrong about
the mechanism*, so I'm leaving my bad predictions in.

**I said: "Grabbing. Constraints created in the simulation on a Bool input. (Careful:
that's instance creation, so it needs the predicted-spawn pattern.)"**

Wrong, and interestingly so. The shipped grab (Chapter 9) creates **nothing**. `Reach`
and `Grip` are pre-built into the rig and sit there `Enabled = false` until the sim
flips them on. Once you accept that the simulation may not create instances, the
conclusion isn't "so I need a fancy predicted-spawn pattern" — it's **"so I'll build
everything up front and let the sim throw switches."** The advanced technique I was
bracing for turned out to be a design smell warning me off.

And the real lesson was somewhere I wasn't looking at all: **an attribute cannot hold an
Instance reference.** So *"my hands are up"* is predictable and *"I am holding **that**
box"* is not — not because of a limitation, but because it is genuinely a fact about the
world, and facts about the world belong to the server. That split is the best thing in
the project and I'd have found it a week earlier if I'd asked "what state does this
need?" instead of "what instances does this need?".

**I said: "More players. Two cakes in an arena full of cardboard is, I suspect, the
actual game."**

That one was right, and it undersold it. It's the whole game (Chapters 8–10), and the
thing I didn't anticipate is that **the arena mattered more than the combat.** Damage
numbers took an afternoon; what turned it into a game was putting a *hole* in the middle
of the level and making a knocked-out player *carryable*. The knockout stopped being a
punishment and became a setup.

## Where to take it next

- **A skinned mesh.** The presentation layer already decouples the visuals from the
  physics — the smoothed copy becomes a bone-backdrive source instead of the visible
  thing, and nothing about the simulation changes.
- **Team rules and a scoreboard.** Everything needed is already an attribute.
- **Throwing.** You can carry a man; you cannot yet *launch* one. All that's missing is
  releasing the grip with an impulse — and the `HeldBy` grace period (Chapter 9) already
  exists to stop you killing yourself with your own throw.
- **Custom-gravity adhesion**, if you want him climbing walls. Cancel world gravity per
  part and re-apply it toward the surface normal. It collapses to normal locomotion on
  flat ground, which is why it's debuggable at all.

## The short version

If you remember seven things:

1. **The ragdoll IS the character.** Don't fake it with a capsule. Everything else in
   this list is a dividend of that one decision — the knockout is four lines that *stop
   holding him up*, and the telegraph is just where his hands actually are.
2. **The brain runs on both machines**, and it re-runs during reconciliation (105 replayed
   steps against 91 live, in a quiet test). No clocks, no dice, no instances. `dt` is the
   only thing that replays identically.
3. **Set `ReplicationFocus` and `player.Character`**, then stop helping. The prediction
   system I hand-built to improve on that made everything worse.
4. **Never smooth the physics.** Smooth a copy of it, and set `CanQuery = false` on that
   copy or you'll break the very thing you were flattering.
5. **Attributes can't hold instances**, so *intent* is predictable and *consequences*
   aren't. That isn't a limitation to route around. It's the architecture telling you
   where the line goes.
6. **A number that has to be enormous is often pushing against nothing.** 26,000 studs of
   force to lift an arm, reacted by the sky. Anchor it to the body and it's 4,000 — and
   faster.
7. **When more force doesn't help, stop adding force. When a tuning change doesn't help,
   stop tuning.** Both are the same instinct: the model is wrong, not the magnitude. Go
   and look at the geometry, or go and read the code.

And one that isn't a technique, but is the actual moral of the series: **almost every bug
in this project presented as a tuning problem.** The floaty hands looked like a weak
force. The five-times punch looked like a big damage number. A constraint with a nil
attachment — silent, zero force, forever — looks *precisely* like a servo that needs
turning up.

The tell is always the same. You reach for the knob, you turn it a long way, and the
game doesn't change as much as the arithmetic says it should. **That is the moment to
stop and go and look at what you're actually pushing against.**

Now go and knock something over.
