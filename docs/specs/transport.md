# Transport: paths and the direct link

Prefix: `PATH` (the session layer, in the public build) and `DIRECT` (the
Wi-Fi Aware provider, direct builds only). Owner docs:
[design/paths.md](../design/paths.md) (the session layer, the wire's shapes, the
machines), [design/direct-link.md](../design/direct-link.md) (the two
providers), [PROTOCOL.md](../PROTOCOL.md) § "Transport" and § "Paths",
[design/e2ee.md](../design/e2ee.md) (TLS, pinning, the per-profile stores),
[ARCHITECTURE.md](../ARCHITECTURE.md) § "Session end / battery".
Last reviewed: 2026-10-30, against main `9082e1f`.

## Purpose

One session between this Mac and one phone must survive the loss of the
connection that carries it, and use the best connection available: the LAN
today, Wi-Fi Aware for a person who opts into a self-build, and a tunnel later.
The session layer is public and always on; the direct provider is optional, off
by default and compiled out of the public build. This surface covers the
transport only: which connection the session runs on, how a frame survives a
switch, which path wins, and what the two direct-build switches do. The
settings *pages* are settings.md's, and every message's meaning for a feature
(windows, files, notifications) stays in that feature's spec.

## User stories

| ID | Priority | Story |
|---|---|---|
| PATH-S1 | P1 | As a person whose Wi-Fi hiccups or changes, I want my windows, files and input to keep working, so that a dropped connection is a two-second pause, not a lost session. |
| PATH-S2 | P1 | As a person with the phone on the same network, I want the session to use the fastest, least lossy connection it has, so that a mirror stays smooth when the router is busy. |
| PATH-S3 | P1 | As a person, I want a session that truly cannot continue to end within half a minute and say so, so that I am never shown a frozen picture as if it were live. |
| PATH-S4 | P1 | As a person who updated one device and not the other, I want a plain "these versions don't match" with no retry loop, so that I update the other app instead of chasing a network fault. |
| DIRECT-S1 | P2 | As a power user building PocketDeck myself, I want a direct Wi-Fi link that works without a router, so that the Mac can reach the phone on another network. |
| DIRECT-S2 | P2 | As a person who did not opt in, I want none of this on my Mac or phone, so that the default install has no extra code, no extra permission and no privilege. |
| DIRECT-S3 | P2 | As a person setting it up, I want to be told exactly what it costs and to type a confirmation, so that I cannot turn off two macOS protections by accident. |
| DIRECT-S4 | P2 | As a person watching it work, I want the direct link to fail honestly and fall back to the LAN, so that a macOS update cannot leave me with a dead session. |

## Requirements

`PATH` applies to the public build. `DIRECT` applies only to a direct build.

| ID | Requirement (EARS) | Proof |
|---|---|---|
| PATH-1 | WHEN a Mac connects THE `hello` SHALL carry `v` 4, and IF the phone serves another version THEN the phone SHALL answer `{"t":"error","code":"version"}` and close before `welcome` and before any session state exists; the Mac SHALL treat that answer as its incompatible-version state, SHALL stop retrying, and SHALL NOT fall back to a one-connection session; the same refusal SHALL happen in the other direction (a v3 Mac's `hello` against a v4 phone), and no path frame, `join` or `session` field SHALL be sent to a refused peer. | K2 `VersionTests` (4 accepted; 3 and 5 refused; the Mac's state; nothing sent after the refusal); K1 `VersionTest`; e2e `pathversion` (both directions) |
| PATH-2 | THE session layer SHALL be the only transport a protocol-4 session has: there SHALL be no reduced or dual mode, no code path that builds a session without seq/ack/replay, and no retry of a refused version as a single connection. | K2 `NoFallbackTests`; review of the session's construction (one path layer, created with the session); e2e `pathversion` |
| PATH-3 | WHEN the Mac opens a later path to the same phone THE `hello` SHALL carry `join` = the session id and a fresh 8-hex `path` id, and the phone SHALL answer `welcome` carrying that same `session` and attach the connection as one more path without dropping the live session, without a new pairing and without a second session; IF the join names no live session THEN the phone SHALL answer `{"t":"error","code":"no_session"}` and close, and the Mac SHALL then start exactly one new session. | K1 `SessionSlotTest` (the join table), `ServerTest.aJoinAttachesWithoutSuperseding`; K2 `PathSessionTests`; e2e `pathswitch` |
| PATH-4 | THE Mac and the phone SHALL each number their reliable frames with a `u64` seq starting at 1 in one space per session, SHALL acknowledge cumulatively with ACK frames (`ack` = the next seq expected), SHALL drop a duplicate seq, SHALL deliver in order, and SHALL replay from the peer's last ack after a switch, so every reliable frame is delivered exactly once and in order; a file transfer across a switch SHALL be byte-identical. | K2 `ReplayBufferTests`, `ReorderWindowTests`, `PathCodecTests` (the golden bytes); K1 `ReplayBufferTest`, `PathCodecTest`; e2e `pathkill` (a file's SHA-256 across a killed path) |
| PATH-5 | THE Mac and the phone SHALL NOT replay VIDEO_CONFIG, VIDEO_FRAME, AUDIO_CONFIG, AUDIO_FRAME or HOVER across a switch; WHEN a switch completes THE Mac SHALL send `window.keyframe` for every open video stream and the phone SHALL answer with a keyframe (preceded by a fresh VIDEO_CONFIG where it must be), so the picture is live again within `stale_picture_ms` (2000 ms). | K2 `PathSwitchTests`; e2e `pathmirror` (the picture within 2 s) |
| PATH-6 | IF no path is usable THEN the session SHALL stay live for 30 s waiting for a join, SHALL drop lossy frames rather than buffer them, SHALL hold reliable frames for replay, and at 30 s SHALL end the session cleanly — one transition line, the phone's slot freed, every power state the phone touched restored — instead of leaving an orphan running. | K2 `PathSessionTests` (the 30 s boundary on a virtual clock); K1 `SessionTeardownTest`; e2e `pathgrace` |
| PATH-7 | WHILE a session has two or more paths THE Mac and the phone SHALL ping every path every 2 s, SHALL count a ping with no pong within 1.5 s as lost, SHALL compute each path's score over the last 30 s with the formula in design/paths.md §7.1, SHALL switch at once to the best live path when the current one fails (a socket error or 1.5 s without a pong), and SHALL otherwise switch only when another path beats the current one by at least 100 points continuously for 5 s; a path with fewer than 2 pongs in its window SHALL NOT win on margin. | K2 `PathRankingTests` (the terms, the worked example 722/463, 412 no switch, 321 switch, 4.9 s, a failure at once, unrankable); K1 `RankingTest` (the same vectors) |
| PATH-8 | THE Mac SHALL be the only side that decides a switch and sends `path.switch`; the phone SHALL follow it and SHALL move its sending path only to a path the Mac named; the phone SHALL run the same ranking transition function for its own health reporting and SHALL NOT act on it. | K2/K1 ranking tests (the phone's copy acts on no action); review of the phone's path layer; e2e `pathswitch` |
| PATH-9 | WHEN the Mac switches a path in a planned way THE `path.switch` SHALL be the last frame it sends on the old path and SHALL carry the seq of its next reliable frame; WHEN the old path failed first THE `path.switch` SHALL be the first frame on the new path; the receiver SHALL move its sending path on it, SHALL close the old path after the peer's marker or 2 s, and SHALL accept frames out of order from the new path in a window of at most 64 frames and 4 MiB. | K2 `PathSwitchTests`, `ReorderWindowTests`; K1 `PathSwitchTest`; e2e `pathswitch` |
| PATH-10 | THE replay buffer SHALL hold at most 16 MiB of unacked reliable frames per direction, of which bulk frames (`APK_DATA`, `SHARE_DATA`, `DROP_DATA`, `CLIP_DATA`, `FS_DATA`) MAY hold at most 12 MiB, keeping at least 4 MiB free for `JSON`, `TOUCH`, `SCROLL` and `KEY`; a producer of a reliable frame SHALL NOT read the next chunk of its source while that frame would exceed its budget, SHALL resume on the ACK that frees enough, and SHALL NOT drop a frame or end the session for a full buffer; a full reorder window (64 frames / 4 MiB) SHALL stop the reader of the path that is ahead rather than drop, and a frame bigger than the buffer SHALL NOT exist (the wire's maximum is 8 MiB). | K2 `CreditTests` (a 200 MiB transfer across a 10 s orphan completes byte-exact with ≤ 16 MiB held; a `KEY` goes out at once while bulk holds 12 MiB; control may use all 16 MiB with no bulk; a frame past the cap is never created), `ReorderWindowTests` (a full window stops the read), `ReplayBufferTests` (ack release, duplicate, an 8 MiB frame fits); K1 `CreditTest`, `ReplayBufferTest`; e2e `pathkill` (a ≥ 64 MiB file across a 10 s black-hole) |
| PATH-11 | IF a join arrives from a peer that is not the live session's own pinned Mac THEN the phone SHALL answer `busy`, never `no_session`, so only the live session's Mac learns that a session id is gone. | K1 `SessionSlotTest` (a stranger never hears `no_session`); review of the slot's admission |
| PATH-12 | `path.ping` and `path.pong` SHALL travel bare — not wrapped, not seq'd, not replayed — on the path they measure, SHALL carry the path id and the sender's own millisecond timestamp, and SHALL be measured with the receiver's monotonic clock so no clock agreement is needed; a ping or pong naming a path the receiver does not have SHALL be ignored. | K2 `PathPingTests` (the bare frame, the RTT from an echoed ts, an unknown id); K1 `PathPingTest` |
| PATH-13 | THE session SHALL keep at most 3 paths; a join past it SHALL be refused `too_many_paths`; a joined path that answers no `path.ping` within 5 s SHALL be dropped and the session SHALL carry on. | K1 `SessionSlotTest` (the cap), K2 `PathSessionTests` (the 5 s drop) |
| PATH-14 | Every line the paths layer logs SHALL carry only closed tokens, ids, counts and durations — never an address, a fingerprint, a peer name, a key or frame content (R-PRIV-1). | review of the transition logs; `scripts/check-rules.sh` on the changed lines; e2e `pathgrace` (the log's tokens) |
| PATH-15 | WHILE a session is live the paths layer SHALL hold at most 20 MiB (16 MiB of unacked reliable frames, credit-bounded, and 4 MiB of reorder window); with no session it SHALL allocate nothing and hold nothing; video and audio frames SHALL never enter either buffer, and a paused bulk producer SHALL hold one descriptor and a position only. | K1 `CreditTest` (the accounting at the 12 MiB and 16 MiB boundaries), review of the buffers' construction; the phone's heap read by the reviewer |
| PATH-16 | THE session SHALL end on the 30 s grace, an oversized frame, a pin failure on its last path, or the person's close — never because a replay buffer or a reorder window is full — and on every one of them the phone SHALL free its slot and restore every power state it touched. | K2 `PathSessionTests` (every end reason); K1 `SessionTeardownTest`; e2e `pathgrace` |
| PATH-17 | WHILE the session has no usable path THE Mac's windows SHALL say so within `stale_picture_ms` (2000 ms) instead of presenting the last frame as live, and SHALL return to the live picture by themselves when a path joins. | e2e `pathmirror`, `pathgrace`; the NFR rule "no stale picture" (`nfr`) |
| PATH-18 | THE 15 s app-level `ping`/`pong` SHALL stay a session-level keepalive and SHALL NOT be the path health signal; every path's accepted socket SHALL carry the existing TCP keepalive options (PAIR-22). | K1 `TcpKeepaliveTest`; K2 review of the ping's ownership; e2e `pathgrace` (the 15 s ping is not what ends a path) |
| PATH-19 | THE phone SHALL mint a fresh 128-bit `session` id for every new session, SHALL never reuse one, and SHALL NOT derive it from any device, user or peer identifier. | K1 `PathIdsTest`, K2 `PathIdsTests` (randomness across sessions, no reuse) |
| DIRECT-1 | THE direct provider SHALL be off on a fresh install on both sides, and SHALL be usable only while the phone's own switch is on with its permission granted, the Mac's switch for that phone is on, and the helper's probe answers `ok`; any of those failing SHALL mean no direct path and no publish, with the reason shown. | K1 `DirectSwitchTest`, K2 `DirectSettingsTests`; the reviewer's real-hardware run |
| DIRECT-2 | THE public build SHALL contain no Wi-Fi Aware code, no Aware permission and no helper; the direct build SHALL be the only one with `POCKETDECK_DIRECT`, the `pocketdeck-directd` product and `NEARBY_WIFI_DEVICES`; both directions SHALL be checked, so the public check is known to be able to see them. | K2 `DirectGateTests` (the source scan, `isCompiledIn == false`, no helper dependency); K1 `DirectGateTest` + the Gradle `verifyPublicBuildHasNoDirect`; e2e `direct-install` (`gate.sh --public` and `--direct` on the two built trees) |
| DIRECT-3 | WHEN the helper's probe does not answer `ok` THE app SHALL offer no direct provider for that session and SHALL show that code's one sentence; the probe SHALL run at launch and after a Wi-Fi wake and SHALL NOT assume an earlier answer still holds. | K2 `DirectProbeTests` (every code and its sentence); review of the probe's call sites; the reviewer's run after a macOS update |
| DIRECT-4 | THE helper SHALL expose exactly the operations of design/direct-link.md §2.5 on `/var/run/pocketdeck-directd.sock` (SOCK_STREAM, `0660 root:staff`), one JSON request line and one JSON reply line each, and one file descriptor by `SCM_RIGHTS` for a `dial`; every accepted connection SHALL be checked with `getpeereid` against the console user before a request is read, and a mismatch SHALL be answered `not_console_user` and closed. | K2 `DirectSocketTests` (the request/reply bytes, the fd, the error codes, the refusal); review of the `getpeereid` step; the reviewer's install |
| DIRECT-5 | THE helper SHALL move bytes only: the app SHALL perform the TLS handshake over the helper's socket, the helper SHALL parse no PocketDeck frame and SHALL see no plaintext, and nothing below TLS SHALL be trusted. | K2 review test: the helper's sources contain no frame codec and no message name; e2e `pathswitch` with the direct build in P4 |
| DIRECT-6 | THE installer SHALL print the exact `csrutil` and `nvram` commands and the Recovery step and SHALL NOT run them; it SHALL check `csrutil status` and `nvram boot-args` and say what it found; it SHALL take the typed phrase `install pocketdeck-directd` and SHALL change nothing on anything else; the uninstaller SHALL remove what was installed and print the revert without running it; both SHALL have a `--dry-run` that prints every command and runs none. | e2e `direct-install` (`--dry-run` for both scripts: the printed commands, the phrase gate rejecting `y`, the cost paragraph verbatim, no `nvram`/`csrutil` invocation); review |
| DIRECT-7 | THE phone SHALL publish only while its own switch is on with its permission granted, a session is live, and that Mac sent `direct.enable` `on` for this phone; WHILE such a session is live it SHALL keep the NDP up as a standby path (the documented exception to ARCHITECTURE's idle cost); WHEN the session ends or either switch turns off it SHALL unpublish within 1 s. | K1 `AwareLinkTest` (every transition, the 1 s teardown); review; the reviewer's battery figure |
| DIRECT-8 | THE phone SHALL establish the NDP with `WifiAwareNetworkSpecifier` and the PSK, SHALL bind a `ServerSocket` to the Aware network, and SHALL serve the same TLS server on it as on the LAN; the Mac SHALL dial that listener through the helper, and nothing plaintext SHALL cross the link. | K1 `AwareListenerTest` (a fake `Network`: bind before listen, the specifier's port); VM `feth-path` (the helper's side); the reviewer's NAN proof |
| DIRECT-9 | WHEN both switches are on and no key is stored for that phone THE Mac SHALL generate 32 random bytes on the first LAN session and send `direct.key` inside TLS; the phone SHALL store it wrapped by an Android Keystore key and answer `direct.key.ok`; the Mac SHALL store it in the profile's `direct.json` (`0600`); forgetting the pairing on either side SHALL delete the key and the next LAN session SHALL mint a new one; the NDP passphrase SHALL be the base64 of those bytes and SHALL never travel on the wire. | K1 `DirectKeyTest` (the passphrase derivation, rotation, the store); K2 `DirectKeyStoreTests` (0600, rotation, no key in the defaults); review |
| DIRECT-10 | THE service-specific info the phone publishes SHALL be `HMAC-SHA256(psk, "pd-nan-v1" ‖ u64_be(window))[0..8]` for a 10-minute window, updated each window; the helper SHALL accept only the current window and its two neighbours; no device id, name, model, fingerprint or key SHALL appear in any Aware field. | K1 `SsiTest` (a fixed vector, the window boundary), K2 `SsiMatchTests` (window ±10 min, a wrong 8 bytes ignored); review of the publish config's fields |
| DIRECT-11 | ON API 33 and above the app SHALL ask `NEARBY_WIFI_DEVICES` in context with one sentence saying why, and below 33 `ACCESS_FINE_LOCATION`; a denial SHALL turn the switch off and leave the sentence naming the permission and where to grant it; a phone without the feature, or with Location services off, SHALL show the row disabled with that reason. | K1 `DirectPermissionTest`; the emulator's `settings` run (the disabled row and its words); the reviewer's real phone |
| DIRECT-12 | IF the probe fails or the platform refuses a publish or an NDP THEN the app and the phone SHALL turn the direct path off for that session, SHALL log a code, SHALL keep the LAN session up, and SHALL show one sentence that names a step which can actually fix it — never an internal code and never a restart that would not help. | K2 `DirectProbeTests` (code → sentence), K1 `AwareLinkTest` (a refused publish keeps the LAN session); review of the copy |
| DIRECT-13 | WHEN a link goes down or the helper stops THE helper SHALL remove the per-peer route it installed, close that link's bridge socket, and leave no route or descriptor behind. | VM `feth-path` (a killed link leaves no route and no open fd); review |
| DIRECT-14 | IF the platform reports that Wi-Fi Aware became unavailable THEN the phone SHALL tear down every Aware session and NDP, SHALL keep the LAN session running, and SHALL re-attach and republish when it is available again (the platform's own rule). | K1 `AwareLinkTest` (`AwareStateChanged` in every state); the reviewer's real phone |
| DIRECT-15 | No log, crash report, error message, UNIX-socket reply or e2e share log SHALL contain the 32 key bytes, the NDP passphrase or the service-specific info; the one line that names the key SHALL carry the first 8 hex of its SHA-256 and its length only (R-PRIV-1). | K1 `DirectLogHygieneTest`, K2 `DirectLogHygieneTests` (grep the captured log for the value and the passphrase, like e2e `tls`); review |

Priority note: PATH-1 to PATH-9 are P1 — without them a session cannot join a
second path, cannot switch, and cannot be trusted with a file. PATH-10 to
PATH-19 are P1 too, because they are the bounds and the honesty; DIRECT-1,
DIRECT-2, DIRECT-6 and DIRECT-15 are P2, and the rest of DIRECT is P2/P3 as the
phases in the plan say. DIRECT-S1–S4 are P2 (nobody has the feature before P3).

## States and events

Full tables and every ignored event: design/paths.md §4 (the phone's slot), §6
(the session), §7.3 (the ranking); design/direct-link.md §2.6 (the probe) and
§8.1 (the phone's Aware machine). The same machines, shorter:

| State (session) | Event | Result |
|---|---|---|
| `Live(cur)` | `PathUp(id)` | stay; that path is pinged; ranking gets `PathUp` |
| `Live(cur)` | `PeerSwitch(to)` | `Migrating(cur, to)`; the old path is closed after the peer's marker (or 2 s) |
| `Live(cur)` | `CurrentFailed` with a live path `b` | `Migrating(cur, b)`; `path.switch` on `b`, replay from the last ack, `window.keyframe` per stream |
| `Live(cur)` | `CurrentFailed` with no other path | `Orphaned(now)` |
| `Migrating(from, to)` | `PeerSwitch(to)` | `Live(to)` |
| `Migrating` | `PathDown(to)`, `from` usable | `Live(from)`; else `Orphaned(now)` |
| `Orphaned(since)` | `PathUp(p)` | `Live(p)`; `path.switch` first, then the replay, then the keyframes |
| `Orphaned(since)` | 30 s | `Ended(graceExpired)` |
| any | `Close(why)` | `Ended(why)` |
| `Ended` | anything | ignored |

| State (ranking) | Event | Result |
|---|---|---|
| `Idle` | `PathUp` | `Steady(best rankable)`, or `Idle` with no live path |
| `Steady(cur)` | `Tick`, another path ≥ 100 points better | `Challenging(cur, b, now)` |
| `Steady(cur)` | `CurrentFailed` / `PathDown(cur)` | `Steady(best live)` + `Switch`; `Idle` + `SessionOrphan` with none |
| `Challenging(cur,b,since)` | `Tick` at 5 s, still ≥ 100 | `Steady(b)` + `Switch(b)` |
| `Challenging(cur,b,since)` | `Tick` under 100, or `b` gone | `Steady(cur)`; the 5 s starts over |
| `Challenging` | `CurrentFailed` | `Steady(best live)` + `Switch`, at once |
| any | the session switched (`path.switch` received) | `Steady(to)` |

| State (phone's slot) | Event | Result |
|---|---|---|
| `Free` | `Connect(join: nil)` | `ADOPT` |
| `Free` / `Draining` / `Live` | `Connect(join: id)` with no such live session and the live Mac's pin | `no_session`, close |
| `Live(s)` | `Connect(join: s.id)`, pinned | `JOIN`: one more path, no supersede |
| `Live(s)` | `Connect(join: nil)`, pinned, same Mac | today's supersede (`Handing`, ≤ 2 s, else `busy`) |
| `Live(s)` | `Connect` from another Mac or an unpinned peer | `busy` |
| `Handing` | any `Connect` | `busy` |

| State (phone's Aware link) | Event | Result |
|---|---|---|
| `Off` | `SwitchOn` + the Mac's `direct.enable` + a live session | `Attaching` |
| `Attaching` | `Attached` | `Publishing` (one publish per Mac with direct on) |
| `Publishing` | `PublishStarted` | `NdpPending` |
| `NdpPending` | `NdpAvailable(network)` | `Up` (the listener is bound and accepts) |
| `Up` | `NdpLost` / `AwareStateChanged` / session end / `SwitchOff` | `Lost` → `Off`; the LAN session is untouched |
| any | `PermissionDenied` | `Blocked(no_permission)` |

Ignored, stated so nobody builds them: a `path.switch` for a path this side does
not have (logged once); an `ACK` above the highest seq sent (a protocol error
that ends the session); a `PathUp` after `Ended`; a second `PathUp` for a path id
already live (the second socket is closed); a `Pong` from a path that is not
live; a `path.ping`/`path.pong` naming an unknown path; an `NdpAvailable` with no
publish running (the network is released at once); a publish callback after
`SwitchOff`.

## Phone count and connection

| Situation | What the transport does |
|---|---|
| 0 phones | No session, no path, no publish: one listening socket and the mDNS registration, as today. |
| 1 phone | One session, one to three paths. The direct path exists only if both switches are on and the probe says `ok`. |
| 2+ phones | One session per Mac, and the Mac app is single-phone today (settings.md): the phone in use is the one with a session. The phone publishes one Aware service per Mac with direct on, up to the platform's 8. |
| Connecting | The Mac dials the LAN path first (Bonjour, then its cached address); a direct path is dialed only while the session is live and this Mac's own provider is ready for that phone — a public build has no such provider, so it never dials one. |
| Connected | One current path, up to two standbys; a switch is invisible but for a keyframe (video) and one audio frame. |
| Offline / reconnecting | `Orphaned` for 30 s with the windows saying so within 2 s; at 30 s the session ends and the Mac's ordinary backoff retries. |
| A phone on another version | `error version` and a close (PATH-1): the Mac's banner says the two apps' versions differ and it stops retrying. Nothing half-works; the way out is to update the other app. |
| A phone that can't do direct | The row is disabled with its reason (DIRECT-11); the session runs on the LAN and nothing is dialed (DIRECT-1). |
| A Mac on another version | The same refusal from the phone's side (PATH-1). The phone's slot is never touched, so a stale half-session cannot exist. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: the transport has no search or filter field (Settings' ⌘F, where a field exists, is settings.md's SET-WIN) |
| CONV-MAC-02 | applies: the transport adds no shortcut and takes none of ⌘W/⌘M/⌘Q/⌘,/⌘H; the Direct link row is reached in the Settings page settings.md owns |
| CONV-MAC-03 | applies: the installer's confirmation is a typed phrase in a terminal, and the Settings row's button is the ordinary default-action button; Esc closes nothing on the transport's own account |
| CONV-MAC-04 | n/a: no text field of this surface (the terminal's own editing is the terminal's) |
| CONV-MAC-05 | n/a: nothing zoomable |
| CONV-MAC-06 | applies: no new shortcut anywhere in this surface; the direct switch is a normal control with a help tag naming the probe's answer |
| CONV-MAC-07 | n/a: no shortcut is reused |
| CONV-MAC-10 | n/a: not the status item's panel (the Deck's connection chip is DECK's) |
| CONV-MAC-11 | applies: one probe, one helper and one direct provider per session; opening Settings again raises the same window (settings.md) |
| CONV-MAC-12 | n/a: no window of its own |
| CONV-MAC-13 | n/a: no menu item and no full-screen command |
| CONV-MAC-14 | n/a: no window resizes here |
| CONV-MAC-15 | n/a: nothing quits or reopens |
| CONV-MAC-16 | n/a: no drag, paste or Services |
| CONV-MAC-20 | applies: the Settings row and its sentence follow light, dark, accent and Increase Contrast (settings.md draws them) |
| CONV-MAC-21 | applies: the row and the installer's steps are text a VoiceOver user hears in order; the switch has a label, not a glyph alone |
| CONV-MAC-22 | n/a: no animation; a switch to another path is not animated (its only visible effect is the picture continuing) |
| CONV-MAC-23 | applies: the probe's answer and the switch's state are words, never a colour alone |
| CONV-MAC-24 | applies: no new macOS permission is asked; the helper's install is a person's own sudo, and its cost text is the reason line §3.1 (DIRECT-6) |
| CONV-MAC-25 | applies: the Direct link switch has the standard hover, pressed and disabled states; disabled is dimmed neutral and its sentence says why (DIRECT-11/12) |
| CONV-MAC-26 | applies: the row and its explanation sit together with settings.md's one inset and rhythm |
| CONV-AND-01 | n/a: the transport carries no phone navigation |
| CONV-AND-02 | applies: the phone's Direct link row follows the system theme; a notification about the permission is dismissable and names what it does (DIRECT-11) |
| CONV-AND-03 | applies: `NEARBY_WIFI_DEVICES` (or location below 33) is asked when the person turns the switch on, with one reason; a denial disables only direct and says why (DIRECT-11) |
| CONV-AND-04 | applies: the Aware publish/NDP changes no phone setting, and the standby ends with the session (DIRECT-7); the lock screen is never touched |
| CONV-PD-01 | applies: the phone-count table above (0, 1, 2+) |
| CONV-PD-02 | applies: the same table — connecting, connected, offline, a phone on another version (refused, PATH-1), a phone without direct (disabled with its reason) |
| CONV-PD-03 | n/a: nothing the phone must confirm (the install's confirmation is the Mac's own sudo, and the phone's switch is its own) |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value |
| CONV-PD-05 | applies: PATH-14 and DIRECT-15 (R-PRIV-1) |
| CONV-PD-06 | applies: a switch costs at most one keyframe (video resumes within `stale_picture_ms`, PATH-5) and one audio frame; a joined path is pinged immediately so its ranking starts at once |
| CONV-PD-07 | applies: "Direct link" is the same words in the Mac's Settings, the phone's Settings, the installer's text and these docs; "Paths" is internal and never shown |
| CONV-PD-08 | applies: the four machines above, with their full tables in the design docs |
| CONV-PD-09 | applies: DIRECT-12 (every probe code and every refusal names a step that can fix it); PATH-17 (the window's own words while there is no path) |

## Assumptions

- Both apps are PocketDeck builds of the same alpha; there is no released
  version to stay compatible with, so a protocol change may rename or require a
  field (AGENTS.md). The two apps still update separately, so the protocol
  version is the single gate: a peer on another version is refused with
  `version` and the person updates the other app. There is no dual mode and no
  reduced transport.
- A path is a TCP connection over which the app runs its own TLS 1.3 handshake
  with the existing pins (e2ee.md); no path is trusted below TLS.
- The Mac is the client on every path: the phone listens on the LAN and on the
  Aware network, and the Mac dials. A provider that cannot be dialed is not a
  provider.
- On the phone all transports live in the shell-UID process; the app process
  pushes identity, pins and switches and never sees a path.
- Wi-Fi Aware is present on the phone model used for the hardware proofs
  (Galaxy S25+, Android 16) and on this Mac's radio; on any other device the
  probe and the feature flags answer, and the row is disabled with the reason.
- The direct build's macOS requirements (SIP off, `amfi_get_out_of_my_way=1`,
  `wifiaware_allowlist=0`) are a person's own machine-wide change, made by the
  person, never by the scripts and never by an agent.
- `direct.json` (0600) is where the Mac's direct key lives during the alpha
  (open question 1).

## Non-goals

- Several sessions at once, or a session with two phones.
- A relay, a tunnel or any WAN behaviour: `wan` is the provider interface's
  third case and nothing more (`docs/ROADMAP.md`).
- A phone-side decision to switch, and any phone-side ranking that acts.
- Replaying video or audio, or a decoder's recovery beyond `window.keyframe`.
- Shipping the direct provider to anyone: it is a self-build for one machine and
  one phone, and the public build has none of it.
- The settings pages' layout and words (settings.md), the Deck's connection chip
  (deck.md) and the windows' "Not responding" copy (phone-mirror.md).
- Surviving a phone reboot, an app kill or Clear data: those end the session, as
  today.

## Open questions

- [NEEDS CLARIFICATION] D9 says the Mac stores the NDP key "in the Keychain",
  while pairing.md PAIR-1 says this alpha keeps key material in the profile's
  `0600` files and never in the login Keychain (and a root daemon cannot read a
  person's login keychain at all — the research hit exactly that failure).
  **Recommended:** the profile's `direct.json` (`0600`), as DIRECT-9 states; the
  Keychain returns with Wallet-style code signing, as PAIR-1's roadmap note says.
- [NEEDS CLARIFICATION] The direct path's throughput is unmeasured (the proof
  only carried ~1 Mbit/s), so its class floor is the 8 Mbit/s one mirror needs.
  Should direct be scored at that floor, or be failover-only until P4 measures
  it? **Recommended:** keep the floor (8) — the ranking then lets it win only
  when the LAN is genuinely bad, and P4 replaces the number with the measurement
  in the one place it lives.
- [NEEDS CLARIFICATION] Where the Mac's Direct link switch lives: on that
  phone's Settings page (it needs that phone's key and the helper) or in This
  Mac ▸ General (it is a Mac-wide install). **Recommended:** that phone's page,
  beside "Share notifications and Now Playing", because everything it needs is
  per phone — with the helper's probe state shown once in General, where the
  install belongs.
- [NEEDS CLARIFICATION] The 100-point switch margin is this design's number, not
  the plan's (D5 fixes the 5 s hysteresis, not the margin). **Recommended:**
  keep 100 — it is three times the score movement a 2 ms swing in p50 causes at
  today's LAN numbers, so one noisy sample cannot start a switch — and record it
  beside the formula so a later measurement can move it in one place.
