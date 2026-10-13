# PocketDeck — Android app

The phone side of PocketDeck: run Android apps in native, resizable Mac windows
while the phone stays **locked**. Single Gradle `:app` module, `dev.pocketdeck`.

The wire contract is `docs/PROTOCOL.md`; the design is `docs/ARCHITECTURE.md`.
Where this code and the docs disagree, the docs win (or the doc gets a proposal).

## Layout

```
app/src/main/java/dev/pocketdeck/
  proto/     frame codec + minimal JSON + hex/HMAC (pure Kotlin, no Android)
  server/    the shell process: DeckService (AIDL), Server, Session, WindowStream,
             InputInjector, AppLauncher, Power, AndroidPower/PanelPower/DisplayProbe,
             DarkPanelPolicy, Watchdog, AndroidWindowObserver, Hidden, ShellContext +
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
starting it, granting the app permission and turning **Allow connections** on.

## How it works

- The app process only does UI, pairing and mDNS advertising
  (`_pocketdeck._tcp`, TXT `v/id/name/model`).
- `DeckForegroundService` binds the Shizuku **user service** (`DeckService`,
  shell UID 2000), calls `startServer()` and pushes the paired-client list over
  AIDL. The service reports its ephemeral port back.
- Each Mac window is one `WindowStream`: a `VirtualDisplay` whose surface is a
  `MediaCodec` H.264 encoder input. Frames go straight to the socket.
- Input is injected on the window's display via `IInputManager.injectInputEvent`
  with `InputEvent.setDisplayId`.

### Virtual-display flags

`PUBLIC | PRESENTATION | OWN_CONTENT_ONLY | SUPPORTS_TOUCH | ROTATES_WITH_CONTENT |
DESTROY_CONTENT_ON_REMOVAL | TRUSTED | OWN_DISPLAY_GROUP | ALWAYS_UNLOCKED |
TOUCH_FEEDBACK_DISABLED | OWN_FOCUS`

Two flags are deliberately **never** set:

- the system-decorations flag — it adds a SystemUI nav bar to the VD and, on
  One UI, poisons `SysUiState` so the phone's back gesture dies until reboot;
- the device display-group flag — the VD would follow the panel's power state and
  freeze while the phone is locked.

`ALWAYS_UNLOCKED` + `OWN_CONTENT_ONLY` are the whole locked-phone feature. The
VD's IME policy is set to HIDE; back is `KEYCODE_BACK` stamped with the VD id.
The VD is built from a hidden `VirtualDisplayConfig` when available so that, on
SDK ≥ 36, `ignoreActivitySizeRestrictions` is set and apps that declare a fixed
size/orientation still fill any Mac-window size; any failure falls back to the
classic 6-arg `createVirtualDisplay`.

### Power

No session → no VD, no encoder, no wake lock, no polling threads. With a session,
`userActivity(displayId)` + `wakeUpWithDisplayId(displayId)` are poked when a
stream opens or resizes, alongside a PARTIAL wake lock. There is **no** fallback
to the global wake-up call and the keyguard is never dismissed: the poke names
the streaming display's own group (`PowerManagerService.wakeUpWithDisplayId`
wakes the power group of that display's display group).

Each unpaused stream also holds a **display-scoped** `SCREEN_BRIGHT` wake lock
bound to its virtual display (hidden `PowerManager.newWakeLock(levelAndFlags,
tag, displayId)`, API 33+), so the VD's power group holds itself awake instead of
depending on the timer. While those locks are held the keep-alive timer slows to
60 s (it is a safety net, and it still drives the panel policy); without the
hidden call it stays at 10 s. `debug.pocketdeck.force_timer_keepalive=1` skips
the display wake locks, for measuring the timer path.

The *physical* panel is a separate story, and the server picks one of two
strategies from the display group the VD actually got (logged at creation, see
below):

- **Own display group (AOSP).** Waking the VD's group leaves the panel's group
  (group 0) off. Nothing else to do; the panel power mode is never touched.
- **Panel group (vendor builds that ignore `OWN_DISPLAY_GROUP`, e.g. Samsung One
  UI).** The same wake also turns the panel on, so right after our own wake the
  panel is powered off through SurfaceFlinger
  (`SurfaceControl.setDisplayPowerMode(token, POWER_MODE_OFF)`, token from
  `com.android.server.display.DisplayControl` loaded out of `services.jar`).
  The override is re-applied after our own wakes only — never in a loop — and a
  transitional wake re-applies it twice more (0.5 s and 1.5 s) because the
  platform's display power controller writes its own mode while it processes the
  wake. Waking on *input* is skipped in this mode: the keep-alive owns the group
  and the panel.
- **The user wins.** If the panel was on (ours, forced dark) and then reports
  off, that was a power-button press: the server stops waking and stops
  re-applying until the screen has been on and off again, so normal Android
  behaviour takes over. The keyguard is never dismissed and the phone is never
  unlocked.
- **Restore.** When the last stream pauses/closes or the session ends, the panel
  power mode is set back to NORMAL *only* if the platform believes the panel is
  on (the override is masking it), then `IPowerManager.goToSleep(…,
  GO_TO_SLEEP_REASON_APPLICATION)` puts the phone back to its normal locked-off
  state. Never called when the user has the phone.
- **Crash guard.** While the override is live, a marker file
  (`/data/local/tmp/pocketdeck/panel-off`) is written and a tiny second
  `app_process` (`pocketdeck-watchdog`, the same APK) holds a loopback socket to
  the server and blocks on a read. If the server dies (crash, `kill -9`, Shizuku
  restart), the read returns without the clean-shutdown byte: the watchdog then
  restores `POWER_MODE_NORMAL` (only when the marker exists and the platform
  believes the panel is on) and calls `goToSleep`, then exits. The watchdog is
  started lazily on the first panel-off and stopped when the episode ends, so
  own-group builds never pay for it. Orphan VDs are released by system_server
  when their owner dies; no wake lock survives a dead process.

`debug.pocketdeck.force_panel_off=1` forces the panel-dark path (used by the
emulator checks, where AOSP gives the VD its own group).

Every VD creation logs the requested flags, the creation path
(`VirtualDisplayConfig` vs the classic call) and the resulting `DisplayInfo`
(`flags`, `displayGroupId`, `state`) with the hidden
`DisplayManagerGlobal.getDisplayInfo`, which is what tells the two strategies
apart on a new build:

```
stream 1 vd=57 1280x800 dpi=240 path=VirtualDisplayConfig
stream 1 vd=57 requested flags=0x7dcb (PUBLIC|…|OWN_DISPLAY_GROUP|ALWAYS_UNLOCKED|…)
stream 1 vd=57 display 57: group=0 state=ON flags=0x4f88 (TRUSTED|OWN_DISPLAY_GROUP|…)
```

Root cause and the AOSP source trail: `docs/research/display-groups.md`.

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
./gradlew :app:c4Harness -Pc4args="--code-file /tmp/code.txt --h264 /tmp/c4.h264"   # prints PORT=<n>
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port <n> --code-file /tmp/code.txt apps
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port <n> --code-file /tmp/code.txt \
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
