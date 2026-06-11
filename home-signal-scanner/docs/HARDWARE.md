# Hardware Guide — RF Monitor & Emitter (Raspberry Pi 5)

Everything you need to build the complete RF monitoring and bench-testing rig.
Parts are split into **Required** (the stack won't run without them) and
**Optional** (add-ons for convenience or a better experience).

Prices are approximate and vary by region. Links point to Amazon.de / Amazon.com
and official vendor stores where stock is most reliable.

---

## Quick Shopping List

| # | Part | Approx. price |
|---|------|--------------|
| 1 | Raspberry Pi 5 — 8 GB | ~€80 / $80 |
| 2 | Official 27 W USB-C power supply | ~€12 / $12 |
| 3 | Active cooler or fan case | ~€5–25 |
| 4 | microSD card 32 GB+ A2 **or** NVMe SSD + HAT | ~€10–50 |
| 5 | RTL-SDR Blog V4 dongle | ~€35 / $35 |
| 6 | Ubertooth One | ~€110 / $120 |
| 7 | HackRF One | ~€330 / $340 |
| 8 | 50 Ω SMA dummy load | ~€10 / $10 |
| 9 | MCP3008 ADC chip | ~€3 / $3 |
| 10 | 3× 10 kΩ potentiometers | ~€3 / $5 |
| 11 | Breadboard + jumper wire kit | ~€8 / $8 |
| 12 | Powered 4-port USB 3.0 hub | ~€20 / $20 |

**Estimated total: ~€620 / $640** (dominated by HackRF + Ubertooth)

> If you only want **passive monitoring** (no TX, no BT sniffer) skip items 6, 7, 8, 9, 10.
> That brings the cost to ~€170 / $170.

---

## 1. Raspberry Pi 5 — 8 GB

**Why 8 GB?** RTL-SDR + Ubertooth capture + Python FFT processing can hit 500 MB RAM
under load. 4 GB works but leaves little headroom. 8 GB is the safer pick.

**Minimum specs:**
- Raspberry Pi 5 (any revision)
- 8 GB LPDDR4X RAM recommended (4 GB is the absolute minimum)
- PCIe 2.0 ×1 FPC connector on the board (all Pi 5 units have this)

**Where to buy:**
- [Raspberry Pi 5 8GB — raspberrypi.com (official)](https://www.raspberrypi.com/products/raspberry-pi-5/)
- [Raspberry Pi 5 8GB — Amazon.de](https://www.amazon.de/s?k=Raspberry+Pi+5+8GB)
- [Raspberry Pi 5 8GB — Amazon.com](https://www.amazon.com/s?k=raspberry+pi+5+8gb)
- [Raspberry Pi 5 8GB — Pimoroni (UK/EU, often in stock)](https://shop.pimoroni.com/products/raspberry-pi-5)
- [Raspberry Pi 5 8GB — Adafruit (US)](https://www.adafruit.com/product/5813)
- [Raspberry Pi 5 8GB — BerryBase (DE)](https://www.berrybase.de/raspberry-pi-5-8gb-ram)

> **Tip:** Pi 5 units go in and out of stock. If the official store shows "out of stock",
> check Pimoroni, Adafruit, or BerryBase — they get separate allocation.

---

## 2. Power Supply — Official 27 W USB-C PD

**Why official?** The Pi 5 draws up to ~12 W at full CPU load. With USB SDR dongles
and a hub attached, total draw can reach 20+ W. A phone charger or a cheap 15 W brick
will trigger the low-voltage warning and throttle the CPU. The official supply is rated
5.1 V / 5 A (25.5 W) with USB-C PD negotiation.

**Minimum specs:**
- USB-C output, 5 V / 5 A (25 W+)
- USB Power Delivery (PD) negotiated — the Pi 5 specifically requires PD to unlock
  the higher power budget (without it, USB peripherals are current-limited)
- Your plug format: Type G (UK), Type F (EU), Type A (US)

**Where to buy:**
- [Official 27W PSU — raspberrypi.com](https://www.raspberrypi.com/products/27w-power-supply/)
- [Official 27W PSU — Amazon.de](https://www.amazon.de/s?k=Raspberry+Pi+27W+Netzteil)
- [Official 27W PSU — Amazon.com](https://www.amazon.com/s?k=raspberry+pi+27w+power+supply)
- [Official 27W PSU — Pimoroni](https://shop.pimoroni.com/products/raspberry-pi-27w-usb-c-power-supply)

---

## 3. Cooling — Active Cooler or Fan Case

**Why active cooling?** The Pi 5 has a higher-performance CPU than the Pi 4. Running
RTL-SDR sweeps + Python FFT in a loop pegs at least one core constantly. Without
active cooling, junction temperature hits 85 °C within minutes and the CPU throttles,
slowing the entire monitoring pipeline.

### Option A — Official Raspberry Pi Active Cooler (recommended)

A blower fan + copper heatsink plate that clips directly onto the Pi 5 GPIO header.
Best thermal performance for the money, no case needed.

- [Official Active Cooler — raspberrypi.com](https://www.raspberrypi.com/products/active-cooler/)
- [Official Active Cooler — Amazon.de](https://www.amazon.de/s?k=Raspberry+Pi+5+Active+Cooler)
- [Official Active Cooler — Amazon.com](https://www.amazon.com/s?k=raspberry+pi+5+active+cooler)

### Option B — Argon ONE V3 Case

Full aluminium case, passive thermal conduction to the case walls, optional 30 mm fan.
Looks clean on a desk. Note: covers the GPIO header (use the included extender for the
SPI ADC wiring).

- [Argon ONE V3 — Amazon.de](https://www.amazon.de/s?k=Argon+ONE+V3+Raspberry+Pi+5)
- [Argon ONE V3 — Amazon.com](https://www.amazon.com/s?k=argon+one+v3+raspberry+pi+5)

### Option C — Geekworm / Waveshare Fan Cases

Budget metal or acrylic cases with a 40 mm PWM fan. GPIO stays accessible, which is
important for the MCP3008 SPI wiring in this project.

- [Geekworm Pi 5 case with fan — Amazon.de](https://www.amazon.de/s?k=Geekworm+Raspberry+Pi+5+Case+Fan)
- [Geekworm Pi 5 case with fan — Amazon.com](https://www.amazon.com/s?k=geekworm+raspberry+pi+5+fan+case)

---

## 4. Storage

### Option A — microSD Card (minimum viable, easier to start)

**Minimum specs:**
- Capacity: 32 GB minimum, 64 GB recommended (Docker images + logs)
- Speed class: **A2 Application Performance Class** (random 4K read ≥ 4000 IOPS)
- Endurance: high-endurance rated if possible (continuous write workload)

Recommended cards:
| Card | Capacity | Notes |
|------|----------|-------|
| Samsung PRO Endurance | 64 GB | Best write endurance for continuous logging |
| SanDisk Extreme Pro | 64 GB | Fastest random IOPS |
| SanDisk MAX Endurance | 128 GB | Good for long-term deployments |

- [Samsung PRO Endurance 64GB — Amazon.de](https://www.amazon.de/s?k=Samsung+PRO+Endurance+64GB+microSD)
- [Samsung PRO Endurance 64GB — Amazon.com](https://www.amazon.com/s?k=samsung+pro+endurance+64gb+microsd)
- [SanDisk Extreme Pro 64GB — Amazon.de](https://www.amazon.de/s?k=SanDisk+Extreme+Pro+64GB+microSD)

### Option B — NVMe SSD + PCIe HAT (recommended for long-term use)

The Pi 5 exposes a PCIe 2.0 ×1 lane via an FPC connector. An M.2 HAT plugs into this
and gives you 5–10× faster storage, dramatically better write endurance, and lower
latency for the Python import chain and log writes.

**What you need:**
1. An M.2 NVMe SSD — 2230, 2242, or 2280 form factor, PCIe Gen 2 or 3 (Gen 4 works
   but is bottlenecked by the Pi's Gen 2 lane)
2. A PCIe to M.2 HAT for the Pi 5 FPC connector

Recommended HATs:
| HAT | Notes |
|-----|-------|
| Pimoroni NVMe Base | Clean design, leaves GPIO accessible |
| Waveshare PCIe to M.2 HAT+ | Supports 2230/2242/2280, good availability |
| Raspberry Pi M.2 HAT+ (official) | Official, 2230/2242 only, limited clearance for active cooler |

Recommended SSDs (all PCIe Gen 3, 2242 or 2280):
| SSD | Capacity | Notes |
|-----|----------|-------|
| WD Green SN350 | 240 GB | Low power, good Pi 5 compatibility |
| Kingston NV3 | 256 GB | Budget-friendly, widely available |
| Samsung 980 | 250 GB | Premium, low latency |

- [Pimoroni NVMe Base — shop.pimoroni.com](https://shop.pimoroni.com/products/nvme-base)
- [Waveshare PCIe M.2 HAT+ — Amazon.de](https://www.amazon.de/s?k=Waveshare+PCIe+M.2+HAT+Raspberry+Pi+5)
- [Raspberry Pi M.2 HAT+ — raspberrypi.com](https://www.raspberrypi.com/products/m2-hat-plus/)
- [WD Green SN350 240GB — Amazon.de](https://www.amazon.de/s?k=WD+Green+SN350+240GB+M.2)
- [WD Green SN350 240GB — Amazon.com](https://www.amazon.com/s?k=wd+green+sn350+240gb+m2)

---

## 5. RTL-SDR Blog V4 Dongle — Passive RX (500 kHz – 1.75 GHz)

**What it does:** Receives the 2.4 GHz band passively. Used by `baseline_scan.py` and
`live_monitor.py` to capture raw IQ samples and compute power-spectral density.

**Why Blog V4 specifically?** The standard RTL-SDR V3 (and no-name clones) use a
different driver stack. The **V4** has a revised tuner (R828D → R860), improved
shielding, and Bias-T on pin 1. More importantly, this project's `install.sh` builds
the **RTL-SDR Blog custom driver** from source — which is required for the V4 hardware
IDs to be recognised correctly. Do not substitute a V3 or a clone.

**Minimum specs:**
- RTL-SDR Blog V4 (genuine, not a clone) — the chip marking reads "R860"
- Frequency range: 500 kHz – 1.75 GHz
- Sample rate: up to 3.2 MS/s (we use 2.4 MS/s)
- Interface: USB 2.0
- Included SMA antenna for RX (adequate for 2.4 GHz bench work)

**Where to buy (genuine only — avoid no-name Amazon listings):**
- [RTL-SDR Blog V4 — rtl-sdr.com (official store)](https://www.rtl-sdr.com/buy-rtl-sdr-dvb-t-dongles/)
- [RTL-SDR Blog V4 — Amazon.de](https://www.amazon.de/s?k=RTL-SDR+Blog+V4)
- [RTL-SDR Blog V4 — Amazon.com](https://www.amazon.com/s?k=rtl-sdr+blog+v4)

**Recommended accessories:**
- 1 m SMA-to-SMA extension cable: keeps the dongle away from Pi board EMI
  → [Amazon.de](https://www.amazon.de/s?k=SMA+Verl%C3%A4ngerungskabel+1m) /
    [Amazon.com](https://www.amazon.com/s?k=sma+extension+cable+1m)
- 4× ferrite chokes (snap-on, 3–5 mm cable diameter): clip onto USB cables to reduce
  conducted RF noise from the Pi's switching regulator
  → [Amazon.de](https://www.amazon.de/s?k=Ferritkern+USB+Kabel) /
    [Amazon.com](https://www.amazon.com/s?k=ferrite+core+snap+usb+cable)

---

## 6. Ubertooth One — Bluetooth 2.4 GHz Sniffer

**What it does:** Captures raw Bluetooth Classic packets and BLE advertising PDUs at
the physical layer, including frequency-hopping patterns. Used by
`monitor/ubertooth_listener.py`. This is passive-only from a legal standpoint — you
are only receiving, not transmitting BT traffic.

**Why genuine?** The Ubertooth One is an open-hardware design, but clone builds
frequently have faulty firmware and mismatched clock references that cause capture
errors. Only the Great Scott Gadgets unit is tested against the `ubertooth-utils` apt
package this project relies on.

**Minimum specs:**
- Great Scott Gadgets Ubertooth One (genuine)
- Frequency: 2.4–2.485 GHz
- Interface: USB 2.0
- Antenna: RP-SMA, 2.4 GHz duck antenna included or purchased separately
- Firmware: must be updateable via `ubertooth-util -f` (genuine units only)

**Where to buy:**
- [Ubertooth One — greatscottgadgets.com (official)](https://greatscottgadgets.com/ubertoothone/)
- [Ubertooth One — Mouser Electronics](https://www.mouser.de/c/?q=ubertooth)
- [Ubertooth One — Amazon.com](https://www.amazon.com/s?k=ubertooth+one+great+scott)
- [Ubertooth One — Amazon.de](https://www.amazon.de/s?k=Ubertooth+One)

> **Note:** Great Scott Gadgets occasionally runs out of stock. Mouser and Digi-Key
> are reliable distributors. Avoid eBay/AliExpress clones entirely.

---

## 7. HackRF One — Bench Transmitter / Receiver (1 MHz – 6 GHz)

**What it does:** Generates arbitrary IQ waveforms for controlled bench tests.
Used by `emitter/emit_single_channel.py`, `emit_sweep.py`, and `emit_with_pot.py`.

**⚠️ Legal reminder:** In this project the HackRF is always used with a **50 Ω dummy
load** or inside a shielded enclosure. Transmitting into a real antenna at 2.4 GHz
without a licence for that frequency and power level is illegal in Germany (TKG §149)
and most other jurisdictions. The `legal_guard.py` module enforces the 20 dBm /
10% duty-cycle limits in software, but physical safety is your responsibility.

**Minimum specs:**
- HackRF One (Great Scott Gadgets, genuine)
- TX/RX frequency: 1 MHz – 6 GHz
- Sample rate: up to 20 MS/s (we use 2 MS/s)
- TX power: up to 10–15 dBm before external amp (no external amp used here)
- Interface: USB 2.0 (high-speed)
- Half-duplex (TX or RX at any time, not simultaneously)

**Where to buy:**
- [HackRF One — greatscottgadgets.com (official)](https://greatscottgadgets.com/hackrf/)
- [HackRF One — Mouser Electronics](https://www.mouser.de/c/?q=hackrf+one)
- [HackRF One — Amazon.de](https://www.amazon.de/s?k=HackRF+One)
- [HackRF One — Amazon.com](https://www.amazon.com/s?k=hackrf+one)

> **Tip:** The HackRF is the most expensive single item in the build. If you only need
> passive monitoring, you can skip it entirely — all emitter scripts have a `--mock`
> flag that runs without hardware.

---

## 8. 50 Ω SMA Dummy Load — MANDATORY for HackRF TX

**What it does:** Absorbs transmitted RF power as heat instead of radiating it.
**This is not optional** — you must connect a dummy load before running any
emitter script. Without it, the HackRF transmits into open air, which is both
illegal (uncertified radiation) and can damage the HackRF output stage.

**Minimum specs:**
- Impedance: 50 Ω
- Power handling: ≥ 1 W (HackRF output is ~10–15 dBm ≈ 10–30 mW, so 1 W is ample)
- Frequency range: DC – 6 GHz (must cover the full HackRF range)
- Connector: SMA male

Recommended models:
| Model | Rating | Notes |
|-------|--------|-------|
| Telegärtner J01151A0046 | DC–6 GHz, 1 W | German brand, excellent quality |
| Mini-Circuits ANNE-50+ | DC–6 GHz, 1 W | Industry standard |
| Pasternack PE6000 | DC–6 GHz, 1 W | Good availability |

- [SMA 50 Ohm Dummy Load — Amazon.de](https://www.amazon.de/s?k=SMA+50+Ohm+Abschlusswiderstand+Dummy+Load)
- [SMA 50 Ohm Dummy Load — Amazon.com](https://www.amazon.com/s?k=sma+50+ohm+dummy+load+6ghz)
- [Mini-Circuits ANNE-50+ — minicircuits.com](https://www.minicircuits.com/WebStore/dashboard.html?model=ANNE-50%2B)

---

## 9. MCP3008 — 8-Channel 10-Bit SPI ADC

**What it does:** Reads the three analogue potentiometers and converts them to
10-bit digital values that the Pi can read over SPI. Used by `utils/adc_reader.py`
and `emitter/emit_with_pot.py`.

**Minimum specs:**
- MCP3008 (Microchip Technology), DIP-16 package
- 8 single-ended input channels, 10-bit resolution
- SPI interface, 3.3 V compatible (matches Pi GPIO voltage)
- Supply voltage: 2.7–5.5 V

**Where to buy:**
- [MCP3008 — Amazon.de](https://www.amazon.de/s?k=MCP3008+ADC)
- [MCP3008 — Amazon.com](https://www.amazon.com/s?k=mcp3008)
- [MCP3008 — Reichelt Elektronik (DE)](https://www.reichelt.de/de/de/suche/?searchterm=MCP3008)
- [MCP3008 — Adafruit (US)](https://www.adafruit.com/product/856)
- [MCP3008 — Conrad Elektronik (DE)](https://www.conrad.de/de/search.html?search=MCP3008)

---

## 10. 3× 10 kΩ Potentiometers

**What they do:**
- **POT0** (ADC CH0) → TX gain control (0–20 dB)
- **POT1** (ADC CH1) → Bluetooth channel select (0–78)
- **POT2** (ADC CH2) → Scan threshold adjustment (spare / configurable)

**Minimum specs:**
- Resistance: 10 kΩ (B-taper / linear preferred)
- Type: single-turn panel mount or breadboard-compatible (9 mm body)
- Shaft: 6 mm round knurled (for a knob) or bare for breadboard
- Power: ≥ 0.1 W

**Where to buy (usually sold in packs of 5–10):**
- [10kΩ potentiometers — Amazon.de](https://www.amazon.de/s?k=10k+Potentiometer+Breadboard)
- [10kΩ potentiometers — Amazon.com](https://www.amazon.com/s?k=10k+ohm+potentiometer+breadboard)
- [10kΩ potentiometers — Reichelt (DE)](https://www.reichelt.de/de/de/suche/?searchterm=Potentiometer+10K+linear)

---

## 11. Breadboard + Jumper Wire Kit

**What it does:** Connects the MCP3008 and potentiometers to the Pi GPIO header
without soldering. You need male-to-female jumpers (Pi GPIO header → breadboard) and
male-to-male jumpers (breadboard internal connections).

**Minimum specs:**
- 830-point solderless breadboard (full-size, 63 rows)
- Jumper wire kit: M-M and M-F, at least 40 of each

### GPIO / SPI Wiring Reference (MCP3008 → Pi 5)

```
MCP3008 Pin     Pi 5 GPIO Pin
───────────     ─────────────
VDD    (16) →   3.3V   (pin 1)
DGND    (9) →   GND    (pin 6)
CLK    (13) →   GPIO11 / SCLK (pin 23)
DOUT   (12) →   GPIO9  / MISO (pin 21)
DIN    (11) →   GPIO10 / MOSI (pin 19)
CS     (10) →   GPIO8  / CE0  (pin 24)
AGND    (9) →   GND    (pin 9)   [tie to DGND]
Vref   (15) →   3.3V   (pin 17) [tie to VDD]

Potentiometer wiring (each pot, 3 pins):
  Left pin  →  3.3V (any 3.3V rail on breadboard)
  Wiper     →  MCP3008 CH0 / CH1 / CH2 (pins 1 / 2 / 3)
  Right pin →  GND  (any GND rail on breadboard)
```

**Where to buy:**
- [830pt breadboard + jumper kit — Amazon.de](https://www.amazon.de/s?k=Breadboard+830+Jumper+Wire+Kit)
- [830pt breadboard + jumper kit — Amazon.com](https://www.amazon.com/s?k=830+point+breadboard+jumper+wire+kit)
- [Elegoo Breadboard Kit — Amazon.de](https://www.amazon.de/s?k=Elegoo+Breadboard+Kit)

---

## 12. Powered 4-Port USB 3.0 Hub

**What it does:** Provides stable, isolated power to the RTL-SDR V4, Ubertooth One,
and HackRF One. The Pi 5 USB ports share a 1.6 A total budget across all USB-A ports
— connecting three power-hungry SDR devices directly will trigger low-current warnings
and cause the RTL-SDR to drop samples.

**Minimum specs:**
- USB 3.0 (5 Gbps) — all three SDR devices are USB 2.0 HS, but USB 3.0 ports are
  backward-compatible and reduce interference compared to USB 2.0 hubs
- External power supply included (12 V / 2–3 A recommended)
- At least 4 ports
- Individual port power of ≥ 900 mA per port

**Where to buy:**
- [Anker 4-Port USB 3.0 powered hub — Amazon.de](https://www.amazon.de/s?k=Anker+USB+3.0+Hub+Netzteil)
- [Anker 4-Port USB 3.0 powered hub — Amazon.com](https://www.amazon.com/s?k=anker+powered+usb+3+hub)
- [UGREEN USB 3.0 powered hub — Amazon.de](https://www.amazon.de/s?k=UGREEN+USB+3.0+Hub+Netzteil+4+Port)

---

## Optional: Waveshare 3.5" SPI LCD HAT

**What it does:** Renders the live spectrum bar chart and status line on a small
display attached directly to the Pi — no HDMI monitor needed. Uses `display/lcd_display.py`.

**Specs:**
- Waveshare 3.5 inch TFT LCD HAT (ILI9486 controller)
- Resolution: 480 × 320 pixels
- Interface: SPI (uses GPIO 24 for DC, GPIO 25 for RST)
- Mounts directly onto the 40-pin GPIO header
- Note: conflicts with GPIO-based cases — use a standoff kit

**Where to buy:**
- [Waveshare 3.5" LCD HAT — Amazon.de](https://www.amazon.de/s?k=Waveshare+3.5+inch+LCD+HAT+Raspberry+Pi)
- [Waveshare 3.5" LCD HAT — Amazon.com](https://www.amazon.com/s?k=waveshare+3.5+lcd+hat+raspberry+pi)
- [Waveshare 3.5" LCD HAT — waveshare.com](https://www.waveshare.com/3.5inch-rpi-lcd-a.htm)

---

## Optional: Aluminium Shielded Enclosure (Faraday Box)

For any HackRF TX tests where you want additional insurance that radiated power stays
contained. Place both the HackRF (connected to dummy load) and the RTL-SDR inside
during loopback tests.

**Minimum specs:**
- All-metal (aluminium or steel) construction — no plastic cutouts on the body
- Size: ~200 × 150 × 80 mm minimum to fit HackRF + RTL-SDR side by side
- SMA or BNC bulkhead feedthrough optional (for connecting test equipment)

**Where to buy:**
- [Aluminium project enclosure — Amazon.de](https://www.amazon.de/s?k=Aluminium+Geh%C3%A4use+Abschirmbox+HF)
- [Aluminium project enclosure — Amazon.com](https://www.amazon.com/s?k=aluminum+rf+shielded+enclosure+project+box)
- [Hammond 1590D (125×120×55 mm) — Reichelt](https://www.reichelt.de/de/de/suche/?searchterm=Hammond+1590)

---

## Minimum Passive-Only Build (no TX, ~€170)

If you only want to monitor and scan (no HackRF transmission), the bill of materials
shrinks significantly:

| # | Part | Approx. price |
|---|------|--------------|
| 1 | Raspberry Pi 5 4GB | ~€60 |
| 2 | Official 27W PSU | ~€12 |
| 3 | Official Active Cooler | ~€5 |
| 4 | Samsung PRO Endurance 64GB microSD | ~€12 |
| 5 | RTL-SDR Blog V4 | ~€35 |
| 6 | Ubertooth One | ~€110 |
| 7 | Powered USB hub (2-port minimum) | ~€15 |

All monitoring scripts (`baseline_scan.py`, `live_monitor.py`, `bt_scanner.py`,
`wifi_channel_map.py`, `ubertooth_listener.py`) and the display modules work
without MCP3008, potentiometers, HackRF, or a dummy load.
