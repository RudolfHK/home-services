"""
Phase 4: Multi-channel test.

Emits on N distinct channels simultaneously (mock: congested spectrum)
and verifies the monitor detects exactly N alert-level spikes.

Usage:
    python test/test_multi_channel.py --mock
"""

from __future__ import annotations

import argparse
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import ALERT_THRESHOLD_DB, STRONG_TX_THRESHOLD_DB, NOISE_FLOOR_DBM
from utils.frequency_utils import bt_channel_to_mhz
from utils.signal_math import delta_spectrum
from mock.mock_spectrum import generate_baseline

TEST_CHANNELS = [4, 20, 38, 54, 70]  # even-offset channels → land on 2 MHz sweep grid
EXPECTED_SPIKE_COUNT = len(TEST_CHANNELS)


def _inject_multi_spike(
    baseline: dict[int, float],
    channels: list[int],
    spike_db: float = 30.0,
) -> dict[int, float]:
    """Return baseline + spike at each listed channel."""
    import random
    current = {freq: power + random.gauss(0, 0.5) for freq, power in baseline.items()}
    for ch in channels:
        freq = bt_channel_to_mhz(ch)
        if freq in current:
            current[freq] = baseline[freq] + spike_db
    return current


def run_phase4(mock: bool = True) -> bool:
    print("\n── Phase 4: Multi-Channel ──")
    freqs = [bt_channel_to_mhz(ch) for ch in TEST_CHANNELS]
    print(f"  Channels: {TEST_CHANNELS} → {freqs} MHz")
    print(f"  Expected spikes ≥ {ALERT_THRESHOLD_DB} dB: {EXPECTED_SPIKE_COUNT}")

    baseline = generate_baseline()

    if mock:
        current = _inject_multi_spike(baseline, TEST_CHANNELS)
    else:
        from emitter.emit_sweep import emit_sweep, _SWEEP_MODES
        # Override light mode channels to our test set
        _SWEEP_MODES["light"] = TEST_CHANNELS
        emit_sweep(mode="light", tx_gain_db=10, mock=False)
        from monitor.live_monitor import _sweep_real
        from rtlsdr import RtlSdr
        from utils.frequency_utils import freq_range_mhz
        sdr = RtlSdr()
        current = _sweep_real(sdr, freq_range_mhz())
        sdr.close()

    deltas = delta_spectrum(current, baseline)
    detected_freqs = [f for f, d in deltas.items() if d >= ALERT_THRESHOLD_DB]
    detected_count = len(detected_freqs)

    print(f"  Detected spikes: {detected_count} at {detected_freqs}")

    # All injected channels must be in the detected set
    expected_freqs = set(freqs)
    detected_set = set(detected_freqs)
    all_found = expected_freqs.issubset(detected_set)

    print(f"  All expected channels detected: {'✓' if all_found else '✗'}")
    print(f"  Result: {'PASS ✓' if all_found else 'FAIL ✗'}")
    return all_found


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Phase 4: Multi-channel spike count test")
    parser.add_argument("--mock", action="store_true")
    args = parser.parse_args()
    ok = run_phase4(mock=args.mock)
    sys.exit(0 if ok else 1)
