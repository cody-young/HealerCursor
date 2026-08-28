-------------------------------------------------------------------------------
--  HealerCursor -- Options.lua
--
--  Copyright (C) 2026 Cody Young (codyy).
--  Licensed under the GNU General Public License v3 or later.
--  See LICENSE, or <https://www.gnu.org/licenses/gpl-3.0.html>.
--
--  The configuration window. Built from plain frames rather than Blizzard's
--  options templates: the template surface churns every expansion, and none of
--  it is worth a load-time dependency for eight checkboxes and seven sliders.
--
--  Everything in here is created lazily on first open, so a player who never
--  types /hc never pays for any of it.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local Options = {}
ns.Options = Options

local C_Spell = C_Spell
local ACCENT  = { 0.05, 0.82, 0.62 }

local panel, rows, refreshList

local ROW_H       = 30
local LIST_H      = 250

-------------------------------------------------------------------------------
--  Small widget helpers
-------------------------------------------------------------------------------
local function Label(parent, text, x, y, template, r, g, b)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
    fs:SetPoint("TOPLEFT", x, y)
    fs:SetText(text)
    if r then fs:SetTextColor(r, g, b) end
    return fs
end

local function Backdrop(frame, r, g, b, a, edge)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(r, g, b, a)
    if edge then
        local e = frame:CreateTexture(nil, "BORDER")
        e:SetPoint("TOPLEFT", -1, 1)
        e:SetPoint("BOTTOMRIGHT", 1, -1)
        e:SetColorTexture(0, 0, 0, 0.9)
    end
    return bg
end

local function Commit()
    ns.Display.ApplySettings()
end

local function CreateCheck(parent, x, y, text, key, tooltip)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetPoint("TOPLEFT", x, y)
    cb:SetSize(24, 24)
    local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    fs:SetText(text)
    cb:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() and true or false
        Commit()
    end)
    if tooltip then
        cb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(text, 1, 1, 1)
            GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        cb:SetScript("OnLeave", GameTooltip_Hide)
    end
    cb._key = key
    return cb
end

-- Hand-rolled slider: a track, a thumb, a live value readout. No template
-- dependency, so it cannot break on a UI overhaul.
local function CreateSlider(parent, x, y, w, text, key, minV, maxV, step, isFloat)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", x, y)
    title:SetText(text)

    local val = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("TOPRIGHT", parent, "TOPLEFT", x + w, y)
    val:SetTextColor(unpack(ACCENT))

    local s = CreateFrame("Slider", nil, parent)
    s:SetPoint("TOPLEFT", x, y - 16)
    s:SetSize(w, 16)
    s:SetOrientation("HORIZONTAL")
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    s:SetObeyStepOnDrag(true)
    s:SetHitRectInsets(0, 0, -6, -6)

    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(4)
    track:SetColorTexture(0, 0, 0, 0.7)

    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = s:GetThumbTexture()
    thumb:SetSize(12, 18)

    local function Fmt(v)
        if isFloat then return ("%.2f"):format(v) end
        return tostring(math.floor(v + 0.5))
    end

    s:SetScript("OnValueChanged", function(self, v)
        if not isFloat then v = math.floor(v + 0.5) end
        val:SetText(Fmt(v))
        if self._loading then return end
        if ns.db[key] ~= v then
            ns.db[key] = v
            Commit()
        end
    end)

    s._key, s._fmt = key, Fmt
    s._val = val
    return s
end

-- A row of mutually exclusive buttons. Cheaper and clearer than a dropdown for
-- two-to-four choices, and immune to the dropdown API churn.
local function CreateSegment(parent, x, y, w, text, key, choices, onChange)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", x, y)
    title:SetText(text)

    local seg = { buttons = {}, key = key }
    local n = #choices
    local bw = math.floor((w - (n - 1) * 3) / n)

    for i = 1, n do
        local c = choices[i]
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(bw, 20)
        b:SetPoint("TOPLEFT", x + (i - 1) * (bw + 3), y - 16)

        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        b._bg = bg

        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("CENTER")
        fs:SetText(c[2])
        b._fs = fs
        b._value = c[1]

        b:SetScript("OnClick", function(self)
            ns.db[key] = self._value
            seg:Update()
            if onChange then onChange(self._value) end
            Commit()
        end)
        seg.buttons[i] = b
    end

    function seg:Update()
        local cur = ns.db and ns.db[key]
        for i = 1, #self.buttons do
            local b = self.buttons[i]
            if b._value == cur then
                b._bg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.55)
                b._fs:SetTextColor(1, 1, 1)
            else
                b._bg:SetColorTexture(0.15, 0.15, 0.15, 0.8)
                b._fs:SetTextColor(0.7, 0.7, 0.7)
            end
        end
    end

    return seg
end

-------------------------------------------------------------------------------
--  Colour swatch
-------------------------------------------------------------------------------
local function CreateColorSwatch(parent, x, y, text, kr, kg, kb)
    local b = CreateFrame("Button", nil, parent)
    b:SetPoint("TOPLEFT", x, y)
    b:SetSize(20, 20)

    local edge = b:CreateTexture(nil, "BACKGROUND")
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0, 0, 0, 1)

    local sw = b:CreateTexture(nil, "ARTWORK")
    sw:SetAllPoints()
    b._sw = sw

    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", b, "RIGHT", 6, 0)
    fs:SetText(text)

    b:SetScript("OnClick", function()
        local r, g, bb = ns.db[kr], ns.db[kg], ns.db[kb]
        ColorPickerFrame:SetupColorPickerAndShow({
            r = r, g = g, b = bb,
            hasOpacity = false,
            swatchFunc = function()
                local nr, ng, nb = ColorPickerFrame:GetColorRGB()
                ns.db[kr], ns.db[kg], ns.db[kb] = nr, ng, nb
                sw:SetColorTexture(nr, ng, nb)
                Commit()
            end,
            cancelFunc = function()
                ns.db[kr], ns.db[kg], ns.db[kb] = r, g, bb
                sw:SetColorTexture(r, g, bb)
                Commit()
            end,
        })
    end)

    function b:Update()
        sw:SetColorTexture(ns.db[kr], ns.db[kg], ns.db[kb])
    end
    return b
end

-------------------------------------------------------------------------------
--  Font picker
--
--  One shared popup for every picker. Each row is drawn IN the font it offers,
--  which is the only way to actually choose a font.
-------------------------------------------------------------------------------
local fontPopup
local fontRows = {}
local POPUP_H, ROW = 200, 20

local function BuildFontPopup()
    fontPopup = CreateFrame("Frame", nil, UIParent)
    fontPopup:SetFrameStrata("FULLSCREEN_DIALOG")
    fontPopup:SetFrameLevel(400)
    fontPopup:SetSize(180, POPUP_H)
    Backdrop(fontPopup, 0.05, 0.05, 0.06, 0.98, true)
    fontPopup:EnableMouse(true)
    fontPopup:EnableMouseWheel(true)
    fontPopup:SetClipsChildren(true)
    fontPopup:Hide()

    fontPopup.content = CreateFrame("Frame", nil, fontPopup)
    fontPopup.content:SetPoint("TOPLEFT", 0, 0)
    fontPopup.content:SetSize(180, POPUP_H)

    fontPopup:SetScript("OnMouseWheel", function(self, delta)
        self._scroll = math.min(self._max or 0,
            math.max(0, (self._scroll or 0) - delta * ROW))
        self.content:SetPoint("TOPLEFT", 0, self._scroll)
    end)
end

local function ToggleFontPopup(owner, key)
    if not fontPopup then BuildFontPopup() end
    if fontPopup:IsShown() and fontPopup._owner == owner then
        fontPopup:Hide()
        return
    end

    fontPopup._owner, fontPopup._key = owner, key
    local list = ns.FontList()

    for i = 1, #list do
        local r = fontRows[i]
        if not r then
            r = CreateFrame("Button", nil, fontPopup.content)
            r:SetSize(178, ROW)
            r:SetPoint("TOPLEFT", 1, -(i - 1) * ROW)
            r._bg = r:CreateTexture(nil, "BACKGROUND")
            r._bg:SetAllPoints()
            r._fs = r:CreateFontString(nil, "OVERLAY")
            r._fs:SetPoint("LEFT", 4, 0)
            r._fs:SetPoint("RIGHT", -4, 0)
            r._fs:SetJustifyH("LEFT")
            r:SetScript("OnEnter", function(self)
                self._bg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.35)
            end)
            r:SetScript("OnLeave", function(self)
                self._bg:SetColorTexture(0, 0, 0, 0)
            end)
            r:SetScript("OnClick", function(self)
                ns.db[fontPopup._key] = self._name
                fontPopup:Hide()
                Options.Refresh()
                Commit()
            end)
            fontRows[i] = r
        end
        r._name = list[i]
        -- A font file that fails to load leaves the string blank, so fall back
        -- to a readable face and still show the name.
        if not pcall(r._fs.SetFont, r._fs, ns.FontPath(list[i]), 13, "") then
            r._fs:SetFont(ns.FontPath("Friz Quadrata TT"), 13, "")
        end
        r._fs:SetText(list[i])
        r._bg:SetColorTexture(0, 0, 0, 0)
        r:Show()
    end
    for i = #list + 1, #fontRows do fontRows[i]:Hide() end

    fontPopup.content:SetHeight(math.max(POPUP_H, #list * ROW))
    fontPopup._max = math.max(0, #list * ROW - POPUP_H)
    fontPopup._scroll = 0
    fontPopup.content:SetPoint("TOPLEFT", 0, 0)
    fontPopup:ClearAllPoints()
    fontPopup:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
    fontPopup:Show()
end

local function CreateFontPicker(parent, x, y, w, text, key)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", x, y)
    title:SetText(text)

    local b = CreateFrame("Button", nil, parent)
    b:SetPoint("TOPLEFT", x, y - 16)
    b:SetSize(w, 22)

    local edge = b:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0, 0, 0, 0.9)

    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.15, 0.15, 0.15, 0.9)

    local fs = b:CreateFontString(nil, "OVERLAY")
    fs:SetPoint("LEFT", 6, 0)
    fs:SetPoint("RIGHT", -6, 0)
    fs:SetJustifyH("LEFT")

    b:SetScript("OnClick", function(self) ToggleFontPopup(self, key) end)
    b:SetScript("OnEnter", function() bg:SetColorTexture(0.25, 0.25, 0.25, 0.95) end)
    b:SetScript("OnLeave", function() bg:SetColorTexture(0.15, 0.15, 0.15, 0.9) end)

    function b:Update()
        local name = ns.db[key]
        if not pcall(fs.SetFont, fs, ns.FontPath(name), 13, "") then
            fs:SetFont(ns.FontPath("Friz Quadrata TT"), 13, "")
        end
        fs:SetText(name)
    end
    return b
end

-------------------------------------------------------------------------------
--  Anchor grid -- a 3x3 of the nine anchor points, which reads far faster
--  than a dropdown listing "BOTTOMRIGHT".
-------------------------------------------------------------------------------
local ANCHOR_GRID = {
    { "TOPLEFT",    "TOP",    "TOPRIGHT"    },
    { "LEFT",       "CENTER", "RIGHT"       },
    { "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" },
}

local function CreateAnchorGrid(parent, x, y, text, key)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    title:SetPoint("TOPLEFT", x, y)
    title:SetText(text)

    local g = { buttons = {} }
    for r = 1, 3 do
        for c = 1, 3 do
            local b = CreateFrame("Button", nil, parent)
            b:SetSize(20, 20)
            b:SetPoint("TOPLEFT", x + (c - 1) * 22, y - 16 - (r - 1) * 22)
            b._bg = b:CreateTexture(nil, "BACKGROUND")
            b._bg:SetAllPoints()
            b._value = ANCHOR_GRID[r][c]
            b:SetScript("OnClick", function(self)
                ns.db[key] = self._value
                g:Update()
                Commit()
            end)
            g.buttons[#g.buttons + 1] = b
        end
    end

    function g:Update()
        local cur = ns.db[key]
        for i = 1, #self.buttons do
            local b = self.buttons[i]
            if b._value == cur then
                b._bg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.75)
            else
                b._bg:SetColorTexture(0.16, 0.16, 0.16, 0.85)
            end
        end
    end
    return g
end

-------------------------------------------------------------------------------
--  Panel construction
-------------------------------------------------------------------------------
local checks, sliders, segments = {}, {}, {}
local swatches, fontPickers, anchorGrids = {}, {}, {}
local pages, tabs = {}, {}

local function BuildPanel()
    panel = CreateFrame("Frame", "HealerCursorOptions", UIParent)
    panel:SetSize(730, 560)
    panel:SetPoint("CENTER")
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", panel.StartMoving)
    panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
    panel:SetClampedToScreen(true)
    panel:Hide()   -- new frames are shown by default; OnShow must fire on the
                   -- first Options.Show() so Refresh() runs
    tinsert(UISpecialFrames, "HealerCursorOptions")   -- Escape closes it

    Backdrop(panel, 0.06, 0.06, 0.07, 0.96, true)

    local header = CreateFrame("Frame", nil, panel)
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", 0, 0)
    header:SetHeight(30)
    Backdrop(header, 0.02, 0.02, 0.02, 0.9)

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", 12, 0)
    title:SetText("|cff0cd29fHealer|rCursor")

    local ver = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ver:SetPoint("LEFT", title, "RIGHT", 8, -1)
    ver:SetText("v" .. (C_AddOns and C_AddOns.GetAddOnMetadata
        and C_AddOns.GetAddOnMetadata(ADDON, "Version") or "1.0.0"))

    local close = CreateFrame("Button", nil, header, "UIPanelCloseButton")
    close:SetPoint("RIGHT", -2, 0)
    close:SetScript("OnClick", function() Options.Hide() end)

    ---------------------------------------------------------------------------
    --  Column A -- tracked spells
    ---------------------------------------------------------------------------
    local COLA = 16
    panel.specLabel = Label(panel, "Tracked spells", COLA, -44)
    panel.specLabel:SetTextColor(unpack(ACCENT))

    local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", COLA, -60)
    hint:SetText("Saved per specialization. Order here is draw order.")

    local listFrame = CreateFrame("Frame", nil, panel)
    listFrame:SetPoint("TOPLEFT", COLA, -78)
    listFrame:SetSize(300, LIST_H)
    Backdrop(listFrame, 0, 0, 0, 0.45, true)
    listFrame:EnableMouse(true)
    listFrame:EnableMouseWheel(true)
    listFrame:SetClipsChildren(true)

    local content = CreateFrame("Frame", nil, listFrame)
    content:SetPoint("TOPLEFT", 0, 0)
    content:SetSize(300, LIST_H)
    panel.content = content

    local scroll = 0
    listFrame:SetScript("OnMouseWheel", function(_, delta)
        local total = #ns.GetList() * ROW_H
        local maxScroll = math.max(0, total - LIST_H)
        scroll = math.min(maxScroll, math.max(0, scroll - delta * ROW_H))
        content:SetPoint("TOPLEFT", 0, scroll)
    end)

    local empty = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    empty:SetPoint("TOP", 0, -16)
    empty:SetText("No spells yet.\nDrag one onto the box below, or type its name.")
    empty:SetJustifyH("CENTER")
    panel.empty = empty

    -- Drop target
    local drop = CreateFrame("Button", nil, panel)
    drop:SetPoint("TOPLEFT", COLA, -336)
    drop:SetSize(300, 46)
    local dropBG = Backdrop(drop, 0.1, 0.12, 0.11, 0.9, true)
    drop:RegisterForDrag("LeftButton")

    local dropText = drop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    dropText:SetPoint("CENTER")
    dropText:SetText("Drag a spell here")
    dropText:SetTextColor(unpack(ACCENT))

    local function AcceptDrop()
        local sid = ns.SpellIDFromCursor()
        if not sid then return end
        ClearCursor()
        local ok, why = ns.AddSpell(sid)
        if not ok and why == "duplicate" then
            UIErrorsFrame:AddMessage("HealerCursor: already tracked", 1, 0.4, 0.4)
        end
        refreshList()
    end
    drop:SetScript("OnReceiveDrag", AcceptDrop)
    drop:SetScript("OnMouseUp", AcceptDrop)
    drop:SetScript("OnEnter", function()
        dropBG:SetColorTexture(0.14, 0.2, 0.18, 0.95)
    end)
    drop:SetScript("OnLeave", function()
        dropBG:SetColorTexture(0.1, 0.12, 0.11, 0.9)
    end)

    -- Manual entry
    local eb = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    eb:SetPoint("TOPLEFT", COLA + 6, -394)
    eb:SetSize(200, 22)
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(60)

    local addBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    addBtn:SetPoint("LEFT", eb, "RIGHT", 8, 0)
    addBtn:SetSize(80, 22)
    addBtn:SetText("Add")

    local function DoAdd()
        local sid = ns.ResolveInput(eb:GetText())
        if not sid then
            UIErrorsFrame:AddMessage("HealerCursor: no such spell", 1, 0.4, 0.4)
            return
        end
        local ok, why = ns.AddSpell(sid)
        if not ok and why == "duplicate" then
            UIErrorsFrame:AddMessage("HealerCursor: already tracked", 1, 0.4, 0.4)
        end
        eb:SetText("")
        eb:ClearFocus()
        refreshList()
    end
    addBtn:SetScript("OnClick", DoAdd)
    eb:SetScript("OnEnterPressed", DoAdd)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local ebHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ebHint:SetPoint("TOPLEFT", COLA + 6, -420)
    ebHint:SetText("Spell name or spell ID")

    -- One-shot copy of the Blizzard Cooldown Manager's spells, so a fresh
    -- install is one click rather than twenty drags.
    local importBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    importBtn:SetPoint("TOPLEFT", COLA + 6, -444)
    importBtn:SetSize(288, 22)
    importBtn:SetText("Import from Cooldown Manager")
    importBtn:SetScript("OnClick", function()
        local added, skipped = ns.ImportFromCDM()
        refreshList()
        print(("|cff0cd29fHealerCursor|r: imported %d spell%s%s."):format(
            added, added == 1 and "" or "s",
            skipped > 0 and (", %d already tracked"):format(skipped) or ""))
    end)
    importBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Import from Cooldown Manager", 1, 1, 1)
        GameTooltip:AddLine("Copies the Essential and Utility spells your "
            .. "Cooldown Manager is currently tracking into this spec's list. "
            .. "A one-time copy -- edit it freely afterwards.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    importBtn:SetScript("OnLeave", GameTooltip_Hide)

    ---------------------------------------------------------------------------
    --  Tabs
    --
    --  Only the right-hand area swaps. The spell list stays put on both tabs,
    --  because it is the thing you most often want in view while adjusting.
    ---------------------------------------------------------------------------
    local COLB, COLC = 336, 528

    local function SelectTab(which)
        for name, page in pairs(pages) do page:SetShown(name == which) end
        for name, tab in pairs(tabs) do
            if name == which then
                tab._bg:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.55)
                tab._fs:SetTextColor(1, 1, 1)
            else
                tab._bg:SetColorTexture(0.15, 0.15, 0.15, 0.85)
                tab._fs:SetTextColor(0.7, 0.7, 0.7)
            end
        end
        if fontPopup then fontPopup:Hide() end
    end

    local function AddTab(name, text, index)
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(120, 22)
        b:SetPoint("TOPLEFT", COLB + (index - 1) * 123, -38)
        b._bg = b:CreateTexture(nil, "BACKGROUND")
        b._bg:SetAllPoints()
        b._fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b._fs:SetPoint("CENTER")
        b._fs:SetText(text)
        b:SetScript("OnClick", function() SelectTab(name) end)
        tabs[name] = b

        -- Full-size transparent overlay so every widget keeps panel-absolute
        -- coordinates. Mouse is off by default, so it never shadows column A.
        local page = CreateFrame("Frame", nil, panel)
        page:SetAllPoints()
        pages[name] = page
        return page
    end

    local pageDisplay = AddTab("display", "Display", 1)
    local pageText    = AddTab("text",    "Text",    2)
    panel.SelectTab = SelectTab

    ---------------------------------------------------------------------------
    --  Display tab, column B -- behaviour
    ---------------------------------------------------------------------------
    Label(pageDisplay, "Behaviour", COLB, -68, nil, unpack(ACCENT))

    local y = -90
    local function Check(text, key, tip)
        local cb = CreateCheck(pageDisplay, COLB, y, text, key, tip)
        checks[#checks + 1] = cb
        y = y - 26
        return cb
    end

    Check("Enabled", "enabled")
    Check("Only in combat", "combatOnly",
        "Hide the icons entirely while out of combat.")
    Check("Only in instances", "instanceOnly",
        "Hide the icons in the open world.")
    Check("Hide in vehicles", "hideInVehicle")
    Check("Hide when unaffordable", "hideUnusable",
        "Also drop a spell when you cannot pay for it, not just when it is on cooldown.")
    Check("Show charge count", "showCharges")
    Check("Show cooldown swipe", "showSwipe",
        "Only applies in Dim mode -- in Hide mode the icon is not on screen while the cooldown runs.")
    Check("Hide while turning", "hideOnMouselook",
        "Hide the icons while you hold right-click to steer the camera.")

    y = y - 14
    segments.cooldownMode = CreateSegment(pageDisplay, COLB, y, 180,
        "When on cooldown", "cooldownMode",
        { { "hide", "Hide" }, { "desaturate", "Dim" } })
    y = y - 52

    segments.direction = CreateSegment(pageDisplay, COLB, y, 180,
        "Grow direction", "direction",
        { { "RIGHT", "Right" }, { "LEFT", "Left" }, { "UP", "Up" }, { "DOWN", "Down" } })

    ---------------------------------------------------------------------------
    --  Display tab, column C -- sizing and position
    ---------------------------------------------------------------------------
    Label(pageDisplay, "Layout", COLC, -68, nil, unpack(ACCENT))

    local sy = -92
    local function Slider(text, key, minV, maxV, step, isFloat)
        local s = CreateSlider(pageDisplay, COLC, sy, 180, text, key, minV, maxV, step, isFloat)
        sliders[#sliders + 1] = s
        sy = sy - 46
        return s
    end

    Slider("Icon size", "iconSize", 12, 80, 1)
    Slider("Spacing", "spacing", 0, 20, 1)
    Slider("Icons per row", "perRow", 1, 12, 1)
    Slider("Offset X", "offsetX", -200, 200, 1)
    Slider("Offset Y", "offsetY", -200, 200, 1)
    Slider("Opacity", "alpha", 0.1, 1, 0.05, true)
    Slider("Dim opacity", "desatAlpha", 0.05, 1, 0.05, true)

    ---------------------------------------------------------------------------
    --  Text tab
    --
    --  Both text layers get the same set of controls, so they are built from
    --  one routine keyed on the setting prefix ("count" / "cd").
    ---------------------------------------------------------------------------
    local function TextGroup(x, heading, pre, enableKey, enableText, enableTip)
        Label(pageText, heading, x, -68, nil, unpack(ACCENT))
        local ty = -90

        if enableKey then
            checks[#checks + 1] =
                CreateCheck(pageText, x, ty, enableText, enableKey, enableTip)
            ty = ty - 28
        end

        fontPickers[#fontPickers + 1] =
            CreateFontPicker(pageText, x, ty, 180, "Font", pre .. "Font")
        ty = ty - 46

        sliders[#sliders + 1] =
            CreateSlider(pageText, x, ty, 180, "Size", pre .. "Size", 6, 32, 1)
        ty = ty - 46

        segments[pre .. "Outline"] = CreateSegment(pageText, x, ty, 180,
            "Outline", pre .. "Outline",
            { { "", "None" }, { "OUTLINE", "Outline" }, { "THICKOUTLINE", "Thick" } })
        ty = ty - 52

        swatches[#swatches + 1] = CreateColorSwatch(pageText, x, ty, "Colour",
            pre .. "R", pre .. "G", pre .. "B")
        ty = ty - 32

        anchorGrids[#anchorGrids + 1] =
            CreateAnchorGrid(pageText, x, ty, "Position", pre .. "Anchor")
        ty = ty - 88

        sliders[#sliders + 1] =
            CreateSlider(pageText, x, ty, 180, "Offset X", pre .. "X", -40, 40, 1)
        ty = ty - 46

        sliders[#sliders + 1] =
            CreateSlider(pageText, x, ty, 180, "Offset Y", pre .. "Y", -40, 40, 1)
    end

    TextGroup(COLB, "Charge count", "count")
    TextGroup(COLC, "Cooldown text", "cd", "showCDText", "Show cooldown text",
        "Only ever visible in Dim mode -- in Hide mode the icon is off screen "
        .. "for the whole cooldown, so there is nothing to count down on.")

    local cdNote = pageText:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    cdNote:SetPoint("TOPLEFT", COLC, -474)
    cdNote:SetWidth(190)
    cdNote:SetJustifyH("LEFT")
    cdNote:SetText("Drawn by the game engine, so it costs no frame time.")

    ---------------------------------------------------------------------------
    --  Footer
    ---------------------------------------------------------------------------
    local preview = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
    preview:SetPoint("BOTTOMLEFT", 16, 14)
    preview:SetSize(24, 24)
    local pfs = preview:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    pfs:SetPoint("LEFT", preview, "RIGHT", 2, 0)
    pfs:SetText("Preview on cursor while this window is open")
    preview:SetChecked(true)
    preview:SetScript("OnClick", function(self)
        ns.Display.SetPreview(self:GetChecked() and true or false)
    end)
    panel.preview = preview

    local reset = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    reset:SetPoint("BOTTOMRIGHT", -16, 12)
    reset:SetSize(120, 22)
    reset:SetText("Reset settings")
    reset:SetScript("OnClick", function()
        for k, v in pairs(ns.DEFAULTS) do ns.db[k] = v end
        Options.Refresh()
        Commit()
    end)

    SelectTab("display")

    panel:SetScript("OnShow", function()
        ns.optionsOpen = true
        Options.Refresh()
        ns.Display.SetPreview(panel.preview:GetChecked() and true or false)
    end)
    panel:SetScript("OnHide", function()
        ns.optionsOpen = false
        if fontPopup then fontPopup:Hide() end
        ns.Display.SetPreview(false)
    end)
end

-------------------------------------------------------------------------------
--  Spell list rendering
-------------------------------------------------------------------------------
rows = {}

local function AcquireRow(i)
    local row = rows[i]
    if row then return row end

    row = CreateFrame("Frame", nil, panel.content)
    row:SetSize(300, ROW_H)
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(24, 24)
    row.icon:SetPoint("LEFT", 4, 0)
    row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
    row.name:SetPoint("RIGHT", -84, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    local function MiniButton(text, xoff, handler)
        local b = CreateFrame("Button", nil, row)
        b:SetSize(20, 20)
        b:SetPoint("RIGHT", xoff, 0)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.18, 0.18, 0.18, 0.9)
        local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("CENTER")
        fs:SetText(text)
        b:SetScript("OnClick", handler)
        b:SetScript("OnEnter", function() bg:SetColorTexture(0.3, 0.3, 0.3, 0.95) end)
        b:SetScript("OnLeave", function() bg:SetColorTexture(0.18, 0.18, 0.18, 0.9) end)
        return b, fs
    end

    row.up = MiniButton("^", -70, function()
        ns.MoveSpell(row._index, -1); refreshList()
    end)
    row.down = MiniButton("v", -47, function()
        ns.MoveSpell(row._index, 1); refreshList()
    end)
    local del, delfs = MiniButton("x", -24, function()
        ns.RemoveSpell(row._index); refreshList()
    end)
    delfs:SetTextColor(1, 0.4, 0.4)
    row.del = del

    rows[i] = row
    return row
end

function refreshList()
    if not panel then return end

    local list = ns.GetList()

    -- Spec name in the header so it is obvious which list you are editing.
    local idx = GetSpecialization and GetSpecialization()
    local specName = idx and select(2, GetSpecializationInfo(idx))
    panel.specLabel:SetText(specName
        and ("Tracked spells  |cff888888(%s)|r"):format(specName)
        or "Tracked spells")

    panel.empty:SetShown(#list == 0)

    for i = 1, #list do
        local row = AcquireRow(i)
        local entry = list[i]
        row._index = i

        local sid = entry.id
        if C_Spell.GetOverrideSpell then
            local o = C_Spell.GetOverrideSpell(sid)
            if o and o > 0 then sid = o end
        end

        local info = C_Spell.GetSpellInfo(sid)
        row.icon:SetTexture(info and info.iconID or 134400)

        local known = C_SpellBook and C_SpellBook.IsSpellKnownOrInSpellBook
            and (C_SpellBook.IsSpellKnownOrInSpellBook(entry.id)
                 or C_SpellBook.IsSpellKnownOrInSpellBook(sid))

        local name = (info and info.name) or ("Spell " .. entry.id)
        if known == false then
            -- Not an error: an off-spec or untalented spell just sits inert.
            row.name:SetText(("%s |cff888888(not known)|r"):format(name))
        else
            row.name:SetText(name)
        end

        row.bg:SetColorTexture(0, 0, 0, (i % 2 == 0) and 0.25 or 0)
        row.up:SetEnabled(i > 1)
        row.down:SetEnabled(i < #list)
        row:Show()
    end

    for i = #list + 1, #rows do rows[i]:Hide() end

    panel.content:SetHeight(math.max(LIST_H, #list * ROW_H))
end

-------------------------------------------------------------------------------
--  Public
-------------------------------------------------------------------------------
function Options.Refresh()
    if not panel then return end

    for i = 1, #checks do
        local cb = checks[i]
        cb:SetChecked(ns.db[cb._key] and true or false)
    end
    for i = 1, #sliders do
        local s = sliders[i]
        s._loading = true
        s:SetValue(ns.db[s._key])
        s._val:SetText(s._fmt(ns.db[s._key]))
        s._loading = nil
    end
    for _, seg in pairs(segments) do seg:Update() end
    for i = 1, #swatches do swatches[i]:Update() end
    for i = 1, #fontPickers do fontPickers[i]:Update() end
    for i = 1, #anchorGrids do anchorGrids[i]:Update() end

    refreshList()
end

function Options.Show()
    if not panel then BuildPanel() end
    panel:Show()
end

function Options.Hide()
    if panel then panel:Hide() end
end

function Options.Toggle()
    if panel and panel:IsShown() then
        Options.Hide()
    else
        Options.Show()
    end
end

-------------------------------------------------------------------------------
--  Blizzard settings entry, so the addon is findable without knowing /hc
-------------------------------------------------------------------------------
local function RegisterSettings()
    if not Settings or not Settings.RegisterCanvasLayoutCategory then return end
    local shim = CreateFrame("Frame")
    shim.name = "HealerCursor"

    local fs = shim:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 16, -16)
    fs:SetText("HealerCursor")

    local desc = shim:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", 16, -44)
    desc:SetText("Cursor-attached spell readiness icons.")

    local b = CreateFrame("Button", nil, shim, "UIPanelButtonTemplate")
    b:SetPoint("TOPLEFT", 16, -76)
    b:SetSize(200, 24)
    b:SetText("Open HealerCursor options")
    b:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
        Options.Show()
    end)

    local cat = Settings.RegisterCanvasLayoutCategory(shim, "HealerCursor")
    cat.ID = "HealerCursor"
    Settings.RegisterAddOnCategory(cat)
end

local init = CreateFrame("Frame")
init:RegisterEvent("PLAYER_LOGIN")
init:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    RegisterSettings()
end)
