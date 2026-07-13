--!strict
-- CakeSim — server-authoritative locomotion for every player's CakeMan, run
-- through BindToSimulation on BOTH sides. Deterministic only: no clocks, no
-- randomness, no instance creation, no effects (the step re-runs ~6x during
-- reconcile).
--
-- The whole character is: drive the BOTTOM layer, and let the stack wobble.
-- That's it. There is no balance controller, no gait, no leg logic -- the wobble
-- comes free from four blocks on loose ball sockets, and the physics engine does
-- all of the work we would otherwise have written (badly).
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local CakeSim = {}

local TARGET_SPEED = 12 -- studs/s the servo holds (a cap, not a motor)
local ACCEL_GAIN = 6 -- servo stiffness: higher = snappier to target. Low = heavy
local FRICTION_FF = 30 -- feed-forward accel that breaks the base's drag on the floor.
-- Size it against the friction it has to beat: sliding needs about mu * gravity of
-- acceleration, and his base is deliberately slippery (mu 0.05, so ~10), so this is
-- mostly just eagerness off the line now. It was 115 back when he had a grippy base
-- and had to tear himself free of the floor every step.
local FF_TAPER_END = 1.3 -- FF is full at TARGET_SPEED and fades to zero at this
-- multiple of it. Untapered it overruns the cap on smooth ground; tapered from zero
-- it feels flat. The knee keeps the zip while the cap stays honest.
local COAST_DRAG = 2 -- gentle damping when not driving: he trundles to a stop
local TURN_RATE = math.rad(720) -- how fast the FACING catches up (movement never
-- waits for it: you slide off immediately and the cake swings around after).
-- Cranked right up so he SPINS: flick the camera and he whips round on the spot,
-- and the arms -- which are just noodles with heavy fists, obeying nothing but
-- physics -- get flung out sideways. Nothing animates that. It's free.

-- THE HOP. He has no legs, so he bounces -- little bird hops as he trundles along.
--
-- The clock that drives it advances by DISTANCE TRAVELLED, not by time. This is not a
-- stylistic choice, it's the only thing that works:
--   * it resimulates identically (a wall clock does not -- see the four rules),
--   * and the cadence tracks his speed for free. Slow down and he hops slower, with no
--     extra code. Speed and rhythm can't drift apart, because they're the same number.
local HOP_STRIDE = 2.75 -- studs travelled per hop. Cadence = TARGET_SPEED / HOP_STRIDE.
local HOP_WINDOW = 0.14 -- fraction of each cycle spent pushing off the ground
local HOP_ACCEL = 520 -- upward accel during that window. It has to beat gravity (196)
-- by a lot, because the window is short -- most of this number is just paying the rent.
local HOP_GROUNDED_VY = 3 -- only push off when he's actually ON something: if he's
-- already rising or falling faster than this, the hop is spent. Without this check he
-- boosts himself in mid-air on every cycle and floats away like a balloon.

-- THE WRESTLER'S STANCE.
--
-- Holding the grab button doesn't fire a magnet. It puts your HANDS UP: both fists are
-- hauled to a fixed pose out in front of you -- apart, level, ready -- and they hold
-- there. Only once they've actually ARRIVED do they become live, and then they grab the
-- first thing they touch.
--
-- This is a much better mechanic than "reach out and vacuum up whatever is nearest",
-- which is what it was before. Now grabbing is something you COMMIT to: you put your
-- guard up, and then you have to walk your opponent into your hands. The pose telegraphs
-- to everyone else exactly what you're about to try, which is precisely what you want in
-- a brawler -- your intent is visible on your body, because your body IS the physics.
--
-- WHERE THE POSE ITSELF LIVES: not here. The stance is a pair of attachments (StanceL,
-- StanceR) on the shoulder layer of the rig, and the fists' Reach servo is anchored
-- between the fist and one of them. So the guard is a property of his BODY, baked into
-- the model, and this file only ever decides whether it's UP.
--
-- Which also means the force is honest. A servo that hauls a fist toward a world
-- coordinate pushes against nothing -- the momentum is conjured, the body never rocks
-- back, and the whole thing feels floaty for reasons no player can name. Anchored to the
-- shoulders with ReactionForceEnabled, throwing your hands out shoves your top cake
-- backwards by exactly as much. He pays for his own guard, out of his own posture.

-- THE COMMITMENT. Putting your hands up does NOT grab. For a full second you are just a
-- cake standing there with its guard up, and only then do the hands become live.
--
-- That second is the entire mechanic. It's what makes grabbing a decision rather than a
-- reflex: you must commit before you know whether it'll land, and everyone watching gets
-- a second of warning painted on your body. Take the delay away and grab becomes a
-- twitch-button that always wins; leave it in and it becomes something you can bait, dodge,
-- or punish.
local ARM_DELAY = 1.0

local UP = Vector3.new(0, 1, 0)

local function readAction(player: Player, name: string): Vector2
	local ctx = player:FindFirstChild("PlayContext")
	local action = ctx and ctx:FindFirstChild(name)
	return action and (action :: any):GetState() or Vector2.zero
end

local function readCameraDir(player: Player): Vector3
	local ctx = player:FindFirstChild("PlayContext")
	local action = ctx and ctx:FindFirstChild("CameraDir")
	return action and (action :: any):GetState() or Vector3.zero
end

local function readBool(player: Player, name: string): boolean
	local ctx = player:FindFirstChild("PlayContext")
	local action = ctx and ctx:FindFirstChild(name)
	return action ~= nil and (action :: any):GetState() == true
end

local function totalMass(model: Model): number
	local m = 0
	for _, p in model:GetDescendants() do
		if p:IsA("BasePart") then
			m += p.Mass
		end
	end
	return m
end

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

-- OWNER: read live input -> write intent attributes (these replicate AND roll back).
local function readInputIntoAttributes(base: BasePart, player: Player, dt: number)
	local steer = readAction(player, "Steer")
	local driving = steer.Magnitude > 0.1
	base:SetAttribute("Driving", driving)

	-- Camera-relative steering, recomputed EVERY FRAME: hold W and swing the
	-- camera to carve a curve. (Committing only on key-change feels dead.)
	if driving then
		local camF = readCameraDir(player)
		local fwd = camF - UP * camF.Y -- camera forward, flattened onto the ground plane
		if fwd.Magnitude > 1e-3 then
			fwd = fwd.Unit
			local right = fwd:Cross(UP)
			local move = fwd * steer.Y + right * steer.X
			if move.Magnitude > 1e-3 then
				base:SetAttribute("TargetDir", move.Unit)
			end
		end
	end

	-- Reaching is intent, so it's an attribute like any other: written by the owner,
	-- rolled back with resimulation, read by every peer.
	base:SetAttribute("Reaching", readBool(player, "Grab"))

	-- You AIM A GRAB WITH THE CAMERA, not with your feet. The first version threw the
	-- fists along his drive direction, which is fine while you're running at something
	-- and completely useless when you're standing still next to it -- he'd lunge
	-- confidently at wherever he last happened to be walking. Store where you're LOOKING.
	local camF = readCameraDir(player)
	if camF.Magnitude > 1e-3 then
		base:SetAttribute("LookDir", camF)
	end

	-- Advance the hop clock by distance travelled. Stand still and it stops -- the clock
	-- IS the speedometer, so he can't hop on the spot without meaning to.
	local v = base.AssemblyLinearVelocity
	local speed = (v - UP * v.Y).Magnitude
	local hop = (base:GetAttribute("HopPhase") :: number?) or 0
	base:SetAttribute("HopPhase", (hop + speed * dt / HOP_STRIDE) % 1)

	-- WITH YOUR GUARD UP, YOU FACE WHERE YOU'RE LOOKING. Otherwise he holds his stance out
	-- in whatever direction he last happened to be walking, and you can't aim a grab at
	-- all -- you'd have to jog in a little circle to point yourself at your opponent,
	-- which is exactly as stupid as it sounds. Squaring up to a man is half of grappling.
	if readBool(player, "Grab") and not driving then
		local flat = camF - UP * camF.Y
		if flat.Magnitude > 1e-3 then
			base:SetAttribute("TargetDir", flat.Unit)
		end
	end

	-- The FACING chases the movement at TURN_RATE. Movement itself never waits.
	local tdir = base:GetAttribute("TargetDir") :: Vector3?
	if tdir then
		local cur = base:GetAttribute("DriveDir") :: Vector3?
		if not cur or (cur :: Vector3).Magnitude < 1e-3 then
			base:SetAttribute("DriveDir", tdir)
		else
			base:SetAttribute("DriveDir", slewDir((cur :: Vector3).Unit, tdir, TURN_RATE * dt))
		end
	end
end

-- EVERY PEER: drive the actuators from the (owner-written) attributes.
local function drive(man: Model, base: BasePart, dt: number)
	local thrust = base:FindFirstChild("Thrust") :: VectorForce?
	local align = base:FindFirstChild("Heading") :: AlignOrientation?
	if not thrust or not align then
		return
	end

	-- KNOCKED OUT.
	--
	-- The ragdoll is not a system. There is no second rig, no animation, no "enter
	-- ragdoll state" -- there is only this: STOP HOLDING HIM UP.
	--
	-- Two things hold a CakeMan together, and being knocked out takes away both:
	--   * the `Heading` servo -- the ONE actively-oriented part in the whole character,
	--     the thing every loose ball socket above it is hanging off. Disable it and
	--     nothing is keeping him upright any more.
	--   * the JOINT TONE -- MaxFrictionTorque, which is what makes his sockets doughy
	--     rather than free. Take it to zero and open the cone limits, and the stack goes
	--     genuinely limp: the layers slide off each other, the cherry lolls, the arms
	--     drag. He doesn't fall over so much as give up.
	--
	-- Both of those are properties we already had. Being unconscious is just being
	-- honest about the physics.
	local downed = base:GetAttribute("Downed") == true
	for _, d in man:GetDescendants() do
		if d:IsA("BallSocketConstraint") then
			local j = d :: BallSocketConstraint
			j.MaxFrictionTorque = if downed then 0 else (j:GetAttribute("RestFriction") :: number? or 0)
			j.UpperAngle = if downed then 75 else (j:GetAttribute("RestAngle") :: number? or 6)
		end
	end
	if downed then
		align.Enabled = false
		thrust.Force = Vector3.zero
		return
	end
	align.Enabled = true
	local driving = base:GetAttribute("Driving") == true
	local moveDir = base:GetAttribute("TargetDir") :: Vector3?
	local faceDir = (base:GetAttribute("DriveDir") :: Vector3?) or moveDir

	-- Thrust must haul the WHOLE stack, not just the base: the layers above hang off
	-- it through the joints and every one of them is dead weight the base has to drag.
	local mass = totalMass(man)
	local vFlat = base.AssemblyLinearVelocity
	vFlat = vFlat - UP * vFlat.Y -- servo the HORIZONTAL velocity; gravity owns vertical

	local force: Vector3
	if driving and moveDir then
		-- Velocity servo: feed-forward breaks drag (tapering off past the target),
		-- while the gap term closes to TARGET_SPEED and goes NEGATIVE above it, so
		-- it's a cap. Accelerations ramp; ramps hide corrections. Never snap.
		local along = vFlat:Dot(moveDir)
		local ffScale = math.clamp(1 - (along - TARGET_SPEED) / (TARGET_SPEED * (FF_TAPER_END - 1)), 0, 1)
		force = (moveDir * (FRICTION_FF * ffScale)
			+ (moveDir * TARGET_SPEED - vFlat) * ACCEL_GAIN) * mass
	else
		force = -vFlat * (COAST_DRAG * mass) -- coast to rest, no hard brake
	end

	-- The hop. Push off during the early slice of each cycle, and only while he's
	-- actually resting on something. Everything above the base is dragged into the air
	-- a beat later through the joints -- so the cake squashes on the way up and the
	-- cherry keeps going after he lands. None of that is animated. It's the same lag
	-- that makes him wobble, now working vertically.
	local hopPhase = (base:GetAttribute("HopPhase") :: number?) or 0
	local vy = base.AssemblyLinearVelocity.Y
	if driving and hopPhase < HOP_WINDOW and math.abs(vy) < HOP_GROUNDED_VY then
		force += UP * (HOP_ACCEL * mass)
	end
	thrust.Force = force

	if faceDir and (faceDir :: Vector3).Magnitude > 1e-3 then
		align.CFrame = CFrame.lookAt(Vector3.zero, faceDir :: Vector3) -- base -Z faces travel
	end

	-- HANDS UP.
	--
	-- Hold the button and both fists are hauled into the wrestler's stance and held
	-- there. A fist becomes ARMED once it has actually ARRIVED (or once you've been
	-- holding long enough that we stop waiting for it) -- and an armed fist grabs the
	-- first thing it TOUCHES. Not the nearest thing in a radius: the thing it touches.
	--
	-- All of this is PREDICTED -- it's in the sim, driven by rolled-back attributes -- so
	-- your guard goes up the instant you click, with no round trip. Whether you then
	-- caught anything is a question only the server can answer (see CakeGrab). Your pose
	-- is yours; what's in your hands is a fact about the world, and facts about the world
	-- belong to the server.
	local reaching = base:GetAttribute("Reaching") == true

	-- How long the guard has been up. Accumulated by dt into a rolled-back attribute --
	-- which is the only kind of clock the simulation is allowed to have.
	local held = (base:GetAttribute("GuardTime") :: number?) or 0
	held = if reaching then held + dt else 0
	base:SetAttribute("GuardTime", held)

	for _, side in { "L", "R" } do
		local fist = man:FindFirstChild("Arm" .. side .. "5") :: BasePart?
		local reach = fist and fist:FindFirstChild("Reach") :: AlignPosition?
		local grip = fist and fist:FindFirstChild("Grip") :: AlignPosition?
		if not fist or not reach then
			continue
		end

		-- Don't fight your own grip: once you've caught something, stop posing at it.
		local holding = grip ~= nil and (grip :: AlignPosition).Enabled
		local guarding = reaching and not holding
		;(reach :: AlignPosition).Enabled = guarding

		-- And that's the whole pose. THE SIMULATION NO LONGER KNOWS WHERE THE HANDS GO --
		-- it just says whether the guard is up. Reach is anchored between the fist and a
		-- StanceL/StanceR attachment on the shoulder layer, so the target rides the top
		-- cake's own frame: it leans when he leans, and the shoulders stay square to the
		-- hands without a line of CFrame maths in here. (It used to recompute a world
		-- position every step. Every step of that was a chance for the pose and the body to
		-- disagree, and one of them did.)

		-- ARMED IS PURELY THE CLOCK. Not "has the fist arrived" -- a noodle arm on five
		-- ball sockets arrives when it feels like it, and gating a player's input on that
		-- means the grab fires at a different moment every time, for reasons invisible to
		-- them. One second, every time, whatever the arms are doing. Predictable beats
		-- physical.
		base:SetAttribute("Armed" .. side, guarding and held >= ARM_DELAY)
	end

	-- ...and that's the entire character. Layers, head and arms are never touched by
	-- this code otherwise: they're along for the ride, dragged through their sockets by
	-- a base that's going somewhere. All the wobble is the physics engine's, for free.
end

function CakeSim.Initialize()
	local isServer = RunService:IsServer()
	local localPlayer = Players.LocalPlayer -- nil on the server
	RunService:BindToSimulation(function(dt: number)
		local men = workspace:FindFirstChild("CakeMen")
		if not men then
			return
		end
		for _, player in Players:GetPlayers() do
			local man = men:FindFirstChild("CakeMan_" .. player.UserId)
			local base = man and man:IsA("Model") and man:FindFirstChild("Layer1") :: BasePart?
			if base then
				if isServer or player == localPlayer then
					readInputIntoAttributes(base, player, dt)
				end
				drive(man :: Model, base, dt)
			end
		end
	end)
end

return CakeSim
