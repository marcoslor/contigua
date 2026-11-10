# macOS app — redesign spec

Companion to [mac-audit.md](mac-audit.md) (the problems, `A##`), [../UX.md](../UX.md) (principles,
copy rules) and [../DESIGN.md](../DESIGN.md) (tokens, Liquid Glass rules). This spec is what
Phase B implements. Where it overrides UX.md/DESIGN.md it says so (§9). Target: macOS 26,
SwiftUI + Liquid Glass, system frameworks only. Wire protocol unchanged.

## 0. Direction in one paragraph

One home window (the **Deck**) that is *always the phone you own*, not a state-switching
pane. A remembered phone is shown immediately, from cache, and reconnects silently; the user only
ever sees a pairing screen when they have no phone or the phone rejected the key. The connection
is a small status chip, never a screen. Errors are one sentence, in place, and never loop. Pairing
is a short, user-driven flow (Nearby → code or QR) in sheets. App windows stay content-only. All
connection logic moves out of the views into one testable `ConnectionController` with a pure state
machine (§4), which also fixes the root causes of A01–A03.

## 1. Principles (extends UX.md)

1. **Only what's necessary.** No raw ids, ports, reason codes or "Nearby"/"Paired" jargon on primary surfaces.
2. **The phone is remembered.** The app never shows a first-run screen to someone who has paired.
3. **Status is a chip, not a screen.** A dropped link dims the grid and shows "Reconnecting…"; it
   never replaces the content, never closes windows.
4. **One line, one place, once.** One banner at a time; the same cause updates in place; nothing flashes.
5. **Nothing loops visibly.** Retries are invisible until 15 s of failure, then one calm "Offline" state.
6. **User-driven pairing only.** The Mac never starts a pairing handshake (and so never makes the phone
   prompt) unless the user pressed Pair / showed a QR.
7. **Glass on the floating layer only** (toolbar, chips, banners, sheets' controls); content (grid, rows) is plain.

## 2. Information architecture and window inventory

| Window | Kind | Opens | Notes |
|---|---|---|---|
| **Deck** | SwiftUI `Window("PocketDeck", id: "deck")` | launch; Dock click; ⌘K; menu-bar "Open PocketDeck" | The only main window. Default 760×600, min 560×420, single instance. Closing hides it; the app keeps running. |
| **App window** | AppKit `NSWindow` per stream (`AppWindowController`) | click an app in the Deck / ↩ | Content only (§3.7). |
| **Phone Mirror** | AppKit `NSWindow` (`PhoneWindowController`) | Deck toolbar **Phone**, ⌘P | Aspect-locked, glass hover header with Back/Home/Recents. |
| **Settings** | SwiftUI `Settings` scene | ⌘, | Tabs General · Devices. |
| *Sheets over the Deck* | SwiftUI `.sheet` | | Nearby (Add phone), Code, QR, Manual connect. |
| **Menu-bar item** | SwiftUI `MenuBarExtra` (`.window`) | always (toggle in Settings) | A Control Center-style panel: the phone's controls, live notifications, window actions, Settings/Quit (§3.8). |

There is no separate Welcome window and no floating launcher panel in v0 (§9): both are states of the
Deck. The Deck has three content modes, chosen **only** by what the profile remembers:

```
profile has no remembered phone, first run ever      → Welcome   (hero + "Find my phone")
profile has no remembered phone, after Welcome seen  → Nearby    (list of phones, the pairing entry point)
profile has ≥1 remembered phone                      → Phone     (header + app grid, §3.3)
```

"Remembered" = a `RememberedPhone` record (§6.3) exists. A record whose key is missing/rejected is
still "remembered"; it renders the Phone mode with the `needsPairing` banner (**Pair again**), so
losing a key never looks like a fresh install (A04, A19).

## 3. Screens

Tokens, radii, type, motion are DESIGN.md §1 unless stated. All screens must work in light and dark
and with Reduce Transparency / Increase Contrast (system fallbacks only).

### 3.1 Welcome (Deck, first run only)

- Window background: `containerBackground(for: .window)` with the brand gradient (DESIGN.md tokens),
  toolbar hidden. Content frame 560×520 (window `contentSize` for this mode; the Deck animates to its
  resizable size when it leaves Welcome).
- Centered glass card, 440 wide, padding 32, `glassEffect(.regular, in: .rect(cornerRadius: 28))`,
  VStack spacing 24: app icon 96 · "PocketDeck" `.largeTitle.bold()` · "Your Android apps, on your Mac."
  `.title3 .secondary` · three step rows (`iphone.and.arrow.forward` "Install PocketDeck on your phone",
  `bolt.badge.checkmark` "Start Shizuku" + `Link("How?")`, `wifi` "Be on the same Wi-Fi") ·
  **Find my phone** `.glassProminent .controlSize(.large)`, full width.
- Action → Nearby (cross-fade, 0.3 s `.smooth`). ↩ triggers the primary button.

### 3.2 Nearby (pairing entry point)

Shown as the Deck content when nothing is remembered, and as a **sheet** (title "Add a phone",
size 480×460) from Settings ▸ Phones ▸ **Add Phone…** and ⇧⌘N when a phone is already remembered.

- Header: "Nearby" `.headline`. Body: list of phones from Discovery, **deduplicated by TXT `id`**
  across interfaces; a result without a TXT `id` is ignored until one arrives (A10). Sorted by name.
- Row (`glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))`, ≥ 52 pt): `iphone.gen3`
  22 pt · VStack(name `.body`, model `.subheadline .secondary`) · Spacer · **Pair** `.glassProminent
  .controlSize(.small)`. A phone that is already remembered shows "Paired" (`.secondary`) instead of the button
  and is not pairable here (a rejected one shows **Pair again** `.orange` text, with a
  **Pair Again…** button that opens the pairing sheet).
  Whole row is also clickable (= Pair). No device ids.
- Footer (`GlassEffectContainer`): **Pair with QR** (`qrcode`) · **Connect manually…** (`network`), `.glass`.
- **Empty/searching:** centered `ProgressView().controlSize(.small)`, "Looking for phones on this
  network…", `.callout .tertiary` "Make sure PocketDeck is open on your phone." Appears 0.4 s after the
  view (no flash for phones that are found instantly). After 15 s with nothing, line 2 becomes
  "Still nothing? Try Pair with QR." (no error).
- **Browse failure** (Local Network denied: `NWBrowser` `.failed`/`.waiting(PolicyDenied)`): one red-less
  `.callout` line replacing the empty-state text: "PocketDeck needs Local Network access. Open System
  Settings → Privacy & Security → Local Network." with a **Open Settings** `.glass` button (opens the pane).
- Tapping **Pair** → §4.3 (code flow). The sheet-hosted variant dismisses itself on success.
- Esc closes the sheet variant.

### 3.3 Phone mode (the Deck, daily use)

Layout: standard titled window with unified toolbar (macOS 26 glass toolbar items; no custom
backgrounds), window background default.

```
┌ ● ● ●   Pixel Walk                         [● Connected · 🔒 87%]  [📱 Phone]  [🔍 Search apps ⌘K] ┐
│ ┌ banner (only when needed) ───────────────────────────────────────────────────────────────────┐ │
│ └──────────────────────────────────────────────────────────────────────────────────────────────┘ │
│   ▢ Camera  ▢ Chrome  ▢ Gallery  …   (D grid, 96×108 cells, 64 pt icons, 16 pt pitch)          │
```

- `navigationTitle(phone.name)`; no subtitle. Toolbar: `ToolbarItem(placement: .status)` **chip**;
  `ToolbarItem(.primaryAction)` **Phone** button (`iphone.gen3`, label "Phone"); `.searchable(text:
  placement: .toolbar, prompt: "Search apps")` + `.searchFocused($searchFocused)`. The chip is a button that opens the
  shared phone controls (the menu bar panel's `PhonePanelView`) in a `.popover`.
- **Chip** (one capsule, `.caption`, system glass via toolbar): dot (6 pt `circle.fill`) + text,
  then secondary details when connected.

  | Link | Dot | Text | Details |
  |---|---|---|---|
  | online | green | (dot alone; the title names the phone) | `lock.fill` only while locked · battery glyph by nearest quarter + "87%" (`.monospacedDigit()`, red below 13 %); tooltip "Connected, phone locked, battery 87%, charging" |
  | connecting (no success this run yet) | secondary | Connecting… | — |
  | reconnecting (was online this run) | orange, `.symbolEffect(.pulse)` | Reconnecting… | — |
  | offline (≥ 15 s) | secondary | Offline | — |
  | needsPairing | orange | Pair again | — |
  | pairing | — | chip hidden (the sheet is up) | |

- **Grid (D):** `DeckGridLayout` places every cell from the width of the pass that draws it, so a live resize or a
  zoom cannot draw a clipped edge column. At 100 % a cell is 96×108, its icon 64×64 (the shared `PhoneAppIcon` in the
  macOS shape, docs/design/dock.md §Icons), with an 8 pt icon-label gap, a fixed 16 pt column gap and row spacing, a
  24 pt vertical inset and a 16 pt hover corner. The block is centred, capped at 880 pt and reserves the rail's 44 pt
  on its trailing side (5 columns at 640, 6 at 760, 8 at 1000 and wider). The cell and icon keep one size at every
  window width: a resize only changes the column count, and past the 880 pt cap the block keeps its eight columns and
  grows its margins instead of scaling a tile. The rail's column starts 18 pt right of the grid's right edge at every
  icon size and width. Label `.caption` 1 line `.truncationMode(.middle)`. Hover
  `.fill(.quaternary)`; keyboard/mouse selection `.fill(Color.accentColor.opacity(0.22))`, both
  `RoundedRectangle(cornerRadius: 16)`. **Single click opens** (↩ opens the selected one, or the first match when none
  is selected). **⌘+ / ⌘− / ⌘0** scale the whole grid (cell, icon, gaps, insets and the 880 pt cap) through
  0.75 / 1 / 1.25 / 1.5 on the Deck, stored as `deckZoom`; the keys do nothing in another window. A **title-bar
  double-click or the green button** takes the system's standard frame — the screen's visible frame — and a second
  zoom returns the frame it came from (DECK-24); the zoom never changes the icon size.
- **A–Z rail (D):** the Deck's trailing edge carries one 16 pt column, 8 pt from the edge: A–Z then `#`, 9 pt letters
  on a 12 pt pitch, the current letter accent and semibold, empty letters dimmed at 35 %. It appears only when the
  search field is empty and there are at least 30 apps. Clicking or dragging a letter scrolls to its first app; an
  empty letter skips forward to the next one with apps. The accent lights the letter the jump landed on and keeps
  it until the grid is scrolled by other means (the wheel, the trackpad, the scroll bar or the keys) or another
  letter is picked; otherwise it is the last section start in the top visible row, read from
  `visibleRect.minY + contentInsets.top`.
- **Data:** apps and icons come from `AppsCache` (§6.3) first, then refresh from the phone, so the grid
  is populated at launch before the first connection. Offline/reconnecting: grid `.opacity(0.5)`,
  `.allowsHitTesting(false)`.
- **Loading** (no cache, apps not yet received): 12 placeholder cells `.redacted(reason: .placeholder)`.
- **No matches:** centered "No apps match “query”" `.callout .secondary`, height 120.
- **Banner** (§4.4): `Label(msg, systemImage:)` `.callout`, glass capsule/rect (cornerRadius 14, padding 12), full
  width minus 16, below the toolbar, with at most one trailing button (`.glass .controlSize(.small)`). Appears
  with `.transition(.opacity.combined(with: .move(edge: .top)))`. Only one banner exists at a time.

  | Cause | Text | Button |
  |---|---|---|
  | offline (≥ 15 s) | "Can't reach *name*. Check that it's on the same Wi-Fi." | Try now |
  | busy | "Another Mac is connected to *name*." | Try now |
  | needsPairing | "*name* no longer trusts this Mac." | **Pair again** (`.glassProminent`) |
  | versionMismatch | "*name* runs an incompatible version of PocketDeck." | — |
  | Local Network denied | as §3.2 | Open Settings |
  | open failed (`launch_failed`) | "Couldn't open *app* on the phone." (auto-clears 5 s) | — |

- **Phone** button: opens the Phone Mirror (disabled unless online).
- **No selection of phones here.** Switching/adding phones is in Settings’ sidebar (§3.6).
- Window title bar has no document icon. Frame autosave `deck`.

### 3.4 Code sheet

`.sheet`, width 400, padding 32, VStack spacing 24. **Title:** "Pair with *phone name*"
`.title3.weight(.semibold)` (the name comes from the Nearby row, so it is known *before* `welcome`; fixes A05).

- Numeric comparison, nothing is typed: the code the phone announced in `pair.code_shown`, large and monospaced, grouped
  "482 913" (DESIGN.md "Pairing-code sheet"). No fields, no boxes.
- Below it, one line (`.callout`), exactly one of:

  | Pairing state | Line | Code |
  |---|---|---|
  | `contacting` | spinner + "Contacting *phone name*…" `.secondary` | hidden |
  | `comparing(code)` | "Tap Allow on your phone if it shows the same code." `.secondary` | shown |
  | `verifying` (`pair.ok` received) | spinner + "Pairing…" `.secondary` | hidden |
  | `denied` (`error{pair_denied}`) | "Pairing was denied on the phone." `.red` | hidden; **Try again** `.glassProminent` |
  | `timedOut` (`error{pair_timeout}`, the phone's 120 s) | "Nobody tapped Allow in time. Try again." `.secondary` | hidden; **Try again** `.glassProminent` |
  | `unreachable` (connect failed or the connection dropped) | "Couldn't reach *phone name*. Try again." `.secondary` | hidden; **Try again** `.glassProminent` |

  The Mac never gives up on its own while the code is up (it keeps a 125 s backstop, 5 s past the phone's window).
- **Cancel** `.glass` (Esc) always present except in `verifying`; it aborts the session cleanly (no
  reconnect) and closes the sheet.
- Success: the code cross-fades to `checkmark.circle.fill` 64 pt `.green` `.symbolEffect(.bounce)`, sheet closes
  after 0.6 s, the Deck is already in Phone mode behind it. ↩ never submits partial codes.
- **Try again** = new handshake (§4.3), user driven, so the phone prompts once per press.

### 3.5 QR sheet, Manual sheet

**QR sheet:** as DESIGN.md (width 360, QR 220×220 on a white tile in both appearances, countdown
"Expires in 4:59" `.monospacedDigit()`), with these changes:
- It probes **only phones that are not remembered by this Mac and that are not busy**, one attempt per phone
  per 4 s, each probe closed 4 s after it started unless it authenticates (A13). Probing stops the instant
  one succeeds. (Implementation: `QRPairingModel`, §6.)
- Status line under the QR: "Waiting for your phone…" only. No counts.
- Success: QR cross-fades to green checkmark (as DESIGN.md), sheet closes after 0.8 s, Deck shows the phone.
- Expiry: QR `.blur(radius: 8)` + **Show new code** `.glassProminent`.
- **Cancel/Done** `.glass`, Esc.

**Manual sheet** ("Connect manually…", width 400): two fields — "Address" (placeholder `192.168.1.20`) and "Port"
(placeholder `47000`, `.monospacedDigit()`) in a `Form`, **Connect** `.glassProminent` (↩, disabled until
valid), **Cancel** `.glass`. Failure to reach: one `.red` `.callout` line under the fields, "Couldn't reach
that address." (no codes). On success it continues into the code sheet (§4.3). This is the only place "port" appears.

### 3.6 Settings (⌘,)

`Settings { SettingsView }` draws a `NavigationSplitView`: a 240 pt source-list sidebar and a 480 pt detail
column in a 720 × 560 window (the smallest supported screen is 1280 × 800; a taller page scrolls). The sidebar's
first group is **Phones** — one row per remembered phone (`DeviceGlyph`, name, a dot plus the state's words and,
while it is not connected, when it was last seen; a checkmark on the in-use phone) then **Add Phone…** — and its
second group is **This Mac**: **General**, **Input**, **Automation**. The detail shows the chosen page with
`.formStyle(.grouped)`; the window title is that page's name.

- **A phone's page** (`PhoneSettingsPage`): a header with the icon, name, state, In Use or **Use This Phone**
  (**Pair Again…** for a phone whose key is gone), then the plain sections **Phone** (model, **Rename…**),
  **Notifications** (**Share notifications and Now Playing**, **When I click a notification**, **Muted apps**),
  **Screen** (**Keep the phone screen off until I turn it on from the Mac**) and **Forget**
  (**Forget This Phone…**, alone at the end). No section heading carries the phone's name.
- **General** and **Input** carry the toggles the app-wide settings bind; **Automation** carries the MCP server's
  gate and client snippet.
- **Add Phone…** opens the Deck's one add-phone sheet and leaves the page where it was. **Forget** = delete the
  pin (profile-scoped), `RememberedPhone`, cached address, Spotlight items and apps cache, after a confirmation
  naming the phone; if it was the open page the next phone (else General) takes the detail, and if it was the
  active phone its windows close and the next remembered phone is activated.
- One selection state (`SettingsSelection`) serves the window: it is stored per profile, so ⌘, reopens the last
  page. The sidebar takes the keyboard; ↑/↓ walk the rows and Tab leaves for the detail.

### 3.7 Stream windows (AppKit)

- `NSWindow` styleMask `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`,
  `titlebarAppearsTransparent = true`, title = app label (no icon, hidden: Window menu only). Frameless like Apple's iPhone Mirroring: at rest only the
  stream with rounded corners and its shadow, the window's sides and bottom being the stream's edges; the window carries a hidden 52 pt band above
  the stream, which fades in as glass (traffic lights where a standard toolbar window has them) at once on hover and out as soon as the pointer
  leaves, never covering or moving the stream or resizing the virtual display
  (DESIGN.md "App windows").
- **Placement (A09):** restore the frame saved for that package (`setFrameAutosaveName("app.<pkg>")`); otherwise cascade
  from the last opened stream window (`cascadeTopLeft(from:)`, 28 pt steps), never `center()` over the Deck. New
  windows become key but do not hide the Deck (they open on the Deck's screen, offset right of it when it fits).
- **Link-down state:** the layer keeps its last frame; the **disconnection overlay** (DESIGN.md "Disconnection
  overlay": one acrylic over the whole window, the window's icon, "Reconnecting…" and "Waiting for <phone>…") comes up
  1 s after the loss and reads "Phone offline" at 15 s; a reconnect takes it away. Input is dropped while down (no
  queueing). Windows are re-opened on reconnect with the existing `reopenAll()` (unchanged protocol behaviour).
- Unchanged: `VideoLayerView`, `AVSampleBufferDisplayLayer`, `InputMapper`, `DebugInput`, gestures, resize debounce,
  pause/resume, density, edge swipe.

#### Bar controls (glass capsules)

The window kind's actions and the Live Text button sit in Liquid Glass capsules at the bar's right end, like a macOS 26
toolbar item group:

- one capsule for the phone navigation trio (Back · Home · Recents), one for Live Text, and one per other group (the
  camera window's switch). Buttons in a capsule keep the 32×28 pt hit area; capsules are 28 pt tall (capsule radius),
  symbols 14 pt medium, and capsules are 6 pt apart. In immersive the same capsules ride the dwell pill; in full screen
  there is no bar or pill, as before.
- symbols (same meaning, more Apple-like): Back `chevron.backward` · Home `house` · Recents `rectangle.stack` · Live
  Text `text.viewfinder` (Apple's own Live Text symbol) · camera switch `arrow.triangle.2.circlepath.camera`. Tooltips
  are unchanged.
- symbols use the label colour the glass provides, so they stay readable over a white and over a black frame.
- **Live Text freezes the controls.** While a window is in Live Text mode every bar action except Live Text itself is
  disabled (dimmed, no hover, no action, accessibility "dimmed"), and the phone navigation shortcuts (⌘[, ⇧⌘H, ⌘↑) do
  nothing, because they would drive the live phone behind the frozen picture. Leaving the mode re-enables them.
  "Move Phone App to Mac" is left alone: it opens another window for the phone's current app, it does not act on this
  window's frozen frame. `HeaderActionPolicy` is the one decision, unit tested.

### 3.8 Menu bar item and app menu

- `MenuBarExtra(isInserted: showMenuBar) { MenuBarContent() } label: { Image(systemName: "apps.iphone") }`,
  `.menuBarExtraStyle(.window)`. A Control Center-style panel, not a menu: a menu-style extra turned the volume
  `Slider` into a "Phone volume" stepper submenu whose hover opened and closed it. Icon: online `apps.iphone` ·
  reconnecting `apps.iphone` (pulse) · offline `iphone.slash`.
- The panel is `PhonePanelView` (PhonePanel.swift), 300 pt wide, 12 pt inset (P3): header (phone symbol, name,
  status dot + text, battery) · the agent row ("AI agent connected" + **Disconnect**) · a 2×2 grid of 134 pt tiles,
  ≥62 pt high, 8 pt apart, 12 pt corners: **Do Not Disturb**, **Ringer**, **Ring Phone**, **Turn Off Screen** ·
  the phone's media volume slider with its % · the one reason line when a control is off · **Now playing: <app>**
  when the phone reports ≥ 2 sessions · **LIVE** (one row per live notification) · one **WINDOWS** row of four icon
  buttons: **Mirror** (VoiceOver "Phone Mirror") ⌘P · **Find Apps** ⌘K · **Move to Mac** ⇧⌘C · **Install APK…**
  (with its phase) · a **gear** at the card's top-right. The panel's own commands are the icon's: a secondary click
  (right-click, or ⌃-click) opens **Settings…** ⌘, · **About PocketDeck** · **Quit PocketDeck** ⌘Q under the icon,
  closing the card first, and the gear opens the same menu anchored under the gear. The Deck popover has neither the gear nor a footer.
- **Ringer** opens a menu (**Ring** / **Vibrate** / **Silent**) with the phone's current mode checked; it never
  cycles on click. The tile's subtitle names the current mode. It is disabled, with a reason, when the phone sends
  no `ringer` or while the phone's DND is on (`dnd_on`). **Turn Off Screen** shows **Screen on** / **Screen off**
  from the phone's held panel and is disabled until a Phone Mirror is open.
- **Volume slider:** Idle shows the phone's value. Dragging shows the pointer's value every frame and ignores the
  phone's echoes; `phone.volume` is sent at most 10 times a second, and the release value is always sent. Settling
  shows the sent value until the phone echoes it, or one second passes and the phone's value wins. A hardware-key
  change while Idle moves the slider.
- No track title, performer, artwork or forwarded-audio volume: the Mac's own Now Playing shows the track, and the
  phone's media volume is the only volume control. A control that cannot work is dimmed with one line saying why
  (offline, no volume sent, no DND reported, no ringer, DND on), never hidden.
- **One component, two hosts:** the Deck's status pill opens the same view in a `.popover`; both build it from
  `PhoneControlsState(controller:)` and `PhoneControlsActions(controller:openDeck:)`.
- **App menu bar** (SwiftUI `commands`, `AppCommands` in MenuBar.swift): every item the app draws is built there, so
  SwiftUI rebuilding the bar — which it does on activation — cannot drop one. Nothing is inserted into a SwiftUI menu
  with AppKit: an inserted item is gone on the next rebuild, which is how v104 lost *Immersive* and v107 lost all three
  View items. The thing the app does not draw is handled without injection: AppKit's own *Enter Full Screen* is last
  in View, after a separator, and follows the key window itself — the Phone Mirror's `.fullScreenNone` disables it —
  just as in Apple's apps. `MenuCleanup` only *removes* what the frameworks add: AppKit's own *Send … Feedback to
  Apple* item in Help (the design keeps Help empty), every separator in Help, and a separator that directly follows
  another (SwiftUI emits one at a group's edge). It runs when the bar changes (debounced, so never on a menu SwiftUI is still
  building) and at once when a menu opens; it never removes a separator at a menu's edge and never adds, moves or
  retitles an item.
  *PocketDeck* (About, Settings… ⌘,, Services, Hide ⌘H, Hide Others ⌥⌘H, Show All, Quit ⌘Q) ·
  *File* (Add Phone… ⇧⌘N · ── · Close ⌘W · Close All ⌥⌘W — nothing after Close All) ·
  *Edit* (the standard Undo/Redo/Cut/Copy/Paste/Select All, so paste works in the code and search fields) ·
  *View* (Find Apps ⌘K · ── · Framed / Immersive · Hide Controls › · ── · Show Touches · Live Text ⇧⌘T · ── · Density › · ── · Enter Full Screen fn‑F) ·
  *Phone* (Phone Mirror ⌘P · Move Phone App to Mac ⇧⌘C · ── · Turn Off Phone Screen · Do Not Disturb · Ring Phone / Stop
  Ringing · ── · Install APK…) ·
  *Navigate* (Back ⌘[ · Home ⇧⌘H · Recents ⌘↑ — no screen item) ·
  *Window* (Minimize ⌘M · Zoom · the system's window group · Bring All to Front · the window list) ·
  *Help* (empty: there is no help book and no public issue tracker, so no dead item).
- **The Phone menu is the panel's controls**: it builds from the same `PhoneControlsState` and `PhoneControlsActions`
  the menu-bar panel and the Deck popover use, so one mapping decides what can work — *Phone Mirror*, *Move to Mac*,
  *Turn Off Phone Screen*, *Ring Phone* and *Install APK…* are disabled while the phone is away, and *Turn Off Phone
  Screen* until a Phone Mirror is open. A control that cannot work is disabled, never hidden. *Turn Off Phone Screen*
  keeps its checkmark on the phone's own `state.panel` report, never a local guess. *Install APK…* and *Ring
  Phone* name what they are doing ("Sending foo.apk… 40%", "Stop Ringing").
- **View ▸ Framed / Immersive** is one radio pair for the key stream window, built by the commands as an inline
  `Picker`, exactly one checked; ⌥⌘F switches to the other. **Hide Controls ›** holds *Instantly* · *Short* · *Long*
  (the reveal delays, checkmark on the current one) · separator · *Always Visible*, and is enabled only while the
  window is immersive. Picking any item stores the choice as the global setting under `immersive.revealDelay`, the
  same store Settings ▸ General uses; the Settings picker gains *Always Visible*. *Always Visible* keeps the traffic
  lights and the bar capsules over the stream at rest — no hot zone, no dwell pill, no hiding — and the stream still
  fills the window.
- **View ▸ Density** names the Settings default in its first item — *Default (100%)* — then lists only the other
  percentages, so no value appears twice, then *Larger* ⌘+, *Smaller* ⌘− and *Actual Size* ⌘0: the same step and reset
  the stream window's own keys perform, now visible, disabled without a key stream window that shows an app.
- **Enter Full Screen** is the system's own item, last in View with fn‑F; its title and enablement follow the key
  window, and the Phone Mirror's `.fullScreenNone` disables it because the mirror would be letterboxed. ⌃⌘F stays on
  one hidden View item that keeps its key while hidden, so the person reads macOS's item alone.
- **Marks SwiftUI cannot keep, and how they are kept:** SwiftUI builds a command item once and never re-reads its
  state — measured in an activated app, not only in the quiet e2e. Every item stays SwiftUI's, so a rebuild can never
  drop one; `MenuMarks` (MenuMarks.swift) corrects the few values that follow the running window whenever a menu
  starts tracking: the Framed/Immersive mark, Hide Controls' enablement and the reveal choice inside it, Show
  Touches, Live Text, and Density's marks and the Default title. It only writes values onto items SwiftUI already built — nothing is added, removed or replaced — and
  its rules are a pure function over a menu snapshot and `StreamMenuState`, unit-tested in K2. A rebuild can reset a
  mark to its launch value at worst; the next open corrects it.

### 3.9 Dock / lifecycle

Closing the Deck hides it; `applicationShouldHandleReopen` shows it (Dock click, A08). The app quits only on ⌘Q or
"Quit". Stream windows are independent of the Deck. Quit closes sessions cleanly (existing `beginShutdown`).

## 4. Connection and pairing — the state machine the UI sees

### 4.1 Inputs and what the UI never sees

The UI never sees `SessionState`, reason strings, or socket events. `ConnectionController` consumes them and
publishes one value, `Link` (below). A new `Session` per attempt, owned by the controller; at most one
live `Session` per phone plus at most one pairing session (§4.3) plus QR probes (§3.5).

```swift
struct PhoneRef: Equatable { var id: String; var name: String; var model: String }

enum Link: Equatable {
    case idle                                       // nothing remembered and nothing in progress
    case connecting(PhoneRef)                       // first attempt(s) this run, never online yet
    case online(PhoneRef)
    case reconnecting(PhoneRef)                     // was online this run, link lost, < 15 s
    case offline(PhoneRef, Cause)                   // ≥ 15 s without a live session
    case needsPairing(PhoneRef)                     // key missing or rejected (auth_failed)
    case pairing(PhoneRef, Pairing)                 // user-driven, sheet is up
}
enum Cause: Equatable { case unreachable, busy, versionMismatch, localNetworkDenied }
enum Pairing: Equatable { case contacting, comparing(code: String), verifying, denied, timedOut, unreachable }
```

### 4.2 Silent reconnect of a remembered phone

1. **Launch:** load `RememberedPhone`s; `active` = last used. If none → `.idle` (Welcome/Nearby). Else
   `Link = .connecting(active)` **at once** and the Deck renders Phone mode from `AppsCache` (no list flash, A11).
   Start Discovery and the first attempt in parallel:
   - phone in Discovery (TXT id matches) → connect through its service endpoint (interface policy below);
   - not (yet) discovered → after 1.5 s connect to the cached IPv4 (if any). Discovery appearing later preempts a
     cached attempt that has not authenticated yet.
2. **Attempt:** 6 s budget from `start()` to `welcome`. On budget expiry the attempt's `NWConnection` is **cancelled**
   (not just dropped; A01) and a failure is recorded. An attempt that completes TCP after cancellation cannot exist.
3. **Backoff:** failures retry after 1, 2, 4, 8, 15 s, then every 15 s indefinitely, with these immediate retries (delay 0,
   counter reset): remembered phone newly discovered/updated · `NWPathMonitor` becomes satisfied or changes interface ·
   system wake · user **Try now**. Never two attempts in flight.
4. **Interface policy (as built):** the first Bonjour attempt is pinned (`requiredInterface`) to the interface the browser found the phone on,
   Wi-Fi/Ethernet ranked first (A03); after a failed service attempt the next one is unpinned, then the remembered IPv4 address is used. (Prohibiting
   bridge/loopback interfaces was tried and rejected: a fake phone on this Mac is only reachable over a bridge.) `--connect host:port` keeps plain parameters.
5. **Auth:** handshake uses the stored key (protocol unchanged). `welcome` → `.online`, `apps.list`, apps/icons refresh,
   window reopen if this is a reconnect. A second `auth_failed` within one attempt ⇒ `.needsPairing` (no retry loop).
6. **Link loss while online:** `Link = .reconnecting` immediately; windows stay open (§3.7); steps 2–4 run.
7. **Timers (single source):** `.connecting`/`.reconnecting` → `.offline(unreachable)` after **15 s** with no live
   session. Retries continue at the 15 s cadence while `.offline`; success returns to `.online` with no navigation.

### 4.3 Transition table

| From | Event | To | UI effect |
|---|---|---|---|
| `.idle` | user presses Pair on a Nearby row | `.pairing(p, .contacting)` | Code sheet |
| any | launch with remembered phone | `.connecting(active)` | Deck/Phone mode, chip "Connecting…" |
| `.connecting` / `.reconnecting` / `.offline` | `welcome` | `.online` | chip green, grid enabled, banner cleared |
| `.online` | socket closed / ping timeout / receive error | `.reconnecting` | chip orange, grid dimmed, window pills after 1 s |
| `.connecting` / `.reconnecting` | 15 s without live session | `.offline(.unreachable)` | chip "Offline", banner "Can't reach…" |
| any non-pairing | `error{busy}` | `.offline(.busy)` after 15 s total, banner immediately | banner "Another Mac is connected…" |
| any non-pairing | `error{auth_failed}` (key rejected) | `.needsPairing` | banner + **Pair again**; reconnect loop stops |
| any non-pairing | `error{version}` | `.offline(.versionMismatch)` | banner, loop stops |
| `.needsPairing` | **Pair again** | `.pairing(p, .contacting)` | Code sheet |
| `.pairing(.contacting)` | `pair.code_shown{code}` | `.pairing(.comparing(code))` | code shown |
| `.pairing(.comparing)` | `pair.ok` | `.pairing(.verifying)` | "Pairing…" |
| `.pairing(.comparing/.verifying)` | `pair.ok`+`welcome` | `.online` | checkmark, sheet closes 0.6 s |
| `.pairing(.comparing/.verifying)` | `error{pair_denied}` | `.pairing(.denied)` | "Pairing was denied on the phone." + **Try again** |
| `.pairing(.comparing)` | `error{pair_timeout}` | `.pairing(.timedOut)` | "Nobody tapped Allow in time. Try again." |
| `.pairing` | any other failure (nothing answered) | `.pairing(.unreachable)` | "Couldn't reach *name*. Try again." |
| `.pairing(.denied/.timedOut/.unreachable)` | **Try again** | `.pairing(p, .contacting)` | new handshake |
| `.pairing` | Cancel / Esc | `.idle` or previous remembered `Link` | sheet closes, session cancelled |
| `.pairing(.viaQR)` | probe authenticates | `.online` | QR success state |
| any | **Forget** (Settings) | `.idle` or next phone | windows closed |
| any | identity mismatch on cached address | (stay) | drop the cached address only; discovery path continues |

Pairing sessions have `autoReconnect = false`; every pairing attempt is one explicit user action.
The controller guarantees: **while `.pairing`, no automatic attempt runs** (so the phone never gets two competing sessions
and never shows a second prompt).

### 4.4 Errors: one line, never loops

- A single `Banner?` value derived from `Link` (table in §3.3). It is `nil` while `online`, `connecting`, `reconnecting`.
- Reasons map through `ConnectionFailure.message(for:)` (landed by the profile task; Phase B reconciles copy with the
  strings in §3.3/§3.4 and updates its tests). Transient reasons (`closed-by-peer`, `timeout`, `receive`, `failed`,
  `cancelled`, `framing`) have **no message**: they only move `Link`.
- The banner for a cause updates in place (e.g. elapsed time is *not* shown); a repeated identical cause never re-animates.
- Nothing modal. The "Pairing failed" alert from UX.md is dropped (§9): denial is inline in the code sheet.
- Raw reasons/ids go to `os.Logger` only (Console), never to the UI.

### 4.5 Forget → pair again

Forget (Settings) removes the key, `RememberedPhone`, cached address, apps cache and Spotlight items for that phone, closes
its windows, and leaves `Link = .idle` (Nearby) or the next remembered phone. The phone side sees `auth_failed` if the Mac ever
tries again; that Mac has nothing to try with. Pairing again goes through §4.3 and the phone's own list replaces the old entry
(same `clientId`).

## 5. Keyboard map

| Where | Keys |
|---|---|
| Global (any window) | ⌘K Find Apps (shows the Deck, focuses search) · ⌘P Phone Mirror · ⇧⌘N Add phone… · ⌘, Settings · ⌘W close window · ⌘M minimize · ⌘H hide · ⌥⌘H hide others · ⌘Q quit · fn‑F / ⌃⌘F full screen (the system's) |
| Deck (Phone mode) | typing goes to search (focused on show) · ⌘F focuses the search field and selects its text · ←→↑↓ move selection (grid) · ⌘+/⌘−/⌘0 zoom the grid (75/100/125/150 %) · ↩ open selected / first match · Esc clears search, then does nothing |
| Deck (Welcome) | ↩ Find my phone |
| Nearby | ↑↓ move · ↩ Pair the selected row · ⌘R rescan (restarts Discovery) |
| Code sheet | Esc Cancel |
| QR sheet | Esc Cancel/Done |
| Manual sheet | ⇥ fields · ↩ Connect · Esc Cancel |
| Settings | ⌘W closes |
| App window | everything is forwarded to the phone as before (`InputMapper`); menu key equivalents win: ⌘[ Back · ⌘+ ⌘− ⌘0 density · ⌘W close; ⌘F is the phone app's find in page; Esc rules unchanged (`escapeAllowed`) |
| Phone Mirror | additionally ⇧⌘H Home · ⌘↑ Recents |

Existing menu shortcuts and their tests (`NavShortcutTests`) are kept verbatim.

## 6. Architecture: SwiftUI vs AppKit

### 6.1 Split

| Piece | Tech | Why |
|---|---|---|
| `@main PocketDeckApp: App` with `@NSApplicationDelegateAdaptor(AppDelegate)`; scenes: `Window` Deck, `Settings`, `MenuBarExtra` | SwiftUI | scenes, sheets, glass, `.searchable`, `SMAppService` |
| Deck / Welcome / Nearby / Phone grid / Code / QR / Manual / Settings / banner / chip | SwiftUI | pure view state |
| Stream windows (`StreamWindowController`, `AppWindow`, `PhoneWindow`), `VideoLayerView`, `InputMapper`, `DebugInput`, gestures | **AppKit (unchanged)** | NSEvent fidelity, `AVSampleBufferDisplayLayer`, resize/occlusion |
| Link-down pill, stream hover chrome | AppKit host (`NSGlassEffectView`) + SwiftUI content | lives inside the video window |
| App menu bar (`NSMenu`) | AppKit | responder-chain key equivalents (`navigateBack` etc.) |
| `AppDelegate` | AppKit | reopen, Spotlight `NSUserActivity`, terminate hooks, launch-option hooks |
| Networking (`Session`, `Discovery`, `Protocol`) | Network.framework, **no UI imports** | testable, unchanged wire behaviour |

### 6.2 New / reshaped types (all `@MainActor @Observable` unless noted)

- `ConnectionController` — owns `Discovery`, the live `Session`, `ReconnectPolicy` (pure struct, §4.2 timings), `NWPathMonitor`;
  publishes `link: Link`, `banner: Banner?`, `phones: [NearbyPhone]`, `apps`, `icons`, `phoneState` (lock/battery), and
  methods `connect(remembered)`, `pair(nearby)`, `tryNow()`, `cancelPairing()`, `forget(id)`. **The only owner of `NWConnection`**:
  every path ends in `cancel()`; a connection that is not `current` is cancelled in its state handler (A01). Replaces the
  connection half of `AppModel` (`App.swift`).
- `Link`, `Pairing`, `Banner`, `ReconnectPolicy`, `ConnectionTimeline` — pure value types so the whole §4.3 table is unit-tested without sockets
  (feed `ConnectionEvent`s, assert `Link` and `Banner`, advance a fake clock).
- `PairingModel` — comparing/verifying, success/denied/timedOut mapping; `QRPairingModel` — payload, remaining, probe scheduling (one probe per un-remembered, non-busy phone, 4 s cadence, ≤ 3 s per probe).
- `DeckModel` — filter, selection, grid navigation, enabled state; `DevicesModel` (Settings).
- `RememberedPhone` (`id, name, model, lastSeen, lastAddress?`) + `RememberedPhones` store and `AppsCache` (apps + icon PNGs per phone), both
  **inside the profile** the profile task added (never raw `UserDefaults.standard`/fixed Keychain service); non-secret, so a missing key never
  erases the memory of the phone.
- `Session` changes (networking, behaviour-preserving for the protocol): cancel on every exit; 6 s attempt watchdog that cancels;
  `prohibitedInterfaceTypes` for service endpoints; no internal auto-reconnect (the controller schedules attempts, one at a time).
  `Discovery` changes: coalesce by TXT id, ignore results without TXT id (A10), expose browse failure.
- `WindowManager` keeps its job; it gains `linkState` (for the pills) and the cascade/autosave placement.
- Test hooks (`LaunchOptions`, `--connect`, `--open`, `--open-phone`, `--resize-stream`, `--minimize-stream`,
  `--deminimize-stream`, `--quit-after`, `--reset-pairing`, `--qr-sheet`, `--qr-payload-file`, `--debug-input-script`) keep working
  (`check-e2e.sh` depends on them). Added: `--appearance light|dark` (sets `NSApp.appearance`), and `--preview <state>` that
  drives `ConnectionController` with a scripted `Link`/`Banner` for states that cannot be staged (offline, reconnecting, needsPairing,
  code `timedOut`/`denied`, loading) — used only for the screenshot set. States: welcome, nearby-empty, nearby-phones, code, code-verifying, code-stillwaiting, code-denied, code-timedout, qr, qr-success, qr-expired, manual, loading, deck, connecting, reconnecting, offline, busy, needspairing, add-phone, devices.

### 6.3 Files (suggested)

`App/PocketDeckApp.swift`, `App/AppDelegate.swift`, `App/MenuBuilder.swift` · `Connection/{ConnectionController, Link, ReconnectPolicy, Session, Discovery, ConnectionFailure}.swift` ·
`Store/{Profile, RememberedPhones, AppsCache, PairKeyStore}.swift` · `Deck/{DeckView, WelcomeView, NearbyView, AppGridView, StatusChip, BannerView}.swift` ·
`Pairing/{CodeSheet, QRSheet, ManualSheet, PairingModel, QRPairingModel}.swift` · `Settings/{SettingsView, DevicesTab}.swift` · `Windows/` (existing stream files + `LinkPill`, `WindowChrome`).
Phase B may keep the flat layout if moving files would make the diff hard to review.

## 7. Tests (Phase B, D1)

- `ConnectionTimelineTests`: every row of §4.3, backoff sequence, 15 s offline threshold, `Try now`/discovery/network/wake resets, pairing blocks automatic attempts, busy/auth/version loops stop or slow.
- `PairingModelTests`: code shown, Allow reaches `verifying`, `pair_denied`, `pair_timeout` = `timedOut`, a dropped connection = `unreachable`, no timer ends `comparing`.
- `QRPairingModelTests`: probe scheduling skips remembered/busy phones, expiry, success closes probes.
- `DiscoveryCoalesceTests`: results without TXT id ignored; multi-interface duplicates merge.
- `RememberedPhonesTests`: key loss ≠ forgotten phone; forget removes everything; profile isolation.
- Session lifecycle test (loopback `NWListener`): after a fail/cancel/timeout, **no connection stays open** (listener sees exactly one accept per attempt and EOF on abandoned ones) — regression for A01.
- Existing tests unchanged; count must not drop.

## 8. Screenshot set for D3 (light and dark, each ≥ 1x)

1 Welcome · 2 Nearby empty/searching · 3 Nearby with 2 phones (one remembered) · 4 Code sheet (comparing) · 5 verifying · 6 contacting · 7 denied · 8 timedOut · 9 QR sheet · 10 QR success · 11 Manual sheet ·
12 Deck loading (skeleton) · 13 Deck connected (≥ 14 apps) · 14 search with matches · 15 no matches · 16 selection state · 17 Connecting… (launch, cached grid) · 18 Reconnecting… · 19 Offline banner ·
20 needsPairing banner · 21 busy banner · 22 Settings General · 23 Settings Devices (2 phones) · 24 Forget confirmation · 25 App window (with link pill visible) · 26 Phone Mirror (hover header visible) · 27 menu-bar menu ·
28 Reduce Transparency variant of 13.

## 9. Revisions to existing docs (proposed here; Phase B applies them to UX.md/DESIGN.md after approval)

1. **docs/UX.md / DESIGN.md — Welcome and Devices windows and the floating launcher panel are removed from v0.** They become Deck
   states (§2). Reason: three windows plus a panel was the cause of the state-flipping and unreachable Forget (A06, A08, A11); one
   window cannot be hidden by another. The floating panel is deferred, not abandoned: the Deck is the same grid and ⌘K already
   summons it.
2. **UX.md "Pairing failed alert is the only modal" is dropped.** Denial/timeout are inline in the code sheet (§3.4) — consistent with "errors are one line, inline".
3. **DESIGN.md "Devices" section** is replaced by §3.2; the launcher panel section by §3.3; "App windows" gains cascade/autosave and the link pill (§3.7); the "Code-entry sheet" gains the §3.4 state lines.
   Tokens, Liquid Glass rules, motion, QR sheet geometry, settings and menu-bar sections stand.
4. **UX.md pairing table**: unchanged flows. One clarification: the Mac probes only phones it has no pairing with during a QR sheet.

No protocol change is required. One optional, non-blocking proposal: a phone→Mac `pair.mismatch` JSON frame so the code sheet
can say "That code didn't match." immediately instead of the 3 s "Still waiting" line (§3.4).
