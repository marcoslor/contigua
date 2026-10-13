# Try PocketDeck: Android apps in Mac windows, phone locked

Same Wi-Fi; Shizuku running on the phone and "Allow connections" on.

```bash
# phone (USB or wireless debugging)
cd android && export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :app:assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk
# Mac: build a release copy and install it to ~/Applications (quits a running copy first)
cd macos && ./scripts/install.sh && open ~/Applications/PocketDeck.app
```

1. Phone: PocketDeck → **Pair new Mac** (first run: onboarding → **Scan QR code**).
2. Mac: **Pair with QR** → point the phone at the sheet (the phone's camera app
   works too — the link opens PocketDeck). The sheet closes itself when paired
   and the Mac shows the app list; the QR key expires after 5 minutes.
3. Lock the phone. It never needs to be unlocked.
4. Mac: double-click an app (or ⌘K → type → ↩). Each app gets its own window.
5. Resize any window freely — tall, square, ultra-wide, or drag while the app
   runs. The app re-lays out to the new shape.
6. Type into the focused window, click/drag, scroll the wheel. Right-click =
   Android back, middle-click = home. Click a window first if keys seem ignored.
7. Closing a window closes the app's virtual display; relaunching the Mac app
   reconnects silently to the last phone.

## No phone? Use the emulator rig

`tools/emulator/` boots the real server on a local Android 16 emulator (the
Shizuku shell service, uid 2000) and runs the same steps — pair, lock, list apps,
two windows, non-16:9 resizes, input — while saving the last decoded frame of
each phase as a PNG. It talks to the phone by address (`adb forward`), never over
mDNS, and pins `emulator-5554` so a real phone stays untouched.

```bash
tools/emulator/setup.sh    # SDK packages + AVD (idempotent)
tools/emulator/start.sh    # boot, Shizuku, build+install, prints 127.0.0.1:47811
tools/emulator/flow.sh     # the POC check; frames in .agent/emu/frames/
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port 47811 \
    --state tools/emulator/.cache/deckctl-state.json apps
```

Details (pairing without a camera, port discovery, timings, what fails on a
loaded machine) are in `tools/emulator/README.md`.

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
- Plaintext + HMAC on the LAN (TLS is a later milestone, docs/PROTOCOL.md).
