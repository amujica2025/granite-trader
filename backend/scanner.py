"""
scanner.py  â€”  Granite Trader entry spread scanner

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
