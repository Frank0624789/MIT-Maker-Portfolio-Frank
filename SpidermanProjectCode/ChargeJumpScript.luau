--StarterPlayer.StarterCharacterScripts

local UserInputService = game:GetService("UserInputService")

local character = script.Parent
local humanoid = character:WaitForChild("Humanoid")
local hrp = character:WaitForChild("HumanoidRootPart")
local rps = game:GetService("ReplicatedStorage")
local ds = game:GetService("Debris")

local CHARGE_ANIM_ID = "rbxassetid://85926860643059"
local JUMP_ANIM_ID = "rbxassetid://131575847612275"

local MAX_CHARGE_TIME = 1.2
local MIN_JUMP_FORCE = 60
local MAX_JUMP_FORCE = 160

local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)

local chargeTrack
if string.match(CHARGE_ANIM_ID, "%d+") and tonumber(string.match(CHARGE_ANIM_ID, "%d+")) > 0 then
	local anim = Instance.new("Animation")
	anim.AnimationId = CHARGE_ANIM_ID
	chargeTrack = animator:LoadAnimation(anim)
	chargeTrack.Priority = Enum.AnimationPriority.Action
end

local jumpTrack
if string.match(JUMP_ANIM_ID, "%d+") and tonumber(string.match(JUMP_ANIM_ID, "%d+")) > 0 then
	local jumpAnim = Instance.new("Animation")
	jumpAnim.AnimationId = JUMP_ANIM_ID
	jumpTrack = animator:LoadAnimation(jumpAnim)
	jumpTrack.Priority = Enum.AnimationPriority.Action
end

local isCharging = false
local chargeStartTime = 0

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.Space then

		if humanoid.FloorMaterial ~= Enum.Material.Air and humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
			--hold space to charge, movement locked while charging
			isCharging = true
			chargeStartTime = os.clock()

			humanoid.WalkSpeed = 0
			humanoid.UseJumpPower = true
			humanoid.JumpPower = 0

			if chargeTrack then chargeTrack:Play(0.15) end
		end
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Space and isCharging then
		isCharging = false
		if chargeTrack then chargeTrack:Stop(0.1) end

		humanoid.WalkSpeed = 16
		humanoid.JumpPower = 50

		if humanoid.FloorMaterial ~= Enum.Material.Air then

			--longer hold = bigger jump
			local holdTime = math.clamp(os.clock() - chargeStartTime, 0, MAX_CHARGE_TIME)
			local chargePercent = holdTime / MAX_CHARGE_TIME
			local jumpForce = MIN_JUMP_FORCE + ((MAX_JUMP_FORCE - MIN_JUMP_FORCE) * chargePercent)

			hrp:ApplyImpulse(Vector3.new(0, hrp.AssemblyMass * jumpForce, 0))

			if jumpTrack then jumpTrack:Play(0.1) end

			local effect = rps.JumpVFX:Clone()
			effect.Parent = character.Parent
			effect.CFrame = hrp.CFrame*CFrame.new(0,-2.75,0)
			effect.Attachment.ParticleEmitter:Emit(2)
			ds:AddItem(effect, 0.41)
		end
	end
end)
