# Try PocketDeck: Android apps in Mac windows, phone locked

Same Wi-Fi; Shizuku running on the phone and "Allow connections" on.

```bash
# phone (USB or wireless debugging)
cd android && export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :app:assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk
# Mac: build a release copy and install it to /Applications (quits a running copy first)
cd macos && ./scripts/install.sh && open /Applications/PocketDeck.app
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
