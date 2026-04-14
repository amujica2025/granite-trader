param(
    [switch]$SkipGit,
    [string]$Root = "C:\\Users\\alexm\\granite_trader"
)
$ErrorActionPreference = "Stop"
$BACKEND  = Join-Path $Root "backend"
$FRONTEND = Join-Path $Root "frontend"
function Write-Info([string]$m) { Write-Host "[Granite] $m" -ForegroundColor Cyan }
function Write-OK([string]$m)   { Write-Host "[Granite] $m" -ForegroundColor Green }
if (-not (Test-Path $BACKEND))  { throw "backend/ not found: $BACKEND" }
if (-not (Test-Path $FRONTEND)) { throw "frontend/ not found: $FRONTEND" }
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$bd = Join-Path $Root "_installer_backups\v05_$ts"
New-Item -ItemType Directory -Force -Path $bd | Out-Null
@("backend\\cache_manager.py","backend\\main.py","backend\\notify.py","frontend\\index.html") |
  ForEach-Object { Copy-Item (Join-Path $Root $_) $bd -Force -ErrorAction SilentlyContinue }
Write-Info "Backup: $bd"
function Write-File([string]$rel, [string]$text) {
    $p = Join-Path $Root $rel
    $d = Split-Path $p -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($p,$text,(New-Object System.Text.UTF8Encoding($false)))
    Write-Info "  wrote $rel"
}
$envPath = Join-Path $Root ".env"
if (Test-Path $envPath) {
    $ec = Get-Content $envPath -Raw
    if ($ec -notmatch "PUSHOVER_USER_KEY") {
        Add-Content $envPath "`nPUSHOVER_USER_KEY=uw8mofrtidtoc46hth3v86dymnssyi"
        Add-Content $envPath "PUSHOVER_API_TOKEN=a9sgeqip8nhorgd9mb4r1f1qkcrf4j"
        Write-Info "Added Pushover keys to .env"
    }
}
Write-Info "Installing v0.5 files..."

$c = @'
from __future__ import annotations

import os
import time
from typing import Any, Dict, List

from archive_manager import archive_symbol_state
from barchart_adapter import refresh_symbol_from_barchart
from data_store import store
from market_clock import is_chain_refresh_window
from schwab_adapter import get_quote, refresh_symbol_from_schwab
from source_router import get_active_chain_source

CHAIN_REFRESH_SECONDS = int(os.getenv("CHAIN_REFRESH_SECONDS", "300"))
DEFAULT_STRIKE_COUNT = int(os.getenv("DEFAULT_CHAIN_STRIKE_COUNT", "200"))
DEFAULT_MAX_EXPIRATIONS = int(os.getenv("DEFAULT_MAX_EXPIRATIONS", "7"))


def _state_is_fresh(state: Dict[str, Any], refresh_seconds: int) -> bool:
    last = float(state.get("last_chain_refresh_epoch", 0.0) or 0.0)
    return last > 0 and (time.time() - last) < refresh_seconds


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
    Load/refresh symbol state from the appropriate source.

    Priority order:
    1. Return fresh cache if available (< CHAIN_REFRESH_SECONDS old)
    2. Return stale cache if outside refresh window and Schwab source
    3. Fetch from Schwab (market hours) or Barchart (after hours)
    4. KEY FIX: if Barchart returns no contracts, fall back to Schwab
       This keeps scanner + vol surface alive after market hours until
       actual Barchart chain JSON files are placed in data/barchart/chains/
    """
    symbol_upper = symbol.upper()
    existing = store.get_symbol_state(symbol_upper)
    active_source = get_active_chain_source()

    # Return cached data if fresh
    if not force and existing and _state_is_fresh(existing, CHAIN_REFRESH_SECONDS):
        return existing

    # Outside refresh window + Schwab + have something → hold
    if (
        not force
        and existing
        and not is_chain_refresh_window()
        and active_source == "schwab"
    ):
        return existing

    if active_source == "schwab":
        payload = refresh_symbol_from_schwab(
            symbol=symbol_upper,
            strike_count=strike_count,
            max_expirations=max_expirations,
        )
    else:
        # After-hours Barchart path
        fallback_quote: Dict[str, Any] = {}
        try:
            fallback_quote = get_quote(symbol_upper)
        except Exception:
            fallback_quote = existing.get("quote_raw", {}) if existing else {}

        payload = refresh_symbol_from_barchart(
            symbol=symbol_upper,
            fallback_quote_raw=fallback_quote,
        )

        # FALLBACK: Barchart has no chain JSON → try Schwab anyway
        if not payload.get("contracts"):
            try:
                schwab_payload = refresh_symbol_from_schwab(
                    symbol=symbol_upper,
                    strike_count=strike_count,
                    max_expirations=max_expirations,
                )
                # Merge any Barchart watchlist fields on top of Schwab snapshot
                merged_snap = dict(schwab_payload.get("symbol_snapshot", {}))
                bc_snap = payload.get("symbol_snapshot", {})
                merged_snap.update({k: v for k, v in bc_snap.items() if v is not None})
                schwab_payload["symbol_snapshot"] = merged_snap
                schwab_payload["active_chain_source"] = "schwab_fallback"
                payload = schwab_payload
            except Exception:
                # Schwab also failed — carry over last known contracts if any
                if existing and existing.get("contracts"):
                    payload["contracts"] = existing.get("contracts", [])
                    payload["expirations"] = existing.get("expirations", [])
                    payload["strikes"] = existing.get("strikes", [])
                    payload["underlying_price"] = existing.get("underlying_price")
                    merged_snap = dict(existing.get("symbol_snapshot", {}))
                    merged_snap.update(
                        {k: v for k, v in payload.get("symbol_snapshot", {}).items() if v is not None}
                    )
                    payload["symbol_snapshot"] = merged_snap
                    payload["metadata"] = {
                        **existing.get("metadata", {}),
                        **payload.get("metadata", {}),
                        "using_cached_contracts": True,
                    }

    payload["updated_at_epoch"] = time.time()
    payload["last_chain_refresh_epoch"] = time.time()
    payload["requested_by"] = requested_by
    return store.upsert_symbol_state(symbol_upper, payload)


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
    archived_paths: List[str] = []
    for symbol in list_cached_symbols():
        state = get_symbol_state(symbol)
        if state:
            archived_paths.append(str(archive_symbol_state(state, reason=reason)))
    return archived_paths

'@
Write-File "backend\cache_manager.py" $c

$c = @'
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

'@
Write-File "backend\main.py" $c

$c = @'
from __future__ import annotations
import os
from typing import Any
import requests

PUSHOVER_USER  = os.getenv("PUSHOVER_USER_KEY",  "uw8mofrtidtoc46hth3v86dymnssyi")
PUSHOVER_TOKEN = os.getenv("PUSHOVER_API_TOKEN", "a9sgeqip8nhorgd9mb4r1f1qkcrf4j")
PUSHOVER_URL   = "https://api.pushover.net/1/messages.json"

def send_pushover(message: str, title: str = "Granite Trader") -> dict[str, Any]:
    if not PUSHOVER_USER or not PUSHOVER_TOKEN:
        return {"ok": False, "error": "Pushover credentials not configured"}
    try:
        resp = requests.post(PUSHOVER_URL, data={
            "user": PUSHOVER_USER, "token": PUSHOVER_TOKEN,
            "message": message, "title": title, "sound": "pushover",
        }, timeout=8)
        data = resp.json() if resp.text else {}
        return {"ok": data.get("status") == 1, "pushover": data}
    except Exception as exc:
        return {"ok": False, "error": str(exc)}

def send_whatsapp_message(message: str) -> dict[str, Any]:
    return {"ok": False, "note": "WhatsApp replaced by Pushover"}

'@
Write-File "backend\notify.py" $c

$c = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<title>Granite Trader</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/plotly.js/2.27.1/plotly.min.js"></script>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600&family=Syne:wght@400;600;700;800&display=swap');
:root,[data-theme="slate"]{--bg:#080b10;--bg1:#0d1117;--bg2:#111820;--bg3:#16202c;--border:#1e2d3d;--border2:#253545;--text:#cdd9e5;--muted:#7a92a8;--accent:#58a6ff;--accent2:#3fb950;--warn:#d29922;--danger:#f85149;--gold:#e3b341}
[data-theme="navy"]{--bg:#030814;--bg1:#070d20;--bg2:#0c142c;--bg3:#111c38;--border:#1a2850;--border2:#243464;--text:#ccd4f0;--muted:#6878b0;--accent:#7090ff;--accent2:#3fb950;--warn:#d29922;--danger:#f85149;--gold:#e3b341}
[data-theme="emerald"]{--bg:#060e0a;--bg1:#0b1510;--bg2:#0f1d14;--bg3:#14261a;--border:#1b3024;--border2:#254535;--text:#c8ddd0;--muted:#6a9a7a;--accent:#3fb950;--accent2:#58a6ff;--warn:#d29922;--danger:#f85149;--gold:#e3b341}
[data-theme="amber"]{--bg:#100d04;--bg1:#181408;--bg2:#201c0c;--bg3:#282312;--border:#3d3010;--border2:#524218;--text:#e0d4b0;--muted:#a09060;--accent:#e3b341;--accent2:#3fb950;--warn:#f85149;--danger:#ff6b6b;--gold:#58a6ff}
[data-theme="rose"]{--bg:#100608;--bg1:#180b0e;--bg2:#201015;--bg3:#28151c;--border:#3d1520;--border2:#521e2c;--text:#e0c8cc;--muted:#a07078;--accent:#f85149;--accent2:#3fb950;--warn:#d29922;--danger:#ff4444;--gold:#e3b341}
[data-theme="purple"]{--bg:#0a0810;--bg1:#100c18;--bg2:#161220;--bg3:#1c1828;--border:#2a1e42;--border2:#382856;--text:#d4c8e8;--muted:#8878a8;--accent:#a070f8;--accent2:#3fb950;--warn:#d29922;--danger:#f85149;--gold:#e3b341}
[data-theme="teal"]{--bg:#040e0e;--bg1:#081616;--bg2:#0c1e1e;--bg3:#102626;--border:#1a3434;--border2:#244545;--text:#c0d8d8;--muted:#608888;--accent:#2dd4d4;--accent2:#3fb950;--warn:#d29922;--danger:#f85149;--gold:#e3b341}
[data-theme="mono"]{--bg:#080808;--bg1:#101010;--bg2:#181818;--bg3:#202020;--border:#2a2a2a;--border2:#383838;--text:#d0d0d0;--muted:#707070;--accent:#c0c0c0;--accent2:#a0a0a0;--warn:#909090;--danger:#808080;--gold:#d0d0d0}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:"JetBrains Mono",monospace;font-size:12px;height:100vh;overflow:hidden;display:flex;flex-direction:column}
::-webkit-scrollbar{width:4px;height:4px}::-webkit-scrollbar-track{background:transparent}::-webkit-scrollbar-thumb{background:var(--border2);border-radius:2px}
input,select,button{font-family:inherit}
input[type=text],input[type=number],select{background:var(--bg3);color:var(--text);border:1px solid var(--border2);border-radius:3px;padding:4px 8px;font-size:11px;outline:none;width:100%}
input:focus,select:focus{border-color:var(--accent)}
#topbar{display:flex;align-items:center;gap:5px;padding:0 8px;background:var(--bg1);border-bottom:1px solid var(--border);flex-shrink:0;height:40px;z-index:9999;position:relative}
.brand{font-family:"Syne",sans-serif;font-weight:800;font-size:15px;color:var(--accent);letter-spacing:.08em;margin-right:4px;white-space:nowrap}
.tpill{display:flex;flex-direction:column;padding:2px 8px;background:var(--bg2);border:1px solid var(--border);border-radius:3px;min-width:80px}
.tpill .lbl{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.tpill .val{font-size:11px;font-weight:600}
.ok{color:var(--accent2)!important}.bad{color:var(--danger)!important}.warn{color:var(--warn)!important}.muted{color:var(--muted)!important}.accent{color:var(--accent)!important}
.tbtn{padding:3px 8px;border:1px solid var(--border2);border-radius:3px;background:var(--bg2);color:var(--text);cursor:pointer;font-size:10px;font-weight:600;white-space:nowrap;transition:all .1s}
.tbtn:hover{border-color:var(--accent);color:var(--accent)}.tbtn.active{background:var(--accent);color:var(--bg);border-color:var(--accent)}
.tbtn.sm{padding:2px 6px;font-size:9px}
.theme-dot{width:16px;height:16px;border-radius:3px;cursor:pointer;border:2px solid transparent;transition:all .1s;flex-shrink:0}
.theme-dot.active{border-color:white}.theme-dot:hover{transform:scale(1.15)}
#themePicker{display:flex;align-items:center;gap:3px;padding:0 5px;border-left:1px solid var(--border);border-right:1px solid var(--border);margin:0 3px}
#workspace{flex:1;position:relative;overflow:hidden;background:var(--bg)}
.tile{position:absolute;background:var(--bg1);border:1px solid var(--border);border-radius:5px;display:flex;flex-direction:column;overflow:hidden;box-shadow:0 4px 20px rgba(0,0,0,.5);min-width:160px;min-height:60px}
.tile.focused{border-color:var(--border2);box-shadow:0 6px 30px rgba(0,0,0,.8)}
.tile-hdr{display:flex;align-items:center;gap:5px;padding:4px 7px;background:var(--bg2);border-bottom:1px solid var(--border);cursor:grab;flex-shrink:0;height:26px;user-select:none}
.tile-hdr:active{cursor:grabbing}
.tile-title{font-family:"Syne",sans-serif;font-size:9px;font-weight:700;text-transform:uppercase;letter-spacing:.1em;color:var(--accent);pointer-events:none;white-space:nowrap}
.tile-ctrls{margin-left:auto;display:flex;gap:3px}
.tc-btn{width:12px;height:12px;border-radius:50%;border:none;cursor:pointer;font-size:0;display:flex;align-items:center;justify-content:center}
.tc-btn.min{background:#d29922}.tc-btn.max{background:#3fb950}.tc-btn.rst{background:#f85149}
.tile-body{flex:1;overflow:auto;min-height:0;display:flex;flex-direction:column}
.tile.minimized .tile-body{display:none}
.tile.minimized{height:26px!important}
.rh{position:absolute;bottom:0;right:0;width:12px;height:12px;cursor:nw-resize;background:linear-gradient(135deg,transparent 50%,var(--border2) 50%);border-radius:0 0 4px 0}
table{width:100%;border-collapse:collapse}
th,td{padding:4px 7px;text-align:right;border-bottom:1px solid #0d1620;white-space:nowrap;font-size:11px}
td:first-child,th:first-child{text-align:left}
thead th{position:sticky;top:0;background:#090e18;color:var(--muted);font-size:9px;text-transform:uppercase;letter-spacing:.04em;font-weight:500;z-index:2;cursor:pointer;padding:4px 7px}
thead th:hover{color:var(--text)}
thead th.sa::after{content:" ▲";color:var(--accent)}
thead th.sd::after{content:" ▼";color:var(--accent)}
tbody tr:hover{background:#0d1a28}
.gh td{background:#070d16;color:var(--accent);font-weight:700;font-size:10px;font-family:"Syne",sans-serif;letter-spacing:.03em;padding:3px 7px}
.tbl-wrap{overflow:auto;flex:1}
#wl-filter{width:100%;padding:4px 8px;background:var(--bg2);border:none;border-bottom:1px solid var(--border);font-size:11px;color:var(--text);outline:none}
.wl-compact-body .wl-row{display:grid;grid-template-columns:54px 62px 58px;padding:4px 8px;border-bottom:1px solid #0a1520;cursor:pointer;align-items:center}
.wl-full-body .wl-row{display:grid;padding:4px 6px;border-bottom:1px solid #0a1520;cursor:pointer;align-items:center;gap:2px;
  grid-template-columns:54px 62px 56px 40px 36px 44px 48px 46px 46px 46px 46px 38px 78px 44px 42px 58px 54px 50px}
.wl-row:hover{background:var(--bg3)}.wl-row.active{background:#0d2040;border-left:2px solid var(--accent)}
.wl-sym{font-weight:600;font-size:11px}.wl-num{font-size:10px;text-align:right}
.wl-pos{color:var(--accent2)!important}.wl-neg{color:var(--danger)!important}
.wlh{display:grid;padding:3px 8px;background:#070d16;border-bottom:1px solid var(--border);position:sticky;top:0;z-index:2}
.wlh.c{grid-template-columns:54px 62px 58px}
.wlh.f{grid-template-columns:54px 62px 56px 40px 36px 44px 48px 46px 46px 46px 46px 38px 78px 44px 42px 58px 54px 50px}
.wlh span{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;text-align:right}
.wlh span:first-child{text-align:left}
.ttm-on{color:var(--warn);font-weight:700}.ttm-off{color:var(--border2)}
.scan-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:5px;padding:7px;border-bottom:1px solid var(--border);background:var(--bg1);flex-shrink:0}
.cg label{font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em;display:block;margin-bottom:2px}
.scan-actions{display:flex;gap:5px;padding:5px 7px;border-bottom:1px solid var(--border);flex-shrink:0;align-items:center}
.btn{padding:4px 10px;border-radius:3px;border:1px solid var(--border2);background:var(--bg3);color:var(--text);cursor:pointer;font-size:11px;font-weight:600;transition:all .12s;white-space:nowrap}
.btn:hover{border-color:var(--accent);color:var(--accent)}.btn.primary{background:var(--accent);color:var(--bg);border-color:var(--accent)}.btn.primary:hover{opacity:.85}
.sb{display:inline-block;padding:1px 5px;border-radius:2px;font-size:9px;font-weight:700;letter-spacing:.03em}
.sb.call{background:rgba(63,185,80,.1);color:var(--accent2);border:1px solid var(--accent2)}
.sb.put{background:rgba(248,81,73,.1);color:var(--danger);border:1px solid var(--danger)}
#totalsbar{display:flex;align-items:center;gap:3px;padding:3px 8px;background:var(--bg1);border-top:1px solid var(--border);flex-shrink:0;flex-wrap:wrap;position:relative;z-index:9999}
.tchip{display:flex;flex-direction:column;padding:2px 7px;border:1px solid var(--border);border-radius:3px;background:var(--bg2);min-width:75px}
.tchip .tl{font-size:7px;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.tchip .tv{font-size:11px;font-weight:600}
.mo{position:fixed;inset:0;background:rgba(0,0,0,.75);z-index:99999;display:none;align-items:center;justify-content:center}
.mo.show{display:flex}
.mbox{background:var(--bg1);border:1px solid var(--border2);border-radius:7px;padding:16px;min-width:480px;max-width:620px;max-height:80vh;overflow-y:auto}
.mbox h2{font-family:"Syne",sans-serif;font-size:13px;font-weight:700;color:var(--accent);margin-bottom:12px;text-transform:uppercase;letter-spacing:.08em}
.mclose{float:right;cursor:pointer;color:var(--muted);font-size:18px;line-height:1}.mclose:hover{color:var(--danger)}
.ar{display:flex;align-items:center;gap:6px;padding:5px;background:var(--bg2);border:1px solid var(--border);border-radius:4px;margin-bottom:5px;font-size:11px}
.ar .ad{margin-left:auto;color:var(--muted);cursor:pointer;font-size:13px}.ar .ad:hover{color:var(--danger)}
.adot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.adot.on{background:var(--accent2)}.adot.off{background:var(--border2)}
.vs-tabs{display:flex;gap:3px;padding:5px 7px;border-bottom:1px solid var(--border);flex-shrink:0;background:var(--bg2)}
.rrow{display:flex;gap:5px;padding:5px;flex-wrap:wrap;border-bottom:1px solid var(--border);flex-shrink:0;max-height:80px;overflow-y:auto}
.rcard{padding:4px 7px;background:var(--bg2);border:1px solid var(--border);border-radius:3px;cursor:pointer;min-width:85px}
.rcard:hover{border-color:var(--accent)}
.strat-grid{display:grid;grid-template-columns:1fr 1fr;gap:3px;padding:7px;flex-shrink:0}
.strat-btn{padding:5px;text-align:center;border:1px solid var(--border2);border-radius:3px;cursor:pointer;font-size:10px;color:var(--muted);background:var(--bg2);transition:all .1s}
.strat-btn:hover{border-color:var(--accent);color:var(--accent)}
.strat-btn.active{background:var(--accent);color:var(--bg);border-color:var(--accent);font-weight:700}
.chart-ph{display:flex;flex-direction:column;align-items:center;justify-content:center;flex:1;color:var(--muted);gap:6px}
.error-msg{color:var(--danger);padding:7px;font-size:11px}
.empty-msg{color:var(--muted);padding:16px;text-align:center;font-size:11px}
.spinner{text-align:center;padding:16px;color:var(--muted);font-size:10px}
.log-line{padding:2px 7px;border-bottom:1px solid #0a1520;font-size:10px;color:var(--muted)}
.log-line .ts{color:var(--border2)}.log-line .msg{color:var(--text)}
</style>
</head>
<body>
<div id="topbar">
  <span class="brand">⬡ GRANITE</span>
  <div class="tpill"><span class="lbl">Net Liq</span><span class="val" id="m-netliq">—</span></div>
  <div class="tpill"><span class="lbl">Limit×25</span><span class="val" id="m-limit">—</span></div>
  <div class="tpill"><span class="lbl">Used</span><span class="val" id="m-used">—</span></div>
  <div class="tpill"><span class="lbl">Room</span><span class="val" id="m-room">—</span></div>
  <div class="tpill"><span class="lbl">Used%</span><span class="val" id="m-usedpct">—</span></div>
  <div class="tpill"><span class="lbl">Symbol</span><span class="val accent" id="m-sym">—</span></div>
  <div class="tpill"><span class="lbl">Price</span><span class="val" id="m-price">—</span></div>
  <div class="tpill"><span class="lbl">Change</span><span class="val" id="m-chg">—</span></div>
  <div class="tpill"><span class="lbl">Source</span><span class="val" id="m-src">—</span></div>
  <div id="themePicker" title="Color theme">
    <span style="font-size:8px;color:var(--muted);margin-right:3px">SKIN</span>
    <div class="theme-dot active" data-theme="slate"  style="background:#1e2d3d" title="Slate"   onclick="setTheme('slate',this)"></div>
    <div class="theme-dot" data-theme="navy"   style="background:#1a2850" title="Navy"    onclick="setTheme('navy',this)"></div>
    <div class="theme-dot" data-theme="emerald"style="background:#1b3024" title="Emerald" onclick="setTheme('emerald',this)"></div>
    <div class="theme-dot" data-theme="teal"   style="background:#1a3434" title="Teal"    onclick="setTheme('teal',this)"></div>
    <div class="theme-dot" data-theme="amber"  style="background:#3d3010" title="Amber"   onclick="setTheme('amber',this)"></div>
    <div class="theme-dot" data-theme="rose"   style="background:#3d1520" title="Rose"    onclick="setTheme('rose',this)"></div>
    <div class="theme-dot" data-theme="purple" style="background:#2a1e42" title="Purple"  onclick="setTheme('purple',this)"></div>
    <div class="theme-dot" data-theme="mono"   style="background:#2a2a2a" title="Mono"    onclick="setTheme('mono',this)"></div>
  </div>
  <span style="font-size:8px;color:var(--muted)">REFRESH:</span>
  <select id="refreshSel" style="width:80px;padding:2px 5px;font-size:10px" onchange="setAutoRefresh(this.value)">
    <option value="30">30s</option><option value="60">1min</option>
    <option value="120">2min</option><option value="300" selected>5min</option>
    <option value="600">10min</option>
  </select>
  <span id="refreshCD" style="font-size:9px;color:var(--muted);min-width:32px">—</span>
  <button class="tbtn" onclick="fullRefresh()" style="margin-left:4px">↺ NOW</button>
  <button class="tbtn" onclick="showModal('alertModal')">🔔 ALERTS</button>
  <div style="display:flex;gap:2px;margin-left:2px">
    <div class="tbtn active" id="abMock"  onclick="setAcct('mock')">MOCK</div>
    <div class="tbtn" id="abTasty" onclick="setAcct('tasty')">TASTY</div>
  </div>
</div>

<div id="workspace">
  <!-- WATCHLIST -->
  <div class="tile" id="tile-wl">
    <div class="tile-hdr" onmousedown="tileDown(event,'tile-wl')">
      <span class="tile-title">Watchlist</span>
      <button class="tbtn sm" id="wlBtn" onclick="toggleWl()" style="font-size:8px">⇔ EXPAND</button>
      <div class="tile-ctrls">
        <div class="tc-btn min" onclick="toggleMin('tile-wl')"></div>
        <div class="tc-btn rst" onclick="resetPos('tile-wl')"></div>
      </div>
    </div>
    <input id="wl-filter" placeholder="Filter…" oninput="renderWl()"/>
    <div id="wl-hdr-c" class="wlh c">
      <span>SYM</span><span>LAST</span><span>CHG%</span>
    </div>
    <div id="wl-hdr-f" class="wlh f" style="display:none">
      <span>SYM</span><span>LAST</span><span>CHG%</span><span>14D RS</span><span>IVpct</span>
      <span>IV/HV</span><span>ImpVol</span><span>5D IV</span><span>1M IV</span>
      <span>3M IV</span><span>6M IV</span><span>BB%</span><span>BB Rank</span>
      <span>TTM</span><span>14DADR</span><span>OptVol</span><span>CallVol</span><span>PutVol</span>
    </div>
    <div class="tile-body wl-compact-body" id="wl-body"></div>
  </div>

  <!-- POSITIONS -->
  <div class="tile" id="tile-pos">
    <div class="tile-hdr" onmousedown="tileDown(event,'tile-pos')">
      <span class="tile-title">Open Positions</span>
      <div class="tile-ctrls">
        <div class="tc-btn min" onclick="toggleMin('tile-pos')"></div>
        <div class="tc-btn rst" onclick="resetPos('tile-pos')"></div>
      </div>
    </div>
    <div id="posErr" class="error-msg" style="display:none"></div>
    <div class="tile-body tbl-wrap">
      <table>
        <thead><tr id="posHdr">
          <th></th>
          <th data-col="underlying" onclick="srt('pos','underlying')">Sym</th>
          <th data-col="display_qty" onclick="srt('pos','display_qty')">Qty</th>
          <th data-col="option_type" onclick="srt('pos','option_type')">Type</th>
          <th data-col="expiration" onclick="srt('pos','expiration')">Exp</th>
          <th data-col="strike" onclick="srt('pos','strike')">Strike</th>
          <th data-col="mark" onclick="srt('pos','mark')">Mark</th>
          <th data-col="trade_price" onclick="srt('pos','trade_price')">Trade</th>
          <th data-col="pnl_open" onclick="srt('pos','pnl_open')">P/L</th>
          <th data-col="short_value" onclick="srt('pos','short_value')">ShtVal</th>
          <th data-col="long_cost" onclick="srt('pos','long_cost')">LngCost</th>
          <th data-col="limit_impact" onclick="srt('pos','limit_impact')">Impact</th>
        </tr></thead>
        <tbody id="posBody"><tr><td colspan="12" class="empty-msg">—</td></tr></tbody>
      </table>
    </div>
  </div>

  <!-- SCANNER -->
  <div class="tile" id="tile-scan">
    <div class="tile-hdr" onmousedown="tileDown(event,'tile-scan')">
      <span class="tile-title">Entry Scanner</span>
      <div class="tile-ctrls">
        <div class="tc-btn min" onclick="toggleMin('tile-scan')"></div>
        <div class="tc-btn rst" onclick="resetPos('tile-scan')"></div>
      </div>
    </div>
    <div class="scan-grid">
      <div class="cg"><label>Symbol</label><input type="text" id="sSym" value="SPY" style="text-transform:uppercase"/></div>
      <div class="cg"><label>Total Risk $</label><input type="number" id="sRisk" value="600" step="100"/></div>
      <div class="cg"><label>Side</label>
        <select id="sSide"><option value="all">All</option><option value="call">Calls</option><option value="put">Puts</option></select>
      </div>
      <div class="cg"><label>Expiration</label>
        <select id="sExp"><option value="all">All (next 7)</option></select>
      </div>
      <div class="cg"><label>Sort By</label>
        <select id="sSort">
          <option value="credit_pct_risk">Credit % Risk</option>
          <option value="richness">Richness Score</option>
          <option value="credit">Net Credit</option>
          <option value="limit_impact">Limit Impact</option>
          <option value="max_loss">Max Loss</option>
        </select>
      </div>
      <div class="cg"><label>Max Results</label><input type="number" id="sMax" value="500" step="100"/></div>
    </div>
    <div class="scan-actions">
      <button class="btn primary" onclick="runScan()">▶ SCAN</button>
      <button class="btn" onclick="clearScan()">✕</button>
      <button class="btn" style="font-size:10px" onclick="loadChain()" title="Force refresh chain data">↺ CHAIN</button>
      <button class="btn" style="font-size:10px" onclick="loadVolSurface()" title="Load vol surface">⬡ SURFACE</button>
      <span id="scanInfo" class="muted" style="font-size:10px;margin-left:4px;align-self:center"></span>
    </div>
    <div id="scanErr" class="error-msg" style="display:none"></div>
    <div class="tile-body tbl-wrap">
      <table>
        <thead><tr id="scanHdr">
          <th data-col="expiration" onclick="srt('scan','expiration')" title="Expiration date">Exp</th>
          <th data-col="option_side" onclick="srt('scan','option_side')" title="Call or Put">Side</th>
          <th data-col="short_strike" onclick="srt('scan','short_strike')" title="Strike you sell">Short</th>
          <th data-col="long_strike" onclick="srt('scan','long_strike')" title="Strike you buy as protection">Long</th>
          <th data-col="width" onclick="srt('scan','width')" title="Dollar distance between strikes">Wid</th>
          <th data-col="quantity" onclick="srt('scan','quantity')" title="# spreads for your target risk">Qty</th>
          <th data-col="net_credit" onclick="srt('scan','net_credit')" title="Total premium received">Net Cr</th>
          <th data-col="gross_defined_risk" onclick="srt('scan','gross_defined_risk')" title="Width×100×Qty — notional max risk">GrRisk</th>
          <th data-col="max_loss" onclick="srt('scan','max_loss')" title="Actual worst case = GrRisk − NetCr">MaxLoss</th>
          <th data-col="credit_pct_risk" onclick="srt('scan','credit_pct_risk')" title="Net Credit ÷ Gross Risk — primary reward/risk metric">Cr%Risk</th>
          <th data-col="short_delta" onclick="srt('scan','short_delta')" title="Delta of short leg ≈ prob ITM at expiry">Sht Δ</th>
          <th data-col="short_iv" onclick="srt('scan','short_iv')" title="IV of short strike — what you are selling">Sht IV</th>
          <th data-col="richness_score" onclick="srt('scan','richness_score')" title="Composite rank: 70% credit% + 30% IV vs peers in same expiration. 1.0=richest">Score</th>
          <th data-col="limit_impact" onclick="srt('scan','limit_impact')" title="max(Short Value, Long Cost) — tastytrade limit usage">Impact</th>
        </tr></thead>
        <tbody id="scanBody"><tr><td colspan="14" class="empty-msg">Configure filters and press SCAN</td></tr></tbody>
      </table>
    </div>
    <div class="rh" onmousedown="resizeDown(event,'tile-scan')"></div>
  </div>

  <!-- VOL SURFACE -->
  <div class="tile" id="tile-vol">
    <div class="tile-hdr" onmousedown="tileDown(event,'tile-vol')">
      <span class="tile-title">Vol Surface</span>
      <div class="vs-tabs" style="padding:0;border:none;background:transparent;gap:3px;margin-left:4px">
        <button class="tbtn sm active" id="vs-avg"  onclick="vsView('avg')">Avg</button>
        <button class="tbtn sm" id="vs-call" onclick="vsView('call')">Call</button>
        <button class="tbtn sm" id="vs-put"  onclick="vsView('put')">Put</button>
        <button class="tbtn sm" id="vs-skew" onclick="vsView('skew')">Skew</button>
        <button class="tbtn sm" id="vs-3d"   onclick="vsView('3d')">3D ▲</button>
      </div>
      <div class="tile-ctrls">
        <div class="tc-btn min" onclick="toggleMin('tile-vol')"></div>
        <div class="tc-btn rst" onclick="resetPos('tile-vol')"></div>
      </div>
    </div>
    <div id="volRrow" class="rrow"><span class="muted" style="font-size:10px">Load a symbol to populate</span></div>
    <div class="tile-body" id="volBody">
      <div id="volPlot" style="width:100%;height:100%;min-height:250px"></div>
    </div>
    <div class="rh" onmousedown="resizeDown(event,'tile-vol')"></div>
  </div>

  <!-- SELECTED LEGS -->
  <div class="tile" id="tile-sel">
    <div class="tile-hdr" onmousedown="tileDown(event,'tile-sel')">
      <span class="tile-title">Selected Legs</span>
      <div class="tile-ctrls">
        <div class="tc-btn min" onclick="toggleMin('tile-sel')"></div>
        <div class="tc-btn rst" onclick="resetPos('tile-sel')"></div>
      </div>
    </div>
    <div class="tile-body" style="flex-direction:row">
      <div class="tbl-wrap" style="flex:1">
        <table>
          <thead><tr id="selHdr">
            <th data-col="underlying" onclick="srt('sel','underlying')">Sym</th>
            <th data-col="option_type" onclick="srt('sel','option_type')">Type</th>
            <th data-col="display_qty" onclick="srt('sel','display_qty')">Qty</th>
            <th data-col="strike" onclick="srt('sel','strike')">Strike</th>
            <th data-col="expiration" onclick="srt('sel','expiration')">Exp</th>
            <th data-col="mark" onclick="srt('sel','mark')">Mark</th>
            <th data-col="pnl_open" onclick="srt('sel','pnl_open')">P/L</th>
            <th data-col="short_value" onclick="srt('sel','short_value')">ShtVal</th>
          </tr></thead>
          <tbody id="selBody"><tr><td colspan="8" class="empty-msg">Select rows in Open Positions</td></tr></tbody>
        </table>
      </div>
      <div style="width:220px;padding:7px;border-left:1px solid var(--border);flex-shrink:0">
        <div style="font-size:8px;color:var(--muted);text-transform:uppercase;margin-bottom:5px">Selection Totals</div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:3px">
          <div class="tchip"><span class="tl">Legs</span><span class="tv" id="st-legs">0</span></div>
          <div class="tchip"><span class="tl">P/L</span><span class="tv" id="st-pnl">—</span></div>
          <div class="tchip"><span class="tl">Sht Val</span><span class="tv" id="st-sv">—</span></div>
          <div class="tchip"><span class="tl">Lng Cost</span><span class="tv" id="st-lc">—</span></div>
          <div class="tchip" style="grid-column:span 2"><span class="tl">Impact</span><span class="tv" id="st-imp">—</span></div>
        </div>
      </div>
    </div>
  </div>

  <!-- TRADE TICKET -->
  <div class="tile" id="tile-ticket">
    <div class="tile-hdr" onmousedown="tileDown(event,'tile-ticket')">
      <span class="tile-title">Quick Trade Ticket → Tastytrade</span>
      <div class="tile-ctrls">
        <div class="tc-btn min" onclick="toggleMin('tile-ticket')"></div>
        <div class="tc-btn rst" onclick="resetPos('tile-ticket')"></div>
      </div>
    </div>
    <div class="tile-body">
      <div class="strat-grid">
        <div class="strat-btn active" onclick="setStrat(this,'credit_spread')">Credit Spread</div>
        <div class="strat-btn" onclick="setStrat(this,'iron_condor')">Iron Condor</div>
        <div class="strat-btn" onclick="setStrat(this,'butterfly')">Butterfly</div>
        <div class="strat-btn" onclick="setStrat(this,'iron_fly')">Iron Fly</div>
        <div class="strat-btn" onclick="setStrat(this,'strangle')">Strangle</div>
        <div class="strat-btn" onclick="setStrat(this,'straddle')">Straddle</div>
      </div>
      <div style="padding:7px;border-top:1px solid var(--border)">
        <div style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:5px;margin-bottom:5px">
          <div><label style="font-size:8px;color:var(--muted)">Symbol</label><input type="text" id="tt-sym" value="SPY"/></div>
          <div><label style="font-size:8px;color:var(--muted)">Qty</label><input type="number" id="tt-qty" value="1"/></div>
          <div><label style="font-size:8px;color:var(--muted)">Action</label>
            <select id="tt-act"><option>Sell to Open</option><option>Buy to Open</option></select></div>
        </div>
        <button class="btn primary" style="width:100%;font-size:11px" onclick="submitTicket()">SEND TO TASTYTRADE →</button>
        <div id="tt-msg" style="font-size:9px;margin-top:4px;color:var(--muted)">Select a strategy above</div>
      </div>
    </div>
    <div class="rh" onmousedown="resizeDown(event,'tile-ticket')"></div>
  </div>

  <!-- CHART -->
  <div class="tile" id="tile-chart">
    <div class="tile-hdr" onmousedown="tileDown(event,'tile-chart')">
      <span class="tile-title">Chart — TradingView Lightweight (v0.5)</span>
      <div class="tile-ctrls">
        <div class="tc-btn min" onclick="toggleMin('tile-chart')"></div>
        <div class="tc-btn rst" onclick="resetPos('tile-chart')"></div>
      </div>
    </div>
    <div class="tile-body">
      <div class="chart-ph">
        <span style="font-size:28px;opacity:.25">📈</span>
        <p style="font-size:10px;text-align:center;max-width:220px;opacity:.5">Chart integration arrives in v0.5<br/>Target: TradingView Lightweight Charts</p>
      </div>
    </div>
    <div class="rh" onmousedown="resizeDown(event,'tile-chart')"></div>
  </div>
</div>

<div id="totalsbar">
  <span style="font-size:8px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-right:3px">SEL:</span>
  <div class="tchip"><span class="tl">Legs</span><span class="tv" id="tb-legs">0</span></div>
  <div class="tchip"><span class="tl">Sht Val</span><span class="tv" id="tb-sv">—</span></div>
  <div class="tchip"><span class="tl">Lng Cost</span><span class="tv" id="tb-lc">—</span></div>
  <div class="tchip"><span class="tl">P/L Open</span><span class="tv" id="tb-pnl">—</span></div>
  <div class="tchip"><span class="tl">Impact</span><span class="tv" id="tb-imp">—</span></div>
  <div class="tchip" style="margin-left:auto"><span class="tl">Positions</span><span class="tv" id="tb-pos">0</span></div>
  <div class="tchip"><span class="tl">Scan Results</span><span class="tv" id="tb-scan">0</span></div>
  <div class="tchip"><span class="tl">Active Alerts</span><span class="tv" id="tb-alerts">0</span></div>
</div>

<!-- ALERT MODAL -->
<div class="mo" id="alertModal">
  <div class="mbox">
    <span class="mclose" onclick="hideModal('alertModal')">✕</span>
    <h2>🔔 Alert Center</h2>
    <div style="display:grid;grid-template-columns:1fr 1fr 70px 90px auto;gap:5px;margin-bottom:10px;align-items:end">
      <div><label style="font-size:8px;color:var(--muted);display:block;margin-bottom:2px">SYMBOL</label>
        <input type="text" id="al-sym" placeholder="SPY" style="text-transform:uppercase"/></div>
      <div><label style="font-size:8px;color:var(--muted);display:block;margin-bottom:2px">FIELD</label>
        <select id="al-field">
          <option value="price">Price</option>
          <option value="iv_pct">IV%</option>
          <option value="credit_pct_risk">Cr% Risk</option>
          <option value="short_delta">Short Delta</option>
          <option value="used_pct">Used%</option>
          <option value="pnl_open">P/L Open</option>
        </select></div>
      <div><label style="font-size:8px;color:var(--muted);display:block;margin-bottom:2px">OP</label>
        <select id="al-op">
          <option value="lt">&lt;</option><option value="lte">&lt;=</option>
          <option value="eq">=</option><option value="gte">&gt;=</option><option value="gt">&gt;</option>
        </select></div>
      <div><label style="font-size:8px;color:var(--muted);display:block;margin-bottom:2px">VALUE</label>
        <input type="number" id="al-val" placeholder="0.00" step="0.01"/></div>
      <button class="btn primary" onclick="addAlert()" style="height:26px;font-size:10px">+ ADD</button>
    </div>
    <div style="font-size:9px;color:var(--muted);margin-bottom:8px">
      Alert when the <b style="color:var(--accent)">[field]</b> of <b style="color:var(--accent)">[symbol]</b> is <b style="color:var(--accent)">[op]</b> <b style="color:var(--accent)">[value]</b> → Desktop + Pushover
    </div>
    <div id="alertList"><div class="empty-msg">No alerts set</div></div>
    <div style="margin-top:10px;display:flex;gap:8px;align-items:center">
      <label style="display:flex;align-items:center;gap:5px;font-size:11px">
        <input type="checkbox" id="alertMasterChk" checked onchange="alertsMaster=this.checked"/>All alerts active
      </label>
      <button class="btn" style="font-size:10px" onclick="testPushover()">Test Pushover</button>
    </div>
  </div>
</div>

<script>
const API='http://localhost:8000';

const WL_DATA=[{"sym": "ANF", "price": "94.5", "chg": "-3.95%", "rs14": "51.53", "ivpct": "33%", "ivhv": "1.0333209723939", "iv": "50.14%", "iv5d": "50.04%", "iv1m": "52.42%", "iv3m": "59.12%", "iv6m": "57.95%", "bb": "63%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.18", "opvol": "1662", "callvol": "892", "putvol": "770"}, {"sym": "NEM", "price": "116.69", "chg": "-3.48%", "rs14": "56.36", "ivpct": "84%", "ivhv": "1.0898165137615", "iv": "53.83%", "iv5d": "54.02%", "iv1m": "54.56%", "iv3m": "54.56%", "iv6m": "48.93%", "bb": "78%", "bbr": "Above Mid", "ttm": "0", "adr14": "3.88", "opvol": "11214", "callvol": "6579", "putvol": "4635"}, {"sym": "TGT", "price": "118.38", "chg": "-2.88%", "rs14": "49.29", "ivpct": "16%", "ivhv": "1.0824552341598", "iv": "31.25%", "iv5d": "30.87%", "iv1m": "32.35%", "iv3m": "37.82%", "iv6m": "38.36%", "bb": "48%", "bbr": "New Below Mid", "ttm": "0", "adr14": "3.08", "opvol": "17643", "callvol": "9330", "putvol": "8313"}, {"sym": "CIEN", "price": "482.87", "chg": "-2.65%", "rs14": "64.88", "ivpct": "82%", "ivhv": "0.88729005612623", "iv": "83.77%", "iv5d": "84.78%", "iv1m": "83.17%", "iv3m": "85.58%", "iv6m": "75.68%", "bb": "86%", "bbr": "Above Mid", "ttm": "0", "adr14": "31.76", "opvol": "5580", "callvol": "3020", "putvol": "2560"}, {"sym": "BBY", "price": "60.72", "chg": "-2.65%", "rs14": "37.79", "ivpct": "41%", "ivhv": "1.0445828603859", "iv": "36.92%", "iv5d": "38.37%", "iv1m": "40.63%", "iv3m": "44.22%", "iv6m": "41.50%", "bb": "-2%", "bbr": "Below Lower", "ttm": "On", "adr14": "2.2", "opvol": "8752", "callvol": "3576", "putvol": "5176"}, {"sym": "GS", "price": "885.43", "chg": "-2.46%", "rs14": "58.99", "ivpct": "71%", "ivhv": "1.0367895247333", "iv": "31.83%", "iv5d": "34.44%", "iv1m": "39.89%", "iv3m": "35.48%", "iv6m": "32.09%", "bb": "82%", "bbr": "Above Mid", "ttm": "0", "adr14": "22.67", "opvol": "64477", "callvol": "32755", "putvol": "31722"}, {"sym": "DXCM", "price": "62.51", "chg": "-2.36%", "rs14": "38.39", "ivpct": "82%", "ivhv": "1.8577443127203", "iv": "57.72%", "iv5d": "54.61%", "iv1m": "48.56%", "iv3m": "49.24%", "iv6m": "48.02%", "bb": "21%", "bbr": "Below Mid", "ttm": "0", "adr14": "1.99", "opvol": "836", "callvol": "464", "putvol": "372"}, {"sym": "TJX", "price": "158.12", "chg": "-2.15%", "rs14": "49.12", "ivpct": "54%", "ivhv": "1.0395395348837", "iv": "22.21%", "iv5d": "22.29%", "iv1m": "23.53%", "iv3m": "23.64%", "iv6m": "21.90%", "bb": "50%", "bbr": "New Below Mid", "ttm": "0", "adr14": "3.37", "opvol": "8189", "callvol": "7288", "putvol": "901"}, {"sym": "HSY", "price": "198.19", "chg": "-2.04%", "rs14": "34.1", "ivpct": "97%", "ivhv": "1.4709049586777", "iv": "35.62%", "iv5d": "34.03%", "iv1m": "33.39%", "iv3m": "29.93%", "iv6m": "27.69%", "bb": "-8%", "bbr": "Below Lower", "ttm": "0", "adr14": "5.36", "opvol": "666", "callvol": "348", "putvol": "318"}, {"sym": "MDLZ", "price": "57.8", "chg": "-2.03%", "rs14": "48.86", "ivpct": "84%", "ivhv": "1.128270313757", "iv": "28.08%", "iv5d": "28.58%", "iv1m": "28.67%", "iv3m": "25.98%", "iv6m": "25.60%", "bb": "53%", "bbr": "Above Mid", "ttm": "On", "adr14": "1.26", "opvol": "1839", "callvol": "1028", "putvol": "811"}, {"sym": "AMAT", "price": "391.42", "chg": "-2.02%", "rs14": "62.43", "ivpct": "94%", "ivhv": "1.039188855581", "iv": "58.93%", "iv5d": "58.57%", "iv1m": "58.01%", "iv3m": "55.60%", "iv6m": "49.27%", "bb": "90%", "bbr": "New Below Upper", "ttm": "0", "adr14": "14.77", "opvol": "25708", "callvol": "17751", "putvol": "7957"}, {"sym": "KO", "price": "75.93", "chg": "-1.99%", "rs14": "45.86", "ivpct": "92%", "ivhv": "1.3569254467036", "iv": "21.86%", "iv5d": "21.54%", "iv1m": "21.61%", "iv3m": "20.11%", "iv6m": "17.87%", "bb": "42%", "bbr": "New Below Mid", "ttm": "0", "adr14": "1.37", "opvol": "28220", "callvol": "18987", "putvol": "9233"}, {"sym": "NEE", "price": "92.26", "chg": "-1.93%", "rs14": "49.6", "ivpct": "44%", "ivhv": "1.6585444579781", "iv": "26.64%", "iv5d": "26.93%", "iv1m": "28.40%", "iv3m": "26.55%", "iv6m": "26.13%", "bb": "49%", "bbr": "New Below Mid", "ttm": "0", "adr14": "1.66", "opvol": "6792", "callvol": "4293", "putvol": "2499"}, {"sym": "ABBV", "price": "203.93", "chg": "-1.93%", "rs14": "37.05", "ivpct": "95%", "ivhv": "1.3241396800624", "iv": "33.68%", "iv5d": "32.85%", "iv1m": "32.54%", "iv3m": "29.72%", "iv6m": "27.35%", "bb": "16%", "bbr": "Below Mid", "ttm": "0", "adr14": "5.11", "opvol": "10381", "callvol": "7330", "putvol": "3051"}, {"sym": "WMB", "price": "71.44", "chg": "-1.79%", "rs14": "43.41", "ivpct": "73%", "ivhv": "1.5873884657236", "iv": "28.80%", "iv5d": "29.31%", "iv1m": "29.71%", "iv3m": "28.96%", "iv6m": "27.15%", "bb": "1%", "bbr": "Below Mid", "ttm": "On", "adr14": "1.74", "opvol": "1024", "callvol": "693", "putvol": "331"}, {"sym": "CVS", "price": "77.94", "chg": "-1.75%", "rs14": "59.76", "ivpct": "64%", "ivhv": "1.2378265486726", "iv": "34.88%", "iv5d": "34.58%", "iv1m": "38.70%", "iv3m": "35.56%", "iv6m": "32.77%", "bb": "84%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.73", "opvol": "3888", "callvol": "2914", "putvol": "974"}, {"sym": "EQT", "price": "57.66", "chg": "-1.74%", "rs14": "33.7", "ivpct": "53%", "ivhv": "1.3522700941347", "iv": "37.06%", "iv5d": "38.84%", "iv1m": "40.48%", "iv3m": "39.19%", "iv6m": "37.01%", "bb": "5%", "bbr": "Below Mid", "ttm": "0", "adr14": "2.01", "opvol": "18010", "callvol": "2506", "putvol": "15504"}, {"sym": "MRK", "price": "119.31", "chg": "-1.74%", "rs14": "51.38", "ivpct": "64%", "ivhv": "1.5134959349593", "iv": "31.44%", "iv5d": "31.21%", "iv1m": "31.65%", "iv3m": "29.47%", "iv6m": "28.02%", "bb": "58%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.72", "opvol": "6177", "callvol": "2846", "putvol": "3331"}, {"sym": "TMUS", "price": "192.48", "chg": "-1.65%", "rs14": "28.88", "ivpct": "92%", "ivhv": "1.7512248995984", "iv": "34.98%", "iv5d": "34.75%", "iv1m": "32.55%", "iv3m": "32.45%", "iv6m": "29.09%", "bb": "-1%", "bbr": "Below Lower", "ttm": "0", "adr14": "5.05", "opvol": "4329", "callvol": "2306", "putvol": "2023"}, {"sym": "WMT", "price": "124.68", "chg": "-1.65%", "rs14": "50.26", "ivpct": "51%", "ivhv": "1.0788420621931", "iv": "25.68%", "iv5d": "25.81%", "iv1m": "26.97%", "iv3m": "28.76%", "iv6m": "26.33%", "bb": "58%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.69", "opvol": "50339", "callvol": "25459", "putvol": "24880"}, {"sym": "URBN", "price": "67.47", "chg": "-1.65%", "rs14": "57.54", "ivpct": "35%", "ivhv": "1.3466993051169", "iv": "42.72%", "iv5d": "44.19%", "iv1m": "45.27%", "iv3m": "48.93%", "iv6m": "48.67%", "bb": "85%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.25", "opvol": "552", "callvol": "225", "putvol": "327"}, {"sym": "BMY", "price": "57.71", "chg": "-1.55%", "rs14": "43.44", "ivpct": "66%", "ivhv": "1.2451164626925", "iv": "31.90%", "iv5d": "31.10%", "iv1m": "30.54%", "iv3m": "28.56%", "iv6m": "29.60%", "bb": "21%", "bbr": "Below Mid", "ttm": "0", "adr14": "1.28", "opvol": "15374", "callvol": "11488", "putvol": "3886"}, {"sym": "REGN", "price": "738.12", "chg": "-1.44%", "rs14": "43.85", "ivpct": "91%", "ivhv": "1.618067940552", "iv": "45.31%", "iv5d": "44.71%", "iv1m": "41.98%", "iv3m": "38.49%", "iv6m": "36.41%", "bb": "29%", "bbr": "Below Mid", "ttm": "0", "adr14": "17.43", "opvol": "673", "callvol": "262", "putvol": "411"}, {"sym": "SO", "price": "95.78", "chg": "-1.41%", "rs14": "48.24", "ivpct": "92%", "ivhv": "1.4825459496256", "iv": "21.80%", "iv5d": "20.81%", "iv1m": "20.99%", "iv3m": "20.71%", "iv6m": "19.26%", "bb": "41%", "bbr": "New Below Mid", "ttm": "0", "adr14": "1.46", "opvol": "1463", "callvol": "1015", "putvol": "448"}, {"sym": "UAL", "price": "95.06", "chg": "-1.39%", "rs14": "50.23", "ivpct": "83%", "ivhv": "1.1134100185529", "iv": "59.82%", "iv5d": "60.48%", "iv1m": "64.31%", "iv3m": "56.65%", "iv6m": "51.97%", "bb": "72%", "bbr": "Above Mid", "ttm": "On", "adr14": "4.29", "opvol": "12606", "callvol": "5809", "putvol": "6797"}, {"sym": "GNRC", "price": "204.16", "chg": "-1.39%", "rs14": "52.2", "ivpct": "98%", "ivhv": "1.3794363395225", "iv": "62.01%", "iv5d": "61.75%", "iv1m": "57.39%", "iv3m": "54.30%", "iv6m": "49.30%", "bb": "69%", "bbr": "Above Mid", "ttm": "On", "adr14": "9.08", "opvol": "471", "callvol": "303", "putvol": "168"}, {"sym": "MO", "price": "66.49", "chg": "-1.32%", "rs14": "51.11", "ivpct": "95%", "ivhv": "1.4328002183406", "iv": "25.89%", "iv5d": "25.57%", "iv1m": "24.77%", "iv3m": "22.51%", "iv6m": "21.15%", "bb": "61%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.46", "opvol": "8671", "callvol": "5367", "putvol": "3304"}, {"sym": "DAL", "price": "66.94", "chg": "-1.30%", "rs14": "53.15", "ivpct": "44%", "ivhv": "1.0574170902929", "iv": "43.36%", "iv5d": "45.50%", "iv1m": "53.03%", "iv3m": "48.08%", "iv6m": "44.98%", "bb": "66%", "bbr": "Above Mid", "ttm": "On", "adr14": "2.43", "opvol": "46928", "callvol": "29946", "putvol": "16982"}, {"sym": "PG", "price": "143.28", "chg": "-1.30%", "rs14": "40.23", "ivpct": "94%", "ivhv": "1.2667201604814", "iv": "25.01%", "iv5d": "25.22%", "iv1m": "25.07%", "iv3m": "21.74%", "iv6m": "20.73%", "bb": "35%", "bbr": "Below Mid", "ttm": "0", "adr14": "2.41", "opvol": "8041", "callvol": "4052", "putvol": "3989"}, {"sym": "VZ", "price": "45.45", "chg": "-1.28%", "rs14": "24.97", "ivpct": "98%", "ivhv": "1.5858700696056", "iv": "27.69%", "iv5d": "27.46%", "iv1m": "26.31%", "iv3m": "23.90%", "iv6m": "21.96%", "bb": "-14%", "bbr": "Below Lower", "ttm": "0", "adr14": "0.86", "opvol": "48123", "callvol": "26433", "putvol": "21690"}, {"sym": "SIG", "price": "92.44", "chg": "-1.27%", "rs14": "56.21", "ivpct": "48%", "ivhv": "0.79683213920164", "iv": "46.52%", "iv5d": "48.25%", "iv1m": "53.20%", "iv3m": "58.28%", "iv6m": "52.73%", "bb": "85%", "bbr": "Above Mid", "ttm": "0", "adr14": "3.72", "opvol": "495", "callvol": "384", "putvol": "111"}, {"sym": "COST", "price": "986.42", "chg": "-1.21%", "rs14": "45.3", "ivpct": "44%", "ivhv": "1.1857023411371", "iv": "21.39%", "iv5d": "21.71%", "iv1m": "22.57%", "iv3m": "23.76%", "iv6m": "22.98%", "bb": "38%", "bbr": "New Below Mid", "ttm": "0", "adr14": "18.17", "opvol": "23463", "callvol": "10770", "putvol": "12693"}, {"sym": "CRH", "price": "116.49", "chg": "-1.19%", "rs14": "62.53", "ivpct": "83%", "ivhv": "0.94345815531541", "iv": "37.53%", "iv5d": "37.93%", "iv1m": "38.53%", "iv3m": "35.63%", "iv6m": "32.26%", "bb": "99%", "bbr": "New Below Upper", "ttm": "0", "adr14": "3.07", "opvol": "903", "callvol": "583", "putvol": "320"}, {"sym": "KMB", "price": "96.16", "chg": "-1.15%", "rs14": "41.95", "ivpct": "94%", "ivhv": "1.1686327979081", "iv": "31.44%", "iv5d": "30.65%", "iv1m": "29.42%", "iv3m": "27.58%", "iv6m": "27.28%", "bb": "25%", "bbr": "Below Mid", "ttm": "0", "adr14": "2.22", "opvol": "2773", "callvol": "1122", "putvol": "1651"}, {"sym": "LLY", "price": "928.93", "chg": "-1.12%", "rs14": "45.34", "ivpct": "89%", "ivhv": "1.4325167892549", "iv": "44.63%", "iv5d": "44.10%", "iv1m": "41.91%", "iv3m": "39.04%", "iv6m": "36.52%", "bb": "55%", "bbr": "Above Mid", "ttm": "0", "adr14": "24.57", "opvol": "15878", "callvol": "9991", "putvol": "5887"}, {"sym": "AAPL", "price": "257.59", "chg": "-1.11%", "rs14": "51.67", "ivpct": "80%", "ivhv": "1.5598144220573", "iv": "29.31%", "iv5d": "28.90%", "iv1m": "28.52%", "iv3m": "27.42%", "iv6m": "25.18%", "bb": "76%", "bbr": "Above Mid", "ttm": "0", "adr14": "5.39", "opvol": "557047", "callvol": "314216", "putvol": "242831"}, {"sym": "WYNN", "price": "102.86", "chg": "-1.10%", "rs14": "50.01", "ivpct": "70%", "ivhv": "1.2341023441967", "iv": "42.48%", "iv5d": "42.96%", "iv1m": "43.04%", "iv3m": "42.44%", "iv6m": "40.89%", "bb": "67%", "bbr": "Above Mid", "ttm": "On", "adr14": "2.93", "opvol": "1409", "callvol": "564", "putvol": "845"}, {"sym": "AMGN", "price": "347.21", "chg": "-1.09%", "rs14": "42.78", "ivpct": "88%", "ivhv": "1.5110557317626", "iv": "33.15%", "iv5d": "33.23%", "iv1m": "32.41%", "iv3m": "29.00%", "iv6m": "27.26%", "bb": "30%", "bbr": "Below Mid", "ttm": "0", "adr14": "7.5", "opvol": "4097", "callvol": "2293", "putvol": "1804"}, {"sym": "HON", "price": "232.53", "chg": "-1.07%", "rs14": "53.05", "ivpct": "91%", "ivhv": "1.1644398682043", "iv": "28.51%", "iv5d": "28.02%", "iv1m": "28.16%", "iv3m": "26.10%", "iv6m": "23.68%", "bb": "76%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.22", "opvol": "3455", "callvol": "1614", "putvol": "1841"}, {"sym": "SATS", "price": "127.28", "chg": "-1.02%", "rs14": "60.24", "ivpct": "62%", "ivhv": "1.2127625489498", "iv": "67.18%", "iv5d": "68.03%", "iv1m": "66.41%", "iv3m": "64.38%", "iv6m": "60.35%", "bb": "86%", "bbr": "Above Mid", "ttm": "0", "adr14": "7.39", "opvol": "8849", "callvol": "5170", "putvol": "3679"}, {"sym": "FSLR", "price": "201.48", "chg": "-0.98%", "rs14": "51.74", "ivpct": "75%", "ivhv": "1.654133583691", "iv": "61.69%", "iv5d": "61.65%", "iv1m": "57.45%", "iv3m": "58.17%", "iv6m": "54.90%", "bb": "81%", "bbr": "Above Mid", "ttm": "On", "adr14": "7.2", "opvol": "15582", "callvol": "13067", "putvol": "2515"}, {"sym": "STZ", "price": "164.55", "chg": "-0.96%", "rs14": "66.75", "ivpct": "6%", "ivhv": "0.84144138372838", "iv": "26.17%", "iv5d": "30.61%", "iv1m": "35.57%", "iv3m": "32.49%", "iv6m": "33.33%", "bb": "109%", "bbr": "Above Upper", "ttm": "0", "adr14": "4.92", "opvol": "1900", "callvol": "805", "putvol": "1095"}, {"sym": "ADI", "price": "346.83", "chg": "-0.95%", "rs14": "63.99", "ivpct": "73%", "ivhv": "1.0488785811733", "iv": "37.58%", "iv5d": "37.42%", "iv1m": "37.74%", "iv3m": "36.94%", "iv6m": "34.80%", "bb": "92%", "bbr": "New Below Upper", "ttm": "0", "adr14": "8.85", "opvol": "1608", "callvol": "695", "putvol": "913"}, {"sym": "CL", "price": "83.56", "chg": "-0.92%", "rs14": "37.79", "ivpct": "91%", "ivhv": "1.2298673740053", "iv": "27.40%", "iv5d": "27.53%", "iv1m": "27.24%", "iv3m": "23.46%", "iv6m": "22.77%", "bb": "21%", "bbr": "Below Mid", "ttm": "0", "adr14": "1.71", "opvol": "1582", "callvol": "1092", "putvol": "490"}, {"sym": "MU", "price": "416.79", "chg": "-0.90%", "rs14": "56.2", "ivpct": "80%", "ivhv": "0.9363835978836", "iv": "70.53%", "iv5d": "70.10%", "iv1m": "68.76%", "iv3m": "71.86%", "iv6m": "67.81%", "bb": "63%", "bbr": "Above Mid", "ttm": "0", "adr14": "21.63", "opvol": "283955", "callvol": "166921", "putvol": "117034"}, {"sym": "MCK", "price": "857.78", "chg": "-0.90%", "rs14": "38.51", "ivpct": "94%", "ivhv": "1.3871661783173", "iv": "33.09%", "iv5d": "32.76%", "iv1m": "31.66%", "iv3m": "28.91%", "iv6m": "27.19%", "bb": "27%", "bbr": "Below Mid", "ttm": "0", "adr14": "18.8", "opvol": "482", "callvol": "251", "putvol": "231"}, {"sym": "CAH", "price": "213.62", "chg": "-0.88%", "rs14": "49.06", "ivpct": "99%", "ivhv": "1.7802712993812", "iv": "37.26%", "iv5d": "36.07%", "iv1m": "33.96%", "iv3m": "31.00%", "iv6m": "28.73%", "bb": "63%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.03", "opvol": "1528", "callvol": "1376", "putvol": "152"}, {"sym": "JNJ", "price": "236.43", "chg": "-0.85%", "rs14": "41.52", "ivpct": "89%", "ivhv": "1.7725434329395", "iv": "25.16%", "iv5d": "25.79%", "iv1m": "27.17%", "iv3m": "23.77%", "iv6m": "21.20%", "bb": "18%", "bbr": "Below Mid", "ttm": "Short", "adr14": "4.1", "opvol": "22006", "callvol": "12427", "putvol": "9579"}, {"sym": "CSCO", "price": "81.53", "chg": "-0.84%", "rs14": "55.65", "ivpct": "94%", "ivhv": "1.2901343784994", "iv": "34.47%", "iv5d": "34.32%", "iv1m": "31.84%", "iv3m": "30.18%", "iv6m": "27.76%", "bb": "72%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.12", "opvol": "19283", "callvol": "14282", "putvol": "5001"}, {"sym": "DVN", "price": "47.4", "chg": "-0.82%", "rs14": "47.28", "ivpct": "77%", "ivhv": "1.3175238722423", "iv": "39.43%", "iv5d": "40.00%", "iv1m": "40.42%", "iv3m": "38.88%", "iv6m": "35.70%", "bb": "19%", "bbr": "Below Mid", "ttm": "0", "adr14": "1.63", "opvol": "12338", "callvol": "9596", "putvol": "2742"}, {"sym": "PPG", "price": "109.44", "chg": "-0.81%", "rs14": "53.67", "ivpct": "94%", "ivhv": "0.8550280767431", "iv": "36.56%", "iv5d": "36.47%", "iv1m": "36.79%", "iv3m": "30.05%", "iv6m": "28.34%", "bb": "85%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.86", "opvol": "10893", "callvol": "10869", "putvol": "24"}, {"sym": "PEP", "price": "155.93", "chg": "-0.72%", "rs14": "49.36", "ivpct": "90%", "ivhv": "1.4992895299145", "iv": "27.77%", "iv5d": "28.28%", "iv1m": "28.94%", "iv3m": "25.45%", "iv6m": "22.98%", "bb": "67%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.98", "opvol": "5637", "callvol": "2855", "putvol": "2782"}, {"sym": "GILD", "price": "138.03", "chg": "-0.69%", "rs14": "43.01", "ivpct": "76%", "ivhv": "1.6172687651332", "iv": "33.52%", "iv5d": "32.65%", "iv1m": "32.20%", "iv3m": "30.96%", "iv6m": "29.76%", "bb": "34%", "bbr": "Below Mid", "ttm": "0", "adr14": "2.71", "opvol": "6606", "callvol": "2098", "putvol": "4508"}, {"sym": "EMR", "price": "142.88", "chg": "-0.62%", "rs14": "60.66", "ivpct": "93%", "ivhv": "1.0646281216069", "iv": "39.35%", "iv5d": "38.15%", "iv1m": "37.51%", "iv3m": "32.66%", "iv6m": "30.16%", "bb": "94%", "bbr": "New Below Upper", "ttm": "0", "adr14": "3.68", "opvol": "1645", "callvol": "1166", "putvol": "479"}, {"sym": "MCD", "price": "303.95", "chg": "-0.57%", "rs14": "37.34", "ivpct": "90%", "ivhv": "1.4394613003096", "iv": "23.33%", "iv5d": "22.95%", "iv1m": "22.74%", "iv3m": "20.86%", "iv6m": "19.59%", "bb": "24%", "bbr": "Below Mid", "ttm": "0", "adr14": "4.91", "opvol": "9127", "callvol": "5078", "putvol": "4049"}, {"sym": "ETN", "price": "400.75", "chg": "-0.56%", "rs14": "66.51", "ivpct": "80%", "ivhv": "0.99366215512754", "iv": "37.99%", "iv5d": "39.52%", "iv1m": "40.07%", "iv3m": "37.23%", "iv6m": "35.29%", "bb": "100%", "bbr": "New Below Upper", "ttm": "0", "adr14": "11.75", "opvol": "1691", "callvol": "1079", "putvol": "612"}, {"sym": "LULU", "price": "162.96", "chg": "-0.55%", "rs14": "51.74", "ivpct": "48%", "ivhv": "1.1014660887302", "iv": "43.93%", "iv5d": "43.76%", "iv1m": "46.20%", "iv3m": "48.83%", "iv6m": "49.80%", "bb": "72%", "bbr": "Above Mid", "ttm": "0", "adr14": "6.33", "opvol": "9927", "callvol": "4564", "putvol": "5363"}, {"sym": "TPR", "price": "149.51", "chg": "-0.53%", "rs14": "55.85", "ivpct": "90%", "ivhv": "1.3683214568488", "iv": "51.93%", "iv5d": "51.05%", "iv1m": "47.96%", "iv3m": "44.40%", "iv6m": "42.83%", "bb": "87%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.77", "opvol": "1055", "callvol": "904", "putvol": "151"}, {"sym": "DE", "price": "601.95", "chg": "-0.50%", "rs14": "57.35", "ivpct": "51%", "ivhv": "1.0604761904762", "iv": "29.56%", "iv5d": "29.39%", "iv1m": "31.14%", "iv3m": "31.91%", "iv6m": "29.95%", "bb": "86%", "bbr": "Above Mid", "ttm": "0", "adr14": "15.59", "opvol": "3166", "callvol": "2244", "putvol": "922"}, {"sym": "FDX", "price": "372.21", "chg": "-0.50%", "rs14": "58.97", "ivpct": "39%", "ivhv": "1.0985709050934", "iv": "29.83%", "iv5d": "30.06%", "iv1m": "35.32%", "iv3m": "36.74%", "iv6m": "33.82%", "bb": "87%", "bbr": "Above Mid", "ttm": "0", "adr14": "7.68", "opvol": "2638", "callvol": "1069", "putvol": "1569"}, {"sym": "RTX", "price": "200.75", "chg": "-0.40%", "rs14": "53.06", "ivpct": "96%", "ivhv": "1.2517204301075", "iv": "33.90%", "iv5d": "33.21%", "iv1m": "33.33%", "iv3m": "31.19%", "iv6m": "27.20%", "bb": "65%", "bbr": "Above Mid", "ttm": "0", "adr14": "3.97", "opvol": "5103", "callvol": "2799", "putvol": "2304"}, {"sym": "PNC", "price": "220.26", "chg": "-0.39%", "rs14": "64.39", "ivpct": "85%", "ivhv": "1.5123541247485", "iv": "30.18%", "iv5d": "30.29%", "iv1m": "33.69%", "iv3m": "29.24%", "iv6m": "26.63%", "bb": "91%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.34", "opvol": "1904", "callvol": "1555", "putvol": "349"}, {"sym": "NSC", "price": "295.24", "chg": "-0.35%", "rs14": "56.15", "ivpct": "86%", "ivhv": "1.4942865013774", "iv": "26.64%", "iv5d": "25.97%", "iv1m": "26.21%", "iv3m": "23.83%", "iv6m": "21.57%", "bb": "91%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.22", "opvol": "53", "callvol": "39", "putvol": "14"}, {"sym": "UPS", "price": "101.35", "chg": "-0.34%", "rs14": "53.02", "ivpct": "80%", "ivhv": "1.3422484998235", "iv": "38.00%", "iv5d": "37.40%", "iv1m": "36.16%", "iv3m": "32.96%", "iv6m": "31.63%", "bb": "96%", "bbr": "New Below Upper", "ttm": "0", "adr14": "2.16", "opvol": "6281", "callvol": "4051", "putvol": "2230"}, {"sym": "ROST", "price": "220.47", "chg": "-0.31%", "rs14": "58.93", "ivpct": "52%", "ivhv": "0.82523067331671", "iv": "26.57%", "iv5d": "26.37%", "iv1m": "27.15%", "iv3m": "28.50%", "iv6m": "26.66%", "bb": "73%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.37", "opvol": "906", "callvol": "393", "putvol": "513"}, {"sym": "LRCX", "price": "262.86", "chg": "-0.30%", "rs14": "66.71", "ivpct": "96%", "ivhv": "1.0200995838288", "iv": "68.61%", "iv5d": "69.06%", "iv1m": "67.70%", "iv3m": "64.70%", "iv6m": "57.30%", "bb": "100%", "bbr": "New Below Upper", "ttm": "0", "adr14": "10.19", "opvol": "14160", "callvol": "6540", "putvol": "7620"}, {"sym": "GM", "price": "76.2", "chg": "-0.29%", "rs14": "52.33", "ivpct": "95%", "ivhv": "1.4267101740295", "iv": "42.70%", "iv5d": "41.91%", "iv1m": "40.49%", "iv3m": "36.97%", "iv6m": "33.61%", "bb": "77%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.75", "opvol": "7695", "callvol": "5545", "putvol": "2150"}, {"sym": "NVDA", "price": "188.1", "chg": "-0.28%", "rs14": "60.7", "ivpct": "7%", "ivhv": "1.0337661141805", "iv": "33.83%", "iv5d": "33.92%", "iv1m": "36.60%", "iv3m": "42.07%", "iv6m": "41.97%", "bb": "94%", "bbr": "New Below Upper", "ttm": "0", "adr14": "4.44", "opvol": "1590103", "callvol": "917629", "putvol": "672474"}, {"sym": "UNP", "price": "249.81", "chg": "-0.28%", "rs14": "58.25", "ivpct": "82%", "ivhv": "1.4677526821005", "iv": "25.99%", "iv5d": "26.74%", "iv1m": "28.12%", "iv3m": "25.58%", "iv6m": "23.79%", "bb": "89%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.07", "opvol": "1648", "callvol": "867", "putvol": "781"}, {"sym": "CAT", "price": "788.63", "chg": "-0.26%", "rs14": "66.42", "ivpct": "88%", "ivhv": "1.0101156780704", "iv": "40.86%", "iv5d": "42.33%", "iv1m": "43.19%", "iv3m": "39.90%", "iv6m": "36.62%", "bb": "98%", "bbr": "New Below Upper", "ttm": "0", "adr14": "21.95", "opvol": "14553", "callvol": "5400", "putvol": "9153"}, {"sym": "EA", "price": "202.23", "chg": "-0.25%", "rs14": "51.37", "ivpct": "38%", "ivhv": "1.8645190839695", "iv": "12.16%", "iv5d": "10.71%", "iv1m": "11.62%", "iv3m": "12.94%", "iv6m": "10.67%", "bb": "53%", "bbr": "Above Mid", "ttm": "0", "adr14": "0.88", "opvol": "30442", "callvol": "193", "putvol": "30249"}, {"sym": "TER", "price": "367.2", "chg": "-0.21%", "rs14": "68.58", "ivpct": "98%", "ivhv": "1.0560640276302", "iv": "80.03%", "iv5d": "79.62%", "iv1m": "74.86%", "iv3m": "68.63%", "iv6m": "61.26%", "bb": "98%", "bbr": "New Below Upper", "ttm": "0", "adr14": "15.89", "opvol": "1741", "callvol": "717", "putvol": "1024"}, {"sym": "HWM", "price": "252.24", "chg": "-0.17%", "rs14": "59.08", "ivpct": "84%", "ivhv": "1.1807669376694", "iv": "43.56%", "iv5d": "43.16%", "iv1m": "42.52%", "iv3m": "40.66%", "iv6m": "36.99%", "bb": "91%", "bbr": "Above Mid", "ttm": "0", "adr14": "6.65", "opvol": "593", "callvol": "249", "putvol": "344"}, {"sym": "XOM", "price": "152.28", "chg": "-0.15%", "rs14": "41.7", "ivpct": "91%", "ivhv": "1.1021443158611", "iv": "32.33%", "iv5d": "33.02%", "iv1m": "32.76%", "iv3m": "29.86%", "iv6m": "25.54%", "bb": "10%", "bbr": "Below Mid", "ttm": "0", "adr14": "5.18", "opvol": "68047", "callvol": "50583", "putvol": "17464"}, {"sym": "GE", "price": "307.91", "chg": "-0.14%", "rs14": "53.29", "ivpct": "93%", "ivhv": "0.94660608921407", "iv": "40.23%", "iv5d": "40.44%", "iv1m": "39.52%", "iv3m": "34.83%", "iv6m": "32.68%", "bb": "82%", "bbr": "Above Mid", "ttm": "0", "adr14": "8.14", "opvol": "4578", "callvol": "1812", "putvol": "2766"}, {"sym": "GEV", "price": "990.57", "chg": "-0.08%", "rs14": "69.48", "ivpct": "66%", "ivhv": "1.0912899106003", "iv": "51.28%", "iv5d": "52.63%", "iv1m": "53.47%", "iv3m": "51.18%", "iv6m": "50.40%", "bb": "101%", "bbr": "Above Upper", "ttm": "0", "adr14": "36.59", "opvol": "11933", "callvol": "5672", "putvol": "6261"}, {"sym": "ABT", "price": "100.27", "chg": "-0.03%", "rs14": "30.97", "ivpct": "92%", "ivhv": "1.5788453608247", "iv": "30.40%", "iv5d": "30.94%", "iv1m": "30.93%", "iv3m": "26.41%", "iv6m": "23.74%", "bb": "13%", "bbr": "Below Mid", "ttm": "0", "adr14": "1.97", "opvol": "7390", "callvol": "4189", "putvol": "3201"}, {"sym": "AMD", "price": "245.09", "chg": "+0.02%", "rs14": "70.59", "ivpct": "75%", "ivhv": "1.1323689396926", "iv": "57.64%", "iv5d": "57.74%", "iv1m": "55.18%", "iv3m": "56.40%", "iv6m": "55.49%", "bb": "103%", "bbr": "Above Upper", "ttm": "0", "adr14": "9.33", "opvol": "213279", "callvol": "111665", "putvol": "101614"}, {"sym": "PDD", "price": "100.21", "chg": "+0.04%", "rs14": "47.84", "ivpct": "45%", "ivhv": "1.1506647673314", "iv": "36.35%", "iv5d": "35.73%", "iv1m": "41.10%", "iv3m": "40.78%", "iv6m": "36.44%", "bb": "50%", "bbr": "Below Mid", "ttm": "Long", "adr14": "3.56", "opvol": "25546", "callvol": "18915", "putvol": "6631"}, {"sym": "OXY", "price": "58", "chg": "+0.05%", "rs14": "46.61", "ivpct": "87%", "ivhv": "1.0864731774415", "iv": "40.47%", "iv5d": "41.41%", "iv1m": "40.71%", "iv3m": "38.01%", "iv6m": "33.98%", "bb": "21%", "bbr": "Below Mid", "ttm": "0", "adr14": "2.38", "opvol": "62144", "callvol": "53744", "putvol": "8400"}, {"sym": "META", "price": "630.36", "chg": "+0.08%", "rs14": "57.51", "ivpct": "80%", "ivhv": "0.9230777903044", "iv": "40.85%", "iv5d": "42.10%", "iv1m": "39.20%", "iv3m": "35.98%", "iv6m": "34.95%", "bb": "81%", "bbr": "Above Mid", "ttm": "0", "adr14": "18.3", "opvol": "384518", "callvol": "231874", "putvol": "152644"}, {"sym": "MMM", "price": "150.47", "chg": "+0.10%", "rs14": "52.22", "ivpct": "85%", "ivhv": "1.194161358811", "iv": "33.78%", "iv5d": "34.31%", "iv1m": "33.84%", "iv3m": "29.96%", "iv6m": "28.03%", "bb": "88%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.8", "opvol": "1936", "callvol": "611", "putvol": "1325"}, {"sym": "SLB", "price": "51.99", "chg": "+0.13%", "rs14": "58.69", "ivpct": "84%", "ivhv": "0.90206150341686", "iv": "39.80%", "iv5d": "40.98%", "iv1m": "41.81%", "iv3m": "38.29%", "iv6m": "35.63%", "bb": "72%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.86", "opvol": "4173", "callvol": "2985", "putvol": "1188"}, {"sym": "AMZN", "price": "238.71", "chg": "+0.14%", "rs14": "71.65", "ivpct": "84%", "ivhv": "1.2297862733293", "iv": "40.73%", "iv5d": "40.45%", "iv1m": "37.67%", "iv3m": "37.17%", "iv6m": "34.80%", "bb": "108%", "bbr": "Above Upper", "ttm": "0", "adr14": "5.4", "opvol": "641320", "callvol": "414751", "putvol": "226569"}, {"sym": "KR", "price": "68.09", "chg": "+0.15%", "rs14": "39.55", "ivpct": "53%", "ivhv": "0.87152804642166", "iv": "27.08%", "iv5d": "27.58%", "iv1m": "28.11%", "iv3m": "29.84%", "iv6m": "28.07%", "bb": "-6%", "bbr": "Below Lower", "ttm": "0", "adr14": "1.86", "opvol": "3307", "callvol": "2413", "putvol": "894"}, {"sym": "DECK", "price": "108.02", "chg": "+0.15%", "rs14": "57.22", "ivpct": "28%", "ivhv": "0.87389458955224", "iv": "38.86%", "iv5d": "40.35%", "iv1m": "41.60%", "iv3m": "44.20%", "iv6m": "45.71%", "bb": "87%", "bbr": "Above Mid", "ttm": "0", "adr14": "3.74", "opvol": "1450", "callvol": "920", "putvol": "530"}, {"sym": "PM", "price": "160.71", "chg": "+0.16%", "rs14": "41.41", "ivpct": "92%", "ivhv": "1.0680492365223", "iv": "34.30%", "iv5d": "33.90%", "iv1m": "32.51%", "iv3m": "30.36%", "iv6m": "28.11%", "bb": "36%", "bbr": "Below Mid", "ttm": "0", "adr14": "4.11", "opvol": "2853", "callvol": "1325", "putvol": "1528"}, {"sym": "TXN", "price": "215.09", "chg": "+0.17%", "rs14": "66.58", "ivpct": "92%", "ivhv": "1.29542527339", "iv": "42.67%", "iv5d": "41.83%", "iv1m": "38.93%", "iv3m": "36.54%", "iv6m": "35.64%", "bb": "100%", "bbr": "New Below Upper", "ttm": "0", "adr14": "4.76", "opvol": "4302", "callvol": "2361", "putvol": "1941"}, {"sym": "RCL", "price": "277.42", "chg": "+0.17%", "rs14": "48.49", "ivpct": "94%", "ivhv": "1.2012314356436", "iv": "58.15%", "iv5d": "57.76%", "iv1m": "57.64%", "iv3m": "49.90%", "iv6m": "45.20%", "bb": "64%", "bbr": "Above Mid", "ttm": "On", "adr14": "10.66", "opvol": "3082", "callvol": "1415", "putvol": "1667"}, {"sym": "HLT", "price": "324.01", "chg": "+0.18%", "rs14": "65.16", "ivpct": "86%", "ivhv": "1.1335698847262", "iv": "30.51%", "iv5d": "30.89%", "iv1m": "32.28%", "iv3m": "29.49%", "iv6m": "26.60%", "bb": "101%", "bbr": "Above Upper", "ttm": "0", "adr14": "6.1", "opvol": "1105", "callvol": "377", "putvol": "728"}, {"sym": "LOW", "price": "244.75", "chg": "+0.22%", "rs14": "52.07", "ivpct": "63%", "ivhv": "0.92877899484536", "iv": "28.74%", "iv5d": "29.01%", "iv1m": "30.51%", "iv3m": "28.99%", "iv6m": "27.14%", "bb": "87%", "bbr": "Above Mid", "ttm": "0", "adr14": "5.68", "opvol": "8716", "callvol": "8008", "putvol": "708"}, {"sym": "USB", "price": "55.81", "chg": "+0.27%", "rs14": "64.87", "ivpct": "74%", "ivhv": "1.5120267379679", "iv": "28.05%", "iv5d": "29.77%", "iv1m": "32.79%", "iv3m": "29.25%", "iv6m": "26.50%", "bb": "96%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.06", "opvol": "1319", "callvol": "628", "putvol": "691"}, {"sym": "JPM", "price": "310.73", "chg": "+0.28%", "rs14": "66.68", "ivpct": "71%", "ivhv": "1.2648070509767", "iv": "26.63%", "iv5d": "28.76%", "iv1m": "32.17%", "iv3m": "28.91%", "iv6m": "26.22%", "bb": "98%", "bbr": "New Below Upper", "ttm": "0", "adr14": "6.12", "opvol": "44949", "callvol": "21170", "putvol": "23779"}, {"sym": "EOG", "price": "136.65", "chg": "+0.34%", "rs14": "48.82", "ivpct": "80%", "ivhv": "1.2071785962474", "iv": "34.74%", "iv5d": "35.38%", "iv1m": "36.05%", "iv3m": "34.29%", "iv6m": "30.58%", "bb": "25%", "bbr": "Below Mid", "ttm": "0", "adr14": "4.28", "opvol": "3342", "callvol": "2118", "putvol": "1224"}, {"sym": "MDT", "price": "87.52", "chg": "+0.36%", "rs14": "43.04", "ivpct": "56%", "ivhv": "1.1900647948164", "iv": "22.06%", "iv5d": "22.66%", "iv1m": "23.40%", "iv3m": "23.12%", "iv6m": "21.61%", "bb": "59%", "bbr": "Above Mid", "ttm": "On", "adr14": "1.53", "opvol": "3030", "callvol": "1843", "putvol": "1187"}, {"sym": "WFC", "price": "85.71", "chg": "+0.36%", "rs14": "63.81", "ivpct": "82%", "ivhv": "1.2571098265896", "iv": "33.02%", "iv5d": "34.42%", "iv1m": "38.18%", "iv3m": "32.99%", "iv6m": "29.91%", "bb": "94%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.7", "opvol": "55635", "callvol": "21843", "putvol": "33792"}, {"sym": "NKE", "price": "42.79", "chg": "+0.40%", "rs14": "23.77", "ivpct": "39%", "ivhv": "0.65463645130183", "iv": "34.00%", "iv5d": "34.66%", "iv1m": "44.54%", "iv3m": "41.52%", "iv6m": "39.09%", "bb": "16%", "bbr": "Below Mid", "ttm": "0", "adr14": "1.42", "opvol": "95329", "callvol": "62220", "putvol": "33109"}, {"sym": "AAOI", "price": "151.22", "chg": "+0.41%", "rs14": "71.56", "ivpct": "99%", "ivhv": "0.99533119526335", "iv": "161.06%", "iv5d": "159.20%", "iv1m": "139.51%", "iv3m": "127.32%", "iv6m": "115.75%", "bb": "104%", "bbr": "Above Upper", "ttm": "0", "adr14": "14.75", "opvol": "37434", "callvol": "19535", "putvol": "17899"}, {"sym": "NFLX", "price": "103.44", "chg": "+0.42%", "rs14": "73.58", "ivpct": "66%", "ivhv": "1.767606543263", "iv": "40.90%", "iv5d": "41.03%", "iv1m": "42.56%", "iv3m": "39.64%", "iv6m": "37.27%", "bb": "100%", "bbr": "New Below Upper", "ttm": "0", "adr14": "2.83", "opvol": "179014", "callvol": "121937", "putvol": "57077"}, {"sym": "URI", "price": "775.38", "chg": "+0.45%", "rs14": "54.13", "ivpct": "93%", "ivhv": "1.2305048814505", "iv": "43.99%", "iv5d": "43.29%", "iv1m": "43.69%", "iv3m": "39.65%", "iv6m": "36.42%", "bb": "101%", "bbr": "Above Upper", "ttm": "0", "adr14": "21.48", "opvol": "764", "callvol": "413", "putvol": "351"}, {"sym": "GEHC", "price": "73.51", "chg": "+0.45%", "rs14": "51.72", "ivpct": "70%", "ivhv": "0.93742903053026", "iv": "35.23%", "iv5d": "36.09%", "iv1m": "36.93%", "iv3m": "33.18%", "iv6m": "31.47%", "bb": "90%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.75", "opvol": "816", "callvol": "375", "putvol": "441"}, {"sym": "SBUX", "price": "97.04", "chg": "+0.46%", "rs14": "56.55", "ivpct": "78%", "ivhv": "1.1888752983294", "iv": "39.52%", "iv5d": "39.90%", "iv1m": "37.52%", "iv3m": "34.66%", "iv6m": "34.20%", "bb": "76%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.35", "opvol": "8395", "callvol": "4340", "putvol": "4055"}, {"sym": "VLO", "price": "239.91", "chg": "+0.46%", "rs14": "53.79", "ivpct": "87%", "ivhv": "1.0209985422741", "iv": "41.25%", "iv5d": "42.68%", "iv1m": "44.26%", "iv3m": "40.77%", "iv6m": "36.82%", "bb": "40%", "bbr": "Below Mid", "ttm": "0", "adr14": "9.75", "opvol": "3369", "callvol": "2085", "putvol": "1284"}, {"sym": "HD", "price": "338.96", "chg": "+0.48%", "rs14": "49.78", "ivpct": "72%", "ivhv": "0.93193505189153", "iv": "27.88%", "iv5d": "28.43%", "iv1m": "29.52%", "iv3m": "27.95%", "iv6m": "26.14%", "bb": "79%", "bbr": "Above Mid", "ttm": "0", "adr14": "7.72", "opvol": "6919", "callvol": "3917", "putvol": "3002"}, {"sym": "STX", "price": "505.58", "chg": "+0.49%", "rs14": "68.94", "ivpct": "99%", "ivhv": "1.1355496235455", "iv": "82.75%", "iv5d": "80.93%", "iv1m": "77.23%", "iv3m": "75.50%", "iv6m": "69.57%", "bb": "93%", "bbr": "Above Mid", "ttm": "0", "adr14": "25.26", "opvol": "6418", "callvol": "2700", "putvol": "3718"}, {"sym": "COP", "price": "123.15", "chg": "+0.49%", "rs14": "47.56", "ivpct": "83%", "ivhv": "1.1929265003372", "iv": "34.98%", "iv5d": "35.46%", "iv1m": "36.43%", "iv3m": "34.13%", "iv6m": "31.27%", "bb": "21%", "bbr": "Below Mid", "ttm": "0", "adr14": "3.67", "opvol": "7591", "callvol": "5111", "putvol": "2480"}, {"sym": "PSX", "price": "160.06", "chg": "+0.51%", "rs14": "37.39", "ivpct": "80%", "ivhv": "1.0207025959368", "iv": "35.06%", "iv5d": "36.34%", "iv1m": "38.53%", "iv3m": "35.67%", "iv6m": "32.62%", "bb": "2%", "bbr": "New Above Lower", "ttm": "0", "adr14": "6.35", "opvol": "1560", "callvol": "1166", "putvol": "394"}, {"sym": "MRNA", "price": "51.22", "chg": "+0.51%", "rs14": "51.98", "ivpct": "72%", "ivhv": "1.1420818452381", "iv": "76.58%", "iv5d": "75.93%", "iv1m": "74.34%", "iv3m": "77.57%", "iv6m": "72.75%", "bb": "52%", "bbr": "New Above Mid", "ttm": "On", "adr14": "2.54", "opvol": "17217", "callvol": "11230", "putvol": "5987"}, {"sym": "GOOG", "price": "317.34", "chg": "+0.51%", "rs14": "63.32", "ivpct": "72%", "ivhv": "1.2174726775956", "iv": "35.71%", "iv5d": "35.29%", "iv1m": "33.70%", "iv3m": "34.05%", "iv6m": "32.67%", "bb": "86%", "bbr": "Above Mid", "ttm": "0", "adr14": "6.99", "opvol": "84252", "callvol": "54557", "putvol": "29695"}, {"sym": "AFL", "price": "111.27", "chg": "+0.51%", "rs14": "54.45", "ivpct": "87%", "ivhv": "1.6042857142857", "iv": "25.02%", "iv5d": "23.53%", "iv1m": "24.05%", "iv3m": "22.46%", "iv6m": "20.68%", "bb": "77%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.84", "opvol": "1635", "callvol": "1462", "putvol": "173"}, {"sym": "LEN", "price": "89.44", "chg": "+0.53%", "rs14": "41.46", "ivpct": "78%", "ivhv": "1.2138104502501", "iv": "43.42%", "iv5d": "43.93%", "iv1m": "43.18%", "iv3m": "42.86%", "iv6m": "40.98%", "bb": "45%", "bbr": "Below Mid", "ttm": "0", "adr14": "3.35", "opvol": "2370", "callvol": "1202", "putvol": "1168"}, {"sym": "MAR", "price": "356.02", "chg": "+0.54%", "rs14": "65.93", "ivpct": "86%", "ivhv": "1.1150066181337", "iv": "33.50%", "iv5d": "34.06%", "iv1m": "34.28%", "iv3m": "31.28%", "iv6m": "28.53%", "bb": "102%", "bbr": "Above Upper", "ttm": "0", "adr14": "7.85", "opvol": "1250", "callvol": "635", "putvol": "615"}, {"sym": "DHI", "price": "143.49", "chg": "+0.60%", "rs14": "51.87", "ivpct": "86%", "ivhv": "1.3010741766697", "iv": "41.63%", "iv5d": "42.58%", "iv1m": "40.91%", "iv3m": "38.96%", "iv6m": "37.92%", "bb": "86%", "bbr": "Above Mid", "ttm": "0", "adr14": "4.48", "opvol": "1920", "callvol": "443", "putvol": "1477"}, {"sym": "MS", "price": "178.71", "chg": "+0.60%", "rs14": "68.21", "ivpct": "79%", "ivhv": "1.205077149155", "iv": "32.83%", "iv5d": "34.41%", "iv1m": "39.12%", "iv3m": "34.55%", "iv6m": "30.62%", "bb": "98%", "bbr": "New Below Upper", "ttm": "0", "adr14": "4.62", "opvol": "10782", "callvol": "6061", "putvol": "4721"}, {"sym": "LMT", "price": "617.45", "chg": "+0.61%", "rs14": "46.1", "ivpct": "93%", "ivhv": "1.4002706078268", "iv": "33.35%", "iv5d": "33.60%", "iv1m": "33.94%", "iv3m": "31.90%", "iv6m": "27.71%", "bb": "39%", "bbr": "Below Mid", "ttm": "0", "adr14": "14.88", "opvol": "4707", "callvol": "3081", "putvol": "1626"}, {"sym": "VRTX", "price": "438.93", "chg": "+0.61%", "rs14": "42.99", "ivpct": "79%", "ivhv": "1.0073595814978", "iv": "36.43%", "iv5d": "35.38%", "iv1m": "33.60%", "iv3m": "36.70%", "iv6m": "32.81%", "bb": "27%", "bbr": "Below Mid", "ttm": "0", "adr14": "10.85", "opvol": "2386", "callvol": "726", "putvol": "1660"}, {"sym": "CBOE", "price": "297.78", "chg": "+0.62%", "rs14": "61.04", "ivpct": "76%", "ivhv": "0.90602826329491", "iv": "24.38%", "iv5d": "26.11%", "iv1m": "26.96%", "iv3m": "24.67%", "iv6m": "22.46%", "bb": "87%", "bbr": "Above Mid", "ttm": "0", "adr14": "7.06", "opvol": "827", "callvol": "191", "putvol": "636"}, {"sym": "CI", "price": "272.94", "chg": "+0.62%", "rs14": "51.37", "ivpct": "92%", "ivhv": "1.4358968524839", "iv": "37.62%", "iv5d": "37.03%", "iv1m": "35.85%", "iv3m": "33.95%", "iv6m": "32.48%", "bb": "71%", "bbr": "Above Mid", "ttm": "0", "adr14": "6.21", "opvol": "2251", "callvol": "737", "putvol": "1514"}, {"sym": "AIG", "price": "77.38", "chg": "+0.66%", "rs14": "55.37", "ivpct": "83%", "ivhv": "1.3466855256954", "iv": "29.60%", "iv5d": "29.47%", "iv1m": "29.25%", "iv3m": "28.81%", "iv6m": "26.67%", "bb": "87%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.46", "opvol": "493", "callvol": "302", "putvol": "191"}, {"sym": "BIIB", "price": "174.13", "chg": "+0.67%", "rs14": "40.72", "ivpct": "65%", "ivhv": "1.2102384020619", "iv": "37.22%", "iv5d": "38.47%", "iv1m": "37.73%", "iv3m": "34.92%", "iv6m": "36.03%", "bb": "12%", "bbr": "Below Mid", "ttm": "0", "adr14": "5.81", "opvol": "974", "callvol": "761", "putvol": "213"}, {"sym": "BAC", "price": "52.9", "chg": "+0.69%", "rs14": "68.27", "ivpct": "75%", "ivhv": "1.2618526785714", "iv": "28.36%", "iv5d": "30.17%", "iv1m": "33.92%", "iv3m": "29.64%", "iv6m": "27.15%", "bb": "98%", "bbr": "New Below Upper", "ttm": "0", "adr14": "1.09", "opvol": "59460", "callvol": "42396", "putvol": "17064"}, {"sym": "C", "price": "125.28", "chg": "+0.72%", "rs14": "70", "ivpct": "80%", "ivhv": "1.0720504150015", "iv": "34.84%", "iv5d": "36.71%", "iv1m": "40.59%", "iv3m": "36.37%", "iv6m": "32.92%", "bb": "96%", "bbr": "Above Mid", "ttm": "0", "adr14": "3.26", "opvol": "68309", "callvol": "38442", "putvol": "29867"}, {"sym": "PHM", "price": "121.22", "chg": "+0.74%", "rs14": "50.26", "ivpct": "92%", "ivhv": "1.237032967033", "iv": "40.66%", "iv5d": "40.83%", "iv1m": "39.41%", "iv3m": "37.83%", "iv6m": "36.20%", "bb": "80%", "bbr": "Above Mid", "ttm": "0", "adr14": "3.44", "opvol": "1570", "callvol": "1403", "putvol": "167"}, {"sym": "CTAS", "price": "176.23", "chg": "+0.74%", "rs14": "42.85", "ivpct": "61%", "ivhv": "1.0005578747628", "iv": "26.39%", "iv5d": "27.21%", "iv1m": "29.58%", "iv3m": "25.96%", "iv6m": "25.43%", "bb": "47%", "bbr": "Below Mid", "ttm": "0", "adr14": "4.65", "opvol": "262", "callvol": "172", "putvol": "90"}, {"sym": "MRVL", "price": "129.49", "chg": "+0.78%", "rs14": "80.57", "ivpct": "61%", "ivhv": "0.78863385877227", "iv": "62.37%", "iv5d": "59.78%", "iv1m": "55.74%", "iv3m": "60.13%", "iv6m": "59.99%", "bb": "106%", "bbr": "Above Upper", "ttm": "0", "adr14": "5.61", "opvol": "157857", "callvol": "110852", "putvol": "47005"}, {"sym": "FCX", "price": "68.33", "chg": "+0.78%", "rs14": "67.84", "ivpct": "79%", "ivhv": "0.93088754134509", "iv": "50.72%", "iv5d": "52.34%", "iv1m": "55.22%", "iv3m": "52.21%", "iv6m": "46.34%", "bb": "100%", "bbr": "Above Upper", "ttm": "0", "adr14": "2.12", "opvol": "31109", "callvol": "13443", "putvol": "17666"}, {"sym": "MSTR", "price": "129.72", "chg": "+0.84%", "rs14": "49.29", "ivpct": "63%", "ivhv": "1.1386481210347", "iv": "69.87%", "iv5d": "70.68%", "iv1m": "72.06%", "iv3m": "75.68%", "iv6m": "72.95%", "bb": "47%", "bbr": "Below Mid", "ttm": "0", "adr14": "6.51", "opvol": "173124", "callvol": "86345", "putvol": "86779"}, {"sym": "ASO", "price": "56.88", "chg": "+0.90%", "rs14": "52.76", "ivpct": "42%", "ivhv": "0.89536234902124", "iv": "43.62%", "iv5d": "42.64%", "iv1m": "44.15%", "iv3m": "48.59%", "iv6m": "48.33%", "bb": "72%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.48", "opvol": "539", "callvol": "381", "putvol": "158"}, {"sym": "V", "price": "307.33", "chg": "+0.98%", "rs14": "50.15", "ivpct": "90%", "ivhv": "1.5212833061446", "iv": "27.98%", "iv5d": "27.92%", "iv1m": "28.26%", "iv3m": "26.05%", "iv6m": "23.65%", "bb": "75%", "bbr": "Above Mid", "ttm": "Long", "adr14": "6.06", "opvol": "15632", "callvol": "10508", "putvol": "5124"}, {"sym": "GD", "price": "338.52", "chg": "+1.01%", "rs14": "40.91", "ivpct": "95%", "ivhv": "1.4570106761566", "iv": "28.99%", "iv5d": "28.60%", "iv1m": "28.51%", "iv3m": "26.44%", "iv6m": "22.96%", "bb": "8%", "bbr": "New Above Lower", "ttm": "On", "adr14": "7.18", "opvol": "1049", "callvol": "650", "putvol": "399"}, {"sym": "CF", "price": "122.58", "chg": "+1.04%", "rs14": "51.25", "ivpct": "92%", "ivhv": "0.80717391304348", "iv": "55.65%", "iv5d": "56.43%", "iv1m": "56.92%", "iv3m": "46.20%", "iv6m": "39.68%", "bb": "31%", "bbr": "Below Mid", "ttm": "0", "adr14": "6.66", "opvol": "6117", "callvol": "4836", "putvol": "1281"}, {"sym": "ISRG", "price": "455.36", "chg": "+1.05%", "rs14": "39.96", "ivpct": "81%", "ivhv": "1.7928895956383", "iv": "39.38%", "iv5d": "39.38%", "iv1m": "38.18%", "iv3m": "33.42%", "iv6m": "32.93%", "bb": "29%", "bbr": "Below Mid", "ttm": "0", "adr14": "10.22", "opvol": "2291", "callvol": "1495", "putvol": "796"}, {"sym": "ABNB", "price": "130.32", "chg": "+1.05%", "rs14": "53.05", "ivpct": "86%", "ivhv": "1.3420816561242", "iv": "46.60%", "iv5d": "45.75%", "iv1m": "43.29%", "iv3m": "41.74%", "iv6m": "37.83%", "bb": "66%", "bbr": "Above Mid", "ttm": "On", "adr14": "4.31", "opvol": "5756", "callvol": "2847", "putvol": "2909"}, {"sym": "QCOM", "price": "129.46", "chg": "+1.09%", "rs14": "45.51", "ivpct": "90%", "ivhv": "2.0800289156627", "iv": "43.00%", "iv5d": "42.39%", "iv1m": "39.71%", "iv3m": "37.91%", "iv6m": "36.26%", "bb": "62%", "bbr": "New Above Mid", "ttm": "On", "adr14": "2.94", "opvol": "28510", "callvol": "20178", "putvol": "8332"}, {"sym": "TSLA", "price": "352.78", "chg": "+1.10%", "rs14": "40.38", "ivpct": "29%", "ivhv": "1.2384450975154", "iv": "46.10%", "iv5d": "46.97%", "iv1m": "44.55%", "iv3m": "44.30%", "iv6m": "47.37%", "bb": "29%", "bbr": "Below Mid", "ttm": "0", "adr14": "12.59", "opvol": "2091800", "callvol": "1210010", "putvol": "881790"}, {"sym": "DLR", "price": "190.95", "chg": "+1.10%", "rs14": "72.18", "ivpct": "60%", "ivhv": "1.4894774346793", "iv": "31.44%", "iv5d": "32.67%", "iv1m": "33.18%", "iv3m": "32.75%", "iv6m": "31.40%", "bb": "103%", "bbr": "Above Upper", "ttm": "0", "adr14": "3.54", "opvol": "945", "callvol": "692", "putvol": "253"}, {"sym": "MCHP", "price": "72.37", "chg": "+1.13%", "rs14": "64.08", "ivpct": "94%", "ivhv": "1.4001357466063", "iv": "58.71%", "iv5d": "57.17%", "iv1m": "52.69%", "iv3m": "49.92%", "iv6m": "48.40%", "bb": "101%", "bbr": "Above Upper", "ttm": "0", "adr14": "2.52", "opvol": "1614", "callvol": "1014", "putvol": "600"}, {"sym": "MA", "price": "504.39", "chg": "+1.15%", "rs14": "49.72", "ivpct": "90%", "ivhv": "1.3224427131072", "iv": "28.70%", "iv5d": "29.34%", "iv1m": "28.84%", "iv3m": "26.76%", "iv6m": "24.19%", "bb": "70%", "bbr": "Above Mid", "ttm": "On", "adr14": "10.36", "opvol": "4032", "callvol": "2105", "putvol": "1927"}, {"sym": "COF", "price": "195.32", "chg": "+1.20%", "rs14": "57.29", "ivpct": "86%", "ivhv": "1.3900779661017", "iv": "41.01%", "iv5d": "41.34%", "iv1m": "42.16%", "iv3m": "37.95%", "iv6m": "34.33%", "bb": "101%", "bbr": "Above Upper", "ttm": "0", "adr14": "4.46", "opvol": "3702", "callvol": "1773", "putvol": "1929"}, {"sym": "CME", "price": "298.86", "chg": "+1.21%", "rs14": "46.07", "ivpct": "81%", "ivhv": "1.0822231237323", "iv": "25.04%", "iv5d": "25.60%", "iv1m": "25.66%", "iv3m": "25.14%", "iv6m": "22.44%", "bb": "35%", "bbr": "Below Mid", "ttm": "0", "adr14": "6.08", "opvol": "970", "callvol": "435", "putvol": "535"}, {"sym": "SCHW", "price": "95.95", "chg": "+1.21%", "rs14": "54.19", "ivpct": "92%", "ivhv": "1.7242913973148", "iv": "34.67%", "iv5d": "34.58%", "iv1m": "34.64%", "iv3m": "30.60%", "iv6m": "28.31%", "bb": "84%", "bbr": "Above Mid", "ttm": "On", "adr14": "2.43", "opvol": "38644", "callvol": "5922", "putvol": "32722"}, {"sym": "CVX", "price": "190.85", "chg": "+1.22%", "rs14": "42.79", "ivpct": "89%", "ivhv": "1.0945813528336", "iv": "29.94%", "iv5d": "30.29%", "iv1m": "29.97%", "iv3m": "27.44%", "iv6m": "24.49%", "bb": "12%", "bbr": "Below Mid", "ttm": "0", "adr14": "5.56", "opvol": "34852", "callvol": "27077", "putvol": "7775"}, {"sym": "WGS", "price": "60.36", "chg": "+1.24%", "rs14": "36.31", "ivpct": "75%", "ivhv": "1.2962122178294", "iv": "101.55%", "iv5d": "97.25%", "iv1m": "86.86%", "iv3m": "87.24%", "iv6m": "81.15%", "bb": "24%", "bbr": "Below Mid", "ttm": "0", "adr14": "4.2", "opvol": "874", "callvol": "406", "putvol": "468"}, {"sym": "AVGO", "price": "376.25", "chg": "+1.26%", "rs14": "72.33", "ivpct": "38%", "ivhv": "1.0397986270023", "iv": "44.90%", "iv5d": "45.14%", "iv1m": "45.98%", "iv3m": "51.45%", "iv6m": "49.32%", "bb": "110%", "bbr": "Above Upper", "ttm": "0", "adr14": "10.19", "opvol": "197490", "callvol": "98208", "putvol": "99282"}, {"sym": "LHX", "price": "358.14", "chg": "+1.29%", "rs14": "53.3", "ivpct": "83%", "ivhv": "1.1695920577617", "iv": "31.64%", "iv5d": "32.31%", "iv1m": "33.71%", "iv3m": "31.61%", "iv6m": "28.15%", "bb": "64%", "bbr": "New Above Mid", "ttm": "0", "adr14": "8.48", "opvol": "459", "callvol": "295", "putvol": "164"}, {"sym": "ULTA", "price": "527.23", "chg": "+1.32%", "rs14": "37.78", "ivpct": "54%", "ivhv": "0.7075406907503", "iv": "36.08%", "iv5d": "36.18%", "iv1m": "36.23%", "iv3m": "37.95%", "iv6m": "35.22%", "bb": "55%", "bbr": "New Above Mid", "ttm": "0", "adr14": "15.06", "opvol": "1080", "callvol": "653", "putvol": "427"}, {"sym": "WDC", "price": "348.08", "chg": "+1.35%", "rs14": "66.78", "ivpct": "84%", "ivhv": "1.0549981129702", "iv": "83.52%", "iv5d": "84.17%", "iv1m": "82.66%", "iv3m": "84.36%", "iv6m": "76.57%", "bb": "95%", "bbr": "Above Mid", "ttm": "0", "adr14": "18.63", "opvol": "20032", "callvol": "10313", "putvol": "9719"}, {"sym": "BLK", "price": "1013.77", "chg": "+1.45%", "rs14": "58.01", "ivpct": "86%", "ivhv": "0.95763120160596", "iv": "32.77%", "iv5d": "34.35%", "iv1m": "36.99%", "iv3m": "31.91%", "iv6m": "28.36%", "bb": "102%", "bbr": "New Above Upper", "ttm": "0", "adr14": "22.9", "opvol": "2240", "callvol": "947", "putvol": "1293"}, {"sym": "CEG", "price": "291.01", "chg": "+1.57%", "rs14": "48.69", "ivpct": "63%", "ivhv": "1.069484454939", "iv": "52.84%", "iv5d": "52.44%", "iv1m": "54.64%", "iv3m": "54.05%", "iv6m": "51.60%", "bb": "48%", "bbr": "Below Mid", "ttm": "0", "adr14": "11.22", "opvol": "4855", "callvol": "2633", "putvol": "2222"}, {"sym": "EBAY", "price": "96.93", "chg": "+1.60%", "rs14": "62.99", "ivpct": "88%", "ivhv": "1.5985199240987", "iv": "43.04%", "iv5d": "42.03%", "iv1m": "39.30%", "iv3m": "38.77%", "iv6m": "35.12%", "bb": "88%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.68", "opvol": "1937", "callvol": "916", "putvol": "1021"}, {"sym": "AMBA", "price": "53.63", "chg": "+1.61%", "rs14": "48.76", "ivpct": "41%", "ivhv": "1.315239223117", "iv": "55.85%", "iv5d": "55.21%", "iv1m": "56.60%", "iv3m": "66.14%", "iv6m": "64.81%", "bb": "68%", "bbr": "Above Mid", "ttm": "Long", "adr14": "2.08", "opvol": "532", "callvol": "127", "putvol": "405"}, {"sym": "IRM", "price": "111.16", "chg": "+1.64%", "rs14": "66.03", "ivpct": "90%", "ivhv": "1.3723409405256", "iv": "39.79%", "iv5d": "39.93%", "iv1m": "38.68%", "iv3m": "37.88%", "iv6m": "35.48%", "bb": "97%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.75", "opvol": "358", "callvol": "245", "putvol": "113"}, {"sym": "GLW", "price": "174.25", "chg": "+1.76%", "rs14": "70.86", "ivpct": "100%", "ivhv": "0.99836998706339", "iv": "76.87%", "iv5d": "75.21%", "iv1m": "69.35%", "iv3m": "61.97%", "iv6m": "52.17%", "bb": "101%", "bbr": "Above Upper", "ttm": "0", "adr14": "8.73", "opvol": "25043", "callvol": "13280", "putvol": "11763"}, {"sym": "JBL", "price": "304.77", "chg": "+1.76%", "rs14": "67.72", "ivpct": "60%", "ivhv": "0.8659996021484", "iv": "43.78%", "iv5d": "46.22%", "iv1m": "47.83%", "iv3m": "49.80%", "iv6m": "46.31%", "bb": "107%", "bbr": "Above Upper", "ttm": "0", "adr14": "11.22", "opvol": "4577", "callvol": "3949", "putvol": "628"}, {"sym": "SHAK", "price": "100.41", "chg": "+1.83%", "rs14": "64.5", "ivpct": "84%", "ivhv": "1.2854338579328", "iv": "60.54%", "iv5d": "60.22%", "iv1m": "56.07%", "iv3m": "54.71%", "iv6m": "51.94%", "bb": "101%", "bbr": "New Above Upper", "ttm": "0", "adr14": "3.79", "opvol": "1819", "callvol": "768", "putvol": "1051"}, {"sym": "BA", "price": "221.61", "chg": "+1.83%", "rs14": "58.54", "ivpct": "88%", "ivhv": "0.98102077001013", "iv": "38.36%", "iv5d": "39.16%", "iv1m": "39.25%", "iv3m": "34.83%", "iv6m": "32.68%", "bb": "91%", "bbr": "Above Mid", "ttm": "0", "adr14": "5.11", "opvol": "37788", "callvol": "18261", "putvol": "19527"}, {"sym": "HOOD", "price": "70.49", "chg": "+1.88%", "rs14": "46.14", "ivpct": "71%", "ivhv": "1.2790938924339", "iv": "69.87%", "iv5d": "70.33%", "iv1m": "68.56%", "iv3m": "68.89%", "iv6m": "65.97%", "bb": "50%", "bbr": "Below Mid", "ttm": "On", "adr14": "3.54", "opvol": "145827", "callvol": "98818", "putvol": "47009"}, {"sym": "BSX", "price": "62.96", "chg": "+1.89%", "rs14": "34.37", "ivpct": "93%", "ivhv": "1.1838888888889", "iv": "41.74%", "iv5d": "40.29%", "iv1m": "43.35%", "iv3m": "36.52%", "iv6m": "30.31%", "bb": "28%", "bbr": "Below Mid", "ttm": "0", "adr14": "1.75", "opvol": "8136", "callvol": "5004", "putvol": "3132"}, {"sym": "DIS", "price": "101.09", "chg": "+1.94%", "rs14": "56.75", "ivpct": "79%", "ivhv": "1.7048007870143", "iv": "35.04%", "iv5d": "34.70%", "iv1m": "32.33%", "iv3m": "30.66%", "iv6m": "29.76%", "bb": "91%", "bbr": "Above Mid", "ttm": "0", "adr14": "1.94", "opvol": "17920", "callvol": "10137", "putvol": "7783"}, {"sym": "PGR", "price": "198", "chg": "+1.99%", "rs14": "45.27", "ivpct": "80%", "ivhv": "1.4367163461538", "iv": "30.04%", "iv5d": "30.34%", "iv1m": "31.03%", "iv3m": "29.87%", "iv6m": "29.06%", "bb": "35%", "bbr": "Below Mid", "ttm": "0", "adr14": "4.51", "opvol": "1443", "callvol": "667", "putvol": "776"}, {"sym": "AXP", "price": "319.94", "chg": "+2.05%", "rs14": "58.63", "ivpct": "88%", "ivhv": "1.6878485864878", "iv": "35.01%", "iv5d": "35.71%", "iv1m": "36.11%", "iv3m": "33.69%", "iv6m": "29.79%", "bb": "101%", "bbr": "New Above Upper", "ttm": "0", "adr14": "7.21", "opvol": "6946", "callvol": "3297", "putvol": "3649"}, {"sym": "LVS", "price": "54.55", "chg": "+2.06%", "rs14": "51.24", "ivpct": "89%", "ivhv": "1.7008189482136", "iv": "44.34%", "iv5d": "44.83%", "iv1m": "43.58%", "iv3m": "39.92%", "iv6m": "37.44%", "bb": "72%", "bbr": "New Above Mid", "ttm": "On", "adr14": "1.46", "opvol": "1546", "callvol": "906", "putvol": "640"}, {"sym": "EL", "price": "74.28", "chg": "+2.22%", "rs14": "41.09", "ivpct": "94%", "ivhv": "1.0693395152107", "iv": "65.20%", "iv5d": "65.46%", "iv1m": "59.81%", "iv3m": "49.73%", "iv6m": "45.59%", "bb": "47%", "bbr": "Below Mid", "ttm": "0", "adr14": "3.37", "opvol": "3465", "callvol": "2200", "putvol": "1265"}, {"sym": "XYZ", "price": "63.58", "chg": "+2.22%", "rs14": "59.56", "ivpct": "85%", "ivhv": "1.4710156609857", "iv": "64.06%", "iv5d": "63.53%", "iv1m": "58.95%", "iv3m": "57.00%", "iv6m": "52.91%", "bb": "101%", "bbr": "New Above Upper", "ttm": "Long", "adr14": "2.46", "opvol": "8720", "callvol": "6413", "putvol": "2307"}, {"sym": "AAP", "price": "55.81", "chg": "+2.23%", "rs14": "58.78", "ivpct": "40%", "ivhv": "1.1761169056932", "iv": "54.30%", "iv5d": "55.86%", "iv1m": "57.50%", "iv3m": "62.83%", "iv6m": "59.43%", "bb": "90%", "bbr": "Above Mid", "ttm": "0", "adr14": "2.11", "opvol": "1387", "callvol": "1105", "putvol": "282"}, {"sym": "UNH", "price": "311.2", "chg": "+2.26%", "rs14": "67.21", "ivpct": "45%", "ivhv": "1.0061073636875", "iv": "35.77%", "iv5d": "35.49%", "iv1m": "42.36%", "iv3m": "37.96%", "iv6m": "36.45%", "bb": "95%", "bbr": "Above Mid", "ttm": "0", "adr14": "7.52", "opvol": "61137", "callvol": "36741", "putvol": "24396"}, {"sym": "TTWO", "price": "201.57", "chg": "+2.28%", "rs14": "50.23", "ivpct": "99%", "ivhv": "1.80778125", "iv": "46.23%", "iv5d": "44.76%", "iv1m": "41.66%", "iv3m": "39.41%", "iv6m": "35.27%", "bb": "66%", "bbr": "New Above Mid", "ttm": "0", "adr14": "5.7", "opvol": "1177", "callvol": "733", "putvol": "444"}, {"sym": "FTNT", "price": "78.49", "chg": "+2.33%", "rs14": "43.34", "ivpct": "96%", "ivhv": "1.7401127361365", "iv": "57.05%", "iv5d": "55.01%", "iv1m": "46.57%", "iv3m": "44.50%", "iv6m": "40.81%", "bb": "17%", "bbr": "New Above Lower", "ttm": "Short", "adr14": "3", "opvol": "11810", "callvol": "10373", "putvol": "1437"}, {"sym": "DHR", "price": "194.07", "chg": "+2.35%", "rs14": "49.45", "ivpct": "86%", "ivhv": "1.2333688552767", "iv": "35.62%", "iv5d": "35.94%", "iv1m": "34.42%", "iv3m": "30.51%", "iv6m": "28.67%", "bb": "76%", "bbr": "New Above Mid", "ttm": "0", "adr14": "4.6", "opvol": "1157", "callvol": "791", "putvol": "366"}, {"sym": "COIN", "price": "171.87", "chg": "+2.39%", "rs14": "44.97", "ivpct": "96%", "ivhv": "1.1020109478536", "iv": "76.17%", "iv5d": "75.69%", "iv1m": "73.86%", "iv3m": "70.38%", "iv6m": "64.98%", "bb": "36%", "bbr": "Below Mid", "ttm": "0", "adr14": "10.66", "opvol": "69041", "callvol": "48973", "putvol": "20068"}, {"sym": "GDDY", "price": "81.21", "chg": "+2.42%", "rs14": "44.79", "ivpct": "98%", "ivhv": "1.4594762024679", "iv": "56.57%", "iv5d": "56.14%", "iv1m": "51.31%", "iv3m": "49.46%", "iv6m": "41.05%", "bb": "42%", "bbr": "Below Mid", "ttm": "On", "adr14": "3.01", "opvol": "2441", "callvol": "618", "putvol": "1823"}, {"sym": "IBM", "price": "236.38", "chg": "+2.44%", "rs14": "41.74", "ivpct": "98%", "ivhv": "1.5651136363636", "iv": "44.77%", "iv5d": "43.78%", "iv1m": "40.09%", "iv3m": "37.81%", "iv6m": "34.05%", "bb": "22%", "bbr": "New Above Lower", "ttm": "Short", "adr14": "6.68", "opvol": "16427", "callvol": "12189", "putvol": "4238"}, {"sym": "ANET", "price": "151", "chg": "+2.48%", "rs14": "65.96", "ivpct": "83%", "ivhv": "0.99700421257291", "iv": "62.18%", "iv5d": "61.57%", "iv1m": "56.93%", "iv3m": "56.92%", "iv6m": "53.91%", "bb": "101%", "bbr": "New Above Upper", "ttm": "0", "adr14": "5.57", "opvol": "12523", "callvol": "7664", "putvol": "4859"}, {"sym": "DG", "price": "118.63", "chg": "+2.51%", "rs14": "38.38", "ivpct": "55%", "ivhv": "0.95451772679875", "iv": "36.50%", "iv5d": "36.61%", "iv1m": "36.44%", "iv3m": "41.36%", "iv6m": "38.51%", "bb": "33%", "bbr": "Below Mid", "ttm": "0", "adr14": "3.96", "opvol": "1588", "callvol": "941", "putvol": "647"}, {"sym": "CHTR", "price": "224.31", "chg": "+2.51%", "rs14": "55", "ivpct": "85%", "ivhv": "1.9049014084507", "iv": "60.13%", "iv5d": "58.92%", "iv1m": "53.78%", "iv3m": "50.35%", "iv6m": "51.07%", "bb": "90%", "bbr": "Above Mid", "ttm": "On", "adr14": "8.11", "opvol": "1558", "callvol": "572", "putvol": "986"}, {"sym": "VST", "price": "158.83", "chg": "+2.65%", "rs14": "53.15", "ivpct": "77%", "ivhv": "1.0689642793035", "iv": "59.93%", "iv5d": "58.40%", "iv1m": "57.58%", "iv3m": "56.68%", "iv6m": "54.72%", "bb": "68%", "bbr": "New Above Mid", "ttm": "0", "adr14": "6.73", "opvol": "10155", "callvol": "7333", "putvol": "2822"}, {"sym": "ADP", "price": "193.82", "chg": "+2.66%", "rs14": "36.14", "ivpct": "98%", "ivhv": "1.3784020416176", "iv": "35.32%", "iv5d": "35.20%", "iv1m": "33.60%", "iv3m": "30.15%", "iv6m": "25.80%", "bb": "8%", "bbr": "New Above Lower", "ttm": "0", "adr14": "6", "opvol": "2398", "callvol": "943", "putvol": "1455"}, {"sym": "DLTR", "price": "102.23", "chg": "+2.69%", "rs14": "37.96", "ivpct": "47%", "ivhv": "1.0216919907288", "iv": "39.22%", "iv5d": "39.78%", "iv1m": "40.15%", "iv3m": "44.56%", "iv6m": "41.81%", "bb": "15%", "bbr": "New Above Lower", "ttm": "0", "adr14": "3.69", "opvol": "2042", "callvol": "1336", "putvol": "706"}, {"sym": "TMO", "price": "509.58", "chg": "+2.72%", "rs14": "56.47", "ivpct": "86%", "ivhv": "1.2825008793528", "iv": "36.50%", "iv5d": "35.81%", "iv1m": "34.91%", "iv3m": "31.22%", "iv6m": "28.81%", "bb": "97%", "bbr": "Above Mid", "ttm": "0", "adr14": "14.14", "opvol": "815", "callvol": "533", "putvol": "282"}, {"sym": "MSFT", "price": "381.87", "chg": "+2.97%", "rs14": "49.32", "ivpct": "99%", "ivhv": "1.7501400560224", "iv": "37.57%", "iv5d": "35.63%", "iv1m": "31.90%", "iv3m": "30.27%", "iv6m": "27.28%", "bb": "62%", "bbr": "New Above Mid", "ttm": "0", "adr14": "8.16", "opvol": "803224", "callvol": "617209", "putvol": "186015"}, {"sym": "IBKR", "price": "73.36", "chg": "+3.02%", "rs14": "61.19", "ivpct": "82%", "ivhv": "1.1369086294416", "iv": "44.99%", "iv5d": "45.79%", "iv1m": "48.87%", "iv3m": "44.07%", "iv6m": "41.50%", "bb": "104%", "bbr": "New Above Upper", "ttm": "0", "adr14": "2.46", "opvol": "2582", "callvol": "1582", "putvol": "1000"}, {"sym": "SPGI", "price": "428.03", "chg": "+3.04%", "rs14": "49.3", "ivpct": "91%", "ivhv": "1.296", "iv": "34.10%", "iv5d": "34.14%", "iv1m": "34.69%", "iv3m": "31.49%", "iv6m": "26.36%", "bb": "61%", "bbr": "New Above Mid", "ttm": "0", "adr14": "11.28", "opvol": "1190", "callvol": "523", "putvol": "667"}, {"sym": "NRG", "price": "169.06", "chg": "+3.04%", "rs14": "62.05", "ivpct": "79%", "ivhv": "0.94475221405691", "iv": "50.71%", "iv5d": "50.80%", "iv1m": "50.99%", "iv3m": "49.52%", "iv6m": "47.44%", "bb": "103%", "bbr": "New Above Upper", "ttm": "0", "adr14": "5.65", "opvol": "2099", "callvol": "1807", "putvol": "292"}, {"sym": "HUM", "price": "198.02", "chg": "+3.05%", "rs14": "63.32", "ivpct": "69%", "ivhv": "1.3689495052017", "iv": "53.81%", "iv5d": "55.12%", "iv1m": "63.99%", "iv3m": "56.97%", "iv6m": "49.18%", "bb": "93%", "bbr": "Above Mid", "ttm": "0", "adr14": "6.95", "opvol": "9890", "callvol": "5649", "putvol": "4241"}, {"sym": "UBER", "price": "72.77", "chg": "+3.25%", "rs14": "48.3", "ivpct": "88%", "ivhv": "1.449025328631", "iv": "46.34%", "iv5d": "45.21%", "iv1m": "42.07%", "iv3m": "40.41%", "iv6m": "38.44%", "bb": "45%", "bbr": "Below Mid", "ttm": "0", "adr14": "2.18", "opvol": "40664", "callvol": "25078", "putvol": "15586"}, {"sym": "LYV", "price": "165.84", "chg": "+3.27%", "rs14": "61.47", "ivpct": "88%", "ivhv": "1.115838641189", "iv": "42.18%", "iv5d": "40.58%", "iv1m": "38.63%", "iv3m": "39.03%", "iv6m": "36.24%", "bb": "100%", "bbr": "Above Mid", "ttm": "0", "adr14": "5", "opvol": "4156", "callvol": "2716", "putvol": "1440"}, {"sym": "ADSK", "price": "225.81", "chg": "+3.37%", "rs14": "41.23", "ivpct": "92%", "ivhv": "1.1753361702128", "iv": "42.43%", "iv5d": "42.31%", "iv1m": "40.07%", "iv3m": "40.76%", "iv6m": "34.74%", "bb": "17%", "bbr": "New Above Lower", "ttm": "0", "adr14": "8.82", "opvol": "1082", "callvol": "762", "putvol": "320"}, {"sym": "ON", "price": "70.99", "chg": "+3.41%", "rs14": "68.58", "ivpct": "84%", "ivhv": "1.0961767895879", "iv": "60.65%", "iv5d": "58.94%", "iv1m": "55.81%", "iv3m": "54.03%", "iv6m": "52.97%", "bb": "106%", "bbr": "Above Upper", "ttm": "0", "adr14": "2.64", "opvol": "5396", "callvol": "4811", "putvol": "585"}, {"sym": "SHOP", "price": "114.69", "chg": "+3.52%", "rs14": "45.06", "ivpct": "92%", "ivhv": "1.4740224134481", "iv": "73.85%", "iv5d": "73.40%", "iv1m": "68.13%", "iv3m": "65.13%", "iv6m": "58.06%", "bb": "34%", "bbr": "Below Mid", "ttm": "On", "adr14": "5.72", "opvol": "24124", "callvol": "14827", "putvol": "9297"}, {"sym": "ZS", "price": "122.23", "chg": "+3.54%", "rs14": "31.98", "ivpct": "94%", "ivhv": "1.1852876859652", "iv": "66.10%", "iv5d": "64.35%", "iv1m": "58.09%", "iv3m": "58.21%", "iv6m": "49.53%", "bb": "9%", "bbr": "New Above Lower", "ttm": "0", "adr14": "7.6", "opvol": "13908", "callvol": "10484", "putvol": "3424"}, {"sym": "ALGN", "price": "179.54", "chg": "+3.70%", "rs14": "54.6", "ivpct": "85%", "ivhv": "1.3285817037537", "iv": "58.75%", "iv5d": "56.52%", "iv1m": "50.20%", "iv3m": "47.01%", "iv6m": "45.59%", "bb": "81%", "bbr": "Above Mid", "ttm": "On", "adr14": "6.99", "opvol": "434", "callvol": "205", "putvol": "229"}, {"sym": "PANW", "price": "161.51", "chg": "+3.71%", "rs14": "49.37", "ivpct": "92%", "ivhv": "1.0124941327075", "iv": "47.62%", "iv5d": "44.60%", "iv1m": "40.60%", "iv3m": "42.56%", "iv6m": "38.11%", "bb": "48%", "bbr": "Below Mid", "ttm": "0", "adr14": "7.72", "opvol": "28967", "callvol": "19989", "putvol": "8978"}, {"sym": "DASH", "price": "158.37", "chg": "+3.79%", "rs14": "48.04", "ivpct": "97%", "ivhv": "1.7108204216408", "iv": "67.47%", "iv5d": "65.52%", "iv1m": "60.16%", "iv3m": "58.82%", "iv6m": "51.19%", "bb": "60%", "bbr": "New Above Mid", "ttm": "0", "adr14": "6.9", "opvol": "4082", "callvol": "2781", "putvol": "1301"}, {"sym": "DDOG", "price": "109.51", "chg": "+3.93%", "rs14": "39.48", "ivpct": "98%", "ivhv": "1.5366881091618", "iv": "78.41%", "iv5d": "75.04%", "iv1m": "64.08%", "iv3m": "63.17%", "iv6m": "53.20%", "bb": "13%", "bbr": "New Above Lower", "ttm": "0", "adr14": "6.83", "opvol": "20229", "callvol": "9407", "putvol": "10822"}, {"sym": "ARM", "price": "155.15", "chg": "+4.18%", "rs14": "63.51", "ivpct": "90%", "ivhv": "0.95280826700182", "iv": "68.50%", "iv5d": "65.40%", "iv1m": "60.93%", "iv3m": "58.43%", "iv6m": "56.77%", "bb": "82%", "bbr": "Above Mid", "ttm": "0", "adr14": "9.22", "opvol": "53723", "callvol": "37718", "putvol": "16005"}, {"sym": "AKAM", "price": "95.2", "chg": "+4.21%", "rs14": "37.72", "ivpct": "97%", "ivhv": "0.99491540649798", "iv": "66.57%", "iv5d": "61.72%", "iv1m": "51.35%", "iv3m": "50.62%", "iv6m": "43.98%", "bb": "-5%", "bbr": "Below Lower", "ttm": "0", "adr14": "6.2", "opvol": "8453", "callvol": "4277", "putvol": "4176"}, {"sym": "PLTR", "price": "133.53", "chg": "+4.27%", "rs14": "40.56", "ivpct": "75%", "ivhv": "1.1455738297488", "iv": "63.56%", "iv5d": "62.84%", "iv1m": "56.48%", "iv3m": "56.49%", "iv6m": "55.41%", "bb": "13%", "bbr": "New Above Lower", "ttm": "0", "adr14": "7.66", "opvol": "526489", "callvol": "372882", "putvol": "153607"}, {"sym": "APO", "price": "108.87", "chg": "+4.40%", "rs14": "48.77", "ivpct": "88%", "ivhv": "1.3796210643633", "iv": "49.11%", "iv5d": "49.00%", "iv1m": "49.84%", "iv3m": "44.74%", "iv6m": "39.71%", "bb": "56%", "bbr": "New Above Mid", "ttm": "On", "adr14": "4.38", "opvol": "12237", "callvol": "5316", "putvol": "6921"}, {"sym": "BE", "price": "174.04", "chg": "+4.40%", "rs14": "62.83", "ivpct": "68%", "ivhv": "1.0522114149385", "iv": "115.72%", "iv5d": "112.40%", "iv1m": "110.50%", "iv3m": "114.98%", "iv6m": "116.76%", "bb": "99%", "bbr": "Above Mid", "ttm": "0", "adr14": "12.72", "opvol": "39926", "callvol": "17537", "putvol": "22389"}, {"sym": "CRM", "price": "172.43", "chg": "+4.53%", "rs14": "37.62", "ivpct": "68%", "ivhv": "1.1224776500639", "iv": "43.56%", "iv5d": "43.47%", "iv1m": "41.77%", "iv3m": "44.11%", "iv6m": "39.65%", "bb": "15%", "bbr": "New Above Lower", "ttm": "0", "adr14": "7.02", "opvol": "54296", "callvol": "40988", "putvol": "13308"}, {"sym": "EXPE", "price": "238.44", "chg": "+4.54%", "rs14": "54.84", "ivpct": "91%", "ivhv": "1.223250694169", "iv": "60.97%", "iv5d": "62.29%", "iv1m": "57.79%", "iv3m": "55.08%", "iv6m": "46.85%", "bb": "76%", "bbr": "New Above Mid", "ttm": "On", "adr14": "10.68", "opvol": "1666", "callvol": "830", "putvol": "836"}, {"sym": "CVNA", "price": "351.95", "chg": "+4.65%", "rs14": "60.75", "ivpct": "84%", "ivhv": "1.424375320458", "iv": "83.74%", "iv5d": "83.56%", "iv1m": "79.85%", "iv3m": "78.32%", "iv6m": "69.39%", "bb": "109%", "bbr": "New Above Upper", "ttm": "0", "adr14": "18.01", "opvol": "50563", "callvol": "32539", "putvol": "18024"}, {"sym": "FISV", "price": "58.74", "chg": "+4.72%", "rs14": "55.71", "ivpct": "93%", "ivhv": "1.9846310679612", "iv": "62.14%", "iv5d": "59.94%", "iv1m": "55.17%", "iv3m": "53.92%", "iv6m": "48.93%", "bb": "104%", "bbr": "New Above Upper", "ttm": "On", "adr14": "1.89", "opvol": "14495", "callvol": "12603", "putvol": "1892"}, {"sym": "KTOS", "price": "73.8", "chg": "+4.92%", "rs14": "44.84", "ivpct": "79%", "ivhv": "1.0272003532677", "iv": "80.46%", "iv5d": "80.03%", "iv1m": "79.21%", "iv3m": "80.66%", "iv6m": "74.90%", "bb": "40%", "bbr": "Below Mid", "ttm": "0", "adr14": "5.14", "opvol": "3922", "callvol": "2822", "putvol": "1100"}, {"sym": "HUT", "price": "69.36", "chg": "+4.96%", "rs14": "70.41", "ivpct": "70%", "ivhv": "0.98301526717557", "iv": "104.63%", "iv5d": "102.14%", "iv1m": "101.32%", "iv3m": "103.44%", "iv6m": "107.79%", "bb": "111%", "bbr": "Above Upper", "ttm": "0", "adr14": "4.45", "opvol": "20882", "callvol": "14285", "putvol": "6597"}, {"sym": "BX", "price": "120.55", "chg": "+4.98%", "rs14": "59.48", "ivpct": "83%", "ivhv": "1.0933236574746", "iv": "45.30%", "iv5d": "46.32%", "iv1m": "48.08%", "iv3m": "43.38%", "iv6m": "37.82%", "bb": "110%", "bbr": "New Above Upper", "ttm": "0", "adr14": "4.04", "opvol": "13953", "callvol": "9392", "putvol": "4561"}, {"sym": "INTU", "price": "368.48", "chg": "+5.00%", "rs14": "33.8", "ivpct": "93%", "ivhv": "1.1031920903955", "iv": "54.41%", "iv5d": "54.58%", "iv1m": "48.92%", "iv3m": "49.82%", "iv6m": "40.17%", "bb": "7%", "bbr": "New Above Lower", "ttm": "0", "adr14": "18.86", "opvol": "8771", "callvol": "5403", "putvol": "3368"}, {"sym": "OKLO", "price": "52.85", "chg": "+5.17%", "rs14": "47.83", "ivpct": "32%", "ivhv": "1.3097406340058", "iv": "96.15%", "iv5d": "94.66%", "iv1m": "91.26%", "iv3m": "96.07%", "iv6m": "100.94%", "bb": "56%", "bbr": "New Above Mid", "ttm": "0", "adr14": "3.68", "opvol": "41942", "callvol": "32850", "putvol": "9092"}, {"sym": "ARES", "price": "105.66", "chg": "+5.18%", "rs14": "46.55", "ivpct": "86%", "ivhv": "1.1212409062565", "iv": "54.00%", "iv5d": "56.29%", "iv1m": "58.27%", "iv3m": "52.34%", "iv6m": "44.86%", "bb": "59%", "bbr": "New Above Mid", "ttm": "On", "adr14": "5.02", "opvol": "3659", "callvol": "2772", "putvol": "887"}, {"sym": "DELL", "price": "187.27", "chg": "+5.33%", "rs14": "67.92", "ivpct": "72%", "ivhv": "1.0823728478132", "iv": "55.02%", "iv5d": "51.89%", "iv1m": "51.37%", "iv3m": "53.40%", "iv6m": "50.84%", "bb": "92%", "bbr": "Above Mid", "ttm": "0", "adr14": "8.85", "opvol": "50228", "callvol": "33484", "putvol": "16744"}, {"sym": "LMND", "price": "57.46", "chg": "+5.53%", "rs14": "45.16", "ivpct": "70%", "ivhv": "1.2586097835254", "iv": "89.16%", "iv5d": "88.81%", "iv1m": "84.02%", "iv3m": "86.80%", "iv6m": "83.49%", "bb": "23%", "bbr": "Below Mid", "ttm": "0", "adr14": "3.78", "opvol": "5650", "callvol": "4132", "putvol": "1518"}, {"sym": "SNPS", "price": "414.56", "chg": "+5.69%", "rs14": "50.8", "ivpct": "67%", "ivhv": "1.2245958795563", "iv": "45.53%", "iv5d": "46.04%", "iv1m": "47.19%", "iv3m": "49.32%", "iv6m": "46.69%", "bb": "59%", "bbr": "New Above Mid", "ttm": "0", "adr14": "15", "opvol": "2791", "callvol": "1837", "putvol": "954"}, {"sym": "DAVE", "price": "196.01", "chg": "+5.72%", "rs14": "55.28", "ivpct": "44%", "ivhv": "1.2059895570153", "iv": "71.81%", "iv5d": "70.54%", "iv1m": "71.76%", "iv3m": "75.52%", "iv6m": "73.95%", "bb": "61%", "bbr": "New Above Mid", "ttm": "0", "adr14": "11.46", "opvol": "1363", "callvol": "1009", "putvol": "354"}, {"sym": "FIS", "price": "45.85", "chg": "+5.72%", "rs14": "42.49", "ivpct": "96%", "ivhv": "1.4144889840881", "iv": "46.12%", "iv5d": "45.56%", "iv1m": "41.88%", "iv3m": "40.39%", "iv6m": "36.08%", "bb": "29%", "bbr": "New Above Lower", "ttm": "0", "adr14": "1.71", "opvol": "2246", "callvol": "2094", "putvol": "152"}, {"sym": "ACN", "price": "190.11", "chg": "+5.89%", "rs14": "41.95", "ivpct": "72%", "ivhv": "1.1380452164323", "iv": "41.05%", "iv5d": "40.92%", "iv1m": "42.87%", "iv3m": "43.49%", "iv6m": "38.70%", "bb": "25%", "bbr": "New Above Lower", "ttm": "On", "adr14": "6.85", "opvol": "5476", "callvol": "3813", "putvol": "1663"}, {"sym": "ADBE", "price": "238.69", "chg": "+5.92%", "rs14": "43.18", "ivpct": "61%", "ivhv": "1.0177570326114", "iv": "40.45%", "iv5d": "40.31%", "iv1m": "39.52%", "iv3m": "43.59%", "iv6m": "39.58%", "bb": "39%", "bbr": "New Above Lower", "ttm": "0", "adr14": "7.96", "opvol": "42010", "callvol": "24125", "putvol": "17885"}, {"sym": "APP", "price": "414.71", "chg": "+5.96%", "rs14": "48.93", "ivpct": "90%", "ivhv": "1.3062458852154", "iv": "91.71%", "iv5d": "87.23%", "iv1m": "78.71%", "iv3m": "80.06%", "iv6m": "71.70%", "bb": "51%", "bbr": "New Above Mid", "ttm": "0", "adr14": "26.54", "opvol": "32457", "callvol": "23563", "putvol": "8894"}, {"sym": "CRWD", "price": "401.65", "chg": "+5.97%", "rs14": "49.06", "ivpct": "70%", "ivhv": "0.94436614396373", "iv": "49.99%", "iv5d": "48.46%", "iv1m": "46.29%", "iv3m": "48.64%", "iv6m": "44.75%", "bb": "48%", "bbr": "Below Mid", "ttm": "0", "adr14": "19.74", "opvol": "38104", "callvol": "22703", "putvol": "15401"}, {"sym": "KKR", "price": "96.69", "chg": "+6.00%", "rs14": "58.63", "ivpct": "80%", "ivhv": "1.283644338118", "iv": "48.25%", "iv5d": "48.97%", "iv1m": "51.59%", "iv3m": "47.91%", "iv6m": "42.60%", "bb": "121%", "bbr": "New Above Upper", "ttm": "On", "adr14": "3.57", "opvol": "10667", "callvol": "7274", "putvol": "3393"}, {"sym": "DOCN", "price": "80.14", "chg": "+6.02%", "rs14": "50.82", "ivpct": "99%", "ivhv": "1.2230070268961", "iv": "99.74%", "iv5d": "97.46%", "iv1m": "87.04%", "iv3m": "78.37%", "iv6m": "70.18%", "bb": "27%", "bbr": "Below Mid", "ttm": "0", "adr14": "6.96", "opvol": "4840", "callvol": "3071", "putvol": "1769"}, {"sym": "CRSP", "price": "54.45", "chg": "+6.31%", "rs14": "60.77", "ivpct": "70%", "ivhv": "1.1774952198853", "iv": "64.16%", "iv5d": "68.44%", "iv1m": "63.67%", "iv3m": "61.47%", "iv6m": "63.55%", "bb": "111%", "bbr": "New Above Upper", "ttm": "0", "adr14": "2.19", "opvol": "3741", "callvol": "3126", "putvol": "615"}, {"sym": "TEAM", "price": "60.77", "chg": "+6.33%", "rs14": "34.28", "ivpct": "99%", "ivhv": "1.6709805593452", "iv": "97.65%", "iv5d": "94.00%", "iv1m": "83.14%", "iv3m": "76.74%", "iv6m": "65.31%", "bb": "16%", "bbr": "New Above Lower", "ttm": "0", "adr14": "4.08", "opvol": "11446", "callvol": "8009", "putvol": "3437"}, {"sym": "NOW", "price": "88.51", "chg": "+6.64%", "rs14": "32.38", "ivpct": "99%", "ivhv": "1.276", "iv": "71.19%", "iv5d": "66.79%", "iv1m": "57.19%", "iv3m": "52.66%", "iv6m": "45.28%", "bb": "8%", "bbr": "New Above Lower", "ttm": "0", "adr14": "5.34", "opvol": "99025", "callvol": "69019", "putvol": "30006"}, {"sym": "LASR", "price": "69.9", "chg": "+6.93%", "rs14": "59.2", "ivpct": "98%", "ivhv": "1.0586876155268", "iv": "114.74%", "iv5d": "109.81%", "iv1m": "102.18%", "iv3m": "95.39%", "iv6m": "84.44%", "bb": "72%", "bbr": "Above Mid", "ttm": "0", "adr14": "5.29", "opvol": "2131", "callvol": "1388", "putvol": "743"}, {"sym": "WDAY", "price": "120.6", "chg": "+7.20%", "rs14": "39.58", "ivpct": "96%", "ivhv": "1.1438990735265", "iv": "58.45%", "iv5d": "57.37%", "iv1m": "52.84%", "iv3m": "50.56%", "iv6m": "42.60%", "bb": "24%", "bbr": "New Above Lower", "ttm": "0", "adr14": "5.95", "opvol": "5930", "callvol": "4199", "putvol": "1731"}, {"sym": "CDNS", "price": "285.84", "chg": "+7.60%", "rs14": "51.05", "ivpct": "98%", "ivhv": "1.3872712723393", "iv": "52.14%", "iv5d": "49.88%", "iv1m": "48.70%", "iv3m": "46.03%", "iv6m": "40.68%", "bb": "64%", "bbr": "New Above Mid", "ttm": "On", "adr14": "9.91", "opvol": "2524", "callvol": "1590", "putvol": "934"}, {"sym": "SNDK", "price": "926.91", "chg": "+8.82%", "rs14": "72.03", "ivpct": "98%", "ivhv": "1.1741316639742", "iv": "118.04%", "iv5d": "107.78%", "iv1m": "100.12%", "iv3m": "102.48%", "iv6m": "102.64%", "bb": "108%", "bbr": "Above Upper", "ttm": "0", "adr14": "51.71", "opvol": "150576", "callvol": "67144", "putvol": "83432"}, {"sym": "CRDO", "price": "132.68", "chg": "+10.95%", "rs14": "66.95", "ivpct": "58%", "ivhv": "0.9267055771725", "iv": "90.61%", "iv5d": "85.10%", "iv1m": "85.70%", "iv3m": "91.84%", "iv6m": "91.03%", "bb": "124%", "bbr": "New Above Upper", "ttm": "0", "adr14": "7.29", "opvol": "34473", "callvol": "25363", "putvol": "9110"}, {"sym": "ORCL", "price": "153.39", "chg": "+11.08%", "rs14": "55.39", "ivpct": "75%", "ivhv": "1.0378645932107", "iv": "54.95%", "iv5d": "52.22%", "iv1m": "52.15%", "iv3m": "60.41%", "iv6m": "55.86%", "bb": "79%", "bbr": "New Above Mid", "ttm": "0", "adr14": "6.2", "opvol": "441707", "callvol": "342533", "putvol": "99174"}];

// ── STATE
let positions=[],selectedIds=new Set(),acctSrc='mock',activeWlSym='SPY';
let wlExpanded=false,scanData=[],volData=null,vsView_='avg';
let alertRules=[],alertsMaster=true;
let refreshTimer=null,refreshInterval=300,refreshCD=0;
let sortState={pos:{col:'',dir:1},scan:{col:'',dir:1},sel:{col:'',dir:1}};
let focusZ=100,dragTarget=null,dragOX=0,dragOY=0,resizeTarget=null,resizeSX,resizeSY,resizeSW,resizeSH;

// ── DEFAULT TILE POSITIONS (3840×1080 ultrawide)
const DEF={
  'tile-wl':    {l:0,   t:0,  w:240,  h:560},
  'tile-pos':   {l:244, t:0,  w:880,  h:370},
  'tile-scan':  {l:1128,t:0,  w:960,  h:560},
  'tile-vol':   {l:2092,t:0,  w:820,  h:560},
  'tile-sel':   {l:244, t:374,w:880,  h:210},
  'tile-ticket':{l:1128,t:564,w:440,  h:218},
  'tile-chart': {l:1572,t:564,w:1340, h:218},
};
function applyDef(){
  for(const[id,p]of Object.entries(DEF)){
    const el=document.getElementById(id);if(!el)continue;
    el.style.cssText=`left:${p.l}px;top:${p.t}px;width:${p.w}px;height:${p.h}px`;
  }
}
function resetPos(id){
  const p=DEF[id];if(!p)return;
  const el=document.getElementById(id);
  el.style.cssText=`left:${p.l}px;top:${p.t}px;width:${p.w}px;height:${p.h}px`;
  el.classList.remove('minimized');
}
function focusTile(id){
  document.querySelectorAll('.tile').forEach(t=>t.classList.remove('focused'));
  const el=document.getElementById(id);el.classList.add('focused');el.style.zIndex=++focusZ;
}
function toggleMin(id){document.getElementById(id).classList.toggle('minimized')}

function tileDown(e,id){
  e.preventDefault();focusTile(id);
  dragTarget=document.getElementById(id);
  const r=dragTarget.getBoundingClientRect();dragOX=e.clientX-r.left;dragOY=e.clientY-r.top;
}
function resizeDown(e,id){
  e.preventDefault();e.stopPropagation();
  resizeTarget=document.getElementById(id);
  resizeSX=e.clientX;resizeSY=e.clientY;
  const r=resizeTarget.getBoundingClientRect();resizeSW=r.width;resizeSH=r.height;
}
document.addEventListener('mousemove',e=>{
  if(dragTarget){dragTarget.style.left=(e.clientX-dragOX)+'px';dragTarget.style.top=Math.max(0,e.clientY-dragOY)+'px';}
  if(resizeTarget){
    resizeTarget.style.width=Math.max(160,resizeSW+(e.clientX-resizeSX))+'px';
    resizeTarget.style.height=Math.max(60,resizeSH+(e.clientY-resizeSY))+'px';
    if(resizeTarget.id==='tile-vol'&&volData)vsView(vsView_);
  }
});
document.addEventListener('mouseup',()=>{dragTarget=null;resizeTarget=null;});

// ── THEME
function setTheme(t,dot){
  document.body.setAttribute('data-theme',t);
  document.querySelectorAll('.theme-dot').forEach(d=>d.classList.remove('active'));
  dot.classList.add('active');
}

// ── WATCHLIST
function toggleWl(){
  wlExpanded=!wlExpanded;
  const tile=document.getElementById('tile-wl');
  const hc=document.getElementById('wl-hdr-c');
  const hf=document.getElementById('wl-hdr-f');
  const body=document.getElementById('wl-body');
  const btn=document.getElementById('wlBtn');
  if(wlExpanded){
    tile.style.width='1820px';tile.style.height='560px';tile.style.zIndex=++focusZ;
    hc.style.display='none';hf.style.display='grid';
    body.className='tile-body wl-full-body';
    btn.textContent='⇔ COLLAPSE';
  }else{
    tile.style.width='240px';hc.style.display='grid';hf.style.display='none';
    body.className='tile-body wl-compact-body';
    btn.textContent='⇔ EXPAND';
  }
  renderWl();
}

function renderWl(){
  const filt=(document.getElementById('wl-filter')?.value||'').toUpperCase();
  const items=filt?WL_DATA.filter(r=>r.sym.includes(filt)):WL_DATA;
  const body=document.getElementById('wl-body');
  if(!body)return;
  if(wlExpanded){
    body.innerHTML=items.map(r=>{
      const pos=!r.chg.startsWith('-');
      const chgCls=pos?'wl-pos':'wl-neg';
      const ttm=r.ttm==='On'?'<span class="ttm-on">ON</span>':'<span class="ttm-off">—</span>';
      const bbCls=r.bbr&&r.bbr.toLowerCase().includes('below')?'bad':r.bbr&&r.bbr.toLowerCase().includes('above')?'ok':'';
      const ivhv=parseFloat(r.ivhv)||0;
      return`<div class="wl-row${r.sym===activeWlSym?' active':''}" onclick="loadWlSym('${r.sym}')">
        <span class="wl-sym">${r.sym}</span>
        <span class="wl-num">${r.price||'—'}</span>
        <span class="wl-num ${chgCls}">${r.chg||'—'}</span>
        <span class="wl-num">${r.rs14||'—'}</span>
        <span class="wl-num">${r.ivpct||'—'}</span>
        <span class="wl-num">${ivhv?ivhv.toFixed(2):'—'}</span>
        <span class="wl-num">${r.iv||'—'}</span>
        <span class="wl-num">${r.iv5d||'—'}</span>
        <span class="wl-num">${r.iv1m||'—'}</span>
        <span class="wl-num">${r.iv3m||'—'}</span>
        <span class="wl-num">${r.iv6m||'—'}</span>
        <span class="wl-num">${r.bb||'—'}</span>
        <span class="wl-num ${bbCls}" style="font-size:9px">${r.bbr||'—'}</span>
        <span class="wl-num">${ttm}</span>
        <span class="wl-num">${r.adr14||'—'}</span>
        <span class="wl-num">${r.opvol||'—'}</span>
        <span class="wl-num">${r.callvol||'—'}</span>
        <span class="wl-num">${r.putvol||'—'}</span>
      </div>`;
    }).join('');
  }else{
    body.innerHTML=items.map(r=>{
      const pos=!r.chg.startsWith('-');
      return`<div class="wl-row${r.sym===activeWlSym?' active':''}" onclick="loadWlSym('${r.sym}')">
        <span class="wl-sym">${r.sym}</span>
        <span class="wl-num">${r.price||'—'}</span>
        <span class="wl-num ${pos?'wl-pos':'wl-neg'}">${r.chg||'—'}</span>
      </div>`;
    }).join('');
  }
}

async function loadWlSym(sym){
  activeWlSym=sym;
  document.getElementById('sSym').value=sym;
  document.getElementById('m-sym').textContent=sym;
  renderWl();log('Loading '+sym+'…');
  await getQuote(sym);await loadExpFilter(sym);
}

// ── SORT
function srt(tbl,col){
  const s=sortState[tbl];
  if(s.col===col)s.dir*=-1;else{s.col=col;s.dir=-1;}
  const hdrMap={pos:'posHdr',scan:'scanHdr',sel:'selHdr'};
  const hid=hdrMap[tbl];
  if(hid){document.querySelectorAll('#'+hid+' th').forEach(th=>{
    th.classList.remove('sa','sd');
    if(th.dataset.col===col)th.classList.add(s.dir>0?'sa':'sd');
  });}
  if(tbl==='pos')renderPos();
  if(tbl==='scan')renderScan(scanData);
  if(tbl==='sel')renderSel();
}
function sortRows(rows,tbl){
  const{col,dir}=sortState[tbl];if(!col)return rows;
  return[...rows].sort((a,b)=>{
    let av=a[col],bv=b[col];
    if(av==null)av=dir>0?-Infinity:Infinity;if(bv==null)bv=dir>0?-Infinity:Infinity;
    if(typeof av==='string')return av.localeCompare(bv)*dir;
    return(parseFloat(av)-parseFloat(bv))*dir;
  });
}

// ── FORMAT
const f$=v=>v==null?'—':'$'+Number(v).toFixed(2);
const fN=(v,d=2)=>v==null?'—':Number(v).toFixed(d);
const fPct=v=>v==null?'—':(Number(v)*100).toFixed(2)+'%';
const fIV=v=>v==null?'—':(Number(v)*100).toFixed(2)+'%';
const cv=v=>Number(v)>=0?'ok':'bad';

// ── API
async function apiFetch(path){
  const r=await fetch(API+path);
  if(!r.ok){const t=await r.text();throw new Error(t||r.status);}
  return r.json();
}

// ── ACCOUNT
function setAcct(src){
  acctSrc=src;
  document.getElementById('abMock').className='tbtn'+(src==='mock'?' active':'');
  document.getElementById('abTasty').className='tbtn'+(src==='tasty'?' active':'');
  loadPos();
}

async function loadPos(){
  const err=document.getElementById('posErr');err.style.display='none';
  try{
    const d=await apiFetch('/account/'+acctSrc);
    positions=d.positions||[];
    renderMetrics(d.limit_summary,d.source);
    renderPos();
    document.getElementById('tb-pos').textContent=positions.length;
    log('Positions: '+positions.length+' legs ('+d.source+')','ok');
  }catch(e){err.textContent=e.message;err.style.display='block';log('Pos error: '+e.message,'bad');}
}

function renderMetrics(ls,src){
  if(!ls)return;
  document.getElementById('m-netliq').textContent=f$(ls.net_liq);
  document.getElementById('m-limit').textContent=f$(ls.max_limit);
  document.getElementById('m-used').textContent=f$(ls.used_short_value);
  document.getElementById('m-room').textContent=f$(ls.remaining_room);
  const pct=Number(ls.used_pct||0)*100;
  const el=document.getElementById('m-usedpct');
  el.textContent=pct.toFixed(1)+'%';el.className='val '+(pct>80?'bad':pct>60?'warn':'ok');
  document.getElementById('m-src').textContent=src||'—';
}

function renderPos(){
  const rows=sortRows(positions,'pos');
  const body=document.getElementById('posBody');
  if(!rows.length){body.innerHTML='<tr><td colspan="12" class="empty-msg">No positions</td></tr>';return;}
  const groups={};
  rows.forEach(p=>{const k=p.underlying+'||'+(p.group||'');if(!groups[k])groups[k]=[];groups[k].push(p);});
  let html='';
  for(const[k,rs]of Object.entries(groups)){
    const[u,g]=k.split('||');
    html+=`<tr class="gh"><td colspan="12">${u}${g?' — '+g:''}</td></tr>`;
    rs.forEach(r=>{
      const chk=selectedIds.has(r.id)?'checked':'';
      html+=`<tr>
        <td><input type="checkbox" data-id="${r.id}" ${chk} onchange="toggleRow(this)"/></td>
        <td><b>${r.underlying}</b></td>
        <td class="${r.display_qty<0?'bad':'ok'}">${r.display_qty}</td>
        <td class="${r.option_type==='C'?'accent':'bad'}">${r.option_type==='C'?'CALL':'PUT'}</td>
        <td class="muted">${r.expiration}</td>
        <td>${r.strike}</td>
        <td>${f$(r.mark)}</td>
        <td>${f$(r.trade_price)}</td>
        <td class="${cv(r.pnl_open)}">${f$(r.pnl_open)}</td>
        <td>${f$(r.short_value)}</td>
        <td>${f$(r.long_cost)}</td>
        <td class="warn">${f$(r.limit_impact)}</td>
      </tr>`;
    });
  }
  body.innerHTML=html;
}

function toggleRow(chk){
  if(chk.checked)selectedIds.add(chk.dataset.id);else selectedIds.delete(chk.dataset.id);
  refreshTotals();
}

function renderSel(){
  const sel=sortRows(positions.filter(p=>selectedIds.has(p.id)),'sel');
  document.getElementById('selBody').innerHTML=sel.length?sel.map(r=>`<tr>
    <td>${r.underlying}</td>
    <td class="${r.option_type==='C'?'accent':'bad'}">${r.option_type==='C'?'CALL':'PUT'}</td>
    <td class="${r.display_qty<0?'bad':'ok'}">${r.display_qty}</td>
    <td>${r.strike}</td>
    <td class="muted">${r.expiration}</td>
    <td>${f$(r.mark)}</td>
    <td class="${cv(r.pnl_open)}">${f$(r.pnl_open)}</td>
    <td>${f$(r.short_value)}</td>
  </tr>`).join(''):'<tr><td colspan="8" class="empty-msg">Select rows in Open Positions</td></tr>';
}

function refreshTotals(){
  const sel=positions.filter(p=>selectedIds.has(p.id));
  const sv=sel.reduce((a,r)=>a+Number(r.short_value||0),0);
  const lc=sel.reduce((a,r)=>a+Number(r.long_cost||0),0);
  const pnl=sel.reduce((a,r)=>a+Number(r.pnl_open||0),0);
  const imp=sel.reduce((a,r)=>a+Number(r.limit_impact||0),0);
  const set=(id,v,cls)=>{const e=document.getElementById(id);if(e){e.textContent=v;e.className='tv '+(cls||'');}};
  set('st-legs',sel.length);set('tb-legs',sel.length);
  set('st-pnl',f$(pnl),cv(pnl));set('tb-pnl',f$(pnl),cv(pnl));
  set('st-sv',f$(sv));set('tb-sv',f$(sv));
  set('st-lc',f$(lc));set('tb-lc',f$(lc));
  set('st-imp',f$(imp),'warn');set('tb-imp',f$(imp),'warn');
  renderSel();
}

// ── QUOTE
async function getQuote(sym){
  sym=(sym||document.getElementById('sSym')?.value||'SPY').toUpperCase();
  try{
    const data=await apiFetch('/quote/schwab?symbol='+encodeURIComponent(sym));
    const payload=data[sym]||data[sym.toUpperCase()]||{};
    const q=payload.quote||payload;
    const last=Number(q.lastPrice||q.mark||q.closePrice||0);
    const chg=Number(q.netChange||0);
    const pct=q.closePrice?chg/Number(q.closePrice):0;
    document.getElementById('m-sym').textContent=sym;
    document.getElementById('m-price').textContent=last?'$'+last.toFixed(2):'—';
    const ce=document.getElementById('m-chg');
    ce.textContent=(chg>=0?'+':'')+chg.toFixed(2)+' ('+(pct*100).toFixed(2)+'%)';
    ce.className='val '+(chg>=0?'ok':'bad');
    checkAlerts({symbol:sym,price:last});return last;
  }catch(e){log('Quote err '+sym+': '+e.message,'bad');}
}

// ── CHAIN
async function loadExpFilter(sym){
  sym=sym||document.getElementById('sSym').value.trim().toUpperCase()||'SPY';
  try{
    const d=await apiFetch('/chain?symbol='+encodeURIComponent(sym));
    const sel=document.getElementById('sExp');
    const exps=(d.expirations||[]).slice(0,7);
    sel.innerHTML='<option value="all">All (next 7)</option>'+exps.map(e=>`<option value="${e}">${e}</option>`).join('');
    if(d.active_chain_source)document.getElementById('m-src').textContent=d.active_chain_source;
  }catch(e){log('Chain filter err: '+e.message,'bad');}
}

async function loadChain(){
  const sym=document.getElementById('sSym').value.trim().toUpperCase()||'SPY';
  log('Refreshing chain for '+sym+'…');
  try{
    const d=await apiFetch('/refresh/symbol?symbol='+encodeURIComponent(sym));
    document.getElementById('m-src').textContent=d.active_chain_source||'—';
    await loadExpFilter(sym);
    log('Chain refreshed: '+sym+' ('+d.contract_count+' contracts)','ok');
  }catch(e){log('Chain refresh err: '+e.message,'bad');}
}

// ── SCANNER
async function runScan(){
  const sym=document.getElementById('sSym').value.trim().toUpperCase()||'SPY';
  const risk=document.getElementById('sRisk').value||600;
  const side=document.getElementById('sSide').value;
  const exp=document.getElementById('sExp').value;
  const sort=document.getElementById('sSort').value;
  const max=document.getElementById('sMax').value||500;
  const err=document.getElementById('scanErr');
  err.style.display='none';
  document.getElementById('scanBody').innerHTML='<tr><td colspan="14" class="spinner">Scanning…</td></tr>';
  document.getElementById('scanInfo').textContent='';
  log('Scanning '+sym+' ('+side+', $'+risk+', sort:'+sort+')…');
  try{
    const qs=new URLSearchParams({symbol:sym,total_risk:risk,side,expiration:exp,sort_by:sort,max_results:max});
    const d=await apiFetch('/scan/live?'+qs);
    scanData=d.items||[];
    renderScan(scanData);
    document.getElementById('scanInfo').textContent=scanData.length+' results';
    document.getElementById('tb-scan').textContent=scanData.length;
    if(d.active_chain_source)document.getElementById('m-src').textContent=d.active_chain_source;
    log('Scan: '+scanData.length+' candidates','ok');
    loadVolSurface(sym);
  }catch(e){
    err.textContent=e.message;err.style.display='block';
    document.getElementById('scanBody').innerHTML='';
    log('Scan err: '+e.message,'bad');
  }
}

function renderScan(items){
  const rows=sortRows(items,'scan');
  const body=document.getElementById('scanBody');
  if(!rows.length){body.innerHTML='<tr><td colspan="14" class="empty-msg">No results</td></tr>';return;}
  body.innerHTML=rows.map(r=>{
    const isC=r.option_side==='call';
    const rs=Number(r.richness_score||0);
    const rsCls=rs>=0.7?'ok':rs>=0.4?'':'muted';
    return`<tr style="border-left:2px solid ${isC?'var(--accent2)':'var(--danger)'}">
      <td class="muted">${r.expiration}</td>
      <td><span class="sb ${r.option_side}">${r.option_side.toUpperCase()}</span></td>
      <td>${r.short_strike}</td>
      <td>${r.long_strike}</td>
      <td class="muted">${r.width}</td>
      <td class="muted">${r.quantity}</td>
      <td class="ok">${f$(r.net_credit)}</td>
      <td class="muted">${f$(r.gross_defined_risk)}</td>
      <td class="bad">${f$(r.max_loss)}</td>
      <td>${fPct(r.credit_pct_risk)}</td>
      <td class="muted">${fN(r.short_delta,4)}</td>
      <td class="muted">${fIV(r.short_iv)}</td>
      <td class="${rsCls}">${fN(r.richness_score,4)}</td>
      <td class="warn">${f$(r.limit_impact)}</td>
    </tr>`;
  }).join('');
}

function clearScan(){
  scanData=[];
  document.getElementById('scanBody').innerHTML='<tr><td colspan="14" class="empty-msg">Configure filters and press SCAN</td></tr>';
  document.getElementById('scanInfo').textContent='';
  document.getElementById('tb-scan').textContent='0';
}

// ── VOL SURFACE
async function loadVolSurface(sym){
  sym=sym||document.getElementById('sSym').value.trim().toUpperCase()||'SPY';
  log('Loading vol surface for '+sym+'…');
  try{
    const d=await apiFetch('/vol/surface?symbol='+encodeURIComponent(sym)+'&max_expirations=7&strike_count=25');
    volData=d;
    renderRrow(d);
    vsView(vsView_);
    log('Vol surface OK: '+sym+' ('+d.count+' contracts)','ok');
  }catch(e){
    log('Vol surface err: '+e.message,'bad');
    document.getElementById('volPlot').innerHTML='<div class="error-msg">Vol surface error: '+e.message+'</div>';
  }
}

function renderRrow(d){
  const rr=document.getElementById('volRrow');
  if(!d.expirations||!d.expirations.length){rr.innerHTML='<span class="muted" style="font-size:10px">No data</span>';return;}
  const rs=d.richness_scores||{};
  const sorted=[...d.expirations].sort((a,b)=>(rs[b]?.richness_score||0)-(rs[a]?.richness_score||0));
  rr.innerHTML=sorted.map(e=>{
    const r=rs[e]||{};
    const iv=r.avg_iv!=null?(r.avg_iv*100).toFixed(1)+'%':'—';
    const sc=r.richness_score!=null?Number(r.richness_score).toFixed(4):'—';
    const skew=r.put_call_skew_near_spot;
    return`<div class="rcard" onclick="document.getElementById('sExp').value='${e}'" title="Click to filter scanner to this exp">
      <div style="font-size:9px;color:var(--muted)">${e}</div>
      <div style="font-size:12px;font-weight:600">${iv}</div>
      <div style="font-size:9px;color:var(--warn)">Score ${sc}</div>
      ${skew!=null?`<div style="font-size:9px;color:var(--muted)">Skew ${skew>=0?'+':''}${(skew*100).toFixed(2)}%</div>`:''}
    </div>`;
  }).join('');
}

const CS=[[0,'#0a1628'],[0.15,'#0e4d7a'],[0.30,'#1a6a4a'],[0.50,'#2a8a40'],[0.65,'#b07800'],[0.80,'#c94040'],[1,'#ff2828']];

function vsView(view){
  vsView_=view;
  ['avg','call','put','skew','3d'].forEach(v=>{
    const b=document.getElementById('vs-'+v);
    if(b)b.className='tbtn sm'+(v===view?' active':'');
  });
  if(!volData||!volData.expirations||!volData.expirations.length){
    document.getElementById('volPlot').innerHTML='<div class="empty-msg">Load a symbol to populate vol surface</div>';return;
  }
  const exps=volData.expirations,strikes=volData.strikes;
  let matrix;
  if(view==='call')matrix=volData.call_iv_matrix||volData.avg_iv_matrix;
  else if(view==='put')matrix=volData.put_iv_matrix||volData.avg_iv_matrix;
  else if(view==='skew')matrix=volData.skew_matrix||volData.avg_iv_matrix;
  else matrix=volData.avg_iv_matrix||volData.iv_matrix;
  if(!matrix||!matrix.length){document.getElementById('volPlot').innerHTML='<div class="empty-msg">No data</div>';return;}
  const z=matrix.map(row=>row.map(v=>v==null?null:Number(v)*100));
  const flat=z.flat().filter(v=>v!=null);
  if(!flat.length){document.getElementById('volPlot').innerHTML='<div class="empty-msg">All null</div>';return;}
  const el=document.getElementById('volPlot');
  const pw=el.parentElement.clientWidth-10;
  const ph=el.parentElement.clientHeight-80;
  if(view==='3d'){
    Plotly.react(el,[{
      type:'surface',x:strikes,y:exps.map((_,i)=>i),z,colorscale:CS,showscale:true,opacity:0.92,
      contours:{z:{show:true,usecolormap:true,highlightcolor:'#58a6ff',project:{z:true}}},
      colorbar:{tickfont:{color:'#7a92a8',size:9},thickness:10,len:0.8}
    }],{
      paper_bgcolor:'rgba(0,0,0,0)',font:{color:'#7a92a8',family:'JetBrains Mono',size:10},
      margin:{l:0,r:0,t:10,b:0},width:pw,height:Math.max(280,ph),
      scene:{
        xaxis:{title:'Strike',gridcolor:'#1e2d3d',tickfont:{size:9}},
        yaxis:{title:'',ticktext:exps,tickvals:exps.map((_,i)=>i),gridcolor:'#1e2d3d',tickfont:{size:9}},
        zaxis:{title:'IV%',gridcolor:'#1e2d3d',tickfont:{size:9}},
        bgcolor:'rgba(13,17,23,0.8)'
      }
    },{responsive:false,displayModeBar:false});
  }else{
    const title=view==='skew'?'Put−Call Skew (%)':'IV (%)';
    Plotly.react(el,[{
      type:'heatmap',x:strikes,y:exps.map((_,i)=>i),z,colorscale:CS,showscale:true,zsmooth:'best',
      colorbar:{title:{text:title,font:{size:9,color:'#7a92a8'}},tickfont:{color:'#7a92a8',size:9},thickness:10,len:0.9},
    }],{
      paper_bgcolor:'rgba(0,0,0,0)',plot_bgcolor:'rgba(13,17,23,0.9)',
      font:{color:'#7a92a8',family:'JetBrains Mono',size:10},
      margin:{l:80,r:20,t:20,b:60},width:pw,height:Math.max(220,ph),
      xaxis:{title:'Strike',gridcolor:'#1e2d3d',tickfont:{size:9},color:'#7a92a8'},
      yaxis:{ticktext:exps,tickvals:exps.map((_,i)=>i),gridcolor:'#1e2d3d',tickfont:{size:9},color:'#7a92a8'},
    },{responsive:false,displayModeBar:false});
  }
}

// ── ALERTS
function showModal(id){document.getElementById(id).classList.add('show');}
function hideModal(id){document.getElementById(id).classList.remove('show');}

function addAlert(){
  const sym=(document.getElementById('al-sym').value||'').toUpperCase().trim();
  const field=document.getElementById('al-field').value;
  const op=document.getElementById('al-op').value;
  const val=parseFloat(document.getElementById('al-val').value);
  if(!sym||isNaN(val)){log('Alert: fill all fields','warn');return;}
  alertRules.push({id:Date.now(),sym,field,op,val,active:true,triggered:false});
  document.getElementById('tb-alerts').textContent=alertRules.filter(a=>a.active).length;
  renderAlerts();log('Alert added: '+sym+' '+field+' '+op+' '+val,'ok');
}

function renderAlerts(){
  const el=document.getElementById('alertList');
  if(!alertRules.length){el.innerHTML='<div class="empty-msg">No alerts set</div>';return;}
  const opL={lt:'<',lte:'≤',eq:'=',gte:'≥',gt:'>'};
  const fL={price:'Price',iv_pct:'IV%',credit_pct_risk:'Cr%Risk',short_delta:'Sht Δ',used_pct:'Used%',pnl_open:'P/L'};
  el.innerHTML=alertRules.map(a=>`
    <div class="ar">
      <div class="adot ${a.active?'on':'off'}"></div>
      <input type="checkbox" ${a.active?'checked':''} onchange="tglAlert(${a.id},this.checked)"/>
      <span>${a.sym} — ${fL[a.field]||a.field} ${opL[a.op]||a.op} ${a.val}</span>
      ${a.triggered?'<span style="color:var(--warn);font-size:9px">⚠ FIRED</span>':''}
      <span class="ad" onclick="delAlert(${a.id})">✕</span>
    </div>`).join('');
}

function tglAlert(id,active){
  const r=alertRules.find(a=>a.id===id);if(r)r.active=active;
  document.getElementById('tb-alerts').textContent=alertRules.filter(a=>a.active).length;
}

function delAlert(id){
  alertRules=alertRules.filter(a=>a.id!==id);renderAlerts();
  document.getElementById('tb-alerts').textContent=alertRules.filter(a=>a.active).length;
}

function checkAlerts(ctx){
  if(!alertsMaster)return;
  alertRules.filter(a=>a.active&&!a.triggered).forEach(a=>{
    let val=null;
    if(a.field==='price'&&a.sym===ctx.symbol)val=ctx.price;
    if(val===null)return;
    const ops={lt:v=>v<a.val,lte:v=>v<=a.val,eq:v=>v===a.val,gte:v=>v>=a.val,gt:v=>v>a.val};
    if(ops[a.op]&&ops[a.op](val)){
      a.triggered=true;
      const msg=`${a.sym}: ${a.field} is ${val} (alert: ${a.op} ${a.val})`;
      fireAlert('🔔 Granite Alert',msg);log('ALERT FIRED: '+msg,'warn');
    }
  });
}

function fireAlert(title,msg){
  if(Notification.permission==='granted')new Notification(title,{body:msg});
  sendPushover(title,msg);
}

async function sendPushover(title,msg){
  try{
    await fetch(API+'/alerts/pushover',{
      method:'POST',headers:{'Content-Type':'application/json'},
      body:JSON.stringify({title,message:msg,notify_whatsapp:false})
    });
  }catch(e){log('Pushover err: '+e.message,'bad');}
}

async function testPushover(){
  log('Sending test Pushover…');
  await sendPushover('🔔 Granite Trader Test','Alert system working. '+new Date().toLocaleTimeString());
  log('Test Pushover sent','ok');
}

// ── AUTO REFRESH
function setAutoRefresh(secs){
  refreshInterval=parseInt(secs);refreshCD=refreshInterval;
  if(refreshTimer)clearInterval(refreshTimer);
  refreshTimer=setInterval(()=>{
    refreshCD--;
    const el=document.getElementById('refreshCD');if(el)el.textContent=refreshCD+'s';
    if(refreshCD<=0){refreshCD=refreshInterval;fullRefresh();}
  },1000);
  log('Auto-refresh: every '+secs+'s');
}

async function fullRefresh(){
  log('Refreshing…');
  await loadPos();
  const sym=document.getElementById('sSym').value.trim().toUpperCase()||'SPY';
  await getQuote(sym);
  if(scanData.length)await runScan();
  log('Refresh complete','ok');
}

// ── TRADE TICKET
let activeStrat='credit_spread';
function setStrat(btn,strat){
  activeStrat=strat;
  document.querySelectorAll('.strat-btn').forEach(b=>b.classList.remove('active'));
  btn.classList.add('active');
  document.getElementById('tt-msg').textContent='Strategy: '+strat.replace(/_/g,' ').toUpperCase();
}
function submitTicket(){
  const sym=document.getElementById('tt-sym').value.trim().toUpperCase();
  const qty=document.getElementById('tt-qty').value;
  const act=document.getElementById('tt-act').value;
  document.getElementById('tt-msg').textContent='⚠ Tastytrade routing arrives v0.5 — '+activeStrat+' '+sym+' ×'+qty+' '+act;
  log('Ticket: '+activeStrat+' '+sym+' ×'+qty,'warn');
}

// ── LOG (in-memory, shown in browser console)
function log(msg,cls){console.log('[Granite]',msg);}

// ── INIT
(async()=>{
  applyDef();renderWl();
  await loadPos();
  await Notification.requestPermission();
  setAutoRefresh(300);
  try{await getQuote(activeWlSym);}catch(e){}
  try{await loadExpFilter(activeWlSym);}catch(e){}
  console.log('[Granite] Ready');
})();
</script>
</body>
</html>
'@
Write-File "frontend\index.html" $c

if (-not $SkipGit -and (Test-Path (Join-Path $Root ".git"))) {
    Push-Location $Root
    git add -A
    if (git status --porcelain) {
        git commit -m "v0.5 tiled workspace + watchlist + vol surface + Pushover + skins"
        git push
        Write-OK "Git push complete."
    } else { Write-Info "Nothing to commit." }
    Pop-Location
}
Write-OK "=== v0.5 install complete ==="
Write-Host "Restart app then open http://localhost:5500" -ForegroundColor Cyan
