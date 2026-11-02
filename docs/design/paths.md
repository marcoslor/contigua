# Paths — the session layer

Design for epic "direct link", phase P0. Implements decisions D1–D5 and D10 of
`.agent/direct-link/plan.md`; the providers themselves (D6–D9) are in
`docs/design/direct-link.md`. The wire is `docs/PROTOCOL.md` § "Paths"; the
requirements are `docs/specs/transport.md` (`PATH-n`).

Today one TCP connection **is** the session: `Session.swift` owns the NIO
channel, the TLS handshake, the framed reader/writer and the 15 s ping, and the
phone's `Server` hands one accepted socket to one `Session`. This document moves
that connection down one level (a *path*) and puts a *session* above it, so the
session outlives the loss and the replacement of its connection. It is part of
protocol version 4 and has no reduced mode: a peer on another version is refused
(§1.1).

## 1. The two layers

- **Path**: one TCP connection carrying today's TLS 1.3 (mutual, pinned, no
  resumption, no 0-RTT). Each path does its own full TLS handshake and its own
  certificate check. Nothing below TLS is trusted: the Mac's direct helper moves
  ciphertext and never sees a plaintext byte (D2).
- **Session**: the thing the person sees. It owns the reliable stream, the
  switch, and the phone's slot. A session has a 128-bit id, one or more paths,
  and lives until it ends on purpose or outlives its grace.

A path is added in one of two ways: it **starts** a session (a phone with no
session), or it **joins** one (a later path for the session the Mac already
has). Adding a path never creates a second session and never re-runs the
handshake's person-facing steps: TLS is the only authentication.

Session-level state that had one home on one connection keeps one home per
session: the seq/ack/replay stream, the switch, the ranking, the phone's slot.

### 1.1 One version, no second mode (D10)

This ships to two apps that update separately, and the answer is **not** a
negotiation: the protocol version moves with the session layer. `hello.v` is 4
(it was 3 before this epic), and a peer on another version gets
`{"t":"error","code":"version","v":<the refusing side's version>}` and a close,
exactly as today. There is no dual mode, no reduced transport, and no fallback
to the one-connection session: a v3 peer is refused, not served. The alpha's
rule is the reason (AGENTS.md — both apps ship together, and a protocol change
may require a field); naming the side is the reason the person sees "Update
PocketDeck on your phone." or "…on this Mac." instead of a session that
half-works.

So the session layer is always on in a v4 session. Nothing in this document has
a "when both sides can" clause.

`direct` is *not* negotiated either: it is a build flavour plus two switches.
A build without it has no provider to offer and no messages to send; a peer
that never offers a direct path is simply never asked to join one.

## 2. Who owns what

| Object | Side | Owns | Never does |
|---|---|---|---|
| `ConnectionController` | Mac | which phone is in use, the attempt planner, the provider list, the settings, the UI events | touch a socket |
| `Session` (one per phone) | Mac | the session id, the path set, seq/ack/replay, the session machine (§6), the ranking machine (§7), the one writer that picks the current path | dial TLS itself |
| `PathConnection` (one per path; today's transport half of `Session`) | Mac | the endpoint, the TLS handshake and pin check, the `FrameDecoder`, the per-path reader, the per-path 2 s ping | see a message before the path layer |
| `PathProvider` (`lan`, `direct`, `wan` later) | Mac | dialing a path to a phone (or a listener, for the phone's side), its throughput class, "is available" | see a plaintext byte |
| `DirectLinkd` (direct builds only) | Mac | the UNIX-socket client of `pocketdeck-directd` | see a plaintext byte |
| `Server` | phone | the LAN listener, the TLS wrap of every socket it is handed, the accept gate | keep a second session |
| `AwareAcceptor` (direct build, app process) | phone | attach, publish, the NDP, the Aware `ServerSocket`, `accept`, and the hand-off of each accepted socket to the shell (`docs/design/direct-link.md` §4.5) | see a frame, hold the key in the shell |
| `Session` | phone | the session id, the path set, the same path layer, the shell-side features (windows, files, notifications) | decide a switch |
| `SessionSlot` / `SessionDropper` | phone | who owns the phone: free, live, draining, handing (§4) | join a path |

Everything stays where it is today, process-wise: on the phone the LAN listener,
the TLS and the whole path layer live in the shell process (UID 2000) next to
the window streams. A direct build adds one thing on the app side: the Aware
listener (only the app may own an Aware network), which hands each accepted
socket to the shell as a descriptor; the shell runs the same TLS, the same slot
and the same path layer on it. Nothing about a path's content crosses AIDL, and
the app process still only pushes identity, pins and switches. On the Mac it all
lives on `Session`'s one serial queue (no new locks, no second actor).

## 3. Where seq / ack / replay sits

The **path layer** is a new, purely local layer between the frame codec and the
message dispatcher, identical on both ends:

```
writer:  sendJSON / sendData  ->  wrap(seq)  ->  current path .write
reader:  path .read -> FrameDecoder -> unwrap + dedupe + ack  ->  dispatcher
```

- Nothing above it changes: `dispatch` still sees the exact frame it sees
  today, with the same `type`, `stream` and payload bytes. Unwrapping a
  RELIABLE frame yields the identical inner frame.
- Nothing below it changes either: the codec keeps `u32 len · u8 type · u32
  stream · payload`, big-endian, 8 MiB cap, `TCP_NODELAY`.
- **One seq space per direction, for the whole session**, not per path and not
  per stream. Two directions number independently, both starting at 1.
- The receiver drops a duplicate by seq, so a frame that crossed a switch twice
  is delivered once, in order.
- **Acks are per session, not per path**: a cumulative ack says "I have your
  frames up to seq N" whichever path it arrives on; the sender keeps the higher
  of any ack it has seen.
- The replay buffer is per direction (`ReplayBuffer`, §8) and lives for the
  session, so a path that dies mid-file costs one round trip of resend, not the
  file.
- On the phone the writer is the session's existing single send queue, so
  priority rules (JSON > keyframes/config > audio > video deltas) survive: the
  wrapper is applied where the frame is queued, and a replay is queued at the
  head of JSON priority.

The 15 s app-level `ping`/`pong` stays exactly as it is (a session-level
keepalive). It is **not** the path health signal: that is `path.ping` (§5),
which runs every 2 s on every path, the standby included.

## 4. The phone's slot: join, adopt, busy

The phone owns one session at a time (`SessionSlot`). Today the slot decides at
**accept** time, from the peer's certificate alone: the same pinned Mac takes
the slot over (supersede → `Handing`), anyone else gets `busy`. A join cannot be
decided there: whether a connection is a new session or a new path depends on
its `hello`.

So `Server.serve` keeps its order up to the master gate, then reads exactly one
frame (the hello, still under the 10 s accept timeout) and passes it to the
slot. A v3 peer never gets this far: its `hello` fails the version check and it
is closed with `error version`, so the slot only ever sees a v4 `hello` — with a
`join` when the Mac is adding a path, without one when it is starting a session.

| Slot state | Event | Result |
|---|---|---|
| `Free` | `Connect(peer, samePinnedMac, join: nil)` | `ADOPT` — a new session (today) |
| `Free` | `Connect(peer, join: <id>)` | `NO_SESSION` — nothing to join; error `no_session`, close |
| `Live(mac, s)` | `Connect(peer, join: s.id)` and the pin matches | **`JOIN`** — attach the socket as one more path of `s`; the slot does not change; `s` answers `welcome` on it |
| `Live(mac, s)` | `Connect(peer, join: <other id>)` and the pin matches | `NO_SESSION` — the Mac's session is gone; it starts a new one |
| `Live(mac, s)` | `Connect(peer, join: nil)` and the pin matches | today's supersede: drop `s`, `Handing`, adopt when its teardown is done (≤ 2 s), else `BUSY` |
| `Live(mac, s)` | `Connect(peer, …)` from another Mac, or an unpinned peer | `BUSY` |
| `Draining` | `Connect(…, join: nil)` | today: `Handing`, wait ≤ 2 s, else `BUSY_SLOW` |
| `Draining` | `Connect(…, join: …)` | `NO_SESSION` — the session is over; nothing is joined |
| `Handing` | any `Connect` | `BUSY` |
| any | the live session's own end (`Ended`) | `Free` |

A connection from either listener reaches the slot the same way (the LAN
listener is the shell's; the direct build's Aware listener runs in the app
process and hands each accepted socket to the shell — `docs/design/direct-link.md`
§4). A session may be founded by either: a `Connect` with no `join` is
`ADOPT` whatever listener it came from.

`JOIN` details: the slot keeps the same session object and the same session id;
the new socket gets its own TLS check (already done), its own path id from the
`hello`, and is added to the session's path set. A join is refused when the
session already has its maximum number of paths (M-PATH = 3) with `error
"too_many_paths"`; a path that joins and never passes the first path ping is
dropped after 5 s.

`no_session` leaks one bit ("a session with that id is not here"). Only a peer
whose certificate is the live session's own pinned Mac ever hears it — every
other peer still gets `busy`, today's rule — so nothing new is learned by a
stranger.

## 5. The wire

All of this is in `docs/PROTOCOL.md` as well; that file is the contract and this
section explains it.

### 5.1 Ids and the version

- **Session id**: 32 lowercase hex characters (128 random bits), minted by the
  **phone** on a new session, in `welcome.session`. A join never mints one; it
  echoes the id it was asked for.
- **Path id**: 8 lowercase hex characters (32 random bits), chosen by the
  **Mac** per attempt, in `hello.path`; unique among the session's live paths.
  Every path is dialed by the Mac, so every path is named by the Mac.
- **Version**: `hello.v` is 4. A phone that does not serve 4 answers
  `{"t":"error","code":"version","v":4}` — its own version — and closes before
  it sends `welcome`; the Mac compares that with its own and says which app to
  update: a phone `v` below its own, or absent (a v3 phone sends none), means
  "Update PocketDeck on your phone."; above means "Update PocketDeck on this
  Mac.". It then stops retrying. The phone's screen names the Mac's side the
  same way from the `hello`'s `v`. A v4 Mac dialing a v3 phone gets the refusal
  from the phone's own check (a v3 phone refuses 4, with no `v`), and a v3 Mac
  dialing a v4 phone is refused the same way, so the rule is symmetric without
  either side trusting the other's claim.

### 5.2 `hello.path`, `hello.join`, `welcome.session`, `no_session`

- `hello` gains `"path":"<8 hex>"`, and — on every attempt after the session's
  first path — `"join":"<32 hex>"`. Its `v` becomes 4.
- `welcome` gains `"session":"<32 hex>"`: a new id on a first path, the asked-for
  id on a joining path.
- A join for an unknown or ended session answers `{"t":"error","code":
  "no_session"}` and closes; the Mac then drops that attempt and starts a new
  session (a plain `hello`, which the phone handles as a supersede or an
  adopt). A join whose `welcome.session` differs from the id it asked for is a
  mismatch: the Mac closes that path and logs `path join mismatch`, keeping the
  old session as it is.
- A phone that has no session (the slot is `Free`) answers `no_session` for a
  join even for a pinned Mac: there is nothing to attach to.

### 5.3 The two new frame types

The frame header is unchanged. Two types are added; existing layouts are
untouched.

**`0x30` RELIABLE** — one reliable frame, wrapped.

```
len      u32   = 5 + 8 + 1 + 4 + n   (= 18 + n)
type     u8    = 0x30
stream   u32   = innerStream          (the wrapper mirrors it, for routing)
payload:
  seq          u64      this direction's seq (starts at 1, +1 per reliable frame)
  innerType    u8       the wrapped frame's type (only a reliable type, §5.5)
  innerStream  u32      the wrapped frame's stream
  innerPayload u8[n]    the wrapped frame's payload, byte for byte
```

Max inner payload: 8 MiB − 18. Senders chunk anything larger (today's largest
single frame is a 1 MiB data frame or a base64 icon, both far below it).

**`0x31` ACK** — a cumulative acknowledgement.

```
len      u32   = 13
type     u8    = 0x31
stream   u32   = 0
payload:
  ack      u64   the next seq this side expects; every seq below it was received in order
```

Golden bytes (both are K1/K2 vectors):

```
ACK, ack = 42:
00 00 00 0d 31 00 00 00 00 00 00 00 00 00 00 00 2a

RELIABLE, seq = 7, stream 0, inner = JSON {"t":"clip.set","text":"hi"}:
00 00 00 2e 30 00 00 00 00
00 00 00 00 00 00 00 07
01 00 00 00 00
7b 22 74 22 3a 22 63 6c 69 70 2e 73 65 74 22 2c 22 74 65 78 74 22 3a 22 68 69 22 7d
```

Rules:

- A receiver that sees an unknown `innerType` acks it and drops it (today's
  rule for unknown types), so a new message type never stalls the stream.
- An ACK is sent at most every 10 ms and at least once per 16 received
  frames; the 10 ms timer flushes the tail of a burst by itself. Both are
  implementation constants, not decisions.
- Duplicates (`seq < expected`) are dropped and answered with an immediate ACK.
- Out-of-order frames (`seq > expected`) wait in a **reorder window** of 64
  frames / 4 MiB. When the window is full, a frame ahead of a gap that another
  path holds pauses that path's reader (TCP backpressure) rather than being
  dropped; a frame ahead of a gap on that same path's own stream does not pause
  its reader — it is held (at most one window) and retried when there is room,
  never dropped. Either way the sender's ack does not advance, so nothing is
  lost.
- A RELIABLE frame whose `stream` differs from `innerStream`, or that does
  not decode, is a protocol error: the session closes, with no path detach and
  no replay (the outer stream exists only for routing).

### 5.4 The path messages

Three JSON messages, session level, never wrapped (`path.ping`/`path.pong` are
bare so they never enter the seq space or the replay buffer: they measure one
path and mean nothing after a switch):

| t | fields | dir | meaning |
|---|---|---|---|
| `path.ping` | `path` (8 hex), `ts` (u64 ms, sender's monotonic clock) | both | sent on that path only: every 2 s with two or more paths while the phone's screen is on or a transfer runs, every 15 s otherwise, never with one path (D1) |
| `path.pong` | `path`, `ts` (echoed) | both | answered on the same path at once |
| `path.switch` | `path` (8 hex, the path being moved **to**), `seq` (u64) | both | "my next reliable frame is `seq` and it goes on `path`" |

`path.switch` is itself a reliable frame, so its own seq is `seq − 1` (the field
names the frame after it). It is a small control frame: it **never waits for
credit** (it may pass the 16 MiB bound by its own size), it takes the priority
lane on both sides, and its `seq` field is fixed when it is written, never when
it is queued. On a **planned** switch it is the last frame the sender puts on
the path it is leaving (so it is also the marker the receiver drains to: TCP
order means everything before it has already arrived). On an **unplanned**
switch the old path is dead, so the same message goes out first on the new
path.

On receiving `path.switch{path:P, seq:N}`:

1. My sending path becomes `P`; my frames' seqs continue from where they were,
   and the replay from the peer's last ack goes out on `P`.
2. If the message arrived on a path other than `P`, nothing is drained: the
   replay goes out on `P` and the old path stays attached as a **standby**.
3. Nothing is closed here. The phone closes a path only on its own socket
   error or EOF, or when the Mac closes it. The Mac closes a path itself after
   a planned switch's drain (the peer's marker read on the old path, or the 2 s
   backstop), and it keeps a demoted path as a standby until that path wins
   back on margin or fails.
4. Every open video stream gets one `window.keyframe` from the Mac (§5.6).

RTT is measured as `now − ts` on the side that receives the `pong`, using that
side's monotonic clock, so no clock agreement is needed. A ping with no pong
within 1.5 s is one lost sample and, if it is the current path and nothing else
answers, a path failure (D5).

### 5.5 Reliable and lossy

| Reliable — wrapped in `0x30` | Lossy — sent bare |
|---|---|
| `0x01` JSON (every message except `path.ping`/`path.pong`) | `0x02` VIDEO_CONFIG |
| `0x10` TOUCH | `0x03` VIDEO_FRAME |
| `0x11` SCROLL | `0x04` AUDIO_CONFIG |
| `0x12` KEY | `0x05` AUDIO_FRAME |
| `0x20` APK_DATA · `0x21` SHARE_DATA · `0x22` DROP_DATA · `0x23` CLIP_DATA · `0x24` FS_DATA | `0x13` HOVER |

- Within a path nothing is ever lost (it is TCP). "Lossy" means **not replayed
  across a switch**: a VIDEO_FRAME that was in flight on a path that died is
  dropped rather than resent, because a resent frame is a stale picture; a
  planned switch does not lose it at all, because it arrives before the marker.
- A new frame type is lossy unless this table lists it.
- A lossy frame is written without credit, so it queues on a path only while
  that path's writer holds at most **128 KiB** (a larger frame only on an empty
  queue); past that it is dropped, which is what lossy means, and the delta-drop
  rule still sees a stalled consumer (E-1/RR-1).
- A reliable frame is never dropped silently: it either arrives, or the session
  ends (§8).

### 5.6 After a switch

- The Mac asks a keyframe of **every open video stream** with the existing
  `{"t":"window.keyframe","stream":N}` — no new message. The phone already
  answers it, and may answer with a fresh VIDEO_CONFIG first (today's rule), so
  a lost VIDEO_CONFIG is repaired by the same request.
- The phone re-sends its current AUDIO_CONFIG (if audio is running) before its
  next AUDIO_FRAME after committing a switch, so a lost AUDIO_CONFIG costs one
  frame, not the rest of the audio.
- `window.content` is JSON, so it is replayed and never lost.

## 6. The session's state machine

One closed set of states, one pure transition `(state, event) -> (state,
actions)`; side effects run from the returned actions, and every transition logs
`paths: <from> --<event>--> <to>` with closed tokens only (never an address, a
fingerprint or a key). One dial is its own small machine (dialing → ready →
hello/join → welcomed, or failed/closed) and logs
`attempt: <from> --<event>--> <to> (path <id>)` the same way.

| State | Event | Result |
|---|---|---|
| `Live(cur)` | `PathUp(id, joined)` | stay `Live`; start that path's ping; ranking gets `PathUp` |
| `Live(cur)` | `PeerSwitch(id, seq)` on the path being left | `Migrating(cur, id)`; the Mac closes `cur` after the peer's marker or the 2 s drain backstop |
| `Live(cur)` | `PeerSwitch(id, seq)` on the new path | `Live(id)`; `cur` stays attached as a standby (the phone never closes it on a switch) |
| `Live(cur)` | `CurrentFailed(cur)` and a ranked path `b` is up | `Migrating(cur, b)`; send `path.switch` on `b`, replay from the last ack, then `window.keyframe` per stream |
| `Live(cur)` | `CurrentFailed(cur)`, no other path up | `Orphaned(now)`; mark the UI "reconnecting" |
| `Live(cur)` | `PathDown(other)` | stay `Live` |
| `Live(cur)` | `PongLost(cur)` and another usable path `b` is up | `Live(b)` at once; `cur` becomes a **standby** — kept open, still pinged, never chosen on a failover, only the margin rule brings it back (D-2) |
| `Live(cur)` | `PongLost(cur)`, no other usable path, one path attached | stay `Live(cur)`; the lost pong is a sample only (PATH-21) |
| `Live(cur)` | `PongLost(cur)`, no other usable path, two or more attached (every other is a standby) | `Orphaned(now)`; mark the UI "reconnecting"; `cur` stays a **standby** — kept open, still pinged, closed by its socket error or the session's end (PATH-21/E-9) |
| `Live(cur)` | `Close(why)` | `Ended(why)` |
| `Migrating(from, to)` | `PeerSwitch(to, seq)` | `Live(to)`; the switch is complete |
| `Migrating(from, to)` | `PeerSwitch(p, seq)` for any attached `p` | `Live(p)`; the Mac alone decides (PATH-8/E-10) |
| `Migrating(from, to)` | `PathDown(to)` | `Orphaned(now)` if nothing else is up, else back to `Live(from)` when `from` is still usable, else `Migrating` to the next ranked path |
| `Migrating(from, to)` | `PongLost(to)` | `Live(from)` when `from` is usable (`to` becomes a standby); else the next usable path; else `Orphaned(now)` with `to` kept as a standby (PATH-21/D-2/E-9) |
| `Migrating(from, to)` | `drain 2 s` (planned switch, the peer's marker was not read) | close `from`; stay `Migrating` until the peer's marker or the new path's own pong timeout decides |
| `Migrating` | `grace 30 s` without the peer's marker | `Ended(graceExpired)`; the slot is freed (PATH-21/E-10) |
| `Migrating` | `Close(why)` | `Ended(why)` |
| `Orphaned(since)` | `PathUp(p, joined)` | `Live(p)`; send `path.switch{p, N}` on `p` as the first frame, replay from the last ack, `window.keyframe` per stream |
| `Orphaned(since)` | `PeerSwitch(p, seq)` for an attached `p` | `Live(p)`; the grace ends (PATH-8/E-10) |
| `Orphaned(since)` | `PathDown(any)` | stay `Orphaned` |
| `Orphaned(since)` | `grace 30 s` | `Ended(graceExpired)`; the replay buffer is discarded and the Mac's UI says the phone is unreachable |
| `Orphaned` | `Close(why)` | `Ended(why)` |
| `Ended` | any | `Ended` (ignored) |

Ignored on purpose, so nobody builds them: a `PeerSwitch` for a path this side
does not have (logged once), an `Ack` for a seq above what was sent or a
`RELIABLE` frame whose outer stream disagrees with its inner one (protocol
errors, session ends), a `PathUp` while `Ended`, a second `PathUp` for a path id
already live (the second socket is closed), a `Pong` from a path that is not
live.

Every path that leaves the layer reaches the session machine as `PathDown` in
every state — a socket error (the writer's failure included), EOF, the Mac's
close, or the phone's own `ClosePath` — so the machine's live set never names a
path that is gone. `CurrentFailed` is the pong rule's failure signal, never the
detach route (E-10).

While `Orphaned` (and whenever the path count is below what the ready providers
can give) the Mac re-dials them with `hello{join}`: back to back with a 2.0 s
connect timeout inside the grace (E-11c), and on the reconnect backoff
(1, 2, 4, 8, 15 s) outside it, inside the 30 s grace (PATH-22/D-3). A rejoin is
`PathUp` on the orphan, so it gets the unplanned switch's marker and replay.

The session ends (not just the path) on: the 30 s grace expiring, an oversized
frame, a bad pin on the last path, the person closing the window/forgetting the
phone, or the phone's own drop. A full replay buffer is **not** on this list: a
producer waits for credit (§8). Ending is
today's ending: the phone restores every power state it touched and frees the
slot; the Mac emits one failure with a reason and retries on the existing
backoff.

## 6.1 The single-path silence probe (PATH-24/E-11)

A one-path session has no ranking to fail over (`D1`) and PATH-21 forbids
failing that path on a lost pong. If the radio dies while the socket stays
open, the old connection can sit in TCP's retransmission backoff for seconds
after the network is back: the picture is dead, but nothing dials.

While exactly one path is attached, a stream is open and neither paused nor
covered, and that path has delivered **no inbound frame for 2.0 s** (frames,
`window.still`, JSON or anything else), the Mac dials one **probe join**: one
PATH-20 provider, `hello{join}` with the session id, the same dial a rejoin
makes. It never fails, closes or marks the old path Reconnecting; the
picture's WIN-17 overlay stays the only signal. With no open and unpaused
stream there is no trigger.

The probe is its own machine (one enum, one pure transition):

| State | Event | Result |
|---|---|---|
| `idle` | `tick`, one path + live stream + 2.0 s silence | `inFlight`, dial one join |
| `idle` | `tick` any other way | stay `idle` |
| `inFlight` | `tick` with the trigger still holding | stay `inFlight` (never a second dial) |
| `inFlight` | `tick` with frames back | `idle`, cancel the dial |
| `inFlight` | `failed` | `idle`; the next tick dials at once if the trigger holds |
| `inFlight` | `inbound` / `stop` | `idle`, cancel a dial in flight |
| any | `welcomed` | `idle` (the session owns the switch) |

A probe's connect timeout is **2.0 s** — its own, not the session's general
dial timeout, which the session's first connect keeps — so a probe begun
during an outage gives up within the blink of a returning network instead of
sitting out the general timeout. After a failure the next probe is dialed at
once: back-to-back, never more than one dial in flight, while the trigger
holds. The machine stops when inbound frames arrive on any path, the stream
closes or the session ends. The cost is one SYN every ~2 s during an outage.

**E-11c.** The same reasoning applies to the orphan's rejoin. PATH-6's grace
exists to bring the session back quickly, so while the session is `orphaned` a
rejoin gives up after **2.0 s** (the probe's constant, not the session's
general dial timeout) and a failed one is dialed again on the next 0.25 s
tick. A round dials every missing provider once; a tick never starts a second
round while one is out, so a provider with a dial in flight is never doubled.
A `no_session` reply still ends the grace and starts one new session at once
(RR-12). Outside the grace — a live session that is a path short — the
reconnect backoff (1, 2, 4, 8, 15 s) is unchanged, and so is the controller's
schedule for a new session after the grace ends.

| State | Event | Result |
|---|---|---|
| `idle` | `tick`, a provider missing | `inFlight`, dial the round |
| `idle` | `tick`, nothing missing | stay `idle` |
| `inFlight` | `tick` | stay `inFlight` (never a second round) |
| `inFlight` | `failed`, orphaned | `idle`; the next tick dials at once |
| `inFlight` | `failed`, not orphaned | `waiting(until, failures + 1)` |
| `waiting` | `tick` before `until`, not orphaned | stay `waiting` |
| `waiting` | `tick` at `until`, or orphaned | `inFlight`, dial the round |
| any | `welcomed` | `idle` (the backoff restarts) |
| any | `stop` | `idle` |

The cost is one round every ~2 s while the grace runs (faster when a dial is
refused), and a phone that comes back 10 s into the grace meets a dial within
about a second instead of waiting out an 8 s backoff step.

When the probe welcomes, the session has two paths, so PATH-7's pings start.
If the old path is **still silent** the session switches to the probe at once
— an unplanned failover: `path.switch` on the new path, the replay, then a
keyframe per stream — and the old path becomes a **standby**, never failed or
closed by the probe. Otherwise the two-path ping rule decides. The phone needs
nothing new (PATH-11, E-10).

The NFR is `blip_recovery_ms` (3000 ms): from the network being back to the
first frame or still over the new path, on the host e2e (`pathblip`) and the
emulator (`probe-join`).

## 7. The ranking

D1: one path is never pinged (PATH-18's 15 s session ping and TCP keepalive
cover it); with two or more, every path — the standby included — is pinged every
2 s while the phone's screen is on or a transfer runs, and every 15 s otherwise.
RTT p50/p95 and loss over the last 30 s; the score is a pure function of those
numbers plus the provider's throughput class; only the Mac decides. A path that
keeps receiving frames is alive even when a pong is late (D-2). A pong that
arrives within **1 s** of that path carrying bulk in either direction is a
liveness signal only: it queued behind that bulk, so it measures the queue, not
the link, and is never a ranking sample (E-8).

### 7.1 The score

Samples are kept in a 30 s window per path (at most 15, one per 2 s ping). With
`n` samples sorted ascending, nearest rank is used: `p50 = x[ceil(0.50·n) − 1]`,
`p95 = x[ceil(0.95·n) − 1]`, `loss = (pings − pongs) / pings` over the window.

```
q_rtt  = 1 / (1 + p50_ms / 10)
q_jit  = 1 / (1 + max(0, p95_ms − p50_ms) / 25)
q_loss = 1 − min(loss, 0.10) / 0.10
q_bw   = min(1, class.floorMbps / 209)

score  = 1000 · (0.45·q_rtt + 0.15·q_jit + 0.20·q_loss + 0.20·q_bw)      // 0…1000
```

- 209 Mbit/s is today's measured LAN upload (research, 2026-10-30), so every
  class is scored against the best number this project has measured.
- **Throughput is not measured.** It is the provider's declared class floor:
  `lan` = 100 (measured 209, declared "at least 100"), `direct` = 8 (the rate
  one 1080p60 mirror needs, ARCHITECTURE; the link's real rate is unmeasured),
  `wan` = 2 (the remote cap in ROADMAP). An unmeasured path is therefore scored
  at its floor, never at zero and never at a guess. A LAN therefore does not
  score a full bandwidth term either: 100/209 = 0.478. The floors — and scoring
  direct at 8 until P4 measures it — are the reviewer's decision of 10-30.
- The weights say what a mirror feels: latency first, then loss (a retransmit
  stall), then the room to grow, then jitter.
- A path is **rankable** only once it has 2 pongs in the window (4 s). An
  unrankable path can still be chosen on failover — it just cannot win on
  margin, so a path that has never run never displaces a working one.

### 7.2 The worked example, with today's numbers

LAN: 5.5 ms median, p95 8 ms (a router on the same Wi-Fi), no loss.
Direct: 10–16 ms, so 13 ms median and p95 39.8 ms (the measured p95 from the
30 s stream), 0.65% loss (the middle of 0.2–1%).

| Term | LAN | direct |
|---|---|---|
| `q_rtt` | 1 / (1 + 5.5/10) = 0.645 | 1 / (1 + 13/10) = 0.435 |
| `q_jit` | 1 / (1 + 2.5/25) = 0.909 | 1 / (1 + 26.8/25) = 0.483 |
| `q_loss` | 1.000 | 1 − 0.0065/0.1 = 0.935 |
| `q_bw` | 100/209 = 0.478 | 8/209 = 0.038 |
| **score** | **1000·(0.290 + 0.136 + 0.200 + 0.096) = 722** | **1000·(0.196 + 0.072 + 0.187 + 0.008) = 463** |

**Verdict: the LAN wins, 722 to 463 — a gap of 259, far above the 100-point
threshold, so nothing switches while the LAN is healthy.** The bandwidth terms
(96 against 8 points) carry more than direct's whole latency advantage, which is
the honest state of knowledge: measured RTT and loss cannot pay for an
unmeasured throughput.

**When it flips.** The Mac switches only when the current path's score falls
100 below another's — so below 363 here. On a merely busy router (p50 30 ms, p95
90 ms, 2% loss) the LAN scores 1000·(0.113 + 0.044 + 0.160 + 0.096) = **412**:
51 below direct, not 100 — **no switch**, which is the point of the margin. On a
congested one (p50 40 ms, p95 120 ms, 5% loss) it scores
1000·(0.090 + 0.036 + 0.100 + 0.096) = **321**, which is 142 below direct:
**after 5 s the Mac switches to direct**. The other way it flips is the failure
rule: a socket error or 1.5 s without a pong on the LAN switches at once,
whatever the scores say.

The margin is 100 because that is three times the score movement one ping of
jitter causes at these numbers (2 ms of p50 moves `q_rtt` by 0.074, i.e. 33
points), so a single noisy sample cannot start a switch. **Decided by the
reviewer on 10-30:** 100 stands, and it is recorded here, beside the formula.

### 7.3 The ranking's state machine

State carries the current path, each path's 30 s window, and the live set.

| State | Event | Result |
|---|---|---|
| `Idle` | `PathUp(id)` | `Steady(id)` if it is the only live path; else `Steady(best rankable)`, and `Idle` while none is rankable |
| `Idle` | `Sample`, `Tick`, `PathDown` | stay `Idle` |
| `Steady(cur)` | `Sample(id, …)` | stay; the window is updated (pruned to 30 s) |
| `Steady(cur)` | `Tick`, some `b` has `score(b) ≥ score(cur) + 100` | `Challenging(cur, b, now)` |
| `Steady(cur)` | `Tick`, no such `b` | stay `Steady(cur)` |
| `Steady(cur)` | `CurrentFailed(cur)` | `Steady(best live)` + `Switch(best)`; `Idle` + `SessionOrphan` when none is live |
| `Steady(cur)` | `PathDown(cur)` | as `CurrentFailed` |
| `Steady(cur)` | `PathDown(other)` | stay |
| `Challenging(cur, b, since)` | `Tick`, still `score(b) ≥ score(cur) + 100` and `now − since ≥ 5 s` | `Steady(b)` + `Switch(b)`, unless a planned switch ran less than **30 s** ago: then stay `Challenging` (E-8's hold) |
| `Challenging(cur, b, since)` | `Tick`, the gap fell below 100, or `b` left, or `cur` changed | `Steady(cur)` (the 5 s starts over next time) |
| `Challenging(cur, b, since)` | `CurrentFailed(cur)` | `Steady(best live)` + `Switch(best)` at once (no hysteresis on a failure) |
| `Challenging` | `PathDown(b)` | `Steady(cur)` |
| `Steady`/`Challenging` | `PathUp(id)` | stay; the new path joins the windows and is unrankable until 2 pongs |
| any | `Switch(to)` from the session (e.g. the phone's marker) | `Steady(to)`; the challenger is dropped |

Both sides run this machine. Only the Mac acts on its `Switch`; the phone's copy
is what the tests run (K1 and K2 use the same vectors) and what lets the phone
report a path's health while the Mac is the one deciding. The Mac is the only
one that sends `path.switch`.

### 7.4 Every timer

| Timer | Value | Where | Source |
|---|---|---|---|
| path ping | **2 s** with two or more paths while the screen is on, an app stream is open, or bulk moved within the **2 s** transfer window; **15 s** otherwise; **never** with one path | both sides, every path, standby included | D1/RR-9 |
| pong timeout | **1.5 s** per ping; not lost while the path receives | both | D5/D2 |
| rejoin dial | **back to back with a 2.0 s connect timeout inside the 30 s grace** (E-11c); the reconnect backoff **1, 2, 4, 8, 15 s** outside it | Mac | D3/E-11c |
| sample window | **30 s** (≤ 15 samples) | both | D5 |
| switch hysteresis | **5 s** at the margin | Mac acts; both compute | D5 |
| planned-switch hold | **30 s** per session between planned (margin) switches; failovers and demotes are never held | Mac acts; the ranking holds | E-8 |
| orphan grace | **30 s** with no path before the session ends | both | D4 |

Implementation constants (named so they are not mistaken for decisions): ACK
coalescing 10 ms / 16 frames with a 10 ms timer flush; reorder window 64 frames /
4 MiB; old-path drain backstop 2 s; a joined path that never answers a ping is
dropped at 5 s; at most 3 paths per session; the Mac's write watermark is 256 KiB
low / 1 MiB high per path.

## 8. The bounds: credit, never a drop

- **Replay buffer: 16 MiB per direction**, holding every reliable frame from
  the peer's last ack to the newest sent one, with its seq and byte count.
- **It never overflows, because a producer waits instead.** Before a producer
  reads the next chunk of its source it checks `unackedBytes + nextFrameBytes`
  against its budget; if the frame would not fit, the producer stops reading
  and resumes when an ACK frees enough. No frame is created that the buffer
  cannot hold, no frame is dropped, and the session does **not** end because a
  buffer is full — a 200 MiB drop or a file read must survive a Wi-Fi blip.
- **Two budgets inside the 16 MiB**, so control never waits behind a file:

  | Producer | Budget | Frames |
  |---|---|---|
  | bulk | at most **12 MiB** of unacked bytes | `APK_DATA`, `SHARE_DATA`, `DROP_DATA`, `CLIP_DATA`, `FS_DATA` |
  | control | the rest, and always at least **4 MiB** free | `JSON` (every message), `TOUCH`, `SCROLL`, `KEY` |

  A bulk producer may not push the bulk total past 12 MiB whatever control is
  doing, so a `KEY`, a `TOUCH` or a `window.*` always has room and goes out at
  once. Control may use the whole 16 MiB when no bulk transfer is running.
- **How each bulk producer pauses**, on both sides, is the same rule: the
  sender owns a chunked reader over its source and stops pulling from it while
  its budget is full, so nothing is buffered beyond the frame it does not read.
  Mac: `DROP_DATA` (a Finder file), `APK_DATA` (a `.apk` file), `CLIP_DATA` and
  `FS_DATA` (a write) pause their file/stream reads. Phone: `SHARE_DATA` (the
  shared file), `FS_DATA` (a read) and `CLIP_DATA` pause theirs. A paused
  producer holds one file descriptor and a position, nothing more; the ack
  that frees a budget resumes it. The producer's own progress messages
  (`drop.progress`, `fs.progress`, `apk.progress`, `share.*`) are control
  frames and keep flowing, so the UI never looks stalled.
- **The reorder window works the same way.** 64 frames / 4 MiB; when it is
  full, the reader **stops reading only the path** whose next frame is ahead of
  a gap another path holds (TCP backpressure). A frame ahead of a gap on that
  same path's own stream does not pause its reader: the receiver keeps it in
  that path's own overflow — bounded by both the 64-frame count and the 4 MiB
  byte budget, past which it is a protocol error — and retries it when the
  window has room. It never drops a frame and never ends the session for this.
  The path that holds the gap keeps being read, and ACKs still go out on any
  path, so progress toward the gap is never blocked by the window (RR-7).
- **Bulk enters the seq space only when its path has room.** A bulk frame takes
  a seq only while the sending path's outbox is under its **256 KiB** low
  watermark and its unacknowledged bulk is inside a **1 MiB** window (RR-4's
  floor for an ack round, measured as the smallest window that carries a 64 MiB
  file across a black-holed path); until then it waits outside the seq space in
  the pending list with no seq. Control frames are admitted at once, so a key is
  never more than the window plus one chunk behind the file, at any link rate
  (E-4). The 12 MiB credit stays the hard cap on unacked bulk.
- **Every path writes from its own writer.** No socket write happens under the
  session lock: one path's writes stay in order, and `detach` and `closeAll`
  close a socket without it, so a stalled path never freezes another's reader,
  the ticker or teardown (R-2).
- **The delivery hand-off is bounded by bytes.** A receiver ACKs a reliable
  frame only after handing it to the session dispatcher; a full dispatcher
  blocks that path's reader and pushes back through TCP instead of dropping an
  acked frame. The hand-off holds at most 4 MiB and admits one larger frame only
  when it is empty — part of the same 20 MiB, because a delivered frame has
  already left the reorder window (R-1/PATH-15).
- **Priority inside a path.** `path.ping`, `path.pong`, ACK and `path.switch`
  are written at once, never behind queued bulk: the Mac holds admitted bulk in
  the path layer and feeds the channel only while it reports writable (a 256 KiB
  low write watermark per path), and the phone gives the same frames a priority
  lane in its writer (the join ping included). The switch marker never waits
  for credit and its seq is fixed when it is written (E-6). A path that
  received anything in the last 1.5 s is alive even if its pong is late, a pong
  lost there is one ranking sample, and a pong-only failure demotes it to a
  standby rather than closing it (D-2/RR-14).
- **One writer per path.** A path's frames are written in seq order by one pump
  at a time: a second sender leaves its frame in the outbox and the running
  pump takes it, so two threads can never reach the channel out of order
  (PATH-4/RR-14).
- A frame larger than the whole buffer cannot exist: the wire's maximum is
  8 MiB, so 16 MiB always holds at least two frames.
- A switch replays **from the peer's last ack**, so a planned switch costs the
  bytes beyond the last ack (at most one path's send window), not the buffer.
- **Phone memory.** The paths layer adds at most 16 MiB (send, credit-bounded)
  + 4 MiB (reorder window) + 4 MiB (delivery hand-off) + 4 MiB (frames held
  ahead of a same-path gap) = **28 MiB** of heap while a session is live, plus
  one frame up to 8 MiB in the hand-off and one in a path's writer queue, on
  top of the existing per-stream ~250 ms video queue; video and audio never
  enter either buffer. A lossy frame queues on a path only while its writer
  holds at most 128 KiB. With no session it allocates nothing and holds
  nothing: the buffers are created with the session and freed with it.
- The phone's slot, the session id and the path ids are per session; nothing
  about a path survives the session.

## 9. The provider interface

A provider is a source of paths. It must offer exactly this, so a tunnel fits
later without touching the session layer:

```
PathKind          lan | direct | wan
ThroughputClass   floorMbps: Int, typicalMbps: Int?     // declared, never measured
Availability      ready | needsSetup(code) | unavailable(code)
PathEndpoint      a dialable target for one phone, or a local listener port
```

- **Mac side**: `availability()` (pure, no network), `dial(phone) -> PathConnection`
  (opens the transport, reports bytes and errors, closes), `class`.
- **Phone side**: `listen(port) -> PathListener` (accepts raw sockets; TLS is
  wrapped above it), `class`, `availability()`.
- What a provider may **not** do: read a decrypted byte, see a frame, decide a
  switch, or keep state the session needs. A provider is a byte pipe with a
  declared class and an honest availability.
- `lan` (public build): today's Bonjour discovery + TCP, class `lan` (100/209).
- `direct` (self-build): the helper dials the phone's Aware listener; class
  `direct` (8, unmeasured) — `docs/design/direct-link.md`.
- `wan` (later): the Mac dials a tunnel's local port; class `wan` (2/8); its
  availability is the tunnel's own state, and the session layer stays as it is
  because a tunnel is just another path with a worse class and a worse RTT.

The Mac's attempt planner (`EndpointPlanner`) gains one rule: it asks every
provider that is `ready` for that phone, and a provider that is not ready is not
a failure — it is simply absent, and the settings say why. A provider that only
exists in a direct build is not offered at all by a public one, so nothing is
dialed that the other side could not join.

### 9.1 Starting a session on any path (the connect order)

A session does not have to start on the LAN. The Mac starts every ready
provider **at once** and only the *hello* is serialized, because two plain
hellos would make the phone supersede its own fresh session:

1. **t = 0.** The LAN provider dials Bonjour, then its cached address; the
   direct provider asks the helper for a `dial` (subscribe → discovery → NDP →
   the phone's Aware listener, then the fd). The two run in parallel.
2. **The first attempt to finish TLS sends the plain `hello`** (no `join`) and
   waits for `welcome`. Every other attempt that also finished TLS holds its
   hello.
3. **The first `welcome` founds the session** (a new id). Every held attempt
   now sends `hello{"join":<id>}` and becomes a path. If the attempt that held
   the plain hello fails before `welcome`, the next finished attempt sends the
   plain hello instead — at most one plain hello is ever in flight.
4. **Timers.** The LAN attempt keeps today's 6 s connect timeout. The direct
   attempt's NDP budget is 20 s in the helper (the proof measured ~3.5 s) and
   its TCP connect 3 s after the NDP is up. The session's connect phase ends at
   the first `welcome`; it fails (and the ordinary backoff starts) only when
   **every** started provider has failed. A direct-only start therefore takes
   the NDP's few seconds; when a LAN exists it still founds the session inside
   `connect_ms`. A path that finishes after the session is up joins inside the
   30 s grace like any other.
5. **Nothing waits on a provider that is absent.** A public build starts one
   provider; a phone that is not published is not dialed over Aware.

The phone's slot sees one `Connect` per listener and does not care which one it
came from (`Server` for the LAN, the app's Aware acceptor for direct —
`docs/design/direct-link.md` §4).

## 10. The test plan for P1

P1 is the public build with `lan` plus a **test-only second provider** (a second
LAN connection to the same fake phone's second listener). Nothing here needs a
phone, a VM or the direct build.

### 10.1 K1 / K2 pure tests

Both sides implement the same machines with the same vectors, so the two suites
carry the same cases:

| Test | Asserts |
|---|---|
| `PathCodecTests` (K2) / `PathCodecTest` (K1) | the two golden byte strings above; a 8 MiB − 18 inner payload round-trips; a 9th inner byte is refused; a mismatched outer `stream` is a protocol error |
| `ReplayBufferTests` | release on ack, a duplicate is dropped, resume from the last ack, a 8 MiB frame fits, and a frame that would pass the cap is never created |
| `CreditTests` | a bulk producer stops at 12 MiB and resumes on the ack that frees it; a `KEY` goes out at once while bulk holds 12 MiB; control may use all 16 MiB when no bulk runs; a 200 MiB transfer across a 10 s orphan completes byte-exact with ≤ 16 MiB held |
| `ReorderWindowTests` | in-order delivery, a gap holds ≤ 64 frames, a full window stops reading that path instead of dropping (the fake reader counts the bytes it was allowed to read), the ack does not advance past a gap |
| `PathSessionTests` | every state/event pair of §6, the ignored events, every timer with a virtual clock (2 s, 1.5 s, 30 s grace, 2 s drain) |
| `PathRankingTests` | the formula's four terms at the boundary values; the worked example's 722 and 463; the busy row (412: no switch) and the congested row (321: switch after 5 s); 4.9 s does not switch; a failure switches at once; an unrankable path can fail over but never wins on margin |
| `PathSwitchTests` | a planned switch sends the marker last on the old path; an unplanned one sends it first on the new; a marker for an unknown path is ignored; the keyframe request goes out per open stream |
| `PathStartTests` | two providers started at once: exactly one plain hello, the other holds and then joins with the winner's id; the plain hello moves to the other attempt when the first fails; the attempt fails only when every provider did; a direct-only start founds the session |
| `SessionSlotTest` (K1) | the join table of §4, every state; a join never supersedes; `no_session` only for the live Mac; `too_many_paths` |
| `PathIdsTests` | 32-hex session ids are random per session; 8-hex path ids are unique per live set |
| `VersionTests` (K2) / `VersionTest` (K1) | `hello.v` is 4 on both sides; a `v` of 3 or 5 gets `error version` carrying the refusing side's `v` and a close before `welcome`; the Mac says "Update PocketDeck on your phone." for a lower or absent `v` and "…on this Mac." for a higher one, the phone says the same from the hello's `v`, and both stop retrying; no path frame, `join` or `session` field is sent to a peer that was refused |
| `NoFallbackTests` | there is no reduced mode: no code path builds a session without seq/ack/replay, and a refused version is never retried as a one-connection session |

### 10.2 `fakephone`

The fake phone speaks the new protocol: `hello.v` 4 with `hello.path`, `join`,
`welcome.session`, RELIABLE/ACK, `path.ping`/`path.pong`/`path.switch`, and a
second listener so a switch has somewhere to go.

New flags: `--version N` (what `hello.v`/`welcome` speaks, default 4; `3` is the
old peer), `--paths N` (how many listeners it opens), `--join <id>` (accept only
this session id), `--no-pong <path>` (black-hole one path's pings),
`--drop-path <path> after <s>`, `--slow-pong <path> <ms>` (scores a path worse
without failing it). New `deckctl` verbs: `version`, `paths` (list),
`switch <path>`, `kill-path <path>`, `pong-mode <path> <on|off|delay>`.

### 10.3 The fault proxy

`tools/pdpathfault/pdpathfault.py` — a TCP proxy that sits in front of one path
listener so a check can break a path exactly as a person's Wi-Fi would:

```
pdpathfault.py --listen 47961 --connect 127.0.0.1:47960 \
               --mode pass|delay|blackhole|rst|throttle \
               [--delay-ms 120] [--rate-mbit 2] [--ctl-file /tmp/pdpathfault.ctl]
```

- `pass`: bytes both ways, unmodified (the default).
- `delay`: each direction delayed by `--delay-ms`, in order.
- `blackhole`: reads and drops, writes nothing (a dead radio, with the socket
  still open — the difference between "silent" and "closed").
- `rst`: closes both sides with a reset at once (a Wi-Fi drop with a RST).
- `throttle`: caps each direction at `--rate-mbit` (a congested LAN).
- The mode can be changed at run time by writing one line to `--ctl-file`
  (`mode blackhole`, `rate 400`), so a check can kill a path at a precise byte
  of a file transfer or change its rate mid-run. Its store-and-forward queue is
  bounded per direction (256 KiB), like a socket buffer, so a sender's own
  write queue can fill and back-pressure is real. Every request and its mode is
  written as a JSON line to `--events`.

### 10.4 e2e, one check each

| Check | What it proves | Requirement |
|---|---|---|
| `pathkill` | a large file (≥ 64 MiB) goes through a path the proxy black-holes for 10 s mid-transfer: the producer waits on credit, the session stays live on the second path, and the file's SHA-256 matches byte for byte with ≤ 16 MiB ever held | PATH-4, PATH-10 |
| `pathmirror` | a mirror is live on a path; the proxy black-holes it; the next VIDEO_CONFIG/keyframe arrives on the second path and the picture is live again **within 2 s** (`stale_picture_ms`) | PATH-5, PATH-17 |
| `pathswitch` | a planned switch (the Mac switches by margin, `--slow-pong` on the LAN) loses no reliable frame: the fake phone's received seqs are contiguous across the switch, and no duplicate is delivered | PATH-3, PATH-9 |
| `pathgrace` | every path is killed and no join ever comes: at 30 s the session ends cleanly — one `paths: live --grace--> ended`, the phone's slot is free, the Mac retries, no orphaned socket stays open | PATH-6, PATH-16 |
| `pathstart` | a fake phone that answers on its second listener only: the Mac's session is founded there (exactly one plain `hello` on the wire, the LAN attempt held and then joined with the winner's id), and the session is usable | PATH-20 |
| `pathversion` | version pinning, both ways: a v3 fake phone answers the Mac's v4 `hello` with `error version` and closes (the Mac shows its incompatible-version state and stops retrying), and a v3-shaped `hello` against a v4 phone gets the same answer and no `welcome` — no path frame, no `join`, and no served session in either direction | PATH-1 |
| `pathrejoin` | the only path dies and the route returns inside the 30 s grace: the Mac re-dials a join on the reconnect backoff, the same session id comes back, the windows clear "reconnecting", and no second session starts | PATH-22, PATH-17 |
| `pathbulk` | a 16 Mbit/s path carries a 32 MiB drop with a fast standby: no lost pong, no path down, both paths open, the hash exact; then, on a 400 Mbit/s path, a KEY typed 0.6 s into a 64 MiB drop reaches the fake phone within `input_latency_ms` | PATH-23, PATH-7, PATH-10 |

`[PATH-n]` tags go on the `ok`/`bad` lines of those checks.

### 10.5 Reviewer, real hardware

One check the reviewer runs on the person's own phone and Mac (never an agent):

1. Both apps are current (protocol 4): a session is live over the LAN and the
   phone's Wi-Fi is switched off mid-mirror. The Mac must not open a new session
   (no `welcome` with a different id), the picture says "reconnecting", and at
   30 s the session ends.
2. The same, but the Wi-Fi returns inside the 30 s: the session continues on the
   joined path with the same session id — no new session, no second window set.
3. A phone still on the previous build (protocol 3): the Mac's connect gets
   `error version`, the banner says the versions differ, and it stops retrying —
   it never falls back to a one-connection session.

## 11. Non-goals

- Several sessions or several phones at once: one session per Mac-phone pair.
- Deciding a switch on the phone: the phone computes, follows, and never
  switches on its own.
- Replaying lossy frames, or a decoder's own error-recovery beyond
  `window.keyframe`.
- Any tunnel, relay or WAN behaviour in P1 (`wan` is the provider interface's
  third case, nothing more).
- Surviving a phone restart or the app being killed: that ends the session, as
  today.
