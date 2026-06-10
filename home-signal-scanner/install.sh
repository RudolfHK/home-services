#!/usr/bin/env bash
# install.sh — Full system setup for the RF Monitor & Emitter stack on
#              Raspberry Pi OS 64-bit (Bookworm, aarch64).
#
# Run once after cloning the repo:
#   cd ~/rf-monitor
#   bash install.sh
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "$(date '+%T') ${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "$(date '+%T') ${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "$(date '+%T') ${RED}[ERROR]${NC} $*" >&2; exit 1; }
step()  { echo -e "\n${CYAN}══ $* ${NC}"; }

[[ "$EUID" -ne 0 ]] || error "Run as a normal user (not root). sudo will be used where needed."
[[ "$(uname -m)" == "aarch64" ]] || warn "Expected aarch64 — got $(uname -m). Continuing anyway."

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 1. System update ─────────────────────────────────────────────────────────
step "1. System update & upgrade"
sudo apt-get update -qq
sudo apt-get full-upgrade -y
sudo apt-get autoremove -y

# ── 2. Blacklist the default RTL-SDR kernel module ───────────────────────────
step "2. Blacklist dvb_usb_rtl28xxu (required for RTL-SDR Blog V4 custom driver)"
BLACKLIST_FILE=/etc/modprobe.d/rtlsdr-blacklist.conf
if [[ ! -f "$BLACKLIST_FILE" ]]; then
    echo "blacklist dvb_usb_rtl28xxu" | sudo tee "$BLACKLIST_FILE"
    echo "blacklist rtl2832"           | sudo tee -a "$BLACKLIST_FILE"
    echo "blacklist rtl2830"           | sudo tee -a "$BLACKLIST_FILE"
    info "Kernel module blacklist written to $BLACKLIST_FILE"
else
    info "Blacklist already exists — skipping."
fi

# ── 3. Build RTL-SDR Blog V4 custom driver ───────────────────────────────────
step "3. Build RTL-SDR Blog V4 custom driver"
sudo apt-get install -y cmake build-essential libusb-1.0-0-dev pkg-config git

RTL_SRC_DIR="$HOME/src/rtl-sdr-blog"
if [[ -d "$RTL_SRC_DIR" ]]; then
    info "Source already cloned — pulling latest…"
    git -C "$RTL_SRC_DIR" pull
else
    info "Cloning rtl-sdr-blog V4 driver…"
    mkdir -p "$HOME/src"
    git clone https://github.com/rtlsdrblog/rtl-sdr-blog.git "$RTL_SRC_DIR"
fi

BUILD_DIR="$RTL_SRC_DIR/build"
mkdir -p "$BUILD_DIR"
cmake -S "$RTL_SRC_DIR" -B "$BUILD_DIR" -DINSTALL_UDEV_RULES=ON -DDETACH_KERNEL_DRIVER=ON
make -C "$BUILD_DIR" -j"$(nproc)"
sudo make -C "$BUILD_DIR" install
sudo ldconfig
sudo cp "$RTL_SRC_DIR/rtl-sdr.rules" /etc/udev/rules.d/rtl-sdr.rules 2>/dev/null || true
sudo udevadm control --reload-rules && sudo udevadm trigger
info "RTL-SDR Blog V4 driver installed."

# ── 4. Install HackRF, Ubertooth, and RF utilities ───────────────────────────
step "4. Install HackRF, Ubertooth, BlueZ, and RF tools"
sudo apt-get install -y \
    hackrf \
    ubertooth \
    bluez \
    bluez-tools \
    aircrack-ng \
    wavemon \
    gnuradio \
    gqrx-sdr \
    wireless-tools \
    python3-pip \
    python3-dev \
    libffi-dev \
    sqlite3

# ── 5. Install Python dependencies ───────────────────────────────────────────
step "5. Install Python packages"
pip install -r "$REPO_DIR/requirements.txt" --break-system-packages

# ── 6. Enable SPI (MCP3008 ADC) ──────────────────────────────────────────────
step "6. Enable SPI interface"
# Non-interactive raspi-config equivalent: add dtparam=spi=on to /boot/firmware/config.txt
CONFIG_FILE=/boot/firmware/config.txt
if ! grep -q "^dtparam=spi=on" "$CONFIG_FILE" 2>/dev/null; then
    echo "dtparam=spi=on" | sudo tee -a "$CONFIG_FILE"
    info "SPI enabled in $CONFIG_FILE (takes effect after reboot)"
else
    info "SPI already enabled."
fi

# ── 7. Enable Bluetooth service ───────────────────────────────────────────────
step "7. Enable and start Bluetooth service"
sudo systemctl enable bluetooth
sudo systemctl start bluetooth || warn "Bluetooth service failed to start — check hardware."
sudo usermod -aG bluetooth "$USER"
info "User $USER added to bluetooth group."

# ── 8. Add user to plugdev for SDR USB access ─────────────────────────────────
sudo usermod -aG plugdev "$USER"
info "User $USER added to plugdev group (USB SDR access)."

# ── 9. Verification checklist ─────────────────────────────────────────────────
step "9. Verification checklist"

echo ""
echo "  Checking hardware (failures are expected if devices not yet connected):"

# RTL-SDR
printf "  %-30s" "RTL-SDR (rtl_test -t):"
if rtl_test -t 2>&1 | grep -q "Found 1 device"; then
    echo -e "${GREEN}FOUND${NC}"
else
    echo -e "${YELLOW}NOT FOUND${NC} (plug in the RTL-SDR dongle and re-check)"
fi

# HackRF
printf "  %-30s" "HackRF (hackrf_info):"
if hackrf_info 2>&1 | grep -q "Serial number"; then
    echo -e "${GREEN}FOUND${NC}"
else
    echo -e "${YELLOW}NOT FOUND${NC} (plug in HackRF and re-check)"
fi

# Ubertooth
printf "  %-30s" "Ubertooth (ubertooth-util -v):"
if ubertooth-util -v 2>&1 | grep -q "Firmware"; then
    echo -e "${GREEN}FOUND${NC}"
else
    echo -e "${YELLOW}NOT FOUND${NC} (plug in Ubertooth and re-check)"
fi

# SPI
printf "  %-30s" "SPI /dev/spidev0.0:"
if [[ -e /dev/spidev0.0 ]]; then
    echo -e "${GREEN}PRESENT${NC}"
else
    echo -e "${YELLOW}ABSENT${NC} (reboot to activate SPI, or check raspi-config)"
fi

# Bluetooth
printf "  %-30s" "Bluetooth (hciconfig):"
if hciconfig 2>&1 | grep -q "hci0"; then
    echo -e "${GREEN}PRESENT${NC}"
else
    echo -e "${YELLOW}ABSENT${NC} (check Bluetooth hardware)"
fi

echo ""
info "Installation complete."
echo ""
echo "  IMPORTANT — read before testing:"
echo "  • Run 'baseline_scan.py --mock' first to generate a baseline."
echo "  • Always connect a 50 Ω dummy load before enabling HackRF TX."
echo "  • Maximum TX power: 20 dBm EIRP (ETSI EN 300 328, German law)."
echo "  • Reboot is recommended to activate SPI and new udev rules."
echo ""
echo "  Quick test (no hardware):"
echo "    cd $REPO_DIR"
echo "    python monitor/baseline_scan.py --mock"
echo "    python test/test_sequence.py --mock"
echo ""
