-- ============================================
-- STEAL ON EGG - Versão Corrigida
-- ============================================

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local TeleportService   = game:GetService("TeleportService")
local LocalPlayer       = Players.LocalPlayer

-- ⚙️ CONFIGURAÇÕES
local CONFIG = {
    ReturnToBase     = true,
    DelayAfterSteal  = 1.5,
    BaseKeyword      = "Base",

    StealthMode      = false,
    StealthDelay     = 0.8,
    AutoFarm         = false,
    AutoFarmDelay    = 3,
    WalkSpeed        = 16,
    ESPEnabled       = false,
    ESPColor         = Color3.fromRGB(255, 215, 0),
    TeleportSmooth   = true,
    TweenTime        = 0.4,
    NotifyOnSteal    = true,
    AutoRejoin       = false,

    AntiBan          = true,
    RandomizeActions = true,
    RandomRange      = 0.3,
    FakeHuman        = true,
    LimitPerMinute   = 15,
    CooldownLong     = false,
    CooldownEvery    = 10,
    CooldownTime     = 8,
    LogDetections    = true,
}

local EggList = {
    "Egg Common", "Egg Rare", "Egg Epic",
    "Egg Legendary", "Egg Mythic", "Egg Secret",
}

local Stats = {
    TotalStolen = 0, TotalFailed = 0, LastSteal = "-",
    SessionStart = os.time(),
    StealsThisMinute = 0, MinuteStart = os.time(),
    CycleCount = 0,
}

local OriginalPosition   = nil
local ESPObjects         = {}
local AutoFarmThread     = nil
local NotifyFn           = function(t, c) print(("[%s] %s"):format(t, c)) end
local Rayfield           = nil

local has = function(name) return type(_G[name]) == "function" end

-- ============================================
-- 🛡️ ANTI-BAN (camadas leves, sem hooks perigosos)
-- ============================================
local function DetectAntiCheat()
    local suspects = {}
    for _, name in ipairs({"AntiCheat", "AC_Service", "ModerationService"}) do
        if game:FindFirstChild(name) then
            table.insert(suspects, name)
        end
    end
    local ps = LocalPlayer:FindFirstChild("PlayerScripts")
    if ps then
        for _, obj in ipairs(ps:GetChildren()) do
            local n = obj.Name:lower()
            if n:find("anti") or n:find("cheat") then
                table.insert(suspects, "PS:" .. obj.Name)
            end
        end
    end
    if #suspects > 0 and CONFIG.LogDetections then
        warn("[Anti-Ban] Possíveis ACs:", table.concat(suspects, ", "))
    end
    return suspects
end

local function HumanDelay(base)
    if not CONFIG.RandomizeActions or CONFIG.RandomRange <= 0 then
        return math.max(0.05, base)
    end
    local r = CONFIG.RandomRange
    return math.max(0.05, base + (math.random() * r * 2 - r))
end

local function CheckRateLimit()
    local now = os.time()
    if now - Stats.MinuteStart >= 60 then
        Stats.MinuteStart = now
        Stats.StealsThisMinute = 0
    end
    while Stats.StealsThisMinute >= CONFIG.LimitPerMinute do
        now = os.time()
        if now - Stats.MinuteStart >= 60 then
            Stats.MinuteStart = now
            Stats.StealsThisMinute = 0
            break
        end
        local waitTime = 60 - (now - Stats.MinuteStart)
        if CONFIG.LogDetections then
            warn("[Anti-Ban] Rate limit, aguardando", waitTime, "s")
        end
        NotifyFn("🛡️ Anti-Ban", "Rate limit: " .. waitTime .. "s")
        task.wait(math.min(waitTime, 5))
    end
end

local function RegisterSteal()
    Stats.StealsThisMinute += 1
end

-- Movimento "humano" leve, sem brigar com tween
local function FakeHumanMovement()
    if not CONFIG.FakeHuman then return end
    task.spawn(function()
        pcall(function()
            local cam = workspace.CurrentCamera
            if cam then
                cam.CFrame = cam.CFrame * CFrame.Angles(
                    math.rad(math.random(-2, 2)),
                    math.rad(math.random(-2, 2)),
                    0)
            end
        end)
    end)
end

local function MaybeLongCooldown()
    if not CONFIG.CooldownLong then return end
    Stats.CycleCount += 1
    if Stats.CycleCount % CONFIG.CooldownEvery == 0 then
        if CONFIG.LogDetections then
            print("[Anti-Ban] Cooldown longo:", CONFIG.CooldownTime, "s")
        end
        NotifyFn("🛡️ Anti-Ban", "Pausa: " .. CONFIG.CooldownTime .. "s")
        task.wait(CONFIG.CooldownTime)
    end
end

-- Hook de Kick: apenas loga o motivo, não bloqueia (bloquear é inútil)
local function HookKickDetection()
    if not (getrawmetatable and newcclosure and setreadonly and getnamecallmethod) then
        print("[Anti-Ban] Hook de Kick indisponível neste executor.")
        return
    end
    local ok, err = pcall(function()
        local mt = getrawmetatable(game)
        local oldNamecall = mt.__namecall
        setreadonly(mt, false)
        mt.__namecall = newcclosure(function(self, ...)
            if getnamecallmethod() == "Kick" then
                local args = {...}
                warn("[Anti-Ban] Kick detectado! Motivo:", args[1])
                Stats.TotalFailed += 1
            end
            return oldNamecall(self, ...)
        end)
        setreadonly(mt, true)
    end)
    if ok then
        print("[Anti-Ban] Hook de Kick ativado ✅")
    else
        warn("[Anti-Ban] Falha no hook:", err)
    end
end

local function SetupAntiBan()
    if not CONFIG.AntiBan then return end
    print("[Anti-Ban] Inicializando...")
    pcall(DetectAntiCheat)
    pcall(HookKickDetection)

    task.spawn(function()
        while task.wait(5) do
            if not CONFIG.AntiBan then continue end
            if Stats.TotalFailed > 10 and Stats.TotalFailed > Stats.TotalStolen * 2 then
                if CONFIG.LogDetections then
                    warn("[Anti-Ban] Muitas falhas, pausando 10s...")
                end
                task.wait(10)
            end
        end
    end)
    print("[Anti-Ban] Proteções ativas ✅")
end

-- ============================================
-- 📍 BASE
-- ============================================
local function SaveBasePosition()
    local char = LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        OriginalPosition = char.HumanoidRootPart.CFrame
        return true
    end
    return false
end

local function FindBasePosition()
    for _, obj in pairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name:lower():find(CONFIG.BaseKeyword:lower()) then
            local owner = obj:FindFirstChild("Owner")
            if owner and owner:IsA("ObjectValue") and owner.Value == LocalPlayer then
                return obj.CFrame + Vector3.new(0, 5, 0)
            end
            if obj.Name:find(LocalPlayer.Name) then
                return obj.CFrame + Vector3.new(0, 5, 0)
            end
        end
    end

    local pf = workspace:FindFirstChild(LocalPlayer.Name)
    if pf then
        for _, obj in pairs(pf:GetDescendants()) do
            if obj:IsA("BasePart") and obj.Name:lower():find(CONFIG.BaseKeyword:lower()) then
                return obj.CFrame + Vector3.new(0, 5, 0)
            end
        end
    end

    if OriginalPosition then return OriginalPosition end

    for _, obj in pairs(workspace:GetDescendants()) do
        if obj:IsA("SpawnLocation") then
            return obj.CFrame + Vector3.new(0, 5, 0)
        end
    end
    return nil
end

-- ============================================
-- 🚀 TELEPORTE
-- ============================================
local function TeleportTo(cframe)
    local char = LocalPlayer.Character
    if not char then return false end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false end

    local tweenTime = CONFIG.StealthMode and CONFIG.StealthDelay
                   or (CONFIG.AntiBan and HumanDelay(CONFIG.TweenTime))
                   or CONFIG.TweenTime

    if CONFIG.StealthMode or CONFIG.TeleportSmooth or CONFIG.AntiBan then
        local ok = pcall(function()
            local tween = TweenService:Create(hrp,
                TweenInfo.new(tweenTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                { CFrame = cframe })
            tween:Play()
            tween.Completed:Wait()
        end)
        if not ok then
            hrp.CFrame = cframe
        end
    else
        hrp.CFrame = cframe
        hrp.Velocity = Vector3.zero
    end
    return true
end

local function ReturnToBase()
    local baseCFrame = FindBasePosition()
    if not baseCFrame then return false end
    TeleportTo(baseCFrame)
    return true
end

-- ============================================
-- 👁️ ESP
-- ============================================
local function ClearESP()
    for _, obj in pairs(ESPObjects) do
        if obj and obj.Parent then obj:Destroy() end
    end
    ESPObjects = {}
end

local function ApplyESP()
    ClearESP()
    if not CONFIG.ESPEnabled then return end
    for _, obj in pairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name:lower():find("egg")
           and not obj:FindFirstChild("EggESP") then
            local hl = Instance.new("Highlight")
            hl.Name = "EggESP"
            hl.FillColor = CONFIG.ESPColor
            hl.OutlineColor = Color3.fromRGB(255, 255, 255)
            hl.FillTransparency = 0.5
            hl.Adornee = obj
            hl.Parent = obj
            table.insert(ESPObjects, hl)
        end
    end
end

-- ============================================
-- 🥚 STEAL
-- ============================================
local function StealEgg(eggName, autoReturn, silent)
    if CONFIG.AntiBan then
        CheckRateLimit()
        FakeHumanMovement()
    end

    if not silent then print("[Steal] Tentando:", eggName) end

    local egg = workspace:FindFirstChild(eggName, true)
    if not egg then
        Stats.TotalFailed += 1
        return false
    end

    if egg:IsA("BasePart") then
        TeleportTo(egg.CFrame + Vector3.new(0, 3, 0))
        task.wait(HumanDelay(CONFIG.StealthMode and CONFIG.StealthDelay or 0.3))
    end

    local success = false

    -- Método 1: ProximityPrompt (mais "oficial")
    local prompt = egg:FindFirstChildOfClass("ProximityPrompt")
        or egg:FindFirstChild("ProximityPrompt", true)
    if prompt and has("fireproximityprompt") then
        local ok = pcall(function() fireproximityprompt(prompt) end)
        if ok then success = true end
    end

    -- Método 2: ClickDetector
    if not success then
        local cd = egg:FindFirstChildOfClass("ClickDetector")
            or egg:FindFirstChild("ClickDetector", true)
        if cd and has("fireclickdetector") then
            local ok = pcall(function() fireclickdetector(cd) end)
            if ok then success = true end
        end
    end

    -- Método 3: RemoteEvent filtrado por contexto (última opção)
    if not success then
        for _, obj in pairs(ReplicatedStorage:GetDescendants()) do
            if obj:IsA("RemoteEvent") then
                local n = obj.Name:lower()
                local isEgg = n:find("egg")
                local isAction = n:find("steal") or n:find("collect") or n:find("take") or n:find("grab")
                if isEgg and isAction then
                    local ok = pcall(function() obj:FireServer(egg) end)
                    if ok then
                        success = true
                        break
                    end
                end
            end
        end
    end

    if success then
        Stats.TotalStolen += 1
        Stats.LastSteal = eggName
        if CONFIG.AntiBan then RegisterSteal() end
        if CONFIG.NotifyOnSteal and not silent then
            NotifyFn("🥚 Steal", "Pegou: " .. eggName)
        end
    else
        Stats.TotalFailed += 1
        if not silent then
            warn("[Steal] Falhou:", eggName)
        end
    end

    if autoReturn and CONFIG.ReturnToBase then
        task.wait(HumanDelay(CONFIG.DelayAfterSteal))
        ReturnToBase()
    end

    return success
end

-- ============================================
-- 🌾 AUTO-FARM
-- ============================================
local function StopAutoFarm()
    CONFIG.AutoFarm = false
    if AutoFarmThread then
        pcall(function() task.cancel(AutoFarmThread) end)
        AutoFarmThread = nil
    end
    print("[AutoFarm] Parado ❌")
end

local function StartAutoFarm()
    if AutoFarmThread then return end
    CONFIG.AutoFarm = true
    Stats.CycleCount = 0

    AutoFarmThread = task.spawn(function()
        while CONFIG.AutoFarm do
            print("[AutoFarm] Ciclo iniciado...")
            for _, eggName in ipairs(EggList) do
                if not CONFIG.AutoFarm then break end
                StealEgg(eggName, false, true)
                task.wait(HumanDelay(CONFIG.StealthMode and CONFIG.StealthDelay or 0.3))
            end
            if CONFIG.ReturnToBase then
                task.wait(HumanDelay(CONFIG.DelayAfterSteal))
                ReturnToBase()
            end
            MaybeLongCooldown()
            print("[AutoFarm] Ciclo completo.")
            task.wait(HumanDelay(CONFIG.AutoFarmDelay))
        end
        AutoFarmThread = nil
    end)
end

-- ============================================
-- ⚡ VELOCIDADE
-- ============================================
local function SetWalkSpeed(speed)
    CONFIG.WalkSpeed = speed
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = speed end
    end
end

LocalPlayer.CharacterAdded:Connect(function(char)
    task.wait(1)
    -- Atualiza posição da base se ainda não tiver
    if not OriginalPosition then
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp then OriginalPosition = hrp.CFrame end
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if hum then hum.WalkSpeed = CONFIG.WalkSpeed end
end)

-- ============================================
-- 🔄 AUTO-REJOIN
-- ============================================
local function SetupAutoRejoin()
    task.spawn(function()
        while true do
            task.wait(5)
            if CONFIG.AutoRejoin and not LocalPlayer.Parent then
                pcall(function() TeleportService:Teleport(game.PlaceId) end)
            end
        end
    end)
end

-- ============================================
-- 📋 SCAN
-- ============================================
local function ScanEggs()
    local found = {}
    for _, obj in pairs(workspace:GetDescendants()) do
        if obj:IsA("BasePart") and obj.Name:lower():find("egg") then
            if not table.find(found, obj.Name) then
                table.insert(found, obj.Name)
            end
        end
    end
    if #found > 0 then
        EggList = found
    else
        warn("[Scan] Nenhum ovo encontrado, mantendo lista padrão.")
    end
    return found
end

-- ============================================
-- 📦 CARREGAR RAYFIELD
-- ============================================
local function LoadRayfield()
    local urls = {
        "https://sirius.menu/rayfield",
        "https://raw.githubusercontent.com/shlexware/Rayfield/main/source",
    }
    for _, url in ipairs(urls) do
        local ok, result = pcall(function()
            return loadstring(game:HttpGet(url))()
        end)
        if ok and result then
            print("[Menu] Rayfield carregado de:", url)
            return result
        else
            warn("[Menu] Falha ao carregar de:", url, result)
        end
    end
    return nil
end

-- ============================================
-- 🖥️ MENU
-- ============================================
local function CreateMenu()
    if not Rayfield then
        warn("[Menu] Rayfield não disponível, seguindo sem interface.")
        return
    end

    local ok, err = pcall(function()
        local Window = Rayfield:CreateWindow({
            Name = "🥚 Steal on Egg",
            LoadingTitle = "Carregando...",
            LoadingSubtitle = "com Anti-Ban",
            ConfigurationSaving = { Enabled = true, FolderName = "StealOnEgg" },
        })

        NotifyFn = function(t, c)
            pcall(function()
                Rayfield:Notify({ Title = t, Content = c, Duration = 3 })
            end)
        end

        -- ABA OVOS
        local MainTab = Window:CreateTab("🥚 Ovos", 4483362458)
        MainTab:CreateButton({
            Name = "⚡ Pegar TODOS e Voltar",
            Callback = function()
                for _, e in ipairs(EggList) do
                    StealEgg(e, false)
                    task.wait(0.2)
                end
                task.wait(CONFIG.DelayAfterSteal)
                ReturnToBase()
            end,
        })
        MainTab:CreateButton({ Name = "🏠 Voltar para Base", Callback = ReturnToBase })
        MainTab:CreateButton({
            Name = "🔍 Escanear Ovos",
            Callback = function()
                ScanEggs()
                NotifyFn("Scan", #EggList .. " ovos encontrados")
            end,
        })
        MainTab:CreateSection("Ovos individuais")
        for _, eggName in ipairs(EggList) do
            MainTab:CreateButton({
                Name = "Pegar: " .. eggName,
                Callback = function() StealEgg(eggName, CONFIG.ReturnToBase) end,
            })
        end

        -- ABA AUTO-FARM
        local FarmTab = Window:CreateTab("🌾 Auto-Farm", 4483362458)
        FarmTab:CreateToggle({
            Name = "Ativar Auto-Farm",
            CurrentValue = CONFIG.AutoFarm,
            Callback = function(s)
                if s then StartAutoFarm() else StopAutoFarm() end
            end,
        })
        FarmTab:CreateSlider({
            Name = "Delay entre ciclos",
            Range = {1, 30}, Increment = 1, Suffix = "s",
            CurrentValue = CONFIG.AutoFarmDelay,
            Callback = function(v) CONFIG.AutoFarmDelay = v end,
        })

        -- ABA ANTI-BAN
        local BanTab = Window:CreateTab("🛡️ Anti-Ban", 4483362458)
        BanTab:CreateSection("Proteção")
        BanTab:CreateToggle({
            Name = "🛡️ Anti-Ban Ativo",
            CurrentValue = CONFIG.AntiBan,
            Callback = function(s) CONFIG.AntiBan = s end,
        })
        BanTab:CreateToggle({
            Name = "🎲 Randomizar delays",
            CurrentValue = CONFIG.RandomizeActions,
            Callback = function(s) CONFIG.RandomizeActions = s end,
        })
        BanTab:CreateToggle({
            Name = "🧍 Simular comportamento humano",
            CurrentValue = CONFIG.FakeHuman,
            Callback = function(s) CONFIG.FakeHuman = s end,
        })
        BanTab:CreateToggle({
            Name = "⏸️ Cooldown longo periódico",
            CurrentValue = CONFIG.CooldownLong,
            Callback = function(s) CONFIG.CooldownLong = s end,
        })
        BanTab:CreateSlider({
            Name = "Máx. steals por minuto",
            Range = {1, 60}, Increment = 1, Suffix = "/min",
            CurrentValue = CONFIG.LimitPerMinute,
            Callback = function(v) CONFIG.LimitPerMinute = v end,
        })

        -- ABA CONFIG
        local CfgTab = Window:CreateTab("⚙️ Config", 4483362458)
        CfgTab:CreateToggle({
            Name = "Voltar para Base após pegar",
            CurrentValue = CONFIG.ReturnToBase,
            Callback = function(s) CONFIG.ReturnToBase = s end,
        })
        CfgTab:CreateToggle({
            Name = "Notificar ao pegar",
            CurrentValue = CONFIG.NotifyOnSteal,
            Callback = function(s) CONFIG.NotifyOnSteal = s end,
        })
        CfgTab:CreateToggle({
            Name = "ESP em Ovos",
            CurrentValue = CONFIG.ESPEnabled,
            Callback = function(s) CONFIG.ESPEnabled = s; ApplyESP() end,
        })
        CfgTab:CreateSlider({
            Name = "WalkSpeed",
            Range = {16, 200}, In
