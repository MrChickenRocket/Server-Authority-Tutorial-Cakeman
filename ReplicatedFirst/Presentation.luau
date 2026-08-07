--!strict
-- Presentation -- the visual layer.
--
-- The physics is the truth: authoritative, networked, and allowed to be ugly. Under
-- Server Authority the client is constantly guessing ahead of the server and being
-- corrected, and when a misprediction lands the truth snaps. Smoothing that away in the
-- simulation is not an option, because the simulation has to stay correct.
--
-- So leave it alone, hide it, and show the player a copy that lags a few milliseconds
-- behind and eases toward it. Corrections land on the truth; the copy glides through them.
--
-- The pipeline:
--
--   Copy A -- the authoritative parts. Replicated, simulated, and locally invisible via
--             LocalTransparencyModifier = 1, a client-only property, so the server's copy
--             is untouched and nobody else's view changes.
--   Copy B -- a client-only anchored clone with every constraint stripped out. Never
--             simulated; we set its CFrame every frame.
--
--   Each RenderStepped: SmoothDamp B's position toward A's with a velocity lead, so the
--   smoothing doesn't leave B trailing behind a moving object, then slerp B's rotation.
--
-- One thing to watch, and it is specific to Server Authority: client-only parts default to
-- CanQuery = true, so an anchored visual copy shows up in your own raycasts on the client
-- only. That is geometry the server does not have, which means the client simulates a world
-- the server disagrees with, which means misprediction. Every clone here is CanQuery = false
-- and CanTouch = false. On a larger project prefer a collision-group policy -- put client
-- visuals in their own group and mask it out of the group the sim queries against -- so it
-- is one central rule rather than a flag to remember on every new visual.
--
-- Anything tagged "Presented" gets a visual copy. This file knows nothing about CakeMen,
-- cakes, boxes or arenas; the server decides what deserves presenting and tags it, so adding
-- a new smoothed thing later never touches this file.
--
-- Tag things the physics moves. Anchored scenery -- walls, floors, pillars -- should not be
-- tagged: it never moves, so there is nothing to smooth and you would be paying to lerp a
-- wall toward itself sixty times a second.
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local UserInputService = game:GetService("UserInputService")

local smoothDamp = require(ReplicatedFirst:WaitForChild("Smoothing")).damp

local PRESENTED_TAG = "Presented"

local Presentation = {}

-- How far the copy lags the truth. This is the one tuning decision in the file, and it is
-- a trade: more smoothing hides bigger corrections but puts the picture further behind the
-- physics you are actually colliding with.
local SMOOTH_TIME = 0.06 -- position follow (s) -- the jitter filter
local ROT_TIME = 0.07 -- rotation follow (s) -- a hair slower reads as weight
local LEAD = 0.05 -- velocity feed-forward (s). Cancels the trail smoothing would otherwise
-- leave behind a fast-moving object; without it everything looks dragged on a rubber band.
local SNAP_DIST = 24 -- if the truth teleports (respawn, big correction), snap rather than
-- sailing across the map. Smoothing a teleport looks like a bug.
local DT_CLAMP = 0.05 -- a hitching frame must not fling the copy across the room

type Follow = {
	truth: BasePart,
	copy: BasePart,
	pos: Vector3,
	vel: Vector3,
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

-- Build the visible copy of one authoritative part.
local function adopt(truth: BasePart)
	if follows[truth] then
		return
	end

	local copy = truth:Clone()

	-- Strip the tags first. A clone inherits the tags of the thing it copied, so ours would
	-- arrive already tagged "Presented", we would present it, that copy would arrive tagged
	-- too, and the layer would feed on itself. It also inherits "Prop", which doubles the
	-- prop count and skews anything that counts props. A visual copy participates in nothing.
	for _, tag in CollectionService:GetTags(copy) do
		CollectionService:RemoveTag(copy, tag)
	end

	-- Strip everything that could make it a physical object in its own right.
	for _, d in copy:GetDescendants() do
		if d:IsA("Constraint") or d:IsA("BodyMover") or d:IsA("Attachment") or d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
	copy.Anchored = true
	copy.CanCollide = false
	copy.CanQuery = false -- see the note at the top of this file
	copy.CanTouch = false
	copy.Massless = true
	copy.CastShadow = truth.CastShadow
	copy.LocalTransparencyModifier = 0
	copy.CFrame = truth.CFrame
	copy.Name = truth.Name .. "_Visual"
	copy.Parent = visualsFolder()

	-- Hide the truth locally only. LocalTransparencyModifier is a client-side property: it
	-- changes nothing on the server and nothing for anyone else.
	truth.LocalTransparencyModifier = 1

	follows[truth] = { truth = truth, copy = copy, pos = truth.Position, vel = Vector3.zero }
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

-- Shift+0 shows the truth: red and semi-transparent, over the top of the smoothed copy, so
-- you can watch the raw physics jitter and correct while the presentation glides. It is the
-- quickest way to check the smoothing is doing what you think it is.
local showTruth = false

function Presentation.Initialize()
	-- The entire subscription. One tag in, visual copies out.
	local function consider(inst: Instance)
		if inst:IsA("BasePart") then
			adopt(inst)
		end
	end

	for _, inst in CollectionService:GetTagged(PRESENTED_TAG) do
		consider(inst)
	end
	CollectionService:GetInstanceAddedSignal(PRESENTED_TAG):Connect(consider)
	CollectionService:GetInstanceRemovedSignal(PRESENTED_TAG):Connect(function(inst)
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

			-- Aim at where the truth is going, not where it is. Smoothing without this lead
			-- leaves every moving object trailing behind itself.
			local target = truth.Position + truth.AssemblyLinearVelocity * LEAD

			if (target - f.pos).Magnitude > SNAP_DIST then
				f.pos, f.vel = truth.Position, Vector3.zero -- teleport: don't smooth it
			else
				f.pos, f.vel = smoothDamp(f.pos, target, f.vel, SMOOTH_TIME, dt)
			end

			f.copy.CFrame = CFrame.new(f.pos) * f.copy.CFrame.Rotation:Lerp(truth.CFrame.Rotation, rotAlpha)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode ~= Enum.KeyCode.Zero then
			return
		end
		if
			not (
				UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			)
		then
			return
		end
		showTruth = not showTruth
		for truth, f in follows do
			truth.LocalTransparencyModifier = if showTruth then 0.45 else 1
			if showTruth then
				truth.Color = Color3.fromRGB(235, 70, 70)
			end
			f.copy.LocalTransparencyModifier = if showTruth then 0.35 else 0
		end
		print("[Presentation] truth view:", showTruth and "ON (red = raw physics)" or "off")
	end)
end

-- The camera should follow the smoothed copy. Tracking a wobbling cake directly is
-- unpleasant to look at, and tracking a correcting one is worse.
function Presentation.GetSmoothed(truth: BasePart): BasePart?
	local f = follows[truth]
	return f and f.copy or nil
end

return Presentation
