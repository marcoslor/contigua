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
  when the phone can answer cheaply (S5+) they are real phone thumbnails; otherwise the system
  makes an icon from the file type.
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
  chunk may split across any reads); a request line is capped at 64 KiB and a
  data chunk at 8 MiB. The listener is 0600 in the group container, refuses a
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
  the identity, and the path rides along because the system runs the
  extension in more than one process and restarts it: an id must resolve
  without the in-memory map (the VM showed a fresh process asking for items a
  previous one had enumerated). The id ↔ path map is still kept and filled by
  listings and stats, the parent identifier is looked up there (or one stat
  supplies its ino), and a subtree is invalidated on delete. `contentVersion`
  is the etag, `metadataVersion` a SHA-256 of (name, size, mtime, ino). A
  rename keeps the id, so S4 must move the path part of it too.
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
4. **S4 — write path: create, modify, delete, move; etags and conflicts.** Phone: `FsWriter`
   (temp + verify + rename + scan), `fs.move`/`fs.delete`/`fs.mkdir`/`fs.setAttrs`, `fs_stale`
   on an etag mismatch; rename through the MediaProvider path behind a `Platform` seam (so the
   JVM tests can assert it was used). Mac: `createItem`/`modifyItem`/`deleteItem` → `fs.*`.
   Checks: `FsWriterTest` (etag mismatch, cancel, over-cap, temp removed), K2 + a
   pending-item unit test; e2e `files-write`: copy a file into the domain (fake phone receives
   `fs.write.end` with a matching sha256), edit it, rename it, delete it — each action shows up
   in the phone's event log in order; then kill fakephone mid-write and assert the write is
   retried after restart.
5. **S5 — watching and the idle rule.** Phone: `FsWatcher` (bounded inotify + the generation
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
   works, a write stays pending; restart → `reconnect`, upload lands), and `files-thumbs`
   (`fetchThumbnails` fills the grid while `isDownloaded` stays false).

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
  emulator and tune; the generation poll is the safety net either way.
- Should thumbnails come from the phone (`fetchThumbnails` → an `fs.thumb` read) or from the
  Mac's own Quick Look once a file is materialized? S6 decides; the cheap answer is the
  latter for downloaded files and the former for the working set.
- Deleting into the Trash server-side: `deleteItem` is "delete forever"
  (https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension);
  a phone-side `.trash` is possible but changes what the person sees in Files on the phone.
