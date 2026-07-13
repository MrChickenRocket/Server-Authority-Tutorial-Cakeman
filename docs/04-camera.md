# 4. The camera, which you now own

Short chapter, one big discovery.

## Twenty minutes of staring at nothing

I turned on `AuthorityMode = Server`, hit Play, and there was no character. Just a
grey blur. I checked the server: the character had spawned, fifteen parts, correct
position. I checked `CameraSubject`: correctly pointed at the character. I checked the
console: clean.

The character was fine. **The camera controller was dead.**

```lua
print(Players.LocalPlayer.PlayerScripts:GetChildren())
--> { RbxCharacterSounds }
```

That's it. That's the whole thing. **There is no `PlayerModule`.** The module that
provides Roblox's default camera *and* default controls simply isn't there in a
characterless Server Authority place. So `CameraType = Custom` does exactly nothing —
no controller ever runs, the camera sits wherever it was born near the origin, and you
stare at an unremarkable patch of baseplate wondering what you broke.

The one-line diagnostic:

```lua
local before = camera.CFrame.Position
camera.CameraSubject = myPart
task.wait(1)
print((camera.CFrame.Position - before).Magnitude) -- 0.00 = nobody is driving the camera
```

## So drive it yourself

This is the doctrine you've probably read — *"with no Humanoid, the camera and input
are entirely yours to build"* — and it turns out to be literal. I'd been quietly
freeloading on `PlayerModule` without noticing, and Server Authority took it away.

A serviceable orbit camera is about forty lines: right-drag to orbit, wheel to zoom,
and a `BindToRenderStep` at `RenderPriority.Camera` to place it.

```lua
RunService:BindToRenderStep("CakeCamera", Enum.RenderPriority.Camera.Value, function(dt)
	local follow = Presentation.GetSmoothed(base) or base
	local target = follow.Position + Vector3.new(0, CAM_HEIGHT, 0)
	if not focus then focus = target end -- snap on frame 1, don't fly in from the origin
	focus, focusVel = smoothDamp(focus, target, focusVel, CAM_SMOOTH, math.min(dt, 0.05))

	local dir = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	camera.CFrame = CFrame.lookAt(focus + dir:VectorToWorldSpace(Vector3.new(0, 0, zoom)), focus)
end)
```

Three things in there are deliberate:

- **It follows a smoothed focus**, not the character. A wobbling cake is nauseating to
  track directly. (In chapter 7 it follows the *presentation copy*, which matters even
  more: the truth is the thing that snaps when a misprediction lands, and a camera
  pointed at it turns every correction into a flick of the whole screen.)
- **It snaps the focus on the first frame**, or it comes sailing in from the world
  origin at boot, which looks like a bug and is a bug.
- **It clamps `dt`.** One hitched frame should not fling your camera across the map.

## The other camera thing

Even with a working camera, it shoved itself straight through the character. The stock
occlusion logic only refuses to push past parts under **`Player.Character`** — and with
no Humanoid, nothing ever set that. The camera considered CakeMan to be scenery.

```lua
player.Character = man   -- on the server, at spawn
```

No Humanoid required, no side effects. Camera immediately held a steady 18 studs.

That's the same line from chapter 1 that also gives the prediction system a centre to
work around. It does a *lot* of work for one assignment, and nothing tells you that you
need it.

## Test-harness footnote

Once you own the camera, **you own it** — including in your automated tests. My playtest
scripts kept steering CakeMan in the wrong direction, because they set `camera.CFrame`
and my own render-step loop overwrote it the same frame. Any harness that wants to drive
a camera-relative character has to take the camera back first:

```lua
RunService:UnbindFromRenderStep("CakeCamera")
```

---

**Next:** [Chapter 5 — the world](05-the-world.md). An arena, and 122 boxes to knock over.
