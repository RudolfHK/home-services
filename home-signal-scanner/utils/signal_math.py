"""
FFT helpers, power calculations, and jamming detection math.
All functions operate on numpy arrays and return plain Python floats / dicts.
"""

from __future__ import annotations

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import numpy as np
from numpy.typing import NDArray

from config.settings import NOISE_FLOOR_DBM, ALERT_THRESHOLD_DB


def compute_power_dbm(iq_samples: NDArray[np.complex64 | np.float32]) -> float:
    """
    Compute mean power in dBm from a block of IQ samples.

    The IQ samples can be:
    - Complex64 array (RTL-SDR raw output after bytes→complex conversion)
    - Interleaved float32 [I0, Q0, I1, Q1, …] — converted internally

    Returns power in dBm (referenced to 1 mW into 50 Ω, approximate).
    """
    if iq_samples.dtype != np.complex64 and iq_samples.dtype != np.complex128:
        # Treat as interleaved I/Q floats
        floats = iq_samples.astype(np.float32)
        if floats.ndim == 1 and len(floats) % 2 == 0:
            iq_samples = floats[0::2] + 1j * floats[1::2]
        else:
            raise ValueError("Cannot interpret iq_samples as IQ data")

    # FFT → power spectrum
    spectrum = np.fft.fft(iq_samples)
    power_linear = np.abs(spectrum) ** 2 / len(spectrum)
    mean_power = float(np.mean(power_linear))

    # Guard against log(0)
    if mean_power <= 0:
        return NOISE_FLOOR_DBM

    power_dbm = 10.0 * np.log10(mean_power + 1e-12)
    # Clamp at a sensible floor so callers never see -inf
    return max(power_dbm, NOISE_FLOOR_DBM)


def compute_peak_power_dbm(iq_samples: NDArray) -> float:
    """Return peak (max) power bin in dBm rather than mean."""
    if iq_samples.dtype not in (np.complex64, np.complex128):
        floats = iq_samples.astype(np.float32)
        iq_samples = floats[0::2] + 1j * floats[1::2]

    spectrum = np.fft.fft(iq_samples)
    power_linear = np.abs(spectrum) ** 2 / len(spectrum)
    peak = float(np.max(power_linear))
    return max(10.0 * np.log10(peak + 1e-12), NOISE_FLOOR_DBM)


def detect_jamming(
    power_spectrum: dict[int, float],
    noise_floor: float = NOISE_FLOOR_DBM,
    threshold: float = ALERT_THRESHOLD_DB,
) -> dict[str, bool | float]:
    """
    Analyse a power spectrum dict {freq_mhz: power_dbm} for jamming signatures.

    Jamming signature (wideband jammer):
    - Average power across all frequencies is above (noise_floor + threshold)
    - Standard deviation of power values is low (flat = jammer, not a single spike)

    Returns::
        {
            "is_jammed": bool,
            "avg_power": float,   # dBm
            "std_power": float,   # dB — low std = flat spectrum
            "elevated_channels": int,  # channels above threshold
        }
    """
    if not power_spectrum:
        return {"is_jammed": False, "avg_power": noise_floor, "std_power": 0.0,
                "elevated_channels": 0}

    values = np.array(list(power_spectrum.values()), dtype=np.float64)
    avg_power = float(np.mean(values))
    std_power = float(np.std(values))
    elevated = int(np.sum(values > (noise_floor + threshold)))

    # Flat raised floor (std < 5 dB) AND elevated average = jammer
    is_jammed = (avg_power > noise_floor + threshold) and (std_power < 5.0)

    return {
        "is_jammed": is_jammed,
        "avg_power": avg_power,
        "std_power": std_power,
        "elevated_channels": elevated,
    }


def delta_spectrum(
    current: dict[int, float],
    baseline: dict[int, float],
) -> dict[int, float]:
    """Return {freq_mhz: delta_db} for frequencies present in both dicts."""
    return {
        freq: current[freq] - baseline[freq]
        for freq in current
        if freq in baseline
    }


def generate_iq_carrier(
    freq_offset_hz: float = 0.0,
    sample_rate: int = 2_000_000,
    duration_sec: float = 1.0,
    amplitude: float = 0.9,
) -> NDArray[np.complex64]:
    """
    Generate a constant-power IQ carrier tone suitable for HackRF transmission.

    freq_offset_hz — offset from the centre frequency (0 = DC carrier).
    amplitude      — peak amplitude 0–1 (keep ≤ 0.9 to avoid clipping).
    """
    n_samples = int(sample_rate * duration_sec)
    t = np.arange(n_samples, dtype=np.float64) / sample_rate
    phase = 2.0 * np.pi * freq_offset_hz * t
    iq = amplitude * (np.cos(phase) + 1j * np.sin(phase))
    return iq.astype(np.complex64)


def generate_iq_noise(
    sample_rate: int = 2_000_000,
    duration_sec: float = 1.0,
    amplitude: float = 0.5,
) -> NDArray[np.complex64]:
    """Generate bandlimited AWGN IQ noise (for sweep / congestion simulation)."""
    n_samples = int(sample_rate * duration_sec)
    rng = np.random.default_rng()
    i_noise = rng.standard_normal(n_samples).astype(np.float32) * amplitude
    q_noise = rng.standard_normal(n_samples).astype(np.float32) * amplitude
    return (i_noise + 1j * q_noise).astype(np.complex64)


def iq_to_bytes(iq: NDArray[np.complex64]) -> bytes:
    """Interleave I/Q as int8 pairs — format expected by hackrf_transfer."""
    i_int8 = np.clip(np.real(iq) * 127, -128, 127).astype(np.int8)
    q_int8 = np.clip(np.imag(iq) * 127, -128, 127).astype(np.int8)
    interleaved = np.empty(len(iq) * 2, dtype=np.int8)
    interleaved[0::2] = i_int8
    interleaved[1::2] = q_int8
    return interleaved.tobytes()


# ── CLI ───────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Signal math utilities demo")
    parser.add_argument("--demo", action="store_true", help="Run a quick self-test")
    args = parser.parse_args()

    if args.demo:
        rng = np.random.default_rng(42)
        # Fake IQ block (noise floor ~-90 dBm)
        iq = (rng.standard_normal(65536) * 0.001 + 1j * rng.standard_normal(65536) * 0.001).astype(np.complex64)
        pwr = compute_power_dbm(iq)
        print(f"Noise-floor IQ block → {pwr:.1f} dBm")

        carrier = generate_iq_carrier(freq_offset_hz=1e6, duration_sec=0.01)
        pwr2 = compute_power_dbm(carrier)
        print(f"0.9-amplitude carrier → {pwr2:.1f} dBm")

        fake_spectrum = {freq: -85.0 + (5.0 if freq == 2440 else 0) for freq in range(2402, 2481, 2)}
        result = detect_jamming(fake_spectrum)
        print(f"Single-spike spectrum jamming detect: {result}")

        jammed_spectrum = {freq: -60.0 for freq in range(2402, 2481, 2)}
        result2 = detect_jamming(jammed_spectrum)
        print(f"Flat +30 dB spectrum jamming detect: {result2}")
    else:
        parser.print_help()
