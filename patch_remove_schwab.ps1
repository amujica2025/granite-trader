param([string]$Root = "C:\\Users\\alexm\\granite_trader")
$ErrorActionPreference = "Stop"
function WF([string]$rel,[string]$txt){$p=Join-Path $Root ($rel -replace '/','\\')
$d=Split-Path $p -Parent
if(-not(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d|Out-Null}
[System.IO.File]::WriteAllText($p,$txt,(New-Object System.Text.UTF8Encoding($false)))
Write-Host "[OK] $rel" -ForegroundColor Cyan}

Write-Host "Installing tastytrade-only backend..." -ForegroundColor Yellow
$c = @'
"""
tasty_chain_adapter.py  ?  Granite Trader

Fetches option chains from tastytrade REST API.
Normalizes output to the same format previously produced by schwab_adapter.py
so scanner.py, vol_surface.py and cache_manager.py need zero changes.

tastytrade chain endpoint:
  GET /option-chains/{underlying}/nested
  Returns expirations with strikes ? call/put legs with bid/ask/delta/IV

DXLink Greeks supplement:
  IV and delta in the REST chain are snapshot values.
  When DXLink Greeks stream is active, live values overwrite these at runtime.
"""
from __future__ import annotations

import os
import time
from collections import Counter
from statistics import mean
from typing import Any, Dict, List, Optional

import requests


# ?? Auth ??????????????????????????????????????????????????????????????????????

def _get_session_token() -> str:
    """Reuse fetch_account_snapshot for correctly refreshed session token."""
    from tasty_adapter import fetch_account_snapshot
    snap = fetch_account_snapshot()
    tok  = snap.get("session_token", "")
    if not tok:
        raise RuntimeError("tastytrade session_token unavailable ? check .env credentials")
    return tok


def _headers() -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {_get_session_token()}",
        "Content-Type":  "application/json",
    }


TASTY_BASE = os.getenv("TASTY_BASE_URL", "https://api.tastytrade.com")


# ?? Helpers ???????????????????????????????????????????????????????????????????

def _safe_float(v: Any, default: float = 0.0) -> float:
    try:
        f = float(v) if v not in (None, "", "NaN") else default
        return f if f == f else default   # NaN guard
    except Exception:
        return default


def _mid(bid: float, ask: float) -> float:
    if bid > 0 and ask > 0:
        return (bid + ask) / 2.0
    return ask or bid or 0.0


def _compute_strike_spacing(contracts: List[Dict[str, Any]]) -> Dict[str, Dict[str, Any]]:
    """Same as schwab_adapter ? detect strike step per expiration."""
    grouped: Dict[str, List[float]] = {}
    for c in contracts:
        exp = str(c.get("expiration", ""))
        grouped.setdefault(exp, []).append(_safe_float(c.get("strike", 0)))

    output: Dict[str, Dict[str, Any]] = {}
    for exp, strikes in grouped.items():
        unique = sorted({round(s, 4) for s in strikes if s > 0})
        diffs  = [round(unique[i+1] - unique[i], 4) for i in range(len(unique)-1)]
        pos    = [d for d in diffs if d > 0]
        ctr    = Counter(pos)
        output[exp] = {
            "strike_count": len(unique),
            "min_step":     min(pos) if pos else None,
            "max_step":     max(pos) if pos else None,
            "common_step":  ctr.most_common(1)[0][0] if ctr else None,
            "step_set":     sorted(ctr.keys()),
        }
    return output


def _atm_iv(contracts: List[Dict[str, Any]], underlying_price: float) -> float:
    """Compute ATM IV from nearest-to-money contracts."""
    if not contracts or underlying_price <= 0:
        return 0.0
    sorted_c = sorted(contracts, key=lambda x: abs(_safe_float(x.get("strike", 0)) - underlying_price))
    atm = sorted_c[:4]
    ivs = [_safe_float(c.get("iv")) for c in atm if _safe_float(c.get("iv")) > 0]
    return mean(ivs) if ivs else 0.0


# ?? Main chain fetch ??????????????????????????????????????????????????????????

def refresh_symbol_from_tasty(
    symbol: str,
    strike_count: int = 200,
    max_expirations: int = 7,
) -> Dict[str, Any]:
    """
    Fetch option chain from tastytrade and return normalized state dict
    compatible with data_store / scanner / vol_surface.
    """
    symbol_upper = symbol.upper()

    # ?? 1. Quote (live from DXLink store if available, else from chain) ????
    underlying_price = 0.0
    from data_store import store as _store
    live_px = _store.get_live_price(symbol_upper)
    if live_px and live_px > 0:
        underlying_price = live_px

    # ?? 2. Fetch option chain ?????????????????????????????????????????????
    url  = f"{TASTY_BASE}/option-chains/{symbol_upper}/nested"
    resp = requests.get(url, headers=_headers(), timeout=15)

    if not resp.ok:
        raise RuntimeError(
            f"tastytrade chain fetch failed: {resp.status_code} {resp.text[:200]}"
        )

    chain_data = resp.json().get("data", {})
    items      = chain_data.get("items", [])   # list of expiration objects

    if not items:
        raise RuntimeError(f"No option chain data returned for {symbol_upper}")

    # ?? 3. Normalize ??????????????????????????????????????????????????????
    contracts:   List[Dict[str, Any]] = []
    expirations: List[str] = []
    all_strikes: List[float] = []

    for exp_obj in items[:max_expirations]:
        exp_date = str(exp_obj.get("expiration-date", ""))
        dte      = int(exp_obj.get("days-to-expiration", 0))

        if not exp_date:
            continue
        expirations.append(exp_date)

        strikes_list = exp_obj.get("strikes", [])

        # Limit strikes to strike_count nearest to ATM
        if underlying_price > 0 and len(strikes_list) > strike_count:
            strikes_list = sorted(
                strikes_list,
                key=lambda s: abs(_safe_float(s.get("strike-price", 0)) - underlying_price)
            )[:strike_count]

        for strike_obj in strikes_list:
            strike_px = _safe_float(strike_obj.get("strike-price", 0))
            if strike_px <= 0:
                continue
            all_strikes.append(strike_px)

            for side, side_key in (("call", "call"), ("put", "put")):
                leg = strike_obj.get(side_key)
                if not leg:
                    continue

                bid  = _safe_float(leg.get("bid"))
                ask  = _safe_float(leg.get("ask"))
                mark = _safe_float(leg.get("mid-price") or leg.get("mark") or 0)
                if mark == 0:
                    mark = _mid(bid, ask)

                # IV: tastytrade returns as decimal already (e.g. 0.18 = 18%)
                iv    = _safe_float(leg.get("implied-volatility") or leg.get("iv") or 0)
                delta = _safe_float(leg.get("delta") or 0)

                # Use live DXLink Greeks if available
                streamer_sym = str(leg.get("streamer-symbol", "") or "")
                if streamer_sym:
                    live_greeks = _store.get_option_greeks(streamer_sym)
                    if live_greeks:
                        iv    = live_greeks.get("live_iv",    iv)
                        delta = live_greeks.get("live_delta", delta)

                contracts.append({
                    "underlying":         symbol_upper,
                    "option_side":        side,
                    "expiration":         exp_date,
                    "days_to_expiration": dte,
                    "strike":             round(strike_px, 4),
                    "bid":                round(bid,  4),
                    "ask":                round(ask,  4),
                    "mark":               round(mark, 4),
                    "mid":                round(_mid(bid, ask), 4),
                    "delta":              round(delta, 6),
                    "iv":                 round(iv, 6),
                    "total_volume":       _safe_float(leg.get("volume", 0)),
                    "open_interest":      _safe_float(leg.get("open-interest", 0)),
                    "in_the_money":       bool(leg.get("in-the-money")),
                    "option_symbol":      str(leg.get("symbol", "") or ""),
                    "streamer_symbol":    streamer_sym,
                    "description":        str(leg.get("description", "") or ""),
                    "underlying_price":   round(underlying_price, 4),
                })

    if not contracts:
        raise RuntimeError(f"Chain parsed but produced no contracts for {symbol_upper}")

    # If we still don't have underlying price, derive from ATM mark
    if underlying_price <= 0 and contracts:
        atm_c = min(contracts, key=lambda c: abs(c["strike"] - (contracts[0]["underlying_price"] or 500)))
        underlying_price = atm_c.get("strike", 0)

    expirations_sorted = sorted(set(expirations))
    strikes_sorted     = sorted(set(round(s, 4) for s in all_strikes))
    atm_iv             = _atm_iv(contracts, underlying_price)

    spacing = _compute_strike_spacing(contracts)

    # ?? 4. Build symbol snapshot (watchlist-style fields) ?????????????????
    symbol_snapshot: Dict[str, Any] = {
        "symbol":            symbol_upper,
        "underlying_price":  round(underlying_price, 2),
        "atm_iv":            round(atm_iv, 4),
        "atm_iv_pct":        round(atm_iv * 100, 2),
        "contract_count":    len(contracts),
        "expiration_count":  len(expirations_sorted),
        "chain_source":      "tastytrade",
    }

    return {
        "symbol":                         symbol_upper,
        "underlying_price":               round(underlying_price, 4),
        "contracts":                      contracts,
        "expirations":                    expirations_sorted,
        "strikes":                        strikes_sorted,
        "strike_spacing_by_expiration":   spacing,
        "atm_iv":                         round(atm_iv, 6),
        "active_chain_source":            "tastytrade",
        "symbol_snapshot":                symbol_snapshot,
        "metadata": {
            "chain_fetched_at":   time.time(),
            "contract_count":     len(contracts),
            "expiration_count":   len(expirations_sorted),
            "strike_count":       len(strikes_sorted),
            "source":             "tastytrade",
        },
        "quote_raw": {
            symbol_upper: {
                "quote": {
                    "lastPrice":  underlying_price,
                    "mark":       underlying_price,
                }
            }
        },
    }

'@
WF "backend\tasty_chain_adapter.py" $c

$c = @'
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

'@
WF "backend\cache_manager.py" $c

$c = @'
from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Dict, List, Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv()

from cache_manager import ensure_symbol_loaded, get_symbol_state, list_cached_symbols, manual_refresh_symbol
from data_store import store
from field_registry import ENTRY_STRATEGIES, SCANNER_FIELDS, VALID_SORT_KEYS
from limit_engine import compute_limit_summary, compute_selected_totals
from notify import send_pushover
from positions import normalize_mock_positions
from refresh_scheduler import start_scheduler
from scanner import generate_risk_equivalent_candidates
# source_router removed - tastytrade is the only chain source
from tasty_adapter import extract_net_liq, fetch_account_snapshot, normalize_live_positions
from vol_surface import build_vol_surface_payload

log = logging.getLogger("main")

app = FastAPI(title="Granite Trader", version="1.3.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ?? Pydantic models ??????????????????????????????????????????????????????????

class SelectedRowsPayload(BaseModel):
    rows: List[Dict[str, Any]]

class AlertPayload(BaseModel):
    title: str
    message: str
    notify_whatsapp: bool = False

class StreamSubscribePayload(BaseModel):
    symbols:  List[str] = []
    period:   Optional[str] = "5y"   # candle timeframe

class GreeksSubscribePayload(BaseModel):
    option_symbols: List[str] = []


# ?? Helpers ??????????????????????????????????????????????????????????????????

def _parse_expirations(expiration: str) -> Optional[List[str]]:
    exp = (expiration or "all").strip().lower()
    return None if exp == "all" else [expiration.strip()]


# ?? Startup ??????????????????????????????????????????????????????????????????

@app.on_event("startup")
def on_startup() -> None:
    # Existing REST-based scheduler (chain refresh, archiving)
    start_scheduler()

    # DXLink streaming ? start in background, non-fatal if token unavailable
    try:
        from dx_streamer import start_dx_streamer
        start_dx_streamer()
        log.info("DXLink streamer started")
    except Exception as exc:
        log.warning(f"DXLink streamer could not start: {exc}")

    # Account streamer
    try:
        from account_streamer import start_account_streamer
        start_account_streamer()
        log.info("Account streamer started")
    except Exception as exc:
        log.warning(f"Account streamer could not start: {exc}")


# ?? Health ???????????????????????????????????????????????????????????????????

@app.get("/health")
def health() -> Dict[str, Any]:
    try:
        from dx_streamer import streamer_is_connected
        dx_connected = streamer_is_connected()
    except Exception:
        dx_connected = False

    return {
        "status": "ok",
        "active_chain_source": "tastytrade",
        "cached_symbols": list_cached_symbols(),
        "dxlink_connected": dx_connected,
    }


# ?? WebSocket stream endpoint ?????????????????????????????????????????????????
# React connects here and receives all DXLink + Account Streamer events
# as JSON messages on a single persistent WebSocket connection.

@app.websocket("/ws/stream")
async def ws_stream(websocket: WebSocket) -> None:
    await websocket.accept()
    q: asyncio.Queue = asyncio.Queue(maxsize=500)

    try:
        from dx_streamer import add_ws_client, remove_ws_client
        add_ws_client(q)
    except Exception:
        pass

    # Send connection ack
    await websocket.send_text(json.dumps({
        "type": "connected",
        "message": "Granite Trader stream active",
    }))

    try:
        while True:
            # Forward queued events to React (non-blocking get with timeout)
            try:
                event = await asyncio.wait_for(q.get(), timeout=15.0)
                await websocket.send_text(json.dumps(event))
            except asyncio.TimeoutError:
                # Send ping to keep connection alive
                await websocket.send_text(json.dumps({"type": "ping"}))
    except (WebSocketDisconnect, Exception):
        pass
    finally:
        try:
            from dx_streamer import remove_ws_client
            remove_ws_client(q)
        except Exception:
            pass


# ?? Streaming subscription endpoints ?????????????????????????????????????????

@app.post("/stream/subscribe/quotes")
def subscribe_quotes(payload: StreamSubscribePayload) -> Dict[str, Any]:
    """Subscribe to live Quote/Trade/Summary for the given symbols."""
    try:
        from dx_streamer import streamer_subscribe_quotes
        streamer_subscribe_quotes(payload.symbols)
        return {"ok": True, "symbols": payload.symbols}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/stream/subscribe/candles")
def subscribe_candles(payload: StreamSubscribePayload) -> Dict[str, Any]:
    """Subscribe to Candle events for symbol at given period."""
    try:
        from dx_streamer import streamer_subscribe_candles
        for sym in payload.symbols:
            streamer_subscribe_candles(sym, payload.period or "5y")
        return {"ok": True, "symbols": payload.symbols, "period": payload.period}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/stream/subscribe/greeks")
def subscribe_greeks(payload: GreeksSubscribePayload) -> Dict[str, Any]:
    """Subscribe to Greeks events for option streamer-symbols."""
    try:
        from dx_streamer import streamer_subscribe_greeks
        streamer_subscribe_greeks(payload.option_symbols)
        return {"ok": True, "option_symbols": payload.option_symbols}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/stream/candles")
def get_candles(
    symbol: str = Query(..., min_length=1),
    period: str = Query("5y"),
) -> Dict[str, Any]:
    """
    Return cached candles from the DXLink stream.
    Falls back to Schwab REST if stream has no data yet.
    """
    try:
        from dx_streamer import streamer_get_candles, streamer_is_connected
        candles = streamer_get_candles(symbol, period)
        if candles:
            return {
                "symbol":    symbol.upper(),
                "period":    period,
                "source":    "dxlink",
                "count":     len(candles),
                "candles":   candles,
            }
    except Exception:
        pass

    # Schwab REST fallback
    try:
        from chart_adapter import get_price_history
        return get_price_history(symbol=symbol, period=period)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/stream/status")
def stream_status() -> Dict[str, Any]:
    """Return status of both streaming connections."""
    try:
        from dx_streamer import streamer_is_connected, _streamer
        dx_ok = streamer_is_connected()
        quote_syms  = list(getattr(_streamer, "_quote_syms",  set()))
        candle_syms = list(getattr(_streamer, "_candle_subs", {}).keys())
        greek_syms  = list(getattr(_streamer, "_greeks_syms", set()))
    except Exception:
        dx_ok = False
        quote_syms = candle_syms = greek_syms = []

    return {
        "dxlink":         {"connected": dx_ok, "quote_symbols": quote_syms,
                           "candle_symbols": candle_syms, "greek_symbols": greek_syms},
        "live_quotes":    list(store.get_all_live_quotes().keys()),
        "live_greeks":    list(store.get_all_option_greeks().keys()),
        "account_balance": store.get_live_balance(),
    }


# ?? Account / Positions ???????????????????????????????????????????????????????

@app.get("/account/mock")
def account_mock() -> Dict[str, Any]:
    positions = normalize_mock_positions()
    return {"source": "mock", "positions": positions,
            "limit_summary": compute_limit_summary(72.0, positions)}

@app.get("/account/tasty")
def account_tasty() -> Dict[str, Any]:
    try:
        snapshot  = fetch_account_snapshot()
        positions = normalize_live_positions(snapshot)
        net_liq   = extract_net_liq(snapshot)
        # Use live balance from account streamer if available and fresher
        live_bal = store.get_live_balance()
        if live_bal.get("net_liq"):
            net_liq = live_bal["net_liq"]
        return {"source": "tasty", "positions": positions,
                "limit_summary": compute_limit_summary(net_liq, positions)}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.post("/totals")
def totals(payload: SelectedRowsPayload) -> Dict[str, Any]:
    return compute_selected_totals(payload.rows)


# ?? Cache ?????????????????????????????????????????????????????????????????????

@app.get("/cache/status")
def cache_status() -> Dict[str, Any]:
    syms = list_cached_symbols()
    return {"symbols": syms, "count": len(syms),
            "active_chain_source": "tastytrade"}

@app.get("/refresh/symbol")
def refresh_symbol(symbol: str = Query(..., min_length=1),
                   strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = manual_refresh_symbol(symbol=symbol, strike_count=strike_count)
        return {"symbol": symbol.upper(),
                "active_chain_source": state.get("active_chain_source"),
                "contract_count": len(state.get("contracts", [])),
                "expirations": state.get("expirations", []),
                "updated_at_epoch": state.get("updated_at_epoch")}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Quote ?????????????????????????????????????????????????????????????????????

@app.get("/quote/live_chain")
def quote_schwab(symbol: str = Query(..., min_length=1),
                 strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = ensure_symbol_loaded(symbol=symbol, strike_count=strike_count,
                                     requested_by="quote")
        quote_raw = state.get("quote_raw", {})

        # Overlay live DXLink data if available
        live = store.get_live_quote(symbol)
        if live and quote_raw:
            sym_key = symbol.upper()
            inner   = quote_raw.get(sym_key, {})
            q       = inner.get("quote", inner)
            if live.get("live_last"):
                q["lastPrice"] = live["live_last"]
            if live.get("live_bid"):
                q["bidPrice"] = live["live_bid"]
            if live.get("live_ask"):
                q["askPrice"] = live["live_ask"]

        if not quote_raw:
            raise RuntimeError(f"No quote for {symbol.upper()}")
        return quote_raw
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/quote/live")
def quote_live(symbol: str = Query(..., min_length=1)) -> Dict[str, Any]:
    """Return the latest live DXLink quote for a symbol."""
    q = store.get_live_quote(symbol)
    if q:
        return {"symbol": symbol.upper(), "source": "dxlink", **q}
    # Fall back to Schwab price
    price = store.get_live_price(symbol)
    return {"symbol": symbol.upper(), "source": "schwab_cache", "live_last": price}


# ?? Chain ?????????????????????????????????????????????????????????????????????

@app.get("/chain")
def chain(symbol: str = Query(..., min_length=1),
          strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = ensure_symbol_loaded(symbol=symbol, strike_count=strike_count,
                                     requested_by="chain")
        return {"symbol": state.get("symbol", symbol.upper()),
                "underlying_price": state.get("underlying_price"),
                "count": len(state.get("contracts", [])),
                "expirations": state.get("expirations", []),
                "strikes": state.get("strikes", []),
                "items": state.get("contracts", []),
                "active_chain_source": state.get("active_chain_source"),
                "symbol_snapshot": state.get("symbol_snapshot", {})}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Vol surface ???????????????????????????????????????????????????????????????

@app.get("/vol/surface")
def vol_surface(symbol: str = Query(..., min_length=1),
                max_expirations: int = Query(7, ge=1, le=20),
                strike_count: int = Query(25, ge=5, le=101)) -> Dict[str, Any]:
    try:
        return build_vol_surface_payload(symbol=symbol,
                                         max_expirations=max_expirations,
                                         strike_count=strike_count)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Scanner ???????????????????????????????????????????????????????????????????

@app.get("/scan")
def scan_legacy(symbol: str = Query("SPY"), total_risk: float = Query(600.0, gt=0),
                side: str = Query("all"), expiration: str = Query("all"),
                sort_by: str = Query("credit_pct_risk"),
                strike_count: int = Query(200, ge=25, le=500),
                max_results: int = Query(500, ge=1, le=2000)) -> Dict[str, Any]:
    return scan_live(symbol=symbol, total_risk=total_risk, side=side,
                     expiration=expiration, sort_by=sort_by,
                     strike_count=strike_count, max_results=max_results)

@app.get("/scan/live")
def scan_live(symbol: str = Query(..., min_length=1),
              total_risk: float = Query(600.0, gt=0),
              side: str = Query("all"), expiration: str = Query("all"),
              sort_by: str = Query("credit_pct_risk"),
              strike_count: int = Query(200, ge=25, le=500),
              max_results: int = Query(500, ge=1, le=2000)) -> Dict[str, Any]:
    side = side.lower().strip()
    if side not in {"all", "call", "put"}:
        raise HTTPException(status_code=400, detail="side must be all, call, or put")
    sort_by = sort_by.strip().lower()
    if sort_by not in VALID_SORT_KEYS:
        raise HTTPException(status_code=400,
                            detail=f"sort_by must be one of: {', '.join(sorted(VALID_SORT_KEYS))}")
    try:
        items = generate_risk_equivalent_candidates(
            symbol=symbol, total_risk=total_risk,
            expirations=_parse_expirations(expiration),
            side_filter=side, pricing_mode="conservative_mid",
            strike_count=strike_count, ranking=sort_by, max_results=max_results)
        s = get_symbol_state(symbol)
        return {"symbol": symbol.upper(), "total_risk": round(total_risk, 2),
                "side": side, "count": len(items), "items": items,
                "active_chain_source": s.get("active_chain_source"),
                "symbol_snapshot": s.get("symbol_snapshot", {})}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Chart history (REST fallback when DXLink not connected) ???????????????????

@app.get("/chart/history")
def chart_history(symbol: str = Query(..., min_length=1),
                  period: str = Query("5y"),
                  frequency: str = Query("daily")) -> Dict[str, Any]:
    """
    REST chart history via Schwab.
    React tries /stream/candles first (DXLink) then falls back here.
    """
    try:
        from chart_adapter import get_price_history
        return get_price_history(symbol=symbol, period=period, frequency=frequency)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ?? Field registry ????????????????????????????????????????????????????????????

@app.get("/field-registry")
def field_registry() -> Dict[str, Any]:
    return {"entry_strategies": ENTRY_STRATEGIES, "scanner_fields": SCANNER_FIELDS,
            "valid_sort_keys": sorted(VALID_SORT_KEYS)}


# ?? Alerts / Notifications ????????????????????????????????????????????????????

@app.post("/alerts/send")
def alerts_send(payload: AlertPayload) -> Dict[str, Any]:
    return {"desktop": True, "pushover": send_pushover(payload.message, payload.title)}

@app.post("/alerts/pushover")
def alerts_pushover(payload: AlertPayload) -> Dict[str, Any]:
    return send_pushover(payload.message, payload.title)

'@
WF "backend\main.py" $c

Write-Host "" 
Write-Host "Schwab removed. Stack is now:" -ForegroundColor Green
Write-Host "  tastytrade  -> account + positions + option chains" -ForegroundColor Cyan
Write-Host "  DXLink      -> live quotes + candles + Greeks (streaming)" -ForegroundColor Cyan
Write-Host ""
Write-Host "Restart backend in your WSL window (Ctrl+C then):" -ForegroundColor Yellow
Write-Host "  uvicorn main:app --port 8000" -ForegroundColor White
Write-Host ""
Write-Host "Test chain fetch:" -ForegroundColor Yellow
Write-Host "  curl http://localhost:8000/chain?symbol=SPY" -ForegroundColor White
Write-Host "  curl http://localhost:8000/scan/live?symbol=SPY^&total_risk=1000" -ForegroundColor White
