# APK install from the Mac (ROADMAP #10)

Drop an `.apk` (or an `.apks` / `.xapk` split bundle) on PocketDeck → it installs on the
phone with progress and a clear result ("Installed Example 1.2"); the app list refreshes so
its icon appears in the grid.

## Entry points (Mac)
- **Drop** a file on the Deck window.
- **Open With / `open -a PocketDeck.app x.apk`**: `CFBundleDocumentTypes` for `.apk`, `.apks`,
  `.xapk` (role Viewer); files arrive in `application(_:open:)` next to `pocketdeck://` URLs.
- **Menu bar** "Install APK…" (an open panel). A menu bar extra cannot take drops reliably.
- **Services** "Install on Phone" for the same file types (`NSSendFileTypes`).
- Several paired phones → the links picker ("Install on which phone?"), same routing rules.

## Bundle parsing (Mac, `ApkBundle`)
All three formats are zips; a minimal central-directory reader (system frameworks only).
- Entry names with `..` components, a leading `/`, a backslash or NUL reject the whole file.
- `.apk`: must contain `AndroidManifest.xml` → one file, `base.apk`.
- `.apks` / `.xapk`: the `.apk` entries are the parts (`standalones/` and `.obb` ignored).
  Base = `base.apk` / `base-master.apk` / `<package>.apk` named in `manifest.json`; else the
  only part not named `config.*` / `split_*`. No `.apk` entry → "not an Android app".
- Parts are extracted (stored or deflate) to a 0700 temp dir, streamed, then deleted.
- Total size cap 1 GiB on both sides.

## Protocol
1. Mac → `{"t":"apk.install","id":N,"files":[{"name","size","sha256"}]}` (id u32 ≠ 0, chosen
   by the Mac; names `[A-Za-z0-9._-]{1,100}` ending `.apk`; base first).
2. Mac → binary `0x20 APK_DATA` frames, `stream` = id, payload = the next bytes (≤ 1 MiB),
   files back to back in order.
3. Phone → `apk.progress {id, bytes}` (≤ 4 per second) and finally
   `apk.result {id, ok:true, pkg, label, version}` or `{id, ok:false, code, message}`.
4. Mac → `apk.cancel {id}` at any time; the phone abandons and replies `ok:false, code:"cancelled"`.
`code` is pm's `INSTALL_FAILED_*` / `INSTALL_PARSE_FAILED_*` token, or `bad_request`,
`too_large`, `busy` (one install at a time), `checksum`, `cancelled`, `failed`. The Mac maps
codes to human text (downgrade, signature/UPDATE_INCOMPATIBLE, storage, ABI, SDK, parse).

## Phone side
Runs at shell UID on its own thread fed by a bounded queue (the reader thread only blocks
when pm is slower than the network). `pm install-create -S <total>` → session id; per part
`pm install-write -S <size> <sid> <name> -` with the frame bytes piped to stdin (argv, never
`sh -c`; nothing is written to disk by us); sha256 checked per part before `install-commit`;
any failure or cancel → `install-abandon`. The new package = the one whose
`lastUpdateTime` is newest since the install began → label + versionName.

## Alternatives rejected
- `adb install` from the Mac: needs adb pairing; PocketDeck already has a session.
- Copy to `/data/local/tmp` then `pm install`: a world-readable file lingers; streaming doesn't.
- Base64 chunks in JSON: +33 % bytes and JSON parsing per MiB; a binary frame is free.
- PackageInstaller from the app UID: needs REQUEST_INSTALL_PACKAGES and a user prompt per install.
- Choosing ABI/density splits on the Mac: pm accepts the full set; selection can come later.
