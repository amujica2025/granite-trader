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

function f$(v: number) { return '$' + v.toFixed(2) }

interface Props {
  onRefreshNow: () => void
  onAlertsOpen: () => void
  onResetLayout: () => void
}

export function TotalsBar({ onRefreshNow, onAlertsOpen, onResetLayout }: Props) {
  const {
    positions, selectedIds, scanResults, alertRules,
    theme, setTheme, refreshInterval, refreshCountdown, setRefreshInterval,
  } = useStore()

  const selected = positions.filter(p => selectedIds.has(p.id))
  const sv  = selected.reduce((a, r) => a + (r.short_value  ?? 0), 0)
  const lc  = selected.reduce((a, r) => a + (r.long_cost    ?? 0), 0)
  const pnl = selected.reduce((a, r) => a + (r.pnl_open     ?? 0), 0)
  const imp = selected.reduce((a, r) => a + (r.limit_impact ?? 0), 0)
  const activeAlerts = alertRules.filter(a => a.active).length

  return (
    <div className="bottombar">
      {/* Selection totals */}
      <span style={{ fontSize: 8, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.07em', marginRight: 2 }}>SEL:</span>
      <div className="tchip"><span className="tl">Legs</span><span className="tv">{selected.length}</span></div>
      <div className="tchip"><span className="tl">Sht Val</span><span className="tv">{f$(sv)}</span></div>
      <div className="tchip"><span className="tl">Lng Cost</span><span className="tv">{f$(lc)}</span></div>
      <div className="tchip"><span className="tl">P/L Open</span><span className="tv" style={{ color: pnl >= 0 ? 'var(--green)' : 'var(--red)' }}>{f$(pnl)}</span></div>
      <div className="tchip"><span className="tl">Impact</span><span className="tv text-warn">{f$(imp)}</span></div>

      <div style={{ borderLeft: '1px solid var(--border)', height: 24, margin: '0 6px' }} />

      {/* Right side: theme, refresh, alerts, layout */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 4, marginLeft: 'auto' }}>
        {/* Skin selector */}
        <span style={{ fontSize: 8, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em' }}>SKIN</span>
        {THEMES.map(t => (
          <div
            key={t.id}
            className={`theme-dot${theme === t.id ? ' active' : ''}`}
            style={{ background: t.color }}
            title={t.label}
            onClick={() => setTheme(t.id)}
          />
        ))}

        <div style={{ width: 1, height: 20, background: 'var(--border)', margin: '0 4px' }} />

        {/* Refresh interval */}
        <span style={{ fontSize: 8, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.05em' }}>REFRESH</span>
        <select
          value={refreshInterval}
          onChange={e => setRefreshInterval(Number(e.target.value))}
          style={{ width: 72, padding: '2px 5px', fontSize: 10 }}
        >
          <option value={30}>30s</option>
          <option value={60}>1 min</option>
          <option value={120}>2 min</option>
          <option value={300}>5 min</option>
          <option value={600}>10 min</option>
        </select>
        <span style={{ fontSize: 10, color: 'var(--muted)', minWidth: 30 }}>{refreshCountdown}s</span>

        <button className="btn sm" onClick={onRefreshNow}>&#x21BA;</button>
        <button className="btn sm" onClick={onAlertsOpen}>
          &#x1F514; {activeAlerts > 0 ? `${activeAlerts}` : ''}
        </button>

        <div style={{ width: 1, height: 20, background: 'var(--border)', margin: '0 4px' }} />

        {/* Stats */}
        <div className="tchip"><span className="tl">Positions</span><span className="tv">{positions.length}</span></div>
        <div className="tchip"><span className="tl">Scan Results</span><span className="tv">{scanResults.length}</span></div>

        <button className="btn sm" onClick={onResetLayout} style={{ opacity: 0.5, fontSize: 9 }}>
          RESET LAYOUT
        </button>
      </div>
    </div>
  )
}
