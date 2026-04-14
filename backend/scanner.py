from __future__ import annotations

from collections import defaultdict
from typing import Any, Dict, List, Optional, Tuple

from cache_manager import ensure_symbol_loaded

# Supported spread widths.  Derived dynamically from the actual chain in
# _build_spread_candidates_for_expiration â€” this list acts as the minimum
# acceptance set; widths outside it are skipped.
SUPPORTED_WIDTHS = [0.5, 1.0, 2.0, 2.5, 5.0, 10.0]


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


def _is_supported_width(width: float) -> bool:
    return any(abs(width - w) < 0.0001 for w in SUPPORTED_WIDTHS)


def _contracts_for_same_risk(total_risk: float, width: float) -> int:
    """
    How many spreads of this width produce exactly total_risk of defined risk?
    Returns 0 if the width doesn't divide evenly.
    """
    per_spread_risk = width * 100.0
    if per_spread_risk <= 0:
        return 0
    quantity = total_risk / per_spread_risk
    rounded = round(quantity)
    if abs(quantity - rounded) > 1e-9 or rounded <= 0:
        return 0
    return int(rounded)


# ---------------------------------------------------------------------------
# Pricing modes
# ---------------------------------------------------------------------------

def _mid(bid: float, ask: float, mark: float) -> float:
    if bid > 0 and ask > 0:
        if ask < bid:
            ask = bid
        return (bid + ask) / 2.0
    if mark > 0:
        return mark
    return ask or bid or 0.0


def _conservative_mid_sell(contract: Dict[str, Any]) -> float:
    bid  = _safe_float(contract.get("bid"))
    ask  = _safe_float(contract.get("ask"))
    mark = _safe_float(contract.get("mark"))
    mid  = _mid(bid, ask, mark)
    return (bid + mid) / 2.0 if bid > 0 and mid > 0 else mid


def _conservative_mid_buy(contract: Dict[str, Any]) -> float:
    bid  = _safe_float(contract.get("bid"))
    ask  = _safe_float(contract.get("ask"))
    mark = _safe_float(contract.get("mark"))
    mid  = _mid(bid, ask, mark)
    return (ask + mid) / 2.0 if ask > 0 and mid > 0 else mid


def _pricing_value(contract: Dict[str, Any], action: str, pricing_mode: str) -> float:
    mode = pricing_mode.lower().strip()
    if mode == "natural":
        return _safe_float(contract.get("bid") if action == "sell" else contract.get("ask"))
    if mode == "mid":
        return _mid(
            _safe_float(contract.get("bid")),
            _safe_float(contract.get("ask")),
            _safe_float(contract.get("mark")),
        )
    # default: conservative_mid
    return _conservative_mid_sell(contract) if action == "sell" else _conservative_mid_buy(contract)


# ---------------------------------------------------------------------------
# Ranking helpers
# ---------------------------------------------------------------------------

def _percentile_ranks(items: List[float]) -> List[float]:
    if not items:
        return []
    if len(items) == 1:
        return [1.0]
    ordered = sorted((value, idx) for idx, value in enumerate(items))
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
    # default: richness
    return sorted(items, key=lambda x: x.get("richness_score", 0.0), reverse=True)


# ---------------------------------------------------------------------------
# Core spread builder
# ---------------------------------------------------------------------------

def _build_spread_candidates_for_expiration(
    symbol: str,
    expiration: str,
    underlying_price: float,
    side: str,
    contracts: List[Dict[str, Any]],
    total_risk: float,
    pricing_mode: str,
) -> List[Dict[str, Any]]:
    """
    Generate all valid credit-spread pairs for one expiration / one side.

    Rules:
      - call spread: short lower strike, long higher strike (bear call)
      - put  spread: short higher strike, long lower strike (bull put)
      - widths restricted to SUPPORTED_WIDTHS
      - quantity chosen so total defined risk == total_risk exactly
      - net_credit must be positive (it IS a credit spread)
    """
    if not contracts:
        return []

    contracts_sorted = sorted(contracts, key=lambda x: x["strike"])
    results: List[Dict[str, Any]] = []

    for i, short_c in enumerate(contracts_sorted):
        for j, long_c in enumerate(contracts_sorted):
            if i == j:
                continue

            short_strike = _safe_float(short_c["strike"])
            long_strike  = _safe_float(long_c["strike"])

            if side == "call":
                if long_strike <= short_strike:
                    continue
            elif side == "put":
                if long_strike >= short_strike:
                    continue
            else:
                continue

            width = round(abs(long_strike - short_strike), 4)
            if not _is_supported_width(width):
                continue

            quantity = _contracts_for_same_risk(total_risk=total_risk, width=width)
            if quantity <= 0:
                continue

            short_fill = _pricing_value(short_c, action="sell", pricing_mode=pricing_mode)
            long_fill  = _pricing_value(long_c,  action="buy",  pricing_mode=pricing_mode)

            if short_fill <= 0 or long_fill <= 0:
                continue

            net_credit_per_spread = (short_fill - long_fill) * 100.0
            if net_credit_per_spread <= 0:
                continue

            gross_defined_risk = width * 100.0 * quantity
            short_value = short_fill * 100.0 * quantity
            long_cost   = long_fill  * 100.0 * quantity
            net_credit  = net_credit_per_spread * quantity
            max_loss    = gross_defined_risk - net_credit
            limit_impact = max(short_value, long_cost)

            # Credit received as % of gross defined risk (primary metric)
            credit_pct_risk = net_credit / gross_defined_risk if gross_defined_risk > 0 else 0.0

            reward_to_max_loss: Optional[float] = None
            if abs(max_loss) > 1e-12:
                reward_to_max_loss = net_credit / max_loss

            results.append(
                {
                    "symbol":         symbol.upper(),
                    "expiration":     expiration,
                    "structure":      "credit_spread",
                    "option_side":    side,
                    "short_strike":   round(short_strike, 4),
                    "long_strike":    round(long_strike, 4),
                    "width":          round(width, 4),
                    "quantity":       quantity,
                    # risk fields
                    "defined_risk":         round(gross_defined_risk, 2),
                    "gross_defined_risk":   round(gross_defined_risk, 2),
                    "max_loss":             round(max_loss, 2),
                    # price fields
                    "short_price":  round(short_fill, 4),
                    "long_price":   round(long_fill, 4),
                    "short_value":  round(short_value, 2),
                    "long_cost":    round(long_cost, 2),
                    "net_credit":   round(net_credit, 2),
                    # reward/risk
                    "credit_pct_risk":        round(credit_pct_risk, 6),
                    "credit_pct_risk_pct":    round(credit_pct_risk * 100.0, 2),
                    "reward_to_max_loss":     round(reward_to_max_loss, 6) if reward_to_max_loss is not None else None,
                    "reward_to_max_loss_pct": round(reward_to_max_loss * 100.0, 2) if reward_to_max_loss is not None else None,
                    "limit_impact":           round(limit_impact, 2),
                    # Greeks / vol
                    "short_delta": round(_safe_float(short_c.get("delta")), 6),
                    "long_delta":  round(_safe_float(long_c.get("delta")), 6),
                    "short_iv":    round(_safe_float(short_c.get("iv")), 6),
                    "long_iv":     round(_safe_float(long_c.get("iv")), 6),
                    "avg_iv":      round(
                        (_safe_float(short_c.get("iv")) + _safe_float(long_c.get("iv"))) / 2.0, 6
                    ),
                    "underlying_price":       round(underlying_price, 4),
                    "short_option_symbol":    short_c.get("option_symbol", ""),
                    "long_option_symbol":     long_c.get("option_symbol", ""),
                    "pricing_mode":           pricing_mode,
                }
            )

    return results


# ---------------------------------------------------------------------------
# Enrichment pass (relative ranking within each expiration/side bucket)
# ---------------------------------------------------------------------------

def _enrich_candidates(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Add expiration-relative ranking fields:
      credit_pct_risk_rank_within_exp
      iv_rank_within_exp
      exp_avg_credit_pct_risk
      exp_avg_iv
      credit_pct_vs_exp_avg
      iv_vs_exp_avg
      richness_score  (70% credit rank + 30% IV rank)
    """
    grouped: Dict[Tuple[str, str], List[Dict[str, Any]]] = defaultdict(list)
    for item in items:
        grouped[(item["expiration"], item["option_side"])].append(item)

    for group in grouped.values():
        credit_values = [item["credit_pct_risk"] for item in group]
        iv_values     = [item["avg_iv"]           for item in group]

        credit_ranks = _percentile_ranks(credit_values)
        iv_ranks     = _percentile_ranks(iv_values)

        avg_credit = sum(credit_values) / len(credit_values) if credit_values else 0.0
        avg_iv     = sum(iv_values)     / len(iv_values)     if iv_values     else 0.0

        for idx, item in enumerate(group):
            cr = credit_ranks[idx]
            ir = iv_ranks[idx]
            item["credit_pct_risk_rank_within_exp"] = round(cr, 6)
            item["iv_rank_within_exp"]              = round(ir, 6)
            item["exp_avg_credit_pct_risk"]         = round(avg_credit, 6)
            item["exp_avg_credit_pct_risk_pct"]     = round(avg_credit * 100.0, 2)
            item["exp_avg_iv"]                      = round(avg_iv, 6)
            item["credit_pct_vs_exp_avg"]           = round(item["credit_pct_risk"] / avg_credit if avg_credit > 0 else 0.0, 6)
            item["iv_vs_exp_avg"]                   = round(item["avg_iv"] / avg_iv if avg_iv > 0 else 0.0, 6)
            item["richness_score"]                  = round((0.70 * cr) + (0.30 * ir), 6)

    return items


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def generate_risk_equivalent_candidates(
    symbol: str = "SPY",
    total_risk: float = 600.0,
    expirations: Optional[List[str]] = None,
    side_filter: str = "all",
    pricing_mode: str = "conservative_mid",
    strike_count: int = 200,
    ranking: str = "richness",
    max_results: int = 250,
) -> List[Dict[str, Any]]:
    """
    Main entry point for the entry scanner.

    Reads contracts from the shared cache (via cache_manager).
    Does NOT call Schwab directly.

    Args:
        symbol:       Underlying ticker.
        total_risk:   Target total defined risk in dollars (e.g. 600).
        expirations:  If None, all cached expirations are scanned.
        side_filter:  'all' | 'call' | 'put'
        pricing_mode: 'conservative_mid' | 'mid' | 'natural'
        strike_count: Passed to cache_manager in case a fresh load is needed.
        ranking:      'credit' | 'credit_pct_risk' | 'limit_impact' | 'max_loss' | 'richness'
        max_results:  Truncate output to this many rows.

    Returns:
        List of spread candidate dicts, sorted by `ranking`.
    """
    side_filter = side_filter.lower().strip()
    if side_filter not in {"all", "call", "put"}:
        raise ValueError("side_filter must be one of: all, call, put")

    # Pull from the shared cache (will refresh if stale)
    state = ensure_symbol_loaded(
        symbol=symbol, strike_count=strike_count, requested_by="scanner"
    )
    all_contracts   = list(state.get("contracts", []))
    underlying_price = _safe_float(state.get("underlying_price"))
    allowed_expirations = set(expirations or [])

    # Group contracts by (expiration, side)
    by_exp_and_side: Dict[Tuple[str, str], List[Dict[str, Any]]] = defaultdict(list)
    for contract in all_contracts:
        exp  = contract["expiration"]
        side = contract["option_side"]
        if allowed_expirations and exp not in allowed_expirations:
            continue
        if side_filter != "all" and side != side_filter:
            continue
        by_exp_and_side[(exp, side)].append(contract)

    # Build candidates for each expiration/side bucket
    results: List[Dict[str, Any]] = []
    for (expiration, option_side), contracts in by_exp_and_side.items():
        results.extend(
            _build_spread_candidates_for_expiration(
                symbol=symbol,
                expiration=expiration,
                underlying_price=underlying_price,
                side=option_side,
                contracts=contracts,
                total_risk=total_risk,
                pricing_mode=pricing_mode,
            )
        )

    results = _enrich_candidates(results)
    results = _sort_candidates(results, ranking=ranking)

    if max_results > 0:
        results = results[:max_results]

    return results
