local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local player = Players.LocalPlayer

local function killEffects(obj)
    if obj:IsA("ParticleEmitter") or obj:IsA("Trail") or obj:IsA("Beam")
       or obj:IsA("Smoke") or obj:IsA("Fire") or obj:IsA("Sparkles") then
        obj.Enabled = false
    elseif obj:IsA("Decal") or obj:IsA("Texture") then
        obj.Transparency = 1
    elseif obj:IsA("Sound") then
        obj.Playing = false
        obj.Volume = 0
    end
end

local function lowGraphics(enable)
    pcall(function()
        settings().Rendering.QualityLevel = enable and Enum.QualityLevel.Level01 or Enum.QualityLevel.Automatic
    end)
    Lighting.GlobalShadows = not enable
    if enable then
        for _, obj in ipairs(workspace:GetDescendants()) do killEffects(obj) end
    end
end

local function hideOtherPlayers(enable)
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= player and p.Character then
            for _, part in ipairs(p.Character:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.Transparency = enable and 1 or 0
                    part.CanCollide = not enable
                elseif part:IsA("Decal") then
                    part.Transparency = enable and 1 or 0
                end
            end
        end
    end
end

local function reduceStreaming(enable)
    pcall(function()
        workspace.StreamingEnabled = true
        workspace.StreamingMinRadius = enable and 40 or 512
        workspace.StreamingTargetRadius = enable and 80 or 1024
    end)
end

local states = {
    LowGraphics = false,
    HidePlayers = false,
    LowStreaming = false,
    FPSCap = false,
    AutoCleanup = false
}

local cleanupThread = nil
local function toggleAutoCleanup(enable)
    if enable and not cleanupThread then
        cleanupThread = task.spawn(function()
            while states.AutoCleanup do
                task.wait(3600)
                for _, obj in ipairs(workspace:GetDescendants()) do killEffects(obj) end
                if states.HidePlayers then hideOtherPlayers(true) end
                collectgarbage("collect")
            end
            cleanupThread = nil
        end)
    end
end

local gui = Instance.new("ScreenGui")
gui.Name = "AntiLagMenu"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 220, 0, 320)
frame.Position = UDim2.new(0, 20, 0, 100)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.Active = true
frame.Draggable = true
frame.Parent = gui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, 0, 0, 30)
title.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
title.TextColor3 = Color3.new(1,1,1)
title.Text = "Anti-Lag Menu"
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.Parent = frame

local fpsLabel = Instance.new("TextLabel")
fpsLabel.Size = UDim2.new(1, -20, 0, 25)
fpsLabel.Position = UDim2.new(0, 10, 0, 280)
fpsLabel.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
fpsLabel.TextColor3 = Color3.new(0, 1, 0)
fpsLabel.Font = Enum.Font.Code
fpsLabel.TextSize = 14
fpsLabel.Text = "FPS: --"
fpsLabel.Parent = frame

local function createToggle(name, posY, callback)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -20, 0, 35)
    btn.Position = UDim2.new(0, 10, 0, posY)
    btn.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    btn.TextColor3 = Color3.new(1,1,1)
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 14
    btn.Text = "OFF " .. name
    btn.Parent = frame

    local enabled = false
    btn.MouseButton1Click:Connect(function()
        enabled = not enabled
        btn.Text = (enabled and "ON " or "OFF ") .. name
        callback(enabled)
    end)
    return btn
end

createToggle("ลดกราฟิกสุด", 40, function(v)
    states.LowGraphics = v
    lowGraphics(v)
end)

createToggle("ซ่อนผู้เล่นอื่น", 80, function(v)
    states.HidePlayers = v
    hideOtherPlayers(v)
end)

createToggle("ลด Render Distance 40 studs", 120, function(v)
    states.LowStreaming = v
    reduceStreaming(v)
end)

createToggle("FPS Cap 30", 160, function(v)
    states.FPSCap = v
    if setfpscap then
        setfpscap(v and 30 or 0)
    end
end)

createToggle("Auto Refresh ทุก 1 ชม.", 200, function(v)
    states.AutoCleanup = v
    toggleAutoCleanup(v)
end)

local refreshBtn = Instance.new("TextButton")
refreshBtn.Size = UDim2.new(1, -20, 0, 35)
refreshBtn.Position = UDim2.new(0, 10, 0, 240)
refreshBtn.BackgroundColor3 = Color3.fromRGB(70, 70, 70)
refreshBtn.TextColor3 = Color3.new(1,1,1)
refreshBtn.Font = Enum.Font.Gotham
refreshBtn.TextSize = 14
refreshBtn.Text = "Refresh ตอนนี้"
refreshBtn.Parent = frame

refreshBtn.MouseButton1Click:Connect(function()
    for _, obj in ipairs(workspace:GetDescendants()) do killEffects(obj) end
    if states.HidePlayers then hideOtherPlayers(true) end
    if states.LowGraphics then lowGraphics(true) end
    collectgarbage("collect")
end)

Players.PlayerAdded:Connect(function(p)
    p.CharacterAdded:Connect(function(char)
        if states.HidePlayers then
            task.wait(0.5)
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.Transparency = 1
                    part.CanCollide = false
                end
            end
        end
    end)
end)

local RunService = game:GetService("RunService")
local frameCount = 0
local lastUpdate = tick()

RunService.RenderStepped:Connect(function()
    frameCount = frameCount + 1
    local now = tick()
    if now - lastUpdate >= 0.25 then
        local fps = math.floor(frameCount / (now - lastUpdate))
        fpsLabel.Text = "FPS: " .. tostring(fps)
        frameCount = 0
        lastUpdate = now
    end
end)
