# 9. The grab: the wrestler's guard

Hold the left mouse button and CakeMan puts his **hands up** — both fists hauled out
in front of him, apart, level, ready. He holds them there. And a full second later,
they go live, and they grab the first thing they touch.

That second is the entire mechanic.

## Commit, don't vacuum

The first version of this was a magnet: press the button, and the nearest grabbable
thing within some radius got yanked to your hand. It worked perfectly and it was
horrible. Grabbing was a *lookup*, not a decision. You held the button down and the
world came to you.

The rework is one sentence: **you put your guard up, and then you have to walk your
opponent into your hands.**

Everything good about the mechanic falls out of that:

- **It's a decision.** You commit before you know whether it'll land.
- **It's telegraphed.** Your intent is written on your body — those hands are genuinely
  out in front of you, in the physics, and everyone can see them coming.
- **It's counterable.** Someone with their guard up is someone who is not punching you
  and cannot turn quickly. Walk around him.

The pose is not decoration. It's the tell, the wind-up and the hitbox all at once,
and it's free, because it's just where his hands are.

## Armed is a clock, not an arrival

The obvious way to decide when the hands go live is to check whether they've *got*
there. Don't.

His arms are five ball sockets of wet spaghetti. They arrive when they feel like it.
A fist that happens to swing into position early would arm early; one that snags on a
box would never arm at all. The player would experience a grab that fires at a
different moment every time, for reasons completely invisible to them.

```lua
local ARM_DELAY = 1.0

-- How long the guard has been up. Accumulated by dt into a rolled-back attribute --
-- which is the only kind of clock the simulation is allowed to have (Chapter 3).
local held = (base:GetAttribute("GuardTime") :: number?) or 0
held = if reaching then held + dt else 0
base:SetAttribute("GuardTime", held)

-- ARMED IS PURELY THE CLOCK. One second, every time, whatever the arms are doing.
base:SetAttribute("Armed" .. side, guarding and held >= ARM_DELAY)
```

**Predictable beats physical.** The physics can be as chaotic as it likes as long as
the *rules* are legible. One second, every time. You can hear it in your head.

## The best bug in the project: hands that push against the sky

Here is how you haul a fist to a pose, and it is what I shipped:

```lua
reach.Mode = Enum.PositionAlignmentMode.OneAttachment
reach.Attachment0 = fistAttachment
reach.MaxForce = 26000                  -- and it NEEDED to be this big
reach.Position = stanceWorldPosition    -- recomputed every step, in the sim
```

A `OneAttachment` `AlignPosition` drags its part toward a coordinate in the world. Ask
where the equal-and-opposite force went, and the answer is: **nowhere**. It is reacted
by the universe. The fist is shoved with up to 26,000 studs of force and *nothing else
in the world feels it*.

Which means throwing your hands out doesn't rock you backwards. Holding a heavy guard
costs you nothing. The momentum is conjured — and players read conjured momentum as
**floaty** long before they can tell you why. It's one of those flaws that never gets
reported accurately, because the person feeling it has no vocabulary for "your
character is exchanging momentum with God".

The fix is to give the force something to pay for itself with:

```lua
reach.Mode = Enum.PositionAlignmentMode.TwoAttachment
reach.Attachment0 = grabAtt   -- the fist: this is the end that gets moved
reach.Attachment1 = stance    -- an attachment ON the shoulder layer: it eats the recoil
reach.ReactionForceEnabled = true
reach.MaxForce = REACH_FORCE  -- 4000
```

Three things fall out of that, and the second is the reason to do it even if you don't
care about physical honesty.

**1. The gesture has weight.** Throwing your hands out now shoves his top cake
backwards — measured, 2.9 rad/s of recoil spin on the shoulders. Holding a guard costs
him posture. Nothing is created; it's borrowed from his own body, which is where a real
wrestler gets it from too.

**2. The pose left the simulation entirely.** `Attachment1` lives *on the top cake*, so
the target leans, lags and wobbles with him for free. The shoulders are square to the
hands **by construction**. The simulation no longer recomputes a world position every
step — it doesn't know where the hands go at all any more; it only says whether the
guard is up. An entire class of bug (the pose and the body disagreeing) simply ceased
to exist.

**3. `MaxForce` collapsed from 26,000 to 4,000 — and the guard arrives *faster*.**
0.30 s to the pose, where before it strained permanently short of the target. The old
number had to be enormous *because it was pushing against nothing*.

> **A number that has to be enormous is often a number that's pushing against nothing.**

That's the one to write on the wall. It's also how I'd have caught this months earlier:
26,000 was never a suspicious number to me until I asked what was on the other end of
it.

### And the geometry that eats your reach

The guard lives in the shoulder layer's own frame:

```lua
local STANCE_DIST = 4.4   -- how far in front of the shoulders
local STANCE_WIDTH = 2.1  -- and how far apart. A grappler's guard, not a lunge.
local STANCE_RISE = -0.1  -- just under the shoulder line
```

The arm is five segments of ~1.1 — call it **5.6 studs**. So the stance must be
reachable *from the shoulder*, and the vertical drop is what kills you: a pose 6 studs
forward and 5 studs down needs `sqrt(6² + 5.2²)` = **7.9 studs** of arm, and he has
5.6. The fist then strains at full extension, permanently short of where you sent it,
and every grab misses by exactly the amount you overreached.

I did that twice before I worked out the arm simply wasn't long enough. Shoulder to
stance is now 4.51 studs against 5.6 of arm, and the hands actually arrive.

## The guard follows the man, not the camera

I built a version where holding the guard re-aimed his facing at the camera direction,
so he'd square up to whatever you were looking at. It felt clever.

It was wrong, and the reason generalises: it slid your hands around your body every
time you moved the mouse, and it quietly promoted the camera from a way of **looking**
at the world into a way of **acting** on it. **Turning your head is not turning your
shoulders.**

The camera still steers — W is camera-relative, everyone expects that — but once your
intent becomes a direction in the world, the camera's job is done. To aim a grab, you
turn the *man*. Which is the game: you line your body up with your opponent, slowly,
visibly, while he watches you do it.

(Verified after ripping it out: sweeping the camera 270° with no steering input turns
him 0.0° and moves his hands 0.04 studs in his own frame.)

## What you caught is not yours to predict

Now the Server Authority lesson that this whole chapter exists for.

**An attribute cannot hold a reference to an instance.** Attributes are what roll back,
so attributes are the only state your simulation can own. Which means the sentence
*"I am holding **that** box"* **cannot be predicted**. It is not expressible in the
rolled-back state at all.

So the grab splits cleanly in two, and the split is not a compromise — it's the correct
architecture, and you'd want it even if attributes could hold instances:

| | Where | Why |
|---|---|---|
| **Your pose** — hands up, arms out, guard timing | the **sim** (predicted) | It's yours. It must be instant. It's just your own body. |
| **What you caught** | the **server** (`CakeGrab`) | It's a fact about the world, and facts about the world belong to the server. |

Your guard goes up the *instant* you click, with no round trip, because that's your
body and your body is predicted. Whether you actually caught anything is a question
only the server can answer, and it answers a few dozen milliseconds later, and nobody
notices — because your hands were already where you put them.

## Tension you can't read

Roblox will not tell you the force inside a constraint. There's no
`Constraint.CurrentForce`, so you cannot read the tension in a grip.

You don't need to. Give the grip a **finite `MaxForce`** and it simply *fails* to hold
anything too heavy or too determined — and the target drifts away from the fist. **That
gap is the tension.** Watch the gap; break the grip when it gets too wide:

```lua
local stretch = (target.Position - fist.Position).Magnitude
if not reaching or downed or gone or stretch > GRIP_BREAK or now - hold.since > GRIP_MAX_TIME then
	release(grip)
end
```

No breaking-force API, no invented "strength stat" — just a spring that isn't strong
enough, and a rule about when to admit it. A struggling opponent tears himself out of
your hand for free, and it looks exactly right, because it *is* right.

There's an invariant hiding in there that will ruin your day if you miss it:

> **`GRIP_BREAK` must be comfortably larger than your grab radius.**

Mine wasn't. `GRIP_BREAK` was smaller than the radius I was searching for targets in,
so every grab was *born already broken* — caught on one frame, torn loose on the next.
It looked, of course, exactly like a grip that was too weak.

## Grab what you touched

One more of my own clever ideas, killed:

```lua
-- YOU SEIZE THE BODY, NOT THE LIMB.  (wrong)
local target = if isPlayer then victimModel.PrimaryPart else part
```

The theory was sound. Grabbing someone's arm gets you five ball sockets of wet
spaghetti and no man on the end of it — you haul on the noodle, it stretches, and the
body doesn't move. So: touch any part of a man, carry the *whole* man.

It broke the very thing it was protecting. The grip is a spring between **your fist**
and the target — so silently retargeting it from the shoulder your hand is *touching*
to a base three studs below means the spring **starts life already stretched past
`GRIP_BREAK`**, and snaps on frame one. The only handhold that ever worked was the one
that happened to be exactly where your hand already was: the bottom slab.

Nobody could grab an arm, or a shoulder, or a head. And it looked like the grip was too
weak. It wasn't. It was being asked to hold something it *wasn't touching*.

So: you hold the thing your hand is on. Yes, an arm is a floppy handle and dragging
someone around by one is hard work — but that's an honest fact about noodles, which the
player can *see*, and respond to by going for a better handhold. **A rule that quietly
moves your grab somewhere else can't be seen at all**, and so it can't be learned,
and so it just feels broken.

## And don't get killed by your own shopping

You pick up a box. The grip hauls it toward your fist at speed. It arrives at your face
at exactly the velocity the combat code considers lethal — and a box that hits your
cherry is an instant knockout (Chapter 8).

You picked up a box and were immediately killed by it.

```lua
-- CakeGrab stamps the box; CakeCombat ignores it.
if isBox and other:GetAttribute("HeldBy") == victim.Name then return end
```

With a grace period (`HELD_GRACE = 0.7`) after you let go, so the box you just *threw*
isn't treated as an enemy projectile while it's still an inch from your nose.

**Whatever a man is carrying is not a weapon pointed at him.**

## The numbers

| | | |
|---|---|---|
| `ARM_DELAY` | 1.0 | the commit. The whole mechanic. |
| `REACH_FORCE` | 4000 | was 26,000, when it pushed against the sky |
| `STANCE_DIST` / `WIDTH` / `RISE` | 4.4 / 2.1 / −0.1 | in the shoulder layer's frame |
| `Grip.MaxForce` | 55000 | enough to hoist a limp cake. Not a fighting one. |
| `GRIP_BREAK` | 7 | the gap at which the hand tears loose |
| `TOUCH_RADIUS` | 1.6 | a contact test, not a search |
| `GRIP_MAX_TIME` | 12 | you cannot carry a man forever |
| `HELD_GRACE` | 0.7 | your own box stops being yours, slowly |

---

**Next:** [Chapter 10 — the knockout](10-knockout-and-respawn.md), which is four lines
that stop holding him up.
