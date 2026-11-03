# Drag & drop + clipboard images (ROADMAP #8)

Drag files from Finder onto a phone window → the phone writes them to
`/sdcard/Download/PocketDeck/`, media-scans them and offers a SEND chooser; clipboard
images travel both ways. Dragging **out** of a phone window is design only (§Drag out).

## Protocol
- **Drop** on any stream window (app, link, phone mode) and on the Deck. A lone `.apk`/`.apks`/`.xapk`
  keeps going to the APK installer (docs/design/apk.md); anything else is a transfer (several queue,
  one at a time). `--debug-input-script` gains `dropfile PATH` (e2e): it feeds the same handler the
  drag ends in; `application(_:open:)` stays APK-only, like Open With.
- Mirrors `apk.install` + `APK_DATA`: Mac → `{"t":"drop.start","id":N,"name","mime","size",
  "sha256","resume":bytes?}` → binary `0x22 DROP_DATA` (`stream` = `id`, chunks ≤ 1 MiB, paced like
  APK parts: ≤ 256 KiB, ≤ 4 in flight) → phone `drop.progress {bytes}` ≤ 4/s, then exactly one
  `drop.result {ok:true,path}` / `{ok:false,code:"bad_request"|"too_large"|"busy"|"checksum"|
  "cancelled"|"failed","message"}`. `drop.cancel {id}` any time; session end abandons (partial
  file removed). Cap 200 MiB counted while receiving; one drop per phone (a second `start` → `busy`).
- **Resume**: `resume:bytes` + a partial temp for the same `(name,size,sha256)` → the phone answers `drop.progress` with the verified offset and the Mac streams on; otherwise from zero.
- Names: `[A-Za-z0-9 ._-]`, ≤ 100 chars, no leading dot, collisions " 2", " 3"… — the share-in receiver's rules, on both sides.

## Phone side (shell UID, like the APK path) — progress in the window
A glass pill like the reconnect pill shows "Sending report.pdf… 43 %" and the outcome for 5 s. All bytes stream into a hidden temp file in `/sdcard/Download/PocketDeck/` (`mkdir -p` on demand;
the only path we create), renamed after a SHA-256 match. Then a media scan
(`MediaScannerConnection.scanFile`, best effort) and — where sensible: one file, a context and our provider
available — the SEND step, whose URI grant must come from the UID that owns `dev.pocketdeck.fileprovider`.
Shell (UID 2000) does not own it, so an `am start -a SEND --grant-read-uri-permission` from shell has the grant
silently dropped and the receiver crashes on a URI it cannot open. Instead the shell process stages the finished
file in the app's external media folder (`Android/media/dev.pocketdeck/shared/`; the app reads what shell writes
there, while the same file under `Android/data/<pkg>` stays unreadable to it) and starts the exported, UI-less
`dev.pocketdeck.drop.ShareTrampoline` with the bare name. The trampoline accepts only a name its own sanitiser
leaves alone, copies the file into `cacheDir/shared/` (≤ 5 files, ≤ 500 MB) and shows the SEND chooser for that
copy, `FLAG_GRANT_READ_URI_PERMISSION` and `ClipData` set — the grant therefore comes from the app's own UID.
The phone never trusts payload or name beyond `sha256` and the sanitised name.

## Finder file copies (round 1)
A copy in Finder carries `public.file-url` next to `public.utf8-plain-text`, which holds the
file's name. Any pasteboard item with the file type is a **file copy**: `ClipboardSync.poll`
reads its URLs (`ClipboardPasteboard.currentFileURLs`, `readObjects` with file URLs only) and
never sends its text, and ⌘V in a stream window consumes it instead of typing the name
(`PasteboardReader.isFileCopy`). Exactly one file whose type conforms to `public.image` at
8 MiB or under becomes a clipboard image (PNG and JPEG verbatim, any other image type as PNG);
a file over 1 MiB is read and decoded off the main thread. Everything else sends nothing
(SHARE-2). The planned drop path turns ⌘V into a transfer instead (SHARE-17).

## Clipboard images — extends `clip.set` (text only today)
- Binary `0x23 CLIP_DATA`, both directions, same shape as the drop:
  `{"t":"clip.image.start","id","mime","size"}` → `0x23` chunks →
  `{"t":"clip.image.end","size","sha256"}` / `{"t":"clip.image.abort","id"}`. Cap 8 MiB each way:
  over it the sender is silent and the receiver ignores — exactly the `clip.set` rule at 1 MiB.
  JPEG stays JPEG; other phone formats become PNG.
- Mac: the text poll also picks up an image item (PNG verbatim, TIFF converted) when the item has
  no text; received images are written back as PNG. A hash of the bytes prevents echo like
  `syncedHash`; secret/concealed items are still never sent.
- Phone: `ShellClipboard` gains image read (first item's stream) and write (`ClipData.newUri` on a
  FileProvider URI under Downloads/PocketDeck, media-scanned). Risk: other apps pasting a
  shell-made clip depends on ClipboardService URI grants — verified on the emulator; worst case the
  image still exists in the folder.

## Drag out (design only, not built)
The window exposes a file-promise drag (qualifier: a mouse-side long-press, since the input mapper
owns ordinary drags). On demand the phone sends `share.file` + `SHARE_DATA` on a fresh share id into
the promise temp file. Deferred: the pasteboard demand loop and the gesture arbitration.

## Alternatives rejected
Base64 in JSON (+33 %, the 8 MiB JSON cap; a binary frame is free). Reusing `APK_DATA` (it routes
to pm; a second meaning of the same ids invites wrecks). A shell `am start` that grants our provider URI
("Alternatives rejected" in round 1: the grant comes from UID 2000, which does not own the provider, so the
system drops it). Sharing the MediaStore URI of the scanned file (the app cannot read a file it does not own
without `READ_MEDIA_*`, so it can neither verify nor usefully grant it — measured on API 36: `openInputStream`
fails, and a shell grant of it is dropped too). Staging under `Android/data/<pkg>` (measured: the app cannot
read a shell-written file there, even in its own package folder). A
clipboard cap over 8 MiB would stream through the queue that carries video and stall the session.

## Risks
The SEND step is verified with a live `am start` of the trampoline on the emulator (chooser shown, Messages
opens the attachment, no `Permission Denial` in logcat). A vendor ROM that refuses the trampoline leaves the
file written in Downloads. Phone→Mac image reads through other apps' content URIs may not resolve.
