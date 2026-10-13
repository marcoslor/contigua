# Remote access — relay protocol (v1)

Status: specification for `relay/` (`pocketdeck-relay`) and `relay/cmd/relayctl`.
Phone and Mac integration comes after end-to-end encryption (ROADMAP, "End-to-end
encryption (P0)"). The E2E layer (mutual TLS 1.3, keys pinned at pairing) runs
**inside** the byte stream this protocol provides, and is specified separately.

The relay is a rendezvous point plus a byte pipe. It never sees plaintext, and it
never authenticates the Mac ⇄ phone pair. It only checks that the phone really holds
the key behind its id, then connects two TCP streams that asked for the same id.

## 1. Roles

- **Phone**: the PocketDeck server inside the Shizuku shell process. It keeps one
  outbound *control connection* to the relay, kept alive by pings. When the relay says
  `incoming`, it opens a second connection to *accept*.
- **Mac**: opens one connection, asks the relay to connect it to a phone id, and then
  uses that connection as the byte stream.
- **Relay**: matches the two, verifies the phone's signature, and copies bytes both ways.

## 2. Identity

- Each phone has an **Ed25519** key pair, generated on the phone once. The private key
  never leaves the phone.
- `relayId` = lowercase base32 (RFC 4648 alphabet, no padding) of the first 16 bytes of
  SHA-256(pub). That is 26 characters from `a-z2-7`. The relay recomputes it from `pub`
  and rejects a mismatch.
- The Mac learns the `relayId` at pairing, together with the phone's pinned E2E keys.
  The id is not secret, but it is not published either.
- Encodings: `pub` and `sig` are standard base64 (with padding). `nonce` and `session`
  are lowercase hex.

## 3. Framing

The framing is the one in `docs/PROTOCOL.md`:

```
u32 len        // bytes that follow this field: type + stream + payload
u8  type
u32 stream
u8[len-5] payload
```

All integers are big-endian. Control messages use type `0x01` (JSON, UTF-8 object with
a string field `"t"`) and stream `0`. Control messages have no `stream` field.

Relay limits (stricter than the 8 MiB PROTOCOL.md ceiling, which the relay still obeys):

- A control frame is at most 64 KiB. A larger frame, a non-JSON type, or a non-zero stream
  on a control connection closes the connection with no reply.
- Malformed JSON, a missing `"t"`, or an unexpected `"t"` in the current state closes the
  connection with no reply. Unknown `"t"` values received after registration are ignored.
  Unknown fields are ignored everywhere.

**After a splice the connection carries raw bytes only.** There is no framing on a spliced
connection.

**Pipelining.** The Mac may send raw bytes immediately after its `connect` frame, and the
phone may send raw bytes immediately after its `accept` frame, without waiting for
`spliced`. The relay buffers them and forwards them in order after `spliced`. Clients
that do not need this must wait for `spliced` first.

## 4. Messages

Phone → relay (control connection):

| `t` | fields | notes |
|---|---|---|
| `register` | `v`=1, `id`, `pub`, `token` (may be empty or omitted) | first frame of a control connection |
| `proof` | `sig` | answers `challenge` |
| `ping` | — | at least every 4 min |
| `accept` | `v`=1, `session`, `id`, `sig` | first frame of a **new** connection (not the control connection) |

Relay → phone:

| `t` | fields | notes |
|---|---|---|
| `challenge` | `nonce` (32 hex = 16 bytes) | fresh per connection |
| `registered` | `observed` (`ip:port` the relay sees) | registration done |
| `pong` | — | answers `ping` |
| `incoming` | `session` (32 hex), `from` (Mac `ip:port` as seen by the relay) | on the control connection |
| `spliced` | — | on the accept connection, before any raw bytes |
| `error` | `code` | then close |

Mac → relay:

| `t` | fields | notes |
|---|---|---|
| `connect` | `v`=1, `id`, `token` (may be empty or omitted) | first frame of the connection |

Relay → Mac:

| `t` | fields | notes |
|---|---|---|
| `spliced` | — | raw bytes follow |
| `error` | `code` | then close |

Signatures:

- `proof.sig` = Ed25519 signature, made with the phone's private key, over the **16 raw
  bytes** obtained by hex-decoding the `challenge.nonce` string.
- `accept.sig` = Ed25519 signature over the **16 raw bytes** obtained by hex-decoding the
  `incoming.session` string.
- Verification uses the standard Ed25519 rules (RFC 8032, as implemented by Go's
  `crypto/ed25519`). The phone's public key is the one registered for `id`.

## 5. Flows

### 5.1 Phone registration

1. Phone opens a TCP connection and sends `register`.
2. Relay checks, in this order:
   1. `v` == 1, otherwise `version`.
   2. `pub` decodes to 32 bytes and `id` == relayId(pub), otherwise `auth`.
   3. If token enforcement is on, `token` is in the token list, otherwise `auth`.
3. Relay sends `challenge` with a fresh random nonce.
4. Phone sends `proof`. The relay verifies it. On failure: `error` `auth`, then close.
5. Relay sends `registered` with `observed`. The connection is now the phone's control
   connection and stays open.
6. The phone sends `ping` at least every 4 minutes. The relay answers `pong`.
   If nothing at all arrives for `--idle-timeout` (default 10 min), the relay closes the
   connection.
7. A newer registration for the same `id` replaces the older one. The relay closes the
   older control connection without an error frame. Phones must reconnect with backoff.
   Two phones sharing a key is a misconfiguration.

### 5.2 Mac connects, phone accepts

1. Mac opens a TCP connection and sends `connect`.
2. Relay checks, in this order:
   1. `v` == 1, otherwise `version`.
   2. Token enforcement (same rule as 5.1 step 2), otherwise `auth`.
   3. `id` is registered, otherwise `offline` and close. A malformed id is also `offline`.
   4. Session limits: `--max-sessions` total, `--max-sessions-per-id` per id, counting
      pending and spliced sessions. Exceeded: `limit` and close.
3. Relay creates a **random 128-bit session id** (32 hex), records it as pending, and
   sends `incoming` on the phone's control connection, with `from` = the Mac's address.
   If that write fails, the Mac gets `offline`.
4. The relay holds the Mac connection for up to 15 s (accept window).
5. Phone opens a **new** connection and sends `accept` with the `session` id, its `id`,
   and `sig` (section 4).
6. The relay looks up the pending session. Unknown or expired session → `error` `timeout`
   to the phone, then close. Then it checks `id` matches the session, and verifies `sig`
   against the registered key:
   - Bad signature or unknown id → `error` `auth` to the phone, then close. **The pending
     session is not consumed**, so the real phone can still accept.
   - Good → the session is claimed. The accept connection is handed to the Mac's handler,
     which splices (5.3).
7. If nothing is accepted within 15 s → `error` `timeout` to the Mac, then close. A late
   accept then gets `timeout` to the phone.

### 5.3 Splice

1. The relay sends `spliced` to the Mac and `spliced` to the phone's accept connection.
   Nothing else is sent to either side before this.
2. From then on the relay copies bytes in both directions with 32 KiB buffers (a
   `sync.Pool`), starting with whatever each side already sent (pipelining).
3. End of stream in one direction (`EOF`): the relay half-closes the other side (TCP
   FIN, or TLS close_notify when the relay itself speaks TLS). The other direction
   keeps running until it ends too.
4. Hard error in either direction (reset, write failure, idle timeout): close **both**
   connections immediately.
5. When both directions have finished, close both connections.
6. Idle: if neither direction moves bytes for `--idle-timeout` (default 10 min), close both.
   Each read and write also has a deadline, so a stalled peer cannot pin the session.
7. Optional rate limit (`--rate-limit-mbps`): a token bucket per session **per direction**.

Byte counts per token are recorded for billing (section 8).

### 5.4 Shutdown

On SIGTERM the relay stops accepting, closes control connections and pending Mac
connections (they get `offline`), and lets spliced sessions run for `--shutdown-grace`
(default 10 s). Then it force-closes whatever is left and exits 0.

## 6. Timers and limits

| What | Value | Where |
|---|---|---|
| First frame, and `proof` after `challenge` | 10 s | relay, fixed |
| Accept window (Mac held while waiting) | 15 s | relay, fixed |
| Phone ping interval | ≤ 4 min | phone |
| Control connection silence before drop | `--idle-timeout`, default 10 min | relay |
| Spliced session idle (no bytes either way) | `--idle-timeout`, default 10 min | relay |
| Shutdown grace | `--shutdown-grace`, default 10 s | relay |
| Max control frame | 64 KiB | relay |
| Max sessions (pending + spliced) | `--max-sessions`, default 1000 | relay |
| Max sessions per id | `--max-sessions-per-id`, default 4 | relay |
| Per-session rate, per direction | `--rate-limit-mbps`, default off | relay |

Buffers: each spliced direction uses one pooled 32 KiB buffer. Each control connection
uses one bufio reader. Nothing else is allocated per session.

## 7. Error codes

| code | sent to | meaning |
|---|---|---|
| `offline` | Mac | the phone id is not registered (or the relay is shutting down, or the id is malformed) |
| `timeout` | Mac, phone | no accept within 15 s; or a late/unknown session on accept |
| `auth` | phone, Mac | bad signature, id not matching pub, or a token that is not allowed |
| `limit` | Mac | session limits exceeded |
| `version` | both | `v` is not supported |

## 8. Operations

**Tokens.** `--tokens FILE` holds one token per line. Blank lines and lines starting with
`#` are ignored. Without `--tokens` the relay runs in **open mode**: tokens are not
checked and all bytes are counted under the label `open`. An empty token file also means
open mode, and the relay logs a warning at startup.

**Metrics.** The admin listener (`--admin`, default `127.0.0.1:9090`, `""` disables it)
serves plain text in Prometheus exposition format at `/metrics`:

- `pocketdeck_relay_registered_phones` (gauge)
- `pocketdeck_relay_pending_sessions` (gauge)
- `pocketdeck_relay_active_sessions` (gauge, spliced)
- `pocketdeck_relay_sessions_spliced_total` (counter)
- `pocketdeck_relay_errors_total{code="..."}` (counter)
- `pocketdeck_relay_bytes_total{token="..."}` (counter, both directions; label =
  first 12 hex chars of SHA-256(token), or `open`)

The admin listener is for the operator only. Bind it to loopback, or keep it on a private
network.

**Logs.** `log/slog` JSON to stderr. Logged: registrations (`relayId`, observed address),
connects and outcomes, splice start and end with byte counts. Never logged: payload bytes,
tokens, session ids, or signatures.

## 9. Threat model

**The relay can see:**

- Which `relayId` a Mac asks for, and when.
- The observed IP:port of both ends, the timing and duration of each session, and the
  bytes per direction.
- The token each client presents (if tokens are on), and the phone's public key.

**The relay cannot:**

- Read or change the E2E payload. The keys are pinned at pairing, and the relay holds none
  of them. A modified stream fails the TLS handshake and is dropped.
- Register as a phone. That needs the phone's Ed25519 private key.
- Make a Mac believe it is talking to a phone. The E2E pin fails.

**What a malicious relay (or network observer) can still do:**

- **Deny service**: drop, delay or refuse. Mitigation: multiple relays later; the phone
  retries with backoff.
- **Flood a phone with `incoming`**: anyone who learns a `relayId` can send `connect`. The
  phone should accept only when its E2E layer expects a paired Mac, drop unknown ones,
  and rate-limit accept attempts. Not enforced by the relay.
- **Exhaust the per-id session quota**, so the real Mac gets `limit`. Mitigation:
  tokens, and a per-source-address limit in front of the relay (not in v1).
- **Replay**: the register proof uses a fresh nonce per connection. The accept uses a
  fresh 128-bit session id that is claimed once. A replayed accept fails.
- **Metadata**: the operator knows who talks to whom, when, and how much. Self-hosting
  keeps that with the self-hoster. The outer TLS (built-in or Caddy) hides it from
  the network path, but not from the relay.
- **Token exposure**: without TLS, tokens travel in plaintext. Hosted deployments must use
  TLS. Plain TCP is for trusted networks or behind a TLS terminator.

**Key hygiene.** The phone's key signs 16-byte values chosen by others (the relay's nonce
and the session id). Do not use this key for anything else. Domain-separate any future
use.

## 10. v2 plan: P2P candidate exchange (not implemented)

The `observed` address in `registered` and `from` in `incoming` are the server-reflexive
addresses the relay sees. The same control channel can carry candidate exchange:

1. Both endpoints gather candidates: host (LAN address), and reflexive (from the relay).
2. `connect` gains `cands` (Mac candidates). `incoming` forwards them to the phone.
3. `accept` gains `cands` (phone candidates). The relay forwards them to the Mac as
   `peer` (`{"t":"peer","cands":[...]}`), then splices as in v1 at once, so E2E can start
   over the relay without waiting.
4. Both sides try direct UDP (QUIC, hole punching) using the candidates. The relay's
   address exchange is the signalling.
5. When the direct path is up and E2E has migrated to it, the relay session is closed. If
   the direct path fails, the relayed splice carries on as today.

Risks: UDP NAT mappings can differ from the TCP ones, and symmetric NATs or carrier-grade
NAT block hole punching, so the relay stays the fallback. v2 carries a `v`=2 field. A v1
relay answers `version` to v2 clients, and vice versa.
