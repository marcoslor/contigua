# Features and known limits

The short version is in the [README](../README.md). Everything in the first group is part of the source-build recipe. Several
features are marked in [docs/ROADMAP.md](ROADMAP.md) as built but still
waiting for a hands-on check on a real Mac and phone.

## Works from a source build

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
- **Window styles** — Framed (the default: a Quick Look-like frame whose
  material bar holds the lights, the title and the controls), Compact (a standard
  window: the system's own title bar above the app) or Immersive (the window
  *is* the app; a dwell pill brings the lights back). Switch with View ▸
  Window Style or ⌥⌘F; the choice is remembered per app.
- **Open <App> on Mac (handoff)** — move the task in the phone's foreground onto
  the Mac (the card's row, the Phone menu, or ⌘⇧C): same app, a new window.
- **Live Text** — View ▸ Live Text (⌘⇧T) freezes a window on its current frame:
  select and copy text, use data detectors, lift an image subject, Visual Look
  Up, translate where macOS offers it. ⌘C without a selection copies the
  whole frame. Input stays paused while the mode is
  on; Esc brings live video back ([docs/design/livetext.md](design/livetext.md)).

**Audio**

- **Audio from the phone to the Mac** — with a window open, the phone's media
  and game audio plays on the Mac with a volume slider and mute in the menu
  bar; media stays silent on the phone's speaker. Capture follows the focused
  window's app where Android allows it and falls back to all-device audio.
  Added latency measured around 80–125 ms on the API 36 emulator
  ([docs/design/audio.md](design/audio.md)).

**Clipboard, links, share, drag and drop, APK install, files**

- **Clipboard text, both ways** — copy on the phone, paste on the Mac and the
  other way round; clipboard **images** travel both ways too.
- **Links Mac → phone** — Share → **Open on Phone**, Services, or drop a link
  on the Deck; it opens in the Android app that handles it, in a new window.
- **Share phone → Mac** — Android Share → **Send to Mac**: links open in the
  Mac's browser, text lands on the Mac clipboard, images up to 50 MB each are
  saved to `~/Downloads/Contigua/` (and the clipboard).
- **Drag and drop** — drop files from Finder on any phone window; the phone
  writes them to `Downloads/Contigua/`, scans them and offers the app's Send
  chooser. Up to 200 MiB per file, resumable.
- **Install APKs from the Mac** — drop an `.apk` / `.apks` / `.xapk` bundle on
  the Deck, or use Open With, Services or the menu bar. The Deck shows
  progress and the result.
- **Focus sync** — a Mac Focus with the Contigua filter turns the phone's Do
  Not Disturb on (priority, alarms only or nothing) and back when it ends. A DND
  you set yourself is never turned off. The menu bar toggles the phone's DND by
  hand, and a Shortcut can too.
- **Phone files in Finder** — the phone's shared storage appears as a
  **Contigua** location in Finder: browse, Quick Look, copy out, and copy in,
  edit, rename, move, make folders and delete. A delete is immediate (the phone
  has no Trash), and a copy onto an existing name is refused, never silently
  replaced. Cached files stay readable while the phone is away. Turn Contigua
  on once in System Settings › General › Login Items & Extensions. Conflict
  handling, watching and verification: [docs/design/files.md](design/files.md).

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
  (`_contigua._tcp`), and direct connect by address. Pairing shows a
  six-digit code on both screens (numeric comparison) or exchanges a QR code;
  sessions are authenticated with keys created at pairing (docs/PROTOCOL.md).

## Built but unproven on real hardware, or in progress

**Notifications and Now Playing** (opt-in on both sides). ROADMAP items 8 and 9
list the real-device proof as still open: the VM never showed a Contigua
banner.

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
- Media on the phone shows up in **Now Playing** on the Mac with its
  **artwork**, play/pause/next/previous, a **position bar** you can drag to
  seek (plus 15-second skips), a **volume** slider for the phone's media
  stream, and, when several apps are playing, the choice of which one the Mac
  follows — even while the phone is locked and its screen is off.

**Control Center controls** (in progress, opt-in build: the controls do not yet
appear in Control Center) — Phone Do Not Disturb as a toggle, Ring Phone, a
ringer-mode control and Open Contigua, built as a small widget extension. In the
test VM an ad-hoc signed build never showed them in the gallery, and whether a
signed build would is not known
([docs/design/controls.md](design/controls.md)). A hotspot control is not
included: at shell UID Android offers no way to toggle the person's existing
hotspot without replacing its configuration.

**Phone as a Mac camera** is on the `feature/camera` branch, not in `main`; it
needs a Developer ID (docs/ROADMAP.md item 7).

## Compatibility and known limits

Tested on:

- Android 16 (API 36) emulator, driven by `tools/emulator/`.
- A Samsung phone running One UI on Android 16.
- macOS 26 or later (the deployment target in `macos/Package.swift`).

Everything else is untested: other Android versions (the minimum is Android 14,
API 34, but only Android 16 has been run), other phone makers and macOS releases
before 26. Shizuku must be installed and running on the phone.

App windows need a phone that gives their virtual displays a display group of
their own, so they keep running while the phone's own screen sleeps. Contigua
gets that from an Android virtual device: the first app window creates one
companion device association for it (owned by the shell user, address
`02:c0:4e:00:00:01`). It is reused for every later window, and **Forget all
Macs** removes it. To remove it by hand:
`adb shell cmd companiondevice disassociate 0 com.android.shell 02:c0:4e:00:00:01`.
On a phone where a window display still lands in the phone screen's own group,
app windows do not open: the Mac says "This phone can't give app windows a
screen of their own." The Phone Mirror still works there.

Known limits from [docs/TRY-IT.md](TRY-IT.md):

- With an app window open, the phone's own screen keeps its normal timeout and
  power button. Whether one press locks or wakes it on the Samsung phone is not
  yet checked (#3, #24).
- Chrome stable is disabled for the user by the vendor on that phone; use
  Chrome Dev from the app list.
- After about 20 minutes with no stream, a dozing phone can stop answering mDNS;
  wake its screen once and the Mac finds it again.
- One Mac at a time; a second session gets "busy".
- Windows larger than 2560 px of virtual display are scaled down, which lowers
  the density.
- The mouse's Forward button does nothing yet.
