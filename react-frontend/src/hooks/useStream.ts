/**
 * useStream.ts ? DXLink WebSocket bridge hook
 *
 * Connects to ws://localhost:8000/ws/stream on mount.
 * Receives all market + account events from the backend relay.
 * Dispatches to Zustand store ? no other component needs to
 * know the WebSocket exists.
 *
 * Event types handled:
 *   connected     ? stream is live, set streamConnected = true
 *   quote         ? live bid/ask/last/OHLC for a symbol
 *   candle        ? single OHLCV bar (historical bulk + live updates)
 *   greeks        ? option Greeks for a position leg
 *   order         ? tastytrade order fill notification
 *   balance       ? account balance update
 *   position      ? position change notification
 *   ping          ? keepalive from backend (no action needed)
 */

import { useEffect, useRef, useCallback } from 'react'
import { useStore } from '../store/useStore'
import type { Candle } from '../api/client'

const WS_URL      = 'ws://localhost:8000/ws/stream'
const RECONNECT_MS = 3000   // retry after 3s on disconnect

export function useStream() {
  const wsRef      = useRef<WebSocket | null>(null)
  const retryTimer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const mounted    = useRef(true)

  const {
    updateLiveQuote,
    updateStreamCandle,
    setStreamCandles,
    setStreamConnected,
    setQuote,
    activeSymbol,
  } = useStore()

  const handleMessage = useCallback((raw: string) => {
    let msg: any
    try { msg = JSON.parse(raw) } catch { return }

    const { type, symbol, data, candle, candle_sym } = msg

    switch (type) {

      case 'connected':
        setStreamConnected(true, 'dxlink')
        break

      case 'quote': {
        // symbol is the underlying (e.g. "SPY")
        if (symbol && data) {
          updateLiveQuote(symbol, data)
        }
        break
      }

      case 'candle': {
        // symbol here is the candle_sym e.g. "SPY{=1d}"
        // candle = { time, open, high, low, close, volume }
        const cSym   = msg.symbol as string   // "SPY{=1d}"
        const bar    = msg.candle as Candle
        const isUpdt = msg.is_update as boolean

        if (!cSym || !bar) break

        // Derive the store key from candle symbol
        // "SPY{=1d}" ? key depends on how ChartTile subscribed
        // We use the full candle symbol as the key
        if (isUpdt) {
          updateStreamCandle(cSym, bar)
        } else {
          // Historical bulk candles arrive one by one ? accumulate
          updateStreamCandle(cSym, bar)
        }
        break
      }

      case 'order':
        // Future: trigger positions refresh, show toast
        console.log('[stream] Order event:', data?.status, data?.id)
        break

      case 'balance':
        // Future: update net liq in real-time
        break

      case 'position':
        // Future: trigger positions refresh
        break

      case 'ping':
        // Backend keepalive ? no action needed
        break

      default:
        break
    }
  }, [updateLiveQuote, updateStreamCandle, setStreamConnected])

  const connect = useCallback(() => {
    if (!mounted.current) return

    const ws = new WebSocket(WS_URL)
    wsRef.current = ws

    ws.onopen = () => {
      console.log('[stream] WebSocket connected')
      setStreamConnected(true, 'dxlink')
    }

    ws.onmessage = (e) => handleMessage(e.data)

    ws.onclose = () => {
      console.log('[stream] WebSocket closed ? reconnecting in 3s')
      setStreamConnected(false, 'none')
      wsRef.current = null
      if (mounted.current) {
        retryTimer.current = setTimeout(connect, RECONNECT_MS)
      }
    }

    ws.onerror = () => {
      // onerror always followed by onclose ? let onclose handle reconnect
      setStreamConnected(false, 'none')
    }
  }, [handleMessage, setStreamConnected])

  useEffect(() => {
    mounted.current = true
    connect()

    return () => {
      mounted.current = false
      if (retryTimer.current) clearTimeout(retryTimer.current)
      if (wsRef.current) {
        wsRef.current.onclose = null   // prevent reconnect on unmount
        wsRef.current.close()
      }
    }
  }, [connect])

  // Expose a manual subscribe function so components can request symbols
  const subscribeQuotes = useCallback(async (symbols: string[]) => {
    try {
      await fetch('http://localhost:8000/stream/subscribe/quotes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ symbols }),
      })
    } catch (e) {
      console.warn('[stream] subscribeQuotes failed:', e)
    }
  }, [])

  const subscribeCandles = useCallback(async (symbol: string, period: string) => {
    try {
      await fetch('http://localhost:8000/stream/subscribe/candles', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ symbols: [symbol], period }),
      })
    } catch (e) {
      console.warn('[stream] subscribeCandles failed:', e)
    }
  }, [])

  const subscribeGreeks = useCallback(async (optionSymbols: string[]) => {
    try {
      await fetch('http://localhost:8000/stream/subscribe/greeks', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ option_symbols: optionSymbols }),
      })
    } catch (e) {
      console.warn('[stream] subscribeGreeks failed:', e)
    }
  }, [])

  return { subscribeQuotes, subscribeCandles, subscribeGreeks }
}
