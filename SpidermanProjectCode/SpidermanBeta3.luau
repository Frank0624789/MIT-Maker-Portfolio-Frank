local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local tool = script.Parent

local MAX_WEB_DISTANCE = 350
local MOMENTUM_FORCE = 1500
local STRAFE_FORCE = 1000
local BUOYANCY_MULTIPLIER = 0.55
local JUMP_IMPULSE = 35

local E_BOOST_FORCE = 65
local WALL_CRAWL_SPEED = 35
local HANGTIME_DURATION = 1.2

local currentState = "IDLE"
local lastBoostTime = 0

local anchorPart, targetHighlight
local ropeConstraint, boostForce, webVisual, swingGyro
local grabbedPart, grabAlign
local wallVelocity, wallGyro
local connectionLoop

local function startHangtime(character)
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp or currentState == "SWINGING" or currentState == "WALL_CRAWL" then return end

	local mass = hrp.AssemblyMass
	local hangtimeForce = Instance.new("VectorForce")
	hangtimeForce.Attachment0 = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)
	hangtimeForce.RelativeTo = Enum.ActuatorRelativeTo.World
	hangtimeForce.Force = Vector3.new(0, mass * Workspace.Gravity * 0.9, 0)
	hangtimeForce.Parent = hrp

	local tween = TweenService:Create(hangtimeForce, TweenInfo.new(HANGTIME_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {Force = Vector3.new(0,0,0)})
	tween:Play()

	task.delay(HANGTIME_DURATION, function()
		if hangtimeForce then hangtimeForce:Destroy() end
	end)
end

local function resetSystem(triggerHangtime)
	local prevState = currentState
	currentState = "IDLE"

	local character = player.Character

	local cleanupList = {anchorPart, targetHighlight, ropeConstraint, boostForce, webVisual, swingGyro, wallVelocity, wallGyro, grabAlign}
	for _, item in ipairs(cleanupList) do
		if item then item:Destroy() end
	end
	if connectionLoop then connectionLoop:Disconnect() end

	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid.PlatformStand = false end

	if prevState == "GRABBING" and grabbedPart then

		local targetPoint = camera.CFrame.Position + (camera.CFrame.LookVector * 500)
		local throwDir = (targetPoint - grabbedPart.Position).Unit

		local throwVelocity = Instance.new("LinearVelocity")
		throwVelocity.Mode = Enum.VelocityConstraintMode.Vector
		throwVelocity.VectorVelocity = throwDir * 180
		throwVelocity.Attachment0 = grabbedPart:FindFirstChild("WebAttach")
		throwVelocity.MaxForce = math.huge
		throwVelocity.Parent = grabbedPart

		task.delay(0.3, function()
			if throwVelocity then throwVelocity:Destroy() end
		end)

		grabbedPart = nil
	end

	if triggerHangtime and character then
		startHangtime(character)
	end
end

local function startWallCrawl(wallNormal)
	resetSystem(false)
	currentState = "WALL_CRAWL"

	local character = player.Character
	local hrp = character.HumanoidRootPart
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	humanoid.PlatformStand = true

	hrp.AssemblyLinearVelocity = Vector3.zero
	local attachment = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)

	--gyro so the char doesnt spin or flatten out
	wallGyro = Instance.new("AlignOrientation")
	wallGyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
	wallGyro.Attachment0 = attachment
	wallGyro.MaxTorque = math.huge
	wallGyro.Responsiveness = 200
	wallGyro.CFrame = CFrame.lookAt(Vector3.zero, -wallNormal, Vector3.new(0,1,0))
	wallGyro.Parent = hrp

	wallVelocity = Instance.new("LinearVelocity")
	wallVelocity.Attachment0 = attachment
	wallVelocity.MaxForce = math.huge
	wallVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	wallVelocity.Parent = hrp

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}

	connectionLoop = RunService.RenderStepped:Connect(function()
		if currentState ~= "WALL_CRAWL" then return end

		local edgeCheck = Workspace:Raycast(hrp.Position, -wallNormal * 4, rayParams)
		if not edgeCheck then
			resetSystem(true)
			return
		end

		local moveDir = Vector3.zero
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + Vector3.new(0, 1, 0) end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir + Vector3.new(0, -1, 0) end

		--cross producting vectors for wall climb coords
		local wallRight = Vector3.new(0,1,0):Cross(wallNormal).Unit

		if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - wallRight end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + wallRight end

		if moveDir.Magnitude > 0 then
			wallVelocity.VectorVelocity = moveDir.Unit * WALL_CRAWL_SPEED
		else
			wallVelocity.VectorVelocity = Vector3.zero
		end
	end)
end

UserInputService.JumpRequest:Connect(function()
	if currentState == "WALL_CRAWL" then
		local hrp = player.Character.HumanoidRootPart
		local jumpVector = (camera.CFrame.LookVector + Vector3.new(0, 1, 0)).Unit
		resetSystem(true)
		hrp:ApplyImpulse(jumpVector * hrp.AssemblyMass * JUMP_IMPULSE * 2.5)
	end
end)

local function startGrabbing(target)
	currentState = "GRABBING"
	grabbedPart = target

	local character = player.Character
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm") or character.HumanoidRootPart

	webVisual = Instance.new("Beam")
	local handAtt = Instance.new("Attachment", hand)
	local targetAtt = target:FindFirstChild("WebAttach") or Instance.new("Attachment", target)
	targetAtt.Name = "WebAttach"
	webVisual.Attachment0 = handAtt
	webVisual.Attachment1 = targetAtt
	webVisual.FaceCamera = true
	webVisual.Width0 = 0.1
	webVisual.Width1 = 0.4
	webVisual.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	webVisual.Parent = hand

	grabAlign = Instance.new("AlignPosition")
	grabAlign.Mode = Enum.PositionAlignmentMode.OneAttachment
	grabAlign.Attachment0 = targetAtt
	grabAlign.Position = target.Position
	grabAlign.MaxForce = math.huge
	grabAlign.Responsiveness = 200
	grabAlign.Parent = target
end

local function initiateAction()
	if currentState ~= "IDLE" then return end

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

	if not result then return end

	if not result.Instance.Anchored then
		startGrabbing(result.Instance)
		return
	end

	currentState = "SWINGING"
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm") or hrp
	local playerAttachment = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)

	targetHighlight = Instance.new("Part")
	targetHighlight.Size = Vector3.new(1.5, 1.5, 1.5)
	targetHighlight.Position = result.Position
	targetHighlight.Anchored = true
	targetHighlight.CanCollide = false
	targetHighlight.Material = Enum.Material.Neon
	targetHighlight.Color = Color3.fromRGB(255, 0, 0)
	targetHighlight.Transparency = 0.2
	targetHighlight.Shape = Enum.PartType.Ball
	targetHighlight.Parent = Workspace

	anchorPart = Instance.new("Part")
	anchorPart.Anchored = true
	anchorPart.CanCollide = false
	anchorPart.Transparency = 1
	anchorPart.Position = hand.Position
	anchorPart.Parent = Workspace
	local anchorAttachment = Instance.new("Attachment", anchorPart)

	webVisual = Instance.new("Beam")
	webVisual.Attachment0 = playerAttachment
	webVisual.Attachment1 = anchorAttachment
	webVisual.FaceCamera = true
	webVisual.Width0 = 0.2
	webVisual.Width1 = 0.2
	webVisual.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	webVisual.Parent = hrp

	local extTween = TweenService:Create(anchorPart, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position = result.Position})
	extTween:Play()

	task.spawn(function()
		extTween.Completed:Wait()
		if currentState ~= "SWINGING" then return end

		TweenService:Create(targetHighlight, TweenInfo.new(0.3), {Size = Vector3.new(0.5, 0.5, 0.5), Transparency = 0.8}):Play()

		local distance = (hrp.Position - result.Position).Magnitude
		--rope constraint is the actual pendulum
		ropeConstraint = Instance.new("RopeConstraint")
		ropeConstraint.Attachment0 = playerAttachment
		ropeConstraint.Attachment1 = anchorAttachment
		ropeConstraint.Visible = false

		ropeConstraint.Length = distance * 0.85
		ropeConstraint.Parent = hrp

		boostForce = Instance.new("VectorForce")
		boostForce.Attachment0 = playerAttachment
		boostForce.ApplyAtCenterOfMass = true
		boostForce.RelativeTo = Enum.ActuatorRelativeTo.World
		boostForce.Parent = hrp

		swingGyro = Instance.new("AlignOrientation")
		swingGyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
		swingGyro.Attachment0 = playerAttachment
		swingGyro.MaxTorque = 100000
		swingGyro.Responsiveness = 50
		swingGyro.Parent = hrp

		humanoid.PlatformStand = true

		local mass = hrp.AssemblyMass
		local isGrounded = humanoid.FloorMaterial ~= Enum.Material.Air
		if isGrounded then
			hrp:ApplyImpulse(Vector3.new(0, mass * JUMP_IMPULSE, 0))
		else
			hrp:ApplyImpulse(Vector3.new(0, mass * (JUMP_IMPULSE * 0.3), 0))
		end

		connectionLoop = RunService.RenderStepped:Connect(function()
			if currentState ~= "SWINGING" then return end

			local moveVector = hrp.AssemblyLinearVelocity

			if moveVector.Magnitude > 10 then
				--ray ahead of movement to catch walls
				local crashRay = Workspace:Raycast(hrp.Position, moveVector.Unit * 3.5, rayParams)
				if crashRay and crashRay.Instance.Anchored then
					if math.abs(crashRay.Normal.Y) < 0.5 then
						startWallCrawl(crashRay.Normal)
						return
					end
				end
			end

			local lookDir = camera.CFrame.LookVector
			local rightDir = camera.CFrame.RightVector
			local horizontalLook = Vector3.new(lookDir.X, 0, lookDir.Z).Unit
			local horizontalRight = Vector3.new(rightDir.X, 0, rightDir.Z).Unit

			local strafeInput = 0
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then strafeInput = -1 end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then strafeInput = 1 end

			local upwardBuoyancy = mass * Workspace.Gravity * BUOYANCY_MULTIPLIER
			local forwardForce = horizontalLook * MOMENTUM_FORCE
			local sidewaysForce = horizontalRight * (strafeInput * STRAFE_FORCE)

			--energy gets added back here so its not a dead pendulum
			boostForce.Force = forwardForce + sidewaysForce + Vector3.new(0, upwardBuoyancy, 0)

			local horizontalVel = Vector3.new(moveVector.X, 0, moveVector.Z)
			if horizontalVel.Magnitude > 1 then
				swingGyro.CFrame = CFrame.lookAt(Vector3.zero, horizontalVel.Unit)
			else
				swingGyro.CFrame = CFrame.lookAt(Vector3.zero, horizontalLook)
			end
		end)
	end)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.E and currentState == "SWINGING" then
		if tick() - lastBoostTime > 1.5 then
			lastBoostTime = tick()
			local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if hrp then
				local boostDir = camera.CFrame.LookVector
				hrp:ApplyImpulse(boostDir * hrp.AssemblyMass * E_BOOST_FORCE)
			end
		end
	end
end)

tool.Activated:Connect(initiateAction)

tool.Deactivated:Connect(function()
	if currentState == "SWINGING" or currentState == "GRABBING" then
		resetSystem(true)
	end
end)

tool.Unequipped:Connect(function()
	resetSystem(false)
end)
