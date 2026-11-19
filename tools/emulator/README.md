# emulator rig — the real Contigua server on a local Android emulator

The test phone can be offline; this rig boots the **real** `app.contigua` server
(the Shizuku shell-process user service, uid 2000) on an Apple-silicon Android 16
emulator, so pairing, the locked-phone virtual displays, resizes and input
injection can be verified without the hardware.

Everything lives in `tools/emulator/`; the emulator is only ever addressed by its
own serial (`emulator-5554`), so a phone plugged in next to it is never touched.

## Requirements

`JAVA_HOME=/opt/homebrew/opt/openjdk@17`, `ANDROID_HOME=~/Library/Android/sdk`
(cmdline-tools present), `ffmpeg`, and a `python3` with TLS 1.3 (3.11+ /
OpenSSL 3; `lib.sh` tries `/opt/homebrew/bin/python3`, override with
`CONTIGUA_PYTHON` — the macOS 3.9 cannot do the v2 handshake), and the SDK
`emulator`/`system-images;android-36;google_apis;arm64-v8a` packages that
`setup.sh` installs.

## Quick start

```sh
tools/emulator/setup.sh    # SDK packages + AVD (idempotent)
tools/emulator/start.sh    # boot, Shizuku, build+install the app, print the address
tools/emulator/flow.sh     # the core POC check, writes PNGs to .work/emu/frames/
```

`start.sh` prints the address to use:

```
CONTIGUA_SERIAL=emulator-5554
CONTIGUA_ADDR=127.0.0.1:47811       # adb forward -> the device-side port
CONTIGUA_DEVICE_PORT=42945
```

Then the usual client works by address:

```sh
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port 47811 \
    --state tools/emulator/.cache/deckctl-state.json apps
```

Other scripts and flags: `lock.sh` (test PIN + screen off), `unlock.sh` (wake +
PIN), `start.sh --window` (visible emulator window), `start.sh --no-build`
(skip Gradle), `CONTIGUA_SETTLE` / `CONTIGUA_PHASE_SECONDS` /
`CONTIGUA_STEPS1` / `CONTIGUA_STEPS2` (flow timings and input steps),
`CONTIGUA_BROWSER` / `CONTIGUA_MESSENGER` (test apps),
`CONTIGUA_DEVICE_ID` (the rig's stable device id, default
`e0e0e0e0e0e0e0e0`), `CONTIGUA_SERIAL` / `CONTIGUA_PORT` (address).

### One boot, all the checks

```sh
bash tools/emulator/preflight.sh              # no device: syntax, APK, manifest, budget
bash tools/emulator/lib-test.sh               # no device: the shared helpers on fixtures
bash tools/emulator/verify-batch.sh --check   # the rehearsal of the boot command
timeout 1800 bash tools/emulator/verify-batch.sh
```

`verify-batch.sh` boots once, pairs once, then runs six sections that do not
depend on each other — the paired row, media part 2, screen off/wake, secure
screens, the music volume, and `apps.icon` at 216 and 1296 px — and kills the
emulator at the end, whatever happened. Its result is one line per section in
`.work/emu/verify-batch.log`:

```
SECTION media PASS 12 checks: sessions: 2 1 s2 s1,s2 art: ... w=512 h=512 ...
SECTION phone-screen PASS 8 checks: screen-off: state screen=off locked=True ...
SECTION volume PASS volume: the first state names 6/15;phone.volume 12 answered with 12/15 ...
SECTION icons PASS apps=3 px=216,1296 flat=144,864 layers=3/3 max_ms=693
```

`media.sh` and `phone-screen.sh` still run alone (`--no-boot` reuses a rig that
is already up and paired).

### direct-p1: the one-boot path proof

```sh
bash tools/emulator/p1-proof.sh --check
timeout 2700 bash tools/emulator/p1-proof.sh
```

`p1-proof.sh` is the direct-p1 item-7 proof of the **real** shell server (not
fakephone): it boots once, pairs the Mac app through the real prompt, founds a
session on two providers, proves the second path joined (no supersede), drops
32 MiB through a path black-holed at 8 MiB and checks the device-side sha256,
refuses a v3-shaped hello with `v=4`, and waits out the 30 s grace (the Mac's
`orphaned --grace--> ended`, the phone's slot free, the panel restored). The
apk must already be built (`start.sh --no-build` installs it). `--check` is the
rehearsal: `preflight.sh`, the stale APK/Mac app checks and the tools, with no
device and no boot. Results and the table go to
`.work/direct-link/p1-emulator.md`; the per-phase logs are under
`/tmp/pd-direct-p1-emu/` (copy them before another `--check`). The boot budget
is in `.work/budgets/<worktree>` and the ledger is
`/tmp/contigua-boots.ledger`; one boot per run, `adb -s emulator-5554 emu
kill` only.

### vd-group: window displays in a group of their own

```sh
bash tools/emulator/start.sh          # once: boot, install, launch
bash tools/emulator/vd-group.sh       # the checks, on the running rig
```

It opens windows on the default route (a virtual device), with
`debug.contigua.vd_plain=1` (a plain `OWN_DISPLAY_GROUP` display) and with
`debug.contigua.vd_panel_group=1` (a display in group 0, which must be
refused), opens two windows on one device, and opens one on a locked,
screen-off rig: its display draws while display 0 stays off. The lines are
`ok [WIN-74]`, `ok [WIN-75]` and `ok [CTRL-14]`, in `.work/emu/vd-group.log`.

### Reliability rules (each one cost a boot once)

- **Run every script as `bash <script>`.** Do not rely on the exec bit: a fresh
  clone that loses it fails with `Permission denied` after the emulator is up.
  The scripts call each other through `bash` too.
- **Install with `adb install -r -d`, never uninstall.** Another worktree may
  have left a higher versionCode on the AVD. `start.sh` then reads the installed
  versionCode (`dumpsys package`) and the APK's (`aapt2 dump badging`) and stops
  with one line if they differ, instead of testing a stale build.
- **Name the component in every debug broadcast** (`am broadcast -n
  app.contigua/app.contigua.app.MediaDebugTrigger`). An implicit broadcast
  is dropped while the app is in the background, and nothing says so.
- **Wait for the shell service's listening port, then retry it.** The first
  launch after a boot sometimes leaves the Shizuku user service without a socket;
  `start.sh` restarts it up to three times, logging each try, and fails with the
  service's own logcat lines.
- **`preflight.sh` runs first in every `--check`.** It checks what no device can
  show: `bash -n` on every rig script, the APK's versionCode against the build
  file, every component the scripts name against the APK's merged manifest,
  deckctl's subcommands (parser and handler) and TLS 1.3, and the boot budget in
  `.work/budgets/<worktree>` against `/tmp/contigua-boots.ledger`.

## What start.sh does

1. Boots the AVD `contigua-api36` headless (`-no-window -no-audio -no-boot-anim
   -gpu swiftshader_indirect`) and waits for `sys.boot_completed`. If a rig PIN
   is set it unlocks first: userdata (and so `run-as`) is only reachable after
   the first unlock.
2. Installs, from `~/.cache/contigua-emulator/` (`$CONTIGUA_FIXTURES`; downloaded once and shared by every checkout, so a new worktree needs no network):
   - **Shizuku** — newest release APK from its GitHub release feed;
   - **app.contigua** — `./gradlew :app:assembleDebug` + `adb install -r -d -g`,
     where the installed versionCode must then equal the APK's;
   - two F-Droid test apps standing in for a browser and a messenger:
     `acr.browser.lightning` (small WebView browser, renders immediately) and
     `org.fossify.messages`. Override with `CONTIGUA_BROWSER` /
     `CONTIGUA_MESSENGER`.
   The messenger is given the SMS role (`cmd role add-role-holder`) so its
   first-run "set as default" dialog does not sit on top of the app's widgets.
3. Grants `app.contigua` the Shizuku permission and POST_NOTIFICATIONS with
   plain `pm grant`. The Shizuku permission is a *dangerous* runtime permission,
   so no dialog and no root are needed:
   `pm grant app.contigua moe.shizuku.manager.permission.API_V23`.
4. Starts the Shizuku server **after** the grant, through its documented adb
   entry point (the starter in the app's native lib dir):
   `adb shell $codePath/lib/arm64/libshizuku.so`. It runs as the adb shell user,
   so the Contigua user service is uid 2000, exactly like on the phone. Running
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
   `app.contigua:contigua` pid; falls back to the `ContiguaSvc: listening on
   0.0.0.0:<port>` logcat line). If nothing listens within 60 s it restarts the
   shell service (up to three times, one log line each) and then fails with the
   service's own logcat lines; a first launch that never binds is a known flake,
   not a product bug. It sets `adb forward tcp:47811 tcp:<port>` and
   prints `127.0.0.1:47811`. The emulator sits behind NAT, so mDNS never reaches
   the Mac — connect by address. `flow.sh` re-asserts the forward every run,
   because forward rules die whenever the adb server restarts (a wireless device
   reconnecting is enough).

## Pairing in the rig

Pairing is the real flow: `pair.request` → commit/nonce/reveal → the phone shows
a 6-digit code in its prompt → someone taps **Allow** → `pair.ok`, which carries
both pins. `flow.sh` runs it through `poc.py pair`, which imports deckctl's v2
TLS client rather than speaking the protocol itself (pins are facts from the
handshake certificates, never hello self-reports): it reads the code from the
pairing prompt (the app dialog, or the notification — whichever appears first,
ignoring a code left over from an earlier request), taps **Allow** over adb and
lets deckctl store the pin in its own state file under the same `clientId`, so
every later `deckctl` call just authenticates with `--state`.
The two codes are not compared on the Mac side: deckctl is a stdlib TLS client
and cannot reach the exporter, so only the person comparing the phone and the
Mac screen verifies the digits; the commit/reveal exchange authenticates the
pins.

Two things make this harder on a loaded machine, and both are handled:

- the app must be *drawing* for the prompt to exist, so `flow.sh` wakes the rig
  (`unlock.sh` — a screen that slept can report "keyguard not showing") and waits
  until `app.contigua` is the resumed activity before pairing;
- on a slow boot the prompt can take long to appear, so the real flow can time
  out. After two failed attempts `flow.sh` stops with an error; re-run it (or
  pair by hand, below) once the rig is awake.

To pair by hand instead: `deckctl --pair apps` (prints the advisory code) with
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

Frames and raw H.264 land in `.work/emu/frames/` (gitignored).

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
- `tools/emulator/.cache/` holds one checkout's run state (the seeded prefs,
  deckctl's state) and is gitignored. The downloads (Shizuku APK, F-Droid
  APKs) live in the shared `~/.cache/contigua-emulator/`.
- The first device run of the media section (2026-10-20) delivered its three
  debug broadcasts and got no media messages back at all, so media control on a
  real listener is still unverified (docs/design/notify.md says what is open).
  The section now records which probe it gets to — enabled listener, logcat
  lines, the session's last output — so a failing boot names the cause instead
  of going silent.
- fakephone's TLS server needs pyOpenSSL in its interpreter; this Mac's
  interpreters do not have it, so the icon dry run in `verify-batch.sh --check`
  drives fakephone's own icon renderer through a stub instead of a socket.
