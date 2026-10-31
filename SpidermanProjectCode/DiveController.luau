--StarterPlayer.StarterCharacterScripts

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")
local hrp = character:WaitForChild("HumanoidRootPart")

local HEIGHT_THRESHOLD = 45

local DIVE_ANIM_W_ID = "rbxassetid://0000000000"
local DIVE_ANIM_S_ID = "rbxassetid://0000000000"

local animW = Instance.new("Animation")
animW.AnimationId = DIVE_ANIM_W_ID
local trackW = humanoid:LoadAnimation(animW)

local animS = Instance.new("Animation")
animS.AnimationId = DIVE_ANIM_S_ID
local trackS = humanoid:LoadAnimation(animS)

local isDiving = false
local wasOnSurface = true

RunService.Heartbeat:Connect(function()
	local onGround = humanoid.FloorMaterial ~= Enum.Material.Air

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = {character}
	--tracks if we touched a surface recently
	local wallCheck = workspace:Spherecast(hrp.Position, 3, Vector3.new(0,0.1,0), rayParams)

	if onGround or wallCheck then
		wasOnSurface = true
	end
end)

humanoid.StateChanged:Connect(function(oldState, newState)

	if newState == Enum.HumanoidStateType.Freefall then

		if humanoid.PlatformStand then return end

		--cant dive twice without landing first
		if not wasOnSurface then return end

		local rayParams = RaycastParams.new()
		rayParams.FilterDescendantsInstances = {character}
		--only dive if nothing is under us for the height threshold
		local rayResult = workspace:Raycast(hrp.Position, Vector3.new(0, -HEIGHT_THRESHOLD, 0), rayParams)

		if not rayResult then
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then
				isDiving = true
				trackW:Play(0.3)
				wasOnSurface = false
			elseif UserInputService:IsKeyDown(Enum.KeyCode.S) then
				isDiving = true
				trackS:Play(0.3)
				wasOnSurface = false
			end
		end

	elseif newState == Enum.HumanoidStateType.Landed
		or newState == Enum.HumanoidStateType.Running
		or newState == Enum.HumanoidStateType.PlatformStanding then

		if isDiving then
			isDiving = false
			trackW:Stop(0.5)
			trackS:Stop(0.5)
		end

		if newState ~= Enum.HumanoidStateType.Freefall then
			wasOnSurface = true
		end
	end
end)
