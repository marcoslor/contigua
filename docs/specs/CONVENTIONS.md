# Conventions baseline

Every surface spec in `docs/specs/` answers each line below with one of four answers:
- **applies**, with the requirement ID that carries it;
- **n/a**, with a reason;
- **deviates**, with a reason the person approved;
- `[NEEDS CLARIFICATION]`.

A line the product claims is proved by a check whose `ok` line names the ID. These are the things a Mac or Android user expects without being told, so no feature request will mention them. That is why they live here and not in each brief.

## macOS: keys

| ID | Convention |
|---|---|
| CONV-MAC-01 | A window or surface with a search or filter field focuses it on **⌘F** and selects the text already typed. A window whose keys belong to the phone (a stream window) passes ⌘F to the phone instead. |
| CONV-MAC-02 | **⌘W** closes the key window; **⌥⌘W** closes all of the app's windows. **⌘M** minimises. **⌘Q** quits. **⌘,** opens Settings. **⌘H** hides the app. None of these is taken for anything else. |
| CONV-MAC-03 | **Esc** closes the frontmost popover, panel, sheet or menu without acting. **Return** triggers the default button. **Tab** / **⇧Tab** move focus through every control, with Full Keyboard Access on. |
| CONV-MAC-04 | Text fields support the standard editing keys: ⌘A, ⌘C/⌘X/⌘V, ⌘Z/⇧⌘Z, ⌥←/→, ⌘←/→. |
| CONV-MAC-05 | Zoom-like content (grid size, density) uses **⌘+ / ⌘− / ⌘0**, shown in the menu that owns it. |
| CONV-MAC-06 | Every keyboard shortcut is visible in a menu or in the control's help tag. A shortcut that is hidden is a bug. A disabled menu item must not eat a key that another window needs (MenuBar.swift). |
| CONV-MAC-07 | The app reuses a standard shortcut for another meaning only as a listed deviation. Today's deviation is **⌘P = Phone Mirror**: PocketDeck has nothing to print. |

## macOS: windows, panels, menus

| ID | Convention |
|---|---|
| CONV-MAC-10 | Clicking a menu-bar (status) item **toggles** its panel: click → open, click → close. Clicking outside or pressing Esc closes it, and so does opening a window from it. A **secondary click** (right-click or ⌃-click) opens the item's own menu instead — Settings… ⌘, · About PocketDeck · Quit PocketDeck ⌘Q — closing the panel first; the panel's gear opens the same menu. |
| CONV-MAC-11 | A window that represents one thing exists **once per thing**: the Deck, the Phone Mirror per phone, Settings, an app window per app per phone. Opening it again brings the existing one to the front (unminimise; switch Space if it is full screen). |
| CONV-MAC-12 | Windows remember size and position across launches. A window never opens off-screen, and never larger than the screen it opens on. |
| CONV-MAC-13 | View → Enter/Exit Full Screen (the system's own, fn‑F) exists exactly once; Window holds the system's tiling group and no app full-screen item. Menus have no empty menu and no duplicate title, and no leading, trailing or doubled separator. A menu item's checkmark follows the key window. |
| CONV-MAC-14 | Live resize keeps content correct on every frame: no stale layout, no black bands, no clipping. Resizing to the minimum size never hides a primary control. |
| CONV-MAC-15 | Closing the last window does not quit the app (a menu-bar app). Reopening from the Dock or Finder shows the Deck. |
| CONV-MAC-16 | Drag and drop, copy and paste, and Services behave as in Finder: drop targets highlight, and a refused drop says why. |

## macOS: system settings and accessibility

| ID | Convention |
|---|---|
| CONV-MAC-20 | Light and Dark appearance, an accent colour, and Increase Contrast all render legibly. |
| CONV-MAC-21 | Every control has a VoiceOver label and role. Images that carry meaning have a description. The order of focus follows the order you read it in. |
| CONV-MAC-22 | Reduce Motion replaces non-essential animation, and Reduce Transparency replaces glass with a solid fill. |
| CONV-MAC-23 | Text follows the system's text size where SwiftUI allows. Nothing important is conveyed by colour alone. |
| CONV-MAC-24 | Notifications, Focus modes and Do Not Disturb are respected. The app asks for a permission only when the person uses the feature that needs it, and says why. |
| CONV-MAC-25 | Every clickable custom control (tile, card, icon button, row) has a **hover** highlight and a **pressed** state, as native Control Center modules do. A **disabled** control is dimmed neutral: never accent-tinted, so it never reads as "on". |
| CONV-MAC-26 | **One inset and one vertical rhythm per surface.** Every section of a panel or window shares one side inset, and section gaps come from one small scale (8/12/16 pt). Helper and reason text sits with the control it explains, aligned to it, never wedged between sections. |

## Android

| ID | Convention |
|---|---|
| CONV-AND-01 | Back, Home and Recents from the Mac map to the phone's own navigation. They behave the same way under gesture and 3-button navigation. |
| CONV-AND-02 | Any phone-side UI follows the system theme. A notification that PocketDeck posts is dismissable and names what it does. |
| CONV-AND-03 | Runtime permissions are asked for in context, with a reason. A denied permission disables only its feature, and the feature says why (honest settings). |
| CONV-AND-04 | Nothing PocketDeck does changes a phone setting the person did not ask for, and every change it makes is undone when the session ends. The lock screen stays locked (product promise). |

## PocketDeck's own

| ID | Convention |
|---|---|
| CONV-PD-01 | **Phone count.** Each surface says what it shows with **0, 1 and 2+** phones, and how to reach the other phones. |
| CONV-PD-02 | **Connection states.** Each surface says what it shows while connecting, connected, and offline or reconnecting. It also says what it shows for a phone that **can't** do the feature (an Android version or OEM limit, or a missing permission): disabled with a reason, never hidden. No fallbacks for older PocketDeck builds during the alpha (AGENTS.md). |
| CONV-PD-03 | **Pending actions.** An action the phone must confirm shows the pending state, then the phone's answer. A refusal shows a pill with the phone's reason. The UI never claims what the phone has not reported. |
| CONV-PD-04 | **Live controls.** A slider or toggle follows the pointer live while dragged, sends throttled updates, and then follows the phone (the volume pattern). |
| CONV-PD-05 | **Privacy.** No message text, notification content, file name, app list or phone number in logs or crash reports. Anything sensitive is redacted. |
| CONV-PD-06 | **Performance.** Interactive surfaces meet docs/NFR.md, with frame p95 measured on the e2e rig. A change that moves a metric records before and after. |
| CONV-PD-07 | **Names.** One name per thing across the menus, panels, Deck, Shortcuts, MCP and docs. Today: Phone Mirror, Deck, Find Apps, Move Phone App to Mac (panel and Deck button: Move to Mac). |
| CONV-PD-08 | **Stateful behaviour** is one explicit state machine (AGENTS.md), and its state/event table is in the surface spec. |
| CONV-PD-09 | **Labels say what happens.** An action's name states its result in plain words ("Move to Mac", not "Continue"). Every icon or short-label button has a help tag and a VoiceOver label with the full sentence and its shortcut. An error names what to do next, never an internal code. |
