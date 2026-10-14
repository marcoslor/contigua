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
- [ ] **End-to-end encryption (P0):** mutual TLS 1.3 with keys pinned at pairing (QR/code exchanges
      certificate fingerprints); the same encrypted stream runs over LAN, P2P and relay, so no
      relay can read it. Replaces plaintext + HMAC; protocol v2.
      Mac pairing keys are protected only by file permissions for now (`pairkeys.json`, 0600);
      Keychain storage returns with proper code signing before release.
- [ ] Device QA on the S25+ with the phone locked: latency ≤ 80 ms p50, #6007 clean, battery drain per hour measured idle vs. one window
- [ ] Repo polish: README with GIF, LICENSE, build docs, CI (gradle build + swift build/test + fakephone selfcheck)

## v0.1 — after the core flow works

Done: accurate lock state, nav shortcuts, orphan cleanup watchdog, display-scoped keep-awake,
live quality knob, Spotlight for apps ("WhatsApp (Phone name)"), trackpad pinch/rotate,
links Mac → phone (#5).

Remaining, in build order (very simple items first, then the ones that make Android apps feel
like Mac apps). Each item is one looped dev task with its own checks.

| # | Feature | Approach | Size |
|---|---|---|---|
| 1 | Phone nickname | rename a phone in Settings → Devices (Mac-side, per device); used everywhere the phone is named | S |
| 2 | Titles name the phone | app windows and their Dock/⌘-Tab entries read "WhatsApp (Nickname)" | S |
| 3 | Clipboard text, both ways | shell `IClipboard` listener ⇄ NSPasteboard polling; `clip.set`, no echo, skips concealed items | S‑M |
| 4 | Audio phone → Mac | `AudioPlaybackCapture`/REMOTE_SUBMIX at shell UID → Opus/AAC on the session | M |
| 5 | [x] Links Mac → phone | `pocketdeck://open?url=`, Services "Open on Phone", drop on the Deck → `link.open` → `ACTION_VIEW` in a new window (docs/design/links.md); Share-menu extension later | S‑M |
| 6 | Dock and Launchpad apps | per-app shim bundles: Dock icon, Launchpad, ⌘-Tab; launching opens that app's window | M |
| 7 | Notifications + media controls | read at shell UID → UserNotifications (click opens the app window); media sessions → Now Playing | M‑L |
| 8 | Drag & drop files, clipboard images | drag-in: push + share intent; drag-out: file promises; images staged both ways, size-limited | M |
| 9 | Phone → Mac app handoff | "Continue on Mac": move the phone's top task onto a new VD window | M |
| 10 | APK install | drop an .apk on the Deck → stream → `pm install-create/write/commit` | S‑M |

## v0.x — later native features

| Feature | Approach | Size |
|---|---|---|
| Links phone → Mac | open-on-Mac share target in the app | M |
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
