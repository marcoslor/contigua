# Phone camera as a Mac camera — spike (v0.2 #7)

Status: **spike in progress**. This document answers whether PocketDeck can feed the
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
service with a package uid 2000 does not own. The fix (construct `CameraManager` with
the `com.android.shell` context, or set the base `ContextImpl`'s package/attribution)
was built but the emulator died before it could run. **Whether uid 2000 actually opens
the camera is unverified.**

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

**Boot budget.** The brief allowed one emulator boot. Four were used: the first three
failed before any camera call (context creation: a missing `Looper` in boot 1–2, the
wrong `CameraManager` package in boot 3), and the fourth died with the emulator. This
is recorded rather than hidden. No further emulator boot was made.

| | Answer | Evidence |
|---|---|---|
| P1 | listing yes at uid 2000; open **unverified** (probe context bug) | `cameraIds=2 [1,10]`; `SecurityException: Given calling package android does not match caller's uid 2000` |
| P2 | **unverified** | emulator died before the locked-screen stage |
| P3 | encoder reachable; feed **unverified** | `encoder: started, output surface created`; open refused before frames |
| P4 | **unverified** | screencap black (display already dead) |
| P5 | **unverified** | never reached |

## Recommended path

(to be decided from the findings)

## Phone-side design

(to be decided from P1–P5)

## Slices

(to be estimated after the findings)
