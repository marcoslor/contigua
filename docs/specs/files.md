# Phone files

Prefix: `FILES`. Owner docs: [design/files.md](../design/files.md) §1, §4–§5 and "Fixes 10-20", [design/dragdrop.md](../design/dragdrop.md), [design/apk.md](../design/apk.md), [UX.md](../UX.md) §4 (the Settings row), [PROTOCOL.md](../PROTOCOL.md) § "Drop Mac → phone", "Phone files" and "APK install", [NFR.md](../NFR.md). Last reviewed: 2026-10-27, against main `6073e3c`.

## Purpose

The phone's shared storage in Finder, and the two ways a Mac file reaches the phone. One opt-in switch puts a location — "PocketDeck (<phone name>)" — in Finder, served by a File Provider extension that asks the running app (the only owner of the session) over a private socket in the app's group; browsing, opening, copying in and out, renaming and deleting all act on the phone's own `/sdcard`. Separately, a file dropped on a window or the Deck is transferred into `Download/PocketDeck/`, and an Android package (`.apk`, `.apks`, `.xapk`) opens the installer instead. Both are person-started, one at a time, verified by SHA-256, and neither leaves anything on the phone when it fails.

## User stories

| ID | Priority | Story |
|---|---|---|
| FILES-S1 | P1 | As a person, I want the phone's files in Finder so that I can drag a photo out and a document in without a cable. |
| FILES-S2 | P1 | As a person, I want the switch off until I ask for it, and to be told what else macOS needs, so that no location appears behind my back. |
| FILES-S3 | P1 | As a person, I want deletions, renames and copies to act on the phone, so that Finder is not a stale copy. |
| FILES-S4 | P1 | As a person, I want to know when the phone is away and what still works, so that Finder's own cache is not mistaken for the phone. |
| FILES-S5 | P2 | As a person, I want a change made on the phone to appear in Finder while I look at it, so that I do not refresh by hand. |
| FILES-S6 | P1 | As a person, I want to drop a file on the phone's window and be told it arrived, so that sending one file is one gesture. |
| FILES-S7 | P1 | As a person, I want to install an app by dropping its package, so that I do not need a store or a cable. |
| FILES-S8 | P1 | As a person, I want a refusal to say what went wrong, so that a failed drop or install is not a silent no. |
| FILES-S9 | P2 | As a person, I want a 200 MiB drop and a 1 GiB install to be refused before they waste the link, so that the answer is quick. |

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| FILES-1 | THE Finder location SHALL exist only WHILE the person's switch is on: Settings ▸ General ▸ "Show phone files in Finder" (off by default, per profile) SHALL add one File Provider domain whose identifier is the profile's name, and turning it off SHALL remove the domain and its folder; a launch with the switch on SHALL re-add or re-adopt it and start the bridge. | K2 `FilesDomainControllerTests.testTheSettingOffMeansNoDomain`, `testEnablingAddsOnceAndShowsTheSwitchPrompt`, `testTurningOffRemovesTheDomainAndStopsTheBridge`, `testAnExistingEnabledDomainAtLaunchAddsNothing`; VM e2e `files-domain` |
| FILES-2 | THE location's name SHALL be "PocketDeck (<phone name>)" — the nickname first, else the phone's own name — and plain "PocketDeck" while no name is known; WHEN the name changes (a rename, or the name arriving after the domain was added) THE Mac SHALL re-add the same identifier with the new name so the folder and its cached files stay. | K2 `FilesDomainControllerTests.testTheLocationNameCarriesThePhoneName`, `testARenameUpdatesTheExistingDomainInPlace`, `testTheNameIsNotReAddedWhenItAlreadyMatches`, `testTheNameArrivingAfterTheAddUpdatesTheDomain`; VM e2e `files-domain` (the location is "PocketDeck (FakePhone)") |
| FILES-3 | WHEN a domain is added THE Mac SHALL report that macOS keeps a new File Provider switched off until the person turns PocketDeck on in System Settings ▸ Login Items & Extensions, say so in the Settings row and once in the Deck, and offer Open System Settings and Check again; coming back to the app SHALL re-read the switch and move the row to on without adding or removing anything. | K2 `FilesDomainControllerTests.testAnExistingDisabledDomainAsksForTheSwitch`, `testTheSwitchTurningOnMovesTheStateToOn`, `testThePromptButtonOpensSystemSettings`; VM e2e `files-domain` (the System Settings switch, then the domain enumerates) |
| FILES-4 | IF this bundle carries no App Group or no `Contents/PlugIns/Files.appex` THEN the row SHALL be disabled with "This copy of PocketDeck was built without Finder files." and no domain SHALL be added; IF the system refuses an add or a remove THEN the row SHALL say Finder files could not be turned on and suggest the switch off and on again, never an internal code. | K2 `FilesDomainControllerTests.testABundleWithoutTheExtensionNeverAddsADomain`, `testNoBridgeWithoutAnAppGroup`, `testAFailedAddIsReported`, `FilesBundleSupportTests.testAGroupAndAnExtensionAreBothNeeded` |
| FILES-5 | THE location's root SHALL list the phone's `/sdcard` without its dot-prefixed top-level entries, without `Android`, and without the phone's own `.pocketdeck-*.part` staging files; a request for `..`, an absolute path, a backslash, a NUL, an over-long path or a symlink that lands on `Android/` or a dot entry SHALL answer `fs_denied` and SHALL have no effect. | e2e `files` `[FILES-5]` (the root's names and sizes, the three refusals); K1 `FsPathsTest` (every shape rule, the symlink rule) |
| FILES-6 | WHEN a folder is listed THE reply SHALL carry each visible item's name, folder flag, size, modification date and etag, page by page, so that a folder of 1500 files lists every name exactly once. | e2e `files` `[FILES-6]` (1500 names exactly once across pages); K1 `FsViewTest`, K2 `FsClientTests.testListPagesParseAndCarryTheCursor` |
| FILES-7 | WHEN a file is read THE Mac SHALL send the etag it has, SHALL verify the phone's SHA-256 against the bytes it wrote and remove a file that fails, and SHALL refuse a short read or more bytes than announced; WHEN the person cancels THE Mac SHALL send one `fs.cancel` and drop the frames that follow. | e2e `files` `[FILES-7]` (byte-identical 3 MiB and 32 MiB reads, a stale etag refused with nothing written, the cancelled read stopped on the phone); K2 `FsClientTests.testAWholeFileReadStatsFirst`, `testAChecksumMismatchFailsAndRemovesTheFile`, `testCancelSendsFsCancelAndDropsLaterFrames`; K1 `FsReaderTest` |
| FILES-8 | WHEN the person writes in the location — a copy in, an edit in place, a rename, a new folder, a delete — THE change SHALL reach the phone, and a copy onto a name the phone already has SHALL land under the next free name (" 2", " 3"…) without replacing the phone's bytes; a write interrupted by a crash SHALL leave neither a staging file nor a partial file on the phone; an operation that would change nothing SHALL send no write. | VM/host e2e `files-write` (the copy, the edit, the rename, mkdir, delete, the collision's next free name, the killed write); K2 `FilesCoreTests.testATakenNameIsNumbered`, `testNothingStoredChangedIsNoWrite`, `testEachStoredFieldIsAWrite`; K1 `FsMutationsTest` |
| FILES-9 | WHEN a read-only view is used — browsing, opening a preview, listing — THE Mac SHALL send no write to the phone. | VM e2e `files-domain` (a preview sends no bridge modify) |
| FILES-10 | WHILE the session is up THE domain SHALL be reconnected and its working set signalled; WHEN the phone goes away THE domain SHALL be disconnected with the reason "Phone not connected" and already-fetched files SHALL still open; WHEN it returns THE domain SHALL reconnect, and a copy made while it was away SHALL be kept pending and SHALL land on the phone after the reconnect. | K2 `FilesDomainControllerTests.testSessionTransitionsReconnectAndDisconnectOnce`, `testAPhoneSideChangeSignalsTheWorkingSet`; VM e2e `files-domain` (disconnect, the cached file opens, the pending copy lands) |
| FILES-11 | THE extension SHALL NOT hold a session of its own: it SHALL reach the phone only through the app's bridge on a private socket in the App Group container, SHALL refuse another protocol version, SHALL answer every request while the session is down without inventing a reply, and SHALL be brought up again by a relaunch so that the domain lists again. | K2 `FilesBridgeTests` (the socket's mode, the version, the offline answers, the caps of 8 live ids and 6 clients, the oversized line); VM e2e `files-domain` (a relaunch lists again) |
| FILES-12 | WHILE the person looks at a folder in Finder THE Mac SHALL keep that folder watched on the phone (at most 64 folders, ten minutes after the last touch, the least recently touched dropped first; a file's touch watches its folder), SHALL show the phone's creates, edits, renames and deletes in the mount, SHALL keep an item's identifier across a rename, and SHALL stop watching when the folder closes or the extension goes away; nothing SHALL be watched while no folder is open, and a working-set identifier SHALL never ask the phone to watch anything. | K2 `FilesBridgeTests.testATouchAsksThePhoneOnceAndARepeatedOneNothing`, `testAFolderIsUnwatchedWhenItsTenMinutesAreOver`, `testTheSixtyFifthFolderDropsTheLeastRecentlyTouched`, `testAWorkingSetIdentifierNeverTouchesThePhone`, `FilesWatchSetTests` (the cap, the TTL, the order), `FilesCoreTests.testARenameKeepsTheIdentifier`; host e2e `files-watch`; VM e2e `files-domain` (create, rename, delete in the mount) |
| FILES-13 | WHEN a file is dropped on an app window or the Deck THE Mac SHALL announce it (`drop.start` with name, mime, size and SHA-256), pace the bytes, honour the phone's progress and resume offset, send one file at a time, and finish with the phone's single `drop.result`; the phone SHALL save it under `Download/PocketDeck/`, verify the digest and media-scan it. | e2e `drop` `[FILES-13]` (32 MiB byte-exact with no tail re-send, 3 MB, the handler's own announce); K2 `FileDropTests.testAnnouncesThenStreamsThenFinishes`, `testDelayedAcksAndALateOffsetDoNotResendTheTail`, `testResumeCarriesTheOffsetAfterALostConnection`; K1 `DropReceiverTest`, `ShareSenderTest` |
| FILES-14 | THE window SHALL show the transfer as one glass pill — "Sending <name>… 43 %" while it runs, then the outcome for 5 s, then nothing; a second drop WHILE one runs SHALL be refused with "The phone is still taking a file." and SHALL NOT interrupt the first, and a drop while the phone is away SHALL be refused with "Connect a phone to send files to it." rather than queued. | e2e `drop` `[FILES-14]` (the outcome pill shown, hidden after 5 s, the app still one instance); K2 `FileDropTests.testTheOutcomeTimesOutIntoIdleAndReportsIt`; review of `FileDropSender.send`/`ConnectionController.dropFiles` |
| FILES-15 | WHEN a drop or an install is refused THE Mac SHALL say why in the person's words — "The phone refused it: the file is bigger than the phone's cap.", "The phone is busy with another file.", the phone's own message for a bad name, "Wait for the current install to finish." for a second install — and SHALL NOT claim the file was saved. | e2e `drop` `[FILES-15]` (`ok=false too_large` and the refusal sentence); K2 `FileDropTests.testOverTheCapRefusesNothingSent`, `ApkBundleTests.testFailureCodesReadAsSentences`; K1 `DropPolicyTest` |
| FILES-16 | THE installer SHALL be reachable from Phone ▸ Install APK…, a drop of a package, Open With / `open -a` (the app's document types) and the "Install on Phone" Service; ONE install SHALL run at a time on the phone in use, and its phase SHALL read "Sending x.apk… 40 %" then "Installing x.apk…" wherever it is shown; an install asked for while the phone is away SHALL wait for the link for up to 120 s rather than be refused (a drop is refused; see Open questions); with several phones the Mac SHALL ask which one and, if it is not the one in use, SHALL make it the phone in use first (one session teardown, as settings.md SET-DEV-03). | e2e `apk` `[FILES-16]` (the progress lines, the one instance); K2 `FileDropTests`/review of `ApkInstall` and `LinkRoute`; menus.md MENU-5, panel.md PANEL-16 |
| FILES-17 | THE Mac SHALL read the package before sending: an `.apk` SHALL carry `AndroidManifest.xml`; an `.apks` or `.xapk` SHALL send its `.apk` parts with the base first and no standalones; an entry name with `..`, a leading `/`, a backslash or a NUL SHALL reject the whole file; a bundle over 1 GiB SHALL be refused. | K2 `ApkBundleTests` (every format, the traversal, the cap, the part names) |
| FILES-18 | WHEN the install finishes THE Mac SHALL show the phone's own result — "Installed <label> <version>." on success, a mapped sentence on failure (a newer version is already on the phone, a signature or update conflict, storage, ABI, SDK, parse) — and SHALL request the app list again so the new icon appears. | e2e `apk` `[FILES-18]` (the result sentence, the app list refreshed, the downgrade's sentence); K2 `ApkBundleTests.testFailureCodesReadAsSentences`; K1 `ApkInstallerTest` |
| FILES-19 | THE bridge, the extension, the drop sender and the installer SHALL write no file name, path, file content or app label to a log or a crash report: operation names, counts, sizes and hash prefixes only; the person's own file name MAY appear on the window and in the banner's text, which the person can see. | K2 `FilesBridgeTests` (the log lines carry op names and sizes), `NotifyMacTests.testRecordsCarrySizesAndPackagesNotText` (the same rule on the wire); host e2e `files-bridge` and `files-write` (no name from the tree in the app log); review of `FilesBridge`, `FsClient`, `FileDrop`, `ApkInstall` |
| FILES-20 | EVERY control SHALL be reachable at 1280×800 and SHALL be honest about its state: the Settings switch is disabled with its sentence when the build cannot serve Finder, the deck's prompt line names the system switch, and no row claims the phone is reachable while it is away. | K2 `FilesDomainControllerTests` (the states), `LayoutTests` (the Settings page's last control is reachable); VM e2e `files-domain` (the switch's states) |
| FILES-21 | A small file's fetch (a Quick Look preview) SHALL complete within `fetch_small_ms` (3000 ms, NFR.md), and a folder's listing SHALL show its first page without waiting for the whole folder. | VM e2e `files-domain` (the 412-byte and 1 MiB fetches against the limit); K2 `HangingPeerTests` (a terminal reply ends the request) |

Priority note: FILES-1, 2, 3, 5, 7, 8, 10, 12, 13, 15 and 16 are P1 — a location that appears by accident, lies about the phone, or silently loses a file is worse than no location. The watch detail, the caps and the fetch limit are P2.

## States and events

The switch's machine is one value per profile (`FilesDomainController.State`); the domain's traffic state follows the session; the drop sender is a second, small machine (`FileDropSender`: idle → announcing → sending → settling → idle). Watches and pending writes are the bridge's own sets, not modes.

| State | Event | Result |
|---|---|---|
| Off | `setEnabled(true)` | Adding: the bridge starts, the domain is added; → Needs switch (a new domain is user-disabled) or On when the system already has it enabled |
| Adding | `add ok` / `add failed` | Needs switch / Failed |
| Needs switch | `the person flips System Settings and returns` | On (refresh only; nothing is added or removed) |
| On | `setEnabled(false)` | Off: the bridge stops, the domain is removed |
| On | `session up` | reconnect + one working-set signal |
| On | `session down` | disconnect(reason "Phone not connected"); cached files still open |
| On | `a phone-side change` | the working set is signalled (coalesced) |
| any | `this bundle has no extension` | Off, row disabled with its sentence, one log line |
| Failed | `setEnabled(false)` then `(true)` | Off, then Adding again (the row's own advice) |

| State (drop) | Event | Result |
|---|---|---|
| Idle | `the person drops a file` | Announcing: `drop.start` (the phone may answer a resume offset) |
| Announcing | `the phone's first progress` | Sending: paced chunks, the pill shows the percentage |
| Sending | `progress` | the pill's percentage follows (at most 4 a second) |
| Sending | `result ok` | Settling: the outcome pill for 5 s → Idle; the phone's path is not shown |
| Sending | `result bad` / `session lost` | Settling: the refusal sentence for 5 s → Idle |
| Announcing / Sending | `a second drop` | refused with "The phone is still taking a file." — the first one continues |
| Idle | `a drop while the phone is away` | refused with "Connect a phone to send files to it."; nothing queued |
| any | `a bundle dropped` | the install route instead (`apk.install`); an install waits up to 120 s for the link |

Ignored events, stated so nobody builds them: a working-set identifier as a watch request, a touch whose ten minutes have passed, a signal with the switch off and no adopted domain, a copy while the phone is away that the extension answers from its own cache, a `drop.progress` after the result, and a second `drop.start` while one runs.

## Phone count and connection

| Situation | Files shows |
|---|---|
| 0 phones | The switch can be turned on (the notification, the domain and the bridge need no phone) but the location is empty and every listing answers "Phone not connected"; a drop is refused ("Connect a phone to send files to it.") and an install is kept pending for 120 s with "Pair a phone to install apps on it.". The location's name is plain "PocketDeck". |
| 1 phone | That phone's storage, named "PocketDeck (<name>)"; drops and installs go to it. |
| 2+ phones | The location follows the phone **in use** (the domain's name changes with Settings ▸ Use This Phone); the other phones' storage is not mounted. A drop and an install act on the phone in use. |
| Connecting | The domain is disconnected until the session is ready; already-fetched files open, listings answer from the Mac's own cache or say the phone is not connected. |
| Connected | Live listings, reads, writes, watches and drops. |
| Offline / reconnecting | "Phone not connected": the domain disconnects, cached files still open, a copy is kept pending and lands after the reconnect, a drop is refused and an install waits up to 120 s for the link. |
| Key rejected (Pair again) | As offline; nothing pairs or re-pairs from this surface. |
| Phone that can't do the feature | A build without the extension disables the switch with its sentence; a phone that refuses `fs.*` reports the phone's error code as a sentence, and no fallback to another transport exists during the alpha. |
| Install running / a drop sending | One at a time per phone; the second is refused with its reason. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: the location has no search field of its own (Finder's is Finder's) |
| CONV-MAC-02 | applies: ⌘W closes the Finder window, ⌘, opens Settings, ⌘Q quits; this surface takes none of them |
| CONV-MAC-03 | applies: Finder's own Esc, Return and Tab behaviour, since the location is drawn by Finder; the installer's panel is the system's open panel |
| CONV-MAC-04 | applies: Finder's own text fields (the Settings row's fields are none) |
| CONV-MAC-05 | applies: Finder's own icon-size and view commands |
| CONV-MAC-06 | applies: no shortcut is added; "Install APK…" is in the Phone menu and Shortcuts has no files entry |
| CONV-MAC-07 | n/a: no shortcut is reused |
| CONV-MAC-10 | n/a: not the status item's panel |
| CONV-MAC-11 | applies: one location per profile (one domain, removed rather than duplicated); one installer panel |
| CONV-MAC-12 | n/a: the location is not a window; Finder remembers its own windows |
| CONV-MAC-13 | n/a: no menu item of its own beyond Phone ▸ Install APK… |
| CONV-MAC-14 | n/a: no app-drawn content to resize |
| CONV-MAC-15 | n/a: closing a Finder window quits nothing |
| CONV-MAC-16 | applies: FILES-8 and FILES-13 (a copy in behaves as Finder's; a drop highlights, is accepted or refused with a reason); **deviates**: a delete in the location deletes for ever — there is no Trash on the phone (the Settings row says so; see Open questions) |
| CONV-MAC-20 | applies: the Settings row, the prompt line and the pill render in light and dark with the accent and Increase Contrast |
| CONV-MAC-21 | applies: the switch, its sentence and the two buttons are labelled; the pill's text is readable and its percentage is text, not a bar alone |
| CONV-MAC-22 | applies: the prompt's move transition is the only motion; Reduce Motion removes it |
| CONV-MAC-23 | applies: every state is a sentence (needs switch, failed, not connected, refused) and never a colour alone |
| CONV-MAC-24 | applies: turning the switch on is the moment macOS is asked for the File Provider switch, and the row says what to do; no other permission is asked |
| CONV-MAC-25 | applies: the Settings switch and the prompt's buttons are native controls with their hover, pressed and disabled states (disabled is dimmed neutral) |
| CONV-MAC-26 | applies: one side inset and one 8/12 pt rhythm in the Settings section and the Deck's prompt line; each helper sentence sits under the control it explains |
| CONV-AND-01 | n/a: no phone navigation |
| CONV-AND-02 | applies: the phone writes its received files into `Download/PocketDeck/` and shows the system's own progress notification, which names what it is doing and is dismissable; the drop's SEND chooser is the app's own UI on the phone |
| CONV-AND-03 | applies: the phone needs no runtime permission for the drop (shell UID writes the file) and the installer runs at shell UID; a phone without Shizuku says so on its own home, not here |
| CONV-AND-04 | applies: the only phone-side effects are the files the person copied and the app they installed; the phone stays locked, and no setting is changed |
| CONV-PD-01 | applies: the phone-count table above (0, 1, 2+; the location and every action follow the phone in use) |
| CONV-PD-02 | applies: the table above (connecting, connected, offline, key rejected, a build without the extension, a phone that refuses `fs.*`) |
| CONV-PD-03 | applies: FILES-13 and FILES-18 (a drop's and an install's outcome is the phone's own `result`, never a local guess; the pill says "Sending…" until the phone answers) |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value (the drop's percentage follows the phone's progress reports; the person does not drag it) |
| CONV-PD-05 | applies: FILES-19 |
| CONV-PD-06 | applies: FILES-21 (`fetch_small_ms`); the bridge runs no work when nothing is browsing, and a drop is paced so it cannot starve the video queue (≤256 KiB, ≤4 in flight — design/dragdrop.md) |
| CONV-PD-07 | applies: "Show phone files in Finder", "Install APK…", "Install on Phone", "Move Phone App to Mac" (not this surface), and the location's name "PocketDeck (<phone name>)" are one name each |
| CONV-PD-08 | applies: the switch/domain machine, the session's effect on it and the drop sender are the tables above |
| CONV-PD-09 | applies: FILES-4 (the row's sentences name the next step), FILES-15 (a refusal says why), FILES-3 ("Open System Settings" and "Check again" name what they do) |

## Assumptions

- The app is the only holder of the phone's session; the extension is a replicated File Provider that reaches the app over `NSFileProviderManager`'s own lifecycle and a unix socket in the App Group container (`PDFilesGroup`).
- macOS 26's File Provider keeps a newly added domain user-disabled until the person flips its switch in Login Items & Extensions; there is no API for that switch.
- The phone writes its files at shell UID (Shizuku): `/sdcard` is readable, `Android/` and dot entries are deliberately not.
- A drop's 200 MiB cap is counted while receiving on the phone; an install's 1 GiB cap is the bundle's total. Neither number lives in NFR.md (they are protocol caps, not time limits).
- Finder, not this app, draws the location: the icon view, the columns, Quick Look and the progress UI are the system's.

## Non-goals

- A second transport for files (WebDAV, SMB, FUSE, a Mac-side cache): the File Provider is the one (design/files.md "Alternatives rejected").
- Browsing `Android/` or other apps' private storage at shell UID: the location shows what a person calls phone storage.
- A Trash on the phone, or undoing a delete from Finder (see Open questions).
- Drag out of a phone window (design/dragdrop.md "Drag out", design only) and clipboard images (`share-clipboard` surface).
- Uploading a folder tree in one drop, or a queue of several drops: one file at a time, in order, and a second is refused.
- Installing an app on a phone other than the one in use, or choosing ABI/density splits on the Mac.
- The phone's own file UI, its Downloads folder or its media library as a surface: the phone's storage is the surface.

## Open questions

- [NEEDS CLARIFICATION] Deleting in the location deletes for ever — no Trash, and the person cannot undo it from Finder (CONV-MAC-16's Finder behaviour). Recommended: keep it and keep the Settings row's sentence (a phone-side `.trash` would change what Files shows on the phone), and prove the delete's irreversibility in the VM check's copy so nobody is surprised.
- [NEEDS CLARIFICATION] settings.md's settings inventory does not list "Show phone files in Finder" (nor the other General/Input switches), so the one place that claims to bind every setting is incomplete. Recommended: add the row to that inventory in a follow-up (it is specs-1's file, not this epic's), with its store `files.showInFinder`, default off, and "no" in the panel column.
- [NEEDS CLARIFICATION] The watch cap is 64 folders on the Mac with a ten-minute TTL, while the phone's own inotify guard is 256 and the design still calls the number unmeasured (design/files.md "Open questions"). Recommended: keep 64 (the folder poll is the safety net) and record the measured cost in the design doc when someone measures it.
- [NEEDS CLARIFICATION] Thumbnails: the extension today asks the Mac's Quick Look for a materialized file rather than a phone-side `fs.thumb`. Recommended: keep it (no new wire message, no phone work while nobody browses) and say so in the design doc.
- [NEEDS CLARIFICATION] A drop while the phone is away is refused, but an install asked for while it is away waits up to 120 s for the link and shows no "waiting" state in between (CONV-PD-03). Recommended: keep the wait (a person who picks Install APK… expects it to go when the phone returns) and show "Waiting for your phone…" as the install's phase, and say "Connect a phone to install apps on it." rather than "Pair a phone" while a phone is paired but away; the alternative — refusing it like a drop — makes the menu item useless on a phone that is briefly away.
