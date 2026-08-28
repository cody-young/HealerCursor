-------------------------------------------------------------------------------
--  HealerCursor -- Core.lua
--
--  Copyright (C) 2026 Cody Young (codyy).
--  Licensed under the GNU General Public License v3 or later.
--  See LICENSE, or <https://www.gnu.org/licenses/gpl-3.0.html>.
--
--  Spell readiness state, event plumbing, saved variables.
--
--  DESIGN NOTE (this is the whole point of the addon):
--
--  Cooldown state is EVENT-DRIVEN, never polled. The engine tells us when
--  something changed (SPELL_UPDATE_COOLDOWN and friends); we coalesce every
--  event fired in the same frame into ONE recompute, and for the one thing
--  events cannot tell us -- "this cooldown has now finished" -- we schedule a
--  single timer at the exact expiry instead of watching the clock.
--
--  So the steady-state cost of this addon while a cooldown runs is: zero.
--  Not a throttled OnUpdate. Zero. The only per-frame code that ever exists
--  is the cursor glue in Display.lua, and that parks itself when the cursor
--  stops moving.
-------------------------------------------------------------------------------

local ADDON, ns = ...

local C_Spell            = C_Spell
local C_SpellBook        = C_SpellBook
local C_Timer            = C_Timer
local GetTime            = GetTime
local InCombatLockdown   = InCombatLockdown
local UnitHasVehicleUI   = UnitHasVehicleUI
local IsInInstance       = IsInInstance
local GetSpecialization  = GetSpecialization
local GetSpecializationInfo = GetSpecializationInfo
local huge               = math.huge
local issecretvalue      = issecretvalue   -- 12.x only; nil on older clients

ns.ADDON = ADDON

-------------------------------------------------------------------------------
--  Defaults
-------------------------------------------------------------------------------
local DEFAULTS = {
    enabled         = true,

    -- layout
    iconSize        = 22,
    spacing         = 3,
    offsetX         = 25,
    offsetY         = -29,
    direction       = "RIGHT",   -- RIGHT | LEFT | UP | DOWN
    perRow          = 8,
    alpha           = 1,

    -- behaviour
    cooldownMode    = "hide",    -- hide | desaturate
    desatAlpha      = 0.35,
    combatOnly      = false,
    instanceOnly    = false,
    hideUnusable    = false,     -- also hide when you cannot afford it
    hideInVehicle   = true,
    hideOnMouselook = false,
    showSwipe       = false,     -- only meaningful in desaturate mode
    showCharges     = true,

    -- charge count text
    countFont       = "Friz Quadrata TT",
    countSize       = 12,
    countOutline    = "OUTLINE",
    countR          = 1,
    countG          = 1,
    countB          = 1,
    countAnchor     = "BOTTOMRIGHT",
    countX          = -1,
    countY          = 2,

    -- cooldown countdown text (only ever visible in Dim mode -- in Hide mode
    -- the icon is off screen for the whole cooldown)
    showCDText      = false,
    cdFont          = "Friz Quadrata TT",
    cdSize          = 14,
    cdOutline       = "OUTLINE",
    cdR             = 1,
    cdG             = 0.82,
    cdB             = 0,
    cdAnchor        = "CENTER",
    cdX             = 0,
    cdY             = 0,
}
ns.DEFAULTS = DEFAULTS

-- Bumped whenever a shipped default changes in a way existing profiles should
-- pick up. A profile still holding the OLD default never had that setting
-- deliberately chosen, so moving it is safe; anything the user actually set is
-- left alone.
local DB_VERSION = 2

local SUPERSEDED = {
    [2] = { iconSize = 34, offsetX = 38, offsetY = -38 },
}

-------------------------------------------------------------------------------
--  Saved variables
-------------------------------------------------------------------------------
local function InitDB()
    HealerCursorDB = HealerCursorDB or {}
    local db = HealerCursorDB
    db.profile = db.profile or {}
    db.specs   = db.specs or {}
    for k, v in pairs(DEFAULTS) do
        if db.profile[k] == nil then db.profile[k] = v end
    end

    -- Fresh profiles already took the new defaults above, so the equality test
    -- below cannot match and this is a no-op for them.
    local from = db.version or 1
    if from < DB_VERSION then
        for v = from + 1, DB_VERSION do
            local old = SUPERSEDED[v]
            if old then
                for k, prev in pairs(old) do
                    if db.profile[k] == prev then db.profile[k] = DEFAULTS[k] end
                end
            end
        end
    end
    db.version = DB_VERSION

    ns.db = db.profile
    return db
end

-- Spell lists are per specialization: a resto shaman and an ele shaman want
-- completely different buttons, and nobody wants to re-enter the list on every
-- spec swap.
local currentSpecKey

local function SpecKey()
    local idx = GetSpecialization and GetSpecialization()
    local id  = idx and GetSpecializationInfo and GetSpecializationInfo(idx)
    return id and tostring(id) or "none"
end

-- The tracked-spell list for the spec we are in right now.
function ns.GetList()
    if not HealerCursorDB then return {} end
    local key = currentSpecKey or SpecKey()
    local list = HealerCursorDB.specs[key]
    if not list then
        list = {}
        HealerCursorDB.specs[key] = list
    end
    return list
end

function ns.CurrentSpecKey()
    return currentSpecKey or SpecKey()
end

-------------------------------------------------------------------------------
--  Fonts
--
--  LibSharedMedia is used when some other addon has already loaded it (which,
--  on any real UI, it has) so you get the same font list as the rest of your
--  interface. It is never embedded and never required -- without it you get
--  the four fonts that ship with the game.
-------------------------------------------------------------------------------
local BUILTIN_FONTS = {
    ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
    ["Arial Narrow"]     = "Fonts\\ARIALN.TTF",
    ["Skurri"]           = "Fonts\\skurri.TTF",
    ["Morpheus"]         = "Fonts\\MORPHEUS.TTF",
}
local FALLBACK = BUILTIN_FONTS["Friz Quadrata TT"]

local function GetLSM()
    return LibStub and LibStub("LibSharedMedia-3.0", true) or nil
end

--- Resolve a font name to a usable path. Always returns something: a font that
--  has gone away (addon disabled since the setting was saved) must not blank
--  out the text or throw inside SetFont.
function ns.FontPath(name)
    local lsm = GetLSM()
    if lsm then
        local ok, path = pcall(lsm.Fetch, lsm, "font", name, true)
        if ok and path then return path end
    end
    return BUILTIN_FONTS[name] or FALLBACK
end

--- Sorted list of every font name we can offer.
function ns.FontList()
    local out, seen = {}, {}
    local lsm = GetLSM()
    if lsm then
        local ok, tbl = pcall(lsm.HashTable, lsm, "font")
        if ok and type(tbl) == "table" then
            for k in pairs(tbl) do
                if not seen[k] then seen[k] = true; out[#out + 1] = k end
            end
        end
    end
    for k in pairs(BUILTIN_FONTS) do
        if not seen[k] then seen[k] = true; out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

-------------------------------------------------------------------------------
--  Spell state
--
--  ns.states is a parallel array to ns.GetList(); one entry per tracked spell,
--  reused across updates so a steady state allocates nothing.
-------------------------------------------------------------------------------
ns.states = {}

-- Talents can swap a spell for a different one (Chain Heal -> whatever). The
-- override is the ID whose cooldown and icon actually matter.
local function Resolve(spellID)
    if C_Spell.GetOverrideSpell then
        local o = C_Spell.GetOverrideSpell(spellID)
        if o and o > 0 then return o end
    end
    return spellID
end

local function IsKnown(spellID)
    if C_SpellBook and C_SpellBook.IsSpellKnownOrInSpellBook then
        return C_SpellBook.IsSpellKnownOrInSpellBook(spellID) and true or false
    end
    return C_Spell.GetSpellInfo(spellID) ~= nil
end

-------------------------------------------------------------------------------
--  Secret values (Midnight / 12.x)
--
--  Inside restricted content -- M+, raids, rated PvP -- the cooldown APIs hand
--  back NUMBERS that are "secret": startTime, duration, modRate, currentCharges,
--  cooldownStartTime, cooldownDuration. A secret number can be stored, passed
--  around and handed to an engine setter, but ANY Lua comparison or arithmetic
--  on one throws:
--
--      attempt to compare field 'duration' (a secret number value)
--
--  The BOOLEAN/identity fields beside them stay clean and readable everywhere:
--  isActive, isOnGCD, isEnabled, maxCharges. So every decision in this file is
--  made from those, and the secret numbers are only ever passed straight back
--  into the engine (SetCooldown, SetFormattedText), never inspected.
-------------------------------------------------------------------------------
local function IsSecret(v)
    return issecretvalue ~= nil and issecretvalue(v)
end

local function CleanNum(v)
    if IsSecret(v) then return false end
    return type(v) == "number"
end

-- How often to re-test a running cooldown when its timing is secret. Expiry
-- cannot be computed from a secret number and the client sends no event when a
-- cooldown simply runs out, so the clean isActive flag is re-read on a slow
-- poll -- and only while something is actually on cooldown.
local SECRET_POLL = 0.2

--- Recompute every tracked spell.
--  @return soonest  seconds until the next state change we cannot be told
--                   about by an event (nil when nothing is on cooldown)
--  @return changed  true when any icon's visible state actually moved
local function Recompute()
    local db     = ns.db
    local list   = ns.GetList()
    local states = ns.states
    local now     = GetTime()
    local soonest = huge
    local changed = false

    for i = 1, #list do
        local entry = list[i]
        local st = states[i]
        if not st then st = {}; states[i] = st end

        local base = entry.id
        local sid  = Resolve(base)

        local known    = IsKnown(base) or IsKnown(sid)
        local ready    = true
        local cooling  = false
        local cdStart, cdDur = nil, nil
        local charges, maxCharges = nil, nil
        local usable   = true

        if known then
            local cd = C_Spell.GetSpellCooldown(sid)
            if cd and cd.isEnabled ~= false then
                local act, gcd = cd.isActive, cd.isOnGCD
                if IsSecret(act) or IsSecret(gcd) then
                    -- Unreadable: fail OPEN. This display answers "what can I
                    -- press", so a spell we cannot judge is better shown than
                    -- silently hidden.
                    ready = true
                else
                    -- The engine already separates a real cooldown from the
                    -- global, which is what the old hand-rolled GCD maths was
                    -- for. A charge still in hand also reads isActive == false,
                    -- so this one test covers charge spells too.
                    cooling = act and not gcd or false
                    ready   = not cooling
                end
                if cooling then
                    -- Opaque in restricted content. Carried for the swipe and
                    -- countdown only, and handed straight to SetCooldown.
                    cdStart, cdDur = cd.startTime, cd.duration
                end
            end

            local ch = C_Spell.GetSpellCharges and C_Spell.GetSpellCharges(sid)
            if ch and CleanNum(ch.maxCharges) and ch.maxCharges > 1 then
                maxCharges = ch.maxCharges
                local chActive = ch.isActive
                if IsSecret(chActive) then
                    charges = ch.currentCharges
                elseif not chActive then
                    -- At max charges: the count is known from the clean
                    -- maxCharges without ever touching secret currentCharges.
                    charges = maxCharges
                else
                    charges = ch.currentCharges   -- display only, may be secret
                end
            end

            if db.hideUnusable and C_Spell.IsSpellUsable then
                -- Resource availability is exactly the sort of thing restricted
                -- content hides, so a secret answer must not be branched on --
                -- fail open and leave the icon visible.
                local ok = C_Spell.IsSpellUsable(sid)
                if IsSecret(ok) then
                    usable = true
                else
                    usable = ok and true or false
                end
            end
        end

        -- The one thing no event will tell us: when this cooldown ends.
        local timingSecret = false
        if cooling then
            if CleanNum(cdStart) and CleanNum(cdDur) then
                local remaining = (cdStart + cdDur) - now
                if remaining > 0 and remaining < soonest then soonest = remaining end
            else
                -- Expiry is uncomputable from a secret. Re-test the clean flag
                -- shortly; this is the only polling in the addon and it stops
                -- the moment nothing is on cooldown.
                timingSecret = true
                if SECRET_POLL < soonest then soonest = SECRET_POLL end
            end
        end

        local shown = known and ready and usable

        -- Timing and charge counts are compared ONLY when clean -- comparing a
        -- secret is what used to throw here. When they are secret the icon is
        -- refreshed unconditionally instead, which is why the flags below are
        -- gated on the setting that actually draws them.
        local chargeText = maxCharges and db.showCharges

        -- BOTH sides must be clean before a comparison: st.charges may still
        -- hold a secret from the previous pass even when the fresh read is
        -- clean. Crossing that boundary in either direction is itself a change;
        -- when both are secret the text is simply re-stamped if it is drawn.
        local chargeChanged
        local newClean, oldClean = CleanNum(charges), CleanNum(st.charges)
        if newClean and oldClean then
            chargeChanged = (charges ~= st.charges)
        elseif newClean or oldClean then
            chargeChanged = true
        else
            chargeChanged = chargeText and true or false
        end

        if st.sid ~= sid or st.known ~= known or st.shown ~= shown
           or st.cooling ~= cooling or st.maxCharges ~= maxCharges
           or chargeChanged
           or (timingSecret and (db.showSwipe or db.showCDText)) then
            changed = true
        end

        st.sid, st.base   = sid, base
        st.known, st.ready, st.usable, st.shown = known, ready, usable, shown
        st.cooling = cooling
        st.cdStart, st.cdDur = cdStart, cdDur
        st.charges, st.maxCharges = charges, maxCharges
    end

    -- Drop stale states when the list shrank.
    for i = #list + 1, #states do states[i] = nil end

    return (soonest < huge) and soonest or nil, changed
end

-------------------------------------------------------------------------------
--  Update scheduling
--
--  Two mechanisms, both self-disarming:
--    * dirty flag  -- many events in one frame collapse into one recompute
--    * wake timer  -- fires once, exactly when the next cooldown finishes
-------------------------------------------------------------------------------
local dirty, wakeTimer = false, nil

local function CancelWake()
    if wakeTimer then wakeTimer:Cancel(); wakeTimer = nil end
end

local Flush   -- forward declaration (the wake timer calls it)

local function ScheduleWake(seconds)
    CancelWake()
    if not seconds then return end
    -- A hair past expiry so the recompute sees the cooldown as finished
    -- rather than at 0.001 remaining and re-arming itself in a tight loop.
    wakeTimer = C_Timer.NewTimer(seconds + 0.03, function()
        wakeTimer = nil
        Flush()
    end)
end

function Flush()
    dirty = false
    if not ns.db then return end
    local soonest, changed = Recompute()
    ScheduleWake(soonest)
    ns.Display.Apply(changed)
end
ns.Flush = Flush

-- Hoisted so MarkDirty allocates nothing. SPELL_UPDATE_COOLDOWN fires many
-- times a second in combat and every one of them lands here.
local function DeferredFlush()
    if dirty then Flush() end
end

--- Ask for a recompute. Cheap and idempotent: call it from anywhere, as often
--  as you like -- everything in one frame collapses into a single Flush.
function ns.MarkDirty()
    if dirty then return end
    dirty = true
    C_Timer.After(0, DeferredFlush)
end

-------------------------------------------------------------------------------
--  Visibility gate
--
--  Answers "should the display exist at all right now". When this is false the
--  cursor glue is torn down completely and the addon costs literally nothing.
-------------------------------------------------------------------------------
function ns.ShouldShow()
    local db = ns.db
    if not db or not db.enabled then return false end
    if #ns.GetList() == 0 then return false end
    -- Preview overrides every gate: the user is looking at the options panel
    -- and needs to see what their sliders are doing.
    if ns.previewMode then return true end
    if db.combatOnly and not InCombatLockdown() then return false end
    if db.instanceOnly then
        local inInstance = IsInInstance()
        if not inInstance then return false end
    end
    if db.hideInVehicle and UnitHasVehicleUI and UnitHasVehicleUI("player") then
        return false
    end
    if ns.optionsOpen then return false end
    return true
end

-------------------------------------------------------------------------------
--  Events
-------------------------------------------------------------------------------
local ev = CreateFrame("Frame")

-- Anything that can change a cooldown, a charge count, or affordability.
local COOLDOWN_EVENTS = {
    SPELL_UPDATE_COOLDOWN = true,
    SPELL_UPDATE_CHARGES  = true,
    SPELL_UPDATE_USABLE   = true,
}

-- Anything that can change WHICH spells you have.
local KNOWN_EVENTS = {
    SPELLS_CHANGED                  = true,
    PLAYER_TALENT_UPDATE            = true,
    TRAIT_CONFIG_UPDATED            = true,
    UPDATE_SHAPESHIFT_FORM          = true,
}

for e in pairs(COOLDOWN_EVENTS) do ev:RegisterEvent(e) end
for e in pairs(KNOWN_EVENTS)    do ev:RegisterEvent(e) end
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("UNIT_ENTERED_VEHICLE")
ev:RegisterEvent("UNIT_EXITED_VEHICLE")

ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        InitDB()
        currentSpecKey = SpecKey()
        ev:UnregisterEvent("ADDON_LOADED")
        return
    end

    if not ns.db then return end

    if event == "PLAYER_SPECIALIZATION_CHANGED" then
        if arg1 and arg1 ~= "player" then return end
        local key = SpecKey()
        if key ~= currentSpecKey then
            currentSpecKey = key
            -- Whole different spell list: rebuild the icons, not just states.
            ns.states = {}
            ns.Display.Rebuild()
            if ns.Options and ns.Options.Refresh then ns.Options.Refresh() end
        end
        ns.MarkDirty()
        return
    end

    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        currentSpecKey = SpecKey()
        ns.Display.Rebuild()
        ns.MarkDirty()
        return
    end

    if KNOWN_EVENTS[event] then
        -- A talent swap can change icons and override IDs, so refresh the
        -- textures too, not just the readiness state.
        ns.Display.RefreshIcons()
        ns.MarkDirty()
        return
    end

    -- Combat/vehicle edges only move the visibility gate; state is unchanged.
    if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED"
       or event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        ns.Display.UpdateVisibility()
        return
    end

    ns.MarkDirty()
end)

-------------------------------------------------------------------------------
--  Spell list mutation (used by the options UI)
-------------------------------------------------------------------------------

--- Add a spell to the current spec's list. Returns true, or false plus a
--  reason string.
function ns.AddSpell(spellID)
    spellID = tonumber(spellID)
    if not spellID or spellID <= 0 then return false, "invalid" end
    local info = C_Spell.GetSpellInfo(spellID)
    if not info then return false, "unknown" end

    local list = ns.GetList()
    for i = 1, #list do
        if list[i].id == spellID then return false, "duplicate" end
    end
    list[#list + 1] = { id = spellID }
    ns.Display.Rebuild()
    ns.MarkDirty()
    return true
end

function ns.RemoveSpell(index)
    local list = ns.GetList()
    if not list[index] then return end
    table.remove(list, index)
    ns.states = {}
    ns.Display.Rebuild()
    ns.MarkDirty()
end

function ns.MoveSpell(index, delta)
    local list = ns.GetList()
    local target = index + delta
    if not list[index] or not list[target] then return end
    list[index], list[target] = list[target], list[index]
    ns.states = {}
    ns.Display.Rebuild()
    ns.MarkDirty()
end

--- Pull the spells currently sitting in Blizzard's Cooldown Manager into this
--  spec's list. Saves setting the whole thing up by hand, and it is a one-shot
--  copy -- the list is yours to edit afterwards, not a live mirror.
--  @return added, skipped
function ns.ImportFromCDM()
    local CV = C_CooldownViewer
    if not CV or not CV.GetCooldownViewerCategorySet
       or not CV.GetCooldownViewerCooldownInfo then
        return 0, 0
    end

    -- Essential and Utility are the two icon categories; the others are buff
    -- and bar trackers, which are not "buttons I can press".
    local cats = {}
    local E = Enum and Enum.CooldownViewerCategory
    cats[#cats + 1] = (E and E.Essential) or 0
    cats[#cats + 1] = (E and E.Utility) or 1

    local list = ns.GetList()
    local seen = {}
    for i = 1, #list do seen[list[i].id] = true end

    local added, skipped = 0, 0
    for _, cat in ipairs(cats) do
        -- `false` = only what this character actually knows.
        local ids = CV.GetCooldownViewerCategorySet(cat, false)
        if ids then
            for _, cdID in ipairs(ids) do
                local info = CV.GetCooldownViewerCooldownInfo(cdID)
                -- Store the BASE spell, not the override: overrides come and go
                -- with talents and are re-resolved live in Display.
                local sid = info and info.spellID
                if sid and sid > 0 then
                    if seen[sid] then
                        skipped = skipped + 1
                    else
                        seen[sid] = true
                        list[#list + 1] = { id = sid }
                        added = added + 1
                    end
                end
            end
        end
    end

    if added > 0 then
        ns.states = {}
        ns.Display.Rebuild()
        ns.MarkDirty()
    end
    return added, skipped
end

--- Resolve whatever the player is dragging into a spell ID.
--  Handles spellbook drags, action bar drags, and macros that cast a spell.
function ns.SpellIDFromCursor()
    if type(GetCursorInfo) ~= "function" then return nil end
    local kind, a, b, c = GetCursorInfo()

    if kind == "spell" then
        -- Modern clients hand back the spell ID directly in the 3rd return;
        -- older shapes give a spellbook index that needs a lookup.
        local sid = tonumber(c)
        if not sid and type(b) == "string" then
            sid = tonumber(b:match("spell:(%d+)"))
        end
        if not sid and type(a) == "number" and C_SpellBook
           and C_SpellBook.GetSpellBookItemInfo then
            local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, a,
                Enum.SpellBookSpellBank.Player)
            if ok and type(info) == "table" then sid = tonumber(info.spellID) end
        end
        return sid
    end

    if kind == "action" and type(a) == "number" and GetActionInfo then
        local ok, actionType, actionID = pcall(GetActionInfo, a)
        if ok then
            if actionType == "spell" and tonumber(actionID) then
                return tonumber(actionID)
            end
            if actionType == "macro" and GetMacroSpell then
                return tonumber(GetMacroSpell(actionID))
            end
        end
    end

    return nil
end

--- Accepts a spell ID or a spell name typed by the user.
function ns.ResolveInput(text)
    if not text then return nil end
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return nil end
    local asID = tonumber(text)
    if asID then
        return C_Spell.GetSpellInfo(asID) and asID or nil
    end
    local info = C_Spell.GetSpellInfo(text)
    return info and info.spellID or nil
end

-------------------------------------------------------------------------------
--  Slash command
-------------------------------------------------------------------------------
--- Explain, in one screenful, exactly why the display is or is not on screen
--  right now. Every gate and every tracked spell's live state.
local function PrintStatus()
    local db, list, states = ns.db, ns.GetList(), ns.states
    local function yn(v) return v and "|cff40ff40yes|r" or "|cffff4040no|r" end

    print("|cff0cd29fHealerCursor|r status")
    print(("  showing: %s   tracked: %d   icons active: %s"):format(
        yn(ns.ShouldShow()), #list, yn(ns.Display.IsActive())))

    -- Gates, in the order ShouldShow tests them. Only failing ones matter.
    local blockers = {}
    if not db.enabled then blockers[#blockers + 1] = "disabled (/hc toggle)" end
    if #list == 0 then blockers[#blockers + 1] = "no spells tracked" end
    if db.combatOnly and not InCombatLockdown() then
        blockers[#blockers + 1] = "combat-only, not in combat"
    end
    if db.instanceOnly and not IsInInstance() then
        blockers[#blockers + 1] = "instance-only, not in an instance"
    end
    if db.hideInVehicle and UnitHasVehicleUI and UnitHasVehicleUI("player") then
        blockers[#blockers + 1] = "in a vehicle"
    end
    if ns.optionsOpen then blockers[#blockers + 1] = "options panel open" end
    if #blockers > 0 then
        print("  |cffff8040blocked by:|r " .. table.concat(blockers, ", "))
    end

    print(("  mode: %s   (in hide mode an unready spell is not drawn at all)"):format(
        db.cooldownMode))

    local ready, cooling, unknown = 0, 0, 0
    local now = GetTime()
    for i = 1, #list do
        local st = states[i]
        local name = C_Spell.GetSpellName(list[i].id) or ("spell " .. list[i].id)
        if not st then
            print(("   %d. %s  |cff888888(no state yet)|r"):format(i, name))
        elseif not st.known then
            unknown = unknown + 1
            print(("   %d. %s  |cff888888not known|r"):format(i, name))
        elseif st.shown then
            ready = ready + 1
            print(("   %d. %s  |cff40ff40ready|r"):format(i, name))
        else
            cooling = cooling + 1
            local afford = (not st.usable) and " |cffff4040(cannot afford)|r" or ""
            if CleanNum(st.cdStart) and CleanNum(st.cdDur) then
                local left = (st.cdStart + st.cdDur) - now
                print(("   %d. %s  |cffff8040%.0fs|r%s"):format(i, name,
                    left > 0 and left or 0, afford))
            else
                -- Restricted content: the remaining time is a secret number.
                print(("   %d. %s  |cffff8040on cooldown|r |cff888888(timing hidden)|r%s")
                    :format(i, name, afford))
            end
        end
    end

    print(("  %d ready, %d on cooldown, %d not known"):format(ready, cooling, unknown))
    if ready == 0 and #list > 0 and db.cooldownMode == "hide" then
        print("  |cffff8040Nothing is ready, so hide mode correctly draws nothing.|r")
        print("  |cffff8040Track some rotational spells too, or switch to Dim mode.|r")
    end
end

SLASH_HEALERCURSOR1 = "/healercursor"
SLASH_HEALERCURSOR2 = "/hc"
SlashCmdList.HEALERCURSOR = function(msg)
    if not ns.db then return end
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "status" then
        PrintStatus()
        return
    end
    if msg == "toggle" then
        ns.db.enabled = not ns.db.enabled
        ns.Display.UpdateVisibility()
        print(("|cff0cd29fHealerCursor|r: %s"):format(ns.db.enabled and "enabled" or "disabled"))
        return
    end
    ns.Options.Toggle()
end
