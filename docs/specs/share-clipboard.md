# Share and clipboard

Prefix: `SHARE`. Owner docs: [design/sharein.md](../design/sharein.md), [design/links.md](../design/links.md), [design/dragdrop.md](../design/dragdrop.md), [design/handoff.md](../design/handoff.md), [PROTOCOL.md](../PROTOCOL.md) § "Clipboard sync", "Clipboard images", "Links", "Drop Mac → phone", [UX.md](../UX.md) § "Pairing model" and § "macOS app", [NFR.md](../NFR.md). Last reviewed: 2026-10-27, against main `12f9d7a`.

## Purpose

Moving what a person has between the two devices without a cable or a cloud: plain text and images on the clipboard in both directions, phone Share → **Send to Mac** (a link opens, text lands on the clipboard, an image is saved), the Mac's **Open on Phone** for a link, **Move to Mac** for the app in front on the phone, and a Finder drop onto a window or the Deck. Everything is person-started and validated on both ends; nothing is queued while a phone is away. The file transfer itself, its pill and its refusals are files.md's (`FILES-13`–`15`), the phone's Share target is its own Android surface (phone-app.md), and the notifications these actions post are the system's, not notifications.md's forwarded ones.

## User stories

| ID | Priority | Story |
|---|---|---|
| SHARE-S1 | P1 | As a person, I want to copy on one device and paste on the other, so that text and images move without retyping. |
| SHARE-S2 | P1 | As a person reading something on my phone, I want Send to Mac to open the link or copy the text, so that I continue on the Mac in one tap. |
| SHARE-S3 | P1 | As a person looking at a link on the Mac, I want Open on Phone to open it in a window on the phone, so that I can pick it up there. |
| SHARE-S4 | P2 | As a person with an app in front on the phone, I want Move to Mac to bring that app into a Mac window, so that I keep my place. |
| SHARE-S5 | P1 | As a person, I want a file dragged onto a window or the Deck to reach the phone, so that sending one file is one gesture. |
| SHARE-S6 | P1 | As a person, I want a secret I copied not to travel, and nothing I share in a log, so that the convenience does not cost privacy. |
| SHARE-S7 | P2 | As a person, I want ⌘V in a phone window to paste the image or files I copied on the Mac into that app, so that a copy-paste works across the two devices. |
| SHARE-S8 | P2 | As a person, I want to drag an image from a browser, a web image or a photos promise onto a window or the Deck, so that any picture reaches the phone in one gesture. |

## Settings inventory

| Setting | Scope | Store (profile defaults) | Default | What it does | In the panel? |
|---|---|---|---|---|---|
| Share clipboard with your phone | per profile | `shareClipboard` | **off** | Off on a fresh profile and off until the person turns it on (AGENTS.md: personal data is opt-in); a stored answer, on or off, is the person's and is never overridden. The switch for the automatic background sync (`clip.set` and unprompted `clip.image.*`) in both directions: it is sent to the phone at every `welcome` and on every change (`clip.enable`, SHARE-13), so while it is off the phone neither sends nor applies either; a change made while off is not sent when it comes back. It never gates the person's own explicit action: a drop (SHARE-11) and a ⌘V in a window (SHARE-16/17) happen while it is off | no |

Everything else this surface does (Open on Phone, Move to Mac, a drop, a ⌘V, Send to Mac) has no setting: each is a person's action.

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| SHARE-1 | WHILE the session is ready, "Share clipboard with your phone" is on and the phone has been told so (SHARE-13) THE Mac SHALL send `clip.set` when its general pasteboard changes to new text, apply a `clip.set` from the phone to its pasteboard, and neither side SHALL echo back text it last sent or received; an item carrying `public.file-url` is a file copy and never takes this path (SHARE-2); empty text and text over 1 MiB (UTF-8 bytes) SHALL NOT be sent and a receiver SHALL ignore an over-cap message; the text already on the clipboard at `welcome` SHALL NOT be sent, and a change made while the setting is off SHALL NOT be sent when it comes back on. | e2e `clip` `[SHARE-1]` (phone → Mac, no echo, Mac → phone, no echo); K2 `ClipboardSyncTests` (the timer, the limit, the echo hash, the off/on rule); K1 `SessionTest` (the gate) |
| SHARE-2 | THE Mac SHALL send a clipboard image when the changed item has image data and no text (PNG verbatim, JPEG verbatim, TIFF converted to PNG) and SHALL apply an image from the phone the same way, at most 8 MiB each way, one image in flight per direction, recording the bytes' SHA-256 so an image is never echoed; the app process SHALL write such an image to its clipboard as one item carrying only the image's URI (no text, no intent), so a plain text field pastes nothing (a content URI that cannot serve text coerces to null, never to its `content://` string) while a field whose content listener accepts image types still receives the URI; an over-cap image SHALL NOT be sent and a receiver that sees an over-cap size SHALL ignore it; a text item always takes the text path. A pasteboard item carrying `public.file-url` SHALL be treated as a file copy: its text (the file's name) SHALL NOT be sent as text; WHEN the copy is exactly one file whose type conforms to `public.image` and whose size is at or under 8 MiB THE Mac SHALL send it as a clipboard image (PNG and JPEG verbatim; any other image type re-encoded, as PNG when it has alpha and as JPEG at quality 0.9 when it is opaque, so a HEIC photo fits the cap, with its orientation kept; a result over 8 MiB sends nothing), and any other file copy (not an image, several files, over 8 MiB or unreadable) SHALL send nothing; the secret-type skip (SHARE-3) still applies first. | K2 `ClipboardImageSyncTests.testAnImageWithoutTextIsSentOnce`, `testTextNextToAnImageGoesThroughTheTextRule`, `testAnImageOverTheCapIsNeverSent`, `testReceivedImageLandsAndIsNotEchoed`, `ClipboardSyncTests.testAFileCopyNeverSendsItsNameAsText`, `testASinglePNGFileCopySendsTheFile`, `testATIFFFileCopyBecomesPNG`, `testAnOpaqueHEICFileCopyBecomesJPEG`, `testTwoFilesSendNothing`, `testANonImageFileSendsNothing`, `testAnOversizedImageFileSendsNothing`; K1 `PasteKeyTest.aUriOnlyImageItemNeverBecomesText` (the item, and its coerced text is empty), `testAnImageGoesToTheAppAndItsLateAnswerIsTheDone` (the app's answer is the only `done`), `testWithoutAnAppWriterTheAnswerIsFalse`; `ClipImageBridgeTest` (the fd, no callback, the 3 s timeout, a late answer), `ClipImageWriterTest` (the app's item, its MIME and authority, newest-only, over-cap), `ClipEchoTest` (our provider authority is never synced back); e2e `clip` `[SHARE-2]` (a Finder copy's name never reaches the phone) and `paste` (a Mac image reaches the fake phone and its confirmation gates the key); emulator A2 (boot 7): `clip.image.done ok=True`, `ClipImageWriter: set (592 bytes)` and `clip image: app answered ok=true (592 bytes)` from the background, the plain field stayed at 0 and the image field read 592 bytes. Boot 5's H1 cause was `setPrimaryClip(image) failed: InvocationTargetException` (ClipboardService's owner check); H2's was a shell-written file the app could stat but not open (`EACCES`). Which real apps accept a pasted image is still the real-phone spike's Q2 |
| SHARE-3 | THE Mac SHALL skip a pasteboard item carrying any password-manager secret type (`ConcealedType`, `TransientType`, `AutoGeneratedType`) in text and image directions. | K2 `ClipboardSyncTests.testSecretItemsAreSkipped` (the type guard is read before the text/image split); review of `ClipboardSync.poll` |
| SHARE-4 | WHEN the phone sends `share.text` THE Mac SHALL trim it and, if it is exactly one `http`/`https` URL with a host or contains exactly one such URL among words, open that URL in the default browser, else copy the whole text and post "Copied from <phone name>" whose body is its first 120 characters; `file:`, `javascript:`, `pocketdeck:`, `intent:`, a custom scheme or two URLs SHALL never open, only be copied; an empty or over-1 MiB text SHALL be ignored; at most one automatic browser open SHALL happen per phone per 3 s, a held-back link SHALL arrive as a "Link from <phone name>" notification carrying only its host, and a click on it SHALL open the link. | e2e `sharein` `[SHARE-4]` (the URL, the text, the `file:` case, the banners); K2 `ShareInTests.testWebLinksAreLinks`, `testOtherTextIsText`, `testOnlyHttpAndHttpsAreEverOpened`, `testEmptyAndOversizedTextIsIgnored`, `testTheOpenLimiterAllowsOneLinkPerPhonePerWindow`, `testTheInboxHoldsASecondLinkInsideTheWindowAsANotification` |
| SHARE-5 | WHEN the phone sends `share.file` + `SHARE_DATA` + `share.end` THE Mac SHALL accept only `image/*`, count bytes to 50 MiB, verify the SHA-256 and the announced size, save to `~/Downloads/PocketDeck/` under the phone's name reduced to `[A-Za-z0-9 ._-]`, no leading dot and ≤ 100 characters (extension from the MIME type when missing, " 2", " 3"… on a collision), put the file URL and image on the pasteboard, and post "Image from <phone name>" (its body is the saved file's name) with Show in Finder; over the cap, a mismatch or a write failure SHALL delete the partial file and post a refusal; an unfinished file SHALL be discarded on abort, a new begin or a disconnect; nothing partial SHALL be left in the folder. | e2e `sharein` `[SHARE-5]` (same SHA-256, no leftovers); K2 `ShareInTests.testSanitizedNames`, `testCollisionsGetANumber`, `testSavesAnImageAndNumbersASecondOne`, `testSizeCapRefusesAndCleansUp`, `testChecksumMismatchAndNonImagesAreRefused`, `testAbortAndNewBeginDropThePartialFile` |
| SHARE-6 | THE phone's "Open on Mac" text menu and Open with / browser entry SHALL run the same pipeline as Send to Mac: the text menu reads only `EXTRA_PROCESS_TEXT`, never replaces the source text, and the viewer accepts only an `http`/`https` data URI that passes `LinkPolicy`, finishing silently otherwise; neither may open a stream or trust the other extras. | K1 `OpenOnMacIntentTest`, `ShareIntentTest` (the aliases' parse rules); review of `ShareActivity`'s alias dispatch |
| SHARE-7 | THE Mac SHALL allow only `http`, `https`, `geo`, `tel` and `mailto` links, at most 8 KiB of UTF-8, with no whitespace or control character inside and a host for `http(s)`, trimming surrounding whitespace; everything else SHALL be refused before it reaches the phone; the phone SHALL re-validate every link it is asked to open. | e2e `links` `[SHARE-7]` (a `file:` link never reaches the phone); e2e `share` `[SHARE-7]` (text with no link and a `file:` URL are refused); K2 `OpenLinkTests.testAllowsTheViewSchemes`, `testTrimsSurroundingWhitespace`, `testRejectsEverythingElse`, `testLimitIsInUtf8Bytes`; K1 `LinkPolicyTest` |
| SHARE-8 | THE Mac SHALL accept a link from the Share extension, the "Open on Phone" Service, a URL or `.webloc` dropped on the Deck, and the `pocketdeck://open` hand-off, and SHALL route it: a named phone that is remembered goes there, one remembered phone goes there, several without a name open "Open on which phone?" with the connected phone first and the choice used for that request; with no phone the link SHALL wait up to 120 s and the Mac SHALL say "Pair a phone to open links on it."; a phone that is not the connected one SHALL become the phone in use and get the link after `welcome`; opening SHALL create one stream window and the phone SHALL resolve the app itself. | e2e `links` `[SHARE-8]` (one `link.open`, a window with video, one instance); K2 `OpenLinkTests.testRoutesToTheNamedPhone`, `testOnePhoneNeedsNoPicker`, `testSeveralPhonesAskWithTheConnectedOneFirst`, `testNoPhoneWaits`; K1 `LoopGuardTest` (the loop guard: we never handle our own link) |
| SHARE-9 | THE "Open on Phone" Share extension SHALL be a sandboxed `com.apple.share-services` extension with its own bundle id, accept the first web URL item or text that is or contains exactly one link, send `pocketdeck://open?url=…` to its containing app only, and cancel on text without a link or a `file:` URL; it SHALL have no UI, and the e2e copy SHALL be unregistered after its run. | e2e `share` `[SHARE-9]` (the extension's Info.plist, sandbox, PlugInKit listing, both hand-offs, one instance, unregistered); K2 `ShareInputTests` (URL and text picking, the scheme); review of `ShareHandoff` |
| SHARE-10 | WHEN the person chooses Move to Mac (⇧⌘C, Phone ▸ Move Phone App to Mac, or the panel's Move to Mac) WHILE the phone is online THE Mac SHALL open a handoff window that sends `task.continue` and the phone SHALL move the newest foreground app on display 0 onto the new display, answer `started:"moved"` and return display 0 to its home screen; IF the move is refused or unverified THEN the phone SHALL relaunch the same package and answer `started:"fresh"` and the window SHALL say "Opened fresh: the app couldn't be moved"; IF nothing is continuable (ours, home, SystemUI) THEN the phone SHALL answer `nothing_to_continue`, the Mac SHALL remove the never-opened window and say "Nothing to move. Your phone is showing its home screen or PocketDeck."; a reconnect SHALL re-open the same package, never whatever is foreground then. | e2e `handoff` `[SHARE-10]` (moved with a titled window, fresh, nothing); K2 `HandoffFlowTests.testTheCommandDoesNothingOfflineAndTalksToThePhoneOnline`, `testAFreshStartGetsTheTitleFromThePhone`, `testNothingToContinueRemovesTheWindowAndShowsTheNotice`; K1 `ForegroundTaskPickerTest`; review of `AndroidTaskMove` and `HandoffWindowController` |
| SHARE-11 | WHEN files are dropped on a stream window or the Deck THE Mac SHALL route a lone `.apk`/`.apks`/`.xapk` to the installer, a URL or `.webloc` to the link path on the Deck, and every other file to the drop transfer (FILES-13/14); a drop WHILE the phone is away SHALL be refused with "Connect a phone to send files to it." and SHALL NOT be queued; a second drop while one runs SHALL be refused and SHALL NOT interrupt the first; the transfer, its pill, its caps and its refusals are files.md's. | e2e `drop` `[FILES-13]`/`[FILES-14]`/`[FILES-15]` (the transfer, the pill, the refusal; pre-existing red — see notes.md); K2 `DropNameTests` (name rules), `FileDropSenderTests` (resume, the cap), `OpenLinkTests.testReadsAWeblocFile`; review of `DeckViews`' drop destination and `VideoLayerView.performDragOperation` |
| SHARE-12 | THE app SHALL write no clipboard text or image bytes, shared file content, file name, URL path or notification text to a log or crash report: operation names, counts, sizes, hash prefixes and the phone's name only; the e2e `--share-log` recorder is the one place a URL or banner line is recorded, by design. | review of `ShareInbox`, `ShareFileReceiver` and `ClipboardSync` log calls; e2e `media` `[MEDIA-13]` (the same rule for media text) |
| SHARE-13 | THE Mac's "Share clipboard with your phone" SHALL be the only clipboard switch, SHALL be off on a profile that never chose it and SHALL respect a stored on or off; the Mac SHALL send it as `clip.enable {on}` at every `welcome` and whenever it changes, and the phone SHALL start every session with sync off, so WHILE it is off **both** sides neither send nor apply `clip.set` or a background clipboard image — the one exception is an image a person carried with their own ⌘V (`paste:true`, SHARE-16), which is explicit like a drop; turning it off WHILE a session is live SHALL stop both at once without tearing the session down; a change made while off SHALL NOT be sent when it comes back; another profile SHALL have its own value, and General's row SHALL say in either position what travels. | K2 `ClipboardSyncTests.testToggleOffSendsAndWritesNothing`, `testChangeMadeWhileOffIsNotSentWhenSyncComesBack`, `testReceiveBeforeStartDoesNothing`, `testIsEnabledIsOffUntilThePersonTurnsItOn`; K1 `SessionTest.thePhoneStopsSendingAfterTheMacTurnsTheGateOff`, `aClipFromTheMacIsNotAppliedWhileTheGateIsOff`, `ClipGateTest.the mac's word is the state`; e2e `clip` (`[SHARE-13]`: the Mac sends `on:false`, a fresh profile applies and sends nothing, the phone's later copy is suppressed; `on:true` after the toggle); review of `GeneralSettings` and `Session.onClipEnable` |
| SHARE-15 | IF a share cannot be sent because the phone's shell service is not bound THEN the phone SHALL say "Start Shizuku to send to your Mac." (naming this phone's own missing permission, CONV-AND-03), and "No Mac connected" SHALL stay for a genuinely absent session. | K1 `ShareIntentTest.aShareWithNoShellSaysShizukuIsNeeded`, `noSessionMeansNoMacConnected`; review of `ShareDispatch.send` |
| SHARE-14 | THE phone SHALL skip a clipboard item whose description carries `ClipDescription.EXTRA_IS_SENSITIVE` (or the same `android.content.extra.IS_SENSITIVE` extra), in the text and image directions, so a copied password never leaves the phone; the skip SHALL be counted in the log and never carry the item's text. | K1 `SessionTest.aSensitiveClipIsNeverSent`; review of `ShellClipboard.isSensitive` |
| SHARE-16 | WHEN the person presses ⌘V in an app's stream window WHILE the general pasteboard holds an image and no file copy, THE Mac SHALL send it as a clipboard image (SHARE-2), SHALL wait up to 3 s for the phone's `clip.image.done {id,ok:true}` and SHALL then send one `KEY` frame (keycode 279, `metaState` 0) to that window's stream and SHALL show a 5 s "Image pasted. Nothing there?" pill; IF the phone answers `ok:false`, the session ends, a second ⌘V arrives while one is in flight, or the 3 s pass THEN the Mac SHALL send no key and SHALL show "Nothing pasted."; either pill SHALL leave after 5 s or on Esc, and its one button SHALL be reachable with Full Keyboard Access, with a help tag and VoiceOver label naming ⇧⌘V; ⇧⌘V WHILE the pasteboard holds an image SHALL send the image through the drop path to the window's app (SHARE-17); a `paste:true` image SHALL reach the phone even WHILE "Share clipboard with your phone" is off, because a ⌘V in a window is the person's explicit action like a drop, and the switch governs only the automatic background sync (SHARE-1/SHARE-13); plain text SHALL keep WIN-15's text paste and a file copy SHALL take SHARE-17. | K2 `PasteFlowTests` (the whole transition table: `testIdlePasteStartsSending`, `testSentMovesToAwaitingThePhone`, `testConfirmationPastesAndSendsTheKey`, `testRefusalFailsWithoutAKey`, `testATimeoutFailsWithoutAKey`, `testAnEarlyConfirmationOrAStaleOneIsIgnored`, `testASecondPasteWhileBusyIsIgnored`, `testANewPasteAfterAnOutcomeReplacesThePill`, `testASessionEndInEveryState`, `testEscLeavesEveryPill`, `testThePillButtonSharesOnlyAfterAnOutcome`, `testAPasteSendsTheImageAndThenOnePasteKey`, `testARefusalSendsNoKeyAndTheFailurePill`, `testATimeoutSendsNoKey`, `testASessionEndInFlightSendsNoKey`, `testASecondPasteWhileBusyIsIgnoredByTheFlowToo`, `testThePillButtonSharesTheSameImage`, `testTheThreePillCopies`), `PasteShortcutTests.testCommandVWithAnImageGoesToThePasteFlow`, `testCommandVWithTextNextToAnImageTypesTheText`, `testShiftCommandVSharesInsteadOfPasting`; K1 `PasteKeyTest` (`thePasteKeyIsAndroidKeycode279WithNoModifiers`, `aWrittenImageAnswersDone`, `aRefusedImageAnswersDoneFalse`, `aChecksumMismatchAnswersDoneFalse`, `aUriOnlyImageItemNeverBecomesText`); e2e `paste` (`[SHARE-16]` in light and dark: the Pasting pill and no button, exactly one `KEY` 279 after the confirmation and never a repeat, the "Image pasted" pill with its button, and with no confirmation the failure pill and no key). Screenshots: `.agent/paste-drop/paste-pasting-{light,dark}.png`, `paste-pasted-{light,dark}.png`, `paste-failed-{light,dark}.png`. Emulator A2 (boot 7): with the launcher on top, `clip.image.done ok=True`, `ClipImageWriter: set (592 bytes)` and `clip image: app answered ok=true (592 bytes)`; the plain field stayed at 0 and the image field read the fixture's own 592 bytes. Boot 5's refusal was `setPrimaryClip(image) failed: InvocationTargetException` (H1: ClipboardService's owner check refused the shell's URI clip); the debug-set URI item stays only as a labelled control. The real-phone spike still owns Q2 (which apps accept a pasted image) |
| SHARE-17 | WHEN the person presses ⌘V with a file copy in an app's stream window, or drops files on one (after SHARE-11's routing), THE Mac SHALL send every file through the existing `drop.*` transfer (one at a time, 200 MiB each) with the window's package in `drop.start.target` and the file's position in the gesture in `drop.start.index` and `count`; the shell SHALL stage each landed file and open it to the app by fd through `openStaged` (the app cannot open a shell-written path), and the phone SHALL share the gesture once, after its last file lands, straight to that package with `FLAG_GRANT_READ_URI_PERMISSION` and the ClipData grant on every URI — `ACTION_SEND` for one file, `ACTION_SEND_MULTIPLE` for two to five — and with more than five SHALL save every file in Downloads/PocketDeck and share none; it SHALL show today's chooser only when the package is absent, not installed, or has no activity that resolves the SEND intent; a drop on the Deck, a phone-mode window or a link window SHALL carry no target and keep the chooser; a file copy SHALL never be sent as text (SHARE-2) and SHALL send no paste key; a file over 200 MiB, a second transfer while one runs, or an offline phone SHALL be refused by SHARE-11's existing rules and never queued; the Mac's outcome pill SHALL say how many files of one gesture were saved. | K2 `TargetedDropTests` (`testAnAppWindowNamesItsPackage`, `testPhoneAndLinkWindowsCarryNoTarget`, `testTheWindowsDropClosurePassesItsPackage`, `testTheSenderCarriesTargetAndBatchOnEveryDrop`, `testAQueueWithoutATargetNamesNone`, `testAPluralBatchSaysHowManyWereSaved`), `PasteShortcutTests.testCommandVWithAFileCopyGoesToTheDropPath`; K1 `DropPolicyTest` (`aTargetIsAPackageName`, `junkTargetsAreRefused`, `theTargetIsAtMost255Bytes`, `batchFieldsDefaultToOne`, `batchFieldsMustBeInsideTheBatch`), `DropReceiverTest` (`theTargetAndBatchFieldsReachTheLanding`, `onlyTheLastFileOfABatchTriggersTheShare`), `ShareBatchTest` (`theShareWaitsForTheLastFile`, `oneFileIsSharedAtOnce`, `sixFilesAreSavedButNeverShared`, `aNewTargetStartsANewBatch`); e2e `drop` (`[SHARE-17]`: an app-window drop names its package 1 of 1, a Deck drop names none, a 3-file ⌘V sends three `drop.start` with the target and i of 3, and the phone saves all three). Emulator SHARE-17 (boot 7): the trampoline copied through `openStaged`, `share offered for 1 file(s) to com.google.android.apps.messaging` with its top activity in that package, the untargeted drop opened `com.android.intentresolver/.ChooserActivityLauncher`, and one 3-file gesture logged `share offered for 3 file(s) to com.google.android.apps.messaging`. Boot 5's H2 cause was a shell-written staged file the app could stat but not open (`EACCES`, `share refused: cannot copy 1 file(s)`). The real-phone spike still owns Q3 (`setPackage` and each app's own picker) |
| SHARE-18 | WHEN image data (`public.png`, `public.tiff`, `public.jpeg`, `public.image`), an `http(s)` URL or a file promise is dropped on a stream window or the Deck THE Mac SHALL write the dropped source as a temp file and send it through SHARE-11/17's drop path; for an `http(s)` URL the Mac SHALL attempt the image download and stop at 8 MiB or 10 s: an image answer SHALL become that temp file, and a non-image answer SHALL be refused with "That link isn't an image. Drop the link itself to open it." on a stream window and SHALL take today's link behaviour on the Deck (SHARE-8/11); a file promise SHALL be awaited up to 30 s; temp files SHALL live in a per-drop folder in the system temporary directory and SHALL be deleted when its `drop.result` arrives, on cancel and on session end, with folders older than 24 h swept at launch; an image on the pasteboard SHALL keep SHARE-2. | K2 `DropSourceOrderTests` (D1's truth table: file URL > promise > image data > link), `DropSourceResolverTests` (image data → verbatim PNG/JPEG, TIFF re-encoded, the 8 MiB stop, a delivered promise and a silent one timing out, a download keeping its own name, temp cleanup on refusal), `DropResolveMachineTests` (resolving → ready/refused/timedOut/cancelled and a session end in every state), `DropScratchTests` (the 24 h sweep), `DropDownloadTests` (ephemeral session, http(s) only, sniff table, image answer, text/html and image-without-image-bytes refused, the cap, the timeout, a non-http redirect refused), `DeckDropTests` (image data and a promise transfer, a link downloads, files keep today's routes); K1 `DropPolicyTest` unchanged (the phone's name rules are reused); e2e `drop-sources` (image data → `Image.png` 531 bytes image/png, a local link → `source.png`, a `text/html` answer shows the spec's refusal pill light and dark and sends no file); emulator boot 8: an image-data drop on a Messages window reached Messages with no chooser. A file promise is K2-only here: the scripted input cannot construct a real `NSFilePromiseReceiver`. |

Priority note: SHARE-1, 3, 4, 7, 8, 9, 10, 11, 13, 14 and 15 are P1; the image direction, the copy detail, and the paste/drop rows SHARE-16–18 are P2.

## Visual items for prototypes

SHARE-16/18 change what a person sees: the paste pills ("Pasting…", "Image pasted. Nothing there?" and "Nothing pasted.", each outcome with one "Share Instead" button), the drop target's highlight for image data, image URLs and file promises, and the refusal line for a URL that is not an image. The paste pills are the existing glass pill component the drop outcome and the reconnect row already use — same corner radius, height, blur, fade and layout — with new copy and one button; no new visual design (A4). The reviewer sees screenshots of each in light and dark, and with Reduce Motion and Reduce Transparency, before they land; SHARE-16's six are listed in its proof.

## States and events

Clipboard sync is one small machine (`ClipboardSync`, `macOS/Sources/PocketDeck/ClipboardSync.swift`), started only for a ready session.

| State | Event | Result |
|---|---|---|
| Off (no session, or the setting off) | pasteboard changes | nothing sent, nothing written; the change is not replayed later |
| Running | `start` | the current change count is taken as the baseline; the poll starts (0.5 s) |
| Running | pasteboard changed and the setting on | one `clip.set` (or one image) when its hash is new; the hash is recorded first |
| Running | the same text or image again | ignored (the hash matches) |
| Running | `clip.set` from the phone | the hash is recorded, then the pasteboard is written; the write's own change is not sent back |
| Running | a secret pasteboard item | ignored |
| Running | empty, over-cap, or a message with no text | ignored |
| Running | the setting turned off | Running becomes Off for sending and receiving at once; nothing else changes, and the phone is told too (the table below) |
| Running | session end / disconnect | Off; the poll stops; an unfinished phone image is discarded |
| any | a `clip.set` before `start` | ignored (no pasteboard write, no hash) |

The phone's half is one gate of its own (`ClipGate`, `android/app/src/main/java/dev/pocketdeck/server/ClipSync.kt`), fed only by `clip.enable` on a ready session:

| State | Event | Result |
|---|---|---|
| Off (every new session) | a local clipboard change | nothing sent; the change is not replayed later |
| Off | `clip.set` or `clip.image.start` from the Mac | ignored: nothing written to the phone's clipboard |
| Off | `clip.enable {on:true}` | On: local changes go out, the Mac's clips land |
| On | a local clipboard change | one `clip.set` (or one image) when its hash is new |
| On | a sensitive clip (`EXTRA_IS_SENSITIVE`) | ignored and counted; the text never reaches the log |
| On | `clip.enable {on:false}` | Off: both directions stop at once, the image poll stops |
| any | a `clip.enable` with no boolean | refused (`bad_request`); the state stays |
| any | session end | Off; the next session starts Off |

Paste and drop into an app (planned, SHARE-16–18) is one flow per window:

| State | Event | Result |
|---|---|---|
| Idle | ⌘V, image, no file copy, switch on | Sending: one `clip.image.*`; "Pasting…" shown |
| Sending | `clip.image.done {id, ok:true}` | Pasted: one `KEY` frame (279, no meta); a 5 s "Image pasted. Nothing there?" pill |
| Sending | `clip.image.done {id, ok:false}` | Refused: no key; "Nothing pasted." |
| Sending | 3 s pass, disconnect, session end | Refused: no key; the fallback pill |
| Sending | a second ⌘V | ignored; the first keeps waiting |
| Idle | ⌘V, file copy | Dropping: one `drop.*` per file with the window's package; no key |
| Dropping | every `drop.result ok:true` | Shared: the phone shares each file to the window's app |
| Dropping | a `drop.result ok:false` or a cancel | Refused: the drop pill's reason; no share |
| Idle | ⇧⌘V, image | Dropping: the image as a PNG temp file, the drop path |
| Idle | ⇧⌘V, file copy | Dropping: the files, the drop path |
| Idle | ⇧⌘V with text, or no app window | ignored |
| any | `clip.image.done` for another id, or after the flow ended | ignored |
| any | a drop while one runs | refused (`busy`); the first continues |

The phone's share step picks its target once per finished file: the package resolves a SEND or VIEW intent for the file's MIME → that app only; absent, unknown or unresolvable → today's chooser (SHARE-17).

Share-in is a receiver and a router (`ShareInbox`, `ShareFileReceiver`), fed only by the connected phone.

| State | Event | Result |
|---|---|---|
| Idle | `share.text` | Link (open, or a host-only banner inside the 3 s window) or Text (copy + "Copied from <phone>") |
| Idle | `share.file` for an image | Receiving: a hidden temp file, bytes counted and hashed |
| Receiving | `share.data` | written; over 50 MiB marks the transfer failed and deletes the temp |
| Receiving | `share.end` with the right size and SHA-256 | Saved: the temp is renamed uniquely, put on the pasteboard, "Image from <phone>" with Show in Finder |
| Receiving | `share.end` with a mismatch / wrong MIME / write failure | Failed: the temp is deleted, a refusal banner names the reason |
| Receiving | `share.abort`, a new `share.file`, or a disconnect | Idle: the partial file is deleted |
| any | `share.*` from no connected phone | impossible on the wire; the phone answers its own toast |

Links are one route (`LinkRoute`, `macOS/Sources/PocketDeck/OpenLink.swift`) plus a pending slot.

| State | Event | Result |
|---|---|---|
| Routed | `open(request)` with a remembered named phone, or exactly one remembered phone | Open: one window for that phone |
| Choosing | several remembered phones and none named | "Open on which phone?" with the connected one first; Cancel opens nothing |
| Waiting | no remembered phone | the request waits up to 120 s and "Pair a phone to open links on it." is shown; a pairing consumes it |
| Waiting | the named phone is not the connected one | it becomes the phone in use; the link is sent after `welcome` |
| any | an invalid link | refused before the route; nothing opens and nothing is sent |

The handoff window is a third, small machine (`HandoffWindowController`): Opening → Moved or Fresh (the window is live; the title comes from `window.title`) → Closed, and Opening → Nothing (the window is removed and the transient shown). A reconnect re-sends the same package. Ignored events: a second `nothing_to_continue` for a window already removed, a `window.title` after the person closed the window, and a link whose 120 s wait expired.

## Phone count and connection

| Situation | Share and clipboard show |
|---|---|
| 0 phones | No session and no clipboard sync; Open on Phone keeps the link for 120 s and says "Pair a phone to open links on it."; a drop says "Connect a phone to send files to it."; Send to Mac answers "No Mac connected"; a window's ⌘V with an image or files sends nothing and says the same. |
| 1 phone | Everything acts on it. |
| 2+ phones | Clipboard and Send to Mac belong to the phone in use only. Open on Phone asks which phone when none is named (connected first) and switches to the chosen one; Move to Mac and a drop act on the phone in use; ⌘V and a targeted drop belong to the phone whose window they happen in. |
| Connecting | Clipboard sync starts at ready; until then a copy is not queued. A link to a phone that is not connected makes it the phone in use and waits for `welcome` (120 s). Move to Mac's menu item is disabled while offline. |
| Connected | As above. |
| Offline / reconnecting | Clipboard polling stops; a phone image in flight is discarded; Open on Phone waits up to 120 s; a drop, a paste with an image and ⌘V with a file copy are refused, not queued; Move to Mac does nothing (and its entry is disabled). |
| Phone that can't do the feature | A phone whose shell service is not bound (Shizuku missing or stopped) answers "Start Shizuku to send to your Mac."; a ready session that cannot be sent to answers "No Mac connected"; no share is queued; a phone that cannot write its clipboard answers `clip.image.done ok:false` and the Mac shows the paste fallback, never a key. Older PocketDeck builds are not supported during the alpha (AGENTS.md). |
| Clipboard off | The Mac sends and applies nothing and tells the phone, which also sends and applies nothing; ⌘V with an image sends nothing until the switch is on (SHARE-16's open question); the rest of the surface (Send to Mac, links, drops, Move to Mac, ⇧⌘V) is unaffected. |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: no search or filter field |
| CONV-MAC-02 | n/a: this surface has no window of its own |
| CONV-MAC-03 | applies: "Open on which phone?" is an alert — Esc is Cancel and opens nothing, Return is Open; the share banners use the system's own actions; the paste pills leave on Esc and their button is in the key-view loop (SHARE-16) |
| CONV-MAC-04 | n/a: no text field (the clipboard itself is the system's) |
| CONV-MAC-05 | n/a: nothing zoomable |
| CONV-MAC-06 | applies: ⇧⌘C is in UX.md's shortcut table and shown in the Phone menu and the panel (SHARE-10); ⇧⌘V (SHARE-16) is named in the paste pills' button help tags and VoiceOver labels; the Services entry has no shortcut, as Finder's own Services do |
| CONV-MAC-07 | n/a: no shortcut is reused here |
| CONV-MAC-10 | n/a: not the status item's panel; the panel's Move to Mac is PANEL-16 |
| CONV-MAC-11 | n/a: no window represents one thing — a Move to Mac window stands for whatever was in front when it opened (design/handoff.md) |
| CONV-MAC-12 | applies: the Move to Mac window is a stream window and obeys the windows' frame rules (app-windows.md) |
| CONV-MAC-13 | n/a: no menu item or full-screen command is added here |
| CONV-MAC-14 | applies: the handoff window resizes as a stream window does (app-windows.md); this surface adds no layout |
| CONV-MAC-15 | n/a: closing a window does not quit the app |
| CONV-MAC-16 | applies: SHARE-8/11 and SHARE-16–18 (drop and Services behave as Finder's: a target highlights, a refusal says why; ⌘V pastes and ⇧⌘V shares instead); one unapproved break — a `.webloc` dropped on a stream window is saved as a file instead of opened (misses.md M1) |
| CONV-MAC-20 | applies: the picker alert, the system banners, the handoff window and the paste/drop pills render in light and dark with the accent and Increase Contrast |
| CONV-MAC-21 | applies: the alert's buttons, the handoff window's bar and the paste fallback pill's button are labelled; the phone picker's popup is the one gap (misses.md M2) |
| CONV-MAC-22 | applies: the paste and drop pills fade like the window's other pills, and Reduce Motion removes the fade; everything else is the system's alert or notification |
| CONV-MAC-23 | applies: every result is words — "Copied from <phone>", "Image from <phone>", "Nothing to move…", "Image pasted. Nothing there?", "Nothing pasted.", "That link isn't an image…"; no state is carried by colour alone |
| CONV-MAC-24 | applies: the first share banner asks for notification permission in context; a denied permission only removes that banner — the copy or open still happens; links, drops and Move to Mac ask for nothing |
| CONV-MAC-25 | applies: the paste fallback pill's Share button has hover and pressed states (SHARE-16); everything else clickable is native |
| CONV-MAC-26 | applies: the paste and drop pills reuse the stream window's one pill inset and rhythm (WIN-22) |
| CONV-AND-01 | n/a: share and clipboard carry no phone navigation |
| CONV-AND-02 | applies: the phone's share target labels and toasts follow the system theme; the phone posts no notification for a share (the Mac's banner does) |
| CONV-AND-03 | applies: the feature needs Shizuku; without it the phone says "Start Shizuku to send to your Mac." (SHARE-15) and no other feature is disabled |
| CONV-AND-04 | applies: the only phone-side changes are the dropped file under `Download/PocketDeck/`, the clipboard image and the one paste key a person's ⌘V causes (SHARE-16), all person-started; no lock, timeout or app state changes, and the phone stays locked |
| CONV-PD-01 | applies: the table above (0/1/2+ phones; the picker for links) |
| CONV-PD-02 | applies: the table above (offline, connecting, a phone without a session, clipboard off) |
| CONV-PD-03 | applies: a share is one-way — the Mac claims a save only after `share.end` verifies, and its refusal says why; a link opens only after the phone accepts it; a paste waits for `clip.image.done` before its key and shows "Pasting…" until then (SHARE-16) |
| CONV-PD-04 | n/a: no slider or toggle follows a phone value (the clipboard poll is not a control) |
| CONV-PD-05 | applies: SHARE-12 |
| CONV-PD-06 | applies: no NFR budget belongs to this surface; the wire caps are the protocol's (1 MiB text, 8 MiB image, 50 MiB share file, 200 MiB drop), a 50 MiB receive is bounded by those caps, and the planned waits are 3 s for a paste confirmation, 10 s and 8 MiB for an image URL, and 30 s for a file promise (SHARE-16/18) |
| CONV-PD-07 | applies: "Send to Mac" (the phone's share target), "Open on Mac" (the phone's text menu and Open with), "Open on Phone" (the Mac's share extension and Service), "Move to Mac"/"Move Phone App to Mac" (panel and menu, as CONV-PD-07 already lists), "Share clipboard with your phone", "Share instead" (SHARE-16) |
| CONV-PD-08 | applies: the tables above (clipboard, the phone's gate, paste and drop into an app, share-in receiver, link route, handoff) |
| CONV-PD-09 | applies: SHARE-4/5 (a banner names what happened), SHARE-7 (a refused link is never half-sent), SHARE-10 ("Nothing to move…", "Opened fresh…"), SHARE-16/18 ("Nothing pasted.", "That link isn't an image. Drop the link itself to open it.") — one gap in a failure body, misses.md M3 |

## Assumptions

- One phone is in use at a time (settings.md); clipboard and Send to Mac belong to it.
- The phone's Shizuku service is bound at shell UID; a share needs a ready session and is not queued.
- The Mac polls its general pasteboard every 0.5 s while a session is ready; the phone polls its own clipboard on its side through the shell service.
- The person's clipboard is the system's general pasteboard; the Mac never keeps a copy.
- `~/Downloads/PocketDeck/` is writable, or `--share-dir` overrides it for tests.
- The phone's share sheet and "Open with" are Android's own surfaces; PocketDeck only supplies their labels and target.
- The planned paste and targeted drop assume the Mac knows the window's package (`window.title.pkg`, PROTOCOL.md) and that Android 16's `TextView` handles `KEYCODE_PASTE`; a Compose field, a WebView and an app that swallows keys are verified on the emulator and the real-phone spike (`docs/design/dragdrop.md`).
- A file promise is delivered to its temp file within 30 s, and an image URL's server answers within 10 s; both are the planned caps (SHARE-18).
- The phone's `clip.image.done` is sent only after its clipboard write and its file write succeed, so the Mac can paste on it.

## Non-goals

- Rich text, HTML, files or folders through the clipboard: text and one image only (SHARE-16 sends one image; files take the drop path).
- Dragging a file out of a phone window (design only).
- V1–V3's code is not part of the file-copy fix: this round is the spec draft only.
- Retrying a paste by itself, or a paste queue: a second ⌘V while one is in flight is ignored.
- A share history, a queue for a phone that is away, or resending a failed share by itself.
- Choosing a phone per clipboard message, or syncing several phones.
- Opening any non-web scheme on the Mac from a shared text.
- A second Mac connected to the same phone (the phone serves one session).

## Open questions

- [NEEDS CLARIFICATION] **A `.webloc` on a window** — the Deck opens a dropped `.webloc` as a link, but a stream window saves it to the phone as a file (misses.md M1). Recommended: route it through the same `OpenLinkRequest.webloc` path on windows, so one gesture means one thing.
- [NEEDS CLARIFICATION] **Image-refusal copy** — "Couldn't save the image from <phone>: checksum mismatch" is an internal phrase (and a write failure names the folder path). Recommended: "The image didn't arrive in one piece. Try sharing it again." and "PocketDeck couldn't save the image." (misses.md M3).
- [NEEDS CLARIFICATION] **Which apps accept a pasted image, and with which key?** `TextView` handles `KEYCODE_PASTE` and Ctrl+V (AOSP, below), but messaging and mail apps may use Compose, a WebView or their own editor; the real-phone spike records, per app, whether the image lands and which key worked. Recommended: `KEYCODE_PASTE` first, Ctrl+V as the fallback only if the spike needs it.
- [NEEDS CLARIFICATION] **Does a targeted SEND reach each app?** `setPackage` + `resolveActivity` decides the targeted share, but an app may declare SEND and still open its own picker or refuse the URI. The real-phone spike records, per app, whether the file arrives without a chooser. Recommended: keep the chooser as the fallback and never claim a targeted share the app did not show.

