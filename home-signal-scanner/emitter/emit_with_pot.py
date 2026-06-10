"""
Potentiometer-controlled live emitter.

POT0 (ADC CH0) → TX gain (0–20 dB)
POT1 (ADC CH1) → BT channel (0–78)

Transmits 100 ms bursts every 900 ms sleep = 10% duty cycle.
legal_guard is called every iteration — turning the gain pot above the
legal limit immediately blocks that burst.

Usage:
    python emit_with_pot.py              # real hardware
    python emit_with_pot.py --mock       # software simulation
"""

from __future__ import annotations

import argparse
import logging
import subprocess
import sys
import tempfile
import threading
import time
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    MAX_TX_GAIN_DB,
    HACKRF_SAMPLE_RATE,
    HACKRF_AMP_ENABLED,
    POT_EMITTER_ON_MS,
    POT_EMITTER_SLEEP_MS,
    SAFE_BENCH_GAIN_DB,
)
from emitter.legal_guard import check_legal_params, LegalViolationError
from utils.adc_reader import adc_to_gain, adc_to_bt_channel, read_adc, read_adc_mock
from utils.frequency_utils import bt_channel_to_mhz
from utils.signal_math import generate_iq_noise, iq_to_bytes

log = logging.getLogger(__name__)

# Shared state updated by the ADC reader thread
_current_gain_db: float = SAFE_BENCH_GAIN_DB
_current_bt_channel: int = 38
_state_lock = threading.Lock()
_stop_event = threading.Event()


def _adc_reader_thread(mock: bool) -> None:
    """Background thread: read pots every 100 ms, update shared state."""
    global _current_gain_db, _current_bt_channel
    read_fn = read_adc_mock if mock else read_adc

    while not _stop_event.is_set():
        try:
            raw0 = read_fn(0)   # POT0 → gain
            raw1 = read_fn(1)   # POT1 → channel
            gain = adc_to_gain(raw0)
            channel = adc_to_bt_channel(raw1)
            with _state_lock:
                _current_gain_db = gain
                _current_bt_channel = channel
        except Exception as e:
            log.warning("ADC read failed: %s", e)
        time.sleep(0.1)


def _transmit_burst(
    bt_channel: int,
    tx_gain_db: float,
    duration_ms: int,
    mock: bool,
) -> bool:
    """
    Emit one burst. Returns True on success, False on TX error.
    Caller must have already called check_legal_params().
    """
    freq_mhz = bt_channel_to_mhz(bt_channel)
    freq_hz = freq_mhz * 1_000_000

    iq = generate_iq_noise(
        sample_rate=HACKRF_SAMPLE_RATE,
        duration_sec=duration_ms / 1000.0,
    )
    burst_bytes = iq_to_bytes(iq)

    if mock:
        time.sleep(duration_ms / 1000.0)
        return True

    with tempfile.NamedTemporaryFile(suffix=".bin", delete=False) as f:
        f.write(burst_bytes)
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
        subprocess.run(cmd, timeout=(duration_ms / 1000.0) + 2,
                       check=True, capture_output=True)
        return True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, FileNotFoundError):
        return False
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def run_pot_emitter(mock: bool = False) -> None:
    """
    Main loop: read pots → legal check → transmit 100 ms → sleep 900 ms.
    Press Ctrl+C to stop.
    """
    duty_cycle = POT_EMITTER_ON_MS / (POT_EMITTER_ON_MS + POT_EMITTER_SLEEP_MS)

    print("\n  Potentiometer-Controlled Emitter")
    print(f"  Duty cycle: {duty_cycle:.0%}  (on={POT_EMITTER_ON_MS} ms, off={POT_EMITTER_SLEEP_MS} ms)")
    print(f"  POT0 → gain (0–{MAX_TX_GAIN_DB} dBm)   POT1 → BT channel (0–78)")
    print("  Press Ctrl+C to stop.\n")

    # Start ADC reader thread
    t = threading.Thread(target=_adc_reader_thread, args=(mock,), daemon=True)
    t.start()

    try:
        while True:
            with _state_lock:
                gain = _current_gain_db
                channel = _current_bt_channel

            freq_mhz = bt_channel_to_mhz(channel)

            # Status line (overwrite in place)
            status = (f"\r  CH: {channel:2d} ({freq_mhz} MHz)  |  "
                      f"Gain: {gain:4.1f} dBm  |  "
                      f"{'[MOCK]' if mock else '[TX]  '}")
            print(status, end="", flush=True)

            try:
                check_legal_params(gain, duty_cycle, verbose=False)
            except LegalViolationError:
                print(f"\r  ⚠️  BLOCKED gain={gain:.1f} dBm > {MAX_TX_GAIN_DB} dBm  "
                      f"(rotate POT0 down)               ", end="", flush=True)
                time.sleep(POT_EMITTER_SLEEP_MS / 1000.0)
                continue

            ok = _transmit_burst(channel, gain, POT_EMITTER_ON_MS, mock)
            if not ok and not mock:
                print("\n  HackRF TX error — is the device connected?", file=sys.stderr)

            time.sleep(POT_EMITTER_SLEEP_MS / 1000.0)

    except KeyboardInterrupt:
        print("\n\n  Stopped by user.")
    finally:
        _stop_event.set()
        t.join(timeout=1.0)


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Potentiometer-controlled BT channel emitter"
    )
    parser.add_argument("--mock", action="store_true",
                        help="Use mock ADC values and skip HackRF (no hardware needed)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING)
    run_pot_emitter(mock=args.mock)
