--!strict
-- CakeGrab — catching things, holding them, and losing them.
--
-- THE SPLIT, and it's the most interesting architectural line in the whole project:
--
--   The LUNGE is predicted. It lives in CakeSim, it's driven by a rolled-back attribute,
--   and your fists fly out the instant you click. No round trip, no lag.
--
--   WHAT YOU CAUGHT is decided here, on the server. And it has to be, for a reason that
--   is not about cheating:
--
--     Attributes cannot hold an Instance reference.
--
--   The whole prediction model rests on state that rolls back, and the only state that
--   rolls back is physics state and attributes. "I am holding THAT box" is a reference,
--   so it cannot live in an attribute, so it cannot roll back, so it cannot be
--   predicted -- not without inventing your own reconciliation for it.
--
--   So we don't fight it. The client predicts the part it CAN (the lunge, the reach, the
--   arm whipping out), and the server owns the part it must (who's holding what). Your
--   lunge is yours; what you're holding is a fact about the world, and facts about the
--   world belong to the server.
--
--   The lag this introduces is real and it is almost invisible, because the fist is
--   already out there before the grab lands.
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local GRAB_RADIUS = 6.5 -- how close the fist must get. Keep it honest -- you have to
-- actually put your hand on the thing -- but be generous, because the fist is on the end
-- of five loose ball sockets and is emphatically NOT a precision instrument. A grab that
-- demands accuracy from a wobbling noodle is a grab that never lands.
-- HOW FAR THE TARGET MAY STRAY BEFORE IT TEARS FREE.
--
-- This MUST be bigger than GRAB_RADIUS, and that is not an obvious constraint until it
-- bites you: if you can grab something at 6.5 studs but the grip snaps at 5.5, then every
-- grab you land is *already* over the breaking distance and tears loose on the very first
-- frame. The grab succeeds and the hold fails, instantly, forever, and it looks for all
-- the world like the grip force is too weak.
--
-- The gap between the two numbers IS the slack in your grip: how far something can drag
-- you before you lose it.
local GRIP_BREAK = 9
local GRIP_MAX_TIME = 12 -- nobody holds anything forever

local menFolder = workspace:WaitForChild("CakeMen")

type Hold = { target: BasePart?, since: number }
local holds: { [AlignPosition]: Hold } = {}

local function fistsOf(man: Model): { BasePart }
	local out = {}
	for _, side in { "L", "R" } do
		local f = man:FindFirstChild("Arm" .. side .. "5")
		if f and f:IsA("BasePart") then
			table.insert(out, f)
		end
	end
	return out
end

-- WHO IS HOLDING THIS THING? Stamped onto the target so the damage code can see it.
--
-- Without this you knock yourself out picking up a box. The grip yanks it toward your
-- fist at speed, it arrives at your face, and the damage code -- which quite reasonably
-- believes that a box travelling at you at 30 studs/s is bad news -- clocks it as a
-- direct hit on your cherry and puts you on the floor. You are killed by your own
-- shopping, every single time, and it looks like the physics has gone mad.
--
-- The GRACE is the other half of it. Clearing the stamp the instant you let go means the
-- box you just hurled is still an inch from your face and instantly counts as an enemy
-- projectile. Give it a moment to leave.
local HELD_GRACE = 0.7

local function stamp(target: BasePart, holder: string?)
	target:SetAttribute("HeldBy", holder)
end

local function release(grip: AlignPosition)
	local hold = holds[grip]
	local target = hold and hold.target
	grip.Enabled = false
	grip.Attachment0 = nil
	holds[grip] = nil

	if target then
		local t = target :: BasePart
		local who = t:GetAttribute("HeldBy")
		task.delay(HELD_GRACE, function()
			-- ...unless somebody else has picked it up in the meantime.
			if t.Parent and t:GetAttribute("HeldBy") == who then
				stamp(t, nil)
			end
		end)
	end
end

-- What can this fist grab? Anything Grabbable that isn't part of ME.
--
-- The self-exclusion is not a nicety: without it, the first thing your fist finds is
-- your own cake -- it's the closest grabbable thing in the world, it's RIGHT THERE -- and
-- you spend the match clutching your own midriff.
local function findTarget(man: Model, fist: BasePart): BasePart?
	local best: BasePart? = nil
	local bestDist = GRAB_RADIUS

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { man } -- never yourself
	params.MaxParts = 24

	for _, part in workspace:GetPartBoundsInRadius(fist.Position, GRAB_RADIUS, params) do
		if not part:IsA("BasePart") or part.Anchored then
			continue
		end
		local victimModel = part:FindFirstAncestorWhichIsA("Model")
		local isPlayer = victimModel ~= nil and victimModel.Parent == menFolder

		local grabbable = CollectionService:HasTag(part, "Grabbable") or isPlayer
		if not grabbable then
			continue
		end

		-- YOU SEIZE THE BODY, NOT THE LIMB.
		--
		-- Grab whatever your fist happened to touch and you will, nine times out of ten,
		-- catch someone's arm -- and an arm on a knocked-out cake is five loose ball
		-- sockets of wet spaghetti. You haul on it, the noodle stretches, and the body
		-- doesn't move an inch. It looks exactly like the grip is too weak. It isn't:
		-- you're pulling on a rope attached to nothing.
		--
		-- So when the thing you touched is a PLAYER, redirect the hold to their root.
		-- Touch any part of a man, carry the whole man.
		local target = if isPlayer then ((victimModel :: Model).PrimaryPart :: BasePart?) else part
		if not target or not target:FindFirstChild("GrabAtt") then
			continue
		end

		local d = (part.Position - fist.Position).Magnitude
		if d < bestDist then
			best, bestDist = target, d
		end
	end
	return best
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()

	for _, m in menFolder:GetChildren() do
		local man = m :: Model
		local root = man.PrimaryPart
		if not root then
			continue
		end
		local reaching = root:GetAttribute("Reaching") == true
		-- A knocked-out cake grabs nothing. He can, however, BE grabbed.
		local downed = root:GetAttribute("Downed") == true

		for _, fist in fistsOf(man) do
			local grip = fist:FindFirstChild("Grip") :: AlignPosition?
			if not grip then
				continue
			end
			local hold = holds[grip]

			if hold and hold.target then
				local target = hold.target :: BasePart
				local gone = not target.Parent or target.Anchored
				-- TENSION. Roblox won't tell you the force inside a constraint, so we
				-- infer it from the only thing it CAN'T hide: the gap. A grip with a
				-- finite MaxForce simply fails to hold something too heavy or too
				-- determined, and the target drifts away from the fist. That drift is
				-- the tension, and when it's too wide, the grip tears.
				--
				-- No breaking-force API, no fake "strength stat" -- just a spring that
				-- isn't strong enough, and a rule about when to admit it.
				local stretch = (target.Position - fist.Position).Magnitude
				if not reaching or downed or gone or stretch > GRIP_BREAK or now - hold.since > GRIP_MAX_TIME then
					release(grip)
				end
			elseif reaching and not downed then
				local target = findTarget(man, fist)
				if target then
					local att = target:FindFirstChild("GrabAtt") :: Attachment
					-- Attachment0 is the TARGET, Attachment1 is the fist: AlignPosition
					-- drags 0 toward 1, and we want the box to come to the hand.
					grip.Attachment0 = att
					grip.Enabled = true
					holds[grip] = { target = target, since = now }
					stamp(target, man.Name) -- "this is mine, don't hit me with it"
				end
			end
		end
	end
end)

print("[CakeGrab] fists armed")
