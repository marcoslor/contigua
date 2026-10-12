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

## v0.1 — after the core flow works (build in this order, small → large)

Ordered by priority (closest to the core POC first), then by size. Each item is one
looped dev task with its own checks; the next starts only after review.

| # | Feature | Approach | Size |
|---|---|---|---|
| 1 | Accurate lock state | hidden `IKeyguardLockedStateListener` → `state.locked` on change (no polling) | S |
| 2 | Nav shortcuts | ⌘[ / esc = back, ⌘H-style home, ⌘↑ recents in phone mode; two-finger swipe from the left edge = back (KEYCODE_BACK on the VD, never decorations) | S |
| 3 | Orphan cleanup watchdog | tiny second shell process with a lock file + heartbeat; if the server dies, release VDs, wake locks and power state | S‑M |
| 4 | Display-scoped keep-awake | hidden 3-arg `newWakeLock(…, displayId)` bound to the VD instead of a timer poke where available | S |
| 5 | Live quality knob | `window.quality` (bitrate/max fps) → `PARAMETER_KEY_VIDEO_BITRATE` at runtime; auto-lower on backlog | S |
| 6 | Clipboard text, both ways | shell `IClipboard` listener ⇄ NSPasteboard; locked-phone reads via the focused VD | S‑M |
| 7 | Spotlight for apps | index the app list into CoreSpotlight; open result = `window.open` | S |
| 8 | Links Mac → phone | `pocketdeck://open?url=` + macOS Services "Open on phone" → `am start VIEW` on a new window | S‑M |
| 9 | APK install | drop an .apk on the launcher → stream → `pm install-create/write/commit` | S‑M |
| 10 | Trackpad pinch/rotate | 2-pointer synthetic touch from NSEvent magnify/rotate | M |
| 11 | Phone → Mac app handoff | "Continue on Mac": move the phone's top task onto a new VD window | M |
| 12 | Clipboard images | stage PNG/JPEG files both ways, size-limited | M |
| 13 | Drag & drop files | drag-in: push to Downloads + share intent; drag-out: file promises | M |
| 14 | Audio phone → Mac | `AudioPlaybackCapture`/REMOTE_SUBMIX at shell UID → AAC/Opus on the session | M |
| 15 | Notifications + media controls | read at shell UID → UserNotifications; media sessions → Now Playing | M‑L |

## v0.x — later native features

| Feature | Approach | Size |
|---|---|---|
| TLS (mutual, pinned at pairing) | replaces HMAC-only auth | M |
| Links phone → Mac | open-on-Mac share target in the app | M |
| Automation server (MCP) | local stdio server over deckctl: list apps, open, observe, tap, type | M |
| Companion IME | composing/emoji/dictation | L |

## Later

Remote (non-LAN) relay, wake over network, widgets on the Mac, Finder FileProvider,
APK preview, calls, camera sharing, adb-only mode (no Shizuku: self-bootstrap
via wireless-debugging pairing).
