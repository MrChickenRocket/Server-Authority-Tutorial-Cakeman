--!strict
-- CakePunch -- fists shove people, and that is the whole file.
--
-- This is separate from CakeSim because CakeSim is the movement brain: deterministic, run
-- on both machines, and re-run during reconciliation, so it may only read input and write
-- actuator targets. A punch is a consequence, not movement -- the server watches collisions
-- and decides that one man's fist arrived at another man, and the client doesn't get a vote.
-- Movement is predicted; consequences are authoritative.
--
-- There is no health, knockout, or score here. A punch applies an impulse and nothing else,
-- so the shove is the mechanic and it writes no game state at all.
local RunService = game:GetService("RunService")

local HIT_SPEED_MIN = 18 -- below this it's a nudge, not a punch
local HIT_COOLDOWN = 0.35 -- per attacker/victim pair, so one contact isn't twenty hits

-- Knockback, scaled by impact speed, so a lazy tap nudges and a full turn launches.
local KNOCKBACK = 150 -- impulse per stud/sec of impact above the threshold
local KNOCKBACK_LIFT = 0.35 -- fraction of the shove redirected up, so a hit pops people off
-- the floor a little instead of only sliding them along it
local KNOCKBACK_REACTION = 0.4 -- how much of the shove the puncher eats back, so he rocks too

local menFolder = workspace:WaitForChild("CakeMen")

-- The velocity you read in Touched is the wrong one. Touched fires after the solver has
-- resolved the contact, so what you read there is the velocity after the impact -- and for a
-- light thing hitting a heavy thing that is nearly zero. Measured here: a part hurled at a
-- CakeMan at 50 studs/s reads 2.1 studs/s by the time Touched hands it over.
--
-- So keep last frame's velocity ourselves. Heartbeat runs after physics, so what we store is
-- the velocity each part carried into the next step, which is the pre-impact one. Weak keys,
-- so destroyed parts drop out of the table on their own.
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

-- The shove. `dir` is which way the blow was travelling (the fist's approach velocity) and
-- `magnitude` is how hard, already scaled by impact speed. Biased upward so a hit lifts as
-- well as slides, full force on the victim's base and a fraction back on the attacker's, so
-- the punch rocks both men.
--
-- The impulse goes on the root, the heavy base the wobbly stack hangs off, so shoving it
-- sends the man skidding while the cake above him lags and flails behind. The wobble does
-- the knockback animation.
local function rock(victim: Model, attacker: Model?, dir: Vector3, magnitude: number)
	if magnitude <= 0 or dir.Magnitude < 1e-3 then
		return
	end
	-- Renormalised: the lift changes the direction of the shove, not its size.
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
		return -- hit the floor, a wall, whatever
	end
	if attacker == victim then
		return -- your own fists can't hit you
	end
	-- Only fists punch. Being barged by someone's cake is a shove, not a punch.
	if not string.match(other.Name, "^Arm[LR]5$") then
		return
	end

	-- Pre-impact, both of them. See the note on prevVel: by the time we're called the solver
	-- has already spent the energy we're trying to measure.
	local otherVel = approachVel(other)
	local myVel = approachVel(victimPart)

	-- Relative speed is the right measure for two fighters: the same number whether I swung
	-- into you or you ran onto my fist, and in a brawl those are the same event.
	local relSpeed = (otherVel - myVel).Magnitude
	if relSpeed < HIT_SPEED_MIN then
		return
	end

	-- Key the cooldown to the victim, not to the part of him you clipped. A cake is five
	-- slabs plus two arms, so a fist sweeping through a man touches several parts on the way
	-- past, and a per-part key bills him separately for each -- one swing landing four or
	-- five times over.
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
