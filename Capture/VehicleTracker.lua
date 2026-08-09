-- =============================================================================
-- Capture/VehicleTracker.lua
--
-- Compatibility surface for the WotLK Vehicle provider. Stock WoW 2.4.3 has
-- no vehicle units, seats, possession bar, or vehicle control events, so the
-- provider remains present and clean without fabricating assignments.
-- =============================================================================

Chronicle.VehicleTracker = {}
local T = Chronicle.VehicleTracker
local listeners = {}

function T:RegisterListener(fn)
    if type(fn) ~= "function" then return end
    listeners[#listeners + 1] = fn
end

function T:GetActiveAssignments()
    return {}
end

function T:Refresh()
    -- Intentionally empty on TBC 2.4.3.
end
