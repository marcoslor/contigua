# Drag & drop + clipboard images (ROADMAP #8)

Drag files from Finder onto a phone window → the phone writes them to
`/sdcard/Download/PocketDeck/`, media-scans them and offers a SEND chooser; clipboard
images travel both ways. Dragging **out** of a phone window is designed only (§7).

## Entry points (Mac)
- **Drop** on any stream window (app, link, phone mode) and on the Deck.
- The drop handler routes: a lone `.apk`/`.apks`/`.xapk` keeps going to the APK installer
  (docs/design/apk.md); anything else is a transfer. Several files queue, one at a time.
- **Open With / Services** for a generic file are not new entry points: `application(_:open:)`
  keeps sending files only through the APK route. `--debug-input-script` gains `dropfile PATH`
  (e2e): it feeds the same handler the drag ends in.

## Protocol (Mac → phone) — mirrors `apk.install` + `APK_DATA`
1. Mac → `{"t":"drop.start","id":N,"name,"mime,"size","sha256", ("resume":bytes)}`, `id` u32 ≠ 0;
   `name` `[A-Za-z0-9 ._-]{1,100}`. Phone → `drop.result` `bad_request` for anything else.
2. Mac → binary `0x22 DROP_DATA`, `stream` = `id`, chunks ≤ 1 MiB, sent like APK parts
   (≤ 256 KiB, ≤ 4 in flight, completion-paced) so video and replies never stall.
3. Phone → `drop.progress {id, bytes}` ≤ 4/s plus once with the last byte, then exactly one
   `drop.result {id, ok:true, path}` or `{id, ok:false, code:"too_large"|"busy"|"checksum"|
   "cancelled"|"failed","message"}`.
4. Mac → `drop.cancel {id}` any time; session end abandons (partial file removed).
5. Size cap 200 MiB counted while receiving; one drop at a time (a new `drop.start` → `busy`).
6. **Resume**: `drop.start` may carry `resume:bytes`; when the phone still holds a partial
   temp file for that exact `(name,size,sha256)` it replies `drop.progress` with the verified
   offset and the Mac streams from there; anything else restarts from zero.

## Phone side (shell UID, like the APK path)
- All bytes stream into a hidden temp file in `/sdcard/Download/PocketDeck/` (`mkdir -p` on
  demand), renamed only after a SHA-256 match. Names: the Mac's `name` is reduced to
  `[A-Za-z0-9 ._-]`, no leading dot, ≤ 100 chars; collisions get " 2", " 3"… The folder is
  the only thing we touch (the app may not assume anything else exists).
- After the rename: media scan (`MediaScannerConnection.scanFile`, best effort) so the file
  is visible in Files/Photos; then, "where sensible" (one file, a context and our provider
  available): `am start -a android.intent.action.SEND -t <mime> --grant-read-uri-permission
  --eu android.intent.extra.STREAM <content-uri>` run as argv (never `sh -c`; shell UID may
  background-start activities, the app process may not). The URI is the **app's**
  `dev.pocketdeck.fileprovider` (`external-path` → `/storage/emulated/0`); because the
  provider has `android:grantUriPermissions="true"`, the system honours the flag for a
  shell caller too. No chooser extras; the phone's person picks the app.
- The phone never trusts the frame payload beyond the announced sha256.

## Clipboard images both ways — extends `clip.set` (one way: text)
- New binary type `0x23 CLIP_DATA` (both directions) with the same announce/end shape:
  `{"t":"clip.image.start","id":N,"mime":"image/png","size":S}` → `0x23` chunks →
  `{"t":"clip.image.end","id":N,"size","sha256"}` or `{"t":"clip.image.abort","id":N}`.
  JPEG stays JPEG; anything else the phone's clipboard serves becomes PNG.
- Cap 8 MiB each way: over it the sender stays silent and the receiver ignores, exactly like
  the 1 MiB `clip.set` rule. One image per side at a time; a new start replaces the old.
- Mac: the poll that watches for text also picks up an image item (PNG taken verbatim, TIFF
  converted) when the item has no text; received images are written to the pasteboard as
  PNG. A hash of the bytes prevents echo, like `syncedHash`.
- Phone: `ShellClipboard` gains image read (the first item's stream, shell may read the clip)
  and write (`ClipData.newUri` on a FileProvider URI under Downloads/PocketDeck, media-scanned).
  Known risk: whether other apps can paste a shell-made clip depends on ClipboardService URI
  grants; verified on the emulator, worst case the folder still has the image.
- Concealed/secret/autogen pasteboard items are still never sent.

## Progress in the window (Mac)
Stream windows (and the Deck) show a glass pill like the reconnect pill: "Sending
`report.pdf`… 43 %", success/failure for 5 s; a transfer is one per session (busy otherwise).

## Drag out (design only, not built)
Finder-style promotion: window calls `beginDraggingSession` with a file promise
(`NSDraggingItem` `writePasteboardTypeFilePromise`) when the pointer drags from a long-press
onto Finder; the phone would then push `share.file` chunks on demand (a heartbeat-pumped
`share.out` request + SHARE_DATA on a second stream id) into a temp promise file. Kept out of
scope: the input mapper owns ordinary pointer drags, so a drag-out needs a qualifying gesture
(a button-2 long-press) plus a pasteboard demand loop; lands in a later milestone.

## Alternatives rejected
- File bytes in JSON/base64: +33 % and the 8 MiB JSON frame cap; a binary frame is free.
- Reusing `APK_DATA` for drops: it routes to pm; a parallel id-space invites wrecks.
- Writing straight to `/data/local/tmp` or `am push`: world-readable leftovers, and the
  Downloads folder is what the person can find.
- Background-activity-launch from the app process: Android 10+ blocks it; `am` from shell is
  the documented exemption, and no grant dance is needed for `MediaStore` URIs we do not own.
- Clipboard image sync above 8 MiB: pasteboards hold screenshots, not videos; a bigger cap
  would stream through the same queue that carries video and stall the session.

## Risks
- Emulator `SEND` grant from shell: verified with a live `am start`; if a vendor ROM refuses,
  the file is still written and the toast says where.
- Phone→Mac image read: content URIs under the shell's clipboard may not resolve; best effort,
  mirrored to the Mac only when the bytes are readable.
