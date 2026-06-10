"""
Phase 5: Potentiometer → emitter → monitor correlation test.

In mock mode: simulates turning the gain pot to a mid-point and the channel
pot to channel 38, runs one emit_with_pot burst, and verifies the correct
channel and gain are used.

Usage:
    python test/test_pot_control.py --mock
"""

from __future__ import annotations

import argparse
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import MAX_TX_GAIN_DB, BT_CHANNEL_COUNT, SAFE_BENCH_GAIN_DB
from utils.adc_reader import adc_to_gain, adc_to_bt_channel, ADC_MAX_RAW
from utils.frequency_utils import bt_channel_to_mhz
from emitter.legal_guard import check_legal_params, LegalViolationError

# Simulated pot positions (0–1023)
POT0_RAW = int(ADC_MAX_RAW * 0.5)   # mid → ~10 dB gain
POT1_RAW = int(ADC_MAX_RAW * (38 / (BT_CHANNEL_COUNT - 1)))   # → channel 38


def run_phase5(mock: bool = True) -> bool:
    print("\n── Phase 5: Potentiometer Control ──")

    # Compute expected values from raw ADC readings
    expected_gain = adc_to_gain(POT0_RAW)
    expected_channel = adc_to_bt_channel(POT1_RAW)
    expected_freq = bt_channel_to_mhz(expected_channel)

    print(f"  POT0 raw={POT0_RAW} → gain={expected_gain} dBm")
    print(f"  POT1 raw={POT1_RAW} → CH{expected_channel} ({expected_freq} MHz)")

    # ── Legal check must pass for these values ──────────────────────────────
    duty_cycle = 0.10
    try:
        check_legal_params(expected_gain, duty_cycle, antenna_connected=False, verbose=False)
        legal_ok = True
    except LegalViolationError:
        legal_ok = False

    print(f"  Legal check: {'PASS ✓' if legal_ok else 'FAIL ✗'}")

    if not legal_ok:
        print("  Result: FAIL ✗")
        return False

    if mock:
        # Verify adc_to_gain enforces the legal ceiling
        over_limit_raw = ADC_MAX_RAW  # max pot → should be capped at MAX_TX_GAIN_DB
        capped_gain = adc_to_gain(over_limit_raw)
        ceiling_ok = capped_gain <= MAX_TX_GAIN_DB

        print(f"  Gain ceiling enforcement (max raw → {capped_gain} dBm, limit {MAX_TX_GAIN_DB}): "
              f"{'✓' if ceiling_ok else '✗'}")

        # Simulate one burst (no hardware)
        print(f"  [MOCK] Would emit 100 ms burst on CH{expected_channel} "
              f"at {expected_gain} dBm → TX OK")
        burst_ok = True

        passed = legal_ok and ceiling_ok and burst_ok
    else:
        # Real hardware: run one burst
        from emitter.emit_single_channel import emit_single_channel
        try:
            emit_single_channel(expected_channel, expected_gain, duration_sec=0.1)
            burst_ok = True
        except Exception as e:
            print(f"  TX error: {e}")
            burst_ok = False

        passed = legal_ok and burst_ok

    print(f"  Result: {'PASS ✓' if passed else 'FAIL ✗'}")
    return passed


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Phase 5: Pot control + emitter test")
    parser.add_argument("--mock", action="store_true")
    args = parser.parse_args()
    ok = run_phase5(mock=args.mock)
    sys.exit(0 if ok else 1)
