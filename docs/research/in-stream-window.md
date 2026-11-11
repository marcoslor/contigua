# An app's own "New window" inside a stream

Research for WIN-44…WIN-49 (ISS-4). What Android 16 does when an app starts a
task while one of its apps is streamed, and the two binder calls that make the
second window work. Measured on the API 36 emulator rig with Chrome 133 and
Settings; the raw boots are in `.agent/instream/spike-in-stream.md`.

## The trigger: the task is born on the phone, not on the stream

Chrome's ⋮ ▸ New window starts `ChromeTabbedActivity` with
`FLAG_ACTIVITY_LAUNCH_ADJACENT` (`flg=0x18001000`) and
`LAUNCH_SINGLE_INSTANCE_PER_TASK`. Android honours the adjacent flag by putting
the new task on the **phone's own display (0) in a split-screen container**,
next to the app the person was in — never on the virtual display the stream
shows:

- the new task is a child of the display's split root (`rootTaskId=3`), with
  `mode=multi-window` and the bottom half's bounds; `launchedFromPackage` is
  Chrome's own uid;
- the streamed display keeps its task and keeps drawing; the per-display
  `WindowObserver` never looks at display 0, so the existing `window.title` path
  cannot see it;
- the split reparent lands **0.11 s** after Chrome's `START`, and a task-list
  poll sees the id at **0.21–0.52 s**.

So a trigger based on "the top task of a streamed display changed" is false on
this build. The signal that does exist is the task stack's own callback:
`ITaskStackListener.onTaskCreated` fires **0.066–0.088 s** after the tap, before
the first task-list read. Its first callback may carry a null component; a
second one for the same id carries the package, so the listener coalesces by id.
`onTaskDisplayChanged` and `onTaskRemoved` come from the same interface.

Registration goes through `IActivityTaskManager.registerTaskStackListener` and
needs `MANAGE_ACTIVITY_TASKS`, which the shell UID holds through the existing
Shizuku service. The listener can be registered from the server process without
an app-side permission prompt; if the phone refuses it, there is no report path
and every other window operation keeps working.

## Why `moveRootTaskToDisplay` cannot adopt it

The task the app started is a **child of the split root**, not a root task.
`IActivityTaskManager.moveRootTaskToDisplay(taskId, displayId)` (the call behind
`cmd activity display move-stack`) only moves root tasks and answers
`IllegalArgumentException: moveRootTaskToTaskDisplayArea: Unknown rootTaskId=…`
for the child. The split root itself is movable, but it also holds Contigua's
own window, so moving it is not acceptable. A root task moves with the same call
(measured on a fullscreen task), which is why the handoff path keeps it.

## The route that works: Recents with a launch display

`IActivityTaskManager.startActivityFromRecents(taskId, options)` with
`ActivityOptions.makeBasic().setLaunchDisplayId(target)` and the hidden
`setLaunchWindowingMode(FULLSCREEN)` reparents the split child onto the target
display as a fullscreen root task. It needs `START_TASKS_FROM_RECENTS`, also
held by the shell UID. The call returns `START_TASK_TO_FRONT` (`result=2`) and
the task list then shows the same id at depth 1, `rootTaskId=null`,
`mode=fullscreen`, `state=RESUMED` on the new display. It worked on the first
try in two separate boots and twice inside one.

The phone's split containers remain in the task list as empty roots, but the
phone's screen is Contigua fullscreen again, and both streams keep drawing.

## The first window is untouched

The streamed display's task is never part of the move: its stream keeps its
encoder, its display and its picture. In the measured boots both streams drew
across the move; Back in the adopted window reached only its display. Chrome's
new-tab page consumed the first Back, so adoption must not promise that one
press removes the task.

## What closes a stream, and with which reason

A real exit removes the task (`onTaskRemoved`) and does not recreate it. The
person opening the streamed app from the phone's launcher is different: the
**same task id** comes to display 0 (`onTaskDisplayChanged task=… display=0`,
no `onTaskCreated`), the streamed display's task list becomes empty, and the
display loses its stream. Today the phone called that `app_exited`; with the
listener it is `moved_to_phone`, and the Mac closes the window quietly. The
existing display-empty poll stays as the real-exit fallback.

## Chrome's own five-window cap

Chrome's overflow menu carries "New window" at its own window count 1–4 and
**omits it at 5** ("Manage windows (5)" stays). A fresh `pm clear
com.android.chrome` returns it to one window and the row comes back; the menu
row's "Manage windows (N)" itself appears only from two windows up. This is the
app's own cap, independent of the Mac's window cap, and it means a test must
clear Chrome's data before the trigger (allowed on the emulator only) and must
not promise a "New window" row at every count.
