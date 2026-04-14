import {
  useEffect, useRef, useCallback, useState, useMemo,
} from 'react'
import {
  createChart, CandlestickSeries, LineSeries, HistogramSeries,
  CrosshairMode, LineStyle, PriceScaleMode,
  type IChartApi, type ISeriesApi, type Time,
  type CandlestickData, type LineData,
} from 'lightweight-charts'
import { useStore } from '../../store/useStore'
import { fetchPriceHistory, type Candle } from '../../api/client'

// â”€â”€ Indicator math (client-side) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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
  for (let i = 1; i < candles.length; i++) {
    const h = candles[i].high, l = candles[i].low, pc = candles[i - 1].close
    const tr = Math.max(h - l, Math.abs(h - pc), Math.abs(l - pc))
    if (i < period) { out.push(null); continue }
    if (i === period) {
      const slice = candles.slice(1, period + 1)
      const trSum = slice.reduce((a, c, j) => {
        const hp = c.high, lp = c.low, pcp = j > 0 ? slice[j - 1].close : candles[0].close
        return a + Math.max(hp - lp, Math.abs(hp - pcp), Math.abs(lp - pcp))
      }, 0)
      out.push(trSum / period); continue
    }
    const prev = out[i - 1] as number
    out.push((prev * (period - 1) + tr) / period)
  }
  return out
}

function vortex(candles: Candle[], period: number): { vip: (number|null)[]; vim: (number|null)[] } {
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

function ema(data: number[], period: number): (number | null)[] {
  const k = 2 / (period + 1)
  const out: (number | null)[] = Array(data.length).fill(null)
  let start = -1
  for (let i = 0; i < data.length; i++) {
    if (data[i] == null) continue
    if (start === -1) { out[i] = data[i]; start = i; continue }
    out[i] = data[i] * k + (out[i - 1] as number) * (1 - k)
  }
  return out
}

function ppo(closes: number[], fast: number, slow: number, signal: number): { ppo: (number|null)[]; sig: (number|null)[]; hist: (number|null)[] } {
  const fastEma  = ema(closes, fast)
  const slowEma  = ema(closes, slow)
  const ppoLine  = closes.map((_, i) => {
    if (fastEma[i] == null || slowEma[i] == null || (slowEma[i] as number) === 0) return null
    return ((fastEma[i] as number) - (slowEma[i] as number)) / (slowEma[i] as number) * 100
  })
  const sigLine = ema(ppoLine.map(v => v ?? 0), signal)
  const hist    = ppoLine.map((v, i) => v == null || sigLine[i] == null ? null : (v - (sigLine[i] as number)))
  return { ppo: ppoLine, sig: sigLine, hist }
}

// â”€â”€ Friday of week for expected move lines â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

function isFriday(unixSec: number): boolean {
  return new Date(unixSec * 1000).getDay() === 5
}

function nextFriday(unixSec: number): number {
  const d = new Date(unixSec * 1000)
  const day = d.getDay()
  const daysUntilFri = (5 - day + 7) % 7 || 7
  return unixSec + daysUntilFri * 86400
}

// â”€â”€ SMA periods â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
const SMA_PERIODS = [8, 16, 32, 50, 64, 128, 200] as const
type SmaPeriod = typeof SMA_PERIODS[number]

const SMA_COLORS: Record<SmaPeriod, string> = {
  8:   '#4d9fff',
  16:  '#3bba6c',
  32:  '#e5b84c',
  50:  '#f8923a',
  64:  '#a855f7',
  128: '#ec4899',
  200: '#f04f48',
}

// â”€â”€ Timeframe options â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
const TF_OPTIONS = [
  { label: '1D',   period: '1d',  frequency: '5min'  },
  { label: '5D',   period: '5d',  frequency: '15min' },
  { label: '1M',   period: '1m',  frequency: 'daily' },
  { label: '3M',   period: '3m',  frequency: 'daily' },
  { label: '6M',   period: '6m',  frequency: 'daily' },
  { label: '1Y',   period: '1y',  frequency: 'daily' },
  { label: '2Y',   period: '2y',  frequency: 'daily' },
  { label: '5Y',   period: '5y',  frequency: 'daily' },
  { label: 'YTD',  period: 'ytd', frequency: 'daily' },
]

// â”€â”€ Component â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

export function ChartTile() {
  const { activeSymbol, quote, positions, volData } = useStore()

  const chartContainerRef = useRef<HTMLDivElement>(null)
  const chart             = useRef<IChartApi | null>(null)
  const candleSeries      = useRef<ISeriesApi<'Candlestick'> | null>(null)
  const smaSeriesMap      = useRef<Map<SmaPeriod, ISeriesApi<'Line'>>>(new Map())
  const spySeriesRef      = useRef<ISeriesApi<'Line'> | null>(null)
  const gldSeriesRef      = useRef<ISeriesApi<'Line'> | null>(null)

  // Sub-panel series refs
  const rsiChartRef       = useRef<IChartApi | null>(null)
  const atrChartRef       = useRef<IChartApi | null>(null)
  const vortexChartRef    = useRef<IChartApi | null>(null)
  const ppoChartRef       = useRef<IChartApi | null>(null)

  const [candles, setCandles]         = useState<Candle[]>([])
  const [loading, setLoading]         = useState(false)
  const [error, setError]             = useState<string | null>(null)
  const [sym, setSym]                 = useState(activeSymbol)
  const [tf, setTf]                   = useState('5y')
  const [freq, setFreq]               = useState('daily')
  const [ctxMenu, setCtxMenu]         = useState<{ x: number; y: number; time: number; price: number } | null>(null)

  // Toggles
  const [activeSmas, setActiveSmas]   = useState<Set<SmaPeriod>>(new Set([50, 200]))
  const [showSpy, setShowSpy]         = useState(false)
  const [showGld, setShowGld]         = useState(false)
  const [showRsi, setShowRsi]         = useState(false)
  const [showAtr, setShowAtr]         = useState(false)
  const [showVortex, setShowVortex]   = useState(false)
  const [showPpo, setShowPpo]         = useState(false)

  // â”€â”€ Init main chart â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  useEffect(() => {
    if (!chartContainerRef.current) return

    const c = createChart(chartContainerRef.current, {
      layout: {
        background: { color: 'rgba(10,12,18,0)' },
        textColor: '#6e8aa0',
        fontFamily: 'IBM Plex Mono, monospace',
        fontSize: 11,
      },
      grid: {
        vertLines: { visible: false },
        horzLines: { visible: false },
      },
      crosshair: {
        mode: CrosshairMode.Normal,
        vertLine: { labelVisible: true,  color: '#4d9fff60', width: 1, style: LineStyle.Dashed },
        horzLine: { labelVisible: true,  color: '#4d9fff60', width: 1, style: LineStyle.Dashed },
      },
      rightPriceScale: {
        borderColor: '#1c2b3a',
        textColor:   '#6e8aa0',
        scaleMargins: { top: 0.08, bottom: 0.15 },
      },
      leftPriceScale: {
        visible:     false,
        borderColor: '#1c2b3a',
        textColor:   '#6e8aa0',
      },
      timeScale: {
        borderColor:   '#1c2b3a',
        textColor:     '#6e8aa0',
        timeVisible:   true,
        secondsVisible: false,
        rightOffset:   8,
        barSpacing:    6,
        fixLeftEdge:   false,
        fixRightEdge:  false,
      },
      handleScroll:  true,
      handleScale:   true,
    })

    // Candlestick series
    const cs = c.addSeries(CandlestickSeries, {
      upColor:          '#3bba6c',
      downColor:        '#f04f48',
      borderUpColor:    '#3bba6c',
      borderDownColor:  '#f04f48',
      wickUpColor:      '#3bba6c88',
      wickDownColor:    '#f04f4888',
    })
    chart.current       = c
    candleSeries.current = cs

    // Mouse wheel zoom centered at pointer
    chartContainerRef.current.addEventListener('wheel', (e) => {
      e.preventDefault()
    }, { passive: false })

    // Right-click context menu
    chartContainerRef.current.addEventListener('contextmenu', (e) => {
      e.preventDefault()
      if (!chart.current) return
      const rect    = chartContainerRef.current!.getBoundingClientRect()
      const relX    = e.clientX - rect.left
      const relY    = e.clientY - rect.top
      const time    = chart.current.timeScale().coordinateToTime(relX)
      const price   = candleSeries.current?.coordinateToPrice(relY) ?? 0
      setCtxMenu({ x: e.clientX, y: e.clientY, time: typeof time === 'number' ? time : 0, price: price ?? 0 })
    })

    // ResizeObserver
    const obs = new ResizeObserver(() => {
      if (chartContainerRef.current && chart.current) {
        chart.current.applyOptions({
          width:  chartContainerRef.current.clientWidth,
          height: chartContainerRef.current.clientHeight,
        })
      }
    })
    if (chartContainerRef.current) obs.observe(chartContainerRef.current)

    return () => {
      obs.disconnect()
      c.remove()
      chart.current       = null
      candleSeries.current = null
    }
  }, [])

  // â”€â”€ Load price data â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  const loadChart = useCallback(async (s: string, period: string, frequency: string) => {
    if (!candleSeries.current || !chart.current) return
    setLoading(true); setError(null)
    try {
      const data = await fetchPriceHistory(s, period, frequency)
      setCandles(data.candles)

      // Set candlestick data â€” Lightweight Charts requires time as YYYY-MM-DD string for daily
      const cdData: CandlestickData<Time>[] = data.candles.map(c => ({
        time:  frequency === 'daily' || frequency === 'weekly' || frequency === 'monthly'
          ? new Date(c.time * 1000).toISOString().slice(0, 10) as Time
          : c.time as unknown as Time,
        open:  c.open,
        high:  c.high,
        low:   c.low,
        close: c.close,
      }))
      candleSeries.current!.setData(cdData)
      chart.current!.timeScale().fitContent()
      setSym(s)
    } catch (e: any) {
      setError(e.message)
    } finally {
      setLoading(false)
    }
  }, [])

  // Sync to active symbol from store
  useEffect(() => {
    if (activeSymbol !== sym) {
      setSym(activeSymbol)
      loadChart(activeSymbol, tf, freq)
    }
  }, [activeSymbol])

  // â”€â”€ SMAs â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  useEffect(() => {
    if (!chart.current || !candles.length) return
    const closes = candles.map(c => c.close)
    const times  = candles.map(c =>
      freq === 'daily' || freq === 'weekly' || freq === 'monthly'
        ? new Date(c.time * 1000).toISOString().slice(0, 10) as Time
        : c.time as unknown as Time
    )

    SMA_PERIODS.forEach(period => {
      const existing = smaSeriesMap.current.get(period)
      if (activeSmas.has(period)) {
        const vals = sma(closes, period)
        const lineData: LineData<Time>[] = vals
          .map((v, i) => ({ time: times[i], value: v }))
          .filter(d => d.value != null) as LineData<Time>[]
        if (existing) {
          existing.setData(lineData)
          existing.applyOptions({ visible: true })
        } else {
          const s = chart.current!.addSeries(LineSeries, {
            color:         SMA_COLORS[period],
            lineWidth:     period >= 128 ? 2 : 1,
            priceLineVisible: false,
            lastValueVisible: false,
            crosshairMarkerVisible: false,
          })
          s.setData(lineData)
          smaSeriesMap.current.set(period, s)
        }
      } else if (existing) {
        existing.applyOptions({ visible: false })
      }
    })
  }, [activeSmas, candles, freq])

  // â”€â”€ Mark open positions on chart â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  useEffect(() => {
    if (!candleSeries.current || !positions.length || !candles.length) return
    const symPositions = positions.filter(p => p.underlying === sym)
    if (!symPositions.length) return

    const markers = symPositions.map(p => ({
      time: new Date().toISOString().slice(0, 10) as Time,
      position: (p.display_qty < 0 ? 'aboveBar' : 'belowBar') as any,
      color:  p.display_qty < 0 ? '#f04f48' : '#3bba6c',
      shape:  (p.display_qty < 0 ? 'arrowDown' : 'arrowUp') as any,
      text:   `${p.option_type}${p.strike} ${p.display_qty > 0 ? '+' : ''}${p.display_qty}`,
    }))
    candleSeries.current.setMarkers(markers)
  }, [positions, candles, sym])

  // â”€â”€ Expected move horizontal lines every Friday â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  useEffect(() => {
    if (!candleSeries.current || !candles.length || !quote.atmStraddle || !quote.lastPrice) return
    const move   = quote.atmStraddle * 0.85
    const price  = quote.lastPrice
    const upper  = price + move
    const lower  = price - move

    // Remove old expected move lines
    try {
      ;(candleSeries.current as any).__em_upper?.remove()
      ;(candleSeries.current as any).__em_lower?.remove()
    } catch {}

    const uLine = candleSeries.current.createPriceLine({
      price:          upper,
      color:          '#3bba6c88',
      lineWidth:      1,
      lineStyle:      LineStyle.Dashed,
      axisLabelVisible: true,
      title:          `EM+ ${upper.toFixed(2)}`,
    })
    const lLine = candleSeries.current.createPriceLine({
      price:          lower,
      color:          '#f04f4888',
      lineWidth:      1,
      lineStyle:      LineStyle.Dashed,
      axisLabelVisible: true,
      title:          `EMâˆ’ ${lower.toFixed(2)}`,
    })
    ;(candleSeries.current as any).__em_upper = uLine
    ;(candleSeries.current as any).__em_lower = lLine
  }, [quote.atmStraddle, quote.lastPrice, candles])

  // â”€â”€ Toggle SMA â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  function toggleSma(p: SmaPeriod) {
    setActiveSmas(prev => {
      const next = new Set(prev)
      if (next.has(p)) next.delete(p); else next.add(p)
      return next
    })
  }

  // â”€â”€ Context menu actions â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  function openGoogleNews() {
    if (!ctxMenu) return
    const date = new Date(ctxMenu.time * 1000).toISOString().slice(0, 10)
    const url  = `https://www.google.com/search?q=${encodeURIComponent(sym)}+stock+news&tbs=cdr:1,cd_min:${date},cd_max:${date}&tbm=nws`
    window.open(url, '_blank')
    setCtxMenu(null)
  }

  function addAlertAtPrice() {
    if (!ctxMenu) return
    // Trigger alert modal via store (fire custom event)
    const ev = new CustomEvent('granite:addAlertAtPrice', {
      detail: { sym, price: ctxMenu.price.toFixed(2) }
    })
    window.dispatchEvent(ev)
    setCtxMenu(null)
  }

  function handleTfClick(period: string, frequency: string) {
    setTf(period); setFreq(frequency)
    loadChart(sym, period, frequency)
  }

  // â”€â”€ Current price line â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  useEffect(() => {
    if (!candleSeries.current || !quote.lastPrice) return
    candleSeries.current.applyOptions({
      lastValueVisible: true,
    })
  }, [quote.lastPrice])

  // â”€â”€ Indicator heights (approximate) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const showAnyIndicator = showRsi || showAtr || showVortex || showPpo
  const mainHeight       = showAnyIndicator ? '60%' : '100%'
  const numIndicators    = [showRsi, showAtr, showVortex, showPpo].filter(Boolean).length
  const indHeight        = numIndicators > 0 ? `${40 / numIndicators}%` : '0%'

  // â”€â”€ Price strip above chart â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  const chgColor = (quote.netChange ?? 0) >= 0 ? '#3bba6c' : '#f04f48'
  const move     = quote.atmStraddle ? (quote.atmStraddle * 0.85).toFixed(2) : null

  return (
    <div
      className="tile"
      style={{ height: '100%', display: 'flex', flexDirection: 'column' }}
      onClick={() => ctxMenu && setCtxMenu(null)}
    >
      {/* Header */}
      <div className="tile-hdr" style={{ height: 'auto', flexDirection: 'column', alignItems: 'stretch', padding: '6px 10px', gap: 6 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span className="tile-title">Chart</span>
          {/* Symbol input */}
          <input
            type="text"
            value={sym}
            onChange={e => setSym(e.target.value.toUpperCase())}
            onKeyDown={e => e.key === 'Enter' && loadChart(sym, tf, freq)}
            style={{ width: 70, fontSize: 12, fontWeight: 700, padding: '2px 6px' }}
          />
          <button
            className="btn sm primary"
            onClick={() => loadChart(sym, tf, freq)}
          >LOAD</button>

          {/* Timeframe buttons */}
          <div style={{ display: 'flex', gap: 2, marginLeft: 4 }}>
            {TF_OPTIONS.map(t => (
              <button
                key={t.label}
                className={`btn sm${tf === t.period ? ' active' : ''}`}
                onClick={() => handleTfClick(t.period, t.frequency)}
              >
                {t.label}
              </button>
            ))}
          </div>

          {/* Comparison overlays */}
          <div style={{ display: 'flex', gap: 2, marginLeft: 6, borderLeft: '1px solid var(--border)', paddingLeft: 6 }}>
            <button
              className={`btn sm${showSpy ? ' active' : ''}`}
              style={{ color: showSpy ? 'var(--bg)' : '#4d9fff' }}
              onClick={() => setShowSpy(v => !v)}
            >SPY</button>
            <button
              className={`btn sm${showGld ? ' active' : ''}`}
              style={{ color: showGld ? 'var(--bg)' : '#e5b84c' }}
              onClick={() => setShowGld(v => !v)}
            >GLD</button>
          </div>

          {/* Price display â€” focal point */}
          <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <span style={{ fontSize: 26, fontWeight: 700, color: 'var(--text)', letterSpacing: '-0.02em', lineHeight: 1 }}>
              {quote.lastPrice != null ? '$' + quote.lastPrice.toFixed(2) : '--'}
            </span>
            <span style={{ fontSize: 14, color: chgColor }}>
              {quote.netChange != null
                ? `${quote.netChange >= 0 ? '+' : ''}${quote.netChange.toFixed(2)} (${((quote.netPctChange ?? 0) * 100).toFixed(2)}%)`
                : '--'}
            </span>
            {quote.openPrice && <span style={{ fontSize: 11, color: 'var(--muted)' }}>O {quote.openPrice.toFixed(2)}</span>}
            {quote.highPrice && <span style={{ fontSize: 11, color: '#3bba6c' }}>H {quote.highPrice.toFixed(2)}</span>}
            {quote.lowPrice  && <span style={{ fontSize: 11, color: '#f04f48' }}>L {quote.lowPrice.toFixed(2)}</span>}
            {move && <span style={{ fontSize: 11, color: 'var(--muted)' }}>EM Â±${move}</span>}
          </div>
        </div>

        {/* SMA toggles */}
        <div style={{ display: 'flex', gap: 3, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ fontSize: 9, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginRight: 2 }}>SMA</span>
          {SMA_PERIODS.map(p => (
            <button
              key={p}
              className="btn sm"
              style={{
                borderColor: activeSmas.has(p) ? SMA_COLORS[p] : undefined,
                color:       activeSmas.has(p) ? SMA_COLORS[p] : 'var(--muted)',
                background:  activeSmas.has(p) ? SMA_COLORS[p] + '20' : undefined,
                fontSize: 10, padding: '1px 6px',
              }}
              onClick={() => toggleSma(p)}
            >{p}</button>
          ))}

          <div style={{ width: 1, height: 16, background: 'var(--border)', margin: '0 4px' }} />

          {/* Indicator toggles */}
          <span style={{ fontSize: 9, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginRight: 2 }}>IND</span>
          {[
            { key: 'rsi',    label: 'RSI 15',  val: showRsi,    set: setShowRsi    },
            { key: 'atr',    label: 'ATR 5',   val: showAtr,    set: setShowAtr    },
            { key: 'vortex', label: 'VTX 14',  val: showVortex, set: setShowVortex },
            { key: 'ppo',    label: 'PPO',     val: showPpo,    set: setShowPpo    },
          ].map(ind => (
            <button
              key={ind.key}
              className={`btn sm${ind.val ? ' active' : ''}`}
              style={{ fontSize: 10, padding: '1px 6px' }}
              onClick={() => ind.set((v: boolean) => !v)}
            >{ind.label}</button>
          ))}
        </div>
      </div>

      {loading && <div className="loading">Loading {sym} chart data...</div>}
      {error   && <div className="error-msg">{error}</div>}

      {/* Main chart area */}
      <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
        <div
          ref={chartContainerRef}
          style={{ width: '100%', height: showAnyIndicator ? '62%' : '100%', minHeight: 0 }}
        />

        {/* Indicator sub-panels */}
        {showAnyIndicator && candles.length > 0 && (
          <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', borderTop: '1px solid var(--border)' }}>
            {showRsi    && <RsiPanel    candles={candles} freq={freq} height={indHeight} />}
            {showAtr    && <AtrPanel    candles={candles} freq={freq} height={indHeight} />}
            {showVortex && <VortexPanel candles={candles} freq={freq} height={indHeight} />}
            {showPpo    && <PpoPanel    candles={candles} freq={freq} height={indHeight} />}
          </div>
        )}
      </div>

      {/* Right-click context menu */}
      {ctxMenu && (
        <div
          style={{
            position: 'fixed', left: ctxMenu.x, top: ctxMenu.y, zIndex: 9999,
            background: 'var(--bg2)', border: '1px solid var(--bord2)',
            borderRadius: 5, padding: '4px 0', minWidth: 200,
            boxShadow: '0 8px 32px rgba(0,0,0,0.6)',
          }}
          onClick={e => e.stopPropagation()}
        >
          <div style={{ padding: '3px 12px 6px', fontSize: 10, color: 'var(--muted)', borderBottom: '1px solid var(--border)' }}>
            {sym} â€” {new Date((ctxMenu.time || 0) * 1000).toLocaleDateString()} @ ${ctxMenu.price.toFixed(2)}
          </div>
          <CtxItem icon="ðŸ“°" label="Google News for this date" onClick={openGoogleNews} />
          <CtxItem icon="ðŸ””" label={`Add alert at $${ctxMenu.price.toFixed(2)}`} onClick={addAlertAtPrice} />
          <CtxItem icon="ðŸ“Š" label="Load vol surface" onClick={() => { window.dispatchEvent(new CustomEvent('granite:loadVolSurface', { detail: { sym } })); setCtxMenu(null) }} />
          <CtxItem icon="âœ•"  label="Close" onClick={() => setCtxMenu(null)} color="var(--muted)" />
        </div>
      )}
    </div>
  )
}

function CtxItem({ icon, label, onClick, color }: { icon: string; label: string; onClick: () => void; color?: string }) {
  return (
    <div
      onClick={onClick}
      style={{
        padding: '6px 12px', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 8,
        fontSize: 12, color: color || 'var(--text)', transition: 'background 0.1s',
      }}
      onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg3)')}
      onMouseLeave={e => (e.currentTarget.style.background = '')}
    >
      <span style={{ fontSize: 14 }}>{icon}</span>{label}
    </div>
  )
}

// â”€â”€ Indicator sub-panel components â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

function MiniChart({
  data, color, height, title, min, max, refLines,
}: {
  data: { time: string | number; value: number | null }[]
  color: string
  height: string
  title: string
  min?: number
  max?: number
  refLines?: { value: number; color: string }[]
}) {
  const ref = useRef<HTMLDivElement>(null)
  const chartRef = useRef<IChartApi | null>(null)

  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 10, fontFamily: 'IBM Plex Mono, monospace' },
      grid:   { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0', scaleMargins: { top: 0.05, bottom: 0.05 } },
      timeScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0', visible: false },
      width:  ref.current.clientWidth,
      height: ref.current.clientHeight,
    })
    const s = c.addSeries(LineSeries, { color, lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    s.setData(data.filter(d => d.value != null) as any)
    refLines?.forEach(rl => s.createPriceLine({ price: rl.value, color: rl.color, lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: false, title: '' }))
    chartRef.current = c

    const obs = new ResizeObserver(() => {
      if (ref.current && chartRef.current) {
        chartRef.current.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight })
      }
    })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [data])

  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>
        {title}
      </div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

function toTime(c: Candle, freq: string): string {
  return freq === 'daily' || freq === 'weekly' || freq === 'monthly'
    ? new Date(c.time * 1000).toISOString().slice(0, 10)
    : String(c.time)
}

function RsiPanel({ candles, freq, height }: { candles: Candle[]; freq: string; height: string }) {
  const vals  = rsi(candles.map(c => c.close), 15)
  const data  = candles.map((c, i) => ({ time: toTime(c, freq), value: vals[i] }))
  return <MiniChart data={data} color="#9868f8" height={height} title="RSI (15)" refLines={[{ value: 70, color: '#f04f4888' }, { value: 30, color: '#3bba6c88' }]} />
}

function AtrPanel({ candles, freq, height }: { candles: Candle[]; freq: string; height: string }) {
  const vals  = atr(candles, 5)
  const data  = candles.map((c, i) => ({ time: toTime(c, freq), value: vals[i] }))
  return <MiniChart data={data} color="#d4972a" height={height} title="ATR (5)" />
}

function VortexPanel({ candles, freq, height }: { candles: Candle[]; freq: string; height: string }) {
  const { vip, vim } = vortex(candles, 14)
  // Render as two mini lines â€” we'll use a custom two-line chart
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
    const s1 = c.addSeries(LineSeries, { color: '#3bba6c', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const s2 = c.addSeries(LineSeries, { color: '#f04f48', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    s1.setData(candles.map((cc, i) => ({ time: toTime(cc, freq), value: vip[i] })).filter(d => d.value != null) as any)
    s2.setData(candles.map((cc, i) => ({ time: toTime(cc, freq), value: vim[i] })).filter(d => d.value != null) as any)
    const obs = new ResizeObserver(() => { if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight }) })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [candles])
  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>
        Vortex (14) <span style={{ color: '#3bba6c' }}>VI+</span> / <span style={{ color: '#f04f48' }}>VIâˆ’</span>
      </div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

function PpoPanel({ candles, freq, height }: { candles: Candle[]; freq: string; height: string }) {
  const closes = candles.map(c => c.close)
  const { ppo: ppoLine, sig, hist } = ppo(closes, 12, 48, 200)
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
    const sh = c.addSeries(HistogramSeries, { color: '#4d9fff40', priceLineVisible: false, lastValueVisible: false })
    const sp = c.addSeries(LineSeries, { color: '#4d9fff', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const ss = c.addSeries(LineSeries, { color: '#f04f48', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const toD = (v: number | null, i: number) => ({ time: toTime(candles[i], freq), value: v })
    sh.setData(hist.map(toD).filter(d => d.value != null) as any)
    sp.setData(ppoLine.map(toD).filter(d => d.value != null) as any)
    ss.setData(sig.map(toD).filter(d => d.value != null) as any)
    const obs = new ResizeObserver(() => { if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight }) })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [candles])
  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>
        PPO (12,48,200)
      </div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}
