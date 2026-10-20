#!/usr/bin/env python3
"""Speak the Finder bridge the way the sandboxed extension does (slice S3).

The app owns the phone session; the File Provider extension asks the app over a
UNIX socket in the App Group container (docs/design/files.md §1/§3). This driver
is the extension's stand-in for the host check `files-bridge`: it opens the same
socket (`--files-bridge-dir` puts it in the run's work dir) and sends
`hello`/`list`/`stat`/`read`/`cancel`, verifying what comes back against the
fake phone's file tree.

Output is the check's `ok ...` / `bad ...` lines. File names never appear: name
hashes, counts, byte lengths and codes only (design §4).

    files-bridge-driver.py --socket PATH --root DIR --work DIR --phase online
    files-bridge-driver.py --socket PATH --root DIR --work DIR --phase offline
"""

import argparse
import hashlib
import json
import os
import socket
import sys
import time

CHUNK_KIND = ("json", "data")


def report(ok, text):
    print(("ok " if ok else "bad ") + text)
    sys.stdout.flush()


def name_hash(name):
    return hashlib.sha256(name.encode()).hexdigest()[:16]


def sha_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


class BridgeError(Exception):
    pass


class Bridge(object):
    """One connection, exactly the framing of FilesCore's BridgeDecoder."""

    def __init__(self, path, timeout=60.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 1

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    # -- framing ---------------------------------------------------------

    def _line(self):
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise BridgeError("closed")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def _exact(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise BridgeError("closed")
            self.buffer += chunk
        out, self.buffer = self.buffer[:count], self.buffer[count:]
        return out

    def frame(self):
        """("json", object) or ("data", id, bytes)."""
        obj = json.loads(self._line())
        if obj.get("t") == "data":
            length = obj.get("len")
            if not isinstance(length, int) or length < 0:
                raise BridgeError("bad data header")
            return ("data", obj.get("id"), self._exact(length))
        return ("json", obj)

    def send(self, obj):
        self.sock.sendall(json.dumps(obj).encode() + b"\n")

    def new_id(self):
        value = self.next_id
        self.next_id += 1
        return value

    # -- requests --------------------------------------------------------

    def hello(self):
        self.send({"t": "hello", "id": self.new_id(), "version": 1})
        while True:
            kind, obj = self.frame()
            if kind == "json" and obj.get("t") == "hello":
                return obj
            if kind == "json" and obj.get("t") == "error":
                raise BridgeError(obj.get("code", "error"))

    def reply(self, request):
        self.send(request)
        while True:
            kind, obj = self.frame()
            if kind == "data":
                raise BridgeError("data for a non-read request")
            if obj.get("id") == request["id"]:
                return obj

    def list_page(self, path, page=None):
        request = {"t": "list", "id": self.new_id(), "path": path}
        if page is not None:
            request["page"] = page
        return self.reply(request)

    def list_all(self, path):
        names, pages, page, last, items = [], 0, None, None, []
        while True:
            last = self.list_page(path, page)
            if last.get("t") != "items":
                return last, names, pages, items
            pages += 1
            page_items = last.get("items") or []
            items.extend(page_items)
            names.extend(item.get("name") for item in page_items)
            page = last.get("page")
            if not page:
                return last, names, pages, items

    def stat(self, path):
        return self.reply({"t": "stat", "id": self.new_id(), "path": path})

    def read(self, path, offset, length, cancel_after_chunks=None, limit_bytes=None):
        """Reads a range, hashing as it goes.

        With cancel_after_chunks the read is abandoned after that many data
        chunks: (code, bytes_before, chunks_before, chunks_after_error,
        digest_hex). Otherwise (None, total, chunks, -, digest_hex).
        """
        request_id = self.new_id()
        self.send({"t": "read", "id": request_id, "path": path,
                   "offset": offset, "length": length})
        digest = hashlib.sha256()
        total, chunks, before = 0, 0, None
        cancelled = cancel_after_chunks is None
        after_error = 0
        seen_error = False
        while True:
            frame = self.frame()
            if frame[0] == "data":
                _, first, payload = frame
                if first != request_id:
                    raise BridgeError("data for another id")
                if seen_error:
                    after_error += 1
                    continue
                total += len(payload)
                digest.update(payload)
                chunks += 1
                if not cancelled and chunks == cancel_after_chunks:
                    before = total
                    self.send({"t": "cancel", "id": request_id})
                    cancelled = True
                if limit_bytes is not None and total > limit_bytes:
                    raise BridgeError("more bytes than announced")
                continue
            obj = frame[1]
            if obj.get("id") != request_id:
                raise BridgeError("reply for another id")
            if obj.get("t") == "end":
                if cancel_after_chunks is not None:
                    raise BridgeError("end after cancel")
                return (None, total, chunks, 0, digest.hexdigest())
            if obj.get("t") == "error":
                code = obj.get("code")
                if cancel_after_chunks is not None and code == "cancelled":
                    # Anything the app wrote before it saw the cancel is already
                    # in the buffer; count only data after the error frame.
                    deadline = time.time() + 0.6
                    self.sock.settimeout(0.2)
                    try:
                        while time.time() < deadline:
                            try:
                                drain = self.frame()
                            except socket.timeout:
                                break
                            if drain[0] == "data" and drain[1] == request_id:
                                after_error += 1
                    finally:
                        self.sock.settimeout(60.0)
                    return ("cancelled", before, chunks, after_error, "")
                return (code, before or 0, chunks, 0, "")


def visible_root(root):
    return {name for name in os.listdir(root)
            if not name.startswith(".") and name != "Android"}


def check_root_listing(bridge, root):
    last, names, pages, items = bridge.list_all("")
    expected = visible_root(root)
    got = set(names)
    sizes_ok = True
    for item in items:
        name = item.get("name")
        full = os.path.join(root, name)
        if not os.path.exists(full):
            sizes_ok = False
            continue
        is_dir = os.path.isdir(full)
        size = 0 if is_dir else os.path.getsize(full)
        if bool(item.get("dir")) != is_dir or int(item.get("size", -1)) != size:
            sizes_ok = False
    report(got == expected and len(names) == len(expected) and sizes_ok,
           "BRIDGE root lists every visible name and size (%d items, hidden/Android left out, %d page(s))"
           % (len(got), pages))


def check_paging(bridge, root, path, minimum_pages):
    last, names, pages, _ = bridge.list_all(path)
    expected = {name for name in os.listdir(os.path.join(root, path))}
    report(last.get("t") == "items" and len(names) == len(expected)
           and len(set(names)) == len(names) and set(names) == expected and pages >= minimum_pages,
           "BRIDGE %s lists %d names exactly once in %d page(s) (hash %s)"
           % (name_hash(path), len(names), pages,
              hashlib.sha256("".join(sorted(names)).encode()).hexdigest()[:12]))


def check_stat(bridge, root, name):
    reply = bridge.stat(name)
    size = os.path.getsize(os.path.join(root, name))
    report(reply.get("t") == "item" and not reply.get("item", {}).get("dir")
           and int(reply.get("item", {}).get("size", -1)) == size,
           "BRIDGE stat %s is a %d-byte file" % (name_hash(name), size))


def check_read(bridge, root, name, size):
    expected = sha_file(os.path.join(root, name))
    try:
        code, total, chunks, _, digest = bridge.read(name, 0, size, limit_bytes=size)
    except BridgeError as error:
        report(False, "BRIDGE read %s failed: %s" % (name_hash(name), error))
        return
    report(code is None and total == size and digest == expected,
           "BRIDGE %s read back byte-identical (%d bytes in %d chunk(s), sha %s...)"
           % (name_hash(name), total, chunks, expected[:12]))


def check_cancel(bridge, root, name, size, fake_err):
    try:
        result = bridge.read(name, 0, size, cancel_after_chunks=3, limit_bytes=size)
    except BridgeError as error:
        report(False, "BRIDGE cancel of %s failed: %s" % (name_hash(name), error))
        return
    code, before, chunks, after_error, _ = result
    # The fake phone's own log: the cancel arrived and its stream stopped.
    sent_before, sent_after, saw_cancel = 0, 0, False
    read_id = None
    order = []
    try:
        with open(fake_err, errors="replace") as handle:
            for raw in handle:
                line = raw.strip()
                if line.startswith("fakephone: fs cancel id="):
                    order.append(("cancel", int(line.rsplit("=", 1)[1])))
                elif line.startswith("fakephone: fs sent id="):
                    order.append(("sent", int(line.split()[3].split("=")[1])))
    except OSError:
        pass
    at = next((index for index, item in enumerate(order) if item[0] == "cancel"), None)
    if at is not None:
        read_id = order[at][1]
        sent_before = sum(1 for kind, ident in order[:at] if kind == "sent" and ident == read_id)
        sent_after = sum(1 for kind, ident in order[at + 1:] if kind == "sent" and ident == read_id)
        saw_cancel = True
    report(code == "cancelled" and before > 0 and after_error == 0
           and saw_cancel and sent_before > 0 and sent_after <= 1,
           "BRIDGE a 32 MiB read cancelled after %d chunk(s) (%d bytes): no data after the "
           "cancel, phone sent %d chunk(s) after its cancel" % (chunks, before, sent_after))
    # The connection is usable afterwards.
    reply = bridge.stat(name)
    report(reply.get("t") == "item",
           "BRIDGE the next request on the same connection still answers")


def check_denied(bridge):
    reply = bridge.list_page("Android/data/x")
    report(reply.get("t") == "error" and reply.get("code") == "fs_denied",
           "BRIDGE Android/data/x answers fs_denied (%s)" % reply.get("code"))


def check_offline(socket_path):
    try:
        bridge = Bridge(socket_path, timeout=20.0)
    except OSError as error:
        report(False, "BRIDGE offline: cannot connect to the socket (%s)" % error)
        return
    try:
        # The app learns the session ended from its own socket; give it a moment.
        hello = bridge.hello()
        deadline = time.time() + 10.0
        while hello.get("connected") is not False and time.time() < deadline:
            time.sleep(0.25)
            hello = bridge.hello()
        report(hello.get("t") == "hello" and hello.get("connected") is False,
               "BRIDGE hello answers not connected while the phone is away")
        reply = bridge.list_page("")
        report(reply.get("t") == "error" and reply.get("code") == "offline",
               "BRIDGE a listing with no phone answers offline (%s)" % reply.get("code"))
        try:
            code, _, _, _, _ = bridge.read("big3.bin", 0, 1024)
            report(code == "offline",
                   "BRIDGE a read with no phone answers offline (%s)" % code)
        except BridgeError as error:
            report(False, "BRIDGE read with no phone: %s" % error)
    finally:
        bridge.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--fake-err", default=None)
    parser.add_argument("--phase", choices=["online", "offline"], required=True)
    args = parser.parse_args()

    if args.phase == "offline":
        check_offline(args.socket)
        return 0

    try:
        bridge = Bridge(args.socket)
    except OSError as error:
        report(False, "BRIDGE cannot connect to the bridge socket (%s)" % error)
        return 1
    try:
        hello = bridge.hello()
        report(hello.get("t") == "hello" and hello.get("connected") is True
               and hello.get("name") == "FakePhone",
               "BRIDGE hello: connected, phone name %r" % hello.get("name"))
        check_root_listing(bridge, args.root)
        check_paging(bridge, args.root, "Documents", 1)
        check_paging(bridge, args.root, "DCIM/Camera", 1)
        check_paging(bridge, args.root, "many", 2)
        check_stat(bridge, args.root, "big3.bin")
        check_stat(bridge, args.root, "big32.bin")
        check_read(bridge, args.root, "big3.bin", 3 * 1024 * 1024)
        check_read(bridge, args.root, "big32.bin", 32 * 1024 * 1024)
        check_cancel(bridge, args.root, "big32.bin", 32 * 1024 * 1024,
                     args.fake_err or os.path.join(args.work, "fake.err"))
        check_denied(bridge)
    except (BridgeError, socket.timeout, OSError) as error:
        report(False, "BRIDGE the bridge stopped answering (%s)" % error)
        return 1
    finally:
        bridge.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
