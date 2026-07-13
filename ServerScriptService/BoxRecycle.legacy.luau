--!strict
-- BoxRecycle — what happens to a box you knock into the void.
--
-- This is the RUNTIME half of the props. The boxes themselves are real instances baked
-- into the place (see ServerStorage.GenerateArena, which is disabled); this script does
-- the thing that has to happen every game, forever: put them back when they fall off.
--
-- Generation and behaviour are different jobs. One runs once, when a designer says so.
-- The other runs for the life of the server. Keeping them in the same file was tidy right
-- up until the moment we wanted the level to exist without the code running.
--
-- WHY LIMBO, and not just an instant respawn:
--
--   Left alone, a box falls forever and Roblox eventually destroys it at
--   FallenPartsDestroyHeight. Nothing leaks -- but the arena quietly runs out of
--   ammunition over a match, and every destroyed box churns a visual copy in the
--   presentation layer for nothing.
--
--   And a box that reappears the INSTANT it falls teaches the player that the void is
--   meaningless. Knocking someone's ammunition into the pit should cost them something,
--   even if only a few seconds.
--
--   So a fallen box is frozen, hidden, and parked out of the world for LIMBO_TIME, then
--   put back exactly where it was born. The prop count stays constant for the life of the
--   server, which is a far easier thing to reason about than a world that slowly empties.
--
-- (This is ordinary server gameplay code, not the simulation, so it's allowed a wall
-- clock. Inside BindToSimulation that would be a bug: it re-runs during reconciliation
-- and would read a different time on each pass.)
local RunService = game:GetService("RunService")

local KILL_Y = -40
local LIMBO_TIME = 6

local props = workspace:WaitForChild("Props")

type Limbo = { home: CFrame, returnAt: number? }
local boxes: { [BasePart]: Limbo } = {}

-- HOME IS WHERE IT WAS BAKED. The boxes are placed by the (disabled) generator and saved
-- into the place, so their starting CFrame is simply where they are when the server boots.
-- No seed, no layout code, no duplication of the generator's maths -- the world IS the
-- record of where things go.
local function adopt(b: Instance)
	if b:IsA("BasePart") then
		boxes[b] = { home = b.CFrame }
	end
end
for _, b in props:GetChildren() do
	adopt(b)
end
props.ChildAdded:Connect(adopt)
props.ChildRemoved:Connect(function(b)
	if b:IsA("BasePart") then
		boxes[b] = nil
	end
end)

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	for b, state in boxes do
		if not b.Parent then
			continue
		end

		if state.returnAt then
			if now >= state.returnAt then
				b.CFrame = state.home
				b.AssemblyLinearVelocity = Vector3.zero
				b.AssemblyAngularVelocity = Vector3.zero
				b.Anchored = false
				b.CanCollide = true
				b.Transparency = 0
				state.returnAt = nil
			end
		elseif b.Position.Y < KILL_Y then
			-- Fell out of the world. Freeze it, hide it, start the clock.
			b.Anchored = true
			b.CanCollide = false
			b.Transparency = 1
			b.AssemblyLinearVelocity = Vector3.zero
			b.AssemblyAngularVelocity = Vector3.zero
			b.CFrame = CFrame.new(0, KILL_Y - 60, 0)
			state.returnAt = now + LIMBO_TIME
		end
	end
end)

print(string.format("[BoxRecycle] watching %d boxes (fall past Y=%d -> %ds in limbo -> restocked)",
	#props:GetChildren(), KILL_Y, LIMBO_TIME))
