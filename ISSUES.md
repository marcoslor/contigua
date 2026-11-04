# Open issues

Until the project has an issue tracker, open bugs, tasks and queued features live here, in priority order. Planned releases and their scope are in [docs/ROADMAP.md](docs/ROADMAP.md).

- **Adding:** anyone who finds a problem outside their task adds it here, in the section where it fits, with the next free `ISS-` number. Say what happens, where it was seen, and the evidence (a check name, a log line, a measurement). Never write personal data: no notification text, file names or phone contents (AGENTS.md, privacy).
- **Closing:** the reviewer deletes an item once the fix is merged and verified, and names its ID in the merge commit. Numbers are never reused.
- **Re-check** means the item may already be fixed by later work. Confirm it before working on it.

## 1. High QoL, next up

- **ISS-37 Finder keeps phone files that are gone.** On the person's phone (2026-11-04), Finder listed 568 entries in DCIM/Camera; the phone had 109. The other 459 were photos moved off or deleted on the phone since June (and 15 of Android's `.trashed-…` files), so Finder showed them, asked thumbnails for them, and got `fs_not_found` (334 of 446 asks).
  - The phone's listing at that moment was right (109 items), so the deletions never reached the File Provider: not through the change feed (`changes … deleted=0`, an expired anchor answered `items=0 deleted=0`) and not through a fresh folder listing.
  - **Why (architectural):** the Mac tells the system only what it sees happen. A folder's first listing in each app run is a silent baseline, the system deletes only when told, and the anchor log is in memory, so every app start, reconnect or phone update loses the changes made meanwhile: deletions for good, and additions until a push.
  - **Design and spec (2026-11-04):** `docs/design/files.md` § Sync integrity; FILES-31…36. A durable replica record; every complete listing diffs (with guards so a diff never deletes a real file); a durable change log; a reconnect resync through a new `fs.digest`; not-found repair; Android's `.trashed-*`/`.pending-*` left out. Four slices; slice 1 (Mac only) fixes the person's case on the next visit. Next free worker.
  - Also seen: the extension opens a new bridge connection per thumbnail ask (419 `bridge: hello` in 8 minutes). Check whether that's meant to be.
- **ISS-2 Finder thumbnails for phone photos and videos.** **Merged to main 2026-11-03** (FILES-22…29, `fs.thumb`; 1bd0ce9c). Proven on the emulator (HEIC/JPEG/MP4 in 0.5–0.7 s, 512 px, no held wake locks) and in the VM (Finder draws the phone's picture; a PDF keeps its icon). Finder never asks again after a lost thumbnail until the file changes (FILES-26), so the queue never expires an ask (FILES-29). **Big folders merged 2026-11-04** (`fix/thumbs-scale`, ba0ce5f9): one pool of 3 asks, newest Finder batch first, so the pictures follow the scroll; a cancelled batch answers at once with `NSUserCancelledError`, and no ask leaves it after the cancel (FILES-25); each phone page is listed once per pass (FILES-30: 3,000 names in 6.45 s instead of 16.3 s in the VM). K2 1724/0. **Real phone, 2026-11-04:** the phone is fast (78 batches, 446 asks, median 33 ms and p90 176 ms per batch, about 6 s of work in all, so the battery cost is negligible), but the pictures came slowly, because 334 of the 446 asks were for files that no longer exist (ISS-37). Re-check after ISS-37.
- **ISS-36 A paste or drop on WhatsApp opens its chat picker, not the open chat** (the person, 2026-11-04: acceptable, an Android limit). The share lands on WhatsApp's share target. Maybe later: an image clip plus a paste key into the focused compose field, if WhatsApp's field takes rich content.

## 2. Bugs you can see

- **ISS-39 App windows are drawn slightly scaled, so text is soft.** The virtual display is the window's pixel size floored to 16 px and capped at 2560 px on the long side (`VideoSize.displayPixels`), and the Mac stretches the frame over the whole window (`Letterbox` `.stretch`). So unless both sides are exact multiples of 16, every frame is resampled by up to 15 px, and a window wider than 2560 px is upscaled. The person's WhatsApp window came at 2560×1488.
  - The person's encoder (`c2.qti.avc.encoder`, 2026-11-04) takes any even size (`alignment 2x2`) up to 8192×8192, so neither rule is needed there.
  - Fix: the phone reports its encoder's alignment and maximum size, the Mac asks for the window's exact pixels within them, and draws 1:1 (no stretch).
  - Test first, plus a crispness metric that must move: the Mac's displayed frame against the phone's lossless capture of the same display (`screencap -d <id>`), as PSNR/SSIM over a text-heavy screen.
- **ISS-40 Crispness beyond 1:1** (the person asked, 2026-11-04). Today: H.264, 4:2:0, VBR, 60 fps, capped at 8 Mbps; the code's own formula wants about 27 Mbps for a 2560×1488 window. A still screen keeps the quality of the frame it last changed in, because the repeated frames don't refine it. The person's link already shows backpressure at 8 Mbps (`stream 7 backpressure: dropping deltas`), so more bits alone may not help.
  - Options for one prototype round on the real phone, side by side on the same text screen, with ISS-39's metric and the bitrate each costs:
    - (a) today;
    - (b) a higher cap, about 25 Mbps;
    - (c) HEVC (`c2.qti.hevc.encoder`; the Mac decodes it in hardware), about 30–50 % better per bit;
    - (d) a refresh when the screen goes still: one high-quality frame about 300 ms after the motion stops;
    - (e) lossless still frames: the exact pixels the phone drew, colour included, with no 4:2:0 fringes.
  - After ISS-39.
- **ISS-3 An app window fades to black when the phone wakes.** Root-caused on the real phone (2026-11-03): [docs/research/lock-fade.md](docs/research/lock-fade.md).
  - One UI keeps PocketDeck's virtual displays in the panel's display group. So while a window is open on a locked phone, PocketDeck keeps that group awake with the panel blacked out, and Android counts the phone as awake.
  - A wake press is then a sleep press to Android: it runs its screen-off fade (ColorFade, about 330 ms) on the window's virtual display too, turns the display off, and PocketDeck's hand-back wakes everything again about 0.65 s after the press. The Mac shows the fade, a dark moment, then the picture, together with the phone's screen.
  - A lock press shows nothing: PocketDeck re-wakes the group within about 20 ms, before the fade draws.
  - **Tried, not merged:** `fix/flicker`'s phone-side gate. It released on the first key frame after the edge, and that frame was itself black (the display turns on before the app draws).
  - **DeX never fades:** its screen sits in display group 2. One UI's group mapper hands out groups by its own rules (DeX, CarLife, per virtual device) and ignores `FLAG_OWN_DISPLAY_GROUP` for ours (lock-fade.md § Why DeX never fades).
  - **Group probe done on the phone (2026-11-03, `spike/group-probe`): no display flag earns a group of its own.** Every variant sat in group 0, and `CARLIFE` was refused (lock-fade.md, option 0).
  - **Next: the virtual device path, a phone probe first (the person OK'd it, 2026-11-04).** Being built on `spike/vd-probe` (`.agent/vd-probe/`).
    - The shell user already holds `CREATE_VIRTUAL_DEVICE` by role, and already owns an app-streaming companion association. So the probe reuses that association and adds nothing to the phone.
    - It creates a virtual device and a few displays on it, reads their groups, watches one through a lock and a wake, then releases everything.
    - If a device display gets a group of its own, plan the move. If One UI ignores it too, fall back to holding the Mac's picture from the press until the app has redrawn (Mac-side, any phone; the window stands still for about 0.7 s instead of fading).
- **ISS-24 Waking the phone sometimes takes two presses while a window is open.** PocketDeck's relight after a lock press runs a panel-off step of about 2.5 s (`relight … +2521ms panel off returned`). A wake press inside it is slept by Android (with the fade), and PocketDeck never hands the panel back, so the phone's screen and the Mac window stay dark until a second press. Seen twice on 2026-11-03, 2.0 s and 2.5 s after a lock press (lock-fade.md § The two-press wake). Fix: hand the panel back on a press seen during the relight's own panel-off step. Test first. **On hold (the person, 2026-11-03):** if the group probe (ISS-3) finds an own display group, the relight goes away and this bug with it.
- **ISS-33 A share sheet closing closes the app's window.** On the person's phone (v135, 2026-11-04): a drop on a WhatsApp window opens WhatsApp's chat picker as a second task on the window's display; when it closes, `TaskArrival` (which had re-pointed the window to the picker's task) closes the window as `app_exited`, although WhatsApp's own task is still there. Same with Chrome's chooser. From the in-stream New window work (WIN-44…49). Being fixed on `fix/share-close` (`.agent/share-close/`).
- **ISS-34 The drop path logs the saved file's name** (`drop …: saved /sdcard/Download/PocketDeck/<name>`), against R-PRIV-1. Audit every drop, share and clip-image log line. On `fix/share-close`.
- **ISS-35 The phone's own keyboard stops showing after a drop or paste on a window.** On the person's phone (2026-11-04): after each share, the app on the phone's own screen couldn't show its keyboard for about 5–45 s (`ImeTracker … onCancelled at PHASE_CLIENT_REPORT_REQUESTED_VISIBLE_TYPES`) until it was reopened. Emulator repro first, on `fix/share-close`; if AOSP doesn't show it, a phone capture by me.
- **ISS-29 The Window menu reads "Enter Full Screen" twice on macOS 26.** The system's own "Enter Full Screen ›" submenu (beside Move & Resize) sits next to the app's "Enter Full Screen ⌃⌘F" (VM shot, 2026-11-04, `.agent/mw-mac/shots/r5/light-5-window-menu.png`). `MenuCleanup` removes only a key-less duplicate without children, so the system's submenu stays. On main too. MENU-7 and MENU-11.
  - **Prototype round done (2026-11-04, `proto/fsmenu` 469a4650; sheets in `.agent/proto/fsmenu/`, pick sheet `fsmenu-pick.png`):**
    - **Apple's convention:** Finder, Safari and TextEdit all put "Enter Full Screen" last in **View**, shown with **fn‑F** (Globe F), and the Window menu keeps the system's "Full Screen Tile ›" (Left of Screen, Right of Screen). In this run the submenu read "Full Screen Tile", not "Enter Full Screen" as in r5, so the doubled title may depend on state; the misplacement doesn't.
    - **Options:** A, our item last in View (⌃⌘F, our symbol); B, macOS's own item (identical to Apple's apps: fn‑F, Apple's symbol, disabled for the Phone Mirror by itself). Whether ⌃⌘F still works under B is unproven: check it first in the build.
    - **Spec fix either way:** MENU-7 says the item is disabled for the Deck, but the code lets the Deck go full screen (only the Phone Mirror opts out) and the system's tile submenu is enabled for it. Fix the spec to match.
    - **The person picked B (2026-11-04).** Being built on `fix/fsmenu` (`.agent/fsmenu/`): ⌃⌘F proven in the VM first, kept as a hidden alternate if macOS drops it.
- **ISS-7 A shared app stops responding after ⌘K under load.** The shared app's control channel stalls after a ⌘K launch while WindowServer is busy. Seen in 3 of about 10 e2e runs on 2026-11-01, none since.
- **ISS-8 A revoked Mac fails silently.** A Mac whose pairing was removed on the phone waits through a 16 s handshake timeout instead of being told. Re-check.
- **ISS-9 "Busy" sticks after a network drop.** The phone kept reporting a busy session after a drop. Re-check: the paths layer (E-10, 2026-11-02) frees the slot.
- **ISS-10 Slow app opens.** Re-check: with the phone locked, the first frame went from 23 s to 0.16–0.6 s on 2026-11-01.

- **ISS-38 A task arrival is matched to the active phone, not the reporting one.** `WindowManager.noteTaskArrival` uses the active phone; with two phones (WIN-35) the new window could go to the wrong one. Small, Mac-side, test first.

## 3. Under the hood

- **ISS-11 Battery cost of keep-alive pings.** Measure on a real phone what the paths layer's ping policy costs (`docs/design/paths.md`), idle and with one window open.
- **ISS-12 The phone can't tell that every path went silent.** Only the Mac detects it, through its pong rule. The phone waits for the Mac to rejoin.
- **ISS-14 Untested requirements.** WIN-16: no input reaches the phone after a drop, and `window.open` after a reconnect. Also two or more phones in the waiting line.

## 4. Test setup (no product change)

- **ISS-16 VM notification checks are broken.** The `pd-e2e` guest refuses PocketDeck's notifications without a prompt, and `check_notify_vm` finds banners by window geometry. macOS 26 draws banners inside one full-screen Notification Center window; use the `AXNotificationCenterBanner` group, as `check_notify_proto` does.
- **ISS-17 The "no stale picture" NFR has a thin margin.** It measured 1792–1831 ms against a 2000 ms limit and flaked twice under load.
- **ISS-18 Rejoin judges count only video frames.** On a still screen the probe-join and grace-rejoin judges read FAIL, because the phone then sends `window.still` heartbeats, not frames. Count those too.
- **ISS-19 The prototype screenshot tool lives on the prototype branch only.** Merge it into main's rig.
- **ISS-20 One unnamed K2 flake.** One assertion failed once in 1340 tests on 2026-10-31 and passed on the rerun. Log the test name the next time it happens.
- **ISS-21 Older rig items.** Re-check each one: the `controls` check's gear AX order (PANEL-7), the fake phone's pause test, the Finder delete-warning proof in the VM, and the panel-yield sequencing steps.
- **ISS-30 VM review shots never switch to light.** `PD_E2E_SHOT_APPEARANCE=light` boots draw dark menus and a dark bar (r5's "light" multiwin set and both fsmenu sheets, 2026-11-04), so light mode has never been reviewed in the VM. Find where the appearance should be set in the guest (`vm-e2e.sh` passes it through) and prove it with one light shot of a Finder menu.
- **ISS-31 The Deck's zoom-drag limit has a thin margin.** DECK-5 allows 21 ms (drag p95). At load < 4, main's runs sit at 18–21 ms and one in ten reaches 22–23 ms; at load 5–6 it was 28 ms twice (2026-11-04, `.agent/deck-perf/`). Every run also has about 6 frames at 33 ms (dropped). Either measure the limit again on a quiet host, or have the check wait for its load gate (as deck-perf did: 5-min load < 4, free memory ≥ 37 %, no swap-outs for 30 s). `_common.md`'s swap < 2 GB gate can't be met on the 8 GB Mac after any e2e.

## 5. Features, in order

Each goes through the requirements gate first: a surface spec, the conventions, prototypes for anything visual, and opt-in for personal data.

1. **Live Updates on the Mac, natively** (the person, 2026-11-04: "close or better experience than iPhone"; macOS shows an iPhone's Live Activities in the menu bar). Android's ongoing cards become native Mac UI that updates in place: delivery and ride trackers, navigation, timers, sports. Today only Android 16's promoted Live Updates are forwarded, as a row in the panel (NOTIFY-3, NOTIFY-12); a legacy persistent card such as a food-delivery tracker isn't forwarded at all.
   - **Sources, richest first:**
     - Android's Live Updates (`FLAG_PROMOTED_ONGOING`, `ProgressStyle` segments and points, short critical text, chronometer) are exact;
     - legacy ongoing cards with a progress bar, a chronometer or countdown, or a big text, in categories such as transport, navigation, progress, stopwatch, alarm and event. Many apps will move to the Live Updates API over the years; until then this is a heuristic, so it gets per-app control on the Mac;
     - cards with a custom layout: their title and text from the extras, else a lossless picture of the card rendered on the phone, sent only when it changes.
     - Never: foreground-service noise (VPN, sync, "running"), media (its own Now Playing surface), calls (feature 3).
   - **On the Mac:** a live item in the menu bar (app icon, plus the short text, a countdown ticking on the Mac, or a progress ring); a click opens a card with the full progress (segments, points), the text and the app's actions, which work both ways, and Open, which shows the app in a PocketDeck window. Several at once. A banner at the start and on alerting updates, as today.
   - **Better than iPhone:** actions both ways, countdowns that tick on the Mac with no traffic, several at once, per-app control, a short history of finished ones ("Delivered 12:40").
   - **Timers both ways come first,** as the cleanest Live Update and the two-way case: a phone timer, stopwatch or alarm becomes a live countdown with pause and stop; "Start Timer…" on the Mac sets it in the phone's own Clock app, so it rings even when the Mac sleeps.
   - **Requirements gate:** research note (Android 16/17 Live Updates, One UI's Now Bar, what disqualifies promotion), surface spec, then a visual prototype round with 3–4 real renders (menu-bar items per update; one menu-bar item with a stack; an island around the notch; a desktop widget), the person picks.
2. **Several phones at once.** An audit and a plan come first; the session layer holds one session today.
3. **Calls and messages.** Answer or decline, place calls, and reply to texts. Starts with the notification reply path.
4. **Instant Hotspot.** One click in the menu bar turns on the phone's hotspot and joins it.
5. **Handoff, Mac to phone.** The open tab or document continues on the phone.
6. **Phone photos on the Mac.** Recent photos and screenshots in Finder or a Recents strip, with drag-out. Needs ISS-2.
7. Then: the phone as a key, Shortcuts both ways, the phone as a Mac remote, Mac-to-phone notifications, Focus modes and the Batteries widget, Wi-Fi password sharing and last-seen location.

- **ISS-41 A web client: PocketDeck for Windows and Linux (a very big epic; the person, 2026-11-04).** macOS stays the first-class, native app. Windows and Linux get a well-built web client (installable as a PWA), with no native app there. SwiftUI may be deprecated in favour of components shared between the Mac and the web.
  - **What a browser makes hard,** whatever the UI toolkit:
    - **Reaching the phone on a LAN:** a page can't open raw sockets. It needs WebSocket, WebTransport or WebRTC, and WebCodecs and WebGPU need a secure context. An `https` page can't call an `http://` LAN address (mixed content, and Chrome's local-network permission). Options: WebRTC with the pairing's fingerprint pinned; the phone serving `https` under a real certificate (the Plex `*.plex.direct` pattern, which needs a small certificate service but carries no traffic); or a self-signed warning (poor).
    - **Video:** WebCodecs `VideoDecoder` (H.264 everywhere, HEVC where the hardware has it) into a canvas or WebGPU texture.
    - **Input:** browsers keep some shortcuts (⌃W, ⌃T, ⌃N) unless the Keyboard Lock API is available in full screen (Chromium only). Also pointer lock, IME composition, and clipboard permissions (images are limited).
    - **Files:** no Finder-like integration; File System Access (Chromium), and drag-and-drop into the page.
    - **Notifications:** only while the page or PWA is open; Web Push needs a push service.
    - **Windows:** each app window is a browser window.
  - **GPUI in the browser (checked 2026-11-04):** upstream Zed has an experimental `gpui_web` crate (WebGPU with a WebGL2 fallback; nightly Rust; cross-origin isolation for threads). It has one canvas and one window per page, no app menus, and canvas-drawn text (IME and accessibility weaker than the DOM). Zed itself doesn't ship on the web. Unknown: whether it can show an external video frame, which a stream window needs.
  - **Shared code:**
    - The deep Mac integrations (File Provider, Notification Center, menu bar, Dock, Live Text) stay Swift whatever happens. So "shared components" means the UI surfaces (Deck, stream window, Settings, pairing, live updates), plus a shared core: protocol, session, E2EE, input mapping and transfer.
    - A Rust core works on this Mac (native compile, plus a `wasm32` target), bridged to Swift (UniFFI) and to the web (wasm-bindgen).
    - Kotlin Multiplatform is out here: Kotlin/Native's macOS targets need a JVM on the host, and this Mac runs no JVM.
  - **First step, a spike** (no UI decision yet): a page on a Windows or Linux machine reaches the paired phone on the LAN with no cloud in the traffic path, opens one stream decoded by WebCodecs with input, and measures latency against the Mac app. Then one prototype round for the UI toolkit (GPUI web vs a DOM framework), showing the Deck and one stream window, and a written decision.

## 6. On their own branches

These need something the public build can't assume, so they stay off `main` (AGENTS.md).

- **Wi-Fi Direct** (`feature/direct-link`): a direct Wi-Fi Aware link between the Mac and the phone, for when there's no shared LAN. It needs SIP off, the boot settings `wifiaware_allowlist=0 amfi_get_out_of_my_way=1` and private Apple API. It may never merge. `main` keeps the groundwork: one session over several paths, switching, replay and the grace (`docs/design/paths.md`). Research: `docs/research/wifi-aware-direct-link/`.
  - **ISS-22** Move the direct-only docs from `main` to the branch, as camera does: `docs/design/direct-link.md`, the DIRECT rows of `docs/specs/transport.md`, and the Wi-Fi Aware lines and `direct.key` in `docs/PROTOCOL.md` and `docs/design/paths.md`. On `main`, leave one line saying where the provider lives.
  - **Next on the branch:** the Mac helper (a root service that drives the link, with a userspace network stack), whose first gate is a throughput benchmark, since the 2026-10-30 proof only carried about 1 Mbit/s. Then the phone provider, then the integration and its setting.
- **Camera sharing** (`feature/camera`): the phone as a Mac camera. Needs a paid Apple Developer ID for the camera extension.
