# 0. A cake that can throw hands

Hi, I'm Peter "@MrChickenRocket" McNeill. I've been building games, engines and
renderers for about 25 years, and lately I've been building physics characters on
Roblox's **Server Authority**.

This series builds one from an empty baseplate: **CakeMan** — a four-layer cake on
loose ball sockets, with a glacé cherry for a head and two noodly arms ending in
heavy fists. He is entirely physics. Nothing about him is animated.

And then it makes him fight. The finished thing is a four-corner brawler: you
lumber across bridges over a pit, punch people with arms you do not really control,
put your guard up and wrestle a knocked-out opponent to the edge, and drop him in.
A clean hit on someone's cherry ends them on the spot, which is the funniest
possible thing to lose to.

By the end you'll have a character that is:

- **server-authoritative** — the server owns the truth, and the client predicts it,
- **entirely physical** — no Humanoid, no animation-driven movement, no capsule,
- **smooth** — because the thing you *see* isn't the thing the physics is doing,
- and **able to punch, grab, carry, knock out and be knocked out**, all of it
  falling out of the rig rather than being scripted on top of it.

## The thesis: the ragdoll IS the character

There's a tempting way to build a character like this, and it's wrong: simulate a
tidy invisible capsule, then hang a wobbly-looking puppet off it for show. You get
a character that *looks* physical and *isn't*. It can't be knocked over, its arms
can't catch on anything, and every interesting collision has to be faked.

We're doing the opposite. The parts you see are the parts the physics engine is
wrestling with. When CakeMan ploughs into a stack of boxes, nothing decides what
should happen — it just happens, and the result is usually funnier than anything
I'd have designed.

You get paid for that decision late, and all at once. Nearly every mechanic in the
back half of this series is *already in the rig* by the time I come to write it:

- **The knockout** isn't a ragdoll system. It's four lines that stop holding him up.
- **Grip strength** isn't a stat. It's a spring that isn't strong enough, and a rule
  about when to admit it.
- **Telegraphing** isn't an animation. His hands are genuinely out in front of him,
  and you can see them coming because they're really there.

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
   create instances, read the clock, or roll dice. (And it is re-run *constantly*.
   In a single-process Studio Play, with no added latency, I logged **105
   resimulated steps against 91 live ones**. Resimulation is the common case, not
   the exception.)
2. **The truth will snap.** Corrections are not a bug, they're the design. You
   don't smooth them away in the simulation — you hide them behind a visual layer.
3. **You get nothing for free.** No Humanoid means no camera, no controls, no
   character. Roblox does not even give you the default camera module. (I found
   that out the interesting way. Chapter 4.)

And one more that only shows up once you start building *consequences*: the
simulation can predict where your fists are, but it cannot predict **what you
caught**. Attributes are the things that roll back, and an attribute cannot hold a
reference to an instance. So "my hands are up" is predicted and instant, and "I am
holding *that* box" is a fact the server tells you. That split runs through the
whole back half of this series, and it's Chapter 9.

## A word about the bugs

I'm leaving the failures in. Not out of humility — because they're the useful part.
Some of the ones you're about to watch me walk into:

- a rig where every joint's bend limit was silently the *twist* limit, which is
  invisible until you turn the gizmos on and ruins ragdolls everywhere;
- a character who got *slower* when I gave him more thrust;
- a prediction system I built, carefully, that made things worse than doing
  nothing at all;
- **hands that pulled against nothing**, hauled toward a point in the world by
  26,000 studs of force reacted by the sky, which felt floaty for a reason no
  player could ever have named;
- **a box that knocked me out for punching it**, because I measured the impact with
  a number that cannot tell "I hit it" from "it hit me";
- **a punch that landed five times**, because a cake is five slabs and I was
  billing the victim once per slab;
- and about twenty minutes where I was convinced my character had failed to spawn
  and I was actually just staring at an abandoned camera.

There's a family resemblance in that list, and it's worth naming up front, because
it will save you more time than any technique in this series: **most of these
presented as tuning problems.** The floaty hands looked like a force that needed to
be bigger. The five-times punch looked like a damage number that needed to be
smaller. A constraint with a nil attachment — which does not error, does not warn,
and applies exactly zero force forever — looks *precisely* like a servo that's too
weak.

When the fix is a number, the bug is usually a number. When you find yourself
reaching for a *much* bigger number, stop and check what you're actually pushing
against.

Every number quoted in this series came out of a trace in the running place. Where
something is still unproven, I say so.

Let's build a cake.
