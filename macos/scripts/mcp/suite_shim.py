#!/usr/bin/env python3
"""MCP shim e2e suite (docs/design/mcp.md "Transport", docs/specs/mcp.md).

The shim's exits are part of the contract because a harness that shells out
reads only them (MCP-11, MCP-12). This suite drives the built `contigua-mcp`
binary directly, once against the app's live socket and once against a test
listener that closes without replying, plus the `--help`/`-h`/unknown-argument
paths that never connect.

Prints one PASS/FAIL line per assertion and a final `DRIVER passed=` summary,
the same shape check-e2e.sh's `check_mcp` already folds into ok/bad.
"""

import argparse
import json
import os
import socket
import subprocess
import sys

PASSED = 0
FAILED = 0


def report(ok, text):
    global PASSED, FAILED
    if ok:
        PASSED += 1
        print("PASS " + text)
    else:
        FAILED += 1
        print("FAIL " + text)
    sys.stdout.flush()


def support_dir(profile):
    base = os.path.expanduser("~/Library/Application Support")
    folder = "Contigua" if profile == "default" else "Contigua-" + profile
    return os.path.join(base, folder)


def sock_path(profile):
    return os.path.join(support_dir(profile), "mcp.sock")


def run(args, stdin=None, timeout=30):
    """Run the shim, returning (returncode, stdout_text, stderr_text)."""
    proc = subprocess.run(
        args,
        input=stdin,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout)
    return (proc.returncode,
            proc.stdout.decode("utf-8", "replace"),
            proc.stderr.decode("utf-8", "replace"))


def check_help(shim):
    code, out, _ = run([shim, "--help"])
    ok = code == 0
    for needle in ("--profile", "mcp.sock", "Turn on Settings › Automation in Contigua"):
        if needle not in out:
            ok = False
    report(ok, "[MCP-12] --help prints the usage and exits 0")

    code, out, _ = run([shim, "-h"])
    ok = code == 0 and "--profile" in out and "mcp.sock" in out
    report(ok, "[MCP-12] -h is an alias for --help")


def check_unknown_argument(shim):
    code, _, err = run([shim, "--bogus"])
    ok = (code == 1 and "unknown argument --bogus" in err and "--profile" in err)
    report(ok, "[MCP-12] an unknown argument prints the reason and usage to stderr and exits 1")


def check_live_initialize(shim, profile):
    line = b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n'
    code, out, _ = run([shim, "--profile", profile], stdin=line, timeout=60)
    reply = None
    try:
        parsed = json.loads(out)
        reply = parsed.get("result") or {}
    except ValueError:
        pass
    report(code == 0 and reply.get("protocolVersion") == "2025-06-18",
           "[MCP-11] stdin EOF drains: initialize answers and the shim exits 0")


def check_no_reply(shim, profile):
    """A listener that accepts, reads one line and closes with no reply."""
    test_profile = profile + "-shimtest"
    path = sock_path(test_profile)
    os.makedirs(support_dir(test_profile), exist_ok=True)
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(path)
    server.listen(1)
    server.settimeout(15)

    proc = subprocess.Popen(
        [shim, "--profile", test_profile],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    try:
        conn, _ = server.accept()
        conn.settimeout(15)
        # Feed one request, then close the shim's stdin (EOF).
        try:
            proc.stdin.write(b'{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}\n')
            proc.stdin.close()
        except BrokenPipeError:
            pass
        # Read exactly one line, then close with no reply.
        data = b""
        while b"\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
        conn.close()
    finally:
        server.close()
        try:
            os.unlink(path)
        except OSError:
            pass
        try:
            os.rmdir(support_dir(test_profile))
        except OSError:
            pass

    proc.wait(timeout=15)
    err = proc.stderr.read().decode("utf-8", "replace")
    report(proc.returncode == 1 and "contigua-mcp: the app closed the connection with no reply" in err,
           "[MCP-11] a connection that ends with no byte back exits 1 with a sentence")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shim", required=True)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()

    check_help(args.shim)
    check_unknown_argument(args.shim)
    check_live_initialize(args.shim, args.profile)
    check_no_reply(args.shim, args.profile)

    print("DRIVER passed=%d failed=%d" % (PASSED, FAILED))
    return 1 if FAILED else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print("FAIL " + str(error))
        sys.exit(1)
