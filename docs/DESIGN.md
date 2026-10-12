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
| Brand gradient (Welcome backdrop only) | `LinearGradient(stops:, startPoint: .topLeading, endPoint: .bottomTrailing)` light: `#6A7BFF` 0 · `#9B6BFF` 0.55 · `#3FD0E0` 1; dark: `#1E2470` 0 · `#3B1F73` 0.55 · `#0D4E5C` 1 |

### Liquid Glass rules
- Glass is for the **floating/navigation layer** only: cards, rows in lists over a backdrop, the launcher panel, chips, hover bar, footer buttons. Never put glass on glass: content *inside* a glass surface uses `.quaternary` fills or accent tints, not another `.glassEffect`.
- Static surfaces: `.glassEffect(.regular, in: .rect(cornerRadius: R))`. Things the user clicks/hovers that are themselves glass (rows, chips): `.glassEffect(.regular.interactive(), in: …)`.
- Over the brand gradient use `.regular`; never `.clear` (contrast).
- Group adjacent glass elements in `GlassEffectContainer(spacing: 8)`; give morphing elements `.glassEffectID(id, in: ns)` with a `@Namespace var ns`.
- Buttons: the one primary action per screen = `.buttonStyle(.glassProminent)` (accent-tinted); everything else = `.buttonStyle(.glass)`. Destructive = `.glass` + `role: .destructive`. Primary uses `.controlSize(.large)`, row buttons `.controlSize(.small)`.
- AppKit-hosted bits (launcher `NSPanel`, app-window hover bar): `NSGlassEffectView` with `cornerRadius` set, SwiftUI content as its `contentView` via `NSHostingView`. Multiple adjacent ones go in `NSGlassEffectContainerView`.
- Reduce Transparency / Increase Contrast: rely on system fallback; do not add custom fallbacks.

### Motion
- Default: `.smooth(duration: 0.3)`. Appear/expand: `.spring(response: 0.32, dampingFraction: 0.86)`. Dismiss: `.easeIn(duration: 0.15)`.
- List rows insert/remove: `.transition(.opacity.combined(with: .move(edge: .top)))`.
- Status text changes: `.contentTransition(.numericText())` for numbers, `.contentTransition(.opacity)` for labels.
- Wrong-code shake: `keyframeAnimator` on x-offset `[0, -10, 10, -8, 8, -4, 4, 0]`, total 0.4 s, plus `NSHapticFeedbackManager.defaultPerformer.perform(.generic, …)`.
- `@Environment(\.accessibilityReduceMotion)`: replace moves/scales/shake with opacity-only.

### Welcome window
- `Window("Welcome", id: "welcome")`, `.windowStyle(.hiddenTitleBar)`, `.windowResizability(.contentSize)`, `.windowBackgroundDragBehavior(.enabled)`; content frame 560×520; background = brand gradient `.ignoresSafeArea()`.
- Centered card 440 wide, padding 32, `.glassEffect(.regular, in: .rect(cornerRadius: 28))`, VStack spacing 24:
  - App icon 96×96 (`NSApp.applicationIconImage`), title, tagline.
  - Steps: 3 rows, `Label` with SF Symbols `iphone.and.arrow.forward` · `bolt.badge.checkmark` · `wifi`, `.font(.body)`, symbol `.foregroundStyle(.tint)`, `.symbolRenderingMode(.hierarchical)`, row spacing 12. "How?" = `Link` in `.callout`.
  - **Find my phone**: `.glassProminent`, `.controlSize(.large)`, full card width.

### Devices window
- `Window("Devices", id: "devices")`, default size 480×560, min 420×420, standard titlebar, `.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)`, default window background (no custom material).
- Section header "Nearby" `.headline`, padding 16.
- Rows in `GlassEffectContainer(spacing: 8)`: HStack(spacing 12) — `iphone.gen3` 22 pt `.secondary` · VStack(name `.body`, model `.subheadline .secondary`) · Spacer · state text ("Paired" `.secondary` / "Pair again" `.orange`) when applicable · **Pair** `.glassProminent .controlSize(.small)`. Row padding 12, height ≥ 52, `.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))`.
- Footer HStack(spacing 8), padding 16, in a `GlassEffectContainer`: **Pair with QR** (`qrcode`) · **Connect manually…** (`network`), both `.glass`.
- Empty: centered VStack(spacing 8): `ProgressView().controlSize(.small)`, "Looking for phones on this network…" `.body .secondary`, "Make sure PocketDeck is open on your phone." `.callout .tertiary`.
- Inline error (e.g. after 3 failed codes): `Label(msg, systemImage: "exclamationmark.circle.fill")`, `.callout`, `.foregroundStyle(.red)`, above the list, auto-clears on next action.
- "Pair again" state (after `auth_failed`): row subtitle "Pair again" `.orange` and button label **Pair again**.

### Code-entry sheet
- `.sheet`, frame width 400, padding 32, VStack spacing 24: title "Enter the code shown on *phone name*" `.title3.weight(.semibold)` · digit row · helper `.callout .secondary` / error `.callout .red` · **Cancel** `.glass`.
- Digit row: HStack(spacing 8) of 6 boxes, extra 16 pt gap after box 3. Box 48×60, `.glassEffect(.regular, in: .rect(cornerRadius: 12))`; digit `.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()`. Focused box: `.overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2))`. Single hidden `TextField` drives all boxes; paste of 6 digits fills all; auto-submit on 6th → boxes show `ProgressView().controlSize(.small)` in place of title icon.
- Wrong code: shake, clear, refocus box 1, error "That code didn't match. Try again."

### QR sheet
- `.sheet`, width 360, padding 32, VStack spacing 16: title "Scan with PocketDeck on your phone" `.title3.weight(.semibold)`; QR 220×220 rendered via `CIFilter.qrCodeGenerator()` (correctionLevel "M"), `.interpolation(.none)`, on a **white** `RoundedRectangle(cornerRadius: 16)` with 16 pt padding in both appearances (scan reliability); "Expires in 4:59" `.caption .secondary .monospacedDigit()`; **Done** `.glass`.
- On success: QR crossfades to `checkmark.circle.fill` 64 pt `.green` with `.symbolEffect(.bounce)`, sheet closes after 0.8 s. On expiry: QR `.blur(radius: 8)` + **Show new code** `.glassProminent`.

### Launcher panel
- `NSPanel` styleMask `[.nonactivatingPanel, .fullSizeContentView, .borderless]`, `level = .floating`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = true`, centered horizontally at 22 % from the screen top. Root = `NSGlassEffectView(cornerRadius: 26)` hosting SwiftUI.
- Size: width 640 fixed; height = content, max 480 (grid scrolls). Padding 16, VStack spacing 12.
- Header (height 28): phone name `.headline` · Spacer · chip group in `GlassEffectContainer(spacing: 6)`: connection chip, lock chip (`lock.fill` / `lock.open.fill`), battery chip (`battery.100percent`…`battery.0percent`, `battery.100percent.bolt` when charging, % `.monospacedDigit()`); chips `.caption`, padding h8 v4, `.glassEffect(.regular, in: Capsule())` · **Phone** button (`iphone.gen3`, `.glass`, `.controlSize(.small)`).
- Connection chip: 6 pt `Circle` + text. Connected `.green` · Reconnecting… `.orange` + dot `.symbolEffect(.pulse)` (use `circle.fill` symbol) · Offline `.secondary`.
- Search: `TextField("Search apps", …)`, `.textFieldStyle(.plain)`, `.font(.title3)`, leading `magnifyingglass` `.secondary`, height 44, padding h12, background `.quaternary` in `.rect(cornerRadius: 12)`, `@FocusState` focused on show.
- Grid: `LazyVGrid(columns: Array(repeating: GridItem(.fixed(96), spacing: 8), count: 6), spacing: 8)` → max 6 columns. Cell 96×100: icon 56×56 `.clipShape(.rect(cornerRadius: 13, style: .continuous))`, label `.caption`, 1 line, `.truncationMode(.middle)`, spacing 6.
- Cell states (no glass inside the panel): hover `.fill(.quaternary)`; selected `.fill(Color.accentColor.opacity(0.22))` + label `.primary`; both `RoundedRectangle(cornerRadius: 14)`. Selection moves with `.smooth(duration: 0.15)`.
- Show: opacity 0→1 + scale 0.96→1 with the appear spring; hide: dismiss curve. Esc / click outside / ⌘K hides.
- Loading: 12 placeholder cells `.redacted(reason: .placeholder)`. No matches: "No apps match "query"" `.callout .secondary`, centered, height 120. Offline: `ContentUnavailableView("Phone is offline", systemImage: "iphone.slash", description: Text("Reconnecting automatically."))`.

### App windows
- `NSWindow` styleMask `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, `titlebarAppearsTransparent = true`, `titleVisibility = .visible`, title = app name, `representedURL` unset, title icon via `standardWindowButton(.documentIconButton)` with the app icon. No toolbar. Video layer fills the whole content view (edge to edge, under the titlebar). Corner radius = system.
- Phone-mode hover bar: `NSGlassEffectView` capsule (cornerRadius 18), 3 buttons × 44 wide + padding 6 → 144×36, centered horizontally, 8 pt below the titlebar. Symbols `chevron.backward` · `circle` · `square.on.square`, 15 pt semibold, `.primary`. Shows when the pointer is in the top 56 pt (`NSTrackingArea`), fade in 0.2 s, fade out 0.3 s after 1 s idle. Each button has a tooltip (Back / Home / Recents).

### Settings
- `Settings { TabView { Tab("General", systemImage: "gearshape") {…}; Tab("Devices", systemImage: "iphone.gen3") {…} } }`, frame width 480. `Form` + `.formStyle(.grouped)`.
- General: `Toggle` "Launch at login", `Toggle` "Show in menu bar", `Picker` "Default window density" (`.menu`).
- Devices: rows `LabeledContent` (name; model + "Last seen *relative*" `.secondary`) with **Forget** `.glass` `role: .destructive` → `confirmationDialog`.

### Menu bar
- `MenuBarExtra { … } label: { Image(systemName: icon) }`, `.menuBarExtraStyle(.menu)`. Icon: Connected `apps.iphone` · Reconnecting `apps.iphone` (`.symbolEffect(.pulse)`) · Offline `iphone.slash`.
- Items: disabled status line "● Connected to *phone*" / "Reconnecting…" / "Offline" · Divider · "Open launcher" ⌘K · "Phone screen" · Divider · "Devices…" · "Settings…" ⌘, · Divider · "Quit PocketDeck" ⌘Q.
- "Pairing failed" is the only modal: `.alert("Pairing failed", …)` with one-line message and **OK**.

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

- `ListItem(headlineContent = "Allow connections", trailingContent = Switch(...))`, whole row toggles.
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

**Mac — Welcome:** gradient backdrop, no titlebar text · one glass card, centered · icon + "PocketDeck" + "Your Android apps, on your Mac." · 3 steps with symbols, "How?" link · single prominent **Find my phone**.
**Mac — Devices:** "Nearby" glass rows with name, model, wifi bars, **Pair** (prominent) · footer has exactly **Pair with QR** + **Connect manually…** (glass, secondary) · empty state shows spinner + two lines, no other content.
**Mac — Code sheet:** 6 boxes, 3+3 grouping, focused box outlined in accent · error line in red under boxes after wrong code · no OK/submit button.
**Mac — QR sheet:** QR on white tile in dark mode too · countdown visible · success shows green checkmark.
**Mac — Launcher:** floating rounded glass panel, 640 wide, no titlebar · header: phone name, connection chip, lock, battery, **Phone** · search focused with caret · ≤6 columns, 56 pt icons, one-line labels · exactly one cell highlighted in accent tint · offline shows "Phone is offline".
**Mac — App window:** video fills window under titlebar, traffic lights visible, title = app name + icon, no toolbar · phone mode only: glass capsule with 3 buttons appears on top hover.
**Mac — Settings:** exactly two tabs (General, Devices) · General has exactly 3 controls · Forget is red.
**Mac — Menu bar:** status line first · items in the order listed · icon changes with connection state.
**Android — Onboarding:** progress bar at top advances per step · no swipe between pages · one primary button per page · Shizuku row shows current state text + matching button · Scan QR is outlined.
**Android — Home:** large title collapses on scroll · status card color matches the table for each state · "Allow connections" switch · Paired Macs rows with last connected · extended FAB "Pair new Mac" · content not under status/nav bars.
**Android — Pairing prompt:** heads-up notification with code + Allow/Deny · in-app dialog code in large monospace, grouped 3+3.
**Android — Phone launcher:** only a docked search bar and the icon grid; columns increase on wider displays.
**Copy (all):** sentence case · no "virtual display/stream/HMAC/port" outside Connect manually · max one helper line per element.
