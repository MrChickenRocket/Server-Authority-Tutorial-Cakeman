# 1. The method, built on a sliding cube

Server Authority moves character movement onto the server. The client no longer owns or
moves its character. It sends inputs; the server simulates; the result replicates back.

Two things follow: movement anticheat becomes secure by design. And designs where multiple
people interact with the same physics become something you can build a game out of,
because the server is simulating it for real and every client agrees on the result.

## The three parts

1. **A custom server character.** The server owns it and moves it.
2. **Client prediction.** Hides the input lag.
3. **A presentation layer.** Hides the corrections.

Part 1 is mechanically short. Parts 2 and 3 are mostly simple engineering.

This chapter builds all three on the simplest character worth building: **a cube you shove
around with a force every step**. Four files, about 200 lines, and at the end you have a
cube that is server-owned, uncheatable, instantly responsive, and smooth. Chapter 2 takes
those same four files and turns the cube into a floppy cake with noodle arms.

---

**Prior reading:** it's recommended you read over the existing Roblox Server Authority
documentation first: https://create.roblox.com/docs/projects/server-authority

---

## What you're building

```
ReplicatedFirst/
  CubeSim.luau            ModuleScript. The brain: runs on server AND client,
                          inside BindToSimulation.
  CubePresent.luau        ModuleScript. The visual layer (Part 3), plus the
                          critically-damped spring that drives it.
  CubeClient.local.luau   LocalScript. Client boot: the camera, the CameraDir feed.

ServerScriptService/
  CubeServer.legacy.luau  Script. Place settings, spawning, and the InputActions.
```

The suffixes are a file-sync convention: `.luau` is a ModuleScript, `.local.luau` a
LocalScript, `.legacy.luau` a Script. In Studio they're just the instance class.

Start from an empty baseplate and build it up as you read.

If you'd rather drive the finished thing first, open
[`samples/chapter1place/`](../samples/chapter1place/) in Studio and press
**Test → Server & Clients**. The loose scripts are in
[`samples/cube/`](../samples/cube/).

---

## Part 1 — a custom server character

Under `Workspace.AuthorityMode = Server`, the server owns every character. Clients send
**inputs**; the server moves the characters from those inputs and replicates the result.

That round trip is input lag. Parts 2 and 3 are how it gets hidden.

### The checklist

1. Set `Workspace.AuthorityMode = Server`. This also enables streaming, which the
   replicator requires.
2. Set `Players.CharacterAutoLoads = false`. You are building your own character, so you
   spawn it.
3. On the server, create the Model that will be each player's character. **Leave its parts
   unanchored, and let the solver move them** — see the callout below.
4. Set `player.Character` to that model.
5. Set `player.ReplicationFocus` to the model's root part.
6. Create the **InputAction** Instances that drive it — a movement vector, buttons —
   parented to the Player, so both machines can read them.
7. Apply those inputs to the character inside `BindToSimulation`, on the server.

Every frame, on the server: read the player's inputs, drive the character. The server
replicates it out like anything else in the world.

There are a few extra rules, covered below. But if you could script a client-side character
before, the server-side version is the same work in a different place, with controls routed
through the InputAction system.

> ### Let the solver move it
>
> The temptation is to take the transform into your own hands — anchor the part and write
> its `CFrame` every step. Don't.
>
> Set `Anchored = true` on your character and it is excluded from client prediction
> entirely. The owning client reports itself **`Authoritative`** for its own *server-owned*
> character, nothing is ever rolled back, and no resimulation happens for it.
>
> There is no error and no warning. Worse, in single-process `Play` it looks perfect — the
> server and the client agree to the last decimal, because both machines run the same
> deterministic code with no latency between them. They agree for reasons that have nothing
> to do with prediction, and `Play` cannot show you the difference.
>
> Check it directly rather than trusting the appearance:
>
> ```lua
> print(RunService:GetPredictionStatus(root)) --> want Enum.PredictionStatus.Predicted
> ```
>
> The same applies to any other way of taking the transform out of the solver's hands.
> Whatever you do to sidestep the physics engine, you are sidestepping the thing Server
> Authority is built on.

So the cube is a real physical body. It is unanchored, it has mass, it rests on the floor
under gravity, and every step the simulation hands it a **force** — which is what Part 1
actually builds below.

### Step 1 — Set the two place settings

Select `Workspace`. In Properties, set **AuthorityMode** to **Server**.

Do this by hand. `AuthorityMode` is place state, not something a script can set, so it is
the one step in this article you cannot automate.

`CharacterAutoLoads` goes in the server script, in Step 2. Without it, every player also
gets a stock avatar you didn't ask for and can't use.

**Check:** reopen the place. `AuthorityMode` still reads `Server`. If it reverted, you
didn't save.

### Step 2 — Spawn a cube per player

`ServerScriptService/CubeServer.legacy.luau`:

```lua
--!strict
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

Players.CharacterAutoLoads = false -- no Humanoids; the cube IS the character

local cubes = Instance.new("Folder")
cubes.Name = "Cubes"
cubes.Parent = workspace

local SPAWNS = {
	Vector3.new(0, 4, -16),
	Vector3.new(16, 4, 0),
	Vector3.new(0, 4, 16),
	Vector3.new(-16, 4, 0),
}
local spawnIndex = 0

local function buildInputContext(player: Player)
	if player:FindFirstChild("PlayContext") then
		return
	end

	local ctx = Instance.new("InputContext")
	ctx.Name = "PlayContext"
	ctx.Enabled = true

	local steer = Instance.new("InputAction")
	steer.Name = "Steer" -- the sim looks these up BY NAME
	steer.Type = Enum.InputActionType.Direction2D
	steer.Parent = ctx

	local kb = Instance.new("InputBinding")
	kb.Name = "Keyboard"
	kb.Up, kb.Down = Enum.KeyCode.W, Enum.KeyCode.S
	kb.Left, kb.Right = Enum.KeyCode.A, Enum.KeyCode.D
	kb.Parent = steer

	local pad = Instance.new("InputBinding")
	pad.Name = "Gamepad"
	pad.KeyCode = Enum.KeyCode.Thumbstick1
	pad.Parent = steer

	-- The camera direction rides in as an input too. See Step 4 for why.
	local cameraDir = Instance.new("InputAction")
	cameraDir.Name = "CameraDir"
	cameraDir.Type = Enum.InputActionType.Direction3D
	cameraDir.Parent = ctx

	ctx.Parent = player -- parented to the Player, so BOTH machines can read it
end

local function spawnCubeFor(player: Player)
	buildInputContext(player)

	local name = "Cube_" .. player.UserId
	if cubes:FindFirstChild(name) then
		return
	end
	spawnIndex += 1

	local spawnAt = SPAWNS[((spawnIndex - 1) % #SPAWNS) + 1]

	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(4, 4, 4)
	root.Color = Color3.fromRGB(220, 150, 60)
	root.Position = spawnAt

	-- UNANCHORED, and this is load-bearing. An ANCHORED part is excluded from client
	-- prediction entirely: the owning client reports itself Authoritative for its own
	-- server-owned character, and nothing is ever rolled back. See the callout above.
	root.Anchored = false

	-- A bit slippery, so the servo is fighting the floor rather than the other way round.
	root.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.1, 0.2, 1, 5)
	root.Parent = model
	model.PrimaryPart = root

	-- ACTUATORS ARE PRE-WIRED HERE, NOT IN THE SIM. The sim may not create instances (it
	-- re-runs on every replayed step), so everything it could ever need exists up front
	-- and the sim only writes TARGETS onto it.
	local att = Instance.new("Attachment")
	att.Name = "DriveAtt"
	att.Parent = root

	local thrust = Instance.new("VectorForce")
	thrust.Name = "Thrust"
	thrust.Attachment0 = att
	thrust.RelativeTo = Enum.ActuatorRelativeTo.World
	thrust.ApplyAtCenterOfMass = true
	thrust.Force = Vector3.zero
	thrust.Parent = root

	local heading = Instance.new("AlignOrientation")
	heading.Name = "Heading"
	heading.Mode = Enum.OrientationAlignmentMode.OneAttachment
	heading.Attachment0 = att
	heading.MaxTorque = 1e6
	heading.Responsiveness = 40
	heading.CFrame = CFrame.identity
	heading.Parent = root

	-- Intent lives in attributes, because attributes roll back with resimulation.
	root:SetAttribute("MoveDir", Vector3.zero)
	root:SetAttribute("FaceDir", Vector3.new(0, 0, -1))

	-- Part 3 renders a smoothed copy of anything with this tag.
	CollectionService:AddTag(root, "Presented")

	-- An instance the client was never sent cannot be predicted.
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	model.Parent = cubes

	-- THE TWO LINES EVERYONE FORGETS. Neither is discoverable.
	player.ReplicationFocus = root -- what replication and PREDICTION centre on
	player.Character = model -- what the camera knows not to push through

	print("[CubeServer] spawned", name)
end

Players.PlayerAdded:Connect(spawnCubeFor)
Players.PlayerRemoving:Connect(function(player)
	local model = cubes:FindFirstChild("Cube_" .. player.UserId)
	if model then
		model:Destroy()
	end
end)
for _, p in Players:GetPlayers() do
	spawnCubeFor(p)
end

require(ReplicatedFirst:WaitForChild("CubeSim")).Initialize()
print("[CubeServer] ready")
```

Two lines in there do far more than they look like they do.

**`player.ReplicationFocus`** is what the server replicates around, and what prediction is
centred on. Without it, your own cube isn't predicted and every input feels like a full
round trip. Because it is one.

**`player.Character`** is what the camera knows not to push through. With no Humanoid,
nothing sets it, and the stock camera treats your character as scenery and rams itself
straight through it. Setting it costs nothing and does not summon a Humanoid.

**Check:** press Play. A cube appears at a spawn point and no stock avatar does. The output
window shows `[CubeServer] ready`.

### Step 3 — Write the brain

`ReplicatedFirst/CubeSim.luau`. This is the only file bound to the simulation, and it runs
on **both** machines.

```lua
--!strict
-- CubeSim -- the whole character. Runs through BindToSimulation on BOTH machines.
--
-- The contract: the OWNER (the server for all cubes, a client for its own) reads live
-- input and writes intent as ATTRIBUTES. EVERY PEER then drives the part from those
-- attributes, identically. Attributes written in the sim roll back with resimulation,
-- which is what makes that work.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local CubeSim = {}

local TARGET_SPEED = 24 -- studs/s the servo holds. A CAP, not a motor -- see drive().
local ACCEL_GAIN = 8 -- servo stiffness: higher = snappier to target, lower = heavier
local COAST_DRAG = 2 -- gentle damping when not driving: it coasts to a stop
local TURN_RATE = math.rad(540) -- how fast the FACING catches up. Movement never waits.
local UP = Vector3.new(0, 1, 0)

-- Rotate unit `cur` toward unit `tgt` by at most `maxRad` (shortest arc).
local function slewDir(cur: Vector3, tgt: Vector3, maxRad: number): Vector3
	local d = math.clamp(cur:Dot(tgt), -1, 1)
	local ang = math.acos(d)
	if ang < 1e-4 then
		return tgt
	end
	local axis = cur:Cross(tgt)
	if axis.Magnitude < 1e-5 then
		return tgt
	end
	return CFrame.fromAxisAngle(axis.Unit, math.min(maxRad, ang)):VectorToWorldSpace(cur)
end

local function readAction(player: Player, name: string): any
	local ctx = player:FindFirstChild("PlayContext")
	local action = ctx and ctx:FindFirstChild(name)
	return action and (action :: any):GetState() or nil
end

-- OWNER: live input -> intent.
local function readInput(root: BasePart, player: Player)
	local steer = readAction(player, "Steer") or Vector2.zero
	if steer.Magnitude < 0.1 then
		root:SetAttribute("MoveDir", Vector3.zero)
		return
	end

	-- Camera-relative steering, recomputed EVERY frame: hold W and swing the camera
	-- to carve a curve. (Committing the direction only on keypress feels dead.)
	local camF = readAction(player, "CameraDir") or Vector3.zero
	local fwd = camF - UP * camF.Y -- flatten onto the ground plane
	if fwd.Magnitude < 1e-3 then
		return
	end
	fwd = fwd.Unit
	local right = fwd:Cross(UP)
	local move = fwd * steer.Y + right * steer.X
	root:SetAttribute("MoveDir", if move.Magnitude > 1e-3 then move.Unit else Vector3.zero)
end

-- EVERY PEER: drive the ACTUATORS from the (owner-written) attributes. The physics
-- solver does the moving; we only ever hand it a target.
local function drive(root: BasePart, dt: number)
	local thrust = root:FindFirstChild("Thrust") :: VectorForce?
	local heading = root:FindFirstChild("Heading") :: AlignOrientation?
	if not thrust or not heading then
		return
	end

	local dir = (root:GetAttribute("MoveDir") :: Vector3?) or Vector3.zero
	local driving = dir.Magnitude > 1e-3

	-- Servo the HORIZONTAL velocity only. Gravity owns vertical.
	local vFlat = root.AssemblyLinearVelocity
	vFlat -= UP * vFlat.Y

	-- THE VELOCITY SERVO, and it is one line.
	--
	-- The gap term closes toward TARGET_SPEED and GOES NEGATIVE above it, which is what
	-- makes this a CAP rather than a motor: it cannot run away, because overshooting makes
	-- the force push back. Accelerations ramp, and ramps hide corrections -- so this also
	-- gives the presentation layer something continuous to smooth.
	--
	-- Multiplied by mass at the last moment, so the knobs stay in acceleration units and
	-- keep their meaning if the cube gets heavier.
	local mass = root.AssemblyMass
	if driving then
		thrust.Force = (dir * TARGET_SPEED - vFlat) * (ACCEL_GAIN * mass)
		root:SetAttribute(
			"FaceDir",
			slewDir(((root:GetAttribute("FaceDir") :: Vector3?) or dir).Unit, dir, TURN_RATE * dt)
		)
	else
		thrust.Force = -vFlat * (COAST_DRAG * mass) -- coast to rest, no hard brake
	end

	-- The body carves immediately; the nose catches up afterwards.
	local face = (root:GetAttribute("FaceDir") :: Vector3?) or Vector3.new(0, 0, -1)
	if face.Magnitude > 1e-3 then
		heading.CFrame = CFrame.lookAt(Vector3.zero, face, UP)
	end
end

function CubeSim.Initialize()
	local isServer = RunService:IsServer()
	local localPlayer = Players.LocalPlayer -- nil on the server

	-- Hz60, NOT the default. See the callout below -- at the default Hz30 this cube
	-- steps visibly, and the presentation layer does not hide it.
	RunService:BindToSimulation(function(dt: number)
		local cubes = workspace:FindFirstChild("Cubes")
		if not cubes then
			return
		end
		for _, player in Players:GetPlayers() do
			local model = cubes:FindFirstChild("Cube_" .. player.UserId)
			local root = model and model:IsA("Model") and model.PrimaryPart
			if root then
				-- The server owns every cube. A client owns only its own.
				if isServer or player == localPlayer then
					readInput(root, player)
				end
				drive(root, dt)
			end
		end
	end, Enum.StepFrequency.Hz60)
end

return CubeSim
```

Set `.Name` on every InputAction. The sim finds them with
`ctx:FindFirstChild("Steer")` — an unnamed action is invisible to the brain, and the cube
simply won't move.

**Use InputActions, not RemoteEvents.** InputActions replicate *and roll back*. A
RemoteEvent is a message that arrives whenever it arrives; there is no shared timeline, so
the server and your client's rollback can't agree on when you pressed the key.

### Step 4 — Build a camera, and feed its direction in as input

Server Authority has no `PlayerModule` in a characterless place. `CameraType = Custom` does
nothing, no controller ever runs, and the camera sits near the origin. Confirm it:

```lua
print(Players.LocalPlayer.PlayerScripts:GetChildren())
--> { RbxCharacterSounds }
```

So you build the camera. `ReplicatedFirst/CubeClient.local.luau`:

```lua
--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

if not game:IsLoaded() then
	game.Loaded:Wait()
end
local player = Players.LocalPlayer

local CubePresent = require(ReplicatedFirst:WaitForChild("CubePresent"))
CubePresent.Initialize()
require(ReplicatedFirst:WaitForChild("CubeSim")).Initialize() -- the SAME brain, client side

local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable -- without this, your CFrame is overwritten

local CAM_HEIGHT = 6
local CAM_SMOOTH = 0.12 -- follow lag (s)
local CAM_SENS = 0.006 -- mouse radians per pixel
local PITCH_MIN, PITCH_MAX = math.rad(-70), math.rad(35)
local ZOOM_MIN, ZOOM_MAX = 12, 80

local yaw, pitch, zoom = 0, math.rad(-18), 34
local focus: Vector3? = nil
local focusVel = Vector3.zero
local orbiting = false

UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
	if not processed and input.UserInputType == Enum.UserInputType.MouseButton2 then
		orbiting = true
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
	end
end)
UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		orbiting = false
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
end)
UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseMovement and orbiting then
		yaw -= input.Delta.X * CAM_SENS
		pitch = math.clamp(pitch - input.Delta.Y * CAM_SENS, PITCH_MIN, PITCH_MAX)
	elseif input.UserInputType == Enum.UserInputType.MouseWheel then
		zoom = math.clamp(zoom - input.Position.Z * 4, ZOOM_MIN, ZOOM_MAX)
	end
end)

local function myRoot(): BasePart?
	local cubes = workspace:FindFirstChild("Cubes")
	local model = cubes and cubes:FindFirstChild("Cube_" .. player.UserId)
	return model and (model :: Model).PrimaryPart or nil
end

RunService:BindToRenderStep("CubeCamera", Enum.RenderPriority.Camera.Value, function(dt: number)
	local root = myRoot()
	if not root then
		return
	end

	-- Follow the SMOOTHED copy. The truth is the thing that snaps on a correction, and a
	-- camera pointed at it turns every correction into a flick of the whole screen.
	local follow = CubePresent.GetSmoothed(root) or root
	local target = follow.Position + Vector3.new(0, CAM_HEIGHT, 0)
	if not focus then
		focus = target -- snap on frame 1, or it sails in from the world origin
	end
	focus, focusVel = CubePresent.damp(focus :: Vector3, target, focusVel, CAM_SMOOTH, math.min(dt, 0.05))

	local dir = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	local eye = (focus :: Vector3) + dir:VectorToWorldSpace(Vector3.new(0, 0, zoom))
	camera.CFrame = CFrame.lookAt(eye, focus :: Vector3)
end)

-- FEED THE CAMERA DIRECTION IN AS AN INPUT.
--
-- The simulation cannot read workspace.CurrentCamera: the server hasn't got one, and a
-- replayed step needs the direction AS IT WAS on that frame. So it arrives like any other
-- input -- fire on change, plus a slow keep-alive.
local playContext = player:WaitForChild("PlayContext")
local cameraDir = playContext:WaitForChild("CameraDir")
local lastFired = Vector3.zero
local sinceFire = 0
RunService.RenderStepped:Connect(function(dt: number)
	local dir = camera.CFrame.LookVector
	sinceFire += dt
	if (dir - lastFired).Magnitude > 0.02 or sinceFire > 0.5 then
		cameraDir:Fire(dir)
		lastFired = dir
		sinceFire = 0
	end
end)
```

`camera.CameraType = Enum.CameraType.Scriptable` is load-bearing. Without it, something
else writes `camera.CFrame` after you do, every frame, and your camera silently does
nothing.

That file requires `CubePresent`, which you write in Part 3. To test Part 1 on its own,
comment out the two `CubePresent` lines and use `root` directly as the camera's `follow`.

**Check — and this is the Part 1 milestone.** Run **Test → Server & Clients**, not `Play`.
Press W. The cube moves, for everyone, in the direction you're facing — after a delay you
can feel. That delay is correct at this stage. It's what Part 2 removes.

Measured: the cube settles at a rock-steady **19.1 studs/s** against a `TARGET_SPEED` of 24,
and reads `Predicted`.

That gap is the servo telling you the truth. The gap term alone settles wherever its pull
balances floor friction, so it always cruises a little under target. Chapter 2's cake adds
a **feed-forward** term sized against `µ × gravity` to close it — which is why that term
exists at all, and why it is the first thing to reach for if your character feels
underpowered.

> **You will see this warning, and it is harmless:**
> `Infinite yield possible on 'Workspace.Cubes.Cube_…:WaitForChild("Humanoid")'`
>
> A Roblox core script reacts to `player.Character` being set by going looking for a
> Humanoid. There isn't one, and there is not meant to be one. Nothing in your game is
> waiting on it.

### What `BindToSimulation` cares about

The netcode does not care what shape your character is or how many parts it has. It cares
that inputs come in, and that something moves the character inside the simulation step.
Chapter 2 keeps this exact servo and hangs a stack of loose ball sockets off it.

> **`BindToSimulation` defaults to `Enum.StepFrequency.Hz30`. The physics world runs at
> 60 Hz.** The servo reads a velocity and writes a force every step, so at the default it
> is correcting half as often as the world it is correcting against.
>
> The knob is an optional second argument, and it takes an enum, not a number:
>
> ```lua
> RunService:BindToSimulation(fn, Enum.StepFrequency.Hz60)
> -- Hz60 | Hz30 (default) | Hz15 | Hz10 | Hz5 | Hz1
> ```
>
> Raising it costs client CPU, so weigh it against your frame budget. Don't assume the
> presentation layer will cover for a low bind rate — smoothing narrows the steps, it does
> not remove them.

At the end of Part 1 you have a character the server owns, everyone can see, and nobody can
cheat. It also has input lag, which is Part 2.

---

## Part 2 — client prediction

Any input has to make a round trip — client → server → back to every client — before you
see the effect. Ping, replication rate and frame rate all add to that delay.

Inputs the server has already processed show up as changes to the character. Inputs you've
fired that it hasn't confirmed yet are **in flight**.

Those unconfirmed inputs are what make **resimulation** possible, and resimulation is what
hides the latency.

### What resimulation does

Say you spend a day moving furniture around your house, then go out. While you're gone,
your friends carry every piece back to where it started, then repeat all of your moves in
order until the house is exactly as you left it. You come home and can't tell.

That is resimulation, inside a single frame.

It rests on one idea: **given the same starting physics state, the same inputs, and the same
amount of time, the simulation produces the same result.**

When a fresh authoritative view arrives from the server, your client still holds a tail of
recent inputs the server hadn't seen when it produced that view. So the client:

1. Snaps the world back to the new authoritative server state.
2. Replays your `BindToSimulation` step once for every still-unconfirmed input frame,
   fast-forwarding to the present.

The client lands back in the present, starting from the server's truth, with all your newer
input applied. This very effectively hides all of your input latency.

### Step 5 — Run the same brain on the client

There is no "predict me" switch. You already did the work, in three places:

- `CubeSim` is a module, and **`CubeClient` requires and initialises the same file**
  (Step 4). One brain, two machines.
- Intent lives in **attributes**, which roll back with resimulation.
- `ReplicationFocus` and `player.Character` are set (Step 2), which is what gives the
  engine a centre to predict from.

That's the whole of Part 2 for this cube.

**Check:** press W under Server & Clients. The cube moves *immediately*, and a second client
still sees your cube in the right place. If it feels like a round trip, check the two lines
from Step 2 before anything else.

### Mispredicts

When the replay lands somewhere different from where the client already was, that's a
**mispredict**. Raw, it looks like a stutter or a teleport.

Three things to know:

1. **Mispredicts are a cost of doing business.** Minimise them; they are not all bugs.
2. **Most of the visual disruption is hideable** with the presentation layer in Part 3.
3. **Some are useful.** Only the server can decide a rocket hit you. Your client
   mispredicts the knockback and still ends up in the right place on the right trajectory.

Remember — there's always another authoritative view arriving a split second later, giving
the client another chance to correct. With Part 3 in place, the player sees none of it.

### The rules that keep it deterministic

Your movement code re-runs on every resimulation, and it re-runs often — in single-process
testing it is normal to see more replayed steps than live ones. So inside
`BindToSimulation`:

1. **Read time from `dt` or the global `time()`, and nothing else.** Most clocks are traps
   (`os.time`, `tick`, `os.clock`, `DistributedGameTime`): they keep ticking through a
   replay and stop agreeing with `dt`, and that disagreement *is* a misprediction you built
   by hand. The global `time()` is safe — under Server Authority it is synchronized across
   machines and rolls back with resimulation, so inside a replayed step it reports the
   simulated frame's time. Use it, or accumulate `dt` into an attribute. Both replay
   identically.
2. **No randomness**, unless the seed rolls back too.
3. **No side effects on a replayed step.** Don't play a sound or spawn a particle — it
   already happened the first time. Fire effects from render code off state *transitions*,
   or guard them with `RunService:IsResimulating()`.
4. **No instance creation** without reading the section on Instance Stitching in the Server
   Authority docs.

`CubeSim` obeys all four, which is the only reason prediction works on it. Chapter 2 shows
what obeying them costs on a character with clocks, timers and state.

**Check how often it replays.** Log `RunService:IsResimulating()` inside the step for a few
seconds and count. Replays should be common — comparable to live steps or more. If they're
rare, you probably aren't predicting at all.

At the end of Part 2 your character responds instantly and is still fully server-owned.
What's left is that the truth **snaps** when a guess turns out wrong. That's Part 3.

---

## Part 3 — a presentation layer

Most frames, resimulation lands exactly where the client already was, and nothing is
visible. When it doesn't, the correction is abrupt.

Here is the rule:

> The physics and instance positions of server-owned instances inside the datamodel are the
> **truth**. It has no consideration for visual fluidity, but it is correct.

So the simplest way to add visual fluidity is to hide the authoritative version entirely on
the client. You then show the player a second copy created entirely on the client, and use
critically damped springs to smooth the positions and rotations into place.

That is the whole job of Part 3: keep the authoritative character invisible, keep a visible
presentation copy of it on the client, and move the visible one toward the authoritative
truth every frame.

There's a small catch: be careful not to let the visual-only copies get pulled into the
simulation, collision, raycasts or other game logic. It's an easy mistake to make, and
Step 6 covers exactly how it bites.

### Step 6 — Build the visual layer

`ReplicatedFirst/CubePresent.luau`:

```lua
--!strict
-- CubePresent -- the visual layer.
--
-- Copy A: the authoritative part. Replicated, simulated, and locally INVISIBLE.
-- Copy B: a client-only, anchored clone. A picture. Never simulated; we set its CFrame.
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local CubePresent = {}

local SMOOTH_TIME = 0.06 -- position follow (s). Higher = smoother, and laggier.
local ROT_TIME = 0.07 -- rotation follow (s). A hair slower reads as weight.
local LEAD = 0.05 -- aim ahead of the truth, or the copy trails on a rubber band
local SNAP_DIST = 24 -- past this, teleport. Smoothing a teleport looks like a bug.
local DT_CLAMP = 0.05 -- one hitched frame must not fling the copy across the room

-- Critically-damped spring toward `tgt`. `st` is roughly the time to arrive.
-- Returns (newPos, newVel); thread `vel` back in on the next call.
function CubePresent.damp(cur: Vector3, tgt: Vector3, vel: Vector3, st: number, dt: number): (Vector3, Vector3)
	st = math.max(st, 1e-4)
	local omega = 2 / st
	local e = math.exp(-omega * dt)
	local change = cur - tgt
	local temp = (vel + change * omega) * dt
	return tgt + (change + temp) * e, (vel - temp * omega) * e
end

type Follow = {
	truth: BasePart,
	copy: BasePart,
	pos: Vector3, -- the smoothed position we render at
	vel: Vector3, -- spring velocity, threaded back into damp()
}

local follows: { [BasePart]: Follow } = {}
local folder: Folder? = nil

local function visualsFolder(): Folder
	if folder and folder.Parent then
		return folder :: Folder
	end
	local f = Instance.new("Folder")
	f.Name = "Presentation"
	f.Parent = workspace
	folder = f
	return f
end

local function adopt(truth: BasePart)
	if follows[truth] then
		return
	end

	local copy = truth:Clone()

	-- STRIP THE TAGS FIRST, and this is not optional: a clone inherits the tags of the
	-- thing it copied. The copy would arrive already tagged "Presented", we would present
	-- IT, that copy would arrive tagged too, and the layer eats itself.
	for _, tag in CollectionService:GetTags(copy) do
		CollectionService:RemoveTag(copy, tag)
	end

	copy.Anchored = true
	copy.CanCollide = false
	copy.CanQuery = false -- READ THE NOTE. Client-only parts default to TRUE.
	copy.CanTouch = false
	copy.Massless = true
	copy.CFrame = truth.CFrame
	copy.Name = truth.Name .. "_Visual"
	copy.Parent = visualsFolder()

	-- Hide the truth, on THIS CLIENT ONLY. LocalTransparencyModifier is client-side: the
	-- server's copy is untouched and nobody else's view changes.
	truth.LocalTransparencyModifier = 1

	follows[truth] = {
		truth = truth,
		copy = copy,
		pos = truth.Position,
		vel = Vector3.zero,
	}
end

local function abandon(truth: BasePart)
	local f = follows[truth]
	if not f then
		return
	end
	f.copy:Destroy()
	if f.truth.Parent then
		f.truth.LocalTransparencyModifier = 0
	end
	follows[truth] = nil
end

function CubePresent.Initialize()
	-- The entire subscription. One tag in, visual copies out. This file knows nothing
	-- about cubes; it knows about a tag.
	local function consider(inst: Instance)
		if inst:IsA("BasePart") then
			adopt(inst :: BasePart)
		end
	end

	for _, inst in CollectionService:GetTagged("Presented") do
		consider(inst)
	end
	CollectionService:GetInstanceAddedSignal("Presented"):Connect(consider)
	CollectionService:GetInstanceRemovedSignal("Presented"):Connect(function(inst)
		if inst:IsA("BasePart") then
			abandon(inst :: BasePart)
		end
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		dt = math.min(dt, DT_CLAMP)
		local rotAlpha = 1 - math.exp(-dt / ROT_TIME)

		for truth, f in follows do
			if not truth.Parent then
				abandon(truth)
				continue
			end

			-- Aim at where the truth is GOING, not where it is, or smoothing leaves every
			-- moving object trailing behind itself on a rubber band.
			--
			-- The cube is moved by the physics solver, so it just tells us how fast it is
			-- going. Nothing to reconstruct.
			local target = truth.Position + truth.AssemblyLinearVelocity * LEAD

			if (target - f.pos).Magnitude > SNAP_DIST then
				f.pos, f.vel = truth.Position, Vector3.zero -- teleport: don't "smooth" it
			else
				f.pos, f.vel = CubePresent.damp(f.pos, target, f.vel, SMOOTH_TIME, dt)
			end

			f.copy.CFrame = CFrame.new(f.pos) * f.copy.CFrame.Rotation:Lerp(truth.CFrame.Rotation, rotAlpha)
		end
	end)
end

-- The camera should follow the SMOOTHED copy. Tracking the truth means tracking a thing
-- that snaps.
function CubePresent.GetSmoothed(truth: BasePart): BasePart?
	local f = follows[truth]
	return f and f.copy or nil
end

return CubePresent
```

### The one detail that will bite everyone

This is specific to Server Authority, and it is silent:

> **Client-only parts default to `CanQuery = true`.**

Your anchored visual copy is therefore visible to **your own raycasts**, on the client only.
That is geometry the server does not have. Your client is now simulating a world the server
disagrees with, which is the definition of a misprediction.

**The visual layer would silently break the physics it exists to flatter.** Every clone gets
`CanQuery = false` and `CanTouch = false`.

**Check:** raycast down from your cube with the default filter. It hits the floor, not a
visual copy.

### Step 7 — Confirm the layer is doing something

Add a debug toggle that reveals the truth in red, semi-transparent, straight over the
polished copy:

```lua
truth.LocalTransparencyModifier = 0.45
truth.Color = Color3.fromRGB(235, 70, 70)
copy.LocalTransparencyModifier = 0.35
```

**Check — the Part 3 milestone.** With the overlay on, the red truth steps and snaps while
the visible cube glides through it. Tag only **things the physics moves**: anchored scenery
must not be tagged, or you'll pay to lerp a wall toward itself sixty times a second.

### If it still isn't smooth

Don't judge it by eye. Measure the frame-to-frame speed of **the copy the player actually
looks at**, and how much that wobbles around its own average — a steady cube holds its
speed:

```lua
-- client, while driving
local copy = workspace.Presentation.Root_Visual
local last, steps = copy.Position, {}
local conn = game:GetService("RunService").RenderStepped:Connect(function(dt)
	table.insert(steps, (copy.Position - last).Magnitude / math.max(dt, 1e-4))
	last = copy.Position
end)
task.wait(1.5)
conn:Disconnect()
-- then compare each entry against the mean
```

Then work down this list:

**The bind rate.** At the default `Hz30` the truth advances half as often as the world, and
smoothing narrows those steps without removing them. Pass `Enum.StepFrequency.Hz60` and
check it took effect rather than trusting the edit — bind a probe at `Hz60` and see how
often the character moved between steps. A ratio near 1.0 means you are running at 60; near
0.5 means you are still at 30.

**Your frame rate.** Nothing looks smooth at 15 fps, and no amount of reading the code will
fix that. Rule it out first.

**Which layer is at fault.** Comment out `CubePresent.Initialize()` in `CubeClient` and set
`CAM_SMOOTH = 0`. That shows the raw authoritative truth with nothing filtering it, so you
can tell a character problem from a rendering one in about five seconds.

---

## What you have now

A cube that is server-owned, uncheatable, instantly responsive, and smooth — in four files
and about 200 lines. Every idea in the method is in there:

| | |
|---|---|
| **Part 1** | Server spawns it, owns it, moves it inside `BindToSimulation`. Input arrives as InputActions. |
| **Part 2** | The same brain runs on the client. Intent lives in attributes, so it rolls back and replays. |
| **Part 3** | The truth is hidden and a smoothed client-only copy is shown, with `CanQuery = false`. |

The netcode is now finished, and it does not care what your character is. Chapter 2 changes
the character and touches none of the above.

---

**Next:** [Chapter 2 — the cake with noodle arms](02-building-cakeman.md).
