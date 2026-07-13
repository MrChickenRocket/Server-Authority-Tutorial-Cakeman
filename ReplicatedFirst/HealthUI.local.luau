--!strict
-- HealthUI — a health bar over every CakeMan.
--
-- Render-only, client-only, and it reads state it never writes. It touches no physics,
-- creates nothing the server knows about, and if you deleted this file the game would
-- play identically -- you just couldn't see who was winning. That's the correct shape
-- for a UI layer, and it's worth being strict about: the moment a health bar starts
-- *deciding* anything, you've split your authority in two.
--
-- Note where the bar is parented: to the SMOOTHED presentation copy, not to the
-- authoritative part. Pin it to the truth and the bar jitters and snaps with every
-- correction, which is a great way to make a perfectly good netcode look broken.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

local Presentation = require(ReplicatedFirst:WaitForChild("Presentation"))

local localPlayer = Players.LocalPlayer
local MAX_HEALTH = 100

local GOOD = Color3.fromRGB(96, 200, 106)
local HURT = Color3.fromRGB(232, 190, 70)
local BAD = Color3.fromRGB(222, 74, 74)
local OUT = Color3.fromRGB(120, 120, 130)

-- Remember what the label SAYS when nothing is wrong, so that a temporary state ("OUT
-- COLD") has something to go back to. A UI that overwrites its own resting text and then
-- never restores it will happily tell you someone is out cold for the rest of the round.
type Bar = {
	root: BasePart,
	gui: BillboardGui,
	fill: Frame,
	label: TextLabel,
	name: string, -- what the label reads when he's on his feet
	color: Color3,
}
local bars: { [Model]: Bar } = {}

local function build(man: Model): Bar?
	local root = man.PrimaryPart or man:FindFirstChild("Layer1") :: BasePart?
	if not root then
		return nil
	end
	-- Follow the smoothed copy if it exists (it will) -- never the raw physics.
	local anchor = Presentation.GetSmoothed(root) or root

	local gui = Instance.new("BillboardGui")
	gui.Name = "HealthBar"
	gui.Size = UDim2.fromOffset(150, 30)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 11, 0) -- well clear of the cherry, which
	-- is itself on a wobbly stem and will happily headbutt a bar you've hung too low
	gui.AlwaysOnTop = true
	gui.MaxDistance = 200
	gui.Adornee = anchor
	gui.Parent = anchor

	local back = Instance.new("Frame")
	back.Size = UDim2.new(1, 0, 0, 10)
	back.Position = UDim2.new(0, 0, 0, 14)
	back.BackgroundColor3 = Color3.fromRGB(30, 30, 36)
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = GOOD
	fill.BorderSizePixel = 0
	fill.Parent = back

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 0, 14)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextStrokeTransparency = 0.4
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Text = man.Name
	label.Parent = gui

	-- Your own bar says so, because in a four-way brawl full of identical cakes you will
	-- absolutely lose track of which one you are.
	local id = tonumber(string.match(man.Name, "%d+") or "")
	if id == localPlayer.UserId then
		label.Text = "YOU"
		label.TextColor3 = Color3.fromRGB(255, 236, 140)
	end

	return { root = root, gui = gui, fill = fill, label = label, name = label.Text, color = label.TextColor3 }
end

RunService.RenderStepped:Connect(function()
	local men = workspace:FindFirstChild("CakeMen")
	if not men then
		return
	end

	for _, m in men:GetChildren() do
		local man = m :: Model
		if not bars[man] then
			local b = build(man)
			if b then
				bars[man] = b
			end
		end
	end

	for man, bar in bars do
		if not man.Parent or not bar.root.Parent then
			bar.gui:Destroy()
			bars[man] = nil
			continue
		end
		local hp = (bar.root:GetAttribute("Health") :: number?) or MAX_HEALTH
		local downed = bar.root:GetAttribute("Downed") == true
		local frac = math.clamp(hp / MAX_HEALTH, 0, 1)

		bar.fill.Size = UDim2.fromScale(frac, 1)
		bar.fill.BackgroundColor3 = if downed
			then OUT
			elseif frac > 0.55 then GOOD
			elseif frac > 0.25 then HURT
			else BAD

		-- Both branches, always. The bug this replaces only had the first one, so the
		-- label went to OUT COLD and stayed there forever -- the man got up, walked off
		-- and carried on brawling with a sign over his head insisting he was unconscious.
		-- Any UI that writes a state must also write its way back out of it.
		if downed then
			local left = (bar.root:GetAttribute("DownedFor") :: number?) or 0
			bar.label.Text = string.format("OUT COLD (%.1f)", left)
			bar.label.TextColor3 = OUT
		else
			bar.label.Text = bar.name
			bar.label.TextColor3 = bar.color
		end
	end
end)
