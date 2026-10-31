local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local tool = script.Parent

local ANIM_IDS = {
	SwingLaunch = "rbxassetid://0000000000",
	SwingLoop   = "rbxassetid://0000000000",
	WallIdle    = "rbxassetid://0000000000",
	WallUp      = "rbxassetid://0000000000",
	WallDown    = "rbxassetid://0000000000",
	WallLeft    = "rbxassetid://0000000000",
	WallRight   = "rbxassetid://0000000000",
	SlowFall    = "rbxassetid://0000000000"
}

local MAX_WEB_DISTANCE = 350
local MOMENTUM_FORCE = 1200
local STRAFE_FORCE = 800
local BUOYANCY_MULTIPLIER = 0.65
local MIN_WEB_LENGTH = 18
local VERTICAL_BOOST_GROUND = 45

local FALL_FLOAT_STRENGTH = 0.5
local FALL_FLOAT_DURATION = 2.0

local CLIMB_SPEED = 25
local JUMP_OFF_FORCE = 40

local isSwinging = false
local isClimbing = false

local anchorPart = nil
local ropeConstraint = nil
local boostForce = nil
local webVisual = nil
local swingGyro = nil
local swingConnection = nil
local climbVelocity = nil

local loadedAnims = {}
local currentClimbAnim = nil

local function loadAnims(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	for name, id in pairs(ANIM_IDS) do
		if not loadedAnims[name] then
			local anim = Instance.new("Animation")
			anim.AnimationId = id
			loadedAnims[name] = animator:LoadAnimation(anim)
		end
	end
end

local function stopAllAnims()
	for _, track in pairs(loadedAnims) do
		track:Stop(0.2)
	end
	currentClimbAnim = nil
end

--floaty fall after release, partial anti gravity for a sec
local function applyFloatyFall()
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	if loadedAnims.SlowFall then loadedAnims.SlowFall:Play(0.2) end

	local floatForce = Instance.new("VectorForce")
	local att = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)
	floatForce.Attachment0 = att
	floatForce.RelativeTo = Enum.ActuatorRelativeTo.World
	floatForce.Force = Vector3.new(0, hrp.AssemblyMass * Workspace.Gravity * FALL_FLOAT_STRENGTH, 0)
	floatForce.Parent = hrp

	task.delay(FALL_FLOAT_DURATION, function()
		if floatForce then floatForce:Destroy() end
		if loadedAnims.SlowFall then loadedAnims.SlowFall:Stop(0.3) end
	end)
end

local function stopClimbing()
	isClimbing = false
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	if humanoid then
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end

	if climbVelocity then climbVelocity:Destroy() climbVelocity = nil end

	if swingGyro then
		swingGyro:Destroy()
		swingGyro = nil
	end

	if swingConnection then swingConnection:Disconnect() swingConnection = nil end
	stopAllAnims()
end

--release keeps your momentum
local function stopSwing()
	if not isSwinging then return end
	isSwinging = false

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then humanoid.PlatformStand = false end

	if anchorPart then anchorPart:Destroy() anchorPart = nil end
	if ropeConstraint then ropeConstraint:Destroy() ropeConstraint = nil end
	if boostForce then boostForce:Destroy() boostForce = nil end
	if webVisual then webVisual:Destroy() webVisual = nil end
	if swingGyro then swingGyro:Destroy() swingGyro = nil end
	if swingConnection then swingConnection:Disconnect() swingConnection = nil end

	stopAllAnims()
	applyFloatyFall()
end

local function startClimbing(surfaceNormal)
	stopSwing()
	isClimbing = true

	local character = player.Character
	local hrp = character.HumanoidRootPart
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	humanoid.PlatformStand = true

	hrp.AssemblyLinearVelocity = Vector3.zero
	local attachment = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)

	--gyro so the char doesnt spin or flatten out
	swingGyro = Instance.new("AlignOrientation")
	swingGyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
	swingGyro.Attachment0 = attachment
	swingGyro.MaxTorque = math.huge
	swingGyro.Responsiveness = 200
	swingGyro.Parent = hrp

	climbVelocity = Instance.new("LinearVelocity")
	climbVelocity.Attachment0 = attachment
	climbVelocity.MaxForce = math.huge
	climbVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	climbVelocity.Parent = hrp

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}

	swingConnection = RunService.RenderStepped:Connect(function()
		if not isClimbing then return end

		local stickCheck = Workspace:Raycast(hrp.Position, -surfaceNormal * 6, rayParams)
		if not stickCheck then
			stopClimbing()
			return
		end

		local isCeiling = surfaceNormal.Y < -0.6
		local moveDir = Vector3.zero
		local camForward = camera.CFrame.LookVector * Vector3.new(1,0,1)
		local camRight = camera.CFrame.RightVector * Vector3.new(1,0,1)

		if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + (isCeiling and camForward or Vector3.new(0,1,0)) end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - (isCeiling and camForward or Vector3.new(0,1,0)) end

		if not isCeiling then
			--cross producting vectors for wall climb coords
			local wallRight = Vector3.new(0,1,0):Cross(surfaceNormal).Unit
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - wallRight end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + wallRight end
		else
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - camRight end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + camRight end
		end

		if isCeiling then
			local charUp = surfaceNormal
			local charForward = moveDir.Magnitude > 0.1 and moveDir.Unit or camForward.Unit
			local charRight = charForward:Cross(charUp).Unit
			--fromMatrix builds the rotation from the 3 perp vectors
			swingGyro.CFrame = CFrame.fromMatrix(Vector3.zero, charRight, charUp, -charForward)
		else
			swingGyro.CFrame = CFrame.lookAt(Vector3.zero, -surfaceNormal, Vector3.new(0, 1, 0))
		end

		local newAnim = loadedAnims.WallIdle
		if moveDir.Magnitude > 0.1 then
			if not isCeiling then
				if UserInputService:IsKeyDown(Enum.KeyCode.W) then newAnim = loadedAnims.WallUp
				elseif UserInputService:IsKeyDown(Enum.KeyCode.S) then newAnim = loadedAnims.WallDown
				elseif UserInputService:IsKeyDown(Enum.KeyCode.A) then newAnim = loadedAnims.WallLeft
				elseif UserInputService:IsKeyDown(Enum.KeyCode.D) then newAnim = loadedAnims.WallRight end
			end
		end

		if currentClimbAnim ~= newAnim then
			if currentClimbAnim then currentClimbAnim:Stop(0.2) end
			currentClimbAnim = newAnim
			if currentClimbAnim then currentClimbAnim:Play(0.2) end
		end

		local inwardForce = -5
		if isCeiling and (hrp.Position - stickCheck.Position).Magnitude < 2.8 then
			inwardForce = 0
		end

		if moveDir.Magnitude > 0 then
			climbVelocity.VectorVelocity = (moveDir.Unit * CLIMB_SPEED) + (surfaceNormal * inwardForce)
		else
			climbVelocity.VectorVelocity = surfaceNormal * inwardForce
		end
	end)
end

local function startSwing()
	if isClimbing then return end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then return end

	loadAnims(humanoid)

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	--raycast from where the camera looks to find the anchor, no autotarget
	local rayOrigin = camera.CFrame.Position
	local rayDirection = camera.CFrame.LookVector * MAX_WEB_DISTANCE
	local result = Workspace:Raycast(rayOrigin, rayDirection, rayParams)

	if result and result.Instance.Anchored then
		isSwinging = true

		if loadedAnims.SwingLaunch then
			loadedAnims.SwingLaunch:Play(0.1)
			task.delay(0.4, function()
				if isSwinging and loadedAnims.SwingLoop then loadedAnims.SwingLoop:Play(0.2) end
			end)
		end

		anchorPart = Instance.new("Part")
		anchorPart.Size = Vector3.one
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
		webVisual.Attachment0 = (character:FindFirstChild("RightHand") and character.RightHand:FindFirstChild("RightGripAttachment")) or playerAttachment
		webVisual.Attachment1 = anchorAttachment
		webVisual.FaceCamera = true
		webVisual.Width0, webVisual.Width1 = 0.2, 0.2
		webVisual.Color = ColorSequence.new(Color3.new(1,1,1))
		webVisual.Parent = hrp

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

		if humanoid.FloorMaterial ~= Enum.Material.Air then
			hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + Vector3.new(0, VERTICAL_BOOST_GROUND, 0)
		end

		swingConnection = RunService.RenderStepped:Connect(function()
			if not isSwinging then return end

			local velocity = hrp.AssemblyLinearVelocity
			if velocity.Magnitude > 12 then
				local collisionRay = Workspace:Raycast(hrp.Position, velocity.Unit * 5, rayParams)
				if collisionRay and collisionRay.Instance.Anchored then
					if collisionRay.Normal.Y < 0.8 then
						startClimbing(collisionRay.Normal)
						return
					end
				end
			end

			local currentDistance = (hrp.Position - anchorPart.Position).Magnitude
			if currentDistance < ropeConstraint.Length then
				ropeConstraint.Length = math.max(MIN_WEB_LENGTH, currentDistance + 0.5)
			end

			local lookDir = camera.CFrame.LookVector
			local horizontalLook = Vector3.new(lookDir.X, 0, lookDir.Z).Unit
			local horizontalRight = camera.CFrame.RightVector * Vector3.new(1,0,1)

			local strafeInput = 0
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then strafeInput = -1 end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then strafeInput = 1 end

			local buoyancy = hrp.AssemblyMass * Workspace.Gravity * BUOYANCY_MULTIPLIER
			local forwardPush = horizontalLook * MOMENTUM_FORCE
			local strafePush = horizontalRight * (strafeInput * STRAFE_FORCE)

			--energy gets added back here so its not a dead pendulum
			boostForce.Force = forwardPush + strafePush + Vector3.new(0, buoyancy, 0)

			local horizVel = Vector3.new(velocity.X, 0, velocity.Z)
			if horizVel.Magnitude > 2 then
				swingGyro.CFrame = CFrame.lookAt(Vector3.zero, horizVel.Unit)
			else
				swingGyro.CFrame = CFrame.lookAt(Vector3.zero, horizontalLook)
			end
		end)
	end
end

tool.Activated:Connect(function()
	if not isSwinging and not isClimbing then startSwing() end
end)

tool.Deactivated:Connect(stopSwing)
tool.Unequipped:Connect(function() stopSwing() stopClimbing() end)

UserInputService.JumpRequest:Connect(function()
	if isClimbing then
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local jumpDir = (camera.CFrame.LookVector + Vector3.new(0, 1.2, 0)).Unit
			stopClimbing()
			hrp:ApplyImpulse(jumpDir * hrp.AssemblyMass * JUMP_OFF_FORCE)
		end
	end
end)
