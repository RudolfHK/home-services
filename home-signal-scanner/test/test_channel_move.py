"""
Phase 2: Channel-move test.

Emits on channel A, then channel B; verifies the monitor tracks the move
(channel A drops, channel B rises).

In --mock mode: uses inject_single_spike on two different channels in sequence.

Usage:
    python test/test_channel_move.py --mock
"""

from __future__ import annotations

import argparse
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import ALERT_THRESHOLD_DB
from utils.frequency_utils import bt_channel_to_mhz
from utils.signal_math import delta_spectrum
from mock.mock_spectrum import generate_baseline
from mock.mock_jammer import inject_single_spike

CHANNEL_A = 10   # 2412 MHz
CHANNEL_B = 60   # 2462 MHz


def run_phase2(mock: bool = True) -> bool:
    print("\n── Phase 2: Channel Move ──")
    freq_a = bt_channel_to_mhz(CHANNEL_A)
    freq_b = bt_channel_to_mhz(CHANNEL_B)
    print(f"  A: CH{CHANNEL_A} ({freq_a} MHz)  →  B: CH{CHANNEL_B} ({freq_b} MHz)")

    baseline = generate_baseline()

    # ── Step A: transmit on channel A ────────────────────────────────────────
    if mock:
        snapshot_a = inject_single_spike(baseline, spike_mhz=freq_a, spike_db=30.0)
    else:
        from emitter.emit_single_channel import emit_single_channel
        from monitor.live_monitor import _sweep_real
        from rtlsdr import RtlSdr
        from utils.frequency_utils import freq_range_mhz
        from config.settings import SAFE_BENCH_GAIN_DB
        emit_single_channel(CHANNEL_A, SAFE_BENCH_GAIN_DB, 2)
        sdr = RtlSdr()
        snapshot_a = _sweep_real(sdr, freq_range_mhz())
        sdr.close()

    deltas_a = delta_spectrum(snapshot_a, baseline)
    delta_at_a = deltas_a.get(freq_a, 0.0)
    delta_at_b_during_a = deltas_a.get(freq_b, 0.0)

    print(f"  During A: Δ at {freq_a} MHz = {delta_at_a:+.1f} dB  "
          f"(expect ≥ {ALERT_THRESHOLD_DB})")
    print(f"  During A: Δ at {freq_b} MHz = {delta_at_b_during_a:+.1f} dB  "
          f"(expect < {ALERT_THRESHOLD_DB})")

    # ── Step B: transmit on channel B ────────────────────────────────────────
    if mock:
        snapshot_b = inject_single_spike(baseline, spike_mhz=freq_b, spike_db=30.0)
    else:
        emit_single_channel(CHANNEL_B, SAFE_BENCH_GAIN_DB, 2)
        sdr = RtlSdr()
        snapshot_b = _sweep_real(sdr, freq_range_mhz())
        sdr.close()

    deltas_b = delta_spectrum(snapshot_b, baseline)
    delta_at_a_during_b = deltas_b.get(freq_a, 0.0)
    delta_at_b = deltas_b.get(freq_b, 0.0)

    print(f"  During B: Δ at {freq_a} MHz = {delta_at_a_during_b:+.1f} dB  "
          f"(expect < {ALERT_THRESHOLD_DB})")
    print(f"  During B: Δ at {freq_b} MHz = {delta_at_b:+.1f} dB  "
          f"(expect ≥ {ALERT_THRESHOLD_DB})")

    passed = (
        delta_at_a >= ALERT_THRESHOLD_DB
        and delta_at_b_during_a < ALERT_THRESHOLD_DB
        and delta_at_a_during_b < ALERT_THRESHOLD_DB
        and delta_at_b >= ALERT_THRESHOLD_DB
    )
    print(f"  Result: {'PASS ✓' if passed else 'FAIL ✗'}")
    return passed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Phase 2: Channel move tracking test")
    parser.add_argument("--mock", action="store_true")
    args = parser.parse_args()
    ok = run_phase2(mock=args.mock)
    sys.exit(0 if ok else 1)
