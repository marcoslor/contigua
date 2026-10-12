# PocketDeck wire protocol — v1

The single source of truth for Mac ⇄ phone traffic. Both sides MUST implement
exactly this. Change it here first, then in code.

## Transport

- **LAN only.** The phone listens on TCP (ephemeral port) and advertises it
  over mDNS/DNS-SD as service type `_pocketdeck._tcp.` with TXT records:
  `v=1`, `id=<deviceId>` (stable random hex, 16 chars), `name=<device name>`,
  `model=<Build.MODEL>`.
- The Mac connects **one TCP connection per phone** (the "session"). Everything
  — control, input and every video stream — is multiplexed on it.
- Both ends set `TCP_NODELAY`. Byte order is **big-endian** everywhere.
- (v1 is plaintext + HMAC auth. TLS is a later milestone; keep framing
  transport-agnostic.)

## Framing

Every message is one frame:

```
u32 len        // number of bytes that follow this field (type + stream + payload)
u8  type
u32 stream     // 0 = session-level; otherwise a window stream id chosen by the Mac
u8[len-5] payload
```

Max frame size 8 MiB; a receiver that sees a larger `len` closes the session.

| type | name | dir | payload |
|---|---|---|---|
| `0x01` | JSON | both | UTF-8 JSON object, always has string field `"t"` |
| `0x02` | VIDEO_CONFIG | phone→mac | `u8 codec` (1 = H.264) · `u16 width` · `u16 height` · Annex-B SPS+PPS bytes |
| `0x03` | VIDEO_FRAME | phone→mac | `u64 ptsUs` · `u8 flags` (bit0 = keyframe) · Annex-B access unit |
| `0x10` | TOUCH | mac→phone | `u8 action` (0 down, 1 up, 2 move, 3 cancel) · `u8 pointerId` · `f32 nx` · `f32 ny` |
| `0x11` | SCROLL | mac→phone | `f32 nx` · `f32 ny` · `f32 hscroll` · `f32 vscroll` (Android axis units, + = up/left content move like a mouse wheel) |
| `0x12` | KEY | mac→phone | `u8 action` (0 down, 1 up) · `u32 keycode` (Android `KEYCODE_*`) · `u32 metaState` |

`nx`,`ny` are normalized `[0,1]` in the stream's video coordinates (top-left
origin). The phone maps them to the stream's current virtual display size.
Input frames carry the window's `stream` id; the phone stamps the matching
display id on every injected event.

`f32` = IEEE-754 single, big-endian.

### Video rules

- A stream starts with VIDEO_CONFIG, then VIDEO_FRAMEs, first one a keyframe.
- On resize the phone sends a **new VIDEO_CONFIG** (new size) followed by a
  keyframe. The Mac must rebuild its format description on every CONFIG.
- No frames are sent while the display content is static (that's normal).
- Backpressure: the phone never queues more than ~250 ms of video per stream.
  If the socket can't keep up it drops non-key frames for that stream until the
  next keyframe, and requests one from the encoder (`PARAMETER_KEY_REQUEST_SYNC_FRAME`).
  JSON and frames for other streams are never blocked behind a stalled stream's
  backlog (send-queue priority: JSON > keyframes/config > delta frames).

## Session handshake

1. Mac → `{"t":"hello","v":1,"clientId":"<uuid>","name":"<Mac name>"}`
2. Phone → `{"t":"challenge","nonce":"<32 hex>"}`
3. Paired Mac → `{"t":"auth","mac":"<hex HMAC-SHA256(key, nonce)>"}`;
   unpaired Mac → `{"t":"pair.request"}` (see Pairing).
4. Phone → `{"t":"welcome","device":{"id":..,"name":..,"model":..,"sdk":36,
   "screen":{"w":1080,"h":2340,"dpi":450},"locked":true}}` or
   `{"t":"error","code":"auth_failed"}` and closes.

Nothing but hello/challenge/auth/pair.* is accepted before `welcome`.

## Pairing (first contact)

1. Mac → `{"t":"pair.request"}`.
2. Phone generates a 6-digit code, shows it in an Android notification/dialog
   ("Allow <Mac name> to connect? Code 123456" + Allow/Deny). Phone →
   `{"t":"pair.code_shown"}`.
3. User types the code on the Mac. Mac → `{"t":"pair.confirm","code":"123456"}`.
4. If the code matches **and** the user tapped Allow, phone generates a random
   32-byte key, stores `{clientId, name, key}`, and replies
   `{"t":"pair.ok","key":"<64 hex>"}` followed by `welcome`. Mac stores the key in
   the Keychain under the device id. Otherwise `{"t":"error","code":"pair_denied"}`.
5. 3 wrong codes → `pair_denied` and the pending request is discarded.

## JSON messages

Mac → phone (after `welcome`):

| t | fields | meaning |
|---|---|---|
| `ping` | `ts` | phone replies `pong` with same `ts` |
| `apps.list` | — | phone replies `apps` |
| `apps.icon` | `pkg` | phone replies `icon` |
| `window.open` | `stream`, `w`, `h`, `dpi`, and `pkg` (+ optional `activity`) **or** `"mode":"phone"` | create VD + encoder, launch app (or the PocketDeck launcher for phone mode) on it |
| `window.resize` | `stream`, `w`, `h`, `dpi` | resize VD + reconfigure encoder; phone sends new VIDEO_CONFIG |
| `window.close` | `stream` | tear down that VD/encoder |
| `window.pause` | `stream` | Mac window hidden/minimized/occluded: stop encoding (keep VD + app alive) |
| `window.resume` | `stream` | resume; phone sends CONFIG + keyframe |
| `window.keyframe` | `stream` | request IDR (decoder error recovery) |
| `window.launch` | `stream`, `pkg` (+`activity`) | launch an app onto an existing window's display (phone mode) |
| `nav` | `stream`, `action`: `back`/`home`/`recents` | back = KEYCODE_BACK on that display; home/recents meaningful in phone mode |
| `text` | `stream`, `text` | type text into the focused field of that display |
| `clipboard.set` | `text` | (optional in v0) |

Phone → Mac:

| t | fields |
|---|---|
| `pong` | `ts` |
| `apps` | `apps`: `[{"pkg","label","activity"}]` — launchable activities, sorted by label |
| `icon` | `pkg`, `png` (base64, 96×96 px) |
| `window.opened` | `stream`, `displayId`, `w`, `h` |
| `window.closed` | `stream`, `reason` (`requested`/`app_exited`/`error`) |
| `window.title` | `stream`, `label`, `pkg` — top app changed on that display (phone mode) |
| `state` | `locked`: bool, `battery`: int, `charging`: bool — sent on change |
| `error` | `code`, `message`, optional `stream` |

Unknown `t` values are ignored (log once). Unknown fields are ignored.

## Versioning

`v` in hello + mDNS TXT. A phone that can't serve the Mac's `v` replies
`{"t":"error","code":"version"}` and closes.
