-- =============================================================================
-- Providers/ZoneProvider.lua
--
-- TBC port of the WotLK Zone provider. It preserves the same ten-field wire
-- record; fields unavailable on 2.4.3 are emitted as stable zero/empty values.
-- =============================================================================

local Log = Chronicle.Logger
local Relay = Chronicle.Relay
local Util = Chronicle.Util

local P = { priority = 2 }
local dirty = true
local lastPayload = nil
local lastEmitAt = 0
local REEMIT_SEC = 600

local function buildPayload()
    local inInstance, instanceType = IsInInstance()
    local name = ""
    if type(GetRealZoneText) == "function" then name = GetRealZoneText() or "" end
    if name == "" and type(GetZoneText) == "function" then name = GetZoneText() or "" end
    local subZone = type(GetSubZoneText) == "function" and GetSubZoneText() or ""

    name = Util.Sanitize(name)
    subZone = Util.Sanitize(subZone)
    instanceType = inInstance and (instanceType or "none") or "none"

    -- Shared WotLK format:
    -- Z:<name>,<type>,<diffIdx>,<diffName>,<maxPlayers>,<dynDiff>,<isDynamic>,<mapID>,<lfgID>,<subZone>
    return string.format("Z:%s,%s,0,,0,0,0,0,0,%s", name, instanceType, subZone)
end

function P:Label() return "Zone" end
function P:Dirty()
    if dirty or (time() - lastEmitAt) >= REEMIT_SEC then return 1 end
    return 0
end
function P:Poll()
    local now = time()
    if not dirty and (now - lastEmitAt) >= REEMIT_SEC then dirty = true end
    if not dirty then return nil end
    local payload = buildPayload()
    if payload == lastPayload and (now - lastEmitAt) < REEMIT_SEC then
        dirty = false
        return nil
    end
    dirty = false
    lastPayload = payload
    lastEmitAt = now
    return payload, "ZONE " .. (GetRealZoneText() or "?")
end
function P:MarkDirty()
    dirty = true
    Relay:Kick()
end
function P:GetState()
    return { dirty = dirty, lastPayload = lastPayload, lastEmitAt = lastEmitAt, reemitSec = REEMIT_SEC }
end

local function onZoneChanged() P:MarkDirty() end
Chronicle.RegisterEvent("ZONE_CHANGED_NEW_AREA", onZoneChanged)
Chronicle.RegisterEvent("PLAYER_ENTERING_WORLD", onZoneChanged)
Chronicle.RegisterEvent("ZONE_CHANGED", function()
    local _, instanceType = IsInInstance()
    if instanceType and instanceType ~= "none" then P:MarkDirty() end
end)

Relay:RegisterProvider(P)
Chronicle.ZoneProvider = P
