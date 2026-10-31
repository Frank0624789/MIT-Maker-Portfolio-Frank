local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local tool = script.Parent

local ANIM_IDS = {
	SwingLaunch = "rbxassetid://0000000000",
	SwingLoop   = "rbxassetid://113176516260267",
	WallIdle    = "rbxassetid://75332896402398",
	WallUp      = "rbxassetid://131088953822645",
	WallDown    = "rbxassetid://0000000000",
	WallLeft    = "rbxassetid://0000000000",
	WallRight   = "rbxassetid://0000000000",
	SlowFall    = "rbxassetid://0000000000",
	WebZip      = "rbxassetid://113677600826400",
	GlideLoop   = "rbxassetid://120630556043999"

}

local MAX_WEB_DISTANCE = 350
local MOMENTUM_FORCE = 1200
local UPWARD_SWING_BOOST = 1800
local STRAFE_FORCE = 800
local BUOYANCY_MULTIPLIER = 0.65
local MIN_WEB_LENGTH = 18

local VERTICAL_BOOST_GROUND = 45

local FALL_FLOAT_STRENGTH = 0.35
local FALL_FLOAT_DURATION = 1.2

local CLIMB_SPEED = 50
local JUMP_OFF_FORCE = 40

local ZIP_COOLDOWN = 1.5
local MAX_ZIP_DISTANCE = 400
local ZIP_SPEED = 250

local DOUBLE_TAP_THRESHOLD = 0.25
local GLIDE_SPEED = 85

local isSwinging = false
local isClimbing = false
local isZipping = false
local isGliding = false

local anchorPart = nil
local ropeConstraint = nil
local boostForce = nil
local activeWebs = {}
local swingGyro = nil
local swingConnection = nil
local climbVelocity = nil
local pullDownVelocity = nil
local zipVelocity = nil
local glideVelocity = nil
local glideGyro = nil
local glideConnection = nil

local loadedAnims = {}
local currentClimbAnim = nil
local currentFloatForce = nil

local lastZipTime = 0
local lastATime = 0
local lastDTime = 0
local lastWallJumpTime = 0
local turnDampener = 1.0

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

local function suppressDefaultAnims(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then return end

	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if track.Priority == Enum.AnimationPriority.Core or track.Priority == Enum.AnimationPriority.Idle or track.Priority == Enum.AnimationPriority.Movement then
			track:Stop(0.1)
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
	currentFloatForce.Force = Vector3.yAxis * (hrp.AssemblyMass * Workspace.Gravity * FALL_FLOAT_STRENGTH)
	currentFloatForce.Parent = hrp

	task.delay(FALL_FLOAT_DURATION, function()
		clearFloatForce()
	end)
end

local function resetStates(preserveMomentum)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local oldVel = hrp and hrp.AssemblyLinearVelocity or Vector3.zero

	isSwinging = false
	isClimbing = false
	isZipping = false
	isGliding = false
	camera.CameraType = Enum.CameraType.Custom

	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
		humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, true)
		if not preserveMomentum then
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
	end

	if anchorPart then anchorPart:Destroy() anchorPart = nil end
	if ropeConstraint then ropeConstraint:Destroy() ropeConstraint = nil end
	if boostForce then boostForce:Destroy() boostForce = nil end
	if swingGyro then swingGyro:Destroy() swingGyro = nil end
	if climbVelocity then climbVelocity:Destroy() climbVelocity = nil end
	if pullDownVelocity then pullDownVelocity:Destroy() pullDownVelocity = nil end
	if zipVelocity then zipVelocity:Destroy() zipVelocity = nil end
	if swingConnection then swingConnection:Disconnect() swingConnection = nil end

	if glideVelocity then glideVelocity:Destroy() glideVelocity = nil end
	if glideGyro then glideGyro:Destroy() glideGyro = nil end
	if glideConnection then glideConnection:Disconnect() glideConnection = nil end

	for _, web in ipairs(activeWebs) do
		if web then web:Destroy() end
	end
	table.clear(activeWebs)

	stopAllAnims()

	if preserveMomentum and hrp then
		hrp.AssemblyLinearVelocity = oldVel
	end
end

--release keeps your momentum
local function stopSwing()
	if not isSwinging and not isZipping then return end
	resetStates(false)
	applyFloatyFall()

	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if hrp then
		local vel = hrp.AssemblyLinearVelocity
		local newY = math.min(vel.Y + 35, 100)
		hrp.AssemblyLinearVelocity = Vector3.new(vel.X, newY, vel.Z)
	end
end

local startClimbing

local function stopGlide()
	if not isGliding then return end
	resetStates(true)
end

--glide, velocity steered off the camera look
local function startGlide()
	if isSwinging or isClimbing or isZipping then return end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then return end

	resetStates(true)
	clearFloatForce()
	isGliding = true

	humanoid.PlatformStand = true
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	suppressDefaultAnims(humanoid)

	if loadedAnims.GlideLoop then loadedAnims.GlideLoop:Play(0.2) end

	local att0 = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)

	glideVelocity = Instance.new("LinearVelocity")
	glideVelocity.Attachment0 = att0
	glideVelocity.MaxForce = math.huge
	glideVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	glideVelocity.Parent = hrp

	--gyro so the char doesnt spin or flatten out
	glideGyro = Instance.new("AlignOrientation")
	glideGyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
	glideGyro.Attachment0 = att0
	glideGyro.MaxTorque = 100000
	glideGyro.Responsiveness = 80
	glideGyro.Parent = hrp

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}

	glideConnection = RunService.RenderStepped:Connect(function()
		if not isGliding then return end
		suppressDefaultAnims(humanoid)

		local camLook = camera.CFrame.LookVector
		local camRight = camera.CFrame.RightVector

		local steer = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then steer = -1 end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then steer = 1 end

		local forwardDir = (camLook * Vector3.new(1,0,1)).Unit
		local rightDir = (camRight * Vector3.new(1,0,1)).Unit
		local moveDir = (forwardDir + (rightDir * steer * 0.6)).Unit

		local downwardSpeed = -20
		if camLook.Y < -0.1 then
			downwardSpeed = math.clamp(camLook.Y * 80, -80, -20)
		end

		glideVelocity.VectorVelocity = (moveDir * GLIDE_SPEED) + Vector3.new(0, downwardSpeed, 0)

		local tilt = CFrame.Angles(0, 0, math.rad(-steer * 35))
		glideGyro.CFrame = CFrame.lookAt(Vector3.zero, moveDir) * tilt

		--ray ahead of movement to catch walls
		local wallCheck = Workspace:Raycast(hrp.Position, moveDir * 5, rayParams)
		if wallCheck and wallCheck.Instance.Anchored and wallCheck.Normal.Y < 0.8 then
			startClimbing(wallCheck.Normal)
			return
		end

		if Workspace:Raycast(hrp.Position, Vector3.new(0, -3, 0), rayParams) then
			stopGlide()
		end
	end)
end

--sharp turn, rotates anchor + velocity 90 deg
local function performSharpTurn(turnDirection)
	if not isSwinging or not anchorPart then return end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local turnAngle = math.rad(-90 * turnDirection)
	local rotCFrame = CFrame.Angles(0, turnAngle, 0)

	local newCamLook = rotCFrame * camera.CFrame.LookVector
	local newCamPos = camera.CFrame.Position

	local currentCamCFrame = camera.CFrame
	local relativeOffset = currentCamCFrame:ToObjectSpace(anchorPart.CFrame)
	local newCamCFrame = CFrame.lookAt(newCamPos, newCamPos + newCamLook)
	local newAnchorCFrame = newCamCFrame:ToWorldSpace(relativeOffset)

	local targetHeight = anchorPart.Position.Y
	anchorPart.Position = Vector3.new(newAnchorCFrame.Position.X, targetHeight, newAnchorCFrame.Position.Z)

	local toAnchorHoriz = Vector3.new(anchorPart.Position.X - hrp.Position.X, 0, anchorPart.Position.Z - hrp.Position.Z).Unit
	local outwardPush = -toAnchorHoriz * 30

	camera.CameraType = Enum.CameraType.Scriptable
	local tweenInfo = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local camTween = TweenService:Create(camera, tweenInfo, {CFrame = newCamCFrame})
	camTween:Play()

	camTween.Completed:Connect(function()
		if isSwinging then camera.CameraType = Enum.CameraType.Custom end
	end)

	local currentVel = hrp.AssemblyLinearVelocity
	local horizontalVel = Vector3.new(currentVel.X, 0, currentVel.Z)
	local newHorizVel = rotCFrame * horizontalVel

	hrp.AssemblyLinearVelocity = Vector3.new(newHorizVel.X * 0.6, currentVel.Y, newHorizVel.Z * 0.6) + outwardPush
	turnDampener = 0.25
end

startClimbing = function(surfaceNormal)
	resetStates(false)
	clearFloatForce()
	isClimbing = true

	local character = player.Character
	local hrp = character.HumanoidRootPart
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	humanoid.PlatformStand = true
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

	hrp.AssemblyLinearVelocity = Vector3.zero
	local attachment = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)

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
		suppressDefaultAnims(humanoid)

		local stickCheck = Workspace:Raycast(hrp.Position, -surfaceNormal * 6, rayParams)
		if not stickCheck then
			resetStates(false)
			return
		end

		local isCeiling = surfaceNormal.Y < -0.6
		local moveDir = Vector3.zero
		local camForward = camera.CFrame.LookVector * Vector3.new(1,0,1)
		local camRight = camera.CFrame.RightVector * Vector3.new(1,0,1)

		if isCeiling then
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += camForward end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= camForward end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= camRight end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += camRight end
		else
			local wallUp = Vector3.yAxis
			--cross producting vectors for wall climb coords
			local wallRight = wallUp:Cross(surfaceNormal).Unit

			if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += wallUp end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= wallUp end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= wallRight end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += wallRight end
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
			swingGyro.CFrame = CFrame.lookAt(Vector3.zero, -surfaceNormal, Vector3.yAxis)
		end

		local newAnim = loadedAnims.WallIdle
		if moveDir.Magnitude > 0.1 then
			if not isCeiling then
				local wallUpAxis = Vector3.yAxis
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
			local distToCeil = (hrp.Position - stickCheck.Position).Magnitude
			if distToCeil < 2.6 then
				inwardForce = 15
			elseif distToCeil < 3.1 then
				inwardForce = 0
			else
				inwardForce = -15
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
	local currentTime = os.clock()
	if currentTime - lastZipTime < ZIP_COOLDOWN then return end

	local character = player.Character
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}

	local origin = camera.CFrame.Position
	local dir = camera.CFrame.LookVector * MAX_ZIP_DISTANCE
	local result = Workspace:Raycast(origin, dir, rayParams)

	local hitSomething = result ~= nil
	local targetPos = hitSomething and result.Position or (origin + dir)

	lastZipTime = currentTime
	resetStates(true)
	clearFloatForce()
	isZipping = true

	local hrp = character.HumanoidRootPart
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	humanoid.PlatformStand = true
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	if loadedAnims.WebZip then loadedAnims.WebZip:Play(0.1) end

	anchorPart = Instance.new("Part")
	anchorPart.Size = Vector3.one
	anchorPart.Position = targetPos
	anchorPart.Anchored = true
	anchorPart.Transparency = 1
	anchorPart.CanCollide = false
	anchorPart.Parent = Workspace

	local att0 = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)
	local att1 = Instance.new("Attachment", anchorPart)

	if hitSomething then
		local rightHand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm") or hrp
		local leftHand = character:FindFirstChild("LeftHand") or character:FindFirstChild("Left Arm") or hrp

		local rightAtt = Instance.new("Attachment", rightHand)
		local leftAtt = Instance.new("Attachment", leftHand)
		table.insert(activeWebs, rightAtt)
		table.insert(activeWebs, leftAtt)

		local rightWeb = Instance.new("Beam")
		rightWeb.Attachment0 = rightAtt
		rightWeb.Attachment1 = att1
		rightWeb.FaceCamera = true
		rightWeb.Width0, rightWeb.Width1 = 0.2, 0.2
		rightWeb.Color = ColorSequence.new(Color3.new(1,1,1))
		rightWeb.Parent = hrp
		table.insert(activeWebs, rightWeb)

		local leftWeb = Instance.new("Beam")
		leftWeb.Attachment0 = leftAtt
		leftWeb.Attachment1 = att1
		leftWeb.FaceCamera = true
		leftWeb.Width0, leftWeb.Width1 = 0.2, 0.2
		leftWeb.Color = ColorSequence.new(Color3.new(1,1,1))
		leftWeb.Parent = hrp
		table.insert(activeWebs, leftWeb)
	end

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

	swingConnection = RunService.RenderStepped:Connect(function()
		if not isZipping then return end
		suppressDefaultAnims(humanoid)

		local toTarget = targetPos - hrp.Position
		zipVelocity.VectorVelocity = toTarget.Unit * ZIP_SPEED

		local velocity = hrp.AssemblyLinearVelocity
		if velocity.Magnitude > 12 then
			local collisionRay = Workspace:Raycast(hrp.Position, velocity.Unit * 5, rayParams)
			if collisionRay and collisionRay.Instance.Anchored and collisionRay.Normal.Y < 0.8 then
				startClimbing(collisionRay.Normal)
				return
			end
		end

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

	local preSwingVel = Vector3.zero
	if isGliding then
		local character = player.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart")
		if hrp then preSwingVel = hrp.AssemblyLinearVelocity end
		resetStates(true)
	end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then return end

	if preSwingVel.Magnitude > 0 then
		hrp.AssemblyLinearVelocity = preSwingVel
	end

	loadAnims(humanoid)
	clearFloatForce()

	turnDampener = 1.0

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

		local swingWeb = Instance.new("Beam")
		swingWeb.Attachment0 = playerAttachment
		swingWeb.Attachment1 = anchorAttachment
		swingWeb.FaceCamera = true
		swingWeb.Width0, swingWeb.Width1 = 0.2, 0.2
		swingWeb.Color = ColorSequence.new(Color3.new(1,1,1))
		swingWeb.Parent = hrp
		table.insert(activeWebs, swingWeb)

		humanoid.PlatformStand = true
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

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
				suppressDefaultAnims(humanoid)
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
			hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + Vector3.yAxis * VERTICAL_BOOST_GROUND
		end

		swingConnection = RunService.RenderStepped:Connect(function(dt)
			if not isSwinging then return end
			suppressDefaultAnims(humanoid)

			if turnDampener < 1.0 then
				turnDampener = math.min(1.0, turnDampener + (dt * 0.75))
			end

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
			local horizVel = Vector3.new(velocity.X, 0, velocity.Z)

			local strafeInput = 0
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then strafeInput = -1 end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then strafeInput = 1 end

			local floorBufferForce = 0
			local groundCheck = Workspace:Raycast(hrp.Position, Vector3.new(0, -6, 0), rayParams)
			if groundCheck then
				local distToFloor = (hrp.Position - groundCheck.Position).Magnitude
				if distToFloor < 5 then
					local severity = 1 - (distToFloor / 5)
					floorBufferForce = hrp.AssemblyMass * Workspace.Gravity * (severity * 3)
					if velocity.Y < 0 then
						hrp.AssemblyLinearVelocity = Vector3.new(velocity.X, velocity.Y * 0.9, velocity.Z)
					end
				end
			end

			local buoyancy = hrp.AssemblyMass * Workspace.Gravity * BUOYANCY_MULTIPLIER
			local forwardPush = horizontalLook * (MOMENTUM_FORCE * turnDampener)
			local strafePush = horizontalRight * (strafeInput * (STRAFE_FORCE * turnDampener))

			local upwardAssist = 0
			if lookDir.Y > 0 then
				upwardAssist = lookDir.Y * (UPWARD_SWING_BOOST * turnDampener)
			end

			--energy gets added back here so its not a dead pendulum
			boostForce.Force = forwardPush + strafePush + Vector3.yAxis * (buoyancy + floorBufferForce + upwardAssist)

			local faceDir = horizVel.Magnitude > 2 and horizVel.Unit or horizontalLook
			local tilt = CFrame.Angles(0, 0, math.rad(-strafeInput * 25))
			swingGyro.CFrame = CFrame.lookAt(Vector3.zero, faceDir) * tilt
		end)
	end
end

tool.Activated:Connect(function()
	if not isSwinging and not isClimbing and not isZipping then startSwing() end
end)

tool.Deactivated:Connect(stopSwing)
tool.Unequipped:Connect(function()
	resetStates(false)
	clearFloatForce()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not tool.Parent:IsA("Model") then return end
	local currentTime = os.clock()

	if input.KeyCode == Enum.KeyCode.Space then
		local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
		if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
			if currentTime - lastWallJumpTime < 0.25 then return end

			if isGliding then
				stopGlide()
			elseif not isSwinging and not isZipping and not isClimbing then
				startGlide()
			end
		end
	end

	if isSwinging then
		if input.KeyCode == Enum.KeyCode.A then
			if currentTime - lastATime < DOUBLE_TAP_THRESHOLD then
				performSharpTurn(-1)
			end
			lastATime = currentTime
		elseif input.KeyCode == Enum.KeyCode.D then
			if currentTime - lastDTime < DOUBLE_TAP_THRESHOLD then
				performSharpTurn(1)
			end
			lastDTime = currentTime
		end
	end

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
			lastWallJumpTime = os.clock()
			local jumpDir = (camera.CFrame.LookVector + Vector3.yAxis * 1.2).Unit
			resetStates(false)
			hrp:ApplyImpulse(jumpDir * hrp.AssemblyMass * JUMP_OFF_FORCE)
		end
	end
end)
