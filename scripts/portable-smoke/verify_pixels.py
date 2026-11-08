# SPDX-License-Identifier: GPL-3.0-only
"""Decode a completed loopback recording and count distinct steady-state rasters."""
import argparse
from pathlib import Path
import subprocess

from analyze import SECOND, load


def verify(directory):
    host_path, = directory.glob("host-*.csv")
    stream, = directory.glob("stream.*")
    _, host = load(host_path)
    _, receiver = load(directory / "loopback.csv")
    decoded = subprocess.run(
        ["ffmpeg", "-v", "error", "-xerror", "-threads", "2", "-i", str(stream),
         "-map", "0:v:0", "-an", "-fps_mode", "passthrough", "-f", "framemd5", "-"],
        check=True, capture_output=True, text=True,
    )
    hashes = [line.rsplit(",", 1)[-1].strip() for line in decoded.stdout.splitlines()
              if line and not line.startswith("#")]
    received_pts = sorted(pts for pts, _, _ in receiver["rx"])
    if len(hashes) != len(received_pts) or len(set(received_pts)) != len(received_pts):
        raise SystemExit(f"Cannot match decoded pictures to authenticated PTS: "
                         f"{len(hashes)} pictures, {len(received_pts)} received units.")
    start = min(time for _, time, _ in host["motion"]) + 5 * SECOND
    end = start + 60 * SECOND
    cohort = {pts for pts, time, _ in host["capture"] if start <= time < end}
    steady = [digest for pts, digest in zip(received_pts, hashes) if pts in cohort]
    distinct = len(set(steady))
    print(f"Decoded {len(hashes)} authenticated pictures in presentation order.")
    print(f"Steady: {len(steady)} decoded pictures, {distinct} unique pixel hashes, "
          f"{len(steady) - distinct} repeated rasters, {distinct / 60:.2f} unique FPS.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("trace_directory", type=Path)
    args = parser.parse_args()
    verify(args.trace_directory)
