--!strict
-- CakeCombat — damage, knockouts, and getting back up.
--
-- WHY THIS IS NOT IN THE SIM, and it's a genuinely useful distinction to draw:
--
--   CakeSim is the character's MOVEMENT brain. It's deterministic, it runs on both
--   machines, and it re-runs during reconciliation -- so it may only read input and
--   write actuator targets.
--
--   Damage is not movement. It is AUTHORITATIVE GAME STATE, and the server is the only
--   one entitled to an opinion about it. The client doesn't predict how much health it
--   has; it is TOLD. That's the whole point of server authority, and trying to predict
--   it would buy nothing (an HP bar that's 80ms late is fine; an HP bar that flickers
--   because the client guessed wrong is not).
--
--   So: the server watches collisions, decides what hurt, and writes Health as an
--   attribute. The sim READS that attribute to decide whether to keep him standing.
--   Movement is predicted; consequences are authoritative. That line is worth holding.
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local MAX_HEALTH = 100

-- Damage is momentum, basically: how fast did it hit you, and how much of it was there.
-- A fist that's just resting against you does nothing; the same fist swung at the end of
-- a whipping noodle arm does a lot.
local HIT_SPEED_MIN = 18 -- below this it's a nudge, not a punch
local FIST_DAMAGE = 1.6 -- per stud/sec of impact speed above the threshold
local BOX_DAMAGE = 0.9 -- boxes are lighter, so they hurt less -- but they're everywhere
local HIT_COOLDOWN = 0.35 -- per attacker/victim pair, so one contact isn't twenty hits

-- The cherry is the kill shot. It sits on top, on a loose socket, bobbing around --
-- the hardest thing on the character to hit, and the funniest thing to lose to.
local CHERRY_KO_SPEED = 14 -- a solid connection with the cherry ends you, full stop

-- Seconds flat on your face. This was 2, which turned out to be barely a stumble: you
-- were up again before anyone could do anything ABOUT you, so a knockout cost you almost
-- nothing and being the one who landed it won you almost nothing either.
--
-- Five is long enough to be a real event. It's the window in which a limp cake is just
-- cargo -- long enough for someone to walk over, grab you, carry you to the edge and
-- drop you in. The knockout isn't the punishment; it's the setup for the punishment.
local DOWNED_TIME = 5
local WAKE_HEALTH = 35 -- you come back with a bit of a boost, not on 1hp...
local REGEN_RATE = 6 -- ...and then climb back to full at this many hp/sec

local menFolder = workspace:WaitForChild("CakeMen")

-- ---------------------------------------------------------------------------
-- THE VELOCITY YOU READ IN `Touched` IS THE WRONG ONE.
--
-- Touched fires after the solver has already resolved the contact, so the velocity you
-- read there is the velocity AFTER the impact -- and for a light thing hitting a heavy
-- thing, that's nearly zero. Measured: a box hurled at a CakeMan at 50 studs/s reads
-- 2.1 studs/s by the time Touched hands it to you. It arrived like a cannonball and
-- reports itself as a gentle nudge.
--
-- Which meant thrown boxes did no damage AT ALL -- the crate that flattens you dealt less
-- than the threshold, every time. (And it hid the real bug: the only impacts that ever
-- registered hard were the ones where a heavy, servo-driven FIST kept its speed through
-- the contact... including my own fist, punching a box. So the one thing box damage
-- reliably did was knock me out for punching a crate.)
--
-- So keep last frame's velocity ourselves. Heartbeat runs after physics, so what we store
-- is the velocity each part carried INTO the next step -- which is the pre-impact one.
-- Weak keys, so destroyed boxes drop out of the table on their own.
-- ---------------------------------------------------------------------------
local prevVel: { [BasePart]: Vector3 } = setmetatable({}, { __mode = "k" }) :: any

local function remember(part: BasePart)
	prevVel[part] = part.AssemblyLinearVelocity
end

RunService.Heartbeat:Connect(function()
	for _, box in CollectionService:GetTagged("Prop") do
		if box:IsA("BasePart") then
			remember(box)
		end
	end
	for _, man in menFolder:GetChildren() do
		for _, p in (man :: Model):GetDescendants() do
			if p:IsA("BasePart") then
				remember(p :: BasePart)
			end
		end
	end
end)

-- The velocity a part was carrying just before it hit something.
local function approachVel(part: BasePart): Vector3
	return prevVel[part] or part.AssemblyLinearVelocity
end

-- Who owns a part? (Fists belong to their CakeMan; a box belongs to nobody.)
local function ownerOf(part: BasePart): Model?
	local m = part:FindFirstAncestorOfClass("Model")
	return (m and m.Parent == menFolder) and m or nil
end

local function rootOf(man: Model): BasePart?
	return man.PrimaryPart
end

local function knockOut(man: Model)
	local root = rootOf(man)
	if not root or root:GetAttribute("Downed") == true then
		return
	end
	root:SetAttribute("Health", 0)
	root:SetAttribute("Downed", true)
	root:SetAttribute("DownedFor", DOWNED_TIME)
	print("[CakeCombat] KO:", man.Name)
end

local function damage(man: Model, amount: number)
	local root = rootOf(man)
	if not root or root:GetAttribute("Downed") == true then
		return -- you can't beat a man who's already down. You can only carry him.
	end
	local hp = math.max((root:GetAttribute("Health") :: number) - amount, 0)
	root:SetAttribute("Health", hp)
	if hp <= 0 then
		knockOut(man)
	end
end

-- ---------------------------------------------------------------------------
-- Impacts.
--
-- Roblox gives you Touched, which fires constantly and tells you nothing about how hard.
-- So we compute the hardness ourselves: the RELATIVE speed of the two parts at the
-- moment of contact. That's the number that separates "leaning on you" from "arrived at
-- you", and it's the same number whether the fist swung into a stationary player or a
-- player ran onto a stationary fist -- which is exactly right, and is why relative
-- velocity is the correct measure rather than the attacker's speed.
-- ---------------------------------------------------------------------------
local lastHit: { [string]: number } = {}

local function onContact(victimPart: BasePart, other: BasePart)
	local victim = ownerOf(victimPart)
	if not victim then
		return
	end
	local attacker = ownerOf(other)
	local isBox = CollectionService:HasTag(other, "Prop")
	if not isBox and not attacker then
		return -- hit the floor, a wall, whatever. Not our problem.
	end
	if attacker == victim then
		return -- your own fists can't hurt you, no matter how hard you try
	end
	-- ...and neither can the box in your own hands. The grip hauls it toward your fist at
	-- speed, so it arrives at your face at exactly the velocity this code considers
	-- lethal -- and a box that hits your cherry is an instant knockout. You picked up a
	-- box and were immediately killed by it. Whatever a man is carrying is not a weapon
	-- pointed at HIM. (CakeGrab stamps HeldBy, and keeps the stamp for a moment after you
	-- let go, so the box you just threw isn't an enemy projectile while it's still an
	-- inch from your nose.)
	if isBox and other:GetAttribute("HeldBy") == victim.Name then
		return
	end
	-- Only FISTS hurt. Being barged by someone's cake is a shove, not a punch.
	if attacker and not string.match(other.Name, "^Arm[LR]5$") then
		return
	end

	local key = tostring(other) .. ">" .. tostring(victimPart)
	local now = os.clock()
	if (lastHit[key] or 0) + HIT_COOLDOWN > now then
		return
	end

	-- Pre-impact, both of them. See the note on prevVel: by the time we're called, the
	-- solver has already spent the energy we're trying to measure.
	local otherVel = approachVel(other)
	local myVel = approachVel(victimPart)

	local relSpeed = (otherVel - myVel).Magnitude
	if relSpeed < HIT_SPEED_MIN then
		return
	end

	-- WHO BROUGHT THE MOMENTUM?
	--
	-- Relative speed is the right measure for two FIGHTERS -- it's the same number whether
	-- I swung into you or you ran onto my fist, and in a brawl those genuinely are the same
	-- event. But a box is not a fighter. It is inert. It has no opinion. And relative speed
	-- cannot tell "I punched a box" from "a box was thrown at my head", because those are
	-- the same number too -- which is why punching a crate was knocking me out cold.
	--
	-- So for props only, ask which of us is doing the closing. Project both velocities onto
	-- the line between us: if I'm arriving at the box faster than the box is arriving at
	-- me, then I hit IT, and a box I hit is not allowed to hurt me. A thrown box still
	-- lands, and a box I run into at speed still hurts -- because in both of those cases
	-- the box really is the one closing the distance.
	if isBox then
		local line = victimPart.Position - other.Position
		if line.Magnitude < 1e-3 then
			return
		end
		local dir = line.Unit -- points from the box toward me
		local boxClosing = otherVel:Dot(dir) -- box coming at me
		local myClosing = myVel:Dot(-dir) -- me going at box
		if boxClosing <= myClosing then
			return -- I punched it. It didn't punch me.
		end
		-- And the box only hits as hard as the box is actually travelling. Its own closing
		-- speed, not the relative speed -- otherwise a fist swung at 40 studs/s into a
		-- gently drifting crate would still register as a 40-stud-per-second impact.
		relSpeed = boxClosing
		if relSpeed < HIT_SPEED_MIN then
			return
		end
	end

	lastHit[key] = now

	-- THE CHERRY. A clean hit on the head ends the fight, whoever you are.
	if victimPart.Name == "Head" and relSpeed >= CHERRY_KO_SPEED then
		print(string.format("[CakeCombat] CHERRY SHOT on %s (%.0f studs/s)", victim.Name, relSpeed))
		knockOut(victim)
		return
	end

	local scale = if isBox then BOX_DAMAGE else FIST_DAMAGE
	damage(victim, (relSpeed - HIT_SPEED_MIN) * scale)
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

-- ---------------------------------------------------------------------------
-- Being down, and getting up.
-- ---------------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt: number)
	for _, m in menFolder:GetChildren() do
		local man = m :: Model
		local root = rootOf(man)
		if not root then
			continue
		end

		if root:GetAttribute("Downed") == true then
			-- Count DOWN by dt. (This is server gameplay code, so a clock would be
			-- legal here -- but counting down by dt is the habit worth keeping, because
			-- the moment this logic moves into the sim, a clock becomes a bug.)
			local left = (root:GetAttribute("DownedFor") :: number) - dt
			if left <= 0 then
				root:SetAttribute("Downed", false)
				root:SetAttribute("DownedFor", 0)
				root:SetAttribute("Health", WAKE_HEALTH) -- a boost, so you're not
				-- instantly knocked out again by the first box that rolls past
				print("[CakeCombat] up:", man.Name)
			else
				root:SetAttribute("DownedFor", left)
			end
		else
			-- ...and then climb back to full, slowly enough that a fight has stakes.
			local hp = root:GetAttribute("Health") :: number
			if hp < MAX_HEALTH then
				root:SetAttribute("Health", math.min(hp + REGEN_RATE * dt, MAX_HEALTH))
			end
		end
	end
end)

print("[CakeCombat] watching for punches")
