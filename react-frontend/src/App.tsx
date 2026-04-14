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
