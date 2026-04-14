param(
    [switch]$SkipGit,
    [switch]$SkipPipSync,
    [string]$Root = "C:\Users\alexm\granite_trader"
)

$ErrorActionPreference = "Stop"

$BACKEND = Join-Path $Root "backend"
$BACKUPS = Join-Path $Root "_installer_backups"

function Write-Info([string]$m) { Write-Host "[Granite] $m" -ForegroundColor Cyan }
function Write-Warn([string]$m) { Write-Host "[Granite] $m" -ForegroundColor Yellow }
function Write-OK([string]$m)   { Write-Host "[Granite] $m" -ForegroundColor Green }

if (-not (Test-Path $Root))    { throw "Project root not found: $Root" }
if (-not (Test-Path $BACKEND)) { throw "backend/ folder not found at: $BACKEND" }

# Backup existing backend files
$ts        = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $BACKUPS $ts
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item "$BACKEND\*" $backupDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Info "Backup written to: $backupDir"

function Ensure-Dir([string]$p) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
}

function Write-TextFile([string]$rel, [string]$text) {
    $target = Join-Path $Root $rel
    Ensure-Dir (Split-Path $target -Parent)
    [System.IO.File]::WriteAllText(
        $target,
        $text,
        (New-Object System.Text.UTF8Encoding($false))
    )
    Write-Info "  wrote $rel"
}

# Create data directories
Write-Info "Creating data directories..."
@(
    "data",
    "data\archive",
    "data\barchart",
    "data\barchart\chains",
    "data\barchart\watchlists",
    "data\barchart\html"
) | ForEach-Object { Ensure-Dir (Join-Path $Root $_) }

# .gitignore
Write-Info "Writing root config files..."
Write-TextFile ".gitignore" ".env`n.env.local`n__pycache__/`n*.pyc`n*.pyo`n*.log`nvenv/`nnode_modules/`nbackend/schwab_token.json`n_installer_backups/`n_backups/`ndata/archive/`ndata/barchart/chains/`ndata/barchart/watchlists/`ndata/barchart/html/`n"

# requirements.txt
Write-TextFile "requirements.txt" "fastapi`nuvicorn`nrequests`npython-multipart`nschwab-py`ntastytrade`npython-dotenv`nbeautifulsoup4`n"

# .env.example (only if missing)
$envExPath = Join-Path $Root ".env.example"
if (-not (Test-Path $envExPath)) {
    Write-TextFile ".env.example" "SCHWAB_CLIENT_ID=`nSCHWAB_CLIENT_SECRET=`nSCHWAB_REDIRECT_URI=https://127.0.0.1`nSCHWAB_TOKEN_PATH=/mnt/c/Users/alexm/granite_trader/backend/schwab_token.json`nTASTY_CLIENT_SECRET=`nTASTY_REFRESH_TOKEN=`nTASTY_ACCOUNT_NUMBER=`nCHAIN_REFRESH_SECONDS=300`nDEFAULT_CHAIN_STRIKE_COUNT=200`nDEFAULT_MAX_EXPIRATIONS=7`nBARCHART_WATCHLIST_CSV_PATH=/mnt/c/Users/alexm/granite_trader/data/barchart/watchlists/weeklys_latest.csv`nBARCHART_CHAIN_DIR=/mnt/c/Users/alexm/granite_trader/data/barchart/chains`n"
}

# Backend Python files
Write-Info "Writing backend source files..."

$c = @'
from __future__ import annotations

import threading
import time
from typing import Any, Dict, List


class DataStore:
    """
    Thread-safe in-memory store for normalized symbol state.

    Each symbol entry holds:
      - quote_raw / quote_snapshot  (from Schwab)
      - contracts                   (flat list of normalized option contracts)
      - expirations / strikes        (sorted subsets for the active 7 expirations)
      - underlying_price
      - symbol_snapshot             (watchlist-style derived fields)
      - active_chain_source         (schwab | barchart)
      - metadata
      - timing bookmarks

    Both scanner.py and vol_surface.py read from here.
    """

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._symbols: Dict[str, Dict[str, Any]] = {}

    # ------------------------------------------------------------------
    # writes
    # ------------------------------------------------------------------

    def upsert_symbol_state(self, symbol: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        key = symbol.upper()
        with self._lock:
            existing = self._symbols.get(key, {})
            merged = dict(existing)
            merged.update(payload)
            merged["symbol"] = key
            if "updated_at_epoch" not in merged:
                merged["updated_at_epoch"] = time.time()
            self._symbols[key] = merged
            return dict(merged)

    def clear(self) -> None:
        with self._lock:
            self._symbols.clear()

    # ------------------------------------------------------------------
    # reads
    # ------------------------------------------------------------------

    def get_symbol_state(self, symbol: str) -> Dict[str, Any]:
        with self._lock:
            return dict(self._symbols.get(symbol.upper(), {}))

    def list_symbols(self) -> List[str]:
        with self._lock:
            return sorted(self._symbols.keys())

    def snapshot_all(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            return {k: dict(v) for k, v in self._symbols.items()}


# singleton
store = DataStore()

'@
Write-TextFile "backend\data_store.py" $c

$c = @'
from __future__ import annotations

import datetime as dt
from zoneinfo import ZoneInfo

PACIFIC = ZoneInfo("America/Los_Angeles")


def now_pacific() -> dt.datetime:
    return dt.datetime.now(PACIFIC)


def is_weekday(ts: dt.datetime | None = None) -> bool:
    value = ts or now_pacific()
    return value.weekday() < 5  # 0=Mon … 4=Fri


def is_chain_refresh_window(ts: dt.datetime | None = None) -> bool:
    """
    True during normal Schwab chain-fetch hours:
    Monday–Friday, 06:30–13:15 Pacific (market open to 30 min before close).
    """
    value = ts or now_pacific()
    if not is_weekday(value):
        return False
    start = value.replace(hour=6, minute=30, second=0, microsecond=0)
    stop = value.replace(hour=13, minute=15, second=0, microsecond=0)
    return start <= value <= stop


def is_afterhours_barchart_window(ts: dt.datetime | None = None) -> bool:
    """
    True when we should rely on Barchart processed data instead of live Schwab chains.
    Roughly: after 4 PM Pacific until 5 AM Pacific next day.
    """
    value = ts or now_pacific()
    hour_min = (value.hour, value.minute)
    return hour_min >= (16, 0) or hour_min < (5, 0)


def is_eod_archive_time(ts: dt.datetime | None = None) -> bool:
    """True at or after 4:00 PM Pacific — triggers EOD archive/clear."""
    value = ts or now_pacific()
    return (value.hour, value.minute) >= (16, 0)


def is_overnight_refresh_time(ts: dt.datetime | None = None) -> bool:
    """
    True at midnight (00:00) or 3 AM Pacific.
    The scheduler checks once per minute so we only need to match the exact minute.
    """
    value = ts or now_pacific()
    return (value.hour, value.minute) in {(0, 0), (3, 0)}

'@
Write-TextFile "backend\market_clock.py" $c

$c = @'
from __future__ import annotations

from market_clock import is_afterhours_barchart_window


def get_active_chain_source() -> str:
    """
    Returns 'schwab' during market-hours chain-fetch windows,
    'barchart' after hours / overnight.
    """
    return "barchart" if is_afterhours_barchart_window() else "schwab"


def get_active_quote_source() -> str:
    """
    Quote source can be switched independently later (e.g. futures overnight).
    For now always Schwab.
    """
    return "schwab"

'@
Write-TextFile "backend\source_router.py" $c

$c = @'
from __future__ import annotations

import json
from datetime import datetime
from pathlib import Path
from typing import Any, Dict

# Resolve relative to this file so it works from any CWD.
PROJECT_ROOT = Path(__file__).resolve().parents[1]
ARCHIVE_ROOT = PROJECT_ROOT / "data" / "archive"


def archive_symbol_state(state: Dict[str, Any], reason: str = "snapshot") -> Path:
    """
    Write a dated JSON snapshot of `state` to data/archive/<date>/<symbol>/<time>_<reason>.json.
    Returns the path written.
    """
    symbol = str(state.get("symbol", "UNKNOWN")).upper()
    date_part = datetime.now().strftime("%Y-%m-%d")
    time_part = datetime.now().strftime("%H%M%S")

    target_dir = ARCHIVE_ROOT / date_part / symbol
    target_dir.mkdir(parents=True, exist_ok=True)

    target_path = target_dir / f"{time_part}_{reason}.json"
    target_path.write_text(json.dumps(state, indent=2, default=str), encoding="utf-8")
    return target_path

'@
Write-TextFile "backend\archive_manager.py" $c

$c = @'
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
    Map Barchart watchlist CSV columns → canonical symbol_snapshot schema.

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

'@
Write-TextFile "backend\barchart_adapter.py" $c

$c = @'
from __future__ import annotations

import datetime as dt
import os
from collections import Counter
from statistics import mean
from typing import Any, Dict, List, Optional

from schwab.auth import client_from_token_file


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def _get_client():
    api_key = os.getenv("SCHWAB_CLIENT_ID", "").strip()
    app_secret = os.getenv("SCHWAB_CLIENT_SECRET", "").strip()
    token_path = os.getenv(
        "SCHWAB_TOKEN_PATH",
        "/mnt/c/Users/alexm/granite_trader/backend/schwab_token.json",
    )
    if not api_key or not app_secret:
        raise RuntimeError(
            "Schwab env vars not loaded. Set SCHWAB_CLIENT_ID and SCHWAB_CLIENT_SECRET in .env."
        )
    return client_from_token_file(
        token_path=token_path,
        api_key=api_key,
        app_secret=app_secret,
    )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _parse_date(value: Optional[str | dt.date]) -> Optional[dt.date]:
    if value is None or value == "":
        return None
    if isinstance(value, dt.date):
        return value
    return dt.date.fromisoformat(str(value))


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except Exception:
        return default


def _extract_expiration(exp_key: str) -> tuple[str, Optional[int]]:
    """
    Schwab encodes expirations as 'YYYY-MM-DD:DTE'.
    Returns (date_str, dte_or_None).
    """
    parts = str(exp_key).split(":")
    expiration = parts[0]
    dte = None
    if len(parts) > 1:
        try:
            dte = int(parts[1])
        except Exception:
            dte = None
    return expiration, dte


def _extract_underlying_price(chain: Dict[str, Any]) -> float:
    candidates = [
        chain.get("underlyingPrice"),
        chain.get("underlying", {}).get("last"),
        chain.get("underlying", {}).get("mark"),
        chain.get("underlying", {}).get("close"),
        chain.get("underlying", {}).get("bid"),
        chain.get("underlying", {}).get("ask"),
    ]
    for value in candidates:
        number = _safe_float(value, default=0.0)
        if number > 0:
            return number
    return 0.0


def _mid_from_bid_ask(bid: float, ask: float, mark: float) -> float:
    if bid > 0 and ask > 0:
        if ask < bid:
            ask = bid
        return (bid + ask) / 2.0
    if mark > 0:
        return mark
    if ask > 0:
        return ask
    if bid > 0:
        return bid
    return 0.0


def _flatten_contract_map(
    symbol: str,
    option_side: str,
    option_map: Dict[str, Any],
    underlying_price: float,
) -> List[Dict[str, Any]]:
    """
    Flatten Schwab's nested callExpDateMap / putExpDateMap into a list of
    normalized contract dicts.  Each dict contains every field downstream
    consumers (scanner, vol_surface) expect.
    """
    flattened: List[Dict[str, Any]] = []

    for exp_key, strikes_map in (option_map or {}).items():
        expiration, dte = _extract_expiration(exp_key)
        if not isinstance(strikes_map, dict):
            continue

        for strike_key, contracts in strikes_map.items():
            strike = _safe_float(strike_key, default=0.0)
            if not isinstance(contracts, list):
                continue

            for contract in contracts:
                bid = _safe_float(contract.get("bid"), default=0.0)
                ask = _safe_float(contract.get("ask"), default=0.0)
                mark = _safe_float(contract.get("mark"), default=0.0)
                delta = _safe_float(contract.get("delta"), default=0.0)
                # Schwab returns IV as a decimal (e.g. 0.18 = 18%)
                iv = _safe_float(contract.get("volatility"), default=0.0)
                total_volume = _safe_float(contract.get("totalVolume"), default=0.0)
                open_interest = _safe_float(contract.get("openInterest"), default=0.0)
                description = str(contract.get("description", "") or "")
                option_symbol = str(contract.get("symbol", "") or "")

                flattened.append(
                    {
                        "underlying": symbol.upper(),
                        "option_side": option_side.lower(),
                        "expiration": expiration,
                        "days_to_expiration": dte,
                        "strike": round(strike, 4),
                        "bid": round(bid, 4),
                        "ask": round(ask, 4),
                        "mark": round(mark, 4),
                        "mid": round(_mid_from_bid_ask(bid, ask, mark), 4),
                        "delta": round(delta, 6),
                        "iv": round(iv, 6),
                        "total_volume": round(total_volume, 2),
                        "open_interest": round(open_interest, 2),
                        "in_the_money": bool(contract.get("inTheMoney", False)),
                        "option_symbol": option_symbol,
                        "description": description,
                        "underlying_price": round(underlying_price, 4),
                    }
                )

    return flattened


# ---------------------------------------------------------------------------
# Strike-spacing detection
# ---------------------------------------------------------------------------

def _compute_strike_spacing_by_expiration(
    contracts: List[Dict[str, Any]],
) -> Dict[str, Dict[str, Any]]:
    """
    For each expiration, derive the actual strike step sizes present in the chain.
    Some weeklies use $0.50, others $1.00; the same ticker can vary across expirations.
    """
    grouped: Dict[str, List[float]] = {}
    for contract in contracts:
        exp = str(contract.get("expiration"))
        grouped.setdefault(exp, []).append(_safe_float(contract.get("strike")))

    output: Dict[str, Dict[str, Any]] = {}
    for exp, strikes in grouped.items():
        unique_strikes = sorted({round(s, 4) for s in strikes if s > 0})
        diffs = [
            round(unique_strikes[i + 1] - unique_strikes[i], 4)
            for i in range(len(unique_strikes) - 1)
        ]
        positive_diffs = [d for d in diffs if d > 0]
        counter = Counter(positive_diffs)
        common_step = counter.most_common(1)[0][0] if counter else None
        output[exp] = {
            "strike_count": len(unique_strikes),
            "min_step": min(positive_diffs) if positive_diffs else None,
            "max_step": max(positive_diffs) if positive_diffs else None,
            "common_step": common_step,
            "step_set": sorted(counter.keys()),
        }
    return output


# ---------------------------------------------------------------------------
# ATM IV helpers for symbol snapshot
# ---------------------------------------------------------------------------

def _compute_atm_iv_for_expiration(
    contracts: List[Dict[str, Any]], underlying_price: float
) -> Optional[float]:
    if not contracts or underlying_price <= 0:
        return None
    ordered = sorted(contracts, key=lambda c: abs(_safe_float(c.get("strike")) - underlying_price))
    nearest = ordered[:8]
    ivs = [_safe_float(c.get("iv")) for c in nearest if _safe_float(c.get("iv")) > 0]
    return round(mean(ivs), 6) if ivs else None


def _pick_term_iv(
    by_exp: Dict[str, List[Dict[str, Any]]],
    underlying_price: float,
    target_dte: int,
) -> Optional[float]:
    best_exp: Optional[str] = None
    best_gap: Optional[int] = None
    for exp, contracts in by_exp.items():
        if not contracts:
            continue
        dte = contracts[0].get("days_to_expiration")
        if dte is None:
            continue
        gap = abs(int(dte) - int(target_dte))
        if best_gap is None or gap < best_gap:
            best_gap = gap
            best_exp = exp
    if best_exp is None:
        return None
    return _compute_atm_iv_for_expiration(by_exp[best_exp], underlying_price)


# ---------------------------------------------------------------------------
# Quote normalization
# ---------------------------------------------------------------------------

def _normalize_quote_snapshot(symbol: str, quote_raw: Dict[str, Any]) -> Dict[str, Any]:
    payload = quote_raw.get(symbol.upper(), {})
    quote = payload.get("quote", {})
    last_price = _safe_float(quote.get("lastPrice"))
    mark = _safe_float(quote.get("mark"))
    close_price = _safe_float(quote.get("closePrice"))
    effective_last = last_price or mark or close_price
    net_change = _safe_float(quote.get("netChange"))
    pct_change = (net_change / close_price) if close_price else 0.0

    return {
        "symbol": symbol.upper(),
        "last_price": round(effective_last, 4),
        "mark": round(mark, 4),
        "close_price": round(close_price, 4),
        "net_change": round(net_change, 4),
        "pct_change": round(pct_change, 6),
        "bid": round(_safe_float(quote.get("bidPrice")), 4),
        "ask": round(_safe_float(quote.get("askPrice")), 4),
        "quote_source": "schwab",
    }


# ---------------------------------------------------------------------------
# Expiration helpers
# ---------------------------------------------------------------------------

def _choose_nearest_expirations(
    expirations: List[str], max_expirations: int
) -> List[str]:
    return sorted(expirations)[:max_expirations]


def _filter_contracts_to_expirations(
    contracts: List[Dict[str, Any]], expirations: List[str]
) -> List[Dict[str, Any]]:
    allowed = set(expirations)
    return [c for c in contracts if c.get("expiration") in allowed]


# ---------------------------------------------------------------------------
# Symbol snapshot (watchlist-level fields derivable from Schwab)
# ---------------------------------------------------------------------------

def build_symbol_snapshot_from_schwab(
    symbol: str,
    quote_raw: Dict[str, Any],
    flat_chain: Dict[str, Any],
    max_expirations: int = 7,
) -> Dict[str, Any]:
    quote_snapshot = _normalize_quote_snapshot(symbol, quote_raw)
    nearest_expirations = _choose_nearest_expirations(
        flat_chain["expirations"], max_expirations=max_expirations
    )
    contracts = _filter_contracts_to_expirations(flat_chain["contracts"], nearest_expirations)
    underlying_price = (
        _safe_float(flat_chain.get("underlying_price"))
        or _safe_float(quote_snapshot.get("last_price"))
    )

    by_exp: Dict[str, List[Dict[str, Any]]] = {}
    for contract in contracts:
        by_exp.setdefault(str(contract["expiration"]), []).append(contract)

    call_volume = sum(
        _safe_float(c.get("total_volume")) for c in contracts if c.get("option_side") == "call"
    )
    put_volume = sum(
        _safe_float(c.get("total_volume")) for c in contracts if c.get("option_side") == "put"
    )
    options_volume = call_volume + put_volume
    put_call_ratio = (put_volume / call_volume) if call_volume > 0 else None

    imp_vol = _compute_atm_iv_for_expiration(contracts, underlying_price)
    strike_spacing = _compute_strike_spacing_by_expiration(contracts)

    return {
        "symbol": symbol.upper(),
        "last_price": quote_snapshot.get("last_price"),
        "pct_change": quote_snapshot.get("pct_change"),
        "imp_vol": imp_vol,
        "iv_5d": _pick_term_iv(by_exp, underlying_price, 5),
        "iv_1m": _pick_term_iv(by_exp, underlying_price, 30),
        "iv_3m": _pick_term_iv(by_exp, underlying_price, 90),
        "iv_6m": _pick_term_iv(by_exp, underlying_price, 180),
        "options_volume": round(options_volume, 2),
        "call_volume": round(call_volume, 2),
        "put_volume": round(put_volume, 2),
        "put_call_ratio": round(put_call_ratio, 6) if put_call_ratio is not None else None,
        "strike_spacing_by_expiration": strike_spacing,
        "active_expirations": nearest_expirations,
        # Fields that need price history or proprietary models — filled by Barchart after-hours:
        "rel_strength_14d": None,
        "iv_percentile": None,
        "iv_hv_ratio": None,
        "bb_pct": None,
        "bb_rank": None,
        "ttm_squeeze": None,
        "adr_14d": None,
        "total_volume_1m": None,
        "notes": None,
        "low_flag": None,
        "high_flag": None,
        "source": "schwab",
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def get_quote(symbol: str) -> Dict[str, Any]:
    client = _get_client()
    response = client.get_quote(symbol.upper())
    response.raise_for_status()
    return response.json()


def get_option_chain_raw(
    symbol: str,
    strike_count: int = 200,
    from_date: Optional[str | dt.date] = None,
    to_date: Optional[str | dt.date] = None,
    include_underlying_quote: bool = True,
) -> Dict[str, Any]:
    """
    Raw Schwab chain response.
    strike_count=200 gives single/triple-digit delta coverage on typical underlyings.
    """
    client = _get_client()
    response = client.get_option_chain(
        symbol.upper(),
        strike_count=int(strike_count),
        include_underlying_quote=include_underlying_quote,
        from_date=_parse_date(from_date),
        to_date=_parse_date(to_date),
    )
    response.raise_for_status()
    return response.json()


def get_flat_option_chain(
    symbol: str,
    strike_count: int = 200,
    from_date: Optional[str | dt.date] = None,
    to_date: Optional[str | dt.date] = None,
) -> Dict[str, Any]:
    """
    Flattened, normalized chain.  All contracts from all expirations in one list.

    Returns:
        {
          symbol, underlying_price,
          expirations: sorted list of all expiration date strings,
          strikes:     sorted list of all unique strikes,
          contracts:   list of normalized contract dicts,
          raw:         the raw Schwab response (for debugging)
        }
    """
    raw = get_option_chain_raw(
        symbol=symbol,
        strike_count=strike_count,
        from_date=from_date,
        to_date=to_date,
        include_underlying_quote=True,
    )
    underlying_price = _extract_underlying_price(raw)

    call_contracts = _flatten_contract_map(
        symbol=symbol,
        option_side="call",
        option_map=raw.get("callExpDateMap", {}),
        underlying_price=underlying_price,
    )
    put_contracts = _flatten_contract_map(
        symbol=symbol,
        option_side="put",
        option_map=raw.get("putExpDateMap", {}),
        underlying_price=underlying_price,
    )

    all_contracts = sorted(
        call_contracts + put_contracts,
        key=lambda x: (x["expiration"], x["option_side"], x["strike"]),
    )

    expirations = sorted({c["expiration"] for c in all_contracts})
    strikes = sorted({c["strike"] for c in all_contracts})

    return {
        "symbol": symbol.upper(),
        "underlying_price": round(underlying_price, 4),
        "expirations": expirations,
        "strikes": strikes,
        "contracts": all_contracts,
        "raw": raw,
    }


def get_available_expirations(symbol: str, strike_count: int = 200) -> List[str]:
    flat = get_flat_option_chain(symbol=symbol, strike_count=strike_count)
    return flat["expirations"]


def get_next_7_expirations(symbol: str, strike_count: int = 200) -> List[str]:
    return get_available_expirations(symbol=symbol, strike_count=strike_count)[:7]


# backward compat alias
get_next_7_opex = get_next_7_expirations


def refresh_symbol_from_schwab(
    symbol: str,
    strike_count: int = 200,
    max_expirations: int = 7,
) -> Dict[str, Any]:
    """
    Full refresh: quote + chain + derived snapshot.
    Called by cache_manager.  Returns a normalized symbol state dict ready to
    be upserted into the DataStore.
    """
    quote_raw = get_quote(symbol)
    flat_chain = get_flat_option_chain(symbol=symbol, strike_count=strike_count)

    nearest_expirations = _choose_nearest_expirations(
        flat_chain["expirations"], max_expirations=max_expirations
    )
    contracts = _filter_contracts_to_expirations(flat_chain["contracts"], nearest_expirations)
    filtered_strikes = sorted({c["strike"] for c in contracts})

    symbol_snapshot = build_symbol_snapshot_from_schwab(
        symbol=symbol,
        quote_raw=quote_raw,
        flat_chain=flat_chain,
        max_expirations=max_expirations,
    )

    return {
        "symbol": symbol.upper(),
        "active_chain_source": "schwab",
        "quote_source": "schwab",
        "quote_raw": quote_raw,
        "quote_snapshot": _normalize_quote_snapshot(symbol, quote_raw),
        "contracts": contracts,
        "expirations": nearest_expirations,
        "strikes": filtered_strikes,
        "underlying_price": flat_chain["underlying_price"],
        "symbol_snapshot": symbol_snapshot,
        "metadata": {
            "strike_count_requested": strike_count,
            "max_expirations": max_expirations,
            "chain_contract_count": len(contracts),
            "strike_spacing_by_expiration": symbol_snapshot.get(
                "strike_spacing_by_expiration", {}
            ),
        },
    }

'@
Write-TextFile "backend\schwab_adapter.py" $c

$c = @'
from __future__ import annotations

import os
import time
from typing import Any, Dict, List

from archive_manager import archive_symbol_state
from barchart_adapter import refresh_symbol_from_barchart
from data_store import store
from market_clock import is_chain_refresh_window
from schwab_adapter import get_quote, refresh_symbol_from_schwab
from source_router import get_active_chain_source

# ---------------------------------------------------------------------------
# Config (overridable via .env)
# ---------------------------------------------------------------------------

CHAIN_REFRESH_SECONDS = int(os.getenv("CHAIN_REFRESH_SECONDS", "300"))          # 5 min default
DEFAULT_STRIKE_COUNT = int(os.getenv("DEFAULT_CHAIN_STRIKE_COUNT", "200"))      # wide enough for 1-digit deltas
DEFAULT_MAX_EXPIRATIONS = int(os.getenv("DEFAULT_MAX_EXPIRATIONS", "7"))


# ---------------------------------------------------------------------------
# Freshness check
# ---------------------------------------------------------------------------

def _state_is_fresh(state: Dict[str, Any], refresh_seconds: int) -> bool:
    last = float(state.get("last_chain_refresh_epoch", 0.0) or 0.0)
    return last > 0 and (time.time() - last) < refresh_seconds


# ---------------------------------------------------------------------------
# Read helpers (thin wrappers over the store)
# ---------------------------------------------------------------------------

def get_symbol_state(symbol: str) -> Dict[str, Any]:
    return store.get_symbol_state(symbol)


def list_cached_symbols() -> List[str]:
    return store.list_symbols()


# ---------------------------------------------------------------------------
# Core load / refresh
# ---------------------------------------------------------------------------

def ensure_symbol_loaded(
    symbol: str,
    force: bool = False,
    strike_count: int = DEFAULT_STRIKE_COUNT,
    max_expirations: int = DEFAULT_MAX_EXPIRATIONS,
    requested_by: str = "api",
) -> Dict[str, Any]:
    """
    Return the normalized symbol state from the shared store.

    Decision tree:
    1. If the cached state is fresh (< CHAIN_REFRESH_SECONDS old) and force=False → return it.
    2. If outside the chain-refresh window and source is Schwab and we have something → return it.
    3. Otherwise refresh from the active source (Schwab or Barchart).
    4. Merge result into store and return.

    This is the single entry point used by scanner.py, vol_surface.py, and all API endpoints.
    """
    symbol_upper = symbol.upper()
    existing = store.get_symbol_state(symbol_upper)
    active_source = get_active_chain_source()

    # Return fresh cached data if we can
    if not force and existing and _state_is_fresh(existing, CHAIN_REFRESH_SECONDS):
        return existing

    # Outside chain-refresh window + Schwab source + we have something → hold
    if (
        not force
        and existing
        and not is_chain_refresh_window()
        and active_source == "schwab"
    ):
        return existing

    # --- Fetch fresh data ---
    if active_source == "schwab":
        payload = refresh_symbol_from_schwab(
            symbol=symbol_upper,
            strike_count=strike_count,
            max_expirations=max_expirations,
        )
    else:
        # After-hours: try Schwab quote as a fallback price, use Barchart chain
        fallback_quote: Dict[str, Any] = {}
        try:
            fallback_quote = get_quote(symbol_upper)
        except Exception:
            fallback_quote = existing.get("quote_raw", {}) if existing else {}

        payload = refresh_symbol_from_barchart(
            symbol=symbol_upper,
            fallback_quote_raw=fallback_quote,
        )

        # If Barchart had no chain JSON, carry over the last Schwab contracts
        if not payload.get("contracts") and existing:
            payload["contracts"] = existing.get("contracts", [])
            payload["expirations"] = existing.get("expirations", [])
            payload["strikes"] = existing.get("strikes", [])
            payload["underlying_price"] = existing.get("underlying_price")

            # Merge watchlist fields on top of the last symbol_snapshot
            merged_snapshot = dict(existing.get("symbol_snapshot", {}))
            merged_snapshot.update(
                {k: v for k, v in payload.get("symbol_snapshot", {}).items() if v is not None}
            )
            payload["symbol_snapshot"] = merged_snapshot
            payload["metadata"] = {
                **existing.get("metadata", {}),
                **payload.get("metadata", {}),
                "barchart_fallback_to_existing_chain": True,
            }

    payload["updated_at_epoch"] = time.time()
    payload["last_chain_refresh_epoch"] = time.time()
    payload["requested_by"] = requested_by

    return store.upsert_symbol_state(symbol_upper, payload)


def manual_refresh_symbol(
    symbol: str,
    strike_count: int = DEFAULT_STRIKE_COUNT,
    max_expirations: int = DEFAULT_MAX_EXPIRATIONS,
) -> Dict[str, Any]:
    """Force-refresh regardless of cache freshness.  Exposed as an API endpoint."""
    return ensure_symbol_loaded(
        symbol=symbol,
        force=True,
        strike_count=strike_count,
        max_expirations=max_expirations,
        requested_by="manual_refresh",
    )


def archive_all_cached_symbols(reason: str = "scheduled") -> List[str]:
    """Archive every cached symbol state to disk.  Called at EOD."""
    archived_paths: List[str] = []
    for symbol in list_cached_symbols():
        state = get_symbol_state(symbol)
        if state:
            archived_paths.append(str(archive_symbol_state(state, reason=reason)))
    return archived_paths

'@
Write-TextFile "backend\cache_manager.py" $c

$c = @'
from __future__ import annotations

import threading
import time

from cache_manager import archive_all_cached_symbols, list_cached_symbols, manual_refresh_symbol
from market_clock import (
    is_chain_refresh_window,
    is_eod_archive_time,
    is_overnight_refresh_time,
    now_pacific,
)
from source_router import get_active_chain_source

_started = False


def _scheduler_loop() -> None:
    last_archive_date: str | None = None
    overnight_marks: set = set()

    while True:
        try:
            now = now_pacific()
            active_source = get_active_chain_source()

            # --- EOD archive (once per calendar day after 4 PM Pacific) ---
            if is_eod_archive_time(now):
                date_key = now.date().isoformat()
                if date_key != last_archive_date:
                    try:
                        archive_all_cached_symbols(reason="eod")
                    except Exception as exc:
                        print(f"[scheduler] EOD archive failed: {exc}")
                    last_archive_date = date_key

            # --- Intraday Schwab refresh (every loop tick = ~60 s) ---
            if active_source == "schwab" and is_chain_refresh_window(now):
                for symbol in list_cached_symbols():
                    try:
                        manual_refresh_symbol(symbol)
                    except Exception as exc:
                        print(f"[scheduler] Schwab refresh failed for {symbol}: {exc}")

            # --- Overnight Barchart refreshes (midnight + 3 AM Pacific) ---
            if active_source == "barchart" and is_overnight_refresh_time(now):
                mark = (now.date().isoformat(), now.hour, now.minute)
                if mark not in overnight_marks:
                    for symbol in list_cached_symbols():
                        try:
                            manual_refresh_symbol(symbol)
                        except Exception as exc:
                            print(f"[scheduler] overnight refresh failed for {symbol}: {exc}")
                    overnight_marks.add(mark)

        except Exception as exc:
            print(f"[scheduler] unexpected error in loop: {exc}")

        time.sleep(60)


def start_scheduler() -> None:
    """Start the background refresh thread.  Safe to call multiple times."""
    global _started
    if _started:
        return
    thread = threading.Thread(
        target=_scheduler_loop,
        daemon=True,
        name="granite-refresh-scheduler",
    )
    thread.start()
    _started = True

'@
Write-TextFile "backend\refresh_scheduler.py" $c

$c = @'
"""
Central registry for scanner strategies and output fields.

Both the entry scanner and the future roll scanner read from here.
The frontend uses /field-registry to populate:
  - strategy dropdown
  - column visibility toggle menu
  - sort-by options

Adding a new field: append to SCANNER_FIELDS.
Adding a new strategy: append to ENTRY_STRATEGIES and wire the logic in scanner.py.
"""

from __future__ import annotations
from typing import Any, Dict, List

# ---------------------------------------------------------------------------
# Entry strategies
# ---------------------------------------------------------------------------

ENTRY_STRATEGIES: List[Dict[str, Any]] = [
    {"id": "credit_spread",  "label": "Credit Spread",  "enabled": True},
    {"id": "butterfly",      "label": "Butterfly",       "enabled": False},
    {"id": "iron_fly",       "label": "Iron Fly",        "enabled": False},
    {"id": "iron_condor",    "label": "Iron Condor",     "enabled": False},
    {"id": "custom",         "label": "Custom",          "enabled": False},
]

# ---------------------------------------------------------------------------
# Scanner output fields
# ---------------------------------------------------------------------------
# applies_to: "entry" | "roll" | "both"
# default_visible: shown by default in the table

SCANNER_FIELDS: List[Dict[str, Any]] = [
    # --- identity ---
    {"id": "expiration",     "label": "Exp",           "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "option_side",    "label": "Side",          "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "short_strike",   "label": "Short",         "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "long_strike",    "label": "Long",          "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "width",          "label": "Width",         "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "quantity",       "label": "Qty",           "sortable": True,  "default_visible": True,  "applies_to": "both"},

    # --- pricing / capital ---
    {"id": "net_credit",            "label": "Net Credit",       "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "gross_defined_risk",    "label": "Gross Risk",       "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "max_loss",              "label": "Max Loss",         "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "short_value",           "label": "Short Value",      "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "long_cost",             "label": "Long Cost",        "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "limit_impact",          "label": "Limit Impact",     "sortable": True,  "default_visible": True,  "applies_to": "both"},

    # --- reward/risk metrics ---
    {"id": "credit_pct_risk",       "label": "Credit % Risk",    "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "credit_pct_risk_pct",   "label": "Credit % Risk %",  "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "reward_to_max_loss",    "label": "Reward/Max Loss",  "sortable": True,  "default_visible": False, "applies_to": "both"},

    # --- vol / Greeks ---
    {"id": "short_delta",  "label": "Short Δ",  "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "long_delta",   "label": "Long Δ",   "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "short_iv",     "label": "Short IV", "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "long_iv",      "label": "Long IV",  "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "avg_iv",       "label": "Avg IV",   "sortable": True,  "default_visible": False, "applies_to": "both"},

    # --- relative ranking ---
    {"id": "richness_score",              "label": "Richness",          "sortable": True,  "default_visible": True,  "applies_to": "entry"},
    {"id": "credit_pct_risk_rank_within_exp", "label": "Credit Rank",   "sortable": True,  "default_visible": False, "applies_to": "entry"},
    {"id": "iv_rank_within_exp",          "label": "IV Rank",           "sortable": True,  "default_visible": False, "applies_to": "entry"},
    {"id": "credit_pct_vs_exp_avg",       "label": "vs Exp Avg Credit", "sortable": True,  "default_visible": False, "applies_to": "entry"},
    {"id": "iv_vs_exp_avg",               "label": "vs Exp Avg IV",     "sortable": True,  "default_visible": False, "applies_to": "entry"},
]

VALID_SORT_KEYS = {"credit", "credit_pct_risk", "limit_impact", "max_loss", "richness"}

'@
Write-TextFile "backend\field_registry.py" $c

$c = @'
from __future__ import annotations

from collections import defaultdict
from statistics import mean
from typing import Any, Dict, List, Optional, Tuple

from cache_manager import ensure_symbol_loaded


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _safe_float(value: Any) -> Optional[float]:
    try:
        if value is None or value == "":
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def _nearest_expirations(items: List[Dict[str, Any]], max_expirations: int) -> List[str]:
    expirations = sorted(
        {str(item.get("expiration")) for item in items if item.get("expiration")}
    )
    return expirations[:max_expirations]


def _extract_underlying_price(
    items: List[Dict[str, Any]], fallback: Optional[float]
) -> Optional[float]:
    if fallback is not None and fallback > 0:
        return round(fallback, 4)
    candidates = [
        _safe_float(item.get("underlying_price"))
        for item in items
        if _safe_float(item.get("underlying_price")) is not None
        and _safe_float(item.get("underlying_price")) > 0
    ]
    if not candidates:
        return None
    return round(mean(candidates), 4)


def _choose_centered_strikes(
    items: List[Dict[str, Any]],
    underlying_price: Optional[float],
    strike_count: int,
) -> List[float]:
    strikes = sorted(
        {
            round(float(item["strike"]), 4)
            for item in items
            if _safe_float(item.get("strike")) is not None
        }
    )
    if not strikes:
        return []
    if underlying_price is None:
        return strikes[:strike_count]
    closest_idx = min(range(len(strikes)), key=lambda i: abs(strikes[i] - underlying_price))
    half = strike_count // 2
    start = max(0, closest_idx - half)
    end = min(len(strikes), start + strike_count)
    start = max(0, end - strike_count)
    return strikes[start:end]


def _build_iv_lookup(
    items: List[Dict[str, Any]],
) -> Dict[Tuple[str, float], Dict[str, Optional[float]]]:
    """
    Build a (expiration, strike) → {call_iv, put_iv, avg_iv, skew_iv} lookup.

    Key fix vs earlier version: calls and puts are bucketed SEPARATELY so
    put_call_skew is non-zero wherever the chain has actual skew.
    """
    bucket: Dict[Tuple[str, float], Dict[str, List[float]]] = defaultdict(
        lambda: {"call": [], "put": []}
    )

    for item in items:
        exp = str(item.get("expiration") or "")
        strike = _safe_float(item.get("strike"))
        option_side = str(item.get("option_side") or "").lower()
        iv = _safe_float(item.get("iv"))

        if not exp or strike is None or option_side not in {"call", "put"} or iv is None or iv <= 0:
            continue

        bucket[(exp, round(strike, 4))][option_side].append(iv)

    lookup: Dict[Tuple[str, float], Dict[str, Optional[float]]] = {}
    for key, values in bucket.items():
        call_iv = mean(values["call"]) if values["call"] else None
        put_iv = mean(values["put"]) if values["put"] else None
        avg_candidates = [v for v in (call_iv, put_iv) if v is not None]
        avg_iv = mean(avg_candidates) if avg_candidates else None
        skew = (put_iv - call_iv) if (put_iv is not None and call_iv is not None) else None
        lookup[key] = {
            "call_iv":  round(call_iv, 6) if call_iv is not None else None,
            "put_iv":   round(put_iv, 6)  if put_iv is not None  else None,
            "avg_iv":   round(avg_iv, 6)  if avg_iv is not None  else None,
            "skew_iv":  round(skew, 6)    if skew is not None    else None,
        }
    return lookup


def _build_matrix(
    expirations: List[str],
    strikes: List[float],
    iv_lookup: Dict[Tuple[str, float], Dict[str, Optional[float]]],
    key: str,
) -> List[List[Optional[float]]]:
    matrix: List[List[Optional[float]]] = []
    for exp in expirations:
        row: List[Optional[float]] = []
        for strike in strikes:
            value = _safe_float(iv_lookup.get((exp, strike), {}).get(key))
            row.append(round(value, 6) if value is not None else None)
        matrix.append(row)
    return matrix


def _avg_iv_by_expiration(
    expirations: List[str],
    strikes: List[float],
    iv_lookup: Dict[Tuple[str, float], Dict[str, Optional[float]]],
) -> Dict[str, Optional[float]]:
    results: Dict[str, Optional[float]] = {}
    for exp in expirations:
        vals = [
            v for strike in strikes
            for v in [_safe_float(iv_lookup.get((exp, strike), {}).get("avg_iv"))]
            if v is not None
        ]
        results[exp] = round(mean(vals), 6) if vals else None
    return results


def _build_skew_curves(
    expirations: List[str],
    strikes: List[float],
    iv_lookup: Dict[Tuple[str, float], Dict[str, Optional[float]]],
) -> Dict[str, List[Dict[str, Optional[float]]]]:
    curves: Dict[str, List[Dict[str, Optional[float]]]] = {}
    for exp in expirations:
        curve = []
        for strike in strikes:
            cell = iv_lookup.get((exp, strike), {})
            curve.append(
                {
                    "strike":  round(strike, 4),
                    "call_iv": _safe_float(cell.get("call_iv")),
                    "put_iv":  _safe_float(cell.get("put_iv")),
                    "avg_iv":  _safe_float(cell.get("avg_iv")),
                    "skew_iv": _safe_float(cell.get("skew_iv")),
                }
            )
        curves[exp] = curve
    return curves


def _build_richness_scores(
    expirations: List[str],
    avg_iv_by_exp: Dict[str, Optional[float]],
    skew_curves: Dict[str, List[Dict[str, Optional[float]]]],
    underlying_price: Optional[float],
) -> Dict[str, Dict[str, Optional[float]]]:
    """
    Per-expiration richness model:
      - avg_iv
      - put/call skew averaged near the spot
      - blended richness = 70% IV premium vs surface + 30% near-spot skew
    """
    output: Dict[str, Dict[str, Optional[float]]] = {}
    all_avg_iv = [v for v in avg_iv_by_exp.values() if v is not None]
    global_avg_iv = mean(all_avg_iv) if all_avg_iv else None

    for exp in expirations:
        avg_iv = avg_iv_by_exp.get(exp)
        curve = skew_curves.get(exp, [])

        atm_candidates = curve
        if underlying_price is not None and curve:
            atm_candidates = sorted(curve, key=lambda x: abs(float(x["strike"]) - underlying_price))[:5]

        put_vals  = [x["put_iv"]  for x in atm_candidates if x.get("put_iv")  is not None]
        call_vals = [x["call_iv"] for x in atm_candidates if x.get("call_iv") is not None]
        put_avg  = mean(put_vals)  if put_vals  else None
        call_avg = mean(call_vals) if call_vals else None
        skew = (put_avg - call_avg) if (put_avg is not None and call_avg is not None) else None

        iv_premium_vs_surface = (
            avg_iv - global_avg_iv
            if avg_iv is not None and global_avg_iv is not None
            else None
        )

        richness_score: Optional[float] = None
        if iv_premium_vs_surface is not None and skew is not None:
            richness_score = (iv_premium_vs_surface * 0.7) + (skew * 0.3)
        elif iv_premium_vs_surface is not None:
            richness_score = iv_premium_vs_surface
        elif skew is not None:
            richness_score = skew

        output[exp] = {
            "avg_iv":                   round(avg_iv, 6)               if avg_iv               is not None else None,
            "put_call_skew_near_spot":  round(skew, 6)                 if skew                 is not None else None,
            "iv_premium_vs_surface":    round(iv_premium_vs_surface, 6)if iv_premium_vs_surface is not None else None,
            "richness_score":           round(richness_score, 6)        if richness_score        is not None else None,
        }

    return output


# ---------------------------------------------------------------------------
# Public API (consumed by main.py /vol/surface endpoint)
# ---------------------------------------------------------------------------

def build_vol_surface_payload(
    symbol: str,
    max_expirations: int = 7,
    strike_count: int = 21,
) -> Dict[str, Any]:
    """
    Build the full IV surface payload for `symbol`.

    Reads contracts from the shared cache (cache_manager.ensure_symbol_loaded).
    Does NOT hit Schwab directly — keeps the chain request count to one per
    symbol per refresh cycle.

    Returns a dict with:
      - expirations   : list of the nearest `max_expirations` dates
      - strikes       : centred list of `strike_count` strikes
      - avg_iv_matrix / call_iv_matrix / put_iv_matrix / skew_matrix
        each is a list[list[float|None]] with shape [exp][strike]
      - avg_iv_by_expiration : {exp: float}
      - skew_curves          : {exp: [{strike, call_iv, put_iv, avg_iv, skew_iv}]}
      - richness_scores      : {exp: {avg_iv, put_call_skew_near_spot, ...}}
    """
    # Use the cache; request wide strikes so vol surface has full coverage
    state = ensure_symbol_loaded(
        symbol=symbol,
        strike_count=max(strike_count, 200),
        requested_by="vol_surface",
    )
    chain_items = list(state.get("contracts", []))

    if not chain_items:
        return {
            "symbol": symbol.upper(),
            "expirations": [],
            "strikes": [],
            "underlying_price": None,
            "iv_matrix": [],
            "avg_iv_matrix": [],
            "call_iv_matrix": [],
            "put_iv_matrix": [],
            "skew_matrix": [],
            "avg_iv_by_expiration": {},
            "skew_curves": {},
            "richness_scores": {},
            "count": 0,
            "active_chain_source": state.get("active_chain_source"),
            "strike_spacing_by_expiration": {},
        }

    expirations = _nearest_expirations(chain_items, max_expirations=max_expirations)
    filtered_items = [i for i in chain_items if str(i.get("expiration")) in set(expirations)]

    underlying_price = _extract_underlying_price(
        filtered_items, fallback=_safe_float(state.get("underlying_price"))
    )
    strikes = _choose_centered_strikes(
        filtered_items, underlying_price=underlying_price, strike_count=strike_count
    )

    iv_lookup = _build_iv_lookup(filtered_items)
    avg_iv_matrix  = _build_matrix(expirations, strikes, iv_lookup, "avg_iv")
    call_iv_matrix = _build_matrix(expirations, strikes, iv_lookup, "call_iv")
    put_iv_matrix  = _build_matrix(expirations, strikes, iv_lookup, "put_iv")
    skew_matrix    = _build_matrix(expirations, strikes, iv_lookup, "skew_iv")

    avg_iv_by_expiration = _avg_iv_by_expiration(expirations, strikes, iv_lookup)
    skew_curves = _build_skew_curves(expirations, strikes, iv_lookup)
    richness_scores = _build_richness_scores(
        expirations=expirations,
        avg_iv_by_exp=avg_iv_by_expiration,
        skew_curves=skew_curves,
        underlying_price=underlying_price,
    )

    return {
        "symbol": symbol.upper(),
        "underlying_price": underlying_price,
        "expirations": expirations,
        "strikes": strikes,
        # iv_matrix kept for backward compat with current frontend
        "iv_matrix": avg_iv_matrix,
        "avg_iv_matrix": avg_iv_matrix,
        "call_iv_matrix": call_iv_matrix,
        "put_iv_matrix": put_iv_matrix,
        "skew_matrix": skew_matrix,
        "avg_iv_by_expiration": avg_iv_by_expiration,
        "skew_curves": skew_curves,
        "richness_scores": richness_scores,
        "count": len(filtered_items),
        "selection_rule": "nearest_expiration_dates",
        "active_chain_source": state.get("active_chain_source"),
        "strike_spacing_by_expiration": (
            state.get("symbol_snapshot", {}).get("strike_spacing_by_expiration", {})
        ),
    }

'@
Write-TextFile "backend\vol_surface.py" $c

$c = @'
from __future__ import annotations

from collections import defaultdict
from typing import Any, Dict, List, Optional, Tuple

from cache_manager import ensure_symbol_loaded

# Supported spread widths.  Derived dynamically from the actual chain in
# _build_spread_candidates_for_expiration — this list acts as the minimum
# acceptance set; widths outside it are skipped.
SUPPORTED_WIDTHS = [0.5, 1.0, 2.0, 2.5, 5.0, 10.0]


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except Exception:
        return default


def _is_supported_width(width: float) -> bool:
    return any(abs(width - w) < 0.0001 for w in SUPPORTED_WIDTHS)


def _contracts_for_same_risk(total_risk: float, width: float) -> int:
    """
    How many spreads of this width produce exactly total_risk of defined risk?
    Returns 0 if the width doesn't divide evenly.
    """
    per_spread_risk = width * 100.0
    if per_spread_risk <= 0:
        return 0
    quantity = total_risk / per_spread_risk
    rounded = round(quantity)
    if abs(quantity - rounded) > 1e-9 or rounded <= 0:
        return 0
    return int(rounded)


# ---------------------------------------------------------------------------
# Pricing modes
# ---------------------------------------------------------------------------

def _mid(bid: float, ask: float, mark: float) -> float:
    if bid > 0 and ask > 0:
        if ask < bid:
            ask = bid
        return (bid + ask) / 2.0
    if mark > 0:
        return mark
    return ask or bid or 0.0


def _conservative_mid_sell(contract: Dict[str, Any]) -> float:
    bid  = _safe_float(contract.get("bid"))
    ask  = _safe_float(contract.get("ask"))
    mark = _safe_float(contract.get("mark"))
    mid  = _mid(bid, ask, mark)
    return (bid + mid) / 2.0 if bid > 0 and mid > 0 else mid


def _conservative_mid_buy(contract: Dict[str, Any]) -> float:
    bid  = _safe_float(contract.get("bid"))
    ask  = _safe_float(contract.get("ask"))
    mark = _safe_float(contract.get("mark"))
    mid  = _mid(bid, ask, mark)
    return (ask + mid) / 2.0 if ask > 0 and mid > 0 else mid


def _pricing_value(contract: Dict[str, Any], action: str, pricing_mode: str) -> float:
    mode = pricing_mode.lower().strip()
    if mode == "natural":
        return _safe_float(contract.get("bid") if action == "sell" else contract.get("ask"))
    if mode == "mid":
        return _mid(
            _safe_float(contract.get("bid")),
            _safe_float(contract.get("ask")),
            _safe_float(contract.get("mark")),
        )
    # default: conservative_mid
    return _conservative_mid_sell(contract) if action == "sell" else _conservative_mid_buy(contract)


# ---------------------------------------------------------------------------
# Ranking helpers
# ---------------------------------------------------------------------------

def _percentile_ranks(items: List[float]) -> List[float]:
    if not items:
        return []
    if len(items) == 1:
        return [1.0]
    ordered = sorted((value, idx) for idx, value in enumerate(items))
    ranks = [0.0] * len(items)
    for rank, (_, idx) in enumerate(ordered):
        ranks[idx] = rank / (len(items) - 1)
    return ranks


def _sort_candidates(items: List[Dict[str, Any]], ranking: str) -> List[Dict[str, Any]]:
    r = ranking.lower().strip()
    if r == "credit":
        return sorted(items, key=lambda x: x["net_credit"], reverse=True)
    if r == "credit_pct_risk":
        return sorted(items, key=lambda x: x["credit_pct_risk"], reverse=True)
    if r == "limit_impact":
        return sorted(items, key=lambda x: (x["limit_impact"], -x["credit_pct_risk"]))
    if r == "max_loss":
        return sorted(items, key=lambda x: (x["max_loss"], -x["credit_pct_risk"]))
    # default: richness
    return sorted(items, key=lambda x: x.get("richness_score", 0.0), reverse=True)


# ---------------------------------------------------------------------------
# Core spread builder
# ---------------------------------------------------------------------------

def _build_spread_candidates_for_expiration(
    symbol: str,
    expiration: str,
    underlying_price: float,
    side: str,
    contracts: List[Dict[str, Any]],
    total_risk: float,
    pricing_mode: str,
) -> List[Dict[str, Any]]:
    """
    Generate all valid credit-spread pairs for one expiration / one side.

    Rules:
      - call spread: short lower strike, long higher strike (bear call)
      - put  spread: short higher strike, long lower strike (bull put)
      - widths restricted to SUPPORTED_WIDTHS
      - quantity chosen so total defined risk == total_risk exactly
      - net_credit must be positive (it IS a credit spread)
    """
    if not contracts:
        return []

    contracts_sorted = sorted(contracts, key=lambda x: x["strike"])
    results: List[Dict[str, Any]] = []

    for i, short_c in enumerate(contracts_sorted):
        for j, long_c in enumerate(contracts_sorted):
            if i == j:
                continue

            short_strike = _safe_float(short_c["strike"])
            long_strike  = _safe_float(long_c["strike"])

            if side == "call":
                if long_strike <= short_strike:
                    continue
            elif side == "put":
                if long_strike >= short_strike:
                    continue
            else:
                continue

            width = round(abs(long_strike - short_strike), 4)
            if not _is_supported_width(width):
                continue

            quantity = _contracts_for_same_risk(total_risk=total_risk, width=width)
            if quantity <= 0:
                continue

            short_fill = _pricing_value(short_c, action="sell", pricing_mode=pricing_mode)
            long_fill  = _pricing_value(long_c,  action="buy",  pricing_mode=pricing_mode)

            if short_fill <= 0 or long_fill <= 0:
                continue

            net_credit_per_spread = (short_fill - long_fill) * 100.0
            if net_credit_per_spread <= 0:
                continue

            gross_defined_risk = width * 100.0 * quantity
            short_value = short_fill * 100.0 * quantity
            long_cost   = long_fill  * 100.0 * quantity
            net_credit  = net_credit_per_spread * quantity
            max_loss    = gross_defined_risk - net_credit
            limit_impact = max(short_value, long_cost)

            # Credit received as % of gross defined risk (primary metric)
            credit_pct_risk = net_credit / gross_defined_risk if gross_defined_risk > 0 else 0.0

            reward_to_max_loss: Optional[float] = None
            if abs(max_loss) > 1e-12:
                reward_to_max_loss = net_credit / max_loss

            results.append(
                {
                    "symbol":         symbol.upper(),
                    "expiration":     expiration,
                    "structure":      "credit_spread",
                    "option_side":    side,
                    "short_strike":   round(short_strike, 4),
                    "long_strike":    round(long_strike, 4),
                    "width":          round(width, 4),
                    "quantity":       quantity,
                    # risk fields
                    "defined_risk":         round(gross_defined_risk, 2),
                    "gross_defined_risk":   round(gross_defined_risk, 2),
                    "max_loss":             round(max_loss, 2),
                    # price fields
                    "short_price":  round(short_fill, 4),
                    "long_price":   round(long_fill, 4),
                    "short_value":  round(short_value, 2),
                    "long_cost":    round(long_cost, 2),
                    "net_credit":   round(net_credit, 2),
                    # reward/risk
                    "credit_pct_risk":        round(credit_pct_risk, 6),
                    "credit_pct_risk_pct":    round(credit_pct_risk * 100.0, 2),
                    "reward_to_max_loss":     round(reward_to_max_loss, 6) if reward_to_max_loss is not None else None,
                    "reward_to_max_loss_pct": round(reward_to_max_loss * 100.0, 2) if reward_to_max_loss is not None else None,
                    "limit_impact":           round(limit_impact, 2),
                    # Greeks / vol
                    "short_delta": round(_safe_float(short_c.get("delta")), 6),
                    "long_delta":  round(_safe_float(long_c.get("delta")), 6),
                    "short_iv":    round(_safe_float(short_c.get("iv")), 6),
                    "long_iv":     round(_safe_float(long_c.get("iv")), 6),
                    "avg_iv":      round(
                        (_safe_float(short_c.get("iv")) + _safe_float(long_c.get("iv"))) / 2.0, 6
                    ),
                    "underlying_price":       round(underlying_price, 4),
                    "short_option_symbol":    short_c.get("option_symbol", ""),
                    "long_option_symbol":     long_c.get("option_symbol", ""),
                    "pricing_mode":           pricing_mode,
                }
            )

    return results


# ---------------------------------------------------------------------------
# Enrichment pass (relative ranking within each expiration/side bucket)
# ---------------------------------------------------------------------------

def _enrich_candidates(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Add expiration-relative ranking fields:
      credit_pct_risk_rank_within_exp
      iv_rank_within_exp
      exp_avg_credit_pct_risk
      exp_avg_iv
      credit_pct_vs_exp_avg
      iv_vs_exp_avg
      richness_score  (70% credit rank + 30% IV rank)
    """
    grouped: Dict[Tuple[str, str], List[Dict[str, Any]]] = defaultdict(list)
    for item in items:
        grouped[(item["expiration"], item["option_side"])].append(item)

    for group in grouped.values():
        credit_values = [item["credit_pct_risk"] for item in group]
        iv_values     = [item["avg_iv"]           for item in group]

        credit_ranks = _percentile_ranks(credit_values)
        iv_ranks     = _percentile_ranks(iv_values)

        avg_credit = sum(credit_values) / len(credit_values) if credit_values else 0.0
        avg_iv     = sum(iv_values)     / len(iv_values)     if iv_values     else 0.0

        for idx, item in enumerate(group):
            cr = credit_ranks[idx]
            ir = iv_ranks[idx]
            item["credit_pct_risk_rank_within_exp"] = round(cr, 6)
            item["iv_rank_within_exp"]              = round(ir, 6)
            item["exp_avg_credit_pct_risk"]         = round(avg_credit, 6)
            item["exp_avg_credit_pct_risk_pct"]     = round(avg_credit * 100.0, 2)
            item["exp_avg_iv"]                      = round(avg_iv, 6)
            item["credit_pct_vs_exp_avg"]           = round(item["credit_pct_risk"] / avg_credit if avg_credit > 0 else 0.0, 6)
            item["iv_vs_exp_avg"]                   = round(item["avg_iv"] / avg_iv if avg_iv > 0 else 0.0, 6)
            item["richness_score"]                  = round((0.70 * cr) + (0.30 * ir), 6)

    return items


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_risk_equivalent_candidates(
    symbol: str = "SPY",
    total_risk: float = 600.0,
    expirations: Optional[List[str]] = None,
    side_filter: str = "all",
    pricing_mode: str = "conservative_mid",
    strike_count: int = 200,
    ranking: str = "richness",
    max_results: int = 250,
) -> List[Dict[str, Any]]:
    """
    Main entry point for the entry scanner.

    Reads contracts from the shared cache (via cache_manager).
    Does NOT call Schwab directly.

    Args:
        symbol:       Underlying ticker.
        total_risk:   Target total defined risk in dollars (e.g. 600).
        expirations:  If None, all cached expirations are scanned.
        side_filter:  'all' | 'call' | 'put'
        pricing_mode: 'conservative_mid' | 'mid' | 'natural'
        strike_count: Passed to cache_manager in case a fresh load is needed.
        ranking:      'credit' | 'credit_pct_risk' | 'limit_impact' | 'max_loss' | 'richness'
        max_results:  Truncate output to this many rows.

    Returns:
        List of spread candidate dicts, sorted by `ranking`.
    """
    side_filter = side_filter.lower().strip()
    if side_filter not in {"all", "call", "put"}:
        raise ValueError("side_filter must be one of: all, call, put")

    # Pull from the shared cache (will refresh if stale)
    state = ensure_symbol_loaded(
        symbol=symbol, strike_count=strike_count, requested_by="scanner"
    )
    all_contracts   = list(state.get("contracts", []))
    underlying_price = _safe_float(state.get("underlying_price"))
    allowed_expirations = set(expirations or [])

    # Group contracts by (expiration, side)
    by_exp_and_side: Dict[Tuple[str, str], List[Dict[str, Any]]] = defaultdict(list)
    for contract in all_contracts:
        exp  = contract["expiration"]
        side = contract["option_side"]
        if allowed_expirations and exp not in allowed_expirations:
            continue
        if side_filter != "all" and side != side_filter:
            continue
        by_exp_and_side[(exp, side)].append(contract)

    # Build candidates for each expiration/side bucket
    results: List[Dict[str, Any]] = []
    for (expiration, option_side), contracts in by_exp_and_side.items():
        results.extend(
            _build_spread_candidates_for_expiration(
                symbol=symbol,
                expiration=expiration,
                underlying_price=underlying_price,
                side=option_side,
                contracts=contracts,
                total_risk=total_risk,
                pricing_mode=pricing_mode,
            )
        )

    results = _enrich_candidates(results)
    results = _sort_candidates(results, ranking=ranking)

    if max_results > 0:
        results = results[:max_results]

    return results

'@
Write-TextFile "backend\scanner.py" $c

$c = @'
from __future__ import annotations

from typing import Any, Dict, List, Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv()

# --- local modules (import AFTER load_dotenv so env vars are present) ---
from cache_manager import (
    ensure_symbol_loaded,
    get_symbol_state,
    list_cached_symbols,
    manual_refresh_symbol,
)
from field_registry import ENTRY_STRATEGIES, SCANNER_FIELDS, VALID_SORT_KEYS
from limit_engine import compute_limit_summary, compute_selected_totals
from notify import send_whatsapp_message
from positions import normalize_mock_positions
from refresh_scheduler import start_scheduler
from scanner import generate_risk_equivalent_candidates
from source_router import get_active_chain_source
from tasty_adapter import extract_net_liq, fetch_account_snapshot, normalize_live_positions
from vol_surface import build_vol_surface_payload

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="Granite Trader", version="0.3.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------

class SelectedRowsPayload(BaseModel):
    rows: List[Dict[str, Any]]


class AlertPayload(BaseModel):
    title: str
    message: str
    notify_whatsapp: bool = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_expirations(expiration: str) -> Optional[List[str]]:
    exp = (expiration or "all").strip().lower()
    if exp == "all":
        return None
    return [expiration.strip()]


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

@app.on_event("startup")
def on_startup() -> None:
    start_scheduler()


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health")
def health() -> Dict[str, Any]:
    return {
        "status": "ok",
        "active_chain_source": get_active_chain_source(),
        "cached_symbols": list_cached_symbols(),
    }


# ---------------------------------------------------------------------------
# Account / positions
# ---------------------------------------------------------------------------

@app.get("/account/mock")
def account_mock() -> Dict[str, Any]:
    positions = normalize_mock_positions()
    limit_summary = compute_limit_summary(72.0, positions)
    return {"source": "mock", "positions": positions, "limit_summary": limit_summary}


@app.get("/account/tasty")
def account_tasty() -> Dict[str, Any]:
    try:
        snapshot = fetch_account_snapshot()
        positions = normalize_live_positions(snapshot)
        net_liq = extract_net_liq(snapshot)
        limit_summary = compute_limit_summary(net_liq, positions)
        return {"source": "tasty", "positions": positions, "limit_summary": limit_summary}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/totals")
def totals(payload: SelectedRowsPayload) -> Dict[str, Any]:
    return compute_selected_totals(payload.rows)


# ---------------------------------------------------------------------------
# Cache / data management
# ---------------------------------------------------------------------------

@app.get("/cache/status")
def cache_status() -> Dict[str, Any]:
    symbols = list_cached_symbols()
    return {
        "symbols": symbols,
        "count": len(symbols),
        "active_chain_source": get_active_chain_source(),
    }


@app.get("/refresh/symbol")
def refresh_symbol(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(200, ge=25, le=500),
) -> Dict[str, Any]:
    """Force-refresh the chain cache for one symbol regardless of freshness."""
    try:
        state = manual_refresh_symbol(symbol=symbol, strike_count=strike_count)
        return {
            "symbol": symbol.upper(),
            "active_chain_source": state.get("active_chain_source"),
            "quote_source": state.get("quote_source"),
            "contract_count": len(state.get("contracts", [])),
            "expirations": state.get("expirations", []),
            "updated_at_epoch": state.get("updated_at_epoch"),
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Quote
# ---------------------------------------------------------------------------

@app.get("/quote/schwab")
def quote_schwab(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(200, ge=25, le=500),
) -> Dict[str, Any]:
    """
    Trigger symbol load (caches chain for next 5 min) and return the raw Schwab quote.
    Downstream: scanner + vol surface will read from the same cached payload.
    """
    try:
        state = ensure_symbol_loaded(
            symbol=symbol, strike_count=strike_count, requested_by="quote"
        )
        quote_raw = state.get("quote_raw", {})
        if not quote_raw:
            raise RuntimeError(f"No quote payload available for {symbol.upper()}")
        return quote_raw
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Chain data
# ---------------------------------------------------------------------------

@app.get("/chain")
def chain(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(200, ge=25, le=500),
) -> Dict[str, Any]:
    """Return the cached normalized chain contracts for a symbol."""
    try:
        state = ensure_symbol_loaded(
            symbol=symbol, strike_count=strike_count, requested_by="chain"
        )
        return {
            "symbol": state.get("symbol", symbol.upper()),
            "underlying_price": state.get("underlying_price"),
            "count": len(state.get("contracts", [])),
            "expirations": state.get("expirations", []),
            "strikes": state.get("strikes", []),
            "items": state.get("contracts", []),
            "active_chain_source": state.get("active_chain_source"),
            "symbol_snapshot": state.get("symbol_snapshot", {}),
            "metadata": state.get("metadata", {}),
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/symbol/snapshot")
def symbol_snapshot(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(200, ge=25, le=500),
) -> Dict[str, Any]:
    """Return watchlist-style derived fields for a symbol."""
    try:
        state = ensure_symbol_loaded(
            symbol=symbol, strike_count=strike_count, requested_by="symbol_snapshot"
        )
        return {
            "symbol": state.get("symbol", symbol.upper()),
            "quote_snapshot": state.get("quote_snapshot", {}),
            "symbol_snapshot": state.get("symbol_snapshot", {}),
            "active_chain_source": state.get("active_chain_source"),
            "metadata": state.get("metadata", {}),
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Volatility surface
# ---------------------------------------------------------------------------

@app.get("/vol/surface")
def vol_surface(
    symbol: str = Query(..., min_length=1),
    max_expirations: int = Query(7, ge=1, le=20),
    strike_count: int = Query(21, ge=5, le=101),
) -> Dict[str, Any]:
    """
    IV surface for the nearest `max_expirations` expirations.
    Reads from the shared cache — no extra chain request.
    Includes separate call_iv_matrix, put_iv_matrix, skew_matrix.
    """
    try:
        return build_vol_surface_payload(
            symbol=symbol,
            max_expirations=max_expirations,
            strike_count=strike_count,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Scanner
# ---------------------------------------------------------------------------

@app.get("/scan")
def scan_legacy(
    symbol: str = Query("SPY"),
    total_risk: float = Query(600.0, gt=0),
    side: str = Query("all"),
    expiration: str = Query("all"),
    sort_by: str = Query("credit_pct_risk"),
    strike_count: int = Query(200, ge=25, le=500),
    max_results: int = Query(100, ge=1, le=1000),
) -> Dict[str, Any]:
    """Backward-compat alias → /scan/live."""
    return scan_live(
        symbol=symbol,
        total_risk=total_risk,
        side=side,
        expiration=expiration,
        sort_by=sort_by,
        strike_count=strike_count,
        max_results=max_results,
    )


@app.get("/scan/live")
def scan_live(
    symbol: str = Query(..., min_length=1),
    total_risk: float = Query(600.0, gt=0),
    side: str = Query("all"),
    expiration: str = Query("all"),
    sort_by: str = Query("credit_pct_risk"),
    strike_count: int = Query(200, ge=25, le=500),
    max_results: int = Query(100, ge=1, le=1000),
) -> Dict[str, Any]:
    """
    Live credit-spread scanner.

    Reads from the shared cache — a /quote/schwab or /refresh/symbol call for the
    same symbol populates (or refreshes) the cache.  The auto-scheduler also
    refreshes every 5 minutes during market hours.

    sort_by: credit | credit_pct_risk | limit_impact | max_loss | richness
    """
    side = side.lower().strip()
    if side not in {"all", "call", "put"}:
        raise HTTPException(status_code=400, detail="side must be all, call, or put")

    sort_by = sort_by.strip().lower()
    if sort_by not in VALID_SORT_KEYS:
        raise HTTPException(
            status_code=400,
            detail=f"sort_by must be one of: {', '.join(sorted(VALID_SORT_KEYS))}",
        )

    expirations = _parse_expirations(expiration)

    try:
        items = generate_risk_equivalent_candidates(
            symbol=symbol,
            total_risk=total_risk,
            expirations=expirations,
            side_filter=side,
            pricing_mode="conservative_mid",
            strike_count=strike_count,
            ranking=sort_by,
            max_results=max_results,
        )
        state = get_symbol_state(symbol)
        return {
            "symbol": symbol.upper(),
            "total_risk": round(total_risk, 2),
            "side": side,
            "expiration_filter": expirations,
            "sort_by": sort_by,
            "pricing_mode": "conservative_mid",
            "count": len(items),
            "items": items,
            "active_chain_source": state.get("active_chain_source"),
            "symbol_snapshot": state.get("symbol_snapshot", {}),
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Field registry
# ---------------------------------------------------------------------------

@app.get("/field-registry")
def field_registry() -> Dict[str, Any]:
    return {
        "entry_strategies": ENTRY_STRATEGIES,
        "scanner_fields": SCANNER_FIELDS,
        "valid_sort_keys": sorted(VALID_SORT_KEYS),
    }


# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------

@app.post("/alerts/send")
def alerts_send(payload: AlertPayload) -> Dict[str, Any]:
    result: Dict[str, Any] = {"desktop": True, "whatsapp": None}
    if payload.notify_whatsapp:
        result["whatsapp"] = send_whatsapp_message(f"{payload.title}\n{payload.message}")
    return result

'@
Write-TextFile "backend\main.py" $c


# Barchart README
Write-TextFile "data\barchart\README.txt" "Watchlist CSV  -> data\barchart\watchlists\weeklys_latest.csv`nChain JSON dir -> data\barchart\chains\<SYMBOL>.json`nSee barchart_adapter.py for expected schema.`n"

# Un-track token file from git if it was accidentally committed
Push-Location $Root
if (Test-Path ".git") {
    git ls-files --error-unmatch "backend/schwab_token.json" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        git rm --cached "backend/schwab_token.json" 2>$null | Out-Null
        Write-Warn "Stopped tracking backend/schwab_token.json"
    }
}

# pip install in WSL
if (-not $SkipPipSync) {
    Write-Info "Running pip install in WSL..."
    try {
        $wslRoot = ($Root -replace "C:\\", "/mnt/c/") -replace "\\", "/"
        $wslCmd  = "cd '$wslRoot' && ([ -d venv ] && source venv/bin/activate); pip install -r requirements.txt -q"
        wsl.exe bash -lc $wslCmd
        Write-OK "pip install complete."
    } catch {
        Write-Warn "WSL pip sync failed. Run ./install_and_run_wsl.sh manually if needed."
    }
}

# git add / commit / push
if (-not $SkipGit -and (Test-Path ".git")) {
    Write-Info "Running git add / commit / push..."
    git add -A
    if (git status --porcelain) {
        git commit -m "v0.3 data plumbing: shared cache + source router + vol surface skew fix"
        git push
        Write-OK "Git push complete."
    } else {
        Write-Info "Nothing new to commit."
    }
}
Pop-Location

Write-Host ""
Write-OK "=== Granite Trader v0.3 install complete ==="
Write-Host "  Backup: $backupDir" -ForegroundColor Gray
Write-Host ""
Write-Host "Test URLs (restart app first):" -ForegroundColor Cyan
Write-Host "  http://localhost:8000/health"
Write-Host "  http://localhost:8000/quote/schwab?symbol=SPY"
Write-Host "  http://localhost:8000/scan/live?symbol=SPY&total_risk=600&sort_by=credit_pct_risk"
Write-Host "  http://localhost:8000/vol/surface?symbol=SPY&max_expirations=7&strike_count=21"
Write-Host "  http://localhost:8000/field-registry"
