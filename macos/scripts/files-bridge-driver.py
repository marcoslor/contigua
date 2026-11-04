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
    files-bridge-driver.py --socket PATH --root DIR --work DIR --phase write
    files-bridge-driver.py --socket PATH --root DIR --work DIR --phase kill --fake-pid N
"""

import argparse
import hashlib
import json
import os
import signal
import socket
import sys
import time

CHUNK_KIND = ("json", "data")
# The two container identifiers the system owns (FilesCore.swift).
WORKING_SET = ".workingSet"
TRASH = ".trashContainer"
WRITE_CHUNK = 256 * 1024
# The bridge wire version (FilesCore.swift): 3 adds the watch wire.
BRIDGE_VERSION = 4


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
        self.send({"t": "hello", "id": self.new_id(), "version": BRIDGE_VERSION})
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

    def stat_item(self, item):
        return self.reply({"t": "stat", "id": self.new_id(), "item": item})

    def list_item(self, item, page=None):
        request = {"t": "list", "id": self.new_id(), "item": item}
        if page is not None:
            request["page"] = page
        return self.reply(request)

    def list_item_all(self, item):
        names, page, items = [], None, []
        while True:
            reply = self.list_item(item, page)
            if reply.get("t") != "items":
                return reply, items
            items.extend(reply.get("items") or [])
            page = reply.get("page")
            if not page:
                return reply, items

    def wait_for(self, request_id):
        """The next JSON frame for this id (data frames are not expected here)."""
        while True:
            kind, obj = self.frame()
            if kind == "data":
                continue
            if obj.get("id") == request_id:
                return obj

    def thumb(self, item, size):
        """One thumbnail: (data, mime, size, sha256, code, frames).

        A success ends with `thumb` (the bytes came as data frames before it);
        a refusal ends with `error`, which carries the code and no bytes.
        """
        request_id = self.new_id()
        self.send({"t": "thumb", "id": request_id, "item": item, "size": size})
        data, frames = b"", 0
        while True:
            frame = self.frame()
            if frame[0] == "data":
                _, first, payload = frame
                if first != request_id:
                    raise BridgeError("thumbnail data for another id")
                data += payload
                frames += 1
                continue
            obj = frame[1]
            if obj.get("id") != request_id:
                raise BridgeError("reply for another id")
            if obj.get("t") == "thumb":
                return (data, obj.get("mime"), obj.get("size"), obj.get("sha256"),
                        None, frames)
            if obj.get("t") == "error":
                return (data, None, None, None, obj.get("code"), frames)
            raise BridgeError("unexpected thumbnail reply %r" % obj.get("t"))

    def cancel_request(self, request_id):
        self.send({"t": "cancel", "id": request_id})

    def create_item(self, parent, name, data, directory=False):
        """create + ready + data chunks + item. Returns the reply object."""
        request_id = self.new_id()
        request = {"t": "create", "id": request_id, "parent": parent,
                   "name": name, "dir": directory}
        if not directory:
            request["size"] = len(data)
            request["sha256"] = hashlib.sha256(data).hexdigest()
        self.send(request)
        reply = self.wait_for(request_id)
        if reply.get("t") != "ready":
            return reply
        for offset in range(0, len(data), WRITE_CHUNK):
            self.send_chunk(request_id, data[offset:offset + WRITE_CHUNK])
        return self.wait_for(request_id)

    def modify_item(self, item, base, data=None, name=None, parent=None, mtime=None):
        request_id = self.new_id()
        fields = {"content": data is not None}
        if name is not None:
            fields["name"] = name
        if parent is not None:
            fields["parent"] = parent
        if mtime is not None:
            fields["mtime"] = mtime
        request = {"t": "modify", "id": request_id, "item": item, "base": base,
                   "fields": fields}
        if data is not None:
            request["size"] = len(data)
            request["sha256"] = hashlib.sha256(data).hexdigest()
        self.send(request)
        reply = self.wait_for(request_id)
        if reply.get("t") != "ready":
            return reply
        for offset in range(0, len(data), WRITE_CHUNK):
            self.send_chunk(request_id, data[offset:offset + WRITE_CHUNK])
        return self.wait_for(request_id)

    def delete_item(self, item, base, recursive=False):
        request_id = self.new_id()
        self.send({"t": "delete", "id": request_id, "item": item, "base": base,
                   "recursive": recursive})
        return self.wait_for(request_id)

    def send_chunk(self, request_id, payload):
        header = json.dumps({"t": "data", "id": request_id, "len": len(payload)}).encode() + b"\n"
        self.sock.sendall(header + payload)

    def read(self, item, offset, length, cancel_after_chunks=None, limit_bytes=None):
        """Reads a range of an item, hashing as it goes.

        With cancel_after_chunks the read is abandoned after that many data
        chunks: (code, bytes_before, chunks_before, chunks_after_error,
        digest_hex). Otherwise (None, total, chunks, -, digest_hex).
        """
        request_id = self.new_id()
        self.send({"t": "read", "id": request_id, "item": item,
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


def watch_folders(bridge, items, on):
    return bridge.reply({"t": "watch", "id": bridge.new_id(), "items": items, "on": on})


def sync_anchor(bridge, item):
    reply = bridge.reply({"t": "anchor", "id": bridge.new_id(), "item": item})
    return reply.get("anchor") if reply.get("t") == "anchor" else None


def change_set(bridge, item, anchor):
    request = {"t": "changes", "id": bridge.new_id(), "item": item}
    if anchor:
        request["from"] = anchor
    return bridge.reply(request)


def await_change(bridge, item, anchor, predicate, timeout=4.0):
    """The next change set after [anchor] that satisfies [predicate].

    A rename reaches the app as more than one notification; each one is a delta
    after the same anchor, so asking again after the next signal is the same
    assertion, not a weaker one.
    """
    deadline = time.time() + timeout
    reply = change_set(bridge, item, anchor)
    while True:
        items = (reply.get("items") or []) if reply.get("t") == "changes" else []
        deleted = (reply.get("deleted") or []) if reply.get("t") == "changes" else []
        if reply.get("t") == "changes" and predicate(items, deleted):
            return reply
        remaining = deadline - time.time()
        if remaining <= 0 or wait_signal(bridge, remaining) is None:
            return reply
        reply = change_set(bridge, item, anchor)


def wait_signal(bridge, timeout):
    """The next `changed` push, or None after [timeout] seconds."""
    deadline = time.time() + timeout
    previous = bridge.sock.gettimeout()
    try:
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                return None
            bridge.sock.settimeout(remaining)
            try:
                kind, obj = bridge.frame()
            except socket.timeout:
                return None
            if kind != "json":
                continue
            if obj.get("t") == "changed":
                return obj
    finally:
        bridge.sock.settimeout(previous)


def drain_signals(bridge, seconds):
    """Drops signals already on the wire; returns how many there were."""
    count = 0
    deadline = time.time() + seconds
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return count
        if wait_signal(bridge, remaining) is None:
            return count
        count += 1


def write_file(path, data):
    with open(path, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())


def phase_watch(bridge, root, fake_err):
    """Phone-side changes reach the Mac: the open folder is watched, moves in
    it arrive as a signal within 3 s plus a delta (create, edit, rename by ino,
    delete), an unwatched folder says nothing, and closing the folder stops it.
    """
    hello = bridge.hello()
    report(hello.get("connected") is True, "WATCH hello: connected")
    a = item_id(bridge, "A")
    b = item_id(bridge, "B")
    report(bool(a) and bool(b), "WATCH the fake tree has folders A and B")
    if not a or not b:
        return
    _, baseline = bridge.list_item_all(a)
    anchor = sync_anchor(bridge, a)
    report(anchor is not None, "WATCH the open folder has a baseline and an anchor (%d items)"
           % len(baseline))
    if anchor is None:
        return
    reply = watch_folders(bridge, [a], True)
    report(reply.get("t") == "ok", "WATCH opening the folder watches it on the phone")

    # Nothing is watched but A: a move in B sends nothing.
    write_file(os.path.join(root, "B", "b1.txt"), b"b\n")
    report(wait_signal(bridge, 1.5) is None,
           "WATCH a change in an unwatched folder sends nothing")

    current = anchor
    one = None
    write_file(os.path.join(root, "A", "one.txt"), b"one\n")
    signal = wait_signal(bridge, 3.0)
    report(signal is not None and a in (signal.get("items") or []),
           "WATCH a create in the open folder signals within 3 s")
    reply = change_set(bridge, a, current)
    items = reply.get("items") or [] if reply.get("t") == "changes" else []
    match = [entry for entry in items if entry.get("name") == "one.txt"]
    report(reply.get("t") == "changes" and reply.get("expired") is False and len(match) == 1,
           "WATCH the change set carries the created file as an add")
    if not match:
        return
    one = match[0]
    report(True, "WATCH the created file has id %s (name hash %s)"
           % (one.get("id"), name_hash("one.txt")))
    current = reply.get("anchor") or current

    write_file(os.path.join(root, "A", "one.txt"), b"one edited\n" * 2)
    wait_signal(bridge, 3.0)
    reply = change_set(bridge, a, current)
    items = reply.get("items") or [] if reply.get("t") == "changes" else []
    match = [entry for entry in items if entry.get("id") == one["id"]]
    report(len(match) == 1 and match[0].get("etag") != one.get("etag")
           and match[0].get("size") != one.get("size"),
           "WATCH an edit is an update of the same id with a new etag")
    current = reply.get("anchor") or current

    os.rename(os.path.join(root, "A", "one.txt"), os.path.join(root, "A", "one-renamed.txt"))
    wait_signal(bridge, 3.0)
    reply = await_change(bridge, a, current, lambda items, deleted: any(
        entry.get("id") == one["id"] and entry.get("name") == "one-renamed.txt"
        for entry in items) and one["id"] not in deleted)
    items = reply.get("items") or [] if reply.get("t") == "changes" else []
    deleted = reply.get("deleted") or []
    match = [entry for entry in items if entry.get("id") == one["id"]]
    report(len(match) == 1 and match[0].get("name") == "one-renamed.txt"
           and one["id"] not in deleted,
           "WATCH a rename keeps the id and reports the new name (was %s, items %s, deleted %s)"
           % (one["id"], [entry.get("id") for entry in items], deleted))
    current = reply.get("anchor") or current

    os.unlink(os.path.join(root, "A", "one-renamed.txt"))
    wait_signal(bridge, 3.0)
    reply = await_change(bridge, a, current,
                         lambda items, deleted: one["id"] in deleted)
    report(reply.get("t") == "changes" and one["id"] in (reply.get("deleted") or []),
           "WATCH a delete is reported as the id that is gone (was %s, deleted %s)"
           % (one["id"], reply.get("deleted") or []))
    current = reply.get("anchor") or current

    # Our own write through the bridge: one change, never a storm.
    drain_signals(bridge, 1.0)
    data = b"from the Mac\n"
    reply = bridge.create_item(a, "two.txt", data)
    seen = 0
    deadline = time.time() + 3.0
    while time.time() < deadline:
        signal = wait_signal(bridge, deadline - time.time())
        if signal is None:
            break
        if a in (signal.get("items") or []):
            seen += 1
    report(create_ok(reply, len(data)) and seen <= 1,
           "WATCH the Mac's own create signals at most once (%d)" % seen)

    # The working set: the same moves, from one domain-wide anchor, and every
    # update carries the item's real parent (design "S5 round 3").
    ws = sync_anchor(bridge, WORKING_SET)
    report(ws is not None, "WATCH the working set has an anchor")
    if ws is None:
        return
    write_file(os.path.join(root, "A", "three.txt"), b"three\n")
    wait_signal(bridge, 3.0)
    reply = await_change(bridge, WORKING_SET, ws, lambda items, deleted: any(
        entry.get("name") == "three.txt" and entry.get("parent") == a for entry in items))
    items = reply.get("items") or [] if reply.get("t") == "changes" else []
    match = [entry for entry in items if entry.get("name") == "three.txt"]
    report(reply.get("t") == "changes" and reply.get("expired") is False
           and len(match) == 1 and match[0].get("parent") == a,
           "WATCH the working set carries a create with its real parent (%d items)"
           % len(items))
    ws_anchor = reply.get("anchor") or ws
    three = match[0] if match else None

    if three:
        os.rename(os.path.join(root, "A", "three.txt"),
                  os.path.join(root, "A", "three-renamed.txt"))
        wait_signal(bridge, 3.0)
        reply = await_change(bridge, WORKING_SET, ws_anchor, lambda items, deleted: any(
            entry.get("id") == three["id"] and entry.get("name") == "three-renamed.txt"
            for entry in items))
        items = reply.get("items") or [] if reply.get("t") == "changes" else []
        match = [entry for entry in items if entry.get("id") == three["id"]]
        report(reply.get("t") == "changes" and len(match) == 1
               and match[0].get("name") == "three-renamed.txt"
               and match[0].get("parent") == a,
               "WATCH the working set's rename is an update of the same id")
        ws_anchor = reply.get("anchor") or ws_anchor

        os.unlink(os.path.join(root, "A", "three-renamed.txt"))
        wait_signal(bridge, 3.0)
        reply = await_change(bridge, WORKING_SET, ws_anchor,
                             lambda items, deleted: three["id"] in deleted)
        report(reply.get("t") == "changes" and three["id"] in (reply.get("deleted") or []),
               "WATCH the working set reports the delete as the id that is gone")
        ws_anchor = reply.get("anchor") or ws_anchor

    # The two system containers never become phone folders: no listing, no
    # stat, no fs.watch. The fake phone's watch count must not move either
    # (the check greps its log).
    before_ws = watch_counts(fake_err)
    listed = bridge.list_item(WORKING_SET)
    watched = watch_folders(bridge, [WORKING_SET], True)
    trash = watch_folders(bridge, [TRASH], True)
    after_ws = watch_counts(fake_err)
    report(listed.get("t") == "error" and listed.get("code") == "fs_not_found"
           and watched.get("t") == "error" and watched.get("code") == "fs_not_found"
           and trash.get("t") == "error" and trash.get("code") == "fs_not_found"
           and before_ws == after_ws,
           "WATCH .workingSet and .trashContainer never reach the phone "
           "(phone watch counts unchanged)")

    # Round 3 keeps a folder for ten minutes after the last touch, so closing
    # the system's enumerator only ends the pushes; the phone keeps watching
    # (the TTL step proves the watch goes when the window ends).
    closed = watch_counts(fake_err)
    reply = watch_folders(bridge, [a], False)
    drain_signals(bridge, 1.0)
    write_file(os.path.join(root, "A", "after.txt"), b"after\n")
    remained = watch_counts(fake_err)
    report(reply.get("t") == "ok" and remained["on"] == closed["on"]
           and remained["off_lines"] == closed["off_lines"],
           "WATCH closing the folder leaves it watched for its ten minutes")


def phase_watchset(bridge, root, fake_err, ttl, folders):
    """The watch set (design "S5 round 3"): 65 folders keep at most 64 (the
    least recently touched drops), and a folder untouched for the TTL is
    unwatched on the phone."""
    hello = bridge.hello()
    report(hello.get("connected") is True, "WATCHSET hello: connected")
    ids = [item_id(bridge, name) for name in folders]
    ok = [ident for ident in ids if ident]
    report(len(ok) == len(folders),
           "WATCHSET the fake tree has %d extra folders (%d)" % (len(folders), len(ok)))
    if len(ok) != len(folders):
        return
    before = watch_counts(fake_err)
    for ident in ok:
        reply = watch_folders(bridge, [ident], True)
        if reply.get("t") != "ok":
            report(False, "WATCHSET a folder was refused (%s)" % reply.get("code"))
            return
    after = watch_counts(fake_err)
    # 64 folders at most: the 65th touch dropped the oldest (one watch off).
    report(after["on"] == 64 and after["off_lines"] > before["off_lines"],
           "WATCHSET 65 touched folders keep 64 watched, the oldest dropped "
           "(on %d, off lines +%d)" % (after["on"], after["off_lines"] - before["off_lines"]))

    # The TTL: A is touched now (it was closed earlier, still inside its
    # window), so wait past it and expect the phone to hear one more watch off.
    a = item_id(bridge, folders[0])
    reply = watch_folders(bridge, [a], True)
    if reply.get("t") != "ok":
        report(False, "WATCHSET the TTL folder was refused (%s)" % reply.get("code"))
        return
    offs = watch_counts(fake_err)["off_lines"]
    deadline = time.time() + ttl + 15.0
    while time.time() < deadline:
        if watch_counts(fake_err)["off_lines"] > offs:
            break
        time.sleep(0.25)
    report(watch_counts(fake_err)["off_lines"] > offs,
           "WATCHSET a folder untouched for the TTL is unwatched on the phone "
           "(%ds)" % ttl)


def watch_counts(path):
    """The fake phone's watch lines from its own log: the last live count and
    how many on/off requests it saw at all."""
    on, off, on_lines, off_lines = 0, 0, 0, 0
    try:
        with open(path, errors="replace") as handle:
            for line in handle:
                line = line.strip()
                if line.startswith("fakephone: watch on "):
                    on = int(line.rsplit(" ", 1)[1])
                    on_lines += 1
                elif line.startswith("fakephone: watch off "):
                    off = int(line.rsplit(" ", 1)[1])
                    off_lines += 1
    except OSError:
        pass
    return {"on": on, "off": off, "on_lines": on_lines, "off_lines": off_lines}


def item_id(bridge, path):
    """The identifier of a relative path, walking the tree by name (the app
    resolves identifiers, so this is what the extension does not have to do)."""
    if path == "":
        return ".rootContainer"
    parent = ".rootContainer"
    parts = path.split("/")
    for index, part in enumerate(parts):
        _, items = bridge.list_item_all(parent)
        match = next((entry for entry in items if entry["name"] == part), None)
        if match is None:
            return None
        if index == len(parts) - 1:
            return match["id"]
        parent = match["id"]
    return None


def visible_root(root):
    return {name for name in os.listdir(root)
            if not name.startswith(".") and name != "Android"}


def check_root_listing(bridge, root):
    _, items = bridge.list_item_all(".rootContainer")
    names = [entry["name"] for entry in items]
    pages = 1
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
    ident = item_id(bridge, path)
    if ident is None:
        return report(False, "BRIDGE no identifier for a folder (%s)" % name_hash(path))
    names, pages, page, last = [], 0, None, {"t": "items"}
    while True:
        last = bridge.list_item(ident, page)
        if last.get("t") != "items":
            break
        pages += 1
        names.extend(entry["name"] for entry in (last.get("items") or []))
        page = last.get("page")
        if not page:
            break
    expected = {name for name in os.listdir(os.path.join(root, path))}
    report(last.get("t") == "items" and len(names) == len(expected)
           and len(set(names)) == len(names) and set(names) == expected and pages >= minimum_pages,
           "BRIDGE %s lists %d names exactly once in %d page(s) (hash %s)"
           % (name_hash(path), len(names), pages,
              hashlib.sha256("".join(sorted(names)).encode()).hexdigest()[:12]))


def check_paging_fresh_connections(socket_path, root, path, minimum_pages):
    """A big folder the way the extension lists it: the extension opens one
    connection per request, so every page arrives on a new socket, with the
    page cursor the previous reply carried. 1500 entries used to list as
    nothing in the VM; the wire must carry them all exactly once."""
    bridge = Bridge(socket_path, timeout=30.0)
    try:
        ident = item_id(bridge, path)
    finally:
        bridge.close()
    if ident is None:
        return report(False, "BRIDGE no identifier for the big folder (%s)" % name_hash(path))
    names, pages, page = [], 0, None
    while True:
        bridge = Bridge(socket_path, timeout=30.0)
        try:
            reply = bridge.list_item(ident, page)
        finally:
            bridge.close()
        if reply.get("t") != "items":
            return report(False, "BRIDGE the big folder's page %d failed (%s)"
                          % (pages + 1, reply.get("code")))
        pages += 1
        batch = reply.get("items") or []
        if len(batch) > 1000 or (pages > 1 and len(batch) == 0):
            return report(False, "BRIDGE the big folder's page %d carries %d items"
                          % (pages, len(batch)))
        names.extend(entry.get("name") for entry in batch)
        page = reply.get("page")
        if not page:
            break
    expected = {name for name in os.listdir(os.path.join(root, path))}
    report(len(names) == len(expected) and len(set(names)) == len(names)
           and set(names) == expected and pages >= minimum_pages,
           "BRIDGE %s lists %d names exactly once in %d page(s), one connection each (hash %s)"
           % (name_hash(path), len(names), pages,
              hashlib.sha256("".join(sorted(names)).encode()).hexdigest()[:12]))


def check_stat(bridge, root, name):
    ident = item_id(bridge, name)
    reply = bridge.stat_item(ident) if ident else {"t": "error", "code": "no_id"}
    size = os.path.getsize(os.path.join(root, name))
    report(reply.get("t") == "item" and not reply.get("item", {}).get("dir")
           and int(reply.get("item", {}).get("size", -1)) == size,
           "BRIDGE stat %s is a %d-byte file" % (name_hash(name), size))


def check_read(bridge, root, name, size):
    expected = sha_file(os.path.join(root, name))
    ident = item_id(bridge, name)
    try:
        code, total, chunks, _, digest = bridge.read(ident, 0, size, limit_bytes=size)
    except BridgeError as error:
        report(False, "BRIDGE read %s failed: %s" % (name_hash(name), error))
        return
    report(code is None and total == size and digest == expected,
           "BRIDGE %s read back byte-identical (%d bytes in %d chunk(s), sha %s...)"
           % (name_hash(name), total, chunks, expected[:12]))


def check_cancel(bridge, root, name, size, fake_err):
    ident = item_id(bridge, name)
    try:
        result = bridge.read(ident, 0, size, cancel_after_chunks=3, limit_bytes=size)
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
    reply = bridge.stat_item(ident)
    report(reply.get("t") == "item",
           "BRIDGE the next request on the same connection still answers")


def check_denied(bridge):
    # No identifier can name Android/data (the app has none for it), so the
    # refusal is asked for by name on a create, which touches nothing.
    reply = bridge.create_item(".rootContainer", "Android/data/x", b"")
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
        # The session keeps a 30 s rejoin grace, so a phone killed mid-run may
        # still read as connected for a while after the process is gone.
        deadline = time.time() + 45.0
        while hello.get("connected") is not False and time.time() < deadline:
            time.sleep(0.25)
            hello = bridge.hello()
        report(hello.get("t") == "hello" and hello.get("connected") is False,
               "BRIDGE hello answers not connected while the phone is away")
        reply = bridge.list_item(".rootContainer")
        report(reply.get("t") == "error" and reply.get("code") == "offline",
               "BRIDGE a listing with no phone answers offline (%s)" % reply.get("code"))
        try:
            code, _, _, _, _ = bridge.read("ino:1", 0, 1024)
            report(code == "offline",
                   "BRIDGE a read with no phone answers offline (%s)" % code)
        except BridgeError as error:
            report(False, "BRIDGE read with no phone: %s" % error)
    finally:
        bridge.close()


# --- the extension's write side (slice S4) ---------------------------------
# The driver plays the sandboxed extension: it speaks the bridge, never the
# phone, and checks the fake phone's tree on disk. Names are hashed in the
# output; the tree itself (in $WORK) is the test's own.

def on_disk(root, rel):
    return os.path.join(root, rel)


def sha_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def staging_files(root):
    found = []
    for base, _dirs, names in os.walk(root):
        for name in names:
            if name.startswith(".pocketdeck-") and name.endswith(".part"):
                found.append(os.path.join(base, name))
    return found


def conflict_candidate(name, attempt):
    """The extension's FilesConflict.candidate: 1 is (from Mac), then numbered."""
    base, dot, ext = name.rpartition(".")
    if not dot or not base:
        base, ext = name, ""
    suffix = "." + ext if ext else ""
    label = " (from Mac)" if attempt == 1 else " (from Mac %d)" % attempt
    return base + label + suffix


def collision_candidate(name, attempt):
    """The extension's FilesConflict.collisionName: attempt 1 is `<name> 2.ext`."""
    base, dot, ext = name.rpartition(".")
    if not dot or not base:
        base, ext = name, ""
    suffix = "." + ext if ext else ""
    return "%s %d%s" % (base, attempt + 1, suffix)


CONFLICT_ATTEMPTS = 20


def create_ok(reply, size):
    return reply.get("t") == "item" and not reply["item"]["dir"] \
        and int(reply["item"]["size"]) == size


def phase_write(bridge, root):
    hello = bridge.hello()
    report(hello.get("connected") is True, "WRITE hello: connected")

    made = bridge.create_item(".rootContainer", "PDWrite", b"", directory=True)
    ok = made.get("t") == "item" and made["item"]["dir"] \
        and os.path.isdir(on_disk(root, "PDWrite"))
    report(ok, "WRITE mkdir made a folder on the fake phone")
    if not ok:
        return
    folder = made["item"]["id"]
    folder_etag = made["item"]["etag"]

    # A 3 MiB file: the bytes, the hash, and no staging file left behind.
    data3 = os.urandom(3 * 1024 * 1024)
    reply = bridge.create_item(folder, "a3.bin", data3)
    path = on_disk(root, "PDWrite/a3.bin")
    landed = create_ok(reply, len(data3)) and os.path.exists(path) \
        and sha_file(path) == hashlib.sha256(data3).hexdigest()
    report(landed, "WRITE a 3 MiB create lands byte-identical")
    first = reply.get("item") if reply.get("t") == "item" else {}
    if not first:
        return

    # A 32 MiB file: the same through the drop pacing.
    data32 = os.urandom(32 * 1024 * 1024)
    reply32 = bridge.create_item(folder, "a32.bin", data32)
    path32 = on_disk(root, "PDWrite/a32.bin")
    report(create_ok(reply32, len(data32)) and os.path.exists(path32)
           and sha_file(path32) == hashlib.sha256(data32).hexdigest(),
           "WRITE a 32 MiB create lands byte-identical")
    report(staging_files(root) == [], "WRITE no staging file is left in the phone's tree")

    # Edit: new bytes, a new etag, the same item id.
    edited = b"edited by the Mac\n" * 70000
    reply = bridge.modify_item(first["id"], first["etag"], data=edited)
    path = on_disk(root, "PDWrite/a3.bin")
    item = reply.get("item") if reply.get("t") == "item" else {}
    report(item.get("id") == first["id"] and item.get("etag") != first["etag"]
           and os.path.exists(path) and sha_file(path) == hashlib.sha256(edited).hexdigest(),
           "WRITE an edit changes the bytes and the etag, the id stays")
    if not item:
        return

    # Rename: still the same id, the folder's listing follows.
    reply = bridge.modify_item(item["id"], item["etag"], name="renamed.bin")
    renamed = reply.get("item") if reply.get("t") == "item" else {}
    stat = bridge.stat_item(item["id"])
    _, listing = bridge.list_item_all(folder)
    names = {entry["name"] for entry in listing}
    report(renamed.get("id") == item["id"] and renamed.get("name") == "renamed.bin"
           and stat.get("t") == "item" and stat["item"]["name"] == "renamed.bin"
           and "renamed.bin" in names and "a3.bin" not in names,
           "WRITE a rename keeps the item id and moves the name (%s)"
           % name_hash("renamed.bin"))

    # Move into another folder: the same id again.
    made = bridge.create_item(".rootContainer", "PDMove", b"", directory=True)
    move_folder = made["item"]["id"] if made.get("t") == "item" else None
    move_folder_etag = made["item"]["etag"] if made.get("t") == "item" else ""
    if move_folder:
        reply = bridge.modify_item(renamed["id"], renamed["etag"], parent=move_folder)
        moved = reply.get("item") if reply.get("t") == "item" else {}
        stat = bridge.stat_item(renamed["id"])
        report(moved.get("id") == renamed["id"] and stat.get("t") == "item"
               and os.path.exists(on_disk(root, "PDMove/renamed.bin"))
               and not os.path.exists(on_disk(root, "PDWrite/renamed.bin")),
               "WRITE a move to another folder keeps the item id")
        if moved:
            reply = bridge.delete_item(moved["id"], moved["etag"])
            report(reply.get("t") == "ok"
                   and not os.path.exists(on_disk(root, "PDMove/renamed.bin")),
                   "WRITE delete removes the file on the phone")
        fresh = bridge.stat_item(move_folder)
        base = fresh["item"]["etag"] if fresh.get("t") == "item" else move_folder_etag
        reply = bridge.delete_item(move_folder, base, recursive=True)
        report(reply.get("t") == "ok" and not os.path.exists(on_disk(root, "PDMove")),
               "WRITE recursive delete removes the folder")

    # Conflict: the phone's copy changes behind the Mac's back.
    original = os.urandom(4096)
    reply = bridge.create_item(folder, "stale.bin", original)
    stale = reply.get("item") if reply.get("t") == "item" else {}
    if stale:
        phone_bytes = b"the phone's own bytes\n" * 100
        with open(on_disk(root, "PDWrite/stale.bin"), "wb") as handle:
            handle.write(phone_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        mine = b"the Mac's edit\n" * 5000
        reply = bridge.modify_item(stale["id"], stale["etag"], data=mine)
        report(reply.get("t") == "error" and reply.get("code") == "fs_stale",
               "WRITE a stale base answers fs_stale (%s)" % reply.get("code"))
        # The conflict rule: keep both, upload as "<name> (from Mac).<ext>".
        # A previous round already left "(from Mac)", and another process takes
        # the first free name right after this listing: the create is
        # exclusive, so fs_exists moves the copy on to the next number.
        _, listing = bridge.list_item_all(folder)
        taken = {entry["name"] for entry in listing}
        older = conflict_candidate("stale.bin", 1)
        older_bytes = b"an older conflict copy\n"
        with open(on_disk(root, "PDWrite/" + older), "wb") as handle:
            handle.write(older_bytes)
            handle.flush()
            os.fsync(handle.fileno())
        landed = None
        for attempt in range(1, CONFLICT_ATTEMPTS + 1):
            candidate = conflict_candidate("stale.bin", attempt)
            if candidate in taken:
                continue
            reply = bridge.create_item(folder, candidate, mine)
            if reply.get("t") == "error" and reply.get("code") == "fs_exists":
                continue
            if reply.get("t") == "item":
                landed = candidate
            break
        second = conflict_candidate("stale.bin", 2)
        current = bridge.stat_item(stale["id"])
        original_path = on_disk(root, "PDWrite/stale.bin")
        conflict_ok = landed == second \
            and sha_file(on_disk(root, "PDWrite/" + second)) == hashlib.sha256(mine).hexdigest()
        report(conflict_ok and current.get("t") == "item"
               and sha_file(original_path) == hashlib.sha256(phone_bytes).hexdigest()
               and sha_file(on_disk(root, "PDWrite/" + older)) == hashlib.sha256(older_bytes).hexdigest(),
               "WRITE a conflict keeps the phone's bytes and numbers past a taken (from Mac) copy (%s)"
               % name_hash(landed or ""))
        if landed:
            _, listing = bridge.list_item_all(folder)
            by_name = {entry["name"]: entry for entry in listing}
            if second in by_name:
                bridge.delete_item(by_name[second]["id"], by_name[second]["etag"])
        bridge.delete_item(stale["id"], current["item"]["etag"] if current.get("t") == "item" else "")

    # A create onto a name the phone already has, but the Mac never listed (a
    # photo taken since): the phone's bytes stay, the Mac is told fs_exists.
    taken_path = on_disk(root, "taken.bin")
    taken_bytes = b"the phone's file, present before the Mac looked\n"
    with open(taken_path, "wb") as handle:
        handle.write(taken_bytes)
        handle.flush()
        os.fsync(handle.fileno())
    mac_bytes = b"the Mac's version\n"
    reply = bridge.create_item(".rootContainer", "taken.bin", mac_bytes)
    report(reply.get("t") == "error" and reply.get("code") == "fs_exists"
           and sha_file(taken_path) == hashlib.sha256(taken_bytes).hexdigest(),
           "WRITE a create onto an existing name answers fs_exists and keeps its bytes (%s)"
           % reply.get("code"))
    # The extension resolves the collision itself under the phone's next free
    # name (FilesConflict.collisionName); the original is untouched.
    free = collision_candidate("taken.bin", 1)
    free_path = on_disk(root, free)
    reply = bridge.create_item(".rootContainer", free, mac_bytes)
    report(create_ok(reply, len(mac_bytes)) and os.path.exists(free_path)
           and sha_file(free_path) == hashlib.sha256(mac_bytes).hexdigest()
           and sha_file(taken_path) == hashlib.sha256(taken_bytes).hexdigest(),
           "WRITE the collision copy lands as <name> 2.<ext>, the phone's file unchanged (%s)"
           % name_hash(free))
    os.unlink(taken_path)
    if os.path.exists(free_path):
        os.unlink(free_path)

    # A delete names the version it removes; the phone checks it right before
    # deleting, so a change made since the Mac's last look is not lost.
    reply = bridge.create_item(folder, "delrace.bin", b"first version\n")
    delrace = reply.get("item") if reply.get("t") == "item" else {}
    if delrace:
        delrace_path = on_disk(root, "PDWrite/delrace.bin")
        with open(delrace_path, "wb") as handle:
            handle.write(b"changed on the phone\n")
            handle.flush()
            os.fsync(handle.fileno())
        reply = bridge.delete_item(delrace["id"], delrace["etag"])
        report(reply.get("t") == "error" and reply.get("code") == "fs_stale"
               and os.path.exists(delrace_path),
               "WRITE a delete with the old etag is fs_stale and keeps the file (%s)"
               % reply.get("code"))
        fresh = bridge.stat_item(delrace["id"])
        if fresh.get("t") == "item":
            reply = bridge.delete_item(delrace["id"], fresh["item"]["etag"])
            report(reply.get("t") == "ok" and not os.path.exists(delrace_path),
                   "WRITE a delete with the current etag removes the file")

    # Leave the tree as the check's next phase expects: PDWrite stays (the
    # mid-write phase writes into it by name).
    report(folder_etag != "", "WRITE the folder is there for the next phase")

    # A path the person must never see from the Mac is refused.
    refused = bridge.create_item(".rootContainer", "Android/data/x", b"nope")
    report(refused.get("t") == "error" and refused.get("code") == "fs_denied",
           "WRITE a write into Android/data answers fs_denied (%s)" % refused.get("code"))


def thumb_log(path):
    """The fake phone's accept/cancel lines, in file order (ids and counts only)."""
    accepts, cancels = [], []
    try:
        with open(path, errors="replace") as handle:
            for number, line in enumerate(handle):
                if "fs thumb accept" in line:
                    accepts.append(number)
                elif "fs thumb cancel" in line:
                    cancels.append(number)
    except OSError:
        pass
    return accepts, cancels


def phase_thumb(bridge, root, fixture):
    """A normal phone: bytes then thumb, and the type filter leaves documents
    and folders with no phone traffic (FILES-22/23)."""
    hello = bridge.hello()
    report(hello.get("connected") is True, "THUMB hello: connected")
    with open(fixture, "rb") as handle:
        expected = handle.read()
    digest = hashlib.sha256(expected).hexdigest()
    photo = item_id(bridge, "DCIM/Camera/photo.jpg")
    report(photo is not None, "THUMB the photo has an id")
    data, mime, size, sha, code, frames = bridge.thumb(photo, 512)
    report(code is None and data == expected,
           "THUMB [FILES-23] the bytes are the phone's answer (%d bytes)" % len(data))
    report(mime == "image/jpeg", "THUMB [FILES-23] the mime is image/jpeg")
    report(size == len(expected) and (sha or "").lower() == digest,
           "THUMB [FILES-23] size and sha256 match the bytes")
    report(frames == 1, "THUMB [FILES-23] the answer is one data frame (%d)" % frames)
    pdf = item_id(bridge, "Documents/report.pdf")
    data, mime, size, sha, code, frames = bridge.thumb(pdf, 512)
    report(code == "not_media" and not data and frames == 0,
           "THUMB [FILES-22] a document is answered not_media with no bytes (%s)" % code)
    folder = item_id(bridge, "DCIM/Camera")
    data, mime, size, sha, code, frames = bridge.thumb(folder, 512)
    report(code == "not_media" and not data and frames == 0,
           "THUMB [FILES-22] a folder is answered not_media with no bytes (%s)" % code)


def phase_thumb_none(bridge):
    """A phone that makes no picture: fs_no_thumb is permanent; a text name
    never reaches the phone at all (FILES-22/26)."""
    hello = bridge.hello()
    report(hello.get("connected") is True, "THUMB hello: connected")
    photo = item_id(bridge, "DCIM/Camera/photo.jpg")
    data, mime, size, sha, code, frames = bridge.thumb(photo, 512)
    report(code == "fs_no_thumb" and not data and frames == 0,
           "THUMB [FILES-26] a phone without a picture answers fs_no_thumb (%s)" % code)
    text = item_id(bridge, "Documents/file00.txt")
    data, mime, size, sha, code, frames = bridge.thumb(text, 512)
    report(code == "not_media" and not data and frames == 0,
           "THUMB [FILES-22] a text file is answered not_media with no bytes (%s)" % code)


def phase_thumb_hold(socket_path, fake_err):
    """A phone that holds every answer: three of four reach it, and cancel
    answers all four; the queued fourth never reaches the phone (FILES-25)."""
    bridge = Bridge(socket_path, timeout=30.0)
    try:
        report(bridge.hello().get("connected") is True, "THUMB hello: connected")
        photo = item_id(bridge, "DCIM/Camera/photo.jpg")
        request_ids = []
        for _ in range(4):
            request_id = bridge.new_id()
            bridge.send({"t": "thumb", "id": request_id, "item": photo, "size": 512})
            request_ids.append(request_id)
        time.sleep(0.8)
        accepts, cancels = thumb_log(fake_err)
        report(len(accepts) == 3 and not cancels,
               "THUMB [FILES-25] three reach the phone and the fourth waits (%d, %d cancels)"
               % (len(accepts), len(cancels)))
        # One connection, FIFO: the last request is the queued one. Cancel it
        # first, so freeing the running slots cannot start it.
        for request_id in [request_ids[3]] + request_ids[:3]:
            bridge.cancel_request(request_id)
            if request_id == request_ids[3]:
                time.sleep(0.2)
        replies = {}
        deadline = time.time() + 5
        while len(replies) < 4 and time.time() < deadline:
            try:
                frame = bridge.frame()
            except socket.timeout:
                continue
            if frame[0] == "data":
                continue
            obj = frame[1]
            if obj.get("id") in request_ids:
                replies.setdefault(obj.get("id"), obj)
        codes = [replies.get(request_id, {}).get("code") for request_id in request_ids]
        report(codes == ["cancelled"] * 4,
               "THUMB [FILES-25] every cancelled ask answers cancelled (%s)" % codes)
        accepts, _ = thumb_log(fake_err)
        report(len(accepts) == 3,
               "THUMB [FILES-25] the queued fourth never reached the phone (%d accepts)"
               % len(accepts))
    finally:
        bridge.close()


def phase_thumb_once(socket_path, fake_err):
    """A phone that holds only its first answer: 3 start, the fourth waits and
    runs once two of them end (FILES-25)."""
    bridge = Bridge(socket_path, timeout=4.0)
    try:
        report(bridge.hello().get("connected") is True, "THUMB hello: connected")
        photo = item_id(bridge, "DCIM/Camera/photo.jpg")
        request_ids = []
        for _ in range(4):
            request_id = bridge.new_id()
            bridge.send({"t": "thumb", "id": request_id, "item": photo, "size": 512})
            request_ids.append(request_id)
        replies = {}
        held = None
        deadline = time.time() + 4
        while time.time() < deadline and len(replies) < 3:
            try:
                frame = bridge.frame()
            except socket.timeout:
                continue
            if frame[0] == "data":
                continue
            obj = frame[1]
            if obj.get("id") in request_ids:
                replies.setdefault(obj.get("id"), obj)
        for request_id in request_ids:
            if request_id not in replies:
                held = request_id
                break
        report(held == request_ids[0] and len(replies) == 3,
               "THUMB [FILES-25] the first answer is held, the other three finish")
        accepts, _ = thumb_log(fake_err)
        report(len(accepts) == 4,
               "THUMB [FILES-25] the queued fourth starts after one ends (%d accepted)"
               % len(accepts))
        successes = sum(1 for obj in replies.values() if obj.get("t") == "thumb")
        report(successes == 3,
               "THUMB [FILES-25] the three unheld answers are thumbnails (%d)" % successes)
        if held is not None:
            bridge.cancel_request(held)
            code = bridge.wait_for(held).get("code")
            report(code == "cancelled",
                   "THUMB [FILES-25] the held ask answers cancelled (%s)" % code)

    finally:
        bridge.close()


def phase_thumb_timeout(socket_path):
    """A phone that accepts and never answers: the app answers at its 8 s
    deadline and sends one fs.cancel (FILES-29)."""
    bridge = Bridge(socket_path, timeout=30.0)
    try:
        report(bridge.hello().get("connected") is True, "THUMB hello: connected")
        photo = item_id(bridge, "DCIM/Camera/photo.jpg")
        started = time.time()
        data, mime, size, sha, code, frames = bridge.thumb(photo, 512)
        elapsed = time.time() - started
        report(code == "timeout",
               "THUMB [FILES-29] a phone that never answers answers timeout (%s)" % code)
        report(7.0 <= elapsed <= 10.5,
               "THUMB [FILES-29] the deadline is 8 s from the ask (%.1f s)" % elapsed)
        report(not data and frames == 0,
               "THUMB [FILES-29] a timed-out answer carries no bytes")
    finally:
        bridge.close()


def phase_thumb_slow(socket_path, fixture):
    """A phone that takes 1 s per picture: 12 asks queue three at a time, and
    the last waits about 9 s before it starts — past the old 8 s deadline
    measured from the ask — yet every one answers with bytes (FILES-29)."""
    bridges = []
    replies = []
    asks = []
    try:
        with open(fixture, "rb") as handle:
            expected = handle.read()
        digest = hashlib.sha256(expected).hexdigest()
        for _ in range(2):
            bridge = Bridge(socket_path, timeout=90.0)
            bridges.append(bridge)
            report(bridge.hello().get("connected") is True, "THUMB hello: connected")
            replies.append({})
        photo = item_id(bridges[0], "DCIM/Camera/photo.jpg")
        started = time.time()
        for bridge in bridges:
            ids = []
            for _ in range(6):
                request_id = bridge.new_id()
                bridge.send({"t": "thumb", "id": request_id, "item": photo, "size": 512})
                ids.append(request_id)
            asks.append(ids)
        deadline = time.time() + 60
        for index, bridge in enumerate(bridges):
            while len(replies[index]) < 6 and time.time() < deadline:
                frame = bridge.frame()
                if frame[0] == "data":
                    continue
                obj = frame[1]
                if obj.get("id") in asks[index]:
                    replies[index].setdefault(obj.get("id"), obj)
        elapsed = time.time() - started
        answers = [obj for by_id in replies for obj in by_id.values()]
        successes = [obj for obj in answers if obj.get("t") == "thumb"]
        failures = [obj for obj in answers if obj.get("t") != "thumb"]
        report(len(answers) == 12,
               "THUMB [FILES-29] all 12 queued asks answered (%d)" % len(answers))
        report(len(successes) == 12 and not failures,
               "THUMB [FILES-29] a 1 s phone answers all 12 with bytes, none timed out "
               "(%d ok, %s)" % (len(successes),
                                ",".join(str(obj.get("code")) for obj in failures)
                                or "no errors"))
        report(elapsed >= 9.0,
               "THUMB [FILES-29] the last ask waited past the old 8 s from the ask "
               "(%.1f s)" % elapsed)
        report(all(obj.get("size") == len(expected) and
                   (obj.get("sha256") or "").lower() == digest for obj in successes),
               "THUMB [FILES-29] every queued answer is the phone's own picture")
    finally:
        for bridge in bridges:
            bridge.close()


def phase_persist(bridge, root, work, stage):
    """FILES-31: the record outlives the app. Before the stop, list the folder
    and save its ids and the working-set anchor; after the restart, watch and
    list it and read the change set from the old anchor. The phone lost two
    files and gained one while the app was down, so the first listing after the
    restart must report exactly that, within 5 s.
    """
    state_path = os.path.join(work, "persist.json")
    folder = os.path.join(root, "P")
    on_disk = set(os.listdir(folder))
    if stage == "before":
        p = item_id(bridge, "P")
        if not p:
            report(False, "PERSIST [FILES-31] the fake tree has folder P")
            return
        reply, items = bridge.list_item_all(p)
        names = {entry.get("name") for entry in items}
        report(reply.get("t") == "items" and names == on_disk and len(items) == 5,
               "PERSIST [FILES-31] the first run listed the folder's 5 files (%d)"
               % len(items))
        anchor = sync_anchor(bridge, WORKING_SET)
        report(anchor is not None,
               "PERSIST [FILES-31] the working set has an anchor before the stop")
        if anchor is None:
            return
        state = {"folder": p, "anchor": anchor,
                 "ids": {entry.get("name"): entry.get("id") for entry in items}}
        with open(state_path, "w") as handle:
            json.dump(state, handle)
        return

    with open(state_path) as handle:
        saved = json.load(handle)
    p = saved["folder"]
    old_names = set(saved["ids"])
    missing = old_names - on_disk
    added = on_disk - old_names
    report(len(missing) == 2 and len(added) == 1,
           "PERSIST [FILES-31] the phone lost 2 files and gained 1 while the app was down")

    started = time.time()
    reply = watch_folders(bridge, [p], True)
    report(reply.get("t") == "ok",
           "PERSIST [FILES-31] the restarted app watches the folder again")
    listing, items = bridge.list_item_all(p)
    names = {entry.get("name") for entry in items}
    elapsed = time.time() - started
    report(listing.get("t") == "items" and names == on_disk and len(items) == 4
           and elapsed <= 5.0,
           "PERSIST [FILES-31] the first listing after the restart is the phone's 4 "
           "in %.2f s" % elapsed)

    reply = await_change(bridge, WORKING_SET, saved["anchor"],
                         lambda changed, deleted: len(deleted) == 2 and len(changed) == 1,
                         timeout=5.0)
    changed = reply.get("items") or [] if reply.get("t") == "changes" else []
    deleted = reply.get("deleted") or [] if reply.get("t") == "changes" else []
    expected = {saved["ids"][name] for name in missing}
    report(reply.get("t") == "changes" and reply.get("expired") is False
           and set(deleted) == expected and len(changed) == 1
           and changed[0].get("name") in added,
           "PERSIST [FILES-31] the old anchor replays the 2 deletions and 1 add "
           "(%d deleted, %d items)" % (len(deleted), len(changed)))


def phase_kill(bridge, root, fake_pid):
    hello = bridge.hello()
    report(hello.get("connected") is True, "WRITE hello: connected")
    data = os.urandom(32 * 1024 * 1024)
    request_id = bridge.new_id()
    bridge.send({"t": "create", "id": request_id, "parent": ".rootContainer",
                 "name": "PDWrite-kill.bin", "dir": False, "size": len(data),
                 "sha256": hashlib.sha256(data).hexdigest()})
    reply = bridge.wait_for(request_id)
    if reply.get("t") != "ready":
        report(False, "WRITE the mid-write check never got ready (%s)" % reply.get("code"))
        return
    sent, killed, broke = 0, False, False
    try:
        for offset in range(0, len(data), WRITE_CHUNK):
            bridge.send_chunk(request_id, data[offset:offset + WRITE_CHUNK])
            sent += min(WRITE_CHUNK, len(data) - offset)
            if not killed and fake_pid and sent >= 8 * 1024 * 1024:
                os.kill(fake_pid, signal.SIGKILL)
                killed = True
    except OSError:
        broke = True
    code = None
    if not broke:
        try:
            final = bridge.wait_for(request_id)
            code = final.get("code")
        except (BridgeError, socket.timeout):
            code = "closed"
    report(killed and (code in ("offline", "closed") or broke),
           "WRITE a phone killed mid-write ends the request as offline (%s, %d bytes sent)"
           % (code or "socket closed", sent))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--fake-err", default=None)
    parser.add_argument("--fake-pid", type=int, default=None)
    parser.add_argument("--thumb-fixture", default=None)
    parser.add_argument("--phase",
                        choices=["online", "read", "offline", "write", "kill",
                                 "watch", "watchset", "persist", "thumb", "thumb-hold",
                                 "thumb-once", "thumb-timeout", "thumb-slow",
                                 "thumb-none"],
                        required=True)
    parser.add_argument("--ttl", type=float, default=20.0)
    parser.add_argument("--watch-folders", default="")
    parser.add_argument("--stage", choices=["before", "after"], default="before")
    args = parser.parse_args()

    if args.phase == "offline":
        check_offline(args.socket)
        return 0
    if args.phase == "persist":
        try:
            bridge = Bridge(args.socket, timeout=60.0)
        except OSError as error:
            report(False, "PERSIST cannot connect to the bridge socket (%s)" % error)
            return 1
        try:
            phase_persist(bridge, args.root, args.work, args.stage)
        except (BridgeError, socket.timeout, OSError) as error:
            report(False, "PERSIST the bridge stopped answering (%s)" % error)
            return 1
        finally:
            bridge.close()
        return 0
    if args.phase in ("watch", "watchset"):
        try:
            bridge = Bridge(args.socket, timeout=60.0)
        except OSError as error:
            report(False, "WATCH cannot connect to the bridge socket (%s)" % error)
            return 1
        try:
            if args.phase == "watch":
                phase_watch(bridge, args.root, args.fake_err or
                            os.path.join(args.work, "fake.err"))
            else:
                folders = [name for name in args.watch_folders.split(",") if name]
                phase_watchset(bridge, args.root, args.fake_err or
                               os.path.join(args.work, "fake.err"), args.ttl, folders)
        except (BridgeError, socket.timeout, OSError) as error:
            report(False, "WATCH the bridge stopped answering (%s)" % error)
            return 1
        finally:
            bridge.close()
        return 0

    if args.phase in ("thumb-hold", "thumb-once", "thumb-timeout", "thumb-slow"):
        try:
            if args.phase == "thumb-hold":
                phase_thumb_hold(args.socket, args.fake_err or
                                 os.path.join(args.work, "fake.err"))
            elif args.phase == "thumb-once":
                phase_thumb_once(args.socket, args.fake_err or
                                 os.path.join(args.work, "fake.err"))
            elif args.phase == "thumb-slow":
                phase_thumb_slow(args.socket, args.thumb_fixture)
            else:
                phase_thumb_timeout(args.socket)
        except (BridgeError, socket.timeout, OSError) as error:
            report(False, "THUMB the bridge stopped answering (%s)" % error)
            return 1
        return 0

    if args.phase in ("write", "kill"):
        try:
            bridge = Bridge(args.socket, timeout=60.0)
        except OSError as error:
            report(False, "WRITE cannot connect to the bridge socket (%s)" % error)
            return 1
        try:
            if args.phase == "write":
                phase_write(bridge, args.root)
            else:
                phase_kill(bridge, args.root, args.fake_pid)
        except (BridgeError, socket.timeout, OSError) as error:
            report(False, "WRITE the bridge stopped answering (%s)" % error)
            return 1
        finally:
            bridge.close()
        return 0

    try:
        bridge = Bridge(args.socket)
    except OSError as error:
        report(False, "BRIDGE cannot connect to the bridge socket (%s)" % error)
        return 1
    try:
        if args.phase == "thumb":
            phase_thumb(bridge, args.root, args.thumb_fixture)
            return 0
        if args.phase == "thumb-none":
            phase_thumb_none(bridge)
            return 0
        if args.phase == "read":
            # The read-only half of `online`: what a Finder browse, a Quick
            # Look and a stat send, with no create/cancel in the same phase.
            hello = bridge.hello()
            report(hello.get("t") == "hello" and hello.get("connected") is True,
                   "BRIDGE hello: connected, phone name %r" % hello.get("name"))
            check_root_listing(bridge, args.root)
            check_paging(bridge, args.root, "Documents", 1)
            check_stat(bridge, args.root, "big3.bin")
            check_read(bridge, args.root, "big3.bin", 3 * 1024 * 1024)
            return 0
        hello = bridge.hello()
        report(hello.get("t") == "hello" and hello.get("connected") is True
               and hello.get("name") == "FakePhone",
               "BRIDGE hello: connected, phone name %r" % hello.get("name"))
        check_root_listing(bridge, args.root)
        check_paging(bridge, args.root, "Documents", 1)
        check_paging(bridge, args.root, "DCIM/Camera", 1)
        check_paging(bridge, args.root, "many", 2)
        check_paging_fresh_connections(args.socket, args.root, "many", 2)
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
