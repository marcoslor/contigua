# handoff — Move Phone App to Mac (docs/ROADMAP.md #9)

One command, three surfaces: the menu bar menu, the Deck's app menu and ⌘⇧C
while PocketDeck is active (`ConnectionController.continueOnMac`). It opens a
new Mac window for the app in the **foreground on the phone's own screen**
(display 0) and moves the task there — same screen, same scroll — while the
phone's screen returns to its home screen. Excluded: our own app, the
launcher/home, SystemUI (and the keyguard it draws) — those answer
`nothing_to_continue` and the Mac shows "Nothing to move. Your phone is showing its home
screen or PocketDeck."

## The phone side

Protocol: `task.continue` (docs/PROTOCOL.md) opens the stream's virtual display
like `window.open`, then moves the system's top task onto it.

- **Listing** `IActivityTaskManager.getTasks(maxNum, false, false, -1)` at shell
  UID: most recent first, every display (the 4th parameter filters by display;
  `-1` covers all; the utility shell holds REAL_GET_TASKS, so the list is full).
- **Picking** is the pure `ForegroundTaskPicker`: the newest task on display 0
  that is not ours, not home (`isHomeTask` **or** the default CATEGORY_HOME
  handler resolved by package — the flag is not reliably set on API 36), not
  SystemUI, not package-less.
- **Moving** `IActivityTaskManager.moveRootTaskToDisplay(taskId, displayId)`
  (MANAGE_ACTIVITY_TASKS, granted to shell) — the service method
  `cmd activity display move-stack <rootTaskId> <displayId>` runs into; the
  reflection path needs no shell-out. The service returns **void and silently
  ignores unknown ids**, so the move is *verified by re-reading* the task list:
  no landing → report fresh. A successful move presses HOME on display 0 so
  the phone's screen shows its launcher again.
- **Fallback** (the move was refused or unverified): relaunch the same package
  on the display (`launchOn`, `started:"fresh"`; such a launch often *reuses*
  the task via `setLaunchDisplayId`, but state is not guaranteed): the window
  shows "Opened fresh: the app couldn't be moved".

## The Mac side

`HandoffWindowController` is its own window kind (not dockable — it stands for
"whatever was in front", not one app): it sends `task.continue` on open, adopts
the app name via `window.title`, and re-opens the *same package* after a
reconnect (its display and task are gone; re-moving whatever is foreground
**then** would be wrong). `nothing_to_continue` removes the never-opened
window and shows the transient notice.

## Emulator verification (API 36, tools/emulator rig, port 5592)

Settings foreground → `task.continue` → `window.opened` `started:"moved"`, the
task re-listed on the VD after the move, display 0 back on the launcher;
launcher → `nothing_to_continue` (probe: `tools/device-checks/handoff-probe.py`).
On real hardware still to check: Samsung One UI's launcher and task-list gaps.

