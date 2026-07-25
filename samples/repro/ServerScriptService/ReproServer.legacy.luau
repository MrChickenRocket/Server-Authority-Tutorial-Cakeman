--!strict
-- MINIMAL REPRO -- Server Authority, four ways to move a character.
--
-- Workspace.AuthorityMode = Server. Players.CharacterAutoLoads = false. No Humanoid.
-- Four cubes read the SAME Steer InputAction and move at the same speed. The camera is
-- pinned and steering is world-relative, so nothing depends on view direction.
--
--   Cube1  AlignPosition + AlignOrientation on an UNANCHORED part (solver moves it)
--   Cube2  CFrame written directly to an ANCHORED part
--   Cube3  CFrame written to an UNANCHORED part, velocities stomped to zero each step
--   Cube4  sim writes a Pos ATTRIBUTE only; the client sets CFrame from it on RenderStepped
--
-- Each cube is labelled live with RunService:GetPredictionStatus() as seen by the
-- OWNING CLIENT. Expected: all four are the local player's own server-owned character
-- parts and should be Predicted. Observed: only the UNANCHORED ones are.
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

Players.CharacterAutoLoads = false

local SIZE = Vector3.new(4, 4, 4)
local Y = 4
local SPACING = 12

local SPECS = {
	{ name = "Cube1_AlignPosition", color = Color3.fromRGB(80, 200, 120), anchored = false },
	{ name = "Cube2_AnchoredCFrame", color = Color3.fromRGB(230, 90, 80), anchored = true },
	{ name = "Cube3_UnanchoredCFrame", color = Color3.fromRGB(240, 180, 60), anchored = false },
	{ name = "Cube4_AttributeRender", color = Color3.fromRGB(90, 170, 240), anchored = true },
}

local folder = Instance.new("Folder")
folder.Name = "Repro"
folder.Parent = workspace

local function buildInputContext(player: Player)
	if player:FindFirstChild("PlayContext") then
		return
	end
	local ctx = Instance.new("InputContext")
	ctx.Name = "PlayContext"
	ctx.Enabled = true

	local steer = Instance.new("InputAction")
	steer.Name = "Steer"
	steer.Type = Enum.InputActionType.Direction2D
	steer.Parent = ctx

	local kb = Instance.new("InputBinding")
	kb.Name = "Keyboard"
	kb.Up, kb.Down = Enum.KeyCode.W, Enum.KeyCode.S
	kb.Left, kb.Right = Enum.KeyCode.A, Enum.KeyCode.D
	kb.Parent = steer

	ctx.Parent = player
end

local function label(part: BasePart, text: string)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Size = UDim2.fromScale(10, 2.2)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
	bb.AlwaysOnTop = true
	bb.Parent = part

	local t = Instance.new("TextLabel")
	t.Name = "Text"
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 0.35
	t.BackgroundColor3 = Color3.new(0, 0, 0)
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextScaled = true
	t.Font = Enum.Font.Code
	t.Text = text
	t.Parent = bb
end

local function spawnRig(player: Player)
	buildInputContext(player)

	local rigName = "Repro_" .. player.UserId
	if folder:FindFirstChild(rigName) then
		return
	end

	local model = Instance.new("Model")
	model.Name = rigName

	for i, spec in SPECS do
		local start = Vector3.new((i - 1) * SPACING, Y, 0)

		local p = Instance.new("Part")
		p.Name = spec.name
		p.Size = SIZE
		p.Color = spec.color
		p.Anchored = spec.anchored
		p.CanCollide = false -- keep the four from ever touching each other
		p.Position = start
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model

		-- Every cube carries its own start point and its dead-reckoned state, so each
		-- variant is driven from identical numbers.
		p:SetAttribute("Start", start)
		p:SetAttribute("Pos", start)
		p:SetAttribute("FaceDir", Vector3.new(0, 0, -1))

		if i == 1 then
			local att = Instance.new("Attachment")
			att.Name = "DriveAtt"
			att.Parent = p

			local mover = Instance.new("AlignPosition")
			mover.Name = "Mover"
			mover.Mode = Enum.PositionAlignmentMode.OneAttachment
			mover.Attachment0 = att
			mover.MaxForce = 1e6
			mover.Responsiveness = 200
			mover.ApplyAtCenterOfMass = true
			mover.Position = start
			mover.Parent = p

			local heading = Instance.new("AlignOrientation")
			heading.Name = "Heading"
			heading.Mode = Enum.OrientationAlignmentMode.OneAttachment
			heading.Attachment0 = att
			heading.MaxTorque = 1e6
			heading.Responsiveness = 200
			heading.CFrame = CFrame.identity
			heading.Parent = p
		end

		label(p, spec.name)

		if i == 1 then
			model.PrimaryPart = p
		end
	end

	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent
	model.Parent = folder

	-- The two lines a Humanoid would normally do for you. Without these nothing near
	-- the player is predicted at all, so they must be set before any of this means
	-- anything.
	player.ReplicationFocus = model.PrimaryPart
	player.Character = model

	print("[Repro] spawned", rigName)
end

Players.PlayerAdded:Connect(spawnRig)
Players.PlayerRemoving:Connect(function(player)
	local m = folder:FindFirstChild("Repro_" .. player.UserId)
	if m then
		m:Destroy()
	end
end)
for _, p in Players:GetPlayers() do
	spawnRig(p)
end

require(ReplicatedFirst:WaitForChild("ReproSim")).Initialize()
print("[Repro] server sim bound")
