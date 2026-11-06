# Media transport — UDP datagrams (P3)

Design for the datagram half of P3. It extends the session layer in
[paths.md](paths.md); it does not fork it. The requirements are
`docs/specs/transport.md` (`PATH-25`…`PATH-35`), the wire is
`docs/PROTOCOL.md` § "Media over UDP". Control, input, files, audio and all JSON stay
on the reliable TCP path exactly as today: only **video** access units move to
datagrams. Audio is low-rate and gains nothing from unreliable delivery once
video no longer blocks it; keeping it on TCP avoids a second jitter buffer.
The packet type for audio is reserved, not sent in this phase.

## 1. Why plain UDP, and not QUIC

The brief allows QUIC datagrams or plain UDP with our own packetization. We
choose plain UDP:

- **Android has no QUIC API we can use in the Docker toolchain.** Cronet is a
  large native dependency and its QUIC stack is not exposed as raw datagrams;
  adding a QUIC library (ngtcp2/kwik) would add a C/C++ build, a JNI surface
  and an update path for one optional transport. The Mac side
  (`NWProtocolQUIC`) would then be a different implementation, so two stacks
  would have to agree on the same application protocol.
- **We need our own congestion control.** The epic's controller (PATH-31) is
  delay-based and drives the encoder's bitrate, frame rate and resolution. A
  QUIC stack would run its own congestion controller and loss recovery; using
  its datagram extension while fighting its sender is the worst of both.
- **The control plane already exists exactly once.** The TLS 1.3 session,
  pinning, path switching and reliable replay do the hard part. UDP inherits
  its trust from that session instead of adding a second handshake.
- **The browser mapping survives.** A browser cannot send raw UDP, but
  WebTransport datagrams and unordered WebRTC data-channel messages carry the
  same packet bytes; the packetizer is transport-agnostic (§8). QUIC would
  help a browser client, not the native one.

The cost is that we own the packet header, replay window, NACK and pacing.
Those are small, pure, and testable; §9 lists their tests.

## 2. Threat model (written before code)

### 2.1 Trust boundary

The only trust anchor is the existing mutual TLS 1.3 session with the pins
established by pairing (`docs/design/e2ee.md`, PAIR-*). UDP adds no pairing
step, no token, no new certificate and no fallback to an unauthenticated
transport. The phone still serves **one session to one Mac** (PAIR-21): the
UDP socket is opened only for the live session and is closed with it.

### 2.2 Assets and adversary

| Asset | Why it matters |
|---|---|
| Media content | it is the person's screen; it may show messages, documents or passwords |
| Session integrity | a forged packet must not corrupt a frame or fool the decoder |
| The phone's slot | an attacker must not create a second "session" or a second Mac |
| The person's network metadata | no address, key, SSID/BSSID or peer name in logs |

Adversaries considered:

1. **Passive observer on the LAN or the path.** Reads every datagram, records
   it, tries to decrypt later.
2. **Off-path/on-path attacker who can send datagrams** to the phone's UDP
   port: spoofing, replay, injection, amplification, resource exhaustion.
3. **A different paired Mac, or an unpaired peer.** Must never receive media,
   never join the media plane, never learn a key.
4. **A malicious app on the phone or the Mac.** Out of scope: it already has
   the plaintext through the OS compositor or the decoder.

### 2.3 Mitigations

- **Keys are per session and ephemeral.** Each side generates a fresh X25519
  key pair after `welcome`, exchanges the public key over the *pinned reliable
  path*, and derives direction-split 256-bit AES-GCM keys with HKDF-SHA256.
  Private keys are discarded when the session ends and are never written to
  disk or to a log.
- **Why not the TLS exporter.** The brief offers the TLS exporter; the Mac's
  public TLS stack (swift-nio-ssl) does not expose one (`NIOSSL` surfaces
  channel binding, not exporters), and reaching into CNIOBoringSSL's `SSL*`
  would couple us to a private pointer. An authenticated ephemeral ECDH over
  the same pinned TLS channel has the same trust properties for this use: no
  new trust path, forward secrecy for recorded media, and keys bound to the
  session id and both public keys. Android's
  `SSLSockets.exportKeyingMaterial` exists, but both ends must use the same
  derivation, so the portable choice is the in-band exchange. A side that
  cannot generate X25519 omits the capability; no new dependency is added.
- **AEAD on every datagram.** AES-256-GCM, a 96-bit nonce of four zero bytes
  plus the per-direction `u64` sequence, and the 18-byte outer header as
  associated data. Any authentication failure drops the packet silently.
- **Replay window.** One `u64` sequence space per direction (all packet types
  share it), a **1024-packet** sliding window, and a duplicate/old packet is
  dropped before it can reach the assembler. The window is sized for the
  shipped 8 Mbit/s cap: 8e6 / (1140 bytes × 8) = **877 packets/s** at full
  fragments, so 1024 packets cover **1.17 s** — longer than the 1 s the policy
  needs to see a loss event. A future cap must raise the window:
  `requiredReplayWindow(capBps) = ceil(capBps / (1140 × 8))` at 1 s;
  `MediaReplayWindowTest` computes it from `cap_kbps`, asserts the shipped
  constant satisfies the shipped cap, and asserts 20 Mbit/s would not.
- **Session and epoch binding.** The HKDF salt contains the session id and
  both public keys; the outer header carries the media epoch, so a packet from
  a previous transport epoch can never be stitched into the current picture.
- **No amplification.** The phone answers a probe only when it authenticates,
  the reply is not larger than the probe, and replies are limited to 100 per
  second per source. An unauthenticated datagram allocates nothing.
- **Bounded work.** Reassembly, NACK and parity have fixed memory and rate
  limits (§7); hitting them drops media, never ends the session and never
  blocks the reliable path.
- **Privacy of the payload, not only its bytes.** The outer header exposes
  magic/version, key id, epoch, sequence and ciphertext length. Type, stream
  id, PTS, fragment shape and the payload itself are inside the ciphertext, so
  the datagrams reveal timing and size — the same metadata any UDP flow shows
  — but not which window or which part of the screen changed. Logs carry
  closed tokens and numbers, never addresses or keys (PATH-14).

### 2.4 What is not protected

Traffic analysis (when the person is active, how large the screen changes
are), and a compromised endpoint. Neither is a regression against the TLS/TCP
path, whose ciphertext also reveals timing and size.

## 3. Capability and key exchange

- `hello` gains an optional `"media":["udp"]`; `welcome` gains an optional
  `"media":{"udp":<port>,"pub":"<64 hex>"}`. Either side missing the field means
  **TCP only**, with no probe, no error and no user-visible change. This is an
  optional media plane, not a second session mode: the session layer itself
  still has no reduced mode (paths.md §1.1).
- The phone binds one UDP socket when the session starts and advertises its
  port and X25519 public key in the founding `welcome`. The Mac sends to the
  TCP path's peer address and that port; the phone replies to the source of
  the authenticated probe, so no new address exchange or discovery exists. The exchange happens
  once per session, on the founding path; a join's welcome does not repeat it
  (if it does, the Mac verifies it is unchanged). The media plane resets to
  TCP on a later path switch (PATH-35) and re-probes if the new path is
  `lan`.
- The Mac sends `{"t":"media.key","pub":"<64 hex>"}` on the reliable path. The
  phone derives, replies `{"t":"media.key.ok","keyId":"<8 hex>"}`, and only
  then does the Mac start probing. Both sides compute:

```
secret = X25519(own private, peer public)
salt   = session_id || mac_pub || phone_pub || "pocketdeck-media-v1"
c2s    = HKDF-SHA256(secret, salt, "pocketdeck-media-c2s", 32)
s2c    = HKDF-SHA256(secret, salt, "pocketdeck-media-s2c", 32)
keyId  = lowercase hex of SHA-256(c2s || s2c)[0..4]
```

  The phone uses `c2s` to open Mac→phone packets and `s2c` to seal its own;
  the Mac does the reverse. A key id mismatch is a dropped packet, not an
  error. A malformed or off-curve public key means no UDP and no error. Keys
  live for the session; the media epoch changes on a transport switch but the
  keys do not. The phone learns the Mac's source address from each
  authenticated probe and replies there, so a Mac that roams to another
  address keeps the media plane without a new exchange.

## 4. The datagram

One UDP datagram is one fragment, at most **1200 bytes** end to end (safe for
IPv6's 1280-byte minimum and for tunnels; we never rely on IP fragmentation).
Overhead is 18 outer bytes + 16 GCM bytes + 26 inner bytes = 60, so one
fragment carries at most **1140 bytes** of an access unit.

```
outer (plaintext, AEAD associated data)
  u8  magic = 0x50 ('P')
  u8  version = 1
  u32 keyId
  u16 epoch           // first UDP media epoch is 1, +1 on every switch
  u64 seq             // per direction, starts at 1, all packet types
  u16 ciphertextLen   // inner header + payload + 16-byte tag
ciphertext (AES-256-GCM)
  u8  type            // 1 video, 2 audio (reserved), 3 feedback, 4 nack, 5 probe, 6 probe reply, 7 parity
  u8  flags           // bit0 keyframe, bit1 retransmit
  u32 stream
  u32 frameId         // per stream, increments for every access unit
  u64 ptsUs           // the access unit's pts; 0 for control packets
  u16 fragmentIndex
  u16 fragmentCount
  u32 sendUs          // low 32 bits of the sender's monotonic µs
  u8  payload[]       // Annex-B video bytes; control payloads for the other types
```

- **One access unit is fragmented, not one access unit plus its metadata.**
  The existing `VIDEO_FRAME` payload is `u64 ptsUs · u8 flags · Annex-B`; on
  UDP the PTS and flags live in the inner header, and the payload is the
  Annex-B bytes. On completion the receiver rebuilds the exact `VIDEO_FRAME`
  payload for the existing dispatcher. `AUDIO_FRAME` is the same with its
  packet bytes.
- The assembler keys on `(epoch, stream, frameId)`, accepts fragments in any
  order, and delivers only complete access units. An incomplete unit older
  than **100 ms** from its first fragment is dropped and counted (**1 s** for a
  keyframe, whose bits can take that long at the target rate); the display
  never waits for it (no jitter buffer — M1 stays the default).
- A dropped non-key frame breaks the reference chain, so the existing
  drop→`window.keyframe` path runs, throttled to one request per stream per
  **500 ms**. A keyframe that is incomplete is NACKed first and only then
  triggers a new request.

## 5. The transport policy machine

It is a second, small machine beside the path ranking (paths.md §7), keyed to
the current path: the path machine chooses *which connection*; this one
chooses *which media plane on that connection*. The Mac decides; the phone
runs the same machine for tests and follows (PATH-8's rule extended). When the strategy enables it, it
starts optimistic: as soon as the keys are ready it probes, without waiting
for a loss event.

States: `off`, `tcp`, `probe`, `handover`, `udp`, `fallback`.

| State | Event | Result |
|---|---|---|
| `off` | capability absent, strategy `tcp`, or the current path is not `lan` | stay `off` |
| `tcp` | `MediaKeysReady` and current path is `lan` | `probe` (10 probes, 100 ms apart) |
| `probe` | ≥5 valid `probe reply` in 1 s, loss ≤10%, p50 RTT ≤ TCP `srtt` + 20 ms | `handover`, send `media.switch{to:udp}` |
| `probe` | the 1 s ends without that | `tcp`; retry in 30 s, then 2 min, then 5 min |
| `handover` | `media.switch.ack` + the first complete keyframe on the target plane | `udp` when the target is udp; `fallback` when it is tcp |
| `handover` | 2 s without the keyframe | send one more `media.switch` back to the other plane; `tcp`/`fallback` |
| `udp` | a valid inbound packet stops for 1 s while a stream is open and unpaused | `handover` to TCP at once |
| `udp` | loss >10% in two consecutive 500 ms feedback windows | `handover` to TCP |
| `udp` | relative one-way-delay p95 > 150 ms (over the session's minimum) for 2 s | `handover` to TCP |
| `udp` | NACK failure >20% for 2 s | `handover` to TCP |
| `fallback` | 30 s, then 2 min, then 5 min (cap) | `probe` again |
| any | `PathChanged` | `tcp`; if the new path is `lan`, keys are still valid, so probe again |
| any | `SessionEnd` | `off` (socket closed, keys dropped) |

Every transition logs one line with closed tokens and numbers, e.g.
`media: tcp -> probe`, `media: probe -> tcp (loss=0.30 rtt=41)`,
`media: udp -> fallback (owd_rel_p95=280)`. No address, key or payload.

The `stream.transport` strategy key (`tcp` default, `auto`/`udp` for the
bench) is read once per session; `tcp` disables the machine, `udp` starts it in
`probe` even on a non-`lan` provider (the bench's fake phone), and `auto` is
the table above. The shipped default stays `tcp` through P3; flipping it to
`auto` is P5's merge decision, after P4's blind test. `MediaDefaultsTest`
asserts the shipped strategy value is `tcp` and that a default session offers
no `media` field and sends no probe — the default is a test, not a comment.

## 6. The switch

Make-before-break, one keyframe, no replay:

1. Mac → `{"t":"media.switch","to":"udp|tcp","epoch":N}` on the reliable path.
2. Phone → `{"t":"media.switch.ack","epoch":N}` on the reliable path. From the
   ack on, the phone sends no **video** on the old plane; audio stays on the
   reliable path and is unaffected. TCP ordering means every old-plane frame
   sent before the ack has already arrived.
3. **TCP → UDP:** the phone sends a fresh IDR on UDP in epoch `N`; the Mac
   keeps presenting the TCP picture until that keyframe is complete, then
   switches and ignores any later TCP video. The encoder keeps its config, so
   no new `VIDEO_CONFIG` is needed.
4. **UDP → TCP:** the phone sends `{"t":"media.epoch","epoch":N}` on the
   reliable path, then the TCP keyframe. The Mac ignores UDP packets for older
   epochs as soon as it processes the ack.
5. Exactly one IDR is forced per switch. The Mac does not also send
   `window.keyframe`; if the IDR is lost, NACK repairs it, and only after
   500 ms does one `window.keyframe` request go out. This is the "no keyframe
   storm" rule.
6. The Mac resets its decoder at the first keyframe of a new epoch. A switch
   never replays a video frame (PATH-5's rule extended).

## 7. Feedback, NACK, parity, the controller, bounds

- **Feedback** (Mac→phone, every 100 ms): highest seq, received/lost counts
  over the window, one-way-delay trend and p95, queue age, RTT. The delay is
  measured relative to the session's minimum observation, so the two clocks'
  offset cancels. It uses the same AEAD/seq space; it is a datagram, not
  JSON.
- **NACK** (receiver→sender): up to 32 missing sequence numbers for frames
  whose deadline has not passed, at most 200 per second. The sender resends a
  named fragment once if it still holds it, flagged `retransmit`. A sent
  frame's fragments are held for **200 ms** (a long round trip) and then
  freed; a later NACK is ignored. On a LAN one retransmit costs about one
  frame interval; that is cheaper than FEC.
- **Parity** (`stream.fec=parity`, default `off`): one XOR packet covering
  `count` consecutive data packets from `firstSeq`, at most one per ten data
  packets (at most 20% extra bytes), reconstructing at most one missing packet
  per group. The research found FEC does not pay on today's
  LAN (loss in 1 of 110 streams; the hitches are radio silences, which FEC
  cannot repair); it exists for a lossy path and is off by default.

### The controller

The phone is the only actuator; the Mac only measures and sends feedback. The
controller is a pure function of one feedback window (100 ms) and the current
state, so both ends run the same vectors in tests.

- **Target.** `min(8 Mbit/s, the stream's cap)` at the first UDP frame. The
  latency target is `stream.latency_target_ms` (40–300, default **100**).
- **Decrease.** The smoothed one-way-delay trend (arrival minus send time,
  differenced so the clock offset cancels) is over the target when it exceeds
  **15 ms/s for 300 ms**; loss is over when it exceeds **10% for 500 ms**. Each
  event multiplies the target by **0.85**, at most once per 500 ms.
- **Increase.** While the trend is below **5 ms/s** and loss below **2%**, the
  target grows **1 Mbit/s per second** (100 kbit/s per tick). It never exceeds
  the cap and never falls below **1 Mbit/s**.
- **Actuator order.** (1) encoder bitrate/QP every tick; (2) when the bitrate
  is at its floor and the delay is still over target for **2 s**, the fps cap
  drops one **15 fps** step toward a floor of **30**; (3) after **5 s** more,
  the resolution scale drops one step from 1 to 0.5 in eighths, through the
  existing CONFIG + keyframe path. Recovery reverses the order, one step per
  **2 s** of stable delay. The phone's TCP SendQueue adaptation is inactive
  for a stream while its media runs on UDP; the controller is the only writer
  of that stream's bitrate.
- **No feedback.** A missing feedback window holds the target (no
  increase); two missing windows (2 s) halve it once and log it.
- **Pacing.** Datagrams leave at the controller's target rate through a token
  bucket with a burst of at most two frames' bytes; a keyframe's excess is
  spread over its bits, never dumped as a burst. If the bucket is empty the
  sender holds at most one frame; an older frame waiting is dropped, counted
  and handled by the keyframe rule above.
- **A CONFIG change is ordered separately.** `VIDEO_CONFIG` stays on TCP, so a
  new-size UDP keyframe can arrive before it. The Mac holds a keyframe whose
  size/codec does not match the current config for up to **500 ms**; if the
  CONFIG arrives it decodes, otherwise it drops the keyframe and requests one.
  The resolution actuator above uses this rule.
- **Latency first.** The display never queues: an incomplete access unit is
  dropped at its deadline, a complete newer frame replaces an older one, and
  a dropped reference frame requests one keyframe (500 ms throttle). An
  incomplete keyframe is held up to 1 s, a delta only 100 ms. The controller
  is allowed to make the picture softer or slower; it is never allowed to
  make it later.

- Bounds: 2 MiB reassembly per session (1 MiB per stream), 1024-entry replay
  window per direction, 200 NACKs/s, 20% parity, one 1 MiB UDP send buffer.
  A bound reached drops media and counts it; it never ends the session and
  never delays reliable frames.

## 8. The browser mapping

The packetizer is transport-agnostic: the inner header + payload (§4) is the
unit a browser client carries.

- **Preferred: WebTransport datagrams.** One datagram = one packet of §4 minus
  the outer 18 bytes and the GCM tag (WebTransport already provides
  confidentiality, integrity and replay protection). A single bidirectional
  stream carries the feedback/NACK JSON/bytes; `sendDatagram` is unordered and
  unreliable by definition. This maps one-to-one to what the native UDP path
  does and needs no SDP.
- **Fallback where WebTransport is unavailable: WebRTC data channels** with
  `ordered:false, maxRetransmits:0`; one channel message = one packet of §4
  (minus the AEAD envelope). The same packetizer and the same controller run
  in JS over WebCodecs.
- **Not RTP/WebRTC media.** RTP would add a second packetization (FU-A), its
  own jitter buffer and its own congestion controller — exactly the latency
  and policy we are trying to own. The data-channel path reuses our frame
  boundaries and drop rules.
- No browser client is built in this epic; the point is that the bytes are
  already in a shape it can speak.

## 9. Tests and rounds

- K1 pure: header encode/decode, fragment/reassemble (any order, duplicates,
  missing, 8 MiB cap), AEAD vectors and tamper, replay window, HKDF vectors,
  the policy table (every state × event), the controller vectors (overuse,
  loss, recovery, floors), NACK/parity.
- K2: the Mac assembler hands the existing dispatcher an exact `VIDEO_FRAME`;
  a malformed/tampered datagram changes nothing; stats fields.
- fakephone: a UDP media socket (the existing fake phone grows one), so the
  e2e checks need no real phone.
- e2e/fault proxy: 1–5% loss, 20–80 ms jitter, 300–700 ms silences, UDP
  blocked; TCP unchanged; the switch is invisible in the picture and logs one
  keyframe per switch.
- Real link (lead): TCP vs auto vs forced UDP on the person's LAN, motion
  runs; the fault proxy repeats the loss/jitter/silence arms.

## 10. Non-goals

- A second session, a second Mac, or media to an unpaired peer.
- Media over UDP on `direct` in this phase (the LAN provider only; direct's
  address model is not an IP the Mac can send to).
- A browser client, a relay, or WAN NAT traversal.
- Replacing TCP for control, input, files or JSON.
- Surviving a phone restart or a killed app.
