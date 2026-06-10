"""
Fake Bluetooth device list generator for UI and logic testing.

Generates plausible Classic BT and BLE scan results without any real
Bluetooth hardware or hcitool calls.
"""

from __future__ import annotations

import random
import string
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    BLE_STORM_THRESHOLD,
    BLE_FLOOD_THRESHOLD,
    CLASSIC_BT_HIGH_DENSITY,
)

BtDevice = dict[str, str | int | float]

# Fake device name pools
_CLASSIC_NAMES = [
    "Sony WH-1000XM5", "JBL Flip 6", "iPhone 15 Pro", "Galaxy S24",
    "MacBook Pro", "Dell Laptop", "AirPods Pro", "Bose QC45",
    "Xbox Controller", "PS5 DualSense", "Raspberry Pi 5", "Arduino Uno",
    "HP Printer", "Canon Camera", "Logitech MX Keys",
]
_BLE_NAMES = [
    "Tile Mate", "Fitbit Charge 6", "Samsung SmartTag", "AirTag",
    "Xiaomi Band 8", "Garmin Forerunner", "Unknown Sensor", "BLE Beacon",
    "iBeacon-A4F2", "Heart Rate Monitor", "Temperature Sensor",
    "Environmental Monitor", "Smart Lock", "BLE Keyboard",
]


def _random_mac() -> str:
    """Generate a random 6-byte MAC address string."""
    return ":".join(f"{random.randint(0, 255):02X}" for _ in range(6))


def generate_classic_devices(
    count: int = 5,
    rssi_range: tuple[int, int] = (-90, -40),
) -> list[BtDevice]:
    """
    Return a list of fake Classic Bluetooth device dicts.

    Each dict: {mac: str, name: str, rssi: int}
    """
    devices: list[BtDevice] = []
    names = random.sample(_CLASSIC_NAMES, min(count, len(_CLASSIC_NAMES)))
    # If count > name pool, pad with random names
    while len(names) < count:
        names.append("BT-Device-" + "".join(random.choices(string.ascii_uppercase, k=4)))

    for name in names:
        devices.append({
            "mac": _random_mac(),
            "name": name,
            "rssi": random.randint(*rssi_range),
        })
    return devices


def generate_ble_devices(
    count: int = 8,
    rssi_range: tuple[int, int] = (-95, -45),
) -> list[BtDevice]:
    """
    Return a list of fake BLE device dicts.

    Each dict: {mac: str, name: str, rssi: int}
    """
    devices: list[BtDevice] = []
    names = random.sample(_BLE_NAMES, min(count, len(_BLE_NAMES)))
    while len(names) < count:
        names.append("BLE-" + "".join(random.choices(string.hexdigits[:16], k=6)).upper())

    for name in names:
        devices.append({
            "mac": _random_mac(),
            "name": name,
            "rssi": random.randint(*rssi_range),
        })
    return devices


def generate_advertising_storm(
    count: int | None = None,
) -> list[BtDevice]:
    """
    Generate enough BLE devices to trigger an advertising storm alert.
    Default count = BLE_STORM_THRESHOLD + 5 (clearly above threshold).
    """
    if count is None:
        count = BLE_STORM_THRESHOLD + 5
    return generate_ble_devices(count=count, rssi_range=(-70, -30))


def generate_ble_flood(count: int | None = None) -> list[BtDevice]:
    """Generate enough BLE devices to trigger the flood alert."""
    if count is None:
        count = BLE_FLOOD_THRESHOLD + 5
    return generate_ble_devices(count=count)


def generate_high_density_classic(count: int | None = None) -> list[BtDevice]:
    """Generate enough Classic BT devices to trigger the high-density alert."""
    if count is None:
        count = CLASSIC_BT_HIGH_DENSITY + 3
    return generate_classic_devices(count=count)


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Generate mock Bluetooth device lists")
    parser.add_argument("--classic", type=int, default=5, help="Number of Classic BT devices")
    parser.add_argument("--ble", type=int, default=8, help="Number of BLE devices")
    parser.add_argument("--storm", action="store_true", help="Simulate advertising storm")
    parser.add_argument("--flood", action="store_true", help="Simulate BLE flood")
    args = parser.parse_args()

    if args.storm:
        devices = generate_advertising_storm()
        print(f"Advertising storm: {len(devices)} BLE devices")
    elif args.flood:
        devices = generate_ble_flood()
        print(f"BLE flood: {len(devices)} BLE devices")
    else:
        classic = generate_classic_devices(args.classic)
        ble = generate_ble_devices(args.ble)
        print(f"\nClassic BT ({len(classic)} devices):")
        for d in classic:
            print(f"  {d['mac']}  {d['name']:30s}  {d['rssi']} dBm")
        print(f"\nBLE ({len(ble)} devices):")
        for d in ble:
            print(f"  {d['mac']}  {d['name']:30s}  {d['rssi']} dBm")
