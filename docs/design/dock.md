# Dock and Launchpad apps (ROADMAP #6)

Each phone app can get its own Mac app identity: a Dock icon with the app's real
icon and Launchpad, Spotlight and ⌘-Tab entries named "WhatsApp (Phone name)".
Launching it opens (or focuses) that app's PocketDeck window; quitting it closes it.

## Shim bundle

```
<folder>/WhatsApp (Pixel).app/Contents/
  Info.plist           CFBundleIdentifier dev.pocketdeck.dock.<profile.>?<deviceId>.<pkg>
                       CFBundleName/DisplayName "WhatsApp (Pixel)", CFBundleIconFile AppIcon,
                       PDDeviceId, PDPackage, PDProfile, PDHostPath (the PocketDeck.app that made it),
                       PDLabel (the phone's raw label), PDOrigins (why the bundle exists, §Shortcuts)
  MacOS/PocketDeckShim the shim binary, copied from the host's Contents/MacOS
  Resources/AppIcon.icns rendered by PhoneAppIcon (all sizes from one 1024 px render)
```

- The folder is `~/Applications/PocketDeck Apps/` for the default profile (where Launchpad
  and Spotlight find apps), the profile's Application Support folder otherwise, or
  `--dock-dir DIR` (the e2e check uses a temp folder).
- Bundle ids are built only from `[A-Za-z0-9-]` pieces (`_` and anything else → `-`), so a
  hostile package or device id can neither escape the id nor collide across phones.
- Names: the file name drops `/` and `:` and a leading `.`; Info.plist values are written
  by `PropertyListSerialization`, so no escaping can break the plist.
- Signing: the copied binary is ad-hoc signed with the bundle (`codesign --sign -`), like the
  host; then `LSRegisterURL` so `open`, Launchpad and Spotlight see it at once.

## Icons

One renderer, one image. `PhoneAppIcon.render(layers:flat:px:)` (pure CoreGraphics, no
window) makes every app icon the Mac draws: the Deck tile, the Dock shim's `AppIcon.icns`,
Spotlight thumbnails. The same pixels at different sizes, so a phone app looks the same in
every place.

### Shape, grid and finish

- Canvas 1024×1024, body 824×824 centred (100 px margin on every side), transparent
  outside the body. The body is a continuous squircle (a superellipse, exponent 4.9) whose
  corner radius is 22.5 % of the side (185 px at 824) — the same fraction as the Deck's
  glass tile (`GlassIcon.cornerFraction`).
- Adaptive icons: `bg` then `fg` at **full opacity**, each cropped to the central 72 dp of
  its 108 dp layer (the tile's `cropRect`/`zoomFactor` math, `zoomFactor` 3/2), clipped to
  the body. No tint, no material over the colours: this is what the phone's launcher draws,
  in Apple's shape.
- Legacy (flat) icons are drawn by their own shape. The alpha is trimmed to its opaque
  bounds (alpha > 0.5), and `PhoneAppIcon.flatFit` decides between cover and plate:
  - **Cover** when the trimmed outline is a square or a rounded square: near square (ratio
    ≤ 1.05), every edge's middle opaque, the four corner radii within 2 px or 6 % of the
    side, and the measured coverage the one that radius explains — a rounded square loses
    (4 − π)·r² of its bounds to its corners, ±0.03, and at least 0.8. The crop is 0.3 × the
    measured corner radius in from each side (never more than 0.13 of the side), so the
    icon's own rounded corners land outside the squircle and no transparency is left inside
    it; the crop aspect-fills the body, clipped to the squircle. **No plate is drawn under
    a cover**, so a cover has no plate colour to get wrong.
  - **Plate** for everything else — a circle, a logo on transparency, an outline whose four
    corners disagree (a baked soft shadow, a bitten corner): the flat image at 78 % of the
    body. The plate is the median colour of the icon's outer opaque ring (the outer 5 % of
    its bounds, at least 2 px), unless that colour is within ΔE 15 of the logo's own mean
    colour — then it stays white, as before.
- Finish: two constants only — a soft top light (white 0 → 5.5 % over the top 40 % of the
  body) and a thin inner specular edge (2 px at 8 % white, inset 1.5 % of the body). Neither
  changes the colour at the centre (unit test: ΔE below 2 against the layer's colour).
- Drop shadow: black at 30 %, blur 24 px, offset (0, −12) inside the margin, so the icon
  has the platform's lift without drawing outside its canvas.

### Sizes and caching

- `apps.icon` gained an optional `px`: the pixel side of the 108 dp layer (default 216,
  clamped to 216…1296). The phone renders `fg`/`bg`/`mono` at that size; `flat` stays 96 px
  unless `px` is given, then it is rendered at `px`·2/3. An older phone ignores `px` and
  answers at 216: the Mac upscales those, which is still better than a 96 px flat icon.
- The Deck asks 432 and renders the 56 pt tile from a 224 px render; building a Dock shim
  asks 1296 and renders one 1024 px icon (its 864 px visible crop downscales into the
  824 px body, so nothing is upscaled), from which every `.icns` size is scaled.
- A covered flat icon is the one source a render enlarges, because its crop is smaller than
  the tile by design. The Deck's request gives a 288 px flat and stays under 1.0: 0.84× at
  worst, a 38 % rounded square's 0.745 crop (a 10 % margin's 0.77 crop is 0.82×). The Dock's
  gives 864 px and costs 1.28× at worst. No cover crops more than 0.13 of a side, which
  keeps the rule's ceiling at 1.29×. The Dock shim therefore reads the flat of its own size
  class, and `icon_covered_flat_scale` in docs/NFR.md holds the 1.3× bound: past it, the
  shim drew a covered icon from the Deck's flat, or the crop rule was widened.
- `IconCache` keeps one slot per size class (`deck` = 432, `dock` = 1296), so a 1296 render
  is never replaced by a 216 one; entries from before size classes are read as `deck`.
- The shim's `Info.plist` carries `PDIconVersion`, bumped with the renderer. A shim with an
  older or missing version is rebuilt the next time it is followed or launched, then
  `lsregister -f` runs on it so the Dock reads the new icon. Shims of other profiles are
  never touched.

### Result (2026-10-20, macOS 26 in the e2e VM)

A shape-perfect legacy `.icns` is **not** put in the grey plate: the shim's tile sits in
the Dock at the same size and shape as the native icons around it, with its own white
squircle and the phone's colours, and the Deck grid draws every app in one shape
(adaptive layers at full opacity; flat icons covered by their own shape or on their
edge-tinted plate). The `.icns` carries a
1024 px representation, its canvas corners are transparent and its centre is the bg
colour — the dock e2e asserts all three. The real Mac's Dock with the user's own apps is
still unverified (test profiles only).

### Emulator numbers (2026-10-20, API 36, `tools/emulator/verify-batch.sh`)

The phone side of `apps.icon` ran on a device for the first time, on three
system apps with `px` 216 and 1296:

| px asked | flat PNG | fg/bg/mono layers | render |
|---|---|---|---|
| 216 | 144×144 px, 3.3–12.0 KB | 216×216 px each | 261–446 ms |
| 1296 | 864×864 px, 45.7–203.5 KB | 1296×1296 px each | 652–693 ms |

The flat icon is exactly `px`·2/3 and every layer exactly `px`, all three apps
sent fg and bg (two also `mono`), and the 1296 fg/bg PNGs were saved under
`.agent/rig-verify/icons/` and checked by eye: the visible artwork sits inside
the central 72 dp of the 108 dp layer, as `IconSizes`/the launcher crop expect.
Render times are software-GPU emulator numbers and say nothing about the phone.

### Step 0: can a runtime-built icon get Liquid Glass?

No supported runtime path exists. macOS 26 only draws a layered Liquid Glass icon from an
`Assets.car` built from an Icon Composer `.icon` package by `actool` (Xcode 26) and named by
`CFBundleIconName` — Apple's "Creating your app icon using Icon Composer" and WWDC25
session 361, which describe the `.icon` → `Assets.car` pipeline as the only delivery route.
`iconutil` converts `.iconset`/`.icns` and extracts icons from an existing `.car`; it cannot
write layers. `CFBundleIconName` names a catalog entry, and no public API writes
`Assets.car`. `NSWorkspace.setIcon(_:forFile:options:)` and `NSApplication.applicationIconImage`
take a single bitmap, which the platform treats as a legacy icon (the grey plate). A stock
Mac has no `actool` either (it ships with Xcode). So the shim keeps a shape-perfect legacy
`.icns`; step 5 records what the platform does with it.

## Launch → window (IPC)

The shim is a regular AppKit app with no windows. On launch, on a Dock click (reopen) and
when it is activated (⌘-Tab) it posts the distributed notification
`dev.pocketdeck.dock.open` (object = profile name; userInfo deviceId, pkg, pid). The host
answers `dev.pocketdeck.dock.opened` (pid) and opens the window, or brings an open one to
the front. Until that answer arrives the shim re-posts every second; after 2 s with no host
running from PDHostPath it launches that bundle (`--profile <profile>`); after 30 s it quits.
A shim started by the automatic path (`--no-open`) skips the first `open`: its window is
already open, so the host binds it or stops it, and only a person's later Dock click asks
for a window.

Why distributed notifications: both sides are unsandboxed, they need no registration or
entitlement, and the profile name as `object` keeps a test copy from ever reaching the
user's app. The `pocketdeck://` scheme was rejected because LaunchServices picks *one*
app for a scheme (with several copies registered — the installed app, a dev build, the e2e
build — the wrong one would get it) and it gives no way to answer. XPC/Mach services need a
launchd job; Apple Events need an automation permission prompt.

## Quit ↔ close

- Quitting the shim (Dock → Quit, ⌘Q while it is frontmost) posts `dev.pocketdeck.dock.quit`;
  the host also watches `NSWorkspace.didTerminateApplication` for the shim's pid, so a force
  quit or crash closes the window too.
- Closing the window (or the phone closing the stream, forgetting the phone) posts
  `dev.pocketdeck.dock.closed` (pid) and the shim exits, so a Dock icon never outlives its window.
- An automatic identity still building or launching when its window closes is dropped
  (nothing built) or quit the moment its pid arrives, and is never bound: a shim bound to a
  closed stream has no event left that would ever stop it. Quitting PocketDeck likewise
  stops any automatic shim it launched that no window owns, including one whose launch is
  in flight at quit.

## Dock and ⌘-Tab while the window is open

The host owns the window (it owns the session and the video layer); the shim stays running as
the window's Dock and ⌘-Tab identity. Selecting the shim (Dock click or ⌘-Tab) forwards
`open` and the host brings the window forward, so the shim acts as the switcher for it.
PocketDeck itself keeps its own Dock icon. Rejected: rendering the stream inside the shim
(a second session or frame forwarding, double the cost) and swapping the host's Dock tile per
window (`NSApp.applicationIconImage` is per process, not per window).

## Shortcuts (Launchpad, Spotlight and other launchers)

A **shortcut** is the same shim bundle as a Dock identity: same folder, same
icon, same "App (Phone)" name. A shortcut in an `~/Applications` subfolder is
listed by Launchpad, Spotlight and other launchers; a CoreSpotlight item is not an app,
so it never is. One mechanism, four reasons a bundle exists — its **origin set**:

| Origin | Asked for by |
|---|---|
| `dock` | Add to Dock (today's `pinned`) |
| `manual` | Add to Applications on one app |
| `all` | the phone's "Save all apps as shortcuts" switch |
| `window` | the automatic identity of an open window (today's unpinned) |

The bundle stays while the set is non-empty, and removing an origin removes only
that origin, so two features can never silently delete each other's shortcut. A
record from before the set existed migrates its `PDPinned` marker: pinned (or
missing, the old default) → `dock`, unpinned → `window`.

- **Per phone: Save all.** Settings ▸ a phone ▸ Applications ▸ "Save all apps as
  shortcuts", off by default, stored per phone id. On: every app of that phone
  gains `all`. Off: `all` is removed from every shim of the phone; a shim another
  origin keeps is rewritten, the rest are removed. A phone that is offline keeps
  its shims.
- **Per app: Add to Applications / Remove from Applications** in the Deck tile's
  menu, next to Add to Dock (origin `manual`). Remove takes only `manual`; with
  Save all on, the App already in Applications offers Add (which makes it stay
  when Save all is turned off), never a silent delete of the `all` shim.
- **Icons.** Save all may build ~230 bundles: the Dock's 1296 px icons are
  requested at most four at a time, and each shim is built when its icon answers,
  off the main thread. A shim is always drawn from the Dock's size class
  (§Icons), never from the Deck's 288 px flat.
- **Reconcile on every app list** (connect, refresh, nickname): an uninstalled app
  loses `all` and `manual` — it keeps a shim only while `dock` or `window` holds
  it; a new app gains `all` when Save all is on; a renamed app or phone rebuilds
  its shims (the existing rule). Forget a phone: every shim of that phone goes,
  whatever its origins.
- **Spotlight duplicates.** An app with a shim is not also a CoreSpotlight item:
  its item is removed when the shim appears, and the phone's list is indexed
  again (without it) when the shim goes away.

## Lifecycle

- Automatic: a phone app's window opening — from the Deck, Spotlight, a link,
  anything — makes its Dock identity appear, while **Settings → General → "Show phone
  apps in the Dock"** is on (default). The window never waits for it: the bundle is
  built off the main thread, and only once the app's real icon is cached — or the
  phone says it has none — so the Dock never shows a blank tile. An identity already
  on disk (kept from Add to Dock) is simply launched. The phone mirror window gets
  none. With the setting off nothing runs automatically and the menu item below
  still works; turning it off also stops the running automatic identities (the
  ones whose origins hold only `window` — their windows stay open, the bundles
  stay on disk), while ones added by hand keep running with their windows.
- Manual: Deck → app context menu → **Add to Dock** creates and launches the shim
  regardless of the setting; the person chooses Options → Keep in Dock. PocketDeck
  never writes the Dock's preferences. Remove: the same menu → **Remove from Dock App**.
- The shim's process lives while a window of its app is open: the host posts
  `closed` when the window closes, and while two windows of one app are open the
  identity follows the one that is left. The bundles stay on disk, so a later
  window only launches the identity again.
- One set per phone: the id and file name include the phone, so the same app on two phones
  gets two shims; re-adding replaces the bundle in place.
- Cleanup: when a phone's app list arrives, an uninstalled app loses the `all` and `manual`
  reasons (its shim goes unless `dock` or `window` keep it), and shims whose name changed
  (phone renamed, app relabelled) are rebuilt — except shims of open windows, which follow
  when their window is gone; forgetting a phone removes all of its shims. Removal =
  `lsregister -u`, then delete. Decisions are a pure function of (shims on disk, app list,
  phone name, Save all), unit-tested; so is whether a window's identity is created,
  relaunched, skipped or waits for its icon.
