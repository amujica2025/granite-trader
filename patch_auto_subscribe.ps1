param([string]$Root = "C:\\Users\\alexm\\granite_trader")
$ErrorActionPreference = "Stop"
$p = Join-Path $Root "backend\\main.py"
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

    # Auto-subscribe core symbols to DXLink on startup
    import threading
    def _auto_subscribe():
        import time
        time.sleep(5)  # wait for DXLink handshake to complete
        try:
            from dx_streamer import streamer_subscribe_quotes, streamer_subscribe_candles
            core = ["SPY", "QQQ", "GLD", "IWM", "VIX"]
            streamer_subscribe_quotes(core)
            streamer_subscribe_candles("SPY", "20y")
            log.info(f"Auto-subscribed core symbols: {core}")
        except Exception as exc:
            log.warning(f"Auto-subscribe failed: {exc}")
    threading.Thread(target=_auto_subscribe, daemon=True).start()


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


@app.get("/quote/schwab")
def quote_schwab_alias(symbol: str = Query(..., min_length=1)) -> Dict[str, Any]:
    """
    Backwards-compat alias. Returns Schwab-format response so the
    existing React parser (which looks for q.lastPrice, q.bidPrice etc) works.
    Sourced from DXLink live data.
    """
    live = store.get_live_quote(symbol.upper())
    last  = live.get("live_last")  or store.get_live_price(symbol) or 0
    bid   = live.get("live_bid",   0)
    ask   = live.get("live_ask",   0)
    open_ = live.get("live_open",  0)
    high  = live.get("live_high",  0)
    low   = live.get("live_low",   0)
    prev  = live.get("live_prev_close", 0)
    chg   = round(last - prev, 4) if last and prev else 0
    pct   = round(chg / prev, 6)  if prev else 0
    sym   = symbol.upper()
    return {
        sym: {
            "quote": {
                "lastPrice":   last,
                "mark":        last,
                "bidPrice":    bid,
                "askPrice":    ask,
                "openPrice":   open_,
                "highPrice":   high,
                "lowPrice":    low,
                "closePrice":  prev,
                "netChange":   chg,
                "netPercent":  pct,
                "activeSource": "dxlink",
            }
        }
    }


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
[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "[OK] main.py - auto-subscribe SPY on startup" -ForegroundColor Green
Write-Host "uvicorn auto-reloads in 2-3 seconds" -ForegroundColor Cyan
Write-Host "Wait 10 seconds then refresh browser" -ForegroundColor Yellow
