local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local player = Players.LocalPlayer

local running = false
local harvestThread = nil

local function autoHarvest()
    while running do
        for _, prompt in ipairs(CollectionService:GetTagged("HarvestPrompt")) do
            if prompt:IsDescendantOf(workspace) and prompt.Enabled then
                if not prompt:GetAttribute("Collected") then
                    prompt:InputHoldBegin()
                    task.wait(math.max(0.05, prompt.HoldDuration + 0.05))
                    if prompt and prompt:IsDescendantOf(workspace) then
                        prompt:InputHoldEnd()
                    end
                end
            end
        end
        task.wait(0.01)
    end
end

local gui = Instance.new("ScreenGui")
gui.Name = "AutoHarvestGui"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, 180, 0, 60)
frame.Position = UDim2.new(0, 20, 0, 450)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
frame.Active = true
frame.Draggable = true
frame.Parent = gui

local frameCorner = Instance.new("UICorner")
frameCorner.CornerRadius = UDim.new(0, 8)
frameCorner.Parent = frame

local label = Instance.new("TextLabel")
label.Size = UDim2.new(1, 0, 0, 25)
label.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
label.TextColor3 = Color3.new(1, 1, 1)
label.Text = "Auto Harvest"
label.Font = Enum.Font.GothamBold
label.TextSize = 14
label.Parent = frame

local labelCorner = Instance.new("UICorner")
labelCorner.CornerRadius = UDim.new(0, 8)
labelCorner.Parent = label

local btn = Instance.new("TextButton")
btn.Size = UDim2.new(1, -20, 0, 25)
btn.Position = UDim2.new(0, 10, 0, 28)
btn.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
btn.TextColor3 = Color3.new(1, 1, 1)
btn.Font = Enum.Font.Gotham
btn.TextSize = 14
btn.Text = "OFF Auto Harvest"
btn.AutoButtonColor = false
btn.Parent = frame

local btnCorner = Instance.new("UICorner")
btnCorner.CornerRadius = UDim.new(0, 6)
btnCorner.Parent = btn

btn.MouseEnter:Connect(function()
    TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(70, 70, 70)}):Play()
end)
btn.MouseLeave:Connect(function()
    if not running then
        TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = Color3.fromRGB(50, 50, 50)}):Play()
    end
end)

btn.MouseButton1Click:Connect(function()
    running = not running

    local targetColor = running and Color3.fromRGB(40, 110, 60) or Color3.fromRGB(50, 50, 50)
    TweenService:Create(btn, TweenInfo.new(0.2), {BackgroundColor3 = targetColor}):Play()

    local pop = TweenService:Create(btn, TweenInfo.new(0.08), {Size = UDim2.new(1, -24, 0, 23)})
    pop:Play()
    pop.Completed:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.08), {Size = UDim2.new(1, -20, 0, 25)}):Play()
    end)

    btn.Text = (running and "ON" or "OFF") .. " Auto Harvest"

    if running then
        harvestThread = task.spawn(autoHarvest)
    else
        harvestThread = nil
    end
end)
