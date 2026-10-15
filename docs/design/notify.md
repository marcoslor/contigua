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
- Notifications on the Mac: UserNotifications, title = app label (apps list, fallback pkg),
  text = body, grouped per phone (`threadIdentifier` = phone id); clicking opens that app's
  window when the phone's app list has the package.
- Media on the Mac: MPNowPlayingInfoCenter + MPRemoteCommandCenter (play/pause/next/prev ticked
  off through `media.command`); cleared when `media.state` shows nothing.
- Dismiss on the Mac → dismiss on the phone: not feasible — macOS UserNotifications cannot
  report a banner clear (responses fire only for clicks and app-declared actions), and the shell
  cannot cancel other posters' notifications.

## Protocol (docs/PROTOCOL.md, session-level JSON)

- mac→phone: `notify.enable {on}` — when the per-phone toggle changes and again on reconnect;
  `media.command {action: play|pause|next|prev}`.
- phone→mac: `notify.state {on}` (true once granted and forwarding); `notify.post {id, pkg, app?,
  when, title?, text?, ongoing?}`; `notify.remove {id}`; `media.state {playing, pkg?, title?,
  artist?, album?, durationMs?, positionMs, rate}` — empty media.state (no list fields) clears
  Now Playing.
- Privacy: notification or media text is never logged (`--notify-log` records only pkg/count);
  without an answered `notify.enable {on:true}` nothing is forwarded; disconnect clears the
  Mac's local state.

## Checks

- Unit tests: notification mapping (title/text extraction incl. BIG_TEXT, caps, skip rules),
  gate (toggle off → nothing leaves), media-state → nowPlayingInfo mapping, command mapping.
- e2e (`check_notify`, and in `all`): fakephone `--notify`/`--media` emit the phone→mac events
  after welcome; the Mac's `--notify-log` shows posts; the click hook delivers the same handler
  a UNNotification click would (fakephone logs `window.open`); media-command hooks deliver
  play/pause/next/prev (fakephone logs rx `media.command`).
- Emulator end to end on emulator-5588: `cmd notification post` → Mac banner (screenshot);
  toggle off → no forwarding; Fossify player → Now Playing at the Mac (values logged); play/
  pause/next/prev from the Mac move the phone session (`dumpsys media_session`); click →
  window.open on the phone (window opens that app's display).
- ROADMAP #7 is marked done only if notifications AND media controls both work end to end on
  the emulator; otherwise the gaps are listed in `.agent/notify/progress.md` and the doc.
