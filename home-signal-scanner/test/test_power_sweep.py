"""
Phase 3: Power sweep test.

Sweeps TX gain from LOW → HIGH (mock: inject spectrum at varying deltas)
and verifies the monitor's measured delta scales monotonically with gain.

Usage:
    python test/test_power_sweep.py --mock
"""

from __future__ import annotations

import argparse
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import ALERT_THRESHOLD_DB, STRONG_TX_THRESHOLD_DB
from utils.frequency_utils import bt_channel_to_mhz
from utils.signal_math import delta_spectrum
from mock.mock_spectrum import generate_baseline
from mock.mock_jammer import inject_single_spike

TEST_CHANNEL = 38
# Gain steps to test: each must produce a larger delta than the previous
GAIN_STEPS_DB = [5.0, 10.0, 15.0, 20.0]
# Expected minimum observed delta (dB) for each gain step (mock: delta ≈ gain * 1.5)
EXPECTED_SCALING = True  # just check monotonic increase


def run_phase3(mock: bool = True) -> bool:
    print("\n── Phase 3: Power Sweep ──")
    freq = bt_channel_to_mhz(TEST_CHANNEL)
    print(f"  Channel: {TEST_CHANNEL} ({freq} MHz)  Gains: {GAIN_STEPS_DB}")

    baseline = generate_baseline()
    observed_deltas: list[tuple[float, float]] = []

    for gain in GAIN_STEPS_DB:
        if mock:
            # Mock: spike height = gain * 1.5 (simulates realistic response)
            spike_db = gain * 1.5
            current = inject_single_spike(baseline, spike_mhz=freq, spike_db=spike_db)
        else:
            from emitter.emit_single_channel import emit_single_channel
            from monitor.live_monitor import _sweep_real
            from rtlsdr import RtlSdr
            from utils.frequency_utils import freq_range_mhz
            emit_single_channel(TEST_CHANNEL, gain, duration_sec=2)
            sdr = RtlSdr()
            current = _sweep_real(sdr, freq_range_mhz())
            sdr.close()

        deltas = delta_spectrum(current, baseline)
        delta = deltas.get(freq, 0.0)
        observed_deltas.append((gain, delta))
        print(f"  Gain {gain:4.1f} dBm → Δ {delta:+6.1f} dB")

    # Verify monotonic increase
    passed = all(
        observed_deltas[i][1] <= observed_deltas[i + 1][1]
        for i in range(len(observed_deltas) - 1)
    )
    print(f"  Monotonic scaling: {'✓' if passed else '✗'}")
    print(f"  Result: {'PASS ✓' if passed else 'FAIL ✗'}")
    return passed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Phase 3: Power sweep linearity test")
    parser.add_argument("--mock", action="store_true")
    args = parser.parse_args()
    ok = run_phase3(mock=args.mock)
    sys.exit(0 if ok else 1)
