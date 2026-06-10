"""
MCP3008 SPI ADC helper.

Reads 10-bit values (0–1023) from any of the 8 channels and converts
them to gain dB, BT channel numbers, or percentages.

Hardware: MCP3008 wired to Pi 5 SPI0 (GPIO 8/9/10/11).
Falls back gracefully if spidev is not available (for mock/test use).
"""

from __future__ import annotations

import logging
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import (
    ADC_MAX_RAW,
    MAX_TX_GAIN_DB,
    BT_CHANNEL_COUNT,
    SPI_BUS,
    SPI_DEVICE,
    SPI_SPEED_HZ,
)

log = logging.getLogger(__name__)

try:
    import spidev as _spidev
    _SPIDEV_AVAILABLE = True
except ImportError:
    _SPIDEV_AVAILABLE = False
    log.warning("spidev not installed — ADC reads will return mock values")

# Module-level SPI handle (opened lazily)
_spi: object | None = None


def _get_spi():
    global _spi
    if _spi is None:
        if not _SPIDEV_AVAILABLE:
            raise RuntimeError("spidev is not installed; cannot open SPI bus")
        import spidev
        _spi = spidev.SpiDev()
        _spi.open(SPI_BUS, SPI_DEVICE)
        _spi.max_speed_hz = SPI_SPEED_HZ
    return _spi


def read_adc(channel: int) -> int:
    """
    Read a raw 10-bit value (0–1023) from MCP3008 channel *channel* (0–7).

    Raises RuntimeError if the hardware is not available.
    """
    if not (0 <= channel <= 7):
        raise ValueError(f"MCP3008 channel must be 0–7, got {channel}")

    spi = _get_spi()
    # MCP3008 SPI protocol: 3 bytes — start bit, single-ended select, don't-care
    cmd = [1, (8 + channel) << 4, 0]
    response = spi.xfer2(cmd)
    raw = ((response[1] & 3) << 8) | response[2]
    return raw


def read_adc_mock(channel: int) -> int:
    """Return a deterministic mock value for testing without hardware."""
    # Mid-scale for all channels
    return ADC_MAX_RAW // 2


def adc_to_gain(raw: int) -> float:
    """
    Map a 10-bit ADC reading (0–1023) to TX gain in dB (0–MAX_TX_GAIN_DB).
    The legal ceiling is enforced here as a hard cap.
    """
    gain = (raw / ADC_MAX_RAW) * MAX_TX_GAIN_DB
    return min(round(gain, 1), float(MAX_TX_GAIN_DB))


def adc_to_bt_channel(raw: int) -> int:
    """Map a 10-bit ADC reading to a Bluetooth channel number (0–78)."""
    channel = round((raw / ADC_MAX_RAW) * (BT_CHANNEL_COUNT - 1))
    return max(0, min(channel, BT_CHANNEL_COUNT - 1))


def adc_to_percent(raw: int) -> float:
    """Map a 10-bit ADC reading to a percentage (0–100)."""
    return round((raw / ADC_MAX_RAW) * 100.0, 1)


def close() -> None:
    """Close the SPI bus if open."""
    global _spi
    if _spi is not None and _SPIDEV_AVAILABLE:
        _spi.close()
        _spi = None


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse
    import time

    parser = argparse.ArgumentParser(description="Read MCP3008 ADC channels")
    parser.add_argument("--channel", type=int, default=0, help="ADC channel (0–7)")
    parser.add_argument("--loop", action="store_true", help="Continuously read every 200 ms")
    parser.add_argument("--mock", action="store_true", help="Use mock values (no hardware)")
    args = parser.parse_args()

    read_fn = read_adc_mock if args.mock else read_adc

    try:
        while True:
            try:
                raw = read_fn(args.channel)
            except RuntimeError as e:
                print(f"Hardware error: {e}. Use --mock for testing.")
                break

            gain = adc_to_gain(raw)
            ch = adc_to_bt_channel(raw)
            pct = adc_to_percent(raw)
            print(f"CH{args.channel}: raw={raw:4d}  gain={gain:5.1f} dB  "
                  f"BT_ch={ch:2d}  {pct:5.1f}%")

            if not args.loop:
                break
            time.sleep(0.2)
    finally:
        close()
