"""
Baseline spectrum capture.

Sweeps 2402–2480 MHz in 2 MHz steps using the RTL-SDR V4 dongle,
reads 64K samples per frequency, computes power via FFT, and saves
the result to baseline.json.

Run this with ALL transmitters OFF to capture the clean noise floor.

Usage:
    python monitor/baseline_scan.py
    python monitor/baseline_scan.py --mock           # no hardware
    python monitor/baseline_scan.py --output my_baseline.json
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    BASELINE_JSON_PATH,
    SWEEP_STEP_MHZ,
    SWEEP_SAMPLE_COUNT,
    RTL_SAMPLE_RATE,
    NOISE_FLOOR_DBM,
)
from utils.frequency_utils import freq_range_mhz
from utils.signal_math import compute_power_dbm

log = logging.getLogger(__name__)

try:
    from rtlsdr import RtlSdr
    _RTLSDR_AVAILABLE = True
except ImportError:
    _RTLSDR_AVAILABLE = False
    log.warning("pyrtlsdr not installed — RTL-SDR unavailable")


def _read_power_real(sdr, freq_mhz: int) -> float:
    """Read SWEEP_SAMPLE_COUNT IQ samples from the RTL-SDR and return power in dBm."""
    sdr.center_freq = freq_mhz * 1e6
    samples = sdr.read_samples(SWEEP_SAMPLE_COUNT)
    return compute_power_dbm(samples)


def _read_power_mock(freq_mhz: int) -> float:
    """Return a fake noise-floor reading with small random variation."""
    import random
    return NOISE_FLOOR_DBM + random.gauss(0, 1.5)


def capture_baseline(output_path: str = BASELINE_JSON_PATH, mock: bool = False) -> dict[str, float]:
    """
    Sweep the BT 2.4 GHz band and save baseline.json.

    Returns {freq_mhz_str: power_dbm} dict (keys are strings for JSON compatibility).
    """
    freqs = freq_range_mhz()
    print(f"\nBaseline scan: {len(freqs)} frequencies "
          f"({freqs[0]}–{freqs[-1]} MHz, step {SWEEP_STEP_MHZ} MHz)")
    print("Ensure all transmitters are OFF.\n")

    baseline: dict[str, float] = {}

    if not mock:
        if not _RTLSDR_AVAILABLE:
            print("ERROR: pyrtlsdr not installed. Use --mock for testing.", file=sys.stderr)
            sys.exit(1)
        try:
            sdr = RtlSdr()
            sdr.sample_rate = RTL_SAMPLE_RATE
            sdr.gain = "auto"
        except Exception as e:
            print(f"ERROR: Cannot open RTL-SDR: {e}\nUse --mock for testing.", file=sys.stderr)
            sys.exit(1)
    else:
        sdr = None

    try:
        for i, freq in enumerate(freqs):
            if mock:
                power = _read_power_mock(freq)
            else:
                power = _read_power_real(sdr, freq)

            baseline[str(freq)] = power
            bar = "█" * max(0, int((power - NOISE_FLOOR_DBM + 10) * 2))
            print(f"  {freq:4d} MHz  {power:6.1f} dBm  {bar[:40]}", flush=True)

    finally:
        if sdr is not None:
            sdr.close()

    # ── Save ───────────────────────────────────────────────────────────────
    with open(output_path, "w") as f:
        json.dump(baseline, f, indent=2)
    print(f"\nBaseline saved to: {output_path}")

    avg = sum(baseline.values()) / len(baseline)
    mn = min(baseline.values())
    mx = max(baseline.values())
    print(f"Noise floor stats: avg={avg:.1f}  min={mn:.1f}  max={mx:.1f} dBm")

    return baseline


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Capture RTL-SDR baseline spectrum")
    parser.add_argument("--output", default=BASELINE_JSON_PATH,
                        help=f"Output JSON file (default: {BASELINE_JSON_PATH})")
    parser.add_argument("--mock", action="store_true",
                        help="Use fake readings instead of real RTL-SDR")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)
    capture_baseline(output_path=args.output, mock=args.mock)
