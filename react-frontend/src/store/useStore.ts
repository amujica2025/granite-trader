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
