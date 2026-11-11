# Menus

Prefix: `MENU`. Owner docs: [design/mac-redesign.md](../design/mac-redesign.md) §3.8 (the bar, the marks, the cleanup), §5 (keyboard map), [UX.md](../UX.md) § "Keyboard shortcuts", [design/controls.md](../design/controls.md) (the Phone menu's shared mapping), [design/focus.md](../design/focus.md) (Do Not Disturb). Last reviewed: 2026-11-10, against main `aca59f10`.

## Purpose

The app's menu bar is how a Mac person finds every command and every shortcut without a help book: File, Edit, View, Phone, Navigate, Window, and an empty Help. The items the app draws are SwiftUI commands, so a rebuild cannot drop one; the few values that follow the running window (which style is checked, whether Hide Controls and Density can act) are written onto SwiftUI's own items when a menu begins tracking. macOS's own Enter Full Screen is AppKit's and follows the key window itself. The bar is the one place a shortcut can be discovered — a key with no menu item is a bug (CONV-MAC-06), with one deliberate exception: the Deck's ⌘F, which must stay window-scoped so a stream window keeps the key for the phone.

## User stories

| ID | Priority | Story |
|---|---|---|
| MENU-S1 | P1 | As a person, I want every command in the menu I expect it in, so that I do not have to guess where a feature lives. |
| MENU-S2 | P1 | As a person, I want to see a shortcut next to its command, so that the mouse is only one way to work. |
| MENU-S3 | P1 | As a person with a stream window open, I want the View and Phone menus to act on that window and show what it is doing, so that two windows cannot confuse them. |
| MENU-S4 | P2 | As a person, I want a command that cannot work to be disabled rather than missing, so that I learn it exists and when it works. |
| MENU-S5 | P2 | As a person, I want the bar to stay complete after windows open, close and the app reactivates, so that items never vanish. |
| MENU-S6 | P2 | As a person, I want the Window menu to list my windows, so that a lost window is one item away. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| MENU-1 | THE bar SHALL be exactly Contigua, File, Edit, View, Phone, Navigate, Window and Help, in that order; Help SHALL be empty (there is no help book); every item the app draws SHALL be a SwiftUI command's (never an AppKit item inserted into a SwiftUI menu) and SHALL carry an SF Symbol; AppKit's own items stay AppKit's. | K2 `MenuDumpTests` (the tree, the owners), `MenuModelTests`; e2e `menus` `[MENU-1]` (the whole bar is the design after each rebuild; every app item has a symbol); e2e `chrome` (the bar's shape) |
| MENU-2 | File SHALL be Add Phone… ⇧⌘N · a separator · New <App> Window ⌘N · a separator · Close ⌘W · Close All ⌥⌘W, with nothing after Close All; Add Phone… SHALL show the Deck and open the app's one add-phone sheet; New <App> Window SHALL name the key window's app, SHALL be enabled only while an app window is key and that app may open another (app-windows.md WIN-25, WIN-27), and with no app window key SHALL read "New Window" and be disabled. | e2e `chrome` (File's items and their keys); e2e `multiwin` `[WIN-25]` (the item's title follows the key app, ⌘N sends one `window.open` with `newInstance`); review of the command's action |
| MENU-3 | Edit SHALL be the system's standard Undo/Redo, Cut/Copy/Paste/Delete/Select All (and the system's own text items), so the code sheet's and the Deck's text fields work; the app SHALL add no item of its own there. | e2e `chrome` (Edit is the standard menu) |
| MENU-4 | View SHALL be Find Apps ⌘K · a separator · Immersive / Framed (one radio pair for the key stream window, ⌥⌘F on the pair, no section title, no icons; both unchecked and disabled while no stream window is key) · a separator · Hide Controls › (Instantly · Short · Long · a separator · Always Visible; the full-screen reveal choice, enabled while a stream window is key) · a separator · Show Touches · Live Text ⇧⌘T · a separator · Icon Size › (75 % · 100 % · 125 % · 150 %, the Deck's stored one checked, no key equivalents) · a separator · Density › (Default (<the Settings default>), the other percentages, a separator, Larger ⌘+, Smaller ⌘−, Actual Size ⌘0; enabled only for a key stream window that shows an app) · a separator · the system's own Enter / Exit Full Screen (fn‑F), last. The system item SHALL follow the key window and SHALL be disabled where the window cannot go full screen: the Phone Mirror opts out, the Deck may. | K2 `MenuModelTests.testTheStylePairHasExactlyOneChecked`, `testHideControlsIsForAKeyStreamWindow`, `testTheDensityItemsNeverRepeatTheDefaultsValue`, `FullScreenMenuTests`, `MenuMarksTests.testTheDeckKeyLeavesEveryStreamOnlyItemOffAndDisabled`; e2e `menus` `[MENU-4]` (the View menu, the pair, Hide Controls, Icon Size, Density, the system item last) and `[MENU-9]` (the Deck-key scene) |
| MENU-5 | Phone SHALL be Phone Mirror ⌘P · Open <App> on Mac ⇧⌘C (fallback "Open Current App on Mac"; disabled with its reason when a fresh foreground reply says there is nothing to open) · a separator · Turn Off Phone Screen · Do Not Disturb · Ring Phone (Stop Ringing while it rings) · a separator · Install APK…; it SHALL be built from the same `PhoneControlsState`/`PhoneControlsActions` the menu-bar panel uses, so the same mapping decides what can work; Turn Off Phone Screen SHALL be enabled only with the key phone window (a stream window that is not the phone window, or any non-stream window, disables it) and its check SHALL follow the phone's `state.panel`; Install APK… SHALL name its phase ("Sending x.apk… 40%", "Installing x.apk…"). | K2 `MenuMarksTests.testPhoneMirrorIsEnabledOnlyWhileThePhoneIsOnline`, `testTurnOffPhoneScreenIsForTheKeyPhoneWindowOnly`, `testTheHandoffItemFollowsThePhonesSubject`; e2e `menus` `[MENU-5]` (the items, the shortcut keys, the disabled Turn Off Phone Screen, the enabled controls for an online phone, the Deck key) |
| MENU-6 | Navigate SHALL be Back ⌘[ · Home ⇧⌘H · Recents ⌘↑, acting on the key stream window through its responder chain; Home and Recents SHALL act only in a phone-mode window and all three SHALL be disabled WHILE no stream window is key and WHILE the picture is frozen (Live Text or a cover). | K2 `NavShortcutTests` (every action, one per press), `LiveTextInputGateTests`, `MenuMarksTests.testNavigateIsDisabledWithoutAStreamWindow`; e2e `menus` `[MENU-10]` (the bar's design includes Navigate's three items) and `[MENU-6]` (the Deck-key scene) |
| MENU-7 | Window SHALL hold the standard Minimise ⌘M and Zoom, the system's own window group (Fill, Center, Move & Resize ›, Full Screen Tile ›), our own Next Window ⌘` (enabled only while two or more windows of the key app are open, app-windows.md WIN-29/WIN-30), then Bring All to Front and AppKit's own list of every open window, each entry naming its task while an app has several; the app SHALL show no full-screen item of its own in any menu (its hidden ⌃⌘F alternate, MENU-8, is not shown), and AppKit's own "Cycle Through Windows" item SHALL be removed by the cleanup pass so ⌘` has one owner. | K2 `MenuMarksTests.testTheSystemFullScreenItemsGetNoEdits`, `MenuCleanupTests.testNoFullScreenItemIsEverRemoved`, `FullScreenMenuTests.testOnlyAWindowThatHasNotOptedOutMayGoFullScreen`, `WindowListTests.testTheDecksAndSettingsWindowsAreTheAppsOwn`, `WindowCycleTests` (one cycle item, the cleanup); e2e `menus` `[MENU-7]` (no app full-screen item, the system's View item, the window list); e2e `multiwin` `[WIN-29]` |
| MENU-8 | EVERY shortcut the app defines SHALL appear in a menu (or, for a control, in its help tag) with its key: ⇧⌘N, ⌘N, ⌘`, ⌘K, ⌥⌘F, ⇧⌘T, ⌘+/⌘−/⌘0, ⌘P, ⇧⌘C, ⌘[, ⇧⌘H, ⌘↑, ⌘,, ⌘Q; the one window-scoped exception SHALL be the Deck's ⌘F (DECK-9), which is deliberately not a menu item. The full-screen shortcut SHALL be the system's own fn‑F on its View item; ⌃⌘F SHALL also toggle full screen through one hidden View item that keeps its key equivalent while hidden (`allowsKeyEquivalentWhenHidden`), so the person still sees macOS's own item alone. | K2 `MenuModelTests`, `MenuMarksTests.testTheFullScreenAlternateIsHiddenWithItsKey`, `StyleShortcutTests.testOptionCommandFTogglesTheStyleAndNeverReachesThePhone`; e2e `menus` `[MENU-4]` and `[MENU-5]` (the keys read back from the bar), `[MENU-7]` (the system item's fn‑F), `[MENU-8]` (the hidden ⌃⌘F item); e2e `multiwin` `[WIN-25]`/`[WIN-29]` (⌘N and ⌘` read back); UX.md's shortcut table (R-KEY-1) |
| MENU-9 | WHEN a menu begins tracking THE app SHALL write the values that follow the key window onto SwiftUI's own items: WHILE a stream window is key, exactly one of Framed/Immersive checked (both enabled), Hide Controls' enablement (a key stream window, either style) and its checked delay, Show Touches and Live Text checked from that window, Icon Size's checked percentage (read from the profile at that moment), Density's marks and its Default title (enabled only with an app); WHILE any other window is key (the Deck, Settings, a sheet) or there is none, Framed and Immersive SHALL both be unchecked and disabled, Hide Controls, Show Touches, Live Text and Density SHALL be disabled, Show Touches and Live Text SHALL be unchecked, and Navigate's three items SHALL be disabled; it SHALL also hide the app's ⌃⌘F alternate and keep its key while hidden; it SHALL only write values — never add, remove, retitle or replace an item, and never touch the system's own full-screen item. It SHALL run after SwiftUI has installed the command items it rebuilt since the last open (AppKit notifies before that install), and an item it cannot find SHALL NOT stop the rest of the pass: the item is named once, `menu marks: missing <menu ▸ item>`. | K2 `MenuMarksTests` (every rule, and "the edits do not depend on what the items show now", the post-install ordering, a missing item), `StreamMenuKeyTests` (every key-window transition), `MenuMarksTests.testTheDeckKeyLeavesEveryStreamOnlyItemOffAndDisabled`; e2e `menus` `[MENU-9]` (the pair, Hide Controls, Show Touches, Live Text and Density after each style pick, the Deck key with a stream window open behind it, read from a menu that is tracking, Icon Size's checkmark on the first open after a pick, the relaunch) |
| MENU-10 | A rebuild of the bar — a style pick, a second window, closing the last stream window, the menu-bar extra being switched off and on, or a relaunch — SHALL leave the bar the design: every item present, every separator correct, every mark right. | e2e `menus` `[MENU-10]` (dumps 0–15, each "the whole bar is the design after the rebuild", and the relaunch's dump 11) |
| MENU-11 | THE bar SHALL have no title twice (AppKit's window list and its window-tiling group headings excepted), no leading, trailing or doubled separator, and no Apple "Send … Feedback" item; the cleanup pass SHALL only remove, never add, move, retitle or drop a menu-edge separator while SwiftUI is still filling it, and SHALL never touch the system's own full-screen item or its tiling submenu. | K2 `MenuCleanupTests` (the doubled separator, the edge, Help's feedback item, "a clean menu has nothing to remove", no full-screen removal); e2e `menus` `[MENU-11]` (the three bar-wide rules on every dump) |
| MENU-12 | THE status item's own menu (Settings… ⌘, · About Contigua · Quit Contigua ⌘Q) SHALL belong to the panel surface and SHALL be built by one function (panel.md PANEL-3); the app menu above SHALL keep the system's About, Settings…, Services, Hide, Hide Others, Show All and Quit. | K2 `MenuBarPanelMachineTests.testTheIconMenuIsSettingsAboutQuit` (the icon's menu); review of the app menu's standard items (untested end to end) |
| MENU-13 | ONE name SHALL be used for each thing across the bar, the panel, the Deck and Shortcuts: "Add Phone…", "New <App> Window", "Next Window", "Find Apps", "Phone Mirror", "Open <App> on Mac" (fallback "Open Current App on Mac"; the card's module "Focus" is still "Do Not Disturb" in the menu), "Show Touches", "Live Text", "Framed", "Immersive", "Hide Controls", "Icon Size", "Density", "Turn Off Phone Screen", "Do Not Disturb", "Ring Phone"/"Stop Ringing", "Install APK…", "Back", "Home", "Recents", "Enter Full Screen"/"Exit Full Screen". | e2e `menus` `[MENU-10]` (the titles the checks read back) and `[MENU-4]`/`[MENU-5]` (the exact titles); review against UX.md's copy |
| MENU-14 | A menu item's name SHALL state its result: Density's first item names what Default restores, the Ring item reads Stop Ringing while it rings, the system's full-screen item reads Enter in a window and Exit in full screen, and no item SHALL contain an internal code. | K2 `MenuModelTests.testTheDensityItemsNeverRepeatTheDefaultsValue`; e2e `menus` `[MENU-4]` (the Density submenu's titles), `[MENU-7]` (the system item's Enter/Exit title); e2e `menubar-shots` `[PANEL-11]` (the Ring item flips to Stop Ringing) |
| MENU-15 | THE menu items SHALL be real menu items with their key equivalents (never buttons that imitate them), so the keyboard, VoiceOver and the system's own menu handling all work; the app SHALL document every shortcut it adds in UX.md's table (R-KEY-1 reads it). | e2e `menus` `[MENU-4]` (the keys and modifiers as the bar reports them); `scripts/check-rules.sh` R-KEY-1 (the table and the code agree) |
| MENU-16 | Opening a menu, reading its marks or dumping it SHALL send nothing to the phone; only the person's pick of an action item SHALL act (and that action is the panel's or the window's own). | review of `MenuMarks`/`MenuDump` (read-only); untested as an e2e zero-write assertion |
| MENU-17 | THE app's items SHALL be built from one small Equatable menu model that holds only what the menu shows (titles, marks, enablement), recomputed at most every 250 ms; a change to any other state — a battery report, a stall, a Now Playing update, an occlusion flip — SHALL NOT rebuild the items; WHILE a menu is tracking NO change SHALL rebuild them (the newest value waits for the menu to close, and only the latest one lands); and a menu that is tracking SHALL NOT pause a stream (a menu is transient, and pausing on it was half of the person's open-menu loop). | K2 `MenuSnapshotTests` (only menu values reach the model, the tracking gate, the deferred value, the pause rule); e2e `menus` `[MENU-17]` (a real menu held open for 5 s while the state under it changes: 0 rebuilds, the same items and submenu, still open) |
| MENU-18 | WHEN the Dock icon's own menu is opened (`applicationDockMenu`) THE menu SHALL offer Find Apps and Phone Mirror, built from the same `PhoneControlsActions` as the Phone menu and the menu-bar panel, with Phone Mirror enabled by the same mapping (`PhonePanelItem.phoneScreen`, so offline it is disabled) and Find Apps always enabled; a pick SHALL run that shared action (Find Apps shows the one Deck and focuses its search field, Phone Mirror raises the phone window). | K2 `DockMenuTests.testTheDockMenuOffersFindAppsAndPhoneMirror`, `testPhoneMirrorIsDisabledWithTheMenusRule`, `testEachPickRunsItsSharedAction`; review of `AppDelegate.applicationDockMenu` (the Dock's own menu cannot be opened in a quiet run) |

Priority note: MENU-1, 2, 4, 5, 6, 7, 8, 9 and 10 are P1 — a person cannot find the app's commands or trust the bar without them. The cleanup detail and the naming audit are P2.

## States and events

The bar's own state is the key window's (`StreamMenuState`): one machine with two states — no stream window key (the Deck, Settings, a sheet, the app deactivated) and a stream window key carrying that window's values. A non-stream window becoming key drops the whole set, so no value can outlive the window it described; a value change only lands while its own window is key. The settings every key window shares (Show Touches, the reveal delay, the default density, the Deck's icon size) stay on `StreamMenuState`, but the stream-only items read them only in the stream-key state. The items' marks and enablement are a pure function of that state plus a menu snapshot (`MenuMarks`), applied when a menu begins tracking; MenuCleanup's removals are a second pure function.

| State | Event | Result |
|---|---|---|
| bar, any | `launch` | built once from the commands; AppKit's items cleaned |
| bar, any | `app activates` / SwiftUI rebuilds | the same items, rebuilt; marks reset to their build values until the next open corrects them |
| Deck / Settings / sheet key | `menu opens` | Framed/Immersive off and disabled; Hide Controls, Show Touches, Live Text and Density disabled (the two toggles unchecked); Navigate's three disabled; the system's full-screen item enabled where the key window may go full screen; the window list names the open windows |
| stream window key | `menu opens` | the pair checked and enabled; Hide Controls enabled in either style; Show Touches and Live Text checked from that window and enabled; Density enabled only with an app; Navigate enabled unless frozen or the link is down; the system's full-screen item enabled (not for the mirror) |
| phone window key | `menu opens` | as a stream window, with the system's full-screen item disabled and Turn Off Screen enabled |
| any | `a stream window becomes key` | its values replace whatever the last key window held, whole; the items are corrected at once |
| any | `a non-stream window becomes key` (Deck, Settings, a sheet, an inactive app) | no stream window is key: every per-window value is dropped; the items are corrected at once |
| any | `the key stream window's values change` | the items follow; a change from a window that is not key is ignored |
| any | `style pick (Framed/Immersive or ⌥⌘F)` | the key window's style changes; the pair's marks are corrected on the next open |
| any | `Hide Controls pick` | the reveal delay is stored (the same key Settings ▸ General uses, plus Always Visible) |
| any | `Density pick / ⌘+ / ⌘− / ⌘0` | the key window's app override changes or clears; the marks follow |
| any | `Live Text toggles` | its check follows; the Navigate items disable while frozen |
| any | `last stream window closes` | the View style pair is off and disabled, Show Touches, Live Text and Density off and disabled, Navigate disabled, the Window list loses it; the items stay |
| any | `menu-bar extra switched off/on` | the whole scene graph rebuilds; the bar is still the design |
| any | `relaunch` | the bar is built from scratch; the Deck is key, so the pair is off and disabled |
| any | `state the menu does not show changes` | nothing: the commands are not rebuilt (the snapshot is equal) |
| any | `state the menu shows changes while no menu tracks` | the model publishes it and the items are rebuilt, at most every 250 ms |
| any | `a menu begins tracking` | the marks are written onto the existing items; a state change waits (the newest value only) |
| any | `the menu stops tracking` | the value that waited lands, if it still differs; a window the menu covered is judged by its own occlusion again |

| State | Event | Result |
|---|---|---|
| Window menu | `a window opens` | AppKit lists it after Bring All to Front |
| Window menu | `a window closes` | its entry leaves; the rest stay |
| View menu | `key window changes` | the system's Enter / Exit Full Screen title and enablement follow |

Ignored events, stated so nobody builds them: a mark correction while a menu is not tracking (only the next open matters), a cleanup while SwiftUI is still building a menu, an Edit item added by the app, a View item section title, any second full-screen item, a state change the menu does not show, a value change from a window that is not the key stream window, and a rebuild while a menu tracks.

## Phone count and connection

| Situation | The bar shows |
|---|---|
| 0 phones | Add Phone… ⇧⌘N, Find Apps and the standard items work; New Window and Phone's items are disabled (no key app window, nothing to mirror, move, ring or install); the app menu's Settings opens the window's empty state. |
| 1 phone | Every Phone item that can work is enabled; the actions act on that phone. |
| 2+ phones | The same bar; every action acts on the phone **in use** (the panel's mapping, PANEL-5). The menus offer no phone picker: Settings ▸ Use This Phone switches, and the bar follows. |
| Connecting | Phone's items are disabled (their mapping needs an online phone) until the link is up; View/Navigate/Find Apps work. |
| Connected | The full mapping: Mirror, Move, Ring, DND, Install, Turn Off Screen (with a mirror) enabled. |
| Offline / reconnecting | The Phone items disable with the link; the bar stays complete and nothing disappears; Navigate's items still act on the window (input is dropped by the window, not the menu). |
| Pair again | As offline; the Deck's banner is the way to pair. |
| Phone that can't do the feature | Its control is disabled in the menu by the same mapping that gives the panel its sentence (the menu has no room for the sentence; the panel and the Deck say why). |
| Frozen picture (Live Text, cover, screen off) | Navigate's three items are disabled; every other item keeps its own rule. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: Find Apps ⌘K shows the Deck and focuses its search field (MENU-4); the Deck's own ⌘F is DECK-9 — the menus deliberately carry no ⌘F |
| CONV-MAC-02 | applies: File ▸ Close ⌘W and Close All ⌥⌘W, Window ▸ Minimise ⌘M, ⌘Q, ⌘,, ⌘H are all present and the app takes none of them for another meaning |
| CONV-MAC-03 | applies: menus are AppKit's (Esc closes one, arrows walk it, Return picks); no sheet or popover in this surface; the menu items are reachable with the keyboard |
| CONV-MAC-04 | applies: MENU-3 (the standard Edit menu is what makes the code and search fields' editing keys work) |
| CONV-MAC-05 | applies: MENU-4 (Density's ⌘+/⌘−/⌘0; the Deck's grid uses the same keys while it is key, DECK-6) |
| CONV-MAC-06 | applies except the one documented window-scoped key: every app shortcut is in a menu (MENU-8), and the only key not in one is the Deck's ⌘F (DECK-9); [NEEDS CLARIFICATION] whether that exception needs the field's help tag to name it |
| CONV-MAC-07 | applies: MENU-5 (⌘P is Phone Mirror; the app prints nothing) |
| CONV-MAC-10 | applies: the status item's own menu is the panel surface's (PANEL-3); the bar has no other status menu |
| CONV-MAC-11 | applies: every item that opens a window goes through the one open-or-raise function (Add Phone…/Find Apps show the one Deck, Phone Mirror raises the one mirror, Settings the one window) — MENU-2/5/12 |
| CONV-MAC-12 | n/a: the menus are not a window and remember nothing themselves |
| CONV-MAC-13 | applies: MENU-4, MENU-7 and MENU-11 (exactly one Enter/Exit Full Screen, the system's, last in View; no duplicate title, no empty menu, no leading/trailing/doubled separator; a checkmark follows the key window) |
| CONV-MAC-14 | n/a: no content to resize |
| CONV-MAC-15 | applies: closing the last window does not quit; the bar stays and Find Apps brings the Deck back |
| CONV-MAC-16 | n/a: menus accept no drops, paste or Services |
| CONV-MAC-20 | applies: the bar is drawn by the system, so light/dark/accent/Increase Contrast follow it; the app's own items' symbols render in both appearances |
| CONV-MAC-21 | applies: MENU-15 (real menu items, labels are the titles, keys are the equivalents) and MENU-1 (a symbol on every item the app draws) |
| CONV-MAC-22 | applies: the bar has no motion of its own; Reduce Motion changes nothing here |
| CONV-MAC-23 | applies: MENU-9/MENU-14 (a checkmark and a title say the state; nothing is conveyed by colour alone) |
| CONV-MAC-24 | applies: no permission is asked for by the bar |
| CONV-MAC-25 | n/a: the system draws the items; the app styles none of them |
| CONV-MAC-26 | n/a: no custom layout in the bar |
| CONV-AND-01 | applies: MENU-6 (Back/Home/Recents are the phone's own navigation, enabled per window) |
| CONV-AND-02 | n/a: no phone-side UI |
| CONV-AND-03 | n/a: no Android permission |
| CONV-AND-04 | applies: only a person's pick of a Phone item reaches the phone (MENU-5/MENU-16); nothing else in the bar changes a phone setting |
| CONV-PD-01 | applies: the table above (0, 1, 2+; every action acts on the phone in use and Settings is the switch) |
| CONV-PD-02 | applies: MENU-5 and the table above (the Phone items use the panel's one mapping, so connecting/offline/pair-again and a missing capability each disable the right items; the sentence lives in the panel) |
| CONV-PD-03 | applies: MENU-5 (Ring Phone flips to Stop Ringing on the phone's report, Turn Off Phone Screen's check follows `state.panel`, Install APK… names its phase — never a local guess) |
| CONV-PD-04 | n/a: no slider or toggle in the bar |
| CONV-PD-05 | applies: no notification text, media title or file content in any menu; an install's own file name appears on screen only (the person picked it) and is never logged |
| CONV-PD-06 | n/a: the bar runs no frame-rate work of its own |
| CONV-PD-07 | applies: MENU-13 |
| CONV-PD-08 | applies: the table above (the bar's marks as one pure function of the key window; MENU-9) |
| CONV-PD-09 | applies: MENU-14 (names state their result: Default (N%), Stop Ringing, Exit Full Screen), MENU-1 (an item that cannot act is disabled, never removed) |

## Assumptions

- macOS 26 / SwiftUI `commands`: the app draws every item it owns there; AppKit items (full screen, the window list, Edit's text items, the tiling group) are the system's and stay as the system draws them.
- SwiftUI builds a command item once and does not re-read its state, so `MenuMarks` writes values onto existing items when a menu tracks. It never inserts or removes an item.
- AppKit posts `NSMenu.didBeginTrackingNotification` before SwiftUI installs the command items it rebuilt since the last open: a pass run inside the notification is replaced while the menu is on screen (ISS-93). The pass therefore runs at the end of that turn, and again after any item change while a menu tracks.
- SwiftUI re-evaluates `.commands` whenever anything the body reads changes, and every evaluation builds its NSMenu items again: a rebuild under an open menu is what closed the person's submenu. `MenuBarModel` is therefore the only thing the body reads, and the model publishes only menu values, never while a menu tracks.
- The app's ⌃⌘F alternate is a hidden View item: AppKit's item shows only fn‑F here and does not take ⌃⌘F, and a hidden item keeps its key with `allowsKeyEquivalentWhenHidden`. It is the only full-screen item the app owns and it is never shown.
- Automatic window tabbing is off, so entering full screen cannot add Show Tab Bar or Show All Tabs to View.
- AppKit's own Enter Full Screen is last in View, after a separator, as in Apple's apps. AppKit reads the key window's collection behaviour itself, so the Phone Mirror's `.fullScreenNone` disables it and no app code writes its title or enablement. AppKit's window-tiling group stays in Window with its own headings.
- The status item is AppKit's (`NSStatusItem` + `NSPanel`), so the icon's menu is built with AppKit; it is the panel surface's (PANEL-3).
- The window list is AppKit's own, after Bring All to Front; the Deck and Settings windows are made listable by clearing SwiftUI's exclusion flag.
- `NSFullScreenMenuItemEverywhere` is left at its default, so AppKit places its own Enter Full Screen in View.

## Non-goals

- A Help book, a feedback item or a search in the menu bar (Help stays empty).
- A custom menu bar, or a Control Center control of the app's commands (Control Center is the opt-in extension). The Dock icon's own menu is the two starting points of MENU-18, not a second place for every command.
- Items for the file domain, notifications, media or Settings' per-phone pages: those surfaces own their own actions.
- A Shortcuts/App Intents entry per menu item: those are separate entry points, listed in docs/design/intents.md.
- Reordering, hiding or customising the system's items.

## Open questions

- [NEEDS CLARIFICATION] The Deck's ⌘F is not in any menu (CONV-MAC-06). Recommended: keep it out (a menu item would eat ⌘F in every stream window) and put "Find (⌘F)" in the search field's help tag, which closes the discovery gap without moving the key.
- [NEEDS CLARIFICATION] The Phone menu's items disable with no visible reason; only the panel says why. Recommended: leave the bar honest by disablement (a menu cannot carry a sentence), and accept that the panel is the place to learn why.
- [NEEDS CLARIFICATION] macOS 26 adds its own Window items (Minimise All ⌥⌘M, Zoom All, Fill, Center, Move & Resize, Arrange in Front, Remove Window from Set). Recommended: leave them (the system's, not the app's) and keep the design's rule about duplicates and separators, which they pass.
