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
| **Automatic (default)** | Phone appears in "Nearby" via Bonjour → click **Pair** → the sheet shows a 6-digit code | Notification/sheet: "Pair with *Studio Mac*?" shows the same code · **Allow** / Deny |
| **QR code** | "Pair with QR" shows a QR (`pocketdeck://pair?c=<clientId>&n=<mac name>&k=<64-hex one-time key>`) | **Scan QR** → the app registers that client + key with the server → done (scanning is the consent; no code, no Allow) |
| **Manual** | "Connect manually…" → host + port fields → then the same comparison | same as Automatic |

Automatic flow detail (numeric comparison, nothing is typed): the Mac sheet reads **"Pair with *phone name*"**, the code in
large monospaced digits grouped "123 456", and the line **"Tap Allow on your phone if it shows the same code."** with **Cancel**.
The person compares the two screens and taps **Allow** on the phone; that is the only step. The sheet then shows "Pairing…" and
a checkmark. States: *Contacting *phone name*…* (before the code arrives) · *Pairing…* · "Pairing was denied on the phone." ·
"Nobody tapped Allow in time. Try again." (the phone gives up after 120 s) · "Couldn't reach *phone name*. Try again." The Mac waits
the whole 120 s; Cancel hangs up and the phone dismisses its prompt. The code is derived from both devices' TLS
certificate fingerprints, so it is only ever displayed, never typed.

QR flow detail: after showing the QR the Mac keeps the pending key and, for every
discovered phone, tries `auth` with it (challenge `id` tells it which phone answered).
On `welcome` it stores the key under that device id and closes the QR sheet. The QR
key expires after 5 minutes or on sheet close.

**Pairing manager:** Mac → Settings → Phones (paired phones: name, nickname, model, last seen,
**Rename…**, **Use**, **Forget**). Phone → home screen "Paired Macs" (name, last connected, Forget). Forgetting
on either side removes the key; the other side gets `auth_failed` next time and shows
"Pair again".

## macOS app

Menu-bar presence + Dock icon. One home window, the **Deck**, plus the app windows.
Detail, states, copy and the connection state machine: [design/mac-redesign.md](design/mac-redesign.md).
The app's own menu items carry SF Symbols, as Apple's apps draw theirs, and the menus have no section titles. **View** holds
Find Apps · Framed / Immersive (⌥⌘F switches) · Hide Controls › · Show Touches · Live Text · Density › (Default, the other
percentages, Larger ⌘+, Smaller ⌘−, Actual Size ⌘0). **Phone** holds Phone Mirror ⌘P · Move Phone App to Mac ⇧⌘C · Turn Off Phone
Screen · Do Not Disturb · Ring Phone / Stop Ringing · Install APK…. **Navigate** holds Back · Home · Recents, **Window** the
standard items plus Enter Full Screen ⌃⌘F, and **Help** is empty (there is no help book). A control that cannot work is
disabled, never hidden.

1. **Deck** (the only main window; closing it hides it, the Dock icon and ⌘K bring it back; ⌘F focuses the search
   field and selects its text). What it shows is chosen by what this Mac remembers:
   - **Welcome** (first run only): glass card over a soft gradient. App icon, "PocketDeck", "Your Android apps, on your
     Mac.", three compact steps (*Install PocketDeck on your phone* · *Start Shizuku* with "How?" · *Be on the same
     Wi-Fi*), primary **Find my phone**.
   - **Nearby** (nothing paired yet; also the "Add a phone" sheet): phones on the network as glass rows (name, model,
     **Pair**), footer **Pair with QR** · **Connect manually…**. Empty: spinner "Looking for phones on this network…" +
     "Make sure PocketDeck is open on your phone." Pairing runs in sheets: the 6-digit code to compare (inline errors, Cancel) or the QR
     (countdown, success check).
   - **Phone** (a phone is paired, including while it is away): toolbar with one group packed at the left — the traffic
     lights, the connection chip (green dot · lock while locked · battery / Connecting… / Reconnecting… / Offline /
     Pair again) and the phone's name (its nickname when one is set) — and one at the right: **Phone** button, the Settings gear (⌘,), then the
     search field (macOS keeps a toolbar search at the trailing end); nothing floats in the middle between them.
     The app grid (single click opens, arrows move, ↩ opens, esc clears).
     The grid is there at launch from the last session and is dimmed while the phone is away. A problem is one banner
     line with at most one button (Try now / Pair again).
2. **App windows**: two styles, View ▸ **Framed** / **Immersive** (plain radio items, no section header; ⌥⌘F is View ▸ Toggle Window
   Style), remembered per app: **Framed** (default) is the stream plus a permanent 28 pt bar
   above it — the stream's own top rows mirrored there, blurred progressively and with no tint, the traffic lights on that line; **Immersive** is only the
   stream, with rounded corners and a shadow, no title bar, and the desktop shows right up to it; a rest at its top-left (350 ms by default; Settings →
   General → **Reveal controls after** picks Instantly, Short or Long) fades in a small clear-glass pill with the traffic lights (Back · Home · Recents
   join it in phone mode), a click in that corner before the dwell reaches the app as an ordinary touch, and the pill fades out 600 ms after the pointer
   leaves. Switching grows or shrinks the window by the bar, the stream keeps its place. Native full screen lives in the Window menu
   (**Enter Full Screen** / **Exit Full Screen**, 🌐F, or the green light); the stream fills the screen in
   either style; the bar macOS reveals at the top edge is the system's, with the window's title centred and the standard traffic lights. The stream's own edges resize the window. The trackpad works like a touch screen: a two-finger scroll is a finger dragging
   (Android's own scrolling, overscroll and fling), a pinch or rotate is two fingers around the pointer, the mouse wheel stays a wheel, the mouse's side
   **Back** button (button 3) sends Android Back to that window once per press — never repeated while held, nothing on release, and never a touch —
   while **Forward** (button 4) does nothing for now, and three or more
   fingers stay the system's; Back also arrives as a right click, ⌘[, or a swipe-back event from mouse utilities (Logi Options+), once per gesture.
   **View → Show Touches** (on by default on a Mac with a trackpad) draws a dot where the phone is being touched by a trackpad
   gesture — touches only, never the pointer's hover — and the framed bar above the stream never shows it: the bar mirrors the
   video, not the overlay.
   The pointer over the stream is a mouse over Android: hover highlights, tooltips and hover menus react as they do with a real
   mouse, and the pointer leaving the video (or the window), a click, a drag or the window losing focus ends the hover before the
   touch. Settings → Input → **Hover over Android apps** turns it off.
   New windows cascade (never on top of the Deck) and remember their frame. While the connection is down a small glass pill
   ("Reconnecting…") sits over the last frame; the window stays open.
   While an app window is open, its app appears in the Dock and ⌘-Tab as "App (Nickname)" (a link window as the app that
   displays the link; the phone mirror as nothing). It arrives on its own, ends when the window closes, and **Options → Keep in Dock**
   makes it permanent ("Add to Dock" in the app's context menu does the same by hand; Settings → General switches it off).
3. **Menu bar panel**: a click on the status item opens a Control Center-style card — the phone's name and state,
   its battery, a 2×2 set of tiles for **Do Not Disturb**, **Ringer**, **Ring Phone** / **Stop Ringing** and
   **Turn Off Screen** (Screen on / Screen off), the volume slider with its %, **Now Playing follows** when several
   apps play, the live notifications, one **WINDOWS** row (**Mirror** ⌘P · **Find Apps** ⌘K · **Move to Mac** ⇧⌘C ·
   **Install APK…**), and a **gear** at the card's top-right. **Ringer** opens
   Ring / Vibrate / Silent with the current mode checked; the volume follows the pointer while it is dragged. A
   control that cannot work is dimmed as a whole (icon, title and its short second line, e.g. "Open Mirror first"),
   never accent-tinted; the full sentence is its help tag and VoiceOver hint ("Open Phone Mirror first."). The
   card opens with its focus ring on the first tile (or on **Disconnect** while an AI agent is connected), never on
   the gear. The Deck's status pill opens the same card in a popover, without the gear.

   The status item's **secondary click** (a right-click, or ⌃-click) opens the app's command menu under the icon:
   **Settings…** ⌘, · **About PocketDeck** · **Quit PocketDeck** ⌘Q, with a separator before Quit. The card closes
   first if it is open. The card's **gear** opens that same menu, so both are one path; its help tag is
   "Settings, About and Quit" and VoiceOver calls it "Settings and more". The panel has no Settings…/Quit rows of
   its own.
4. **Settings** (⌘,; also the settings gear at the Deck header's right): a System Settings–style window,
   720 × 560, with a sidebar and a detail column. The sidebar opens with **Phones** — a row per phone (icon,
   name, a dot plus **Connected** / **Connecting…** / **Reconnecting…** / **Offline** / **Pair again** and,
   while it is not connected, when it was last seen; **In Use** on the one the rest of the app shows) and an
   **Add Phone…** row — then **This Mac**: **General** (launch at login, show in menu bar, share clipboard with
   your phone — off until it is turned on, and the row says in either position what travels: the text and images
   you copy here reach the phone while it is connected, and what you copy there lands here — show phone apps in
   the Dock, **glass app icons**, default window density, **reveal controls
   after**), **Input** (**hover over Android apps**) and **Automation**. A phone opens its page in the detail:
   a header with its icon, name, state and **In Use** or **Use This Phone** (**Pair Again…** when its key is
   gone), then the plain sections **Phone** (**Model**, **Rename…**), **Notifications** (**Share notifications
   and Now Playing**, **When I click a notification** with **Open on this Mac** / **Open on the phone** / **Do
   nothing**, and **Muted apps** with its count, a search field and a **Muted** checkbox column), **Screen**
   (**Keep the phone screen off until I turn it on from the Mac**) and **Forget** (**Forget This Phone…** alone
   at the end). The window title is the open page's name, and that is the only other place a phone is named: no
   section heading carries it. ⌘, reopens the last page (the in-use phone, or **General** with no phones); the
   sidebar has the keyboard, ↑/↓ move between rows and Tab moves into the page; **Add Phone…** opens the
   pairing sheet without moving the page. Any phone is one click away and its settings are editable whether or
   not it is in use (they apply on its next connection); forgetting the open phone opens the phone in
   use, else **General**. Muted apps lists the apps this Mac already has for that phone, muted first, with a
   mark on apps that sent a notification this session, "System UI" for `com.android.systemui` and the package
   name for an app with no name. When the phone has not been granted notification access, the page says
   **Allow notification access on the phone.** under the switch. The Dock shims rebuild on a rename. Nothing else.

    A **nickname** ("Rename…" dialog) is 1–40 characters, trimmed; empty keeps using the phone's own name. It is the one
    name everywhere: the Deck title, the menu bar, the chip's voiceover copy, failure banners, notifications from the phone
    ("Copied from *Nickname*"), Spotlight entries ("App (Nickname)"), phone and app window titles ("WhatsApp (Nickname)"),
    and the Dock shim names — open windows retitle at once and the phone's shims rebuild with the new name.

Status/feedback: a single connection chip in the Deck toolbar and the menu-bar panel. Reconnecting is silent: a remembered phone
connects by itself at launch and after any drop, with back-off, and the UI shows "Offline" (never an error code) only after 15 s
without a connection. Errors are one line, inline, never modal.

## Android app

Material 3, edge-to-edge, dynamic color, light/dark.

1. **Onboarding** (first run, pager with a progress indicator, each step auto-advances
   when its condition becomes true):
   1. *Welcome* — illustration/icon, "Your Android apps, on your Mac", one line on
      how ("Open PocketDeck on your Mac and pick this phone — it stays locked."),
      **Get started**.
   2. *Shizuku* — live status row: Not installed (button **Get Shizuku**) → Not running
      (button **Open Shizuku** + 3-line "How to start it" with wireless debugging) →
      Permission needed (button **Allow**) → ✓ Ready. Auto-advance on ready.
   3. *Notifications* — needed for pairing prompts → **Allow** (POST_NOTIFICATIONS);
      also offers **Let PocketDeck run in the background** once, with one line why.
   4. *Pair your Mac* — "Open PocketDeck on your Mac. It will find this phone." +
      **Scan QR code** (outlined) — completes on first successful pairing.
2. **Home**:
   - Big status card: **Ready** · "Visible to Macs on *Wi-Fi name*" / **Connected to
     *Mac name*** · "*N* windows open" / **Shizuku not running** (with fix button).
     With the background switch off the card still says **Ready**, with
     "Stops when you close PocketDeck from recent apps." — information, not a
     warning, and no button.
   - Switch: "Keep running in the background". On: the service survives the app
     being swiped away from Recents and starts at boot. Off: it runs only while
     PocketDeck's task is open, then stops (and closes its listening socket)
     when the task is swiped away; no boot start. Default off.
   - Divider, then the connection switches:
   - Switch: "Allow connections" (master: off refuses every Mac, paired or not,
     drops live sessions and stops advertising). Default on. Independent of the
     background switch: turning it on flips only this one.
   - Switch: "Allow new pairings" (off refuses unknown Macs before any code;
     paired Macs still connect). Greyed out while "Allow connections" is off.
     Default on.
   - No notification-sharing switch: the switch lives on the Mac, per phone
     (Settings ▸ Phones). When a Mac turns it on, the phone asks for
     notification-listener access by itself; if that fails, the status card
     shows **Notification access is off** with **Allow**, which opens the
     system's Notification access screen. A later grant starts forwarding on
     its own.
   - The card, every switch row and the "Paired Macs" title share one left
     edge; no extra indent on the list rows.
   - "Paired Macs" list (name, last connected, Forget via swipe or overflow).
   - FAB or tonal button: **Pair new Mac** (QR scan).
   - Ongoing notification (channel **Connection status**): "Ready for your Mac"
     while listening, "Connected to *Mac name* · *N* windows" when a Mac is
     connected (singular for one window). No port numbers.
3. **Pairing prompt**: high-priority notification with the code and Allow/Deny, and,
   if the app is in the foreground, a floating Material card with the large code
   ("Check it matches your Mac.") — 16 dp from the sides and 16 dp above the
   navigation bar, rounded on all corners, not a bottom sheet under the gesture
   handle.
   It disappears by itself when the Mac cancels or the request expires.
4. **Phone-mode launcher** (runs on the virtual display, shown on the Mac): Material
   search bar + app grid, nothing else.

## Mac windows

### Opening a window

- App window, before its first frame: the app's icon and name, a spinner,
  **Opening on your phone…**.
- Phone Mirror: the phone's icon and name, a spinner, **Opening your phone…**.
- After 5 s: **Still opening…**.
- After 20 s without a frame: **Couldn't open <app>.** (the Phone Mirror:
  **Couldn't open your phone.**) with **Try Again** and **Close**. Try Again
  sends the same open again; Close closes the window.
- The cover is a frozen mode: no input reaches the phone. The "Not responding"
  watchdog runs only after the first frame.

### Secondary click

Settings ▸ Input ▸ **Secondary click (two-finger click)**:

- **Long press** (default): the touch goes down at the pointer, holds for
  Android's long-press timeout, then comes up, so the app's context menu opens
  as a right-click does. A drag while held moves the touch.
- **Back**: one Back, like the mouse's side Back button.
- **Nothing**: the gesture does nothing.

## Copy rules

Sentence case. No jargon on primary surfaces ("virtual display", "VD", "stream",
"HMAC", "port" only appear under Connect manually / diagnostics). Max one line of
helper text per element.

## Keyboard shortcuts

Every keyboard shortcut the app defines (CONV-MAC-06). The first cell of each row is the shortcut, with
⌃ ⌥ ⇧ ⌘ for modifiers; `scripts/check-rules.sh` (R-KEY-1) reads this table, so a new shortcut outside
`MenuBar.swift` needs its row here. A bare key with no modifier is not a shortcut and is not listed.

| Shortcut | Action | Where |
| --- | --- | --- |
| ⇧⌘N | Add Phone… | File |
| ⌘K | Find Apps | View |
| ⌥⌘F | Framed window style (the same key toggles Framed / Immersive) | View |
| ⇧⌘T | Live Text | View |
| ⌘+ | Larger: the Deck grid, or the window's density | View, Deck |
| ⌘− | Smaller: the Deck grid, or the window's density | View, Deck |
| ⌘0 | Actual Size: the Deck grid, or the window's density | View, Deck |
| ⌘P | Phone Mirror | Phone |
| ⇧⌘C | Move Phone App to Mac | Phone |
| ⌘[ | Back | Navigate |
| ⇧⌘H | Home (phone mode) | Navigate |
| ⌘↑ | Recents (phone mode) | Navigate |
| ⌃⌘F | Enter / Exit Full Screen | Window |
| ⌘F | Find in the Deck: focus and select the search field | Deck |
| ⌘, | Settings | Icon menu, Deck |
| ⌘Q | Quit PocketDeck | Icon menu, app menu |
| ↩ | Default button: Find my phone, Try again | Deck, pairing sheets |
| ⎋ | Cancel button: Cancel, Done | Pairing sheets |
