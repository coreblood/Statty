--[[
    QoLBridge -- the piece that makes the two halves one addon.

    Adds to every Stat Feed row, on the right:

        [G] [R] [35%]

    G(reen)  = this stat RECEIVES: it gets a percentage share of everything dumped.
    R(ed)    = this stat FEEDS: it is dumped as it is earned.
    neither  = untouched - it neither feeds nor is fed.

    The shares of all green stats must total exactly 100; a red stat's
    percentage button is disabled (a feeder has no share by definition).
    Below the rows a one-line strip shows the running total, the plan's
    on/off switch and Save.

    None of this is a second implementation of anything. The draft being
    edited, the validation, the DSASET on Save and the DSACFG/DSAERR
    handling all live in AutoStatConverter.lua and are reached through
    ASC_AutoBridge - these controls are a second PAINTER of the same
    plan the Auto % window edits. Change a share here and the Auto %
    window shows it; Save in either place and both repaint from what the
    server confirms it now stores.

    Load order matters and the .toc guarantees it:
    AutoStatConverter.lua (the bridge) -> StatFeed.lua (the rows and the
    OnRowsBuilt hook) -> this file (the hook's implementation).
]]

local CONTROLS_W = 78      -- G + R + percent button + gaps; StatFeed reserves this
local BTN = 13             -- the G/R squares
local PCT_W = 38

local bridge = _G.ASC_AutoBridge
local controls = {}        -- [wireIndex] = { g, r, pct, key }
local strip = nil
local built = false

-- StatFeed asks this while laying out its columns. Zero until the controls
-- exist AND the server has ever confirmed a plan - a realm without the DSA
-- verbs gets the stock Stat Feed layout back, pixel for pixel.
function StatFeedQoL_ControlsReserve()
    if built and bridge and bridge.GetPlan() then return CONTROLS_W end
    return 0
end

-- Map a Stat Feed display key to the DSA wire index BY NAME. The two lists
-- hold the same eight names in different orders (Stat Feed shows Spell Power
-- above Defense Rating; the wire has them swapped) - indexing positionally
-- would silently swap those two stats' fates.
local function WireIndex(key)
    if not bridge then return nil end
    for n = 1, 8 do
        if bridge.STATS[n] == key then return n end
    end
    return nil
end

local function Repaint()
    if not built or not bridge then return end
    local plan = bridge.GetPlan()
    local avail = plan ~= nil
    local d = bridge.GetDraft()

    for n = 1, 8 do
        local c = controls[n]
        if c then
            if avail then
                c.g:Show(); c.r:Show(); c.pct:Show()
                local isDump = d.dump[n]
                local isMark = (d.mark and d.mark[n]) or (d.w[n] or 0) > 0
                c.g.tex:SetTexture(0, 0.85, 0, isMark and 0.95 or 0.22)
                c.r.tex:SetTexture(0.9, 0.1, 0.1, isDump and 0.95 or 0.22)
                if isDump then
                    -- A feeder has no share; the button says so and stops listening.
                    c.pct:Disable()
                    c.pct.text:SetText("|cff555555--|r")
                else
                    c.pct:Enable()
                    local w = d.w[n] or 0
                    if w > 0 then
                        c.pct.text:SetText(w .. "%")
                    elseif isMark then
                        c.pct.text:SetText("|cffff8800?%|r") -- green but shareless: pick one
                    else
                        c.pct.text:SetText("|cff777777--|r")
                    end
                end
            else
                c.g:Hide(); c.r:Hide(); c.pct:Hide()
            end
        end
    end

    if strip then
        if avail then
            strip:Show()
            local total = 0
            for n = 1, 8 do total = total + (d.w[n] or 0) end
            local err = bridge.GetError()
            local why = bridge.WhyNotSaveable(d)
            local unsent = bridge.HasUnsentEdits()
            if err then
                strip.text:SetText("|cffff4444" .. err .. "|r")
            elseif why then
                -- Incomplete plan: name the one thing left to do, in orange.
                strip.text:SetText("|cffffaa00" .. why .. "|r")
            elseif unsent then
                -- Valid but NOT yet sent to the server. This is the state that
                -- previously lied by saying "ready to Save" as though ON meant
                -- live - it flashes so the unsent edit can't be mistaken for an
                -- active plan.
                strip.text:SetText("|cffff8800Unsaved changes - press Save to apply|r")
            elseif bridge.IsLiveAndActive() then
                local owned = bridge.IsOwned and bridge.IsOwned()
                strip.text:SetText(string.format("|cff00ff00Active%s|r · Shares 100%% · dumping into %d stat(s)",
                    owned and " (Statty-owned)" or "",
                    (function() local c=0; for n=1,8 do if (d.w[n] or 0)>0 then c=c+1 end end; return c end)()))
            elseif not d.enabled then
                -- Plan is valid but switched OFF. Point straight at the fix.
                strip.text:SetText("|cffffaa00Plan is OFF - turn Auto ON, then Save|r")
            else
                strip.text:SetText("|cffaaaaaaSaved but not converting - press Save to (re)apply|r")
            end
            -- Reflect the draft's on/off on the toggle button itself.
            if strip.toggle then
                strip.toggle:SetText(d.enabled and "|cff00ff00ON|r" or "|cffff5555OFF|r")
            end
            if why then strip.save:Disable() else strip.save:Enable() end
        else
            strip:Hide()
        end
    end
end

-- The percentage menu: one shared UIDropDownMenu-driven list, opened at the
-- clicked button. EasyMenu is stock 3.3.5 FrameXML. Initialization happens
-- inside the click, never at file scope [3.3.5a constraint].
local pctMenuFrame = nil
local function OpenPctMenu(wireIndex, anchor)
    if not pctMenuFrame then
        pctMenuFrame = CreateFrame("Frame", "QoL_PctMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end
    local d = bridge.GetDraft()
    local menu = {}
    table.insert(menu, { text = "Share for " .. bridge.STATS[wireIndex], isTitle = true, notCheckable = true })
    table.insert(menu, {
        text = "Clear (0%)", notCheckable = true,
        func = function()
            local dd = bridge.GetDraft()
            dd.w[wireIndex] = 0
            if dd.mark then dd.mark[wireIndex] = false end
            bridge.ClearError()
            bridge.Touch()
        end,
    })
    for v = 5, 100, 5 do
        local vv = v
        table.insert(menu, {
            text = vv .. "%",
            checked = (d.w[wireIndex] or 0) == vv,
            func = function()
                local dd = bridge.GetDraft()
                -- Picking a share IS marking it green; nobody assigns a share
                -- to a stat they mean to leave alone.
                dd.w[wireIndex] = vv
                if dd.mark then dd.mark[wireIndex] = true end
                dd.dump[wireIndex] = false
                bridge.ClearError()
                bridge.Touch()
            end,
        })
    end
    EasyMenu(menu, pctMenuFrame, anchor, 0, 0, "MENU")
end

local function MakeSquare(parent, r, g, b, tooltipTitle, tooltipBody)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetSize(BTN, BTN)
    btn.tex = btn:CreateTexture(nil, "ARTWORK")
    btn.tex:SetAllPoints()
    btn.tex:SetTexture(r, g, b, 0.22)
    -- A hairline border so a dim square still reads as a control, not dirt.
    btn.edge = btn:CreateTexture(nil, "BORDER")
    btn.edge:SetPoint("TOPLEFT", -1, 1)
    btn.edge:SetPoint("BOTTOMRIGHT", 1, -1)
    btn.edge:SetTexture(0, 0, 0, 0.8)
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltipTitle)
        GameTooltip:AddLine(tooltipBody, 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end

-- StatFeed calls this once, right after building its rows.
function StatFeedQoL_OnRowsBuilt(statBlock, rows, STATS, statRow, stripH, relayout)
    if built or not bridge then return end
    built = true

    local baseLevel = statBlock:GetFrameLevel() + 5 -- above the row hover frames

    for i = 1, #STATS do
        local key = STATS[i].key
        local n = WireIndex(key)
        local row = rows[key]
        if n and row and row.y then
            local c = { key = key }

            c.g = MakeSquare(statBlock, 0, 0.85, 0, "Receive (green)",
                key .. " gets a percentage share of every dumped stat. Pick the share on the % button.")
            c.g:SetFrameLevel(baseLevel)
            c.g:SetPoint("TOPRIGHT", statBlock, "TOPRIGHT", -(CONTROLS_W - BTN), row.y - 1)
            c.g:SetScript("OnClick", function()
                local d = bridge.GetDraft()
                local isMark = (d.mark and d.mark[n]) or (d.w[n] or 0) > 0
                if isMark then
                    -- Toggling green off returns the stat to untouched.
                    d.w[n] = 0
                    if d.mark then d.mark[n] = false end
                else
                    if d.mark then d.mark[n] = true end
                    d.dump[n] = false -- receiver and feeder are mutually exclusive
                end
                bridge.ClearError()
                bridge.Touch()
            end)

            c.r = MakeSquare(statBlock, 0.9, 0.1, 0.1, "Feed (red)",
                key .. " is dumped as it is earned and converted into the green stats' shares.")
            c.r:SetFrameLevel(baseLevel)
            c.r:SetPoint("LEFT", c.g, "RIGHT", 2, 0)
            c.r:SetScript("OnClick", function()
                local d = bridge.GetDraft()
                if d.dump[n] then
                    d.dump[n] = false -- back to untouched
                else
                    d.dump[n] = true
                    -- A feeder cannot also receive: dumping clears the share.
                    d.w[n] = 0
                    if d.mark then d.mark[n] = false end
                end
                bridge.ClearError()
                bridge.Touch()
            end)

            c.pct = CreateFrame("Button", nil, statBlock)
            c.pct:SetSize(PCT_W, BTN + 2)
            c.pct:SetFrameLevel(baseLevel)
            c.pct:SetPoint("LEFT", c.r, "RIGHT", 4, 0)
            c.pct.text = c.pct:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            c.pct.text:SetAllPoints()
            c.pct.text:SetJustifyH("RIGHT")
            c.pct:SetScript("OnClick", function(self) OpenPctMenu(n, self) end)
            c.pct:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Share")
                GameTooltip:AddLine("This stat's percentage of everything dumped. All shares together must total exactly 100%.", 0.9, 0.9, 0.9, true)
                GameTooltip:Show()
            end)
            c.pct:SetScript("OnLeave", function() GameTooltip:Hide() end)

            controls[n] = c
        end
    end

    -- The strip: total + on/off + Save, in the band StatFeed reserved.
    strip = CreateFrame("Frame", nil, statBlock)
    strip:SetPoint("BOTTOMLEFT", statBlock, "BOTTOMLEFT", 2, 0)
    strip:SetPoint("BOTTOMRIGHT", statBlock, "BOTTOMRIGHT", -2, 0)
    strip:SetHeight(stripH)
    strip:SetFrameLevel(baseLevel)

    strip.save = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    strip.save:SetSize(52, 16)
    strip.save:SetPoint("RIGHT", strip, "RIGHT", 0, 1)
    strip.save:SetText("Save")
    strip.save:SetScript("OnClick", function()
        -- Pressing Save means "make this happen". If the plan is otherwise
        -- valid, turn Auto ON automatically so the player doesn't have to
        -- discover the separate toggle - the #1 confusion ("saved but not
        -- converting") was a valid plan sitting with Auto off.
        local d = bridge.GetDraft()
        if not bridge.WhyNotSaveable(d) then d.enabled = true end
        bridge.Save()
    end)

    -- Visible ON/OFF toggle pill (was previously hidden behind clicking the
    -- status text, which nobody could discover).
    strip.toggle = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
    strip.toggle:SetSize(40, 16)
    strip.toggle:SetPoint("RIGHT", strip.save, "LEFT", -6, 0)
    strip.toggle:SetScript("OnClick", function()
        local d = bridge.GetDraft()
        d.enabled = not d.enabled
        bridge.ClearError()
        bridge.Touch()
    end)
    strip.toggle:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Automatic stat spending")
        GameTooltip:AddLine("Turn the plan ON or OFF. Press Save to apply. Green stats receive the shares; red stats are dumped as earned. Banked stats are never touched.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    strip.toggle:SetScript("OnLeave", function() GameTooltip:Hide() end)

    strip.text = strip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    strip.text:SetPoint("LEFT", strip, "LEFT", 0, 1)
    strip.text:SetPoint("RIGHT", strip.toggle, "LEFT", -6, 1)
    strip.text:SetJustifyH("LEFT")

    -- Repaint whenever the plan side changes for ANY reason: server replies,
    -- edits made in the Auto % window, refusals, the availability timeout.
    bridge.Listen(function()
        Repaint()
        if relayout then relayout() end
    end)

    -- The window may open before the server has ever answered; asking when it
    -- shows keeps the controls current after long idles too.
    local host = statBlock:GetParent()
    if host and host.HookScript then
        host:HookScript("OnShow", function() bridge.Request() end)
    end

    Repaint()
end

-- One request shortly after entering the world, so the controls are live the
-- first time the player looks at the window rather than the second. The same
-- moment doubles as the ancestry check: Statty IS AutoStatConverter and
-- StatFeed - running the old standalones beside it doubles every frame,
-- hijacks the shared global names, and produces half-broken options pages.
-- They get disabled on sight, loudly.
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:SetScript("OnEvent", function(self)
    self:UnregisterEvent("PLAYER_ENTERING_WORLD")
    -- Load confirmation: if you do NOT see this line in chat at login, the
    -- addon folder isn't being read at all (wrong folder name, or disabled).
    print("|cff00ff00[Statty]|r loaded. Type /statty for the window, /asc options for settings.")
    local stale = {}
    for _, old in ipairs({ "AutoStatConverter", "StatFeed" }) do
        if IsAddOnLoaded and IsAddOnLoaded(old) then
            if DisableAddOn then DisableAddOn(old) end
            table.insert(stale, old)
        end
    end
    if #stale > 0 then
        print("|cffff4444[Statty]|r The old standalone addon(s) " .. table.concat(stale, ", ") ..
            " were still enabled - they are now DISABLED (Statty replaces them). " ..
            "Type /reload to finish; your settings carry over.")
    end
    -- The C_Timer shim ships in AutoStatConverter.lua, loaded before this file.
    C_Timer.After(3, function()
        if bridge then bridge.Request() end
    end)
end)

-- ============================================================
-- The addon's own Interface Options: an "Uncapped QoL" category
-- with two children - Converter (AutoStatConverter's existing
-- panel, re-parented) and Stat Feed (built here on the API the
-- feed exposes; its old UncappedUI page is superseded).
-- ============================================================
local rootPanel = CreateFrame("Frame", "QoL_RootOptionsPanel", UIParent)
rootPanel.name = "Statty"

local rt = rootPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
rt:SetPoint("TOPLEFT", 16, -16)
rt:SetText("Statty")

local rs = rootPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
rs:SetPoint("TOPLEFT", rt, "BOTTOMLEFT", 0, -6)
rs:SetPoint("RIGHT", rootPanel, "RIGHT", -32, 0)
rs:SetJustifyH("LEFT")
rs:SetText("Stat Feed with inline conversion planning, the converter queue and automatic stat spending. Settings live in the two sub-pages on the left; the buttons below open the windows themselves.")

local function RootButton(label, anchor, onClick)
    local b = CreateFrame("Button", nil, rootPanel, "UIPanelButtonTemplate")
    b:SetSize(150, 24)
    if anchor then
        b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -8)
    else
        b:SetPoint("TOPLEFT", rs, "BOTTOMLEFT", 0, -20)
    end
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local b1 = RootButton("Stat Feed", nil, function()
    if StatFeedQoL_API then StatFeedQoL_API.Toggle() end
end)
local b2 = RootButton("Converter Window", b1, function()
    local f = _G["AutoStatConverterFrame"]
    if f then f:Show() end
end)
RootButton("Auto % Window", b2, function()
    if ASC_ToggleAutoWindow then ASC_ToggleAutoWindow() end
end)

local rv = rootPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
rv:SetPoint("BOTTOMLEFT", 16, 16)
rv:SetText("Statty v1.0  ·  built from Auto Stat Converter v3.2 + Stat Feed v0.54")

-- --- Stat Feed child panel -----------------------------------
local sfPanel = CreateFrame("Frame", "QoL_StatFeedOptionsPanel", UIParent)
sfPanel.name = "Stat Feed"
sfPanel.parent = "Statty"

local st = sfPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
st:SetPoint("TOPLEFT", 16, -16)
st:SetText("Stat Feed")

local function SFDB() return StatFeedQoL_API and StatFeedQoL_API.GetDB() end

local function SFCheck(name, label, tooltip, anchor, yOff, key, apply)
    local cb = CreateFrame("CheckButton", name, sfPanel, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yOff)
    _G[name .. "Text"]:SetText(label)
    cb.tooltipText = tooltip
    cb.dbKey = key
    cb:SetScript("OnClick", function(self)
        local db = SFDB(); if not db then return end
        db[key] = self:GetChecked() and true or false
        if apply then apply() end
    end)
    return cb
end

local sfShown = SFCheck("QoL_SFShown", "Show the Stat Feed window",
    "Same as /statfeed.", st, -12, "shown",
    function() StatFeedQoL_API.SetShown(SFDB().shown) end)

local sfStats = SFCheck("QoL_SFStats", "Show the per-stat rows",
    "Hide to keep only the session summary and the feed.", sfShown, -4, "showStats",
    function() StatFeedQoL_API.ApplyStatVisibility() end)

local sfBars = SFCheck("QoL_SFBars", "Show the share bars behind the rows",
    "The coloured bars showing each stat's share of this session's gains.", sfStats, -4, "showBars", nil)

local sfAlpha = CreateFrame("Slider", "QoL_SFAlphaSlider", sfPanel, "OptionsSliderTemplate")
sfAlpha:SetPoint("TOPLEFT", sfBars, "BOTTOMLEFT", 8, -28)
sfAlpha:SetWidth(220)
sfAlpha:SetMinMaxValues(0, 100)
sfAlpha:SetValueStep(5)
_G["QoL_SFAlphaSliderLow"]:SetText("0%")
_G["QoL_SFAlphaSliderHigh"]:SetText("100%")
sfAlpha:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value / 5 + 0.5) * 5
    _G["QoL_SFAlphaSliderText"]:SetText("Background opacity: " .. value .. "%")
    local db = SFDB(); if not db then return end
    local a = value / 100
    if math.abs((db.bgAlpha or 0) - a) > 0.001 then
        db.bgAlpha = a
        StatFeedQoL_API.ApplyBgAlpha()
    end
end)

local sfLines = CreateFrame("Slider", "QoL_SFLinesSlider", sfPanel, "OptionsSliderTemplate")
sfLines:SetPoint("TOPLEFT", sfAlpha, "BOTTOMLEFT", 0, -32)
sfLines:SetWidth(220)
sfLines:SetMinMaxValues(50, 500)
sfLines:SetValueStep(50)
_G["QoL_SFLinesSliderLow"]:SetText("50")
_G["QoL_SFLinesSliderHigh"]:SetText("500")
sfLines:SetScript("OnValueChanged", function(self, value)
    value = math.floor(value / 50 + 0.5) * 50
    _G["QoL_SFLinesSliderText"]:SetText("Feed history: " .. value .. " lines")
    local db = SFDB(); if not db then return end
    if db.maxLines ~= value then
        db.maxLines = value
        StatFeedQoL_API.ApplyMaxLines()
    end
end)

local function SFButton(label, anchor, xOff, onClick)
    local b = CreateFrame("Button", nil, sfPanel, "UIPanelButtonTemplate")
    b:SetSize(120, 22)
    b:SetPoint(xOff and "LEFT" or "TOPLEFT", anchor, xOff and "RIGHT" or "BOTTOMLEFT", xOff or -8, xOff and 0 or -24)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

local sb1 = SFButton("Reset Position", sfLines, nil, function() StatFeedQoL_API.ResetWindow() end)
local sb2 = SFButton("Reset Session", sb1, 6, function() StatFeedQoL_API.ResetSession() end)
SFButton("Clear Feed", sb2, 6, function() StatFeedQoL_API.ClearFeed() end)

sfPanel:SetScript("OnShow", function()
    local db = SFDB(); if not db then return end
    sfShown:SetChecked(StatFeedQoL_API.IsShown())
    sfStats:SetChecked(db.showStats)
    sfBars:SetChecked(db.showBars)
    local a = math.floor((db.bgAlpha or 0.78) * 100 / 5 + 0.5) * 5
    sfAlpha:SetValue(a)
    _G["QoL_SFAlphaSliderText"]:SetText("Background opacity: " .. a .. "%")
    sfLines:SetValue(db.maxLines or 200)
    _G["QoL_SFLinesSliderText"]:SetText("Feed history: " .. (db.maxLines or 200) .. " lines")
end)

-- --- Register the tree: parent first, then the children ------
if InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(rootPanel)
    local conv = _G.ASC_OptionsPanel
    if conv then
        conv.parent = "Statty"
        InterfaceOptions_AddCategory(conv)
    end
    InterfaceOptions_AddCategory(sfPanel)
end


-- ============================================================
-- Auto-convert breakdown [Statty]
-- ============================================================
-- The server applies the saved plan on each stat award and announces it with
-- a single system line: "Auto-convert: spent 75,000 to gain 37,500." - no
-- stat names, no split. Statty knows the plan (which reds feed, which greens
-- receive and their shares), so it can append what that spend WENT TO.
--
-- Honesty rule: the per-green amounts are DERIVED from the plan's shares, not
-- reported by the server. They are labelled as an estimate and rounded, and
-- the raw server line is always shown untouched above them. If no plan is
-- confirmed (or shares don't total 100), only the passthrough note is added.
-- Per-stat conversion tally for THIS LOGIN SESSION, keyed by wire name:
--   gained[name] = stats this stat RECEIVED via conversion (green side, exact)
--   lost[name]   = stats this stat FED into conversion (red side; the spent
--                  pool is split across feeders by how much each earned since
--                  the last pass, so it reflects the real mix, not a guess)
-- Persisted in AutoStatConverterDB.convTally so it survives /reload, and
-- zeroed only on a real logout (see the session-token logic at the bottom of
-- this file), never on reload.
local convGained = {}
local convLost   = {}
local convLastEarned = {}  -- per-feeder session-earned watermark for delta splitting
_G.StattyQoL_ConvGained = function(statName) return convGained[statName] or 0 end
_G.StattyQoL_ConvLost   = function(statName) return convLost[statName]   or 0 end
_G.StattyQoL_ResetConvGained = function()
    for k in pairs(convGained) do convGained[k] = nil end
    for k in pairs(convLost)   do convLost[k]   = nil end
    if AutoStatConverterDB then AutoStatConverterDB.convTally = nil end
end
local function ConvPersist()
    if AutoStatConverterDB then
        AutoStatConverterDB.convTally = { gained = convGained, lost = convLost }
    end
end

local function CommaNum(n)
    n = tostring(math.floor((tonumber(n) or 0) + 0.5))
    local out = n:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Feed printer, resolved lazily: StatFeed exposes it after it builds.
local function FeedPrint(msg)
    if _G.StatFeedQoL_API and _G.StatFeedQoL_API.AddRawLine then
        _G.StatFeedQoL_API.AddRawLine(msg)
    end
end

-- Record one auto-conversion pass. Called by StatFeed's HandleFeed when the
-- server's "Auto-convert: spent X to gain Y" line arrives on the DSTATS feed
-- channel (NOT CHAT_MSG_SYSTEM - that was the v1.6.4 miss: the line comes
-- through the stat-feed addon stream, so the old system-event listener never
-- fired). Prints the per-receiver breakdown AND updates the gained/lost
-- tooltip counters.
local function RecordConvertPass(spentN, gainedN)
    spentN = tonumber(spentN) or 0
    gainedN = tonumber(gainedN) or 0
    if gainedN <= 0 then return end
    if not bridge then return end
    -- The server only sends this line when it actually converted, so the
    -- conversion definitely happened - count it. We split it by the plan's
    -- shares. Prefer the server-confirmed plan; if that hasn't come back yet
    -- (the confirm can lag or be silent), fall back to the saved draft, which
    -- is what the player last committed. Only bail if we have NO plan shape at
    -- all to attribute the split to.
    -- [Statty v1.6.4] Previously this required IsLiveAndActive() (the confirmed
    -- plan only), so a working conversion whose DSACFG confirm hadn't arrived
    -- counted nothing and the tooltip's gained/lost lines stayed empty.
    local plan = bridge.GetPlan()
    if not plan then
        local d = bridge.GetDraft and bridge.GetDraft()
        if d then
            -- Shape a plan-like table from the draft (dump[]/w[] already match).
            plan = { dump = d.dump, w = d.w, enabled = d.enabled }
        end
    end
    if not plan then return end
    -- Need at least one receiver and one feeder in the plan to attribute a
    -- split; without both, there's nothing meaningful to record.
    do
        local anyR, anyF = false, false
        for n = 1, 8 do
            if (plan.w[n] or 0) > 0 then anyR = true end
            if plan.dump[n] then anyF = true end
        end
        if not (anyR and anyF) then return end
    end

    -- Which stats receive (green + share). The gained total splits by the
    -- shares EXACTLY - percentages of a known number are arithmetic, not a
    -- guess - so this per-receiver line is precise. (The "spent" side is
    -- deliberately not attributed to individual feeders: the server pools
    -- them before spending and never reports which gave how much, so any
    -- per-feeder figure would be invented. We show only what is exact.)
    local receivers, shareTotal = {}, 0
    for n = 1, 8 do
        if (plan.w[n] or 0) > 0 then
            table.insert(receivers, { name = bridge.STATS[n], share = plan.w[n] })
            shareTotal = shareTotal + plan.w[n]
        end
    end
    if #receivers == 0 or shareTotal == 0 then return end

    -- Distribute the gain by share, giving any rounding remainder to the
    -- largest receiver so the parts always sum to exactly gainedN.
    local assigned, biggest, biggestCut = 0, nil, -1
    for _, r in ipairs(receivers) do
        r.cut = math.floor(gainedN * (r.share / shareTotal) + 0.5)
        assigned = assigned + r.cut
        if r.cut > biggestCut then biggestCut = r.cut; biggest = r end
    end
    if biggest then biggest.cut = biggest.cut + (gainedN - assigned) end

    local parts = {}
    for _, r in ipairs(receivers) do
        convGained[r.name] = (convGained[r.name] or 0) + r.cut
        table.insert(parts, string.format("|cff66ff66%s|r |cffffffff+%s|r|cff888888 (%d%%)|r",
            r.name, CommaNum(r.cut), r.share))
    end

    -- LOST side: the server spent `spentN` total across all red feeders but
    -- never says the per-feeder split. Approximate it by how much each feeder
    -- EARNED since the last pass (StatFeed tracks per-stat session gain): a
    -- stat that earned more contributed more to the pool. If that signal is
    -- unavailable, fall back to an equal split. Either way the parts sum to
    -- exactly spentN (remainder to the largest), so the per-stat "lost"
    -- tallies always add up to what the server actually spent.
    local feeders = {}
    for n = 1, 8 do
        if plan.dump[n] then table.insert(feeders, { name = bridge.STATS[n], weight = 0 }) end
    end
    if #feeders > 0 then
        local wsum = 0
        for _, fdr in ipairs(feeders) do
            local since = _G.StattyQoL_SessionEarned and _G.StattyQoL_SessionEarned(fdr.name) or 0
            -- Use the delta since we last sampled, not the whole session, so a
            -- feeder that stopped earning stops absorbing the spend.
            local prev = convLastEarned[fdr.name] or 0
            local d = since - prev
            if d < 0 then d = 0 end
            fdr.weight = d
            wsum = wsum + d
        end
        local assignedL, bigF, bigW = 0, nil, -1
        for _, fdr in ipairs(feeders) do
            local share = (wsum > 0) and (fdr.weight / wsum) or (1 / #feeders)
            fdr.loss = math.floor(spentN * share + 0.5)
            assignedL = assignedL + fdr.loss
            if fdr.weight > bigW then bigW = fdr.weight; bigF = fdr end
        end
        if bigF then bigF.loss = bigF.loss + (spentN - assignedL) end
        for _, fdr in ipairs(feeders) do
            convLost[fdr.name] = (convLost[fdr.name] or 0) + fdr.loss
        end
        -- Remember where each feeder's session-earned counter stands now, so
        -- next pass measures only the new earnings.
        for _, fdr in ipairs(feeders) do
            convLastEarned[fdr.name] = _G.StattyQoL_SessionEarned and _G.StattyQoL_SessionEarned(fdr.name) or 0
        end
    end

    ConvPersist()
    FeedPrint("|cff9CC243   -> |r" .. table.concat(parts, "  "))
end

-- Exposed for StatFeed's feed parser to call on the auto-convert line.
_G.StattyQoL_RecordConvert = RecordConvertPass


-- ============================================================
-- Conversion-tally session lifecycle [Statty]
-- ============================================================
-- Requirement: the "gained/lost by conversion" counters reset on LOGOUT but
-- survive /reload. WoW keeps SavedVariables across both, and PLAYER_LOGOUT
-- fires for both, so neither alone distinguishes them. Two signals are used,
-- in order of reliability:
--   1. PLAYER_ENTERING_WORLD's (isInitialLogin, isReload) booleans, when this
--      core passes them - a true initial login means "new session, zero it".
--   2. A logout stamp fallback: on PLAYER_LOGOUT we record that a clean exit
--      happened; if the stored tally is from before such an exit, it's stale
--      and gets zeroed on next load. A /reload does NOT set the clean-exit
--      stamp, so a reloaded tally is kept.
local convLifecycle = CreateFrame("Frame")
convLifecycle:RegisterEvent("PLAYER_ENTERING_WORLD")
convLifecycle:RegisterEvent("PLAYER_LOGOUT")

local convSessionStarted = false

local function ConvLoadOrReset(freshLogin)
    if freshLogin then
        -- New login: start empty and clear any persisted leftovers.
        for k in pairs(convGained) do convGained[k] = nil end
        for k in pairs(convLost) do convLost[k] = nil end
        for k in pairs(convLastEarned) do convLastEarned[k] = nil end
        if AutoStatConverterDB then AutoStatConverterDB.convTally = nil end
    else
        -- Reload: restore what we had in memory before the reload.
        local t = AutoStatConverterDB and AutoStatConverterDB.convTally
        if t then
            if t.gained then for k, v in pairs(t.gained) do convGained[k] = v end end
            if t.lost then for k, v in pairs(t.lost) do convLost[k] = v end end
        end
    end
end

convLifecycle:SetScript("OnEvent", function(self, event, isInitialLogin, isReload)
    isInitialLogin = isInitialLogin
    if event == "PLAYER_LOGOUT" then
        -- Mark a clean exit so the next load knows a real logout happened and
        -- the persisted tally (if any) is from the previous session.
        if AutoStatConverterDB then AutoStatConverterDB.convCleanExit = true end
        return
    end

    -- PLAYER_ENTERING_WORLD - may fire more than once; only act the first time.
    if convSessionStarted then return end
    convSessionStarted = true

    local fresh
    if type(isInitialLogin) == "boolean" or type(isReload) == "boolean" then
        -- The core told us directly.
        fresh = isInitialLogin == true
    else
        -- Fallback: a clean-exit stamp means the last shutdown was a true
        -- logout/quit, so anything persisted is last session's - treat as
        -- fresh. No stamp means we came back from a /reload - keep the tally.
        fresh = (AutoStatConverterDB and AutoStatConverterDB.convCleanExit) and true or false
        -- If there's no persisted tally at all, it's also effectively fresh.
        if not (AutoStatConverterDB and AutoStatConverterDB.convTally) then fresh = true end
    end

    ConvLoadOrReset(fresh)
    -- Consume the clean-exit stamp: from here on we're a live session, and a
    -- subsequent /reload must NOT look like a fresh login.
    if AutoStatConverterDB then AutoStatConverterDB.convCleanExit = nil end
end)
