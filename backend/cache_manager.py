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
    1. If the cached state is fresh (< CHAIN_REFRESH_SECONDS old) and force=False â†’ return it.
    2. If outside the chain-refresh window and source is Schwab and we have something â†’ return it.
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

    # Outside chain-refresh window + Schwab source + we have something â†’ hold
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
