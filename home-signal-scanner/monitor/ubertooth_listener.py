"""
Ubertooth One BT packet capture and hop pattern analyser.

Wraps 'ubertooth-rx' subprocess, parses stdout, detects frequency-hopping
patterns, and alerts on packet-per-second spikes.

Logs to ubertooth_log.jsonl with timestamps.

Usage:
    python monitor/ubertooth_listener.py
    python monitor/ubertooth_listener.py --mock
    python monitor/ubertooth_listener.py --mock --duration 10
"""

from __future__ import annotations

import argparse
import json
import logging
import re
import subprocess
import sys
import threading
import time
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import UBERTOOTH_LOG_PATH
from utils.frequency_utils import bt_channel_to_mhz

log = logging.getLogger(__name__)

# Packets-per-second threshold above which an alert fires
PPS_SPIKE_THRESHOLD: int = 50

# Regex for ubertooth-rx output lines
# Example: "systime=1719000000 freq=2426 LAP=0xaabbcc"
_RX_RE = re.compile(r"freq=(\d+).*LAP=(0x[0-9A-Fa-f]+)", re.IGNORECASE)


class UbertoothListener:
    """
    Wraps ubertooth-rx and publishes parsed packet events.
    """

    def __init__(self, log_path: str = UBERTOOTH_LOG_PATH) -> None:
        self.log_path = log_path
        self._proc: subprocess.Popen | None = None
        self._packets_this_second: int = 0
        self._freq_counts: dict[int, int] = {}
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self._pps_alert_fired = False

    def start(self) -> None:
        """Start ubertooth-rx in a background subprocess."""
        try:
            self._proc = subprocess.Popen(
                ["ubertooth-rx", "-U0"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            log.info("ubertooth-rx started (PID %d)", self._proc.pid)
        except FileNotFoundError:
            log.error("ubertooth-rx not found — install: sudo apt install ubertooth")
            self._proc = None

    def stop(self) -> None:
        self._stop.set()
        if self._proc:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self._proc.kill()

    def _parse_line(self, line: str) -> dict | None:
        m = _RX_RE.search(line)
        if not m:
            return None
        freq_mhz = int(m.group(1))
        lap = m.group(2)
        return {
            "timestamp": time.time(),
            "freq_mhz": freq_mhz,
            "lap": lap,
        }

    def _log_event(self, event: dict) -> None:
        with open(self.log_path, "a") as f:
            f.write(json.dumps(event) + "\n")

    def listen(self, duration: float | None = None) -> list[dict]:
        """
        Read ubertooth-rx output for *duration* seconds (None = until Ctrl+C).
        Returns list of parsed packet events.
        """
        packets: list[dict] = []
        deadline = time.time() + duration if duration else None
        t_second_start = time.time()
        pps_count = 0

        stream = self._proc.stdout if self._proc else None

        while not self._stop.is_set():
            if deadline and time.time() > deadline:
                break
            if stream is None:
                time.sleep(0.1)
                continue

            line = stream.readline()
            if not line:
                break

            event = self._parse_line(line.strip())
            if event is None:
                continue

            packets.append(event)
            self._log_event(event)
            pps_count += 1

            freq = event["freq_mhz"]
            with self._lock:
                self._freq_counts[freq] = self._freq_counts.get(freq, 0) + 1

            # Packets-per-second spike detection (reset every second)
            elapsed = time.time() - t_second_start
            if elapsed >= 1.0:
                pps = pps_count / elapsed
                if pps >= PPS_SPIKE_THRESHOLD:
                    print(f"\n⚠️  PPS spike: {pps:.0f} packets/s (threshold: {PPS_SPIKE_THRESHOLD})")
                pps_count = 0
                t_second_start = time.time()

        return packets

    def get_hop_pattern(self) -> dict[int, int]:
        """Return {freq_mhz: packet_count} — the observed frequency distribution."""
        with self._lock:
            return dict(self._freq_counts)


def _mock_listener(duration: float = 10.0) -> list[dict]:
    """Generate synthetic Ubertooth data for testing."""
    import random
    packets: list[dict] = []
    t_start = time.time()
    log_path = UBERTOOTH_LOG_PATH

    while time.time() - t_start < duration:
        ch = random.randint(0, 78)
        freq = bt_channel_to_mhz(ch)
        event = {
            "timestamp": time.time(),
            "freq_mhz": freq,
            "lap": hex(random.randint(0, 0xFFFFFF)),
        }
        packets.append(event)
        with open(log_path, "a") as f:
            f.write(json.dumps(event) + "\n")
        time.sleep(0.05)   # ~20 pps

    return packets


def run_listener(mock: bool = False, duration: float | None = 30.0) -> None:
    """Run the Ubertooth listener and print a summary."""
    print(f"\n── Ubertooth Listener {'[MOCK]' if mock else '[HARDWARE]'} ──")
    if duration:
        print(f"Running for {duration:.0f} s …")

    if mock:
        packets = _mock_listener(duration or 10.0)
    else:
        ul = UbertoothListener()
        ul.start()
        if ul._proc is None:
            print("ERROR: Could not start ubertooth-rx", file=sys.stderr)
            return
        try:
            packets = ul.listen(duration=duration)
        except KeyboardInterrupt:
            print("\nStopped by user.")
            packets = []
        finally:
            ul.stop()
        hop = ul.get_hop_pattern()
        print(f"\nFrequency distribution (top 10):")
        for freq, count in sorted(hop.items(), key=lambda x: -x[1])[:10]:
            print(f"  {freq} MHz: {count} packets")

    print(f"\nTotal packets captured: {len(packets)}")
    print(f"Log written to: {UBERTOOTH_LOG_PATH}")


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Ubertooth BT packet capture")
    parser.add_argument("--mock", action="store_true", help="Use mock data (no hardware)")
    parser.add_argument("--duration", type=float, default=30.0,
                        help="Listen duration in seconds (default: 30)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)
    run_listener(mock=args.mock, duration=args.duration)
