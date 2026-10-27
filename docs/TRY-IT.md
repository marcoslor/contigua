# Try PocketDeck: Android apps in Mac windows, phone locked

Same Wi-Fi; Shizuku running on the phone, PocketDeck running and "Allow connections" on.

```bash
# phone (USB or wireless debugging)
cd android && export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :app:assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk
# Mac: build a release copy and install it to /Applications (quits a running copy first).
cd macos && ./scripts/install.sh && open /Applications/PocketDeck.app
# Phone files in Finder (opt-in): the same install with the File Provider extension; the
# installer registers the installed copy and its extension.
cd macos && ./scripts/install.sh --with-files && open /Applications/PocketDeck.app
```

0. **Upgrading from a plaintext build? Pair once more.** Sessions are now TLS 1.3
   with pinned keys (protocol v2), so the old plaintext pairing does not carry
   over: the first connection after the update asks for a fresh pair (the
   phone's "This Mac's certificate changed; pair again" or the Mac's "This
   phone's identity changed. Pair again."). Code and QR pairing both work;
   after that, reconnects are silent as before.
1. Phone: PocketDeck → **Pair new Mac** (first run: onboarding → **Scan QR code**).
2. Mac: **Pair with QR** → point the phone at the sheet (the phone's camera app
   works too — the link opens PocketDeck). The sheet closes itself when paired
   and the Mac shows the app list; the QR key expires after 5 minutes.
3. Lock the phone. It never needs to be unlocked.
4. Mac: double-click an app (or ⌘K → type → ↩). Each app gets its own window.
5. Resize any window freely — tall, square, ultra-wide, or drag while the app
   runs. The app re-lays out to the new shape.
6. Type into the focused window, click/drag, scroll the wheel. Right-click =
   Android back, middle-click = home, and the mouse's side **Back** button =
   Android back too — exactly one per press, like the header's Back button
   (nothing while it is held, nothing on release, never a touch); **Forward**
   does nothing yet. Click a window first if keys seem ignored.
   On a trackpad, two-finger scroll drags the page like a finger (with fling),
   pinch and rotate are two fingers around the pointer. Windows are just the
   app: move the pointer to the top edge and a glass header with the traffic
   lights appears above the stream (drag it to move the window; the stream's
   edges resize it); it goes as soon as you leave. In the phone window it also has Back · Home · Recents.
7. Closing a window closes the app's virtual display; relaunching the Mac app
   reconnects silently to the last phone.
8. Send a link to the phone: in Safari, Chrome, Notes or any app, **Share → Open on
   Phone** (also: right-click → Services → Open on Phone, or drop a link on the Deck). It
   opens in its Android app (Maps, YouTube, the browser…) in a new window; with several
   phones PocketDeck asks which. If "Open on Phone" isn't in the Share menu, turn it on in
   System Settings → General → Login Items & Extensions → Sharing.
9. Install an Android app: drop an `.apk` (or an `.apks` / `.xapk` split bundle) on the Deck,
   or use the menu bar's **Install APK…** (also: Finder → Open With → PocketDeck, or
   right-click → Services → Install on Phone). The Deck shows the progress and the result
   ("Installed Example 1.2", or why the phone refused it).
10. Send something from the phone to the Mac: in any Android app, **Share → Send to Mac**.
   A link opens in the Mac's default browser; other text goes on the Mac clipboard
   ("Copied from <phone>"); an image (one or several, up to 50 MB each) is saved to
   `~/Downloads/PocketDeck/` and put on the clipboard, with a "Show in Finder" notification.
   Select text (or long-press a link) → **Open on Mac** in the text menu does the same; when an
   app offers a choice of browsers for a link, **Open on Mac** opens it on the Mac.
   With no Mac connected the phone says "No Mac connected".
11. Give a phone app its own Mac app: in the Deck, right-click it → **Add to Dock**. "WhatsApp
   (Phone)" appears in the Dock with the app's icon (Options → Keep in Dock to pin it), in
   Launchpad, Spotlight and ⌘-Tab (it lives in `~/Applications/PocketDeck Apps/`). Launching it
   opens that app's window, or brings it forward; quitting it closes the window. Right-click →
   **Remove from Dock App** removes it; uninstalling the app on the phone or forgetting the phone
   removes it too.
12. Audio phone → Mac: with a window open, PocketDeck captures the phone's media/game audio
   (REMOTE_SUBMIX, via Shizuku at shell UID) and plays it on the Mac through AVAudioEngine (Opus
   or AAC, 20 ms frames) with the per-device volume slider and mute in the menu bar. Media apps
   playing on the phone are silenced on the phone speaker; added latency is under 150 ms. Try it
   by opening a music or video app in a PocketDeck window and playing something.

## No phone? Use the emulator rig

`tools/emulator/` boots the real server on a local Android 16 emulator (the
Shizuku shell service, uid 2000) and runs the same steps — pair, lock, list apps,
two windows, non-16:9 resizes, input — while saving the last decoded frame of
each phase as a PNG. It talks to the phone by address (`adb forward`), never over
mDNS, and pins `emulator-5554` so a real phone stays untouched.

```bash
bash tools/emulator/setup.sh        # SDK packages + AVD (idempotent)
bash tools/emulator/preflight.sh    # no device: syntax, APK, manifest, budget
bash tools/emulator/verify-batch.sh --check   # rehearse the boot command
bash tools/emulator/start.sh        # boot, Shizuku, build+install, 127.0.0.1:47811
bash tools/emulator/flow.sh         # the POC check; frames in .agent/emu/frames/
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port 47811 \
    --state tools/emulator/.cache/deckctl-state.json apps
```

Run every script as `bash <script>`: the rig does not rely on exec bits, and one
missing bit used to cost a whole boot. A boot is expensive, so rehearse it:
`verify-batch.sh --check` runs preflight (syntax, the APK's versionCode and
merged manifest, deckctl's subcommands, the boot budget) plus every section's
dry run without starting anything. The boot itself is one call, because the
emulator holds the machine-wide heavy lock for its whole life:

```sh
~/dev/pocketdeck/.agent/heavy.sh timeout 1800 bash tools/emulator/verify-batch.sh
```

That boots once and runs media control, screen off/wake and the icon renders in
one go, then kills the emulator. The reliability rules learnt the hard way
(explicit broadcast components, `-d` installs with a versionCode check, the
shell-service retry) are in `tools/emulator/README.md`.

Details (pairing without a camera, port discovery, timings, what fails on a
loaded machine) are in `tools/emulator/README.md`.

## Running the e2e checks while you work

`macos/scripts/check-e2e.sh <check|all>` drives a test copy of the app against
the fakephone. By default the run is quiet, so you can keep typing in another app:

- the app runs with `--background` (only with a test profile, never the default
  one): no Dock icon or ⌘-Tab entry, it never becomes the frontmost app, and its
  per-app Dock apps are agents launched in the background;
- its windows open on a virtual display of its own (about the size of your main
  display, placed so it touches it only at the bottom-right corner, gone when the
  app quits), so nothing appears on your screens and the streams keep running;
- clicks, keys and side buttons are delivered inside the app, never by moving
  your pointer.

`scripts/quiet-watch.swift` watches the whole run and the summary ends with
`QUIET focus_changes=N pointer_moves=N visible_windows=N dock_icons=N`; any
non-zero count fails the run. The few steps that need real input through the
window server print `SKIP … (needs real input; PD_E2E_VISIBLE=1 runs it)`.
`PD_E2E_VISIBLE=1` runs everything visibly, as a normal foreground app with real
pointer events (for debugging; don't type meanwhile).

Each virtual display macOS sees also leaves a ColorSync display profile behind,
one per run, and nothing removes it. `macos/scripts/clean-ghost-displays.sh`
lists them and, with `--apply` (as an administrator: the folder is root-owned),
deletes only files named after the rig's displays whose display is not online
now; every other profile is left alone.

## Running the suite in a VM

`macos/scripts/vm-e2e.sh <check>` runs the same suite inside a headless
macOS VM on this Mac, so the run cannot touch your session at all: the VM has
no window of its own, and its displays, focus and input are its own. Nothing
has to be typed during the run, so the VM runs `PD_E2E_VISIBLE=1` by default
and the real-input checks (global events, side button, `open -a`) run too
(`PD_VM_VISIBLE=0` for a quiet run instead). A comma list
(`vm-e2e.sh pair,chrome,mirror,dock`) runs those checks one after another in a
single boot, each with its own log, PASS/FAIL and `passed=`/`failed=` lines; a
boot is the expensive part, and each check is its own process either way.

The VM is `pd-e2e`: a clone of `ghcr.io/cirruslabs/macos-tahoe-base:latest`
with 2 CPUs, 4 GB RAM (the smallest this image accepts) and a 1920x1200 pt
display setting. `macos/scripts/vm-prepare.sh` creates it (add `--fresh` to re-clone)
and installs what the suite needs inside: Homebrew python3
with pyOpenSSL (TLS 1.3 for the fakephone) and ffmpeg (video checks), the ssh
key from `~/.tart/pd-e2e` and the TCC grants `screencapture` and CGEvents need.
The image already brings the rest — Command Line Tools (the suite compiles its
small helpers in the guest), an auto-login console session and SIP off, which
is what allows the TCC rows. `vm-prepare.sh` ends with a check per piece
(console session, swiftc, ffmpeg, python/pyOpenSSL, a real
`screencapture`) and writes a marker, so a prepared VM is a verified one. It
takes a few minutes and is worth re-running after changing what the suite needs.
The suite runs under `/bin/bash` in the guest, the same shell the host uses, so
the VM reproduces the host's behaviour instead of hiding a difference. The
guest's toolchain is Command Line Tools only, so the one step that needs the
XCTest runner (C12's Spotlight unit tests) prints `SKIP` with that reason
instead of failing; the check also tests for the runner itself, so a host run
never skips it.

A visible run puts the app on the guest's own screen, and AppKit clamps a
window to that screen's visible frame: C6's tall window needs 900 pt of stream
plus the 52 pt header band. The VM boots headless, so the guest keeps the
resolution it last had (tart's `--display` hint sizes a host window a headless
run never opens); `vm-e2e.sh` runs `scripts/pd-screens.swift` in the guest
before the checks, which picks the tallest 2x mode the guest offers (the checks
are written against 2x) and logs the screen. The guest's small display has no
2x mode with the 952 pt of visible height the tall window needs, so that one
step prints `SKIP` there (`PD_E2E_TALL_SCREEN=0`); a host run always runs it.
`pd-screens` prints the screen and its modes when run by hand in the guest;
nothing on the host calls it, since there it would resize the person's own
screen.

`vm-e2e.sh` builds `build/e2e/PocketDeck.app` on the host, boots the VM
headless, copies the tree, the bundle and `tools/fakephone` in, runs the check
in the VM's console session, copies the log and the run's work dir back to
`macos/build/vm-e2e/<check>/` (`run.log`, `work/`) and stops the VM; a list
lands in `macos/build/vm-e2e/<check+check...>/checks/<check>/` (`run.log`,
`work/`). The whole boot-run-stop is one heavy step: it takes the same
machine-wide lock as a host run (`.agent/heavy.sh`), so it never runs beside
other heavy work. Before that it waits for room for the VM (at least 25% free
memory, swap under 2 GB); a boot/stop cycle pushes swap up for a while, so
back-to-back runs can wait a few minutes between them. The exit code is the
check's (a list's is the number of checks that failed).

Known VM-only failures (second `all` in the VM, 2026-10-19: 254 passed, 5
failed; none of them fail on the host): C15 fingerscroll's refresh-apart gap
(VM timing), and a cascade where the shared session goes offline after phone
mode (C11's nav home/recents, then the audio and drop opens answer "not
online"); the cascade does not show every boot. `PD_VM_FAKE_DEBUG=1 vm-e2e.sh`
keeps the guest fakephone's session diagnostics in `fake.err` for the next
time it does. C12's Spotlight unit tests and C6's tall shape print `SKIP` in
the VM, with the reason.

## Known limitations (SM-S936B, Android 16)

- This Samsung build puts the virtual display in the panel's display group, so
  the server powers the physical panel off (SurfaceFlinger) while a window
  streams: the locked phone shows nothing, frames keep arriving and input
  works. Closing the last window restores the panel and puts the phone back to
  sleep. While the fallback holds, the platform still counts the screen as on
  (the panel is dark, not asleep), and pressing the power button hands the phone
  back to normal Android behaviour until the screen has been off again.
- Chrome stable (`com.android.chrome`) is disabled for user 0 by the vendor;
  use **Chrome Dev** (`com.chrome.dev`) from the app list.
- After ~20 min with no stream the phone can stop answering mDNS while fully
  dozing; wake its screen once and the Mac finds it again.
- One Mac at a time (a second session gets "busy").
- Windows wider/taller than 2560 px of virtual display are scaled down (aspect
  kept), which lowers the density instead of letterboxing.
- Mutual TLS 1.3 on the LAN, both certificates pinned at pairing
  (docs/PROTOCOL.md, docs/design/e2ee.md).
