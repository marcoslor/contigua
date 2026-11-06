# Settings

Prefix: `SET-WIN` (the window and its sidebar) and `SET-DEV` (a phone's page). Owner docs: [UX.md](../UX.md) §4 (Settings), [notify.md](../design/notify.md) (per-phone sharing, click target, muted apps), [phone-mirror.md](../design/phone-mirror.md) (the keep-screen-off option). Last reviewed: 2026-10-27, against build 114.

## Purpose

The one place a person manages this Mac's phones and the app's Mac-wide settings. Settings (⌘,; the gear; the panel's Settings…) is a System Settings–style window: a source list with this Mac's phones first — every phone this Mac remembers, which one is in use, what each is called — and the Mac's own sections (General, Input, Automation) below it. Choosing a phone opens its page in the detail column, and that page is the only surface that edits per-phone settings; the Deck, the menu-bar panel and the windows only *use* the phone that is in use.

Phones are peers: everything per phone is keyed by its device id and its page names it once, in the page header and the window title — never in a section heading. The Mac keeps one current phone (the In Use mark and Use This Phone) and one connection per phone, so the window must not assume one live connection.

Everything that belongs to one phone lives in `PhoneSettingsPage(deviceId:)` (macOS `PhoneSettingsPage.swift`): its header (icon, name, state, Use This Phone / Pair Again…), the Phone section (model, Rename…), Notifications with Muted apps, the Screen option and Forget. The page reads and writes only that phone's stores, so its host (today the sidebar's detail column) can change without changing the page.

Names: **Use This Phone**, **Forget This Phone…**, **Share notifications and Now Playing**, "When I click a notification" with its value on the right (CONV-PD-07, CONV-PD-09). `docs/UX.md` §4 and the shortcuts table are updated with this spec.

## User stories

| ID | Priority | Story |
|---|---|---|
| SET-WIN-S1 | P1 | As a person, I want the Settings window to lead with my phones, so that the thing I came for is one click away. |
| SET-WIN-S2 | P1 | As a person, I want the Mac-wide settings in the same window, so that I do not hunt through tabs. |
| SET-WIN-S3 | P1 | As a person, I want ⌘, to open where I left off, so that changing a phone's setting twice is one trip. |
| SET-DEV-S1 | P1 | As a person with one or more paired phones, I want to see all of them and which one is in use, so that I know what the Deck and the panel are showing. |
| SET-DEV-S2 | P1 | As a person with two phones, I want to switch the phone in use from here, so that I do not have to unpair one to use the other. |
| SET-DEV-S3 | P1 | As a person whose phone was just paired, I want to see it here with its name and state, so that I know the Mac actually has it. |
| SET-DEV-S4 | P2 | As a person, I want to rename a phone so that I can tell my two phones apart everywhere the app names them. |
| SET-DEV-S5 | P1 | As a person, I want to forget a phone safely (with a confirmation) so that a half-seen list cannot cost me a pairing. |
| SET-DEV-S6 | P1 | As a person, I want to choose per phone whether its notifications and Now Playing appear on my Mac so that sharing stays opt-in. |
| SET-DEV-S7 | P1 | As a person, I want to choose what a click on a phone notification does so that it opens where I expect. |
| SET-DEV-S8 | P2 | As a person, I want to mute a noisy app by its name and icon, and see how many I muted, so that I do not have to read package names. |
| SET-DEV-S9 | P2 | As a person, I want a power press not to light the phone's screen while the Mac holds it off, so that the phone stays dark on my desk. |
| SET-DEV-S10 | P1 | As a person, I want the window to make sense with no phone, one phone and several, and while a phone is offline, so that nothing looks broken or lies about the phone. |

## Settings inventory

Every setting this window binds today, and where it lives. Nothing is dropped.

| Setting | Scope | Store (profile defaults) | Default | What it does | In the menu-bar panel? |
|---|---|---|---|---|---|
| The sidebar's selection | per profile | `settings.selection` | the phone in use, else the first phone, else General | Which page the window shows; ⌘, reopens it | no |
| The paired-phone list (name, model, last seen, state) | per phone (read) | `rememberedPhones`, `phoneNicknames`, pins | — | The sidebar's Phones group; the one in use is what every other surface acts on | the in-use phone's name and state only |
| Use This Phone | per Mac (which phone) | `activePhoneId` | most recently used | Makes that phone the one the Deck, panel and windows show | indirect: the panel acts on the in-use phone |
| Add Phone… | — (action) | — | — | Opens the app's one add-phone sheet (Deck pairing flow); the page does not change | no |
| Rename… (nickname) | per phone | `phoneNicknames[deviceId]` | empty: the phone's own name | The one name used everywhere (Deck, panel, titles, notifications, Spotlight, Dock shims, Finder location) | the name is shown; no control |
| Forget This Phone… | per phone | — (removes the pin and the remembered record) | — | Unpairs this Mac from that phone after a confirmation | no |
| Share notifications and Now Playing | per phone | `notify.<deviceId>` | **off** | The only person-facing notification switch: gates notification and media forwarding from that phone; off while the session is live stops it at once. The phone's listener grant must also be granted (its own row below). | no (the panel shows the forwarded notifications themselves) |
| When I click a notification | per phone | `notify.click.<deviceId>` (`mac`, `phone`, `none`) | `mac` ("Open on this Mac") | What a click on that phone's banner does: open/raise the app window and run its action, run it on the phone's own screen, or only dismiss | no |
| Muted apps | per phone | `notify.mute.<deviceId>` (package list) | empty | Drops that package's notifications on the Mac before they are shown; the muted set stays listed so it can be undone | no |
| Keep the phone screen off until I turn it on from the Mac | per phone | `phonePanelIgnorePower[deviceId]` | **off** | While the Phone Mirror holds the panel off, a power press lights it only until the next keep-alive step; the hold still ends on window close, disconnect or crash, and the phone stays locked | no (the panel's Turn Off Screen starts the hold; this only changes how a power press behaves during it) |
| Save all apps as shortcuts | per phone | `saveAllAppsAsShortcuts[deviceId]` | **off** | Gives every app of that phone a real Mac app in Applications (listed by Launchpad, Spotlight and other launchers); off removes only the shortcuts the switch made, and a shim the Dock or the person keeps stays | no |
| Notification access (phone-side) | per phone (system grant) | Android `enabled_notification_listeners` for `PdNotificationListener` | **off** | What lets the phone honour the Mac's switch. The phone asks once at shell UID when sharing turns on; a failed grant is shown on both sides, and a later grant starts forwarding by itself | no |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| SET-WIN-01 | THE Settings window SHALL show a source-list sidebar whose first group is Phones — one row per remembered phone, then Add Phone… — and whose second group is This Mac with General, Input and Automation; WHEN the person chooses a row THE detail column SHALL show that page. | K2 `SettingsSidebarTests` (group order, rows, five phones); e2e `settings` `[SET-WIN-01]` (the rows and the page) |
| SET-WIN-02 | IF no phone is remembered THEN the window SHALL open General and the Phones group SHALL say "No phones yet." with Add Phone…; WHEN the person chooses Add Phone… THE Mac SHALL open the app's one add-phone sheet and the page SHALL NOT change. | K2 `SettingsSidebarTests.testAddPhoneOpensTheSheetWithoutMovingTheSelection`, `testPhonesComeFirst…` (the sentence); e2e `settings` `[SET-WIN-02]` (0 phones; the sheet opens, the page does not move) |
| SET-WIN-03 | WHEN the window opens THE window SHALL select the page stored for this profile; IF none is stored THEN the phone in use, else the first remembered phone, else General; WHEN a row is chosen THE detail SHALL show that page and the window title SHALL be that page's name. | K2 `SettingsSidebarTests` (every open/choose transition); e2e `settings` `[SET-WIN-03]` (0/1/3 phones, the title) |
| SET-WIN-04 | THE selection SHALL be stored in the profile's defaults, so that ⌘, and a relaunch reopen the last page; another profile SHALL start from its own value. | K2 `SettingsSidebarTests` (round trip, another profile); e2e `settings` `[SET-WIN-04]` (a relaunch reopens Pixel 9) |
| SET-WIN-05 | WHEN the person confirms Forget This Phone… for the open page's phone THE window SHALL select the phone in use, else the first remaining phone, else General. | K2 `SettingsSidebarTests.testForgettingTheOpenPhone…`; e2e `settings` `[SET-WIN-05]` (after the confirmation the in-use phone's page is open) |
| SET-WIN-06 | A phone's page SHALL show a header with its icon, its name, a dot plus the state's words, when it was last seen while it is not connected, the In Use mark, and Use This Phone (Pair Again… when its key is gone); every section heading SHALL be plain — Phone, Notifications, Applications, Screen, Forget — and SHALL NOT contain the phone's name, which SHALL appear only in the header and the window title. | K2 `SettingsSidebarTests.testSectionHeadingsArePlainAndNeverCarryThePhoneName` (no heading contains a phone name), `testTheWindowTitleIsTheOpenPagesName`; e2e `settings` `[SET-WIN-06]` (the title, the header's state/action, the five plain headings) |
| SET-WIN-07 | THE window SHALL be 720×560 pt (a 240 pt sidebar and a 480 pt detail) and SHALL fit a 1280×800 screen with the menu bar; a page taller than the window SHALL scroll and its last control SHALL be reachable. | K2 `LayoutTests.testEverySettingsPageFitsAndScrollsAtTheSmallestScreen`, `SettingsSidebarTests.testTheWindowIs720WideAndFitsTheSmallestScreen`; e2e `settings` (geometry) and `chrome` `C14 Settings` (720 pt, fits, scrolls, last row reachable) |
| SET-WIN-08 | WHEN the window opens THE sidebar SHALL have the keyboard; ↑/↓ SHALL move the selection between its rows; Tab SHALL move the keyboard into the detail. | e2e `settings` `[SET-WIN-08]` (real ↓/↑/Tab events through the app's key dispatch; the window reports where the keyboard is) |
| SET-WIN-09 | WHEN the window opens with no saved frame THE window SHALL open centred on the screen holding the key window (the main screen when there is none); WHEN it opens with a saved frame that is still on a screen THE window SHALL open at that origin, pushed inside the screen when it is only partly off; IF the saved frame is on no screen (a display went away) THEN the window SHALL open centred; moving the window SHALL be remembered for the next open and for a relaunch, one origin per profile; the window SHALL keep its size rules (SET-WIN-07) and SHALL NOT be moved again while it is up. | K2 `SettingsPlacementTests` (centred with no saved frame, kept on its screen, kept on a second screen, centred off every screen, pushed inside when partly off, the stored value per profile); e2e `settings` `[SET-WIN-09]` (fresh profile centred within 2 pt, moved through AX, ⌘W then reopen, relaunch) |
| SET-DEV-01 | THE Phones group SHALL list every phone this Mac remembers, once each, with the name the rest of the app uses (its nickname, else the phone's own name), its model, its connection state and, while it is not connected, when it was last seen. | K2 `DevicesTabTests` (rows, presence, last seen); e2e `settings` `[SET-DEV-01]` (1 and 3 phones); names K2 `PhoneNicknamesTests` |
| SET-DEV-02 | THE sidebar SHALL mark exactly one listed phone as in use, and that mark SHALL follow `activePhoneId`. | K2 `DevicesTabTests` (the in-use row); e2e `settings` `[SET-DEV-02]` (one mark of three) |
| SET-DEV-03 | WHEN the person chooses Use This Phone on a phone that is not in use THE Mac SHALL make it the current phone for the surfaces that name no phone (the Deck, the menu-bar panel and the actions without a target), SHALL close the previous current phone's windows, and SHALL move the in-use mark to it; it SHALL keep the previous phone's session only while another claim names it and SHALL close it when none does. | K2 `LinkMachineTests.testActivateConnectsToTheOtherPhone`, `PhoneBookTests.testSwitchingKeepsTheOtherSessionRunning`, `PhoneBookTests.testSwitchingClosesAPreviousPhoneNothingNames`; review of the button (`ConnectionController.use`) |
| SET-DEV-05 | WHEN the person chooses Add Phone… (the sidebar row, ⇧⌘N or the Deck) THE Mac SHALL open the app's one add-phone sheet; the window SHALL NOT start a second pairing flow of its own. | review (the row runs the Deck's one add-phone route, `DeckWindow.show` + `sheet = .addPhone`); e2e `settings` `[SET-WIN-02]` opens that sheet |
| SET-DEV-06 | WHEN the person renames a phone THE Mac SHALL store the trimmed nickname (≤ 40 characters, whitespace runs collapsed; empty clears it) and SHALL update that name everywhere at once: Deck title, panel, window titles, notification titles, Spotlight entries, Dock shim names and the Finder location. | K2 `PhoneNicknamesTests` (all cases); e2e `nickname` (the live retitle and shim rebuild); review of the dialog |
| SET-DEV-07 | WHEN the person chooses Forget This Phone… THE page SHALL ask for confirmation naming the phone and saying the pairing will be removed; only after the person confirms SHALL the Mac remove the pin, the remembered record, the cached apps and icons, the Spotlight entries and the Dock shims, and tell the phone. | e2e `settings` `[SET-DEV-07]` (a fixture phone: the confirmation names it, Esc keeps its row and pin, confirming removes both); review of `ConnectionController.forget` |
| SET-DEV-08 | IF the phone in use is forgotten WHILE another phone is remembered THEN the Mac SHALL close the forgotten phone's session only and SHALL make the most recently used remaining phone the current one, connecting to it if it has no live session. | K2 `LinkMachineTests` (the forget/activate transitions), `PhoneBookTests.testForgettingTheCurrentPhoneLeavesAnotherSessionRunning`; review of `ConnectionController.forget` |
| SET-DEV-09 | THE notification-sharing switch SHALL exist only on the Mac, be per phone and off by default; the phone SHALL have no second switch. WHEN it is turned on or off WHILE that phone's session is live THE Mac SHALL send the change at once, and SHALL store it for the next session; turning it off SHALL also clear the Mac's Now Playing state for that phone. WHEN it is turned on and the phone's listener is not granted THE phone SHALL make one shell-UID grant attempt; IF that fails THEN the phone SHALL answer `notify.state {on:false, reason:"no_access"}`, its home SHALL show a Notification access attention item that opens the system's notification-access settings, and the Mac's page SHALL say "Allow notification access on the phone." under the switch; a later grant SHALL turn forwarding on without another Mac toggle. A stored value from an older install SHALL be ignored, never migrated to on. | K1 `NotifyGateTest` (truth table, reply), `NotifySessionTest` (no_access, later grant, revoked grant), `UiStateTest` (attention); K2 `DevicesTabTests` (the hint); e2e `settings` `[SET-DEV-09]` (the hint against a fake phone with no access); e2e `notify` (the gate) |
| SET-DEV-10 | THE click-target picker SHALL be per phone, SHALL default to Open on this Mac, and SHALL read forwards: the sentence is the row's label ("When I click a notification") and the choices are its value (Open on this Mac · Open on the phone · Do nothing). WHILE sharing is off THE picker SHALL be disabled with a sentence saying sharing must be turned on. | K2 `NotifyMacTests` (default, mapping, Do nothing); K2 `DevicesTabTests` (the label); e2e `settings` `[SET-DEV-10]`; e2e `notify` (the three targets) |
| SET-DEV-11 | THE muted-apps row SHALL show how many apps are muted in its row ("2", "None" when zero); opening it SHALL list every app this Mac has cached for that phone plus every package seen this session or already muted, each with its icon and name, searchable, muted apps first, one trailing "Muted" checkbox column under a "Muted" column header; a system package SHALL get a friendly name with its package name underneath, and an unknown app SHALL show its package name; an app that has sent a notification this session SHALL carry a mark; toggling mute SHALL take effect on the next notification and SHALL be stored per phone. | K2 `DevicesTabTests` (count, rows, order, search, unknown fallback, system names, seen mark, labels); K2 `NotifyMacTests.testMutedSetIsPerPhoneAndSorted`; e2e `settings` `[SET-DEV-11]`; e2e `notify-actions` (a muted package is dropped) |
| SET-DEV-12 | IF the open list has no apps to offer (nothing cached for the phone, nothing seen and nothing muted) THEN it SHALL say so in one sentence instead of showing an empty box. | K2 `DevicesTabTests` (the count text); review of the empty-list sentence |
| SET-DEV-13 | THE keep-screen-off option SHALL be per phone and off by default; while it is on, a press of the phone's power button SHALL light the screen only until the next keep-alive step re-applies the hold, and every end of the hold (window close, session end, disconnect, crash recovery) SHALL still restore the panel; the phone SHALL stay locked. | K1 `PanelHoldTest` (the hold's transitions); e2e `mirror` (the hold's ends) |
| SET-DEV-14 | THE sidebar SHALL show every phone's state as a dot plus words — Connected, Connecting…, Reconnecting…, Offline, Pair again — and SHALL NOT convey any state by colour alone; a phone that is not connected SHALL also show when it was last seen. | K2 `DevicesTabTests` (presence words); e2e `settings` `[SET-DEV-14]` (offline and pair-again rows and headers) |
| SET-DEV-15 | THE window SHALL render 0, 1 and 2+ phones: with 0 General is open and the Phones group offers Add Phone…; with 2+ every phone SHALL be one row in the sidebar, the in-use one marked, and any other phone's page SHALL be one click away, with Use This Phone (or Pair Again…) in its header. | K2 `SettingsSidebarTests` (0/1/5 phones); e2e `settings` `[SET-DEV-15]` (0/1/3 fixture phones) |
| SET-DEV-16 | WHILE the active phone is offline, connecting or reconnecting THE page SHALL keep every per-phone setting editable, SHALL store a change, and SHALL NOT claim the phone applied it (the change is sent when the phone connects). | e2e `settings` `[SET-DEV-16]` (offline fixture, the header and settings still shown); review of `notifySettingChanged` |
| SET-DEV-17 | IF a remembered phone's key is gone THEN its state SHALL read Pair again and the page header SHALL offer Pair Again…, which opens the add-phone sheet; no other control SHALL imply that phone can be reached. | K2 `DevicesTabTests` (the pair-again row); e2e `settings` `[SET-DEV-17]` (the header's action) |
| SET-DEV-18 | THE page SHALL keep every control reachable at the smallest supported screen (1280×800): the window SHALL fit the visible frame and the page SHALL scroll when it is taller than it. | K2 `LayoutTests.testEverySettingsPageFitsAndScrollsAtTheSmallestScreen`; e2e `chrome` `C14 Settings` (the window's report) |
| SET-DEV-19 | EVERY control SHALL have a VoiceOver label and role; an icon-only control SHALL carry a help tag and a label naming its result; a sidebar row SHALL read its name, state, last-seen time and in-use mark, and the page's reading order SHALL be header, name/state/actions, then the sections. | K2 `DevicesTabTests` (the row labels), `SettingsSidebarTests.testVoiceOverLabels…`; review of every control's accessibility label, role and help tag |
| SET-DEV-20 | WHEN ⌘F is pressed WHILE the muted-apps list is open THE page SHALL focus its search field and select the text already typed; WHILE the list is closed ⌘F SHALL be ignored by this window, and a stream window's ⌘F SHALL still belong to the phone. | e2e `settings` `[SET-DEV-20]` (a real ⌘F through the app's key dispatch); e2e `deck` (a stream window keeps its ⌘F) |
| SET-DEV-21 | WHEN Esc is pressed WHILE the rename or forget dialog is up THE dialog SHALL close without acting; WHILE the muted-apps list is open Esc SHALL close the list without changing any mute. | e2e `settings` `[SET-DEV-07]` (Esc on the Forget confirmation) and `[SET-DEV-21]` (the list); review of the rename dialog |
| SET-DEV-22 | THE window SHALL write no phone name, nickname, app name, package name, notification content or media title to a log or a crash report. | K2 `NotifyMacTests.testRecordsCarrySizesAndPackagesNotText` (the wire's existing redaction); review of the window's code |
| SET-DEV-23 | THE window SHALL NOT send anything to a phone that is not connected, and SHALL NOT change a phone-side setting (the lock screen, a screen timeout, an app's enabled state) — the only phone-side effects are the per-phone sharing gate and the panel hold. | e2e `notify` and `mirror` (zero writes/inputs from a read-only view); review |
| SET-DEV-24 | THE window SHALL NOT put per-phone settings in the menu-bar panel: the panel shows the in-use phone's live state and notifications, and the only per-phone control it may carry is the one it already has (Turn Off Screen's live hold). | review against `docs/UX.md` §3 |
| SET-DEV-25 | THE Applications section SHALL offer "Save all apps as shortcuts", per phone, off by default and stored per phone id; WHEN it is turned on WHILE that phone's app list is known THE Mac SHALL give every app of the phone the `all` reason and build its shortcut with the Dock's 1296 px icon, at most four icon requests in flight; WHEN it is turned off THE Mac SHALL remove only `all`, keeping a shim the Dock or the person added; the switch SHALL stay editable while the phone is offline and apply at its next app list. | K2 `DockAppsTests.testSaveAllPlanIsOnEveryAppOffOnlyAll`, `testSaveAllSettingIsPerPhoneAndOffByDefault`; e2e `settings` (the switch's report), `shortcuts` `[SET-DEV-25]` (40 apps on, two kept off) |

Priority note: SET-WIN-01/02/03/04/07/08 and SET-DEV-01/02/03/05/07/15 are P1 (a person cannot manage phones without them); the per-phone switches stay P1; the new affordances (counts, search, badges, offline copy) are P2.

## States and events

The window's own state is one selection over its pages (`SettingsSelection` in macOS `SettingsSelection.swift`): `General`, `Input`, `Automation`, or `phone(id)`. One pure transition function takes an event and returns the new selection plus the actions the window performs (open the add sheet, store the selection).

| State | Event | Result |
|---|---|---|
| any | `open` | the page stored for this profile, if it still exists; else `phone(in use)`, else `phone(first)`, else `General`; store it |
| any | `choose(page)` | that page (store it); a phone that is not remembered is ignored; choosing the same page stores nothing |
| any | `addPhone` | the selection does not move; the add-phone sheet opens |
| any | `phonesChanged` | the page stays while its phone exists; else `phone(in use)`, else `phone(first)`, else `General` |
| `phone(id)` | `forgot(id)` | `phone(in use)`, else `phone(first)`, else `General` |
| other than `phone(id)` | `forgot(other)` | the page stays |

A phone's page is the shipped `PhoneSettingsPage`: its header (state, last seen, In Use, Use This Phone / Pair Again…), then the sections of the table below. Every per-phone state is `Link`'s (`macOS/Sources/PocketDeck/Link.swift`, and UX.md's "Status/feedback").

| State | Event | Result |
|---|---|---|
| Empty (0 phones) | `open` | `General`; the Phones group says "No phones yet." with Add Phone… |
| Empty | `paired(phone)` | the list gains the phone, selected if nothing else was |
| Single / List | `select(phone)` | that phone's page is shown; the in-use phone does not change |
| Single / List | `use(phone)` | if `phone` is not in use: `activePhoneId = phone`, the previous current phone's windows close, the previous phone's session stays only while another claim names it and closes when none does, connect to `phone` only if it has no live session; if it is already in use: ignored |
| Single / List | `rename(phone)` | the rename dialog opens with the stored nickname; `save` stores it (SET-DEV-06), `cancel`/Esc changes nothing |
| Single / List | `forget(phone)` | the confirmation dialog opens; `confirm` removes the phone (SET-DEV-07) and, if it is the open page and another remains, selects the next phone (SET-WIN-05); `cancel`/Esc changes nothing |
| Any | `linkChanged(active phone)` | that phone's state words update (SET-DEV-14); no other row changes |
| Any | `toggleShare(phone)` | stored; sent when that phone is live (SET-DEV-09) |
| Any | `listenerGrantFailed(phone)` | the phone answers `no_access`, its home shows the attention item, and the Mac's page shows the hint (SET-DEV-09) |
| Any | `listenerGranted(phone)` | forwarding turns on without another Mac toggle; the hint goes away (SET-DEV-09) |
| Any | `pickClickTarget(phone)` | ignored while sharing is off (the control is disabled), else stored (SET-DEV-10) |
| Any | `openMuted(phone)` / `closeMuted` | the list opens/closes for that phone; the mute set is unchanged by closing (SET-DEV-21) |
| Any | `typeInMutedSearch` | filters the list by app name or package name; the count and the mute set do not change |
| Any | `toggleMute(pkg)` | ignored while sharing is off (row disabled), else stored for that phone and applied to the next notification (SET-DEV-11) |
| Any | `toggleKeepOff(phone)` | stored for that phone (SET-DEV-13) |

The window's own placement is a second, small machine (`SettingsPlacement` in macOS `SettingsPlacement.swift` and the tag's coordinator): one placement per open, then nothing until the person moves the window or closes it.

| State | Event | Result |
|---|---|---|
| Closed | `open()` | placed once: the saved origin when it is on a screen, else centred on the screen holding the key window (SET-WIN-09) |
| Open, placing | `shown` | the size rules applied and the origin set in one frame change; → Placed |
| Placed | `moved` | the origin is stored (once the drag settles); the window is not moved |
| Placed | `closed` | the origin is stored; → Closed |
| Closed | `screens changed` (a display went away) | the next `open()` finds the saved origin on no screen and centres instead |

## Phone count and connection

| Situation | The window shows |
|---|---|
| 0 phones | General is open; the Phones group says there are no phones and offers Add Phone… (SET-WIN-02). |
| 1 phone | Its row in the sidebar (name, state, model and last seen) and its page: the header, then Notifications, Screen and Forget. |
| 2+ phones | Every phone is one row; the in-use one is marked; one phone's page is open at a time (the in-use one by default, else the last one opened) and every other phone is one click away. |
| Connecting | The in-use phone's dot and words: "Connecting…"; its settings remain editable (SET-DEV-16). |
| Connected | "Connected"; last seen reads "now". |
| Offline / reconnecting | "Offline" (or "Reconnecting…") plus "last seen …"; settings stay editable, and no control claims the phone has applied a change (SET-DEV-16). |
| Key gone | "Pair again" and Pair Again… in the page header; nothing pretends the phone is reachable (SET-DEV-17). |
| Missing listener grant | The phone's own home shows "Notification access is off" with an Allow button; the Mac's page shows "Allow notification access on the phone." under the sharing switch; a later grant starts forwarding (SET-DEV-09). |
| Phone that can't do the feature | The per-phone switches are Mac-side stores, so they stay enabled for any paired phone; a phone that never reports notifications simply sends none. The keep-off option only matters while the Phone Mirror's hold exists; it is not hidden when the phone is offline. |
| No app list yet | Muted apps opens to a one-sentence empty list (SET-DEV-12). |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: SET-DEV-20 (⌘F focuses the muted-apps search; the window has no other search field) |
| CONV-MAC-02 | applies: ⌘W/⌥⌘W/⌘M/⌘Q/⌘,/⌘H are the window's and the app's, unchanged; the window takes none |
| CONV-MAC-03 | applies: SET-DEV-21 (Esc closes the dialogs and the open muted list without acting); Return triggers Rename/Forget in their dialogs; SET-WIN-08 (↑/↓ walk the sidebar; Tab leaves it for the detail) |
| CONV-MAC-04 | applies: the rename and muted-search fields are standard text fields |
| CONV-MAC-05 | n/a: no zoomable content in this window |
| CONV-MAC-06 | applies: no new shortcut; ⇧⌘N (Add Phone…) is already in UX.md's table; every icon-only control has a help tag (SET-DEV-19) |
| CONV-MAC-07 | n/a: no shortcut is reused here (⌘P stays Phone Mirror) |
| CONV-MAC-10 | n/a: the window is not the status-item panel |
| CONV-MAC-11 | applies: ⌘, and the gear open the one Settings window; the window adds no window of its own (SET-WIN-03) |
| CONV-MAC-12 | applies: SET-WIN-09 (the window opens centred, remembers where it was moved and never opens off-screen) and SET-WIN-07 (its size rules); it never opens a second window |
| CONV-MAC-13 | n/a: the window adds no menu item or full-screen command |
| CONV-MAC-14 | applies: SET-WIN-07 (no clipping at the minimum; the page scrolls) |
| CONV-MAC-15 | n/a: closing Settings does not quit the app (unchanged); the window changes nothing |
| CONV-MAC-16 | n/a: no drag/drop, paste or Services in this window |
| CONV-MAC-20 | applies: dark and light, accent colour and Increase Contrast all render (reviewed from the two appearances' captures) |
| CONV-MAC-21 | applies: SET-DEV-19 |
| CONV-MAC-22 | applies: the window's only motion is the list's row disclosure; Reduce Motion removes it |
| CONV-MAC-23 | applies: SET-DEV-14 (state is words as well as a dot), SET-DEV-19 (text size follows the system) |
| CONV-MAC-24 | applies: the window asks for no permission; the phone-side notification grant is the phone's own, asked for at shell UID when sharing is turned on (or in the system settings the phone's attention item opens) |
| CONV-MAC-25 | applies: rows and buttons use the native hover/pressed states; a disabled control is dimmed neutral (the click target and the muted rows while sharing is off) |
| CONV-MAC-26 | applies: one side inset and one vertical rhythm (8/12/16 pt) across the sidebar and the page; helper text sits under the control it explains |
| CONV-AND-01 | n/a: no phone navigation from this window |
| CONV-AND-02 | applies: the phone's own "Share notifications and Now Playing" switch is gone; its only surface for this feature is the "Notification access is off" attention item, which opens the system's notification-access settings (SET-DEV-09) |
| CONV-AND-03 | n/a: the window asks for no Android permission; a denied listener grant shows on the phone and in the page's row |
| CONV-AND-04 | applies: SET-DEV-23 (nothing changes a phone setting the person did not ask for; the lock screen stays locked) |
| CONV-PD-01 | applies: SET-DEV-15 and SET-WIN-03 (0/1/2+ in one window, every phone one row away) |
| CONV-PD-02 | applies: SET-DEV-14 and SET-DEV-16 (connecting/connected/offline/pair-again; settings editable offline; nothing hidden) |
| CONV-PD-03 | applies: SET-DEV-16 (no claim before the phone reports); SET-DEV-09 (the live send is the phone's answer) |
| CONV-PD-04 | n/a: the page has no live slider or live toggle that follows a phone value |
| CONV-PD-05 | applies: SET-DEV-22. Pre-existing deviation, not changed here: the mute path logs `notify muted pkg=…` (docs/design/notify.md §Logs allows package names; this line's "app list" wording reads stricter) |
| CONV-PD-06 | applies: no new metric — the window is a form and inherits NFR's limits; it runs no background work and holds no memory of its own, so there is no power or memory budget; a change that moves a frame metric records before/after |
| CONV-PD-07 | applies: SET-WIN-06 (one name per thing: the page's headings are plain, the phone's name appears in the header and the title), SET-DEV-01 (the row's name), and "Phones", "In Use", "Use This Phone", "Add Phone…", "Rename…", "Forget This Phone…", "Muted apps", "Share notifications and Now Playing", "When I click a notification" |
| CONV-PD-08 | applies: the window's selection/forget/disclosure machine is the table above |
| CONV-PD-09 | applies: SET-DEV-10 (the sentence is the label, the values are the choices), SET-WIN-02 (the empty state names its action), SET-DEV-19 (help tags and full-sentence labels) |

## Assumptions

- The phone name, model and last-seen time come from the remembered record; the app names and icons in the muted list come from the app list this Mac already caches per phone.
- The Mac never asks for an Android permission: the Mac's switch asks, and the phone either grants its own listener access or shows the attention item.
- macOS 26 / SwiftUI Settings idioms; settings live in the active profile's `UserDefaults` suite, never in the person's default domain. The window's selection is one of those keys.
- A phone that has never reported an app list has nothing to offer in the muted list beyond what is seen or already muted (SET-DEV-12).

## Non-goals

- Several phone pages open at once: one phone's page is shown at a time, and Use This Phone switches the current phone and connects it only if it has no live session (SET-DEV-03); every other connection is automatic. The per-phone settings are stored and take effect the next time that phone is live.
- A phone-side settings editor, per-app notification sound/importance, or a bulk "forget all".
- Pairing itself: the window opens the add-phone sheet; pairing stays the Deck's flow.
- Several windows, one per phone, or a tab per section: the sidebar is the only navigation.
- Showing notification *content* or an app list beyond the muted list's names and icons.
- Reordering the phone list by hand (most recently used decides the order).
- A search field over the sidebar (a long phone list scrolls until it is asked for).

## Open

- Several phones connected at once is planned; the sidebar must not block it (each phone's page is keyed by device id and the window has no "the phone" state).
- A long phone list scrolls; a sidebar search or a pinned This Mac group is a later change if people ask.
- `SET-DEV-04` (a confirmation before Use This Phone closes the previous phone's windows) was deleted on 2026-10-27: phones are peers and switching is not destructive.
