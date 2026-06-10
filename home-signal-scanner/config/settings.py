"""
Central configuration for the RF Monitor & Emitter stack.
All modules import constants from here — no magic numbers inline.
"""

# ── Bluetooth 2.4 GHz band ────────────────────────────────────────────────────
BT_FREQ_MIN_MHZ: int = 2402
BT_FREQ_MAX_MHZ: int = 2480
BT_CHANNEL_COUNT: int = 79          # channels 0–78

# ── Wi-Fi 2.4 GHz channels → center frequency (MHz) ─────────────────────────
WIFI_24_CHANNELS: dict[int, int] = {
    1:  2412,
    2:  2417,
    3:  2422,
    4:  2427,
    5:  2432,
    6:  2437,
    7:  2442,
    8:  2447,
    9:  2452,
    10: 2457,
    11: 2462,
    12: 2467,
    13: 2472,
    14: 2484,
}

# ── Legal TX limits (Germany / EU — ETSI EN 300 328 V2.2.2) ──────────────────
MAX_TX_GAIN_DB: int = 20            # hard legal ceiling — EIRP 20 dBm
SAFE_BENCH_GAIN_DB: int = 10        # recommended bench default (dummy load)
MAX_DUTY_CYCLE: float = 0.10        # 10% for non-adaptive devices

# ── RTL-SDR / monitoring defaults ────────────────────────────────────────────
NOISE_FLOOR_DBM: float = -90.0      # typical RTL-SDR V4 noise floor
ALERT_THRESHOLD_DB: float = 15.0    # delta above baseline → ⚠️  SIGNAL
STRONG_TX_THRESHOLD_DB: float = 30.0  # delta above baseline → 🚨 STRONG TX

# Sweep parameters
SWEEP_STEP_MHZ: int = 2             # 2 MHz steps across BT band
SWEEP_SAMPLE_COUNT: int = 65536     # 64K samples per frequency point
RTL_SAMPLE_RATE: int = 2_400_000    # 2.4 MS/s

# ── HackRF emitter defaults ───────────────────────────────────────────────────
HACKRF_SAMPLE_RATE: int = 2_000_000
HACKRF_AMP_ENABLED: int = 0         # amp OFF for all bench tests (safety)

# ── Bluetooth scanning thresholds ─────────────────────────────────────────────
BLE_STORM_THRESHOLD: int = 20       # unique BLE MACs per window
BLE_FLOOD_THRESHOLD: int = 30
CLASSIC_BT_HIGH_DENSITY: int = 15   # classic BT devices in scan
BLE_SCAN_WINDOW_SEC: int = 10

# ── Wi-Fi congestion thresholds ───────────────────────────────────────────────
WIFI_CONGESTED_THRESHOLD: int = 4   # networks per channel → ⚠️
WIFI_JAMMED_THRESHOLD: int = 10     # networks per channel → 🚨 JAMMED?
WIFI_HIDDEN_THRESHOLD: int = 3      # hidden networks before alert
WIFI_ABNORMAL_SIGNAL_DBM: int = -20 # suspiciously strong signal

# ── ADC / potentiometer ───────────────────────────────────────────────────────
ADC_MAX_RAW: int = 1023             # MCP3008 10-bit
SPI_BUS: int = 0
SPI_DEVICE: int = 0
SPI_SPEED_HZ: int = 1_350_000

# ── Duty cycle timing ─────────────────────────────────────────────────────────
POT_EMITTER_ON_MS: int = 100        # TX burst length (emit_with_pot.py)
POT_EMITTER_SLEEP_MS: int = 900     # silence period → 10% duty cycle

# ── Paths ─────────────────────────────────────────────────────────────────────
BASELINE_JSON_PATH: str = "baseline.json"
UBERTOOTH_LOG_PATH: str = "ubertooth_log.jsonl"
CARRIER_SIGNAL_PATH: str = "/tmp/carrier_signal.bin"
