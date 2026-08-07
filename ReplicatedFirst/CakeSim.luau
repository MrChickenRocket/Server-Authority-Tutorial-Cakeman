--!strict
-- CakeSim -- locomotion for every player's CakeMan, run through BindToSimulation on
-- both sides. It must stay deterministic, because the step re-runs several times during
-- reconciliation: no wall clocks, no randomness, no instance creation, no effects. Keep
-- time with dt. The global time() is resim-safe if you need it.
--
-- Only the bottom layer is driven. The wobble is what four blocks on loose ball sockets
-- do by themselves, so there is no balance controller, gait, or leg logic in this file.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local CakeSim = {}

-- Tuning lives on the rig as attributes, so you can change how he moves from the Properties
-- panel mid-playtest instead of editing this file. The numbers below are fallbacks for a rig
-- that doesn't carry the attribute.
--
-- Two kinds of attribute are in play here and they must not be confused. These are config:
-- they sit on the Model, the sim only ever reads them, and they never roll back. The intent
-- attributes further down -- Driving, TargetDir, DriveDir, HopPhase -- sit on the base part,
-- are written inside the sim, and do roll back with resimulation.
local DEFAULTS: { [string]: number } = {
	TargetSpeed = 12, -- studs/s the servo holds (a cap, not a motor)
	AccelGain = 6, -- servo stiffness: higher = snappier to target, lower = heavier
	FrictionFF = 30, -- feed-forward accel that breaks the base's drag on the floor. Sliding
	-- needs roughly mu * gravity, and the base is deliberately slippery (mu 0.05, so about
	-- 10), so most of this is eagerness off the line.
	FFTaperEnd = 1.3, -- FF is full at TargetSpeed and fades to zero at this multiple of it.
	-- Untapered it overruns the cap on smooth ground; tapered from zero it feels flat.
	CoastDrag = 2, -- gentle damping when not driving, so he trundles to a stop
	TurnRate = 720, -- degrees/s the facing catches up at. Movement never waits for it, so you
	-- slide off immediately and the cake swings around after. High enough that a camera flick
	-- spins him on the spot and flings the arms out sideways.
	HopStride = 2.75, -- studs travelled per hop. Cadence = TargetSpeed / HopStride
	HopWindow = 0.14, -- fraction of each cycle spent pushing off the ground
	HopAccel = 520, -- upward accel during that window. Has to beat gravity (196) by a lot,
	-- because the window is short.
	HopGroundedVY = 3, -- only push off when he is resting on something. Without this check he
	-- boosts himself in mid-air every cycle and floats away.
	HopMinSpeed = 4, -- the floor the hop clock runs at while driving. A pure distance clock
	-- stops dead the moment he is blocked, so he would stand silent against a wall while the
	-- player mashes a key. Above this speed the clock is distance again.
}

-- Read one tuning value off the rig, falling back to the table above. Read per step rather
-- than cached: it needs no signal connections and leaves no state to survive a rollback, and
-- eleven attribute lookups are nothing next to the totalMass() walk already happening below.
local function tuned(man: Model, name: string): number
	local v = man:GetAttribute(name)
	return if type(v) == "number" then v :: number else DEFAULTS[name]
end

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

-- Owner: read live input, write intent attributes. These replicate and roll back.
local function readInputIntoAttributes(man: Model, base: BasePart, player: Player, dt: number)
	local steer = readAction(player, "Steer")
	local driving = steer.Magnitude > 0.1
	base:SetAttribute("Driving", driving)

	-- Camera-relative steering, recomputed every frame: hold W and swing the camera to
	-- carve a curve. Committing the direction only on key-change feels dead.
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

	-- Advance the hop clock by distance travelled rather than by time: distance resimulates
	-- identically where a wall clock does not, and the cadence tracks his speed with no extra
	-- code. Floored at HopMinSpeed while driving, so being blocked doesn't stop the bounce.
	-- Both terms are rolled-back state, so this replays identically.
	local v = base.AssemblyLinearVelocity
	local speed = (v - UP * v.Y).Magnitude
	if driving then
		speed = math.max(speed, tuned(man, "HopMinSpeed"))
	end
	local hop = (base:GetAttribute("HopPhase") :: number?) or 0
	base:SetAttribute("HopPhase", (hop + speed * dt / tuned(man, "HopStride")) % 1)

	-- The facing chases the movement at TurnRate. Movement itself never waits.
	local tdir = base:GetAttribute("TargetDir") :: Vector3?
	if tdir then
		local turn = math.rad(tuned(man, "TurnRate")) * dt
		local cur = base:GetAttribute("DriveDir") :: Vector3?
		if not cur or (cur :: Vector3).Magnitude < 1e-3 then
			base:SetAttribute("DriveDir", tdir)
		else
			base:SetAttribute("DriveDir", slewDir((cur :: Vector3).Unit, tdir, turn))
		end
	end
end

-- Every peer: drive the actuators from the (owner-written) attributes.
local function drive(man: Model, base: BasePart, dt: number)
	local thrust = base:FindFirstChild("Thrust") :: VectorForce?
	local align = base:FindFirstChild("Heading") :: AlignOrientation?
	if not thrust or not align then
		return
	end
	align.Enabled = true

	local driving = base:GetAttribute("Driving") == true
	local moveDir = base:GetAttribute("TargetDir") :: Vector3?
	local faceDir = (base:GetAttribute("DriveDir") :: Vector3?) or moveDir

	-- Thrust hauls the whole stack, not just the base: the layers above hang off it
	-- through the joints, and every one of them is weight the base has to drag.
	local mass = totalMass(man)
	local vFlat = base.AssemblyLinearVelocity
	vFlat = vFlat - UP * vFlat.Y -- servo the horizontal velocity; gravity owns vertical

	local force: Vector3
	if driving and moveDir then
		-- Velocity servo. Feed-forward breaks drag and tapers off past the target, while the
		-- gap term closes to TargetSpeed and goes negative above it, which is what makes it a
		-- cap. Accelerations ramp, and ramps hide corrections.
		local targetSpeed = tuned(man, "TargetSpeed")
		local taperEnd = tuned(man, "FFTaperEnd")
		local along = vFlat:Dot(moveDir)
		local ffScale = math.clamp(1 - (along - targetSpeed) / (targetSpeed * (taperEnd - 1)), 0, 1)
		local ff = moveDir * (tuned(man, "FrictionFF") * ffScale)
		local gap = (moveDir * targetSpeed - vFlat) * tuned(man, "AccelGain")
		force = (ff + gap) * mass
	else
		force = -vFlat * (tuned(man, "CoastDrag") * mass) -- coast to rest, no hard brake
	end

	-- Push off during the early slice of each cycle, and only while he is resting on
	-- something. Everything above the base follows a beat later through the joints, so the
	-- cake squashes on the way up and the cherry keeps going after he lands. That is the
	-- same joint lag that makes him wobble, working vertically.
	local hopPhase = (base:GetAttribute("HopPhase") :: number?) or 0
	local vy = base.AssemblyLinearVelocity.Y
	if driving and hopPhase < tuned(man, "HopWindow") and math.abs(vy) < tuned(man, "HopGroundedVY") then
		force += UP * (tuned(man, "HopAccel") * mass)
	end
	thrust.Force = force

	if faceDir and (faceDir :: Vector3).Magnitude > 1e-3 then
		align.CFrame = CFrame.lookAt(Vector3.zero, faceDir :: Vector3) -- base -Z faces travel
	end

	-- Layers, head and arms are never touched from here. They are dragged through their
	-- sockets by a base that's going somewhere, and the physics engine supplies the wobble.
	--
	-- Punching is deliberately not in this file. CakeSim re-runs during reconciliation, so
	-- it may only read input and write actuator targets. Deciding who hit whom is the
	-- server's job -- see CakePunch.
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
					readInputIntoAttributes(man :: Model, base, player, dt)
				end
				drive(man :: Model, base, dt)
			end
		end
	end)
end

return CakeSim
