# HealerCursor

Cursor-attached spell readiness icons. Spells you can press right now appear
next to your pointer; spells on cooldown get out of the way.

The point is micro-decisions: your eyes are already on your cursor when you are
healing, so that is where "what can I press" should live. Your Cooldown Manager
stays where it is and keeps showing you the actual timers.

## Using it

`/hc` opens the options. Or Game Menu → Options → AddOns → HealerCursor.

- **Import from Cooldown Manager** copies whatever your Blizzard Cooldown
  Manager is tracking into the list. One-time copy, edit it afterwards.
- Or drag a spell from your spellbook / action bars onto the drop box.
- Or type a spell name or ID.

Spell lists are saved **per specialization**. Everything else (size, position,
opacity, behaviour) is shared across all specs.

`/hc toggle` turns the display on and off without opening anything.

`/hc status` prints exactly why the display is or is not on screen right now:
every visibility gate, and every tracked spell's live ready / on-cooldown /
not-known state. Start here if something looks wrong.

## Text

The **Text** tab controls the charge count and the cooldown countdown
separately: font, size, outline, colour, and a 3x3 anchor grid with X/Y
offsets. Fonts come from LibSharedMedia when any addon on your UI has loaded it
(so you get the same list as everything else); without it you get the four that
ship with the game. It is never embedded and never required.

Cooldown text is **only visible in Dim mode**. In Hide mode the icon is off
screen for the entire cooldown, so there is nothing to count down on. It is
drawn by the game engine rather than a Lua ticker, so it costs no frame time --
which is also why OmniCC is kept off these icons, since it would replace the
countdown with its own and silently ignore every setting here.

## Why it is light

The whole reason this addon exists is that the alternatives cost more frame
time than the feature is worth. Two decisions do almost all of that work:

**Cooldown state is never polled.** The game already tells us when a cooldown,
charge count, or resource state changes. Every event that fires in the same
frame collapses into a single recompute, and the one thing no event covers --
"this cooldown just finished" -- is handled by scheduling one timer for the
exact moment of expiry. While a cooldown runs, this addon does nothing at all.

Notably, the global cooldown is ignored. Without that, every cast would blink
every icon out for a second and a half. The engine reports this directly as a
clean `isOnGCD` flag, so no timing maths is needed to spot it, and the recompute
on every GCD tick finds state unchanged and skips all the drawing work.

**Secret values (Midnight / 12.x).** Inside restricted content -- Mythic+, raids,
rated PvP -- the cooldown APIs return *secret* numbers. `startTime`, `duration`
and `currentCharges` can be passed to the engine but throw on any comparison or
arithmetic in addon Lua. The boolean flags beside them (`isActive`, `isOnGCD`,
`maxCharges`) stay readable, so every decision here is made from those, and the
secret numbers are only ever handed straight back to `SetCooldown` and
`SetFormattedText`.

One consequence: expiry cannot be computed while timing is secret, and the client
sends no event when a cooldown merely runs out. In that case only -- in restricted
content, and only while something is actually on cooldown -- the clean `isActive`
flag is re-tested five times a second. Everywhere else the exact-expiry timer
still does the job and nothing polls at all.

**The cursor follow parks itself.** Position cannot be throttled without
visibly lagging the pointer, so while the cursor moves there is one reposition
per rendered frame. But a cursor that is not moving needs nothing, and while
you are flying across a city with your hand off the mouse it is not moving. So
the per-frame handler removes itself after one second of stillness, and a
self-stopping animation ticker -- which sleeps inside the C engine and costs no
Lua at frame rate -- watches at 20 Hz for the first moved pixel and puts it
back. After 30 seconds of stillness even that drops to 0.15s.

When there is nothing to show at all -- out of combat with "only in combat" on,
no spells configured, every tracked spell on cooldown -- the handler and the
ticker are both torn down and the addon costs literally nothing.

## Mouse input

Every frame this addon creates is click-through and motion-through, always,
with no option to change it. Icons riding your pointer that capture the mouse
would break every `[@mouseover]` macro you own, which for a healer would be
considerably worse than having no addon.

## Files

| File | What is in it |
| --- | --- |
| `Core.lua` | Spell state, event plumbing, saved variables, slash command |
| `Display.lua` | Icons, layout, cursor follow |
| `Options.lua` | Configuration window |

## License

GPLv3 or later. See [LICENSE](LICENSE).
