# Phone camera as a Mac camera — spike (v0.2 #7)

Status: **phone probe answered (C0): the shell UID cannot open the camera; C1 is
not built, and the capture moves to the app process.** This document answers whether
PocketDeck can feed the phone's camera into a Mac camera device, what that would take,
and what the fallback is. It is a design + experiment record; no product feature is
implemented.

Shape in one line: a **CoreMediaIO Camera Extension** on the Mac presents a camera
device; the extension gets H.264 frames from the PocketDeck app, which gets them from
a Camera2 session on the phone running at the shell UID (the same `app_process` the
Shizuku user service already uses).

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

### Mac — VM session (M2)

One session was meant to answer M2. Three boots were used, all recorded below.
The bundle was `bundle.sh ... --variant e2e --with-camera`, ad-hoc signed, copied
into the guest's `/Applications/PocketDeckCamera.app` and registered with
LaunchServices. The activation probe (`macos/Extensions/Camera/activate.swift`,
ad-hoc signed, run in the guest's GUI session) submitted the request.

**Result: refused before any approval, exactly as expected.** The app's signature
does carry the entitlement — and the system still reports it missing, because an
ad-hoc signature has no provisioning profile to authorize it:

```
$ codesign -d --entitlements :- /Applications/PocketDeckCamera.app
  com.apple.developer.system-extension.install = true
  com.apple.security.application-groups = [group.dev.pocketdeck.mac.camera-e2e]

$ /Users/admin/pd-e2e/camera/work/activate dev.pocketdeck.mac.camera-e2e
request: activate dev.pocketdeck.mac.camera-e2e
submitted
delegate failed: domain=OSSystemExtensionErrorDomain code=2
  description=Missing entitlement com.apple.developer.system-extension.install
activate_exit=1
```

Consequences in the guest, from the same run:

- `systemextensionsctl list` → `0 extension(s)`; `/Library/SystemExtensions` is
  empty apart from `.staging`;
- no `CameraExtension` process, and no camera: `system_profiler SPCameraDataType`
  is empty (the VM has no camera at all), so the "does it appear in Photo Booth /
  FaceTime" branch was never reachable;
- no approval prompt: the screenshot (`work/after-activate.png`) shows System
  Settings › Login Items & Extensions with no camera extension row; the
  deactivation request fails with the same code 2 (nothing was installed);
- `sysextd` logs the request (`attempting to realize extension with identifier
  dev.pocketdeck.mac.camera-e2e`) and nothing after it — no user-facing error, the
  caller only sees code 2.

The `sysextd`/CoreMediaIO log, the screenshot, the delegate output and the
entitlement dumps are in `macos/build/vm-e2e/camera/work/` (not committed).

**Boot record.** Session 1 stopped before activation: rsync could not create the
guest's `camera/` directory. Session 2 stopped before activation: the destination
app directory already existed, so rsync nested a second `PocketDeck.app` inside it.
Session 3 produced the result above. The budget was one session; the overrun is
recorded rather than hidden. Both failures were guest-copy mistakes, not test
results.

### Mac — SDK research (M1)

A phone camera becomes a Mac camera only through a **CoreMediaIO Camera Extension**
(macOS 12.3+, `CoreMediaIO.framework` `CMIOExtension*`; the WWDC22 "Create camera
extensions with Core Media IO" session and "Creating a camera extension with Core Media
I/O"). It is a **system extension**, not an app extension: macOS runs it in its own
sandboxed daemon (as the `_cmiodalassistants` role user), validates every buffer, and
republishes it as a normal capture device through AVFoundation. No piece of PocketDeck
code runs inside the capturing app.

**Bundle layout.** The extension lives in the containing app:

```
PocketDeck.app/Contents/Library/SystemExtensions/dev.pocketdeck.mac.camera.systemextension/
  Contents/Info.plist
  Contents/MacOS/CameraExtension
```

The extension's `Info.plist` must declare `CFBundlePackageType = SYSX` and the
`CMIOExtension` dictionary with `CMIOExtensionMachServiceName`; Apple's register
assistant finds and launches the extension by that Mach service name, so it is
required, not cosmetic. The `CMIOExtensionInfoDictionaryKey` / `…MachServiceNameKey`
constants are in `CMIOExtensionProvider.h`.

**Entitlements.** From Apple's article and the WWDC22 walkthrough:

- the **app** carries `com.apple.developer.system-extension.install` (the "System
  Extension" capability) and an **App Group** shared with the extension;
- the **extension** carries `com.apple.security.app-sandbox` and the same App Group.
  Apple's guidance is that the group identifier is prefixed by the extension's
  MachServiceName. `com.apple.security.device.camera` is needed only if the
  extension itself opens a camera (we do not: the frames come from the phone);
- the restricted `system-extension.install` entitlement is authorized by a
  **provisioning profile**, i.e. a Developer ID (or development) team identity. An
  ad-hoc signature has no profile, which is the experiment below.

**Activation.** The app submits
`OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:queue:)` and
implements the delegate: `requestNeedsUserApproval(_:)`, `request(_:didFinishWithResult:)`
(`.completed`, `.willCompleteAfterReboot`) and `request(_:didFailWithError:)`. The
person approves in System Settings — Privacy & Security's "Allow" prompt, and the
extension is listed under Login Items & Extensions › Camera Extensions. The containing
app must be in `/Applications`: an app elsewhere fails with
`OSSystemExtensionErrorUnsupportedParentBundleLocation` (code 3). The other error codes
that matter here are `MissingEntitlement` (2), `CodeSignatureInvalid` (8),
`ValidationFailed` (9) and `ForbiddenBySystemPolicy` (10). Installing a replacement
build needs a reboot before its daemon runs (a known CoreMediaIO behaviour, Apple
forums thread 756234).

**Built here (host, compile + sign only).** `macos/Extensions/Camera/` now holds a
minimal extension (one provider, one device, one 1280×720@30 source stream that sends
a solid colour; the real one would send the phone's decoded frames) and
`bundle.sh --with-camera` builds and ad-hoc signs it into
`Contents/Library/SystemExtensions/dev.pocketdeck.mac.camera-<variant>.systemextension`.
On this host that bundle was **built and signed but never opened, copied into place,
registered or activated** (the brief forbids it):

```
$ codesign --verify --deep --strict build/vm-e2e/camera/PocketDeck.app   # no output
$ plutil -p .../dev.pocketdeck.mac.camera-e2e.systemextension/Contents/Info.plist
  "CFBundlePackageType" => "SYSX"
  "CMIOExtension" => { "CMIOExtensionMachServiceName" => "group.dev.pocketdeck.mac.camera-e2e" }
$ codesign -d --entitlements :- .../CameraExtension
  com.apple.security.app-sandbox = true
  com.apple.security.application-groups = [group.dev.pocketdeck.mac.camera-e2e]
$ codesign -d --entitlements :- PocketDeck.app
  com.apple.developer.system-extension.install = true
  com.apple.security.application-groups = [group.dev.pocketdeck.mac.camera-e2e]
```

## M3 — alternatives

**(a) A camera-less "Phone camera" window.** The stream the app already decodes in
a normal PocketDeck window; no extension, no signing, works today. What the person
gets: the phone's view on the Mac, useful for document scans, a desk view, or
checking the framing of the phone that is filming. What they lose: it is not a
camera *device*. Zoom, Teams, FaceTime, Photo Booth and every other app that asks
CoreMediaIO for a camera cannot select it; there is no per-app camera permission,
no system camera menu entry, no macOS green-dot semantics. It also needs the phone
to be unlocked if P2 turns out badly (see below). Cost: **S-M** (window + start/stop
around the existing stream).

**(b) The deprecated DAL plug-in.** Not an option on macOS 26. DAL plug-ins were
deprecated in 12.3 and **disabled from macOS 14.1**; the only way back is booting
into Recovery and setting
`system-override legacy-camera-plugins-without-sw-camera-indication=on`, which
changes a security setting (the brief forbids it, and we did not touch it). Even
when loaded, DAL plug-ins never worked in Apple's own apps (FaceTime, QuickTime,
Photo Booth) because they load code into the app's process and hardened runtime /
library validation refuses them — so the escape hatch would not even deliver the
goal. Host evidence for the removal: `/Library/CoreMediaIO/Plug-Ins/DAL` does not
exist and `/System/Library/CoreMediaIO/Plug-Ins` holds only `plugins-info.txt`.

**(c) What a Developer ID account unlocks.** The restricted
`com.apple.developer.system-extension.install` entitlement is authorized by a
provisioning profile, so the CMIO path needs an Apple Developer Program team: a
System-Extension-enabled App ID, **Developer ID provisioning profiles for both the
app and the extension**, the Developer ID certificate, and notarization for
distribution. That turns M2 from a code-2 refusal into a real extension, at the
cost of the membership and a signing/notarization pipeline — no new engineering
beyond C3. It ties directly to the pending "release signing key" decision: if
PocketDeck is going to ship any system extension (camera, File Provider for
release, future drivers), that decision is now on the critical path for the camera
feature; without it the camera can only be a window.

## Recommended path

**A CMIO camera extension is the only supported way to make the phone a real Mac
camera, and it is blocked on the Developer ID decision.** Ad-hoc signing is refused
at the entitlement check (M2), DAL plug-ins no longer load (M3b), so there is no
signed-out workaround. Until the signing decision is made:

- build the phone-side capture (C0/C1) and the **"Phone camera" window** fallback
  (C2), which are useful on their own for scanning and desk views;
- keep C3/C4 behind `--with-camera` and behind the Developer ID/notarization work;
- re-probe P1-P5 first: the phone side is the part the spike could not verify, and
  the window fallback depends on the same locked-phone answer as the extension.

## Phone-side design

Decided after C0 (2026-10-20). The shell service cannot open a camera: the platform
refuses every Camera2 call whose caller package is not one uid 2000 owns, and the
`app_process` system context's package is `android` (uid 1000) in a field this
process cannot rewrite. So:

- **Who opens the camera: the app process (uid 10xxx), not the shell service.**
  Capture runs in a foreground service of type `camera` in `dev.pocketdeck`, which
  holds `android.permission.CAMERA` (manifest addition; the person grants it on
  first use and the rig grants it with `pm grant`). The foreground service is what
  keeps a session alive while the phone is locked or another app is in front. The
  encoded access units cross to the shell service over the existing one-way
  `IDeckCallback` bridge, which enqueues them into the session's send queue as
  `VIDEO_FRAME`; the wire protocol does not change. One capture at a time: a second
  `cam.start` answers `busy`.
- **Locked phone.** Not answered by C0 (blocked). The chosen shape is an
  app-process, foreground-service client, which Android allows to capture with the
  keyguard up; the service still treats `ERROR_CAMERA_DISABLED` and
  `onDisconnected` as a pause, stops the encoder, reports `locked`/`disabled`, and
  retries exactly once when the phone becomes interactive. The Mac window must show
  that state instead of a black frame.
- **What the person sees.** Still unverified (P4). The green camera dot is per
  client, so an app-process client gets it; the app must say so before the first
  use. If a later probe shows the indicator is not reliable for a background
  service, the fallback is an explicit on-phone confirmation for the first capture.
- **Eviction.** Still unverified (P5). A person's own camera app always wins: the
  service reports `evicted` with the exact callback/error, stops the encoder and
  never retries in a loop.

## Slices

| | Slice | What | Size | Gate |
|---|---|---|---|---|
| C0 | Finish the phone probe | done 2026-10-20: staged probe, one boot. Shell UID lists the camera and cannot open it (package/uid refusal); P2–P5 are blocked by P1 | S | none |
| C1 | Phone capture service | Camera2 in the **app process** (foreground service, `CAMERA` permission) → MediaCodec H.264 1280×720@30 (the `WindowStream` encoder settings) → `VIDEO_FRAME` to the shell session, start/stop, busy/disabled/evicted errors, one stream | M | C0 (answered no for the shell UID) |
| C2 | "Phone camera" window | the existing H.264 decode path in a normal Mac window, a menu item and start/stop; no extension, ships with today's ad-hoc signing | S-M | C1 |
| C3 | CMIO camera extension | provider/device/stream, decode H.264 into `CVPixelBuffer`, App Group socket between app and extension, stream on first client and stop when none; replaces the solid-colour source | M-L | C1; **Developer ID** |
| C4 | Signing and install | System-Extension App ID, Developer ID profiles for app and extension, notarization, `/Applications` install, approval deep-link, uninstall/upgrade | M | signing decision |
