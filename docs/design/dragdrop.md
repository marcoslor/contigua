# Drag & drop + clipboard images (ROADMAP #8)

Drag files from Finder onto a phone window → the phone writes them to
`/sdcard/Download/PocketDeck/`, media-scans them and offers a SEND chooser; clipboard
images travel both ways. Dragging **out** of a phone window is design only (§Drag out).

## Entry points (Mac)
- **Drop** on any stream window (app, link, phone mode) and on the Deck. A lone
  `.apk`/`.apks`/`.xapk` keeps going to the APK installer (docs/design/apk.md); anything
  else is a transfer. Several files queue, one at a time.
- `--debug-input-script` gains `dropfile PATH` (e2e): it feeds the same handler the drag
  ends in. `application(_:open:)` is left APK-only (Open With stays an APK path).

## Protocol — mirrors `apk.install` + `APK_DATA`
1. Mac → `{"t":"drop.start","id":N,"name","mime","size","sha256","resume":bytes?}`,
   `id` u32 ≠ 0; anything the phone rejects → `drop.result {ok:false,code:"bad_request"}`.
2. Mac → binary `0x22 DROP_DATA`, `stream` = `id`, chunks ≤ 1 MiB, paced like APK parts
   (≤ 256 KiB, ≤ 4 in flight) so video and replies never stall.
3. Phone → `drop.progress {id, bytes}` ≤ 4/s (and once with the last byte), then exactly
   one `drop.result {id, ok:true, path}` / `{id, ok:false, code:"too_large"|"busy"|
   "checksum"|"cancelled"|"failed","message"}`.
4. Mac → `drop.cancel {id}` any time; session end abandons (partial file removed).
5. Cap 200 MiB counted while receiving; one drop per phone (a second `start` → `busy`).
6. **Resume**: `resume:bytes` + a partial temp file for the same `(name,size,sha256)` →
   the phone answers `drop.progress` with the verified offset and the Mac streams on;
   otherwise it restarts from zero. Name: `[A-Za-z0-9 ._-]`, ≤ 100 chars, no leading dot,
   collisions " 2", " 3"… — same rules as the share-in receiver, on both sides.

## Phone side (shell UID, like the APK path)
All bytes stream into a hidden temp file in `/sdcard/Download/PocketDeck/` (`mkdir -p` on
demand; the only path we create), renamed after a SHA-256 match. Then a media scan
(`MediaScannerConnection.scanFile`, best effort) and — where sensible: one file, a context
and our provider available — `am start -a android.intent.action.SEND -t <mime>
--grant-read-uri-permission --eu android.intent.extra.STREAM <uri>`, as argv (never
`sh -c`; shell UID may background-start activities, the app process may not). The URI is
the **app's** `dev.pocketdeck.fileprovider` (`external-path` → `/storage/emulated/0`); with
the provider's `grantUriPermissions="true"` the system honours the flag for a shell caller
too. The phone never trusts payload or name beyond `sha256` and the sanitised name.

## Clipboard images — extends `clip.set` (text only today)
- Binary `0x23 CLIP_DATA`, both directions, same shape as the drop:
  `{"t":"clip.image.start","id","mime","size"}` → `0x23` chunks →
  `{"t":"clip.image.end","size","sha256"}` / `{"t":"clip.image.abort","id"}`.
- Cap 8 MiB each way: over it the sender is silent, the receiver ignores — exactly the
  `clip.set` rule at 1 MiB. JPEG stays JPEG; other phone formats become PNG.
- Mac: the text poll also picks up an image item (PNG verbatim, TIFF converted) when the
  item has no text; received images are written back as PNG. A hash of the bytes prevents
  echo like `syncedHash`; secret/concealed items are still never sent.
- Phone: `ShellClipboard` gains image read (first item's stream) and write
  (`ClipData.newUri` on a FileProvider URI under Downloads/PocketDeck, media-scanned). Risk:
  other apps pasting a shell-made clip depends on ClipboardService URI grants — verified on
  the emulator; worst case the image still exists in the folder.

## Progress in the window (Mac)
A glass pill like the reconnect pill: "Sending report.pdf… 43 %", then the outcome for 5 s.

## Drag out (design only, not built)
The window exposes a file-promise drag (`NSDraggingItem` promise, qualifier: a mouse-side
long-press, since the input mapper owns ordinary drags). On demand the phone sends
`share.file` + `SHARE_DATA` on a fresh share id into the promise temp file. Deferred: the
pasteboard demand loop and the gesture arbitration.

## Alternatives rejected
- Base64 in JSON (share.text style): +33 % and the 8 MiB JSON cap; a binary frame is free.
- Reusing `APK_DATA`: it routes to pm; a second meaning of the same ids invites wrecks.
- App-process activity start for SEND: Android 10+ background-activity-launch blocks it;
  `am` from shell is the documented exemption.
- Clipboard sync over 8 MiB: pasteboards hold screenshots, not videos; a larger cap would
  stream through the queue that carries video and stall the session.

## Risks
- The shell `SEND` grant is verified with a live `am start` on the emulator; a vendor ROM
  that refuses leaves the file written and a told-off toast instead.
- Phone→Mac image reads through other apps' content URIs may not resolve; best effort.
