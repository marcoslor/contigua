# Live updates on the Mac: what Android promotes, what One UI shows, and what macOS can draw

Status, 2026-11-06: **research for the requirements gate. No product code, no device run.** The emulator budget is zero and the person's phone is off limits, so this note is built from published documentation, AOSP source read at the `android16-qpr1-release` branch, Apple's documentation, and Samsung's support pages. Device-dependent claims are marked **(unverified)** and are the phone probe's job.

## What today's path does, and what it cannot see

PocketDeck forwards a notification only when it is **ongoing and promoted** (`FLAG_PROMOTED_ONGOING`), and then reads `progress`, `chip`, `chrono` and `countDown` from the notification's extras (`NotifyEvents.promoted`, `NotifyEvents.liveWire`, `PdNotificationListener.liveFor`). Everything else ongoing is treated as service chrome and dropped. A notification with neither a title nor text is dropped as contentless (`NOTIFY-3`).

That rule cannot see a stock Android timer. AOSP DeskClock's running timer is ongoing and has a custom `RemoteViews` layout, and on Android N and later it sets **no title and no text** in the extras; the numbers live only inside the custom view. It is therefore skipped twice: as unpromoted ongoing chrome, and as contentless. The same is true of the stopwatch. This is the central gap for the "timers first" story.

## Android 16 Live Updates

### What promotion buys

A promoted notification is expanded by default and cannot be collapsed. The system shows it at the top of the notification drawer, on the lock screen and the always-on display, and as a status-bar chip. The chip is the only part that is visible while another app is in front.

### The rules, version by version

| Android release | What the platform does | What an app must do |
|---|---|---|
| 16 (API 36) | Adds `Notification.ProgressStyle` and the `FLAG_PROMOTED_ONGOING` flag, but the AOSP `ui_rich_ongoing` flag is off. `hasPromotableCharacteristics()` exists and, in this branch, falls back to the older rule: ongoing, titled, no custom view, not a group summary, and **colorized** (an ongoing `CallStyle` is the exception). The per-app `canHavePromotedNotifs` preference defaults to the same off flag. | Nothing public can request promotion. AOSP promotes nobody by default; an OEM build could flip the preference. |
| 16 QPR1 (API 36.1) | Turns the feature on. Adds `POST_PROMOTED_NOTIFICATIONS`, `EXTRA_REQUEST_PROMOTED_ONGOING`, `Notification.Builder#setRequestPromotedOngoing`, `Notification#isRequestPromotedOngoing` and `NotificationManager#canPostPromotedNotifications`. The guide also names `Settings.ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS`; the 36.1 Settings API diff did not list it when checked, so treat it as a doc claim (unverified). | The full eligibility list below. |
| 16 QPR2 (minor SDK, still 36.1) | No published Live Update behaviour change. The release notes cover dark theme, icon shapes, media and security. | Same as QPR1. |
| 17 (API 37) | Adds `Notification.MetricStyle` (up to three metrics) and semantic colours for `Notification`, `Metric`, `ProgressStyle.Segment` and `ProgressStyle.Point`. No published change to the promotion rules. | Same as QPR1, plus the new style and colour annotations. |

The QPR1 source is explicit. With `uiRichOngoing()` on, `Notification.hasPromotableCharacteristics()` returns:

- `isRequestPromotedOngoing()`
- `isOngoingEvent()`
- `hasTitle()`
- `hasPromotableStyle()`: no style (Standard), `BigTextStyle`, `CallStyle`, `MetricStyle` or `ProgressStyle`
- not a group summary
- no custom views
- **not** colorized

`NotificationManagerService.fixNotificationWithChannel` adds the channel rule (`importance > IMPORTANCE_MIN`) and checks `POST_PROMOTED_NOTIFICATIONS` **last**, after the eligibility test, so a promotion attempt is recorded in app-ops. A listener cannot call `canPostPromotedNotifications()` for another app; it is a method on the posting app's own `NotificationManager`. The portable observation is the flag the system already set.

The published guide lists the same rules, plus: the channel must not be `IMPORTANCE_MIN`; the notification must not be a group summary; the app must hold `POST_PROMOTED_NOTIFICATIONS` **in addition to** `POST_NOTIFICATIONS`; and OEMs may add criteria. The permission's protection level is `normal|appops`.

Two separate questions are easy to conflate:

- `hasPromotableCharacteristics()` says whether the **notification shape** qualifies. It ignores the person's app setting and the channel.
- `canPostPromotedNotifications()` says whether **this app** may post a promoted notification now, which includes the person's per-app switch.

A listener can read `hasPromotableCharacteristics()` on someone else's `Notification` object, but that only describes the shape. It still needs the actual flag to know what the system did.

### ProgressStyle's payload

`ProgressStyle` (API 36) carries:

| Piece | API | Notes |
|---|---|---|
| Progress and maximum | `setProgress(int)`, `getProgress()`, `getProgressMax()` | The maximum is the sum of the segment lengths, or 100 when no segments exist. The builder's ordinary `setProgress` extras are overridden by the style. |
| Segments | `addProgressSegment`, `setProgressSegments`, `Segment(length, color)` | Length is relative, not a unit; each segment can carry a colour and an id. |
| Points | `addProgressPoint`, `setProgressPoints`, `Point(position, color)` | Positions are relative to the maximum; used for stops or milestones. |
| Tracker icon | `setProgressTrackerIcon(Icon)` | An overlay at the current progress; aspect ratio 2:1 to 1:2; mirrored in RTL. |
| Start and end icons | `setProgressStartIcon(Icon)`, `setProgressEndIcon(Icon)` | Square, cropped to the central square, not mirrored. |
| Styling behind/ahead | `setStyledByProgress(boolean)` | Default true: segments and points ahead of the tracker look different. |
| Indeterminate | `setProgressIndeterminate(boolean)` | When true, progress, segments, points and the tracker are ignored. |

AOSP serialises this into hidden extras on the notification: `android.progressSegments` (an `ArrayList<Bundle>` with `length`, `id`, `color`), `android.progressPoints` (`position`, `id`, `color`), `android.progressTrackerIcon`, `android.progressStartIcon`, `android.progressEndIcon` and `android.styledByProgress`. Those keys are `@hide`, but the strings and the `Bundle` are readable by a listener without reflection. Treat this as an AOSP implementation detail until the probe proves it on One UI.

### The short critical text and the chip

`Notification.Builder#setShortCriticalText` is the text behind the status-bar chip. The guide's rules:

- the chip is at most **96 dp** wide and always carries the small icon;
- text shorter than **7 characters** is shown whole;
- if less than half the text fits, only the icon is shown;
- if more than half fits, as much as fits is shown.

When the chip has no short critical text, `setWhen` drives it: a `when` at least 2 minutes ahead shows a rounded time ("5min" for five minutes), a past `when` shows nothing, and a chronometer is shown while it is positive. A timer's `setUsesChronometer(true)` plus `setChronometerCountDown(true)` is the standard way to put a countdown in the chip.

### What disqualifies a card in practice

- A custom `contentView`, `bigContentView` or `headsUpContentView` (this is the Clock's case).
- `setColorized(true)` on QPR1 and later. Before QPR1 the opposite was required.
- A group summary.
- No `contentTitle`.
- A channel at `IMPORTANCE_MIN`.
- No promotion request on QPR1 and later; no permission; the person's per-app switch off.
- A notification the person dismissed or demoted: the guide tells apps not to repost it.
- OEM additions. Samsung's own allowlist or Now Bar settings can suppress a card that Android promoted.

## One UI: the Now Bar and Live notifications

- **One UI 7 (Android 15)** introduced the Now Bar: a lock-screen and AOD strip for timers, stopwatch, media, calls, Samsung Health, Google Maps, sports and a small set of third parties. On One UI 7 a third-party app needed to be on Samsung's allowlist and declare a Samsung manifest metadata item; media playback worked through `MediaSessionService` without that. The allowlist is not public API. **(unverified)**
- **One UI 8 (Android 16)** integrates Android 16 Live Updates into the Now Bar, so the same promoted notification can appear in the status bar, the notification panel, the lock screen and the AOD. Samsung's support pages describe per-app "Live notifications" switches under **Lock screen and AOD → Now bar → Live notifications**, and say the app's own notification permission, lock-screen setting and Live notifications switch must all be on.
- Reports through One UI 8's life say third-party Live Updates on the stable build are inconsistent: some apps appear, others need **Developer options → Live notifications for all apps**, and some never appear. One UI 8.5 is reported to widen support and to add alarms to the Now Bar. **(unverified)**
- Samsung publishes no developer API for the Now Bar. Its behaviour is a layer above Android's promotion flag; it is not a second promotion mechanism an app can call.

**For the person's Galaxy S25+ on One UI 8 / API 36:** if the build is the base Android 16 platform (not QPR1), AOSP has no general promotion path; if Samsung backported QPR1's policy, the posting app still needs the permission and the request. In both cases the Now Bar's per-app switches can hide the card. The only way to know is to read `FLAG_PROMOTED_ONGOING` from a known card on the phone. The probe in `.agent/liveupd/phone-probe.md` does that without printing any content.

**Recommendation:** do not make the first release depend on promotion on this phone. Treat a promoted card as the best source when it exists, and build the timer path on the Clock's own notification and actions.

## Legacy ongoing cards

### The signals a listener has

| Signal | Where it lives | What it suggests |
|---|---|---|
| `FLAG_ONGOING_EVENT` (`0x2`) | `Notification.flags` / `StatusBarNotification.isOngoing()` | Persistent; not dismissable. |
| `FLAG_FOREGROUND_SERVICE` (`0x40`) | `flags` | A running service is attached. Common for trackers **and** for chrome. |
| `FLAG_NO_CLEAR` (`0x20`) | `flags` | Clear-all skips it. Not a tracker signal by itself. |
| `FLAG_GROUP_SUMMARY` (`0x200`) | `flags` | Never a live card (the notification surface owns groups). |
| `FLAG_PROMOTED_ONGOING` (`0x40000`) | `flags`, API 36 | The system promoted it. The strongest signal. |
| Category | `Notification.category` | `navigation`, `transport`, `progress`, `alarm`, `event`, `workout`, `location_sharing`, `stopwatch`, `call`, `service`, `status`, `system`. Categories are hints, not guarantees; many apps set none. |
| Progress | `EXTRA_PROGRESS`, `EXTRA_PROGRESS_MAX`, `EXTRA_PROGRESS_INDETERMINATE` | A determinate bar (max > 0) or a spinner. The new `ProgressStyle` overrides these extras. |
| Chronometer | `EXTRA_SHOW_CHRONOMETER`, `EXTRA_CHRONOMETER_COUNT_DOWN`, `Notification.when` | A running clock. `when` is the base; countdown says direction. |
| Big text | `EXTRA_BIG_TEXT`, `EXTRA_TITLE_BIG` | A longer body; often a status line, not a tracker. |
| Template | `EXTRA_TEMPLATE` | `BigTextStyle`, `MediaStyle`, `CallStyle`, `ProgressStyle`, `DecoratedCustomViewStyle`, `CustomViewStyle`, or none. |
| Custom views | `contentView`, `bigContentView`, `headsUpContentView` | A layout the app draws itself. The Clock, many delivery and navigation apps. |
| Actions | `Notification.actions` | Pause, Stop, Reset, Lap. A strong sign of a user-controlled ongoing activity. |
| Short critical text | `Notification.getShortCriticalText()`, API 36 | The app's own chip label. |
| Media session | `EXTRA_MEDIA_SESSION` | Media; the Now Playing surface owns it. Never a live card. |
| Channel importance | `NotificationListenerService.Ranking.getChannel().getImportance()` | `MIN` is silent; `LOW` is quiet; `DEFAULT` and above can alert. |

### Tracker or service chrome?

There is no single flag that separates a food-delivery tracker from a VPN. A useful rule is a **score**, not a boolean:

- **Strong positive:** promoted; category in `navigation`, `transport`, `progress`, `stopwatch`, `alarm`, `workout`, `location_sharing`; a determinate progress maximum above 0; a chronometer or countdown; an action such as Pause, Stop or Reset; a short critical text; a `when` in the future.
- **Weak positive:** a title that is not the app name and changes over time; big text that reads like a status ("Arriving in 8 min"); a foreground service plus a location or media-projection type.
- **Negative:** category `service`, `status` or `system`; a package known for VPN, sync, backup, keyboards, batteries, security or launchers; a title that is only the app name or "Running"/"Connected"; no progress, no clock and no actions; a media session; a notification that never changes.
- **Unknown:** a custom view with no title, no text, no category and no actions. This is the Clock and a lot of delivery apps. It cannot be classified from the notification alone; it needs the per-app allowlist or a rendered snapshot.

The flag `FLAG_FOREGROUND_SERVICE` is not a negative on its own: a navigation or workout tracker normally uses a foreground service. The notification's *content* decides, not the service.

**Recommended gate:** a promoted notification follows the main notification switch (it is exact, and Android's own UX rules already restrict it). A legacy card is shown only for an app the person has explicitly allowed, with the list off by default, and only when it has at least one positive signal. A foreground-service notification with none of the positives stays hidden. This is what makes "VPN, sync, running" non-goals enforceable.

### Rendering a card's RemoteViews

`RemoteViews.apply(context, parent)` is public. It inflates the layout and applies the actions. The listener can call it in PocketDeck's process; the `RemoteViews` carries the posting package's name and resource ids, so the package's resources must still be installed. The view set is restricted: `FrameLayout`, `LinearLayout`, `RelativeLayout`, `GridLayout`, `GridView`, `ListView`, `AdapterViewFlipper`, `StackView`, `ViewFlipper`, and the standard `TextView`, `ImageView`, `Button`, `ImageButton`, `ProgressBar`, `Chronometer`, `AnalogClock`, `TextClock`, plus (API 31+) `CheckBox`, `RadioButton`, `RadioGroup` and `Switch`. Descendants are not supported.

Cost and failure modes:

- Inflating and laying out a notification-sized view is cheap in absolute terms (single-digit to low tens of milliseconds is the expected range; unverified) but it allocates a view tree and a bitmap; at 512 × 256 that is about 0.5 MiB at 4 bytes per pixel, and 2 MiB at 1024 × 512. Do it off the main thread, only when the card changes, and recycle the bitmap.
- A collection (`ListView`, `GridView`) needs a `RemoteViewsService` adapter. `apply` alone produces an empty list. A delivery app that puts its steps in a collection renders as a blank strip.
- A `Chronometer` starts when it is attached to a window. A detached `apply` may draw nothing or a static value, not a running clock; a single bitmap cannot tick. **(unverified for each OEM.)**
- `RemoteViews` may contain `PendingIntent` click handlers; `apply` sets them but they are inert without a window. That is fine for a picture; do not expect the picture's buttons to work.
- Possible failures: `InflateException`, `ActionException`, `ClassNotFoundException`, `SecurityException` (package resources), `OutOfMemoryError`, a blank or transparent view, a missing image because a content URI permission was not granted, a layout that assumes the system theme, and RTL or font-scale differences.
- The system itself limits custom views: AOSP warns at **2,000,000 bytes** of estimated memory and strips at **5,000,000 bytes** (`config_notificationWarnRemoteViewSizeBytes`, `config_notificationStripRemoteViewSizeBytes`). A build with the `remove_remote_views` flag on nulls every custom view. OEM values can differ. **(unverified on One UI)**
- `Notification.lightenPayload()` exists for archival and can null views; a listener should treat a missing view as "no snapshot", not as an empty card.

So "lossless picture of the card" is the right ambition but the wrong promise. It is a **snapshot**: good for a status line, a progress bar and a map-like image; not a live countdown and not guaranteed to include collection rows. Send it only when the rendered bitmap's hash changes, cap it at 512 px on the long side and 200 KiB, and keep the title/text from the extras when they exist.

## Timers on Android

### What the Clock apps post

**AOSP DeskClock** (read from the `android16-qpr1-release` branch):

| Activity | Notification | Promotion? |
|---|---|---|
| Timer running | `setOngoing(true)`, category `CATEGORY_ALARM`, channel `TimerModelNotification` at `IMPORTANCE_DEFAULT`, `DecoratedCustomViewStyle` with a custom `chronometer_notif_content` layout, `setChronometerCountDown(true)`, `setChronometer(base, …, running)`, no `setContentTitle`/`setContentText` on N+, actions **Pause** and **Add 1 min**. | Never: custom content view. Also contentless. |
| Timer paused | Same builder with `running=false`; actions **Resume** and **Reset**. | Never. |
| Timer firing | `setOngoing(true)`, category `ALARM`, high priority, full-screen intent, custom chronometer view, actions **Stop** and **Add 1 min** (single timer). | Never. |
| Stopwatch running | `setOngoing(true)`, custom `chronometer_notif_content`, **no category**, channel at `IMPORTANCE_DEFAULT`, actions **Pause** and **Lap**. | Never. |
| Stopwatch paused | `setOngoing(false)`, `setAutoCancel(true)`, actions **Start** and **Reset**. | No; it is not ongoing, and it is custom. |
| Alarm scheduled | **No notification.** AOSP's alarm is a scheduled `AlarmManager` event, not an ongoing card. | — |
| Alarm firing | A high-priority alarm notification with a full-screen intent; the person stops or snoozes it. | Not a countdown. |

The AOSP timer's custom view means the listener cannot get the remaining time from the notification extras. There is no `EXTRA_SHOW_CHRONOMETER` and no `setUsesChronometer`; the chronometer is an action inside the `RemoteViews`. The only ways to read it are to render the view (a still picture) or to reflect into `RemoteViews`' private action list (brittle, hidden API, not recommended).

**Samsung Clock** (`com.sec.android.app.clockpackage`) is not open source and has no public notification documentation. Samsung's Now Bar supports the timer and stopwatch, and One UI 8.5 is reported to add alarms, so Samsung's Clock likely posts a Samsung-specific ongoing card for at least the timer and stopwatch. Its style, category, extras, actions and promotion flag are unknown. **(unverified; the probe covers it.)** Its package name is a label used in the probe, not a verified API contract.

### Starting a timer from the Mac

`AlarmClock.ACTION_SET_TIMER` (API 19) is the public route:

| Extra | Meaning |
|---|---|
| `EXTRA_LENGTH` | Seconds, 1 to 86400 (24 hours). |
| `EXTRA_MESSAGE` | A label; the Clock apps use it as the timer's name. |
| `EXTRA_SKIP_UI` | Boolean: "bypass any intermediate UI". Default false. |

The action requires `com.android.alarm.permission.SET_ALARM` (a normal permission). AOSP DeskClock's `HandleApiCalls.handleSetTimer` honours `EXTRA_SKIP_UI`: without it, it opens the running-timer screen; with it, it creates and starts the timer and stays out of the way. Another Clock app may ignore the extra, show a confirmation, or not handle the intent at all. A phone with no handler resolves to nothing.

Two practical limits:

- **Background activity launch.** The intent is handled by an activity. A phone-side app cannot always start an activity from the background on Android 10 and later. PocketDeck's session has a foreground service while connected, which may or may not be enough on One UI 8. The safe implementation starts the intent from a phone-side component that is already in the foreground, or asks the person to open the app once; this is a spike item. **(unverified)**
- **"The phone's own Clock app" is not a single target.** The intent goes to whichever app handles it. On the person's phone that is presumably Samsung Clock; if a third-party Clock is the default, the timer rings there instead. The Mac should say which app it used, or show the system chooser once.

`AlarmClock.ACTION_DISMISS_TIMER` only dismisses an **expired** timer; it is not a way to stop a running one. There is no public "pause timer" or "reset timer" intent. The notification's actions are the supported control surface.

### Pause and stop through the notification's actions

The existing `notify.action {id, i}` route executes the `PendingIntent` behind an advertised action. That is the right mechanism: it uses the app's own code and does not need a special API.

The limits are the app's, not ours:

- A running AOSP timer offers **Pause** and **Add 1 min**, not Stop. To stop it, the person must Pause, wait for the notification to rebuild, then press **Reset**. A Mac "Stop" is therefore a two-step action, and the second step only exists after the phone's next post. The same is true of the stopwatch: Pause, then Reset.
- The phone sends no reply to `notify.action`; the result is the next `notify.post` or `notify.remove`. A failed action looks like silence. The Mac needs a timeout and a sentence, not a claim that the timer stopped.
- A third-party timer may offer a single Stop, or only "Open". The Mac must show the actions the phone advertised, not invent names.
- Clearing the Mac card must not cancel the timer. A live card is a view of a phone notification; the phone's Clock is the owner. Hiding the card on the Mac leaves the timer running, and the next snapshot brings it back.

### The countdown problem, stated plainly

A native Mac countdown needs a **deadline**: a `when` plus `countDown`, a `ProgressStyle` fraction with a known total, or a duration the Mac itself sent. The sources are:

- **Promoted third-party timers (QPR1+):** likely `setUsesChronometer(true)` + `setChronometerCountDown(true)`, or a `ProgressStyle`. The existing wire already carries `chrono` and `countDown`; it needs the phone's `now` as well to cancel clock skew.
- **A timer the Mac started:** the Mac knows `EXTRA_LENGTH` and the send time; it can keep a local deadline and match the Clock's notification by package, category and start time. This is the reliable P1 path.
- **A timer started on the phone with AOSP DeskClock:** the notification has no deadline. It can be shown as a snapshot with Pause/Stop actions, but not as a ticking Mac countdown. A future option is a phone-side Clock integration; it is not available through the notification API.
- **Samsung Clock:** unknown until the probe. If it exposes `EXTRA_SHOW_CHRONOMETER`/`EXTRA_CHRONOMETER_COUNT_DOWN`, the standard path works; if it uses a custom view, it has the AOSP problem.
- **Alarms:** no notification before they fire, so no countdown from the notification path. `AlarmManager.getNextAlarmClock()` (API 21, no permission) returns the next `AlarmClockInfo` scheduled by any app, and `ACTION_NEXT_ALARM_CLOCK_CHANGED` is a registered-receiver broadcast when it changes. That can power a Mac "Next alarm" countdown if the product wants one. It gives a time, not a label or a repeat rule.

**Recommendation for the P1 story:** guarantee a Mac countdown for a timer the Mac starts, and for a phone timer whose notification reports a chronometer or a promoted progress deadline. For a phone timer that only has a custom view, show the card and its actions, and say the countdown is unavailable rather than inventing one. Ask the person whether that is acceptable, or whether "Start Timer…" should be the only timer path in P1.

## macOS

### How macOS 26 shows an iPhone's Live Activities

Apple's support page (120684) says an iPhone's Live Activities appear in the Mac's menu bar after iPhone Mirroring has connected, even when Mirroring is not open. Depending on space, the Mac shows either a small Live Activity icon or a compact view; a click shows more detail, and a double-click opens iPhone Mirroring when the phone is nearby. A close button on the detail removes that activity for its duration. The setting is **System Settings → Notifications → Allow Live Activities from iPhone**, and it exists on macOS 26 and later.

The page does not state a limit on how many activities show at once, nor what happens at the notch. In practice the menu bar's right region is finite; this is the same space problem the app's own status item has. **(unverified for several at once and for the notch.)**

### Can a Mac app post a Live Activity?

`ActivityKit` lists macOS **27.3 beta** as its first macOS platform; iOS, iPadOS and Mac Catalyst have had it since 16.1. PocketDeck's deployment target is **macOS 26.0** and the person's Mac runs macOS 26. So a Mac app cannot post a Live Activity today, and the app cannot use ActivityKit even on macOS 27.0 or 27.1. The framework's macOS support is a future path, not a current one.

The public model is also iPhone-first: Apple's support page is about an iPhone's activities appearing on the Mac. Where a Mac-originated ActivityKit activity would appear on macOS 27.3 is not documented in a form this note could verify. **(unverified.)**

### What a Mac app can use instead

**`NSStatusItem`.** The app already has one status item with `NSStatusItem.variableLength` and a custom panel (`MenuBarPanel.swift`). A status item can carry a template image and a title; the system lays items out from the right and grows left. Several items are allowed. Important facts:

- `NSStatusItem.length` can be `NSVariableStatusItemLength`, `NSSquareStatusItemLength` or a fixed width.
- `NSStatusItem.isVisible` returns **true even when the item is temporarily hidden because the menu bar has no room**. There is no public API that says "your item is under the notch". A workaround is to observe the item button's window occlusion state, or compare the button's frame with `NSScreen`'s notch geometry; both are best-effort. Apple's own engineers have acknowledged the gap.
- On a notched Mac the menu bar has two top regions, exposed by `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`; status items live in the right region. There is no menu-bar surface in the notch itself. When items overflow, macOS stops rendering the leftmost ones; they keep their frames and their accessibility entries, but there is nothing to click. macOS 27 replaces the per-item windows with one composited menu bar and adds a native overflow control; the exact API behaviour is still changing. **(secondary sources; unverified on the person's Mac.)**
- One status item per live update is therefore risky on a 14- or 16-inch notched Mac: four timers and trackers can push the leftmost ones into the notch, and the app cannot tell. One item with a stack, or one item plus a panel, is safer.
- The menu bar's own width is shared with every other app; a per-second countdown title redraws the item every second and can make the menu bar busier than a compact icon. Measure before choosing.

**`NSPanel` / popover.** The app already uses a borderless, non-activating `NSPanel` at `.statusBar` level with `.canJoinAllSpaces` and `.fullScreenAuxiliary` for the menu-bar panel. The same shape works for a click-through card. A panel can be placed anywhere, including under the notch, without private APIs; it is a normal window, so it follows Spaces, full-screen apps and display sleep. Pitfalls for an island:

- The notch is a physical gap, not a window; a panel cannot draw "in" it. An island is a panel hugging the notch's lower edge, with the menu bar around it.
- Menu-bar auto-hide, full-screen apps, Stage Manager, screen savers and display sleep all change the safe top inset. `NSScreen.safeAreaInsets` gives the camera-housing inset, not the menu bar's state.
- A panel over the menu bar can cover other apps' status items and the system clock; it must be narrow, dismiss on outside click and Esc, and never become key unless the person is typing.
- On a Mac without a notch the island has nothing to attach to; it becomes a floating pill. The design must say what it does there.
- Accessibility: the panel's content needs a focus order and VoiceOver labels; Reduce Motion and Reduce Transparency apply; a countdown is information, not decoration.

**WidgetKit desktop widget.** Widgets are a separate extension process. The timeline budget is dynamic: a frequently viewed widget typically gets **40 to 70 reloads per 24 hours**, roughly every 15 to 60 minutes; the budget does not reset at midnight and is per widget instance. A countdown can tick without reloads by using SwiftUI's timer-based `Text` and `ProgressView(timerInterval:)`, but the data behind it only refreshes on the timeline's schedule or an explicit reload.

PocketDeck is **ad-hoc signed**; release builds are ad-hoc (AGENTS.md, `docs/design/mac-audit.md`). The repo's Control Center extension experiment (`docs/design/controls.md`) built an ad-hoc, sandboxed `Controls.appex`; `pluginkit` listed it, but the Control Center gallery never showed it and the extension never launched in the VM. The File Provider extension did register, so extension registration is not uniformly broken; it is per extension kind and per install. There is no public Apple statement that an ad-hoc Mac app's WidgetKit extension can be discovered and added like an App Store app's. **(unverified; a VM spike is the only way to know.)**

The roadmap already lists widgets for later (ROADMAP #11), using a snapshot the Mac app keeps. That is compatible with the Live surface, but a widget is **not** a shippable part of the first round on the current signing and install story. The prototype can include a mock to compare the idea; the plan should not claim it ships.

## Power and traffic

- The listener is push-based: the system calls `onNotificationPosted` when the app posts. PocketDeck does not poll the phone. A tick from a timer app is one Binder callback, one extras read and one `notify.post`; the phone-side app already pays for its own notification update.
- The Mac must not ask the phone for a tick. A countdown is computed from a deadline and a local 1 Hz timer. `NOTIFY-12` already coalesces updates to one per second per id; that is the right ceiling for wire traffic, not a reason to send one per second.
- The existing `chrono` is an absolute epoch. If the phone's clock is 3 seconds off, the Mac's countdown is 3 seconds off, and the error is invisible. Send the phone's `now` with the post (or send `remainingMs`) and start a monotonic local deadline when the post arrives. The same applies to a `when` that is a future wall-clock time. This is a correctness fix, not a nicety.
- A menu-bar title that counts down redraws a status item every second; with several items that is several redraws. A card that is only visible in the panel can tick only while the panel is open. Measure both; the NFR has no menu-bar redraw budget yet.
- Phone sleep does not stop the Clock; the notification remains and the deadline is still valid. Mac sleep: recompute on wake. If the deadline passed while the Mac slept, show `0:00` and wait for the phone's removal or firing notification; do not invent an end. Disconnect: the phone's snapshot on reconnect is the truth; before that, the last state can be shown frozen and marked, or hidden. The spec must choose one and say for how long.
- Rendering a custom view costs far more than reading extras. Cap it: per-app opt-in, only when the notification has no plain progress/chrono, at most once per second, at most 512 px, and skip it while the phone reports a low battery or the screen is off if that turns out to matter. **(cost unverified; measure on the phone.)**

## Privacy

Live cards carry exactly what makes them useful: a restaurant and a driver's name, a street address, a plate, a score, a workout, a timer's label, a parcel number. The existing notification opt-in covers forwarding, but it is one switch for all notifications and the listener grant is all-or-nothing at the OS level. A live surface adds three new risks:

1. **Persistence.** A history of finished cards ("Delivered 12:40") is a history of addresses and names. Keep it in memory, cap it (for example 20 items), clear it on disconnect and quit, and never write it to disk or a log. If the person wants it across launches, it needs its own opt-in and an expiry.
2. **Rendered snapshots.** A card bitmap can contain a map, a plate or a message. Keep it in memory, never in the share log, never in a crash report, and wipe it when the card ends. It is content, not chrome.
3. **Per-app control.** Promoted cards are app-controlled and exact; legacy cards are a heuristic. The per-app allowlist, off by default, is what keeps a banking app's persistent "session active" card or a VPN's "connected" card off the Mac. It is a filter on the Mac, not a permission on the phone; say so in Settings.

`CONV-PD-05` already forbids content in logs. The live path must also forbid content in the **history** and in **rendered bitmap** filenames, and the Mac's debug dump (`livedump`) already carries lengths and booleans only.

## What this note could not verify

- Whether One UI 8 on the person's S25+ marks any third-party notification `FLAG_PROMOTED_ONGOING`, and whether Samsung Clock's own timer is promoted.
- Samsung Clock's notification style, category, extras, actions, channel importance and `EXTRA_SKIP_UI` behaviour.
- Whether One UI 8's Now Bar per-app switches gate a card that Android already promoted, and whether the Developer options switch is needed on stable.
- AOSP DeskClock's behaviour on the emulator build (the source was read, not run), and whether the custom view renders correctly through `RemoteViews.apply` in a listener process.
- The real cost and success rate of rendering custom views on the person's phone, including collections, images and theme differences.
- The `remove_remote_views` flag on OEM builds, and OEM-specific RemoteViews size limits.
- Whether a Mac app can start `AlarmClock.ACTION_SET_TIMER` from the background on One UI 8, and whether Samsung Clock honours `EXTRA_SKIP_UI`.
- The exact clock skew between the Mac and the phone.
- Status-item visibility under the notch on the person's Mac, and macOS 27's overflow behaviour with several items.
- Where a Mac-originated ActivityKit Live Activity would appear on macOS 27.3.
- Whether an ad-hoc Mac app's WidgetKit extension can be discovered and added on macOS 26.
- The phone-side power cost of a rendered snapshot per update.

## Sources

Primary sources first. AOSP links point at the `android16-qpr1-release` branch where the note relies on QPR1 behaviour; `main` on the public mirror was stale (March 2025) at the time of reading.

1. Android Developers, "Live updates" guide: https://developer.android.com/develop/ui/views/notifications/live-update
2. Android Developers, `Notification.FLAG_PROMOTED_ONGOING`: https://developer.android.com/reference/android/app/Notification#FLAG_PROMOTED_ONGOING
3. Android Developers, `Notification.EXTRA_REQUEST_PROMOTED_ONGOING`: https://developer.android.com/reference/android/app/Notification#EXTRA_REQUEST_PROMOTED_ONGOING
4. Android Developers, `Notification.Builder#setRequestPromotedOngoing`: https://developer.android.com/reference/android/app/Notification.Builder#setRequestPromotedOngoing(boolean)
5. Android Developers, `Notification.ProgressStyle`: https://developer.android.com/reference/android/app/Notification.ProgressStyle
6. Android Developers, `Manifest.permission#POST_PROMOTED_NOTIFICATIONS`: https://developer.android.com/reference/android/Manifest.permission#POST_PROMOTED_NOTIFICATIONS
7. Android Developers, `NotificationManager#canPostPromotedNotifications`: https://developer.android.com/reference/android/app/NotificationManager#canPostPromotedNotifications()
8. Android Developers, `Settings.ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS`: https://developer.android.com/reference/android/provider/Settings#ACTION_MANAGE_APP_PROMOTED_NOTIFICATIONS
9. Android Developers, Android 16 features: https://developer.android.com/about/versions/16/features
10. Android Developers, API differences 36 to 36.1: https://developer.android.com/sdk/api_diff/36.1/changes/android.app.Notification
11. Android Developers, Android 16 QPR2 release notes: https://developer.android.com/about/versions/16/qpr2/release-notes
12. Android Developers, Android 17 features (Live Update semantic colours): https://developer.android.com/about/versions/17/features
13. Android Developers, `Notification.MetricStyle`: https://developer.android.com/reference/android/app/Notification.MetricStyle
14. Android Developers, `AlarmClock`: https://developer.android.com/reference/android/app/AlarmClock
15. Android Developers, `AlarmManager#getNextAlarmClock`: https://developer.android.com/reference/android/app/AlarmManager#getNextAlarmClock()
16. Android Developers, `RemoteViews`: https://developer.android.com/reference/android/widget/RemoteViews
17. Android Developers, `NotificationListenerService`: https://developer.android.com/reference/android/service/notification/NotificationListenerService
18. AOSP, `Notification.java` (QPR1 branch): https://android.googlesource.com/platform/frameworks/base/+/android16-qpr1-release/core/java/android/app/Notification.java
19. AOSP, `NotificationManagerService.java` (QPR1 branch): https://android.googlesource.com/platform/frameworks/base/+/android16-qpr1-release/services/core/java/com/android/server/notification/NotificationManagerService.java
20. AOSP, `PreferencesHelper.java` (QPR1 branch): https://android.googlesource.com/platform/frameworks/base/+/android16-qpr1-release/services/core/java/com/android/server/notification/PreferencesHelper.java
21. AOSP, `config.xml` (RemoteViews size limits): https://android.googlesource.com/platform/frameworks/base/+/android16-qpr1-release/core/res/res/values/config.xml
22. AOSP DeskClock, `TimerNotificationBuilder.kt`: https://android.googlesource.com/platform/packages/apps/DeskClock/+/android16-qpr1-release/src/com/android/deskclock/data/TimerNotificationBuilder.kt
23. AOSP DeskClock, `StopwatchNotificationBuilder.kt`: https://android.googlesource.com/platform/packages/apps/DeskClock/+/android16-qpr1-release/src/com/android/deskclock/data/StopwatchNotificationBuilder.kt
24. AOSP DeskClock, `HandleApiCalls.kt`: https://android.googlesource.com/platform/packages/apps/DeskClock/+/android16-qpr1-release/src/com/android/deskclock/HandleApiCalls.kt
25. Apple Support, "Manage iPhone notifications and Live Activities on Mac" (120684): https://support.apple.com/en-us/120684
26. Apple Developer, ActivityKit (macOS 27.3 beta): https://developer.apple.com/documentation/activitykit
27. Apple Developer, `NSStatusItem.variableLength`: https://developer.apple.com/documentation/appkit/nsstatusitem/variablelength
28. Apple Developer, `NSStatusItem.isVisible`: https://developer.apple.com/documentation/appkit/nsstatusitem/isvisible
29. Apple Developer, `NSStatusBar.system`: https://developer.apple.com/documentation/appkit/nsstatusbar/system
30. Apple Developer, `NSScreen.safeAreaInsets`: https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets
31. Apple Developer, "Keeping a widget up to date": https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
32. Apple Developer, `NSPanel`: https://developer.apple.com/documentation/appkit/nspanel
33. Samsung Support, "How to use the Now bar on the lock screen": https://www.samsung.com/ph/support/mobile-devices/how-to-use-the-now-bar-on-the-lock-screen-of-your-samsung-galaxy-device/
34. Android Authority, "Android 16 QPR1 adds full support for Live Updates" (secondary): https://www.androidauthority.com/android-16-qpr1-live-updates-3573399/
35. Android Authority, "One UI 8 will let any app show a Live Notification in Samsung's Now Bar" (secondary): https://www.androidauthority.com/one-ui-8-live-updates-support-3573794/
36. Android Police, "How to make use of your Samsung's Now Bar" (secondary): https://www.androidpolice.com/use-samsungs-now-bar-lock-screen-aod-tutorial/
37. Ake Xorcist, "Live Notifications and Now Bar in Samsung One UI 7: As developer" (secondary): https://akexorcist.dev/live-notifications-and-now-bar-in-samsung-one-ui-7-as-developer-en/
38. Sammy Fans, "Samsung upgrades Now Bar with new live notifications" (One UI 8.5; secondary): https://www.sammyfans.com/2025/11/19/samsung-upgrades-now-bar-with-new-live-notifications/
39. Jorvik Software, "The Icons Behind The Notch" (secondary; macOS 27 update): https://jorviksoftware.cc/notes/2026/05/03/the-icons-behind-the-notch
40. Michael Tsai, "Mac Menu Bar Icons and the Notch" (secondary): https://mjtsai.com/blog/2023/12/08/mac-menu-bar-icons-and-the-notch/
41. Michael Tsai, "Golden Gate and the Notch" (secondary; macOS 27 overflow): https://mjtsai.com/blog/2026/09/25/golden-gate-and-the-notch/
