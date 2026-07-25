--!strict
-- MINIMAL REPRO -- client. Runs the same sim (this is the prediction), pins the
-- camera, renders Cube4 from its attribute, and labels every cube with its live
-- RunService:GetPredictionStatus().
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedFirst = game:GetService("ReplicatedFirst")

if not game:IsLoaded() then
	game.Loaded:Wait()
end
local player = Players.LocalPlayer

-- The SAME sim, locally. This is the client-side prediction.
require(ReplicatedFirst:WaitForChild("ReproSim")).Initialize()

-- PINNED CAMERA. Fixed overhead shot of all four lanes, so smoothness is judged
-- against a still frame and nothing depends on view direction.
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable
local EYE = Vector3.new(18, 95, 26)
local LOOK = Vector3.new(18, 0, -6)
RunService:BindToRenderStep("ReproCamera", Enum.RenderPriority.Camera.Value, function()
	camera.CFrame = CFrame.lookAt(EYE, LOOK, Vector3.new(0, 0, -1))
end)

local function rig(): Model?
	local folder = workspace:FindFirstChild("Repro")
	local m = folder and folder:FindFirstChild("Repro_" .. player.UserId)
	return m and m:IsA("Model") and m or nil
end

local SHORT = {
	Cube1_AlignPosition = "1 AlignPosition",
	Cube2_AnchoredCFrame = "2 CFrame/anchored",
	Cube3_UnanchoredCFrame = "3 CFrame/unanchored+stomp",
	Cube4_AttributeRender = "4 attribute -> RenderStepped",
}

RunService.RenderStepped:Connect(function()
	local model = rig()
	if not model then
		return
	end

	for _, p in model:GetChildren() do
		if not p:IsA("BasePart") then
			continue
		end

		-- Cube4 is placed here, on the render step, straight from its attribute.
		if p.Name == "Cube4_AttributeRender" then
			local pos = (p:GetAttribute("Pos") :: Vector3?) or p.Position
			local face = (p:GetAttribute("FaceDir") :: Vector3?) or Vector3.new(0, 0, -1)
			p.CFrame = CFrame.lookAt(pos, pos + face, Vector3.new(0, 1, 0))
		end

		local bb = p:FindFirstChild("Label")
		local text = bb and bb:FindFirstChild("Text") :: TextLabel?
		if text then
			local ok, status = pcall(function()
				return RunService:GetPredictionStatus(p)
			end)
			local s = ok and tostring(status):gsub("Enum.PredictionStatus.", "") or "?"
			text.Text = (SHORT[p.Name] or p.Name) .. "\n" .. s
			text.TextColor3 = if s == "Predicted"
				then Color3.fromRGB(90, 235, 130)
				else Color3.fromRGB(255, 110, 100)
		end
	end
end)

print("[Repro] client ready -- WASD drives all four. Camera is pinned.")
