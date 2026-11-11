# Share phone → Mac ("Send to Mac")

In any Android app, Share → **Send to Mac** sends the item to the connected Mac: a link
opens in the Mac's default browser, other text lands on the Mac clipboard, an image is
saved to `~/Downloads/Contigua/` and put on the clipboard.

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

## Reading the clipboard (SHARE-19)

AOSP's `ClipboardService.getPrimaryClip` runs `addActiveOwnerLocked(intendingUid, …,
pkg)`: when the caller's UID does not own `pkg`, the service logs `Could not grant
permission to primary clip. Clearing clipboard.`, **sets the primary clip to null** and
returns null. `setPrimaryClip` has no owner check, and `getPrimaryClipDescription` has
none either. The shell server therefore never reads from a UID that would fail the
check (ISS-27).

One pure policy decides a read (`ClipReader.kt`), from the process UID and whether the
helper is ready:

| Process UID | Helper | Reader | Effect |
|---|---|---|---|
| 2000 (`com.android.shell`) | any | `Direct` | reads the hidden `IClipboard` directly |
| 0 (with root privileges) | ready | `Helper` | asks the helper, which runs at UID 2000 |
| 0 (with root privileges) | not ready or absent | `Off("uid 0, no helper")` | never calls `getPrimaryClip`; one log line names the uid and the missing helper |
| any other | any | `Off(reason)` | the same: no read, one line with the reason |

`ShellClipboard`, the image poll (`Session.clipImageLoop`) and `AndroidInjector`'s
save/restore around a non-ASCII paste all take reads through it; on `Helper` or `Off`
nothing in the server process calls `getPrimaryClip`. Writes are safe at any UID and
still go through `setPrimaryClip`.

Images are probed first: `getPrimaryClipDescription` is safe at every UID, and no
`image/*` MIME means no image read. That also keeps a text clip away from
`getPrimaryClip` at UID 2000, halving the poll's reads.

The listener is a change signal, not a read. `Session` calls `getText()` only while the
Mac's clipboard gate is on (`clip.enable`, SHARE-13), and `clipImageLoop` checks the
same gate before any probe.

### The helper

- Started only when the server's UID is 0. Two `su` forms are tried in this order:
  1. `su 2000 -c '<cmd>'` — a root manager's syntax, and the one used before the second
     form existed, so a device where it works starts exactly as it did;
  2. `su 2000 sh -c '<cmd>'` — AOSP's userdebug `su` is `su [WHO [COMMAND...]]` and has
     no `-c` of its own, so it runs the command through `sh` instead.

  The command is `CLASSPATH=<apk path> exec app_process /system/bin
  app.contigua.server.ClipHelperMain`, with the APK path the watchdog already uses
  (`appApkPath`).
- One explicit machine, `Off → Starting → Ready → Failed(reason)`. A death before ready
  tries the next form at once and spends no restart; when every form has died the state
  is `Failed("no su form")` and reads stay off. The form that reached ready is the one
  every later restart uses: at most three, with 500 ms, 1 s and 2 s backoff, then
  `Failed`. A death after at least a minute of ready is a healthy run: the count starts
  over, so a helper that dies once a day no longer ends the sync for the session. The
  healthy time runs from the accepted `ready` frame on a monotonic clock; a debug build
  may shorten the minute through a system property for one test boot, and shipped builds
  always keep it. `Stop` kills it and returns to `Off`; every transition is logged with
  its form. A missing or refused `su` ends in `Failed`, and the reader policy is
  `Off("no helper")` — never a crash.
- It registers the real shell user's primary-clip listener at startup, then answers
  requests on stdin/stdout: `[length][type][id][payload]`, binary-safe for images up to
  the existing 8 MiB cap, with `text`, `image`, `text reply`, `image reply`, `changed`
  and `ready` types. It sends `changed` events; it sends no clip unless asked.
- It exits on stdin EOF, so it dies with the server; `stop` closes stdin and only
  destroys the process as a guard.
- It is stopped with the clipboard sync, which the session ends.
- Privacy: frames carry clip text and bytes only between two local processes. Logs carry
  lengths, codes and counts, never text or bytes; the helper's stderr is drained and
  reduced to a line count plus fatal/exception/error counts.

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
  `file:`, `javascript:`, `contigua:`, `intent:`, custom schemes, two URLs — goes to the
  clipboard as text. Same URL syntax rules as `LinkPolicy` (≤ 8 KiB, no whitespace/control).
- Clipboard writes from a share are recorded in the clipboard sync's hash first, so they are
  not echoed back as `clip.set`. Notification: "Copied from <phone name>".
- Files: `mime` must be `image/*`; ≤ 50 MiB (52 428 800 bytes), counted while receiving —
  over the cap or a SHA-256 mismatch deletes the partial file. Data goes to a hidden temp
  file in the target folder and is renamed on success. Name: the phone's name reduced to
  `[A-Za-z0-9 ._-]`, no leading dot, ≤ 100 chars, extension from the MIME type if missing;
  an existing name gets " 2", " 3"… before the extension. The image goes on the pasteboard
  as a file URL plus image data; notification "Image from <phone>" with "Show in Finder".
- Folder: `~/Downloads/Contigua/` (created on demand); `--share-dir DIR` overrides it.
  `--share-log FILE` records "would open <url>" / notifications instead of acting (e2e).

## "Open on Mac": text menu and Open with
Two `activity-alias`es of `ShareActivity` labelled "Open on Mac" (the share sheet keeps "Send to
Mac"); both send through the same `share.text` pipeline, so the Mac classifies as above.
- `OpenOnMacText` (`PROCESS_TEXT`, `text/plain`): reads `EXTRA_PROCESS_TEXT` only, same rules as
  shared text; never calls `setResult`, so the source text is never replaced.
- `OpenOnMacLink` (`VIEW` + `BROWSABLE` + `DEFAULT`, schemes http/https, no host): shows up in
  Open with and in Settings → Default browser. The data URI must pass `LinkPolicy` (≤ 8 KiB) and
  be http/https, else the activity finishes silently.
- Both are exported, so the intent is untrusted: the activity dispatches on the alias name, reads
  only that string extra / data URI, and never opens streams.
- No `autoVerify`, no host: we never claim a domain, we're just one more browser choice.
- Loop guard: if the user makes Contigua the default browser, a Mac → phone `link.open` must not
  come back. `AndroidLauncher.view` resolves the handlers itself and `LoopGuard.pick` drops our
  package and the resolver, keeping the default when it's another app (`MATCH_ALL`: a default browser otherwise hides the rest); the launch (binder or
  `am start -n`) is always explicit. Only us → `view` fails and the Mac gets the usual error.

## Alternatives rejected
- Image bytes in AIDL / JSON base64: binder transactions cap at ~1 MB; base64 hits the 8 MiB
  frame cap and inflates 33 %.
- A share target that talks TCP to the Mac itself: a second connection the server would
  answer with `busy`, and auth keys live in the shell process.
- Reading the content URI in the shell process: needs a URI grant for UID 2000.
- Phone-side classification (`share.url`): the Mac would have to re-check anyway.
- Opening any `LinkPolicy` scheme (`tel:`, `mailto:`, `geo:`) on the Mac: only web links
  are wanted; anything else becomes text.
