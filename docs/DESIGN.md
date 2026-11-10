# PocketDeck — Design system (v0)

Companion to [UX.md](UX.md) (flows and copy). This file is prescriptive: use these exact
APIs and values. If something is not specified here, use the platform default and do
not invent styling. No hard-coded colors except where a hex is given below.

## 1. macOS (macOS 26, SwiftUI first)

### Tokens
| Token | Value |
|---|---|
| Spacing | 4 · 8 · 12 · 16 · 24 · 32 (use only these) |
| Radii | panel/window content 26 · card 20 · row 14 · cell 14 · app icon 13 (`.continuous`) · digit box 12 · chips/bars `Capsule()` |
| Type | Welcome title `.largeTitle.bold()` · tagline `.title3` + `.secondary` · section headers `.headline` · rows `.body` / subtitle `.subheadline` + `.secondary` · helper/error `.callout` · chips/labels `.caption` · all numbers `.monospacedDigit()` |
| Color | `Color.accentColor`, `.primary/.secondary/.tertiary`, `.quaternary` fills, system `.green/.orange/.red` for status only. Vibrancy comes from glass; never set text color on glass beyond hierarchical styles |

### Liquid Glass rules
- Glass is for the **floating/navigation layer** only: cards, rows in lists over a backdrop, the launcher panel, chips, the stream dwell pill, footer buttons. Never put glass on glass: content *inside* a glass surface uses `.quaternary` fills or accent tints, not another `.glassEffect`.
- Static surfaces: `.glassEffect(.regular, in: .rect(cornerRadius: R))`. Things the user clicks/hovers that are themselves glass (rows, chips): `.glassEffect(.regular.interactive(), in: …)`.
- Group adjacent glass elements in `GlassEffectContainer(spacing: 8)`; give morphing elements `.glassEffectID(id, in: ns)` with a `@Namespace var ns`.
- Buttons: the one primary action per screen = `.buttonStyle(.glassProminent)` (accent-tinted); everything else = `.buttonStyle(.glass)`. Destructive = `.glass` + `role: .destructive`. Primary uses `.controlSize(.large)`, row buttons `.controlSize(.small)`.
- AppKit-hosted bits (launcher `NSPanel`, stream-window dwell pill): `NSGlassEffectView` with `cornerRadius` set, SwiftUI content as its `contentView` via `NSHostingView`. Multiple adjacent ones go in `NSGlassEffectContainerView`.
- Reduce Transparency / Increase Contrast: rely on system fallback; do not add custom fallbacks.

### Motion
- Default: `.smooth(duration: 0.3)`. Appear/expand: `.spring(response: 0.32, dampingFraction: 0.86)`. Dismiss: `.easeIn(duration: 0.15)`.
- List rows insert/remove: `.transition(.opacity.combined(with: .move(edge: .top)))`.
- Status text changes: `.contentTransition(.numericText())` for numbers, `.contentTransition(.opacity)` for labels.
- Wrong-code shake: `keyframeAnimator` on x-offset `[0, -10, 10, -8, 8, -4, 4, 0]`, total 0.4 s, plus `NSHapticFeedbackManager.defaultPerformer.perform(.generic, …)`.
- `@Environment(\.accessibilityReduceMotion)`: replace moves/scales/shake with opacity-only.

### Deck (one window; Welcome, Nearby and Phone are its states)
Spec of every state, copy and transitions: [design/mac-redesign.md](design/mac-redesign.md) §3. Values:
- `Window("PocketDeck", id: "deck")`, default 760×600, min 640×420 (below that the toolbar's pill and Phone button fall into the overflow menu; below 592 the A–Z rail hides rather than shrink its 20 pt targets), `.windowResizability(.contentMinSize)`; the standard titled
  window with the macOS 26 glass toolbar. No custom window backgrounds except Welcome.
- **Welcome:** plain system window background (no gradient), toolbar hidden; centered card 440 wide, padding 32,
  `.glassEffect(.regular, in: .rect(cornerRadius: 28))`, VStack spacing 24: app icon 96 · title · tagline · three step rows
  (`iphone.and.arrow.forward`, `bolt.badge.checkmark` + "How?" `Link`, `wifi`; symbols `.hierarchical`, `.tint`) · **Find my phone**
  `.glassProminent .controlSize(.large)`, full width.
- **Nearby rows** in `GlassEffectContainer(spacing: 8)`: HStack(spacing 12) `iphone.gen3` 22 pt `.secondary` · name `.body` + model
  `.subheadline .secondary` · Spacer · **Pair** `.glassProminent .controlSize(.small)` (remembered phones: "Paired" `.secondary`;
  rejected: "Pair again" `.orange` + button). Row padding 12, ≥ 52 pt, `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))`.
  Footer: **Pair with QR** · **Connect manually…** `.glass` in a `GlassEffectContainer`. Empty state: `ProgressView().controlSize(.small)` +
  "Looking for phones on this network…" `.body .secondary` + "Make sure PocketDeck is open on your phone." `.callout .tertiary`, shown after 0.4 s.
- **Phone mode toolbar:** `navigationTitle` = the phone's user-visible name (Settings > About phone; the model only when the phone has none — it arrives as `welcome.device.name`);
  `ToolbarItem(.status)` pill, `.caption`, 10 pt horizontal padding, ≥ 28 pt high: 7 pt `circle.fill` (green connected, secondary connecting/offline, orange reconnecting with
  `.symbolEffect(.pulse)` or pair again). **Connected shows the dot alone** (the title names the phone); every other state adds its text. When connected: `lock.fill` `.secondary` only
  while the phone is locked (unlocked shows nothing), then the battery glyph for the level — `battery.0/25/50/75/100percent` by nearest quarter, `battery.100percent.bolt` while
  charging — and the `%` `.monospacedDigit()`, `.secondary`, `.red` below 13 % when not charging. Tooltip: "Connected, phone locked, battery 24 %".
  The pill is a button: it opens the phone controls (the menu bar panel's shared `PhonePanelView`) in a `.popover`, so the same
  P3 tiles (Do Not Disturb, Ringer, Ring/Stop Ringing, Turn Off Screen), the volume slider, the Now Playing picker and the window actions are one click away in the Deck.
  `ToolbarItem(.primaryAction)` **Phone** (`iphone.gen3`); `.searchable(placement: .toolbar, prompt: "Search apps")`.
- **Header groups** (at every width): one group packed at the left — traffic lights, then the connection
  chip (`ToolbarItem(.navigation)`; `.status` would float it in the middle of the toolbar on macOS), then the
  `navigationTitle`; one group packed at the right — **Phone**, the Settings gear (`gearshape`, SettingsLink,
  "Settings", ⌘,), then the search field (`DefaultToolbarItem(kind: .search, placement: .primaryAction)`;
  macOS pins a `.toolbar` search field at the trailing end of a window toolbar, so it renders last whatever
  order the toolbar content declares). Nothing floats in the middle: the system's own leading/trailing
  placements pin the groups to the edges.
- **Banner:** `Label(text, systemImage: "exclamationmark.circle.fill")` `.callout`, padding 12, `.glassEffect(.regular, in: .rect(cornerRadius: 14))`, at most
  one trailing `.glass .controlSize(.small)` button (`.glassProminent` for **Pair again**), below the toolbar; one banner at a time.
- **Grid (D):** `DeckGridLayout` places cells from the width of the pass that draws them. At 100 %: 96×108 cells,
  64×64 icons `.clipShape(.rect(cornerRadius: 13, style: .continuous))` inside a 16 pt hover corner, 8 pt icon-label
  gap, fixed 16 pt column gap and row spacing, 24 pt vertical inset; the block is centred, capped at 880 pt and
  reserves the rail's 44 pt on its trailing side (5 columns at 640, 6 at 760, 8 at 1000+). A cell and its icon keep
  one size at every window width: a resize only changes the column count, and past the 880 pt cap the block keeps its
  eight columns and grows its margins instead of scaling a tile. A title-bar double-click or the green button takes
  the system's standard frame (the screen's visible frame); a second zoom returns the frame it came from.
  Label `.caption` 1 line `.truncationMode(.middle)`; a name the line truncates carries the full name in its help tag.
  Hover `.fill(.quaternary)`;
  selected `.fill(Color.accentColor.opacity(0.22))`. ⌘+/⌘−/⌘0 scale cell, icon, gaps, inset and cap together
  (0.75/1/1.25/1.5, `deckZoom`) on the Deck only. Loading: one "Loading apps…" `.callout .secondary` line above 12 silent `.redacted(reason: .placeholder)`
  cells (a cell never says Loading). **Icons** come
  from the phone, cached per phone (device id + package). While one is on its way: a 64 pt `.quaternary` rounded square.
  When the phone has none (or the link is down): a generated tile — rounded square (13, continuous) with a top→bottom
  gradient of a hue derived from the package name (FNV-1a, so it is stable), the app's initial in
  `.system(size: 26, weight: .semibold, design: .rounded)` white. Never pixel art.
  Offline/reconnecting: `.opacity(0.5)`, not clickable. No matches: "No apps match “query”" `.callout .secondary`,
  height 120; a phone with no launchable apps: "No apps on this phone." in the same place.
- **A–Z rail (D):** a 26 pt column beside the grid's last column, 18 pt to its right (the grid block and the rail are
  centred together, so the margin past the rail grows with a wider window); A–Z + `#` at 9 pt in an 11 pt rest box on a
  rest pitch of at most 20 pt, giving way down to 18 pt (and then to every other or every third letter) before the rail
  hides — each letter is a 20 pt target at rest, and a short window never shrinks it; current letter accent, empty
  letters dimmed. Shows when the search field is empty and there are ≥ 30 apps; a click/drag scrolls to that letter's
  first app, and an empty letter skips forward. The current letter follows the first app in the top visible row.

- **App icons:** every tile is the shared `PhoneAppIcon` render (docs/design/dock.md §Icons) at 224 px — the macOS
  squircle (22.5 % corners), the adaptive `fg`/`bg` layers at full opacity cropped to the visible 72 dp of the 108 dp
  canvas, or the flat icon drawn by its own shape (covering the tile, or at 78 % on a plate tinted from its edge),
  with one small top light and a specular edge. Nothing is tinted or put under a material, so the tile
  shows the phone's colours; hovering lifts the tile by 4 %. The tile draws the render or the placeholder, never the
  bare flat image. The Dock, Launchpad and Spotlight use the same renderer, so an app's icon is the same everywhere;
  placeholders and the generated tile are unchanged, and `mono` is stored for a later round.

### Pairing-code sheet (numeric comparison)
- `.sheet`, frame width 400, padding 32, VStack spacing 24: title "Pair with *phone name*" `.title3.weight(.semibold)` · the code · one line `.callout`
  (state text, see docs/UX.md) · **Cancel** `.glass` (Esc), or **Try again** `.glassProminent` after denial/timeout.
- Code: "482 913" (3+3, one space), `.system(size: 52, weight: .semibold, design: .monospaced)`, `.kerning(4)`, `.primary`, height 60. Nothing is typed: no field, no boxes, no submit.
- Line while comparing: "Tap Allow on your phone if it shows the same code." Before the code arrives: spinner + "Contacting *phone name*…".
- Success: `checkmark.circle.fill` 64 pt `.green` `.symbolEffect(.bounce)`, sheet closes after 0.6 s.

### QR sheet
- `.sheet`, width 360, padding 32, VStack spacing 16: title "Scan with PocketDeck on your phone" `.title3.weight(.semibold)`; QR rendered via `CIFilter.qrCodeGenerator()`
  (correctionLevel "M"), `.interpolation(.none)`, on a **white** `RoundedRectangle(cornerRadius: 16)` with 16 pt padding in both appearances (scan reliability);
  "Expires in 4:59" `.caption .secondary .monospacedDigit()`; "Waiting for your phone…" `.callout .secondary`; **Cancel** `.glass`.
- Success: QR crossfades to `checkmark.circle.fill` 64 pt `.green` `.symbolEffect(.bounce)`, sheet closes after 0.8 s. Expiry: QR `.blur(radius: 8)` + **Show new code** `.glassProminent`.

### App windows
- `NSWindow` styleMask `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden` (the title = app
  name still names the window in the Window menu and Mission Control). An empty, non-customizable `.unified` `NSToolbar` (no items) only sizes the title area like a
  standard toolbar window, so the traffic lights sit where Finder's do (centre 26 pt from the left and the top). New windows cascade 28 pt from the top-left of the main screen (never centred over the Deck) and
  restore their saved frame per app.
- **Frameless at rest.** The window is only the stream: the system's rounded corners and window shadow, no title bar, no title text, no band above the video. The content view
  (`StreamContainerView`, plain AppKit) holds the video view, which fills it, so the window's frame is the video. The virtual display is that area × backing scale, exactly:
  rounded down to the phone's encoder alignment (2 px on the person's phone) inside its reported limits, and the phone fits nothing coarser (ISS-39; a phone that sends no
  `device.encoder` keeps the old multiple of 16 clamped to 320–2560). Such a frame is the view's own pixels and is drawn 1:1 (`Letterbox` `.oneToOne`). A settled frame more than
  1 px off but within 2 % of the view's shape (a coarser encoder step, an older phone, the cap) stretches over the view (`.stretch`, `videoGravity = .resize`) instead of showing
  thin black bars, and input is mapped against the same rectangle. A real mismatch is cropped:
  while the window has asked for a new size and no frame at that size has arrived, the last frame fills the view (`videoGravity = .resizeAspectFill`, a centred crop) so a live drag
  shows no black bars; a config within one alignment step ends it, and 2 s after the last ask with no answer it falls back to aspect-fit. Input is mapped against the same rectangle
  (`Letterbox.placement` and `videoRect`), so a click lands on the pixel under the pointer even mid-resize. The Phone Mirror is the exception: it mirrors the phone's fixed screen,
  so its letterbox is never cropped.
- **Window chrome by style** (`StreamChrome.swift` + `WindowStyle.swift`; View ▸ Window Style, ⌥⌘F toggles). The window is the stream plus a 28 pt bar above it in
  Framed (the default, none in full screen); Immersive is exactly the stream. The other three edges are the stream's own; the corners round once on the window's
  container (every child paints square so the bar's seam stays straight); 16 pt continuous corners on the window; the virtual display is sized from the stream
  rect only, never the style.
  - **Framed bar.** An `NSBackgroundExtensionView` has the video view as its `contentView` and fills the whole window, so the band above the video is the
    stream's own top 28 pt mirrored there — live, with the system's progressive blur raised from its 5 pt radius to 15 (strongest at the window's top edge,
    sharp at the seam), no CPU readback and no second decode. A white haze fades over the bar band alone, α 0.14 in dark and 0.30 in light at the window's
    top edge to clear at the seam; it is hidden while the opening cover or the disconnection overlay is up and in Immersive or full screen. Nothing else is
    drawn over the mirror: no material, tint or scrim, so the bar keeps the stream's colours in light and dark apps; the traffic lights ride it as standard
    controls. A macOS whose backdrop has no such filter keeps the system's own radius and still gets the haze.
  - **Immersive.** A 72×32 pt hot zone at the stream's top-left. A click there before the dwell reaches the app as an ordinary touch (no added delay) and
    restarts the rest; a rest (moved < 3 pt) fades the pill in over 0.12 s — `NSGlassEffectView` in its clear style, corner 8, so it blurs the stream
    without a grey fill — with the window's traffic lights on its slots (8 pt in, 23 pt apart) and the kind's actions after them (app windows: none).
    Settings → General → "Reveal controls after" picks the rest: Instantly (0), Short (350 ms, the default) or Long (700 ms); it applies to open windows
    live. The pill fades back 600 ms after the pointer leaves zone and pill; while shown, a click on its empty area drags the window, a double-click zooms.
  - **Switching.** View ▸ Window Style's Framed/Immersive radio items and Toggle Window Style (⌥⌘F): the window grows or shrinks by the bar above the stream
    (`WindowStyle.frame` moves it down just enough when the bar would poke above the visible frame) and the choice lands per package under
    `chrome.style.<package>` (`chrome.style.phone` for the Phone Mirror); a window with nothing stored opens Framed and re-applies the stored style when it
    learns its package (link/handoff).
  - `DebugInput windowstyle framed|immersive|toggle` drives it; `--debug-chrome-state FILE` writes `style=framed|immersive lights=shown|hidden pill=shown|hidden clicks=N`
    (N = clicks the bar's or the pill's background received) there for the e2e check.
- **Disconnection overlay (stall and link down):** the whole window — the 28 pt bar included — as one sheet: the last frame under one acrylic
  (`NSVisualEffectView` `.hudWindow` with a black dim, 0.38 in dark and 0.50 in light so white ink keeps 4.5:1), with the window's icon (96 pt, corner 22),
  the title "Not responding" / "Reconnecting…" / "Phone offline" (15 pt semibold) and "Waiting for <phone>…" (12.5 pt) centred in the body. No buttons; the
  traffic lights and the bar's controls ride above it, and every other click is the overlay's (the stream is frozen). It comes with the picture's state: 1.5 s
  of silence, or 1 s after the link drops ("Phone offline" at 15 s); a frame or the reconnect takes it away and the bar's mirror is live again.

### Trackpad input (stream windows)
The phone is a touch screen, the Mac has a pointer and a trackpad. Everything reaches it as the touches, scroll and key frames of docs/PROTOCOL.md; the aim is that the trackpad feels like
using the phone with fingers.

| On the Mac | The phone sees |
|---|---|
| Click, click-drag | one finger (TOUCH pointer 0) |
| Mouse wheel (line units, or no gesture phase) | SCROLL (`ACTION_SCROLL`, `SOURCE_MOUSE`), one notch per wheel unit |
| Two-finger scroll (phased) | **one finger dragging**: DOWN at the cursor, one MOVE per scroll event, UP when the fingers lift. Android's own slop, drag, overscroll and fling apply; the momentum events are dropped because Android flings by itself |
| Pinch / rotate / two-finger gestures | **two pointers from the raw fingers** (below) |
| Pinch / rotate without raw fingers | the coarse emulation: two pointers symmetric around the cursor, scaled by the magnification, turned by the rotation (`PointerGesture`) |
| Two-finger double tap (smart zoom) | a double tap at the cursor |
| Three or more fingers | nothing: Spaces, Mission Control and the rest stay the system's |

- **Scroll as a drag** (`ScrollDrag`). The finger moves 1:1 with the scroll deltas, in window points (a point is a dp on the phone at the default density), in the direction AppKit reports them (the
  deltas already follow natural scrolling: the content follows the fingers). A drag that travels less than 12 pt ends as CANCEL, not UP, so a resting two-finger touch never becomes a tap. The finger
  stops at the video's edge and comes back the moment the scroll reverses. Events are sent as they arrive, none merged or delayed: the phone stamps each one when it arrives, so the Mac's cadence
  and the lift (UP right after the last MOVE) are the velocity Android computes its fling from.
- **Raw fingers** (`allowedTouchTypes = [.indirect]`, `touchesBegan/Moved/Ended/Cancelled`). NSTouch gives each finger's `normalizedPosition` and the surface's `deviceSize` (points of 1/72 in), so the
  fingers are converted to millimetres. Pointer *i* = cursor + (finger *i* − the fingers' centroid when the second one landed) × 4 pt per mm (`TrackpadPinch`, tunable), clamped to the video. The cursor,
  not the finger position on the pad, says where in the app it happens; a spread of 20 → 60 mm becomes 80 → 240 pt. Resting touches are not reported (`wantsRestingTouches = false`).
- **How the two paths share two fingers** (`TrackpadGestures`; exactly one of them reaches the phone). Two fingers landing starts a classification; the scroll events that arrive meanwhile are held.
  Once the fingers have travelled 2 mm, translation of their centroid against change of their distance or angle (the larger wins) decides: *pan* releases everything held as one MOVE after the DOWN and
  lets the scroll events drive the drag; *pinch* puts down two pointers where the fingers landed, moves them to where they are, and ignores the scroll, magnify and rotate events of that gesture.
  A pinch ends when one finger lifts (both pointers go up) and nothing more happens until all fingers are off. A magnify or rotate event while two fingers are down only settles a pinch the fingers have
  not classified yet. A scroll that ends before the verdict still scrolls if it travelled 12 pt. Without raw touches (`touchesAvailable` false) scroll goes straight to the drag and magnify/rotate use the
  coarse emulation.
- **Cancelled, not released:** a click or right click in the middle of a gesture, the window losing key, a third finger, and a `cancelled` scroll phase all send CANCEL for every pointer, and the rest of that
  gesture is ignored.
- **Show Touches** (View → Show Touches; off by default; one setting for every window, kept in the profile's defaults). While a trackpad gesture holds pointers on the phone, a 34 pt dot per pointer
  (`white` 32 % fill, 1.5 pt `white` 85 % border, soft shadow) is drawn over the video at the position the phone was told, fading out in 0.2 s when the pointer goes up. It shows what Android sees, including
  the one finger of a scroll; mouse clicks are not drawn.
- **Compared with the Xcode Simulator.** The Simulator has a pointer and a trackpad too, and settles it differently: a click is a finger; holding Option shows two mirrored fingers around the centre for
  pinch, and moving them (Shift locks them together) is its two-finger gesture; a trackpad scroll is converted into a drag. PocketDeck keeps the click-is-a-finger and scroll-is-a-drag parts (but keeps the
  wheel a wheel) and drops the modifier: the trackpad's own pinch, rotate and two-finger gestures are the gestures, because the raw fingers are available, so a pinch needs no mode, follows the real finger
  distance and rotation, pans while it zooms, and is anchored at the cursor like a thumb on the glass. The Option-drag dots are what Show Touches draws, for any gesture. The mirrored-dots mode remains the
  fallback for a Mac without trackpad touches, as the magnify/rotate emulation.

### Settings
- `Settings { TabView { Tab("General", systemImage: "gearshape") {…}; Tab("Devices", systemImage: "iphone.gen3") {…} } }`, frame width 480. `Form` + `.formStyle(.grouped)`.
- General: `Toggle` "Launch at login", `Toggle` "Show in menu bar", `Picker` "Default window density" (`.menu`).
- Devices: rows `LabeledContent` (name; model + "Last seen *relative*" `.secondary`; state text) with **Use** `.glass` (non-active phones) and **Forget** `.glass` `role: .destructive` → `confirmationDialog`; **Add phone…** `.glass` below the list.

- **The bar's geometry (BarGeometry).** 14 pt traffic lights, 7 pt in from
  the left, the top and the bottom, in a 28 pt bar; the 28 pt Live Text button
  mirrors them 7 pt in from the right, centred on the lights' line. The framed
  bar and the immersive pill use the same numbers, in app windows and the Phone Mirror,
  light and dark.

### Menu bar
- `MenuBarExtra { MenuBarContent() } label: { Image(systemName: icon) }`, `.menuBarExtraStyle(.window)`: a Control Center-style panel, not a menu (a `Slider` inside a menu-style extra became a "Phone volume" stepper submenu that opened and closed under the pointer). Icon: Connected `apps.iphone` · Reconnecting `apps.iphone` (`.symbolEffect(.pulse)`) · Offline `iphone.slash`; a dot next to it, in a slot the image reserves in both states, while an AI agent is connected.
- `PhonePanelView` (PhonePanel.swift), one component shared with the Deck popover, 300 pt wide, 12 pt inset (P3): header (phone symbol, name, status dot + text, battery) · agent row ("AI agent connected" + **Disconnect**) · 2×2 tiles (134 pt wide, ≥ 62 pt high, 8 pt gap, 12 pt corners): **Do Not Disturb**, **Ringer**, **Ring Phone**, **Turn Off Screen** · volume `Slider` with its % · the reason on a disabled control's own second line (the full sentence in its help tag and hint) · **Now playing: <app>** with ≥ 2 sessions · **LIVE** (one row per live notification) · one **WINDOWS** row of four icon buttons (**Mirror** / **Find Apps** / **Move to Mac** / **Install APK…** with its phase) · a **gear** at the card's top-right that opens the icon's own menu (**Settings…** ⌘, · **About PocketDeck** · **Quit PocketDeck** ⌘Q) anchored under the gear, which a secondary click on the status item also opens under the item, closing the card first.
- **Ringer** opens Ring / Vibrate / Silent with the current mode checked (never cycles); its subtitle names the mode. **Turn Off Screen** says Screen on / Screen off and needs a Phone Mirror. **Volume** is a three-state control: Idle follows the phone, Dragging follows the pointer and ignores echoes with sends capped at 10/s plus the release, Settling shows the sent value until the echo or one second, after which the phone wins.
- The Deck's status pill opens the same view in a `.popover` (one component, one copy, no footer, no gear).
- Nothing is modal: pairing failures are inline in the code sheet.

## 2. Android (Compose + Material 3, minSdk 30)

### Theme
- `PocketDeckTheme`: `if (Build.VERSION.SDK_INT >= 31) dynamicLight/DarkColorScheme(context) else lightScheme/darkScheme`, dark from `isSystemInDarkTheme()`.
- Fallback schemes: generate with Material Theme Builder from **seed `#5B6CF0`** (scheme "Tonal Spot"), paste all roles into `ui/theme/Color.kt`. No other hex in code.
- Typography: default `Typography()`; used styles: `headlineMedium` (onboarding titles), `titleLarge` (status card title), `titleMedium` (list headers), `bodyLarge`/`bodyMedium`, `labelLarge` (buttons), `labelSmall` (grid labels).
- Pairing code: `displayLarge.copy(fontFamily = FontFamily.Monospace, letterSpacing = 6.sp, fontFeatureSettings = "tnum")`, formatted "482 913", color `primary`.
- Shapes: default `Shapes()` (4/8/12/16/28). Status card `extraLarge`, list group `large`; grid app icons are drawn as the system provides them (already masked), no extra clip.
- Icons: Material Symbols Rounded exported as vector drawables in `res/drawable/ic_*.xml` (no icons-extended dependency).

### Layout & insets
- `enableEdgeToEdge()` in `onCreate`. Every screen = `Scaffold` (default `contentWindowInsets`) and apply `innerPadding`; lists add `WindowInsets.navigationBars` bottom padding + 88.dp under FAB.
- Horizontal margins 16.dp (compact), 24.dp (≥600dp). Vertical rhythm 8/16/24.dp.

### Motion
- Easing: emphasized decelerate `CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)` (enter), emphasized accelerate `CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)` (exit), standard `CubicBezierEasing(0.2f, 0f, 0f, 1f)`.
- Durations: enter 400 ms, exit 200 ms, small state changes (card content) 300 ms via `AnimatedContent` (`fadeIn + slideInVertically { it / 4 }` togetherWith `fadeOut`), pager auto-advance `animateScrollToPage` with `tween(500, easing = emphasized)`.
- Respect `Settings.Global.ANIMATOR_DURATION_SCALE` (Compose does by default).

### Onboarding
- `Scaffold` without top bar; top: `LinearProgressIndicator(progress = { (page + 1) / 4f }, Modifier.fillMaxWidth())` with `animateFloatAsState`. `HorizontalPager(state, userScrollEnabled = false)`; each page: Column, 24.dp padding, illustration/icon 96.dp at top, `headlineMedium` title, one `bodyLarge` line, actions pinned bottom (`Button` full width primary, `OutlinedButton` secondary).
- Shizuku page: one `ListItem` in an `OutlinedCard` with leading status icon + `supportingContent` state; button changes per state (**Get Shizuku** / **Open Shizuku** / **Allow**); "How to start it" = 3 numbered `bodyMedium` lines. Ready = `ic_check_circle` tinted `primary`.
- Pair page: `OutlinedButton` **Scan QR code** with `ic_qr_code_scanner`; `CircularProgressIndicator` 24.dp + "Waiting for your Mac…" `bodyMedium onSurfaceVariant`.

### Home
- `LargeTopAppBar(title = "PocketDeck")` + `exitUntilCollapsedScrollBehavior`; overflow is empty in v0 (no action).
- Status `ElevatedCard(shape = extraLarge)`, padding 20.dp, Row: icon 40.dp · Column(`titleLarge` title, `bodyMedium` subtitle). Colors via `CardDefaults.elevatedCardColors(containerColor = …)`:

| State | Container / content | Icon |
|---|---|---|
| Ready | `secondaryContainer` / `onSecondaryContainer` | `ic_check_circle` |
| Connected | `primaryContainer` / `onPrimaryContainer` | `ic_desktop_mac` |
| Needs attention (Shizuku not running, connections off) | `tertiaryContainer` / `onTertiaryContainer` | `ic_warning` + `FilledTonalButton` fix |
| Error | `errorContainer` / `onErrorContainer` | `ic_error` + `FilledTonalButton` retry |

- One left edge: list rows are full-bleed and keep `ListItem`'s own 16 dp start padding; the status card, the "Paired Macs" title and the dividers carry the screen inset (16 dp, 24 dp ≥ 600 dp). No double indent: the first switch label, the card's left edge and the section title all start at 16 dp.
- Switch rows are one `SwitchRow` `ListItem` (headline, optional supporting line, `Switch` at the end; whole row toggles). Order: "Keep running in the background" | `HorizontalDivider(padding vertical 8.dp)` | "Allow connections" (master) and "Allow new pairings" (disabled while the master is off, keeping its value). Notification sharing has no switch here: the Mac holds the only one, and a missing listener grant on the phone is the status card's "Notification access is off" attention item with an **Allow** action.
- Background switch off = `START_NOT_STICKY` and no boot start; the service still starts with the screen's task, and `onTaskRemoved` stops it and calls `stopServer()` on the shell service. On = `START_STICKY` and `BootReceiver` starts it after boot/update. The status card maps off to Ready with `untilTaskClosed = true`, so its subtitle is "Stops when you close PocketDeck from recent apps." and it has no action; the attention colours are only for Allow connections off and Shizuku problems.
- "Paired Macs" header `titleMedium` `primary`; rows `ListItem` (leading `ic_laptop_mac`, headline name, supporting "Last connected *relative*", trailing `IconButton` overflow → `DropdownMenu` "Forget"), wrapped in `SwipeToDismissBox` (end-to-start, background `errorContainer` + `ic_delete`). Forget → `Snackbar` with **Undo** (4 s) before the key is deleted. Empty: `bodyMedium onSurfaceVariant` "No Macs paired yet."
- `ExtendedFloatingActionButton(text = "Pair new Mac", icon = ic_qr_code_scanner)`, collapses (`expanded = !scrolled`).

### Pairing prompt
- Notification channel "pairing", `IMPORTANCE_HIGH`, `NotificationCompat.CATEGORY_STATUS`, title "Pair with *Mac name*?", text "Code 482 913", actions **Allow** / **Deny**, `setTimeoutAfter(120_000)`, `setOnlyAlertOnce(true)`.
- Foreground: `AlertDialog(icon = ic_link, title = "Pair with *Mac name*?", text = code (display style above) + "Check it matches your Mac." bodyMedium, confirmButton = TextButton("Allow"), dismissButton = TextButton("Deny"))`.

### Phone-mode launcher (virtual display)
- Same theme. `Scaffold` → `DockedSearchBar` at top (16.dp margin, full width, `inputField` with leading `ic_search`, placeholder "Search apps"), autofocus.
- `LazyVerticalGrid(GridCells.Adaptive(minSize = 88.dp), contentPadding = 16.dp, spacing 8.dp)`; cell: app icon 56.dp, `labelSmall` 1 line ellipsis, spacing 6.dp; focused/hovered cell background `secondaryContainer` in `RoundedCornerShape(16.dp)`. Nothing else on screen.

## 3. App icon brief

**Mac (macOS 26 layered icon, Icon Composer, 1024×1024 canvas, system rounded-rect mask).** Background layer: linear gradient top-left → bottom-right using the brand light stops (`#6A7BFF` → `#9B6BFF` → `#3FD0E0`). Middle layer ("window"): a white rounded rectangle 600×440 at (212, 300), radius 56, 22 % white fill with a 6 pt white 60 % stroke and three 28 pt dots (white 70 %) at top-left — a Mac window. Foreground layer ("phone"): a solid white rounded rectangle 260×470 at (470, 330), radius 64, rotated −8° about its center, overlapping the window's right edge, with a 2×3 grid of 56×56 radius-14 squares in `#6A7BFF` at 85 % (apps) and a 90×10 capsule speaker at top. Enable Liquid Glass on the foreground layer (specular + shadow on, translucency 20 %); dark and tinted variants derive automatically — the phone stays white, the gradient drops to the dark stops.

**Android adaptive (108×108 dp, 66 dp safe circle).** Background: `<gradient android:type="linear" android:angle="315">` (top-left → bottom-right) `#6A7BFF` → `#9B6BFF` → `#3FD0E0` (center color = middle stop). Foreground vector, all white: window outline = rounded rect 52×38 dp at (22, 32), radius 6, stroke 3 dp, three 2.5 dp dots at its top-left; phone = filled rounded rect 24×42 dp at (52, 36), radius 6, rotated −8° about (64, 57), with four 6×6 dp radius-1.5 holes cut out (2×2 grid, `fillType="evenOdd"`). Everything stays within the 66 dp circle. Monochrome: same foreground paths, single `#FFFFFF` fill, no gradient, window stroke 3.5 dp.

## 4. QA checklist (verify from screenshots, light **and** dark)

**Mac — Welcome:** plain window background, no toolbar · one glass card, centered · icon + "PocketDeck" + "Your Android apps, on your Mac." · 3 steps with symbols, "How?" link · single prominent **Find my phone**.
**Mac — Nearby:** "Nearby" glass rows with name, model, **Pair** (prominent), no device ids · footer has exactly **Pair with QR** + **Connect manually…** (glass, secondary) · empty state shows spinner + two lines, no other content.
**Mac — Code sheet:** title names the phone · the code large and monospaced, 3+3 grouping · one state line under it, no raw error codes · **Cancel** always reachable (except while pairing finishes) · no input fields, no OK/submit button.
**Mac — QR sheet:** QR on white tile in dark mode too · countdown visible · success shows green checkmark · expired QR blurred with **Show new code**.
**Mac — Deck (phone):** toolbar: one group packed at the left (traffic lights, the status pill — green dot alone when
connected, plus lock while locked and the battery glyph + % — then the phone's own name (not the model)), one at the
right (**Phone**, the Settings `gearshape` opening Settings, ⌘,, then the search field with caret) · nothing between
the groups ·
grid ≤ 56 pt icons (generated initial tile when the phone has none), one-line labels, equal 20 pt side insets, the scroll bar never over a tile · at most one cell highlighted in accent tint · offline/reconnecting: dimmed grid + chip, banner only when action is needed · one cell per launch target: a package with two launcher activities is two cells, each keyed by its activity, and a cell with no label falls back to the package's last part (a repeated key draws nothing).
**Mac — Banner:** one line, one trailing button at most, never a reason code.
**Mac — App window:** two styles (View ▸ Window Style, ⌥⌘F; remembered per app package, no stored choice = Framed): **Framed** (default) = the stream plus a permanent bar above it (28 pt) — the stream's own top rows mirrored there under the window material, traffic lights on the bar's line, Phone Mirror: Back · Home · Recents at the bar's right; **Immersive** = only the stream, rounded corners and the system shadow, a glass pill with the traffic lights at the stream's top-left after a 350 ms rest (a click in that corner before the dwell is the app's ordinary touch); switching grows or shrinks the window by the bar, the stream keeps its place; full screen has no custom chrome in either style — the stream fills the screen, and the system's bar, revealed at the top edge, shows the window's title and the standard traffic lights · the **disconnection overlay** above over the whole window while the picture is stalled or the link is down.
**Mac — Settings:** exactly two tabs (General, Devices) · General has exactly 3 controls · Forget is red.
**Mac — Menu bar:** status line first · items in the order listed · icon changes with connection state.
**Android — Onboarding:** progress bar at top advances per step · no swipe between pages · one primary button per page · Shizuku row shows current state text + matching button · Scan QR is outlined.
**Android — Home:** large title collapses on scroll · status card color matches the table for each state · "Keep PocketDeck running", "Allow connections" and "Allow new pairings" switches · Paired Macs rows with last connected · extended FAB "Pair new Mac" · content not under status/nav bars.
**Android — Pairing prompt:** heads-up notification with code + Allow/Deny · in-app dialog code in large monospace, grouped 3+3.
**Android — Phone launcher:** only a docked search bar and the icon grid; columns increase on wider displays.
**Copy (all):** sentence case · no "virtual display/stream/HMAC/port" outside Connect manually · max one helper line per element.
