# Why an app window fades to black when the phone wakes (ISS-3)

Status, 2026-11-03: **root-caused on the real phone, not fixed.** The fade is Android's own screen-off animation, drawn on the virtual display that streams the window. The options are at the end. The cheap one, a display flag that earns its own group, was probed on the phone and none does; whether options 1 or 2 can remove it on One UI is still open.

Measured on an SM-S936B (One UI 8.5) running v131, with one app window streaming to the Mac, and on the 2026-11-01 field log from the same phone. The emulator runs of `fix/flicker` (8 boots, 2026-11-03) are compared at the end.

## What the person sees

With the phone unlocked and an app window open on the Mac:

1. **Power to lock:** the phone's screen goes dark. The Mac window doesn't flicker; it keeps streaming.
2. **Power to wake:** the Mac window fades to black, then lights up again together with the phone's screen.
3. **Sometimes the wake takes two presses:** after the first press, the phone's screen stays dark (and so does the Mac window) until a second press.

## Root cause

1. **One UI puts Contigua's virtual displays in the panel's display group (group 0).** It ignores `VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP`, which AOSP honours end to end ([display-groups.md](display-groups.md)). A display renders only while its group is awake, so a stream can't run while group 0 sleeps.
2. **So, while a window is open on a locked phone, Contigua keeps group 0 awake and blacks the panel out** through SurfaceFlinger (`DarkPanelPolicy`, `AndroidPower`). The panel looks off, but to Android the phone is awake: every power press in this state is logged `interactive=true`.
3. **A wake press is therefore a sleep press to Android.** `PowerManagerService` puts group 0 to sleep (`Going to sleep due to power_button`). Every display in the group runs its screen-off sequence, and that includes Contigua's virtual display, which has its own `DisplayPowerController`:
   - `animateScreenStateChange: target=OFF`, then **ColorFade**: the controller takes a screenshot of the display, puts a layer on top of it (`ColorFade_d<id>`, z = 1073741825, at the display's full size) and animates that layer to black;
   - the display then turns off (`VirtualDisplayAdapter: … from ON to OFF`, SurfaceFlinger power mode 0);
   - WindowManager adds a `Display-off` sleep token for it, so the app on it is paused.
4. **Contigua's power watch sees the press and hands the phone back** (`panel_yield reason=power`, 12–14 ms after the press). It wakes group 0 again, which lights the panel (with its lock screen) and the virtual display at the same moment. The sleep token goes, a `WAKE` transition runs, and the app redraws.
5. **The encoder streams whatever the virtual display composes.** So the Mac shows the screenshot fading to black (about 330 ms), then a dark interval (about 250 ms), then the app again, with the phone's screen.

A **lock press** doesn't show this. Android puts the group to sleep, and Contigua's relight wakes it again 17–27 ms later, before the screen-off animation has drawn anything (once it aborted the animation 4 ms in). Then it powers the panel off. The virtual display never goes off, so the Mac window just keeps streaming.

## Timelines (real phone, 2026-11-03)

The times are milliseconds after the press, from the phone's log. "VD" is the virtual display that streams the window.

| Event | Lock press (3 of 3) | Wake press (3 of 5) | Wake press inside the relight window (2 of 5) |
|---|---|---|---|
| Android's reading | `interactive=true` → sleep, +1 | same | same |
| Contigua sees the press | relight wake, +17 to +27 | `panel_yield`, +12 to +14 | nothing |
| Screen-off fade on the VD | none, or aborted after 4 ms | +43–99 → +376–428 (≈330 ms) | +37–46 → +365–366 |
| VD off, sleep token added | never | +396–446 | +376–389 |
| Contigua wakes the group | (already awake) | +616–671 | never |
| VD on, sleep token removed, `WAKE` transition | — | +637–702 → +640–750 | after the person's **second** press, 2.7 s and 3.9 s later |
| What the Mac shows | no change | fade ≈330 ms, dark ≈250 ms, then the picture | fade, then dark until the second press |

The 2026-11-01 field log has the same chain on one wake press:
- ColorFade on the panel and on display 73 (2560×1488, the VD) from +36 to +359 ms;
- the VD off at +397 and its sleep token at +402;
- the group awake again at +528 (`Waking up from Dozing … power_button`) and Contigua's hand-back at +605;
- the VD's sleep token removed and the `WAKE` transition at +607–608;
- the VD's compositor back on at +674. The fade's large picture change also set off Contigua's encoder backpressure twice (`dropping deltas, requesting keyframe`, 6.0 → 4.5 Mbit/s).

## The two-press wake (ISS-24)

After every lock press, Contigua's relight runs a panel-off step that takes about 2.5 s: `power: relight edge+0ms wake issued, +3ms wake returned, +2521ms panel off returned`, and in the same session 2511, 2525 and 2534 ms. A wake press that lands inside that step goes to sleep as above, fade included, but no hand-back follows. The phone's screen and the Mac window stay dark until the person presses again.

Both two-press wakes in the session came 2.0 s and 2.5 s after a lock press. That's a Contigua bug, separate from the fade: the relight must hand the panel back on a press it sees during its own panel-off step, as the idle policy does.

## Why the emulator showed something else

- AOSP honours `OWN_DISPLAY_GROUP`, so on a plain emulator a power press never touches the virtual displays. The `fix/flicker` runs used a debug-only property that puts them in group 0 instead, imitating One UI.
- The emulator's display controllers didn't run ColorFade on the virtual displays (boot 8 logged one ColorFade, for the panel). Its dark picture came from steps 3–4 alone: the sleep token pauses the app, its window leaves the display (`no touchable window … on display 5`), and the display composes nothing until the app redraws after the wake.
- The emulator's black was also a real composed picture, so `fix/flicker`'s phone-side gate failed for the same reason it would on the phone. It waited for a key frame newer than the edge, and that frame was itself black: the controller turns the virtual display on 2–4 ms after the wake (`Unblocked screen on after 2 ms`), before the app has drawn.

## Why the vendor desktop mode never fades (read on the same phone, 2026-11-03)

The person reports that a vendor desktop-mode session doesn't show the fade. With the desktop mode on a cable to a monitor, `dumpsys display` shows why:
- The desktop mode's screen is a physical external display (`local:` id, 3840×2160) carrying Samsung's own `FLAG_EXTERNAL_DEX_HOSTING`;
- it sits in **display group 2**, so the phone's lock and wake never touch it;
- Contigua's window display sits in group 0 at the same moment, **although its `DisplayInfo` carries `FLAG_OWN_DISPLAY_GROUP`**. So One UI keeps the flag and its group mapper ignores it: case 2 in display-groups.md, now confirmed.

**Samsung's group rule**, read from the phone's `services.jar`. `assignDisplayGroupLocked` is inlined into `LogicalDisplayMapper.updateLogicalDisplaysLocked` there, so this is a reading of bytecode:
- group 2 is hard-wired for the desktop (vendor desktop mode) display;
- group 4 goes to CarLife displays when the build's `CARLIFE_DISPLAY_GROUP` feature is on (device flag `1 << 31`);
- the displays of a **virtual device** get a group per device (`mDeviceDisplayGroupIds`, keyed by the device id);
- the AOSP own-group path (`FLAG_OWN_DISPLAY_GROUP` or a group name) is still there, but an earlier branch overrides it for Contigua's display. That branch isn't decoded.

**Samsung's extra virtual display flags**, read from `framework.jar` on the phone: `HIDDEN_SPACE` 1<<17, `REMOTE_APP` 1<<19, `CARLIFE` 1<<20, `CARLIFE_ROTATION` 1<<22, `SPEG_DISPLAY` 1<<24, `VIEW_COVER` 1<<30, `BACKGROUND_DISPLAY` 1<<31. `REMOTE_APP` is likely what Samsung's own phone-app streaming to a PC uses, which is Contigua's own case.

## Can it go away?

0. **A group probe on the real phone: done, 2026-11-03. No flag earns a group of its own.**
   - The debug-only `app.contigua.debug.GroupProbe` (branch `spike/group-probe`) created a 64×64 virtual display per variant through the same config path as the stream, read its group, and released it. No probe display was left behind.
   - The variants: today's flags; today's flags without `OWN_DISPLAY_GROUP`; each Samsung flag (`REMOTE_APP`, `BACKGROUND_DISPLAY`, `CARLIFE`, `SPEG_DISPLAY`, `HIDDEN_SPACE`, `VIEW_COVER`) with and without it; and `DEVICE_DISPLAY_GROUP`.
   - **Every display that was created sat in group 0.** The display info kept `OWN_DISPLAY_GROUP` where it was asked for, which confirms that the mapper ignores it.
   - `CARLIFE` was refused with a `SecurityException`, with and without `OWN_DISPLAY_GROUP`. The probe ran with root privileges, so the refusal is not a shell-permission gap. A run as the system user stopped earlier, because the probe presents itself as the shell package. So whether a CarLife display would get its own group (group 4) is still open. It could only ever help a rooted phone.
   - `DEVICE_DISPLAY_GROUP` without a virtual device behaves like the base flags.
   - So option 0 is closed. The options below remain.
1. **Give the virtual displays a group of their own through a virtual device.**
   - On the SM-S936B the shell user holds `CREATE_VIRTUAL_DEVICE` (granted by role).
   - On AOSP 16, displays created by a virtual device with `DEVICE_DISPLAY_GROUP` join that device's own group, not group 0 (display-groups.md, the Android 16 note).
   - If One UI honours that group, none of the above happens: no dark-panel trick, a locked phone is really asleep, a wake press is a real wake, and there's no fade on the window.
   - Unknowns:
     - One UI may ignore this group as it ignores `OWN_DISPLAY_GROUP`;
     - a virtual device needs a companion-device association, which is a visible, lasting change on the phone and needs the person's OK;
     - a virtual device has its own policies for activities, input, clipboard and audio, which touch much of the stream path.
   - **Probe on the real phone: done, 2026-11-04 (`spike/vd-probe`, `app.contigua.debug.DeviceGroupProbe`). It works.**
     - The shell user already held `CREATE_VIRTUAL_DEVICE` by role and owned an app-streaming companion association, so the probe reused it and changed nothing on the phone. It ran as the shell user (`su 2000`), and the device was created through the raw `virtualdevice` binder.
     - Groups, one 64×64 display per variant:
       - a plain display with today's flags (`0x7dcb`), the control: group **0**;
       - a device display with today's flags: group **0**;
       - today's flags plus `DEVICE_DISPLAY_GROUP` (`0xfdcb`): still group **0**. `OWN_DISPLAY_GROUP` sends it back to the panel's group;
       - today's flags **without** `OWN_DISPLAY_GROUP`, plus `DEVICE_DISPLAY_GROUP` (`0xf5cb`): group **5**;
       - `OWN_CONTENT_ONLY | DEVICE_DISPLAY_GROUP` only: group **6**.
     - The `0xf5cb` display kept every other flag Contigua needs (`TRUSTED`, `ALWAYS_UNLOCKED`, `TOUCH_FEEDBACK_DISABLED`, `OWN_FOCUS`; info flags `0x4e88`).
     - **Through a lock and a wake it stayed ON.** A 60 s hold of the `0xf5cb` display, in its own group, read `state=ON` the whole time. Meanwhile the panel went off and on three times (the phone's `screen_toggled` events at 13:47:44, :49 and :55 match the probe's lines), and a real power-button sleep followed (`power_sleep_requested` at 13:48:00). A display made during that sleep came up ON at once.
     - Cleanup: `Number of active virtual devices: 0` and no probe display left, after every run.
   - **So option 1 can remove the fade at its root.** The window's display leaves the panel's group, the phone can really sleep, a wake press is a real wake, and the dark-panel hold (and with it ISS-24's two-press wake) isn't needed.
   - **Open before a move:**
     - launching apps on a device display (in October, on AOSP, `am start --display` was refused there and `IVirtualDevice.launchPendingIntent` worked);
     - input (inject as today, or the device's own virtual touchscreen and keyboard);
     - the device's IME, clipboard, audio and recents policies. A per-device clipboard would break paste (ISS-1);
     - who owns the association: reuse the shell's, or create Contigua's own, which is a lasting change that needs the person's OK;
     - and how this behaves on a phone where the service runs as the shell user, not with root privileges.

   - **Window spike on the phone: done, 2026-11-04 (`spike/vd-window`, `app.contigua.debug.VdWindowSpike`).** One virtual device (association 25, run as the shell user), one 1080×1920 display with `0xf5cb` in a group of its own (9), driven step by step through a FIFO.
     - **Launch:** the device's own `launchPendingIntent` started Samsung Clock (result 0). On One UI a plain `am start --display <id>` onto the device display also worked, as the shell user and with root privileges (the October AOSP run refused it), so today's launcher path can stay.
     - **Frames and input:** about 60 frames a second while drawing; injected taps and key events with the display id reached the apps (Calculator: `42`, then `+ 1 =` → `43`; a text field took `pdvdw42`). The activity listener reported each top app on the display.
     - **IME:** with the default policy, a tap in a text field opened the phone's own soft keyboard **inside the window**. `setDisplayImePolicy(hide)` stopped that, and typing still arrived. The move needs that policy.
     - **Lock and wake, the question:** the person locked the phone at 16:05:12 and woke it at 16:08:51. The window drew all along (the cursor's two frames a second), its brightness never changed (luma 20 throughout), and the display reported no pause or stop. **No fade, and the window stays live while the phone is locked.**
     - **The phone's own keyboard:** while the window was up, the phone's own apps still showed their keyboard 0.5 s after asking. Injected typing moved the top focus to the device display (`mTopFocusedDisplayId=23`), the same mechanism ISS-35 fixed for today's displays with `STEAL_TOP_FOCUS_DISABLED` (WIN-51), and that flag belongs on the device display too.
     - **Clipboard:** Ctrl+V into the window typed a plain `v`: the device's own clipboard was empty with the default policy. The `POLICY_TYPE_CLIPBOARD = DEVICE_POLICY_CUSTOM` run (share the phone's clipboard) wasn't reached and is the first check of the move.
     - **Secure windows** (Samsung Internet marks its window secure) draw black, as on today's displays.
     - Cleanup: `Number of active virtual devices: 0`, no spike display, files removed.
   - **Still open for the move:** the shared clipboard run, audio (where an app on the device display plays, and the per-device capture October found), recents, the association owner (reuse the shell's, or Contigua's own with the person's OK), and phones where the service runs as the shell user.

     **Next:** the move itself, as a planned epic: requirements and a design for the device-display path first (launch, IME hide, `STEAL_TOP_FOCUS_DISABLED`, shared clipboard, the dark-panel hold retired), then the build.
2. **Hide it in the stream.**
   - Hold the last good picture from the press until the app has redrawn after the hand-back.
   - The press is known 12–14 ms after it happens, and the fade's first frame comes 37–99 ms after it, so the trigger is in time.
   - The release is the hard part. "A key frame newer than the edge" isn't enough (see the emulator section). It must be the display back on, its sleep token gone, and a picture whose brightness is back near the held one. The phone has no decoded pictures, so the brightness check belongs on the Mac.
   - The person would see the window stand still for about 0.7 s instead of fading.
3. **Live with it.**
   - It happens only on a wake press while a window is open, and it lasts about 0.6 s.
   - The phone's own screen does the same fade at the same moment, which is why it reads as "together with the phone's screen".

## Evidence

The raw logs are kept outside the repository, because they hold notification and app data. The lines quoted here are the system's and Contigua's own log lines, with display ids and times only.
