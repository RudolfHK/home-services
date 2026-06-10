"""
Wi-Fi 2.4 GHz channel utilisation map.

Parses 'iwlist wlan0 scan' output, builds per-channel counts, and flags
congestion, potential jamming, hidden networks, and abnormally strong signals.

Usage:
    python monitor/wifi_channel_map.py
    python monitor/wifi_channel_map.py --mock
    python monitor/wifi_channel_map.py --interface wlan1 --mock
"""

from __future__ import annotations

import argparse
import logging
import re
import subprocess
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    WIFI_24_CHANNELS,
    WIFI_CONGESTED_THRESHOLD,
    WIFI_JAMMED_THRESHOLD,
    WIFI_HIDDEN_THRESHOLD,
    WIFI_ABNORMAL_SIGNAL_DBM,
)

log = logging.getLogger(__name__)

WifiNetwork = dict[str, str | int | float]


def _parse_iwlist_output(raw: str) -> list[WifiNetwork]:
    """
    Parse 'iwlist scan' stdout into a list of network dicts.
    Each dict: {ssid, mac, channel, signal_dbm, hidden}
    """
    networks: list[WifiNetwork] = []
    # Split into per-cell blocks
    cells = re.split(r"Cell \d+ - ", raw)
    for cell in cells[1:]:  # skip header
        mac_m = re.search(r"Address:\s*([0-9A-Fa-f:]{17})", cell)
        ssid_m = re.search(r'ESSID:"([^"]*)"', cell)
        chan_m = re.search(r"Channel:(\d+)", cell)
        sig_m = re.search(r"Signal level=(-?\d+)\s*dBm", cell)
        if not mac_m:
            continue

        mac = mac_m.group(1)
        ssid = ssid_m.group(1) if ssid_m else ""
        channel = int(chan_m.group(1)) if chan_m else 0
        signal = int(sig_m.group(1)) if sig_m else -99
        hidden = len(ssid) == 0

        networks.append({
            "mac": mac,
            "ssid": ssid,
            "channel": channel,
            "signal_dbm": signal,
            "hidden": hidden,
        })
    return networks


def _generate_mock_networks() -> list[WifiNetwork]:
    """Return a plausible mix of Wi-Fi networks for testing."""
    import random
    networks: list[WifiNetwork] = []
    for ssid, ch, sig in [
        ("HomeNetwork", 6, -55),
        ("Neighbor_5G_2.4", 6, -70),
        ("AndroidAP_7A3F", 6, -80),
        ("FRITZ!Box 7590", 1, -60),
        ("Hidden_AP", 11, -65),
        ("", 6, -72),         # hidden
        ("UPC1234567", 11, -50),
        ("Vodafone-F2A1", 11, -68),
        ("Office_Guest", 11, -75),
        ("TP-Link_AA4B", 11, -85),
        ("Eero_Pro_6E", 1, -45),
        ("Sky_ABCDE", 13, -90),
    ]:
        networks.append({
            "mac": ":".join(f"{random.randint(0,255):02X}" for _ in range(6)),
            "ssid": ssid,
            "channel": ch,
            "signal_dbm": sig,
            "hidden": len(ssid) == 0,
        })
    return networks


def scan_wifi(interface: str = "wlan0", mock: bool = False) -> list[WifiNetwork]:
    """Run iwlist scan and return parsed networks list."""
    if mock:
        return _generate_mock_networks()

    try:
        result = subprocess.run(
            ["iwlist", interface, "scan"],
            capture_output=True, text=True, timeout=30,
        )
        return _parse_iwlist_output(result.stdout)
    except FileNotFoundError:
        log.error("iwlist not found — install wireless-tools: sudo apt install wireless-tools")
        return []
    except subprocess.TimeoutExpired:
        log.error("iwlist scan timed out")
        return []


def build_channel_map(networks: list[WifiNetwork]) -> dict[int, list[WifiNetwork]]:
    """Return {channel: [network, …]} for all channels that have at least one network."""
    channel_map: dict[int, list[WifiNetwork]] = {}
    for net in networks:
        ch = int(net["channel"])
        channel_map.setdefault(ch, []).append(net)
    return channel_map


def analyse_wifi(networks: list[WifiNetwork]) -> dict:
    """Produce congestion report and alert list."""
    channel_map = build_channel_map(networks)
    alerts: list[str] = []

    hidden_count = sum(1 for n in networks if n["hidden"])
    if hidden_count >= WIFI_HIDDEN_THRESHOLD:
        alerts.append(f"⚠️  {hidden_count} hidden networks detected (threshold: {WIFI_HIDDEN_THRESHOLD})")

    for net in networks:
        sig = int(net["signal_dbm"])
        if sig > WIFI_ABNORMAL_SIGNAL_DBM:
            alerts.append(
                f"⚠️  Abnormally strong signal: {net['ssid'] or '(hidden)'} "
                f"@ {sig} dBm on CH{net['channel']} (possible rogue AP or jammer)"
            )

    per_channel: dict[int, dict] = {}
    for ch in sorted(WIFI_24_CHANNELS):
        nets = channel_map.get(ch, [])
        count = len(nets)
        strongest = max((int(n["signal_dbm"]) for n in nets), default=-99)
        congestion = "🚨 JAMMED?" if count >= WIFI_JAMMED_THRESHOLD else (
            "⚠️ CONGESTED" if count >= WIFI_CONGESTED_THRESHOLD else "OK"
        )
        per_channel[ch] = {
            "count": count,
            "strongest_dbm": strongest,
            "congestion": congestion,
            "networks": nets,
        }
        if count >= WIFI_JAMMED_THRESHOLD:
            alerts.append(f"🚨 CH{ch}: {count} networks — possibly jammed / overloaded")
        elif count >= WIFI_CONGESTED_THRESHOLD:
            alerts.append(f"⚠️ CH{ch}: {count} networks (congested)")

    return {
        "total_networks": len(networks),
        "hidden_count": hidden_count,
        "per_channel": per_channel,
        "alerts": alerts,
    }


def print_channel_map(analysis: dict) -> None:
    """Print a human-readable ASCII table."""
    print(f"\n── Wi-Fi Channel Map ({analysis['total_networks']} networks, "
          f"{analysis['hidden_count']} hidden) ──\n")
    print(f"  {'CH':>3}  {'Networks':>8}  {'Strongest':>10}  {'Status'}")
    print(f"  {'-'*3}  {'-'*8}  {'-'*10}  {'-'*20}")

    for ch, data in analysis["per_channel"].items():
        bar = "█" * min(data["count"] * 2, 20)
        strongest = f"{data['strongest_dbm']} dBm" if data["count"] > 0 else "—"
        print(f"  {ch:>3}  {data['count']:>8}  {strongest:>10}  {data['congestion']:20s}  {bar}")

    if analysis["alerts"]:
        print("\nALERTS:")
        for a in analysis["alerts"]:
            print(f"  {a}")
    else:
        print("\n✓ No anomalies detected.")


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Wi-Fi 2.4 GHz channel utilisation scanner")
    parser.add_argument("--interface", default="wlan0", help="Wireless interface (default: wlan0)")
    parser.add_argument("--mock", action="store_true", help="Use mock data (no hardware)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING)
    networks = scan_wifi(interface=args.interface, mock=args.mock)
    analysis = analyse_wifi(networks)
    print_channel_map(analysis)
