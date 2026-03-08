SexyReputation = LibStub("AceAddon-3.0"):NewAddon("Sexy Reputations", "AceEvent-3.0", "AceTimer-3.0", "AceConsole-3.0")
local mod = SexyReputation
local tooltip

local RepCompat = LibStub("LibMagicUtil-1.0").Reputation

local fmt = string.format
local floor = math.floor
local IsAltKeyDown = IsAltKeyDown
local IsControlKeyDown = IsControlKeyDown
local IsShiftKeyDown = IsShiftKeyDown
local tconcat = table.concat
local FL

local L        = LibStub("AceLocale-3.0"):GetLocale("SexyReputation", false)
local LD       = LibStub("LibDropdown-1.0")
local QTIP     = LibStub("LibQTip-1.0")
local BAR      = LibStub("LibSimpleBar-1.0")

local ldb = LibStub("LibDataBroker-1.1"):NewDataObject(L["Sexy Reputation"],
        {
            type =  "data source",
            label = L["Sexy Reputation"],
            text = L["Factions"],
            icon = (UnitFactionGroup("player") == "Horde" and
                    [[Interface\Addons\SexyReputation\hordeicon]] or
                    [[Interface\Addons\SexyReputation\allianceicon]]),
        })


mod.repTitles = {
    FACTION_STANDING_LABEL1, -- Hated
    FACTION_STANDING_LABEL2, -- Hostile
    FACTION_STANDING_LABEL3, -- Unfriendly
    FACTION_STANDING_LABEL4, -- Neutral
    FACTION_STANDING_LABEL5, -- Friendly
    FACTION_STANDING_LABEL6, -- Honored
    FACTION_STANDING_LABEL7, -- Revered
    FACTION_STANDING_LABEL8, -- Exalted
}

-- names, used for looking up colors
mod.colorIds = {
    hated = 1, hostile = 2, unfriendly = 3, neutral = 4, friendly = 5, honored = 6, revered = 7, exalted = 8, renown = 9
}

local minReputationValues =  {
    [1] = -42000, -- Hated
    [2] =  -6000, -- Hostile
    [3] =  -3000, -- Unfriendly
    [4] =      0, -- Neutral
    [5] =   3000, -- Friendly
    [6] =   9000, -- Honored
    [7] =  21000, -- Revered
    [8] =  42000, -- Exalted
}


-- table recycling
local new, del, newHash, newSet, deepDel
do
    local list = setmetatable({}, {__mode='k'})
    function new(...)
        local t = next(list)
        if t then
            list[t] = nil
            for i = 1, select('#', ...) do
                t[i] = select(i, ...)
            end
            return t
        else
            return { ... }
        end
    end

    function newHash(...)
        local t = next(list)
        if t then
            list[t] = nil
        else
            t = {}
        end
        for i = 1, select('#', ...), 2 do
            t[select(i, ...)] = select(i+1, ...)
        end
        return t
    end

    function del(t)
        if type(t) ~= table then
            return nil
        end
        for k,v in pairs(t) do
            t[k] = nil
        end
        list[t] = true
        return nil
    end

    function deepDel(t)
        if type(t) ~= "table" then
            return nil
        end
        for k,v in pairs(t) do
            t[k] = deepDel(v)
        end
        return del(t)
    end
end

function mod:OnInitialize()
    mod.db = LibStub("AceDB-3.0"):New("SexyRepDB", mod.defaults, "Default")
    mod.gdb = mod.db.global
    mod.cdb = mod.db.char
    FL = mod.gdb.factionLookup

    mod.sessionFactionChanges = new()
    mod.factionGainsCache = new()
    mod:SetDefaultColors()
end

function mod:OnEnable()
    mod:RegisterEvent("COMBAT_TEXT_UPDATE")
    mod:RegisterEvent("QUEST_TURNED_IN")

    -- Run migrations once on first load after update
    mod:ScheduleTimer("RunMigrations", 2)

    mod:ScheduleTimer("UpdateLDBText", 3)
    mod:ScheduleTimer("ScanFactions", 5)
end

function mod:OnDisable()
    mod:UnregisterEvent("COMBAT_TEXT_UPDATE");
end

-- This transforms the faction name to an ID which is cached.
-- When wowFactionId is provided, it uses WoW's native faction ID directly.
-- This prevents issues with duplicate faction names in different trees.
-- The old name-based lookup is kept for backward compatibility during migration.
function mod:FactionID(name, wowFactionId)
    -- If WoW's native faction ID is provided, use it directly
    if wowFactionId then
        return wowFactionId
    end

    -- Backward compatibility: name-based lookup (used during migration)
    if type(name) == "number" then return name end
    local id = FL[name]
    if not id then
        id = (mod.gdb.numFactions or 0) + 1
        mod.gdb.numFactions = id
        FL[name] = id
    end
    return id
end

function mod:RunMigrations()
    mod:MigrateFactionData()
    mod:MigrateWarboundGains()
end

-- Migrates faction data from old name-based IDs to new native WoW faction IDs
-- This runs once on first load after the update
function mod:MigrateFactionData()
    -- Check if migration has already been completed
    if mod.gdb.factionIdMigrationComplete then
        return
    end

    local oldToNewMapping = {}
    local factionIdToName = {}  -- Map faction ID to name for composite key
    local migrationInfo = {
        timestamp = date("%Y-%m-%d %H:%M:%S"),
        mappingCount = 0,
        historyDates = 0,
        factionsMigrated = {},
    }

    -- Scan current factions to build mapping
    for idx = 1, 500 do
        local factionData = RepCompat.GetFactionDataByIndex(idx)
        local name = factionData and factionData.name
        local factionId = factionData and factionData.factionID
        if not name then break end

        if factionId then
            -- Store faction ID to name mapping for composite keys
            factionIdToName[factionId] = name

            -- Get the old custom ID for this faction name
            local oldId = FL[name]
            if oldId and oldId ~= factionId then
                oldToNewMapping[oldId] = factionId
                migrationInfo.mappingCount = migrationInfo.mappingCount + 1
                migrationInfo.factionsMigrated[name] = {
                    oldId = oldId,
                    newId = factionId,
                }
            end
        end
    end

    -- Migrate data if we have mappings
    if migrationInfo.mappingCount > 0 then
        -- Migrate faction history
        if mod.cdb.factionHistory then
            local newHistory = {}
            for date, factionData in pairs(mod.cdb.factionHistory) do
                newHistory[date] = {}
                migrationInfo.historyDates = migrationInfo.historyDates + 1
                for oldFactionId, amount in pairs(factionData) do
                    local newFactionId = oldToNewMapping[oldFactionId] or oldFactionId
                    newHistory[date][newFactionId] = (newHistory[date][newFactionId] or 0) + amount
                end
            end
            mod.cdb.factionHistory = newHistory
        end

        -- Migrate header fold states to composite key format (factionID_name)
        if mod.cdb.hf then
            local newHf = {}
            for oldFactionId, folded in pairs(mod.cdb.hf) do
                local newFactionId = oldToNewMapping[oldFactionId] or oldFactionId
                local factionName = factionIdToName[newFactionId]

                if factionName then
                    -- Create composite key: factionID_name
                    local compositeKey = newFactionId .. "_" .. factionName
                    newHf[compositeKey] = folded
                end
            end
            mod.cdb.hf = newHf
        end

        -- Migrate watched faction
        if mod.cdb.watchedFaction then
            mod.cdb.watchedFaction = oldToNewMapping[mod.cdb.watchedFaction] or mod.cdb.watchedFaction
        end
    end

    -- Special case: Clear data for faction 169 (Steamwheedle Cartel header)
    -- This faction should not have reputation data
    if mod.cdb.factionHistory then
        for date, factionData in pairs(mod.cdb.factionHistory) do
            factionData[169] = nil
        end
    end
    if mod.cdb.hf then
        mod.cdb.hf[169] = nil
    end
    if mod.cdb.watchedFaction == 169 then
        mod.cdb.watchedFaction = nil
    end

    -- Mark migration as complete
    mod.gdb.factionIdMigrationComplete = true

    -- Print info message
    if migrationInfo.mappingCount > 0 then
        print(fmt("SexyReputation: Migration complete - migrated %d factions across %d history dates to native WoW faction IDs",
                  migrationInfo.mappingCount, migrationInfo.historyDates))
    else
        print("SexyReputation: Migration complete - no faction ID changes needed")
    end
end

function mod:MigrateWarboundGains()
    if mod.gdb.warboundGainsMigrationComplete then return end

    -- Build set of warbound faction IDs from current scan
    local warboundIds = {}
    for idx = 1, 500 do
        local factionData = RepCompat.GetFactionDataByIndex(idx)
        if not factionData then break end
        local factionId = factionData.factionID
        if factionId and factionData.isAccountWide then
            warboundIds[factionId] = true
        end
    end

    local migratedCount = 0
    -- Iterate all character profiles in AceDB's raw storage
    local sv = mod.db.sv and mod.db.sv.char
    if sv then
        for charKey, charData in pairs(sv) do
            local fh = charData.factionHistory
            if fh then
                for date, dayData in pairs(fh) do
                    for factionId, amount in pairs(dayData) do
                        if warboundIds[factionId] then
                            -- Move to global history
                            if not mod.gdb.globalFactionHistory[date] then
                                mod.gdb.globalFactionHistory[date] = {}
                            end
                            mod.gdb.globalFactionHistory[date][factionId] =
                                (mod.gdb.globalFactionHistory[date][factionId] or 0) + amount
                            dayData[factionId] = nil
                            migratedCount = migratedCount + 1
                        end
                    end
                end
            end
        end
    end

    mod.gdb.warboundGainsMigrationComplete = true
    if migratedCount > 0 then
        print(fmt("SexyReputation: Migrated %d warbound faction gain entries to global history.", migratedCount))
    end
end

function mod:ScanFactions(toggleActiveId)
    local foldedHeaders = new()

    mod.allFactions = deepDel(mod.allFactions) or new()
    mod.factionIdToIdx = del(mod.factionIdToIdx) or new()
    mod.factionGainsCache = deepDel(mod.factionGainsCache) or new()

    -- Iterate through the factions until we run out. We need to unfold
    -- any folded header, which changes the number of factions, so we just
    -- keep iterating until GetFactionDataByIndex returns nil
    local fr = mod.cdb.fr

    for idx = 1, 500 do
        local factionData = RepCompat.GetFactionDataByIndex(idx)

        local name = factionData and factionData.name
        local description = factionData and factionData.description
        local standingId = factionData and factionData.reaction
        local bottomValue = factionData and factionData.currentReactionThreshold
        local topValue = factionData and factionData.nextReactionThreshold
        local earnedValue = factionData and factionData.currentStanding
        local atWarWith = factionData and factionData.atWarWith
        local canToggleAtWar = factionData and factionData.canToggleAtWar
        local isHeader = factionData and factionData.isHeader
        local isCollapsed = factionData and factionData.isCollapsed
        local hasRep = factionData and factionData.isHeaderWithRep
        local isWatched = factionData and factionData.isWatched
        local isChild = factionData and factionData.isChild
        local factionId = factionData and factionData.factionID

        local isParagon, paraVal, paraThreshold, paraRewardPending
        local isRenown, renownTitle, renownLevel, maxRenownLevels
        local isAccountWide

        if factionId then
            isAccountWide = factionData.isAccountWide
            --check if paragon and grab info
            isParagon = RepCompat.IsFactionParagon(factionId)

            if isParagon then
                paraVal, paraThreshold, _, paraRewardPending, _ = RepCompat.GetFactionParagonInfo(factionId)
            end

            isRenown = RepCompat.IsMajorFaction(factionId)
            if isRenown then
                local majorFactionData = C_MajorFactions.GetMajorFactionData(factionId)
                renownLevel = majorFactionData.renownLevel
                maxRenownLevels = majorFactionData.maxLevel or #C_MajorFactions.GetRenownLevels(factionId)
                renownTitle = fmt(RENOWN_LEVEL_LABEL, renownLevel)
                bottomValue = majorFactionData.renownLevelThreshold*(renownLevel-1)
                topValue = bottomValue + majorFactionData.renownLevelThreshold

                local isCapped = C_MajorFactions.HasMaximumRenown(factionId)
                earnedValue = isCapped and (majorFactionData.renownLevelThreshold*(maxRenownLevels-1))
                        or (bottomValue + majorFactionData.renownReputationEarned) or 0
            end
        end

        local nextFactionData = RepCompat.GetFactionDataByIndex(idx + 1)
        local nextName = nextFactionData and nextFactionData.name

        if name == nextName and nextName ~= "Guild" then break end -- bugfix
        if not name then  break end -- last one reached
        local friendInfo = RepCompat.GetFriendshipReputation(factionId)
        local isCapped
        local friendRank, friendMaxRank
        if friendInfo then
            if friendInfo.nextThreshold then
                bottomValue = friendInfo.reactionThreshold
                topValue = friendInfo.nextThreshold
                earnedValue = friendInfo.standing
            else
                bottomValue, topValue, earnedValue = 0, 1, 1
                isCapped = true
            end
            local rankInfo = RepCompat.GetFriendshipReputationRanks(factionId)
            if rankInfo then
                friendRank, friendMaxRank = rankInfo.currentLevel, rankInfo.maxLevel
            end
        end

        local faction = newHash("name", name,
                "desc", description,
                "bottomValue", bottomValue,
                "topValue", topValue,
                "reputation", earnedValue,
                "isHeader", isHeader,
                "standingId", standingId,
                "hasRep", hasRep or earnedValue ~= 0,
                "isParagon", isParagon or false,
                "paraVal", paraVal or nil,
                "paraThresh", paraThreshold or nil,
                "paraRewardPending", paraRewardPending or nil,
                "isRenown", isRenown or false,
                "renownTitle", renownTitle,
                "renownLevel", renownLevel,
                "maxRenownLevels", maxRenownLevels,
                "isChild", isChild,
                "friendId", friendInfo and friendInfo.friendshipFactionID,
                "friendshipText", friendInfo and friendInfo.text,
                "friendTextLevel", friendInfo and friendInfo.reaction,
                "friendRank", friendRank,
                "friendMaxRank", friendMaxRank,
                "friendIsCapped", isCapped,
                "isAccountWide", isAccountWide,
                "id", mod:FactionID(name, factionId))
        mod.allFactions[idx] = faction
        mod.factionIdToIdx[faction.id] = idx

        if faction.id == toggleActiveId then
            local isActive = RepCompat.IsFactionActive(idx)
            RepCompat.SetFactionActive(idx, not isActive)
            mod:ScanFactions() -- we need to rescan fully..
            return
        end

        if isHeader and isCollapsed then
            foldedHeaders[idx] = true
            RepCompat.ExpandFactionHeader(idx)
        end
        if fr and faction.name == FACTION_INACTIVE then
            mod.cdb.hf[faction.id] = true
        end
    end

    mod.cdb.fr = false

    -- Restore factions folded states
    for id = #mod.allFactions, 1, -1 do
        if foldedHeaders[id] then
            RepCompat.CollapseFactionHeader(id)
        end
    end
    del(foldedHeaders)

    -- Snapshot current character's rep data for cross-character tracking
    mod:SnapshotCharRepData()
end

function mod:SnapshotCharRepData()
    local charKey = mod.db.keys.char
    local _, className = UnitClass("player")
    local charEntry = mod.gdb.charRepData[charKey]
    if not charEntry then
        charEntry = { className = className, factions = {} }
        mod.gdb.charRepData[charKey] = charEntry
    else
        charEntry.className = className
    end
    local factions = charEntry.factions
    wipe(factions)
    for _, faction in ipairs(mod.allFactions) do
        if not faction.isHeader and not faction.isAccountWide and faction.hasRep and faction.id then
            factions[faction.id] = {
                standingId = faction.standingId,
                reputation = faction.reputation,
                bottomValue = faction.bottomValue,
                topValue = faction.topValue,
                isParagon = faction.isParagon or nil,
                paraVal = faction.paraVal,
                paraThresh = faction.paraThresh,
                friendId = faction.friendId,
                friendTextLevel = faction.friendTextLevel,
                isRenown = faction.isRenown or nil,
                renownLevel = faction.renownLevel,
                renownTitle = faction.renownTitle,
                maxRenownLevels = faction.maxRenownLevels,
            }
        end
    end
end

function mod:GetCrossCharRepForFaction(factionId)
    local results = {}
    local currentChar = mod.db.keys.char
    local currentRealm = GetRealmName()
    for charKey, charEntry in pairs(mod.gdb.charRepData) do
        local fData = charEntry.factions[factionId]
        if fData then
            local displayName = charKey
            -- Strip realm if same realm
            local name, realm = charKey:match("^(.+) %- (.+)$")
            if realm and realm == currentRealm then
                displayName = name
            end
            local classColor = RAID_CLASS_COLORS[charEntry.className]
            local colorHex = classColor and classColor.colorStr or "ffffffff"
            -- Determine standing text and color
            local title, colorId
            if fData.isRenown then
                title = fData.renownTitle or (RENOWN_LEVEL_LABEL and fmt(RENOWN_LEVEL_LABEL, fData.renownLevel or "?")) or "Renown"
                colorId = mod.colorIds.renown
            elseif fData.friendId then
                title = fData.friendTextLevel or ""
                colorId = mod.colorIds.friendly
            else
                title = mod.repTitles[fData.standingId] or ""
                colorId = fData.standingId or 4
            end
            local sc = mod.gdb.colors[colorId]
            local standingColor = sc and fmt("%02x%02x%02x", floor(sc.r*255), floor(sc.g*255), floor(sc.b*255)) or "ffffff"
            local rep = fData.reputation - fData.bottomValue
            local maxRep = fData.topValue - fData.bottomValue
            local repText
            if maxRep > 0 then
                repText = fmt("%s %d/%d", title, rep, maxRep)
            else
                repText = title
            end
            table.insert(results, {
                name = displayName,
                colorHex = colorHex,
                repText = repText,
                standingColor = standingColor,
                sortValue = fData.reputation + (fData.isParagon and (fData.paraVal or 0) or 0),
                isCurrent = charKey == currentChar,
            })
        end
    end
    table.sort(results, function(a, b) return a.sortValue > b.sortValue end)
    local maxChars = mod.gdb.crossCharMax or 5
    if #results > maxChars then
        -- Preserve the current character even if outside top N
        local currentEntry
        for i = maxChars + 1, #results do
            if results[i].isCurrent then
                currentEntry = results[i]
            end
        end
        for i = #results, maxChars + 1, -1 do
            results[i] = nil
        end
        if currentEntry then
            results[maxChars + 1] = currentEntry
        end
    end
    return results
end

function mod:GetDate(delta)
    local dt = date("*t", time()-(delta or 0))
    return dt.year * 10000 + dt.month * 100 + dt.day
end

function mod:ReputationLevelDetails(faction)
    local reputation, standingId, friendId = faction.reputation, faction.standingId, faction.friendId
    local sc, color, rep, title, colorId
    rep = reputation - faction.bottomValue
    if faction.isRenown then
        title = faction.renownTitle
        colorId = mod.colorIds.renown
    elseif friendId then
        title = faction.friendTextLevel
        colorId = mod.colorIds.friendly
    else
        title = mod.repTitles[standingId]
        colorId = standingId
    end
    sc = mod.gdb.colors[colorId]
    if mod.gdb.colorFactions then
        color = fmt("%02x%02x%02x", floor(sc.r*255), floor(sc.g*255), floor(sc.b*255))
    else
        color = "ffffff"
    end
    return color, rep, title, colorId
end

function mod:GetGainsSummary(id)
    local today = mod:GetDate()
    local newlyCalculated = false
    local fc = mod.factionGainsCache[today]
    if not fc then
        -- Either we changed day, in which case we need to recalculate
        -- or it's new and it doesn't matter
        mod.factionGainsCache = deepDel(mod.factionGainsCache) or new()
        mod.factionGainsCache[today] = new()
        fc = mod.factionGainsCache[today]
    end
    if not fc[id] then
        newlyCalculated = true
        local todayDate = mod:GetDate()
        local yesterdayDate = mod:GetDate(86400)
        -- Use global history for warbound factions, character history otherwise
        local isWarbound = mod.factionIdToIdx and mod.factionIdToIdx[id]
            and mod.allFactions[mod.factionIdToIdx[id]]
            and mod.allFactions[mod.factionIdToIdx[id]].isAccountWide
        local fh = isWarbound and mod.gdb.globalFactionHistory or mod.cdb.factionHistory
        local todayChange = fh[todayDate] and fh[todayDate][id] or 0
        local yesterdayChange = fh[yesterdayDate] and fh[yesterdayDate][id] or 0
        local weekChange = (todayChange or 0) + (yesterdayChange or 0)
        for day = 2,6 do
            local dayChange = fh[mod:GetDate(day*86400)] -- going back in time
            if dayChange and dayChange[id] then
                weekChange = weekChange + dayChange[id]
            end
        end
        local monthChange = weekChange
        for day = 7, 29 do
            local dayChange = fh[mod:GetDate(day*86400)] -- going back in time
            if dayChange and dayChange[id] then
                monthChange = monthChange + dayChange[id]
            end
        end
        fc[id] = newHash("today", todayChange,
                "yesterday", yesterdayChange,
                "week", weekChange,
                "month", monthChange,
                "changed", todayChange ~= 0 or yesterdayChange ~= 0
                        or weekChange ~= 0 or monthChange ~= 0)
    end
    return fc[id], newlyCalculated
end

---------------------------------------------------
-- LDB Display and display utility methods

local function _addIndentedCell(tooltip, icon, text, indentation, font, func, arg)
    local y, x = tooltip:AddLine(icon)
    tooltip:SetCell(y, 2, text, font or tooltip:GetFont(), "LEFT", 1, nil, indentation)
    if func then
        tooltip:SetLineScript(y, "OnMouseUp", func, arg)
    end
    return y, x
end

local function c(text, color)
    text = text or ""
    return fmt("|cff%s%s|r", color, text)
end
local function delta(number, zero)
    if not number or (not zero and number == 0) then
        return ""
    end
    if number < 0 then
        return fmt("|cffff2020%d|r", number)
    elseif number > 0 then
	return fmt("|cff00ef9a+%d|r", number)
    else
        return "|cffcfcfcf0|r"
    end
end

local function _plusminus(folded)
    return fmt("|TInterface\\Buttons\\UI-%sButton-Up:18|t", folded and "Plus" or "Minus")
end

local function _showFactionInfoTooltip(frame, faction)
    if mod.gdb.showTooltips then
        local tooltip = QTIP:Acquire("SexyRepFactionTooltip")
        if faction.hasRep or (faction.desc and faction.desc ~= '') then
            local y
            tooltip:SetColumnLayout(faction.hasRep and 2 or 1, "LEFT", "RIGHT")
            tooltip:Clear()
            local header = faction.name
            if faction.friendRank and faction.friendMaxRank then
                header = fmt("%s (%d / %d)", header, faction.friendRank, faction.friendMaxRank)
            end
            tooltip:AddHeader(c(header, "ffd200"))
            if faction.desc and faction.desc ~= '' then
                tooltip:SetCell((tooltip:AddLine()), 1, faction.desc, tooltip:GetFont(), "LEFT", 1, nil, nil, 0, 300, 100)
                tooltip:AddLine(" ")
            end
            if faction.friendshipText and faction.friendshipText ~= '' then
                tooltip:SetCell((tooltip:AddLine()), 1, faction.friendshipText, tooltip:GetFont(), "LEFT", 1, nil, nil, 0, 300, 100)
                tooltip:AddLine(" ")
            end
            if faction.isRenown then
                local renownText = faction.renownTitle
                if faction.maxRenownLevels and faction.renownLevel < faction.maxRenownLevels then
                    renownText = fmt("%s / %d", renownText, faction.maxRenownLevels)
                end
                tooltip:SetCell((tooltip:AddLine()), 1, renownText, tooltip:GetFont(), "LEFT", 1, nil, nil, 0, 300, 50)
                tooltip:AddLine(" ")
            end
            if faction.isAccountWide then
                tooltip:AddLine(c(L["Warbound"], "00ccff"))
                tooltip:AddLine(" ")
            end
            if faction.hasRep then
                -- Show recent reputtion history
                local sessionChange = mod.sessionFactionChanges[faction.id] or 0
                local gs = mod:GetGainsSummary(faction.id)
                y = tooltip:AddHeader()
                if sessionChange ~= 0 or gs.changed then
                    tooltip:SetCell(y, 1, c(L["Recent reputation changes"], "ffd200"))
                    tooltip:AddSeparator(1)
                    tooltip:AddLine(L["Session"], delta(sessionChange, true))
                    tooltip:AddLine(L["Today"], delta(gs.today, true))
                    tooltip:AddLine(L["Yesterday"], delta(gs.yesterday, true))
                    tooltip:AddLine(L["Last Week"], delta(gs.week, true))
                    tooltip:AddLine(L["Last Month"], delta(gs.month, true))

                    local color, rep, repTitle = mod:ReputationLevelDetails(faction)
                    if not faction.friendId then
                        local remaining =
                            (faction.isParagon and (faction.paraThresh - faction.paraVal % faction.paraThresh))
                            or (faction.isRenown and ((faction.topValue - faction.bottomValue)* (faction.maxRenownLevels-1) - faction.reputation))
                            or (42999 - faction.bottomValue - rep)
                        if remaining > 0 then
                            tooltip:AddLine(L["Remaining"], remaining)
                        end
                        local repetitions
                        if gs.today > 0 then
                            repetitions = remaining/gs.today
                        elseif gs.yesterday > 0 then
                            repetitions = remaining/gs.yesterday
                        end
                        if repetitions then
                            tooltip:AddLine(L["Repetitions"], string.format("%.2f", repetitions))
                        end
                    end
                else
                    tooltip:SetColumnLayout(1, "LEFT")
                    tooltip:SetCell(y, 1, c(L["Recent reputation changes"], "ffd200"))
                    tooltip:AddSeparator(1)
                    y = tooltip:AddLine(L["No changes recorded in the last 30 days."])
                end
            end

            -- Cross-character standings
            if mod.gdb.showCrossCharRep and not faction.isAccountWide and faction.hasRep then
                local crossChars = mod:GetCrossCharRepForFaction(faction.id)
                if #crossChars > 0 then
                    tooltip:AddLine(" ")
                    y = tooltip:AddHeader()
                    tooltip:SetCell(y, 1, c(L["Other Characters"], "ffd200"))
                    tooltip:AddSeparator(1)
                    for _, entry in ipairs(crossChars) do
                        local nameText = fmt("|c%s%s|r", entry.colorHex, entry.name)
                        if entry.isCurrent then
                            nameText = "> " .. nameText
                        end
                        tooltip:AddLine(
                            nameText,
                            c(entry.repText, entry.standingColor)
                        )
                    end
                end
            end

            if mod.cdb.watchedFaction == faction.id then
                tooltip:AddLine(" ")
                tooltip:AddSeparator(1)
                tooltip:AddLine(c(L["This faction is currently being tracked."], "ffff00"))
            end
            tooltip:SetPoint("TOPLEFT", frame, "TOPRIGHT", 10, 0)
            tooltip:SetFrameLevel(frame:GetFrameLevel()+1)
            tooltip:SetClampedToScreen(true)
            tooltip:Show()
            tooltip:SetAutoHideDelay(0.25, frame)
        else
            QTIP:Release(tooltip)
        end
    end
end

local function _factionOnClick(frame, faction, button)
    if button == "LeftButton" then
        if IsAltKeyDown() then
            if faction.hasRep then
                if mod.cdb.watchedFaction == faction.id then
                    mod.cdb.watchedFaction = nil
                else
                    mod.cdb.watchedFaction = faction.id
                end
                mod:UpdateLDBText()
            end
        elseif IsControlKeyDown() and IsShiftKeyDown() then
            mod:ScanFactions(faction.id)
        elseif faction.isHeader then
            -- Use composite key: factionID_name to handle duplicate faction IDs
            local foldKey = faction.id .. "_" .. faction.name
            mod.cdb.hf[foldKey] = not mod.cdb.hf[foldKey] or nil
        end
    end
    ldb.OnEnter() -- redraw
end

function ldb.OnEnter(frame)
    tooltip = QTIP:Acquire("SexyRepTooltip")
    tooltip:EnableMouse(true)

    local numCols = 2

    local showRep = mod.gdb.repTextStyle ~= mod.TEXT_STYLE_STANDING and mod.gdb.repStyle == mod.STYLE_TEXT
    local showStanding = mod.gdb.repTextStyle ~= mod.TEXT_STYLE_REPUTATION and mod.gdb.repStyle == mod.STYLE_TEXT
    local showRepBar = mod.gdb.repStyle == mod.STYLE_BAR
    local showPercentage = mod.gdb.showPercentage
    local showGains = mod.gdb.showGains
    local colorFactions = mod.gdb.colorFactions

    if showRepBar then
        numCols = numCols + 1
    else
        if showRep then numCols = numCols + 3 end
        if showStanding then numCols = numCols + 1 end
    end
    if showPercentage then numCols = numCols + 1 end
    if showGains then numCols = numCols + 2 end

    tooltip:Clear()
    tooltip:SetColumnLayout(numCols, "LEFT")

    if frame then
        tooltip:SetAutoHideDelay(0.5, frame)
    end

    if not mod.allFactions or not #mod.allFactions then
        mod:ScanFactions()
    end

    local y, x

    y = tooltip:AddHeader("", c(L["Faction"], "ffff00"))
    x = 3
    if showRepBar then
        tooltip:SetCell(y, x, c(L["Standing"], "ffff00"), "CENTER") x = x + 1
    else
        if showStanding then
            tooltip:SetCell(y, x, c(L["Standing"], "ffff00"), "LEFT") x = x + 1
        end
        if showRep then
            tooltip:SetCell(y, x, c(L["Reputation"], "ffff00"), "CENTER", 3) x = x + 3
        end
    end
    if showPercentage then
        tooltip:SetCell(y, x, c("%", "ffff00"), "CENTER") x = x + 1
    end
    if showGains then
        tooltip:SetCell(y, x, c(L["Session"], "ffff00"), "CENTER") x = x + 1
        tooltip:SetCell(y, x, c(L["Today"], "ffff00"), "CENTER") x = x + 1
    end
    tooltip:AddSeparator(1)

    local skipUntilHeader, skipUntilChildHeader
    local isTopLevelHeader, isChildHeader
    local todaysDate = mod:GetDate()
    local showOnlyChanged = mod.gdb.showOnlyChanged
    local hideExalted = mod.gdb.hideExalted
    local showParagon = mod.gdb.showParagon
    local watchedFaction = mod.cdb.watchedFaction
    local gridLines = mod.gdb.gridLines
    local indent, isTopLevelHeader, isChildHeader, sessionChange, today, showRow
    local paraIcon = [[|TInterface\Icons\Inv_legioncircle_paragoncache_argussianreach:16|t]]

    -- Track empty headers to add placeholder rows
    local lastHeaderFaction = nil
    local lastHeaderIndent = 0
    local lastHeaderFolded = false
    local childrenShownForLastHeader = false

    for id, faction in ipairs(mod.allFactions) do
        isTopLevelHeader = faction.isHeader and not faction.isChild
        isChildHeader = faction.isHeader and faction.isChild

        -- Calculate indent early so we can use it in skip logic
        indent = 0
        if faction.isChild then indent = 20 end
        if not faction.isHeader then indent = indent + 20 end

        sessionChange = mod.sessionFactionChanges[faction.id]
        today = mod.cdb.factionHistory[todaysDate] and mod.cdb.factionHistory[todaysDate][faction.id];

        showRow = true
        -- calculate whether this row should be displayed. Split out this way
        -- so it's possible to understand what it's filtering and why

        if skipUntilHeader then
            -- Skip everything until we find another top-level header
            if isTopLevelHeader then
                -- Found next top-level header, stop skipping and show it
                skipUntilHeader = nil
                -- showRow remains true, display this faction
            else
                -- Still inside the folded top-level header, hide this row
                showRow = false
            end
        elseif skipUntilChildHeader then
            -- Skip factions at deeper indentation (indent=40) until we find:
            -- 1. Another header (sibling child header or top-level)
            -- 2. A faction at same or shallower indentation (indent <= 20)
            if isTopLevelHeader or isChildHeader or indent <= 20 then
                -- Found sibling or went back up, stop skipping and show it
                skipUntilChildHeader = nil
                -- showRow remains true, display this faction
            else
                -- Still inside the folded child header (indent=40), hide this row
                showRow = false
            end
        end

        if showOnlyChanged and not (sessionChange or today) then
            showRow = false
        elseif hideExalted and faction.standingId == 8 then
            showRow = faction.isParagon and showParagon
        end
        if showRow then
            -- Check if we need to add placeholder for previous empty header (only if not folded)
            -- Only show placeholder when encountering a sibling or parent-level header, not child headers
            if lastHeaderFaction and not childrenShownForLastHeader and not lastHeaderFolded and faction.isHeader and indent <= lastHeaderIndent then
                y = _addIndentedCell(tooltip, "", c(L["(No visible factions)"], "808080"), lastHeaderIndent + 20, nil, nil, nil)
                if gridLines then
                    tooltip:AddSeparator(0.5, 1, 1, 1, 0.5)
                end
            end

            local title, folded
            if not showOnlyChanged then
                -- Use composite key: factionID_name to handle duplicate faction IDs (like "Inactive")
                local foldKey = faction.id .. "_" .. faction.name
                folded = faction.isHeader and mod.cdb.hf[foldKey]
                local pm = _plusminus(folded)
                title = faction.isHeader and fmt("%s %s", pm, faction.name) or c(faction.name, "ffd200")
            else
                title = faction.isHeader and faction.name or c(faction.name, "ffd200")
            end
            local color, rep, repTitle, colorId = mod:ReputationLevelDetails(faction)
            local font

            local barColor = mod.gdb.colors[colorId]

            local icon = ""
            if watchedFaction == faction.id then
                icon = [[|TInterface\Icons\Spell_Shadow_EvilEye:16|t]]
            end
            y = _addIndentedCell(tooltip, icon, title, indent, font, _factionOnClick, faction)

            tooltip:SetLineScript(y, "OnEnter", _showFactionInfoTooltip, faction)
            tooltip:SetLineScript(y, "OnLeave", nil)

            -- Track headers and their children for empty header detection
            if faction.isHeader then
                lastHeaderFaction = faction
                lastHeaderIndent = indent
                lastHeaderFolded = folded or false
                childrenShownForLastHeader = false
            else
                childrenShownForLastHeader = true
            end

            -- Headers without reputation need empty cells to maintain proper row height
            if faction.isHeader and not faction.hasRep then
                -- Add empty cell spanning remaining columns to give the row proper height
                tooltip:SetCell(y, 3, " ", "LEFT", numCols - 2)
            elseif not faction.isHeader or faction.hasRep then
                x = 3
                local maxValue = faction.topValue-faction.bottomValue

                --Paragon adjustments
                if faction.isParagon then
                    repTitle = L["Paragon"]
                    barColor = {r=0, g=171/255, b=240/255}
                    color = "00ABF0"

                    rep = faction.paraVal % faction.paraThresh
                    maxValue = faction.paraThresh
                end

                if maxValue == 0 then
                    maxValue = 21000 -- Exalted rep has no max value
                    rep = 21000
                end

                -- "RIGHT", "CENTER", "RIGHT", "RIGHT")
                if showStanding then
                    if faction.paraRewardPending then
                        tooltip:SetCell(y, x, paraIcon, "CENTER")
                    else
                        tooltip:SetCell(y, x, c(repTitle, color), "LEFT")
                    end
                    x = x + 1
                end

                if showRep then
                    tooltip:SetCell(y, x, tostring(rep), "RIGHT") x = x + 1
                    tooltip:SetCell(y, x, "/", "CENTER") x = x + 1
                    tooltip:SetCell(y, x, tostring(maxValue), "RIGHT") x = x + 1
                end
                if showRepBar then

                    if faction.paraRewardPending then
                        tooltip:SetCell(y, x, paraIcon, "CENTER")
                    else
                        tooltip:SetCell(y, x, repTitle, "CENTER", mod.barProvider, barColor, rep, maxValue, 120, 14)
                        local xx, yy = x, y

                        tooltip:SetLineScript(y, "OnEnter", function(frame, factionid)
                            local idx = mod.factionIdToIdx[factionid]
                            local faction
                            if idx then
                                local faction = mod.allFactions[idx]
                                if faction then
                                    tooltip:SetCell(yy, xx, fmt("%d / %d", rep, maxValue), "CENTER", mod.barProvider, barColor, rep, maxValue, 120, 12)

                                    _showFactionInfoTooltip(frame, faction)
                                end
                            end
                        end, faction.id)
                        tooltip:SetLineScript(y, "OnLeave", function(frame, factionid)
                            local idx = mod.factionIdToIdx[factionid]
                            if idx then
                                local faction = mod.allFactions[idx]
                                if faction then
                                    -- Breaks encapsulation but.. otherwise it breaks the code
                                    local lines = tooltip.lines and tooltip.lines[yy]
                                    if lines and lines.cells and lines.cells[xx] then
                                        tooltip:SetCell(yy, xx, repTitle, "CENTER", mod.barProvider, barColor, rep, maxValue, 120, 12)
                                    end
                                end
                            end
                        end, faction.id)
                    end

                    x = x + 1
                end
                if showPercentage then
                    tooltip:SetCell(y, x, fmt("%.0f%%", (100.0*rep / maxValue)), "RIGHT") x = x + 1
                end
                if showGains then
                    tooltip:SetCell(y, x, delta(sessionChange), "CENTER") x = x + 1
                    tooltip:SetCell(y, x, delta(today), "CENTER") x = x + 1
                end
                if (sessionChange or today) and colorFactions and not showOnlyChanged then
                    tooltip:SetLineColor(y, 1, 1, 1, 0.2)
                end
                if gridLines then
                    tooltip:AddSeparator(0.5, 1, 1, 1, 0.5)
                end
            end
            if folded then
                if faction.isChild then
                    skipUntilChildHeader = true
                    skipUntilHeader = nil
                else
                    skipUntilChildHeader = nil
                    skipUntilHeader = true
                end
            end
        end
    end

    -- Check if last header needs placeholder (only if not folded)
    if lastHeaderFaction and not childrenShownForLastHeader and not lastHeaderFolded then
        y = _addIndentedCell(tooltip, "", c(L["(No visible factions)"], "808080"), lastHeaderIndent + 20, nil, nil, nil)
        if gridLines then
            tooltip:AddSeparator(0.5, 1, 1, 1, 0.5)
        end
    end

    tooltip:AddLine(" ")
    tooltip:AddSeparator(1)
    y = tooltip:AddLine()
    tooltip:SetCell(y, 1, c(L["Using the faction tooltip:"], "ffff00"), "LEFT", numCols)
    y = tooltip:AddLine("")
    tooltip:SetCell(y, 2, c(L["Click:"], "eda55f") .. " "..c(L["Fold / unfold faction headers."], "ffd200"), "LEFT", numCols-1)
    y = tooltip:AddLine("")
    tooltip:SetCell(y, 2, c(L["Alt-Click:"], "eda55f").. " "..c(L["Toggle faction tracking state on and off."], "ffd200"), "LEFT", numCols-1)
    y = tooltip:AddLine("")
    tooltip:SetCell(y, 2, c(L["Shift+Ctrl-Click:"], "eda55f").. " "..c(L["Toggle faction inactive state."], "ffd200"), "LEFT", numCols-1)

    if frame then
        tooltip:SmartAnchorTo(frame)
    end
    tooltip:SetScrollStep(100)
    tooltip:UpdateScrolling(mod.gdb.maxHeight)
    tooltip:Show()
end

function ldb.OnClick(frame, button)
    if button == "LeftButton" then
        --mod:ToggleConfigDialog()
    elseif button == "RightButton" then
        -- First hide the tooltip
        local tooltip = QTIP:Acquire("SexyRepTooltip")
        QTIP:Release(tooltip)

        local menu = LD:OpenAce3Menu(mod.options)
        menu:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 0)
        menu:SetFrameLevel(frame:GetFrameLevel() + 50)
        menu:SetClampedToScreen(true)
    end
end

function ldb.OnLeave(frame)
    --   if ldb.tooltip then
    --      QTIP:Release(ldb.tooltip)
    --      ldb.tooltip = nil
    --   end
end

function mod:UpdateLDBText()
    local text = ""
    local gdb = mod.gdb
    if not mod.cdb.watchedFaction then
        ldb.text = L["Factions"]
        return
    end

    if not mod.allFactions then
        mod:ScanFactions()
    end
    local idx = mod.factionIdToIdx[mod.cdb.watchedFaction]
    local faction =  mod.allFactions[idx]
    if not faction then
        ldb.text = L["Factions"]
        return
    end

    local fields = new()

    if gdb.trackName then
        fields[1] = faction.name
    end

    local color, rep, repTitle = mod:ReputationLevelDetails(faction)
    local maxValue = faction.topValue - faction.bottomValue

    if faction.isParagon then
        repTitle = "Paragon"
        color = "00ABF0"

        rep = faction.paraVal % faction.paraThresh
        maxValue = faction.paraThresh
    end

    if maxValue == 0 then
        maxValue = 21000 -- Exalted rep has no max value
        rep = 21000
    end


    if gdb.trackStanding then
        fields[#fields+1] = c(repTitle, color)
    end

    if gdb.trackRep then
        fields[#fields+1] = fmt("%d/%d", rep, maxValue)
    end

    if gdb.trackPercentage then
        fields[#fields+1] = fmt("|cffffd200%.1f%%|r", 100.0 * rep / maxValue)
    end

    if gdb.trackGains and mod.sessionFactionChanges[faction.id] then
        fields[#fields+1] = delta(mod.sessionFactionChanges[faction.id], true)
    end

    ldb.text = tconcat(fields, " - ")
    local hasParagonChest = false
    for idx = 1, 500 do
        local factionData = RepCompat.GetFactionDataByIndex(idx)
        if not factionData then break end
        local factionId = factionData.factionID
        if factionId and RepCompat.IsFactionParagon(factionId) then
            hasParagonChest = select(4, RepCompat.GetFactionParagonInfo(factionId)) or hasParagonChest
            if hasParagonChest then
                break
            end
        end
    end
    ldb.icon = (hasParagonChest and [[Interface\Icons\Inv_legioncircle_paragoncache_argussianreach]])
            or ((UnitFactionGroup("player") == "Horde" and
            [[Interface\Addons\SexyReputation\hordeicon]] or
            [[Interface\Addons\SexyReputation\allianceicon]]));
end

-----------------------
--- EVENT HANDLING
do
    local factionScanTimer
    function ScheduleFactionScan()
        if factionScanTimer then
            mod:CancelTimer(factionScanTimer, true)
        end

        factionScanTimer = mod:ScheduleTimer("ScanForFactionChanges", 1)
    end

    function mod:COMBAT_TEXT_UPDATE(event, type, faction, amount)
        if type == "FACTION" then
            ScheduleFactionScan()
        end
    end

    function mod:QUEST_TURNED_IN(event, questID, xp, money)
        --rescan for paragon status change
        ScheduleFactionScan()
    end

    function mod:ScanForFactionChanges()
        local previousFactionData = mod.allFactions
        factionScanTimer = nil
        mod.allFactions = nil
        mod:ScanFactions()

        if not previousFactionData then return end -- can't do anything, had no data before

        local date = mod:GetDate()

        local charToday = mod.cdb.factionHistory[date] or new()
        mod.cdb.factionHistory[date] = charToday

        local globalToday = mod.gdb.globalFactionHistory[date] or {}
        mod.gdb.globalFactionHistory[date] = globalToday

        for _,faction in ipairs(previousFactionData) do
            local idx = mod.factionIdToIdx[faction.id] -- required since faction orders might have changed
            if idx then
                local newFaction = mod.allFactions[idx]
                if newFaction.reputation ~= faction.reputation or
                        (newFaction.isParagon and newFaction.paraVal ~= faction.paraVal)
                then
                    -- Rep change occurred
                    local paraAmount = newFaction.isParagon and (newFaction.paraVal - faction.paraVal) or 0
                    local amount = paraAmount + newFaction.reputation - faction.reputation
                    mod.sessionFactionChanges[faction.id] = (mod.sessionFactionChanges[faction.id] or 0) + amount

                    -- Route to appropriate history table
                    if newFaction.isAccountWide then
                        globalToday[faction.id] = (globalToday[faction.id] or 0) + amount
                    else
                        charToday[faction.id] = (charToday[faction.id] or 0) + amount
                    end

                    -- Update the cached rep changes here, if needed.
                    local gs,upToDate = mod:GetGainsSummary(faction.id)
                    if not upToDate then
                        gs.changed = true
                        gs.today = gs.today + amount
                        gs.week  = gs.week + amount
                        gs.month = gs.month + amount
                    end
                end
            end
        end
        mod:UpdateLDBText()
        deepDel(previousFactionData)
    end
end


-- Set up a custom provider for the bars
local barProvider, barCellPrototype = QTIP:CreateCellProvider()
mod.barProvider = barProvider

function barCellPrototype:InitializeCell()
    self.bar = BAR:NewSimpleBar(self, 0, 0, 100, 10, BAR.LEFT_TO_RIGHT)
    self.bar:SetAllPoints(self)
    self.fontString = self.bar:CreateFontString()
    self.fontString:SetAllPoints(self.bar)
    self.fontString:SetFontObject(GameTooltipText)
    self.fontString:SetJustifyV("MIDDLE")
end

function barCellPrototype:SetupCell(tooltip, value, justification, font, color, rep, maxRep, width, height)
    local fs = self.fontString
    fs:SetFontObject(font or tooltip:GetFont())
    fs:SetJustifyH(justification)
    fs:SetText(tostring(value))
    fs:Show()

    self.bar:SetValue(rep, maxRep)
    self.bar:SetBackgroundColor(0, 0, 0, 0.4)
    self.bar:SetColor(color.r, color.g, color.b, 0.8)
    if width then
        self.bar:SetLength(width)
    end
    if height then
        self.bar:SetThickness(height)
    end
    self.bar.spark:Hide()
    self:SetWidth(width)
    return width, height
end

function barCellPrototype:getContentHeight()
    return self.bar:GetHeight()
end

function barCellPrototype:ReleaseCell()
    self.r, self.g, self.b = 1, 1, 1
end

