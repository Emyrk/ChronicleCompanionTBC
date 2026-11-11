local T = _G.Test
local cases = {}

local function add(name, run)
    cases[#cases + 1] = { name = name, run = run }
end

local RU_TAB_NAMES = {
    "\208\158\209\128\209\131\208\182\208\184\208\181",
    "\208\157\208\181\208\184\209\129\209\130\208\190\208\178\209\129\209\130\208\178\208\190",
    "\208\151\208\176\209\137\208\184\209\130\208\176",
}

local EN_TAB_NAMES = { "Arms", "Fury", "Protection" }
local WARRIOR_BACKGROUNDS = { "WarriorArms", "WarriorFury", "WarriorProtection" }

local function loadTalentScan(options)
    options = options or {}
    local names = options.names or EN_TAB_NAMES
    local backgrounds = options.backgrounds or WARRIOR_BACKGROUNDS
    local ranks = options.ranks or {
        [1] = { 5, 0 },
        [2] = { 0, 3 },
        [3] = { 1, 1 },
    }

    _G.Chronicle = {
        Capture = {},
        Logger = { Debug = function() end, Info = function() end },
    }
    _G.GetLocale = function() return options.locale or "enUS" end
    _G.UnitClass = function()
        return options.className or "Warrior", options.classToken or "WARRIOR"
    end
    _G.GetNumTalentTabs = function() return 3 end
    _G.GetTalentTabInfo = function(tab)
        local points = 0
        for _, rank in ipairs(ranks[tab]) do points = points + rank end
        return names[tab], "Icon" .. tab, points, backgrounds[tab]
    end
    _G.GetNumTalents = function() return 2 end
    _G.GetTalentInfo = function(tab, index)
        local rank = ranks[tab][index]
        return "Talent" .. tab .. index, "TalentIcon", index, 1, rank, 5
    end

    dofile("Capture/TalentScan.lua")
    return Chronicle.Capture
end

add("Russian talent names are accepted and rank strings are preserved", function()
    local capture = loadTalentScan({ locale = "ruRU", names = RU_TAB_NAMES })
    local talents = capture.ScanTalents("raid1", true)

    T.truthy(talents)
    T.equal(talents.active_group, 1)
    T.equal(talents.num_groups, 1)
    T.equal(talents.groups[1].tabs[1].name, RU_TAB_NAMES[1])
    T.equal(talents.groups[1].rank_string, "50}03}11")
end)

add("localized names do not control inspect-buffer validation", function()
    local capture = loadTalentScan({ locale = "enUS", names = RU_TAB_NAMES })
    T.truthy(capture.ScanTalents("raid1", true))
end)

add("all TBC class tokens accept their stock talent background prefix", function()
    local fixtures = {
        { "WARRIOR", "WarriorArms" },
        { "PALADIN", "PaladinHoly" },
        { "HUNTER", "HunterBeastMastery" },
        { "ROGUE", "RogueAssassination" },
        { "PRIEST", "PriestDiscipline" },
        { "SHAMAN", "ShamanElementalCombat" },
        { "MAGE", "MageArcane" },
        { "WARLOCK", "WarlockCurses" },
        { "DRUID", "DruidBalance" },
    }

    for _, fixture in ipairs(fixtures) do
        local capture = loadTalentScan({
            classToken = fixture[1],
            backgrounds = { fixture[2], fixture[2], fixture[2] },
        })
        T.truthy(capture.ScanTalents("raid1", true), fixture[1] .. " background rejected")
    end
end)

add("Russian clients reject a known cross-class inspect buffer", function()
    local capture = loadTalentScan({
        locale = "ruRU",
        names = RU_TAB_NAMES,
        backgrounds = { "WarriorArms", "MageFire", "WarriorProtection" },
    })

    T.falsy(capture.ScanTalents("raid1", true))
    T.falsy(capture.InspectTalentBufferMatches("raid1"))
end)

add("inspected talents reject an incomplete background", function()
    local capture = loadTalentScan({
        backgrounds = { "WarriorArms", "", "WarriorProtection" },
    })

    T.falsy(capture.ScanTalents("raid1", true))
    T.falsy(capture.InspectTalentBufferMatches("raid1"))
end)

add("inspected talents accept an unknown non-empty custom background", function()
    local capture = loadTalentScan({
        backgrounds = { "WarriorArms", "CustomFuryTree", "WarriorProtection" },
    })

    T.truthy(capture.ScanTalents("raid1", true))
    T.truthy(capture.InspectTalentBufferMatches("raid1"))
end)

add("self scans do not validate inspect-buffer backgrounds", function()
    local capture = loadTalentScan({
        backgrounds = { "MageFire", "", "CustomTree" },
    })

    T.truthy(capture.ScanTalents("player", false))
end)

return cases
