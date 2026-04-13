from __future__ import annotations

from typing import Any, Dict, List, Optional

from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv()

from limit_engine import compute_limit_summary, compute_selected_totals
from notify import send_whatsapp_message
from positions import normalize_mock_positions
from scanner import generate_risk_equivalent_candidates
from schwab_adapter import get_flat_option_chain, get_quote
from tasty_adapter import extract_net_liq, fetch_account_snapshot, normalize_live_positions
from vol_surface import build_vol_surface_payload

app = FastAPI(title="Granite Trader V0.2")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


class SelectedRowsPayload(BaseModel):
    rows: List[Dict[str, Any]]


class AlertPayload(BaseModel):
    title: str
    message: str
    notify_whatsapp: bool = False


def _parse_expirations(expiration: str) -> Optional[List[str]]:
    exp = (expiration or "all").strip().lower()
    if exp == "all":
        return None
    return [expiration]


@app.get("/health")
def health() -> Dict[str, str]:
    return {"status": "ok"}


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


@app.get("/quote/schwab")
def quote_schwab(symbol: str = Query(..., min_length=1)) -> Dict[str, Any]:
    try:
        return get_quote(symbol)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/chain")
def chain(
    symbol: str = Query(..., min_length=1),
    strike_count: int = Query(25, ge=5, le=200),
) -> Dict[str, Any]:
    try:
        flat = get_flat_option_chain(symbol=symbol, strike_count=strike_count)
        return {
            "symbol": flat["symbol"],
            "underlying_price": flat["underlying_price"],
            "count": len(flat["contracts"]),
            "expirations": flat["expirations"],
            "strikes": flat["strikes"],
            "items": flat["contracts"],
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/scan")
def scan_legacy(
    symbol: str = Query("SPY"),
    total_risk: float = Query(600.0, gt=0),
    side: str = Query("all"),
    expiration: str = Query("all"),
    sort_by: str = Query("credit_pct_risk"),
    strike_count: int = Query(25, ge=5, le=200),
    max_results: int = Query(100, ge=1, le=1000),
) -> Dict[str, Any]:
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
    strike_count: int = Query(25, ge=5, le=200),
    max_results: int = Query(100, ge=1, le=1000),
) -> Dict[str, Any]:
    side = side.lower().strip()
    if side not in {"all", "call", "put"}:
        raise HTTPException(status_code=400, detail="side must be all, call, or put")

    sort_by = sort_by.strip().lower()
    valid_sort = {"credit", "credit_pct_risk", "limit_impact", "richness"}
    if sort_by not in valid_sort:
        raise HTTPException(
            status_code=400,
            detail=f"sort_by must be one of: {', '.join(sorted(valid_sort))}",
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
        return {
            "symbol": symbol.upper(),
            "total_risk": round(total_risk, 2),
            "side": side,
            "expiration_filter": expirations,
            "sort_by": sort_by,
            "pricing_mode": "conservative_mid",
            "count": len(items),
            "items": items,
        }
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.get("/vol/surface")
def vol_surface(
    symbol: str = Query(..., min_length=1),
    max_expirations: int = Query(7, ge=1, le=20),
    strike_count: int = Query(21, ge=5, le=101),
) -> Dict[str, Any]:
    try:
        return build_vol_surface_payload(
            symbol=symbol,
            max_expirations=max_expirations,
            strike_count=strike_count,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/alerts/send")
def alerts_send(payload: AlertPayload) -> Dict[str, Any]:
    result: Dict[str, Any] = {"desktop": True, "whatsapp": None}
    if payload.notify_whatsapp:
        result["whatsapp"] = send_whatsapp_message(f"{payload.title}\n{payload.message}")
    return result