import { MarqueeTicker } from './MarqueeTicker'
import { useStore } from '../../store/useStore'

function f$(v: number | null) {
  return v == null ? '--' : '$' + v.toFixed(2)
}

interface Props {
  onRefreshNow: () => void
  onAlertsOpen: () => void
}

export function TopBar({ onRefreshNow, onAlertsOpen }: Props) {
  const {
    limitSummary, quote,
    desktopAllowed, setDesktopAllowed,
    streamConnected,
  } = useStore()

  const usedPct  = limitSummary ? Number(limitSummary.used_pct) * 100 : 0
  const pctColor = usedPct > 80 ? 'var(--red)' : usedPct > 60 ? 'var(--warn)' : 'var(--green)'
  const chgColor = (quote.netChange ?? 0) >= 0 ? 'var(--green)' : 'var(--red)'
  const chgSign  = (quote.netChange ?? 0) >= 0 ? '+' : ''
  const chgText  = quote.netChange != null
    ? `${chgSign}${quote.netChange.toFixed(2)} (${((quote.netPctChange ?? 0) * 100).toFixed(2)}%)`
    : '--'

  async function enableNotifs() {
    if (!('Notification' in window)) return
    const perm = await Notification.requestPermission()
    setDesktopAllowed(perm === 'granted')
  }

  return (
    <div className="topbar">
      {/* LEFT: brand */}
      <div className="topbar-left">
        <span className="topbar-brand font-display">&#x2B21; GRANITE</span>
        <div className="tsep" />
        <button
          className="btn sm"
          onClick={enableNotifs}
          style={{ fontSize: 10, color: desktopAllowed ? 'var(--green)' : 'var(--muted)', padding: '2px 8px' }}
        >
          {desktopAllowed ? 'NOTIF ON' : 'NOTIF'}
        </button>
      </div>

      {/* CENTER: scrolling index marquee */}
      <div className="topbar-center" style={{ overflow: 'hidden', padding: '0 8px' }}>
        <MarqueeTicker />
      </div>

      {/* RIGHT: balances + stream status */}
      <div className="topbar-right">
        <div className="tpill">
          <span className="lbl">Net Liq</span>
          <span className="val">{f$(limitSummary?.net_liq ?? null)}</span>
        </div>
        <div className="tpill">
          <span className="lbl">Limit x25</span>
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
        <div className="tpill" style={{ minWidth: 110 }}>
          <span className="lbl">Source</span>
          <span className="val" style={{
            fontSize: 11,
            color: streamConnected ? 'var(--green)' : 'var(--muted)',
            display: 'flex', alignItems: 'center', gap: 5,
          }}>
            <span style={{
              width: 8, height: 8, borderRadius: '50%',
              background: streamConnected ? 'var(--green)' : 'var(--border)',
              flexShrink: 0,
              boxShadow: streamConnected ? '0 0 6px var(--green)' : 'none',
            }} />
            {streamConnected ? 'TASTY LIVE' : 'TASTY REST'}
          </span>
        </div>
        <div style={{
          padding: '3px 10px',
          background: 'var(--bg3)',
          border: '1px solid var(--green)',
          borderRadius: 3, fontSize: 11,
          color: 'var(--green)', fontWeight: 700,
        }}>
          TASTY
        </div>
      </div>
    </div>
  )
}
