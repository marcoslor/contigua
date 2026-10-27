# Phone app

Prefix: `PHONE`. Owner docs: [UX.md](../UX.md) § "Android app", [DESIGN.md](../DESIGN.md) §2–3, [PROTOCOL.md](../PROTOCOL.md) § "Transport", § "Phone screen" and § "Ring", [design/phone-mirror.md](../design/phone-mirror.md) (the panel hold), [design/notify.md](../design/notify.md) (the listener grant). Last reviewed: 2026-10-27, against main `12f9d7a`.

## Purpose

The Android app as a person sees it on the phone: one home screen that says whether this phone is reachable and why not, three switches, the Macs it trusts, the pairing prompt (a notification and, in the foreground, a floating card), the permissions it needs, the foreground service that keeps it reachable with its ongoing notification, and what "Turn Off Phone Screen" looks like from the phone's side — a dark screen that stays locked. The onboarding pager's copy and the pairing flows are UX.md's and pairing.md's (`PAIR-6`, `PAIR-16`); the Mac's side of every conversation is deck.md, settings.md, panel.md or phone-mirror.md. This spec owns the phone's own surfaces and answers the Android conventions here in full.

## User stories

| ID | Priority | Story |
|---|---|---|
| PHONE-S1 | P1 | As a person, I want one screen that says whether my phone is reachable and what to fix, so that "it doesn't work" is never a mystery. |
| PHONE-S2 | P1 | As a person, I want to decide whether PocketDeck keeps running and who may connect, so that my phone is not reachable when I do not want it. |
| PHONE-S3 | P1 | As a person, I want the pairing prompt where I am — over the app or as a notification — so that I can allow the Mac without hunting for the app. |
| PHONE-S4 | P1 | As a person, I want to see the Macs I paired and forget one safely, so that an old Mac cannot connect. |
| PHONE-S5 | P1 | As a person, I want each permission asked only when it is needed and to see why one is missing, so that a denial disables one thing, not the app. |
| PHONE-S6 | P2 | As a person, I want PocketDeck to stay reachable after a reboot or a swipe when I asked for that, and to stop when I did not, so that the switch means what it says. |
| PHONE-S7 | P2 | As a person, I want the screen dark while the Mac holds it off but my phone still locked, so that a mirrored phone does not light up my desk. |

## Settings inventory

| Setting | Scope | Store | Default | What it does | Where |
|---|---|---|---|---|---|
| Keep running in the background | per install | SharedPreferences `pocketdeck` `enabled` | **off** | On: the service survives the app's task being swiped away and starts at boot (with Shizuku running). Off: it lives only while the task lives. | Home switch; asked once in onboarding as "Let PocketDeck run in the background" |
| Allow connections | per install | `allow_connections` | **on** | Off refuses every Mac (paired or not), drops a live session, stops advertising and shows "Connections are off"; unreadable values fail closed | Home switch |
| Allow new pairings | per install | `allow_pairings` | **on** | Off refuses an unpaired Mac before any code; paired Macs still connect. Disabled with "Turn on Allow connections first." while the master switch is off | Home switch |
| Onboarding done | per install | `onboarding_done` | false | Home after the first run, the pager before it | Internal |
| Battery request made | per install | `battery_requested` | false | The onboarding step completes once the person has been asked to exempt PocketDeck from battery optimisation | Internal |
| Paired Macs | per install | `paired` (client id, name, fingerprint, last connected) | empty | The home list, the pins, and what the shell service trusts | Home list |
| Pending QR | per install | `pending_qr` | none | A scanned pairing secret, served once or after 5 minutes | Internal |
| Notifications (system) | per install | Android `POST_NOTIFICATIONS` | **off** until asked | The pairing prompt as a notification, the ongoing service notification and the ring | Onboarding step 3, in context |
| Shizuku permission (system) | per install | Shizuku grant | **off** until asked | The shell service that serves the session, the screen and the files | Onboarding step 2 and the home's Allow |
| Notification-listener access (system) | per install | `enabled_notification_listeners` for `PdNotificationListener` | **off** | The Mac's sharing switch needs it; the phone asks once at shell UID when sharing turns on | Requested by the Mac's switch; the home's attention item opens the system screen |
| Battery optimisation (system) | per install | Android exemption | not exempt | Keeps the service alive while the screen is off | Onboarding step 3, once |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| PHONE-1 | THE home's status card SHALL be one of Ready, Connected to <Mac>, Needs attention (with its kind) or Couldn't start, chosen in this order: Allow connections off; Shizuku not running; Shizuku permission missing; the Mac asked for notifications and the listener grant is missing; a Mac connected; the background switch off (Ready, "Stops when you close PocketDeck from recent apps."); a listening port (Ready); otherwise Couldn't start with Retry. | K1 `UiStateTest` (`running server with nothing connected is ready`, `a connected Mac wins over ready`, `connections off needs attention with the turn-on action`, `background off is ready and informational, not a warning`, `connections off outranks the background switch`, `shizuku not running needs attention`, `shizuku permission missing needs attention`, `enabled with everything healthy but no port is an error with retry`, `a broken shizuku outranks a notification grant`); Compose screenshots `home_ready_*`, `home_connected_*`, `home_shizuku_not_running_*`, `home_notify_access_*` (light and dark) |
| PHONE-2 | THE card's copy SHALL be: Ready · "Visible to Macs on <Wi-Fi name>" (the word Wi-Fi when the name is unknown); Connected to <Mac name> · "1 window open" or "<n> windows open"; Shizuku not running · "Start it in the Shizuku app."; Shizuku permission needed · "Allow PocketDeck to use Shizuku."; Connections are off · "Turn on Allow connections."; Notification access is off · "Allow PocketDeck to read notifications on this phone."; Couldn't start · "Something stopped PocketDeck's connection."; it SHALL carry no port number, and the background-off card SHALL have no action button. | K1 `HomeScreenTest` (`background off says the service stops with the task`, `background off has no turn-on button`); Compose screenshots `home_ready_*`, `home_connected_*`, `home_shizuku_not_running_*`, `home_notify_access_*`; review of `strings.xml` |
| PHONE-3 | WHEN the card's action is used THE phone SHALL run exactly that fix: Turn on sets Allow connections; Open Shizuku opens Shizuku (or says it is not installed); Allow asks for Shizuku; the notification-access action opens the system's notification-listener screen; Retry starts the service again; a card with no action SHALL do nothing. | K1 `StatusActionTest.turn on fixes only allow connections`, `UiStateTest` (the kind → action table); review of `DeckViewModel.runStatusAction` |
| PHONE-4 | WHEN the Mac asks for notification sharing THE app SHALL pass the phone's listener grant into the status card and, IF it is missing, the card SHALL show "Notification access is off" with Allow. | K1 `UiStateTest` `a missing notification grant while the Mac asked needs attention`, `HomeScreenTest` `a missing listener grant while the Mac asked shows the attention item`, Compose screenshots `home_notify_access_*`; **the wiring is absent today** — `DeckViewModel.refresh` calls `mapStatus` without `notifyNoAccess`, so the state is unreachable in the running app (open question 1, misses.md M5) |
| PHONE-5 | THE home SHALL offer exactly three switches — Keep running in the background (default off), Allow connections (default on) and Allow new pairings (default on, disabled with "Turn on Allow connections first." while the master is off) — and SHALL NOT offer a notification-sharing switch; toggling a gate SHALL push it to the shell service at once and fix the advertisement (off stops advertising; on advertises when listening), and toggling the background switch SHALL NOT stop the running service (off lets it stop with the task; on starts it). | K1 `StatusActionTest.turning the background switch off keeps the service running`, `turning the background switch on starts the service`, `ConnectionGateTest` (the server gates, fail closed); K1 `HomeScreenTest` `the phone's home has no notification sharing switch`; review of `Prefs` defaults and `DeckForegroundService.gatesChanged` |
| PHONE-6 | WHILE the app runs THE phone SHALL run one foreground service of type connectedDevice with an ongoing notification on the "Connection status" channel (low importance) whose text is "Starting…" before the port exists, "Ready for your Mac" while listening and "Connected to <Mac name> · 1 window" or "· <n> windows" while serving; tapping it SHALL open the app, it SHALL carry no port number, and it SHALL update on every session or window change. | K1 `DeckForegroundServiceTest` (`the service stops when the task is removed and the switch is off`, `the service survives task removal when the switch is on`, `boot starts the deck only with the switch on and Shizuku running`); review of `DeckForegroundService.updateOngoing` and `strings.xml`; preview of the phone's own notification is **untested** (the e2e has no phone UI) |
| PHONE-7 | WHEN the app's task is swiped away WHILE the background switch is off THE service SHALL stop serving — close the listening socket, stop advertising and stop itself — and WHILE the switch is on it SHALL keep serving; after a reboot or an app update it SHALL start only when the switch is on and Shizuku is running. | K1 `DeckForegroundServiceTest` (the three cases), `BootReceiver`'s `startsAtBoot` (the same test); review of `onTaskRemoved` and `stopServing` |
| PHONE-8 | WHEN a Mac asks to pair THE phone SHALL show, as a high-importance notification on the "Pairing requests" channel, "Pair with <Mac name>?" with "Code 123 456" and Allow/Deny, only alert once, time out and cancel after 120 s, and tap through to the app; WHILE PocketDeck is in the foreground it SHALL also show the floating card — 16 dp side margins, 16 dp above the navigation bar, all corners rounded, the code in large monospaced digits, the line "Check it matches your Mac." and Deny/Allow — and the card SHALL NOT be dismissed by Back or a tap outside; both SHALL disappear when the Mac cancels or the request expires, and only one request SHALL be pending at a time. | K1 `PairingDialogTest` `the card floats 16dp above the navigation bar inset`, `PairCooldownTest` (the 30 s window), `SessionTest` (pairing.md PAIR-6); e2e `pair` `[PAIR-4]` (the same code on both screens); screenshots `pairing_dialog_light`/`_dark` |
| PHONE-9 | THE home's "Paired Macs" list SHALL show one row per paired Mac with its name and "Connected now" or "Last connected <relative time>", the live Mac first and then the most recently connected, "No Macs paired yet." when empty, and the relative times SHALL refresh on the next whole minute without polling; "Pair new Mac" (QR) SHALL be offered only while Allow connections and Allow new pairings are on. | K1 `DeckPairedRowsTest.the live Mac is the first paired row`, `never connected Macs come last, newest connection first`, `UiStateTest` `the relative-time ticker wakes on the next whole minute`; screenshots `home_ready_*`, `home_connected_*`; review of `HomeScreen` (the FAB's condition and `rememberMinuteTick`) |
| PHONE-10 | WHEN the person forgets a Mac by swiping its row or its overflow menu THE row SHALL disappear and a snackbar SHALL say "Forgot <Mac>." with Undo for four seconds; Undo SHALL keep the pairing; letting it expire SHALL remove the pin and tell the shell service; the overflow button SHALL read "More options for <Mac>". | K1 `HomeScreenTest.the paired row overflow is named for its Mac`; review of `DeckViewModel.forget`/`undoForget` and `HomeScreen`'s snackbar; the four-second undo is **untested** end to end |
| PHONE-11 | THE phone SHALL ask for a permission only in context, with a sentence saying why: notifications in the onboarding step "Allow notifications" ("Needed for pairing prompts."), Shizuku from the onboarding step or the card's Allow, the battery exemption from onboarding's "Let PocketDeck run in the background" once, and the notification-listener grant only when the Mac's sharing switch asks; a denied permission SHALL disable only its own feature (the prompt notification, the session, the sharing) and SHALL NOT disable the in-app pairing card or the rest of the app. | K1 `UiStateTest` `shizuku row follows installed, running, granted order`, `notifications step needs permission and one battery request`; review of `DeckApp`'s launcher and `DeckViewModel`; screenshots `onboarding_shizuku_*`, `onboarding_notifications_*`; the denied-notification pairing case is **untested** (misses.md M8) |
| PHONE-12 | WHILE the Mac holds this phone's panel off THE phone's screen SHALL be dark while the mirror still renders and SHALL stay locked; the phone SHALL report `state.panel off` only while it actually holds it; a power press SHALL end the hold and restore the panel unless the Mac's keep-off setting is on, in which case the screen lights only until the next keep-alive step and the hold stands; a paused mirror SHALL hand the panel back and re-apply the hold on resume; every end — the Mac's request, the window closing, the session ending, a disconnect and crash recovery — SHALL restore the panel. | K1 `PanelHoldTest` (every state/event pair, every exit restores the panel), `PanelPowerSessionTest`, `PhoneWakeSessionTest`; e2e `mirror` `[MIRROR-12]` (the power press); phone-mirror.md MIRROR-9/12 own the Mac's side |
| PHONE-13 | PocketDeck SHALL NOT unlock the phone, dismiss the keyguard, or change the lock screen, a screen timeout or another app's state: waking the screen is allowed, a power press still locks the phone, and "Turn Off Phone Screen" only holds the panel's power mode until it is handed back. | K1 `PanelHoldTest` (no action unlocks), `PanelPowerSessionTest`; review of `AndroidPower`; e2e `mirror` (the hold's ends); AGENTS.md's product promise |
| PHONE-14 | WHEN the Mac asks the phone to ring THE phone SHALL play the default alarm at the alarm volume for 1–30 s and show a black "Ringing" activity with one big Stop over the lock screen when the system allows it, plus a dismissable "Ringing" notification whose Stop action stops the ring; it SHALL stop on Stop, on the timeout and on audio-focus loss, and it SHALL NOT unlock the phone or change the alarm volume. | K1 `RingSessionTest`, `RingerControlTest`; review of `RingController` and `RingActivity`; the visible lock-screen face is **untested** (the e2e has no phone UI) |
| PHONE-15 | THE app SHALL follow the system theme — Material 3 dynamic colour and light/dark, edge-to-edge with the system bars' insets — and SHALL NOT convey a state by colour alone (the status card carries an icon, a title and a sentence; a connected row says "Connected now"); the home SHALL scroll and its card, switches and "Paired Macs" title SHALL share one left edge. | Compose screenshots (`home_ready_*`, `home_connected_*`, `home_shizuku_not_running_*`, `home_notify_access_*`, `pairing_dialog_*`, the onboarding pages — light and dark); K1 `HomeScreenTest` `the card, the first switch label and the paired title share a left edge`; review of the Compose semantics |
| PHONE-16 | EVERY switch SHALL be a switch to its accessibility service with its own label and checked state; an icon-only control SHALL have a spoken label ("More options for <Mac>"); the card's reading order SHALL be icon, title, sentence, action; every text SHALL follow the system's font scale. | K1 `HomeScreenTest` `the paired row overflow is named for its Mac`; Compose semantics review (the `toggleable` role on each row); screenshots at the default scale |
| PHONE-17 | THE app SHALL write no notification text, notification title, media title/artist/album, file name, pasteboard content, Mac pairing secret, QR secret or key material to logcat or a crash report: ids, counts, states, sizes and hash prefixes only, and the pairing code is displayed, never logged. | review of every `Log` call in the app and the shell service; K1 `NotifyEventsTest`/`MediaArtTest` (their records carry no text); pairing.md PAIR-18, notifications.md NOTIFY-3 |

Priority note: PHONE-1, 2, 3, 5, 6, 7, 8, 9, 11, 12, 13 and 17 are P1; the list's detail, the undo, the ring face and the visual rules are P2.

## States and events

The home is one status machine (`mapStatus`, `android/app/src/main/java/dev/pocketdeck/ui/DeckUiState.kt`). Every input is read from the service's and Shizuku's current state; nothing is stored as a second flag.

| State | Event | Result |
|---|---|---|
| any | a state change (service, Shizuku, session, gates, listener) | the card is recomputed in the precedence of PHONE-1; the first matching state wins |
| Ready / Connected | Allow connections turned off | Needs attention (Connections are off), Turn on; the session drops and advertising stops |
| Needs attention (Connections are off) | Turn on | Ready (or Connected when a Mac returns) |
| Needs attention (Shizuku not running) | Shizuku started | Shizuku permission needed, or Ready when granted |
| Needs attention (Shizuku permission) | Allow granted | the service starts; Ready |
| Needs attention (notification access) | a later grant | the item goes away; forwarding starts without another Mac toggle (NOTIFY-2) |
| Ready (background off) | the task is swiped away | the service stops; the card is not visible |
| Ready (background on) | reboot with Shizuku running | the service starts; Ready |
| any | no port while enabled and healthy | Couldn't start, Retry |
| Needs attention (any) | Retry | the service starts again; the card follows the new state |

Ignored events, stated so nobody builds them: a second Retry while the service is starting, a listener grant while the Mac's sharing switch is off, a pairing answer with no pending prompt, and a notification-access item while the master switch is off (Connections are off wins).

The service is a small lifecycle of its own (`DeckForegroundService`):

| State | Event | Result |
|---|---|---|
| Idle | the app's task starts | Starting: bind Shizuku, create the channels, show "Starting…" |
| Starting | Shizuku ready and gates pushed | Listening: start the server, advertise, "Ready for your Mac" |
| Listening | a Mac connects | Serving: "Connected to <Mac name> · <n> windows"; the gates still apply |
| Serving | the session ends | Listening; the last-connected time is stamped |
| Listening / Serving | the task is swiped away WHILE background is off | Stopping: `stopServer`, stop advertising, `stopSelf` |
| Listening / Serving | the task is swiped away WHILE background is on | no change (the service keeps serving) |
| any | Shizuku is lost | Listening is lost: the port goes, the advertisement stops, "Starting…" (or the attention card) |
| any | Allow connections is turned off | the session drops, advertising stops, the server refuses everything; the service still runs |

The pairing prompt is `None → Pending → Answered` (pairing.md PAIR-6 owns the session machine and the 30 s cooldown):

| State | Event | Result |
|---|---|---|
| None | `pair.request` with Allow new pairings on | Pending: the notification and, in the foreground, the card |
| None | `pair.request` with Allow new pairings off | refused before any code (`pairing_off`); no prompt |
| Pending | Allow / Deny | Answered: the answer goes to the shell service; both surfaces disappear |
| Pending | 120 s / the Mac cancels | None; a deny-timeout answer goes to the Mac |
| Pending | a second `pair.request` in the same session | ignored |
| Pending | Back or a tap outside the card | ignored (the card stays until answered) |
| Pending | notifications denied | the card still shows while the app is in front; the notification is absent (misses.md M8) |

## Phone count and connection

This surface runs on one phone. Its own list counts **Macs**; the Mac-side surfaces count phones (CONV-PD-01 there).

| Situation | The phone shows |
|---|---|
| 0 Macs | Ready (or an attention state); "No Macs paired yet."; Pair new Mac; a pairing prompt can still be answered. |
| 1 Mac | Its row with Connected now or the last-connected time; Connected to <Mac> while it serves. |
| 2+ Macs | One row each, live first then most recent; only one Mac can be connected at a time (a second is refused as busy); forget one and the others keep their pins. |
| The Mac is connecting | The phone's card still says Ready; the session's own state is the Mac's side (pairing.md PAIR-6, deck.md). |
| Connected | "Connected to <Mac name>" · "<n> windows open"; the ongoing notification says the same with no port. |
| The Mac is offline / reconnecting | Ready (the Mac's name is dropped when the session ends); the last-connected time updates. |
| The Mac's sharing switch on, listener missing | The notification-access attention item and "Allow" (when PHONE-4 is wired); the Mac says the same under its switch (SET-DEV-09). |
| Shizuku missing | "Shizuku not running" with Open Shizuku; a phone without Shizuku installed still gets "Shizuku isn't installed." after the tap (misses.md M6). |
| A phone that can't do a feature | The attention card names the missing thing and the one fix; features that need it (the session, notifications, media, files) stay off; the app itself and the pairing card keep working. |
| Phone locked / screen off | Everything above still holds; the lock screen stays; the only screen that may light is the ring's Stop face (PHONE-14). |
| Panel held off | The screen is dark and still locked; the mirror keeps rendering; a power press ends the hold or briefly relights it with "keep it off" on (PHONE-12). |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: no Mac window or search field on this surface |
| CONV-MAC-02 | n/a: the Mac's window keys are not this app's |
| CONV-MAC-03 | n/a: no Mac popover, sheet or menu; the pairing card deliberately ignores Back (PHONE-8) |
| CONV-MAC-04 | n/a: no Mac text field |
| CONV-MAC-05 | n/a: nothing zoomable |
| CONV-MAC-06 | n/a: this app defines no Mac shortcut |
| CONV-MAC-07 | n/a: no Mac shortcut is reused |
| CONV-MAC-10 | n/a: the Mac's status-item panel is panel.md's |
| CONV-MAC-11 | n/a: no Mac window |
| CONV-MAC-12 | n/a: no Mac window |
| CONV-MAC-13 | n/a: no Mac menu or full-screen command |
| CONV-MAC-14 | n/a: no Mac layout |
| CONV-MAC-15 | n/a: closing the Mac app does not quit it; nothing here changes that |
| CONV-MAC-16 | n/a: no Mac drag/drop, paste or Services on this surface (a drop is files.md's) |
| CONV-MAC-20 | n/a: the Mac's appearance rules are the Mac windows'; the phone follows the system theme (CONV-AND-02) |
| CONV-MAC-21 | n/a: Mac accessibility; the phone's own is PHONE-16 |
| CONV-MAC-22 | n/a: Mac Reduce Motion; the phone's animations follow the system's animator scale (PHONE-15) |
| CONV-MAC-23 | n/a: Mac text size; the phone follows the system font scale (PHONE-16) |
| CONV-MAC-24 | n/a: macOS notifications and Focus; the phone's own permission rule is CONV-AND-03 |
| CONV-MAC-25 | n/a: no Mac custom control |
| CONV-MAC-26 | n/a: no Mac layout |
| CONV-AND-01 | n/a: mapping the Mac's Back/Home/Recents to the phone is phone-mirror.md's (MIRROR); this app is an ordinary Android task and leaves system navigation alone |
| CONV-AND-02 | deviates (platform, approval requested): the pairing and ring notifications are dismissable and name what they do, but the foreground-service notification is ongoing by Android's requirement and cannot be dismissed (open question 4); every screen follows the system theme, dynamic colour and light/dark (PHONE-15) |
| CONV-AND-03 | applies: PHONE-11 (each permission in context, with its reason) and PHONE-2/3 (a missing one says why and offers its fix). Two gaps: the notification-access item is unreachable (misses.md M5) and a denied notification permission hides the pairing prompt (misses.md M8) |
| CONV-AND-04 | applies: PHONE-12 and PHONE-13 (the panel hold is the only phone-side change and every end restores it; nothing unlocks or changes a setting; the lock screen stays), plus a paired-client list the person edits and files they asked to send |
| CONV-PD-01 | applies: the table above — this surface runs on one phone; it counts 0/1/2+ **Macs**, and the Mac-side 0/1/2+ phones are deck.md/settings.md |
| CONV-PD-02 | applies: the table above (connecting, connected, offline, Shizuku missing, a phone that can't do a feature) |
| CONV-PD-03 | applies: PHONE-8 (the prompt is the pending state; the Mac shows "Pairing…" from the wire, never from a guess) and PHONE-3 (an action does only its fix) |
| CONV-PD-04 | n/a: the three switches are local values, not live controls following a phone value |
| CONV-PD-05 | applies: PHONE-17 |
| CONV-PD-06 | applies: no measured frame budget belongs to this surface; the only motion is the card's 200 ms cross-fade and the pager, which follow the system's animator scale, and the home is a static list with one minute ticker |
| CONV-PD-07 | applies: "Ready", "Connected to <Mac>", "Allow connections", "Allow new pairings", "Paired Macs", "Pair new Mac", "Keep running in the background" are one name each — except the onboarding label "Let PocketDeck run in the background" for the same switch (misses.md M7) |
| CONV-PD-08 | applies: the status, service and prompt tables above; the panel hold is MIRROR's `PanelHold` table (PHONE-12) |
| CONV-PD-09 | applies: every attention item names its fix (Turn on, Open Shizuku, Allow, Retry) and "No Macs paired yet." names the empty state; two gaps: Shizuku-not-installed still offers Open Shizuku (misses.md M6) and the notification-access item has no way to appear (M1) |

## Assumptions

- Android 13+ (API 33) for the runtime notification permission; the app targets API 36 and uses Shizuku at shell UID.
- Shizuku is installed and started by the person; PocketDeck cannot start it or grant itself the permission.
- The shell user service is the only server; there is one app process and one foreground service.
- The Material 3 dynamic colour is supplied by the system; on a device without dynamic colour the theme falls back to the app's own palette.
- A phone has one screen (display 0); a foldable's inner/outer change is Android's own configuration change.
- The person's lock screen and screen timeout are theirs; PocketDeck never changes them.

## Non-goals

- The onboarding pager's copy and the pairing flow itself (UX.md, pairing.md); this spec covers the permissions it asks and the prompt's surfaces.
- Notifications, media, Now Playing and files forwarding as content (notifications.md, media.md, files.md); this spec covers the phone's own home, service and notifications for them.
- Starting, installing or granting Shizuku for the person beyond the one button each.
- A phone-side notification-sharing switch: the Mac's per-phone switch is the only one (settings.md SET-DEV-09).
- A settings screen of its own: the three switches and the list are the whole home.
- Running without Shizuku, or a second server/session.
- Any change to the lock screen, screen timeout or another app's state.

## Open questions

- [NEEDS CLARIFICATION] **The notification-access item cannot appear** — `mapStatus` has the state and the Compose card renders it, but `DeckViewModel.refresh` builds `StatusInput` without `notifyNoAccess`, so the running app never shows "Notification access is off" (CONV-AND-03; misses.md M5). Recommended: pass `DeckState.notifyNoAccess` and add one K1 wiring test; no new UI.
- [NEEDS CLARIFICATION] **Shizuku not installed still offers Open Shizuku** — the home says "Shizuku not running" and the button opens Shizuku; on a phone without it the person gets "Shizuku isn't installed." (CONV-PD-09; misses.md M6). Recommended: when the package is absent, the card reads "Shizuku isn't installed" with Get Shizuku, the onboarding step's own action.
- [NEEDS CLARIFICATION] **One switch, two names** — onboarding says "Let PocketDeck run in the background", home says "Keep running in the background" (CONV-PD-07; misses.md M7). Recommended: one name everywhere, "Keep running in the background".
- [NEEDS CLARIFICATION] **The ongoing notification is not dismissable** — CONV-AND-02 says a notification PocketDeck posts is dismissable; a foreground service's is ongoing by Android's requirement (misses.md M9). Recommended: keep it and record the deviation in CONVENTIONS.md, with the pairing and ring notifications as the dismissable ones.
- [NEEDS CLARIFICATION] **A denied notification permission hides the pairing prompt** — with notifications denied and the app in the background, the notification is never posted and the in-app card is not on screen; the Mac waits 120 s and says nobody answered (CONV-AND-03; the same gap pairing.md records as M4, misses.md M8). Recommended: an "Allow notifications to pair" attention item on the home while a prompt is pending, and the Mac's sheet says "Open PocketDeck on your phone to allow it." after 20 s.
