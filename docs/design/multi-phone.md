# Several phones at once — audit and plan

Feature 2 of `ISSUES.md` § 5. This document is docs only: it reads the Mac and
the phone code, names every place the app assumes one phone, and then plans the
change. It does not change product code, the wire, or any spec. The audit is
against `main` at `3144abd1`.

Today the Mac pairs with more than one phone and talks to one at a time. That
one-phone assumption is not in the wire protocol: `welcome` already carries the
phone's own id, the pins are stored per phone, and one session already belongs
to one Mac-phone pair (`docs/design/paths.md`). The assumption lives in the Mac
app's ownership layer: one `Session`, one `Link`, one current phone, and one of
each per-surface object (a File Provider domain, a notification store, a Now
Playing entry, an audio engine). The phone side is a separate limit: one phone
serves one Mac at a time.

The target is **one session per phone on the Mac**, each with its own state
machine, and one phone at a time on each phone. A person with a work phone and
a personal phone, or a household with several phones paired to one Mac, can
then have every phone connected without any of them ending another's session.
The rest of this document is the evidence for that sentence and the order in
which to build it.

## 1. What is true today

### 1.1 The Mac: one owner for one phone

`ConnectionController` is the app's single owner of the live connection. It
holds:

- `private var session: Session?` — the one live `Session`;
- `private(set) var machine = LinkMachine()` and the computed `link` — one
  connection state for one phone;
- `activePhone` — `link.phone ?? remembered.active?.ref`, the one phone the
  Deck, the menu-bar panel and the menus act on;
- one each of the per-surface objects: `clipboardSync`, `fsClient`,
  `filesBridgeClient`, `apkInstaller`, `dropSender`, `audio`, `notifyCenter`,
  `nowPlaying`, `filesDomain`, `shareInbox`, `mcp`.

Every session event arrives through one closure, and the closure guards
`newSession === self.session`; every video event is guarded again inside
`WindowManager.handleVideo` by `source === current`. `ConnectionController.start`
calls `windows.attach(newSession)`, so opening a session for a second phone
detaches the first phone's windows from video and input. `use(_:)` goes further:
it closes every window, closes the session, stops clipboard sync and resets the
app list, status and icons before connecting the chosen phone.

Pairing is also built on the one link: `beginPairing` closes the live session
and every window before it shows the sheet, and the `pairing` state is a case of
the one `LinkMachine`. Two phones can be remembered and pinned; they cannot be
live together.

### 1.2 The phone: one Mac at a time

The phone's `Server` binds one listener and hands each accepted socket to one
`SessionSlot`. The slot is one state machine — `Free`, `Live`, `Draining`,
`Handing` — and it decides from the peer certificate and the `hello`:

- a second Mac gets `error busy`, unless the live session's own pinned Mac is
  reconnecting;
- the live session's own Mac connecting again without `join` supersedes the old
  session after its teardown (at most 2 s);
- the same Mac connecting with a matching `join` attaches one more path to the
  live session.

The phone's pairing store is already a list of Macs (`Prefs.PairedMac`), and
`NsdAdvertiser` advertises one identity and one port. So the phone can pair many
Macs, but it serves one at a time. That is a phone-side product limit, not a
Mac-side one; it does not block a Mac from holding one session to each of
several phones.

### 1.3 What the specs already say

Every surface spec has a "Phone count and connection" section and answers
`CONV-PD-01`. Most of them describe today's model precisely: the phone **in
use**, and Settings ▸ Use This Phone as the only switch. Some already describe a
per-phone surface that the code does not have (Live items and history,
notifications grouped per phone, one Phone Mirror per phone, every phone's row
in Settings). Section 4 compares the two. The specs are not edited here; the
lines that must change are listed in section 13.

## 2. The audit

One row per place where the code ties a surface to one phone. "Size" is the
change to make that place work with two connected phones, not the size of the
whole feature:

- **S** — a key, a parameter or a field: the data is already per phone, or the
  object only needs to be told which phone it serves.
- **M** — one owner type becomes per-phone: a single object, dictionary or
  state machine must exist once per phone.
- **L** — a new layer: the place has no per-phone identity at all and needs a
  registry, a keyed store, or a second instance with its own lifetime.

### 2.1 The session and its state

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| S1 | `ConnectionController.swift: ConnectionController.session` | The one live `Session`; every attempt ends here | Every surface, through `link` and the session event closures | A second session replaces the first (`start`), and the first phone's events are dropped by `newSession === self.session`. `windows.attach` makes the first phone's video and input go nowhere. | L |
| S2 | `ConnectionController.swift: ConnectionController.machine`, `Link.swift: Link`, `LinkMachine` | One `LinkMachine` and one `Link` value: the closed states idle, connecting, online, reconnecting, offline, needsPairing and pairing for one phone | Deck chip and banner, menu-bar icon and panel, menus, Settings presence, window "Reconnecting…" pills | Only one phone can be connecting or online. The second phone's transition overwrites the first phone's chip, banner and retry clock; the first phone has no state left to show. | M |
| S3 | `Session.swift: Session`, `SessionState`, `PathLayer` | One TLS session, one session id, one to three paths, one `SessionState` machine, one event stream | `ConnectionController`, `WindowManager`, `FsClient`, `ClipboardSync`, `FileDropSender`, `ApkInstaller` | Nothing in the class assumes one phone: it is already one per Mac-phone pair (`docs/design/paths.md`). The assumption is in its owner (S1) and in the event routing (S5). Two instances are two independent sessions. | S |
| S4 | `ConnectionController.swift: runAttempt`, `attemptTimer` | One attempt at a time and one backoff index for the one phone | Connection retries | A reconnect for the second phone cancels the first phone's pending attempt (`attemptTimer?.cancel()`), and `runAttempt` always reads `link.phone`. The first phone can be left offline with no retry. | M |
| S5 | `ConnectionController.swift: handle(_:)` | The one event funnel: every event is attributed to `link.phone` or `session?.phone`; failure paths clear global state | Every surface | A second phone's `welcome`, failure or path outage is written into the first phone's state. A failure on either phone calls `notifyCenter.clearAll()`, `nowPlaying.clear()`, `filesDomain.sessionReady(false)` and stops the one clipboard sync, so one phone's drop clears the other phone's banners, media and Finder state. | L |
| S6 | `ConnectionController.swift: activePhone`, `RememberedPhones.active` | One current phone id, and the fallback to the most recently used phone | Deck title and grid, panel header, menus, Settings presence, Files location name | One phone is "the" phone. With two online, the other is invisible to every surface that says "the phone"; there is no data for it. | S |
| S7 | `ConnectionController.swift: use(_:)` | The switch: set active, `windows.closeAll()`, `closeSession()`, `resetPhoneData`, activate the new phone | Settings ▸ Use This Phone, links, intents, Spotlight clicks | Switching to the second phone ends the first phone's session and closes all its windows. Both phones can never be live across a switch. | M |
| S8 | `ConnectionController.swift: pathOutage`, `WindowManager.linkPhase` | One path-outage phase and one reconnect phase for every window | Deck chip, panel, every stream window | A path outage on one phone makes every window, including the other phone's, say "Reconnecting…" then "Phone offline"; a restore does the same in reverse. | M |
| S9 | `ConnectionController.swift: resetPhoneData` | One `apps`, `appsLoaded`, `status`, `icons`, `iconLayers`, `deckIcons` set | Deck grid, panel, window covers, Settings | The second phone's `welcome` resets the first phone's grid and clears its icons; both phones share one app list and one status. | M |

### 2.2 Pairing and pins

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| P1 | `ConnectionController.swift: beginPairing`, `pairingTarget`, `Link.pairing` | The one pairing attempt; it closes the live session and all windows before the sheet | Pair sheet, QR sheet, phone prompt | Pairing the second phone disconnects the first and closes its windows; the pairing state lives in the one `LinkMachine`, so a live session cannot be shown while pairing. | M |
| P2 | `TlsV2.swift: PhonePinStoreV2`, `IdentityPinMirror`, `identity.pin` | One pin record per phone (correct), and one `identity.json` mirror naming a phone | TLS dial per phone; e2ee docs | The store is already right. The mirror names the last phone that became ready, so with two online it names one of them; it is a mirror, not the check (the TLS layer uses the dialed phone's record), so trust is not broken, but the field no longer means "the phone in use" unless "in use" is the last ready. | S |
| P3 | `Discovery.swift: Discovery`, `QRProbePlanner`, `ConnectionController.nearby` | One Bonjour browser returning every phone; the QR probe planner and the Nearby list already take a set | Deck Nearby, Add Phone, QR sheet | Nothing: discovery, the Nearby list, the QR probe planner and `NearbyPhone` already handle any number of phones. Only the dial loop (S4) and the current phone (S6) assume one. | S |

### 2.3 Phone files in Finder

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| F1 | `FilesDomain.swift: FilesDomain.identifier`, `FilesDomain.displayName`, `FilesDomainController` | One File Provider domain per profile; its display name is built from `RememberedPhones.active`; one reconnect/disconnect state | Finder's PocketDeck location, Settings ▸ General, the Deck | Only one phone's storage can be mounted. Switching phones renames the one domain and reattaches the one bridge, so the first phone's cached files and identifiers are presented as the second phone's. The name follows `remembered.active`, not the live session, so a connected phone that is not active is named on the location that another phone serves. | L |
| F2 | `FilesBridge.swift: FilesBridge.shared`, `SessionBridgeHost` | One app-group socket, one accepted client set, one `FsClient`, one watch set, one thumbnail queue; `attach` cancels the previous host | The File Provider extension, the app's bridge | A second phone's `ready` calls `attach` and cancels the first host: its watch set, thumbnails and in-flight reads are abandoned. Requests carry only an item id, so the second phone's id 5 can answer the first phone's request 5. | L |
| F3 | `FilesCore.swift: FilesIdMap`, `FilesReplica`, `FilesChanges` | One id ↔ path map and one durable replica/change log per profile, keyed by path and inode | The bridge and the extension | Both phones use path strings such as `DCIM/Camera/IMG_0001.jpg`; one map and one replica cannot tell them apart. A deletion or rename on one phone can delete or repoint the other phone's item in Finder. | L |
| F4 | `macos/` File Provider extension (`NSFileProviderReplicatedExtension`) and `FilesDomain.domain(profile:)` | One domain whose identifier is the profile name; the extension asks the one app socket | Finder, the system's File Provider daemon | The extension has no way to name a phone. A second domain cannot be added without a second identifier and a way for the extension to choose the right socket or phone. | L |

### 2.4 Notifications, Live and media

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| N1 | `NotifyCenter.swift: NotifyCenter.known`, `knownOrder`, `requestIds`, `postCounts`, `pending`; `clearAll()`, `remove(id:)`, `snapshot(ids:)` | Notification state keyed by the phone's notification id only; posts themselves carry `phoneId` | Notification banners, Notification Center, the panel, the Deck | Android notification ids are small integers per app, so two phones can both post id 5. `known[5]`, `pending[5]` and `requestIds[5]` then collide: one phone's banner, attachment, update or removal replaces the other's. `clearAll()` on any session end or path outage removes every phone's banners. | M |
| N2 | `NotifyCenter.swift: NotifyLiveStore`, `NotifyLiveItem`; `ConnectionController.liveNotifications`, `livePhoneName` | One live row store keyed by notification id; `NotifyLiveItem` has no phone id; the panel names the current phone | Menu-bar LIVE section, panel LIVE rows, Live cards | Two phones' live items with the same id collide. A live item cannot say which phone it belongs to, and "Live on <phone>" always names the current phone even when the rows came from another phone. The spec (`live.md`) already promises per-phone items, allowlists and history. | M |
| N3 | `NowPlaying.swift: NowPlayingController` | One `MPNowPlayingInfoCenter`, one `MPRemoteCommandCenter`, one current media state and artwork; `onCommand` sends to `self.session`; `clear()` wipes the platform entry | macOS Now Playing, Control Center, the menu-bar media row, the panel | The second phone's media replaces the first phone's. A transport command for the displayed track goes to the current session, which may be the other phone. A session end on either phone clears the one entry, so the other phone's track disappears. | M |
| N4 | `ConnectionController.swift: mediaNow`, `mediaSessions`, `mediaArt` | One mirror of the phone's media state for the observed UI | Panel, menu bar media row | One phone's media only; the second phone's state and artwork are overwritten. | S |

### 2.5 Clipboard, links, share, audio

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| C1 | `ClipboardSync.swift: ClipboardSync`, `ConnectionController.startClipboardSync` | One poll of the general pasteboard, bound to one session; one global `shareClipboard` switch | Clipboard sync, ⌘V with text, `clip.set` | `startClipboardSync` stops the previous sync and starts one for the new session, so only one phone can sync. A window on the other phone has no clipboard path; a copy on the Mac cannot be routed by window. | M |
| C2 | `AudioEngine.swift: AudioEngine`, `ConnectionController.syncAudio` | One `AVAudioEngine`, one output route, one jitter buffer; audio starts for the one session with any open window; the audio event closure ignores a non-current session | Phone audio in the Mac's output, the menu-bar volume/mute | Only the current phone's audio is captured or played. If it were wired for two, both phones' PCM would mix into one route with one gain. `audio.stop` on any window close stops the one engine. | M |
| C3 | `OpenLink.swift: LinkRoute`, `PhonePicker`; `ConnectionController.openLink(_:on:)` | The route is already per phone (named, one, picker, wait); the send path switches with `use` | Share extension, Services, a dropped URL, `pocketdeck://open` | A link to the second phone calls `use`, which closes the first phone's windows and session. A pending link is one queue. Routing itself needs no new model. | M |
| C4 | `ShareIn.swift: ShareInbox`, `ShareFileReceiver` | One inbox; `phoneName` and `phoneId` are mutable fields set just before an event; the file receiver is keyed by file id | Share phone → Mac: browser, clipboard, Downloads, notification | A file from the second phone assembling while the first phone shares is attributed to whichever phone set the fields last; file ids are per session and collide, so one phone's bytes can be written under the other phone's share. | M |
| C5 | `FileDrop.swift: FileDropSender` | One active drop, one id counter, one session, one resume-hint map | A drop on a window or the Deck, the drop pill | A drop to the second phone is refused `busy` behind the first, or is sent to the first session. Ids and resume hints are not phone-scoped. | M |
| C6 | `ApkInstall.swift: ApkInstaller` | One install, one id, one session; `onInstalled` asks the current session for its app list | Install APK, a dropped package, Open With | An install on the second phone waits behind the first or goes to the first session. One install at a time per Mac instead of one per phone. | M |
| C7 | `ClipboardSync.swift: ClipImageBuffer` (held in `ConnectionController`) | One image assembly for the phone → Mac clipboard-image direction | Paste from the phone, drag-out | Two phones' image ids collide; one phone's image can be completed with the other's bytes or written to the wrong window's paste flow. | S |

### 2.6 Windows, the Deck, the panel and the menus

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| W1 | `WindowManager.swift: WindowManager.session`, `attach`, `handleVideo`, `streams`, `nextStream` | One session, a stream table keyed by a stream id allocated from 1, a source guard on video | Every stream window, the Window menu, the Deck, menus | A second phone's `window.open` has no session to go to; `handleVideo` drops a non-current session; stream ids restart at 1 for each session, so a `(stream, phone)` pair is needed to route frames, input and closes. `openStreams` counts one phone's windows as if they were all. | L |
| W2 | `WindowManager.swift: phone`, `phoneName`, `maxWindows`; `AppWindowController.retitle`, `WindowTitles` | One phone's info, one display name, one window cap; every title uses `manager.phoneName` | Window titles, opening covers, New-window items, the Window menu | The second phone's window would carry the first phone's name in its title and cover. The cap counts one phone's streams, and `setPhoneName` retitles every window at once. | M |
| W3 | `WindowManager.swift: linkPhase`, `phoneScreen`, `setPhoneScreen`, `setPhonePanel`, `setPhoneSecure` | One reconnect phase and one phone-screen state broadcast to every window | Reconnect pills, the Mirror's screen-off cover, the secure-surface cover | A path outage or a screen/lock change on one phone shows on the other phone's windows and mirror. | M |
| W4 | `WindowManager.swift: phoneWindow`, `openPhoneWindow`, `togglePhonePanelOff` | One Phone Mirror window; one mirror per app run | Phone ▸ Phone Window (⌘P), the panel, the Deck, intents | Only one mirror can exist. Opening the second phone's mirror raises the first; switching phones closes it (`use` → `closeAll`). The spec promises one window per phone. | M |
| W5 | `StreamWindow.swift: StreamWindowController.session`; `AppWindow.deviceId`; `LinkWindow`, `PhoneWindow` | Every window talks to `manager.session`; only `AppWindow` carries a device id, and it is used for filtering, not for sending | Input, paste, drop, keyframes, open/close/resize | A window cannot send to its own phone. Input, ⌘V, a drop, a keyframe and a close all go to the manager's one session, which is the wrong phone whenever the window's phone is not current. `LinkWindow` and `PhoneWindow` have no phone id at all. | L |
| W6 | `WindowStyle.swift: WindowStyleStore`, `WindowDensity.swift: WindowDensityStore`, `WindowManager.streamFrames`, `frameKey` (`app.<pkg>`, `phone`, `link`, `handoff`) | Per-package style, density override and remembered frame; no phone in any key | Window chrome, View menu, Settings ▸ General, window placement | The same app on two phones shares one style, one density and one remembered frame. Two windows of the same app on two phones open on top of each other at the same place. | S |
| W7 | `DeckViews.swift: DeckView`, `ConnectionController.deckMode`, `apps` | One Deck mode (welcome/nearby/phone), one app grid, one title | The Deck window and its popover | The Deck can show only the current phone's grid. There is no way to see the second phone's apps or to switch phones from the Deck; Settings is the only switch. | M |
| W8 | `PhonePanel.swift: PhoneControlsState.from(controller:)`, `PhonePanelView` | One card built from one link, one status, one media state, one live list, one ringing flag, one install | Menu-bar panel, Deck popover | The card shows and controls the current phone only; the second phone's ring, volume, DND, screen and media cannot be reached from it. | M |
| W9 | `MenuBarModel.swift: MenuBarModel.currentSnapshot`, `MenuMarks.swift` | One menu snapshot from the one controller link and window set; checkmarks follow the key window | The app's menus, the status item's secondary-click menu | Phone items act on `link.phone`; a key window on the second phone still rings, mutes or installs on the current phone. No menu item names a phone. | M |
| W10 | `MenuBarPanel.swift: MenuBarController`, `MenuBar.swift: MenuBarGlyph` | One status item and one icon for the app | The menu bar | Nothing: the app should have one status item. Its icon must summarise several phones (see section 7), but the item itself stays shared. | S |

### 2.7 Settings, MCP, App Intents, Spotlight and the Dock

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| G1 | `SettingsSidebar.swift: SettingsSidebarModel.rows`, `DevicePieces.swift: DevicesPreview.presence` | Every remembered phone is a row; presence is the live `link` for the active phone and a staged/offline value for every other | Settings sidebar | A connected phone that is not in use reads "Offline" or a stale "last seen", because `presence` asks `controller.link` only for `activePhone`. | S |
| G2 | `PhoneSettingsPage.swift: header` (Use This Phone), `ConnectionController.use` | Per-phone page and one switch; the switch closes windows and the live session (`SET-DEV-03`) | Settings ▸ Phones | Using the second phone from its page ends the first phone's session and windows. The page's presence is the one link. | S |
| G3 | `MCPCore.swift: MCPCall`, `MCPTools.swift: MCPToolHost` | Phone-level calls have no phone argument; `phone_status`, `list_apps`, `open_app`, `send_link`, `send_file` resolve `IntentsBridge.resolve(nil)`; `list_windows` has no phone field | The automation server and an AI agent | An agent can act only on the current (or only) phone. It cannot name the second phone, cannot list its apps or windows, and `open_app` on the second phone fails or switches the current phone. | M |
| G4 | `IntentsBridge.swift: connectedId`, `IntentsCore.swift: IntentPhoneResolver` | Intents already take an optional phone and resolve by id or name; `connectedId` is one; `openApp`/`openPhoneScreen` call `use` when the target is not current | Shortcuts, Siri, Focus, Spotlight's intents | An intent can name the second phone, but acting on it switches the current phone and closes the first phone's windows. `PhoneAppEntityQuery` offers the resolved phone's apps only. | S |
| G5 | `Spotlight.swift: SpotlightIndex`, `DockApps.swift: DockApps.reconcile` and the per-device stores (`AppsCache`, `IconCache`, `BatteryMemory`, `ControlIntentStore`, `NotifyToggle`, `NotifyMute`, `NotifyClickTarget`, `PhonePanelOffSetting`, `SaveAllShortcutsSetting`) | Spotlight has one domain and one verification per device id; Dock shims and every listed store are keyed by device id | Spotlight search, the Dock, Settings, controls | The per-device stores are already right. Dock's `reconcile` runs only when that phone's `apps` event arrives, so the first phone's shims are not rebuilt from cache when the second becomes live; Spotlight is complete for every remembered phone. | S |

### 2.8 Stats and logs

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| L1 | `StreamStats.swift: StreamStatsLine.text`, the window and session log lines; `tools/stream-bench` | One `stats stream=<id>` line per window every 5 s; ids come from the one `WindowManager` allocator | The stats log, `stats-summary.py`, the stream bench | Stream ids are per session and both phones start at 1, so two windows on two phones both log `stats stream=1`. The summary and the bench cannot tell them apart, and no line carries the phone. | S |

### 2.9 The phone side

| # | Where (file: symbol) | What it holds | Read by | What breaks with two connected phones | Size |
|---|---|---|---|---|---|
| D1 | `Server.kt: Server`, `SessionSlot.kt: SessionSlot`, `SessionDropper.kt` | One listener, one live session, one slot (`Free`, `Live`, `Draining`, `Handing`); a second Mac gets `busy`, the same Mac's second connection supersedes or joins | The phone app, the Mac's path layer | Nothing on the Mac side: two phones are two independent slots, each with one Mac. A phone cannot serve two Macs; a Mac cannot hold two independent sessions to one phone. If the product ever wants a phone to serve two Macs, this is the L row, because the shared phone state (audio route, panel hold, clipboard owner, notification gate, window cap) has one owner each. | S |
| D2 | `Prefs.kt: PairedMac`, `DeckService.servedClients`, `NsdAdvertiser.kt` | A list of paired Macs; one identity, one advertisement and one port per phone | The phone's home, pairing, the Mac's discovery | Nothing: many Macs pair; one is live. | S |
| D3 | `AudioCapture.kt`, `PanelPower.kt`, `ShellClipboard.kt`, `NotifyGate.kt`, `WindowCap.kt`, `Server.shareText/shareFile/onDeviceEvent` | One capture owner, one panel hold, one clipboard owner, one notify gate and one window cap, each per live session; `Server.shareText`, `shareFile` and `onDeviceEvent` use `sessions.current()` | The phone's own surfaces and the Mac's features | Nothing while one Mac is live. With two live sessions they would fight for one owner each; the slot's teardown (`PAIR-21`) is the only arbiter today. This is the L side of the same "phone serves two Macs" question as D1. | S |

**Counts.** 46 rows: **16 S**, **22 M**, **8 L**.

The size spread is the point: most per-phone data already exists (pins, app
caches, icons, Dock shims, notification settings, control memory, Spotlight
domains). The work is not "make every store per phone"; it is "put the one
server-wide object above the per-phone stores" and then let the per-phone
surfaces read their own record.

## 3. Where the specs answer 2+ phones, and where the code disagrees

This table compares the spec's own 2+ answer with the code. "Spec right, code
wrong" means the code has to change even before the target model; "spec right
for today" means the spec is accurate about the one-phone app and must change
with the feature; "spec wrong" means the spec's 2+ answer never matched any
code.

| Surface (spec line) | What the spec says for 2+ | What the code does | Verdict |
|---|---|---|---|
| Notifications (`docs/specs/notifications.md:195`) | Each phone has its own switch, click target and mute set; a phone's notification state is cleared when that phone's session ends; banners are grouped and titled per phone. | The switch, mute set and click target are per phone. The notification stores are keyed by the phone's notification id only, and `clearAll()` clears every phone on any session end. | **Spec right, code wrong.** The per-phone guarantee fails on an id collision and on the clear. |
| Live (`docs/specs/live.md:86`) | Each phone's items, allowlist and history exist; the panel says "Live on <phone>"; switching keeps each phone's allowlist and history. | One `NotifyLiveStore` keyed by notification id, `NotifyLiveItem` has no phone id, and the panel's name is the current phone. | **Spec right, code wrong.** The live surface is the one place the spec already describes the target and the code has not caught up. |
| App windows (`docs/specs/app-windows.md:195`, `WIN-35` at `:71`) | The window belongs to the phone in use; switching closes the previous phone's windows; New/list/⌘\` act on that phone; `WIN-35` proves it with a second fake phone. | The window functions take a `deviceId` and filter by it (`MultiWindowPhoneTests`), but one `WindowManager` owns one session; switching closes all windows; the e2e has no second fake phone. | **Partly right.** The filtering is real; the session ownership and the claimed e2e proof are not. |
| Phone Mirror (`docs/specs/phone-mirror.md:101`) | One mirror per phone, so switching and opening again gives the other phone's mirror; each stays one window. | `WindowManager.phoneWindow` is one; `use` closes every window, including the mirror. | **Spec right, code wrong.** There is one mirror in total. |
| Settings (`docs/specs/settings.md:141`, `SET-DEV-03` at `:67`) | Every phone is a row and the in-use one is marked; Use This Phone switches the active phone. | Every phone is a row, but a connected non-active phone reads Offline (G1); Use This Phone closes windows and the session. | **Spec right for today, change the switch.** The row model is right; the presence and the teardown are not. |
| Files (`docs/specs/files.md:128`, `FILES-1`/`2`/`16`) | The one location follows the phone in use; the other phones are not mounted; an install asks which phone and makes it the phone in use first. | One domain per profile named from `remembered.active`; one bridge; a second phone replaces the host; installs switch the current phone. | **Spec right for today, wrong for the feature.** The target needs one domain per phone. |
| Media (`docs/specs/media.md:91`, `MEDIA-6` at `:37`, `MEDIA-8` at `:39`) | Only the phone in use sends media; there is no cross-phone picker; the system entry is cleared when another phone becomes the one in use. | Same, through one `NowPlayingController`; any session end clears the one entry. | **Spec right for today, change the rule.** The target needs a cross-phone rule and a picker. |
| Panel (`docs/specs/panel.md:108`, `PANEL-5` at `:29`) | The card shows the phone in use only; no picker. | `PhoneControlsState.from` reads the one link, status, media and live list. | **Spec right for today, change the card.** The target needs a per-phone section or a picker. |
| Menus (`docs/specs/menus.md:81`) | Every action acts on the phone in use; no phone picker. | `MenuBarModel` reads the one controller; Phone items use `link.phone`. | **Spec right for today, change the target.** A key window on the other phone must win over the current phone. |
| Deck (`docs/specs/deck.md:114`) | The Deck shows the phone in use only; Settings is the switch. | One `deckMode`, one `apps`, one title. | **Spec right for today, change the Deck.** The target needs a visible switch or a per-phone grid. |
| Share and clipboard (`docs/specs/share-clipboard.md:150`) | Clipboard and Send to Mac belong to the phone in use; ⌘V and a targeted drop belong to the window's phone; Open on Phone picks. | One clipboard sync; every window's paste goes to the one session; link routing already picks. | **Spec right for today, change the clipboard rule.** The window's phone is only real after W5. |
| Transport (`docs/specs/transport.md:159`) | One session per Mac, and the Mac app is single-phone today; the phone in use is the one with a session. | One `Session`; the phone side serves one Mac. | **Spec right for today, rewrite the 2+ line.** The target is one session per Mac-phone pair. |
| Dock (`docs/specs/dock.md:56`) | Every bundle id and name includes the phone; an app list reconciles only that phone's shims. | Ids and names are per phone; `reconcile` runs only for the phone whose app list arrived. | **Spec right, small code gap.** Reconcile every connected phone's cached list. |
| Spotlight (`docs/specs/spotlight.md:38`) | One domain and one verification per device id. | `SpotlightIndex` keys by device id; `openFromSpotlight` switches with `use`. | **Spec right, code right.** Only the open path inherits S7. |
| Pairing (`docs/specs/pairing.md:102`) | Each phone is pinned separately; the phone lists one row per Mac, the live one first. | The pin store and the phone's `PairedMac` list are per phone/Mac; pairing a second phone still ends the live session (P1). | **Spec right, one code gap.** A second pairing must not end the live session. |
| Phone app (`docs/specs/phone-app.md:192`) | One row per Mac; only one Mac can be connected at a time. | `SessionSlot` enforces exactly that. | **Spec right, code right.** This is a phone limit and stays. |
| Controls (`docs/specs/controls.md:128`) | A control's memory is per phone; a value one phone had is not sent because another was added. | `ControlIntentStore` keys by device id; the send path uses the one session. | **Spec right, code right per phone.** Only the send target needs a phone. |

Three code defects are worth naming separately because they are wrong even if
the product keeps "one phone in use" and only overlaps two connections for a
moment:

1. `NotifyCenter` keys every store by the phone's notification id, not
   `(phone, id)`, and `clearAll()` clears every phone. Two phones with the same
   notification id collide.
2. `NotifyLiveStore` and `NotifyLiveItem` have no phone id, so the Live surface
   cannot satisfy `live.md`'s per-phone rows.
3. `DevicesPreview.presence` shows a connected non-active phone as offline.

## 4. What is already per phone and can stay

The following are keyed by device id and need no model change. The target model
should reuse them as they are:

- pins: `PhonePinStoreV2` (`pins.json`, one record per phone);
- remembered phones and nicknames: `RememberedPhones`, `PhoneNicknames`;
- reachability: `CachedDeviceStore` (`cachedAddresses`, `cachedDeviceNames`);
- app lists and icons: `AppsCache`, `IconCache`;
- battery: `BatteryMemory`;
- control memory: `ControlIntentStore` (`controlIntent.<control>[deviceId]`);
- notification settings: `NotifyToggle`, `NotifyMute`, `NotifyClickTarget`;
- panel-off and ignore-power: `PhonePanelOffSetting`,
  `PhonePanelIgnorePowerSetting`;
- shortcuts: `SaveAllShortcutsSetting`;
- Dock shims: `DockApps` (bundle id and name include the phone);
- Spotlight: `SpotlightIndex` (domain and verification per device id);
- the phone's paired Mac list: `Prefs.PairedMac`;
- the wire: `welcome.device.id`, `hello.clientId`, one pin per phone.

This is why the audit's S row count is high: the data model is already
multi-phone. The one-phone assumption is in the owner objects, not in the
storage.
