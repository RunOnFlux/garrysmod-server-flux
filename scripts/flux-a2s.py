#!/usr/bin/env python3
"""Is the game answering? One Steam A2S_INFO query to this container's own game port.

srcds binds its network only AFTER it has downloaded the Workshop collection and loaded the map,
so an answer here is the proof the server can be joined, and silence is "still starting" (or
broken). Used by the image's HEALTHCHECK and by the supervisor's ready watcher.

    flux-a2s.py [port]     exit 0 when the server answered, 1 when it did not

Asked at EVERY address of this container, not at 127.0.0.1: srcds binds the container's own
address ("Network: IP 172.17.0.4, ... ports 27015 SV"), and a query to the loopback is never
answered (measured, 2026-11-03).

The port is the argument, else GAME_PORT, else 27015. A value that is not a port from 1024 to
65535 is the launcher's fallback too (flux-launch.py): 27015.

Since 2020 a server may answer A2S_INFO with a CHALLENGE (header 0x41) instead of the info, and
that is an answer: only a live srcds sends it. Any reply that starts with the 0xFFFFFFFF
header counts.
"""
import os
import socket
import sys

QUERY = b"\xff\xff\xff\xffTSource Engine Query\x00"
HEADER = b"\xff\xff\xff\xff"


def game_port(value):
    """The port to query for a GAME_PORT value, as the launcher reads it."""
    value = (value or "").strip() or "27015"
    if value.isdigit() and 1024 <= int(value) <= 65535:
        return int(value)
    return 27015


def local_addresses(fib_trie="/proc/net/fib_trie"):
    """This container's IPv4 addresses, loopback first. From the kernel's table, so it needs no tool."""
    found = ["127.0.0.1"]
    try:
        with open(fib_trie) as f:
            previous = ""
            for line in f:
                text = line.strip()
                # A local address is a "/32 host LOCAL" leaf, named on the line above it.
                if text.startswith("/32 host LOCAL") and previous.startswith(("|--", "+--")):
                    addr = previous.split()[-1]
                    if addr.count(".") == 3 and addr not in found and not addr.startswith("127."):
                        found.append(addr)
                previous = text
    except OSError:
        pass
    try:
        addr = socket.gethostbyname(socket.gethostname())
        if addr not in found:
            found.append(addr)
    except OSError:
        pass
    return found


def answers(port, hosts=None, timeout=3.0, sock=None):
    """True when the A2S query sent to port at any of `hosts` was answered. `sock` is for the tests."""
    s = sock or socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.settimeout(timeout)
        for host in (hosts or local_addresses()):
            try:
                s.sendto(QUERY, (host, port))
            except OSError:
                continue
        # One socket, every address asked at once: the answer comes from the address srcds bound.
        data, _ = s.recvfrom(4096)
        return data.startswith(HEADER)
    except OSError:
        return False
    finally:
        s.close()


def main(argv):
    port = game_port(argv[1] if len(argv) > 1 else os.environ.get("GAME_PORT"))
    return 0 if answers(port) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
