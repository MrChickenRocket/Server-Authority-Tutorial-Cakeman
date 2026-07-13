# 9. Going further

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

## Where to take the cake

The rig here is a trunk, not a destination. Things that graft straight onto it:

- **A skinned mesh.** The presentation layer already decouples the visuals from the
  physics — the smoothed copy becomes a bone-backdrive source instead of the visible
  thing, and nothing about the simulation changes.
- **Grabbing.** Constraints created in the simulation on a Bool input. (Careful: that's
  instance creation, so it needs the predicted-spawn pattern, not a naive `Instance.new`
  in the sim.)
- **More players.** The architecture is already per-player. Two cakes in an arena full
  of cardboard is, I suspect, the actual game.
- **Custom-gravity adhesion**, if you want him climbing walls. Cancel world gravity per
  part and re-apply it toward the surface normal. It collapses to normal locomotion on
  flat ground, which is why it's debuggable at all.

## The short version

If you remember five things:

1. **The ragdoll IS the character.** Don't fake it with a capsule.
2. **The brain runs on both machines**, and it re-runs during reconciliation. No clocks,
   no dice, no instances.
3. **Set `ReplicationFocus` and `player.Character`**, then stop helping.
4. **Never smooth the physics.** Smooth a copy of it, and set `CanQuery = false` on that
   copy or you'll break the very thing you were flattering.
5. **When more force doesn't help, stop adding force.** Go and look at the geometry.

Now go and knock something over.
