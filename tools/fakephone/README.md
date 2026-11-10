# fakephone — fake PocketDeck phone + conformance client

A protocol-faithful test harness for [docs/PROTOCOL.md](../../docs/PROTOCOL.md)
v4 (TLS 1.3 client certificates, pins, reliable paths). Python 3.11+ for the TLS parts (3.9's
LibreSSL cannot do TLS 1.3), plus `ffmpeg`/`ffprobe` and the macOS `dns-sd` CLI.

- `proto.py` — the frame codec (JSON, VIDEO_CONFIG, VIDEO_FRAME, TOUCH, SCROLL,
  KEY), the HMAC auth helper, and Annex-B helpers (NAL/access-unit splitting,
  SPS/PPS extraction, IDR detection).
- `fakephone.py` — the fake phone server: mDNS advertising, pairing, every
  phone→mac message, and one ffmpeg H.264 (or `--codec hevc` HEVC) encoder per
  window stream.
- `deckctl.py` — the fake Mac client, used to conformance-test any phone server
  (this fake today, the Android server later).
- `paths.py` — the paths core: RELIABLE/ACK, the replay buffer with credit,
  the reorder window, pings and the switch marker.
- `test_selfcheck.sh` — end-to-end check of all of the above.
- `test_busy_reject.py` — unit check of one connection path the selfcheck only
  reaches at its end: a rejected second connection (TLS-wrapped, stale) must
  close quietly.

## Requirements

A Python with TLS 1.3 — Python 3.11+ against OpenSSL 3 (`/opt/homebrew/bin/python3`),
or set `PD_FAKE_TLS_PYTHON`. The macOS system `/usr/bin/python3` (3.9.6) links
LibreSSL 2.8, which has no TLS 1.3, so it cannot talk to the v2 server. Also
`ffmpeg`/`ffprobe` (tested with Homebrew 8.0). `dns-sd` ships with macOS at
`/usr/bin/dns-sd`.

## Run the self-check

```sh
bash tools/fakephone/test_selfcheck.sh   # prints SELFCHECK PASS, exit 0
```

The connection paths have a small unit check of their own (a second, rejected
connection over TLS, with a client that stalls on it):

```sh
python3.11 tools/fakephone/test_busy_reject.py   # prints OK, exit 0
```

The window stream encoder's state machine (the `--stall-after`/`--stall-for`
rig, ISS-46) has its own:

```sh
python3.11 tools/fakephone/test_encoder_state.py   # prints OK, exit 0
```

The HEVC arm's wire helpers (NAL types, VPS/SPS/PPS, IDR/CRA, access-unit cuts,
and the codec choice against the Mac's `hello.codecs`) have their own:

```sh
python3.11 tools/fakephone/test_hevc.py   # prints OK, exit 0
```

The path socket's kernel-queue cap (the real phone's `TCP_NOTSENT_LOWAT`, 16 KiB
at Linux option 25) has its own; it also pins that a kernel without the option
returns an errno instead of failing:

```sh
python3.11 tools/fakephone/test_notsent_lowat.py   # prints OK, exit 0
```

It starts `fakephone` on an ephemeral port (`--no-mdns --auto-allow`), pairs with
`deckctl`, runs `apps`, `icon`, `open`, `resize-test`, `input-test`,
`pause-test`, `latency`, checks that a second simultaneous session is rejected
with `busy`, validates the recorded file with `ffprobe`, asserts the event log
contains a session `open`/`auth_ok`, a touch down+up and VIDEO_CONFIGs at each
size, and confirms no ffmpeg/dns-sd process survives shutdown.

## fakephone

```sh
python3 tools/fakephone/fakephone.py            # mDNS on, random port, prompts y/n to pair
python3 tools/fakephone/fakephone.py --no-mdns --auto-allow \
    --port 47811 --state /tmp/fh.json --events /tmp/ev.jsonl
```

Paths (docs/PROTOCOL.md "Paths"): `--paths N` opens N listeners (`PORT`,
`PORT+1`, …) so a Mac can join a second path and switch to it; `--version N`
speaks protocol N (default 4; `3` refuses a v4 Mac with `error version`);
`--join ID` fixes/serves only that 32-hex session id; `--no-pong PATH`,
`--slow-pong PATH MS` and `--drop-path PATH after S` break one path by its
8-hex id or its join order (or `all`); `--ctl-file F` does the same at run
time (`pong ID on|off|delay [MS]`, `slow ID MS`, `drop ID`).

Options: `--port` (0 = ephemeral), `--name` (mDNS instance), `--no-mdns`,
`--auto-allow` (with `--allow-delay SECONDS` to act like a person comparing codes), `--state` (default `~/.pocketdeck-fakephone.json`),
`--events` (JSON Lines log, flushed per line), `--no-labels` (skip the stream
label overlay), `--image-frame PATH` (encode that still picture in every
stream, cover-cropped to the stream's size and with no label: a visual
fixture), `--resize-delay-ms MS` (hold a window's new VIDEO_CONFIG that long
after `window.resize`, so a Mac can be checked mid-resize), `--config-every
SECONDS` (re-send the stream's last VIDEO_CONFIG every N seconds without
restarting the encoder: the real phone's config on a resume, followed by deltas
against the pre-config chain), `--demo-apps N` (pads the app list to N apps for grid screenshots;
`--no-icon-every K` leaves every K-th one without an icon, answered with an empty
`png` like the real phone), `--qr-uri URI` (simulates a QR scan: registers the client id and
key from a `pocketdeck://pair?c=&n=&k=` URI as paired, so the next `auth`
succeeds without any `pair.request`). The pairing code is sent in `pair.code_shown`
and printed to the terminal; Allow (`--auto-allow` or the y/n prompt) is the only
step, there is no `pair.confirm`. Paired clients are persisted, so a second
connection authenticates with its key instead of pairing again. A second
simultaneous session is answered with `{"t":"error","code":"busy"}`; the first
keeps working. Ctrl-C kills every ffmpeg/dns-sd child.

Deeper media (docs/design/notify.md "Media part 2"): `--media` serves two
playing apps with generated artwork, a seekable position and an absolute volume
(`media.sessions`, `media.state` with `key`/`canSeek`/`volume`, `media.art`);
`media.command seek|volume` moves the fake and the next `media.state` confirms,
and `media.choose` switches the chosen app. `--older-phone` sends today's
`media.state` only (no sessions, no artwork, no new fields), which is how the
e2e checks that an older phone keeps today's behaviour. `deckctl media watch|seek|volume|choose` drives it, and `deckctl media drive`
(one session: seek, volume and choose 3 s apart) is what the emulator script
uses, because the phone allows a single session; the event log records action names, keys,
positions, levels and artwork dimensions/bytes only.

Do Not Disturb (docs/design/focus.md): `state` carries `dnd` and `phone.dnd`
sets the fake's zen mode with the phone's restore rule (`--dnd-person MODE`
starts in a mode the person set, which must survive; `--dnd-person-after
SECONDS` [and `--dnd-person-mode MODE`, default `off`] turns it off again that
long after a Mac command, as the person would; `--dnd-unsupported` acts like a
build that predates both). `--drop-after SECONDS` drops the first session that
long after its welcome (a Wi-Fi loss) while the fake keeps serving and keeps
its memory, so the Mac reconnects to the same phone.

Screens and streams: `welcome` reports a 1080x2340 @450dpi locked phone. Each
`window.open`/`resize`/`resume`/`keyframe` starts an ffmpeg
`testsrc2` (phone mode: `smptehdbars`) encoder at 60 fps, H.264 High, and sends
VIDEO_CONFIG (SPS+PPS) then VIDEO_FRAMEs (bit0 set on IDR). Sizes are rounded
down to a multiple of 16. Deltas are dropped past ~250 ms of backlog per stream
(JSON > config/key > delta). A phone that cannot capture display 0 answers a
phone-mode `window.open` with `{"t":"error","code":"mirror_unavailable"}`
(`--mirror-unavailable`), sending no `window.opened` and no frames.

### The window stream encoder's states

A stream's encoder is one explicit state machine (`encoder_transition` in
`fakephone.py`), not a pause flag. `--stall-after` stops the encoder because
the phone's picture froze; that is `Stalled`, and it is not something a request
from the Mac can undo.

| state | what the encoder is doing | leaves on |
| --- | --- | --- |
| `Idle` | the window exists, no encoder yet | `start` → `Running`; `hold` → `Held` |
| `Held` | `--first-frame-delay` holds frame one | the first-frame timer → `Running`; `pause` → `Paused`; `stop` → `Stopped` |
| `Running` | ffmpeg is encoding and frames flow | `start` (restart); `pause`/`stall` → `Paused`/`Stalled`; `stop` → `Stopped` |
| `Paused` | stopped by `window.pause` or the screen going off | `start` → `Running` (except a cleared backlog's `start(False)`); `stop` → `Stopped` |
| `Stalled` | stopped by `--stall-after`, session still up | only `--stall-for` → `Running`, or `stop` → `Stopped` |
| `Stopped` | the window closed | nothing (terminal) |

Every `start` cause (open, resize, resume, keyframe, rotate, adopt, continue,
black, screen-on, backlog cleared, and a path switch) is one `Start` event.
While `Stalled`, every one of them is ignored: a stalled encoder does not come
back because it was asked. Each ignored request still counts where it counts
(the keyframe counter), and prints one line to stderr:

```
fakephone: stream N <cause> ignored (stalled)
```

Transitions print to stderr as well, so a field log shows the path:

```
fakephone: stream N encoder <from> --<event>--> <to>
```

### Event log (`--events`)

One JSON object per line, exactly:

```
{"ev":"session","state":"open"|"auth_ok"|"paired"|"closed","ts":<float>}
{"ev":"rx","msg":{...},"ts":<float>}
{"ev":"input","kind":"touch","stream":N,"action":0..3,"pointer":N,"nx":f,"ny":f,"ts":..}
{"ev":"input","kind":"scroll","stream":N,"nx":f,"ny":f,"h":f,"v":f,"ts":..}
{"ev":"input","kind":"key","stream":N,"action":0|1,"keycode":N,"meta":N,"ts":..}
{"ev":"video","stream":N,"config":true,"w":W,"h":H,"ts":..}
{"ev":"quality","stream":N,"bitrate":N|null,"maxFps":N|null,"ts":..}
{"ev":"link","stream":N,"url":"...","ts":..}
{"ev":"share","kind":"text"|"image","value":"<text or path>","size":N,"sha256":"..","ts":..}  (--share text:<text> / image:<path>, sent after welcome like Share → Send to Mac)
{"ev":"apk","id":N,"files":[{"name","size","sha256","match"}],"ok":bool,"code":..,"ts":..}  (acts like pm; a part containing PD_FAKE_DOWNGRADE fails with INSTALL_FAILED_VERSION_DOWNGRADE)
```

## pdpathfault

`tools/pdpathfault/pdpathfault.py` is a TCP proxy in front of one path
listener for the e2e checks. `--mode pass|delay|blackhole|rst|throttle`
(`--delay-ms`, `--rate-mbit`) can be changed at run time by writing
`mode blackhole` to `--ctl-file`; each connection and mode change is a JSON
line on `--events`. It does not terminate TLS.

## deckctl

```sh
# directly:
python3 tools/fakephone/deckctl.py --host 127.0.0.1 --port 47811 apps
# or over mDNS (pair once with --pair, then the stored key is reused):
python3 tools/fakephone/deckctl.py --discover apps
```

`--state` (default `~/.pocketdeck-deckctl.json`) stores the client id and per-device
keys; `--pair` pairs on first contact: it prints the code the phone shows (`--code-file F`
also writes it to `F`) and waits for Allow on the phone.
Subcommands:

- `version` — print `hello.v`, the session id and this path's id.
- `paths` — list the phone's live paths (`*current*` marks the sending one).
- `switch PATH` — send `path.switch` and wait for the phone's own marker
  (`current` names this client's path).
- `kill-path PATH`, `pong-mode PATH on|off|delay [--ms N]` — fake-phone
  conformance hooks (a real phone ignores them).
- `apps` — list `pkg<TAB>label`.
- `icon PKG --out f.png` — fetch a 96x96 PNG.
- `open (PKG|--phone) --w --h --dpi --seconds N --out f.h264` — record raw
  Annex-B H.264 and print `fps= kbps= first_frame_ms=`.
- `probe (PKG|--phone) --w --h --steps "tap:NX,NY;text:STR;scroll:V;wait:S"` —
  open one window and record one phase file + PNG (`frame-png` on the last
  frame) per step.
- `multi --apps PKG1 PKG2 --w --h --resize1 WxH --resize2 WxH --steps ... --steps2 ...`
  — two windows in one session; a phase per step plus a phase after the
  resizes, each checked against its new VIDEO_CONFIG, recorded to `.h264` + PNG.
- `resize-test` — open, resize, require a new VIDEO_CONFIG and a keyframe after it.
- `input-test` — open, then send touch down/move/up, scroll, key down/up, nav back.
- `pause-test` — require no frames while paused and CONFIG + keyframe after resume.
- `exit-test PKG` — back out of the app; require `window.closed(app_exited)`.
- `frame-png FILE --out f.png [--at SECONDS]` — decode a frame of a recorded
  `.h264` (default: the last frame) without any session.
- `latency --count N` — ping round-trip p50/p95.
- `quality-test (PKG|--phone) --w --h [--quality-bps N] [--quality-fps N]
  [--stall S] [--stall-bps N] [--motion V] [--motion-mode scroll|drag]
  [--cap-seconds S --cap-fps N]` — open, then print per-phase frame counts,
  kbps and average frame size: `base` (untouched), `quality` (right after a
  `window.quality` message), `stall` (the socket is deliberately not read for
  `--stall` seconds, so the phone's send queue overflows; `--stall-bps` sets a
  higher target first, so the phone's own -25% is visible above its floor) and
  `recover`. `--motion V` injects motion to keep a static app drawing:
  `--motion-mode scroll` sends wheel bursts, `drag` a synthetic fling.
  `--cap-seconds`/`--cap-fps` end with an fps-cap phase.
- `watch-state --seconds N` — print every `state` message with its timestamp
  (and `dnd` when the phone reports it); lock/unlock the phone while it runs and
  count the lines (one per change).
- `dnd MODE` — send `phone.dnd` with `priority`/`alarms`/`none`/`off` and print
  the state the phone reports (docs/design/focus.md).

`--wait-for-free SECONDS` (any subcommand) retries while another client holds the
phone's single session; the default is to fail fast with `busy`.

Any protocol violation (wrong order, wrong size, a frame before CONFIG, a
non-keyframe first frame after CONFIG, an unknown frame type) exits non-zero
with a message on stderr.

## Notes on ffmpeg here

The installed ffmpeg has no `drawtext` filter, so the app-icon letter and the
per-stream `stream=<id> WxH` label are drawn with a small built-in 5x7 bitmap
font (`render_text_png`); the moving clock comes from `testsrc2` itself. If the
font cannot fit, the icon degrades to a plain colour block, as the task allows.
