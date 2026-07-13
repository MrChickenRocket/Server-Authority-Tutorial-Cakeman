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
local HOP_STRIDE = 5.5 -- studs travelled per hop. Cadence = TARGET_SPEED / HOP_STRIDE.
local HOP_WINDOW = 0.14 -- fraction of each cycle spent pushing off the ground
local HOP_ACCEL = 520 -- upward accel during that window. It has to beat gravity (196)
-- by a lot, because the window is short -- most of this number is just paying the rent.
local HOP_GROUNDED_VY = 3 -- only push off when he's actually ON something: if he's
-- already rising or falling faster than this, the hop is spent. Without this check he
-- boosts himself in mid-air on every cycle and floats away like a balloon.

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

	-- Advance the hop clock by distance travelled. Stand still and it stops -- the clock
	-- IS the speedometer, so he can't hop on the spot without meaning to.
	local v = base.AssemblyLinearVelocity
	local speed = (v - UP * v.Y).Magnitude
	local hop = (base:GetAttribute("HopPhase") :: number?) or 0
	base:SetAttribute("HopPhase", (hop + speed * dt / HOP_STRIDE) % 1)

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
local function drive(man: Model, base: BasePart)
	local thrust = base:FindFirstChild("Thrust") :: VectorForce?
	local align = base:FindFirstChild("Heading") :: AlignOrientation?
	if not thrust or not align then
		return
	end
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

	-- ...and that's the entire character. Layers, head and arms are never touched by
	-- this code: they're along for the ride, dragged through their sockets by a base
	-- that's going somewhere. All the wobble you see is the physics engine's, for free.
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
				drive(man :: Model, base)
			end
		end
	end)
end

return CakeSim
