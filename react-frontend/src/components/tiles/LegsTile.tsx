import { useStore } from '../../store/useStore'

const f$ = (v: number) => '$' + v.toFixed(2)

export function SelectedLegsTile() {
  const { positions, selectedIds } = useStore()
  const sel = positions.filter((p) => selectedIds.has(p.id))
  const sv  = sel.reduce((a, r) => a + r.short_value, 0)
  const lc  = sel.reduce((a, r) => a + r.long_cost, 0)
  const pnl = sel.reduce((a, r) => a + r.pnl_open, 0)
  const imp = sel.reduce((a, r) => a + r.limit_impact, 0)

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div className="tile-hdr"><span className="tile-title">Selected Legs</span></div>
      <div className="tile-body" style={{ flexDirection: 'row' }}>
        <div style={{ flex: 1, overflowY: 'auto' }}>
          <table className="data-table">
            <thead><tr>
              <th>Sym</th><th>Type</th><th>Qty</th><th>Strike</th><th>Exp</th><th>Mark</th><th>P/L</th><th>ShtVal</th>
            </tr></thead>
            <tbody>
              {sel.length === 0 ? (
                <tr><td colSpan={8} className="empty-msg">Select rows in Open Positions</td></tr>
              ) : sel.map((r) => (
                <tr key={r.id}>
                  <td><b>{r.underlying}</b></td>
                  <td style={{ color: r.option_type === 'C' ? 'var(--accent)' : 'var(--red)' }}>{r.option_type === 'C' ? 'CALL' : 'PUT'}</td>
                  <td style={{ color: r.display_qty < 0 ? 'var(--red)' : 'var(--green)' }}>{r.display_qty}</td>
                  <td>{r.strike}</td>
                  <td style={{ color: 'var(--muted)' }}>{r.expiration}</td>
                  <td>{f$(r.mark)}</td>
                  <td style={{ color: r.pnl_open >= 0 ? 'var(--green)' : 'var(--red)' }}>{f$(r.pnl_open)}</td>
                  <td>{f$(r.short_value)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div style={{ width: 200, padding: 10, borderLeft: '1px solid var(--border)', flexShrink: 0 }}>
          <div style={{ fontSize: 9, color: 'var(--muted)', textTransform: 'uppercase', marginBottom: 8 }}>Totals</div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 4 }}>
            <div className="tchip"><span className="tl">Legs</span><span className="tv">{sel.length}</span></div>
            <div className="tchip"><span className="tl">P/L</span><span className="tv" style={{ color: pnl >= 0 ? 'var(--green)' : 'var(--red)' }}>{f$(pnl)}</span></div>
            <div className="tchip"><span className="tl">Sht Val</span><span className="tv">{f$(sv)}</span></div>
            <div className="tchip"><span className="tl">Lng Cost</span><span className="tv">{f$(lc)}</span></div>
            <div className="tchip" style={{ gridColumn: 'span 2' }}><span className="tl">Impact</span><span className="tv text-warn">{f$(imp)}</span></div>
          </div>
        </div>
      </div>
    </div>
  )
}

// â”€â”€ Trade Ticket â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

const STRATEGIES = [
  { id: 'credit_spread', label: 'Credit Spread' },
  { id: 'iron_condor',   label: 'Iron Condor'   },
  { id: 'butterfly',     label: 'Butterfly'      },
  { id: 'iron_fly',      label: 'Iron Fly'       },
  { id: 'strangle',      label: 'Strangle'       },
  { id: 'straddle',      label: 'Straddle'       },
]

import { useState } from 'react'
import { useStore as useStoreGlobal } from '../../store/useStore'

export function TradeTicketTile() {
  const { activeSymbol } = useStoreGlobal()
  const [strat, setStrat] = useState('credit_spread')
  const [sym, setSym]     = useState(activeSymbol)
  const [qty, setQty]     = useState(1)
  const [action, setAction] = useState('Sell to Open')
  const [msg, setMsg]     = useState('Select a strategy above')

  function submit() {
    setMsg(`\u26A0 Tastytrade order routing arrives in v0.6 \u2014 ${strat.replace(/_/g,' ').toUpperCase()} | ${sym} \u00D7${qty} | ${action}`)
  }

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div className="tile-hdr"><span className="tile-title">Quick Trade Ticket &rarr; Tastytrade</span></div>
      <div className="tile-body">
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 4, padding: 8, flexShrink: 0 }}>
          {STRATEGIES.map((s) => (
            <button
              key={s.id}
              className={`btn${strat === s.id ? ' active' : ''}`}
              style={{ fontSize: 11, padding: '5px 8px' }}
              onClick={() => { setStrat(s.id); setMsg('Strategy: ' + s.label) }}
            >
              {s.label}
            </button>
          ))}
        </div>
        <div style={{ padding: '0 8px 8px', borderTop: '1px solid var(--border)' }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 6, margin: '8px 0' }}>
            <div><label>Symbol</label><input type="text" value={sym} onChange={(e) => setSym(e.target.value.toUpperCase())} /></div>
            <div><label>Qty</label><input type="number" value={qty} onChange={(e) => setQty(Number(e.target.value))} min={1} /></div>
            <div><label>Action</label>
              <select value={action} onChange={(e) => setAction(e.target.value)}>
                <option>Sell to Open</option>
                <option>Buy to Open</option>
                <option>Buy to Close</option>
                <option>Sell to Close</option>
              </select>
            </div>
          </div>
          <button className="btn primary" style={{ width: '100%' }} onClick={submit}>SEND TO TASTYTRADE &rarr;</button>
          <div style={{ fontSize: 10, marginTop: 6, color: 'var(--muted)' }}>{msg}</div>
        </div>
      </div>
    </div>
  )
}
