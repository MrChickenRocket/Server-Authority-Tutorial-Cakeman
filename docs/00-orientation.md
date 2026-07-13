# 0. A cake that can throw hands

Hi, I'm Peter "@MrChickenRocket" McNeill. I've been building games, engines and
renderers for about 25 years, and lately I've been building physics characters on
Roblox's **Server Authority**.

This series builds one from an empty baseplate: **CakeMan** — a four-layer cake on
loose ball sockets, with a little box head and two noodly arms with heavy fists.
He glides around an arena knocking over piles of cardboard boxes. He is entirely
physics. Nothing about him is animated.

By the end you'll have a character that is:

- **server-authoritative** — the server owns the truth, and the client predicts it,
- **entirely physical** — no Humanoid, no animation-driven movement,
- **smooth** — because the thing you *see* isn't the thing the physics is doing,
- and **fun to shove things with**, which is the actual point.

## The thesis: the ragdoll IS the character

There's a tempting way to build a character like this, and it's wrong: simulate a
tidy invisible capsule, then hang a wobbly-looking puppet off it for show. You get
a character that *looks* physical and *isn't*. It can't be knocked over, its arms
can't catch on anything, and every interesting collision has to be faked.

We're doing the opposite. The parts you see are the parts the physics engine is
wrestling with. When CakeMan ploughs into a stack of boxes, nothing decides what
should happen — it just happens, and the result is usually funnier than anything
I'd have designed.

The price is that you have to actually understand your rig, and you have to build
your character's brain to survive a network model that re-runs it several times a
frame. That's what the rest of this series is.

## What Server Authority changes

Under `Workspace.AuthorityMode = Server`, the server simulates the truth and your
client *predicts* it: it runs the same simulation locally, guesses ahead, and when
the server disagrees, the client **rolls back and re-simulates**. That's what makes
the game responsive and cheat-resistant at the same time.

It also means three things you have to internalise, and everything in this series
falls out of them:

1. **Your character's brain runs on both machines**, and it must produce the same
   result from the same inputs. It gets re-run during reconciliation, so it can't
   create instances, read the clock, or roll dice.
2. **The truth will snap.** Corrections are not a bug, they're the design. You
   don't smooth them away in the simulation — you hide them behind a visual layer.
3. **You get nothing for free.** No Humanoid means no camera, no controls, no
   character. Roblox does not even give you the default camera module. (I found
   that out the interesting way. Chapter 4.)

## A word about the bugs

I'm leaving the failures in. Not out of humility — because they're the useful part.
This series contains, among others:

- a rig where every joint's bend limit was silently the *twist* limit, which is
  invisible until you turn the gizmos on and ruins ragdolls everywhere;
- a character who got *slower* when I gave him more thrust;
- a prediction system I built, carefully, that made things worse than doing
  nothing at all;
- and about twenty minutes where I was convinced my character had failed to spawn
  and I was actually just staring at an abandoned camera.

Every number quoted in this series came out of a trace in the running place. Where
something is still unproven, I say so.

Let's build a cake.
