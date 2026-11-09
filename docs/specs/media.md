# Media

Prefix: `MEDIA`. Owner docs: [design/notify.md](../design/notify.md) § "Media part 2 design", [design/audio.md](../design/audio.md), [design/mac-redesign.md](../design/mac-redesign.md) §3.8 (the panel's volume and picker), [UX.md](../UX.md) § "macOS app" 3, [PROTOCOL.md](../PROTOCOL.md) § "Audio rules" and § "Notifications + media". Last reviewed: 2026-10-27, against main `12f9d7a`.

## Purpose

What the phone plays, on the Mac: the chosen media session becomes the Mac's own Now Playing (so the system's player, Control Center and the keyboard's media keys drive the phone), and the audio of an open stream window plays on the Mac while the phone's speaker goes quiet. The person sees no track text in PocketDeck's own windows — the system's Now Playing shows it — except one picker naming which app follows when several play. The panel's layout, its volume row and where the picker sits are panel.md's (`PANEL-5`, `PANEL-13`, `PANEL-14`); the notification gate that permits all of this is notifications.md's (`NOTIFY-1`) and settings.md's (`SET-DEV-09`).

## User stories

| ID | Priority | Story |
|---|---|---|
| MEDIA-S1 | P1 | As a person playing something on my phone, I want the Mac's Now Playing to show it and the media keys to work, so that I control the phone without unlocking it. |
| MEDIA-S2 | P1 | As a person watching an app's window, I want its sound on the Mac with the phone's speaker quiet, so that I can hear what I am looking at. |
| MEDIA-S3 | P2 | As a person listening to a podcast, I want to seek and skip inside the track from the Mac, so that I do not pick the phone up. |
| MEDIA-S4 | P2 | As a person with two apps playing, I want to choose which one Now Playing follows, so that the controls act on the app I mean. |
| MEDIA-S5 | P1 | As a person, I want a track that stopped or a phone that left to clear Now Playing, so that the Mac never shows a stale track as live. |
| MEDIA-S6 | P1 | As a person with an older phone, I want what it can do to keep working and what it cannot to say so, so that a missing feature is not a silent no. |

## Settings inventory

| Setting | Scope | Store (profile defaults) | Default | What it does | In the panel? |
|---|---|---|---|---|---|
| Share notifications and Now Playing | per phone | `notify.<deviceId>` | **off** | The gate for every `media.*` message in both directions (the phone's listener sends nothing while off); off while live clears the Mac's Now Playing | no (the panel shows the forwarded rows, not the switch) |

The media volume row is the **phone's music stream** (`phone.volume`, panel.md `PANEL-13`), not a Mac output gain. The session's own `volume`/`volumeMax` has no person-facing control today (see Open questions).

## Requirements

| ID | Requirement (EARS) | Proof |
|---|---|---|
| MEDIA-1 | WHILE the phone in use reports a chosen media session and its sharing switch is on THE Mac SHALL publish that session's title, artist, album, duration, position, playback rate and service package as the system's Now Playing, with the artwork the phone sent for it, and SHALL update it on every `media.state` the phone sends; the displayed position SHALL advance from the reported position and rate, never from a local guess about what was clicked. | K2 `NotifyMacTests.testNowPlayingInfoFromMediaState`, `testNotifyAndMediaFramesDecodeIntoEvents`; e2e `notify` `[MEDIA-1]` (the state record and chosen session); e2e `media` `[MEDIA-1]` |
| MEDIA-2 | WHEN the person uses the system's Now Playing play, pause, next or previous control (including the Mac's media keys) THE Mac SHALL send one `media.command` with that action and the chosen session's key; the control SHALL act only on the phone's session, and the Mac SHALL NOT change its picture of playback before the phone reports it. | K2 `NotifyMacTests.testMediaCommandWireShapes`; K1 `MediaControlTest` (`only the six actions are commands`); e2e `notify` `[MEDIA-2]` (a play control reaches the phone); the real media-key press is **untested** — no check posts a hardware media key |
| MEDIA-3 | WHILE the chosen session lists `ACTION_SEEK_TO` THE system's position bar and 15 s skip controls SHALL be enabled; a seek or skip SHALL be clamped to `[0, durationMs]` on the Mac and again on the phone, and a skip SHALL land inside the track also while paused; WHILE the session cannot seek those controls SHALL be disabled, and the Mac SHALL send no seek. | e2e `media` `[MEDIA-3]` (45 s asked of a 30 s track becomes 30 s, the phone's clamped value, the confirming state, a seek on the picked session); K2 `NotifyMacTests.testSeekAndSkipStayInsideTheTrack`; K1 `MediaControlTest` (`a seek position is clamped to the track`, `seek and volume need their value`) |
| MEDIA-4 | THE phone SHALL send at most one `media.art` per session key and only when the picture changes — `image/jpeg`, each side ≤ 512 px, ≤ 256 KiB, never enlarged — and `media.art {key}` alone SHALL clear it; the Mac SHALL refuse art for a key that is not the current session, a MIME other than `image/jpeg`, a side over 512 px, empty or over-cap bytes, or bytes that do not decode, SHALL keep the track's info without a picture, SHALL drop the old session's picture when the session changes, SHALL hold it in memory only, and SHALL log only its size, dimensions and a hash prefix. | e2e `media` `[MEDIA-4]` (arrives once, once more for the picked app); K2 `NotifyMacTests.testNowPlayingInfoCarriesTheArtwork`, `testArtworkCapsAreTheWireCaps`; K1 `MediaArtTest` (the caps, the halving, the hash, the wire shape) |
| MEDIA-5 | WHEN the phone reports two or more active sessions THE Mac SHALL show a row reading "Now Playing follows: <chosen app>" whose menu lists every session in the phone's order with the playing one marked "— playing", and picking one SHALL send `media.choose {key}`; an unknown key SHALL leave the phone's chosen session unchanged and log it; with one session the picker SHALL NOT appear, and the Mac SHALL NOT show a track title, performer or artwork in its own windows. | e2e `media` `[MEDIA-5]` (two sessions, the pick, the list and state moving to `s2`); K2 `PhonePanelTests.testThePickerNeedsTwoSessionsAndNamesTheChosenApp`, `testThePanelHasNoTrackText`, `testThePanelDrawsNothingFromTheTrack`; K1 `MediaControlTest` (`the mac's pick wins while it is active, else the first session`, `a malformed preferred key never becomes the chosen one`, `the sessions list keeps the system's order and drops bad entries`) |
| MEDIA-6 | IF the phone reports a state with no title, artist or album THEN the Mac SHALL replace the Now Playing text with none and stop the rate; the system's Now Playing SHALL be cleared when the session ends, the sharing switch is turned off, another phone becomes the one in use, and on quit, so nothing remains that a person could mistake for a track still playing. | K2 `NotifyMacTests.testEmptyStateClearsNowPlaying` (a state the Mac builds empty — `receivedAt == 0`); review of `ConnectionController`'s disconnect/switch/quit `nowPlaying.clear()` calls; the live empty report is **untested**: it leaves a title-less entry and keeps the same session's old picture (open question 4) |
| MEDIA-7 | A phone that sends only today's `media.state` SHALL keep working as one session: its state SHALL still drive Now Playing and its transport commands SHALL still reach it, while no picker, no artwork, no seek controls and no session volume SHALL be offered; the Mac SHALL send no command whose value it cannot clamp. | e2e `media` `[MEDIA-7]` (the older-phone state, no sessions, no art, a transport command); K1 `MediaControlTest`; K2 `NotifyMacTests.testAVolumeCommandNeedsTheSessionsMaximum` |
| MEDIA-8 | WHEN the phone in use is online and at least one stream window is open and unpaused THE Mac SHALL send one `audio.start {codecs:[opus,aac]}`; the phone SHALL answer one `AUDIO_CONFIG` and then `AUDIO_FRAME`s, one encoder packet each; the Mac SHALL send `audio.stop` when the last window closes or pauses, the session ends, the phone disconnects and on quit; there SHALL be no audio with no open windows and none while every stream is paused. | e2e `audio` `[MEDIA-8]` (`audio.start`, a config and ≥ 10 frames at the Mac, audio events on the phone); K2 `AudioEngineTests.testStatsCountConfigsFramesAndPts`, `ProtocolTests.testAudioConfigRoundTrip`, `testAudioFrameRoundTrip` |
| MEDIA-9 | THE phone SHALL prefer Opus and fall back to AAC-LC only when its Opus encoder is missing, SHALL send 48 kHz stereo with one Opus frame (20 ms) or one AAC-LC access unit (1024 samples) per AUDIO_FRAME, SHALL drop old audio beyond ~250 ms rather than block JSON or video, and SHALL capture only while at least one window is open and unpaused; the Mac SHALL decode both codecs to 48 kHz stereo, SHALL play digital silence without stalling if it cannot decode a packet, and SHALL keep the played audio within 185 ms of the picture (CONV-PD-06). | e2e `audio` `[MEDIA-9]` (AAC 48 kHz stereo accepted); K2 `AudioEngineTests` (the format gate); e2e `audiogap` (the real-time AAC pacing, late_p95 92 ms, depth ≤ 185 ms); review of `AudioCapture`; DAC/Opus decode on the real phone is **untested** on this Mac |
| MEDIA-10 | THE phone SHALL capture only what an open window shows where it can attribute the app (one loop-back mix of those app UIDs), SHALL capture the whole device when a phone-mode window is open or a window cannot be attributed, SHALL capture nothing when no window plays anything, and SHALL keep every other app on the phone speaker in the per-app mode; only one capture path SHALL be registered at a time and it SHALL end with the session. | K1 `AudioFollowTest` (six transition cases), `SessionAudioFollowTest`; the swap's sub-second gap and the real-speaker routing are **untested** (the e2e host has no phone audio) |
| MEDIA-11 | THE phone's chosen session SHALL carry `volume`/`volumeMax`; a `media.command {action:"volume", level}` SHALL be clamped to `[0, volumeMax]` on the Mac and again on the phone, and the Mac SHALL send no volume command for a session that reports no maximum; no person-facing control SHALL send it (the `media` check drives it through the debug route). | e2e `media` `[MEDIA-11]` (99 asked of a 15 max, 15 at the phone, the confirming state); K2 `NotifyMacTests.testAVolumeCommandNeedsTheSessionsMaximum`; K1 `MediaControlTest` (`a volume level is clamped to the session maximum`) |
| MEDIA-12 | THE forwarded sound SHALL play through the Mac's current default output at unity gain with no PocketDeck volume or mute control; WHEN the output device changes THE Mac SHALL stop the engine, discard the pre-buffer and restart on the next frame without aborting the process; there SHALL be one capture and one playback per phone. | K2 `AudioEngineTests.testVolumeAndMuteDriveGain`, `testMayPlayRequiresRunningEngineAndUsableOutputFormat`, `testJitterStartsAfterTargetAndCapsAtMax`; review of `AudioEngine.configurationChanged`; the device-change restart is **untested** |
| MEDIA-13 | THE Mac SHALL write no media title, artist, album or artwork bytes to a log, a crash report or the e2e share log: session keys, field lengths, sizes, dimensions and hash prefixes only. | e2e `media` `[MEDIA-13]` (no track text or picture bytes in any log); e2e `notify` (the media record's fields); K2 `NotifyMacTests.testMediaStateCarriesThePartTwoFieldsWithoutText` |
| MEDIA-14 | WHILE the person only watches media — no control used — the Mac SHALL send no write to the phone. | **untested** — the check to write: an `nfr` phase that lets two `media.state`s arrive with no command and asserts the fake phone's `writes` counter unchanged |
| MEDIA-15 | WHILE audio plays THE Mac SHALL buffer decoded audio to an adaptive target of the last 10 s p99 arrival lateness + 20 ms margin + one 20 ms frame, clamped to 60–180 ms (9 × 20 ms frames) so the played audio never trails the picture by more than the 185 ms A/V limit; the AAC fallback's 1024-sample packets make its queue 192 ms, within the codec's frame granularity and still under the video pipeline's delay, SHALL start playback only when that target is filled, SHALL count one underrun per dry spell and conceal it from the last real PCM with a decaying crossfade (at most 160 ms), SHALL drain a backlog above the target by time-compressing with a crossfade rather than cutting audio, and SHALL count underrun, late, concealed and dropped packets. | K2 `AudioJitterTests` (`testTargetFollowsTheMeasuredLateness`, `testTargetStaysInRange`, `testStarvationCountsOneUnderrunAndConceals`, `testConcealmentIsBounded`, `testStretchDrainsABacklogAndStopsAtTheTarget`, `testStretchKeepsPitchAndLength`, `testTheMeasuredArrivalPatternNeverStarves`); e2e `audiogap` `[MEDIA-15]` |
| MEDIA-16 | THE phone SHALL send audio ahead of video deltas and SHALL split a video access unit larger than 16 KiB into `VIDEO_CHUNK` fragments of at most 16 KiB only when the Mac's hello says `videoChunks`, keeping the first fragment at the frame's priority and the rest behind audio so no audio packet waits behind more than one fragment; it SHALL bound unsent socket bytes with `TCP_NOTSENT_LOWAT` 16 KiB; the Mac SHALL reassemble one access unit per stream and hand the decoder the same Annex-B bytes it would have received as a whole `VIDEO_FRAME`. | K1 `AudioGapTest` (the audio lane overtakes deltas and interleaves between chunks; the chunk wire shape); e2e `audiogap` `[MEDIA-16]` (the chunked picture reaches the decoder; audio wait `ahead_p95 ≤ 32 KiB`) |
| MEDIA-17 | WHILE a stream window plays over a link that goes off-channel for 100 ms every second THE Mac SHALL play audio with zero underruns and zero drops, and WHEN one 500 ms off-channel episode hits THE Mac SHALL conceal it as one starvation episode (one underrun, at most 160 ms of concealment), discard the stale head of the burst that follows, and resynchronise with the picture; the queued audio depth SHALL stay at or under 200 ms (the AAC fallback's 192 ms; the A/V trail stays under 185 ms, ITU-R BT.1359) and the picture SHALL keep decoding. | e2e `audiogap` `[MEDIA-17]` (phase A counters, phase B counters, depth max, audio wait) |

Priority note: MEDIA-1, 2, 5, 6, 8, 12, 13, 15, 16 and 17 are P1; seek, artwork, the picker, the volume wire and the older-phone rules are P2.

## States and events

The Mac's media model is one small machine (`NowPlayingController`, `macOS/Sources/PocketDeck/NowPlaying.swift`): the phone's reports are the only truth, and a click only asks.

| State | Event | Result |
|---|---|---|
| Empty | `media.state` with a track | Following(session): Now Playing set, transport registered |
| Empty | `media.state` with no track | an empty entry (no title, rate 0); today it is not cleared (open question 4) |
| Following(session) | `media.state` (same key) | the info is replaced; position and rate follow the report |
| Following(session) | `media.state` (another key) | Following(new session); the old session's artwork is dropped |
| Following(session) | `media.art` for its key | the picture joins the info |
| Following(session) | `media.art` for another key, bad MIME/size/bytes | ignored with a log line; the picture stays as it was |
| Following(session) | `media.art {key}` with no data | the picture is cleared; the info stays |
| Following(session) | `media.sessions` | the rows and chosen key update; the state machine does not change |
| Following(session) | `media.choose(key)` | one `media.choose`; nothing changes until the phone reports |
| Following(session) | `play`/`pause`/`next`/`prev` control | one `media.command`; nothing changes until the phone reports |
| Following(session) | `seek`/skip WHILE `canSeek` | one clamped `media.command seek`; nothing changes until the phone reports |
| Following(session) | seek/skip WHILE not `canSeek` | ignored (the command is disabled) |
| Following(session) | volume WHILE no `volumeMax` | ignored (no level can be clamped) |
| Following(session) | `media.state` with no track | the text is replaced with none and the rate stops; the system's entry is not cleared and a picture for the same session key is kept today (open question 4) |
| any | sharing switch off / disconnect / another phone / quit | Empty: Now Playing and artwork cleared |

Ignored events, stated so nobody builds them: a `media.choose` for a key the phone no longer lists, a seek on a session without `canSeek`, a volume command without a maximum, a skip on a non-seekable session, and a `media.art` after its session changed.

Audio is a second, small machine (the phone's `AudioFollow` and the Mac's `AudioEngine`):

| State | Event | Result |
|---|---|---|
| Idle | first unpaused `window.open` | Start: `audio.start`; the phone chooses a codec and configures |
| Start | `AUDIO_CONFIG` | Streaming: the jitter buffer fills to the adaptive target (60–180 ms), then playback starts |
| Streaming | frames | played after the jitter target; a backlog above it is time-compressed, and past the 9-frame cap (or target + 3 when lower) silence is trimmed then stale packets are dropped |
| Streaming | the queue runs dry | Starved: one underrun, concealment from the last PCM (≤ 160 ms), then a fade-in on the first real frame |
| Streaming | all windows paused or closed / session end | Stop: `audio.stop`, engine stopped, buffer dropped |
| Streaming | the output device changes | Stop, then Start on the next frame (no crash) |
| any | a frame with no config | ignored until a config arrives |
| any | a codec the Mac cannot decode | silence for that packet, counted; transport stays up |

## Phone count and connection

| Situation | Media shows |
|---|---|
| 0 phones | Nothing to follow: the system's Now Playing is empty and the Mac's own windows show no media. |
| 1 phone | That phone's chosen session drives Now Playing; its audio plays while a window of that phone is open. |
| 2+ phones | Only the phone in use sends media; the others are a switch away (`SET-DEV-03`) and send nothing until they are in use. There is no cross-phone picker. |
| Connecting | Nothing new is shown; a new session's first `media.state` replaces the picture. The Mac's Now Playing keeps its last track only until the phone reports or the link is lost. |
| Connected | As above: the phone's reports drive every field. |
| Offline / reconnecting | Now Playing and its artwork are cleared when the session ends; nothing pretends to be playing. Reconnect re-reads the sessions on the phone. |
| Phone that can't do the feature | An older phone: one session, no artwork, no seek controls, no picker, no session volume (MEDIA-7). A phone whose sharing switch is off sends nothing at all (`NOTIFY-1`). |
| Sharing off / listener missing | No media messages either way; the Mac's page says why (`SET-DEV-09`); the phone's own item is unreachable today (phone-app.md PHONE-4). |

## Conventions

| Convention | Answer |
|---|---|
| CONV-MAC-01 | n/a: no search or filter field; the picker is a value menu, not a search |
| CONV-MAC-02 | n/a: this surface has no window of its own; the panel's keys are panel.md's |
| CONV-MAC-03 | applies: the picker is a standard Menu — Esc closes it with no choice, Return runs the focused row (reviewed, MEDIA-5) |
| CONV-MAC-04 | n/a: no text field |
| CONV-MAC-05 | n/a: nothing zoomable |
| CONV-MAC-06 | applies: media adds no shortcut; the Mac's media keys are the system's and reach the phone only through Now Playing (MEDIA-2), and the picker's control has no hidden shortcut |
| CONV-MAC-07 | n/a: no shortcut is reused here (⌘P stays Phone Mirror) |
| CONV-MAC-10 | n/a: the picker is a row in the panel; the panel's click/Esc/secondary-click behaviour is PANEL-2/PANEL-3 |
| CONV-MAC-11 | n/a: no window |
| CONV-MAC-12 | n/a: no window |
| CONV-MAC-13 | n/a: no menu item or full-screen command |
| CONV-MAC-14 | n/a: this surface adds no window or layout; the panel's live resize is PANEL-22's |
| CONV-MAC-15 | n/a: closing nothing does not quit the app |
| CONV-MAC-16 | n/a: no drag/drop, paste or Services on this surface |
| CONV-MAC-20 | applies: the picker and the system's Now Playing render in light and dark with the accent and Increase Contrast (panel appearance, PANEL-22); the artwork is drawn by the system |
| CONV-MAC-21 | applies: the picker reads "Now Playing follows: <app>" and the chosen app is spoken; every control's label is panel.md's (PANEL-21) |
| CONV-MAC-22 | applies: nothing on this surface animates; Reduce Motion changes nothing |
| CONV-MAC-23 | applies: the chosen app is words, never a colour; state is the system's own |
| CONV-MAC-24 | n/a: the Mac asks no permission for media; the phone's notification-listener grant is notifications.md's, and media is silent while it is missing (NOTIFY-2) |
| CONV-MAC-25 | applies: the picker row has the panel's hover and pressed states; a session that cannot act is a disabled control, never an accent (PANEL-22, PANEL-19) |
| CONV-MAC-26 | applies: the picker uses the panel's one inset and rhythm (PANEL-22) |
| CONV-AND-01 | n/a: media carries no phone navigation |
| CONV-AND-02 | n/a: media has no phone-side UI of its own; the phone's player and its notification are the player's |
| CONV-AND-03 | applies: media is read only through the same listener grant as NOTIFY-2 — a denied grant disables media too and the Mac's hint says why (`SET-DEV-09`); the phone's attention item is unreachable today (phone-app.md PHONE-4) |
| CONV-AND-04 | applies: media commands change only the chosen session's playback and volume, which the person asked for; no lock, timeout or app state changes and the phone stays locked |
| CONV-PD-01 | applies: the table above (0/1/2+ phones; only the phone in use sends media) |
| CONV-PD-02 | applies: MEDIA-7 and the table (older phone, sharing off, offline) |
| CONV-PD-03 | applies: MEDIA-2 and MEDIA-3 (a command is a request; the Mac follows `media.state`, never the click) |
| CONV-PD-04 | applies: the panel's volume slider follows the pointer and sends `phone.volume` (PANEL-13); the session's own volume has no control today (MEDIA-11) |
| CONV-PD-05 | applies: MEDIA-13 |
| CONV-PD-06 | applies: the audio path's budget is the design's 150 ms end to end (MEDIA-9, MEDIA-12), and forwarded audio trails the picture by at most 185 ms (ITU-R BT.1359; MEDIA-15, MEDIA-17); no frame metric belongs to media, and the panel's metrics are PANEL-22 |
| CONV-PD-07 | applies: "Now Playing follows: <app>" names the value; the app label is the phone's own `media.sessions` label, and "Now Playing" is one name across UX.md and the panel |
| CONV-PD-08 | applies: the two tables above (Now Playing and audio), with their ignored events |
| CONV-PD-09 | applies: MEDIA-5 (the picker names its result), MEDIA-7 (an older phone is not offered what it cannot do), PANEL-19 for the panel's reasons |

## Assumptions

- One phone is in use at a time (settings.md); media has no per-phone surface beyond the in-use phone.
- The phone's notification-listener grant is the gate's other half (NOTIFY-2); a phone without it sends no media and the Mac's Now Playing stays empty.
- Opus decodes through the system's AudioToolbox on macOS 26; AAC-LC is the fallback when the phone has no Opus encoder.
- Audio follows open stream windows; the phone's own mixer decides which usages follow the capture (design/audio.md's risk).
- The system's Now Playing is the Mac's only visible track surface; PocketDeck's own windows deliberately show none.

## Non-goals

- A media player on the Mac: no track list, no queue, no local playback.
- A second audio device picker, a per-app Mac volume, or an equaliser: the sound follows the Mac's default output at unity gain.
- Per-window audio capture by itself: capture is per app UID or device-wide (MEDIA-10).
- Media from a phone that is not in use, or several phones at once.
- A person-facing session-volume control: the panel's slider is the phone's music stream (PANEL-13).
- Artwork or titles in PocketDeck's own windows or logs.

## Open questions

- [NEEDS CLARIFICATION] The session volume (`media.command {action:"volume"}`) has no person-facing control: the panel's slider sends the phone's music-stream volume (`phone.volume`, PANEL-13), and only `mediacmd` reaches the session volume. design/notify.md describes the slider as the session's. Recommended: keep one slider (the stream's, which is what a person hears) and delete the session-volume UI wording from the design; keep the wire command for the `media` check.
- [NEEDS CLARIFICATION] design/audio.md still calls the all-audio path "today's" and the per-app path "the goal", while `AudioFollow` already picks per-app for attributable app windows. Recommended: code wins; update design/audio.md's "Audio follows the window" section to say per-app is built and all-audio is the fallback.
- [NEEDS CLARIFICATION] design/audio.md's menu-bar slider and mute toggle for forwarded audio are not built: `AudioEngine.volume` is fixed at 1.0 and `muted` at false, with no control. Recommended: keep them unbuilt (the Mac's own volume keys cover it) and remove the claim from the design doc.
- [NEEDS CLARIFICATION] The phone's live "nothing is playing" state does not clear the system's Now Playing: `MediaMapping.nowPlayingInfo` returns nil only for a state with `receivedAt == 0` (which the wire never produces), so an empty `media.state` leaves a title-less entry until the session ends. Recommended: treat a state with no title/artist/album as a clear (text and artwork), which is what a person expects when the music stops.
- [NEEDS CLARIFICATION] The transport commands stay enabled while the Mac has no current session, so a media key press with nothing playing sends `media.command` and the phone logs "media command play ignored: no session attached". Recommended: disable play/pause/next/previous while there is no current session, so a stray press does nothing on either side (the seek commands already follow `canSeek`).
