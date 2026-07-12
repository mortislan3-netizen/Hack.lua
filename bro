local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid")
local rootPart = character:WaitForChild("HumanoidRootPart")

local CONFIG = {
    DribbleRadius = 15,
    DribbleCooldown = 0.1,
    ShootPowerMin = 80,
    ShootPowerMax = 100,
    ShootDistanceMin = 30,
    ShootDistanceMax = 80,
    TopCornerBias = 0.9,
    TackleRadius = 12,
    TackleCooldown = 0.3,
    SpeedMultiplier = 50,
    TeleportToBallEnabled = true,
    TeleportMode = "instant",
    TeleportRange = 200,
    TeleportCooldown = 0.2,
    TeleportOffset = Vector3.new(0, 3, 0),
    TweenSpeed = 0.15,
    GoalLeftPosition = nil,
    GoalRightPosition = nil,
    TeamCheckEnabled = true,
}

local state = {
    lastDribbleTime = 0,
    lastTackleTime = 0,
    lastTeleportTime = 0,
    isDribbling = false,
    isShooting = false,
    isTackling = false,
    isTeleporting = false,
    nearestEnemy = nil,
    nearestBall = nil,
    currentGoalTarget = nil,
    teleportConnection = nil,
}

local function setupConsoleCommand()
    player.Chatted:Connect(function(message)
        local speedCmd = message:match("^/speed%s+(%d+%.?%d*)$")
        if speedCmd then
            local newSpeed = tonumber(speedCmd)
            if newSpeed and newSpeed > 0 then
                CONFIG.SpeedMultiplier = newSpeed
                if humanoid then humanoid.WalkSpeed = newSpeed end
            end
        end
        local teleCmd = message:match("^/teleport%s+(%w+)$")
        if teleCmd then
            if teleCmd == "on" then CONFIG.TeleportToBallEnabled = true
            elseif teleCmd == "off" then CONFIG.TeleportToBallEnabled = false
            elseif teleCmd == "instant" then CONFIG.TeleportMode = "instant"
            elseif teleCmd == "tween" then CONFIG.TeleportMode = "tween"
            elseif teleCmd == "both" then CONFIG.TeleportMode = "both" end
        end
        local rangeCmd = message:match("^/telerange%s+(%d+%.?%d*)$")
        if rangeCmd then
            local newRange = tonumber(rangeCmd)
            if newRange and newRange > 0 then CONFIG.TeleportRange = newRange end
        end
    end)
end

local function setupKeybinds()
    UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode == Enum.KeyCode.Equals then
            CONFIG.SpeedMultiplier = CONFIG.SpeedMultiplier + 10
            if humanoid then humanoid.WalkSpeed = CONFIG.SpeedMultiplier end
        elseif input.KeyCode == Enum.KeyCode.Minus then
            CONFIG.SpeedMultiplier = math.max(10, CONFIG.SpeedMultiplier - 10)
            if humanoid then humanoid.WalkSpeed = CONFIG.SpeedMultiplier end
        elseif input.KeyCode == Enum.KeyCode.R then
            CONFIG.SpeedMultiplier = 50
            if humanoid then humanoid.WalkSpeed = CONFIG.SpeedMultiplier end
        elseif input.KeyCode == Enum.KeyCode.T then
            CONFIG.TeleportToBallEnabled = not CONFIG.TeleportToBallEnabled
        elseif input.KeyCode == Enum.KeyCode.Y then
            local modes = {"instant", "tween", "both"}
            local currentIndex = table.find(modes, CONFIG.TeleportMode) or 1
            CONFIG.TeleportMode = modes[(currentIndex % #modes) + 1]
        end
    end)
end

local function findBall()
    local ballFolder = Workspace:FindFirstChild("Balls") or Workspace:FindFirstChild("Ball")
    if ballFolder then
        for _, obj in ipairs(ballFolder:GetChildren()) do
            if obj:IsA("BasePart") and obj.Name:lower():find("ball") then return obj end
        end
    end
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") and (obj.Name:lower():find("ball") or obj:FindFirstChild("IsBall")) then return obj end
    end
    return nil
end

local function findGoals()
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name:lower():find("goal") then
            local goalPos = obj.Position
            if goalPos.X < 0 then CONFIG.GoalLeftPosition = goalPos + Vector3.new(0, obj.Size.Y * 0.8, 0)
            else CONFIG.GoalRightPosition = goalPos + Vector3.new(0, obj.Size.Y * 0.8, 0) end
        end
    end
    if not CONFIG.GoalLeftPosition or not CONFIG.GoalRightPosition then
        local goalModels = {}
        for _, model in ipairs(Workspace:GetChildren()) do
            if model:IsA("Model") and model.Name:lower():find("goal") then table.insert(goalModels, model) end
        end
        if #goalModels >= 2 then
            local pos1, pos2 = goalModels[1]:GetPivot().Position, goalModels[2]:GetPivot().Position
            if pos1.X < pos2.X then CONFIG.GoalLeftPosition, CONFIG.GoalRightPosition = pos1 + Vector3.new(0, 6, 0), pos2 + Vector3.new(0, 6, 0)
            else CONFIG.GoalLeftPosition, CONFIG.GoalRightPosition = pos2 + Vector3.new(0, 6, 0), pos1 + Vector3.new(0, 6, 0) end
        end
    end
end

local function isEnemy(targetPlayer)
    if not CONFIG.TeamCheckEnabled then return true end
    if targetPlayer == player then return false end
    if player.Team and targetPlayer.Team then return player.Team ~= targetPlayer.Team end
    if player.TeamColor and targetPlayer.TeamColor then return player.TeamColor ~= targetPlayer.TeamColor end
    return true
end

local function findNearestEnemy()
    local nearest, nearestDist = nil, CONFIG.DribbleRadius
    for _, targetPlayer in ipairs(Players:GetPlayers()) do
        if targetPlayer ~= player and isEnemy(targetPlayer) then
            local targetChar = targetPlayer.Character
            if targetChar then
                local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
                if targetRoot then
                    local dist = (rootPart.Position - targetRoot.Position).Magnitude
                    if dist < nearestDist then nearestDist, nearest = dist, targetChar end
                end
            end
        end
    end
    return nearest
end

local function performDribble(enemyChar)
    if not enemyChar then return end
    local enemyRoot = enemyChar:FindFirstChild("HumanoidRootPart")
    if not enemyRoot then return end
    state.lastDribbleTime, state.isDribbling = tick(), true
    local enemyPos, myPos = enemyRoot.Position, rootPart.Position
    local directionToEnemy = (enemyPos - myPos).Unit
    local perpendicularRight = Vector3.new(-directionToEnemy.Z, 0, directionToEnemy.X)
    local perpendicularLeft = Vector3.new(directionToEnemy.Z, 0, -directionToEnemy.X)
    local enemyVelocity = enemyRoot.Velocity
    local enemyForward = enemyVelocity.Magnitude > 1 and enemyVelocity.Unit or (enemyChar:FindFirstChild("Humanoid") and enemyChar.Humanoid.MoveDirection or Vector3.zero)
    local dodgeDirection = math.random() > 0.5 and perpendicularRight or perpendicularLeft
    if enemyForward.Magnitude > 0.1 then
        dodgeDirection = perpendicularRight:Dot(enemyForward) > 0 and perpendicularLeft or perpendicularRight
    end
    local dodgeTarget = myPos + dodgeDirection * (8 + math.random() * 4)
    if humanoid then
        local originalSpeed = humanoid.WalkSpeed
        humanoid.WalkSpeed = 35
        humanoid:MoveTo(dodgeTarget)
        task.wait(CONFIG.DribbleCooldown)
        humanoid.WalkSpeed = originalSpeed
    end
    state.isDribbling = false
end

local function calculateTopCornerTarget(goalBasePos, isLeftGoal)
    return goalBasePos + Vector3.new(isLeftGoal and -2 or 2, 8, 0) + Vector3.new(math.random() * 1.5 - 0.75, math.random() * 1.5 - 0.75, math.random() * 2 - 1)
end

local function performAutoShoot(ball)
    if not ball or not rootPart then return end
    state.isShooting = true
    local myPos, ballPos = rootPart.Position, ball.Position
    local targetGoal, isLeftGoal = nil, false
    if CONFIG.GoalLeftPosition and CONFIG.GoalRightPosition then
        if (ballPos - CONFIG.GoalLeftPosition).Magnitude < (ballPos - CONFIG.GoalRightPosition).Magnitude then
            targetGoal, isLeftGoal = CONFIG.GoalRightPosition, false
        else targetGoal, isLeftGoal = CONFIG.GoalLeftPosition, true end
    else targetGoal = Vector3.new(myPos.X > 0 and -50 or 50, 8, 0) end
    local distanceToGoal = (ballPos - targetGoal).Magnitude
    local shootPower = math.clamp(distanceToGoal / CONFIG.ShootDistanceMax * CONFIG.ShootPowerMax, CONFIG.ShootPowerMin, CONFIG.ShootPowerMax)
    local shootDirection = (calculateTopCornerTarget(targetGoal, isLeftGoal) - ballPos).Unit
    if ball:IsA("BasePart") then
        local bodyVelocity = Instance.new("BodyVelocity")
        bodyVelocity.Velocity, bodyVelocity.MaxForce, bodyVelocity.P = shootDirection * shootPower, Vector3.new(1, 1, 1) * 1e6, 1e6
        bodyVelocity.Parent = ball
        task.delay(0.5, function() pcall(function() bodyVelocity:Destroy() end) end)
    end
    state.isShooting = false
end

local function performAutoTackle(ball, enemyChar)
    if not ball or not enemyChar then return end
    if tick() - state.lastTackleTime < CONFIG.TackleCooldown then return end
    state.lastTackleTime, state.isTackling = tick(), true
    local ballPos = ball.Position
    local enemyRoot = enemyChar:FindFirstChild("HumanoidRootPart")
    if not enemyRoot then state.isTackling = false; return end
    local tackleTarget = ballPos + (ballPos - enemyRoot.Position).Unit * 2
    if humanoid then
        local originalSpeed = humanoid.WalkSpeed
        humanoid.WalkSpeed, humanoid:MoveTo(tackleTarget) = 40, humanoid:MoveTo(tackleTarget)
        task.wait(0.1)
        if (rootPart.Position - ballPos).Magnitude < 5 and ball:IsA("BasePart") then
            local weldConstraint = Instance.new("WeldConstraint", ball)
            weldConstraint.Part0, weldConstraint.Part1 = ball, rootPart
            task.delay(0.2, function() pcall(function() weldConstraint:Destroy() end) end)
        end
        humanoid.WalkSpeed = originalSpeed
    end
    state.isTackling = false
end

local function teleportToBall(ball)
    if not ball or not rootPart then return end
    if not CONFIG.TeleportToBallEnabled then return end
    if tick() - state.lastTeleportTime < CONFIG.TeleportCooldown then return end
    local ballPos, myPos = ball.Position, rootPart.Position
    local distance = (myPos - ballPos).Magnitude
    if distance > CONFIG.TeleportRange or distance < 5 then return end
    state.lastTeleportTime, state.isTeleporting = tick(), true
    local targetPosition = ballPos + CONFIG.TeleportOffset
    if CONFIG.TeleportMode == "instant" then
        rootPart.CFrame = CFrame.new(targetPosition)
        state.isTeleporting = false
    elseif CONFIG.TeleportMode == "tween" then
        local tween = TweenService:Create(rootPart, TweenInfo.new(CONFIG.TweenSpeed, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {CFrame = CFrame.new(targetPosition)})
        if state.teleportConnection then state.teleportConnection:Disconnect() end
        state.teleportConnection = tween.Completed:Connect(function() state.isTeleporting = false end)
        tween:Play()
    elseif CONFIG.TeleportMode == "both" then
        rootPart.CFrame = CFrame.new(myPos + (ballPos - myPos) * 0.7 + Vector3.new(0, 10, 0))
        task.wait(0.05)
        local tween = TweenService:Create(rootPart, TweenInfo.new(CONFIG.TweenSpeed * 0.8, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {CFrame = CFrame.new(ball.Position + CONFIG.TeleportOffset)})
        if state.teleportConnection then state.teleportConnection:Disconnect() end
        state.teleportConnection = tween.Completed:Connect(function() state.isTeleporting = false end)
        tween:Play()
    end
end

local function applyCustomSpeed()
    if humanoid then
        humanoid.WalkSpeed = CONFIG.SpeedMultiplier
        humanoid.JumpPower, humanoid.AutoRotate = 100, true
        humanoid:GetPropertyChangedSignal("WalkSpeed"):Connect(function()
            if humanoid.WalkSpeed ~= CONFIG.SpeedMultiplier then humanoid.WalkSpeed = CONFIG.SpeedMultiplier end
        end)
    end
end

local function mainLoop()
    applyCustomSpeed()
    setupConsoleCommand()
    setupKeybinds()
    findGoals()
    RunService.Heartbeat:Connect(function()
        if not player.Character then return end
        character = player.Character
        humanoid, rootPart = character:FindFirstChild("Humanoid"), character:FindFirstChild("HumanoidRootPart")
        if not humanoid or not rootPart then return end
        local ball = findBall()
        if not ball then return end
        state.nearestBall = ball
        local ballPos, myPos = ball.Position, rootPart.Position
        local distToBall = (myPos - ballPos).Magnitude
        state.nearestEnemy = findNearestEnemy()
        if not state.isTeleporting and distToBall > 5 then teleportToBall(ball) end
        if state.nearestEnemy and distToBall < CONFIG.DribbleRadius and not state.isTeleporting then
            local enemyRoot = state.nearestEnemy:FindFirstChild("HumanoidRootPart")
            if enemyRoot and (myPos - enemyRoot.Position).Magnitude < 10 and tick() - state.lastDribbleTime > CONFIG.DribbleCooldown then
                performDribble(state.nearestEnemy)
            end
        end
        if state.nearestEnemy and distToBall < CONFIG.TackleRadius and not state.isTeleporting then
            local enemyRoot = state.nearestEnemy:FindFirstChild("HumanoidRootPart")
            if enemyRoot and (enemyRoot.Position - ballPos).Magnitude < distToBall and tick() - state.lastTackleTime > CONFIG.TackleCooldown then
                performAutoTackle(ball, state.nearestEnemy)
            end
        end
        if distToBall < 8 and not state.isShooting and not state.isTeleporting then
            local distToGoal = math.huge
            if CONFIG.GoalLeftPosition then distToGoal = math.min(distToGoal, (ballPos - CONFIG.GoalLeftPosition).Magnitude) end
            if CONFIG.GoalRightPosition then distToGoal = math.min(distToGoal, (ballPos - CONFIG.GoalRightPosition).Magnitude) end
            if distToGoal >= CONFIG.ShootDistanceMin and distToGoal <= CONFIG.ShootDistanceMax then
                performAutoShoot(ball)
            end
        end
    end)
end

player.CharacterAdded:Connect(function(newCharacter)
    character = newCharacter
    humanoid, rootPart = character:WaitForChild("Humanoid"), character:WaitForChild("HumanoidRootPart")
    mainLoop()
end)

mainLoop()
