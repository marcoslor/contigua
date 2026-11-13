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

One per-phone switch covers both features, and it lives on the Mac only; off by default. The
phone has no second switch: its notification-listener grant is the phone-side half of the gate
(person's decision, 2026-10-27).

- `notify.enable on` → if the listener is not granted, the phone asks the shell service to run
  `cmd notification allow_listener app.contigua/app.contigua.app.PdNotificationListener`
  (verified above). If that fails the phone answers `notify.state {on:false, reason:"no_access"}`,
  its home shows a "Notification access is off" attention item that opens
  `ACTION_NOTIFICATION_LISTENER_SETTINGS`, and the Mac's Devices row says "Allow notification
  access on the phone" under the switch. A later grant is announced by the listener and turns
  forwarding on without another Mac toggle. `notify.enable off` just stops forwarding (the grant
  may stay; nothing is read for the wire). A value stored by an older install's phone switch is
  ignored, never migrated to on.
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
- Parity guard: K1 `NotifyWireParityTest` pushes every field the app's builders emit through
  `Session.onDeviceEvent` and fails when the shell server drops or changes one.
- Notifications on the Mac: UserNotifications, title = the notification's own title (else the app
  label), with the phone's name appended ("Review (Nicky)") only while two or more phones are
  paired; with one phone the title stands alone, and a notification with neither title nor label
  shows its package; text = body, grouped per
  phone (`threadIdentifier` = phone id; `<phone id>.<group hash>` when the post carries a group,
  NOTIFY-20). "When I click a phone notification" (per phone, beside the
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

- mac→phone: `notify.enable {on}` — the only person-facing switch, sent when it changes, again
  on reconnect, and again after a same-session rejoin that followed an outage (PATH-6); every
  `on:true` is an active-set request (NOTIFY-1).
  `notify.open {id, target: window|phone, stream?}` — a banner click (the id is one the phone
  issued; the action never crosses the wire); `media.command {action: play|pause|next|prev}`.
- phone→mac: `notify.state {on, reason?}` (true once granted and forwarding; `reason:"no_access"`
  when the Mac asked but the listener grant is missing); `notify.post {id, pkg, app?,
  when, title?, text?, alert, group?, ongoing?}`; `notify.remove {id}`; `notify.snapshot {ids}`
  — the active set that answers an enable: one quiet `notify.post` (`alert:false`) per
  notification still active, then the ids it just posted; `media.state {playing, pkg?, title?,
  artist?, album?, durationMs?, positionMs, rate}` — empty media.state (no list fields) clears
  Now Playing.

The active set is how a rejoin repairs state the Mac cleared on path loss: the quiet posts
update a changed row in place (never a second banner) and `notify.snapshot` names everything
the phone still holds. The Mac drops every live row, banner and waiting post whose id the set
does not name, so a row the phone ended during the outage does not outlive it. The set is the
same shape at session start and after a rejoin; a planned switch or a probe join beside a
live path sends no enable and therefore no snapshot. Ids are the opaque tokens `notify.post`
carried (at most 200), never text.
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

Settings › Devices › (per phone) › Notifications has "Muted apps": the app list this Mac already
caches for the phone, plus packages seen this session and already-muted ones (package + label,
never text; an app that sent a notification this session carries a mark). The list is
searchable, muted apps sort first, and a trailing "Muted" checkbox column with a column header
is the only switch; a system package gets a friendly name ("System UI") with its package name
underneath, and an unknown app shows its package name. Muted means the Mac drops that package's
`notify.post` before posting (`notify muted pkg=…` in the share log); the message still crossed
the encrypted link. The set is stored per phone in the profile's defaults as
`notify.mute.<deviceId>`.

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
  an unknown `t`, so the banner is unaffected. Every post (an update too) is followed
  by its picture again: the Mac replaces the whole banner on an update, so a
  skipped picture would leave the updated banner without it.

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

### The attachment's app badge

N4, picked 10-31. With a picture, the attachment is a square PNG with alpha: the picture
is scaled to fill (**cover**) and clipped to a circle, with the sending app's icon as a
circular badge at the bottom-right — 40 % of the side, inset 4.5 % from the right and
bottom edges, clipped to a circle, **no ring**. With no picture, the app's icon alone is
the attachment at 256 px, filling the square and clipped to a rounded square with a 22 %
corner (never a circle, so it cannot be read as a person's photo). A picture's side is
min(512 px, its long side).

The icon is the Deck's and Dock's rendering: the cached adaptive layers, else the flat
icon, through `PhoneAppIcon` (F3 plate included), drawn body-full so the badge or tile is
filled; the cache size class is the first whose source stays inside the 1.3× upscale
bound (docs/NFR.md). No icon cached, or a source too small: the picture stays a circle
without a badge, and with no picture there is nothing to attach. A composed PNG that
would exceed 200 KiB (or the `NotifyImageCaps` caps) falls back to the phone's picture as
sent, today's behaviour; an undecodable picture keeps the phone's bytes too. The record carries facts only — `composed shape=… badge=yes|no
side=… class=…`, or `composed fallback=over_cap|no_icon` — never pixels or text
(R-PRIV-1). There is no setting, and the banner's own icon stays Contigua's.

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
(service chrome), **except** that `live.md` `LIVE-3`/`LIVE-5` may accept an
allowed app's legacy card as a live item; the live surface owns that rule and
the item is not a banner. The debug poster's own ongoing notifications stay
forwardable in debug builds (the test seam that made the dismiss rule testable)
and carry their own `promoted=` record.

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

## Quiet updates: which posts may present (NOTIFY-19)

A notification that updates in place (a progress bar, a download, a timer)
posts again for every tick. Reusing the request identifier replaces the banner
on the Mac but does not make it quiet: `UNUserNotificationCenter.h`
(`addNotificationRequest:`, macOS 27.0 SDK) says *"A notification request with
the identifier as an existing delivered notifications will alert for the new
notification request and replace the existing delivered notification when it is
triggered."* Every update therefore presented again, which is the report's
first bug.

The decision now travels with the post. The phone marks `alert:true` on the
first post of a key and on an update Android would alert for, and `alert:false`
when the notification carries `FLAG_ONLY_ALERT_ONCE`, when its title and text
hash equals the last forwarded post of that key, or when the only thing that
moved is a progress bar (`NotifyEvents.alerts` with `progressOnly`: both posts
carry a bar and the title hash is unchanged, so "12 MB of 50 MB" → "13 MB of
50 MB" is quiet while the post that drops the bar is judged by its content).
The hashes live in memory and are never logged.

On the Mac, `NotifyPostPolicy.plan(alert:delivered:)` says what the post does:
`.banner` for an alerting post with no banner, `.quietAdd` for a quiet one —
`alert:false` is always quiet, so a LOW channel or a notification first seen
mid-life is listed without a banner — `.replace` for an alerting update, and
`.quietReplace` for a non-alerting update of a delivered banner. Both quiet
plans submit with `content.interruptionLevel = .passive`.

**Finding: a passive replacement is not presented.** `UNNotificationContent.h`
(macOS 27.0 SDK, `UNNotificationInterruptionLevel`) defines `.passive` as
*"Added to the notification list; does not light up screen or play sound"* and
`.active` as *"Presented immediately"*. Apple's documentation pages for
`UNNotificationInterruptionLevel` and its `passive` case
(`developer.apple.com/documentation/usernotifications/`) state the same. A
replacement therefore lands in the list and the quiet update is never shown as
a banner. Levels above `.active` are never set, and Focus is untouched
(NOTIFY-18): a passive notification is still subject to the person's Focus.

What this round does **not** prove: the system draws the banners, and host e2e
runs are quiet (`--share-log`), so "no second banner" rests on the header
definitions above plus the Mac's own record (`alert=`, `banners=`,
`presented=`, `quiet=` on each `notify post` line) and the K2 test that posts
ten times and reads it. A real banner's look stays with the `notify-vm` check.
If a future OS did present a passive replacement anyway, the fallback is the
one the spec allows: keep the delivered banner untouched and update only the
Mac's record (the LIVE row and the dismiss state); the record already
distinguishes a presented post from a quiet one.

The hold is not a delivery (2026-10-29 review finding): a post waits up to
300 ms for its picture, and an app that re-posts right away — to add an action
or an icon — supersedes that waiting post. The newcomer inherits the wait's
delivery state (`NotifyPostMerge.delivered`) and alerts if either post did
(`NotifyPostMerge.alert`), so only a banner already handed to Notification
Center can be replaced quietly. Without that, a quiet re-post 100 ms after an
alerting one left the person with no banner at all (`presented=0`).

## Conversations: the last message is the body (NOTIFY-3)

A `MessagingStyle` notification keeps its conversation in `EXTRA_MESSAGES` (a
`Bundle[]` of text, time and sender) and its name in `EXTRA_CONVERSATION_TITLE`;
`EXTRA_TITLE`/`EXTRA_TEXT` may both be empty, so r1 dropped such a post as
"no title and no text". The listener now walks the messages back to the last one
with text, uses that text as the body and, when `EXTRA_TITLE` is empty, the
conversation title (else that message's sender) as the title. A plain title and
text still win; the wire's per-string caps are unchanged, and a string over the
cap is dropped whole. MessagingStyle itself caps a message's own text at 1024,
so the wire cap is not reachable from a real conversation.

## Media notifications are not banners (NOTIFY-3)

A player's notification carries `EXTRA_MEDIA_SESSION`; while it plays it is also
ongoing, and r1's promoted-ongoing gate happened to skip it — but a paused
player is not ongoing, so the notification would banner on the Mac beside the Now
Playing row for the same session. A post carrying a media session is now skipped
with `notify skip media id=…` and its id joins the not-announced set (a removal
for a notification the Mac never saw is not news). Now Playing is unchanged.

## Channels: LOW and MIN are listed quietly (NOTIFY-21)

Android's shade shows a MIN channel in its silent section and a LOW one without
a heads-up; neither is a banner. The listener reads the channel's importance
from the system's ranking of the notification's key
(`getCurrentRanking().getRanking(key, ranking)`), marks every post of a LOW or
MIN channel `alert:false`, and still forwards it — the Mac lists it with
`.passive` (NOTIFY-19) instead of dropping a notification Android would show.
DEFAULT and above keep the alert rules, and a ranking the system does not
answer for leaves today's rules in place with `notify importance=unknown` in
logcat. The line carries the number (or `unknown`), never a channel name.

## Groups: summaries never land on their children (NOTIFY-20)

Android bundles a chat's messages into a group: each message is a child and the
app also posts one `FLAG_GROUP_SUMMARY` notification ("5 new messages") to fold
them. The listener forwarded both, and the summary — a different key, hence a
different banner — landed on top of the message that had just arrived. The wire
also had no group, so the Mac put every notification of a phone into one thread.

The phone now keeps a small machine per package+group (`NotifyGroups` in
NotifyEvents.kt, one pure transition function over `EMPTY`, `CHILDREN`,
`SUMMARY`; every transition is in `NotifyGroupMachineTest`):

- a summary forwarded on its own is quiet when the app asked for
  `GROUP_ALERT_CHILDREN` (`NotifyEvents.summaryAlerts`); children keep their
  own decision, so the child that takes a summary away still alerts;
- a child is forwarded and its id joins the group's set; a re-post of a known child is an update, not a second child (a chat updates its one notification per message);
- the summary is forwarded only while the group has no forwarded child;
- when a child arrives after a forwarded summary, the summary gets a
  `notify.remove` first and the child follows;
- a child's removal drops its id, and the last one leaving returns the group
  to `EMPTY` (the state is forgotten), so a later summary can be forwarded
  again; the set is bounded like the other maps.

A removal is announced for every id the phone forwarded, whatever its bounded
forwarded-id map still holds: the Mac keeps the banner, so a swallowed removal
is a ghost. The only silent removals are the summaries the phone deliberately
kept (they were never forwarded), remembered in a small bounded set.

The wire's `group` is 64 bits of SHA-256 over the package and the Android group
key (`NotifyEvents.groupHash`), never the key: apps put chat and folder names in
it, and a log or a thread identifier must not carry one. The Mac only accepts
that 16-lowercase-hex shape (`NotifyMapping.thread`) and threads a grouped post
under `<phone id>.<group>`; anything else joins the phone's own thread. Because
the hash is salted by the package (and 64 bits wide), it is not reversible to a
short name.

Not proven here: the machine's decisions on a real listener (a K1 class and the
fake phone's replay only). The emulator budget is 0 this round, so a real
WhatsApp group on a real phone stays with the next device pass; the e2e proves
the wire and the Mac's threading.

## Media part 2 design (v0.2 #9)

Deeper media control: the Mac's Now Playing becomes a local player. The phone still
reads sessions with `MediaSessionManager.getActiveSessions(listener)` inside the
notification listener, throttled to ≤ 1/s, and the existing gate is unchanged —
nothing media leaves the phone unless notification sharing is on. No new gate.

### Artwork

The phone takes the chosen session's `MediaMetadata` artwork in this order:
`METADATA_KEY_ART`, `METADATA_KEY_ALBUM_ART`, `METADATA_KEY_DISPLAY_ICON`, and, for
each, the `*_URI` variant only when a `ContentResolver` open works in the app
process. A bitmap or an `Icon` is rasterised; a URI that cannot be opened is
skipped (the next source is tried). The picture is scaled to at most 512×512
(aspect kept, never enlarged), encoded as JPEG quality 80, and sent only when it
is at most 256 KiB. This is a pure rule ([MediaArtRules]) behind the same
`BitmapSource` seam the notification pictures use, and it is JVM-tested with a
fake source.

The wire message is `media.art {key, mime, w, h, data}` (data = base64 of the
encoded bytes), sent once per change: the phone hashes the scaled bytes (SHA-256,
first 16 hex chars) and keeps the last hash per session key, so an unchanged
picture is never re-sent. No artwork means `media.art {key}` with no data, which
clears it. Logs carry bytes, w×h and a hash prefix only — never the picture.

On the Mac the picture becomes an `MPMediaItemArtwork` in `nowPlayingInfo`; the
menu bar extra's media row shows it small. Artwork in tests is a generated test
pattern.

### Position and seek

`media.state` already carries `positionMs`, `durationMs` and `rate`; it gains
**`canSeek`** (the phone's `PlaybackState` lists `ACTION_SEEK_TO`). The Mac
enables `MPRemoteCommandCenter.changePlaybackPositionCommand` only while
`canSeek`, which sends `media.command {action:"seek", positionMs}`. The phone
calls `transportControls.seekTo` and the next `media.state` confirms. The
`skipForward`/`skipBackward` commands are 15 s seek steps by the same route, and
are enabled only while `canSeek`. `positionMs` is clamped to
`[0, durationMs]` (unclamped above 0 when the session reports no duration).

### Several playing apps

The phone keeps the list of active sessions in the order the system reports
them. The **chosen** session is the Mac's pick while that key is still active,
else the system's first. A new message `media.sessions {list, chosen}`:

- `list` = `[{key, pkg, app, playing}]` in system order. `key` is an opaque
  per-session id the phone mints; `app` is the app label. The list never carries
  titles, artists or albums.
- `chosen` = the key `media.state` describes.

`media.command` and `media.state` gain an optional `key`. `media.choose {key}`
(Mac → phone) picks a session; an unknown key is ignored with a log line and the
chosen session does not move. On the Mac the menu bar extra's media row gets a
"Playing on phone: <app>" submenu listing the sessions when there are two or
more. A phone that predates `media.sessions` keeps today's behaviour: one
session, no submenu.

### Volume

Phone → Mac: `volume` and `volumeMax` in `media.state`, read from the chosen
session's `MediaController.playbackInfo` (local playback = the music stream).
Mac → phone: `media.command {action:"volume", level}` → the app process calls
`MediaController.setVolumeTo(level, 0)` — no shell call, no system UI flag. The
level is clamped to `[0, volumeMax]`. The Mac UI is a slider in the menu bar
extra's media row; the Mac's own volume keys stay the Mac's and are not
intercepted.

### Older peers

A command from an older Mac carries no `key` and acts on the chosen session, as
before. An older phone ignores `media.choose` and `media.art` like any unknown
`t`, and never sends `media.sessions`; the Mac then shows today's single-session
Now Playing. Unknown fields are ignored on both sides.

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
  should run. So on a real listener **unverified**: action mapping,
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
  never reaching the manifest receiver; the emulator script now sends it with
  `-p app.contigua`, keeps each broadcast's output in `broadcast.log`, and its
  assertions pass against a synthetic log (`--self-test`). So on a real listener
  **unverified**: reply/button mapping, RemoteInput fill, `cancelNotification`, the
  ongoing refusal, the picture extraction and the promoted flag the system sets.
- **VM (1 session used)**: the guest showed its own system banner ("App Background
  Activity") but no Contigua banner in any phase, so every AX press found nothing
  (`notfound`) and the screenshots are of the same plain screen. The run's app log was
  overwritten by the next phase, which failed to start fakephone because the previous one
  still held the port (the check now stops the fake between phases), so the extended
  picture and live phases never ran. `check_notify_vm` now also reports whether macOS
  authorized the app (`notify authorization granted=…`) instead of only failing to find
  buttons. Part 1's reply field, Copy code, banner clear (`customDismissAction`) and part
  2's picture banner and live menu section remain **unproven**; ROADMAP #8 is not ticked.

Screenshots from that session: `macos/build/vm-e2e/notify3/work/shots/` (the plain
screen, plus the system banner — kept as the record of what did and did not appear).

## Media part 2 results (v0.2 #9)

Built: the chosen session's artwork (`media.art`, scaled to ≤ 512 px, JPEG q80,
≤ 256 KiB, sent once per change and deduped by a hash of the scaled bytes), a
position bar and 15 s skips gated on `canSeek` (`media.command seek` with the
position clamped to the track), the list of playing apps and the choice among
them (`media.sessions` / `media.choose`, opaque per-session keys minted by the
phone), and the phone's media volume from a menu bar slider
(`media.command volume`, the level clamped to `[0, volumeMax]`). The phone side
is the listener plus a pure rules seam (`MediaControl`, `MediaArtRules`); the
debug fake media session lives in the debug source set only, DUMP-protected
like the notification poster. The Mac maps artwork to `MPMediaItemArtwork`,
enables `changePlaybackPositionCommand` / `skipForward` / `skipBackward` only
while `canSeek`, and lists the playing apps in a "Playing on phone" submenu when
there are two or more.

Verified (K1 595 unit tests 0 failures; K2 856 tests 0 failures; host e2e
`media` 23/23 twice, regressions `notify-media` 21/21 and `notify` 22/22, all
quiet share-log runs):

- the phone's two sessions arrive in the system's order with their opaque keys,
  and `media.state` carries the chosen `key`, `canSeek`, `volume`/`volumeMax`
  and the position; the artwork arrives once, at 160×120 from the fake's
  generated card, with only bytes, dimensions and a hash prefix in the log;
- a seek past the end leaves the Mac clamped to the track's 30 s, reaches the
  phone with that value, and the next `media.state` is at the new position;
- a volume of 99 is clamped to the session's maximum of 15 on the Mac, reaches
  the phone as 15, and the next `media.state` reports 15/15;
- `media.choose` switches the chosen session, the next `media.sessions` and
  `media.state` carry the picked key, and that session's artwork arrives once;
- an older phone (`--older-phone`: today's `media.state` only) still drives Now
  Playing, gets no seek/volume UI, and its transport commands still work;
- no title, artist, album or artwork byte appears in any log.

Not verified:

- **Emulator (second boot spent, API 36, `tools/emulator/verify-batch.sh`)**:
  the rig booted, installed 102 (the versionCode check passed), paired over v2
  and the icon section passed, but the media section got no media messages at
  all. The three debug broadcasts were delivered to the explicit component
  (`cmp=app.contigua/.app.MediaDebugTrigger`, `Broadcast completed:
  result=0`), `notify.enable on=true` went out, and then the phone sent nothing
  for 40 s: no `media.sessions`, no `media.state`, no `media.art`, and no
  `PdMediaDebug` seek/volume lines. `media.sh` reports 12 failed assertions and
  the run's logcat was gone with the emulator, so the cause is narrower but not
  settled: either the notification listener was not bound after the section's
  own app restart (the phone scans media sessions from it, and nothing else
  would explain complete silence), or the fake sessions do not surface through
  `getActiveSessions` on this image. The rig now waits for the enabled listener
  and records the debug/server logcat lines and the listener setting when the
  section fails, so the next boot's log names the cause. The boot budget allows
  no second boot here. (Settled later, on the JVM: see "Why the emulator
  reported no media sessions" below.)

  ### Why the emulator reported no media sessions

The listener read `getActiveSessions` once, at `onListenerConnected`, and then
trusted the system's `OnActiveSessionsChangedListener`. A read that lands before
a session exists (the rig starts its fake sessions after the app), or a missed
callback, leaves the list empty for the rest of the process. On top of that,
every push made before the Mac's `notify.enable` is dropped by the gate, and the
session and artwork dedupe caches were updated on those dropped pushes, so a
later push of the same list was skipped as unchanged. The two together explain
the silence: no `media.sessions`, no `media.state`, and `media command …
ignored: no session attached` while the listener was connected.

The listener now re-reads the stack at connect, when the gate opens and when a
command finds nothing attached, and it remembers only what a Mac actually
received. `MediaSessionScanTest` (Robolectric,
behind a recording seam in `PdNotificationBridge`) pins both cases: on the old
listener the late gate and the callback-less session both fail (the second with
`media command play ignored: no session attached`); with the fix both pass.

The second boot (`verify-batch`, 2026-10-20) reached the media section and showed
the other half of the silence: `dumpsys media_session` said `Sessions Stack -
have 0 sessions` and no `PdMediaDebug` line existed at all, while the listener
logged `media scan n=0` for the gate and for each command. The rig's
`debug_broadcast` helper sent `am broadcast -n <component>` without the intent
action, so `MediaDebugTrigger.onReceive` returned at its `action != ACTION`
check and no fake session was ever created; "the broadcast was delivered"
(`result=0`) was true and meaningless. The helper now sends `-a <action>`, the
receiver logs the action it ignored, `media.sh --check` asserts the helper's
intent carries it, and preflight counts the boot ledger by its actual columns
(it reported "0 of 2 used" whatever the ledger held). The media section itself
still has not run on a device: the budget for this round is spent.

The next boot (2026-10-20 22:09, commit 60f1acb) paired, passed the paired-row,
phone-screen, secure and icon sections, and the media section failed one step
further in: the three broadcasts now carried their action and were delivered,
and the receiver logged `refused: no DUMP` for the stop broadcast. Its runtime
check (`checkCallingOrSelfPermission(DUMP)`) can never pass: `onReceive` runs
outside a binder call, so it sees this app's own permissions and the app does
not hold DUMP. The manifest's `android:permission="android.permission.DUMP"` on
the receiver is the sender gate (adb shell holds it) and stays; the runtime
check is gone, and preflight now fails if that manifest permission disappears.
The media section is still unproven on a device (the boot budget for this round
is spent): the fake sessions have never started under the current rig.

Still unproven on a real listener: `getActiveSessions` ordering and key
  minting, artwork from a real `MediaMetadata` (bitmap and `*_URI` sources),
  `transportControls.seekTo`, the local-playback volume (`playbackInfo` +
  `setVolumeTo`), and the session list shrinking when an app stops.
- **Real apps** (YouTube Music, Spotify) and **the Mac menu bar's look** (the
  small artwork, the slider, the picker) were not seen on screen: host e2e is
  quiet and the VM is out of this brief's budget.

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
  the emulator; otherwise the gaps are listed in the doc.
