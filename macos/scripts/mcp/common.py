"""Shared helpers for the MCP e2e suites (docs/design/mcp.md).

The stdio MCP client the suites (and tools/emulator, tools/stream-bench) speak
to Contigua through the built shim, the fakephone event log reader, a stdlib
PNG decoder, and the PASS/FAIL reporter `check_mcp` folds into ok/bad.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import select
import struct
import subprocess
import sys
import time
import traceback
import zlib

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


def mode(args, *words):
    """Set the fake phone's modes (fakephone.py `--mode-file`, the `fake-mode`
    file beside the events log) for the requests that follow."""
    path = os.path.join(os.path.dirname(os.path.abspath(args.events)), "fake-mode")
    with open(path + ".tmp", "w") as handle:
        handle.write(" ".join(words) + "\n")
    os.rename(path + ".tmp", path)


def note(text):
    print("DRIVER " + text)
    sys.stdout.flush()


# --- MCP-5: every answer matches its outputSchema and its text mirror -------

ANSWERS_CHECKED = 0
ANSWERS_BROKEN = 0


def _schema_type_ok(value, kind):
    if kind == "null":
        return value is None
    if kind == "boolean":
        return isinstance(value, bool)
    if kind == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if kind == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if kind == "string":
        return isinstance(value, str)
    if kind == "array":
        return isinstance(value, list)
    if kind == "object":
        return isinstance(value, dict)
    return True


def schema_problems(value, schema, where="answer"):
    """The ways `value` breaks a JSON Schema subset (type, properties,
    required, items): what a strict MCP client checks structuredContent with."""
    problems = []
    kinds = schema.get("type")
    if kinds is not None:
        kinds = kinds if isinstance(kinds, list) else [kinds]
        if not any(_schema_type_ok(value, kind) for kind in kinds):
            return ["%s is %s, not %s" % (where, type(value).__name__, "/".join(kinds))]
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                problems.append("%s lacks required %r" % (where, key))
        for key, sub in schema.get("properties", {}).items():
            if key in value:
                problems += schema_problems(value[key], sub, "%s.%s" % (where, key))
    if isinstance(value, list) and isinstance(schema.get("items"), dict):
        for index, item in enumerate(value):
            problems += schema_problems(item, schema["items"], "%s[%d]" % (where, index))
    return problems


def text_block(result):
    for block in result.get("content", []):
        if block.get("type") == "text":
            return block.get("text", "")
    return ""


# --- MCP stdio client ------------------------------------------------------

class MCP:
    def __init__(self, shim, profile):
        self.proc = subprocess.Popen(
            [shim, "--profile", profile],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1)
        self.next_id = 0
        self.schemas = None

    def _write(self, object):
        self.proc.stdin.write(json.dumps(object, separators=(",", ":")) + "\n")
        self.proc.stdin.flush()

    def notify(self, method, params=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        self._write(message)

    def request(self, method, params=None, timeout=60):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self._write(message)
        ready, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not ready:
            raise RuntimeError("no reply to %s in %ss" % (method, timeout))
        line = self.proc.stdout.readline()
        if not line:
            stderr = self.proc.stderr.read() if self.proc.stderr else ""
            raise RuntimeError("shim closed during %s: %s" % (method, stderr.strip()))
        reply = json.loads(line)
        if reply.get("id") != self.next_id:
            raise RuntimeError("reply id %r for request %r" % (reply.get("id"), self.next_id))
        return reply

    def tool(self, name, arguments=None, timeout=60):
        reply = self.request("tools/call", {"name": name, "arguments": arguments or {}},
                            timeout=timeout)
        if "error" in reply:
            raise RuntimeError("%s: JSON-RPC error %r" % (name, reply["error"]))
        result = reply["result"]
        if not result.get("isError"):
            self.check_answer(name, result)
        return result

    def check_answer(self, name, result):
        """MCP-5: structuredContent equals its text mirror and validates
        against the tool's outputSchema. A FAIL line names the break."""
        global ANSWERS_CHECKED, ANSWERS_BROKEN
        if self.schemas is None:
            tools = self.request("tools/list")["result"]["tools"]
            self.schemas = {tool["name"]: tool.get("outputSchema") for tool in tools}
        answer = result.get("structuredContent")
        problems = []
        if answer is None:
            problems.append("no structuredContent")
        else:
            try:
                if json.loads(text_block(result)) != answer:
                    problems.append("the text mirror differs from structuredContent")
            except ValueError:
                problems.append("the text mirror is not JSON")
            schema = self.schemas.get(name)
            if schema is None:
                problems.append("tools/list declares no outputSchema")
            else:
                problems += schema_problems(answer, schema)
        ANSWERS_CHECKED += 1
        if problems:
            ANSWERS_BROKEN += 1
            report(False, "[MCP-5] MCP %s answer: %s" % (name, "; ".join(problems[:3])))

    def text(self, name, arguments=None, timeout=60):
        result = self.tool(name, arguments, timeout)
        if result.get("isError"):
            raise RuntimeError("%s: %s" % (name, result["content"][0]["text"]))
        body = text_block(result)
        if not body:
            raise RuntimeError("%s: empty result text" % name)
        return json.loads(body)

    def close(self):
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)


# --- fakephone event log ---------------------------------------------------

def events(path):
    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError:
        return []
    out = []
    for line in raw.split(b"\n"):
        if not line.strip():
            continue
        try:
            out.append(json.loads(line))
        except ValueError:
            continue
    return out


def wait_event(path, predicate, seconds, description):
    deadline = time.time() + seconds
    while time.time() < deadline:
        for event in events(path):
            if predicate(event):
                return event
        time.sleep(0.2)
    raise RuntimeError("timed out waiting for " + description)


# --- PNG ------------------------------------------------------------------

def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def png_stats(data):
    """(width, height, mean luma, min luma, max luma) of an 8-bit RGB/RGBA PNG."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("screenshot is not a PNG")
    offset = 8
    width = height = bit_depth = color_type = None
    idat = b""
    while offset + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        body = data[offset + 8:offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", body[:10])
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if width is None or bit_depth != 8 or color_type not in (2, 6):
        raise RuntimeError("unexpected PNG format: depth=%r type=%r" % (bit_depth, color_type))
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(idat)
    previous = bytearray(stride)
    total = 0
    count = 0
    low, high = 255, 0
    position = 0
    for _ in range(height):
        filter_type = raw[position]
        position += 1
        line = bytearray(raw[position:position + stride])
        position += stride
        for index in range(stride):
            left = line[index - channels] if index >= channels else 0
            up = previous[index]
            upper_left = previous[index - channels] if index >= channels else 0
            if filter_type == 1:
                line[index] = (line[index] + left) & 0xFF
            elif filter_type == 2:
                line[index] = (line[index] + up) & 0xFF
            elif filter_type == 3:
                line[index] = (line[index] + (left + up) // 2) & 0xFF
            elif filter_type == 4:
                line[index] = (line[index] + _paeth(left, up, upper_left)) & 0xFF
            elif filter_type != 0:
                raise RuntimeError("unknown PNG filter %d" % filter_type)
        previous = line
        for x in range(0, width, 3):
            base = x * channels
            luma = 0.2126 * line[base] + 0.7152 * line[base + 1] + 0.0722 * line[base + 2]
            total += luma
            count += 1
            low = min(low, luma)
            high = max(high, luma)
    return width, height, total / max(1, count), low, high


# --- checks ---------------------------------------------------------------

TOOLS = [
    "phone_status", "list_apps", "open_app", "list_windows", "screenshot", "ui_tree",
    "wait", "tap", "long_press", "swipe", "type_text", "press_key",
    "input_probe", "close_window", "send_link", "send_file",
]


def within_px(actual, expected, pixels):
    return abs(actual - expected) * pixels <= 1.0 + 1e-6

