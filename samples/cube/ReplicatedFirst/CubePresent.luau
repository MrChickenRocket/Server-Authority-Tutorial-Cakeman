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
