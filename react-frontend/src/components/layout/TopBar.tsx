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
    streamConnected, streamSource,
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
        <div className="tpill" style={{ minWidth: 100 }}>
          <span className="lbl">Data Source</span>
          <span className="val" style={{ fontSize: 11, color: streamConnected ? 'var(--green)' : 'var(--muted)', display: 'flex', alignItems: 'center', gap: 5 }}>
            <span style={{ width: 8, height: 8, borderRadius: '50%', background: streamConnected ? 'var(--green)' : 'var(--border)', flexShrink: 0, boxShadow: streamConnected ? '0 0 6px var(--green)' : 'none' }} />
            {streamConnected ? 'DXLINK LIVE' : (quote.activeSource || 'REST')}
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
