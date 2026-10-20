# Notifications + media controls — design (notify)

ROADMAP #7. Emulator probes ran on Android 16 / API 36 (emulator-5588, 2026-10-15) as `app_process`
dex probes and plain `cmd`/`dumpsys` at uid 2000 — the same uid and permission grants the Shizuku
server has (`status()` reports uid=2000; `com.android.shell` holds STATUS_BAR_SERVICE +
MEDIA_CONTENT_CONTROL, seen in `dumpsys package`).

## Shell-UID route, probed

- Media read: `ISessionManager("media_session").getSessions(null, 0)` from uid 2000 → session
  tokens for the active session; `token.getBinder()` → `ISessionController`: pkg, PlaybackState
  (state/position/speed) and full MediaMetadata (title/artist/album/duration=30000 ms on the
  Fossify track). `MediaSessionManager.getActiveSessions` from a bare shell process NPEs
  (MediaServiceManager singleton only exists in real app contexts).
- Media control: `cmd media_session dispatch play|pause|next|previous` at uid 2000 toggled real
  playback (PlaybackState verified around each dispatch); works while paused too.
- Notification read: `INotificationManager.getActiveNotifications(as "com.android.shell")` →
  SecurityException (PermissionEnforcer). `cmd notification list` → keys;
  `dumpsys notification --noredact` → per-key record incl. `extras{android.title, android.text}`,
  pkg, flags, postTime (`cmd notification get` has no extras).
- Listener grant from shell: `cmd notification allow_listener <component>` at uid 2000 flips
  `secure.enabled_notification_listeners` (add + remove verified; the component need not exist yet).
- Notification dismiss from shell: no supported call (cancel is poster/listener identity only).

## Decision: NotificationListenerService in the app, granted by the shell at opt-in

One per-phone opt-in covers both features; default OFF on the Mac and the phone.

- Phone toggle on → the app asks the shell service (new AIDL `grantListenerAccess`) to run
  `cmd notification allow_listener dev.pocketdeck/dev.pocketdeck.app.PdNotificationListener`
  (verified above). If exec fails, open `ACTION_NOTIFICATION_LISTENER_SETTINGS`. Toggle off just
  stops forwarding (the grant may stay; nothing is read for the wire).
- `PdNotificationListener` (BIND_NOTIFICATION_LISTENER_SERVICE) runs in the app process:
  onNotificationPosted/Removed → `{id, pkg, app?, when, title?, text?, ongoing}` (each string
  capped at 8 KiB; our own package and contentless notifications skipped). Forwarded only while
  the phone toggle is on and the Mac session has notify enabled.
- Media: `MediaSessionManager.getActiveSessions(listener)` in the app process — public
  MediaController with metadata (duration), position drift via rate, callbacks throttled to ≤1/s.
  No dumpsys parsing, no `cmd` spawning, no reflection; the shell route stays as a documented
  fallback (parse `dumpsys notification --noredact`, drive sessions via the AIDL/cmd probes) if
  the listener route is ever blocked by an OEM.
- Plumbing: AIDL `IDeckService.pushNotificationEvent(json)` / `pushMediaState(json)` app→shell;
  `IDeckCallback.onMediaCommand(action)` shell→app. The shell `Session` validates and forwards.
- Notifications on the Mac: UserNotifications, title = the notification's own title (else the app
  label) with the phone's name appended ("Review (Nicky)"), the name the Deck shows for that phone;
  a notification with neither title nor label shows the phone name alone; text = body, grouped per
  phone (`threadIdentifier` = phone id). "When I click a phone notification" (per phone, beside the
  opt-in, enabled only while it is on) picks what a click does: **Open on Mac** (default) opens or
  raises the app's window and runs the notification's own `contentIntent` on that window's virtual
  display; **Open on phone** runs it on the phone's display 0 and opens no Mac window; **Do nothing**
  only dismisses the banner.
- Media on the Mac: MPNowPlayingInfoCenter + MPRemoteCommandCenter (play/pause/next/prev ticked
  off through `media.command`); cleared when `media.state` shows nothing.
- Dismiss on the Mac → dismiss on the phone: a banner clear is reported through a
  `UNNotificationCategory` with `.customDismissAction` (`didReceive` gets
  `UNNotificationDismissActionIdentifier`; the person still sees no Mac UI). The phone then
  cancels its own notification (`cancelNotification(key)` as the listener) and skips
  ongoing/no-clear ones. **Not yet proven on macOS 26**: the VM run (part 2 results) did not
  reach a banner clear, so this rests on the API being documented, not on a measurement.

## Protocol (docs/PROTOCOL.md, session-level JSON)

- mac→phone: `notify.enable {on}` — when the per-phone toggle changes and again on reconnect;
  `notify.open {id, target: window|phone, stream?}` — a banner click (the id is one the phone
  issued; the action never crosses the wire); `media.command {action: play|pause|next|prev}`.
- phone→mac: `notify.state {on}` (true once granted and forwarding); `notify.post {id, pkg, app?,
  when, title?, text?, ongoing?}`; `notify.remove {id}`; `media.state {playing, pkg?, title?,
  artist?, album?, durationMs?, positionMs, rate}` — empty media.state (no list fields) clears
  Now Playing.
- Privacy: notification or media text is never logged (the e2e `--share-log` file records ids, package
  names and field lengths only, and in that mode nothing is posted to Notification Center); without
  an answered `notify.enable {on:true}` nothing is forwarded; disconnect clears the Mac's local state.

## Part 2 design (v0.2 #8)

Deeper notifications, part 1: the phone's own buttons and a reply field on the Mac banner, a
clear on either side clearing both, per-app mute, and a Copy code button for sign-in codes.
Images and Android 16 Live Updates / Now Bar are part 2 and not covered here.

### Actions on the wire

`notify.post` gains `actions`: up to 3 entries `{ "i": <index in Notification.actions>,
"title": <≤ 64 chars>, "reply": true? }`. `reply` means the action carries a RemoteInput
that allows free-form input. An action is advertised only when it has both a title and a
PendingIntent (an action with neither cannot be shown or run), the title is trimmed and
capped at 64 chars, and "contextual"/system-generated smart actions are skipped. Old Macs
ignore the field; a phone that does not know it keeps working with clicks only.

Mac → phone `notify.action {id, i, text?}`: the listener looks the notification up by the id
it issued (the existing id map), validates `i` against the actions it advertised, and sends
that action's PendingIntent. With `text` (≤ 4 KiB, reply actions only) it fills the
RemoteInput with `RemoteInput.addResultsToIntent` first. An unknown id or index logs
`notify.action unknown` (never the text) and sends nothing; a text on a non-reply action or
over the cap is refused. No answer is sent: the app updating or removing the notification
flows back through `notify.post`/`notify.remove`.

### Dismiss

Mac → phone `notify.dismiss {id}`: the listener calls `cancelNotification(key)` for the
notification it forwarded; ongoing/no-clear notifications (FLAG_ONGOING_EVENT / FLAG_NO_CLEAR)
are skipped. The Mac learns of a banner clear through `.customDismissAction` on the phone's
notification category; phone → Mac already maps `notify.remove` to removing the delivered
banner. The Mac itself refuses to send a dismiss for a notification the wire marked `ongoing`
(recorded as `notify dismiss ... refused=ongoing`).

### Mac categories

macOS puts action titles in the category, not the notification, so a category is keyed by
the notification's shape: its button titles, whether it has a reply action, and whether a
code was found. The id is `pd.n.<16 hex>` of an FNV-1a hash over `[titles…, reply?, code?]`
(never over the notification's text). The registered phone categories live in a bounded LRU
of 64; when a new shape arrives the oldest is dropped and the whole set is re-registered
with `setNotificationCategories` together with the share category. Each category carries
`UNNotificationAction`s for the phone's buttons (ids `pd.a.<i>`, title from the phone), a
`UNTextInputNotificationAction` for a reply action (id `pd.r.<i>`, the phone's title,
placeholder "Message"), and `Copy code` (`pd.copy`) when a code was found. Button titles are
part of the hash but are never logged. `.customDismissAction` is set so a banner clear is
reported.

### Sign-in codes

`NotifyCode.find(title:text:)` is a pure scan on the Mac: 4–8 digits, or 6–8 alphanumerics
with at least two digits, within 32 characters of a keyword in English, Portuguese or
Spanish ("code", "código", "verification", "verificação", "OTP", "PIN", "passcode"; "senha"
and "password" count only when "code"/"código" is also present). It rejects a run that is
part of a longer number, a date/time, an amount or a phone number. Unit-tested with fake
samples. `Copy code` copies on click only, marks the pasteboard item
`org.nspasteboard.ConcealedType` + `org.nspasteboard.TransientType`, and clears it after
90 s if the pasteboard still holds it (changeCount check).

### Per-app mute

Settings › Devices › (per phone) › Notifications has "Muted apps": the packages seen in this
session (package + label, never text; already muted packages stay listed so they can be
unmuted). Muted means the Mac drops that package's `notify.post` before posting
(`notify muted pkg=…` in the share log); the message still crossed the encrypted link.
The set is stored per phone in the profile's defaults as `notify.mute.<deviceId>`.

### Logs

Ids, package names, action indexes, field lengths and category counts only — never titles,
texts, codes or replies, on either side and in the e2e share log.

## Part 2b design: images and Live Updates

Part 2 of v0.2 #8: a forwarded notification's picture and Android 16 Live Updates
(promoted ongoing notifications). Part 1 (actions, reply, dismiss, mute, codes) is
unchanged except for the promoted-ongoing gate below.

### Images

The phone picks **at most one picture per notification**, in this order: the
big-picture bitmap/icon (`EXTRA_PICTURE`, else `EXTRA_PICTURE_ICON`), else the
large icon (`Notification.getLargeIcon()`). The pick happens in the app process
(the listener already holds the notification), and the mapping rules are a pure,
JVM-tested seam (`NotifyImageRules` + a bitmap-source interface) so the cap math
is tested without Android:

- the long side is scaled to at most 512 px (aspect kept, no upscaling);
- encoded as JPEG quality 80, or PNG when the source has an alpha channel;
- at most 200 KiB after encoding; if it does not fit, the long side is halved
  (512 → 256 → 128 → 64 → 32) and re-encoded; still over the cap at 32 px, or
  the source cannot be read: no image is sent (the notification itself still goes);
- the wire carries `notify.image {id, mime, w, h, data}` (data = base64 of the
  encoded bytes) right after the `notify.post` for that id. An older Mac ignores
  an unknown `t`, so the banner is unaffected. An update that repeats the same
  picture for the same id is not sent again.

The Mac refuses a received image that breaks its own caps (decoded > 256 KiB,
mime other than `image/jpeg`/`image/png`, w or h ≤ 0 or > 1024, base64 that does
not decode, or an id it never posted) and keeps the banner without a picture:
`notify image id=… refused=<reason>`. A valid one becomes a
`UNNotificationAttachment` in a temp file under the profile's caches folder
(`~/Library/Caches/<support dir>/notify/<requestId>.<ext>`, directory 0700, file
0600, the attachment's own temp copy is the system's). The temp file is deleted
when the banner is removed (`notify.remove`, a phone-side dismiss), on
disconnect, and on app quit; the image lives nowhere else.

**Post timing:** the phone sends the post and then the image, so the Mac holds a
post for up to **300 ms** (`NotifyCenter.hold`, 0 in tests) before submitting it
to Notification Center, and the image that arrives in that window rides on the
same request. A post that is already delivered is never re-posted for a late
image: the image is dropped with `notify image id=… late` (a second banner for
one notification is worse than a missing thumbnail). Late means the hold has
elapsed; deeper queues are not reordered.

### Live Updates

Android 16 promotes an eligible ongoing notification (a ProgressStyle, CallStyle
or BigTextStyle ongoing notification with a title, no custom view, no colorized
flag, a non-MIN channel and a promotion request) into a Live Update. The listener
forwards an **ongoing** notification only when the system marked it promoted:
`notification.flags and Notification.FLAG_PROMOTED_ONGOING != 0` (API 36). The
system's own `hasPromotableCharacteristics()` is recorded in the logcat line
`notify live id=… promoted=0|1 promotable=0|1 style=…` (never text), which is how
the emulator run records exactly what Android 16 did. `EXTRA_REQUEST_PROMOTED_ONGOING`
(and its `NotificationCompat.Builder#setRequestPromotedOngoing`) only exists from
API 36.1 and is not in this project's compileSdk 36; on 36 promotion is the
system's decision for a notification that already qualifies, so nothing requests
it. A notification that is ongoing and not promoted is skipped exactly as before
(service chrome). The debug poster's own ongoing notifications stay forwardable
in debug builds (the test seam that made the dismiss rule testable) and carry
their own `promoted=` record.

The wire adds `live` to `notify.post`: `{progress?: 0..1, chip?: ≤ 16 chars,
chrono?: <epoch ms>, countDown?: bool}`.

- `progress` is the ProgressStyle fraction: `getProgress()/getProgressMax()`,
  or, for a segmented style, `getProgress()/sum(segment lengths)`; clamped to
  0..1; absent when indeterminate or unknown.
- `chip` is `Notification.getShortCriticalText()` (trimmed, capped at 16 chars).
- `chrono` is `when` when the notification shows a chronometer, and `countDown`
  says whether it counts down (`EXTRA_CHRONOMETER_COUNT_DOWN`).
- Updates re-send `notify.post` with the **same id**, coalesced to at most one
  per second per id (the newest state wins; a scheduled trailing send delivers
  whatever is current at the boundary). Ending the activity is the phone's normal
  `notify.remove`.

On the Mac the first post of a live item banners once (like any notification);
later posts for that id update the item in place and never banner again,
recorded as `notify live id=… progress=<0|1..10 bucket> chip=<len> chrono=0|1
countDown=0|1` in the share log. `notify.remove` (or a disconnect) removes both
the banner and the item. The menu bar extra's **Live on <phone>** section lists
the items with the app label, the chip, and either a ten-cell text progress bar
or the running chronometer, computed when the menu opens; a click runs the same
route a banner click runs (`notify.open`). Nothing about the items goes to the
host's Notification Center in e2e (`--share-log` records instead).

Samsung's Now Bar has no public API; One UI 8 shows Android 16 Live Updates
there, so the same promoted notification appears in it with no Samsung-specific
code.

## Part 2 results (v0.2 #8, part 1)

Built: actions/buttons and inline reply, dismiss Mac ↔ phone, per-app mute, Copy code. Images
and Live Updates / Now Bar are part 2 and untouched.

Verified (K1 468 unit tests 0 failures; K2 774 tests 0 failures; host e2e `notify-actions`
19/19, regressions `notify` 22/22 twice, `dock` 29/29, `menus` 8/8, all quiet share-log runs):

- the phone advertises at most three actions with trimmed, capped titles and the original
  action index; contextual and unusable ones are skipped; `notify.action` reaches the phone
  with the right index and a reply of the right length (fakephone logs it), a non-reply action
  gets no text;
- `notify.dismiss` reaches the phone for a clearable notification and is refused for one the
  wire marked `ongoing`; `notify.remove` still clears the delivered banner;
- a muted package's post is dropped at the Mac (`notify muted pkg=…`) and never shown;
- a code notification gets a category that carries Copy code, the pasteboard then holds the
  code (hash compared), the item is `org.nspasteboard.ConcealedType` +
  `org.nspasteboard.TransientType`, and the e2e clears it; no title, text, code or reply
  appears in any log;
- unit tests cover the action selection/validation, the category hash and its 64-entry LRU,
  the banner-action parser, the code scanner (23 positive / 24 negative samples) and the
  90 s pasteboard clear by changeCount.

Not verified (both hardware sessions were spent on the test client, not on the feature):

- **Emulator (1 boot used, API 36)**: the real server installed, the debug prefs were seeded,
  the listener grant and the v2 pairing succeeded. The actions/reply/dismiss checks never ran
  because the ad-hoc verification client was started with the macOS system `python3` (3.9,
  no TLS 1.3) instead of the rig's `$PYTHON`; it printed `Unsupported protocol version 0x304`
  and the run had no forwarded ids. With that one line fixed (use `$PYTHON`) the same script
  (`.agent/notify2/emu.sh`) should run. So on a real listener **unverified**: action mapping,
  RemoteInput fill, `cancelNotification`, the ongoing refusal.
- **VM (1 session used)**: the guest booted and the app received the reply-shaped
  `notify.post` (id, 2 actions, reply=1) over a healthy session, but the new visible check
  waited on the wrong event marker (`"kind":"notify"` instead of the id) and returned before
  any banner interaction. `.customDismissAction`, the real Reply field, Copy code from a real
  banner and the banner's buttons therefore remain **unproven**. `check-e2e.sh notify-vm` is
  fixed (waits for the notification id) for the next VM session; the screenshots the brief
  asked for do not exist yet.

## Part 2 results (v0.2 #8, part 2)

Built: a notification's picture (big picture, else its icon, else the large icon) scaled
and encoded on the phone and attached to the Mac banner through a 0600 temp file; Android
16 Live Updates (promoted ongoing notifications) with progress, chip and chronometer,
coalesced to one per second per id and shown in a menu bar **Live on <phone>** section;
the debug poster's picture/icon/live/chrono kinds; fakephone's picture and live shapes;
host e2e `notify-media`.

Verified (K1 519 unit tests 0 failures; K2 810 tests 0 failures; host e2e `notify-media`
21/21, regressions `notify` 22/22, `notify-actions` 19/19, `menus` 8/8, all quiet
share-log runs):

- `notify.image` joins the post held for 300 ms; the attachment temp file is 0600 in a
  0700 directory under the profile's caches, goes away with `notify.remove` and with a
  disconnect, and only mime/size/dimensions ever reach a log;
- an oversized picture is refused while its banner still posts without a picture;
- a live item banners once, updates in place (never a second banner) at most once per
  second, ends with `notify.remove`, and the menu bar's section (read through the
  `livedump` test hook) lists both rows, advances one and drops the ended one;
- a row click runs the normal click route; no notification text or picture bytes appear
  in any log.

Not verified (both hardware sessions were spent, and neither produced a forwarded
notification):

- **Emulator (1 boot used, API 36)**: the boot unlocked the locked rig with its PIN — the
  first real run of the API 36 `unlock.sh` fix, which worked (`device is locked, unlocking
  with the rig PIN`, then `[unlock.sh] unlocked`) — and the v2 pairing succeeded. But no
  notification was ever forwarded: the watch client saw `notify.state on=true` and then
  nothing. The emulator had to be killed at the end of the run (the boot budget), so no
  logcat survived. The likely cause is the implicit `am broadcast` for the debug poster
  never reaching the manifest receiver; `.agent/notify3/emu.sh` now sends it with
  `-p dev.pocketdeck`, keeps each broadcast's output in `broadcast.log`, and its
  assertions pass against a synthetic log (`--self-test`). So on a real listener
  **unverified**: reply/button mapping, RemoteInput fill, `cancelNotification`, the
  ongoing refusal, the picture extraction and the promoted flag the system sets.
- **VM (1 session used)**: the guest showed its own system banner ("App Background
  Activity") but no PocketDeck banner in any phase, so every AX press found nothing
  (`notfound`) and the screenshots are of the same plain screen. The run's app log was
  overwritten by the next phase, which failed to start fakephone because the previous one
  still held the port (the check now stops the fake between phases), so the extended
  picture and live phases never ran. `check_notify_vm` now also reports whether macOS
  authorized the app (`notify authorization granted=…`) instead of only failing to find
  buttons. Part 1's reply field, Copy code, banner clear (`customDismissAction`) and part
  2's picture banner and live menu section remain **unproven**; ROADMAP #8 is not ticked.

Screenshots from that session: `macos/build/vm-e2e/notify3/work/shots/` (the plain
screen, plus the system banner — kept as the record of what did and did not appear).

## Checks

- Unit tests: notification mapping (title/text extraction incl. BIG_TEXT, caps, skip rules),
  gate (toggle off → nothing leaves), media-state → nowPlayingInfo mapping, command mapping.
- e2e (`check_notify`, and in `all`): fakephone emits the phone→mac events after the Mac's
  `notify.enable {on:true}`; the Mac's `--share-log` shows posts/removals/clicks (sizes, never
  text); the DebugInput `notifyclick` action delivers the same handler a UNNotification click would
  (fakephone logs `window.open`); DebugInput `mediacmd` delivers play/pause/next/prev (fakephone logs
  rx `media.command`).
- Emulator end to end on emulator-5588: `cmd notification post` → Mac banner (screenshot);
  toggle off → no forwarding; Fossify player → Now Playing at the Mac (values logged); play/
  pause/next/prev from the Mac move the phone session (`dumpsys media_session`); click →
  window.open on the phone (window opens that app's display).
- Part 2 unit tests: action selection/caps/skips, index and reply-text validation, ongoing
  refusal, debug-poster gate; category hash/LRU and banner-action parsing; sign-in code samples
  and the pasteboard write/clear. e2e `notify-actions` (quiet) covers the wire, fakephone's
  action/dismiss logs, mute, the ongoing refusal, Copy code's value hash and concealed types,
  and the no-text rule. `notify-vm` (SKIP on the host) drives real banners with AX inside the
  VM: Reply, Send, Copy code, and a banner clear.
- ROADMAP #7 is marked done only if notifications AND media controls both work end to end on
  the emulator; otherwise the gaps are listed in `.agent/notify/progress.md` and the doc.
