# macOS app — happy-path audit

Walked as a first-time user on 2026-10-12 against `tools/fakephone/fakephone.py` (port 47510,
mDNS on), with a private build of `macos/` (own bundle id and Keychain service, so no user data
was touched). Screenshots: `.agent/redesign/shots/`. Line numbers refer to the tree as read at
the start of the audit; the profile task was editing `Identity.swift`, `Session.swift`,
`App.swift` and `LauncherWindow.swift` concurrently, so lines may have shifted by a few.

Not covered:
- **Emulator rig:** it is shared with the `android-s` task (single-session server, its client was
  streaming during the walk). A second Mac session would have collided with it.
- **`--no-mdns` variant:** covered by code reading only (`--connect` path, `App.swift:189-191`).
- **Light appearance:** `-AppleInterfaceStyle Light` on the command line did not change the
  window appearance. Phase B adds an explicit `--appearance` test hook (see the redesign spec).
- **Phone-window chrome:** reviewed by code only.

Severity: **P0** breaks the happy path · **P1** a core feature is missing or misleading ·
**P2** UX/visual defect · **P3** polish.

## What works (keep)

- Stored key + remembered phone: relaunch reconnects without a code (`16-relaunch-reconnected.png`,
  `13-relaunch-t6-reconnected.png`). The user's "forgets the phone" is the Keychain wipe (profile task).
- Video path, resize (`window.resize` sent, 900×628 → 663×486 window gave 1312×912 VD), typing
  (`text`), close (`window.close`), QR payload and probe logic, wrong-device refusal.

## P0

### A01 — Dropped connections are never cancelled, so the phone's single session slot is held by zombies
- **Evidence:** `lsof -p <app>` after a phone restart showed 8 sockets to the phone's port: 7×
  `CLOSE_WAIT` and 1×`ESTABLISHED` on `127.0.0.1`. fakephone's event log for the stuck period has
  `{"ev":"session","state":"open"}` and **no `hello`**: a connection the Mac opened, abandoned, and
  never spoke on. The phone serves one session, so every later attempt gets `busy`/closed →
  "closed-by-peer" forever. Screens: `04-pairing-timeout-closed-by-peer.png`,
  `05-failed-stays-no-reconnect.png`, `06-retry-no-effect.png` (Retry does nothing),
  `15-phone-back-t12-stuck-failed.png`, `15-phone-back-t25.png` (phone is back, Mac never recovers).
- **Root cause:** `Session.fail()` (`Session.swift:266-289`) sets `connection?.stateUpdateHandler = nil;
  connection = nil` (lines 271-272) and never calls `cancel()`. The connect watchdog
  (`Session.swift:189-198`) also calls `fail("timeout")`, so a connection that completes TCP *after*
  the watchdog fired is live on the phone, has no handler, and never sends `hello`.
- **Fix direction:** one owner of the live `NWConnection`; every exit path cancels it; a connection
  that is not the current one is cancelled the moment its state handler fires. See spec §6.

### A02 — Silent infinite retry loop; UI flaps between "Connecting…" and a raw error
- **Evidence:** `04-…closed-by-peer.png`: `Connection failed: closed-by-peer (closed-by-peer)` with an empty
  list and a Retry button. This is the message the user sees constantly.
- **Root cause:**
  - `Session.fail()` schedules a restart with back-off 1/2/4/8/15 s, forever (`Session.swift:281-288`).
  - `App.handle` flips `uiState` to `.connecting` on every retry and to `.failed` on every failure
    (`App.swift:549-557`), so the user sees flashes of failure.
  - The text is the raw transport reason twice: `"Connection failed: \(errorText) (\(reason))"`
    (`LauncherWindow.swift:357-359`).
  - `.closed`/`.idle` fall back to `.discovering` (`App.swift:558-559`), which swaps the whole pane
    to the phone list.
- **Fix direction:** the UI state derives from "is a session live, and for how long has it not been"
  (spec §4), never from raw `SessionState`. Reasons are mapped to one sentence or to nothing
  (the profile task's `ConnectionFailure` does the mapping; the spec reuses it).

### A03 — Connecting through a Bonjour endpoint can hang in `waiting` with no feedback
- **Evidence:** `24-connecting-hang-no-sheet.png`: after clicking Connect on a discovered phone,
  UI shows "Connecting…" for >60 s (the hint is also clipped, see A14), `lsof` lists no socket, the phone
  logs nothing. `dns-sd -B/-L` shows the service advertised on `en0` **and on `bridge100/101/102`**
  (VM bridges on this Mac; `192.168.139.3` appeared in the socket list). The same flow worked on
  the first run, when only `en0` carried the record.
- **Root cause (probable):** `NWConnection(to: .service)` is free to pick any interface the
  record is on; `Session.tcpParameters` (`Session.swift:200-209`) sets no interface policy. On a
  Mac with VMs/VPN/Docker the endpoint resolves onto an unreachable interface and sits in `waiting`
  (the watchdog then restarts it into the same hole, A02). Users with a VPN or virtualization hit
  this in the real world.
- **Fix direction:** Bonjour endpoints connect with `prohibitedInterfaceTypes = [.loopback, .other]`;
  if the attempt is still `waiting` after 4 s, retry once with the TXT-resolved IPv4 address.
  Must be proven in Phase B on this Mac (it has the bridges).

## P1

### A04 — A paired phone vanishes from the list when it goes offline
- **Evidence:** `14-phone-gone-t3.png` / `-t15.png`: "Pixel Walk" (Paired a moment earlier) is simply gone; no
  "Offline", no explanation.
- **Root cause:** `deviceRows` lists non-discovered phones only if `cache.deviceIds` has an address
  (`App.swift:361-376`), and the cache only stores IPv4 literals taken from
  `connection.currentPath.remoteEndpoint` (`DirectConnect.swift:97,113`). For a service
  connection that is usually an interface-scoped/hostname endpoint, so nothing is cached.
  There is no record of "remembered phones" independent of the address cache.
- **Fix direction:** a `RememberedPhone` list (id, name, model, last seen) persisted with the profile;
  the UI is driven by that, addresses are an optimisation.

### A05 — Pairing code sheet has no way out, no phone name, and no error state
- **Evidence:** `02-code-sheet-empty.png`: free text field with grey "123456" placeholder (reads as a
  pre-filled value), a single **Pair** button, no Cancel, no Escape.
- **Root cause:**
  - The sheet is a bare `NSWindow` with a text field (`LauncherWindow.swift:13-20, 103-148`).
  - The title says "your phone" because `model.phone` is nil until `welcome` (`LauncherWindow.swift:49`).
  - `refresh()` ends the sheet whenever the state leaves `.awaitingCode` (`LauncherWindow.swift:337`),
    so the phone's 15 s code window turns into the failure screen of A02 instead of "Try again".
  - A wrong code is never shown: `phoneError` only sets `errorText` (`App.swift:624-626`).

### A06 — No Settings / Devices manager; "Forget" is unreachable once connected
- **Evidence:** menu bar has only *PocketDeck, View, Navigate*; `08-connected-apps.png` has no Forget.
- **Root cause:** docs/UX.md requires Settings → Devices (`UX.md` "Pairing manager"); the app has none
  (`App.swift:720-764`). Forget exists only in the phone list while `uiState == .discovering` with a row
  selected (`LauncherWindow.swift:344-347`), so a connected or failed state cannot forget, and a remembered
  but undiscovered phone cannot be selected at all (A04).

### A07 — Menu is incomplete: ⌘W / ⌘M / paste do not work
- **Evidence:** menu bar items are `Apple, PocketDeck, View, Navigate`; ⌘W on the launcher did nothing
  (window stayed open).
- **Root cause:** `buildMenu` (`App.swift:720-764`) has no File/Edit/Window menus, so close, minimize,
  copy/paste (code field, search field) and window cycling have no key equivalents.

### A08 — Closing the launcher leaves no way back except ⌘K; Dock click does nothing
- **Root cause:** `applicationShouldTerminateAfterLastWindowClosed` is false (`App.swift:713`) and
  there is no `applicationShouldHandleReopen`; there is no menu-bar item or Window menu (A07). (By code
  inspection; ⌘K "Find Apps" re-shows the window by accident, `LauncherWindow.swift:87-93`.)

### A09 — App windows stack on one spot and bury the launcher
- **Evidence:** `11-second-app-same-position.png`: Camera and Chrome open at exactly `2950,128`, both
  covering the launcher (`3010,128`). Opening a second app needs ⌘K first.
- **Root cause:** `StreamWindowController.present()` calls `window?.center()` for every window
  (`StreamWindow.swift:80-85`), no cascade and no saved frame, and activates the app.

### A10 — Discovery invents a device id when the TXT record is missing
- **Evidence:** `20-qr-after-nearby-not-paired.png` / `21-…png`: fakephone logged `auth_ok` for the
  QR key, the Mac stayed on the list and shows "Pixel Walk · Nearby" (no model, id = name).
- **Root cause:** `deviceId: txt["id"] ?? name` (`Discovery.swift:63`): a result without TXT (results
  per interface arrive without metadata first) gets the *service name* as id. `finishQRPairing` then looks
  up `phones.first { $0.deviceId == id }` (`App.swift:514`), finds nothing and never connects.
- **Fix direction:** ignore results until a TXT `id` is present; coalesce results across interfaces by id.

### A11 — Relaunch flashes the phone list before reconnecting
- **Evidence:** `13-relaunch-t1-list-flash.png` (list with "Paired" row for ~1–2 s) → `13-relaunch-t6-…` (grid).
- **Root cause:** the Deck starts in `.discovering` (`App.swift:193`), which shows the list; the silent
  reconnect begins only after the first discovery callback or the 3 s grace
  (`App.swift:277-284`, `DirectConnect.swift` `discoveryGrace`).

## P2

### A12 — The list is a stock bezel table with raw ids and no primary action
`01-first-launch-list.png`: subtitle `FakePhone · b21cd9cc8029332a · Nearby` (`LauncherWindow.swift:462`),
status "Nearby" is meaningless, **Connect** is disabled until a row is selected, the real action is
double-click. No Pair button per row, no empty/searching state beyond hint text. Phone shown
while a pairing exists elsewhere ("PocketDeck Emulator", the user's SM-S936B) is indistinguishable from
the one the user wants.

### A13 — QR sheet: no countdown, no success state, probes every phone it can see
`18-qr-sheet.png`: status line "Waiting for the scan… (3 phones found)" (`LauncherWindow.swift:74-76`).
No expiry countdown (payload has `remaining()`, `QRPairing.swift:46`), no success state (the sheet just
disappears), and `qrRound` opens a probe session to *every* discovered phone every 2 s
(`App.swift:458-482`), including a phone the user does not own or one that is busy with another Mac.

### A14 — Visual: no glass, no hierarchy, clipped copy
Flat dark-grey `NSWindow`, stock `NSTableView` with bezel border, emoji lock (`LauncherWindow.swift:396`),
four loose bordered buttons laid out by hand (`LauncherWindow.swift:316-319`), 780×600 window with no
titlebar integration (`LauncherWindow.swift:36-41`). The "Connecting…" hint sits under the table and
is clipped by it (`LauncherWindow.swift:315` vs `:314`), so the screen looks blank. docs/DESIGN.md is
not implemented. Light appearance is untested.

### A15 — The connected header says nothing about the phone
`08-connected-apps.png`: no phone name, no connection indicator; only `🔒 Locked · 87%`. A dropped
connection replaces the whole grid with the failure pane (A02), including with windows open.

### A16 — Windows keep streaming controls after the link drops, with no signal
By code inspection: `WindowManager.handle(.ready(isReconnect))` re-opens windows
(`WindowManager.swift:137-139`), but a stream window shows its last frame with no indication that it
is stale while the link is down.

## P3

- **A17** App windows have an opaque titlebar and no app icon in the title (`StreamWindow.swift:21-25`).
- **A18** Phone-mode hover chrome is a hand-drawn dark layer 220×44 (`PhoneWindow.swift:65-83`), not glass.
- **A19** `auth_failed` and `.closed` both return to `.discovering` (`App.swift:626,558`), so "Pair again" never
  appears for a phone whose key the phone rejected (`App.swift:367` handles only the cached-address case).
- **A20** Hint copy: "Looking for PocketDeck phones on your network…", "Select a phone and press Connect." —
  procedural, not state-driven.

## Out of scope here (other tasks), listed so the redesign does not rebuild them

- **Keychain wipe:** a hard-coded service `dev.pocketdeck.mac` (`Identity.swift:38`), `--reset-pairing`
  and the e2e `clean()` deleting every item, and the "only key in the Keychain" fallback in
  `candidateKey` (`Identity.swift:77-79`). The profile task replaces these; the redesign consumes
  its `Profile`.
- **15 s code window:** phone-side. The Mac must handle the close gracefully (spec §4.3).

## Phase B re-walk

Walked again on 2026-10-13 against fakephone (port 47510, mDNS on) with a release bundle of the redesigned app
(profile `redesign`). Screenshots: `.agent/redesign/shots/rewalk/`, plus the light/dark set in `.agent/redesign/shots/final/`.

| Step | Result | Evidence |
|---|---|---|
| First launch | Welcome card, traffic lights, one primary button | `final/*/welcome.png`, `rewalk/01-first-launch.png` |
| Find phone → pair (code) | Nearby row (name + model, no ids) → code sheet titled with the phone's name, Cancel visible → connected | `rewalk/02-nearby.png`, `03-code-sheet.png`, `04-connected.png` |
| Pair (QR) | e2e `qr` check: sheet up, probe authenticates, stored key reconnects (68/68 pass) | `scripts/check-e2e.sh qr` |
| App list, open 2 apps | Cascade at 28 pt steps, Deck stays visible (A09) | `rewalk/05-app-window.png` |
| Resize | Clean video after resize on the release build (a debug build drops frames and corrupts) | `rewalk/06-resized.png` |
| Type / scroll / close | Input frames reach the phone; ⌘W closes (A07) | fakephone events |
| Quit → relaunch | Phone mode with the cached grid and "Connected" within 1.5 s, no list flash (A11) | `rewalk/07-relaunch-t1.png` |
| Phone away | Chip "Offline" and one banner "Can't reach Pixel Walk…" with **Try now** after 15 s; grid dimmed, not replaced (A02) | `rewalk/08-phone-gone-t17.png` |
| Phone back | Reconnected silently, banner gone, no click (A01) | `rewalk/09-phone-back-t9.png` |
| Forget | Settings → Devices → Forget → confirmation → Nearby (A06) | `rewalk/10…13` |
| Pair again | Nearby → code → connected | `rewalk/14-paired-again.png` |

No bug found on the happy path in this walk. Not covered: **the emulator rig** — `emulator-5554` has Shizuku stopped ("Shizuku not running" on the phone app),
so there is no PocketDeck server to talk to; restarting it means `start.sh`, which rebuilds and installs Android (out of scope). The `--no-mdns`/`--connect` path is
covered by `check-e2e.sh all`.

Issues found while re-walking and fixed in the same pass: the Bonjour connection was stuck for a same-host service (see A03 below), the search field
lost focus after the pairing sheet closed on some runs (⌘K always focuses it), ⌘P was shadowed by the default Print item,
the Forget button was not red, "Last seen" showed seconds-ago for a connected phone, and a window opened by a build whose Keychain items were created by
another binary blocks on the system Keychain prompt (see "Known risk").

### A03 follow-up (what actually fixed it)
Prohibiting interface types was wrong for a same-host fake phone (its only reachable interface is a VM bridge). The attempt is now **pinned to the interface the browser found the
service on** (Wi-Fi/Ethernet ranked first), and the next attempt after a failure is unpinned, alternating until one gets through; a remembered IPv4 address is the next fallback.
The cache now stores the address of service connections too (the scoped `192.168.1.74%en0` literal is stripped), so a remembered phone has an address after its first session (A04).

### Known risk (not fixed here)
Release builds are ad-hoc signed; a binary that did not create a Keychain item makes macOS show a blocking "wants to use confidential information"
dialog, and the app waits behind it. The e2e harness avoids it with its own profile, and a developer reinstalling over their own copy hits it once. A stable signing identity
fixes it; out of scope.
