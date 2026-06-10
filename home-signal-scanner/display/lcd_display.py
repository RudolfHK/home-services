"""
Waveshare 3.5" SPI LCD HAT output.

Renders a compact spectrum bar + status line on the 480×320 display
without needing an external monitor.

The Waveshare 3.5" HAT uses the ILI9486 controller over SPI. The
`waveshare_lcd` library (or luma.lcd) is used if available; the module
falls back gracefully to stdout when the HAT is not connected.

Usage:
    python display/lcd_display.py --mock
    python display/lcd_display.py --mock --mode jammed
"""

from __future__ import annotations

import argparse
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
)
from utils.frequency_utils import freq_range_mhz
from utils.signal_math import delta_spectrum

log = logging.getLogger(__name__)

# Attempt to import PIL (Pillow) for drawing
try:
    from PIL import Image, ImageDraw, ImageFont
    _PIL_OK = True
except ImportError:
    _PIL_OK = False
    log.warning("Pillow not installed — LCD rendering disabled (pip install pillow)")

# Attempt to import luma.lcd for Waveshare HAT
try:
    from luma.core.interface.serial import spi
    from luma.lcd.device import ili9486
    _LUMA_OK = True
except ImportError:
    _LUMA_OK = False
    log.warning("luma.lcd not installed — LCD hardware unavailable")

LCD_WIDTH = 480
LCD_HEIGHT = 320
BAR_AREA_HEIGHT = 220
STATUS_AREA_Y = BAR_AREA_HEIGHT + 10

_COLOUR_NORMAL = (0, 200, 0)       # green
_COLOUR_ALERT = (255, 200, 0)      # yellow
_COLOUR_STRONG = (220, 30, 30)     # red
_COLOUR_BG = (10, 10, 20)          # near-black


def _open_lcd_device():
    """Open the Waveshare 3.5" SPI LCD. Returns device or None."""
    if not _LUMA_OK:
        return None
    try:
        serial = spi(port=0, device=0, gpio_DC=24, gpio_RST=25)
        device = ili9486(serial, rotate=1)
        return device
    except Exception as e:
        log.warning("LCD open failed: %s", e)
        return None


def _render_frame(
    current: dict[int, float],
    baseline: dict[int, float],
    freqs: list[int],
    bt_classic: int,
    bt_ble: int,
    alerts: list[str],
    cycle: int,
) -> "Image.Image":
    """Draw one frame and return a PIL Image (480×320)."""
    img = Image.new("RGB", (LCD_WIDTH, LCD_HEIGHT), _COLOUR_BG)
    draw = ImageDraw.Draw(img)

    # Try to load a small font; fall back to default
    try:
        font_sm = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 10)
        font_md = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 12)
    except (IOError, OSError):
        font_sm = ImageFont.load_default()
        font_md = font_sm

    n = len(freqs)
    bar_width = max(1, LCD_WIDTH // n)

    for i, freq in enumerate(freqs):
        pwr = current.get(freq, NOISE_FLOOR_DBM)
        base = baseline.get(freq, NOISE_FLOOR_DBM)
        delta = pwr - base

        # Map delta to bar height (0–BAR_AREA_HEIGHT)
        bar_h = max(1, int(min(delta / STRONG_TX_THRESHOLD_DB, 1.0) * BAR_AREA_HEIGHT))
        x0 = i * bar_width
        y1 = BAR_AREA_HEIGHT
        y0 = y1 - bar_h

        if delta >= STRONG_TX_THRESHOLD_DB:
            colour = _COLOUR_STRONG
        elif delta >= ALERT_THRESHOLD_DB:
            colour = _COLOUR_ALERT
        else:
            colour = _COLOUR_NORMAL

        draw.rectangle([x0, y0, x0 + bar_width - 1, y1], fill=colour)

    # Horizontal threshold line
    alert_y = BAR_AREA_HEIGHT - int(ALERT_THRESHOLD_DB / STRONG_TX_THRESHOLD_DB * BAR_AREA_HEIGHT)
    draw.line([(0, alert_y), (LCD_WIDTH, alert_y)], fill=(200, 200, 0), width=1)

    # Status bar
    ts = time.strftime("%H:%M:%S")
    alert_str = f"⚠️ {alerts[-1][:28]}" if alerts else "OK"
    status = (f"{ts}  BT:{bt_classic}  BLE:{bt_ble}  Cy:{cycle}  {alert_str}")
    draw.text((4, STATUS_AREA_Y + 4), status, font=font_sm, fill=(220, 220, 220))
    draw.text((4, STATUS_AREA_Y + 18), "2402" + " " * 30 + "2480 MHz",
              font=font_sm, fill=(140, 140, 140))

    return img


def run_lcd(
    mock: bool = True,
    mock_mode: str = "normal",
    baseline_path: str = BASELINE_JSON_PATH,
    interval: float = 1.0,
) -> None:
    import json
    from mock.mock_spectrum import get_spectrum, generate_baseline
    from mock.mock_bt_devices import generate_classic_devices, generate_ble_devices

    try:
        with open(baseline_path) as f:
            baseline = {int(k): float(v) for k, v in json.load(f).items()}
    except FileNotFoundError:
        baseline = generate_baseline()

    freqs = freq_range_mhz()
    device = _open_lcd_device() if not mock else None
    alerts: list[str] = []
    cycle = 0

    print(f"LCD display {'[MOCK — no HAT]' if not device else '[HARDWARE]'}  Ctrl+C to stop")

    try:
        while True:
            cycle += 1
            if mock:
                current = get_spectrum(mock_mode, baseline)
                classic = generate_classic_devices(5)
                ble = generate_ble_devices(8)
            else:
                from monitor.live_monitor import _sweep_real
                from rtlsdr import RtlSdr
                sdr = RtlSdr()
                current = _sweep_real(sdr, freqs)
                sdr.close()
                from monitor.bt_scanner import scan_classic, scan_ble
                classic = scan_classic()
                ble = scan_ble()

            if _PIL_OK:
                frame = _render_frame(current, baseline, freqs,
                                      len(classic), len(ble), alerts, cycle)
                if device:
                    device.display(frame)
                else:
                    # Save a PNG for debugging when no LCD attached
                    frame.save(f"/tmp/lcd_frame_{cycle % 5}.png")
                    print(f"\r  Cycle {cycle}  [saved /tmp/lcd_frame_{cycle%5}.png]",
                          end="", flush=True)
            else:
                # Fallback: plain text
                deltas = delta_spectrum(current, baseline)
                active = [f for f, d in deltas.items() if d >= ALERT_THRESHOLD_DB]
                print(f"\r  Cycle {cycle}  Active TX: {active[:5]}  "
                      f"BT:{len(classic)} BLE:{len(ble)}",
                      end="", flush=True)

            time.sleep(interval)

    except KeyboardInterrupt:
        print("\n\nLCD display stopped.")


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Waveshare 3.5\" LCD spectrum display")
    parser.add_argument("--mock", action="store_true", help="Mock mode — no hardware")
    parser.add_argument("--mode", choices=["normal", "congested", "jammed"],
                        default="normal", help="Mock spectrum mode")
    parser.add_argument("--baseline", default=BASELINE_JSON_PATH)
    parser.add_argument("--interval", type=float, default=1.0)
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING)
    run_lcd(mock=args.mock, mock_mode=args.mode,
            baseline_path=args.baseline, interval=args.interval)
