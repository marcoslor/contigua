# e2ee — mutual TLS 1.3 (design, phase 1)

Launch blocker: docs/ROADMAP.md, "End-to-end encryption (P0)". Fixed decisions are
NOT reopened here (TLS 1.3 only; ECDSA P-256; self-signed certs; pinned at
pairing; protocol v2; no plaintext/v1 fallback; one forced re-pair; QR carries the
phone's certificate fingerprint; framing unchanged; keys never leave the device).
Answers the brief's 8 questions with spike evidence, then the phase-2 steps.
Spikes stay uncommitted in .agent/e2ee/spikes/ (s1-mac Swift, s2-jvm Java).

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
  see "Interop").
- The pin is NOT the cert's DER: Apple re-encodes certs (`SecCertificateCopyData`
  ≠ the DER we gave it) and BoringSSL/SunJSSE may normalize. The canonical pin is
  **SHA-256 over the 65-byte uncompressed EC point `04||X||Y`**, stable on all
  three stacks (Apple `SecKeyCopyExternalRepresentation`; BoringSSL/SPKI; Java
  `ECPublicKey.getW()` + 32-byte X||Y). The QR payload, the code and the pin
  store all use this fingerprint.
- Cert-generation detail learned the hard way: nil-out `notValidBefore=now`
  flapped `CERTIFICATE_VERIFY_FAILED`/`SSLV3_ALERT_CERTIFICATE_EXPIRED` across
  runs under BoringSSL's evaluator. Certs are generated with
  `notBefore = now−1 day`, `notAfter = now + 366 days` ("±1 day" margin) in both
  spikes; the same margin goes into phase 2 code.

## 2. Phone side: Conscrypt/JSSE `SSLContext` with in-memory identity; key over AIDL

- The shell-UID server gains a **TLS wrapper from `Socket` to `SSLSocket`**:
  `SSLContext` with an in-memory `KeyManagerFactory` (own identity) and a
  `TrustManagerFactory` whose store has only the peer Mac's cert; enforced
  `enabledProtocols = ["TLSv1.3"]`, `setNeedClientAuth(true)`.
- **Where the phone's identity lives**: the app process generates it (key + cert)
  once per provisioning (v2 first run), stores it in **the app's own private files
  dir** (mode 0600, belongs to UID dev.pocketdeck, FBE-encrypted at rest while the
  device is locked), and **passes it over the existing AIDL** to the shell service
  the same way pairing keys travel today (`setPairedClients` JSON gains
  `self: {certPem, keyP8}`), so the UID 2000 server never touches a file it cannot
  read. Private keys never leave the device and never enter logs (RULES; the
  design doc adopts "never stringify the KeyManagerFactory's material").
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

## 3. Mac private key at rest

`pairkeys.json` (0600, profile folder, same as today per ROADMAP's note) is
replaced by a **per-profile identity file** `identity.json`:
`{"deviceId": ..., "certPem": ..., "keyP8": ..., "pin": "<64 hex of the phone's
point fingerprint>", "pinVersion": 2}`.0600 in the 0700 profile folder, exactly
as pairkeys.json is treated now; Keychain returns when Wallet-style code signing
exists (ROADMAP). Migration: on first v2 run the old pairkeys.json is deleted
(the forced re-pair) and identity.json is created — no reverse path.

## 4. The pairing code: exact formula

The numeric code is display-only (never typed; the phone's Allow is the
confirmation, PROTOCOL.md). Both screens derive the SAME number ONLY if both saw
the other's true certificate — a MITM that swaps either cert changes at least one
side's code.

```
macFP   = SHA-256(04||X||Y of the Mac's   SPKI public point)   // 32 bytes
phoneFP = SHA-256(04||X||Y of the Phone's SPKI public point)
seed    = SHA-256("pocketdeck-code-v2" TLV:
            0x01 len=32 macFP   ordered so the SMALLER 32-byte value comes first
            0x02 len=32 phoneFP (the larger one)  [domain separation: prefix]
          )
code    = int(seed[0..7]) % 1_000_000 = 6 digits (zero-padded, displayed "123 456")
```

- Both sides compute at the same points: the Mac displays it together with
  `pair.code_shown`, the phone computes it from its own FP and the FP of the cert
  it received, then shows it on the prompt. Equal codes on both screens ⇔ no MITM.
- **Test vectors**: fixed named pairs (all-zero point ⇒ 471 108, and one
  realistic P-256 pair with its code) live as constants in BOTH spikes and must
  produce the same 6 digits on Swift and Java; phase 2 pins them as unit tests
  on both platforms (K1 JVM + swift test).
- `{t:"challenge"}` retains `id` but "nonce" is REMOVED — the Mac knows which pin
  to expect from `id` alone; auth/HMAC frames disappear entirely (fixed decision:
  the TLS pin replaces the HMAC auth).

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
  in TLS; Session.kt's phases HELLO/AUTH collapse to HELLO-READY (no challenge, no
  HMAC, no auth_failed); `deviceId` rides in `hello` on the Mac side / mDNS TXT;
  PairingStore.shapshots shrink to `{clientId,name}` only — no keyHex field.
- **AIDL** (`IDeckService.aidl`): `setPairedClients` JSON gains
  `"self": {"certPem": "...", "keyB64": "..."}`; keys never log and never cross a
  process boundary except over binder (device-local, same trust as today).
- **App (key gen + pin store + UI)**: Prefs.kt stores identity + per-Mac pin
  (fp→clientId,name); the pairing prompt shows the SAME 6-digit code (section 4)
  for code-pairing; the QR flow now RUNS FROM THE PHONE: it shows a QR
  (`pocketdeck://pair?c=<certFingerprint 64 hex>&n=<deviceId>&k=unused-empty`) and
  the Mac scans it (new Mac-side AVCaptureSession path in phase 2). Scanning is
  the consent on the Mac side; the phone keeps its Allow prompt after the first
  TLS connection completes (so a held-down spoofed phone screen still requires
  physical presence), but no code comparison.
- **Mac connection** (`Session.swift`): NWConnection replaced by
  `ClientBootstrap + NIOSSLClientHandler` + framing handlers; the pin store feeds
  `trustRoots` per phone; on a pin mismatch the session dies with an explicit
  "certificate changed" error (surfaced as "phone reinstalled — re-pair").
- **Mac key store**: pairkeys.json → identity.json (section 3).
- **mDNS/QrPairing on the phone side**: `_pocketdeck._tcp` TXT gains
  `fp64=<phone cert fingerprint>`; QrPairing.kt switches from parsing the Mac's
  key-carrying URI (gone) to *displaying* the phone's URI.
- **fakephone** (tools/fakephone/): Python `ssl` with temp cert files; TLS 1.3
  needs OpenSSL 3.x (`python3.11` on this machine; the system python3's LibreSSL
  2.8.3 has no TLS 1.3 — the check script passes an interpreter override env).
  Adds modes: wrong pin, bad cert, rotated cert; HMAC paths removed.
- **check-e2e.sh (mac e2e)**: `qr`, `pair`, `direct` (C3/C4/C10) reworked to the
  v2 pairing flows; `nickname`, `notify`, `audio`, `handoff` … only need the
  session bring-up changed (they don't care about the handshake, they rely on
  auth_ok/paired events which REMAIN — the events log gains "tls", "pin-mismatch"
  instead of "auth_failed"). NEW check `tls` replaces `auth`:
     1) plaintext refused (a plain TCP client connecting gets a TLS alert, never
        `welcome`),
     2) v1 client refused (`v=1` in `hello` → error `version`),
     3) wrong pin refused (fakephone's cert != pinned),
     4) a cert ROTATED on either side refused (re-pair needed),
     5) code equal on both screens (S2 spike + on-emulator check),
     6) relay sees ciphertext only (relay-loopback session; the relay's byte
        counters must show no readable `hello`/`_pocketdeck` strings).
- **PROTOCOL.md**: rewritten to v2 (the framing table stands; "Transport" changes:
  "TLS 1.3 required, cert pinning, no plaintext fallback"; "Session handshake"
  loses challenge/auth; "Pairing" reworked per section 2/4 above).
- **ARCHITECTURE.md**: diagram line "TCP server" → "TLS server (SSLEngine)";
  "pairing keys" → "identity + pins"; key decisions gains "TLS 1.3 at shell UID:
  Conscrypt/JSSE, in-memory identity pushed via AIDL".

## 7. Migration experience

- One forced re-pair per phone⇄Mac pair, before release. The Mac shows
  "PocketDeck updated its connection security — pair your phone again"; the
  phone's omnibox prompt pairs normally. Pair keys from v1 (`pairkeys.json`) are
  deleted on first v2 start (they authenticate nothing in v2 and MUST NOT be
  reused as pin data given both sides' certs replace them).
- **Stale pin** (phone reinstalled → phone cert regenerated): the Mac's
  connection dies at TLS verify with `certificate changed` (not a network
  error). The Mac surface: the phone row in "Nearby" gains a ⚠ "re-pair" hint;
  clicking Pair re-runs the pairing (code-driven); the old pin is deleted on
  successful re-pair. The phone's prompt says "Pair with <Mac name>?" as today —
  the human flow is unchanged. A pin-mismatch storm is rate-limited on the Mac
  (one re-pair-sheet auto-open per address per minute) so a hostile LAN address
  can't force a UI loop.

## 8. Phase-2 steps (ordered, ≤12, each with its own check)

1. **DER cert builder (Kotlin, JVM-testable)** + tests: minimal self-signed
   P-256 cert byte-exact (extensions: SAN/IP, EKU, BC) — K1's JVM tests only.
2. **Identity + pin store on the Mac** (identity.json, 0600, delete pairkeys;
   SwiftUI pin-mismatch surface) — swift unit test for the JSON round trip +
   fingerprint math (reuse of S1's pointFP code).
3. **NIOSSL transport on the Mac** — connection/controller wiring, pin
   enforcement (no pin present ⇒ refuse), session bring-up. Check: swift test
   with a loopback mock (reuse the spike harness) + K2 green.
4. **App-side identity gen + AIDL push (`setPairedClients` self)** — K1.
5. **Server TLS wrapper at shell UID** (SSLEngine/SSLSocket wrapper, KeyManager
   from binder material, TrustManager pin) — K1's JVM tests with an in-memory
   harness (S2-style).
6. **v2 handshake in Session.kt** (deviceId in hello; no challenge/HMAC;
   error `version` for v1) + code-derivation (Kotlin implementation of section 4)
   + unit test vectors — K1.
7. **Pairing state machine v2** on the phone (Allow prompt, QR display, code
   display); `pair.ok` gains `"macFP"` for the pin, `"relay"` is unchanged —
   K1 + `check-e2e.sh pair` rework on the tap of a fake phone.
8. **QR rework** (phone shows, Mac scans) + fakephone `--qr-uri` update —
   check-e2e.sh `qr` (C3).
9. **fakephone TLS mode + check-e2e.sh `tls`** (the 6-case matrix of section 6);
   needs the python3.11 baseline check-e2e precondition (`PD_FAKE_TLS_PYTHON`).
10. **check-e2e.sh all** green on the API-36 emulator (`tls`, pair, qr, plus all
    existing checks re-pointed off HMAC; the `direct` C10 keeps the "different
    device id refused" semantics via a pin mismatch).
11. **Throughput regression gate**: a 20 Mbit/s 64 KiB pre/post-TLS case against
    the emulator with CPU%/latency reports; catches Conscrypt regressions;
    (report numbers to docs/ROADMAP.md's device-QA cell).
12. **PROTOCOL.md + ARCHITECTURE.md rewrite & stakeholder sweep** — docs only
    (phase-2 task), commit with the implementation steps.

Out of scope for phase 2 (noted, not blocking): Keystore-grade key protection
(returns with signing), QUIC/P2P backends (REMOTE.md v2), certificate rotation
UI (a re-pair covers it).

## Spike artifacts + record of what failed

- .agent/e2ee/spikes/s1-mac/ — Swift spike v2 (NIOSSL): matrix 3/3 PASS, bench
  numbers above, interop to the JVM server OK. First-round Apple-TLS attempts
  preserved in spike-logs/ (in-memory SecIdentityCreate + custom file keychain
  both hang; `-9810` when peer auth is off), kept as the Q1 evidence trail.
- .agent/e2ee/spikes/s2-jvm/Spike2.java — SunJSSE TLS 1.3, mutual auth, pin by
  point FP; Java↔Java bench + interop with S1 (SunJSSE only because the spike
  runs on the JVM; Android's Conscrypt is BoringSSL and faster — phase 2 re-runs
  on-device before numbers go to ROADMAP).
  Spike time inside the 2 h budget; no item overran the 30-min stop rule without
  being recorded here.

Co-authored: this document, the two spikes and measured numbers above are the
deliverable of phase 1. No product code changed.
