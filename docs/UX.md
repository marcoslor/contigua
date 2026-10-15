# PocketDeck — UX spec (v0)

Principle: **only what's necessary.** One primary action per screen, short copy, no
settings the user doesn't need. Status is shown, not explained. macOS uses Liquid
Glass materials throughout; Android uses Material 3 (dynamic color, light/dark).
Visual system: [DESIGN.md](DESIGN.md).

## Pairing model (both sides)

Three ways to pair; all end in the same stored pairing (Mac pair key ⇄ phone
paired-clients list). Pairings are remembered; reconnection is automatic and silent.

| Method | Mac | Phone |
|---|---|---|
| **Automatic (default)** | Phone appears in "Nearby" via Bonjour → click **Pair** → the sheet shows a 6-digit code | Notification/sheet: "Pair with *Marcos's MacBook*?" shows the same code · **Allow** / Deny |
| **QR code** | "Pair with QR" shows a QR (`pocketdeck://pair?c=<clientId>&n=<mac name>&k=<64-hex one-time key>`) | **Scan QR** → the app registers that client + key with the server → done (scanning is the consent; no code, no Allow) |
| **Manual** | "Connect manually…" → host + port fields → then the same comparison | same as Automatic |

Automatic flow detail (numeric comparison, nothing is typed): the Mac sheet reads **"Pair with *phone name*"**, the code in
large monospaced digits grouped "123 456", and the line **"Tap Allow on your phone if it shows the same code."** with **Cancel**.
The person compares the two screens and taps **Allow** on the phone; that is the only step. The sheet then shows "Pairing…" and
a checkmark. States: *Contacting *phone name*…* (before the code arrives) · *Pairing…* · "Pairing was denied on the phone." ·
"Nobody tapped Allow in time. Try again." (the phone gives up after 120 s) · "Couldn't reach *phone name*. Try again." The Mac waits
the whole 120 s; Cancel hangs up and the phone dismisses its prompt. The code will later be derived from both devices' TLS
certificate fingerprints, so it is only ever displayed, never typed.

QR flow detail: after showing the QR the Mac keeps the pending key and, for every
discovered phone, tries `auth` with it (challenge `id` tells it which phone answered).
On `welcome` it stores the key under that device id and closes the QR sheet. The QR
key expires after 5 minutes or on sheet close.

**Pairing manager:** Mac → Settings → Devices (paired phones: name, model, last seen,
Forget). Phone → home screen "Paired Macs" (name, last connected, Forget). Forgetting
on either side removes the key; the other side gets `auth_failed` next time and shows
"Pair again".

## macOS app

Menu-bar presence + Dock icon. One home window, the **Deck**, plus the app windows.
Detail, states, copy and the connection state machine: [design/mac-redesign.md](design/mac-redesign.md).

1. **Deck** (the only main window; closing it hides it, the Dock icon and ⌘K bring it back). What it shows is chosen by
   what this Mac remembers:
   - **Welcome** (first run only): glass card over a soft gradient. App icon, "PocketDeck", "Your Android apps, on your
     Mac.", three compact steps (*Install PocketDeck on your phone* · *Start Shizuku* with "How?" · *Be on the same
     Wi-Fi*), primary **Find my phone**.
   - **Nearby** (nothing paired yet; also the "Add a phone" sheet): phones on the network as glass rows (name, model,
     **Pair**), footer **Pair with QR** · **Connect manually…**. Empty: spinner "Looking for phones on this network…" +
     "Make sure PocketDeck is open on your phone." Pairing runs in sheets: the 6-digit code to compare (inline errors, Cancel) or the QR
     (countdown, success check).
   - **Phone** (a phone is paired, including while it is away): toolbar with one group packed at the left — the traffic
     lights, the connection chip (green dot · lock while locked · battery / Connecting… / Reconnecting… / Offline /
     Pair again) and the phone's name — and one at the right: **Phone** button, search and the Settings gear (⌘,);
     nothing floats in the middle between them. The app grid (single click opens, arrows move, ↩ opens, esc clears).
     The grid is there at launch from the last session and is dimmed while the phone is away. A problem is one banner
     line with at most one button (Try now / Pair again).
2. **App windows**: only the stream, with rounded corners and a shadow; no title bar, and the desktop shows right up to the stream. Bring
   the pointer to the stream's top edge and a glass header (with the traffic lights) appears at once *above* the stream, never over it; drag
   the glass to move the window. The stream's own edges resize the window. The header goes as soon as the pointer leaves, and clicks above a resting
   window reach what is behind it. The stream never moves or changes size for it. The trackpad works like a touch screen: a two-finger scroll is a finger dragging
   (Android's own scrolling, overscroll and fling), a pinch or rotate is two fingers around the pointer, the mouse wheel stays a wheel and three or more
   fingers stay the system's; **View → Show Touches** draws a dot where the phone is being touched (off by default).
   New windows cascade (never on top of the Deck) and remember their frame. While the connection is down a small glass pill
   ("Reconnecting…") sits over the last frame; the window stays open. Phone mode: Back · Home · Recents sit at the right
   of the hover header.
3. **Settings** (⌘,; also the settings gear at the Deck header's right): tabs **General** (launch at login, show in
   menu bar, default window density) · **Devices** (paired phones: name, model, last seen, **Use**, **Forget**;
   **Add phone…**). Nothing else.

Status/feedback: a single connection chip in the Deck toolbar and the menu-bar menu. Reconnecting is silent: a remembered phone
connects by itself at launch and after any drop, with back-off, and the UI shows "Offline" (never an error code) only after 15 s
without a connection. Errors are one line, inline, never modal.

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
   if the app is in the foreground, a Material dialog with the large code ("Check it matches your Mac.").
   It disappears by itself when the Mac cancels or the request expires.
4. **Phone-mode launcher** (runs on the virtual display, shown on the Mac): Material
   search bar + app grid, nothing else.

## Copy rules

Sentence case. No jargon on primary surfaces ("virtual display", "VD", "stream",
"HMAC", "port" only appear under Connect manually / diagnostics). Max one line of
helper text per element.
