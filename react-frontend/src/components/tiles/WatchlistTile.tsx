import { useState, useMemo, useRef } from 'react'
import { useStore } from '../../store/useStore'
import type { WatchlistRow } from '../../types'
import { WL_DATA } from '../../data/watchlist'

// â”€â”€ Multi-watchlist storage â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
interface SavedWatchlist {
  id: string
  name: string
  rows: WatchlistRow[]
  created: number
}

function loadSavedLists(): SavedWatchlist[] {
  try {
    return JSON.parse(localStorage.getItem('granite_watchlists') || '[]')
  } catch { return [] }
}

function saveLists(lists: SavedWatchlist[]) {
  localStorage.setItem('granite_watchlists', JSON.stringify(lists))
}

// â”€â”€ IV Term Structure Heatmap â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
// Converts 5 IV values (spot, 5d, 1m, 3m, 6m) into a heat color
// "Rising term structure" = low IV now, high IV further out = ideal entry
// Each cell colored relative to the row's own range (min=coolest, max=hottest)
function ivHeatColor(val: number, min: number, max: number, rising: boolean): string {
  if (max === min) return 'rgba(100,140,200,0.25)'
  const t = (val - min) / (max - min)   // 0 = lowest IV, 1 = highest IV
  // Rising term structure: we WANT low near-term, high far-term
  // near-term low = cool (blue), far-term high = hot (orange-red)
  const r = Math.round(20  + t * 220)
  const g = Math.round(100 - t * 60)
  const b = Math.round(200 - t * 160)
  return `rgba(${r},${g},${b},0.55)`
}

function parseIvPct(s: string): number {
  if (!s) return 0
  return parseFloat(s.replace('%', '')) || 0
}

function IvHeatRow({ iv, iv5d, iv1m, iv3m, iv6m }: {
  iv: string; iv5d: string; iv1m: string; iv3m: string; iv6m: string
}) {
  const vals = [parseIvPct(iv), parseIvPct(iv5d), parseIvPct(iv1m), parseIvPct(iv3m), parseIvPct(iv6m)]
  const filtered = vals.filter(v => v > 0)
  const min = filtered.length ? Math.min(...filtered) : 0
  const max = filtered.length ? Math.max(...filtered) : 1

  // Detect if term structure is rising (6M IV > spot IV = ideal)
  const rising = parseIvPct(iv6m) > parseIvPct(iv)

  const labels = ['Spot', '5D', '1M', '3M', '6M']

  return (
    <>
      {vals.map((v, i) => (
        <span
          key={labels[i]}
          className="wl-cell"
          style={{
            background: v > 0 ? ivHeatColor(v, min, max, rising) : 'transparent',
            borderRadius: 2,
            fontWeight: rising && i >= 3 ? 600 : 400,
            color: v > 0 ? 'var(--text)' : 'var(--muted)',
            fontSize: 10,
            padding: '0 2px',
          }}
          title={`${labels[i]} IV: ${v.toFixed(2)}%${rising ? ' (rising term âœ“)' : ''}`}
        >
          {v > 0 ? v.toFixed(2) + '%' : '--'}
        </span>
      ))}
    </>
  )
}

// â”€â”€ Expected weekly move from ImpVol â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function calcExpMove(priceStr: string, ivStr: string) {
  const price = parseFloat(priceStr) || 0
  const iv = parseFloat((ivStr || '').replace('%', '')) / 100 || 0
  if (!price || !iv) return null
  const move = price * iv * Math.sqrt(7 / 365)
  return { move, upper: price + move, lower: price - move }
}

// â”€â”€ Range bar component â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
function ExpMoveBar({ price, move }: { price: number; move: number }) {
  const range = move * 2 * 1.5  // show 1.5x the move as total range
  const start = price - move * 1.5
  const pct   = (price - start) / range * 100
  const barW  = (move * 2) / range * 100
  const barL  = ((price - move) - start) / range * 100

  return (
    <div className="em-bar-wrap" title={`Weekly EM: Â±$${move.toFixed(2)}`}>
      <div className="em-bar">
        <div className="em-bar-inner" style={{ left: `${barL}%`, width: `${barW}%` }} />
        <div className="em-bar-price" style={{ left: `${pct}%` }} />
      </div>
    </div>
  )
}

interface Props {
  onSymbolLoad:  (sym: string) => void
  onAlertOpen:   (sym: string) => void
  onScanSymbol:  (sym: string) => void
}

export function WatchlistTile({ onSymbolLoad, onAlertOpen, onScanSymbol }: Props) {
  const { activeSymbol, livePrices } = useStore()
  const [filter, setFilter]       = useState('')
  const [expanded, setExpanded]   = useState(false)

  // Multi-watchlist state
  const [savedLists, setSavedLists]       = useState<SavedWatchlist[]>(loadSavedLists)
  const [activeListId, setActiveListId]   = useState<string>('__default__')
  const [newListName, setNewListName]     = useState('')
  const [showListMgr, setShowListMgr]     = useState(false)
  const fileInputRef = useRef<HTMLInputElement>(null)

  const activeRows: WatchlistRow[] = useMemo(() => {
    if (activeListId === '__default__') return WL_DATA as WatchlistRow[]
    const found = savedLists.find(l => l.id === activeListId)
    return found ? found.rows : WL_DATA as WatchlistRow[]
  }, [activeListId, savedLists])

  const displayed = useMemo(() => {
    const f = filter.toUpperCase()
    return f ? activeRows.filter(r => r.sym.includes(f)) : activeRows
  }, [activeRows, filter])

  // â”€â”€ Watchlist management â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  function saveCurrentAsNew() {
    if (!newListName.trim()) return
    const next: SavedWatchlist = {
      id: Date.now().toString(),
      name: newListName.trim(),
      rows: activeRows,
      created: Date.now(),
    }
    const updated = [...savedLists, next]
    setSavedLists(updated)
    saveLists(updated)
    setNewListName('')
    setActiveListId(next.id)
  }

  function deleteList(id: string) {
    const updated = savedLists.filter(l => l.id !== id)
    setSavedLists(updated)
    saveLists(updated)
    if (activeListId === id) setActiveListId('__default__')
  }

  function importCSV(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    const reader = new FileReader()
    reader.onload = (ev) => {
      const text = ev.target?.result as string
      const lines = text.split('\n').filter(Boolean)
      const headers = lines[0].split(',').map(h => h.trim().replace(/^"|"$/g, ''))
      const symIdx = headers.findIndex(h => h.toLowerCase() === 'symbol')
      if (symIdx < 0) return
      const rows: WatchlistRow[] = lines.slice(1).map(line => {
        const cells = line.split(',').map(c => c.trim().replace(/^"|"$/g, ''))
        const sym = cells[symIdx] || ''
        if (!sym || sym.startsWith('Downloaded')) return null
        return {
          sym,
          price:   cells[headers.indexOf('Latest')] || '',
          chg:     cells[headers.indexOf('%Change')] || '',
          rs14:    cells[headers.indexOf('14D Rel Str')] || '',
          ivpct:   cells[headers.indexOf('IV Pctl')] || '',
          ivhv:    cells[headers.indexOf('IV/HV')] || '',
          iv:      cells[headers.indexOf('Imp Vol')] || '',
          iv5d:    cells[headers.indexOf('5D IV')] || '',
          iv1m:    cells[headers.indexOf('1M IV')] || '',
          iv3m:    cells[headers.indexOf('3M IV')] || '',
          iv6m:    cells[headers.indexOf('6M IV')] || '',
          bb:      cells[headers.indexOf('BB%')] || '',
          bbr:     cells[headers.indexOf('BB Rank')] || '',
          ttm:     cells[headers.indexOf('TTM Squeeze')] || '',
          adr14:   cells[headers.indexOf('14D ADR')] || '',
          opvol:   cells[headers.indexOf('Options Vol')] || '',
          callvol: cells[headers.indexOf('Call Volume')] || '',
          putvol:  cells[headers.indexOf('Put Volume')] || '',
        } as WatchlistRow
      }).filter(Boolean) as WatchlistRow[]

      const newList: SavedWatchlist = {
        id: Date.now().toString(),
        name: file.name.replace('.csv', ''),
        rows,
        created: Date.now(),
      }
      const updated = [...savedLists, newList]
      setSavedLists(updated)
      saveLists(updated)
      setActiveListId(newList.id)
    }
    reader.readAsText(file)
    e.target.value = ''
  }

  function shareList() {
    const rows = activeRows.map(r => r.sym).join(',')
    navigator.clipboard.writeText(rows)
    alert('Symbol list copied to clipboard')
  }

  // â”€â”€ Colors â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  function chgColor(chg: string) {
    if (!chg) return ''
    return chg.startsWith('-') ? 'var(--red)' : 'var(--green)'
  }
  function bbColor(bbr: string) {
    const l = (bbr || '').toLowerCase()
    if (l.includes('below lower')) return 'var(--red)'
    if (l.includes('above mid'))   return 'var(--green)'
    return ''
  }

  // â”€â”€ Row action handler â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  function handleRowClick(sym: string, e: React.MouseEvent) {
    // Only full row click loads symbol; action buttons handle their own click
    onSymbolLoad(sym)
  }

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <div className="tile-hdr">
        <span className="tile-title">Watchlist</span>

        {/* List selector */}
        <select
          value={activeListId}
          onChange={e => setActiveListId(e.target.value)}
          style={{ width: 110, fontSize: 10, padding: '1px 4px', marginLeft: 4 }}
          onClick={e => e.stopPropagation()}
        >
          <option value="__default__">Weeklys (229)</option>
          {savedLists.map(l => (
            <option key={l.id} value={l.id}>{l.name} ({l.rows.length})</option>
          ))}
        </select>

        <button
          className="btn sm"
          style={{ fontSize: 9 }}
          onClick={() => setShowListMgr(!showListMgr)}
          title="Manage watchlists"
        >
          &#x2630;
        </button>

        <button
          className="btn sm"
          style={{ fontSize: 9 }}
          onClick={() => setExpanded(!expanded)}
          title={expanded ? 'Collapse' : 'Expand all columns'}
        >
          {expanded ? '\u21D0 COLLAPSE' : '\u21D4 EXPAND'}
        </button>

        <span style={{ fontSize: 9, color: 'var(--muted)', marginLeft: 'auto' }}>
          {displayed.length}
        </span>
      </div>

      {/* Watchlist manager panel */}
      {showListMgr && (
        <div style={{ padding: '8px', background: 'var(--bg2)', borderBottom: '1px solid var(--border)', flexShrink: 0 }}>
          <div style={{ display: 'flex', gap: 4, marginBottom: 6, alignItems: 'center' }}>
            <input
              type="text"
              placeholder="New watchlist name..."
              value={newListName}
              onChange={e => setNewListName(e.target.value)}
              style={{ flex: 1, fontSize: 11 }}
              onKeyDown={e => e.key === 'Enter' && saveCurrentAsNew()}
            />
            <button className="btn sm" onClick={saveCurrentAsNew}>SAVE</button>
            <button className="btn sm" onClick={() => fileInputRef.current?.click()} title="Import CSV from Barchart">IMPORT</button>
            <button className="btn sm" onClick={shareList} title="Copy symbols to clipboard">SHARE</button>
          </div>
          <input ref={fileInputRef} type="file" accept=".csv" style={{ display: 'none' }} onChange={importCSV} />
          {savedLists.length > 0 && (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
              {savedLists.map(l => (
                <div key={l.id} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 10 }}>
                  <span style={{ flex: 1, color: activeListId === l.id ? 'var(--accent)' : 'var(--text)' }}>
                    {l.name} ({l.rows.length} symbols)
                  </span>
                  <button className="btn sm" onClick={() => setActiveListId(l.id)}>LOAD</button>
                  <button className="btn sm" style={{ color: 'var(--red)' }} onClick={() => deleteList(l.id)}>&#x2715;</button>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      <input
        className="wl-filter-input"
        placeholder="Filter symbols..."
        value={filter}
        onChange={e => setFilter(e.target.value)}
      />

      {/* Headers */}
      {expanded ? (
        <div className={`wl-hdr wl-hdr-f`} style={{ display: 'grid' }}>
          <span>SYM</span><span>LAST</span><span>CHG%</span>
          <span>14D RS</span><span>IVpct</span><span>IV/HV</span>
          <span>ImpVol</span><span>5D IV</span><span>1M IV</span>
          <span>3M IV</span><span>6M IV</span><span>BB%</span>
          <span>BB Rank</span><span>TTM</span><span>14DADR</span>
          <span>OptVol</span><span>CallVol</span><span>PutVol</span>
          <span>Wk Upper</span><span>Wk Lower</span><span>Exp Move</span>
          <span>Actions</span>
        </div>
      ) : (
        <div className={`wl-hdr wl-hdr-c`} style={{ display: 'grid' }}>
          <span>SYM</span><span>LAST</span><span>CHG%</span><span>Actions</span>
        </div>
      )}

      {/* Rows â€” fills all remaining height */}
      <div className="tile-body" style={{ overflow: 'hidden auto' }}>
        {displayed.map((r: WatchlistRow) => {
          const live   = livePrices[r.sym]
          const dispPx = live ? live.last.toFixed(2) : r.price
          const dispChg = live
            ? `${live.pct >= 0 ? '+' : ''}${(live.pct * 100).toFixed(2)}%`
            : r.chg
          const isActive = r.sym === activeSymbol
          const ivhvNum  = parseFloat(r.ivhv || '0')
          const em       = calcExpMove(r.price, r.iv1m || r.iv || '0%')

          const actions = (
            <div className="wl-actions" onClick={e => e.stopPropagation()}>
              <button
                className="wl-icon-btn"
                title="Get Quote"
                onClick={() => onSymbolLoad(r.sym)}
              >Q</button>
              <button
                className="wl-icon-btn"
                title="Set Alert"
                onClick={() => onAlertOpen(r.sym)}
              >&#x1F514;</button>
              <button
                className="wl-icon-btn"
                title="Scan Entries"
                onClick={() => onScanSymbol(r.sym)}
              >&#x2B21;</button>
              <button
                className="wl-icon-btn"
                title="Load Chart"
                onClick={() => onSymbolLoad(r.sym)}
              >&#x1F4C8;</button>
            </div>
          )

          if (expanded) {
            return (
              <div
                key={r.sym}
                className={`wl-row wl-row-full${isActive ? ' active' : ''}`}
                onClick={(e) => handleRowClick(r.sym, e)}
              >
                <span className="wl-cell" style={{ color: isActive ? 'var(--accent)' : undefined }}>{r.sym}</span>
                <span className="wl-cell">{dispPx || '--'}</span>
                <span className="wl-cell" style={{ color: chgColor(dispChg) }}>{dispChg || '--'}</span>
                <span className="wl-cell">{parseFloat(r.rs14 || '0').toFixed(2)}</span>
                <span className="wl-cell">{r.ivpct || '--'}</span>
                <span className="wl-cell">{isNaN(ivhvNum) ? '--' : ivhvNum.toFixed(2)}</span>
                <span className="wl-cell">{r.iv || '--'}</span>
                <IvHeatRow iv={r.iv} iv5d={r.iv5d} iv1m={r.iv1m} iv3m={r.iv3m} iv6m={r.iv6m} />
                <span className="wl-cell">{r.bb || '--'}</span>
                <span className="wl-cell" style={{ color: bbColor(r.bbr), fontSize: 9 }}>{r.bbr || '--'}</span>
                <span className="wl-cell" style={{ color: r.ttm === 'On' ? 'var(--warn)' : 'var(--border)' }}>
                  {r.ttm === 'On' ? 'ON' : '--'}
                </span>
                <span className="wl-cell">{r.adr14 || '--'}</span>
                <span className="wl-cell">{r.opvol || '--'}</span>
                <span className="wl-cell">{r.callvol || '--'}</span>
                <span className="wl-cell">{r.putvol || '--'}</span>
                {/* Weekly expected move columns */}
                <span className="wl-cell" style={{ color: 'var(--green)' }}>
                  {em ? `$${em.upper.toFixed(2)}` : '--'}
                </span>
                <span className="wl-cell" style={{ color: 'var(--red)' }}>
                  {em ? `$${em.lower.toFixed(2)}` : '--'}
                </span>
                <span className="wl-cell">
                  {em ? (
                    <ExpMoveBar
                      price={parseFloat(r.price) || 0}
                      move={em.move}
                    />
                  ) : '--'}
                </span>
                <span className="wl-cell">{actions}</span>
              </div>
            )
          }

          return (
            <div
              key={r.sym}
              className={`wl-row wl-row-compact${isActive ? ' active' : ''}`}
              onClick={(e) => handleRowClick(r.sym, e)}
            >
              <span className="wl-cell" style={{ color: isActive ? 'var(--accent)' : undefined }}>{r.sym}</span>
              <span className="wl-cell">{dispPx || '--'}</span>
              <span className="wl-cell" style={{ color: chgColor(dispChg) }}>{dispChg || '--'}</span>
              <span className="wl-cell">{actions}</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}
