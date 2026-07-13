--!strict
-- Presentation — the visual layer.
--
-- THE IDEA, AND IT IS THE MOST IMPORTANT IDEA IN THE WHOLE PROJECT:
--
--   The physics is the TRUTH. It is authoritative, it is networked, and it is allowed
--   to be ugly. Under Server Authority your client is constantly guessing ahead of the
--   server and being corrected -- a misprediction lands and the truth SNAPS. You cannot
--   smooth that away in the simulation, because the simulation has to stay correct:
--   smooth the physics and you've just made your character wrong.
--
--   So don't touch it. Hide it, and show the player a copy that lags a few milliseconds
--   behind and eases toward it. Corrections land on the truth; the copy glides through
--   them. The player never sees the snap.
--
-- The pipeline:
--
--   Copy A -- the authoritative parts. Replicated, simulated, and locally INVISIBLE
--             (LocalTransparencyModifier = 1, a client-only property: the server's
--             copy is untouched, and nobody else's view changes).
--   Copy B -- a client-only, anchored clone with every constraint stripped out. A pure
--             data carrier. It is never simulated; we set its CFrame every frame.
--
--   Each RenderStepped: SmoothDamp B's position toward A's, with a velocity lead so the
--   smoothing doesn't leave B trailing behind a moving object; slerp B's rotation.
--
-- THE FOOTGUN THAT WILL BITE EVERYONE (and it's a Server Authority footgun specifically):
-- client-only parts default to CanQuery = true. An ANCHORED visual copy is therefore
-- visible to your own raycasts -- on the client only. That's geometry the server does
-- not have, which means your client simulates a world the server disagrees with, which
-- means guaranteed misprediction. The visual layer would silently break the physics it
-- exists to flatter. Every clone here is CanQuery = false and CanTouch = false.
-- (On a bigger project, prefer a collision-group policy -- put all client visuals in a
-- "ClientVisuals" group and mask it out of the group your sim queries with. One central
-- rule beats a flag you have to remember on every new visual you ever add.)
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local UserInputService = game:GetService("UserInputService")

local smoothDamp = require(ReplicatedFirst:WaitForChild("Smoothing")).damp

local Presentation = {}

-- How much the copy lags the truth. This is the ONE tuning decision in the file, and
-- it's a trade: more smoothing hides bigger corrections but puts the picture further
-- behind the physics you're actually colliding with.
local SMOOTH_TIME = 0.06 -- position follow (s) -- the jitter filter
local ROT_TIME = 0.07 -- rotation follow (s) -- a hair slower reads as weight
local LEAD = 0.05 -- velocity feed-forward (s): cancels the trail that smoothing
-- would otherwise leave behind a fast-moving object. Without it, everything moving
-- looks like it's being dragged on a rubber band.
local SNAP_DIST = 24 -- if the truth teleports (respawn, big correction), don't sail
-- gracefully across the map -- give up and snap. Smoothing a teleport looks like a bug.
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
	-- Strip everything that could make it a physical object in its own right. It is a
	-- picture, not a participant.
	for _, d in copy:GetDescendants() do
		if d:IsA("Constraint") or d:IsA("BodyMover") or d:IsA("Attachment") or d:IsA("Script") or d:IsA("LocalScript") then
			d:Destroy()
		end
	end
	copy.Anchored = true
	copy.CanCollide = false
	copy.CanQuery = false -- see the footgun note at the top of this file
	copy.CanTouch = false
	copy.Massless = true
	copy.CastShadow = truth.CastShadow
	copy.LocalTransparencyModifier = 0
	copy.CFrame = truth.CFrame
	copy.Name = truth.Name .. "_Visual"
	copy.Parent = visualsFolder()

	-- Hide the truth -- LOCALLY ONLY. LocalTransparencyModifier is a client-side
	-- property: it changes nothing on the server and nothing for anyone else.
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

local function adoptModel(model: Instance)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			adopt(d)
		end
	end
	model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			adopt(d)
		end
	end)
	model.DescendantRemoving:Connect(function(d)
		if d:IsA("BasePart") then
			abandon(d)
		end
	end)
end

-- Shift+0: show the truth. Red, semi-transparent, straight over the top of the polished
-- copy -- so you can watch the raw physics jitter and correct while the presentation
-- glides. You will use this constantly, and it is the fastest way to convince yourself
-- (or a sceptic) that the smoothing is doing anything at all.
local showTruth = false

function Presentation.Initialize()
	-- Characters.
	task.spawn(function()
		local men = workspace:WaitForChild("CakeMen")
		for _, m in men:GetChildren() do
			adoptModel(m)
		end
		men.ChildAdded:Connect(adoptModel)
	end)

	-- Props. The exact same pipeline -- there is nothing character-specific about any of
	-- this. Anything the physics moves can be presented this way.
	for _, p in CollectionService:GetTagged("Prop") do
		if p:IsA("BasePart") then
			adopt(p)
		end
	end
	CollectionService:GetInstanceAddedSignal("Prop"):Connect(function(p)
		if p:IsA("BasePart") then
			adopt(p)
		end
	end)
	CollectionService:GetInstanceRemovedSignal("Prop"):Connect(function(p)
		if p:IsA("BasePart") then
			abandon(p :: BasePart)
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

			-- Aim at where the truth is GOING, not where it is. Smoothing without this
			-- lead leaves every moving object trailing behind itself.
			local target = truth.Position + truth.AssemblyLinearVelocity * LEAD

			if (target - f.pos).Magnitude > SNAP_DIST then
				f.pos, f.vel = truth.Position, Vector3.zero -- teleport: don't "smooth" it
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

-- The camera should follow the SMOOTHED copy, not the truth. Tracking a wobbling cake
-- directly is nauseating, and tracking a *correcting* one is worse.
function Presentation.GetSmoothed(truth: BasePart): BasePart?
	local f = follows[truth]
	return f and f.copy or nil
end

return Presentation
