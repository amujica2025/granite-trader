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

# Backup
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$bd = Join-Path $Root "_installer_backups\v04_$ts"
New-Item -ItemType Directory -Force -Path $bd | Out-Null
Copy-Item "$BACKEND\cache_manager.py" $bd -Force -ErrorAction SilentlyContinue
Copy-Item "$FRONTEND\index.html" $bd -Force -ErrorAction SilentlyContinue
Write-Info "Backup: $bd"

function Write-File([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Info "  wrote $path"
}

Write-Info "Writing cache_manager.py (Schwab fallback fix)..."
$cm = @'
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
Write-File (Join-Path $BACKEND "cache_manager.py") $cm

Write-Info "Writing index.html (ultrawide UI)..."
$idx = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Granite Trader</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600&family=Syne:wght@400;600;700;800&display=swap');

:root {
  --bg:         #080b10;
  --bg1:        #0d1117;
  --bg2:        #111820;
  --bg3:        #16202c;
  --border:     #1e2d3d;
  --border2:    #253545;
  --text:       #cdd9e5;
  --muted:      #7a92a8;
  --accent:     #58a6ff;
  --accent2:    #3fb950;
  --warn:       #d29922;
  --danger:     #f85149;
  --call:       #3fb950;
  --put:        #f85149;
  --gold:       #e3b341;
  --panel-hdr:  #0d1520;
  --mono: 'JetBrains Mono', monospace;
  --sans: 'Syne', sans-serif;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  background: var(--bg);
  color: var(--text);
  font-family: var(--mono);
  font-size: 12px;
  height: 100vh;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}

/* ── TOP BAR ── */
#topbar {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 6px 10px;
  background: var(--bg1);
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
  flex-wrap: wrap;
  min-height: 44px;
}

.brand {
  font-family: var(--sans);
  font-weight: 800;
  font-size: 14px;
  color: var(--accent);
  letter-spacing: 0.05em;
  margin-right: 8px;
  white-space: nowrap;
}

.metric-pill {
  display: flex;
  flex-direction: column;
  padding: 3px 10px;
  background: var(--bg2);
  border: 1px solid var(--border);
  border-radius: 4px;
  min-width: 100px;
}
.metric-pill .lbl { font-size: 9px; color: var(--muted); text-transform: uppercase; letter-spacing: .08em; }
.metric-pill .val { font-size: 13px; font-weight: 600; color: var(--text); }
.metric-pill .val.ok  { color: var(--accent2); }
.metric-pill .val.warn { color: var(--warn); }
.metric-pill .val.bad  { color: var(--danger); }

.source-badge {
  margin-left: auto;
  padding: 3px 10px;
  border-radius: 3px;
  font-size: 10px;
  font-weight: 600;
  letter-spacing: .06em;
  background: var(--bg3);
  border: 1px solid var(--border);
  color: var(--muted);
}
.source-badge.live { border-color: var(--accent2); color: var(--accent2); }

/* ── MAIN GRID ── */
#workspace {
  display: grid;
  grid-template-columns: 200px 1fr 1fr 1fr 220px;
  gap: 0;
  flex: 1;
  min-height: 0;
  overflow: hidden;
}

.panel {
  display: flex;
  flex-direction: column;
  border-right: 1px solid var(--border);
  min-height: 0;
  overflow: hidden;
}
.panel:last-child { border-right: none; }

.panel-hdr {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 6px 10px;
  background: var(--panel-hdr);
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}
.panel-hdr h2 {
  font-family: var(--sans);
  font-size: 11px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: .1em;
  color: var(--accent);
}
.panel-body {
  flex: 1;
  overflow-y: auto;
  overflow-x: hidden;
}

/* ── SCROLLBARS ── */
::-webkit-scrollbar { width: 4px; height: 4px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--border2); border-radius: 2px; }

/* ── WATCHLIST PANEL ── */
#watchlistFilter {
  width: 100%;
  padding: 5px 8px;
  background: var(--bg2);
  border: none;
  border-bottom: 1px solid var(--border);
  color: var(--text);
  font-family: var(--mono);
  font-size: 11px;
  outline: none;
}
.wl-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 5px 10px;
  border-bottom: 1px solid #0f1a24;
  cursor: pointer;
  transition: background .1s;
}
.wl-row:hover { background: var(--bg3); }
.wl-row.active { background: #0f2340; border-left: 2px solid var(--accent); }
.wl-sym { font-weight: 600; font-size: 12px; color: var(--text); }
.wl-price { font-size: 11px; color: var(--muted); }
.wl-chg.pos { color: var(--accent2); font-size: 10px; }
.wl-chg.neg { color: var(--danger); font-size: 10px; }

/* ── POSITIONS TABLE ── */
.tbl-wrap { overflow: auto; flex: 1; }
table { width: 100%; border-collapse: collapse; }
th, td {
  padding: 5px 8px;
  text-align: right;
  border-bottom: 1px solid #0f1a24;
  white-space: nowrap;
  font-size: 11px;
}
td:first-child, th:first-child { text-align: left; }
thead th {
  position: sticky;
  top: 0;
  background: #0d1520;
  color: var(--muted);
  font-size: 9px;
  text-transform: uppercase;
  letter-spacing: .06em;
  font-weight: 500;
  z-index: 2;
  cursor: pointer;
  user-select: none;
}
thead th:hover { color: var(--text); }
tbody tr:hover { background: #0f1a24; }
.group-hdr td {
  background: #0a1520;
  color: var(--accent);
  font-weight: 700;
  font-size: 10px;
  font-family: var(--sans);
  letter-spacing: .04em;
  padding: 4px 8px;
}
.pos-call { color: var(--call); }
.pos-put  { color: var(--put); }
.pos-long { color: var(--accent2); }
.pos-short { color: var(--danger); }
.pos-neutral { color: var(--text); }

/* ── TABS ── */
.tabs {
  display: flex;
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
  background: var(--panel-hdr);
}
.tab {
  padding: 6px 14px;
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: .08em;
  color: var(--muted);
  cursor: pointer;
  border-bottom: 2px solid transparent;
  transition: all .15s;
}
.tab:hover { color: var(--text); }
.tab.active { color: var(--accent); border-bottom-color: var(--accent); }
.tab-content { display: none; flex: 1; min-height: 0; overflow: auto; flex-direction: column; }
.tab-content.active { display: flex; }

/* ── SCANNER CONTROLS ── */
.scan-controls {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 6px;
  padding: 8px;
  border-bottom: 1px solid var(--border);
  background: var(--bg1);
  flex-shrink: 0;
}
.ctrl-group { display: flex; flex-direction: column; gap: 2px; }
.ctrl-group label { font-size: 9px; color: var(--muted); text-transform: uppercase; letter-spacing: .06em; }
select, input[type=text], input[type=number] {
  background: var(--bg3);
  color: var(--text);
  border: 1px solid var(--border2);
  border-radius: 3px;
  padding: 4px 7px;
  font-family: var(--mono);
  font-size: 11px;
  width: 100%;
  outline: none;
}
select:focus, input:focus { border-color: var(--accent); }

.scan-actions {
  display: flex;
  gap: 6px;
  padding: 6px 8px;
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}

/* ── BUTTONS ── */
.btn {
  padding: 5px 12px;
  border-radius: 3px;
  border: 1px solid var(--border2);
  background: var(--bg3);
  color: var(--text);
  font-family: var(--mono);
  font-size: 11px;
  font-weight: 600;
  cursor: pointer;
  transition: all .12s;
  white-space: nowrap;
}
.btn:hover { background: var(--bg2); border-color: var(--accent); color: var(--accent); }
.btn.primary { background: var(--accent); color: var(--bg); border-color: var(--accent); }
.btn.primary:hover { opacity: .85; }
.btn.sm { padding: 3px 8px; font-size: 10px; }

/* ── SCANNER TABLE ── */
.scan-row.call-row { border-left: 2px solid var(--call); }
.scan-row.put-row  { border-left: 2px solid var(--put); }

/* ── VOL SURFACE ── */
.vol-surface-wrap {
  overflow: auto;
  padding: 6px;
}
.vol-matrix {
  border-collapse: collapse;
  width: max-content;
  min-width: 100%;
}
.vol-matrix th, .vol-matrix td {
  padding: 4px 7px;
  text-align: center;
  border: 1px solid #0f1a24;
  font-size: 10px;
  white-space: nowrap;
}
.vol-matrix thead th {
  background: #0d1520;
  color: var(--muted);
  font-size: 9px;
  letter-spacing: .05em;
  position: sticky;
  top: 0;
}
.vol-matrix .exp-label {
  background: #0d1520;
  color: var(--accent);
  font-weight: 600;
  text-align: left;
  position: sticky;
  left: 0;
}
.richness-bar {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  padding: 6px 8px;
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
}
.rich-exp {
  display: flex;
  flex-direction: column;
  padding: 4px 8px;
  background: var(--bg2);
  border: 1px solid var(--border);
  border-radius: 3px;
  min-width: 100px;
  cursor: pointer;
}
.rich-exp:hover { border-color: var(--accent); }
.rich-exp .re-date { font-size: 9px; color: var(--muted); }
.rich-exp .re-iv { font-size: 12px; font-weight: 600; color: var(--text); }
.rich-exp .re-score { font-size: 9px; color: var(--warn); }

/* ── RIGHT CONTROLS PANEL ── */
.ctrl-section {
  padding: 8px;
  border-bottom: 1px solid var(--border);
}
.ctrl-section h3 {
  font-family: var(--sans);
  font-size: 10px;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: .1em;
  color: var(--muted);
  margin-bottom: 6px;
}
.acct-select {
  display: flex;
  gap: 4px;
  margin-bottom: 6px;
}
.acct-btn {
  flex: 1;
  padding: 4px;
  text-align: center;
  border: 1px solid var(--border2);
  border-radius: 3px;
  cursor: pointer;
  font-size: 10px;
  color: var(--muted);
  background: var(--bg2);
  transition: all .12s;
}
.acct-btn.active { background: var(--accent); color: var(--bg); border-color: var(--accent); font-weight: 700; }

.alert-row {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 5px 0;
  border-bottom: 1px solid #0f1a24;
  font-size: 10px;
}
.alert-dot { width: 6px; height: 6px; border-radius: 50%; flex-shrink: 0; }
.alert-dot.ok  { background: var(--accent2); }
.alert-dot.off { background: var(--border2); }

.log-entry {
  padding: 4px 8px;
  border-bottom: 1px solid #0a1520;
  font-size: 10px;
  color: var(--muted);
  line-height: 1.5;
}
.log-entry .ts { color: var(--border2); }
.log-entry .msg { color: var(--text); }

/* ── BOTTOM TOTALS BAR ── */
#totalsbar {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 5px 10px;
  background: var(--bg1);
  border-top: 1px solid var(--border);
  flex-shrink: 0;
  flex-wrap: wrap;
}
.total-chip {
  display: flex;
  flex-direction: column;
  padding: 2px 10px;
  border: 1px solid var(--border);
  border-radius: 3px;
  background: var(--bg2);
  min-width: 90px;
}
.total-chip .tc-lbl { font-size: 8px; color: var(--muted); text-transform: uppercase; letter-spacing: .06em; }
.total-chip .tc-val { font-size: 12px; font-weight: 600; }

/* ── UTILITY ── */
.ok    { color: var(--accent2) !important; }
.bad   { color: var(--danger) !important; }
.warn  { color: var(--warn) !important; }
.muted { color: var(--muted) !important; }
.accent { color: var(--accent) !important; }

.error-msg { color: var(--danger); padding: 8px; font-size: 11px; }
.empty-msg { color: var(--muted); padding: 20px; text-align: center; font-size: 11px; }
.spinner { text-align: center; padding: 20px; color: var(--muted); font-size: 10px; }

/* ── SCAN ROW BADGE ── */
.side-badge {
  display: inline-block;
  padding: 1px 6px;
  border-radius: 2px;
  font-size: 9px;
  font-weight: 700;
  letter-spacing: .05em;
}
.side-badge.call { background: rgba(63,185,80,.15); color: var(--call); border: 1px solid var(--call); }
.side-badge.put  { background: rgba(248,81,73,.15);  color: var(--put);  border: 1px solid var(--put); }

/* ── RICHNESS SCORE COLOR ── */
.rs-high { color: var(--gold); font-weight: 600; }
.rs-mid  { color: var(--text); }
.rs-low  { color: var(--muted); }

.flex-gap { display: flex; gap: 6px; align-items: center; }
.ml-auto { margin-left: auto; }

</style>
</head>
<body>

<!-- ════════════════════ TOP BAR ════════════════════ -->
<div id="topbar">
  <span class="brand">⬡ GRANITE</span>

  <div class="metric-pill">
    <span class="lbl">Net Liq</span>
    <span class="val" id="m-netliq">—</span>
  </div>
  <div class="metric-pill">
    <span class="lbl">Limit (×25)</span>
    <span class="val" id="m-limit">—</span>
  </div>
  <div class="metric-pill">
    <span class="lbl">Used</span>
    <span class="val" id="m-used">—</span>
  </div>
  <div class="metric-pill">
    <span class="lbl">Room</span>
    <span class="val" id="m-room">—</span>
  </div>
  <div class="metric-pill">
    <span class="lbl">Used %</span>
    <span class="val" id="m-usedpct">—</span>
  </div>
  <div class="metric-pill">
    <span class="lbl">Active Symbol</span>
    <span class="val accent" id="m-sym">SPY</span>
  </div>
  <div class="metric-pill">
    <span class="lbl">Price</span>
    <span class="val" id="m-price">—</span>
  </div>
  <div class="metric-pill">
    <span class="lbl">Change</span>
    <span class="val" id="m-chg">—</span>
  </div>

  <span class="source-badge" id="sourceBadge">LOADING</span>

  <button class="btn sm" id="refreshBtn" onclick="fullRefresh()">↺ REFRESH</button>
  <button class="btn sm" id="notifyBtn" onclick="enableAlerts()">🔔 ALERTS</button>
</div>

<!-- ════════════════════ MAIN WORKSPACE ════════════════════ -->
<div id="workspace">

  <!-- ═══ PANEL 1: WATCHLIST ═══ -->
  <div class="panel">
    <div class="panel-hdr">
      <h2>Watchlist</h2>
      <span class="muted" style="font-size:9px" id="wlCount">0 symbols</span>
    </div>
    <input id="watchlistFilter" placeholder="Filter symbols…" oninput="filterWatchlist(this.value)"/>
    <div class="panel-body" id="watchlistBody"></div>
  </div>

  <!-- ═══ PANEL 2: OPEN POSITIONS ═══ -->
  <div class="panel">
    <div class="panel-hdr">
      <h2>Open Positions</h2>
      <div class="flex-gap">
        <div class="acct-select">
          <div class="acct-btn active" id="acctMock" onclick="setAcctSource('mock')">MOCK</div>
          <div class="acct-btn" id="acctTasty" onclick="setAcctSource('tasty')">TASTY</div>
        </div>
      </div>
    </div>
    <div id="positionsError" class="error-msg"></div>
    <div class="tbl-wrap" style="flex:1">
      <table id="posTable">
        <thead>
          <tr>
            <th></th>
            <th>Sym</th>
            <th>Q</th>
            <th>Type</th>
            <th>Exp</th>
            <th>Strike</th>
            <th>Mark</th>
            <th>Trade</th>
            <th>P/L</th>
            <th>Sht Val</th>
            <th>Lng Cost</th>
            <th>Impact</th>
          </tr>
        </thead>
        <tbody id="posBody"></tbody>
      </table>
    </div>
  </div>

  <!-- ═══ PANEL 3: SCANNER + VOL SURFACE ═══ -->
  <div class="panel">
    <div class="panel-hdr">
      <h2 id="scanPanelTitle">Entry Scanner</h2>
    </div>
    <div class="tabs">
      <div class="tab active" onclick="switchTab('scanner')">Scanner</div>
      <div class="tab" onclick="switchTab('surface')">Vol Surface</div>
    </div>

    <!-- Scanner Tab -->
    <div class="tab-content active" id="tab-scanner" style="flex-direction:column">
      <div class="scan-controls">
        <div class="ctrl-group">
          <label>Symbol</label>
          <input type="text" id="scanSym" value="SPY" style="text-transform:uppercase"/>
        </div>
        <div class="ctrl-group">
          <label>Total Risk $</label>
          <input type="number" id="scanRisk" value="600" step="100"/>
        </div>
        <div class="ctrl-group">
          <label>Side</label>
          <select id="scanSide">
            <option value="all">All</option>
            <option value="call">Calls</option>
            <option value="put">Puts</option>
          </select>
        </div>
        <div class="ctrl-group">
          <label>Expiration</label>
          <select id="scanExp"><option value="all">All</option></select>
        </div>
        <div class="ctrl-group">
          <label>Sort By</label>
          <select id="scanSort">
            <option value="credit_pct_risk">Credit % Risk</option>
            <option value="richness">Richness Score</option>
            <option value="credit">Net Credit</option>
            <option value="limit_impact">Limit Impact</option>
            <option value="max_loss">Max Loss</option>
          </select>
        </div>
        <div class="ctrl-group">
          <label>Max Results</label>
          <input type="number" id="scanMax" value="150" step="50" min="10"/>
        </div>
      </div>
      <div class="scan-actions">
        <button class="btn primary" onclick="runScan()">▶ SCAN</button>
        <button class="btn" onclick="clearScan()">✕ CLEAR</button>
        <span id="scanCount" class="muted" style="font-size:10px;margin-left:4px;align-self:center"></span>
      </div>
      <div id="scanError" class="error-msg"></div>
      <div class="tbl-wrap" style="flex:1">
        <table>
          <thead>
            <tr>
              <th>Exp</th>
              <th>Side</th>
              <th>Short</th>
              <th>Long</th>
              <th>Wid</th>
              <th>Qty</th>
              <th>Net Cr</th>
              <th>Gr Risk</th>
              <th>Max Loss</th>
              <th>Cr%Risk</th>
              <th>Sht Δ</th>
              <th>Sht IV</th>
              <th>Richness</th>
              <th>Impact</th>
            </tr>
          </thead>
          <tbody id="scanBody"></tbody>
        </table>
      </div>
    </div>

    <!-- Vol Surface Tab -->
    <div class="tab-content" id="tab-surface" style="flex-direction:column">
      <div class="richness-bar" id="richnessBar"><span class="muted" style="font-size:10px">Load a symbol to see vol surface</span></div>
      <div class="vol-surface-wrap panel-body" id="volSurfaceWrap">
        <div class="empty-msg">Run a scan or load a quote to populate the surface.</div>
      </div>
    </div>
  </div>

  <!-- ═══ PANEL 4: POSITION DETAIL / ROLL CANDIDATES ═══ -->
  <div class="panel">
    <div class="panel-hdr">
      <h2>Selected Legs</h2>
    </div>
    <div class="tabs">
      <div class="tab active" onclick="switchDetailTab('detail')">Selection Detail</div>
      <div class="tab" onclick="switchDetailTab('roll')">Roll Preview</div>
    </div>

    <div class="tab-content active" id="tab-detail" style="flex-direction:column">
      <div class="tbl-wrap" style="flex:1">
        <table>
          <thead>
            <tr>
              <th>Sym</th>
              <th>Side</th>
              <th>Qty</th>
              <th>Strike</th>
              <th>Exp</th>
              <th>Mark</th>
              <th>P/L</th>
              <th>Sht Val</th>
            </tr>
          </thead>
          <tbody id="detailBody">
            <tr><td colspan="8" class="empty-msg">Select rows in Open Positions</td></tr>
          </tbody>
        </table>
      </div>
      <div style="padding:8px;border-top:1px solid var(--border);flex-shrink:0">
        <div style="font-size:9px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em;margin-bottom:4px">Selection Totals</div>
        <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px" id="selTotals">
          <div class="total-chip"><span class="tc-lbl">Legs</span><span class="tc-val" id="st-legs">0</span></div>
          <div class="total-chip"><span class="tc-lbl">P/L Open</span><span class="tc-val" id="st-pnl">—</span></div>
          <div class="total-chip"><span class="tc-lbl">Short Value</span><span class="tc-val" id="st-sv">—</span></div>
          <div class="total-chip"><span class="tc-lbl">Long Cost</span><span class="tc-val" id="st-lc">—</span></div>
          <div class="total-chip"><span class="tc-lbl">Limit Impact</span><span class="tc-val" id="st-imp">—</span></div>
        </div>
      </div>
    </div>

    <div class="tab-content" id="tab-roll" style="flex-direction:column">
      <div class="empty-msg" id="rollMsg">Select position legs then click Roll Preview</div>
      <div class="tbl-wrap" style="flex:1">
        <table>
          <thead>
            <tr>
              <th>Exp</th>
              <th>Side</th>
              <th>Short</th>
              <th>Long</th>
              <th>Net Cr</th>
              <th>Credit%</th>
              <th>Impact</th>
            </tr>
          </thead>
          <tbody id="rollBody"></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- ═══ PANEL 5: CONTROLS + ALERTS + LOG ═══ -->
  <div class="panel">
    <div class="panel-hdr">
      <h2>Controls</h2>
    </div>
    <div class="panel-body">

      <div class="ctrl-section">
        <h3>Quote</h3>
        <div class="ctrl-group" style="margin-bottom:6px">
          <label>Symbol</label>
          <input type="text" id="quoteInput" value="SPY" style="text-transform:uppercase" onkeydown="if(event.key==='Enter')getQuote()"/>
        </div>
        <div class="flex-gap">
          <button class="btn primary" style="flex:1" onclick="getQuote()">Get Quote</button>
          <button class="btn" style="flex:1" onclick="loadVolSurface()">Vol Surface</button>
        </div>
        <div id="quoteResult" style="margin-top:8px;font-size:11px"></div>
      </div>

      <div class="ctrl-section">
        <h3>Price Alert</h3>
        <div class="ctrl-group" style="margin-bottom:4px">
          <label>Symbol</label>
          <input type="text" id="alertSym" value="SPY"/>
        </div>
        <div class="ctrl-group" style="margin-bottom:6px">
          <label>Move Threshold $</label>
          <input type="number" id="alertThresh" value="1.00" step="0.25"/>
        </div>
        <div style="display:flex;align-items:center;gap:8px;margin-bottom:6px;font-size:11px">
          <input type="checkbox" id="whatsappChk"/>
          <label for="whatsappChk">WhatsApp</label>
        </div>
        <button class="btn" style="width:100%" onclick="enableAlerts()">Enable Desktop Alerts</button>
        <div id="alertStatus" style="font-size:10px;color:var(--muted);margin-top:4px"></div>
      </div>

      <div class="ctrl-section">
        <h3>Auto Refresh</h3>
        <div style="display:flex;align-items:center;gap:8px;font-size:11px;margin-bottom:4px">
          <input type="checkbox" id="autoRefreshChk" onchange="toggleAutoRefresh()"/>
          <label for="autoRefreshChk">Every 5 min</label>
        </div>
        <div id="autoRefreshStatus" style="font-size:10px;color:var(--muted)"></div>
      </div>

      <div class="ctrl-section">
        <h3>Cache Status</h3>
        <div id="cacheStatus" style="font-size:10px;color:var(--muted)">—</div>
        <button class="btn sm" style="margin-top:6px" onclick="loadCacheStatus()">Check Cache</button>
      </div>

      <div class="ctrl-section" style="flex:1">
        <h3>Activity Log</h3>
        <div id="activityLog"></div>
      </div>

    </div>
  </div>

</div>

<!-- ════════════════════ BOTTOM TOTALS BAR ════════════════════ -->
<div id="totalsbar">
  <span style="font-size:9px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-right:4px">SELECTED:</span>
  <div class="total-chip"><span class="tc-lbl">Legs</span><span class="tc-val" id="tb-legs">0</span></div>
  <div class="total-chip"><span class="tc-lbl">Short Value</span><span class="tc-val" id="tb-sv">—</span></div>
  <div class="total-chip"><span class="tc-lbl">Long Cost</span><span class="tc-val" id="tb-lc">—</span></div>
  <div class="total-chip"><span class="tc-lbl">P/L Open</span><span class="tc-val" id="tb-pnl">—</span></div>
  <div class="total-chip"><span class="tc-lbl">Limit Impact</span><span class="tc-val" id="tb-imp">—</span></div>
  <div class="total-chip ml-auto"><span class="tc-lbl">Positions Loaded</span><span class="tc-val" id="tb-poscount">0</span></div>
  <div class="total-chip"><span class="tc-lbl">Scanner Results</span><span class="tc-val" id="tb-scancount">0</span></div>
</div>

<script>
const API = 'http://localhost:8000';

// ── STATE ────────────────────────────────────────────────
let positions = [];
let selectedIds = new Set();
let acctSource = 'mock';
let lastQuoteData = null;
let autoRefreshTimer = null;
let alertsEnabled = false;
let lastAlertPrice = null;
let scanResults = [];

// ── WATCHLIST ────────────────────────────────────────────
const WATCHLIST = [
  'SPY','QQQ','IWM','DIA','GLD','SLV','TLT','XSP',
  'AAPL','NVDA','TSLA','AMZN','META','MSFT','GOOGL',
  'AMD','NFLX','BA','COIN','PLTR','SOFI','MSTR',
  'UBER','SHOP','RIVN','BABA','SNOW','CRWD','SQ'
];

let wlPrices = {};
let activeWlSym = 'SPY';

function renderWatchlist(filter='') {
  const body = document.getElementById('watchlistBody');
  const syms = filter
    ? WATCHLIST.filter(s => s.includes(filter.toUpperCase()))
    : WATCHLIST;
  document.getElementById('wlCount').textContent = syms.length + ' symbols';

  body.innerHTML = syms.map(sym => {
    const p = wlPrices[sym];
    const chgClass = !p ? '' : (p.pct >= 0 ? 'pos' : 'neg');
    const chgText  = !p ? '' : `${p.pct >= 0 ? '+' : ''}${(p.pct*100).toFixed(2)}%`;
    return `
      <div class="wl-row${sym===activeWlSym?' active':''}" onclick="loadSymbol('${sym}')">
        <span class="wl-sym">${sym}</span>
        <div style="text-align:right">
          <div class="wl-price">${p ? '$'+p.price.toFixed(2) : '—'}</div>
          <div class="wl-chg ${chgClass}">${chgText}</div>
        </div>
      </div>`;
  }).join('');
}

function filterWatchlist(v) { renderWatchlist(v); }

async function loadSymbol(sym) {
  activeWlSym = sym.toUpperCase();
  document.getElementById('scanSym').value = activeWlSym;
  document.getElementById('quoteInput').value = activeWlSym;
  document.getElementById('alertSym').value = activeWlSym;
  document.getElementById('m-sym').textContent = activeWlSym;
  renderWatchlist(document.getElementById('watchlistFilter').value);
  log(`Loading ${activeWlSym}…`);
  await getQuote();
  await populateExpFilter();
}

// ── FORMATTING ──────────────────────────────────────────
const fmt$ = v => v==null ? '—' : '$' + Number(v).toFixed(2);
const fmtN = (v, d=2) => v==null ? '—' : Number(v).toFixed(d);
const fmtPct = v => v==null ? '—' : (Number(v)*100).toFixed(2)+'%';
const fmtIV  = v => v==null ? '—' : (Number(v)*100).toFixed(2)+'%';
const fmtSign = v => v==null ? '—' : (v>=0?'+':'')+Number(v).toFixed(2);

function colorVal(v) {
  if (v==null) return '';
  return Number(v) >= 0 ? ' class="ok"' : ' class="bad"';
}

function rsClass(v) {
  if (v==null) return '';
  const n = Number(v);
  if (n >= 0.7) return ' class="rs-high"';
  if (n >= 0.4) return ' class="rs-mid"';
  return ' class="rs-low"';
}

// ── API ─────────────────────────────────────────────────
async function api(path) {
  const r = await fetch(API + path);
  const t = await r.text();
  try { return JSON.parse(t); }
  catch { throw new Error(t || r.status); }
}

async function apiPost(path, body) {
  const r = await fetch(API + path, {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify(body)
  });
  const t = await r.text();
  try { return JSON.parse(t); }
  catch { throw new Error(t || r.status); }
}

// ── LOG ─────────────────────────────────────────────────
function log(msg, cls='') {
  const el = document.getElementById('activityLog');
  const ts = new Date().toLocaleTimeString('en-US',{hour12:false});
  const div = document.createElement('div');
  div.className = 'log-entry';
  div.innerHTML = `<span class="ts">[${ts}]</span> <span class="msg ${cls}">${msg}</span>`;
  el.insertBefore(div, el.firstChild);
  if (el.children.length > 50) el.removeChild(el.lastChild);
}

// ── ACCOUNT / POSITIONS ─────────────────────────────────
function setAcctSource(src) {
  acctSource = src;
  document.getElementById('acctMock').className = 'acct-btn' + (src==='mock'?' active':'');
  document.getElementById('acctTasty').className = 'acct-btn' + (src==='tasty'?' active':'');
  loadPositions();
}

async function loadPositions() {
  document.getElementById('positionsError').textContent = '';
  try {
    const data = await api(`/account/${acctSource}`);
    positions = data.positions || [];
    renderMetrics(data.limit_summary, data.source);
    renderPositions();
    document.getElementById('tb-poscount').textContent = positions.length;
    log(`Positions loaded (${data.source}) — ${positions.length} legs`, 'ok');
  } catch(e) {
    document.getElementById('positionsError').textContent = e.message;
    log('Positions error: ' + e.message, 'bad');
  }
}

function renderMetrics(ls, src) {
  if (!ls) return;
  document.getElementById('m-netliq').textContent = fmt$(ls.net_liq);
  document.getElementById('m-limit').textContent  = fmt$(ls.max_limit);
  document.getElementById('m-used').textContent   = fmt$(ls.used_short_value);
  document.getElementById('m-room').textContent   = fmt$(ls.remaining_room);
  const pct = Number(ls.used_pct||0)*100;
  const pctEl = document.getElementById('m-usedpct');
  pctEl.textContent = pct.toFixed(1)+'%';
  pctEl.className = 'val ' + (pct>80?'bad':pct>60?'warn':'ok');
}

function renderPositions() {
  const body = document.getElementById('posBody');
  if (!positions.length) {
    body.innerHTML = '<tr><td colspan="12" class="empty-msg">No positions</td></tr>';
    return;
  }

  const groups = {};
  positions.forEach(p => {
    const k = `${p.underlying}||${p.group||''}`;
    if (!groups[k]) groups[k] = [];
    groups[k].push(p);
  });

  let html = '';
  Object.entries(groups).forEach(([k, rows]) => {
    const [underlying, group] = k.split('||');
    html += `<tr class="group-hdr"><td colspan="12">${underlying} ${group?'— '+group:''}</td></tr>`;
    rows.forEach(row => {
      const chk = selectedIds.has(row.id) ? 'checked' : '';
      const typeClass = row.option_type==='C' ? 'pos-call' : 'pos-put';
      const qtyClass  = row.display_qty < 0 ? 'pos-short' : 'pos-long';
      html += `<tr>
        <td><input type="checkbox" data-id="${row.id}" ${chk} onchange="toggleRow(this)"/></td>
        <td><b>${row.underlying}</b></td>
        <td class="${qtyClass}">${row.display_qty}</td>
        <td class="${typeClass}">${row.option_type==='C'?'CALL':'PUT'}</td>
        <td class="muted">${row.expiration}</td>
        <td>${row.strike}</td>
        <td>${fmt$(row.mark)}</td>
        <td>${fmt$(row.trade_price)}</td>
        <td${colorVal(row.pnl_open)}>${fmt$(row.pnl_open)}</td>
        <td>${fmt$(row.short_value)}</td>
        <td>${fmt$(row.long_cost)}</td>
        <td>${fmt$(row.limit_impact)}</td>
      </tr>`;
    });
  });
  body.innerHTML = html;
}

function toggleRow(chk) {
  const id = chk.dataset.id;
  if (chk.checked) selectedIds.add(id);
  else selectedIds.delete(id);
  refreshTotals();
}

async function refreshTotals() {
  const sel = positions.filter(p => selectedIds.has(p.id));
  const legs = sel.length;

  // Update detail table
  const db = document.getElementById('detailBody');
  if (!sel.length) {
    db.innerHTML = '<tr><td colspan="8" class="empty-msg">Select rows in Open Positions</td></tr>';
  } else {
    db.innerHTML = sel.map(r => `<tr>
      <td>${r.underlying}</td>
      <td class="${r.option_type==='C'?'pos-call':'pos-put'}">${r.option_type==='C'?'CALL':'PUT'}</td>
      <td class="${r.display_qty<0?'pos-short':'pos-long'}">${r.display_qty}</td>
      <td>${r.strike}</td>
      <td class="muted">${r.expiration}</td>
      <td>${fmt$(r.mark)}</td>
      <td${colorVal(r.pnl_open)}>${fmt$(r.pnl_open)}</td>
      <td>${fmt$(r.short_value)}</td>
    </tr>`).join('');
  }

  // Compute totals
  const sv  = sel.reduce((a,r) => a + Number(r.short_value||0), 0);
  const lc  = sel.reduce((a,r) => a + Number(r.long_cost||0), 0);
  const pnl = sel.reduce((a,r) => a + Number(r.pnl_open||0), 0);
  const imp = sel.reduce((a,r) => a + Number(r.limit_impact||0), 0);

  const setChip = (id, val, cls) => {
    const el = document.getElementById(id);
    if (el) { el.textContent = val; el.className = 'tc-val ' + (cls||''); }
  };

  setChip('st-legs', legs);
  setChip('st-pnl',  fmt$(pnl), pnl>=0?'ok':'bad');
  setChip('st-sv',   fmt$(sv));
  setChip('st-lc',   fmt$(lc));
  setChip('st-imp',  fmt$(imp));

  setChip('tb-legs', legs);
  setChip('tb-sv',   fmt$(sv));
  setChip('tb-lc',   fmt$(lc));
  setChip('tb-pnl',  fmt$(pnl), pnl>=0?'ok':'bad');
  setChip('tb-imp',  fmt$(imp));
}

// ── QUOTE ────────────────────────────────────────────────
async function getQuote() {
  const sym = (document.getElementById('quoteInput').value||'SPY').toUpperCase().trim();
  document.getElementById('quoteInput').value = sym;
  activeWlSym = sym;
  document.getElementById('m-sym').textContent = sym;

  try {
    log(`Fetching quote + chain: ${sym}…`);
    const data = await api(`/quote/schwab?symbol=${encodeURIComponent(sym)}`);

    // Parse Schwab quote structure
    const payload = data[sym] || data[sym.toUpperCase()] || {};
    const q = payload.quote || payload;
    const last = Number(q.lastPrice || q.mark || q.closePrice || 0);
    const chg  = Number(q.netChange || 0);
    const pct  = Number(q.netPercentChange || (q.closePrice ? chg/q.closePrice : 0));

    document.getElementById('m-price').textContent = last ? '$'+last.toFixed(2) : '—';
    const chgEl = document.getElementById('m-chg');
    chgEl.textContent = (chg>=0?'+':'')+chg.toFixed(2)+' ('+((pct*100).toFixed(2))+'%)';
    chgEl.className = 'val ' + (chg>=0?'ok':'bad');

    wlPrices[sym] = {price: last, pct};
    renderWatchlist(document.getElementById('watchlistFilter').value);

    // Update source badge
    updateSourceBadge('schwab');

    // Alert check
    if (alertsEnabled && lastAlertPrice !== null) {
      const thresh = Number(document.getElementById('alertThresh').value)||1;
      if (Math.abs(last - lastAlertPrice) >= thresh) {
        sendDesktopAlert(`${sym} moved $${(last-lastAlertPrice).toFixed(2)}`, `Price: $${last.toFixed(2)}`);
        lastAlertPrice = last;
      }
    } else {
      lastAlertPrice = last;
    }

    // Build quote card
    document.getElementById('quoteResult').innerHTML = `
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:4px;margin-top:4px">
        <div class="total-chip"><span class="tc-lbl">Last</span><span class="tc-val">${fmt$(last)}</span></div>
        <div class="total-chip"><span class="tc-lbl">Change</span><span class="tc-val ${chg>=0?'ok':'bad'}">${fmtSign(chg)}</span></div>
        <div class="total-chip"><span class="tc-lbl">Bid</span><span class="tc-val">${fmt$(q.bidPrice||q.bid)}</span></div>
        <div class="total-chip"><span class="tc-lbl">Ask</span><span class="tc-val">${fmt$(q.askPrice||q.ask)}</span></div>
      </div>`;

    log(`Quote OK: ${sym} @ $${last.toFixed(2)}`, 'ok');
    return data;
  } catch(e) {
    log(`Quote error (${sym}): ${e.message}`, 'bad');
    document.getElementById('quoteResult').innerHTML = `<div class="error-msg">${e.message}</div>`;
  }
}

function updateSourceBadge(src) {
  const el = document.getElementById('sourceBadge');
  el.textContent = src === 'schwab' ? '● SCHWAB LIVE' : src === 'schwab_fallback' ? '● SCHWAB FALLBACK' : '○ BARCHART';
  el.className = 'source-badge' + (src.includes('schwab') ? ' live' : '');
}

// ── EXPIRATION FILTER ────────────────────────────────────
async function populateExpFilter() {
  const sym = document.getElementById('scanSym').value.trim().toUpperCase() || 'SPY';
  try {
    const data = await api(`/chain?symbol=${encodeURIComponent(sym)}`);
    const sel = document.getElementById('scanExp');
    const exps = (data.expirations||[]).slice(0,20);
    sel.innerHTML = '<option value="all">All</option>' +
      exps.map(e => `<option value="${e}">${e}</option>`).join('');
    if (data.active_chain_source) updateSourceBadge(data.active_chain_source);
  } catch(e) {
    log('Chain load error: ' + e.message, 'bad');
  }
}

// ── SCANNER ──────────────────────────────────────────────
async function runScan() {
  const sym  = document.getElementById('scanSym').value.trim().toUpperCase() || 'SPY';
  const risk = document.getElementById('scanRisk').value || 600;
  const side = document.getElementById('scanSide').value;
  const exp  = document.getElementById('scanExp').value;
  const sort = document.getElementById('scanSort').value;
  const max  = document.getElementById('scanMax').value || 150;

  document.getElementById('scanError').textContent = '';
  document.getElementById('scanBody').innerHTML = '<tr><td colspan="14" class="spinner">Scanning…</td></tr>';
  document.getElementById('scanCount').textContent = '';
  log(`Scanning ${sym} (${side}, risk $${risk}, sort: ${sort})…`);

  try {
    const qs = new URLSearchParams({symbol:sym, total_risk:risk, side, expiration:exp, sort_by:sort, max_results:max});
    const data = await api(`/scan/live?${qs}`);
    scanResults = data.items || [];
    renderScanResults(scanResults);
    document.getElementById('scanCount').textContent = `${scanResults.length} results`;
    document.getElementById('tb-scancount').textContent = scanResults.length;
    if (data.active_chain_source) updateSourceBadge(data.active_chain_source);
    log(`Scan complete: ${scanResults.length} candidates`, 'ok');

    // Auto-load vol surface after scan
    loadVolSurface(sym);
  } catch(e) {
    document.getElementById('scanError').textContent = e.message;
    document.getElementById('scanBody').innerHTML = '';
    log(`Scan error: ${e.message}`, 'bad');
  }
}

function renderScanResults(items) {
  const body = document.getElementById('scanBody');
  if (!items.length) {
    body.innerHTML = '<tr><td colspan="14" class="empty-msg">No results — try different filters or refresh symbol</td></tr>';
    return;
  }
  body.innerHTML = items.map(r => {
    const rowCls = r.option_side==='call' ? 'scan-row call-row' : 'scan-row put-row';
    const rs = Number(r.richness_score||0);
    return `<tr class="${rowCls}">
      <td class="muted">${r.expiration}</td>
      <td><span class="side-badge ${r.option_side}">${r.option_side.toUpperCase()}</span></td>
      <td>${r.short_strike}</td>
      <td>${r.long_strike}</td>
      <td class="muted">${r.width}</td>
      <td class="muted">${r.quantity}</td>
      <td class="ok">${fmt$(r.net_credit)}</td>
      <td class="muted">${fmt$(r.gross_defined_risk)}</td>
      <td class="bad">${fmt$(r.max_loss)}</td>
      <td${rsClass(r.credit_pct_risk)}>${fmtPct(r.credit_pct_risk)}</td>
      <td class="muted">${fmtN(r.short_delta,4)}</td>
      <td class="muted">${fmtIV(r.short_iv)}</td>
      <td${rsClass(r.richness_score)}>${fmtN(r.richness_score,4)}</td>
      <td class="warn">${fmt$(r.limit_impact)}</td>
    </tr>`;
  }).join('');
}

function clearScan() {
  scanResults = [];
  document.getElementById('scanBody').innerHTML = '';
  document.getElementById('scanCount').textContent = '';
  document.getElementById('tb-scancount').textContent = '0';
}

// ── VOL SURFACE ──────────────────────────────────────────
async function loadVolSurface(sym) {
  sym = sym || document.getElementById('scanSym').value.trim().toUpperCase() || 'SPY';
  const wrap = document.getElementById('volSurfaceWrap');
  wrap.innerHTML = '<div class="spinner">Building vol surface…</div>';
  document.getElementById('richnessBar').innerHTML = '<span class="spinner">Loading…</span>';

  try {
    const data = await api(`/vol/surface?symbol=${encodeURIComponent(sym)}&max_expirations=7&strike_count=21`);
    renderVolSurface(data);
    log(`Vol surface loaded: ${sym} (${data.count} contracts)`, 'ok');
  } catch(e) {
    wrap.innerHTML = `<div class="error-msg">Surface error: ${e.message}</div>`;
    log(`Vol surface error: ${e.message}`, 'bad');
  }
}

function renderVolSurface(d) {
  const exps = d.expirations || [];
  const strikes = d.strikes || [];
  const matrix = d.avg_iv_matrix || d.iv_matrix || [];
  const richness = d.richness_scores || {};
  const wrap = document.getElementById('volSurfaceWrap');
  const rb = document.getElementById('richnessBar');

  if (!exps.length) {
    wrap.innerHTML = '<div class="empty-msg">No surface data — load a symbol first</div>';
    rb.innerHTML = '';
    return;
  }

  // Richness bar
  const sorted = exps.map(e => ({e, r: richness[e] || {}})).sort((a,b)=>(b.r.richness_score||0)-(a.r.richness_score||0));
  rb.innerHTML = sorted.map(({e,r}) => `
    <div class="rich-exp" onclick="document.getElementById('scanExp').value='${e}'; switchTab('scanner');">
      <span class="re-date">${e}</span>
      <span class="re-iv">${r.avg_iv != null ? (r.avg_iv*100).toFixed(1)+'%' : '—'}</span>
      <span class="re-score">Score: ${r.richness_score != null ? Number(r.richness_score).toFixed(4) : '—'}</span>
    </div>`).join('');

  // Color scale
  const flat = matrix.flat().filter(v => v != null);
  const minIV = flat.length ? Math.min(...flat) : 0;
  const maxIV = flat.length ? Math.max(...flat) : 1;
  const ivColor = (v) => {
    if (v == null) return 'transparent';
    const t = maxIV > minIV ? (v - minIV) / (maxIV - minIV) : 0.5;
    const r = Math.round(30 + t * 200);
    const g = Math.round(140 - t * 90);
    const b = Math.round(200 - t * 120);
    return `rgba(${r},${g},${b},0.5)`;
  };

  // Matrix view selector
  const matrices = {avg: matrix, call: d.call_iv_matrix||matrix, put: d.put_iv_matrix||matrix, skew: d.skew_matrix||[]};
  let activeView = 'avg';

  const buildTable = (m) => {
    if (!m||!m.length) return '<div class="empty-msg">No data</div>';
    const fv = m.flat().filter(v=>v!=null);
    const mn = fv.length ? Math.min(...fv) : 0;
    const mx = fv.length ? Math.max(...fv) : 1;
    const clr = (v) => {
      if (v==null) return 'transparent';
      const t = mx>mn ? (v-mn)/(mx-mn) : 0.5;
      const r = Math.round(30+t*200), g=Math.round(140-t*90), b=Math.round(200-t*120);
      return `rgba(${r},${g},${b},0.5)`;
    };
    let html = '<table class="vol-matrix"><thead><tr><th>Exp \\ Strike</th>';
    html += strikes.map(s=>`<th>${Number(s).toFixed(1)}</th>`).join('');
    html += '</tr></thead><tbody>';
    exps.forEach((exp, ri) => {
      html += `<tr><th class="exp-label">${exp}</th>`;
      strikes.forEach((_, ci) => {
        const v = m[ri]?.[ci];
        const bg = clr(v);
        html += `<td style="background:${bg}">${v!=null?(Number(v)*100).toFixed(2):'—'}</td>`;
      });
      html += '</tr>';
    });
    html += '</tbody></table>';
    return html;
  };

  wrap.innerHTML = `
    <div style="display:flex;gap:4px;padding:6px 6px 0;flex-shrink:0">
      <button class="btn sm" onclick="setVolView('avg',this)">Avg IV</button>
      <button class="btn sm" onclick="setVolView('call',this)">Call IV</button>
      <button class="btn sm" onclick="setVolView('put',this)">Put IV</button>
      <button class="btn sm" onclick="setVolView('skew',this)">Skew</button>
      <span class="muted" style="font-size:9px;align-self:center;margin-left:4px">Click cell row = expiration, click richness card above to jump to expiration filter</span>
    </div>
    <div id="volMatrixContent" style="padding:6px;overflow:auto">${buildTable(matrices.avg)}</div>
    <div style="padding:4px 8px;font-size:9px;color:var(--muted)">
      <span style="display:inline-block;width:12px;height:12px;background:rgba(30,140,200,.5);vertical-align:middle;border-radius:2px"></span> Low IV &nbsp;
      <span style="display:inline-block;width:12px;height:12px;background:rgba(230,50,80,.5);vertical-align:middle;border-radius:2px"></span> High IV
    </div>`;

  window._volMatrices = matrices;
}

function setVolView(key, btn) {
  const m = window._volMatrices;
  if (!m) return;
  document.getElementById('volMatrixContent').innerHTML = buildVolMatrix(m[key]);
  document.querySelectorAll('#volSurfaceWrap .btn.sm').forEach(b => b.style.borderColor = '');
  btn.style.borderColor = 'var(--accent)';
  btn.style.color = 'var(--accent)';
}

function buildVolMatrix(m) {
  if (!m||!m.length) return '<div class="empty-msg">No data for this view</div>';
  const fv = m.flat().filter(v=>v!=null);
  const mn = fv.length ? Math.min(...fv) : 0;
  const mx = fv.length ? Math.max(...fv) : 1;
  const clr = (v) => {
    if (v==null) return 'transparent';
    const t = mx>mn?(v-mn)/(mx-mn):0.5;
    return `rgba(${Math.round(30+t*200)},${Math.round(140-t*90)},${Math.round(200-t*120)},0.5)`;
  };
  // Need exps/strikes from closure - use last loaded
  const data = window._lastVolData;
  if (!data) return '<div class="empty-msg">No data</div>';
  const exps = data.expirations || [];
  const strikes = data.strikes || [];
  let html = '<table class="vol-matrix"><thead><tr><th>Exp \\ Strike</th>';
  html += strikes.map(s=>`<th>${Number(s).toFixed(1)}</th>`).join('');
  html += '</tr></thead><tbody>';
  exps.forEach((exp,ri) => {
    html += `<tr><th class="exp-label">${exp}</th>`;
    strikes.forEach((_,ci) => {
      const v = m[ri]?.[ci];
      html += `<td style="background:${clr(v)}">${v!=null?(Number(v)*100).toFixed(2):'—'}</td>`;
    });
    html += '</tr>';
  });
  return html + '</tbody></table>';
}

// ── TABS ─────────────────────────────────────────────────
function switchTab(id) {
  document.querySelectorAll('#tab-scanner,#tab-surface').forEach(el => {
    el.classList.toggle('active', el.id==='tab-'+id);
  });
  document.querySelectorAll('.tabs:first-of-type .tab').forEach((t,i) => {
    t.classList.toggle('active', i===(id==='scanner'?0:1));
  });
}

function switchDetailTab(id) {
  document.querySelectorAll('#tab-detail,#tab-roll').forEach(el => {
    el.classList.toggle('active', el.id==='tab-'+id);
  });
}

// ── ALERTS ───────────────────────────────────────────────
async function enableAlerts() {
  if (!('Notification' in window)) {
    document.getElementById('alertStatus').textContent = 'Not supported in this browser';
    return;
  }
  const perm = await Notification.requestPermission();
  alertsEnabled = perm === 'granted';
  document.getElementById('alertStatus').textContent = alertsEnabled
    ? '✓ Desktop alerts active'
    : '✗ Permission denied';
  if (alertsEnabled) document.getElementById('notifyBtn').textContent = '🔔 ACTIVE';
  log(`Desktop alerts: ${perm}`, alertsEnabled?'ok':'warn');
}

function sendDesktopAlert(title, body) {
  if (!alertsEnabled) return;
  new Notification(title, {body, icon: ''});
}

// ── AUTO REFRESH ─────────────────────────────────────────
function toggleAutoRefresh() {
  const on = document.getElementById('autoRefreshChk').checked;
  if (on) {
    autoRefreshTimer = setInterval(fullRefresh, 5*60*1000);
    document.getElementById('autoRefreshStatus').textContent = 'Refreshing every 5 min';
    log('Auto-refresh enabled (5 min)', 'ok');
  } else {
    clearInterval(autoRefreshTimer);
    autoRefreshTimer = null;
    document.getElementById('autoRefreshStatus').textContent = '';
    log('Auto-refresh disabled');
  }
}

async function fullRefresh() {
  document.getElementById('refreshBtn').textContent = '↻ …';
  try {
    await loadPositions();
    const sym = document.getElementById('scanSym').value.trim().toUpperCase() || 'SPY';
    await api(`/refresh/symbol?symbol=${encodeURIComponent(sym)}`);
    if (document.getElementById('scanBody').innerHTML && scanResults.length) {
      await runScan();
    }
    log('Full refresh complete', 'ok');
  } catch(e) {
    log('Refresh error: ' + e.message, 'bad');
  }
  document.getElementById('refreshBtn').textContent = '↺ REFRESH';
}

// ── CACHE STATUS ─────────────────────────────────────────
async function loadCacheStatus() {
  try {
    const d = await api('/cache/status');
    const el = document.getElementById('cacheStatus');
    el.textContent = `Source: ${d.active_chain_source || '—'} | ${d.count || 0} symbols: ${(d.symbols||[]).join(', ')||'none'}`;
    updateSourceBadge(d.active_chain_source || 'unknown');
  } catch(e) {
    document.getElementById('cacheStatus').textContent = 'Error: ' + e.message;
  }
}

// ── INIT ─────────────────────────────────────────────────
(async () => {
  renderWatchlist();
  await loadPositions();
  await loadCacheStatus();
  // Optionally pre-load SPY
  try {
    await populateExpFilter();
  } catch(e) {}
  log('Granite Trader ready', 'ok');
})();
</script>
</body>
</html>

'@
Write-File (Join-Path $FRONTEND "index.html") $idx

if (-not $SkipGit -and (Test-Path (Join-Path $Root ".git"))) {
    Push-Location $Root
    git add -A
    if (git status --porcelain) {
        git commit -m "v0.4 ultrawide UI + cache Schwab fallback fix"
        git push
        Write-OK "Git push complete."
    } else {
        Write-Info "Nothing to commit."
    }
    Pop-Location
}

Write-OK "=== v0.4 install complete ==="
Write-Host "Restart the app then open http://localhost:5500" -ForegroundColor Cyan
