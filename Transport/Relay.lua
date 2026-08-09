-- =============================================================================
-- Transport/Relay.lua
--
-- The hijack engine.  Overwrites SPELL_FAILED_* globals with our payload
-- so the engine writes it into WoWCombatLog.txt on SPELL_CAST_FAILED.
--
-- The relay is message-type-agnostic.  It pulls data from registered
-- providers in priority order.  Each provider implements:
--
--   provider.priority  number      lower = polled first
--   provider:Poll()    string|nil  nil = nothing to send
--   provider:Label()   string      for UI / debug output
--
-- When the relay needs data it walks providers by priority until one
-- returns a payload.  The payload is chunked on the fly and armed
-- into the SPELL_FAILED_* globals.  On confirmed landing (CLEU match)
-- we advance to the next chunk.  When the message is complete we poll
-- again.
--
-- Provider Poll() calls may be destructive, so each payload is completed before
-- the relay polls again. This prevents speculative batching from losing data.
-- =============================================================================

local Log = Chronicle.Logger
local C   = Chronicle.C

Chronicle.Relay = {}
local R = Chronicle.Relay

-- ---------------------------------------------------------------------------
-- Provider registry
-- ---------------------------------------------------------------------------

R.onRelayEvent = nil
local relayEventSequence = 0

local function emitRelayEvent(kind, detail)
    relayEventSequence = relayEventSequence + 1
    local callback = R.onRelayEvent
    if not callback then return end
    local ok, err = pcall(callback, kind, detail or "", relayEventSequence)
    if not ok then
        Log:Debug("Relay monitor callback failed: %s", tostring(err))
    end
end

local providers = {}   -- sorted { {priority, provider}, ... }

function R:RegisterProvider(provider)
    if not provider or not provider.Poll or not provider.priority then
        Log:Warn("Relay: invalid provider (needs .priority and :Poll())")
        return
    end
    -- Insert sorted by priority (lower first)
    local entry = { priority = provider.priority, provider = provider }
    local inserted = false
    for i = 1, #providers do
        if provider.priority < providers[i].priority then
            table.insert(providers, i, entry)
            inserted = true
            break
        end
    end
    if not inserted then
        providers[#providers + 1] = entry
    end
    local label = "?"
    local ok, value = pcall(provider.Label, provider)
    if ok and value then label = value end
    Log:Debug("Relay: registered provider '%s' (priority %d)",
        tostring(label), provider.priority)
    emitRelayEvent("PROVIDER", "registered " .. tostring(label))
end

function R:GetProviders()
    return providers
end

-- Diagnostic writes are intentionally kept outside the production provider
-- registry so the monitor shows the same provider chain as the WotLK addon.
local diagnosticQueue = {}
local diagnosticDropped = 0

local function enqueueDiagnostic(payload)
    if #diagnosticQueue >= C.DIAGNOSTIC_QUEUE_MAX then
        table.remove(diagnosticQueue, 1)
        diagnosticDropped = diagnosticDropped + 1
        emitRelayEvent("DROP", "diagnostic queue dropped oldest payload")
    end
    diagnosticQueue[#diagnosticQueue + 1] = payload
end

function R:ClearDiagnosticQueue()
    diagnosticQueue = {}
    emitRelayEvent("CLEAR", "diagnostic queue cleared")
end

-- ---------------------------------------------------------------------------
-- Hijack state
-- ---------------------------------------------------------------------------

local originals     = {}      -- { [globalName] = originalValue }
local eligibleGlobals = {}    -- globals present as strings on this client
local captured      = false
local globalsDirty  = false   -- true while globals hold our payload

-- Active message being chunked
local activePayload = nil     -- full payload string (from provider)
local activeLabel   = ""      -- provider label for debug
local activeCounter = 0       -- message counter digit (0-9)
local chunkOffset   = 0       -- bytes of activePayload already landed
local totalChunks   = 0       -- precomputed total chunk count
local landedChunks  = 0       -- how many chunks have landed so far

local armedIsLast = false    -- completion follows the armed chunk, not byte offset

-- What is currently written into the globals
local armedChunk    = nil
local suspendedChunk = nil     -- current normal chunk retained across pause/resume
local suspendedIsLast = false

-- Raw field-length probe state. These probes intentionally bypass normal
-- chunking so the client truncation boundary can be measured.
local fieldProbeExpected = nil
local fieldProbePrefix = nil
local lastFieldProbe = nil

-- Relay on/off
local active        = false
local paused        = false   -- manual pause via /clog relay pause

-- Metrics (in-memory, reset on reload)
local metrics = {
    chunks_landed = 0,
    chunks_missed = 0,
    messages_sent = 0,
    provider_polls = 0,
    provider_errors = 0,
    last_arm_at = 0,
    last_land_at = 0,
    last_miss_at = 0,
}

-- Rolling ten-minute throughput history used by the WotLK Meta provider.
local BUCKET_COUNT = 10
local BUCKET_SECONDS = 60
local bucketStart = time()
local buckets = {}
for i = 1, BUCKET_COUNT do
    buckets[i] = { landed = 0, missed = 0, errors = 0 }
end

local function rotateBuckets()
    local elapsed = time() - bucketStart
    if elapsed < BUCKET_SECONDS then return end
    local shifts = math.floor(elapsed / BUCKET_SECONDS)
    if shifts >= BUCKET_COUNT then
        buckets = {}
        for i = 1, BUCKET_COUNT do
            buckets[i] = { landed = 0, missed = 0, errors = 0 }
        end
        bucketStart = time()
        return
    end
    for _ = 1, shifts do
        for i = BUCKET_COUNT, 2, -1 do buckets[i] = buckets[i - 1] end
        buckets[1] = { landed = 0, missed = 0, errors = 0 }
    end
    bucketStart = bucketStart + shifts * BUCKET_SECONDS
end

local function recordBucket(field)
    rotateBuckets()
    buckets[1][field] = (buckets[1][field] or 0) + 1
end

function R:GetBuckets()
    rotateBuckets()
    local result = {}
    for i = 1, BUCKET_COUNT do
        result[i] = {
            landed = buckets[i].landed,
            missed = buckets[i].missed,
            errors = buckets[i].errors,
            minute_ago = i - 1,
        }
    end
    return result
end

function R:GetMetrics() return metrics end
function R:IsActive() return active end
function R:IsPaused() return paused end
function R:GetActiveLabel() return activeLabel end
function R:GetEligibleGlobalCount() return #eligibleGlobals end
function R:IsActivationPending() return false end
function R:GetArmedChunk() return armedChunk end
function R:GetRelayEventSequence() return relayEventSequence end

function R:GetProviderStates()
    local states = {}
    for i, entry in ipairs(providers) do
        local provider = entry.provider
        local label = "?"
        local dirty = 0
        local lastEmitAt = 0
        local dropped = 0

        if provider and provider.Label then
            local ok, value = pcall(provider.Label, provider)
            if ok and value then label = value end
        end
        if provider and provider.Dirty then
            local ok, value = pcall(provider.Dirty, provider)
            if ok and value then dirty = value end
        end
        if provider and provider.GetState then
            local ok, value = pcall(provider.GetState, provider)
            if ok and type(value) == "table" then
                lastEmitAt = value.lastEmitAt or 0
                dropped = value.dropped or 0
                -- Dirty() is the provider contract and must remain numeric for
                -- MetaProvider. GetState().dirty is often a UI boolean.
                if type(value.dirty) == "number" then dirty = value.dirty end
            end
        end

        states[i] = {
            label = label,
            priority = entry.priority,
            dirty = dirty,
            lastEmitAt = lastEmitAt,
            dropped = dropped,
            provider = provider,
        }
    end
    return states
end

function R:GetActiveProgress()
    if not activePayload then return 0, 0 end
    return landedChunks, totalChunks
end

-- ---------------------------------------------------------------------------
-- Originals capture / restore
-- ---------------------------------------------------------------------------

local function captureOriginals()
    if captured then return end
    for _, name in ipairs(C.HIJACK_GLOBALS) do
        if type(_G[name]) == "string" then
            originals[name] = _G[name]
            eligibleGlobals[#eligibleGlobals + 1] = name
        end
    end
    captured = true
    Log:Debug("Relay: captured %d eligible originals", #eligibleGlobals)
end

local function restoreOriginals()
    if not globalsDirty then return end
    for _, name in ipairs(eligibleGlobals) do
        _G[name] = originals[name]
    end
    globalsDirty = false
    armedChunk = nil
    armedIsLast = false
    Log:Debug("Relay: originals restored")
end

local function applyToGlobals(text)
    for _, name in ipairs(eligibleGlobals) do
        _G[name] = text
    end
    globalsDirty = true
    armedChunk = text
    metrics.last_arm_at = time()
    emitRelayEvent("ARMED", tostring(activeLabel) .. " (" .. #text .. " chars)")
end

-- ---------------------------------------------------------------------------
-- Chunking
--
-- Given a payload and a counter digit, produce the chunk at a given
-- byte offset. Framing uses the verified 1023-character TBC field:
--   first chunk:  [N<payload_slice>       (1021 payload chars max)
--   middle chunk: ~<payload_slice>        (1022 payload chars max)
--   last chunk:   ~<payload_slice>]       (1021 payload chars max)
--   single chunk: [N<payload_slice>]      (1020 payload chars max)
-- ---------------------------------------------------------------------------

local FIELD_MAX = C.FIELD_MAX_CHARS  -- 1023 on the verified TBC client

--- Compute total chunk count for a payload.
local function computeChunkCount(payload)
    local len = #payload
    -- Single-slot: [N + payload + ] <= FIELD_MAX.
    if len <= FIELD_MAX - 3 then return 1 end

    -- First chunk uses FIELD_MAX - 2 payload bytes after "[N".
    local remaining = len - (FIELD_MAX - 2)
    -- Continuation chunks have "~" prefix (1 char overhead)
    -- Last chunk capacity is FIELD_MAX - 2 payload bytes.
    -- Middle chunk capacity is FIELD_MAX - 1 payload bytes.
    if remaining <= FIELD_MAX - 2 then return 2 end  -- first + last
    remaining = remaining - (FIELD_MAX - 2)  -- subtract last chunk capacity
    local middles = math.ceil(remaining / (FIELD_MAX - 1))
    return 1 + middles + 1  -- first + middles + last
end

--- Build chunk at the given offset for a payload + counter.
-- Returns (chunkString, newOffset, isLast).
--
-- Chunk layout:
--   first chunk:  [N<payload>       (prefix = 2 chars)
--   middle chunk: ~<payload>        (prefix = 1 char)
--   last chunk:   ~<payload>]       (prefix = 1 char, suffix = 1 char)
--   single chunk: [N<payload>]      (prefix = 2 chars, suffix = 1 char)
local function buildChunk(payload, counter, offset)
    local len = #payload
    local isFirst = (offset == 0)

    -- Build prefix
    local prefix
    if isFirst then
        prefix = C.MSG_OPEN .. tostring(counter)
    else
        prefix = C.MSG_CONTINUE
    end

    -- How much payload can we fit?
    local capacity = FIELD_MAX - #prefix
    local remaining = len - offset

    -- Will this be the last chunk?
    local suffix = ""
    local isLast = false
    if remaining <= capacity - 1 then
        -- Fits with the closing bracket
        suffix = C.MSG_CLOSE
        isLast = true
        capacity = capacity - 1
    end

    local slice = payload:sub(offset + 1, offset + capacity)
    local newOffset = offset + #slice

    return prefix .. slice .. suffix, newOffset, isLast
end

-- ---------------------------------------------------------------------------
-- Provider polling
-- ---------------------------------------------------------------------------

--- Poll providers in priority order for a payload.
-- Returns (payload, label) or (nil, nil).
local function pollProviders()
    -- Keep aggregate poll telemetry without flooding the live feed on idle scans.
    metrics.provider_polls = metrics.provider_polls + 1

    if #diagnosticQueue > 0 then
        local payload = table.remove(diagnosticQueue, 1)
        emitRelayEvent("PULLED", "Diagnostics returned " .. #payload .. " bytes")
        return payload, "Diagnostics"
    end

    for _, entry in ipairs(providers) do
        local provider = entry.provider
        local label = "?"
        if provider and provider.Label then
            local okLabel, value = pcall(provider.Label, provider)
            if okLabel and value then label = value end
        end

        local ok, payload, summary = pcall(provider.Poll, provider)
        if ok and payload and payload ~= "" then
            if not summary or summary == "" then summary = label end
            emitRelayEvent("PULLED", label .. " returned " .. #payload .. " bytes")
            return payload, summary
        elseif not ok then
            metrics.provider_errors = metrics.provider_errors + 1
            recordBucket("errors")
            Log:Warn("Relay: provider '%s' Poll() error: %s",
                tostring(label), tostring(payload))
            emitRelayEvent("ERROR", label .. " poll failed")
        end
    end
    return nil, nil
end

--- Start a new message from a provider's payload.
local function startMessage(payload, label)
    activePayload = payload
    activeLabel   = label
    activeCounter = (activeCounter + 1) % (C.MSG_COUNTER_MAX + 1)
    chunkOffset   = 0
    totalChunks   = computeChunkCount(payload)
    landedChunks  = 0
    Log:Debug("Relay: new message [%d] from '%s' (%d chars, %d chunks)",
        activeCounter, label, #payload, totalChunks)
    emitRelayEvent("MESSAGE", label .. " " .. #payload .. " bytes / " .. totalChunks .. " chunks")
end

-- ---------------------------------------------------------------------------
-- Arm the next chunk
--
-- Called after a landing or when we first activate.  Builds the next
-- chunk and writes it to all SPELL_FAILED_* globals.
--
-- One provider payload is handled at a time. Provider polls can consume
-- data, so speculative bin-packing is deliberately disabled.
-- ---------------------------------------------------------------------------

local function armNext()
    -- Need a message?
    if not activePayload then
        local payload, label = pollProviders()
        if not payload then
            -- Nothing to send -- restore originals
            restoreOriginals()
            return
        end
        startMessage(payload, label)
    end

    local chunk, newOffset, isLast = buildChunk(activePayload, activeCounter, chunkOffset)

    -- Do not poll a second provider here. Provider Poll() calls are
    -- destructive, so optimistic bin-packing can silently drop a payload when
    -- it does not fit. Reliability is more important than saving a failure.

    applyToGlobals(chunk)
    armedIsLast = isLast
    chunkOffset = newOffset
end

-- ---------------------------------------------------------------------------
-- Landing + CLEU handler
-- ---------------------------------------------------------------------------

local function onLanding()
    local landedLabel = activeLabel
    local landedNumber = landedChunks + 1
    landedChunks = landedNumber
    metrics.chunks_landed = metrics.chunks_landed + 1
    metrics.last_land_at = time()
    recordBucket("landed")
    emitRelayEvent("LANDED", tostring(landedLabel) .. " chunk " ..
        landedNumber .. "/" .. totalChunks)

    -- Completion follows the chunk's explicit closing marker. At exact
    -- capacity boundaries the payload bytes can be exhausted by a non-final
    -- chunk, followed by a small closing chunk (`~]`).
    if armedIsLast then
        metrics.messages_sent = metrics.messages_sent + 1
        Log:Debug("Relay: message [%d] '%s' complete (%d chunks)",
            activeCounter, activeLabel, totalChunks)
        emitRelayEvent("SENT", tostring(activeLabel) .. " complete")
        activePayload = nil
        activeLabel = ""
    end

    -- Arm the next chunk (or poll for a new message)
    armNext()
end

local function onMiss()
    metrics.chunks_missed = metrics.chunks_missed + 1
    metrics.last_miss_at = time()
    recordBucket("missed")
    emitRelayEvent("MISSED", tostring(activeLabel) .. " retained for retry")
    -- Re-arm the same chunk -- it stays in the globals already.
    -- Nothing to do; the globals still hold our payload.
end

local function onSpellCastFailed(failedType)
    if not active or paused then return end

    if fieldProbeExpected then
        local expectedLength = #fieldProbeExpected
        local actualLength = #failedType
        local exact = (failedType == fieldProbeExpected)
        local prefixMatch = fieldProbePrefix and
            failedType:sub(1, #fieldProbePrefix) == fieldProbePrefix
        local suffixMatch = failedType:sub(-1) == "!"

        if not exact and not prefixMatch then
            -- Some failures such as resource/GCD errors are formatted C-side
            -- and ignore the localized globals. Keep the probe armed until a
            -- failure carrying our marker arrives.
            metrics.chunks_missed = metrics.chunks_missed + 1
            Log:Debug("Field probe ignored unrelated failure reason (%d chars)",
                actualLength)
            return
        end

        lastFieldProbe = {
            expected = expectedLength,
            actual = actualLength,
            exact = exact,
            prefix_match = prefixMatch and true or false,
            suffix_match = suffixMatch and true or false,
        }

        restoreOriginals()
        fieldProbeExpected = nil
        fieldProbePrefix = nil
        active = false
        activeLabel = ""

        if exact then
            Log:Info("Field probe PASS: expected=%d actual=%d tail=present",
                expectedLength, actualLength)
            emitRelayEvent("PROBE", "PASS " .. expectedLength .. " chars")
        else
            Log:Warn("Field probe TRUNCATED: expected=%d actual=%d tail=%s",
                expectedLength, actualLength, suffixMatch and "present" or "missing")
            emitRelayEvent("PROBE", "TRUNCATED expected " .. expectedLength ..
                " actual " .. actualLength)
        end

        -- A field probe temporarily owns the hijacked globals. Resume normal
        -- relay service immediately when combat logging still allows it.
        R:Reevaluate()
        return
    end

    -- If nothing is armed, try to get something
    if not armedChunk then
        armNext()
        return
    end

    -- Landing check: exact match
    if failedType == armedChunk then
        onLanding()
    else
        onMiss()
    end
end

-- ---------------------------------------------------------------------------
-- UIErrorsFrame suppression
--
-- When armed, the engine also routes SPELL_FAILED_* strings to the
-- red error text overlay.  We hook AddMessage and drop anything that
-- matches our current armed chunk.
-- ---------------------------------------------------------------------------

local uiErrorHooked = false
local originalUIErrorAddMessage = nil

local function installUIErrorHook()
    if uiErrorHooked then return end
    if not UIErrorsFrame then return end

    originalUIErrorAddMessage = UIErrorsFrame.AddMessage
    UIErrorsFrame.AddMessage = function(self, msg, ...)
        -- Drop messages that are our armed payload or a truncated field probe.
        if armedChunk and msg == armedChunk then
            return
        end
        if fieldProbePrefix and msg and
            msg:sub(1, #fieldProbePrefix) == fieldProbePrefix
        then
            return
        end
        -- Also drop anything that starts with our framing markers:
        --   [N  (message start + digit)
        --   ~   (continuation chunk)
        if msg and #msg >= 2 then
            local first = msg:sub(1, 1)
            if first == C.MSG_CONTINUE then
                return
            end
            local second = msg:sub(2, 2)
            if first == C.MSG_OPEN and second >= "0" and second <= "9" then
                return
            end
        end
        return originalUIErrorAddMessage(self, msg, ...)
    end
    uiErrorHooked = true
end

-- ---------------------------------------------------------------------------
-- Taint error suppression
--
-- Overwriting SPELL_FAILED_* globals causes taint.  We suppress the
-- cosmetic error popups.  The actual taint is harmless for our use case.
-- ---------------------------------------------------------------------------

local taintHooked = false

local function installTaintSuppression()
    if taintHooked then return end

    -- Layer 1: error handler wrapper. Some 2.4.3 server builds do not
    -- expose geterrorhandler even though seterrorhandler exists.
    if type(seterrorhandler) == "function" then
        local innerHandler = nil
        if type(geterrorhandler) == "function" then
            innerHandler = geterrorhandler()
        end
        seterrorhandler(function(msg)
            if type(msg) == "string"
                and msg:find("ChronicleCompanionTBC", 1, true)
                and msg:find("tainted", 1, true)
            then
                return
            end
            if innerHandler then return innerHandler(msg) end
        end)
    end

    -- Layer 2: StaticPopup suppression
    local popupNames = { "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED" }
    for _, name in ipairs(popupNames) do
        local dialog = StaticPopupDialogs and StaticPopupDialogs[name]
        if dialog then
            local origOnShow = dialog.OnShow
            dialog.OnShow = function(self, ...)
                -- If the popup text mentions our addon, hide it
                local text = self.text and self.text:GetText() or ""
                if text:find("ChronicleCompanionTBC", 1, true) then
                    self:Hide()
                    return
                end
                if origOnShow then return origOnShow(self, ...) end
            end
        end
    end

    taintHooked = true
end

-- ---------------------------------------------------------------------------
-- Activation / deactivation
-- ---------------------------------------------------------------------------

local function shouldBeActive()
    if paused then return false end
    if not LoggingCombat() then return false end
    local cfg = Chronicle.Config
    if cfg and cfg:Get("hijack_enabled") == false then return false end
    return true
end

function R:Activate()
    if active then return end
    captureOriginals()
    installUIErrorHook()
    installTaintSuppression()
    active = true
    Log:Debug("Relay: activated")
    emitRelayEvent("ACTIVATED", "relay active")

    -- Pause restores the localized globals but retains the exact in-flight
    -- chunk. Re-arm that chunk instead of advancing the payload offset.
    if suspendedChunk then
        local chunk = suspendedChunk
        local isLast = suspendedIsLast
        suspendedChunk = nil
        suspendedIsLast = false
        applyToGlobals(chunk)
        armedIsLast = isLast
    else
        armNext()
    end
end

function R:Deactivate()
    if not active and not fieldProbeExpected and not suspendedChunk then return end
    restoreOriginals()
    active = false
    activePayload = nil
    activeLabel = ""
    suspendedChunk = nil
    suspendedIsLast = false
    fieldProbeExpected = nil
    fieldProbePrefix = nil
    Log:Debug("Relay: deactivated")
    emitRelayEvent("DEACTIVATED", "relay inactive")
end

function R:Pause()
    if paused then return end
    paused = true

    -- Preserve only normal relay chunks. Raw field probes are disposable
    -- diagnostics and cannot be resumed through the normal landing path.
    if armedChunk and activePayload and not fieldProbeExpected then
        suspendedChunk = armedChunk
        suspendedIsLast = armedIsLast
    end

    restoreOriginals()
    active = false
    if fieldProbeExpected then activeLabel = "" end
    fieldProbeExpected = nil
    fieldProbePrefix = nil
    Log:Info("Relay paused")
    emitRelayEvent("PAUSED", "relay paused")
end

function R:Resume()
    paused = false
    Log:Info("Relay resumed")
    emitRelayEvent("RESUMED", "relay resumed")
    if shouldBeActive() then
        R:Activate()
    end
end

function R:Reevaluate()
    if shouldBeActive() and not active then
        R:Activate()
    elseif not shouldBeActive() and active then
        R:Deactivate()
    end
end

-- ---------------------------------------------------------------------------
-- Diagnostic writes
--
-- Enqueues bounded test payloads through the relay's private diagnostics queue.
-- Diagnostics are not part of the production provider registry.
-- ---------------------------------------------------------------------------

function R:Kick()
    if not active or paused or armedChunk or activePayload or fieldProbeExpected then
        return false
    end
    armNext()
    return armedChunk ~= nil
end

function R:InjectTest(text)
    if type(text) ~= "string" or text == "" then
        Log:Warn("Relay: diagnostic payload must be a non-empty string")
        return false
    end

    enqueueDiagnostic(text)
    emitRelayEvent("QUEUED", "Diagnostics queued " .. #text .. " bytes")

    -- If relay is active and idle, kick the private queue immediately.
    if active and not armedChunk then
        armNext()
    end
    Log:Info("Relay: queued diagnostic message (%d chars)", #text)
    return true
end

function R:InjectLengthTest(length)
    length = tonumber(length)
    if not length then
        Log:Warn("Relay length test requires a numeric payload length")
        return false
    end
    length = math.floor(length)
    if length < 1 or length > C.FIELD_PROBE_MAX_CHARS then
        Log:Warn("Relay length test must be between 1 and %d bytes",
            C.FIELD_PROBE_MAX_CHARS)
        return false
    end

    local prefix = "L" .. length .. ":"
    local suffix = "!"
    local fillLength = length - #prefix - #suffix
    local payload
    if fillLength >= 0 then
        payload = prefix .. string.rep("X", fillLength) .. suffix
    else
        payload = string.rep("X", length)
    end
    R:InjectTest(payload)
    return true
end

function R:StartFieldProbe(length)
    if fieldProbeExpected then
        Log:Warn("Relay field probe is already armed")
        return false
    end
    if activePayload or armedChunk then
        Log:Warn("Relay field probe requires an idle relay; wait for the armed message to land")
        return false
    end

    length = tonumber(length)
    if not length then
        Log:Warn("Relay field probe requires a numeric length")
        return false
    end
    length = math.floor(length)
    if length < C.FIELD_PROBE_MIN_CHARS or length > C.FIELD_PROBE_MAX_CHARS then
        Log:Warn("Relay field probe length must be between %d and %d",
            C.FIELD_PROBE_MIN_CHARS, C.FIELD_PROBE_MAX_CHARS)
        return false
    end

    captureOriginals()
    installUIErrorHook()
    installTaintSuppression()

    -- Keep the prefix short and deterministic so the logged field is easy to
    -- identify and its exact length can be counted outside the client.
    local prefix = "[[CLEN" .. length .. "]]"
    local suffix = "!"
    local fillLength = length - #prefix - #suffix
    if fillLength < 0 then
        Log:Warn("Relay field probe length %d is too short for its marker", length)
        return false
    end

    activePayload = nil
    activeLabel = "Field Probe"
    armedChunk = nil
    fieldProbePrefix = prefix
    fieldProbeExpected = prefix .. string.rep("X", fillLength) .. suffix
    lastFieldProbe = nil
    applyToGlobals(fieldProbeExpected)
    active = true
    paused = false

    Log:Info("Field probe armed: %d characters. Cause one spell failure.", length)
    return true
end

function R:GetLastFieldProbe()
    return lastFieldProbe
end

-- ---------------------------------------------------------------------------
-- Event wiring
-- ---------------------------------------------------------------------------

local function onCLEU(event, ...)
    local subevent = select(2, ...)
    if subevent ~= "SPELL_CAST_FAILED" then return end

    local sourceGUID = select(3, ...)
    if sourceGUID ~= UnitGUID("player") then return end

    local failedType = select(C.RELAY_FAILEDTYPE_ARG, ...)
    if failedType then
        onSpellCastFailed(failedType)
    end
end

local function onPlayerLogin()
    captureOriginals()
    -- Start relay if combat logging is already on
    R:Reevaluate()
end

local function onPlayerLogout()
    -- Unconditional safety net -- always restore
    if captured then
        for _, name in ipairs(eligibleGlobals) do
            _G[name] = originals[name]
        end
    end
end

-- Reevaluate on events that might change shouldBeActive()
Chronicle.RegisterEvent("PLAYER_LOGIN", onPlayerLogin)
Chronicle.RegisterEvent("PLAYER_LOGOUT", onPlayerLogout)
Chronicle.RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCLEU)

-- These could change LoggingCombat() state
Chronicle.RegisterEvent("PLAYER_ENTERING_WORLD", function()
    R:Reevaluate()
end)
