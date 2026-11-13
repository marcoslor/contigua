# Changelog

All notable changes are listed here, in the style of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The version follows [SemVer](https://semver.org/), 0.x, and lives in `VERSION`.

## 0.1.0 (unreleased)

The first public alpha. There are no binaries; build from source with
[docs/TRY-IT.md](docs/TRY-IT.md). Items marked "unproven" are built but have
not been checked on a real Mac and phone.

### Windows and input

- One resizable Mac window per Android app, several at once, running on the phone while it stays locked.
- A Phone window that mirrors the phone's own screen, with Back, Home and Recents.
- Typed keys, clicks, drags, scroll, hover, trackpad scroll with fling, and pinch and rotate.
- Framed and Immersive window styles, remembered per app.
- Hand a task from the phone to a Mac window.
- Live Text on a frozen frame: select and copy text, Visual Look Up, translate (unproven).
- Dock and Launchpad entries for phone apps, and Spotlight search for them (the Shortcuts actions are unproven).

### Audio

- Phone media and game audio plays on the Mac, with volume and mute in the menu bar and the phone's speaker kept silent.
- Capture follows the focused app where Android allows it. Measured on the API 36 emulator only; real phones are unproven.

### Sharing (clipboard, links, share, drops, APK install)

- Clipboard text and images, both ways.
- Open a link on the phone from the Mac (Share, Services or a drop on the Deck).
- Android Share to the Mac: links, text and images.
- Drop files from Finder onto a phone window: resumable, up to 200 MiB each.
- Install .apk, .apks and .xapk files dropped on the Deck.
- Mac Focus turns the phone's Do Not Disturb on and off (unproven).

### Phone files in Finder

- The phone's shared storage appears as a Finder location: browse, Quick Look, copy in and out, edit, rename, move, make folders, delete.
- A delete is immediate and a copy onto an existing name is refused. Cached files stay readable while the phone is away.
- Proven in a VM only; a real Mac and phone pass is still to do.

### Notifications and Now Playing

- Phone notifications in Notification Center with buttons, inline reply, two-way dismissal, pictures, muted apps and a Copy code action. Opt-in on both sides (unproven).
- Android 16 Live Updates in the menu bar (unproven).
- Now Playing on the Mac with artwork, transport buttons, a seek bar, phone media volume and a choice among players (unproven).
- Control Center controls are in progress and do not appear yet.

### AI agents (MCP)

- A local MCP server on the Mac: list apps, open one, screenshot a window, tap, type and swipe (unproven).

### Security

- LAN only. Mutual TLS 1.3 with keys pinned at pairing.
- Pairing by a six-digit code compared on both screens, or by QR code.
- Anything that reads personal data is off until a person turns it on.

### Known limits

- Tested on an Android 16 emulator, one Samsung phone and macOS 26. Everything else is untested; Shizuku must be running.
- One Mac at a time per phone.
- On the Samsung build the physical panel is powered off while a window streams.
- A dozing phone can stop answering discovery after about 20 minutes; wake its screen once.
- Windows over 2560 px of virtual display are scaled down.
- The mouse's Forward button does nothing yet.
- Phone as a Mac camera is not in this release; it needs a Developer ID.

The wire protocol is at version 4. There is no backward compatibility during the alpha.
