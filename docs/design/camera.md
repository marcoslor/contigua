# Phone camera as a Mac camera — spike (v0.2 #7)

Status: **C0 answered: the shell UID cannot open the camera. C0b answered: the app
process can capture in the background and with the phone locked, as long as the
shell UID (2000) starts its `camera` foreground service; the app starting itself is
refused. C1 can be built on that shape.**
This document answers whether PocketDeck can feed the phone's camera into a Mac
camera device, what that would take, and what the fallback is. It is a design +
experiment record; no product feature is implemented.

Shape in one line: a **CoreMediaIO Camera Extension** on the Mac presents a camera
device; the extension gets H.264 frames from the PocketDeck app, which gets them from
a Camera2 session in the phone's **app process** (a `camera`-type foreground service;
C0 showed the shell UID cannot open a camera at all).

## Questions

### Phone (API 36 emulator, one boot)

| | Question |
|---|---|
| P1 | Can a shell-UID `app_process` process list cameras (`CameraManager.getCameraIdList`, facing, sizes, fps ranges) and open one with Camera2? What context/package name does it need, and what is the exact refusal if any? |
| P2 | With the screen off and the keyguard up, does the open session still deliver frames? Frames in 5 s, `dumpsys media.camera` client/UID, any background/idle kicks, `dumpsys sensor_privacy` behaviour, and what happens when the screen comes back. |
| P3 | Does the camera feed a MediaCodec H.264 encoder input surface at 1280×720@30 (frames/s out, keyframe interval honoured)? Counts and sizes only, never pixels. |
| P4 | Does Android show the green camera indicator (status-bar dot / notification) for a shell-UID client? What does the person see on the phone? |
| P5 | What happens when another app opens the camera while the probe holds it: who is evicted, and which error code arrives? |

### Mac (SDK research + one VM session)

| | Question |
|---|---|
| M1 | What does a Camera Extension need: bundle layout, entitlements, activation, approval, install location? |
| M2 | In the VM, can an ad-hoc-signed minimal camera extension activate, and does the camera appear to the system? If not, the exact error. |
| M3 | Alternatives if activation is refused: a camera-less PocketDeck camera window, the deprecated DAL plug-in, and what a Developer ID account would unlock. |

## Findings

### Phone — API 36 emulator, adb shell UID 2000

The probe is `android/app/src/debug/java/dev/pocketdeck/server/CameraProbe.kt`, debug
source set only. It runs as a second `app_process` at the shell UID, the same UID as
the Shizuku user service, and every stage is its own run:

```sh
adb -s emulator-5554 shell 'CP=$(pm path dev.pocketdeck | cut -d: -f2); \
  CLASSPATH=$CP app_process /system/bin dev.pocketdeck.server.CameraProbe list'
```

**P1 — no: the shell UID lists the cameras but cannot open one.** The 2026-10-20
boot (`tools/emulator/cam-probe.sh`, one boot, log in `.agent/emu/cam-probe.log`)
listed the emulator's single back camera and then failed every call that needs the
caller's package (PID and attribution fields elided):

```
cam: result stage=list ok=true uid=2000 pkg=com.android.shell op=com.android.shell basePkg=android adopted=mOpPackageName,mAttributionSource notAdopted=mPackageName cams=1 ids=1 camera_1=characteristics_failed
cam: result stage=open ok=false uid=2000 pkg=com.android.shell op=com.android.shell basePkg=android adopted=mOpPackageName,mAttributionSource notAdopted=mPackageName camera=1 opened=false session=configured error=SecurityException:Given_calling_package_android_does_not_match_caller's_uid_2000
```

(The `session=configured` on that line is the probe's own reporting bug: a
synchronous `openCamera` failure releases the latch, so the stage thought the
session had been configured. Fixed after the boot; the error code is the fact.)

Why the context rewrite could not fix it. On API 36 `ContextImpl` no longer has an
`mPackageName` field: `getPackageName()` returns `mPackageInfo.getPackageName()`,
and the system context's `LoadedApk` is the `android` package (uid 1000).
`getOpPackageName()` reads `mAttributionSource`, and `mBasePackageName` /
`mOpPackageName` are final. The probe rewrote the base context's `mOpPackageName`
and `mAttributionSource` to `com.android.shell`
(`adopted=mOpPackageName,mAttributionSource`) and the platform still refused with
"calling package android": the package the failing call presents is neither of
those fields. Both `getCameraCharacteristics` and `openCamera` refuse, so no device
is opened, no session exists and no frame can flow; the encoder half is irrelevant
until this is solved.

The one untested route is a real `ContextImpl` for `com.android.shell`
(`ActivityThread.getPackageInfoNoCheck` for the shell package plus
`ContextImpl.createAppContext`), which would make `getPackageName()` answer with a
package uid 2000 owns. It was not tried: the epic had one boot left for C1 and C1
is not built (the brief's budget rule), so C1 answers "app process" instead.

**P2–P5 — blocked by P1.** All stages ran in the same boot and stopped at the same
refusal, so none of them answers its question:

- P2: the phone was locked first (`input keyevent KEYCODE_SLEEP`,
  `isKeyguardShowing=true` confirmed; the rig PIN was already set and was not
  changed) and the open still failed with the P1 error, before any lock-specific
  policy could be observed. No frames.
- P3: no camera, so no frames. `MediaCodec` H.264 1280×720@30 with a surface input
  was shown to configure and start at uid 2000 by the earlier spike, but the
  camera→encoder frame count and keyframe interval are unverified.
- P4: no capture ran, so no privacy indicator was observed (the status-bar shot was
  skipped because the capture stage never became ready).
- P5: there was no capture to evict. The emulator's camera app resolves and starts
  (`com.android.camera2/com.android.camera.CameraActivity`), but the probe held
  nothing for it to take.

| | Answer | Evidence |
|---|---|---|
| P1 | **no** at uid 2000: listing yes, open refused | `cams=1 ids=1`; `SecurityException: Given calling package android does not match caller's uid 2000` on `getCameraCharacteristics` and `openCamera`; `notAdopted=mPackageName`, `basePkg=android` |
| P2 | blocked by P1 (locked phone, same refusal, no frames) | `stage=locked ok=false ... opened=false` with the same `SecurityException`, after `isKeyguardShowing=true` |
| P3 | blocked by P1; encoder half known good from the earlier spike | `stage=feed ok=false ... opened=false` |
| P4 | **unverified**: no capture, no indicator | no capture stage ever became ready |
| P5 | **unverified**: no capture to evict; camera app resolvable and startable | `stage=evict ok=false ... opened=true configured=true error=SecurityException` (no readiness marker); `com.android.camera2/com.android.camera.CameraActivity` |
| M1 | camera extension = SYSX system extension in `Contents/Library/SystemExtensions`, `CMIOExtensionMachServiceName`, app's `system-extension.install` entitlement + App Group, activation + System Settings approval, app in `/Applications` | SDK headers, Apple's camera-extension article, WWDC22 10022 |
| M2 | **refused**: ad-hoc extension cannot activate; `OSSystemExtensionErrorDomain` code 2 "Missing entitlement com.apple.developer.system-extension.install"; nothing installed, no camera | `macos/build/vm-e2e/camera/work/{activate.txt,sysextd.log,after-activate.png}` |
| M3 | window fallback viable; DAL dead since 14.1 (Recovery-only override, not used); Developer ID unlocks the entitlement | headers + Apple docs; host has no DAL plug-in directory |

**Earlier spike (four boots, budget was one).** The first probe attempt burned four
boots of the old budget and is kept here because the failures were real:

1. context creation failed twice over: `ActivityThread` needs `Looper.prepareMainLooper()`
   on the bare `app_process` main thread, and the probe cast `systemMain`'s
   ActivityThread to a Context — no camera call;
2. the same, with the cause printed — no camera call;
3. context worked and two cameras were listed, but `getCameraCharacteristics`/open were
   still attributed to `android`, and the `pkg` mode hung on a leaked handler thread;
4. the hang was fixed; the open was still refused for the same package reason, then the
   emulator process went offline (qemu died) before P2-P5.

The P1 answer above is the first boot after the probe was rebuilt with independent
stages, a 60 s watchdog and no leaked threads; it finished all five stages (four
answered "blocked", none hung) and the emulator was killed by the script.

### Phone — C0b: capture in the app process (answered)

C0 says the shell UID cannot open a camera, so the capture has to run in the app
process. Whether that shape works at all is decided by one platform rule: **a
`camera`-type foreground service cannot be created while the app is in the
background** unless a while-in-use exemption applies (Android 14+, and this app
targets API 36 — [Restrictions on starting a foreground service from the
background](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)).
In AOSP (`android-16.0.0_r1`) the check is
`ActiveServices.shouldAllowFgsWhileInUsePermissionLocked`: it returns
`REASON_SYSTEM_UID` for the special UIDs, **including `SHELL_UID` (2000)**, and
`REASON_BACKGROUND_ACTIVITY_PERMISSION` for a caller holding
`START_ACTIVITIES_FROM_BACKGROUND`; any other background caller gets
`REASON_DENIED`, and `startForegroundService()`/`startForeground()` throws
`ForegroundServiceStartNotAllowedException`. The shell user service runs at uid
2000, so **the expected exemption is "a system component starts the service"
(`SHELL_UID`)** — and only if the *caller* of the start is uid 2000; a call made by
the app's own UID is not exempt, no matter who asked it to make the call.

The probe (debug source set only, `android/app/src/debug`):

- `CamFgsProbe`: foreground service with `foregroundServiceType="camera"`; calls
  `startForeground(..., FOREGROUND_SERVICE_TYPE_CAMERA)` inside try/catch, opens the
  back camera with Camera2 into a 1280×720 `ImageReader` for 5 s, counts frames,
  closes everything and stops itself. One line per run under the fixed `PdCamFgs`
  tag — `stage=<name> ok=<bool> started_fg=<bool> opened=<bool> frames=<n>
  error=<class:msg>` — and a 60 s watchdog.
- `CamFgsTrigger`: a DUMP-protected receiver; after `am broadcast -p dev.pocketdeck`
  the app starts the service from its own process.
- `tools/emulator/cam-fgs.sh` (one boot, `--check` dry run): grants `CAMERA`, sends
  the app HOME, then runs stage **a** (uid 2000: `am start-foreground-service`),
  stage **b** (the app starts itself from the broadcast) and stage **b2** (the same
  broadcast with `--allow-background-activity-starts`, which only a
  `START_ACTIVITIES_FROM_BACKGROUND` holder such as shell can set), each unlocked and
  with the phone locked. Stage **c** is skipped: the shell→app direction of the
  existing binding is `IDeckCallback`, whose fixed method set has no camera start,
  and adding one would be an AIDL/protocol change; a binder trigger would still run
  in the app's UID, so it is the same platform question as b.

**Result (2026-10-20 08:22, second boot, run by the reviewer).** The agent's boot
(08:11) was lost to a script bug before the first stage (`printf '--- start …'`
parsed as an option, fixed in 43d9b3f). The reviewer re-ran the fixed
`cam-fgs.sh` once (ledger `camera-c0b emulator 88917`). The app was in the
background for every stage (HOME, deck service `foregroundServiceType=connectedDevice`);
the locked stages ran with `isKeyguardShowing=true` and the screen off.

| stage | started_fg | opened | frames (5 s) | error |
|---|---|---|---|---|
| bg-unlocked-a (uid 2000 `am start-foreground-service`) | yes | yes | 29 | none |
| bg-unlocked-b (the app starts itself) | no | no | 0 | `SecurityException: Starting FGS with type camera … targetSDK=36 requires permissions: all of …` |
| bg-unlocked-b2 (broadcast with `--allow-background-activity-starts`) | yes | yes | 39 | none |
| locked-a | yes | yes | 42 | none |
| locked-b | no | no | 0 | the same `SecurityException` |
| locked-b2 | yes | yes | 42 | none |
| bg-unlocked-a-evict (25 s, camera app started mid-capture) | yes | yes | 28 | `onDisconnected` |

- **Exemption.** As the platform code predicts: a start whose caller is uid 2000
  (stage a) is exempt (`REASON_SYSTEM_UID`), and so is the app's own start when it
  runs inside a broadcast that carries the shell's background-start privileges
  (b2). The app starting itself with no such privilege (b) is refused at
  `startForegroundService` with a `SecurityException`, unlocked and locked.
- **P2 (locked phone): yes.** A shell-started `camera` FGS opens the camera and
  delivers frames with the keyguard up and the screen off (locked-a, locked-b2).
- **P3 (feed): partly.** 29–42 frames per 5 s (6–8 fps) into a 1280×720
  `ImageReader` on the emulator's synthetic camera under software GPU; not a
  measure of a real phone, and the MediaCodec feed/keyframe interval is still
  unmeasured (C1 measures it).
- **P4 (indicator): not seen on the emulator.** `dumpsys media.camera` lists the
  active client as package `dev.pocketdeck` (PID of the app), so the platform
  attributes the capture to the app, which is what the privacy indicator keys on;
  the one `screencap` taken during the capture shows no green dot in the status bar,
  but `screencap` may not include the indicator overlay. To be checked on a real
  phone before C1 ships.
- **P5 (eviction): answered.** Starting the camera app mid-capture disconnected the
  probe (`onDisconnected` after 28 frames); the person's own camera app wins.

## Recommended path

**A CMIO camera extension is the only supported way to make the phone a real Mac
camera, and it is blocked on the Developer ID decision.** Ad-hoc signing is refused
at the entitlement check (M2), DAL plug-ins no longer load (M3b), so there is no
signed-out workaround. Until the signing decision is made:

- build the phone-side capture (C0/C1) and the **"Phone camera" window** fallback
  (C2), which are useful on their own for scanning and desk views;
- keep C3/C4 behind `--with-camera` and behind the Developer ID/notarization work;
- C0b answered the phone half (a shell-started app FGS captures in the background
  and locked); C1 is next, then C2; the privacy indicator is checked on a real phone.

## Phone-side design

Decided after C0 and verified by C0b (2026-10-20, emulator). The shell service cannot
open a camera: the platform refuses every Camera2 call whose caller package is not
one uid 2000 owns, and the `app_process` system context's package is `android` (uid
1000) in a field this process cannot rewrite. So:

- **Who opens the camera: the app process (uid 10xxx), not the shell service.**
  Capture runs in a foreground service of type `camera` in `dev.pocketdeck`, which
  holds `android.permission.CAMERA` (manifest addition; the person grants it on
  first use and the rig grants it with `pm grant`). The foreground service is what
  keeps a session alive while the phone is locked or another app is in front. The
  encoded access units cross to the shell service over the existing one-way
  `IDeckCallback` bridge, which enqueues them into the session's send queue as
  `VIDEO_FRAME`; the wire protocol does not change. One capture at a time: a second
  `cam.start` answers `busy`.
- **Who starts it: the shell service.** Android 14+ refuses to create a `camera`
  FGS from the background unless a while-in-use exemption applies, and the one
  available keys off the caller: C0b showed a uid-2000 start works (the shell
  service issuing the equivalent of `am start-foreground-service`), and the app
  starting itself is refused. So on `cam.start` the shell service starts the app's
  camera service itself (through the activity manager, as uid 2000) and the app
  never starts it on its own.
- **Locked phone.** Works (C0b P2): a shell-started `camera` FGS captures with the
  keyguard up. The service still treats `ERROR_CAMERA_DISABLED` and `onDisconnected`
  as a stop: it stops the encoder, reports `locked`/`disabled`/`evicted`, and never
  loops. The Mac window shows that state instead of a black frame.
- **What the person sees.** Partly answered (P4): the camera service attributes
  the capture to `dev.pocketdeck`; the green dot was not visible in the emulator's
  screencap, so it is checked on a real phone. The green camera dot is per client, so
  an app-process client should get it; the app must say so before the first use. If
  the re-run shows the indicator is not reliable for a background service, the
  fallback is an explicit on-phone confirmation for the first capture.
- **Eviction.** Answered (P5): the camera app's open disconnects ours. A person's own camera app always wins: the service
  reports `evicted` with the exact callback/error, stops the encoder and never
  retries in a loop.

## C1 implementation notes

Built on the shape above; the wire is docs/PROTOCOL.md "Camera". Numbers from the
one C1 emulator boot are at the end of this section.

- **Consent is a setting, default off.** "Let Macs use the camera" sits on the Home
  screen next to the notification-sharing toggle. Turning it on asks for `CAMERA`
  through the normal runtime dialog; the setting only becomes true once the
  permission is granted. Turning it off writes the preference and stops a running
  capture. The app pushes `{allowed, cams}` to the shell service through
  `IDeckService.cameraState` whenever the setting or the permission changes and when
  the deck service starts; the shell refuses `cam.start` with `off` while it is
  false or was never pushed (fail closed). The rig enables it with the preference
  write the toggle makes plus `pm grant` (tools/emulator/cam-c1.sh) — production
  code never grants the permission itself.
- **Start path: the shell spawns `am start-foreground-service`.** The shell service
  has no `ContextImpl` for our package (C0's finding), so the start is the C0b
  stage-a mechanism run as a child process — `am start-foreground-service -n
  dev.pocketdeck/.app.CameraCaptureService --es params <json>` — rather than
  `IActivityManager.startService`, whose binder signature needs the caller's package
  as well. `android:exported="true"` plus `android.permission.DUMP` on the service is
  what lets uid 2000 start it while ordinary apps cannot (the C0b probe's protection,
  kept for production). The service has 5 s to call `startForeground`, so it calls it
  first thing and only then waits for its pipe.
- **Frames app → shell: one reliable pipe per capture.** The shell creates
  `ParcelFileDescriptor.createReliablePipe()` and passes the write end in the one new
  `IDeckCallback.onCameraStart(String paramsJson, in ParcelFileDescriptor sink)`;
  the app's write end is read as `u32 len · u64 ptsUs · u8 flags` (bit0 = keyframe)
  `· Annex-B access unit`. The shell turns each into `VIDEO_FRAME` on the stream
  (keyframes on the control queue, deltas on the delta queue, the existing
  backpressure and drop rules apply). Closing the read end (stop, session end) is
  the signal the other way: the app's next write fails, it stops the camera and
  reports `stopped`; a failed write is never retried.
- **State app → shell: `IDeckService.cameraState(String json)`**, method 16. It
  carries `{"stream":N,"state":"...","reason":"..."}` for the wire and
  `{"allowed":bool,"cams":[...]}` for the gate and the camera list. The session
  relays state to `cam.state`; a terminal state also tears the pipe down. `cam.list`
  is answered from the last pushed list (empty while the setting is off).
- **The app service** (`CameraCaptureService`, main source set) is `camera`-typed,
  shows an ongoing "Your Mac is using the camera" notification with Stop, and runs
  the state machine in `CameraControl` (pure JVM code behind `CameraEngine`/`AuSink`
  seams) with `Camera2Engine` (Camera2 → MediaCodec surface) and `CameraAuWriter` as
  the real implementations. `onDisconnected` is `evicted`; `ERROR_CAMERA_DISABLED`
  is `disabled`; `ERROR_CAMERA_IN_USE`/`MAX_CAMERAS_IN_USE` are `busy`; nothing is
  retried. The encoder is the `WindowStream` shape: `video/avc`, surface colour
  format, VBR, no B-frames, I-frame interval 2 s.
- **Encoder details.** Bitrate ~0.12 bpp·fps, capped at 8 Mbps; SPS+PPS from the
  output format (`csd-0`, `csd-1`) are prepended to the first keyframe only; every
  later keyframe is a plain IDR. The first keyframe therefore decodes without a
  prior config.
- **One capture at a time, service-wide.** A second `cam.start` answers `busy` in the
  shell before anything is spawned; the app service refuses one too (its registry
  holds one stream) if it somehow receives two.

### C1 verification

- **Host, `cam-wire` (fakephone + deckctl, no Mac app): PASS 15/15.** list (2
  cameras) → 3 s capture (92 frames, 30.7 fps, keyframe first and with SPS/PPS, a
  1906 ms keyframe gap) → a second stream `busy` → `cam.stop` → `stopped` → the
  camera free again (61 frames) → the Annex-B decodes as 1280×720 H.264 →
  eviction after 29 frames (`evicted`, 0 frames after, no retry) → setting off
  (empty list, `off`).
- **JVM (K1):** the state machine (start/frames framing/busy/evict/pipe EOF/off) and
  the wire shapes in `CameraCaptureTest` (9) and `CameraBridgeTest` (8).
- **Emulator: NOT verified — C1's one boot was lost to a rig bug.** The boot
  (2026-10-20 10:55, ledger `camera-c1 emulator 32633`) reached the app with the
  permission granted and the wire up (deckctl paired on the rig, real phone
  server), but `tools/emulator/cam-c1.sh` wrote the `camera_allowed` pref *after*
  `</map>`, where SharedPreferences cannot see it: `cam.start` answered `off` on
  the wire (frames 0), which is the gate working, and the script then died on an
  undefined helper (`stats_field`). Both are fixed (the key is asserted inside
  `<map>`, and `cam.list` must be non-empty before the capture stages), but the
  budget is one boot, so the emulator numbers — fps, keyframe interval with the
  phone locked, eviction and recovery, `stopped` and the service gone, the `off`
  path after the setting is turned off — are unverified until a re-run:
  `tools/emulator/cam-c1.sh --check` then the script inside one
  `heavy.sh` call. Evidence from the lost boot: `.agent/emu/cam-c1.log`,
  `.cache/cam-c1-start.txt`.
- **Unverified on a real phone:** the privacy dot for an app-process camera client
  (C0b's P4 note); the emulator's synthetic camera is not a measure of a real
  camera's fps or keyframe timing.

## Slices


| | Slice | What | Size | Gate |
|---|---|---|---|---|
| C0 | Finish the phone probe | done 2026-10-20: staged probe, one boot. Shell UID lists the camera and cannot open it (package/uid refusal); P2–P5 are blocked by P1 | S | none |
| C0b | App-process camera FGS probe | **done** 2026-10-20: shell-started `camera` FGS captures in the background and locked; the app starting itself is refused; eviction = `onDisconnected`; indicator to check on a real phone | S | none |
| C1 | Phone capture service | **built; host-verified, emulator boot lost to a rig bug (see "C1 verification")**: Camera2 in the **app process** (foreground service, `CAMERA` permission) → MediaCodec H.264 1280×720@30 (the `WindowStream` encoder settings) → `VIDEO_FRAME` to the shell session, start/stop, busy/disabled/evicted errors, one stream | M | C0b (done) |
| C2 | "Phone camera" window | the existing H.264 decode path in a normal Mac window, a menu item and start/stop; no extension, ships with today's ad-hoc signing | S-M | C1 |
| C3 | CMIO camera extension | provider/device/stream, decode H.264 into `CVPixelBuffer`, App Group socket between app and extension, stream on first client and stop when none; replaces the solid-colour source | M-L | C1; **Developer ID** |
| C4 | Signing and install | System-Extension App ID, Developer ID profiles for app and extension, notarization, `/Applications` install, approval deep-link, uninstall/upgrade | M | signing decision |
