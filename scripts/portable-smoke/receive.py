# SPDX-License-Identifier: GPL-3.0-only
import csv
import hashlib
import hmac
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import threading
import time

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

width, height, codec, port = map(int, sys.argv[1:5])
scenario, directory = sys.argv[5:]
secret = sys.stdin.buffer.read(16)


def read(s, n):
    data = bytearray()
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise EOFError("host closed stream")
        data.extend(chunk)
    return bytes(data)


def sample_resources(stop, events):
    # ps percentages are process samples; IORegistry utilisation is system-wide
    # and does not isolate VideoToolbox's media engine.
    host_pid = os.getppid()
    receiver_pid = os.getpid()
    while not stop.wait(2):
        stamp = time.monotonic_ns()
        ps = subprocess.run(
            ["/bin/ps", "-p", f"{host_pid},{receiver_pid}", "-o", "pid=,%cpu=,rss="],
            capture_output=True, text=True,
        )
        for line in ps.stdout.splitlines():
            pid, cpu, rss = line.split()
            prefix = "host" if int(pid) == host_pid else "receiver"
            events.append((prefix + "_cpu_milli_pct", 0, stamp, round(float(cpu) * 1000)))
            events.append((prefix + "_rss_kib", 0, stamp, int(rss)))
        registry = subprocess.run(
            ["/usr/sbin/ioreg", "-r", "-c", "IOAccelerator", "-d", "1"],
            capture_output=True, text=True,
        )
        for key, value in (("gpu_device_pct", "Device Utilization %"),
                           ("gpu_renderer_pct", "Renderer Utilization %"),
                           ("gpu_memory_bytes", "In use system memory")):
            match = re.search(r'"' + re.escape(value) + r'"\s*=\s*(\d+)', registry.stdout)
            if match:
                events.append((key, 0, stamp, int(match.group(1))))


def receive(s, bitstream):
    server = read(s, 32)
    nonce = os.urandom(32)
    pairing_secret = bytes([secret[0] ^ 1]) + secret[1:] if scenario == "wrong_code" else secret

    def key(direction):
        return hmac.digest(pairing_secret, b"BetterCast Portable v1" + server + nonce + bytes([direction]), hashlib.sha256)

    s.sendall(nonce + AESGCM(key(1)).encrypt(bytes(12), struct.pack(">IIB", width, height, codec), None))
    receiver = AESGCM(key(2))
    seq = count = media_bytes = 0
    pts = set()
    access_units = set()
    events = []
    sampler_stop = threading.Event()
    sampler = None
    if directory:
        sampler = threading.Thread(target=sample_resources, args=(sampler_stop, events), daemon=True)
        sampler.start()
    start = None
    duration = {"steady": 70, "reset": 2, "window_close": 5}.get(scenario, 5)
    while True:
        try:
            header = read(s, 4)
            length = struct.unpack(">I", header)[0]
            assert 17 <= length <= 8 * 1024 * 1024
            ciphertext = read(s, length)
        except (EOFError, ConnectionResetError):
            if scenario == "wrong_code":
                assert seq == 0
                return
            if scenario == "host_stop" and count >= 30:
                break
            raise
        packet_at = time.monotonic_ns()
        msg = receiver.decrypt(seq.to_bytes(12, "big"), ciphertext, header)
        seq += 1
        if msg[0] == 3:
            reason = msg[1:].decode()
            if scenario == "approval_timeout" and reason == "Mac approval timed out.":
                assert start is None
                return
            raise RuntimeError(reason)
        if msg[0] == 4:
            assert msg == b"\x04" and start is None
            start = time.monotonic()
        if msg[0] == 1:
            assert start is not None
            pts_ns = int.from_bytes(msg[1:9], "little")
            pts.add(pts_ns)
            access_units.add(hashlib.sha256(msg[9:]).digest())
            count += 1
            media_bytes += len(msg) - 1
            if directory:
                events.append(("tcp_read", pts_ns // 100, packet_at, 0))
                events.append(("rx", pts_ns // 100, time.monotonic_ns(), len(msg) - 1))
            offset = 9
            while offset < len(msg):
                assert offset + 4 < len(msg)
                n = struct.unpack_from(">I", msg, offset)[0]
                assert n > 0
                offset += 4 + n
                assert offset <= len(msg)
                if bitstream:
                    bitstream.write(b"\x00\x00\x00\x01")
                    bitstream.write(memoryview(msg)[offset - n:offset])
        if start is not None and time.monotonic() - start >= duration:
            break
    elapsed = time.monotonic() - start
    if scenario == "reset":
        s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    if sampler:
        sampler_stop.set()
        sampler.join()
    if directory:
        with (Path(directory) / "loopback.csv").open("w", newline="") as output:
            writer = csv.writer(output)
            writer.writerow(("event", "pts_100ns", "time_ns", "value"))
            writer.writerows(events)
    if count < 30 or len(pts) != count or len(access_units) < 30:
        raise RuntimeError(f"Invalid frame coverage: {count} access units, {len(pts)} unique PTS, "
                           f"{len(access_units)} distinct payloads in {elapsed:.2f} s")
    print(f"PASS received {count} authenticated access units, {len(pts)} unique PTS, {len(access_units)} distinct payloads in {elapsed:.2f} s; {count/elapsed:.1f} RX FPS, {media_bytes*8/elapsed/1e6:.2f} Mb/s", flush=True)


try:
    with socket.create_connection(("127.0.0.1", port), timeout=10) as sock:
        assert scenario != "expired", "Expired listener still accepts connections"
        if directory and os.environ.get("PORTABLE_RECORD_BITSTREAM") == "1":
            extension = "hevc" if codec == 2 else "h264"
            with (Path(directory) / f"stream.{extension}").open("wb") as bitstream:
                receive(sock, bitstream)
        else:
            receive(sock, None)
except ConnectionRefusedError:
    if scenario != "expired":
        raise
