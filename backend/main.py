from __future__ import annotations

from typing import Any, Dict, List, Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv()

# --- local modules (import AFTER load_dotenv so env vars are present) ---
from cache_manager import (
    ensure_symbol_loaded,
    get_symbol_state,
    list_cached_symbols,
    manual_refresh_symbol,
)
from field_registry import ENTRY_STRATEGIES, SCANNER_FIELDS, VALID_SORT_KEYS
from limit_engine import compute_limit_summary, compute_selected_totals
from notify import send_whatsapp_message
from positions import normalize_mock_positions
from refresh_scheduler import start_scheduler
from scanner import generate_risk_equivalent_candidates
from source_router import get_active_chain_source
from tasty_adapter import extract_net_liq, fetch_account_snapshot, normalize_live_positions
from vol_surface import build_vol_surface_payload

# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(title="Granite Trader", version="0.3.0")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Pydantic models
# ---------------------------------------------------------------------------

class SelectedRowsPayload(BaseModel):
    rows: List[Dict[str, Any]]


class AlertPayload(BaseModel):
    title: str
    message: str
    notify_whatsapp: bool = False


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _parse_expirations(expiration: str) -> Optional[List[str]]:
    exp = (expiration or "all").strip().lower()
    if exp == "all":
        return None
    return [expiration.strip()]


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

@app.on_event("startup")
def on_startup() -> None:
    start_scheduler()


# ---------------------------------------------------------------------------
# Health
# ---------------------------------------------------------------------------

@app.get("/health")
def health() -> Dict[str, Any]:
    return {
        "status": "ok",
        "active_chain_source": get_active_chain_source(),
        "cached_symbols": list_cached_symbols(),
    }


# ---------------------------------------------------------------------------
# Account / positions
# ---------------------------------------------------------------------------

@app.get("/account/mock")
def account_mock() -> Dict[str, Any]:
    positions = normalize_mock_positions()
    limit_summary = compute_limit_summary(72.0, positions)
    return {"source": "mock", "positions": positions, "limit_summary": limit_summary}


@app.get("/account/tasty")
def account_tasty() -> Dict[str, Any]:
    try:
        snapshot = fetch_account_snapshot()
        positions = normalize_live_positions(snapshot)
        net_liq = extract_net_liq(snapshot)
        limit_summary = compute_limit_summary(net_liq, positions)
        return {"source": "tasty", "positions": positions, "limit_summary": limit_summary}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/totals")
def totals(payload: SelectedRowsPayload) -> Dict[str, Any]:
    return compute_selected_totals(payload.rows)


# ---------------------------------------------------------------------------
# Cache / data management
# ---------------------------------------------------------------------------

@app.get("/cache/status")
def cache_status() -> Dict[str, Any]:
    symbols = list_cached_symbols()
    return {
        "symbols": symbols,
        "count": len(symbols),
        "active_chain_source": get_active_chain_source(),
    }


@app.get("/refresh/symbol")
def refresh_symbol(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(200, ge=25, le=500),
) -> Dict[str, Any]:
    """Force-refresh the chain cache for one symbol regardless of freshness."""
    try:
        state = manual_refresh_symbol(symbol=symbol, strike_count=strike_count)
        return {
            "symbol": symbol.upper(),
            "active_chain_source": state.get("active_chain_source"),
            "quote_source": state.get("quote_source"),
            "contract_count": len(state.get("contracts", [])),
            "expirations": state.get("expirations", []),
            "updated_at_epoch": state.get("updated_at_epoch"),
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Quote
# ---------------------------------------------------------------------------

@app.get("/quote/schwab")
def quote_schwab(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(200, ge=25, le=500),
) -> Dict[str, Any]:
    """
    Trigger symbol load (caches chain for next 5 min) and return the raw Schwab quote.
    Downstream: scanner + vol surface will read from the same cached payload.
    """
    try:
        state = ensure_symbol_loaded(
            symbol=symbol, strike_count=strike_count, requested_by="quote"
        )
        quote_raw = state.get("quote_raw", {})
        if not quote_raw:
            raise RuntimeError(f"No quote payload available for {symbol.upper()}")
        return quote_raw
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Chain data
# ---------------------------------------------------------------------------

@app.get("/chain")
def chain(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(200, ge=25, le=500),
) -> Dict[str, Any]:
    """Return the cached normalized chain contracts for a symbol."""
    try:
        state = ensure_symbol_loaded(
            symbol=symbol, strike_count=strike_count, requested_by="chain"
        )
        return {
            "symbol": state.get("symbol", symbol.upper()),
            "underlying_price": state.get("underlying_price"),
            "count": len(state.get("contracts", [])),
            "expirations": state.get("expirations", []),
            "strikes": state.get("strikes", []),
            "items": state.get("contracts", []),
            "active_chain_source": state.get("active_chain_source"),
            "symbol_snapshot": state.get("symbol_snapshot", {}),
            "metadata": state.get("metadata", {}),
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/symbol/snapshot")
def symbol_snapshot(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(200, ge=25, le=500),
) -> Dict[str, Any]:
    """Return watchlist-style derived fields for a symbol."""
    try:
        state = ensure_symbol_loaded(
            symbol=symbol, strike_count=strike_count, requested_by="symbol_snapshot"
        )
        return {
            "symbol": state.get("symbol", symbol.upper()),
            "quote_snapshot": state.get("quote_snapshot", {}),
            "symbol_snapshot": state.get("symbol_snapshot", {}),
            "active_chain_source": state.get("active_chain_source"),
            "metadata": state.get("metadata", {}),
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Volatility surface
# ---------------------------------------------------------------------------

@app.get("/vol/surface")
def vol_surface(
    symbol: str = Query(..., min_length=1),
    max_expirations: int = Query(7, ge=1, le=20),
    strike_count: int = Query(21, ge=5, le=101),
) -> Dict[str, Any]:
    """
    IV surface for the nearest `max_expirations` expirations.
    Reads from the shared cache â€” no extra chain request.
    Includes separate call_iv_matrix, put_iv_matrix, skew_matrix.
    """
    try:
        return build_vol_surface_payload(
            symbol=symbol,
            max_expirations=max_expirations,
            strike_count=strike_count,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Scanner
# ---------------------------------------------------------------------------

@app.get("/scan")
def scan_legacy(
    symbol: str = Query("SPY"),
    total_risk: float = Query(600.0, gt=0),
    side: str = Query("all"),
    expiration: str = Query("all"),
    sort_by: str = Query("credit_pct_risk"),
    strike_count: int = Query(200, ge=25, le=500),
    max_results: int = Query(100, ge=1, le=1000),
) -> Dict[str, Any]:
    """Backward-compat alias â†’ /scan/live."""
    return scan_live(
        symbol=symbol,
        total_risk=total_risk,
        side=side,
        expiration=expiration,
        sort_by=sort_by,
        strike_count=strike_count,
        max_results=max_results,
    )


@app.get("/scan/live")
def scan_live(
    symbol: str = Query(..., min_length=1),
    total_risk: float = Query(600.0, gt=0),
    side: str = Query("all"),
    expiration: str = Query("all"),
    sort_by: str = Query("credit_pct_risk"),
    strike_count: int = Query(200, ge=25, le=500),
    max_results: int = Query(100, ge=1, le=1000),
) -> Dict[str, Any]:
    """
    Live credit-spread scanner.

    Reads from the shared cache â€” a /quote/schwab or /refresh/symbol call for the
    same symbol populates (or refreshes) the cache.  The auto-scheduler also
    refreshes every 5 minutes during market hours.

    sort_by: credit | credit_pct_risk | limit_impact | max_loss | richness
    """
    side = side.lower().strip()
    if side not in {"all", "call", "put"}:
        raise HTTPException(status_code=400, detail="side must be all, call, or put")

    sort_by = sort_by.strip().lower()
    if sort_by not in VALID_SORT_KEYS:
        raise HTTPException(
            status_code=400,
            detail=f"sort_by must be one of: {', '.join(sorted(VALID_SORT_KEYS))}",
        )

    expirations = _parse_expirations(expiration)

    try:
        items = generate_risk_equivalent_candidates(
            symbol=symbol,
            total_risk=total_risk,
            expirations=expirations,
            side_filter=side,
            pricing_mode="conservative_mid",
            strike_count=strike_count,
            ranking=sort_by,
            max_results=max_results,
        )
        state = get_symbol_state(symbol)
        return {
            "symbol": symbol.upper(),
            "total_risk": round(total_risk, 2),
            "side": side,
            "expiration_filter": expirations,
            "sort_by": sort_by,
            "pricing_mode": "conservative_mid",
            "count": len(items),
            "items": items,
            "active_chain_source": state.get("active_chain_source"),
            "symbol_snapshot": state.get("symbol_snapshot", {}),
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


# ---------------------------------------------------------------------------
# Field registry
# ---------------------------------------------------------------------------

@app.get("/field-registry")
def field_registry() -> Dict[str, Any]:
    return {
        "entry_strategies": ENTRY_STRATEGIES,
        "scanner_fields": SCANNER_FIELDS,
        "valid_sort_keys": sorted(VALID_SORT_KEYS),
    }


# ---------------------------------------------------------------------------
# Alerts
# ---------------------------------------------------------------------------

@app.post("/alerts/send")
def alerts_send(payload: AlertPayload) -> Dict[str, Any]:
    result: Dict[str, Any] = {"desktop": True, "whatsapp": None}
    if payload.notify_whatsapp:
        result["whatsapp"] = send_whatsapp_message(f"{payload.title}\n{payload.message}")
    return result
