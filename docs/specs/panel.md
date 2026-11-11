# Menu-bar panel

Prefix: `PANEL`. Owner docs: [design/mac-redesign.md](../design/mac-redesign.md) §3.8, [UX.md](../UX.md) § "macOS app" 3, [design/controls.md](../design/controls.md) § "Panel volume slider", [design/focus.md](../design/focus.md) (DND), [design/audio.md](../design/audio.md) (volume, Now Playing), [design/notify.md](../design/notify.md) (Live rows), [design/handoff.md](../design/handoff.md) (the foreground app). Last reviewed: 2026-11-10, against main `c0a17364`.

## Purpose

The menu-bar panel is the phone's remote control and its noticeboard: one Control Center–style card, anchored to the status item or opened as a popover from the Deck's status chip, with the phone's header, one Sound module, four 2×2 modules (Focus, Ringer, Ring Phone, Turn Off Screen), what it is playing, its live notifications, the app in front on its screen and the two window actions. It acts on the phone **in use** and names it; it is not a settings page and not a second Deck. The status item itself is the app's always-there presence: its icon carries the link's state, its menu carries Settings, About and Quit, and a click toggles the card (CONV-MAC-10).

## User stories

| ID | Priority | Story |
|---|---|---|
| PANEL-S1 | P1 | As a person anywhere on the Mac, I want the phone's controls one click from the menu bar, so that I do not switch apps to silence it. |
| PANEL-S2 | P1 | As a person, I want the card to say which phone it is, how it is connected and whether it is locked, so that I never act on the wrong one or on a phone that is away. |
| PANEL-S3 | P1 | As a person, I want a control that cannot work to be dimmed and to say why, so that a click never silently does nothing. |
| PANEL-S4 | P2 | As a person, I want the volume to follow my drag, so that setting it is not a guessing game of echo and lag. |
| PANEL-S5 | P2 | As a person, I want the card's two window buttons — Phone Mirror and Apps — at normal text size, so that the two things I open most are one click away. |
| PANEL-S6 | P2 | As a person, I want to see and open the phone's live notifications, and dismiss one I have read, so that I notice one without unlocking the phone. |
| PANEL-S7 | P1 | As a person, I want the card to close with Esc or a click outside, and to stay closed on a second click, so that it never gets stuck or reopens itself. |
| PANEL-S8 | P2 | As a person, I want a row that opens the app in front on my phone as its own Mac window, so that I keep my place without looking for it. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| PANEL-1 | WHILE Settings ▸ General's "show in menu bar" is on (the default) THE app SHALL show one status item, with the tooltip "Contigua", the symbol `apps.iphone` (`iphone.slash` while offline, pulsing while reconnecting) and a dot while an AI agent is connected; turning the setting off SHALL remove the item and close any open card. | K2 `MenuBarIconTests` (the symbol per link, the dot); e2e `menubar-shots` `[PANEL-1]` (the dot with a client connected); review of `MenuBarController.applyVisibility` |
| PANEL-2 | WHEN the status item is clicked THE card SHALL open; WHEN it is clicked again WHILE open THE card SHALL close; a click that arrives WHILE closing SHALL be ignored; a click outside the card or the item, Esc, or an action that opens a window SHALL close it; losing key SHALL NOT close it. | K2 `MenuBarPanelMachineTests.testIconClickTogglesThePanel`, `testEveryTransition`, `testAClickWhileClosingStillEndsClosed`; e2e `menus` (the panel host opens) |
| PANEL-3 | WHEN the status item is right-clicked or ⌃-clicked THE card SHALL close at once (no fade) and the icon's own menu SHALL open under it; the card's gear SHALL be the same request, and its menu SHALL open anchored under the gear's button (a pull-down, kept inside the screen's visible frame), never under the status item; the menu SHALL be Settings… ⌘, · About Contigua · a separator · Quit Contigua ⌘Q, built by one function that also serves the dump; Settings… and About SHALL close the card and open the window or the About panel, and Quit SHALL quit. | K2 `MenuBarPanelMachineTests.testASecondaryClickClosesThePanelFirstThenShowsTheMenu`, `testTheSecondaryClickIsARightClickOrAControlClick`, `testTheIconMenuIsSettingsAboutQuit`, `MenuBarMenuAnchorTests` (the pull-down point), `PhonePanelP3Tests.testTheGearAnchorIsTheGearButtonsOwnFrame`; e2e `menus` `[PANEL-3]` (the dump is that menu); e2e `menubar-shots` `[PANEL-3]` (the gear's anchor is the gear's own frame) and its gear-menu shot |
| PANEL-4 | THE card SHALL be a 320 pt-wide glass panel (300 pt of content plus 10 pt on each side) anchored under the status item, centred on it, 6 pt below it and never closer than 8 pt to the visible frame's edges; it SHALL be a non-activating panel that still takes the keyboard, join every Space and float over full-screen apps, and fade in and out over 0.12 s; WHILE it is open its height SHALL follow its content when a row arrives or leaves (the top edge stays under the item, the growth animates through the card's 0.12 s and never clips a row), and it SHALL never grow past the visible frame's bottom edge. | review of `MenuBarController.showPanel`/`PanelProbe`/`panelContentHeightChanged`; e2e `menubar-shots` `[PANEL-4]` (the panel window's size) and `controls` (the card's 300 pt contents) |
| PANEL-5 | THE card SHALL show, top to bottom, the header (phone symbol, the name — a phone pop-up with 2+ phones —, a dot plus the link's words, a lock while the phone is locked, the battery), the notice row while one is needed, the agent row while an agent is connected, one full-width Sound module (speaker, the word "Sound", the phone's percentage and the volume slider), the 2×2 modules Focus / Ringer / Ring Phone / Turn Off Screen, the Now Playing module while the phone reports two or more sessions, one Live row per live notification when any, the "Open <App> on Mac" row only while the phone reports an app in front (PANEL-28), and the WINDOWS row of Phone Mirror and Apps; the gear SHALL sit at the card's top-right; the keyboard order SHALL follow that reading order, with the gear first (PANEL-20). | K2 `PhonePanelTests.testTheRowsAreInTheOrderTheViewLaysThemOut`, `PhonePanelP3Tests.testTheModulesAreTwoRowsOfTwoWithTheirTitlesAndStates`, `testTheSoundModuleComesFirstAndHoldsTheSlider`; e2e `controls` `[PANEL-5]` (the order and the enabled controls) |
| PANEL-6 | THE header SHALL show the phone's symbol, its name (the nickname first), the link as dot plus words — Connected, Connecting…, Reconnecting…, Offline, Pair again, No phone paired — with `iphone.slash` while away, a lock glyph WHILE the phone is online and locked, and the battery (glyph by quarter, its percentage, red below 13%) only WHILE online; WHILE the phone is not online it SHALL add the last-seen line when a time is known ("Last seen 14:32"); the identity block (symbol, name, link, lock, battery) SHALL be one VoiceOver element whose label names the phone and its link, and the lock's word when locked. | K2 `PhonePanelTests.testTheHeaderNamesThePhoneItsLinkItsLockAndItsBattery`, `testOfflineDimsThePhoneControlsAndShowsLastSeen`; review of `PhoneControlsState.Connection`/`headerIdentity` |
| PANEL-7 | WHILE an AI agent is connected THE card SHALL show the row "AI agent connected" with a Disconnect button, and the card SHALL open with its keyboard focus on Focus, the first phone module (Do Not Disturb), with or without the agent row — and never on the gear, the phone pop-up or a destructive action such as Disconnect. | K2 `PhonePanelP3Tests.testThePanelOpensOnTheFirstModuleNotTheGear`, `testTheGearIsOnTheHeaderAndHeadsTheKeyOrder`; e2e `menubar-shots` `[PANEL-7]` (with an agent connected the opening focus is Focus) and `controls` `[PANEL-7]` (the gear is first in AX order) |
| PANEL-8 | THE four modules SHALL be a 2×2 grid — Focus, Ringer, Ring Phone/Stop Ringing, Turn Off Screen — two 134 pt modules per row, 8 pt apart, at least 62 pt high at the card's 300 pt width; each SHALL be a real button with a symbol, its title and one state line: Focus "Do Not Disturb" / "Off", Ringer the phone's mode, Ring Phone "Plays a sound" at rest and "Ringing" while it rings, Turn Off Screen "Screen on" / "Screen off"; each SHALL carry an accessibility label (its title) and a value (its state); a module SHALL be lit with the accent only WHILE on and enabled; a timeout SHALL NOT be a state line; a disabled module SHALL be dimmed neutral, never accent, and its second line SHALL be the short reason, except WHILE the link is down when the group shows one reason (PANEL-19). | K2 `PhonePanelP3Tests.testTheModulesAreTwoRowsOfTwoWithTheirTitlesAndStates`, `testADisabledModuleIsNeverOn`, `testADisabledModuleSaysWhyOnItsSecondLine`, `PhonePanelTests.testTheRingModuleSaysPlaysASoundAtRest`; e2e `controls` (the panel's modules in order) |
| PANEL-9 | WHEN Focus is clicked THE Mac SHALL ask the phone for `priority` (on) or for the mode it had before the Mac set it (off), SHALL follow the phone's report (`state.dnd`) and SHALL NOT turn off a DND the person set; the module SHALL be disabled with "This phone doesn't report Do Not Disturb." when the phone reports none. | K2 `PhonePanelTests` (the module's state), `FocusCoreTests` (the restore rule); e2e `controls` (a person's DND left alone, through the shared request path) |
| PANEL-10 | WHEN the Ringer module is clicked THE card SHALL open a menu of Ring, Vibrate and Silent with the phone's current mode checked, and a pick SHALL send `phone.ringer`; a click SHALL never cycle the mode; the module SHALL be disabled with a reason when the phone reports no ringer or WHILE its DND is on ("Turn off Do Not Disturb to change the ringer."). | K2 `PhonePanelP3Tests.testTheRingerModuleNamesItsModeAndExplainsWhyItIsOff`, `ControlsCoreTests` (the modes); e2e `controls` `[PANEL-10]` (the menu sent vibrate) |
| PANEL-11 | WHEN Ring Phone is clicked THE phone SHALL ring for 30 s; WHILE it rings the module SHALL read Stop Ringing and its symbol SHALL change, and a click SHALL stop it; both SHALL follow the phone's report, not a local guess; at rest its second line SHALL read "Plays a sound", and "Ringing" while it rings. | K2 `PhonePanelTests.testRingFlipsToStopRinging`, `testTheRingModuleSaysPlaysASoundAtRest`, `PhonePanelViewTests.testTheRingRowFlipsToStopWhileThePhoneRings`; e2e `menubar-shots` `[PANEL-11]` (the module becomes Stop Ringing for the shot) |
| PANEL-12 | WHILE the link is online and a Phone Mirror is open THE Turn Off Screen module SHALL be enabled and a click SHALL toggle the mirror's panel hold (the same request the bar makes), the module following the phone's `state.panel`; IF the phone is online and no Phone Mirror is open THEN the module SHALL be disabled with the short line "Open Mirror first", which is also its help tag, and the full sentence "Open Phone Mirror first." as its VoiceOver hint; WHILE the link is not online THE module SHALL be disabled by the group's offline reason (PANEL-19), because a request sent into a dead session is a click that does nothing. | K2 `PhonePanelP3Tests.testTheScreenModuleFollowsThePanelAndNeedsItsWindow`, `testTheScreenModuleIsOffWhileTheLinkIsDown`, `testTheScreenModulesHelpTagIsItsReason`; e2e `mirror` `[PANEL-12]` (enabled while connected, disabled with zero `phone.panel` sent once the phone is gone); e2e `menubar-shots` (the disabled screen module's short line) |
| PANEL-13 | THE Sound module SHALL be one full-width module at the card's top: the speaker symbol, the word "Sound", the phone's percentage on its first line, and the volume slider under it; the slider SHALL show the phone's music volume while idle, follow the pointer every frame while dragged (ignoring the phone's echoes), send `phone.volume` at most ten times a second plus always on release, and settle on the sent value until the phone echoes it or one second passes; its label SHALL read the phone's percentage, and a phone that reports no volume SHALL replace the slider with "Your phone hasn't sent a volume." while the module stays visible. | K2 `PhoneVolumeTests` (every transition), `PhonePanelViewTests.testTheVolumeMirrorStartsAtThePhonesValue`, `PhonePanelP3Tests.testTheSoundModuleComesFirstAndHoldsTheSlider`; e2e `controls` `[PANEL-13]` (the drag's ten steps, the throttled sends, the release) |
| PANEL-14 | WHEN the phone reports two or more media sessions THE card SHALL show the Now Playing module — a music note, the words "Now playing", the chosen app's name and the picker of the sessions (the chosen one marked) — the same pop-up and no other behaviour change, and choosing SHALL switch what follows; the module SHALL NOT show a track title, performer, artwork or forwarded-audio volume; its VoiceOver label SHALL read "Now playing: <app>". | K2 `PhonePanelTests.testThePickerNeedsTwoSessionsAndNamesTheChosenApp`, `testThePanelHasNoTrackText`, `testThePanelDrawsNothingFromTheTrack`; e2e `media` |
| PANEL-15 | WHILE notifications are live THE card SHALL list one Live row per notification, with the same relative age the notification centre uses; a click SHALL run that notification's click action; each row SHALL carry its own Dismiss button (always visible, a help tag, the VoiceOver label "Dismiss notification") that hides that row on the Mac only, sends nothing to the phone and leaves the other rows; the row SHALL never be hidden for any other reason and the content SHALL never be logged. | K2 `PhonePanelLiveRowsTests` (the filter, the order), `NotifyLiveMacTests` (the row's chip, its title and age); e2e `notify`; review of `PhonePanelView.dismissLive` |
| PANEL-16 | THE WINDOWS row SHALL carry two buttons at normal text size — Phone Mirror (⌘P) and Apps (⌘K), each with its symbol and label, a help tag naming it and its shortcut, and a VoiceOver label (Apps reads "Find Apps") — each SHALL be disabled with its reason when it cannot act (offline) and each SHALL open its window and close the card; Install APK… SHALL NOT be in the card: it stays in the Phone menu, the Deck's drop and Finder's Open With. | K2 `PhonePanelP3Tests.testTheWindowRowIsPhoneMirrorAndAppsAtNormalTextSize`, `testEveryModuleAndRowCarriesItsOwnReason`; e2e `menus` (the panel's window row and the Phone menu's Install APK…) |
| PANEL-17 | THE card SHALL NOT carry Settings or Quit rows: those commands are the icon's menu (PANEL-3), and the card's footer SHALL stay empty. | e2e `controls` `[PANEL-17]`; e2e `menus` `[PANEL-17]`; K2 `PhonePanelTests` |
| PANEL-18 | THE Deck's status chip SHALL open the same card in a popover — 300 pt, the same rows and actions, without the gear and without a footer — and a control clicked there SHALL act on the phone; the popover SHALL start the foreground request while it is open and stop it when it closes (PANEL-26). | K2 `PhonePanelTests.testTheDeckStatusPillOpensTheSamePanel`, `PhonePanelViewTests.testTheDeckPopoverHostsTheSamePanel`; e2e `deck` (the popover and its DND click); e2e `controls` `[PANEL-18]` |
| PANEL-19 | EVERY control that cannot work SHALL be visible and disabled, with one short line on the control and the full sentence in its help tag and VoiceOver hint, except WHILE the link is not online: then the Sound module and the four modules SHALL dim as one group, the Sound module SHALL show the one reason "Connect your phone to use these." in place of its slider, the four modules SHALL show no second line or per-module reason, and the handoff row SHALL be hidden by PANEL-28; online, a module that cannot work SHALL show its own short reason (no DND / no ringer / no volume / DND on / "Open Mirror first"), never be hidden. No other control SHALL be hidden to avoid a state. | K2 `PhonePanelP3Tests.testEveryModuleAndRowCarriesItsOwnReason`, `PhonePanelTests.testOfflineExplainsWhyTheControlsAreOff`, `testTheReasonNamesTheMissingPhoneCapability`, `HonestSettingsTests`; e2e `menubar-shots` `[PANEL-19]` (the offline card's one reason) and `mirror` `[PANEL-19]` (Turn Off Screen offline: disabled, its reason, a refused click) |
| PANEL-20 | THE card SHALL take the keyboard without activating the app: Tab and ⇧Tab SHALL walk its controls in the order it lays them out (the gear first, the phone pop-up with 2+ phones, the agent row's Disconnect while connected, the Sound slider, the four modules, Now Playing, the Live rows and their Dismiss buttons, the handoff row when shown, Phone Mirror and Apps), Return SHALL run the focused control, and Esc SHALL close the card without acting; the opening focus SHALL be Focus, never the gear or Disconnect (PANEL-7). | K2 `PhonePanelP3Tests.testTheFocusOrderIsTheReadingOrderWithTheGearFirst`, `MenuBarPanelMachineTests` (Esc); review of `MenuBarPanel.focusFirstPhoneControl` |
| PANEL-21 | EVERY control SHALL have a VoiceOver label and role; the gear's SHALL be "Settings and more" with the help tag "Settings, About and Quit"; a module SHALL read its title and value ("Focus, Do Not Disturb", "Focus, Off"); a disabled control SHALL carry its reason as its hint; a live row's Dismiss SHALL read "Dismiss notification"; the phone pop-up SHALL read "<name>, phone in use" with "Choose the phone the panel acts on." as its help. | K2 `PhonePanelP3Tests.testTheGearIsOnTheHeaderAndHeadsTheKeyOrder`, `testTheModulesReadTheirTitleAndValue`, `PhonePanelTests` (labels); e2e `controls` `[PANEL-21]` (the gear's AX name and help); e2e `menubar-shots` (the gear's AX name and help, visible run) |
| PANEL-22 | THE card SHALL use one 12 pt inset and one 8/12 pt rhythm for every section, the 134×62 pt modules, the full-width Sound, Now Playing and handoff modules, the 28 pt Live rows and the two normal-text window buttons; its glass SHALL render in light and dark, with the accent and Increase Contrast, and every clickable element SHALL have a hover and a pressed state. | K2 `PhonePanelP3Tests.testTheModulesAreTwoRowsOfTwoWithTheirTitlesAndStates`, `testTheWindowRowIsPhoneMirrorAndAppsAtNormalTextSize`; e2e `menubar-shots` (the states in both appearances; a real hover in a visible run) |
| PANEL-23 | THE panel SHALL log no notification text, app name from a notification, media title, file name or foreground package: ids, counts and closed states only; the foreground reply's log line SHALL say "front: present" or "front: none", never the package. | review of the panel's and the front machine's logging; K2 `NotifyMacTests.testRecordsCarrySizesAndPackagesNotText` (the wire's redaction) |
| PANEL-24 | WHILE the person only opens and closes the card, or reads it, the app SHALL send no write to the phone; opening the card MAY send the one read `task.front` (PANEL-26) and nothing else. | untested (no read-only-panel phase in `nfr`) |
| PANEL-25 | THE status item SHALL be AppKit's own, sized to its content (`NSStatusItem.variableLength`), and SHALL draw its state only as the button's own template image — `apps.iphone`, `iphone.slash` while offline, the agent dot drawn into that image in a slot the image reserves in both states so its size and the glyph's position never change when an agent connects, nothing layered over the button — so AppKit centres it and the menu bar dims it on an inactive display as it dims its neighbours; the reconnecting pulse SHALL swap two frames of that same template image on a timer; the image SHALL follow the link and the agent count without polling; and the item's VoiceOver label SHALL name the agent while the dot shows. | K2 `MenuBarIconTests` (the symbol per link, the template image, the dot keeps the image size and the glyph in place, every pulse transition); e2e `menubar-shots` `[PANEL-25]` (`length=variable image=template subviews=0` and the same image size with and without the dot) and the item's crops on the active and inactive displays |
| PANEL-26 | WHILE the card is open THE Mac SHALL ask `task.front` once at open and again at most once every 2 s, never while the card is closed and never in the background; each request SHALL carry a new `seq`; the foreground SHALL be one machine — Idle, Asking(seq), Known(pkg), None — where Asking SHALL keep the answer before it on show, so the row does not blink out and back at each 2 s request, a reply whose `seq` is not the newest request SHALL be ignored, a reply whose `pkg` is null SHALL be None, and an error (`not_available`) SHALL be None; the machine SHALL reset while the phone is away or the phone in use changes. The phone SHALL read display 0's top task once per request (the same `ForegroundTaskPicker` as `task.continue`) and SHALL never watch or push it. | K2 `FrontAppMachineTests` (every transition, a stale reply, a reset), `FrontAppFlowTests` (the request, the reply, a stale reply, none, silence after close); K1 `SessionTest` (present, null, without the seam); e2e `controls` `[PANEL-26]` (with a phone that never answers, no handoff row) and `menubar-shots` (the row after the reply) |
| PANEL-27 | WHILE two or more phones are remembered THE header's name SHALL be a pop-up listing them with a checkmark on the phone in use; choosing one SHALL run the app's one Use This Phone route (SET-DEV-03) and SHALL NOT change the card's width; with one phone or none the name SHALL be plain text. | K2 `PhonePanelTests.testTwoPhonesMakeTheNameAPopUpAndSwitchingUsesTheOneRoute`, `PhonePanelP3Tests.testThePhonePopUpFitsTheCardsWidth`; e2e `phones` (the card names the phone in use) |
| PANEL-28 | WHILE the phone is online and the front machine is Known(pkg) THE card SHALL show one full-width handoff module after the Live rows and before WINDOWS: the app's icon, "Open <App> on Mac" when the app list knows the package (the icon from the Deck's cache), else "Open Current App on Mac" with a generic icon; its help tag and VoiceOver label SHALL name what it does and ⇧⌘C; a click SHALL open the handoff window (the same function as the Phone menu's item); WHILE the phone is away or the machine is not Known THE row SHALL be absent (no disabled placeholder), and its arrival SHALL not shift a row above it. The Phone Mirror's bar SHALL carry no handoff control: the Phone menu and this row are its entry points. | K2 `PhonePanelViewTests.testTheHandoffRowAppearsOnlyForAFreshFrontApp`, `PhonePanelTests.testTheHandoffRowNamesTheKnownAppAndItsFallback`; e2e `menubar-shots` `[PANEL-28]` (the row with the fake phone's foreground app) and `controls` (no row before the reply) |
| PANEL-29 | WHEN a row of the open card comes or goes (the handoff row after the phone's answer, a Live row, the notice) THE card's content and height SHALL change at once, with no fade, slide or animated resize, so no control under it moves over time; WHEN the card opens again WHILE the link stayed up THE handoff row SHALL show the last answer from the first frame and follow the new reply when it arrives. | K2 `FrontAppMachineTests.testAskingAgainKeepsTheAnswerOnShowUntilTheReply`; `FrontAppFlowTests.testTheForegroundReadRunsOnlyWhileTheCardIsOpen`; review of the card's transaction (`PhonePanelView.card`) and `MenuBarPanel.panelContentHeightChanged` |

Priority note: PANEL-1, 2, 3, 5, 6, 8, 11, 13, 16, 17, 19, 20, 26 and 28 are P1 (the card is the app's always-available control). The picker, Live rows, the phone pop-up and the appearance detail are P2.

## States and events

The card is one three-state machine (`MenuBarPanelMachine`, `macOS/Sources/Contigua/MenuBarPanel.swift`); the volume is a second, small one (`PhoneVolumeControl`); the foreground app is a third (`FrontAppMachine`); each control's availability is derived from the phone's reports, never stored.

| State | Event | Result |
|---|---|---|
| Closed | `iconClick` | Open: the card fades in, positioned under the item; focus on Focus |
| Open | `iconClick` | Closing: the card fades out |
| Closing | `iconClick` | ignored (the click that closed it is still in flight) |
| Closed | `iconSecondaryClick` / `gear` | the icon's menu opens; no card |
| Open | `iconSecondaryClick` / `gear` | the card hides at once, then the menu opens under the item (a secondary click) or under the gear (a pull-down) |
| Closing | `iconSecondaryClick` | ignored; no second menu |
| Open | `clickOutside` / `escape` / `openWindow` | Closing |
| Closing | `hideFinished` | Closed |
| Closed / Closing | `clickOutside` / `escape` / `openWindow` / `hideFinished` | ignored |
| any | `showMenuBar` off | the item is removed and the card closes |
| any card | `content height changes` | the panel grows or shrinks from its top edge, within the visible frame (PANEL-4) |

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
| Idle | `card opens` | Asking(seq 1): one `task.front` goes out |
| Asking(seq) | `2 s while the card is open` | Asking(seq + 1): one more request; the older reply is stale |
| Asking(seq) | `reply(seq, pkg)` | Known(pkg) |
| Asking(seq) | `reply(seq, null)` | None |
| Asking(seq) | `error not_available` | None |
| Asking(seq) | `reply(other seq)` | ignored |
| Known / None | `card opens` | Asking(seq + 1) |
| Known / None | `2 s while the card is open` | Asking(seq + 1) |
| any | `card closes` | the timer stops; the last Known/None stays only for the Phone menu's 2 s freshness, then falls back |
| any | `phone away` / `phone in use changes` | Idle, no row, no requests until the card reopens |

| State | Event | Result |
|---|---|---|
| any card | `link changes` | the header's words update; controls dim with the offline reason (PANEL-19) |
| any card | `state.dnd` / `state.ringer` / `state.volume` arrives | that module's mode, title or position follows |
| any card | `ring.state` says ringing | the Ring module becomes Stop Ringing, and back |
| any card | `state.panel` changes | the Turn Off Screen module follows the mirror's hold |
| any card | `1 notification becomes live / goes` | a Live row appears / leaves; a dismissed id stays hidden while it lives |
| any card | `task.front reply` | the handoff row appears, changes app or leaves (PANEL-26/28) |

Ignored events, stated so nobody builds them: an icon click while the card is closing, a second secondary click while closing, Esc or a click outside while closed, a phone echo while dragging, a binder update to a phone other than the one in use, a control click on a disabled row, a foreground reply with an older `seq`, and a foreground request while the card is closed.

## Phone count and connection

| Situation | The card shows |
|---|---|
| 0 phones | "No phone paired"; every module disabled with one "Connect your phone to use these." reason; no battery, no lock; Phone Mirror disabled and Apps enabled. |
| 1 phone | That phone: its name, state, lock, battery while online, all controls for it. |
| 2+ phones | The phone **in use** only, named in the header; the name is a pop-up listing every remembered phone with a checkmark on the one in use, and picking one runs Use This Phone (SET-DEV-03). |
| Connecting | "Connecting…"; the phone's last known name; controls disabled with the offline reason; last seen line; no battery or lock until online. |
| Connected | "Connected"; battery; a lock while locked; every module the phone supports enabled. |
| Offline / reconnecting | "Reconnecting…" then "Offline"; the last-seen line; the modules dim as one group with one reason; never hidden; the card stays usable as a readout; the notice row (the Deck's banner, PAIR-33/35) carries its last-seen line. |
| Pair again | "Pair again"; controls disabled with the reason; the Deck's banner is the way to re-pair. |
| Phone that can't do the feature | Focus, Ringer or Sound individually disabled with its own sentence ("This phone doesn't report Do Not Disturb.", "This phone doesn't report a ringer.", "Your phone hasn't sent a volume."), never hidden. |
| No mirror open | Turn Off Screen disabled with "Open Mirror first" (and "Open Phone Mirror first." as its hint). |
| No app in front / no reply | The handoff row is absent; the Phone menu keeps "Open Current App on Mac" and the old one-shot behaviour unless a fresh reply says there is nothing to open. |
| An agent connected | The agent row with Disconnect; the opening focus stays on Focus, never on Disconnect. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: the card has no search or filter field |
| CONV-MAC-02 | applies: the card takes none of ⌘W/⌥⌘W/⌘M/⌘Q/⌘,/⌘H for itself; ⌘, and ⌘Q are the icon's menu's (PANEL-3) |
| CONV-MAC-03 | applies: PANEL-20 (Esc closes without acting, Return runs the focused control, Tab/⇧Tab walk the card in its own order while it is key) |
| CONV-MAC-04 | n/a: no text field in the card |
| CONV-MAC-05 | n/a: nothing zoomable; the Sound module holds a slider, not a zoom |
| CONV-MAC-06 | applies: every shortcut the card offers is in a menu (⌘P, ⌘K, ⇧⌘C) and in the WINDOWS button's help tag (PANEL-16); the gear's help tag names its menu (PANEL-21) |
| CONV-MAC-07 | applies: the card's Phone Mirror button is the app's ⌘P = Phone Mirror (PANEL-16) |
| CONV-MAC-10 | applies: PANEL-1–PANEL-3 (click toggles; outside and Esc close; a window action closes; secondary click opens the icon's menu after closing the card, and the gear is the same request) |
| CONV-MAC-11 | applies: one status item and one card; the Deck's popover is a second host of the same component, not a second card (PANEL-18) |
| CONV-MAC-12 | n/a: the card is not a movable window — it is placed under the item and clamped to the screen on every open (PANEL-4) |
| CONV-MAC-13 | n/a: the card adds no menu item and no full-screen command |
| CONV-MAC-14 | n/a: the card does not resize by dragging; its width is fixed at 300 pt and its height follows its content (PANEL-4) |
| CONV-MAC-15 | n/a: the card is not a window that a person closes to quit, and closing it never quits the app |
| CONV-MAC-16 | n/a: no drop target, no paste, no Services in the card |
| CONV-MAC-20 | applies: PANEL-22 (light, dark, accent and Increase Contrast; the offline and disabled states stay legible) and PANEL-25 (the item is the button's own template image, so the menu bar dims it on an inactive display as it dims its neighbours) |
| CONV-MAC-21 | applies: PANEL-21 and PANEL-25 (the item's label names the agent while the dot shows) |
| CONV-MAC-22 | applies: the card's only motion is its 0.12 s open/close fade, which Reduce Motion allows to be instant; a content change is instant (PANEL-29); Reduce Transparency replaces the material with a solid fill (the system's `NSVisualEffectView`) |
| CONV-MAC-23 | applies: PANEL-6 and PANEL-9 (states are words as well as a dot or a lit module, and a disabled module is never colour-only) |
| CONV-MAC-24 | applies: the card asks for no permission; DND and ringing are phone-side and the phone's own Focus/notifications permissions govern them |
| CONV-MAC-25 | applies: PANEL-22 (hover and pressed on every control) and PANEL-8/PANEL-19 (a disabled module is dimmed neutral, never accent) |
| CONV-MAC-26 | applies: PANEL-22 (one 12 pt inset, one 8/12 pt rhythm; a module's reason sits on the module, the volume's on its Sound module) |
| CONV-AND-01 | n/a: the card carries no phone navigation (Back/Home/Recents live in the mirror's bar and the Navigate menu) |
| CONV-AND-02 | n/a: no phone-side UI |
| CONV-AND-03 | n/a: no Android permission is asked from the card |
| CONV-AND-04 | applies: DND, ringer, ring, panel hold and the handoff are actions the person asked for; the card changes nothing else, and the panel hold is always restored (MIRROR-9/12) |
| CONV-PD-01 | applies: the phone-count table above (0, 1, 2+; the card shows the phone in use, switches it from the header, and Settings is the other way) |
| CONV-PD-02 | applies: PANEL-6 and the table above (connecting, connected, offline, pair again, and a phone that cannot report a control — each disabled with its own sentence) |
| CONV-PD-03 | applies: PANEL-9–12, PANEL-15 and PANEL-26/28 (every title and check follows the phone's report; the foreground row follows the phone's reply, never a local guess) |
| CONV-PD-04 | applies: PANEL-13 (the volume follows the pointer live, throttles its sends and then follows the phone) |
| CONV-PD-05 | applies: PANEL-23 |
| CONV-PD-06 | applies: the card is a fixed-size form and inherits NFR's limits; it runs no background work of its own except the foreground request while it is open (PANEL-26). `panel_glyph_ms` belongs to the mirror's bar (MIRROR-10), not to this card |
| CONV-PD-07 | applies: "Phone Mirror" and "Apps" on the WINDOWS row (VoiceOver "Phone Mirror"/"Find Apps"), "Open <App> on Mac" for the handoff everywhere (fallback "Open Current App on Mac" where a menu item must always exist), and "Focus", "Ringer", "Ring Phone"/"Stop Ringing", "Turn Off Screen", "Install APK…" are one name each everywhere |
| CONV-PD-08 | applies: the panel machine, the volume machine and the foreground machine are the tables above |
| CONV-PD-09 | applies: PANEL-19 (a dimmed control says its result and its next step), PANEL-14 ("Now playing" names its value), PANEL-21 (full-sentence labels), PANEL-28 ("Open <App> on Mac" names what it opens) |

## Assumptions

- The status item is owned by AppKit (`NSStatusItem` + `NSPanel`), not SwiftUI's `MenuBarExtra`: a second click on the item must close the card (CONV-MAC-10), which `MenuBarExtra(.window)` could not do.
- The card's phone is the one in use (`activePhoneId`, settings.md); it renders from that phone's cached last state while the link is down.
- The phone reports `state.dnd`, `state.ringer`, `state.volume`/`state.volumeMax`, `ring.state` and `state.panel`; a phone that does not is shown as "not on this phone", not as zero.
- The foreground app is a **read** the Mac asks for only while the card is open (`task.front`, PROTOCOL.md). It is the same one-shot task-list read `task.continue` already makes, so it needs no opt-in switch: the person's open of the card is the action. The phone never watches or pushes its top task.
- The card is one component with two hosts (`PhonePanelView`), so the Deck's popover cannot drift from the menu-bar card.
- A menu-bar app's panel may take the keyboard without activating the app; the card relies on that for Tab/Esc/Return.
- The app list the phone already sends is the only source of the handoff row's name and icon; a package it does not know falls back to "Open Current App on Mac".

## Non-goals

- A settings page, a notification history or a second card in the card (Settings and the notification surface own those).
- Track title, artwork, a per-app volume, or a second audio device picker: the Mac's own Now Playing shows the track, and the phone's media volume is the only volume here.
- A general customisable card (reordering, hiding rows) or extra control modules; the phone's own quick-settings tiles and their Edit Controls mode are a later option (ISS-76 P3), not this card.
- A continuous foreground report or a foreground-history surface: the app in front is one read on the person's action (PANEL-26), never a watch, a log or a setting.
- A Control Center control: Control Center is its own opt-in extension (design/controls.md). The Dock icon's own menu is the menus' two starting points (MENU-18), not the panel's.
- Keeping the card open while another app is frontmost for more than a click or a key: the card is transient by convention.
- A second card for another phone at the same time.

## Open questions

- [NEEDS CLARIFICATION] With 0 phones the card still opens and says "No phone paired"; should it offer Pair Phone… instead of the disabled modules? Recommended: no (pairing is the Deck's), but one sentence naming the next step ("Open the Deck to pair a phone.") would be honest.
- [NEEDS CLARIFICATION] The card has no way to reach Settings for the phone it names (per-phone sharing lives there). Recommended: the gear's menu is the app's commands only; leave it, because Settings is one ⌘, away and the card is for acting on the phone.
