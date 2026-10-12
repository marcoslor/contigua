# Try PocketDeck: Android apps in Mac windows, phone locked

Same Wi-Fi; Shizuku running on the phone and "Allow connections" on.

```bash
# phone (USB or wireless debugging)
cd android && export JAVA_HOME=/opt/homebrew/opt/openjdk@17 ANDROID_HOME=$HOME/Library/Android/sdk
./gradlew :app:assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk
# Mac
cd macos && swift build && ./scripts/bundle.sh && open build/PocketDeck.app
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

## Known limitations (SM-S936B, Android 16)

- The locked phone's screen wakes while a window streams (lock screen only; the
  PIN is never needed) because this Samsung build puts the virtual display in
  the panel's display group. AOSP builds keep the panel off.
- Chrome stable (`com.android.chrome`) is disabled for user 0 by the vendor;
  use **Chrome Dev** (`com.chrome.dev`) from the app list.
- After ~20 min with no stream the phone can stop answering mDNS while fully
  dozing; wake its screen once and the Mac finds it again.
- One Mac at a time (a second session gets "busy").
- Windows wider/taller than 2560 px of virtual display are scaled down (aspect
  kept), which lowers the density instead of letterboxing.
- Plaintext + HMAC on the LAN (TLS is a later milestone, docs/PROTOCOL.md).
