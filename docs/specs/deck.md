# Deck

Prefix: `DECK`. Owner docs: [design/mac-redesign.md](../design/mac-redesign.md) §2–3.3, §4 (the Link machine), [UX.md](../UX.md) § "macOS app" 1, [DESIGN.md](../DESIGN.md) (Deck), [dragdrop.md](../design/dragdrop.md). Last reviewed: 2026-10-27, against main `66dd3ea`.

## Purpose

The Deck is the app's one home window and the only place a person starts from: your phone's apps as a grid, the connection as one chip, and the pairing screens while there is no phone yet. It is a view of the phone *in use* — adding, switching and forgetting phones live in Settings — and every other window (a stream window, the Phone Mirror, the menu-bar panel) is reached from here or from the menus.

## User stories

| ID | Priority | Story |
|---|---|---|
| DECK-S1 | P1 | As a person with a paired phone, I want my apps at launch without pairing again, so that the Deck is the app I left. |
| DECK-S2 | P1 | As a person on the first run, I want three steps and one button, so that I know what to do before I understand the product. |
| DECK-S3 | P1 | As a person with 200 apps, I want to find one by typing its name, so that I do not scroll. |
| DECK-S4 | P2 | As a person scanning the grid, I want a letter rail that jumps sections, so that a long list is one click. |
| DECK-S5 | P2 | As a person on a small or large screen, I want the grid to fit the window, so that nothing is clipped at any size. |
| DECK-S6 | P1 | As a person whose phone dropped off, I want one calm line saying what happened and what to try, so that I am not left guessing. |
| DECK-S7 | P2 | As a person, I want the phone's controls one click from the grid, so that changing the volume does not mean leaving the Deck. |
| DECK-S8 | P2 | As a person, I want a drag onto the Deck to install an app, open a link or send a file, so that I do not hunt for the right window. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| DECK-1 | WHEN the app launches with a remembered phone THE Deck SHALL open in Phone mode at once from the cached app list, start one silent connection attempt, and SHALL NOT show Welcome, Nearby or a pairing sheet. | K2 `LinkMachineTests.testLaunchWithARememberedPhoneConnectsAtOnceWithoutAScreen`; e2e `deck` `[DECK-1]` (the launch asked the phone for its apps) |
| DECK-2 | WHEN the app list arrives THE Deck SHALL request every app's icon once, draw the layered reply when the phone sends one and fall back to the flat reply, and SHALL draw a fallback tile for an app with no icon. | e2e `deck` `[DECK-2]` (layered and flat replies, the total); K2 `DeckGridTests.testAMissingIconStillDrawsATile`, `IconReferenceTests.testNoIconIsUpscaled` |
| DECK-3 | THE grid SHALL draw one cell per launcher entry, keyed by its own id: two launcher activities of one package SHALL be two cells, an entry with no label SHALL fall back to its package's last part, and two entries with the same id SHALL draw as one. | e2e `deck` `[DECK-3]` (201 cells, each with words and its own id); K2 `DeckGridTests.testTwoLaunchActivitiesOfOnePackageAreTwoCells`, `testARepeatedEntryIsOneCell`, `testAnEntryWithoutALabelFallsBackToThePackage` |
| DECK-4 | THE grid SHALL lay out from the width of the frame that draws it: 96×108 pt cells at 100%, a 64 pt icon, a fixed 16 pt gap, a 24 pt vertical inset, a centred block that stops growing at 880 pt (5 columns at 640 pt, 8 at 1000 pt and wider), and SHALL NOT clip a cell on any drawn frame. | K2 `DeckGridTests.testTheGridUsesTheDesignedMetrics`, `testColumnCountsAndTheCentredBlockFollowTheWidth`, `testTheDrawnLayoutFollowsTheWidthItIsGiven`, `testAFrameDrawnAtItsWidthFits`; e2e `deck` `[DECK-4]` (the block at 640 and 1200 pt) |
| DECK-5 | WHILE the Deck is zoomed, unzoomed or drag-resized THE drawn frames SHALL stay within `deck_zoom_frame_p95_ms` and `deck_drag_frame_p95_ms` (NFR.md) and SHALL fit the width each frame is drawn at. | e2e `deck` `[DECK-5]` |
| DECK-6 | WHEN ⌘+ / ⌘− / ⌘0 is pressed WHILE the Deck is key THE Deck SHALL scale the whole grid (cells, icons, gaps, insets and the 880 pt cap) through 75 / 100 / 125 / 150%, SHALL store the choice for this profile, and SHALL leave a stream window's density alone; the same keys WHILE a stream window is key SHALL NOT scale the Deck. | K2 `DeckGridTests.testZoomScalesTheWholeGridTogether` (the chosen fraction's step and clamp); review of `GridNavigator`'s key filter and `DeckZoom`; the keys themselves have no e2e line yet (untested end to end) |
| DECK-7 | WHILE the search field is empty and the list has at least 30 apps THE Deck SHALL show the A–Z rail (`#` last): 20 pt targets, a 9 pt letter magnified under the pointer, the top row's letter in the accent, empty letters dimmed at 35%, a click or drag jumping to that letter's first app and skipping forward over empty letters; a window too short for 27 slots SHALL condense the rail to every other or every third letter before hiding it, and the rail SHALL NOT show while searching. | K2 `DeckGridTests` (letters and first indexes, `testRailClickSkipsForwardToTheNextLetterWithApps`, `testRailFisheyeMagnifiesTheLetterUnderThePointer`, `testRailCondensesItsSlotsWhenTheWindowIsShort`, `testRailHidesWhileSearchingAndBelowThirtyApps`, `testRailLettersAreTwentyPointTargetsAndHideWhenTooShort`); e2e `deck` `[DECK-7]` (the T click, the short rail) |
| DECK-8 | WHEN the person types in the search field THE Deck SHALL filter the grid by app label, case-insensitively and ignoring surrounding whitespace; IF nothing matches THEN it SHALL say "No apps match “<query>”"; WHILE the list is empty and the app list has not arrived THEN it SHALL draw 12 placeholder cells. | K2 `DiscoveryAndStoresTests.testFilterMatchesLabelsCaseInsensitively`; review of the empty and loading states |
| DECK-9 | WHEN ⌘F is pressed WHILE the Deck is key THE Deck SHALL focus the search field and select the text already typed; WHILE a stream window is key the same ⌘F SHALL reach the phone as meta+F and the Deck's field SHALL NOT take focus. | e2e `deck` `[DECK-9]` (the Deck's ⌘F, and the stream window's); K2 `StyleShortcutTests.testCommandFStillReachesThePhone` |
| DECK-10 | WHEN ⌘K, the Dock icon, the menu bar's Find Apps or the File menu's Add Phone… route shows the Deck THE app SHALL show the one Deck window (unminimising it) and SHALL NOT create a second; Find Apps SHALL also put the keyboard in the search field. | e2e `deck` `[DECK-10]` (⌘K brings the Deck up with search focused); review of `DeckWindow.open`/`show` |
| DECK-11 | WHEN ←→↑↓ is pressed WHILE the Deck is key THE Deck SHALL move the selection (the first arrow selects the first cell; ← and → SHALL leave the caret alone while the search field has text); WHEN ↩ is pressed THE Deck SHALL open the selected app, else the first match; WHEN Esc is pressed WHILE the field has text THE Deck SHALL clear it and otherwise do nothing. | K2 `DiscoveryAndStoresTests.testFirstArrowSelectsTheFirstCell`, `testMovesWithinTheGridAndStopsAtTheEdges`; review of `GridNavigator` (Return and Esc) |
| DECK-12 | WHEN the person clicks a cell THE Deck SHALL open that app's stream window; a second open WHILE its window is opening or open SHALL raise that window instead of making another. | K2 `OpeningDedupeTests.testASecondOpenWhileTheAppIsOpeningRaisesTheSameWindow`, `testAFinishedWindowDoesNotSwallowANewOpen` |
| DECK-13 | THE toolbar SHALL carry, packed left and right, the traffic lights, one status chip, the Phone button, the Settings gear and the search field at the trailing end, with nothing floating between the groups; the Phone button SHALL be disabled unless the link is online; the window title SHALL be the phone's name (its nickname first), else "PocketDeck". | review of `PhoneDeckView`'s toolbar; K2 `PhoneNicknamesTests` (the one name); e2e `nickname` (the live title) |
| DECK-14 | THE status chip SHALL show the link as a dot plus words — Connected, Connecting…, Reconnecting… (pulsing), Offline, Pair again — and while online SHALL add the lock (while locked) and the battery (by quarter, with its percentage, red below 13%); WHILE a pairing sheet is up the chip SHALL be hidden. | review of `Link.chip`/`BatterySymbol`; K2 `LinkMachineTests` (every link state); K2 `DeckGridTests.testBatteryGlyphMatchesTheLevel` |
| DECK-15 | WHILE the link is down THE Deck SHALL show at most one banner, naming the cause in the person's words and at most one button, and SHALL NOT show a reason code; a transient failure SHALL show nothing and only move the chip; a repeated cause SHALL update in place rather than flash. | K2 `LinkMachineTests.testBannersNeverMentionReasonCodes`, `testTransientFailuresBackOffAndShowNothing`, `testBusyShowsTheBannerAtOnceAndRetriesSlowly`, `testLocalNetworkDeniedStopsAndExplains`; review of `BannerView` |
| DECK-16 | THE banner's single button SHALL act: Try now SHALL retry at once; Pair again SHALL open a new user-driven pairing; Open Settings SHALL open System Settings' Local Network pane; a banner with no possible next step SHALL carry no button. | K2 `LinkMachineTests.testReachabilityHintsAndTryNowRetryImmediately`, `testTryAgainIsANewPairing`, `testCancelReturnsToWhereTheUserWas`; review of `Banner.openLocalNetworkSettings` |
| DECK-17 | WITH no remembered phone THE Deck SHALL show Welcome on the first run and Nearby afterwards; Nearby SHALL list the discovered phones once each (deduplicated by device id, sorted by name), mark a remembered one "Paired" and a keyless one Pair again, offer Pair with QR and Connect manually…, and say "Looking for phones on this network…" while it searches; Esc or Done SHALL close the add-phone sheet. | K2 `DiscoveryAndStoresTests.testOneRowPerDeviceIdAcrossInterfaces`, `testResultsWithoutATextIdAreIgnored`, `testSortedByNameAndOtherVersionsSkipped`; e2e `pair`, `qr` |
| DECK-18 | THE Deck SHALL be one window: closing it SHALL NOT quit the app (a menu-bar app), and a Dock or Finder reopen SHALL show it again; only ⌘Q SHALL quit. | untested (no check drives the Dock or a reopen; only the code's `applicationShouldTerminateAfterLastWindowClosed`/`applicationShouldHandleReopen` is reviewed) |
| DECK-19 | THE Deck SHALL open at 760×600 pt with no stored frame, SHALL never be smaller than 640×420 pt, and every control SHALL be reachable at the smallest supported screen (1280×800). | K2 `LayoutTests.testTheDeckFitsAtTheSmallestScreen`; review of `defaultSize` and `DeckRoot`'s minimum frame |
| DECK-20 | WHEN the status chip is clicked THE Deck SHALL open the shared phone controls in a popover: the same 300 pt card, without the gear and without Settings/Quit rows, whose controls act on the phone. | K2 `PhonePanelTests.testTheDeckStatusPillOpensTheSamePanel`; e2e `deck` `[DECK-20]` (the popover is the shared panel; its DND click reached the phone) |
| DECK-21 | WHEN a file is dropped on the Deck THE Deck SHALL install an `.apk`/`.apks`/`.xapk` on the phone, open a link (or a `.webloc` file) on the phone, and transfer any other file; a drop it refuses SHALL be refused with a reason, and a phone that is away SHALL refuse the drop rather than queue it. | K2 `ApkBundleTests` (parts), `OpenLinkTests.testReadsAWeblocFile`, `FileDropTests.testOverTheCapRefusesNothingSent`; e2e `drop`, `apk` |
| DECK-22 | WHILE the person browses the Deck (search, scroll, icons, opening and closing a window) THE Deck SHALL send no write to the phone. | e2e `nfr` (read-only Deck browsing and icons) |
| DECK-23 | THE Deck SHALL write no app list, notification text, file name, path or media title to a log or crash report. | review of the Deck's logging (ids, counts and states only) |

Priority note: DECK-1, 2, 8, 9, 11, 12, 13, 14, 15, 17, 18 and 19 are P1 — without them the Deck is not the app's home. Zoom, the rail, the popover and drop are P2.

## States and events

Two machines meet here: the Deck's *mode* (what the window shows, from the profile) and the *Link* (the connection, one value the chip and banner read; `LinkMachine` in `macOS/Sources/PocketDeck/Link.swift`, tables in design/mac-redesign.md §4.3). The grid's own state is a query, a selection and one stored zoom, not a mode.

| State | Event | Result |
|---|---|---|
| Welcome | `launch` | Welcome (no phone remembered, Welcome never seen) |
| Welcome | `findMyPhone` | Welcome seen is stored; → Nearby |
| Nearby | `phoneDiscovered` | the row appears (and leaves after its discovery expires) |
| Nearby | `pair(row)` | the code sheet; success → Phone mode with the new phone |
| Nearby | `pairWithQR` / `connectManually` | the QR or manual sheet; success → Phone mode |
| Nearby / Phone | `welcome` | Phone mode; the chip reads Connected |
| Phone | `link lost` | the chip reads Reconnecting…, the grid dims and stops taking clicks, windows stay |
| Phone | `15 s without a session` | the chip reads Offline; one banner (DECK-15) |
| Phone | `forget(active phone)` | Welcome or Nearby (whatever the profile remembers now) |
| any | `sheet open` | the chip is hidden; the grid keeps its apps behind the sheet |
| any | `sheet dismissed` | the search field takes the keyboard |
| any | `search typed` | the grid filters (DECK-8); the rail hides; the selection clears |
| any | `⌘F` WHILE Deck key | the field is focused and its text selected |
| any | `⌘F` WHILE a stream window key | the Deck ignores it; the phone receives meta+F |
| any | `arrow` / `return` / `esc` | selection, open, clear (DECK-11) |
| any | `⌘+ / ⌘− / ⌘0` WHILE Deck key | the grid zooms and stores it |
| any | `zoom key` WHILE another window key | ignored by the Deck |
| any | `open(app)` | that app's window (or the one already open) |
| any | `⌘K` / Dock click / reopen | the one Deck window, key, search field focused |
| any | `close` | the window closes; the app and its session keep running |

Ignored events, stated so nobody builds them: Esc with an empty query (no window closes), Return with no apps and no selection, an arrow with a modifier held, a drop while the phone is away, and any zoom key while another window is key.

## Phone count and connection

| Situation | The Deck shows |
|---|---|
| 0 phones | Welcome (first run) or Nearby with the search line, Pair with QR and Connect manually… (DECK-17). |
| 1 phone | Phone mode: chip, title, grid from cache; everything acts on that phone. |
| 2+ phones | Phone mode for the phone **in use** only. The Deck offers no phone switch: Settings ▸ Phones' Use This Phone decides, and the Deck follows it. |
| Connecting | Phone mode at once from the cache, chip "Connecting…", the grid dimmed and not clickable until the link is online. |
| Connected | Chip green; lock and battery when the phone reports them. |
| Offline / reconnecting | "Reconnecting…" then "Offline" after 15 s; grid dimmed, one banner with Try now; nothing is replaced and no window closes. |
| Key rejected | Chip "Pair again"; banner "*phone* no longer trusts this Mac." with Pair again; the reconnect loop stops. |
| Phone that can't do the feature | The Deck's features need only the app list. A phone that reports an incompatible version gets its banner and no retry loop; nothing is hidden. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: DECK-9 (⌘F focuses and selects; a stream window's ⌘F belongs to the phone) |
| CONV-MAC-02 | applies: the standard items — File ▸ Close ⌘W and Close All ⌥⌘W, Window ▸ Minimise ⌘M, Quit ⌘Q, Settings ⌘,, Hide ⌘H — and the Deck takes none of them for its own |
| CONV-MAC-03 | applies: DECK-11 (arrows move the selection, Return opens, Esc clears the search); Esc closes the add-phone, code, QR and manual sheets (DECK-17); Tab follows the system's focus order |
| CONV-MAC-04 | applies: the search field is the standard toolbar field (⌘A, ⌘C/⌘X/⌘V, ⌘Z, ⌥←/→, ⌘←/→) |
| CONV-MAC-05 | applies: DECK-6 (⌘+ / ⌘− / ⌘0 scale the grid; View ▸ Larger / Smaller / Actual Size name the same keys) |
| CONV-MAC-06 | deviates, unapproved: ⌘F is deliberately not a menu item so a stream window keeps it (DECK-9), and the search field's help tag does not name it — [NEEDS CLARIFICATION] whether that counts as "visible", and whether the field's help tag should say "Find (⌘F)". Every other shortcut is in a menu (DECK-6, menus.md) |
| CONV-MAC-07 | applies: the app's one re-used key is ⌘P = Phone Mirror (menus.md), not the Deck's |
| CONV-MAC-10 | n/a: the Deck is not the status item's panel; the chip's popover is the panel's second host (panel.md) |
| CONV-MAC-11 | applies: DECK-10/DECK-18 (one Deck; ⌘K, the Dock icon and the panel raise it) |
| CONV-MAC-12 | [NEEDS CLARIFICATION] the stream windows remember their frames, but the Deck is a SwiftUI `Window` with `.restorationBehavior(.disabled)` and no frame autosave of its own, and no check asserts its frame across a relaunch. Likely deviates from "windows remember size and position" (misses.md, unverified) |
| CONV-MAC-13 | n/a: the Deck adds no menu item and no full-screen command; the menus are menus.md's |
| CONV-MAC-14 | applies: DECK-4 and DECK-5 (laid out per frame, no clipping, no stale width) |
| CONV-MAC-15 | applies: DECK-18 (closing the Deck does not quit; the Dock reopens it) |
| CONV-MAC-16 | applies: DECK-21 (a drop is accepted, refused with a reason, or the Deck says the phone is away); copy and paste are the standard text behaviour |
| CONV-MAC-20 | applies: the Deck is the system's own window material and text styles; light, dark, accent and Increase Contrast render (reviewed from e2e captures) |
| CONV-MAC-21 | applies: DECK-13 (every icon-only button has a help tag and a label: Phone, Settings, the chip) and DECK-11 (arrow keys never replace VoiceOver's own order); review of the grid cells' labels |
| CONV-MAC-22 | applies: the Deck's only motion is the mode cross-fade and the banner's move; Reduce Motion removes them |
| CONV-MAC-23 | applies: DECK-14 (the chip is words as well as a dot; the battery reads a percentage) |
| CONV-MAC-24 | applies: the Deck asks for no permission; Local Network is asked for by the system when the app first browses, and a denial is one banner with Open Settings (DECK-15/16) |
| CONV-MAC-25 | applies: cells, rows and buttons use the native hover and pressed states, and a disabled Phone button is dimmed neutral, never accent |
| CONV-MAC-26 | applies: one inset (16 pt) and one rhythm across the banner, the grid and the toolbar; helper text (the searching line) sits under what it explains |
| CONV-AND-01 | n/a: no phone navigation from the Deck |
| CONV-AND-02 | n/a: no phone-side UI |
| CONV-AND-03 | n/a: no Android permission is asked from the Deck |
| CONV-AND-04 | applies: opening an app never changes a phone setting; the phone stays locked and its own timeout applies |
| CONV-PD-01 | applies: DECK-17 and the table above (0, 1, 2+; the Deck shows the phone in use and Settings is the way to another) |
| CONV-PD-02 | applies: DECK-14, DECK-15 and the table above (connecting, connected, offline, pair-again, incompatible version) |
| CONV-PD-03 | n/a: the Deck starts no action the phone must confirm — opening an app is a request whose failure is a banner ("Couldn't open *app* on the phone."), and the chip only ever repeats what the link reported |
| CONV-PD-04 | n/a: the Deck has no live slider or toggle |
| CONV-PD-05 | applies: DECK-23 |
| CONV-PD-06 | applies: DECK-5 (the grid's frame p95 limits in NFR.md) and DECK-2/DECK-8 (`app_list_ms`) |
| CONV-PD-07 | applies: "Deck", "Nearby", "Find Apps", "Pair again", "Try now", "Phone" carry one meaning across the Deck, menus, panel and designed docs (DECK-13, DECK-16, DECK-17) |
| CONV-PD-08 | applies: the Link machine (design/mac-redesign.md §4.3, `LinkMachine`) plus the mode/query table above |
| CONV-PD-09 | applies: DECK-15/16 (a banner names the next step), DECK-13 (the Phone button's help tag "Open Phone Mirror"), DECK-11 ("No apps match …" names the query) |

## Assumptions

- The app list and icons are cached per phone in the profile; a launch with a remembered phone therefore has every cell before the first connection (design/mac-redesign.md §3.3 "Data").
- The Deck is a SwiftUI `Window` scene on macOS 26, one window, with AppKit stream windows opened from it.
- The phone in use is the one `activePhoneId` names (settings.md); the Deck never decides that itself.
- Screen sizes: 1280×800 is the smallest supported screen; the Deck's own minimum is 640×420 pt (code, not the doc's 560×420).

## Non-goals

- A phone switcher, an add-phone button or per-phone lists in the Deck: Settings owns phones (settings.md).
- A settings page, a file browser or a media player in the Deck: the panel, Settings, Finder and the media surfaces own those.
- A second launcher window or a floating launcher panel (design/mac-redesign.md §9).
- A wallpaper, a home-screen layout or icon rearrangement: the Deck lists apps, it does not change the phone.
- A help book or an About window of its own (⌘? is the system's About panel from the app menu).

## Open questions

- [NEEDS CLARIFICATION] Should the Deck remember its size and position across launches (CONV-MAC-12)? Recommended: yes, one frame per profile, the way Settings now does (SET-WIN-09); it is a one-window app and people resize it once.
- [NEEDS CLARIFICATION] Is the Deck's ⌘F allowed to stay out of the menus (CONV-MAC-06), with the help tag "Find (⌘F)" on the search field instead? Recommended: yes, keep it out of the menus (a menu item would eat ⌘F in every stream window) and add the help tag.
- [NEEDS CLARIFICATION] The design doc says the Deck's minimum is 560×420 and its rail letters are 9 pt on a 12 pt pitch; the code says 640×420 and 20 pt targets. Recommended: code wins (the 20 pt target is the person's accessibility floor), and the design doc is corrected.
- [NEEDS CLARIFICATION] With two phones, the Deck gives no hint that another phone exists. Recommended: leave it (Settings marks In Use) unless the person wants a row in the title bar; this is a product question, not a bug.
