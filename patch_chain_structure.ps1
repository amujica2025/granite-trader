param([string]$Root = "C:\\Users\\alexm\\granite_trader")
$ErrorActionPreference = "Stop"
$p = Join-Path $Root "backend\\tasty_chain_adapter.py"
$c = @'
"""
tasty_chain_adapter.py  ?  Granite Trader

Fetches option chain STRUCTURE from tastytrade REST API:
  GET /option-chains/{symbol}/nested
  Returns: items[0] -> expirations[] -> strikes[]
  Each strike has: strike-price, call symbol, put symbol, streamer-symbols

Bid/ask/delta/IV come from DXLink:
  - Subscribes all option streamer-symbols to DXLink Quote + Greeks
  - Waits briefly for DXLink data to arrive
  - Falls back to 0 if DXLink hasn't streamed yet (scanner will be sparse
    on very first cold load; subsequent calls will have live data)

This is the correct architecture: tastytrade = structure truth,
DXLink = price/Greeks truth.
"""
from __future__ import annotations

import os
import time
from collections import Counter
from typing import Any, Dict, List, Optional

import requests

TASTY_BASE = os.getenv("TASTY_BASE_URL", "https://api.tastytrade.com")


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
        diffs = [round(u[i+1] - u[i], 4) for i in range(len(u)-1)]
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


# ?? DXLink subscription helper ????????????????????????????????????????????????

def _subscribe_option_symbols(
    call_syms: List[str],
    put_syms:  List[str],
) -> None:
    """
    Subscribe option streamer-symbols to DXLink Quote + Greeks.
    Non-fatal if DXLink not yet connected.
    """
    all_syms = call_syms + put_syms
    if not all_syms:
        return
    try:
        from dx_streamer import streamer_subscribe_greeks, _streamer, _loop
        import asyncio

        # Subscribe Greeks (includes IV + delta)
        if _streamer and _loop and _loop.is_running():
            asyncio.run_coroutine_threadsafe(
                _streamer.subscribe_greeks(all_syms), _loop
            )

        # Also subscribe Quote events for bid/ask
        # We do this by adding them to the quote subscription channel
        if _streamer and _loop and _loop.is_running():
            subs = []
            for sym in all_syms:
                subs.append({"type": "Quote",  "symbol": sym})
            import asyncio as _asyncio
            _asyncio.run_coroutine_threadsafe(
                _streamer._send({
                    "type": "FEED_SUBSCRIPTION",
                    "channel": _streamer._channel,
                    "reset": False,
                    "add": subs,
                }),
                _loop,
            )
    except Exception:
        pass   # DXLink not connected yet ? that's OK


# ?? Main fetch ????????????????????????????????????????????????????????????????

def refresh_symbol_from_tasty(
    symbol: str,
    strike_count: int = 200,
    max_expirations: int = 7,
) -> Dict[str, Any]:
    """
    Fetch option chain from tastytrade and normalize to scanner-compatible format.
    Bid/ask/delta/IV sourced from DXLink store (live streaming).
    """
    sym = symbol.upper()

    # ?? 1. Get underlying price from DXLink store ????????????????????????
    from data_store import store as _store
    underlying_price = _store.get_live_price(sym) or 0.0

    # ?? 2. Fetch chain structure from tastytrade ?????????????????????????
    resp = requests.get(
        f"{TASTY_BASE}/option-chains/{sym}/nested",
        headers=_headers(),
        timeout=15,
    )
    if not resp.ok:
        raise RuntimeError(f"tastytrade chain {resp.status_code}: {resp.text[:200]}")

    data = resp.json().get("data", {})

    # Structure: data.items[0].expirations[].strikes[]
    items = data.get("items", [])
    if not items:
        raise RuntimeError(f"No chain items for {sym}")

    chain_item  = items[0]
    expirations = chain_item.get("expirations", [])
    if not expirations:
        raise RuntimeError(f"No expirations in chain for {sym}")

    # ?? 3. Build skeleton contracts + collect DXLink symbols ?????????????
    contracts:    List[Dict[str, Any]] = []
    exp_dates:    List[str]            = []
    all_strikes:  List[float]          = []
    call_syms:    List[str]            = []
    put_syms:     List[str]            = []

    # Sort expirations by date, take nearest max_expirations
    expirations_sorted = sorted(
        expirations,
        key=lambda e: str(e.get("expiration-date", ""))
    )[:max_expirations]

    for exp_obj in expirations_sorted:
        exp_date = str(exp_obj.get("expiration-date", ""))
        dte      = int(exp_obj.get("days-to-expiration", 0))
        if not exp_date:
            continue

        exp_dates.append(exp_date)
        strikes_list = exp_obj.get("strikes", [])

        # Limit to strike_count nearest ATM
        if underlying_price > 0 and len(strikes_list) > strike_count:
            strikes_list = sorted(
                strikes_list,
                key=lambda s: abs(_f(s.get("strike-price", 0)) - underlying_price)
            )[:strike_count]

        for strike_obj in strikes_list:
            strike_px = _f(strike_obj.get("strike-price", 0))
            if strike_px <= 0:
                continue
            all_strikes.append(strike_px)

            call_streamer = str(strike_obj.get("call-streamer-symbol", "") or "")
            put_streamer  = str(strike_obj.get("put-streamer-symbol", "")  or "")
            call_sym      = str(strike_obj.get("call", "") or "")
            put_sym       = str(strike_obj.get("put",  "") or "")

            if call_streamer: call_syms.append(call_streamer)
            if put_streamer:  put_syms.append(put_streamer)

            # Build call and put leg ? prices from DXLink store if available
            for side, streamer_sym, option_sym in (
                ("call", call_streamer, call_sym),
                ("put",  put_streamer,  put_sym),
            ):
                if not streamer_sym:
                    continue

                # Pull live data from DXLink store
                live_q = _store.get_live_quote(streamer_sym)   # Quote event (bid/ask)
                live_g = _store.get_option_greeks(streamer_sym) # Greeks event (delta/IV)

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
                    "strike":              round(strike_px, 4),
                    "bid":                 round(bid,  4),
                    "ask":                 round(ask,  4),
                    "mark":                round(mark, 4),
                    "mid":                 round(mark, 4),
                    "delta":               round(delta, 6),
                    "iv":                  round(iv,   6),
                    "total_volume":        0.0,
                    "open_interest":       0.0,
                    "in_the_money":        (
                        strike_px < underlying_price if side == "call"
                        else strike_px > underlying_price
                    ) if underlying_price > 0 else False,
                    "option_symbol":       option_sym.strip(),
                    "streamer_symbol":     streamer_sym,
                    "description":         f"{sym} {exp_date} {side.upper()} {strike_px}",
                    "underlying_price":    round(underlying_price, 4),
                })

    if not contracts:
        raise RuntimeError(
            f"Chain parsed but produced no contracts for {sym}. "
            f"Expirations found: {len(exp_dates)}, underlying_price: {underlying_price}"
        )

    # ?? 4. Subscribe to DXLink in background ????????????????????????????
    _subscribe_option_symbols(call_syms[:200], put_syms[:200])

    # ?? 5. Build output ??????????????????????????????????????????????????
    exp_sorted    = sorted(set(exp_dates))
    strike_sorted = sorted({round(s, 4) for s in all_strikes})
    spacing       = _strike_spacing(contracts)

    # ATM IV estimate
    if underlying_price > 0:
        atm_c = sorted(contracts, key=lambda c: abs(c["strike"] - underlying_price))
        atm_ivs = [c["iv"] for c in atm_c[:4] if c["iv"] > 0]
        atm_iv  = sum(atm_ivs) / len(atm_ivs) if atm_ivs else 0.0
    else:
        atm_iv = 0.0

    has_prices = any(c["bid"] > 0 or c["ask"] > 0 for c in contracts)

    return {
        "symbol":                        sym,
        "underlying_price":              round(underlying_price, 4),
        "contracts":                     contracts,
        "expirations":                   exp_sorted,
        "strikes":                       strike_sorted,
        "strike_spacing_by_expiration":  spacing,
        "atm_iv":                        round(atm_iv, 6),
        "active_chain_source":           "tastytrade+dxlink",
        "has_live_prices":               has_prices,
        "symbol_snapshot": {
            "symbol":           sym,
            "underlying_price": round(underlying_price, 2),
            "atm_iv":           round(atm_iv, 4),
            "atm_iv_pct":       round(atm_iv * 100, 2),
            "contract_count":   len(contracts),
            "expiration_count": len(exp_sorted),
            "chain_source":     "tastytrade+dxlink",
            "has_live_prices":  has_prices,
        },
        "metadata": {
            "chain_fetched_at":  time.time(),
            "contract_count":    len(contracts),
            "expiration_count":  len(exp_sorted),
            "strike_count":      len(strike_sorted),
            "source":            "tastytrade+dxlink",
            "dxlink_syms_subscribed": len(call_syms) + len(put_syms),
        },
        "quote_raw": {
            sym: {"quote": {
                "lastPrice": underlying_price,
                "mark":      underlying_price,
            }}
        },
    }

'@
[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[OK] tasty_chain_adapter.py fixed" -ForegroundColor Green
Write-Host "Restart uvicorn then test:" -ForegroundColor Yellow
Write-Host "  curl http://localhost:8000/chain?symbol=SPY" -ForegroundColor Cyan
