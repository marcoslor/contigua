# e2ee — mutual TLS 1.3 (design, revision 2)

Launch blocker: docs/ROADMAP.md, "End-to-end encryption (P0)". Fixed decisions are
NOT reopened here (TLS 1.3 only; ECDSA P-256; self-signed certs; pinned at
pairing; protocol v2; no plaintext/v1 fallback; one forced re-pair; framing
unchanged; keys never leave the device).
Revision 2 applies the architect's review (.agent/e2ee/review1.md): R1 (blocker)
replaces the fingerprint-hash pairing code with commit/nonce/reveal over the TLS
exporter; R2 keeps the QR as Mac-shows/phone-scans (Mac fingerprint + one-time
secret); R3 disables resumption/0-RTT, adds key hygiene and drops the mDNS TXT
`fp64`. Answers the brief's 8 questions with spike evidence, then the phase-2
steps. Spikes stay uncommitted in .agent/e2ee/spikes/ (s1-mac Swift, s2-jvm Java).

Fixed decisions restated for rev 2: the QR is what the MAC shows and the PHONE
scans; it carries the Mac's certificate fingerprint `f` and a one-time secret
`s` (the phone pins the Mac by `f`). Certificate fingerprints travel in the
handshake and the pairing frames, not on the LAN.

## 1. Mac TLS stack: SwiftNIO-SSL (BoringSSL), NOT Network.framework

**Decision: SwiftNIO-SSL (+ SwiftNIO) for the Mac's TLS layer. In-memory keys, no
keychain anywhere.**

Evidence (spike s1-mac, two rounds):

- Round 1 — Apple's own stack (NWProtocolTLS) was driven through three identity
  paths: in-memory `SecIdentityCreate(cert, key)` (`SecKeyCreateRandomKey` with
  `kSecAttrIsPermanent:false`), a profile-scoped **file keychain**
  (SecKeychainCreate + keygen with `kSecUseKeychain` + SecItemAdd cert +
  SecItemCopyMatching identity), and hand-rolled DER certs (Apple has no public
  self-signed builder). Result: in all of them the TLS 1.3 handshake **stalls
  forever in `.preparing`** once the client's verify block accepts the server
  cert; with peer auth off the server conn dies with `-9810 errSecInternalError`.
  Software-backed identities are unusable with Network.framework TLS on macOS
  26.x; the only remaining route (keychain + ACL-managed items) contradicts
  "no default-keychain writes" + ad-hoc-signed dev builds (RULES 3). Evidence
  kept in .agent/e2ee/spikes/s1-mac/spike-logs/.
- Round 2 — **SwiftNIO-SSL 2.37.5 + SwiftNIO + swift-certificates** (SwiftPM):
  mutual TLS 1.3 with in-memory CryptoKit P-256 keys, self-signed certs
  (SAN, EKU server+client), pinning by per-side trust roots — matrix passes.
  No keychain, no entitlements. Cost: 6 SwiftPM packages, debug build +~30 s;
  BoringSSL vendored by the package (bundle +~6 MB). Session.swift's
  NWConnection moves to `NIOBootstrap + NIOSSLHandler + framing handlers`.
- Swift↔Java interop works (the Mac must talk to the phone's Conscrypt stack;
  see "Interop" and the exporter proof below).
- The pin is NOT the cert's DER: Apple re-encodes certs (`SecCertificateCopyData`
  ≠ the DER we gave it) and BoringSSL/SunJSSE may normalize. The canonical pin is
  **SHA-256 over the 65-byte uncompressed EC point `04||X||Y`**, stable on all
  three stacks (Apple `SecKeyCopyExternalRepresentation`; BoringSSL/SPKI; Java
  `ECPublicKey.getW()` + 32-byte X||Y). The QR payload, the code and the pin
  store all use this fingerprint.
- Cert-generation detail learned the hard way: nil-out `notValidBefore=now`
  flapped `CERTIFICATE_VERIFY_FAILED`/`SSLV3_ALERT_CERTIFICATE_EXPIRED` across
  runs under BoringSSL's evaluator. Certs are generated with
  `notBefore = now−1 day`; a new phone identity uses the RFC 5280
  "no well-defined expiration" date `notAfter = 9999-12-31T23:59:59Z`
  (GeneralizedTime in DER), so a pinned leaf never expires while the app's
  data lives (review L-5). Existing identities are never regenerated. (The
  phase-1 spikes used `now + 366 days`; the "±1 day" margin note was about
  `notBefore`.)
- **Exporter access (rev 2)**: NIOSSL has no public `SSL_export_keying_material`
  wrapper as of 2.37.5 (its vendor trims the wrapper; upstream issue
  apple/swift-nio-ssl#599 opened 2026-08 is exactly this gap). The vendored
  BoringSSL logs every TLS 1.3 secret through the keylog callback, including
  **`EXPORTER_SECRET <client_random> <hex>`** (ssl_lib.cc, ssl_log_secret;
  fired in tls13_derive_application_secrets). The Mac therefore takes the
  exporter the RFC-composed way: capture `EXPORTER_SECRET` from
  `TLSConfiguration.keyLogCallback` and run the §7.5 math with CryptoKit HKDF
  (`exportSecret(...)` helper, pure math, unit-testable). The spike proves the
  result byte-identical for the same session against Conscrypt's real
  `Conscrypt.exportKeyingMaterial` (see "Exporter interop"). Key log lines are
  secrets: the callback consumes them in memory, never writes them to disk or
  logs.

## 2. Phone side: Conscrypt/JSSE `SSLContext` with in-memory identity; key over AIDL

- The shell-UID server gains a **TLS wrapper from `Socket` to `SSLSocket`**:
  `SSLContext` with an in-memory `KeyManagerFactory` (own identity) and a
  `TrustManagerFactory` whose store has only the peer Mac's cert; enforced
  `enabledProtocols = ["TLSv1.3"]`, `setNeedClientAuth(true)`.
- **Where the phone's identity lives**: the app process generates it (key + cert)
  once per provisioning (v2 first run), stores it in **the app's own private files
  dir** (mode 0600, belongs to UID app.contigua, FBE-encrypted at rest while the
  device is locked), and **passes it over the existing AIDL** to the shell service
  the same way pairing keys travel today (`setPairedClients` JSON gains
  `self: {certPem, keyP8}`), so the UID 2000 server never touches a file it cannot
  read. The phone's private key therefore lives in app-private storage (0600
  in app data), not in the Android Keystore, and is handed to the shell process
  over that AIDL — the accepted risk for now (sec L-4). Private keys never
  leave the device and never enter logs (RULES; the
  shell server holds the PEM only in memory (R3 hygiene: it must never write the
  key to disk and never log it; the K1 test greps harness logs for the PEM header
  and the key's base64).
- **The Android Keystore is unusable here**: Keystore keys are per-UID and cannot
  be operated on at shell (UID 2000) — confirmed by the architecture docs; keys
  are therefore software keys. Protection at rest becomes: app sandbox (0600,
  FBE) + AIDL transport (binder), same threat model as today's pairing keys
  (they are 0600 files in app data today). This is a documented *weaker*
  guarantee than Keystore-backed hardware keys; accepting it in phase 1 is a
  fixed decision by the brief ("the app generates it and passes it over the
  existing AIDL").
- On-device **cert generation needs a DER builder**: Android has no Conscrypt
  cert builder and BouncyCastle is a ~3 MB APK cost we refuse. Phase 2 includes a
  small hand-rolled DER builder (deterministic, ~150 lines Kotlin; the same DER
  subset the Swift spike proved round-1; pinned tests for round-trip parse on
  Java/BoringSSL validate it). Spike S2 used `sun.security.x509` (JDK-only) to
  keep the spike cheap, as the phase-1 document is the only place that notes it.
- **Exporter on the phone (rev 3)**: `android.net.ssl.SSLSockets
  .exportKeyingMaterial(socket, label, context, length)` is **API 31**; the
  app's `minSdk` is 30. The call is guarded by
  `TlsExporter.exportSupported(Build.VERSION.SDK_INT)` (31+) and
  `SSLSockets.isSupportedSocket(socket)`. On API 30 the helper returns null
  and pairing fails closed with `pair_exporter`; the phone never reaches the
  missing method. The planned media plane would derive no keys either, and no
  media code exists in this merge. It operates on the platform `SSLSocket`, so the shell-UID
  server terminates each session on a **`SSLSocket`** (not `SSLEngine`) and asks
  that same socket for the 32 bytes after the handshake (§4b). No additional
  dependency — the `org.conscrypt: conscrypt-android` AAR route was rejected
  for size. The K1 JVM tests pin the §4b HKDF math as vectors (no TLS engine
  needed); the platform call itself is
  verified in K4 (emulator step 10).

## 3. Mac private key at rest

The Mac's private key lives in a **per-profile identity file** `identity.json`:
`{"deviceId": ..., "certPem": ..., "keyP8": ..., "pin": "<64 hex of the phone's
point fingerprint>", "pinVersion": 2}`.0600 in the 0700 profile folder; Keychain
returns when Wallet-style code signing exists (ROADMAP).

`pin` is a **mirror of the phone in use**, not the pin check: the per-phone
records in `pins.json` (§6) are the authority, and a connection verifies the
peer against the dialed phone's own record. The mirror is rewritten from that
record on a successful connect, on Settings ▸ Phones ▸ Use This Phone and after pairing,
and emptied when no record holds it. Since the mirror can name a different
phone (pairing A, then B, then using A again), the TLS gate must never compare
it with another phone's record.

## 4. The pairing code: commit / nonce / reveal over the TLS exporter (rev 2)

**Why not the rev-1 formula (the R1 blocker).** Deriving the code only from the
two static fingerprints lets a man in the middle grind it: with own keys M1
(toward the phone) and M2 (toward the Mac), the phone would display
H(M1, PhoneFP) and the Mac H(MacFP, M2). The attacker sees both fingerprints in
the handshakes, fixes M1, and generates P-256 keys for M2 until
H(MacFP, M2) mod 10^6 equals the phone's displayed code — about 10^6 keygens
(seconds to minutes), and it precomputes because the attack key is long-lived.
Belt-and-braces with the TLS exporter alone does not close it either: in TLS 1.3
the server picks its key share after seeing the client's, so a MITM (the server
side of the phone's channel) can still grind the *session* the same way.

**The fix (Bluetooth SSP-style numeric comparison, inside the TLS channel).**
The code is derived from material the attacker cannot fix *before it commits*:

1. After the TLS handshake (neither side has a pin yet), the phone sends
   `{"t":"pair.commit","c":hex(SHA-256("pd-commit-v2"||Np||phoneFP||macFP))}`
   with `Np` = 16 fresh random bytes.
2. The Mac replies `{"t":"pair.nonce","n":hex(Nm)}`, `Nm` = 16 fresh random
   bytes — sent only AFTER it received the commit.
3. The phone sends `{"t":"pair.reveal","n":hex(Np)}`; the Mac recomputes the
   commit hash from the revealed `Np` and both fingerprints; mismatch (or a
   reveal arriving before/without a verified commit) closes the connection with
   the error `pair_commit`.
4. Both sides then derive the same number:

```
exporter = TLS-Exporter("EXPORTER-contigua-pair", empty context, 32 bytes)
           (RFC 8446 §7.5, from exporter_master_secret — see section 4b)
code = uint64_be(SHA-256("pd-code-v2" || exporter || macFP || phoneFP
                          || Nm || Np)[0..8]) mod 1_000_000     // 6 digits, shown "123 456"
```

Numeric-comparison ordering (both screens show `code`): the phone derives it at
reveal time and shows it with its Allow prompt; the Mac derives it on the
verified reveal and shows it next to the phone row. Equal codes on both screens
⇔ no MITM; this is the same property Bluetooth SSP gets from its channel, here
the channel is the TLS exporter and the Fresh nonces.

**Why the grinding fails now.** The Mac releases `Nm` only AFTER the attacker's
`pair.commit` is on record, and the code mixes in the session's exporter with
fresh-per-session keys. So a candidate (M2 key, `Np`) is only good for the one
session it was committed in: the attacker can still grind, but every attempt
needs a fresh TLS handshake on both legs, a fresh `Np` hash-locked before `Nm`
exists, and it always produces a visible pairing prompt on the phone;
per-attempt success chance stays 1 in 10^6 and nothing carries over (no
precomputation table). `pair.commit` also covers `phoneFP||macFP`, so a spliced
victim pair never survives the Mac's rehash at reveal ( → `pair_commit`).

- `pair.commit`/`pair.nonce`/`pair.reveal` exist only in the pairing state
  machine (section 8, step 7); steady-state sessions never send them.
- `{t:"challenge"}` is REMOVED entirely; `id` stays on the hello frames and "nonce"
  is REMOVED from the challenge (there is no challenge anymore). Auth/HMAC
  frames disappear (fixed decision: the TLS pin replaces the HMAC auth).
- **Test vectors (identical constants in Kotlin AND Swift tests)**:

```
vector A (all zero):  exporter=macFP=phoneFP=00*32, Nm=Np=00*16
  commit SHA-256("pd-commit-v2"||Np||phoneFP||macFP)
          = 4db996acf8699876c00680a004258f80b6027b3e486fef58cbd47b3c4c2d55b0
  code preimage hash
          = f28c00a27dc8c40011fa37bc093e4681ca8bde98fc8f84454a3aa21cc4f9d578
  code    = 063680
vector B (realistic):
  exporter = SHA-256("pd-v2-vector exporter") = 8198969f9157f30874bf2dc035c9f6ba2b789e635f831f3a981706a08649f0fd
  macFP    = SHA-256("pd-v2-vector mac")      = 20ac3461fdd5af5cc0b6c0c7ca6cf2df8edb8eb1322096c3fc9e06297e97dc41
  phoneFP  = SHA-256("pd-v2-vector phone")    = 88227c41edbdf92b83c27bff6ae8570eb14144050a5b0903e351a777e09ecfe5
  Nm       = SHA-256("pd-v2-vector Nm")[0..16]  = 3fb962da6c0eaaee44a7a16a2bcf9c97
  Np       = SHA-256("pd-v2-vector Np")[0..16]  = 3341237e0f5483a474b2c4e1f67c1648
  commit   = 1416bfb0ad52d1e41616118ef7a672aca9bd2bd1c8bf72dde845536749ca53f0
  code preimage hash = 826dde3dd5847d43a449eb3158908849c2205bc56cbcab124f3dac041018a8ae
  code     = 694339
```

These pin the KDF order ("pd-code-v2", then exporter, then macFP, then phoneFP,
then Nm, then Np), the uint64 big-endian read and the mod 1 000 000; JVM and
swift tests MUST hardcode these six-digit codes and the commit hashes as
constants (no computed vectors at test time).

## 4b. The TLS exporter, exactly

RFC 8446 §7.5: `TLS-Exporter(label, context_value, key_length) =
HKDF-Expand-Label(Derive-Secret(Secret, label, ""), "exporter",
Hash(context_value), key_length)`, `Secret = exporter_master_secret`,
`Derive-Secret(S, l, "") = HKDF-Expand-Label(S, l, Hash(""), Hash.length)`.
No context: `context_value` is zero-length and Hash("") is used both places
(same value as an empty context in TLS 1.3). So, label `EXPORTER-contigua-pair`:

```
inner     = HKDF-Expand-Label(exporter_secret, "EXPORTER-contigua-pair", SHA-256(""), 32)
exporter  = HKDF-Expand-Label(inner, "exporter", SHA-256(""), 32)      // 32 bytes
```

(verified against the vendored BoringSSL `tls13_export_keying_material` in
tls13_enc.cc: first `hkdf_expand_label(secret, label, export_context)`, then
`hkdf_expand_label(out, "exporter", hash)` — the RFC's structure, one
HKDF-Expand per step, `export_context = hash = SHA-256(empty)` here.)

Acquisition per stack (both are named by the review):
- **Mac (SwiftNIO-SSL)**: `TLSConfiguration.keyLogCallback` delivers BoringSSL's
  keylog lines; the line `EXPORTER_SECRET <client_random 64hex> <secret 64hex>`
  carries `exporter_secret` for the session; the `exportSecret(...)` helper runs
  the two HKDF-Expand-Label steps above with CryptoKit. Pure math = unit vectors
  (K2). Use: only on the freshly-completed pairing session, consumed in memory.
- **Phone (Conscrypt)**: `android.net.ssl.SSLSockets.exportKeyingMaterial(
  sslSocket, "EXPORTER-contigua-pair", empty context, 32)` on the platform
  `SSLSocket` (public SDK API, **API 31+**; `isSupportedSocket` guard, plus a
  `Build.VERSION.SDK_INT >= 31` guard because minSdk is 30). JVM unit vector
  (K1) pins the HKDF math; the on-device engine call is K4.

## 5. Cost on the video path: negligible at 20 Mbit/s

Loopback, 64 KiB framed pushes at full rate, mutual TLS 1.3 with pins (both spikes):

| metric | S1 (Swift NIOSSL/BoringSSL, macOS 26.2, M-series) | S2 (JDK 17 SunJSSE loopback proxy for Conscrypt) |
|---|---|---|
| throughput (server-received) | **3578.8 Mbit/s** (0.9 GB in 2.0 s) | **385.9**–**400.1 Mbit/s** (150 MB in 3.0 s) |
| through 20 Mbit/s target | ≤ 1 % of a core (extrapolated: client CPU 1.95 s for ~0.9 GB ⇒ ~17.7 µs/MB) | 99.4 % of one core sustains 400 Mbit/s ⇒ ~5 % of one core at 20 Mbit/s |
| RTT p50 / p95 (small pings) | **0.15 ms / 0.20 ms** (n=200) | ≈0–1 ms (ms-granularity clock hides sub-ms) |
| memory at full rate | RSS ~17 GB when flooding (NIO allocs per write; a phase-2 note, no blocker at 20 Mbit/s) | ~160 MB |

Interpretation: doors are wide open — the TLS layer is nowhere near the video
path's needs (one 60 fps 1080p stream is ~8 Mbit/s; the ROADMAP's remote cap is
2 Mbit/s). The true costs phase 2 will profile on-device are Conscrypt vs
SunJSSE deltas and the emulator's crypto budget, which these numbers bound from
above (Conscrypt ships BoringSSL, the same engine that hit 3.5 Gbit/s on the Mac).

## 6. Everything that changes (component list)

- **Phone server** (`android/.../server/`): Server.kt wraps each accepted Socket
  in TLS (platform Conscrypt/JSSE, section 2); Session.kt's phases HELLO/AUTH
  collapse
  to HELLO-READY (no challenge, no HMAC, no auth_failed); a **pairing path**
  appears (section 4): `pair.commit` → `pair.nonce` → `pair.reveal` for code
  pairing; QR pairing accepts the phone's `pair.qr` HMAC instead.
  `deviceId` rides in `hello` on the Mac side; mDNS TXT shows deviceId/name ONLY
  (R3: no `fp64` — the fingerprint is a tracking identifier on open Wi-Fi).
- **AIDL** (`IDeckService.aidl`): `setPairedClients` JSON gains
  `"self": {"certPem": "...", "keyB64": "..."}`; keys never log and never cross a
  process boundary except over binder (device-local, same trust as today).
- **App (key gen + pin store + UI)**: Prefs.kt stores identity + per-Mac pin
  (fp→clientId,name); the pairing prompt shows the §4 code; the phone
  **scans** the Mac's QR (unchanged direction, QrScan.kt) which now carries
  `contigua://pair?c=<clientId>&n=<name>&f=<macFP hex 64>&s=<S hex 32>`
  (R2: f = the pin the phone stores for the Mac; s = one-time 128-bit secret,
  regenerated each time the Mac opens the QR and expired with it). The phone's
  Allow prompt stays the human confirmation.
- **Mac connection** (`Session.swift`): NWConnection replaced by
  `ClientBootstrap + NIOSSLClientHandler` + framing handlers; the pin store feeds
  `trustRoots` per phone; on a pin mismatch the session dies with an explicit
  "certificate changed" error (surfaced as "phone reinstalled — re-pair").
  **TLS 1.3 only, session resumption and 0-RTT disabled** (R3): the client never
  sends `pre_shared_key`, the config pins min=max TLSv1.3; the open-io path
  treats a resumed (PSK) handshake as an error and re-handshakes from scratch —
  a fakephone test asserts the full-handshake path completes (section 6, `tls`).
- **Mac key store**: identity.json (section 3); Mac-side identity files keep the
  QR secret `s` in RAM only (never written — regenerate per QR).
- **Exporter on both stacks**: section 4b (Mac: keylog EXPORTER_SECRET + HKDF;
  phone: `android.net.ssl.SSLSockets` on the platform SSLSocket). The label is
  carried in protocol code as a constant.
- **QR flow reworked (R2)**: the Mac's **QRPairing.swift keeps generating** the
  QR (now with c/n/f/s); the phone's QrScan.kt keeps scanning; after the scan the
  phone connects and MUST authenticate by sending
  `{"t":"pair.qr","m":hex(HMAC-SHA256(S, "pd-qr-v2"||exporter||phoneFP))}` on the
  fresh TLS channel; the Mac (which knows S, issued it with the QR) verifies, and
  pins the phone's fingerprint from the client-cert handshake. No code
  comparison on this path; the phone's Allow prompt still gates the first
  connection.
- **fakephone** (tools/fakephone/): Python `ssl` with temp cert files; TLS 1.3
  needs OpenSSL 3.x (`python3.11` on this machine; the system python3's LibreSSL
  2.8.3 has no TLS 1.3 — the check script passes an interpreter override env).
  Adds modes: wrong pin, bad cert, rotated cert, **stale session ticket (the
  resumption attempt)**; HMAC paths removed.
- **check-e2e.sh (mac e2e)**: `qr`, `pair`, `direct` (C3/C4/C10) reworked to the
  v2 pairing flows; `nickname`, `notify`, `audio`, `handoff` … only need the
  session bring-up changed (auth_ok/paired events REMAIN — the events log gains
  "tls", "pair_commit", "pin-mismatch" instead of "auth_failed"). NEW check `tls`
  replaces `auth`:
     1) plaintext refused (a plain TCP client connecting gets a TLS alert, never
        `welcome`),
     2) v1 client refused (`v=1` in `hello` → error `version`),
     3) wrong pin refused (fakephone's cert != pinned),
     4) a cert ROTATED on either side refused (re-pair needed),
     5) code equal on both screens (spike + K4 emulator),
     6) relay sees ciphertext only (relay-loopback session; the relay's byte
        counters must show no readable `hello`/`_contigua` strings),
     7) resumption attempt does a FULL handshake: fakephone replays a stale
        ticket/PSK identity; the session must complete with a fresh,
        non-resumed handshake (observable: new exporter, `pairing` prompt, no
        0-RTT acceptance) — R3's requirement,
     8) server logs contain no key material: the log capture is grepped for
        `-----BEGIN PRIVATE KEY-----` and the phone key's base64 → zero hits
        (R3 hygiene; the K1 JVM test mirrors this on the Android engine).
- **PROTOCOL.md**: rewritten to v2 (the framing table stands; "Transport" changes:
  "TLS 1.3 required, cert pinning, no plaintext fallback, no resumption/0-RTT";
  "Session handshake" loses challenge/auth; "Pairing" reworked per section 4 and
  the R2 QR).
- **ARCHITECTURE.md**: diagram line "TCP server" → "TLS server (SSLEngine)";
  "pairing keys" → "identity + pins"; key decisions gains "TLS 1.3 at shell UID:
  Conscrypt/JSSE, in-memory identity pushed via AIDL".

## 7. Re-pairing and stale pins

- **Stale pin** (phone reinstalled → phone cert regenerated): the Mac's
  connection dies at TLS verify with `certificate changed` (not a network
  error). The Mac surface: the phone row in "Nearby" gains a ⚠ "re-pair" hint;
  clicking Pair re-runs the pairing (code-driven); the old pin is deleted on
  successful re-pair. The phone's prompt says "Pair with <Mac name>?" as today —
  the human flow is unchanged. A pin-mismatch storm is rate-limited on the Mac
  (one re-pair-sheet auto-open per address per minute) so a hostile LAN address
  can't force a UI loop.

## 8. Phase-2 steps (ordered, 13, each with its own check)

K1 = `cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@17 ./gradlew -q
:app:assembleDebug :app:testDebugUnitTest`; K2 = `cd macos && swift build &&
swift test`; e2e = `PD_E2E_PORT=... ./scripts/check-e2e.sh <check>`.

1. **DER cert builder (Kotlin, JVM-testable)** + tests: minimal self-signed
   P-256 cert byte-exact (extensions: SAN/IP, EKU, BC) — K1's JVM tests only.
2. **Identity + pin store on the Mac** (identity.json, 0600; SwiftUI
   pin-mismatch surface) — swift unit test for the JSON round trip +
   fingerprint math (reuse of S1's pointFP code).
3. **NIOSSL transport on the Mac** — connection/controller wiring, pin
   enforcement against the dialed phone's record (no record ⇒ refuse, record
   without its cert ⇒ refuse), TLS 1.3-only config, resumption/0-RTT
   off, and the `exportSecret(...)` helper (§4b) with unit vectors. Check:
   swift test with a loopback mock (reuse the spike harness) + K2 green.
4. **App-side identity gen + AIDL push (`setPairedClients` self)** — K1.
5. **Server TLS wrapper at shell UID** (SSLSocket wrapper using platform
   Conscrypt via the SDK TLS stack, KeyManager from binder material,
   TrustManager pin; never write the key, never log it — hygiene test) — K1's
   JVM tests with an in-memory harness (S2-style).
6. **v2 handshake in Session.kt** (deviceId in hello; no challenge/HMAC; error
   `version` for v1) + code-derivation (Kotlin implementation of §4 with the
   **identical constants**) + the exporter acquisition helper (platform
   `SSLSockets.exportKeyingMaterial`, guarded; JVM HKDF vectors as the K1
   check) — K1.
7. **Pairing state machine v2** on the phone (commit/nonce/reveal, Allow prompt,
   code display, `pair.qr` HMAC accept path, `pair.ok` gains `"macFP"`,
   `"relay"` unchanged; error `pair_commit` on a bad reveal) — K1 + `pair` e2e
   rework on the tap of a fake phone.
8. **QR rework** (Mac QR with f + one-time s; phone scans and answers `pair.qr`)
   + fakephone `--qr-uri` update — e2e `qr` (C3).
9. **fakephone TLS mode + `tls` check matrix** (the 8 cases of section 6,
   including resumption-full-handshake and the log-hygiene grep); needs the
   python3.11 baseline check-e2e precondition (`PD_FAKE_TLS_PYTHON`).
10. **K4 emulator**: real TLS 1.3 handshake on the platform Conscrypt stack and
    exporter bytes equal on both ends via `SSLSockets.exportKeyingMaterial`
    (§2) + code pairing with the Mac e2e app; the step that proves the phone's
    exporter call on-device.
11. **check-e2e.sh all green** (fakephone): the remaining checks re-pointed off
    HMAC (`nickname`, `notify`, `audio`, `handoff`, `direct` …; `direct` C10
    keeps the "different device id refused" semantics via a pin mismatch).
12. **Throughput regression gate**: a 20 Mbit/s 64 KiB pre/post-TLS case against
    the emulator with CPU%/latency reports; catches Conscrypt regressions;
    (report numbers to docs/ROADMAP.md's device-QA cell).
13. **PROTOCOL.md + ARCHITECTURE.md rewrite & stakeholder sweep** — docs only
    (phase-2 task), committed with the implementation steps.

Out of scope for phase 2 (noted, not blocking): Keystore-grade key protection
(returns with signing), QUIC/P2P backends (REMOTE.md v2), certificate rotation
UI (a re-pair covers it).

## 9. Exporter interop proof (rev 2 step 0)

Requirement (R1): BOTH stacks must expose the RFC 8446 exporter with the same 32
bytes for the same session, Swift client ↔ JVM server, label
`EXPORTER-contigua-pair`, empty context.

Spike modes added (kept in .agent/e2ee/spikes/, uncommitted):
- s1-mac: `Spike exporter-client --port P` — NIOSSL client, keylog callback,
  `exportSecret(...)` per §4b, waits for the phone's `0xFE` proof frame, prints
  `s1 exporter= <64 hex>`( + rereads the keylog once from a second derivations
  route for stability).
- s2-jvm: `java -cp .:conscrypt-openjdk-uber-2.5.2.jar Spike2 exporter-server
  [port]` — Conscrypt provider (the phone engine's JVM proxy; the production
  route is `android.net.ssl.SSLSockets`), mutual TLS 1.3, prints
  `s2 exporter= <64 hex>` via `Conscrypt.exportKeyingMaterial(..., 32)`.
- Result (this machine, JDK 17, SwiftNIO-SSL 2.37.5 vs Conscrypt 2.5.2-uber):
  **same 64-hex string** on both lines for the same session (log kept in
  spike-logs/), across repeated runs. This is the proof the phase-2 export
  paths (Mac: keylog+HKDF / phone: `SSLSockets.exportKeyingMaterial`) are
  RFC-equal; the destination for production code is steps 3/6, and K4 re-proves
  the phone on-device.

## 10. The reset rule (Clear data, uninstall, Forget All Macs)

The phone's identity and its pinned Macs belong to the **app process**; the
shell-UID server (Shizuku user service) only borrows them, and it outlives the
app. Settings ▸ Apps ▸ Clear data kills the app and deletes `filesDir`, but the
shell process kept serving the old identity and paired list from memory — the Mac
stayed connected after the reset, and a reconnect kept working. The rule that
closes it:

- The app pushes `identityFp` (SHA-256 of the identity certificate's 65-byte
  point) with the paired set on every bind and every change (`setPairedClients`).
  The shell recomputes the fingerprint from the pushed certificate and trusts the
  declared value only when the two agree; a push without a usable identity is
  treated as the app being gone.
- `AppLink` (server package) is the shell's state machine: `Unlinked` (serves
  nothing) or `Linked(identityFp, certPem, keyP8, pairs)`. One pure transition
  function `(state, event) -> (state, actions)` over `AppPushed`, `AppGone` and
  `PhonePaired`; a push that keeps the same fingerprint and the same set of pins
  changes nothing, any other push or a death drops the live session and forgets
  the cached TLS material, then adopts the new state.
- **Detection**: the app's `IDeckCallback` binder is watched with
  `Binder.linkToDeath`, so the shell learns of Clear data, uninstall or a kill
  immediately. That works on API 30–36 with no broadcast permission, no package
  query and no polling; `ACTION_PACKAGE_DATA_CLEARED` is not delivered to a
  process without a real app context (the user service has none), and a `pm`
  probe would be a poll. The binder dying and the data being cleared are the same
  event for the app (its process ends), so the shell does not need to tell them
  apart: it stops serving either way, which is the fail-closed rule.
- While unlinked the listener stays bound but every connection is closed before
  TLS (there is no identity to present). A relaunch pushes again: the same
  fingerprint and pins resume serving; a new identity (Clear data) starts from
  an empty paired set, so the Mac must pair again.
- **Teardown is a hand-off.** `Server.dropSessions()` takes the live session out
  of its slot and closes it on one daemon thread; `Session`'s teardown is one
  state machine (Live → Ending → Dropped → Finished) and a drop cuts the plain
  socket under TLS at once, then closes the TLS socket on that daemon. Both are
  needed: the app's push is a binder call that can be on the app's UI thread
  (Forget All), and the platform TLS socket's own close waits for a reader
  blocked in `SSL_read` — a live session has no read timeout — so it can take as
  long as the Mac stays away.
- **Nothing for a reset runs on the app's UI thread.** Forget All empties the
  list at once, then rotates the identity and pushes from a background thread,
  the push after the rotation. The push is a binder call the shell answers, and
  the shell's close can wait on the Mac, so the UI thread waits for neither.
- **Forget All Macs…** rotates the identity in the app (`PhoneIdentity.rotate`)
  and empties the paired list; the next push therefore differs and the same
  transition drops the session. The advertised device id is unchanged, so the
  Mac's pin (the pinned phone certificate) fails to verify → `pin-mismatch` →
  Pair again (PAIR-14). Clear data also regenerates the advertised id, so the Mac
  sees a new phone and pairs afresh; either way nothing on the phone accepts the
  Mac without the person's Allow.

## Spike artifacts + record of what failed (phase 1)

- .agent/e2ee/spikes/s1-mac/ — Swift spike v2 (NIOSSL): matrix 3/3 PASS, bench
  numbers above, interop to the JVM server OK. First-round Apple-TLS attempts
  preserved in spike-logs/ (in-memory SecIdentityCreate + custom file keychain
  both hang; `-9810` when peer auth is off), kept as the Q1 evidence trail.
- .agent/e2ee/spikes/s2-jvm/Spike2.java — SunJSSE TLS 1.3, mutual auth, pin by
  point FP; Java↔Java bench + interop with S1 (SunJSSE only because the spike
  runs on the JVM; Android's Conscrypt is BoringSSL and faster — phase 2 re-runs
  on-device before numbers go to ROADMAP). Rev 2 adds the Conscrypt uber-jar
  exporter-server mode (section 9).
  Spike time inside the 2 h budget; no item overran the 30-min stop rule without
  being recorded here.

Co-authored: this document, the two spikes and measured numbers above are the
deliverable of phase 1; revision 2 documents the review fixes and the exporter
proof. No product code changed yet (phase-2 steps follow in order).
