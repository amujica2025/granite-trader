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
