import type { LimitSummary, Position, ScanResult, VolSurfaceData } from '../types'

const API = 'http://localhost:8000'

async function get<T>(path: string): Promise<T> {
  const r = await fetch(API + path)
  if (!r.ok) {
    const text = await r.text()
    throw new Error(text || `HTTP ${r.status}`)
  }
  return r.json()
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const r = await fetch(API + path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!r.ok) {
    const text = await r.text()
    throw new Error(text || `HTTP ${r.status}`)
  }
  return r.json()
}

// â”€â”€ Account â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export async function fetchAccount(source: 'mock' | 'tasty'): Promise<{
  source: string
  positions: Position[]
  limit_summary: LimitSummary
}> {
  return get(`/account/${source}`)
}

// â”€â”€ Quote â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export async function fetchQuote(symbol: string): Promise<Record<string, { quote: Record<string, number> }>> {
  return get(`/quote/schwab?symbol=${encodeURIComponent(symbol)}`)
}

// â”€â”€ Chain â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export async function fetchChain(symbol: string): Promise<{
  symbol: string
  underlying_price: number
  expirations: string[]
  strikes: number[]
  active_chain_source: string
}> {
  return get(`/chain?symbol=${encodeURIComponent(symbol)}`)
}

// â”€â”€ Refresh â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export async function refreshSymbol(symbol: string): Promise<{
  symbol: string
  active_chain_source: string
  contract_count: number
  expirations: string[]
}> {
  return get(`/refresh/symbol?symbol=${encodeURIComponent(symbol)}`)
}

// â”€â”€ Scanner â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export interface ScanParams {
  symbol: string
  total_risk: number
  side: 'all' | 'call' | 'put'
  expiration: string
  sort_by: string
  max_results: number
}

export async function fetchScan(params: ScanParams): Promise<{
  symbol: string
  count: number
  items: ScanResult[]
  active_chain_source: string
}> {
  const qs = new URLSearchParams({
    symbol: params.symbol,
    total_risk: String(params.total_risk),
    side: params.side,
    expiration: params.expiration,
    sort_by: params.sort_by,
    max_results: String(params.max_results),
  })
  return get(`/scan/live?${qs}`)
}

// â”€â”€ Vol Surface â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export async function fetchVolSurface(symbol: string, maxExp = 7, strikeCount = 25): Promise<VolSurfaceData> {
  return get(`/vol/surface?symbol=${encodeURIComponent(symbol)}&max_expirations=${maxExp}&strike_count=${strikeCount}`)
}

// â”€â”€ Alerts â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export async function sendPushover(title: string, message: string): Promise<void> {
  await post('/alerts/pushover', { title, message, notify_whatsapp: false })
}

// â”€â”€ Health â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export async function fetchHealth(): Promise<{ status: string; active_chain_source: string }> {
  return get('/health')
}

// â”€â”€ Chart / Price History â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
export interface Candle {
  time: number   // Unix seconds
  open: number
  high: number
  low: number
  close: number
  volume: number
}

export interface PriceHistory {
  symbol: string
  period: string
  frequency: string
  count: number
  candles: Candle[]
}

export async function fetchPriceHistory(
  symbol: string,
  period = '5y',
  frequency = 'daily',
): Promise<PriceHistory> {
  return get(`/chart/history?symbol=${encodeURIComponent(symbol)}&period=${period}&frequency=${frequency}`)
}
