"""
Synthetic jamming data injector.

Raises all channels 25–35 dB above a supplied baseline so that the
live monitor pipeline's detect_jamming() and alert thresholds can be
validated without a real transmitter.
"""

from __future__ import annotations

import random
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    NOISE_FLOOR_DBM,
    BT_FREQ_MIN_MHZ,
    BT_CHANNEL_COUNT,
    SWEEP_STEP_MHZ,
)
from mock.mock_spectrum import generate_baseline, SpectrumDict

# How much to lift the floor above baseline (dB) — keep std low to look like a jammer
_JAM_LIFT_MIN_DB: float = 25.0
_JAM_LIFT_MAX_DB: float = 35.0
_JAM_VARIANCE_DB: float = 0.8   # very flat spectrum → low std → jamming signature


def inject_jamming(baseline: SpectrumDict | None = None) -> SpectrumDict:
    """
    Return a spectrum dict with every channel elevated by 25–35 dB above
    *baseline* with minimal variance (flat-floor jamming signature).
    """
    if baseline is None:
        baseline = generate_baseline()

    lift = random.uniform(_JAM_LIFT_MIN_DB, _JAM_LIFT_MAX_DB)
    return {
        freq: baseline.get(freq, NOISE_FLOOR_DBM) + lift + random.gauss(0, _JAM_VARIANCE_DB)
        for freq in baseline
    }


def inject_partial_jamming(
    baseline: SpectrumDict | None = None,
    start_mhz: int = 2420,
    stop_mhz: int = 2460,
) -> SpectrumDict:
    """
    Raise only the sub-band start_mhz–stop_mhz.
    Useful for testing narrow-band jammer detection.
    """
    if baseline is None:
        baseline = generate_baseline()

    lift = random.uniform(_JAM_LIFT_MIN_DB, _JAM_LIFT_MAX_DB)
    result: SpectrumDict = {}
    for freq, base_power in baseline.items():
        if start_mhz <= freq <= stop_mhz:
            result[freq] = base_power + lift + random.gauss(0, _JAM_VARIANCE_DB)
        else:
            result[freq] = base_power + random.gauss(0, 1.5)
    return result


def inject_single_spike(
    baseline: SpectrumDict | None = None,
    spike_mhz: int = 2440,
    spike_db: float = 30.0,
) -> SpectrumDict:
    """
    Single-channel spike — should NOT trigger the flat-floor jamming detector
    but should trigger the per-channel STRONG TX alert.
    Used for negative test: is_jammed must be False.
    """
    if baseline is None:
        baseline = generate_baseline()

    result: SpectrumDict = {}
    for freq, base_power in baseline.items():
        if freq == spike_mhz:
            result[freq] = base_power + spike_db
        else:
            result[freq] = base_power + random.gauss(0, 1.5)
    return result


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse
    from utils.signal_math import detect_jamming

    parser = argparse.ArgumentParser(description="Simulate jamming data for detector testing")
    parser.add_argument("--mode", choices=["full", "partial", "spike"],
                        default="full", help="Jamming mode to simulate")
    args = parser.parse_args()

    baseline = generate_baseline()

    if args.mode == "full":
        spectrum = inject_jamming(baseline)
        label = "Full-band jamming"
    elif args.mode == "partial":
        spectrum = inject_partial_jamming(baseline)
        label = "Partial-band jamming (2420–2460 MHz)"
    else:
        spectrum = inject_single_spike(baseline)
        label = "Single spike (should NOT trigger jam detector)"

    result = detect_jamming(spectrum)
    avg = sum(spectrum.values()) / len(spectrum)

    print(f"\n{label}")
    print(f"  avg_power        : {result['avg_power']:.1f} dBm")
    print(f"  std_power        : {result['std_power']:.2f} dB")
    print(f"  elevated_channels: {result['elevated_channels']}")
    print(f"  is_jammed        : {result['is_jammed']}")

    if args.mode == "spike":
        assert not result["is_jammed"], "FAIL: single spike incorrectly flagged as jammed"
        print("  ✓ Correctly NOT flagged as jammed (single spike)")
    else:
        assert result["is_jammed"], "FAIL: jamming signal not detected"
        print("  ✓ Jamming correctly detected")
