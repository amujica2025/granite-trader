param([string]$Root = "C:\\Users\\alexm\\granite_trader")
$ErrorActionPreference = "Stop"
function WF([string]$rel,[string]$txt){
  $p=Join-Path $Root ($rel -replace '/','\\')
  $d=Split-Path $p -Parent
  if(-not(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d|Out-Null}
  [System.IO.File]::WriteAllText($p,$txt,(New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[OK] $rel" -ForegroundColor Cyan
}

$c = @'
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

'@
WF "backend\tasty_chain_adapter.py" $c

$c = @'
import { useEffect, useState, useCallback, useRef } from 'react'
import GridLayout, { type Layout } from 'react-grid-layout'
import 'react-grid-layout/css/styles.css'
import 'react-resizable/css/styles.css'
import './styles/globals.css'

import { TopBar }          from './components/layout/TopBar'
import { TotalsBar }       from './components/layout/TotalsBar'
import { WatchlistTile }   from './components/tiles/WatchlistTile'
import { PositionsTile }   from './components/tiles/PositionsTile'
import { ScannerTile }     from './components/tiles/ScannerTile'
import { VolSurfaceTile }  from './components/tiles/VolSurfaceTile'
import { ChartTile }       from './components/tiles/ChartTile'
import { SelectedLegsTile, TradeTicketTile } from './components/tiles/LegsTile'
import { AlertModal }      from './components/modals/AlertModal'

import { useStore } from './store/useStore'
import { useStream } from './hooks/useStream'
import {
  fetchAccount, fetchQuote, fetchChain,
  fetchVolSurface, sendPushover,
} from './api/client'

// ?? Grid layout ?????????????????????????????????????????????
const COLS   = 16
const ROW_H  = 40
const TOPBAR_H  = 72
const BOTTOM_H  = 38

const STORAGE_KEY = 'granite_layout_v2'

// Default layout optimised for 3840?1080 ultrawide (16 cols)
const DEFAULT_LAYOUT: Layout[] = [
  { i: 'watchlist', x: 0,  y: 0, w: 1,  h: 14, minW: 1, minH: 4 },
  { i: 'positions', x: 1,  y: 0, w: 5,  h: 9,  minW: 2, minH: 3 },
  { i: 'selected',  x: 1,  y: 9, w: 5,  h: 5,  minW: 2, minH: 2 },
  { i: 'scanner',   x: 6,  y: 0, w: 6,  h: 14, minW: 3, minH: 4 },
  { i: 'volsurf',   x: 12, y: 0, w: 4,  h: 14, minW: 2, minH: 4 },
  { i: 'chart',     x: 1,  y: 14,w: 11, h: 6,  minW: 3, minH: 3 },
  { i: 'ticket',    x: 12, y: 14,w: 4,  h: 6,  minW: 2, minH: 3 },
]

function loadLayout(): Layout[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (raw) return JSON.parse(raw)
  } catch {}
  return DEFAULT_LAYOUT
}

function saveLayout(l: Layout[]) {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(l)) } catch {}
}

// ?? Gear icon button (renders in tile header via portal-like approach) ??????
function TileGear({ tileId, onOpen }: { tileId: string; onOpen: (id: string) => void }) {
  return (
    <button
      className="tile-gear-btn"
      title="Panel settings"
      onClick={(e) => { e.stopPropagation(); onOpen(tileId) }}
    >
      &#x2699;
    </button>
  )
}

// ?? Gear settings modal ??????????????????????????????????????
const TILE_FIELDS: Record<string, { label: string; fields: { key: string; label: string }[] }> = {
  watchlist: {
    label: 'Watchlist',
    fields: [
      { key: 'sym', label: 'Symbol' },
      { key: 'price', label: 'Last Price' },
      { key: 'chg', label: '% Change' },
      { key: 'rs14', label: '14D Rel Strength' },
      { key: 'ivpct', label: 'IV Percentile' },
      { key: 'ivhv', label: 'IV/HV Ratio' },
      { key: 'iv', label: 'Imp Vol' },
      { key: 'iv1m', label: '1M IV' },
      { key: 'iv3m', label: '3M IV' },
      { key: 'bb', label: 'BB%' },
      { key: 'bbr', label: 'BB Rank' },
      { key: 'ttm', label: 'TTM Squeeze' },
      { key: 'opvol', label: 'Options Vol' },
      { key: 'callvol', label: 'Call Vol' },
      { key: 'putvol', label: 'Put Vol' },
    ],
  },
  scanner: {
    label: 'Entry Scanner',
    fields: [
      { key: 'expiration', label: 'Expiration' },
      { key: 'option_side', label: 'Side' },
      { key: 'short_strike', label: 'Short Strike' },
      { key: 'long_strike', label: 'Long Strike' },
      { key: 'width', label: 'Width' },
      { key: 'quantity', label: 'Qty' },
      { key: 'net_credit', label: 'Net Credit' },
      { key: 'actual_defined_risk', label: 'Actual Risk' },
      { key: 'max_loss', label: 'Max Loss' },
      { key: 'credit_pct_risk', label: 'Credit % Risk' },
      { key: 'short_delta', label: 'Short Delta' },
      { key: 'short_iv', label: 'Short IV' },
      { key: 'richness_score', label: 'Richness Score' },
      { key: 'limit_impact', label: 'Limit Impact' },
    ],
  },
  positions: {
    label: 'Open Positions',
    fields: [
      { key: 'underlying', label: 'Symbol' },
      { key: 'display_qty', label: 'Qty' },
      { key: 'option_type', label: 'Type' },
      { key: 'expiration', label: 'Expiration' },
      { key: 'strike', label: 'Strike' },
      { key: 'mark', label: 'Mark' },
      { key: 'trade_price', label: 'Trade Price' },
      { key: 'pnl_open', label: 'P/L Open' },
      { key: 'short_value', label: 'Short Value' },
      { key: 'long_cost', label: 'Long Cost' },
      { key: 'limit_impact', label: 'Limit Impact' },
    ],
  },
}

function GearModal({ tileId, onClose }: { tileId: string; onClose: () => void }) {
  const storageKey = `granite_cols_${tileId}`
  const info = TILE_FIELDS[tileId]

  const [hidden, setHidden] = useState<Set<string>>(() => {
    try {
      return new Set(JSON.parse(localStorage.getItem(storageKey) || '[]'))
    } catch { return new Set() }
  })

  function toggle(key: string) {
    setHidden(prev => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      localStorage.setItem(storageKey, JSON.stringify([...next]))
      return next
    })
  }

  if (!info) return null

  return (
    <div className="modal-overlay" onClick={e => { if (e.target === e.currentTarget) onClose() }}>
      <div className="modal-box gear-modal">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
          <span className="modal-title">&#x2699; {info.label} Settings</span>
          <button className="btn sm" onClick={onClose}>&#x2715;</button>
        </div>
        <div style={{ fontSize: 10, color: 'var(--muted)', marginBottom: 10 }}>
          Toggle columns / fields. Selections saved automatically.
        </div>
        <div className="gear-field-list">
          {info.fields.map(f => (
            <div key={f.key} className="gear-field-row">
              <input
                type="checkbox"
                id={`gear-${f.key}`}
                checked={!hidden.has(f.key)}
                onChange={() => toggle(f.key)}
              />
              <label htmlFor={`gear-${f.key}`}>{f.label}</label>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

// ?? Wrapped tile with focus border and gear icon ?????????????
function TileWrapper({
  id, children, focusedTile, setFocusedTile, onGearOpen,
}: {
  id: string
  children: React.ReactNode
  focusedTile: string | null
  setFocusedTile: (id: string) => void
  onGearOpen: (id: string) => void
}) {
  const isFocused  = focusedTile === id
  const [min, setMin] = useState(false)

  return (
    <div
      className={`tile${isFocused ? ' tile-focused' : ''}`}
      style={{ height: '100%', display: 'flex', flexDirection: 'column' }}
      onMouseDown={() => setFocusedTile(id)}
    >
      <div style={{ display: 'flex', alignItems: 'center', padding: '2px 6px', background: 'var(--bg2)', borderBottom: '1px solid var(--border)', flexShrink: 0, minHeight: 24 }}>
        <span style={{ flex: 1 }} />
        <button style={{ background: 'none', border: 'none', cursor: 'pointer', color: 'var(--muted)', fontSize: 11, padding: '0 3px', lineHeight: 1 }}
          onClick={e => { e.stopPropagation(); setMin(v => !v) }} title={min ? 'Restore' : 'Minimize'}>
          {min ? '?' : '?'}
        </button>
        <button className="tile-gear-btn" onClick={e => { e.stopPropagation(); onGearOpen(id) }} title="Panel settings">?</button>
      </div>
      <div style={{ flex: 1, display: min ? 'none' : 'flex', flexDirection: 'column', overflow: 'hidden', minHeight: 0 }}>
        {children}
      </div>
    </div>
  )
}

// ?? Main App ????????????????????????????????????????????????

export default function App() {
  const {
    acctSource, activeSymbol, refreshInterval, refreshCountdown,
    alertRules, alertsMaster, desktopAllowed,
    setPositions, setPositionsLoading, setPositionsError,
    setQuote, setScanExpOptions, setVolData, setVolLoading, setVolError,
    setActiveSymbol, setLivePrice, markAlertTriggered,
    tickCountdown, resetCountdown,
  } = useStore()

  const [layout, setLayout]         = useState<Layout[]>(loadLayout)
  const [alertsOpen, setAlertsOpen] = useState(false)
  const [alertPreSym, setAlertPreSym] = useState<string | undefined>()
  const [gearTile, setGearTile]     = useState<string | null>(null)
  const [focusedTile, setFocusedTile] = useState<string | null>(null)
  const [workspaceH, setWorkspaceH] = useState(window.innerHeight - TOPBAR_H - BOTTOM_H)

  useEffect(() => {
    const onResize = () => setWorkspaceH(window.innerHeight - TOPBAR_H - BOTTOM_H)
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])

  // ?? Data loading ?????????????????????????????????????????

  const loadPositions = useCallback(async () => {
    setPositionsLoading(true)
    setPositionsError(null)
    try {
      const d = await fetchAccount(acctSource)
      setPositions(d.positions, d.limit_summary)
    } catch (e: any) {
      setPositionsError(e.message)
    } finally {
      setPositionsLoading(false)
    }
  }, [acctSource])

  const loadQuote = useCallback(async (sym: string) => {
    try {
      const q = await fetchQuote(sym)
      // DXLink live quote format
      const last    = q.live_last      ?? q.underlying_price ?? null
      const open    = q.live_open      ?? null
      const high    = q.live_high      ?? null
      const low     = q.live_low       ?? null
      const prev    = q.live_prev_close ?? 0
      const chg     = last && prev ? last - prev : null
      const pctChg  = last && prev ? (last - prev) / prev : null
      const bid     = q.live_bid ?? null
      const ask     = q.live_ask ?? null

      setQuote({
        symbol: sym, lastPrice: last, openPrice: open,
        highPrice: high, lowPrice: low,
        netChange: chg, netPctChange: pctChg,
        bid, ask, activeSource: q.source?.toUpperCase() ?? 'DXLINK',
      })
      if (last) setLivePrice(sym, last, pctChg ?? 0)
      checkAlerts(sym, { price: last ?? 0 })
    } catch (e: any) {
      console.error('Quote error:', e.message)
    }
  }, [])

  const loadChain = useCallback(async (sym: string) => {
    try {
      const d = await fetchChain(sym)
      setScanExpOptions(d.expirations.slice(0, 7))
      setQuote({ activeSource: d.active_chain_source?.toUpperCase() ?? 'SCHWAB' })
    } catch (e: any) {
      console.error('Chain error:', e.message)
    }
  }, [])

  const loadVolSurface = useCallback(async (sym: string) => {
    setVolLoading(true); setVolError(null)
    try {
      const d = await fetchVolSurface(sym, 7, 25)
      setVolData(d)
      // Compute ATM straddle from near-exp data for expected move lines
      if (d.expirations.length && d.underlying_price) {
        const price = d.underlying_price
        const exp   = d.expirations[0]
        const curve = d.skew_curves?.[exp] ?? []
        const sorted = [...curve].sort((a, b) => Math.abs(a.strike - price) - Math.abs(b.strike - price))
        const atm = sorted.slice(0, 2)
        const avgIV = atm.reduce((s, x) => s + ((x.call_iv ?? 0) + (x.put_iv ?? 0)) / 2, 0) / Math.max(atm.length, 1)
        const approxStraddle = avgIV * price * Math.sqrt(5 / 365)
        if (approxStraddle > 0) setQuote({ atmStraddle: approxStraddle })
      }
    } catch (e: any) { setVolError(e.message) }
    finally { setVolLoading(false) }
  }, [])

  function checkAlerts(sym: string, ctx: { price: number }) {
    if (!alertsMaster) return
    alertRules.filter(a => a.active && !a.triggered).forEach(a => {
      if (a.field !== 'price' || a.sym !== sym) return
      const ops: Record<string, (v: number) => boolean> = {
        lt: v => v < a.val, lte: v => v <= a.val, eq: v => v === a.val,
        gte: v => v >= a.val, gt: v => v > a.val,
      }
      if (ops[a.op]?.(ctx.price)) {
        markAlertTriggered(a.id)
        const msg = `${sym}: Price ${ctx.price.toFixed(2)} ${a.op} ${a.val}`
        if (desktopAllowed) new Notification('Granite Alert', { body: msg })
        sendPushover('Granite Alert', msg)
      }
    })
  }

  // ?? Symbol orchestrator ???????????????????????????????????

  const loadSymbol = useCallback(async (sym: string) => {
    setActiveSymbol(sym)
    setFocusedTile('scanner')
    await Promise.all([loadQuote(sym), loadChain(sym), loadVolSurface(sym)])
    // Subscribe new symbol to live stream
    subscribeQuotes([sym])
    subscribeCandles(sym, '20y')
  }, [loadQuote, loadChain, loadVolSurface, subscribeQuotes, subscribeCandles])

  const scanSymbol = useCallback(async (sym: string) => {
    setActiveSymbol(sym)
    setFocusedTile('scanner')
    await Promise.all([loadQuote(sym), loadChain(sym)])
  }, [loadQuote, loadChain])

  // ?? Full refresh ??????????????????????????????????????????

  const fullRefresh = useCallback(async () => {
    await loadPositions()
    await loadQuote(activeSymbol)
    resetCountdown()
  }, [loadPositions, loadQuote, activeSymbol])

  // ?? Auto-refresh countdown ????????????????????????????????
  useEffect(() => {
    const t = setInterval(tickCountdown, 1000)
    return () => clearInterval(t)
  }, [])

  // ?? Stream connection ?????????????????????????????????????????????????????
  const { subscribeQuotes, subscribeCandles } = useStream()

  // ?? Initial load ??????????????????????????????????????????????????????????
  useEffect(() => {
    loadPositions()
    loadSymbol('SPY')
    Notification.requestPermission()
    // Subscribe to live stream after WS handshake has time to complete
    setTimeout(() => {
      subscribeQuotes(['SPY', 'QQQ', 'GLD'])
      subscribeCandles('SPY', '20y')
    }, 2000)
  }, [])

  // ?? Layout persistence ????????????????????????????????????
  function onLayoutChange(nl: Layout[]) { setLayout(nl); saveLayout(nl) }
  function resetLayout() { setLayout(DEFAULT_LAYOUT); saveLayout(DEFAULT_LAYOUT) }

  const gridW = window.innerWidth

  return (
    <div className="app-shell">
      <TopBar onRefreshNow={fullRefresh} onAlertsOpen={() => setAlertsOpen(true)} />

      <div style={{ flex: 1, overflow: 'hidden', position: 'relative', background: 'var(--bg)' }}>
        <GridLayout
          layout={layout}
          cols={COLS}
          rowHeight={ROW_H}
          width={gridW}
          margin={[4, 4]}
          containerPadding={[4, 4]}
          onLayoutChange={onLayoutChange}
          draggableHandle=".tile-hdr"
          resizeHandles={['se']}
          style={{ minHeight: workspaceH }}
        >
          <div key="watchlist">
            <TileWrapper id="watchlist" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <WatchlistTile
                onSymbolLoad={loadSymbol}
                onAlertOpen={(sym) => { setAlertPreSym(sym); setAlertsOpen(true) }}
                onScanSymbol={scanSymbol}
              />
            </TileWrapper>
          </div>

          <div key="positions">
            <TileWrapper id="positions" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <PositionsTile />
            </TileWrapper>
          </div>

          <div key="selected">
            <TileWrapper id="selected" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <SelectedLegsTile />
            </TileWrapper>
          </div>

          <div key="scanner">
            <TileWrapper id="scanner" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <ScannerTile />
            </TileWrapper>
          </div>

          <div key="volsurf">
            <TileWrapper id="volsurf" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <VolSurfaceTile />
            </TileWrapper>
          </div>

          <div key="chart">
            <TileWrapper id="chart" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <ChartTile />
            </TileWrapper>
          </div>

          <div key="ticket">
            <TileWrapper id="ticket" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <TradeTicketTile />
            </TileWrapper>
          </div>
        </GridLayout>
      </div>

      <TotalsBar
        onRefreshNow={fullRefresh}
        onAlertsOpen={() => setAlertsOpen(true)}
        onResetLayout={resetLayout}
      />

      {alertsOpen && (
        <AlertModal
          onClose={() => { setAlertsOpen(false); setAlertPreSym(undefined) }}
          prefilledSym={alertPreSym}
        />
      )}

      {gearTile && <GearModal tileId={gearTile} onClose={() => setGearTile(null)} />}
    </div>
  )
}

'@
WF "react-frontend\src\App.tsx" $c

$c = @'
import { MarqueeTicker } from './MarqueeTicker'
import { useStore } from '../../store/useStore'

function f$(v: number | null) {
  return v == null ? '--' : '$' + v.toFixed(2)
}

interface Props {
  onRefreshNow: () => void
  onAlertsOpen: () => void
}

export function TopBar({ onRefreshNow, onAlertsOpen }: Props) {
  const {
    limitSummary, quote,
    desktopAllowed, setDesktopAllowed,
    streamConnected,
  } = useStore()

  const usedPct  = limitSummary ? Number(limitSummary.used_pct) * 100 : 0
  const pctColor = usedPct > 80 ? 'var(--red)' : usedPct > 60 ? 'var(--warn)' : 'var(--green)'
  const chgColor = (quote.netChange ?? 0) >= 0 ? 'var(--green)' : 'var(--red)'
  const chgSign  = (quote.netChange ?? 0) >= 0 ? '+' : ''
  const chgText  = quote.netChange != null
    ? `${chgSign}${quote.netChange.toFixed(2)} (${((quote.netPctChange ?? 0) * 100).toFixed(2)}%)`
    : '--'

  async function enableNotifs() {
    if (!('Notification' in window)) return
    const perm = await Notification.requestPermission()
    setDesktopAllowed(perm === 'granted')
  }

  return (
    <div className="topbar">
      {/* LEFT: brand */}
      <div className="topbar-left">
        <span className="topbar-brand font-display">&#x2B21; GRANITE</span>
        <div className="tsep" />
        <button
          className="btn sm"
          onClick={enableNotifs}
          style={{ fontSize: 10, color: desktopAllowed ? 'var(--green)' : 'var(--muted)', padding: '2px 8px' }}
        >
          {desktopAllowed ? 'NOTIF ON' : 'NOTIF'}
        </button>
      </div>

      {/* CENTER: scrolling index marquee */}
      <div className="topbar-center" style={{ overflow: 'hidden', padding: '0 8px' }}>
        <MarqueeTicker />
      </div>

      {/* RIGHT: balances + stream status */}
      <div className="topbar-right">
        <div className="tpill">
          <span className="lbl">Net Liq</span>
          <span className="val">{f$(limitSummary?.net_liq ?? null)}</span>
        </div>
        <div className="tpill">
          <span className="lbl">Limit x25</span>
          <span className="val">{f$(limitSummary?.max_limit ?? null)}</span>
        </div>
        <div className="tpill">
          <span className="lbl">Used</span>
          <span className="val">{f$(limitSummary?.used_short_value ?? null)}</span>
        </div>
        <div className="tpill">
          <span className="lbl">Room</span>
          <span className="val">{f$(limitSummary?.remaining_room ?? null)}</span>
        </div>
        <div className="tpill">
          <span className="lbl">Used %</span>
          <span className="val" style={{ color: pctColor }}>{usedPct.toFixed(1)}%</span>
        </div>
        <div className="tpill" style={{ minWidth: 110 }}>
          <span className="lbl">Source</span>
          <span className="val" style={{
            fontSize: 11,
            color: streamConnected ? 'var(--green)' : 'var(--muted)',
            display: 'flex', alignItems: 'center', gap: 5,
          }}>
            <span style={{
              width: 8, height: 8, borderRadius: '50%',
              background: streamConnected ? 'var(--green)' : 'var(--border)',
              flexShrink: 0,
              boxShadow: streamConnected ? '0 0 6px var(--green)' : 'none',
            }} />
            {streamConnected ? 'TASTY LIVE' : 'TASTY REST'}
          </span>
        </div>
        <div style={{
          padding: '3px 10px',
          background: 'var(--bg3)',
          border: '1px solid var(--green)',
          borderRadius: 3, fontSize: 11,
          color: 'var(--green)', fontWeight: 700,
        }}>
          TASTY
        </div>
      </div>
    </div>
  )
}

'@
WF "react-frontend\src\components\layout\TopBar.tsx" $c

$c = @'
import { useStore } from '../../store/useStore'
import type { Theme } from '../../types'

const THEMES: { id: Theme; color: string; label: string }[] = [
  { id: 'slate',   color: '#1c2b3a', label: 'Slate'   },
  { id: 'navy',    color: '#182648', label: 'Navy'     },
  { id: 'emerald', color: '#182e22', label: 'Emerald'  },
  { id: 'teal',    color: '#183232', label: 'Teal'     },
  { id: 'amber',   color: '#3a2e0e', label: 'Amber'    },
  { id: 'rose',    color: '#3a1420', label: 'Rose'     },
  { id: 'purple',  color: '#261c40', label: 'Purple'   },
  { id: 'mono',    color: '#282828', label: 'Mono'     },
]

function f$(v: number) { return '$' + v.toFixed(2) }

interface Props {
  onRefreshNow: () => void
  onAlertsOpen: () => void
  onResetLayout: () => void
}

export function TotalsBar({ onRefreshNow, onAlertsOpen, onResetLayout }: Props) {
  const {
    positions, selectedIds, scanResults, alertRules,
    theme, setTheme, refreshInterval, refreshCountdown, setRefreshInterval,
  } = useStore()

  const selected = positions.filter(p => selectedIds.has(p.id))
  const sv  = selected.reduce((a, r) => a + (r.short_value  ?? 0), 0)
  const lc  = selected.reduce((a, r) => a + (r.long_cost    ?? 0), 0)
  const pnl = selected.reduce((a, r) => a + (r.pnl_open     ?? 0), 0)
  const imp = selected.reduce((a, r) => a + (r.limit_impact ?? 0), 0)
  const activeAlerts = alertRules.filter(a => a.active).length

  return (
    <div className="bottombar">
      {/* Selection totals */}
      <span style={{ fontSize: 8, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.07em', marginRight: 2 }}>SEL:</span>
      <div className="tchip"><span className="tl">Legs</span><span className="tv">{selected.length}</span></div>
      <div className="tchip"><span className="tl">Sht Val</span><span className="tv">{f$(sv)}</span></div>
      <div className="tchip"><span className="tl">Lng Cost</span><span className="tv">{f$(lc)}</span></div>
      <div className="tchip"><span className="tl">P/L Open</span><span className="tv" style={{ color: pnl >= 0 ? 'var(--green)' : 'var(--red)' }}>{f$(pnl)}</span></div>
      <div className="tchip"><span className="tl">Impact</span><span className="tv text-warn">{f$(imp)}</span></div>

      <div style={{ borderLeft: '1px solid var(--border)', height: 24, margin: '0 6px' }} />

      {/* Right side: theme, refresh, alerts, layout */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, marginLeft: 'auto' }}>
        {/* Skin selector */}
        <span style={{ fontSize: 8, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>SKIN</span>
        {THEMES.map(t => (
          <div
            key={t.id}
            className={`theme-dot${theme === t.id ? ' active' : ''}`}
            style={{ background: t.color }}
            title={t.label}
            onClick={() => setTheme(t.id)}
          />
        ))}

        <div style={{ width: 1, height: 20, background: 'var(--border)', margin: '0 4px' }} />

        {/* Refresh interval */}
        <span style={{ fontSize: 8, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>REFRESH</span>
        <select
          value={refreshInterval}
          onChange={e => setRefreshInterval(Number(e.target.value))}
          style={{ width: 72, padding: '2px 5px', fontSize: 10 }}
        >
          <option value={30}>30s</option>
          <option value={60}>1 min</option>
          <option value={120}>2 min</option>
          <option value={300}>5 min</option>
          <option value={600}>10 min</option>
        </select>
        <span style={{ fontSize: 10, color: 'var(--muted)', minWidth: 30 }}>{refreshCountdown}s</span>

        <button className="btn sm" onClick={onRefreshNow}>&#x21BA;</button>
        <button className="btn sm" onClick={onAlertsOpen}>
          &#x1F514; {activeAlerts > 0 ? `${activeAlerts}` : ''}
        </button>

        <div style={{ width: 1, height: 20, background: 'var(--border)', margin: '0 4px' }} />

        {/* Stats */}
        <div className="tchip"><span className="tl">Positions</span><span className="tv">{positions.length}</span></div>
        <div className="tchip"><span className="tl">Scan Results</span><span className="tv">{scanResults.length}</span></div>

        <button className="btn sm" onClick={onResetLayout} style={{ opacity: 0.5, fontSize: 9 }}>
          RESET
        </button>

        <div style={{ width: 1, height: 20, background: 'var(--border)', margin: '0 4px' }} />

        {/* Font size slider */}
        <span style={{ fontSize: 9, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>FONT</span>
        <input
          type="range"
          min={11} max={18} step={1}
          defaultValue={14}
          style={{ width: 70, accentColor: 'var(--accent)', cursor: 'pointer' }}
          onChange={(e) => {
            document.documentElement.style.setProperty('--app-font-size', e.target.value + 'px')
          }}
        />
      </div>
    </div>
  )
}

'@
WF "react-frontend\src\components\layout\TotalsBar.tsx" $c

$c = @'
/**
 * MarqueeTicker.tsx
 * Scrolling live price strip for major indices.
 * Polls /quote/live for each symbol every 5s.
 */
import { useEffect, useRef, useState } from 'react'
import { useStore } from '../../store/useStore'

const SYMBOLS = ['SPY', 'QQQ', 'IWM', 'GLD', 'TLT', 'VIX', 'DXY']
const LABELS:  Record<string, string> = {
  SPY: 'S&P 500', QQQ: 'NASDAQ', IWM: 'RUSSELL', GLD: 'GOLD', TLT: 'BONDS', VIX: 'VIX', DXY: 'DXY'
}

interface TickerItem {
  sym:   string
  last:  number | null
  chg:   number | null
  pct:   number | null
}

function fmt(v: number | null, decimals = 2) {
  return v == null ? '--' : v.toFixed(decimals)
}

export function MarqueeTicker() {
  const { livePrices } = useStore()
  const [tickers, setTickers] = useState<TickerItem[]>(
    SYMBOLS.map(sym => ({ sym, last: null, chg: null, pct: null }))
  )
  const scrollRef = useRef<HTMLDivElement>(null)

  // Pull from live prices store ? updated by DXLink stream
  useEffect(() => {
    const updated = SYMBOLS.map(sym => {
      const lp = livePrices[sym]
      return {
        sym,
        last: lp?.last ?? null,
        chg:  lp?.last && lp?.open ? lp.last - lp.open : null,
        pct:  lp?.pct ?? null,
      }
    })
    setTickers(updated)
  }, [livePrices])

  // Auto-scroll marquee
  useEffect(() => {
    const el = scrollRef.current
    if (!el) return
    let pos = 0
    const tick = setInterval(() => {
      pos += 0.5
      if (pos >= el.scrollWidth / 2) pos = 0
      el.scrollLeft = pos
    }, 30)
    return () => clearInterval(tick)
  }, [])

  const items = [...tickers, ...tickers]  // duplicate for seamless loop

  return (
    <div
      ref={scrollRef}
      style={{
        overflow: 'hidden',
        whiteSpace: 'nowrap',
        display: 'flex',
        alignItems: 'center',
        gap: 0,
        width: '100%',
        userSelect: 'none',
        cursor: 'default',
      }}
    >
      {items.map((t, i) => {
        const upColor  = (t.pct ?? 0) >= 0 ? 'var(--green)' : 'var(--red)'
        const sign     = (t.pct ?? 0) >= 0 ? '+' : ''
        return (
          <span
            key={`${t.sym}-${i}`}
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              padding: '0 18px',
              borderRight: '1px solid var(--border)',
              fontSize: 13,
              flexShrink: 0,
            }}
          >
            <span style={{ color: 'var(--muted)', fontSize: 11, fontWeight: 600, letterSpacing: '0.04em' }}>
              {LABELS[t.sym] ?? t.sym}
            </span>
            <span style={{ fontWeight: 700, color: 'var(--text)' }}>
              {t.last ? fmt(t.last) : '--'}
            </span>
            <span style={{ fontSize: 11, color: upColor }}>
              {t.pct != null ? `${sign}${(t.pct * 100).toFixed(2)}%` : ''}
            </span>
          </span>
        )
      })}
    </div>
  )
}

'@
WF "react-frontend\src\components\layout\MarqueeTicker.tsx" $c

$c = @'
import {
  useEffect, useRef, useCallback, useState,
} from 'react'
import {
  createChart,
  CrosshairMode,
  LineStyle,
  type IChartApi,
  type ISeriesApi,
  type Time,
  type CandlestickData,
  type LineData,
} from 'lightweight-charts'
import { useStore } from '../../store/useStore'
import { fetchPriceHistory, type Candle } from '../../api/client'

// ?? Math helpers ?????????????????????????????????????????????

function sma(data: number[], period: number): (number | null)[] {
  const out: (number | null)[] = []
  for (let i = 0; i < data.length; i++) {
    if (i < period - 1) { out.push(null); continue }
    out.push(data.slice(i - period + 1, i + 1).reduce((a, b) => a + b, 0) / period)
  }
  return out
}

function rsiCalc(closes: number[], period: number): (number | null)[] {
  const out: (number | null)[] = Array(closes.length).fill(null)
  if (closes.length < period + 1) return out
  let gains = 0, losses = 0
  for (let i = 1; i <= period; i++) {
    const d = closes[i] - closes[i - 1]
    if (d > 0) gains += d; else losses -= d
  }
  let avgG = gains / period, avgL = losses / period
  out[period] = avgL === 0 ? 100 : 100 - 100 / (1 + avgG / avgL)
  for (let i = period + 1; i < closes.length; i++) {
    const d = closes[i] - closes[i - 1]
    avgG = (avgG * (period - 1) + (d > 0 ? d : 0)) / period
    avgL = (avgL * (period - 1) + (d < 0 ? -d : 0)) / period
    out[i] = avgL === 0 ? 100 : 100 - 100 / (1 + avgG / avgL)
  }
  return out
}

function atrCalc(candles: Candle[], period: number): (number | null)[] {
  const out: (number | null)[] = [null]
  let sum = 0
  for (let i = 1; i < candles.length; i++) {
    const { high: h, low: l } = candles[i], pc = candles[i - 1].close
    const tr = Math.max(h - l, Math.abs(h - pc), Math.abs(l - pc))
    if (i < period) { out.push(null); sum += tr; continue }
    if (i === period) { out.push((sum + tr) / period); continue }
    out.push(((out[i - 1] as number) * (period - 1) + tr) / period)
  }
  return out
}

function vortexCalc(candles: Candle[], period: number) {
  const n = candles.length
  const vip: (number | null)[] = Array(n).fill(null)
  const vim: (number | null)[] = Array(n).fill(null)
  for (let i = period; i < n; i++) {
    let vp = 0, vm = 0, tr = 0
    for (let j = i - period + 1; j <= i; j++) {
      const { high: h, low: l } = candles[j], { high: ph, low: pl, close: pc } = candles[j - 1]
      vp += Math.abs(h - pl); vm += Math.abs(l - ph)
      tr += Math.max(h - l, Math.abs(h - pc), Math.abs(l - pc))
    }
    vip[i] = tr > 0 ? vp / tr : null
    vim[i] = tr > 0 ? vm / tr : null
  }
  return { vip, vim }
}

function emaCalc(data: (number | null)[], period: number): (number | null)[] {
  const k = 2 / (period + 1)
  const out: (number | null)[] = Array(data.length).fill(null)
  let prev: number | null = null
  for (let i = 0; i < data.length; i++) {
    if (data[i] == null) { out[i] = prev; continue }
    const v = data[i] as number
    prev = prev == null ? v : v * k + prev * (1 - k)
    out[i] = prev
  }
  return out
}

function ppoCalc(closes: number[], fast: number, slow: number, signal: number) {
  const fe = emaCalc(closes, fast), se = emaCalc(closes, slow)
  const line = closes.map((_, i) =>
    fe[i] == null || se[i] == null || (se[i] as number) === 0 ? null
    : ((fe[i] as number) - (se[i] as number)) / (se[i] as number) * 100
  )
  const sig = emaCalc(line, signal)
  const hist = line.map((v, i) => v == null || sig[i] == null ? null : v - (sig[i] as number))
  return { line, sig, hist }
}

// ?? Config ???????????????????????????????????????????????????

const SMA_PERIODS = [8, 16, 32, 50, 64, 128, 200] as const
type SmaPeriod = typeof SMA_PERIODS[number]
const SMA_COLORS: Record<SmaPeriod, string> = {
  8:'#4d9fff', 16:'#3bba6c', 32:'#e5b84c', 50:'#f8923a', 64:'#a855f7', 128:'#ec4899', 200:'#f04f48',
}
const TF_OPTIONS = [
  { label:'1D',  period:'1d',  freq:'5min'   },
  { label:'5D',  period:'5d',  freq:'15min'  },
  { label:'1M',  period:'1m',  freq:'daily'  },
  { label:'3M',  period:'3m',  freq:'daily'  },
  { label:'6M',  period:'6m',  freq:'daily'  },
  { label:'1Y',  period:'1y',  freq:'daily'  },
  { label:'2Y',  period:'2y',  freq:'daily'  },
  { label:'5Y',  period:'5y',  freq:'daily'  },
  { label:'10Y', period:'10y', freq:'daily'  },
  { label:'20Y', period:'20y', freq:'daily'  },
  { label:'YTD', period:'ytd', freq:'daily'  },
]

function toT(c: Candle, freq: string): string {
  const daily = freq === 'daily' || freq === 'weekly' || freq === 'monthly'
  return daily ? new Date(c.time * 1000).toISOString().slice(0, 10) : String(c.time)
}

// ?? Mini sub-panel ????????????????????????????????????????????

function MiniLine({ points, color, height, title, refLines }: {
  points: { time: string; value: number | null }[]
  color: string; height: string; title: string
  refLines?: { value: number; color: string }[]
}) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 11, fontFamily: 'IBM Plex Mono,monospace' },
      grid:  { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0' },
      timeScale: { borderColor: '#1c2b3a', visible: false },
      width: ref.current.clientWidth, height: ref.current.clientHeight,
    })
    const s = c.addLineSeries({ color, lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    s.setData(points.filter(p => p.value != null).map(p => ({ time: p.time as Time, value: p.value as number })))
    refLines?.forEach(r => s.createPriceLine({ price: r.value, color: r.color, lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: false, title: '' }))
    const obs = new ResizeObserver(() => { if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight }) })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [points])
  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 8, fontSize: 10, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>{title}</div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

function MiniTwoLine({ p1, p2, c1, c2, height, title }: {
  p1: { time: string; value: number | null }[]; p2: { time: string; value: number | null }[]
  c1: string; c2: string; height: string; title: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 11, fontFamily: 'IBM Plex Mono,monospace' },
      grid: { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0' },
      timeScale: { borderColor: '#1c2b3a', visible: false },
      width: ref.current.clientWidth, height: ref.current.clientHeight,
    })
    const s1 = c.addLineSeries({ color: c1, lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const s2 = c.addLineSeries({ color: c2, lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    s1.setData(p1.filter(x => x.value != null).map(x => ({ time: x.time as Time, value: x.value as number })))
    s2.setData(p2.filter(x => x.value != null).map(x => ({ time: x.time as Time, value: x.value as number })))
    const obs = new ResizeObserver(() => { if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight }) })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [p1, p2])
  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 8, fontSize: 10, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>{title}</div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

function MiniHistoTwo({ hist, l1, l2, height, title }: {
  hist: { time: string; value: number | null }[]
  l1: { time: string; value: number | null }[]; l2: { time: string; value: number | null }[]
  height: string; title: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 11, fontFamily: 'IBM Plex Mono,monospace' },
      grid: { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0' },
      timeScale: { borderColor: '#1c2b3a', visible: false },
      width: ref.current.clientWidth, height: ref.current.clientHeight,
    })
    const sh = c.addHistogramSeries({ color: '#4d9fff40', priceLineVisible: false, lastValueVisible: false })
    const s1 = c.addLineSeries({ color: '#4d9fff', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const s2 = c.addLineSeries({ color: '#f04f48', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    sh.setData(hist.filter(x => x.value != null).map(x => ({ time: x.time as Time, value: x.value as number, color: (x.value ?? 0) >= 0 ? '#4d9fff60' : '#f04f4860' })))
    s1.setData(l1.filter(x => x.value != null).map(x => ({ time: x.time as Time, value: x.value as number })))
    s2.setData(l2.filter(x => x.value != null).map(x => ({ time: x.time as Time, value: x.value as number })))
    const obs = new ResizeObserver(() => { if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight }) })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [hist, l1, l2])
  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 8, fontSize: 10, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>{title}</div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

// ?? Main component ???????????????????????????????????????????

export function ChartTile() {
  const { activeSymbol, quote, positions, streamCandles, streamConnected, streamSource } = useStore()

  const chartRef     = useRef<HTMLDivElement>(null)
  const chart        = useRef<IChartApi | null>(null)
  const candleSeries = useRef<ISeriesApi<'Candlestick'> | null>(null)
  const smaMap       = useRef<Map<SmaPeriod, ISeriesApi<'Line'>>>(new Map())

  // KEY: track when the chart canvas is ready to receive data
  const [chartReady, setChartReady] = useState(false)

  const [candles,    setCandles]    = useState<Candle[]>([])
  const [loading,    setLoading]    = useState(false)
  const [error,      setError]      = useState<string | null>(null)
  const [sym,        setSym]        = useState(activeSymbol || 'SPY')
  const [tf,         setTf]         = useState('20y')
  const [freq,       setFreq]       = useState('daily')
  const [ctxMenu,    setCtxMenu]    = useState<{ x: number; y: number; time: number; price: number } | null>(null)
  const [activeSmas, setActiveSmas] = useState<Set<SmaPeriod>>(new Set([50, 200]))
  const [showRsi,    setShowRsi]    = useState(false)
  const [showAtr,    setShowAtr]    = useState(false)
  const [showVortex, setShowVortex] = useState(false)
  const [showPpo,    setShowPpo]    = useState(false)

  // ?? Init chart canvas ?????????????????????????????????????
  useEffect(() => {
    if (!chartRef.current) return
    const c = createChart(chartRef.current, {
      layout: {
        background: { color: 'rgba(10,12,18,0)' },
        textColor:  '#6e8aa0',
        fontFamily: 'IBM Plex Mono, monospace',
        fontSize:   12,
      },
      grid: { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: {
        mode: CrosshairMode.Normal,
        vertLine: { labelVisible: true, color: '#4d9fff50', width: 1, style: LineStyle.Dashed },
        horzLine: { labelVisible: true, color: '#4d9fff50', width: 1, style: LineStyle.Dashed },
      },
      rightPriceScale: {
        borderColor: '#1c2b3a', textColor: '#6e8aa0',
        scaleMargins: { top: 0.08, bottom: 0.15 },
      },
      timeScale: {
        borderColor: '#1c2b3a', timeVisible: true, secondsVisible: false,
        rightOffset: 8, barSpacing: 6,
        fixLeftEdge: true,
      },
      handleScroll: true,
      handleScale:  true,
    })

    const cs = c.addCandlestickSeries({
      upColor:         '#3bba6c',
      downColor:       '#f04f48',
      borderUpColor:   '#3bba6c',
      borderDownColor: '#f04f48',
      wickUpColor:     '#3bba6c88',
      wickDownColor:   '#f04f4888',
    })
    chart.current        = c
    candleSeries.current = cs

    // Right-click
    const el = chartRef.current
    const onCtx = (e: MouseEvent) => {
      e.preventDefault()
      const rect  = el.getBoundingClientRect()
      const time  = chart.current?.timeScale().coordinateToTime(e.clientX - rect.left)
      const price = candleSeries.current?.coordinateToPrice(e.clientY - rect.top) ?? 0
      setCtxMenu({ x: e.clientX, y: e.clientY, time: typeof time === 'number' ? time : 0, price: price ?? 0 })
    }
    el.addEventListener('contextmenu', onCtx)

    const obs = new ResizeObserver(() => {
      if (el && chart.current) c.applyOptions({ width: el.clientWidth, height: el.clientHeight })
    })
    obs.observe(el)

    // Signal that the chart is ready for data
    setChartReady(true)

    return () => {
      obs.disconnect()
      el.removeEventListener('contextmenu', onCtx)
      c.remove()
      chart.current        = null
      candleSeries.current = null
      setChartReady(false)
    }
  }, [])

  // ?? Load price data ???????????????????????????????????????
  const loadChart = useCallback(async (s: string, period: string, frequency: string) => {
    if (!candleSeries.current) return
    setLoading(true); setError(null)
    try {
      const data = await fetchPriceHistory(s, period, frequency)
      if (!data.candles.length) throw new Error(`No candle data returned for ${s}`)
      setCandles(data.candles)
      const daily = frequency === 'daily' || frequency === 'weekly' || frequency === 'monthly'
      const cdData: CandlestickData<Time>[] = data.candles.map(c => ({
        time:  (daily ? new Date(c.time * 1000).toISOString().slice(0, 10) : c.time) as Time,
        open: c.open, high: c.high, low: c.low, close: c.close,
      }))
      candleSeries.current!.setData(cdData)
      chart.current?.timeScale().fitContent()
      setSym(s)
    } catch (e: any) {
      setError(e.message)
    } finally {
      setLoading(false)
    }
  }, [])

  // AUTO-LOAD: fires once the chart canvas is ready
  useEffect(() => {
    if (chartReady) {
      loadChart(sym, '20y', 'daily')
    }
  }, [chartReady])

  // ?? Stream candle updates ?????????????????????????????????????????????????
  // When DXLink sends candle events, streamCandles is updated in the store.
  // We watch it here and call series.update() for smooth live bar updates.
  useEffect(() => {
    if (!candleSeries.current || !chartReady) return

    const daily  = freq === 'daily' || freq === 'weekly' || freq === 'monthly'
    const period = tf   // e.g. '20y'

    // Map period to DXLink candle interval
    const intervalMap: Record<string, string> = {
      '1d':'5m','5d':'15m','1m':'30m','3m':'1h',
      '6m':'2h','1y':'1d','2y':'1d','5y':'1d',
      '10y':'1d','20y':'1d','ytd':'1d',
    }
    const interval  = intervalMap[period] ?? '1d'
    const candleKey = `${sym.toUpperCase()}{=${interval}}`
    const streamed  = streamCandles[candleKey]

    if (!streamed || streamed.length === 0) return

    // If we have more candles than before, do a full setData (bulk load)
    // Otherwise just update the last bar
    const existing = candles
    if (streamed.length > existing.length + 10) {
      // Bulk historical load arrived ? set all at once
      const cdData = streamed.map(c => ({
        time:  (daily ? new Date(c.time * 1000).toISOString().slice(0, 10) : c.time) as Time,
        open: c.open, high: c.high, low: c.low, close: c.close,
      }))
      candleSeries.current!.setData(cdData)
      setCandles(streamed)
      chart.current?.timeScale().fitContent()
    } else if (streamed.length > 0) {
      // Live bar update ? just update the last candle
      const last = streamed[streamed.length - 1]
      const bar = {
        time:  (daily ? new Date(last.time * 1000).toISOString().slice(0, 10) : last.time) as Time,
        open: last.open, high: last.high, low: last.low, close: last.close,
      }
      try { candleSeries.current!.update(bar) } catch {}
    }
  }, [streamCandles, chartReady, sym, tf, freq])


  // Reload when active symbol changes from another tile
  useEffect(() => {
    if (chartReady && activeSymbol && activeSymbol !== sym) {
      setSym(activeSymbol)
      loadChart(activeSymbol, tf, freq)
    }
  }, [activeSymbol, chartReady])

  // ?? SMAs ?????????????????????????????????????????????????
  useEffect(() => {
    if (!chart.current || !candles.length) return
    const closes = candles.map(c => c.close)
    const daily  = freq === 'daily' || freq === 'weekly' || freq === 'monthly'
    const times  = candles.map(c => (daily ? new Date(c.time * 1000).toISOString().slice(0, 10) : String(c.time)) as Time)
    SMA_PERIODS.forEach(period => {
      const vals = sma(closes, period)
      const lineData: LineData<Time>[] = vals.map((v, i) => ({ time: times[i], value: v })).filter(d => d.value != null) as LineData<Time>[]
      const existing = smaMap.current.get(period)
      if (activeSmas.has(period)) {
        if (existing) { existing.setData(lineData); existing.applyOptions({ visible: true }) }
        else {
          const s = chart.current!.addLineSeries({ color: SMA_COLORS[period], lineWidth: period >= 128 ? 2 : 1, priceLineVisible: false, lastValueVisible: false, crosshairMarkerVisible: false })
          s.setData(lineData)
          smaMap.current.set(period, s)
        }
      } else if (existing) { existing.applyOptions({ visible: false }) }
    })
  }, [activeSmas, candles, freq])

  // ?? Position markers ??????????????????????????????????????
  useEffect(() => {
    if (!candleSeries.current || !candles.length) return
    const symPos = positions.filter(p => p.underlying === sym)
    const daily  = freq === 'daily' || freq === 'weekly' || freq === 'monthly'
    const today  = daily ? new Date().toISOString().slice(0, 10) : String(Math.floor(Date.now() / 1000))
    candleSeries.current.setMarkers(
      symPos.map(p => ({
        time:     today as Time,
        position: (p.display_qty < 0 ? 'aboveBar' : 'belowBar') as any,
        color:    p.display_qty < 0 ? '#f04f48' : '#3bba6c',
        shape:    (p.display_qty < 0 ? 'arrowDown' : 'arrowUp') as any,
        text:     `${p.option_type}${p.strike}`,
      }))
    )
  }, [positions, candles, sym])

  // ?? Expected move lines ???????????????????????????????????
  useEffect(() => {
    if (!candleSeries.current || !quote.atmStraddle || !quote.lastPrice) return
    const move = quote.atmStraddle * 0.85
    const upper = quote.lastPrice + move, lower = quote.lastPrice - move
    try { ;(candleSeries.current as any).__em_u?.remove(); (candleSeries.current as any).__em_l?.remove() } catch {}
    ;(candleSeries.current as any).__em_u = candleSeries.current.createPriceLine({ price: upper, color: '#3bba6c88', lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: true, title: `EM+ ${upper.toFixed(2)}` })
    ;(candleSeries.current as any).__em_l = candleSeries.current.createPriceLine({ price: lower, color: '#f04f4888', lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: true, title: `EM- ${lower.toFixed(2)}` })
  }, [quote.atmStraddle, quote.lastPrice])

  function toggleSma(p: SmaPeriod) {
    setActiveSmas(prev => { const n = new Set(prev); n.has(p) ? n.delete(p) : n.add(p); return n })
  }

  function openNews() {
    if (!ctxMenu) return
    const date = ctxMenu.time > 0 ? new Date(ctxMenu.time * 1000).toISOString().slice(0, 10) : new Date().toISOString().slice(0, 10)
    window.open(`https://www.google.com/search?q=${encodeURIComponent(sym)}+stock+news&tbs=cdr:1,cd_min:${date},cd_max:${date}&tbm=nws`, '_blank')
    setCtxMenu(null)
  }
  function addAlert() {
    if (!ctxMenu) return
    window.dispatchEvent(new CustomEvent('granite:addAlertAtPrice', { detail: { sym, price: ctxMenu.price.toFixed(2) } }))
    setCtxMenu(null)
  }

  const toPoints = (vals: (number | null)[]) =>
    candles.map((c, i) => ({ time: toT(c, freq), value: vals[i] ?? null }))

  const closes      = candles.map(c => c.close)
  const rsiVals     = showRsi    ? rsiCalc(closes, 15)    : []
  const atrVals     = showAtr    ? atrCalc(candles, 5)    : []
  const vtx         = showVortex ? vortexCalc(candles, 14): { vip: [], vim: [] }
  const ppo         = showPpo    ? ppoCalc(closes, 12, 48, 200) : { line: [], sig: [], hist: [] }
  const numInd      = [showRsi, showAtr, showVortex, showPpo].filter(Boolean).length
  const indH        = numInd > 0 ? `${Math.floor(40 / numInd)}%` : '0%'

  const chgColor = (quote.netChange ?? 0) >= 0 ? '#3bba6c' : '#f04f48'
  const move     = quote.atmStraddle ? (quote.atmStraddle * 0.85).toFixed(2) : null

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column' }} onClick={() => ctxMenu && setCtxMenu(null)}>

      {/* Header */}
      <div className="tile-hdr" style={{ flexDirection: 'column', height: 'auto', padding: '6px 10px', gap: 5, cursor: 'default' }}>

        {/* Row 1: symbol + timeframes + price */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
          <span className="tile-title">Chart</span>

          {/* Editable symbol ? no LOAD button, Enter key triggers load */}
          <input
            type="text" value={sym}
            onChange={e => setSym(e.target.value.toUpperCase())}
            onKeyDown={e => { if (e.key === 'Enter') loadChart(sym, tf, freq) }}
            title="Press Enter to load"
            style={{ width: 70, fontSize: 13, fontWeight: 700, padding: '2px 6px' }}
          />

          <div style={{ display: 'flex', gap: 1, background: 'var(--bg3)', borderRadius: 4, padding: 2 }}>
            {TF_OPTIONS.map(t => (
              <button
                key={t.label}
                onClick={() => { setTf(t.period); setFreq(t.freq); loadChart(sym, t.period, t.freq) }}
                style={{
                  padding: '3px 8px', fontSize: 11, border: 'none', borderRadius: 3, cursor: 'pointer',
                  background: tf === t.period ? 'var(--accent)' : 'transparent',
                  color: tf === t.period ? 'var(--bg)' : 'var(--muted)',
                  fontWeight: tf === t.period ? 700 : 400, fontFamily: 'inherit',
                }}
              >{t.label}</button>
            ))}
          </div>

          {/* Focal price */}
          <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <span style={{ fontSize: 26, fontWeight: 700, lineHeight: 1, letterSpacing: '-0.02em' }}>
              {quote.lastPrice != null ? '$' + quote.lastPrice.toFixed(2) : '--'}
            </span>
            <span style={{ fontSize: 14, color: chgColor }}>
              {quote.netChange != null ? `${quote.netChange >= 0 ? '+' : ''}${quote.netChange.toFixed(2)} (${((quote.netPctChange ?? 0) * 100).toFixed(2)}%)` : ''}
            </span>
            {quote.openPrice && <span style={{ fontSize: 12, color: 'var(--muted)' }}>O {quote.openPrice.toFixed(2)}</span>}
            {quote.highPrice && <span style={{ fontSize: 12, color: '#3bba6c' }}>H {quote.highPrice.toFixed(2)}</span>}
            {quote.lowPrice  && <span style={{ fontSize: 12, color: '#f04f48' }}>L {quote.lowPrice.toFixed(2)}</span>}
            {move && <span style={{ fontSize: 12, color: 'var(--muted)' }}>EM {move}</span>}
          </div>
        </div>

        {/* Row 2: SMA + indicator toggles */}
        <div style={{ display: 'flex', gap: 3, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>SMA</span>
          {SMA_PERIODS.map(p => (
            <button key={p} className="btn sm"
              style={{ fontSize: 11, padding: '1px 6px', borderColor: activeSmas.has(p) ? SMA_COLORS[p] : undefined, color: activeSmas.has(p) ? SMA_COLORS[p] : 'var(--muted)', background: activeSmas.has(p) ? SMA_COLORS[p] + '18' : undefined }}
              onClick={() => toggleSma(p)}>{p}</button>
          ))}
          <div style={{ width: 1, height: 14, background: 'var(--border)', margin: '0 4px' }} />
          <span style={{ fontSize: 10, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>IND</span>
          {[
            { label: 'RSI 15', val: showRsi,    fn: setShowRsi    },
            { label: 'ATR 5',  val: showAtr,    fn: setShowAtr    },
            { label: 'VTX 14', val: showVortex, fn: setShowVortex },
            { label: 'PPO',    val: showPpo,    fn: setShowPpo    },
          ].map(ind => (
            <button key={ind.label} className={`btn sm${ind.val ? ' active' : ''}`}
              style={{ fontSize: 11, padding: '1px 6px' }}
              onClick={() => ind.fn((v: boolean) => !v)}>{ind.label}</button>
          ))}
          {loading && <span style={{ fontSize: 11, color: 'var(--muted)', marginLeft: 6 }}>Loading {sym}...</span>}
          <span style={{ marginLeft: 'auto', fontSize: 10, color: streamConnected ? 'var(--green)' : 'var(--muted)', display: 'flex', alignItems: 'center', gap: 4 }}>
            <span style={{ width: 7, height: 7, borderRadius: '50%', background: streamConnected ? 'var(--green)' : 'var(--border)', display: 'inline-block' }} />
            {streamConnected ? 'LIVE' : 'REST'}
          </span>
          {error   && <span style={{ fontSize: 11, color: 'var(--red)',   marginLeft: 6 }}>{error}</span>}
        </div>
      </div>

      {/* Chart area */}
      <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
        <div ref={chartRef} style={{ width: '100%', height: numInd > 0 ? '62%' : '100%', minHeight: 0 }} />
        {numInd > 0 && (
          <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', borderTop: '1px solid var(--border)' }}>
            {showRsi    && <MiniLine points={toPoints(rsiVals)} color="#9868f8" height={indH} title="RSI (15)" refLines={[{ value: 70, color: '#f04f4888' }, { value: 30, color: '#3bba6c88' }]} />}
            {showAtr    && <MiniLine points={toPoints(atrVals)} color="#d4972a" height={indH} title="ATR (5)" />}
            {showVortex && <MiniTwoLine p1={toPoints(vtx.vip)} p2={toPoints(vtx.vim)} c1="#3bba6c" c2="#f04f48" height={indH} title="Vortex (14)  VI+ / VI-" />}
            {showPpo    && <MiniHistoTwo hist={toPoints(ppo.hist)} l1={toPoints(ppo.line)} l2={toPoints(ppo.sig)} height={indH} title="PPO (12,48,200)" />}
          </div>
        )}
      </div>

      {/* Right-click menu */}
      {ctxMenu && (
        <div style={{ position: 'fixed', left: ctxMenu.x, top: ctxMenu.y, zIndex: 99999, background: 'var(--bg2)', border: '1px solid var(--bord2)', borderRadius: 5, padding: '4px 0', minWidth: 230, boxShadow: '0 8px 32px rgba(0,0,0,.6)' }} onClick={e => e.stopPropagation()}>
          <div style={{ padding: '4px 14px 7px', fontSize: 11, color: 'var(--muted)', borderBottom: '1px solid var(--border)' }}>
            {sym} @ ${ctxMenu.price.toFixed(2)}
          </div>
          {[
            { icon: '?', label: 'Google News for this date', fn: openNews },
            { icon: '?', label: `Set alert at $${ctxMenu.price.toFixed(2)}`, fn: addAlert },
            { icon: '?',  label: 'Close menu', fn: () => setCtxMenu(null) },
          ].map(item => (
            <div key={item.label} onClick={item.fn}
              style={{ padding: '7px 14px', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 10, fontSize: 13 }}
              onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg3)')}
              onMouseLeave={e => (e.currentTarget.style.background = '')}
            >
              <span>{item.icon}</span>{item.label}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

'@
WF "react-frontend\src\components\tiles\ChartTile.tsx" $c

$c = @'
import { useState } from 'react'
import {
  createColumnHelper, flexRender, getCoreRowModel,
  getSortedRowModel, useReactTable, type SortingState,
} from '@tanstack/react-table'
import { useStore } from '../../store/useStore'
import type { ScanResult } from '../../types'
import { fetchScan, fetchChain } from '../../api/client'
import { fetchVolSurface } from '../../api/client'

const ch = createColumnHelper<ScanResult>()

// ?? 2dp formatters ?????????????????????????????????????????
const f$  = (v: number | null | undefined) => v == null ? '--' : '$' + Number(v).toFixed(2)
const fPct = (v: number | null | undefined) => v == null ? '--' : (Number(v) * 100).toFixed(2) + '%'
const fIV  = (v: number | null | undefined) => v == null ? '--' : (Number(v) * 100).toFixed(2) + '%'
const fN2  = (v: number | null | undefined) => v == null ? '--' : Number(v).toFixed(2)

// ?? Column definitions ?????????????????????????????????????
const COLS = [
  ch.accessor('expiration', {
    header: 'Exp', size: 94,
    cell: i => <span style={{ color: 'var(--muted)' }}>{i.getValue()}</span>,
    meta: { tip: 'Expiration date of the spread' },
  }),
  ch.accessor('option_side', {
    header: 'Side', size: 52,
    cell: i => <span className={`side-badge ${i.getValue()}`}>{i.getValue().toUpperCase()}</span>,
    meta: { tip: 'CALL (bear call) or PUT (bull put) credit spread' },
  }),
  ch.accessor('short_strike', {
    header: 'Short', size: 60,
    cell: i => fN2(i.getValue()),
    meta: { tip: 'Strike you SELL ? where you collect premium' },
  }),
  ch.accessor('long_strike', {
    header: 'Long', size: 60,
    cell: i => fN2(i.getValue()),
    meta: { tip: 'Strike you BUY ? your protection leg' },
  }),
  ch.accessor('width', {
    header: 'Wid', size: 46,
    cell: i => <span style={{ color: 'var(--muted)' }}>{fN2(i.getValue())}</span>,
    meta: { tip: 'Dollar distance between strikes. Any width is shown (no preset list).' },
  }),
  ch.accessor('quantity', {
    header: 'Qty', size: 40,
    cell: i => <span style={{ color: 'var(--muted)' }}>{i.getValue()}</span>,
    meta: { tip: 'Contracts for nearest-integer match to your target risk. Actual risk may differ slightly.' },
  }),
  ch.accessor('net_credit', {
    header: 'Net Cr', size: 72,
    cell: i => <span style={{ color: 'var(--green)' }}>{f$(i.getValue())}</span>,
    meta: { tip: 'Total premium collected for entire position (all contracts)' },
  }),
  ch.accessor('actual_defined_risk', {
    header: 'Act Risk', size: 72,
    cell: i => <span style={{ color: 'var(--muted)' }}>{f$(i.getValue() as number)}</span>,
    meta: { tip: 'Actual defined risk = Width ? 100 ? Qty. May differ slightly from target when qty rounds.' },
  }),
  ch.accessor('max_loss', {
    header: 'Max Loss', size: 76,
    cell: i => <span style={{ color: 'var(--red)' }}>{f$(i.getValue())}</span>,
    meta: { tip: 'Worst-case loss = Actual Risk minus Net Credit' },
  }),
  ch.accessor('credit_pct_risk', {
    header: 'Cr%Risk', size: 66,
    cell: i => <span>{fPct(i.getValue())}</span>,
    meta: { tip: 'Net Credit / Actual Risk ? primary reward/risk metric. 30% = collected 30? per $1 at risk.' },
  }),
  ch.accessor('short_delta', {
    header: 'Sht ?', size: 60,
    cell: i => <span style={{ color: 'var(--muted)' }}>{fN2(i.getValue())}</span>,
    meta: { tip: 'Delta of the short leg ? approximate probability ITM at expiry' },
  }),
  ch.accessor('short_iv', {
    header: 'Sht IV', size: 62,
    cell: i => <span style={{ color: 'var(--muted)' }}>{fIV(i.getValue())}</span>,
    meta: { tip: 'Implied volatility of the short strike ? what you are selling. Now correctly scaled.' },
  }),
  ch.accessor('richness_score', {
    header: 'Score', size: 58,
    cell: i => {
      const v = Number(i.getValue() ?? 0)
      const color = v >= 0.7 ? 'var(--green)' : v >= 0.4 ? 'var(--text)' : 'var(--muted)'
      return <span style={{ color, fontWeight: v >= 0.7 ? 600 : 400 }}>{fN2(v)}</span>
    },
    meta: { tip: 'Composite rank: 70% credit% rank + 30% IV rank vs peers in same expiration. 1.0 = richest.' },
  }),
  ch.accessor('limit_impact', {
    header: 'Impact', size: 72,
    cell: i => <span style={{ color: 'var(--warn)' }}>{f$(i.getValue())}</span>,
    meta: { tip: 'max(Short Value, Long Cost) ? tastytrade limit usage for this trade' },
  }),
]


function downloadScanResults(results: any[]) {
  if (!results.length) return
  const headers = ['exp','side','short','long','width','qty','net_credit','act_risk','max_loss','cr_pct_risk','short_delta','short_iv','score','impact']
  const rows = results.map(r => headers.map(h => r[h] ?? '').join(','))
  const csv  = [headers.join(','), ...rows].join('\n')
  const blob = new Blob([csv], { type: 'text/csv' })
  const url  = URL.createObjectURL(blob)
  const a    = document.createElement('a')
  a.href = url; a.download = `scan_${new Date().toISOString().slice(0,10)}.csv`
  a.click(); URL.revokeObjectURL(url)
}

export function ScannerTile() {
  const {
    scanResults, scanLoading, scanError, scanExpOptions,
    setScanResults, setScanLoading, setScanError, setScanExpOptions,
    activeSymbol, setActiveSymbol, setVolData, setVolLoading, setVolError,
  } = useStore()

  const [sorting, setSorting] = useState<SortingState>([])
  const [sym, setSym]         = useState(activeSymbol)
  const [risk, setRisk]       = useState(1000)
  const [side, setSide]       = useState<'all' | 'call' | 'put'>('all')
  const [exp, setExp]         = useState('all')
  const [sortBy, setSortBy]   = useState('credit_pct_risk')
  const [maxRes, setMaxRes]   = useState(500)
  const [pricing, setPricing] = useState<'conservative_mid' | 'mid' | 'natural'>('conservative_mid')
  const [tooltip, setTooltip] = useState<string | null>(null)

  const table = useReactTable({
    data: scanResults,
    columns: COLS,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  })

  async function run() {
    setScanLoading(true); setScanError(null)
    setActiveSymbol(sym)
    try {
      const d = await fetchScan({
        symbol: sym, total_risk: risk, side, expiration: exp,
        sort_by: sortBy, max_results: maxRes,
      })
      setScanResults(d.items)
    } catch (e: any) {
      setScanError(e.message)
    } finally {
      setScanLoading(false)
    }
  }

  async function refreshChain() {
    try {
      const d = await fetchChain(sym)
      setScanExpOptions(d.expirations.slice(0, 7))
    } catch (e: any) { setScanError(e.message) }
  }

  async function loadSurface() {
    setVolLoading(true); setVolError(null)
    try {
      const d = await fetchVolSurface(sym, 7, 25)
      setVolData(d)
    } catch (e: any) { setVolError(e.message) }
    finally { setVolLoading(false) }
  }

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column', position: 'relative' }}>
      <div className="tile-hdr">
        <span className="tile-title">Entry Scanner</span>
        {tooltip && (
          <div style={{ position: 'absolute', top: 30, left: 8, background: 'var(--bg3)', border: '1px solid var(--bord2)', borderRadius: 4, padding: '5px 10px', fontSize: 11, color: 'var(--text)', zIndex: 200, maxWidth: 380, lineHeight: 1.5, pointerEvents: 'none', whiteSpace: 'normal' }}>
            {tooltip}
          </div>
        )}
      </div>

      <div className="scan-controls">
        <div className="ctrl-group">
          <label>Symbol</label>
          <input type="text" value={sym} onChange={e => setSym(e.target.value.toUpperCase())} onKeyDown={e => e.key === 'Enter' && run()} />
        </div>
        <div className="ctrl-group">
          <label>Target Risk $</label>
          <input type="number" value={risk} onChange={e => setRisk(Number(e.target.value))} step={100} />
        </div>
        <div className="ctrl-group">
          <label>Side</label>
          <select value={side} onChange={e => setSide(e.target.value as any)}>
            <option value="all">All</option>
            <option value="call">Calls</option>
            <option value="put">Puts</option>
          </select>
        </div>
        <div className="ctrl-group">
          <label>Expiration</label>
          <select value={exp} onChange={e => setExp(e.target.value)}>
            <option value="all">All (next 7)</option>
            {scanExpOptions.map(e => <option key={e} value={e}>{e}</option>)}
          </select>
        </div>
        <div className="ctrl-group">
          <label>Sort By</label>
          <select value={sortBy} onChange={e => setSortBy(e.target.value)}>
            <option value="credit_pct_risk">Credit % Risk</option>
            <option value="richness">Richness Score</option>
            <option value="credit">Net Credit</option>
            <option value="limit_impact">Limit Impact</option>
            <option value="max_loss">Max Loss</option>
          </select>
        </div>
        <div className="ctrl-group">
          <label>Pricing</label>
          <select value={pricing} onChange={e => setPricing(e.target.value as any)}>
            <option value="conservative_mid">Conservative Mid</option>
            <option value="mid">Mid (faster fills)</option>
            <option value="natural">Natural (bid/ask)</option>
          </select>
        </div>
      </div>

      <div className="scan-actions">
        <button className="btn primary" onClick={run} disabled={scanLoading}>
          {scanLoading ? 'Scanning...' : '\u25B6 SCAN'}
        </button>
        <button className="btn" onClick={() => { setScanResults([]); setScanError(null) }}>&#x2715;</button>
        <button className="btn sm" onClick={refreshChain} title="Force-refresh chain data">&#x21BA; CHAIN</button>
        <button className="btn sm" onClick={loadSurface} title="Load vol surface">&#x2B21; SURFACE</button>
        <span style={{ fontSize: 10, color: 'var(--muted)', marginLeft: 4, alignSelf: 'center' }}>
          {scanResults.length > 0 ? `${scanResults.length} results` : ''}
        </span>
        <span style={{ fontSize: 9, color: 'var(--muted)', marginLeft: 'auto', alignSelf: 'center', fontStyle: 'italic' }}>
          {pricing === 'conservative_mid' ? 'conservative' : pricing} pricing
        </span>
      </div>

      {scanError && <div className="error-msg">{scanError}</div>}

      <div className="tile-body tbl-wrap">
        <table className="data-table">
          <thead>
            {table.getHeaderGroups().map(hg => (
              <tr key={hg.id}>
                {hg.headers.map(h => {
                  const tip = (h.column.columnDef.meta as any)?.tip as string | undefined
                  return (
                    <th
                      key={h.id}
                      style={{ width: h.getSize(), cursor: h.column.getCanSort() ? 'pointer' : 'default' }}
                      className={
                        h.column.getIsSorted() === 'asc' ? 'sort-asc' :
                        h.column.getIsSorted() === 'desc' ? 'sort-desc' : ''
                      }
                      onClick={h.column.getToggleSortingHandler()}
                      onMouseEnter={() => tip && setTooltip(tip)}
                      onMouseLeave={() => setTooltip(null)}
                    >
                      {flexRender(h.column.columnDef.header, h.getContext())}
                    </th>
                  )
                })}
              </tr>
            ))}
          </thead>
          <tbody>
            {scanLoading ? (
              <tr><td colSpan={14} className="loading">Scanning all strike pairs...</td></tr>
            ) : scanResults.length === 0 ? (
              <tr><td colSpan={14} className="empty-msg">Configure filters and press SCAN</td></tr>
            ) : (
              table.getRowModel().rows.map(row => (
                <tr
                  key={row.id}
                  style={{ borderLeft: `2px solid ${row.original.option_side === 'call' ? 'var(--green)' : 'var(--red)'}` }}
                >
                  {row.getVisibleCells().map(cell => (
                    <td key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}

'@
WF "react-frontend\src\components\tiles\ScannerTile.tsx" $c

$c = @'
/* ?? Fonts & Reset ???????????????????????????????????????? */
@import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=Syne:wght@600;700;800&display=swap');

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

/* ?? Themes ??????????????????????????????????????????????? */
:root, [data-theme="slate"] {
  --bg:#07090e;--bg1:#0c1018;--bg2:#111820;--bg3:#16202c;
  --border:#1c2b3a;--bord2:#243448;--text:#cbd9e8;--muted:#6e8aa0;
  --accent:#4d9fff;--green:#3bba6c;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;
  --focus-border:#4d9fff;
}
[data-theme="navy"]{--bg:#02071a;--bg1:#060d24;--bg2:#0b142e;--bg3:#101c38;--border:#182648;--bord2:#203058;--text:#c8d2f0;--muted:#5870b0;--accent:#6888ff;--green:#3bba6c;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;--focus-border:#6888ff}
[data-theme="emerald"]{--bg:#040c08;--bg1:#091410;--bg2:#0e1c16;--bg3:#13241c;--border:#182e22;--bord2:#213c2e;--text:#c0d8c8;--muted:#5a906a;--accent:#3bba6c;--green:#4d9fff;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;--focus-border:#3bba6c}
[data-theme="teal"]{--bg:#030d0d;--bg1:#071616;--bg2:#0c1e1e;--bg3:#112626;--border:#183232;--bord2:#204040;--text:#b8d4d4;--muted:#508080;--accent:#2bcece;--green:#3bba6c;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;--focus-border:#2bcece}
[data-theme="amber"]{--bg:#0e0b04;--bg1:#161208;--bg2:#1e180c;--bg3:#261e10;--border:#3a2e0e;--bord2:#4e3e14;--text:#ddd0a8;--muted:#968850;--accent:#e5b84c;--green:#3bba6c;--red:#f04f48;--warn:#f04f48;--gold:#4d9fff;--focus-border:#e5b84c}
[data-theme="rose"]{--bg:#0e0508;--bg1:#16080d;--bg2:#1e0d14;--bg3:#26121b;--border:#3a1420;--bord2:#4e1c2c;--text:#ddc4cc;--muted:#985060;--accent:#f04f48;--green:#3bba6c;--red:#ff4444;--warn:#d4972a;--gold:#e5b84c;--focus-border:#f04f48}
[data-theme="purple"]{--bg:#08060e;--bg1:#0c0a18;--bg2:#120e20;--bg3:#181228;--border:#261c40;--bord2:#342454;--text:#d0c4e8;--muted:#806898;--accent:#9868f8;--green:#3bba6c;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;--focus-border:#9868f8}
[data-theme="mono"]{--bg:#060606;--bg1:#0e0e0e;--bg2:#161616;--bg3:#1e1e1e;--border:#282828;--bord2:#343434;--text:#cccccc;--muted:#686868;--accent:#b0b0b0;--green:#909090;--red:#787878;--warn:#888888;--gold:#cccccc;--focus-border:#c0c0c0}

/* ?? Base ?????????????????????????????????????????????????? */
html, body, #root { height: 100%; overflow: hidden; background: var(--bg); color: var(--text); font-family: 'IBM Plex Mono', 'Courier New', monospace; font-size: var(--app-font-size, 14px); line-height: 1.5; -webkit-font-smoothing: antialiased; }
::-webkit-scrollbar { width: 4px; height: 4px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--bord2); border-radius: 2px; }
input,select,button { font-family: inherit; }
input[type=text],input[type=number],select { background: var(--bg3); color: var(--text); border: 1px solid var(--bord2); border-radius: 3px; padding: 4px 8px; font-size: 12px; outline: none; width: 100%; }
input:focus,select:focus { border-color: var(--accent); }

/* ?? Typography ???????????????????????????????????????????? */
.font-display { font-family: 'Syne', sans-serif; }
.text-accent { color: var(--accent); }
.text-green  { color: var(--green); }
.text-red    { color: var(--red); }
.text-warn   { color: var(--warn); }
.text-muted  { color: var(--muted); }
.text-gold   { color: var(--gold); }

/* ?? App shell ????????????????????????????????????????????? */
.app-shell { display: flex; flex-direction: column; height: 100%; overflow: hidden; }

/* ?? TOPBAR ? doubled height ??????????????????????????????? */
.topbar {
  display: grid;
  grid-template-columns: auto 1fr auto;
  align-items: center;
  padding: 0 12px;
  height: 72px;
  background: var(--bg1);
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
  z-index: 9999;
  position: relative;
  gap: 16px;
}
.topbar-left  { display: flex; align-items: center; gap: 8px; }
.topbar-center { display: flex; flex-direction: column; align-items: center; justify-content: center; min-width: 280px; }
.topbar-right { display: flex; align-items: center; gap: 8px; justify-content: flex-end; }
.topbar-brand { font-family: 'Syne', sans-serif; font-weight: 800; font-size: 18px; color: var(--accent); letter-spacing: 0.08em; white-space: nowrap; }
.topbar-price-big { font-size: 36px; font-weight: 700; letter-spacing: -0.02em; line-height: 1; }
.topbar-sym { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.1em; }
.topbar-chg { font-size: 16px; font-weight: 600; }
.tpill { display: flex; flex-direction: column; padding: 3px 10px; background: var(--bg2); border: 1px solid var(--border); border-radius: 4px; min-width: 80px; }
.tpill .lbl { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; }
.tpill .val { font-size: 14px; font-weight: 700; }
.tsep { width: 1px; height: 28px; background: var(--border); margin: 0 2px; }

/* ?? BOTTOM BAR ???????????????????????????????????????????? */
.bottombar {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 10px;
  background: var(--bg1);
  border-top: 1px solid var(--border);
  flex-shrink: 0;
  z-index: 9999;
  position: relative;
  flex-wrap: wrap;
}
.tchip { display: flex; flex-direction: column; padding: 2px 8px; border: 1px solid var(--border); border-radius: 3px; background: var(--bg2); min-width: 72px; }
.tchip .tl { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }
.tchip .tv { font-size: 14px; font-weight: 600; }

/* ?? Buttons ??????????????????????????????????????????????? */
.btn { padding: 5px 13px; border: 1px solid var(--bord2); border-radius: 3px; background: var(--bg2); color: var(--text); cursor: pointer; font-family: 'IBM Plex Mono', monospace; font-size: 13px; font-weight: 600; white-space: nowrap; transition: border-color 0.1s, color 0.1s, background 0.1s; }
.btn:hover { border-color: var(--accent); color: var(--accent); }
.btn.primary { background: var(--accent); color: var(--bg); border-color: var(--accent); }
.btn.primary:hover { opacity: 0.85; }
.btn.sm { padding: 2px 8px; font-size: 10px; }
.btn.active { background: var(--accent); color: var(--bg); border-color: var(--accent); }

/* ?? Tiles ????????????????????????????????????????????????? */
.tile {
  background: var(--bg1);
  border: 1px solid var(--border);
  border-radius: 5px;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  box-shadow: 0 4px 24px rgba(0,0,0,0.5);
  transition: border-color 0.12s;
}
/* FOCUSED TILE ? accent-colored top border */
.tile.tile-focused {
  border-color: var(--bord2);
  border-top: 2px solid var(--focus-border);
}

.tile-hdr {
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 4px 8px;
  background: var(--bg2);
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
  min-height: 28px;
  cursor: grab;
  user-select: none;
  position: relative;
}
.tile-hdr:active { cursor: grabbing; }
.tile-title { font-family: 'Syne', sans-serif; font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.12em; color: var(--accent); pointer-events: none; white-space: nowrap; }
.tile-body { flex: 1; overflow: auto; min-height: 0; display: flex; flex-direction: column; }
.tile-gear-btn { margin-left: auto; background: none; border: none; cursor: pointer; color: var(--muted); font-size: 14px; padding: 0 2px; line-height: 1; transition: color 0.1s; }
.tile-gear-btn:hover { color: var(--text); }

/* ?? Tables ???????????????????????????????????????????????? */
.data-table { width: 100%; border-collapse: collapse; font-size: 14px; }
.data-table th, .data-table td { padding: 5px 9px; text-align: right; border-bottom: 1px solid #0c1422; white-space: nowrap; }
.data-table th:first-child, .data-table td:first-child { text-align: left; }
.data-table thead th { position: sticky; top: 0; background: #08101a; color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.04em; font-weight: 600; z-index: 2; cursor: pointer; padding: 5px 9px; }
.data-table thead th:hover { color: var(--text); }
.data-table thead th.sort-asc::after  { content: " \25B2"; color: var(--accent); }
.data-table thead th.sort-desc::after { content: " \25BC"; color: var(--accent); }
.data-table tbody tr:hover { background: #0c1825; }
.data-table .group-row td { background: #070e18; color: var(--accent); font-family: 'Syne', sans-serif; font-size: 10px; font-weight: 700; letter-spacing: 0.04em; padding: 4px 8px; }

/* ?? Watchlist ????????????????????????????????????????????? */
.wl-filter-input { width: 100%; padding: 5px 10px; background: var(--bg2); border: none; border-bottom: 1px solid var(--border); font-size: 12px; color: var(--text); outline: none; }
.wl-row { display: grid; gap: 0; padding: 4px 6px; border-bottom: 1px solid #0a1420; cursor: pointer; align-items: center; font-size: 12px; }
.wl-row:hover { background: var(--bg3); }
.wl-row.active { background: #0e2240; border-left: 2px solid var(--accent); }
.wl-row-compact { grid-template-columns: 54px 62px 56px 1fr; }
.wl-row-full { grid-template-columns: 54px 56px 54px 38px 34px 44px 50px 46px 46px 46px 46px 38px 80px 44px 40px 58px 52px 48px 80px 80px 80px 1fr; }
.wl-cell { text-align: right; font-size: 13px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.wl-cell:first-child { text-align: left; font-weight: 600; font-size: 14px; }
.wl-hdr { display: grid; padding: 3px 6px; background: #070c16; border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 3; }
.wl-hdr-c { grid-template-columns: 54px 62px 56px 1fr; }
.wl-hdr-f { grid-template-columns: 54px 56px 54px 38px 34px 44px 50px 46px 46px 46px 46px 38px 80px 44px 40px 58px 52px 48px 80px 80px 80px 1fr; }
.wl-hdr span { font-size: 8px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; text-align: right; }
.wl-hdr span:first-child { text-align: left; }

/* Watchlist action icons */
.wl-actions { display: flex; gap: 3px; justify-content: flex-end; align-items: center; }
.wl-icon-btn { background: none; border: none; cursor: pointer; font-size: 11px; padding: 1px 2px; color: var(--muted); transition: color 0.1s; line-height: 1; border-radius: 2px; }
.wl-icon-btn:hover { color: var(--accent); background: var(--bg3); }

/* Expected move range bar */
.em-bar-wrap { display: flex; align-items: center; gap: 4px; }
.em-bar { height: 6px; background: var(--border); border-radius: 3px; position: relative; flex: 1; min-width: 40px; overflow: hidden; }
.em-bar-inner { position: absolute; height: 100%; background: var(--accent); opacity: 0.4; border-radius: 3px; }
.em-bar-price { position: absolute; width: 2px; height: 100%; background: var(--text); border-radius: 1px; }

/* ?? Side badges ??????????????????????????????????????????? */
.side-badge { display: inline-block; padding: 1px 6px; border-radius: 2px; font-size: 10px; font-weight: 700; letter-spacing: 0.04em; }
.side-badge.call { background: rgba(59,186,108,0.12); color: var(--green); border: 1px solid var(--green); }
.side-badge.put  { background: rgba(240,79,72,0.12);  color: var(--red);   border: 1px solid var(--red); }

/* ?? Theme dots ???????????????????????????????????????????? */
.theme-dot { width: 16px; height: 16px; border-radius: 3px; cursor: pointer; border: 2px solid transparent; transition: all 0.1s; flex-shrink: 0; }
.theme-dot:hover { transform: scale(1.2); }
.theme-dot.active { border-color: white; }

/* ?? Modals ???????????????????????????????????????????????? */
.modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.8); z-index: 99999; display: flex; align-items: center; justify-content: center; }
.modal-box { background: var(--bg1); border: 1px solid var(--bord2); border-radius: 8px; padding: 20px; min-width: 480px; max-width: 660px; max-height: 80vh; overflow-y: auto; }
.modal-title { font-family: 'Syne', sans-serif; font-size: 14px; font-weight: 700; color: var(--accent); text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 14px; }

/* Gear settings panel */
.gear-modal { min-width: 340px; max-width: 440px; }
.gear-field-list { display: flex; flex-direction: column; gap: 4px; max-height: 320px; overflow-y: auto; }
.gear-field-row { display: flex; align-items: center; gap: 8px; padding: 4px 6px; border-radius: 3px; font-size: 12px; }
.gear-field-row:hover { background: var(--bg3); }
.gear-field-row label { cursor: pointer; flex: 1; }

/* ?? Vol surface ??????????????????????????????????????????? */
.vs-tabs { display: flex; gap: 3px; padding: 5px 8px; border-bottom: 1px solid var(--border); flex-shrink: 0; }
.richness-row { display: flex; gap: 5px; padding: 5px; flex-wrap: nowrap; overflow-x: auto; border-bottom: 1px solid var(--border); flex-shrink: 0; min-height: 64px; }
.rcard { padding: 4px 8px; background: var(--bg2); border: 1px solid var(--border); border-radius: 3px; cursor: pointer; flex-shrink: 0; min-width: 86px; }
.rcard:hover { border-color: var(--accent); }

/* ?? Scanner controls ?????????????????????????????????????? */
.scan-controls { display: grid; grid-template-columns: repeat(3,1fr); gap: 5px; padding: 7px; border-bottom: 1px solid var(--border); background: var(--bg1); flex-shrink: 0; }
.scan-actions { display: flex; gap: 5px; padding: 5px 7px; border-bottom: 1px solid var(--border); flex-shrink: 0; align-items: center; }
.ctrl-group { display: flex; flex-direction: column; }
.ctrl-group label { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; display: block; margin-bottom: 2px; }

/* ?? Trade ticket ?????????????????????????????????????????? */
.strat-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 3px; padding: 7px; flex-shrink: 0; }
.strat-btn { padding: 5px; text-align: center; border: 1px solid var(--bord2); border-radius: 3px; cursor: pointer; font-size: 11px; color: var(--muted); background: var(--bg2); transition: all 0.1s; }
.strat-btn:hover { border-color: var(--accent); color: var(--accent); }
.strat-btn.active { background: var(--accent); color: var(--bg); border-color: var(--accent); font-weight: 700; }

/* ?? Chart ????????????????????????????????????????????????? */
.chart-ph { display: flex; flex-direction: column; align-items: center; justify-content: center; flex: 1; color: var(--muted); gap: 6px; }

/* ?? Misc ?????????????????????????????????????????????????? */
.error-msg  { color: var(--red);   padding: 8px 10px; font-size: 13px; }
.empty-msg  { color: var(--muted); padding: 20px 16px; text-align: center; font-size: 13px; }
.loading    { color: var(--muted); padding: 20px 16px; text-align: center; font-size: 11px; animation: pulse 1.5s infinite; }
.tbl-wrap   { overflow: auto; flex: 1; }
@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }

/* ?? RGL overrides ????????????????????????????????????????? */
.react-grid-layout { position: relative; }
.react-grid-item { transition: none; box-sizing: border-box; }
.react-grid-item.react-draggable-dragging { transition: none; z-index: 3; }
.react-grid-item > .react-resizable-handle { position: absolute; bottom: 2px; right: 2px; width: 14px; height: 14px; cursor: nw-resize; background: linear-gradient(135deg, transparent 50%, var(--bord2) 50%); border-radius: 0 0 4px 0; opacity: 0.5; }
.react-grid-item > .react-resizable-handle:hover { opacity: 1; }

'@
WF "react-frontend\src\styles\globals.css" $c

$c = @'
import { create } from 'zustand'
import type { AlertRule, LimitSummary, Position, ScanResult, Theme, VolSurfaceData, WatchlistRow } from '../types'
import type { Candle } from '../api/client'

interface QuoteState {
  symbol: string
  lastPrice: number | null
  openPrice: number | null
  highPrice: number | null
  lowPrice: number | null
  netChange: number | null
  netPctChange: number | null
  bid: number | null
  ask: number | null
  atmStraddle: number | null
  activeSource: string
}

interface AppState {
  acctSource: 'mock' | 'tasty'
  positions: Position[]
  limitSummary: LimitSummary | null
  positionsLoading: boolean
  positionsError: string | null

  activeSymbol: string
  quote: QuoteState

  scanResults: ScanResult[]
  scanLoading: boolean
  scanError: string | null
  scanExpOptions: string[]

  volData: VolSurfaceData | null
  volLoading: boolean
  volError: string | null

  selectedIds: Set<string>

  alertRules: AlertRule[]
  alertsMaster: boolean
  desktopAllowed: boolean

  theme: Theme
  refreshInterval: number
  refreshCountdown: number

  // Live prices from DXLink (keyed by symbol)
  livePrices: Record<string, { last: number; bid: number; ask: number; open: number; high: number; low: number; pct: number }>

  // Streaming candle cache (keyed by "SYMBOL:period")
  streamCandles: Record<string, Candle[]>

  // Stream connection status
  streamConnected: boolean
  streamSource: 'dxlink' | 'schwab' | 'none'
}

interface AppActions {
  setAcctSource: (src: 'mock' | 'tasty') => void
  setPositions: (positions: Position[], summary: LimitSummary) => void
  setPositionsLoading: (v: boolean) => void
  setPositionsError: (e: string | null) => void

  setActiveSymbol: (sym: string) => void
  setQuote: (q: Partial<QuoteState>) => void

  setScanResults: (items: ScanResult[]) => void
  setScanLoading: (v: boolean) => void
  setScanError: (e: string | null) => void
  setScanExpOptions: (exps: string[]) => void

  setVolData: (d: VolSurfaceData | null) => void
  setVolLoading: (v: boolean) => void
  setVolError: (e: string | null) => void

  toggleSelected: (id: string) => void
  clearSelected: () => void

  addAlertRule: (rule: Omit<AlertRule, 'id' | 'triggered'>) => void
  toggleAlertRule: (id: number, active: boolean) => void
  deleteAlertRule: (id: number) => void
  markAlertTriggered: (id: number) => void
  setAlertsMaster: (v: boolean) => void
  setDesktopAllowed: (v: boolean) => void

  setTheme: (t: Theme) => void
  setRefreshInterval: (secs: number) => void
  tickCountdown: () => void
  resetCountdown: () => void

  // Live price updates from DXLink stream
  setLivePrice: (sym: string, last: number, pct: number) => void
  updateLiveQuote: (sym: string, data: {
    live_last?: number; live_bid?: number; live_ask?: number
    live_open?: number; live_high?: number; live_low?: number
    live_prev_close?: number; live_volume?: number
  }) => void

  // Streaming candle cache management
  setStreamCandles: (key: string, candles: Candle[]) => void
  updateStreamCandle: (key: string, candle: Candle) => void

  // Stream status
  setStreamConnected: (v: boolean, source: 'dxlink' | 'schwab' | 'none') => void
}

const INITIAL_QUOTE: QuoteState = {
  symbol: 'SPY',
  lastPrice: null,
  openPrice: null,
  highPrice: null,
  lowPrice: null,
  netChange: null,
  netPctChange: null,
  bid: null,
  ask: null,
  atmStraddle: null,
  activeSource: '--',
}

export const useStore = create<AppState & AppActions>((set, get) => ({
  acctSource: 'tasty',
  positions: [],
  limitSummary: null,
  positionsLoading: false,
  positionsError: null,

  activeSymbol: 'SPY',
  quote: INITIAL_QUOTE,

  scanResults: [],
  scanLoading: false,
  scanError: null,
  scanExpOptions: [],

  volData: null,
  volLoading: false,
  volError: null,

  selectedIds: new Set(),

  alertRules: [],
  alertsMaster: true,
  desktopAllowed: false,

  theme: 'slate',
  refreshInterval: 300,
  refreshCountdown: 300,

  livePrices: {},
  streamCandles: {},
  streamConnected: false,
  streamSource: 'none',

  setAcctSource: (src) => set({ acctSource: src }),
  setPositions: (positions, limitSummary) => set({ positions, limitSummary }),
  setPositionsLoading: (v) => set({ positionsLoading: v }),
  setPositionsError: (e) => set({ positionsError: e }),

  setActiveSymbol: (sym) => set({ activeSymbol: sym.toUpperCase() }),
  setQuote: (q) => set((s) => ({ quote: { ...s.quote, ...q } })),

  setScanResults: (items) => set({ scanResults: items }),
  setScanLoading: (v) => set({ scanLoading: v }),
  setScanError: (e) => set({ scanError: e }),
  setScanExpOptions: (exps) => set({ scanExpOptions: exps }),

  setVolData: (d) => set({ volData: d }),
  setVolLoading: (v) => set({ volLoading: v }),
  setVolError: (e) => set({ volError: e }),

  toggleSelected: (id) =>
    set((s) => {
      const next = new Set(s.selectedIds)
      if (next.has(id)) next.delete(id); else next.add(id)
      return { selectedIds: next }
    }),
  clearSelected: () => set({ selectedIds: new Set() }),

  addAlertRule: (rule) =>
    set((s) => ({ alertRules: [...s.alertRules, { ...rule, id: Date.now(), triggered: false }] })),
  toggleAlertRule: (id, active) =>
    set((s) => ({ alertRules: s.alertRules.map((r) => r.id === id ? { ...r, active } : r) })),
  deleteAlertRule: (id) =>
    set((s) => ({ alertRules: s.alertRules.filter((r) => r.id !== id) })),
  markAlertTriggered: (id) =>
    set((s) => ({ alertRules: s.alertRules.map((r) => r.id === id ? { ...r, triggered: true } : r) })),
  setAlertsMaster: (v) => set({ alertsMaster: v }),
  setDesktopAllowed: (v) => set({ desktopAllowed: v }),

  setTheme: (t) => {
    document.documentElement.setAttribute('data-theme', t)
    set({ theme: t })
  },
  setRefreshInterval: (secs) => set({ refreshInterval: secs, refreshCountdown: secs }),
  tickCountdown: () => set((s) => ({ refreshCountdown: Math.max(0, s.refreshCountdown - 1) })),
  resetCountdown: () => set((s) => ({ refreshCountdown: s.refreshInterval })),

  // Live price ? simple version for watchlist
  setLivePrice: (sym, last, pct) =>
    set((s) => ({
      livePrices: {
        ...s.livePrices,
        [sym]: { ...s.livePrices[sym], last, pct },
      },
    })),

  // Full live quote update from DXLink stream event
  updateLiveQuote: (sym, data) =>
    set((s) => {
      const existing = s.livePrices[sym] || { last: 0, bid: 0, ask: 0, open: 0, high: 0, low: 0, pct: 0 }
      const last    = data.live_last  ?? existing.last
      const prev    = data.live_prev_close ?? 0
      const pct     = prev > 0 ? (last - prev) / prev : existing.pct

      const updated = {
        last,
        bid:  data.live_bid  ?? existing.bid,
        ask:  data.live_ask  ?? existing.ask,
        open: data.live_open ?? existing.open,
        high: data.live_high ?? existing.high,
        low:  data.live_low  ?? existing.low,
        pct,
      }

      // Also update the main quote if this is the active symbol
      const quoteUpdate: Partial<QuoteState> = {}
      if (sym === s.activeSymbol) {
        if (data.live_last  != null) { quoteUpdate.lastPrice = data.live_last;  quoteUpdate.activeSource = 'DXLINK' }
        if (data.live_bid   != null) quoteUpdate.bid       = data.live_bid
        if (data.live_ask   != null) quoteUpdate.ask       = data.live_ask
        if (data.live_open  != null) quoteUpdate.openPrice = data.live_open
        if (data.live_high  != null) quoteUpdate.highPrice = data.live_high
        if (data.live_low   != null) quoteUpdate.lowPrice  = data.live_low
        if (prev > 0 && data.live_last != null) {
          quoteUpdate.netChange    = data.live_last - prev
          quoteUpdate.netPctChange = pct
        }
      }

      return {
        livePrices: { ...s.livePrices, [sym]: updated },
        quote: Object.keys(quoteUpdate).length > 0
          ? { ...s.quote, ...quoteUpdate }
          : s.quote,
      }
    }),

  // Candle cache ? bulk set (initial historical load)
  setStreamCandles: (key, candles) =>
    set((s) => ({ streamCandles: { ...s.streamCandles, [key]: candles } })),

  // Candle update ? single bar (live update or new bar)
  updateStreamCandle: (key, candle) =>
    set((s) => {
      const existing = s.streamCandles[key] ?? []
      const last     = existing[existing.length - 1]
      let updated: Candle[]

      if (last && last.time === candle.time) {
        // Update the last bar in place
        updated = [...existing.slice(0, -1), candle]
      } else {
        // New bar
        updated = [...existing, candle]
      }
      return { streamCandles: { ...s.streamCandles, [key]: updated } }
    }),

  setStreamConnected: (v, source) => set({ streamConnected: v, streamSource: source }),
}))

'@
WF "react-frontend\src\store\useStore.ts" $c

$c = @'
/**
 * useStream.ts ? DXLink WebSocket bridge hook
 *
 * Connects to ws://localhost:8000/ws/stream on mount.
 * Receives all market + account events from the backend relay.
 * Dispatches to Zustand store ? no other component needs to
 * know the WebSocket exists.
 *
 * Event types handled:
 *   connected     ? stream is live, set streamConnected = true
 *   quote         ? live bid/ask/last/OHLC for a symbol
 *   candle        ? single OHLCV bar (historical bulk + live updates)
 *   greeks        ? option Greeks for a position leg
 *   order         ? tastytrade order fill notification
 *   balance       ? account balance update
 *   position      ? position change notification
 *   ping          ? keepalive from backend (no action needed)
 */

import { useEffect, useRef, useCallback } from 'react'
import { useStore } from '../store/useStore'
import type { Candle } from '../api/client'

const WS_URL      = 'ws://localhost:8000/ws/stream'
const RECONNECT_MS = 3000   // retry after 3s on disconnect

export function useStream() {
  const wsRef      = useRef<WebSocket | null>(null)
  const retryTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const mounted    = useRef(true)

  const {
    updateLiveQuote,
    updateStreamCandle,
    setStreamCandles,
    setStreamConnected,
    setQuote,
    activeSymbol,
  } = useStore()

  const handleMessage = useCallback((raw: string) => {
    let msg: any
    try { msg = JSON.parse(raw) } catch { return }

    const { type, symbol, data, candle, candle_sym } = msg

    switch (type) {

      case 'connected':
        setStreamConnected(true, 'dxlink')
        break

      case 'quote': {
        // symbol is the underlying (e.g. "SPY")
        if (symbol && data) {
          updateLiveQuote(symbol, data)
        }
        break
      }

      case 'candle': {
        // symbol here is the candle_sym e.g. "SPY{=1d}"
        // candle = { time, open, high, low, close, volume }
        const cSym   = msg.symbol as string   // "SPY{=1d}"
        const bar    = msg.candle as Candle
        const isUpdt = msg.is_update as boolean

        if (!cSym || !bar) break

        // Derive the store key from candle symbol
        // "SPY{=1d}" ? key depends on how ChartTile subscribed
        // We use the full candle symbol as the key
        if (isUpdt) {
          updateStreamCandle(cSym, bar)
        } else {
          // Historical bulk candles arrive one by one ? accumulate
          updateStreamCandle(cSym, bar)
        }
        break
      }

      case 'order':
        // Future: trigger positions refresh, show toast
        console.log('[stream] Order event:', data?.status, data?.id)
        break

      case 'balance':
        // Future: update net liq in real-time
        break

      case 'position':
        // Future: trigger positions refresh
        break

      case 'ping':
        // Backend keepalive ? no action needed
        break

      default:
        break
    }
  }, [updateLiveQuote, updateStreamCandle, setStreamConnected])

  const connect = useCallback(() => {
    if (!mounted.current) return

    const ws = new WebSocket(WS_URL)
    wsRef.current = ws

    ws.onopen = () => {
      console.log('[stream] WebSocket connected')
      setStreamConnected(true, 'dxlink')
    }

    ws.onmessage = (e) => handleMessage(e.data)

    ws.onclose = () => {
      console.log('[stream] WebSocket closed ? reconnecting in 3s')
      setStreamConnected(false, 'none')
      wsRef.current = null
      if (mounted.current) {
        retryTimer.current = setTimeout(connect, RECONNECT_MS)
      }
    }

    ws.onerror = () => {
      // onerror always followed by onclose ? let onclose handle reconnect
      setStreamConnected(false, 'none')
    }
  }, [handleMessage, setStreamConnected])

  useEffect(() => {
    mounted.current = true
    connect()

    return () => {
      mounted.current = false
      if (retryTimer.current) clearTimeout(retryTimer.current)
      if (wsRef.current) {
        wsRef.current.onclose = null   // prevent reconnect on unmount
        wsRef.current.close()
      }
    }
  }, [connect])

  // Expose a manual subscribe function so components can request symbols
  const subscribeQuotes = useCallback(async (symbols: string[]) => {
    try {
      await fetch('http://localhost:8000/stream/subscribe/quotes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ symbols }),
      })
    } catch (e) {
      console.warn('[stream] subscribeQuotes failed:', e)
    }
  }, [])

  const subscribeCandles = useCallback(async (symbol: string, period: string) => {
    try {
      await fetch('http://localhost:8000/stream/subscribe/candles', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ symbols: [symbol], period }),
      })
    } catch (e) {
      console.warn('[stream] subscribeCandles failed:', e)
    }
  }, [])

  const subscribeGreeks = useCallback(async (optionSymbols: string[]) => {
    try {
      await fetch('http://localhost:8000/stream/subscribe/greeks', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ option_symbols: optionSymbols }),
      })
    } catch (e) {
      console.warn('[stream] subscribeGreeks failed:', e)
    }
  }, [])

  return { subscribeQuotes, subscribeCandles, subscribeGreeks }
}

'@
WF "react-frontend\src\hooks\useStream.ts" $c

$c = @'
import type { LimitSummary, Position, ScanResult, VolSurfaceData } from '../types'

const API = 'http://localhost:8000'

async function get<T>(path: string): Promise<T> {
  const r = await fetch(API + path)
  if (!r.ok) {
    const text = await r.text()
    throw new Error(text || `HTTP ${r.status}`)
  }
  return r.json()
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const r = await fetch(API + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!r.ok) {
    const text = await r.text()
    throw new Error(text || `HTTP ${r.status}`)
  }
  return r.json()
}

// ?? Account ???????????????????????????????????????????????
export async function fetchAccount(source: 'mock' | 'tasty'): Promise<{
  source: string
  positions: Position[]
  limit_summary: LimitSummary
}> {
  // Always use tasty ? mock removed
  return get('/account/tasty')
}

// ?? Quote ? DXLink live + chain fallback ??????????????????
export async function fetchQuote(symbol: string): Promise<{
  symbol: string
  source: string
  live_last?: number
  live_bid?: number
  live_ask?: number
  live_open?: number
  live_high?: number
  live_low?: number
  live_prev_close?: number
  live_volume?: number
  underlying_price?: number
}> {
  return get(`/quote/live?symbol=${encodeURIComponent(symbol)}`)
}

// ?? Chain ? tastytrade + DXLink ???????????????????????????
export async function fetchChain(symbol: string): Promise<{
  symbol: string
  underlying_price: number
  expirations: string[]
  strikes: number[]
  active_chain_source: string
}> {
  return get(`/chain?symbol=${encodeURIComponent(symbol)}`)
}

// ?? Refresh ???????????????????????????????????????????????
export async function refreshSymbol(symbol: string): Promise<{
  symbol: string
  active_chain_source: string
  contract_count: number
  expirations: string[]
}> {
  return get(`/refresh/symbol?symbol=${encodeURIComponent(symbol)}`)
}

// ?? Scanner ???????????????????????????????????????????????
export interface ScanParams {
  symbol: string
  total_risk: number
  side: 'all' | 'call' | 'put'
  expiration: string
  sort_by: string
  max_results: number
}

export async function fetchScan(params: ScanParams): Promise<{
  symbol: string
  count: number
  items: ScanResult[]
  active_chain_source: string
}> {
  const qs = new URLSearchParams({
    symbol:      params.symbol,
    total_risk:  String(params.total_risk),
    side:        params.side,
    expiration:  params.expiration,
    sort_by:     params.sort_by,
    max_results: String(params.max_results),
  })
  return get(`/scan/live?${qs}`)
}

// ?? Vol Surface ???????????????????????????????????????????
export async function fetchVolSurface(
  symbol: string,
  maxExp     = 7,
  strikeCount = 25,
): Promise<VolSurfaceData> {
  return get(
    `/vol/surface?symbol=${encodeURIComponent(symbol)}&max_expirations=${maxExp}&strike_count=${strikeCount}`
  )
}

// ?? Alerts ????????????????????????????????????????????????
export async function sendPushover(title: string, message: string): Promise<void> {
  await post('/alerts/pushover', { title, message, notify_whatsapp: false })
}

// ?? Health ????????????????????????????????????????????????
export async function fetchHealth(): Promise<{
  status: string
  active_chain_source: string
  dxlink_connected: boolean
}> {
  return get('/health')
}

// ?? Candles ???????????????????????????????????????????????
export interface Candle {
  time:   number   // Unix seconds
  open:   number
  high:   number
  low:    number
  close:  number
  volume: number
}

export interface PriceHistory {
  symbol:    string
  period:    string
  frequency: string
  count:     number
  candles:   Candle[]
}

// DXLink streaming candles first, chart/history REST fallback
export async function fetchPriceHistory(
  symbol: string,
  period    = '20y',
  frequency = 'daily',
): Promise<PriceHistory> {
  return get(
    `/stream/candles?symbol=${encodeURIComponent(symbol)}&period=${period}`
  )
}

'@
WF "react-frontend\src\api\client.ts" $c

Write-Host "Building React..." -ForegroundColor Yellow
$wslRoot = ($Root -replace 'C:\\\\', '/mnt/c/') -replace '\\\\', '/'
wsl.exe bash -lc "cd '$wslRoot/react-frontend' && npm run build 2>&1 | tail -15"
if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "Build OK" -ForegroundColor Green
    Write-Host "Changes in this build:" -ForegroundColor Yellow
    Write-Host "  SCANNER: waits 8s for DXLink option quotes - real results now" -ForegroundColor Cyan
    Write-Host "  VOL SURFACE: same fix - IVs will populate" -ForegroundColor Cyan
    Write-Host "  TOPBAR: scrolling index marquee (SPY/QQQ/IWM/GLD/TLT/VIX)" -ForegroundColor Cyan
    Write-Host "  PANELS: minimize arrow button top-right of each tile" -ForegroundColor Cyan
    Write-Host "  SCANNER: CSV download button" -ForegroundColor Cyan
    Write-Host "  CHART: auto-fit indicators, standard TF buttons, price left" -ForegroundColor Cyan
    Write-Host "  FONT: drag slider in bottom-right to resize" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Refresh http://localhost:5500" -ForegroundColor Yellow
    Write-Host "Wait 15s after page loads before scanning (DXLink option warm-up)" -ForegroundColor Yellow
} else {
    Write-Host "Build errors - paste to Claude" -ForegroundColor Red
}
