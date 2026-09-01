# OS + Docker Setup Guide

Step-by-step instructions for a fresh Raspberry Pi 5 from bare metal to a running
Docker stack. Follow these in order.

---

## 1. Flash Raspberry Pi OS

1. Download **Raspberry Pi Imager** from https://www.raspberrypi.com/software/
2. Insert the microSD card (or connect the NVMe drive via USB adapter).
3. In Imager:
   - **Device:** Raspberry Pi 5
   - **OS:** Raspberry Pi OS Lite (64-bit); no desktop needed.
   - **Storage:** Your SD card / NVMe drive.
4. Click the **gear icon** (or press Ctrl+Shift+X) to open OS Customisation:
   - ✅ Set hostname: `homepi` (or whatever you set as `TS_HOSTNAME`)
   - ✅ Enable SSH → use password authentication (you can add a key later)
   - ✅ Set username + password
   - ✅ Configure Wi-Fi (SSID + password, country code); optional if using Ethernet
   - ✅ Set locale / timezone
5. Write the image.

---

## 2. First Boot

Connect power + Ethernet. Give it 60 seconds to boot, then:

```bash
# Find the Pi's IP (check your router, or use nmap)
# nmap -sn 192.168.1.0/24 | grep homepi

ssh pi@homepi.local        # or ssh pi@<IP>
```

### Update the system

```bash
sudo apt-get update && sudo apt-get full-upgrade -y
sudo apt-get autoremove -y
sudo reboot
```

### Harden SSH (key-only authentication)

```bash
# On your laptop, generate a key if you don't have one
ssh-keygen -t ed25519 -C "homepi"

# Copy the public key to the Pi
ssh-copy-id pi@homepi.local

# On the Pi: disable password authentication
sudo nano /etc/ssh/sshd_config
```

Set these values in `/etc/ssh/sshd_config`:
```
PasswordAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
```

```bash
sudo systemctl restart sshd
```

---

## 3. Mount the External Data Drive

```bash
# Identify the drive
lsblk -f

# Run the mount helper script (format + fstab)
sudo bash scripts/mount-drive.sh
```

Verify:
```bash
df -h /mnt/data
```

---

## 4. Install Docker

```bash
# Official install script — works on ARM64
curl -fsSL https://get.docker.com | sh

# Add your user to the docker group (avoids needing sudo for docker commands)
sudo usermod -aG docker $USER

# Apply the group change without logging out
newgrp docker

# Verify
docker version
docker compose version
```

---

## 5. Configure UFW Firewall

Home Drive is reachable directly on the LAN, so the firewall's job is to keep it off
everything else: allow LAN SSH and LAN access to Nextcloud's port, deny everything else
incoming.

```bash
sudo apt-get install -y ufw fail2ban

# Default: deny all incoming, allow all outgoing
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Find YOUR LAN subnet first. Do not copy the example below verbatim; allowing
# the wrong subnet and then enabling ufw locks you out of SSH.
ip -br -4 addr show eth0        # e.g. 192.168.1.59/24 → use 192.168.1.0/24
LAN=192.168.1.0/24              # <- change this to match

# Allow SSH and Nextcloud (NEXTCLOUD_PORT) from your local network only
sudo ufw allow from "$LAN" to any port 22 proto tcp
sudo ufw allow from "$LAN" to any port 80 proto tcp

# Enable the firewall
sudo ufw enable
sudo ufw status verbose
```

If you also enable the optional `tailscale` profile, do **not** add
`ufw allow in on tailscale0`: Tailscale runs *inside a container* in this stack, so
`tailscale0` exists only in that container's network namespace, not on the host. There is no
such interface for UFW to match, and tailnet traffic reaches the container as
conntrack-established return traffic on the Docker bridge, which UFW already permits.

### fail2ban (brute-force SSH protection)

```bash
# Default config is good enough for a home server
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Check status
sudo fail2ban-client status sshd
```

---

## 6. Optional: Boot from NVMe

If you have a PCIe HAT with an NVMe SSD:

```bash
# Update bootloader (run on a Pi that is already booted from SD)
sudo rpi-eeprom-update -a
sudo reboot

# After reboot, check EEPROM is up to date
sudo rpi-eeprom-update

# Flash the NVMe SSD with Raspberry Pi OS Lite 64-bit using Imager
# (attach the NVMe via USB-C adapter temporarily)

# Change boot order to prefer NVMe
sudo raspi-config
# → Advanced Options → Boot Order → NVMe/USB Boot → OK → Finish → Reboot
```

The Pi will now boot from NVMe on the PCIe HAT.

---

## 7. Clone the Project and Launch

```bash
# Clone the repo
git clone https://github.com/<you>/home-services.git ~/home-services
cd ~/home-services/home-drive

# Copy and edit the environment file
cp .env.example .env
chmod 600 .env
nano .env   # fill in NEXTCLOUD_LAN_HOSTNAME, passwords, DATA_PATH, etc.

# Run the install script
bash scripts/install.sh
```

---

## Useful Commands

```bash
# View running containers
docker compose ps

# View logs for a service
docker compose logs -f nextcloud-app
docker compose logs -f nextcloud-web
docker compose logs -f nextcloud-db

# Restart a single service
docker compose restart nextcloud-app

# Stop everything
docker compose down

# Pull latest images and restart
docker compose pull && docker compose up -d
```
