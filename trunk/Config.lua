local mod = LibStub("AceAddon-3.0"):GetAddon("Sexy Reputations")
local L = LibStub("AceLocale-3.0"):GetLocale("SexyReputation", false)
local R = LibStub("AceConfigRegistry-3.0")
local C = LibStub("AceConfigDialog-3.0")
local DBOpt = LibStub("AceDBOptions-3.0")

function mod:SetProfileParam(var, value)
   local varName = var[#var]
   mod.db.global[varName] = value
end

function mod:GetProfileParam(var) 
   local varName = var[#var]
   return mod.db.global[varName]
end

mod.defaults = {
   char = {
      factionHistory = {}, -- the gains of faction, per day
      hf = {}
   },
   global = {
      factionLookup = {},
      colorFactions = true,
      showStanding = true,
      showRep = true,
      showPercentage = true,
      showTooltips = true,
      showOnlyChanged = false,
      showGains = true,
   }
}

mod.options = {
   type = "group",
   name = L["Sexy Reputations"],
   handler = mod,
   set = "SetProfileParam",
   get = "GetProfileParam",
   args = {
      colorFactions = {
	 type = "toggle",
	 name = L["Standing Color"],
	 desc = L["Color fields based on your standing with the different factions."], 
      },
      showStanding = {
	 type = "toggle",
	 name = L["Show Standing"],
	 desc = L["Show the faction standing text, i.e Hated, Neutral etc."], 
	    },
      showRep = {
	 type = "toggle",
	 name = L["Show Reputation"],
	 desc = L["Show reputation values, ie 4543 / 12000."], 
      },
      showPercentage = {
	 type = "toggle",
	 name = L["Show Percentage"],
	 desc = L["Show your rep as a percentage of the reputation standing (i.e Neutral 1500/3000 = 50%)"], 
      },
      showGains = {
	 type = "toggle",
	 name = L["Show Gains"],
	 desc = L["Show reputation gained or lost in the session and today."],
      },
      showOnlyChanged = {
	 type = "toggle",
	 name = L["Show Changes Only"],
	 desc = L["Only show factions that have had reputation changes in the past 30 days."],
      },
   }
}
