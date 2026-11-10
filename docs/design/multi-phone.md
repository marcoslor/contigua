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

## 5. The target model

### 5.1 One session per phone

The layer above `Session` becomes a **phone book**: a map from device id to a
**phone session**, plus one current id. A phone session is the per-phone
counterpart of today's single controller state. It owns:

- the live `Session` (one TLS session, one to three paths);
- its `LinkMachine` and `Link` — the connection state machine of that phone,
  unchanged;
- `PhoneInfo` and `PhoneStatus` — the phone's own report;
- the app list and its icons;
- the notification seen set and the no-access flag for that phone;
- the files client for that phone;
- the phone's window set: app, link and handoff windows, and one Phone Mirror;
- the drop sender, APK installer and clipboard-image buffer for that phone;
- the ringing flag, the path outage and the retry state.

The controller keeps what is genuinely shared: the remembered list, the pins,
the Mac identity, discovery, the current id, the pairing flow, the menu bar,
the Deck, Settings, MCP, Spotlight, the Dock, one Notification Center, one Now
Playing controller, one audio engine and the stats log. The views that exist
today keep their names and read the current phone; a view that names a phone
reads that phone's record.

The wire does not change. A phone already sees one Mac; the Mac holding two
sessions to two different phones is invisible to both. `welcome` already carries
`device.id`, the pins are per phone, and `docs/design/paths.md` already defines
one session per Mac-phone pair. There is no protocol version bump and no
phone-side change for the target model.

### 5.2 Shared and per phone

| Thing | Scope | Why |
|---|---|---|
| App process, profile, identity, pins | shared | One Mac app, one trust store; pins are already per phone |
| Menu-bar status item | shared | One icon should mean "PocketDeck", not one icon per phone |
| Deck window | shared, showing the current phone | One home window; a phone switcher, not a second Deck |
| Settings window | shared, every phone a row | One management window; already built that way |
| MCP server | shared | One automation endpoint; calls take a phone |
| Spotlight index | shared object, one domain per phone | Already per device id |
| Session, link, status, apps, icons | per phone | The feature |
| Stream windows and Phone Mirror | per phone | A window is one phone's picture and input |
| File Provider domain, bridge, id map, replica | per phone | A Finder location is one phone's storage |
| Notification store | shared object, keys per phone | One Notification Center, banners grouped per phone |
| Live store | shared object, keys per phone | One panel, rows per phone |
| Media state and Now Playing | shared system slot, one owner at a time | macOS has one Now Playing entry |
| Clipboard | shared pasteboard, one target at a time | macOS has one general pasteboard |
| Audio | shared engine, one source at a time | macOS has one output route for the app |
| Dock and Launchpad shims | per phone | Already one shim per app per phone |
| Stats and logs | per window, tagged with the phone | One log, no ambiguous stream ids |

### 5.3 The current phone and the target

Every action has a **target**. A surface that names a phone (a window, a
notification, a Finder location, an intent's phone, an MCP `phone`, a link's
`phone`) uses that target. A surface that names none uses the **current
phone**:

- the Deck and its grid;
- the menu-bar panel;
- the phone-level menu items when no app window is key;
- a copy on the Mac (the clipboard poll);
- a drop on the Deck;
- Start Timer… from the menu.

The current phone is set by Settings ▸ Use This Phone, and by a finished
pairing (the new phone becomes current, as today). Opening a window on another
phone does not change the current phone: the window is already the strongest
target, and the Deck may keep showing the phone the person was looking at.

In the target model, changing the current phone no longer ends a session and
no longer closes a window. It changes what the Deck and the panel show, where
the clipboard poll points, and which phone an untargeted action uses. Slices 1
and 2 keep today's window closing for a switch until slice 3 moves the windows
to their own phones; only the session already survives those slices.

### 5.4 How a surface says which phone it is

A window says it in its title, which already carries the phone name
(`WIN-3`/`WIN-28`): "WhatsApp (Work)" or "Chrome — Inbox (Personal)". The
opening cover says "Opening on <phone>". The Window menu groups windows by
phone when two or more are online; the Dock shim names already include the
phone. The menu items that change one phone (Ring, DND, Ringer, Volume, Turn
Off Screen, Open <App> on Mac) name the phone in their title while two or more are
online, because the action may be invoked from a window of the other phone.

A small phone chip in the window bar is a visual decision. It is not needed for
correctness; it is a prototype round if the person wants more than the title.

## 6. The rules for conflicts

The rules below are the target behaviour. They are the parts a slice must not
improvise.

| Action | Target | Rule |
|---|---|---|
| A copy on the Mac (the poll) | current phone | One pasteboard, one mirror. The poll sends to the current phone only; on a switch, stop the old sync and start the new. A background phone's clipboard gate stays off. |
| ⌘V of an image or files in a window | the window's phone | The window's paste flow owns the stream. The image or file goes on that window's session, never on the current phone's. Text ⌘V types into the window as today. |
| A copy on a phone to the Mac | current phone | A background phone's copy does not silently replace the Mac's pasteboard. Its gate is off until it becomes current. A notification for a background phone's copy is a later feature. |
| A file dropped on a window | the window's phone | One drop per phone; a second drop on the same phone is refused as today. Two phones can receive a file at the same time. |
| A file dropped on the Deck | current phone | The Deck is the current phone's surface. |
| A link with `phone=<id>` | that phone | Send on that phone's own session when it is online; otherwise keep the link for up to 120 s and send when that phone is ready. The current phone does not change. |
| A link with no phone, 2+ paired | the person's pick | The picker lists remembered phones, connected first. The chosen phone gets the link; the current phone does not change. |
| Start Timer… | current phone, or the phone whose Live section was used | The timer is created in that phone's Clock app and the live item carries that phone. Two phones can each have a timer. |
| `phone_status`, `list_apps`, `open_app`, `send_link`, `send_file` (MCP) | the call's `phone`, else current | An unknown or ambiguous phone is a tool error that lists the phones. Window tools use the window's phone. |
| Ring, DND, ringer, volume, Turn Off Screen, Open <App> on Mac | the key window's phone, else current | These change one phone. Their menu titles name the phone when two or more are online. |
| A notification click, reply or dismiss | the notification's phone | Open that app's window on that phone and send the action on its session. |
| Now Playing | the phone that is playing | If the current phone is playing, it wins. Otherwise the most recently updated playing phone wins. A pick in the panel wins until that phone's session ends or it stops playing. Transport commands go to the phone that owns the displayed state. |
| Audio | current phone, and only while one of its windows is open and unpaused | One route. Switching stops the old phone's capture and starts the new one only if it has an open window. Two phones do not mix. |
| Finder | the location's phone | Each location is one phone's storage. A copy, drop or install started from a location goes to that phone. |
| Phone Mirror | its own window's phone | One mirror per phone, both may be open. |
| Pairing | the phone being paired | A pairing does not end another phone's session or close its windows. The new phone becomes current when the pairing finishes. |
| Forgetting a phone | that phone | Forget one and the others keep their sessions, pins, windows and files. |

Two rules make the rest small:

1. **A window is the target.** Anything that starts inside a window (input,
   paste, drop, link, notification click) uses that window's phone. A window
   never asks "which phone is current?".
2. **A phone-level action is explicit.** If an action changes a phone rather
   than a window, it either comes from that phone's own surface (its
   notification, its Finder location, its live row) or names the current phone,
   and its title says which. It never guesses from a list order.

## 7. The slices

Each slice ships alone and has its own proof. The first is deliberately small:
two phones can be connected at once and neither breaks, while most surfaces
still act on one current phone.

### Slice 1 — Two live sessions, one current phone

**Goal.** The app owns a session per phone and a current id. A second phone can
be connected while the first stays live. The UI still shows and acts on the
current phone; switching still closes the current phone's windows, as today.

**Changes.**

- Add the phone book and the phone session (session, link machine, phone info,
  attempt timer, backoff, path outage).
- `ConnectionController.session`, `machine` and `link` become views of the
  current phone's session. `currentId` is the in-memory current; the persisted
  choice stays `RememberedPhones.active`.
- `connect(deviceId:)` and `disconnect(deviceId:)` replace the one
  `start`/`closeSession`. A phone's retry loop is its own.
- `handle(_:from:)` takes the phone id. Events from a non-current phone update
  only that phone's session and link; they never touch the current phone's
  clipboard, notifications, files, media or windows. A failure on a
  non-current phone clears nothing global.
- `use(deviceId:)` changes the current phone, closes the current phone's
  windows as today, and leaves the other session running.
- `shutdown` closes every session. A pairing still replaces the current phone's
  session, as today; reconnecting a remembered phone uses its own pin.
- One test hook: `--connect-phone <host:port>` (repeatable, test builds only)
  connects an additional phone without making it current; a report file says
  `phones=<n> online=<n> current=<id>` with one row per phone.

**Proof.** K2 `PhoneBookTests`: two sessions are independent; switching changes
the current view; closing one leaves the other ready; a failed event on B
changes no A state. E2E `phones` phase A with two fake phones: pair A, pair B,
reconnect A from its pin while B is current; both `welcome`, both answer pings
for 20 s, B's close leaves A online.

**Phone sessions and claims.** `PhoneBook` holds one `PhoneSession` per device
id; the session lives while at least one claim names it (the current phone, the
`--connect-phone` test hook; later slices add feature claims). The claim set is
a set, never a bool: two claims can name one phone, and removing one does not
end its session. The connection state inside a session is the `LinkMachine`
(`docs/specs/pairing.md`'s state table); the claim set decides that session's
lifetime.

| State | Event | Result |
|---|---|---|
| no session | `claim added` (`current`, `testHook`) | connect that phone; one attempt on its own timer |
| connecting / online / reconnecting / offline | `claim added` | session and link unchanged; no new attempt |
| any live state, two or more claims | `claim removed` | session and link unchanged |
| any live state, one claim | `claim removed` | close that phone's session and cancel its retry; link → `idle`; every other phone untouched |
| no session | `claim removed` | ignored |

**Done on `feat/mp1`.** `PhoneBook`/`PhoneSession` own the session, the
`LinkMachine`, the attempt task, the retry state and the path outage per phone;
`ConnectionController.session`, `machine` and `link` are views of the current
record. K2 `PhoneBookTests` (14 tests) covers the claim set, switching,
per-phone retry, event isolation and shutdown. E2E `phones` phase A passes
16/16 on ports 47995/47994: A paired, B paired while A stayed live through the
test hook, A reconnected from its pin while B was current, both answered pings
for 20 s, and B's close left A online. The other phases stay for their slices.

**Size.** M. No wire change.

### Slice 2 — Per-phone state, and pairing beside a live phone

**Goal.** Everything the current phone shows is that phone's own data, and a
pairing no longer ends another phone's session.

**Changes.**

- Move the status, app list, icons, notification seen/no-access sets, ringing
  flag and path outage into the phone session.
- The current-only views read `current`; a phone's Settings page reads that
  phone. `DevicesPreview.presence` uses each phone's own link, so a connected
  non-current phone reads Connected.
- A pairing becomes its own flow: one sheet at a time, refused with a sentence
  while another pairing runs. `beginPairing` does not close the live session or
  its windows; on success the new phone becomes current, and the old phone
  stays live.
- `use` still closes the current phone's windows (slice 3 changes that) but
  keeps its session.

**Proof.** K2 `PhoneSessionDataTests`, `PairingWhileLiveTests`. E2E `phones`
phase B: pair B while A streams; A's window and session are untouched; B's
Settings page says Connected; B's app list does not replace A's grid; B's
failure clears none of A's banners.

**Size.** M.

### Slice 3 — Windows per phone

**Goal.** Windows belong to their phone and stay open across a switch. This is
the user-facing heart of the feature.

**Changes.**

- `WindowManager` is one shared object keyed by `WindowKey(deviceId, stream)`,
  with a global stream allocator. Its per-phone fields (phone info, name, cap,
  link phase, screen, panel, secure) become per-phone records.
- Every window holds its phone session and sends open, resize, input, keyframe,
  paste and close on it. `LinkWindow` and `PhoneWindow` gain a phone id.
- Video and events route by `(source phone, stream)`; a second phone's video no
  longer hits a guard.
- `use` stops closing windows. The Deck switches its grid; windows of both
  phones stay and keep streaming.
- One Phone Mirror per phone; `openPhoneWindow(on:)`; screen/secure/panel state
  per phone.
- Titles use the window's phone. The Window menu groups by phone when two or
  more are online; New/list/⌘\` use the key window's phone (its app's windows on
  that phone).
- The app-wide cap is each phone's own `maxWindows`, as the phone reports it.

**Proof.** K2 `WindowKeyTests`, `MultiPhoneWindowTests`. E2E `phones` phase C:
A and B each have one app window; A keeps receiving frames while B's window
opens; input, a paste and a drop on A's window appear only in A's fake-phone
event log and vice versa; each title names its phone; ⌘W closes only that
window; switching current leaves both windows; two Phone Mirrors open at once.

**Size.** L.

### Slice 4 — Finder files per phone

**Goal.** Every phone with the Finder feature on gets its own location, and one
phone's files cannot resolve in another phone's domain.

**Changes.**

- `FilesDomain.identifier` includes the phone id, not only the profile. The
  display name is that phone's nickname/name.
- One bridge socket per phone; `FilesBridge` becomes a keyed registry; one
  `SessionBridgeHost`, `FilesIdMap` and `FilesReplica` file per phone. The
  extension finds its socket from its `NSFileProviderDomain` identifier.
- The switch: one Mac-wide "Show phone files in Finder" adds every paired
  phone's location (recommended), or one switch per phone (section 10).
- `FILES-1`, `FILES-2` and `FILES-16` change with the slices.

**Proof.** K2 id-map isolation; host `files-bridge` with two sockets; VM
`files-domain` with two fake phones: two locations, each lists its own root,
the same relative path resolves to each location's own file, a delete on one
domain leaves the other's item. This is the only slice that needs a VM boot.

**Size.** L.

### Slice 5 — Notifications, Live and media per phone

**Goal.** Every phone with its switch on delivers, and one phone's notification
or media state cannot replace another's.

**Changes.**

- `NotifyCenter` keys every store by `(phoneId, id)`; `clearPhone(deviceId)`
  replaces every cross-phone `clearAll()`; the banner thread and request id
  stay per phone.
- `NotifyLiveStore` keys by `(phoneId, id)`; `NotifyLiveItem` carries the
  phone; the panel's Live section is per phone.
- `NowPlayingController` carries the phone id; the panel's picker lists phones
  as well as apps when two or more are online; `clear` only for the phone that
  ended; transport goes to the owner.
- A notification click, reply or dismiss uses the notification's phone and
  opens that app's window on that phone.

**Proof.** K2 `NotifyKeyTests`, `LivePerPhoneTests`, `NowPlayingPhoneTests`.
E2E `phones` phase D: B posts while A is current — both banners appear under
their own names; clearing B's session leaves A's banner; two timers run; the
panel picker switches the song between phones; Play goes to the displayed
phone.

**Size.** M.

### Slice 6 — Clipboard and audio, one target at a time

**Goal.** One pasteboard and one output route with an explicit owner.

**Changes.**

- One `ClipboardSync`, retargeted when the current phone changes. ⌘V in a
  window uses that window's phone. The clipboard-image buffer is per phone.
- One `AudioEngine`; its source is the current phone when at least one of its
  windows is open and unpaused. `syncAudio` stops the old source on a switch or
  when the last window closes; it never mixes two phones.
- The UI names the audio source ("Sound plays from <phone>") when two or more
  are online.

**Proof.** E2E `phones` phase E: a Mac copy reaches A only; ⌘V in B's window
writes B's clipboard; audio frames arrive from A and stop when A is no longer
current or has no window; switching starts B only if B has an open window.

**Size.** M.

### Slice 7 — The remaining entry points

**Goal.** Every way into the app names or implies the right phone, and the
stats/log can tell two phones apart.

**Changes.**

- Links: send on the target's session without switching (C3).
- Share phone → Mac: the inbox is per phone, or keyed by `(phone, id)` (C4).
- Drops and APK installs: one sender/installer per phone (C5, C6).
- MCP: a `phone` argument on phone-level tools; a `phone` field in
  `list_windows`; an error that lists the choices (G3).
- App Intents: resolve a named phone and act on its session without `use`
  (G4).
- Dock: reconcile every connected phone's cached app list (G5).
- Stats and logs: `phone=<short id>` on every `stats stream=` line and every
  per-window line; stream ids are globally unique (L1).
- Menu items that change a phone name it in their title when two or more are
  online (W9).

**Proof.** The existing `links`, `sharein`, `drop`, `apk`, `mcp`, `intents`,
`dock` and `stats` checks, extended with a second fake phone for the phases
that need one; E2E `phones` phase F for the mixed cases. K2 covers the routing
functions.

**Size.** M.

## 8. The test rig

### 8.1 Can the fake phone run twice?

Yes. One `fakephone.py` process is one phone: one identity, one port, one
session at a time. Two processes on different ports, state files and event
logs are two independent phones:

```
python3.11 tools/fakephone/fakephone.py --no-mdns --auto-allow \
  --port 47811 --state "$WORK/a-state.json" --events "$WORK/a-events.jsonl" \
  --name "Fake A"
python3.11 tools/fakephone/fakephone.py --no-mdns --auto-allow \
  --port 47812 --state "$WORK/b-state.json" --events "$WORK/b-events.jsonl" \
  --name "Fake B"
```

Each keeps its own device id in its state file and still answers a second
session with `busy`. That is the phone-side rule and should stay: the feature
is a Mac with two phones, not a phone with two Macs.

The app needs one test hook because `--connect` is a single endpoint and
discovery is off under `--no-mdns`: `--connect-phone <host:port>` (repeatable,
`PD_TEST_HOOKS` only) starts or resumes a session for that endpoint without
making it current, and `--phones-report FILE` writes one line per phone
(`id`, state, current) for the check. A release build ignores both, like the
other test hooks.

### 8.2 The e2e check

One check, `phones`, with phases A–F in the order of the slices. It uses two
fake phones on two ports and one profile, one window per phone at most (two
ffmpeg encoders), and reads each phone's own `--events` file to prove which
phone received an action. It never opens a second app instance and never uses
the person's default profile.

The phases:

- **A:** both phones pair and connect; both answer pings for 20 s; A's session
  survives B's close; switching back does not re-handshake.
- **B:** pair B while A streams; A's window, session and banners are untouched;
  B's Settings row says Connected.
- **C:** one app window and one mirror on each phone; A's frames continue while
  B opens; input, paste and drop land only in the owning phone's log; titles;
  ⌘W; switch current with both window sets alive.
- **D:** a notification and a timer from the non-current phone; banners and
  rows under the right names; clearing one phone leaves the other; media
  picker and transport.
- **E:** clipboard and audio ownership on a switch.
- **F:** link, share, drop, APK and MCP targeting with both phones live.

Each `ok` line names its requirement ID when the corresponding spec rows land.

### 8.3 The cheapest proof

- **K2** for every pure machine and key: the phone book, link per phone,
  `WindowKey`, notification and live keys, media ownership, link routing. These
  need no phone and no boot.
- **Two fake phones** for the cross-session wiring. They are Python processes
  plus one ffmpeg per open window; two windows total is well inside the 8 GB
  Mac's budget. They run under the same e2e lock as any other check.
- **The phone side** needs no new boot: `SessionSlotTest`, `ServerTest` and
  `tools/fakephone/test_busy_reject.py` already pin one Mac at a time, including
  the `busy`, supersede and join paths. The phone code does not change for this
  feature.
- **No two emulators.** The emulator is only for phone-side behaviour, which
  this feature does not touch. If a phone must ever serve two Macs, the cheap
  proof is the JVM `SessionSlot`/`ServerTest` pair, not a second emulator; two
  emulators on this Mac would also compete for the one heavy lock and the 8 GB
  of memory.
- **The VM** is needed only for slice 4 (File Provider). One boot, two fake
  phones, two domains.

## 9. Risks

### 9.1 Memory and CPU with two streams

Each open window holds one decoded picture, at most 16 MiB at the 2560 px cap
(`WIN-33`). Today one phone can have four app windows plus its mirror; the
target could hold ten streams (four app windows and a mirror on each of two
phones) — about 160 MiB of pictures, plus two H.264 decoders per stream and the
Mac's decoder-session limit. The per-phone cap does not bound the total.

Mitigations, in order:

1. Pause hidden and occluded windows as today (`window.pause` already stops the
   encoder and detaches the surface); a hidden window keeps only its last
   frame.
2. Measure the app's resident size and CPU with two phones and two, four and
   six windows, and with the panel/Deck open. The measurement goes in the NFR
   notes before a limit is chosen.
3. If the numbers need it, add a Mac-wide stream cap (for example 8 total) next
   to each phone's cap, with the same "Close a window to open another."
   sentence. That is a product limit, hence section 10.
4. Two phones streaming at once also double the Mac's TLS, ping and ACK work;
   that is small compared with video, but the session layer must not run one
   global timer that scans every phone on every tick.

### 9.2 Battery

An idle connected phone costs one listening socket, one 15 s app-level ping and
no virtual display, encoder or wake lock (`ARCHITECTURE.md` "Session end /
battery"). A second idle phone adds one socket and one ping; a second streaming
phone costs its own encoder and radio, exactly as if it were the only phone.
The Mac's choice that matters is whether it connects every remembered phone at
launch. Connecting all of them keeps every radio awake and every phone's
notification listener busy; connecting lazily keeps the idle cost to the
phones in use. Section 10 asks the person.

Do not add a poll to discover a second phone. The existing Bonjour browse and
the per-phone retry backoff are enough.

### 9.3 Privacy on a shared Mac

The pins, cached files, File Provider domains and notification settings live in
the macOS user's home (`~/Library/Application Support/PocketDeck…`, the user's
defaults and caches). Another macOS account cannot read them: the OS account is
the boundary. A household that shares one macOS account shares every paired
phone: both phones' notifications, Finder locations, media and clipboard are
visible to anyone at that Mac.

Options: keep the OS account as the boundary and say so; add a per-phone "Show
on this Mac" switch; or add a macOS-user check. The first is the current design
and needs no code; the second is a later feature; the third is not possible
with one account. The product call is section 10.

The logs must not get worse: every per-window line may carry a short phone id
(a hash prefix or the device id's first characters, never the name), and no
notification text, file name, media title, clipboard content or key material
enters a log. `CONV-PD-05` and `R-PRIV-1` already say this.

### 9.4 Wrong-phone actions

The dangerous cases are the phone-level actions with no window: Ring, DND,
ringer, volume, Turn Off Screen, Open <App> on Mac, Install APK, Start Timer and a
notification reply. Each gets an explicit target in section 6, and the menu or
card names the phone when two or more are online. The old behaviour (act on
`link.phone`) is not enough once two phones are online; a wrong Ring or a wrong
DND is a visible, personal mistake.

A second risk is a delayed action: a link or install that waits 120 s must
remember its phone, not fall back to "whichever is current when it becomes
ready". The existing pending queues already carry a `deviceId`; keep that and
make every wait check the phone id.

### 9.5 Decoder, File Provider and system limits

- **VideoToolbox**: many simultaneous H.264 decodes can exhaust the Mac's
  session limit. The Mac-wide cap (9.1) is the mitigation; a failed decoder
  shows the window's cover, never a frozen frame as if live.
- **File Provider**: two domains mean two Finder locations and two
  registrations. The System Settings extension switch is per extension, not per
  domain, so both appear or disappear together; the VM check must prove two
  domains coexist and that removing one leaves the other. Adding a domain is
  slow (the add can take seconds); do it once per phone, not on every switch.
- **Notification Center**: two phones' banners share one center; the thread and
  request id already carry the phone, so grouping is per phone. A phone's mute
  list is per phone; do not merge them.
- **Now Playing**: macOS has one entry. Two players will fight unless the rule
  in section 6 is enforced in one place (`NowPlayingController`), not in each
  caller.
- **Audio**: one route. Two phones playing at once is the case the rule
  forbids; the UI must say which phone owns the sound.

## 10. Open questions

Each line is a product call, not something the code can settle. The
recommendation is the one the plan assumes.

- [NEEDS CLARIFICATION] Should a household's phones all show in one panel, or
  only the phones of the macOS user who paired them? Recommended: every phone
  paired by this macOS account shows; the OS account is the privacy boundary,
  and sharing one account means sharing every phone.
- [NEEDS CLARIFICATION] One Deck and one panel with a phone switcher, or a
  section per phone (all phones visible at once)? Recommended: one current
  phone with a switcher in the Deck toolbar and the panel header; a section per
  phone is a redesign of the 300 pt card.
- [NEEDS CLARIFICATION] Does the Mac connect every remembered phone at launch,
  or only the current phone plus any phone a feature needs (notifications,
  Finder)? Recommended: lazily — current phone, plus a phone when a feature is
  turned on or an entry point names it — to keep idle battery low.
- [NEEDS CLARIFICATION] Should a background phone's copy reach the Mac
  clipboard? Recommended: no; only the current phone's copy does, and a
  notification for a background phone's copy is a later feature.
- [NEEDS CLARIFICATION] Should two phones' audio mix, or only the current
  phone's play? Recommended: one phone at a time; two calls or two songs mixed
  into one Mac route is worse than a switch.
- [NEEDS CLARIFICATION] When both phones play media, which wins Now Playing:
  the current phone, the most recently updated, or the person's pick?
  Recommended: the person's pick, else the current phone, else the most
  recently updated; transport always goes to the displayed phone.
- [NEEDS CLARIFICATION] One Mac-wide "Show phone files in Finder" switch that
  mounts every paired phone, or a switch per phone? Recommended: one switch,
  every paired phone's location; forgetting a phone removes its location.
- [NEEDS CLARIFICATION] Keep each phone's window cap only, or add a Mac-wide cap
  for the 8 GB Mac? Recommended: add a total cap (8 is the starting proposal)
  beside the per-phone cap, with the same sentence.
- [NEEDS CLARIFICATION] Does "Use This Phone" still exist as one current phone,
  or does every surface pick its own phone and the Deck show all phones?
  Recommended: keep a current phone for surfaces with no target; every surface
  with a target ignores it.
- [NEEDS CLARIFICATION] Where does a non-current phone's problem show (Pair
  again, offline, a missing permission): a row in Settings, a badge on the
  phone switcher, or a second banner? Recommended: a badge on the switcher and
  the phone's Settings row; the one Deck banner stays the current phone's.
- [NEEDS CLARIFICATION] May one phone be connected to two Macs at the same time?
  Recommended: no for this feature; the phone's one-slot rule stays. It would be
  a separate L change to the phone's shared audio, panel, clipboard and notify
  owners.
- [NEEDS CLARIFICATION] May a second pairing run while a phone is live?
  Recommended: yes, one sheet at a time, and the live phone keeps its session.

**Decided by the reviewer (2026-11-06).** These are technical defaults, so the plan proceeds on them:
- **Connect at launch:** lazily. The current phone, plus a phone when a feature that needs it is on (notifications, Finder) or an entry point names it.
- **Window cap:** a Mac-wide total cap of 8 beside the per-phone cap, with the same sentence.
- **The current phone stays.** It serves surfaces with no target; every surface with a target ignores it.
- **A non-current phone's problem** shows as a badge on the switcher and in its Settings row. The Deck banner stays the current phone's.
- **Finder:** one Mac-wide switch shows every paired phone's location.
- **Pairing:** a second pairing may run while a phone is live, one sheet at a time.

**For the person** (product calls; slice 1 depends on none of them): the privacy boundary on a shared Mac; the Deck and panel shape (visual, so a prototype round before slice 3); whether a background phone's copy reaches the clipboard; audio mixing and the Now Playing winner; one phone on two Macs.

## 11. Spec notes

These are the spec lines that must change when the plan lands. They are listed
here, not edited: a behaviour change updates its spec in the same commit
(`AGENTS.md`). Line numbers are at `3144abd1`. Where the spec is already right
for the target, there is no entry.

### 11.1 Phone-count sections that are wrong for 2+

**`docs/specs/app-windows.md:195`** (the 2+ row). It says the window belongs to
the phone in use and that switching closes every window of the previous phone.
Replace it with: "Each window belongs to its phone and stays open when another
phone becomes current; its title names its phone. New Window, the open-window
list and ⌘\` act on the key window's phone; with no key window, the current
phone. Each phone's cap counts its own streams." Also change `WIN-35`
(`:71`) from "act on the phone in use only" to "act on the key window's phone,
else the current phone"; its proof's "e2e `multiwin` `[WIN-35]` with a second
fake phone" does not exist today (the `multiwin` check runs one phone), so point
it at the `phones` check's phase C or mark it untested. The `CONV-PD-01` answer
(`:234`) then reads "windows follow their phone; Settings switches the current
phone and closes nothing."

**`docs/specs/deck.md:114`** (the 2+ row). It says the Deck offers no phone
switch. Replace it with: "Phone mode for the current phone, with a phone
switcher in the toolbar that lists every connected phone and its state;
Settings ▸ Use This Phone does the same. Changing the current phone closes no
window." Update the `CONV-PD-01` answer (`:150`) and the assumption at `:164`
("The phone in use is the one `activePhoneId` names") to "the current phone".
Whether the Deck shows one current phone or all phones at once is section 10's
question; this replacement is the recommended one.

**`docs/specs/files.md:128`** (the 2+ row). It says the one location follows
the phone in use and the other phones are not mounted. Replace it with: "Every
phone with the switch on has its own location, 'PocketDeck (<name>)'; a
location's listings, thumbnails, drops and installs act on that phone." The
same change reaches three requirement rows: `FILES-1` (`:28`) makes the domain
identifier the profile **and** the phone id instead of the profile name;
`FILES-2` (`:29`) makes the name per phone; `FILES-16` (`:43`) drops "and, if it
is not the one in use, SHALL make it the phone in use first (one session
teardown, as settings.md SET-DEV-03)" and sends the install to the named
phone's session. Update the `CONV-PD-01` answer (`:165`) and the non-goal at
`:192` ("Installing an app on a phone other than the one in use").

**`docs/specs/live.md:86`** (the 2+ row). It says only the phone in use has a
session, and switching clears the controls. Replace it with: "Every connected
phone with its switch on has its items, allowlist and history; each item names
its phone; the panel groups the rows per phone; switching the current phone
changes the focused section, not the items." Also `LIVE-10` (`:33`) and
`LIVE-15` (`:38`) say "a session end" / "WHEN the session ends"; make both "that
phone's session". `LIVE-13` (`:36`) already says per phone and needs no change.

**`docs/specs/media.md:91`** (the 2+ row). It says only the phone in use sends
media and there is no cross-phone picker. Replace it with: "Every connected
phone with its switch on reports media. Now Playing follows the playing phone:
the current phone when it plays, else the most recently updated playing phone,
else the person's pick; the panel offers a phone picker when two or more play.
Transport goes to the displayed phone." Also `MEDIA-6` (`:37`) changes "another
phone becomes the one in use" to "the displayed phone's session ends or it stops
playing"; `MEDIA-8` (`:39`) changes "the phone in use" to "the current phone,
when at least one of its windows is open"; update `CONV-PD-01` (`:127`) and
remove the non-goal "Media from a phone that is not in use, or several phones at
once" (`:150`).

**`docs/specs/menus.md:81`** (the 2+ row). It says every action acts on the
phone in use and the menus offer no picker. Replace it with: "Every action acts
on the key window's phone; with no key window, the current phone. A phone-level
item's title names the phone when two or more are online. Settings ▸ Use This
Phone changes the current phone." Update `CONV-PD-01` (`:118`).

**`docs/specs/notifications.md:195`** (the 2+ row). It says only the phone in
use has a live session, so only its notifications arrive. Replace it with:
"Every connected phone with its switch on delivers. Every store is keyed by the
phone and the phone's notification id; a phone's session end clears only that
phone's banners and live state; banners are grouped and titled per phone." The
rest of the row (its own switch, click target and mute set) is already right.
This spec describes the target better than the code does: the code's
`NotifyCenter` is keyed by the notification id alone.

**`docs/specs/panel.md:108`** (the 2+ row). It says the card shows the phone in
use only and offers no picker. Replace it with: "The current phone, named in the
header, with a phone picker in the header when two or more are online; each
phone's controls, media and live rows follow that phone. Settings ▸ Use This
Phone does the same." Add the picker to `PANEL-5`'s top-to-bottom list (`:29`),
update `CONV-PD-01` (`:147`), and change the assumption at `:160` ("The card's
phone is the one in use") to "the current phone".

**`docs/specs/phone-mirror.md:101`** (the 2+ row). It says one window per phone
but describes switching phones and opening again. Replace it with: "One mirror
per phone; both can be open at once; switching the current phone changes
nothing; each window's title names its phone." `CONV-PD-01` (`:139`) stays
right.

**`docs/specs/settings.md:141`** (the 2+ row). It says every phone is a row and
the in-use one is marked. Replace it with: "Every phone is one row with its own
presence (Connected, Connecting, Offline, Pair again); the current phone is
marked; several phones may be Connected; one phone's page is open at a time and
every other phone is one click away." Then `SET-DEV-03` (`:67`) must stop saying
Use This Phone changes "every surface (Deck, menu-bar panel, windows,
notifications, Dock shims)"; it changes the Deck, the panel and the actions
with no target, and does not close another phone's windows or end its session.
`SET-DEV-08` (`:71`) drops "one session teardown, one connect" for the remaining
phones, and the state table's `use(phone)` row (`:112`) drops "windows of the
previous phone close, one session teardown". `SET-DEV-02` (`:66`, exactly one
in-use mark) stays: one current phone, several connected.

**`docs/specs/share-clipboard.md:150`** (the 2+ row). It says clipboard and
Send to Mac belong to the phone in use only, and a link switches to the chosen
phone. Replace it with: "Clipboard sync follows the current phone; ⌘V of an
image or files belongs to the window's phone; a drop on a window goes to its
phone and on the Deck to the current phone; Open on Phone asks when none is
named and sends on the chosen phone without changing the current phone." Also
`SHARE-8` (`:41`) changes "a phone that is not the connected one SHALL become
the phone in use and get the link after `welcome`" to "receives the link on its
own session; the current phone does not change"; the waiting table row (`:139`)
and the non-goal at `:198` carry the same change. `CONV-PD-01` (`:186`) stays.

**`docs/specs/transport.md:159`** (the 2+ row). Replace "One session per Mac,
and the Mac app is single-phone today (settings.md): the phone in use is the one
with a session" with "One session per Mac-phone pair; the Mac holds one session
for each connected phone. Each phone still serves one Mac at a time." The rest
of the row (the phone publishes one Aware service per Mac) stays.

**`docs/specs/dock.md:56`** (the 2+ sentence in the paragraph, not a table
row). Its ids and names are right. Change "an app list reconciles only that
phone's shims" to "every connected phone's app list, live or cached, reconciles
its own shims." This closes the gap where only the live phone's list is
reconciled.

### 11.2 Requirement rows that carry the same one-phone rule

These are not in a "Phone count" section but state the rule the feature
changes; they change in the same commits as their slice:

- `docs/specs/app-windows.md:71` — `WIN-35` (the target and its e2e proof).
- `docs/specs/files.md:28-29,43` — `FILES-1`, `FILES-2`, `FILES-16`.
- `docs/specs/live.md:33,38` — `LIVE-10`, `LIVE-15`.
- `docs/specs/media.md:37,39` — `MEDIA-6`, `MEDIA-8`.
- `docs/specs/settings.md:67,71,112` — `SET-DEV-03`, `SET-DEV-08`, the `use`
  state row.
- `docs/specs/share-clipboard.md:41,139` — `SHARE-8` and the waiting row.
- `docs/specs/pairing.md:32` — `PAIR-7` says a finished pairing makes the new
  phone "the one in use"; add "without ending another phone's session or
  closing its windows." The 2+ row (`:102`) is already right.
- `docs/specs/spotlight.md:38` — already right; add that a click on another
  phone's result opens the app on that phone without changing the current
  phone (after slice 3).
- `docs/specs/controls.md:128` — already right (per-phone memory); add that a
  control acts on the key window's phone, else the current phone.
- `docs/specs/phone-app.md:192` — already right: one Mac at a time is the
  phone's limit and stays. Add one sentence that the Mac may hold sessions to
  several phones, so a reader does not read it as a Mac limit.

### 11.3 Missing specs and design lines

- **MCP has no surface spec.** Its 2+ answer lives only in
  `docs/design/mcp.md:76-79`, where the phone-level tools have no phone
  argument. If a spec is written, its 2+ row must say: a `phone` argument on
  `phone_status`, `list_apps`, `open_app`, `send_link` and `send_file`; the
  current phone when the argument is absent; a `phone` field in
  `list_windows`; an unknown or ambiguous name is a tool error that lists the
  phones.
- **App Intents has no surface spec.** `docs/design/intents.md:8` says the
  default is "the connected phone, else the only paired one"; change it to "the
  current phone, else the only paired one", because with two phones connected
  "the connected phone" is ambiguous. The optional phone parameter is already
  the right shape.
- **`docs/design/paths.md:834`** lists "several sessions or several phones at
  once" as a non-goal. Reword it to "one session per Mac-phone pair; several
  pairs on one Mac is feature 2, not a second session for one pair." The
  session layer itself needs no change.
- **`docs/design/files.md:1233`** ("The extension dials the phone itself. One
  session per phone (`busy`)") stays true; add that the domain per phone is the
  new part (slice 4). This is a design note, not a spec.

### 11.4 Sections that are right as written

These already answer 2+ phones correctly and need no edit for the target, only
the code behind them:

- `docs/specs/pairing.md:102` — each phone pinned separately; one row per Mac on
  the phone.
- `docs/specs/phone-app.md:192` — one Mac at a time on the phone.
- `docs/specs/spotlight.md:38` — one domain and one verification per device id.
- `docs/specs/controls.md:128` — per-phone memory.
- `docs/specs/dock.md` ids and names — per phone (only the reconcile sentence
  changes, 11.1).
- `docs/specs/settings.md` row list — every phone is a row (only presence and
  the switch change, 11.1).
