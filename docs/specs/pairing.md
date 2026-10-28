# Pairing

Prefix: `PAIR`. Owner docs: [design/e2ee.md](../design/e2ee.md) §4–§7, [design/mac-redesign.md](../design/mac-redesign.md) §3.4–3.5 and §4.5, [UX.md](../UX.md) § "Pairing model" and § "Android app" 3, [PROTOCOL.md](../PROTOCOL.md) § "Session handshake" and § "Pairing (first contact)". Last reviewed: 2026-10-27, against main `6073e3c`.

## Purpose

Pairing is how a Mac and a phone come to trust each other once, so every later connection is silent: both sides keep the other's TLS certificate fingerprint, and a connection is either verified against that pin or refused. Two people-facing flows produce the same result — a 6-digit code both screens show and the person allows on the phone (the default, discovered or manual), and a QR the phone scans (the Mac shows it, the person scans, nothing to compare). It is the phone's consent either way; the Mac never pairs with itself and no code is ever typed or sent. This surface covers both ends of those flows, the pins, forgetting and pairing again; the Deck's Welcome/Nearby screens are DECK's, the phones list is settings.md's, and the wire is PROTOCOL.md's.

## User stories

| ID | Priority | Story |
|---|---|---|
| PAIR-S1 | P1 | As a person with a phone on the same Wi-Fi, I want to pair by comparing two screens and tapping Allow once, so that I never type an address, a code or a key. |
| PAIR-S2 | P1 | As a person, I want a QR when discovery is awkward, so that pointing the phone at the Mac's screen is the whole step. |
| PAIR-S3 | P1 | As a person, I want a refused, denied or timed-out pairing to say what happened and let me try again, so that a failed attempt is not a dead end. |
| PAIR-S4 | P1 | As a person, I want the trust to survive restarts on both sides, so that pairing is once, not every day. |
| PAIR-S5 | P1 | As a person who lost the other device's key, I want to pair again from the phone's prompt or the Mac's banner, so that one missing key does not mean reinstalling. |
| PAIR-S6 | P1 | As a person, I want to forget a Mac from the phone (and a phone from the Mac) so that a device I no longer own cannot connect. |
| PAIR-S7 | P2 | As a person pairing a second phone, I want each pairing to stand alone, so that one phone's key never stands for another's. |
| PAIR-S8 | P2 | As a person, I want the phone's own switches to refuse strangers and new pairings, so that I control who may even ask. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| PAIR-1 | A finished pairing SHALL leave two pins — the Mac stores the phone's certificate fingerprint under its device id and the phone stores the Mac's under its client id, one record each, so two phones never share a pin — plus a remembered record on the Mac (device id, name, model, last seen); both SHALL survive a relaunch and a restart, and SHALL be stored in the active profile (keys `0600` in a `0700` folder), never in the login Keychain or the person's default domain. | K2 `DiscoveryAndStoresTests.testRememberingKeepsNameAndMakesThePhoneActive`, `testAPhoneWithoutAPinIsStillRemembered`, `testProfilesDoNotShareMemory`; K1 `DeckPairedRowsTest`; review of `PhonePinStoreV2` (`pins.json`, `0600`) |
| PAIR-2 | WHEN the Mac connects to a remembered phone THE handshake SHALL verify the phone's certificate against its pin, and the phone SHALL verify the Mac's certificate against its pinned client; IF either fingerprint does not match THEN the side that holds the pin SHALL refuse (the phone answers `bad_pin`; the Mac's banner then reads "<name> no longer trusts this Mac." with Pair again) and SHALL NOT fall back to pairing. | K2 `TlsV2Tests` (the pin check), `LinkMachineTests` (`pin-mismatch`/`bad_pin`/`no-pin` → Pair again); review of `TlsConnectorV2` |
| PAIR-3 | WHEN the person chooses Pair on a discovered phone or connects manually THE Mac SHALL send `pair.request`, then the phone SHALL commit (`pair.commit`), the Mac SHALL release its nonce (`pair.nonce`), the phone SHALL reveal (`pair.reveal`), both SHALL derive the same 6-digit code from the TLS exporter, and the person's Allow SHALL answer `pair.ok` with the two fingerprints followed by `welcome`; no message SHALL carry the code, and the Mac SHALL NOT accept a reveal whose commit does not verify. | e2e `pair` `[PAIR-3]` (`pair.request`, `pair.commit`, `pair.nonce`, `pair.reveal`, no `pair.confirm`); K2 `PairingCodeV2Tests` (the vectors), `PairingFlowTests.testTheSheetStaysUpWhileAPersonCompares`; K1 `PairingCodeV2Test` |
| PAIR-4 | THE code sheet SHALL read "Pair with <phone name>", show the code as "123 456" in large monospaced digits, and say "Tap Allow on your phone if it shows the same code." with Cancel; while contacting it SHALL read "Contacting <name>…" with a spinner, and while verifying "Pairing…"; the code SHALL be identical on both screens. | e2e `pair` `[PAIR-4]` (the same code on both screens); K2 `DiscoveryAndStoresTests.testSixDigitsAreGroupedThreeAndThree`, `PairingFlowTests`; review of `CodeSheet` |
| PAIR-5 | WHEN the person taps Deny, does nothing for 120 s, or the phone cannot be reached THE sheet SHALL say "Pairing was denied on the phone.", "Nobody tapped Allow in time. Try again." or "Couldn't reach <name>. Try again." with Cancel and Try again; Try again SHALL run the same pairing again; a refusal (the phone's switch off) SHALL show the phone's own sentence; the Mac SHALL wait the whole 120 s without a watchdog firing. | e2e `pair` `[PAIR-5]` (an 8 s Allow still completes); K2 `PairingFlowTests.testDeniedAndTimedOutReachTheSheet`, `testCancelHangsUpOnThePhone`; K1 `SessionTest.denyReportsPairDeniedAndCloses`, `noDecisionTimesOutWithPairTimeout` |
| PAIR-6 | WHEN the Mac connects to an unpaired phone THE phone SHALL show "Pair with <Mac name>?" with the same code and Allow/Deny — as a notification, and as a floating card with 16 dp side margins and 16 dp above the navigation bar when PocketDeck is in the foreground; the prompt SHALL disappear when the Mac cancels or the request expires; no decision in 120 s SHALL answer `pair_timeout`, and a Deny or timeout SHALL refuse that Mac's next `pair.request` for 30 s; one request per session SHALL be honoured (a second is ignored). | K1 `PairingDialogTest` (the card's insets), `PairCooldownTest.testWindowOpensOnStartAndClosesAfterThirtySeconds`, `testASecondDenialRestartsTheWindow`, `SessionTest.aNewPairRequestIsRefusedWhileTheDenyWindowIsOpen`, `macHangingUpDismissesThePhonePrompt`, `aSessionInPairingSendsNothingButThePairingMachine`; review of `DeckForegroundService`'s prompt |
| PAIR-7 | WHEN the person chooses Cancel, Esc or Done in a pairing sheet THE Mac SHALL hang up (the phone discards the request and dismisses its prompt), SHALL store nothing and SHALL return to where the person was; a pairing that finishes instead SHALL make the phone the one in use, remember it, request its app list and close the sheet with "Paired." and a checkmark. | K2 `PairingFlowTests.testCancelHangsUpOnThePhone`, `LinkMachineTests.testCancelReturnsToWhereTheUserWas`; review of `ConnectionController.sheetDismissed`/`ready`; e2e `pair` (the first launch's pairing completes and the app list is requested) |
| PAIR-8 | WHEN a pairing or a reconnect succeeds WHERE the phone was already remembered THE Mac SHALL connect silently — no code, no sheet, no prompt on the phone — and SHALL re-open the windows it had. | e2e `pair` `[PAIR-8]` (second launch: `auth_ok`, no `pair.request`); K2 `LinkMachineTests` (`launch` → `attempt` → `welcome`) |
| PAIR-9 | WHEN the person opens Pair with QR THE Mac SHALL show a fresh QR for `pocketdeck://pair?c=<clientId>&n=<name>&f=<64 hex>&s=<32 hex>`, white with a quiet zone, with "Scan with PocketDeck on your phone" and an "Expires in m:ss" countdown; the one-time secret SHALL be 16 random bytes kept in RAM and SHALL expire with the QR after 5 minutes; an expired QR SHALL blur and offer "Show new code" with "This code expired.". | e2e `qr` `[PAIR-9]` (the sheet, the c/n/f/s shape, `f` 64 hex, `s` 32 hex); K2 `QRPairingTests` (the URI, the encoding, the 5-minute boundary, the random secret), `QRPairingTests.testQRImageIsDrawnCrisplyOnWhite` |
| PAIR-10 | WHILE the QR sheet is up THE Mac SHALL probe every unpaired discovered phone and a manual `--connect` target with a pairing-channel `hello` (a 2 s round, each phone at most every 4 s, for the QR's 5 minutes) and SHALL NOT send `pair.request`; WHEN a phone that scanned the QR answers `pair.qr` with a valid HMAC THE Mac SHALL verify it with the sheet's secret and answer `pair.ok`; an unknown, expired or reused secret SHALL be refused like any failed pairing, and a second hello in the same window SHALL get no `pair.qr`; the sheet SHALL close on `welcome`. | e2e `qr` `[PAIR-10]` (no `pair.request`, `pair.qr`, `pair.ok`); K2 `QRPairingTests` (`testProbesEveryUnpairedPhone`, `testSkipsPhonesAlreadyPairedWithThisMac`, `testProbesEachPhoneAtMostEveryFourSeconds`, `testLeavesBusyPhonesAloneUntilTheyAreFree`); K1 `PairingCodeV2Test.qrHmacFixedVector` |
| PAIR-11 | THE QR pairing SHALL still be gated by the phone's own Allow prompt, and the phone SHALL pin the Mac's fingerprint from the QR's `f` when it scans; a Mac whose certificate does not match `f` SHALL be refused. | e2e `qr` `[PAIR-11]` (`pair.qr` after the scan, pins stored, the reconnect authenticates); K1 `QrPairingTest` (the payload's rules, `any fingerprint length difference invalidates the payload`) |
| PAIR-12 | THE phone SHALL keep its two switches: "Allow connections" (off refuses every Mac, paired or not, with `connections_off`; unreadable settings fail closed) and "Allow new pairings" (off refuses an unpaired Mac with `pairing_off` before any code while paired Macs still connect); a peer whose certificate matches no pin SHALL be closed without a reply once TLS completes. | e2e `gates` `[PAIR-12]` (pairings off: refused at the handshake, no `pair.request`; the paired Mac still authenticates; connections off: refused); K1 `ConnectionGateTest` (the truth table, fail closed) |
| PAIR-13 | WHEN the phone refuses THE Mac SHALL show one banner in the person's words — "Connections are turned off on <name>.", "<name> isn't accepting new pairings.", "Another Mac is connected to <name>.", "<name> runs an incompatible version of PocketDeck." — with at most one button, SHALL retry on the 1/2/4/8/15 s backoff rather than in a loop, and SHALL NOT show a reason code. | e2e `gates` `[PAIR-13]` (the reason read, the sentence shown, the attempts inside the backoff window); K2 `LinkMachineTests` (every banner, the backoff) |
| PAIR-14 | WHEN the Mac's pin for a phone is gone or the phone rejected it THE phone's state SHALL read "Pair again" and the Deck's banner SHALL read "<name> no longer trusts this Mac." with Pair again; Pair again on a discovered phone SHALL forget the old pin and run the code flow again, and on a phone that is not in range SHALL open the add-phone sheet; nothing SHALL imply the phone can be reached meanwhile. | K2 `LinkMachineTests` (`pin-mismatch` → `needsPairing`), `DevicesTabTests.testAPhoneWithoutItsKeyOffersPairAgainOnly`; review of `ConnectionController.pairAgain` |
| PAIR-15 | WHEN the person chooses Forget This Phone… (Settings ▸ a phone) and confirms THE Mac SHALL remove that phone's pin, remembered record, cached app list and icons, Spotlight entries and Dock shims, and SHALL NOT remove another phone's; THE phone's own Forget of a Mac SHALL drop that Mac's pin and its row after a four-second Undo window; the other side SHALL then read Pair again. | e2e `settings` (the same confirmation, tagged SET-DEV-07 there); K2 `DiscoveryAndStoresTests.testForgetRemovesThePhoneAndTheActiveChoice`; K1 `DeckPairedRowsTest`; review of `ConnectionController.forget` and `DeckViewModel.forget` |
| PAIR-16 | THE phone's home SHALL list its paired Macs — one row each with the Mac's name and "Connected now" or when it last connected — with the live Mac first and then the most recently connected, and SHALL offer "Pair new Mac" (QR scan); the list SHALL refresh its relative times on the minute. | K1 `DeckPairedRowsTest` (`the live Mac is the first paired row`, `never connected Macs come last`), `UiStateTest` (`a session start or end stamps only that Mac`, `the relative-time ticker wakes on the next whole minute`) |
| PAIR-17 | WHEN the phone scans a QR THE phone SHALL accept only `pocketdeck://pair` with a client id, a Mac name, a 64-hex fingerprint and a 32-hex secret, SHALL decode `+` as a space in the name and normalise uppercase hex, and SHALL refuse a v1-shaped payload, a short fingerprint or secret and any non-hex secret; a fresh QR from another Mac SHALL replace its pending one and the same Mac MAY refresh it. | K1 `QrPairingTest` (every parse rule), `PairingCodeTest` (the grouping) |
| PAIR-18 | THE pairing SHALL write no key material, nonce, exporter output, pairing code or QR secret to a log, a crash report or the e2e share log; the code SHALL only be displayed (never typed, stored or sent), and the phone's prompt SHALL carry the Mac's name, the code and the one hint line "Check it matches your Mac.". | e2e `pair` (the code read from the screens' own lines only); review of `PairingCodeV2`, `QRPairing` and `TlsV2` logging; e2e `tls` (no key material in any log) |
| PAIR-19 | THE shell-UID server SHALL serve only with the identity and paired Macs the app process currently vouches for: on every bind and every change the app SHALL push its identity fingerprint and paired set, and WHEN a push differs from what the shell holds THE shell SHALL drop every live session, forget its cached identity and pairing state and adopt the push; an identical push SHALL keep the session, and a push with no usable identity SHALL be handled as the app being gone. | K1 `AppLinkTest` (every state/event pair, the ignored events, order/rename are not a change), `IdentityPinTest` (the declared fingerprint must match the certificate); emulator `phone-reset` (a re-push with the same state keeps the session) |
| PAIR-20 | WHEN the app's data is cleared, the app is uninstalled, or the person chooses Paired Macs ▸ Forget All Macs… and confirms THE shell-UID server SHALL end every live session at once (measured: ≤ 5 s from Clear data and from Forget All), without waiting on the Mac: the app SHALL empty the paired list at once and run the identity rotation and the push off its main thread (the push after the rotation), and the shell's drop SHALL hand the close to its own thread and cut the transport through the plain socket under TLS; it SHALL forget the identity and every pairing it cached, and accept no Mac until the app pushes its current state again; the phone SHALL then list no paired Macs, and a Mac that knew the phone SHALL NOT authenticate without a fresh pairing (clear data rotates the phone's identity and its advertised id, so the Mac's stale pin cannot match; Forget All rotates the identity under the same id, so the Mac reads its pin as changed). | K1 `AppLinkTest` (`the app dying drops the session…`, `a different identity drops the session…`), `PrefsIdentityTest` (`forget all Macs rotates the identity…`), `SessionTeardownTest` (every transition, the ignored events), `SessionDropperTest` (`aDropReturnsAtOnceEvenWhenTheCloseBlocks`), `ServerTest.droppingSessionsNeverWaitsForASlowClose`, `DeckViewModelTest` (`forget all empties the list at once and pushes the rotated identity off the main thread`, `forgetting one Mac pushes the new list off the main thread`); emulator `phone-reset` (both measured closes, no `ANR in dev.pocketdeck` after the Forget All tap, the refused reconnect, the empty list, Forget All's confirmation) |

Priority note: PAIR-1, 2, 3, 4, 5, 6, 7, 8, 9, 12, 13 and 14 are P1 — without them a person cannot pair, cannot trust the pairing and cannot recover from a lost key. The QR probe detail, the phone's list and the parse rules are P2.

## States and events

Pairing is one machine on the Mac (`LinkMachine`, `macOS/Sources/PocketDeck/Link.swift`; its table is in design/mac-redesign.md §4.3) with a pairing sub-state (`Pairing`), and one on the phone (`Session`'s pairing phase, `PairCooldown`). The Mac's `resume` value is where a cancelled pairing goes back to.

| State | Event | Result |
|---|---|---|
| any | `beginPairing(phone)` | `pairing(contacting)`; every attempt stops; one pairing session starts |
| pairing(contacting) | `codeShown(code)` | `pairing(comparing)`; the sheet shows the code |
| pairing(comparing) | `pairApproved` (`pair.ok`) | `pairing(verifying)` |
| pairing(verifying) | `welcome` | `online`; "Paired."; the sheet closes 0.6 s later |
| pairing(any) | `pair_denied` / `pair_timeout` / `connections_off`/`pairing_off` / other | `denied` / `timedOut` / `refused(reason)` / `unreachable`; Cancel + Try again |
| pairing(any) | `Cancel` / `Esc` / sheet dismissed | back to `resume` (or `idle`); the attempt restarts where it was |
| pairing(any) | `Try again` | `contacting` again with the same target |
| online(phone) | `link lost` < 15 s | `reconnecting` |
| reconnecting | `15 s` | `offline(unreachable)`; one banner |
| any | `bad_pin` / `no-pin` / `pin-mismatch` | `needsPairing`; attempts stop; Pair again |
| any | `connections_off` / `pairing_off` / `busy` | `offline(cause)`; a retry on the backoff |
| any | `version` | `offline(versionMismatch)`; attempts stop |
| any | `forget(phone)` | `idle` when it was the phone in use; attempts stop |
| any | `localNetworkDenied` | `offline(localNetworkDenied)`; attempts stop; Open Settings |

| State (phone) | Event | Result |
|---|---|---|
| unpaired | `hello` with "Allow new pairings" on | the pairing phase; `pair.request` → commit → reveal → prompt |
| unpaired | `hello` with "Allow new pairings" off | `error pairing_off` and close, before any code |
| pairing | `Allow` | pins the Mac, `pair.ok`, then `welcome` |
| pairing | `Deny` / 120 s | `pair_denied` / `pair_timeout`, close, and the 30 s cooling window |
| cooling (30 s) | `pair.request` from an unpaired Mac | `pair_denied` and close |
| cooling | a scanned QR | honoured (it needs the person at the Mac's screen) |
| paired | `hello` with "Allow connections" off | `error connections_off` and close |
| paired | `hello` with a pinned fingerprint mismatch | `error bad_pin` and close |
| any (shell) | the app pushes the same identity fingerprint and paired set | no change; the live session keeps running |
| any (shell) | the app pushes a different identity fingerprint or paired set | the live session drops; the cached identity and pairings are forgotten; the push is adopted |
| any (shell) | the app's binder dies (Clear data, uninstall, a kill) | the live session drops; nothing is served until the app pushes again |
| unlinked (shell) | a Mac connects | refused before TLS completes; no identity is presented |

Ignored events, stated so nobody builds them: a second `pair.request` in one session, a `pair.ok` without a pairing in progress, a `cancelPairing` when no pairing is running, a `forget` for a phone that is not the one in use, a probe while the QR sheet is closed, and a QR secret after its fifth minute.

## Phone count and connection

| Situation | Pairing shows |
|---|---|
| 0 phones | The Deck is in Welcome (first run) or Nearby; pairing is the only way out. The phone's home offers "Pair new Mac". |
| 1 phone | A second pairing is allowed and stands alone (its own pin, its own remembered record); the new phone becomes the one in use when the pairing finishes. |
| 2+ phones | Each pinned separately; forget one and the others keep their pins and records. The phone shows one row per paired Mac, the live one first. |
| Connecting | The code sheet's "Contacting <name>…" until the phone shows its code; the phone's prompt appears at the same moment. |
| Connected | No pairing UI. A reconnect uses the pins for ever; the phone's Allow is not asked again. |
| Offline / reconnecting | As Connected: a pairing is not involved. A pairing attempt to an unreachable phone ends "Couldn't reach <name>. Try again." |
| Key rejected | "Pair again" on the Mac and its banner; the phone's `bad_pin` sentence for a rotated Mac certificate. The way back is Pair again — a new pairing with the person's Allow. |
| Phone that can't do the feature | A pre-v2 phone is refused with the version reason (`<name> runs an incompatible version of PocketDeck.`) and no retry loop; the QR and the code flow both need TLS 1.3 and the exporter. |
| Phones' switches off | "Connections are turned off on <name>." (no button) or "<name> isn't accepting new pairings." (no button); the pairing sheet's refusal line for the same two causes. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: no search or filter field in the pairing sheets (the manual sheet's two text fields are not a search) |
| CONV-MAC-02 | applies: the sheets take none of ⌘W/⌘M/⌘Q/⌘,/⌘H; Cancel is the sheets' own button and Esc |
| CONV-MAC-03 | applies: Esc is Cancel in every pairing sheet (PAIR-7), Return is the default button (Try again, Connect), Tab moves between the manual sheet's fields and buttons |
| CONV-MAC-04 | applies: the manual sheet's Address and Port fields are standard text fields (⌘A, ⌘C/⌘X/⌘V, ⌘Z, ⌥←/→) |
| CONV-MAC-05 | n/a: nothing zoomable in a pairing sheet |
| CONV-MAC-06 | applies: no new shortcut; ⇧⌘N (Add Phone…) is in UX.md's table and opens the same add-phone sheet, and every sheet button is a labelled button |
| CONV-MAC-07 | n/a: no shortcut is reused by pairing |
| CONV-MAC-10 | n/a: the sheets are not the status item's panel |
| CONV-MAC-11 | applies: one add-phone sheet at a time and one pairing session; Add Phone… and Pair again open the Deck's one sheet (DECK-17, SET-DEV-05) |
| CONV-MAC-12 | n/a: a sheet is placed by its window, not remembered |
| CONV-MAC-13 | n/a: pairing adds no menu item and no full-screen command |
| CONV-MAC-14 | n/a: the sheets do not resize |
| CONV-MAC-15 | n/a: a cancelled pairing returns to the Deck; nothing quits |
| CONV-MAC-16 | n/a: no drops, paste or Services in the pairing sheets (the manual fields take normal text paste) |
| CONV-MAC-20 | applies: both sheets and the phone's card follow light and dark, the accent and Increase Contrast; the QR is white in both appearances for the scanner's contrast |
| CONV-MAC-21 | applies: the code is one VoiceOver element labelled digit by digit ("Pairing code 1 2 3 4 5 6"), every button is a labelled button, and the reading order is title, code, hint, actions |
| CONV-MAC-22 | applies: the QR success checkmark bounces and the sheets' transitions animate; Reduce Motion removes them |
| CONV-MAC-23 | applies: a refusal is words (never a colour), and the code is text, not an image |
| CONV-MAC-24 | applies: pairing asks for the Local Network permission through the app's first browse and shows "Open Settings" when it is denied (DECK-16); no other permission is asked |
| CONV-MAC-25 | applies: the sheets' buttons are glass with the standard hover and pressed states; a disabled Connect is dimmed neutral |
| CONV-MAC-26 | applies: one 32 pt sheet inset and one 16–24 pt rhythm; the hint line sits under the code it explains |
| CONV-AND-01 | n/a: pairing carries no phone navigation |
| CONV-AND-02 | applies: the phone's prompt and its "Paired Macs" rows follow the system theme; the pairing notification is dismissable and names what it does ("Pair with <Mac name>?") |
| CONV-AND-03 | applies: the phone's notification permission is asked in context (the onboarding step and the pairing prompt), and a denied one disables only the prompt's notification while the in-app card (PAIR-6) is shown regardless |
| CONV-AND-04 | applies: pairing changes only the phone's own paired-clients list; it sets no lock, timeout or app state, and the phone stays locked |
| CONV-PD-01 | applies: the phone-count table above (0, 1, 2+; each pairing stands alone) |
| CONV-PD-02 | applies: the table above (connecting, connected, offline, key rejected, the switches, a pre-v2 phone) |
| CONV-PD-03 | applies: PAIR-3/PAIR-6 (every state on both screens follows the wire's own messages; the sheet never claims a pairing before `welcome`) |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value |
| CONV-PD-05 | applies: PAIR-18 |
| CONV-PD-06 | applies: a pairing is a person waiting on a reply — the connect attempt's limit is `connect_ms` and the phone's 120 s window is its own; no frame work belongs to a sheet |
| CONV-PD-07 | applies: "Pair", "Pair again", "Pair with QR", "Connect manually…", "Add Phone…", "Paired", "Allow"/"Deny" carry one meaning on both ends and in the Deck, Settings and menus |
| CONV-PD-08 | applies: the Mac's `LinkMachine` + `Pairing` and the phone's session/cooldown are the tables above |
| CONV-PD-09 | applies: PAIR-5 and PAIR-13 (each failure names the next step), PAIR-14 ("<name> no longer trusts this Mac." + Pair again), PAIR-9 ("Scan with PocketDeck on your phone") |

## Assumptions

- The phone runs PocketDeck's v2 wire (TLS 1.3 with the exporter) and is on the same LAN, or reachable at an address the person types; nothing goes through a relay during pairing (design/e2ee.md).
- The phone's certificate is self-signed and its identity stays the same for the life of the app's data; only Paired Macs ▸ Forget All Macs… rotates it, and Clear data starts it again. The Mac's is one P-256 identity per profile (IdentityV2).
- The shell-UID service outlives the app process (it runs under the shell UID), so the app pushes its identity and paired set on every bind and the shell serves only while that app binder is alive (PAIR-19/PAIR-20).
- Bonjour discovery gives a device id from the service's TXT record; a phone with no id is ignored, and the service name is never the id.
- Both sides' clocks are irrelevant to the code: it is derived from the exporter and the two nonces, not from time.
- A paired phone accepts exactly one session at a time; "Another Mac is connected" is the phone's own answer, not a Mac-side guess.

## Non-goals

- A relay, a cloud account, an emailed or SMS code, or pairing across networks: LAN or a typed address only.
- Remembering a Mac's pairing in the login Keychain: the profile's own files are the store during the alpha.
- An automatic re-pair without the person's Allow: a lost or changed pin is always a new pairing.
- Several phones connected at once: pairing remembers any number of phones, but the session layer is single-phone today (settings.md).
- The Deck's Welcome/Nearby copy and layout (DECK-17) and the Settings phones list (settings.md): this spec owns the flows, the pins and the recovery.
- Per-Mac permissions or scopes: a pairing is full trust on both ends, revoked by forgetting.

## Open questions

- [NEEDS CLARIFICATION] The QR payload's shape changed from UX.md's `...&k=<64-hex one-time key>` to PROTOCOL.md's `f=<mac fingerprint>&s=<32-hex secret>`. Recommended: PROTOCOL.md wins (code and tests agree); UX.md's pairing table is corrected.
- [NEEDS CLARIFICATION] After a Deny or a 120 s timeout the phone refuses that Mac for 30 s with `pair_denied`, which the Mac's sheet cannot tell apart from a fresh deny. Recommended: keep it silent (the sheet already says "Pairing was denied on the phone." and Try again within 30 s will fail the same way); a person who tries immediately sees one more deny, not a different error.
- [NEEDS CLARIFICATION] The phone's "Paired Macs" rows can only be forgotten by swipe or the overflow menu, with a four-second Undo. Recommended: keep both (swipe is the platform's own gesture, Undo matches the destructive action), and make sure the row's VoiceOver action is the overflow's, not the gesture.
- [NEEDS CLARIFICATION] Should the Mac's Nearby list show a phone that is already paired to **another** Mac? It cannot know. Recommended: no change — "Paired" means paired to this Mac.
- [NEEDS CLARIFICATION] The Mac's identity is per profile and its pin mirror lives in `identity.json` while the phone pins live in `pins.json`; a person who switches profiles keeps one identity per profile and must pair the phone again. Recommended: keep it (profiles are test and reviewer tools), and say so in the spec rather than sharing an identity.
