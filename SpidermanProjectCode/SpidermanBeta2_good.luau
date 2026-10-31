local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local tool = script.Parent

local MAX_WEB_DISTANCE = 350
local MOMENTUM_FORCE = 1800
local STRAFE_FORCE = 1200
local BUOYANCY_MULTIPLIER = 0.65
local MIN_WEB_LENGTH = 20

local VERTICAL_BOOST_GROUND = 85
local VERTICAL_BOOST_AIR = 25

local isSwinging = false
local anchorPart = nil
local ropeConstraint = nil
local boostForce = nil
local webVisual = nil
local swingGyro = nil
local swingConnection = nil

--release keeps your momentum
local function stopSwing()
	if not isSwinging then return end
	isSwinging = false

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid.PlatformStand = false
	end

	if anchorPart then anchorPart:Destroy() end
	if ropeConstraint then ropeConstraint:Destroy() end
	if boostForce then boostForce:Destroy() end
	if webVisual then webVisual:Destroy() end
	if swingGyro then swingGyro:Destroy() end
	if swingConnection then swingConnection:Disconnect() end

	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp then
		local currentVelocity = hrp.AssemblyLinearVelocity
		if currentVelocity.Magnitude > 150 then
			hrp.AssemblyLinearVelocity = currentVelocity.Unit * 150
		end
	end
end

local function startSwing()
	local character = player.Character
	if not character then return end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then return end

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	--raycast from where the camera looks to find the anchor, no autotarget
	local rayOrigin = camera.CFrame.Position
	local rayDirection = camera.CFrame.LookVector * MAX_WEB_DISTANCE
	local result = Workspace:Raycast(rayOrigin, rayDirection, rayParams)

	if result then
		isSwinging = true

		anchorPart = Instance.new("Part")
		anchorPart.Size = Vector3.new(1, 1, 1)
		anchorPart.Position = result.Position
		anchorPart.Anchored = true
		anchorPart.CanCollide = false
		anchorPart.Transparency = 1
		anchorPart.Parent = Workspace

		local anchorAttachment = Instance.new("Attachment", anchorPart)
		local playerAttachment = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)

		local distance = (hrp.Position - result.Position).Magnitude
		--rope constraint is the actual pendulum
		ropeConstraint = Instance.new("RopeConstraint")
		ropeConstraint.Attachment0 = playerAttachment
		ropeConstraint.Attachment1 = anchorAttachment
		ropeConstraint.Visible = false
		ropeConstraint.Length = distance
		ropeConstraint.Parent = hrp

		webVisual = Instance.new("Beam")
		webVisual.Attachment0 = character:FindFirstChild("RightHand") and character.RightHand:FindFirstChild("RightGripAttachment") or playerAttachment
		webVisual.Attachment1 = anchorAttachment
		webVisual.FaceCamera = true
		webVisual.Width0 = 0.2
		webVisual.Width1 = 0.2
		webVisual.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
		webVisual.Parent = hrp

		boostForce = Instance.new("VectorForce")
		boostForce.Attachment0 = playerAttachment
		boostForce.ApplyAtCenterOfMass = true
		boostForce.RelativeTo = Enum.ActuatorRelativeTo.World
		boostForce.Parent = hrp

		--gyro so the char doesnt spin or flatten out
		swingGyro = Instance.new("AlignOrientation")
		swingGyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
		swingGyro.Attachment0 = playerAttachment
		swingGyro.MaxTorque = 100000
		swingGyro.Responsiveness = 50
		swingGyro.Parent = hrp

		humanoid.PlatformStand = true

		local isGrounded = humanoid.FloorMaterial ~= Enum.Material.Air
		if isGrounded then
			hrp.AssemblyLinearVelocity = Vector3.new(hrp.AssemblyLinearVelocity.X, VERTICAL_BOOST_GROUND, hrp.AssemblyLinearVelocity.Z)
		else
			hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + Vector3.new(0, VERTICAL_BOOST_AIR, 0)
		end

		swingConnection = RunService.RenderStepped:Connect(function()
			if not isSwinging then return end

			local currentDistance = (hrp.Position - anchorPart.Position).Magnitude

			if currentDistance < ropeConstraint.Length then
				ropeConstraint.Length = math.max(MIN_WEB_LENGTH, currentDistance + 0.5)
			end

			local lookDir = camera.CFrame.LookVector
			local rightDir = camera.CFrame.RightVector

			local horizontalLook = Vector3.new(lookDir.X, 0, lookDir.Z).Unit
			local horizontalRight = Vector3.new(rightDir.X, 0, rightDir.Z).Unit

			local strafeInput = 0
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then strafeInput = -1 end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then strafeInput = 1 end

			local totalMass = hrp.AssemblyMass
			local upwardBuoyancy = totalMass * Workspace.Gravity * BUOYANCY_MULTIPLIER

			local forwardForce = horizontalLook * MOMENTUM_FORCE
			local sidewaysForce = horizontalRight * (strafeInput * STRAFE_FORCE)

			--energy gets added back here so its not a dead pendulum
			boostForce.Force = forwardForce + sidewaysForce + Vector3.new(0, upwardBuoyancy, 0)

			local velocity = hrp.AssemblyLinearVelocity
			local horizontalVel = Vector3.new(velocity.X, 0, velocity.Z)

			if horizontalVel.Magnitude > 1 then

				swingGyro.CFrame = CFrame.lookAt(Vector3.zero, horizontalVel.Unit)
			else

				swingGyro.CFrame = CFrame.lookAt(Vector3.zero, horizontalLook)
			end
		end)
	end
end

tool.Activated:Connect(function()
	if not isSwinging then
		startSwing()
	end
end)

tool.Deactivated:Connect(stopSwing)

tool.Unequipped:Connect(stopSwing)
