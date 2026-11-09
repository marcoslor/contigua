# Every full-window cover (ISS-66, ISS-55)

Inventory of the surfaces that draw over a whole window. The shared rule is the
B language from ISS-55 (the held frame blurred hard and darkened; white wrapping
text; a glass capsule button; 200 ms fades), applied through one `FrostedCover`
view.

Window kinds: the Phone Mirror (`PhoneWindow.swift`), and the app, link and
handoff windows, which share `StreamWindow.swift` and `StreamChrome.swift`.

| # | Cover / state | File and type | Trigger | Ends on | Text and buttons | Spec |
|---|---|---|---|---|---|---|
| 1 | Opening — opening | `OpeningCover.swift`, `OpeningCoverView` (all four window kinds) | the window opens and no first frame has arrived | the first frame, the phone's refusal, 20 s, or Cancel | "<app> — opening on <phone>"; no button | WIN-11; MIRROR-2 |
| 2 | Opening — slow | same | 5 s without a first frame | first frame, 20 s, Cancel | the same title; "Taking longer than usual"; Cancel | WIN-11; MIRROR-2 |
| 3 | Opening — failed | same | 20 s, or `error{...}` at once | a late first frame (the picture can still come), or Close | "<phone> can't open <app>."; a reason line for a known code; Close only | WIN-11; MIRROR-2 |
| 4 | Picture stalled | `StallOverlay.swift`, `StallOverlayView` (all four window kinds) | 1.5 s of silence with no frame or `window.still` | a frame or a `still` | "Not responding"; "Waiting for <phone>…"; the app's icon; no button | WIN-17, WIN-39 |
| 5 | Link down — reconnecting | same | the link drops; shown 1 s after the drop | the link returns or a frame arrives | "Reconnecting…"; "Waiting for <phone>…"; the icon; no button | WIN-16, WIN-39 |
| 6 | Link down — offline | same | 15 s after the drop | the link returns | "Phone offline"; "Waiting for <phone>…"; the icon; no button | WIN-16, WIN-39 |
| 7 | Phone screen off | `PhoneScreenOverlay.swift`, `PhoneScreenOverlayView` (Phone Mirror) | `state.screen: off` | `state.screen: on` | "The phone's screen is off"; Wake Screen (a click anywhere on the cover also wakes) | MIRROR-6, MIRROR-7 |
| 8 | Secure surface | same | `state.secure: true`, or 0.5 s of near-black frames while the screen is on | `state.secure: false`, or a frame with content | "Android doesn't let PocketDeck show this screen."; no button | MIRROR-8 |

Checked and not full-window covers (regular window content or a small pill, not
a sheet over a picture):

- The Deck's Welcome, Nearby and phone-grid states (`DeckViews.swift`): the Deck
  has no held picture to cover; these are its ordinary content, and the bottom
  "No apps match" line is a grid empty state, not a cover. No change here.
- The menu-bar panel (`MenuBarPanel.swift`) is a 320 pt card, not a window cover.
- The stream pills (`GlassPillView`, Live Text status, the panel pill, the drop
  and paste pills, the "Opened fresh" note) are small overlays, not covers.
- Live Text (`LiveTextView.swift`) draws the frozen frame itself (Image Analysis)
  and is a mode of the picture, not a cover over it.

One row per state, because the words and buttons differ even where the view is
shared.

## Today's renders

The `.agent/covers/today/` set (not committed) has one PNG per state and
appearance at these sizes: the phone window's own opening size (~268×628), its
minimum 300×650 stream, 430×935, an app window at 320×650, and an app window at
1000×700. The script is `.agent/covers/shoot.sh`; the contact sheet is
`.agent/covers/today.html` (and `before-after.html` after the change). Shots are
taken from the e2e bundle with the fake phone on the run's own virtual display.
