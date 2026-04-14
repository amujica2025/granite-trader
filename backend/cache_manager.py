"""
cache_manager.py  ?  Granite Trader

Symbol state cache. Uses tastytrade option chains exclusively.
DXLink streaming provides live quotes/candles ? no Schwab needed.
"""
from __future__ import annotations

import os
import time
from typing import Any, Dict, List

from data_store import store

CHAIN_REFRESH_SECONDS  = int(os.getenv("CHAIN_REFRESH_SECONDS", "300"))
DEFAULT_STRIKE_COUNT   = int(os.getenv("DEFAULT_CHAIN_STRIKE_COUNT", "200"))
DEFAULT_MAX_EXPIRATIONS= int(os.getenv("DEFAULT_MAX_EXPIRATIONS", "7"))


def _is_fresh(state: Dict[str, Any]) -> bool:
    last = float(state.get("last_chain_refresh_epoch", 0) or 0)
    return last > 0 and (time.time() - last) < CHAIN_REFRESH_SECONDS


def get_symbol_state(symbol: str) -> Dict[str, Any]:
    return store.get_symbol_state(symbol)


def list_cached_symbols() -> List[str]:
    return store.list_symbols()


def ensure_symbol_loaded(
    symbol: str,
    force: bool = False,
    strike_count: int = DEFAULT_STRIKE_COUNT,
    max_expirations: int = DEFAULT_MAX_EXPIRATIONS,
    requested_by: str = "api",
) -> Dict[str, Any]:
    """
    Return symbol state from cache if fresh, otherwise fetch from tastytrade.
    Falls back to stale cache if tastytrade fetch fails.
    """
    sym      = symbol.upper()
    existing = store.get_symbol_state(sym)

    # Return fresh cache immediately
    if not force and existing and _is_fresh(existing):
        return existing

    # Fetch fresh chain from tastytrade
    try:
        from tasty_chain_adapter import refresh_symbol_from_tasty
        payload = refresh_symbol_from_tasty(
            symbol=sym,
            strike_count=strike_count,
            max_expirations=max_expirations,
        )
    except Exception as exc:
        # Chain fetch failed ? return stale cache if we have it
        if existing and existing.get("contracts"):
            existing["metadata"] = {
                **existing.get("metadata", {}),
                "chain_error": str(exc),
                "using_stale_cache": True,
            }
            return existing
        raise RuntimeError(
            f"tastytrade chain fetch failed for {sym} and no cache available: {exc}"
        )

    payload["updated_at_epoch"]        = time.time()
    payload["last_chain_refresh_epoch"] = time.time()
    payload["requested_by"]            = requested_by
    return store.upsert_symbol_state(sym, payload)


def manual_refresh_symbol(
    symbol: str,
    strike_count: int = DEFAULT_STRIKE_COUNT,
    max_expirations: int = DEFAULT_MAX_EXPIRATIONS,
) -> Dict[str, Any]:
    return ensure_symbol_loaded(
        symbol=symbol,
        force=True,
        strike_count=strike_count,
        max_expirations=max_expirations,
        requested_by="manual_refresh",
    )


def archive_all_cached_symbols(reason: str = "scheduled") -> List[str]:
    from archive_manager import archive_symbol_state
    paths = []
    for sym in list_cached_symbols():
        state = get_symbol_state(sym)
        if state:
            paths.append(str(archive_symbol_state(state, reason=reason)))
    return paths
