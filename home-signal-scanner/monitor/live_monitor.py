"""
Real-time spectrum monitor.

Loads baseline.json, then continuously sweeps 2402–2480 MHz via RTL-SDR.
Per frequency: computes delta vs baseline, prints a colour-coded bar chart,
and raises ⚠️ / 🚨 alerts at configured thresholds.

Usage:
    python monitor/live_monitor.py
    python monitor/live_monitor.py --mock            # software-only demo
    python monitor/live_monitor.py --mock --mode jammed
"""

from __future__ import annotations

import argparse
import json
import logging
import sys
import time
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    BASELINE_JSON_PATH,
    NOISE_FLOOR_DBM,
    ALERT_THRESHOLD_DB,
    STRONG_TX_THRESHOLD_DB,
    RTL_SAMPLE_RATE,
    SWEEP_SAMPLE_COUNT,
    SWEEP_STEP_MHZ,
)
from utils.frequency_utils import freq_range_mhz, describe_frequency
from utils.signal_math import compute_power_dbm, detect_jamming, delta_spectrum

log = logging.getLogger(__name__)

try:
    from rich.console import Console
    from rich.text import Text
    from rich.live import Live
    from rich.table import Table
    _RICH = True
except ImportError:
    _RICH = False
    log.warning("rich not installed — falling back to plain output")

try:
    from rtlsdr import RtlSdr
    _RTLSDR_AVAILABLE = True
except ImportError:
    _RTLSDR_AVAILABLE = False


def _load_baseline(path: str) -> dict[int, float]:
    """Load baseline.json and return {freq_mhz: power_dbm}."""
    try:
        with open(path) as f:
            raw = json.load(f)
        return {int(k): float(v) for k, v in raw.items()}
    except FileNotFoundError:
        print(f"ERROR: Baseline file not found: {path}\n"
              f"Run monitor/baseline_scan.py first.", file=sys.stderr)
        sys.exit(1)


def _sweep_real(sdr, freqs: list[int]) -> dict[int, float]:
    result: dict[int, float] = {}
    for freq in freqs:
        sdr.center_freq = freq * 1e6
        samples = sdr.read_samples(SWEEP_SAMPLE_COUNT)
        result[freq] = compute_power_dbm(samples)
    return result


def _sweep_mock(freqs: list[int], mode: str, baseline: dict[int, float]) -> dict[int, float]:
    from mock.mock_spectrum import get_spectrum
    return get_spectrum(mode, baseline)


def _format_bar(delta: float, width: int = 40) -> str:
    """Render a delta-dB as a coloured bar (plain text fallback)."""
    filled = max(0, int(delta * (width / STRONG_TX_THRESHOLD_DB)))
    return "█" * min(filled, width)


def _alert_label(delta: float) -> str:
    if delta >= STRONG_TX_THRESHOLD_DB:
        return "🚨 STRONG TX"
    if delta >= ALERT_THRESHOLD_DB:
        return "⚠️  SIGNAL"
    return ""


def run_monitor(
    baseline_path: str = BASELINE_JSON_PATH,
    mock: bool = False,
    mock_mode: str = "normal",
    interval: float = 1.0,
) -> None:
    """
    Main monitoring loop. Ctrl+C to stop.

    Parameters
    ----------
    baseline_path : Path to baseline.json
    mock          : Use software mock spectrum instead of RTL-SDR
    mock_mode     : 'normal', 'congested', 'jammed' (only used when mock=True)
    interval      : Seconds between sweeps
    """
    baseline = _load_baseline(baseline_path)
    freqs = freq_range_mhz()

    if not mock:
        if not _RTLSDR_AVAILABLE:
            print("ERROR: pyrtlsdr not installed. Use --mock.", file=sys.stderr)
            sys.exit(1)
        try:
            sdr = RtlSdr()
            sdr.sample_rate = RTL_SAMPLE_RATE
            sdr.gain = "auto"
        except Exception as e:
            print(f"ERROR: Cannot open RTL-SDR: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        sdr = None

    console = Console() if _RICH else None
    cycle = 0

    try:
        while True:
            cycle += 1

            if mock:
                current = _sweep_mock(freqs, mock_mode, baseline)
            else:
                current = _sweep_real(sdr, freqs)

            deltas = delta_spectrum(current, baseline)
            jam = detect_jamming(current, NOISE_FLOOR_DBM, ALERT_THRESHOLD_DB)
            active_freqs = [f for f, d in deltas.items() if d >= ALERT_THRESHOLD_DB]

            # ── Render ────────────────────────────────────────────────────
            if _RICH and console:
                table = Table(
                    title=f"Cycle {cycle}  |  {'[MOCK]' if mock else '[RTL-SDR]'}",
                    show_header=True,
                )
                table.add_column("MHz", width=6)
                table.add_column("dBm now", width=8)
                table.add_column("Δ dB", width=7)
                table.add_column("Level", width=42)
                table.add_column("Alert", width=14)

                for freq in freqs:
                    pwr = current.get(freq, NOISE_FLOOR_DBM)
                    delta = deltas.get(freq, 0.0)
                    bar = _format_bar(delta)
                    alert = _alert_label(delta)

                    if delta >= STRONG_TX_THRESHOLD_DB:
                        colour = "bold red"
                    elif delta >= ALERT_THRESHOLD_DB:
                        colour = "yellow"
                    else:
                        colour = "green"

                    table.add_row(
                        str(freq),
                        f"{pwr:6.1f}",
                        f"{delta:+5.1f}",
                        Text(bar, style=colour),
                        alert,
                    )

                console.clear()
                console.print(table)
                if jam["is_jammed"]:
                    console.print("[bold red]🚨  JAMMING DETECTED — full-band elevation[/]")
                if active_freqs:
                    console.print(f"[yellow]Active TX: {', '.join(str(f)+' MHz' for f in active_freqs)}[/]")

            else:
                # Plain fallback
                print(f"\n── Cycle {cycle} {'[MOCK]' if mock else '[RTL-SDR]'} ──")
                for freq in freqs:
                    delta = deltas.get(freq, 0.0)
                    bar = _format_bar(delta, width=30)
                    alert = _alert_label(delta)
                    print(f"  {freq:4d} MHz  {delta:+5.1f} dB  {bar:<30s}  {alert}")
                if jam["is_jammed"]:
                    print("🚨  JAMMING DETECTED")
                if active_freqs:
                    print(f"Active TX: {active_freqs}")

            time.sleep(interval)

    except KeyboardInterrupt:
        print("\n\nMonitor stopped.")
    finally:
        if sdr is not None:
            sdr.close()


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Real-time 2.4 GHz spectrum monitor")
    parser.add_argument("--baseline", default=BASELINE_JSON_PATH,
                        help="Path to baseline.json")
    parser.add_argument("--mock", action="store_true",
                        help="Use software mock spectrum (no RTL-SDR needed)")
    parser.add_argument("--mode", choices=["normal", "congested", "jammed"],
                        default="normal", help="Mock spectrum mode")
    parser.add_argument("--interval", type=float, default=1.0,
                        help="Seconds between sweeps (default: 1.0)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING)
    run_monitor(
        baseline_path=args.baseline,
        mock=args.mock,
        mock_mode=args.mode,
        interval=args.interval,
    )
