/**
 * MarqueeTicker.tsx
 * Scrolling live price strip for major indices.
 * Polls /quote/live for each symbol every 5s.
 */
import { useEffect, useRef, useState } from 'react'
import { useStore } from '../../store/useStore'

const SYMBOLS = ['SPY', 'QQQ', 'IWM', 'GLD', 'TLT', 'VIX', 'DXY']
const LABELS:  Record<string, string> = {
  SPY: 'S&P 500', QQQ: 'NASDAQ', IWM: 'RUSSELL', GLD: 'GOLD', TLT: 'BONDS', VIX: 'VIX', DXY: 'DXY'
}

interface TickerItem {
  sym:   string
  last:  number | null
  chg:   number | null
  pct:   number | null
}

function fmt(v: number | null, decimals = 2) {
  return v == null ? '--' : v.toFixed(decimals)
}

export function MarqueeTicker() {
  const { livePrices } = useStore()
  const [tickers, setTickers] = useState<TickerItem[]>(
    SYMBOLS.map(sym => ({ sym, last: null, chg: null, pct: null }))
  )
  const scrollRef = useRef<HTMLDivElement>(null)

  // Pull from live prices store ? updated by DXLink stream
  useEffect(() => {
    const updated = SYMBOLS.map(sym => {
      const lp = livePrices[sym]
      return {
        sym,
        last: lp?.last ?? null,
        chg:  lp?.last && lp?.open ? lp.last - lp.open : null,
        pct:  lp?.pct ?? null,
      }
    })
    setTickers(updated)
  }, [livePrices])

  // Auto-scroll marquee
  useEffect(() => {
    const el = scrollRef.current
    if (!el) return
    let pos = 0
    const tick = setInterval(() => {
      pos += 0.5
      if (pos >= el.scrollWidth / 2) pos = 0
      el.scrollLeft = pos
    }, 30)
    return () => clearInterval(tick)
  }, [])

  const items = [...tickers, ...tickers]  // duplicate for seamless loop

  return (
    <div
      ref={scrollRef}
      style={{
        overflow: 'hidden',
        whiteSpace: 'nowrap',
        display: 'flex',
        alignItems: 'center',
        gap: 0,
        width: '100%',
        userSelect: 'none',
        cursor: 'default',
      }}
    >
      {items.map((t, i) => {
        const upColor  = (t.pct ?? 0) >= 0 ? 'var(--green)' : 'var(--red)'
        const sign     = (t.pct ?? 0) >= 0 ? '+' : ''
        return (
          <span
            key={`${t.sym}-${i}`}
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 6,
              padding: '0 18px',
              borderRight: '1px solid var(--border)',
              fontSize: 13,
              flexShrink: 0,
            }}
          >
            <span style={{ color: 'var(--muted)', fontSize: 11, fontWeight: 600, letterSpacing: '0.04em' }}>
              {LABELS[t.sym] ?? t.sym}
            </span>
            <span style={{ fontWeight: 700, color: 'var(--text)' }}>
              {t.last ? fmt(t.last) : '--'}
            </span>
            <span style={{ fontSize: 11, color: upColor }}>
              {t.pct != null ? `${sign}${(t.pct * 100).toFixed(2)}%` : ''}
            </span>
          </span>
        )
      })}
    </div>
  )
}
