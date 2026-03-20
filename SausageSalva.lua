-- ============================================================================
-- SAUSAGE SALVA - Paladin Threat & Salvation Coordinator (Pro Grid Edition)
-- Author: Sausage Party / Kokotiar
-- ============================================================================

local addonName, addonTable = ...
local SAUSAGE_VERSION = "v1.0.0" -- SEM SCRIPT DOPLNI VERZIU PODLA TAGU
local PREFIX = "SSALVA"
local SALVA_SPELL_ID = 1038 -- Hand of Salvation
local MISDIRECT_SPELL_ID = 34477 -- Misdirection
local TRICKS_SPELL_ID = 57934 -- Tricks of the Trade

local SALVA_NAME = GetSpellInfo(SALVA_SPELL_ID)
local MISDIRECT_NAME = GetSpellInfo(MISDIRECT_SPELL_ID)
local TRICKS_NAME = GetSpellInfo(TRICKS_SPELL_ID)

local defaultDB = {
    autoHide = false,
    isShown = true,
    anchor = "TOP",
    frameX = nil,
    frameY = nil,
    btnWidth = 75,
    btnHeight = 35,
    cols = 5,
    spacing = 2,
    hideBorder = false,
    hideHeader = false,
    hideNames = false,
    hideThreat = false,
    showListPala = {},
    showListHunt = {},
    showListRogue = {},
    showListMaster = {},
    enableSound = true,
    hideBackground = false
}

local inCombat = false
local isTestMode = false
local unitButtons = {}
local activePaladins = {}
local currentTab = 1
local focusTarget = nil
local focusTimer = 0
local focusTargetClass = nil -- Zaznamenáva, aká classa bola priradená (pre farbu pulzu)
local preCastTarget = nil
local preCastTimer = 0
local rangeFailTracker = {}

-- [[ PRED-DEKLARÁCIE ]]
local EventFrame = CreateFrame("Frame")
local SausageSalvaMainFrame_UpdateGrid
local UpdateCombatGrid
local SortPaladins
local UpdateIgnoreScrollFrame
local BroadcastStatus
local HandleRadialClick

local playerClassOrig = select(2, UnitClass("player"))
local debugClass = nil
local debugLeader = false

local isPaladin, isHunter, isRogue, isCoordClass
local mySpellName, mySoundPath

-- [[ UTILITY FUNKCIE ]]
local function UpdateAddonIdentity()
    local currentClass = debugClass or playerClassOrig
    isPaladin = (currentClass == "PALADIN")
    isHunter = (currentClass == "HUNTER")
    isRogue = (currentClass == "ROGUE")
    isCoordClass = isPaladin or isHunter or isRogue
    
    SALVA_NAME = SALVA_NAME or GetSpellInfo(SALVA_SPELL_ID)
    MISDIRECT_NAME = MISDIRECT_NAME or GetSpellInfo(MISDIRECT_SPELL_ID)
    TRICKS_NAME = TRICKS_NAME or GetSpellInfo(TRICKS_SPELL_ID)
    
    mySpellName = (isPaladin and SALVA_NAME) or (isHunter and MISDIRECT_NAME) or (isRogue and TRICKS_NAME) or nil
    
    local soundFile = (isPaladin and "salvation.wav") or (isHunter and "misdirection.wav") or (isRogue and "tricksoftrade.wav")
    if soundFile then
        mySoundPath = "Interface\\AddOns\\SausageSalva\\sound\\" .. soundFile
    else
        mySoundPath = nil
    end
end
UpdateAddonIdentity()

local function IsRaidLeader()
    if debugLeader then return true end
    return (GetNumRaidMembers() > 0 and IsRaidLeader_Orig()) or (GetNumPartyMembers() > 0 and not (GetNumRaidMembers() > 0) and IsPartyLeader())
end

local function IsRaidOfficer()
    if debugLeader then return true end
    if GetNumRaidMembers() > 0 then
        local _, rank = GetRaidRosterInfo(UnitInRaid("player"))
        return rank >= 1
    end
    return false
end

local IsRaidLeader_Orig = IsRaidLeader
local function IsInRaid() return GetNumRaidMembers() > 0 end
local function IsInGroup() return GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0 end

local function GetPaladinSpec()
    if not isPaladin then return 0 end
    local highestPoints, spec = -1, 1
    for i = 1, 3 do
        local _, _, points = GetTalentTabInfo(i)
        if points and points > highestPoints then
            highestPoints, spec = points, i
        end
    end
    return spec
end

local function SendComm(msg)
    if not IsInGroup() then return end
    local channel = IsInRaid() and "RAID" or "PARTY"
    if select(2, IsInInstance()) == "pvp" then channel = "BATTLEGROUND" end
    SendAddonMessage(PREFIX, msg, channel)
end

local function GetUnitByName(name)
    if name == UnitName("player") then return "player" end
    if name == UnitName("target") then return "target" end
    if name == UnitName("focus") then return "focus" end
    if IsInRaid() then
        for i=1, GetNumRaidMembers() do
            if UnitName("raid"..i) == name then return "raid"..i end
        end
    elseif IsInGroup() then
        for i=1, GetNumPartyMembers() do
            if UnitName("party"..i) == name then return "party"..i end
        end
    end
    return nil
end

-- [[ LOGIKA ZÁZNAMOV A COOLDOWNOV ]]
local function CleanupPaladinList()
    local changed = false
    for i = #activePaladins, 1, -1 do
        local name = activePaladins[i].name
        if not UnitInRaid(name) and not UnitInParty(name) then
            table.remove(activePaladins, i)
            changed = true
        end
    end
    return changed
end

-- Explicitná definícia
SortPaladins = function()
    CleanupPaladinList()
    table.sort(activePaladins, function(a, b) return a.spec < b.spec end)
    
    local palas, hunts, rogues = {}, {}, {}
    for _, p in ipairs(activePaladins) do
        local color = "|cFFFFFFFF"
        if p.spec == 1 then color = "|cFFFFFF00" -- Holy
        elseif p.spec == 2 then color = "|cFFFF8800" -- Prot
        elseif p.spec == 3 then color = "|cFFFF0000" -- Ret
        elseif p.spec == 4 then color = "|cFFABD473" -- Hunter
        elseif p.spec == 5 then color = "|cFFFFF569" -- Rogue
        end
        local entry = color .. p.name .. "|r"
        if p.spec <= 3 then table.insert(palas, entry)
        elseif p.spec == 4 then table.insert(hunts, entry)
        elseif p.spec == 5 then table.insert(rogues, entry)
        end
    end

    if SausageSalvaMainFrame_UpdateGrid then
        SausageSalvaCoordPala.text:SetText(#palas > 0 and table.concat(palas, ", ") or "|cFF888888None|r")
        SausageSalvaCoordHunt.text:SetText(#hunts > 0 and table.concat(hunts, ", ") or "|cFF888888None|r")
        SausageSalvaCoordRogue.text:SetText(#rogues > 0 and table.concat(rogues, ", ") or "|cFF888888None|r")
    end
end

-- Bezpečná funkcia na broadcast statusu
BroadcastStatus = function()
    if not isCoordClass then return end
    local spell = (isPaladin and SALVA_NAME) or (isHunter and MISDIRECT_NAME) or (isRogue and TRICKS_NAME)
    if not spell then return end
    
    local start, duration = GetSpellCooldown(spell)
    local isReady = 0
    -- Poistka proti "attempt to compare nil with number"
    if start and duration then
        isReady = (start == 0 or duration <= 1.5) and 1 or 0
    end

    local spec = 1
    if isPaladin then spec = GetPaladinSpec() elseif isHunter then spec = 4 elseif isRogue then spec = 5 end
    SendComm("ANNOUNCE:"..spec..":"..isReady)
end

-- [[ HLAVNÝ FRAME ]]
local MainFrame = CreateFrame("Frame", "SausageSalvaMainFrame", UIParent)
MainFrame:SetPoint("CENTER", 0, 0)
MainFrame:SetMovable(true)
MainFrame:EnableMouse(true)
MainFrame:RegisterForDrag("LeftButton")
MainFrame:SetScript("OnDragStart", MainFrame.StartMoving)
MainFrame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point = SausageSalvaDB.anchor or "TOP"
    local x, y
    
    if point == "TOP" then x, y = self:GetLeft() + self:GetWidth()/2, self:GetTop()
    elseif point == "BOTTOM" then x, y = self:GetLeft() + self:GetWidth()/2, self:GetBottom()
    elseif point == "LEFT" then x, y = self:GetLeft(), self:GetTop() - self:GetHeight()/2
    elseif point == "RIGHT" then x, y = self:GetRight(), self:GetTop() - self:GetHeight()/2
    else x, y = self:GetCenter() end

    self:ClearAllPoints()
    self:SetPoint(point, UIParent, "BOTTOMLEFT", x, y)
    if SausageSalvaDB then SausageSalvaDB.frameX, SausageSalvaDB.frameY = x, y end
end)

MainFrame:SetScript("OnHide", function() 
    if SausageSalvaDB then SausageSalvaDB.isShown = false end 
    EventFrame:SetScript("OnUpdate", nil)
end)
MainFrame:SetScript("OnShow", function() 
    if SausageSalvaDB then SausageSalvaDB.isShown = true end 
    EventFrame:SetScript("OnUpdate", function(self, elapsed) UpdateCombatGrid(elapsed) end)
end)

MainFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})

local header = MainFrame:CreateTexture(nil, "OVERLAY")
header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
header:SetSize(256, 64)
header:SetPoint("TOP", 0, 12)

local title = MainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", header, "TOP", 0, -14)
title:SetText("Sausage Salva")

local ContentFrame = CreateFrame("Frame", "SausageSalvaContent", MainFrame)
ContentFrame:SetPoint("TOPLEFT", 15, -35)
ContentFrame:SetSize(1, 1)

-- [[ PANEL PRE KOORDINÁTOROV ]]
local CoordFrame = CreateFrame("Frame", nil, MainFrame)
CoordFrame:SetSize(250, 20)
CoordFrame:SetPoint("TOP", header, "BOTTOM", 0, -2)
CoordFrame:Hide()

local function CreateCoordIcon(class, x, name)
    local f = CreateFrame("Frame", name, CoordFrame)
    f:SetSize(16, 16)
    f:SetPoint("LEFT", x, 0)
    local tex = f:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\Icons\\ClassIcon_" .. class)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.text:SetPoint("LEFT", f, "RIGHT", 3, 0)
    return f
end

CreateCoordIcon("Paladin", 0, "SausageSalvaCoordPala")
CreateCoordIcon("Hunter", 85, "SausageSalvaCoordHunt")
CreateCoordIcon("Rogue", 170, "SausageSalvaCoordRogue")

-- [[ NOVÉ RADIAL MENU (Zmenšené na 128x128, Custom IKONY a VÝSEKY, BEZ ZLATÉHO KRÚŽKU) ]]
local RadialMenu = CreateFrame("Frame", "SausageSalvaRadialMenu", UIParent)
RadialMenu:SetSize(128, 128)
RadialMenu:SetFrameStrata("TOOLTIP")
RadialMenu:Hide()

local radialBg = RadialMenu:CreateTexture(nil, "BACKGROUND")
radialBg:SetSize(128, 128)
radialBg:SetPoint("CENTER", 0, 0)
radialBg:SetTexture("Interface\\MINIMAP\\UI-Minimap-Background")
radialBg:SetVertexColor(0, 0, 0, 0.6)

local function CreateSlice(textureName, r, g, b)
    local t = RadialMenu:CreateTexture(nil, "ARTWORK")
    t:SetSize(128, 128)
    t:SetPoint("CENTER", 0, 0)
    t:SetTexture("Interface\\AddOns\\SausageSalva\\Textures\\" .. textureName)
    t:SetVertexColor(r, g, b, 0.4)
    return t
end

local palaSec  = CreateSlice("SliceTop.tga", 0.96, 0.55, 0.73)
local huntSec  = CreateSlice("SliceBotLeft.tga", 0.67, 0.83, 0.45)
local rogueSec = CreateSlice("SliceBotRight.tga", 1.00, 0.96, 0.41)

local hub = CreateFrame("Frame", nil, RadialMenu)
hub:SetSize(26, 26)
hub:SetPoint("CENTER", 0, 0)

RadialMenu.hubBg = hub:CreateTexture(nil, "OVERLAY")
RadialMenu.hubBg:SetAllPoints()
RadialMenu.hubBg:SetTexture("Interface\\MINIMAP\\UI-Minimap-Background")
RadialMenu.hubBg:SetVertexColor(0, 0, 0, 1)

local hubBorder = hub:CreateTexture(nil, "OVERLAY", nil, 2)
hubBorder:SetAllPoints()
hubBorder:SetTexture("Interface\\CHARACTERFRAME\\UI-Char-InnerShadow")
hubBorder:SetVertexColor(0, 0, 0, 1)

local hubText = hub:CreateFontString(nil, "OVERLAY", "SystemFont_Tiny")
hubText:SetPoint("CENTER", 0, 1)

local function CreateCustomIcon(textureName, x, y)
    local f = CreateFrame("Frame", nil, RadialMenu)
    f:SetSize(24, 24)
    f:SetPoint("CENTER", x, y)
    local tex = f:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints()
    tex:SetTexture("Interface\\AddOns\\SausageSalva\\Textures\\" .. textureName)
    return f
end

local iconPala = CreateCustomIcon("IconSalva.tga", 0, 32)
local iconHunt = CreateCustomIcon("IconMisdirect.tga", -28, -16)
local iconRogue = CreateCustomIcon("IconTricks.tga", 28, -16)

-- Aura Ring (Zlatý okraj koláča pre prémiový vzhľad)
local aura = RadialMenu:CreateTexture(nil, "OVERLAY", nil, 5)
aura:SetSize(148, 148)
aura:SetPoint("CENTER", 0, 0)
aura:SetTexture("Interface\\SPELLBOOK\\UI-Spellbook-SpellHighlight")
aura:SetBlendMode("ADD")
aura:SetVertexColor(1, 0.9, 0.5, 0.4)

RadialMenu.targetName = nil
RadialMenu.currentHoveredClass = nil

HandleRadialClick = function(targetClass, overrideTargetName)
    local targetName = overrideTargetName or RadialMenu.targetName
    if not targetName then return end
    
    local potentialUnits = {}
    local now = GetTime()
    
    for _, p in ipairs(activePaladins) do
        local penaltyUntil = (rangeFailTracker[targetName] and rangeFailTracker[targetName][p.name]) or 0
        if now >= penaltyUntil then
            if (targetClass == "PALA" and p.spec <= 3) or 
               (targetClass == "HUNT" and p.spec == 4) or 
               (targetClass == "ROGUE" and p.spec == 5) then
                table.insert(potentialUnits, p.name)
            end
        end
    end

    if #potentialUnits > 0 then
        local chosenUnit = potentialUnits[1]
        SendComm("PING_CAST:"..targetName..":"..chosenUnit..":"..targetClass)
        print("|cFF00CCFF[SausageSalva]|r Assigning " .. targetClass .. " to " .. chosenUnit)
    else
        print("|cFFFF0000[SausageSalva]|r No available " .. targetClass .. "s in range/ready!")
    end
    RadialMenu:Hide()
end

RadialMenu:SetScript("OnUpdate", function(self)
    if not self:IsShown() then return end
    if not IsMouseButtonDown("RightButton") then self:Hide(); return end
    
    local x, y = GetCursorPosition()
    local s = self:GetEffectiveScale()
    local mx, my = self:GetCenter()
    
    local angle = math.deg(math.atan2(y/s - my, x/s - mx))
    local dist = math.sqrt((x/s - mx)^2 + (y/s - my)^2)

    palaSec:SetAlpha(0.4); huntSec:SetAlpha(0.4); rogueSec:SetAlpha(0.4)
    self.currentHoveredClass = nil

    if dist < 12 then return end

    if angle >= 30 and angle <= 150 then
        self.currentHoveredClass = "PALA"; palaSec:SetAlpha(1.0)
    elseif angle > 150 or angle <= -90 then
        self.currentHoveredClass = "HUNT"; huntSec:SetAlpha(1.0)
    else
        self.currentHoveredClass = "ROGUE"; rogueSec:SetAlpha(1.0)
    end
end)

-- [[ GRID SYSTÉM A AUTO-VEĽKOSŤ ]]
SausageSalvaMainFrame_UpdateGrid = function()
    if InCombatLockdown() or not SausageSalvaDB then return end 

    local boxWidth = SausageSalvaDB.btnWidth
    local boxHeight = SausageSalvaDB.btnHeight
    local maxCols = SausageSalvaDB.cols
    local spacing = SausageSalvaDB.spacing

    if SausageSalvaDB.hideBorder then
        MainFrame:SetBackdrop({ bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile=nil, tile=true, tileSize=16, edgeSize=0, insets={left=3,right=3,top=3,bottom=3} })
        MainFrame:SetBackdropBorderColor(0, 0, 0, 0)
    else
        MainFrame:SetBackdrop({ bgFile="Interface\\DialogFrame\\UI-DialogBox-Background", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=12, insets={left=3,right=3,top=3,bottom=3} })
        MainFrame:SetBackdropBorderColor(1, 1, 1, 1)
    end

    if SausageSalvaDB.hideBackground then MainFrame:SetBackdropColor(0,0,0,0) else MainFrame:SetBackdropColor(0,0,0,1) end
    if SausageSalvaDB.hideHeader then header:Hide(); title:Hide() else header:Show(); title:Show() end

    ContentFrame:ClearAllPoints()
    ContentFrame:SetPoint("TOP", 0, -35)

    local row, col = 0, 0
    local units = {}

    if isTestMode then for i=1, 25 do units[#units + 1] = "player" end
    else
        if IsInRaid() then for i=1, GetNumRaidMembers() do units[#units + 1] = "raid"..i end
        elseif GetNumPartyMembers() > 0 then units[#units + 1] = "player"; for i=1, GetNumPartyMembers() do units[#units + 1] = "party"..i end
        else units[#units + 1] = "player" end
    end

    local activeCount = 0
    local isSpecial = IsRaidLeader() or IsRaidOfficer()
    local showList = isSpecial and SausageSalvaDB.showListMaster or nil
    if not showList or next(showList) == nil then showList = (isPaladin and SausageSalvaDB.showListPala) or (isHunter and SausageSalvaDB.showListHunt) or (isRogue and SausageSalvaDB.showListRogue) end
    showList = showList or {}

    for i = 1, 40 do
        local btn = unitButtons[i]
        local unit = units[i]
        local unitName = nil
        if isTestMode and i <= 25 then unitName = "TestPlayer " .. i elseif unit then unitName = UnitName(unit) end

        if unitName and (isTestMode or (unit and showList[unitName])) then
            btn:SetAttribute("unit", isTestMode and nil or unit)
            btn.targetUnit = isTestMode and "player" or unit
            btn.unitName = unitName
            btn:SetSize(boxWidth, boxHeight)
            btn:SetFrameLevel(MainFrame:GetFrameLevel() + 5)
            btn.text:SetText(string.sub(unitName, 1, 6))
            if SausageSalvaDB.hideNames then btn.text:Hide() else btn.text:Show() end
            btn.threatText:SetText("0%")
            if SausageSalvaDB.hideThreat then btn.threatText:Hide() else btn.threatText:Show() end
            
            btn.bg:SetVertexColor(0.2, 0.2, 0.2, 0.9)
            btn.border:SetBackdropBorderColor(1, 1, 1, 0.5)
            btn:ClearAllPoints(); btn:SetPoint("TOPLEFT", col * (boxWidth + spacing), -row * (boxHeight + spacing))
            btn:Show(); btn:SetAlpha(1)

            activeCount = activeCount + 1
            col = col + 1; if col >= maxCols then col = 0; row = row + 1 end
        else
            btn:SetAttribute("unit", nil); btn.targetUnit = nil; btn:Hide()
        end
    end

    if activeCount == 0 then activeCount = 1 end
    local finalRows = math.ceil(activeCount / maxCols); local finalCols = math.min(activeCount, maxCols)
    local newWidth = (finalCols * boxWidth) + ((finalCols - 1) * spacing) + 30
    local headerSize = (SausageSalvaDB.hideHeader and 20 or 45); local rlSize = CoordFrame:IsShown() and 15 or 0
    local newHeight = (finalRows * boxHeight) + ((finalRows - 1) * spacing) + headerSize + rlSize + 15
    
    local anchor = SausageSalvaDB.anchor or "TOP"
    MainFrame:ClearAllPoints(); MainFrame:SetSize(newWidth, newHeight)
    local screenX = SausageSalvaDB.frameX or (UIParent:GetWidth()/2); local screenY = SausageSalvaDB.frameY or (UIParent:GetHeight()/2)
    MainFrame:SetPoint(anchor, UIParent, "BOTTOMLEFT", screenX, screenY)
    
    ContentFrame:ClearAllPoints()
    local topOffset = (SausageSalvaDB.hideHeader and -15 or -35); if CoordFrame:IsShown() then topOffset = topOffset - 15 end
    if anchor == "LEFT" then ContentFrame:SetPoint("LEFT", 15, 0) elseif anchor == "RIGHT" then ContentFrame:SetPoint("RIGHT", -15, 0) elseif anchor == "BOTTOM" then ContentFrame:SetPoint("BOTTOM", 0, 15) else ContentFrame:SetPoint("TOP", 0, topOffset) end
    ContentFrame:SetSize(newWidth - 30, (finalRows * boxHeight) + (finalRows * spacing))
end

local function CreateGridButtons()
    for i = 1, 40 do
        local btn = CreateFrame("Button", "SausageSalvaBtn"..i, ContentFrame, "SecureActionButtonTemplate")
        
        btn.bg = btn:CreateTexture(nil, "BACKGROUND")
        btn.bg:SetAllPoints()
        btn.bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
        btn.bg:SetVertexColor(0.2, 0.2, 0.2, 0.9)
        
        btn.border = CreateFrame("Frame", nil, btn)
        btn.border:SetAllPoints()
        btn.border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        btn.border:SetBackdropBorderColor(0, 0, 0, 1)

        -- Decentný vnútorný okraj, aby boxy nepôsobili "prázdne"
        btn.innerBorder = CreateFrame("Frame", nil, btn)
        btn.innerBorder:SetPoint("TOPLEFT", 1, -1)
        btn.innerBorder:SetPoint("BOTTOMRIGHT", -1, 1)
        btn.innerBorder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        btn.innerBorder:SetBackdropBorderColor(1, 1, 1, 0.05)

        btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.text:SetPoint("TOP", 0, -4); btn.text:SetTextColor(1, 1, 1, 1); btn.text:SetShadowColor(0, 0, 0, 1); btn.text:SetShadowOffset(1, -1)
        
        btn.threatText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        btn.threatText:SetPoint("BOTTOM", 0, 4); btn.threatText:SetTextColor(1, 1, 1, 1); btn.threatText:SetShadowColor(0, 0, 0, 1); btn.threatText:SetShadowOffset(1, -1)

        btn.icon = btn:CreateTexture(nil, "OVERLAY")
        btn.icon:SetSize(20, 20); btn.icon:SetPoint("RIGHT", -2, 0); btn.icon:Hide()

        -- Čistý pulzujúci overlay efekt pre príkaz
        btn.pingHighlight = btn:CreateTexture(nil, "OVERLAY", nil, 7)
        btn.pingHighlight:SetTexture("Interface\\Buttons\\WHITE8X8")
        btn.pingHighlight:SetAllPoints()
        btn.pingHighlight:SetBlendMode("ADD")
        btn.pingHighlight:Hide()

        btn:SetAttribute("type1", "spell"); btn:SetAttribute("spell1", mySpellName or "")
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        
        btn:SetScript("OnMouseDown", function(self, button)
            if button == "RightButton" then
                if IsRaidLeader() or IsRaidOfficer() or not IsInRaid() then
                    local targetName = UnitName(self.targetUnit)
                    local _, targetClass = UnitClass(self.targetUnit)
                    if targetName then
                        RadialMenu.targetName = targetName
                        RadialMenu.hubBg:SetVertexColor(targetClass and RAID_CLASS_COLORS[targetClass] and RAID_CLASS_COLORS[targetClass].r or 0.5, targetClass and RAID_CLASS_COLORS[targetClass] and RAID_CLASS_COLORS[targetClass].g or 0.5, targetClass and RAID_CLASS_COLORS[targetClass] and RAID_CLASS_COLORS[targetClass].b or 0.5, 1)
                        local x, y = GetCursorPosition(); local scale = UIParent:GetEffectiveScale()
                        RadialMenu:ClearAllPoints(); RadialMenu:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x/scale, y/scale); RadialMenu:Show()
                    end
                end
            end
        end)

        btn:SetScript("OnMouseUp", function(self, button)
            if button == "RightButton" and RadialMenu:IsShown() then
                if RadialMenu.currentHoveredClass then HandleRadialClick(RadialMenu.currentHoveredClass) end
                RadialMenu:Hide()
            end
        end)

        btn:HookScript("OnClick", function(self, button)
            if button == "LeftButton" then local targetName = UnitName(self.targetUnit); if targetName then SendComm("PRE_CAST:"..targetName); focusTarget, focusTargetClass = nil, nil end end
        end)
        
        btn:Hide(); unitButtons[i] = btn
    end
end

UpdateCombatGrid = function(dt)
    if not MainFrame:IsShown() then return end

    local pulse = (math.sin(GetTime() * 5) + 1) / 2
    local inFocusMode = (focusTarget ~= nil and focusTimer > 0)
    if focusTimer > 0 then focusTimer = focusTimer - dt else focusTargetClass = nil end

    for i = 1, 40 do
        local btn = unitButtons[i]
        if btn:IsShown() then
            local unit = btn.targetUnit
            local unitName = btn.unitName or btn.text:GetText()
            
            local inRange = 1
            if not isTestMode and unit and UnitExists(unit) then
                if mySpellName then inRange = IsSpellInRange(mySpellName, unit) else inRange = UnitInRange(unit) and 1 or 0 end
            end
            if inRange == 0 then btn:SetAlpha(0.4) else btn:SetAlpha(1.0) end

            local threatPct = 0
            if isTestMode then threatPct = (i * 7) % 135 elseif unit and UnitExists(unit) then local _, _, pct = UnitDetailedThreatSituation(unit, "target"); threatPct = pct or 0 end
            btn.threatText:SetText(string.format("%d%%", threatPct))

            local threshold = 100
            if not isTestMode and unit then local _, class = UnitClass(unit); threshold = (class == "MAGE" or class == "WARLOCK" or class == "PRIEST") and 120 or 100 end
            local isTestFocus = isTestMode and (i == 5)
            
            local hasSalva, activeIcon = false, nil
            if isTestMode and (i == 3 or i == 7) then hasSalva = true 
            elseif unit and UnitExists(unit) then
                local s, _, iconS = UnitBuff(unit, SALVA_NAME); local m, _, iconM = UnitBuff(unit, MISDIRECT_NAME); local t, _, iconT = UnitBuff(unit, TRICKS_NAME)
                if s then hasSalva = true; activeIcon = iconS elseif m then hasSalva = true; activeIcon = iconM elseif t then hasSalva = true; activeIcon = iconT end
            end
            if activeIcon then btn.icon:SetTexture(activeIcon); btn.icon:Show() else btn.icon:Hide() end

            -- Vyhodnotenie farieb pre PING pulz
            if inFocusMode or isTestFocus then
                local isThisFocus = (isTestMode and isTestFocus) or (not isTestMode and unitName and focusTarget and string.lower(unitName) == string.lower(focusTarget))
                if isThisFocus then
                    local colorKey = focusTargetClass
                    if isTestMode then
                        colorKey = (debugClass == "HUNTER" and "HUNT" or debugClass == "ROGUE" and "ROGUE" or "PALA")
                    end
                    
                    local r, g, b = 1, 1, 1
                    if colorKey == "PALA" then r, g, b = 0.96, 0.55, 0.73
                    elseif colorKey == "HUNT" then r, g, b = 0.67, 0.83, 0.45
                    elseif colorKey == "ROGUE" then r, g, b = 1.00, 0.96, 0.41 end

                    btn.bg:SetVertexColor(r * 0.3, g * 0.3, b * 0.3, 0.9)
                    btn.pingHighlight:SetTexture("Interface\\Buttons\\CheckButtonHilight")
                    btn.pingHighlight:SetVertexColor(r, g, b, 0.4 + (pulse * 0.6))
                    btn.pingHighlight:Show()
                else
                    btn.bg:SetVertexColor(0.1, 0.1, 0.1, 0.5)
                    btn.pingHighlight:Hide()
                end
            else
                btn.pingHighlight:Hide()
                if hasSalva then btn.bg:SetVertexColor(0.8 + (pulse * 0.2), 0.8 + (pulse * 0.2), 0.8 + (pulse * 0.2), 0.9)
                elseif threatPct >= threshold then btn.bg:SetVertexColor(0.6 + (pulse * 0.4), 0, 0, 0.9)
                elseif threatPct > 0 then btn.bg:SetVertexColor(0.2 + ((threatPct / threshold) * 0.6), 0.2, 0.2, 0.9)
                else btn.bg:SetVertexColor(0.2, 0.2, 0.2, 0.9) end
            end
        end
    end
end

-- [[ UPDATE / GITHUB CUSTOM FRAME ]]
local GitFrame = CreateFrame("Frame", "SausageAutomsgGitFrame", UIParent)
GitFrame:SetSize(320, 130)
GitFrame:SetPoint("CENTER")
GitFrame:SetFrameStrata("DIALOG")
GitFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
tinsert(UISpecialFrames, "SausageAutomsgGitFrame")
GitFrame:Hide()

local gitHeader = GitFrame:CreateTexture(nil, "OVERLAY")
gitHeader:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
gitHeader:SetSize(250, 64)
gitHeader:SetPoint("TOP", 0, 12)
local gitTitle = GitFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
gitTitle:SetPoint("TOP", gitHeader, "TOP", 0, -14)
gitTitle:SetText("UPDATE LINK")
local gitClose = CreateFrame("Button", nil, GitFrame, "UIPanelCloseButton")
gitClose:SetPoint("TOPRIGHT", -8, -8)
local gitDesc = GitFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
gitDesc:SetPoint("TOP", 0, -35)
gitDesc:SetText("Press Ctrl+C to copy the GitHub link:")
local gitEditBox = CreateFrame("EditBox", nil, GitFrame, "InputBoxTemplate")
gitEditBox:SetSize(260, 20)
gitEditBox:SetPoint("TOP", gitDesc, "BOTTOM", 0, -15)
gitEditBox:SetAutoFocus(true)
local GITHUB_LINK = "https://github.com/NikowskyWow/SausageSalva/releases"

gitEditBox:SetScript("OnTextChanged", function(self)
    if self:GetText() ~= GITHUB_LINK then self:SetText(GITHUB_LINK); self:HighlightText() end
end)
gitEditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus(); GitFrame:Hide() end)
GitFrame:SetScript("OnShow", function() gitEditBox:SetText(GITHUB_LINK); gitEditBox:SetFocus(); gitEditBox:HighlightText() end)

-- [[ NASTAVENIA (SETTINGS FRAME) ]]
local SettingsFrame = CreateFrame("Frame", "SausageSalvaSettings", UIParent)
SettingsFrame:SetSize(450, 520)
SettingsFrame:SetPoint("CENTER")
SettingsFrame:SetFrameStrata("DIALOG")
SettingsFrame:SetMovable(true)
SettingsFrame:EnableMouse(true)
SettingsFrame:RegisterForDrag("LeftButton")
SettingsFrame:SetScript("OnDragStart", SettingsFrame.StartMoving)
SettingsFrame:SetScript("OnDragStop", SettingsFrame.StopMovingOrSizing)
SettingsFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 }
})
SettingsFrame:SetBackdropColor(0, 0, 0, 1.0)
tinsert(UISpecialFrames, "SausageSalvaSettings")
SettingsFrame:Hide()

local setHeader = SettingsFrame:CreateTexture(nil, "OVERLAY")
setHeader:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
setHeader:SetSize(256, 64)
setHeader:SetPoint("TOP", 0, 12)
local setTitle = SettingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
setTitle:SetPoint("TOP", setHeader, "TOP", 0, -14)
setTitle:SetText("Settings")
local setClose = CreateFrame("Button", nil, SettingsFrame, "UIPanelCloseButton")
setClose:SetPoint("TOPRIGHT", -8, -8)

local panelContainer = CreateFrame("Frame", nil, SettingsFrame)
panelContainer:SetPoint("TOPLEFT", 0, -65)
panelContainer:SetPoint("BOTTOMRIGHT", 0, 75)
local generalPanel = CreateFrame("Frame", nil, panelContainer); generalPanel:SetAllPoints()
local listPanel = CreateFrame("Frame", nil, panelContainer); listPanel:SetAllPoints()

local function CreateTab(id, text, x, width)
    local btn = CreateFrame("Button", "SausageSalvaTab"..id, SettingsFrame, "UIPanelButtonTemplate")
    btn:SetSize(width or 80, 25)
    btn:SetPoint("TOPLEFT", x, -35)
    btn:SetText(text)
    btn:SetScript("OnClick", function()
        currentTab = id
        for i=1, 5 do 
            local b = _G["SausageSalvaTab"..i]
            if b then if i == id then b:SetAlpha(1.0) else b:SetAlpha(0.6) end end
        end
        SettingsFrame.RefreshUI()
    end)
    return btn
end

CreateTab(1, "General", 20, 80); CreateTab(2, "Paladins", 105, 80); CreateTab(3, "Hunters", 190, 80); CreateTab(4, "Rogues", 275, 80); CreateTab(5, "Master", 360, 80)

local cbAutoHide = CreateFrame("CheckButton", nil, generalPanel, "OptionsBaseCheckButtonTemplate")
cbAutoHide:SetPoint("TOPLEFT", 20, 0)
cbAutoHide:SetScript("OnClick", function(self)
    if SausageSalvaDB then 
        SausageSalvaDB.autoHide = self:GetChecked()
        if not inCombat and SausageSalvaDB.autoHide then MainFrame:Hide() elseif inCombat then MainFrame:Show() end
    end
end)
local cbAutoHideText = generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
cbAutoHideText:SetPoint("LEFT", cbAutoHide, "RIGHT", 5, 0); cbAutoHideText:SetText("Auto-hide out of combat")

local function CreateGridSlider(name, text, minV, maxV, x, y, dbKey)
    local slider = CreateFrame("Slider", "SausageSalvaSlider"..name, generalPanel, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", x, y)
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(1)
    _G[slider:GetName().."Low"]:SetText(minV)
    _G[slider:GetName().."High"]:SetText(maxV)
    _G[slider:GetName().."Text"]:SetText(text)
    local valText = slider:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valText:SetPoint("TOP", slider, "BOTTOM", 0, 3)
    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value); valText:SetText(value)
        if SausageSalvaDB then SausageSalvaDB[dbKey] = value; if not InCombatLockdown() then SausageSalvaMainFrame_UpdateGrid() end end
    end)
    return slider
end

local sldCols = CreateGridSlider("Cols", "Columns", 1, 8, 20, -60, "cols")
local sldWidth = CreateGridSlider("Width", "Button Width", 50, 150, 20, -110, "btnWidth")
local sldHeight = CreateGridSlider("Height", "Button Height", 20, 60, 20, -160, "btnHeight")
local sldSpacing = CreateGridSlider("Spacing", "Spacing", 0, 20, 20, -210, "spacing")

local col2X = 220
local function CreateCB(name, text, y, dbKey)
    local cb = CreateFrame("CheckButton", nil, generalPanel, "OptionsBaseCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", col2X, y)
    cb:SetScript("OnClick", function(self)
        if SausageSalvaDB then SausageSalvaDB[dbKey] = self:GetChecked(); if not InCombatLockdown() then SausageSalvaMainFrame_UpdateGrid() end end
    end)
    local t = generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    t:SetPoint("LEFT", cb, "RIGHT", 5, 0); t:SetText(text)
    return cb
end
local cbHideBorder = CreateCB("Border", "Hide Main Border", -60, "hideBorder")
local cbHideHeader = CreateCB("Header", "Hide Header", -90, "hideHeader")
local cbHideNames = CreateCB("Names", "Hide Names", -120, "hideNames")
local cbHideThreat = CreateCB("Threat", "Hide Threat %", -150, "hideThreat")
local cbHideBackground = CreateCB("BG", "Hide Main BG", -180, "hideBackground")

local anchorLabel = generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
anchorLabel:SetPoint("TOPLEFT", 20, -255); anchorLabel:SetText("Growth Direction (Anchor):")

local function CreateAnchorBtn(name, point, x, y)
    local btn = CreateFrame("Button", nil, generalPanel, "UIPanelButtonTemplate")
    btn:SetSize(60, 22); btn:SetPoint("TOPLEFT", x, y); btn:SetText(name)
    btn:SetScript("OnClick", function()
        SausageSalvaDB.anchor = point
        local px, py
        if point == "TOP" then px, py = MainFrame:GetLeft() + MainFrame:GetWidth()/2, MainFrame:GetTop()
        elseif point == "BOTTOM" then px, py = MainFrame:GetLeft() + MainFrame:GetWidth()/2, MainFrame:GetBottom()
        elseif point == "LEFT" then px, py = MainFrame:GetLeft(), MainFrame:GetTop() - MainFrame:GetHeight()/2
        elseif point == "RIGHT" then px, py = MainFrame:GetRight(), MainFrame:GetTop() - MainFrame:GetHeight()/2 end
        if px and py then SausageSalvaDB.frameX, SausageSalvaDB.frameY = px, py end
        if not InCombatLockdown() then SausageSalvaMainFrame_UpdateGrid() end
    end)
end
CreateAnchorBtn("Down", "TOP", 20, -275); CreateAnchorBtn("Up", "BOTTOM", 85, -275)
CreateAnchorBtn("Right", "LEFT", 150, -275); CreateAnchorBtn("Left", "RIGHT", 215, -275)

local ignoreLabel = listPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
ignoreLabel:SetPoint("TOPLEFT", 15, -5); ignoreLabel:SetText("Players Visibility (Show List)")
local rosterFrame = CreateFrame("Frame", nil, listPanel)
rosterFrame:SetSize(410, 330); rosterFrame:SetPoint("TOPLEFT", 15, -25)
rosterFrame:SetBackdrop({ bgFile="Interface\\Tooltips\\UI-Tooltip-Background", edgeFile="Interface\\Tooltips\\UI-Tooltip-Border", tile=true, tileSize=16, edgeSize=12, insets={left=3,right=3,top=3,bottom=3} })
rosterFrame:SetBackdropColor(0,0,0,0.5)

local ignoreListScroll = CreateFrame("ScrollFrame", "SausageSalvaIgnoreScroll", rosterFrame, "FauxScrollFrameTemplate")
ignoreListScroll:SetPoint("TOPLEFT", 5, -5); ignoreListScroll:SetPoint("BOTTOMRIGHT", -25, 5)

local ignoreRowBtns = {}
for i = 1, 15 do
    local row = CreateFrame("CheckButton", nil, rosterFrame, "UICheckButtonTemplate")
    row:SetSize(20, 20)
    if i == 1 then row:SetPoint("TOPLEFT", 10, -10) else row:SetPoint("TOPLEFT", ignoreRowBtns[i-1], "BOTTOMLEFT", 0, 0) end
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.text:SetPoint("LEFT", row, "RIGHT", 5, 0)
    row:SetScript("OnClick", function(self)
        if not (not IsInRaid() or IsRaidLeader() or IsRaidOfficer()) then self:SetChecked(not self:GetChecked()); return end
        if not self.playerName then return end
        local listKey = (currentTab == 2 and "showListPala") or (currentTab == 3 and "showListHunt") or (currentTab == 4 and "showListRogue") or (currentTab == 5 and "showListMaster")
        SausageSalvaDB[listKey][self.playerName] = self:GetChecked()
        if IsInGroup() then
            local csv = ""
            for name, shown in pairs(SausageSalvaDB[listKey]) do if shown then csv = csv .. name .. "," end end
            local classCode = (currentTab == 2 and "PALA") or (currentTab == 3 and "HUNT") or (currentTab == 4 and "ROGUE") or (currentTab == 5 and "MASTER")
            SendComm("SYNC_LIST:"..classCode..":"..csv)
        end
        UpdateIgnoreScrollFrame()
        if not InCombatLockdown() then SausageSalvaMainFrame_UpdateGrid() end
    end)
    ignoreRowBtns[i] = row
end

local rosterCache = {}
UpdateIgnoreScrollFrame = function()
    wipe(rosterCache)
    if IsInRaid() then for i=1, GetNumRaidMembers() do local n = UnitName("raid"..i); if n then rosterCache[#rosterCache+1] = n end end
    elseif GetNumPartyMembers() > 0 then local pn = UnitName("player"); if pn then rosterCache[#rosterCache+1] = pn end; for i=1, GetNumPartyMembers() do local n = UnitName("party"..i); if n then rosterCache[#rosterCache+1] = n end end
    else local pn = UnitName("player"); if pn then rosterCache[#rosterCache+1] = pn end end
    table.sort(rosterCache)

    FauxScrollFrame_Update(ignoreListScroll, #rosterCache, 15, 20)
    local offset = FauxScrollFrame_GetOffset(ignoreListScroll)
    local listKey = (currentTab == 2 and "showListPala") or (currentTab == 3 and "showListHunt") or (currentTab == 4 and "showListRogue") or (currentTab == 5 and "showListMaster")

    for i = 1, 15 do
        local index = offset + i
        local row = ignoreRowBtns[i]
        if index <= #rosterCache and listKey then
            local pName = rosterCache[index]
            row.playerName = pName; row.text:SetText(pName)
            if SausageSalvaDB[listKey] and SausageSalvaDB[listKey][pName] then row:SetChecked(true); row.text:SetTextColor(1, 1, 1, 1) else row:SetChecked(false); row.text:SetTextColor(0.5, 0.5, 0.5, 1) end
            row:Show()
        else row:Hide() end
    end
end
ignoreListScroll:SetScript("OnVerticalScroll", function(self, offset) FauxScrollFrame_OnVerticalScroll(self, offset, 20, UpdateIgnoreScrollFrame) end)

local footerFrame = CreateFrame("Frame", nil, SettingsFrame)
footerFrame:SetSize(450, 75); footerFrame:SetPoint("BOTTOMLEFT", 0, 0); footerFrame:SetFrameLevel(SettingsFrame:GetFrameLevel() + 5)

local btnCheckStatus = CreateFrame("Button", nil, footerFrame, "UIPanelButtonTemplate")
btnCheckStatus:SetSize(110, 25); btnCheckStatus:SetPoint("BOTTOMLEFT", 15, 45); btnCheckStatus:SetText("Check Group")
btnCheckStatus:SetScript("OnClick", function() if IsRaidLeader() or IsRaidOfficer() or not IsInRaid() then SendComm("CHECK") end end)

local btnTestGrid = CreateFrame("Button", nil, footerFrame, "UIPanelButtonTemplate")
btnTestGrid:SetSize(100, 25); btnTestGrid:SetPoint("LEFT", btnCheckStatus, "RIGHT", 5, 0); btnTestGrid:SetText("Test Grid")
btnTestGrid:SetScript("OnClick", function()
    isTestMode = not isTestMode
    if isTestMode then CoordFrame:Show(); MainFrame:Show(); EventFrame:SetScript("OnUpdate", function(self, elapsed) UpdateCombatGrid(elapsed) end)
    else if not inCombat then if not (IsInRaid() and (IsRaidLeader() or IsRaidOfficer())) then CoordFrame:Hide() end; if SausageSalvaDB.autoHide then MainFrame:Hide() end; EventFrame:SetScript("OnUpdate", nil) end end
    SortPaladins(); if not InCombatLockdown() then SausageSalvaMainFrame_UpdateGrid() end
end)

local refreshBtn = CreateFrame("Button", nil, footerFrame, "UIPanelButtonTemplate")
refreshBtn:SetSize(100, 25); refreshBtn:SetPoint("LEFT", btnTestGrid, "RIGHT", 5, 0); refreshBtn:SetText("Update Grid")
refreshBtn:SetScript("OnClick", function() if not InCombatLockdown() then SausageSalvaMainFrame_UpdateGrid(); UpdateIgnoreScrollFrame(); BroadcastStatus() end end)

local updateBtn = CreateFrame("Button", nil, footerFrame, "UIPanelButtonTemplate")
updateBtn:SetSize(110, 25); updateBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 5, 0); updateBtn:SetText("Check Updates")
updateBtn:SetScript("OnClick", function() GitFrame:Show() end)

local lblVersion = footerFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
lblVersion:SetPoint("BOTTOMRIGHT", -20, 15); lblVersion:SetText(SAUSAGE_VERSION)
local lblCredits = footerFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
lblCredits:SetPoint("BOTTOM", footerFrame, "BOTTOM", 0, 15); lblCredits:SetText("by Sausage Party")

local cbEnableSound = CreateFrame("CheckButton", nil, generalPanel, "OptionsBaseCheckButtonTemplate")
cbEnableSound:SetPoint("TOPLEFT", 20, -320)
cbEnableSound:SetScript("OnClick", function(self) if SausageSalvaDB then SausageSalvaDB.enableSound = self:GetChecked() end end)
local cbEnableSoundText = generalPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
cbEnableSoundText:SetPoint("LEFT", cbEnableSound, "RIGHT", 5, 0); cbEnableSoundText:SetText("Enable Alert Sound")

local testSoundBtn = CreateFrame("Button", nil, generalPanel, "UIPanelButtonTemplate")
testSoundBtn:SetSize(80, 22); testSoundBtn:SetPoint("LEFT", cbEnableSoundText, "RIGHT", 20, 0); testSoundBtn:SetText("Test Sound")
testSoundBtn:SetScript("OnClick", function() if mySoundPath then PlaySoundFile(mySoundPath, "Master") end end)

function SettingsFrame.RefreshUI()
    if currentTab == 1 then
        generalPanel:Show(); listPanel:Hide()
        cbAutoHide:SetChecked(SausageSalvaDB.autoHide)
        sldCols:SetValue(SausageSalvaDB.cols); sldWidth:SetValue(SausageSalvaDB.btnWidth); sldHeight:SetValue(SausageSalvaDB.btnHeight); sldSpacing:SetValue(SausageSalvaDB.spacing)
        cbHideBorder:SetChecked(SausageSalvaDB.hideBorder); cbHideHeader:SetChecked(SausageSalvaDB.hideHeader); cbHideNames:SetChecked(SausageSalvaDB.hideNames); cbHideThreat:SetChecked(SausageSalvaDB.hideThreat); cbHideBackground:SetChecked(SausageSalvaDB.hideBackground)
        cbEnableSound:SetChecked(SausageSalvaDB.enableSound)
    else
        generalPanel:Hide(); listPanel:Show(); UpdateIgnoreScrollFrame()
    end
end
SettingsFrame:SetScript("OnShow", function() if SausageSalvaDB then SettingsFrame.RefreshUI() end end)

-- [[ TEST WINDOW ]]
local TestFrame = CreateFrame("Frame", "SausageSalvaTestFrame", UIParent)
TestFrame:SetSize(250, 400); TestFrame:SetPoint("CENTER", 300, 0); TestFrame:SetBackdrop(SettingsFrame:GetBackdrop()); TestFrame:SetBackdropColor(0,0,0,1); TestFrame:SetMovable(true); TestFrame:EnableMouse(true); TestFrame:RegisterForDrag("LeftButton"); TestFrame:SetScript("OnDragStart", TestFrame.StartMoving); TestFrame:SetScript("OnDragStop", TestFrame.StopMovingOrSizing); TestFrame:Hide()
local testHeader = TestFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal"); testHeader:SetPoint("TOP", 0, -15); testHeader:SetText("SausageSalva Debug")

local function CreateTestButton(text, y, func)
    local btn = CreateFrame("Button", nil, TestFrame, "UIPanelButtonTemplate")
    btn:SetSize(180, 25); btn:SetPoint("TOP", 0, y); btn:SetText(text); btn:SetScript("OnClick", func)
    return btn
end

-- Vylepšená funkcia pre automatické zapnutie Test Gridu po kliknutí na classu
local function SetIdentityAndTest(className)
    debugClass = className
    UpdateAddonIdentity()
    isTestMode = true
    CoordFrame:Show()
    MainFrame:Show()
    EventFrame:SetScript("OnUpdate", function(self, elapsed) UpdateCombatGrid(elapsed) end)
    SortPaladins()
    if not InCombatLockdown() then SausageSalvaMainFrame_UpdateGrid() end
    print("|cFFFFFF00[SausageSalva]|r Identity: " .. className .. " | Test Mode: |cFF00FF00ON|r")
end

CreateTestButton("Identity: PALADIN", -45, function() SetIdentityAndTest("PALADIN") end)
CreateTestButton("Identity: HUNTER", -75, function() SetIdentityAndTest("HUNTER") end)
CreateTestButton("Identity: ROGUE", -105, function() SetIdentityAndTest("ROGUE") end)

local lbLeader = CreateFrame("CheckButton", nil, TestFrame, "OptionsBaseCheckButtonTemplate")
lbLeader:SetPoint("TOPLEFT", 35, -140); lbLeader:SetScript("OnClick", function(self) debugLeader = self:GetChecked() end)
local lbLeaderText = TestFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"); lbLeaderText:SetPoint("LEFT", lbLeader, "RIGHT", 5, 0); lbLeaderText:SetText("Force Leader Rights")

CreateTestButton("Simulate PALA Ping", -185, function() EventFrame:GetScript("OnEvent")(EventFrame, "CHAT_MSG_ADDON", PREFIX, "PING_CAST:player:"..UnitName("player")..":PALA", "RAID", "FakeRL") end)
CreateTestButton("Simulate HUNT Ping", -215, function() EventFrame:GetScript("OnEvent")(EventFrame, "CHAT_MSG_ADDON", PREFIX, "PING_CAST:player:"..UnitName("player")..":HUNT", "RAID", "FakeRL") end)
CreateTestButton("Simulate ROGUE Ping", -245, function() EventFrame:GetScript("OnEvent")(EventFrame, "CHAT_MSG_ADDON", PREFIX, "PING_CAST:player:"..UnitName("player")..":ROGUE", "RAID", "FakeRL") end)
CreateTestButton("Add Fake Spellers", -285, function() activePaladins[#activePaladins+1] = { name="F_Holy", spec=1 }; activePaladins[#activePaladins+1] = { name="F_Hunt", spec=4 }; activePaladins[#activePaladins+1] = { name="F_Rogu", spec=5 }; SortPaladins() end)
CreateTestButton("Fake ANNOUNCE (Pala)", -315, function() EventFrame:GetScript("OnEvent")(EventFrame, "CHAT_MSG_ADDON", PREFIX, "ANNOUNCE:2:1", "RAID", "F_Pala_"..math.random(10,99)) end)
CreateTestButton("Close Test Window", -350, function() TestFrame:Hide() end)

-- [[ MINIMAP IKONA ]]
local minimapIcon = CreateFrame("Button", "SausageSalvaMinimapIcon", Minimap)
minimapIcon:SetSize(32, 32); minimapIcon:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 0, 0)
local iconTex = minimapIcon:CreateTexture(nil, "BACKGROUND"); iconTex:SetTexture("Interface\\Icons\\Inv_Misc_Food_54"); iconTex:SetSize(20, 20); iconTex:SetPoint("CENTER")
local iconBorder = minimapIcon:CreateTexture(nil, "OVERLAY"); iconBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder"); iconBorder:SetSize(54, 54); iconBorder:SetPoint("TOPLEFT", 0, 0)
minimapIcon:RegisterForClicks("LeftButtonUp", "RightButtonUp"); minimapIcon:RegisterForDrag("RightButton")
local isDragging = false
minimapIcon:SetScript("OnDragStart", function(self)
    self:LockHighlight(); isDragging = true
    self:SetScript("OnUpdate", function(self)
        local xpos, ypos = GetCursorPosition(); local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()
        xpos = xmin - xpos/UIParent:GetScale() + 70; ypos = ypos/UIParent:GetScale() - ymin - 70
        local angle = math.deg(math.atan2(ypos, xpos))
        local x, y = math.cos(math.rad(angle)) * 80, math.sin(math.rad(angle)) * 80
        self:SetPoint("TOPLEFT", Minimap, "TOPLEFT", 52 - x, y - 52)
    end)
end)
minimapIcon:SetScript("OnDragStop", function(self) self:UnlockHighlight(); isDragging = false; self:SetScript("OnUpdate", nil) end)
minimapIcon:SetScript("OnClick", function(self, button)
    if isDragging then return end
    if button == "LeftButton" then if IsShiftKeyDown() then if SettingsFrame:IsShown() then SettingsFrame:Hide() else SettingsFrame:Show() end else if MainFrame:IsShown() then MainFrame:Hide() else MainFrame:Show() end end end
end)

-- [[ EVENTY ]]
EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
EventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
EventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:RegisterEvent("CHAT_MSG_ADDON")
EventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
EventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")

EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == addonName then
            if RegisterAddonMessagePrefix then RegisterAddonMessagePrefix(PREFIX) end
            SausageSalvaDB = SausageSalvaDB or {}
            for k, v in pairs(defaultDB) do if SausageSalvaDB[k] == nil then SausageSalvaDB[k] = v end end
            if SausageSalvaDB.framePoint then SausageSalvaDB.anchor = SausageSalvaDB.framePoint; SausageSalvaDB.framePoint = nil end
            if not SausageSalvaDB.frameY or SausageSalvaDB.frameY < 0 then SausageSalvaDB.frameX = UIParent:GetWidth() / 2; SausageSalvaDB.frameY = UIParent:GetHeight() - 100 end

            MainFrame:ClearAllPoints(); CreateGridButtons()
            if SausageSalvaDB.isShown == false or SausageSalvaDB.autoHide then MainFrame:Hide() else MainFrame:Show() end
            SausageSalvaMainFrame_UpdateGrid()
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
        if IsInRaid() and (IsRaidLeader() or IsRaidOfficer()) or isTestMode then CoordFrame:Show() else CoordFrame:Hide() end
        local changed = false; for i = #activePaladins, 1, -1 do if not UnitInRaid(activePaladins[i].name) and not UnitInParty(activePaladins[i].name) then table.remove(activePaladins, i); changed = true end end
        SortPaladins(); SausageSalvaMainFrame_UpdateGrid(); if SettingsFrame:IsShown() then UpdateIgnoreScrollFrame() end; BroadcastStatus()
        if event == "PLAYER_ENTERING_WORLD" and not (IsRaidLeader() or IsRaidOfficer()) then SendComm("REQ_IGNORE") end
    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true; if SausageSalvaDB and SausageSalvaDB.autoHide then MainFrame:Show() end
    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false; focusTarget, focusTargetClass = nil, nil; if SausageSalvaDB and SausageSalvaDB.autoHide then MainFrame:Hide() end; SausageSalvaMainFrame_UpdateGrid() 
    elseif event == "SPELL_UPDATE_COOLDOWN" then
        BroadcastStatus()
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix == PREFIX then
            local args = {strsplit(":", msg)}
            local cmd = args[1]

            if cmd == "CHECK" then SendComm("VERSION:"..SAUSAGE_VERSION)
            elseif cmd == "VERSION" then print("|cFFFFFF00[SausageSalva]|r " .. sender .. " má verziu " .. args[2])
            elseif cmd == "SYNC_LIST" then
                local listKey = (args[2] == "PALA" and "showListPala") or (args[2] == "HUNT" and "showListHunt") or (args[2] == "ROGUE" and "showListRogue") or (args[2] == "MASTER" and "showListMaster")
                if listKey and args[3] then
                    wipe(SausageSalvaDB[listKey]); for _, n in ipairs({strsplit(",", args[3])}) do if n ~= "" then SausageSalvaDB[listKey][n] = true end end
                    if SettingsFrame:IsShown() then SettingsFrame.RefreshUI() end; if not InCombatLockdown() then SausageSalvaMainFrame_UpdateGrid() end
                end
            elseif cmd == "REQ_IGNORE" then
                if IsRaidLeader() or IsRaidOfficer() or (not IsInRaid() and IsInGroup()) then
                    for _, c in ipairs({"PALA", "HUNT", "ROGUE", "MASTER"}) do
                        local csv = ""; for name, shown in pairs(SausageSalvaDB[(c == "PALA" and "showListPala") or (c == "HUNT" and "showListHunt") or (c == "ROGUE" and "showListRogue") or (c == "MASTER" and "showListMaster")]) do if shown then csv = csv .. name .. "," end end
                        if csv ~= "" then SendComm("SYNC_LIST:"..c..":"..csv) end
                    end
                end
            elseif cmd == "ANNOUNCE" then
                if sender == UnitName("player") then return end
                for i = #activePaladins, 1, -1 do if activePaladins[i].name == sender then table.remove(activePaladins, i) end end
                if tonumber(args[3]) == 1 then activePaladins[#activePaladins + 1] = {name = sender, spec = tonumber(args[2])} end
                SortPaladins()
            elseif cmd == "PRE_CAST" then -- Vizuálne zmeny iba
            elseif cmd == "PING_CAST" then
                local targetName, assignedName, targetClass = args[2], args[3], args[4]
                if assignedName == UnitName("player") then
                    local targetUnit = GetUnitByName(targetName)
                    if targetUnit and mySpellName and IsSpellInRange(mySpellName, targetUnit) == 0 then
                        print("|cFFFF0000[SausageSalva]|r Rejected PING (Out of range): " .. targetName); SendComm("RANGE_FAIL:"..targetName..":"..(targetClass or "PALA"))
                        return
                    end
                    focusTarget, focusTimer, focusTargetClass = targetName, 15.0, targetClass 
                    EventFrame:SetScript("OnUpdate", function(self, elapsed) UpdateCombatGrid(elapsed) end)
                    print("|cFF00CCFF[SausageSalva]|r Cast spell on " .. targetName .. "!")
                    if SausageSalvaDB.enableSound and mySoundPath then PlaySoundFile(mySoundPath, "Master") end
                end
            elseif cmd == "RANGE_FAIL" then
                local targetName, targetClass = args[2], args[3]
                print("|cFFFF8800[SausageSalva]|r " .. sender .. " is out of range! Reassigning " .. targetClass .. " on " .. targetName)
                rangeFailTracker[targetName] = rangeFailTracker[targetName] or {}; rangeFailTracker[targetName][sender] = GetTime() + 5
                HandleRadialClick(targetClass, targetName)
            end
        end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, subEvent, _, sourceName, _, _, destName, _, spellId = ...
        if subEvent == "SPELL_CAST_SUCCESS" and sourceName == UnitName("player") then
            if spellId == SALVA_SPELL_ID or spellId == MISDIRECT_SPELL_ID or spellId == TRICKS_SPELL_ID then
                if IsInGroup() then SendChatMessage(GetSpellInfo(spellId) .. " on " .. destName .. "!", IsInRaid() and "RAID" or "PARTY") end
                focusTarget, focusTargetClass = nil, nil; BroadcastStatus()
            end
        end
    end
end)

-- [[ SLASH COMMANDS ]]
SLASH_SAUSAGESALVA1 = "/ssalva"
SLASH_SAUSAGESALVA2 = "/salva"
SlashCmdList["SAUSAGESALVA"] = function(msg)
    msg = (msg or ""):lower()
    if msg == "center" then
        if not InCombatLockdown() then SausageSalvaDB.anchor = "TOP"; SausageSalvaDB.frameX = UIParent:GetWidth() / 2; SausageSalvaDB.frameY = UIParent:GetHeight() - 100; SausageSalvaMainFrame_UpdateGrid(); print("|cFFFFFF00[SausageSalva]|r Addon centered (Top-Center).") else print("|cFFFF0000[SausageSalva]|r Cannot center while in combat!") end
    elseif msg == "settings" or msg == "config" then if SettingsFrame:IsShown() then SettingsFrame:Hide() else SettingsFrame:Show() end
    elseif msg == "test" or msg == "debug" then if TestFrame:IsShown() then TestFrame:Hide() else TestFrame:Show() end
    else if MainFrame:IsShown() then MainFrame:Hide() else MainFrame:Show() end end
end