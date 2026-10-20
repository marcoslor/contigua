# Roadmap

Status: `[ ]` todo · `[~]` in progress · `[x]` done (verified on device).

## v0 — prove the POC (LAN, locked phone)

- [x] Phone server in the Shizuku shell process, one TCP session, PROTOCOL v1
- [x] One VD + encoder per Mac window, resizable, multiple at once
- [x] Phone mode — a mirror of the phone's own screen (display 0), at phone
      aspect, turning with the phone, with Back/Home/Recents
      (docs/design/phone-mirror.md)
- [x] Mac client: Bonjour discovery, pairing, launcher with search, AVSampleBufferDisplayLayer windows
- [x] Low-latency input path (binary frames, no sleeps, no hub)
- [x] Battery rules from ARCHITECTURE.md (pause on hidden windows, no idle work)
- [ ] `setIgnoreActivitySizeRestrictions(true)` on SDK ≥ 36 so fixed-size apps fill any window
- [ ] **Spike:** `VirtualDisplayConfig.Builder.setHomeSupported(true)` without
      `SHOULD_SHOW_SYSTEM_DECORATIONS`. If One UI's launcher runs on the VD and #6007
      stays clean across lock/unlock, use the system launcher in phone mode instead of ours.
- [ ] Device QA on the S25+ with the phone locked: latency ≤ 80 ms p50, #6007 clean, battery drain per hour measured idle vs. one window
- [~] Repo polish: README with GIF, LICENSE, build docs, CI (gradle build + swift build/test + fakephone selfcheck) — README and LICENSE (PolyForm Noncommercial 1.0.0) landed; GIF, CI and the fakephone selfcheck in CI are still open

## Before launch (P0)

- [~] **End-to-end encryption:** done on `epic/e2ee` — mutual TLS 1.3 with keys pinned at
      pairing (the code derives from the TLS exporter plus fresh nonces; the QR carries the
      Mac's fingerprint and a one-time secret), replacing plaintext + HMAC; protocol v2.
      It flips to `[x]` once the architect verifies it on the real phone (phase 2b step 10
      proved it on the emulator: code and exporter hash equal on both ends).
      Mac identity and pins are protected only by file permissions for now
      (`identity.json`, `pins.json`, 0600); Keychain storage returns with proper code
      signing before release.

## v0.1 — after the core flow works

All v0.1 items are done on main: accurate lock state, nav shortcuts, orphan cleanup watchdog,
display-scoped keep-awake, live quality knob, Spotlight for apps ("WhatsApp (Phone name)"),
trackpad pinch/rotate, links Mac → phone (#5), APK install (#10), share phone → Mac (#11),
Dock and Launchpad apps (#6), phone nickname + titles (#1, #2), clipboard text both ways (#3),
audio phone → Mac (#4, per-app capture), notifications + Now Playing (#7), drag & drop +
clipboard images (#8), phone mirroring, window styles (Framed / Immersive, remembered per app).

| # | Feature | Approach | Size |
|---|---|---|---|
| 1 | [x] Phone nickname | rename a phone in Settings → Devices (Mac-side, per device); used everywhere the phone is named; e2e `nickname` (shim name, window title, rename reorder) | S |
| 2 | [x] Titles name the phone | app windows and their Dock/⌘-Tab entries read "WhatsApp (Nickname)"; a rename retitles the open windows | S |
| 3 | [x] Clipboard text, both ways | shell `IClipboard` listener ⇄ NSPasteboard polling; `clip.set`, no echo, skips concealed items | S‑M |
| 4 | [x] Audio phone → Mac | REMOTE_SUBMIX at shell UID → Opus/AAC on the session → AVAudioEngine on the Mac, <150 ms added latency, per-device volume/mute (docs/design/audio.md); verified end to end on the API 36 emulator (~80–125 ms tone → Mac, speaker idle), API 34/35 and the real phone still to check | M |
| 5 | [x] Links Mac → phone | Share → "Open on Phone" (Share extension), Services, drop on the Deck → `link.open` → `ACTION_VIEW` in a new window (docs/design/links.md) | S‑M |
| 6 | [x] Dock and Launchpad apps | Deck → right-click an app → Add to Dock: a per-app shim bundle in ~/Applications/PocketDeck Apps (real icon, "App (Phone)" in Dock, Launchpad, ⌘-Tab); launching opens/focuses the window, quitting closes it (docs/design/dock.md) | M |
| 7 | [x] Notifications + Now Playing | notifications and media sessions read by a listener in the app process (granted at the per-phone opt-in via `cmd notification allow_listener` from the shell), forwarded over AIDL → macOS UserNotifications (click opens the app window) and MPNowPlayingInfoCenter + MPRemoteCommandCenter; off by default on both sides (docs/design/notify.md); e2e `notify` | M‑L |
| 8 | [x] Drag & drop files, clipboard images | Mac → `drop.start` (chunked ≤ 1 MiB parts, resumable, 200 MiB cap) → phone writes to `Downloads/PocketDeck/`, media-scans and offers the app's SEND chooser through shell staging; clipboard images travel both ways (docs/design/dragdrop.md); e2e `drop` | M |
| 9 | [x] Phone → Mac app handoff | "Continue on Mac" (menu bar, app menu, ⌘⇧C): move the phone's foreground task onto a new VD window — `task.continue` → `IActivityTaskManager.moveRootTaskToDisplay` at shell UID, verified on the API 36 emulator (docs/design/handoff.md) | M |
| 10 | [x] APK install | drop / Open With / Services / menu bar an .apk, .apks or .xapk → `apk.install` + `APK_DATA` → `pm install-create/write/commit` at shell UID (docs/design/apk.md) | S‑M |
| 11 | [x] Share phone → Mac | Android Share → "Send to Mac": links open in the Mac browser, text → clipboard, images → ~/Downloads/PocketDeck + clipboard; "Open on Mac" in the text menu and Open with (`share.text`, `share.file` + `SHARE_DATA`; docs/design/sharein.md) | S‑M |

## QoL batch (2026-10-18), smallest first

Order of work: this batch, then quick features, then an architecture / maintainability / security review before more features.

Batch A (XS-S, one agent, one commit each)
- [x] A1 Android: space between the collapsed top bar and the first card (the "Connected" card touches the bar).
- [x] A2 Mac: notification titles end with the phone's name, e.g. "Ana (Pixel 9)".
- [x] A3 Mac: Show Touches defaults to on when a trackpad is present; an explicit user choice always wins.
- [x] A4 Mac: turning off "Show phone apps in the Dock" removes the Dock icon of running non-pinned apps too.

Batch B (S)
- [x] B1 Mac: glass title bar uses progressive blur only, no dimming, in framed and immersive, light and dark apps.
- [ ] B2 Mac: immersive mode's reveal delay is a setting (default unchanged) (done); fix the unbalanced immersive controls (needs a screenshot of the issue).
- [x] B3 Android: "Allow connections" (master: refuses every Mac, paired or not, and drops live sessions) + "Allow new pairings" (greyed out while the master is off).

Batch C (M, one at a time)
- [x] C1 Mac: View > Density submenu. "Default" (the Settings value, checked when the app has no override) plus the values; picking a value sets a per-app override for the focused window's app, "Default" clears it. Settings lists overrides with a reset.
- [x] C2 Mac: native fullscreen shows the app title and the traffic lights in the revealed title bar, framed and immersive.
- [x] C3 Mac: live resize. Until the phone sends a frame at the new size, the last frame fills the window aspect-fill (centred crop) instead of letterboxing; the reflection samples only the video, never the black gap.

Batch D (M-L)
- [x] D1 Hover pass-through: Mac pointer moves reach the phone as mouse hover (ACTION_HOVER_*), e.g. Chrome's new-tab Lens button reacts as with a real mouse. Brief: .agent/hover/brief.md.
- [x] D2 Clicking a Mac notification runs its action in a PocketDeck window. Setting: Open on Mac (default) / Open on phone / Do nothing.

## v0.2 — deeper integrations (planned 2026-10-19, in this order)

| # | Feature | Approach | Size |
|---|---|---|---|
| 1 | Finder: browse and open phone files (read-only) built; writes next | File Provider extension (replicated): the phone's shared storage as a Finder location, listed and fetched on demand over the session at shell UID; thumbnails and Quick Look; cached files stay readable offline, edits upload when the phone is back | L |
| 2 | ✅ Shortcuts, Siri and Spotlight actions (built; needs a hands-on check in Shortcuts and on the phone) | App Intents: open a phone app, ring the phone, send a link or file to the phone, phone battery; macOS 26 Spotlight runs them directly | M |
| 3 | ✅ Live Text and images in phone windows (built; needs a hands-on check) | VisionKit on a frozen frame of the window: select and copy text, lift an image subject or drag the whole frame out, Visual Look Up, translate. Its own mode (View ▸ Live Text, ⌘⇧T), because a click-and-hold already selects text in the Android app. Design: docs/design/livetext.md | S‑M |
| 4 | Control Center and menu bar controls (in progress: the phone ringer, the app's snapshot and socket and the opt-in extension are built, but in the VM the controls never appeared in Control Center's gallery, so they don't work yet; hotspot left out, the shell UID cannot toggle it without replacing the person's config) | ControlWidget toggles: phone Do Not Disturb, ringer mode, ring the phone, open PocketDeck; the extension reads a snapshot and sends actions over a group socket | S‑M |
| 5 | ✅ Focus sync (built; needs a hands-on check) | a Mac Focus turns on the phone's Do Not Disturb and back (Focus filter + the phone's zen mode at shell UID) | S‑M |
| 6 | ✅ Automation server (MCP) (built; needs a hands-on check) | local stdio MCP server on the Mac over the existing session: list apps, open, screenshot a window, tap/type/swipe (UI tree later) | M |
| 7 | Camera sharing | phone camera as a Mac camera: CoreMediaIO camera extension fed by a Camera2 stream from the phone. Spike first: can the shell process open the camera with the phone locked, or does it need the app with a foreground service | L |
| 8 | Deeper notifications | notification actions (inline reply, buttons), dismiss synced both ways, per-app filters, images; a sign-in code from an SMS becomes "Code copied" on the Mac; Android 16 Live Updates / Samsung Now Bar shown live on the Mac | M‑L |
| 9 | Deeper media control | artwork, position and seeking, choosing among several playing apps, Mac media keys and volume, where the audio plays (phone or Mac) | M |
| 10 | Deeper calls | incoming call on the Mac with Answer / Decline / message, call log; call audio on the Mac's mic and speakers. Spike first: Telecom control and call-audio capture at shell UID | L |
| 11 | Widgets | WidgetKit widgets (battery, now playing, latest notifications, app shortcuts). Built from a snapshot the Mac app keeps; timelines computed on the Mac so a refresh never wakes the phone; the phone pushes changes only; a disconnected phone shows the last state with its age, never an error | M |
| 12 | WAN access | see "Remote access" below | L |
| 13 | Remote wake | wake a dozing phone server from the Mac: the rendezvous connection doubles as the wake channel off the LAN; on the LAN, find the cheapest keepalive that survives doze | M |

## After the v0.2 features: maintainability

- [ ] Source file size gate: fail a source file over 10k tokens (≈ 40 KB), warn over 5k. Source only
      (Kotlin, Swift, Python, shell); docs, generated files, lockfiles and baselines are exempt.
      Today's offenders get a shrinking allowlist, then splits (Session.kt, ConnectionController.swift,
      Session.swift, WindowStream.kt, check-e2e.sh → e2e-lib.sh + check files).
- [ ] Warnings as errors on both sides; a separate Swift core target (protocol, session, TLS, geometry).
- [ ] CI (gradle build, swift build/test, fakephone selfcheck, the size gate).

## Remote access (paid hosted option, always self-hostable)

1. Rendezvous service: the phone's shell server keeps one outbound connection (keepalive
   ≥ 4 min); the Mac asks it to connect to a paired phone id. Sees only ids and addresses.
2. Relay fallback (TCP/WebSocket) that forwards opaque E2E-encrypted bytes; works on every
   network. Remote mode caps video at ~2 Mbps / 30 fps.
3. P2P upgrade: UDP hole punching (QUIC) with the rendezvous as the address exchange; relay only
   when NAT forbids it (symmetric/CGNAT, typically mobile data).
Single static server binary + Docker image; one process does rendezvous + relay.

## Later

APK preview, Companion IME (composing/emoji/dictation), the phone's battery in the Mac's own
Bluetooth menu and Batteries widget (spike: the phone as a Bluetooth HID device reporting the
Battery Service; unverified), adb-only mode (no Shizuku: self-bootstrap
via wireless-debugging pairing).
