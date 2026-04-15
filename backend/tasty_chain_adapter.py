"""
tasty_chain_adapter.py  ?  Granite Trader

Chain data from tastytrade REST + pricing from DXLink streaming.

Flow:
  1. Fetch chain structure from tastytrade /option-chains/{sym}/nested
  2. Collect all streamer-symbols (e.g. .SPY260418C695)
  3. Subscribe them to DXLink Quote + Greeks events
  4. Wait up to WAIT_SECS for prices to arrive in the store
  5. Build normalized contracts with real bid/ask/delta/IV
  6. Return ? scanner and vol_surface get real data

On cold start (no DXLink data yet) we wait and retry.
After first load, data is cached and subsequent calls are instant.
"""
from __future__ import annotations

import os
import time
from collections import Counter
from typing import Any, Dict, List, Optional

import requests

TASTY_BASE = os.getenv("TASTY_BASE_URL", "https://api.tastytrade.com")
WAIT_SECS  = 8    # max seconds to wait for DXLink option quotes on cold start
WAIT_STEP  = 0.5  # poll interval


# ?? Auth ??????????????????????????????????????????????????????????????????????

def _get_token() -> str:
    from tasty_adapter import fetch_account_snapshot
    tok = fetch_account_snapshot().get("session_token", "")
    if not tok:
        raise RuntimeError("tastytrade session_token unavailable")
    return tok


def _headers() -> Dict[str, str]:
    return {"Authorization": f"Bearer {_get_token()}"}


# ?? Helpers ???????????????????????????????????????????????????????????????????

def _f(v: Any, default: float = 0.0) -> float:
    try:
        f = float(v) if v not in (None, "", "NaN") else default
        return f if f == f else default
    except Exception:
        return default


def _mid(bid: float, ask: float) -> float:
    return (bid + ask) / 2.0 if bid > 0 and ask > 0 else ask or bid or 0.0


def _strike_spacing(contracts: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    grouped: Dict[str, List[float]] = {}
    for c in contracts:
        grouped.setdefault(str(c.get("expiration", "")), []).append(_f(c.get("strike", 0)))
    out: Dict[str, Dict[str, Any]] = {}
    for exp, strikes in grouped.items():
        u = sorted({round(s, 4) for s in strikes if s > 0})
        diffs = [round(u[i+1] - u[i], 4) for i in range(len(u) - 1)]
        pos   = [d for d in diffs if d > 0]
        ctr   = Counter(pos)
        out[exp] = {
            "strike_count": len(u),
            "min_step":     min(pos) if pos else None,
            "max_step":     max(pos) if pos else None,
            "common_step":  ctr.most_common(1)[0][0] if ctr else None,
            "step_set":     sorted(ctr.keys()),
        }
    return out


# ?? DXLink subscription ???????????????????????????????????????????????????????

def _subscribe_to_dxlink(streamer_syms: List[str]) -> bool:
    """
    Subscribe option streamer-symbols to DXLink Quote + Greeks.
    Returns True if DXLink is connected, False otherwise.
    """
    if not streamer_syms:
        return False
    try:
        from dx_streamer import _streamer, _loop, streamer_is_connected
        import asyncio

        if not streamer_is_connected():
            return False

        # Subscribe Quote events (bid/ask)
        quote_subs = [{"type": "Quote", "symbol": s} for s in streamer_syms]
        asyncio.run_coroutine_threadsafe(
            _streamer._send({
                "type": "FEED_SUBSCRIPTION",
                "channel": _streamer._channel,
                "reset": False,
                "add": quote_subs,
            }),
            _loop,
        )

        # Subscribe Greeks (delta/IV/theta/vega)
        asyncio.run_coroutine_threadsafe(
            _streamer.subscribe_greeks(streamer_syms),
            _loop,
        )
        return True
    except Exception as e:
        return False


def _wait_for_option_quotes(
    streamer_syms: List[str],
    store: Any,
    wait_secs: float = WAIT_SECS,
) -> int:
    """
    Poll the store until option Quote events arrive.
    Returns number of symbols that got prices.
    """
    if not streamer_syms:
        return 0

    deadline = time.time() + wait_secs
    sample   = streamer_syms[:10]   # check a sample, not all

    while time.time() < deadline:
        filled = sum(
            1 for s in sample
            if store.get_live_quote(s).get("live_bid", 0) > 0
        )
        if filled >= min(3, len(sample)):
            return filled
        time.sleep(WAIT_STEP)

    return sum(
        1 for s in sample
        if store.get_live_quote(s).get("live_bid", 0) > 0
    )


# ?? Main fetch ????????????????????????????????????????????????????????????????

def refresh_symbol_from_tasty(
    symbol: str,
    strike_count: int = 200,
    max_expirations: int = 7,
) -> Dict[str, Any]:
    sym = symbol.upper()

    # 1. Underlying price from DXLink store
    from data_store import store as _store
    underlying_price = _store.get_live_price(sym) or 0.0

    # 2. Fetch chain structure
    resp = requests.get(
        f"{TASTY_BASE}/option-chains/{sym}/nested",
        headers=_headers(),
        timeout=15,
    )
    if not resp.ok:
        raise RuntimeError(f"tastytrade chain {resp.status_code}: {resp.text[:200]}")

    data  = resp.json().get("data", {})
    items = data.get("items", [])
    if not items:
        raise RuntimeError(f"No chain items for {sym}")

    chain_item  = items[0]
    expirations = sorted(
        chain_item.get("expirations", []),
        key=lambda e: str(e.get("expiration-date", ""))
    )[:max_expirations]

    if not expirations:
        raise RuntimeError(f"No expirations for {sym}")

    # 3. Collect all streamer symbols
    all_streamer: List[str] = []
    exp_strike_map: List[tuple] = []   # (exp_date, dte, strike_px, call_str, put_str, call_sym, put_sym)

    for exp_obj in expirations:
        exp_date = str(exp_obj.get("expiration-date", ""))
        dte      = int(exp_obj.get("days-to-expiration", 0))
        if not exp_date:
            continue

        strikes_list = exp_obj.get("strikes", [])

        # Limit to nearest ATM
        if underlying_price > 0 and len(strikes_list) > strike_count:
            strikes_list = sorted(
                strikes_list,
                key=lambda s: abs(_f(s.get("strike-price", 0)) - underlying_price)
            )[:strike_count]

        for s in strikes_list:
            sp      = _f(s.get("strike-price", 0))
            cs      = str(s.get("call-streamer-symbol", "") or "")
            ps      = str(s.get("put-streamer-symbol",  "") or "")
            csym    = str(s.get("call", "") or "").strip()
            psym    = str(s.get("put",  "") or "").strip()

            if cs: all_streamer.append(cs)
            if ps: all_streamer.append(ps)
            exp_strike_map.append((exp_date, dte, sp, cs, ps, csym, psym))

    # 4. Subscribe to DXLink and wait for prices
    dxlink_connected = _subscribe_to_dxlink(all_streamer)
    if dxlink_connected:
        # Only wait if we don't already have data
        sample_sym = all_streamer[0] if all_streamer else ""
        already_has_data = (
            sample_sym and
            _store.get_live_quote(sample_sym).get("live_bid", 0) > 0
        )
        if not already_has_data:
            _wait_for_option_quotes(all_streamer, _store, wait_secs=WAIT_SECS)

    # 5. Build contracts using live data
    contracts:   List[Dict[str, Any]] = []
    exp_dates:   List[str] = []
    all_strikes: List[float] = []

    for (exp_date, dte, sp, cs, ps, csym, psym) in exp_strike_map:
        if exp_date not in exp_dates:
            exp_dates.append(exp_date)
        if sp > 0:
            all_strikes.append(sp)

        for side, streamer_sym, option_sym in (
            ("call", cs, csym),
            ("put",  ps, psym),
        ):
            if not streamer_sym:
                continue

            # Pull from store
            live_q = _store.get_live_quote(streamer_sym)
            live_g = _store.get_option_greeks(streamer_sym)

            bid   = _f(live_q.get("live_bid"))
            ask   = _f(live_q.get("live_ask"))
            mark  = _mid(bid, ask)
            delta = _f(live_g.get("live_delta"))
            iv    = _f(live_g.get("live_iv"))

            contracts.append({
                "underlying":          sym,
                "option_side":         side,
                "expiration":          exp_date,
                "days_to_expiration":  dte,
                "strike":              round(sp, 4),
                "bid":                 round(bid,  4),
                "ask":                 round(ask,  4),
                "mark":                round(mark, 4),
                "mid":                 round(mark, 4),
                "delta":               round(delta, 6),
                "iv":                  round(iv,   6),
                "total_volume":        0.0,
                "open_interest":       0.0,
                "in_the_money":        (
                    sp < underlying_price if side == "call"
                    else sp > underlying_price
                ) if underlying_price > 0 else False,
                "option_symbol":       option_sym,
                "streamer_symbol":     streamer_sym,
                "description":         f"{sym} {exp_date} {side.upper()} {sp}",
                "underlying_price":    round(underlying_price, 4),
            })

    if not contracts:
        raise RuntimeError(f"No contracts built for {sym}")

    # Count how many have real prices
    priced = sum(1 for c in contracts if c["bid"] > 0 or c["ask"] > 0)

    exp_sorted    = sorted(set(exp_dates))
    strike_sorted = sorted({round(s, 4) for s in all_strikes})
    spacing       = _strike_spacing(contracts)

    # ATM IV
    if underlying_price > 0:
        atm_c  = sorted(contracts, key=lambda c: abs(c["strike"] - underlying_price))
        atm_ivs = [c["iv"] for c in atm_c[:4] if c["iv"] > 0]
        atm_iv  = sum(atm_ivs) / len(atm_ivs) if atm_ivs else 0.0
    else:
        atm_iv = 0.0

    return {
        "symbol":                        sym,
        "underlying_price":              round(underlying_price, 4),
        "contracts":                     contracts,
        "expirations":                   exp_sorted,
        "strikes":                       strike_sorted,
        "strike_spacing_by_expiration":  spacing,
        "atm_iv":                        round(atm_iv, 6),
        "active_chain_source":           "tastytrade+dxlink",
        "has_live_prices":               priced > 0,
        "priced_contracts":              priced,
        "total_contracts":               len(contracts),
        "symbol_snapshot": {
            "symbol":           sym,
            "underlying_price": round(underlying_price, 2),
            "atm_iv":           round(atm_iv, 4),
            "atm_iv_pct":       round(atm_iv * 100, 2),
            "contract_count":   len(contracts),
            "priced_contracts": priced,
            "expiration_count": len(exp_sorted),
            "chain_source":     "tastytrade+dxlink",
        },
        "metadata": {
            "chain_fetched_at":  time.time(),
            "contract_count":    len(contracts),
            "priced_contracts":  priced,
            "expiration_count":  len(exp_sorted),
            "source":            "tastytrade+dxlink",
            "dxlink_connected":  dxlink_connected,
        },
        "quote_raw": {
            sym: {"quote": {
                "lastPrice": underlying_price,
                "mark":      underlying_price,
            }}
        },
    }
