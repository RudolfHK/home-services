"""
Software-only fake spectrum generator.

Produces RTL-SDR-style power readings for testing monitor logic and UI
without any physical SDR hardware connected.

Modes:
  normal     — random noise floor (~-90 dBm), occasional small spikes
  congested  — several random spikes across the band
  jammed     — flat elevated floor (+30 dB above baseline everywhere)
"""

from __future__ import annotations

import random
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    NOISE_FLOOR_DBM,
    ALERT_THRESHOLD_DB,
    STRONG_TX_THRESHOLD_DB,
    BT_FREQ_MIN_MHZ,
    BT_CHANNEL_COUNT,
    SWEEP_STEP_MHZ,
)

SpectrumDict = dict[int, float]

_SWEEP_FREQS: list[int] = list(range(BT_FREQ_MIN_MHZ, BT_FREQ_MIN_MHZ + BT_CHANNEL_COUNT * 2, SWEEP_STEP_MHZ))


def generate_baseline() -> SpectrumDict:
    """
    Return a plausible baseline spectrum (noise floor with small random variation).
    Mirrors the output format of monitor/baseline_scan.py.
    """
    return {
        freq: NOISE_FLOOR_DBM + random.gauss(0, 1.5)
        for freq in _SWEEP_FREQS
    }


def generate_normal(baseline: SpectrumDict | None = None) -> SpectrumDict:
    """
    Normal spectrum: noise floor + occasional 1–5 dB bumps (no alerts).
    Returns {freq_mhz: power_dbm}.
    """
    if baseline is None:
        baseline = generate_baseline()
    result: SpectrumDict = {}
    for freq in _SWEEP_FREQS:
        base = baseline.get(freq, NOISE_FLOOR_DBM)
        # Small random variation around baseline
        delta = random.gauss(0, 2.0)
        result[freq] = base + delta
    return result


def generate_congested(
    baseline: SpectrumDict | None = None,
    n_spikes: int = 6,
) -> SpectrumDict:
    """
    Congested spectrum: several random frequency spikes at ALERT_THRESHOLD_DB+.
    Simulates multiple active devices (e.g. BT + Wi-Fi overlap).
    """
    if baseline is None:
        baseline = generate_baseline()
    result = generate_normal(baseline)

    spike_freqs = random.sample(_SWEEP_FREQS, min(n_spikes, len(_SWEEP_FREQS)))
    for freq in spike_freqs:
        result[freq] = (baseline.get(freq, NOISE_FLOOR_DBM)
                        + ALERT_THRESHOLD_DB
                        + random.uniform(2, 10))
    return result


def generate_jammed(baseline: SpectrumDict | None = None) -> SpectrumDict:
    """
    Jammed spectrum: entire band raised ~30 dB above baseline with low variance.
    Tests whether live_monitor / detect_jamming raises 🚨 STRONG TX alerts.
    """
    if baseline is None:
        baseline = generate_baseline()
    return {
        freq: baseline.get(freq, NOISE_FLOOR_DBM) + STRONG_TX_THRESHOLD_DB + random.gauss(0, 0.5)
        for freq in _SWEEP_FREQS
    }


def get_spectrum(mode: str = "normal", baseline: SpectrumDict | None = None) -> SpectrumDict:
    """
    Convenience function: return a spectrum for the given mode string.
    Valid modes: 'normal', 'congested', 'jammed'.
    """
    if baseline is None:
        baseline = generate_baseline()
    dispatch = {
        "normal": generate_normal,
        "congested": generate_congested,
        "jammed": generate_jammed,
    }
    if mode not in dispatch:
        raise ValueError(f"Unknown mode '{mode}'. Choose from: {list(dispatch)}")
    return dispatch[mode](baseline)


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Generate mock spectrum data")
    parser.add_argument("--mode", choices=["normal", "congested", "jammed"],
                        default="normal", help="Spectrum mode")
    parser.add_argument("--count", type=int, default=5,
                        help="Number of spectrum snapshots to generate")
    args = parser.parse_args()

    baseline = generate_baseline()
    print(f"Mode: {args.mode}  |  {len(baseline)} frequency points")
    for i in range(args.count):
        spectrum = get_spectrum(args.mode, baseline)
        avg = sum(spectrum.values()) / len(spectrum)
        mx = max(spectrum.values())
        print(f"  Snapshot {i+1}: avg={avg:.1f} dBm  peak={mx:.1f} dBm")
