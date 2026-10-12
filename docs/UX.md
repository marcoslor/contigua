# PocketDeck — UX spec (v0)

Principle: **only what's necessary.** One primary action per screen, short copy, no
settings the user doesn't need. Status is shown, not explained. macOS uses Liquid
Glass materials throughout; Android uses Material 3 (dynamic color, light/dark).
Visual system: [DESIGN.md](DESIGN.md).

## Pairing model (both sides)

Three ways to pair; all end in the same stored pairing (Mac Keychain key ⇄ phone
paired-clients list). Pairings are remembered; reconnection is automatic and silent.

| Method | Mac | Phone |
|---|---|---|
| **Automatic (default)** | Phone appears in "Nearby" via Bonjour → click **Pair** → enter the 6-digit code | Notification/sheet: "Pair with *Marcos's MacBook*?" shows the code · **Allow** / Deny |
| **QR code** | "Pair with QR" shows a QR (`pocketdeck://pair?c=<clientId>&n=<mac name>&k=<64-hex one-time key>`) | **Scan QR** → the app registers that client + key with the server → done (scanning is the consent; no code, no Allow) |
| **Manual** | "Connect manually…" → host + port fields → then the code flow | same as Automatic |

QR flow detail: after showing the QR the Mac keeps the pending key and, for every
discovered phone, tries `auth` with it (challenge `id` tells it which phone answered).
On `welcome` it stores the key under that device id and closes the QR sheet. The QR
key expires after 5 minutes or on sheet close.

**Pairing manager:** Mac → Settings → Devices (paired phones: name, model, last seen,
Forget). Phone → home screen "Paired Macs" (name, last connected, Forget). Forgetting
on either side removes the key; the other side gets `auth_failed` next time and shows
"Pair again".

## macOS app

Menu-bar presence + Dock icon. Windows:

1. **Welcome** (first run only, one window, glass card over a soft gradient):
   - Hero: app icon, "PocketDeck", one line: "Your Android apps, on your Mac."
   - Three compact steps with SF Symbols: *Install PocketDeck on your phone* ·
     *Start Shizuku* (link "How?") · *Be on the same Wi-Fi*.
   - Primary button **Find my phone** → Devices view.
2. **Devices** (also the window shown when nothing is paired):
   - "Nearby" list (glass rows: phone name, model, signal of reachability), each with **Pair**.
   - Footer buttons (glass, secondary): **Pair with QR** · **Connect manually…**
   - Empty state: subtle spinner "Looking for phones on this network…" + "Make sure
     PocketDeck is open on your phone."
   - Code entry sheet: six digit boxes, auto-advance, auto-submit on the 6th digit;
     wrong code shakes; 3 failures → back to list with a one-line error.
3. **Launcher** (main window once paired; ⌘K / menu-bar click toggles it, Spotlight-like):
   - Floating glass panel: search field (focused), app grid with icons, phone name +
     lock/battery chip in the header, **Phone** button (opens phone mode).
   - Typing filters; ↩ opens the first match; arrows move selection; esc hides.
4. **App windows**: content only — video edge to edge, standard traffic lights,
   title = app name with its icon. No toolbar. A thin glass bar appears on hover at
   the top for phone mode only (Back · Home · Recents).
5. **Settings** (⌘,): tabs **General** (launch at login, show in menu bar, default
   window density) · **Devices** (pairing manager). Nothing else.

Status/feedback: a single connection chip (Connected · Reconnecting… · Offline) in the
launcher header and the menu-bar menu. Errors are one line, inline, never modal except
"Pairing failed".

## Android app

Material 3, edge-to-edge, dynamic color, light/dark.

1. **Onboarding** (first run, pager with a progress indicator, each step auto-advances
   when its condition becomes true):
   1. *Welcome* — illustration/icon, "Use your apps on your Mac", **Get started**.
   2. *Shizuku* — live status row: Not installed (button **Get Shizuku**) → Not running
      (button **Open Shizuku** + 3-line "How to start it" with wireless debugging) →
      Permission needed (button **Allow**) → ✓ Ready. Auto-advance on ready.
   3. *Notifications* — needed for pairing prompts → **Allow** (POST_NOTIFICATIONS);
      also requests ignoring battery optimizations once, with one line why.
   4. *Pair your Mac* — "Open PocketDeck on your Mac. It will find this phone." +
      **Scan QR code** (outlined) — completes on first successful pairing.
2. **Home**:
   - Big status card: **Ready** · "Visible to Macs on *Wi-Fi name*" / **Connected to
     *Mac name*** · "*N* windows open" / **Shizuku not running** (with fix button).
   - Switch: "Allow connections".
   - "Paired Macs" list (name, last connected, Forget via swipe or overflow).
   - FAB or tonal button: **Pair new Mac** (QR scan).
3. **Pairing prompt**: high-priority notification with the code and Allow/Deny, and,
   if the app is in the foreground, a Material dialog with the large code.
4. **Phone-mode launcher** (runs on the virtual display, shown on the Mac): Material
   search bar + app grid, nothing else.

## Copy rules

Sentence case. No jargon on primary surfaces ("virtual display", "VD", "stream",
"HMAC", "port" only appear under Connect manually / diagnostics). Max one line of
helper text per element.
