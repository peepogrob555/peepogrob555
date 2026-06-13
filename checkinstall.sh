local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
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

local function blackify(obj)
    if obj:IsA("BasePart") then
        obj.Material = Enum.Material.SmoothPlastic
        obj.Color = Color3.new(0, 0, 0)
        obj.Reflectance = 0
        obj.CastShadow = false
    elseif obj:IsA("MeshPart") then
        obj.TextureID = ""
        obj.Color = Color3.new(0, 0, 0)
        obj.CastShadow = false
    end
    killEffects(obj)
end

local function applyBlackout(enable)
    if enable then
        Lighting.GlobalShadows = false
        Lighting.Brightness = 0
        Lighting.ClockTime = 0
        Lighting.OutdoorAmbient = Color3.new(0, 0, 0)
        Lighting.Ambient = Color3.new(0, 0, 0)
        Lighting.FogColor = Color3.new(0, 0, 0)
        Lighting.FogStart = 0
        Lighting.FogEnd = 50
        for _, fx in ipairs(Lighting:GetChildren()) do
            if fx:IsA("PostEffect") or fx:IsA("Sky") then
                fx.Enabled = false
            end
        end
        for _, obj in ipairs(workspace:GetDescendants()) do
            blackify(obj)
        end
        pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        end)
    else
        Lighting.GlobalShadows = true
        Lighting.Brightness = 2
        Lighting.OutdoorAmbient = Color3.fromRGB(128,128,128)
        Lighting.Ambient = Color3.fromRGB(128,128,128)
        Lighting.FogStart = 0
        Lighting.FogEnd = 100000
        for _, fx in ipairs(Lighting:GetChildren()) do
            if fx:IsA("PostEffect") or fx:IsA("Sky") then
                fx.Enabled = true
            end
        end
        pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Automatic
        end)
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

local function reduceRenderDistance(enable)
    if enable then
        Lighting.FogStart = 10
        Lighting.FogEnd = 50
        Lighting.FogColor = Color3.new(0, 0, 0)
        pcall(function()
            workspace.CurrentCamera.FieldOfView = 50
        end)
    else
        Lighting.FogStart = 0
        Lighting.FogEnd = 100000
        pcall(function()
            workspace.CurrentCamera.FieldOfView = 70
        end)
    end
end

local function lockMovement(enable)
    local char = player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end

    if enable then
        hum.WalkSpeed = 0
        hum.JumpPower = 0
        hum.AutoRotate = false
    else
        hum.WalkSpeed = 16
        hum.JumpPower = 50
        hum.AutoRotate = true
    end
end

local states = {
    Blackout = false,
    HidePlayers = false,
    LowRender = false,
    FPSCap = false,
    AutoCleanup = false,
    LockMovement = false
}

local cleanupThread = nil
local function toggleAutoCleanup(enable)
    if enable and not cleanupThread then
        cleanupThread = task.spawn(function()
            while states.AutoCleanup do
                task.wait(3600)
                for _, obj in ipairs(workspace:GetDescendants()) do
                    if states.Blackout then
                        blackify(obj)
                    else
                        killEffects(obj)
                    end
                end
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

local mainFrameWidth = 220
local mainFrameHeight = 360

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, mainFrameWidth, 0, mainFrameHeight)
frame.Position = UDim2.new(0, 20, 0, 100)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.Active = true
frame.Draggable = true
frame.ClipsDescendants = true
frame.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -40, 0, 30)
title.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
title.TextColor3 = Color3.new(1,1,1)
title.Text = "Anti-Lag Menu"
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.Parent = frame

local titleCorner = Instance.new("UICorner")
titleCorner.CornerRadius = UDim.new(0, 8)
titleCorner.Parent = title

local fpsLabel = Instance.new("TextLabel")
fpsLabel.Size = UDim2.new(1, -20, 0, 25)
fpsLabel.Position = UDim2.new(0, 10, 0, 320)
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
    btn.AutoButtonColor = false
    btn.Parent = frame

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 6)
    btnCorner.Parent = btn

    local enabled = false

    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(70,70,70)}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(50,50,50)}):Play()
    end)

    btn.MouseButton1Click:Connect(function()
        enabled = not enabled
        btn.Text = (enabled and "ON " or "OFF ") .. name

        local targetColor = enabled and Color3.fromRGB(40, 110, 60) or Color3.fromRGB(50, 50, 50)
        TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = targetColor}):Play()

        local pop = TweenService:Create(btn, TweenInfo.new(0.08), {Size = UDim2.new(1, -24, 0, 33)})
        pop:Play()
        pop.Completed:Connect(function()
            TweenService:Create(btn, TweenInfo.new(0.08), {Size = UDim2.new(1, -20, 0, 35)}):Play()
        end)

        callback(enabled)
    end)
    return btn
end

createToggle("Blackout ทั้งแมพ", 40, function(v)
    states.Blackout = v
    applyBlackout(v)
end)

createToggle("ซ่อนผู้เล่นอื่น", 80, function(v)
    states.HidePlayers = v
    hideOtherPlayers(v)
end)

createToggle("ลดระยะมองเห็น (Fog)", 120, function(v)
    states.LowRender = v
    reduceRenderDistance(v)
end)

createToggle("FPS Cap 8", 160, function(v)
    states.FPSCap = v
    if setfpscap then
        setfpscap(v and 8 or 0)
    end
end)

createToggle("ล็อคห้ามเดิน", 200, function(v)
    states.LockMovement = v
    lockMovement(v)
end)

createToggle("Auto Refresh ทุก 1 ชม.", 280, function(v)
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
refreshBtn.AutoButtonColor = false
refreshBtn.Text = "Refresh ตอนนี้"
refreshBtn.Parent = frame

local refreshCorner = Instance.new("UICorner")
refreshCorner.CornerRadius = UDim.new(0, 6)
refreshCorner.Parent = refreshBtn

refreshBtn.MouseEnter:Connect(function()
    TweenService:Create(refreshBtn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(90,90,90)}):Play()
end)
refreshBtn.MouseLeave:Connect(function()
    TweenService:Create(refreshBtn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(70,70,70)}):Play()
end)

refreshBtn.MouseButton1Click:Connect(function()
    local spin = TweenService:Create(refreshBtn, TweenInfo.new(0.3), {Rotation = 360})
    spin:Play()
    spin.Completed:Connect(function() refreshBtn.Rotation = 0 end)

    for _, obj in ipairs(workspace:GetDescendants()) do
        if states.Blackout then
            blackify(obj)
        else
            killEffects(obj)
        end
    end
    if states.HidePlayers then hideOtherPlayers(true) end
    collectgarbage("collect")
end)

local toggleVisBtn = Instance.new("TextButton")
toggleVisBtn.Size = UDim2.new(0, 36, 0, 30)
toggleVisBtn.Position = UDim2.new(0, mainFrameWidth + 30, 0, 100)
toggleVisBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
toggleVisBtn.TextColor3 = Color3.new(1,1,1)
toggleVisBtn.Font = Enum.Font.GothamBold
toggleVisBtn.TextSize = 18
toggleVisBtn.AutoButtonColor = false
toggleVisBtn.Text = "‹"
toggleVisBtn.Parent = gui

local toggleCorner = Instance.new("UICorner")
toggleCorner.CornerRadius = UDim.new(0, 6)
toggleCorner.Parent = toggleVisBtn

local menuOpen = true

local function setMenuOpen(open)
    menuOpen = open
    if open then
        frame.Visible = true
        frame.Size = UDim2.new(0, mainFrameWidth, 0, 0)
        frame.Position = UDim2.new(0, 20, 0, 100)
        TweenService:Create(frame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Size = UDim2.new(0, mainFrameWidth, 0, mainFrameHeight)
        }):Play()
        TweenService:Create(toggleVisBtn, TweenInfo.new(0.25), {
            Position = UDim2.new(0, mainFrameWidth + 30, 0, 100)
        }):Play()
        toggleVisBtn.Text = "‹"
    else
        local closeTween = TweenService:Create(frame, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Size = UDim2.new(0, mainFrameWidth, 0, 0)
        })
        closeTween:Play()
        closeTween.Completed:Connect(function()
            if not menuOpen then
                frame.Visible = false
            end
        end)
        TweenService:Create(toggleVisBtn, TweenInfo.new(0.25), {
            Position = UDim2.new(0, 20, 0, 100)
        }):Play()
        toggleVisBtn.Text = "›"
    end
end

toggleVisBtn.MouseEnter:Connect(function()
    TweenService:Create(toggleVisBtn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(60,60,60)}):Play()
end)
toggleVisBtn.MouseLeave:Connect(function()
    TweenService:Create(toggleVisBtn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(40,40,40)}):Play()
end)

toggleVisBtn.MouseButton1Click:Connect(function()
    setMenuOpen(not menuOpen)
end)

workspace.DescendantAdded:Connect(function(obj)
    if states.Blackout then
        blackify(obj)
    end
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

player.CharacterAdded:Connect(function(char)
    if states.LockMovement then
        task.wait(1)
        lockMovement(true)
    end
end)

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
