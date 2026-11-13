# Contigua — UX spec (v0)

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
| **QR code** | "Pair with QR" shows a QR (`contigua://pair?c=<clientId>&n=<mac name>&k=<64-hex one-time key>`) | **Scan QR** → the app registers that client + key with the server → done (scanning is the consent; no code, no Allow) |
| **Manual** | "Connect manually…" → host + port fields → then the same comparison | same as Automatic |

Automatic flow detail (numeric comparison, nothing is typed): the Mac sheet reads **"Pair with *phone name*"**, the code in
large monospaced digits grouped "123 456", and the line **"Tap Allow on your phone if it shows the same code."** with **Cancel**.
The person compares the two screens and taps **Allow** on the phone; that is the only step. The sheet then shows "Pairing…" and
a checkmark. States: *Contacting *phone name*…* (before the code arrives) · *Pairing…* · "Pairing was denied on the phone." ·
"Nobody tapped Allow in time. Try again." (the phone gives up after 120 s) · "Couldn't reach *phone name*. Try again." ·
in the phone's 30 s cooldown, "Wait a moment, then try again." with a small secondary "23 s" counting down (Try again is
disabled until 0, and nothing retries by itself). The Mac waits
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
Find Apps · Framed / Compact / Immersive (⌥⌘F cycles) · Hide Controls › (enabled only while the window is Immersive; disabled, never hidden, otherwise) · Show Touches · Live Text · Icon Size › (75 %, 100 %,
125 %, 150 %, the current one checked; 125 % until the person picks another) · Density › (Default, the other percentages, Larger ⌘+, Smaller ⌘−, Actual Size ⌘0) · the
system's Enter Full Screen (fn‑F). **Phone** holds Phone Mirror ⌘P · Open <App> on Mac ⇧⌘C · Turn Off Phone
Screen · Do Not Disturb · Ring Phone / Stop Ringing · Install APK…. **Navigate** holds Back · Home · Recents, **Window** the
standard items, the system's window group and Next Window ⌘`, and **Help** is empty (there is no help book). **File** is
Add Phone… ⇧⌘N · **New <App> Window** ⌘N · Close ⌘W · Close All ⌥⌘W. The Dock icon's own menu (a right-click on it)
offers **Find Apps** and **Phone Mirror**, with Phone Mirror disabled while the phone is away. The items that act on a stream
window — Framed/Compact/Immersive, Hide Controls, Show Touches, Live Text, Density and Navigate's three — are off and disabled whenever
a window that is not a stream window (the Deck, Settings, a sheet) has the keyboard, and unchecked where they carry a mark.
A control that cannot
work is disabled, never hidden.

1. **Deck** (the only main window; closing it hides it, the Dock icon and ⌘K bring it back; ⌘F focuses the search
   field and selects its text). What it shows is chosen by what this Mac remembers:
   - **Welcome** (first run only): glass card over a soft gradient. App icon, "Contigua", "Your Android apps, on your
     Mac.", three compact steps (*Install Contigua on your phone* · *Start Shizuku* with "How?" · *Be on the same
     Wi-Fi*), primary **Find my phone**.
   - **Nearby** (nothing paired yet; also the "Add a phone" sheet): phones on the network as glass rows (name, model,
     **Pair**), footer **Pair with QR** · **Connect manually…**. Empty: spinner "Looking for phones on this network…" +
     "Make sure Contigua is open on your phone." Pairing runs in sheets: the 6-digit code to compare (inline errors, Cancel) or the QR
     (countdown, success check).
   - **Phone** (a phone is paired, including while it is away): toolbar with one group packed at the left — the traffic
     lights, the connection chip (green dot · lock while locked · battery / Connecting… / Reconnecting… / Offline /
     Pair again) and the phone's name (its nickname when one is set; with 2+ phones that name is a menu of the
     remembered phones, the one in use checked, and **Phone Settings…** opens Settings) — and one at the right: **Phone** button, the Settings gear (⌘,), then the
     search field (macOS keeps a toolbar search at the trailing end); nothing floats in the middle between them.
     The start page, top to bottom: **Open on this Mac** (the apps with a Mac window, front window first; a click
     raises it; a small Mac-window mark on the tile), **Pinned** (up to eight, kept on this Mac per phone, from the
     tile's context menu **Pin** / **Unpin**), then **All Apps** sorted by name. Every section sits on All Apps'
     columns and its header starts at the grid's edge; an empty section is not shown, so with nothing pinned and no
     window the page is the plain grid. **Single click opens, arrows move across the sections as one page, ↩ opens,
     esc clears; typing filters and the first match is selected; ⌘1–⌘9 open the first nine visible tiles in reading
     order; ⌘F puts the keyboard in the search field.** While searching, only the results are shown. Pressing or
     dragging along the A–Z rail lights that letter's All Apps tiles — a slight lift and a semibold name — while the
     other All Apps tiles fade to 30 %; a click holds it for a second, a press or a drag ends it when the button comes
     up, and hover alone lights nothing. The Open on this Mac and Pinned rows stay as they are. An empty letter lights
     the letter it would jump to.
     The grid is there at launch from the last session and is dimmed — the sections with it, as one page — while the phone is away. A problem is one banner
     line with at most one button (Try now / Pair again); while the phone is away the banner and the chip's help tag say
     when it was last seen. A phone that no longer trusts this Mac, or whose connections
     switch is off, keeps its banner until it is fixed: it has no close control, it survives a relaunch, and the
     connections-off banner adds one line naming the switch on the phone.
2. **App windows**: three styles, View ▸ **Framed** / **Compact** / **Immersive** (plain radio items, no section header; ⌥⌘F cycles
   Framed → Compact → Immersive), remembered per app: **Framed** (default) is the stream inside a real frame on all four sides — 38 pt
   above and 5 pt on the other three sides, a 21 pt window corner radius and a 12 pt picture radius, the system's dark or light material, a
   hairline and a lighter rim, the app's name and phone in the system label colour, the traffic lights and our controls in the taller bar
   (the measured numbers and the reference are in DESIGN.md); **Compact** is the stream plus a permanent 28 pt bar
   above it — the stream's own top rows mirrored there under a 30 pt progressive blur and a 14 % tint, the app's name and the phone's as
   "<App> (<phone>)" centred on that line (the phone's name alone in the Phone Mirror, and for a link or a handoff only once the phone
   reports an app), the traffic lights on that line; **Immersive** is the old borderless style — the window is exactly the stream, no
   bar and no borders, and the traffic lights and our controls live on a clear-glass pill at the stream's top-left that a 350 ms rest in a
   72×32 pt hot zone brings in and a 600 ms absence takes away (Always Visible keeps it up). Switching grows or shrinks the window by the
   difference between the two insets, the stream keeps its place. Native full
   screen is macOS's own View item (**Enter Full Screen** / **Exit Full Screen**, fn‑F, ⌃⌘F or the green light); the stream fills the
   screen in every style. In Framed and Compact a translucent 28 pt acrylic bar holds our traffic lights, the title and our controls
   without the mirror; in Immersive the system's own revealed title bar carries the title and lights, as it did before the three styles. The bar
   stays hidden until the pointer reaches the top edge and rests there (350 ms by default; **View ▸ Hide Controls** and Settings →
   General → **Reveal controls after** pick Instantly, Short or Long) and slides in; it slides away 600 ms after the pointer leaves it, or
   goes at once on leaving full screen. **Always Visible** keeps it up; picking it never changes a window's style. A click at the top
   edge before the bar shows is still the app's own touch. **Hide Controls** and its items are disabled outside Immersive. The stream's own edges resize the window. The trackpad works like a touch screen: a two-finger scroll is a finger dragging
   (Android's own scrolling, overscroll and fling), a pinch or rotate is two fingers around the pointer, the mouse wheel stays a wheel, the mouse's side
   **Back** button (button 3) sends Android Back to that window once per press — never repeated while held, nothing on release, and never a touch —
   while **Forward** (button 4) does nothing for now, and three or more
   fingers stay the system's; Back also arrives as a right click, ⌘[, or a swipe-back event from mouse utilities (Logi Options+), once per gesture.
   **View → Show Touches** (on by default on a Mac with a trackpad) draws a dot where the phone is being touched by a trackpad
   gesture — touches only, never the pointer's hover — and the Compact bar above the stream never shows it: the bar mirrors the
   video, not the overlay.
   The pointer over the stream is a mouse over Android: hover highlights, tooltips and hover menus react as they do with a real
   mouse, and the pointer leaving the video (or the window), a click, a drag or the window losing focus ends the hover before the
   touch. Settings → Input → **Hover over Android apps** turns it off.
   New windows cascade (never on top of the Deck) and remember their frame. While the connection is down the window shows
   its disconnection screen — the last frame under one acrylic, the app's icon, "Reconnecting…" and "Waiting for <phone>…",
   then "Phone offline" after 15 s — and stays open.
   While an app window is open, its app appears in the Dock and ⌘-Tab as "App (Nickname)" (a link window as the app that
   displays the link; the phone mirror as nothing). It arrives on its own, ends when the window closes, and **Options → Keep in Dock**
   makes it permanent ("Add to Dock" in the app's context menu does the same by hand; Settings → General switches it off).
   The same menu's **Add to Applications** puts that one app in Applications as a real Mac app — Launchpad, Spotlight
   and other launchers list it — and **Remove from Applications** takes only that shortcut away; the phone's page can do it for
   every app at once (**Save all apps as shortcuts**).
3. **Menu bar panel**: a click on the status item opens a Control Center-style card — the phone's symbol, its
   name (with two or more phones the name is a checkmark pop-up and the card keeps its width), the link as a dot plus
   words, a lock while it is locked and the battery; away from the phone, the last-seen line. Below: one full-width
   **Sound** module (speaker, "Sound", the phone's %, the volume slider), the 2×2 modules **Focus** (Do Not Disturb /
   Off), **Ringer**, **Ring Phone** / **Stop Ringing** (Plays a sound / Ringing), **Turn Off Screen** (Screen on /
   Screen off), **Now playing** with the chosen app when several apps play, one **Live** row per notification each
   with its own **Dismiss** (it hides that row on the Mac only), **Open <App> on Mac** ⇧⌘C only while the phone
   reports an app in front ("Open Current App on Mac" with a generic icon when the app list does not know it), and one
   **WINDOWS** row (**Phone Mirror** ⌘P · **Apps** ⌘K). **Install APK…** is not on the card: it stays in the Phone
   menu, the Deck's drop and Finder's Open With. A **gear** at the card's top-right opens the icon's own menu.
   When the phone no longer trusts this Mac (or its connections switch is off) one banner row sits under the header
   with the same sentence the Deck shows and its **Pair again** action; it cannot be closed. **Ringer** opens
   Ring / Vibrate / Silent with the current mode checked; the volume follows the pointer while it is dragged. A
   control that cannot work is dimmed as a whole (icon, title and its short second line, e.g. "Open Mirror first"),
   never accent-tinted; the full sentence is its help tag and VoiceOver hint ("Open Phone Mirror first."). While the
   phone is away the Sound module shows the one group reason "Connect your phone to use these." and the four modules
   dim with no line of their own. The card opens with its focus ring on **Focus**, with or without an AI agent
   connected, and never on the gear, the phone pop-up or **Disconnect**. The Deck's status pill opens the same card
   in a popover, without the gear.

   The status item's **secondary click** (a right-click, or ⌃-click) opens the app's command menu under the icon:
   **Settings…** ⌘, · **About Contigua** · **Quit Contigua** ⌘Q, with a separator before Quit. The card closes
   first if it is open. The card's **gear** opens that same menu, anchored under the gear rather than under the status item, so
   both are one path; its help tag is
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
   a header with its icon, name, state and **In Use** or **Use This Phone** (**Pair Again…** when it no longer
   trusts this Mac, also beside **In Use**), then the plain sections **Phone** (**Model**, **Rename…**), **Notifications** (**Share notifications
   and Now Playing**, **When I click a notification** with **Open on this Mac** / **Open on the phone** / **Do
   nothing**, and **Muted apps** with its count, a search field and a **Muted** checkbox column), **Applications**
   (**Save all apps as shortcuts**, with the sentence that it gives every app of that phone a real Mac app in
   Applications — Launchpad, Spotlight and other launchers — and that off removes only the ones this switch made),
   **Screen** (**Keep the phone screen off until I turn it on from the Mac**) and **Forget** (**Forget This
   Phone…** alone at the end). The window title is the open page's name, and that is the only other place a phone is named: no
   section heading carries it. ⌘, reopens the last page (the in-use phone, or **General** with no phones); the
   sidebar has the keyboard, ↑/↓ move between rows and Tab moves into the page; **Add Phone…** opens the
   pairing sheet without moving the page. Any phone is one click away and its settings are editable whether or
   not it is in use (they apply on its next connection); forgetting the open phone opens the phone in
   use, else **General**. Muted apps lists the apps this Mac already has for that phone, muted first, with a
   mark on apps that sent a notification this session, "System UI" for `com.android.systemui` and the package
   name for an app with no name. When the phone has not been granted notification access, the page says
   **Allow notification access on the phone.** under the switch. When this Mac's own notifications are off for
   Contigua, it says **Notifications are turned off for Contigua in System Settings.** with **Open System
   Settings** and **Check Again**. The Dock shims rebuild on a rename. Nothing else.

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
      how ("Open Contigua on your Mac and pick this phone — it stays locked."),
      **Get started**.
   2. *Shizuku* — live status row: Not installed (button **Get Shizuku**) → Not running
      (button **Open Shizuku** + 3-line "How to start it" with wireless debugging) →
      Permission needed (button **Allow**) → ✓ Ready. Auto-advance on ready.
   3. *Notifications* — needed for pairing prompts → **Allow** (POST_NOTIFICATIONS);
      also offers **Keep running in the background** once, with one line why (the home's
      own words for that switch).
   4. *Pair your Mac* — "Open Contigua on your Mac. It will find this phone." +
      **Scan QR code** (outlined) — completes on first successful pairing.
2. **Home**:
   - Big status card: **Ready** · "Visible to Macs on *Wi-Fi name*" / **Connected to
     *Mac name*** · "*N* windows open" / **Shizuku not running** (with fix button), or
     **Shizuku isn't installed** with **Get Shizuku** when the app is absent. When
     Shizuku runs but its shell service keeps timing out the card says
     **Shizuku isn't answering** · "Contigua can't reach Shizuku. Try again
     restarts Contigua's connection." with **Try again**. While
     a pairing prompt waits and this phone's notifications are off the card says
     **Notifications are off** · "Allow notifications so your Mac can ask to pair."
     with **Allow** (the runtime permission). With the background switch off the
     card still says **Ready**, with
     "Stops when you close Contigua from recent apps." — information, not a
     warning, and no button.
   - Switch: "Keep running in the background". On: the service survives the app
     being swiped away from Recents and starts at boot. Off: it runs only while
     Contigua's task is open, then stops (and closes its listening socket)
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

The loading state (L1 "Splash"): the app's large icon centred on the window's
dark background, a 2 pt accent line sweeping under the window's top edge
(indeterminate, never a made-up percentage) and the title **<App> — opening on
<phone>**.

The cover is the whole window in every style: one sheet from the top edge,
with the traffic lights and our controls on the top row, and the icon, title and
line where Compact puts them. The style's bar — its mirror, blur and haze — or
frame — its material and rim — arrives with the first frame, so the loading
state looks the same in Framed, Compact and Immersive; the stored style does not change.

- 0–5 s: the icon, the line and the title.
- 5–20 s: the same, plus **Taking longer than usual** and **Cancel**. Cancel
  closes the window and cancels the open on the phone.
- The phone's refusal, or 20 s without a frame: the icon greys out; one sentence
  **<phone> can't open <App>.** and, when the phone's error code has one, a
  reason line (**The app is disabled on the phone.**, **The app isn't installed
  any more.**); **Close** only. No **Try Again**: asking again cannot work.
- The Phone Mirror wears the same cover: **Phone — opening on <phone>** and
  **<phone> can't open the phone screen.** A phone that cannot capture its
  screen (`mirror_unavailable`) puts its sentence on the reason line:
  **This phone can't share its screen with Contigua.**
- The cover is a frozen mode: no input reaches the phone, and the bar's
  phone-side controls are dimmed. The "Not responding" watchdog runs only after
  the first frame.

### A second window of one app

Some apps can run more than once on the phone (the phone says which). **New <App>
Window** (⌘N, File) opens one more window of the app in front; every other way in
— the Deck cell, the Dock, Spotlight, a notification, a shortcut without the
new-window argument — raises the window the app already has. A window of an app
with two or more open is named **<App> — <task label>**; a lone window keeps
**<App>** and is named <App> (<phone>).

- **Next Window ⌘`** brings the next window of the app in front, wrapping; it
  sends nothing to the phone, and with one window it does nothing.
- The Dock app's and the Deck cell's menus list **New <App> Window** and, below
  it, one item per open window, the front one checked; picking one raises it.
- When the app cannot open another, the New item says why in its help tag:
  **<App> opens one window at a time.**, **Close a <App> window to open another.**
  (the phone's limit, four by default) or **Opening on your phone…**; while the
  link is down it reads **Reconnecting…**, then **Phone offline**. A disabled item
  sends nothing.
- A phone that refuses one anyway closes the window that asked and the Deck says
  **Close a <App> window to open another.**

### Installing an app

- Phone ▸ **Install APK…** (or Open With / the "Install on Phone" Service) shows
  the install in the Deck's pill: **Sending x.apk… 40 %**, then
  **Installing x.apk…**, then the phone's own result.
- A phone that is paired but away: **Waiting for your phone…** with **Cancel**,
  and the sentence **Connect your phone to install apps on it.** (only with no
  phone paired at all: **Pair a phone to install apps on it.**) The install runs
  by itself when the link returns; Cancel drops the file.

### The Phone Mirror's bar from the keyboard

The window's keys are the phone's: Tab types on Android, Esc is Back, ⌘F is
Find in the app. The bar's four buttons get their own way in, so a person who
cannot use a pointer can reach them:

- **⌃Tab** moves the keyboard into the bar: the first button (Back) takes a
  focus ring. Press it again, or **Esc**, to give the keyboard back to the
  picture; nothing is sent to the phone either way.
- **←** / **→** (or Tab / ⇧Tab) move between the bar's enabled buttons, wrapping
  at both ends.
- **Return** or **Space** presses the focused button — the same action a click
  runs.
- A frozen picture (a cover, or Live Text) has no enabled bar button, so ⌃Tab
  has nowhere to go and the keyboard stays on the phone.

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
| ⌥⌘F | Cycle the window style (Framed → Compact → Immersive) | View |
| ⌃Tab | Move the keyboard into the Phone Mirror's bar; ←/→, Tab, Return and Esc act there | Phone Mirror |
| ⇧⌘T | Live Text | View |
| ⌘+ | Larger: the Deck's icon size, or the window's density | View, Deck |
| ⌘− | Smaller: the Deck's icon size, or the window's density | View, Deck |
| ⌘0 | Actual Size: the Deck's icon size (back to its default, 125 %), or the window's density | View, Deck |
| ⌘P | Phone Mirror | Phone |
| ⇧⌘C | Open <App> on Mac | Phone |
| ⌘[ | Back | Navigate |
| ⇧⌘H | Home (phone mode) | Navigate |
| ⌘↑ | Recents (phone mode) | Navigate |
| ⌃⌘F | Enter / Exit Full Screen (one hidden View item; fn‑F is the shown system shortcut) | View |
| ⌘N | New <App> Window: one more window of the key window's app | File |
| ⌘` | Next Window: the next window of the key window's app, wrapping | Window |
| ⌘F | Find in the Deck: focus and select the search field (the field's help tag names the key) | Deck |
| ⌘1–⌘9 | Open the first nine visible tiles in reading order (the sections included) | Deck |
| ⌘, | Settings | Icon menu, Deck |
| ⌘Q | Quit Contigua | Icon menu, app menu |
| ↩ | Default button: Find my phone, Try again | Deck, pairing sheets |
| ⎋ | Cancel button: Cancel, Done | Pairing sheets |
