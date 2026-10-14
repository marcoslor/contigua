# Dock and Launchpad apps (ROADMAP #6)

Each phone app can get its own Mac app identity: a Dock icon with the app's real
icon and Launchpad, Spotlight and ⌘-Tab entries named "WhatsApp (Phone name)".
Launching it opens (or focuses) that app's PocketDeck window; quitting it closes it.

## Shim bundle

```
<folder>/WhatsApp (Pixel).app/Contents/
  Info.plist           CFBundleIdentifier dev.pocketdeck.dock.<profile.>?<deviceId>.<pkg>
                       CFBundleName/DisplayName "WhatsApp (Pixel)", CFBundleIconFile AppIcon,
                       PDDeviceId, PDPackage, PDProfile, PDHostPath (the PocketDeck.app that made it)
  MacOS/PocketDeckShim the shim binary, copied from the host's Contents/MacOS
  Resources/AppIcon.icns from IconCache (icons/<deviceId>/<pkg>.png), 16–1024 px
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

## Launch → window (IPC)

The shim is a regular AppKit app with no windows. On launch, on a Dock click (reopen) and
when it is activated (⌘-Tab) it posts the distributed notification
`dev.pocketdeck.dock.open` (object = profile name; userInfo deviceId, pkg, pid). The host
answers `dev.pocketdeck.dock.opened` (pid) and opens the window, or brings an open one to
the front. Until that answer arrives the shim re-posts every second; after 2 s with no host
running from PDHostPath it launches that bundle (`--profile <profile>`); after 30 s it quits.

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

## Dock and ⌘-Tab while the window is open

The host owns the window (it owns the session and the video layer); the shim stays running as
the window's Dock and ⌘-Tab identity. Selecting the shim (Dock click or ⌘-Tab) forwards
`open` and the host brings the window forward, so the shim acts as the switcher for it.
PocketDeck itself keeps its own Dock icon. Rejected: rendering the stream inside the shim
(a second session or frame forwarding, double the cost) and swapping the host's Dock tile per
window (`NSApp.applicationIconImage` is per process, not per window).

## Lifecycle

- Create: Deck → app context menu → **Add to Dock**. The shim is created and launched,
  so it appears in the Dock; the person chooses Options → Keep in Dock. PocketDeck never
  writes the Dock's preferences. Remove: the same menu → **Remove from Dock App**.
- One set per phone: the id and file name include the phone, so the same app on two phones
  gets two shims; re-adding replaces the bundle in place.
- Cleanup: when a phone's app list arrives, shims of packages no longer on it are removed and
  shims whose name changed (phone renamed, app relabelled) are rebuilt; forgetting a phone
  removes all of its shims. Removal = `lsregister -u`, then delete. Decisions are a pure
  function of (shims on disk, app list, phone name), unit-tested.
