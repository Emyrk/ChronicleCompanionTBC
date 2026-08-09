-- =============================================================================
-- Capture/TalentScan.lua
--
-- Reads the single talent build available on WoW 2.4.3 for the local player
-- or the current inspect buffer. TBC has no dual-spec groups.
-- =============================================================================

local Log = Chronicle.Logger
local Capture = Chronicle.Capture

local CLASS_TAB_NAMES = {
    WARRIOR = { "Arms", "Fury", "Protection" },
    PALADIN = { "Holy", "Protection", "Retribution" },
    HUNTER = { "Beast Mastery", "Marksmanship", "Survival" },
    ROGUE = { "Assassination", "Combat", "Subtlety" },
    PRIEST = { "Discipline", "Holy", "Shadow" },
    SHAMAN = { "Elemental", "Enhancement", "Restoration" },
    MAGE = { "Arcane", "Fire", "Frost" },
    WARLOCK = { "Affliction", "Demonology", "Destruction" },
    DRUID = { "Balance", "Feral Combat", "Restoration" },
}

local function readBuild(isInspect)
    local numTabs = GetNumTalentTabs(isInspect) or 3
    local tabs = {}
    local rankParts = {}

    for tab = 1, numTabs do
        local tabName, tabIcon, tabPoints = GetTalentTabInfo(tab, isInspect)
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

local function validateTabNames(tabs, unit)
    local locale = type(GetLocale) == "function" and GetLocale() or "enUS"
    if locale ~= "enUS" and locale ~= "enGB" then return true end

    local _, classToken = UnitClass(unit)
    local expected = classToken and CLASS_TAB_NAMES[classToken]
    if not expected then return true end

    for i = 1, 3 do
        if tabs[i] and expected[i] and tabs[i].name ~= expected[i] then
            Log:Warn("TalentScan: inspect buffer mismatch for %s -- expected tab %d '%s', got '%s'",
                tostring(unit), i, expected[i], tostring(tabs[i].name))
            return false
        end
    end
    return true
end

function Capture.ScanTalents(unit, isInspect)
    unit = unit or "player"
    isInspect = isInspect or false

    local build = readBuild(isInspect)
    if isInspect and not validateTabNames(build.tabs, unit) then
        return nil
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
