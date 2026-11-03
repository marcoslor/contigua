#!/usr/bin/env python3
"""The other end of the direct-link feth harness (docs/design/direct-link.md §7.2).

Runs inside the e2e VM guest as the "phone": a plain or TLS TCP server bound to
a link-local on feth1, so the kernel plays the peer and the helper's lwIP stack
is the thing under test.

  feth_phone.py --address fe80::1%feth1 --port 47990 --mode echo
  feth_phone.py --address fe80::1%feth1 --port 47991 --mode count --tls \
                --cert cert.pem --key key.pem --stats tls.count

Modes:
  echo   echo every byte back (the 1 MiB and MSS-boundary runs)
  count  read and count, writing "<n>\\n" to --stats every half second and on
         EOF (the benchmark; the bytes must match the client's)
  close  accept, wait --close-after seconds, close (the mid-transfer close)

Prints one "feth_phone listening ..." line so the check can wait for it.
"""

import argparse
import os
import socket
import ssl
import sys
import threading
import time


def write_count(path, value):
    if not path:
        return
    tmp = path + ".tmp"
    with open(tmp, "w") as handle:
        handle.write("%d\n" % value)
    os.replace(tmp, path)


def serve_connection(conn, mode, stats, close_after):
    received = 0
    if mode == "close":
        time.sleep(close_after)
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()
        return
    try:
        while True:
            data = conn.recv(65536)
            if not data:
                break
            received += len(data)
            if mode == "echo":
                conn.sendall(data)
            else:
                write_count(stats, received)
    except (ConnectionResetError, BrokenPipeError):
        pass
    finally:
        write_count(stats, received)
        try:
            conn.close()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--address", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--mode", choices=["echo", "count", "close"], default="echo")
    parser.add_argument("--tls", action="store_true")
    parser.add_argument("--cert")
    parser.add_argument("--key")
    parser.add_argument("--stats")
    parser.add_argument("--close-after", type=float, default=1.0)
    args = parser.parse_args()

    context = None
    if args.tls:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.cert, args.key)
        # No session tickets: the app's TLS client treats incoming bytes as
        # protocol frames, and a post-handshake ticket would look like one.
        context.options |= ssl.OP_NO_TICKET
        context.minimum_version = ssl.TLSVersion.TLSv1_3

    host, _, zone = args.address.partition("%")
    scope = socket.if_nametoindex(zone) if zone else 0
    listener = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    # A link-local needs sin6_scope_id; the "fe80::1%if" string form fails with
    # EADDRNOTAVAIL on macOS, so bind the 4-tuple.
    listener.bind((host, args.port, 0, scope))
    listener.listen(4)
    print("feth_phone listening %s %d mode=%s tls=%d"
          % (args.address, args.port, args.mode, 1 if args.tls else 0), flush=True)

    while True:
        try:
            conn, _ = listener.accept()
        except KeyboardInterrupt:
            break
        try:
            if context is not None:
                conn = context.wrap_socket(conn, server_side=True)
        except (ssl.SSLError, OSError) as error:
            print("feth_phone tls failed: %s" % error, file=sys.stderr, flush=True)
            conn.close()
            continue
        thread = threading.Thread(target=serve_connection,
                                  args=(conn, args.mode, args.stats, args.close_after),
                                  daemon=True)
        thread.start()


if __name__ == "__main__":
    main()
