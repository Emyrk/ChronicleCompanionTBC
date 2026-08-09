-- =============================================================================
-- Core/Namespace.lua
--
-- Bootstrap for the Chronicle addon namespace.  Creates the single public
-- global (_G.Chronicle) and a shared event dispatcher frame.  Every other
-- module attaches itself to sub-tables of Chronicle rather than creating
-- new globals.
--
-- Load order: this file MUST be the first Chronicle source in the TOC
-- (after DispatchProbe.lua, which is a throwaway that also sets the global).
-- =============================================================================

Chronicle = Chronicle or {}
Chronicle.Capture = Chronicle.Capture or {}

-- Addon identity (used by Logger, TOC metadata lookups, etc.)
Chronicle.ADDON_NAME = "ChronicleCompanionTBC"

-- ---------------------------------------------------------------------------
-- Shared event frame + multi-handler dispatcher
--
-- Modules call Chronicle.RegisterEvent(event, fn) to subscribe.
-- Multiple handlers per event are supported.  The dispatcher frame is the
-- single point where :RegisterEvent / :UnregisterEvent hit the engine --
-- no other frame should be created for event routing.
-- ---------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "ChronicleEventFrame")
local handlers = {}  -- { [event] = { fn1, fn2, ... } }

eventFrame:SetScript("OnEvent", function(self, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        -- pcall so one bad handler doesn't break the rest
        local ok, err = pcall(list[i], event, ...)
        if not ok and Chronicle.Logger then
            Chronicle.Logger:Warn("Event handler error (%s): %s", event, tostring(err))
        end
    end
end)

--- Register a callback for a WoW event.
-- @param event  string  Event name (e.g. "PLAYER_LOGIN")
-- @param fn     function(event, ...) handler
function Chronicle.RegisterEvent(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        eventFrame:RegisterEvent(event)
    end
    -- Prevent duplicate registration of the same function
    local list = handlers[event]
    for i = 1, #list do
        if list[i] == fn then return end
    end
    list[#list + 1] = fn
end

--- Unregister a previously registered callback.
-- When the last handler for an event is removed the engine-level
-- registration is also dropped.
function Chronicle.UnregisterEvent(event, fn)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == fn then
            table.remove(list, i)
            break
        end
    end
    if #list == 0 then
        handlers[event] = nil
        eventFrame:UnregisterEvent(event)
    end
end

--- Access the raw event frame (for OnUpdate or other frame-level needs).
Chronicle.eventFrame = eventFrame

-- ---------------------------------------------------------------------------
-- Shared callback scheduler
-- ---------------------------------------------------------------------------

local scheduledCallbacks = {}

local function runScheduledCallbacks(self, elapsed)
    local remaining = {}
    local due = {}
    for i = 1, #scheduledCallbacks do
        local entry = scheduledCallbacks[i]
        entry.delay = entry.delay - elapsed
        if entry.delay <= 0 then
            due[#due + 1] = entry.fn
        else
            remaining[#remaining + 1] = entry
        end
    end
    scheduledCallbacks = remaining
    for i = 1, #due do
        local ok, err = pcall(due[i])
        if not ok and Chronicle.Logger then
            Chronicle.Logger:Warn("Scheduled callback error: %s", tostring(err))
        end
    end
    if #scheduledCallbacks == 0 then self:SetScript("OnUpdate", nil) end
end

function Chronicle.RunAfter(delay, fn)
    if type(fn) ~= "function" then return end
    scheduledCallbacks[#scheduledCallbacks + 1] = {
        delay = math.max(tonumber(delay) or 0, 0),
        fn = fn,
    }
    eventFrame:SetScript("OnUpdate", runScheduledCallbacks)
end

function Chronicle.RunNextFrame(fn)
    Chronicle.RunAfter(0, fn)
end

-- Boot message and slash registration live in Init.lua (last file in the TOC)
-- so they work even if a Capture module errors at load time.
