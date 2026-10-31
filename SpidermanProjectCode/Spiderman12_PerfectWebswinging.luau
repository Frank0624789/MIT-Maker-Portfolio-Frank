local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
local camera = Workspace.CurrentCamera
local tool = script.Parent

local ANIM_IDS = {
	SwingLaunch = "rbxassetid://116534651656242",
	SwingLoop   = "rbxassetid://113176516260267",
	WallIdle    = "rbxassetid://75332896402398",
	WallUp      = "rbxassetid://131088953822645",
	WallDown    = "rbxassetid://131088953822645",
	WallLeft    = "rbxassetid://94063233191935",
	WallRight   = "rbxassetid://137981820698104",
	WallSprint  = "rbxassetid://118986028799453",
	CeilingIdle = "rbxassetid://79404469862825",
	CeilingWalk = "rbxassetid://125160423408592",
	SlowFall1   = "rbxassetid://120661040650545",
	SlowFall2   = "rbxassetid://114998067442880",
	SlowFall3   = "rbxassetid://79931396234670",
	WebZip      = "rbxassetid://134154748952137",
	GlideLoop   = "rbxassetid://120630556043999",
	WallJump    = "rbxassetid://81906676461754"
}

local CROSSHAIR_IMAGE_ID = "rbxassetid://127479709861252"

local MAX_WEB_DISTANCE = 350
local MOMENTUM_FORCE = 1200
local UPWARD_SWING_BOOST = 1800
local STRAFE_FORCE = 800
local BUOYANCY_MULTIPLIER = 0.65
local MIN_WEB_LENGTH = 18

local VERTICAL_BOOST_GROUND = 45

local FALL_FLOAT_STRENGTH = 0.35
local FALL_FLOAT_DURATION = 1.2
local NORMAL_FALL_STRENGTH = 0.25

local CLIMB_SPEED = 45
local SPRINT_CLIMB_SPEED = 75
local JUMP_OFF_FORCE = 40

local ZIP_COOLDOWN = 2.0
local MAX_ZIP_DISTANCE = 450
local ZIP_SPEED = 265

local DOUBLE_TAP_THRESHOLD = 0.25
local GLIDE_SPEED = 85

local MAX_TARGET_DISTANCE = 250
local TARGET_SCREEN_RADIUS = 110
local WEB_PROJECTILE_SPEED = 300
local SLAM_DAMAGE = 35
local SLAM_RADIUS = 25
local SLAM_IMPULSE_FORCE = 80

local isEquipped = false
local isSwinging = false
local isClimbing = false
local isCeilingCrawling = false
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

local shiftLockGyro = nil
local shiftLockConnection = nil
local crosshairGui = nil
local actionHighlight = nil

local currentTarget = nil
local targetHighlight = nil

local loadedAnims = {}
local currentClimbAnim = nil
local currentFloatForce = nil
local normalFallForce = nil
local activeSlowFallAnim = nil

local lastZipTime = 0
local lastATime = 0
local lastDTime = 0
local lastWallJumpTime = 0
local turnDampener = 1.0

local function loadAnims(humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	for name, id in pairs(ANIM_IDS) do
		local numericId = string.match(id, "%d+")
		if not loadedAnims[name] and numericId and tonumber(numericId) > 0 then
			local anim = Instance.new("Animation")
			anim.AnimationId = id
			local success, track = pcall(function() return animator:LoadAnimation(anim) end)
			if success then
				track.Priority = Enum.AnimationPriority.Action
				loadedAnims[name] = track
			end
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

local function createActionHighlight(char)
	if actionHighlight then actionHighlight:Destroy() end
	actionHighlight = Instance.new("Highlight")
	actionHighlight.FillTransparency = 1
	actionHighlight.OutlineColor = Color3.new(1, 1, 1)
	actionHighlight.OutlineTransparency = 0
	actionHighlight.Parent = char
end

local function clearFloatForce()
	if currentFloatForce then
		currentFloatForce:Destroy()
		currentFloatForce = nil
	end
	if activeSlowFallAnim then
		activeSlowFallAnim:Stop(0.2)
		activeSlowFallAnim = nil
	end
end

--floaty fall after release, partial anti gravity for a sec
local function applyFloatyFall()
	clearFloatForce()
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local randomPick = math.random(1, 3)
	activeSlowFallAnim = loadedAnims["SlowFall" .. randomPick]
	if activeSlowFallAnim then activeSlowFallAnim:Play(0.2) end

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
	isCeilingCrawling = false
	isZipping = false
	isGliding = false
	camera.CameraType = Enum.CameraType.Custom

	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.AutoRotate = not isEquipped
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

	if actionHighlight then actionHighlight:Destroy() actionHighlight = nil end
	if normalFallForce then normalFallForce:Destroy() normalFallForce = nil end

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

local attachToSurface
local startClimbing
local startCeilingCrawling

local function stopGlide()
	if not isGliding then return end
	resetStates(true)
end

--glide, velocity steered off the camera look
local function startGlide()
	if isSwinging or isClimbing or isCeilingCrawling or isZipping then return end

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then return end

	resetStates(true)
	clearFloatForce()
	isGliding = true

	createActionHighlight(character)

	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)

	loadAnims(humanoid)
	suppressDefaultAnims(humanoid)

	if loadedAnims.GlideLoop then
		loadedAnims.GlideLoop:Play(0.3)
	end

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
			attachToSurface(wallCheck.Normal)
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

--ceiling or wall depending on normal.Y
attachToSurface = function(surfaceNormal)
	if surfaceNormal.Y < -0.6 then
		startCeilingCrawling(surfaceNormal)
	else
		startClimbing(surfaceNormal)
	end
end

startClimbing = function(surfaceNormal)
	resetStates(false)
	clearFloatForce()
	isClimbing = true

	local character = player.Character
	local hrp = character.HumanoidRootPart
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

	loadAnims(humanoid)

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

		local rayOrigin = hrp.Position + (surfaceNormal * 1.5)
		local stickCheck = Workspace:Raycast(rayOrigin, -surfaceNormal * 6, rayParams)
		if not stickCheck then
			resetStates(false)
			return
		end

		surfaceNormal = stickCheck.Normal
		local moveDir = Vector3.zero
		local isSprinting = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local newAnim = loadedAnims.WallIdle

		if isSprinting then
			local camLook = camera.CFrame.LookVector
			--vector rejection, look vector with the into-wall part removed
			local wallForward = camLook - (camLook:Dot(surfaceNormal) * surfaceNormal)

			if wallForward.Magnitude > 0.01 then
				wallForward = wallForward.Unit
			else
				wallForward = Vector3.yAxis
			end
			--cross producting vectors for wall climb coords
			local wallRight = wallForward:Cross(surfaceNormal).Unit

			if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += wallForward end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= wallForward end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= wallRight end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += wallRight end

			if moveDir.Magnitude > 0.1 then
				local charUp = moveDir.Unit
				local charBack = surfaceNormal
				local charRight = charUp:Cross(charBack).Unit
				--fromMatrix builds the rotation from the 3 perp vectors
				swingGyro.CFrame = CFrame.fromMatrix(Vector3.zero, charRight, charUp, charBack)

				newAnim = loadedAnims.WallSprint or loadedAnims.WallUp
			else
				local charUp = wallForward
				local charBack = surfaceNormal
				local charRight = charUp:Cross(charBack).Unit
				swingGyro.CFrame = CFrame.fromMatrix(Vector3.zero, charRight, charUp, charBack)
			end
		else
			local wallUp = Vector3.yAxis
			local wallRight = wallUp:Cross(surfaceNormal).Unit

			if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += wallUp end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= wallUp end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= wallRight end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += wallRight end

			swingGyro.CFrame = CFrame.lookAt(Vector3.zero, -surfaceNormal, Vector3.yAxis)

			if moveDir.Magnitude > 0.1 then
				local upDot = moveDir.Unit:Dot(wallUp)
				local rightDot = moveDir.Unit:Dot(wallRight)

				if math.abs(upDot) > math.abs(rightDot) then
					newAnim = upDot > 0 and loadedAnims.WallUp or loadedAnims.WallDown
				else
					newAnim = rightDot > 0 and loadedAnims.WallRight or loadedAnims.WallLeft
				end
			end
		end

		if currentClimbAnim ~= newAnim then
			if currentClimbAnim then currentClimbAnim:Stop(0.2) end
			currentClimbAnim = newAnim
			if currentClimbAnim then currentClimbAnim:Play(0.2) end
		end

		local inwardForce = -15
		local distToWall = (hrp.Position - stickCheck.Position).Magnitude
		if distToWall < 1.2 then
			inwardForce = 0
		end

		if moveDir.Magnitude > 0 then
			local speed = isSprinting and SPRINT_CLIMB_SPEED or CLIMB_SPEED
			climbVelocity.VectorVelocity = (moveDir.Unit * speed) + (surfaceNormal * inwardForce)
		else
			climbVelocity.VectorVelocity = surfaceNormal * inwardForce
		end
	end)
end

startCeilingCrawling = function(surfaceNormal)
	resetStates(false)
	clearFloatForce()
	isCeilingCrawling = true

	local character = player.Character
	local hrp = character.HumanoidRootPart
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, false)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)

	loadAnims(humanoid)

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
		if not isCeilingCrawling then return end
		suppressDefaultAnims(humanoid)

		local rayOrigin = hrp.Position + (surfaceNormal * 0.5)
		local stickCheck = Workspace:Raycast(rayOrigin, -surfaceNormal * 8, rayParams)
		if not stickCheck then
			resetStates(false)
			return
		end

		surfaceNormal = stickCheck.Normal
		local moveDir = Vector3.zero

		local camLook = camera.CFrame.LookVector
		local camRight = camera.CFrame.RightVector

		local camForwardFlat = Vector3.new(camLook.X, 0, camLook.Z)
		if camForwardFlat.Magnitude > 0.01 then camForwardFlat = camForwardFlat.Unit else camForwardFlat = Vector3.xAxis end

		local camRightFlat = Vector3.new(camRight.X, 0, camRight.Z)
		if camRightFlat.Magnitude > 0.01 then camRightFlat = camRightFlat.Unit else camRightFlat = Vector3.zAxis end

		if UserInputService:IsKeyDown(Enum.KeyCode.W) then moveDir += camForwardFlat end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then moveDir -= camForwardFlat end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then moveDir -= camRightFlat end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then moveDir += camRightFlat end

		local charUp = surfaceNormal
		local charForward = moveDir.Magnitude > 0.1 and moveDir.Unit or camForwardFlat

		if math.abs(charForward:Dot(charUp)) > 0.99 then
			charForward = camera.CFrame.RightVector:Cross(charUp).Unit
		end
		--same coord building but for the ceiling
		local charRight = charForward:Cross(charUp).Unit
		local actualForward = charUp:Cross(charRight).Unit

		swingGyro.CFrame = CFrame.fromMatrix(Vector3.zero, charRight, charUp, -actualForward)

		local newAnim = loadedAnims.CeilingIdle
		if moveDir.Magnitude > 0.1 then
			newAnim = loadedAnims.CeilingWalk
		end

		if currentClimbAnim ~= newAnim then
			if currentClimbAnim then currentClimbAnim:Stop(0.2) end
			currentClimbAnim = newAnim
			if currentClimbAnim then currentClimbAnim:Play(0.2) end
		end

		local inwardForce = -5
		local distToCeil = (hrp.Position - stickCheck.Position).Magnitude
		if distToCeil < 2.6 then
			inwardForce = 15
		elseif distToCeil < 3.1 then
			inwardForce = 0
		else
			inwardForce = -15
		end

		if moveDir.Magnitude > 0 then
			climbVelocity.VectorVelocity = (moveDir.Unit * CLIMB_SPEED) + (surfaceNormal * inwardForce)
		else
			climbVelocity.VectorVelocity = surfaceNormal * inwardForce
		end
	end)
end

--combat web projectile
local function shootWebProjectile(targetNPC)
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp or not targetNPC then return end

	local targetHRP = targetNPC:FindFirstChild("HumanoidRootPart")
	local targetHumanoid = targetNPC:FindFirstChildOfClass("Humanoid")
	if not targetHRP or not targetHumanoid or targetHumanoid.Health <= 0 then return end

	if loadedAnims.WebZip then loadedAnims.WebZip:Play(0.05, nil, 2.5) end

	local projectile = Instance.new("Part")
	projectile.Shape = Enum.PartType.Ball
	projectile.Size = Vector3.one * 1.5
	projectile.Color = Color3.fromRGB(240, 240, 245)
	projectile.Material = Enum.Material.SmoothPlastic
	projectile.CanCollide = false
	projectile.Anchored = true
	projectile.Position = hrp.Position + (camera.CFrame.LookVector * 2)
	projectile.Parent = Workspace

	local attachment0 = Instance.new("Attachment", projectile)
	attachment0.Position = Vector3.new(0, 0.5, 0)
	local attachment1 = Instance.new("Attachment", projectile)
	attachment1.Position = Vector3.new(0, -0.5, 0)

	local trail = Instance.new("Trail")
	trail.Attachment0 = attachment0
	trail.Attachment1 = attachment1
	trail.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	trail.LightEmission = 0.8
	trail.Lifetime = 0.25
	trail.WidthScale = NumberSequence.new({
		PathPoint.new(0, 1),
		PathPoint.new(1, 0)
	})
	trail.Parent = projectile

	local startPos = projectile.Position
	local targetPos = targetHRP.Position
	local distance = (targetPos - startPos).Magnitude
	local duration = distance / WEB_PROJECTILE_SPEED

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Linear)
	local tween = TweenService:Create(projectile, tweenInfo, {Position = targetPos})
	tween:Play()

	tween.Completed:Connect(function()
		projectile:Destroy()

		if not targetHRP or not targetHumanoid or targetHumanoid.Health <= 0 then return end

		targetHumanoid:TakeDamage(10)

		local wasAnchored = targetHRP.Anchored
		targetHRP.Anchored = true

		local webCluster = Instance.new("Folder")
		webCluster.Name = "WebBindings"
		webCluster.Parent = targetNPC

		for i = 1, 5 do
			local webNode = Instance.new("Part")
			webNode.Size = Vector3.new(math.random(2, 4), math.random(2, 4), math.random(2, 4))
			webNode.Color = Color3.fromRGB(250, 250, 250)
			webNode.Material = Enum.Material.SmoothPlastic
			webNode.Transparency = 0.15
			webNode.CanCollide = false
			webNode.Anchored = true
			webNode.CFrame = targetHRP.CFrame * CFrame.new(math.random(-1, 1), math.random(-2, 2), math.random(-1, 1)) * CFrame.Angles(math.rad(math.random(0, 360)), math.rad(math.random(0, 360)), math.rad(math.random(0, 360)))
			webNode.Parent = webCluster
		end

		task.delay(2, function()
			if targetHRP then targetHRP.Anchored = wasAnchored end

			for _, node in ipairs(webCluster:GetChildren()) do
				local dissolveTween = TweenService:Create(node, TweenInfo.new(0.5), {Transparency = 1, Size = Vector3.zero})
				dissolveTween:Play()
			end
			task.delay(0.5, function() webCluster:Destroy() end)
		end)
	end)
end

--aoe shockwave on zip impact
local function executeAoESlam(impactPosition)

	local wave = Instance.new("Part")
	wave.Shape = Enum.PartType.Cylinder
	wave.Size = Vector3.new(0.5, 1, 1)
	wave.Color = Color3.fromRGB(255, 255, 255)
	wave.Material = Enum.Material.Neon
	wave.Transparency = 0.4
	wave.CanCollide = false
	wave.Anchored = true
	wave.CFrame = CFrame.new(impactPosition) * CFrame.Angles(0, 0, math.rad(90))
	wave.Parent = Workspace

	local waveTween = TweenService:Create(wave, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.5, SLAM_RADIUS * 2, SLAM_RADIUS * 2),
		Transparency = 1
	})
	waveTween:Play()
	waveTween.Completed:Connect(function() wave:Destroy() end)

	for _, obj in ipairs(Workspace:GetChildren()) do
		if obj == player.Character then continue end

		local enemyHumanoid = obj:FindFirstChildOfClass("Humanoid")
		local enemyHRP = obj:FindFirstChild("HumanoidRootPart")

		if enemyHumanoid and enemyHRP and enemyHumanoid.Health > 0 then
			local distance = (impactPosition - enemyHRP.Position).Magnitude
			if distance <= SLAM_RADIUS then
				local severity = 1 - (distance / SLAM_RADIUS)
				enemyHumanoid:TakeDamage(SLAM_DAMAGE * severity)

				local dir = (enemyHRP.Position - impactPosition).Unit
				if dir.Y < 0.2 then dir = Vector3.new(dir.X, 0.4, dir.Z).Unit end

				enemyHRP:ApplyImpulse(dir * enemyHRP.AssemblyMass * (SLAM_IMPULSE_FORCE * severity))
			end
		end
	end
end

--web zip, to a point or a combat target
local function startWebZip()
	local currentTime = os.clock()
	if currentTime - lastZipTime < ZIP_COOLDOWN then return end

	local character = player.Character
	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}

	local isCombatZip = false
	local targetPos = nil

	if currentTarget and currentTarget:FindFirstChild("HumanoidRootPart") then
		targetPos = currentTarget.HumanoidRootPart.Position
		isCombatZip = true
	else

		local origin = camera.CFrame.Position
		local dir = camera.CFrame.LookVector * MAX_ZIP_DISTANCE
		local result = Workspace:Raycast(origin, dir, rayParams)

		if not result or not result.Instance.Anchored then return end
		targetPos = result.Position
	end

	lastZipTime = currentTime
	resetStates(true)
	clearFloatForce()
	isZipping = true

	createActionHighlight(character)

	local hrp = character.HumanoidRootPart
	local humanoid = character:FindFirstChildOfClass("Humanoid")

	humanoid.PlatformStand = true
	humanoid.AutoRotate = false
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
	rightWeb.Width0, rightWeb.Width1 = 5, 5
	rightWeb.Color = ColorSequence.new(Color3.new(1,1,1))
	rightWeb.LightEmission = 0.5
	rightWeb.Texture = "rbxassetid://9632171388"
	rightWeb.Parent = hrp
	table.insert(activeWebs, rightWeb)

	local leftWeb = Instance.new("Beam")
	leftWeb.Attachment0 = leftAtt
	leftWeb.Attachment1 = att1
	leftWeb.FaceCamera = true
	leftWeb.Width0, leftWeb.Width1 = 5, 5
	leftWeb.Color = ColorSequence.new(Color3.new(1,1,1))
	leftWeb.LightEmission = 0.5
	leftWeb.Texture = "rbxassetid://9632171388"
	leftWeb.Parent = hrp
	table.insert(activeWebs, leftWeb)

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

		if not isCombatZip then
			local velocity = hrp.AssemblyLinearVelocity
			if velocity.Magnitude > 12 then
				local collisionRay = Workspace:Raycast(hrp.Position, velocity.Unit * 5, rayParams)
				if collisionRay and collisionRay.Instance.Anchored and collisionRay.Normal.Y < 0.8 then
					attachToSurface(collisionRay.Normal)
					return
				end
			end
		end

		local targetDistThreshold = isCombatZip and 10 or 5
		if toTarget.Magnitude < targetDistThreshold then
			if isCombatZip then
				executeAoESlam(targetPos)
			end
			stopSwing()
		end
	end)

	task.delay(0.6, function()
		if isZipping then stopSwing() end
	end)
end

local function startSwing()
	if isClimbing or isCeilingCrawling or isZipping then return end

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

		createActionHighlight(character)

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
		swingWeb.Width0, swingWeb.Width1 = 5, 5
		swingWeb.Color = ColorSequence.new(Color3.new(1,1,1))
		swingWeb.LightEmission = 0.5
		swingWeb.Texture = "rbxassetid://9632171388"
		swingWeb.Parent = hrp
		table.insert(activeWebs, swingWeb)

		humanoid.PlatformStand = true
		humanoid.AutoRotate = false
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
		else
			if loadedAnims.SwingLoop then loadedAnims.SwingLoop:Play(0.2) end
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
					attachToSurface(collisionRay.Normal)
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

tool.Equipped:Connect(function()
	isEquipped = true
	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not hrp or not humanoid then return end

	loadAnims(humanoid)

	stateConnection = humanoid.StateChanged:Connect(function(oldState, newState)
		if not isEquipped then return end
		if newState == Enum.HumanoidStateType.Landed then
			if not (isSwinging or isClimbing or isCeilingCrawling or isZipping or isGliding) then
				if loadedAnims.Landing then loadedAnims.Landing:Play(0.05) end
			end
		end
	end)

	ContextActionService:BindAction("PreventNativeShiftLock", function()
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)

	UserInputService.MouseIconEnabled = false

	local playerGui = player:FindFirstChild("PlayerGui")
	if playerGui then
		crosshairGui = Instance.new("ScreenGui")
		crosshairGui.Name = "WebCrosshair"
		crosshairGui.ResetOnSpawn = false
		crosshairGui.IgnoreGuiInset = true
		crosshairGui.DisplayOrder = 100

		local crosshairImage = Instance.new("ImageLabel")
		crosshairImage.Size = UDim2.new(0, 30, 0, 30)
		crosshairImage.Position = UDim2.new(0.5, 0, 0.5, 0)
		crosshairImage.AnchorPoint = Vector2.new(0.5, 0.5)
		crosshairImage.BackgroundTransparency = 1
		crosshairImage.Image = CROSSHAIR_IMAGE_ID
		crosshairImage.Parent = crosshairGui
		crosshairGui.Parent = playerGui
	end

	shiftLockGyro = Instance.new("AlignOrientation")
	shiftLockGyro.Mode = Enum.OrientationAlignmentMode.OneAttachment
	shiftLockGyro.Attachment0 = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)
	shiftLockGyro.MaxTorque = 100000
	shiftLockGyro.Responsiveness = 200
	shiftLockGyro.Parent = hrp

	shiftLockConnection = RunService.RenderStepped:Connect(function()
		if not isEquipped or not humanoid or not hrp then return end

		--own shift lock
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter

		local doingAction = (isSwinging or isClimbing or isCeilingCrawling or isZipping or isGliding)

		--soft lock, enemy closest to crosshair on screen
		local closestTarget = nil
		local closestScreenDist = TARGET_SCREEN_RADIUS
		local screenCenter = Vector2.new(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)

		for _, obj in ipairs(Workspace:GetChildren()) do
			if obj == character then continue end

			local enemyHumanoid = obj:FindFirstChildOfClass("Humanoid")
			local enemyHRP = obj:FindFirstChild("HumanoidRootPart")

			if enemyHumanoid and enemyHRP and enemyHumanoid.Health > 0 then
				local dist3D = (camera.CFrame.Position - enemyHRP.Position).Magnitude
				if dist3D <= MAX_TARGET_DISTANCE then
					local screenPos, onScreen = camera:WorldToViewportPoint(enemyHRP.Position)
					if onScreen then
						local dist2D = (Vector2.new(screenPos.X, screenPos.Y) - screenCenter).Magnitude
						if dist2D < closestScreenDist then
							closestScreenDist = dist2D
							closestTarget = obj
						end
					end
				end
			end
		end

		if currentTarget ~= closestTarget then
			currentTarget = closestTarget
			if targetHighlight then
				targetHighlight:Destroy()
				targetHighlight = nil
			end

			if currentTarget then
				targetHighlight = Instance.new("Highlight")
				targetHighlight.Name = "CombatTargetHighlight"
				targetHighlight.FillTransparency = 1
				targetHighlight.OutlineColor = Color3.fromRGB(255, 30, 30)
				targetHighlight.OutlineTransparency = 0
				targetHighlight.Parent = currentTarget
			end
		end

		local isFalling = humanoid:GetState() == Enum.HumanoidStateType.Freefall
		if isFalling and not doingAction and not currentFloatForce then
			if not normalFallForce then
				normalFallForce = Instance.new("VectorForce")
				local att = hrp:FindFirstChild("RootRigAttachment") or Instance.new("Attachment", hrp)
				normalFallForce.Attachment0 = att
				normalFallForce.RelativeTo = Enum.ActuatorRelativeTo.World
				normalFallForce.Force = Vector3.yAxis * (hrp.AssemblyMass * Workspace.Gravity * NORMAL_FALL_STRENGTH)
				normalFallForce.Parent = hrp
			end
		else
			if normalFallForce then
				normalFallForce:Destroy()
				normalFallForce = nil
			end
		end

		local targetOffset = doingAction and Vector3.zero or Vector3.new(1.5, 0, 0)
		humanoid.CameraOffset = humanoid.CameraOffset:Lerp(targetOffset, 0.15)

		if not doingAction then
			humanoid.AutoRotate = false
			if shiftLockGyro then
				shiftLockGyro.Enabled = true
				local camLook = camera.CFrame.LookVector
				local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
				if flatLook.Magnitude > 0.01 then
					shiftLockGyro.CFrame = CFrame.lookAt(Vector3.zero, flatLook.Unit)
				end
			end
		else
			if shiftLockGyro then
				shiftLockGyro.Enabled = false
			end
		end
	end)
end)

tool.Unequipped:Connect(function()
	isEquipped = false
	resetStates(false)
	clearFloatForce()

	if targetHighlight then targetHighlight:Destroy() targetHighlight = nil end
	currentTarget = nil

	if normalFallForce then normalFallForce:Destroy() normalFallForce = nil end

	ContextActionService:UnbindAction("PreventNativeShiftLock")
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true

	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.CameraOffset = Vector3.zero
		humanoid.AutoRotate = true
	end

	if stateConnection then stateConnection:Disconnect() stateConnection = nil end
	if crosshairGui then crosshairGui:Destroy() crosshairGui = nil end
	if shiftLockGyro then shiftLockGyro:Destroy() shiftLockGyro = nil end
	if shiftLockConnection then shiftLockConnection:Disconnect() shiftLockConnection = nil end
end)

tool.Activated:Connect(function()
	if currentTarget then
		shootWebProjectile(currentTarget)
	elseif not isSwinging and not isClimbing and not isCeilingCrawling and not isZipping then
		startSwing()
	end
end)

tool.Deactivated:Connect(stopSwing)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not isEquipped then return end
	local currentTime = os.clock()

	if input.KeyCode == Enum.KeyCode.Space then
		local humanoid = player.Character and player.Character:FindFirstChild("Humanoid")
		if humanoid and humanoid.FloorMaterial == Enum.Material.Air then
			if currentTime - lastWallJumpTime < 0.25 then return end

			if isGliding then
				stopGlide()
			elseif not isSwinging and not isZipping and not isClimbing and not isCeilingCrawling then
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
			if humanoid.FloorMaterial ~= Enum.Material.Air or isClimbing or isCeilingCrawling then
				showZipError()
			elseif not isZipping then
				startWebZip()
			end
		end
	end
end)

UserInputService.JumpRequest:Connect(function()
	if isClimbing or isCeilingCrawling then
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
