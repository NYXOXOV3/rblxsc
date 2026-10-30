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

-- Server hop
local SCRIPT_URL = ""                          -- isi URL Pastebin/Gist raw
local VISIT_TTL  = 300
local VISIT_FILE = "teleport_visited.json"
local MAX_VISIT_ENTRIES = 500

-- AUTO HOP saat pumpkin habis
local EMPTY_GRACE_SECONDS = 8                  -- detik tanpa pumpkin sebelum hop
local HOP_COOLDOWN        = 10                 -- jeda minimum antar hop attempt
local AUTOHOP_FILE        = "teleport_autohop.txt"

-- State auto rotate
local autoRotate       = false
local rotateConnection = nil

-- State auto teleport
local autoTeleport   = true
local autoTPConn     = nil
local lastTargetRef  = nil
local lastTargetPos  = nil
local lastCheckTime  = 0

-- State auto hop
local autoHopEmpty  = false
local emptyConn     = nil
local emptyTimer    = 0
local lastHopAttempt= 0

-- Blacklist server
local visitedServers = {}

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
    if emptyConn then
        pcall(function() emptyConn:Disconnect() end)
        emptyConn = nil
    end
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

-- ============ BLACKLIST HELPERS ============
local function hasFileAPI()
    return type(writefile) == "function"
       and type(readfile) == "function"
       and type(isfile) == "function"
end

local function pruneVisited()
    local now = tick()
    local count = 0
    for jobId, ts in pairs(visitedServers) do
        if now - ts >= VISIT_TTL then
            visitedServers[jobId] = nil
        else
            count = count + 1
        end
    end
    return count
end

local function loadVisitedFromFile()
    if not hasFileAPI() then return end
    if not isfile(VISIT_FILE) then return end
    local ok, content = pcall(readfile, VISIT_FILE)
    if not ok or not content or content == "" then return end
    local decodeOk, data = pcall(function() return HttpService:JSONDecode(content) end)
    if not decodeOk or type(data) ~= "table" then return end
    local now = tick()
    for jobId, ts in pairs(data) do
        if type(jobId) == "string" and type(ts) == "number" and now - ts < VISIT_TTL then
            visitedServers[jobId] = ts
        end
    end
end

local function loadVisitedFromPreload()
    if hasFileAPI() then
        _G.__preloadedVisited = nil
        return
    end
    local data = _G.__preloadedVisited
    _G.__preloadedVisited = nil
    if type(data) ~= "table" then return end
    local now = tick()
    for jobId, ts in pairs(data) do
        if type(jobId) == "string" and type(ts) == "number" and now - ts < VISIT_TTL then
            visitedServers[jobId] = ts
        end
    end
end

local function saveVisited()
    pruneVisited()
    local count = 0
    for _ in pairs(visitedServers) do count = count + 1 end
    if count > MAX_VISIT_ENTRIES then
        local sorted = {}
        for jobId, ts in pairs(visitedServers) do
            table.insert(sorted, { id = jobId, ts = ts })
        end
        table.sort(sorted, function(a, b) return a.ts < b.ts end)
        local toRemove = count - MAX_VISIT_ENTRIES
        for i = 1, toRemove do
            visitedServers[sorted[i].id] = nil
        end
    end
    if not hasFileAPI() then return end
    local ok, encoded = pcall(function() return HttpService:JSONEncode(visitedServers) end)
    if not ok then return end
    pcall(writefile, VISIT_FILE, encoded)
end

local function markVisited(jobId)
    if not jobId or jobId == "" then return end
    visitedServers[jobId] = tick()
    saveVisited()
end

local function isVisited(jobId)
    local ts = visitedServers[jobId]
    if not ts then return false end
    if tick() - ts >= VISIT_TTL then
        visitedServers[jobId] = nil
        return false
    end
    return true
end

local function getBlacklistCount()
    return pruneVisited()
end

local function clearVisited()
    visitedServers = {}
    if hasFileAPI() and isfile(VISIT_FILE) then
        pcall(delfile, VISIT_FILE)
    end
end

-- AUTO HOP persistence
local function loadAutoHopState()
    if not hasFileAPI() then
        local v = _G.__preloadedAutoHop
        _G.__preloadedAutoHop = nil
        return v == true
    end
    if not isfile(AUTOHOP_FILE) then return false end
    local ok, content = pcall(readfile, AUTOHOP_FILE)
    if not ok or not content then return false end
    return content == "1"
end

local function saveAutoHopState()
    if not hasFileAPI() then return end
    pcall(writefile, AUTOHOP_FILE, autoHopEmpty and "1" or "0")
end

loadVisitedFromFile()
loadVisitedFromPreload()
pruneVisited()

-- ============ SERVER HOP ============
local function fetchBestServer(mode)
    mode = mode or "low"
    local currentJobId = game.JobId
    local url = string.format(
        "https://games.roblox.com/v1/games/%d/servers/0?sortOrder=1&excludeFullGames=true&limit=100",
        game.PlaceId
    )

    local ok, response = pcall(function() return game:HttpGet(url) end)
    if not ok then
        return nil, "❌ Gagal fetch daftar server (HTTP error)"
    end

    local decodeOk, data = pcall(function() return HttpService:JSONDecode(response) end)
    if not decodeOk or not data or not data.data then
        return nil, "❌ Response server list tidak valid"
    end

    local servers = data.data
    if #servers == 0 then
        return nil, "❌ Tidak ada server tersedia saat ini"
    end

    local function sortFn(a, b)
        if mode == "high" then
            return (a.playing or 0) > (b.playing or 0)
        else
            return (a.playing or 0) < (b.playing or 0)
        end
    end

    local filtered = {}
    local skippedCurrent = 0
    local skippedBlacklist = 0
    for _, s in ipairs(servers) do
        if s.id == currentJobId then
            skippedCurrent = skippedCurrent + 1
        elseif isVisited(s.id) then
            skippedBlacklist = skippedBlacklist + 1
        else
            table.insert(filtered, s)
        end
    end

    local info = {
        total = #servers,
        skippedCurrent = skippedCurrent,
        skippedBlacklist = skippedBlacklist,
        fallback = false,
        mode = mode,
    }

    if #filtered == 0 then
        local fallbackList = {}
        for _, s in ipairs(servers) do
            if s.id ~= currentJobId then
                table.insert(fallbackList, s)
            end
        end
        if #fallbackList == 0 then
            return nil, "❌ Hanya ada 1 server tersedia (server ini). Tidak bisa hop.", info
        end
        table.sort(fallbackList, function(a, b)
            local ta = visitedServers[a.id] or 0
            local tb = visitedServers[b.id] or 0
            return ta < tb
        end)
        info.fallback = true
        info.filtered = #fallbackList
        return fallbackList[1], nil, info
    end

    table.sort(filtered, sortFn)
    info.filtered = #filtered
    return filtered[1], nil, info
end

local function safeQueueOnTeleport(code)
    if type(syn) == "table" and syn.queue_on_teleport then
        if pcall(function() syn.queue_on_teleport(code) end) then return true end
    end
    if type(queue_on_teleport) == "function" then
        if pcall(function() queue_on_teleport(code) end) then return true end
    end
    if type(fluxus) == "table" and fluxus.queue_on_teleport then
        if pcall(function() fluxus.queue_on_teleport(code) end) then return true end
    end
    if type(krnl) == "table" and krnl.queue_on_teleport then
        if pcall(function() krnl.queue_on_teleport(code) end) then return true end
    end
    return false
end

local function buildQueuePayload()
    local preludes = {}
    local base = string.format([[pcall(function() loadstring(game:HttpGet("%s"))() end)]], SCRIPT_URL)

    if not hasFileAPI() then
        local now = tick()
        local valid = {}
        for jobId, ts in pairs(visitedServers) do
            if now - ts < VISIT_TTL then
                valid[jobId] = ts
            end
        end
        local encoded = HttpService:JSONEncode(valid)
        table.insert(preludes, string.format(
            [[_G.__preloadedVisited = game:GetService("HttpService"):JSONDecode(%q)]],
            encoded
        ))
        table.insert(preludes, string.format([[_G.__preloadedAutoHop = %s]], tostring(autoHopEmpty)))
    end

    table.insert(preludes, base)
    return table.concat(preludes, "\n")
end

local function queueScriptAfterTeleport()
    if SCRIPT_URL == "" then
        return false, "SCRIPT_URL kosong — auto execute dilewati"
    end
    local payload = buildQueuePayload()
    if safeQueueOnTeleport(payload) then
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
frame.Size = UDim2.new(0, FRAME_W, 0, 425)
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

-- Row 1
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

-- Row 2
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

-- Row 4: LOW POP | HIGH POP
local lowBtn = Instance.new("TextButton")
lowBtn.Size = UDim2.new(0.5, -15, 0, 38)
lowBtn.Position = UDim2.new(0, 10, 0, 258)
lowBtn.Text = "🌐 LOW POP"
lowBtn.BackgroundColor3 = Color3.fromRGB(0, 140, 220)
lowBtn.TextColor3 = Color3.new(1, 1, 1)
lowBtn.Font = Enum.Font.GothamBold
lowBtn.TextSize = 13
lowBtn.BorderSizePixel = 0
lowBtn.Parent = frame

local lowCorner = Instance.new("UICorner")
lowCorner.CornerRadius = UDim.new(0, 6)
lowCorner.Parent = lowBtn

local highBtn = Instance.new("TextButton")
highBtn.Size = UDim2.new(0.5, -15, 0, 38)
highBtn.Position = UDim2.new(0.5, 5, 0, 258)
highBtn.Text = "🔥 HIGH POP"
highBtn.BackgroundColor3 = Color3.fromRGB(220, 100, 30)
highBtn.TextColor3 = Color3.new(1, 1, 1)
highBtn.Font = Enum.Font.GothamBold
highBtn.TextSize = 13
highBtn.BorderSizePixel = 0
highBtn.Parent = frame

local highCorner = Instance.new("UICorner")
highCorner.CornerRadius = UDim.new(0, 6)
highCorner.Parent = highBtn

-- Row 5: AUTO HOP | RESET BL (BARU)
local autoHopBtn = Instance.new("TextButton")
autoHopBtn.Size = UDim2.new(0.5, -15, 0, 38)
autoHopBtn.Position = UDim2.new(0, 10, 0, 302)
autoHopBtn.Text = "🔁 AUTO HOP: OFF"
autoHopBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
autoHopBtn.TextColor3 = Color3.new(1, 1, 1)
autoHopBtn.Font = Enum.Font.GothamBold
autoHopBtn.TextSize = 12
autoHopBtn.BorderSizePixel = 0
autoHopBtn.Parent = frame

local autoHopCorner = Instance.new("UICorner")
autoHopCorner.CornerRadius = UDim.new(0, 6)
autoHopCorner.Parent = autoHopBtn

local resetBtn = Instance.new("TextButton")
resetBtn.Size = UDim2.new(0.5, -15, 0, 38)
resetBtn.Position = UDim2.new(0.5, 5, 0, 302)
resetBtn.Text = "🧹 RESET BL"
resetBtn.BackgroundColor3 = Color3.fromRGB(120, 60, 60)
resetBtn.TextColor3 = Color3.new(1, 1, 1)
resetBtn.Font = Enum.Font.GothamBold
resetBtn.TextSize = 12
resetBtn.BorderSizePixel = 0
resetBtn.Parent = frame

local resetCorner = Instance.new("UICorner")
resetCorner.CornerRadius = UDim.new(0, 6)
resetCorner.Parent = resetBtn

-- Status
local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 75)
status.Position = UDim2.new(0, 10, 0, 345)
status.BackgroundTransparency = 1
status.Text = "LOW=tersedikit • HIGH=teramai • AUTO HOP=hop saat pumpkin habis"
status.TextColor3 = Color3.fromRGB(180, 180, 180)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Parent = frame

local function setStatus(msg, color)
    local count = getBlacklistCount()
    status.Text = string.format("[BL: %d] %s", count, msg)
    status.TextColor3 = color or Color3.fromRGB(180, 180, 180)
end

-- ============ SHARED HOP HANDLER ============
local function doServerHop(mode)
    if not running then return end

    -- Reset timer & cooldown supaya auto-hop tidak langsung menyusul
    lastHopAttempt = tick()
    emptyTimer = 0

    local modeLabel = (mode == "high") and "HIGH POP" or "LOW POP"
    setStatus(string.format("🌐 [%s] Mencari server...", modeLabel), Color3.fromRGB(0, 200, 255))

    if SCRIPT_URL ~= "" then
        local queueOk = queueScriptAfterTeleport()
        if not queueOk then
            setStatus("⚠ queue_on_teleport gagal — hop tetap lanjut.", Color3.fromRGB(255, 210, 90))
        end
    end

    local server, err, info = fetchBestServer(mode)
    if not server then
        setStatus(err or "❌ Gagal mendapatkan server.", Color3.fromRGB(255, 110, 110))
        return
    end

    local jobId = server.id
    local playing = server.playing or 0
    local maxPlayers = server.maxPlayers or "?"

    markVisited(jobId)

    local infoMsg = ""
    if info then
        if info.fallback then
            infoMsg = " (fallback: semua ter-BL)"
        elseif info.skippedBlacklist > 0 then
            infoMsg = string.format(" (skip %d BL)", info.skippedBlacklist)
        end
    end

    setStatus(string.format("🌐 [%s] → %d/%s pemain%s — teleport...",
        modeLabel, playing, maxPlayers, infoMsg), Color3.fromRGB(0, 200, 255))

    local teleportOk, teleportErr = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, player)
    end)

    if not teleportOk then
        visitedServers[jobId] = nil
        saveVisited()
        setStatus("❌ Teleport gagal: " .. tostring(teleportErr), Color3.fromRGB(255, 110, 110))
    else
        setStatus(string.format("✅ [%s] Hop ke %d/%s — di-BL 5 menit.",
            modeLabel, playing, maxPlayers), Color3.fromRGB(120, 255, 140))
    end
end

-- ============ EMPTY WATCHER ============
local function stopEmptyWatcher()
    if emptyConn then
        pcall(function() emptyConn:Disconnect() end)
        emptyConn = nil
    end
end

local function startEmptyWatcher()
    stopEmptyWatcher()
    emptyTimer = 0
    emptyConn = RunService.Heartbeat:Connect(function(dt)
        if not running or not autoHopEmpty then
            stopEmptyWatcher()
            return
        end
        if tick() - lastHopAttempt < HOP_COOLDOWN then return end

        local pumpkins = scanAllPumpkins()
        if #pumpkins > 0 then
            emptyTimer = 0
            return
        end

        emptyTimer = emptyTimer + dt
        if emptyTimer >= EMPTY_GRACE_SECONDS then
            emptyTimer = 0
            lastHopAttempt = tick()
            setStatus(string.format("🎃 Pumpkin habis %ds — auto hop HIGH POP...",
                EMPTY_GRACE_SECONDS), Color3.fromRGB(255, 160, 80))
            doServerHop("high")
        end
    end)
end

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
fab.Visible = false
fab.Parent = screenGui

local fabCorner = Instance.new("UICorner")
fabCorner.CornerRadius = UDim.new(1, 0)
fabCorner.Parent = fab

local fabStroke = Instance.new("UIStroke")
fabStroke.Color = Color3.fromRGB(255, 255, 255)
fabStroke.Thickness = 2
fabStroke.Transparency = 0.5
fabStroke.Parent = fab

track(minBtn.MouseButton1Click:Connect(function()
    if not running then return end
    frame.Visible = false
    fab.Visible = true
end))

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

-- ============ AUTO ROTATE ============
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

-- ============ AUTO TP ============
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

    setStatus(string.format("🎃 Auto-TP → %s (%.1f, %.1f, %.1f)",
        target.obj.Name, target.pivot.X, target.pivot.Y, target.pivot.Z),
        Color3.fromRGB(200, 140, 255))
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

-- ============ LOAD PERSISTED AUTO HOP ============
if loadAutoHopState() then
    autoHopEmpty = true
    autoHopBtn.Text = "🔁 AUTO HOP: ON"
    autoHopBtn.BackgroundColor3 = Color3.fromRGB(190, 70, 140)
    startEmptyWatcher()
    if SCRIPT_URL == "" then
        setStatus("⚠ AUTO HOP ON (tersimpan) — SCRIPT_URL kosong, hanya 1x hop.",
            Color3.fromRGB(255, 160, 80))
    else
        setStatus("🔁 AUTO HOP ON (tersimpan) — menunggu pumpkin habis...",
            Color3.fromRGB(200, 140, 255))
    end
end

-- ============ EVENT ============

track(closeBtn.MouseButton1Click:Connect(function()
    stopScript()
end))

track(tpBtn.MouseButton1Click:Connect(function()
    if not running then return end
    local cf = parseCFrame(textBox.Text)
    if not cf then
        setStatus("❌ Format salah! Butuh 3 atau 12 angka dipisah koma.", Color3.fromRGB(255, 110, 110))
        return
    end
    local root = getRoot()
    if not root then
        setStatus("❌ Character / HumanoidRootPart tidak ditemukan.", Color3.fromRGB(255, 110, 110))
        return
    end
    savedCFrame = root.CFrame
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = cf
    setStatus(string.format("✅ Teleport manual! (%.1f, %.1f, %.1f)", cf.X, cf.Y, cf.Z),
        Color3.fromRGB(120, 255, 140))
end))

track(autoBtn.MouseButton1Click:Connect(function()
    if not running then return end
    autoTeleport = not autoTeleport
    if autoTeleport then
        autoBtn.Text = "🎃 AUTO TP: ON"
        autoBtn.BackgroundColor3 = Color3.fromRGB(0, 170, 90)
        setStatus("🎃 Auto TP aktif — mencari pumpkin...", Color3.fromRGB(200, 140, 255))
        lastTargetRef = nil
        lastTargetPos = nil
        startAutoTP()
    else
        stopAutoTP()
        lastTargetRef = nil
        lastTargetPos = nil
        autoBtn.Text = "🎃 AUTO TP: OFF"
        autoBtn.BackgroundColor3 = Color3.fromRGB(150, 60, 200)
        setStatus("🎃 Auto TP dimatikan.", Color3.fromRGB(180, 180, 180))
    end
end))

track(backBtn.MouseButton1Click:Connect(function()
    if not running then return end
    if not savedCFrame then
        setStatus("⚠ Belum ada posisi tersimpan. Teleport dulu.", Color3.fromRGB(255, 210, 90))
        return
    end
    local root = getRoot()
    if not root then
        setStatus("❌ Character tidak ditemukan.", Color3.fromRGB(255, 110, 110))
        return
    end
    root.AssemblyLinearVelocity = Vector3.zero
    root.CFrame = savedCFrame
    setStatus("↩ Kembali ke posisi sebelumnya.", Color3.fromRGB(120, 200, 255))
end))

track(clearBtn.MouseButton1Click:Connect(function()
    if not running then return end
    textBox.Text = ""
    setStatus("🗑 Input dikosongkan.", Color3.fromRGB(180, 180, 180))
end))

track(rotateBtn.MouseButton1Click:Connect(function()
    if not running then return end
    autoRotate = not autoRotate
    if autoRotate then
        local pivot = getFirstPumpkin()
        if not pivot then
            autoRotate = false
            setStatus("❌ Pumpkin tidak ditemukan, tidak bisa auto rotate.", Color3.fromRGB(255, 110, 110))
            return
        end
        rotateBtn.Text = "🔄 AUTO ROTATE: ON"
        rotateBtn.BackgroundColor3 = Color3.fromRGB(0, 170, 90)
        setStatus("🔄 Auto rotate aktif.", Color3.fromRGB(120, 255, 140))
        startAutoRotate()
    else
        stopRotate()
        rotateBtn.Text = "🔄 AUTO ROTATE: OFF"
        rotateBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
        setStatus("🔄 Auto rotate dimatikan.", Color3.fromRGB(180, 180, 180))
    end
end))

track(lowBtn.MouseButton1Click:Connect(function()
    doServerHop("low")
end))

track(highBtn.MouseButton1Click:Connect(function()
    doServerHop("high")
end))

-- AUTO HOP TOGGLE (BARU)
track(autoHopBtn.MouseButton1Click:Connect(function()
    if not running then return end
    autoHopEmpty = not autoHopEmpty
    saveAutoHopState()

    if autoHopEmpty then
        autoHopBtn.Text = "🔁 AUTO HOP: ON"
        autoHopBtn.BackgroundColor3 = Color3.fromRGB(190, 70, 140)
        if SCRIPT_URL == "" then
            setStatus("⚠ AUTO HOP ON, tapi SCRIPT_URL kosong — hanya 1x hop!",
                Color3.fromRGB(255, 160, 80))
        else
            setStatus("🔁 AUTO HOP aktif — hop HIGH POP saat pumpkin habis.",
                Color3.fromRGB(200, 140, 255))
        end
        startEmptyWatcher()
    else
        stopEmptyWatcher()
        emptyTimer = 0
        autoHopBtn.Text = "🔁 AUTO HOP: OFF"
        autoHopBtn.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
        setStatus("🔁 AUTO HOP dimatikan.", Color3.fromRGB(180, 180, 180))
    end
end))

track(resetBtn.MouseButton1Click:Connect(function()
    if not running then return end
    clearVisited()
    setStatus("🧹 Blacklist server di-reset (kosong).", Color3.fromRGB(180, 200, 255))
end))
