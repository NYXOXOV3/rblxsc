-- Lokasi: StarterPlayer > StarterPlayerScripts (LocalScript)
-- Atau paste di executor (Delta, Wave, Synapse, dll)

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local HttpService= game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local player     = Players.LocalPlayer
local playerGui  = player:WaitForChild("PlayerGui")

local running = true
local savedCFrame = nil
local connections = {}

-- === Konfigurasi ===
local PUMPKIN_FOLDER   = "_LabuAktif"
local PUMPKIN_NAME     = "PumpkinTemplate"
local TELEPORT_OFFSET  = Vector3.new(0, 4, 0)
local CHECK_INTERVAL   = 0.4
local MIN_MOVE_DIST    = 5

-- URL script untuk auto-execute setelah server hop.
-- Upload script ini ke Pastebin (raw) / GitHub Gist (raw), lalu paste URL-nya di sini.
local SCRIPT_URL = ""  -- contoh: "https://pastebin.com/raw/xxxxxxx"

-- State auto rotate
local autoRotate       = false
local rotateConnection = nil

-- State auto teleport
local autoTeleport   = false
local autoTPConn     = nil
local lastTargetRef  = nil
local lastTargetPos  = nil
local lastCheckTime  = 0

-- ============ HELPER ============
local function track(conn)
    table.insert(connections, conn)
    return conn
end

local function stopRotate()
    if rotateConnection then
        pcall(function() rotateConnection:Disconnect() end)
        rotateConnection = nil
    end
end

local function stopAutoTP()
    if autoTPConn then
        pcall(function() autoTPConn:Disconnect() end)
        autoTPConn = nil
    end
end

local function stopScript()
    running = false
    autoRotate = false
    autoTeleport = false
    stopRotate()
    stopAutoTP()
    for _, c in ipairs(connections) do
        pcall(function() c:Disconnect() end)
    end
    connections = {}
    lastTargetRef = nil
    lastTargetPos = nil
    local gui = playerGui:FindFirstChild("TeleportGui")
    if gui then gui:Destroy() end
end

local function getRoot()
    local char = player.Character
    if not char then return nil end
    return char:FindFirstChild("HumanoidRootPart")
end

local function parseCFrame(text)
    local nums = {}
    for token in string.gmatch(text, "[^,]+") do
        local cleaned = token:gsub("[{}%[%]()]", "")
        cleaned = cleaned:match("^%s*(.-)%s*$") or ""
        local n = tonumber(cleaned)
        if n then table.insert(nums, n) end
    end
    if #nums == 12 then
        return CFrame.new(
            nums[1], nums[2], nums[3],
            nums[4], nums[5], nums[6],
            nums[7], nums[8], nums[9],
            nums[10], nums[11], nums[12]
        )
    elseif #nums == 3 then
        return CFrame.new(nums[1], nums[2], nums[3])
    end
    return nil
end

local function getPivotOf(obj)
    if not obj then return nil end
    local ok, pivot = pcall(function() return obj:GetPivot() end)
    if ok and pivot then return pivot end
    if obj:IsA("BasePart") then return obj.CFrame end
    return nil
end

local function scanAllPumpkins()
    local labu = workspace:FindFirstChild(PUMPKIN_FOLDER)
    if not labu then return {} end
    local result = {}
    for _, obj in ipairs(labu:GetDescendants()) do
        if obj.Name:lower():find("pumpkin") and (obj:IsA("Model") or obj:IsA("BasePart")) then
            local pivot = getPivotOf(obj)
            if pivot then
                table.insert(result, { obj = obj, pivot = pivot })
            end
        end
    end
    return result
end

local function getFirstPumpkin()
    local list = scanAllPumpkins()
    if #list > 0 then return list[1].pivot, list[1].obj end
    return nil, nil
end

-- ============ SERVER HOP HELPER ============
local function fetchLowestServer()
    local placeId = game.PlaceId
    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/0?sortOrder=1&excludeFullGames=true&limit=100",
        placeId
    )

    local ok, response = pcall(function()
        return game:HttpGet(url)
    end)
    if not ok then
        return nil, "❌ Gagal fetch daftar server (HTTP error)"
    end

    local decodeOk, data = pcall(function()
        return HttpService:JSONDecode(response)
    end)
    if not decodeOk or not data or not data.data then
        return nil, "❌ Response server list tidak valid"
    end

    local servers = data.data
    if #servers == 0 then
        return nil, "❌ Tidak ada server tersedia saat ini"
    end

    -- Urutkan dari pemain paling sedikit
    table.sort(servers, function(a, b)
        return (a.playing or 0) < (b.playing or 0)
    end)

    return servers[1], nil
end

-- Wrapper queue_on_teleport lintas executor[reference:1]
local function safeQueueOnTeleport(code)
    if type(syn) == "table" and syn.queue_on_teleport then
        local ok = pcall(function() syn.queue_on_teleport(code) end)
        if ok then return true end
    end
    if type(queue_on_teleport) == "function" then
        local ok = pcall(function() queue_on_teleport(code) end)
        if ok then return true end
    end
    if type(fluxus) == "table" and fluxus.queue_on_teleport then
        local ok = pcall(function() fluxus.queue_on_teleport(code) end)
        if ok then return true end
    end
    if type(krnl) == "table" and krnl.queue_on_teleport then
        local ok = pcall(function() krnl.queue_on_teleport(code) end)
        if ok then return true end
    end
    return false
end

local function queueScriptAfterTeleport()
    if SCRIPT_URL == "" then
        return false, "SCRIPT_URL kosong — auto execute dilewati"
    end
    local payload = string.format([[pcall(function() loadstring(game:HttpGet("%s"))() end)]], SCRIPT_URL)
    local ok = safeQueueOnTeleport(payload)
    if ok then
        return true
    end
    return false, "Executor tidak support queue_on_teleport"
end

-- ============ UI ============
local cam = workspace.CurrentCamera
local vpSize = (cam and cam.ViewportSize) or Vector2.new(1280, 720)
local FRAME_W = math.min(420, vpSize.X - 20)

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "TeleportGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = false
screenGui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Size = UDim2.new(0, FRAME_W, 0, 370)  -- lebih tinggi karena ada tombol hop
frame.Position = UDim2.new(0, 10, 0, 100)
frame.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
frame.BorderSizePixel = 0
frame.Active = true
frame.Draggable = true
frame.Parent = screenGui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 8)
corner.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -100, 0, 28)
title.Position = UDim2.new(0, 12, 0, 6)
title.BackgroundTransparency = 1
title.Text = "⚡ TELEPORT TOOL"
title.TextColor3 = Color3.fromRGB(0, 200, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = frame

-- MINIMIZE
local minBtn = Instance.new("TextButton")
minBtn.Size = UDim2.new(0, 30, 0, 30)
minBtn.Position = UDim2.new(1, -72, 0, 6)
minBtn.Text = "—"
minBtn.BackgroundColor3 = Color3.fromRGB(90, 90, 100)
minBtn.TextColor3 = Color3.new(1, 1, 1)
minBtn.Font = Enum.Font.GothamBold
minBtn.TextSize = 20
minBtn.BorderSizePixel = 0
minBtn.Parent = frame

local minCorner = Instance.new("UICorner")
minCorner.CornerRadius = UDim.new(0, 6)
minCorner.Parent = minBtn

-- CLOSE
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 30, 0, 30)
closeBtn.Position = UDim2.new(1, -38, 0, 6)
closeBtn.Text = "X"
closeBtn.BackgroundColor3 = Color3.fromRGB(220, 55, 55)
closeBtn.TextColor3 = Color3.new(1, 1, 1)
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 18
closeBtn.BorderSizePixel = 0
closeBtn.Parent = frame

local closeCorner = Instance.new("UICorner")
closeCorner.CornerRadius = UDim.new(0, 6)
closeCorner.Parent = closeBtn

-- TextBox
local textBox = Instance.new("TextBox")
textBox.Size = UDim2.new(1, -20, 0, 70)
textBox.Position = UDim2.new(0, 10, 0, 40)
textBox.BackgroundColor3 = Color3.fromRGB(45, 45, 52)
textBox.TextColor3 = Color3.new(1, 1, 1)
textBox.PlaceholderText = "617, 104.45, -1738, -0.609, 0, 0.793, 0, 1, 0, -0.793, 0, -0.609"
textBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 130)
textBox.Text = ""
textBox.TextSize = 13
textBox.TextWrapped = true
textBox.MultiLine = true
textBox.ClearTextOnFocus = false
textBox.Font = Enum.Font.Code
textBox.BorderSizePixel = 0
textBox.TextXAlignment = Enum.TextXAlignment.Left
textBox.TextYAlignment = Enum.TextYAlignment.Top
textBox.Parent = frame

local tbPad = Instance.new("UIPadding")
tbPad.PaddingLeft = UDim.new(0, 8)
tbPad.PaddingRight = UDim.new(0, 8)
tbPad.PaddingTop = UDim.new(0, 6)
tbPad.Parent = textBox

local tbCorner = Instance.new("UICorner")
tbCorner.CornerRadius = UDim.new(0, 6)
tbCorner.Parent = textBox

-- Row 1: TELEPORT | AUTO TP
local tpBtn = Instance.new("TextButton")
tpBtn.Size = UDim2.new(0.5, -15, 0, 42)
tpBtn.Position = UDim2.new(0, 10, 0, 118)
tpBtn.Text = "TELEPORT"
tpBtn.BackgroundColor3 = Color3.fromRGB(0, 170, 90)
tpBtn.TextColor3 = Color3.new(1, 1, 1)
tpBtn.Font = Enum.Font.GothamBold
tpBtn.TextSize = 14
tpBtn.BorderSizePixel = 0
tpBtn.Parent = frame

local tpCorner = Instance.new("UICorner")
tpCorner.CornerRadius = UDim.new(0, 6)
tpCorner.Parent = tpBtn

local autoBtn = Instance.new("TextButton")
autoBtn.Size = UDim2.new(0.5, -15, 0, 42)
autoBtn.Position = UDim2.new(0.5, 5, 0, 118)
autoBtn.Text = "🎃 AUTO TP: OFF"
autoBtn.BackgroundColor3 = Color3.fromRGB(150, 60, 200)
autoBtn.TextColor3 = Color3.new(1, 1, 1)
autoBtn.Font = Enum.Font.GothamBold
autoBtn.TextSize = 14
autoBtn.BorderSizePixel = 0
autoBtn.Parent = frame

local autoCorner = Instance.new("UICorner")
autoCorner.CornerRadius = UDim.new(0, 6)
autoCorner.Parent = autoBtn

-- Row 2: BACK | CLEAR
local backBtn = Instance.new("TextButton")
backBtn.Size = UDim2.new(0.5, -15, 0, 42)
backBtn.Position = UDim2.new(0, 10, 0, 166)
backBtn.Text = "⬅ BACK"
backBtn.BackgroundColor3 = Color3.fromRGB(200, 130, 0)
backBtn.TextColor3 = Color3.new(1, 1, 1)
backBtn.Font = Enum.Font.GothamBold
backBtn.TextSize = 14
backBtn.BorderSizePixel = 0
backBtn.Parent = frame

local backCorner = Instance.new("UICorner")
backCorner.CornerRadius = UDim.new(0, 6)
backCorner.Parent = backBtn

local clearBtn = Instance.new("TextButton")
clearBtn.Size = UDim2.new(0.5, -15, 0, 42)
clearBtn.Position = UDim2.new(0.5, 5, 0, 166)
clearBtn.Text = "🗑 CLEAR"
clearBtn.BackgroundColor3 = Color3.fromRGB(160, 60, 60)
clearBtn.TextColor3 = Color3.new(1, 1, 1)
clearBtn.Font = Enum.Font.GothamBold
clearBtn.TextSize = 14
clearBtn.BorderSizePixel = 0
clearBtn.Parent = frame

local clearCorner = Instance.new("UICorner")
clearCorner.CornerRadius = UDim.new(0, 6)
clearCorner.Parent = clearBtn

-- Row 3: AUTO ROTATE
local rotateBtn = Instance.new("TextButton")
rotateBtn.Size = UDim2.new(1, -20, 0, 38)
rotateBtn.Position = UDim2.new(0, 10, 0, 214)
rotateBtn.Text = "🔄 AUTO ROTATE: OFF"
rotateBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
rotateBtn.TextColor3 = Color3.new(1, 1, 1)
rotateBtn.Font = Enum.Font.GothamBold
rotateBtn.TextSize = 13
rotateBtn.BorderSizePixel = 0
rotateBtn.Parent = frame

local rotateCorner = Instance.new("UICorner")
rotateCorner.CornerRadius = UDim.new(0, 6)
rotateCorner.Parent = rotateBtn

-- Row 4: SERVER HOP (BARU)
local hopBtn = Instance.new("TextButton")
hopBtn.Size = UDim2.new(1, -20, 0, 38)
hopBtn.Position = UDim2.new(0, 10, 0, 258)
hopBtn.Text = "🌐 SERVER HOP (Pemain Tersedikit)"
hopBtn.BackgroundColor3 = Color3.fromRGB(0, 140, 220)
hopBtn.TextColor3 = Color3.new(1, 1, 1)
hopBtn.Font = Enum.Font.GothamBold
hopBtn.TextSize = 13
hopBtn.BorderSizePixel = 0
hopBtn.Parent = frame

local hopCorner = Instance.new("UICorner")
hopCorner.CornerRadius = UDim.new(0, 6)
hopCorner.Parent = hopBtn

-- Status
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 55)
status.Position = UDim2.new(0, 10, 0, 302)
status.BackgroundTransparency = 1
status.Text = "Masukkan koordinat manual, atau klik AUTO TP / SERVER HOP."
status.TextColor3 = Color3.fromRGB(180, 180, 180)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = frame

-- ============ MOBILE FAB ============
local fab = Instance.new("TextButton")
fab.Name = "MobileFAB"
fab.Size = UDim2.new(0, 64, 0, 64)
fab.Position = UDim2.new(1, -84, 1, -100)
fab.Text = "⚡"
fab.TextSize = 30
fab.BackgroundColor3 = Color3.fromRGB(0, 170, 220)
fab.TextColor3 = Color3.new(1, 1, 1)
fab.Font = Enum.Font.GothamBold
fab.BorderSizePixel = 0
fab.AutoButtonColor = true
fab.Visible = false
fab.Active = true
fab.Parent = screenGui

local fabCorner = Instance.new("UICorner")
fabCorner.CornerRadius = UDim.new(1, 0)
fabCorner.Parent = fab

local fabStroke = Instance.new("UIStroke")
fabStroke.Color = Color3.fromRGB(255, 255, 255)
fabStroke.Thickness = 2
fabStroke.Transparency = 0.5
fabStroke.Parent = fab

-- Minimize toggle
track(minBtn.MouseButton1Click:Connect(function()
    if not running then return end
    frame.Visible = false
    fab.Visible = true
end))

-- FAB tap vs drag
local fabDragging = false
local fabMoved    = false
local fabStartInputPos
local fabStartPos

track(fab.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        fabDragging = true
        fabMoved = false
        fabStartInputPos = input.Position
        fabStartPos = fab.Position
    end
end))

track(UIS.InputChanged:Connect(function(input)
    if not fabDragging then return end
    if input.UserInputType == Enum.UserInputType.MouseMovement
    or input.UserInputType == Enum.UserInputType.Touch then
        local delta = input.Position - fabStartInputPos
        if math.abs(delta.X) > 10 or math.abs(delta.Y) > 10 then
            fabMoved = true
        end
        if fabMoved then
            fab.Position = UDim2.new(
                fabStartPos.X.Scale, fabStartPos.X.Offset + delta.X,
                fabStartPos.Y.Scale, fabStartPos.Y.Offset + delta.Y
            )
        end
    end
end))

track(UIS.InputEnded:Connect(function(input)
    if not fabDragging then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
    or input.UserInputType == Enum.UserInputType.Touch then
        fabDragging = false
        if not fabMoved and running then
            frame.Visible = true
            fab.Visible = false
        end
    end
end))

-- ============ LOGIKA AUTO ROTATE ============
local function facePumpkin()
    local root = getRoot()
    if not root then return end
    local pivot = getFirstPumpkin()
    if not pivot then return end
    local myPos = root.Position
    local target = Vector3.new(pivot.X, myPos.Y, pivot.Z)
    if (target - myPos).Magnitude < 0.5 then return end
    root.CFrame = CFrame.lookAt(myPos, target)
end

local function startAutoRotate()
    stopRotate()
    rotateConnection = RunService.RenderStepped:Connect(function()
        if not running or not autoRotate then
            stopRotate()
            return
        end
        facePumpkin()
    end)
end

-- ============ LOGIKA AUTO TELEPORT ============
local function autoTeleportTick()
    if not running or not autoTeleport then return end
    local pumpkins = scanAllPumpkins()
    if #pumpkins == 0 then return end

    local target = nil
    for _, p in ipairs(pumpkins) do
        if lastTargetRef ~= p.obj then
            target = p
            break
        elseif lastTargetPos and (p.pivot.Position - lastTargetPos).Magnitude > MIN_MOVE_DIST then
            target = p
            break
        end
    end

    if not target then return end
    local root = getRoot()
    if not root then return end

    if not lastTargetRef then
        savedCFrame = root.CFrame
    end

    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = target.pivot + TELEPORT_OFFSET

    lastTargetRef = target.obj
    lastTargetPos = target.pivot.Position

    status.Text = string.format("🎃 Auto-TP → %s (%.1f, %.1f, %.1f)",
        target.obj.Name, target.pivot.X, target.pivot.Y, target.pivot.Z)
    status.TextColor3 = Color3.fromRGB(200, 140, 255)
end

local function startAutoTP()
    stopAutoTP()
    lastCheckTime = 0
    autoTPConn = RunService.Heartbeat:Connect(function()
        if not running or not autoTeleport then
            stopAutoTP()
            return
        end
        local now = tick()
        if now - lastCheckTime < CHECK_INTERVAL then return end
        lastCheckTime = now
        pcall(autoTeleportTick)
    end)
end

-- ============ EVENT ============

track(closeBtn.MouseButton1Click:Connect(function()
    stopScript()
end))

-- TELEPORT manual
track(tpBtn.MouseButton1Click:Connect(function()
    if not running then return end
    local cf = parseCFrame(textBox.Text)
    if not cf then
        status.Text = "❌ Format salah! Butuh 3 atau 12 angka dipisah koma."
        status.TextColor3 = Color3.fromRGB(255, 110, 110)
        return
    end
    local root = getRoot()
    if not root then
        status.Text = "❌ Character / HumanoidRootPart tidak ditemukan."
        status.TextColor3 = Color3.fromRGB(255, 110, 110)
        return
    end
    savedCFrame = root.CFrame
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = cf
    status.Text = string.format("✅ Teleport manual! (%.1f, %.1f, %.1f)", cf.X, cf.Y, cf.Z)
    status.TextColor3 = Color3.fromRGB(120, 255, 140)
end))

-- AUTO TP
track(autoBtn.MouseButton1Click:Connect(function()
    if not running then return end
    autoTeleport = not autoTeleport
    if autoTeleport then
        autoBtn.Text = "🎃 AUTO TP: ON"
        autoBtn.BackgroundColor3 = Color3.fromRGB(0, 170, 90)
        status.Text = "🎃 Auto TP aktif — mencari pumpkin..."
        status.TextColor3 = Color3.fromRGB(200, 140, 255)
        lastTargetRef = nil
        lastTargetPos = nil
        startAutoTP()
    else
        stopAutoTP()
        lastTargetRef = nil
        lastTargetPos = nil
        autoBtn.Text = "🎃 AUTO TP: OFF"
        autoBtn.BackgroundColor3 = Color3.fromRGB(150, 60, 200)
        status.Text = "🎃 Auto TP dimatikan."
        status.TextColor3 = Color3.fromRGB(180, 180, 180)
    end
end))

-- BACK
track(backBtn.MouseButton1Click:Connect(function()
    if not running then return end
    if not savedCFrame then
        status.Text = "⚠ Belum ada posisi tersimpan. Teleport dulu."
        status.TextColor3 = Color3.fromRGB(255, 210, 90)
        return
    end
    local root = getRoot()
    if not root then
        status.Text = "❌ Character tidak ditemukan."
        status.TextColor3 = Color3.fromRGB(255, 110, 110)
        return
    end
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = savedCFrame
    status.Text = "↩ Kembali ke posisi sebelumnya."
    status.TextColor3 = Color3.fromRGB(120, 200, 255)
end))

-- CLEAR
track(clearBtn.MouseButton1Click:Connect(function()
    if not running then return end
    textBox.Text = ""
    status.Text = "🗑 Input dikosongkan."
    status.TextColor3 = Color3.fromRGB(180, 180, 180)
end))

-- AUTO ROTATE
track(rotateBtn.MouseButton1Click:Connect(function()
    if not running then return end
    autoRotate = not autoRotate
    if autoRotate then
        local pivot = getFirstPumpkin()
        if not pivot then
            autoRotate = false
            status.Text = "❌ Pumpkin tidak ditemukan, tidak bisa auto rotate."
            status.TextColor3 = Color3.fromRGB(255, 110, 110)
            return
        end
        rotateBtn.Text = "🔄 AUTO ROTATE: ON"
        rotateBtn.BackgroundColor3 = Color3.fromRGB(0, 170, 90)
        status.Text = "🔄 Auto rotate aktif."
        status.TextColor3 = Color3.fromRGB(120, 255, 140)
        startAutoRotate()
    else
        stopRotate()
        rotateBtn.Text = "🔄 AUTO ROTATE: OFF"
        rotateBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
        status.Text = "🔄 Auto rotate dimatikan."
        status.TextColor3 = Color3.fromRGB(180, 180, 180)
    end
end))

-- SERVER HOP (BARU)
track(hopBtn.MouseButton1Click:Connect(function()
    if not running then return end

    status.Text = "🌐 Mencari server dengan pemain tersedikit..."
    status.TextColor3 = Color3.fromRGB(0, 200, 255)

    -- 1. Queue script untuk auto-execute setelah teleport
    local queueOk, queueErr = queueScriptAfterTeleport()
    if queueOk then
        status.Text = "🌐 Script di-queue untuk auto-execute setelah hop..."
    elseif SCRIPT_URL ~= "" then
        -- queue gagal tapi URL diisi
        status.Text = "⚠ " .. (queueErr or "queue_on_teleport gagal") .. " — hop tetap lanjut."
    else
        -- SCRIPT_URL kosong
        status.Text = "⚠ SCRIPT_URL kosong — hop tanpa auto-execute."
    end

    -- 2. Fetch server dengan pemain tersedikit
    local server, err = fetchLowestServer()
    if not server then
        status.Text = err or "❌ Gagal mendapatkan server."
        status.TextColor3 = Color3.fromRGB(255, 110, 110)
        return
    end

    local jobId = server.id
    local playing = server.playing or 0
    local maxPlayers = server.maxPlayers or "?"

    status.Text = string.format("🌐 Server ditemukan: %d/%s pemain — teleport...", playing, maxPlayers)
    status.TextColor3 = Color3.fromRGB(0, 200, 255)

    -- 3. Teleport ke server tersebut
    -- TeleportToPlaceInstance masih berfungsi di banyak executor meski deprecated.
    local teleportOk, teleportErr = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, player)
    end)

    if not teleportOk then
        status.Text = "❌ Teleport gagal: " .. tostring(teleportErr)
        status.TextColor3 = Color3.fromRGB(255, 110, 110)
    else
        status.Text = string.format("✅ Teleport ke server %d/%s pemain...", playing, maxPlayers)
        status.TextColor3 = Color3.fromRGB(120, 255, 140)
    end
end))
