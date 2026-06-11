# RF Monitor & Emitter — Raspberry Pi 5

**⚠️ LEGAL NOTICE (Germany / EU):** All transmission code enforces ETSI EN 300 328 limits
(max 20 dBm EIRP, 10% duty cycle). HackRF TX is only for **controlled bench testing**
with a **50 Ω dummy load** or inside a **shielded Faraday enclosure**. Intentional radio
interference is a criminal offence (TKG §149(1) no.10 — fine up to €500,000).

---

## What This Is

A Bluetooth and Wi-Fi RF monitoring, testing, and bench-level signal emitting system.

| Capability | Tool |
|---|---|
| Passive 2.4 GHz spectrum monitoring | RTL-SDR V4 + `monitor/live_monitor.py` |
| Baseline noise floor capture | `monitor/baseline_scan.py` |
| BT Classic + BLE device scanning | `monitor/bt_scanner.py` (hcitool) |
| Wi-Fi channel congestion map | `monitor/wifi_channel_map.py` (iwlist) |
| BT hop pattern capture | `monitor/ubertooth_listener.py` (Ubertooth One) |
| Bench TX — single carrier | `emitter/emit_single_channel.py` (HackRF) |
| Bench TX — multi-channel sweep | `emitter/emit_sweep.py` (HackRF) |
| Pot-controlled live TX | `emitter/emit_with_pot.py` (HackRF + MCP3008) |
| Legal guard (enforced everywhere) | `emitter/legal_guard.py` |
| Software-only testing | `mock/` modules + `--mock` flag |
| Rich terminal dashboard | `display/terminal_ui.py` |
| Waveshare 3.5" LCD output | `display/lcd_display.py` |

---

## Hardware

| Component | Notes |
|---|---|
| Raspberry Pi 5 (8 GB) | Main compute unit |
| RTL-SDR Blog V4 dongle | Passive RX, 500 kHz–1.75 GHz |
| Ubertooth One | BT 2.4 GHz sniffer |
| HackRF One | Bench TX/RX 1 MHz–6 GHz — **dummy load only** |
| MCP3008 ADC + 3× potentiometers | Physical dials for gain/channel |
| 50 Ω SMA dummy load | **Required** for all HackRF TX tests |

Full hardware guide: [docs/HARDWARE.md](docs/HARDWARE.md)

---

## Setup

```bash
# 1. Clone + install
git clone <repo> ~/rf-monitor
cd ~/rf-monitor
bash install.sh        # installs drivers, Python packages, enables SPI/BT

# 2. Reboot (activates SPI + udev rules)
sudo reboot

# 3. Capture a quiet baseline (all transmitters OFF)
python monitor/baseline_scan.py

# 4. Start the live monitor
python monitor/live_monitor.py

# 5. Run the full test suite (software-only)
python test/test_sequence.py --mock
```

---

## Quick Commands

```bash
# Software-only demo (no hardware needed)
python monitor/live_monitor.py --mock --mode jammed
python display/terminal_ui.py --mock --mode congested
python mock/mock_jammer.py --mode full

# Real-hardware monitoring
python monitor/bt_scanner.py
python monitor/wifi_channel_map.py
python monitor/ubertooth_listener.py --duration 60

# Bench TX (DUMMY LOAD REQUIRED)
python emitter/emit_single_channel.py --channel 38 --gain 10 --duration 5
python emitter/emit_sweep.py --mode light --gain 10
python emitter/emit_with_pot.py        # physical pots control gain + channel

# Full hardware test sequence
python test/test_sequence.py
```

---

## Architecture

```
rf-monitor/
├── config/settings.py        ← all constants (thresholds, legal limits, paths)
│
├── utils/
│   ├── frequency_utils.py    ← BT channel ↔ MHz conversions
│   ├── signal_math.py        ← FFT, power dBm, jamming detection, IQ generation
│   └── adc_reader.py         ← MCP3008 SPI reads + scaling
│
├── mock/                     ← software-only test data (no hardware)
│   ├── mock_spectrum.py
│   ├── mock_bt_devices.py
│   └── mock_jammer.py
│
├── monitor/                  ← passive monitoring (no TX)
│   ├── baseline_scan.py
│   ├── live_monitor.py
│   ├── bt_scanner.py
│   ├── wifi_channel_map.py
│   └── ubertooth_listener.py
│
├── emitter/                  ← TX — all call legal_guard first
│   ├── legal_guard.py        ← HARD legal ceiling enforcement
│   ├── emit_single_channel.py
│   ├── emit_sweep.py
│   └── emit_with_pot.py
│
├── test/                     ← 5-phase automated test suite
│   ├── test_sequence.py      ← master runner
│   ├── test_single_tone.py
│   ├── test_channel_move.py
│   ├── test_power_sweep.py
│   ├── test_multi_channel.py
│   └── test_pot_control.py
│
└── display/
    ├── terminal_ui.py        ← rich dashboard
    └── lcd_display.py        ← Waveshare 3.5" SPI LCD
```

---

## Legal Reference

| Rule | Value | Law |
|---|---|---|
| Max TX power | 20 dBm EIRP | ETSI EN 300 328 V2.2.2 §4.3.2 |
| Max duty cycle (non-adaptive) | 10% | ETSI EN 300 328 V2.2.2 §4.3.3 |
| Intentional interference | Forbidden | TKG §149(1) no.10 — fine up to €500,000 |
| Intercepting private comms | Forbidden | TKG §89 |
| Uncertified TX on live band | Restricted | FuAG / RED 2014/53/EU |

---

## Troubleshooting

**RTL-SDR not detected:**
```bash
# Check udev rules applied
ls /dev/bus/usb/  && lsusb | grep RTL
# Re-run the custom driver install
sudo bash install.sh
```

**HackRF not found:**
```bash
hackrf_info    # should print serial number
# Unplug + replug HackRF, then retry
```

**SPI / ADC not working:**
```bash
ls /dev/spidev*    # should show /dev/spidev0.0
# Add dtparam=spi=on to /boot/firmware/config.txt and reboot
```

**`LegalViolationError` raised:**
The requested TX parameters exceed German / EU legal limits. Lower the gain
(≤ 20 dBm) or reduce the duty cycle (≤ 10%) and retry.
