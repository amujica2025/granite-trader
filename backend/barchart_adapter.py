from __future__ import annotations

import csv
import json
import os
from pathlib import Path
from typing import Any, Dict, List, Optional

PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WATCHLIST_PATH = PROJECT_ROOT / "data" / "barchart" / "watchlists" / "weeklys_latest.csv"
DEFAULT_CHAIN_DIR = PROJECT_ROOT / "data" / "barchart" / "chains"


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _safe_float(value: Any) -> Optional[float]:
    try:
        if value is None:
            return None
        text = str(value).strip().replace(",", "").replace("%", "")
        if text == "":
            return None
        return float(text)
    except Exception:
        return None


def _safe_bool(value: Any) -> Optional[bool]:
    if value is None:
        return None
    text = str(value).strip().lower()
    if text in {"true", "1", "yes", "y"}:
        return True
    if text in {"false", "0", "no", "n"}:
        return False
    return None


# ---------------------------------------------------------------------------
# Path resolution
# ---------------------------------------------------------------------------

def get_watchlist_csv_path() -> Path:
    configured = os.getenv("BARCHART_WATCHLIST_CSV_PATH", "").strip()
    return Path(configured) if configured else DEFAULT_WATCHLIST_PATH


def get_chain_dir() -> Path:
    configured = os.getenv("BARCHART_CHAIN_DIR", "").strip()
    return Path(configured) if configured else DEFAULT_CHAIN_DIR


# ---------------------------------------------------------------------------
# Watchlist CSV loading
# ---------------------------------------------------------------------------

def load_watchlist_rows() -> List[Dict[str, Any]]:
    path = get_watchlist_csv_path()
    if not path.exists():
        return []
    with path.open(encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f)
        return [dict(row) for row in reader]


def get_watchlist_row(symbol: str) -> Dict[str, Any]:
    symbol_upper = symbol.upper()
    for row in load_watchlist_rows():
        candidate = str(row.get("Symbol", row.get("symbol", ""))).strip().upper()
        if candidate == symbol_upper:
            return row
    return {}


def normalize_watchlist_row(row: Dict[str, Any]) -> Dict[str, Any]:
    """
    Map Barchart watchlist CSV columns â†’ canonical symbol_snapshot schema.

    Column names are matched case-insensitively.  Unknown columns are ignored.
    Any field that can't be parsed is left as None so the normalized store
    stays schema-consistent regardless of which columns exist in the CSV.
    """
    def get(key: str) -> Any:
        for k, v in row.items():
            if k.strip().lower() == key.lower():
                return v
        return None

    symbol = str(get("Symbol") or get("symbol") or "").strip().upper()
    return {
        "symbol": symbol,
        "last_price": _safe_float(get("Last") or get("latest") or get("last")),
        "pct_change": _safe_float(get("%Change") or get("pct_change")),
        "imp_vol": _safe_float(get("Imp Vol") or get("imp_vol")),
        "iv_percentile": _safe_float(get("IV Pctl") or get("iv_percentile")),
        "iv_hv_ratio": _safe_float(get("IV/HV") or get("iv_hv_ratio")),
        "iv_5d": _safe_float(get("5D IV") or get("iv_5d")),
        "iv_1m": _safe_float(get("1M IV") or get("iv_1m")),
        "iv_3m": _safe_float(get("3M IV") or get("iv_3m")),
        "iv_6m": _safe_float(get("6M IV") or get("iv_6m")),
        "rel_strength_14d": _safe_float(get("14D Rel Strength") or get("rel_strength_14d")),
        "bb_pct": _safe_float(get("BB%") or get("bb_pct")),
        "bb_rank": _safe_float(get("BB Rank") or get("bb_rank")),
        "ttm_squeeze": _safe_float(get("TTM Squeeze") or get("ttm_squeeze")),
        "adr_14d": _safe_float(get("14D ADR") or get("adr_14d")),
        "options_volume": _safe_float(get("Options Vol") or get("options_volume")),
        "total_volume_1m": _safe_float(get("1M Total Vol") or get("total_volume_1m")),
        "call_volume": _safe_float(get("Call Volume") or get("call_volume")),
        "put_volume": _safe_float(get("Put Volume") or get("put_volume")),
        "put_call_ratio": _safe_float(get("Put/Call Ratio") or get("put_call_ratio")),
        "low_flag": _safe_bool(get("Low Flag") or get("low_flag")),
        "high_flag": _safe_bool(get("High Flag") or get("high_flag")),
        "notes": str(get("Notes") or get("notes") or "").strip() or None,
        "source": "barchart",
    }


# ---------------------------------------------------------------------------
# Processed chain snapshot (JSON files placed by the user / scraper)
# ---------------------------------------------------------------------------

def load_processed_chain_snapshot(symbol: str) -> Dict[str, Any]:
    """
    Load a pre-processed Barchart chain JSON from data/barchart/chains/<SYMBOL>.json.

    Expected shape:
      {
        "symbol": "SPY",
        "underlying_price": 525.12,
        "expirations": ["2026-04-17", ...],
        "strikes": [520.0, 521.0, ...],
        "contracts": [
          {
            "underlying": "SPY",
            "option_side": "call",
            "expiration": "2026-04-17",
            "days_to_expiration": 4,
            "strike": 520.0,
            "bid": 4.2,  "ask": 4.35,  "mark": 4.275,  "mid": 4.275,
            "delta": 0.41,  "iv": 0.182,
            "total_volume": 1200,  "open_interest": 9300,
            "option_symbol": "SPY   260417C00520000",
            "description": "",
            "underlying_price": 525.12
          }, ...
        ]
      }
    """
    chain_dir = get_chain_dir()
    path = chain_dir / f"{symbol.upper()}.json"
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


# ---------------------------------------------------------------------------
# Public entry point called by cache_manager
# ---------------------------------------------------------------------------

def refresh_symbol_from_barchart(
    symbol: str,
    fallback_quote_raw: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """
    Build a normalized symbol state dict from:
      1. Watchlist CSV row (watchlist-level fields)
      2. Pre-processed chain JSON (contract-level data)

    If the chain JSON is missing the system falls back to any existing cached
    Schwab contracts (handled in cache_manager).
    """
    watchlist_row = normalize_watchlist_row(get_watchlist_row(symbol))
    chain_payload = load_processed_chain_snapshot(symbol)

    contracts = list(chain_payload.get("contracts", []))
    expirations = list(chain_payload.get("expirations", []))
    strikes = list(chain_payload.get("strikes", []))
    underlying_price = chain_payload.get("underlying_price") or watchlist_row.get("last_price")

    return {
        "symbol": symbol.upper(),
        "active_chain_source": "barchart",
        "quote_source": "schwab" if fallback_quote_raw else "barchart",
        "quote_raw": fallback_quote_raw or {},
        "quote_snapshot": {},
        "contracts": contracts,
        "expirations": expirations,
        "strikes": strikes,
        "underlying_price": underlying_price,
        "symbol_snapshot": watchlist_row,
        "metadata": {
            "barchart_watchlist_path": str(get_watchlist_csv_path()),
            "barchart_chain_dir": str(get_chain_dir()),
            "barchart_chain_loaded": bool(contracts),
        },
    }
