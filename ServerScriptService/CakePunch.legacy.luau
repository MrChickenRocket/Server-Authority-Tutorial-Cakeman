--!strict
-- CakePunch — fists shove people. That is the whole file.
--
-- WHY THIS IS NOT IN THE SIM, and it's a genuinely useful distinction to draw:
--
--   CakeSim is the character's MOVEMENT brain. It's deterministic, it runs on both
--   machines, and it re-runs during reconciliation -- so it may only read input and
--   write actuator targets.
--
--   A punch is not movement. It is a CONSEQUENCE: the server watches collisions and
--   decides that one man's fist arrived at another man. The client doesn't get a vote.
--   Movement is predicted; consequences are authoritative. That line is worth holding.
--
-- There is no health here, no knockout, and no score. A punch applies an impulse and
-- nothing else -- the shove IS the mechanic, and it writes no game state at all.
local RunService = game:GetService("RunService")

local HIT_SPEED_MIN = 18 -- below this it's a nudge, not a punch
local HIT_COOLDOWN = 0.35 -- per attacker/victim pair, so one contact isn't twenty hits

-- KNOCKBACK. Scaled by impact speed, so a lazy tap nudges and a full turn launches.
local KNOCKBACK = 150 -- impulse per stud/sec of impact above the threshold
local KNOCKBACK_LIFT = 0.35 -- fraction of the shove redirected UP, so a hit pops people
-- off the floor a little instead of only sliding them along it
local KNOCKBACK_REACTION = 0.4 -- how much of the shove the PUNCHER eats back, so he rocks too

local menFolder = workspace:WaitForChild("CakeMen")

-- ---------------------------------------------------------------------------
-- THE VELOCITY YOU READ IN `Touched` IS THE WRONG ONE.
--
-- Touched fires after the solver has already resolved the contact, so the velocity you
-- read there is the velocity AFTER the impact -- and for a light thing hitting a heavy
-- thing, that's nearly zero. Measured: a part hurled at a CakeMan at 50 studs/s reads
-- 2.1 studs/s by the time Touched hands it to you. It arrived like a cannonball and
-- reports itself as a gentle nudge.
--
-- So keep last frame's velocity ourselves. Heartbeat runs after physics, so what we store
-- is the velocity each part carried INTO the next step -- which is the pre-impact one.
-- Weak keys, so destroyed parts drop out of the table on their own.
-- ---------------------------------------------------------------------------
local prevVel: { [BasePart]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any

RunService.Heartbeat:Connect(function()
	for _, man in menFolder:GetChildren() do
		for _, p in (man :: Model):GetDescendants() do
			if p:IsA("BasePart") then
				prevVel[p :: BasePart] = (p :: BasePart).AssemblyLinearVelocity
			end
		end
	end
end)

-- The velocity a part was carrying just before it hit something.
local function approachVel(part: BasePart): Vector3
	return prevVel[part] or part.AssemblyLinearVelocity
end

-- Who owns a part? Fists belong to their CakeMan.
local function ownerOf(part: BasePart): Model?
	local m = part:FindFirstAncestorOfClass("Model")
	return (m and m.Parent == menFolder) and m or nil
end

-- The shove. `dir` is which way the blow was travelling (the fist's approach velocity);
-- `magnitude` is how hard, already scaled by impact speed. We bias it a little upward so a
-- hit LIFTS as well as slides, shove the victim's base by the full amount, and shove the
-- attacker's base back by a fraction -- so the punch rocks both men, not just the one who
-- caught it.
--
-- The impulse goes on the ROOT: it's the heavy base the whole wobbly stack hangs off, so
-- shoving it sends the man skidding while the cake above him lags and flails behind. That
-- is the wobble doing our knockback animation for free.
local function rock(victim: Model, attacker: Model?, dir: Vector3, magnitude: number)
	if magnitude <= 0 or dir.Magnitude < 1e-3 then
		return
	end
	-- Renormalised: the lift changes the DIRECTION of the shove, not its size.
	local push = (dir.Unit + Vector3.yAxis * KNOCKBACK_LIFT).Unit

	local vroot = victim.PrimaryPart
	if vroot then
		vroot:ApplyImpulse(push * magnitude)
	end
	if attacker and attacker.PrimaryPart then
		attacker.PrimaryPart:ApplyImpulse(-push * magnitude * KNOCKBACK_REACTION)
	end
end

local lastHit: { [string]: number } = {}

local function onContact(victimPart: BasePart, other: BasePart)
	local victim = ownerOf(victimPart)
	local attacker = ownerOf(other)
	if not victim or not attacker then
		return -- hit the floor, a wall, whatever. Not our problem.
	end
	if attacker == victim then
		return -- your own fists can't hit you, no matter how hard you try
	end
	-- Only FISTS punch. Being barged by someone's cake is a shove, not a punch.
	if not string.match(other.Name, "^Arm[LR]5$") then
		return
	end

	-- Pre-impact, both of them. See the note on prevVel: by the time we're called, the
	-- solver has already spent the energy we're trying to measure.
	local otherVel = approachVel(other)
	local myVel = approachVel(victimPart)

	-- RELATIVE speed is the right measure for two fighters: it's the same number whether
	-- I swung into you or you ran onto my fist, and in a brawl those genuinely are the
	-- same event.
	local relSpeed = (otherVel - myVel).Magnitude
	if relSpeed < HIT_SPEED_MIN then
		return
	end

	-- ONE PUNCH IS ONE PUNCH.
	--
	-- This cooldown used to be keyed per attacker-part -> VICTIM PART. A cake is five slabs
	-- plus two arms, so a fist sweeping through a man clipped his sponge, his strawberry
	-- AND his icing on the way past and billed him separately for each -- one swing landing
	-- four or five times over. Key the cooldown to the VICTIM, not to the piece of him you
	-- happened to clip.
	local key = tostring(other) .. ">" .. tostring(victim)
	local now = os.clock()
	if (lastHit[key] or 0) + HIT_COOLDOWN > now then
		return
	end
	lastHit[key] = now

	rock(victim, attacker, otherVel, (relSpeed - HIT_SPEED_MIN) * KNOCKBACK)
end

local function watch(man: Model)
	for _, p in man:GetDescendants() do
		if p:IsA("BasePart") then
			local part = p :: BasePart
			part.Touched:Connect(function(other)
				onContact(part, other)
			end)
		end
	end
end

for _, m in menFolder:GetChildren() do
	watch(m :: Model)
end
menFolder.ChildAdded:Connect(function(m)
	task.defer(watch, m :: Model)
end)

print("[CakePunch] watching for punches")
