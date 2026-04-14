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
