# fakephone — fake PocketDeck phone + conformance client

A protocol-faithful test harness for [docs/PROTOCOL.md](../../docs/PROTOCOL.md)
v1. Python 3.9 stdlib only, plus `ffmpeg`/`ffprobe` and the macOS `dns-sd` CLI.

- `proto.py` — the frame codec (JSON, VIDEO_CONFIG, VIDEO_FRAME, TOUCH, SCROLL,
  KEY), the HMAC auth helper, and Annex-B helpers (NAL/access-unit splitting,
  SPS/PPS extraction, IDR detection).
- `fakephone.py` — the fake phone server: mDNS advertising, pairing, every
  phone→mac message, and one ffmpeg H.264 encoder per window stream.
- `deckctl.py` — the fake Mac client, used to conformance-test any phone server
  (this fake today, the Android server later).
- `test_selfcheck.sh` — end-to-end check of all of the above.

## Requirements

`/usr/bin/python3` (3.9.6) and `ffmpeg`/`ffprobe` (tested with Homebrew 8.0).
`dns-sd` ships with macOS at `/usr/bin/dns-sd`.

## Run the self-check

```sh
bash tools/fakephone/test_selfcheck.sh   # prints SELFCHECK PASS, exit 0
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

Options: `--port` (0 = ephemeral), `--name` (mDNS instance), `--no-mdns`,
`--auto-allow` (with `--allow-delay SECONDS` to act like a person comparing codes), `--state` (default `~/.pocketdeck-fakephone.json`),
`--events` (JSON Lines log, flushed per line), `--no-labels` (skip the stream
label overlay), `--demo-apps N` (pads the app list to N apps for grid screenshots;
`--no-icon-every K` leaves every K-th one without an icon, answered with an empty
`png` like the real phone), `--qr-uri URI` (simulates a QR scan: registers the client id and
key from a `pocketdeck://pair?c=&n=&k=` URI as paired, so the next `auth`
succeeds without any `pair.request`). The pairing code is sent in `pair.code_shown`
and printed to the terminal; Allow (`--auto-allow` or the y/n prompt) is the only
step, there is no `pair.confirm`. Paired clients are persisted, so a second
connection authenticates with its key instead of pairing again. A second
simultaneous session is answered with `{"t":"error","code":"busy"}`; the first
keeps working. Ctrl-C kills every ffmpeg/dns-sd child.

Screens and streams: `welcome` reports a 1080x2340 @450dpi locked phone. Each
`window.open`/`resize`/`resume`/`keyframe` starts an ffmpeg
`testsrc2` (phone mode: `smptehdbars`) encoder at 60 fps, H.264 High, and sends
VIDEO_CONFIG (SPS+PPS) then VIDEO_FRAMEs (bit0 set on IDR). Sizes are rounded
down to a multiple of 16. Deltas are dropped past ~250 ms of backlog per stream
(JSON > config/key > delta).

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
```

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
- `watch-state --seconds N` — print every `state` message with its timestamp;
  lock/unlock the phone while it runs and count the lines (one per change).

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
