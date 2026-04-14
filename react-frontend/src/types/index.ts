export interface Position {
  id: string
  underlying: string
  group?: string
  display_qty: number
  option_type: 'C' | 'P'
  expiration: string
  strike: number
  mark: number
  trade_price: number
  pnl_open: number
  short_value: number
  long_cost: number
  limit_impact: number
  delta?: number
  theta?: number
  vega?: number
}

export interface LimitSummary {
  net_liq: number
  max_limit: number
  used_short_value: number
  remaining_room: number
  used_pct: number
}

export interface ScanResult {
  symbol: string
  expiration: string
  structure: string
  option_side: 'call' | 'put'
  short_strike: number
  long_strike: number
  width: number
  quantity: number
  defined_risk: number
  gross_defined_risk: number
  actual_defined_risk: number
  target_defined_risk: number
  max_loss: number
  short_price: number
  long_price: number
  short_value: number
  long_cost: number
  net_credit: number
  credit_pct_risk: number
  credit_pct_risk_pct: number
  reward_to_max_loss: number | null
  limit_impact: number
  short_delta: number
  long_delta: number
  short_iv: number
  long_iv: number
  avg_iv: number
  richness_score: number
  credit_pct_risk_rank_within_exp: number
  iv_rank_within_exp: number
  exp_avg_credit_pct_risk: number
  exp_avg_iv: number
  underlying_price: number
  pricing_mode: string
}

export interface VolSurfaceData {
  symbol: string
  underlying_price: number | null
  expirations: string[]
  strikes: number[]
  iv_matrix: (number | null)[][]
  avg_iv_matrix: (number | null)[][]
  call_iv_matrix: (number | null)[][]
  put_iv_matrix: (number | null)[][]
  skew_matrix: (number | null)[][]
  avg_iv_by_expiration: Record<string, number | null>
  skew_curves: Record<string, { strike: number; call_iv: number | null; put_iv: number | null; avg_iv: number | null; skew_iv: number | null }[]>
  richness_scores: Record<string, {
    avg_iv: number | null
    put_call_skew_near_spot: number | null
    iv_premium_vs_surface: number | null
    richness_score: number | null
  }>
  count: number
  active_chain_source: string
  strike_spacing_by_expiration: Record<string, { common_step: number | null }>
}

export interface QuoteData {
  lastPrice?: number
  mark?: number
  closePrice?: number
  openPrice?: number
  highPrice?: number
  lowPrice?: number
  netChange?: number
  netPercentChange?: number
  bidPrice?: number
  askPrice?: number
}

export interface AlertRule {
  id: number
  sym: string
  field: string
  op: 'lt' | 'lte' | 'eq' | 'gte' | 'gt'
  val: number
  active: boolean
  triggered: boolean
}

export interface WatchlistRow {
  sym: string
  price: string
  chg: string
  rs14: string
  ivpct: string
  ivhv: string
  iv: string
  iv5d: string
  iv1m: string
  iv3m: string
  iv6m: string
  bb: string
  bbr: string
  ttm: string
  adr14: string
  opvol: string
  callvol: string
  putvol: string
}

export type Theme = 'slate' | 'navy' | 'emerald' | 'teal' | 'amber' | 'rose' | 'purple' | 'mono'

export type VSView = 'avg' | 'call' | 'put' | 'skew' | '3d'
