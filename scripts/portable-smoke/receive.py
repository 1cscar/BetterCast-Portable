# SPDX-License-Identifier: GPL-3.0-only
import hashlib
import hmac
import os
import socket
import struct
import sys
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
width, height, codec = map(int, sys.argv[1:])
secret = sys.stdin.buffer.read(16)

def read(s, n):
    data = bytearray()
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise RuntimeError("host closed stream")
        data.extend(chunk)
    return bytes(data)

with socket.create_connection(("127.0.0.1", 51823), timeout=10) as s:
    server = read(s, 32)
    nonce = os.urandom(32)
    def key(direction):
        return hmac.digest(secret, b"BetterCast Portable v1" + server + nonce + bytes([direction]), hashlib.sha256)
    s.sendall(nonce + AESGCM(key(1)).encrypt(bytes(12), struct.pack(">IIB", width, height, codec), None))
    receiver = AESGCM(key(2))
    seq = count = media_bytes = 0
    pts = set()
    access_units = set()
    start = None
    while True:
        header = read(s, 4)
        length = struct.unpack(">I", header)[0]
        assert 17 <= length <= 8 * 1024 * 1024
        msg = receiver.decrypt(seq.to_bytes(12, "big"), read(s, length), header)
        seq += 1
        if msg[0] == 3:
            raise RuntimeError(msg[1:].decode())
        if msg[0] == 4:
            assert msg == b"\x04" and start is None
            start = time.monotonic()
        if msg[0] == 1:
            assert start is not None
            pts.add(msg[1:9])
            access_units.add(hashlib.sha256(msg[9:]).digest())
            count += 1
            media_bytes += len(msg) - 1
            offset = 9
            while offset < len(msg):
                assert offset + 4 < len(msg)
                n = struct.unpack_from(">I", msg, offset)[0]
                assert n > 0
                offset += 4 + n
                assert offset <= len(msg)
        if start is not None and time.monotonic() - start >= 5:
            break
    elapsed = time.monotonic() - start
    assert count >= 30 and len(pts) == count and len(access_units) >= 30
    print(f"PASS received {count} authenticated access units, {len(pts)} unique PTS, {len(access_units)} distinct payloads in {elapsed:.2f} s; {count/elapsed:.1f} RX FPS, {media_bytes*8/elapsed/1e6:.2f} Mb/s", flush=True)
