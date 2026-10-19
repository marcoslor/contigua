#!/usr/bin/env python3
"""e2e-cost — what one check-e2e.sh run cost the Mac.

    python3 -I scripts/e2e-cost.py [--profile NAME] [--summary FILE] -- <command...>

Runs the command (normally `scripts/check-e2e.sh <check>`) and samples the
process table every 0.5 s while it runs. Each process's CPU time is the last
value `ps` reported for it, so a process that lives less than one sample, or
the CPU it burns after its last sample, is missed by the sampling. The run's
own process tree is exact instead: its total is the command's rusage with its
reaped descendants (wait4; the meter's own `ps` calls are not in it), so
short-lived helpers (python, grep, screencapture) count in full and land in
cpu_helpers, which is that total minus the sampled app/fake/build CPU.

At the end it prints one line (and writes it to --summary):

    DAEMONS name=… name=… …   (the five busiest system processes)
    COST wall=… launches=N builds=N cpu_app=… cpu_fake=… cpu_ws=… cpu_build=…
         cpu_helpers=… cpu_run=… cpu_daemons=… machine_busy=… peak_load=…

  launches     — distinct PocketDeck processes of the profile's e2e bundle
  builds       — distinct swift-build / swift-test / swiftc invocations
  cpu_app      — the e2e app and its Dock shims
  cpu_fake     — fakephone and its ffmpeg encoders
  cpu_ws       — WindowServer's CPU over the run (its counter's delta)
  cpu_build    — the compilers and linkers the builds ran
  cpu_helpers  — everything else the run's process tree used (python checks,
                 screencapture, `log show`, cgevent/quiet-watch/pd-load, …)
  cpu_run      — the sum of the five above
  cpu_daemons  — macOS's own processes (under /System, /usr/libexec, /usr/sbin,
                 /sbin, /Library/Apple; not WindowServer) over the run: what the
                 Mac did in reply to the run's launches, windows and app
                 registrations (Dock, Control Center, duetexpertd, …), and
                 whatever it did anyway (not apps in /System/Applications or
                 virtual machines). Sampled, like cpu_app.
  machine_busy — all CPUs' non-idle time over the run (host_statistics),
                 which includes whatever else the Mac was doing
  peak_load    — the highest 1-minute load average seen
"""

import ctypes
import os
import re
import signal
import subprocess
import sys
import time

INTERVAL = 0.5


def machine_ticks():
    """Cumulative (busy, total) CPU ticks of all CPUs (HOST_CPU_LOAD_INFO)."""
    libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
    libc.mach_host_self.restype = ctypes.c_uint
    ticks = (ctypes.c_uint * 4)()  # user, system, idle, nice
    count = ctypes.c_uint(4)
    libc.host_statistics(libc.mach_host_self(), 3, ticks, ctypes.byref(count))
    return ticks[0] + ticks[1] + ticks[3], sum(ticks)


def cpu_seconds(text):
    """ps's TIME column: [[DD-]HH:]MM:SS.ss."""
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    parts = [float(p) for p in text.split(":")]
    seconds = 0.0
    for part in parts:
        seconds = seconds * 60 + part
    return seconds + days * 86400


def snapshot():
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,time=,command="],
                         capture_output=True, text=True).stdout
    rows = {}
    for line in out.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)", line)
        if m:
            rows[int(m.group(1))] = (int(m.group(2)), cpu_seconds(m.group(3)), m.group(4))
    return rows


BUILD_TOOLS = ("swift-frontend", "swift-driver", "swift-build", "swift-test", "swiftc", "/ld ",
               "ld64", "clang", "swift-autolink-extract", "xctest", "PackageTests")


def category(command, profile):
    exe = command.split(" --", 1)[0]
    if "/build/e2e/PocketDeck.app/" in exe and ("--profile " + profile) in command:
        return "app"
    if "PocketDeckShim" in command or exe.endswith("/Contents/MacOS/PocketDeck"):
        return "app"
    if "fakephone.py" in command:
        return "fake"
    if "ffmpeg" in exe and "lavfi" in command:
        return "fake"
    if any(tool in command for tool in BUILD_TOOLS):
        return "build"
    return "helpers"


SYSTEM_DIRS = ("/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/")
WINDOWSERVER = "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
# Counted elsewhere (WindowServer), or the person's and other work's, not the
# Mac reacting to the run: apps in /System/Applications and virtual machines.
NOT_DAEMONS = (WINDOWSERVER, "/System/Applications/",
               "/System/Library/Frameworks/Virtualization.framework/")


def daemon_name(command):
    """The system process's short name, or None when it is not one."""
    if not command.startswith(SYSTEM_DIRS) or command.startswith(NOT_DAEMONS):
        return None
    m = re.search(r"/([^/]+)\.(?:app|appex|xpc)/Contents/MacOS/", command)
    if m:
        return m.group(1).replace(" ", "_")
    return os.path.basename(command.split(" ", 1)[0])


def is_launch(command, profile):
    exe = command.split(" --", 1)[0]
    return "/build/e2e/PocketDeck.app/Contents/MacOS/PocketDeck" in exe and ("--profile " + profile) in command


def is_build(command):
    exe = command.split(" ", 1)[0]
    base = os.path.basename(exe)
    if base in ("swift-build", "swift-test", "swiftc"):
        return True
    # `swift build` / `swift test` run as the `swift` driver with a subcommand.
    return base == "swift" and re.search(r"\s(build|test)\b", command) is not None


def main():
    args = sys.argv[1:]
    profile, summary = os.environ.get("PD_E2E_PROFILE", "e2e"), None
    while args and args[0] != "--":
        if args[0] == "--profile":
            profile = args[1]; args = args[2:]
        elif args[0] == "--summary":
            summary = args[1]; args = args[2:]
        else:
            sys.exit("usage: e2e-cost.py [--profile NAME] [--summary FILE] -- <command...>")
    command = args[1:]
    if not command:
        sys.exit("usage: e2e-cost.py [--profile NAME] [--summary FILE] -- <command...>")

    before = snapshot()
    ws_pid = next((pid for pid, row in before.items() if row[2].startswith(WINDOWSERVER)), None)
    ws_start = before[ws_pid][1] if ws_pid else 0.0
    busy0, total0 = machine_ticks()
    start = time.monotonic()

    child = subprocess.Popen(command)
    # The run's processes: the child and everything whose parent was one at first
    # sight, plus the e2e app and fakephone by name (LaunchServices starts some
    # launches; a killed parent re-parents its children to launchd).
    ours = {child.pid}
    seen = {}  # pid -> (category, last cpu seconds, start cpu, in the process tree)
    daemons = {}  # pid -> (name, last cpu seconds, start cpu)
    launches, builds = set(), set()
    peak = os.getloadavg()[0]
    ws_now = ws_start

    def sample():
        nonlocal peak, ws_now
        rows = snapshot()
        for pid, (ppid, cpu, cmd) in rows.items():
            if pid in seen:
                cat, _, base, tree = seen[pid]
                seen[pid] = (cat, cpu, base, tree)
                continue
            if pid in daemons:
                name, _, base = daemons[pid]
                daemons[pid] = (name, cpu, base)
                continue
            cat = category(cmd, profile)
            tree = ppid in ours or pid in ours
            if not tree and not (cat in ("app", "fake") and pid not in before):
                name = daemon_name(cmd)
                if name:
                    daemons[pid] = (name, cpu, before[pid][1] if pid in before else 0.0)
                continue
            if tree:
                ours.add(pid)
            # A process alive before the run only counts its CPU from here on.
            base = before[pid][1] if pid in before else 0.0
            seen[pid] = (cat, cpu, base, tree)
            if is_launch(cmd, profile):
                launches.add(pid)
            if is_build(cmd):
                builds.add(pid)
        if ws_pid in rows:
            ws_now = rows[ws_pid][1]
        peak = max(peak, os.getloadavg()[0])

    signal.signal(signal.SIGINT, lambda *_: child.send_signal(signal.SIGINT))
    # wait4 on the child alone: its rusage covers the run's reaped tree and not
    # the `ps` calls this meter makes.
    while True:
        sample()
        pid, status, usage = os.wait4(child.pid, os.WNOHANG)
        if pid == child.pid:
            break
        time.sleep(INTERVAL)
    returncode = os.waitstatus_to_exitcode(status)

    wall = time.monotonic() - start
    busy1, _ = machine_ticks()
    tree_cpu = usage.ru_utime + usage.ru_stime
    totals = {"app": 0.0, "fake": 0.0, "build": 0.0, "helpers": 0.0}
    sampled_in_tree, outside = 0.0, 0.0
    for cat, cpu, base, tree in seen.values():
        used = max(0.0, cpu - base)
        if cat == "helpers":
            continue
        totals[cat] += used
        if tree:
            sampled_in_tree += used
        else:
            outside += used
    totals["helpers"] = max(0.0, tree_cpu - sampled_in_tree)
    ws = max(0.0, ws_now - ws_start)
    run = tree_cpu + outside + ws
    by_name = {}
    for name, cpu, base in daemons.values():
        by_name[name] = by_name.get(name, 0.0) + max(0.0, cpu - base)
    top = sorted(by_name.items(), key=lambda item: -item[1])[:5]
    hz = os.sysconf("SC_CLK_TCK") or 100
    lines = [
        "DAEMONS " + " ".join("%s=%.1f" % item for item in top),
        "COST wall=%.0fs launches=%d builds=%d cpu_app=%.1f cpu_fake=%.1f cpu_ws=%.1f "
        "cpu_build=%.1f cpu_helpers=%.1f cpu_run=%.1f cpu_daemons=%.1f machine_busy=%.1f peak_load=%.1f"
        % (wall, len(launches), len(builds), totals["app"], totals["fake"], ws,
           totals["build"], totals["helpers"], run, sum(by_name.values()), (busy1 - busy0) / hz, peak),
    ]
    print("\n".join(lines), flush=True)
    if summary:
        with open(summary, "a") as fp:
            fp.write("\n".join(lines) + "\n")
    sys.exit(returncode)


if __name__ == "__main__":
    main()
