"""
Master test runner — runs all 5 phases in order and prints a summary table.

In --mock mode the full pipeline runs without any physical hardware.

Usage:
    python test/test_sequence.py --mock
    python test/test_sequence.py           # requires HackRF + RTL-SDR
"""

from __future__ import annotations

import argparse
import sys
import time
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from test.test_single_tone import run_phase1
from test.test_channel_move import run_phase2
from test.test_power_sweep import run_phase3
from test.test_multi_channel import run_phase4
from test.test_pot_control import run_phase5

# Each entry: (phase_number, name, run_function)
PHASES = [
    (1, "Single tone — spike detection",         run_phase1),
    (2, "Channel move — tracker follows signal", run_phase2),
    (3, "Power sweep — monotonic delta scaling", run_phase3),
    (4, "Multi-channel — discrete spike count",  run_phase4),
    (5, "Pot control — ADC → TX → monitor",      run_phase5),
]


def run_sequence(mock: bool = False) -> int:
    """
    Run all phases. Returns the number of failures (0 = all passed).
    """
    print("\n" + "=" * 60)
    print(f"  RF Monitor Test Sequence  {'[MOCK]' if mock else '[HARDWARE]'}")
    print("=" * 60)

    results: list[tuple[int, str, bool, float]] = []

    for phase_num, name, fn in PHASES:
        t0 = time.time()
        try:
            passed = fn(mock=mock)
        except Exception as e:
            print(f"  EXCEPTION in Phase {phase_num}: {e}")
            passed = False
        elapsed = time.time() - t0
        results.append((phase_num, name, passed, elapsed))

    # ── Summary table ──────────────────────────────────────────────────────
    print("\n" + "=" * 60)
    print("  TEST SUMMARY")
    print("=" * 60)
    print(f"  {'#':>2}  {'Phase':42s}  {'Result':8s}  {'Time':>6s}")
    print(f"  {'-'*2}  {'-'*42}  {'-'*8}  {'-'*6}")

    failures = 0
    for phase_num, name, passed, elapsed in results:
        status = "PASS ✓" if passed else "FAIL ✗"
        if not passed:
            failures += 1
        print(f"  {phase_num:>2}  {name:42s}  {status:8s}  {elapsed:.2f}s")

    print("=" * 60)
    total = len(results)
    print(f"  Passed: {total - failures}/{total}")
    if failures == 0:
        print("  ✓ All tests passed.")
    else:
        print(f"  ✗ {failures} test(s) failed.")
    print("=" * 60 + "\n")

    return failures


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Run the full 5-phase RF monitor test sequence"
    )
    parser.add_argument("--mock", action="store_true",
                        help="Software-only mode — no hardware required")
    args = parser.parse_args()

    failures = run_sequence(mock=args.mock)
    sys.exit(0 if failures == 0 else 1)
