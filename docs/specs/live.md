# Live updates

Prefix: `LIVE`. Owner docs: [design/notify.md](../design/notify.md) § "Live Updates", [design/mac-redesign.md](../design/mac-redesign.md) §3.8, [PROTOCOL.md](../PROTOCOL.md) § "Notifications + media", [UX.md](../UX.md) §4. Last reviewed: 2026-11-08, against `f0f1571f` (v149). Scope refined by the person on 2026-11-08: persistent notifications are a first-class source and on by default, the source rules are brand-neutral, and timers, alarms, deliveries and rides come first.

## Purpose

The phone's ongoing activities, on the Mac: a timer counting down, an alarm ringing or coming up, a ride or delivery moving, a workout, a download. They come from any app and from any phone brand. Most apps still post a plain persistent notification rather than Android's Live Update, so both are first-class sources. Android's promoted Live Update is simply the most exact one, and brand-specific extras (Samsung's Now Bar fields and the like) only enrich what the standard notification already gives. A live item is a menu-bar control and a card, not another banner: it updates in place, its countdown ticks on the Mac with no traffic, and its card carries the phone's own actions. This surface owns the live item's source rules, its life, its card and its short history. The notification surface still owns the forwarding switch, banners, the mute list and the click target; the panel owns where the rows sit (`PANEL-15`). The visual form (one control per item, one control with a stack, or an island) is the prototype round's decision, not this spec's.

## User stories

| ID | Priority | Story |
|---|---|---|
| LIVE-S1 | P1 | As a person, I want a timer I started on the Mac to run in the phone's Clock app, and a timer or stopwatch running on the phone to appear on the Mac with a countdown, pause and stop, so that I can watch and control it without picking up the phone. |
| LIVE-S2 | P1 | As a person, I want an Android 16 Live Update to appear as a live item that updates in place, so that a delivery, ride or navigation is glanceable on the Mac. |
| LIVE-S7 | P1 | As a person, I want my next alarm to show on the Mac, and a timer or alarm that is ringing on the phone to show as ringing with Dismiss (and Snooze for an alarm), so that I can silence it from the Mac. |
| LIVE-S8 | P1 | As a person, I want live items to work the same on any Android phone, so that the feature does not depend on one brand's private fields. |
| LIVE-S3 | P1 | As a person, I want an app's persistent notification that shows an activity (a delivery, a ride, a download, a workout) to become a live item automatically, and to switch any app off, so that the many apps that never adopted Android's Live Updates still reach the Mac. |
| LIVE-S4 | P2 | As a person, I want several live items at once, so that a timer and a delivery do not replace each other. |
| LIVE-S5 | P3 | As a person, I want a short history of finished items ("Delivered 12:40"), so that I can see what just ended. |
| LIVE-S6 | P2 | As a person, I want a card that draws its own layout to show its status, countdown and progress, and a picture when those are not enough, so that a custom tracker is not invisible. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| LIVE-1 | WHEN the Mac's notification switch for a phone is off THE live surface SHALL show no item, card, history or Start Timer control for that phone, SHALL send no live message, and SHALL clear that phone's live state; WHILE the switch is on THE live surface SHALL take every state from the phone's `notify.post`, `notify.remove` and `notify.snapshot` and SHALL NOT invent one. | e2e `live` `[LIVE-1]`; K1 `LiveGateTest`; K2 `LiveCardTests.testSwitchOffClearsItemsAndControls` |
| LIVE-2 | THE phone SHALL mark an item promoted only when `FLAG_PROMOTED_ONGOING` is set; it SHALL send every live field it can read (progress, segments, points, tracker and start/end icons, chip, chrono, countDown) and SHALL NOT infer promotion from a style, a category, a progress bar or its own guess. | K1 `LiveSourceTest` (`promoted means the flag, never a style`); K1 `NotifyLiveTest`; e2e `live` `[LIVE-2]`; emulator `live-promote`; phone probe |
| LIVE-3 | THE phone SHALL send an app's ongoing notification as a live item **by default**, without an allowlist, WHEN a pure classifier finds it is an activity: at least one strong signal (a determinate progress maximum above 0 or a ProgressStyle; a chronometer or countdown, from the extras or from a `Chronometer` in its views (LIVE-23); a category in {navigation, transport, progress, alarm, event, workout, location_sharing, stopwatch}; a title or text that changes across posts; a promoted flag) and no disqualifier. An advertised action is a weak signal: it never qualifies a notification on its own, because service chrome often carries Disconnect or Stop. It SHALL NOT send: a notification whose only signal is `FLAG_FOREGROUND_SERVICE`; one in category `service`, `status`, `system` or `sys`; one carrying `EXTRA_MEDIA_SESSION` (Now Playing owns it); a `CallStyle` notification (calls own it); a group summary; or one whose title and text stayed unchanged for its whole life with no progress and no clock (service chrome such as VPN, sync or "running", even with a Disconnect or Stop action). WHEN the person switches an app off THE phone SHALL send none of its live items until it is switched on again; a promoted Live Update follows the same per-app switch. The classifier SHALL be one pure function from the notification's facts to `activity` or a closed reason, logged with that token and never with content. | K1 `LiveSourceTest` (each signal, each disqualifier, the per-app off, the unchanged-text rule); K1 `LiveClassifierTest` (fixtures for a delivery, a ride, a download, a timer, a VPN, a sync, a media and a call notification); e2e `live-legacy` `[LIVE-3]`; K2 `LiveSettingsTests.testAppsAreOnByDefaultAndCanBeSwitchedOff`; the survey (LIVE-26) |
| LIVE-4 | THE live settings list SHALL be per phone and list every package seen live, with its switch (on by default), search by app name or package, and the reason a package's last notification was not shown when the classifier refused it; a switched-off package SHALL be shown as off, not removed from the list. | K2 `LiveSettingsTests` (the rows, the default on, the search, the per-phone store, the refusal reason); e2e `settings` `[LIVE-4]` |
| LIVE-5 | WHEN any Clock app posts a running timer or stopwatch THE phone SHALL send it as a live item even when it has no title, no text and a custom view, with a kind (`timer`, `stopwatch`, `alarm`) and the actions it advertises. THE phone SHALL find its deadline from, in order: `EXTRA_SHOW_CHRONOMETER` with `EXTRA_CHRONOMETER_COUNT_DOWN` and `when`; a running `Chronometer` in any of its views (LIVE-23); a timer the Mac started. WHEN it finds one THE Mac SHALL run a local countdown; IF it finds none THEN the Mac SHALL show the card and the actions with the countdown marked unavailable and SHALL NOT invent a deadline. | K1 `LiveTimerTest` (timer, stopwatch, each deadline source, no deadline); e2e `live-timer` `[LIVE-5]`; emulator `live-clock` (Google's Clock); phone probe: Samsung Clock's countdown view gave a deadline within 1 s (2026-11-06) |
| LIVE-6 | WHEN the person chooses Start Timer… THE Mac SHALL ask for a length of 1–86400 seconds and an optional label, send one `live.timer.start`, show a pending state, and then show the phone's answer; THE phone SHALL start the default handler of `AlarmClock.ACTION_SET_TIMER` with `EXTRA_LENGTH`, `EXTRA_MESSAGE` and `EXTRA_SKIP_UI:true`; IF no app handles the intent or the phone refuses it THEN the phone SHALL answer with a reason and the Mac SHALL show that sentence and leave no running timer claim. | K1 `LiveTimerTest` (validation, the intent, the refusal); K2 `LiveTimerMacTests.testStartTimerIsPendingThenAnswered`, `testNoClockAppDisablesTheControl`; e2e `live-timer` `[LIVE-6]`; `untested` for a background start on One UI 9 |
| LIVE-7 | THE live card SHALL show only the actions the phone advertised, with the phone's own titles; WHEN the person presses one THE Mac SHALL send `notify.action {id,i}` and show a pending state; THE Mac SHALL send exactly one action per press and SHALL NOT chain actions: a stop that the app offers as Pause, then Reset, is two presses, as on the phone, because the Mac cannot tell which button is Reset without reading its label, in any language and on any brand; IF no `notify.post` or `notify.remove` arrives within 5 seconds THEN the Mac SHALL show "No answer from the phone" and keep the item; the Mac SHALL NOT claim that a timer stopped, paused or reset until the phone reports it. | K1 `LiveTimerTest` (the advertised indices, one action per press); K2 `LiveTimerMacTests.testActionsAreNeverChained`, `testAnUnansweredActionSaysSo`; e2e `notify-actions` `[LIVE-7]` |
| LIVE-8 | WHILE a live item has a deadline THE Mac SHALL redraw its countdown at most once a second from a monotonic local deadline, SHALL NOT ask the phone for a tick, and SHALL recompute the remaining time on wake; WHEN the deadline passes THE Mac SHALL show `0:00` and "Waiting for the phone" until the phone removes or updates the item. The phone SHALL send its own `now` with a deadline, or a remaining duration, so the Mac does not depend on the two clocks agreeing. | K1 `LiveTimerTest.testClockSkewIsCancelled`; K2 `LiveTimerMacTests.testTheCountdownUsesALocalDeadline`, `testWakeRecomputesAndWaits`; e2e `live-timer` `[LIVE-8]` |
| LIVE-9 | WHEN a later post for a live id arrives THE Mac SHALL update the item in place at most once a second per id, the newest state winning, and SHALL NOT present a banner; a scheduled trailing update SHALL deliver the newest state at the boundary. | K1 `NotifyLiveTest` (the rule); K2 `NotifyLiveMacTests.testUpdatesInsideOneSecondAreCoalescedAndTheNewestWins`; e2e `notify-media` `[LIVE-9]` |
| LIVE-10 | WHEN a live id first arrives THE Mac SHALL present one banner as `NOTIFY-5` and add one item; WHEN the phone removes the item THE Mac SHALL remove the item and its control (menu-bar item or island pill); a session end SHALL follow LIVE-15, not remove the item at once. | e2e `notify` `[LIVE-10]`, `notify-vm`; K2 `NotifyLiveMacTests.testEndRemovesTheRowAndAPendingUpdate` |
| LIVE-11 | WHEN the person opens a live item THE Mac SHALL show one card with the app, the title and text, the state (live, paused, ended), the progress (segments and points when reported, else one bar), the chip, the countdown, the phone's actions and Open; Open SHALL run the phone's notification click as `NOTIFY-8`; WHEN the phone sent a snapshot THE card SHALL show it; WHEN a field is absent THE card SHALL omit it; the card SHALL be one element per item and SHALL NOT be the only place a state is recorded. | K2 `LiveCardTests` (every field, the omissions, the one card per id, Open); e2e `live` `[LIVE-11]`; e2e `live-vm` (a real card in the VM); `untested` for the final visual form until the prototype |
| LIVE-12 | THE live surface SHALL hold at most 8 live items per phone, in the phone's order or by start time, and SHALL give each one its own menu-bar control, its own row in a stack, or its own place in the island; WHEN more than 8 are live THE Mac SHALL keep the 8 newest and show "N more" with the rest in the panel; with 2+ items every item SHALL remain reachable — its control or row is visible, and opening it shows its card — on a Mac with or without a notch. | K2 `LiveMenuBarTests` (8, the order, "N more", 2+ controls); e2e `live-multi` `[LIVE-12]`; `untested` for the notch and menu-bar overflow |
| LIVE-13 | WHEN an item ends THE Mac SHALL add it to an in-memory history of at most 20 items per phone with its app, label, end time and a closed reason (ended, lost, stopped); the history SHALL survive a disconnect and SHALL be cleared on quit, when the phone is forgotten, or when the notification switch is turned off; it SHALL never be written to disk, a log or a crash report. | K1 `LiveHistoryTest` (the cap, the reasons, the clears); K2 `LiveHistoryMacTests` (the rows and the memory-only store); e2e `live-history` `[LIVE-13]` |
| LIVE-14 | WHEN the person hides a live card THE Mac SHALL hide its control (menu-bar item or island pill) and card for the session, SHALL NOT send `notify.dismiss`, SHALL NOT stop the phone's timer, and SHALL keep the item's LIVE row in the panel (`PANEL-15`); the control SHALL return only when the person shows it from that row or the phone ends the item; Stop SHALL use only the phone's advertised actions. | K1 `LiveStateMachineTest.testHideIsNotStop`; K2 `LiveCardTests.testHideDoesNotDismissOrStop`; e2e `live` `[LIVE-14]` |
| LIVE-15 | WHEN the session ends THE Mac SHALL freeze each item for 5 minutes with "Last seen …", SHALL keep counting a known deadline, and after 5 minutes SHALL move it to history as lost and remove it; WHEN the session returns THE phone's snapshot SHALL reconcile: a still-present id updates in place with no banner, an absent id ends as lost, and a new id starts. | K1 `LiveStateMachineTest` (every transition); K2 `LiveCardTests.testDisconnectFreezesThenLoses`, `testReconnectReconcilesFromTheSnapshot`; e2e `live-reconnect` `[LIVE-15]` |
| LIVE-16 | WHEN the phone sleeps THE Mac SHALL keep the item, because the Clock keeps running; WHEN the Mac sleeps and wakes THE Mac SHALL recompute each deadline and SHALL show `0:00` and "Waiting for the phone" if it passed; it SHALL NOT end an item on either sleep. | K2 `LiveTimerMacTests.testPhoneSleepDoesNotEndTheTimer`, `testMacSleepRecomputes`; e2e `live-timer` `[LIVE-16]` |
| LIVE-17 | WHEN a live item's card has a custom view and no plain progress, chronometer or title/text THE phone SHALL render `contentView`, else `bigContentView`, to a bitmap off the main thread, only when a hash of the rendered bytes changes, at most 512 px on the long side and 200 KiB; IF the render fails or exceeds the cap THEN the Mac SHALL show the app, its title/text and actions without a picture; the Mac SHALL keep the bitmap in memory only and wipe it when the item ends. | K1 `LiveSnapshotTest` (the caps, the hash, every failure); emulator `live-snapshot`; e2e `live-legacy` `[LIVE-17]`; `untested` for a real Clock render |
| LIVE-18 | THE Mac SHALL keep every title, text, chip, action title and snapshot in memory only; the phone and the Mac SHALL log ids, packages, lengths, flags and closed states only — never a title, text, chip, action title or bitmap; the snapshot SHALL never be written to disk, the share log or a crash report; the history SHALL be memory only. | e2e `live` `[LIVE-18]` (no content in any log); K1 `LiveSnapshotTest`; K2 `LiveCardTests.testRecordsCarryOnlyFacts` |
| LIVE-19 | THE live surface SHALL make each item and each action one accessibility element with the app, state and remaining time; progress SHALL be text as well as a bar; state SHALL not be conveyed by colour alone; Tab and ⇧Tab SHALL reach every control in reading order; Reduce Motion SHALL replace the card's open and close animation with an instant change and SHALL NOT stop the countdown; Reduce Transparency SHALL replace the card's material with a solid fill. | K2 `LiveCardTests.testAccessibilityLabelsAndOrder`, `testReduceMotionKeepsTheCountdown`; e2e `live-vm` (a VoiceOver pass by review); `untested` for full VoiceOver |
| LIVE-20 | WHILE no live card is on screen THE Mac SHALL run no 1 Hz redraw for it; WHILE a card is visible THE Mac SHALL redraw at most once a second per item, SHALL batch the menu-bar update into the same tick, and SHALL keep the card's frame p95 at or below 21 ms on the e2e rig; the Mac's live store SHALL stay under 16 MiB; the phone SHALL render a snapshot at most once a second per id and SHALL stop when no Mac is connected; neither side SHALL poll. | K2 `LiveTimerMacTests.testNoTickWhenHidden`; e2e `nfr` `[LIVE-20]` (the 21 ms p95); `untested` for phone power |
| LIVE-21 | IF a phone cannot report live items (no listener grant, an API or OEM limit, no Clock app, a system that never promotes) THEN the phone's live settings SHALL show a disabled row with the phone's reason and the one fix, and the panel SHALL NOT show an empty LIVE section; the reason SHALL be a sentence, never an internal code, and the feature SHALL not be hidden without one. | K2 `LiveCardTests.testUnsupportedPhoneShowsTheReason`; e2e `live` `[LIVE-21]`; `untested` for One UI 9 |
| LIVE-22 | THE surface SHALL use "LIVE" for the panel section, "Start Timer…", "Pause", "Resume", "Stop", "Reset", "Open" and "History" as one name each; an action's label SHALL be the phone's advertised title; "Stop" SHALL exist only when the phone advertises it; an error SHALL name the next step. | K2 `LiveCardTests.testNamesAndActionLabels`; review of `live.md` against `CONVENTIONS.md` |
| LIVE-23 | THE phone SHALL read a live item's fields from the standard notification first (title, text, sub text, big text, progress, ProgressStyle, chronometer, `when`, actions, icons, colour), and WHEN the notification carries a custom layout or a `RemoteViews` in its extras THE phone SHALL inflate it off-screen in its own process and read, through public view APIs only, each visible `TextView`'s text, each `Chronometer`'s base and direction (a deadline: wall now + base − elapsedRealtime now), each `ProgressBar`'s progress and maximum, and each `ImageView`'s drawable; it SHALL use no hidden API and no reflection into `RemoteViews`. Brand extras (Samsung's `android.ongoingActivityNoti.*`, and other brands' equivalents when documented) MAY add a short label, a colour or an icon, and SHALL NOT be required by any other row: a phone without them SHALL produce the same item, minus those enrichments. | K1 `LiveExtractTest` (a fixture per layout: standard, custom with a chronometer, custom with a progress bar, a RemoteViews in the extras); emulator `live-extract` (Google's Clock and the debug poster's shapes); phone probe (Samsung Clock, 2026-11-06); review: no `@hide` call and no reflection in the extractor |
| LIVE-24 | THE phone SHALL send the next alarm as one live item of kind `alarm` from `AlarmManager.getNextAlarmClock()`, refreshed on `ACTION_NEXT_ALARM_CLOCK_CHANGED`, with its time only (no label, no repeat rule) and Open running its show intent; WHEN no alarm is set THE item SHALL not exist; the Mac SHALL show it with the time and a relative "in 7 h 12 min" that it computes locally. | K1 `LiveAlarmTest` (set, changed, cleared); K2 `LiveCardTests.testNextAlarmShowsTimeAndRelative`; emulator `live-alarm` |
| LIVE-25 | WHEN a timer item's deadline passes and its card disappears, or its deadline is more than 1 s past while its card stays (Google's Clock keeps the card in category `alarm` with no full-screen intent), or a Clock app posts a ringing timer or alarm (a full-screen intent in category `alarm`), THE Mac SHALL show the item as ringing on that phone with Dismiss, and Snooze for an alarm; Dismiss SHALL send the phone's advertised action when there is one, else the phone's shell-UID server SHALL start `AlarmClock.ACTION_DISMISS_TIMER` or `ACTION_DISMISS_ALARM`, and Snooze `ACTION_SNOOZE_ALARM` (from the app process Google's Clock ignored `DISMISS_TIMER` on the emulator, 2026-11-08, while the shell's start stopped it); the item SHALL end when the phone reports the ringing stopped or after 10 minutes. | K1 `LiveRingTest` (each trigger, each action, the bound); e2e `live-timer` `[LIVE-25]`; phone probe: Samsung's ringing timer is a full-screen screen and its card leaves; `DISMISS_TIMER` stopped it within 2 s (2026-11-06) |
| LIVE-26 | IN debug builds only THE phone SHALL be able to record a survey of the ongoing notifications it sees: one line per new or changed ongoing notification with its package, the classifier's verdict and reason, and its shape (style, flags, category, progress and chronometer presence, custom-view presence, action count, brand-extra key prefixes), never a title, text, label, action title or extra value; the survey SHALL stay on the phone until pulled and SHALL never enter the repository. | K1 `LiveSurveyTest` (the line carries no content); review of the debug source set |

## States and events

One live item's life. The phone's posts are the only source; the Mac's countdown is a local clock. "Hidden" is the person's view, not the phone's state.

| State | Event | Result |
|---|---|---|
| Absent | the first post of an allowed id | Live; one banner (LIVE-10); one control (menu-bar item or island pill) |
| Absent | a legacy card for an app that is not allowed, or with no positive signal | ignored; no item, no banner |
| Absent | a media session, a `CallStyle` notification or a group summary | ignored; the media or call surface owns it |
| Live | a later post of the same id | Live; fields replaced; at most once a second; no banner |
| Live | a post that says paused | Paused; the countdown stops at its last value; the phone's Resume and Reset actions replace Pause |
| Paused | a post that says running | Live; a new deadline starts from the phone's `now` |
| Live or Paused | the phone removes it | Ended; the control leaves; a history row ("Delivered 12:40") |
| Live or Paused | the person hides it | Hidden; no `notify.dismiss`, no stop; the phone keeps running; the control and card go, the panel's LIVE row stays |
| Hidden | a later post | Hidden; the fields and the panel row update silently, with no control |
| Hidden | the phone removes it | Ended; the history row appears |
| Hidden | the person shows it from the panel | Live or Paused with the current fields |
| Live | the person presses an action | Live with a pending state; the phone's next post or removal decides the result |
| Live | 5 seconds pass with no post or removal after an action | Live with "No answer from the phone"; the item stays |
| Live or Paused | the session ends | Stale; the card freezes with "Last seen …"; a known deadline keeps counting |
| Stale | the session returns and the snapshot names the id | Live; fresh fields; no banner |
| Stale | the session returns and the snapshot does not name the id | Ended (lost); the control leaves; a history row |
| Stale | 5 minutes pass | Ended (lost); the control leaves; a history row |
| Stale | a known deadline passes | Stale with `0:00` and "Waiting for the phone" |
| Live, Paused or Stale | the phone sleeps | unchanged; the Clock is still running |
| Live, Paused or Stale | the Mac sleeps and wakes | unchanged; a countdown is recomputed from its deadline |
| Live or Paused | the person turns the phone's switch off | Gone; all items and controls clear; no history |
| Live or Paused | the person switches the app off | Gone; no history |
| Ended | the 21st history row | the oldest history row drops |
| Ended | quit or the phone is forgotten | the history clears |

Ignored events, stated so nobody builds them: a post for a phone whose switch is off; an update for an id the Mac does not hold; an action for an ended id; a removal for an id already ended; a snapshot id the Mac never held; a live item for an app the person switched off; a notification the classifier refused; a media-session card; a group summary; a call; a second "Start Timer…" while one is pending; a countdown tick from the phone.

## Phone count and connection

| Situation | Live shows |
|---|---|
| 0 phones | No live control, no Start Timer, no history. The settings page says "Pair a phone to see live updates." |
| 1 phone | That phone's items, its per-app switches (every app on by default), its history and its Start Timer. |
| 2+ phones | Only the phone in use has a session, so only its items exist. Each item names its phone; switching phones clears the controls and keeps each phone's switches and history. The panel's section is "Live on <phone>". |
| Connecting | No new items; Start Timer is disabled with "Connecting…"; a previous phone's items are stale for at most 5 minutes. |
| Offline | Items freeze with "Last seen …"; after 5 minutes they move to history as lost; Start Timer is disabled. |
| Connected | Items follow `notify.post`, `notify.remove` and `notify.snapshot`; no polling. |
| Key rejected (Pair again) | No session and no items; the Deck's banner carries Pair again. |
| Missing listener grant | "Allow notification access on the phone." under the live settings, with the same one fix as `NOTIFY-2`; no items. |
| Phone that never promotes | Nothing changes for the person: persistent notifications are live items anyway (LIVE-3). |
| No Clock app | Start Timer is disabled with "No Clock app handles timers on this phone." |
| Phone that can't run the feature (API or OEM) | A disabled row with the reason; the panel shows no empty LIVE section, and the row is never hidden without the sentence. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | applies: LIVE-4 — ⌘F focuses the per-app list's search and selects its text. |
| CONV-MAC-02 | applies: no key of ⌘W/⌥⌘W/⌘M/⌘Q/⌘,/⌘H is taken; the live card is a panel and Esc closes it, and ⌘W closes a window if the card is shown in one. |
| CONV-MAC-03 | applies: LIVE-11 and LIVE-19 — Esc closes the card without acting, Return runs the default action (Open), Tab and ⇧Tab move through every control. |
| CONV-MAC-04 | applies: the timer's label field and the per-app search are standard fields (⌘A, ⌘C/⌘X/⌘V, ⌘Z/⇧⌘Z, ⌥←/→, ⌘←/→). |
| CONV-MAC-05 | n/a: nothing zoomable. |
| CONV-MAC-06 | applies: Start Timer…, Open, Pause, Stop and History are visible in the menu or have help tags; no hidden shortcut. |
| CONV-MAC-07 | n/a: no shortcut is reused. |
| CONV-MAC-10 | applies: a live control (menu-bar item or island pill) toggles its panel (a single card, the stack, or the island's expanded card); a row in the stack opens its card; outside click or Esc closes it; a secondary click opens the app's own menu; the existing main status item keeps `PANEL-*`. |
| CONV-MAC-11 | applies: LIVE-10 and LIVE-11 — one item per live id and one card per item; opening it again brings the same card forward. |
| CONV-MAC-12 | applies: the card is anchored to its control and never opens off-screen; a stack panel remembers its size within the screen. |
| CONV-MAC-13 | n/a: the live surface adds no View or Window menu item and no full-screen command. |
| CONV-MAC-14 | applies: the card lays out at the widths the prototype allows; rows, the progress and the countdown never clip, and a resize never hides an action. |
| CONV-MAC-15 | n/a: the live card is not a window whose close quits the app. |
| CONV-MAC-16 | applies: the timer name field and the per-app search use the system's own copy, paste and Services; no drop target is added. |
| CONV-MAC-20 | applies: LIVE-11 — the card and the progress render in light and dark, with the accent colour and Increase Contrast; the phone's segment colours are never the only cue. |
| CONV-MAC-21 | applies: LIVE-19 — every item, action and row has a VoiceOver label and role, and the focus order follows the reading order. |
| CONV-MAC-22 | applies: LIVE-19 — Reduce Motion stops the appear/disappear animation but not the countdown; Reduce Transparency makes the card solid. |
| CONV-MAC-23 | applies: LIVE-11 and LIVE-19 — text follows the system size where SwiftUI allows; progress and state are text as well as colour. |
| CONV-MAC-24 | applies: the main notification switch is the permission gate (LIVE-1); Start Timer asks the phone, not the Mac, and the first banner follows `NOTIFY-18` for Focus and DND. |
| CONV-MAC-25 | applies: LIVE-11 — every row, action and control has a hover highlight and a pressed state; a disabled Start Timer is dimmed neutral. |
| CONV-MAC-26 | applies: LIVE-11 — one side inset and one 8/12/16 pt rhythm in the card; the reason for a disabled control sits with it. |
| CONV-AND-01 | n/a: no phone navigation. |
| CONV-AND-02 | applies: LIVE-6 — the phone starts the Clock's own timer and posts no new Contigua notification; the Clock's card follows the system theme. |
| CONV-AND-03 | applies: the listener grant is asked for in context by the main switch (`NOTIFY-2`); `SET_ALARM` is a normal permission; a missing Clock app disables only Start Timer with a sentence (`LIVE-21`). |
| CONV-AND-04 | applies: LIVE-6 and LIVE-14 — the only phone change is the timer the person asked for; hiding a card or ending the Mac session changes no phone setting, the lock screen stays locked and the phone's DND is untouched. |
| CONV-PD-01 | applies: the phone-count table above (0, 1, 2+; per phone items, per-app switches and history). |
| CONV-PD-02 | applies: the table above (connecting, connected, offline, key rejected, no listener, no promotion, no Clock, API/OEM limit); a live feature that cannot work is disabled with its reason. |
| CONV-PD-03 | applies: LIVE-6, LIVE-7 and LIVE-8 — Start Timer and every action show a pending state and then the phone's answer; a refusal shows the phone's sentence; a countdown never claims the phone confirmed an end. |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value; the per-app switches are local. |
| CONV-PD-05 | applies: LIVE-18 — no title, text, chip, action title or bitmap in a log, a crash report or a file; ids, packages, lengths and states only. |
| CONV-PD-06 | applies: LIVE-20 and `docs/NFR.md`; the countdown is local and no live path polls. |
| CONV-PD-07 | applies: LIVE-22 — Live, Start Timer…, Pause, Resume, Stop, Reset, Open and History are one name each across the menu, the card, the panel, Settings and the docs. |
| CONV-PD-08 | applies: the states-and-events table above (`LIVE-1`–`LIVE-21`), with the ignored events named. |
| CONV-PD-09 | applies: LIVE-6 ("Start Timer…" names the result), LIVE-7 (an action is the phone's title, not "OK"), LIVE-21 (the reason says what to do next). |

## Assumptions

- The phone runs API 30 or later; a `NotificationListenerService` is granted at shell UID when the Mac's switch turns on (`design/notify.md`).
- The main notification switch is the only person-facing gate; the per-app switches are the Mac's per-phone setting, sent to the phone so it sends nothing for a switched-off app; they are not a phone permission. The listener grant remains all-or-nothing at the OS level.
- "Promoted" means `FLAG_PROMOTED_ONGOING` was set by the system. The app never infers it from a style, a category or a progress bar.
- A legacy card is a notification the phone already holds; the phone does not create one. It is forwarded only for an allowed package with a positive signal (`LIVE-3`).
- A timer has a deadline only when the notification reports one, or when the Mac started it. AOSP DeskClock's custom view does not report one; the Mac shows its card without a native countdown (`LIVE-5`).
- `AlarmClock.ACTION_SET_TIMER` resolves to the phone's default Clock app; the phone can start that activity while the session is live. The background-start question is a spike (`LIVE-6`).
- The live card is AppKit/SwiftUI in the app process. There is no ActivityKit path: the app targets macOS 26 and ActivityKit's macOS support is 27.3 beta.
- The countdown reads a deadline and ticks locally; the phone sends its `now` with a deadline (or a remaining duration) so clock skew cancels.
- The wire's `live` object and the start-timer command are `PROTOCOL.md`'s. The implementation brief extends them with `paused`, `segments`, `points`, the tracker and start/end icons, the phone's `now`, and `live.timer.start`/`live.timer.state`; this spec does not define a second protocol.
- The visual form — one menu-bar control per item, one control with a stack, or an island — is chosen by the prototype round; the requirements are written to hold for all three.
- The phone's Clock notification may be a custom `RemoteViews` with no title, text, progress or chronometer extras; the Mac does not reflect into `RemoteViews` or OCR a rendered picture.

## Non-goals

- Media, Now Playing, artwork and media controls: the media surface and `PANEL-14`.
- Calls and messaging: feature 3; a `CallStyle` notification is never a live item here.
- Foreground-service chrome: VPN, sync, backup, keyboards, batteries, "running" and similar notifications are never live items.
- Notification banners, the mute list and the forwarding switch: `notifications.md` (`NOTIFY-*`). This surface adds live items to the same gate; it does not change banner rules.
- A notification centre or a durable history: the history is at most 20 per phone, in memory, cleared on quit.
- Posting a live item back to the phone, or changing the phone's Clock, alarm, DND or lock settings.
- A desktop widget in this round. The research says an ad-hoc app's WidgetKit extension is unproven; a VM spike must prove registration before the plan promises one.
- macOS Live Activities / ActivityKit: the app targets macOS 26, and ActivityKit for Mac apps is macOS 27.3 beta.
- Reading a custom `RemoteViews` by reflection, OCR or the Clock app's private provider.
- A phone-side UI beyond the Clock's own timer screen; no new Contigua notification on the phone.
- Any third-party service: nothing leaves the two devices.

## Open questions

- Resolved 2026-11-06 (phone probe): a custom-view timer does give a deadline; the extractor reads it from the inflated `Chronometer` (LIVE-5, LIVE-23). "Unavailable" remains only for a timer with no chronometer at all.
- Resolved 2026-11-08: no synthetic Stop. AOSP's running timer offers Pause and Add 1 min; stopping it is Pause, then Reset, two presses on the Mac as on the phone (LIVE-7). Chaining them would mean matching a button's label, which breaks in other languages and on other brands. A ringing timer's Dismiss stays (LIVE-25), because it uses a public intent.
- Resolved 2026-11-08 (the person): hiding is only a view change and leaves the phone's timer running; stopping uses the phone's own buttons (LIVE-14).
- Resolved 2026-11-08 (the person): the history is 20 items per phone, in memory, survives a disconnect and clears on quit (LIVE-13); a durable history would need its own opt-in and expiry.
- Resolved 2026-11-08 (the person): there is no allowlist. Every app's activity-like persistent notification is on by default, and the person switches apps off (LIVE-3, LIVE-4).
- Resolved 2026-11-08 (the person: timers and alarms come first): the next alarm is a P1 item (LIVE-24), and a ringing timer or alarm shows with Dismiss and Snooze (LIVE-25).
- Resolved 2026-11-08: superseded by on-by-default for every app (LIVE-3).
