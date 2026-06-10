"""
Phase 1: Single-tone test.

Emits a carrier on one BT channel and verifies the monitor detects a spike
on that frequency (Δ dB > ALERT_THRESHOLD_DB).

In --mock mode: injects a synthetic single-spike spectrum via mock_jammer,
then checks that live_monitor's delta computation produces the expected alert.

Usage:
    python test/test_single_tone.py --mock
    python test/test_single_tone.py  # requires HackRF + RTL-SDR
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

TEST_CHANNEL = 38  # BT channel 38 = 2440 MHz (advertising channel — easy to verify)
EXPECTED_MIN_DELTA_DB = ALERT_THRESHOLD_DB


def run_phase1(mock: bool = True) -> bool:
    """
    Returns True on PASS, False on FAIL.
    """
    print("\n── Phase 1: Single Tone ──")
    print(f"  Target: BT channel {TEST_CHANNEL} ({bt_channel_to_mhz(TEST_CHANNEL)} MHz)")
    print(f"  Expected Δ dB ≥ {EXPECTED_MIN_DELTA_DB}")

    baseline = generate_baseline()

    if mock:
        # Inject a 30 dB spike at the test channel
        current = inject_single_spike(baseline, spike_mhz=bt_channel_to_mhz(TEST_CHANNEL),
                                      spike_db=STRONG_TX_THRESHOLD_DB)
    else:
        # Real hardware path
        from emitter.emit_single_channel import emit_single_channel
        from monitor.live_monitor import _sweep_real
        from rtlsdr import RtlSdr
        from config.settings import SAFE_BENCH_GAIN_DB

        emit_single_channel(
            bt_channel=TEST_CHANNEL,
            tx_gain_db=SAFE_BENCH_GAIN_DB,
            duration_sec=3,
            mock=False,
        )
        sdr = RtlSdr()
        from utils.frequency_utils import freq_range_mhz
        current = _sweep_real(sdr, freq_range_mhz())
        sdr.close()

    deltas = delta_spectrum(current, baseline)
    target_freq = bt_channel_to_mhz(TEST_CHANNEL)
    observed_delta = deltas.get(target_freq, 0.0)

    print(f"  Observed Δ dB at {target_freq} MHz: {observed_delta:+.1f} dB")

    passed = observed_delta >= EXPECTED_MIN_DELTA_DB
    print(f"  Result: {'PASS ✓' if passed else 'FAIL ✗'}")
    return passed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Phase 1: Single tone detection test")
    parser.add_argument("--mock", action="store_true", help="Software-only (no hardware)")
    args = parser.parse_args()
    ok = run_phase1(mock=args.mock)
    sys.exit(0 if ok else 1)
