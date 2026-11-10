#!/usr/bin/env python3
"""losslab Part B: the fake phone in a container, shaped by netem, measured.

One condition per container. The container's kernel TCP is the sender, so loss
and delay hit a real TCP (a userspace stall never makes TCP time out). The
Mac's own built app connects to the published port with --debug-frame-log, so
every video frame's arrival time is on disk.

    python3 tools/netem/losslab.py <condition> [--runs N]

Run it through ~/dev/pocketdeck/.agent/heavy.sh: it starts a container.
Data: /tmp/pd-losslab-<condition>/run<N>/ (frames.tsv, audio.json, ss.txt,
timeline.json, events.jsonl, app.log, phone.log). Nothing personal is read.
"""

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import threading
import time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
APP = os.path.join(ROOT, "macos", "build", "e2e", "PocketDeck.app", "Contents", "MacOS", "PocketDeck")
FAKEPHONE_DIR = os.path.join(ROOT, "tools", "fakephone")
PORT = 47691
PROFILE = "losslab"
IMAGE = "pd-losslab-phone:local"
CONTAINER = "pd-losslab-phone"
RUN_SECONDS = 30.0
MEASURE_AFTER_FRAMES = 10
KEYCHAIN_SERVICE = "dev.pocketdeck.mac." + PROFILE
DEFAULTS_SUITE = "dev.pocketdeck.mac." + PROFILE

# name -> (qdisc setup, timeline). Every qdisc is a root netem unless `tbf`.
# The timeline is a list of (at_s, hold_ms, tc params) pulses: change the
# qdisc for hold_ms, then back to base.
CONDITIONS = {
    # The original brief's arms: TCP under real silence.
    "baseline": dict(qdisc="netem", base=""),
    "loss1": dict(qdisc="netem", base="loss 1%"),
    "loss2": dict(qdisc="netem", base="loss 2%"),
    "loss5": dict(qdisc="netem", base="loss 5%"),
    "silence300": dict(qdisc="netem", base="", pulse=("delay 300ms", 300, 3.0)),
    "silence500": dict(qdisc="netem", base="", pulse=("delay 500ms", 500, 3.0)),
    "silence700": dict(qdisc="netem", base="", pulse=("delay 700ms", 700, 3.0)),
    "loss2jitter20": dict(qdisc="netem", base="delay 20ms 20ms loss 2%"),
    # Architect: loss x RTT (loss x RTT is what hurts TCP).
    "d20": dict(qdisc="netem", base="delay 20ms"),
    "d20l1": dict(qdisc="netem", base="delay 20ms loss 1%"),
    "d20l2": dict(qdisc="netem", base="delay 20ms loss 2%"),
    "d50": dict(qdisc="netem", base="delay 50ms"),
    "d50l1": dict(qdisc="netem", base="delay 50ms loss 1%"),
    "d50l2": dict(qdisc="netem", base="delay 50ms loss 2%"),
    "d50l1r3": dict(qdisc="netem", base="rate 3mbit delay 50ms loss 1%"),
    # Architect, the headline: a crowded 2.4 GHz channel. A token bucket
    # carries the cap so the 200 ms spike can change the child netem without
    # refilling the bucket; jitter is heavy-tailed (paretonormal).
    "wifi8": dict(qdisc="tbf", rate="8mbit",
                  base="delay 10ms 30ms distribution paretonormal loss 0.5%",
                  pulse=("delay 200ms", 200, 2.0)),
    "wifi4": dict(qdisc="tbf", rate="4mbit",
                  base="delay 10ms 30ms distribution paretonormal loss 0.5%",
                  pulse=("delay 200ms", 200, 2.0)),
    # The order-preserving control for the two above: a saturated AP queue
    # delays and drops but never reorders (netem's jitter does reorder, which
    # 802.11 does not). Same cap, loss and spike.
    "wifiq8": dict(qdisc="tbf", rate="8mbit",
                   base="delay 10ms loss 0.5%",
                   pulse=("delay 200ms", 200, 2.0)),
    "wifiq4": dict(qdisc="tbf", rate="4mbit",
                   base="delay 10ms loss 0.5%",
                   pulse=("delay 200ms", 200, 2.0)),
}


def say(msg):
    print(msg, flush=True)


def run(cmd, **kw):
    return subprocess.run(cmd, check=False, capture_output=True, text=True, **kw)


def clear_profile():
    while run(["security", "delete-generic-password", "-s", KEYCHAIN_SERVICE]).returncode == 0:
        pass
    support = os.path.expanduser("~/Library/Application Support/PocketDeck-" + PROFILE)
    for name in ("identity.json", "pins.json"):
        try:
            os.remove(os.path.join(support, name))
        except FileNotFoundError:
            pass
    run(["defaults", "delete", DEFAULTS_SUITE])


class Phone:
    def __init__(self, work):
        self.work = work
        self.sock = os.path.join(work, "phone")
        os.makedirs(self.sock, exist_ok=True)

    def start(self):
        run(["docker", "rm", "-f", CONTAINER])
        for _ in range(40):
            if run(["docker", "inspect", CONTAINER]).returncode != 0:
                break
            time.sleep(0.25)
        cmd = [
            "docker", "run", "-d", "--name", CONTAINER, "--cap-add", "NET_ADMIN",
            "-p", "127.0.0.1:%d:%d" % (PORT, PORT),
            "-v", FAKEPHONE_DIR + ":/fp:ro",
            "-v", self.sock + ":/w",
            IMAGE,
            "python3", "/fp/fakephone.py", "--port", str(PORT), "--no-mdns",
            "--auto-allow", "--frame-events",
            "--state", "/w/state.json", "--events", "/w/events.jsonl",
        ]
        p = run(cmd)
        if p.returncode != 0:
            raise SystemExit("docker run failed: " + p.stderr.strip())
        self.wait_listening()

    def wait_listening(self, timeout=30):
        end = time.time() + timeout
        while time.time() < end:
            logs = run(["docker", "logs", CONTAINER]).stdout + run(["docker", "logs", CONTAINER]).stderr
            if "listening" in logs:
                return
            if run(["docker", "inspect", "-f", "{{.State.Running}}", CONTAINER]).stdout.strip() != "true":
                raise SystemExit("fakephone exited: " + logs[-2000:])
            time.sleep(0.2)
        raise SystemExit("fakephone never listened")

    def tc(self, params):
        q = CONDITIONS[self.cond]["qdisc"]
        dev = "eth0"
        if q == "tbf":
            target = "dev %s parent 1:1 handle 10:" % dev
            if params == "ADD-BASE":
                cmd = ["tc", "qdisc", "add", "dev", dev, "parent", "1:1", "handle", "10:",
                       "netem"] + CONDITIONS[self.cond]["base"].split()
            else:
                cmd = ["tc", "qdisc", "change"] + target.split() + ["netem"] + params.split()
        else:
            if params == "ADD-BASE":
                cmd = ["tc", "qdisc", "add", "dev", dev, "root", "netem"] + CONDITIONS[self.cond]["base"].split()
            else:
                cmd = ["tc", "qdisc", "change", "dev", dev, "root", "netem"] + params.split()
        p = run(["docker", "exec", CONTAINER] + cmd)
        if p.returncode != 0:
            raise SystemExit("tc failed (%s): %s" % (" ".join(cmd), p.stderr.strip()))

    def setup(self):
        q = CONDITIONS[self.cond]["qdisc"]
        if q == "tbf":
            p = run(["docker", "exec", CONTAINER, "tc", "qdisc", "add", "dev", "eth0", "root",
                     "handle", "1:", "tbf", "rate", CONDITIONS[self.cond]["rate"],
                     "burst", "32k", "latency", "200ms"])
            if p.returncode != 0:
                raise SystemExit("tbf failed: " + p.stderr.strip())
        self.tc("ADD-BASE")

    def ss(self):
        p = run(["docker", "exec", CONTAINER, "ss", "-tin"])
        return p.stdout

    def logs(self):
        p = run(["docker", "logs", CONTAINER])
        return (p.stdout or "") + (p.stderr or "")

    def stop(self):
        run(["docker", "rm", "-f", CONTAINER])


def launch(work):
    frames = os.path.join(work, "frames.tsv")
    args = [
        APP, "--profile", PROFILE, "--background",
        "--connect", "127.0.0.1:%d" % PORT,
        "--open", "com.android.chrome",
        "--quit-after", str(int(RUN_SECONDS + 90)),
        "--debug-frame-log", frames,
        "--audio-stats", os.path.join(work, "audio.json"),
        "--debug-chrome-state", os.path.join(work, "chrome.txt"),
    ]
    logstream = open(os.path.join(work, "unified.log"), "w")
    logp = subprocess.Popen(
        ["/usr/bin/log", "stream", "--level", "debug", "--style", "compact",
         "--predicate", 'processImagePath == "%s"' % APP],
        stdout=logstream, stderr=subprocess.DEVNULL)
    app = subprocess.Popen(args, stdout=open(os.path.join(work, "app.log"), "w"),
                           stderr=subprocess.STDOUT)
    return app, logp, logstream, frames


def wait_frames(frames, n, timeout):
    end = time.time() + timeout
    while time.time() < end:
        try:
            with open(frames) as f:
                if sum(1 for _ in f) >= n:
                    return True
        except FileNotFoundError:
            pass
        time.sleep(0.1)
    return False


def frame_times(frames):
    out = []
    try:
        with open(frames) as f:
            for line in f:
                parts = line.split("\t")
                if len(parts) >= 2:
                    out.append(float(parts[0]))
    except FileNotFoundError:
        pass
    return out


def shape(phone, work, stop_flag):
    spec = CONDITIONS[phone.cond]
    t0 = time.time()
    timeline = [{"kind": "start", "t0": t0}]
    end = t0 + RUN_SECONDS
    if "pulse" not in spec:
        while time.time() < end and not stop_flag.is_set():
            time.sleep(0.2)
        timeline.append({"kind": "end", "t1": time.time()})
        return timeline
    params, hold_ms, every_s = spec["pulse"]
    while True:
        at = t0 + every_s
        while time.time() < at and not stop_flag.is_set():
            time.sleep(min(0.05, max(0.0, at - time.time())))
        if time.time() >= end or stop_flag.is_set():
            break
        started = time.time()
        phone.tc(params)
        time.sleep(hold_ms / 1000.0)
        phone.tc(spec["base"])
        timeline.append({"kind": "pulse", "params": params, "t0": started,
                         "t1": time.time(), "hold_ms": hold_ms})
        t0 = at
    timeline.append({"kind": "end", "t1": time.time()})
    return timeline


def vdisplay_start():
    """One virtual display per batch: the app adopts it instead of creating and
    destroying one per launch (each is a system-wide reconfiguration)."""
    src = os.path.join(ROOT, "macos", "scripts", "pd-vdisplay.swift")
    tools = "/tmp/pocketdeck-e2e-tools"
    os.makedirs(tools, exist_ok=True)
    binary = os.path.join(tools, "pd-vdisplay-%x" % (hash(open(src).read()) & 0xFFFFFFFF))
    if not os.path.exists(binary):
        p = run(["swiftc", "-O", src, "-o", binary])
        if p.returncode != 0:
            return None
    out = "/tmp/pd-losslab-vdisplay.txt"
    try:
        os.remove(out)
    except FileNotFoundError:
        pass
    proc = subprocess.Popen([binary, "--profile", PROFILE, "--size", "1280x800", "--scale", "1"],
                            stdout=open(out, "w"), stderr=subprocess.STDOUT)
    for _ in range(80):
        if os.path.exists(out) and ("id=" in open(out).read() or "FAIL" in open(out).read()):
            break
        time.sleep(0.25)
    if not os.path.exists(out) or "id=" not in open(out).read():
        proc.terminate()
        return None
    say("vdisplay: " + open(out).read().split("\n")[0])
    return proc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("conditions", nargs="+", choices=sorted(CONDITIONS))
    ap.add_argument("--runs", type=int, default=2)
    args = ap.parse_args()

    if not os.path.exists(APP):
        raise SystemExit("no e2e app at %s; build it first" % APP)
    vd = vdisplay_start()
    try:
        for cond in args.conditions:
            runs(cond, args.runs, "/tmp/pd-losslab-" + cond)
    finally:
        if vd is not None:
            vd.terminate()
            try:
                vd.wait(timeout=5)
            except subprocess.TimeoutExpired:
                vd.kill()


def runs(cond, count, base):
    for i in range(1, count + 1):
        work = os.path.join(base, "run%d" % i)
        shutil.rmtree(work, ignore_errors=True)
        os.makedirs(work)
        say("== %s run %d/%d" % (cond, i, count))

        clear_profile()
        phone = Phone(work)
        phone.cond = cond
        app = logp = logstream = None
        stop_flag = threading.Event()
        samples = []
        try:
            phone.start()
            phone.setup()
            with open(os.path.join(work, "qdisc-before.txt"), "w") as f:
                f.write(run(["docker", "exec", CONTAINER, "tc", "-s", "qdisc", "show", "dev", "eth0"]).stdout)
            app, logp, logstream, frames = launch(work)

            def sampler():
                while not stop_flag.is_set():
                    samples.append({"t": time.time(), "ss": phone.ss(),
                                    "tc": run(["docker", "exec", CONTAINER, "tc", "-s", "qdisc",
                                               "show", "dev", "eth0"]).stdout})
                    time.sleep(1.0)

            sampler_thread = threading.Thread(target=sampler, daemon=True)
            sampler_thread.start()

            if not wait_frames(frames, MEASURE_AFTER_FRAMES, 30):
                say("   no picture: %d frames after 30 s" % len(frame_times(frames)))
            timeline = shape(phone, work, stop_flag)
            stop_flag.set()
            sampler_thread.join(timeout=3)
            final = [{"t": time.time(), "ss": phone.ss()}]
            with open(os.path.join(work, "qdisc-after.txt"), "w") as f:
                f.write(run(["docker", "exec", CONTAINER, "tc", "-s", "qdisc", "show", "dev", "eth0"]).stdout)
            with open(os.path.join(work, "timeline.json"), "w") as f:
                json.dump(timeline, f)
            with open(os.path.join(work, "ss.txt"), "w") as f:
                for s in samples + final:
                    f.write("### %.6f\n" % s["t"])
                    f.write(s["ss"])
                    if s.get("tc"):
                        f.write(";;tc\n")
                        f.write(s["tc"])
            phone.logs()
            with open(os.path.join(work, "phone.log"), "w") as f:
                f.write(phone.logs())
        finally:
            stop_flag.set()
            if app is not None:
                app.send_signal(signal.SIGTERM)
                try:
                    app.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    app.kill()
            if logp is not None:
                logp.terminate()
                try:
                    logp.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    logp.kill()
            if logstream is not None:
                logstream.close()
            phone.stop()
        n = len(frame_times(os.path.join(work, "frames.tsv")))
        say("   frames=%d" % n)


if __name__ == "__main__":
    main()
