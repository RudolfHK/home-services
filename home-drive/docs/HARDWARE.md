# Hardware Guide: Raspberry Pi 5 Home Drive

This page lists every piece of hardware recommended for a reliable, always-on home drive
running the Nextcloud stack.

---

## Core Components

### Raspberry Pi 5

| Variant | Notes |
|---------|-------|
| 4 GB RAM | Sufficient for this stack (Nextcloud, PostgreSQL and Redis together run at roughly 900 MB at idle). |
| 8 GB RAM | Recommended if you plan to add more services later (PiHub, Home Assistant, etc.). |

The Pi 5 uses a **PCIe 2.0 x1** lane exposed via the FPC connector on the board. This is
what makes NVMe storage practical for the first time on a Pi.

---

### Power Supply

Use the **official Raspberry Pi 27 W USB-C PD power supply**.  
The Pi 5 draws up to ~12 W under load; connected USB peripherals can draw more. A
under-powered supply causes throttling and SD card corruption.

- Do **not** use phone chargers or cheap USB-C cables.
- If powering the Pi from a UPS/battery, make sure it can supply 5 V @ 5 A (25 W).

---

### Cooling

The Pi 5 runs hot. Sustained CPU loads easily hit 80 °C without active cooling, which
triggers thermal throttling and slows the whole stack.

**Recommended options (pick one):**

| Option | Notes |
|--------|-------|
| Official Raspberry Pi Active Cooler | Clips directly onto the Pi 5 GPIO header. Includes a small blower fan and heatsink plate. Best thermal performance. |
| Argon ONE V3 case | Full aluminium case with passive conduction + optional fan. Looks good, blocks some GPIO pins. |
| KKSB / Pimoroni cases with fans | Third-party cases with decent airflow, leave GPIO accessible. |

---

### Storage: OS Drive

| Option | Notes |
|--------|-------|
| **NVMe SSD via PCIe HAT** (recommended) | Fastest option. Get a HAT that exposes the PCIe FPC connector as an M.2 slot (e.g. Pimoroni NVMe Base, Waveshare PCIe to M.2 HAT). Any PCIe Gen 2/3 M.2 2230/2242/2280 NVMe works. 64–256 GB is plenty for the OS + Docker layers. |
| microSD A2 Class 32 GB+ | Works but is slower and less durable for continuous write workloads (Docker logs, PostgreSQL writes). Use a high-endurance card (Samsung Pro Endurance, SanDisk Max Endurance). |

To boot from NVMe, flash the NVMe SSD with Raspberry Pi Imager, then update the boot
order in `raspi-config` → Advanced Options → Boot Order → NVMe/USB Boot.

---

### Storage: Data Drive (external)

All Nextcloud data lives on a **separate** drive from the OS.
This makes backups, replacements, and re-imaging the OS much easier.

| Option | Notes |
|--------|-------|
| **USB 3.0 SSD in an enclosure** (recommended) | Fast, silent, portable. Any SATA SSD + a USB 3.0 UASP enclosure (e.g. UGREEN, Inatek) works. 1–4 TB is a practical size. |
| NVMe in a USB 3.2 Gen 2 enclosure | Even faster, same idea. Overkill for a home drive but fine. |
| USB 3.0 spinning hard drive | Large and cheap but draws more power (needs a powered USB hub) and is slower. |

> **Important:** Plug the data drive into a **blue USB 3.0 port** on the Pi, not a black
> USB 2.0 port. The Pi 5 has two of each.

---

### Networking

- **Gigabit Ethernet**: always prefer wired over Wi-Fi for a server. The Pi 5 has a true
  Gigabit NIC (not shared with USB like earlier Pis).
- Wi-Fi is fine for testing but introduces latency and reliability issues for sync workloads.

---

### Optional: UPS HAT

A brief power cut will corrupt the PostgreSQL data files if the Pi shuts down uncleanly.
A mini UPS HAT (e.g. Pisugar 3, Waveshare UPS HAT) gives the Pi ~15–30 minutes to shut
down gracefully.

Configure the Pi to watch the UPS GPIO pin and call `sudo shutdown -h now` when power is
lost:

```bash
# Example using Pisugar's daemon (varies by HAT)
sudo pisugar-server --config /etc/pisugar-server/config.json
```

---

### Optional: Powered USB Hub

If you use a spinning hard drive for data *and* other USB peripherals, use a **powered
USB hub** so the drive gets stable current. Bus-powered spinning drives frequently drop
off the USB bus under load.

---

## Minimal Shopping List

1. Raspberry Pi 5 (4 GB or 8 GB)
2. Official 27 W USB-C power supply
3. Official Active Cooler (or a case with a fan)
4. microSD A2 32 GB (for OS, if not using NVMe)
5. USB 3.0 SSD in an enclosure (data drive, 1 TB recommended)
6. Short Cat 6 Ethernet cable
