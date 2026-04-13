from __future__ import annotations

from collections import defaultdict
from typing import Any, Dict, List, Optional, Tuple

from schwab_adapter import get_flat_option_chain

SUPPORTED_WIDTHS = [1.0, 2.0, 2.5, 5.0, 10.0]


def _safe_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None or value == "":
            return default
        return float(value)
    except Exception:
        return default


def _is_supported_width(width: float) -> bool:
    return any(abs(width - candidate) < 0.0001 for candidate in SUPPORTED_WIDTHS)


def _contracts_for_same_risk(total_risk: float, width: float) -> int:
    per_spread_risk = width * 100.0
    if per_spread_risk <= 0:
        return 0
    quantity = total_risk / per_spread_risk
    rounded = round(quantity)
    if abs(quantity - rounded) > 1e-9 or rounded <= 0:
        return 0
    return int(rounded)


def _mid(bid: float, ask: float, mark: float) -> float:
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


def _conservative_mid_sell(contract: Dict[str, Any]) -> float:
    bid = _safe_float(contract.get("bid"))
    ask = _safe_float(contract.get("ask"))
    mark = _safe_float(contract.get("mark"))
    mid = _mid(bid, ask, mark)
    if bid > 0 and mid > 0:
        return (bid + mid) / 2.0
    return mid


def _conservative_mid_buy(contract: Dict[str, Any]) -> float:
    bid = _safe_float(contract.get("bid"))
    ask = _safe_float(contract.get("ask"))
    mark = _safe_float(contract.get("mark"))
    mid = _mid(bid, ask, mark)
    if ask > 0 and mid > 0:
        return (ask + mid) / 2.0
    return mid


def _pricing_value(contract: Dict[str, Any], action: str, pricing_mode: str) -> float:
    pricing_mode = pricing_mode.lower().strip()

    if pricing_mode == "natural":
        if action == "sell":
            return _safe_float(contract.get("bid"), default=0.0)
        return _safe_float(contract.get("ask"), default=0.0)

    if pricing_mode == "mid":
        return _mid(
            _safe_float(contract.get("bid")),
            _safe_float(contract.get("ask")),
            _safe_float(contract.get("mark")),
        )

    # Default: conservative_mid
    if action == "sell":
        return _conservative_mid_sell(contract)
    return _conservative_mid_buy(contract)


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
    ranking = ranking.lower().strip()

    if ranking == "credit":
        return sorted(items, key=lambda x: x["net_credit"], reverse=True)

    if ranking == "credit_pct_risk":
        return sorted(items, key=lambda x: x["credit_pct_risk"], reverse=True)

    if ranking == "limit_impact":
        return sorted(items, key=lambda x: (x["limit_impact"], -x["credit_pct_risk"]))

    if ranking == "max_loss":
        return sorted(items, key=lambda x: (x["max_loss"], -x["credit_pct_risk"]))

    return sorted(items, key=lambda x: x["richness_score"], reverse=True)


def _build_spread_candidates_for_expiration(
    symbol: str,
    expiration: str,
    underlying_price: float,
    side: str,
    contracts: List[Dict[str, Any]],
    total_risk: float,
    pricing_mode: str,
) -> List[Dict[str, Any]]:
    if not contracts:
        return []

    contracts_sorted = sorted(contracts, key=lambda x: x["strike"])
    results: List[Dict[str, Any]] = []

    for i, short_contract in enumerate(contracts_sorted):
        for j, long_contract in enumerate(contracts_sorted):
            if i == j:
                continue

            short_strike = _safe_float(short_contract["strike"])
            long_strike = _safe_float(long_contract["strike"])

            if side == "call":
                # Bear call credit spread: short lower strike, long higher strike
                if long_strike <= short_strike:
                    continue
            elif side == "put":
                # Bull put credit spread: short higher strike, long lower strike
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

            short_fill = _pricing_value(short_contract, action="sell", pricing_mode=pricing_mode)
            long_fill = _pricing_value(long_contract, action="buy", pricing_mode=pricing_mode)

            if short_fill <= 0 or long_fill <= 0:
                continue

            net_credit_per_spread = (short_fill - long_fill) * 100.0
            if net_credit_per_spread <= 0:
                continue

            gross_defined_risk = width * 100.0 * quantity
            short_value = short_fill * 100.0 * quantity
            long_cost = long_fill * 100.0 * quantity
            net_credit = net_credit_per_spread * quantity
            max_loss = gross_defined_risk - net_credit
            limit_impact = max(short_value, long_cost)

            # Keep your original metric exactly as requested:
            # credit received as % of gross defined risk
            credit_pct_risk = net_credit / gross_defined_risk if gross_defined_risk > 0 else 0.0

            # Add actual max loss as a separate field.
            # Allow negative values to remain visible if they occur from the pricing model / chain shape.
            reward_to_max_loss = None
            if abs(max_loss) > 1e-12:
                reward_to_max_loss = net_credit / max_loss

            results.append(
                {
                    "symbol": symbol.upper(),
                    "expiration": expiration,
                    "structure": "credit_spread",
                    "option_side": side,
                    "short_strike": round(short_strike, 4),
                    "long_strike": round(long_strike, 4),
                    "width": round(width, 4),
                    "quantity": quantity,
                    "defined_risk": round(gross_defined_risk, 2),
                    "gross_defined_risk": round(gross_defined_risk, 2),
                    "max_loss": round(max_loss, 2),
                    "short_price": round(short_fill, 4),
                    "long_price": round(long_fill, 4),
                    "short_value": round(short_value, 2),
                    "long_cost": round(long_cost, 2),
                    "net_credit": round(net_credit, 2),
                    "credit_pct_risk": round(credit_pct_risk, 6),
                    "credit_pct_risk_pct": round(credit_pct_risk * 100.0, 2),
                    "reward_to_max_loss": round(reward_to_max_loss, 6) if reward_to_max_loss is not None else None,
                    "reward_to_max_loss_pct": round(reward_to_max_loss * 100.0, 2) if reward_to_max_loss is not None else None,
                    "limit_impact": round(limit_impact, 2),
                    "short_delta": round(_safe_float(short_contract.get("delta")), 6),
                    "long_delta": round(_safe_float(long_contract.get("delta")), 6),
                    "short_iv": round(_safe_float(short_contract.get("iv")), 6),
                    "long_iv": round(_safe_float(long_contract.get("iv")), 6),
                    "avg_iv": round(
                        (
                            _safe_float(short_contract.get("iv"))
                            + _safe_float(long_contract.get("iv"))
                        )
                        / 2.0,
                        6,
                    ),
                    "underlying_price": round(underlying_price, 4),
                    "short_option_symbol": short_contract.get("option_symbol", ""),
                    "long_option_symbol": long_contract.get("option_symbol", ""),
                    "pricing_mode": pricing_mode,
                }
            )

    return results


def _enrich_candidates(items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    grouped: Dict[Tuple[str, str], List[Dict[str, Any]]] = defaultdict(list)
    for item in items:
        grouped[(item["expiration"], item["option_side"])].append(item)

    for (_, _), group in grouped.items():
        credit_values = [item["credit_pct_risk"] for item in group]
        iv_values = [item["avg_iv"] for item in group]

        credit_ranks = _percentile_ranks(credit_values)
        iv_ranks = _percentile_ranks(iv_values)

        avg_credit = sum(credit_values) / len(credit_values) if credit_values else 0.0
        avg_iv = sum(iv_values) / len(iv_values) if iv_values else 0.0

        for idx, item in enumerate(group):
            credit_rank = credit_ranks[idx]
            iv_rank = iv_ranks[idx]
            richness_score = (0.70 * credit_rank) + (0.30 * iv_rank)

            item["credit_pct_risk_rank_within_exp"] = round(credit_rank, 6)
            item["iv_rank_within_exp"] = round(iv_rank, 6)
            item["exp_avg_credit_pct_risk"] = round(avg_credit, 6)
            item["exp_avg_credit_pct_risk_pct"] = round(avg_credit * 100.0, 2)
            item["exp_avg_iv"] = round(avg_iv, 6)
            item["credit_pct_vs_exp_avg"] = round(
                (item["credit_pct_risk"] / avg_credit) if avg_credit > 0 else 0.0,
                6,
            )
            item["iv_vs_exp_avg"] = round(
                (item["avg_iv"] / avg_iv) if avg_iv > 0 else 0.0,
                6,
            )
            item["richness_score"] = round(richness_score, 6)

    return items


def generate_risk_equivalent_candidates(
    symbol: str = "SPY",
    total_risk: float = 600.0,
    expirations: Optional[List[str]] = None,
    side_filter: str = "all",
    pricing_mode: str = "conservative_mid",
    strike_count: int = 25,
    ranking: str = "richness",
    max_results: int = 250,
) -> List[Dict[str, Any]]:
    side_filter = side_filter.lower().strip()
    if side_filter not in {"all", "call", "put"}:
        raise ValueError("side_filter must be one of: all, call, put")

    flat_chain = get_flat_option_chain(symbol=symbol, strike_count=strike_count)
    all_contracts = flat_chain["contracts"]
    underlying_price = _safe_float(flat_chain["underlying_price"])
    allowed_expirations = set(expirations or [])

    by_exp_and_side: Dict[Tuple[str, str], List[Dict[str, Any]]] = defaultdict(list)
    for contract in all_contracts:
        expiration = contract["expiration"]
        option_side = contract["option_side"]

        if allowed_expirations and expiration not in allowed_expirations:
            continue
        if side_filter != "all" and option_side != side_filter:
            continue

        by_exp_and_side[(expiration, option_side)].append(contract)

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