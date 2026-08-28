-------------------------------------------------------------------------------
--  HealerCursor -- Display.lua
--
--  Copyright (C) 2026 Cody Young (codyy).
--  Licensed under the GNU General Public License v3 or later.
--  See LICENSE, or <https://www.gnu.org/licenses/gpl-3.0.html>.
--
--  The icons and the cursor glue.
--
--  CURSOR TRACKING, and why it is not just an OnUpdate:
--
--  Position cannot be eased or throttled -- a throttled follow visibly steps
--  behind the pointer -- so while the cursor MOVES we genuinely do want one
--  reposition per rendered frame. The trick is that a cursor which is not
--  moving needs no work at all, and in the case that actually matters (flying
--  through a city, hand off the mouse, camera held) it is not moving.
--
--  So: the per-frame handler parks itself after one second of stillness, and a
--  self-stopping animation ticker -- which sleeps in the C engine and costs no
--  Lua at frame rate -- watches at 20 Hz for the first moved pixel and re-arms
--  it. Worst case you are ~50ms late on the first pixel of motion after a
--  pause, which is invisible. Best case, which is most of the time, this addon
--  runs no per-frame code whatsoever.
--
--  When the display is gated off entirely (out of combat, no spells, options
--  open) both the handler and the ticker are torn down and the cost is zero.
--
--  MOUSE INPUT: everything here is click-through and motion-through, always.
--  An icon riding the pointer that captures the mouse would break every
--  [@mouseover] macro in a healer's kit, which would be worse than useless.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local Display = {}
ns.Display = Display

local GetCursorPosition = GetCursorPosition
local GetTime           = GetTime
local UIParent          = UIParent
local IsMouselooking    = IsMouselooking
local C_Spell           = C_Spell
local floor             = math.floor

local STILL_AFTER = 1.0    -- park the per-frame follow after this much stillness
local WATCH_FAST  = 0.05   -- 20 Hz re-arm watch
local WATCH_SLOW  = 0.15   -- cadence once the cursor has been still a long time
local AFK_AFTER   = 30

-------------------------------------------------------------------------------
--  Frames
--
--  Both created in this file's main chunk on purpose: the engine bills a
--  script handler's whole call tree to whichever addon created the frame that
--  carries it, so being born here is what makes our cost show up under
--  HealerCursor in a profiler instead of somewhere misleading.
-------------------------------------------------------------------------------
local anchor = CreateFrame("Frame", "HealerCursorAnchor", UIParent)
anchor:SetSize(1, 1)
anchor:SetFrameStrata("FULLSCREEN_DIALOG")
anchor:SetFrameLevel(200)
anchor:EnableMouse(false)
anchor:EnableMouseMotion(false)
if anchor.SetMouseClickEnabled then anchor:SetMouseClickEnabled(false) end
anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT", 0, 0)
anchor:Hide()
ns.anchor = anchor

-- Hosts the watch ticker. Never drawn; exists only so the animation has
-- somewhere to live while the anchor itself is parked or hidden.
local driver = CreateFrame("Frame", nil, UIParent)
driver:SetSize(1, 1)
driver:SetPoint("TOPLEFT")

-------------------------------------------------------------------------------
--  Cursor glue
-------------------------------------------------------------------------------
local active, armed = false, false
local lastX, lastY, stillSince = nil, nil, 0

local function Reposition(x, y)
    local db = ns.db
    local s = UIParent:GetEffectiveScale()
    anchor:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
        floor(x / s + 0.5) + db.offsetX,
        floor(y / s + 0.5) + db.offsetY)
end

local function OnMotion(self, elapsed)
    local x, y = GetCursorPosition()
    if x ~= lastX or y ~= lastY then
        lastX, lastY = x, y
        stillSince = GetTime()
        Reposition(x, y)
    elseif GetTime() - stillSince > STILL_AFTER then
        -- Settled. Hand the watch back to the ticker and stop paying per frame.
        self:SetScript("OnUpdate", nil)
        armed = false
    end
end

local ag       = driver:CreateAnimationGroup()
local animStep = ag:CreateAnimation("Animation")
local interval = WATCH_FAST
ag:SetLooping("REPEAT")
animStep:SetDuration(WATCH_FAST)

local function Arm()
    if armed then return end
    armed = true
    stillSince = GetTime()
    anchor:SetScript("OnUpdate", OnMotion)
end

ag:SetScript("OnLoop", function()
    if not active then ag:Stop(); return end

    if not armed then
        local x, y = GetCursorPosition()
        if x ~= lastX or y ~= lastY then
            lastX, lastY = x, y
            Reposition(x, y)
            Arm()
        end
    end

    -- During mouselook the hardware cursor is gone and its position is frozen,
    -- so the icons would otherwise sit at a stale spot.
    local wantAlpha = ns.db.alpha
    if ns.db.hideOnMouselook and IsMouselooking and IsMouselooking() then
        wantAlpha = 0
    end
    if anchor:GetAlpha() ~= wantAlpha then anchor:SetAlpha(wantAlpha) end

    -- Long stillness (AFK, reading, camera held): drop to the slow cadence.
    -- Costs at most one 0.15s catch-up on the next movement.
    local want = (armed or (GetTime() - stillSince) <= AFK_AFTER)
        and WATCH_FAST or WATCH_SLOW
    if want ~= interval then
        interval = want
        ag:Stop()
        animStep:SetDuration(want)
        ag:Play()
    end
end)

local function Activate()
    if active then return end
    active = true
    lastX, lastY = nil, nil
    anchor:SetAlpha(ns.db.alpha)
    anchor:Show()
    local x, y = GetCursorPosition()
    lastX, lastY = x, y
    Reposition(x, y)
    Arm()
    interval = WATCH_FAST
    animStep:SetDuration(WATCH_FAST)
    ag:Play()
end

local function Deactivate()
    if not active then return end
    active = false
    armed = false
    anchor:SetScript("OnUpdate", nil)
    ag:Stop()
    anchor:Hide()
end

-------------------------------------------------------------------------------
--  Icons
-------------------------------------------------------------------------------
local icons = {}

local function AcquireIcon(i)
    local ic = icons[i]
    if ic then return ic end

    ic = CreateFrame("Frame", nil, anchor)
    ic:EnableMouse(false)
    ic:EnableMouseMotion(false)
    if ic.SetMouseClickEnabled then ic:SetMouseClickEnabled(false) end
    ic:SetFrameStrata("FULLSCREEN_DIALOG")
    ic:SetFrameLevel(200 + i)

    ic.tex = ic:CreateTexture(nil, "ARTWORK")
    ic.tex:SetAllPoints()
    ic.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the stock icon border

    ic.border = ic:CreateTexture(nil, "BACKGROUND")
    ic.border:SetPoint("TOPLEFT", -1, 1)
    ic.border:SetPoint("BOTTOMRIGHT", 1, -1)
    ic.border:SetColorTexture(0, 0, 0, 0.9)

    ic.cd = CreateFrame("Cooldown", nil, ic, "CooldownFrameTemplate")
    ic.cd:SetAllPoints()
    ic.cd:SetDrawEdge(false)
    ic.cd:SetDrawBling(false)
    ic.cd:EnableMouse(false)
    if ic.cd.SetMouseClickEnabled then ic.cd:SetMouseClickEnabled(false) end
    -- Keep OmniCC and friends off this widget: they replace the countdown with
    -- their own FontString, which would silently ignore every font setting here.
    ic.cd.noCooldownCount = true
    ic.cd:SetHideCountdownNumbers(true)

    ic.count = ic:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    ic.count:SetPoint("BOTTOMRIGHT", -2, 2)

    icons[i] = ic
    return ic
end

-- The countdown number is a FontString the C widget creates on the Cooldown
-- frame. It does not exist until the widget has drawn once, so this is looked
-- up lazily and only cached on success.
local function CountdownFS(cd)
    if cd._hcFS then return cd._hcFS end
    local regions = { cd:GetRegions() }
    for i = 1, #regions do
        local r = regions[i]
        if r and r.GetObjectType and r:GetObjectType() == "FontString" then
            cd._hcFS = r
            return r
        end
    end
    return nil
end

--- Font/colour/placement for the cooldown countdown.
--  Re-applied after every SetCooldown: the engine re-asserts its own baseline
--  when the widget restarts, and it must stay PARENTED to the Cooldown frame --
--  reparenting it makes the engine re-centre it and ignore our offsets.
local function StyleCountdown(ic)
    local db = ns.db
    if not db.showCDText then return end
    local fs = CountdownFS(ic.cd)
    if not fs then return end
    fs:SetFont(ns.FontPath(db.cdFont), db.cdSize, db.cdOutline)
    fs:SetTextColor(db.cdR, db.cdG, db.cdB)
    fs:ClearAllPoints()
    fs:SetPoint(db.cdAnchor, ic.cd, db.cdAnchor, db.cdX, db.cdY)
end

--- Font/colour/placement for both text layers on one icon.
local function StyleIcon(ic)
    local db = ns.db
    ic.count:SetFont(ns.FontPath(db.countFont), db.countSize, db.countOutline)
    ic.count:SetTextColor(db.countR, db.countG, db.countB)
    ic.count:ClearAllPoints()
    ic.count:SetPoint(db.countAnchor, ic, db.countAnchor, db.countX, db.countY)

    ic.cd:SetHideCountdownNumbers(not db.showCDText)
    StyleCountdown(ic)
end

local DIRS = {
    RIGHT = { point = "LEFT",   ax =  1, ay =  0, wx =  0, wy = -1 },
    LEFT  = { point = "RIGHT",  ax = -1, ay =  0, wx =  0, wy = -1 },
    UP    = { point = "BOTTOM", ax =  0, ay =  1, wx =  1, wy =  0 },
    DOWN  = { point = "TOP",    ax =  0, ay = -1, wx =  1, wy =  0 },
}

--- Position `list` (an array of icon frames) in a grid growing away from the
--  anchor. Only called when the set of visible icons actually changes.
local function Layout(shown)
    local db     = ns.db
    local dir    = DIRS[db.direction] or DIRS.RIGHT
    local size   = db.iconSize
    local step   = size + db.spacing
    local perRow = (db.perRow and db.perRow > 0) and db.perRow or 8

    for n = 1, #shown do
        local ic = shown[n]
        local a = (n - 1) % perRow          -- along the growth axis
        local w = floor((n - 1) / perRow)   -- wrap index
        ic:ClearAllPoints()
        ic:SetPoint(dir.point, anchor, "CENTER",
            (dir.ax * a + dir.wx * w) * step,
            (dir.ay * a + dir.wy * w) * step)
    end
end

-------------------------------------------------------------------------------
--  State application
-------------------------------------------------------------------------------
local shownBuf   = {}
local lastLayout = -1   -- signature of the last laid-out set

-- Re-evaluate the gate (combat edge, vehicle, options opened). Apply owns
-- both the activate and the deactivate paths, so this is just a forced pass.
function Display.UpdateVisibility()
    if not ns.db then return end
    if ns.previewMode then return end
    Display.Apply(true)
end

--- Push the computed spell states onto the icons.
--  @param changed  false when Core knows nothing moved, letting us skip the
--                  per-icon writes entirely
function Display.Apply(changed)
    if not ns.db then return end
    if ns.previewMode then return end   -- the options panel owns the icons

    if not ns.ShouldShow() then
        Deactivate()
        return
    end
    if changed == false and active then return end

    local db       = ns.db
    local states   = ns.states
    local list     = ns.GetList()
    local hideMode = (db.cooldownMode == "hide")
    local size     = db.iconSize

    local count = 0
    local sig   = 0

    for i = 1, #list do
        local st = states[i]
        local ic = icons[i]
        if st and ic then
            -- In hide mode an unready spell leaves the display entirely; in
            -- desaturate mode it stays put and greys out. Either way an
            -- unknown spell (wrong spec, untalented) is never drawn.
            local visible = st.known and (not hideMode or st.shown)

            if visible then
                count = count + 1
                shownBuf[count] = ic
                sig = sig * 31 + i

                ic:SetSize(size, size)

                if st.shown then
                    ic.tex:SetDesaturated(false)
                    ic:SetAlpha(1)
                else
                    ic.tex:SetDesaturated(true)
                    ic:SetAlpha(db.desatAlpha)
                end

                -- The swipe only earns its keep in desaturate mode; in hide
                -- mode the icon is off screen while the cooldown runs.
                -- st.cooling is a CLEAN boolean from Core; the start/duration
                -- beside it are secret numbers in restricted content, so they
                -- are never tested here -- just handed to the engine, which
                -- takes secrets natively.
                if (db.showSwipe or db.showCDText) and not hideMode and st.cooling then
                    ic.cd:SetCooldown(st.cdStart, st.cdDur)
                    ic.cd:SetDrawSwipe(db.showSwipe)
                    StyleCountdown(ic)
                    ic.cd:Show()
                else
                    ic.cd:Clear()
                    ic.cd:Hide()
                end

                -- maxCharges is clean, so the decision to draw is safe; the
                -- count itself may be secret, which SetFormattedText accepts
                -- (SetText would too, but never a comparison or concat).
                if db.showCharges and st.maxCharges and st.maxCharges > 1 then
                    if type(st.charges) == "number" then
                        ic.count:SetFormattedText("%d", st.charges)
                        ic.count:Show()
                    else
                        ic.count:Hide()
                    end
                else
                    ic.count:Hide()
                end

                if not ic:IsShown() then ic:Show() end
            elseif ic:IsShown() then
                ic:Hide()
                ic.cd:Clear()
            end
        elseif ic and ic:IsShown() then
            ic:Hide()
        end
    end

    for n = count + 1, #shownBuf do shownBuf[n] = nil end

    -- Nothing ready to draw: stop following the cursor until something is.
    if count == 0 then
        Deactivate()
        lastLayout = -1
        return
    end

    Activate()

    if sig ~= lastLayout then
        lastLayout = sig
        Layout(shownBuf)
    end
end

--- Re-read every icon texture. Cheap, and only needed when talents change
--  which spell an entry actually resolves to.
function Display.RefreshIcons()
    local list = ns.GetList()
    for i = 1, #list do
        local ic = icons[i]
        if ic then
            local sid = list[i].id
            if C_Spell.GetOverrideSpell then
                local o = C_Spell.GetOverrideSpell(sid)
                if o and o > 0 then sid = o end
            end
            ic.tex:SetTexture(C_Spell.GetSpellTexture(sid))
        end
    end
end

--- Full rebuild: the spell list itself changed (add/remove/reorder/spec swap).
function Display.Rebuild()
    if not ns.db then return end
    local list = ns.GetList()
    local size = ns.db.iconSize

    for i = 1, #list do
        local ic = AcquireIcon(i)
        ic:SetSize(size, size)
        StyleIcon(ic)
        ic:Hide()
    end
    -- Retire icons past the end of the list.
    for i = #list + 1, #icons do
        icons[i]:Hide()
        icons[i].cd:Clear()
    end

    Display.RefreshIcons()
    lastLayout = -1       -- force a re-layout on the next Apply

    -- The list changed. If the options preview is up it owns the icons, so
    -- refresh THAT -- UpdateVisibility deliberately does nothing while
    -- previewing, which would otherwise swallow adds, removes and imports
    -- until some other setting happened to be touched.
    if ns.previewMode then
        Display.SetPreview(true)
    else
        Display.UpdateVisibility()
    end
end

--- Any settings change (size, spacing, offsets, direction, mode).
function Display.ApplySettings()
    if not ns.db then return end
    anchor:SetAlpha(ns.db.alpha)
    lastLayout = -1
    if active then
        local x, y = GetCursorPosition()
        Reposition(x, y)
    end
    if ns.previewMode then
        Display.SetPreview(true)   -- keep the options preview in step
    else
        Display.Rebuild()
        ns.MarkDirty()
    end
end

--- Preview mode for the options panel: force every configured icon on screen
--  regardless of readiness so the user can see what they are adjusting.
function Display.SetPreview(on)
    ns.previewMode = on and true or false
    lastLayout = -1
    if on then
        local list = ns.GetList()
        if #list == 0 then Deactivate(); return end
        for i = 1, #list do
            local ic = AcquireIcon(i)
            ic:SetSize(ns.db.iconSize, ns.db.iconSize)
            StyleIcon(ic)
            ic.tex:SetDesaturated(false)
            ic:SetAlpha(1)
            ic.cd:Clear(); ic.cd:Hide()
            ic.count:Hide()
            ic:Show()
            shownBuf[i] = ic
        end
        for n = #list + 1, #shownBuf do shownBuf[n] = nil end
        Display.RefreshIcons()
        Activate()
        Layout(shownBuf)
    else
        Display.UpdateVisibility()
    end
end

function Display.IsActive() return active end
