# Contigua — Android app

The phone side of Contigua: run Android apps in native, resizable Mac windows
while the phone stays **locked**. Single Gradle `:app` module, `app.contigua`.

The wire contract is `docs/PROTOCOL.md`; the design is `docs/ARCHITECTURE.md`.
Where this code and the docs disagree, the docs win (or the doc gets a proposal).

## Layout

```
app/src/main/java/app/contigua/
  proto/     frame codec + minimal JSON + hex/HMAC (pure Kotlin, no Android)
  server/    the shell process: DeckService (AIDL), Server, Session, WindowStream,
             InputInjector, AppLauncher, Power, AndroidPower/PanelPower/DisplayProbe,
             WindowDevice/AndroidWindowDevice/CompanionAssociation, Watchdog,
             AndroidWindowObserver, Hidden, ShellContext +
             the platform interfaces Session depends on
  app/       MainActivity (Compose host), DeckForegroundService, BootReceiver,
             NsdAdvertiser, ShizukuClient, Prefs, DeckState, QrPairing (pure)
  ui/        Compose UI: theme/, DeckViewModel + DeckUiState (pure mapping),
             Onboarding/Home/PairingDialog screens, QrScan
  launcher/  LauncherActivity + LauncherScreen (phone-mode home)
```

The session core (`Session`, `Server`, `SendQueue`, the interfaces in
`Platform.kt`) has **no Android imports**, which is what makes the JVM tests and
the C4 harness possible. The UI is Jetpack Compose + Material 3; all copy and
visual values come from `docs/UX.md` and `docs/DESIGN.md`.

## Build

```bash
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :app:assembleDebug :app:testDebugUnitTest
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

`versionCode` is the **Shizuku user-service version**: the daemon keeps running
after an install unless the number grows, so bump it on every device install.

Shizuku must be running. The first-run onboarding walks through installing and
starting it, granting the app permission and turning **Keep Contigua running** on
(**Allow connections** stays on unless someone turns it off).

## How it works

- The app process only does UI, pairing and mDNS advertising
  (`_contigua._tcp`, TXT `v/id/name/model`).
- `DeckForegroundService` binds the Shizuku **user service** (`DeckService`,
  shell UID 2000), calls `startServer()` and pushes the paired-client list over
  AIDL. The service reports its ephemeral port back.
- Each Mac window is one `WindowStream`: a `VirtualDisplay` whose surface is a
  `MediaCodec` H.264 encoder input. Frames go straight to the socket.
- Input is injected on the window's display via `IInputManager.injectInputEvent`
  with `InputEvent.setDisplayId`.

### Window displays and their group

A window display must sit in a display group of its own, or it sleeps and wakes
with the phone's screen (docs/specs/app-windows.md WIN-74). The server takes
the first route that works:

- **Virtual device (Android 14+, One UI).** One platform virtual device
  (`VirtualDeviceManager.createVirtualDevice`, reached by reflection at shell
  UID) makes every window display. It is created from Contigua's own companion
  association: owned by `com.android.shell`, profile
  `COMPANION_DEVICE_APP_STREAMING`, self-managed, fixed address
  `02:c0:4e:00:00:01` (`CompanionAssociation`, created once with
  `cmd companiondevice associate` and removed by Forget All Macs). The device
  shares the phone's clipboard and keeps its tasks out of the phone's Recents
  (`POLICY_TYPE_CLIPBOARD` and `POLICY_TYPE_RECENTS` = custom). The display
  flags are

  `PUBLIC | PRESENTATION | OWN_CONTENT_ONLY | SUPPORTS_TOUCH | ROTATES_WITH_CONTENT |
  DESTROY_CONTENT_ON_REMOVAL | TRUSTED | DEVICE_DISPLAY_GROUP | ALWAYS_UNLOCKED |
  TOUCH_FEEDBACK_DISABLED | OWN_FOCUS | STEAL_TOP_FOCUS_DISABLED` (`0x1f5cb`).

  One UI ignores `OWN_DISPLAY_GROUP` on a plain display but gives a device
  display its own group. The device is made with the first window and closed
  with the last (`WindowDevice`, a pure state machine).
- **Plain display (AOSP, the emulator).** No device could be made (no service,
  no association, refused): the classic flags with `OWN_DISPLAY_GROUP` instead
  of the device group.
- **Refused.** A display that still reads group 0 is released before anything
  launches on it, and the Mac gets `error {code: "windows_unsupported"}`.

The system-decorations flag is never set: it adds a SystemUI nav bar to the VD
and, on One UI, poisons `SysUiState` so the phone's back gesture dies until
reboot.

`ALWAYS_UNLOCKED` + `OWN_CONTENT_ONLY` are the whole locked-phone feature. Each
window display's IME policy is set to HIDE; back is `KEYCODE_BACK` stamped with
the VD id. The VD is built from a hidden `VirtualDisplayConfig` so that, on
SDK ≥ 36, `ignoreActivitySizeRestrictions` is set and apps that declare a fixed
size/orientation still fill any Mac-window size.

Debug builds take `debug.contigua.vd_plain=1` (skip the device: the plain
route) and `debug.contigua.vd_panel_group=1` (a display in group 0: the
refusal), read at every open. `tools/emulator/vd-group.sh` checks all three.

Every VD creation logs the requested flags, the creation path and the resulting
`DisplayInfo` (`flags`, `displayGroupId`, `state`) with the hidden
`DisplayManagerGlobal.getDisplayInfo`:

```
windowdevice: device 7 made association=26 recents=params clipboard=params
stream 1 vd=57 1280x800 dpi=240 path=VirtualDisplayConfig
stream 1 vd=57 requested flags=0x1f5cb (PUBLIC|…|ALWAYS_UNLOCKED|…)
stream 1 vd=57 display 57: group=2 state=ON flags=… (TRUSTED|…)
```

Root cause and the AOSP source trail: `docs/research/display-groups.md`.

### Power

No session → no VD, no encoder, no wake lock, no polling threads. With an app
window open the server keeps **only the window displays' own group** awake:
`userActivity(displayId)` + `wakeUpWithDisplayId(displayId)` before a launch,
on input and on a keep-alive timer, a PARTIAL wake lock, and a
**display-scoped** `SCREEN_BRIGHT` wake lock per window display (hidden
`PowerManager.newWakeLock(levelAndFlags, tag, displayId)`). While those locks
are held the timer runs every 60 s as a safety net; without the hidden call it
runs every 10 s. `debug.contigua.force_timer_keepalive=1` skips the display
wake locks, for measuring the timer path. Display 0 is never named: the phone's
own screen sleeps on its own timeout, a power press works as usual, and the
keyguard is never dismissed. A virtual device's group never times out on its
own, so the server releases its displays itself.

**Refresh floor (One UI).** SurfaceFlinger paces every display by the built-in
panel, so a window display draws no faster than the panel's render rate. In
Always-On Display the AOD plugin caps the panel at 30 Hz with a
`RefreshRateMaxLimitToken` (`PRIORITY_REFRESH_RATE_MAX_LIMIT`, priority 1).
While the window device is open the server holds a 60 Hz
`RefreshRateMinLimitToken` (hidden
`IDisplayManager.acquireRefreshRateMinLimitToken`, tag `contigua`), whose
`PRIORITY_REFRESH_RATE_MIN_LIMIT` (priority 2) outranks it; the device's
`made` log line says `floor=60` or `floor=none`. The token is linked to the
service's binder, so it goes when the process dies; no setting changes and
the panel is never woken (`RefreshFloor`, docs/specs/app-windows.md WIN-76).
`dumpsys display` lists it under `RefreshRateTokens`.

A device display keeps the platform's *global* wakefulness awake while group 0
dozes, so every "is the phone's screen on" check reads display 0
(`ScreenState.read`), never `PowerManager.isInteractive()`.

**Turn Off Phone Screen** (the Phone Mirror, `phone.panel`, `PanelHold`) is the
one panel control left:

- the panel is powered off through SurfaceFlinger
  (`SurfaceControl.setDisplayPowerMode(token, POWER_MODE_OFF)`, token from
  `com.android.server.display.DisplayControl` loaded out of `services.jar`)
  while the mirror keeps rendering, with a 2 s user-activity poke on display 0
  so the mirrored group does not time out;
- the person's power press (display 0 leaving ON) ends the hold, unless the
  Mac's keep-it-off setting is on;
- every end gives the panel back with `POWER_MODE_NORMAL`;
- **crash guard:** while the override is live, a marker file
  (`/data/local/tmp/contigua/panel-off`) is written and a tiny second
  `app_process` (`contigua-watchdog`, the same APK) holds a loopback socket to
  the server and blocks on a read. If the server dies, the watchdog restores
  `POWER_MODE_NORMAL` (only when the marker exists and the platform believes
  the panel is on), calls `goToSleep`, and exits. Orphan VDs and the virtual
  device are released by system_server when their owner dies.

### Device state (locked / battery)

`state` is event-driven, never polled: the shell process registers the hidden
`IWindowManager.addKeyguardLockedStateListener` (reflective proxy whose
`asBinder()` hands system_server a binder that parses
`onKeyguardLockedStateChanged`), or — on a build without that call — the
`ACTION_SCREEN_ON/OFF/USER_PRESENT` broadcasts re-reading
`KeyguardManager.isDeviceLocked`. Battery comes from a sticky
`ACTION_BATTERY_CHANGED` receiver. A tracker dedupes both, so the session sends
`state` once right after `welcome` and then only when the integer battery %,
the charging flag or the lock state really changes.

### Live quality

`window.quality` (optional, best-effort) sets a stream's bitrate target
(`PARAMETER_KEY_VIDEO_BITRATE` via `setParameters`) and an fps cap
(`max-fps-to-encoder` at the next configure, plus frame dropping above the cap).
The full-size bitrate computed from the pixels is the default target. When the
session drops deltas because a stream's backlog exceeds the protocol's ~250 ms
budget (both a byte budget and the video duration of the queued frames), the
stream's bitrate falls 25% (floor 1 Mbps) and grows back 10% every 5 s without a
drop, up to the target; every change is logged once.

### Typed text

`text` is split into ASCII runs (typed via `KeyCharacterMap`) and non-ASCII runs
(`é`, `ç`, `ã`, emoji), which are delivered by setting the primary clipboard clip
through the shell `IClipboard` and injecting `KEYCODE_PASTE` on that display; the
previous clip text is restored shortly after.

## Tests

```bash
./gradlew :app:testDebugUnitTest
```

- `proto/` — frame round-trips, big-endian floats, 8 MiB limit, JSON parser
  (nesting, escapes, surrogate pairs, numbers).
- `server/` — `SendQueue` priority/backpressure (byte and video-duration
  budgets); `Session` over a real loopback socket: auth success/failure, pairing
  (happy path and 3 wrong codes), messages rejected before `welcome`, `busy`
  second session, challenge carrying the device id, window lifecycle with sizes
  floored to 16, input timing, titles, state (initial + on change + dedupe),
  `window.quality`, `no_stream`/`launch_failed` errors, and app-exit →
  `window.closed(app_exited)`; plus the pure `TextRuns` split, `AppExit` close
  decision, `DeviceStateTracker` dedupe, `QualityAdaptation` (drops, recovery,
  floor/cap), the watchdog decision and `LauncherOverloads` ordering.
- `app/` + `ui/` — the pure pieces: QR pairing URI parsing, pairing-code
  formatting, and the input → status-card / onboarding-step mappings.
- `ui/ScreenshotTest` — Robolectric + Roborazzi screenshots at 412×915 dp, light
  and dark, using the static seeded color scheme. Run with the record system
  property set (the Gradle build sets `roborazzi.test.record=true`); PNGs land in
  `app/src/test/screenshots/`.

### C4 interop harness

Runs the real `Session` against the Python fake client
(`tools/fakephone/deckctl.py`) with a canned H.264 clip:

```bash
ffmpeg -f lavfi -i testsrc2=size=640x480:rate=30 -t 3 -c:v libx264 -bf 0 -f h264 /tmp/c4.h264
./gradlew :app:c4Harness -Pc4args="--h264 /tmp/c4.h264"   # prints PORT=<n>
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port <n> --pair apps
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port <n> --pair \
    open com.android.settings --w 640 --h 480 --seconds 2 --out /tmp/a.h264
```

## Known limitations (v0)

- Plaintext + HMAC only (TLS is a later milestone, per the protocol).
- Single touch pointer; multi-touch pointer ids are carried but not fanned out.
- `nav recents` and `clipboard.set` are no-ops.
- `apps.icon` and `window.title` are best-effort; app-exit detection polls the
  per-display task list at most every 2 s, so a window closes up to ~2 s after
  the app leaves its display.
- Typing non-ASCII text uses the clipboard internally (see above), so it briefly
  replaces the user's clip.
