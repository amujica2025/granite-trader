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
