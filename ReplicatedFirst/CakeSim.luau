--!strict
-- CakeSim — server-authoritative locomotion for every player's CakeMan, run
-- through BindToSimulation on BOTH sides. Deterministic only: no clocks, no
-- randomness, no instance creation, no effects (the step re-runs ~6x during
-- reconcile).
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local CakeSim = {}

local TARGET_SPEED = 14 -- studs/s the servo holds (a cap, not a motor)
local ACCEL_GAIN = 8 -- servo stiffness: higher = snappier to target
local FRICTION_FF = 55 -- feed-forward accel that breaks ground drag/stiction
local FF_TAPER_END = 1.35 -- FF fades from full at TARGET_SPEED to zero at this multiple:
-- untapered overruns the cap on smooth ground; tapered-from-zero feels flat. The knee keeps the zip.
local COAST_DRAG = 2 -- gentle damping when not driving: glide, never a hard brake
local TURN_RATE = math.rad(300) -- how fast the FACING catches up (movement never waits for it)
local PLATE_LIFT = 45 -- constant upward accel on the plate: holds it level-ish against the socket
local PLATE_DAMP = 8 -- damps plate velocity RELATIVE to the hips -> tips, then settles

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
local function readInputIntoAttributes(hips: BasePart, player: Player, dt: number)
	local steer = readAction(player, "Steer")
	local driving = steer.Magnitude > 0.1
	hips:SetAttribute("Driving", driving)

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
				hips:SetAttribute("TargetDir", move.Unit)
			end
		end
	end

	-- The FACING chases the movement at TURN_RATE. Movement itself never waits:
	-- you strafe immediately, the nose comes around after.
	local tdir = hips:GetAttribute("TargetDir") :: Vector3?
	if tdir then
		local cur = hips:GetAttribute("DriveDir") :: Vector3?
		if not cur or (cur :: Vector3).Magnitude < 1e-3 then
			hips:SetAttribute("DriveDir", tdir)
		else
			hips:SetAttribute("DriveDir", slewDir((cur :: Vector3).Unit, tdir, TURN_RATE * dt))
		end
	end
end

-- EVERY PEER: drive the actuators from the (owner-written) attributes.
local function drive(man: Model, hips: BasePart)
	local thrust = hips:FindFirstChild("Thrust") :: VectorForce?
	local align = hips:FindFirstChild("Heading") :: AlignOrientation?
	if not thrust or not align then
		return
	end
	local driving = hips:GetAttribute("Driving") == true
	local moveDir = hips:GetAttribute("TargetDir") :: Vector3?
	local faceDir = (hips:GetAttribute("DriveDir") :: Vector3?) or moveDir
	local mass = totalMass(man)
	local vFlat = hips.AssemblyLinearVelocity
	vFlat = vFlat - UP * vFlat.Y -- servo the HORIZONTAL velocity; gravity owns vertical

	if driving and moveDir then
		-- Velocity servo: feed-forward breaks drag (tapering to zero past the
		-- target), the gap term closes to TARGET_SPEED and goes NEGATIVE above it,
		-- so it's a cap. Accelerations ramp; ramps hide corrections. Never snap.
		local along = vFlat:Dot(moveDir)
		local ffScale = math.clamp(1 - (along - TARGET_SPEED) / (TARGET_SPEED * (FF_TAPER_END - 1)), 0, 1)
		thrust.Force = (moveDir * (FRICTION_FF * ffScale)
			+ (moveDir * TARGET_SPEED - vFlat) * ACCEL_GAIN) * mass
	else
		thrust.Force = -vFlat * (COAST_DRAG * mass) -- coast to rest, no hard brake
	end

	if faceDir and (faceDir :: Vector3).Magnitude > 1e-3 then
		align.CFrame = CFrame.lookAt(Vector3.zero, faceDir :: Vector3) -- hips -Z faces travel
	end

	-- Plate: constant lift + relative damping = tips with motion, then settles.
	local plate = man:FindFirstChild("Plate") :: BasePart?
	local balance = plate and plate:FindFirstChild("PlateBalance") :: VectorForce?
	if plate and balance then
		local pl = plate :: BasePart
		local force = UP * (PLATE_LIFT * pl.AssemblyMass)
		force -= (pl.AssemblyLinearVelocity - hips.AssemblyLinearVelocity) * (PLATE_DAMP * pl.AssemblyMass)
		balance.Force = force
	end
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
			local hips = man and man:IsA("Model") and man:FindFirstChild("Hips") :: BasePart?
			if hips then
				if isServer or player == localPlayer then
					readInputIntoAttributes(hips, player, dt)
				end
				drive(man :: Model, hips)
			end
		end
	end)
end

return CakeSim
