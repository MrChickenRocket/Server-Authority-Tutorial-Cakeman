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

local DOWNED_TIME = 2 -- seconds flat on your face
local WAKE_HEALTH = 35 -- you come back with a bit of a boost, not on 1hp...
local REGEN_RATE = 6 -- ...and then climb back to full at this many hp/sec

local menFolder = workspace:WaitForChild("CakeMen")

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

	local relSpeed = (other.AssemblyLinearVelocity - victimPart.AssemblyLinearVelocity).Magnitude
	if relSpeed < HIT_SPEED_MIN then
		return
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
