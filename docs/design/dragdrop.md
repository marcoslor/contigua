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
there, while the same file under `Android/data/<pkg>` stays unreadable to it). The folder is
`/storage/emulated/0/Android/media/<pkg>/shared`: in the uid-2000 process both
`getExternalMediaDirs()` and `Environment.getExternalStorageDirectory()` are refused (boots 3/4),
so it is computed from the real root and the app's package. The shell then starts the exported,
UI-less
`dev.pocketdeck.drop.ShareTrampoline` with the bare name. The trampoline accepts only a name its own sanitiser
leaves alone, copies the file into `cacheDir/shared/` (≤ 5 files, ≤ 500 MB) and shows the SEND chooser for that
copy, `FLAG_GRANT_READ_URI_PERMISSION` and `ClipData` set — the grant therefore comes from the app's own UID.
The phone never trusts payload or name beyond `sha256` and the sanitised name.

## Finder file copies
A copy in Finder carries `public.file-url` next to `public.utf8-plain-text`, which holds the
file's name. Any pasteboard item with the file type is a **file copy**: `ClipboardSync.poll`
reads its URLs (`ClipboardPasteboard.currentFileURLs`, `readObjects` with file URLs only) and
never sends its text, and ⌘V in a stream window consumes it instead of typing the name
(`PasteboardReader.isFileCopy`). Exactly one file whose type conforms to `public.image` at
8 MiB or under becomes a clipboard image (PNG and JPEG verbatim; any other image type re-encoded, as PNG with alpha and as JPEG at quality 0.9 when opaque, so a HEIC photo fits the cap);
a file over 1 MiB is read and decoded off the main thread. Everything else sends nothing
(SHARE-2). The drop path turns ⌘V into a transfer instead (SHARE-17).

## Clipboard images — extends `clip.set` (text only today)
- Binary `0x23 CLIP_DATA`, both directions, same shape as the drop:
  `{"t":"clip.image.start","id","mime","size"}` → `0x23` chunks →
  `{"t":"clip.image.end","size","sha256"}` / `{"t":"clip.image.abort","id"}`. Cap 8 MiB each way:
  over it the sender is silent and the receiver ignores — exactly the `clip.set` rule at 1 MiB.
  JPEG stays JPEG; other phone formats become PNG.
- Mac: the text poll also picks up an image item (PNG verbatim, TIFF converted) when the item has
  no text; received images are written back as PNG. A hash of the bytes prevents echo like
  `syncedHash`; secret/concealed items are still never sent.
- Phone: `ShellClipboard` gains image read (first item's stream) and write (one item carrying
  only a FileProvider URI under Downloads/PocketDeck, media-scanned). A2, measured on the
  emulator: a URI-only item pastes nothing in a plain field (a content URI that cannot serve text
  coerces to null; `plain text length=0`) and reaches a field whose content listener takes image
  types (`rich image bytes=98`; boots 3/4). The URI is built from the drop folder by hand, and
  the storage root is `/storage/emulated/0`, because both `FileProvider.getUriForFile` and
  `Environment.getExternalStorageDirectory()` are refused for uid 2000 (boots 3/4; files.md §4).
  Risk: another app pasting a shell-made clip depends on ClipboardService URI grants — the r2
  boots stopped at the write (`clip.image.done ok:false`), and the fixed write was not re-run
  (no boot left), so it stays unproven until the real-phone spike; worst case the image still
  exists in the folder.

## Paste and drop into an app (SHARE-16–17 built; SHARE-18 planned)

⌘V in an app's window stops being a text-only key. The pasteboard is classified once, in this
order: a file copy (`public.file-url`) takes the drop path; an image with no text takes the
clipboard-image path and then a paste key; plain text keeps today's `text` frame.

**V1, an image.** The Mac sends the image as `clip.image.*` with `"paste":true` — a person's ⌘V
is explicit like a drop, so the phone applies it even while "Share clipboard with your phone" is
off (A1; the switch governs the background sync). The phone writes one URI-only clipboard
item (the image's URI, no text; A2) and answers
`{"t":"clip.image.done","id":N,"ok":true}` (PROTOCOL.md
"Clipboard images"); only then does the Mac send one `KEY` frame with keycode 279
(`KEYCODE_PASTE`) and `metaState` 0 to the window's stream. The wait is 3 s; a refusal, a
disconnect or the timeout sends no key and shows "Nothing pasted."

The paste key comes from AOSP, read on 2026-11-03: `TextView.onKeyDown` handles
`case KeyEvent.KEYCODE_PASTE` when `event.hasNoModifiers()` and calls
`onTextContextMenuItem(ID_PASTE)` (`core/java/android/widget/TextView.java`). Ctrl+V is also
handled: `TextView.onKeyShortcut` handles `META_CTRL_ON` + `KEYCODE_V`, and
`ViewRootImpl.ViewPostImeInputStage` turns a modified key into a shortcut event. `KEYCODE_PASTE`
is the direct one, needs no modifiers, and `AndroidInjector.pasteViaClipboard` already injects
it at shell UID for non-ASCII typing. Known unknowns for the real-phone spike: a Compose field
and a WebView do not use `TextView.onKeyDown`, an app may swallow the key, and the focused field
may not be the one the person means. `[NEEDS CLARIFICATION]` per app, as above.

The phone cannot see a field refuse the image, so the fallback is the person's own action: after
the key the Mac shows a 5 s pill, "Image pasted. Nothing there?"; a refusal or a
timeout says "Nothing pasted." Both have a button whose help tag and VoiceOver
label name ⇧⌘V. ⇧⌘V writes the same image to a temp PNG and sends it through the drop path to
the window's app, so the app receives it as a shared attachment.

**V2, files.** A file copy, or a drop of files, on an app's window transfers each file through
the existing `drop.*` path (one at a time, 200 MiB) and names the window's package in a new
optional `drop.start.target` field, with the file's place in the gesture in `index`/`count`
(A3). `AppWindowController.pkg` is the source (the phone's `window.title.pkg` is what named the
window). `WindowManager.onFilesDropped` and `ConnectionController.dropFiles` grow a target
argument; the Deck, a phone-mode window and a link window pass none. On the phone
`android/app/src/main/java/dev/pocketdeck/server/ShellLanding.kt` collects a gesture's finished
files in `ShareBatch` and offers one SEND after the last one: `ACTION_SEND` for one file,
`ACTION_SEND_MULTIPLE` for 2–5, each with `FLAG_GRANT_READ_URI_PERMISSION` and the same
`ClipData`; over 5 files are saved but never shared. It adds `--esa names`, `--esa mimes` and
`--es target <pkg>` to the `am start` of
`android/app/src/main/java/dev/pocketdeck/drop/ShareTrampoline.kt`; its `offer` builds the SEND,
calls `setPackage(pkg)`, and shows the intent only when `resolveActivity` returns a component for
it; otherwise it clears the package and shows today's chooser. No paste key is sent for files.

**V3, sources.** `VideoLayerView.registerForDraggedTypes` gains `.URL`, the image types
(`public.png`, `public.tiff`, `public.jpeg`, `public.image`) and
`NSFilePromiseReceiver.readableDraggedTypes`; the Deck's `.dropDestination(for: URL.self)` is
replaced by a drop view that reads the same sources (SwiftUI's URL-only destination cannot see
image data or promises). Each source becomes a temp file for the drop path:

- image data: the first `NSImage` is encoded as PNG (the existing `NSImage.pngData()`);
- an `http(s)` URL: `URLSession` download, stop at 8 MiB or 10 s; an image answer becomes the temp
  file, and a non-image answer is refused on a window with "That link isn't an image. Drop the
  link itself to open it." (on the Deck it keeps SHARE-8/11's link route);
- a file promise: `NSFilePromiseReceiver.receivePromisedFiles` into the same temp folder,
  awaited up to 30 s.

Temp files live in `FileManager.default.temporaryDirectory/PocketDeck-drop-<uuid>/`, one folder
per gesture. The folder is deleted when every file of that gesture has its `drop.result`, on a
cancel, and on session end; folders older than 24 h are swept at launch. Nothing about a file's
name or path is logged.

Visual items for prototypes: the drop target's highlight for the new types, the refusal line
for a non-image URL, and the paste pills (A4: the existing glass pill component with new copy and
one button — "Pasting…", "Image pasted. Nothing there?", "Nothing pasted." — light and dark,
Reduce Motion and Reduce Transparency; the six captures are in
`.agent/paste-drop/`).

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
