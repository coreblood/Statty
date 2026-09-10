local ADDON_NAME = ...

-- ============================================================
-- C_Timer compatibility shim for 3.3.5a
-- ============================================================
-- The 3.3.5a client has NO C_Timer API (it was added in 6.0 / WoD).
-- Every timer call in this addon (C_Timer.After / NewTimer / NewTicker)
-- therefore errored with "attempt to index global 'C_Timer' (a nil value)"
-- the moment "Start Conversion" was pressed. This shim provides the same
-- three functions (with :Cancel()) on top of a plain OnUpdate frame.
if not C_Timer then
    C_Timer = {}
    local timers = {}
    local timerFrame = CreateFrame("Frame")

    local function Cancel(self) self.cancelled = true end
    local function IsCancelled(self) return self.cancelled == true end

    local function NewTimerObject(duration, callback, isTicker, iterations)
        local t = {
            remaining = duration,
            duration = duration,
            callback = callback,
            ticker = isTicker,
            iterations = iterations,
            Cancel = Cancel,
            IsCancelled = IsCancelled,
        }
        table.insert(timers, t)
        return t
    end

    timerFrame:SetScript("OnUpdate", function(_, elapsed)
        for i = #timers, 1, -1 do
            local t = timers[i]
            if t.cancelled then
                table.remove(timers, i)
            else
                t.remaining = t.remaining - elapsed
                if t.remaining <= 0 then
                    if t.ticker then
                        t.remaining = t.remaining + t.duration
                        if t.iterations then
                            t.iterations = t.iterations - 1
                            if t.iterations <= 0 then t.cancelled = true end
                        end
                    else
                        t.cancelled = true
                    end
                    t.callback(t)
                end
            end
        end
    end)

    function C_Timer.After(duration, callback)
        NewTimerObject(duration, callback, false)
    end

    function C_Timer.NewTimer(duration, callback)
        return NewTimerObject(duration, callback, false)
    end

    function C_Timer.NewTicker(duration, callback, iterations)
        return NewTimerObject(duration, callback, true, iterations)
    end
end

local frame = CreateFrame("Frame", "AutoStatConverterFrame", UIParent)
frame:SetSize(340, 420)
frame:SetPoint("CENTER")
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
frame:Hide()
frame:EnableMouse(true)
frame:SetMovable(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

-- Title
local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -15)
title:SetText("Auto Stat Converter (3.3.5a)")

-- Close Button
local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)

-- Stats list
local STAT_LIST = {
    "Strength",
    "Agility",
    "Stamina",
    "Intellect",
    "Spirit",
    "Defense Rating",
    "Spell Power",
    "Expertise"
}

-- ============================================================
-- Server gossip text matching (edit these if your server's
-- wording differs - run /asc debug to see the real option text)
-- ============================================================
local MATCH = {
    CONVERT_MENU = "Convert stats", -- exact text of the top-level gossip option
    HALF = "HALF",                  -- keyword identifying the "convert half" options
    ALL = "ALL",                    -- keyword identifying the "convert all" options
}
local DEFAULT_MATCH = { CONVERT_MENU = MATCH.CONVERT_MENU, HALF = MATCH.HALF, ALL = MATCH.ALL }

local sourceCheckboxes = {}
local targetCheckboxes = {}
local modeAll = true
local autoLeaveDungeon = false
local wasInInstance = false
local conversionQueue = {}
local isRunning = false
local sessionGains = {}
local sessionSkipped = {}
local queueTotal = 0
local queueDone = 0
local activeItem = nil
local debugMode = false
local retryEnabled = true   -- retry timeout-skipped conversions once at queue end
local autoCountdown = 10    -- seconds of warning before dungeon-exit auto-convert

-- ============================================================
-- SavedVariables (persist settings between sessions/characters)
-- ============================================================
-- Add "## SavedVariables: AutoStatConverterDB" to the .toc for this to persist.
AutoStatConverterDB = AutoStatConverterDB or {}

local function SaveSettings()
    AutoStatConverterDB.modeAll = modeAll
    AutoStatConverterDB.autoLeaveDungeon = autoLeaveDungeon
    AutoStatConverterDB.debugMode = debugMode
    AutoStatConverterDB.retryEnabled = retryEnabled
    AutoStatConverterDB.autoCountdown = autoCountdown
    AutoStatConverterDB.match = { CONVERT_MENU = MATCH.CONVERT_MENU, HALF = MATCH.HALF, ALL = MATCH.ALL }
    AutoStatConverterDB.minimapAngle = minimapAngle
    AutoStatConverterDB.targets = {}
    for i, cb in ipairs(targetCheckboxes) do
        AutoStatConverterDB.targets[i] = cb:GetChecked() and true or false
    end
    AutoStatConverterDB.sources = {}
    for i, cb in ipairs(sourceCheckboxes) do
        AutoStatConverterDB.sources[i] = cb:GetChecked() and true or false
    end
end

-- Summary Results Window
local summaryFrame = CreateFrame("Frame", "ASC_SummaryFrame", UIParent)
summaryFrame:SetSize(300, 310)
summaryFrame:SetPoint("CENTER")
summaryFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
summaryFrame:Hide()
summaryFrame:EnableMouse(true)
summaryFrame:SetMovable(true)
summaryFrame:RegisterForDrag("LeftButton")
summaryFrame:SetScript("OnDragStart", summaryFrame.StartMoving)
summaryFrame:SetScript("OnDragStop", summaryFrame.StopMovingOrSizing)

local summaryTitle = summaryFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
summaryTitle:SetPoint("TOP", 0, -15)
summaryTitle:SetText("Conversion Summary")

local summaryText = summaryFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
summaryText:SetPoint("TOPLEFT", 20, -50)
summaryText:SetJustifyH("LEFT")
summaryText:SetJustifyV("TOP")
summaryText:SetSize(260, 200)

local summaryCloseBtn = CreateFrame("Button", nil, summaryFrame, "UIPanelButtonTemplate")
summaryCloseBtn:SetSize(100, 24)
summaryCloseBtn:SetPoint("BOTTOM", 0, 15)
summaryCloseBtn:SetText("Close")
summaryCloseBtn:SetScript("OnClick", function() summaryFrame:Hide() end)

-- Target Stats Selection (Strictly 1 or 2 targets)
local targetLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
targetLabel:SetPoint("TOPLEFT", 20, -40)
targetLabel:SetText("Convert INTO Target Stat(s) [Max 2]:")

local targetContainer = CreateFrame("Frame", nil, frame)
targetContainer:SetSize(300, 75)
targetContainer:SetPoint("TOPLEFT", 20, -55)

for i, stat in ipairs(STAT_LIST) do
    local cb = CreateFrame("CheckButton", "ASC_TCB_" .. i, targetContainer, "UICheckButtonTemplate")
    local row = math.floor((i - 1) / 3)
    local col = (i - 1) % 3
    cb:SetPoint("TOPLEFT", col * 95, -row * 22)
    _G[cb:GetName() .. "Text"]:SetText(stat:sub(1, 8))
    cb.statName = stat

    cb:SetScript("OnClick", function(self)
        local count = 0
        for _, box in ipairs(targetCheckboxes) do
            if box:GetChecked() then count = count + 1 end
        end
        if count > 2 then
            self:SetChecked(false)
            if UIErrorsFrame then
                UIErrorsFrame:AddMessage("Select maximum 2 target stats (1st takes HALF, 2nd takes REMAINING FULL).", 1, 0, 0)
            end
        end
        SaveSettings()
    end)
    table.insert(targetCheckboxes, cb)
end
targetCheckboxes[7]:SetChecked(true)

-- Source Stats Selection
local checkLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
checkLabel:SetPoint("TOPLEFT", 20, -135)
checkLabel:SetText("Select Source Stats to Convert FROM:")

for i, stat in ipairs(STAT_LIST) do
    local cb = CreateFrame("CheckButton", "ASC_CB_" .. i, frame, "UICheckButtonTemplate")
    local row = math.floor((i - 1) / 2)
    local col = (i - 1) % 2
    cb:SetPoint("TOPLEFT", 20 + (col * 140), -150 - (row * 22))
    _G[cb:GetName() .. "Text"]:SetText(stat)
    cb.statName = stat
    cb:SetScript("OnClick", SaveSettings)
    table.insert(sourceCheckboxes, cb)
end

-- Amount Toggle Button (For Single Target Selection)
local modeBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
modeBtn:SetSize(110, 22)
modeBtn:SetPoint("BOTTOMLEFT", 20, 80)
modeBtn:SetText("Amount: ALL")
modeBtn:SetScript("OnClick", function(self)
    modeAll = not modeAll
    self:SetText(modeAll and "Amount: ALL" or "Amount: HALF")
    SaveSettings()
end)

-- Preview Button (shows the queue that would run, without running it)
local previewBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
previewBtn:SetSize(90, 22)
previewBtn:SetPoint("LEFT", modeBtn, "RIGHT", 8, 0)
previewBtn:SetText("Preview")
-- OnClick wired up after PreviewQueue is defined (see below)

-- Auto Dungeon Trigger Checkbox
local autoDungeonCB = CreateFrame("CheckButton", "ASC_AutoDungeonCB", frame, "UICheckButtonTemplate")
autoDungeonCB:SetPoint("BOTTOMLEFT", 20, 50)
_G[autoDungeonCB:GetName() .. "Text"]:SetText("Auto-convert after leaving dungeon")
autoDungeonCB:SetScript("OnClick", function(self)
    autoLeaveDungeon = self:GetChecked()
    SaveSettings()
end)

-- Status text (shows current step / stall diagnostics)
local statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
statusText:SetPoint("BOTTOMLEFT", 20, 108)
statusText:SetPoint("BOTTOMRIGHT", -20, 108)
statusText:SetJustifyH("LEFT")
statusText:SetText("")

local function SetStatus(text, isError)
    statusText:SetText(text or "")
    if isError then
        statusText:SetTextColor(1, 0.3, 0.3)
    else
        statusText:SetTextColor(0.6, 0.6, 0.6)
    end
end

-- Automation Engine
local STEP_DELAY = 0.15
local RESET_DELAY = 0.10
local STEP_TIMEOUT = 5.0 -- seconds to wait for gossip to respond before giving up
local currentStep = 0
local activeSourceStat = nil
local activeTargetStat = nil
local activeAmountMode = "ALL" -- "HALF" or "ALL"
local tickerTimer = nil
local watchdogTimer = nil

local function DelayRun(delay, func)
    C_Timer.After(delay, func)
end

local function CancelWatchdog()
    if watchdogTimer then
        watchdogTimer:Cancel()
        watchdogTimer = nil
    end
end

local function ResetState()
    currentStep = 0
    isRunning = false
    activeSourceStat = nil
    activeTargetStat = nil
    conversionQueue = {}
    if tickerTimer then
        tickerTimer:Cancel()
        tickerTimer = nil
    end
    CancelWatchdog()
end

-- Forward declaration so the watchdog can reference it before it's defined
local ProcessNextInQueue

-- Skips only the conversion currently in progress (e.g. the source stat
-- has 0 points, so the server doesn't list it in the gossip menu) and
-- moves on to the next item in the queue instead of aborting everything.
-- `definitive` = we positively confirmed the option is absent (e.g. the
-- source page was on screen without our stat). Non-definitive skips
-- (watchdog timeouts, which can be caused by lag) get one retry at the
-- end of the queue before being recorded as skipped.
local function SkipCurrentConversion(reason, definitive)
    if not isRunning then return end
    if not definitive and retryEnabled and activeItem and not activeItem.retried then
        activeItem.retried = true
        table.insert(conversionQueue, activeItem)
        queueTotal = queueTotal + 1
        SetStatus(string.format("Requeued %s for one retry", tostring(activeSourceStat)))
    else
        SetStatus(string.format("Skipped %s (%s)", tostring(activeSourceStat), reason))
        table.insert(sessionSkipped, string.format("%s -> %s", tostring(activeSourceStat), tostring(activeTargetStat)))
    end
    CancelWatchdog()
    currentStep = 0
    CloseGossip()
    DelayRun(STEP_DELAY, ProcessNextInQueue)
end

-- Starts (or restarts) a timeout for the step we're currently waiting on.
-- Step 1 stalling (gossip never opened at all) aborts the whole run,
-- since every later item would fail the same way. Steps 2/3 stalling
-- only skip the current item — the usual cause is a stat with no points
-- to give, which the server simply omits from the menu.
local function ArmWatchdog(step, description)
    CancelWatchdog()
    watchdogTimer = C_Timer.NewTimer(STEP_TIMEOUT, function()
        watchdogTimer = nil
        if isRunning and currentStep == step then
            if step == 1 then
                SetStatus("Stalled at step 1: the gossip window never opened (server/range issue).", true)
                ResetState()
            elseif step == 2 then
                SkipCurrentConversion(string.format(
                    "no gossip option matched target '%s' within %ds", tostring(activeTargetStat), STEP_TIMEOUT), false)
            elseif step == 3 then
                SkipCurrentConversion(string.format(
                    "no gossip option matched source '%s' (%s) within %ds - it may have 0 points to give",
                    tostring(activeSourceStat), tostring(activeAmountMode), STEP_TIMEOUT), false)
            end
        end
    end)
end

local function GetSelectedTargets()
    local targets = {}
    for _, cb in ipairs(targetCheckboxes) do
        if cb:GetChecked() then
            table.insert(targets, cb.statName)
        end
    end
    return targets
end

local function ShowSummaryWindow()
    local lines = {}
    table.insert(lines, "|cff00ff00Conversions Completed!|r\n")
    local totalStatsGained = 0
    for stat, amount in pairs(sessionGains) do
        if amount > 0 then
            table.insert(lines, string.format("|cffffd100+ %s %s|r", FormatLargeNumber and FormatLargeNumber(amount) or tostring(amount), stat))
            totalStatsGained = totalStatsGained + 1
        end
    end

    if totalStatsGained == 0 then
        table.insert(lines, "No stat gains detected or popups skipped.")
    end

    if #sessionSkipped > 0 then
        table.insert(lines, "\n|cffff8800Skipped (nothing to convert):|r")
        for _, entry in ipairs(sessionSkipped) do
            table.insert(lines, "|cffaaaaaa" .. entry .. "|r")
        end
    end

    summaryText:SetText(table.concat(lines, "\n"))
    summaryFrame:Show()
end

ProcessNextInQueue = function()
    if #conversionQueue == 0 then
        ResetState()
        SetStatus("Done.")
        ShowSummaryWindow()
        return
    end

    local item = table.remove(conversionQueue, 1)
    activeItem = item
    activeSourceStat = item.source
    activeTargetStat = item.target
    activeAmountMode = item.amountMode
    queueDone = queueDone + 1

    SetStatus(string.format("Converting %d/%d: %s of %s -> %s ...",
        queueDone, queueTotal, activeAmountMode, activeSourceStat, activeTargetStat))

    CloseGossip()
    CloseLoot()

    DelayRun(RESET_DELAY, function()
        currentStep = 1
        SendChatMessage(".ds", "SAY")
        ArmWatchdog(1, "gossip window opening")
    end)
end

local function CleanStatText(text)
    if not text then return "" end
    local clean = string.gsub(text, "%s*%([^%)]*%)", "")
    clean = string.gsub(clean, "^%s*(.-)%s*$", "%1")
    return clean
end

local function ParseGainFromPopupText(text)
    if not text then return false end
    local rawGain, statName = string.match(text, "gain%s+([%d%,]+)%s+([^%?%c]+)")
    if rawGain and statName then
        rawGain = string.gsub(rawGain, ",", "")
        local gainAmount = tonumber(rawGain)
        if gainAmount and activeTargetStat then
            sessionGains[activeTargetStat] = (sessionGains[activeTargetStat] or 0) + gainAmount
        end
        return true
    end
    return false
end

-- Returns true if this popup text looks like the conversion confirmation
-- we're expecting, so we only ever auto-accept popups that are actually
-- ours. This prevents the addon from blind-clicking unrelated popups
-- (ready checks, duel requests, delete-item confirms, etc.) that might
-- happen to appear while a conversion is running.
local function IsExpectedConversionPopup(text)
    if not text then return false end
    if string.find(text, "gain", 1, true) then return true end
    if activeTargetStat and string.find(text, activeTargetStat, 1, true) then return true end
    if activeSourceStat and string.find(text, activeSourceStat, 1, true) then return true end
    return false
end

local function ForceClickAccept()
    for i = 1, STATICPOPUP_NUMDIALOGS do
        local frameName = "StaticPopup" .. i
        local popupFrame = _G[frameName]
        if popupFrame and popupFrame:IsShown() then
            local textObj = _G[frameName .. "Text"]
            local text = textObj and textObj:GetText()
            if IsExpectedConversionPopup(text) then
                ParseGainFromPopupText(text)
                local b1 = _G[frameName .. "Button1"]
                if b1 and b1:IsShown() then
                    b1:Click()
                    return true
                end
                if StaticPopup_OnClick then
                    StaticPopup_OnClick(popupFrame, 1)
                    return true
                end
            elseif debugMode then
                print("|cff888888[AutoStatConverter debug]|r Ignoring unrelated popup: " .. tostring(text))
            end
        end
    end

    return false
end

local function StartPopupClearingTicker()
    local attempts = 0
    if tickerTimer then tickerTimer:Cancel() end

    tickerTimer = C_Timer.NewTicker(0.05, function()
        attempts = attempts + 1
        local clicked = ForceClickAccept()
        if clicked or attempts > 20 then
            tickerTimer:Cancel()
            tickerTimer = nil
            if not clicked then
            end
            CloseGossip()
            DelayRun(STEP_DELAY, ProcessNextInQueue)
        end
    end)
end

-- Builds the conversion list from the current checkbox state without
-- touching any run state. Returns the list, or nil + error message.
local function BuildQueue()
    local selectedTargets = GetSelectedTargets()
    if #selectedTargets == 0 then
        return nil, "Please select at least one target stat."
    end

    local queue = {}

    -- If exactly 2 target stats are selected:
    -- 1) First convert HALF into Target 1
    -- 2) Then convert ALL (remaining half) into Target 2
    if #selectedTargets == 2 then
        local target1 = selectedTargets[1]
        local target2 = selectedTargets[2]

        for _, cb in ipairs(sourceCheckboxes) do
            if cb:GetChecked() then
                if cb.statName ~= target1 then
                    table.insert(queue, { source = cb.statName, target = target1, amountMode = "HALF" })
                end
                if cb.statName ~= target2 then
                    table.insert(queue, { source = cb.statName, target = target2, amountMode = "ALL" })
                end
            end
        end
    else
        -- 1 target stat selected
        local singleTarget = selectedTargets[1]
        local modeStr = modeAll and "ALL" or "HALF"
        for _, cb in ipairs(sourceCheckboxes) do
            if cb:GetChecked() and cb.statName ~= singleTarget then
                table.insert(queue, { source = cb.statName, target = singleTarget, amountMode = modeStr })
            end
        end
    end

    if #queue == 0 then
        return nil, "No valid conversion combinations selected."
    end
    return queue
end

-- Prints the queue that WOULD run, without running it.
local function PreviewQueue()
    local queue, err = BuildQueue()
    if not queue then
        print("|cffff0000[Statty]|r " .. err)
        return
    end
    print(string.format("|cff00ff00[Statty]|r Preview - %d conversion(s) would run in this order:", #queue))
    for i, item in ipairs(queue) do
        print(string.format("  %d. %s of |cffffd100%s|r -> |cffffd100%s|r", i, item.amountMode, item.source, item.target))
    end
    SetStatus(string.format("Preview: %d conversion(s) queued. See chat.", #queue))
end

local function BuildAndStartQueue()
    local queue, err = BuildQueue()
    if not queue then
        print("|cffff0000[Statty]|r " .. err)
        return
    end

    sessionGains = {}
    for _, t in ipairs(GetSelectedTargets()) do
        sessionGains[t] = 0
    end
    sessionSkipped = {}
    conversionQueue = queue
    queueTotal = #queue
    queueDone = 0
    activeItem = nil

    isRunning = true
    ProcessNextInQueue()
end

previewBtn:SetScript("OnClick", PreviewQueue)

-- ============================================================
-- Dungeon-exit countdown window
-- ============================================================
-- Instead of silently firing 3s after you leave a dungeon, show a
-- 10-second countdown with Start Now / Cancel, so stale checkbox
-- settings can't quietly convert the wrong stats.
local countdownTicker = nil

local countdownFrame = CreateFrame("Frame", "ASC_CountdownFrame", UIParent)
countdownFrame:SetSize(280, 110)
countdownFrame:SetPoint("TOP", 0, -140)
countdownFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
countdownFrame:Hide()

local countdownText = countdownFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
countdownText:SetPoint("TOP", 0, -22)

local function StopCountdown()
    if countdownTicker then
        countdownTicker:Cancel()
        countdownTicker = nil
    end
    countdownFrame:Hide()
end

local countdownStartBtn = CreateFrame("Button", nil, countdownFrame, "UIPanelButtonTemplate")
countdownStartBtn:SetSize(100, 24)
countdownStartBtn:SetPoint("BOTTOMLEFT", 25, 18)
countdownStartBtn:SetText("Start Now")
countdownStartBtn:SetScript("OnClick", function()
    StopCountdown()
    if not isRunning then BuildAndStartQueue() end
end)

local countdownCancelBtn = CreateFrame("Button", nil, countdownFrame, "UIPanelButtonTemplate")
countdownCancelBtn:SetSize(100, 24)
countdownCancelBtn:SetPoint("BOTTOMRIGHT", -25, 18)
countdownCancelBtn:SetText("Cancel")
countdownCancelBtn:SetScript("OnClick", function()
    StopCountdown()
    print("|cffff0000[Statty]|r Auto-conversion cancelled.")
end)

local function StartDungeonExitCountdown()
    StopCountdown()
    local remaining = autoCountdown
    countdownText:SetText("Auto-converting stats in " .. remaining .. "s...")
    countdownFrame:Show()
    countdownTicker = C_Timer.NewTicker(1, function()
        remaining = remaining - 1
        if remaining <= 0 then
            StopCountdown()
            if not isRunning then BuildAndStartQueue() end
        else
            countdownText:SetText("Auto-converting stats in " .. remaining .. "s...")
        end
    end, autoCountdown)
end

frame:RegisterEvent("GOSSIP_SHOW")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("ADDON_LOADED")

frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon == ADDON_NAME then
            local db = AutoStatConverterDB
            if db.modeAll ~= nil then modeAll = db.modeAll end
            if db.autoLeaveDungeon ~= nil then
                autoLeaveDungeon = db.autoLeaveDungeon
                autoDungeonCB:SetChecked(autoLeaveDungeon)
            end
            if db.debugMode ~= nil then debugMode = db.debugMode end
            if db.retryEnabled ~= nil then retryEnabled = db.retryEnabled end
            if db.autoCountdown ~= nil then autoCountdown = db.autoCountdown end
            if db.match then
                MATCH.CONVERT_MENU = db.match.CONVERT_MENU or MATCH.CONVERT_MENU
                MATCH.HALF = db.match.HALF or MATCH.HALF
                MATCH.ALL = db.match.ALL or MATCH.ALL
            end
            if db.minimapAngle ~= nil then minimapAngle = db.minimapAngle end
            modeBtn:SetText(modeAll and "Amount: ALL" or "Amount: HALF")

            if db.targets then
                for i, checked in pairs(db.targets) do
                    if targetCheckboxes[i] then targetCheckboxes[i]:SetChecked(checked) end
                end
            end
            if db.sources then
                for i, checked in pairs(db.sources) do
                    if sourceCheckboxes[i] then sourceCheckboxes[i]:SetChecked(checked) end
                end
            end
            if UpdateMinimapButtonPosition then UpdateMinimapButtonPosition() end
            if ASC_InitOptionsPanel then ASC_InitOptionsPanel() end
            if ASC_RefreshOptionsPanel then ASC_RefreshOptionsPanel() end
        end
        return
    end

    if event == "ZONE_CHANGED_NEW_AREA" or event == "PLAYER_ENTERING_WORLD" then
        local inInstance, instanceType = IsInInstance()
        if inInstance and (instanceType == "party" or instanceType == "raid") then
            wasInInstance = true
        elseif wasInInstance and not inInstance then
            wasInInstance = false
            if autoLeaveDungeon then
                StartDungeonExitCountdown()
            end
        end
        return
    end

    if not isRunning then return end

    if event == "GOSSIP_SHOW" then
        local options = { GetGossipOptions() }
        if debugMode then
            print("|cff888888[AutoStatConverter debug]|r GOSSIP_SHOW step " .. currentStep .. ", options:")
            for i = 1, #options, 2 do
                print("  " .. tostring(options[i]))
            end
        end

        -- Step 1: Click "Convert stats"
        if currentStep == 1 then
            for i = 1, #options, 2 do
                if options[i] == MATCH.CONVERT_MENU then
                    currentStep = 2
                    ArmWatchdog(2, "matching target stat option")
                    DelayRun(STEP_DELAY, function() SelectGossipOption((i + 1) / 2) end)
                    return
                end
            end

        -- Step 2: Click Target Stat
        elseif currentStep == 2 then
            for i = 1, #options, 2 do
                local textClean = CleanStatText(options[i])
                if textClean == activeTargetStat or string.find(options[i], activeTargetStat, 1, true) then
                    currentStep = 3
                    ArmWatchdog(3, "matching source stat / amount option")
                    DelayRun(STEP_DELAY, function() SelectGossipOption((i + 1) / 2) end)
                    return
                end
            end

        -- Step 3: Click matching Source Stat entry matching activeAmountMode ("HALF" or "ALL")
        elseif currentStep == 3 then
            for i = 1, #options, 2 do
                local text = options[i]
                if string.find(text, activeSourceStat, 1, true) and string.find(text, MATCH[activeAmountMode], 1, true) then
                    currentStep = 4
                    CancelWatchdog()
                    DelayRun(STEP_DELAY, function()
                        SelectGossipOption((i + 1) / 2)
                        StartPopupClearingTicker()
                    end)
                    return
                end
            end
            -- No option matched our source stat. Before skipping, make sure
            -- this really is the source-selection page and not some other
            -- gossip page that fired in between: the source page is the one
            -- whose options carry the amount keyword ("HALF"/"ALL"). The
            -- server omits stats with 0 points to give, so if the page is
            -- confirmed and our stat isn't on it, skip immediately instead
            -- of letting the watchdog wait out its full timeout.
            local isSourcePage = false
            for i = 1, #options, 2 do
                if string.find(options[i], MATCH[activeAmountMode], 1, true) then
                    isSourcePage = true
                    break
                end
            end
            if isSourcePage then
                SkipCurrentConversion("not listed in the menu (0 points to give?)", true)
                return
            end
        end
    end
end)

-- Start Button
local startBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
startBtn:SetSize(140, 25)
startBtn:SetPoint("BOTTOMRIGHT", -20, 18)
startBtn:SetText("Start Conversion")
startBtn:SetScript("OnClick", function()
    if isRunning then ResetState() end
    BuildAndStartQueue()
end)

-- Cancel Button (new: lets the user bail out of a stuck/running queue)
local cancelBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
cancelBtn:SetSize(100, 25)
cancelBtn:SetPoint("RIGHT", startBtn, "LEFT", -8, 0)
cancelBtn:SetText("Cancel")
cancelBtn:SetScript("OnClick", function()
    if isRunning then
        ResetState()
        print("|cffff0000[Statty]|r Conversion cancelled.")
        SetStatus("Cancelled.")
    end
end)

-- ============================================================
-- Profiles (named checkbox setups, e.g. "tank", "pvp")
-- ============================================================
local function SnapshotProfile()
    local prof = { modeAll = modeAll, autoLeaveDungeon = autoLeaveDungeon, targets = {}, sources = {} }
    for i, cb in ipairs(targetCheckboxes) do prof.targets[i] = cb:GetChecked() and true or false end
    for i, cb in ipairs(sourceCheckboxes) do prof.sources[i] = cb:GetChecked() and true or false end
    return prof
end

local function ApplyProfile(prof)
    modeAll = prof.modeAll and true or false
    autoLeaveDungeon = prof.autoLeaveDungeon and true or false
    modeBtn:SetText(modeAll and "Amount: ALL" or "Amount: HALF")
    autoDungeonCB:SetChecked(autoLeaveDungeon)
    for i, cb in ipairs(targetCheckboxes) do cb:SetChecked(prof.targets and prof.targets[i]) end
    for i, cb in ipairs(sourceCheckboxes) do cb:SetChecked(prof.sources and prof.sources[i]) end
    SaveSettings()
end

local function GetProfiles()
    AutoStatConverterDB.profiles = AutoStatConverterDB.profiles or {}
    return AutoStatConverterDB.profiles
end

-- Slash Commands
SLASH_AUTOSTATCONVERTER1 = "/asc"
SLASH_AUTOSTATCONVERTER2 = "/statty"
SlashCmdList["AUTOSTATCONVERTER"] = function(msg)
    msg = (msg or ""):match("^%s*(.-)%s*$")
    local cmd, arg = msg:match("^(%S+)%s*(.-)$")
    cmd = (cmd or ""):lower()
    arg = arg or ""

    if cmd == "debug" then
        debugMode = not debugMode
        SaveSettings()
        print("|cff00ff00[Statty]|r Debug mode " .. (debugMode and "ON" or "OFF") ..
            " - gossip option text will be printed to chat to help diagnose stalls.")
        return

    elseif cmd == "preview" then
        PreviewQueue()
        return

    elseif cmd == "options" or cmd == "config" then
        if ASC_OpenOptions then ASC_OpenOptions() end
        return

    elseif cmd == "auto" then
        if ASC_ToggleAutoWindow then ASC_ToggleAutoWindow() end
        return

    elseif cmd == "release" then
        local B = _G.ASC_AutoBridge
        if B and B.IsOwned and B.IsOwned() then
            B.ReleaseOwnership()
            print("|cff00ff00[Statty]|r Released the conversion plan. Statty will no longer re-apply it; the Progress tab now controls it freely. (This did not change the plan on the server - use the Auto window to turn it off if you want.)")
        else
            print("|cffffaa00[Statty]|r Statty isn't currently owning a plan.")
        end
        return

    elseif cmd == "plan" then
        local B = _G.ASC_AutoBridge
        local plan = B and B.GetPlan()
        if not plan then
            print("|cffffaa00[Statty]|r No automatic-spending plan is confirmed yet. Open the Auto % window or the Stat Feed controls, set one and Save.")
            return
        end
        local feeders, receivers = {}, {}
        for n = 1, 8 do
            if plan.dump[n] then table.insert(feeders, B.STATS[n]) end
            if (plan.w[n] or 0) > 0 then table.insert(receivers, B.STATS[n] .. " " .. plan.w[n] .. "%") end
        end
        print("|cff00ff00[Statty]|r Automatic spending is " .. (plan.enabled and "|cff00ff00ON|r" or "|cffff8800OFF|r") .. ":")
        print("  Feeds (red): " .. (#feeders > 0 and table.concat(feeders, ", ") or "|cffff4444none - nothing will convert!|r"))
        print("  Receives (green): " .. (#receivers > 0 and table.concat(receivers, ", ") or "|cffff4444none|r"))
        return

    elseif cmd == "minimap" then
        -- Rescue command: put the button back at the default angle and say
        -- where it should be, for when it's hiding under another UI element.
        minimapAngle = 45
        if UpdateMinimapButtonPosition then UpdateMinimapButtonPosition() end
        SaveSettings()
        print("|cff00ff00[Statty]|r Minimap button reset to the top-right of the minimap (45\194\176).")
        return

    elseif cmd == "save" then
        if arg == "" then
            print("|cffff0000[Statty]|r Usage: /asc save <name>")
            return
        end
        GetProfiles()[arg:lower()] = SnapshotProfile()
        print("|cff00ff00[Statty]|r Profile '" .. arg:lower() .. "' saved.")
        return

    elseif cmd == "load" then
        local prof = GetProfiles()[arg:lower()]
        if not prof then
            print("|cffff0000[Statty]|r No profile named '" .. arg:lower() .. "'. Use /asc profiles to list.")
            return
        end
        ApplyProfile(prof)
        print("|cff00ff00[Statty]|r Profile '" .. arg:lower() .. "' loaded.")
        return

    elseif cmd == "delete" then
        local profiles = GetProfiles()
        if profiles[arg:lower()] then
            profiles[arg:lower()] = nil
            print("|cff00ff00[Statty]|r Profile '" .. arg:lower() .. "' deleted.")
        else
            print("|cffff0000[Statty]|r No profile named '" .. arg:lower() .. "'.")
        end
        return

    elseif cmd == "profiles" then
        local names = {}
        for name in pairs(GetProfiles()) do table.insert(names, name) end
        table.sort(names)
        if #names == 0 then
            print("|cffffaa00[Statty]|r No saved profiles. Use /asc save <name>.")
        else
            print("|cff00ff00[Statty]|r Profiles: " .. table.concat(names, ", "))
        end
        return

    elseif cmd == "help" then
        print("|cff00ff00[Statty]|r Commands:")
        print("  /asc - toggle the window")
        print("  /asc preview - show what would be converted, without running")
        print("  /asc options - open the Interface Options panel")
        print("  /asc auto - open the Automatic Stat Spending (percentages) window")
        print("  /asc plan - show your current automatic-spending plan")
        print("  /asc release - stop Statty re-applying the plan (hand control back to Progress)")
        print("  /asc minimap - reset the minimap button position")
        print("  /asc save <name> / load <name> / delete <name> / profiles - manage setups")
        print("  /asc debug - toggle diagnostic logging of gossip text")
        return
    end

    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
    end
end

-- Minimap Button Setup
-- Parented to UIParent, NOT Minimap: on reskinned/scaled minimaps (the
-- Uncapped ring-of-slots skin) a Minimap child can have its mouse events
-- eaten or be clipped, which is why the button wouldn't drag. It still
-- anchors relative to Minimap via SetPoint in UpdateMinimapButtonPosition.
local minimapBtn = CreateFrame("Button", "ASC_MinimapButton", UIParent)
minimapBtn:SetSize(33, 33)
minimapBtn:SetFrameStrata("HIGH")
minimapBtn:SetFrameLevel(20)
minimapBtn:SetToplevel(true)

local minimapIcon = minimapBtn:CreateTexture(nil, "BACKGROUND")
minimapIcon:SetTexture("Interface\\Icons\\Spell_Holy_MagicalSentry")
minimapIcon:SetSize(21, 21)
minimapIcon:SetPoint("CENTER")

local minimapBorder = minimapBtn:CreateTexture(nil, "OVERLAY")
minimapBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
minimapBorder:SetSize(54, 54)
minimapBorder:SetPoint("TOPLEFT", 0, 0)

-- Minimap Position & Dragging Logic
-- NOTE: minimapAngle is stored in DEGREES for readability/saving; it is
-- converted to radians only at the point math.cos/math.sin need it.
-- (Previously the raw degree value was fed directly into math.cos/sin,
-- which expect radians, causing the button to spawn at the wrong spot.)
minimapAngle = 45

function UpdateMinimapButtonPosition()
    -- Radius follows the actual minimap size instead of assuming the stock
    -- 140px circle - custom UIs (the Uncapped client reskins plenty) resize
    -- it, and a fixed 80 can put the button under other elements or oddly
    -- far off the ring.
    local half = (Minimap:GetWidth() or 140) / 2
    local radius = half + 10
    if radius < 20 then radius = 80 end
    local rad = math.rad(minimapAngle)
    local x = math.cos(rad) * radius
    local y = math.sin(rad) * radius
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", x, y)
    minimapBtn:Show()
end

UpdateMinimapButtonPosition()

minimapBtn:EnableMouse(true)
minimapBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

-- Dragging is done manually with OnMouseDown/OnUpdate/OnMouseUp rather than
-- RegisterForDrag. On 3.3.5a, RegisterForDrag on a Button that also has
-- RegisterForClicks is unreliable - the click registration swallows the
-- press and the drag never starts, which is why the button appeared stuck.
-- Trigger is SHIFT + RIGHT-button so it can never be confused with the plain
-- left/right clicks or shift+left.
local minimapDragging = false

local function MinimapUpdateDrag(self)
    -- Work in UIParent coordinates so minimap scale is irrelevant.
    -- Minimap:GetCenter() is in the minimap's own frame space; multiply by its
    -- effective scale to get UIParent-space pixels. The cursor from
    -- GetCursorPosition() is in screen pixels; divide by UIParent's effective
    -- scale for the same space.
    local mScale = Minimap:GetEffectiveScale()
    local uScale = UIParent:GetEffectiveScale()
    local mx, my = Minimap:GetCenter()
    if not mx then return end
    mx, my = mx * mScale / uScale, my * mScale / uScale
    local cx, cy = GetCursorPosition()
    cx, cy = cx / uScale, cy / uScale
    minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
    UpdateMinimapButtonPosition()
end

minimapBtn:SetScript("OnMouseDown", function(self, button)
    if button == "RightButton" and IsShiftKeyDown() then
        minimapDragging = true
        self:SetScript("OnUpdate", MinimapUpdateDrag)
    end
end)

minimapBtn:SetScript("OnMouseUp", function(self, button)
    if minimapDragging then
        minimapDragging = false
        self:SetScript("OnUpdate", nil)
        SaveSettings()
    end
end)

-- One button for the whole addon:
--   Left            = converter window
--   Shift+Left      = Automatic Stat Spending (Auto %)
--   Right           = Stat Feed window
--   Shift+Right     = drag to move the button
-- Clicks that complete a drag are ignored (minimapDragging guard).
minimapBtn:SetScript("OnClick", function(self, button)
    if minimapDragging then return end
    if button == "LeftButton" then
        if IsShiftKeyDown() and ASC_ToggleAutoWindow then
            ASC_ToggleAutoWindow()
        elseif frame:IsShown() then
            frame:Hide()
        else
            frame:Show()
        end
    elseif button == "RightButton" then
        -- Shift+Right is the drag gesture, not a Stat Feed toggle.
        if not IsShiftKeyDown() and StatFeedQoL_API and StatFeedQoL_API.Toggle then
            StatFeedQoL_API.Toggle()
        end
    end
end)

minimapBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("Statty")
    GameTooltip:AddLine("Left: Converter  |  Shift+Left: Auto %", 1, 1, 1)
    GameTooltip:AddLine("Right: Stat Feed  |  Shift+Right-drag: move", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("/asc help for commands (preview, profiles, debug)", 0.5, 0.8, 1)
    GameTooltip:Show()
end)

minimapBtn:SetScript("OnLeave", function(self)
    GameTooltip:Hide()
end)

-- ============================================================
-- Interface Options panel (Esc > Interface > AddOns tab)
-- ============================================================
local optionsPanel = CreateFrame("Frame", "ASC_OptionsPanel", UIParent)
optionsPanel.name = "Auto Stat Converter"

local optTitle = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
optTitle:SetPoint("TOPLEFT", 16, -16)
optTitle:SetText("Converter")

local optSub = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
optSub:SetPoint("TOPLEFT", optTitle, "BOTTOMLEFT", 0, -6)
optSub:SetPoint("RIGHT", optionsPanel, "RIGHT", -180, 0)
optSub:SetJustifyH("LEFT")
optSub:SetText("Pick source/target stats in the converter window (/asc or minimap button).")

-- Keeps the main window's widgets in step with option changes
local function SyncMainUI()
    modeBtn:SetText(modeAll and "Amount: ALL" or "Amount: HALF")
    autoDungeonCB:SetChecked(autoLeaveDungeon)
end

local function MakeOptionCheckbox(name, label, tooltip, anchor, yOff, getter, setter)
    local cb = CreateFrame("CheckButton", name, optionsPanel, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
    _G[name .. "Text"]:SetText(label)
    cb.tooltipText = tooltip
    cb.Get = getter
    cb:SetScript("OnClick", function(self)
        setter(self:GetChecked() and true or false)
        SaveSettings()
        SyncMainUI()
    end)
    return cb
end

local cbAmountAll = MakeOptionCheckbox("ASC_OptAmountAll",
    "Convert ALL of each source stat (unchecked = HALF)",
    "Amount used when a single target stat is selected. With two targets the HALF/ALL split is always used.",
    optSub, -12,
    function() return modeAll end,
    function(v) modeAll = v end)

local cbAutoDungeon = MakeOptionCheckbox("ASC_OptAutoDungeon",
    "Auto-convert after leaving a dungeon or raid",
    "Shows a cancellable countdown window after you exit an instance.",
    cbAmountAll, -4,
    function() return autoLeaveDungeon end,
    function(v) autoLeaveDungeon = v end)

local cbRetry = MakeOptionCheckbox("ASC_OptRetry",
    "Retry timed-out conversions once at the end of the queue",
    "Conversions skipped because of lag/timeouts get one more attempt. Stats confirmed to have 0 points are never retried.",
    cbAutoDungeon, -4,
    function() return retryEnabled end,
    function(v) retryEnabled = v end)

local cbDebug = MakeOptionCheckbox("ASC_OptDebug",
    "Debug mode (print gossip option text to chat)",
    "Helps diagnose stalls when the server's gossip wording doesn't match.",
    cbRetry, -4,
    function() return debugMode end,
    function(v) debugMode = v end)

-- Countdown slider
local countdownSlider = CreateFrame("Slider", "ASC_OptCountdownSlider", optionsPanel, "OptionsSliderTemplate")
countdownSlider:SetPoint("TOPLEFT", cbDebug, "BOTTOMLEFT", 8, -28)
countdownSlider:SetWidth(220)
countdownSlider:SetMinMaxValues(3, 30)
countdownSlider:SetValueStep(1)
_G["ASC_OptCountdownSliderLow"]:SetText("3s")
_G["ASC_OptCountdownSliderHigh"]:SetText("30s")
countdownSlider:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value + 0.5)
    if value ~= autoCountdown then
        autoCountdown = value
        SaveSettings()
    end
    _G["ASC_OptCountdownSliderText"]:SetText("Dungeon-exit countdown: " .. value .. "s")
end)

-- Gossip match strings
local matchHeader = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
matchHeader:SetPoint("TOPLEFT", countdownSlider, "BOTTOMLEFT", -8, -24)
matchHeader:SetText("Gossip text matching")

local matchSub = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
matchSub:SetPoint("TOPLEFT", matchHeader, "BOTTOMLEFT", 0, -3)
matchSub:SetPoint("RIGHT", optionsPanel, "RIGHT", -32, 0)
matchSub:SetJustifyH("LEFT")
matchSub:SetTextColor(0.7, 0.7, 0.7)
matchSub:SetText("Edit these only if your server words its menu differently.")

local matchBoxes = {}
local function MakeMatchBox(key, label, anchor, yOff)
    local lbl = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
    lbl:SetText(label)
    local eb = CreateFrame("EditBox", "ASC_OptMatch" .. key, optionsPanel, "InputBoxTemplate")
    eb:SetSize(170, 20)
    eb:SetPoint("LEFT", lbl, "LEFT", 200, 0)
    eb:SetAutoFocus(false)
    eb:SetText(MATCH[key]) -- never leave the box looking empty
    local function commit(self)
        local text = self:GetText():match("^%s*(.-)%s*$")
        if text ~= "" then
            MATCH[key] = text
            SaveSettings()
        else
            self:SetText(MATCH[key])
        end
        self:ClearFocus()
    end
    eb:SetScript("OnEnterPressed", commit)
    eb:SetScript("OnEditFocusLost", commit)
    eb:SetScript("OnEscapePressed", function(self) self:SetText(MATCH[key]); self:ClearFocus() end)
    matchBoxes[key] = eb
    return lbl
end

local m1 = MakeMatchBox("CONVERT_MENU", "Top-level menu option (exact):", matchSub, -10)
local m2 = MakeMatchBox("HALF", "Keyword for 'convert half' options:", m1, -14)
local m3 = MakeMatchBox("ALL", "Keyword for 'convert all' options:", m2, -14)

-- Profiles
local profileHeader = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
profileHeader:SetPoint("TOPLEFT", m3, "BOTTOMLEFT", 0, -24)
profileHeader:SetText("Profiles (saved checkbox setups)")

local selectedProfile = nil
local profileDropdown = CreateFrame("Frame", "ASC_OptProfileDropdown", optionsPanel, "UIDropDownMenuTemplate")
profileDropdown:SetPoint("TOPLEFT", profileHeader, "BOTTOMLEFT", -16, -8)

local function ProfileDropdown_Refresh()
    UIDropDownMenu_SetText(profileDropdown, selectedProfile or "Select profile...")
end

-- NOTE: UIDropDownMenu_Initialize must NOT run at file scope on 3.3.5a -
-- it executes the init function immediately, before ADDON_LOADED / saved
-- variables exist. Deferred into ASC_InitOptionsPanel below, which the
-- ADDON_LOADED handler calls exactly once.
local optionsPanelInitialized = false
function ASC_InitOptionsPanel()
    if optionsPanelInitialized then return end
    optionsPanelInitialized = true
    UIDropDownMenu_Initialize(profileDropdown, function()
        local names = {}
        for name in pairs(GetProfiles()) do table.insert(names, name) end
        table.sort(names)
        for _, name in ipairs(names) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = name
            info.value = name
            info.checked = (name == selectedProfile)
            info.func = function(self)
                selectedProfile = self.value
                UIDropDownMenu_SetSelectedValue(profileDropdown, self.value)
                ProfileDropdown_Refresh()
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    UIDropDownMenu_SetWidth(profileDropdown, 140)
    ProfileDropdown_Refresh()
end

local loadProfileBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
loadProfileBtn:SetSize(60, 22)
loadProfileBtn:SetPoint("LEFT", profileDropdown, "RIGHT", -8, 2)
loadProfileBtn:SetText("Load")
loadProfileBtn:SetScript("OnClick", function()
    local prof = selectedProfile and GetProfiles()[selectedProfile]
    if prof then
        ApplyProfile(prof)
        SyncMainUI()
        print("|cff00ff00[Statty]|r Profile '" .. selectedProfile .. "' loaded.")
        if ASC_RefreshOptionsPanel then ASC_RefreshOptionsPanel() end
    end
end)

local deleteProfileBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
deleteProfileBtn:SetSize(60, 22)
deleteProfileBtn:SetPoint("LEFT", loadProfileBtn, "RIGHT", 4, 0)
deleteProfileBtn:SetText("Delete")
deleteProfileBtn:SetScript("OnClick", function()
    if selectedProfile and GetProfiles()[selectedProfile] then
        print("|cff00ff00[Statty]|r Profile '" .. selectedProfile .. "' deleted.")
        GetProfiles()[selectedProfile] = nil
        selectedProfile = nil
        ProfileDropdown_Refresh()
    end
end)

local newProfileBox = CreateFrame("EditBox", "ASC_OptNewProfile", optionsPanel, "InputBoxTemplate")
newProfileBox:SetSize(140, 20)
newProfileBox:SetPoint("TOPLEFT", profileDropdown, "BOTTOMLEFT", 22, -8)
newProfileBox:SetAutoFocus(false)
newProfileBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local function SaveCurrentAsProfile()
    local name = newProfileBox:GetText():match("^%s*(.-)%s*$"):lower()
    if name == "" then
        print("|cffff0000[Statty]|r Enter a profile name first.")
        return
    end
    GetProfiles()[name] = SnapshotProfile()
    selectedProfile = name
    ProfileDropdown_Refresh()
    newProfileBox:SetText("")
    newProfileBox:ClearFocus()
    print("|cff00ff00[Statty]|r Profile '" .. name .. "' saved.")
end
newProfileBox:SetScript("OnEnterPressed", SaveCurrentAsProfile)

local saveProfileBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
saveProfileBtn:SetSize(124, 22)
saveProfileBtn:SetPoint("LEFT", newProfileBox, "RIGHT", 4, 0)
saveProfileBtn:SetText("Save current as")
saveProfileBtn:SetScript("OnClick", SaveCurrentAsProfile)

-- Open main window button
local openWindowBtn = CreateFrame("Button", nil, optionsPanel, "UIPanelButtonTemplate")
openWindowBtn:SetSize(160, 24)
openWindowBtn:SetPoint("TOPRIGHT", optionsPanel, "TOPRIGHT", -16, -16)
openWindowBtn:SetText("Converter Window")
openWindowBtn:SetScript("OnClick", function() frame:Show() end)

-- Sync all widgets from current state (used on show / after loads)
function ASC_RefreshOptionsPanel()
    cbAmountAll:SetChecked(modeAll)
    cbAutoDungeon:SetChecked(autoLeaveDungeon)
    cbRetry:SetChecked(retryEnabled)
    cbDebug:SetChecked(debugMode)
    countdownSlider:SetValue(autoCountdown)
    _G["ASC_OptCountdownSliderText"]:SetText("Dungeon-exit countdown: " .. autoCountdown .. "s")
    matchBoxes.CONVERT_MENU:SetText(MATCH.CONVERT_MENU)
    matchBoxes.HALF:SetText(MATCH.HALF)
    matchBoxes.ALL:SetText(MATCH.ALL)
    ProfileDropdown_Refresh()
end

optionsPanel:SetScript("OnShow", ASC_RefreshOptionsPanel)

-- Blizzard options integration
optionsPanel.default = function()
    MATCH.CONVERT_MENU = DEFAULT_MATCH.CONVERT_MENU
    MATCH.HALF = DEFAULT_MATCH.HALF
    MATCH.ALL = DEFAULT_MATCH.ALL
    autoCountdown = 10
    retryEnabled = true
    SaveSettings()
    ASC_RefreshOptionsPanel()
end

-- Registered by QoLBridge.lua as a CHILD of the "Uncapped QoL" category, so
-- the parent exists first. Standalone fallback kept for a toc that ships this
-- file alone.
optionsPanel.name = "Converter"
_G.ASC_OptionsPanel = optionsPanel
_G.ASC_RegisterOptionsStandalone = function()
    if InterfaceOptions_AddCategory then
        optionsPanel.name = "Auto Stat Converter"
        InterfaceOptions_AddCategory(optionsPanel)
    end
end

function ASC_OpenOptions()
    if InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(optionsPanel)
    elseif InterfaceOptionsFrame_OpenToFrame then
        InterfaceOptionsFrame_OpenToFrame(optionsPanel)
    end
end

-- ============================================================
-- Automatic stat spending (percentages) - ported from the
-- Uncapped Dashboard's Progress tab editor [#1193].
-- ============================================================
-- The server-side plan: tick stats to DUMP as they are earned, give the
-- others percentage SHARES totalling exactly 100, and the server converts
-- future earnings automatically at the same rate the .ds window charges.
-- Wire: DSAGET -> DSACFG + DSAPEND (or DSAERR); DSASET stores a plan and
-- answers with the same pair reflecting what is now STORED, never an echo.
-- Banked stats are untouched by this - that's what the converter queue is for.

local ASC_TRANSPORT_PREFIX = "REAGENTBANK" -- client -> server
local ASC_PIPE_PREFIX      = "UNC"         -- server -> client

-- Wire order. Positional in DSACFG/DSAPEND/DSASET - DO NOT REORDER.
local ESSENCE_STATS = {
    "Strength", "Agility", "Stamina", "Intellect",
    "Spirit", "Defense Rating", "Spell Power", "Expertise",
}

local autoPlan  = nil   -- last DSACFG the server confirmed { rate, enabled, dump[8], w[8] }
local autoDraft = nil   -- unsaved edits, same shape; nil = no edits
local autoPend  = nil   -- DSAPEND remainders
local autoError = nil   -- server refusal (verbatim) or local validation text
local autoWaiting = false
local autoWaited  = 0

-- Ownership (option 2): when the player saves a plan with Auto ON, Statty
-- remembers it as the INTENDED plan and keeps the server matching it, so the
-- Progress tab (or anything else) can't silently disable or change the one
-- shared server-side plan without Statty putting it back. Persisted so intent
-- survives relog. nil = Statty is not asserting ownership (Auto was saved OFF,
-- or never set).
local autoOwned = nil          -- { enabled=true, dump[8], w[8] } the player committed to
local autoHeartbeat = 0        -- seconds since last DSAGET poll
local autoAssertGrace = 0      -- seconds to wait for a confirm after we re-assert
local AUTO_POLL_EVERY = 8      -- how often to check the server still matches
local AUTO_ASSERT_WAIT = 5     -- after re-asserting, don't re-assert again this long

local function AutoSend(msg)
    SendAddonMessage(ASC_TRANSPORT_PREFIX, msg, "WHISPER", UnitName("player"))
end

-- The draft the player is editing, seeded from the confirmed plan the first
-- time they touch anything. Never seeded from nothing: a blank editor would
-- let someone Save a plan they never wrote.
local function AutoDraftGet()
    if autoDraft then return autoDraft end
    local src = autoPlan or { enabled = false, dump = {}, w = {} }
    local d = { enabled = src.enabled and true or false, dump = {}, w = {}, mark = {} }
    for n = 1, 8 do
        d.dump[n] = src.dump[n] and true or false
        d.w[n] = tonumber(src.w[n]) or 0
        -- mark[] is client-side only (never on the wire): a stat the player
        -- has flagged as a receiver even before typing its share. A marked
        -- stat with no share blocks Save instead of silently meaning "unset".
        d.mark[n] = d.w[n] > 0
    end
    autoDraft = d
    return d
end

local function AutoTotal(d)
    local t = 0
    for n = 1, 8 do t = t + (d.w[n] or 0) end
    return t
end

-- The same three rules the server enforces, checked here only to decide
-- whether Save is clickable. NOT a second implementation: the server still
-- refuses, and its sentence is what the player is shown.
local function AutoWhyNotSaveable(d)
    local anyDump, anyTarget = false, false
    for n = 1, 8 do
        if d.dump[n] then anyDump = true end
        if (d.w[n] or 0) > 0 then
            anyTarget = true
            if d.dump[n] then
                return string.format("%s cannot be both dumped and a target.", ESSENCE_STATS[n])
            end
        end
    end
    if not anyDump then return "Tick at least one stat to dump." end
    if not anyTarget then return "Give at least one stat a share." end
    if d.mark then
        for n = 1, 8 do
            if d.mark[n] and not d.dump[n] and (d.w[n] or 0) == 0 then
                return string.format("%s is marked to receive but has no share yet.", ESSENCE_STATS[n])
            end
        end
    end
    local total = AutoTotal(d)
    if total ~= 100 then
        return string.format("Shares total %d%% -- they have to total exactly 100%%.", total)
    end
    return nil
end

-- ------------------------------------------------------------
-- The window
-- ------------------------------------------------------------
local autoFrame = CreateFrame("Frame", "ASC_AutoFrame", UIParent)
autoFrame:SetSize(540, 250)
autoFrame:SetPoint("CENTER", 60, 40)
autoFrame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 }
})
autoFrame:SetMovable(true)
autoFrame:EnableMouse(true)
autoFrame:RegisterForDrag("LeftButton")
autoFrame:SetScript("OnDragStart", autoFrame.StartMoving)
autoFrame:SetScript("OnDragStop", autoFrame.StopMovingOrSizing)
autoFrame:Hide()
table.insert(UISpecialFrames, "ASC_AutoFrame")

local autoTitle = autoFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
autoTitle:SetPoint("TOP", 0, -16)
autoTitle:SetText("Automatic Stat Spending")

local autoClose = CreateFrame("Button", nil, autoFrame, "UIPanelCloseButton")
autoClose:SetPoint("TOPRIGHT", -6, -6)

local autoStatus = autoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
autoStatus:SetPoint("BOTTOMLEFT", 20, 44)
autoStatus:SetPoint("RIGHT", autoFrame, "RIGHT", -20, 0)
autoStatus:SetJustifyH("LEFT")

local autoUI = { rows = {} }
local AutoRefresh -- forward

local CELL_H, COL_W = 24, 250
for n = 1, 8 do
    local col = (n <= 4) and 0 or 1
    local rowIdx = (n <= 4) and (n - 1) or (n - 5)
    local x = 24 + col * COL_W
    local y = -44 - (rowIdx * CELL_H)

    local r = {}
    -- Named: UICheckButtonTemplate hangs its hit-highlight off $parent globals.
    r.check = CreateFrame("CheckButton", "ASC_AutoDump" .. n, autoFrame, "UICheckButtonTemplate")
    r.check:SetSize(22, 22)
    r.check:SetPoint("TOPLEFT", autoFrame, "TOPLEFT", x, y)
    r.check:SetScript("OnClick", function(self)
        local d = AutoDraftGet()
        d.dump[n] = self:GetChecked() and true or false
        -- Dumping and feeding are mutually exclusive server-side, so ticking
        -- dump clears the share rather than building a plan that can only be
        -- refused.
        if d.dump[n] then d.w[n] = 0 end
        autoError = nil
        AutoRefresh()
    end)

    r.label = autoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.label:SetPoint("LEFT", r.check, "RIGHT", 2, 0)
    r.label:SetWidth(100)
    r.label:SetJustifyH("LEFT")
    r.label:SetText(ESSENCE_STATS[n])

    r.pct = CreateFrame("EditBox", "ASC_AutoPct" .. n, autoFrame, "InputBoxTemplate")
    r.pct:SetSize(36, 18)
    r.pct:SetPoint("LEFT", r.label, "RIGHT", 8, 0)
    r.pct:SetAutoFocus(false)
    r.pct:SetNumeric(true)
    r.pct:SetMaxLetters(3)
    r.pct:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    r.pct:SetScript("OnTextChanged", function(self)
        local d = AutoDraftGet()
        local v = tonumber(self:GetText() or "") or 0
        if v > 100 then v = 100 end
        d.w[n] = v
        autoError = nil
        -- Footer only. A full refresh here would SetText the focused box,
        -- which on 3.3.5a moves the cursor to the end on every keystroke.
        if autoUI.RefreshFooter then autoUI.RefreshFooter() end
    end)

    r.suffix = autoFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    r.suffix:SetPoint("LEFT", r.pct, "RIGHT", 2, 0)
    r.suffix:SetText("%")

    autoUI.rows[n] = r
end

autoUI.enable = CreateFrame("CheckButton", "ASC_AutoEnable", autoFrame, "UICheckButtonTemplate")
autoUI.enable:SetSize(22, 22)
autoUI.enable:SetPoint("TOPLEFT", autoFrame, "TOPLEFT", 24, -44 - 4 * CELL_H - 6)
autoUI.enable:SetScript("OnClick", function(self)
    AutoDraftGet().enabled = self:GetChecked() and true or false
    autoError = nil
    AutoRefresh()
end)

autoUI.enableLabel = autoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
autoUI.enableLabel:SetPoint("LEFT", autoUI.enable, "RIGHT", 2, 0)
autoUI.enableLabel:SetText("Spend automatically")

autoUI.total = autoFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
autoUI.total:SetPoint("LEFT", autoUI.enableLabel, "RIGHT", 20, 0)

autoUI.save = CreateFrame("Button", nil, autoFrame, "UIPanelButtonTemplate")
autoUI.save:SetSize(80, 22)
autoUI.save:SetPoint("TOPRIGHT", autoFrame, "TOPRIGHT", -24, -44 - 4 * CELL_H - 6)
autoUI.save:SetText("Save")

-- Serialize + send a plan table straight to the server. Shared by Save and by
-- the ownership heartbeat; does not read or write the draft.
local function AutoSendPlan(plan)
    local mask = 0
    for n = 1, 8 do
        if plan.dump[n] then mask = mask + 2 ^ (n - 1) end
    end
    AutoSend(string.format("DSASET:%d:%d:%d:%d:%d:%d:%d:%d:%d:%d",
        plan.enabled and 1 or 0, mask,
        plan.w[1] or 0, plan.w[2] or 0, plan.w[3] or 0, plan.w[4] or 0,
        plan.w[5] or 0, plan.w[6] or 0, plan.w[7] or 0, plan.w[8] or 0))
end

-- Snapshot a plan-shaped table (deep enough: two flat arrays + a flag).
local function AutoClonePlan(src)
    local c = { enabled = src.enabled and true or false, dump = {}, w = {} }
    for n = 1, 8 do
        c.dump[n] = src.dump[n] and true or false
        c.w[n] = tonumber(src.w[n]) or 0
    end
    return c
end

-- Does the server's confirmed plan match what Statty intends to own?
local function AutoPlanMatches(a, b)
    if not a or not b then return false end
    if (a.enabled and true or false) ~= (b.enabled and true or false) then return false end
    for n = 1, 8 do
        if (a.dump[n] and true or false) ~= (b.dump[n] and true or false) then return false end
        if (a.w[n] or 0) ~= (b.w[n] or 0) then return false end
    end
    return true
end

-- One Save for every editor of this draft (the Auto % window and the Stat
-- Feed row controls). Returns false when validation blocked it.
local function AutoSaveDraft()
    local d = AutoDraftGet()
    local why = AutoWhyNotSaveable(d)
    if why then
        autoError = why
        AutoRefresh()
        return false
    end
    local mask = 0
    for n = 1, 8 do
        if d.dump[n] then mask = mask + 2 ^ (n - 1) end
    end
    AutoSendPlan(d)
    -- Ownership: saving with Auto ON means "keep this running". Statty will
    -- now re-assert it if the server drifts. Saving with Auto OFF hands the
    -- switch back - Statty stops policing it.
    if d.enabled then
        autoOwned = AutoClonePlan(d)
        if AutoStatConverterDB then AutoStatConverterDB.ownedPlan = autoOwned end
    else
        autoOwned = nil
        if AutoStatConverterDB then AutoStatConverterDB.ownedPlan = nil end
    end
    autoAssertGrace = AUTO_ASSERT_WAIT
    -- Nothing optimistic: the reply carries what the server now STORES and
    -- replaces the plan. Until then the old one keeps showing - the truth.
    autoError = nil
    autoUI.save:Disable()
    return true
end

autoUI.save:SetScript("OnClick", AutoSaveDraft)

function autoUI.RefreshFooter()
    local d = AutoDraftGet()
    local total = AutoTotal(d)
    local why = AutoWhyNotSaveable(d)
    autoUI.total:SetText(string.format("Shares: %s%d%%|r",
        (total == 100) and "|cff00ff00" or "|cffff8800", total))
    if why then autoUI.save:Disable() else autoUI.save:Enable() end
end

local autoListeners = {}
local function AutoNotify()
    for i = 1, #autoListeners do
        local ok, err = pcall(autoListeners[i])
        if not ok then
            -- A broken listener must never take the Auto window down with it.
            -- swallow: internal guard, never user-facing chat
        end
    end
end

AutoRefresh = function()
    local d = AutoDraftGet()
    for n = 1, 8 do
        local r = autoUI.rows[n]
        r.check:SetChecked(d.dump[n])
        -- Never write into a box the player is typing in.
        if not r.pct:HasFocus() then
            r.pct:SetText(tostring(d.w[n] or 0))
        end
        -- A dumped stat has no share by definition; greying the box says so.
        if d.dump[n] then
            r.pct:EnableKeyboard(false)
            r.pct:SetAlpha(0.35)
        else
            r.pct:EnableKeyboard(true)
            r.pct:SetAlpha(1.0)
        end
    end
    autoUI.enable:SetChecked(d.enabled)
    autoUI.RefreshFooter()

    if autoError then
        autoStatus:SetText("|cffff4444" .. autoError .. "|r")
    elseif not autoPlan then
        autoStatus:SetText(autoWaiting and "Waiting for the server..."
            or "|cffaaaaaa Automatic spending is not available on this server build.|r")
    else
        local note = string.format(
            "Ticked stats are dumped as they are earned and spent on the shares, at %d of the " ..
            "dumped stat per 1 gained (the .ds rate). Only stats earned AFTER enabling are " ..
            "converted; banked stats are untouched - use the converter queue for those.",
            autoPlan.rate or 2)
        if autoPend then
            local parts = {}
            for n = 1, 8 do
                if (autoPend[n] or 0) > 0 then
                    table.insert(parts, string.format("%s %d", string.sub(ESSENCE_STATS[n], 1, 3), autoPend[n]))
                end
            end
            if #parts > 0 then
                note = note .. "\n|cffaaaaaaPending remainders: " .. table.concat(parts, ", ") .. "|r"
            end
        end
        autoStatus:SetText(note)
    end
    AutoNotify()
end

-- ------------------------------------------------------------
-- Comms: request on show, parse DSA* replies, 3s no-answer timeout
-- ------------------------------------------------------------
local function AutoRequest()
    autoWaiting = true
    autoWaited = 0
    AutoSend("DSAGET")
end

autoFrame:SetScript("OnShow", function()
    AutoRequest()
    AutoRefresh()
end)

-- Always-on driver: reply timeout AND the ownership heartbeat, both of which
-- must run whether or not any Statty window is open.
local autoDriver = CreateFrame("Frame")
autoDriver:SetScript("OnUpdate", function(self, elapsed)
    elapsed = elapsed or 0

    -- Reply timeout (unchanged behaviour, just relocated off autoFrame).
    if autoWaiting then
        autoWaited = autoWaited + elapsed
        if autoWaited > 3 then
            autoWaiting = false
            if not autoPlan then
                if autoFrame:IsShown() then AutoRefresh() end
            else
                AutoNotify()
            end
        end
    end

    if autoAssertGrace > 0 then autoAssertGrace = autoAssertGrace - elapsed end

    -- Ownership heartbeat: only while Statty owns a plan.
    if autoOwned then
        autoHeartbeat = autoHeartbeat + elapsed
        if autoHeartbeat >= AUTO_POLL_EVERY and not autoWaiting then
            autoHeartbeat = 0
            AutoRequest()  -- DSAGET; the DSACFG handler does the comparison
        end
    end
end)

-- Load persisted ownership intent and begin policing shortly after login.
-- Done here (not in the early ADDON_LOADED block) because autoOwned and its
-- helpers are declared in this section of the file.
local autoOwnBoot = CreateFrame("Frame")
autoOwnBoot:RegisterEvent("PLAYER_ENTERING_WORLD")
autoOwnBoot:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    if AutoStatConverterDB and AutoStatConverterDB.ownedPlan then
        autoOwned = AutoClonePlan(AutoStatConverterDB.ownedPlan)
        -- First poll soon, so a plan the Progress tab disabled while we were
        -- logged out is corrected within a few seconds of logging in.
        autoHeartbeat = AUTO_POLL_EVERY - 3
    end
end)

local autoComms = CreateFrame("Frame")
autoComms:RegisterEvent("CHAT_MSG_ADDON")
autoComms:SetScript("OnEvent", function(self, event, a1, a2)
    -- 3.3.5a hands some paths the arg1..argN globals rather than parameters.
    event = event or _G.event
    a1 = a1 or _G.arg1
    a2 = a2 or _G.arg2
    if event ~= "CHAT_MSG_ADDON" then return end
    if a1 ~= ASC_PIPE_PREFIX or not a2 then return end
    if string.sub(a2, 1, 3) ~= "DSA" then return end

    local err = string.match(a2, "^DSAERR:(.+)$")
    if err then
        -- "busy" is the shared throttle answering a GET - not news. Everything
        -- else is a REFUSED PLAN, surfaced word for word: the server composes
        -- those sentences and is the only thing that knows which rule broke.
        if err ~= "busy" then autoError = err end
        autoWaiting = false
        if autoFrame:IsShown() then AutoRefresh() else AutoNotify() end
        return
    end

    local rate, enabled, mask, w0, w1, w2, w3, w4, w5, w6, w7 = string.match(a2,
        "^DSACFG:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if rate then
        local weights = { tonumber(w0) or 0, tonumber(w1) or 0, tonumber(w2) or 0,
                          tonumber(w3) or 0, tonumber(w4) or 0, tonumber(w5) or 0,
                          tonumber(w6) or 0, tonumber(w7) or 0 }
        local dump = {}
        local m = tonumber(mask) or 0
        for n = 1, 8 do
            -- No bitlib in 3.3.5a Lua: divide down and test parity.
            dump[n] = (math.floor(m / (2 ^ (n - 1))) % 2) == 1
        end
        autoPlan = { rate = tonumber(rate) or 2,
                     enabled = (tonumber(enabled) or 0) ~= 0,
                     dump = dump, w = weights }
        autoError = nil
        -- The draft is REPLACED by every confirmed plan, including the one
        -- that comes back from the player's own Save.
        autoDraft = nil
        autoWaiting = false

        -- Ownership enforcement (option 2). If Statty owns a plan and the
        -- server's confirmed plan no longer matches it - the Progress tab
        -- disabled it, someone changed it - put it back. The grace window
        -- stops a feedback loop: right after we assert, we expect one drifting
        -- confirm to arrive and must not re-fire on it.
        if autoOwned and not AutoPlanMatches(autoPlan, autoOwned) then
            if autoAssertGrace <= 0 then
                -- Silent re-assert: the strip shows the state; no chat output
                -- (standing rule: nothing in chat beyond the login stamp).
                AutoSendPlan(autoOwned)
                autoAssertGrace = AUTO_ASSERT_WAIT
                autoHeartbeat = 0
            end
        end

        if autoFrame:IsShown() then AutoRefresh() else AutoNotify() end
        return
    end

    local p0, p1, p2, p3, p4, p5, p6, p7 = string.match(a2,
        "^DSAPEND:(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
    if p0 then
        autoPend = { tonumber(p0) or 0, tonumber(p1) or 0, tonumber(p2) or 0,
                     tonumber(p3) or 0, tonumber(p4) or 0, tonumber(p5) or 0,
                     tonumber(p6) or 0, tonumber(p7) or 0 }
        if autoFrame:IsShown() then AutoRefresh() else AutoNotify() end
        return
    end
end)

-- ============================================================
-- Bridge for other files of this addon (QoLBridge.lua): one shared
-- draft, one Save, one set of comms - two editors painting it.
-- ============================================================
_G.ASC_AutoBridge = {
    STATS = ESSENCE_STATS,                       -- wire order; map by NAME
    GetPlan = function() return autoPlan end,     -- last server-confirmed
    GetPending = function() return autoPend end,
    GetDraft = AutoDraftGet,                      -- the ONE editable draft
    -- True when the draft has edits not yet confirmed by the server. Compares
    -- the draft against autoPlan field by field; if there is no draft at all,
    -- there is nothing unsent.
    HasUnsentEdits = function()
        if not autoDraft then return false end
        local p = autoPlan
        if not p then return true end -- edited but nothing confirmed yet
        if (autoDraft.enabled and true or false) ~= (p.enabled and true or false) then return true end
        for n = 1, 8 do
            if (autoDraft.dump[n] and true or false) ~= (p.dump[n] and true or false) then return true end
            if (autoDraft.w[n] or 0) ~= (p.w[n] or 0) then return true end
        end
        return false
    end,
    -- True when the SERVER has confirmed an enabled plan that will convert
    -- something (at least one feeder and one receiver).
    IsOwned = function() return autoOwned ~= nil end,
    ReleaseOwnership = function()
        autoOwned = nil
        if AutoStatConverterDB then AutoStatConverterDB.ownedPlan = nil end
    end,
    IsLiveAndActive = function()
        local p = autoPlan
        if not p or not p.enabled then return false end
        local anyDump, anyRecv = false, false
        for n = 1, 8 do
            if p.dump[n] then anyDump = true end
            if (p.w[n] or 0) > 0 then anyRecv = true end
        end
        return anyDump and anyRecv
    end,
    GetError = function() return autoError end,
    ClearError = function() autoError = nil end,
    IsWaiting = function() return autoWaiting end,
    WhyNotSaveable = AutoWhyNotSaveable,
    Save = AutoSaveDraft,
    Request = AutoRequest,
    -- Repaint the Auto % window (if open) and tell every listener. External
    -- editors call this after changing the draft.
    Touch = function()
        if autoFrame:IsShown() then AutoRefresh() else AutoNotify() end
    end,
    Listen = function(fn) table.insert(autoListeners, fn) end,
}

function ASC_ToggleAutoWindow()
    if autoFrame:IsShown() then autoFrame:Hide() else autoFrame:Show() end
end

-- "Auto %" button on the main window, next to Preview
local autoBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
autoBtn:SetSize(70, 22)
autoBtn:SetPoint("LEFT", previewBtn, "RIGHT", 8, 0)
autoBtn:SetText("Auto %")
autoBtn:SetScript("OnClick", ASC_ToggleAutoWindow)
