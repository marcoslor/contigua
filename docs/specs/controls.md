# Phone controls

Prefix: `CTRL`. Owner docs: `docs/design/focus.md`, `docs/design/controls.md`,
`docs/design/phone-mirror.md`, `docs/PROTOCOL.md` ("Focus and Do Not Disturb",
"Phone screen", "Ringer", "Volume"). Last reviewed: 2026-11-13, against
main `8a313043` (the dark panel removed, #142).

## Purpose

Every value the Mac sets on the phone (Do Not Disturb, the ringer, the volume,
the phone screen's panel, keep-awake, clipboard and notification gates, audio
routing) has a person on both ends. This spec pins the one rule that keeps them
from fighting: **a Mac intent is applied on its edge, not re-asserted.** A
change the person makes on the phone stands until the Mac-side intent changes
again, and a reconnect sends a value only when it changed while the two were
apart.

The phone's own screen is not one of these controls for app windows: they run
in a display group of their own (app-windows.md WIN-74) and never wake, hold or
sleep display 0 (phone-app.md PHONE-22). Turn Off Phone Screen is the one panel
control, and it follows CTRL-5 and CTRL-6.

## User stories

| ID | Priority | Story |
|---|---|---|
| CTRL-S1 | P1 | As a person, I want a control I changed on the phone to stay changed, so that Contigua does not undo my choice behind my back. |
| CTRL-S2 | P1 | As a person, I want a Focus or a menu pick to reach the phone when I make it, so that the Mac's controls still do what they say. |
| CTRL-S3 | P1 | As a person, I want the phone's screen to come back to me the moment I unlock or use it, so that closing a Mac window never blacks it out in my hand. (Met by phone-app.md PHONE-22 since #142: app windows never touch the phone's own screen.) |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| CTRL-1 | WHEN the Mac-side intent for a control changes (a Focus starts or ends, a menu pick, a Shortcut, an MCP call, a panel control, the window's button), THE Mac SHALL send that control's new value to the phone once, on that edge. | K2 `ControlIntentTests`; e2e `focus`, `controls` |
| CTRL-2 | WHEN a Mac Focus starts or ends, THE Mac SHALL apply its DND as that edge (`priority`/`alarms`/`none` for a start, `off` for an end). | e2e `dnd-edge` `[CTRL-2]`, K2 `ControlIntentTests` |
| CTRL-3 | WHEN a phone connects (the first `state` of a session) and the Mac's memory already holds the wanted value for that phone and control, THE Mac SHALL send nothing for that control. | e2e `dnd-edge` `[CTRL-3]`, K2 `ControlIntentTests.testReconnect*` |
| CTRL-4 | WHEN the person changes a control on the phone, THE phone's value SHALL stand until the Mac-side intent changes again; a restore SHALL clear only a value Contigua set. | e2e `dnd-edge` `[CTRL-4]`, K1 `DndSessionTest` |
| CTRL-5 | WHEN the person wakes the phone's own screen after "Turn Off Phone Screen", THE hold SHALL end, and NO later reconnect or reopened phone window SHALL re-assert it; only a new Mac-side action applies it. | e2e `panel-edge` `[CTRL-5]` |
| CTRL-6 | WHEN a phone window opens with "Turn Off Phone Screen" remembered, THE Mac SHALL apply it only when this phone has not received that value since the person ended it. | e2e `panel-edge` `[CTRL-6]`, K2 `ControlIntentTests.testPanel*` |
| CTRL-7 | ~~WHEN the last Mac window closes and the phone is still as Contigua left it (no unlock, no user activity on display 0, no person's wake since Contigua's own wake), THE phone SHALL put itself back to sleep; IF the person unlocked, used or woke it since, THE phone SHALL leave the screen alone and log the closed reason `person_unlocked` or `person_active`.~~ **Removed 2026-11-13 (#142):** app windows now run in a display group of their own (app-windows.md WIN-74): Contigua never wakes the panel for them, so it has no sleep of its own to undo, and the phone's screen is always the person's (phone-app.md PHONE-22). | — |
| CTRL-8 | WHEN no Mac-side intent changes, THE Mac SHALL NOT re-send a control's value on a timer, on every `state`, or on a connect beyond CTRL-3. | audit table in `docs/design/controls.md`; e2e `dnd-edge`, `panel-edge` |
| CTRL-9 | WHEN the phone reports a control's value that differs from the last one the Mac sent, THE Mac SHALL treat it as the person's own change and SHALL NOT correct it. | K2 `ControlIntentTests.testReportOfAnotherValueIsThePersonsChange` |
| CTRL-10 | WHEN the person's phone cannot do a control (no `dnd`, no `ringer`, no volume maximum, no panel control), THE Mac SHALL disable it with a reason and send nothing. | K2 `FocusCoreTests`; e2e `focus`, `controls`, `panel-edge` |
| CTRL-11 | ~~WHILE Contigua holds the phone's panel dark, WHEN the person unlocks it, touches display 0, presses a panel key or presses the power key, THE phone SHALL give the panel back at once (power mode NORMAL, display 0 lit, the keyguard untouched) and SHALL log `panel_yield reason=unlock\|touch\|key\|power`; after that it SHALL NOT darken the panel again while the person uses the phone, and only the phone going idle by itself (its own screen timeout or a lock) or the streams stopping SHALL end the dark episode.~~ **Removed 2026-11-13 (#142):** app windows now run in a display group of their own (app-windows.md WIN-74), so Contigua never holds the panel dark for them; the only panel hold left is the Phone Mirror's Turn Off Phone Screen (phone-app.md PHONE-12). | — |
| CTRL-12 | ~~WHILE Contigua holds the phone's panel dark, WHEN the person presses the power key, THE phone SHALL treat it as one hand back and nothing else: no relight of the streaming group and no panel-off after it, so one press gives the screen back.~~ **Removed 2026-11-13 (#142):** app windows now run in a display group of their own (app-windows.md WIN-74), so Contigua never holds the panel dark for them; the only panel hold left is the Phone Mirror's Turn Off Phone Screen (phone-app.md PHONE-12). | — |
| CTRL-13 | ~~THE phone SHALL open the panel's input devices (`/dev/input`) only WHILE it holds the panel dark and SHALL close them when the hold ends; it SHALL reduce each event to one of TOUCH, KEY or POWER and SHALL NOT store, log or send an event's code, position, count or timing beyond the one `panel_yield reason=…` line.~~ **Removed 2026-11-13 (#142):** the panel's input devices were read only to hand a dark panel back; with no dark panel (WIN-74) the phone never opens them. | — |
| CTRL-14 | WHILE at least one app stream is open and live THE phone SHALL keep every open stream's display in the episode with its display wake held, covered windows included; opening or closing one stream SHALL NOT change another stream's display wake; the episode (its partial wake lock, its display locks and its keep-alive) SHALL end WHEN the last app stream closes or every open one is covered, and start again WHEN one is live again, waking only the window displays' own group before a launch (WIN-23). | K1 `StreamEpisodeTest` (every transition, including a closed sibling and a covered one), `PanelPowerSessionTest` (a covered window's display stays in the set); emulator `vd-group` (`ok [CTRL-14]`: a window on a locked phone draws while display 0 stays off and no panel line is logged) |
| CTRL-15 | ~~WHILE the plan owes `panelOff` on a shared panel group no keep-alive step SHALL wake the group, and the `power: panel` line SHALL name the override (`held off`) rather than the platform's display state, which still reads on after the wake.~~ **Removed 2026-11-13 (#142):** app windows now run in a display group of their own (app-windows.md WIN-74), so Contigua never holds the panel dark for them; the only panel hold left is the Phone Mirror's Turn Off Phone Screen (phone-app.md PHONE-12). | — |
| CTRL-16 | ~~WHEN an episode takes over a sleeping shared panel group THE phone SHALL arm the panel off before its wake and re-apply it at 100, 250, 500 and 1 500 ms, so the physical panel's ON window is as short as the platform allows; the window SHALL NOT exceed 350 ms on the emulator rig.~~ **Removed 2026-11-13 (#142):** app windows now run in a display group of their own (app-windows.md WIN-74), so Contigua never holds the panel dark for them; the only panel hold left is the Phone Mirror's Turn Off Phone Screen (phone-app.md PHONE-12). | — |

## States and events

### The control intent machine (`macos/Sources/Contigua/ControlIntent.swift`)

One machine per control per phone, stored in the profile's defaults keyed by the
phone's device id. States:

- `Applied(v)`: the phone's last report was `v`; the phone is in it.
- `Overridden(v)`: `v` is the last value the Mac sent and the phone reported
  something else since — the person changed it, so their value stands.
- no memory: this phone never received the control.

| From \ Event | intent changed / Mac action | phone reported `v` | connected |
|---|---|---|---|
| no memory | `Applied(v)`, send `v` | unchanged | `Applied(w)`, send `w` |
| `Applied(a)` | `Applied(v)`, send `v` (an edge even when `v == a`) | `v == a`: `Applied(a)`, nothing; else `Overridden(a)`, nothing | `w == a`: nothing; else `Applied(w)`, send `w` |
| `Overridden(a)` | `Applied(v)`, send `v` | `v == a`: `Applied(a)`, nothing; else `Overridden(a)`, nothing | `w == a`: nothing (the person's value stands); else `Applied(w)`, send `w` |

Every transition is unit-tested, including the ignored events, and logged as
`controlintent <control>: <from> --<event>--> <to> send|none` with closed tokens.

### The app-window episode (`server/StreamEpisode.kt`)

The episode holds the set of open app displays. Two states: `Idle` (no live app
window: no partial wake, no display lock, no keep-alive) and `Live` (at least
one open window is live). A window the Mac covers stays in the set and keeps its
display wake while a sibling is live, so a sibling's open or close never changes
it; when every open window is covered, or the last one closes, the episode ends
and releases everything. Each step and each input pokes only the window
displays, which sit in their own group (WIN-74), so the panel's group is never
held.

| From \ Event | streams, one or more live | streams, every one covered | no streams |
|---|---|---|---|
| `Idle` | `Live`; partial wake, wake the window displays' group, display locks, keep-alive | stays `Idle`, nothing | stays `Idle`, nothing |
| `Live` | stays `Live`; a new display gets its lock, a gone one loses it | `Idle`; release every lock, end | `Idle`; release every lock, end |

Transitions are logged as `episode: <from> --<event>--> <to> displays=<n>`.

## Phone count and connection

- A control's memory is per phone (CONV-PD-01): the same Focus on two phones
  applies once per phone, and a value one phone already had is not sent again
  because another phone was added.
- Connecting: nothing is sent for a control whose value this phone already has
  (CTRL-3). Offline: a Mac-side edge is stored as the wanted value and applied
  on the next connect (CTRL-3). A phone that cannot do the control: disabled
  with a reason, nothing sent (CTRL-10).

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: no search field in a control's path. |
| CONV-MAC-02 | n/a: no new shortcut. |
| CONV-MAC-03 | n/a: no new popover or sheet; the menu items already follow Return/Esc. |
| CONV-MAC-04 | n/a: no new text field. |
| CONV-MAC-05 | n/a: no zoomable content. |
| CONV-MAC-06 | n/a: no new shortcut; every touched item is already in a menu. |
| CONV-MAC-07 | n/a: no shortcut reuse. |
| CONV-MAC-10 | n/a: the menu-bar panel is not changed. |
| CONV-MAC-11 | applies: "Turn Off Phone Screen" stays one window per phone; the panel memory is per phone. |
| CONV-MAC-12 | n/a: no window geometry change. |
| CONV-MAC-13 | n/a: no menu structure change. |
| CONV-MAC-14 | n/a: no layout change. |
| CONV-MAC-15 | n/a: closing windows does not quit; unchanged. |
| CONV-MAC-16 | n/a: no drag or paste path. |
| CONV-MAC-20 | n/a: no new visual. |
| CONV-MAC-21 | applies: the DND and panel controls keep their existing labels; no label changes here. |
| CONV-MAC-22 | n/a: no new animation. |
| CONV-MAC-23 | n/a: no new text. |
| CONV-MAC-24 | applies: CTRL-2; a Focus is still respected, and Contigua asks for nothing new. |
| CONV-MAC-25 | n/a: no new clickable control. |
| CONV-MAC-26 | n/a: no layout change. |
| CONV-AND-01 | n/a: no navigation change. |
| CONV-AND-02 | n/a: no phone-side UI. |
| CONV-AND-03 | n/a: no new permission. |
| CONV-AND-04 | applies: CTRL-4 (a restore clears only what Contigua set) and CTRL-14 (app windows hold only their own displays, so the person's screen is never woken, held or slept by Contigua; phone-app.md PHONE-22). |
| CONV-PD-01 | applies: CTRL-3 and the per-phone memory above. |
| CONV-PD-02 | applies: CTRL-10 and the connection paragraph above. |
| CONV-PD-03 | applies: CTRL-3 and CTRL-9: the Mac never claims a value the phone has not reported. |
| CONV-PD-04 | applies: the volume slider keeps its drag/settle machine; its sends are Mac-side edges (CTRL-1). |
| CONV-PD-05 | applies: transitions log closed tokens (states, events, reasons), never a value a person typed. |
| CONV-PD-06 | n/a: no interactive surface's frame budget changes. |
| CONV-PD-07 | applies: the touched labels keep their names (Phone Do Not Disturb, Turn Off Phone Screen, Phone Mirror). |
| CONV-PD-08 | applies: the two state machines above (`Applied`/`Overridden`; the episode's `Idle`/`Live`). |
| CONV-PD-09 | n/a: no new control or error copy. |

## Non-goals

- No phone-side "person overrode" memory: the phone keeps only `owned` for its
  restore (cleared when the person changes the value and on a shell-service
  restart), while the Mac holds the edge memory, which must outlive restarts.
- No re-application of a Mac intent to "correct" the phone.
- No change to the volume slider's drag/settle behaviour.
- No waking, holding or sleeping the phone's own screen for an app window (PHONE-22).

## Open questions

None.
