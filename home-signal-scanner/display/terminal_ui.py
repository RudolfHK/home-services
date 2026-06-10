"""
Rich terminal dashboard.

Left panel  : spectrum bar chart (frequency vs power delta vs baseline)
Right panel : BT device list + alert log
Bottom bar  : current time, device counts, alert count

Usage:
    python display/terminal_ui.py --mock
    python display/terminal_ui.py --mock --mode jammed
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
    ALERT_THRESHOLD_DB,
    STRONG_TX_THRESHOLD_DB,
    NOISE_FLOOR_DBM,
)
from utils.frequency_utils import freq_range_mhz
from utils.signal_math import detect_jamming, delta_spectrum

log = logging.getLogger(__name__)

try:
    from rich.console import Console
    from rich.layout import Layout
    from rich.live import Live
    from rich.panel import Panel
    from rich.table import Table
    from rich.text import Text
    from rich import box
    _RICH_OK = True
except ImportError:
    _RICH_OK = False
    log.warning("rich not installed — pip install rich")


def _load_baseline(path: str) -> dict[int, float]:
    try:
        with open(path) as f:
            return {int(k): float(v) for k, v in json.load(f).items()}
    except FileNotFoundError:
        return {}


def _build_spectrum_panel(
    current: dict[int, float],
    baseline: dict[int, float],
    freqs: list[int],
) -> "Panel":
    """Build a Rich Panel with a bar chart of delta-dB per frequency."""
    table = Table(
        title="Spectrum  (Δ dB vs baseline)",
        show_header=True,
        header_style="bold cyan",
        box=box.SIMPLE,
        expand=True,
    )
    table.add_column("MHz", width=6, justify="right")
    table.add_column("Δ dB", width=7, justify="right")
    table.add_column("Level", ratio=1)
    table.add_column("", width=14)

    for freq in freqs:
        pwr = current.get(freq, NOISE_FLOOR_DBM)
        base = baseline.get(freq, NOISE_FLOOR_DBM)
        delta = pwr - base
        bar_len = max(0, int(delta * 1.2))
        bar = "█" * min(bar_len, 38)

        if delta >= STRONG_TX_THRESHOLD_DB:
            style = "bold red"
            label = "🚨 STRONG TX"
        elif delta >= ALERT_THRESHOLD_DB:
            style = "yellow"
            label = "⚠️  SIGNAL"
        else:
            style = "bright_green"
            label = ""

        table.add_row(
            str(freq),
            f"{delta:+.1f}",
            Text(bar, style=style),
            label,
        )

    return Panel(table, title="[bold]Spectrum Monitor[/]", border_style="cyan")


def _build_bt_panel(
    classic_devices: list[dict],
    ble_devices: list[dict],
    alerts: list[str],
) -> "Panel":
    """Build a Rich Panel with BT device list and alert log."""
    table = Table(show_header=True, box=box.SIMPLE, expand=True)
    table.add_column("Type", width=8)
    table.add_column("MAC", width=19)
    table.add_column("Name", ratio=1)
    table.add_column("RSSI", width=8, justify="right")

    for d in classic_devices[:8]:
        table.add_row("Classic", str(d["mac"]), str(d["name"]), f"{d['rssi']} dBm")
    for d in ble_devices[:8]:
        table.add_row("BLE", str(d["mac"]), str(d["name"]), "—")

    alert_text = "\n".join(alerts[-5:]) if alerts else "✓ No alerts"
    content = f"{table}\n\n[bold red]{alert_text}[/]" if alerts else str(table)

    return Panel(
        table,
        title=(f"[bold]BT Devices  "
               f"(Classic: {len(classic_devices)}  BLE: {len(ble_devices)})"
               f"{'  [red]⚠️ ALERTS[/]' if alerts else ''}[/]"),
        border_style="magenta",
    )


def _build_status_bar(
    cycle: int,
    classic_count: int,
    ble_count: int,
    alert_count: int,
    mock: bool,
) -> "Panel":
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    mode_tag = "[yellow][MOCK][/]" if mock else "[green][LIVE][/]"
    text = (f"{mode_tag}  {ts}  |  Cycle {cycle}  |  "
            f"Classic BT: {classic_count}  BLE: {ble_count}  |  "
            f"Alerts: {'[red]' + str(alert_count) + '[/]' if alert_count else '0'}")
    return Panel(Text.from_markup(text), height=3)


def run_dashboard(
    mock: bool = True,
    mock_mode: str = "normal",
    baseline_path: str = BASELINE_JSON_PATH,
    interval: float = 2.0,
) -> None:
    if not _RICH_OK:
        print("ERROR: rich is not installed. Run: pip install rich", file=sys.stderr)
        sys.exit(1)

    from mock.mock_spectrum import get_spectrum, generate_baseline
    from mock.mock_bt_devices import generate_classic_devices, generate_ble_devices
    from monitor.bt_scanner import scan_classic, scan_ble, analyse_scan

    baseline = _load_baseline(baseline_path)
    if not baseline:
        baseline = generate_baseline()

    freqs = freq_range_mhz()
    console = Console()
    alerts: list[str] = []
    cycle = 0

    with Live(console=console, refresh_per_second=1, screen=True) as live:
        try:
            while True:
                cycle += 1

                if mock:
                    current = get_spectrum(mock_mode, baseline)
                    classic = generate_classic_devices(count=5)
                    ble = generate_ble_devices(count=10)
                else:
                    # Real hardware paths
                    from monitor.live_monitor import _sweep_real
                    from rtlsdr import RtlSdr
                    sdr = RtlSdr()
                    current = _sweep_real(sdr, freqs)
                    sdr.close()
                    classic = scan_classic()
                    ble = scan_ble()

                bt_analysis = analyse_scan(classic, ble)
                alerts.extend(bt_analysis["alerts"])

                deltas = delta_spectrum(current, baseline)
                jam = detect_jamming(current)
                if jam["is_jammed"]:
                    alerts.append(f"🚨 JAMMING DETECTED  avg={jam['avg_power']:.1f} dBm")

                spectrum_panel = _build_spectrum_panel(current, baseline, freqs)
                bt_panel = _build_bt_panel(classic, ble, alerts[-10:])
                status_bar = _build_status_bar(
                    cycle, len(classic), len(ble), len(alerts), mock
                )

                layout = Layout()
                layout.split_column(
                    Layout(name="main", ratio=9),
                    Layout(status_bar, name="status", size=3),
                )
                layout["main"].split_row(
                    Layout(spectrum_panel, name="spectrum"),
                    Layout(bt_panel, name="bt"),
                )

                live.update(layout)
                time.sleep(interval)

        except KeyboardInterrupt:
            pass

    print("\nDashboard closed.")


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Rich terminal RF dashboard")
    parser.add_argument("--mock", action="store_true", help="Use mock data (no hardware)")
    parser.add_argument("--mode", choices=["normal", "congested", "jammed"],
                        default="normal", help="Mock spectrum mode")
    parser.add_argument("--baseline", default=BASELINE_JSON_PATH,
                        help="Path to baseline.json")
    parser.add_argument("--interval", type=float, default=2.0,
                        help="Refresh interval in seconds")
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING)
    run_dashboard(
        mock=args.mock,
        mock_mode=args.mode,
        baseline_path=args.baseline,
        interval=args.interval,
    )
