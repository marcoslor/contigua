# Phone files in Finder — design (files)

ROADMAP v0.2 #1. The phone's shared storage (`/sdcard`: DCIM, Download, Documents…) shows
up as a location in Finder on the Mac: browse, Quick Look, open, copy in and out, rename,
delete, thumbnails. Cached files stay readable when the phone is gone, and edits made while
it is away upload when it is back. The phone must cost nothing when nobody browses, and the
whole thing must survive disconnects.

This document is a design: no code was written and nothing was run. Every protocol detail
below is a **proposal** — the wire lives in `docs/PROTOCOL.md` once it is agreed.

Shape in one line: the Mac side is a **replicated File Provider extension** (`NSFileProviderReplicatedExtension`);
it asks the running PocketDeck app over a local socket, and the app asks the phone over the
existing mutual-TLS session (`docs/PROTOCOL.md` framing), where a shell-uid service does
`File`/`Os.stat` work under `/sdcard`. One session, reused; no second listener, no new port.

## 1. Mac mechanism

| | (a) replicated File Provider extension | (b) localhost WebDAV/NFS/SMB mount | (c) macFUSE / FUSE-T |
|---|---|---|---|
| Sidebar/Locations entry | yes, a real domain in Finder (Apple: "Your provider will show up in the sidebar") | yes, as a network volume | yes, as a volume |
| Thumbnails | yes, extension-provided (`NSFileProviderThumbnailing`), no full download needed | only files Finder already cached; no provider thumbnails | yes (we generate) |
| Quick Look | yes; a dataless item is materialized when QL opens it | yes, after a download | yes |
| Offline cached reads | yes — the system keeps the local copy; we never write our own cache | partial: Finder's WebDAV cache, no pinning, unclear eviction | yes (we keep the cache) |
| Edits while offline | yes — local changes become *pending items*, uploaded on reconnect | no: a write to a dead mount fails | yes (we queue) |
| Progress | per item (`NSProgress` from `fetchContents`/`createItem`) | none | per file |
| Disconnect story | `disconnect(reason:options:.temporary)` → "items may be out of date", cached content still open | volume stays mounted but every operation errors | carve-outs we own |
| Signing today | ad-hoc, same shape as the Share extension (`macos/scripts/bundle.sh:258`) | none (unsandboxed app binds localhost; the mount is done by Finder) | needs an installer + System Settings approval |
| Entitlements | extension sandbox + one App Group (see below) | none | system extension / helper daemon |
| Install friction | none beyond the app | the person ⌘K-connects and must remount after a disconnect | high (macFUSE: Reduced Security on Apple Silicon) |
| Build cost | the extension + the bridge (the protocol is needed either way) | the WebDAV server (~a day) | a whole filesystem |
| What Finder gives us that we would have to fake | **everything**: it is the supported macOS path | little | a lot |

(a) is recommended. Background: Apple deprecated kernel filesystems for this job and shipped
File Provider for on-demand, user-space folders — WWDC21 session 10182, "Sync files to the
cloud with FileProvider on macOS": "The API is entirely in user space. We're deprecating
kernel extensions on macOS, so this is a good alternative for you if you were relying on
FUSE or KAUTH…". A replicated extension is `NSFileProviderReplicatedExtension`
(macOS 11+; https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension):
the system owns the local copies as APFS dataless files, and we only answer metadata, content
fetches and local changes. That is exactly the feature we were asked for.

### What (a) needs from our signing

- **An app extension** with `NSExtensionPointIdentifier = com.apple.fileprovider-nonui`
  (the File Provider extension point; see the Info.plist key reference) and
  `NSExtensionPrincipalClass` naming our class, embedded at `Contents/PlugIns/Files.appex`
  like the Share extension is today (`macos/scripts/bundle.sh:208-258`). Info.plist also
  wants `NSExtensionFileProviderSupportsEnumeration = true` and a document group (below).
- **App Sandbox in the extension.** macOS app extensions must be sandboxed (Apple DTS in
  forums/thread/798886: "macOS app extensions must have App Sandbox enabled"), which is
  exactly how the Share extension is already signed ad-hoc: `codesign --force --sign -`
  with an entitlements file holding only `com.apple.security.app-sandbox`
  (`macos/Extensions/Share/Share.entitlements:5`). The app itself stays unsandboxed, as now.
- **An App Group** so the sandboxed extension and the unsandboxed app share one directory —
  a UNIX socket and nothing else. `com.apple.security.application-groups` in both targets
  (Apple says app groups on macOS do not require a provisioning profile; see
  forums/thread/672554). The identifier would be `group.dev.pocketdeck.mac.files`
  (`group.dev.pocketdeck.mac.files.<profile>` for a non-default profile, mirroring
  `Profile.supportDirectoryName`, `macos/Sources/PocketDeck/Profile.swift:62`).
  If a profile-less ad-hoc signature refuses the group container, the fallback is a
  `com.apple.security.temporary-exception.files.home-relative-path.read-only` on
  `~/Library/Application Support/PocketDeck[-<profile>]/` for the extension — an ad-hoc
  signature may carry any entitlement, since no profile validates it. Both forms are
  experiments E1/E2 below.
- **No File Provider *capability*.** The portal capability for this feature is
  `com.apple.developer.fileprovider.testing-mode`, which only unlocks `NSFileProviderDomain.testingModes`
  and needs a provisioning profile
  (https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.developer.fileprovider.testing-mode).
  We don't want testing modes; plain `NSFileProviderManager.add(_:)` is enough.
- **Not translocated.** A quarantined app run from a download folder is refused as a provider
  (`NSFileProviderError.providerTranslocated`). Our builds are local and `install.sh` lands
  them in `/Applications`, so this should not bite; E1 checks it.

### How the extension gets bytes: it does not own a session

The phone serves **one session at a time**; a second client gets `busy`
(`docs/PROTOCOL.md` "Error codes", `android/.../Server.kt`). So the extension must never dial
the phone: the app owns the session (TLS keys, pins, `Session`), and the extension reaches it
over a UNIX domain socket in the App Group container (`files.sock`; ~55 characters, well
under the 104-byte `sun_path`). The app runs a `FilesBridge` listener on the session thread's
terms and answers extension requests by translating them into `fs.*` messages on the session.

The reverse path already exists and proves a sandboxed extension can reach the app: the Share
extension calls `NSWorkspace.open` on a `pocketdeck://` URL (`macos/Sources/PocketDeck/LinkShare.swift:107`,
`ShareHandoff.send`). If the app is not running when Finder opens the domain, the same trick
launches it (`pocketdeck://files?profile=…`) and the extension retries the socket with a
short timeout; until then the domain's items are the cached ones and dataless items get
`serverUnreachable`.

### What Finder does for us, exactly

- `enumerator(for:)` returns an `NSFileProviderEnumerator` per folder; paging via
  `enumerateItems(for:startingAt:)`, deltas via `enumerateChanges(for:from:)` /
  `currentSyncAnchor` (https://developer.apple.com/documentation/fileprovider/nsfileproviderenumerator).
- `item(for:)` answers metadata; `fetchContents(for:version:)` downloads a dataless item and
  its `NSProgress` drives Finder's per-file progress.
- Local creations/edits/deletes arrive as `createItem`/`modifyItem`/`deleteItem`; those are
  our uploads, including edits made while the phone was away.
- `NSFileProviderContentPolicy.downloadEagerlyAndKeepDownloaded` (macOS 13+,
  https://developer.apple.com/documentation/fileprovider/nsfileprovidercontentpolicy) is what
  Finder's **Keep Downloaded** means; `downloadLazily` (the default) is our ordinary item.
- Thumbnails come from `NSFileProviderThumbnailing.fetchThumbnails(for:requestedSize:…)`;
  the phone makes them over `fs.thumb` for a name that maps to an image or movie type, and
  every other item keeps the system's type icon (see "Thumbnails (S6)").
- Offline: `NSFileProviderManager.disconnect(reason:options:[.temporary])` marks the domain
  "may be out of date" while its cached content keeps working; dataless items then answer
  `NSFileProviderError.serverUnreachable`; `reconnect()` when the session is ready again
  (https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager).
- The domain is persistent: `NSFileProviderManager.add(_:)` once, then it lives in Finder's
  sidebar; `remove(_:mode:)` is our "forget this phone".

### Experiments (for the architect to approve — not run here)

- **E1 — does an ad-hoc app with a replicated extension load?**
  1. In a worktree, add `macos/Extensions/Files/` (Info.plist with the keys above; a class
     implementing `item`, `fetchContents`, `enumerator(for:)` over a hard-coded 3-item tree)
     and extend `bundle.sh`/`install.sh` the way `Share.appex` is built
     (`swiftc -O -application-extension … -Xlinker -e -Xlinker _NSExtensionMain`,
     `codesign --force --sign - --entitlements …`).
  2. Add a debug flag `--files-domain add|remove` that calls `NSFileProviderManager.add(NSFileProviderDomain(identifier:displayName:))`
     and prints the `NSError` domain/code.
  3. Run `build/…/PocketDeck.app --profile files-design --files-domain add`; then
     `pluginkit -m -p com.apple.fileprovider-nonui` (extension registered?),
     `NSFileProviderManager.getDomains` (domain there?), Finder ▸ sidebar (location shown?),
     open it (3 items?), Space on one (Quick Look materializes a real file?), and
     `ls ~/Library/CloudStorage/` (the domain's storage location).
  4. Repeat from a copy in `~/Downloads` (expect quarantine/translocation trouble; record it).
  Pass = all of step 3; else record the exact `NSFileProviderError` code — it decides E6 vs (b).
- **E2 — extension ⇄ app over the App Group, ad-hoc.**
  1. Add the group to both entitlements + `NSExtensionFileProviderDocumentGroup`; app creates
     `…/files.sock` (0700 dir) and answers `pong`.
  2. `codesign -d --entitlements :-` both bundles; extension logs the `connect()` errno.
  Pass = the extension gets `pong`; fail = repeat with the temporary-exception path and record
  which one the sandbox honours.
- **E3 — offline + queued edits.**
  1. With E1's provider: fetch a 5 MiB file, kill the fake phone, call `disconnect(…, .temporary)`.
  2. Finder: cached file opens; copy a file into a cached folder → stays as a *pending* item
     (`enumeratorForPendingItems()`), no user-visible error.
  3. Restart the fake phone, `reconnect()` → the extension is asked to upload it (`createItem`
     with `contents`).
- **E4 — thumbnails without materializing.** `fetchThumbnails` fills Finder's icon grid and
  `item.isDownloaded` stays false for those items.
- **E5 — one session.** While the app holds a session, extension reads are served over the
  same one; the fake phone logs no second connection (a second would be `busy`).
- **E6 (only if E1 fails) — the fallback mount.** App serves a read-only WebDAV tree of the
  fake phone on `127.0.0.1`; ⌘K `http://127.0.0.1:PORT`; check sidebar entry, thumbnails,
  Quick Look, and what a write does when the server is stopped.

### Experiment results (2026-10-19)

Run in the `pd-e2e` VM, `macos/scripts/check-e2e.sh files-exp` with `PD_E2E_VISIBLE=1`:
**28 passed, 0 failed**. Artefacts in `macos/build/vm-e2e/files-exp/work/r5-*`
(`r5-check.log`, `r5-finder-check.png`, `r5-notes-qL.png` and the screenshots of the
enable path).

**E1 — pass, with one one-time switch.** The ad-hoc-signed, sandboxed replicated
extension (`Files.appex`, bundle id `dev.pocketdeck.mac.files-e2e`, App Group
`group.dev.pocketdeck.mac.files.filesexp`) registers (`pluginkit -m -p
com.apple.fileprovider-nonui` lists it), `NSFileProviderManager.add` returns ok, and
the domain mounts at `~/Library/CloudStorage/PocketDeck-PocketDeckFiles`. A **new
domain starts `user-disabled`**: every job fails with `FP -2011 "Sync is not enabled"`
and any `ls` on the mount times out. Nothing non-GUI moves that switch:
`fileproviderctl` has no enable/approve command (`fileproviderctl help`: dump,
diagnose, evaluate, check/repair, obfuscate), and `pluginkit -e use -i
dev.pocketdeck.mac.files-e2e`, before or after the domain exists, leaves
`Enabled` false in `~/Library/Application Support/FileProvider/
dev.pocketdeck.mac.files-e2e/Domains.plist`.

The enable path that works is System Settings › **General › Login Items &
Extensions › Extensions**:

- *By App* (the default): the app's row (PocketDeck) → its ⓘ button → the sheet
  lists **File Provider** and **Sharing** → switch File Provider on. This is the
  shortest and the one `check-e2e.sh files-exp` now takes.
- *By Category* → **File Providers** → PocketDeck → switch on. Same result.

The app can take the person to the right pane: `open
"x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions"`
opens Login Items & Extensions directly on the Extensions section. (The bare URL
without `?Extensions` opens General, where the row is at the bottom, normally below
the fold.) That is the Deck's one-time prompt: say why, then open that URL; the
person flips one switch. Opening the sheet from the app itself is not possible
(the settings UI is another process), and there is no API to set the state.

**Ad-hoc signing is enough.** After the switch, no Gatekeeper, notarization or
signing error appears in `log show --predicate 'subsystem ==
"com.apple.FileProvider"'`; the sandboxed extension reaches the app over the App
Group socket (`socket group=pong`) and the App Group storage path from its
`NSExtensionFileProviderDocumentGroup` resolves.

**E2 — pass.** The app's App Group socket bridge answers the extension; the log
shows `socket group=pong` and every enumeration served through it.

**Enumeration and reads — pass.** `ls` on the mount lists `DCIM` (the experiment's
hard-coded tree has one root item); `DCIM` has `big.bin` and `notes.txt`;
`cat DCIM/notes.txt` returns the 39 bytes the fake phone serves; a `cp` out of the
domain writes the same bytes; Quick Look (`qlmanage -t`) writes a thumbnail for
`notes.txt`; Finder shows PocketDeck under Locations and the folder's contents.
`fileproviderctl dump` has `enabled: yes` and `errors: 0` for the domain (the
remaining `user-disabled` line belongs to the hidden default domain).

**E4 — pass, with Finder as the caller.** Finder's icon view made the system call
`fetchThumbnails ids=big size=2048x2048`, and no `fetchContents big` followed.
`qlmanage -t` on `big.bin` produces nothing (a `.bin` has no Quick Look
generator), so the check now opens the folder in Finder instead.

**E3 — pass.** Cached 5 MiB read, `disconnect(.temporary)`, the cached file still
opens, a `cp` into the domain is accepted locally and materializes as an upload
(`createItem pending.bin`) after `reconnect`. macOS keeps the write in its own
queue while disconnected, so the extension may see `createItem` only after
reconnect; the check accepts either ordering.

**Product consequence.** The File Provider path is viable, with a one-time,
per-person step: the Deck must explain it and deep-link
`x-apple.systempreferences:com.apple.LoginItems-Settings.extension?Extensions`;
until the switch is on, the domain is mounted but empty/timing out, so the app
should say "turn PocketDeck on in Login Items & Extensions" rather than show an
empty folder. No WebDAV fallback (E6) is needed for this reason. The e2e check
flips the same switch through the accessibility tree, so a VM run is green end to
end.

### S3 implementation notes

The experiment's code becomes the slice's product code; this is what it does.

- **Bridge wire** (`FilesCore.swift`, `FilesBridge.swift`): the App Group
  socket carries newline-delimited JSON, every message with a `u32` `id`.
  Requests: `hello` (version), `list` (path, page), `stat` (path), `read`
  (path, offset, length, etag), `cancel` (id). Replies: `hello` (name,
  connected), `items` (page, items), `item` (item), `data`, `end` (size,
  sha256), `error` (code). A read streams `{"id":N,"t":"data","len":L}\n`
  followed by exactly `L` raw bytes, repeatedly, then `end`; the extension
  writes them into its own
  `NSFileProviderManager(for:).temporaryDirectoryURL()` file, so the app never
  writes in the extension's space. `BridgeDecoder` is incremental (a line or a
  chunk may split across any reads); a request line is capped at 64 KiB, a
  reply line at 2 MiB (one `items` page is one line, and the phone may put
  1000 items in it) and a data chunk at 8 MiB. Both sides set `SO_NOSIGPIPE`:
  a write to a peer that just went away must not kill the app. The listener is
  0600 in the group container, refuses a
  peer whose uid differs, takes at most 4 clients, and each client may have at
  most 8 live ids.
- **Names**: bundle.sh writes `PDFilesGroup` into the app's and the extension's
  Info.plist and the same id into both entitlements. Production
  `group.dev.pocketdeck.mac.files`; every non-release bundle keeps its own
  (`…files-<variant>`). The socket is `files.sock` for the default profile and
  `files-<profile>.sock` otherwise. The domain identifier is the profile name
  (production: `default`); its display name is the phone's nickname, else
  "PocketDeck".
- **Identifiers**: `ino:<st_ino>:<relative path>`, or `path:<relative path>`
  when the phone reports `ino: 0`; `.rootContainer` for the root. The ino is
  the identity, and the path rides along (percent-encoded, so an id is one
  token) because the system runs the extension in more than one process and
  restarts it: an id must resolve without the in-memory map (the VM showed a fresh process asking for items a
  previous one had enumerated). The id ↔ path map is still kept and filled by
  listings and stats, the parent identifier is looked up there (or one stat
  supplies its ino), and a subtree is invalidated on delete. `contentVersion`
  is the etag, `metadataVersion` a SHA-256 of (name, size, mtime, ino).
  **A rename changes the id**, because the path rides in it. S3 is read-only so
  nothing renames; S4 must revisit this before it ships moves: either re-issue
  the item identifier and rely on the system's rename handling, or keep a
  second id form that is only the ino for known items. Do not assume an id
  survives a move.
- **Errors**: the pure map (`FilesFailure.from(code:)`) turns `offline` and
  `closed` into `NSFileProviderError(.serverUnreachable)`, `fs_not_found` into
  `.noSuchItem`, `fs_denied` into `CocoaError(.fileReadNoPermission)`,
  `fs_stale` into one metadata refetch then `.noSuchItem` if the item is gone,
  `fs_too_large` into a clear "over 1 GiB" read error, `fs_busy`/`busy` into
  `.serverUnreachable`, and everything else into the underlying error.
- **What the experiment code becomes**: `Files.swift` loses the hard-coded
  tree, the temporary-exception fallback and its log file (os_log only, no
  names) and serves the real tree through the bridge; `FilesDomain.swift`
  keeps `--files-domain` as a PD_TEST_HOOKS-only hook refused outside the VM and
  gains `FilesDomainController` (the Settings toggle, session
  reconnect/disconnect, the one-time System Settings prompt via
  `NSFileProviderDomain.userEnabled`); `FilesBridge` is the only listener, and
  `--files-bridge-dir` puts its socket in a test directory so the host e2e
  check can drive it without any File Provider.

## 2. Phone side (shell uid 2000)

**Listing and stat.** `/sdcard` is MediaProvider's FUSE mount, and at uid 2000 the FUSE
daemon *bypasses* MediaProvider: `shouldBypassMediaProvider(uid) { return uid == SHELL_UID ||
uid == ROOT_UID; }` in `MediaProviderWrapper.cpp`
(https://android.googlesource.com/platform/packages/providers/MediaProvider/+/refs/heads/main/jni/MediaProviderWrapper.cpp).
So plain `File.listFiles()` and `android.system.Os.stat()` see everything under `/sdcard`,
`Android/data` and `Android/obb` included (`isUidAllowedAccessToDataOrObbPath` also returns
true at shell uid), and listing costs one `readdir` plus one `lstat` per entry — the same
filesystem the drop path already writes to at this uid (`android/.../DropReceiver.kt`;
"at shell UID the filesystem of `/sdcard/Download` needs no extra privilege").

Two consequences worth designing around:

- **Rename goes through MediaProvider even at shell uid**: the same file's `Rename()` comments
  "Rename from SHELL_UID should go through MediaProvider to update database rows". Good for us
  (MediaStore stays consistent), but it can fail on paths MediaProvider does not know; the
  fallback is `File.renameTo` + `MediaScannerConnection.scanFile`, the drop path's habit.
- **Files we create with `File` are invisible to other apps until scanned**; we scan lazily
  (on write completion), not on every list.

**Change detection.** `FileObserver` is inotify and per watched inode: a directory watch
covers that directory's entries ("events will be triggered for all files and subdirectories
*inside* the monitored directory", `android/os/FileObserver` docs) — there is no recursion.
Watches are kernel resources: `inotify.max_user_watches` defaulted to 8192 for years (the
5.11 change makes it memory-scaled, 8192…1048576; Android GKI carries it) and
`max_user_instances` is 128. A recursive watch over a real `/sdcard` (DCIM + thousands of
app folders) will exhaust that; so will one FileObserver per directory we ever listed.

Design:

- **Watch only what the Mac currently has open, and only while it has it open.** The Mac sends
  `fs.watch paths,on:true` per folder it enumerates (and the working set), capped at 256
  watches on the phone. "Watch" means one `FileObserver` per folder (CREATE/DELETE/MOVED_TO/
  MOVED_FROM/CLOSE_WRITE), re-established for folders created under a watched one.
  *(S5 round 3 changed the Mac's half of this rule: a folder the system touches stays
  watched for ten minutes after the last touch, at most 64 — see "S5 round 3: the
  working set". The phone's cap and poll below are unchanged.)*
- When the cap would be exceeded, fall back to **`MediaStore.getGeneration(context, volumeName)`**
  (API 30+), a single `long` that changes whenever the volume's database changes, polled every
  5 s *while* something is watched; on a change, re-list only the folders the Mac has open and
  diff (ino, size, mtime) into `fs.changes`. Registering a `ContentObserver` on
  `MediaStore.getContentUri(volume)` is the push version of the same signal; MediaProvider
  batches its notifications, so inotify stays the primary source for the folders we watch.
- Nothing is watched while no Mac has the domain open — see §5.

**Scoped-storage surprises at shell uid.** None for read/write (the bypass above), and three
to respect anyway: (i) `Android/data` and `Android/obb` are reachable *because* we are uid
2000 — no other app can see them, and the person does not think of them as phone storage, so
the domain hides `Android/` and every dot-prefixed top-level entry (§4); (ii) MediaProvider
still polices names (the unicode check) on create/rename, so a rejected name is a real error,
not ours to retry; (iii) `/sdcard` normally holds no symlinks (FUSE refuses them) but the
path rule canonicalizes anyway (§4).

## 3. Protocol sketch (proposal, `docs/PROTOCOL.md` style)

One session, one feature multiplexed on it. Every request is one JSON message with an `id`
(u32 ≠ 0, chosen by the Mac); binary bodies use `FS_DATA` frames with `stream` = that `id`,
exactly the way `drop.start`/`DROP_DATA` do (`docs/PROTOCOL.md` "Drop Mac → phone") and with
the same pacing: **256 KiB chunks, at most 4 in flight** (`macos/Sources/PocketDeck/FileDrop.swift:134-135`),
the producer blocking past 1 MiB queued (the share-in rule). The phone is **stateless across
requests**: it keeps no index, no cache, no lock table beyond the running request.

| type | name | dir | payload |
|---|---|---|---|
| `0x24` | `FS_DATA` | both | the next bytes (≤ 256 KiB) of the file transfer `stream` = the request `id` |

Mac → phone:

| t | fields | meaning |
|---|---|---|
| `fs.list` | `id`, `path`, `page`? | children of `path`; `page` is the phone's opaque cursor, absent = first |
| `fs.stat` | `id`, `path` | one item's metadata |
| `fs.read` | `id`, `path`, `offset`, `length`, `etag` | stream `length` bytes from `offset` (`FS_DATA`, then `fs.read.end`); `etag` mismatch → `fs_stale` |
| `fs.write` | `id`, `path`, `size`, `sha256`, `etag`?, `temp`? | stream the body; `etag` = the version the Mac believes it is replacing; `temp` = this is a hidden staging write |
| `fs.move` | `id`, `from`, `to`, `etag`? | rename/move within the domain |
| `fs.delete` | `id`, `path`, `recursive` | delete a file, or a folder when it is empty or `recursive` |
| `fs.mkdir` | `id`, `path` | create one folder (`fs.exists` if taken) |
| `fs.setAttrs` | `id`, `path`, `mtime`? | Finder edits dates; best effort |
| `fs.watch` | `id`, `paths`, `on` | add/remove the folders the Mac is watching (§2, §5) |
| `fs.cancel` | `id` | abandon a read/write; the phone stops streaming and drops it |

Phone → Mac:

| t | fields |
|---|---|
| `fs.items` | `id`, `page` (null = last), `items`: `[{"name","dir","size","mtime","ino","etag"}]` — no path per item; the parent is implicit |
| `fs.item` | `id`, `item` (same shape) |
| `fs.changes` | `path`, `items`, `deleted`: `[name]` — at most 4 per second, coalesced (a WRITE storm becomes one message per folder) |
| `fs.progress` | `id`, `bytes` — at most 4 per second, plus once with the last byte (the drop rule) |
| `fs.read.end` | `id`, `size`, `sha256` — the range is complete and correct |
| `fs.result` | `id`, `ok`; success `item` (and the new `etag`); failure `code`, `message` |
| `error` | existing codes, plus `fs_not_found`, `fs_denied`, `fs_exists`, `fs_not_a_dir`, `fs_stale`, `fs_too_large`, `fs_busy` |

Rules:

- Caps: path ≤ 4096 bytes and ≤ 32 components; one request in flight per `id`; ≤ 8 live ids;
  a list page ≤ 1000 items and ≤ 1 MiB of JSON; a `fs.write` body ≤ 1 GiB announced, else
  `fs_too_large` before a byte arrives; reads are bounded by the file's own size at `fs.read`.
- Every reply carries its `id`; frames for a cancelled/unknown `id` are dropped (the drop
  rule). Session end abandons every running transfer; the phone deletes a partial write temp.
- Unknown fields are ignored, unknown `t` is logged once — the existing rules.

**Identifiers — the Mac's side.** The phone speaks paths *relative to the shared-storage root*
(`""` = root) and is stateless. The Mac cannot use paths as
`NSFileProviderItemIdentifier` (a rename must keep the item's identity), so:

- item identifier = `ino:<st_ino>` (with `st_dev` folded in when non-zero) from `Os.stat`;
  when the phone reports `ino: 0`, fall back to `path:<relative path>`.
- the extension keeps an `id ↔ path` map, populated by `fs.items`/`fs.item` and invalidated on
  `fs.changes`; a rename (`modifyItem`) keeps the id and only changes the filename.
- `NSFileProviderItemVersion`: `contentVersion` = the item's `etag`, `metadataVersion` = a hash
  of `(name, size, mtime, ino)`.
- **etag = 16 bytes of (ino, size, mtimeMs)** — a weak version that changes on any metadata
  change, which is what a replicated provider needs for conflict detection. Content hashes are
  used only where a pipeline already needs one: the SHA-256 of a write (`fs.write.result`), so
  the phone verifies before it renames (`drop.*` shape). No per-file hashing on list.

## 4. Security

- **Paths only, canonical, under one root.** Every incoming path is relative; it is rejected
  if it is absolute, empty where not allowed, contains `\`, NUL or a `.`/`..` component, or has
  more than 32 components. The root is `<shared storage>/` itself (`/storage/emulated/0`, the
  real path of `/sdcard`), resolved once at startup. Before any operation, `File(root, rel).canonicalPath`
  must equal the root or start with `root + "/"`; anything else is `fs_denied`. We never
  create or follow a symlink out of the root; a symlink whose target leaves the root is
  refused, not resolved.
- **The shell uid reaches more than the person expects; we expose less.** uid 2000 can read
  every app's `Android/data/<pkg>/` and `Android/obb/<pkg>/` file trees, `Android/media/…`,
  and dot-directories — none of which another app can see. A Finder location must be *shared
  storage*, so `Android/` and every dot-prefixed top-level name are hidden (`fs.list` of the
  root omits them; a direct request is `fs_denied`). This is not a privacy boundary inside the
  user's own device, it is the boundary between "what a person calls phone storage" and "what
  only uid 2000 can see".
- **The Mac is untrusted** (the drop/share rule): the phone validates every field, ignores
  unknown ones, closes the session on an oversized frame (`Frames.MAX_FRAME`, 8 MiB —
  `android/.../proto/Frames.kt:31`), and never lets a `fs.write` announce more than the cap.
- **No names or contents in logs, either side.** The phone logs counts, byte lengths, depths
  and codes only ("list 42 items", "read id=7 262144", "denied", "stale"); a refused path logs
  its depth, never its last component. The Mac logs lengths, hashes and the FP error code. A
  `--profile` non-default debug build may log a name hash prefix; the default profile never
  does.
- Transport is unchanged: mutual TLS 1.3, pinned, one session, no new port and no new listener
  (the App Group socket is a local, same-user bridge, not an interface others can reach).

## 5. Battery and resilience

- **Idle phone = nothing.** No watcher, no timer, no wake lock, no index. The session's
  existing idle state is one listening socket
  (`docs/ARCHITECTURE.md` "Session end / battery"). Watching starts on the first `fs.watch on`
  (equivalently: the first enumeration of a folder from a materialized domain), stops on
  `fs.watch off`, on the last holding folder closing, and on session end — plus a 30 s grace
  so a Finder refresh does not thrash watches.
- **While browsing**, the phone runs at most 256 inotify watches over exactly the folders the
  Mac named, or the 5 s `MediaStore.getGeneration` poll when the cap is reached; events are
  coalesced (≤ 4 `fs.changes`/s). No wake lock: the session is already awake because it is
  being used.
- **Mac offline.** Cached copies are ordinary local files, so reading, copying and Quick Look
  of previously downloaded items keeps working with no code of ours in the path. The app calls
  `NSFileProviderManager.disconnect(reason:options:.temporary)` when the session drops, so
  Finder says "items may be out of date"; dataless items answer `serverUnreachable`. Edits,
  copies-in and renames made then are local changes the system keeps as **pending items** —
  not our queue, not the phone's.
- **Reconnect.** On session-ready the app calls `reconnect()`, invalidates the extension's sync
  anchors (we may have missed `fs.changes` while away) and lets the system re-enumerate; the
  pending items upload through `createItem`/`modifyItem`/`deleteItem` in order. A failed
  upload reports through the item's `uploadingError` and the Deck's chip ("Phone files: phone
  away, 3 uploads pending"), whose source of truth is `enumeratorForPendingItems()`.
- **Nothing is queued on the phone ever**: a request that cannot be served returns an error and
  the Mac's File Provider retries. That keeps the phone's memory and battery out of the
  reliability story.
- A write is atomic from the person's point of view: bytes stream into
  `<target dir>/.<name>.pd-<id>` (same filesystem), are verified by `size` + `sha256`, and are
  then renamed into place (through MediaProvider, which updates its rows) and media-scanned.
  A cancel, a checksum mismatch or a session end removes the temp.

## 6. Slices (4–7 steps, smallest first)

Each slice ends with the checks it touches: K1 = `cd android && ./gradlew -q :app:assembleDebug
:app:testDebugUnitTest`, K2 = `cd macos && swift build && swift test`, plus the named e2e checks.
The e2e checks are **new checks in `macos/scripts/check-e2e.sh`**, run one at a time against
`tools/fakephone` (never `all`). fakephone grows a fake `/sdcard`: `--fs-root DIR`
(`PD_FAKE_FS_ROOT`), defaulting to a small tree the check builds in `$WORK/fsroot` — a few
folders, ~40 files, one 3 MiB and one 32 MiB file (S2), a `.hidden` and an `Android/data/x/`
pair (to prove the exclusions), with the phone-side rules of §3/§4 implemented in Python
(relative canonical paths, paging, etags from `st_ino/st_size/st_mtime_ns`), mirroring how
`drop.*` is already faked.

1. **S1 — read-only listing (protocol first, fakephone only).** Phone: `FsPaths` (root,
   canonical rule, hidden set) + `FsView` (list/stat, paging) + `Session` dispatch for
   `fs.list`/`fs.stat`. Mac: an `FsClient` on the session, driven by a hidden
   `--debug-fs-script FILE` (the `--debug-input-script` pattern). Checks: `FsPathsTest`,
   `FsViewTest` (a temp dir stands in for `/sdcard`, as `DropReceiverTest` does); e2e `files`:
   list `$WORK/fsroot` from the fake phone, names+sizes match; `..`, an absolute path and
   `Android` each answer `fs_denied`.
2. **S2 — ranges and `FS_DATA`.** `fs.read`/`FS_DATA`/`fs.read.end`/`fs.cancel` on both sides
   (bounded queue, one chunk in flight per id, cancel drops the rest). Checks: `FsReaderTest`
   (bounding, partial read, cancel); e2e `files` grows: copy the 3 MiB and the 32 MiB file off
   the fake phone, SHA-256 equal, no byte beyond the announced range.
3. **S3 — the Mac extension: domain, list/stat, fetchContents.** `macos/Extensions/Files/`
   (extension point, `NSFileProviderItem`, enumerator, `fetchContents` through the bridge),
   `FilesBridge` in the app, bundle/install changes, `--files-domain add|remove`. Checks: K2 +
   `FilesItemTests` (JSON → item: size, dates, uti, etag), `FilesPathMapTests` (id ↔ path,
   rename keeps the id); e2e `files-domain`: fakephone on, `--files-domain add`, assert the
   domain is registered (`getDomains`), the domain root lists the fake tree and a fetched file
   is byte-identical. (E1–E5 are the pre-slice experiments for this step.)
   **Done (read-only).** What shipped: `FilesCore.swift` (wire, decoder, item/path/failure
   maps), `FilesBridge.swift` (the 0600 App Group listener, streaming reads, cancel), the
   replicated extension in `macos/Extensions/Files/` (enumerator, `fetchContents`, read-only),
   `FilesDomainController` + the Settings row and Deck prompt, `--files-domain add|remove`
   and `--files-bridge-dir` as hooks. Checks: K2 738/0; `FilesCoreTests` 37, `FilesBridgeTests`
   13, `FilesDomainControllerTests` 11; e2e `files-bridge` 18/0 (host, bridge only, no File
   Provider) and the `files` regression 8/0; VM `files-domain` 29/0 with the Finder screenshot
   at `macos/build/vm-e2e/files-domain/work/finder.png`. What the VM taught us, now in the
   code: identifiers must resolve in a fresh extension process (so the path rides in them), a
   closed peer must not raise SIGPIPE, and a listing page is a single line larger than a
   request line. Known limitation: the id↔path coupling means a rename changes the id — S4
   owns that (see the identifiers note above).

### S4 implementation notes

S3's read-only tree gains writes: create, edit, rename, move, delete and folder creation,
with the phone's bytes verified and nothing lost when both sides changed a file.

- **Identifiers** are `ino:<st_ino>` only; `path:<relative path>` stays the fallback when the
  phone reports `ino: 0`, and `.rootContainer` is the root. The path no longer rides in the id,
  so a rename or a move keeps the identity — S3's limitation is gone.
- **The app owns the id ↔ path map**, because the extension runs in more than one process and
  is restarted at will while the app is one process: one JSON file per profile in the
  profile's Application Support folder (`files-ids.json`, 0600, written atomically), filled
  from every listing and stat reply and updated on every successful write, move, delete and
  mkdir. A stale entry (a stat by the mapped path reports another ino, or is gone) is
  re-resolved once from the parent's listing; if that does not settle it the answer is
  `noSuchItem`. Bumping the domain's version (the map format version, below) drops S3's
  path-carrying ids: on the first run of a domain with the old format the app removes and
  re-adds the domain, logging one line.
- **Bridge wire** (`FilesCore.swift`, `FilesBridge.swift`) grows a second version, and the
  requests carry item identifiers rather than paths, since only the app can resolve them:
  `list` (item, page), `stat` (item), `read` (item, offset, length, etag), `create` (parent,
  name, dir?, size, sha256), `modify` (item, base etag, changed fields: content and/or
  name/parent/mtime), `delete` (item, base etag, recursive), `cancel` (id). Replies carry the
  new or current item with its identifier (`{"t":"item","id","item"}`), and `{"t":"ok","id"}`
  for a delete. For a create or a content modify, `data` chunks travel extension → app on the
  same framing as reads; the app streams them into `fs.write` with the drop rule (≤ 1 MiB
  queued). The extension writes nothing outside its own temporary directory.
- **Extension**: capabilities add `allowsWriting`, `allowsAddingSubItems`, `allowsRenaming`,
  `allowsReparenting` and `allowsDeleting`, but not `allowsTrashing` — there is no trash
  container, so Finder's delete is immediate and says so. `createItem`, `modifyItem` and
  `deleteItem` carry a real `Progress`; a cancel sends the bridge `cancel`, which sends
  `fs.cancel`. With the phone away the answer is `NSFileProviderError(.serverUnreachable)`, so
  the system keeps the change pending and retries after `reconnect()`.
- **Conflicts**: a `modifyItem` whose base etag no longer matches the phone (`fs_stale`) keeps
  both — the Mac's content is uploaded as `<name> (from Mac).<ext>` in the same folder
  (numbered when taken: `<name> (from Mac 2).<ext>`), the phone's current item is returned for
  the original id, and one line logs "conflict" with no names. A delete whose base etag is
  stale does not delete: the phone's item comes back in Finder. A rename onto an existing name
  (`fs_exists`) answers `NSFileProviderError(.filenameCollision)`.
- **A create never replaces.** `createItem` sends `fs.write` with `exclusive: true`: a name that
  already exists on the phone (a photo taken since the Mac's last listing) answers `fs_exists`
  at the request (no byte accepted) and again right before the rename, and the phone's file is
  never touched. The extension maps that to `NSFileProviderError(.filenameCollision)`, so the
  system retries the new item under another name. The conflict copy is a create too and runs the
  same numbered retry (`(from Mac 2)` … `(from Mac 20)`, then it fails with that collision error);
  unlike the listing-based pick it survives a name taken between the listing and the upload.
  Without `exclusive`, a replace must name the version it replaces (`etag`); neither → `fs_exists`.
- **Delete names its version.** `fs.delete` carries the base etag and the phone checks it right
  before deleting (`fs_stale`, nothing removed), so there is no stat-then-delete window. A
  folder's etag is the folder's own, which catches children added or removed directly in it; a
  recursive delete removes what is in the folder at that moment, deeper changes included.
- **No trash**: `deleteItem` deletes forever on the phone; there is no `.trash` container on
  either side (a phone-side trash would change what the person sees in Files on the phone).
  Finder warns that the delete cannot be undone.
- **Caps and refusals** are the phone's (design §3): a write body over 1 GiB is
  `fs_too_large` before a byte, at most 8 live ids per client, one write at a time. The
  Android/ and dot-prefixed top-level rules, the canonical-path rule and "a write never
  replaces a directory" apply to every write op.


4. **S4 — write path: create, modify, delete, move; etags and conflicts.** Phone: `FsWriter`
   (temp + verify + rename + scan), `fs.move`/`fs.delete`/`fs.mkdir`/`fs.setAttrs`, `fs_stale`
   on an etag mismatch; rename through the MediaProvider path behind a `Platform` seam (so the
   JVM tests can assert it was used). Mac: `createItem`/`modifyItem`/`deleteItem` → `fs.*`.
   Checks: `FsWriterTest` (etag mismatch, cancel, over-cap, temp removed), K2 + a
   pending-item unit test; e2e `files-write`: copy a file into the domain (fake phone receives
   `fs.write.end` with a matching sha256), edit it, rename it, delete it — each action shows up
   in the phone's event log in order; then kill fakephone mid-write and assert the write is
   retried after restart.
   **Done (writes).** What shipped: `FsWriter` (hidden staging file, size + sha256, MediaProvider
   rename behind `FsPlatform`, media scan), `FsMutations` (`fs.move`/`delete`/`mkdir`/
   `setAttrs`, etag checks) and `AndroidFsPlatform` on the phone; `FsClient` writes and
   mutations, `FilesIdMap` (0600 from the moment its temp exists, parent ids, pinned across
   content replacement), bridge version 2 with the extension→app data flow and its 1 MiB gate,
   and the extension's `createItem`/`modifyItem`/`deleteItem` with Progress, cancel, offline and
   the `(from Mac)` conflict copy. A create is exclusive end to end (`fs_exists` at the request
   and again at the rename; the extension answers `filenameCollision`), a delete carries its
   base etag so the phone checks it right before deleting, and more bytes than announced get one
   `fs_denied` answer. Checks: K1 494/0; K2 786/0; e2e `files-write` 23/0 (create, edit, rename,
   move, delete, cancel, kill mid-write and retry, a create onto an existing name, the numbered
   conflict copy, a delete with a stale etag) plus the `files-bridge` 18/0, `files` 8/0 and
   `drop` 10/0 regressions.
   **VM.** `macos/scripts/vm-e2e.sh files-domain` runs in two sessions (2/2 used): 41/0. Finder's
   own actions, not the bridge: a 3 MiB copy into the mount lands on the fake phone with the
   Mac's sha256, an edit in place changes the phone's size, a rename follows (one entry, no
   duplicate), mkdir, delete, a copy made while the phone is away lands after the reconnect, and
   the 32 MiB file reads back byte-identical. The collision case: a name that exists on the phone
   but not in the Mac's listing is refused (`fs_exists`, 8 retries in the run) and **the phone's
   file keeps its bytes**; a POSIX `cp` has no "pick another name" step, so the system kept
   retrying the same name instead of renaming — the extension's `filenameCollision` answer is
   what Finder's own copy uses, and the numbered `(from Mac 2)` retry is proven by the host
   `files-write` check. Screenshots: the domain root and Documents in `finder.png` /
   `finder-documents.png` under the run's work dir.
   **Emulator: unverified.** The single boot was spent on the round-2 `unlock.sh` fix: the
   dump was being written to `/sdcard`, which is not mounted until the phone has been unlocked
   once (FBE), so round 1's dump was always empty and the bouncer grep could never match. The
   script now dumps to `/data/local/tmp`, raises the bouncer with `wm dismiss-keyguard`, accepts
   API 36's `KeyguardPINView` and enters the PIN as key events (with a blind attempt when the
   keyguard is not visible to uiautomator). That fix has not been run: no boot budget was left,
   so `tools/emulator/fs-write.sh` has not run either and nothing is claimed here about whether
   a MediaProvider rename keeps the MediaStore `_id`.
### S5 implementation notes

What the phone watches, and when, is a subscription on the session: the Mac says
which folders it has open, the phone watches exactly those, and nothing at all
while the list is empty. No watcher thread, timer or poll exists when idle.

- **The wire** is `fs.watch` / `fs.unwatch` (`id`, `paths`: relative folders) and
  the phone → Mac `fs.changes` (`paths`: the folders whose contents moved). A
  watch request that names `Android/…`, a dot-prefixed top-level entry or a path
  the shape rules refuse is `fs_denied` and adds nothing. `fs.watch` is additive
  and idempotent, `fs.unwatch` forgets a folder that is not watched. Both answer
  `fs.result` with `ok: true`; `fs.changes` carries paths only, never names, so
  the Mac re-lists the folder it already knows and diffs against its own last
  listing. That keeps the phone stateless (design §3) and means one event type
  covers create, edit, delete and rename.
- **One folder = one watch.** A `FileObserver` (inotify) per requested folder,
  non-recursive, CREATE/DELETE/MOVED_TO/MOVED_FROM/CLOSE_WRITE. Nested folders
  are watched only when the Mac has them open itself. A directory created under
  a watched one is seen as an entry change in the parent; opening it later adds
  its own watch.
- **A watch alone is not enough on `/storage/emulated`.** Round 2's emulator run
  placed a watch, logged it, and then got no `fs.changes` at all while `adb`
  created, deleted and burst files in the folder: inotify on the FUSE mount
  does not report changes another process makes through it on that build, and
  the failure is silent — the watch "succeeds". So while at least one folder is
  watched, `FsWatcher` also compares each watched folder every 2 s: a hash of
  the entry names (our own staging names left out), the folder's own mtime and
  count, plus size and mtime per entry while the folder is small enough for the
  stats to stay cheap. A folder whose shape moved goes through the same pending
  set as the watches, and a flush refreshes the fingerprints it reports, so one
  change seen by both paths is one `fs.changes`. inotify stays the fast path;
  the poll is the guarantee. Nothing is scheduled while nothing is wanted, and
  unwatch or session end stops it — the idle rule is unchanged. The cost is one
  readdir (plus up to 300 stats) per watched folder per 2 s, and only while the
  Mac has folders open.
- **Cap:** 256 live watches per session. The emulator's
  `fs.inotify.max_user_watches` is measured in S5 and recorded below; 256 is the
  budget we keep because the phone also watches for its own reasons and because
  `max_user_instances` (128) is the tighter kernel resource. When a request would
  exceed the cap, or a watch fails to start, the folder is still in the wanted
  set and the **generation fallback** covers it.
- **Generation fallback:** while any wanted folder lacks a live watch, the phone
  polls `MediaStore.getGeneration()` every 5 s. A changed generation marks every
  wanted folder as changed in one `fs.changes`. It is the same signal the
  `ContentObserver` push would carry, without depending on MediaProvider's
  batching. The poll stops the moment every wanted folder is watched (or none
  is), so the idle rule still holds.
- **Coalescing:** events only add a folder to a pending set; the set is flushed
  at most once per 250 ms as one `fs.changes` (≤ 4 per second per session). A
  write storm in one folder is one message.
- **Our own temp files never signal.** A `.pocketdeck-*.part` staging name is
  dropped by the watch source before it reaches the coalescer, so a create from
  the Mac does not echo back as a change.
- **Teardown:** `fs.unwatch` closes that watch; a session end closes every watch
  and stops the poll. The bridge's client cap grows from 4 to 6 because the
  watch subscription is one standing connection per extension process. The Mac also sends `fs.unwatch` when its last enumerator
  for a folder goes away (below), so "no one is looking" is reached both ways.
- **Mac side:** `enumerator(for:)` asks the bridge to `watch` its container, and
  the enumerator's `invalidate()`, the extension process ending or the bridge
  client closing asks to `unwatch` it. The app maps container ids to paths,
  ref-counts the paths **across extension processes and clients**, and only then
  sends `fs.watch`/`fs.unwatch` on the session. On `fs.changes` the app re-lists
  the folder, diffs it against the listing it handed out last, follows a rename
  through the item identifier (which is the ino, so the same file under a new
  name is an update, not a delete plus an add), bumps that container's anchor,
  keeps the last 32 deltas and pushes a signal to the extension, which calls
  `NSFileProviderManager.signalEnumerator(for:)`. **Corrected in round 3: that
  per-container call is ignored by a replicated extension (see "S5 round 3"
  below); the app signals the working set instead.** `currentSyncAnchor` answers the
  container's anchor; `enumerateChanges(from:)` replays the deltas after it, and
  an anchor older than the kept history — or one from another process — is
  `NSFileProviderError(.syncAnchorExpired)` so the system re-enumerates.
  **The app must do that itself, not only the extension.** Round 2's VM run
  showed the push going only to *connected* extension clients while Finder kept
  none alive between two operations, so the change reached nobody and the mount
  did not move. The bridge now also asks the domain to re-enumerate the changed
  container (`NSFileProviderManager.signalEnumerator(for: <container>)`, one
  cached domain lookup per app run); that call is what starts an extension when
  none is running. The push to a live client stays as the fast path.
  **Corrected in round 3:** that container signal is ignored too — a replicated
  extension may only signal the working set — so neither the push nor the
  container call moved the mount. Round 3's working-set signal is the one the
  system acts on.
- **A rename replaces only when the caller says so.** The platform seam is explicit:
  `rename(from, to, replace)` / `plainRename(from, to, replace)`. An exclusive
  create and `fs.move` pass `false`; only a write whose etag matched passes
  `true`. A `FileAlreadyExistsException` from the seam is `fs_exists` and
  nothing of the caller's is left behind (a write's temp is deleted, the other
  file keeps its bytes). `plainRename` without replace is `Files.move` with no
  `REPLACE_EXISTING`, so the kernel checks the name and moves in one call.
  `rename` is a `renameTo`, which has no no-replace mode, so it does one fresh
  existence check immediately before the syscall: Java has no
  `RENAME_NOREPLACE`, and the usual portable trick (hard link, then unlink)
  does not work on the FUSE-backed `/storage/emulated` mount. The window left
  is the gap between that check and the rename — microseconds instead of the
  whole transfer. A create used to replace a file that appeared after its last
  check, i.e. one that landed while the bytes streamed.
- **Who indexes a finished file.** A rename on the FUSE mount goes through MediaProvider even
  at shell uid (§2), and MediaProvider indexes the new path as part of that rename: in the
  round-2 emulator run the written photo had a MediaStore row right after the write and the
  same `_id` after a rename, with no scan of ours in between. So a write or a move calls the
  media scan only when the **plain** fallback did the rename; the media-aware path does not
  scan on top of MediaProvider's own work.
- **Why the shell service died in round 1.** `MediaScannerConnection.scanFile` with the Context
  Shizuku hands in — the app's package, inside a process that runs as uid 2000 — acquires
  MediaProvider on a background HandlerThread, and the system refuses it
  (`SecurityException: Given calling package … does not match caller's uid 2000`) on that
  thread. No `runCatching` can catch that: the uncaught exception kills the process. It
  happened right after the write and again right after the move, while the rows themselves
  were fine. `MediaScan` replaces it with one synchronous `scan_file` provider call per path (the
  call the framework's own `MediaStore.scanFile` makes) on its own daemon thread, from a context
  whose package is the one this uid really is (`com.android.shell`), all inside `runCatching`;
  the drop path's scan had the same call shape and got the same fix. The fix is from that
  logcat evidence and was not re-run (one boot this round), so a fallback-path scan that the
  provider still refuses costs a log line, never the process.
- **Collision (S4 leftover).** Apple's replicated-provider contract says a  `createItem` that answers `NSFileProviderError.filenameCollision` is retried
  by the system with another name, and `NSFileProviderCreateItemOptions.mayAlreadyExist`
  means "the name may now be there, it is yours to resolve". A POSIX `cp` is not
  a File Provider client operation, though: in S4's VM run the system replayed
  the same `createItem` 8× with the same name and the copy stayed pending. So
  the extension now resolves the collision itself: on `fs_exists` it creates the
  file under the next free name, `<name> 2.<ext>`, `<name> 3.<ext>`, … up to 20
  (`<name> 21` + ext is the last try; past that it answers the same collision
  error), with `exclusive: true`, and returns the created item, whose filename
  the system applies to its local copy. The phone's file is never touched, and
  the person sees the copied file appear as `name 2.ext` instead of a pending
  item that never lands. `.filenameCollision` stays only for the "20 names are
  taken" give-up. Renames and moves (`modifyItem`) are unchanged: a name already
  taken there is still a collision for the person to resolve.

**Done (watching).** What shipped: the phone's `FsWatcher` (one `FileObserver`
per folder, 256 cap, 250 ms coalescing, `.pocketdeck-*.part` dropped, the 5 s
`MediaStore.getGeneration()` poll while any wanted folder is unwatched),
`fs.watch`/`fs.unwatch`/`fs.changes` on the wire (bridge v3) and the session
re-applying its counted watches after a reconnect; on the Mac the ref-counted
watch per container, the per-container delta log (32 deltas, `g<gen>.<scope>`
anchors, `syncAnchorExpired` past the history), a quiet baseline for a watched
folder the system never listed, and the extension subscribing in
`enumerator(for:)`, `enumerateChanges` and `currentSyncAnchor` (with
`invalidate()` as the unwatch, and a dead bridge socket re-opened and
re-subscribed). A phone-side rename is an update of the same identifier: a
persisted id whose inode no longer matches is re-derived on its first listing,
so a path that came to hold another file cannot hand it an old id. Re-listings
are serialized per folder and settle for 150 ms, so a rename's two
notifications cannot surface as a delete followed by an add.
Checks: K2 805/0; `files-watch` 20/0 (create, edit, a rename keeping the id, a
delete, unwatch on close, a change after close sends nothing, coalesced
`fs.changes`, the drop when its client goes away, no file names in the app
log); regressions `files-write` 24/0, `files-bridge` 18/0, `files` 8/0.
**VM (round 1).** The collision leftover is proven: a POSIX copy onto a taken name lands
as `collide 2.bin` and nothing is left pending in `fileproviderctl dump`. The
watch is only partly proven: the phone was asked to watch (and unwatched) the
open folder, but the phone-side create and rename still did not reach the mount
in the run (47 of 49). The change→mount path was fixed after that run (a
watched folder with no listing now gets a quiet baseline; the check waits for a
new phone watch instead of any earlier one, so a file cannot predate the
watch's own baseline). Host `files-watch` drives the same wire with the driver,
not the File Provider stack.
**VM (round 2).** `files-domain` in one session: 46 of 49. The watch was still
not proven and the run says why. The fake phone logged `watch on 1` and its three
change batches, so the phone's half worked; the mount's create and rename never
moved, and the delete step passed only because nothing had appeared. The app's
bridge sent a change to *connected extension clients* only, and Finder does not
keep an extension process alive between two operations (the run's log is full of
`client gone`), so the change reached nobody. Fixed after the run: the bridge
also asks the domain to re-enumerate the changed **container**
(`NSFileProviderManager.signalEnumerator(for:)`, one cached lookup per domain),
which is the call that starts an extension; the push to a live client stays as
the fast path. **Round 3 found that call is a no-op too** (a replicated
extension may only signal the working set); the working-set signal replaced it
and is what the next VM run tests. Not re-run in round 2: budgets were spent, so
"watch reaches the mount" is unverified end to end until the real-phone pass. The third failure, `many lists
0 names, wanted 1500`, is a 1500-entry listing that returned nothing while the
four root listings before it worked; nothing in this epic changed that path and
round 1 passed it, so it is recorded as unexplained, not fixed.
**Emulator (round 1).** The unlock fix works (the bouncer dump lands in
`/data/local/tmp` and the PIN is entered): `fs-write.sh` passed mkdir, the
write, the sha256 and the MediaStore row, then the app's shell service went
away (TLS `UNEXPECTED_EOF_WHILE_READING` on every later call while adb stayed
healthy).
**Emulator (round 2, one boot).** The service died twice, and the crash buffer
named it: `FATAL EXCEPTION: android.bg`, `SecurityException: Given calling
package … does not match caller's uid 2000`, raised inside
`MediaScannerConnection` (see the notes above). The scan now never uses the app
Context from this process and only runs when the plain rename fallback did the
work. The same boot measured the write path end to end: the JPEG reached the
phone with the Mac's sha256, MediaStore listed it, a rename **kept its `_id`**
(41 before and after), a delete dropped the row, a write into `Android/data`
answered `fs_denied`, and no staging file was left. The watch half is *not*
proven on the device: `fs.watch` answered ok and no `fs.changes` arrived in
13 s while adb created, deleted and burst files in the folder — i.e. inotify
does not report another process's changes through the FUSE mount on API 36 —
and `cat /proc/sys/fs/inotify/max_user_watches` returned nothing for the shell
user, so **`max_user_watches` is still unmeasured**. Fixed from that evidence
after the boot: `FsWatcher` compares every watched folder every 2 s (names,
sizes and mtimes hashed; no names logged) while anything is watched, and
inotify stays the fast path. Not re-run on a device.

### S5 round 3: the working set

Rounds 1 and 2 signalled the changed *folder*
(`signalEnumerator(for: <container>)`) from the extension, and round 2 added the
same call from the app. Apple's `NSFileProviderManager.h`, above
`signalEnumeratorForContainerItemIdentifier:`, says why neither moved the mount:

> When using NSFileProviderReplicatedExtension, only call this method with
> NSFileProviderWorkingSetContainerItemIdentifier. Other container identifiers
> are ignored. The system will automatically propagate working set changes to
> the UI, without explicitly signaling the containers currently being viewed in
> the UI.

The extension is replicated, so every container signal was a no-op. Round 3
signals the working set and gives it a real enumerator.

- **The working-set enumerator.** `enumerator(for: .workingSet)` returns a
  `WorkingSetEnumerator` (never a phone listing and never a phone `fs.watch`);
  `.trashContainer` returns an enumerator that lists nothing and watches
  nothing, because there is no trash. `NSFileProviderReplicatedExtension.h`:
  "The working set enumerator is a special enumerator
  (NSFileProviderWorkingSetContainerItemIdentifier) the system uses to detect
  changes that should be synced to the disk and/or searchable in Spotlight.
  Because that enumerator is by definition used for change detection, the
  working set enumerator must implement
  `enumerateChangesForObserver:fromSyncAnchor:` and
  `currentSyncAnchorWithCompletionHandler:`."
- **The anchor is one domain-wide sequence.** The app keeps one ordered log of
  deltas across every container: each entry is a sequence number, the container
  it happened in, and the container's `FilesDelta` (full items, deletions by
  identifier). It is capped at 512 entries. The working-set anchor is
  `w:<epoch>:<sequence>`; a folder enumerator's anchor is
  `g:<epoch>:<sequence>:<container>`. The epoch changes when the app starts, so
  an anchor from an earlier process cannot be replayed against a fresh log.
  `enumerateChanges(from:)` returns every update after the anchor with the item's
  **real** `parentItemIdentifier` (not the working set), then
  `finishEnumeratingChanges(upTo:moreComing:)`; an anchor that is unparseable,
  from another epoch, from the future, or older than the kept entries is
  `NSFileProviderError(.syncAnchorExpired)`. A first enumeration (`nil` anchor)
  answers every item the app currently has in its cached listings.
- **Why `enumerateItems` may be a snapshot.** The working set is enumerated
  with `enumerateChangesFromSyncAnchor:` (NSFileProviderEnumerating.h: "This
  method is also called with NSFileProviderWorkingSetContainerItemIdentifier,
  which is enumerated with
  -[NSFileProviderEnumerator enumerateChangesForObserver:fromSyncAnchor:]"), and
  the system removes an item from its replica only when the change observer
  calls `didDeleteItemsWithIdentifiers:` ("Delete existing items. No-op if the
  item was unknown."). So an item that a re-enumeration does not return is not
  treated as gone; on an expired anchor the system "will drop all cached data
  and start the enumeration over starting with sync anchor nil"
  (NSFileProviderEnumerating.h). Round 3 therefore answers `enumerateItems` for
  the working set with every item the app currently has in its cached listings,
  paged by index, and never turns "not returned" into a deletion.
- **The signal.** When a phone `fs.changes` produced a delta, the app calls
  `NSFileProviderManager(for: domain).signalEnumerator(for: .workingSet)`, at
  most twice a second (the first change of a burst goes out at once, later ones
  coalesce; one cached manager per domain, as in round 2). The completion's
  error domain and code are logged ("domain: signal working set" plus
  "failed domain=… code=…") — round 2 discarded them. The per-container calls
  are gone from the extension and from the app; they were ignored anyway. The
  push on a live watch connection stays as the fast path for a connected
  extension.
- **What the phone watches (a deliberate change to §5).** A replicated extension
  is not told what Finder is showing and its enumerators are short-lived, so
  "watch only while an enumerator exists" left the phone watching nothing
  exactly when a change arrived with no extension running. The new rule: a
  folder is watched on the phone from the moment the system touches it — its
  container enumerator, `enumerateItems`/`enumerateChanges`/`currentSyncAnchor`
  on it, or a fetch/create/modify/delete of an item in it — until **10 minutes
  after the last touch** (every touch refreshes it), at most **64 folders**
  (the least recently touched drops first), all dropped on disconnect and
  re-sent on reconnect while their 10 minutes last. The phone side is
  unchanged: its 2 s folder poll while anything is watched is still the
  guarantee, so idle means no watch and no poll. The TTL and the cap are unit
  tested with an injected clock, and the TTL is shortened through the
  environment for the host check (`PD_FILES_WATCH_TTL`).
- **`.workingSet` and `.trashContainer` are never phone folders.** Before this
  round `enumerator(for: .workingSet)` fell through to the phone path: it sent
  `fs.watch` for a folder literally named after the identifier and listed it
  (an `fs_not_found` in the VM log). The app also refuses those identifiers on
  every phone-facing request, so a protocol mistake cannot turn one into a
  listing or a watch.

**Done (round 3).** What shipped: one domain-wide delta log (`FilesChangeLog`:
sequence + container + delta, 512 entries) behind two anchor shapes,
`w:<epoch>:<sequence>` for the working set and
`g:<epoch>:<sequence>:<container>` for a folder; a `WorkingSetEnumerator` that
answers `currentSyncAnchor`/`enumerateChanges` from it and pages the app's
cached listings for `enumerateItems`, and an `EmptyEnumerator` for
`.trashContainer`; both identifiers refused by the app on every phone-facing
request. The app signals the working set on a delta (coalesced to two a second)
and logs the completion's error domain/code; the extension and the domain
controller no longer signal containers. `FilesWatchSet` keeps a touched folder
for ten minutes after the last touch, at most 64 (LRU), unit tested with an
injected clock; `PD_FILES_WATCH_TTL` shortens the TTL for the host check. A big
folder is enumerated in 250-item batches with the page cursor carrying the
offset (`b<offset>@<phone page>`) and the phone page cached, and the id-map JSON
is written once per quarter second instead of once per item.
Checks: K2 849/0; host `files-watch` 29/0 (working-set updates with the real
parent, a delete, `.workingSet`/`.trashContainer` no phone traffic, 65 folders
→ 64, TTL → `watch off`); regressions `files-write` 24/0, `files-bridge` 19/0,
`files` 8/0.

**VM (round 3).** Session 1: 49 of 54. The 1500-entry folder listed **all 1500
names** (round 2's `many lists 0 names` is fixed by the 250-item batches), and
the working-set enumerator answered a full scan after an expired anchor (1547
cached items, two pages). The phone-side create and rename still did not reach
the mount, and the run's log showed why: the app logged `bridge: signal
containers` but never `domain: signal working set`, because the controller's
signal guarded on the stored setting while `--files-domain add` adopts a domain
without it. Fixed after the run (`enabled || addedLocally`, with a unit test for
the adopted case; K2 849/0, host `files-watch` 29/0 again). Session 2 was meant
to prove the fix end to end; the memory watchdog stopped the VM four minutes in
(swap 5.4 GB, free 16%), which spends the round's second boot, so there was no
third session. **Unverified:** "with no extension process running, a phone-side
create reaches the mount within 10 s" — the fix is unit-tested and the host wire
is green, but the system's response to the working-set signal was not observed.
The next VM round (or the real-phone pass) must run that step. Session 2 reused
the run directory (`vm-e2e.sh` clears it at start), so session 1's work
directory — including its Finder screenshots — is gone; the two console logs are
in `macos/build/vm-e2e/files-s5r3/`.

**VM (supervisor re-run, after the merge).** `vm-e2e.sh files-domain` from main:
**54 of 54**. Every watch step passed: a phone-side create, rename and delete
reached the mount in 0–1 s; closing Finder left the folder watched for its ten
minutes; then, with no extension process running in the guest, a phone-side
create reached the mount in **1 s** — the case rounds 1–2 lost. The app logged
the working-set signal with no error and the system enumerated the working set
after it (counts only). Two earlier attempts failed for a reason outside the
extension: the VM's disk persists between runs, a run cut short left its domain
registered, the check's pre-run remove ran before the bundle was registered (so
it said "not found"), and an add that comes right after a remove finds the old
domain's CloudStorage folder still there and imports it from disk — the root is
then never asked of the extension and every listing stalls (`importing: true`,
MaterializationError). The check now removes after registering and waits for the
folder to go before the add; `wait_until` is a wall-clock deadline (it counted
tries, so a 15 s `ls` per try stretched a 90 s wait toward 90 minutes).
Still unverified: the same on a real Mac with the real phone (the hands-on pass).

   fallback) + `fs.watch`/`fs.changes`; the platform seam lets the JVM test drive a fake watch
   source. Mac: `enumerateChanges`/`currentSyncAnchor` + `signalEnumerator` from the bridge.
   Checks: `FsWatcherTest` (nothing watched when idle; only the requested paths; teardown on
   session end; ≤ 4 `fs.changes`/s coalesced); e2e `files-watch`: create/edit/delete in
   `$WORK/fsroot` while the Mac has the folder open and see the Mac's view change; the fake
   phone's log must show `watch on` then `off` after the folder closes, and no watcher wheel
   when nothing is open.
6. **S6 — offline, thumbnails, polish, Deck UI.** Phone: error mapping, the Android/hidden
   rules already in S1 exercised end to end, MediaStore scan on write. Mac: the Deck's "Phone
   files" row (domain state, "Show in Finder", add/remove domain from Settings), the offline
   path of §5. Checks: e2e `files-offline` (kill fakephone → `disconnect` called, cached read
   works, a write stays pending; restart → `reconnect`, upload lands), host `files-bridge`
   phase `thumb` and VM `files-thumbs` (the icon grid fills from `fs.thumb` while
   `isDownloaded` stays false — see "Thumbnails (S6)").

## Thumbnails (S6)

Finder's icon grid asks the extension for a picture and no file body: E4's
run logged `fetchThumbnails ids=big size=2048x2048` and no `fetchContents` for
`big` afterwards (§1). So the picture comes from the phone, not from a
materialized copy on the Mac, and the wire addition is one request shaped like
`fs.read` (PROTOCOL.md "Phone files" › "Thumbnails"). This section is what
FILES-22…29 carry, and it closes the old open question: the Mac never
materializes a file just to draw its icon.

**Which items (T1).** Only a name whose extension maps to a type conforming to
`public.image` or `public.movie` (`UTType(filenameExtension:)`, the same call
`FilesMap.contentTypeIdentifier` already makes for `ProviderItem.contentType`).
Everything else — a `.pdf`, a folder, a name with no type — is answered with
nil data at once, with no phone request, so the system draws its type icon. The
extension cannot map an identifier to a name, so it sends one `thumb` request
for every id in the batch and the app makes the decision from the mapped path
(`FilesThumbPolicy.pathIsMedia`, the same `UTType` call) before any phone
traffic; a wrong answer here costs a phone round trip per icon.

**The path (T2).** The extension adopts `NSFileProviderThumbnailing`:
`fetchThumbnails(for:requestedSize:perThumbnailCompletionHandler:completionHandler:)`
arrives as a batch. Each media item becomes one `thumb` bridge request —
`{t:"thumb", id, item, size}` (the item's identifier, the batch's long side
clamped to the wire's 1–4096) — on its own `BridgeConnection`, the bridge's one
request per connection habit, so the extension needs no demultiplexer and never
holds more than 3 connections (the bridge's 6-client cap). The app turns it
into one `fs.thumb {id, path, size}` on the session. No etag goes with it: the
id map keeps ids and paths, not etags, and a `thumb` of a version the phone has
already replaced is corrected by the next listing (a picture of the wrong
version is still only a picture, while a stat per icon would cost more); the
phone's `etag` field stays optional for any other caller. the phone answers with
`FS_DATA` frames (`stream` = the phone id), then `fs.thumb.end {id, mime, size,
sha256}`, or one `fs_*` failure. The extension hands the bytes to the system as
`Data` — `perThumbnailCompletionHandler` takes no type, and the system sniffs
JPEG/PNG — checks the end's `size` and `sha256` against what it received (the
read's rule) and answers nil on a mismatch, and calls the batch's completion
once. The bridge's own version goes 3 → 4 (new request and reply cases); the
phone's wire version stays 4 (new `t` values only).

**Lost or missing (R-1).** The system may remember a nil answer as "this version
has no thumbnail" and not ask again until the item's version changes, so a
picture lost to a timeout or a disconnected phone would never appear. The
per-thumbnail handler therefore answers a **transient** failure — the session
down, the 8 s deadline, `fs_busy` (the app's `offline`, `timeout`, `fs_busy`,
`busy`, `closed`) — with `NSFileProviderError(.serverUnreachable)` (a transient
error, so the answer is not remembered as final), and a **permanent** one — not
a media type, `fs_no_thumb`,
`fs_not_found`, `fs_denied`, `fs_not_a_dir`, `fs_stale`, a size/sha256 mismatch
— with nil data. Neither is shown to the person: a thumbnail error is not an
alert, and the type icon is what either answer leaves behind. `FilesThumbPolicy`
holds both decisions, so K2 pins them even though the extension object itself is
compiled only by `bundle.sh`.

**Measured (VM `files-thumbs`, 2026-11-03).** The system did not ask again after
either answer: not by itself within 45 s, not on close and reopen within 30 s,
and not at all with the phone away. `serverUnreachable` is therefore harmless
but cannot be relied on to bring a lost picture back — a lost thumbnail returns
only when the item's version changes. That is why a queued ask must not expire
while it waits (FILES-29).

**The phone's generator (T3).** `FsThumbnailer` mirrors `FsReader`: a request
parses the id, path, `size` (1–4096, else `fs_denied`), resolves the path,
stats, refuses a directory, checks `etag` like a read, checks the name's MIME
prefix is `image/` or `video/`, and enqueues the job. One worker thread runs the
queue; each job calls a `ThumbSource` seam, whose Android implementation
(`AndroidThumbSource`) is `ThumbnailUtils.createImageThumbnail(File, Size,
CancellationSignal)` or `createVideoThumbnail(...)` (API 29+; minSdk is 30),
then `Bitmap.compress` — JPEG at quality 80, or PNG when the bitmap has alpha
and the item is an image (a video frame is opaque even when its bitmap reports
alpha, so video is always JPEG) — with the long side `min(size, 512)`. Over
256 KiB it re-encodes once as JPEG at
quality 60 (a PNG over the cap loses its alpha; it is a thumbnail), and if that
is still over, `fs_no_thumb` with no bytes. The seam is what the JVM tests fake:
`FsThumbnailer` owns the cap, the re-encode decision, the queue, cancel and the
logs; the platform owns decode and encode. Nothing is cached and nothing is
prefetched; cancel goes through the same `CancellationSignal`, and no code on
this path touches `PowerManager` or the display.

**Limits (T4).** At most 3 thumbnails in flight per session on the Mac
(`FilesThumbQueue` in the app: FIFO, 3 slots, an 8 s deadline per request
measured from the `fs.thumb` send — a queued ask waits its turn; cancel either
leaves the queue or sends one `fs.cancel`); the extension keeps its own 3 per
batch so it never leans on the app's queue for pacing. The phone generates one
at a time, accepts at most 3 live thumb ids (`fs_busy` past that) and puts the
frames on the **bulk lane** — `SendQueue.enqueueBulk`, the session writer's
lowest-priority queue, drained after JSON, control, audio and video deltas with
at most 1 MiB queued; the same `FS_DATA` type the paths layer counts as bulk
(12 MiB unacked cap, 1 MiB window, no seq until the path has room). So a grid
of icons can never overtake a reply, delay a stream, or starve a drop.

The queue's one request, by state (`FilesThumbQueue.transition`):

| state | `slotFree` | `end` / `failure` | `cancel` | `deadline` | `drop` |
|---|---|---|---|---|---|
| `queued` | → `running`, send `fs.thumb` | ignored | → `cancelled`, answer `cancelled`; nothing reaches the phone | **ignored: queue time is not the phone's work** | → `cancelled`, answer `offline` |
| `running` | ignored | → `done`, answer the bytes or the code | → `cancelled`, one `fs.cancel`, answer `cancelled` | → `expired`, one `fs.cancel`, answer `timeout` | → `cancelled`, answer `offline` |
| `done` / `cancelled` / `expired` | ignored | ignored | ignored | ignored | ignored |

Only the `queued` → `running` send arms the deadline timer; `settle` cancels it.

**Why 8 s, and why the queue waits.** A warm 512 px encode is tens of
milliseconds, a cold HEIF/HEVC decode about a second; the answer is at most
256 KiB, about 20 ms on the LAN's 100 Mbit/s floor. The deadline starts when
`fs.thumb` goes to the phone, so 8 s covers one ask's cold decode with a wide
margin and stays under the 10 s at which Finder's grid reads as broken. Queue
time is not the phone's work: Finder asks for every visible item at once, the
phone generates one at a time, and a timeout is not retried by the system until
the item's version changes, so expiring a queued ask would lose its picture for
good. A queued ask therefore waits until it runs, Finder cancels it (the
`Progress` is cancelled when the icon scrolls away or the window closes), or the
session ends. The extension's per-thumbnail connection waits up to 120 s —
about 170 photos at 0.7 s each, a full Finder icon grid — so the socket cannot
cut a queued ask short, while still bounding a bridge that died. It is a bridge
deadline, not an NFR time limit: nobody waits on a thumbnail (the type icon is
already there), so it does not belong in NFR.md; it is the spec's FILES-29 and
the bridge's own constant.

### Round-2 test plan

- **K1 — the generator behind the seam** (`FsThumbnailerTest`, a fake
  `ThumbSource`): the 512 long-side cap, JPEG 80, the alpha → PNG choice for an
  image and JPEG for a video, the
  single re-encode and `fs_no_thumb`, the 256 KiB cap, cancel of a queued and a
  running job, one worker and FIFO order, `fs_busy` past 3 ids, the etag and
  missing-file refusals, no call at all without a request, and log lines that
  carry no name.
- **K2 — the extension's routing with a fake bridge** (`FilesThumbTests`, plus
  `FilesBridgeTests` and `FilesCoreTests`): an image is media and a `.pdf` is
  not, a document path asks the phone nothing, the request carries the long
  side, 3 in flight and the fourth queued in arrival order, cancel before and
  during the phone call, a transient failure (offline/timeout/`fs_busy`) →
  `serverUnreachable`, a permanent one (`fs_no_thumb`, `not_media`) → nil data,
  the bridge's deadline (a 50 ms deadline in the test) answers `timeout` and
  sends one `fs.cancel`, and a queued ask does not expire while it waits but
  gets its full deadline from the send (twenty asks behind three slots).
- **Fake phone:** `fs.thumb` serves a fixed JPEG for a fixture name, with a mode
  that never answers and a mode that answers `fs_no_thumb`; host e2e
  `files-bridge` grows a `thumb` phase through the real bridge: bytes then
  `end` with a matching mime/size/hash, a `.pdf` and a folder answered without a
  phone request, three at once and the fourth after one ends, a cancelled queued
  ask the phone never sees, the deadline's one `fs.cancel`, and 12 asks against
  a phone that takes 1 s each all answering with bytes (the last waits past 8 s
  before it starts).
- **One VM boot:** `files-thumbs` — Finder's icon view shows the fake phone's
  thumbnail for a fixture JPEG while the item stays undownloaded (`isDownloaded`
  false), the PDF shows its type icon, and the fake phone's log has no
  `fs.thumb` for the PDF. The screenshot is
  `.agent/finder-thumbs/after-files-thumbs.png`.
- **One emulator boot:** `thumbs` — push a JPEG, a HEIC and an MP4 into the
  emulator's `DCIM/Camera`, ask `fs.thumb` for each through `deckctl`, and print
  the mime, the long side, the byte count and the time each took; assert ≤ 256
  KiB and a long side ≤ 512. The real-phone cost measurement stays with the
  reviewer.

## Fixes 10-20 (the hands-on pass)

The first real Mac + real phone run (2026-10-20) found three defects and two
honesty gaps. All are fixed on this branch; the unit tests and the host checks
run everywhere, the end-to-end proof is `files-domain` in the VM (the real
Mac + phone pass stays with the reviewer).

- **A fetch took 20 s.** `fetchContents` read frames until the connection
  answered. `end` is the read's terminal reply, but the loop treated it as an
  intermediate one: it set no failure, the `if failure != nil` guard did not
  break, and the next `next()` blocked until the socket's `SO_RCVTIMEO` (20 s)
  returned nil. A Quick Look preview fetches more than once (thumbnail and
  preview), so a 412-byte file took about a minute. The loop now leaves on
  `end` (or `error`) and logs `fetch done bytes=<n> ms=<n>`; every other
  `while let frame = connection.next()` loop in the extension was audited and
  already returned on its terminal reply.
- **A preview wrote the file back.** After an open, the system sends a modify
  for its replica's own bookkeeping (last-used date, tags, favourite rank).
  The extension forwarded every `modifyItem`, so the phone got
  `content=false` with no name, parent or date and re-wrote the file. The
  decision is now a pure helper (`FilesModifyDecision`): a write happens only
  for contents, or a filename, parent or modification date that really
  differs. Anything else is answered locally with the item as it is.
- **A watch named a file.** The working set touches folders, but the system can
  ask about a file (a preview did); the phone answered `fs_not_a_dir` and the
  logging-only failure hid it. A touch now resolves the item and, when it is a
  file, watches its folder instead. The 64-folder cap is unchanged.
- **The location is "PocketDeck (<phone name>)".** `FilesDomain.displayName`
  now uses the one name every other surface uses (`RememberedPhones.displayName`:
  the nickname, else the phone's own name) and composes "PocketDeck (<name>)";
  with no phone it stays "PocketDeck". A rename, or the phone's name arriving
  after the domain was added, re-adds the same identifier with the new display
  name, which macOS updates in place: the Finder location and its
  CloudStorage folder (with the cached files) stay.
- **Settings are honest about the build.** A bundle without the App Group or
  `Contents/PlugIns/Files.appex` shows a disabled switch and "This copy of
  PocketDeck was built without Finder files."; the controller never tries to
  add a domain and logs one line. Real failures say to turn the switch off and
  on again instead of promising that a restart helps. `scripts/install.sh`
  forwards extra arguments to `bundle.sh`, so `./scripts/install.sh --with-files`
  installs the extension, and (only for a bundle that carries it) registers the
  installed copy and its `Files.appex`.

## Alternatives rejected

- **The extension dials the phone itself.** One session per phone (`busy`), and the keys/pins
  live in the app; the extension would fight the app for the only session.
- **A localhost WebDAV mount** (§1(b)) as the primary: no pinning, no queued edits, no
  provider thumbnails or progress, a manual remount after every disconnect. Kept as E6 if the
  File Provider turns out not to load ad-hoc.
- **macFUSE/FUSE-T** (§1(c)): a system extension or a third-party daemon plus a System
  Settings approval, for a feature macOS now does in user space.
- **SMB or NFS served by us**: writing an SMB2/3 server is a project of its own, and NFS
  mounts need root (or a shim, i.e. FUSE-T again).
- **Keeping our own cache of phone files on the Mac**: the replicated File Provider already
  is the cache, with eviction, pinning and offline reads for free; a second cache would only
  duplicate it.
- **An index/database of `/sdcard` on the phone**: MediaStore already is one, and any index we
  keep costs battery the moment nobody is browsing.

## Open questions

- Does an ad-hoc signed app group container work without a team identifier on macOS 26
  (E2), or does the extension need the temporary-exception entitlement? This decides how the
  extension reaches the app, not whether it can.
- Does fileproviderd launch the extension and hold the domain when the app is closed (E1/E3)?
  If not, the domain is only live while the app runs — acceptable, but the Deck must say so.
- Watch cap: 256 is a guess. S5 should measure the real `max_user_watches` per uid on the
  emulator and tune; the generation poll is the safety net either way. S5's `fs-watch.sh` did
  not get to run in round 1, and in round 2 `cat /proc/sys/fs/inotify/max_user_watches`
  returned nothing for the shell user on API 36, so **the number is still unmeasured**. The
  folder poll above is now the real safety net: it does not depend on inotify at all, so the
  cap only decides how many folders get the fast path.
- Deleting into the Trash server-side: `deleteItem` is "delete forever"
  (https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension);
  a phone-side `.trash` is possible but changes what the person sees in Files on the phone.
