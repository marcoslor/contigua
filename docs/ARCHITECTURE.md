# Contigua — architecture

Mac-style continuity for Android: run Android apps in native, resizable Mac
windows (one window per app, several at once) and a "phone" window — **while the
phone stays locked**. LAN only. Open source.

```
 macOS app (Swift)                             Android phone
┌──────────────────────────────┐ 1-3 paths (TLS)┌────────────────────────────────────┐
│ ConnectionController ────────┼───────────────►│ App process (app.contigua)       │
│ Session (paths) + Protocol   │  (PROTOCOL.md) │  MainActivity, PairingPrompt,      │
│ Path providers: lan, direct  │◄───────────────┤  NsdAdvertiser, ShizukuClient,     │
│ Deck (app grid, search)      │                │  PdNotificationListener, prefs     │
│ AppWindow/StreamWindow +     │                │        │ AIDL (control only)       │
│  WindowStyle chrome          │                │ Shell service (UID 2000, Shizuku)  │
│  VideoLayerView              │                │  DeckService (IDeckService.aidl)   │
│ InputMapper + gestures       │                │  Server → Session (paths) →        │
│ AudioEngine (Opus/AAC)       │                │   WindowStream × N:                │
│ NotifyCenter / NowPlaying    │                │    VirtualDisplay + MediaCodec     │
│ ClipboardSync, FileDrop,     │                │   WindowStream.startMirror         │
│  OpenLink, ApkInstall,       │                │   AudioCapture (+ AudioFollow)     │
│  DockApps, Handoff,          │                │   AndroidInjector, AndroidLauncher │
│  Spotlight, Share extension  │                │   Power/PanelPower, ShellLanding,  │
│                              │                │   ApkInstaller, ShellClipboard     │
└──────────────────────────────┘                └────────────────────────────────────┘
```

## The phone side: the app process and the shell server

**Two processes, one job each.** Without root privileges, Shizuku runs our server
code as UID 2000 (`com.android.shell`), the same uid as `adb shell`; with root
privileges it runs as UID 0, which owns no package, so clipboard reads go through
a helper started as UID 2000 (docs/design/sharein.md, SHARE-19). The app process
(`app.contigua`) does everything a normal Android app can: UI, pairing prompt,
the foreground service, the notification listener, NSD advertising, battery/lock
relays. It cannot create virtual displays or read notifications at will — that is
why the capability lives in the shell process.

The app binds the user service over Shizuku and talks to it over AIDL:

- `IDeckService.aidl` (app → shell): growable transaction codes — `stopServer`,
  `setPairedClients`, `respondPairing`, `setBatteryState`, `setLockedState`,
  `shareFile`, `setNotifyShared`, `pushDeviceEvent`, `openStaged` (an fd for a staged
  drop), `clipImageDone` (the app's answer to a clipboard image) (bumped per transaction;
  see "Device lessons").
- `IDeckCallback.aidl` (shell → app): `onPairingRequest`, `onPaired`,
  `onSessionChanged`, `onNotifySession`, `onMediaCommand`, `onClipImage` (a clipboard
  image's bytes for the app to set).

The app pushes identity and per-feature gates in (`setPairedClients`, the
notify opt-in), the shell calls back for pairing decisions and media actions.
The TCP session itself lives in the shell process end to end. Once ready, a
handler that throws ends only that message (an `error`/`internal` reply); it
never closes the session.

## Streaming: one virtual display per window

Each app window is a `WindowStream`: one virtual display (VD), one H.264
encoder whose input surface backs the VD, one stream id. `window.open` carries
`w/h/dpi/pkg`; `window.resize` resizes the VD (`resize` + encoder
reconfiguration); `window.close` tears it down. The Mac resizes freely and the
app re-lays out at the new shape and DPI.

Every VD must sit in a display group of its own, or it sleeps and wakes with
the phone's screen (docs/specs/app-windows.md WIN-74). On Android 14+ the VDs
are made by one platform virtual device (`VirtualDeviceManager`, from
Contigua's own `com.android.shell` companion association, WIN-75), with
`PUBLIC | PRESENTATION | OWN_CONTENT_ONLY | SUPPORTS_TOUCH |
ROTATES_WITH_CONTENT | DESTROY_CONTENT_ON_REMOVAL | TRUSTED |
DEVICE_DISPLAY_GROUP | ALWAYS_UNLOCKED | TOUCH_FEEDBACK_DISABLED | OWN_FOCUS |
STEAL_TOP_FOCUS_DISABLED`; One UI ignores `OWN_DISPLAY_GROUP` on a plain VD
but gives a device's display its own group. Where no device can be made (AOSP,
the emulator) a plain VD with `OWN_DISPLAY_GROUP` instead of the device group
is used. A VD that still reads group 0 is refused before anything launches on
it (`error {code: "windows_unsupported"}`).

- **Never `SHOULD_SHOW_SYSTEM_DECORATIONS`** — it poisons SysUiState on One UI
  and breaks the phone's back gesture until reboot. Back is `KEYCODE_BACK`
  stamped with the VD's display id.
- `ALWAYS_UNLOCKED` is what makes "apps run while the panel is locked"
  possible; the keyguard itself is never touched.
- The VD's creation source is a `ShellContext` package `com.android.shell`
  (a Shizuku-only trick); injected input must carry the display id explicitly.
- Encoder: H.264 at the platform's default profile (we never set `KEY_PROFILE`
  or `KEY_LEVEL`), VBR scaled to pixels (≈ 0.12 bpp·fps, capped 8 Mbps),
  60 fps, IDR on demand, realtime priority, low-latency keys where supported.
  VDs bigger than 2560 px are scaled at capture instead of letterboxing.

**Phone mode** is not a launcher config — it is a mirror of display 0. The
shell creates a virtual display that mirrors the phone's own screen (hidden
`DisplayManager.createVirtualDisplay` with the mirrored display id, CAPTURE
from shell uid), at phone aspect, turning with the phone; input goes to
display 0. It never unlocks or dismisses the keyguard; an explicit
`phone.wake` may light the panel (window open, Wake Screen), and nothing keeps
it awake beyond the phone's own timeout. Its own glass header carries
Back/Home/Recents (docs/design/phone-mirror.md).

## Audio: two capture modes

The shell process captures the phone's playback and streams it → Mac
Opus/AAC (20 ms frames) → `AVAudioEngine`. Which source is picked is a plan:

- **Per-app**: an `AudioPolicy` loop-back mix uid-filtered to the focused
  window's app (`AudioFollow.plan`, attributed as `com.android.shell`);
- **All-audio**: the `REMOTE_SUBMIX` record (the plain submix technique), used
  when no window can be attributed (phone window, link pending, uid lookup
  failure) — one path is registered at a time, switching by unregister +
  register while streams open/close/focus.

Capture keeps the app's samples 1:1; media playback is routed away from the
phone's own speaker while we stream. Per-device volume/mute lives in the Mac
menu bar. Measurements (~80–125 ms tone → Mac on the API 36 emulator, speaker
idle; added latency < 150 ms) and the swap rules: docs/design/audio.md.

## Notifications and Now Playing

Both read features ride one per-phone opt-in, default OFF on the phone and on
the Mac. The grant is done **by the shell service** (`cmd notification
allow_listener …PdNotificationListener` at UID 2000) when the phone toggle is
turned on — so no settings screen and no root touch is needed.

- `PdNotificationListener` runs **in the app process** (a real
  notification-listener service), caps strings at 8 KiB, skips our own and
  contentless notifications, and pushes JSON events to the shell over AIDL
  (`pushDeviceEvent`) while the gate is on; the shell validates and forwards.
- Media sessions are read in the app process with
  `MediaSessionManager.getActiveSessions(listener)` — position drift tracked
  via rate, callbacks throttled ≤ 1/s. `onMediaCommand` carries play/pause/next/
  previous back. The shell-UID route is kept as a documented fallback.
- On the Mac, notifications post via UserNotifications (grouped per phone,
  click opens that app's window) and media state is published to
  MPNowPlayingInfoCenter + MPRemoteCommandCenter, cleared when nothing plays.

## Drag and drop, share in, APK install, shell staging

Everything that turns a Mac file into a phone notification or reverse goes
through a small shell-staging pipeline (so the shell, not the app, holds the
system-privileged steps):

- **Drop in**: Mac → `drop.start` → binary `DROP_DATA` chunks (≤ 1 MiB, paced,
  resumable via `resume:bytes`, 200 MiB cap, one active drop per phone) → the
  phone lands the file in `Downloads/Contigua/`, media-scans it and offers a
  SEND chooser through `DropReceiver` + shell staging (`ShellLanding`,
  `ShareTrampoline`). The shell stages the file and opens it read-only through
  `openStaged` (the app cannot open a shell-written path, boot 5); the app
  copies from that fd into its own cache and its own-uid SEND step picks the
  receiving app.
- **APK install** reuses the same transport shape: `apk.install` + `APK_DATA`
  → `pm install-create/write/commit` at shell uid; `.apks`/`.xapk` bundles are
  parsed Mac-side first (docs/design/apk.md).
- **Share phone → Mac**: `shareFile` (AIDL) hands bytes from the phone's SHARE
  to the shell; `share.text`/`share.file` drive the Mac (browser / clipboard /
  `~/Downloads/Contigua` + a Show-in-Finder notification).
- Clipboard text is read/written at shell uid (`ShellClipboard`), so it works
  while the phone is locked; images are read there too. A Mac image goes to the
  app process over `onClipImage` because ClipboardService refuses the shell's
  own URI clip (boot 5); the app sets it and answers `clipImageDone`.

## The Mac side

- **Connection**: `Discovery` (NWBrowser over `_contigua._tcp`) or manual
  address; `ConnectionController` owns pairing state and the session. Every
  session is **TLS 1.3, mutual, pinned** (NIOSSL/BoringSSL on this side): the
  per-profile identity is `…/Contigua-<profile>/identity.json` (0600) and
  each paired phone's fingerprint and certificate live in `pins.json` (0600).
  Pairing: QR (the sheet publishes
  `contigua://pair?c=…&n=…&f=…&s=…`, secret one-time) or numeric comparison
  (six digits on both screens, derived from the TLS exporter and fresh nonces;
  the phone's **Allow** is the confirmation — the code is never typed). A
  non-default profile never dials a phone found over Bonjour on its own
  (`DialPolicy`). Profiles isolate all of this (`--profile <name>`, never the
  default).
- **Windows**: `AppWindow`/`StreamWindow` + `StreamChrome`. The style system
  (`WindowStyle`, remembered per app in the profile defaults) has three shapes:
  **Framed** (the default: a real 38/5 pt frame round the picture with the
  system material, hairline, rim and rounded corners), **Compact** (a
  permanent 28 pt bar with the traffic lights and the picture mirrored under a
  blur) and **Immersive** (the stream alone; a dwell pill at the top-left
  brings the lights back). Full screen in Framed or Compact fills the screen
  with the stream and reveals one acrylic bar from the top edge; Immersive
  full screen uses the system's title bar. Style flips (⌥⌘F / View menu)
  resize the window around the same stream and never re-open the window.
- **Video**: H.264 Annex-B → `CMSampleBuffer` →
  `AVSampleBufferDisplayLayer` with `DisplayImmediately`. No CPU readback, no
  `CGImage`, no `draw(_:)` — this is what keeps the pointer honest.
- **Input**: binary frames sent immediately per NSEvent (moves coalesced to
  one per display refresh, no sleeps); the phone injects synchronously on its
  socket reader thread with cached reflection handles. Hover: the video's
  tracking area sends ENTER/MOVE/EXIT (moves at most one per 16 ms, the newest
  point) and the phone injects `ACTION_HOVER_*` as a mouse; a button down sends
  EXIT before the touch, and Mac UI over the video (the Compact bar, the
  Framed frame, the full-screen bar) or a window losing key ends it. Trackpad: two-finger
  scroll is a touch drag (Android gets flings; a mouse wheel is a SCROLL
  frame), pinch/rotate are two pointers from the raw fingers; a mouse side
  Back button maps to one Android Back per press.
- **Outbound features**: `ClipboardSync` (NSPasteboard ⇄ shell clipboard),
  `FileDrop` sender (chunked/resumable drops + pill UI), `OpenLink`
  (`contigua://open` + the bundled Share extension "Open on Phone"),
  `ApkInstall`/`ApkBundle`, `AudioEngine` (menu bar volume/mute),
  `NotifyCenter`/`NowPlaying`, `DockApps` (shim bundles in
  `~/Applications/Contigua Apps/` with the real icon), `Spotlight`,
  `HandoffWindow` (⌘⇧C / menu continuing the phone's foreground task).
- **Deck**: the launcher window — app grid, search, battery/lock chips,
  drops as AP target, per-app context menu (Add to Dock, style).

References per feature: docs/design/*.md (also mac-audit.md). The wire is
defined once in docs/PROTOCOL.md (framing, message tables, pairing rules).

## Repo layout

```
android/                 Gradle project, single :app module (app.contigua)
  app/src/main/java/app/contigua/
    app/                 MainActivity, PairingPrompt, NsdAdvertiser,
                         ShizukuClient, PdNotificationListener, prefs, share
    server/              (runs in the shell process) DeckService (AIDL),
                         Server, Session, WindowStream (VD + MediaCodec
                         encoder), AudioCapture + AudioFollow, AndroidInjector,
                         AndroidLauncher, Power/PanelPower, DisplayProbe,
                         ShellLanding (+ DropReceiver, ShareTrampoline),
                         ApkInstaller, ShellClipboard, Hidden, ResizePlan
    proto/               Frame codec (mirrors docs/PROTOCOL.md)
  app/src/test/          Robolectric/device-state unit tests + screenshot tests
macos/                   SwiftPM package (macOS 26+) → Contigua.app
  Sources/Contigua/    App/Profile, Discovery/DirectConnect, Session +
                         Protocol, WindowManager + AppWindow/StreamWindow +
                         StreamChrome/WindowStyle, VideoLayerView, InputMapper
                         + gestures, DeckViews, AudioEngine, NotifyCenter,
                         NowPlaying, ClipboardSync, FileDrop, OpenLink,
                         ApkInstall, DockApps, Spotlight, HandoffWindow,
                         QRPairing/PairingSheets, pair keys (Identity)
  Scripts/               bundle.sh, check-e2e.sh (fakephone-driven checks),
                         install.sh, cgevent-input.swift (input driver)
tools/fakephone/         Python fake phone (protocol-complete) + deckctl
tools/emulator/          boots the real server on a local emulator (uid 2000)
docs/                    ARCHITECTURE, PROTOCOL, ROADMAP, TRY-IT, UX, design/
```

## Device lessons (keep, they are load-bearing)

- VD creation needs `DisplayManager` built on a `ShellContext` whose package is
  `com.android.shell`; audio capture and policy registration must be
  attributed the same way or AudioFlinger rejects them.
- Injected input needs `InputEvent.setDisplayId(vdId)` or it lands on display 0.
- Synthesised drags must carry real, increasing event times; instant bursts get
  discarded by apps. Injected keys must leave Shift in
  `charactersIgnoringModifiers` or text arrives doubled.
- Shizuku user services are daemons: bump `versionCode` (used as service
  version) on every install or the old service keeps running. AIDL transaction
  codes must grow monotonically — a rebuild with an existing shell service
  breaks otherwise.
- Some OEM builds (One UI) ignore `OWN_DISPLAY_GROUP` on a plain VD and put
  it in the panel's group; the virtual device's display group is what avoids
  that (android/README.md). A phone where even that lands in group 0 cannot
  open app windows.

## Session end / battery (acceptance criteria, not suggestions)

- No session → no VD, no encoder, no wake lock, no polling; idle cost is one
  listening socket + NSD registration.
- **Two exceptions, and only in a direct build** (the phone's switch on with a
  key for a paired Mac):
  1. an **idle publish** with no session, so a direct path can *start* a session
     after the LAN is gone;
  2. a **standby NDP** while a session is live, so a switch is instant.
  Both end with the phone's switch (or the Mac's); the standby also ends with
  the session. Neither exists in the public build, and the settings name the
  battery cost in one sentence (docs/design/direct-link.md §4.3, `DIRECT-1`,
  `DIRECT-7`, `DIRECT-16`).
- A session outlives its connection: from protocol 4 one session has one to
  three **paths** (each one TLS connection), and a path that dies is replaced
  without a new session — up to the 30 s grace, then the session ends as above
  (docs/design/paths.md).
- Windows hidden/occluded → `window.pause` (encoder stopped, VD surface
  detached). Static content emits no frames. App-level ping every 15 s.
- Keep-awake pokes only the VDs' own display group (on stream open,
  throttled input, a timer while a window is live), with a display-scoped wake
  lock per VD and a PARTIAL wake lock while ≥ 1 window is live; display 0 is
  never woken, held or slept for an app window, so the phone's own screen
  times out and a power press works as usual, and the keyguard is never
  dismissed. The group wake runs right after the VD exists and *before* the
  activity launch: a VD created while its group sleeps starts OFF, and Android
  does not launch onto it until it is awake.
- A device VD keeps the platform's global wakefulness awake while group 0
  dozes, so "is the phone's screen on" is read from display 0 itself.
- End of session restores every power state we touched.

## End-to-end encryption (v2, shipped in this branch)

The wire is **TLS 1.3 only, with both ends pinned**: no plaintext phase, no v1
fallback, no session resumption or 0-RTT, and a certificate that is not the
pinned peer's is refused (`bad_pin`). The phone terminates each session on a
platform `SSLSocket` (Conscrypt); the Mac dials with NIOSSL/BoringSSL from an
in-memory identity. Pairing pins the peer: the code path commits to a fresh
phone nonce before the Mac releases its own and derives the six digits from the
TLS exporter plus both nonces (docs/PROTOCOL.md "Pairing", design §4/§4b), and
the QR path carries the Mac's fingerprint plus a one-time secret the phone
proves with `pair.qr`. Key material never leaves the devices and never enters
a log (hashes only). A relay (a later, optional milestone) therefore sees
ciphertext only (docs/ROADMAP.md "Before launch").
