param(
    [string]$Root = "C:\Users\alexm\granite_trader"
)
$ErrorActionPreference = "Stop"
function Write-Info([string]$m) { Write-Host "[Granite] $m" -ForegroundColor Cyan }
function Write-OK([string]$m)   { Write-Host "[Granite] $m" -ForegroundColor Green }
function Write-File([string]$rel, [string]$text) {
    $p = Join-Path $Root ($rel -replace '/', '\')
    $d = Split-Path $p -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Info "  $rel"
}
Write-Info "Patching 4 files..."
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

// ── Indicator math (client-side) ─────────────────────────────

function sma(data: number[], period: number): (number | null)[] {
  const out: (number | null)[] = []
  for (let i = 0; i < data.length; i++) {
    if (i < period - 1) { out.push(null); continue }
    const slice = data.slice(i - period + 1, i + 1)
    out.push(slice.reduce((a, b) => a + b, 0) / period)
  }
  return out
}

function rsi(closes: number[], period: number): (number | null)[] {
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
    const g = d > 0 ? d : 0, l = d < 0 ? -d : 0
    avgG = (avgG * (period - 1) + g) / period
    avgL = (avgL * (period - 1) + l) / period
    out[i] = avgL === 0 ? 100 : 100 - 100 / (1 + avgG / avgL)
  }
  return out
}

function atr(candles: Candle[], period: number): (number | null)[] {
  const out: (number | null)[] = [null]
  let sum = 0
  for (let i = 1; i < candles.length; i++) {
    const h = candles[i].high, l = candles[i].low, pc = candles[i - 1].close
    const tr = Math.max(h - l, Math.abs(h - pc), Math.abs(l - pc))
    if (i < period) { out.push(null); sum += tr; continue }
    if (i === period) {
      sum += tr
      const v = sum / period
      out.push(v)
      continue
    }
    const prev = out[i - 1] as number
    out.push((prev * (period - 1) + tr) / period)
  }
  return out
}

function vortex(candles: Candle[], period: number) {
  const n = candles.length
  const vip: (number | null)[] = Array(n).fill(null)
  const vim: (number | null)[] = Array(n).fill(null)
  for (let i = period; i < n; i++) {
    let vpSum = 0, vmSum = 0, trSum = 0
    for (let j = i - period + 1; j <= i; j++) {
      const h = candles[j].high, l = candles[j].low
      const ph = candles[j - 1].high, pl = candles[j - 1].low, pc = candles[j - 1].close
      vpSum += Math.abs(h - pl)
      vmSum += Math.abs(l - ph)
      trSum += Math.max(h - l, Math.abs(h - pc), Math.abs(l - pc))
    }
    vip[i] = trSum > 0 ? vpSum / trSum : null
    vim[i] = trSum > 0 ? vmSum / trSum : null
  }
  return { vip, vim }
}

function ema(data: (number | null)[], period: number): (number | null)[] {
  const k = 2 / (period + 1)
  const out: (number | null)[] = Array(data.length).fill(null)
  let started = false
  let prev = 0
  for (let i = 0; i < data.length; i++) {
    if (data[i] == null) { out[i] = started ? prev : null; continue }
    const v = data[i] as number
    if (!started) { out[i] = v; prev = v; started = true; continue }
    const next = v * k + prev * (1 - k)
    out[i] = next; prev = next
  }
  return out
}

function ppoCalc(closes: number[], fast: number, slow: number, signal: number) {
  const fastE = ema(closes, fast)
  const slowE = ema(closes, slow)
  const ppoLine = closes.map((_, i) => {
    if (fastE[i] == null || slowE[i] == null || (slowE[i] as number) === 0) return null
    return ((fastE[i] as number) - (slowE[i] as number)) / (slowE[i] as number) * 100
  })
  const sigLine = ema(ppoLine, signal)
  const hist    = ppoLine.map((v, i) => v == null || sigLine[i] == null ? null : v - (sigLine[i] as number))
  return { ppoLine, sigLine, hist }
}

// ── SMA config ───────────────────────────────────────────────
const SMA_PERIODS = [8, 16, 32, 50, 64, 128, 200] as const
type SmaPeriod = typeof SMA_PERIODS[number]
const SMA_COLORS: Record<SmaPeriod, string> = {
  8:'#4d9fff', 16:'#3bba6c', 32:'#e5b84c', 50:'#f8923a', 64:'#a855f7', 128:'#ec4899', 200:'#f04f48',
}

// ── Timeframes ───────────────────────────────────────────────
const TF_OPTIONS = [
  { label:'1D', period:'1d',  freq:'5min'  },
  { label:'5D', period:'5d',  freq:'15min' },
  { label:'1M', period:'1m',  freq:'daily' },
  { label:'3M', period:'3m',  freq:'daily' },
  { label:'6M', period:'6m',  freq:'daily' },
  { label:'1Y', period:'1y',  freq:'daily' },
  { label:'2Y', period:'2y',  freq:'daily' },
  { label:'5Y', period:'5y',  freq:'daily' },
  { label:'YTD',period:'ytd', freq:'daily' },
]

// ── Helpers ──────────────────────────────────────────────────
function toTimeStr(c: Candle, freq: string): string {
  const isDaily = freq === 'daily' || freq === 'weekly' || freq === 'monthly'
  return isDaily
    ? new Date(c.time * 1000).toISOString().slice(0, 10)
    : String(c.time)
}

// ── Mini chart sub-panel ─────────────────────────────────────
function MiniLineChart({
  points, color, height, title, refLines,
}: {
  points: { time: string; value: number | null }[]
  color: string
  height: string
  title: string
  refLines?: { value: number; color: string }[]
}) {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 10, fontFamily: 'IBM Plex Mono, monospace' },
      grid:   { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0' },
      timeScale: { borderColor: '#1c2b3a', visible: false },
      width:  ref.current.clientWidth,
      height: ref.current.clientHeight,
    })
    // v4 API: addLineSeries()
    const s = c.addLineSeries({ color, lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const data = points
      .filter(p => p.value != null)
      .map(p => ({ time: p.time as Time, value: p.value as number }))
    s.setData(data)
    refLines?.forEach(rl =>
      s.createPriceLine({ price: rl.value, color: rl.color, lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: false, title: '' })
    )
    const obs = new ResizeObserver(() => {
      if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight })
    })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [points])

  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>{title}</div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

function MiniTwoLineChart({
  p1, p2, c1, c2, height, title,
}: {
  p1: { time: string; value: number | null }[]
  p2: { time: string; value: number | null }[]
  c1: string; c2: string; height: string; title: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 10, fontFamily: 'IBM Plex Mono, monospace' },
      grid:   { vertLines: { visible: false }, horzLines: { visible: false } },
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
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>{title}</div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

function MiniHistoLineChart({
  hist, line1, line2, height, title,
}: {
  hist: { time: string; value: number | null; color?: string }[]
  line1: { time: string; value: number | null }[]
  line2: { time: string; value: number | null }[]
  height: string; title: string
}) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 10, fontFamily: 'IBM Plex Mono, monospace' },
      grid:   { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0' },
      timeScale: { borderColor: '#1c2b3a', visible: false },
      width: ref.current.clientWidth, height: ref.current.clientHeight,
    })
    // v4 API: addHistogramSeries, addLineSeries
    const sh = c.addHistogramSeries({ color: '#4d9fff40', priceLineVisible: false, lastValueVisible: false })
    const s1 = c.addLineSeries({ color: '#4d9fff', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const s2 = c.addLineSeries({ color: '#f04f48', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    sh.setData(hist.filter(x => x.value != null).map(x => ({ time: x.time as Time, value: x.value as number, color: x.value! >= 0 ? '#4d9fff60' : '#f04f4860' })))
    s1.setData(line1.filter(x => x.value != null).map(x => ({ time: x.time as Time, value: x.value as number })))
    s2.setData(line2.filter(x => x.value != null).map(x => ({ time: x.time as Time, value: x.value as number })))
    const obs = new ResizeObserver(() => { if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight }) })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [hist, line1, line2])
  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>{title}</div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

// ── Main ChartTile ───────────────────────────────────────────

export function ChartTile() {
  const { activeSymbol, quote, positions } = useStore()

  const chartRef    = useRef<HTMLDivElement>(null)
  const chart       = useRef<IChartApi | null>(null)
  // v4 types
  const candleSeries = useRef<ISeriesApi<'Candlestick'> | null>(null)
  const smaMap       = useRef<Map<SmaPeriod, ISeriesApi<'Line'>>>(new Map())

  const [candles,    setCandles]    = useState<Candle[]>([])
  const [loading,    setLoading]    = useState(false)
  const [error,      setError]      = useState<string | null>(null)
  const [sym,        setSym]        = useState(activeSymbol)
  const [tf,         setTf]         = useState('5y')
  const [freq,       setFreq]       = useState('daily')
  const [ctxMenu,    setCtxMenu]    = useState<{ x: number; y: number; time: number; price: number } | null>(null)
  const [activeSmas, setActiveSmas] = useState<Set<SmaPeriod>>(new Set([50, 200]))
  const [showRsi,    setShowRsi]    = useState(false)
  const [showAtr,    setShowAtr]    = useState(false)
  const [showVortex, setShowVortex] = useState(false)
  const [showPpo,    setShowPpo]    = useState(false)

  // ── Init chart (v4 API) ────────────────────────────────────
  useEffect(() => {
    if (!chartRef.current) return
    const c = createChart(chartRef.current, {
      layout: {
        background: { color: 'rgba(10,12,18,0)' },
        textColor: '#6e8aa0',
        fontFamily: 'IBM Plex Mono, monospace',
        fontSize: 11,
      },
      grid: { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: {
        mode: CrosshairMode.Normal,
        vertLine: { labelVisible: true, color: '#4d9fff50', width: 1, style: LineStyle.Dashed },
        horzLine: { labelVisible: true, color: '#4d9fff50', width: 1, style: LineStyle.Dashed },
      },
      rightPriceScale: {
        borderColor: '#1c2b3a',
        textColor:   '#6e8aa0',
        scaleMargins: { top: 0.08, bottom: 0.15 },
      },
      timeScale: {
        borderColor:    '#1c2b3a',
        timeVisible:    true,
        secondsVisible: false,
        rightOffset:    8,
        barSpacing:     6,
      },
      handleScroll: true,
      handleScale:  true,
    })

    // v4: addCandlestickSeries()
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

    // Right-click context menu
    const el = chartRef.current
    const onCtx = (e: MouseEvent) => {
      e.preventDefault()
      if (!chart.current) return
      const rect  = el.getBoundingClientRect()
      const time  = chart.current.timeScale().coordinateToTime(e.clientX - rect.left)
      const price = candleSeries.current?.coordinateToPrice(e.clientY - rect.top) ?? 0
      setCtxMenu({ x: e.clientX, y: e.clientY, time: typeof time === 'number' ? time : 0, price: price ?? 0 })
    }
    el.addEventListener('contextmenu', onCtx)

    // ResizeObserver
    const obs = new ResizeObserver(() => {
      if (el && chart.current) {
        chart.current.applyOptions({ width: el.clientWidth, height: el.clientHeight })
      }
    })
    obs.observe(el)

    return () => {
      obs.disconnect()
      el.removeEventListener('contextmenu', onCtx)
      c.remove()
      chart.current        = null
      candleSeries.current = null
    }
  }, [])

  // ── Load price data ────────────────────────────────────────
  const loadChart = useCallback(async (s: string, period: string, frequency: string) => {
    if (!candleSeries.current) return
    setLoading(true); setError(null)
    try {
      const data = await fetchPriceHistory(s, period, frequency)
      setCandles(data.candles)
      const isDaily = frequency === 'daily' || frequency === 'weekly' || frequency === 'monthly'
      const cdData: CandlestickData<Time>[] = data.candles.map(c => ({
        time:  (isDaily ? new Date(c.time * 1000).toISOString().slice(0, 10) : c.time) as Time,
        open:  c.open, high: c.high, low: c.low, close: c.close,
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

  // Sync active symbol
  useEffect(() => {
    if (activeSymbol && activeSymbol !== sym) {
      setSym(activeSymbol)
      loadChart(activeSymbol, tf, freq)
    }
  }, [activeSymbol])

  // ── SMAs (v4: addLineSeries) ───────────────────────────────
  useEffect(() => {
    if (!chart.current || !candles.length) return
    const closes = candles.map(c => c.close)
    const isDaily = freq === 'daily' || freq === 'weekly' || freq === 'monthly'
    const times   = candles.map(c => (isDaily ? new Date(c.time * 1000).toISOString().slice(0, 10) : String(c.time)) as Time)

    SMA_PERIODS.forEach(period => {
      const existing = smaMap.current.get(period)
      if (activeSmas.has(period)) {
        const vals = sma(closes, period)
        const lineData: LineData<Time>[] = vals
          .map((v, i) => ({ time: times[i], value: v }))
          .filter(d => d.value != null) as LineData<Time>[]
        if (existing) {
          existing.setData(lineData)
          existing.applyOptions({ visible: true })
        } else {
          // v4: addLineSeries()
          const s = chart.current!.addLineSeries({
            color: SMA_COLORS[period],
            lineWidth: period >= 128 ? 2 : 1,
            priceLineVisible: false,
            lastValueVisible: false,
            crosshairMarkerVisible: false,
          })
          s.setData(lineData)
          smaMap.current.set(period, s)
        }
      } else if (existing) {
        existing.applyOptions({ visible: false })
      }
    })
  }, [activeSmas, candles, freq])

  // ── Open positions markers ─────────────────────────────────
  useEffect(() => {
    if (!candleSeries.current || !positions.length || !candles.length) return
    const symPos = positions.filter(p => p.underlying === sym)
    if (!symPos.length) { candleSeries.current.setMarkers([]); return }
    const isDaily = freq === 'daily' || freq === 'weekly' || freq === 'monthly'
    const today = isDaily ? new Date().toISOString().slice(0, 10) : String(Math.floor(Date.now() / 1000))
    const markers = symPos.map(p => ({
      time: today as Time,
      position: (p.display_qty < 0 ? 'aboveBar' : 'belowBar') as any,
      color:    p.display_qty < 0 ? '#f04f48' : '#3bba6c',
      shape:   (p.display_qty < 0 ? 'arrowDown' : 'arrowUp') as any,
      text:    `${p.option_type}${p.strike} ${p.display_qty > 0 ? '+' : ''}${p.display_qty}`,
    }))
    candleSeries.current.setMarkers(markers)
  }, [positions, candles, sym])

  // ── Expected move lines ────────────────────────────────────
  useEffect(() => {
    if (!candleSeries.current || !quote.atmStraddle || !quote.lastPrice) return
    const move  = quote.atmStraddle * 0.85
    const upper = quote.lastPrice + move
    const lower = quote.lastPrice - move
    try {
      (candleSeries.current as any).__em_u?.remove()
      ;(candleSeries.current as any).__em_l?.remove()
    } catch {}
    const ul = candleSeries.current.createPriceLine({ price: upper, color: '#3bba6c88', lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: true, title: `EM+ ${upper.toFixed(2)}` })
    const ll = candleSeries.current.createPriceLine({ price: lower, color: '#f04f4888', lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: true, title: `EM− ${lower.toFixed(2)}` })
    ;(candleSeries.current as any).__em_u = ul
    ;(candleSeries.current as any).__em_l = ll
  }, [quote.atmStraddle, quote.lastPrice])

  function toggleSma(p: SmaPeriod) {
    setActiveSmas(prev => { const n = new Set(prev); n.has(p) ? n.delete(p) : n.add(p); return n })
  }

  function openGoogleNews() {
    if (!ctxMenu) return
    const date = ctxMenu.time > 0 ? new Date(ctxMenu.time * 1000).toISOString().slice(0, 10) : new Date().toISOString().slice(0, 10)
    window.open(`https://www.google.com/search?q=${encodeURIComponent(sym)}+stock+news&tbs=cdr:1,cd_min:${date},cd_max:${date}&tbm=nws`, '_blank')
    setCtxMenu(null)
  }

  function addAlertAtPrice() {
    if (!ctxMenu) return
    window.dispatchEvent(new CustomEvent('granite:addAlertAtPrice', { detail: { sym, price: ctxMenu.price.toFixed(2) } }))
    setCtxMenu(null)
  }

  // ── Computed indicator data (memo) ─────────────────────────
  const closes = candles.map(c => c.close)
  const times  = candles.map(c => toTimeStr(c, freq))

  const rsiVals    = showRsi    ? rsi(closes, 15)    : []
  const atrVals    = showAtr    ? atr(candles, 5)    : []
  const vortexVals = showVortex ? vortex(candles, 14): { vip: [], vim: [] }
  const ppoVals    = showPpo    ? ppoCalc(closes, 12, 48, 200) : { ppoLine: [], sigLine: [], hist: [] }

  const toPoints = (vals: (number | null)[]) =>
    times.map((t, i) => ({ time: t, value: vals[i] ?? null }))

  const numIndicators = [showRsi, showAtr, showVortex, showPpo].filter(Boolean).length
  const indH = numIndicators > 0 ? `${Math.floor(40 / numIndicators)}%` : '0%'

  const chgColor = (quote.netChange ?? 0) >= 0 ? '#3bba6c' : '#f04f48'
  const move     = quote.atmStraddle ? (quote.atmStraddle * 0.85).toFixed(2) : null

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column' }} onClick={() => ctxMenu && setCtxMenu(null)}>

      {/* ── Header ── */}
      <div className="tile-hdr" style={{ flexDirection: 'column', height: 'auto', padding: '5px 10px', gap: 5, cursor: 'default' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
          <span className="tile-title">Chart</span>
          <input
            type="text" value={sym}
            onChange={e => setSym(e.target.value.toUpperCase())}
            onKeyDown={e => e.key === 'Enter' && loadChart(sym, tf, freq)}
            style={{ width: 66, fontSize: 12, fontWeight: 700, padding: '2px 6px' }}
          />
          <button className="btn sm primary" onClick={() => loadChart(sym, tf, freq)}>LOAD</button>

          {/* Timeframes */}
          {TF_OPTIONS.map(t => (
            <button
              key={t.label}
              className={`btn sm${tf === t.period ? ' active' : ''}`}
              onClick={() => { setTf(t.period); setFreq(t.freq); loadChart(sym, t.period, t.freq) }}
            >{t.label}</button>
          ))}

          {/* Price focal point */}
          <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span style={{ fontSize: 24, fontWeight: 700, lineHeight: 1, letterSpacing: '-0.02em' }}>
              {quote.lastPrice != null ? '$' + quote.lastPrice.toFixed(2) : '--'}
            </span>
            <span style={{ fontSize: 13, color: chgColor }}>
              {quote.netChange != null ? `${quote.netChange >= 0 ? '+' : ''}${quote.netChange.toFixed(2)} (${((quote.netPctChange ?? 0) * 100).toFixed(2)}%)` : '--'}
            </span>
            {quote.openPrice && <span style={{ fontSize: 11, color: 'var(--muted)' }}>O {quote.openPrice.toFixed(2)}</span>}
            {quote.highPrice && <span style={{ fontSize: 11, color: '#3bba6c' }}>H {quote.highPrice.toFixed(2)}</span>}
            {quote.lowPrice  && <span style={{ fontSize: 11, color: '#f04f48' }}>L {quote.lowPrice.toFixed(2)}</span>}
            {move && <span style={{ fontSize: 11, color: 'var(--muted)' }}>EM ±${move}</span>}
          </div>
        </div>

        {/* SMA + Indicator toggles */}
        <div style={{ display: 'flex', gap: 3, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ fontSize: 8, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>SMA</span>
          {SMA_PERIODS.map(p => (
            <button
              key={p}
              className="btn sm"
              style={{ fontSize: 9, padding: '1px 5px', borderColor: activeSmas.has(p) ? SMA_COLORS[p] : undefined, color: activeSmas.has(p) ? SMA_COLORS[p] : 'var(--muted)', background: activeSmas.has(p) ? SMA_COLORS[p] + '18' : undefined }}
              onClick={() => toggleSma(p)}
            >{p}</button>
          ))}
          <div style={{ width: 1, height: 14, background: 'var(--border)', margin: '0 3px' }} />
          <span style={{ fontSize: 8, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>IND</span>
          {[
            { label: 'RSI 15', val: showRsi,    set: setShowRsi    },
            { label: 'ATR 5',  val: showAtr,    set: setShowAtr    },
            { label: 'VTX 14', val: showVortex, set: setShowVortex },
            { label: 'PPO',    val: showPpo,    set: setShowPpo    },
          ].map(ind => (
            <button
              key={ind.label}
              className={`btn sm${ind.val ? ' active' : ''}`}
              style={{ fontSize: 9, padding: '1px 5px' }}
              onClick={() => ind.set((v: boolean) => !v)}
            >{ind.label}</button>
          ))}
        </div>
      </div>

      {loading && <div className="loading">Loading {sym}...</div>}
      {error   && <div className="error-msg">{error}</div>}

      {/* ── Chart + indicators ── */}
      <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
        <div
          ref={chartRef}
          style={{ width: '100%', height: numIndicators > 0 ? '60%' : '100%', minHeight: 0 }}
        />
        {numIndicators > 0 && (
          <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', borderTop: '1px solid var(--border)' }}>
            {showRsi && (
              <MiniLineChart
                points={toPoints(rsiVals)}
                color="#9868f8" height={indH} title="RSI (15)"
                refLines={[{ value: 70, color: '#f04f4888' }, { value: 30, color: '#3bba6c88' }]}
              />
            )}
            {showAtr && (
              <MiniLineChart points={toPoints(atrVals)} color="#d4972a" height={indH} title="ATR (5)" />
            )}
            {showVortex && (
              <MiniTwoLineChart
                p1={toPoints(vortexVals.vip)} p2={toPoints(vortexVals.vim)}
                c1="#3bba6c" c2="#f04f48" height={indH} title="Vortex (14)  VI+ / VI−"
              />
            )}
            {showPpo && (
              <MiniHistoLineChart
                hist={toPoints(ppoVals.hist).map(x => ({ ...x, color: (x.value ?? 0) >= 0 ? '#4d9fff60' : '#f04f4860' }))}
                line1={toPoints(ppoVals.ppoLine)}
                line2={toPoints(ppoVals.sigLine)}
                height={indH} title="PPO (12,48,200)"
              />
            )}
          </div>
        )}
      </div>

      {/* ── Right-click context menu ── */}
      {ctxMenu && (
        <div
          style={{ position: 'fixed', left: ctxMenu.x, top: ctxMenu.y, zIndex: 99999, background: 'var(--bg2)', border: '1px solid var(--bord2)', borderRadius: 5, padding: '4px 0', minWidth: 220, boxShadow: '0 8px 32px rgba(0,0,0,.6)' }}
          onClick={e => e.stopPropagation()}
        >
          <div style={{ padding: '3px 12px 6px', fontSize: 10, color: 'var(--muted)', borderBottom: '1px solid var(--border)' }}>
            {sym} — {ctxMenu.time > 0 ? new Date(ctxMenu.time * 1000).toLocaleDateString() : 'today'} @ ${ctxMenu.price.toFixed(2)}
          </div>
          {[
            { icon: '📰', label: 'Google News for this date', fn: openGoogleNews },
            { icon: '🔔', label: `Add alert at $${ctxMenu.price.toFixed(2)}`, fn: addAlertAtPrice },
            { icon: '✕',  label: 'Close', fn: () => setCtxMenu(null) },
          ].map(item => (
            <div
              key={item.label}
              onClick={item.fn}
              style={{ padding: '6px 12px', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: 'var(--text)' }}
              onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg3)')}
              onMouseLeave={e => (e.currentTarget.style.background = '')}
            >
              <span style={{ fontSize: 14 }}>{item.icon}</span>{item.label}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

'@
Write-File "react-frontend\src\components\tiles\ChartTile.tsx" $c

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

// ── 2dp formatters ─────────────────────────────────────────
const f$  = (v: number | null | undefined) => v == null ? '--' : '$' + Number(v).toFixed(2)
const fPct = (v: number | null | undefined) => v == null ? '--' : (Number(v) * 100).toFixed(2) + '%'
const fIV  = (v: number | null | undefined) => v == null ? '--' : (Number(v) * 100).toFixed(2) + '%'
const fN2  = (v: number | null | undefined) => v == null ? '--' : Number(v).toFixed(2)

// ── Column definitions ─────────────────────────────────────
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
    meta: { tip: 'Strike you SELL — where you collect premium' },
  }),
  ch.accessor('long_strike', {
    header: 'Long', size: 60,
    cell: i => fN2(i.getValue()),
    meta: { tip: 'Strike you BUY — your protection leg' },
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
    meta: { tip: 'Actual defined risk = Width × 100 × Qty. May differ slightly from target when qty rounds.' },
  }),
  ch.accessor('max_loss', {
    header: 'Max Loss', size: 76,
    cell: i => <span style={{ color: 'var(--red)' }}>{f$(i.getValue())}</span>,
    meta: { tip: 'Worst-case loss = Actual Risk minus Net Credit' },
  }),
  ch.accessor('credit_pct_risk', {
    header: 'Cr%Risk', size: 66,
    cell: i => <span>{fPct(i.getValue())}</span>,
    meta: { tip: 'Net Credit / Actual Risk — primary reward/risk metric. 30% = collected 30¢ per $1 at risk.' },
  }),
  ch.accessor('short_delta', {
    header: 'Sht Δ', size: 60,
    cell: i => <span style={{ color: 'var(--muted)' }}>{fN2(i.getValue())}</span>,
    meta: { tip: 'Delta of the short leg ≈ approximate probability ITM at expiry' },
  }),
  ch.accessor('short_iv', {
    header: 'Sht IV', size: 62,
    cell: i => <span style={{ color: 'var(--muted)' }}>{fIV(i.getValue())}</span>,
    meta: { tip: 'Implied volatility of the short strike — what you are selling. Now correctly scaled.' },
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
    meta: { tip: 'max(Short Value, Long Cost) — tastytrade limit usage for this trade' },
  }),
]

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
Write-File "react-frontend\src\components\tiles\ScannerTile.tsx" $c

$c = @'
export interface Position {
  id: string
  underlying: string
  group?: string
  display_qty: number
  option_type: 'C' | 'P'
  expiration: string
  strike: number
  mark: number
  trade_price: number
  pnl_open: number
  short_value: number
  long_cost: number
  limit_impact: number
  delta?: number
  theta?: number
  vega?: number
}

export interface LimitSummary {
  net_liq: number
  max_limit: number
  used_short_value: number
  remaining_room: number
  used_pct: number
}

export interface ScanResult {
  symbol: string
  expiration: string
  structure: string
  option_side: 'call' | 'put'
  short_strike: number
  long_strike: number
  width: number
  quantity: number
  defined_risk: number
  gross_defined_risk: number
  actual_defined_risk: number
  target_defined_risk: number
  max_loss: number
  short_price: number
  long_price: number
  short_value: number
  long_cost: number
  net_credit: number
  credit_pct_risk: number
  credit_pct_risk_pct: number
  reward_to_max_loss: number | null
  limit_impact: number
  short_delta: number
  long_delta: number
  short_iv: number
  long_iv: number
  avg_iv: number
  richness_score: number
  credit_pct_risk_rank_within_exp: number
  iv_rank_within_exp: number
  exp_avg_credit_pct_risk: number
  exp_avg_iv: number
  underlying_price: number
  pricing_mode: string
}

export interface VolSurfaceData {
  symbol: string
  underlying_price: number | null
  expirations: string[]
  strikes: number[]
  iv_matrix: (number | null)[][]
  avg_iv_matrix: (number | null)[][]
  call_iv_matrix: (number | null)[][]
  put_iv_matrix: (number | null)[][]
  skew_matrix: (number | null)[][]
  avg_iv_by_expiration: Record<string, number | null>
  skew_curves: Record<string, { strike: number; call_iv: number | null; put_iv: number | null; avg_iv: number | null; skew_iv: number | null }[]>
  richness_scores: Record<string, {
    avg_iv: number | null
    put_call_skew_near_spot: number | null
    iv_premium_vs_surface: number | null
    richness_score: number | null
  }>
  count: number
  active_chain_source: string
  strike_spacing_by_expiration: Record<string, { common_step: number | null }>
}

export interface QuoteData {
  lastPrice?: number
  mark?: number
  closePrice?: number
  openPrice?: number
  highPrice?: number
  lowPrice?: number
  netChange?: number
  netPercentChange?: number
  bidPrice?: number
  askPrice?: number
}

export interface AlertRule {
  id: number
  sym: string
  field: string
  op: 'lt' | 'lte' | 'eq' | 'gte' | 'gt'
  val: number
  active: boolean
  triggered: boolean
}

export interface WatchlistRow {
  sym: string
  price: string
  chg: string
  rs14: string
  ivpct: string
  ivhv: string
  iv: string
  iv5d: string
  iv1m: string
  iv3m: string
  iv6m: string
  bb: string
  bbr: string
  ttm: string
  adr14: string
  opvol: string
  callvol: string
  putvol: string
}

export type Theme = 'slate' | 'navy' | 'emerald' | 'teal' | 'amber' | 'rose' | 'purple' | 'mono'

export type VSView = 'avg' | 'call' | 'put' | 'skew' | '3d'

'@
Write-File "react-frontend\src\types\index.ts" $c

$c = @'
declare module 'plotly.js-dist-min'

'@
Write-File "react-frontend\src\types\plotly.d.ts" $c


Write-Info "Rebuilding React in WSL..."
$wslRoot = ($Root -replace 'C:\\', '/mnt/c/') -replace '\\', '/'
$out = wsl.exe bash -lc "cd '$wslRoot/react-frontend' && npm run build 2>&1 | tail -25"
Write-Host $out
if ($LASTEXITCODE -eq 0) { Write-OK "Build successful! Restart the app then refresh http://localhost:5500" }
else { Write-Host "Build errors shown above. Paste them to Claude." -ForegroundColor Red }
