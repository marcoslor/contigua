# Links Mac → phone (ROADMAP #5)

Send a link from any Mac app to a phone; it opens in the Android app that handles it,
in a new PocketDeck window (its own virtual display).

## Entry points (Mac)
- **Share menu** "Open on Phone": a Share extension (`Share.appex`, `com.apple.share-services`)
  in `Contents/PlugIns`, built by `scripts/bundle.sh` with swiftc (SwiftPM cannot link an
  extension entry point). Sandboxed, ad-hoc signed, no UI: it takes the first web URL item
  (or text that is / contains exactly one link), hands it to the app and closes. Activation:
  `SupportsWebURLWithMaxCount 1` + `SupportsText`; text without a link cancels the request.
- **Services** "Open on Phone" and **dragging** a URL / `.webloc` onto the Deck.
- **Hand-off (internal pipe)**: the extension opens `pocketdeck://open?url=…[&phone=id]` with
  `NSWorkspace.open(_:withApplicationAt:)` naming its *containing* app, so LaunchServices can
  never route it to another PocketDeck copy. The open does not activate the app: the person
  stays in the app they shared from and the link opens on the phone (the app's own link path
  decides what to show). The sandbox allows this (verified), and it needs no
  app group, XPC service or shared container. The scheme is plumbing, not a user feature.
- Only `bundle.sh --variant release` (install.sh) uses the id `dev.pocketdeck.mac.share`; other
  bundles get `dev.pocketdeck.mac.share-<variant>` titled "Open on Phone (<variant>)", and
  check-e2e unregisters its copy (`pluginkit -r`, `lsregister -u`) on exit.

## Validation (both sides, same rules)
Allowed schemes: `http`, `https`, `geo`, `tel`, `mailto` (case-insensitive). Rejected:
anything else (`intent:`, `file:`, `content:`, `javascript:`, `android-app:` …), empty
input, more than 8 KiB of UTF-8, whitespace or control characters inside the URL,
`http(s)` without a host. Leading/trailing whitespace is trimmed (pasted text).
`intent:` and `content:` would let a link pick any component or read private files on the
phone; the shell UID makes that worse, so the phone re-validates and never trusts the Mac.

## Protocol
`{"t":"link.open","stream":N,"w":..,"h":..,"dpi":..,"url":"https://…"}` — like
`window.open`, but the phone starts `ACTION_VIEW` with that data URI
(`CATEGORY_BROWSABLE`, `FLAG_ACTIVITY_NEW_TASK`) on the new display. Android's own
resolution picks the app: verified app links (Maps, YouTube…) open their app, the rest the
default browser; with no default the system chooser shows on that display.
Replies are those of `window.open` (`window.opened`, video, `window.title`, `window.closed`
with `app_exited` when the task goes away). A rejected URL → `error` `bad_url` (no display
is created); no handler → `launch_failed`.

## Phone side
`WindowContent.Link(url)` next to `App`/`Phone`. `Launcher.view(displayId, url)` uses the
same `IActivityManager.startActivity` + `setLaunchDisplayId` path as app launches, falling
back to `am start --display N -a android.intent.action.VIEW -d <url>` run as an argv array
(never through `sh -c`, so a URL can't inject shell syntax).

## Multi-phone picker
- `phone=<id>` given and paired → that phone.
- One paired phone → it.
- Several → a small sheet "Open on which phone?" listing remembered phones (connected one
  first, preselected). If the choice isn't the connected phone, the Mac switches to it and
  sends the link after `welcome` (same deferred path as Spotlight opens).
- None paired → the Deck shows "Pair a phone to open links on it."

## Alternatives rejected
- Extending `window.open` with `url`: an older phone would ignore the field and fail on the
  missing `pkg` with a misleading error; a new `t` is ignored cleanly.
- `am start` through `sh -c`: shell injection via the URL.
- Sending to the phone's default display: unlocks/lights the phone; breaks the locked-phone promise.
- Allowing `intent:`: arbitrary component launch with shell privileges.
- Extension → app over an app group / XPC: needs a team-signed app group; the URL pipe works ad-hoc.
