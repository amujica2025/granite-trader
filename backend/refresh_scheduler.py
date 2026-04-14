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
