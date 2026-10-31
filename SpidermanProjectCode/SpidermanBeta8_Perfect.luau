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
	SlowFall    = "rbxassetid://0000000000",
	WebZip      = "rbxassetid://0000000000"
}

local MAX_WEB_DISTANCE = 350
local MOMENTUM_FORCE = 1200
local STRAFE_FORCE = 800
local BUOYANCY_MULTIPLIER = 0.65
local MIN_WEB_LENGTH = 18

local VERTICAL_BOOST_GROUND = 45

local FALL_FLOAT_STRENGTH = 0.35
local FALL_FLOAT_DURATION = 1.2

local CLIMB_SPEED = 50
local JUMP_OFF_FORCE = 40

local ZIP_COOLDOWN = 4.0
local MAX_ZIP_DISTANCE = 150
local ZIP_SPEED = 250

local isSwinging = false
local isClimbing = false
local isZipping = false

local anchorPart = nil
local ropeConstraint = nil
local boostForce = nil
local webVisual = nil
local swingGyro = nil
local swingConnection = nil
local climbVelocity = nil
local pullDownVelocity = nil
local zipVelocity = nil

local loadedAnims = {}
local currentClimbAnim = nil
local currentFloatForce = nil
local lastZipTime = 0

local function loadAnims(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	for name, id in pairs(ANIM_IDS) do
		if not loadedAnims[name] then
			local anim = Instance.new("Animation")
			anim.AnimationId = id
			local track = animator:LoadAnimation(anim)

			track.Priority = Enum.AnimationPriority.Action

			loadedAnims[name] = track
		end
	end
end

local function stopAllAnims()
	for _, track in pairs(loadedAnims) do
		if track.IsPlaying then track:Stop(0.2) end
	end
	currentClimbAnim = nil
end

local function showZipError()
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then return end
	local screenGui = playerGui:FindFirstChild("ScreenGui")
	if not screenGui then return end
	local textLabel = screenGui:FindFirstChild("TextLabel")
	if not textLabel then return end

	textLabel.Text = "YOU MUST BE IN THE AIR TO WEBZIP"
	textLabel.Visible = true

	task.delay(2, function()
		if textLabel.Text == "YOU MUST BE IN THE AIR TO WEBZIP" then
			textLabel.Visible = false
		end
	end)
end

local function clearFloatForce()
	if currentFloatForce then
		currentFloatForce:Destroy()
		currentFloatForce = nil
	end
	if loadedAnims.SlowFall then loadedAnims.SlowFall:Stop(0.2) end
end

--floaty fall after release, partial anti gravity for a sec
local function applyFloatyFall()
	clearFloatForce()

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	if loadedAnims.SlowFall then loadedAnims.SlowFall:Play(0.2) end

	currentFloatForce = Instance.new("VectorForce")
	local att = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)
	currentFloatForce.Attachment0 = att
	currentFloatForce.RelativeTo = Enum.ActuatorRelativeTo.World
	currentFloatForce.Force = Vector3.new(0, hrp.AssemblyMass * Workspace.Gravity * FALL_FLOAT_STRENGTH, 0)
	currentFloatForce.Parent = hrp

	task.delay(FALL_FLOAT_DURATION, function()
		clearFloatForce()
	end)
end

local function resetStates()
	isSwinging = false
	isClimbing = false
	isZipping = false

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
	end

	if anchorPart then anchorPart:Destroy() anchorPart = nil end
	if ropeConstraint then ropeConstraint:Destroy() ropeConstraint = nil end
	if boostForce then boostForce:Destroy() boostForce = nil end
	if webVisual then webVisual:Destroy() webVisual = nil end
	if swingGyro then swingGyro:Destroy() swingGyro = nil end
	if climbVelocity then climbVelocity:Destroy() climbVelocity = nil end
	if pullDownVelocity then pullDownVelocity:Destroy() pullDownVelocity = nil end
	if zipVelocity then zipVelocity:Destroy() zipVelocity = nil end
	if swingConnection then swingConnection:Disconnect() swingConnection = nil end

	stopAllAnims()
end

--release keeps your momentum
local function stopSwing()
	if not isSwinging and not isZipping then return end
	resetStates()
	applyFloatyFall()

	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if hrp then
		local vel = hrp.AssemblyLinearVelocity
		if vel.Y > 50 then
			hrp.AssemblyLinearVelocity = Vector3.new(vel.X, 50, vel.Z)
		end
	end
end

local function startClimbing(surfaceNormal)
	resetStates()
	clearFloatForce()
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
			resetStates()
			return
		end

		local isCeiling = surfaceNormal.Y < -0.6
		local moveDir = Vector3.zero
		local camForward = camera.CFrame.LookVector * Vector3.new(1,0,1)
		local camRight = camera.CFrame.RightVector * Vector3.new(1,0,1)

		if isCeiling then
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + camForward end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - camForward end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - camRight end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + camRight end
		else
			local wallUp = Vector3.new(0, 1, 0)
			--cross producting vectors for wall climb coords
			local wallRight = wallUp:Cross(surfaceNormal).Unit

			if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir = moveDir + wallUp end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir = moveDir - wallUp end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir = moveDir - wallRight end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir = moveDir + wallRight end
		end

		if isCeiling then
			local charUp = surfaceNormal
			local charForward = moveDir.Magnitude > 0.1 and moveDir.Unit or camForward.Unit

			if math.abs(charForward:Dot(charUp)) > 0.99 then
				charForward = camera.CFrame.RightVector:Cross(charUp).Unit
			end
			local charRight = charForward:Cross(charUp).Unit
			local actualForward = charUp:Cross(charRight).Unit

			--fromMatrix builds the rotation from the 3 perp vectors
			swingGyro.CFrame = CFrame.fromMatrix(Vector3.zero, charRight, charUp, -actualForward)
		else
			swingGyro.CFrame = CFrame.lookAt(Vector3.zero, -surfaceNormal, Vector3.new(0, 1, 0))
		end

		local newAnim = loadedAnims.WallIdle
		if moveDir.Magnitude > 0.1 then
			if not isCeiling then
				local wallUpAxis = Vector3.new(0, 1, 0)
				local wallRightAxis = wallUpAxis:Cross(surfaceNormal).Unit
				local upDot = moveDir.Unit:Dot(wallUpAxis)
				local rightDot = moveDir.Unit:Dot(wallRightAxis)

				if math.abs(upDot) > math.abs(rightDot) then
					newAnim = upDot > 0 and loadedAnims.WallUp or loadedAnims.WallDown
				else
					newAnim = rightDot > 0 and loadedAnims.WallRight or loadedAnims.WallLeft
				end
			else
				newAnim = loadedAnims.WallUp
			end
		end

		if currentClimbAnim ~= newAnim then
			if currentClimbAnim then currentClimbAnim:Stop(0.2) end
			currentClimbAnim = newAnim
			if currentClimbAnim then currentClimbAnim:Play(0.2) end
		end

		local inwardForce = -5
		if isCeiling then

			if (hrp.Position - stickCheck.Position).Magnitude < 2.2 then
				inwardForce = -1
			end
		end

		if moveDir.Magnitude > 0 then
			climbVelocity.VectorVelocity = (moveDir.Unit * CLIMB_SPEED) + (surfaceNormal * inwardForce)
		else
			climbVelocity.VectorVelocity = surfaceNormal * inwardForce
		end
	end)
end

--web zip, to a point or a combat target
local function startWebZip()
	if tick() - lastZipTime < ZIP_COOLDOWN then return end
	lastZipTime = tick()

	resetStates()
	clearFloatForce()
	isZipping = true

	local character = player.Character
	local hrp = character.HumanoidRootPart
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	if loadedAnims.WebZip then loadedAnims.WebZip:Play(0.1) end

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	local origin = camera.CFrame.Position
	local dir = camera.CFrame.LookVector * MAX_ZIP_DISTANCE
	local result = Workspace:Raycast(origin, dir, rayParams)

	local targetPos = result and result.Position or (origin + dir)

	anchorPart = Instance.new("Part")
	anchorPart.Size = Vector3.one
	anchorPart.Position = targetPos
	anchorPart.Anchored = true
	anchorPart.Transparency = 1
	anchorPart.CanCollide = false
	anchorPart.Parent = Workspace

	local att0 = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)
	local att1 = Instance.new("Attachment", anchorPart)

	webVisual = Instance.new("Beam")
	webVisual.Attachment0 = (character:FindFirstChild("RightHand") and character.RightHand:FindFirstChild("RightGripAttachment")) or att0
	webVisual.Attachment1 = att1
	webVisual.FaceCamera = true
	webVisual.Width0 = 0.2
	webVisual.Width1 = 0.2
	webVisual.Color = ColorSequence.new(Color3.new(1,1,1))
	webVisual.Parent = hrp

	zipVelocity = Instance.new("LinearVelocity")
	zipVelocity.Attachment0 = att0
	zipVelocity.MaxForce = math.huge
	zipVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	zipVelocity.Parent = hrp

	swingGyro = Instance.new("AlignOrientation")
	swingGyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
	swingGyro.Attachment0 = att0
	swingGyro.MaxTorque = 100000
	swingGyro.Responsiveness = 100
	swingGyro.CFrame = CFrame.lookAt(Vector3.zero, camera.CFrame.LookVector)
	swingGyro.Parent = hrp

	humanoid.PlatformStand = true

	swingConnection = RunService.RenderStepped:Connect(function()
		if not isZipping then return end

		local toTarget = targetPos - hrp.Position
		zipVelocity.VectorVelocity = toTarget.Unit * ZIP_SPEED

		if toTarget.Magnitude < 5 then
			stopSwing()
		end
	end)

	task.delay(0.6, function()
		if isZipping then stopSwing() end
	end)
end

local function startSwing()
	if isClimbing or isZipping then return end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then return end

	loadAnims(humanoid)
	clearFloatForce()

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	--raycast from where the camera looks to find the anchor, no autotarget
	local rayOrigin = camera.CFrame.Position
	local rayDirection = camera.CFrame.LookVector * MAX_WEB_DISTANCE
	local result = Workspace:Raycast(rayOrigin, rayDirection, rayParams)

	if result and result.Instance.Anchored then
		isSwinging = true

		anchorPart = Instance.new("Part")
		anchorPart.Size = Vector3.one
		anchorPart.Position = result.Position
		anchorPart.Anchored = true
		anchorPart.CanCollide = false
		anchorPart.Transparency = 1
		anchorPart.Parent = Workspace

		local anchorAttachment = Instance.new("Attachment", anchorPart)
		local playerAttachment = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)

		webVisual = Instance.new("Beam")
		webVisual.Attachment0 = (character:FindFirstChild("RightHand") and character.RightHand:FindFirstChild("RightGripAttachment")) or playerAttachment
		webVisual.Attachment1 = anchorAttachment
		webVisual.FaceCamera = true
		webVisual.Width0, webVisual.Width1 = 0.2, 0.2
		webVisual.Color = ColorSequence.new(Color3.new(1,1,1))
		webVisual.Parent = hrp

		humanoid.PlatformStand = true

		swingGyro = Instance.new("AlignOrientation")
		swingGyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
		swingGyro.Attachment0 = playerAttachment
		swingGyro.MaxTorque = 100000
		swingGyro.Responsiveness = 50
		swingGyro.Parent = hrp

		local toAnchorDir = (result.Position - hrp.Position).Unit
		local isPullingDown = (humanoid.FloorMaterial == Enum.Material.Air and toAnchorDir.Y < -0.7)

		if isPullingDown then
			pullDownVelocity = Instance.new("LinearVelocity")
			pullDownVelocity.Attachment0 = playerAttachment
			pullDownVelocity.MaxForce = math.huge
			pullDownVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
			pullDownVelocity.Parent = hrp

			swingConnection = RunService.RenderStepped:Connect(function()
				if not isSwinging then return end
				local pullDir = (anchorPart.Position - hrp.Position).Unit
				pullDownVelocity.VectorVelocity = pullDir * 120
				swingGyro.CFrame = CFrame.lookAt(Vector3.zero, pullDir)

				if (hrp.Position - anchorPart.Position).Magnitude < 4 then
					stopSwing()
				end
			end)
			return
		end

		if loadedAnims.SwingLaunch then
			loadedAnims.SwingLaunch:Play(0.1)
			task.delay(0.4, function()
				if isSwinging and loadedAnims.SwingLoop then loadedAnims.SwingLoop:Play(0.2) end
			end)
		end

		local distance = (hrp.Position - result.Position).Magnitude
		--rope constraint is the actual pendulum
		ropeConstraint = Instance.new("RopeConstraint")
		ropeConstraint.Attachment0 = playerAttachment
		ropeConstraint.Attachment1 = anchorAttachment
		ropeConstraint.Visible = false
		ropeConstraint.Length = distance
		ropeConstraint.Parent = hrp

		boostForce = Instance.new("VectorForce")
		boostForce.Attachment0 = playerAttachment
		boostForce.ApplyAtCenterOfMass = true
		boostForce.RelativeTo = Enum.ActuatorRelativeTo.World
		boostForce.Parent = hrp

		if humanoid.FloorMaterial ~= Enum.Material.Air then
			hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + Vector3.new(0, VERTICAL_BOOST_GROUND, 0)
		end

		swingConnection = RunService.RenderStepped:Connect(function()
			if not isSwinging then return end

			local velocity = hrp.AssemblyLinearVelocity
			if velocity.Magnitude > 12 then
				local collisionRay = Workspace:Raycast(hrp.Position, velocity.Unit * 5, rayParams)
				if collisionRay and collisionRay.Instance.Anchored and collisionRay.Normal.Y < 0.8 then
					startClimbing(collisionRay.Normal)
					return
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
	if not isSwinging and not isClimbing and not isZipping then startSwing() end
end)

tool.Deactivated:Connect(stopSwing)
tool.Unequipped:Connect(function()
	resetStates()
	clearFloatForce()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not tool.Parent:IsA("Model") then return end

	if input.KeyCode == Enum.KeyCode.E then
		local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
		if humanoid then
			if humanoid.FloorMaterial ~= Enum.Material.Air or isClimbing then
				showZipError()
			elseif not isZipping then
				startWebZip()
			end
		end
	end
end)

UserInputService.JumpRequest:Connect(function()
	if isClimbing then
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local jumpDir = (camera.CFrame.LookVector + Vector3.new(0, 1.2, 0)).Unit
			resetStates()
			hrp:ApplyImpulse(jumpDir * hrp.AssemblyMass * JUMP_OFF_FORCE)
		end
	end
end)
