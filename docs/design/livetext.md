# Live Text (ROADMAP v0.2 #3)

Live Text mode puts Apple's VisionKit analysis on one frozen frame of a stream
window: select and copy text, data detectors (links, phone numbers, dates),
dragging an image subject out, Visual Look Up, Translate where macOS offers it,
and dragging or copying the whole frame as an image. It is the only way in:
clicks and click-and-hold on the video keep going to Android.

## Frame route

Two routes, in this order:

1. `AVSampleBufferDisplayLayer.sampleBufferRenderer.displayedPixelBuffer()`
   (the API header's `copyDisplayedPixelBuffer`, macOS 14.4+) returns exactly
   the buffer the layer is showing. It is read on the main thread (the layer is
   main-thread-only here, see VideoLayerView) and only when the person enters
   the mode, never per frame. The renderer answers only while its timebase is
   stopped, so the rate is paused for the copy and put back at once.
2. The layer reports no displayed buffer when its window is occluded (a quiet
   e2e run, a window fully or partly behind another). Entering then asks the
   phone for a keyframe (`window.keyframe`) and decodes the next samples with a
   private `VTDecompressionSession` in `KeyframeSnapshotter`, which is torn down
   after the first frame: the same picture the phone is sending, one frame
   behind. The phone restarts its encoder for that keyframe, so a `VIDEO_CONFIG`
   arriving while the mode is still capturing is the answer to our request and
   is not treated as a window change.

If neither route delivers a frame within 5 s, the mode leaves again
(`captureFailed`) and the window keeps showing live video.

The frozen frame is an `NSImageView` over the video rect; the phone's stream is
paused (`window.pause`, the same message occlusion uses) once the frame is
frozen, so the mode really is still and costs no encode/decode while it is up.
Leaving resumes (`window.resume`), which restarts the phone's encoder with a
fresh `VIDEO_CONFIG`; the mode is idle by then, so that config is ignored.

## States

`LiveTextMode` (pure, unit tested):

```
idle --enter--> capturing --frameCaptured--> analyzing --analysisFinished--> shown
      |                                             \--analysisFailed------> shown
      \--------captureFailed / any exit(reason)-------------------> idle
```

- `enter` while capturing/analyzing/shown is ignored (a second Enter does not
  start a second capture).
- `capturing` is the window between pressing the shortcut and having a frame:
  route one is synchronous, route two waits for the keyframe.
- `exit` reasons: Esc, the shortcut/menu/bar button again, a window resize, the
  window closing, the link dropping, a new stream config (rotation, size), and
  the capture timeout. Every one drops the overlay and brings live video back.
- `analysisFailed` still shows the frozen frame: copying it and leaving work,
  only text selection is missing.

The mode is per stream window. The video view owns the freeze image and the
`ImageAnalysisOverlayView` (VisionKit: `ImageAnalyzer` with `.text`,
`.machineReadableCode`, `.visualLookUp`, `preferredInteractionTypes =
.automatic`); the window controller owns the phone-side pause/resume and the
menu/chrome state.

## Input rules

While the state is not idle, `InputMapper` forwards nothing: keyboard, pointer
(touch down/move/up, right and side buttons, swipe), scroll, trackpad fingers,
pinch/rotate, hover and pending text are all dropped. Esc is the one key the
mode reads: it leaves instead of sending Back.

Entering clears any pending text batch and any local gesture/hover state without
sending their release frames: the mode is entered from the keyboard or the bar,
so there is normally nothing held, and a held touch must not leak into the
frozen frame either.

## Chrome, copy and drag

- View ▸ Live Text (⌘⇧T) and the bar's `text.viewfinder` button toggle the mode.
  The button is at the right end of the framed bar, or inside the immersive
  dwell pill; full screen has no bar, so the menu is the way in there.
- A small "Live Text" pill in the bar (top centre of the stream where there is
  no bar) says the window is frozen and input is paused.
- ⌘C while the overlay has no text selection copies the frozen frame as PNG +
  TIFF to the general pasteboard; with a selection VisionKit's own copy runs.
- **Force click copies a subject.** In the mode, a pressure stage-2 click
  (Force Touch trackpad) on a point covered by a lifted subject copies that
  subject's image to the pasteboard as PNG + TIFF — the same image the
  right-click *Copy Subject* menu copies — plays the standard haptic and shows
  the status pill as "Subject copied" for about 1.5 s. On text or empty area the
  force click is left to the system (Look Up); normal clicks, drags and the
  right-click menu are untouched. Nothing looks for subjects outside the mode.
  The gated debug route `livetext forceclick <x> <y>` drives the same code path
  and logs `livetext: force-click subject=<0|1> copied=<0|1>` (counts only).
- The bar button drags the frozen frame out as a PNG file (written to a
  temporary directory when the drag starts).

## Privacy

Analysis is Apple's on-device VisionKit/ImageAnalyzer: the frame stays in this
process, nothing is uploaded and nothing leaves the Mac. The mode logs state
transitions only, never recognized text, frame pixels or file names. The debug
hook reports `hasText`, transcript length and whether one token from the test
script occurs — never the transcript.

## Tests

- `LiveTextModeTests`: every transition, every exit reason.
- `LiveTextInputGateTests`: pointer, keys (Esc included), scroll, hover,
  trackpad and pending text are dropped while the mode is on.
- `LiveTextDebugScriptTests`: the `--debug-livetext` script grammar.
- e2e `livetext`: enter → VisionKit reads `POCKETDECK` from the fake phone's
  text frame; no `INPUT` frame reaches the phone while the mode is on and the
  phone stops sending frames; `copy-image` writes a PNG at the stream's pixel
  size; exit resumes the frames; a resize while in the mode drops to idle.
