--!strict
local Smoothing = {}

-- Critically-damped spring toward `tgt`; `st` ~= time to arrive.
-- Returns (newPos, newVel); thread `vel` back in next call.
function Smoothing.damp(cur: Vector3, tgt: Vector3, vel: Vector3, st: number, dt: number): (Vector3, Vector3)
	st = math.max(st, 1e-4)
	local omega = 2 / st
	local x = omega * dt
	local e = math.exp(-x)
	local change = cur - tgt
	local temp = (vel + change * omega) * dt
	local newVel = (vel - temp * omega) * e
	return tgt + (change + temp) * e, newVel
end

return Smoothing
