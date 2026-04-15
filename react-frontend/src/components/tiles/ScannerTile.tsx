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
