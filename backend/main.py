from __future__ import annotations
from typing import Any, Dict, List, Optional
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv()

from cache_manager import ensure_symbol_loaded, get_symbol_state, list_cached_symbols, manual_refresh_symbol
from field_registry import ENTRY_STRATEGIES, SCANNER_FIELDS, VALID_SORT_KEYS
from limit_engine import compute_limit_summary, compute_selected_totals
from notify import send_pushover
from positions import normalize_mock_positions
from refresh_scheduler import start_scheduler
from scanner import generate_risk_equivalent_candidates
from source_router import get_active_chain_source
from tasty_adapter import extract_net_liq, fetch_account_snapshot, normalize_live_positions
from vol_surface import build_vol_surface_payload

app = FastAPI(title="Granite Trader", version="0.5.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

class SelectedRowsPayload(BaseModel):
    rows: List[Dict[str, Any]]

class AlertPayload(BaseModel):
    title: str
    message: str
    notify_whatsapp: bool = False

def _parse_expirations(expiration: str) -> Optional[List[str]]:
    exp = (expiration or "all").strip().lower()
    return None if exp == "all" else [expiration.strip()]

@app.on_event("startup")
def on_startup() -> None:
    start_scheduler()

@app.get("/health")
def health() -> Dict[str, Any]:
    return {"status": "ok", "active_chain_source": get_active_chain_source(), "cached_symbols": list_cached_symbols()}

@app.get("/account/mock")
def account_mock() -> Dict[str, Any]:
    positions = normalize_mock_positions()
    return {"source": "mock", "positions": positions, "limit_summary": compute_limit_summary(72.0, positions)}

@app.get("/account/tasty")
def account_tasty() -> Dict[str, Any]:
    try:
        snapshot = fetch_account_snapshot()
        positions = normalize_live_positions(snapshot)
        net_liq = extract_net_liq(snapshot)
        return {"source": "tasty", "positions": positions, "limit_summary": compute_limit_summary(net_liq, positions)}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.post("/totals")
def totals(payload: SelectedRowsPayload) -> Dict[str, Any]:
    return compute_selected_totals(payload.rows)

@app.get("/cache/status")
def cache_status() -> Dict[str, Any]:
    syms = list_cached_symbols()
    return {"symbols": syms, "count": len(syms), "active_chain_source": get_active_chain_source()}

@app.get("/refresh/symbol")
def refresh_symbol(symbol: str = Query(..., min_length=1), strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = manual_refresh_symbol(symbol=symbol, strike_count=strike_count)
        return {"symbol": symbol.upper(), "active_chain_source": state.get("active_chain_source"),
                "contract_count": len(state.get("contracts", [])), "expirations": state.get("expirations", []),
                "updated_at_epoch": state.get("updated_at_epoch")}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/quote/schwab")
def quote_schwab(symbol: str = Query(..., min_length=1), strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = ensure_symbol_loaded(symbol=symbol, strike_count=strike_count, requested_by="quote")
        quote_raw = state.get("quote_raw", {})
        if not quote_raw:
            raise RuntimeError(f"No quote for {symbol.upper()}")
        return quote_raw
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/chain")
def chain(symbol: str = Query(..., min_length=1), strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = ensure_symbol_loaded(symbol=symbol, strike_count=strike_count, requested_by="chain")
        return {"symbol": state.get("symbol", symbol.upper()), "underlying_price": state.get("underlying_price"),
                "count": len(state.get("contracts", [])), "expirations": state.get("expirations", []),
                "strikes": state.get("strikes", []), "items": state.get("contracts", []),
                "active_chain_source": state.get("active_chain_source"), "symbol_snapshot": state.get("symbol_snapshot", {})}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/vol/surface")
def vol_surface(symbol: str = Query(..., min_length=1), max_expirations: int = Query(7, ge=1, le=20),
                strike_count: int = Query(25, ge=5, le=101)) -> Dict[str, Any]:
    try:
        return build_vol_surface_payload(symbol=symbol, max_expirations=max_expirations, strike_count=strike_count)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/scan")
def scan_legacy(symbol: str = Query("SPY"), total_risk: float = Query(600.0, gt=0),
                side: str = Query("all"), expiration: str = Query("all"),
                sort_by: str = Query("credit_pct_risk"), strike_count: int = Query(200, ge=25, le=500),
                max_results: int = Query(500, ge=1, le=2000)) -> Dict[str, Any]:
    return scan_live(symbol=symbol, total_risk=total_risk, side=side, expiration=expiration,
                     sort_by=sort_by, strike_count=strike_count, max_results=max_results)

@app.get("/scan/live")
def scan_live(symbol: str = Query(..., min_length=1), total_risk: float = Query(600.0, gt=0),
              side: str = Query("all"), expiration: str = Query("all"),
              sort_by: str = Query("credit_pct_risk"), strike_count: int = Query(200, ge=25, le=500),
              max_results: int = Query(500, ge=1, le=2000)) -> Dict[str, Any]:
    side = side.lower().strip()
    if side not in {"all", "call", "put"}:
        raise HTTPException(status_code=400, detail="side must be all, call, or put")
    sort_by = sort_by.strip().lower()
    if sort_by not in VALID_SORT_KEYS:
        raise HTTPException(status_code=400, detail=f"sort_by must be one of: {', '.join(sorted(VALID_SORT_KEYS))}")
    try:
        items = generate_risk_equivalent_candidates(
            symbol=symbol, total_risk=total_risk, expirations=_parse_expirations(expiration),
            side_filter=side, pricing_mode="conservative_mid", strike_count=strike_count,
            ranking=sort_by, max_results=max_results)
        state = get_symbol_state(symbol)
        return {"symbol": symbol.upper(), "total_risk": round(total_risk, 2), "side": side,
                "count": len(items), "items": items,
                "active_chain_source": state.get("active_chain_source"),
                "symbol_snapshot": state.get("symbol_snapshot", {})}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/field-registry")
def field_registry() -> Dict[str, Any]:
    return {"entry_strategies": ENTRY_STRATEGIES, "scanner_fields": SCANNER_FIELDS, "valid_sort_keys": sorted(VALID_SORT_KEYS)}

@app.post("/alerts/send")
def alerts_send(payload: AlertPayload) -> Dict[str, Any]:
    return {"desktop": True, "pushover": send_pushover(payload.message, payload.title)}

@app.post("/alerts/pushover")
def alerts_pushover(payload: AlertPayload) -> Dict[str, Any]:
    return send_pushover(payload.message, payload.title)
