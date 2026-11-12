# Threat model

Contigua is a pre-release alpha. This page restates what the repository's own
docs say about security. Each claim cites its source. Where the docs are
silent or disagree with the code, the item is under "Open questions" and is
not guessed. To report a problem, see [SECURITY.md](../SECURITY.md).

Sources: [PROTOCOL](PROTOCOL.md), [ARCHITECTURE](ARCHITECTURE.md),
[e2ee](design/e2ee.md), [mcp](design/mcp.md), [files](design/files.md),
[links](design/links.md), [REMOTE](REMOTE.md), [ROADMAP](ROADMAP.md),
[AGENTS](../AGENTS.md).

## What is in the system

- A Mac app. A phone app. A phone server that runs as shell UID 2000 inside
  Shizuku and holds the TCP session (ARCHITECTURE, "The phone side").
- One LAN session per phone: mutual TLS 1.3, both certificates pinned
  (PROTOCOL, "Transport").
- Optional pieces on the Mac: a local MCP socket (mcp, "Transport"), a File
  Provider extension, and a Share extension (files, links).

## Assets

| Asset | Where it lives | Source |
|---|---|---|
| Phone screen content and input | Streamed over the session; input is injected by the shell-UID server | ARCHITECTURE, "Streaming" |
| Phone shared storage | Reachable only through the optional Finder location, minus `Android/` and dot-prefixed top-level names | PROTOCOL, "Phone files"; files §4 |
| Notifications, Now Playing, clipboard | Off until a person switches them on | AGENTS "Never trade away"; ARCHITECTURE, "Notifications"; specs/share-clipboard SHARE-13 |
| Mac identity key | `identity.json`, mode 0600, in a 0700 profile folder; not in Keychain | e2ee §3 |
| Pins (peer certificate fingerprints) | `pins.json` on the Mac (0600); app-private storage on the phone | ARCHITECTURE, "The Mac side"; specs/pairing PAIR-1 |
| Phone identity key | App-private files dir, then handed to the shell process over AIDL, held in memory there | e2ee §2 |
| The phone staying locked | Contigua never unlocks it or dismisses the keyguard | AGENTS "Never trade away" |
| Logs | Ids, counts, sizes, states, durations and error codes only | AGENTS "Never trade away" |

## Trust boundaries

1. **Mac to phone, over the LAN.** Everything is inside mutual TLS 1.3 with
   pinned certificates. No plaintext phase, no v1 fallback, no session
   resumption, no 0-RTT. A peer whose certificate is not the pin is refused
   (PROTOCOL, "Transport", "Session handshake").
2. **Phone app process to phone shell process.** The app (its own UID) pushes
   identity and pins to the shell-UID server over AIDL (ARCHITECTURE, "The
   phone side"; e2ee §2). The shell server serves only what the app currently
   vouches for, and stops when the app is gone (e2ee §10; specs/pairing PAIR-19).
3. **Mac app to Mac extensions and agents.** The MCP socket (0600 in a 0700
   folder, same-uid check) and the File Provider's App Group socket (0600,
   same-uid check) are local, same-user channels (mcp, "Transport"; files §2
   "Bridge wire"; files §4).
4. **The phone's trust in the Mac.** The phone treats the Mac as untrusted
   input: it validates every field and closes on an oversized frame
   (files §4).

## Attackers

### Attacker on the same LAN

Can do:

- See the Bonjour advertisement `_contigua._tcp` with `id`, `name` and `model`
  in the TXT record. No fingerprint is advertised (PROTOCOL, "Transport").
- Connect to the phone's TCP port. The phone binds all interfaces on an
  ephemeral port (code: `Server.kt`, `bind(InetSocketAddress(0))`).
- Make the phone show a pairing prompt, if "Allow new pairings" is on. After a
  Deny or a 120 s timeout the phone refuses new requests from an unpaired Mac
  for 30 s (PROTOCOL, "Code flow" step 7).
- Try a man-in-the-middle at pairing. Each attempt needs a fresh handshake on
  both legs and shows a prompt on the phone. The chance per attempt is stated
  as 1 in 10^6 (e2ee §4).

Cannot do:

- Read or change session traffic, or resume a session (PROTOCOL, "Transport").
- Get a reply from the phone unless its certificate matches a stored pin. Any
  other peer is closed without a reply once TLS completes (PROTOCOL, "Session
  handshake" step 3).
- Pair without a person tapping Allow on the phone (specs/pairing PAIR-11;
  PROTOCOL, "Pairing").
- Use a pairing code or QR for more than one session. The QR secret is
  one-time and expires after 5 minutes (PROTOCOL, "QR flow"; specs/pairing
  PAIR-9).

### A malicious app on the phone

The docs do not model this attacker directly. What they do say:

- The phone's private key is in app-private storage, not in the Android
  Keystore, and is passed to the shell process over AIDL. The doc calls this a
  weaker guarantee and "the accepted risk for now" (e2ee §2).
- The app disables backup (code: `allowBackup="false"` in the manifest).
- A malicious app can reach the TCP port like any LAN peer, and is then
  limited as in the LAN case above.

See Open questions 3 and 4.

### Another user or process on the Mac

- A different uid cannot connect to the MCP socket or the Files socket. Both
  check the peer uid with `getpeereid` (mcp, "Transport"; code:
  `MCPServer.swift`, `FilesBridge.swift`).
- The identity key and the pins are plain files (0600) in a 0700 folder, not
  in the Keychain (e2ee §3). File permissions keep other users out. The docs
  do not say what a process running as the same user can do. See Open
  question 5.

### An AI agent connected over MCP

Gate: off by default. While off, the socket does not exist. While on, the menu
bar shows an indicator and a "Disconnect agent" action. Up to four clients
(mcp, "Gate and visibility", "Protocol").

Can do (mcp, "Threat model"):

- Read phone state and the app list.
- Open, list and close windows.
- Take a screenshot of the last displayed frame of any window.
- Tap, swipe, long-press, type and press keys in any window.
- Send an http, https, geo, tel or mailto link.
- Send one regular file that the Mac user can read, up to the drop cap.

The doc says this equals a person at the Mac with the same windows open, plus
the ability to read a screenshot.

Cannot do (mcp, "Threat model"):

- Read notifications, media sessions or clipboard contents.
- Open arbitrary file URLs on the phone.
- Read or change pairings, identity keys or defaults.
- Write files on the Mac, run shell commands or launch Mac apps.
- Reach the phone except through the existing paired, encrypted session.

Logging: one line per tool call, name and duration only. No arguments, text,
URLs, file names or pixels (mcp, "Gate and visibility").

Every process running as the same user can connect while the setting is on.
The docs describe no per-client authentication. See Open question 6.

### A relay operator

The relay is **not part of the current build**. REMOTE.md specifies it, and
says phone and Mac integration comes after end-to-end encryption (REMOTE,
header). The ARCHITECTURE doc calls it "a later, optional milestone". The
repository has no `relay/` directory. What REMOTE.md says about a relay
(REMOTE §9):

Can see: which `relayId` a Mac asks for and when, both ends' IP and port,
session timing, bytes per direction, tokens (if on), and the phone's public
key.

Cannot: read or change the end-to-end payload, register as a phone without its
Ed25519 key, or make a Mac believe it talks to a phone (the pin fails).

Can still: deny service, flood a phone with `incoming` (not limited by the
relay), use up a phone id's session quota, and learn who talks to whom. REMOTE.md
says tokens travel in plaintext without outer TLS.

See Open question 7.

## Known limits, stated plainly

- Pairing is only as strong as the person comparing two six-digit codes and
  tapping Allow (PROTOCOL, "Pairing").
- The phone's identity key is software-held, passed over AIDL, and held in
  memory in the shell process (e2ee §2). The Mac's key is a file (e2ee §3).
- The server runs as shell UID 2000. That UID can read more than a normal app,
  including other apps' `Android/data` trees. The Files feature hides
  `Android/` and dot-prefixed top-level names, which files §4 describes as a
  boundary between "phone storage" and "what only uid 2000 can see", not a
  privacy boundary inside the person's own device.
- The phone's name, model and id are visible on the LAN while it advertises (PROTOCOL, "Transport").
- Android blanks secure surfaces (such as the PIN pad and `FLAG_SECURE` apps)
  in a capture. They arrive black (PROTOCOL, "Secure screens"). This is a
  property of capture, not a Contigua control.
- Direct link (Wi-Fi Aware) and the relay do not exist in the public build
  (PROTOCOL, "Direct link"; ARCHITECTURE, "Session end / battery").
- Logs are meant to carry no names, text, paths, contents or key material. This
  is a rule and is tested by log greps (e2ee §6; specs/pairing PAIR-18), not a
  guarantee against every future change.

## Open questions

1. **Advertised TXT fields.** PROTOCOL "Transport" lists `v`, `id`, `name`,
   `model`. e2ee §6 says "mDNS TXT shows deviceId/name ONLY". The code
   (`NsdAdvertiser.kt`) sets `model`. The protocol doc and the code agree. The
   e2ee text is out of date, or a decision was reversed. Which is correct?
2. **Listener scope.** The phone's listener binds `0.0.0.0` (code). The docs say
   "LAN only" and "nothing leaves the LAN unencrypted". They do not say how
   that is enforced on a phone with a cellular or VPN interface. Is there a
   guard, or is it left to the network?
3. **Malicious app on the phone.** No doc names this attacker. What can an app
   do to reach the shell service, the app's private files, or the TCP port,
   beyond what a LAN peer can?
4. **AIDL caller checks.** The docs describe the AIDL calls from the app to the
   shell service (ARCHITECTURE). They do not say whether the service checks
   who calls it. A grep for `getCallingUid` in `android/app/src/main` finds
   nothing. Is the Shizuku user-service binder considered private enough, and
   should that be written down?
5. **Same-user process on the Mac.** The identity key, the pins and the MCP
   socket are all reachable by any process running as the same user (0600
   files, same-uid check). Is that an accepted limit? e2ee §3 only says the
   Keychain "returns when Wallet-style code signing exists".
6. **MCP client identity.** Any same-user process can speak to the MCP socket
   while the setting is on. mcp.md describes no per-client approval, no
   allow-list and no per-tool consent. Is "same user plus a visible
   indicator" the intended full boundary?
7. **Relay status.** REMOTE.md is a specification for `relay/`, which is not in
   this repository. Is the relay out of scope for the first public release? If
   it is later added, how does a phone limit `incoming` floods (REMOTE §9 says
   "Not enforced by the relay")?
8. **Agents and personal data on screen.** A screenshot over MCP can contain any
   personal data a window shows. The docs say input and screenshots are like a
   person at the Mac, and that notifications and the clipboard are excluded.
   They do not say whether a window showing a notification shade, a message
   thread or a password field is in or out. The "Never trade away" list says
   anything that reads personal data is off until switched on. Does the MCP
   switch count as that switch for screen content?
9. **Pairing prompt abuse.** The 30 s cooldown starts after a Deny or timeout.
   A peer can still make the phone show one prompt per cooldown window,
   indefinitely, while "Allow new pairings" is on. Is a longer back-off or a
   cap wanted?
10. **Mac Share extension.** links.md says the extension is sandboxed and opens
    `contigua://open?url=...`. The docs do not say how the app treats a
    `contigua://` URL sent by another app on the Mac (LinkPolicy is named for
    MCP in mcp.md; it is not cited for the URL scheme).
11. **Phone files write access.** PROTOCOL "Phone files" and files.md describe
    write, move and delete on the phone's shared storage, gated by one Mac
    switch (specs/files FILES-1). They do not say what stops a paired but
    compromised Mac from reading all of shared storage once that switch is on.
    Is that accepted as "a paired Mac is trusted"?
