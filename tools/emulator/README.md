# emulator rig — the real PocketDeck server on a local Android emulator

The test phone can be offline; this rig boots the **real** `dev.pocketdeck` server
(the Shizuku shell-process user service, uid 2000) on an Apple-silicon Android 16
emulator, so pairing, the locked-phone virtual displays, resizes and input
injection can be verified without the hardware.

Everything lives in `tools/emulator/`; the emulator is only ever addressed by its
own serial (`emulator-5554`), so a phone plugged in next to it is never touched.

## Requirements

`JAVA_HOME=/opt/homebrew/opt/openjdk@17`, `ANDROID_HOME=~/Library/Android/sdk`
(cmdline-tools present), `ffmpeg`, `python3` (3.9 is fine), and the SDK
`emulator`/`system-images;android-36;google_apis;arm64-v8a` packages that
`setup.sh` installs.

## Quick start

```sh
tools/emulator/setup.sh    # SDK packages + AVD (idempotent)
tools/emulator/start.sh    # boot, Shizuku, build+install the app, print the address
tools/emulator/flow.sh     # the core POC check, writes PNGs to .agent/emu/frames/
```

`start.sh` prints the address to use:

```
POCKETDECK_SERIAL=emulator-5554
POCKETDECK_ADDR=127.0.0.1:47811       # adb forward -> the device-side port
POCKETDECK_DEVICE_PORT=42945
```

Then the usual client works by address:

```sh
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port 47811 \
    --state tools/emulator/.cache/deckctl-state.json apps
```

Other scripts and flags: `lock.sh` (test PIN + screen off), `unlock.sh` (wake +
PIN), `start.sh --window` (visible emulator window), `start.sh --no-build`
(skip Gradle), `POCKETDECK_SETTLE` / `POCKETDECK_PHASE_SECONDS` /
`POCKETDECK_STEPS1` / `POCKETDECK_STEPS2` (flow timings and input steps),
`POCKETDECK_BROWSER` / `POCKETDECK_MESSENGER` (test apps),
`POCKETDECK_DEVICE_ID` (the rig's stable device id, default
`e0e0e0e0e0e0e0e0`), `POCKETDECK_SERIAL` / `POCKETDECK_PORT` (address).

## What start.sh does

1. Boots the AVD `pocketdeck-api36` headless (`-no-window -no-audio -no-boot-anim
   -gpu swiftshader_indirect`) and waits for `sys.boot_completed`. If a rig PIN
   is set it unlocks first: userdata (and so `run-as`) is only reachable after
   the first unlock.
2. Installs, from `tools/emulator/.cache/` (downloaded once):
   - **Shizuku** — newest release APK from its GitHub release feed;
   - **dev.pocketdeck** — `./gradlew :app:assembleDebug` + `adb install -r -g`;
   - two F-Droid test apps standing in for a browser and a messenger:
     `acr.browser.lightning` (small WebView browser, renders immediately) and
     `org.fossify.messages`. Override with `POCKETDECK_BROWSER` /
     `POCKETDECK_MESSENGER`.
   The messenger is given the SMS role (`cmd role add-role-holder`) so its
   first-run "set as default" dialog does not sit on top of the app's widgets.
3. Grants `dev.pocketdeck` the Shizuku permission and POST_NOTIFICATIONS with
   plain `pm grant`. The Shizuku permission is a *dangerous* runtime permission,
   so no dialog and no root are needed:
   `pm grant dev.pocketdeck moe.shizuku.manager.permission.API_V23`.
4. Starts the Shizuku server **after** the grant, through its documented adb
   entry point (the starter in the app's native lib dir):
   `adb shell $codePath/lib/arm64/libshizuku.so`. It runs as the adb shell user,
   so the PocketDeck user service is uid 2000, exactly like on the phone. Running
   the starter again kills any daemon left over from a previous install.
   *Order matters:* the Shizuku server snapshots each app's permission state when
   it starts, so granting the permission after it is up leaves the app stuck on
   "shizuku permission not granted" until the server restarts.
5. Seeds the app prefs with `run-as` (debug build): `enabled=true`,
   `onboarding_done=true`, a stable `device_id` (`e0e0e0e0e0e0e0e0`) and any
   existing `paired` list, then launches `MainActivity` so the foreground service
   binds the user service and starts the TCP server.
6. Keeps the rig's own screen on (`settings put system screen_off_timeout`,
   because a sleeping screen freezes the app and a frozen app never draws the
   pairing prompt — `lock.sh` still sleeps the panel explicitly).
7. Finds the server port from the kernel (`ss -ltnp`, filtered by the
   `dev.pocketdeck:pocketdeck` pid; falls back to the `PocketDeckSvc: listening on
   0.0.0.0:<port>` logcat line), sets `adb forward tcp:47811 tcp:<port>` and
   prints `127.0.0.1:47811`. The emulator sits behind NAT, so mDNS never reaches
   the Mac — connect by address. `flow.sh` re-asserts the forward every run,
   because forward rules die whenever the adb server restarts (a wireless device
   reconnecting is enough).

## Pairing in the rig

Pairing is the real flow: `pair.request` → `pair.code_shown` (with the code) and
a prompt showing the same code → someone taps **Allow** → `pair.ok`.
`flow.sh` runs it through `poc.py pair`: it reads the code from the pairing
prompt (the app dialog, or the notification — whichever appears first, ignoring
a code left over from an earlier request), checks it against the announced one, taps **Allow** over adb and writes the
key into deckctl's own state file under the same `clientId`, so every later
`deckctl` call just authenticates with `--state`.

Two things make this harder on a loaded machine, and both are handled:

- the app must be *drawing* for the prompt to exist, so `flow.sh` wakes the rig
  (`unlock.sh` — a screen that slept can report "keyguard not showing") and waits
  until `dev.pocketdeck` is the resumed activity before pairing;
- on a slow boot the prompt can take long to appear, so the real flow can time out. After two failed attempts `flow.sh` seeds a client instead
  (`poc.py seed`): it writes the same `paired` entry a real pairing stores into
  the app's prefs with `run-as`, restarts the app (which pushes it to the shell
  service) and puts the matching key in deckctl's state file. Callers cannot tell
  the difference afterwards; the README says so instead of hiding it.

To pair by hand instead: `deckctl --pair apps` (prints the announced code) with
`poc.py wait-prompt` running in the background to tap Allow.

## What flow.sh checks

- pairs if needed (above), then `lock.sh` and `dumpsys window` must show the
  keyguard up;
- `deckctl apps` must list both test apps;
- `deckctl multi --apps A B --w 1280 --h 800 --resize1 768x1280 --resize2
  1600x496 --steps … --steps2 …`: two streams in one session, each app opened on
  its own virtual display, both resized to non-16:9 shapes (the phone must send a
  new VIDEO_CONFIG plus a keyframe for each), and the last decoded frame of every
  phase written as a PNG;
- `poc.py verify-phases`: every PNG must be real app UI (mean luma) and every
  input-step phase must differ from the previous phase of the same stream.

Both the pairing and the `multi` step are retried (with a warm-up between
attempts) because a cold WebView app on a software GPU can take longer than the
first CONFIG wait; the machine may also be busy with someone else's emulator.

Input steps (per stream, over protocol frames): open the browser menu, back,
tap the address bar, type `example.com`, tap the new-message button, `wait:5`
(let the screen finish appearing), type `5551234`, scroll the list. A `wait:`
step is not judged as input; every real input step must change that stream's
frames, and the frames are saved so the effect is visible in the PNG.

Frames and raw H.264 land in `.agent/emu/frames/` (gitignored).

## Notes / limitations

- The emulator has no hardware encoder; the server's `video/avc` encoder resolves
  to the software `c2.android.avc.encoder`. Quality and latency numbers from the
  emulator say nothing about the phone.
- Everything renders through a software GPU (`swiftshader_indirect`), so a
  WebView app can miss Android's 5 s input deadline during its first layout: with
  `--settle` too small, the browser was ANR-killed on resize
  (`ANR in acr.browser.lightning … Input dispatching timed out`, then
  `Force finishing activity`). The defaults (settle 12 s, 6 s per phase) keep it
  responsive; the phone's GPU does not have this problem.
- Screenshots of windows that opt out of screen capture (an app that sets the
  secure-window flag) come out black, on the emulator as everywhere; such an app
  is not usable as a rig test app, which is why the browser stand-in is a plain
  WebView browser.
- `adb root` works on this `google_apis` (non-Play) image, but the rig
  deliberately never roots: Shizuku and the server must run as the shell user.
- `tools/emulator/.cache/` holds the downloads (Shizuku APK, F-Droid APKs, the
  seeded prefs, deckctl's state) and is gitignored.
