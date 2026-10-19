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
- [~] Repo polish: README with GIF, LICENSE, build docs, CI (gradle build + swift build/test + fakephone selfcheck) — README landed on epic/docs; GIF, LICENSE, CI and the fakephone selfcheck in CI are still open

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
- [ ] B3 Android: "Allow connections" (master: refuses every Mac, paired or not, and drops live sessions) + "Allow new pairings" (greyed out while the master is off).

Batch C (M, one at a time)
- [ ] C1 Mac: View > Density submenu. "Default" (the Settings value, checked when the app has no override) plus the values; picking a value sets a per-app override for the focused window's app, "Default" clears it. Settings lists overrides with a reset.
- [ ] C2 Mac: native fullscreen shows the app title and the traffic lights in the revealed title bar, framed and immersive.
- [ ] C3 Mac: live resize. Until the phone sends a frame at the new size, the last frame fills the window aspect-fill (centred crop) instead of letterboxing; the reflection samples only the video, never the black gap.

Batch D (M-L)
- [ ] D1 Hover pass-through: Mac pointer moves reach the phone as mouse hover (ACTION_HOVER_*), e.g. Chrome's new-tab Lens button reacts as with a real mouse. Brief: .agent/hover/brief.md.
- [ ] D2 Clicking a Mac notification runs its action in a PocketDeck window. Setting: Open on Mac (default) / Open on phone / Do nothing.

## v0.x — later native features

| Feature | Approach | Size |
|---|---|---|
| Automation server (MCP) | local stdio server over deckctl: list apps, open, observe, tap, type | M |
| Companion IME | composing/emoji/dictation | L |

## Remote access (paid hosted option, always self-hostable)

1. Rendezvous service: the phone's shell server keeps one outbound connection (keepalive
   ≥ 4 min); the Mac asks it to connect to a paired phone id. Sees only ids and addresses.
2. Relay fallback (TCP/WebSocket) that forwards opaque E2E-encrypted bytes; works on every
   network. Remote mode caps video at ~2 Mbps / 30 fps.
3. P2P upgrade: UDP hole punching (QUIC) with the rendezvous as the address exchange; relay only
   when NAT forbids it (symmetric/CGNAT, typically mobile data).
Single static server binary + Docker image; one process does rendezvous + relay.

## Later

Wake over network, widgets on the Mac, Finder FileProvider,
APK preview, calls, camera sharing, adb-only mode (no Shizuku: self-bootstrap
via wireless-debugging pairing).
