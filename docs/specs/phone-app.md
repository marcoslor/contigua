# Phone app

Prefix: `PHONE`. Owner docs: [UX.md](../UX.md) § "Android app", [DESIGN.md](../DESIGN.md) §2–3, [PROTOCOL.md](../PROTOCOL.md) § "Transport", § "Phone screen" and § "Ring", [design/phone-mirror.md](../design/phone-mirror.md) (the panel hold), [design/notify.md](../design/notify.md) (the listener grant). Last reviewed: 2026-11-01, against main `a3f0731c`.

## Purpose

The Android app as a person sees it on the phone: one home screen that says whether this phone is reachable and why not, three switches, the Macs it trusts, the pairing prompt (a notification and, in the foreground, a floating card), the permissions it needs, the foreground service that keeps it reachable with its ongoing notification, and what "Turn Off Phone Screen" looks like from the phone's side — a dark screen that stays locked. The onboarding pager's copy and the pairing flows are UX.md's and pairing.md's (`PAIR-6`, `PAIR-16`); the Mac's side of every conversation is deck.md, settings.md, panel.md or phone-mirror.md. This spec owns the phone's own surfaces and answers the Android conventions here in full.

## User stories

| ID | Priority | Story |
|---|---|---|
| PHONE-S1 | P1 | As a person, I want one screen that says whether my phone is reachable and what to fix, so that "it doesn't work" is never a mystery. |
| PHONE-S2 | P1 | As a person, I want to decide whether Contigua keeps running and who may connect, so that my phone is not reachable when I do not want it. |
| PHONE-S3 | P1 | As a person, I want the pairing prompt where I am — over the app or as a notification — so that I can allow the Mac without hunting for the app. |
| PHONE-S4 | P1 | As a person, I want to see the Macs I paired and forget one safely, so that an old Mac cannot connect. |
| PHONE-S5 | P1 | As a person, I want each permission asked only when it is needed and to see why one is missing, so that a denial disables one thing, not the app. |
| PHONE-S6 | P2 | As a person, I want Contigua to stay reachable after a reboot or a swipe when I asked for that, and to stop when I did not, so that the switch means what it says. |
| PHONE-S7 | P2 | As a person, I want the screen dark while the Mac holds it off but my phone still locked, so that a mirrored phone does not light up my desk. |

## Settings inventory

| Setting | Scope | Store | Default | What it does | Where |
|---|---|---|---|---|---|
| Keep running in the background | per install | SharedPreferences `contigua` `enabled` | **off** | On: the service survives the app's task being swiped away, starts after a reboot or an app update (waiting up to 5 s for Shizuku's binder), and the row asks for the battery exemption while it is missing. Off: it lives only while the task lives, and no reboot or update starts it. | Home switch; the same action in onboarding, with the same words |
| Allow connections | per install | `allow_connections` | **on** | Off refuses every Mac (paired or not), drops a live session, stops advertising and shows "Connections are off"; unreadable values fail closed | Home switch |
| Allow new pairings | per install | `allow_pairings` | **on** | Off refuses an unpaired Mac before any code; paired Macs still connect. Disabled with "Turn on Allow connections first." while the master switch is off | Home switch |
| Onboarding done | per install | `onboarding_done` | false | Home after the first run, the pager before it | Internal |
| Battery request made | per install | `battery_requested` | false | True once a battery-settings screen actually opened; the onboarding step completes only together with the exemption itself (PHONE-19) | Internal |
| Paired Macs | per install | `paired` (client id, name, fingerprint, last connected) | empty | The home list, the pins, and what the shell service trusts | Home list |
| Forget All Macs… | per install | rotates `identity_v2.json`, empties `paired` | n/a | Every Mac must pair again; the live session drops and the shell forgets what it cached | Paired Macs ▸ the action beside the title, with a confirmation (PHONE-18) |
| Pending QR | per install | `pending_qr` | none | A scanned pairing secret, served once or after 5 minutes | Internal |
| Notifications (system) | per install | Android `POST_NOTIFICATIONS` | **off** until asked | The pairing prompt as a notification, the ongoing service notification and the ring | Onboarding step 3, in context |
| Shizuku permission (system) | per install | Shizuku grant | **off** until asked | The shell service that serves the session, the screen and the files | Onboarding step 2 and the home's Allow |
| Notification-listener access (system) | per install | `enabled_notification_listeners` for `PdNotificationListener` | **off** | The Mac's sharing switch needs it; the phone asks once at shell UID when sharing turns on | Requested by the Mac's switch; the home's attention item opens the system screen |
| Battery optimisation (system) | per install | Android exemption | not exempt | Keeps the service alive while the screen is off | Onboarding step 3, once |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| PHONE-1 | THE home's status card SHALL be one of Ready, Connected to <Mac>, Needs attention (with its kind) or Couldn't start, chosen in this order: Allow connections off; Shizuku not running; Shizuku permission missing; the shell binding keeps timing out while Shizuku answers; the Mac asked for notifications and the listener grant is missing; a pairing prompt is pending and the notification permission is denied; a Mac connected; the background switch off (Ready, "Stops when you close Contigua from recent apps."); a listening port (Ready); otherwise Couldn't start with Retry. | K1 `UiStateTest` (`running server with nothing connected is ready`, `a connected Mac wins over ready`, `connections off needs attention with the turn-on action`, `background off is ready and informational, not a warning`, `connections off outranks the background switch`, `shizuku not running needs attention`, `shizuku permission missing needs attention`, `enabled with everything healthy but no port is an error with retry`, `a broken shizuku outranks a notification grant`, `a shell helper that stops answering needs attention with retry`, `a dead shell helper outranks a notification grant`); Compose screenshots `home_ready_*`, `home_connected_*`, `home_shizuku_not_running_*`, `home_notify_access_*` (light and dark) |
| PHONE-2 | THE card's copy SHALL be: Ready · "Visible to Macs on <Wi-Fi name>" (the word Wi-Fi when the name is unknown); Connected to <Mac name> · "1 window open" or "<n> windows open"; Shizuku not running · "Start it in the Shizuku app." (a phone without Shizuku · "Shizuku isn't installed" · "Install Shizuku to use Contigua."); Shizuku permission needed · "Allow Contigua to use Shizuku."; Shizuku isn't answering · "Contigua can't reach Shizuku. Try again restarts Contigua's connection." with Try again; Connections are off · "Turn on Allow connections."; Notification access is off · "Allow Contigua to read notifications on this phone."; Notifications are off (a pairing prompt is waiting) · "Allow notifications so your Mac can ask to pair."; Couldn't start · "Something stopped Contigua's connection."; it SHALL carry no port number, and the background-off card SHALL have no action button. | K1 `HomeScreenTest` (`background off says the service stops with the task`, `background off has no turn-on button`, `a phone without Shizuku offers to get it`); Compose screenshots `home_ready_*`, `home_connected_*`, `home_shizuku_not_running_*`, `home_shizuku_not_installed_*`, `home_notify_access_*`; review of `strings.xml` |
| PHONE-3 | WHEN the card's action is used THE phone SHALL run exactly that fix: Turn on sets Allow connections; Open Shizuku opens Shizuku (or says it is not installed); Allow asks for Shizuku; the notification-access action opens the system's notification-listener screen; the pairing-prompt notification item asks for the notification permission; Retry starts the service again; Try again (the shell card) restarts Contigua's connection — the app's own process when Shizuku answers but every bind times out; a card with no action SHALL do nothing. | K1 `StatusActionTest.turn on fixes only allow connections`, `UiStateTest` (the kind → action table); review of `DeckViewModel.runStatusAction` |
| PHONE-4 | WHEN the Mac asks for notification sharing THE app SHALL pass the phone's listener grant into the status card and, IF it is missing, the card SHALL show "Notification access is off" with Allow. | K1 `DeckViewModelTest` `a missing listener grant while the Mac asked reaches the card` (the service's flag reaches `mapStatus`), `UiStateTest` `a missing notification grant while the Mac asked needs attention`, `HomeScreenTest` `a missing listener grant while the Mac asked shows the attention item`, Compose screenshots `home_notify_access_*` |
| PHONE-5 | THE home SHALL offer exactly three switches — Keep running in the background (default off), Allow connections (default on) and Allow new pairings (default on, disabled with "Turn on Allow connections first." while the master is off) — and SHALL NOT offer a notification-sharing switch; toggling a gate SHALL push it to the shell service at once and fix the advertisement (off stops advertising; on advertises when listening), and toggling the background switch SHALL NOT stop the running service (off lets it stop with the task; on starts it). | K1 `StatusActionTest.turning the background switch off keeps the service running`, `turning the background switch on starts the service`, `ConnectionGateTest` (the server gates, fail closed); K1 `HomeScreenTest` `the phone's home has no notification sharing switch`, `BackgroundSwitchNameTest` (onboarding and the home render one name); review of `Prefs` defaults and `DeckForegroundService.gatesChanged` |
| PHONE-6 | WHILE the app runs THE phone SHALL run one foreground service of type connectedDevice with an ongoing notification on the "Connection status" channel (low importance) whose text is "Starting…" before the port exists, "Ready for your Mac" while listening and "Connected to <Mac name> · 1 window" or "· <n> windows" while serving; tapping it SHALL open the app, it SHALL carry no port number, and it SHALL update on every session or window change. | K1 `DeckForegroundServiceTest` (`the service stops when the task is removed and the switch is off`, `the service survives task removal when the switch is on`); review of `DeckForegroundService.updateOngoing` and `strings.xml`; preview of the phone's own notification is **untested** (the e2e has no phone UI) |
| PHONE-7 | WHEN the app's task is swiped away WHILE the background switch is off THE service SHALL stop serving — close the listening socket, stop advertising and stop itself — and WHILE the switch is on it SHALL keep serving; after a reboot or an app update THE app SHALL start the deck only when the switch is on, waiting up to 5 s for Shizuku's binder through one `goAsync` result and the sticky listener, SHALL start it exactly once when a binder that arrives later reaches the process, and SHALL NOT start it when the switch is off; WHEN the shell binding reaches Ready while no deck service runs and the switch is on THE app SHALL start the deck so the pairings and gates are pushed; with no tap and no launch the shell service SHALL be linked (`app link: … --> linked`) and listening within 15 s of the binder. | K1 `DeckStartupTest` (every state/event pair, the 5 s bound, the late binder, keep-running off, the ready guard), `DeckForegroundServiceTest` (the two task cases); emulator `update-race` (3 rounds: the APK installed over itself with the binder 1 s late, linked and listening within 15 s, the update's own pid, no tap or launch), `shizuku-restart` (3 rounds, PHONE-20); review of `BootReceiver`/`StartupRun` |
| PHONE-8 | WHEN a Mac asks to pair THE phone SHALL show, as a high-importance notification on the "Pairing requests" channel, "Pair with <Mac name>?" with "Code 123 456" and Allow/Deny, only alert once, time out and cancel after 120 s, and tap through to the app; WHILE Contigua is in the foreground it SHALL also show the floating card — 16 dp side margins, 16 dp above the navigation bar, all corners rounded, the code in large monospaced digits, the line "Check it matches your Mac." and Deny/Allow — and the card SHALL NOT be dismissed by Back or a tap outside; both SHALL disappear when the Mac cancels or the request expires, and only one request SHALL be pending at a time. | K1 `PairingDialogTest` `the card floats 16dp above the navigation bar inset`, `PairCooldownTest` (the 30 s window), `SessionTest` (pairing.md PAIR-6); e2e `pair` `[PAIR-4]` (the same code on both screens); screenshots `pairing_dialog_light`/`_dark` |
| PHONE-9 | THE home's "Paired Macs" list SHALL show one row per paired Mac with its name and "Connected now" or "Last connected <relative time>", the live Mac first and then the most recently connected, "No Macs paired yet." when empty, and the relative times SHALL refresh on the next whole minute without polling; "Pair new Mac" (QR) SHALL be offered only while Allow connections and Allow new pairings are on. | K1 `DeckPairedRowsTest.the live Mac is the first paired row`, `never connected Macs come last, newest connection first`, `UiStateTest` `the relative-time ticker wakes on the next whole minute`; screenshots `home_ready_*`, `home_connected_*`; review of `HomeScreen` (the FAB's condition and `rememberMinuteTick`) |
| PHONE-10 | WHEN the person forgets a Mac by swiping its row or its overflow menu THE row SHALL disappear and a snackbar SHALL say "Forgot <Mac>." with Undo for four seconds; Undo SHALL keep the pairing; letting it expire SHALL remove the pin and tell the shell service; the overflow button SHALL read "More options for <Mac>". | K1 `HomeScreenTest.the paired row overflow is named for its Mac`; review of `DeckViewModel.forget`/`undoForget` and `HomeScreen`'s snackbar; the four-second undo is **untested** end to end |
| PHONE-11 | THE phone SHALL ask for a permission only in context, with a sentence saying why: notifications in the onboarding step "Allow notifications" ("Needed for pairing prompts."), Shizuku from the onboarding step or the card's Allow, the battery exemption from onboarding's "Let Contigua run in the background" once, and the notification-listener grant only when the Mac's sharing switch asks; a denied permission SHALL disable only its own feature (the prompt notification, the session, the sharing) and SHALL NOT disable the in-app pairing card or the rest of the app. | K1 `UiStateTest` `shizuku row follows installed, running, granted order`, `notifications step needs permission and one battery request`; review of `DeckApp`'s launcher and `DeckViewModel`; screenshots `onboarding_shizuku_*`, `onboarding_notifications_*`; the pairing-prompt notification item (K1 `UiStateTest`, `HomeScreenTest`) |
| PHONE-12 | WHILE the Mac holds this phone's panel off THE phone's screen SHALL be dark while the mirror still renders and SHALL stay locked; the phone SHALL report `state.panel off` only while it actually holds it; a power press SHALL end the hold and restore the panel unless the Mac's keep-off setting is on, in which case the screen lights only until the next keep-alive step and the hold stands; a paused mirror SHALL hand the panel back and re-apply the hold on resume; every end — the Mac's request, the window closing, the session ending, a disconnect and crash recovery — SHALL restore the panel. | K1 `PanelHoldTest` (every state/event pair, every exit restores the panel), `PanelPowerSessionTest`, `PhoneWakeSessionTest`, `PanelRelightTest` (a press inside a relight's panel-off hands back once); e2e `mirror` `[MIRROR-12]` (the power press); phone-mirror.md MIRROR-9/12 own the Mac's side |
| PHONE-13 | Contigua SHALL NOT unlock the phone, dismiss the keyguard, or change the lock screen, a screen timeout or another app's state: waking the screen is allowed, a power press still locks the phone, and "Turn Off Phone Screen" only holds the panel's power mode until it is handed back. | K1 `PanelHoldTest` (no action unlocks), `PanelPowerSessionTest`; review of `AndroidPower`; e2e `mirror` (the hold's ends); AGENTS.md's product promise |
| PHONE-22 | WHILE the person owns the panel (`WakeOwner.PERSON_TOOK_OVER`) and a streaming window display shares the panel's display group THE phone SHALL hold no display-scoped wake lock and send no user-activity poke that keeps that group awake, so the phone's own screen timeout runs; WHEN that timeout turns the panel off THE phone SHALL re-light the window displays exactly as after a power press — the panel stays dark, the windows keep streaming, and the Mac is told about the off edge; a power press seen during that relight's own panel-off SHALL hand the panel back at once and stop the re-applies, so one press lights the phone (ISS-24); on a build where the window display has its own group THE phone SHALL hold and poke as before in every wake state; and no display lock SHALL outlive its stream. | K1 `GroupHoldTest` (the person-owned shared group, ours/not-ours with streams, every owner on an own group, no streams, the timeout's `RELIGHT`), `DarkPanelPolicyTest` (the press and timeout pairs), `PanelRelightTest` (a press inside the relight's panel-off hands back once); emulator (one boot, no force flags: a window streams across the phone's sleep, the panel is asleep in `dumpsys power` (`mWakefulness=Asleep`), the window keeps delivering frames, the display lock stays held, and no `displaylock released reason=person_owns` line appears); real-phone check `.agent/timeout/real-phone.md` |
| PHONE-14 | WHEN the Mac asks the phone to ring THE phone SHALL play the default alarm at the alarm volume for 1–30 s and show a black "Ringing" activity with one big Stop over the lock screen when the system allows it, plus a dismissable "Ringing" notification whose Stop action stops the ring; it SHALL stop on Stop, on the timeout and on audio-focus loss, and it SHALL NOT unlock the phone or change the alarm volume. | K1 `RingSessionTest`, `RingerControlTest`; review of `RingController` and `RingActivity`; the visible lock-screen face is **untested** (the e2e has no phone UI) |
| PHONE-15 | THE app SHALL follow the system theme — Material 3 dynamic colour and light/dark, edge-to-edge with the system bars' insets — and SHALL NOT convey a state by colour alone (the status card carries an icon, a title and a sentence; a connected row says "Connected now"); the home SHALL scroll and its card, switches and "Paired Macs" title SHALL share one left edge. | Compose screenshots (`home_ready_*`, `home_connected_*`, `home_shizuku_not_running_*`, `home_notify_access_*`, `pairing_dialog_*`, the onboarding pages — light and dark); K1 `HomeScreenTest` `the card, the first switch label and the paired title share a left edge`; review of the Compose semantics |
| PHONE-16 | EVERY switch SHALL be a switch to its accessibility service with its own label and checked state; an icon-only control SHALL have a spoken label ("More options for <Mac>"); the card's reading order SHALL be icon, title, sentence, action; every text SHALL follow the system's font scale. | K1 `HomeScreenTest` `the paired row overflow is named for its Mac`; Compose semantics review (the `toggleable` role on each row); screenshots at the default scale |
| PHONE-18 | THE home's Paired Macs section SHALL offer Forget All Macs… while at least one Mac is paired; choosing it SHALL ask "Forget all Macs?" with the consequence ("Contigua will create a new identity for this phone. Every Mac must pair again.") and Cancel, and confirming SHALL rotate the phone's identity, empty the list, drop the live session through the shell service's reconcile (PAIR-20) and show "No Macs paired yet."; the action SHALL be absent while the list is empty. | K1 `PrefsIdentityTest` (`forget all Macs rotates the identity and drops every pairing`, `keeps the device id`), `HomeScreenTest` (the action's presence/absence); screenshots `home_forget_all_light`/`_dark`; emulator `phone-reset` (the confirmation, then the live session ending and the refused reconnect) |
| PHONE-19 | THE onboarding step and the home switch SHALL share one keep-running action: ON SHALL store the pref, start the service and ask for the battery exemption only WHILE it is missing (the exemption dialog, then the app's battery page, then the system's exemption list; each failure logged and reported with "Couldn't open battery settings…"), OFF SHALL store the pref and leave the service running with the task; and the row SHALL say what the pref plus the exemption mean — "Keeps running after you swipe it away and starts when the phone restarts." with the exemption, "Battery restriction still on — Android may stop it." with a button that opens the settings without it, and "Runs only while Contigua is open." when off; onboarding SHALL show "On — Contigua keeps running in the background" with a check, or "Battery restriction still on" with the same button, and SHALL NOT advance that step while the exemption is still missing. | K1 `KeepRunningActionTest` (pref, service, exemption only when missing, the reported failure), `BatteryExemptionTest` (the fallback chain), `keepRunningState` in `UiStateTest`, `StatusActionTest` (`the onboarding keep-running button does what the home switch does`), `HomeScreenTest` (both lines), `UiStateTest` (`notifications step waits for the grant and a real exemption`); screenshots `onboarding_keep_running_on_*`, `onboarding_keep_running_restricted_*`, `home_keep_running_restricted_*`; emulator `background-switch` (the tap before/after, the swipe with on and with off) |
| PHONE-17 | THE app SHALL write no notification text, notification title, media title/artist/album, file name, pasteboard content, Mac pairing secret, QR secret or key material to logcat or a crash report: ids, counts, states, sizes and hash prefixes only, and the pairing code is displayed, never logged. | review of every `Log` call in the app and the shell service; K1 `NotifyEventsTest`/`MediaArtTest` (their records carry no text); pairing.md PAIR-18, notifications.md NOTIFY-3 |
| PHONE-20 | WHEN Shizuku's binder arrives, or arrives again after its server died, THE app SHALL bind the shell user service by itself — binder received, permission check, bind, service ready — with no tap and no relaunch; it SHALL treat a Shizuku permission it cannot read (no binder, or not attached yet) as the last known answer and never as a denial, so a grant that survived the server restart asks for nothing; and the binding SHALL follow one state machine — NoBinder, NeedsPermission, Binding, WaitingRetry, Ready, Failed(reason) — where a bind failure or timeout retries at most 3 times with a 1 s then 2 s backoff, then ends the round in Failed and hands it to the slow ladder (PHONE-23) with no tap needed; a connect that lands after its timeout fired SHALL be Ready, not dropped; and where a binder death returns to NoBinder so the next binder recovers without a tap. Every transition SHALL be logged as `shell binding: <from> --<event>--> <to>`, and a failure SHALL carry one of `bind_timeout`, `binder_dead`, `permission_denied`, `service_died`, `bind_failed` plus, for a thrown bind, only its exception class name. | K1 `ShellBindingTest` (every state/event pair, the bound, the backoff, the late connect, the recovery paths, the log tokens); emulator `shizuku-restart` (3 rounds on one boot: the server and the shell service die, the server starts again, the shell service serves again within 10 s with no tap and no permission prompt), `bootbind` (a second server survives ours: the app recovers without a tap, PHONE-23; written, not yet run); review of `ShizukuClient`, `DeckForegroundService` and `DeckViewModel` |
| PHONE-23 | WHEN the app's binder dies, or a bind round fails, THE app SHALL keep asking for the binder with no tap and no relaunch — a binder probe (a ping and a sticky binder-listener re-add; a pushed binder is then received) and, IF the binder answers, a fresh round — on one slow ladder of 10 s, 30 s, 60 s, then every 60 s; at the 60 s step with no binder it SHALL restart Contigua's own process exactly once per lost-binder episode, so a living Shizuku server pushes a binder to a new pid, and SHALL remember that across the restart (cleared on Ready) so the new process never starts a restart loop; it SHALL log `shell restart: <reason> --restart--> process` (and `--restart declined(<no_context|keep_off|already_restarted>)--> waiting` when it may not) and SHALL NOT kill, signal or restart Shizuku or any of its processes; IF the restarted process also fails to bind THE app SHALL stay on the slow ladder and show the card; WHEN the person uses Try again while the binder answers but every bind times out THE app SHALL restart its own process at once — a tap is consent, so it is not bounded by the episode flag, but it SHALL NOT loop by itself. | K1 `ShellBindingTest` (the table, the late connect, the ladder, the once-per-episode restart, the tap restart, the broadened binder-arrival paths); `UiStateTest` (`a shell helper that stops answering needs attention with retry`); emulator `bootbind` (one round: two servers, the app's server killed, the surviving one must serve again with no tap, our process restarted once; **written, not yet run** — the rig's starter kills every old server, so the second one is forked with `app_process`, and the last boot showed the APK must come from `pm path`, not `dumpsys` codePath; the person's phone install is the final proof); review of `ShizukuClient.restartSelf`/`probeBinder` (no Shizuku process is signalled) |
| PHONE-21 | WHILE a stream is live THE phone SHALL keep its picture's silence under one second: IF the encoder has produced no output buffer for 1000 ms THEN the stream SHALL send JSON `{"t":"window.still","stream":N}` from its own drain loop, and SHALL send it again once a second while the silence lasts; it SHALL send nothing while the stream is paused or covered (the Mac's `window.pause`) and stop when it closes; a stalled drain loop, a stuck session or a backlogged socket SHALL send neither frames nor `still`, leaving the Mac's WIN-17 to say "Not responding"; an encoder that hangs while the drain loop keeps polling reads as still (the known gap, not built for); the stream SHALL log its `still` count as a fact and every transition as `heartbeat: <from> --<event>--> <to>`. | K1 `IdleFrameWatchdogTest` (a fake vendor encoder that produces nothing: a `still` within 1.0–1.2 s and every second for 30 s, none while paused/covered/closed, no poll and no `still` from a stuck drain, every transition); emulator `static-stall` (with `debug.contigua.ignore_repeat_frame=1`: no `stall` for 30 s on a still Settings screen, `still` 25 on the phone and 25 on the Mac, 2026-11-01; the `debug.contigua.freeze_drain=1` phase is not run yet: a stuck drain is K1's case and the Mac's 1.5 s rule is e2e `nfr`'s); the S25+ field check remains for the vendor encoder itself |

Priority note: PHONE-1, 2, 3, 5, 6, 7, 8, 9, 11, 12, 13, 17, 21, 22 and 23 are P1; the list's detail, the undo, the ring face and the visual rules are P2.

## States and events

The home is one status machine (`mapStatus`, `android/app/src/main/java/app/contigua/ui/DeckUiState.kt`). Every input is read from the service's and Shizuku's current state; nothing is stored as a second flag.

| State | Event | Result |
|---|---|---|
| any | a state change (service, Shizuku, session, gates, listener) | the card is recomputed in the precedence of PHONE-1; the first matching state wins |
| Ready / Connected | Allow connections turned off | Needs attention (Connections are off), Turn on; the session drops and advertising stops |
| Needs attention (Connections are off) | Turn on | Ready (or Connected when a Mac returns) |
| Needs attention (Shizuku not running) | Shizuku started | Shizuku permission needed, or Ready when granted |
| Needs attention (Shizuku permission) | Allow granted | the service starts; Ready |
| Needs attention (notification access) | a later grant | the item goes away; forwarding starts without another Mac toggle (NOTIFY-2) |
| Ready (background off) | the task is swiped away | the service stops; the card is not visible |
| Ready (background on) | reboot or app update with Shizuku late | the deck waits up to 5 s for the binder, starts, pushes the pairings and serves; Ready |
| any | no port while enabled and healthy | Couldn't start, Retry |
| Ready (Shizuku answers) | each bind round times out | Needs attention (Shizuku isn't answering), Try again: Contigua's own process restarts (PHONE-23) |
| Needs attention (any) | Retry | the service starts again; the card follows the new state |

### The shell service binding (PHONE-20)

`android/app/src/main/java/app/contigua/app/ShellBinding.kt` is the one state
machine for the app's binding to the shell user service; `ShizukuClient` performs
its actions and keeps no binding flags of its own. A round is at most 3 binds
(5 s timeout each, 1 s then 2 s backoff); a round that fails, or a lost binder,
goes onto one slow ladder — 10 s, 30 s, 60 s, then every 60 s — that probes for
the binder and starts a fresh round when one answers, so nothing needs a tap.
The ladder step is part of the state, so a fresh round resumes it instead of
starting over. A process restart is logged as `shell restart: <reason>
--restart--> process` (or `--restart declined(<no_context|keep_off|already_restarted>)--> waiting`);
Shizuku and its processes are never signalled.

| State | Event | Result |
|---|---|---|
| NoBinder | Started (a fresh process or a re-attach) | NoBinder: probe for the binder |
| NoBinder | binder received | NeedsPermission, check the permission |
| NoBinder | a probe found no binder | NoBinder: wait 10 s, then 30 s, then 60 s, then every 60 s |
| NoBinder | the 60 s step with no binder | NoBinder: restart our own process once (`RestartSelf`, bounded), wait 60 s |
| NoBinder | Retry (no binder to bind with) | Failed (binder_dead) with the first 10 s wait |
| NeedsPermission | permission granted | Binding (1): bind, arm the 5 s timeout |
| NeedsPermission | permission denied | NeedsPermission: the card keeps Allow |
| NeedsPermission | Retry | check the permission again |
| Binding (n) | bound | Ready: the foreground service starts the server |
| Binding (n) | bind failed / timed out / service died | n < 3: WaitingRetry (n) with backoff, then Binding (n+1); else Failed (reason) with the next slow wait (10 s, 30 s, 60 s, then 60 s) |
| Binding / WaitingRetry / NoBinder / Failed | binder dead | NoBinder: cancel the timers, probe now |
| WaitingRetry / Failed | bound (a late connect) | Ready: the connect is the service, even after its timeout |
| WaitingRetry | Retry | Binding (1): a new round with the full budget |
| Failed (any) | slow tick | Failed: probe for the binder |
| Failed (any) | a probe found no binder | Failed: wait the next ladder step |
| Failed (any) | a probe found a binder | NeedsPermission: a fresh round at the same ladder step |
| Failed (any) | binder received | NeedsPermission: recovery with no tap |
| Failed (any) | Retry | Binding (1) |
| Failed (any) | Try again while the binder answers | Failed: restart our own process now (tap), wait 60 s |
| Ready | service died | WaitingRetry (0, service_died), then a new round |
| Ready | binder dead | NoBinder: cancel the timers, probe now |

Ignored events, stated so nobody builds them: a second Retry while the service is starting, a listener grant while the Mac's sharing switch is off, a pairing answer with no pending prompt, and a notification-access item while the master switch is off (Connections are off wins).

### The boot/update start decision (PHONE-7)

`android/app/src/main/java/app/contigua/app/DeckStartup.kt` is the one state
machine for the receiver's decision; `BootReceiver`'s `StartupRun` performs its
actions and keeps no flags of its own. The wait is 5 s: the person's binder was
0.4 s late, and a `goAsync` result has about 10 s, so the start keeps the other
half. A binder that arrives after the bound still starts the deck once while the
process lives (the sticky listener stays registered until it starts).

| State | Event | Result |
|---|---|---|
| Idle | boot/update received, switch on, binder here | Starting: start the deck, finish the broadcast |
| Idle | boot/update received, switch on, no binder | Waiting (0 s): register the sticky listener, arm the 5 s timeout |
| Idle | boot/update received, switch off | Off: nothing, whatever the binder does |
| Waiting | the binder arrives | Starting: finish the broadcast, start the deck |
| Waiting | the timeout before 5 s | Waiting: the new elapsed time |
| Waiting | the timeout at 5 s | OutOfTime: finish the broadcast; the listener stays |
| Waiting | a second broadcast | Waiting: one broadcast decides, no second start |
| Starting | any event | Starting: the deck starts exactly once |
| OutOfTime | the binder arrives | Starting: the deck starts once, now without the broadcast |
| OutOfTime / Off | any other event | no change |

The second path: when the shell binding reaches Ready while no deck service runs
and the switch is on (`startsDeckWhenReady`), the app starts the deck, so the
pairings and gates are pushed. The deck service's own listener remains the one
caller of `onServiceReady`.

### The stream heartbeat (PHONE-21)

`android/app/src/main/java/app/contigua/server/IdleFrameWatchdog.kt` is the one
state machine for a live stream's silence; `WindowStream`'s drain thread feeds it
its clock and performs its actions, and keeps no idle flag of its own. A still
screen sends one `window.still` a second; a paused or covered stream sends
nothing; a closed one never sends again.

| State | Event | Result |
|---|---|---|
| Idle | an encoder is attached, or the stream resumes | Armed: due in 1000 ms |
| Idle | a tick, a frame, a pause | nothing |
| Armed | a frame | Armed: due moves to frame + 1000 ms (the clock restarts) |
| Armed | a tick with no output buffer at its deadline | Still: one `window.still`, due + 1000 ms |
| Armed | a second live | nothing (the encoder's clock is already running) |
| Still | a frame | Armed: due + 1000 ms |
| Still | a tick with no output buffer at its deadline | Still: send again, due + 1000 ms (a stuck encoder stays silent) |
| Armed / Still | a pause or a cover (`window.pause`) | Idle: nothing until the next resume |
| Armed / Still | close | Closed, with the stream's `still` count logged |
| Closed | any event | nothing: the stream is gone |

The service is a small lifecycle of its own (`DeckForegroundService`):

| State | Event | Result |
|---|---|---|
| Idle | the app's task starts | Starting: bind Shizuku, create the channels, show "Starting…" |
| Starting | Shizuku ready and gates pushed | Listening: start the server, advertise, "Ready for your Mac" |
| Listening | a Mac connects | Serving: "Connected to <Mac name> · <n> windows"; the gates still apply |
| Serving | the session ends | Listening; the last-connected time is stamped |
| Listening / Serving | the task is swiped away WHILE background is off | Stopping: `stopServer`, stop advertising, `stopSelf` |
| Listening / Serving | the task is swiped away WHILE background is on | no change (the service keeps serving) |
| Ready (onboarding step) | Keep running in the background tapped, exemption missing | On: the pref is stored, the service starts, the exemption screen opens; the step stays until the exemption is granted |
| On, restricted | the exemption granted later (back from the settings screen) | On — keeps running; the step completes and the pager advances |
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
| Pending | notifications denied | the card still shows while the app is in front; the notification is absent, and the home shows the "Notifications are off" attention item until it is granted (PAIR-6) |

## Phone count and connection

This surface runs on one phone. Its own list counts **Macs**; the Mac-side surfaces count phones (CONV-PD-01 there).

| Situation | The phone shows |
|---|---|
| 0 Macs | Ready (or an attention state); "No Macs paired yet."; Pair new Mac; a pairing prompt can still be answered. |
| 1 Mac | Its row with Connected now or the last-connected time; Connected to <Mac> while it serves. |
| 2+ Macs | One row each, live first then most recent; only one Mac can be connected at a time (a second is refused as busy); the Mac may hold a session to each of several phones at once, which does not change this limit; forget one and the others keep their pins. |
| The Mac is connecting | The phone's card still says Ready; the session's own state is the Mac's side (pairing.md PAIR-6, deck.md). |
| Connected | "Connected to <Mac name>" · "<n> windows open"; the ongoing notification says the same with no port. |
| The Mac is offline / reconnecting | Ready (the Mac's name is dropped when the session ends); the last-connected time updates. |
| The Mac's sharing switch on, listener missing | The notification-access attention item and "Allow" (when PHONE-4 is wired); the Mac says the same under its switch (SET-DEV-09). |
| Shizuku missing | "Shizuku not running" with Open Shizuku; a phone without Shizuku installed says "Shizuku isn't installed" with Get Shizuku, which opens its store or install page. |
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
| CONV-AND-03 | applies: PHONE-11 (each permission in context, with its reason) and PHONE-2/3 (a missing one says why and offers its fix, and the Shizuku item offers the install page when the app is absent). One gap: a denied notification permission hides the pairing prompt (misses.md M8) |
| CONV-AND-04 | applies: PHONE-12, PHONE-13 and PHONE-22 (the panel hold is the only phone-side change and every end restores it; the streams hold no wake lock or poke that outlives the person's own screen timeout; nothing unlocks or changes a setting; the lock screen stays), plus a paired-client list the person edits and files they asked to send |
| CONV-PD-01 | applies: the table above — this surface runs on one phone; it counts 0/1/2+ **Macs**, and the Mac-side 0/1/2+ phones are deck.md/settings.md |
| CONV-PD-02 | applies: the table above (connecting, connected, offline, Shizuku missing, a phone that can't do a feature) |
| CONV-PD-03 | applies: PHONE-8 (the prompt is the pending state; the Mac shows "Pairing…" from the wire, never from a guess) and PHONE-3 (an action does only its fix) |
| CONV-PD-04 | n/a: the three switches are local values, not live controls following a phone value |
| CONV-PD-05 | applies: PHONE-17 |
| CONV-PD-06 | applies: no measured frame budget belongs to this surface; the only motion is the card's 200 ms cross-fade and the pager, which follow the system's animator scale, and the home is a static list with one minute ticker |
| CONV-PD-07 | applies: "Ready", "Connected to <Mac>", "Allow connections", "Allow new pairings", "Paired Macs", "Pair new Mac", "Keep running in the background" (home and onboarding alike) are one name each |
| CONV-PD-08 | applies: the status, service and prompt tables above; the panel hold is MIRROR's `PanelHold` table (PHONE-12) |
| CONV-PD-09 | applies: every attention item names its fix (Turn on, Open Shizuku or Get Shizuku, Allow, Retry) and "No Macs paired yet." names the empty state |

## Assumptions

- Android 13+ (API 33) for the runtime notification permission; the app targets API 36 and uses Shizuku at shell UID.
- Shizuku is installed and started by the person; Contigua cannot start it or grant itself the permission.
- The shell user service is the only server; there is one app process and one foreground service.
- The Material 3 dynamic colour is supplied by the system; on a device without dynamic colour the theme falls back to the app's own palette.
- A phone has one screen (display 0); a foldable's inner/outer change is Android's own configuration change.
- The person's lock screen and screen timeout are theirs; Contigua never changes them.

## Non-goals

- The onboarding pager's copy and the pairing flow itself (UX.md, pairing.md); this spec covers the permissions it asks and the prompt's surfaces.
- Notifications, media, Now Playing and files forwarding as content (notifications.md, media.md, files.md); this spec covers the phone's own home, service and notifications for them.
- Starting, installing or granting Shizuku for the person beyond the one button each.
- A phone-side notification-sharing switch: the Mac's per-phone switch is the only one (settings.md SET-DEV-09).
- A settings screen of its own: the three switches and the list are the whole home.
- Running without Shizuku, or a second server/session.
- Any change to the lock screen, screen timeout or another app's state.

## Open questions

- [NEEDS CLARIFICATION] **The ongoing notification is not dismissable** — CONV-AND-02 says a notification Contigua posts is dismissable; a foreground service's is ongoing by Android's requirement (misses.md M9). Recommended: keep it and record the deviation in CONVENTIONS.md, with the pairing and ring notifications as the dismissable ones.
- [NEEDS CLARIFICATION] **A denied notification permission hides the pairing prompt** — with notifications denied and the app in the background, the notification is never posted and the in-app card is not on screen; the Mac waits 120 s and says nobody answered (CONV-AND-03; the same gap pairing.md records as M4, misses.md M8). Recommended: an "Allow notifications to pair" attention item on the home while a prompt is pending, and the Mac's sheet says "Open Contigua on your phone to allow it." after 20 s.
