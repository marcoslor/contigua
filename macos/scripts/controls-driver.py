#!/usr/bin/env python3
"""The Control Center extension's side of the controls e2e check.

docs/design/controls.md: the extension only reads a snapshot and sends one JSON
line over a UNIX socket, so the check can stand in for it without a widget
extension (a host run never carries one). Prints JSON on stdout; exit 1 when a
wait or a request fails.

  controls-driver.py snapshot DIR
  controls-driver.py wait DIR SECONDS key=value [key=value ...]
  controls-driver.py request DIR KIND [ARG]
  controls-driver.py send DIR JSON
"""

import json
import os
import socket
import sys
import time

SNAPSHOT = "controls.json"
SOCKET = "controls.sock"


def snapshot_path(directory):
    return os.path.join(directory, SNAPSHOT)


def read_snapshot(directory):
    with open(snapshot_path(directory), "r", encoding="utf-8") as handle:
        return json.load(handle)


def wait(directory, seconds, wanted):
    deadline = time.time() + float(seconds)
    last = None
    while time.time() < deadline:
        try:
            last = read_snapshot(directory)
        except (OSError, ValueError):
            time.sleep(0.1)
            continue
        if all(str(last.get(key)).lower() == value.lower() for key, value in wanted.items()):
            return last
        time.sleep(0.1)
    print("last snapshot: %s" % json.dumps(last, sort_keys=True), file=sys.stderr)
    return None


def request_line(kind, arg):
    if kind == "dnd":
        return {"t": "dnd", "on": arg.lower() in ("on", "true", "1")}
    if kind in ("ring", "ring.stop", "open"):
        return {"t": kind}
    if kind == "ringer":
        return {"t": "ringer", "mode": arg}
    raise SystemExit("unknown request %r" % kind)


def send_once(directory, line):
    path = os.path.join(directory, SOCKET)
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(6)
    client.connect(path)
    client.sendall((json.dumps(line, sort_keys=True) + "\n").encode("utf-8"))
    buffer = b""
    while b"\n" not in buffer and len(buffer) <= 4096:
        chunk = client.recv(1024)
        if not chunk:
            break
        buffer += chunk
    client.close()
    return json.loads(buffer.split(b"\n", 1)[0].decode("utf-8"))


def send(directory, line):
    """One request, retried once: the app answers on its main actor, and a
    control tap must not fail over a slow launch. No request is repeated when
    the first one answered."""
    for attempt in range(2):
        try:
            return send_once(directory, line)
        except (socket.timeout, ConnectionError, OSError):
            if attempt:
                raise


def main(argv):
    if len(argv) < 3:
        raise SystemExit(__doc__)
    command, directory = argv[1], argv[2]
    if command == "snapshot":
        print(json.dumps(read_snapshot(directory), sort_keys=True))
        return 0
    if command == "wait":
        if len(argv) < 5:
            raise SystemExit(__doc__)
        wanted = dict(pair.split("=", 1) for pair in argv[4:])
        found = wait(directory, argv[3], wanted)
        if found is None:
            print("timed out waiting for %s" % wanted, file=sys.stderr)
            return 1
        print(json.dumps(found, sort_keys=True))
        return 0
    if command == "request":
        line = request_line(argv[3], argv[4] if len(argv) > 4 else "")
        reply = send(directory, line)
        print(json.dumps(reply, sort_keys=True))
        return 0 if reply.get("ok") else 1
    if command == "send":
        reply = send(directory, json.loads(argv[3]))
        print(json.dumps(reply, sort_keys=True))
        return 0 if reply.get("ok") else 1
    raise SystemExit(__doc__)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
