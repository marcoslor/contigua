# Settings ▸ Devices

Prefix: `SET-DEV`. Owner docs: [UX.md](../UX.md) §4 (Settings), [notify.md](../design/notify.md) (per-phone sharing, click target, muted apps), [phone-mirror.md](../design/phone-mirror.md) (the keep-screen-off option). Last reviewed: 2026-10-27, against build 112 (`ca1b429`).

## Purpose

The one place a person manages the phones this Mac knows: which phone is in use, what each phone is called, and what that phone is allowed to send to this Mac (notifications, Now Playing, muted apps) and how its screen behaves while the Mac holds it off. It sits in the Settings window (⌘,) and is the only surface that edits per-phone settings; the Deck, the menu-bar panel and the windows only *use* the phone that is in use.

Names: this spec renames today's **Use** button to **Use This Phone**, **Forget** to **Forget This Phone…**, **Show notifications + Now Playing** to **Share notifications and Now Playing**, and the click-target sentence to a label with short values (CONV-PD-07, CONV-PD-09). `docs/UX.md` §4 and the shortcuts table are updated in the same change that implements this tab.

## User stories

| ID | Priority | Story |
|---|---|---|
| SET-DEV-S1 | P1 | As a person with one or more paired phones, I want to see all of them and which one is in use, so that I know what the Deck and the panel are showing. |
| SET-DEV-S2 | P1 | As a person with two phones, I want to switch the phone in use from here, so that I do not have to unpair one to use the other. |
| SET-DEV-S3 | P1 | As a person whose phone was just paired, I want to see it here with its name and state, so that I know the Mac actually has it. |
| SET-DEV-S4 | P2 | As a person, I want to rename a phone so that I can tell my two phones apart everywhere the app names them. |
| SET-DEV-S5 | P1 | As a person, I want to forget a phone safely (with a confirmation) so that a half-seen list cannot cost me a pairing. |
| SET-DEV-S6 | P1 | As a person, I want to choose per phone whether its notifications and Now Playing appear on my Mac so that sharing stays opt-in. |
| SET-DEV-S7 | P1 | As a person, I want to choose what a click on a phone notification does so that it opens where I expect. |
| SET-DEV-S8 | P2 | As a person, I want to mute a noisy app by its name and icon, and see how many I muted, so that I do not have to read package names. |
| SET-DEV-S9 | P2 | As a person, I want a power press not to light the phone's screen while the Mac holds it off, so that the phone stays dark on my desk. |
| SET-DEV-S10 | P1 | As a person, I want the tab to make sense with no phone, one phone and several, and while a phone is offline, so that nothing looks broken or lies about the phone. |

## Settings inventory

Every setting this tab binds today, and where it lives. Nothing is dropped.

| Setting | Scope | Store (profile defaults) | Default | What it does | In the menu-bar panel? |
|---|---|---|---|---|---|
| The paired-phone list (name, model, last seen, state) | per phone (read) | `rememberedPhones`, `phoneNicknames`, pins | — | What the tab lists; the one in use is what every other surface acts on | the in-use phone's name and state only |
| Use This Phone | per Mac (which phone) | `activePhoneId` | most recently used | Makes that phone the one the Deck, panel and windows show | indirect: the panel acts on the in-use phone |
| Add Phone… | — (action) | — | — | Opens the app's one add-phone sheet (Deck pairing flow) | no |
| Rename… (nickname) | per phone | `phoneNicknames[deviceId]` | empty: the phone's own name | The one name used everywhere (Deck, panel, titles, notifications, Spotlight, Dock shims, Finder location) | the name is shown; no control |
| Forget | per phone | — (removes the pin and the remembered record) | — | Unpairs this Mac from that phone after a confirmation | no |
| Share notifications and Now Playing | per phone | `notify.<deviceId>` | **off** | Gates notification and media forwarding from that phone; off while the session is live stops it at once | no (the panel shows the forwarded notifications themselves) |
| When I click a notification | per phone | `notify.click.<deviceId>` (`mac`, `phone`, `none`) | `mac` ("Open on this Mac") | What a click on that phone's banner does: open/raise the app window and run its action, run it on the phone's own screen, or only dismiss | no |
| Muted apps | per phone | `notify.mute.<deviceId>` (package list) | empty | Drops that package's notifications on the Mac before they are shown; the muted set stays listed so it can be undone | no |
| Keep the phone screen off until I turn it on from the Mac | per phone | `phonePanelIgnorePower[deviceId]` | **off** | While the Phone Mirror holds the panel off, a power press lights it only until the next keep-alive step; the hold still ends on window close, disconnect or crash, and the phone stays locked | no (the panel's Turn Off Screen starts the hold; this only changes how a power press behaves during it) |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| SET-DEV-01 | THE Devices tab SHALL list every phone this Mac remembers, once each, with the name the rest of the app uses (its nickname, else the phone's own name), its model and its connection state. | untested (this change ships no tab): planned e2e `settings-devices` `[SET-DEV-01]`; names K2 `PhoneNicknamesTests` |
| SET-DEV-02 | THE tab SHALL mark exactly one listed phone as in use, and that mark SHALL follow `activePhoneId`; IF no phone is remembered THEN the tab SHALL show an empty state whose only action is Add Phone…. | untested: planned e2e `settings-devices` `[SET-DEV-02]` |
| SET-DEV-03 | WHEN the person chooses Use This Phone on a phone that is not in use THE Mac SHALL make it the active phone for every surface (Deck, menu-bar panel, windows, notifications, Dock shims) and SHALL move the in-use mark to it. | untested: planned e2e `settings-devices` `[SET-DEV-03]` |
| SET-DEV-04 | (P2) [NEEDS CLARIFICATION] WHEN Use This Phone closes windows that belong to the previous phone THE Mac SHALL say so before it acts (a confirmation naming how many windows close); today it closes them silently (`ConnectionController.use`). | untested: planned e2e `settings-devices` `[SET-DEV-04]` |
| SET-DEV-05 | WHEN the person chooses Add Phone… (in the list or the empty state, or presses ⇧⌘N) THE Mac SHALL open the app's one add-phone sheet; the tab SHALL NOT start a second pairing flow of its own. | untested: planned e2e `settings-devices` `[SET-DEV-05]` |
| SET-DEV-06 | WHEN the person renames a phone THE Mac SHALL store the trimmed nickname (≤ 40 characters, whitespace runs collapsed; empty clears it) and SHALL update that name everywhere at once: Deck title, panel, window titles, notification titles, Spotlight entries, Dock shim names and the Finder location. | K2 `PhoneNicknamesTests` (all cases); e2e `settings-devices` `[SET-DEV-06]` for the dialog and the live retitle |
| SET-DEV-07 | WHEN the person chooses Forget THE tab SHALL ask for confirmation naming the phone and saying the pairing will be removed; only after the person confirms SHALL the Mac remove the pin, the remembered record, the cached apps and icons, the Spotlight entries and the Dock shims, and tell the phone. | untested: planned e2e `settings-devices` `[SET-DEV-07]` |
| SET-DEV-08 | IF the phone in use is forgotten WHILE another phone is remembered THEN the Mac SHALL make the most recently used remaining phone the active one and SHALL switch to it (one session teardown, one connect). | untested: planned e2e `settings-devices` `[SET-DEV-08]` |
| SET-DEV-09 | THE notification-sharing switch SHALL be per phone and off by default; WHEN it is turned on or off WHILE that phone's session is live THE Mac SHALL send the change at once, and SHALL store it for the next session; turning it off SHALL also clear the Mac's Now Playing state for that phone. | K2 `NotifyMacTests.testClickSettingDefaultsToOpenOnMacAndIsStoredPerPhone` (storage shape) and `testMutedSetIsPerPhoneAndSorted`; e2e `notify` (gate); e2e `settings-devices` `[SET-DEV-09]` |
| SET-DEV-10 | THE click-target picker SHALL be per phone, SHALL default to Open on this Mac, and SHALL read forwards: the sentence is the row's label ("When I click a notification") and the choices are its value (Open on this Mac · Open on the phone · Do nothing). WHILE sharing is off THE picker SHALL be disabled with a sentence saying sharing must be turned on. | K2 `NotifyMacTests` (default, mapping, Do nothing); e2e `settings-devices` `[SET-DEV-10]` |
| SET-DEV-11 | THE muted-apps row SHALL show how many apps are muted ("Muted apps: 2", "None" when zero); opening it SHALL list every app that has sent a notification this session plus every already-muted package, each with its icon and app name (the package name only when the app is unknown), searchable, one switch per row aligned in a single trailing column; toggling mute SHALL take effect on the next notification and SHALL be stored per phone. | K2 `NotifyMacTests.testMutedSetIsPerPhoneAndSorted`; K2 `DevicesTabTests` (planned: rows, count, search, unknown-app fallback); e2e `notify-actions` (a muted package is dropped); e2e `settings-devices` `[SET-DEV-11]` |
| SET-DEV-12 | IF no app has sent a notification this session and none is muted THEN the open list SHALL say so in one sentence instead of showing an empty box. | untested: planned K2 `DevicesTabTests.testEmptyMutedList`; e2e `settings-devices` `[SET-DEV-12]` |
| SET-DEV-13 | THE keep-screen-off option SHALL be per phone and off by default; while it is on, a press of the phone's power button SHALL light the screen only until the next keep-alive step re-applies the hold, and every end of the hold (window close, session end, disconnect, crash recovery) SHALL still restore the panel; the phone SHALL stay locked. | K1 `PanelHoldTest` (the hold's transitions); e2e `mirror` (the hold's ends); e2e `settings-devices` `[SET-DEV-13]` |
| SET-DEV-14 | THE tab SHALL show every phone's state as a dot plus words — Connected, Connecting…, Reconnecting…, Offline, Pair again — and SHALL NOT convey any state by colour alone; a phone that is not connected SHALL also show when it was last seen. | untested: planned K2 `DevicesTabTests.testPresenceWords`; e2e `settings-devices` `[SET-DEV-14]` |
| SET-DEV-15 | THE tab SHALL render 0, 1 and 2+ phones: with 0 an empty state and Add Phone…, with 1 that phone's settings, and with 2+ every phone SHALL be reachable from this tab, with the in-use phone clearly marked and the other phones' Use This Phone (or Pair Again…) reachable in at most one click. | untested: planned e2e `settings-devices` `[SET-DEV-15]` (0/1/2+ fixture phones) |
| SET-DEV-16 | WHILE the active phone is offline, connecting or reconnecting THE tab SHALL keep every per-phone setting editable, SHALL store a change, and SHALL NOT claim the phone applied it (the change is sent when the phone connects). | untested: planned e2e `settings-devices` `[SET-DEV-16]` |
| SET-DEV-17 | IF a remembered phone's key is gone THEN its state SHALL read Pair again and the tab SHALL offer Pair Again…, which opens the add-phone sheet; no other control SHALL imply that phone can be reached. | untested: planned e2e `settings-devices` `[SET-DEV-17]` |
| SET-DEV-18 | THE tab SHALL keep every control reachable at the smallest supported screen (1280×800): the window SHALL fit the visible frame and the tab's rows SHALL scroll when they are taller than it. | K2 `SettingsLayoutTests.testSettingsFitsAndScrollsAt1280x800` and `testTheWindowNeverOutgrowsTheScreen`; e2e `chrome` (the Settings window report) |
| SET-DEV-19 | EVERY control SHALL have a VoiceOver label and role; an icon-only button SHALL carry a help tag and a label naming its result; the reading order SHALL be name, state, actions, then the phone's settings. | untested: planned K2 `DevicesTabTests.testEveryControlHasALabel` (AX tree) + review |
| SET-DEV-20 | WHEN ⌘F is pressed WHILE the muted-apps list is open THE tab SHALL focus its search field and select the text already typed; WHILE the list is closed ⌘F SHALL be ignored by this tab. | untested: planned e2e `settings-devices` `[SET-DEV-20]` |
| SET-DEV-21 | WHEN Esc is pressed WHILE the rename or forget dialog is up THE dialog SHALL close without acting; WHILE the muted-apps list is open Esc SHALL close the list without changing any mute. | untested: planned e2e `settings-devices` `[SET-DEV-21]` |
| SET-DEV-22 | THE tab SHALL write no phone name, nickname, app name, package name, notification content or media title to a log or a crash report. | K2 `NotifyMacTests.testRecordsCarrySizesAndPackagesNotText` (the wire's existing redaction); review of the tab's code |
| SET-DEV-23 | THE tab SHALL NOT send anything to a phone that is not connected, and SHALL NOT change a phone-side setting (the lock screen, a screen timeout, an app's enabled state) — the only phone-side effects are the per-phone sharing gate and the panel hold. | e2e `notify` and `mirror` (zero writes/inputs from a read-only view); review |
| SET-DEV-24 | THE tab SHALL NOT put per-phone settings in the menu-bar panel: the panel shows the in-use phone's live state and notifications, and the only per-phone control it may carry is the one it already has (Turn Off Screen's live hold). | review against `docs/UX.md` §3; untested |

Priority note: SET-DEV-01/02/03/05/07/15 are P1 (a person cannot manage phones without them); the per-phone switches are already shipped and stay P1; the new affordances (counts, search, badges, offline copy) are P2.

## States and events

The tab's own state is one selection over a list; every per-phone state is `Link`'s (`macos/Sources/PocketDeck/Link.swift`, and UX.md's "Status/feedback"). `Phones` is derived: `Empty` (0 remembered), `Single` (1), `List` (2+).

| State | Event | Result |
|---|---|---|
| Empty | `open` | empty state, Add Phone… only |
| Empty | `addPhone` | the add-phone sheet opens (state unchanged until a pairing lands) |
| Empty | `paired(phone)` | `Single`, that phone selected and in use |
| Single / List | `paired(phone)` | the list gains the phone, selected and in use |
| Single / List | `select(phone)` | that phone's settings are shown; the in-use phone does not change |
| Single / List | `use(phone)` | if `phone` is not in use: `activePhoneId = phone`, windows of the previous phone close, one session teardown, connect to `phone`; if it is already in use: ignored |
| Single / List | `rename(phone)` | the rename dialog opens with the stored nickname; `save` stores it (SET-DEV-06), `cancel`/Esc changes nothing |
| Single / List | `forget(phone)` | the confirmation dialog opens; `confirm` removes the phone (SET-DEV-07) and, if it was in use and another remains, makes the next one active (SET-DEV-08); `cancel`/Esc changes nothing |
| Single | `forgetConfirmed(last phone)` | `Empty` |
| List | `forgetConfirmed(not in use)` | the list shrinks; selection moves to the in-use phone |
| Any | `linkChanged(active phone)` | that phone's state words update (SET-DEV-14); no other row changes |
| Any | `toggleShare(phone)` | stored; sent when that phone is live (SET-DEV-09) |
| Any | `pickClickTarget(phone)` | ignored while sharing is off (the control is disabled), else stored (SET-DEV-10) |
| Any | `openMuted(phone)` / `closeMuted` | the list opens/closes for that phone; the mute set is unchanged by closing (SET-DEV-21) |
| Any | `typeInMutedSearch` | filters the list by app name or package name; the count and the mute set do not change |
| Any | `toggleMute(pkg)` | ignored while sharing is off (row disabled), else stored for that phone and applied to the next notification (SET-DEV-11) |
| Any | `toggleKeepOff(phone)` | stored for that phone (SET-DEV-13) |

## Phone count and connection

| Situation | The tab shows |
|---|---|
| 0 phones | An empty state that says there are no phones and offers Add Phone… (SET-DEV-02). |
| 1 phone | That phone's name, state, model and last seen; its per-phone settings; Forget alone at the end. |
| 2+ phones | Every phone in one list, the in-use one marked; the in-use phone's settings are visible without switching; any other phone is reachable in one click and can be made the in-use phone with Use This Phone (SET-DEV-15). |
| Connecting | The in-use phone's dot and words: "Connecting…"; its settings remain editable (SET-DEV-16). |
| Connected | "Connected"; last seen reads "now". |
| Offline / reconnecting | "Offline" (or "Reconnecting…") plus "last seen …"; settings stay editable, and no control claims the phone has applied a change (SET-DEV-16). |
| Key gone | "Pair again" and Pair Again…; nothing pretends the phone is reachable (SET-DEV-17). |
| Phone that can't do the feature | The per-phone switches are Mac-side stores, so they stay enabled for any paired phone; a phone that never reports notifications simply sends none. The keep-off option only matters while the Phone Mirror's hold exists; it is not hidden when the phone is offline. |
| No notification-posting app yet | Muted apps opens to a one-sentence empty list (SET-DEV-12). |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: SET-DEV-20 (⌘F focuses the muted-apps search; the tab has no other search field) |
| CONV-MAC-02 | applies: ⌘W/⌥⌘W/⌘M/⌘Q/⌘,/⌘H are the window's and the app's, unchanged; the tab takes none |
| CONV-MAC-03 | applies: SET-DEV-21 (Esc closes the dialogs and the open muted list without acting); Return triggers Rename/Forget in their dialogs; Tab walks the controls in reading order (SET-DEV-19) |
| CONV-MAC-04 | applies: the rename and muted-search fields are standard text fields |
| CONV-MAC-05 | n/a: no zoomable content on this tab |
| CONV-MAC-06 | applies: no new shortcut; ⇧⌘N (Add Phone…) is already in UX.md's table; every icon-only button has a help tag (SET-DEV-19) |
| CONV-MAC-07 | n/a: no shortcut is reused here (⌘P stays Phone Mirror) |
| CONV-MAC-10 | n/a: the tab is not the status-item panel |
| CONV-MAC-11 | applies: ⌘, and the gear open the one Settings window; the tab adds no window of its own |
| CONV-MAC-12 | applies: the Settings window keeps its size rules (SET-DEV-18); the tab never opens a second window |
| CONV-MAC-13 | n/a: the tab adds no menu item or full-screen command |
| CONV-MAC-14 | applies: SET-DEV-18 (no clipping at the minimum; the form scrolls) |
| CONV-MAC-15 | n/a: closing Settings does not quit the app (unchanged); the tab changes nothing |
| CONV-MAC-16 | n/a: no drag/drop, paste or Services on this tab |
| CONV-MAC-20 | applies: dark and light, accent colour and Increase Contrast all render (reviewed from the two appearances' captures) |
| CONV-MAC-21 | applies: SET-DEV-19 |
| CONV-MAC-22 | applies: the tab's only motion is the list/row disclosure; Reduce Motion removes it |
| CONV-MAC-23 | applies: SET-DEV-14 (state is words as well as a dot), SET-DEV-19 (text size follows the system) |
| CONV-MAC-24 | applies: the tab asks for no permission; the phone-side notification grant is the phone's own, asked for there when sharing is turned on |
| CONV-MAC-25 | applies: rows and buttons use the native hover/pressed states; a disabled control is dimmed neutral (the click target and the muted rows while sharing is off) |
| CONV-MAC-26 | applies: one side inset and one vertical rhythm (8/12/16 pt) across the list and the settings; helper text sits under the control it explains |
| CONV-AND-01 | n/a: no phone navigation from this tab |
| CONV-AND-02 | n/a: no phone-side UI on this tab (the phone's own "Share notifications" switch is the phone app's surface) |
| CONV-AND-03 | n/a: the tab asks for no Android permission; a denied listener grant shows on the phone |
| CONV-AND-04 | applies: SET-DEV-23 (nothing changes a phone setting the person did not ask for; the lock screen stays locked) |
| CONV-PD-01 | applies: SET-DEV-15 (0/1/2+ in one list, every phone reachable) |
| CONV-PD-02 | applies: SET-DEV-14 and SET-DEV-16 (connecting/connected/offline/pair-again; settings editable offline; nothing hidden) |
| CONV-PD-03 | applies: SET-DEV-16 (no claim before the phone reports); SET-DEV-09 (the live send is the phone's answer) |
| CONV-PD-04 | n/a: the tab has no live slider or live toggle that follows a phone value |
| CONV-PD-05 | applies: SET-DEV-22. Pre-existing deviation, not changed here: the mute path logs `notify muted pkg=…` (docs/design/notify.md §Logs allows package names; this line's "app list" wording reads stricter) |
| CONV-PD-06 | applies: no new metric — the tab is a form and inherits NFR's limits; it runs no background work and holds no memory of its own, so there is no power or memory budget; a change that moves a frame metric records before/after |
| CONV-PD-07 | applies: SET-DEV-01 (one name per thing: "Devices", "In Use", "Use This Phone", "Add Phone…", "Rename…", "Forget This Phone…", "Muted apps", "Share notifications and Now Playing", "When I click a notification") |
| CONV-PD-08 | applies: the tab's selection/forget/disclosure machine is the table above |
| CONV-PD-09 | applies: SET-DEV-10 (the sentence is the label, the values are the choices), SET-DEV-19 (help tags and full-sentence labels); the empty state names its action |

## Assumptions

- The phone name, model and last-seen time come from the remembered record; the app names and icons in the muted list come from the app list this Mac already caches per phone.
- The notification gate is the phone's own listener grant (asked for on the phone) plus this Mac's per-phone switch; the Mac never asks for an Android permission.
- macOS 26 / SwiftUI Settings idioms; settings live in the active profile's `UserDefaults` suite, never in the person's default domain.
- A phone that has never reported notifications has no muted apps to offer; the list may be empty (SET-DEV-12).

## Non-goals

- Editing a *second* phone's notifications while the first is mirrored: the per-phone settings are stored and take effect the next time that phone is live; nothing connects to a phone from this tab.
- A phone-side settings editor (the phone app's own switches), per-app notification sound/importance, or a bulk "forget all".
- Pairing itself: the tab opens the add-phone sheet; pairing stays the Deck's flow.
- Showing notification *content* or an app list in the tab beyond the muted list's names and icons.
- Reordering the phone list by hand (most recently used decides the order).

## Open questions

- [NEEDS CLARIFICATION] SET-DEV-04: does Use This Phone ask before it closes the previous phone's windows (recommended: yes, when any are open), or close them silently as it does today?
- [NEEDS CLARIFICATION] The muted list's contents: apps seen this session only (today) or every app the phone has (recommended: the app list this Mac already has, with a mark for the ones that have sent something), so the list is usable right after launch?
- [NEEDS CLARIFICATION] Window width: the sidebar option needs a wider Settings window (≈640 pt vs today's 480). Accept a wider Settings window for all tabs, or keep 480 and rule out the sidebar?
- [NEEDS CLARIFICATION] Per-phone settings for a phone that is not in use: keep them editable here (recommended; they apply on its next connection), or only show them for the in-use phone?
- [NEEDS CLARIFICATION] Where Add Phone… lives: one row under the list for every option (recommended), or a "+" at the end of a sidebar only.
