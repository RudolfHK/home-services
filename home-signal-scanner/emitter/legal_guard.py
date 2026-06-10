"""
Legal guard for RF transmissions — Germany / EU compliance.

Every emitter script MUST call check_legal_params() before any transmission.
This module is the single enforcement point for:
  - ETSI EN 300 328 V2.2.2 (max 20 dBm EIRP, 10% duty cycle)
  - TKG §149(1) no.10 (jamming / interference — up to €500,000 fine)
  - FuAG / RED 2014/53/EU (uncertified TX on live band)

Never bypass or catch LegalViolationError — transmission must not proceed
if this function raises.
"""

from __future__ import annotations

import logging
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from config.settings import MAX_TX_GAIN_DB, MAX_DUTY_CYCLE, SAFE_BENCH_GAIN_DB

log = logging.getLogger(__name__)


class LegalViolationError(Exception):
    """
    Raised when a requested transmission would violate German / EU RF law.
    Catching this exception and proceeding with transmission is illegal.
    """


def check_legal_params(
    gain_db: float,
    duty_cycle: float,
    antenna_connected: bool = False,
    *,
    verbose: bool = True,
) -> None:
    """
    Validate TX parameters against German / EU legal limits.

    Parameters
    ----------
    gain_db           : Requested TX gain in dBm (must be ≤ MAX_TX_GAIN_DB = 20).
    duty_cycle        : Fraction of time transmitting (must be ≤ MAX_DUTY_CYCLE = 0.10).
    antenna_connected : Pass True if a real radiating antenna is connected.
                        A live antenna outside a shielded enclosure should only be used
                        for licensed passive-RX operations (Ubertooth, RTL-SDR).
                        TX through a live antenna can interfere with real devices and
                        violates FuAG / RED 2014/53/EU for uncertified equipment.
    verbose           : If True, print the parameter check to stdout.

    Raises
    ------
    LegalViolationError
        If gain_db > MAX_TX_GAIN_DB or duty_cycle > MAX_DUTY_CYCLE.
    """
    violations: list[str] = []

    # ── Gain check ─────────────────────────────────────────────────────────
    if gain_db > MAX_TX_GAIN_DB:
        violations.append(
            f"TX gain {gain_db:.1f} dBm exceeds the legal maximum of "
            f"{MAX_TX_GAIN_DB} dBm EIRP (ETSI EN 300 328 V2.2.2 §4.3.2). "
            f"Penalty: up to €500,000 (TKG §149)."
        )

    if gain_db < 0:
        violations.append(f"TX gain {gain_db:.1f} dBm is negative — invalid.")

    # ── Duty cycle check ────────────────────────────────────────────────────
    if duty_cycle > MAX_DUTY_CYCLE:
        violations.append(
            f"Duty cycle {duty_cycle:.1%} exceeds the legal maximum of "
            f"{MAX_DUTY_CYCLE:.0%} for non-adaptive devices "
            f"(ETSI EN 300 328 V2.2.2 §4.3.3)."
        )

    if duty_cycle < 0 or duty_cycle > 1:
        violations.append(f"Duty cycle {duty_cycle} must be between 0 and 1.")

    if violations:
        msg = "\n".join([
            "=" * 60,
            "🚫  LEGAL VIOLATION — TRANSMISSION BLOCKED",
            "=" * 60,
        ] + [f"  • {v}" for v in violations] + [
            "",
            "  Applicable law:",
            "    ETSI EN 300 328 V2.2.2 — 2.4 GHz band requirements",
            "    TKG §149(1) no.10       — intentional interference, fine up to €500,000",
            "    FuAG / RED 2014/53/EU   — uncertified radio equipment",
            "=" * 60,
        ])
        print(msg, file=sys.stderr)
        raise LegalViolationError("; ".join(violations))

    # ── Antenna warning ─────────────────────────────────────────────────────
    if antenna_connected:
        log.warning(
            "⚠️  LIVE ANTENNA DETECTED.\n"
            "  HackRF TX through a radiating antenna can interfere with real devices\n"
            "  and violates FuAG / RED 2014/53/EU for uncertified equipment.\n"
            "  Use a 50 Ω dummy load (e.g. Telegärtner J01151A0046) or a\n"
            "  shielded Faraday enclosure for all TX tests.\n"
            "  Proceeding — but you accept full legal responsibility."
        )
        print(
            "\n⚠️  WARNING: Live antenna connected. Use dummy load for TX tests.\n"
            "   Interfering with radio comms is illegal (TKG §149).\n",
            file=sys.stderr,
        )

    # ── Bench gain advisory ─────────────────────────────────────────────────
    if gain_db > SAFE_BENCH_GAIN_DB and verbose:
        print(
            f"  Advisory: gain {gain_db:.1f} dBm > bench default {SAFE_BENCH_GAIN_DB} dBm. "
            f"Ensure dummy load or shielded enclosure.",
            file=sys.stderr,
        )

    if verbose:
        print(
            f"  ✓ Legal check passed: gain={gain_db:.1f} dBm  "
            f"duty={duty_cycle:.1%}  antenna={'live' if antenna_connected else 'dummy/shielded'}"
        )


def assert_dummy_load(antenna_connected: bool) -> None:
    """
    Convenience check used by emitter scripts.
    Prints a loud warning but does not raise (antenna_connected is a soft guard).
    """
    if antenna_connected:
        print(
            "\n" + "!" * 60 + "\n"
            "  REMINDER: Connect a 50 Ω DUMMY LOAD before enabling TX.\n"
            "  Never transmit with a real antenna outside a shielded box.\n"
            "!" * 60 + "\n",
            file=sys.stderr,
        )


# ── CLI self-test ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Test the legal guard")
    parser.add_argument("--gain", type=float, default=10.0, help="TX gain dBm")
    parser.add_argument("--duty", type=float, default=0.05, help="Duty cycle 0–1")
    parser.add_argument("--antenna", action="store_true", help="Simulate live antenna")
    args = parser.parse_args()

    try:
        check_legal_params(args.gain, args.duty, args.antenna)
        print("All checks passed — transmission would be permitted.")
    except LegalViolationError as e:
        print(f"\nBlocked: {e}")
        sys.exit(1)
