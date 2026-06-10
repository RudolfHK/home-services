"""
Bluetooth Classic + BLE device scanner.

Uses hcitool (BlueZ) subprocess calls to scan for nearby devices and
detects advertising storms or flood conditions.

Usage:
    python monitor/bt_scanner.py
    python monitor/bt_scanner.py --mock
    python monitor/bt_scanner.py --ble-only --mock
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
    BLE_STORM_THRESHOLD,
    BLE_FLOOD_THRESHOLD,
    CLASSIC_BT_HIGH_DENSITY,
    BLE_SCAN_WINDOW_SEC,
)

log = logging.getLogger(__name__)

BtDevice = dict[str, str | int | float]


def _run(cmd: list[str], timeout: int = 20) -> str:
    """Run a shell command and return stdout, or '' on failure."""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return result.stdout
    except FileNotFoundError:
        log.warning("Command not found: %s (install bluez)", cmd[0])
        return ""
    except subprocess.TimeoutExpired:
        log.warning("Command timed out: %s", " ".join(cmd))
        return ""


def scan_classic(mock: bool = False) -> list[BtDevice]:
    """
    Run 'hcitool scan --flush' and return list of {mac, name, rssi} dicts.
    Fetches RSSI per device via 'hcitool rssi <mac>'.
    """
    if mock:
        from mock.mock_bt_devices import generate_classic_devices
        return generate_classic_devices(count=5)

    raw = _run(["hcitool", "scan", "--flush"])
    devices: list[BtDevice] = []
    # Output format: "\t<MAC>\t<NAME>"
    for line in raw.splitlines():
        parts = line.strip().split("\t")
        if len(parts) >= 2 and ":" in parts[0]:
            mac = parts[0].strip()
            name = parts[1].strip() if len(parts) > 1 else "Unknown"
            rssi = _get_rssi(mac)
            devices.append({"mac": mac, "name": name, "rssi": rssi})

    return devices


def _get_rssi(mac: str) -> int:
    """Get RSSI for a Classic BT device via 'hcitool rssi'."""
    raw = _run(["hcitool", "rssi", mac], timeout=5)
    # Output: "RSSI return value: -65"
    m = re.search(r"RSSI return value:\s*(-?\d+)", raw)
    if m:
        return int(m.group(1))
    return -99


def scan_ble(window_sec: int = BLE_SCAN_WINDOW_SEC, mock: bool = False) -> list[BtDevice]:
    """
    Run 'hcitool lescan --duplicate' for window_sec seconds.
    Returns list of unique {mac, name, rssi} dicts.
    """
    if mock:
        from mock.mock_bt_devices import generate_ble_devices
        return generate_ble_devices(count=12)

    # lescan needs the adapter reset first
    _run(["hciconfig", "hci0", "reset"])

    raw = _run(
        ["timeout", str(window_sec), "hcitool", "lescan", "--duplicate"],
        timeout=window_sec + 5,
    )
    seen: dict[str, str] = {}
    for line in raw.splitlines():
        # Format: "<MAC>  <NAME or (unknown)>"
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and ":" in parts[0]:
            mac = parts[0]
            name = parts[1] if parts[1] != "(unknown)" else "Unknown"
            seen[mac] = name

    return [{"mac": mac, "name": name, "rssi": -99} for mac, name in seen.items()]


def analyse_scan(
    classic_devices: list[BtDevice],
    ble_devices: list[BtDevice],
) -> dict[str, bool | int | list]:
    """
    Analyse scan results and return alert flags.

    Returns::
        {
            "ble_storm":         bool,
            "ble_flood":         bool,
            "classic_high":      bool,
            "ble_count":         int,
            "classic_count":     int,
            "alerts":            list[str],
        }
    """
    alerts: list[str] = []
    ble_count = len(ble_devices)
    classic_count = len(classic_devices)

    ble_storm = ble_count >= BLE_STORM_THRESHOLD
    ble_flood = ble_count >= BLE_FLOOD_THRESHOLD
    classic_high = classic_count >= CLASSIC_BT_HIGH_DENSITY

    if ble_flood:
        alerts.append(f"🚨 BLE FLOOD: {ble_count} devices (threshold: {BLE_FLOOD_THRESHOLD})")
    elif ble_storm:
        alerts.append(f"⚠️  BLE STORM: {ble_count} devices (threshold: {BLE_STORM_THRESHOLD})")
    if classic_high:
        alerts.append(f"⚠️  HIGH DENSITY: {classic_count} Classic BT (threshold: {CLASSIC_BT_HIGH_DENSITY})")

    return {
        "ble_storm": ble_storm,
        "ble_flood": ble_flood,
        "classic_high": classic_high,
        "ble_count": ble_count,
        "classic_count": classic_count,
        "alerts": alerts,
    }


def run_scanner(mock: bool = False, ble_only: bool = False) -> None:
    """Run one scan cycle and print results."""
    print("\n── Bluetooth Scan ──")

    classic: list[BtDevice] = []
    if not ble_only:
        print("Scanning Classic BT (may take 10–15 s)…")
        classic = scan_classic(mock=mock)
        print(f"Found {len(classic)} Classic BT device(s):")
        for d in classic:
            print(f"  {d['mac']}  {d['name']:30s}  RSSI: {d['rssi']} dBm")

    print(f"\nScanning BLE ({BLE_SCAN_WINDOW_SEC} s window)…")
    ble = scan_ble(mock=mock)
    print(f"Found {len(ble)} BLE device(s):")
    for d in ble:
        print(f"  {d['mac']}  {d['name']:30s}")

    result = analyse_scan(classic, ble)
    if result["alerts"]:
        print("\nALERTS:")
        for a in result["alerts"]:
            print(f"  {a}")
    else:
        print("\n✓ No anomalies detected.")


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Bluetooth device scanner + anomaly detector")
    parser.add_argument("--mock", action="store_true", help="Use mock device lists (no hardware)")
    parser.add_argument("--ble-only", action="store_true", help="Skip Classic BT scan")
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING)
    run_scanner(mock=args.mock, ble_only=args.ble_only)
