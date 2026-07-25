--!strict
-- MINIMAL REPRO -- the shared simulation. Runs on the server AND on each client,
-- through RunService:BindToSimulation at Hz60.
--
-- Every cube is dead-reckoned from the SAME input to the SAME position. The only
-- difference between them is HOW that position is applied to the instance.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local ReproSim = {}

local SPEED = 24 -- studs/second
local ACCEL = 120 -- studs/second^2 -- ramped, never stepped
local UP = Vector3.new(0, 1, 0)

-- World-relative steering. The camera is pinned in this repro and plays no part.
local function moveDirOf(player: Player): Vector3
	local ctx = player:FindFirstChild("PlayContext")
	local action = ctx and ctx:FindFirstChild("Steer")
	local s: Vector2 = action and (action :: any):GetState() or Vector2.zero
	if s.Magnitude < 0.1 then
		return Vector3.zero
	end
	local v = Vector3.new(s.X, 0, -s.Y)
	return if v.Magnitude > 1e-3 then v.Unit else Vector3.zero
end

-- Advance one cube's dead-reckoned state. Identical for all four; only `apply` differs.
local function integrate(part: BasePart, dir: Vector3, dt: number): (Vector3, Vector3)
	local pos = (part:GetAttribute("Pos") :: Vector3?) or part.Position
	local vel = (part:GetAttribute("Vel") :: Vector3?) or Vector3.zero

	local want = dir * SPEED
	local dv = want - vel
	local maxDv = ACCEL * dt
	if dv.Magnitude > maxDv then
		dv = dv.Unit * maxDv
	end
	vel += dv
	pos += vel * dt

	part:SetAttribute("Vel", vel)
	part:SetAttribute("Pos", pos)
	if vel.Magnitude > 1e-3 then
		part:SetAttribute("FaceDir", vel.Unit)
	end
	return pos, vel
end

local function faceCFrame(part: BasePart, pos: Vector3): CFrame
	local face = (part:GetAttribute("FaceDir") :: Vector3?) or Vector3.new(0, 0, -1)
	return CFrame.lookAt(pos, pos + face, UP)
end

local function driveRig(model: Model, player: Player, dt: number)
	local dir = moveDirOf(player)

	-- 1: ALIGNPOSITION + ALIGNORIENTATION on an unanchored part.
	local c1 = model:FindFirstChild("Cube1_AlignPosition") :: BasePart?
	if c1 then
		local pos = integrate(c1, dir, dt)
		local mover = c1:FindFirstChild("Mover") :: AlignPosition?
		local heading = c1:FindFirstChild("Heading") :: AlignOrientation?
		if mover then
			mover.Position = pos
		end
		if heading then
			local face = (c1:GetAttribute("FaceDir") :: Vector3?) or Vector3.new(0, 0, -1)
			heading.CFrame = CFrame.lookAt(Vector3.zero, face, UP)
		end
	end

	-- 2: CFRAME ON AN ANCHORED PART.
	local c2 = model:FindFirstChild("Cube2_AnchoredCFrame") :: BasePart?
	if c2 then
		local pos = integrate(c2, dir, dt)
		c2.CFrame = faceCFrame(c2, pos)
	end

	-- 3: CFRAME ON AN UNANCHORED PART, with the velocities stomped flat every step so
	-- the solver never carries anything over between frames.
	local c3 = model:FindFirstChild("Cube3_UnanchoredCFrame") :: BasePart?
	if c3 then
		local pos = integrate(c3, dir, dt)
		c3.CFrame = faceCFrame(c3, pos)
		c3.AssemblyLinearVelocity = Vector3.zero
		c3.AssemblyAngularVelocity = Vector3.zero
	end

	-- 4: ATTRIBUTE ONLY. The sim never touches this part's CFrame; ReproClient reads
	-- the Pos attribute on RenderStepped and places it there.
	local c4 = model:FindFirstChild("Cube4_AttributeRender") :: BasePart?
	if c4 then
		integrate(c4, dir, dt)
	end
end

function ReproSim.Initialize()
	local isServer = RunService:IsServer()
	local localPlayer = Players.LocalPlayer -- nil on the server

	RunService:BindToSimulation(function(dt: number)
		local folder = workspace:FindFirstChild("Repro")
		if not folder then
			return
		end
		for _, player in Players:GetPlayers() do
			if not (isServer or player == localPlayer) then
				continue
			end
			local model = folder:FindFirstChild("Repro_" .. player.UserId)
			if model and model:IsA("Model") then
				driveRig(model, player, dt)
			end
		end
	end, Enum.StepFrequency.Hz60)
end

return ReproSim
