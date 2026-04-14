"""
chart_adapter.py â€” Schwab price history for the chart tile.
Fetches OHLCV candles and returns a clean list for the frontend.
"""
from __future__ import annotations

import datetime as dt
from typing import Any, Dict, List, Optional

from schwab_adapter import _get_client


def _safe_float(v: Any, default: float = 0.0) -> float:
    try:
        if v is None or v == "":
            return default
        return float(v)
    except Exception:
        return default


def get_price_history(
    symbol: str,
    period: str = "5y",          # "1d","5d","1m","3m","6m","1y","2y","5y","10y","ytd"
    frequency: str = "daily",    # "minute","daily","weekly","monthly"
) -> Dict[str, Any]:
    """
    Fetch OHLCV candles from Schwab.
    Returns: {symbol, candles:[{time,open,high,low,close,volume},...], period, frequency}
    """
    client = _get_client()

    # Map user-friendly params to Schwab API params
    period_type_map = {
        "1d": ("day", 1),
        "5d": ("day", 5),
        "1m": ("month", 1),
        "3m": ("month", 3),
        "6m": ("month", 6),
        "1y": ("year", 1),
        "2y": ("year", 2),
        "5y": ("year", 5),
        "10y": ("year", 10),
        "ytd": ("ytd", 1),
    }
    freq_map = {
        "minute":  ("minute", 1),
        "5min":    ("minute", 5),
        "15min":   ("minute", 15),
        "30min":   ("minute", 30),
        "hourly":  ("minute", 60),
        "daily":   ("daily",  1),
        "weekly":  ("weekly", 1),
        "monthly": ("monthly",1),
    }

    period_type, period_count = period_type_map.get(period, ("year", 5))
    freq_type, freq_count     = freq_map.get(frequency, ("daily", 1))

    import schwab
    resp = client.get_price_history(
        symbol.upper(),
        period_type=getattr(schwab.client.Client.PriceHistory.PeriodType, period_type.upper(), None)
            or period_type,
        period=period_count,
        frequency_type=getattr(schwab.client.Client.PriceHistory.FrequencyType, freq_type.upper(), None)
            or freq_type,
        frequency=freq_count,
        need_extended_hours_data=False,
    )

    data = resp.json() if hasattr(resp, "json") else {}
    raw_candles = data.get("candles", [])

    candles = []
    for c in raw_candles:
        epoch_ms = c.get("datetime", 0)
        if not epoch_ms:
            continue
        # Lightweight Charts expects Unix seconds for daily, ms for intraday
        epoch_s = epoch_ms // 1000
        candles.append({
            "time":   epoch_s,
            "open":   round(_safe_float(c.get("open")),   2),
            "high":   round(_safe_float(c.get("high")),   2),
            "low":    round(_safe_float(c.get("low")),    2),
            "close":  round(_safe_float(c.get("close")),  2),
            "volume": int(_safe_float(c.get("volume"), 0)),
        })

    # Sort ascending by time (Lightweight Charts requirement)
    candles.sort(key=lambda x: x["time"])

    return {
        "symbol":    symbol.upper(),
        "period":    period,
        "frequency": frequency,
        "count":     len(candles),
        "candles":   candles,
    }
