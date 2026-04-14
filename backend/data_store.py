from __future__ import annotations

import threading
import time
from typing import Any, Dict, List, Optional


class DataStore:
    """
    Thread-safe in-memory store.

    Sections:
      1. symbol_state   - chain/vol/scanner data (from schwab_adapter)
      2. live_quotes    - real-time Quote/Trade/Summary from DXLink
      3. option_greeks  - real-time Greeks from DXLink per option symbol
      4. live_balance   - real-time account balance from Account Streamer
    """

    def __init__(self) -> None:
        self._lock           = threading.RLock()
        self._symbols:       Dict[str, Dict[str, Any]] = {}
        self._live_quotes:   Dict[str, Dict[str, Any]] = {}
        self._option_greeks: Dict[str, Dict[str, Any]] = {}
        self._live_balance:  Dict[str, Any] = {}

    # ?? Symbol state ???????????????????????????????????????????????????????

    def upsert_symbol_state(self, symbol: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        key = symbol.upper()
        with self._lock:
            existing = self._symbols.get(key, {})
            merged   = dict(existing)
            merged.update(payload)
            merged["symbol"] = key
            if "updated_at_epoch" not in merged:
                merged["updated_at_epoch"] = time.time()
            self._symbols[key] = merged
            return dict(merged)

    def get_symbol_state(self, symbol: str) -> Dict[str, Any]:
        with self._lock:
            return dict(self._symbols.get(symbol.upper(), {}))

    def list_symbols(self) -> List[str]:
        with self._lock:
            return sorted(self._symbols.keys())

    def snapshot_all(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            return {k: dict(v) for k, v in self._symbols.items()}

    def clear(self) -> None:
        with self._lock:
            self._symbols.clear()

    # ?? Live quotes (DXLink) ???????????????????????????????????????????????

    def upsert_live_quote(self, symbol: str, data: Dict[str, Any]) -> None:
        key = symbol.upper()
        with self._lock:
            existing = self._live_quotes.get(key, {})
            merged   = dict(existing)
            merged.update(data)
            merged["updated_at"] = time.time()
            self._live_quotes[key] = merged

    def get_live_quote(self, symbol: str) -> Dict[str, Any]:
        with self._lock:
            return dict(self._live_quotes.get(symbol.upper(), {}))

    def get_all_live_quotes(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            return {k: dict(v) for k, v in self._live_quotes.items()}

    def get_live_price(self, symbol: str) -> Optional[float]:
        """Best live last price ? DXLink first, Schwab chain fallback."""
        q    = self.get_live_quote(symbol)
        last = q.get("live_last")
        if last and float(last) > 0:
            return float(last)
        state = self.get_symbol_state(symbol)
        return state.get("underlying_price")

    # ?? Option Greeks (DXLink) ?????????????????????????????????????????????

    def upsert_option_greeks(self, option_symbol: str, data: Dict[str, Any]) -> None:
        with self._lock:
            existing = self._option_greeks.get(option_symbol, {})
            merged   = dict(existing)
            merged.update(data)
            merged["updated_at"] = time.time()
            self._option_greeks[option_symbol] = merged

    def get_option_greeks(self, option_symbol: str) -> Dict[str, Any]:
        with self._lock:
            return dict(self._option_greeks.get(option_symbol, {}))

    def get_all_option_greeks(self) -> Dict[str, Dict[str, Any]]:
        with self._lock:
            return {k: dict(v) for k, v in self._option_greeks.items()}

    # ?? Live balance (Account Streamer) ????????????????????????????????????

    def upsert_live_balance(self, data: Dict[str, Any]) -> None:
        with self._lock:
            self._live_balance.update(data)
            self._live_balance["updated_at"] = time.time()

    def get_live_balance(self) -> Dict[str, Any]:
        with self._lock:
            return dict(self._live_balance)


# singleton
store = DataStore()
