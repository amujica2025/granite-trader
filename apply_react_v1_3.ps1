param(
    [switch]$SkipGit,
    [switch]$SkipBuild,
    [string]$Root = "C:\Users\alexm\granite_trader"
)
$ErrorActionPreference = "Stop"
function Write-Info([string]$m) { Write-Host "[Granite] $m" -ForegroundColor Cyan }
function Write-OK([string]$m)   { Write-Host "[Granite] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[Granite] $m" -ForegroundColor Yellow }
if (-not (Test-Path $Root)) { throw "Root not found: $Root" }

# Backup
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$bd = Join-Path $Root "_installer_backups\v1_3_$ts"
New-Item -ItemType Directory -Force -Path $bd | Out-Null
@("backend","react-frontend\src") | ForEach-Object {
    $src = Join-Path $Root $_
    if (Test-Path $src) { Copy-Item $src (Join-Path $bd $_) -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Info "Backup: $bd"

function Write-File([string]$rel, [string]$text) {
    $p = Join-Path $Root ($rel -replace '/', '\')
    $d = Split-Path $p -Parent
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Info "  $rel"
}

# Check Node.js in WSL
Write-Info "Checking Node.js in WSL..."
$nodeVersion = wsl.exe bash -lc "node --version 2>/dev/null" 2>$null
if (-not $nodeVersion -or $nodeVersion -notmatch 'v\d') {
    Write-Warn "Node.js not found in WSL. Installing Node 20..."
    wsl.exe bash -lc "curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt-get install -y nodejs" 2>&1 | Out-Null
    Write-OK "Node.js installed."
} else {
    Write-Info "Node.js: $nodeVersion"
}

Write-Info "Writing all files..."

$c = @'
"""
scanner.py  —  Granite Trader entry spread scanner

BUGS FIXED vs previous version
-------------------------------
1. SUPPORTED_WIDTHS removed entirely.
   Any width >= min_width (default = strike spacing for that expiration) is valid.
   GS with $2.50 spacing will now surface $7.50, $12.50, $15, $17.50, $20... widths.

2. _contracts_for_same_risk replaced with _best_quantity.
   Old: required exact integer -> returned 0 for any non-round quotient.
   New: qty = max(1, round(target / per_spread_risk)).
   actual_defined_risk shown in output; may differ slightly from target.

3. Richness score now meaningful: IV stored as decimal (schwab_adapter
   divides Schwab's percentage form by 100 at ingestion).

4. All output numbers rounded to 2dp.
"""
from __future__ import annotations

from collections import defaultdict
from typing import Any, Dict, List, Optional

from cache_manager import ensure_symbol_loaded


# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------

def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except Exception:
        return default


def _best_quantity(total_risk: float, width: float) -> int:
    """
    Nearest integer contracts for the target risk.
    Always at least 1 so every valid strike pair surfaces.
    """
    per_spread_risk = width * 100.0
    if per_spread_risk <= 0:
        return 0
    qty = total_risk / per_spread_risk
    return max(1, round(qty))


# ---------------------------------------------------------------------------
# Pricing modes
# ---------------------------------------------------------------------------

def _mid(bid: float, ask: float, mark: float) -> float:
    if bid > 0 and ask > 0:
        return (bid + max(bid, ask)) / 2.0
    return mark or ask or bid or 0.0


def _conservative_mid_sell(c: Dict[str, Any]) -> float:
    bid = _safe_float(c.get("bid"))
    ask = _safe_float(c.get("ask"))
    mark = _safe_float(c.get("mark"))
    mid = _mid(bid, ask, mark)
    return (bid + mid) / 2.0 if bid > 0 and mid > 0 else mid


def _conservative_mid_buy(c: Dict[str, Any]) -> float:
    bid = _safe_float(c.get("bid"))
    ask = _safe_float(c.get("ask"))
    mark = _safe_float(c.get("mark"))
    mid = _mid(bid, ask, mark)
    return (ask + mid) / 2.0 if ask > 0 and mid > 0 else mid


def _pricing_value(c: Dict[str, Any], action: str, pricing_mode: str) -> float:
    mode = pricing_mode.lower().strip()
    bid = _safe_float(c.get("bid"))
    ask = _safe_float(c.get("ask"))
    mark = _safe_float(c.get("mark"))
    if mode == "natural":
        return bid if action == "sell" else ask
    if mode == "mid":
        return _mid(bid, ask, mark)
    return _conservative_mid_sell(c) if action == "sell" else _conservative_mid_buy(c)


# ---------------------------------------------------------------------------
# Ranking helpers
# ---------------------------------------------------------------------------

def _percentile_ranks(items: List[float]) -> List[float]:
    if not items:
        return []
    if len(items) == 1:
        return [1.0]
    ordered = sorted((v, i) for i, v in enumerate(items))
    ranks = [0.0] * len(items)
    for rank, (_, idx) in enumerate(ordered):
        ranks[idx] = rank / (len(items) - 1)
    return ranks


def _sort_candidates(items: List[Dict[str, Any]], ranking: str) -> List[Dict[str, Any]]:
    r = ranking.lower().strip()
    if r == "credit":
        return sorted(items, key=lambda x: x["net_credit"], reverse=True)
    if r == "credit_pct_risk":
        return sorted(items, key=lambda x: x["credit_pct_risk"], reverse=True)
    if r == "limit_impact":
        return sorted(items, key=lambda x: (x["limit_impact"], -x["credit_pct_risk"]))
    if r == "max_loss":
        return sorted(items, key=lambda x: (x["max_loss"], -x["credit_pct_risk"]))
    return sorted(items, key=lambda x: x.get("richness_score", 0.0), reverse=True)


# ---------------------------------------------------------------------------
# Core spread builder
# ---------------------------------------------------------------------------

def _build_spread_candidates(
    symbol: str,
    expiration: str,
    underlying_price: float,
    side: str,
    contracts: List[Dict[str, Any]],
    total_risk: float,
    pricing_mode: str,
    min_width: float,
) -> List[Dict[str, Any]]:
    """
    All valid credit spreads for one expiration / one side.

    Call spread: short lower strike, long higher (bear call).
    Put  spread: short higher strike, long lower (bull put).
    Width >= min_width accepted. No preset list.
    """
    if not contracts:
        return []

    cs = sorted(contracts, key=lambda x: _safe_float(x.get("strike", 0)))
    results: List[Dict[str, Any]] = []

    for short_c in cs:
        for long_c in cs:
            ss = _safe_float(short_c.get("strike", 0))
            ls = _safe_float(long_c.get("strike", 0))

            if side == "call" and ls <= ss:
                continue
            if side == "put"  and ls >= ss:
                continue
            if side not in ("call", "put"):
                continue

            width = round(abs(ls - ss), 4)
            if width < min_width:
                continue

            qty = _best_quantity(total_risk, width)
            actual_risk = round(width * 100.0 * qty, 2)

            sf = _pricing_value(short_c, "sell", pricing_mode)
            lf = _pricing_value(long_c,  "buy",  pricing_mode)

            if sf <= 0 or lf <= 0:
                continue

            net_credit_per = (sf - lf) * 100.0
            if net_credit_per <= 0:
                continue

            net_credit  = round(net_credit_per * qty, 2)
            short_value = round(sf * 100.0 * qty, 2)
            long_cost   = round(lf * 100.0 * qty, 2)
            max_loss    = round(actual_risk - net_credit, 2)
            limit_impact = round(max(short_value, long_cost), 2)
            cr_pct      = round(net_credit / actual_risk, 4) if actual_risk > 0 else 0.0
            rtr         = round(net_credit / max_loss, 4) if abs(max_loss) > 0.01 else None

            short_iv = _safe_float(short_c.get("iv"))
            long_iv  = _safe_float(long_c.get("iv"))

            results.append({
                "symbol":              symbol.upper(),
                "expiration":          expiration,
                "structure":           "credit_spread",
                "option_side":         side,
                "short_strike":        round(ss, 2),
                "long_strike":         round(ls, 2),
                "width":               round(width, 2),
                "quantity":            qty,
                "target_defined_risk": round(total_risk, 2),
                "actual_defined_risk": actual_risk,
                "defined_risk":        actual_risk,
                "gross_defined_risk":  actual_risk,
                "max_loss":            max_loss,
                "short_price":         round(sf, 2),
                "long_price":          round(lf, 2),
                "short_value":         short_value,
                "long_cost":           long_cost,
                "net_credit":          net_credit,
                "credit_pct_risk":     cr_pct,
                "credit_pct_risk_pct": round(cr_pct * 100.0, 2),
                "reward_to_max_loss":  rtr,
                "limit_impact":        limit_impact,
                "short_delta":         round(_safe_float(short_c.get("delta")), 4),
                "long_delta":          round(_safe_float(long_c.get("delta")), 4),
                "short_iv":            round(short_iv, 4),
                "long_iv":             round(long_iv, 4),
                "avg_iv":              round((short_iv + long_iv) / 2.0, 4),
                "underlying_price":    round(underlying_price, 2),
                "short_option_symbol": short_c.get("option_symbol", ""),
                "long_option_symbol":  long_c.get("option_symbol", ""),
                "pricing_mode":        pricing_mode,
                "richness_score":      0.0,  # filled by _enrich_candidates
            })

    return results


# ---------------------------------------------------------------------------
# Enrichment
# ---------------------------------------------------------------------------

def _enrich_candidates(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    buckets: Dict[str, List[int]] = defaultdict(list)
    for idx, item in enumerate(items):
        key = f"{item['expiration']}|{item['option_side']}"
        buckets[key].append(idx)

    enriched = [dict(item) for item in items]

    for bucket_indices in buckets.values():
        credit_pcts = [enriched[i]["credit_pct_risk"] for i in bucket_indices]
        ivs         = [enriched[i]["avg_iv"]           for i in bucket_indices]
        cp_ranks    = _percentile_ranks(credit_pcts)
        iv_ranks    = _percentile_ranks(ivs)
        avg_cr      = sum(credit_pcts) / len(credit_pcts) if credit_pcts else 0.0
        avg_iv      = sum(ivs) / len(ivs) if ivs else 0.0

        for rank_pos, idx in enumerate(bucket_indices):
            richness = round(0.70 * cp_ranks[rank_pos] + 0.30 * iv_ranks[rank_pos], 4)
            enriched[idx].update({
                "credit_pct_risk_rank_within_exp": round(cp_ranks[rank_pos], 4),
                "iv_rank_within_exp":              round(iv_ranks[rank_pos], 4),
                "exp_avg_credit_pct_risk":         round(avg_cr, 4),
                "exp_avg_iv":                      round(avg_iv, 4),
                "richness_score":                  richness,
            })

    return enriched


def _deduplicate(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    seen: Dict[tuple, Dict[str, Any]] = {}
    for item in items:
        key = (item["short_strike"], item["long_strike"], item["expiration"], item["option_side"])
        if key not in seen or item.get("richness_score", 0) > seen[key].get("richness_score", 0):
            seen[key] = item
    return list(seen.values())


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_risk_equivalent_candidates(
    symbol: str,
    total_risk: float = 600.0,
    expirations: Optional[List[str]] = None,
    side_filter: str = "all",
    pricing_mode: str = "conservative_mid",
    strike_count: int = 200,
    ranking: str = "credit_pct_risk",
    max_results: int = 500,
    min_width: float = 0.5,
) -> List[Dict[str, Any]]:
    """
    Scan for credit spread candidates across all valid strike pairs.

    total_risk   : Target position risk in $. Quantity chosen by rounding.
                   actual_defined_risk in results may differ slightly.
    pricing_mode : "conservative_mid" (default) | "mid" | "natural"
    min_width    : Minimum spread width in $. Default = strike spacing for expiration.
    """
    state = ensure_symbol_loaded(
        symbol=symbol,
        strike_count=strike_count,
        requested_by="scanner",
    )

    all_contracts: List[Dict[str, Any]] = state.get("contracts", [])
    underlying_price: float = _safe_float(state.get("underlying_price", 0.0))
    all_expirations: List[str] = state.get("expirations", [])
    spacing_by_exp: Dict[str, Any] = state.get("strike_spacing_by_expiration", {})

    if not all_contracts or underlying_price <= 0:
        return []

    target_exps = expirations if expirations else all_expirations[:7]
    sides = ["call", "put"] if side_filter == "all" else [side_filter.lower()]

    # Group contracts by (expiration, option_side) for O(1) lookup
    grouped: Dict[tuple, List[Dict[str, Any]]] = defaultdict(list)
    for c in all_contracts:
        grouped[(c.get("expiration", ""), c.get("option_side", ""))].append(c)

    all_candidates: List[Dict[str, Any]] = []

    for exp in target_exps:
        # Use detected strike spacing as minimum width floor for this expiration
        sp_info = spacing_by_exp.get(exp, {})
        effective_min = max(min_width, _safe_float(sp_info.get("min_step"), min_width))

        for side in sides:
            bucket = grouped.get((exp, side), [])
            if not bucket:
                continue

            candidates = _build_spread_candidates(
                symbol=symbol,
                expiration=exp,
                underlying_price=underlying_price,
                side=side,
                contracts=bucket,
                total_risk=total_risk,
                pricing_mode=pricing_mode,
                min_width=effective_min,
            )
            all_candidates.extend(candidates)

    if not all_candidates:
        return []

    all_candidates = _enrich_candidates(all_candidates)
    all_candidates = _deduplicate(all_candidates)
    all_candidates = _sort_candidates(all_candidates, ranking)

    return all_candidates[:max_results]

'@
Write-File "backend\scanner.py" $c

$c = @'
from __future__ import annotations

import datetime as dt
import os
from collections import Counter
from statistics import mean
from typing import Any, Dict, List, Optional

from schwab.auth import client_from_token_file


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def _get_client():
    api_key = os.getenv("SCHWAB_CLIENT_ID", "").strip()
    app_secret = os.getenv("SCHWAB_CLIENT_SECRET", "").strip()
    token_path = os.getenv(
        "SCHWAB_TOKEN_PATH",
        "/mnt/c/Users/alexm/granite_trader/backend/schwab_token.json",
    )
    if not api_key or not app_secret:
        raise RuntimeError(
            "Schwab env vars not loaded. Set SCHWAB_CLIENT_ID and SCHWAB_CLIENT_SECRET in .env."
        )
    return client_from_token_file(
        token_path=token_path,
        api_key=api_key,
        app_secret=app_secret,
    )


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _parse_date(value: Optional[str | dt.date]) -> Optional[dt.date]:
    if value is None or value == "":
        return None
    if isinstance(value, dt.date):
        return value
    return dt.date.fromisoformat(str(value))


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except Exception:
        return default


def _extract_expiration(exp_key: str) -> tuple[str, Optional[int]]:
    """
    Schwab encodes expirations as 'YYYY-MM-DD:DTE'.
    Returns (date_str, dte_or_None).
    """
    parts = str(exp_key).split(":")
    expiration = parts[0]
    dte = None
    if len(parts) > 1:
        try:
            dte = int(parts[1])
        except Exception:
            dte = None
    return expiration, dte


def _extract_underlying_price(chain: Dict[str, Any]) -> float:
    candidates = [
        chain.get("underlyingPrice"),
        chain.get("underlying", {}).get("last"),
        chain.get("underlying", {}).get("mark"),
        chain.get("underlying", {}).get("close"),
        chain.get("underlying", {}).get("bid"),
        chain.get("underlying", {}).get("ask"),
    ]
    for value in candidates:
        number = _safe_float(value, default=0.0)
        if number > 0:
            return number
    return 0.0


def _mid_from_bid_ask(bid: float, ask: float, mark: float) -> float:
    if bid > 0 and ask > 0:
        if ask < bid:
            ask = bid
        return (bid + ask) / 2.0
    if mark > 0:
        return mark
    if ask > 0:
        return ask
    if bid > 0:
        return bid
    return 0.0


def _flatten_contract_map(
    symbol: str,
    option_side: str,
    option_map: Dict[str, Any],
    underlying_price: float,
) -> List[Dict[str, Any]]:
    """
    Flatten Schwab's nested callExpDateMap / putExpDateMap into a list of
    normalized contract dicts.  Each dict contains every field downstream
    consumers (scanner, vol_surface) expect.
    """
    flattened: List[Dict[str, Any]] = []

    for exp_key, strikes_map in (option_map or {}).items():
        expiration, dte = _extract_expiration(exp_key)
        if not isinstance(strikes_map, dict):
            continue

        for strike_key, contracts in strikes_map.items():
            strike = _safe_float(strike_key, default=0.0)
            if not isinstance(contracts, list):
                continue

            for contract in contracts:
                bid = _safe_float(contract.get("bid"), default=0.0)
                ask = _safe_float(contract.get("ask"), default=0.0)
                mark = _safe_float(contract.get("mark"), default=0.0)
                delta = _safe_float(contract.get("delta"), default=0.0)
                # Schwab returns volatility as an annualized PERCENTAGE (e.g., 34.25 = 34.25% IV)
                # Divide by 100 to store as decimal for consistent internal use.
                # Frontend displays as (v * 100).toFixed(2) + '%' — correct with decimal form.
                raw_iv = _safe_float(contract.get("volatility"), default=0.0)
                iv = raw_iv / 100.0
                total_volume = _safe_float(contract.get("totalVolume"), default=0.0)
                open_interest = _safe_float(contract.get("openInterest"), default=0.0)
                description = str(contract.get("description", "") or "")
                option_symbol = str(contract.get("symbol", "") or "")

                flattened.append(
                    {
                        "underlying": symbol.upper(),
                        "option_side": option_side.lower(),
                        "expiration": expiration,
                        "days_to_expiration": dte,
                        "strike": round(strike, 4),
                        "bid": round(bid, 4),
                        "ask": round(ask, 4),
                        "mark": round(mark, 4),
                        "mid": round(_mid_from_bid_ask(bid, ask, mark), 4),
                        "delta": round(delta, 6),
                        "iv": round(iv, 6),
                        "total_volume": round(total_volume, 2),
                        "open_interest": round(open_interest, 2),
                        "in_the_money": bool(contract.get("inTheMoney", False)),
                        "option_symbol": option_symbol,
                        "description": description,
                        "underlying_price": round(underlying_price, 4),
                    }
                )

    return flattened


# ---------------------------------------------------------------------------
# Strike-spacing detection
# ---------------------------------------------------------------------------

def _compute_strike_spacing_by_expiration(
    contracts: List[Dict[str, Any]],
) -> Dict[str, Dict[str, Any]]:
    """
    For each expiration, derive the actual strike step sizes present in the chain.
    Some weeklies use $0.50, others $1.00; the same ticker can vary across expirations.
    """
    grouped: Dict[str, List[float]] = {}
    for contract in contracts:
        exp = str(contract.get("expiration"))
        grouped.setdefault(exp, []).append(_safe_float(contract.get("strike")))

    output: Dict[str, Dict[str, Any]] = {}
    for exp, strikes in grouped.items():
        unique_strikes = sorted({round(s, 4) for s in strikes if s > 0})
        diffs = [
            round(unique_strikes[i + 1] - unique_strikes[i], 4)
            for i in range(len(unique_strikes) - 1)
        ]
        positive_diffs = [d for d in diffs if d > 0]
        counter = Counter(positive_diffs)
        common_step = counter.most_common(1)[0][0] if counter else None
        output[exp] = {
            "strike_count": len(unique_strikes),
            "min_step": min(positive_diffs) if positive_diffs else None,
            "max_step": max(positive_diffs) if positive_diffs else None,
            "common_step": common_step,
            "step_set": sorted(counter.keys()),
        }
    return output


# ---------------------------------------------------------------------------
# ATM IV helpers for symbol snapshot
# ---------------------------------------------------------------------------

def _compute_atm_iv_for_expiration(
    contracts: List[Dict[str, Any]], underlying_price: float
) -> Optional[float]:
    if not contracts or underlying_price <= 0:
        return None
    ordered = sorted(contracts, key=lambda c: abs(_safe_float(c.get("strike")) - underlying_price))
    nearest = ordered[:8]
    ivs = [_safe_float(c.get("iv")) for c in nearest if _safe_float(c.get("iv")) > 0]
    return round(mean(ivs), 6) if ivs else None


def _pick_term_iv(
    by_exp: Dict[str, List[Dict[str, Any]]],
    underlying_price: float,
    target_dte: int,
) -> Optional[float]:
    best_exp: Optional[str] = None
    best_gap: Optional[int] = None
    for exp, contracts in by_exp.items():
        if not contracts:
            continue
        dte = contracts[0].get("days_to_expiration")
        if dte is None:
            continue
        gap = abs(int(dte) - int(target_dte))
        if best_gap is None or gap < best_gap:
            best_gap = gap
            best_exp = exp
    if best_exp is None:
        return None
    return _compute_atm_iv_for_expiration(by_exp[best_exp], underlying_price)


# ---------------------------------------------------------------------------
# Quote normalization
# ---------------------------------------------------------------------------

def _normalize_quote_snapshot(symbol: str, quote_raw: Dict[str, Any]) -> Dict[str, Any]:
    payload = quote_raw.get(symbol.upper(), {})
    quote = payload.get("quote", {})
    last_price = _safe_float(quote.get("lastPrice"))
    mark = _safe_float(quote.get("mark"))
    close_price = _safe_float(quote.get("closePrice"))
    effective_last = last_price or mark or close_price
    net_change = _safe_float(quote.get("netChange"))
    pct_change = (net_change / close_price) if close_price else 0.0

    return {
        "symbol": symbol.upper(),
        "last_price": round(effective_last, 4),
        "mark": round(mark, 4),
        "close_price": round(close_price, 4),
        "net_change": round(net_change, 4),
        "pct_change": round(pct_change, 6),
        "bid": round(_safe_float(quote.get("bidPrice")), 4),
        "ask": round(_safe_float(quote.get("askPrice")), 4),
        "quote_source": "schwab",
    }


# ---------------------------------------------------------------------------
# Expiration helpers
# ---------------------------------------------------------------------------

def _choose_nearest_expirations(
    expirations: List[str], max_expirations: int
) -> List[str]:
    return sorted(expirations)[:max_expirations]


def _filter_contracts_to_expirations(
    contracts: List[Dict[str, Any]], expirations: List[str]
) -> List[Dict[str, Any]]:
    allowed = set(expirations)
    return [c for c in contracts if c.get("expiration") in allowed]


# ---------------------------------------------------------------------------
# Symbol snapshot (watchlist-level fields derivable from Schwab)
# ---------------------------------------------------------------------------

def build_symbol_snapshot_from_schwab(
    symbol: str,
    quote_raw: Dict[str, Any],
    flat_chain: Dict[str, Any],
    max_expirations: int = 7,
) -> Dict[str, Any]:
    quote_snapshot = _normalize_quote_snapshot(symbol, quote_raw)
    nearest_expirations = _choose_nearest_expirations(
        flat_chain["expirations"], max_expirations=max_expirations
    )
    contracts = _filter_contracts_to_expirations(flat_chain["contracts"], nearest_expirations)
    underlying_price = (
        _safe_float(flat_chain.get("underlying_price"))
        or _safe_float(quote_snapshot.get("last_price"))
    )

    by_exp: Dict[str, List[Dict[str, Any]]] = {}
    for contract in contracts:
        by_exp.setdefault(str(contract["expiration"]), []).append(contract)

    call_volume = sum(
        _safe_float(c.get("total_volume")) for c in contracts if c.get("option_side") == "call"
    )
    put_volume = sum(
        _safe_float(c.get("total_volume")) for c in contracts if c.get("option_side") == "put"
    )
    options_volume = call_volume + put_volume
    put_call_ratio = (put_volume / call_volume) if call_volume > 0 else None

    imp_vol = _compute_atm_iv_for_expiration(contracts, underlying_price)
    strike_spacing = _compute_strike_spacing_by_expiration(contracts)

    return {
        "symbol": symbol.upper(),
        "last_price": quote_snapshot.get("last_price"),
        "pct_change": quote_snapshot.get("pct_change"),
        "imp_vol": imp_vol,
        "iv_5d": _pick_term_iv(by_exp, underlying_price, 5),
        "iv_1m": _pick_term_iv(by_exp, underlying_price, 30),
        "iv_3m": _pick_term_iv(by_exp, underlying_price, 90),
        "iv_6m": _pick_term_iv(by_exp, underlying_price, 180),
        "options_volume": round(options_volume, 2),
        "call_volume": round(call_volume, 2),
        "put_volume": round(put_volume, 2),
        "put_call_ratio": round(put_call_ratio, 6) if put_call_ratio is not None else None,
        "strike_spacing_by_expiration": strike_spacing,
        "active_expirations": nearest_expirations,
        # Fields that need price history or proprietary models — filled by Barchart after-hours:
        "rel_strength_14d": None,
        "iv_percentile": None,
        "iv_hv_ratio": None,
        "bb_pct": None,
        "bb_rank": None,
        "ttm_squeeze": None,
        "adr_14d": None,
        "total_volume_1m": None,
        "notes": None,
        "low_flag": None,
        "high_flag": None,
        "source": "schwab",
    }


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def get_quote(symbol: str) -> Dict[str, Any]:
    client = _get_client()
    response = client.get_quote(symbol.upper())
    response.raise_for_status()
    return response.json()


def get_option_chain_raw(
    symbol: str,
    strike_count: int = 200,
    from_date: Optional[str | dt.date] = None,
    to_date: Optional[str | dt.date] = None,
    include_underlying_quote: bool = True,
) -> Dict[str, Any]:
    """
    Raw Schwab chain response.
    strike_count=200 gives single/triple-digit delta coverage on typical underlyings.
    """
    client = _get_client()
    response = client.get_option_chain(
        symbol.upper(),
        strike_count=int(strike_count),
        include_underlying_quote=include_underlying_quote,
        from_date=_parse_date(from_date),
        to_date=_parse_date(to_date),
    )
    response.raise_for_status()
    return response.json()


def get_flat_option_chain(
    symbol: str,
    strike_count: int = 200,
    from_date: Optional[str | dt.date] = None,
    to_date: Optional[str | dt.date] = None,
) -> Dict[str, Any]:
    """
    Flattened, normalized chain.  All contracts from all expirations in one list.

    Returns:
        {
          symbol, underlying_price,
          expirations: sorted list of all expiration date strings,
          strikes:     sorted list of all unique strikes,
          contracts:   list of normalized contract dicts,
          raw:         the raw Schwab response (for debugging)
        }
    """
    raw = get_option_chain_raw(
        symbol=symbol,
        strike_count=strike_count,
        from_date=from_date,
        to_date=to_date,
        include_underlying_quote=True,
    )
    underlying_price = _extract_underlying_price(raw)

    call_contracts = _flatten_contract_map(
        symbol=symbol,
        option_side="call",
        option_map=raw.get("callExpDateMap", {}),
        underlying_price=underlying_price,
    )
    put_contracts = _flatten_contract_map(
        symbol=symbol,
        option_side="put",
        option_map=raw.get("putExpDateMap", {}),
        underlying_price=underlying_price,
    )

    all_contracts = sorted(
        call_contracts + put_contracts,
        key=lambda x: (x["expiration"], x["option_side"], x["strike"]),
    )

    expirations = sorted({c["expiration"] for c in all_contracts})
    strikes = sorted({c["strike"] for c in all_contracts})

    return {
        "symbol": symbol.upper(),
        "underlying_price": round(underlying_price, 4),
        "expirations": expirations,
        "strikes": strikes,
        "contracts": all_contracts,
        "raw": raw,
    }


def get_available_expirations(symbol: str, strike_count: int = 200) -> List[str]:
    flat = get_flat_option_chain(symbol=symbol, strike_count=strike_count)
    return flat["expirations"]


def get_next_7_expirations(symbol: str, strike_count: int = 200) -> List[str]:
    return get_available_expirations(symbol=symbol, strike_count=strike_count)[:7]


# backward compat alias
get_next_7_opex = get_next_7_expirations


def refresh_symbol_from_schwab(
    symbol: str,
    strike_count: int = 200,
    max_expirations: int = 7,
) -> Dict[str, Any]:
    """
    Full refresh: quote + chain + derived snapshot.
    Called by cache_manager.  Returns a normalized symbol state dict ready to
    be upserted into the DataStore.
    """
    quote_raw = get_quote(symbol)
    flat_chain = get_flat_option_chain(symbol=symbol, strike_count=strike_count)

    nearest_expirations = _choose_nearest_expirations(
        flat_chain["expirations"], max_expirations=max_expirations
    )
    contracts = _filter_contracts_to_expirations(flat_chain["contracts"], nearest_expirations)
    filtered_strikes = sorted({c["strike"] for c in contracts})

    symbol_snapshot = build_symbol_snapshot_from_schwab(
        symbol=symbol,
        quote_raw=quote_raw,
        flat_chain=flat_chain,
        max_expirations=max_expirations,
    )

    return {
        "symbol": symbol.upper(),
        "active_chain_source": "schwab",
        "quote_source": "schwab",
        "quote_raw": quote_raw,
        "quote_snapshot": _normalize_quote_snapshot(symbol, quote_raw),
        "contracts": contracts,
        "expirations": nearest_expirations,
        "strikes": filtered_strikes,
        "underlying_price": flat_chain["underlying_price"],
        "symbol_snapshot": symbol_snapshot,
        "metadata": {
            "strike_count_requested": strike_count,
            "max_expirations": max_expirations,
            "chain_contract_count": len(contracts),
            "strike_spacing_by_expiration": symbol_snapshot.get(
                "strike_spacing_by_expiration", {}
            ),
        },
    }

'@
Write-File "backend\schwab_adapter.py" $c

$c = @'
from __future__ import annotations
from typing import Any, Dict, List, Optional
from dotenv import load_dotenv
from fastapi import FastAPI, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

load_dotenv()

from cache_manager import ensure_symbol_loaded, get_symbol_state, list_cached_symbols, manual_refresh_symbol
from field_registry import ENTRY_STRATEGIES, SCANNER_FIELDS, VALID_SORT_KEYS
from limit_engine import compute_limit_summary, compute_selected_totals
from notify import send_pushover
from positions import normalize_mock_positions
from refresh_scheduler import start_scheduler
from scanner import generate_risk_equivalent_candidates
from source_router import get_active_chain_source
from tasty_adapter import extract_net_liq, fetch_account_snapshot, normalize_live_positions
from vol_surface import build_vol_surface_payload

app = FastAPI(title="Granite Trader", version="0.5.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_credentials=True, allow_methods=["*"], allow_headers=["*"])

class SelectedRowsPayload(BaseModel):
    rows: List[Dict[str, Any]]

class AlertPayload(BaseModel):
    title: str
    message: str
    notify_whatsapp: bool = False

def _parse_expirations(expiration: str) -> Optional[List[str]]:
    exp = (expiration or "all").strip().lower()
    return None if exp == "all" else [expiration.strip()]

@app.on_event("startup")
def on_startup() -> None:
    start_scheduler()

@app.get("/health")
def health() -> Dict[str, Any]:
    return {"status": "ok", "active_chain_source": get_active_chain_source(), "cached_symbols": list_cached_symbols()}

@app.get("/account/mock")
def account_mock() -> Dict[str, Any]:
    positions = normalize_mock_positions()
    return {"source": "mock", "positions": positions, "limit_summary": compute_limit_summary(72.0, positions)}

@app.get("/account/tasty")
def account_tasty() -> Dict[str, Any]:
    try:
        snapshot = fetch_account_snapshot()
        positions = normalize_live_positions(snapshot)
        net_liq = extract_net_liq(snapshot)
        return {"source": "tasty", "positions": positions, "limit_summary": compute_limit_summary(net_liq, positions)}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.post("/totals")
def totals(payload: SelectedRowsPayload) -> Dict[str, Any]:
    return compute_selected_totals(payload.rows)

@app.get("/cache/status")
def cache_status() -> Dict[str, Any]:
    syms = list_cached_symbols()
    return {"symbols": syms, "count": len(syms), "active_chain_source": get_active_chain_source()}

@app.get("/refresh/symbol")
def refresh_symbol(symbol: str = Query(..., min_length=1), strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = manual_refresh_symbol(symbol=symbol, strike_count=strike_count)
        return {"symbol": symbol.upper(), "active_chain_source": state.get("active_chain_source"),
                "contract_count": len(state.get("contracts", [])), "expirations": state.get("expirations", []),
                "updated_at_epoch": state.get("updated_at_epoch")}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/quote/schwab")
def quote_schwab(symbol: str = Query(..., min_length=1), strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = ensure_symbol_loaded(symbol=symbol, strike_count=strike_count, requested_by="quote")
        quote_raw = state.get("quote_raw", {})
        if not quote_raw:
            raise RuntimeError(f"No quote for {symbol.upper()}")
        return quote_raw
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/chain")
def chain(symbol: str = Query(..., min_length=1), strike_count: int = Query(200, ge=25, le=500)) -> Dict[str, Any]:
    try:
        state = ensure_symbol_loaded(symbol=symbol, strike_count=strike_count, requested_by="chain")
        return {"symbol": state.get("symbol", symbol.upper()), "underlying_price": state.get("underlying_price"),
                "count": len(state.get("contracts", [])), "expirations": state.get("expirations", []),
                "strikes": state.get("strikes", []), "items": state.get("contracts", []),
                "active_chain_source": state.get("active_chain_source"), "symbol_snapshot": state.get("symbol_snapshot", {})}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/vol/surface")
def vol_surface(symbol: str = Query(..., min_length=1), max_expirations: int = Query(7, ge=1, le=20),
                strike_count: int = Query(25, ge=5, le=101)) -> Dict[str, Any]:
    try:
        return build_vol_surface_payload(symbol=symbol, max_expirations=max_expirations, strike_count=strike_count)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/scan")
def scan_legacy(symbol: str = Query("SPY"), total_risk: float = Query(600.0, gt=0),
                side: str = Query("all"), expiration: str = Query("all"),
                sort_by: str = Query("credit_pct_risk"), strike_count: int = Query(200, ge=25, le=500),
                max_results: int = Query(500, ge=1, le=2000)) -> Dict[str, Any]:
    return scan_live(symbol=symbol, total_risk=total_risk, side=side, expiration=expiration,
                     sort_by=sort_by, strike_count=strike_count, max_results=max_results)

@app.get("/scan/live")
def scan_live(symbol: str = Query(..., min_length=1), total_risk: float = Query(600.0, gt=0),
              side: str = Query("all"), expiration: str = Query("all"),
              sort_by: str = Query("credit_pct_risk"), strike_count: int = Query(200, ge=25, le=500),
              max_results: int = Query(500, ge=1, le=2000)) -> Dict[str, Any]:
    side = side.lower().strip()
    if side not in {"all", "call", "put"}:
        raise HTTPException(status_code=400, detail="side must be all, call, or put")
    sort_by = sort_by.strip().lower()
    if sort_by not in VALID_SORT_KEYS:
        raise HTTPException(status_code=400, detail=f"sort_by must be one of: {', '.join(sorted(VALID_SORT_KEYS))}")
    try:
        items = generate_risk_equivalent_candidates(
            symbol=symbol, total_risk=total_risk, expirations=_parse_expirations(expiration),
            side_filter=side, pricing_mode="conservative_mid", strike_count=strike_count,
            ranking=sort_by, max_results=max_results)
        state = get_symbol_state(symbol)
        return {"symbol": symbol.upper(), "total_risk": round(total_risk, 2), "side": side,
                "count": len(items), "items": items,
                "active_chain_source": state.get("active_chain_source"),
                "symbol_snapshot": state.get("symbol_snapshot", {})}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

@app.get("/field-registry")
def field_registry() -> Dict[str, Any]:
    return {"entry_strategies": ENTRY_STRATEGIES, "scanner_fields": SCANNER_FIELDS, "valid_sort_keys": sorted(VALID_SORT_KEYS)}

@app.post("/alerts/send")
def alerts_send(payload: AlertPayload) -> Dict[str, Any]:
    return {"desktop": True, "pushover": send_pushover(payload.message, payload.title)}

@app.post("/alerts/pushover")
def alerts_pushover(payload: AlertPayload) -> Dict[str, Any]:
    return send_pushover(payload.message, payload.title)


# ── Chart / Price History ─────────────────────────────────────

@app.get("/chart/history")
def chart_history(
    symbol: str = Query(..., min_length=1),
    period: str = Query("5y"),
    frequency: str = Query("daily"),
) -> Dict[str, Any]:
    """
    Fetch OHLCV candles for charting.
    period: 1d|5d|1m|3m|6m|1y|2y|5y|10y|ytd
    frequency: minute|5min|15min|30min|hourly|daily|weekly|monthly
    """
    try:
        from chart_adapter import get_price_history
        return get_price_history(symbol=symbol, period=period, frequency=frequency)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))

'@
Write-File "backend\main.py" $c

$c = @'
"""
chart_adapter.py — Schwab price history for the chart tile.
Fetches OHLCV candles and returns a clean list for the frontend.
"""
from __future__ import annotations

import datetime as dt
from typing import Any, Dict, List, Optional

from schwab_adapter import _get_client


def _safe_float(v: Any, default: float = 0.0) -> float:
    try:
        if v is None or v == "":
            return default
        return float(v)
    except Exception:
        return default


def get_price_history(
    symbol: str,
    period: str = "5y",          # "1d","5d","1m","3m","6m","1y","2y","5y","10y","ytd"
    frequency: str = "daily",    # "minute","daily","weekly","monthly"
) -> Dict[str, Any]:
    """
    Fetch OHLCV candles from Schwab.
    Returns: {symbol, candles:[{time,open,high,low,close,volume},...], period, frequency}
    """
    client = _get_client()

    # Map user-friendly params to Schwab API params
    period_type_map = {
        "1d": ("day", 1),
        "5d": ("day", 5),
        "1m": ("month", 1),
        "3m": ("month", 3),
        "6m": ("month", 6),
        "1y": ("year", 1),
        "2y": ("year", 2),
        "5y": ("year", 5),
        "10y": ("year", 10),
        "ytd": ("ytd", 1),
    }
    freq_map = {
        "minute":  ("minute", 1),
        "5min":    ("minute", 5),
        "15min":   ("minute", 15),
        "30min":   ("minute", 30),
        "hourly":  ("minute", 60),
        "daily":   ("daily",  1),
        "weekly":  ("weekly", 1),
        "monthly": ("monthly",1),
    }

    period_type, period_count = period_type_map.get(period, ("year", 5))
    freq_type, freq_count     = freq_map.get(frequency, ("daily", 1))

    import schwab
    resp = client.get_price_history(
        symbol.upper(),
        period_type=getattr(schwab.client.Client.PriceHistory.PeriodType, period_type.upper(), None)
            or period_type,
        period=period_count,
        frequency_type=getattr(schwab.client.Client.PriceHistory.FrequencyType, freq_type.upper(), None)
            or freq_type,
        frequency=freq_count,
        need_extended_hours_data=False,
    )

    data = resp.json() if hasattr(resp, "json") else {}
    raw_candles = data.get("candles", [])

    candles = []
    for c in raw_candles:
        epoch_ms = c.get("datetime", 0)
        if not epoch_ms:
            continue
        # Lightweight Charts expects Unix seconds for daily, ms for intraday
        epoch_s = epoch_ms // 1000
        candles.append({
            "time":   epoch_s,
            "open":   round(_safe_float(c.get("open")),   2),
            "high":   round(_safe_float(c.get("high")),   2),
            "low":    round(_safe_float(c.get("low")),    2),
            "close":  round(_safe_float(c.get("close")),  2),
            "volume": int(_safe_float(c.get("volume"), 0)),
        })

    # Sort ascending by time (Lightweight Charts requirement)
    candles.sort(key=lambda x: x["time"])

    return {
        "symbol":    symbol.upper(),
        "period":    period,
        "frequency": frequency,
        "count":     len(candles),
        "candles":   candles,
    }

'@
Write-File "backend\chart_adapter.py" $c

$c = @'
{
  "name": "granite-trader",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "tsc && vite build",
    "preview": "vite preview --port 5500"
  },
  "dependencies": {
    "plotly.js-dist-min": "^2.27.1",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-grid-layout": "^1.4.4",
    "zustand": "^4.5.2",
    "@tanstack/react-table": "^8.17.3",
    "lightweight-charts": "^4.1.7"
  },
  "devDependencies": {
    "@types/plotly.js": "^2.12.29",
    "@types/react": "^18.3.1",
    "@types/react-dom": "^18.3.1",
    "@types/react-grid-layout": "^1.3.5",
    "@vitejs/plugin-react": "^4.3.1",
    "typescript": "^5.4.5",
    "vite": "^5.3.1"
  }
}

'@
Write-File "react-frontend\package.json" $c

$c = @'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: { port: 5500, host: true },
  preview: { port: 5500, host: true },
  build: { outDir: 'dist', sourcemap: false },
})

'@
Write-File "react-frontend\vite.config.ts" $c

$c = @'
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": false,
    "noUnusedParameters": false,
    "noFallthroughCasesInSwitch": true
  },
  "include": ["src"]
}

'@
Write-File "react-frontend\tsconfig.json" $c

$c = @'
<!DOCTYPE html>
<html lang="en" data-theme="slate">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Granite Trader</title>
    <link rel="preconnect" href="https://fonts.googleapis.com" />
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
    <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=Syne:wght@600;700;800&display=swap" rel="stylesheet" />
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>

'@
Write-File "react-frontend\index.html" $c

$c = @'
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
)

'@
Write-File "react-frontend\src\main.tsx" $c

$c = @'
import { useEffect, useState, useCallback, useRef } from 'react'
import GridLayout, { type Layout } from 'react-grid-layout'
import 'react-grid-layout/css/styles.css'
import 'react-resizable/css/styles.css'
import './styles/globals.css'

import { TopBar }          from './components/layout/TopBar'
import { TotalsBar }       from './components/layout/TotalsBar'
import { WatchlistTile }   from './components/tiles/WatchlistTile'
import { PositionsTile }   from './components/tiles/PositionsTile'
import { ScannerTile }     from './components/tiles/ScannerTile'
import { VolSurfaceTile }  from './components/tiles/VolSurfaceTile'
import { ChartTile }       from './components/tiles/ChartTile'
import { SelectedLegsTile, TradeTicketTile } from './components/tiles/LegsTile'
import { AlertModal }      from './components/modals/AlertModal'

import { useStore } from './store/useStore'
import {
  fetchAccount, fetchQuote, fetchChain,
  fetchVolSurface, sendPushover,
} from './api/client'

// ── Grid layout ─────────────────────────────────────────────
const COLS   = 16
const ROW_H  = 40
const TOPBAR_H  = 72
const BOTTOM_H  = 38

const STORAGE_KEY = 'granite_layout_v2'

// Default layout optimised for 3840×1080 ultrawide (16 cols)
const DEFAULT_LAYOUT: Layout[] = [
  { i: 'watchlist', x: 0,  y: 0, w: 1,  h: 14, minW: 1, minH: 4 },
  { i: 'positions', x: 1,  y: 0, w: 5,  h: 9,  minW: 2, minH: 3 },
  { i: 'selected',  x: 1,  y: 9, w: 5,  h: 5,  minW: 2, minH: 2 },
  { i: 'scanner',   x: 6,  y: 0, w: 6,  h: 14, minW: 3, minH: 4 },
  { i: 'volsurf',   x: 12, y: 0, w: 4,  h: 14, minW: 2, minH: 4 },
  { i: 'chart',     x: 1,  y: 14,w: 11, h: 6,  minW: 3, minH: 3 },
  { i: 'ticket',    x: 12, y: 14,w: 4,  h: 6,  minW: 2, minH: 3 },
]

function loadLayout(): Layout[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (raw) return JSON.parse(raw)
  } catch {}
  return DEFAULT_LAYOUT
}

function saveLayout(l: Layout[]) {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(l)) } catch {}
}

// ── Gear icon button (renders in tile header via portal-like approach) ──────
function TileGear({ tileId, onOpen }: { tileId: string; onOpen: (id: string) => void }) {
  return (
    <button
      className="tile-gear-btn"
      title="Panel settings"
      onClick={(e) => { e.stopPropagation(); onOpen(tileId) }}
    >
      &#x2699;
    </button>
  )
}

// ── Gear settings modal ──────────────────────────────────────
const TILE_FIELDS: Record<string, { label: string; fields: { key: string; label: string }[] }> = {
  watchlist: {
    label: 'Watchlist',
    fields: [
      { key: 'sym', label: 'Symbol' },
      { key: 'price', label: 'Last Price' },
      { key: 'chg', label: '% Change' },
      { key: 'rs14', label: '14D Rel Strength' },
      { key: 'ivpct', label: 'IV Percentile' },
      { key: 'ivhv', label: 'IV/HV Ratio' },
      { key: 'iv', label: 'Imp Vol' },
      { key: 'iv1m', label: '1M IV' },
      { key: 'iv3m', label: '3M IV' },
      { key: 'bb', label: 'BB%' },
      { key: 'bbr', label: 'BB Rank' },
      { key: 'ttm', label: 'TTM Squeeze' },
      { key: 'opvol', label: 'Options Vol' },
      { key: 'callvol', label: 'Call Vol' },
      { key: 'putvol', label: 'Put Vol' },
    ],
  },
  scanner: {
    label: 'Entry Scanner',
    fields: [
      { key: 'expiration', label: 'Expiration' },
      { key: 'option_side', label: 'Side' },
      { key: 'short_strike', label: 'Short Strike' },
      { key: 'long_strike', label: 'Long Strike' },
      { key: 'width', label: 'Width' },
      { key: 'quantity', label: 'Qty' },
      { key: 'net_credit', label: 'Net Credit' },
      { key: 'actual_defined_risk', label: 'Actual Risk' },
      { key: 'max_loss', label: 'Max Loss' },
      { key: 'credit_pct_risk', label: 'Credit % Risk' },
      { key: 'short_delta', label: 'Short Delta' },
      { key: 'short_iv', label: 'Short IV' },
      { key: 'richness_score', label: 'Richness Score' },
      { key: 'limit_impact', label: 'Limit Impact' },
    ],
  },
  positions: {
    label: 'Open Positions',
    fields: [
      { key: 'underlying', label: 'Symbol' },
      { key: 'display_qty', label: 'Qty' },
      { key: 'option_type', label: 'Type' },
      { key: 'expiration', label: 'Expiration' },
      { key: 'strike', label: 'Strike' },
      { key: 'mark', label: 'Mark' },
      { key: 'trade_price', label: 'Trade Price' },
      { key: 'pnl_open', label: 'P/L Open' },
      { key: 'short_value', label: 'Short Value' },
      { key: 'long_cost', label: 'Long Cost' },
      { key: 'limit_impact', label: 'Limit Impact' },
    ],
  },
}

function GearModal({ tileId, onClose }: { tileId: string; onClose: () => void }) {
  const storageKey = `granite_cols_${tileId}`
  const info = TILE_FIELDS[tileId]

  const [hidden, setHidden] = useState<Set<string>>(() => {
    try {
      return new Set(JSON.parse(localStorage.getItem(storageKey) || '[]'))
    } catch { return new Set() }
  })

  function toggle(key: string) {
    setHidden(prev => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key)
      else next.add(key)
      localStorage.setItem(storageKey, JSON.stringify([...next]))
      return next
    })
  }

  if (!info) return null

  return (
    <div className="modal-overlay" onClick={e => { if (e.target === e.currentTarget) onClose() }}>
      <div className="modal-box gear-modal">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
          <span className="modal-title">&#x2699; {info.label} Settings</span>
          <button className="btn sm" onClick={onClose}>&#x2715;</button>
        </div>
        <div style={{ fontSize: 10, color: 'var(--muted)', marginBottom: 10 }}>
          Toggle columns / fields. Selections saved automatically.
        </div>
        <div className="gear-field-list">
          {info.fields.map(f => (
            <div key={f.key} className="gear-field-row">
              <input
                type="checkbox"
                id={`gear-${f.key}`}
                checked={!hidden.has(f.key)}
                onChange={() => toggle(f.key)}
              />
              <label htmlFor={`gear-${f.key}`}>{f.label}</label>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}

// ── Wrapped tile with focus border and gear icon ─────────────
function TileWrapper({
  id, children, focusedTile, setFocusedTile, onGearOpen,
}: {
  id: string
  children: React.ReactNode
  focusedTile: string | null
  setFocusedTile: (id: string) => void
  onGearOpen: (id: string) => void
}) {
  const isFocused = focusedTile === id

  return (
    <div
      className={`tile${isFocused ? ' tile-focused' : ''}`}
      style={{ height: '100%' }}
      onMouseDown={() => setFocusedTile(id)}
    >
      {children}
    </div>
  )
}

// ── Main App ────────────────────────────────────────────────

export default function App() {
  const {
    acctSource, activeSymbol, refreshInterval, refreshCountdown,
    alertRules, alertsMaster, desktopAllowed,
    setPositions, setPositionsLoading, setPositionsError,
    setQuote, setScanExpOptions, setVolData, setVolLoading, setVolError,
    setActiveSymbol, setLivePrice, markAlertTriggered,
    tickCountdown, resetCountdown,
  } = useStore()

  const [layout, setLayout]         = useState<Layout[]>(loadLayout)
  const [alertsOpen, setAlertsOpen] = useState(false)
  const [alertPreSym, setAlertPreSym] = useState<string | undefined>()
  const [gearTile, setGearTile]     = useState<string | null>(null)
  const [focusedTile, setFocusedTile] = useState<string | null>(null)
  const [workspaceH, setWorkspaceH] = useState(window.innerHeight - TOPBAR_H - BOTTOM_H)

  useEffect(() => {
    const onResize = () => setWorkspaceH(window.innerHeight - TOPBAR_H - BOTTOM_H)
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [])

  // ── Data loading ─────────────────────────────────────────

  const loadPositions = useCallback(async () => {
    setPositionsLoading(true)
    setPositionsError(null)
    try {
      const d = await fetchAccount(acctSource)
      setPositions(d.positions, d.limit_summary)
    } catch (e: any) {
      setPositionsError(e.message)
    } finally {
      setPositionsLoading(false)
    }
  }, [acctSource])

  const loadQuote = useCallback(async (sym: string) => {
    try {
      const raw = await fetchQuote(sym)
      const payload = raw[sym] ?? raw[sym.toUpperCase()] ?? {}
      const q = (payload as any).quote ?? payload
      const last   = Number(q.lastPrice || q.mark || q.closePrice || 0) || null
      const open   = Number(q.openPrice  || 0) || null
      const high   = Number(q.highPrice  || 0) || null
      const low    = Number(q.lowPrice   || 0) || null
      const chg    = Number(q.netChange  || 0)
      const pctChg = q.closePrice ? chg / Number(q.closePrice) : 0

      setQuote({ symbol: sym, lastPrice: last, openPrice: open, highPrice: high, lowPrice: low, netChange: chg, netPctChange: pctChg, bid: Number(q.bidPrice || 0) || null, ask: Number(q.askPrice || 0) || null, activeSource: 'SCHWAB' })
      if (last) setLivePrice(sym, last, pctChg)
      checkAlerts(sym, { price: last ?? 0 })
    } catch (e: any) {
      console.error('Quote error:', e.message)
    }
  }, [])

  const loadChain = useCallback(async (sym: string) => {
    try {
      const d = await fetchChain(sym)
      setScanExpOptions(d.expirations.slice(0, 7))
      setQuote({ activeSource: d.active_chain_source?.toUpperCase() ?? 'SCHWAB' })
    } catch (e: any) {
      console.error('Chain error:', e.message)
    }
  }, [])

  const loadVolSurface = useCallback(async (sym: string) => {
    setVolLoading(true); setVolError(null)
    try {
      const d = await fetchVolSurface(sym, 7, 25)
      setVolData(d)
      // Compute ATM straddle from near-exp data for expected move lines
      if (d.expirations.length && d.underlying_price) {
        const price = d.underlying_price
        const exp   = d.expirations[0]
        const curve = d.skew_curves?.[exp] ?? []
        const sorted = [...curve].sort((a, b) => Math.abs(a.strike - price) - Math.abs(b.strike - price))
        const atm = sorted.slice(0, 2)
        const avgIV = atm.reduce((s, x) => s + ((x.call_iv ?? 0) + (x.put_iv ?? 0)) / 2, 0) / Math.max(atm.length, 1)
        const approxStraddle = avgIV * price * Math.sqrt(5 / 365)
        if (approxStraddle > 0) setQuote({ atmStraddle: approxStraddle })
      }
    } catch (e: any) { setVolError(e.message) }
    finally { setVolLoading(false) }
  }, [])

  function checkAlerts(sym: string, ctx: { price: number }) {
    if (!alertsMaster) return
    alertRules.filter(a => a.active && !a.triggered).forEach(a => {
      if (a.field !== 'price' || a.sym !== sym) return
      const ops: Record<string, (v: number) => boolean> = {
        lt: v => v < a.val, lte: v => v <= a.val, eq: v => v === a.val,
        gte: v => v >= a.val, gt: v => v > a.val,
      }
      if (ops[a.op]?.(ctx.price)) {
        markAlertTriggered(a.id)
        const msg = `${sym}: Price ${ctx.price.toFixed(2)} ${a.op} ${a.val}`
        if (desktopAllowed) new Notification('Granite Alert', { body: msg })
        sendPushover('Granite Alert', msg)
      }
    })
  }

  // ── Symbol orchestrator ───────────────────────────────────

  const loadSymbol = useCallback(async (sym: string) => {
    setActiveSymbol(sym)
    setFocusedTile('scanner') // shift focus to scanner on symbol load
    await Promise.all([loadQuote(sym), loadChain(sym), loadVolSurface(sym)])
  }, [loadQuote, loadChain, loadVolSurface])

  const scanSymbol = useCallback(async (sym: string) => {
    setActiveSymbol(sym)
    setFocusedTile('scanner')
    await Promise.all([loadQuote(sym), loadChain(sym)])
  }, [loadQuote, loadChain])

  // ── Full refresh ──────────────────────────────────────────

  const fullRefresh = useCallback(async () => {
    await loadPositions()
    await loadQuote(activeSymbol)
    resetCountdown()
  }, [loadPositions, loadQuote, activeSymbol])

  // ── Auto-refresh countdown ────────────────────────────────
  useEffect(() => {
    const t = setInterval(tickCountdown, 1000)
    return () => clearInterval(t)
  }, [])

  useEffect(() => {
    if (refreshCountdown <= 0) fullRefresh()
  }, [refreshCountdown])

  // ── Initial load ──────────────────────────────────────────
  useEffect(() => {
    loadPositions()
    loadSymbol('SPY')
    Notification.requestPermission()
  }, [])

  // ── Layout persistence ────────────────────────────────────
  function onLayoutChange(nl: Layout[]) { setLayout(nl); saveLayout(nl) }
  function resetLayout() { setLayout(DEFAULT_LAYOUT); saveLayout(DEFAULT_LAYOUT) }

  const gridW = window.innerWidth

  return (
    <div className="app-shell">
      <TopBar onRefreshNow={fullRefresh} onAlertsOpen={() => setAlertsOpen(true)} />

      <div style={{ flex: 1, overflow: 'hidden', position: 'relative', background: 'var(--bg)' }}>
        <GridLayout
          layout={layout}
          cols={COLS}
          rowHeight={ROW_H}
          width={gridW}
          margin={[4, 4]}
          containerPadding={[4, 4]}
          onLayoutChange={onLayoutChange}
          draggableHandle=".tile-hdr"
          resizeHandles={['se']}
          style={{ minHeight: workspaceH }}
        >
          <div key="watchlist">
            <TileWrapper id="watchlist" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <WatchlistTile
                onSymbolLoad={loadSymbol}
                onAlertOpen={(sym) => { setAlertPreSym(sym); setAlertsOpen(true) }}
                onScanSymbol={scanSymbol}
              />
            </TileWrapper>
          </div>

          <div key="positions">
            <TileWrapper id="positions" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <PositionsTile />
            </TileWrapper>
          </div>

          <div key="selected">
            <TileWrapper id="selected" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <SelectedLegsTile />
            </TileWrapper>
          </div>

          <div key="scanner">
            <TileWrapper id="scanner" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <ScannerTile />
            </TileWrapper>
          </div>

          <div key="volsurf">
            <TileWrapper id="volsurf" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <VolSurfaceTile />
            </TileWrapper>
          </div>

          <div key="chart">
            <TileWrapper id="chart" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <ChartTile />
            </TileWrapper>
          </div>

          <div key="ticket">
            <TileWrapper id="ticket" focusedTile={focusedTile} setFocusedTile={setFocusedTile} onGearOpen={setGearTile}>
              <TradeTicketTile />
            </TileWrapper>
          </div>
        </GridLayout>
      </div>

      <TotalsBar
        onRefreshNow={fullRefresh}
        onAlertsOpen={() => setAlertsOpen(true)}
        onResetLayout={resetLayout}
      />

      {alertsOpen && (
        <AlertModal
          onClose={() => { setAlertsOpen(false); setAlertPreSym(undefined) }}
          prefilledSym={alertPreSym}
        />
      )}

      {gearTile && <GearModal tileId={gearTile} onClose={() => setGearTile(null)} />}
    </div>
  )
}

'@
Write-File "react-frontend\src\App.tsx" $c

$c = @'
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

'@
Write-File "react-frontend\src\types\index.ts" $c

$c = @'
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

// ── Account ──────────────────────────────────────────────
export async function fetchAccount(source: 'mock' | 'tasty'): Promise<{
  source: string
  positions: Position[]
  limit_summary: LimitSummary
}> {
  return get(`/account/${source}`)
}

// ── Quote ─────────────────────────────────────────────────
export async function fetchQuote(symbol: string): Promise<Record<string, { quote: Record<string, number> }>> {
  return get(`/quote/schwab?symbol=${encodeURIComponent(symbol)}`)
}

// ── Chain ─────────────────────────────────────────────────
export async function fetchChain(symbol: string): Promise<{
  symbol: string
  underlying_price: number
  expirations: string[]
  strikes: number[]
  active_chain_source: string
}> {
  return get(`/chain?symbol=${encodeURIComponent(symbol)}`)
}

// ── Refresh ───────────────────────────────────────────────
export async function refreshSymbol(symbol: string): Promise<{
  symbol: string
  active_chain_source: string
  contract_count: number
  expirations: string[]
}> {
  return get(`/refresh/symbol?symbol=${encodeURIComponent(symbol)}`)
}

// ── Scanner ───────────────────────────────────────────────
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

// ── Vol Surface ───────────────────────────────────────────
export async function fetchVolSurface(symbol: string, maxExp = 7, strikeCount = 25): Promise<VolSurfaceData> {
  return get(`/vol/surface?symbol=${encodeURIComponent(symbol)}&max_expirations=${maxExp}&strike_count=${strikeCount}`)
}

// ── Alerts ────────────────────────────────────────────────
export async function sendPushover(title: string, message: string): Promise<void> {
  await post('/alerts/pushover', { title, message, notify_whatsapp: false })
}

// ── Health ────────────────────────────────────────────────
export async function fetchHealth(): Promise<{ status: string; active_chain_source: string }> {
  return get('/health')
}

// ── Chart / Price History ─────────────────────────────────────
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

'@
Write-File "react-frontend\src\api\client.ts" $c

$c = @'
import { create } from 'zustand'
import type { AlertRule, LimitSummary, Position, ScanResult, Theme, VolSurfaceData, WatchlistRow } from '../types'

interface QuoteState {
  symbol: string
  lastPrice: number | null
  openPrice: number | null
  highPrice: number | null
  lowPrice: number | null
  netChange: number | null
  netPctChange: number | null
  bid: number | null
  ask: number | null
  atmStraddle: number | null   // ATM call + put mid — for expected move lines
  activeSource: string
}

interface AppState {
  // Account
  acctSource: 'mock' | 'tasty'
  positions: Position[]
  limitSummary: LimitSummary | null
  positionsLoading: boolean
  positionsError: string | null

  // Quote / symbol
  activeSymbol: string
  quote: QuoteState

  // Scanner
  scanResults: ScanResult[]
  scanLoading: boolean
  scanError: string | null
  scanExpOptions: string[]

  // Vol surface
  volData: VolSurfaceData | null
  volLoading: boolean
  volError: string | null

  // Selection
  selectedIds: Set<string>

  // Alerts
  alertRules: AlertRule[]
  alertsMaster: boolean
  desktopAllowed: boolean

  // Theme
  theme: Theme

  // Refresh
  refreshInterval: number  // seconds
  refreshCountdown: number

  // Watchlist live prices (keyed by symbol)
  livePrices: Record<string, { last: number; pct: number }>
}

interface AppActions {
  setAcctSource: (src: 'mock' | 'tasty') => void
  setPositions: (positions: Position[], summary: LimitSummary) => void
  setPositionsLoading: (v: boolean) => void
  setPositionsError: (e: string | null) => void

  setActiveSymbol: (sym: string) => void
  setQuote: (q: Partial<QuoteState>) => void

  setScanResults: (items: ScanResult[]) => void
  setScanLoading: (v: boolean) => void
  setScanError: (e: string | null) => void
  setScanExpOptions: (exps: string[]) => void

  setVolData: (d: VolSurfaceData | null) => void
  setVolLoading: (v: boolean) => void
  setVolError: (e: string | null) => void

  toggleSelected: (id: string) => void
  clearSelected: () => void

  addAlertRule: (rule: Omit<AlertRule, 'id' | 'triggered'>) => void
  toggleAlertRule: (id: number, active: boolean) => void
  deleteAlertRule: (id: number) => void
  markAlertTriggered: (id: number) => void
  setAlertsMaster: (v: boolean) => void
  setDesktopAllowed: (v: boolean) => void

  setTheme: (t: Theme) => void
  setRefreshInterval: (secs: number) => void
  tickCountdown: () => void
  resetCountdown: () => void

  setLivePrice: (sym: string, last: number, pct: number) => void
}

const INITIAL_QUOTE: QuoteState = {
  symbol: 'SPY',
  lastPrice: null,
  openPrice: null,
  highPrice: null,
  lowPrice: null,
  netChange: null,
  netPctChange: null,
  bid: null,
  ask: null,
  atmStraddle: null,
  activeSource: '--',
}

export const useStore = create<AppState & AppActions>((set, get) => ({
  // State
  acctSource: 'mock',
  positions: [],
  limitSummary: null,
  positionsLoading: false,
  positionsError: null,

  activeSymbol: 'SPY',
  quote: INITIAL_QUOTE,

  scanResults: [],
  scanLoading: false,
  scanError: null,
  scanExpOptions: [],

  volData: null,
  volLoading: false,
  volError: null,

  selectedIds: new Set(),

  alertRules: [],
  alertsMaster: true,
  desktopAllowed: false,

  theme: 'slate',
  refreshInterval: 300,
  refreshCountdown: 300,

  livePrices: {},

  // Actions
  setAcctSource: (src) => set({ acctSource: src }),
  setPositions: (positions, limitSummary) => set({ positions, limitSummary }),
  setPositionsLoading: (v) => set({ positionsLoading: v }),
  setPositionsError: (e) => set({ positionsError: e }),

  setActiveSymbol: (sym) => set({ activeSymbol: sym.toUpperCase() }),
  setQuote: (q) => set((s) => ({ quote: { ...s.quote, ...q } })),

  setScanResults: (items) => set({ scanResults: items }),
  setScanLoading: (v) => set({ scanLoading: v }),
  setScanError: (e) => set({ scanError: e }),
  setScanExpOptions: (exps) => set({ scanExpOptions: exps }),

  setVolData: (d) => set({ volData: d }),
  setVolLoading: (v) => set({ volLoading: v }),
  setVolError: (e) => set({ volError: e }),

  toggleSelected: (id) =>
    set((s) => {
      const next = new Set(s.selectedIds)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return { selectedIds: next }
    }),
  clearSelected: () => set({ selectedIds: new Set() }),

  addAlertRule: (rule) =>
    set((s) => ({
      alertRules: [...s.alertRules, { ...rule, id: Date.now(), triggered: false }],
    })),
  toggleAlertRule: (id, active) =>
    set((s) => ({ alertRules: s.alertRules.map((r) => (r.id === id ? { ...r, active } : r)) })),
  deleteAlertRule: (id) =>
    set((s) => ({ alertRules: s.alertRules.filter((r) => r.id !== id) })),
  markAlertTriggered: (id) =>
    set((s) => ({ alertRules: s.alertRules.map((r) => (r.id === id ? { ...r, triggered: true } : r)) })),
  setAlertsMaster: (v) => set({ alertsMaster: v }),
  setDesktopAllowed: (v) => set({ desktopAllowed: v }),

  setTheme: (t) => {
    document.documentElement.setAttribute('data-theme', t)
    set({ theme: t })
  },
  setRefreshInterval: (secs) => set({ refreshInterval: secs, refreshCountdown: secs }),
  tickCountdown: () =>
    set((s) => ({ refreshCountdown: Math.max(0, s.refreshCountdown - 1) })),
  resetCountdown: () => set((s) => ({ refreshCountdown: s.refreshInterval })),

  setLivePrice: (sym, last, pct) =>
    set((s) => ({ livePrices: { ...s.livePrices, [sym]: { last, pct } } })),
}))

'@
Write-File "react-frontend\src\store\useStore.ts" $c

$c = @'
/* ── Fonts & Reset ──────────────────────────────────────── */
@import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=Syne:wght@600;700;800&display=swap');

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

/* ── Themes ─────────────────────────────────────────────── */
:root, [data-theme="slate"] {
  --bg:#07090e;--bg1:#0c1018;--bg2:#111820;--bg3:#16202c;
  --border:#1c2b3a;--bord2:#243448;--text:#cbd9e8;--muted:#6e8aa0;
  --accent:#4d9fff;--green:#3bba6c;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;
  --focus-border:#4d9fff;
}
[data-theme="navy"]{--bg:#02071a;--bg1:#060d24;--bg2:#0b142e;--bg3:#101c38;--border:#182648;--bord2:#203058;--text:#c8d2f0;--muted:#5870b0;--accent:#6888ff;--green:#3bba6c;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;--focus-border:#6888ff}
[data-theme="emerald"]{--bg:#040c08;--bg1:#091410;--bg2:#0e1c16;--bg3:#13241c;--border:#182e22;--bord2:#213c2e;--text:#c0d8c8;--muted:#5a906a;--accent:#3bba6c;--green:#4d9fff;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;--focus-border:#3bba6c}
[data-theme="teal"]{--bg:#030d0d;--bg1:#071616;--bg2:#0c1e1e;--bg3:#112626;--border:#183232;--bord2:#204040;--text:#b8d4d4;--muted:#508080;--accent:#2bcece;--green:#3bba6c;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;--focus-border:#2bcece}
[data-theme="amber"]{--bg:#0e0b04;--bg1:#161208;--bg2:#1e180c;--bg3:#261e10;--border:#3a2e0e;--bord2:#4e3e14;--text:#ddd0a8;--muted:#968850;--accent:#e5b84c;--green:#3bba6c;--red:#f04f48;--warn:#f04f48;--gold:#4d9fff;--focus-border:#e5b84c}
[data-theme="rose"]{--bg:#0e0508;--bg1:#16080d;--bg2:#1e0d14;--bg3:#26121b;--border:#3a1420;--bord2:#4e1c2c;--text:#ddc4cc;--muted:#985060;--accent:#f04f48;--green:#3bba6c;--red:#ff4444;--warn:#d4972a;--gold:#e5b84c;--focus-border:#f04f48}
[data-theme="purple"]{--bg:#08060e;--bg1:#0c0a18;--bg2:#120e20;--bg3:#181228;--border:#261c40;--bord2:#342454;--text:#d0c4e8;--muted:#806898;--accent:#9868f8;--green:#3bba6c;--red:#f04f48;--warn:#d4972a;--gold:#e5b84c;--focus-border:#9868f8}
[data-theme="mono"]{--bg:#060606;--bg1:#0e0e0e;--bg2:#161616;--bg3:#1e1e1e;--border:#282828;--bord2:#343434;--text:#cccccc;--muted:#686868;--accent:#b0b0b0;--green:#909090;--red:#787878;--warn:#888888;--gold:#cccccc;--focus-border:#c0c0c0}

/* ── Base ────────────────────────────────────────────────── */
html, body, #root { height: 100%; overflow: hidden; background: var(--bg); color: var(--text); font-family: 'IBM Plex Mono', 'Courier New', monospace; font-size: 13px; line-height: 1.4; -webkit-font-smoothing: antialiased; }
::-webkit-scrollbar { width: 4px; height: 4px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--bord2); border-radius: 2px; }
input,select,button { font-family: inherit; }
input[type=text],input[type=number],select { background: var(--bg3); color: var(--text); border: 1px solid var(--bord2); border-radius: 3px; padding: 4px 8px; font-size: 12px; outline: none; width: 100%; }
input:focus,select:focus { border-color: var(--accent); }

/* ── Typography ──────────────────────────────────────────── */
.font-display { font-family: 'Syne', sans-serif; }
.text-accent { color: var(--accent); }
.text-green  { color: var(--green); }
.text-red    { color: var(--red); }
.text-warn   { color: var(--warn); }
.text-muted  { color: var(--muted); }
.text-gold   { color: var(--gold); }

/* ── App shell ───────────────────────────────────────────── */
.app-shell { display: flex; flex-direction: column; height: 100%; overflow: hidden; }

/* ── TOPBAR — doubled height ─────────────────────────────── */
.topbar {
  display: grid;
  grid-template-columns: auto 1fr auto;
  align-items: center;
  padding: 0 12px;
  height: 72px;
  background: var(--bg1);
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
  z-index: 9999;
  position: relative;
  gap: 16px;
}
.topbar-left  { display: flex; align-items: center; gap: 8px; }
.topbar-center { display: flex; flex-direction: column; align-items: center; justify-content: center; min-width: 280px; }
.topbar-right { display: flex; align-items: center; gap: 8px; justify-content: flex-end; }
.topbar-brand { font-family: 'Syne', sans-serif; font-weight: 800; font-size: 18px; color: var(--accent); letter-spacing: 0.08em; white-space: nowrap; }
.topbar-price-big { font-size: 36px; font-weight: 700; letter-spacing: -0.02em; line-height: 1; }
.topbar-sym { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.1em; }
.topbar-chg { font-size: 16px; font-weight: 600; }
.tpill { display: flex; flex-direction: column; padding: 3px 10px; background: var(--bg2); border: 1px solid var(--border); border-radius: 4px; min-width: 80px; }
.tpill .lbl { font-size: 9px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; }
.tpill .val { font-size: 13px; font-weight: 600; }
.tsep { width: 1px; height: 28px; background: var(--border); margin: 0 2px; }

/* ── BOTTOM BAR ──────────────────────────────────────────── */
.bottombar {
  display: flex;
  align-items: center;
  gap: 4px;
  padding: 4px 10px;
  background: var(--bg1);
  border-top: 1px solid var(--border);
  flex-shrink: 0;
  z-index: 9999;
  position: relative;
  flex-wrap: wrap;
}
.tchip { display: flex; flex-direction: column; padding: 2px 8px; border: 1px solid var(--border); border-radius: 3px; background: var(--bg2); min-width: 72px; }
.tchip .tl { font-size: 8px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.06em; }
.tchip .tv { font-size: 12px; font-weight: 600; }

/* ── Buttons ─────────────────────────────────────────────── */
.btn { padding: 4px 12px; border: 1px solid var(--bord2); border-radius: 3px; background: var(--bg2); color: var(--text); cursor: pointer; font-family: 'IBM Plex Mono', monospace; font-size: 11px; font-weight: 600; white-space: nowrap; transition: border-color 0.1s, color 0.1s, background 0.1s; }
.btn:hover { border-color: var(--accent); color: var(--accent); }
.btn.primary { background: var(--accent); color: var(--bg); border-color: var(--accent); }
.btn.primary:hover { opacity: 0.85; }
.btn.sm { padding: 2px 8px; font-size: 10px; }
.btn.active { background: var(--accent); color: var(--bg); border-color: var(--accent); }

/* ── Tiles ───────────────────────────────────────────────── */
.tile {
  background: var(--bg1);
  border: 1px solid var(--border);
  border-radius: 5px;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  box-shadow: 0 4px 24px rgba(0,0,0,0.5);
  transition: border-color 0.12s;
}
/* FOCUSED TILE — accent-colored top border */
.tile.tile-focused {
  border-color: var(--bord2);
  border-top: 2px solid var(--focus-border);
}

.tile-hdr {
  display: flex;
  align-items: center;
  gap: 5px;
  padding: 4px 8px;
  background: var(--bg2);
  border-bottom: 1px solid var(--border);
  flex-shrink: 0;
  min-height: 28px;
  cursor: grab;
  user-select: none;
  position: relative;
}
.tile-hdr:active { cursor: grabbing; }
.tile-title { font-family: 'Syne', sans-serif; font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.12em; color: var(--accent); pointer-events: none; white-space: nowrap; }
.tile-body { flex: 1; overflow: auto; min-height: 0; display: flex; flex-direction: column; }
.tile-gear-btn { margin-left: auto; background: none; border: none; cursor: pointer; color: var(--muted); font-size: 13px; padding: 0 2px; line-height: 1; transition: color 0.1s; }
.tile-gear-btn:hover { color: var(--text); }

/* ── Tables ──────────────────────────────────────────────── */
.data-table { width: 100%; border-collapse: collapse; font-size: 12px; }
.data-table th, .data-table td { padding: 4px 8px; text-align: right; border-bottom: 1px solid #0c1422; white-space: nowrap; }
.data-table th:first-child, .data-table td:first-child { text-align: left; }
.data-table thead th { position: sticky; top: 0; background: #08101a; color: var(--muted); font-size: 10px; text-transform: uppercase; letter-spacing: 0.05em; font-weight: 500; z-index: 2; cursor: pointer; padding: 5px 8px; }
.data-table thead th:hover { color: var(--text); }
.data-table thead th.sort-asc::after  { content: " \25B2"; color: var(--accent); }
.data-table thead th.sort-desc::after { content: " \25BC"; color: var(--accent); }
.data-table tbody tr:hover { background: #0c1825; }
.data-table .group-row td { background: #070e18; color: var(--accent); font-family: 'Syne', sans-serif; font-size: 10px; font-weight: 700; letter-spacing: 0.04em; padding: 4px 8px; }

/* ── Watchlist ───────────────────────────────────────────── */
.wl-filter-input { width: 100%; padding: 5px 10px; background: var(--bg2); border: none; border-bottom: 1px solid var(--border); font-size: 12px; color: var(--text); outline: none; }
.wl-row { display: grid; gap: 0; padding: 4px 6px; border-bottom: 1px solid #0a1420; cursor: pointer; align-items: center; font-size: 12px; }
.wl-row:hover { background: var(--bg3); }
.wl-row.active { background: #0e2240; border-left: 2px solid var(--accent); }
.wl-row-compact { grid-template-columns: 54px 62px 56px 1fr; }
.wl-row-full { grid-template-columns: 54px 56px 54px 38px 34px 44px 50px 46px 46px 46px 46px 38px 80px 44px 40px 58px 52px 48px 80px 80px 80px 1fr; }
.wl-cell { text-align: right; font-size: 11px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.wl-cell:first-child { text-align: left; font-weight: 600; font-size: 12px; }
.wl-hdr { display: grid; padding: 3px 6px; background: #070c16; border-bottom: 1px solid var(--border); position: sticky; top: 0; z-index: 3; }
.wl-hdr-c { grid-template-columns: 54px 62px 56px 1fr; }
.wl-hdr-f { grid-template-columns: 54px 56px 54px 38px 34px 44px 50px 46px 46px 46px 46px 38px 80px 44px 40px 58px 52px 48px 80px 80px 80px 1fr; }
.wl-hdr span { font-size: 8px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.04em; text-align: right; }
.wl-hdr span:first-child { text-align: left; }

/* Watchlist action icons */
.wl-actions { display: flex; gap: 3px; justify-content: flex-end; align-items: center; }
.wl-icon-btn { background: none; border: none; cursor: pointer; font-size: 11px; padding: 1px 2px; color: var(--muted); transition: color 0.1s; line-height: 1; border-radius: 2px; }
.wl-icon-btn:hover { color: var(--accent); background: var(--bg3); }

/* Expected move range bar */
.em-bar-wrap { display: flex; align-items: center; gap: 4px; }
.em-bar { height: 6px; background: var(--border); border-radius: 3px; position: relative; flex: 1; min-width: 40px; overflow: hidden; }
.em-bar-inner { position: absolute; height: 100%; background: var(--accent); opacity: 0.4; border-radius: 3px; }
.em-bar-price { position: absolute; width: 2px; height: 100%; background: var(--text); border-radius: 1px; }

/* ── Side badges ─────────────────────────────────────────── */
.side-badge { display: inline-block; padding: 1px 6px; border-radius: 2px; font-size: 10px; font-weight: 700; letter-spacing: 0.04em; }
.side-badge.call { background: rgba(59,186,108,0.12); color: var(--green); border: 1px solid var(--green); }
.side-badge.put  { background: rgba(240,79,72,0.12);  color: var(--red);   border: 1px solid var(--red); }

/* ── Theme dots ──────────────────────────────────────────── */
.theme-dot { width: 16px; height: 16px; border-radius: 3px; cursor: pointer; border: 2px solid transparent; transition: all 0.1s; flex-shrink: 0; }
.theme-dot:hover { transform: scale(1.2); }
.theme-dot.active { border-color: white; }

/* ── Modals ──────────────────────────────────────────────── */
.modal-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.8); z-index: 99999; display: flex; align-items: center; justify-content: center; }
.modal-box { background: var(--bg1); border: 1px solid var(--bord2); border-radius: 8px; padding: 20px; min-width: 480px; max-width: 660px; max-height: 80vh; overflow-y: auto; }
.modal-title { font-family: 'Syne', sans-serif; font-size: 13px; font-weight: 700; color: var(--accent); text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 14px; }

/* Gear settings panel */
.gear-modal { min-width: 340px; max-width: 440px; }
.gear-field-list { display: flex; flex-direction: column; gap: 4px; max-height: 320px; overflow-y: auto; }
.gear-field-row { display: flex; align-items: center; gap: 8px; padding: 4px 6px; border-radius: 3px; font-size: 12px; }
.gear-field-row:hover { background: var(--bg3); }
.gear-field-row label { cursor: pointer; flex: 1; }

/* ── Vol surface ─────────────────────────────────────────── */
.vs-tabs { display: flex; gap: 3px; padding: 5px 8px; border-bottom: 1px solid var(--border); flex-shrink: 0; }
.richness-row { display: flex; gap: 5px; padding: 5px; flex-wrap: nowrap; overflow-x: auto; border-bottom: 1px solid var(--border); flex-shrink: 0; min-height: 64px; }
.rcard { padding: 4px 8px; background: var(--bg2); border: 1px solid var(--border); border-radius: 3px; cursor: pointer; flex-shrink: 0; min-width: 86px; }
.rcard:hover { border-color: var(--accent); }

/* ── Scanner controls ────────────────────────────────────── */
.scan-controls { display: grid; grid-template-columns: repeat(3,1fr); gap: 5px; padding: 7px; border-bottom: 1px solid var(--border); background: var(--bg1); flex-shrink: 0; }
.scan-actions { display: flex; gap: 5px; padding: 5px 7px; border-bottom: 1px solid var(--border); flex-shrink: 0; align-items: center; }
.ctrl-group { display: flex; flex-direction: column; }
.ctrl-group label { font-size: 9px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; display: block; margin-bottom: 2px; }

/* ── Trade ticket ────────────────────────────────────────── */
.strat-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 3px; padding: 7px; flex-shrink: 0; }
.strat-btn { padding: 5px; text-align: center; border: 1px solid var(--bord2); border-radius: 3px; cursor: pointer; font-size: 11px; color: var(--muted); background: var(--bg2); transition: all 0.1s; }
.strat-btn:hover { border-color: var(--accent); color: var(--accent); }
.strat-btn.active { background: var(--accent); color: var(--bg); border-color: var(--accent); font-weight: 700; }

/* ── Chart ───────────────────────────────────────────────── */
.chart-ph { display: flex; flex-direction: column; align-items: center; justify-content: center; flex: 1; color: var(--muted); gap: 6px; }

/* ── Misc ────────────────────────────────────────────────── */
.error-msg  { color: var(--red);   padding: 7px 10px; font-size: 11px; }
.empty-msg  { color: var(--muted); padding: 20px 16px; text-align: center; font-size: 12px; }
.loading    { color: var(--muted); padding: 20px 16px; text-align: center; font-size: 11px; animation: pulse 1.5s infinite; }
.tbl-wrap   { overflow: auto; flex: 1; }
@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.4} }

/* ── RGL overrides ───────────────────────────────────────── */
.react-grid-layout { position: relative; }
.react-grid-item { transition: none; box-sizing: border-box; }
.react-grid-item.react-draggable-dragging { transition: none; z-index: 3; }
.react-grid-item > .react-resizable-handle { position: absolute; bottom: 2px; right: 2px; width: 14px; height: 14px; cursor: nw-resize; background: linear-gradient(135deg, transparent 50%, var(--bord2) 50%); border-radius: 0 0 4px 0; opacity: 0.5; }
.react-grid-item > .react-resizable-handle:hover { opacity: 1; }

'@
Write-File "react-frontend\src\styles\globals.css" $c

$c = @'
import type { WatchlistRow } from '../types'

export const WL_DATA: WatchlistRow[] = [
  {
    "sym": "ANF",
    "price": "94.5",
    "chg": "-3.95%",
    "rs14": "51.53",
    "ivpct": "33%",
    "ivhv": "1.0333209723939",
    "iv": "50.14%",
    "iv5d": "50.04%",
    "iv1m": "52.42%",
    "iv3m": "59.12%",
    "iv6m": "57.95%",
    "bb": "63%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.18",
    "opvol": "1662",
    "callvol": "892",
    "putvol": "770"
  },
  {
    "sym": "NEM",
    "price": "116.69",
    "chg": "-3.48%",
    "rs14": "56.36",
    "ivpct": "84%",
    "ivhv": "1.0898165137615",
    "iv": "53.83%",
    "iv5d": "54.02%",
    "iv1m": "54.56%",
    "iv3m": "54.56%",
    "iv6m": "48.93%",
    "bb": "78%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "3.88",
    "opvol": "11214",
    "callvol": "6579",
    "putvol": "4635"
  },
  {
    "sym": "TGT",
    "price": "118.38",
    "chg": "-2.88%",
    "rs14": "49.29",
    "ivpct": "16%",
    "ivhv": "1.0824552341598",
    "iv": "31.25%",
    "iv5d": "30.87%",
    "iv1m": "32.35%",
    "iv3m": "37.82%",
    "iv6m": "38.36%",
    "bb": "48%",
    "bbr": "New Below Mid",
    "ttm": "0",
    "adr14": "3.08",
    "opvol": "17643",
    "callvol": "9330",
    "putvol": "8313"
  },
  {
    "sym": "CIEN",
    "price": "482.87",
    "chg": "-2.65%",
    "rs14": "64.88",
    "ivpct": "82%",
    "ivhv": "0.88729005612623",
    "iv": "83.77%",
    "iv5d": "84.78%",
    "iv1m": "83.17%",
    "iv3m": "85.58%",
    "iv6m": "75.68%",
    "bb": "86%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "31.76",
    "opvol": "5580",
    "callvol": "3020",
    "putvol": "2560"
  },
  {
    "sym": "BBY",
    "price": "60.72",
    "chg": "-2.65%",
    "rs14": "37.79",
    "ivpct": "41%",
    "ivhv": "1.0445828603859",
    "iv": "36.92%",
    "iv5d": "38.37%",
    "iv1m": "40.63%",
    "iv3m": "44.22%",
    "iv6m": "41.50%",
    "bb": "-2%",
    "bbr": "Below Lower",
    "ttm": "On",
    "adr14": "2.2",
    "opvol": "8752",
    "callvol": "3576",
    "putvol": "5176"
  },
  {
    "sym": "GS",
    "price": "885.43",
    "chg": "-2.46%",
    "rs14": "58.99",
    "ivpct": "71%",
    "ivhv": "1.0367895247333",
    "iv": "31.83%",
    "iv5d": "34.44%",
    "iv1m": "39.89%",
    "iv3m": "35.48%",
    "iv6m": "32.09%",
    "bb": "82%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "22.67",
    "opvol": "64477",
    "callvol": "32755",
    "putvol": "31722"
  },
  {
    "sym": "DXCM",
    "price": "62.51",
    "chg": "-2.36%",
    "rs14": "38.39",
    "ivpct": "82%",
    "ivhv": "1.8577443127203",
    "iv": "57.72%",
    "iv5d": "54.61%",
    "iv1m": "48.56%",
    "iv3m": "49.24%",
    "iv6m": "48.02%",
    "bb": "21%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "1.99",
    "opvol": "836",
    "callvol": "464",
    "putvol": "372"
  },
  {
    "sym": "TJX",
    "price": "158.12",
    "chg": "-2.15%",
    "rs14": "49.12",
    "ivpct": "54%",
    "ivhv": "1.0395395348837",
    "iv": "22.21%",
    "iv5d": "22.29%",
    "iv1m": "23.53%",
    "iv3m": "23.64%",
    "iv6m": "21.90%",
    "bb": "50%",
    "bbr": "New Below Mid",
    "ttm": "0",
    "adr14": "3.37",
    "opvol": "8189",
    "callvol": "7288",
    "putvol": "901"
  },
  {
    "sym": "HSY",
    "price": "198.19",
    "chg": "-2.04%",
    "rs14": "34.1",
    "ivpct": "97%",
    "ivhv": "1.4709049586777",
    "iv": "35.62%",
    "iv5d": "34.03%",
    "iv1m": "33.39%",
    "iv3m": "29.93%",
    "iv6m": "27.69%",
    "bb": "-8%",
    "bbr": "Below Lower",
    "ttm": "0",
    "adr14": "5.36",
    "opvol": "666",
    "callvol": "348",
    "putvol": "318"
  },
  {
    "sym": "MDLZ",
    "price": "57.8",
    "chg": "-2.03%",
    "rs14": "48.86",
    "ivpct": "84%",
    "ivhv": "1.128270313757",
    "iv": "28.08%",
    "iv5d": "28.58%",
    "iv1m": "28.67%",
    "iv3m": "25.98%",
    "iv6m": "25.60%",
    "bb": "53%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "1.26",
    "opvol": "1839",
    "callvol": "1028",
    "putvol": "811"
  },
  {
    "sym": "AMAT",
    "price": "391.42",
    "chg": "-2.02%",
    "rs14": "62.43",
    "ivpct": "94%",
    "ivhv": "1.039188855581",
    "iv": "58.93%",
    "iv5d": "58.57%",
    "iv1m": "58.01%",
    "iv3m": "55.60%",
    "iv6m": "49.27%",
    "bb": "90%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "14.77",
    "opvol": "25708",
    "callvol": "17751",
    "putvol": "7957"
  },
  {
    "sym": "KO",
    "price": "75.93",
    "chg": "-1.99%",
    "rs14": "45.86",
    "ivpct": "92%",
    "ivhv": "1.3569254467036",
    "iv": "21.86%",
    "iv5d": "21.54%",
    "iv1m": "21.61%",
    "iv3m": "20.11%",
    "iv6m": "17.87%",
    "bb": "42%",
    "bbr": "New Below Mid",
    "ttm": "0",
    "adr14": "1.37",
    "opvol": "28220",
    "callvol": "18987",
    "putvol": "9233"
  },
  {
    "sym": "NEE",
    "price": "92.26",
    "chg": "-1.93%",
    "rs14": "49.6",
    "ivpct": "44%",
    "ivhv": "1.6585444579781",
    "iv": "26.64%",
    "iv5d": "26.93%",
    "iv1m": "28.40%",
    "iv3m": "26.55%",
    "iv6m": "26.13%",
    "bb": "49%",
    "bbr": "New Below Mid",
    "ttm": "0",
    "adr14": "1.66",
    "opvol": "6792",
    "callvol": "4293",
    "putvol": "2499"
  },
  {
    "sym": "ABBV",
    "price": "203.93",
    "chg": "-1.93%",
    "rs14": "37.05",
    "ivpct": "95%",
    "ivhv": "1.3241396800624",
    "iv": "33.68%",
    "iv5d": "32.85%",
    "iv1m": "32.54%",
    "iv3m": "29.72%",
    "iv6m": "27.35%",
    "bb": "16%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "5.11",
    "opvol": "10381",
    "callvol": "7330",
    "putvol": "3051"
  },
  {
    "sym": "WMB",
    "price": "71.44",
    "chg": "-1.79%",
    "rs14": "43.41",
    "ivpct": "73%",
    "ivhv": "1.5873884657236",
    "iv": "28.80%",
    "iv5d": "29.31%",
    "iv1m": "29.71%",
    "iv3m": "28.96%",
    "iv6m": "27.15%",
    "bb": "1%",
    "bbr": "Below Mid",
    "ttm": "On",
    "adr14": "1.74",
    "opvol": "1024",
    "callvol": "693",
    "putvol": "331"
  },
  {
    "sym": "CVS",
    "price": "77.94",
    "chg": "-1.75%",
    "rs14": "59.76",
    "ivpct": "64%",
    "ivhv": "1.2378265486726",
    "iv": "34.88%",
    "iv5d": "34.58%",
    "iv1m": "38.70%",
    "iv3m": "35.56%",
    "iv6m": "32.77%",
    "bb": "84%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.73",
    "opvol": "3888",
    "callvol": "2914",
    "putvol": "974"
  },
  {
    "sym": "EQT",
    "price": "57.66",
    "chg": "-1.74%",
    "rs14": "33.7",
    "ivpct": "53%",
    "ivhv": "1.3522700941347",
    "iv": "37.06%",
    "iv5d": "38.84%",
    "iv1m": "40.48%",
    "iv3m": "39.19%",
    "iv6m": "37.01%",
    "bb": "5%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "2.01",
    "opvol": "18010",
    "callvol": "2506",
    "putvol": "15504"
  },
  {
    "sym": "MRK",
    "price": "119.31",
    "chg": "-1.74%",
    "rs14": "51.38",
    "ivpct": "64%",
    "ivhv": "1.5134959349593",
    "iv": "31.44%",
    "iv5d": "31.21%",
    "iv1m": "31.65%",
    "iv3m": "29.47%",
    "iv6m": "28.02%",
    "bb": "58%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.72",
    "opvol": "6177",
    "callvol": "2846",
    "putvol": "3331"
  },
  {
    "sym": "TMUS",
    "price": "192.48",
    "chg": "-1.65%",
    "rs14": "28.88",
    "ivpct": "92%",
    "ivhv": "1.7512248995984",
    "iv": "34.98%",
    "iv5d": "34.75%",
    "iv1m": "32.55%",
    "iv3m": "32.45%",
    "iv6m": "29.09%",
    "bb": "-1%",
    "bbr": "Below Lower",
    "ttm": "0",
    "adr14": "5.05",
    "opvol": "4329",
    "callvol": "2306",
    "putvol": "2023"
  },
  {
    "sym": "WMT",
    "price": "124.68",
    "chg": "-1.65%",
    "rs14": "50.26",
    "ivpct": "51%",
    "ivhv": "1.0788420621931",
    "iv": "25.68%",
    "iv5d": "25.81%",
    "iv1m": "26.97%",
    "iv3m": "28.76%",
    "iv6m": "26.33%",
    "bb": "58%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.69",
    "opvol": "50339",
    "callvol": "25459",
    "putvol": "24880"
  },
  {
    "sym": "URBN",
    "price": "67.47",
    "chg": "-1.65%",
    "rs14": "57.54",
    "ivpct": "35%",
    "ivhv": "1.3466993051169",
    "iv": "42.72%",
    "iv5d": "44.19%",
    "iv1m": "45.27%",
    "iv3m": "48.93%",
    "iv6m": "48.67%",
    "bb": "85%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.25",
    "opvol": "552",
    "callvol": "225",
    "putvol": "327"
  },
  {
    "sym": "BMY",
    "price": "57.71",
    "chg": "-1.55%",
    "rs14": "43.44",
    "ivpct": "66%",
    "ivhv": "1.2451164626925",
    "iv": "31.90%",
    "iv5d": "31.10%",
    "iv1m": "30.54%",
    "iv3m": "28.56%",
    "iv6m": "29.60%",
    "bb": "21%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "1.28",
    "opvol": "15374",
    "callvol": "11488",
    "putvol": "3886"
  },
  {
    "sym": "REGN",
    "price": "738.12",
    "chg": "-1.44%",
    "rs14": "43.85",
    "ivpct": "91%",
    "ivhv": "1.618067940552",
    "iv": "45.31%",
    "iv5d": "44.71%",
    "iv1m": "41.98%",
    "iv3m": "38.49%",
    "iv6m": "36.41%",
    "bb": "29%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "17.43",
    "opvol": "673",
    "callvol": "262",
    "putvol": "411"
  },
  {
    "sym": "SO",
    "price": "95.78",
    "chg": "-1.41%",
    "rs14": "48.24",
    "ivpct": "92%",
    "ivhv": "1.4825459496256",
    "iv": "21.80%",
    "iv5d": "20.81%",
    "iv1m": "20.99%",
    "iv3m": "20.71%",
    "iv6m": "19.26%",
    "bb": "41%",
    "bbr": "New Below Mid",
    "ttm": "0",
    "adr14": "1.46",
    "opvol": "1463",
    "callvol": "1015",
    "putvol": "448"
  },
  {
    "sym": "UAL",
    "price": "95.06",
    "chg": "-1.39%",
    "rs14": "50.23",
    "ivpct": "83%",
    "ivhv": "1.1134100185529",
    "iv": "59.82%",
    "iv5d": "60.48%",
    "iv1m": "64.31%",
    "iv3m": "56.65%",
    "iv6m": "51.97%",
    "bb": "72%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "4.29",
    "opvol": "12606",
    "callvol": "5809",
    "putvol": "6797"
  },
  {
    "sym": "GNRC",
    "price": "204.16",
    "chg": "-1.39%",
    "rs14": "52.2",
    "ivpct": "98%",
    "ivhv": "1.3794363395225",
    "iv": "62.01%",
    "iv5d": "61.75%",
    "iv1m": "57.39%",
    "iv3m": "54.30%",
    "iv6m": "49.30%",
    "bb": "69%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "9.08",
    "opvol": "471",
    "callvol": "303",
    "putvol": "168"
  },
  {
    "sym": "MO",
    "price": "66.49",
    "chg": "-1.32%",
    "rs14": "51.11",
    "ivpct": "95%",
    "ivhv": "1.4328002183406",
    "iv": "25.89%",
    "iv5d": "25.57%",
    "iv1m": "24.77%",
    "iv3m": "22.51%",
    "iv6m": "21.15%",
    "bb": "61%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.46",
    "opvol": "8671",
    "callvol": "5367",
    "putvol": "3304"
  },
  {
    "sym": "DAL",
    "price": "66.94",
    "chg": "-1.30%",
    "rs14": "53.15",
    "ivpct": "44%",
    "ivhv": "1.0574170902929",
    "iv": "43.36%",
    "iv5d": "45.50%",
    "iv1m": "53.03%",
    "iv3m": "48.08%",
    "iv6m": "44.98%",
    "bb": "66%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "2.43",
    "opvol": "46928",
    "callvol": "29946",
    "putvol": "16982"
  },
  {
    "sym": "PG",
    "price": "143.28",
    "chg": "-1.30%",
    "rs14": "40.23",
    "ivpct": "94%",
    "ivhv": "1.2667201604814",
    "iv": "25.01%",
    "iv5d": "25.22%",
    "iv1m": "25.07%",
    "iv3m": "21.74%",
    "iv6m": "20.73%",
    "bb": "35%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "2.41",
    "opvol": "8041",
    "callvol": "4052",
    "putvol": "3989"
  },
  {
    "sym": "VZ",
    "price": "45.45",
    "chg": "-1.28%",
    "rs14": "24.97",
    "ivpct": "98%",
    "ivhv": "1.5858700696056",
    "iv": "27.69%",
    "iv5d": "27.46%",
    "iv1m": "26.31%",
    "iv3m": "23.90%",
    "iv6m": "21.96%",
    "bb": "-14%",
    "bbr": "Below Lower",
    "ttm": "0",
    "adr14": "0.86",
    "opvol": "48123",
    "callvol": "26433",
    "putvol": "21690"
  },
  {
    "sym": "SIG",
    "price": "92.44",
    "chg": "-1.27%",
    "rs14": "56.21",
    "ivpct": "48%",
    "ivhv": "0.79683213920164",
    "iv": "46.52%",
    "iv5d": "48.25%",
    "iv1m": "53.20%",
    "iv3m": "58.28%",
    "iv6m": "52.73%",
    "bb": "85%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "3.72",
    "opvol": "495",
    "callvol": "384",
    "putvol": "111"
  },
  {
    "sym": "COST",
    "price": "986.42",
    "chg": "-1.21%",
    "rs14": "45.3",
    "ivpct": "44%",
    "ivhv": "1.1857023411371",
    "iv": "21.39%",
    "iv5d": "21.71%",
    "iv1m": "22.57%",
    "iv3m": "23.76%",
    "iv6m": "22.98%",
    "bb": "38%",
    "bbr": "New Below Mid",
    "ttm": "0",
    "adr14": "18.17",
    "opvol": "23463",
    "callvol": "10770",
    "putvol": "12693"
  },
  {
    "sym": "CRH",
    "price": "116.49",
    "chg": "-1.19%",
    "rs14": "62.53",
    "ivpct": "83%",
    "ivhv": "0.94345815531541",
    "iv": "37.53%",
    "iv5d": "37.93%",
    "iv1m": "38.53%",
    "iv3m": "35.63%",
    "iv6m": "32.26%",
    "bb": "99%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "3.07",
    "opvol": "903",
    "callvol": "583",
    "putvol": "320"
  },
  {
    "sym": "KMB",
    "price": "96.16",
    "chg": "-1.15%",
    "rs14": "41.95",
    "ivpct": "94%",
    "ivhv": "1.1686327979081",
    "iv": "31.44%",
    "iv5d": "30.65%",
    "iv1m": "29.42%",
    "iv3m": "27.58%",
    "iv6m": "27.28%",
    "bb": "25%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "2.22",
    "opvol": "2773",
    "callvol": "1122",
    "putvol": "1651"
  },
  {
    "sym": "LLY",
    "price": "928.93",
    "chg": "-1.12%",
    "rs14": "45.34",
    "ivpct": "89%",
    "ivhv": "1.4325167892549",
    "iv": "44.63%",
    "iv5d": "44.10%",
    "iv1m": "41.91%",
    "iv3m": "39.04%",
    "iv6m": "36.52%",
    "bb": "55%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "24.57",
    "opvol": "15878",
    "callvol": "9991",
    "putvol": "5887"
  },
  {
    "sym": "AAPL",
    "price": "257.59",
    "chg": "-1.11%",
    "rs14": "51.67",
    "ivpct": "80%",
    "ivhv": "1.5598144220573",
    "iv": "29.31%",
    "iv5d": "28.90%",
    "iv1m": "28.52%",
    "iv3m": "27.42%",
    "iv6m": "25.18%",
    "bb": "76%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "5.39",
    "opvol": "557047",
    "callvol": "314216",
    "putvol": "242831"
  },
  {
    "sym": "WYNN",
    "price": "102.86",
    "chg": "-1.10%",
    "rs14": "50.01",
    "ivpct": "70%",
    "ivhv": "1.2341023441967",
    "iv": "42.48%",
    "iv5d": "42.96%",
    "iv1m": "43.04%",
    "iv3m": "42.44%",
    "iv6m": "40.89%",
    "bb": "67%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "2.93",
    "opvol": "1409",
    "callvol": "564",
    "putvol": "845"
  },
  {
    "sym": "AMGN",
    "price": "347.21",
    "chg": "-1.09%",
    "rs14": "42.78",
    "ivpct": "88%",
    "ivhv": "1.5110557317626",
    "iv": "33.15%",
    "iv5d": "33.23%",
    "iv1m": "32.41%",
    "iv3m": "29.00%",
    "iv6m": "27.26%",
    "bb": "30%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "7.5",
    "opvol": "4097",
    "callvol": "2293",
    "putvol": "1804"
  },
  {
    "sym": "HON",
    "price": "232.53",
    "chg": "-1.07%",
    "rs14": "53.05",
    "ivpct": "91%",
    "ivhv": "1.1644398682043",
    "iv": "28.51%",
    "iv5d": "28.02%",
    "iv1m": "28.16%",
    "iv3m": "26.10%",
    "iv6m": "23.68%",
    "bb": "76%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.22",
    "opvol": "3455",
    "callvol": "1614",
    "putvol": "1841"
  },
  {
    "sym": "SATS",
    "price": "127.28",
    "chg": "-1.02%",
    "rs14": "60.24",
    "ivpct": "62%",
    "ivhv": "1.2127625489498",
    "iv": "67.18%",
    "iv5d": "68.03%",
    "iv1m": "66.41%",
    "iv3m": "64.38%",
    "iv6m": "60.35%",
    "bb": "86%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "7.39",
    "opvol": "8849",
    "callvol": "5170",
    "putvol": "3679"
  },
  {
    "sym": "FSLR",
    "price": "201.48",
    "chg": "-0.98%",
    "rs14": "51.74",
    "ivpct": "75%",
    "ivhv": "1.654133583691",
    "iv": "61.69%",
    "iv5d": "61.65%",
    "iv1m": "57.45%",
    "iv3m": "58.17%",
    "iv6m": "54.90%",
    "bb": "81%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "7.2",
    "opvol": "15582",
    "callvol": "13067",
    "putvol": "2515"
  },
  {
    "sym": "STZ",
    "price": "164.55",
    "chg": "-0.96%",
    "rs14": "66.75",
    "ivpct": "6%",
    "ivhv": "0.84144138372838",
    "iv": "26.17%",
    "iv5d": "30.61%",
    "iv1m": "35.57%",
    "iv3m": "32.49%",
    "iv6m": "33.33%",
    "bb": "109%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "4.92",
    "opvol": "1900",
    "callvol": "805",
    "putvol": "1095"
  },
  {
    "sym": "ADI",
    "price": "346.83",
    "chg": "-0.95%",
    "rs14": "63.99",
    "ivpct": "73%",
    "ivhv": "1.0488785811733",
    "iv": "37.58%",
    "iv5d": "37.42%",
    "iv1m": "37.74%",
    "iv3m": "36.94%",
    "iv6m": "34.80%",
    "bb": "92%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "8.85",
    "opvol": "1608",
    "callvol": "695",
    "putvol": "913"
  },
  {
    "sym": "CL",
    "price": "83.56",
    "chg": "-0.92%",
    "rs14": "37.79",
    "ivpct": "91%",
    "ivhv": "1.2298673740053",
    "iv": "27.40%",
    "iv5d": "27.53%",
    "iv1m": "27.24%",
    "iv3m": "23.46%",
    "iv6m": "22.77%",
    "bb": "21%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "1.71",
    "opvol": "1582",
    "callvol": "1092",
    "putvol": "490"
  },
  {
    "sym": "MU",
    "price": "416.79",
    "chg": "-0.90%",
    "rs14": "56.2",
    "ivpct": "80%",
    "ivhv": "0.9363835978836",
    "iv": "70.53%",
    "iv5d": "70.10%",
    "iv1m": "68.76%",
    "iv3m": "71.86%",
    "iv6m": "67.81%",
    "bb": "63%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "21.63",
    "opvol": "283955",
    "callvol": "166921",
    "putvol": "117034"
  },
  {
    "sym": "MCK",
    "price": "857.78",
    "chg": "-0.90%",
    "rs14": "38.51",
    "ivpct": "94%",
    "ivhv": "1.3871661783173",
    "iv": "33.09%",
    "iv5d": "32.76%",
    "iv1m": "31.66%",
    "iv3m": "28.91%",
    "iv6m": "27.19%",
    "bb": "27%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "18.8",
    "opvol": "482",
    "callvol": "251",
    "putvol": "231"
  },
  {
    "sym": "CAH",
    "price": "213.62",
    "chg": "-0.88%",
    "rs14": "49.06",
    "ivpct": "99%",
    "ivhv": "1.7802712993812",
    "iv": "37.26%",
    "iv5d": "36.07%",
    "iv1m": "33.96%",
    "iv3m": "31.00%",
    "iv6m": "28.73%",
    "bb": "63%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.03",
    "opvol": "1528",
    "callvol": "1376",
    "putvol": "152"
  },
  {
    "sym": "JNJ",
    "price": "236.43",
    "chg": "-0.85%",
    "rs14": "41.52",
    "ivpct": "89%",
    "ivhv": "1.7725434329395",
    "iv": "25.16%",
    "iv5d": "25.79%",
    "iv1m": "27.17%",
    "iv3m": "23.77%",
    "iv6m": "21.20%",
    "bb": "18%",
    "bbr": "Below Mid",
    "ttm": "Short",
    "adr14": "4.1",
    "opvol": "22006",
    "callvol": "12427",
    "putvol": "9579"
  },
  {
    "sym": "CSCO",
    "price": "81.53",
    "chg": "-0.84%",
    "rs14": "55.65",
    "ivpct": "94%",
    "ivhv": "1.2901343784994",
    "iv": "34.47%",
    "iv5d": "34.32%",
    "iv1m": "31.84%",
    "iv3m": "30.18%",
    "iv6m": "27.76%",
    "bb": "72%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.12",
    "opvol": "19283",
    "callvol": "14282",
    "putvol": "5001"
  },
  {
    "sym": "DVN",
    "price": "47.4",
    "chg": "-0.82%",
    "rs14": "47.28",
    "ivpct": "77%",
    "ivhv": "1.3175238722423",
    "iv": "39.43%",
    "iv5d": "40.00%",
    "iv1m": "40.42%",
    "iv3m": "38.88%",
    "iv6m": "35.70%",
    "bb": "19%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "1.63",
    "opvol": "12338",
    "callvol": "9596",
    "putvol": "2742"
  },
  {
    "sym": "PPG",
    "price": "109.44",
    "chg": "-0.81%",
    "rs14": "53.67",
    "ivpct": "94%",
    "ivhv": "0.8550280767431",
    "iv": "36.56%",
    "iv5d": "36.47%",
    "iv1m": "36.79%",
    "iv3m": "30.05%",
    "iv6m": "28.34%",
    "bb": "85%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.86",
    "opvol": "10893",
    "callvol": "10869",
    "putvol": "24"
  },
  {
    "sym": "PEP",
    "price": "155.93",
    "chg": "-0.72%",
    "rs14": "49.36",
    "ivpct": "90%",
    "ivhv": "1.4992895299145",
    "iv": "27.77%",
    "iv5d": "28.28%",
    "iv1m": "28.94%",
    "iv3m": "25.45%",
    "iv6m": "22.98%",
    "bb": "67%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.98",
    "opvol": "5637",
    "callvol": "2855",
    "putvol": "2782"
  },
  {
    "sym": "GILD",
    "price": "138.03",
    "chg": "-0.69%",
    "rs14": "43.01",
    "ivpct": "76%",
    "ivhv": "1.6172687651332",
    "iv": "33.52%",
    "iv5d": "32.65%",
    "iv1m": "32.20%",
    "iv3m": "30.96%",
    "iv6m": "29.76%",
    "bb": "34%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "2.71",
    "opvol": "6606",
    "callvol": "2098",
    "putvol": "4508"
  },
  {
    "sym": "EMR",
    "price": "142.88",
    "chg": "-0.62%",
    "rs14": "60.66",
    "ivpct": "93%",
    "ivhv": "1.0646281216069",
    "iv": "39.35%",
    "iv5d": "38.15%",
    "iv1m": "37.51%",
    "iv3m": "32.66%",
    "iv6m": "30.16%",
    "bb": "94%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "3.68",
    "opvol": "1645",
    "callvol": "1166",
    "putvol": "479"
  },
  {
    "sym": "MCD",
    "price": "303.95",
    "chg": "-0.57%",
    "rs14": "37.34",
    "ivpct": "90%",
    "ivhv": "1.4394613003096",
    "iv": "23.33%",
    "iv5d": "22.95%",
    "iv1m": "22.74%",
    "iv3m": "20.86%",
    "iv6m": "19.59%",
    "bb": "24%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "4.91",
    "opvol": "9127",
    "callvol": "5078",
    "putvol": "4049"
  },
  {
    "sym": "ETN",
    "price": "400.75",
    "chg": "-0.56%",
    "rs14": "66.51",
    "ivpct": "80%",
    "ivhv": "0.99366215512754",
    "iv": "37.99%",
    "iv5d": "39.52%",
    "iv1m": "40.07%",
    "iv3m": "37.23%",
    "iv6m": "35.29%",
    "bb": "100%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "11.75",
    "opvol": "1691",
    "callvol": "1079",
    "putvol": "612"
  },
  {
    "sym": "LULU",
    "price": "162.96",
    "chg": "-0.55%",
    "rs14": "51.74",
    "ivpct": "48%",
    "ivhv": "1.1014660887302",
    "iv": "43.93%",
    "iv5d": "43.76%",
    "iv1m": "46.20%",
    "iv3m": "48.83%",
    "iv6m": "49.80%",
    "bb": "72%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "6.33",
    "opvol": "9927",
    "callvol": "4564",
    "putvol": "5363"
  },
  {
    "sym": "TPR",
    "price": "149.51",
    "chg": "-0.53%",
    "rs14": "55.85",
    "ivpct": "90%",
    "ivhv": "1.3683214568488",
    "iv": "51.93%",
    "iv5d": "51.05%",
    "iv1m": "47.96%",
    "iv3m": "44.40%",
    "iv6m": "42.83%",
    "bb": "87%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.77",
    "opvol": "1055",
    "callvol": "904",
    "putvol": "151"
  },
  {
    "sym": "DE",
    "price": "601.95",
    "chg": "-0.50%",
    "rs14": "57.35",
    "ivpct": "51%",
    "ivhv": "1.0604761904762",
    "iv": "29.56%",
    "iv5d": "29.39%",
    "iv1m": "31.14%",
    "iv3m": "31.91%",
    "iv6m": "29.95%",
    "bb": "86%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "15.59",
    "opvol": "3166",
    "callvol": "2244",
    "putvol": "922"
  },
  {
    "sym": "FDX",
    "price": "372.21",
    "chg": "-0.50%",
    "rs14": "58.97",
    "ivpct": "39%",
    "ivhv": "1.0985709050934",
    "iv": "29.83%",
    "iv5d": "30.06%",
    "iv1m": "35.32%",
    "iv3m": "36.74%",
    "iv6m": "33.82%",
    "bb": "87%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "7.68",
    "opvol": "2638",
    "callvol": "1069",
    "putvol": "1569"
  },
  {
    "sym": "RTX",
    "price": "200.75",
    "chg": "-0.40%",
    "rs14": "53.06",
    "ivpct": "96%",
    "ivhv": "1.2517204301075",
    "iv": "33.90%",
    "iv5d": "33.21%",
    "iv1m": "33.33%",
    "iv3m": "31.19%",
    "iv6m": "27.20%",
    "bb": "65%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "3.97",
    "opvol": "5103",
    "callvol": "2799",
    "putvol": "2304"
  },
  {
    "sym": "PNC",
    "price": "220.26",
    "chg": "-0.39%",
    "rs14": "64.39",
    "ivpct": "85%",
    "ivhv": "1.5123541247485",
    "iv": "30.18%",
    "iv5d": "30.29%",
    "iv1m": "33.69%",
    "iv3m": "29.24%",
    "iv6m": "26.63%",
    "bb": "91%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.34",
    "opvol": "1904",
    "callvol": "1555",
    "putvol": "349"
  },
  {
    "sym": "NSC",
    "price": "295.24",
    "chg": "-0.35%",
    "rs14": "56.15",
    "ivpct": "86%",
    "ivhv": "1.4942865013774",
    "iv": "26.64%",
    "iv5d": "25.97%",
    "iv1m": "26.21%",
    "iv3m": "23.83%",
    "iv6m": "21.57%",
    "bb": "91%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.22",
    "opvol": "53",
    "callvol": "39",
    "putvol": "14"
  },
  {
    "sym": "UPS",
    "price": "101.35",
    "chg": "-0.34%",
    "rs14": "53.02",
    "ivpct": "80%",
    "ivhv": "1.3422484998235",
    "iv": "38.00%",
    "iv5d": "37.40%",
    "iv1m": "36.16%",
    "iv3m": "32.96%",
    "iv6m": "31.63%",
    "bb": "96%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "2.16",
    "opvol": "6281",
    "callvol": "4051",
    "putvol": "2230"
  },
  {
    "sym": "ROST",
    "price": "220.47",
    "chg": "-0.31%",
    "rs14": "58.93",
    "ivpct": "52%",
    "ivhv": "0.82523067331671",
    "iv": "26.57%",
    "iv5d": "26.37%",
    "iv1m": "27.15%",
    "iv3m": "28.50%",
    "iv6m": "26.66%",
    "bb": "73%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.37",
    "opvol": "906",
    "callvol": "393",
    "putvol": "513"
  },
  {
    "sym": "LRCX",
    "price": "262.86",
    "chg": "-0.30%",
    "rs14": "66.71",
    "ivpct": "96%",
    "ivhv": "1.0200995838288",
    "iv": "68.61%",
    "iv5d": "69.06%",
    "iv1m": "67.70%",
    "iv3m": "64.70%",
    "iv6m": "57.30%",
    "bb": "100%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "10.19",
    "opvol": "14160",
    "callvol": "6540",
    "putvol": "7620"
  },
  {
    "sym": "GM",
    "price": "76.2",
    "chg": "-0.29%",
    "rs14": "52.33",
    "ivpct": "95%",
    "ivhv": "1.4267101740295",
    "iv": "42.70%",
    "iv5d": "41.91%",
    "iv1m": "40.49%",
    "iv3m": "36.97%",
    "iv6m": "33.61%",
    "bb": "77%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.75",
    "opvol": "7695",
    "callvol": "5545",
    "putvol": "2150"
  },
  {
    "sym": "NVDA",
    "price": "188.1",
    "chg": "-0.28%",
    "rs14": "60.7",
    "ivpct": "7%",
    "ivhv": "1.0337661141805",
    "iv": "33.83%",
    "iv5d": "33.92%",
    "iv1m": "36.60%",
    "iv3m": "42.07%",
    "iv6m": "41.97%",
    "bb": "94%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "4.44",
    "opvol": "1590103",
    "callvol": "917629",
    "putvol": "672474"
  },
  {
    "sym": "UNP",
    "price": "249.81",
    "chg": "-0.28%",
    "rs14": "58.25",
    "ivpct": "82%",
    "ivhv": "1.4677526821005",
    "iv": "25.99%",
    "iv5d": "26.74%",
    "iv1m": "28.12%",
    "iv3m": "25.58%",
    "iv6m": "23.79%",
    "bb": "89%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.07",
    "opvol": "1648",
    "callvol": "867",
    "putvol": "781"
  },
  {
    "sym": "CAT",
    "price": "788.63",
    "chg": "-0.26%",
    "rs14": "66.42",
    "ivpct": "88%",
    "ivhv": "1.0101156780704",
    "iv": "40.86%",
    "iv5d": "42.33%",
    "iv1m": "43.19%",
    "iv3m": "39.90%",
    "iv6m": "36.62%",
    "bb": "98%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "21.95",
    "opvol": "14553",
    "callvol": "5400",
    "putvol": "9153"
  },
  {
    "sym": "EA",
    "price": "202.23",
    "chg": "-0.25%",
    "rs14": "51.37",
    "ivpct": "38%",
    "ivhv": "1.8645190839695",
    "iv": "12.16%",
    "iv5d": "10.71%",
    "iv1m": "11.62%",
    "iv3m": "12.94%",
    "iv6m": "10.67%",
    "bb": "53%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "0.88",
    "opvol": "30442",
    "callvol": "193",
    "putvol": "30249"
  },
  {
    "sym": "TER",
    "price": "367.2",
    "chg": "-0.21%",
    "rs14": "68.58",
    "ivpct": "98%",
    "ivhv": "1.0560640276302",
    "iv": "80.03%",
    "iv5d": "79.62%",
    "iv1m": "74.86%",
    "iv3m": "68.63%",
    "iv6m": "61.26%",
    "bb": "98%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "15.89",
    "opvol": "1741",
    "callvol": "717",
    "putvol": "1024"
  },
  {
    "sym": "HWM",
    "price": "252.24",
    "chg": "-0.17%",
    "rs14": "59.08",
    "ivpct": "84%",
    "ivhv": "1.1807669376694",
    "iv": "43.56%",
    "iv5d": "43.16%",
    "iv1m": "42.52%",
    "iv3m": "40.66%",
    "iv6m": "36.99%",
    "bb": "91%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "6.65",
    "opvol": "593",
    "callvol": "249",
    "putvol": "344"
  },
  {
    "sym": "XOM",
    "price": "152.28",
    "chg": "-0.15%",
    "rs14": "41.7",
    "ivpct": "91%",
    "ivhv": "1.1021443158611",
    "iv": "32.33%",
    "iv5d": "33.02%",
    "iv1m": "32.76%",
    "iv3m": "29.86%",
    "iv6m": "25.54%",
    "bb": "10%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "5.18",
    "opvol": "68047",
    "callvol": "50583",
    "putvol": "17464"
  },
  {
    "sym": "GE",
    "price": "307.91",
    "chg": "-0.14%",
    "rs14": "53.29",
    "ivpct": "93%",
    "ivhv": "0.94660608921407",
    "iv": "40.23%",
    "iv5d": "40.44%",
    "iv1m": "39.52%",
    "iv3m": "34.83%",
    "iv6m": "32.68%",
    "bb": "82%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "8.14",
    "opvol": "4578",
    "callvol": "1812",
    "putvol": "2766"
  },
  {
    "sym": "GEV",
    "price": "990.57",
    "chg": "-0.08%",
    "rs14": "69.48",
    "ivpct": "66%",
    "ivhv": "1.0912899106003",
    "iv": "51.28%",
    "iv5d": "52.63%",
    "iv1m": "53.47%",
    "iv3m": "51.18%",
    "iv6m": "50.40%",
    "bb": "101%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "36.59",
    "opvol": "11933",
    "callvol": "5672",
    "putvol": "6261"
  },
  {
    "sym": "ABT",
    "price": "100.27",
    "chg": "-0.03%",
    "rs14": "30.97",
    "ivpct": "92%",
    "ivhv": "1.5788453608247",
    "iv": "30.40%",
    "iv5d": "30.94%",
    "iv1m": "30.93%",
    "iv3m": "26.41%",
    "iv6m": "23.74%",
    "bb": "13%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "1.97",
    "opvol": "7390",
    "callvol": "4189",
    "putvol": "3201"
  },
  {
    "sym": "AMD",
    "price": "245.09",
    "chg": "+0.02%",
    "rs14": "70.59",
    "ivpct": "75%",
    "ivhv": "1.1323689396926",
    "iv": "57.64%",
    "iv5d": "57.74%",
    "iv1m": "55.18%",
    "iv3m": "56.40%",
    "iv6m": "55.49%",
    "bb": "103%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "9.33",
    "opvol": "213279",
    "callvol": "111665",
    "putvol": "101614"
  },
  {
    "sym": "PDD",
    "price": "100.21",
    "chg": "+0.04%",
    "rs14": "47.84",
    "ivpct": "45%",
    "ivhv": "1.1506647673314",
    "iv": "36.35%",
    "iv5d": "35.73%",
    "iv1m": "41.10%",
    "iv3m": "40.78%",
    "iv6m": "36.44%",
    "bb": "50%",
    "bbr": "Below Mid",
    "ttm": "Long",
    "adr14": "3.56",
    "opvol": "25546",
    "callvol": "18915",
    "putvol": "6631"
  },
  {
    "sym": "OXY",
    "price": "58",
    "chg": "+0.05%",
    "rs14": "46.61",
    "ivpct": "87%",
    "ivhv": "1.0864731774415",
    "iv": "40.47%",
    "iv5d": "41.41%",
    "iv1m": "40.71%",
    "iv3m": "38.01%",
    "iv6m": "33.98%",
    "bb": "21%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "2.38",
    "opvol": "62144",
    "callvol": "53744",
    "putvol": "8400"
  },
  {
    "sym": "META",
    "price": "630.36",
    "chg": "+0.08%",
    "rs14": "57.51",
    "ivpct": "80%",
    "ivhv": "0.9230777903044",
    "iv": "40.85%",
    "iv5d": "42.10%",
    "iv1m": "39.20%",
    "iv3m": "35.98%",
    "iv6m": "34.95%",
    "bb": "81%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "18.3",
    "opvol": "384518",
    "callvol": "231874",
    "putvol": "152644"
  },
  {
    "sym": "MMM",
    "price": "150.47",
    "chg": "+0.10%",
    "rs14": "52.22",
    "ivpct": "85%",
    "ivhv": "1.194161358811",
    "iv": "33.78%",
    "iv5d": "34.31%",
    "iv1m": "33.84%",
    "iv3m": "29.96%",
    "iv6m": "28.03%",
    "bb": "88%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.8",
    "opvol": "1936",
    "callvol": "611",
    "putvol": "1325"
  },
  {
    "sym": "SLB",
    "price": "51.99",
    "chg": "+0.13%",
    "rs14": "58.69",
    "ivpct": "84%",
    "ivhv": "0.90206150341686",
    "iv": "39.80%",
    "iv5d": "40.98%",
    "iv1m": "41.81%",
    "iv3m": "38.29%",
    "iv6m": "35.63%",
    "bb": "72%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.86",
    "opvol": "4173",
    "callvol": "2985",
    "putvol": "1188"
  },
  {
    "sym": "AMZN",
    "price": "238.71",
    "chg": "+0.14%",
    "rs14": "71.65",
    "ivpct": "84%",
    "ivhv": "1.2297862733293",
    "iv": "40.73%",
    "iv5d": "40.45%",
    "iv1m": "37.67%",
    "iv3m": "37.17%",
    "iv6m": "34.80%",
    "bb": "108%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "5.4",
    "opvol": "641320",
    "callvol": "414751",
    "putvol": "226569"
  },
  {
    "sym": "KR",
    "price": "68.09",
    "chg": "+0.15%",
    "rs14": "39.55",
    "ivpct": "53%",
    "ivhv": "0.87152804642166",
    "iv": "27.08%",
    "iv5d": "27.58%",
    "iv1m": "28.11%",
    "iv3m": "29.84%",
    "iv6m": "28.07%",
    "bb": "-6%",
    "bbr": "Below Lower",
    "ttm": "0",
    "adr14": "1.86",
    "opvol": "3307",
    "callvol": "2413",
    "putvol": "894"
  },
  {
    "sym": "DECK",
    "price": "108.02",
    "chg": "+0.15%",
    "rs14": "57.22",
    "ivpct": "28%",
    "ivhv": "0.87389458955224",
    "iv": "38.86%",
    "iv5d": "40.35%",
    "iv1m": "41.60%",
    "iv3m": "44.20%",
    "iv6m": "45.71%",
    "bb": "87%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "3.74",
    "opvol": "1450",
    "callvol": "920",
    "putvol": "530"
  },
  {
    "sym": "PM",
    "price": "160.71",
    "chg": "+0.16%",
    "rs14": "41.41",
    "ivpct": "92%",
    "ivhv": "1.0680492365223",
    "iv": "34.30%",
    "iv5d": "33.90%",
    "iv1m": "32.51%",
    "iv3m": "30.36%",
    "iv6m": "28.11%",
    "bb": "36%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "4.11",
    "opvol": "2853",
    "callvol": "1325",
    "putvol": "1528"
  },
  {
    "sym": "TXN",
    "price": "215.09",
    "chg": "+0.17%",
    "rs14": "66.58",
    "ivpct": "92%",
    "ivhv": "1.29542527339",
    "iv": "42.67%",
    "iv5d": "41.83%",
    "iv1m": "38.93%",
    "iv3m": "36.54%",
    "iv6m": "35.64%",
    "bb": "100%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "4.76",
    "opvol": "4302",
    "callvol": "2361",
    "putvol": "1941"
  },
  {
    "sym": "RCL",
    "price": "277.42",
    "chg": "+0.17%",
    "rs14": "48.49",
    "ivpct": "94%",
    "ivhv": "1.2012314356436",
    "iv": "58.15%",
    "iv5d": "57.76%",
    "iv1m": "57.64%",
    "iv3m": "49.90%",
    "iv6m": "45.20%",
    "bb": "64%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "10.66",
    "opvol": "3082",
    "callvol": "1415",
    "putvol": "1667"
  },
  {
    "sym": "HLT",
    "price": "324.01",
    "chg": "+0.18%",
    "rs14": "65.16",
    "ivpct": "86%",
    "ivhv": "1.1335698847262",
    "iv": "30.51%",
    "iv5d": "30.89%",
    "iv1m": "32.28%",
    "iv3m": "29.49%",
    "iv6m": "26.60%",
    "bb": "101%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "6.1",
    "opvol": "1105",
    "callvol": "377",
    "putvol": "728"
  },
  {
    "sym": "LOW",
    "price": "244.75",
    "chg": "+0.22%",
    "rs14": "52.07",
    "ivpct": "63%",
    "ivhv": "0.92877899484536",
    "iv": "28.74%",
    "iv5d": "29.01%",
    "iv1m": "30.51%",
    "iv3m": "28.99%",
    "iv6m": "27.14%",
    "bb": "87%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "5.68",
    "opvol": "8716",
    "callvol": "8008",
    "putvol": "708"
  },
  {
    "sym": "USB",
    "price": "55.81",
    "chg": "+0.27%",
    "rs14": "64.87",
    "ivpct": "74%",
    "ivhv": "1.5120267379679",
    "iv": "28.05%",
    "iv5d": "29.77%",
    "iv1m": "32.79%",
    "iv3m": "29.25%",
    "iv6m": "26.50%",
    "bb": "96%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.06",
    "opvol": "1319",
    "callvol": "628",
    "putvol": "691"
  },
  {
    "sym": "JPM",
    "price": "310.73",
    "chg": "+0.28%",
    "rs14": "66.68",
    "ivpct": "71%",
    "ivhv": "1.2648070509767",
    "iv": "26.63%",
    "iv5d": "28.76%",
    "iv1m": "32.17%",
    "iv3m": "28.91%",
    "iv6m": "26.22%",
    "bb": "98%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "6.12",
    "opvol": "44949",
    "callvol": "21170",
    "putvol": "23779"
  },
  {
    "sym": "EOG",
    "price": "136.65",
    "chg": "+0.34%",
    "rs14": "48.82",
    "ivpct": "80%",
    "ivhv": "1.2071785962474",
    "iv": "34.74%",
    "iv5d": "35.38%",
    "iv1m": "36.05%",
    "iv3m": "34.29%",
    "iv6m": "30.58%",
    "bb": "25%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "4.28",
    "opvol": "3342",
    "callvol": "2118",
    "putvol": "1224"
  },
  {
    "sym": "MDT",
    "price": "87.52",
    "chg": "+0.36%",
    "rs14": "43.04",
    "ivpct": "56%",
    "ivhv": "1.1900647948164",
    "iv": "22.06%",
    "iv5d": "22.66%",
    "iv1m": "23.40%",
    "iv3m": "23.12%",
    "iv6m": "21.61%",
    "bb": "59%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "1.53",
    "opvol": "3030",
    "callvol": "1843",
    "putvol": "1187"
  },
  {
    "sym": "WFC",
    "price": "85.71",
    "chg": "+0.36%",
    "rs14": "63.81",
    "ivpct": "82%",
    "ivhv": "1.2571098265896",
    "iv": "33.02%",
    "iv5d": "34.42%",
    "iv1m": "38.18%",
    "iv3m": "32.99%",
    "iv6m": "29.91%",
    "bb": "94%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.7",
    "opvol": "55635",
    "callvol": "21843",
    "putvol": "33792"
  },
  {
    "sym": "NKE",
    "price": "42.79",
    "chg": "+0.40%",
    "rs14": "23.77",
    "ivpct": "39%",
    "ivhv": "0.65463645130183",
    "iv": "34.00%",
    "iv5d": "34.66%",
    "iv1m": "44.54%",
    "iv3m": "41.52%",
    "iv6m": "39.09%",
    "bb": "16%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "1.42",
    "opvol": "95329",
    "callvol": "62220",
    "putvol": "33109"
  },
  {
    "sym": "AAOI",
    "price": "151.22",
    "chg": "+0.41%",
    "rs14": "71.56",
    "ivpct": "99%",
    "ivhv": "0.99533119526335",
    "iv": "161.06%",
    "iv5d": "159.20%",
    "iv1m": "139.51%",
    "iv3m": "127.32%",
    "iv6m": "115.75%",
    "bb": "104%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "14.75",
    "opvol": "37434",
    "callvol": "19535",
    "putvol": "17899"
  },
  {
    "sym": "NFLX",
    "price": "103.44",
    "chg": "+0.42%",
    "rs14": "73.58",
    "ivpct": "66%",
    "ivhv": "1.767606543263",
    "iv": "40.90%",
    "iv5d": "41.03%",
    "iv1m": "42.56%",
    "iv3m": "39.64%",
    "iv6m": "37.27%",
    "bb": "100%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "2.83",
    "opvol": "179014",
    "callvol": "121937",
    "putvol": "57077"
  },
  {
    "sym": "URI",
    "price": "775.38",
    "chg": "+0.45%",
    "rs14": "54.13",
    "ivpct": "93%",
    "ivhv": "1.2305048814505",
    "iv": "43.99%",
    "iv5d": "43.29%",
    "iv1m": "43.69%",
    "iv3m": "39.65%",
    "iv6m": "36.42%",
    "bb": "101%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "21.48",
    "opvol": "764",
    "callvol": "413",
    "putvol": "351"
  },
  {
    "sym": "GEHC",
    "price": "73.51",
    "chg": "+0.45%",
    "rs14": "51.72",
    "ivpct": "70%",
    "ivhv": "0.93742903053026",
    "iv": "35.23%",
    "iv5d": "36.09%",
    "iv1m": "36.93%",
    "iv3m": "33.18%",
    "iv6m": "31.47%",
    "bb": "90%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.75",
    "opvol": "816",
    "callvol": "375",
    "putvol": "441"
  },
  {
    "sym": "SBUX",
    "price": "97.04",
    "chg": "+0.46%",
    "rs14": "56.55",
    "ivpct": "78%",
    "ivhv": "1.1888752983294",
    "iv": "39.52%",
    "iv5d": "39.90%",
    "iv1m": "37.52%",
    "iv3m": "34.66%",
    "iv6m": "34.20%",
    "bb": "76%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.35",
    "opvol": "8395",
    "callvol": "4340",
    "putvol": "4055"
  },
  {
    "sym": "VLO",
    "price": "239.91",
    "chg": "+0.46%",
    "rs14": "53.79",
    "ivpct": "87%",
    "ivhv": "1.0209985422741",
    "iv": "41.25%",
    "iv5d": "42.68%",
    "iv1m": "44.26%",
    "iv3m": "40.77%",
    "iv6m": "36.82%",
    "bb": "40%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "9.75",
    "opvol": "3369",
    "callvol": "2085",
    "putvol": "1284"
  },
  {
    "sym": "HD",
    "price": "338.96",
    "chg": "+0.48%",
    "rs14": "49.78",
    "ivpct": "72%",
    "ivhv": "0.93193505189153",
    "iv": "27.88%",
    "iv5d": "28.43%",
    "iv1m": "29.52%",
    "iv3m": "27.95%",
    "iv6m": "26.14%",
    "bb": "79%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "7.72",
    "opvol": "6919",
    "callvol": "3917",
    "putvol": "3002"
  },
  {
    "sym": "STX",
    "price": "505.58",
    "chg": "+0.49%",
    "rs14": "68.94",
    "ivpct": "99%",
    "ivhv": "1.1355496235455",
    "iv": "82.75%",
    "iv5d": "80.93%",
    "iv1m": "77.23%",
    "iv3m": "75.50%",
    "iv6m": "69.57%",
    "bb": "93%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "25.26",
    "opvol": "6418",
    "callvol": "2700",
    "putvol": "3718"
  },
  {
    "sym": "COP",
    "price": "123.15",
    "chg": "+0.49%",
    "rs14": "47.56",
    "ivpct": "83%",
    "ivhv": "1.1929265003372",
    "iv": "34.98%",
    "iv5d": "35.46%",
    "iv1m": "36.43%",
    "iv3m": "34.13%",
    "iv6m": "31.27%",
    "bb": "21%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "3.67",
    "opvol": "7591",
    "callvol": "5111",
    "putvol": "2480"
  },
  {
    "sym": "PSX",
    "price": "160.06",
    "chg": "+0.51%",
    "rs14": "37.39",
    "ivpct": "80%",
    "ivhv": "1.0207025959368",
    "iv": "35.06%",
    "iv5d": "36.34%",
    "iv1m": "38.53%",
    "iv3m": "35.67%",
    "iv6m": "32.62%",
    "bb": "2%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "6.35",
    "opvol": "1560",
    "callvol": "1166",
    "putvol": "394"
  },
  {
    "sym": "MRNA",
    "price": "51.22",
    "chg": "+0.51%",
    "rs14": "51.98",
    "ivpct": "72%",
    "ivhv": "1.1420818452381",
    "iv": "76.58%",
    "iv5d": "75.93%",
    "iv1m": "74.34%",
    "iv3m": "77.57%",
    "iv6m": "72.75%",
    "bb": "52%",
    "bbr": "New Above Mid",
    "ttm": "On",
    "adr14": "2.54",
    "opvol": "17217",
    "callvol": "11230",
    "putvol": "5987"
  },
  {
    "sym": "GOOG",
    "price": "317.34",
    "chg": "+0.51%",
    "rs14": "63.32",
    "ivpct": "72%",
    "ivhv": "1.2174726775956",
    "iv": "35.71%",
    "iv5d": "35.29%",
    "iv1m": "33.70%",
    "iv3m": "34.05%",
    "iv6m": "32.67%",
    "bb": "86%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "6.99",
    "opvol": "84252",
    "callvol": "54557",
    "putvol": "29695"
  },
  {
    "sym": "AFL",
    "price": "111.27",
    "chg": "+0.51%",
    "rs14": "54.45",
    "ivpct": "87%",
    "ivhv": "1.6042857142857",
    "iv": "25.02%",
    "iv5d": "23.53%",
    "iv1m": "24.05%",
    "iv3m": "22.46%",
    "iv6m": "20.68%",
    "bb": "77%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.84",
    "opvol": "1635",
    "callvol": "1462",
    "putvol": "173"
  },
  {
    "sym": "LEN",
    "price": "89.44",
    "chg": "+0.53%",
    "rs14": "41.46",
    "ivpct": "78%",
    "ivhv": "1.2138104502501",
    "iv": "43.42%",
    "iv5d": "43.93%",
    "iv1m": "43.18%",
    "iv3m": "42.86%",
    "iv6m": "40.98%",
    "bb": "45%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "3.35",
    "opvol": "2370",
    "callvol": "1202",
    "putvol": "1168"
  },
  {
    "sym": "MAR",
    "price": "356.02",
    "chg": "+0.54%",
    "rs14": "65.93",
    "ivpct": "86%",
    "ivhv": "1.1150066181337",
    "iv": "33.50%",
    "iv5d": "34.06%",
    "iv1m": "34.28%",
    "iv3m": "31.28%",
    "iv6m": "28.53%",
    "bb": "102%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "7.85",
    "opvol": "1250",
    "callvol": "635",
    "putvol": "615"
  },
  {
    "sym": "DHI",
    "price": "143.49",
    "chg": "+0.60%",
    "rs14": "51.87",
    "ivpct": "86%",
    "ivhv": "1.3010741766697",
    "iv": "41.63%",
    "iv5d": "42.58%",
    "iv1m": "40.91%",
    "iv3m": "38.96%",
    "iv6m": "37.92%",
    "bb": "86%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "4.48",
    "opvol": "1920",
    "callvol": "443",
    "putvol": "1477"
  },
  {
    "sym": "MS",
    "price": "178.71",
    "chg": "+0.60%",
    "rs14": "68.21",
    "ivpct": "79%",
    "ivhv": "1.205077149155",
    "iv": "32.83%",
    "iv5d": "34.41%",
    "iv1m": "39.12%",
    "iv3m": "34.55%",
    "iv6m": "30.62%",
    "bb": "98%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "4.62",
    "opvol": "10782",
    "callvol": "6061",
    "putvol": "4721"
  },
  {
    "sym": "LMT",
    "price": "617.45",
    "chg": "+0.61%",
    "rs14": "46.1",
    "ivpct": "93%",
    "ivhv": "1.4002706078268",
    "iv": "33.35%",
    "iv5d": "33.60%",
    "iv1m": "33.94%",
    "iv3m": "31.90%",
    "iv6m": "27.71%",
    "bb": "39%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "14.88",
    "opvol": "4707",
    "callvol": "3081",
    "putvol": "1626"
  },
  {
    "sym": "VRTX",
    "price": "438.93",
    "chg": "+0.61%",
    "rs14": "42.99",
    "ivpct": "79%",
    "ivhv": "1.0073595814978",
    "iv": "36.43%",
    "iv5d": "35.38%",
    "iv1m": "33.60%",
    "iv3m": "36.70%",
    "iv6m": "32.81%",
    "bb": "27%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "10.85",
    "opvol": "2386",
    "callvol": "726",
    "putvol": "1660"
  },
  {
    "sym": "CBOE",
    "price": "297.78",
    "chg": "+0.62%",
    "rs14": "61.04",
    "ivpct": "76%",
    "ivhv": "0.90602826329491",
    "iv": "24.38%",
    "iv5d": "26.11%",
    "iv1m": "26.96%",
    "iv3m": "24.67%",
    "iv6m": "22.46%",
    "bb": "87%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "7.06",
    "opvol": "827",
    "callvol": "191",
    "putvol": "636"
  },
  {
    "sym": "CI",
    "price": "272.94",
    "chg": "+0.62%",
    "rs14": "51.37",
    "ivpct": "92%",
    "ivhv": "1.4358968524839",
    "iv": "37.62%",
    "iv5d": "37.03%",
    "iv1m": "35.85%",
    "iv3m": "33.95%",
    "iv6m": "32.48%",
    "bb": "71%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "6.21",
    "opvol": "2251",
    "callvol": "737",
    "putvol": "1514"
  },
  {
    "sym": "AIG",
    "price": "77.38",
    "chg": "+0.66%",
    "rs14": "55.37",
    "ivpct": "83%",
    "ivhv": "1.3466855256954",
    "iv": "29.60%",
    "iv5d": "29.47%",
    "iv1m": "29.25%",
    "iv3m": "28.81%",
    "iv6m": "26.67%",
    "bb": "87%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.46",
    "opvol": "493",
    "callvol": "302",
    "putvol": "191"
  },
  {
    "sym": "BIIB",
    "price": "174.13",
    "chg": "+0.67%",
    "rs14": "40.72",
    "ivpct": "65%",
    "ivhv": "1.2102384020619",
    "iv": "37.22%",
    "iv5d": "38.47%",
    "iv1m": "37.73%",
    "iv3m": "34.92%",
    "iv6m": "36.03%",
    "bb": "12%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "5.81",
    "opvol": "974",
    "callvol": "761",
    "putvol": "213"
  },
  {
    "sym": "BAC",
    "price": "52.9",
    "chg": "+0.69%",
    "rs14": "68.27",
    "ivpct": "75%",
    "ivhv": "1.2618526785714",
    "iv": "28.36%",
    "iv5d": "30.17%",
    "iv1m": "33.92%",
    "iv3m": "29.64%",
    "iv6m": "27.15%",
    "bb": "98%",
    "bbr": "New Below Upper",
    "ttm": "0",
    "adr14": "1.09",
    "opvol": "59460",
    "callvol": "42396",
    "putvol": "17064"
  },
  {
    "sym": "C",
    "price": "125.28",
    "chg": "+0.72%",
    "rs14": "70",
    "ivpct": "80%",
    "ivhv": "1.0720504150015",
    "iv": "34.84%",
    "iv5d": "36.71%",
    "iv1m": "40.59%",
    "iv3m": "36.37%",
    "iv6m": "32.92%",
    "bb": "96%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "3.26",
    "opvol": "68309",
    "callvol": "38442",
    "putvol": "29867"
  },
  {
    "sym": "PHM",
    "price": "121.22",
    "chg": "+0.74%",
    "rs14": "50.26",
    "ivpct": "92%",
    "ivhv": "1.237032967033",
    "iv": "40.66%",
    "iv5d": "40.83%",
    "iv1m": "39.41%",
    "iv3m": "37.83%",
    "iv6m": "36.20%",
    "bb": "80%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "3.44",
    "opvol": "1570",
    "callvol": "1403",
    "putvol": "167"
  },
  {
    "sym": "CTAS",
    "price": "176.23",
    "chg": "+0.74%",
    "rs14": "42.85",
    "ivpct": "61%",
    "ivhv": "1.0005578747628",
    "iv": "26.39%",
    "iv5d": "27.21%",
    "iv1m": "29.58%",
    "iv3m": "25.96%",
    "iv6m": "25.43%",
    "bb": "47%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "4.65",
    "opvol": "262",
    "callvol": "172",
    "putvol": "90"
  },
  {
    "sym": "MRVL",
    "price": "129.49",
    "chg": "+0.78%",
    "rs14": "80.57",
    "ivpct": "61%",
    "ivhv": "0.78863385877227",
    "iv": "62.37%",
    "iv5d": "59.78%",
    "iv1m": "55.74%",
    "iv3m": "60.13%",
    "iv6m": "59.99%",
    "bb": "106%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "5.61",
    "opvol": "157857",
    "callvol": "110852",
    "putvol": "47005"
  },
  {
    "sym": "FCX",
    "price": "68.33",
    "chg": "+0.78%",
    "rs14": "67.84",
    "ivpct": "79%",
    "ivhv": "0.93088754134509",
    "iv": "50.72%",
    "iv5d": "52.34%",
    "iv1m": "55.22%",
    "iv3m": "52.21%",
    "iv6m": "46.34%",
    "bb": "100%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "2.12",
    "opvol": "31109",
    "callvol": "13443",
    "putvol": "17666"
  },
  {
    "sym": "MSTR",
    "price": "129.72",
    "chg": "+0.84%",
    "rs14": "49.29",
    "ivpct": "63%",
    "ivhv": "1.1386481210347",
    "iv": "69.87%",
    "iv5d": "70.68%",
    "iv1m": "72.06%",
    "iv3m": "75.68%",
    "iv6m": "72.95%",
    "bb": "47%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "6.51",
    "opvol": "173124",
    "callvol": "86345",
    "putvol": "86779"
  },
  {
    "sym": "ASO",
    "price": "56.88",
    "chg": "+0.90%",
    "rs14": "52.76",
    "ivpct": "42%",
    "ivhv": "0.89536234902124",
    "iv": "43.62%",
    "iv5d": "42.64%",
    "iv1m": "44.15%",
    "iv3m": "48.59%",
    "iv6m": "48.33%",
    "bb": "72%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.48",
    "opvol": "539",
    "callvol": "381",
    "putvol": "158"
  },
  {
    "sym": "V",
    "price": "307.33",
    "chg": "+0.98%",
    "rs14": "50.15",
    "ivpct": "90%",
    "ivhv": "1.5212833061446",
    "iv": "27.98%",
    "iv5d": "27.92%",
    "iv1m": "28.26%",
    "iv3m": "26.05%",
    "iv6m": "23.65%",
    "bb": "75%",
    "bbr": "Above Mid",
    "ttm": "Long",
    "adr14": "6.06",
    "opvol": "15632",
    "callvol": "10508",
    "putvol": "5124"
  },
  {
    "sym": "GD",
    "price": "338.52",
    "chg": "+1.01%",
    "rs14": "40.91",
    "ivpct": "95%",
    "ivhv": "1.4570106761566",
    "iv": "28.99%",
    "iv5d": "28.60%",
    "iv1m": "28.51%",
    "iv3m": "26.44%",
    "iv6m": "22.96%",
    "bb": "8%",
    "bbr": "New Above Lower",
    "ttm": "On",
    "adr14": "7.18",
    "opvol": "1049",
    "callvol": "650",
    "putvol": "399"
  },
  {
    "sym": "CF",
    "price": "122.58",
    "chg": "+1.04%",
    "rs14": "51.25",
    "ivpct": "92%",
    "ivhv": "0.80717391304348",
    "iv": "55.65%",
    "iv5d": "56.43%",
    "iv1m": "56.92%",
    "iv3m": "46.20%",
    "iv6m": "39.68%",
    "bb": "31%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "6.66",
    "opvol": "6117",
    "callvol": "4836",
    "putvol": "1281"
  },
  {
    "sym": "ISRG",
    "price": "455.36",
    "chg": "+1.05%",
    "rs14": "39.96",
    "ivpct": "81%",
    "ivhv": "1.7928895956383",
    "iv": "39.38%",
    "iv5d": "39.38%",
    "iv1m": "38.18%",
    "iv3m": "33.42%",
    "iv6m": "32.93%",
    "bb": "29%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "10.22",
    "opvol": "2291",
    "callvol": "1495",
    "putvol": "796"
  },
  {
    "sym": "ABNB",
    "price": "130.32",
    "chg": "+1.05%",
    "rs14": "53.05",
    "ivpct": "86%",
    "ivhv": "1.3420816561242",
    "iv": "46.60%",
    "iv5d": "45.75%",
    "iv1m": "43.29%",
    "iv3m": "41.74%",
    "iv6m": "37.83%",
    "bb": "66%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "4.31",
    "opvol": "5756",
    "callvol": "2847",
    "putvol": "2909"
  },
  {
    "sym": "QCOM",
    "price": "129.46",
    "chg": "+1.09%",
    "rs14": "45.51",
    "ivpct": "90%",
    "ivhv": "2.0800289156627",
    "iv": "43.00%",
    "iv5d": "42.39%",
    "iv1m": "39.71%",
    "iv3m": "37.91%",
    "iv6m": "36.26%",
    "bb": "62%",
    "bbr": "New Above Mid",
    "ttm": "On",
    "adr14": "2.94",
    "opvol": "28510",
    "callvol": "20178",
    "putvol": "8332"
  },
  {
    "sym": "TSLA",
    "price": "352.78",
    "chg": "+1.10%",
    "rs14": "40.38",
    "ivpct": "29%",
    "ivhv": "1.2384450975154",
    "iv": "46.10%",
    "iv5d": "46.97%",
    "iv1m": "44.55%",
    "iv3m": "44.30%",
    "iv6m": "47.37%",
    "bb": "29%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "12.59",
    "opvol": "2091800",
    "callvol": "1210010",
    "putvol": "881790"
  },
  {
    "sym": "DLR",
    "price": "190.95",
    "chg": "+1.10%",
    "rs14": "72.18",
    "ivpct": "60%",
    "ivhv": "1.4894774346793",
    "iv": "31.44%",
    "iv5d": "32.67%",
    "iv1m": "33.18%",
    "iv3m": "32.75%",
    "iv6m": "31.40%",
    "bb": "103%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "3.54",
    "opvol": "945",
    "callvol": "692",
    "putvol": "253"
  },
  {
    "sym": "MCHP",
    "price": "72.37",
    "chg": "+1.13%",
    "rs14": "64.08",
    "ivpct": "94%",
    "ivhv": "1.4001357466063",
    "iv": "58.71%",
    "iv5d": "57.17%",
    "iv1m": "52.69%",
    "iv3m": "49.92%",
    "iv6m": "48.40%",
    "bb": "101%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "2.52",
    "opvol": "1614",
    "callvol": "1014",
    "putvol": "600"
  },
  {
    "sym": "MA",
    "price": "504.39",
    "chg": "+1.15%",
    "rs14": "49.72",
    "ivpct": "90%",
    "ivhv": "1.3224427131072",
    "iv": "28.70%",
    "iv5d": "29.34%",
    "iv1m": "28.84%",
    "iv3m": "26.76%",
    "iv6m": "24.19%",
    "bb": "70%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "10.36",
    "opvol": "4032",
    "callvol": "2105",
    "putvol": "1927"
  },
  {
    "sym": "COF",
    "price": "195.32",
    "chg": "+1.20%",
    "rs14": "57.29",
    "ivpct": "86%",
    "ivhv": "1.3900779661017",
    "iv": "41.01%",
    "iv5d": "41.34%",
    "iv1m": "42.16%",
    "iv3m": "37.95%",
    "iv6m": "34.33%",
    "bb": "101%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "4.46",
    "opvol": "3702",
    "callvol": "1773",
    "putvol": "1929"
  },
  {
    "sym": "CME",
    "price": "298.86",
    "chg": "+1.21%",
    "rs14": "46.07",
    "ivpct": "81%",
    "ivhv": "1.0822231237323",
    "iv": "25.04%",
    "iv5d": "25.60%",
    "iv1m": "25.66%",
    "iv3m": "25.14%",
    "iv6m": "22.44%",
    "bb": "35%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "6.08",
    "opvol": "970",
    "callvol": "435",
    "putvol": "535"
  },
  {
    "sym": "SCHW",
    "price": "95.95",
    "chg": "+1.21%",
    "rs14": "54.19",
    "ivpct": "92%",
    "ivhv": "1.7242913973148",
    "iv": "34.67%",
    "iv5d": "34.58%",
    "iv1m": "34.64%",
    "iv3m": "30.60%",
    "iv6m": "28.31%",
    "bb": "84%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "2.43",
    "opvol": "38644",
    "callvol": "5922",
    "putvol": "32722"
  },
  {
    "sym": "CVX",
    "price": "190.85",
    "chg": "+1.22%",
    "rs14": "42.79",
    "ivpct": "89%",
    "ivhv": "1.0945813528336",
    "iv": "29.94%",
    "iv5d": "30.29%",
    "iv1m": "29.97%",
    "iv3m": "27.44%",
    "iv6m": "24.49%",
    "bb": "12%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "5.56",
    "opvol": "34852",
    "callvol": "27077",
    "putvol": "7775"
  },
  {
    "sym": "WGS",
    "price": "60.36",
    "chg": "+1.24%",
    "rs14": "36.31",
    "ivpct": "75%",
    "ivhv": "1.2962122178294",
    "iv": "101.55%",
    "iv5d": "97.25%",
    "iv1m": "86.86%",
    "iv3m": "87.24%",
    "iv6m": "81.15%",
    "bb": "24%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "4.2",
    "opvol": "874",
    "callvol": "406",
    "putvol": "468"
  },
  {
    "sym": "AVGO",
    "price": "376.25",
    "chg": "+1.26%",
    "rs14": "72.33",
    "ivpct": "38%",
    "ivhv": "1.0397986270023",
    "iv": "44.90%",
    "iv5d": "45.14%",
    "iv1m": "45.98%",
    "iv3m": "51.45%",
    "iv6m": "49.32%",
    "bb": "110%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "10.19",
    "opvol": "197490",
    "callvol": "98208",
    "putvol": "99282"
  },
  {
    "sym": "LHX",
    "price": "358.14",
    "chg": "+1.29%",
    "rs14": "53.3",
    "ivpct": "83%",
    "ivhv": "1.1695920577617",
    "iv": "31.64%",
    "iv5d": "32.31%",
    "iv1m": "33.71%",
    "iv3m": "31.61%",
    "iv6m": "28.15%",
    "bb": "64%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "8.48",
    "opvol": "459",
    "callvol": "295",
    "putvol": "164"
  },
  {
    "sym": "ULTA",
    "price": "527.23",
    "chg": "+1.32%",
    "rs14": "37.78",
    "ivpct": "54%",
    "ivhv": "0.7075406907503",
    "iv": "36.08%",
    "iv5d": "36.18%",
    "iv1m": "36.23%",
    "iv3m": "37.95%",
    "iv6m": "35.22%",
    "bb": "55%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "15.06",
    "opvol": "1080",
    "callvol": "653",
    "putvol": "427"
  },
  {
    "sym": "WDC",
    "price": "348.08",
    "chg": "+1.35%",
    "rs14": "66.78",
    "ivpct": "84%",
    "ivhv": "1.0549981129702",
    "iv": "83.52%",
    "iv5d": "84.17%",
    "iv1m": "82.66%",
    "iv3m": "84.36%",
    "iv6m": "76.57%",
    "bb": "95%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "18.63",
    "opvol": "20032",
    "callvol": "10313",
    "putvol": "9719"
  },
  {
    "sym": "BLK",
    "price": "1013.77",
    "chg": "+1.45%",
    "rs14": "58.01",
    "ivpct": "86%",
    "ivhv": "0.95763120160596",
    "iv": "32.77%",
    "iv5d": "34.35%",
    "iv1m": "36.99%",
    "iv3m": "31.91%",
    "iv6m": "28.36%",
    "bb": "102%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "22.9",
    "opvol": "2240",
    "callvol": "947",
    "putvol": "1293"
  },
  {
    "sym": "CEG",
    "price": "291.01",
    "chg": "+1.57%",
    "rs14": "48.69",
    "ivpct": "63%",
    "ivhv": "1.069484454939",
    "iv": "52.84%",
    "iv5d": "52.44%",
    "iv1m": "54.64%",
    "iv3m": "54.05%",
    "iv6m": "51.60%",
    "bb": "48%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "11.22",
    "opvol": "4855",
    "callvol": "2633",
    "putvol": "2222"
  },
  {
    "sym": "EBAY",
    "price": "96.93",
    "chg": "+1.60%",
    "rs14": "62.99",
    "ivpct": "88%",
    "ivhv": "1.5985199240987",
    "iv": "43.04%",
    "iv5d": "42.03%",
    "iv1m": "39.30%",
    "iv3m": "38.77%",
    "iv6m": "35.12%",
    "bb": "88%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.68",
    "opvol": "1937",
    "callvol": "916",
    "putvol": "1021"
  },
  {
    "sym": "AMBA",
    "price": "53.63",
    "chg": "+1.61%",
    "rs14": "48.76",
    "ivpct": "41%",
    "ivhv": "1.315239223117",
    "iv": "55.85%",
    "iv5d": "55.21%",
    "iv1m": "56.60%",
    "iv3m": "66.14%",
    "iv6m": "64.81%",
    "bb": "68%",
    "bbr": "Above Mid",
    "ttm": "Long",
    "adr14": "2.08",
    "opvol": "532",
    "callvol": "127",
    "putvol": "405"
  },
  {
    "sym": "IRM",
    "price": "111.16",
    "chg": "+1.64%",
    "rs14": "66.03",
    "ivpct": "90%",
    "ivhv": "1.3723409405256",
    "iv": "39.79%",
    "iv5d": "39.93%",
    "iv1m": "38.68%",
    "iv3m": "37.88%",
    "iv6m": "35.48%",
    "bb": "97%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.75",
    "opvol": "358",
    "callvol": "245",
    "putvol": "113"
  },
  {
    "sym": "GLW",
    "price": "174.25",
    "chg": "+1.76%",
    "rs14": "70.86",
    "ivpct": "100%",
    "ivhv": "0.99836998706339",
    "iv": "76.87%",
    "iv5d": "75.21%",
    "iv1m": "69.35%",
    "iv3m": "61.97%",
    "iv6m": "52.17%",
    "bb": "101%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "8.73",
    "opvol": "25043",
    "callvol": "13280",
    "putvol": "11763"
  },
  {
    "sym": "JBL",
    "price": "304.77",
    "chg": "+1.76%",
    "rs14": "67.72",
    "ivpct": "60%",
    "ivhv": "0.8659996021484",
    "iv": "43.78%",
    "iv5d": "46.22%",
    "iv1m": "47.83%",
    "iv3m": "49.80%",
    "iv6m": "46.31%",
    "bb": "107%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "11.22",
    "opvol": "4577",
    "callvol": "3949",
    "putvol": "628"
  },
  {
    "sym": "SHAK",
    "price": "100.41",
    "chg": "+1.83%",
    "rs14": "64.5",
    "ivpct": "84%",
    "ivhv": "1.2854338579328",
    "iv": "60.54%",
    "iv5d": "60.22%",
    "iv1m": "56.07%",
    "iv3m": "54.71%",
    "iv6m": "51.94%",
    "bb": "101%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "3.79",
    "opvol": "1819",
    "callvol": "768",
    "putvol": "1051"
  },
  {
    "sym": "BA",
    "price": "221.61",
    "chg": "+1.83%",
    "rs14": "58.54",
    "ivpct": "88%",
    "ivhv": "0.98102077001013",
    "iv": "38.36%",
    "iv5d": "39.16%",
    "iv1m": "39.25%",
    "iv3m": "34.83%",
    "iv6m": "32.68%",
    "bb": "91%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "5.11",
    "opvol": "37788",
    "callvol": "18261",
    "putvol": "19527"
  },
  {
    "sym": "HOOD",
    "price": "70.49",
    "chg": "+1.88%",
    "rs14": "46.14",
    "ivpct": "71%",
    "ivhv": "1.2790938924339",
    "iv": "69.87%",
    "iv5d": "70.33%",
    "iv1m": "68.56%",
    "iv3m": "68.89%",
    "iv6m": "65.97%",
    "bb": "50%",
    "bbr": "Below Mid",
    "ttm": "On",
    "adr14": "3.54",
    "opvol": "145827",
    "callvol": "98818",
    "putvol": "47009"
  },
  {
    "sym": "BSX",
    "price": "62.96",
    "chg": "+1.89%",
    "rs14": "34.37",
    "ivpct": "93%",
    "ivhv": "1.1838888888889",
    "iv": "41.74%",
    "iv5d": "40.29%",
    "iv1m": "43.35%",
    "iv3m": "36.52%",
    "iv6m": "30.31%",
    "bb": "28%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "1.75",
    "opvol": "8136",
    "callvol": "5004",
    "putvol": "3132"
  },
  {
    "sym": "DIS",
    "price": "101.09",
    "chg": "+1.94%",
    "rs14": "56.75",
    "ivpct": "79%",
    "ivhv": "1.7048007870143",
    "iv": "35.04%",
    "iv5d": "34.70%",
    "iv1m": "32.33%",
    "iv3m": "30.66%",
    "iv6m": "29.76%",
    "bb": "91%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "1.94",
    "opvol": "17920",
    "callvol": "10137",
    "putvol": "7783"
  },
  {
    "sym": "PGR",
    "price": "198",
    "chg": "+1.99%",
    "rs14": "45.27",
    "ivpct": "80%",
    "ivhv": "1.4367163461538",
    "iv": "30.04%",
    "iv5d": "30.34%",
    "iv1m": "31.03%",
    "iv3m": "29.87%",
    "iv6m": "29.06%",
    "bb": "35%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "4.51",
    "opvol": "1443",
    "callvol": "667",
    "putvol": "776"
  },
  {
    "sym": "AXP",
    "price": "319.94",
    "chg": "+2.05%",
    "rs14": "58.63",
    "ivpct": "88%",
    "ivhv": "1.6878485864878",
    "iv": "35.01%",
    "iv5d": "35.71%",
    "iv1m": "36.11%",
    "iv3m": "33.69%",
    "iv6m": "29.79%",
    "bb": "101%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "7.21",
    "opvol": "6946",
    "callvol": "3297",
    "putvol": "3649"
  },
  {
    "sym": "LVS",
    "price": "54.55",
    "chg": "+2.06%",
    "rs14": "51.24",
    "ivpct": "89%",
    "ivhv": "1.7008189482136",
    "iv": "44.34%",
    "iv5d": "44.83%",
    "iv1m": "43.58%",
    "iv3m": "39.92%",
    "iv6m": "37.44%",
    "bb": "72%",
    "bbr": "New Above Mid",
    "ttm": "On",
    "adr14": "1.46",
    "opvol": "1546",
    "callvol": "906",
    "putvol": "640"
  },
  {
    "sym": "EL",
    "price": "74.28",
    "chg": "+2.22%",
    "rs14": "41.09",
    "ivpct": "94%",
    "ivhv": "1.0693395152107",
    "iv": "65.20%",
    "iv5d": "65.46%",
    "iv1m": "59.81%",
    "iv3m": "49.73%",
    "iv6m": "45.59%",
    "bb": "47%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "3.37",
    "opvol": "3465",
    "callvol": "2200",
    "putvol": "1265"
  },
  {
    "sym": "XYZ",
    "price": "63.58",
    "chg": "+2.22%",
    "rs14": "59.56",
    "ivpct": "85%",
    "ivhv": "1.4710156609857",
    "iv": "64.06%",
    "iv5d": "63.53%",
    "iv1m": "58.95%",
    "iv3m": "57.00%",
    "iv6m": "52.91%",
    "bb": "101%",
    "bbr": "New Above Upper",
    "ttm": "Long",
    "adr14": "2.46",
    "opvol": "8720",
    "callvol": "6413",
    "putvol": "2307"
  },
  {
    "sym": "AAP",
    "price": "55.81",
    "chg": "+2.23%",
    "rs14": "58.78",
    "ivpct": "40%",
    "ivhv": "1.1761169056932",
    "iv": "54.30%",
    "iv5d": "55.86%",
    "iv1m": "57.50%",
    "iv3m": "62.83%",
    "iv6m": "59.43%",
    "bb": "90%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "2.11",
    "opvol": "1387",
    "callvol": "1105",
    "putvol": "282"
  },
  {
    "sym": "UNH",
    "price": "311.2",
    "chg": "+2.26%",
    "rs14": "67.21",
    "ivpct": "45%",
    "ivhv": "1.0061073636875",
    "iv": "35.77%",
    "iv5d": "35.49%",
    "iv1m": "42.36%",
    "iv3m": "37.96%",
    "iv6m": "36.45%",
    "bb": "95%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "7.52",
    "opvol": "61137",
    "callvol": "36741",
    "putvol": "24396"
  },
  {
    "sym": "TTWO",
    "price": "201.57",
    "chg": "+2.28%",
    "rs14": "50.23",
    "ivpct": "99%",
    "ivhv": "1.80778125",
    "iv": "46.23%",
    "iv5d": "44.76%",
    "iv1m": "41.66%",
    "iv3m": "39.41%",
    "iv6m": "35.27%",
    "bb": "66%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "5.7",
    "opvol": "1177",
    "callvol": "733",
    "putvol": "444"
  },
  {
    "sym": "FTNT",
    "price": "78.49",
    "chg": "+2.33%",
    "rs14": "43.34",
    "ivpct": "96%",
    "ivhv": "1.7401127361365",
    "iv": "57.05%",
    "iv5d": "55.01%",
    "iv1m": "46.57%",
    "iv3m": "44.50%",
    "iv6m": "40.81%",
    "bb": "17%",
    "bbr": "New Above Lower",
    "ttm": "Short",
    "adr14": "3",
    "opvol": "11810",
    "callvol": "10373",
    "putvol": "1437"
  },
  {
    "sym": "DHR",
    "price": "194.07",
    "chg": "+2.35%",
    "rs14": "49.45",
    "ivpct": "86%",
    "ivhv": "1.2333688552767",
    "iv": "35.62%",
    "iv5d": "35.94%",
    "iv1m": "34.42%",
    "iv3m": "30.51%",
    "iv6m": "28.67%",
    "bb": "76%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "4.6",
    "opvol": "1157",
    "callvol": "791",
    "putvol": "366"
  },
  {
    "sym": "COIN",
    "price": "171.87",
    "chg": "+2.39%",
    "rs14": "44.97",
    "ivpct": "96%",
    "ivhv": "1.1020109478536",
    "iv": "76.17%",
    "iv5d": "75.69%",
    "iv1m": "73.86%",
    "iv3m": "70.38%",
    "iv6m": "64.98%",
    "bb": "36%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "10.66",
    "opvol": "69041",
    "callvol": "48973",
    "putvol": "20068"
  },
  {
    "sym": "GDDY",
    "price": "81.21",
    "chg": "+2.42%",
    "rs14": "44.79",
    "ivpct": "98%",
    "ivhv": "1.4594762024679",
    "iv": "56.57%",
    "iv5d": "56.14%",
    "iv1m": "51.31%",
    "iv3m": "49.46%",
    "iv6m": "41.05%",
    "bb": "42%",
    "bbr": "Below Mid",
    "ttm": "On",
    "adr14": "3.01",
    "opvol": "2441",
    "callvol": "618",
    "putvol": "1823"
  },
  {
    "sym": "IBM",
    "price": "236.38",
    "chg": "+2.44%",
    "rs14": "41.74",
    "ivpct": "98%",
    "ivhv": "1.5651136363636",
    "iv": "44.77%",
    "iv5d": "43.78%",
    "iv1m": "40.09%",
    "iv3m": "37.81%",
    "iv6m": "34.05%",
    "bb": "22%",
    "bbr": "New Above Lower",
    "ttm": "Short",
    "adr14": "6.68",
    "opvol": "16427",
    "callvol": "12189",
    "putvol": "4238"
  },
  {
    "sym": "ANET",
    "price": "151",
    "chg": "+2.48%",
    "rs14": "65.96",
    "ivpct": "83%",
    "ivhv": "0.99700421257291",
    "iv": "62.18%",
    "iv5d": "61.57%",
    "iv1m": "56.93%",
    "iv3m": "56.92%",
    "iv6m": "53.91%",
    "bb": "101%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "5.57",
    "opvol": "12523",
    "callvol": "7664",
    "putvol": "4859"
  },
  {
    "sym": "DG",
    "price": "118.63",
    "chg": "+2.51%",
    "rs14": "38.38",
    "ivpct": "55%",
    "ivhv": "0.95451772679875",
    "iv": "36.50%",
    "iv5d": "36.61%",
    "iv1m": "36.44%",
    "iv3m": "41.36%",
    "iv6m": "38.51%",
    "bb": "33%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "3.96",
    "opvol": "1588",
    "callvol": "941",
    "putvol": "647"
  },
  {
    "sym": "CHTR",
    "price": "224.31",
    "chg": "+2.51%",
    "rs14": "55",
    "ivpct": "85%",
    "ivhv": "1.9049014084507",
    "iv": "60.13%",
    "iv5d": "58.92%",
    "iv1m": "53.78%",
    "iv3m": "50.35%",
    "iv6m": "51.07%",
    "bb": "90%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "8.11",
    "opvol": "1558",
    "callvol": "572",
    "putvol": "986"
  },
  {
    "sym": "VST",
    "price": "158.83",
    "chg": "+2.65%",
    "rs14": "53.15",
    "ivpct": "77%",
    "ivhv": "1.0689642793035",
    "iv": "59.93%",
    "iv5d": "58.40%",
    "iv1m": "57.58%",
    "iv3m": "56.68%",
    "iv6m": "54.72%",
    "bb": "68%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "6.73",
    "opvol": "10155",
    "callvol": "7333",
    "putvol": "2822"
  },
  {
    "sym": "ADP",
    "price": "193.82",
    "chg": "+2.66%",
    "rs14": "36.14",
    "ivpct": "98%",
    "ivhv": "1.3784020416176",
    "iv": "35.32%",
    "iv5d": "35.20%",
    "iv1m": "33.60%",
    "iv3m": "30.15%",
    "iv6m": "25.80%",
    "bb": "8%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "6",
    "opvol": "2398",
    "callvol": "943",
    "putvol": "1455"
  },
  {
    "sym": "DLTR",
    "price": "102.23",
    "chg": "+2.69%",
    "rs14": "37.96",
    "ivpct": "47%",
    "ivhv": "1.0216919907288",
    "iv": "39.22%",
    "iv5d": "39.78%",
    "iv1m": "40.15%",
    "iv3m": "44.56%",
    "iv6m": "41.81%",
    "bb": "15%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "3.69",
    "opvol": "2042",
    "callvol": "1336",
    "putvol": "706"
  },
  {
    "sym": "TMO",
    "price": "509.58",
    "chg": "+2.72%",
    "rs14": "56.47",
    "ivpct": "86%",
    "ivhv": "1.2825008793528",
    "iv": "36.50%",
    "iv5d": "35.81%",
    "iv1m": "34.91%",
    "iv3m": "31.22%",
    "iv6m": "28.81%",
    "bb": "97%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "14.14",
    "opvol": "815",
    "callvol": "533",
    "putvol": "282"
  },
  {
    "sym": "MSFT",
    "price": "381.87",
    "chg": "+2.97%",
    "rs14": "49.32",
    "ivpct": "99%",
    "ivhv": "1.7501400560224",
    "iv": "37.57%",
    "iv5d": "35.63%",
    "iv1m": "31.90%",
    "iv3m": "30.27%",
    "iv6m": "27.28%",
    "bb": "62%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "8.16",
    "opvol": "803224",
    "callvol": "617209",
    "putvol": "186015"
  },
  {
    "sym": "IBKR",
    "price": "73.36",
    "chg": "+3.02%",
    "rs14": "61.19",
    "ivpct": "82%",
    "ivhv": "1.1369086294416",
    "iv": "44.99%",
    "iv5d": "45.79%",
    "iv1m": "48.87%",
    "iv3m": "44.07%",
    "iv6m": "41.50%",
    "bb": "104%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "2.46",
    "opvol": "2582",
    "callvol": "1582",
    "putvol": "1000"
  },
  {
    "sym": "SPGI",
    "price": "428.03",
    "chg": "+3.04%",
    "rs14": "49.3",
    "ivpct": "91%",
    "ivhv": "1.296",
    "iv": "34.10%",
    "iv5d": "34.14%",
    "iv1m": "34.69%",
    "iv3m": "31.49%",
    "iv6m": "26.36%",
    "bb": "61%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "11.28",
    "opvol": "1190",
    "callvol": "523",
    "putvol": "667"
  },
  {
    "sym": "NRG",
    "price": "169.06",
    "chg": "+3.04%",
    "rs14": "62.05",
    "ivpct": "79%",
    "ivhv": "0.94475221405691",
    "iv": "50.71%",
    "iv5d": "50.80%",
    "iv1m": "50.99%",
    "iv3m": "49.52%",
    "iv6m": "47.44%",
    "bb": "103%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "5.65",
    "opvol": "2099",
    "callvol": "1807",
    "putvol": "292"
  },
  {
    "sym": "HUM",
    "price": "198.02",
    "chg": "+3.05%",
    "rs14": "63.32",
    "ivpct": "69%",
    "ivhv": "1.3689495052017",
    "iv": "53.81%",
    "iv5d": "55.12%",
    "iv1m": "63.99%",
    "iv3m": "56.97%",
    "iv6m": "49.18%",
    "bb": "93%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "6.95",
    "opvol": "9890",
    "callvol": "5649",
    "putvol": "4241"
  },
  {
    "sym": "UBER",
    "price": "72.77",
    "chg": "+3.25%",
    "rs14": "48.3",
    "ivpct": "88%",
    "ivhv": "1.449025328631",
    "iv": "46.34%",
    "iv5d": "45.21%",
    "iv1m": "42.07%",
    "iv3m": "40.41%",
    "iv6m": "38.44%",
    "bb": "45%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "2.18",
    "opvol": "40664",
    "callvol": "25078",
    "putvol": "15586"
  },
  {
    "sym": "LYV",
    "price": "165.84",
    "chg": "+3.27%",
    "rs14": "61.47",
    "ivpct": "88%",
    "ivhv": "1.115838641189",
    "iv": "42.18%",
    "iv5d": "40.58%",
    "iv1m": "38.63%",
    "iv3m": "39.03%",
    "iv6m": "36.24%",
    "bb": "100%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "5",
    "opvol": "4156",
    "callvol": "2716",
    "putvol": "1440"
  },
  {
    "sym": "ADSK",
    "price": "225.81",
    "chg": "+3.37%",
    "rs14": "41.23",
    "ivpct": "92%",
    "ivhv": "1.1753361702128",
    "iv": "42.43%",
    "iv5d": "42.31%",
    "iv1m": "40.07%",
    "iv3m": "40.76%",
    "iv6m": "34.74%",
    "bb": "17%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "8.82",
    "opvol": "1082",
    "callvol": "762",
    "putvol": "320"
  },
  {
    "sym": "ON",
    "price": "70.99",
    "chg": "+3.41%",
    "rs14": "68.58",
    "ivpct": "84%",
    "ivhv": "1.0961767895879",
    "iv": "60.65%",
    "iv5d": "58.94%",
    "iv1m": "55.81%",
    "iv3m": "54.03%",
    "iv6m": "52.97%",
    "bb": "106%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "2.64",
    "opvol": "5396",
    "callvol": "4811",
    "putvol": "585"
  },
  {
    "sym": "SHOP",
    "price": "114.69",
    "chg": "+3.52%",
    "rs14": "45.06",
    "ivpct": "92%",
    "ivhv": "1.4740224134481",
    "iv": "73.85%",
    "iv5d": "73.40%",
    "iv1m": "68.13%",
    "iv3m": "65.13%",
    "iv6m": "58.06%",
    "bb": "34%",
    "bbr": "Below Mid",
    "ttm": "On",
    "adr14": "5.72",
    "opvol": "24124",
    "callvol": "14827",
    "putvol": "9297"
  },
  {
    "sym": "ZS",
    "price": "122.23",
    "chg": "+3.54%",
    "rs14": "31.98",
    "ivpct": "94%",
    "ivhv": "1.1852876859652",
    "iv": "66.10%",
    "iv5d": "64.35%",
    "iv1m": "58.09%",
    "iv3m": "58.21%",
    "iv6m": "49.53%",
    "bb": "9%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "7.6",
    "opvol": "13908",
    "callvol": "10484",
    "putvol": "3424"
  },
  {
    "sym": "ALGN",
    "price": "179.54",
    "chg": "+3.70%",
    "rs14": "54.6",
    "ivpct": "85%",
    "ivhv": "1.3285817037537",
    "iv": "58.75%",
    "iv5d": "56.52%",
    "iv1m": "50.20%",
    "iv3m": "47.01%",
    "iv6m": "45.59%",
    "bb": "81%",
    "bbr": "Above Mid",
    "ttm": "On",
    "adr14": "6.99",
    "opvol": "434",
    "callvol": "205",
    "putvol": "229"
  },
  {
    "sym": "PANW",
    "price": "161.51",
    "chg": "+3.71%",
    "rs14": "49.37",
    "ivpct": "92%",
    "ivhv": "1.0124941327075",
    "iv": "47.62%",
    "iv5d": "44.60%",
    "iv1m": "40.60%",
    "iv3m": "42.56%",
    "iv6m": "38.11%",
    "bb": "48%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "7.72",
    "opvol": "28967",
    "callvol": "19989",
    "putvol": "8978"
  },
  {
    "sym": "DASH",
    "price": "158.37",
    "chg": "+3.79%",
    "rs14": "48.04",
    "ivpct": "97%",
    "ivhv": "1.7108204216408",
    "iv": "67.47%",
    "iv5d": "65.52%",
    "iv1m": "60.16%",
    "iv3m": "58.82%",
    "iv6m": "51.19%",
    "bb": "60%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "6.9",
    "opvol": "4082",
    "callvol": "2781",
    "putvol": "1301"
  },
  {
    "sym": "DDOG",
    "price": "109.51",
    "chg": "+3.93%",
    "rs14": "39.48",
    "ivpct": "98%",
    "ivhv": "1.5366881091618",
    "iv": "78.41%",
    "iv5d": "75.04%",
    "iv1m": "64.08%",
    "iv3m": "63.17%",
    "iv6m": "53.20%",
    "bb": "13%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "6.83",
    "opvol": "20229",
    "callvol": "9407",
    "putvol": "10822"
  },
  {
    "sym": "ARM",
    "price": "155.15",
    "chg": "+4.18%",
    "rs14": "63.51",
    "ivpct": "90%",
    "ivhv": "0.95280826700182",
    "iv": "68.50%",
    "iv5d": "65.40%",
    "iv1m": "60.93%",
    "iv3m": "58.43%",
    "iv6m": "56.77%",
    "bb": "82%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "9.22",
    "opvol": "53723",
    "callvol": "37718",
    "putvol": "16005"
  },
  {
    "sym": "AKAM",
    "price": "95.2",
    "chg": "+4.21%",
    "rs14": "37.72",
    "ivpct": "97%",
    "ivhv": "0.99491540649798",
    "iv": "66.57%",
    "iv5d": "61.72%",
    "iv1m": "51.35%",
    "iv3m": "50.62%",
    "iv6m": "43.98%",
    "bb": "-5%",
    "bbr": "Below Lower",
    "ttm": "0",
    "adr14": "6.2",
    "opvol": "8453",
    "callvol": "4277",
    "putvol": "4176"
  },
  {
    "sym": "PLTR",
    "price": "133.53",
    "chg": "+4.27%",
    "rs14": "40.56",
    "ivpct": "75%",
    "ivhv": "1.1455738297488",
    "iv": "63.56%",
    "iv5d": "62.84%",
    "iv1m": "56.48%",
    "iv3m": "56.49%",
    "iv6m": "55.41%",
    "bb": "13%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "7.66",
    "opvol": "526489",
    "callvol": "372882",
    "putvol": "153607"
  },
  {
    "sym": "APO",
    "price": "108.87",
    "chg": "+4.40%",
    "rs14": "48.77",
    "ivpct": "88%",
    "ivhv": "1.3796210643633",
    "iv": "49.11%",
    "iv5d": "49.00%",
    "iv1m": "49.84%",
    "iv3m": "44.74%",
    "iv6m": "39.71%",
    "bb": "56%",
    "bbr": "New Above Mid",
    "ttm": "On",
    "adr14": "4.38",
    "opvol": "12237",
    "callvol": "5316",
    "putvol": "6921"
  },
  {
    "sym": "BE",
    "price": "174.04",
    "chg": "+4.40%",
    "rs14": "62.83",
    "ivpct": "68%",
    "ivhv": "1.0522114149385",
    "iv": "115.72%",
    "iv5d": "112.40%",
    "iv1m": "110.50%",
    "iv3m": "114.98%",
    "iv6m": "116.76%",
    "bb": "99%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "12.72",
    "opvol": "39926",
    "callvol": "17537",
    "putvol": "22389"
  },
  {
    "sym": "CRM",
    "price": "172.43",
    "chg": "+4.53%",
    "rs14": "37.62",
    "ivpct": "68%",
    "ivhv": "1.1224776500639",
    "iv": "43.56%",
    "iv5d": "43.47%",
    "iv1m": "41.77%",
    "iv3m": "44.11%",
    "iv6m": "39.65%",
    "bb": "15%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "7.02",
    "opvol": "54296",
    "callvol": "40988",
    "putvol": "13308"
  },
  {
    "sym": "EXPE",
    "price": "238.44",
    "chg": "+4.54%",
    "rs14": "54.84",
    "ivpct": "91%",
    "ivhv": "1.223250694169",
    "iv": "60.97%",
    "iv5d": "62.29%",
    "iv1m": "57.79%",
    "iv3m": "55.08%",
    "iv6m": "46.85%",
    "bb": "76%",
    "bbr": "New Above Mid",
    "ttm": "On",
    "adr14": "10.68",
    "opvol": "1666",
    "callvol": "830",
    "putvol": "836"
  },
  {
    "sym": "CVNA",
    "price": "351.95",
    "chg": "+4.65%",
    "rs14": "60.75",
    "ivpct": "84%",
    "ivhv": "1.424375320458",
    "iv": "83.74%",
    "iv5d": "83.56%",
    "iv1m": "79.85%",
    "iv3m": "78.32%",
    "iv6m": "69.39%",
    "bb": "109%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "18.01",
    "opvol": "50563",
    "callvol": "32539",
    "putvol": "18024"
  },
  {
    "sym": "FISV",
    "price": "58.74",
    "chg": "+4.72%",
    "rs14": "55.71",
    "ivpct": "93%",
    "ivhv": "1.9846310679612",
    "iv": "62.14%",
    "iv5d": "59.94%",
    "iv1m": "55.17%",
    "iv3m": "53.92%",
    "iv6m": "48.93%",
    "bb": "104%",
    "bbr": "New Above Upper",
    "ttm": "On",
    "adr14": "1.89",
    "opvol": "14495",
    "callvol": "12603",
    "putvol": "1892"
  },
  {
    "sym": "KTOS",
    "price": "73.8",
    "chg": "+4.92%",
    "rs14": "44.84",
    "ivpct": "79%",
    "ivhv": "1.0272003532677",
    "iv": "80.46%",
    "iv5d": "80.03%",
    "iv1m": "79.21%",
    "iv3m": "80.66%",
    "iv6m": "74.90%",
    "bb": "40%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "5.14",
    "opvol": "3922",
    "callvol": "2822",
    "putvol": "1100"
  },
  {
    "sym": "HUT",
    "price": "69.36",
    "chg": "+4.96%",
    "rs14": "70.41",
    "ivpct": "70%",
    "ivhv": "0.98301526717557",
    "iv": "104.63%",
    "iv5d": "102.14%",
    "iv1m": "101.32%",
    "iv3m": "103.44%",
    "iv6m": "107.79%",
    "bb": "111%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "4.45",
    "opvol": "20882",
    "callvol": "14285",
    "putvol": "6597"
  },
  {
    "sym": "BX",
    "price": "120.55",
    "chg": "+4.98%",
    "rs14": "59.48",
    "ivpct": "83%",
    "ivhv": "1.0933236574746",
    "iv": "45.30%",
    "iv5d": "46.32%",
    "iv1m": "48.08%",
    "iv3m": "43.38%",
    "iv6m": "37.82%",
    "bb": "110%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "4.04",
    "opvol": "13953",
    "callvol": "9392",
    "putvol": "4561"
  },
  {
    "sym": "INTU",
    "price": "368.48",
    "chg": "+5.00%",
    "rs14": "33.8",
    "ivpct": "93%",
    "ivhv": "1.1031920903955",
    "iv": "54.41%",
    "iv5d": "54.58%",
    "iv1m": "48.92%",
    "iv3m": "49.82%",
    "iv6m": "40.17%",
    "bb": "7%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "18.86",
    "opvol": "8771",
    "callvol": "5403",
    "putvol": "3368"
  },
  {
    "sym": "OKLO",
    "price": "52.85",
    "chg": "+5.17%",
    "rs14": "47.83",
    "ivpct": "32%",
    "ivhv": "1.3097406340058",
    "iv": "96.15%",
    "iv5d": "94.66%",
    "iv1m": "91.26%",
    "iv3m": "96.07%",
    "iv6m": "100.94%",
    "bb": "56%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "3.68",
    "opvol": "41942",
    "callvol": "32850",
    "putvol": "9092"
  },
  {
    "sym": "ARES",
    "price": "105.66",
    "chg": "+5.18%",
    "rs14": "46.55",
    "ivpct": "86%",
    "ivhv": "1.1212409062565",
    "iv": "54.00%",
    "iv5d": "56.29%",
    "iv1m": "58.27%",
    "iv3m": "52.34%",
    "iv6m": "44.86%",
    "bb": "59%",
    "bbr": "New Above Mid",
    "ttm": "On",
    "adr14": "5.02",
    "opvol": "3659",
    "callvol": "2772",
    "putvol": "887"
  },
  {
    "sym": "DELL",
    "price": "187.27",
    "chg": "+5.33%",
    "rs14": "67.92",
    "ivpct": "72%",
    "ivhv": "1.0823728478132",
    "iv": "55.02%",
    "iv5d": "51.89%",
    "iv1m": "51.37%",
    "iv3m": "53.40%",
    "iv6m": "50.84%",
    "bb": "92%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "8.85",
    "opvol": "50228",
    "callvol": "33484",
    "putvol": "16744"
  },
  {
    "sym": "LMND",
    "price": "57.46",
    "chg": "+5.53%",
    "rs14": "45.16",
    "ivpct": "70%",
    "ivhv": "1.2586097835254",
    "iv": "89.16%",
    "iv5d": "88.81%",
    "iv1m": "84.02%",
    "iv3m": "86.80%",
    "iv6m": "83.49%",
    "bb": "23%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "3.78",
    "opvol": "5650",
    "callvol": "4132",
    "putvol": "1518"
  },
  {
    "sym": "SNPS",
    "price": "414.56",
    "chg": "+5.69%",
    "rs14": "50.8",
    "ivpct": "67%",
    "ivhv": "1.2245958795563",
    "iv": "45.53%",
    "iv5d": "46.04%",
    "iv1m": "47.19%",
    "iv3m": "49.32%",
    "iv6m": "46.69%",
    "bb": "59%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "15",
    "opvol": "2791",
    "callvol": "1837",
    "putvol": "954"
  },
  {
    "sym": "DAVE",
    "price": "196.01",
    "chg": "+5.72%",
    "rs14": "55.28",
    "ivpct": "44%",
    "ivhv": "1.2059895570153",
    "iv": "71.81%",
    "iv5d": "70.54%",
    "iv1m": "71.76%",
    "iv3m": "75.52%",
    "iv6m": "73.95%",
    "bb": "61%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "11.46",
    "opvol": "1363",
    "callvol": "1009",
    "putvol": "354"
  },
  {
    "sym": "FIS",
    "price": "45.85",
    "chg": "+5.72%",
    "rs14": "42.49",
    "ivpct": "96%",
    "ivhv": "1.4144889840881",
    "iv": "46.12%",
    "iv5d": "45.56%",
    "iv1m": "41.88%",
    "iv3m": "40.39%",
    "iv6m": "36.08%",
    "bb": "29%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "1.71",
    "opvol": "2246",
    "callvol": "2094",
    "putvol": "152"
  },
  {
    "sym": "ACN",
    "price": "190.11",
    "chg": "+5.89%",
    "rs14": "41.95",
    "ivpct": "72%",
    "ivhv": "1.1380452164323",
    "iv": "41.05%",
    "iv5d": "40.92%",
    "iv1m": "42.87%",
    "iv3m": "43.49%",
    "iv6m": "38.70%",
    "bb": "25%",
    "bbr": "New Above Lower",
    "ttm": "On",
    "adr14": "6.85",
    "opvol": "5476",
    "callvol": "3813",
    "putvol": "1663"
  },
  {
    "sym": "ADBE",
    "price": "238.69",
    "chg": "+5.92%",
    "rs14": "43.18",
    "ivpct": "61%",
    "ivhv": "1.0177570326114",
    "iv": "40.45%",
    "iv5d": "40.31%",
    "iv1m": "39.52%",
    "iv3m": "43.59%",
    "iv6m": "39.58%",
    "bb": "39%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "7.96",
    "opvol": "42010",
    "callvol": "24125",
    "putvol": "17885"
  },
  {
    "sym": "APP",
    "price": "414.71",
    "chg": "+5.96%",
    "rs14": "48.93",
    "ivpct": "90%",
    "ivhv": "1.3062458852154",
    "iv": "91.71%",
    "iv5d": "87.23%",
    "iv1m": "78.71%",
    "iv3m": "80.06%",
    "iv6m": "71.70%",
    "bb": "51%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "26.54",
    "opvol": "32457",
    "callvol": "23563",
    "putvol": "8894"
  },
  {
    "sym": "CRWD",
    "price": "401.65",
    "chg": "+5.97%",
    "rs14": "49.06",
    "ivpct": "70%",
    "ivhv": "0.94436614396373",
    "iv": "49.99%",
    "iv5d": "48.46%",
    "iv1m": "46.29%",
    "iv3m": "48.64%",
    "iv6m": "44.75%",
    "bb": "48%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "19.74",
    "opvol": "38104",
    "callvol": "22703",
    "putvol": "15401"
  },
  {
    "sym": "KKR",
    "price": "96.69",
    "chg": "+6.00%",
    "rs14": "58.63",
    "ivpct": "80%",
    "ivhv": "1.283644338118",
    "iv": "48.25%",
    "iv5d": "48.97%",
    "iv1m": "51.59%",
    "iv3m": "47.91%",
    "iv6m": "42.60%",
    "bb": "121%",
    "bbr": "New Above Upper",
    "ttm": "On",
    "adr14": "3.57",
    "opvol": "10667",
    "callvol": "7274",
    "putvol": "3393"
  },
  {
    "sym": "DOCN",
    "price": "80.14",
    "chg": "+6.02%",
    "rs14": "50.82",
    "ivpct": "99%",
    "ivhv": "1.2230070268961",
    "iv": "99.74%",
    "iv5d": "97.46%",
    "iv1m": "87.04%",
    "iv3m": "78.37%",
    "iv6m": "70.18%",
    "bb": "27%",
    "bbr": "Below Mid",
    "ttm": "0",
    "adr14": "6.96",
    "opvol": "4840",
    "callvol": "3071",
    "putvol": "1769"
  },
  {
    "sym": "CRSP",
    "price": "54.45",
    "chg": "+6.31%",
    "rs14": "60.77",
    "ivpct": "70%",
    "ivhv": "1.1774952198853",
    "iv": "64.16%",
    "iv5d": "68.44%",
    "iv1m": "63.67%",
    "iv3m": "61.47%",
    "iv6m": "63.55%",
    "bb": "111%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "2.19",
    "opvol": "3741",
    "callvol": "3126",
    "putvol": "615"
  },
  {
    "sym": "TEAM",
    "price": "60.77",
    "chg": "+6.33%",
    "rs14": "34.28",
    "ivpct": "99%",
    "ivhv": "1.6709805593452",
    "iv": "97.65%",
    "iv5d": "94.00%",
    "iv1m": "83.14%",
    "iv3m": "76.74%",
    "iv6m": "65.31%",
    "bb": "16%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "4.08",
    "opvol": "11446",
    "callvol": "8009",
    "putvol": "3437"
  },
  {
    "sym": "NOW",
    "price": "88.51",
    "chg": "+6.64%",
    "rs14": "32.38",
    "ivpct": "99%",
    "ivhv": "1.276",
    "iv": "71.19%",
    "iv5d": "66.79%",
    "iv1m": "57.19%",
    "iv3m": "52.66%",
    "iv6m": "45.28%",
    "bb": "8%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "5.34",
    "opvol": "99025",
    "callvol": "69019",
    "putvol": "30006"
  },
  {
    "sym": "LASR",
    "price": "69.9",
    "chg": "+6.93%",
    "rs14": "59.2",
    "ivpct": "98%",
    "ivhv": "1.0586876155268",
    "iv": "114.74%",
    "iv5d": "109.81%",
    "iv1m": "102.18%",
    "iv3m": "95.39%",
    "iv6m": "84.44%",
    "bb": "72%",
    "bbr": "Above Mid",
    "ttm": "0",
    "adr14": "5.29",
    "opvol": "2131",
    "callvol": "1388",
    "putvol": "743"
  },
  {
    "sym": "WDAY",
    "price": "120.6",
    "chg": "+7.20%",
    "rs14": "39.58",
    "ivpct": "96%",
    "ivhv": "1.1438990735265",
    "iv": "58.45%",
    "iv5d": "57.37%",
    "iv1m": "52.84%",
    "iv3m": "50.56%",
    "iv6m": "42.60%",
    "bb": "24%",
    "bbr": "New Above Lower",
    "ttm": "0",
    "adr14": "5.95",
    "opvol": "5930",
    "callvol": "4199",
    "putvol": "1731"
  },
  {
    "sym": "CDNS",
    "price": "285.84",
    "chg": "+7.60%",
    "rs14": "51.05",
    "ivpct": "98%",
    "ivhv": "1.3872712723393",
    "iv": "52.14%",
    "iv5d": "49.88%",
    "iv1m": "48.70%",
    "iv3m": "46.03%",
    "iv6m": "40.68%",
    "bb": "64%",
    "bbr": "New Above Mid",
    "ttm": "On",
    "adr14": "9.91",
    "opvol": "2524",
    "callvol": "1590",
    "putvol": "934"
  },
  {
    "sym": "SNDK",
    "price": "926.91",
    "chg": "+8.82%",
    "rs14": "72.03",
    "ivpct": "98%",
    "ivhv": "1.1741316639742",
    "iv": "118.04%",
    "iv5d": "107.78%",
    "iv1m": "100.12%",
    "iv3m": "102.48%",
    "iv6m": "102.64%",
    "bb": "108%",
    "bbr": "Above Upper",
    "ttm": "0",
    "adr14": "51.71",
    "opvol": "150576",
    "callvol": "67144",
    "putvol": "83432"
  },
  {
    "sym": "CRDO",
    "price": "132.68",
    "chg": "+10.95%",
    "rs14": "66.95",
    "ivpct": "58%",
    "ivhv": "0.9267055771725",
    "iv": "90.61%",
    "iv5d": "85.10%",
    "iv1m": "85.70%",
    "iv3m": "91.84%",
    "iv6m": "91.03%",
    "bb": "124%",
    "bbr": "New Above Upper",
    "ttm": "0",
    "adr14": "7.29",
    "opvol": "34473",
    "callvol": "25363",
    "putvol": "9110"
  },
  {
    "sym": "ORCL",
    "price": "153.39",
    "chg": "+11.08%",
    "rs14": "55.39",
    "ivpct": "75%",
    "ivhv": "1.0378645932107",
    "iv": "54.95%",
    "iv5d": "52.22%",
    "iv1m": "52.15%",
    "iv3m": "60.41%",
    "iv6m": "55.86%",
    "bb": "79%",
    "bbr": "New Above Mid",
    "ttm": "0",
    "adr14": "6.2",
    "opvol": "441707",
    "callvol": "342533",
    "putvol": "99174"
  }
]

'@
Write-File "react-frontend\src\data\watchlist.ts" $c

$c = @'
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
      {/* ── LEFT: brand + menu ── */}
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

      {/* ── CENTER: focal price display ── */}
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

      {/* ── RIGHT: balances ── */}
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
        <div className="tpill" style={{ minWidth: 80 }}>
          <span className="lbl">Source</span>
          <span className="val" style={{ fontSize: 11, color: 'var(--green)' }}>
            {quote.activeSource || '--'}
          </span>
        </div>

        {/* Account toggle */}
        <div style={{ display: 'flex', gap: 3, marginLeft: 4 }}>
          <button
            className={`btn sm${acctSource === 'tasty' ? ' active' : ''}`}
            onClick={() => setAcctSource('tasty')}
          >
            TASTY
          </button>
          <button
            className={`btn sm${acctSource === 'mock' ? ' active' : ''}`}
            onClick={() => setAcctSource('mock')}
            style={{ opacity: 0.5 }}
            title="Mock mode (for testing without live account)"
          >
            MOCK
          </button>
        </div>
      </div>
    </div>
  )
}

'@
Write-File "react-frontend\src\components\layout\TopBar.tsx" $c

$c = @'
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

'@
Write-File "react-frontend\src\components\layout\TotalsBar.tsx" $c

$c = @'
import { useState, useMemo, useRef } from 'react'
import { useStore } from '../../store/useStore'
import type { WatchlistRow } from '../../types'
import { WL_DATA } from '../../data/watchlist'

// ── Multi-watchlist storage ──────────────────────────────────
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

// ── IV Term Structure Heatmap ───────────────────────────────
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
          title={`${labels[i]} IV: ${v.toFixed(2)}%${rising ? ' (rising term ✓)' : ''}`}
        >
          {v > 0 ? v.toFixed(2) + '%' : '--'}
        </span>
      ))}
    </>
  )
}

// ── Expected weekly move from ImpVol ───────────────────────
function calcExpMove(priceStr: string, ivStr: string) {
  const price = parseFloat(priceStr) || 0
  const iv = parseFloat((ivStr || '').replace('%', '')) / 100 || 0
  if (!price || !iv) return null
  const move = price * iv * Math.sqrt(7 / 365)
  return { move, upper: price + move, lower: price - move }
}

// ── Range bar component ────────────────────────────────────
function ExpMoveBar({ price, move }: { price: number; move: number }) {
  const range = move * 2 * 1.5  // show 1.5x the move as total range
  const start = price - move * 1.5
  const pct   = (price - start) / range * 100
  const barW  = (move * 2) / range * 100
  const barL  = ((price - move) - start) / range * 100

  return (
    <div className="em-bar-wrap" title={`Weekly EM: ±$${move.toFixed(2)}`}>
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

  // ── Watchlist management ─────────────────────────────────
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

  // ── Colors ─────────────────────────────────────────────────
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

  // ── Row action handler ──────────────────────────────────────
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

      {/* Rows — fills all remaining height */}
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

'@
Write-File "react-frontend\src\components\tiles\WatchlistTile.tsx" $c

$c = @'
import { useMemo, useState } from 'react'
import {
  createColumnHelper,
  flexRender,
  getCoreRowModel,
  getSortedRowModel,
  useReactTable,
  type SortingState,
} from '@tanstack/react-table'
import { useStore } from '../../store/useStore'
import type { Position } from '../../types'

const ch = createColumnHelper<Position>()

function f$(v: number | null | undefined) {
  if (v == null) return '--'
  return '$' + Number(v).toFixed(2)
}

const columns = [
  ch.display({
    id: 'select',
    header: '',
    cell: ({ row }) => {
      const { selectedIds, toggleSelected } = useStore.getState()
      return (
        <input
          type="checkbox"
          checked={selectedIds.has(row.original.id)}
          onChange={() => toggleSelected(row.original.id)}
          onClick={(e) => e.stopPropagation()}
        />
      )
    },
    size: 32,
    enableSorting: false,
  }),
  ch.accessor('underlying', { header: 'Sym', cell: (i) => <b>{i.getValue()}</b>, size: 54 }),
  ch.accessor('display_qty', {
    header: 'Qty',
    cell: (i) => <span style={{ color: i.getValue() < 0 ? 'var(--red)' : 'var(--green)' }}>{i.getValue()}</span>,
    size: 40,
  }),
  ch.accessor('option_type', {
    header: 'Type',
    cell: (i) => <span style={{ color: i.getValue() === 'C' ? 'var(--accent)' : 'var(--red)' }}>{i.getValue() === 'C' ? 'CALL' : 'PUT'}</span>,
    size: 50,
  }),
  ch.accessor('expiration', { header: 'Exp', cell: (i) => <span style={{ color: 'var(--muted)' }}>{i.getValue()}</span>, size: 94 }),
  ch.accessor('strike', { header: 'Strike', size: 64 }),
  ch.accessor('mark', { header: 'Mark', cell: (i) => f$(i.getValue()), size: 70 }),
  ch.accessor('trade_price', { header: 'Trade', cell: (i) => f$(i.getValue()), size: 70 }),
  ch.accessor('pnl_open', {
    header: 'P/L',
    cell: (i) => <span style={{ color: i.getValue() >= 0 ? 'var(--green)' : 'var(--red)' }}>{f$(i.getValue())}</span>,
    size: 76,
  }),
  ch.accessor('short_value', { header: 'ShtVal', cell: (i) => f$(i.getValue()), size: 76 }),
  ch.accessor('long_cost',   { header: 'LngCost', cell: (i) => f$(i.getValue()), size: 76 }),
  ch.accessor('limit_impact', {
    header: 'Impact',
    cell: (i) => <span style={{ color: 'var(--warn)' }}>{f$(i.getValue())}</span>,
    size: 76,
  }),
]

export function PositionsTile() {
  const { positions, positionsLoading, positionsError } = useStore()
  const [sorting, setSorting] = useState<SortingState>([])

  // Flatten groups into rows with group header rows injected
  const flatRows = useMemo(() => {
    const groups: Record<string, Position[]> = {}
    positions.forEach((p) => {
      const k = `${p.underlying}||${p.group ?? ''}`
      if (!groups[k]) groups[k] = []
      groups[k].push(p)
    })
    return groups
  }, [positions])

  const table = useReactTable({
    data: positions,
    columns,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  })

  if (positionsLoading) return <div className="tile" style={{ height: '100%' }}><div className="tile-hdr"><span className="tile-title">Open Positions</span></div><div className="loading">Loading...</div></div>

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div className="tile-hdr">
        <span className="tile-title">Open Positions</span>
        <span style={{ fontSize: 10, color: 'var(--muted)', marginLeft: 4 }}>{positions.length} legs</span>
      </div>

      {positionsError && <div className="error-msg">{positionsError}</div>}

      <div className="tile-body tbl-wrap">
        <table className="data-table">
          <thead>
            {table.getHeaderGroups().map((hg) => (
              <tr key={hg.id}>
                {hg.headers.map((h) => (
                  <th
                    key={h.id}
                    style={{ width: h.getSize(), cursor: h.column.getCanSort() ? 'pointer' : 'default' }}
                    className={
                      h.column.getIsSorted() === 'asc' ? 'sort-asc' :
                      h.column.getIsSorted() === 'desc' ? 'sort-desc' : ''
                    }
                    onClick={h.column.getToggleSortingHandler()}
                  >
                    {flexRender(h.column.columnDef.header, h.getContext())}
                  </th>
                ))}
              </tr>
            ))}
          </thead>
          <tbody>
            {positions.length === 0 ? (
              <tr><td colSpan={12} className="empty-msg">No positions loaded</td></tr>
            ) : (
              (() => {
                const seen = new Set<string>()
                const rows: JSX.Element[] = []
                table.getRowModel().rows.forEach((row) => {
                  const p = row.original
                  const gk = `${p.underlying}||${p.group ?? ''}`
                  if (!seen.has(gk)) {
                    seen.add(gk)
                    rows.push(
                      <tr key={`g-${gk}`} className="group-row">
                        <td colSpan={12}>
                          {p.underlying}{p.group ? ` \u2014 ${p.group}` : ''}
                        </td>
                      </tr>
                    )
                  }
                  rows.push(
                    <tr key={row.id}>
                      {row.getVisibleCells().map((cell) => (
                        <td key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</td>
                      ))}
                    </tr>
                  )
                })
                return rows
              })()
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}

'@
Write-File "react-frontend\src\components\tiles\PositionsTile.tsx" $c

$c = @'
import { useState } from 'react'
import {
  createColumnHelper, flexRender, getCoreRowModel,
  getSortedRowModel, useReactTable, type SortingState,
} from '@tanstack/react-table'
import { useStore } from '../../store/useStore'
import type { ScanResult } from '../../types'
import { fetchScan, fetchChain } from '../../api/client'
import { fetchVolSurface } from '../../api/client'

const ch = createColumnHelper<ScanResult>()

// ── 2dp formatters ─────────────────────────────────────────
const f$  = (v: number | null | undefined) => v == null ? '--' : '$' + Number(v).toFixed(2)
const fPct = (v: number | null | undefined) => v == null ? '--' : (Number(v) * 100).toFixed(2) + '%'
const fIV  = (v: number | null | undefined) => v == null ? '--' : (Number(v) * 100).toFixed(2) + '%'
const fN2  = (v: number | null | undefined) => v == null ? '--' : Number(v).toFixed(2)

// ── Column definitions ─────────────────────────────────────
const COLS = [
  ch.accessor('expiration', {
    header: 'Exp', size: 94,
    cell: i => <span style={{ color: 'var(--muted)' }}>{i.getValue()}</span>,
    meta: { tip: 'Expiration date of the spread' },
  }),
  ch.accessor('option_side', {
    header: 'Side', size: 52,
    cell: i => <span className={`side-badge ${i.getValue()}`}>{i.getValue().toUpperCase()}</span>,
    meta: { tip: 'CALL (bear call) or PUT (bull put) credit spread' },
  }),
  ch.accessor('short_strike', {
    header: 'Short', size: 60,
    cell: i => fN2(i.getValue()),
    meta: { tip: 'Strike you SELL — where you collect premium' },
  }),
  ch.accessor('long_strike', {
    header: 'Long', size: 60,
    cell: i => fN2(i.getValue()),
    meta: { tip: 'Strike you BUY — your protection leg' },
  }),
  ch.accessor('width', {
    header: 'Wid', size: 46,
    cell: i => <span style={{ color: 'var(--muted)' }}>{fN2(i.getValue())}</span>,
    meta: { tip: 'Dollar distance between strikes. Any width is shown (no preset list).' },
  }),
  ch.accessor('quantity', {
    header: 'Qty', size: 40,
    cell: i => <span style={{ color: 'var(--muted)' }}>{i.getValue()}</span>,
    meta: { tip: 'Contracts for nearest-integer match to your target risk. Actual risk may differ slightly.' },
  }),
  ch.accessor('net_credit', {
    header: 'Net Cr', size: 72,
    cell: i => <span style={{ color: 'var(--green)' }}>{f$(i.getValue())}</span>,
    meta: { tip: 'Total premium collected for entire position (all contracts)' },
  }),
  ch.accessor('actual_defined_risk', {
    header: 'Act Risk', size: 72,
    cell: i => <span style={{ color: 'var(--muted)' }}>{f$(i.getValue())}</span>,
    meta: { tip: 'Actual defined risk = Width × 100 × Qty. May differ slightly from target when qty rounds.' },
  }),
  ch.accessor('max_loss', {
    header: 'Max Loss', size: 76,
    cell: i => <span style={{ color: 'var(--red)' }}>{f$(i.getValue())}</span>,
    meta: { tip: 'Worst-case loss = Actual Risk minus Net Credit' },
  }),
  ch.accessor('credit_pct_risk', {
    header: 'Cr%Risk', size: 66,
    cell: i => <span>{fPct(i.getValue())}</span>,
    meta: { tip: 'Net Credit / Actual Risk — primary reward/risk metric. 30% = collected 30¢ per $1 at risk.' },
  }),
  ch.accessor('short_delta', {
    header: 'Sht Δ', size: 60,
    cell: i => <span style={{ color: 'var(--muted)' }}>{fN2(i.getValue())}</span>,
    meta: { tip: 'Delta of the short leg ≈ approximate probability ITM at expiry' },
  }),
  ch.accessor('short_iv', {
    header: 'Sht IV', size: 62,
    cell: i => <span style={{ color: 'var(--muted)' }}>{fIV(i.getValue())}</span>,
    meta: { tip: 'Implied volatility of the short strike — what you are selling. Now correctly scaled.' },
  }),
  ch.accessor('richness_score', {
    header: 'Score', size: 58,
    cell: i => {
      const v = Number(i.getValue() ?? 0)
      const color = v >= 0.7 ? 'var(--green)' : v >= 0.4 ? 'var(--text)' : 'var(--muted)'
      return <span style={{ color, fontWeight: v >= 0.7 ? 600 : 400 }}>{fN2(v)}</span>
    },
    meta: { tip: 'Composite rank: 70% credit% rank + 30% IV rank vs peers in same expiration. 1.0 = richest.' },
  }),
  ch.accessor('limit_impact', {
    header: 'Impact', size: 72,
    cell: i => <span style={{ color: 'var(--warn)' }}>{f$(i.getValue())}</span>,
    meta: { tip: 'max(Short Value, Long Cost) — tastytrade limit usage for this trade' },
  }),
]

export function ScannerTile() {
  const {
    scanResults, scanLoading, scanError, scanExpOptions,
    setScanResults, setScanLoading, setScanError, setScanExpOptions,
    activeSymbol, setActiveSymbol, setVolData, setVolLoading, setVolError,
  } = useStore()

  const [sorting, setSorting] = useState<SortingState>([])
  const [sym, setSym]         = useState(activeSymbol)
  const [risk, setRisk]       = useState(1000)
  const [side, setSide]       = useState<'all' | 'call' | 'put'>('all')
  const [exp, setExp]         = useState('all')
  const [sortBy, setSortBy]   = useState('credit_pct_risk')
  const [maxRes, setMaxRes]   = useState(500)
  const [pricing, setPricing] = useState<'conservative_mid' | 'mid' | 'natural'>('conservative_mid')
  const [tooltip, setTooltip] = useState<string | null>(null)

  const table = useReactTable({
    data: scanResults,
    columns: COLS,
    state: { sorting },
    onSortingChange: setSorting,
    getCoreRowModel: getCoreRowModel(),
    getSortedRowModel: getSortedRowModel(),
  })

  async function run() {
    setScanLoading(true); setScanError(null)
    setActiveSymbol(sym)
    try {
      const d = await fetchScan({
        symbol: sym, total_risk: risk, side, expiration: exp,
        sort_by: sortBy, max_results: maxRes,
      })
      setScanResults(d.items)
    } catch (e: any) {
      setScanError(e.message)
    } finally {
      setScanLoading(false)
    }
  }

  async function refreshChain() {
    try {
      const d = await fetchChain(sym)
      setScanExpOptions(d.expirations.slice(0, 7))
    } catch (e: any) { setScanError(e.message) }
  }

  async function loadSurface() {
    setVolLoading(true); setVolError(null)
    try {
      const d = await fetchVolSurface(sym, 7, 25)
      setVolData(d)
    } catch (e: any) { setVolError(e.message) }
    finally { setVolLoading(false) }
  }

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column', position: 'relative' }}>
      <div className="tile-hdr">
        <span className="tile-title">Entry Scanner</span>
        {tooltip && (
          <div style={{ position: 'absolute', top: 30, left: 8, background: 'var(--bg3)', border: '1px solid var(--bord2)', borderRadius: 4, padding: '5px 10px', fontSize: 11, color: 'var(--text)', zIndex: 200, maxWidth: 380, lineHeight: 1.5, pointerEvents: 'none', whiteSpace: 'normal' }}>
            {tooltip}
          </div>
        )}
      </div>

      <div className="scan-controls">
        <div className="ctrl-group">
          <label>Symbol</label>
          <input type="text" value={sym} onChange={e => setSym(e.target.value.toUpperCase())} onKeyDown={e => e.key === 'Enter' && run()} />
        </div>
        <div className="ctrl-group">
          <label>Target Risk $</label>
          <input type="number" value={risk} onChange={e => setRisk(Number(e.target.value))} step={100} />
        </div>
        <div className="ctrl-group">
          <label>Side</label>
          <select value={side} onChange={e => setSide(e.target.value as any)}>
            <option value="all">All</option>
            <option value="call">Calls</option>
            <option value="put">Puts</option>
          </select>
        </div>
        <div className="ctrl-group">
          <label>Expiration</label>
          <select value={exp} onChange={e => setExp(e.target.value)}>
            <option value="all">All (next 7)</option>
            {scanExpOptions.map(e => <option key={e} value={e}>{e}</option>)}
          </select>
        </div>
        <div className="ctrl-group">
          <label>Sort By</label>
          <select value={sortBy} onChange={e => setSortBy(e.target.value)}>
            <option value="credit_pct_risk">Credit % Risk</option>
            <option value="richness">Richness Score</option>
            <option value="credit">Net Credit</option>
            <option value="limit_impact">Limit Impact</option>
            <option value="max_loss">Max Loss</option>
          </select>
        </div>
        <div className="ctrl-group">
          <label>Pricing</label>
          <select value={pricing} onChange={e => setPricing(e.target.value as any)}>
            <option value="conservative_mid">Conservative Mid</option>
            <option value="mid">Mid (faster fills)</option>
            <option value="natural">Natural (bid/ask)</option>
          </select>
        </div>
      </div>

      <div className="scan-actions">
        <button className="btn primary" onClick={run} disabled={scanLoading}>
          {scanLoading ? 'Scanning...' : '\u25B6 SCAN'}
        </button>
        <button className="btn" onClick={() => { setScanResults([]); setScanError(null) }}>&#x2715;</button>
        <button className="btn sm" onClick={refreshChain} title="Force-refresh chain data">&#x21BA; CHAIN</button>
        <button className="btn sm" onClick={loadSurface} title="Load vol surface">&#x2B21; SURFACE</button>
        <span style={{ fontSize: 10, color: 'var(--muted)', marginLeft: 4, alignSelf: 'center' }}>
          {scanResults.length > 0 ? `${scanResults.length} results` : ''}
        </span>
        <span style={{ fontSize: 9, color: 'var(--muted)', marginLeft: 'auto', alignSelf: 'center', fontStyle: 'italic' }}>
          {pricing === 'conservative_mid' ? 'conservative' : pricing} pricing
        </span>
      </div>

      {scanError && <div className="error-msg">{scanError}</div>}

      <div className="tile-body tbl-wrap">
        <table className="data-table">
          <thead>
            {table.getHeaderGroups().map(hg => (
              <tr key={hg.id}>
                {hg.headers.map(h => {
                  const tip = (h.column.columnDef.meta as any)?.tip as string | undefined
                  return (
                    <th
                      key={h.id}
                      style={{ width: h.getSize(), cursor: h.column.getCanSort() ? 'pointer' : 'default' }}
                      className={
                        h.column.getIsSorted() === 'asc' ? 'sort-asc' :
                        h.column.getIsSorted() === 'desc' ? 'sort-desc' : ''
                      }
                      onClick={h.column.getToggleSortingHandler()}
                      onMouseEnter={() => tip && setTooltip(tip)}
                      onMouseLeave={() => setTooltip(null)}
                    >
                      {flexRender(h.column.columnDef.header, h.getContext())}
                    </th>
                  )
                })}
              </tr>
            ))}
          </thead>
          <tbody>
            {scanLoading ? (
              <tr><td colSpan={14} className="loading">Scanning all strike pairs...</td></tr>
            ) : scanResults.length === 0 ? (
              <tr><td colSpan={14} className="empty-msg">Configure filters and press SCAN</td></tr>
            ) : (
              table.getRowModel().rows.map(row => (
                <tr
                  key={row.id}
                  style={{ borderLeft: `2px solid ${row.original.option_side === 'call' ? 'var(--green)' : 'var(--red)'}` }}
                >
                  {row.getVisibleCells().map(cell => (
                    <td key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</td>
                  ))}
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
    </div>
  )
}

'@
Write-File "react-frontend\src\components\tiles\ScannerTile.tsx" $c

$c = @'
import { useEffect, useRef, useState } from 'react'
import Plotly from 'plotly.js-dist-min'
import { useStore } from '../../store/useStore'
import type { VSView } from '../../types'
import { fetchVolSurface } from '../../api/client'

const COLORSCALE: Plotly.ColorScale = [
  [0.00, '#080e24'],
  [0.15, '#0c3c7a'],
  [0.30, '#156a48'],
  [0.48, '#228a38'],
  [0.60, '#c87800'],
  [0.78, '#c83838'],
  [1.00, '#ff2020'],
]

function richColor(score: number | null) {
  if (score == null) return 'var(--muted)'
  if (score >= 0.03) return 'var(--green)'
  if (score >= 0) return 'var(--warn)'
  return 'var(--red)'
}

export function VolSurfaceTile() {
  const { volData, volLoading, volError, activeSymbol, setVolData, setVolLoading, setVolError } = useStore()
  const plotRef = useRef<HTMLDivElement>(null)
  const [view, setView] = useState<VSView>('3d')
  const [plotted, setPlotted] = useState(false)

  async function load(sym?: string) {
    const s = sym ?? activeSymbol
    setVolLoading(true)
    setVolError(null)
    try {
      const d = await fetchVolSurface(s, 7, 25)
      setVolData(d)
    } catch (e: any) {
      setVolError(e.message)
    } finally {
      setVolLoading(false)
    }
  }

  // Render Plotly chart whenever data or view changes
  useEffect(() => {
    if (!plotRef.current || !volData || !volData.expirations.length) return
    renderPlot()
  }, [volData, view])

  // Also re-render on container resize
  useEffect(() => {
    const obs = new ResizeObserver(() => {
      if (plotRef.current && plotted) {
        Plotly.Plots.resize(plotRef.current)
      }
    })
    if (plotRef.current) obs.observe(plotRef.current)
    return () => obs.disconnect()
  }, [plotted])

  function renderPlot() {
    if (!plotRef.current || !volData) return
    const { expirations, strikes } = volData

    // FIX: Sort strikes ascending so lowest is left-front in 3D
    const sortedStrikes = [...strikes].sort((a, b) => a - b)
    const strikeIndexMap = new Map(strikes.map((s, i) => [s, i]))

    function getMatrix(mat: (number | null)[][]) {
      // Reorder columns to match sortedStrikes
      return mat.map((row) =>
        sortedStrikes.map((s) => {
          const idx = strikeIndexMap.get(s)
          const v = idx != null ? row[idx] : null
          return v != null ? v * 100 : null
        })
      )
    }

    let raw: (number | null)[][]
    if (view === 'call') raw = volData.call_iv_matrix ?? volData.avg_iv_matrix
    else if (view === 'put') raw = volData.put_iv_matrix ?? volData.avg_iv_matrix
    else if (view === 'skew') raw = volData.skew_matrix ?? volData.avg_iv_matrix
    else raw = volData.avg_iv_matrix ?? volData.iv_matrix

    const z = getMatrix(raw)
    const flat = z.flat().filter((v): v is number => v != null)
    if (!flat.length) return

    const el = plotRef.current
    const W = el.clientWidth
    const H = el.clientHeight

    const paperBg = 'rgba(0,0,0,0)'
    const plotBg  = 'rgba(10,18,30,0.9)'
    const font    = { family: 'IBM Plex Mono, monospace', color: '#6e8aa0', size: 10 }
    const gridColor = '#1c2b3a'

    if (view === '3d') {
      const trace: Plotly.Data = {
        type: 'surface',
        x: sortedStrikes,
        y: expirations,
        z,
        colorscale: COLORSCALE,
        showscale: true,
        opacity: 0.94,
        contours: {
          z: { show: true, usecolormap: true, highlightcolor: '#4d9fff', project: { z: true } },
        } as any,
        colorbar: {
          thickness: 12,
          len: 0.85,
          xpad: 4,
          tickfont: { color: '#6e8aa0', size: 9 },
          title: { text: 'IV %', font: { size: 9, color: '#6e8aa0' } },
          // Overlay inside the plot
          x: 1.0,
        } as any,
        hovertemplate: 'Strike: %{x}<br>Exp: %{y}<br>IV: %{z:.2f}%<extra></extra>',
      }

      const layout: Partial<Plotly.Layout> = {
        paper_bgcolor: paperBg,
        font,
        margin: { l: 0, r: 60, t: 10, b: 0 },
        width: W,
        height: H,
        scene: {
          xaxis: {
            title: { text: 'Strike', font: { size: 10 } },
            gridcolor: gridColor,
            zerolinecolor: gridColor,
            tickfont: { size: 9 },
            // Lowest strike on left front: autorange handles this with sorted array
            autorange: true,
          },
          yaxis: {
            title: { text: '', font: { size: 10 } },
            gridcolor: gridColor,
            tickfont: { size: 9 },
            autorange: true,
          },
          zaxis: {
            title: { text: 'IV %', font: { size: 10 } },
            gridcolor: gridColor,
            tickfont: { size: 9 },
          },
          bgcolor: 'rgba(7,9,14,0.85)',
          camera: {
            eye: { x: -1.5, y: -1.8, z: 1.0 },
          },
        } as any,
      }
      Plotly.react(el, [trace], layout, { responsive: false, displayModeBar: false })
    } else {
      const title = view === 'skew' ? 'Put - Call Skew (%)' : 'IV (%)'
      const trace: Plotly.Data = {
        type: 'heatmap',
        x: sortedStrikes,
        y: expirations,
        z,
        colorscale: COLORSCALE,
        showscale: true,
        zsmooth: 'best',
        colorbar: {
          thickness: 12,
          len: 0.92,
          xpad: 4,
          tickfont: { color: '#6e8aa0', size: 9 },
          title: { text: title, font: { size: 9, color: '#6e8aa0' } },
          x: 1.0,
        } as any,
        hovertemplate: 'Strike: %{x}<br>Exp: %{y}<br>Value: %{z:.2f}%<extra></extra>',
      }
      const layout: Partial<Plotly.Layout> = {
        paper_bgcolor: paperBg,
        plot_bgcolor: plotBg,
        font,
        margin: { l: 90, r: 55, t: 10, b: 60 },
        width: W,
        height: H,
        xaxis: { title: { text: 'Strike' }, gridcolor: gridColor, tickfont: { size: 9 }, color: '#6e8aa0' },
        yaxis: { gridcolor: gridColor, tickfont: { size: 9 }, color: '#6e8aa0', autorange: 'reversed' },
      }
      Plotly.react(el, [trace], layout, { responsive: false, displayModeBar: false })
    }
    setPlotted(true)
  }

  const richness = volData?.richness_scores ?? {}
  const sortedExps = volData ? [...volData.expirations].sort((a, b) => (richness[b]?.richness_score ?? 0) - (richness[a]?.richness_score ?? 0)) : []

  return (
    <div className="tile" style={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
      <div className="tile-hdr">
        <span className="tile-title">Vol Surface</span>
        <div className="vs-tabs" style={{ padding: 0, border: 'none', background: 'transparent', marginLeft: 8, gap: 3, display: 'flex' }}>
          {(['avg','call','put','skew','3d'] as VSView[]).map((v) => (
            <button key={v} className={`btn sm${view === v ? ' active' : ''}`} onClick={() => setView(v)}>
              {v === '3d' ? '3D' : v.charAt(0).toUpperCase() + v.slice(1)}
            </button>
          ))}
        </div>
        <button className="btn sm" style={{ marginLeft: 'auto' }} onClick={() => load()}>&#x21BA; LOAD</button>
      </div>

      {/* Richness expiration cards */}
      <div className="richness-row">
        {volLoading && <span className="muted" style={{ fontSize: 10, alignSelf: 'center' }}>Loading surface...</span>}
        {volError && <span className="error-msg" style={{ fontSize: 10 }}>{volError}</span>}
        {!volLoading && !volError && sortedExps.length === 0 && (
          <span style={{ fontSize: 10, color: 'var(--muted)', alignSelf: 'center' }}>Click LOAD to populate vol surface</span>
        )}
        {sortedExps.map((e) => {
          const r = richness[e] ?? {}
          const iv = r.avg_iv != null ? (r.avg_iv * 100).toFixed(1) + '%' : '--'
          const sc = r.richness_score != null ? Number(r.richness_score).toFixed(4) : '--'
          const skew = r.put_call_skew_near_spot
          return (
            <div key={e} className="rcard">
              <div className="rc-date">{e}</div>
              <div className="rc-iv">{iv}</div>
              <div className="rc-score" style={{ color: richColor(r.richness_score ?? null) }}>Score {sc}</div>
              {skew != null && (
                <div className="rc-skew">Skew {skew >= 0 ? '+' : ''}{(skew * 100).toFixed(2)}%</div>
              )}
            </div>
          )
        })}
      </div>

      {/* Plotly container — fills all remaining space */}
      <div ref={plotRef} style={{ flex: 1, minHeight: 0, width: '100%' }} />
    </div>
  )
}

'@
Write-File "react-frontend\src\components\tiles\VolSurfaceTile.tsx" $c

$c = @'
import {
  useEffect, useRef, useCallback, useState, useMemo,
} from 'react'
import {
  createChart, CandlestickSeries, LineSeries, HistogramSeries,
  CrosshairMode, LineStyle, PriceScaleMode,
  type IChartApi, type ISeriesApi, type Time,
  type CandlestickData, type LineData,
} from 'lightweight-charts'
import { useStore } from '../../store/useStore'
import { fetchPriceHistory, type Candle } from '../../api/client'

// ── Indicator math (client-side) ─────────────────────────────

function sma(data: number[], period: number): (number | null)[] {
  const out: (number | null)[] = []
  for (let i = 0; i < data.length; i++) {
    if (i < period - 1) { out.push(null); continue }
    const slice = data.slice(i - period + 1, i + 1)
    out.push(slice.reduce((a, b) => a + b, 0) / period)
  }
  return out
}

function rsi(closes: number[], period: number): (number | null)[] {
  const out: (number | null)[] = Array(closes.length).fill(null)
  if (closes.length < period + 1) return out
  let gains = 0, losses = 0
  for (let i = 1; i <= period; i++) {
    const d = closes[i] - closes[i - 1]
    if (d > 0) gains += d; else losses -= d
  }
  let avgG = gains / period, avgL = losses / period
  out[period] = avgL === 0 ? 100 : 100 - 100 / (1 + avgG / avgL)
  for (let i = period + 1; i < closes.length; i++) {
    const d = closes[i] - closes[i - 1]
    const g = d > 0 ? d : 0, l = d < 0 ? -d : 0
    avgG = (avgG * (period - 1) + g) / period
    avgL = (avgL * (period - 1) + l) / period
    out[i] = avgL === 0 ? 100 : 100 - 100 / (1 + avgG / avgL)
  }
  return out
}

function atr(candles: Candle[], period: number): (number | null)[] {
  const out: (number | null)[] = [null]
  for (let i = 1; i < candles.length; i++) {
    const h = candles[i].high, l = candles[i].low, pc = candles[i - 1].close
    const tr = Math.max(h - l, Math.abs(h - pc), Math.abs(l - pc))
    if (i < period) { out.push(null); continue }
    if (i === period) {
      const slice = candles.slice(1, period + 1)
      const trSum = slice.reduce((a, c, j) => {
        const hp = c.high, lp = c.low, pcp = j > 0 ? slice[j - 1].close : candles[0].close
        return a + Math.max(hp - lp, Math.abs(hp - pcp), Math.abs(lp - pcp))
      }, 0)
      out.push(trSum / period); continue
    }
    const prev = out[i - 1] as number
    out.push((prev * (period - 1) + tr) / period)
  }
  return out
}

function vortex(candles: Candle[], period: number): { vip: (number|null)[]; vim: (number|null)[] } {
  const n = candles.length
  const vip: (number | null)[] = Array(n).fill(null)
  const vim: (number | null)[] = Array(n).fill(null)
  for (let i = period; i < n; i++) {
    let vpSum = 0, vmSum = 0, trSum = 0
    for (let j = i - period + 1; j <= i; j++) {
      const h = candles[j].high, l = candles[j].low
      const ph = candles[j - 1].high, pl = candles[j - 1].low, pc = candles[j - 1].close
      vpSum += Math.abs(h - pl)
      vmSum += Math.abs(l - ph)
      trSum += Math.max(h - l, Math.abs(h - pc), Math.abs(l - pc))
    }
    vip[i] = trSum > 0 ? vpSum / trSum : null
    vim[i] = trSum > 0 ? vmSum / trSum : null
  }
  return { vip, vim }
}

function ema(data: number[], period: number): (number | null)[] {
  const k = 2 / (period + 1)
  const out: (number | null)[] = Array(data.length).fill(null)
  let start = -1
  for (let i = 0; i < data.length; i++) {
    if (data[i] == null) continue
    if (start === -1) { out[i] = data[i]; start = i; continue }
    out[i] = data[i] * k + (out[i - 1] as number) * (1 - k)
  }
  return out
}

function ppo(closes: number[], fast: number, slow: number, signal: number): { ppo: (number|null)[]; sig: (number|null)[]; hist: (number|null)[] } {
  const fastEma  = ema(closes, fast)
  const slowEma  = ema(closes, slow)
  const ppoLine  = closes.map((_, i) => {
    if (fastEma[i] == null || slowEma[i] == null || (slowEma[i] as number) === 0) return null
    return ((fastEma[i] as number) - (slowEma[i] as number)) / (slowEma[i] as number) * 100
  })
  const sigLine = ema(ppoLine.map(v => v ?? 0), signal)
  const hist    = ppoLine.map((v, i) => v == null || sigLine[i] == null ? null : (v - (sigLine[i] as number)))
  return { ppo: ppoLine, sig: sigLine, hist }
}

// ── Friday of week for expected move lines ─────────────────

function isFriday(unixSec: number): boolean {
  return new Date(unixSec * 1000).getDay() === 5
}

function nextFriday(unixSec: number): number {
  const d = new Date(unixSec * 1000)
  const day = d.getDay()
  const daysUntilFri = (5 - day + 7) % 7 || 7
  return unixSec + daysUntilFri * 86400
}

// ── SMA periods ───────────────────────────────────────────────
const SMA_PERIODS = [8, 16, 32, 50, 64, 128, 200] as const
type SmaPeriod = typeof SMA_PERIODS[number]

const SMA_COLORS: Record<SmaPeriod, string> = {
  8:   '#4d9fff',
  16:  '#3bba6c',
  32:  '#e5b84c',
  50:  '#f8923a',
  64:  '#a855f7',
  128: '#ec4899',
  200: '#f04f48',
}

// ── Timeframe options ─────────────────────────────────────────
const TF_OPTIONS = [
  { label: '1D',   period: '1d',  frequency: '5min'  },
  { label: '5D',   period: '5d',  frequency: '15min' },
  { label: '1M',   period: '1m',  frequency: 'daily' },
  { label: '3M',   period: '3m',  frequency: 'daily' },
  { label: '6M',   period: '6m',  frequency: 'daily' },
  { label: '1Y',   period: '1y',  frequency: 'daily' },
  { label: '2Y',   period: '2y',  frequency: 'daily' },
  { label: '5Y',   period: '5y',  frequency: 'daily' },
  { label: 'YTD',  period: 'ytd', frequency: 'daily' },
]

// ── Component ─────────────────────────────────────────────────

export function ChartTile() {
  const { activeSymbol, quote, positions, volData } = useStore()

  const chartContainerRef = useRef<HTMLDivElement>(null)
  const chart             = useRef<IChartApi | null>(null)
  const candleSeries      = useRef<ISeriesApi<'Candlestick'> | null>(null)
  const smaSeriesMap      = useRef<Map<SmaPeriod, ISeriesApi<'Line'>>>(new Map())
  const spySeriesRef      = useRef<ISeriesApi<'Line'> | null>(null)
  const gldSeriesRef      = useRef<ISeriesApi<'Line'> | null>(null)

  // Sub-panel series refs
  const rsiChartRef       = useRef<IChartApi | null>(null)
  const atrChartRef       = useRef<IChartApi | null>(null)
  const vortexChartRef    = useRef<IChartApi | null>(null)
  const ppoChartRef       = useRef<IChartApi | null>(null)

  const [candles, setCandles]         = useState<Candle[]>([])
  const [loading, setLoading]         = useState(false)
  const [error, setError]             = useState<string | null>(null)
  const [sym, setSym]                 = useState(activeSymbol)
  const [tf, setTf]                   = useState('5y')
  const [freq, setFreq]               = useState('daily')
  const [ctxMenu, setCtxMenu]         = useState<{ x: number; y: number; time: number; price: number } | null>(null)

  // Toggles
  const [activeSmas, setActiveSmas]   = useState<Set<SmaPeriod>>(new Set([50, 200]))
  const [showSpy, setShowSpy]         = useState(false)
  const [showGld, setShowGld]         = useState(false)
  const [showRsi, setShowRsi]         = useState(false)
  const [showAtr, setShowAtr]         = useState(false)
  const [showVortex, setShowVortex]   = useState(false)
  const [showPpo, setShowPpo]         = useState(false)

  // ── Init main chart ──────────────────────────────────────

  useEffect(() => {
    if (!chartContainerRef.current) return

    const c = createChart(chartContainerRef.current, {
      layout: {
        background: { color: 'rgba(10,12,18,0)' },
        textColor: '#6e8aa0',
        fontFamily: 'IBM Plex Mono, monospace',
        fontSize: 11,
      },
      grid: {
        vertLines: { visible: false },
        horzLines: { visible: false },
      },
      crosshair: {
        mode: CrosshairMode.Normal,
        vertLine: { labelVisible: true,  color: '#4d9fff60', width: 1, style: LineStyle.Dashed },
        horzLine: { labelVisible: true,  color: '#4d9fff60', width: 1, style: LineStyle.Dashed },
      },
      rightPriceScale: {
        borderColor: '#1c2b3a',
        textColor:   '#6e8aa0',
        scaleMargins: { top: 0.08, bottom: 0.15 },
      },
      leftPriceScale: {
        visible:     false,
        borderColor: '#1c2b3a',
        textColor:   '#6e8aa0',
      },
      timeScale: {
        borderColor:   '#1c2b3a',
        textColor:     '#6e8aa0',
        timeVisible:   true,
        secondsVisible: false,
        rightOffset:   8,
        barSpacing:    6,
        fixLeftEdge:   false,
        fixRightEdge:  false,
      },
      handleScroll:  true,
      handleScale:   true,
    })

    // Candlestick series
    const cs = c.addSeries(CandlestickSeries, {
      upColor:          '#3bba6c',
      downColor:        '#f04f48',
      borderUpColor:    '#3bba6c',
      borderDownColor:  '#f04f48',
      wickUpColor:      '#3bba6c88',
      wickDownColor:    '#f04f4888',
    })
    chart.current       = c
    candleSeries.current = cs

    // Mouse wheel zoom centered at pointer
    chartContainerRef.current.addEventListener('wheel', (e) => {
      e.preventDefault()
    }, { passive: false })

    // Right-click context menu
    chartContainerRef.current.addEventListener('contextmenu', (e) => {
      e.preventDefault()
      if (!chart.current) return
      const rect    = chartContainerRef.current!.getBoundingClientRect()
      const relX    = e.clientX - rect.left
      const relY    = e.clientY - rect.top
      const time    = chart.current.timeScale().coordinateToTime(relX)
      const price   = candleSeries.current?.coordinateToPrice(relY) ?? 0
      setCtxMenu({ x: e.clientX, y: e.clientY, time: typeof time === 'number' ? time : 0, price: price ?? 0 })
    })

    // ResizeObserver
    const obs = new ResizeObserver(() => {
      if (chartContainerRef.current && chart.current) {
        chart.current.applyOptions({
          width:  chartContainerRef.current.clientWidth,
          height: chartContainerRef.current.clientHeight,
        })
      }
    })
    if (chartContainerRef.current) obs.observe(chartContainerRef.current)

    return () => {
      obs.disconnect()
      c.remove()
      chart.current       = null
      candleSeries.current = null
    }
  }, [])

  // ── Load price data ──────────────────────────────────────

  const loadChart = useCallback(async (s: string, period: string, frequency: string) => {
    if (!candleSeries.current || !chart.current) return
    setLoading(true); setError(null)
    try {
      const data = await fetchPriceHistory(s, period, frequency)
      setCandles(data.candles)

      // Set candlestick data — Lightweight Charts requires time as YYYY-MM-DD string for daily
      const cdData: CandlestickData<Time>[] = data.candles.map(c => ({
        time:  frequency === 'daily' || frequency === 'weekly' || frequency === 'monthly'
          ? new Date(c.time * 1000).toISOString().slice(0, 10) as Time
          : c.time as unknown as Time,
        open:  c.open,
        high:  c.high,
        low:   c.low,
        close: c.close,
      }))
      candleSeries.current!.setData(cdData)
      chart.current!.timeScale().fitContent()
      setSym(s)
    } catch (e: any) {
      setError(e.message)
    } finally {
      setLoading(false)
    }
  }, [])

  // Sync to active symbol from store
  useEffect(() => {
    if (activeSymbol !== sym) {
      setSym(activeSymbol)
      loadChart(activeSymbol, tf, freq)
    }
  }, [activeSymbol])

  // ── SMAs ─────────────────────────────────────────────────

  useEffect(() => {
    if (!chart.current || !candles.length) return
    const closes = candles.map(c => c.close)
    const times  = candles.map(c =>
      freq === 'daily' || freq === 'weekly' || freq === 'monthly'
        ? new Date(c.time * 1000).toISOString().slice(0, 10) as Time
        : c.time as unknown as Time
    )

    SMA_PERIODS.forEach(period => {
      const existing = smaSeriesMap.current.get(period)
      if (activeSmas.has(period)) {
        const vals = sma(closes, period)
        const lineData: LineData<Time>[] = vals
          .map((v, i) => ({ time: times[i], value: v }))
          .filter(d => d.value != null) as LineData<Time>[]
        if (existing) {
          existing.setData(lineData)
          existing.applyOptions({ visible: true })
        } else {
          const s = chart.current!.addSeries(LineSeries, {
            color:         SMA_COLORS[period],
            lineWidth:     period >= 128 ? 2 : 1,
            priceLineVisible: false,
            lastValueVisible: false,
            crosshairMarkerVisible: false,
          })
          s.setData(lineData)
          smaSeriesMap.current.set(period, s)
        }
      } else if (existing) {
        existing.applyOptions({ visible: false })
      }
    })
  }, [activeSmas, candles, freq])

  // ── Mark open positions on chart ──────────────────────────
  useEffect(() => {
    if (!candleSeries.current || !positions.length || !candles.length) return
    const symPositions = positions.filter(p => p.underlying === sym)
    if (!symPositions.length) return

    const markers = symPositions.map(p => ({
      time: new Date().toISOString().slice(0, 10) as Time,
      position: (p.display_qty < 0 ? 'aboveBar' : 'belowBar') as any,
      color:  p.display_qty < 0 ? '#f04f48' : '#3bba6c',
      shape:  (p.display_qty < 0 ? 'arrowDown' : 'arrowUp') as any,
      text:   `${p.option_type}${p.strike} ${p.display_qty > 0 ? '+' : ''}${p.display_qty}`,
    }))
    candleSeries.current.setMarkers(markers)
  }, [positions, candles, sym])

  // ── Expected move horizontal lines every Friday ───────────
  useEffect(() => {
    if (!candleSeries.current || !candles.length || !quote.atmStraddle || !quote.lastPrice) return
    const move   = quote.atmStraddle * 0.85
    const price  = quote.lastPrice
    const upper  = price + move
    const lower  = price - move

    // Remove old expected move lines
    try {
      ;(candleSeries.current as any).__em_upper?.remove()
      ;(candleSeries.current as any).__em_lower?.remove()
    } catch {}

    const uLine = candleSeries.current.createPriceLine({
      price:          upper,
      color:          '#3bba6c88',
      lineWidth:      1,
      lineStyle:      LineStyle.Dashed,
      axisLabelVisible: true,
      title:          `EM+ ${upper.toFixed(2)}`,
    })
    const lLine = candleSeries.current.createPriceLine({
      price:          lower,
      color:          '#f04f4888',
      lineWidth:      1,
      lineStyle:      LineStyle.Dashed,
      axisLabelVisible: true,
      title:          `EM− ${lower.toFixed(2)}`,
    })
    ;(candleSeries.current as any).__em_upper = uLine
    ;(candleSeries.current as any).__em_lower = lLine
  }, [quote.atmStraddle, quote.lastPrice, candles])

  // ── Toggle SMA ────────────────────────────────────────────
  function toggleSma(p: SmaPeriod) {
    setActiveSmas(prev => {
      const next = new Set(prev)
      if (next.has(p)) next.delete(p); else next.add(p)
      return next
    })
  }

  // ── Context menu actions ──────────────────────────────────
  function openGoogleNews() {
    if (!ctxMenu) return
    const date = new Date(ctxMenu.time * 1000).toISOString().slice(0, 10)
    const url  = `https://www.google.com/search?q=${encodeURIComponent(sym)}+stock+news&tbs=cdr:1,cd_min:${date},cd_max:${date}&tbm=nws`
    window.open(url, '_blank')
    setCtxMenu(null)
  }

  function addAlertAtPrice() {
    if (!ctxMenu) return
    // Trigger alert modal via store (fire custom event)
    const ev = new CustomEvent('granite:addAlertAtPrice', {
      detail: { sym, price: ctxMenu.price.toFixed(2) }
    })
    window.dispatchEvent(ev)
    setCtxMenu(null)
  }

  function handleTfClick(period: string, frequency: string) {
    setTf(period); setFreq(frequency)
    loadChart(sym, period, frequency)
  }

  // ── Current price line ────────────────────────────────────
  useEffect(() => {
    if (!candleSeries.current || !quote.lastPrice) return
    candleSeries.current.applyOptions({
      lastValueVisible: true,
    })
  }, [quote.lastPrice])

  // ── Indicator heights (approximate) ──────────────────────
  const showAnyIndicator = showRsi || showAtr || showVortex || showPpo
  const mainHeight       = showAnyIndicator ? '60%' : '100%'
  const numIndicators    = [showRsi, showAtr, showVortex, showPpo].filter(Boolean).length
  const indHeight        = numIndicators > 0 ? `${40 / numIndicators}%` : '0%'

  // ── Price strip above chart ───────────────────────────────
  const chgColor = (quote.netChange ?? 0) >= 0 ? '#3bba6c' : '#f04f48'
  const move     = quote.atmStraddle ? (quote.atmStraddle * 0.85).toFixed(2) : null

  return (
    <div
      className="tile"
      style={{ height: '100%', display: 'flex', flexDirection: 'column' }}
      onClick={() => ctxMenu && setCtxMenu(null)}
    >
      {/* Header */}
      <div className="tile-hdr" style={{ height: 'auto', flexDirection: 'column', alignItems: 'stretch', padding: '6px 10px', gap: 6 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span className="tile-title">Chart</span>
          {/* Symbol input */}
          <input
            type="text"
            value={sym}
            onChange={e => setSym(e.target.value.toUpperCase())}
            onKeyDown={e => e.key === 'Enter' && loadChart(sym, tf, freq)}
            style={{ width: 70, fontSize: 12, fontWeight: 700, padding: '2px 6px' }}
          />
          <button
            className="btn sm primary"
            onClick={() => loadChart(sym, tf, freq)}
          >LOAD</button>

          {/* Timeframe buttons */}
          <div style={{ display: 'flex', gap: 2, marginLeft: 4 }}>
            {TF_OPTIONS.map(t => (
              <button
                key={t.label}
                className={`btn sm${tf === t.period ? ' active' : ''}`}
                onClick={() => handleTfClick(t.period, t.frequency)}
              >
                {t.label}
              </button>
            ))}
          </div>

          {/* Comparison overlays */}
          <div style={{ display: 'flex', gap: 2, marginLeft: 6, borderLeft: '1px solid var(--border)', paddingLeft: 6 }}>
            <button
              className={`btn sm${showSpy ? ' active' : ''}`}
              style={{ color: showSpy ? 'var(--bg)' : '#4d9fff' }}
              onClick={() => setShowSpy(v => !v)}
            >SPY</button>
            <button
              className={`btn sm${showGld ? ' active' : ''}`}
              style={{ color: showGld ? 'var(--bg)' : '#e5b84c' }}
              onClick={() => setShowGld(v => !v)}
            >GLD</button>
          </div>

          {/* Price display — focal point */}
          <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'baseline', gap: 10 }}>
            <span style={{ fontSize: 26, fontWeight: 700, color: 'var(--text)', letterSpacing: '-0.02em', lineHeight: 1 }}>
              {quote.lastPrice != null ? '$' + quote.lastPrice.toFixed(2) : '--'}
            </span>
            <span style={{ fontSize: 14, color: chgColor }}>
              {quote.netChange != null
                ? `${quote.netChange >= 0 ? '+' : ''}${quote.netChange.toFixed(2)} (${((quote.netPctChange ?? 0) * 100).toFixed(2)}%)`
                : '--'}
            </span>
            {quote.openPrice && <span style={{ fontSize: 11, color: 'var(--muted)' }}>O {quote.openPrice.toFixed(2)}</span>}
            {quote.highPrice && <span style={{ fontSize: 11, color: '#3bba6c' }}>H {quote.highPrice.toFixed(2)}</span>}
            {quote.lowPrice  && <span style={{ fontSize: 11, color: '#f04f48' }}>L {quote.lowPrice.toFixed(2)}</span>}
            {move && <span style={{ fontSize: 11, color: 'var(--muted)' }}>EM ±${move}</span>}
          </div>
        </div>

        {/* SMA toggles */}
        <div style={{ display: 'flex', gap: 3, alignItems: 'center', flexWrap: 'wrap' }}>
          <span style={{ fontSize: 9, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginRight: 2 }}>SMA</span>
          {SMA_PERIODS.map(p => (
            <button
              key={p}
              className="btn sm"
              style={{
                borderColor: activeSmas.has(p) ? SMA_COLORS[p] : undefined,
                color:       activeSmas.has(p) ? SMA_COLORS[p] : 'var(--muted)',
                background:  activeSmas.has(p) ? SMA_COLORS[p] + '20' : undefined,
                fontSize: 10, padding: '1px 6px',
              }}
              onClick={() => toggleSma(p)}
            >{p}</button>
          ))}

          <div style={{ width: 1, height: 16, background: 'var(--border)', margin: '0 4px' }} />

          {/* Indicator toggles */}
          <span style={{ fontSize: 9, color: 'var(--muted)', textTransform: 'uppercase', letterSpacing: '0.06em', marginRight: 2 }}>IND</span>
          {[
            { key: 'rsi',    label: 'RSI 15',  val: showRsi,    set: setShowRsi    },
            { key: 'atr',    label: 'ATR 5',   val: showAtr,    set: setShowAtr    },
            { key: 'vortex', label: 'VTX 14',  val: showVortex, set: setShowVortex },
            { key: 'ppo',    label: 'PPO',     val: showPpo,    set: setShowPpo    },
          ].map(ind => (
            <button
              key={ind.key}
              className={`btn sm${ind.val ? ' active' : ''}`}
              style={{ fontSize: 10, padding: '1px 6px' }}
              onClick={() => ind.set((v: boolean) => !v)}
            >{ind.label}</button>
          ))}
        </div>
      </div>

      {loading && <div className="loading">Loading {sym} chart data...</div>}
      {error   && <div className="error-msg">{error}</div>}

      {/* Main chart area */}
      <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column' }}>
        <div
          ref={chartContainerRef}
          style={{ width: '100%', height: showAnyIndicator ? '62%' : '100%', minHeight: 0 }}
        />

        {/* Indicator sub-panels */}
        {showAnyIndicator && candles.length > 0 && (
          <div style={{ flex: 1, minHeight: 0, display: 'flex', flexDirection: 'column', borderTop: '1px solid var(--border)' }}>
            {showRsi    && <RsiPanel    candles={candles} freq={freq} height={indHeight} />}
            {showAtr    && <AtrPanel    candles={candles} freq={freq} height={indHeight} />}
            {showVortex && <VortexPanel candles={candles} freq={freq} height={indHeight} />}
            {showPpo    && <PpoPanel    candles={candles} freq={freq} height={indHeight} />}
          </div>
        )}
      </div>

      {/* Right-click context menu */}
      {ctxMenu && (
        <div
          style={{
            position: 'fixed', left: ctxMenu.x, top: ctxMenu.y, zIndex: 9999,
            background: 'var(--bg2)', border: '1px solid var(--bord2)',
            borderRadius: 5, padding: '4px 0', minWidth: 200,
            boxShadow: '0 8px 32px rgba(0,0,0,0.6)',
          }}
          onClick={e => e.stopPropagation()}
        >
          <div style={{ padding: '3px 12px 6px', fontSize: 10, color: 'var(--muted)', borderBottom: '1px solid var(--border)' }}>
            {sym} — {new Date((ctxMenu.time || 0) * 1000).toLocaleDateString()} @ ${ctxMenu.price.toFixed(2)}
          </div>
          <CtxItem icon="📰" label="Google News for this date" onClick={openGoogleNews} />
          <CtxItem icon="🔔" label={`Add alert at $${ctxMenu.price.toFixed(2)}`} onClick={addAlertAtPrice} />
          <CtxItem icon="📊" label="Load vol surface" onClick={() => { window.dispatchEvent(new CustomEvent('granite:loadVolSurface', { detail: { sym } })); setCtxMenu(null) }} />
          <CtxItem icon="✕"  label="Close" onClick={() => setCtxMenu(null)} color="var(--muted)" />
        </div>
      )}
    </div>
  )
}

function CtxItem({ icon, label, onClick, color }: { icon: string; label: string; onClick: () => void; color?: string }) {
  return (
    <div
      onClick={onClick}
      style={{
        padding: '6px 12px', cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 8,
        fontSize: 12, color: color || 'var(--text)', transition: 'background 0.1s',
      }}
      onMouseEnter={e => (e.currentTarget.style.background = 'var(--bg3)')}
      onMouseLeave={e => (e.currentTarget.style.background = '')}
    >
      <span style={{ fontSize: 14 }}>{icon}</span>{label}
    </div>
  )
}

// ── Indicator sub-panel components ────────────────────────────

function MiniChart({
  data, color, height, title, min, max, refLines,
}: {
  data: { time: string | number; value: number | null }[]
  color: string
  height: string
  title: string
  min?: number
  max?: number
  refLines?: { value: number; color: string }[]
}) {
  const ref = useRef<HTMLDivElement>(null)
  const chartRef = useRef<IChartApi | null>(null)

  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 10, fontFamily: 'IBM Plex Mono, monospace' },
      grid:   { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0', scaleMargins: { top: 0.05, bottom: 0.05 } },
      timeScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0', visible: false },
      width:  ref.current.clientWidth,
      height: ref.current.clientHeight,
    })
    const s = c.addSeries(LineSeries, { color, lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    s.setData(data.filter(d => d.value != null) as any)
    refLines?.forEach(rl => s.createPriceLine({ price: rl.value, color: rl.color, lineWidth: 1, lineStyle: LineStyle.Dashed, axisLabelVisible: false, title: '' }))
    chartRef.current = c

    const obs = new ResizeObserver(() => {
      if (ref.current && chartRef.current) {
        chartRef.current.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight })
      }
    })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [data])

  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>
        {title}
      </div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

function toTime(c: Candle, freq: string): string {
  return freq === 'daily' || freq === 'weekly' || freq === 'monthly'
    ? new Date(c.time * 1000).toISOString().slice(0, 10)
    : String(c.time)
}

function RsiPanel({ candles, freq, height }: { candles: Candle[]; freq: string; height: string }) {
  const vals  = rsi(candles.map(c => c.close), 15)
  const data  = candles.map((c, i) => ({ time: toTime(c, freq), value: vals[i] }))
  return <MiniChart data={data} color="#9868f8" height={height} title="RSI (15)" refLines={[{ value: 70, color: '#f04f4888' }, { value: 30, color: '#3bba6c88' }]} />
}

function AtrPanel({ candles, freq, height }: { candles: Candle[]; freq: string; height: string }) {
  const vals  = atr(candles, 5)
  const data  = candles.map((c, i) => ({ time: toTime(c, freq), value: vals[i] }))
  return <MiniChart data={data} color="#d4972a" height={height} title="ATR (5)" />
}

function VortexPanel({ candles, freq, height }: { candles: Candle[]; freq: string; height: string }) {
  const { vip, vim } = vortex(candles, 14)
  // Render as two mini lines — we'll use a custom two-line chart
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 10, fontFamily: 'IBM Plex Mono, monospace' },
      grid:   { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0' },
      timeScale: { borderColor: '#1c2b3a', visible: false },
      width: ref.current.clientWidth, height: ref.current.clientHeight,
    })
    const s1 = c.addSeries(LineSeries, { color: '#3bba6c', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const s2 = c.addSeries(LineSeries, { color: '#f04f48', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    s1.setData(candles.map((cc, i) => ({ time: toTime(cc, freq), value: vip[i] })).filter(d => d.value != null) as any)
    s2.setData(candles.map((cc, i) => ({ time: toTime(cc, freq), value: vim[i] })).filter(d => d.value != null) as any)
    const obs = new ResizeObserver(() => { if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight }) })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [candles])
  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>
        Vortex (14) <span style={{ color: '#3bba6c' }}>VI+</span> / <span style={{ color: '#f04f48' }}>VI−</span>
      </div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

function PpoPanel({ candles, freq, height }: { candles: Candle[]; freq: string; height: string }) {
  const closes = candles.map(c => c.close)
  const { ppo: ppoLine, sig, hist } = ppo(closes, 12, 48, 200)
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (!ref.current) return
    const c = createChart(ref.current, {
      layout: { background: { color: 'transparent' }, textColor: '#6e8aa0', fontSize: 10, fontFamily: 'IBM Plex Mono, monospace' },
      grid:   { vertLines: { visible: false }, horzLines: { visible: false } },
      crosshair: { mode: CrosshairMode.Normal },
      rightPriceScale: { borderColor: '#1c2b3a', textColor: '#6e8aa0' },
      timeScale: { borderColor: '#1c2b3a', visible: false },
      width: ref.current.clientWidth, height: ref.current.clientHeight,
    })
    const sh = c.addSeries(HistogramSeries, { color: '#4d9fff40', priceLineVisible: false, lastValueVisible: false })
    const sp = c.addSeries(LineSeries, { color: '#4d9fff', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const ss = c.addSeries(LineSeries, { color: '#f04f48', lineWidth: 1, priceLineVisible: false, lastValueVisible: false })
    const toD = (v: number | null, i: number) => ({ time: toTime(candles[i], freq), value: v })
    sh.setData(hist.map(toD).filter(d => d.value != null) as any)
    sp.setData(ppoLine.map(toD).filter(d => d.value != null) as any)
    ss.setData(sig.map(toD).filter(d => d.value != null) as any)
    const obs = new ResizeObserver(() => { if (ref.current) c.applyOptions({ width: ref.current.clientWidth, height: ref.current.clientHeight }) })
    obs.observe(ref.current)
    return () => { obs.disconnect(); c.remove() }
  }, [candles])
  return (
    <div style={{ height, minHeight: 0, position: 'relative', borderBottom: '1px solid var(--border)' }}>
      <div style={{ position: 'absolute', top: 3, left: 6, fontSize: 9, color: '#6e8aa0', zIndex: 1, pointerEvents: 'none' }}>
        PPO (12,48,200)
      </div>
      <div ref={ref} style={{ width: '100%', height: '100%' }} />
    </div>
  )
}

'@
Write-File "react-frontend\src\components\tiles\ChartTile.tsx" $c

$c = @'
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

// ── Trade Ticket ──────────────────────────────────────────

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

'@
Write-File "react-frontend\src\components\tiles\LegsTile.tsx" $c

$c = @'
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

'@
Write-File "react-frontend\src\components\modals\AlertModal.tsx" $c

Write-File "install_and_run_wsl.sh" @'
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
echo "== Granite Trader v1.3 =="
if [ ! -f ".env" ]; then cp .env.example .env; echo "Created .env"; exit 1; fi
if [ ! -d "venv" ]; then python3 -m venv venv; fi
source venv/bin/activate
python -m pip install -q -r requirements.txt
set -a; source ./.env; set +a
if [ ! -f "${SCHWAB_TOKEN_PATH:-$ROOT_DIR/backend/schwab_token.json}" ]; then
    python backend/get_schwab_client_env.py
fi
pkill -f "uvicorn main:app" 2>/dev/null || true
pkill -f "vite preview"     2>/dev/null || true
echo "Starting backend: http://localhost:8000"
(cd backend && ../venv/bin/uvicorn main:app --reload --host 0.0.0.0 --port 8000) &
if [ -d "react-frontend/dist" ]; then
    echo "Starting React: http://localhost:5500"
    (cd react-frontend && npx vite preview --port 5500 --host) &
else
    echo "React not built yet - run: cd react-frontend && npm install && npm run build"
    (cd frontend && python3 -m http.server 5500) &
fi
echo "Open http://localhost:5500"
trap 'pkill -f "uvicorn main:app"; pkill -f "vite preview"; pkill -f "http.server"' EXIT
wait

'@

if (-not $SkipBuild) {
    Write-Info "Building React app in WSL..."
    $wslRoot = ($Root -replace 'C:\\', '/mnt/c/') -replace '\\', '/'
    $result = wsl.exe bash -lc "cd '$wslRoot/react-frontend' && npm install --silent 2>&1 | tail -5 && npm run build 2>&1 | tail -20"
    Write-Host $result
    if ($LASTEXITCODE -eq 0) { Write-OK "React build successful!" }
    else { Write-Warn "Check build output above. Try: -SkipBuild flag then build manually." }
} else {
    Write-Warn "Skipped build. Run in WSL:"
    Write-Warn "  cd /mnt/c/Users/alexm/granite_trader/react-frontend && npm install && npm run build"
}

if (-not $SkipGit -and (Test-Path (Join-Path $Root ".git"))) {
    Push-Location $Root
    git add -A
    $changed = git status --porcelain
    if ($changed) {
        git commit -m "v1.3 React build: chart tile + IV heatmap + scanner fix + topbar reorg"
        git push
        Write-OK "Git push complete."
    } else { Write-Info "Nothing new to commit." }
    Pop-Location
}

Write-OK ""
Write-OK "=== Granite Trader v1.3 Install Complete ==="
Write-Host ""
Write-Host "NEW IN v1.3:" -ForegroundColor Yellow
Write-Host "  BACKEND:"
Write-Host "    chart_adapter.py   - Schwab 5Y daily OHLCV via /chart/history endpoint"
Write-Host "    scanner.py         - All widths valid; nearest-integer qty; actual_defined_risk"
Write-Host "    schwab_adapter.py  - IV /100 fix (6679% -> 66.79%)"
Write-Host "  REACT CHART TILE:"
Write-Host "    TradingView Lightweight Charts candlesticks"
Write-Host "    Mouse wheel zoom (built-in to Lightweight Charts)"
Write-Host "    Crosshair with axis labels only, no pointer labels, no gridlines"
Write-Host "    Dark background (transparent on app bg)"
Write-Host "    SMA toggles: 8/16/32/50/64/128/200 day (all computed client-side)"
Write-Host "    Indicator sub-panels: RSI(15), ATR(5), Vortex(14), PPO(12,48,200)"
Write-Host "    Expected move lines (ATM straddle x 0.85) every Friday"
Write-Host "    Right-click: Google News for that date, add alert at price, load vol surface"
Write-Host "    Open positions marked as arrows on the chart"
Write-Host "    SPY / GLD comparison overlays (toggle)"
Write-Host "    9 timeframes: 1D/5D/1M/3M/6M/1Y/2Y/5Y/YTD"
Write-Host "  WATCHLIST:"
Write-Host "    IV term structure heat map (5 IV columns color-coded by slope)"
Write-Host "    Rising term structure (6M > spot) highlighted in warm colors"
Write-Host "  UI:"
Write-Host "    Topbar doubled height; center = focal price; right = balances"
Write-Host "    Bottom bar = skins + refresh + alerts"
Write-Host "    Panel focus border (accent color on active tile)"
Write-Host "    Gear icon per panel = column/field toggle settings (persisted)"
Write-Host ""
Write-Host "If build failed, add -SkipBuild and build manually in WSL" -ForegroundColor Yellow
Write-Host "Open: http://localhost:5500" -ForegroundColor Green
