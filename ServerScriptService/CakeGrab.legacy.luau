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

-- TOUCH, not proximity.
--
-- The old version swept a big radius around the fist and hoovered up the nearest
-- grabbable thing, which felt like a tractor beam: you waved a hand in the general
-- direction of a box and it leapt into your palm.
--
-- Now the hand has to actually be ON it. This radius is barely bigger than the fist
-- itself -- it's a contact test, not a search. You put your guard up, you walk your man
-- into your hands, and THEN you close them.
local TOUCH_RADIUS = 1.6
-- HOW FAR THE TARGET MAY STRAY BEFORE IT TEARS FREE.
--
-- This MUST be comfortably bigger than the distance you can grab at, and that is not an
-- obvious constraint until it bites you: I once had a grab radius of 6.5 and a break
-- distance of 5.5, so every grab I landed was ALREADY past breaking and tore loose on the
-- very first frame. The grab succeeded and the hold failed, instantly, forever, and it
-- looked exactly like the grip force being too weak.
--
-- The gap between the two IS the slack in your grip: how far something can drag you
-- before you lose it. Now that you have to close your hands ON a thing, that slack can be
-- generous -- you've earned the hold.
local GRIP_BREAK = 7
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
	local bestDist = TOUCH_RADIUS + fist.Size.X

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { man } -- never yourself
	params.MaxParts = 24

	for _, part in workspace:GetPartBoundsInRadius(fist.Position, TOUCH_RADIUS + fist.Size.X, params) do
		if not part:IsA("BasePart") or part.Anchored then
			continue
		end
		local victimModel = part:FindFirstAncestorWhichIsA("Model")
		local isPlayer = victimModel ~= nil and victimModel.Parent == menFolder

		local grabbable = CollectionService:HasTag(part, "Grabbable") or isPlayer
		if not grabbable then
			continue
		end

		-- YOU GRAB WHAT YOU TOUCHED.
		--
		-- This used to redirect any hit on a player to their PrimaryPart -- "seize the body,
		-- not the limb" -- on the theory that grabbing an arm gets you five ball sockets of
		-- wet spaghetti and no man on the end of it.
		--
		-- It was a bad trade, and it broke the thing it was protecting. The grip is a spring
		-- between YOUR FIST and the target: silently retarget that spring from the shoulder
		-- your hand is touching to a base three studs below it, and it starts life already
		-- stretched further than GRIP_BREAK -- so it snapped on the first frame, every time.
		-- The only part of a man you could actually hold was the one part that happened to
		-- be where your hand already was: the bottom slab. Nobody could grab an arm, a
		-- shoulder, or a head, and it looked like the grip was too weak. It wasn't. It was
		-- being asked to hold something it wasn't touching.
		--
		-- So: hold the thing your hand is on. Yes, an arm is a floppy handle and hauling
		-- someone about by one is hard work -- but that's a fact about noodles, and the
		-- player can SEE it and go for a better handhold. A rule that quietly moves the
		-- grab somewhere else can't be seen at all.
		local target = part
		if not target:FindFirstChild("GrabAtt") then
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

		for _, side in { "L", "R" } do
			local fist = man:FindFirstChild("Arm" .. side .. "5") :: BasePart?
			local grip = fist and fist:FindFirstChild("Grip") :: AlignPosition?
			if not fist or not grip then
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
			elseif reaching and not downed and root:GetAttribute("Armed" .. side) == true then
				-- ARMED means the sim says this hand has actually reached its stance (or
				-- has been trying for long enough that we've stopped waiting). A hand
				-- that's still on its way out doesn't grab anything -- that's the whole
				-- point of the pose. You commit, then you close.
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
