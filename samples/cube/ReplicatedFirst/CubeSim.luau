--!strict
-- CubeSim -- the whole character. Runs through BindToSimulation on BOTH machines.
--
-- The contract: the OWNER (the server for all cubes, a client for its own) reads live
-- input and writes intent as ATTRIBUTES. EVERY PEER then drives the actuators from those
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
--
-- We never write CFrame and we never write velocity. Setting a velocity every step would
-- mean the character is not really being simulated -- and an anchored part, which is the
-- other way to take the transform into your own hands, is excluded from client prediction
-- altogether (see samples/repro). Let the solver move it and Server Authority can see it.
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

	-- Hz60, NOT the default. BindToSimulation defaults to Enum.StepFrequency.Hz30 while
	-- the physics world runs at 60. The servo reads a velocity and writes a force every
	-- step, so at the default it is correcting half as often as the world it is correcting
	-- against. Costs client CPU; measure before you decide you need it.
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
