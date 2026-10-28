# Phone controls

Prefix: `CTRL`. Owner docs: `docs/design/focus.md`, `docs/design/controls.md`,
`docs/design/phone-mirror.md`, `docs/PROTOCOL.md` ("Focus and Do Not Disturb",
"Phone screen", "Ringer", "Volume"). Last reviewed: 2026-10-28, against
build 117.

## Purpose

Every value the Mac sets on the phone (Do Not Disturb, the ringer, the volume,
the phone screen's panel, keep-awake, clipboard and notification gates, audio
routing) has a person on both ends. This spec pins the one rule that keeps them
from fighting: **a Mac intent is applied on its edge, not re-asserted.** A
change the person makes on the phone stands until the Mac-side intent changes
again, and a reconnect sends a value only when it changed while the two were
apart.

It also pins the phone's side of the same rule for the screen: PocketDeck puts
the phone back to sleep after its last stream only when the phone is still as
PocketDeck left it.

## User stories

| ID | Priority | Story |
|---|---|---|
| CTRL-S1 | P1 | As a person, I want a control I changed on the phone to stay changed, so that PocketDeck does not undo my choice behind my back. |
| CTRL-S2 | P1 | As a person, I want a Focus or a menu pick to reach the phone when I make it, so that the Mac's controls still do what they say. |
| CTRL-S3 | P1 | As a person, I want the phone's screen to come back to me the moment I unlock or use it, so that closing a Mac window never blacks it out in my hand. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| CTRL-1 | WHEN the Mac-side intent for a control changes (a Focus starts or ends, a menu pick, a Shortcut, an MCP call, a panel control, the window's button), THE Mac SHALL send that control's new value to the phone once, on that edge. | K2 `ControlIntentTests`, K1 `WakeOwnershipTest`; e2e `focus`, `controls` |
| CTRL-2 | WHEN a Mac Focus starts or ends, THE Mac SHALL apply its DND as that edge (`priority`/`alarms`/`none` for a start, `off` for an end). | e2e `dnd-edge` `[CTRL-2]`, K2 `ControlIntentTests` |
| CTRL-3 | WHEN a phone connects (the first `state` of a session) and the Mac's memory already holds the wanted value for that phone and control, THE Mac SHALL send nothing for that control. | e2e `dnd-edge` `[CTRL-3]`, K2 `ControlIntentTests.testReconnect*` |
| CTRL-4 | WHEN the person changes a control on the phone, THE phone's value SHALL stand until the Mac-side intent changes again; a restore SHALL clear only a value PocketDeck set. | e2e `dnd-edge` `[CTRL-4]`, K1 `DndSessionTest` |
| CTRL-5 | WHEN the person wakes the phone's own screen after "Turn Off Phone Screen", THE hold SHALL end, and NO later reconnect or reopened phone window SHALL re-assert it; only a new Mac-side action applies it. | e2e `panel-edge` `[CTRL-5]` |
| CTRL-6 | WHEN a phone window opens with "Turn Off Phone Screen" remembered, THE Mac SHALL apply it only when this phone has not received that value since the person ended it. | e2e `panel-edge` `[CTRL-6]`, K2 `ControlIntentTests.testPanel*` |
| CTRL-7 | WHEN the last Mac window closes and the phone is still as PocketDeck left it (no unlock, no user activity on display 0, no person's wake since PocketDeck's own wake), THE phone SHALL put itself back to sleep; IF the person unlocked, used or woke it since, THE phone SHALL leave the screen alone and log the closed reason `person_unlocked` or `person_active`. | K1 `WakeOwnershipTest` |
| CTRL-8 | WHEN no Mac-side intent changes, THE Mac SHALL NOT re-send a control's value on a timer, on every `state`, or on a connect beyond CTRL-3. | audit table in `docs/design/controls.md`; e2e `dnd-edge`, `panel-edge` |
| CTRL-9 | WHEN the phone reports a control's value that differs from the last one the Mac sent, THE Mac SHALL treat it as the person's own change and SHALL NOT correct it. | K2 `ControlIntentTests.testReportOfAnotherValueIsThePersonsChange` |
| CTRL-10 | WHEN the person's phone cannot do a control (no `dnd`, no `ringer`, no volume maximum, no panel control), THE Mac SHALL disable it with a reason and send nothing. | K2 `FocusCoreTests`; e2e `focus`, `controls`, `panel-edge` |

## States and events

### The control intent machine (`macos/Sources/PocketDeck/ControlIntent.swift`)

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

### Wake ownership on the phone

One machine for the whole phone, not per stream: PocketDeck wakes the panel's
power group once per streaming episode, and the last stream's close may sleep it
again only while that wake is still ours.

| From \ Event | our wake | the person unlocked | the screen went on (not our wake) | last stream closed |
|---|---|---|---|---|
| `NotOurs` | `OursWoke` | ignored | ignored (only tracked) | nothing |
| `OursWoke` | `OursWoke` (new baseline) | `PersonTookOver(person_unlocked)` | `PersonTookOver(person_active)`; ignored inside the own-wake settle | `NotOurs`, sleep the phone |
| `PersonTookOver` | `OursWoke` (our next wake: a new episode, or a relight) | stays | stays | `NotOurs`, nothing, log the reason |

Only a wake that named the panel's own power group arms the machine: a wake of a
virtual display that has its own group never makes the phone's sleep ours.
Transitions are logged as `wake: <from> --<event>--> <to>`.

The person's use comes from the session's `state` stream as edges: `locked`
going false (the unlock; the face-unlock case the wake pokes cannot show as a
screen edge) and display 0 changing power. A repeated state is not a use, and a
session's first screen reading is not one: a reconnect must not read the phone's
current picture as a new wake.

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
| CONV-MAC-24 | applies: CTRL-2; a Focus is still respected, and PocketDeck asks for nothing new. |
| CONV-MAC-25 | n/a: no new clickable control. |
| CONV-MAC-26 | n/a: no layout change. |
| CONV-AND-01 | n/a: no navigation change. |
| CONV-AND-02 | n/a: no phone-side UI. |
| CONV-AND-03 | n/a: no new permission. |
| CONV-AND-04 | applies: CTRL-4 (a restore clears only what PocketDeck set) and CTRL-7 (no sleep under the person). |
| CONV-PD-01 | applies: CTRL-3 and the per-phone memory above. |
| CONV-PD-02 | applies: CTRL-10 and the connection paragraph above. |
| CONV-PD-03 | applies: CTRL-3 and CTRL-9: the Mac never claims a value the phone has not reported. |
| CONV-PD-04 | applies: the volume slider keeps its drag/settle machine; its sends are Mac-side edges (CTRL-1). |
| CONV-PD-05 | applies: transitions log closed tokens (states, events, reasons), never a value a person typed. |
| CONV-PD-06 | n/a: no interactive surface's frame budget changes. |
| CONV-PD-07 | applies: the touched labels keep their names (Phone Do Not Disturb, Turn Off Phone Screen, Phone Mirror). |
| CONV-PD-08 | applies: the two state machines above (`Applied`/`Overridden`; `NotOurs`/`OursWoke`/`PersonTookOver`). |
| CONV-PD-09 | n/a: no new control or error copy. |

## Non-goals

- No phone-side "person overrode" memory: the phone keeps only `owned` for its
  restore (cleared when the person changes the value and on a shell-service
  restart), while the Mac holds the edge memory, which must outlive restarts.
- No re-application of a Mac intent to "correct" the phone.
- No change to the volume slider's drag/settle behaviour.
- No waking a phone that PocketDeck did not wake, and no sleeping one it did not.

## Open questions

None.
