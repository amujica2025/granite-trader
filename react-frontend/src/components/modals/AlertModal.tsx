import { useRef, useEffect } from 'react'
import { useStore } from '../../store/useStore'
import { sendPushover } from '../../api/client'

const FIELD_LABELS: Record<string, string> = {
  price:            'Price',
  iv_pct:           'IV%',
  credit_pct_risk:  'Cr% Risk',
  short_delta:      'Short Delta',
  used_pct:         'Used%',
  pnl_open:         'P/L Open',
}
const OP_LABELS: Record<string, string> = {
  lt: '<', lte: '<=', eq: '=', gte: '>=', gt: '>',
}

interface Props {
  onClose: () => void
  prefilledSym?: string
}

export function AlertModal({ onClose, prefilledSym }: Props) {
  const { alertRules, alertsMaster, setAlertsMaster, addAlertRule, toggleAlertRule, deleteAlertRule } = useStore()
  const symRef   = useRef<HTMLInputElement>(null)
  const fieldRef = useRef<HTMLSelectElement>(null)
  const opRef    = useRef<HTMLSelectElement>(null)
  const valRef   = useRef<HTMLInputElement>(null)

  useEffect(() => {
    if (prefilledSym && symRef.current) {
      symRef.current.value = prefilledSym
    }
  }, [prefilledSym])

  function add() {
    const sym   = symRef.current?.value.trim().toUpperCase()
    const field = fieldRef.current?.value ?? 'price'
    const op    = (opRef.current?.value ?? 'lt') as any
    const val   = parseFloat(valRef.current?.value ?? '')
    if (!sym || isNaN(val)) return
    addAlertRule({ sym, field, op, val, active: true })
    if (!prefilledSym && symRef.current) symRef.current.value = ''
    if (valRef.current) valRef.current.value = ''
  }

  async function testPush() {
    await sendPushover(
      'Granite Trader Test',
      `Alert system working. ${new Date().toLocaleTimeString()}`
    )
  }

  return (
    <div className="modal-overlay" onClick={e => { if (e.target === e.currentTarget) onClose() }}>
      <div className="modal-box">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
          <span className="modal-title">&#x1F514; Alert Center</span>
          <button className="btn sm" onClick={onClose}>&#x2715;</button>
        </div>

        <div style={{ fontSize: 11, color: 'var(--muted)', marginBottom: 10 }}>
          Alert me when the <b style={{ color: 'var(--accent)' }}>[field]</b> of{' '}
          <b style={{ color: 'var(--accent)' }}>[symbol]</b> is{' '}
          <b style={{ color: 'var(--accent)' }}>[op]</b>{' '}
          <b style={{ color: 'var(--accent)' }}>[value]</b>{' '}
          &mdash; delivered via desktop + Pushover
        </div>

        {/* Add rule */}
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 72px 96px auto', gap: 6, marginBottom: 14, alignItems: 'end' }}>
          <div>
            <label>Symbol</label>
            <input
              ref={symRef}
              type="text"
              placeholder="SPY"
              defaultValue={prefilledSym || ''}
              style={{ textTransform: 'uppercase' }}
            />
          </div>
          <div>
            <label>Field</label>
            <select ref={fieldRef}>
              <option value="price">Price</option>
              <option value="iv_pct">IV%</option>
              <option value="credit_pct_risk">Cr% Risk</option>
              <option value="short_delta">Short Delta</option>
              <option value="used_pct">Used%</option>
              <option value="pnl_open">P/L Open</option>
            </select>
          </div>
          <div>
            <label>Op</label>
            <select ref={opRef}>
              <option value="lt">&lt;</option>
              <option value="lte">&lt;=</option>
              <option value="eq">=</option>
              <option value="gte">&gt;=</option>
              <option value="gt">&gt;</option>
            </select>
          </div>
          <div>
            <label>Value</label>
            <input ref={valRef} type="number" placeholder="0.00" step="0.01" />
          </div>
          <button className="btn primary" onClick={add} style={{ height: 28 }}>+ ADD</button>
        </div>

        {/* Rules list */}
        <div style={{ maxHeight: 280, overflowY: 'auto' }}>
          {alertRules.length === 0 ? (
            <div className="empty-msg">No alerts set</div>
          ) : alertRules.map(a => (
            <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 8px', background: 'var(--bg2)', border: '1px solid var(--border)', borderRadius: 4, marginBottom: 5, fontSize: 12 }}>
              <div style={{ width: 8, height: 8, borderRadius: '50%', background: a.active ? 'var(--green)' : 'var(--border)', flexShrink: 0 }} />
              <input type="checkbox" checked={a.active} onChange={e => toggleAlertRule(a.id, e.target.checked)} />
              <span>{a.sym} &mdash; {FIELD_LABELS[a.field] ?? a.field} {OP_LABELS[a.op] ?? a.op} {a.val}</span>
              {a.triggered && <span style={{ color: 'var(--warn)', fontSize: 10 }}>&#x26A0; FIRED</span>}
              <button
                style={{ marginLeft: 'auto', background: 'none', border: 'none', color: 'var(--muted)', cursor: 'pointer', fontSize: 14 }}
                onClick={() => deleteAlertRule(a.id)}
              >&#x2715;</button>
            </div>
          ))}
        </div>

        <div style={{ marginTop: 14, display: 'flex', gap: 12, alignItems: 'center' }}>
          <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, textTransform: 'none', color: 'var(--text)' }}>
            <input
              type="checkbox"
              checked={alertsMaster}
              onChange={e => setAlertsMaster(e.target.checked)}
            />
            All alerts active
          </label>
          <button className="btn sm" onClick={testPush}>Test Pushover</button>
          <span style={{ fontSize: 10, color: 'var(--muted)', marginLeft: 4 }}>
            Keys: uw8mofrtidtoc46hth3v86dymnssyi
          </span>
        </div>
      </div>
    </div>
  )
}
