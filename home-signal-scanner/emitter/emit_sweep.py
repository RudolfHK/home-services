"""
Multi-channel sweep emitter.

Hops across Bluetooth channels emitting short noise bursts.
Three modes:
  light  — 5 channels,  ~50 ms dwell
  medium — 20 channels, ~50 ms dwell
  heavy  — all 79 channels, ~50 ms dwell — REQUIRES --confirm-shielded

LEGAL NOTICE: All transmissions must use a 50 Ω dummy load or shielded
Faraday enclosure. Max 20 dBm EIRP, 10% duty cycle (ETSI EN 300 328).
legal_guard is called before every transmission burst.

Usage:
    python emit_sweep.py --mode light --gain 10 --mock
    python emit_sweep.py --mode heavy --gain 10 --confirm-shielded --mock
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys
import tempfile
import time
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    BT_CHANNEL_COUNT,
    MAX_TX_GAIN_DB,
    MAX_DUTY_CYCLE,
    SAFE_BENCH_GAIN_DB,
    HACKRF_SAMPLE_RATE,
    HACKRF_AMP_ENABLED,
)
from emitter.legal_guard import check_legal_params, LegalViolationError
from utils.frequency_utils import bt_channel_to_mhz
from utils.signal_math import generate_iq_noise, iq_to_bytes

log = logging.getLogger(__name__)

# Sweep mode definitions: {mode_name: channel_list}
_SWEEP_MODES: dict[str, list[int]] = {
    "light":  [0, 10, 20, 38, 70],
    "medium": list(range(0, 79, 4))[:20],   # every 4th channel, first 20
    "heavy":  list(range(79)),              # all 79
}

# Dwell time (ms) — on + off pair must respect 10% duty cycle
_DWELL_ON_MS: int = 50
# Off time required to stay within 10% duty cycle: on/(on+off) ≤ 0.10
# → off ≥ on * 9  → 450 ms per channel hop
_DWELL_OFF_MS: int = 450


def _duty_cycle_for_dwell(on_ms: int, off_ms: int) -> float:
    return on_ms / (on_ms + off_ms)


def emit_sweep(
    mode: str = "light",
    tx_gain_db: float = SAFE_BENCH_GAIN_DB,
    antenna_connected: bool = False,
    confirm_shielded: bool = False,
    mock: bool = False,
) -> None:
    """
    Sweep through channels in the given mode.

    Parameters
    ----------
    mode              : 'light', 'medium', or 'heavy'
    tx_gain_db        : TX gain 0–20 dBm
    antenna_connected : Pass True only if you truly have a live antenna
    confirm_shielded  : Required for 'heavy' mode (explicit acknowledgement)
    mock              : Dry-run — no hardware
    """
    if mode not in _SWEEP_MODES:
        raise ValueError(f"Unknown mode '{mode}'. Choose from: {list(_SWEEP_MODES)}")

    channels = _SWEEP_MODES[mode]
    duty_cycle = _duty_cycle_for_dwell(_DWELL_ON_MS, _DWELL_OFF_MS)

    # ── Legal check ──────────────────────────────────────────────────────────
    check_legal_params(
        gain_db=tx_gain_db,
        duty_cycle=duty_cycle,
        antenna_connected=antenna_connected,
    )

    # ── Heavy mode extra gate ─────────────────────────────────────────────────
    if mode == "heavy" and not confirm_shielded:
        print(
            "\n⚠️  HEAVY MODE sweeps all 79 Bluetooth channels.\n"
            "   This will cause significant interference if not inside\n"
            "   a shielded (Faraday) enclosure with a dummy load.\n"
            "   Add --confirm-shielded to proceed.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"\n{'=' * 55}")
    print(f"  Sweep TX — mode={mode.upper()}  channels={len(channels)}")
    print(f"  Gain: {tx_gain_db} dBm  |  On: {_DWELL_ON_MS} ms  Off: {_DWELL_OFF_MS} ms")
    print(f"  Effective duty cycle: {duty_cycle:.1%}  (limit: {MAX_DUTY_CYCLE:.0%})")
    print(f"  Antenna: {'⚠️  LIVE' if antenna_connected else '✓ dummy/shielded'}")
    print(f"{'=' * 55}\n")

    # Pre-generate one block of IQ noise (reused for all channels)
    iq = generate_iq_noise(
        sample_rate=HACKRF_SAMPLE_RATE,
        duration_sec=_DWELL_ON_MS / 1000.0,
    )
    noise_bytes = iq_to_bytes(iq)

    for idx, ch in enumerate(channels):
        freq_mhz = bt_channel_to_mhz(ch)
        freq_hz = freq_mhz * 1_000_000

        print(f"  [{idx + 1:2d}/{len(channels)}] CH {ch:2d} ({freq_mhz} MHz) "
              f"gain={tx_gain_db} dBm  ...", end="", flush=True)

        if mock:
            time.sleep(_DWELL_ON_MS / 1000.0)
            print(" [MOCK OK]")
        else:
            # Write IQ to a temp file (overwrite each iteration)
            with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
                f.write(noise_bytes)
                tmp_path = f.name

            cmd = [
                "hackrf_transfer",
                "-t", tmp_path,
                "-f", str(freq_hz),
                "-x", str(int(tx_gain_db)),
                "-s", str(HACKRF_SAMPLE_RATE),
                "-a", str(HACKRF_AMP_ENABLED),
            ]
            try:
                subprocess.run(cmd, timeout=(_DWELL_ON_MS / 1000.0) + 2, check=True,
                               capture_output=True)
                print(" OK")
            except subprocess.CalledProcessError:
                print(" FAILED (HackRF error)")
            except subprocess.TimeoutExpired:
                print(" timeout")
            except FileNotFoundError:
                print("\nERROR: hackrf_transfer not found.", file=sys.stderr)
                sys.exit(1)
            finally:
                try:
                    os.unlink(tmp_path)
                except OSError:
                    pass

        time.sleep(_DWELL_OFF_MS / 1000.0)

    print(f"\n  ✓ Sweep complete ({len(channels)} channels).")


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Multi-channel BT sweep emitter")
    parser.add_argument("--mode", choices=list(_SWEEP_MODES), default="light",
                        help="Sweep intensity (default: light)")
    parser.add_argument("--gain", type=float, default=SAFE_BENCH_GAIN_DB,
                        help=f"TX gain dBm, max {MAX_TX_GAIN_DB} (default: {SAFE_BENCH_GAIN_DB})")
    parser.add_argument("--antenna", action="store_true",
                        help="Acknowledge live antenna is connected")
    parser.add_argument("--confirm-shielded", action="store_true",
                        help="Required for heavy mode — confirm shielded enclosure")
    parser.add_argument("--mock", action="store_true",
                        help="Dry-run mode — no hardware required")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO)

    try:
        emit_sweep(
            mode=args.mode,
            tx_gain_db=args.gain,
            antenna_connected=args.antenna,
            confirm_shielded=args.confirm_shielded,
            mock=args.mock,
        )
    except LegalViolationError:
        sys.exit(1)
