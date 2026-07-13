# 6. Prediction, and how not to help

This chapter is a record of me getting it wrong twice, because the wrong turns teach
more than the destination does. The destination, for the impatient, is: **set two
properties and then leave prediction alone.**

## The symptom

Boxes felt *late*. You'd charge a pile and there was a beat — a small, sticky pause —
before they moved. Everything else about the character felt immediate.

## Wrong turn 1: "there's no flag for this"

I went looking for a per-part prediction property. `EnableClientPrediction`,
`PredictionMode`, `ClientSimulated`, `PredictionRadius` — probed a dozen plausible names
on `BasePart` and `Workspace`. None of them exist. I checked `Player.SimulationRadius`
and found it sitting at a comical **8.5 studs**; I forced it to 300 and watched the
engine adaptively drift it back to 220 within seconds. I confirmed the props were on
auto network ownership, which under Server Authority is meaningless anyway — **the
server owns everything by definition; `SetNetworkOwner` is not the lever.**

So I told Peter there was no local-prediction flag.

There is. It's a **method on `RunService`**, not a property on the part, which is why my
probing sailed straight past it:

```lua
RunService:SetPredictionMode(instance, Enum.PredictionMode)  -- client-only
-- Enum.PredictionMode = Automatic | On | Off
```

And the docs describe the exact symptom I'd been chasing:

> By default, Roblox will automatically predict properties with simulation access
> **near the local player Character**.

There's also `RunService:GetPredictionStatus(instance)`, which reports what the engine
is *actually* doing — `Predicted`, `Authoritative`, or `None`. **Read your knobs back.**
Don't trust that setting a mode did anything.

*(It was documented in my own notes the whole time. I hadn't looked.)*

## Wrong turn 2: building a better bubble

Right. `On` forces an instance to always be predicted. But `On` isn't free — every
forced instance joins the **resimulation set**, and the sim re-runs several times a
frame. Force all 73 boxes on and you're re-simulating a warehouse in order to punch one
box.

So I wrote the clever thing: an **ad-hoc prediction bubble**. Every tick, force
prediction `On` for props within N studs and back to `Automatic` for props beyond M
studs, with hysteresis so boundary props don't flip every frame.

It worked. I have the traces: at a 10/15-stud bubble, **5–9 of 73** props predicted, and
the box he charged was `Predicted` at the moment of impact, caught at 4.5 studs. I even
built a debug view (F6) that paints every prop **green** for predicted and **red** for
not, so you can watch the bubble move with you.

And Peter looked at it and said: *the props are dancing around.*

They were. Because **the engine already has a prediction bubble**, keyed to
`Player.Character`, and mine was fighting it — flipping modes underneath the engine's own
decisions, every tick, forever.

## What actually works

Delete all of it. With `ReplicationFocus` and `Character` set — the two lines from
chapter 1 — the engine predicts things near you, and it's *already right*:

| | |
|---|---|
| Boxes predicted while idle | 10–14, out to ~20–34 studs |
| Box status at the moment he hits it | **`Predicted`.** Every time. |
| `SetPredictionMode` calls in the shipping code | **Zero.** |

103 lines of my cleverness deleted; the character got *more* responsive.

## The gotcha that made the bubble actively harmful

This is the real find, and it's nasty:

> **Re-issuing a prediction mode repeatedly CHURNS the engine's state**, and can leave a
> part *less* predicted than if you had never touched it.

A test loop of mine re-asserted `Automatic` at 20 Hz, and a box being punched at **4.4
studs** read `None` — completely unpredicted, right under his fists. My bubble was doing
a gentler version of exactly that.

**Set it once, or don't set it at all. Never poll-and-set.**

## So when *should* you use `SetPredictionMode`?

For the exception, not the policy. An instance the game is genuinely *about* that lives
outside the bubble — a boss across the arena, a ball everyone is chasing. Force that one
`On`, deliberately, and pay for it knowingly.

And keep the F6 debug paint. It's still useful — it now visualises **the engine's**
bubble rather than yours, which is exactly what you want when you're trying to work out
whether prediction is your problem. (Ours is adaptive and, frankly, erratic: it reaches
34 studs when idle and collapses to 8 when you're standing in a pile of boxes — which is
precisely when you most want the things around you predicted. Worth knowing.)

## The lesson

> If you find yourself micromanaging prediction, check `ReplicationFocus` and
> `player.Character` first. You are probably solving a problem you created by not
> setting them.

---

**Next:** [Chapter 7 — presentation](07-presentation.md). Making it look good, without lying.
