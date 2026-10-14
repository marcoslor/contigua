# Share phone → Mac ("Send to Mac")

In any Android app, Share → **Send to Mac** sends the item to the connected Mac: a link
opens in the Mac's default browser, other text lands on the Mac clipboard, an image is
saved to `~/Downloads/PocketDeck/` and put on the clipboard.

## Phone: share target → session
- `app/ShareActivity`: exported, `Theme.NoDisplay`, no history. Filters: `SEND` text/plain
  and image/*, `SEND_MULTIPLE` image/*. It parses the intent (`ShareIntent`), opens the
  image streams **before** `finish()` (the URI grant belongs to the activity), finishes in
  `onCreate` and hands the work to a background thread in the app process.
- The session lives in the shell process, so the app reaches it the way it already does
  for battery/lock state: the Shizuku user-service AIDL (`ShizukuClient.ensureBound`).
  New calls: `int shareText(String)` and `int shareFile(String name, String mime,
  ParcelFileDescriptor)`. An image is pumped through a pipe (`ParcelFileDescriptor.createPipe`),
  so any content provider works and the shell never needs a URI grant. Both calls are
  synchronous and return a status: `OK`, `NO_SESSION`, `TOO_LARGE`, `FAILED`.
- No Shizuku binding, no server or no ready session → toast "No Mac connected". Nothing
  is queued for later. Other results: "Sent to Mac", "Too large to send", "Couldn't send".
- Several Macs: the server serves one session at a time (a second Mac gets `busy`), so the
  most recently active Mac is the connected one. If that ever changes, `Server.share`
  must pick the session with the latest inbound frame.
- Multiple images (`SEND_MULTIPLE`): up to 10, sent one after another as separate files.

## Protocol (phone → Mac)
- `{"t":"share.text","text":"..."}`: UTF-8, ≤ 1 MiB, not empty. The phone does not label it:
  the Mac decides link vs text.
- `{"t":"share.file","id":N,"name":"IMG_1.jpg","mime":"image/jpeg"}`, then `SHARE_DATA`
  (`0x21`, `stream` = `id`) frames of ≤ 1 MiB, then `{"t":"share.end","id":N,"size":..,
  "sha256":"<64 hex>"}`, or `{"t":"share.abort","id":N}` if the phone gave up (read error,
  over the cap). One file at a time; a new `share.file` abandons an unfinished one.
- All of a file's frames (its JSON too, so nothing overtakes the data) use the lowest send
  priority, after video deltas, and the producer blocks while 1 MiB is queued: a 50 MB image
  never sits in memory and never delays replies or keyframes.

## Mac: validation (the Mac never trusts the phone)
- Text: trimmed; if it is exactly one `http`/`https` URL with a host, or contains exactly one
  such URL among other words, that URL is opened with `NSWorkspace.open`. Everything else —
  `file:`, `javascript:`, `pocketdeck:`, `intent:`, custom schemes, two URLs — goes to the
  clipboard as text. Same URL syntax rules as `LinkPolicy` (≤ 8 KiB, no whitespace/control).
- Clipboard writes from a share are recorded in the clipboard sync's hash first, so they are
  not echoed back as `clip.set`. Notification: "Copied from <phone name>".
- Files: `mime` must be `image/*`; ≤ 50 MiB (52 428 800 bytes), counted while receiving —
  over the cap or a SHA-256 mismatch deletes the partial file. Data goes to a hidden temp
  file in the target folder and is renamed on success. Name: the phone's name reduced to
  `[A-Za-z0-9 ._-]`, no leading dot, ≤ 100 chars, extension from the MIME type if missing;
  an existing name gets " 2", " 3"… before the extension. The image goes on the pasteboard
  as a file URL plus image data; notification "Image from <phone>" with "Show in Finder".
- Folder: `~/Downloads/PocketDeck/` (created on demand); `--share-dir DIR` overrides it.
  `--share-log FILE` records "would open <url>" / notifications instead of acting (e2e).

## Alternatives rejected
- Image bytes in AIDL / JSON base64: binder transactions cap at ~1 MB; base64 hits the 8 MiB
  frame cap and inflates 33 %.
- A share target that talks TCP to the Mac itself: a second connection the server would
  answer with `busy`, and auth keys live in the shell process.
- Reading the content URI in the shell process: needs a URI grant for UID 2000.
- Phone-side classification (`share.url`): the Mac would have to re-check anyway.
- Opening any `LinkPolicy` scheme (`tel:`, `mailto:`, `geo:`) on the Mac: only web links
  are wanted; anything else becomes text.
