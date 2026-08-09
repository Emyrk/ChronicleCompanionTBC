-- =============================================================================
-- UI/RelayUI.lua
-- WotLK-style relay monitor implemented with stock WoW 2.4.3 widgets.
-- =============================================================================

local Relay = Chronicle.Relay
local Log = Chronicle.Logger
local C = Chronicle.C

local frame = nil
local statusLine = nil
local messageLine = nil
local armedLine = nil
local providerLines = {}
local totalsLine = nil
local feed = nil
local startButton = nil
local bucketRows = {}
local buckets = {}
local bucketMinute = math.floor(time() / 60)
local previousMetrics = { landed = 0, missed = 0, sent = 0 }
for i = 1, 10 do
    buckets[i] = { landed = 0, missed = 0, sent = 0 }
end

local function makeText(parent, template)
    return parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
end

local function makeButton(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetWidth(width)
    b:SetHeight(20)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function applyBackdrop(f)
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", f, "TOPLEFT", 5, -5)
    bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -5, 5)
    bg:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
    bg:SetVertexColor(0.02, 0.02, 0.03)
    bg:SetAlpha(0.94)
    f._chronicleBackground = bg
    f:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropBorderColor(0.38, 0.38, 0.42, 1)
end

local function appendFeed(text, r, g, b)
    if not feed or not text then return end
    feed:AddMessage(date("%H:%M:%S") .. "  " .. text,
        r or 0.75, g or 0.75, b or 0.75)
end

local function onRelayEvent(kind, detail, sequence)
    local r, g, b = 0.75, 0.75, 0.75
    if kind == "LANDED" or kind == "SENT" then
        r, g, b = 0.27, 1.0, 0.27
    elseif kind == "MISSED" or kind == "DROP" then
        r, g, b = 1.0, 0.82, 0.0
    elseif kind == "ERROR" then
        r, g, b = 1.0, 0.3, 0.3
    elseif kind == "ARMED" or kind == "QUEUED" or kind == "MESSAGE" then
        r, g, b = 0.4, 0.7, 1.0
    end
    appendFeed("#" .. tostring(sequence) .. " " .. kind .. "  " .. tostring(detail), r, g, b)
end

local function updateBuckets(metrics)
    local nowMinute = math.floor(time() / 60)
    local advance = nowMinute - bucketMinute
    if advance > 0 then
        if advance > 10 then advance = 10 end
        for _ = 1, advance do
            table.remove(buckets, 10)
            table.insert(buckets, 1, { landed = 0, missed = 0, sent = 0 })
        end
        bucketMinute = nowMinute
    end

    local landedDelta = metrics.chunks_landed - previousMetrics.landed
    local missedDelta = metrics.chunks_missed - previousMetrics.missed
    local sentDelta = metrics.messages_sent - previousMetrics.sent
    if landedDelta >= 0 then buckets[1].landed = buckets[1].landed + landedDelta end
    if missedDelta >= 0 then buckets[1].missed = buckets[1].missed + missedDelta end
    if sentDelta >= 0 then buckets[1].sent = buckets[1].sent + sentDelta end
    previousMetrics.landed = metrics.chunks_landed
    previousMetrics.missed = metrics.chunks_missed
    previousMetrics.sent = metrics.messages_sent
end

local function refresh()
    if not frame then return end
    local logging = LoggingCombat() and true or false
    local state = "INACTIVE"
    if Relay:IsPaused() then state = "PAUSED"
    elseif Relay:IsActive() then state = "ACTIVE" end

    local last = Relay:GetMetrics()
    updateBuckets(last)
    local lastLand = "n/a"
    if last.last_land_at and last.last_land_at > 0 then
        lastLand = tostring(math.max(0, time() - last.last_land_at)) .. "s"
    end
    statusLine:SetText("Status: " .. state .. "   CombatLog: " ..
        (logging and "ON" or "OFF") .. "   Globals: " .. Relay:GetEligibleGlobalCount() ..
        "   Last land: " .. lastLand)
    startButton:SetText(logging and "Stop Log" or "Start Log")

    local landed, total = Relay:GetActiveProgress()
    local label = Relay:GetActiveLabel()
    if label and label ~= "" then
        messageLine:SetText("Message: " .. label .. "  chunk " .. landed .. "/" .. total)
    else
        messageLine:SetText("Message: idle")
    end

    local armed = Relay:GetArmedChunk()
    if armed and armed ~= "" then
        local preview = armed:sub(1, C.RELAY_ARMED_PREVIEW_CHARS)
        if #armed > C.RELAY_ARMED_PREVIEW_CHARS then preview = preview .. "..." end
        armedLine:SetText("Armed: " .. #armed .. " chars  " .. preview)
    else
        armedLine:SetText("Armed: (none)")
    end

    local providers = Relay:GetProviderStates()
    for i = 1, #providerLines do
        local line = providerLines[i]
        local stateRow = providers[i]
        if stateRow then
            local emitted = "never"
            if stateRow.lastEmitAt and stateRow.lastEmitAt > 0 then
                emitted = tostring(math.max(0, time() - stateRow.lastEmitAt)) .. "s ago"
            end
            line:SetText("#" .. i .. "  " .. stateRow.label ..
                "    dirty:" .. tostring(stateRow.dirty) ..
                "    emit:" .. emitted ..
                "    drop:" .. tostring(stateRow.dropped or 0))
        else
            line:SetText("#" .. i .. "  --")
        end
    end

    for i = 1, #bucketRows do
        local bucket = buckets[i]
        local minuteLabel = (i == 1) and "now" or ("-" .. (i - 1))
        bucketRows[i]:SetText(string.format("%3s   %4d   %4d   %4d",
            minuteLabel, bucket.landed, bucket.missed, bucket.sent))
    end

    totalsLine:SetText("Totals:  Landed " .. last.chunks_landed ..
        "  |  Missed " .. last.chunks_missed ..
        "  |  Sent " .. last.messages_sent ..
        "  |  Polls " .. last.provider_polls ..
        "  |  Errors " .. (last.provider_errors or 0))
end

local function buildFrame()
    if frame then return frame end
    local f = CreateFrame("Frame", "ChronicleRelayMonitorFrame", UIParent)
    f:Hide()
    f:SetWidth(560)
    f:SetHeight(520)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 30)
    f:SetMovable(true)
    f:EnableMouse(true)
    if f.SetClampedToScreen then f:SetClampedToScreen(true) end
    f:SetFrameStrata("DIALOG")
    applyBackdrop(f)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)

    local title = makeText(f, "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
    title:SetText("Chronicle Relay Monitor")
    title:SetTextColor(0.31, 0.76, 1)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    table.insert(UISpecialFrames, "ChronicleRelayMonitorFrame")

    startButton = makeButton(f, "Start Log", 75, function()
        LoggingCombat(not LoggingCombat())
        Relay:Reevaluate()
        refresh()
    end)
    startButton:SetPoint("RIGHT", close, "LEFT", -4, 0)

    statusLine = makeText(f)
    statusLine:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -38)
    messageLine = makeText(f)
    messageLine:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -58)
    armedLine = makeText(f)
    armedLine:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -78)

    local providersTitle = makeText(f)
    providersTitle:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -108)
    providersTitle:SetText("-- Providers --")
    providersTitle:SetTextColor(1, 0.82, 0)
    for i = 1, C.RELAY_MONITOR_PROVIDER_ROWS do
        local line = makeText(f)
        line:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -108 - (i * 17))
        providerLines[i] = line
    end

    local diagnosticsTitle = makeText(f)
    diagnosticsTitle:SetPoint("TOPLEFT", f, "TOPLEFT", 365, -108)
    diagnosticsTitle:SetText("-- Diagnostics --")
    diagnosticsTitle:SetTextColor(1, 0.82, 0)

    local helloButton = makeButton(f, "Queue Hello", 82, function()
        Relay:InjectTest("hello")
        refresh()
    end)
    helloButton:SetPoint("TOPLEFT", f, "TOPLEFT", 365, -132)

    local len1020Button = makeButton(f, "Len 1020", 72, function()
        Relay:InjectLengthTest(1020)
        refresh()
    end)
    len1020Button:SetPoint("LEFT", helloButton, "RIGHT", 4, 0)

    local len1021Button = makeButton(f, "Len 1021", 72, function()
        Relay:InjectLengthTest(1021)
        refresh()
    end)
    len1021Button:SetPoint("TOPLEFT", f, "TOPLEFT", 365, -158)

    local fieldButton = makeButton(f, "Field 1023", 82, function()
        if not LoggingCombat() then
            appendFeed("Combat logging must be on for field probe", 1.0, 0.82, 0.0)
            return
        end
        Relay:StartFieldProbe(1023)
        refresh()
    end)
    fieldButton:SetPoint("LEFT", len1021Button, "RIGHT", 4, 0)

    local clearButton = makeButton(f, "Clear Queue", 82, function()
        Relay:ClearDiagnosticQueue()
        refresh()
    end)
    clearButton:SetPoint("TOPLEFT", f, "TOPLEFT", 365, -184)

    local throughputTitle = makeText(f)
    throughputTitle:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -248)
    throughputTitle:SetText("-- Throughput (per minute) --")
    throughputTitle:SetTextColor(1, 0.82, 0)

    local throughputHeader = makeText(f)
    throughputHeader:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -268)
    throughputHeader:SetText(" Min   Land   Miss   Sent")
    throughputHeader:SetTextColor(0.55, 0.55, 0.55)
    for i = 1, 10 do
        local line = makeText(f)
        line:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -268 - (i * 17))
        bucketRows[i] = line
    end

    local feedTitle = makeText(f)
    feedTitle:SetPoint("TOPLEFT", f, "TOPLEFT", 200, -248)
    feedTitle:SetText("-- Live Feed --")
    feedTitle:SetTextColor(1, 0.82, 0)

    local feedBg = CreateFrame("Frame", nil, f)
    feedBg:SetPoint("TOPLEFT", f, "TOPLEFT", 200, -268)
    feedBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 42)
    feedBg:SetBackdrop({
        bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    feedBg:SetBackdropColor(0.02, 0.02, 0.02, 0.95)

    feed = CreateFrame("ScrollingMessageFrame", "ChronicleRelayFeed", feedBg)
    feed:SetPoint("TOPLEFT", feedBg, "TOPLEFT", 6, -6)
    feed:SetPoint("BOTTOMRIGHT", feedBg, "BOTTOMRIGHT", -6, 6)
    feed:SetFontObject(GameFontHighlightSmall)
    feed:SetJustifyH("LEFT")
    feed:SetMaxLines(200)
    if feed.SetFading then feed:SetFading(false) end

    totalsLine = makeText(f)
    totalsLine:SetPoint("BOTTOM", f, "BOTTOM", 0, 12)
    totalsLine:SetTextColor(0.65, 0.65, 0.65)

    local elapsed = 0
    f:SetScript("OnShow", function()
        elapsed = 0
        Relay.onRelayEvent = onRelayEvent
        appendFeed("Relay monitor attached", 0.4, 0.7, 1.0)
        refresh()
    end)
    f:SetScript("OnHide", function()
        if Relay.onRelayEvent == onRelayEvent then Relay.onRelayEvent = nil end
    end)
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= 0.25 then elapsed = 0; refresh() end
    end)

    frame = f
    return f
end

function Chronicle.ToggleRelayUI()
    local firstBuild = (frame == nil)
    local f = buildFrame()
    if firstBuild then
        f:Show()
    elseif f:IsShown() then
        f:Hide()
    else
        f:Show()
    end
end

function Chronicle.ShowRelayUI() buildFrame():Show() end
function Chronicle.HideRelayUI() if frame then frame:Hide() end end
