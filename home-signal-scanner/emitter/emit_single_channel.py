"""
Single-channel constant-carrier emitter.

Transmits a constant IQ carrier on a single Bluetooth channel for a
specified duration using HackRF One.

LEGAL NOTICE: All transmissions must use a 50 Ω dummy load or shielded
Faraday enclosure. Max 20 dBm EIRP (ETSI EN 300 328). legal_guard is
called before any transmission — do not bypass it.

Usage:
    python emit_single_channel.py --channel 38 --gain 10 --duration 5
    python emit_single_channel.py --channel 0 --gain 5 --duration 2 --mock
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    BT_CHANNEL_COUNT,
    MAX_TX_GAIN_DB,
    SAFE_BENCH_GAIN_DB,
    HACKRF_SAMPLE_RATE,
    HACKRF_AMP_ENABLED,
    CARRIER_SIGNAL_PATH,
)
from emitter.legal_guard import check_legal_params, LegalViolationError
from utils.frequency_utils import bt_channel_to_mhz
from utils.signal_math import generate_iq_carrier, iq_to_bytes

log = logging.getLogger(__name__)


def emit_single_channel(
    bt_channel: int,
    tx_gain_db: float,
    duration_sec: float,
    antenna_connected: bool = False,
    mock: bool = False,
) -> None:
    """
    Transmit a constant carrier on *bt_channel* at *tx_gain_db* for *duration_sec*.

    MUST call legal_guard before any hackrf_transfer invocation.
    """
    # ── 1. Legal check — aborts with LegalViolationError if limits exceeded ──
    check_legal_params(
        gain_db=tx_gain_db,
        duty_cycle=1.0,     # constant carrier = 100% during transmission
        antenna_connected=antenna_connected,
    )

    if not (0 <= bt_channel < BT_CHANNEL_COUNT):
        raise ValueError(f"BT channel must be 0–{BT_CHANNEL_COUNT - 1}")

    freq_mhz = bt_channel_to_mhz(bt_channel)
    freq_hz = freq_mhz * 1_000_000

    print(f"\n{'=' * 50}")
    print(f"  Single Channel TX")
    print(f"  Channel   : {bt_channel} ({freq_mhz} MHz)")
    print(f"  Gain      : {tx_gain_db} dBm")
    print(f"  Duration  : {duration_sec} s")
    print(f"  Antenna   : {'⚠️  LIVE — use dummy load!' if antenna_connected else '✓ dummy load / shielded'}")
    print(f"  Amp       : {'ON' if HACKRF_AMP_ENABLED else 'OFF'} (always OFF for bench use)")
    print(f"{'=' * 50}\n")

    # ── 2. Generate carrier IQ samples ────────────────────────────────────────
    iq_data = generate_iq_carrier(
        freq_offset_hz=0.0,       # tune to exact channel centre via hackrf_transfer -f
        sample_rate=HACKRF_SAMPLE_RATE,
        duration_sec=duration_sec,
    )
    carrier_bytes = iq_to_bytes(iq_data)

    if mock:
        print(f"  [MOCK] Would write {len(carrier_bytes)} bytes to {CARRIER_SIGNAL_PATH}")
        print(f"  [MOCK] Would run: hackrf_transfer -t {CARRIER_SIGNAL_PATH} "
              f"-f {freq_hz} -x {int(tx_gain_db)} -s {HACKRF_SAMPLE_RATE} -a {HACKRF_AMP_ENABLED}")
        print("  [MOCK] Transmission complete (simulated).")
        return

    # ── 3. Write IQ file ───────────────────────────────────────────────────────
    with open(CARRIER_SIGNAL_PATH, "wb") as f:
        f.write(carrier_bytes)
    log.info("Wrote %d bytes to %s", len(carrier_bytes), CARRIER_SIGNAL_PATH)

    # ── 4. Run hackrf_transfer ─────────────────────────────────────────────────
    cmd = [
        "hackrf_transfer",
        "-t", CARRIER_SIGNAL_PATH,           # transmit from file
        "-f", str(freq_hz),                  # centre frequency
        "-x", str(int(tx_gain_db)),          # TX VGA gain
        "-s", str(HACKRF_SAMPLE_RATE),       # sample rate
        "-a", str(HACKRF_AMP_ENABLED),       # amp: 0 = OFF
        "-R",                                 # repeat until duration expires
    ]

    print(f"  Running: {' '.join(cmd)}\n")
    try:
        proc = subprocess.run(
            cmd,
            timeout=duration_sec + 5,
            check=True,
        )
    except FileNotFoundError:
        print("ERROR: hackrf_transfer not found. Install: sudo apt install hackrf", file=sys.stderr)
        sys.exit(1)
    except subprocess.TimeoutExpired:
        print("Transmission timed out.")
    except subprocess.CalledProcessError as e:
        print(f"hackrf_transfer failed (exit {e.returncode}). Is HackRF connected?", file=sys.stderr)
        sys.exit(1)

    print("\n  ✓ Transmission complete.")


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Emit a single carrier on one Bluetooth channel (HackRF)"
    )
    parser.add_argument("--channel", type=int, default=38,
                        help=f"BT channel 0–{BT_CHANNEL_COUNT - 1} (default: 38 = 2440 MHz)")
    parser.add_argument("--gain", type=float, default=SAFE_BENCH_GAIN_DB,
                        help=f"TX gain dBm, max {MAX_TX_GAIN_DB} (default: {SAFE_BENCH_GAIN_DB})")
    parser.add_argument("--duration", type=float, default=5.0,
                        help="Transmission duration in seconds (default: 5)")
    parser.add_argument("--antenna", action="store_true",
                        help="Acknowledge that a live antenna is connected (not recommended)")
    parser.add_argument("--mock", action="store_true",
                        help="Dry-run mode — no hardware required")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)

    try:
        emit_single_channel(
            bt_channel=args.channel,
            tx_gain_db=args.gain,
            duration_sec=args.duration,
            antenna_connected=args.antenna,
            mock=args.mock,
        )
    except LegalViolationError:
        sys.exit(1)
