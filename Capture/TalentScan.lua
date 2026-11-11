-- =============================================================================
-- Capture/TalentScan.lua
--
-- Reads the single talent build available on WoW 2.4.3 for the local player
-- or the current inspect buffer. TBC has no dual-spec groups.
-- =============================================================================

local Log = Chronicle.Logger
local Capture = Chronicle.Capture

-- GetTalentTabInfo display names are localized. Stock 2.4.3 FrameXML uses
-- the fourth return value to load Interface\\TalentFrame\\<background>-*, and
-- those background values keep a stable class prefix across all three trees.
local CLASS_BACKGROUND_PREFIX = {
    WARRIOR = "Warrior",
    PALADIN = "Paladin",
    HUNTER = "Hunter",
    ROGUE = "Rogue",
    PRIEST = "Priest",
    SHAMAN = "Shaman",
    MAGE = "Mage",
    WARLOCK = "Warlock",
    DRUID = "Druid",
}

local function readBuild(isInspect)
    local numTabs = GetNumTalentTabs(isInspect) or 3
    local tabs = {}
    local rankParts = {}

    for tab = 1, numTabs do
        local tabName, tabIcon, tabPoints, tabBackground =
            GetTalentTabInfo(tab, isInspect)
        local numTalents = GetNumTalents(tab, isInspect) or 0
        local talents = {}
        local rankDigits = {}

        for idx = 1, numTalents do
            local name, icon, tier, column, rank, maxRank =
                GetTalentInfo(tab, idx, isInspect)
            rank = rank or 0
            maxRank = maxRank or 0
            rankDigits[#rankDigits + 1] = tostring(rank)

            if rank > 0 then
                talents[idx] = {
                    name = name,
                    rank = rank,
                    max = maxRank,
                }
            end
        end

        tabs[tab] = {
            name = tabName or ("Tab" .. tab),
            icon = tabIcon or "",
            background = tabBackground or "",
            points = tabPoints or 0,
            talents = talents,
        }
        rankParts[tab] = table.concat(rankDigits, "")
    end

    return {
        tabs = tabs,
        rank_string = table.concat(rankParts, "}"),
    }
end

local function backgroundClass(background)
    for classToken, prefix in pairs(CLASS_BACKGROUND_PREFIX) do
        if background:sub(1, #prefix) == prefix then
            return classToken
        end
    end
    return nil
end

local function validateTabBackgrounds(tabs, unit)
    local _, classToken = UnitClass(unit)
    local expectedPrefix = classToken and CLASS_BACKGROUND_PREFIX[classToken]
    if not expectedPrefix then return true end

    for i = 1, 3 do
        local background = tabs[i] and tabs[i].background or ""
        if background == "" then
            return false, i, expectedPrefix, background
        end

        if background:sub(1, #expectedPrefix) ~= expectedPrefix then
            local actualClass = backgroundClass(background)
            if actualClass then
                return false, i, expectedPrefix, background
            end
            -- Custom clients may use different asset names. Unknown non-empty
            -- backgrounds cannot prove a race, so accept them rather than
            -- dropping localized talent data.
        end
    end
    return true
end

--- Check whether the current inspect talent buffer belongs to the unit's class.
-- INSPECT_TALENT_READY has no unit argument on TBC, so unrelated or superseded
-- inspect requests can fire while a different unit is pending.
function Capture.InspectTalentBufferMatches(unit)
    local tabs = {}
    for i = 1, 3 do
        local _, _, _, tabBackground = GetTalentTabInfo(i, true)
        tabs[i] = { background = tabBackground or "" }
    end
    return validateTabBackgrounds(tabs, unit)
end

function Capture.ScanTalents(unit, isInspect)
    unit = unit or "player"
    isInspect = isInspect or false

    local build = readBuild(isInspect)
    if isInspect then
        local matches, tab, expected, actual = validateTabBackgrounds(build.tabs, unit)
        if not matches then
            Log:Debug("TalentScan: ignoring stale inspect buffer for %s -- expected tab %d %s background, got '%s'",
                tostring(unit), tab, expected, tostring(actual))
            return nil
        end
    end

    local result = {
        active_group = 1,
        num_groups = 1,
        groups = { [1] = build },
    }

    local totalPoints = 0
    for _, tab in pairs(build.tabs) do
        totalPoints = totalPoints + (tab.points or 0)
    end
    Log:Debug("TalentScan: %s -- single TBC build, total points=%d",
        tostring(unit), totalPoints)
    return result
end

function Capture.PrintTalents(talents)
    if not talents or not talents.groups or not talents.groups[1] then
        Log:Info("TalentScan: no talent data")
        return
    end

    local build = talents.groups[1]
    Log:Info("Talent build:")
    for i = 1, #build.tabs do
        local tab = build.tabs[i]
        Log:Info("  %s: %d pts", tab.name, tab.points)
    end
    Log:Info("  rank_string: %s", build.rank_string)
end

function Capture.ProbeTalents()
    Log:Info("WoW 2.4.3 supports one talent build; dual spec is unavailable")
    local talents = Capture.ScanTalents("player", false)
    Capture.PrintTalents(talents)
end
