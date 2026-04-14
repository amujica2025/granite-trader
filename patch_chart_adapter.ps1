param([string]$Root = "C:\\Users\\alexm\\granite_trader")
$ErrorActionPreference = "Stop"

$p = Join-Path $Root "backend\\chart_adapter.py"
$c = @'
"""
chart_adapter.py  ?  Schwab price history for the chart tile.

Uses start_datetime / end_datetime instead of period enums to avoid
schwab-py's strict enum enforcement (the "expected type Period" error).
"""
from __future__ import annotations

import datetime as dt
from typing import Any, Dict

from schwab_adapter import _get_client


def _safe_float(v: Any, default: float = 0.0) -> float:
    try:
        if v is None or v == "":
            return default
        return float(v)
    except Exception:
        return default


# Days to look back for each period label
_PERIOD_DAYS: Dict[str, int] = {
    "1d":  1,
    "5d":  5,
    "1m":  31,
    "3m":  92,
    "6m":  183,
    "1y":  365,
    "2y":  730,
    "5y":  1826,
    "10y": 3652,
    "ytd": 0,   # handled separately
}


def get_price_history(
    symbol: str,
    period: str = "5y",
    frequency: str = "daily",
) -> Dict[str, Any]:
    """
    Fetch OHLCV candles from Schwab.
    period   : 1d | 5d | 1m | 3m | 6m | 1y | 2y | 5y | 10y | ytd
    frequency: minute | 5min | 15min | 30min | daily | weekly | monthly
    """
    import schwab

    client = _get_client()
    C = schwab.client.Client

    # ?? Frequency enums ???????????????????????????????????????
    freq_map = {
        "minute":  (C.PriceHistory.FrequencyType.MINUTE,  C.PriceHistory.Frequency.EVERY_MINUTE),
        "5min":    (C.PriceHistory.FrequencyType.MINUTE,  C.PriceHistory.Frequency.EVERY_FIVE_MINUTES),
        "10min":   (C.PriceHistory.FrequencyType.MINUTE,  C.PriceHistory.Frequency.EVERY_TEN_MINUTES),
        "15min":   (C.PriceHistory.FrequencyType.MINUTE,  C.PriceHistory.Frequency.EVERY_FIFTEEN_MINUTES),
        "30min":   (C.PriceHistory.FrequencyType.MINUTE,  C.PriceHistory.Frequency.EVERY_THIRTY_MINUTES),
        "daily":   (C.PriceHistory.FrequencyType.DAILY,   C.PriceHistory.Frequency.DAILY),
        "weekly":  (C.PriceHistory.FrequencyType.WEEKLY,  C.PriceHistory.Frequency.WEEKLY),
        "monthly": (C.PriceHistory.FrequencyType.MONTHLY, C.PriceHistory.Frequency.MONTHLY),
    }
    freq_type, freq_val = freq_map.get(frequency, (
        C.PriceHistory.FrequencyType.DAILY,
        C.PriceHistory.Frequency.DAILY,
    ))

    # ?? Date range ????????????????????????????????????????????
    end_dt = dt.datetime.now()
    if period == "ytd":
        start_dt = dt.datetime(end_dt.year, 1, 1)
    else:
        days = _PERIOD_DAYS.get(period, 1826)
        start_dt = end_dt - dt.timedelta(days=days)

    # ?? Fetch ?????????????????????????????????????????????????
    resp = client.get_price_history(
        symbol.upper(),
        frequency_type=freq_type,
        frequency=freq_val,
        start_datetime=start_dt,
        end_datetime=end_dt,
        need_extended_hours_data=False,
    )

    data = resp.json() if hasattr(resp, "json") else {}
    raw_candles = data.get("candles", [])

    candles = []
    for c in raw_candles:
        epoch_ms = c.get("datetime", 0)
        if not epoch_ms:
            continue
        candles.append({
            "time":   epoch_ms // 1000,
            "open":   round(_safe_float(c.get("open")),  2),
            "high":   round(_safe_float(c.get("high")),  2),
            "low":    round(_safe_float(c.get("low")),   2),
            "close":  round(_safe_float(c.get("close")), 2),
            "volume": int(_safe_float(c.get("volume"), 0)),
        })

    candles.sort(key=lambda x: x["time"])

    return {
        "symbol":    symbol.upper(),
        "period":    period,
        "frequency": frequency,
        "count":     len(candles),
        "candles":   candles,
    }

'@
[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[Granite] chart_adapter.py patched" -ForegroundColor Cyan
Write-Host "[Granite] Restart the app to apply:" -ForegroundColor Yellow
Write-Host "  wsl bash -lc 'cd /mnt/c/Users/alexm/granite_trader && ./install_and_run_wsl.sh'" -ForegroundColor White
Write-Host "[Granite] Then click LOAD in the chart tile - no rebuild needed (Python only)" -ForegroundColor Green
