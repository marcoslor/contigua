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
WRITE_CHUNK = 256 * 1024
# The bridge wire version (FilesCore.swift): 2 is the S4 id-carrying wire.
BRIDGE_VERSION = 2


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
        deadline = time.time() + 10.0
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
    reply = bridge.create_item(".rootContainer", "taken.bin", b"the Mac's version\n")
    report(reply.get("t") == "error" and reply.get("code") == "fs_exists"
           and sha_file(taken_path) == hashlib.sha256(taken_bytes).hexdigest(),
           "WRITE a create onto an existing name answers fs_exists and keeps its bytes (%s)"
           % reply.get("code"))
    os.unlink(taken_path)

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
    parser.add_argument("--phase", choices=["online", "offline", "write", "kill"], required=True)
    args = parser.parse_args()

    if args.phase == "offline":
        check_offline(args.socket)
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
