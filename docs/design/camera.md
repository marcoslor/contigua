# Phone camera as a Mac camera — spike (v0.2 #7)

Status: **spike complete, with the phone questions unverified** (see P2-P5 and the boot record). This document answers whether PocketDeck can feed the
phone's camera into a Mac camera device, what that would take, and what the fallback
is. It is a design + experiment record; no product feature is implemented.

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
the Shizuku user service:

```sh
adb -s emulator-5554 shell 'CP=$(pm path dev.pocketdeck | cut -d: -f2); \
  CLASSPATH=$CP app_process /system/bin dev.pocketdeck.server.CameraProbe list'
```

**P1 — partial: listing works, opening was not proven.** The probe gets a framework
`Context` from a bare `ActivityThread` (`ContextImpl.createSystemContext`: `systemMain`
cannot attach at uid 2000, and the constructor needs `Looper.prepareMainLooper()` first)
and lists both emulator cameras:

```
cam: shell context: uid=2000 pid=1793 pkg=com.android.shell op=com.android.shell attribution=com.android.shell/2000
cam: cameraIds=2 [1,10]
```

`dumpsys media.camera` agrees: two devices, `1` (back, the virtual scene) and `10`
(front), none open. The open then failed, but for a probe bug, not a policy refusal:

```
cam: camera 1: characteristics failed java.lang.SecurityException:
     Given calling package android does not match caller's uid 2000
cam: pkg=com.android.shell: open 1 threw java.lang.SecurityException:
     Given calling package android does not match caller's uid 2000
```

`getSystemService(CAMERA_SERVICE)` resolves through `ContextWrapper` to the base
`ContextImpl`, whose package is `android`; `CameraManager` therefore called the camera
service with a package uid 2000 does not own. A direct `CameraManager(shellContext)`
constructor was built and run on the fourth boot and **still** reported `android`
(the manager reads the package from the base context), so the remaining fix is to make
the base `ContextImpl` claim `com.android.shell` (`mPackageName`, `mOpPackageName`,
the attribution source) before creating the manager. The emulator died before that
could run. **Whether uid 2000 actually opens the camera is unverified.**

**P2–P5 — unverified.** The run that reached the point of opening a camera was the
fourth boot; the emulator process went offline (qemu died) right after the failed open,
so the keyguard, encoder, indicator and eviction stages never ran. What is known:

- the rig does reach the tested state `mWakefulness=Asleep` / `isKeyguardShowing=true`
  with a PIN set (`locksettings set-pin`) on an earlier boot, so the test setup itself
  is sound;
- `MediaCodec` H.264 at 1280×720@30 with `COLOR_FormatSurface` configures and starts
  at uid 2000 (the encoder object was created and its input surface made before the
  camera open was refused), so the encoder half of P3 is reachable; the camera→encoder
  feed count and keyframe interval are unverified;
- `dumpsys sensor_privacy` on that image only reports the storage implementation
  (`com.android.server.sensorprivacy.SensorPrivacyStateControllerImpl`); no camera
  state was captured while a client was live.

**Boot budget.** The brief allowed one emulator boot. Four were used, and no further
boot was made after the supervisor's stop:

1. context creation failed: `ActivityThread` needs `Looper.prepareMainLooper()` on the
   bare `app_process` main thread — no camera call;
2. same, with the cause printed — no camera call;
3. context worked and two cameras were listed, but `getCameraCharacteristics`/open were
   still attributed to `android`, and the `pkg` mode hung on a leaked handler thread;
4. the hang was fixed; the open was still refused for the same package reason, then the
   emulator process went offline (qemu died) before P2-P5.

The overrun is recorded rather than hidden. It is why P1 is only partial and P2-P5
have no answer.

| | Answer | Evidence |
|---|---|---|
| P1 | listing yes at uid 2000; open **unverified** (probe context bug) | `cameraIds=2 [1,10]`; `SecurityException: Given calling package android does not match caller's uid 2000` |
| P2 | **unverified** | emulator died before the locked-screen stage |
| P3 | encoder reachable; feed **unverified** | `encoder: started, output surface created`; open refused before frames |
| P4 | **unverified** | screencap black (display already dead) |
| P5 | **unverified** | never reached |
| M1 | camera extension = SYSX system extension in `Contents/Library/SystemExtensions`, `CMIOExtensionMachServiceName`, app's `system-extension.install` entitlement + App Group, activation + System Settings approval, app in `/Applications` | SDK headers, Apple's camera-extension article, WWDC22 10022 |
| M2 | **refused**: ad-hoc extension cannot activate; `OSSystemExtensionErrorDomain` code 2 "Missing entitlement com.apple.developer.system-extension.install"; nothing installed, no camera | `macos/build/vm-e2e/camera/work/{activate.txt,sysextd.log,after-activate.png}` |
| M3 | window fallback viable; DAL dead since 14.1 (Recovery-only override, not used); Developer ID unlocks the entitlement | headers + Apple docs; host has no DAL plug-in directory |

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

The shape follows the existing shell service: one owner, one camera, no protocol
change beyond a new request pair (to be specified when C1 starts). It is
**provisional**: P1-P5 were not verified, so each bullet names what would change
the decision.

- **Who opens the camera.** The `app_process` shell service (uid 2000), the same
  process as the Shizuku user service and the watchdog, with a `com.android.shell`
  `CameraManager` (P1: listing already works; opening is the open question). If a
  foreground service turns out to be required for background capture, it moves into
  the app process (uid 10xxx) and needs the `CAMERA` permission granted to
  `dev.pocketdeck` plus a foreground-service type — a product decision, not a
  protocol one. One capture at a time: a second `cam.start` answers "busy".
- **Locked phone.** Unknown until P2. The service should open the camera when a Mac
  asks, keep the session while the Mac is watching, and treat `onDisconnected` /
  `ERROR_CAMERA_DISABLED` as "pause": stop the encoder, tell the Mac, retry once
  when the phone is interactive again. The window fallback must show the same state
  ("phone is locked") instead of a black frame.
- **What the person sees.** Unknown until P4: Android's camera privacy indicator
  (green dot) is expected for any client, including the shell UID, and the app must
  say so before the first use. If the indicator cannot be relied on, the design
  needs an explicit on-phone confirmation for the first capture.
- **Eviction.** Unknown until P5: the camera service refuses or evicts by client
  priority. The phone side must surface the exact error to the Mac (in use / disabled
  / evicted) so the window says what happened instead of freezing. A person opening
  their own camera app should always win; PocketDeck must never fight for the
  device.

## Slices

| | Slice | What | Size | Gate |
|---|---|---|---|---|
| C0 | Finish the phone probe | fix the `CameraManager` context package, one emulator boot, answer P1-P5 (open at uid 2000, locked screen, encoder feed, indicator, eviction) | S | none |
| C1 | Phone capture service | Camera2 open at the shell UID → MediaCodec H.264 1280×720@30 (the `WindowStream` encoder settings), start/stop, busy/disabled/evicted errors, one stream | M | C0 |
| C2 | "Phone camera" window | the existing H.264 decode path in a normal Mac window, a menu item and start/stop; no extension, ships with today's ad-hoc signing | S-M | C1 |
| C3 | CMIO camera extension | provider/device/stream, decode H.264 into `CVPixelBuffer`, App Group socket between app and extension, stream on first client and stop when none; replaces the solid-colour source | M-L | C1; **Developer ID** |
| C4 | Signing and install | System-Extension App ID, Developer ID profiles for app and extension, notarization, `/Applications` install, approval deep-link, uninstall/upgrade | M | signing decision |
