# PocketDeck

PocketDeck runs Android apps in **native Mac windows** over your home network —
one window per Android app, several at once, plus a phone-sized window that
mirrors the phone's screen — **while the phone stays locked in your pocket**.
No cables, no cloud: the phone runs a tiny server inside
[Shizuku](https://shizuku.rikka.app/)'s shell process and streams video over a
single TCP session to the Mac, which drives the apps with real touch, keyboard
and audio in the other direction.

Screen recording is per-app virtual displays on the Android side and
`AVSampleBufferDisplayLayer` on the Mac side, so these are real windows you can
resize into any shape, not screen-capture videos — the app re-lays out to the
window you give it.

| Two apps in Mac windows (Clock in Immersive style, Settings in Framed style — both are the actual Android app) | The Deck: the phone's app grid on the Mac |
|---|---|
| ![Two Android apps as Mac windows](docs/images/two_app_windows.png) | ![The app grid](docs/images/deck_dark.png) |

| The phone window mirrors the phone's own screen (Back / Home / Recents at the right of the bar) | Pairing, step by step on the phone |
|---|---|
| ![Phone mode](docs/images/phone_mode.png) | ![Pairing onboarding](docs/images/onboarding_4_pair_light.png) |

## Features

**Windows and input**

- **One window per app** — pick any app in the Deck (⌘K to search) and it opens
  in its own resizable Mac window; resize into any shape and the app re-lays
  out. Several app windows at once.
- **Phone window** — a mirror of the phone's own screen (status bar, lock
  screen, home, apps), turning with the phone, with Back/Home/Recents buttons.
- **Real input** — typed keys, clicks, drags and scroll; right-click is Android
  Back, middle-click is Home, and a mouse's side **Back** button sends Back. On
  a trackpad, two-finger scroll drags the page like a finger (with fling) and
  pinch/rotate are two fingers around the pointer.
- **Window styles** — a Framed bar (always visible, holds the traffic lights)
  or Immersive (the window *is* the app; a dwell pill brings the lights back).
  Switch with View ▸ Window Style or ⌥⌘F; the choice is remembered per app.
- **Continue on Mac (handoff)** — move the task in the phone's foreground onto
  the Mac (menu bar, app menu, or ⌘⇧C): same app, a new window.
- **Live Text** — View ▸ Live Text (⌘⇧T) freezes a window on its current frame:
  select and copy text, use data detectors (links, numbers, dates), lift an
  image subject, Visual Look Up, translate where macOS offers it. ⌘C without a
  selection copies the whole frame, and the bar's `text.viewfinder` button drags
  it out as a PNG. Input stays paused while the mode is on; Esc (or the shortcut
  again) brings live video back.

**Phone mode, audio**

- **Audio from the phone to the Mac** — with a window open, the phone's media
  and game audio plays on the Mac with a volume slider and mute in the menu
  bar; media stays silent on the phone's speaker. Capture follows the focused
  window's app where Android allows it and falls back to all-device audio.
  Added latency measured around 80–125 ms on the API 36 emulator
  (docs/design/audio.md).

**Clipboard, links, share, drag and drop, APK install**

- **Clipboard text, both ways** — copy on the phone, paste on the Mac and the
  other way round; clipboard **images** travel both ways too.
- **Links Mac → phone** — Share → **Open on Phone**, Services, or drop a link
  on the Deck; it opens in the Android app that handles it, in a new window.
- **Share phone → Mac** — Android Share → **Send to Mac**: links open in the
  Mac's browser, text lands on the Mac clipboard, images up to 50 MB each are
  saved to `~/Downloads/PocketDeck/` (and the clipboard).
- **Drag and drop** — drop files from Finder on any phone window; the phone
  writes them to `Downloads/PocketDeck/`, scans them and offers the app's Send
  chooser. Up to 200 MiB per file, resumable.
- **Install APKs from the Mac** — drop an `.apk` / `.apks` / `.xapk` bundle on
  the Deck, or use Open With, Services or the menu bar. The Deck shows
  progress and the result.
- **Focus sync** — a Mac Focus with the PocketDeck filter turns the phone's Do
  Not Disturb on (priority, alarms only or nothing) and back when it ends. A DND
  you set yourself is never turned off. The menu bar toggles the phone's DND by
  hand, and a Shortcut can too.
- **Phone files in Finder** — the phone's shared storage appears as a
  **PocketDeck** location in Finder: browse, open and Quick Look files, copy
  them out, and copy files in, edit, rename, move, make folders and delete.
  Writes are verified on the phone and MediaStore is kept in step, so a new
  photo shows up in the Gallery. While a folder has been open the phone keeps
  watching it for ten minutes, and the app signals the domain's working set so
  Finder can pick the change up — the end-to-end proof of a phone-side change
  appearing in Finder is still open (see docs/design/files.md "S5 Done"). A
  delete is **immediate** — the phone has no Trash — and Finder says
  so. Cached files stay readable while the phone is away, and edits made then
  upload when it is back; when both sides changed a file, both copies are kept
  (`name (from Mac).ext`). A copy onto a name the phone already has is refused,
  never silently replaced. The first time, turn PocketDeck on in System
  Settings › General › Login Items & Extensions (Settings › General has the
  switch and the link).
- **Control Center controls** (in progress, opt-in build: the controls do not yet appear in Control Center) —
  Phone Do Not Disturb as a toggle, Ring Phone, a ringer-mode control and Open
  PocketDeck, built as a small widget extension that reads a snapshot the app
  writes and sends its actions over a private socket in the app's group. A
  hotspot control is not included: at shell UID Android offers no way to toggle
  the person's existing hotspot without replacing its configuration.

**Notifications and Now Playing** (opt-in on both sides)

- The phone's notifications appear in macOS Notification Center; clicking one
  opens that app's window.
- A notification's own buttons and a **Reply** field ride along on its banner;
  clearing the banner clears it on the phone, and a phone-side removal clears
  the banner. A chat's picture is on the banner too.
- Android 16 **Live Updates** (a ride's ETA, a delivery, a timer) stay in the
  menu bar's **Live on <phone>** section and update in place while they run.
- **Muted apps** per phone drop those apps' notifications before they appear,
  and a sign-in code gets a **Copy code** button that copies it concealed for
  90 seconds.
- Media on the phone shows up in **Now Playing** on the Mac with
  play/pause/next/previous, even while the phone is locked and its screen is
  off.

**The Mac knows the phone**

- **Dock and Launchpad apps** — right-click an app in the Deck → **Add to
  Dock**: a real Mac app bundle named "App (Phone)" with the app's icon, in
  Launchpad, Spotlight and ⌘-Tab. Launching it opens that app's window.
- **Spotlight** — every phone app searches as "App (Phone name)".
- Silently reconnects to the last phone; closes a window by closing the app's
  display, saves bandwidth when a window is hidden or covered, and asks the
  phone for nothing while you're not looking (battery rules in
  docs/ARCHITECTURE.md).

**Security**

- One LAN-only TCP session per phone, one Bonjour advertisement
  (`_pocketdeck._tcp`), and direct connect by address. Pairing shows a
  six-digit code on both screens (numeric comparison) or exchanges a QR code;
  sessions are authenticated with keys created at pairing (docs/PROTOCOL.md).

## Requirements

- **Android 11+** (minSdk 30) with **Shizuku** installed and running.
  Verified against Android 16 (API 36 emulator and a Samsung One UI build).
- **macOS 26 or later.**
- Mac and phone on the same network.

## Install / build from source

No releases yet. Build both sides yourself — the full recipe, including the
pairing walk-through and an emulator rig for phoneless testing, is in
[docs/TRY-IT.md](docs/TRY-IT.md).

## Pairing

1. On the phone: PocketDeck → **Pair new Mac** (first run: **Scan QR code**).
2. On the Mac: **Pair with QR**, or connect by address and compare the
   six-digit code.
3. Tap **Allow** on the phone. Lock it — it never needs to be unlocked.
   Remembers the Mac afterwards.

Every detail: [docs/TRY-IT.md](docs/TRY-IT.md).

## Privacy

- **Nothing leaves your home network.** One TCP session, phone → Mac, over the
  LAN. No accounts, no analytics, no logging anywhere.
- The session is **mutual TLS 1.3 with both certificates pinned at pairing**
  (docs/PROTOCOL.md, docs/design/e2ee.md): no plaintext phase, no account and
  no key material outside the two devices.
- **Notifications and Now Playing are off by default on both sides** and need
  a per-phone opt-in (Android's notification-listener consent *and* a switch
  in PocketDeck's UI) before anything is read or shown.
- The phone's screen stays locked. PocketDeck never unlocks it, never
  dismisses the keyguard, and never opens the phone's panel; apps run on a
  virtual display Android treats as unlocked (docs/ARCHITECTURE.md).

## Use with AI agents (MCP)

PocketDeck can hand the connected phone to an AI agent on the same Mac over a
local MCP server: see what a window shows, tap, type, swipe, open apps, send
links and files, read the phone's state. It is **off by default** —
Settings › Automation › **Allow AI agents to control your phone**. While an
agent is connected the menu bar shows a small indicator, and its menu has
**Disconnect agent**.

Everything stays local: a private UNIX socket in the PocketDeck support folder,
same user only, no network listener. The app logs a tool call as name and
duration only — never arguments, typed text, URLs, file names or pixels.
[Setting up an MCP client](docs/design/mcp.md).

Point an MCP client at the shim that ships inside the app:

```json
{"command": "/Applications/PocketDeck.app/Contents/Helpers/pocketdeck-mcp"}
```

Settings › Automation shows this snippet with a Copy button (it adds
`"args": ["--profile", "NAME"]` for a non-default profile). With Claude Code:

```sh
claude mcp add pocketdeck -- /Applications/PocketDeck.app/Contents/Helpers/pocketdeck-mcp
```

The agent gets 13 tools: phone status, list apps, open an app, list windows,
screenshot, tap, long-press, swipe, type text, press a key, close a window,
send a link, send a file.

## Status

Pre-release. Traffic is end-to-end encrypted: **mutual TLS 1.3 with the
certificates pinned at pairing** (protocol v2). Details and the rest of the
plan: [docs/ROADMAP.md](docs/ROADMAP.md).

## Docs

| | |
|---|---|
| [docs/TRY-IT.md](docs/TRY-IT.md) | setup, first pairing, emulator rig, known limitations |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | how the phone and the Mac actually work |
| [docs/PROTOCOL.md](docs/PROTOCOL.md) | the wire protocol (single source of truth) |
| [docs/ROADMAP.md](docs/ROADMAP.md) | status and what is next |
| [docs/UX.md](docs/UX.md) | interface conventions |
| [docs/design/*.md](docs/design) | per-feature design notes (audio, dock, mirror, notify, drops, …) |
| [tools/emulator/](tools/emulator/README.md) | boots the real server on a local emulator |
| [tools/fakephone/](tools/fakephone/README.md) | protocol-complete fake phone for e2e checks |

## License

[PolyForm Noncommercial 1.0.0](LICENSE). You may use, change and share PocketDeck for
personal and other noncommercial purposes; commercial use is not licensed. Third-party
dependencies (SwiftNIO, swift-crypto, …) keep their own licenses.
