# Physics characters under Server Authority

Doctrine for building a character whose **authoritative ragdoll is the character** — real
parts, real constraints, real forces. No Humanoid, no animation-driven movement, no
kinematic controller.

Platform mechanics are in [server-authority.md](server-authority.md); the patterns this
builds on are in [patterns.md](patterns.md). Everything here was verified in play. Numbers
are measurements unless labelled as a setting.

## 1. The architecture that survives rollback

### One shared sim module, one state contract

The entire character brain is a single ModuleScript run through `BindToSimulation` on both
server and client:

> **The owner of a character — the server for all of them, a client for its own — reads live
> input and writes *intent* as attributes on the character's root part. Every peer — server,
> owning client, spectating clients — drives the actuators from those attributes,
> identically.**

Intent attributes are the character's entire mind: things like `Driving`, `TargetDir`,
`DriveDir`, `SurfaceNormal`, `GaitPhase`, `Attached`, `ContactT`, `LookDir`. Attributes
written inside the sim roll back with resimulation, which is what makes this work. A remote
character is driven from its last replicated attributes — extrapolated as though the player
kept doing what they were doing.

Consequences learned by breaking them:

- Attribute names cannot contain `.`; sanitize any name derived from a part name.
- Timers are **countdown attributes decremented by `dt`**, never wall-clock.
- Progress clocks advance by **distance travelled**, not time — cadence tracks speed and
  resimulates identically.
- The owner **may** write `AssemblyLinearVelocity` inside the sim — it is a Simulation Access
  property and it rolls back correctly. Rotating momentum during a surface transition is a
  legitimate use. Prefer forces as the movement channel anyway, for feel: ramps hide
  corrections, snaps expose them.
- **Plain Lua tables do not roll back.** A prototype that keeps a trail, a ring buffer, or a
  history table in module state works in single-process Play and diverges the moment it is
  promoted to real prediction. Promoting it means either moving that state into attributes —
  budget it, 24 `Vector3`s is roughly 288 bytes against a 64-attribute cap — or reformulating
  the mechanic to need only the predecessor's replicated state.

### Actuators are pre-wired; the sim only sets targets

The server wires every force object at spawn: a world-relative `VectorForce` per driven part,
an `AlignOrientation` for facing, an `AlignPosition` per anchor point. The sim never creates
instances. It only writes `.Force`, `.CFrame`, `.Position`, `.Enabled`.

Setting an actuator target is **idempotent**, which is what makes a step that re-runs six
times during reconcile produce the same world.

### Characterless place checklist

`CharacterAutoLoads = false` throughout this doctrine. Three things break silently without a
Humanoid: the server must spawn and despawn the character itself; **`player.Character` must
be set to the model** or nothing is pulled into the prediction and rollback loop; camera and
input are entirely yours to build. Set `player.ReplicationFocus` to the root part as well —
that governs the streaming radius, not prediction. Full detail in
[patterns.md §15](patterns.md#15-characterless-setups-characterautoloads--false).

### Two hierarchies, split at boot

Author the character as one model — physics parts plus skinned mesh and bones — then split it
at server boot:

- **Physics-only ragdoll** → the spawning template. Authoritative, replicated.
- **Mesh character** → `ReplicatedStorage`. The client clones it; render-only.

Bake part-to-bone rest offsets *before* the split, while everything is still aligned, and
store them as attributes — they survive every clone. Set the streaming mode on both so
clients never see half a character.

## 2. The body is gameplay: mass, joints, assemblies

- **Ball sockets do not merge assemblies.** Each ragdoll part is its own assembly, so a force
  on a foot drags the body through the constraint chain. This is what makes "apply force at
  the foot" work at all.
- **Mass distribution is a gameplay variable.** Every traversal failure worth debugging
  reduced to the same sentence: *a force lifted part of the chain while the heavy part hung
  as dead weight.*

  > **Assist forces must cover the whole mass chain.** Apply them as uniform acceleration
  > fields — `force = accel * part.Mass` per part — not as a push on one part. A torso-only
  > bump folds the character around its own heavy midsection.

- **Scale per-part forces by `part.Mass`, not `AssemblyMass`**, so the field sums to exactly
  one gravity even if parts ever share an assembly.
- **Tune in acceleration units.** Every knob is an acceleration, multiplied by mass at the
  last moment. Knobs then keep their meaning when the rig's mass changes.
- **Loosen authored joint limits in code at spawn.** Floppiness is expressiveness, and the
  renderer follows whatever the physics does. A neck authored at 25° opened to 80° in code.

## 3. Locomotion: slide the body, the legs keep up

The single most important feel decision: **slide the whole character around and let the legs
keep up as best they can.** The body is driven directly; the legs are grip and theater. Every
time that was inverted — making the legs load-bearing — the character got stiff and unfun.

### The velocity servo

```lua
-- feed-forward breaks drag and stiction; the gap term closes to TARGET_SPEED
-- and goes NEGATIVE above it, which makes this a cap rather than a motor
local along = vIn:Dot(moveDir)
local ffScale = math.clamp(
	1 - (along - TARGET_SPEED) / (TARGET_SPEED * (FF_TAPER_END - 1)), 0, 1)

thrust.Force = (moveDir * (FRICTION_FF * ffScale)
	+ (moveDir * TARGET_SPEED - vIn) * ACCEL_GAIN) * mass
```

- **Taper the feed-forward with a knee** — full to `TARGET_SPEED`, zero at about 1.35×.
  Untapered feed-forward overran the cap 1.7–4× on drag-free surfaces and launched the
  character off every edge. Tapering from zero instead felt flat. The knee keeps the zip.
- **Strafe is not facing.** Move toward the committed target direction *immediately*; slew a
  separate facing direction toward it at `TURN_RATE` and aim the `AlignOrientation` at that.
  The body carves; the nose catches up.
- **Coast, do not brake.** When input stops, apply light velocity damping, never a hard stop.
  Glide is feel, and hard stops expose corrections under latency.

### Gait, if you have legs

- One phase clock per leg group, advanced by distance. Per-limb offsets give contralateral
  stepping and a stride wave that travels front to back. A duty fraction splits planted from
  swing.
- Planted feet **grip by damping their in-plane velocity** plus a press into the surface.
  Swing feet lift along the surface normal and reach toward the next plant.
- **Position anchors (`AlignPosition` pins) only while parked — never while driving.** Pins
  hold under sustained load, which sounds right and plays wrong: every strafe and turn fights
  them, and feet pinned to the floor fight the floor-to-wall transition itself. If adhesion
  cancels gravity on walls, climbing never needed pins.
- Plant distance (`STRIDE * duty`) must stay under the leg's physical reach, or the leg goes
  taut mid-stroke and levers the foot off the ground.
- **Cadence = `TARGET_SPEED / STRIDE`.** One speed knob sets both movement speed and step
  rate. Keep couplings like this: fewer knobs, coherent feel.

## 4. Steering and the camera

Camera-relative steering on arbitrary surfaces has real math in it. Each rule below replaced
a simpler rule that field-failed.

1. **Recompute the move direction every frame** from the live camera direction. Hold W and
   swing the camera to carve a curve. Edge-locked steering — recompute on key change only —
   feels dead. Feed the camera in as a `Direction3D` InputAction
   ([patterns.md §13](patterns.md#13-camera)); it replicates and rolls back, unlike reading
   the camera directly.

2. **W means "up on the screen", mapped onto the surface.** The W/S axis is the intersection
   of the camera's vertical screen plane with the surface plane — `N × camRight` — signed so
   it reads as screen-up, with screen-depth breaking the tie when the axis is level on screen
   (flat ground plus a level camera). This one rule gives "away from camera" on the floor and
   "up the wall" face-on **at any camera pitch**: run at a wall with the camera pointed at the
   ground and the character climbs.

   Simpler rules that failed: pure camera-forward projection (its surviving remnant is the
   *pitch*, which steers down the wall); blending forward-to-up by face-on-ness (fails for
   ground-pitched cameras).

3. **Edge-on fallback.** A surface seen as a sliver on screen has a degenerate axis. The plain
   forward projection is well-defined exactly there — weight it in as the axis magnitude
   fades.

4. **Hidden-face rule.** Screen mapping is ill-defined on faces the camera cannot see
   (`camF·N > 0.25` on non-flat surfaces). Without this, W points back up a wall's far face
   and fights the wrap into a deadlock at top edges. Hold the parallel-transported direction
   instead — keep doing what you were doing — until the camera comes around.

5. **Steer-away release.** On a wall, the **raw, unprojected** stick direction pointing away
   from the surface (`> 0.55`) is a deliberate detach: push-off kick, attachment suppressed
   for about 0.35 s. Every attach mechanic needs a deliberate exit; without one the only way
   off a wall is finding an edge.

   Note 0.25 (hidden) < 0.55 (release). Surface goes out of view → steering freezes; camera
   turned fully away plus W → let go. The thresholds mesh by design.

6. **Parallel transport.** Whatever direction steering commits is rotated by the same
   per-frame rotation the surface normal takes, so "forward into the wall" rolls into "forward
   up the wall" and nothing snaps when projections degenerate.

   **Transport the momentum too.** `AssemblyLinearVelocity` is the one vector you would forget
   to transport, and it is the one that causes the launch.

   Re-deriving instead of transporting fails at exactly the wrong moment: driving into a wall,
   once the frame finishes rolling onto it, the requested world direction is parallel to `−N`
   and projects to **zero**. Measured symptom — the body commits, climbs 0.35 studs on
   leftover momentum, slides back, repeats.

## 5. Omni-surface traversal

Wall-and-ceiling traversal, in dependency order. Each item is load-bearing.

1. **Custom-gravity adhesion.** A per-part `GravityForce = g * (worldUp − N) * mass` cancels
   world gravity and re-applies it toward the surface. On flat ground the force is zero, so
   the whole feature collapses to normal locomotion — which is why it is debuggable at all.

2. **The frame comes from contacts, per half.** Front half and rear half each blend their
   contact normals with their body's down-ray. Two independent frames let the body straddle an
   edge; contact blending keeps the frame valid at lips, smooths corners, and "ramp-ifies"
   staircases for free.

3. **The rear's "ahead" is toward the front half** — not the steering direction, which lives
   in the front's plane and can project to nothing in the rear's. Without this the rear never
   discovers the wall and hangs as dead weight. Measured symptom: front sticks at y≈7 and the
   whole body hangs, because the rear's mass out-anchors the climb.

4. **Radial control.** Pull-only suction — a ride-height spring past the hover target — plus
   damping of *outward* body velocity on non-flat surfaces. This is the centripetal glue that
   keeps momentum from launching the character off convex edges. Pull-only and outward-only,
   so flat ground is untouched.

5. **Wrap probes for convex edges.** When the surface ends ahead, cast from a point ahead
   *and pushed off the surface* (~0.75 studs) back down into where the next face must be. Add
   a steeper second ray to catch thin tops: a 1-stud fin sits in a window the 45° ray grazes
   past. Priority order: wall-ahead (concave) > wrap (convex) > contact blend > down-ray.

6. **Aim the edge probe by geometry, not by its own output.** The "does my surface continue
   ahead?" ray is cast along `−oldN`, and if *any* hit suppresses the wrap probe you build a
   feedback loop. On a flat top the ray points down and misses over the void → wrap fires →
   `N` tilts ~25° toward the face → the ray now points into that face → "ground ahead" → wrap
   skipped → the target falls back to the down blend, still voting straight up → `N` tilts
   back → the ray misses again.

   Measured: a character at cruise stalled at a cliff lip indefinitely. `N·up` locked at 0.89
   and oscillated 0.83↔0.93 for 1.5 s and beyond; branch tally past the lip was 158 frames
   down-blend against 67 frames wrap, a two-state limit cycle at 60 Hz, with the drive
   direction flipping ±0.5 in Y every frame.

   **Fix: `EDGE_SAME_FACE` (0.7).** A hit only means "my surface continues" if its normal
   still resembles `oldN`. A hit that has turned away is the *next face* and must not suppress
   the wrap. This alone closes the loop — the frame then slews monotonically
   1.00 → 0.87 → 0.67 → 0.41 → 0.10 → 0.00 with zero reversals.

   **Add `WRAP_COMMIT` (0.2 s).** Once a wrap has found a face, hold that target through
   frames where the back-and-down ray grazes past it. It also carries the wrap when the player
   releases the stick mid-rotation.

7. **Speed-split launch.** Above a launch speed (0.55 × cruise) onto a face turning more than
   60°, release attachment: momentum and gravity only, no adhesion, no wrap. Below it, the
   crawl-down behavior is unchanged.

   - **A `dropsAway` discriminator is essential.** A wall *top* is the same convex edge seen
     from the other side and passes every other test. Without the discriminator
     (`tgt·UP < oldN·UP`) a character cresting a 12-stud wall at y=11.8 gets launched straight
     back to the floor.
   - **End the arc on contact, not on a clock.** A fixed duration must cover the *longest*
     body; a long-tailed rig still had its tail crossing when 0.28 s expired, so the rear
     grabbed the face mid-fall and dragged it down the wall, keeping only 41% of speed.
     Holding the release while the down probe is empty is length-independent.

   Measured after both fixes, at cruise onto a sharp cliff: **84% of cruise speed kept**, a
   level parabolic arc, zero stalls — against "stalled at the lip forever" before. A
   long-tailed rig kept 82%. Wall climb and mantle stayed at zero launch frames and zero
   normal reversals.

8. **Intent gates, split by ray.** The forward probe is a center ray plus a ±28° fan. Grazes
   only ever arrive via the fan, so gate the fan hard (`mv·faceN < −0.5`) and walls you run
   alongside will not grab you. A center hit means the player is steering straight at the
   surface, so it gets a glance filter only (−0.15) — otherwise shallow-angle wall-to-floor
   descents grind into the seam. **Do not re-unify these.**

9. **Attachment is explicit and expires.** Any probe contact refreshes a contact-grace
   countdown (~0.15 s); adhesion, suction, and transport all gate on it. Detached means falls
   under real gravity, immediately. The not-upside-down rule is one dot product at the probe
   layer (`hit.Normal·UP > −0.15`) — too-overhung surfaces are simply never seen, so the
   character bumps instead of sticking.

10. **Slew the frame at a speed-coupled rate** (`speed / EDGE_RADIUS`, clamped): wrap a corner
    at the rate you round it. Fixed-rate slew is either too slow at speed or snappy when slow.

11. **Stairs are steps, not walls.** A shin-height knee ray finds the riser; a probe just past
    it finds the top; a walkable top within `STEP_MAX` (2.2 studs) suppresses the wall commit
    and hops. **The hop must be whole-body** — boosting only the detecting half cannot lift
    the character, because the other half's dead weight pins it grinding against the riser.
    Rear at 70% of full strength; full strength pops the back end up.

    Ramps are excluded because the riser must be steep. Tall walls are excluded because there
    is no top in probe range — the top probe starts inside the wall, and inside-out rays hit
    nothing. Descending stairs need nothing: the ahead-down ray sees each lower step, so no
    wraps fire.

12. **Assists shrink as the physics gets right.** A mantle boost went 220 → 120 → barely
    needed as anchors, suction, and wrap probes landed. A hack you get to delete is the health
    metric.

**Raycast budget:** roughly 6–10 casts per character per step on the owner, times ~6 during
reconcile. Static-world raycasts are deterministic and resim-safe — the cost is real, the
correctness is not at risk.

**Only probe `Anchored` geometry.** Adhering to a dynamic part feedback-loops: you pull
yourself with no reaction force on the object.

### Spheres, if the priority ladder chatters

An oriented body needs a priority ladder of probes because something must decide what to
align to, and at a convex edge two answers are true at once. A sphere has nothing to align:
it needs the nearest surface and its normal, and for a sphere that quantity is **continuous
across a convex edge** — the contact slides from the top face onto the edge line onto the
side face, the normal sweeping through 90° with no moment where two faces compete. Measured:
a ball chain wrapped a 90° cliff lip 1.00 → 0.86 → 0.49 → 0.00 in three frames, monotonic.

Three things a nearest-contact sphere formulation gets wrong, each caught by measurement:

1. **Nearest contact cannot climb.** A ball at the foot of a wall genuinely has the floor as
   its nearest surface, so nearest-point pins it there — measured driving into the wall at
   11.9 studs/s and stopping dead. Blend **all** distinct faces, weighted by gap.
2. **A purely geometric blend is a stable trap.** In a corner both faces are at zero gap, so
   the blend sits at exactly 45° and stays: surface-ward gravity pulled 139 studs/s² toward
   the real floor while the in-plane drive could only lift 85. Measured `N·up` parked at 0.71,
   speed 0.00. Weight a face louder when you are **driving into** it — the forward-commit gate
   again, but as a continuous weight on a blend rather than a hard branch, so it cannot
   chatter. Convex is free; **concave still needs intent**, and that asymmetry looks
   fundamental.
3. **Steering must be transported, not re-derived** — the same failure as §4.6, with the same
   fix. With it, a head climbed a 12-stud wall at 11.4 studs/s and crested at y=12.55.

### Chains: follow the path, not the leader

For a segmented body, servo each follower to the point a fixed **arc length** back along the
path the head actually took, lifted off it by the follower's own radius. Do not steer each
follower at its leader's current position.

Steering at the leader's current position is a straight line to where the leader *is*, not
the path it *took*. Around a corner that line cuts through geometry; over a lip it points
through open air; and being a force-follow it stretches without bound. A trail removes the
whole class — a follower cannot be somewhere the head has never been, and spacing is *set*
rather than negotiated.

Two details that mattered more than the servo tuning:

- **Store the contact point, not the centre.** The shared thing is the path on the *surface*;
  each segment then sits at its own radius above it. Storing centres puts a radius-1.10 rump
  wherever a radius-0.55 nose's middle had been — half a ball into the floor. This is what
  makes a tapered chain work at all.
- **Prime the trail on spawn and teleport.** An empty trail makes the sampler clamp every
  follower onto the single oldest crumb, stacking the rear and shoving it apart — measured
  1.7 studs of spacing error. Seeding from the placed layout, tail first, drops that to 0.009.
  Weightless followers must also be *snapped* to the surface on teleport, or they hover at the
  spawn clearance until the head has driven far enough to lay fresh crumbs under them.

Measured over a full 12-stud wall traversal, five segments:

| | spacing error |
|---|---|
| at rest / on spawn | 0.009 studs |
| straight run at cruise | 0.003 – 0.03 studs |
| mean while moving | 0.276 studs |
| worst, rounding the 90° corner | 1.33 studs |

The corner transient travels down the chain as a wave — each link compresses at the wall base
and stretches over the crest — and recovers to ~0.006 once every segment is on the new face.
Roughly half of that worst case is not error: the metric is straight-line centre distance
while the constraint is arc length, and the chord across a right-angle bend is genuinely
shorter than the arc.

**Rollback caveat:** a trail held in a Lua table does not survive rollback. See §1.

## 6. The presentation layer

- **Copy A** — the authoritative ragdoll. Replicated, locally invisible via
  `LocalTransparencyModifier = 1`.
- **Copy B** — a client-only anchored clone with constraints stripped: a pure data carrier.
  Each `RenderStepped`, SmoothDamp B toward A with a velocity feed-forward lead
  (`target + v * LEAD`) so smoothing does not trail; lerp rotation separately.
- **Mesh** — the skinned character, bones backdriven from Copy B via the baked rest offsets,
  **sorted by bone depth so parents pose before children**.

The same pipeline runs for local and remote characters. A remote is just anchors updating at
network rate instead of prediction rate.

**`CanQuery` defaults to `true` on your visual copies, and an anchored visual then answers
your own sim's raycasts on the client only** — geometry the server does not have, i.e. a
guaranteed misprediction you built by hand. Defenses and their tradeoffs are in
[patterns.md §8](patterns.md#the-visual-copy-is-still-a-part).

Camera: follow a smoothed proxy, never the truth. Details in
[patterns.md §13](patterns.md#13-camera).

## 7. Feel-tuning principles

1. **Fluidity beats correctness.** The "correct" grip — position pins — was the stiff one.
   When a mechanic and the feel doctrine conflict, the doctrine wins and the mechanic gets
   rescoped.
2. **Every attach needs a deliberate exit** the player can perform on purpose.
3. **Speed-sensitive outcomes read as organic.** Slow onto an obstacle wraps it; sprinting
   vaults it. Do not force one outcome — ballistic recovery that lands driving is a feature.
4. **Cap speed with a taper, not a wall** — and cap it somewhere, because overspeed breaks
   everything else: probes get outrun and transitions skip.
5. **Prefer acceleration ramps over snaps** for every force. Latency masking and feel point
   the same direction.
6. **Couple knobs deliberately** — speed sets cadence — and keep every knob in acceleration
   units at the top of the sim file, each with a comment saying what it *feels* like.
7. **Blend, do not branch**, wherever two rules meet. Thresholds pop; weights do not.
8. **The player is the final instrument.** Traces prove mechanics; only hands prove feel.

## 8. Testing methodology

- **A versioned test course, built by a boot script.** Ramps at 30/45/60°, a 12-stud wall, a
  chamfered wall, an inside corner, a 1-stud fin, 95° and 110° overhangs, 1-stud and 2-stud
  staircases, a cliff bank with sharp/chamfered/undercut lips. Place-level geometry is
  invisible to source control; a script that rebuilds the course each boot is not. **Every
  mechanic gets a station before it gets tuned.**
- **A gizmo overlay.** Normals, every probe ray (solid to hit, dim on miss), contact states,
  plant points, attach state. Attribute-driven and render-only so it stays simulation-inert.
  Feel-tuning blind via prints is the single biggest time sink there is.
- **Trace tables, not vibes.** Sample position, normal, velocity and state attributes at
  1–2 Hz into a table and read the numbers. Verify every mechanic with a trace before a human
  ever feels it.
- **A headless drive harness.** `InputAction:Fire()` acts as a held input; a `Scriptable`
  camera defines steering. Put multi-step timelines inside **one** script — tool and command
  latency between separate calls is seconds.
- **Single-process Play is accurate; Server & Clients is for latency.** Build and tune
  mechanics in single-process. Reconcile behavior under latency, latency feel, and remote
  rendering are what need Server & Clients plus the network simulator.
- **Log findings with dates, including failed approaches and why they failed.** Re-reading an
  earlier failure note is where several of the fixes above came from.

## 9. Known open problems

Carried forward from the rig this doctrine was built on; listed so nobody re-derives them as
new:

- Concave wall-to-wall inside corners are formally untested; one stall observed at a
  perimeter seam.
- 95° overhang climbs work but are slow, around 3 studs/s.
- A brief hesitation at wall-top back edges before the wrap commits, up to ~1.5 s worst case.
  Much improved by the hidden-face rule (§4.4), not gone.
- The speed-split launch triggers about 1 stud *before* the physical lip, because it is
  edge-reach driven. Invisible at body scale, but it is why launch speed is measured against
  pre-lip cruise.
- Chamfered and undercut lips are built but not swept.
