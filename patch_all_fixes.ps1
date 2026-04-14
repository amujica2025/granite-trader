param([string]$Root = "C:\\Users\\alexm\\granite_trader")
$ErrorActionPreference = "Stop"

function WF([string]$rel,[string]$txt){
  $p=Join-Path $Root ($rel -replace '/','\\')
  $d=Split-Path $p -Parent
  if(-not(Test-Path $d)){New-Item -ItemType Directory -Force -Path $d|Out-Null}
  [System.IO.File]::WriteAllText($p,$txt,(New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[OK] $rel" -ForegroundColor Cyan
}

Write-Host "Writing backend files..." -ForegroundColor Yellow
$c = @'
"""
chart_adapter.py ? Schwab price history for the chart tile.
Uses enforce_enums=False so we can pass plain strings/ints
instead of enum members (avoids the "expected type Period" error).
"""
from __future__ import annotations

import datetime as dt
import os
from typing import Any, Dict


def _safe_float(v: Any, default: float = 0.0) -> float:
    try:
        return float(v) if v not in (None, "") else default
    except Exception:
        return default


def _get_chart_client():
    """Schwab client with enum enforcement disabled."""
    from schwab.auth import client_from_token_file
    token_path = os.getenv(
        "SCHWAB_TOKEN_PATH",
        "/mnt/c/Users/alexm/granite_trader/backend/schwab_token.json",
    )
    return client_from_token_file(
        token_path=token_path,
        api_key=os.getenv("SCHWAB_CLIENT_ID", "").strip(),
        app_secret=os.getenv("SCHWAB_CLIENT_SECRET", "").strip(),
        enforce_enums=False,   # <-- key fix; allows plain string/int params
    )


# Days per period string
_DAYS: Dict[str, int] = {
    "1d": 1, "5d": 5, "1m": 31, "3m": 92, "6m": 183,
    "1y": 365, "2y": 730, "5y": 1826, "10y": 3652,
}

# (period_type, period, frequency_type, frequency) as plain strings/ints
_PARAMS: Dict[str, tuple] = {
    "1d":  ("day",   1,  "minute",  5),
    "5d":  ("day",   5,  "minute", 15),
    "1m":  ("month", 1,  "daily",   1),
    "3m":  ("month", 3,  "daily",   1),
    "6m":  ("month", 6,  "daily",   1),
    "1y":  ("year",  1,  "daily",   1),
    "2y":  ("year",  2,  "daily",   1),
    "5y":  ("year",  5,  "daily",   1),
    "10y": ("year", 10,  "daily",   1),
    "ytd": ("ytd",   1,  "daily",   1),
}


def get_price_history(
    symbol: str,
    period: str = "5y",
    frequency: str = "daily",
) -> Dict[str, Any]:
    client = _get_chart_client()

    pt, p, ft, f = _PARAMS.get(period, ("year", 5, "daily", 1))

    # With enforce_enums=False we can pass strings and ints directly
    resp = client.get_price_history(
        symbol.upper(),
        period_type=pt,
        period=p,
        frequency_type=ft,
        frequency=f,
        need_extended_hours_data=False,
    )

    data = resp.json() if hasattr(resp, "json") else {}
    raw  = data.get("candles", [])

    candles = sorted([
        {
            "time":   c["datetime"] // 1000,
            "open":   round(_safe_float(c.get("open")),  2),
            "high":   round(_safe_float(c.get("high")),  2),
            "low":    round(_safe_float(c.get("low")),   2),
            "close":  round(_safe_float(c.get("close")), 2),
            "volume": int(_safe_float(c.get("volume"), 0)),
        }
        for c in raw if c.get("datetime")
    ], key=lambda x: x["time"])

    return {
        "symbol":    symbol.upper(),
        "period":    period,
        "frequency": ft,
        "count":     len(candles),
        "candles":   candles,
    }

'@
WF "backend\chart_adapter.py" $c

Write-Host "Writing React files..." -ForegroundColor Yellow
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
        <div className="tpill" style={{ minWidth: 80 }}>
          <span className="lbl">Source</span>
          <span className="val" style={{ fontSize: 11, color: 'var(--green)' }}>
            {quote.activeSource || '--'}
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

$c = @'
import { useEffect, useRef, useState } from 'react'
import Plotly from 'plotly.js-dist-min'
import { useStore } from '../../store/useStore'
import type { VSView } from '../../types'
import { fetchVolSurface } from '../../api/client'

const COLORSCALE = [
  [0.00, '#080e24'],
  [0.15, '#0c3c7a'],
  [0.30, '#156a48'],
  [0.48, '#228a38'],
  [0.60, '#c87800'],
  [0.78, '#c83838'],
  [1.00, '#ff2020'],
]

function richColor(score: number | null) {
  if (score == null) return 'var(--muted)'
  if (score >= 0.03) return 'var(--green)'
  if (score >= 0) return 'var(--warn)'
  return 'var(--red)'
}

export function VolSurfaceTile() {
  const { volData, volLoading, volError, activeSymbol, setVolData, setVolLoading, setVolError } = useStore()
  const plotRef = useRef<HTMLDivElement>(null)
  const [view, setView] = useState<VSView>('3d')
  const [plotted, setPlotted] = useState(false)

  // Auto-load on mount and when activeSymbol changes
  useEffect(() => {
    const s = activeSymbol || 'SPY'
    load(s)
  }, [activeSymbol])

  async function load(sym?: string) {
    const s = sym ?? activeSymbol
    setVolLoading(true)
    setVolError(null)
    try {
      const d = await fetchVolSurface(s, 7, 25)
      setVolData(d)
    } catch (e: any) {
      setVolError(e.message)
    } finally {
      setVolLoading(false)
    }
  }

  // Render Plotly chart whenever data or view changes
  useEffect(() => {
    if (!plotRef.current || !volData || !volData.expirations.length) return
    renderPlot()
  }, [volData, view])

  // Also re-render on container resize
  useEffect(() => {
    const obs = new ResizeObserver(() => {
      if (plotRef.current && plotted) {
        Plotly.Plots.resize(plotRef.current)
      }
    })
    if (plotRef.current) obs.observe(plotRef.current)
    return () => obs.disconnect()
  }, [plotted])

  function renderPlot() {
    if (!plotRef.current || !volData) return
    const { expirations, strikes } = volData

    // FIX: Sort strikes ascending so lowest is left-front in 3D
    const sortedStrikes = [...strikes].sort((a, b) => a - b)
    const strikeIndexMap = new Map(strikes.map((s, i) => [s, i]))

    function getMatrix(mat: (number | null)[][]) {
      // Reorder columns to match sortedStrikes
      return mat.map((row) =>
        sortedStrikes.map((s) => {
          const idx = strikeIndexMap.get(s)
          const v = idx != null ? row[idx] : null
          return v != null ? v * 100 : null
        })
      )
    }

    let raw: (number | null)[][]
    if (view === 'call') raw = volData.call_iv_matrix ?? volData.avg_iv_matrix
    else if (view === 'put') raw = volData.put_iv_matrix ?? volData.avg_iv_matrix
    else if (view === 'skew') raw = volData.skew_matrix ?? volData.avg_iv_matrix
    else raw = volData.avg_iv_matrix ?? volData.iv_matrix

    const z = getMatrix(raw)
    const flat = z.flat().filter((v): v is number => v != null)
    if (!flat.length) return

    const el = plotRef.current
    const W = el.clientWidth
    const H = el.clientHeight

    const paperBg = 'rgba(0,0,0,0)'
    const plotBg  = 'rgba(10,18,30,0.9)'
    const font    = { family: 'IBM Plex Mono, monospace', color: '#6e8aa0', size: 10 }
    const gridColor = '#1c2b3a'

    if (view === '3d') {
      const trace: any = {
        type: 'surface',
        x: sortedStrikes,
        y: expirations,
        z,
        colorscale: COLORSCALE,
        showscale: true,
        opacity: 0.94,
        contours: {
          z: { show: true, usecolormap: true, highlightcolor: '#4d9fff', project: { z: true } },
        } as any,
        colorbar: {
          thickness: 12,
          len: 0.85,
          xpad: 4,
          tickfont: { color: '#6e8aa0', size: 9 },
          title: { text: 'IV %', font: { size: 9, color: '#6e8aa0' } },
          // Overlay inside the plot
          x: 1.0,
        } as any,
        hovertemplate: 'Strike: %{x}<br>Exp: %{y}<br>IV: %{z:.2f}%<extra></extra>',
      }

      const layout: any = {
        paper_bgcolor: paperBg,
        font,
        margin: { l: 0, r: 60, t: 10, b: 0 },
        width: W,
        height: H,
        scene: {
          xaxis: {
            title: { text: 'Strike', font: { size: 10 } },
            gridcolor: gridColor,
            zerolinecolor: gridColor,
            tickfont: { size: 9 },
            // Lowest strike on left front: autorange handles this with sorted array
            autorange: true,
          },
          yaxis: {
            title: { text: '', font: { size: 10 } },
            gridcolor: gridColor,
            tickfont: { size: 9 },
            autorange: true,
          },
          zaxis: {
            title: { text: 'IV %', font: { size: 10 } },
            gridcolor: gridColor,
            tickfont: { size: 9 },
          },
          bgcolor: 'rgba(7,9,14,0.85)',
          camera: {
            eye: { x: -1.5, y: -1.8, z: 1.0 },
          },
        } as any,
      }
      Plotly.react(el, [trace], layout, { responsive: false, displayModeBar: false })
    } else {
      const title = view === 'skew' ? 'Put - Call Skew (%)' : 'IV (%)'
      const trace: any = {
        type: 'heatmap',
        x: sortedStrikes,
        y: expirations,
        z,
        colorscale: COLORSCALE,
        showscale: true,
        zsmooth: 'best',
        colorbar: {
          thickness: 12,
          len: 0.92,
          xpad: 4,
          tickfont: { color: '#6e8aa0', size: 9 },
          title: { text: title, font: { size: 9, color: '#6e8aa0' } },
          x: 1.0,
        } as any,
        hovertemplate: 'Strike: %{x}<br>Exp: %{y}<br>Value: %{z:.2f}%<extra></extra>',
      }
      const layout: any = {
        paper_bgcolor: paperBg,
        plot_bgcolor: plotBg,
        font,
        margin: { l: 90, r: 55, t: 10, b: 60 },
        width: W,
        height: H,
        xaxis: { title: { text: 'Strike' }, gridcolor: gridColor, tickfont: { size: 9 }, color: '#6e8aa0' },
        yaxis: { gridcolor: gridColor, tickfont: { size: 9 }, color: '#6e8aa0', autorange: 'reversed' },
      }
      Plotly.react(el, [trace], layout, { responsive: false, displayModeBar: false })
    }
    setPlotted(true)
  }

  const richness = volData?.richness_scores ?? {}
  const sortedExps = volData ? [...volData.expirations].sort((a, b) => (richness[b]?.richness_score ?? 0) - (richness[a]?.richness_score ?? 0)) : []

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div className="tile-hdr">
        <span className="tile-title">Vol Surface</span>
        <div className="vs-tabs" style={{ padding: 0, border: 'none', background: 'transparent', marginLeft: 8, gap: 3, display: 'flex' }}>
          {(['avg','call','put','skew','3d'] as VSView[]).map((v) => (
            <button key={v} className={`btn sm${view === v ? ' active' : ''}`} onClick={() => setView(v)}>
              {v === '3d' ? '3D' : v.charAt(0).toUpperCase() + v.slice(1)}
            </button>
          ))}
        </div>
        <button className="btn sm" style={{ marginLeft: 'auto' }} onClick={() => load()}>&#x21BA; LOAD</button>
      </div>

      {/* Richness expiration cards */}
      <div className="richness-row">
        {volLoading && <span className="muted" style={{ fontSize: 10, alignSelf: 'center' }}>Loading surface...</span>}
        {volError && <span className="error-msg" style={{ fontSize: 10 }}>{volError}</span>}
        {!volLoading && !volError && sortedExps.length === 0 && (
          <span style={{ fontSize: 10, color: 'var(--muted)', alignSelf: 'center' }}>Click LOAD to populate vol surface</span>
        )}
        {sortedExps.map((e) => {
          const r = richness[e] ?? {}
          const iv = r.avg_iv != null ? (r.avg_iv * 100).toFixed(1) + '%' : '--'
          const sc = r.richness_score != null ? Number(r.richness_score).toFixed(4) : '--'
          const skew = r.put_call_skew_near_spot
          return (
            <div key={e} className="rcard">
              <div className="rc-date">{e}</div>
              <div className="rc-iv">{iv}</div>
              <div className="rc-score" style={{ color: richColor(r.richness_score ?? null) }}>Score {sc}</div>
              {skew != null && (
                <div className="rc-skew">Skew {skew >= 0 ? '+' : ''}{(skew * 100).toFixed(2)}%</div>
              )}
            </div>
          )
        })}
      </div>

      {/* Plotly container ? fills all remaining space */}
      <div ref={plotRef} style={{ flex: 1, minHeight: 0, width: '100%' }} />
    </div>
  )
}

'@
WF "react-frontend\src\components\tiles\VolSurfaceTile.tsx" $c

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
  const { activeSymbol, quote, positions } = useStore()

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
  const [tf,         setTf]         = useState('5y')
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
      loadChart(sym, tf, freq)
    }
  }, [chartReady])

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
import { create } from 'zustand'
import type { AlertRule, LimitSummary, Position, ScanResult, Theme, VolSurfaceData, WatchlistRow } from '../types'

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
  atmStraddle: number | null   // ATM call + put mid ? for expected move lines
  activeSource: string
}

interface AppState {
  // Account
  acctSource: 'mock' | 'tasty'
  positions: Position[]
  limitSummary: LimitSummary | null
  positionsLoading: boolean
  positionsError: string | null

  // Quote / symbol
  activeSymbol: string
  quote: QuoteState

  // Scanner
  scanResults: ScanResult[]
  scanLoading: boolean
  scanError: string | null
  scanExpOptions: string[]

  // Vol surface
  volData: VolSurfaceData | null
  volLoading: boolean
  volError: string | null

  // Selection
  selectedIds: Set<string>

  // Alerts
  alertRules: AlertRule[]
  alertsMaster: boolean
  desktopAllowed: boolean

  // Theme
  theme: Theme

  // Refresh
  refreshInterval: number  // seconds
  refreshCountdown: number

  // Watchlist live prices (keyed by symbol)
  livePrices: Record<string, { last: number; pct: number }>
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

  setLivePrice: (sym: string, last: number, pct: number) => void
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
  // State
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

  // Actions
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
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return { selectedIds: next }
    }),
  clearSelected: () => set({ selectedIds: new Set() }),

  addAlertRule: (rule) =>
    set((s) => ({
      alertRules: [...s.alertRules, { ...rule, id: Date.now(), triggered: false }],
    })),
  toggleAlertRule: (id, active) =>
    set((s) => ({ alertRules: s.alertRules.map((r) => (r.id === id ? { ...r, active } : r)) })),
  deleteAlertRule: (id) =>
    set((s) => ({ alertRules: s.alertRules.filter((r) => r.id !== id) })),
  markAlertTriggered: (id) =>
    set((s) => ({ alertRules: s.alertRules.map((r) => (r.id === id ? { ...r, triggered: true } : r)) })),
  setAlertsMaster: (v) => set({ alertsMaster: v }),
  setDesktopAllowed: (v) => set({ desktopAllowed: v }),

  setTheme: (t) => {
    document.documentElement.setAttribute('data-theme', t)
    set({ theme: t })
  },
  setRefreshInterval: (secs) => set({ refreshInterval: secs, refreshCountdown: secs }),
  tickCountdown: () =>
    set((s) => ({ refreshCountdown: Math.max(0, s.refreshCountdown - 1) })),
  resetCountdown: () => set((s) => ({ refreshCountdown: s.refreshInterval })),

  setLivePrice: (sym, last, pct) =>
    set((s) => ({ livePrices: { ...s.livePrices, [sym]: { last, pct } } })),
}))

'@
WF "react-frontend\src\store\useStore.ts" $c

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
html, body, #root { height: 100%; overflow: hidden; background: var(--bg); color: var(--text); font-family: 'IBM Plex Mono', 'Courier New', monospace; font-size: 14px; line-height: 1.5; -webkit-font-smoothing: antialiased; }
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

Write-Host "Building React..." -ForegroundColor Yellow
$wslRoot = ($Root -replace 'C:\\\\', '/mnt/c/') -replace '\\\\', '/'
wsl.exe bash -lc "cd '$wslRoot/react-frontend' && npm run build 2>&1 | tail -20"
if ($LASTEXITCODE -eq 0) {
    Write-Host "[Granite] Build OK" -ForegroundColor Green
    Write-Host "Restart app: wsl bash -lc 'cd /mnt/c/Users/alexm/granite_trader && ./install_and_run_wsl.sh'" -ForegroundColor Yellow
} else {
    Write-Host "Build errors above" -ForegroundColor Red
}
