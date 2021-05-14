local  _, CLM = ...

local LOG = CLM.LOG

local MODULES =  CLM.MODULES
local CONSTANTS = CLM.CONSTANTS
local UTILS = CLM.UTILS
local MODELS = CLM.MODELS

-- local ACL_LEVEL = CONSTANTS.ACL.LEVEL

local ACL = MODULES.ACL
local LedgerManager = MODULES.LedgerManager
local RosterManager = MODULES.RosterManager
-- local ProfileManager = MODULES.ProfileManager
local Comms = MODULES.Comms

-- local LEDGER_DKP = MODELS.LEDGER.DKP
-- local Profile = MODELS.Profile
local Roster = MODELS.Roster
-- local PointHistory = MODELS.PointHistory

local typeof = UTILS.typeof
-- local getGuidFromInteger = UTILS.getGuidFromInteger

local RAID_COMM_PREFIX = "raid"
local RAID_COMMS_INIT = "i"
local RAID_COMMS_END = "e"
local RAID_COMMS_REQUEST_REINIT = "r"


local RaidManager = {}

function RaidManager:Initialize()
    LOG:Trace("RaidManager:Initialize()")
    self.status = MODULES.Database:Raid()
    if not self:IsRaidInProgress() then
        LOG:Debug("No raid in Progress")
        -- We dont have any inProgress information stored or it's false (raid is not in progress)
        self:ClearRaidInfo()
    else
        -- Raid in progress -> we had a /reload or disconnect and user was ML
        -- Check if user logged back when raid was still in progress
        -- if IsInRaid() then
        if true then
            LOG:Debug("Raid in Progress")
            -- We need to handle the stored info
            self.restoreRaid = true
        else
            -- Clear status
            self:ClearRaidInfo()
        end
    end

    Comms:Register(RAID_COMM_PREFIX, (function(message, distribution, sender)
        if distribution ~= CONSTANTS.COMMS.DISTRIBUTION.RAID then return end
        self:HandleIncomingMessage(message, sender)
    end), CONSTANTS.ACL.LEVEL.MANAGER)

    LedgerManager:RegisterOnUpdate(function(lag, uncommitted)
        if lag == 0 and uncommitted == 0 then
            if self.restoreRaid then
                self:RestoreRaidInfo()
                self.restoreRaid = false
            end
        end
    end)

    self._initialized = true
end

function RaidManager:IsRaidInProgress()
    return self.status and (self.status.inProgress or self.status.inProgressExternal)
end

function RaidManager:InitializeRaid(roster)
    LOG:Trace("RaidManager:InitializeRaid()")
    if not typeof(roster, Roster) then
        LOG:Error("RaidManager:InitializeRaid(): Missing valid roster")
        return
    end
    if not ACL:CheckLevel(CONSTANTS.ACL.LEVEL.MANAGER) then
        LOG:Message("You are not allowed to initialize a raid.")
        return
    end
    -- @non-debug@
    -- if not IsInRaid() then
    --     LOG:Message("You are not in raid.")
    --     return
    -- end
    -- @end-non-debug@
    if self:IsRaidInProgress() then
        LOG:Message("Raid is already in progress.")
        return
    end
    -- is RL / ML -> check the loot system ? -- do we need it? maybe everyone can be?
    self.status.time.raidStart = GetServerTime()
    self.status.roster = roster:UID()
    self.roster = roster

    self.status.inProgress = true
    -- Handle ontime bonus
    -- Send comms
    Comms:Send(RAID_COMM_PREFIX, RAID_COMMS_INIT, CONSTANTS.COMMS.DISTRIBUTION.RAID)
    -- Handle internal
    SendChatMessage("Raid started" , "RAID_WARNING")
    self:HandleRaidInitialization(UTILS.whoami())
end

function RaidManager:EndRaid()
    LOG:Trace("RaidManager:EndRaid()")
    if self:IsRaidInProgress() then -- implies being in raid in release version
        -- Handle raid completion bonus
        --
        -- Send comms
        Comms:Send(RAID_COMM_PREFIX, RAID_COMMS_END, CONSTANTS.COMMS.DISTRIBUTION.RAID)
        -- Handle end of raid
        SendChatMessage("Raid ended" , "RAID_WARNING")
        self:HandleRaidEnd(UTILS.whoami())
        self:ClearRaidInfo()
    end
end

function RaidManager:MarkAsAuctioneer(name)
    LOG:Trace("RaidManager:MarkAsAuctioneer()")
    MODULES.AuctionManager:MarkAsAuctioneer(name)
end

function RaidManager:ClearAuctioneer()
    LOG:Trace("RaidManager:ClearAuctioneer()")
    MODULES.AuctionManager:ClearAuctioneer()
end

function RaidManager:RestoreRaidInfo()
    LOG:Trace("RaidManager:RestoreRaidInfo()")
    if self.status.inProgressExternal then
        Comms:Send(RAID_COMM_PREFIX, RAID_COMMS_REQUEST_REINIT, CONSTANTS.COMMS.DISTRIBUTION.RAID)
    else
        -- restore roster
        self.roster = RosterManager:GetRosterByUid(self.status.roster)
        LOG:Message("%s", tostring(self.roster))
        -- pass info to auction manager
        self:HandleRaidInitialization(UTILS.whoami())
        -- check if we have some pending auto awards to do
    end
end

function RaidManager:ClearRaidInfo()
    LOG:Trace("RaidManager:ClearRaidInfo()")
    -- Do not do self.status = {} as we are referencing here directly to DB and that would break the reference
    self.status.inProgress = false
    self.status.inProgressExternal = false
    self.status.roster = 0
    self.status.time = {
        raidStart = 0,
        awardInterval = 0,
        lastAwardTime = 0 -- for unfortunate reloads during award time
    }
    self.status.loot = {
        isPlayerMasterLooter = false,
        masterLooter = "",
        lootSystem = ""
    }
    self.status.points = {
        awardIntervalBonus = false,
        awardBossKillBonus = false
    }
end

function RaidManager:GetRoster()
    return self.roster
end

function RaidManager:GetRosterUid()
    return self.status.roster
end

function RaidManager:HandleRaidInitialization(auctioneer)
    if not self:IsRaidInProgress() then
        LOG:Message("Raid started by %s", UTILS.ColorCodeText(auctioneer, "FFD100"))
    end
    self.status.inProgressExternal = true
    -- We allow overwriting just in case
    self:MarkAsAuctioneer(auctioneer)
end

function RaidManager:HandleRaidEnd(auctioneer)
    if self:IsRaidInProgress() then
        LOG:Message("Raid ended by %s", UTILS.ColorCodeText(auctioneer, "FFD100"))
    end
    self.status.inProgressExternal = false
    self:ClearAuctioneer()
end

function RaidManager:HandleRequestReinit(sender)
    -- I am the raid initiator as my status inprogress is not external
    if self:IsRaidInProgress() and not self.status.inProgressExternal then
        Comms:Send(RAID_COMM_PREFIX, RAID_COMMS_INIT, CONSTANTS.COMMS.DISTRIBUTION.RAID)
    end
end

function RaidManager:HandleIncomingMessage(message, sender)
    if type(message) ~= "string" then
        LOG:Debug("RaidManager:HandleIncomingMessage(): Received unsupported message type")
        return
    end

    if message == RAID_COMMS_INIT then
        self:HandleRaidInitialization(sender)
    elseif message == RAID_COMMS_END then
        self:HandleRaidEnd(sender)
    elseif message == RAID_COMMS_REQUEST_REINIT then
        self:HandleRequestReinit(sender)
    else
        LOG:Debug("RaidManager:HandleIncomingMessage(): Received unsupported message %s", tostring(message))
    end
end

MODULES.RaidManager = RaidManager