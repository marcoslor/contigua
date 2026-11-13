# Try Contigua: Android apps in Mac windows, phone locked

This guide builds both halves from source and gets you to a first window. There
are no binaries yet. You need a Mac, an Android phone on the same Wi-Fi, and
about an hour for the first build.

The steps, in order:

1. Prerequisites
2. Clone
3. Build and install the phone app
4. Start Shizuku
5. Build and run the Mac app
6. Pair
7. Open your first window
8. Optional: the emulator rig (no phone needed)
9. Optional: the e2e checks
10. Optional: the suite in a VM

Then: troubleshooting and known limitations.

## 1. Prerequisites

What you need to have before you start. The versions come from
`android/app/build.gradle.kts`, `macos/Package.swift` and
`docs/CONTRIBUTING.md`.

| Need | Version | Why |
| --- | --- | --- |
| macOS | 26 or later | The deployment target in `macos/Package.swift` is `macOS("26.0")`. Earlier releases are untested. |
| Xcode | The release that ships Swift 6.4 and the macOS 27 SDK (`docs/CONTRIBUTING.md`) | `macos/scripts/bundle.sh` calls `swift`, `swiftc`, `xcodebuild -version`, `xcrun --sdk macosx` and the App Intents tool inside Xcode's toolchain. Command Line Tools alone are not enough for the app build. |
| JDK | 17 | `compileOptions` and `jvmTarget` are 17. |
| Android SDK | Platform 36, build-tools 36.0.0, platform-tools (for `adb`) | `compileSdk = 36`; `tools/emulator/lib.sh` uses `build-tools/36.0.0/aapt2`. |
| Gradle | Nothing to install | `android/gradlew` downloads Gradle 8.11.1 on first run. |
| Phone | Android 11 or later (API 30, `minSdk`) | Tested on Android 16 only. |
| Python | 3.11 or later, built on OpenSSL 3 | Only for the fake phone, the e2e checks and the emulator rig. The macOS system `python3` (3.9, LibreSSL) cannot do TLS 1.3 (`macos/scripts/check-e2e.sh`, `tools/fakephone/README.md`). |
| ffmpeg | Any current Homebrew build | Only for the e2e checks and the emulator rig. |

You do not need:

- An Apple Developer ID or a paid Apple account. You sign the app with a
  certificate you make on your own Mac (step 5).
- Root on the phone. The phone side runs inside Shizuku, which you start
  without root (step 4).
- To unlock the phone. It stays locked while you use it.
- Docker, a VM or an emulator, unless you choose the optional steps.

Install what is missing. Homebrew is the normal route for the command-line
tools (install Homebrew from <https://brew.sh> first):

```bash
# Xcode: install it from the App Store (or developer.apple.com), open it once,
# then point the command-line tools at it:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -version && swift --version     # Swift 6.4 or later

brew install openjdk@17                    # JDK 17
brew install python@3.12 ffmpeg            # only for the optional steps 8 to 10
adb version || brew install --cask android-platform-tools
```

Then the Android SDK. The scripts look for it in `~/Library/Android/sdk`
(that is also where Android Studio puts it). Android Studio is the easy way:
install it, open it once, and in SDK Manager tick "Android SDK Platform 36",
"Android SDK Build-Tools 36.0.0", "Android SDK Platform-Tools" and
"Android SDK Command-line Tools (latest)". Without Android Studio, download
the "command line tools only" zip from <https://developer.android.com/studio>,
unpack it to `~/Library/Android/sdk/cmdline-tools/latest/`, and run:

```bash
export JAVA_HOME="$(brew --prefix openjdk@17)"
export ANDROID_HOME="$HOME/Library/Android/sdk"
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses
"$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" \
    "platform-tools" "platforms;android-36" "build-tools;36.0.0"
```

Put `adb` on your PATH (skip if you installed it with Homebrew above):

```bash
export PATH="$ANDROID_HOME/platform-tools:$PATH"
```

Every build command below assumes these two variables are set in the same
terminal. `tools/emulator/*.sh` default to the same values when they are unset:

```bash
export JAVA_HOME="$(brew --prefix openjdk@17)"
export ANDROID_HOME="$HOME/Library/Android/sdk"
```

On the phone, turn on Developer options (Settings, About phone, tap Build
number seven times). You need USB debugging or Wireless debugging in there.

## 2. Clone

```bash
git clone https://github.com/marcoslor/contigua.git contigua
cd contigua
```

Use the clone URL of the repository you are reading this in. All commands
below run from the clone's top folder unless a `cd` says otherwise.

## 3. Build and install the phone app

Connect the phone with USB, or pair it for wireless debugging
(`adb pair <ip>:<port>`, then `adb connect <ip>:<port>`). Check `adb devices`
shows it as `device`, then:

```bash
cd android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
cd ..
```

The package is `app.contigua`. With more than one device attached, add
`-s <serial>` to `adb`.

Installing a new build over an old one does not restart the phone's running
server (the old process keeps the deleted APK and the Mac then times out).
For every install after the first, use the helper, which installs, restarts the
service and checks that the new process runs the new APK:

```bash
tools/phone_install.sh android/app/build/outputs/apk/debug/app-debug.apk [serial]
```

Open Contigua on the phone once. The first run is an onboarding with four
steps: Welcome, Start Shizuku, Allow notifications (needed for pairing prompts;
it also offers **Keep running in the background**), and Pair your Mac. Each
step moves on by itself when its condition is true. Do step 4 when it reaches
the Shizuku page.

## 4. Start Shizuku

Contigua's phone server runs as the adb shell user inside Shizuku's process.
You need Shizuku installed and running, and you need to allow Contigua to use
it. You do not need root.

1. In Contigua's onboarding, the Shizuku page shows its state: **Not
   installed** (button **Get Shizuku**), **Not running** (button **Open
   Shizuku**, with a three-line "How to start it"), **Permission needed**
   (button **Allow**) and **Ready**. Install Shizuku with the button, or from
   <https://shizuku.rikka.app/>.
2. Start Shizuku without root, by one of the two routes in Shizuku's own guide,
   <https://shizuku.rikka.app/guide/setup/>:
   - On the phone, with Wireless debugging (Android 11 or later): the guide
     walks you through it in the Shizuku app. Contigua's own hint is: turn on
     Wireless debugging in Developer options, open Shizuku and start the
     service, then come back.
   - From a computer, with one adb command while the phone is connected. The
     exact command is in Shizuku's guide.
3. Back in Contigua, tap **Allow** on **Permission needed**. Shizuku shows its
   own permission prompt for Contigua; accept it.

What Contigua asks of Shizuku, from the code
(`android/app/src/main/java/app/contigua/app/ShizukuClient.kt`): a running
Shizuku that gates apps one by one (Shizuku 11 or later; the code treats an
older server as "cannot be granted"), and the Shizuku permission for
`app.contigua`. The dependency is Shizuku API 13.1.5. The server it starts
runs at shell UID 2000.

Shizuku stops when the phone restarts. Start it again the same way. The
**Home** card says **Shizuku not running** when that happens, and **Shizuku
isn't answering** (button **Try again**) when it runs but the shell service
keeps timing out.

Finish the onboarding. On **Home**, **Allow connections** is on by default;
leave it on. Turn on **Keep running in the background** if you want the service to
survive swiping the app away and start when the phone restarts.

## 5. Build and run the Mac app

### A signing certificate, once per Mac

macOS keeps the app's Local Network permission only for an app signed with a
certificate it trusts; without that, the Mac lists your phone but cannot pair
with it. Make a local code-signing certificate once and trust it (macOS asks
for your password):

```bash
cat > /tmp/contigua-cert.cfg <<'CFG'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Contigua Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
cd /tmp
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config contigua-cert.cfg \
  -keyout contigua.key -out contigua.pem
openssl pkcs12 -export -legacy -inkey contigua.key -in contigua.pem \
  -out contigua.p12 -passout pass:contigua
security import contigua.p12 -k ~/Library/Keychains/login.keychain-db \
  -P contigua -T /usr/bin/codesign
security add-trusted-cert -r trustRoot -p codeSign \
  -k ~/Library/Keychains/login.keychain-db contigua.pem
rm contigua.key contigua.p12 contigua-cert.cfg
cd -
```

`security find-identity -v -p codesigning` now lists "Contigua Local
Signing". The certificate lives in your login keychain and is valid for ten
years; nothing leaves your Mac. The first build asks whether `codesign` may
use the key: choose **Always Allow**.

### Build and install

```bash
cd macos
export CONTIGUA_SIGN_IDENTITY="Contigua Local Signing"
./scripts/install.sh
open /Applications/Contigua.app
cd ..
```

`install.sh` builds a release bundle with `scripts/bundle.sh`, quits a running
copy of `/Applications/Contigua.app` (never any other copy), replaces it, and
registers the copy and its Finder files extension with LaunchServices and
PlugInKit. The first build downloads the Swift packages listed in
`macos/Package.swift` and takes a few minutes. A failed build leaves the
installed copy alone.

Phone files in Finder are part of the install: it carries the File Provider
extension. For a copy without it (the script warns what is missing):

```bash
cd macos && ./scripts/install.sh --without-files && open /Applications/Contigua.app
```

To see the plan without building: `./scripts/install.sh --dry-run`.

To build without installing, run `./scripts/bundle.sh --variant release`; it
writes `macos/build/Contigua.app`. Never run a bundle's binary by hand without
`--profile <name>`, or it rewrites your profile (`macos/AGENTS.md`). Opening
the installed app is fine.

### What macOS does with this app

- **Gatekeeper.** The scripts build the app on your Mac and sign it there.
  Nothing in them downloads the bundle or sets a quarantine mark on it, so you
  open it with `open` or a double-click and macOS shows no "unidentified
  developer" prompt. If you copy the built app to another Mac through a
  download, that Mac may quarantine it; that is outside this guide.
- **Local Network.** The app finds phones with Bonjour (`_contigua._tcp`) and
  connects to them on your network, which needs Local Network access. On first
  pairing macOS should ask; allow it. If pairing says "Couldn't reach" while
  the phone is listed under Nearby, open System Settings, Privacy & Security,
  Local Network and turn Contigua on. That switch only holds for an app built
  with `CONTIGUA_SIGN_IDENTITY` set (above). The app does not yet name this
  cause itself (#132).
- **Login Items & Extensions.** The Share extension ("Open on Phone") and the
  Finder files extension need a one-time switch in System Settings, General,
  Login Items & Extensions. The app tells you when the files one is off ("Turn
  on Contigua in System Settings > Login Items & Extensions to show phone files
  in Finder."). Details: `docs/design/files.md`.
- **Accessibility and Screen Recording.** Building, installing, pairing and
  using the app need neither. Only the VM preparation script
  (`macos/scripts/vm-prepare.sh`) grants them, inside its own VM.
- **Control Center controls** do not appear yet (see README.md).

## 6. Pair

0. Upgrading from a plaintext build? Pair once more. Sessions are now TLS 1.3
   with pinned keys, so the old pairing does not carry over: the first
   connection after the update asks for a fresh pair (the phone's "This Mac's
   certificate changed; pair again" or the Mac's "This phone's identity
   changed. Pair again."). Code and QR pairing both work; after that,
   reconnects are silent.
1. Phone: Contigua, **Pair new Mac** (first run: onboarding, **Scan QR code**).
   The phone and the Mac must be on the same network, and **Allow connections**
   must be on.
2. Mac: **Pair with QR**, then point the phone at the sheet (the phone's camera
   app works too, because the link opens Contigua). The sheet closes itself
   when paired and the Mac shows the app list. The QR key expires after 5
   minutes. Without a camera you can connect by address and compare the
   six-digit code, then tap **Allow** on the phone.
3. Lock the phone. It never needs to be unlocked.

## 7. Open your first window

Double-click an app in the Deck (or press Command-K, type, then Return). Each
app gets its own window.

Things to try next:

1. Resize any window freely: tall, square, ultra-wide, or drag while the app
   runs. The app re-lays out to the new shape.
2. Type into the focused window, click, drag, scroll the wheel. Right-click is
   Android back, middle-click is home, and the mouse's side **Back** button is
   Android back too, exactly one per press, like the header's Back button
   (nothing while it is held, nothing on release, never a touch); **Forward**
   does nothing yet. Click a window first if keys seem ignored. On a trackpad,
   two-finger scroll drags the page like a finger (with fling); pinch and
   rotate are two fingers around the pointer. Windows are just the app: move
   the pointer to the top edge and a glass header with the traffic lights
   appears above the stream (drag it to move the window; the stream's edges
   resize it); it goes as soon as you leave. In the phone window it also has
   Back, Home and Recents.
3. Closing a window closes the app's virtual display. Relaunching the Mac app
   reconnects silently to the last phone.
4. Send a link to the phone: in Safari, Chrome, Notes or any app, **Share,
   Open on Phone** (also: right-click, Services, Open on Phone, or drop a link
   on the Deck). It opens in its Android app (Maps, YouTube, the browser) in a
   new window; with several phones Contigua asks which. If "Open on Phone"
   isn't in the Share menu, turn it on in System Settings, General, Login Items
   & Extensions, Sharing.
5. Install an Android app: drop an `.apk` (or an `.apks` / `.xapk` split bundle)
   on the Deck, or use the menu bar's **Install APK...** (also: Finder, Open
   With, Contigua, or right-click, Services, Install on Phone). The Deck shows
   the progress and the result ("Installed Example 1.2", or why the phone
   refused it).
6. Send something from the phone to the Mac: in any Android app, **Share, Send
   to Mac**. A link opens in the Mac's default browser; other text goes on the
   Mac clipboard ("Copied from <phone>"); an image (one or several, up to 50 MB
   each) is saved to `~/Downloads/Contigua/` and put on the clipboard, with a
   "Show in Finder" notification. Select text (or long-press a link) and choose
   **Open on Mac** in the text menu to do the same; when an app offers a
   choice of browsers for a link, **Open on Mac** opens it on the Mac. With no
   Mac connected the phone says "No Mac connected".
7. Give a phone app its own Mac app: in the Deck, right-click it, **Add to
   Dock**. "WhatsApp (Phone)" appears in the Dock with the app's icon
   (Options, Keep in Dock to pin it), in Launchpad, Spotlight and Command-Tab
   (it lives in `~/Applications/Contigua Apps/`). Launching it opens that app's
   window, or brings it forward; quitting it closes the window. Right-click,
   **Remove from Dock App** removes it; uninstalling the app on the phone or
   forgetting the phone removes it too.
8. Audio phone to Mac: with a window open, Contigua captures the phone's
   media/game audio (REMOTE_SUBMIX, via Shizuku at shell UID) and plays it on
   the Mac through AVAudioEngine (Opus or AAC, 20 ms frames) with the
   per-device volume slider and mute in the menu bar. Media apps playing on the
   phone are silenced on the phone speaker; added latency is under 150 ms. Try
   it by opening a music or video app in a Contigua window and playing
   something.

## 8. Optional: no phone? Use the emulator rig

`tools/emulator/` boots the real server on a local Android 16 emulator (the
Shizuku shell service, uid 2000) and runs the same steps (pair, lock, list
apps, two windows, non-16:9 resizes, input) while saving the last decoded frame
of each phase as a PNG. It talks to the phone by address (`adb forward`), never
over mDNS, and pins `emulator-5554` so a real phone stays untouched.

It needs an Apple-silicon Mac (the system image is `arm64-v8a`), the Android
SDK from step 1 with the command-line tools in `cmdline-tools/latest`,
`ffmpeg`, and a `python3` that can do TLS 1.3. `lib.sh` tries
`/opt/homebrew/bin/python3`; set `CONTIGUA_PYTHON` to use another. The scripts
call `timeout`; if `command -v timeout` prints nothing, run
`brew install coreutils` and put `$(brew --prefix coreutils)/libexec/gnubin`
on your PATH.

```bash
bash tools/emulator/setup.sh        # SDK packages + AVD (idempotent)
bash tools/emulator/preflight.sh    # no device: syntax, APK, manifest, budget
bash tools/emulator/verify-batch.sh --check   # rehearse the boot command
bash tools/emulator/start.sh        # boot, Shizuku, build+install, 127.0.0.1:47811
bash tools/emulator/flow.sh         # the POC check; frames in .work/emu/frames/
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port 47811 \
    --state tools/emulator/.cache/deckctl-state.json apps
```

`preflight.sh` needs the debug APK from step 3 to exist. `start.sh` downloads
Shizuku and two test apps into `~/.cache/contigua-emulator` (override with
`CONTIGUA_FIXTURES`); use `--no-build` to skip Gradle and `--window` for a
visible emulator.

Run every script as `bash <script>`: the rig does not rely on exec bits, and one
missing bit used to cost a whole boot. A boot is expensive, so rehearse it:
`verify-batch.sh --check` runs preflight (syntax, the APK's versionCode and
merged manifest, deckctl's subcommands, the boot budget) plus every section's
dry run without starting anything. The boot itself is one call:

```bash
timeout 1800 bash tools/emulator/verify-batch.sh
```

That boots once and runs media control, screen off/wake and the icon renders in
one go, then kills the emulator. The maintainer runs it under an optional machine-wide
lock script (set CONTIGUA_HEAVY) that is not part of the clone; you can leave it
out. The reliability rules learnt the hard way (explicit broadcast components,
`-d` installs with a versionCode check, the shell-service retry) are in
`tools/emulator/README.md`, which also covers pairing without a camera, port
discovery, timings and what fails on a loaded machine.

## 9. Optional: run the e2e checks

`macos/scripts/check-e2e.sh <check|all>` drives a test copy of the app against
the fake phone. It is not executable in the checkout, so run it with `bash`. It
needs Xcode (it builds `build/e2e/Contigua.app` from the current tree), a
`python3.11` or later on OpenSSL 3 (`brew install python@3.12` gives
`python3.12`; point `PD_FAKE_TLS_PYTHON` at it, since the script looks for
`python3.11` by name first), and `ffmpeg`. One check at a time; `all` is a
rare final gate.

```bash
cd macos
export PD_FAKE_TLS_PYTHON="$(brew --prefix python@3.12)/bin/python3.12"
bash scripts/check-e2e.sh pair
```

By default the run is quiet, so you can keep typing in another app:

- the app runs with `--background` (only with a test profile, never the default
  one): no Dock icon or Command-Tab entry, it never becomes the frontmost app,
  and its per-app Dock apps are agents launched in the background;
- its windows open on a virtual display of its own (about the size of your main
  display, placed so it touches it only at the bottom-right corner, gone when
  the app quits), so nothing appears on your screens and the streams keep
  running;
- clicks, keys and side buttons are delivered inside the app, never by moving
  your pointer.

`scripts/quiet-watch.swift` watches the whole run and the summary ends with
`QUIET focus_changes=N pointer_moves=N visible_windows=N dock_icons=N`; any
non-zero count fails the run. The few steps that need real input through the
window server print `SKIP ... (needs real input; PD_E2E_VISIBLE=1 runs it)`.
`PD_E2E_VISIBLE=1` runs everything visibly, as a normal foreground app with real
pointer events (for debugging; don't type meanwhile).

A test display has one fixed identity whatever `PD_E2E_PROFILE` says, so a
run adds no new display to macOS after the first one it has seen
(`docs/design/e2e-rig.md`). `macos/scripts/clean-ghost-displays.sh` lists the
ColorSync profiles left by older per-profile displays and, with `--apply` (as
an administrator: the folder is root-owned), deletes only files named after the
rig's displays whose display is not online now; every other profile is left
alone. Each run also sweeps the test copies and extensions it registered with
LaunchServices and PlugInKit, at its start and on its exit; the person's
`/Applications` copy is outside that allow-list.

## 10. Optional: run the suite in a VM

`macos/scripts/vm-e2e.sh <check>` runs the same suite inside a headless
macOS VM on this Mac, so the run cannot touch your session at all: the VM has
no window of its own, and its displays, focus and input are its own. It needs
the VM tool `tart` (the scripts look for it at `~/.local/bin/tart`; set `TART`
to use another path) and room for the VM. Nothing has to be typed during the
run, so the VM runs `PD_E2E_VISIBLE=1` by default and the real-input checks
(global events, side button, `open -a`) run too (`PD_VM_VISIBLE=0` for a quiet
run instead). A comma list (`vm-e2e.sh pair,chrome,mirror,dock`) runs those
checks one after another in a single boot, each with its own log, PASS/FAIL and
`passed=`/`failed=` lines; a boot is the expensive part, and each check is its
own process either way.

The VM is `pd-e2e`: a clone of `ghcr.io/cirruslabs/macos-tahoe-base:latest`
with 2 CPUs, 4 GB RAM (the smallest this image accepts) and a 1920x1200 pt
display setting. `macos/scripts/vm-prepare.sh` creates it (add `--fresh` to re-clone)
and installs what the suite needs inside: Homebrew python3
with pyOpenSSL (TLS 1.3 for the fakephone) and ffmpeg (video checks), the ssh
key from `~/.tart/pd-e2e` and the TCC grants `screencapture` and CGEvents need.
The image already brings the rest: Command Line Tools (the suite compiles its
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

`vm-e2e.sh` builds `build/e2e/Contigua.app` on the host, boots the VM
headless, copies the tree, the bundle and `tools/fakephone` in, runs the check
in the VM's console session, copies the log and the run's work dir back to
`macos/build/vm-e2e/<check>/` (`run.log`, `work/`) and stops the VM; a list
lands in `macos/build/vm-e2e/<check+check...>/checks/<check>/` (`run.log`,
`work/`). The whole boot-run-stop is one heavy step: it takes a machine-wide
lock (`/tmp/contigua-heavy.lock`, taken by `vm-common.sh`), so it never runs
beside other heavy work that uses the same lock. Before that it waits for room
for the VM (at least 25% free memory, swap under 2 GB); a boot/stop cycle
pushes swap up for a while, so back-to-back runs can wait a few minutes between
them. The exit code is the check's (a list's is the number of checks that
failed).

Known VM-only failures (second `all` in the VM, 2026-10-19: 254 passed, 5
failed; none of them fail on the host): C15 fingerscroll's refresh-apart gap
(VM timing), and a cascade where the shared session goes offline after phone
mode (C11's nav home/recents, then the audio and drop opens answer "not
online"); the cascade does not show every boot. `PD_VM_FAKE_DEBUG=1 vm-e2e.sh`
keeps the guest fakephone's session diagnostics in `fake.err` for the next
time it does. C12's Spotlight unit tests and C6's tall shape print `SKIP` in
the VM, with the reason.

## Troubleshooting

- **The Mac says it cannot find the phone, or times out, though the phone looks
  healthy.** After an `adb install -r` the old server process can still hold
  the listener. Reinstall with `tools/phone_install.sh <apk> [serial]` (step
  3), which restarts it and checks the new process runs the new APK.
- **Phone card says "Shizuku not running" or "Shizuku isn't installed".**
  Start or install it (step 4). Shizuku has to be started again after every
  phone restart.
- **Phone card says "Shizuku permission needed".** Tap **Allow** and accept
  Shizuku's prompt.
- **Phone card says "Shizuku isn't answering".** Tap **Try again**. If it
  persists, restart Shizuku.
- **The phone never asks to pair.** Turn on **Allow connections** (and **Allow
  new pairings**) on the phone's Home, and allow notifications: the pairing
  prompt is a notification ("Notifications are off" on the card means it
  cannot show).
- **"Contigua needs Local Network access" on the Mac.** System Settings,
  Privacy & Security, Local Network, switch Contigua on.
- **Finder says "This copy of Contigua was built without Finder files".** The
  app was built without the files extension. Run `./scripts/install.sh` (not
  `--without-files`) and switch Contigua on in Login Items & Extensions.
- **"Open on Phone" is missing from the Share menu.** Switch it on in System
  Settings, General, Login Items & Extensions.
- **Keys seem ignored in a window.** Click the window first.
- **A second Mac gets "busy".** One Mac at a time (see below).
- **"This phone's identity changed. Pair again." or "This Mac's certificate
  changed; pair again".** Pair once more (step 6).
- **`install.sh` says a check-e2e run is in progress.** Wait for it to finish,
  then run it again.

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
- After about 20 min with no stream the phone can stop answering mDNS while
  fully dozing; wake its screen once and the Mac finds it again.
- One Mac at a time (a second session gets "busy").
- Windows wider/taller than 2560 px of virtual display are scaled down (aspect
  kept), which lowers the density instead of letterboxing.
- Mutual TLS 1.3 on the LAN, both certificates pinned at pairing
  (docs/PROTOCOL.md, docs/design/e2ee.md).
