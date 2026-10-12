# Roadmap

Status: `[ ]` todo · `[~]` in progress · `[x]` done (verified on device).

## v0 — prove the POC (LAN, locked phone)

- [~] Phone server in the Shizuku shell process, one TCP session, PROTOCOL v1
- [~] One VD + encoder per Mac window, resizable, multiple at once
- [~] Phone mode (phone-aspect VD + PocketDeck launcher)
- [~] Mac client: Bonjour discovery, pairing, launcher with search, AVSampleBufferDisplayLayer windows
- [~] Low-latency input path (binary frames, no sleeps, no hub)
- [~] Battery rules from ARCHITECTURE.md (pause on hidden windows, no idle work)
- [ ] `setIgnoreActivitySizeRestrictions(true)` on SDK ≥ 36 so fixed-size apps fill any window
- [ ] **Spike:** `VirtualDisplayConfig.Builder.setHomeSupported(true)` without
      `SHOULD_SHOW_SYSTEM_DECORATIONS`. If One UI's launcher runs on the VD and #6007
      stays clean across lock/unlock, use the system launcher in phone mode instead of ours.
- [ ] Device QA on the S25+ with the phone locked: latency ≤ 80 ms p50, #6007 clean, battery drain per hour measured idle vs. one window
- [ ] Repo polish: README with GIF, LICENSE, build docs, CI (gradle build + swift build/test + fakephone selfcheck)

## v0.x — make it feel native

| Feature | Approach | Size |
|---|---|---|
| Clipboard text + images | shell `IClipboard` listener ⇄ NSPasteboard | S |
| Trackpad pinch/rotate | 2-pointer synthetic touch from NSEvent magnify/rotate | M |
| Audio | `REMOTE_SUBMIX`/playback capture from shell → Opus/AAC over the session | M |
| Notifications + media controls | NotificationListener in app process → Mac UserNotifications / NowPlaying | M |
| App handoff phone→Mac | move the phone's top task onto a new VD window | M |
| Link handoff both ways | macOS Services/URL scheme ⇄ `am start` VIEW | M |
| Spotlight | index the app list into CoreSpotlight | S |
| Drag & drop files | push to /sdcard + share intent; drag-out as file promises | M |
| TLS (mutual, pinned at pairing) | replaces HMAC-only auth | M |
| Companion IME | composing/emoji/dictation | L |

## Later

Remote (non-LAN) relay, wake over network, widgets on the Mac, Finder FileProvider,
APK install/preview, calls, camera sharing, adb-only mode (no Shizuku: self-bootstrap
via wireless-debugging pairing).
