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

CHAIN_REFRESH_SECONDS = int(os.getenv("CHAIN_REFRESH_SECONDS", "300"))
DEFAULT_STRIKE_COUNT = int(os.getenv("DEFAULT_CHAIN_STRIKE_COUNT", "200"))
DEFAULT_MAX_EXPIRATIONS = int(os.getenv("DEFAULT_MAX_EXPIRATIONS", "7"))


def _state_is_fresh(state: Dict[str, Any], refresh_seconds: int) -> bool:
    last = float(state.get("last_chain_refresh_epoch", 0.0) or 0.0)
    return last > 0 and (time.time() - last) < refresh_seconds


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
    Load/refresh symbol state from the appropriate source.

    Priority order:
    1. Return fresh cache if available (< CHAIN_REFRESH_SECONDS old)
    2. Return stale cache if outside refresh window and Schwab source
    3. Fetch from Schwab (market hours) or Barchart (after hours)
    4. KEY FIX: if Barchart returns no contracts, fall back to Schwab
       This keeps scanner + vol surface alive after market hours until
       actual Barchart chain JSON files are placed in data/barchart/chains/
    """
    symbol_upper = symbol.upper()
    existing = store.get_symbol_state(symbol_upper)
    active_source = get_active_chain_source()

    # Return cached data if fresh
    if not force and existing and _state_is_fresh(existing, CHAIN_REFRESH_SECONDS):
        return existing

    # Outside refresh window + Schwab + have something â†’ hold
    if (
        not force
        and existing
        and not is_chain_refresh_window()
        and active_source == "schwab"
    ):
        return existing

    if active_source == "schwab":
        payload = refresh_symbol_from_schwab(
            symbol=symbol_upper,
            strike_count=strike_count,
            max_expirations=max_expirations,
        )
    else:
        # After-hours Barchart path
        fallback_quote: Dict[str, Any] = {}
        try:
            fallback_quote = get_quote(symbol_upper)
        except Exception:
            fallback_quote = existing.get("quote_raw", {}) if existing else {}

        payload = refresh_symbol_from_barchart(
            symbol=symbol_upper,
            fallback_quote_raw=fallback_quote,
        )

        # FALLBACK: Barchart has no chain JSON â†’ try Schwab anyway
        if not payload.get("contracts"):
            try:
                schwab_payload = refresh_symbol_from_schwab(
                    symbol=symbol_upper,
                    strike_count=strike_count,
                    max_expirations=max_expirations,
                )
                # Merge any Barchart watchlist fields on top of Schwab snapshot
                merged_snap = dict(schwab_payload.get("symbol_snapshot", {}))
                bc_snap = payload.get("symbol_snapshot", {})
                merged_snap.update({k: v for k, v in bc_snap.items() if v is not None})
                schwab_payload["symbol_snapshot"] = merged_snap
                schwab_payload["active_chain_source"] = "schwab_fallback"
                payload = schwab_payload
            except Exception:
                # Schwab also failed â€” carry over last known contracts if any
                if existing and existing.get("contracts"):
                    payload["contracts"] = existing.get("contracts", [])
                    payload["expirations"] = existing.get("expirations", [])
                    payload["strikes"] = existing.get("strikes", [])
                    payload["underlying_price"] = existing.get("underlying_price")
                    merged_snap = dict(existing.get("symbol_snapshot", {}))
                    merged_snap.update(
                        {k: v for k, v in payload.get("symbol_snapshot", {}).items() if v is not None}
                    )
                    payload["symbol_snapshot"] = merged_snap
                    payload["metadata"] = {
                        **existing.get("metadata", {}),
                        **payload.get("metadata", {}),
                        "using_cached_contracts": True,
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
    return ensure_symbol_loaded(
        symbol=symbol,
        force=True,
        strike_count=strike_count,
        max_expirations=max_expirations,
        requested_by="manual_refresh",
    )


def archive_all_cached_symbols(reason: str = "scheduled") -> List[str]:
    archived_paths: List[str] = []
    for symbol in list_cached_symbols():
        state = get_symbol_state(symbol)
        if state:
            archived_paths.append(str(archive_symbol_state(state, reason=reason)))
    return archived_paths
