"""
chart_adapter.py ? Schwab price history for the chart tile.
Uses enforce_enums=False so we can pass plain strings/ints
instead of enum members (avoids the "expected type Period" error).
"""
from __future__ import annotations

import datetime as dt
import os
from typing import Any, Dict


def _safe_float(v: Any, default: float = 0.0) -> float:
    try:
        return float(v) if v not in (None, "") else default
    except Exception:
        return default


def _get_chart_client():
    """Schwab client with enum enforcement disabled."""
    from schwab.auth import client_from_token_file
    token_path = os.getenv(
        "SCHWAB_TOKEN_PATH",
        "/mnt/c/Users/alexm/granite_trader/backend/schwab_token.json",
    )
    return client_from_token_file(
        token_path=token_path,
        api_key=os.getenv("SCHWAB_CLIENT_ID", "").strip(),
        app_secret=os.getenv("SCHWAB_CLIENT_SECRET", "").strip(),
        enforce_enums=False,   # <-- key fix; allows plain string/int params
    )


# Days per period string
_DAYS: Dict[str, int] = {
    "1d": 1, "5d": 5, "1m": 31, "3m": 92, "6m": 183,
    "1y": 365, "2y": 730, "5y": 1826, "10y": 3652,
}

# (period_type, period, frequency_type, frequency) as plain strings/ints
_PARAMS: Dict[str, tuple] = {
    "1d":  ("day",   1,  "minute",  5),
    "5d":  ("day",   5,  "minute", 15),
    "1m":  ("month", 1,  "daily",   1),
    "3m":  ("month", 3,  "daily",   1),
    "6m":  ("month", 6,  "daily",   1),
    "1y":  ("year",  1,  "daily",   1),
    "2y":  ("year",  2,  "daily",   1),
    "5y":  ("year",  5,  "daily",   1),
    "10y": ("year", 10,  "daily",   1),
    "20y": ("year", 20,  "daily",   1),
    "ytd": ("ytd",   1,  "daily",   1),
}


def get_price_history(
    symbol: str,
    period: str = "5y",
    frequency: str = "daily",
) -> Dict[str, Any]:
    client = _get_chart_client()

    pt, p, ft, f = _PARAMS.get(period, ("year", 5, "daily", 1))

    # With enforce_enums=False we can pass strings and ints directly
    resp = client.get_price_history(
        symbol.upper(),
        period_type=pt,
        period=p,
        frequency_type=ft,
        frequency=f,
        need_extended_hours_data=False,
    )

    data = resp.json() if hasattr(resp, "json") else {}
    raw  = data.get("candles", [])

    candles = sorted([
        {
            "time":   c["datetime"] // 1000,
            "open":   round(_safe_float(c.get("open")),  2),
            "high":   round(_safe_float(c.get("high")),  2),
            "low":    round(_safe_float(c.get("low")),   2),
            "close":  round(_safe_float(c.get("close")), 2),
            "volume": int(_safe_float(c.get("volume"), 0)),
        }
        for c in raw if c.get("datetime")
    ], key=lambda x: x["time"])

    return {
        "symbol":    symbol.upper(),
        "period":    period,
        "frequency": ft,
        "count":     len(candles),
        "candles":   candles,
    }
