param([string]$Root = "C:\\Users\\alexm\\granite_trader")
$ErrorActionPreference = "Stop"
function WF([string]$rel,[string]$txt){$p=Join-Path $Root ($rel -replace '/','\\')
$d=Split-Path $p -Parent
if(-not(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d|Out-Null}
[System.IO.File]::WriteAllText($p,$txt,(New-Object System.Text.UTF8Encoding($false)))
Write-Host "[OK] $rel" -ForegroundColor Cyan}

Write-Host "Installing React stream frontend..." -ForegroundColor Yellow
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
  const isFocused = focusedTile === id

  return (
    <div
      className={`tile${isFocused ? ' tile-focused' : ''}`}
      style={{ height: '100%' }}
      onMouseDown={() => setFocusedTile(id)}
    >
      {children}
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
      const raw = await fetchQuote(sym)
      const payload = raw[sym] ?? raw[sym.toUpperCase()] ?? {}
      const q = (payload as any).quote ?? payload
      const last   = Number(q.lastPrice || q.mark || q.closePrice || 0) || null
      const open   = Number(q.openPrice  || 0) || null
      const high   = Number(q.highPrice  || 0) || null
      const low    = Number(q.lowPrice   || 0) || null
      const chg    = Number(q.netChange  || 0)
      const pctChg = q.closePrice ? chg / Number(q.closePrice) : 0

      setQuote({ symbol: sym, lastPrice: last, openPrice: open, highPrice: high, lowPrice: low, netChange: chg, netPctChange: pctChg, bid: Number(q.bidPrice || 0) || null, ask: Number(q.askPrice || 0) || null, activeSource: 'SCHWAB' })
      if (last) setLivePrice(sym, last, pctChg)
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

          {TF_OPTIONS.map(t => (
            <button
              key={t.label}
              className={`btn sm${tf === t.period ? ' active' : ''}`}
              style={{ fontSize: 12 }}
              onClick={() => { setTf(t.period); setFreq(t.freq); loadChart(sym, t.period, t.freq) }}
            >{t.label}</button>
          ))}

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

function f$(v: number | null) {
  return v == null ? '--' : '$' + v.toFixed(2)
}

interface Props {
  onRefreshNow: () => void
  onAlertsOpen: () => void
}

export function TopBar({ onRefreshNow, onAlertsOpen }: Props) {
  const {
    limitSummary, quote, acctSource, setAcctSource,
    theme, setTheme, refreshInterval, refreshCountdown,
    setRefreshInterval, desktopAllowed, setDesktopAllowed,
    streamConnected, streamSource,
  } = useStore()

  const usedPct  = limitSummary ? Number(limitSummary.used_pct) * 100 : 0
  const pctColor = usedPct > 80 ? 'var(--red)' : usedPct > 60 ? 'var(--warn)' : 'var(--green)'
  const chgColor = (quote.netChange ?? 0) >= 0 ? 'var(--green)' : 'var(--red)'
  const chgSign  = (quote.netChange ?? 0) >= 0 ? '+' : ''
  const chgText  = quote.netChange != null
    ? `${chgSign}${quote.netChange.toFixed(2)}  (${((quote.netPctChange ?? 0) * 100).toFixed(2)}%)`
    : '--'

  async function enableNotifs() {
    if (!('Notification' in window)) return
    const p = await Notification.requestPermission()
    setDesktopAllowed(p === 'granted')
  }

  return (
    <div className="topbar">
      {/* ?? LEFT: brand + menu ?? */}
      <div className="topbar-left">
        <span className="topbar-brand">&#x2B21; GRANITE</span>
        <div className="tsep" />
        <button className="btn sm" onClick={onRefreshNow}>&#x21BA; NOW</button>
        <button className="btn sm" onClick={onAlertsOpen}>&#x1F514; ALERTS</button>
        <button
          className="btn sm"
          onClick={enableNotifs}
          title={desktopAllowed ? 'Desktop alerts active' : 'Enable desktop alerts'}
          style={{ color: desktopAllowed ? 'var(--green)' : undefined }}
        >
          {desktopAllowed ? '&#x2705; NOTIF' : 'NOTIF OFF'}
        </button>
      </div>

      {/* ?? CENTER: focal price display ?? */}
      <div className="topbar-center">
        <span className="topbar-sym">{quote.symbol}</span>
        <span
          className="topbar-price-big"
          style={{ color: (quote.netChange ?? 0) >= 0 ? 'var(--text)' : 'var(--red)' }}
        >
          {quote.lastPrice != null ? '$' + quote.lastPrice.toFixed(2) : '--'}
        </span>
        <span className="topbar-chg" style={{ color: chgColor }}>{chgText}</span>
      </div>

      {/* ?? RIGHT: balances ?? */}
      <div className="topbar-right">
        <div className="tpill">
          <span className="lbl">Net Liq</span>
          <span className="val">{f$(limitSummary?.net_liq ?? null)}</span>
        </div>
        <div className="tpill">
          <span className="lbl">Limit &#xD7;25</span>
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
        <div className="tpill" style={{ minWidth: 100 }}>
          <span className="lbl">Data Source</span>
          <span className="val" style={{ fontSize: 11, color: streamConnected ? 'var(--green)' : 'var(--muted)', display: 'flex', alignItems: 'center', gap: 5 }}>
            <span style={{ width: 8, height: 8, borderRadius: '50%', background: streamConnected ? 'var(--green)' : 'var(--border)', flexShrink: 0, boxShadow: streamConnected ? '0 0 6px var(--green)' : 'none' }} />
            {streamConnected ? 'DXLINK LIVE' : (quote.activeSource || 'REST')}
          </span>
        </div>

        {/* Account source ? always live */}
        <div style={{ padding: '3px 10px', background: 'var(--bg3)', border: '1px solid var(--green)', borderRadius: 3, fontSize: 11, color: 'var(--green)', fontWeight: 700 }}>
          TASTY LIVE
        </div>
      </div>
    </div>
  )
}

'@
WF "react-frontend\src\components\layout\TopBar.tsx" $c

Write-Host "Building React..." -ForegroundColor Yellow
$wslRoot = ($Root -replace 'C:\\\\', '/mnt/c/') -replace '\\\\', '/'
wsl.exe bash -lc "cd '$wslRoot/react-frontend' && npm run build 2>&1 | tail -15"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[Granite] Build OK" -ForegroundColor Green
    Write-Host "Chart will now use DXLink streaming candles with series.update()" -ForegroundColor Green
    Write-Host "Live status dot in topbar: green = DXLink streaming" -ForegroundColor Green
    Write-Host "Restart app then refresh http://localhost:5500" -ForegroundColor Yellow
} else {
    Write-Host "Build errors above - paste to Claude" -ForegroundColor Red
}
