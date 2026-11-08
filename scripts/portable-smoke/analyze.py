# SPDX-License-Identifier: GPL-3.0-only
"""Measure a 60-second cohort of captured frames after five seconds of real motion."""
import argparse
from collections import defaultdict
import csv
import math
from pathlib import Path

SECOND = 1_000_000_000


def load(path):
    rows = defaultdict(list)
    with path.open(newline="") as stream:
        first = stream.readline().strip()
        metadata = dict(part.split("=", 1) for part in first[2:].split() if "=" in part) if first.startswith("# ") else {}
        if not metadata:
            stream.seek(0)
        for row in csv.DictReader(stream):
            rows[row["event"]].append((int(row["pts_100ns"]), int(row["time_ns"]), int(row["value"])))
    return metadata, rows


def percentile_ms(values, fraction):
    return sorted(values)[math.ceil(len(values) * fraction) - 1] / 1_000_000


def latency(label, values):
    if values:
        print(f"{label}: P50 {percentile_ms(values, .50):.3f} ms, "
              f"P95 {percentile_ms(values, .95):.3f} ms, n={len(values)}")
    else:
        print(f"{label}: unavailable (no matching timestamps)")


def summarize(host_path, receiver_path, loopback):
    host_meta, host = load(host_path)
    receiver_meta, receiver = load(receiver_path)
    if not loopback and (not host_meta.get("commit") or host_meta.get("commit") != receiver_meta.get("commit")):
        raise SystemExit("Host and receiver source commits differ or are absent.")
    if receiver["trace_truncated"]:
        raise SystemExit("Receiver trace exceeded its event limit.")
    if host_meta.get("omitted") != "0" or not host["capture_stopped"]:
        raise SystemExit("Incomplete Host trace: no capture shutdown marker or events were omitted.")
    if not host["motion"]:
        raise SystemExit("No recorded test motion. Start motion on the Mac after pairing.")
    start = min(t for _, t, _ in host["motion"]) + 5 * SECOND
    end = start + 60 * SECOND
    if max(t for _, t, _ in host["motion"]) < end:
        raise SystemExit("Less than 60 seconds of test motion after warm-up. Keep the session active longer.")

    def during(rows):
        return [(pts, time, value) for pts, time, value in rows if start <= time < end]

    def by_pts(rows):
        return {pts: time for pts, time, _ in rows if pts > 0}

    capture = by_pts(during(host["capture"]))
    encode = by_pts(host["encode"])
    submitted = by_pts(host["tcp_submit"])
    processed = by_pts(host["tcp_processed"])
    received = by_pts(receiver["rx"])
    read = by_pts(receiver["tcp_read"])
    decoded = by_pts(receiver["decoded"])
    present = by_pts(receiver["present"])
    backpressure = by_pts(host["backpressure"])
    cohort = set(capture)
    if not cohort or not (cohort & received.keys()):
        raise SystemExit("No matching authenticated media for the measured capture cohort.")
    # Approximate the receiver window using the lowest observed read transit. It includes
    # the unknown clock offset, so its value is never reported as absolute LAN latency.
    transport = [read[pts] - submitted[pts] for pts in cohort & read.keys() & submitted.keys()]
    if not transport:
        raise SystemExit("No matching TCP reads for the measured capture cohort.")
    offset = 0 if loopback else min(transport)
    if max(t for _, t, _ in receiver["rx"]) < end + offset:
        raise SystemExit("Receiver stopped before the steady window finished.")

    print(f"Host {host_path.name}: {host_meta}")
    print(f"Receiver {receiver_path.name}: {receiver_meta or 'Mac Python loopback'}")
    print(f"Steady interval: 60.000 s after 5 s of motion, virtual display {host_meta['refresh_hz']} Hz")
    print(f"Motion updates {len(during(host['motion']))}; ScreenCaptureKit idle notifications "
          f"{len(during(host['idle']))}; other incomplete notifications {len(during(host['capture_other']))}")
    print(f"Capture callbacks {len(during(host['capture']))}; unique capture PTS {len(cohort)}")
    stages = [("Capture", capture), ("Encode", encode), ("Receive", received)]
    if not loopback:
        stages.extend([("Decode matched", decoded), ("Present S_OK matched", present)])
    for label, stage in stages:
        count = len(cohort & stage.keys())
        print(f"{label}: {count} frames, {count / 60:.2f} FPS")
    if not loopback:
        if receiver["gpu_vendor_id"] and receiver["gpu_device_id"]:
            print(f"DXGI adapter PCI IDs: {receiver['gpu_vendor_id'][0][2]:04x}:{receiver['gpu_device_id'][0][2]:04x}")
        for label, event in (("Decode outputs", "decoded"), ("Present S_OK calls", "present"),
                             ("Other Present HRESULTs", "present_other")):
            rows = [row for row in receiver[event] if start + offset <= row[1] < end + offset]
            print(f"{label} in receiver window: {len(rows)} ({len(rows) / 60:.2f}/s); "
                  f"without PTS {sum(row[0] == 0 for row in rows)}")
    else:
        print("Decode / Present: not measured by Mac loopback")
    encoded_pts = cohort & encode.keys()
    received_pts = cohort & received.keys()
    dropped = cohort - encoded_pts
    print(f"Capture without encode {len(dropped)} (before encoder due to backpressure {len(dropped & backpressure.keys())}; "
          f"other without encoder output {len(dropped - backpressure.keys())}); "
          f"encoded without TCP submit {len(encoded_pts - submitted.keys())}; "
          f"submitted without authenticated receive {len(cohort & submitted.keys() - received.keys())}")
    if not loopback:
        print(f"RX without matched decoder output {len(received_pts - decoded.keys())}; "
              f"decoded without matched S_OK present {len((cohort & decoded.keys()) - present.keys())}")
    media_bytes = sum(n for pts, _, n in receiver["rx"] if pts in cohort)
    print(f"Received video payload: {media_bytes * 8 / 60 / 1e6:.2f} Mb/s")

    def stage_latency(label, earlier, later):
        latency(label, [later[pts] - earlier[pts] for pts in cohort & earlier.keys() & later.keys()
                        if later[pts] >= earlier[pts]])

    stage_latency("Mac capture callback → encoded access unit", capture, encode)
    stage_latency("Mac encode → TCP submit", encode, submitted)
    stage_latency("Mac TCP submit → local TCP completion", submitted, processed)
    if loopback:
        stage_latency("Mac TCP submit → loopback read", submitted, read)
        stage_latency("Mac capture callback → authenticated loopback RX", capture, received)
    else:
        floor = min(transport)
        latency("TCP submit → Windows read, excess over observed minimum (includes receive thread)", [t - floor for t in transport])
        stage_latency("Windows authenticated RX → decoder output", received, decoded)
        stage_latency("Windows decoder output → Present S_OK return", decoded, present)
        stage_latency("Windows authenticated RX → Present S_OK return", received, present)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("host", type=Path)
    parser.add_argument("receiver", type=Path)
    parser.add_argument("--loopback", action="store_true")
    args = parser.parse_args()
    summarize(args.host, args.receiver, args.loopback)
