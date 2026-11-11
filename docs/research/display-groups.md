# Why a virtual display lands in the panel's display group (displayGroupId 0)

Investigation for the P0 "dark panel" task, against AOSP tags
`android-14.0.0_r1`, `android-15.0.0_r1`, `android-16.0.0_r1`
(links are `cs.android.com`-style googlesource permalinks; the line numbers were
read from the tagged `?format=TEXT` sources).

Short version: **AOSP honours `VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP` end to
end.** Nothing in Android 14–16 strips the flag for a shell-UID caller, and no
creation path drops it. A VD that reports `displayGroupId 0` while holding the
flag is a *vendor divergence* — on the SM-S936B a One UI framework fork. The
creation-time probe added by this task (see below) says which layer diverges on
the device.

## The chain, flag in → group out

### 1. `DisplayManager.createVirtualDisplay` (client side)

The classic 6-argument call is a thin wrapper: it builds a
`VirtualDisplayConfig` and forwards it, so **both creation paths carry the flag**.
`DisplayManagerGlobal.createVirtualDisplay` only forwards the config to
`IDisplayManager`.

- 16: [`DisplayManager.createVirtualDisplay(String,int,int,int,Surface,int,Callback,Handler)`](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/hardware/display/DisplayManager.java#1274)
  → `builder.setFlags(flags)` → `createVirtualDisplay(config, …)`.
- 16: [`DisplayManagerGlobal.createVirtualDisplay`](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/hardware/display/DisplayManagerGlobal.java#886).
- `VirtualDisplayConfig.Builder.setFlags` is a plain field assignment
  ([16](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/hardware/display/VirtualDisplayConfig.java#498)):
  no masking, no validation.

### 2. `DisplayManagerService.createVirtualDisplayInternal` (system_server)

The only flag rewriting around `OWN_DISPLAY_GROUP`:

```java
// 16, lines 1861-1864 (14: 1430, 15: 1580)
if ((flags & VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR) != 0
        && (flags & VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP) != 0) {
    Slog.d(TAG, "Auto mirror displays must be in the default display group, ...");
    flags &= ~VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP;
}
```

So the flag is dropped only for **mirror** displays. Contigua sets
`OWN_CONTENT_ONLY` (which suppresses the automatic `AUTO_MIRROR` that
`PUBLIC` would otherwise add — 16:1869ff / 14:1420ff), so this rule never fires
for us.

Permission rules (callers other than `SYSTEM_UID`):

- `OWN_DISPLAY_GROUP` → `ADD_TRUSTED_DISPLAY`, else `SecurityException`
  ([16:1947](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/display/DisplayManagerService.java#1947),
  [14:1491](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-14.0.0_r1/services/core/java/com/android/server/display/DisplayManagerService.java#1491)).
  Android 14 also exempts callers that pass a `virtualDevice`.
- `TRUSTED` → `ADD_TRUSTED_DISPLAY` ([16:1928/14:1482](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/display/DisplayManagerService.java#1928)).
- `ALWAYS_UNLOCKED` → `ADD_ALWAYS_UNLOCKED_DISPLAY` **and** is *ignored* unless the
  display also has `OWN_DISPLAY_GROUP` or `DEVICE_DISPLAY_GROUP`
  ([16:1954](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/display/DisplayManagerService.java#1954)).

The shell UID (2000, Shizuku user service) holds both permissions: the same call
already creates a `TRUSTED | ALWAYS_UNLOCKED` VD on the device, which would throw
`SecurityException` otherwise. So neither permission nor the flag-stripping rule
explains the observed behaviour.

(The Android 16 `DEVICE_DISPLAY_GROUP` auto-adding rule at
[16:1869](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/display/DisplayManagerService.java#1869)
only applies to displays owned by a `VirtualDevice`, which we do not use.)

### 3. `VirtualDisplayAdapter` → `DisplayDeviceInfo`

```java
// 16, lines 619-621 (14: 483, 15: 486)
if ((mFlags & VIRTUAL_DISPLAY_FLAG_OWN_DISPLAY_GROUP) != 0) {
    mInfo.flags |= DisplayDeviceInfo.FLAG_OWN_DISPLAY_GROUP;
}
```

Also relevant: a display is *not* `FLAG_NEVER_BLANK` when it is public and not a
mirror (`isNeverBlank`, [16:325](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/display/VirtualDisplayAdapter.java#325)),
which is why the VD's power state follows its display group and goes `OFF` when
the panel's group sleeps.

### 4. `LogicalDisplay` → `DisplayInfo`

`DisplayDeviceInfo.FLAG_OWN_DISPLAY_GROUP` becomes
`DisplayInfo.FLAG_OWN_DISPLAY_GROUP` (`Display.FLAG_OWN_DISPLAY_GROUP = 1 << 8`),
[LogicalDisplay.java:474](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/display/LogicalDisplay.java#474).

### 5. `LogicalDisplayMapper.assignDisplayGroupLocked` → the group id

```java
// 16, lines 1076-1084
final boolean needsOwnDisplayGroup =
        (displayDeviceInfo.flags & DisplayDeviceInfo.FLAG_OWN_DISPLAY_GROUP) != 0
                || !TextUtils.isEmpty(groupName);
...
groupId = assignDisplayGroupIdLocked(needsOwnDisplayGroup, groupName, …);

// 16, lines 1310-1321
private int assignDisplayGroupIdLocked(boolean isOwnDisplayGroup, …) {
    …
    if (!isOwnDisplayGroup) return Display.DEFAULT_DISPLAY_GROUP;
    Integer displayGroupId = mDisplayGroupIdsByName.get(displayGroupName);
    if (displayGroupId == null) {
        displayGroupId = Integer.valueOf(mNextNonDefaultGroupId++);   // first free id ≥ 1
        …
    }
    return displayGroupId;
}
```

`Display.DEFAULT_DISPLAY_GROUP = 0`, `INVALID_DISPLAY_GROUP = -1`
([Display.java:164](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/view/Display.java#164)),
so an own-group VD gets the next free id `≥ 1`. `dumpsys display` prints this as
`displayGroupId=` on the VD's `DisplayInfo`.

### 6. Why the keep-awake lights the panel

```java
// PowerManagerService.java:6187 (16)
public void wakeUpWithDisplayId(long eventTime, int reason, String details,
        String opPackageName, int displayId) {
    …
    int displayGroupId = getDisplayGroupId(displayId);
    synchronized (mLock) {
        …
        wakePowerGroupLocked(mPowerGroups.get(displayGroupId), eventTime, reason,
                details, uid, opPackageName, uid);
    }
}
```

The wake names the **power group of the display's display group**. If the VD is
in group 0, that group is the panel's group, and waking it is what makes a locked
phone light its lock screen. If the VD has its own group, only that group wakes
and the panel (group 0) stays off — the intended behaviour, and what the
emulator (AOSP) shows.

`userActivity(displayId, …)` likewise addresses the display's own group; it does
not change device wakefulness.

## Conclusion / discriminating probe

AOSP 14, 15 and 16 are identical in every step above, so no flag, permission or
creation-path change can fix the SM-S936B from the AOSP side. The vendor fork
either

1. **drops the flag or the `DisplayDeviceInfo` bit** (vendor
   `DisplayManagerService`/`VirtualDisplayAdapter` change), or
2. **ignores it in the mapper** (vendor `LogicalDisplayMapper` change).

The probe added in `server/DisplayProbe.kt` logs both facts at VD creation:

```
stream 1 vd=57 requested flags=0x... path=VirtualDisplayConfig
stream 1 vd=57 info flags=0x140 (OWN_DISPLAY_GROUP|ALWAYS_UNLOCKED) group=0 state=ON
```

- `FLAG_OWN_DISPLAY_GROUP` (1<<8) missing from `info flags` → case 1.
- flag present but `group=0` → case 2.

Either way the fix on such builds is the panel-dark fallback: keep the same
wake (the group's compositor must be on for the VD's surface to be produced) and
then power the *physical* panel off through SurfaceFlinger, restoring it when the
last stream goes away.

## Panel power-off technique (what the fallback uses)

- `android.view.SurfaceControl.setDisplayPowerMode(IBinder token, int mode)` with
  `POWER_MODE_OFF = 0` / `POWER_MODE_NORMAL = 2`
  ([SurfaceControl.java:2074](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/view/SurfaceControl.java#2074)).
  This is the same lever the platform's own display power controller uses; a
  later platform state change (user presses power, wakes the phone) re-applies
  the normal mode by itself.
- The physical display *token* is not public: on Android 14+
  `SurfaceControl.getPhysicalDisplayToken` is gone. It lives in
  `com.android.server.display.DisplayControl`, a `services.jar` class with a
  JNI implementation in `libandroid_servers.so`:
  [`DisplayControl.getPhysicalDisplayIds()` / `getPhysicalDisplayToken(long)`](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/display/DisplayControl.java#103).
  Loading it from a shell-UID process follows the long-standing
  screen-mirroring-client recipe: build a class loader over `SYSTEMSERVERCLASSPATH`
  with `com.android.internal.os.ClassLoaderFactory.createClassLoader`
  ([ClassLoaderFactory.java:128](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/com/android/internal/os/ClassLoaderFactory.java#128)),
  load `DisplayControl`, then `Runtime.loadLibrary0(DisplayControl.class, "android_servers")`
  so the JNI methods bind.
- Restoring the phone to its locked-off state uses
  `IPowerManager.goToSleep(long, int, int)` with
  `GO_TO_SLEEP_REASON_APPLICATION = 0`
  ([PowerManager.java:442](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/os/PowerManager.java#442),
  [IPowerManager.aidl:58](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/core/java/android/os/IPowerManager.aidl#58)).
  Android 16 also offers `goToSleepWithDisplayId(displayId, …)`, which sleeps only
  that display's group; the 3-arg form sleeps the default group, which is the
  group that must end up asleep on the affected builds.

## What could not be determined without the device

The SM-S936B is offline; the vendor framework itself cannot be read (odex/vdex),
so which of the two divergences is real is decided by the probe output on the
device, not by reading source. Everything else above was verified in AOSP source
and is exercised on an AOSP emulator by the K3 checks.

## Why not "just keep the group in DOZE"

The alternative considered for the panel-group case was to leave the group in
DOZE (AOD) instead of a full wake. AOSP makes that impractical as a *replacement*
for the panel-off fallback:

- `PowerGroup.dozeLocked` only runs when the group is already interactive
  (`!isInteractive(mWakefulness)` returns false) and after its last wake, so
  doze cannot be entered from a phone that is asleep — the group has to be woken
  first, which is the lock-screen flash the fallback removes
  ([PowerGroup.java:315](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/power/PowerGroup.java#315)).
- The same holds for a nap (`PowerGroup.dreamLocked`,
  [PowerGroup.java:298](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/power/PowerGroup.java#298)),
  which also targets the default display group only
  ([PowerManagerService.napInternal:2143](https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-16.0.0_r1/services/core/java/com/android/server/power/PowerManagerService.java#2143)).
- Does a VD in a DOZE group keep rendering and accepting input? An earlier QA run
  saw a VD render while the panel was in DOZE (AOD), so it may be enough — but it
  needs AOD enabled on the phone and the doze/AOD surface is SystemUI's, not ours.
  The panel-off fallback works without depending on the AOD setting, and the
  device check (`tools/device-checks/dark-panel.sh`) accepts either `Off` or
  `DOZE` panel state, so a future experiment can still replace the fallback if it
  proves better.
