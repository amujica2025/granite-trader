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
