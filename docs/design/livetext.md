# Live Text (ROADMAP v0.2 #3)

Live Text mode puts Apple's VisionKit analysis on one frozen frame of a stream
window: select and copy text, data detectors (links, phone numbers, dates),
dragging an image subject out, Visual Look Up, Translate where macOS offers it,
and dragging or copying the whole frame as an image. It is the only way in:
clicks and click-and-hold on the video keep going to Android.

## Frame route

`AVSampleBufferDisplayLayer.sampleBufferRenderer.copyDisplayedPixelBuffer()`
(macOS 14.4+; this app targets macOS 26) returns exactly the pixel buffer the
layer is showing, so it is the route. It is read on the main thread (the layer
is main-thread-only here, see VideoLayerView) and only when the person enters
the mode, never per frame: no CPU readback on the normal path.

Falls back to nothing else: a `VTDecompressionSession` decoding a fresh
`window.keyframe` was the second choice and would need protocol work, but route
one covers it. If the buffer is missing (no frame displayed yet, or the layer
was flushed), entering the mode does nothing and the window keeps showing live
video.

The frozen frame is an `NSImageView` over the video rect; the video is paused
at the phone (`window.pause`, the same message occlusion uses) so the mode
really is still and costs no encode/decode while it is up. Leaving resumes
(`window.resume`), which restarts the phone's encoder with a fresh
`VIDEO_CONFIG`; the mode is idle by then, so that config is ignored.

## States

`LiveTextMode` (pure, unit tested):

```
idle --enter--> capturing --frameCaptured--> analyzing --analysisFinished--> shown
                                                       \--analysisFailed----> shown
any non-idle --exit(reason)--> idle
```

- `enter` while capturing/analyzing/shown is ignored (a second Enter does not
  start a second capture).
- `exit` reasons: Esc, the shortcut/menu again, the bar button, a window resize,
  the window closing, the link dropping, a new stream config (rotation, size).
  Every one drops the overlay and brings live video back.
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
mapper reads: it asks the window to leave the mode instead of sending Back.

Entering clears any pending text batch and any local gesture/hover state without
sending their release frames: the mode is entered from the keyboard or the bar,
so there is normally nothing held, and a held touch must not leak into the
frozen frame either.

## Copy and drag

- ⌘C while the overlay has no text selection copies the frozen frame as PNG +
  TIFF to the general pasteboard; with a selection VisionKit's own copy runs.
- The bar button (SF Symbol `text.viewfinder`) drags the frozen frame out as a
  PNG file. It toggles the mode on click; the drag starts after a small
  movement.
- A small "Live Text" pill in the bar (top centre in immersive/full screen)
  says input is paused.

## Privacy

Analysis is Apple's on-device VisionKit/ImageAnalyzer: the frame stays in this
process, nothing is uploaded and nothing leaves the Mac. The mode logs state
transitions only, never recognized text, frame pixels or file names. The debug
hook reports `hasText`, transcript length and whether one token from the test
script occurs — never the transcript.
