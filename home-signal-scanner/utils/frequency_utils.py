"""
Frequency conversion helpers: BT channel ↔ MHz, Wi-Fi channel lookups,
sweep range generation.
"""

from __future__ import annotations

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    BT_FREQ_MIN_MHZ,
    BT_CHANNEL_COUNT,
    WIFI_24_CHANNELS,
    SWEEP_STEP_MHZ,
)


def bt_channel_to_mhz(channel: int) -> int:
    """Convert Bluetooth channel number (0–78) to center frequency in MHz."""
    if not (0 <= channel < BT_CHANNEL_COUNT):
        raise ValueError(f"BT channel must be 0–{BT_CHANNEL_COUNT - 1}, got {channel}")
    return BT_FREQ_MIN_MHZ + channel


def mhz_to_bt_channel(mhz: int) -> int:
    """Convert a frequency in MHz to the nearest Bluetooth channel number."""
    channel = mhz - BT_FREQ_MIN_MHZ
    if not (0 <= channel < BT_CHANNEL_COUNT):
        raise ValueError(f"{mhz} MHz is outside the Bluetooth 2.4 GHz band")
    return channel


def wifi_channel_to_mhz(channel: int) -> int:
    """Return center frequency in MHz for a 2.4 GHz Wi-Fi channel (1–14)."""
    if channel not in WIFI_24_CHANNELS:
        raise ValueError(f"Unsupported Wi-Fi channel: {channel}. Valid: {sorted(WIFI_24_CHANNELS)}")
    return WIFI_24_CHANNELS[channel]


def mhz_to_wifi_channel(mhz: int) -> int | None:
    """Return the Wi-Fi channel number whose center is closest to *mhz*, or None."""
    for ch, freq in WIFI_24_CHANNELS.items():
        if abs(freq - mhz) <= 2:
            return ch
    return None


def freq_range_mhz(
    start: int | None = None,
    stop: int | None = None,
    step: int = SWEEP_STEP_MHZ,
) -> list[int]:
    """
    Return a list of sweep frequencies in MHz.
    Defaults to the full Bluetooth 2.4 GHz band (2402–2480 MHz).
    """
    if start is None:
        start = BT_FREQ_MIN_MHZ
    if stop is None:
        stop = BT_FREQ_MIN_MHZ + (BT_CHANNEL_COUNT - 1) * 2  # 2480
    return list(range(start, stop + 1, step))


def describe_frequency(mhz: int) -> str:
    """Return a human-readable label for a frequency (BT channel and/or Wi-Fi channel)."""
    parts: list[str] = [f"{mhz} MHz"]
    try:
        bt_ch = mhz_to_bt_channel(mhz)
        parts.append(f"BT ch {bt_ch}")
    except ValueError:
        pass
    wifi_ch = mhz_to_wifi_channel(mhz)
    if wifi_ch is not None:
        parts.append(f"Wi-Fi ch {wifi_ch}")
    return " | ".join(parts)


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Frequency conversion utilities")
    parser.add_argument("--bt-to-mhz", type=int, metavar="CHANNEL",
                        help="Convert BT channel number to MHz")
    parser.add_argument("--mhz-to-bt", type=int, metavar="MHZ",
                        help="Convert MHz to BT channel")
    parser.add_argument("--sweep", action="store_true",
                        help="Print full BT band sweep frequencies")
    args = parser.parse_args()

    if args.bt_to_mhz is not None:
        print(f"BT channel {args.bt_to_mhz} → {bt_channel_to_mhz(args.bt_to_mhz)} MHz")
    elif args.mhz_to_bt is not None:
        print(f"{args.mhz_to_bt} MHz → BT channel {mhz_to_bt_channel(args.mhz_to_bt)}")
    elif args.sweep:
        freqs = freq_range_mhz()
        print(f"Sweep: {len(freqs)} frequencies from {freqs[0]} to {freqs[-1]} MHz")
        for f in freqs:
            print(f"  {describe_frequency(f)}")
    else:
        parser.print_help()
