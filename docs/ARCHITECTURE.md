# PocketDeck — architecture (v0)

Continuity-style Android ⇄ macOS: run Android apps in native, resizable Mac
windows (one window per app, several at once) and a "phone" window — **while the
phone stays locked**. LAN only. Open source.

```
 macOS app (Swift)                          Android phone
┌────────────────────────┐   1 TCP session  ┌─────────────────────────────────────┐
│ Launcher (apps, ⌘K)    │  (PROTOCOL.md)   │ App process (dev.pocketdeck)        │
│ AppWindow × N ─────────┼─────────────────►│  UI, pairing prompt, NSD advertise, │
│  AVSampleBufferDisplay │◄─────────────────┤  Shizuku binding                    │
│  Layer per stream      │                  │        │ AIDL (control only)        │
│ PhoneWindow            │                  │ Shell service (UID 2000, Shizuku)   │
│ Bonjour browser        │                  │  TCP server ◄── the session lives here
└────────────────────────┘                  │  SessionManager → WindowStream × N  │
                                            │    VirtualDisplay + MediaCodec      │
                                            │  InputInjector, AppLauncher, Power  │
                                            └─────────────────────────────────────┘
```

## Key decisions

1. **The phone is the server, inside the Shizuku shell process.** No hub, no
   relay. UID 2000 has network access and is not subject to app-standby/Doze
   network restrictions; encoder output goes straight to the socket (no AIDL
   frame hop). The app process only does UI, the pairing prompt and NSD
   advertising (the service reports its port over AIDL).
2. **One virtual display (VD) per Mac window.** Each `WindowStream` owns a VD,
   an H.264 encoder whose input surface backs the VD, and a stream id.
   Resizing the Mac window resizes the VD (`VirtualDisplay.resize`) and
   reconfigures the encoder.
3. **VD flags** (proven on Galaxy S25+, Android 16):
   `PUBLIC | PRESENTATION | OWN_CONTENT_ONLY | SUPPORTS_TOUCH |
   ROTATES_WITH_CONTENT | DESTROY_CONTENT_ON_REMOVAL | TRUSTED |
   OWN_DISPLAY_GROUP | ALWAYS_UNLOCKED | TOUCH_FEEDBACK_DISABLED | OWN_FOCUS`.
   - **Never `SHOULD_SHOW_SYSTEM_DECORATIONS`** — it adds a SystemUI
     NavigationBar to the VD and, on One UI, poisons `SysUiState`
     (`backGestureDisabled`) so the phone's back gesture dies until reboot
     (scrcpy #6007). Back = `KEYCODE_BACK` stamped with the VD display id.
   - **Never `DEVICE_DISPLAY_GROUP`** — the VD would follow the panel's power
     state and freeze while the phone is locked. Note: some OEM builds (Samsung
     One UI) ignore `OWN_DISPLAY_GROUP` and put the VD in the panel's group
     anyway (`displayGroupId 0`); the phone side detects that from the VD's
     `DisplayInfo` at creation and powers the panel off through SurfaceFlinger
     while it streams, so the locked panel shows nothing and the VD still
     renders (never unlocked, no keyguard dismissal) — see android/README.md.
   - `ALWAYS_UNLOCKED` keeps apps (not the keyguard) on the VD while the phone
     is locked. This is the whole "locked phone" feature.
   - Display IME policy = HIDE (no soft keyboard on the VD; Mac keyboard types).
4. **Phone mode** = a phone-aspect VD showing **PocketDeck's own launcher
   activity** (app grid + search, `dev.pocketdeck.launcher`) — not the system
   launcher (that needs decorations → #6007). Apps launched from it open on the
   same display. Home = relaunch our launcher on that display. Mirroring the
   physical screen is out of scope for v0 (it would require unlocking).
5. **Mac rendering:** compressed H.264 → `CMSampleBuffer` →
   `AVSampleBufferDisplayLayer` with `DisplayImmediately`. No CPU readback, no
   `CGImage`/`NSImage`, no `draw(_:)`. (The old client's VT→CIImage→CGImage→
   NSView path was the main source of the "laggy mouse".)
6. **Input** is binary frames on the same TCP session, sent immediately per
   NSEvent (moves coalesced to at most one per display refresh). The phone
   injects synchronously on the socket reader thread with cached reflection
   handles. No sleeps in the touch path. A trackpad's two-finger scroll is a touch drag (so Android
   flings), its pinch and rotate are two pointers from the raw fingers; only a mouse wheel is a SCROLL.

## Power / battery rules (acceptance criteria, not suggestions)

- No session → no VD, no encoder, no wake lock, no polling threads. Idle cost =
  one listening socket + NSD registration.
- Session but no windows → no VD/encoder; TCP keepalive only (app-level ping
  from the Mac every 15 s).
- Mac window minimized/hidden/fully occluded → `window.pause`: encoder stopped
  (VD surface detached), app stays alive.
- Static content → encoder emits nothing (no repeat-frame setting).
- Keep-awake: the VD's display group must not time out while a window is
  visible on the Mac. Poke `userActivity` + `wakeUpWithDisplayId` for the VD's
  group when a stream opens, on input (throttled to ≤1/s) and on a timer every
  10 s while ≥1 stream is unpaused. Hold a PARTIAL wake lock only while ≥1
  stream is unpaused.
- Panel policy, chosen from the display group the VD actually got (logged at
  creation): own group (AOSP) → only that group is woken and the panel power
  mode is never touched; panel group (vendor builds that ignore
  `OWN_DISPLAY_GROUP`) → the same wake also lights the panel, so the panel is
  powered off through SurfaceFlinger right after our own wakes (never in a
  loop), the screen showing nothing while the VD renders. A power-button press
  hands the phone back to normal Android behaviour until the screen has been on
  and off again. Never dismiss the keyguard, never unlock, never force the panel
  on.
- End of session: when we were the ones who woke the panel's group, restore the
  panel's power mode and `goToSleep` so the phone returns to its normal
  locked-off state with no wake locks or forced power modes left behind.
- Encoder: H.264 High, VBR, bitrate scaled to pixels (≈ 0.12 bpp·fps, capped
  8 Mbps), `KEY_FRAME_RATE 60`, `KEY_I_FRAME_INTERVAL` 10 s (IDR on demand),
  `KEY_PRIORITY 0` (realtime), `KEY_LATENCY 1` where supported,
  `KEY_MAX_B_FRAMES 0`.

## Latency budget (LAN, 60 Hz)

Click → visible change on Mac ≤ 80 ms p50. Both sides log timestamps behind a
debug flag so it can be measured: Mac logs input send time; phone logs inject
time and the pts of the next encoded frame.

## Repo layout

```
android/                 Gradle project, single :app module (dev.pocketdeck)
  app/src/main/java/dev/pocketdeck/
    app/                 MainActivity, PairingPrompt, NsdAdvertiser, ShizukuBinder
    server/              (runs in the shell process) DeckService (AIDL), Server,
                         Session, WindowStream, Encoder, InputInjector,
                         AppLauncher, Power, PanelPower (panel off through
                         SurfaceFlinger), DisplayProbe, Hidden (reflection cache),
                         ShellContext
    launcher/            LauncherActivity (phone mode)
    proto/               Frame codec (mirrors docs/PROTOCOL.md)
macos/                   SwiftPM package (macOS 26+) → PocketDeck.app (scripts/bundle.sh)
  Sources/PocketDeck/    App, Discovery, Session, Protocol, WindowManager,
                         AppWindow, VideoLayerView, InputMapper, Launcher UI, pair keys
tools/fakephone/         Python fake phone (protocol-complete, ffmpeg testsrc video)
docs/                    ARCHITECTURE, PROTOCOL, research/
```

## Device lessons carried over from the POC (don't re-learn these)

- VD creation needs `DisplayManager` constructed with a `ShellContext` whose
  package is `com.android.shell` (scrcpy FakeContext trick).
- Android 16 `IPowerManager.wakeUp` is the 4-arg `(long,int,String,String)`.
- Injected input needs `InputEvent.setDisplayId(vdId)` or it lands on display 0.
- Synthesised drags must carry real, increasing event times; instant bursts get
  discarded by apps.
- Shizuku user services are daemons: bump `versionCode` (used as service
  version) on every install or the old service keeps running.
- Test rig: Samsung SM-S936B, Android 16, adb via wireless-debugging TLS only;
  prefix adb with `timeout 20`.
