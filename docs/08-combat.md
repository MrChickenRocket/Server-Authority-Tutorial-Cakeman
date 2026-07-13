# 8. Combat: damage is momentum

CakeMan has no attack button. He has arms, and the arms have mass, and if you turn
fast enough they arrive somewhere with a lot of energy. The whole combat system is
one question asked at every contact: **how hard did that hit, and who brought the
energy?**

Both halves of that question turned out to be traps.

## First: where does combat live?

Not in the simulation.

Chapter 3 drew a line: intent is predicted, consequences are authoritative. Combat is
entirely on the far side of that line. `CakeCombat.legacy.luau` runs on the server
only, on `Heartbeat`, listening to `Touched`.

That is a deliberate choice and not a lazy one. Your *movement* has to be predicted or
the game feels like it's underwater. Whether you just took 7 damage does not: it
arrives a few dozen milliseconds later and nobody can tell, and the alternative — a
client that predicts its own damage — is a client that is *wrong* about who is
winning, which is the one thing you can never smooth over.

So health is three attributes on the root part, written only by the server:

```lua
root:SetAttribute("Health", 100)
root:SetAttribute("Downed", false)
root:SetAttribute("DownedFor", 0) -- counts DOWN by dt. Never a timestamp.
```

The simulation *reads* them (that's how the knockout limp works, Chapter 10). It never
writes them.

## Trap 1: the velocity in `Touched` is the wrong one

Here's the naive impact test, and it's what I shipped first:

```lua
local relSpeed = (other.AssemblyLinearVelocity - victimPart.AssemblyLinearVelocity).Magnitude
if relSpeed < HIT_SPEED_MIN then return end
```

Reasonable. Wrong.

**`Touched` fires after the solver has already resolved the contact.** The velocity you
read there is the velocity *left over* — after the impact spent it. And for a light
thing hitting a heavy thing, that's nearly nothing.

I measured it. A cardboard box (density 0.008) hurled at a CakeMan at **50 studs/s**
reports **2.1 studs/s** by the time `Touched` hands it to you. It arrives like a
cannonball and describes itself as a nudge.

Which meant thrown boxes did **no damage at all, ever**. Not "not enough damage" —
none: every impact fell under the threshold. And nobody noticed for weeks, because of
Trap 2, which was busy generating spurious damage from the other direction.

The fix is to keep the velocity yourself:

```lua
-- Heartbeat runs AFTER physics, so what we store is the velocity each part carried
-- INTO the next step -- which is the pre-impact one. Weak keys, so destroyed boxes
-- drop out of the table on their own.
local prevVel: { [BasePart]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any

RunService.Heartbeat:Connect(function()
	for _, box in CollectionService:GetTagged("Prop") do
		prevVel[box] = box.AssemblyLinearVelocity
	end
	for _, man in menFolder:GetChildren() do
		for _, p in man:GetDescendants() do
			if p:IsA("BasePart") then prevVel[p] = p.AssemblyLinearVelocity end
		end
	end
end)

local function approachVel(part: BasePart): Vector3
	return prevVel[part] or part.AssemblyLinearVelocity
end
```

That's the whole fix, and it generalises: **if you are measuring an impact from a
collision callback, you are measuring the wreckage.** Cache the velocity a frame
early or you're describing the aftermath.

## Trap 2: relative speed can't tell who hit whom

With the velocities fixed, here's the next version — and the comment I wrote above it,
which I was rather pleased with:

> Relative speed is the correct measure, because it's the same number whether the fist
> swung into a stationary player or a player ran onto a stationary fist — which is
> exactly right.

And it *is* exactly right, **for two fighters**. Those two events genuinely are the
same event, and should hurt the same.

But a box is not a fighter. A box is inert. It has no opinion. And relative speed
cannot tell *"I punched a crate"* from *"a crate was thrown at my head"* — because
those are also the same number.

So punching a box hit **me** with the full closing speed of my own fist. Repeatedly.
Until I fell over. I was knocking myself out on the scenery, and the symptom that
finally gave it away came from the player, not the code:

> *"I keep knocking myself out by punching boxes — the boxes don't seem to contact
> anywhere but my arms."*

If the box only ever touches your arms, then the thing hurting you is the box you are
punching. The fix is to ask **who is closing the distance**:

```lua
if isBox then
	local dir = (victimPart.Position - other.Position).Unit -- box -> me
	local boxClosing = otherVel:Dot(dir)   -- box coming at me
	local myClosing = myVel:Dot(-dir)      -- me going at box
	if boxClosing <= myClosing then
		return -- I punched it. It didn't punch me.
	end
	-- And it only hits as hard as it is actually travelling: its own closing speed,
	-- not the relative speed. Otherwise a fist swung at 40 into a gently drifting
	-- crate still registers as a 40-stud-per-second impact.
	relSpeed = boxClosing
end
```

A thrown box still lands. A box you *run into* at speed still hurts — correctly, because
then the box really is the one closing. But a box you hit is a box you hit.

Note this rule is for **props only**. Between two players, relative speed stands: two
cakes colliding at speed is a mutual event and it should be.

## Trap 3: a cake is five slabs, so one punch landed five times

The damage numbers felt enormous. Two clean hits and a man was finished. So I did the
obvious thing and cut every damage constant by a factor of five... and it *still* felt
like being hit by a truck.

Because the damage number was never the problem. This was:

```lua
local key = tostring(other) .. ">" .. tostring(victimPart)   -- WRONG
```

The hit cooldown was keyed per attacker-part → **victim part**. And a CakeMan is five
slabs plus two arms. A fist sweeping through a man clips his sponge, his strawberry
*and* his icing on the way past — and gets billed separately for each. One swing,
four or five hits.

They weren't hitting harder. They were hitting **repeatedly**. Cutting the scale by 5×
didn't fix it; it just made the multiplier harder to see.

```lua
local key = tostring(other) .. ">" .. tostring(victim)       -- the MAN, not the slab
```

There's a general lesson buried in that, and it's the one I'd actually take away:
**when a tuning change doesn't produce the effect its arithmetic says it should, stop
tuning.** The model is wrong, not the constant. I had a 5× cut that behaved like a
1.2× cut and I nearly went round again with another factor of five.

## The cherry, which is judged first

A clean hit on the head is an instant knockout, whatever your health.

```lua
local CHERRY_KO_SPEED = 14 -- a solid connection with the cherry ends you, full stop
```

The ordering here is not incidental, and fixing Trap 3 nearly destroyed it. With the
cooldown now keyed to the *victim*, a fist that clips a man's icing on the way to his
cherry **sets the cooldown in passing** — and the head contact, arriving a millisecond
later, gets discarded as a duplicate. The one hit in the game that is supposed to be
unmissable, swallowed by bookkeeping.

So the head is settled **before** the cooldown, on the merits of the contact itself:

```lua
-- THE CHERRY, JUDGED FIRST AND EXEMPT FROM THE COOLDOWN.
if victimPart.Name == "Head" and relSpeed >= CHERRY_KO_SPEED then
	knockOut(victim)
	return
end

-- ...only now do we do the one-punch-is-one-punch bookkeeping
local key = tostring(other) .. ">" .. tostring(victim)
if (lastHit[key] or 0) + HIT_COOLDOWN > now then return end
lastHit[key] = now

local scale = if isBox then BOX_DAMAGE else FIST_DAMAGE
damage(victim, (relSpeed - HIT_SPEED_MIN) * scale)
```

It's a lovely target: a light, wobbling sweet on a loose neck socket, the single
hardest thing on the body to connect with, and the funniest possible thing to lose to.
Make your instant-win condition the thing that's hardest to hit and everything else
looks after itself.

## Only fists hurt

```lua
-- Being barged by someone's cake is a shove, not a punch.
if attacker and not string.match(other.Name, "^Arm[LR]5$") then return end
```

Walking into someone should move them, not hurt them. This one line is most of what
separates "a brawler" from "a game where everyone dies by standing next to each other".

## The numbers

| | | |
|---|---|---|
| `HIT_SPEED_MIN` | 18 | below this it's a nudge, not a punch |
| `FIST_DAMAGE` | 0.32 | per stud/sec above the threshold |
| `BOX_DAMAGE` | 0.18 | boxes are light — but they're everywhere |
| `HIT_COOLDOWN` | 0.35 | per attacker → **victim** |
| `CHERRY_KO_SPEED` | 14 | instant knockout, exempt from all of the above |

A clean fist at 40 studs/s does **7 damage** — about fourteen good punches to drop
someone. That is deliberately, almost comically weak, and it's the right call: this is
a game about a cake with noodles for arms. **The flailing is the content.** You have to
survive long enough to do some.

---

**Next:** [Chapter 9 — the grab](09-the-grab.md), in which my hands push against the sky.
