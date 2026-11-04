# Open issues

Until the project has an issue tracker, open bugs, tasks and queued features live here, in priority order. Planned releases and their scope are in [docs/ROADMAP.md](docs/ROADMAP.md).

- **Adding:** anyone who finds a problem outside their task adds it here, in the section where it fits, with the next free `ISS-` number. Say what happens, where it was seen, and the evidence (a check name, a log line, a measurement). Never write personal data: no notification text, file names or phone contents (AGENTS.md, privacy).
- **Closing:** the reviewer deletes an item once the fix is merged and verified, and names its ID in the merge commit. Numbers are never reused.
- **Re-check** means the item may already be fixed by later work. Confirm it before working on it.

## 1. High QoL, next up

- **ISS-1 Paste and drop into phone apps.** Clipboard sync for text and images already exists (opt-in, both directions; `docs/specs/share-clipboard.md`). What's missing:
  - **V1 and V2 merged to main 2026-11-03 (SHARE-16/17, db23e133):**
    - ⌘V pastes an image into the focused field: the app sets the clip, the phone answers `clip.image.done`, and the Mac sends one `KEYCODE_PASTE`.
    - Finder-copied files go through the drop path.
    - A drop or ⌘V on an app window shares straight to that window's app, once per gesture, and falls back to the chooser only when that app can't take it.
    - **Proven on the emulator** (boot 7): the image clip was written with the app in the background; a plain field pastes nothing and an image field gets the exact bytes; a targeted drop opens Messages with no chooser; an untargeted drop shows the chooser; a 3-file batch is one share.
    - **V3 merged 2026-11-03 (SHARE-18, ee5712eb):** drops of image data, `http(s)` image links (an ephemeral download, 8 MiB / 10 s, sniffed) and file promises (Photos) go through the same drop path; a link that isn't an image is refused with the spec's copy. Host e2e `drop-sources` 11/0; file promises are K2-only (scripted input can't build a real promise).
    - **All of ISS-1 is on main.** Waiting on the person's real-phone check: ⌘V an image and a Finder-copied file into a messaging app's window, drop a photo from Photos and an image from Safari onto it.
  - **Bug (the person, 2026-11-02):** copy a file in Finder, paste in a messaging app on the phone, and the file's *name* is pasted as text. Finder puts the name on the pasteboard next to the file URL, and clipboard sync sends the name. A Finder file copy must never reach the phone as its name; it pastes the file (V2) or nothing. Test first. The app may be at fault too, but ours is the name we send.
    **Fixed on main 2026-11-03 (98f5f8f4, 0732a79a):** neither clipboard sync nor ⌘V sends the name; one copied image file (≤ 8 MiB) goes as the image, HEIC re-encoded as JPEG. Waiting on the person's real-phone check (copy a photo and a PDF in Finder, paste in a messaging app).

  Plan (one surface spec through the requirements gate):
  - **V1.** ⌘V with an image: set the phone clipboard to it and send a paste key to the focused field. If the field refuses an image, share it to that window's app.
  - **V2.** ⌘V with Finder-copied files: transfer them like a drop, then share straight to the window's app. The chooser is only the fallback.
  - **V3.** Drop images from anywhere (image data, web image URLs, file promises); a drop on an app's window goes straight to that app.
  - **Spec (2026-11-03):** `docs/specs/share-clipboard.md` SHARE-16–18 and `docs/design/dragdrop.md` § "Paste and drop into an app"; the file-copy half of the bug is fixed in SHARE-2. V1–V3 are merged.

  First, a real-phone spike: which apps accept a pasted image from a shell clip (messaging and mail apps), and whether a share aimed at one app works per app.
- **ISS-2 Finder thumbnails for phone photos and videos.** **Merged to main 2026-11-03** (FILES-22…29, `fs.thumb`; 1bd0ce9c). Proven on the emulator (HEIC/JPEG/MP4 in 0.5–0.7 s, 512 px, no held wake locks) and in the VM (Finder draws the phone's picture; a PDF keeps its icon). Finder never asks again after a lost thumbnail until the file changes (FILES-26), so the queue never expires an ask (FILES-29). **Big folders merged 2026-11-04** (`fix/thumbs-scale`, ba0ce5f9): one pool of 3 asks, newest Finder batch first, so the pictures follow the scroll; a cancelled batch answers at once with `NSUserCancelledError`, and no ask leaves it after the cancel (FILES-25); each phone page is listed once per pass (FILES-30: 3,000 names in 6.45 s instead of 16.3 s in the VM). K2 1724/0. Waiting on the real-phone check: a camera folder with thousands of pictures in Finder's icon view fills where you scroll, and the cost on the phone (time per thumbnail, battery).

## 2. Bugs you can see

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
- **ISS-4 Chrome's "New window" doesn't open a new window.** It should give one more Mac window running a new instance of the app. Specced as multi-window phase 2: WIN-24…36, MENU-2/7/8/13 and the New Window table in `docs/specs/app-windows.md`.
  - **The phone half** is on `main` (2026-10-28): `multi`, `newInstance`, `taskId`, `maxWindows`, task labels and closing one task.
  - **The Mac half** (⌘N, File/Dock/Deck menus, titles per task, the cap, offline) is **merged to main 2026-11-04** (6175837b; WIN-24…36, MENU-2/7/8/13). On the merged tree: K2 1778/0; host e2e `multiwin` 29/0, `menus` 72/0, `windows` 32/0. VM review shots in `.agent/mw-mac/shots/r5/`.
    - **Installed on the Mac 2026-11-04** (main 00e91c82). **No Deck slowdown:** 10 alternating `deck` runs at load < 4 (`.agent/deck-perf/`): median zoom-drag p95 19 ms before the merge, 18 ms after (ISS-31 for the limit's margin).
  - **The app's own in-stream "New window"** is the case the person hit. Spec draft and emulator spike on `epic/mw-mac` (`.agent/mw-mac/spec-draft-in-stream.md`).
    - **Spike boot 4 (2026-11-04):** Chrome's ⋮ ▸ New window on a streamed display did **not** stay on it. Chrome started a new task on the phone's own display, in a split-screen pair with PocketDeck. The stream kept the old task, and no `window.title` arrived. So the fix must catch the new task wherever it lands, move it to a display of its own, and open a Mac window for it.
    - **Spike round 2 (boots 6–7, `.agent/instream/`):**
      - **The trigger:** Chrome's New window starts its activity with NEW_TASK | MULTIPLE_TASK | LAUNCH_ADJACENT. LAUNCH_ADJACENT is what puts the new task in a split-screen pair on the phone's own display. It repeats on demand (the "New window" row goes away at Chrome's 5-window cap).
      - **The move:** the shell and `moveRootTaskToDisplay` can't move it, because it isn't a root task (`Unknown rootTaskId`). A root task moves fine.
      - **The observer:** it never sees the new task, because it watches only the streamed displays.
      - **A false close:** opening a streamed app from the phone's launcher moves its task to the phone and sends `window.closed reason=app_exited`.
    - **Round 3 (boots 8–9):**
      - **The move works:** `startActivityFromRecents(task, launch display + fullscreen)` reparents the split child onto its own display (permission `START_TASKS_FROM_RECENTS`). The phone's split dissolves, both streams draw, and Back and close reach only that window.
      - **The signal:** a task-stack listener's `onTaskCreated` fires 66 ms after the tap. The phone's launcher never fires it.
      - **The false close** gets its own reason, `moved_to_phone` (WIN-49).
    - **Merged 2026-11-04 (f205de9f, phone v135; Mac installed):** WIN-44…49 (`docs/specs/app-windows.md`, `docs/research/in-stream-window.md`). K1 1273/0, K2 1786/0, e2e `multiwin` 46/0, `windows` 32/0, `dock` 66/0, `files` 9/0.
      - The branch's own emulator script never reached the trigger. Its four boots went to the rig and to setup: the Shizuku feed (now a shared cache, 8692f0f4), an argument order, Chrome's first run, and its notification promo. The spike proved the end-to-end move (boots 8–9).
      - **On the person's phone:** the listener registers as root (`task listener: started uid=0`).
      - **Waiting on the person:** Chrome in a Mac window, ⋮ ▸ New window should give a second Mac window.
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

- **ISS-23 Clipboard images may never reach the phone.** On the emulator (2026-11-03, paste-drop r2), the phone's `ShellClipboard.writeImage` failed: `clip.image.done ok=False` and no clip was set. That's the Mac → phone direction of clipboard image sync (SHARE-2), which has no end-to-end image test, so it is likely broken on real phones too. Being fixed on `fix/paste-drop` (test first, emulator proof).
  - **Cause (emulator boot 5, 2026-11-03):** the phone's helper runs as the shell user (uid 2000). The clipboard service refuses a clip whose URI points into PocketDeck's own file provider (`setPrimaryClip` threw), and the app process can't open files the helper wrote on shared storage (`share refused: cannot copy`).
  - **The same second cause probably breaks a drop's share step on `main`:** the file lands in Downloads, but the share sheet never opens.
  - **Fixed and merged 2026-11-03 (db23e133):** the helper hands the app an open file descriptor (`openStaged`), and the app serves its own copy. The app sets image clips itself (`onClipImage` / `clipImageDone`). Proven on the emulator (boot 7). Waiting on the real-phone check: copy an image on the Mac and paste it in a messaging app on the phone; drop a photo on a messaging app's window.

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

1. **Timers both ways.** A phone timer, stopwatch or alarm becomes a live countdown in the Mac menu bar with its pause/stop actions. "Start Timer…" on the Mac sets the timer in the phone's own Clock app, so it rings even when the Mac sleeps. This includes the live-notification surface for Android's ongoing cards (navigation, delivery, sports), since macOS has no Live Activity API for Mac apps.
2. **Several phones at once.** An audit and a plan come first; the session layer holds one session today.
3. **Calls and messages.** Answer or decline, place calls, and reply to texts. Starts with the notification reply path.
4. **Instant Hotspot.** One click in the menu bar turns on the phone's hotspot and joins it.
5. **Handoff, Mac to phone.** The open tab or document continues on the phone.
6. **Phone photos on the Mac.** Recent photos and screenshots in Finder or a Recents strip, with drag-out. Needs ISS-2.
7. Then: the phone as a key, Shortcuts both ways, the phone as a Mac remote, Mac-to-phone notifications, Focus modes and the Batteries widget, Wi-Fi password sharing and last-seen location.

## 6. On their own branches

These need something the public build can't assume, so they stay off `main` (AGENTS.md).

- **Wi-Fi Direct** (`feature/direct-link`): a direct Wi-Fi Aware link between the Mac and the phone, for when there's no shared LAN. It needs SIP off, the boot settings `wifiaware_allowlist=0 amfi_get_out_of_my_way=1` and private Apple API. It may never merge. `main` keeps the groundwork: one session over several paths, switching, replay and the grace (`docs/design/paths.md`). Research: `docs/research/wifi-aware-direct-link/`.
  - **ISS-22** Move the direct-only docs from `main` to the branch, as camera does: `docs/design/direct-link.md`, the DIRECT rows of `docs/specs/transport.md`, and the Wi-Fi Aware lines and `direct.key` in `docs/PROTOCOL.md` and `docs/design/paths.md`. On `main`, leave one line saying where the provider lives.
  - **Next on the branch:** the Mac helper (a root service that drives the link, with a userspace network stack), whose first gate is a throughput benchmark, since the 2026-10-30 proof only carried about 1 Mbit/s. Then the phone provider, then the integration and its setting.
- **Camera sharing** (`feature/camera`): the phone as a Mac camera. Needs a paid Apple Developer ID for the camera extension.
