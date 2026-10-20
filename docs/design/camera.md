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

(to be filled from the experiment logs)

## Recommended path

(to be decided from the findings)

## Phone-side design

(to be decided from P1–P5)

## Slices

(to be estimated after the findings)
