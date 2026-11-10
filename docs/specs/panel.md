# Menu-bar panel

Prefix: `PANEL`. Owner docs: [design/mac-redesign.md](../design/mac-redesign.md) §3.8, [UX.md](../UX.md) § "macOS app" 3, [design/controls.md](../design/controls.md) § "Panel volume slider", [design/focus.md](../design/focus.md) (DND), [design/audio.md](../design/audio.md) (volume, Now Playing), [design/notify.md](../design/notify.md) (LIVE rows). Last reviewed: 2026-10-27, against main `66dd3ea`.

## Purpose

The menu-bar panel is the phone's remote control and its noticeboard: one Control Center–style card, anchored to the status item or opened as a popover from the Deck's status chip, with the phone's four controls, its volume, what it is playing, its live notifications and the four window actions. It acts on the phone **in use** and names it; it is not a settings page and not a second Deck. The status item itself is the app's always-there presence: its icon carries the link's state, its menu carries Settings, About and Quit, and a click toggles the card (CONV-MAC-10).

## User stories

| ID | Priority | Story |
|---|---|---|
| PANEL-S1 | P1 | As a person anywhere on the Mac, I want the phone's controls one click from the menu bar, so that I do not switch apps to silence it. |
| PANEL-S2 | P1 | As a person, I want the card to say which phone it is and how it is connected, so that I never act on the wrong one or on a phone that is away. |
| PANEL-S3 | P1 | As a person, I want a control that cannot work to be dimmed and to say why, so that a click never silently does nothing. |
| PANEL-S4 | P2 | As a person, I want the volume to follow my drag, so that setting it is not a guessing game of echo and lag. |
| PANEL-S5 | P2 | As a person, I want the card's window buttons to open the mirror, Find Apps, Move to Mac and Install APK, so that the four things I do most are in one row. |
| PANEL-S6 | P2 | As a person, I want to see and open the phone's live notifications, so that I notice one without unlocking the phone. |
| PANEL-S7 | P1 | As a person, I want the card to close with Esc or a click outside, and to stay closed on a second click, so that it never gets stuck or reopens itself. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| PANEL-1 | WHILE Settings ▸ General's "show in menu bar" is on (the default) THE app SHALL show one status item, with the tooltip "PocketDeck", the symbol `apps.iphone` (`iphone.slash` while offline, pulsing while reconnecting) and a dot while an AI agent is connected; turning the setting off SHALL remove the item and close any open card. | K2 `MenuBarIconTests` (the symbol per link, the dot); e2e `menubar-shots` `[PANEL-1]` (the dot with a client connected); review of `MenuBarController.applyVisibility` |
| PANEL-2 | WHEN the status item is clicked THE card SHALL open; WHEN it is clicked again WHILE open THE card SHALL close; a click that arrives WHILE closing SHALL be ignored; a click outside the card or the item, Esc, or an action that opens a window SHALL close it; losing key SHALL NOT close it. | K2 `MenuBarPanelMachineTests.testIconClickTogglesThePanel`, `testEveryTransition`, `testAClickWhileClosingStillEndsClosed`; e2e `menus` (the panel host opens) |
| PANEL-3 | WHEN the status item is right-clicked or ⌃-clicked THE card SHALL close at once (no fade) and the icon's own menu SHALL open under it; the card's gear SHALL be the same request; the menu SHALL be Settings… ⌘, · About PocketDeck · a separator · Quit PocketDeck ⌘Q, built by one function that also serves the dump; Settings… and About SHALL close the card and open the window or the About panel, and Quit SHALL quit. | K2 `MenuBarPanelMachineTests.testASecondaryClickClosesThePanelFirstThenShowsTheMenu`, `testTheSecondaryClickIsARightClickOrAControlClick`, `testTheIconMenuIsSettingsAboutQuit`; e2e `menus` `[PANEL-3]` (the dump is that menu); e2e `menubar-shots` (the real gear's menu, visible runs) |
| PANEL-4 | THE card SHALL be a 320 pt-wide glass panel (300 pt of content plus 10 pt on each side) anchored under the status item, centred on it, 6 pt below it and never closer than 8 pt to the visible frame's edges; it SHALL be a non-activating panel that still takes the keyboard, join every Space and float over full-screen apps, and fade in and out over 0.12 s. | review of `MenuBarController.showPanel`/`PanelProbe`; e2e `menubar-shots` `[PANEL-4]` (the panel window's size) and `controls` (the card's 300 pt contents) |
| PANEL-5 | THE card SHALL show, top to bottom, the header (phone symbol, name, a dot plus the link's words, the battery), the agent row when an agent is connected, the four tiles, the volume row, the Now Playing picker when the phone reports two or more sessions, a LIVE section when notifications are live, and the WINDOWS row; the gear SHALL sit at the card's top-right. | K2 `PhonePanelTests.testThePanelIsP3sTileGridThenVolumeThenOneWindowsRow`, `testTheRowsAreInTheOrderTheViewLaysThemOut`, `PhonePanelP3Tests.testTheFocusOrderIsP3WithTheGearFirst`; e2e `controls` `[PANEL-5]` (the order and the enabled tiles) |
| PANEL-6 | THE header SHALL name the phone (its nickname first), show the link as dot plus words — Connected, Connecting…, Reconnecting…, Offline, Pair again, No phone paired — with `iphone.slash` while away, and SHALL show the battery (glyph by quarter, its percentage, red below 13%) only WHILE online; the whole header SHALL be one VoiceOver element. | K2 `PhonePanelTests.testOfflineDimsThePhoneControlsAndHidesTheBattery`; review of `PhoneControlsState.Connection`/`headerIdentity` |
| PANEL-7 | WHILE an AI agent is connected THE card SHALL show the row "AI agent connected" with a Disconnect button, and the card SHALL open with its keyboard focus on the first phone control — Do Not Disturb, with or without the agent row — and never on the gear or on a destructive action such as Disconnect. | K2 `PhonePanelP3Tests.testThePanelOpensOnTheFirstTileNotTheGear`, `testTheGearIsOnTheHeaderAndHeadsTheKeyOrder`; e2e `menubar-shots` `[PANEL-7]` (with an agent connected the opening focus is Do Not Disturb) and `controls` `[PANEL-7]` (the gear is first in AX order) |
| PANEL-8 | THE four tiles SHALL be a 2×2 grid — Do Not Disturb, Ringer, Ring Phone / Stop Ringing, Turn Off Screen — each ≥62 pt with a symbol, its title and one second line, lit with the accent only WHILE on and enabled; a disabled tile SHALL be dimmed neutral, never accent, and its second line SHALL be the short reason. | K2 `PhonePanelP3Tests.testTheTilesAreTwoRowsOfTwoAtTheirReviewSize`, `testADisabledTileIsNeverOn`, `testADisabledTileSaysWhyOnItsSubtitle`; e2e `controls` (the panel is P3, its tiles in order) |
| PANEL-9 | WHEN Do Not Disturb is clicked THE Mac SHALL ask the phone for `priority` (on) or for the mode it had before the Mac set it (off), SHALL follow the phone's report (`state.dnd`) and SHALL NOT turn off a DND the person set; the tile SHALL be disabled with "This phone doesn't report Do Not Disturb." when the phone reports none. | K2 `PhonePanelTests` (the tile's state), `FocusCoreTests` (the restore rule); e2e `controls` (a person's DND left alone, through the shared request path) |
| PANEL-10 | WHEN the Ringer tile is clicked THE card SHALL open a menu of Ring, Vibrate and Silent with the phone's current mode checked, and a pick SHALL send `phone.ringer`; a click SHALL never cycle the mode; the tile SHALL be disabled with a reason when the phone reports no ringer or WHILE its DND is on ("Turn off Do Not Disturb to change the ringer."). | K2 `PhonePanelP3Tests.testTheRingerTileNamesItsModeAndExplainsWhyItIsOff`, `ControlsCoreTests` (the modes); e2e `controls` `[PANEL-10]` (the menu sent vibrate) |
| PANEL-11 | WHEN Ring Phone is clicked THE phone SHALL ring for 30 s; WHILE it rings the tile SHALL read Stop Ringing and its symbol SHALL change, and a click SHALL stop it; both SHALL follow the phone's report, not a local guess. | K2 `PhonePanelTests.testRingFlipsToStopRinging`, `PhonePanelViewTests.testTheRingRowFlipsToStopWhileThePhoneRings`; e2e `menubar-shots` `[PANEL-11]` (the row becomes Stop Ringing for the shot) |
| PANEL-12 | WHILE the link is online and a Phone Mirror is open THE Turn Off Screen tile SHALL be enabled and a click SHALL toggle the mirror's panel hold (the same request the bar makes), the tile following the phone's `state.panel`; WHILE the link is not online (offline or connecting) THE tile SHALL be disabled with the offline reason, because a request sent into a dead session is a click that does nothing. | K2 `PhonePanelP3Tests.testTheScreenTileFollowsThePanelAndNeedsItsWindow`, `testTheScreenTileIsOffWhileTheLinkIsDown`; e2e `mirror` `[PANEL-12]` (enabled while connected, disabled with zero `phone.panel` sent once the phone is gone) |
| PANEL-13 | THE volume slider SHALL show the phone's music volume while idle, follow the pointer every frame while dragged (ignoring the phone's echoes), send `phone.volume` at most ten times a second plus always on release, and settle on the sent value until the phone echoes it or one second passes; its label SHALL read the phone's percentage, and a phone that reports no volume SHALL disable the row with "Your phone hasn't sent a volume." | K2 `PhoneVolumeTests` (every transition), `PhonePanelViewTests.testTheVolumeMirrorStartsAtThePhonesValue`; e2e `controls` `[PANEL-13]` (the drag's ten steps, the throttled sends, the release) |
| PANEL-14 | WHEN the phone reports two or more media sessions THE card SHALL add "Now Playing follows: <app>" with a picker of the sessions (the chosen one marked) and choosing SHALL switch what follows; the card SHALL show no track title, performer, artwork or forwarded-audio volume. | K2 `PhonePanelTests.testThePickerNeedsTwoSessionsAndNamesTheChosenApp`, `testThePanelHasNoTrackText`, `testThePanelDrawsNothingFromTheTrack`; e2e `media` |
| PANEL-15 | WHILE notifications are live THE card SHALL list one LIVE row per notification, with the same relative age the notification centre uses, and a click SHALL run that notification's click action; the row SHALL never be hidden and the content SHALL never be logged. | K2 `NotifyLiveMacTests` (the row's chip, its title and age); e2e `notify` |
| PANEL-16 | THE WINDOWS row SHALL carry four icon buttons — Mirror (⌘P), Find Apps (⌘K), Move to Mac (⇧⌘C) and Install APK… — each with a help tag naming it and its shortcut, a VoiceOver label (Move to Mac's is the full sentence plus ⇧⌘C), and the install button's second line following its phase ("Sending x.apk… 40%", "Installing x.apk…"); each SHALL be disabled with its reason when it cannot act (offline; "Open Mirror first."; "An install is already running.") and each SHALL open its window and close the card. | K2 `PhonePanelP3Tests.testTheHandoffButtonNamesWhatItDoes`, `testEveryTileAndRowCarriesItsOwnReason`, `testTheWindowButtonIsNamedPhoneMirror`; e2e `menus` (the panel's window rows) |
| PANEL-17 | THE card SHALL NOT carry Settings or Quit rows: those commands are the icon's menu (PANEL-3), and the card's footer SHALL stay empty. | e2e `controls` `[PANEL-17]`; e2e `menus` `[PANEL-17]`; K2 `PhonePanelTests` |
| PANEL-18 | THE Deck's status chip SHALL open the same card in a popover — 300 pt, the same rows and actions, without the gear and without a footer — and a control clicked there SHALL act on the phone. | K2 `PhonePanelTests.testTheDeckStatusPillOpensTheSamePanel`, `PhonePanelViewTests.testTheDeckPopoverHostsTheSamePanel`; e2e `deck` (the popover and its DND click); e2e `controls` `[PANEL-18]` |
| PANEL-19 | EVERY control that cannot work SHALL be visible and disabled, with one short line on the control and the full sentence in its help tag and VoiceOver hint: offline "Connect your phone to use these."; no DND / no ringer / no volume; DND on; no mirror; an install running. No control SHALL be hidden to avoid a state. | K2 `PhonePanelP3Tests.testEveryTileAndRowCarriesItsOwnReason`, `PhonePanelTests.testOfflineExplainsWhyTheControlsAreOff`, `testTheReasonNamesTheMissingPhoneCapability`, `HonestSettingsTests`; e2e `menubar-shots` `[PANEL-19]` (the offline sentence) and `mirror` `[PANEL-19]` (Turn Off Screen offline: disabled, its reason, a refused click) |
| PANEL-20 | THE card SHALL take the keyboard without activating the app: Tab and ⇧Tab SHALL walk its controls in the order it lays them out (the header's gear first, then the agent row, the tiles, the volume, the picker, the live rows and the WINDOWS row), Return SHALL run the focused control, and Esc SHALL close the card without acting. | K2 `PhonePanelP3Tests.testTheFocusOrderIsP3WithTheGearFirst`, `MenuBarPanelMachineTests` (Esc); review of `MenuBarPanel.focusFirstPhoneControl` |
| PANEL-21 | EVERY control SHALL have a VoiceOver label and role; the gear's SHALL be "Settings and more" with the help tag "Settings, About and Quit"; a disabled row SHALL carry its reason as its hint; and a tile SHALL read its state ("Do Not Disturb, Off"). | K2 `PhonePanelP3Tests.testTheGearIsOnTheHeaderAndHeadsTheKeyOrder`, `PhonePanelTests` (labels); e2e `controls` `[PANEL-21]` (the gear's AX name and help); e2e `menubar-shots` (the gear's AX name and help, visible run) |
| PANEL-22 | THE card SHALL use one 12 pt inset and one 8/12 pt rhythm for every section, the 134×62 pt tiles, the 28 pt rows and the 46 pt window buttons; its glass SHALL render in light and dark, with the accent and Increase Contrast, and every clickable element SHALL have a hover and a pressed state. | K2 `PhonePanelP3Tests.testTheTilesAreTwoRowsOfTwoAtTheirReviewSize`, `testTheVolumeRowAndWindowsRow`; e2e `menubar-shots` (the states in both appearances; a real hover in a visible run) |
| PANEL-23 | THE panel SHALL log no notification text, app name from a notification, media title or file name: ids, counts and closed states only. | review of the panel's logging; K2 `NotifyMacTests.testRecordsCarrySizesAndPackagesNotText` (the wire's redaction) |
| PANEL-24 | WHILE the person only opens and closes the card, or reads it, the app SHALL send no write to the phone. | untested (no read-only-panel phase in `nfr`) |
| PANEL-25 | THE status item SHALL be AppKit's own, sized to its content (`NSStatusItem.variableLength`), and SHALL draw its state only as the button's own template image — `apps.iphone`, `iphone.slash` while offline, the agent dot drawn into that image and widening it, nothing layered over the button — so AppKit centres it and the menu bar dims it on an inactive display as it dims its neighbours; the reconnecting pulse SHALL swap two frames of that same template image on a timer; the image SHALL follow the link and the agent count without polling; and the item's VoiceOver label SHALL name the agent while the dot shows. | K2 `MenuBarIconTests` (the symbol per link, the template image, the dot widens it, every pulse transition); e2e `menubar-shots` `[PANEL-25]` (`length=variable image=template subviews=0`) and the item's crops on the active and inactive displays |

Priority note: PANEL-1, 2, 3, 5, 6, 8, 11, 13, 16, 17, 19 and 20 are P1 (the card is the app's always-available control). The picker, Live rows and the appearance detail are P2.

## States and events

The card is one three-state machine (`MenuBarPanelMachine`, `macOS/Sources/PocketDeck/MenuBarPanel.swift`); the volume is a second, small one (`PhoneVolumeControl`); each control's availability is derived from the phone's reports, never stored.

| State | Event | Result |
|---|---|---|
| Closed | `iconClick` | Open: the card fades in, positioned under the item; focus on the first phone control |
| Open | `iconClick` | Closing: the card fades out |
| Closing | `iconClick` | ignored (the click that closed it is still in flight) |
| Closed | `iconSecondaryClick` / `gear` | the icon's menu opens; no card |
| Open | `iconSecondaryClick` / `gear` | the card hides at once, then the menu opens |
| Closing | `iconSecondaryClick` | ignored; no second menu |
| Open | `clickOutside` / `escape` / `openWindow` | Closing |
| Closing | `hideFinished` | Closed |
| Closed / Closing | `clickOutside` / `escape` / `openWindow` / `hideFinished` | ignored |
| any | `showMenuBar` off | the item is removed and the card closes |

| State | Event | Result |
|---|---|---|
| Idle | `phone state.volume` | the thumb and % show it |
| Idle | `hardware key on the phone` | the phone reports a new value; the thumb moves |
| Idle | `drag begins` | Dragging |
| Dragging | `thumb moves` | the thumb and % follow the pointer; at most one send per 100 ms |
| Dragging | `phone echo` | ignored (the drag owns the thumb) |
| Dragging | `release` | the value is sent; Settling |
| Settling | `matching echo` | Idle, showing the phone's value |
| Settling | `1 s passes, different value` | Idle, showing the phone's value |
| Settling | `a new drag` | Dragging |

| State | Event | Result |
|---|---|---|
| Steady | `pulses(true)` | Bright: the full frame shows; the frame timer starts |
| Bright | `tick` | Dim: the dim frame shows |
| Dim | `tick` | Bright |
| Bright / Dim | `pulses(false)` | Steady: the full frame shows; the timer stops |
| Steady | `pulses(false)` / `tick` | ignored (no timer is running) |
| Bright / Dim | `pulses(true)` | ignored (the pulse is already running) |

| State | Event | Result |
|---|---|---|
| any card | `link changes` | the header's words update; controls dim with the offline reason (PANEL-19) |
| any card | `state.dnd` / `state.ringer` / `state.volume` arrives | that control's mode, title or position follows |
| any card | `ring.state` says ringing | the Ring tile becomes Stop Ringing, and back |
| any card | `state.panel` changes | the Turn Off Screen tile follows the mirror's hold |
| any card | `install starts / progresses / ends` | the install button's line follows, and is disabled while running |
| any card | `1 notification becomes live / goes` | a LIVE row appears / leaves |

Ignored events, stated so nobody builds them: an icon click while the card is closing, a second secondary click while closing, Esc or a click outside while closed, a phone echo while dragging, a binder update to a phone other than the one in use, and a control click on a disabled row.

## Phone count and connection

| Situation | The card shows |
|---|---|
| 0 phones | "No phone paired"; every control disabled with "Connect your phone to use these."; no battery; Mirror/Find Apps/Move to Mac/Install APK disabled. |
| 1 phone | That phone: its name, state, battery while online, all controls for it. |
| 2+ phones | The phone **in use** only, named in the header. Settings ▸ Phones' Use This Phone changes which phone the card acts on; the card itself offers no picker. |
| Connecting | "Connecting…"; the phone's last known name; controls disabled with the offline reason; no battery until online. |
| Connected | "Connected"; battery; every control the phone supports enabled. |
| Offline / reconnecting | "Reconnecting…" then "Offline"; controls disabled with the reason, never hidden; the card stays usable as a readout. |
| Pair again | "Pair again"; controls disabled with the reason; the Deck's banner is the way to re-pair. |
| Phone that can't do the feature | DND, ringer or volume individually disabled with its own sentence ("This phone doesn't report Do Not Disturb.", "This phone doesn't report a ringer.", "Your phone hasn't sent a volume."), never hidden. |
| No mirror open | Turn Off Screen disabled with "Open Mirror first." |
| Install running | Install APK… disabled with "An install is already running." and its progress line. |
| An agent connected | The agent row with Disconnect; the opening focus stays on Do Not Disturb, never on Disconnect. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: the card has no search or filter field |
| CONV-MAC-02 | applies: the card takes none of ⌘W/⌥⌘W/⌘M/⌘Q/⌘,/⌘H for itself; ⌘, and ⌘Q are the icon's menu's (PANEL-3) |
| CONV-MAC-03 | applies: PANEL-20 (Esc closes without acting, Return runs the focused control, Tab/⇧Tab walk the card in its own order while it is key) |
| CONV-MAC-04 | n/a: no text field in the card |
| CONV-MAC-05 | n/a: nothing zoomable; the volume is a slider, not a zoom |
| CONV-MAC-06 | applies: every shortcut the card offers is in a menu (⌘P, ⌘K, ⇧⌘C) and in the WINDOWS button's help tag (PANEL-16); the gear's help tag names its menu (PANEL-21) |
| CONV-MAC-07 | applies: the card's Mirror button is the app's ⌘P = Phone Mirror (PANEL-16) |
| CONV-MAC-10 | applies: PANEL-1–PANEL-3 (click toggles; outside and Esc close; a window action closes; secondary click opens the icon's menu after closing the card, and the gear is the same request) |
| CONV-MAC-11 | applies: one status item and one card; the Deck's popover is a second host of the same component, not a second card (PANEL-18) |
| CONV-MAC-12 | n/a: the card is not a movable window — it is placed under the item and clamped to the screen on every open (PANEL-4) |
| CONV-MAC-13 | n/a: the card adds no menu item and no full-screen command |
| CONV-MAC-14 | n/a: the card does not resize; its content is laid out once at its fixed 300 pt width |
| CONV-MAC-15 | n/a: the card is not a window that a person closes to quit, and closing it never quits the app |
| CONV-MAC-16 | n/a: no drop target, no paste, no Services in the card |
| CONV-MAC-20 | applies: PANEL-22 (light, dark, accent and Increase Contrast; the offline and disabled states stay legible) and PANEL-25 (the item is the button's own template image, so the menu bar dims it on an inactive display as it dims its neighbours) |
| CONV-MAC-21 | applies: PANEL-21 and PANEL-25 (the item's label names the agent while the dot shows) |
| CONV-MAC-22 | applies: the card's only motion is its 0.12 s fade, which Reduce Motion allows; Reduce Transparency replaces the material with a solid fill (the system's `NSVisualEffectView`) |
| CONV-MAC-23 | applies: PANEL-6 and PANEL-9 (states are words as well as a dot or a lit tile, and a disabled tile is never colour-only) |
| CONV-MAC-24 | applies: the card asks for no permission; DND and ringing are phone-side and the phone's own Focus/notifications permissions govern them |
| CONV-MAC-25 | applies: PANEL-22 (hover and pressed on every control) and PANEL-8/PANEL-19 (a disabled control is dimmed neutral, never accent) |
| CONV-MAC-26 | applies: PANEL-22 (one 12 pt inset, one 8/12 pt rhythm; a tile's reason sits on the tile, the volume's on its row) |
| CONV-AND-01 | n/a: the card carries no phone navigation (Back/Home/Recents live in the mirror's bar and the Navigate menu) |
| CONV-AND-02 | n/a: no phone-side UI |
| CONV-AND-03 | n/a: no Android permission is asked from the card |
| CONV-AND-04 | applies: DND, ringer, ring, panel hold and install are actions the person asked for; the card changes nothing else, and the panel hold is always restored (MIRROR-9/12) |
| CONV-PD-01 | applies: the phone-count table above (0, 1, 2+; the card shows the phone in use and Settings is the switch) |
| CONV-PD-02 | applies: PANEL-6 and the table above (connecting, connected, offline, pair again, and a phone that cannot report a control — each disabled with its own sentence) |
| CONV-PD-03 | applies: PANEL-9–12 and PANEL-15 (every title and check follows the phone's report; a refused install or ring shows the phone's answer) |
| CONV-PD-04 | applies: PANEL-13 (the volume follows the pointer live, throttles its sends and then follows the phone) |
| CONV-PD-05 | applies: PANEL-23 |
| CONV-PD-06 | applies: the card is a fixed-size form and inherits NFR's limits; it runs no background work of its own. `panel_glyph_ms` belongs to the mirror's bar (MIRROR-10), not to this card |
| CONV-PD-07 | applies: "Mirror" on the WINDOWS button is "Phone Mirror" to VoiceOver and in the menu (PANEL-16); "Move to Mac" is "Move Phone App to Mac" in the menu; "Do Not Disturb", "Ringer", "Ring Phone"/"Stop Ringing", "Turn Off Screen", "Find Apps", "Install APK…" are one name each everywhere |
| CONV-PD-08 | applies: the panel machine and the volume machine are the tables above |
| CONV-PD-09 | applies: PANEL-19 (a dimmed control says its result and its next step), PANEL-14 ("Now Playing follows: <app>" names its value), PANEL-21 (full-sentence labels) |

## Assumptions

- The status item is owned by AppKit (`NSStatusItem` + `NSPanel`), not SwiftUI's `MenuBarExtra`: a second click on the item must close the card (CONV-MAC-10), which `MenuBarExtra(.window)` could not do.
- The card's phone is the one in use (`activePhoneId`, settings.md); it renders from that phone's cached last state while the link is down.
- The phone reports `state.dnd`, `state.ringer`, `state.volume`/`state.volumeMax`, `ring.state` and `state.panel`; a phone that does not is shown as "not on this phone", not as zero.
- The card is one component with two hosts (`PhonePanelView`), so the Deck's popover cannot drift from the menu-bar card.
- A menu-bar app's panel may take the keyboard without activating the app; the card relies on that for Tab/Esc/Return.

## Non-goals

- A settings page, a phone picker or a notification history in the card (Settings and the notification surface own those).
- Track title, artwork, a per-app volume, or a second audio device picker: the Mac's own Now Playing shows the track, and the phone's media volume is the only volume here.
- A customisable card (reordering, hiding rows) or extra control tiles.
- A Dock menu or a Control Center control: Control Center is its own opt-in extension (design/controls.md).
- Keeping the card open while another app is frontmost for more than a click or a key: the card is transient by convention.
- A second card for another phone at the same time.

## Open questions

- [NEEDS CLARIFICATION] With 0 phones the card still opens and says "No phone paired"; should it offer Pair Phone… instead of five disabled tiles? Recommended: no (pairing is the Deck's), but one sentence naming the next step ("Open the Deck to pair a phone.") would be honest.
- [NEEDS CLARIFICATION] The card has no way to reach Settings for the phone it names (per-phone sharing lives there). Recommended: the gear's menu is the app's commands only; leave it, because Settings is one ⌘, away and the card is for acting on the phone.
