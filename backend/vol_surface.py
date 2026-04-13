from __future__ import annotations

from collections import defaultdict
from statistics import mean
from typing import Any, Dict, List, Optional, Tuple

from schwab_adapter import get_flat_option_chain


def _safe_float(value: Any) -> Optional[float]:
    try:
        if value is None or value == "":
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def _nearest_expirations(items: List[Dict[str, Any]], max_expirations: int) -> List[str]:
    expirations = sorted(
        {
            str(item.get("expiration"))
            for item in items
            if item.get("expiration")
        }
    )
    return expirations[:max_expirations]


def _extract_underlying_price(items: List[Dict[str, Any]], fallback: Optional[float]) -> Optional[float]:
    if fallback is not None and fallback > 0:
        return round(fallback, 4)

    candidates: List[float] = []
    for item in items:
        value = _safe_float(item.get("underlying_price"))
        if value is not None and value > 0:
            candidates.append(value)

    if not candidates:
        return None
    return round(mean(candidates), 4)


def _choose_centered_strikes(
    items: List[Dict[str, Any]],
    underlying_price: Optional[float],
    strike_count: int,
) -> List[float]:
    strikes = sorted(
        {
            round(float(item["strike"]), 4)
            for item in items
            if _safe_float(item.get("strike")) is not None
        }
    )
    if not strikes:
        return []

    if underlying_price is None:
        return strikes[:strike_count]

    closest_idx = min(range(len(strikes)), key=lambda i: abs(strikes[i] - underlying_price))
    half = strike_count // 2
    start = max(0, closest_idx - half)
    end = min(len(strikes), start + strike_count)
    start = max(0, end - strike_count)
    return strikes[start:end]


def _build_iv_lookup(items: List[Dict[str, Any]]) -> Dict[Tuple[str, float], Dict[str, Optional[float]]]:
    bucket: Dict[Tuple[str, float], Dict[str, List[float]]] = defaultdict(lambda: {"call": [], "put": []})

    for item in items:
        exp = str(item.get("expiration") or "")
        strike = _safe_float(item.get("strike"))
        option_side = str(item.get("option_side") or "").lower()
        iv = _safe_float(item.get("iv"))

        if not exp or strike is None or option_side not in {"call", "put"} or iv is None or iv <= 0:
            continue

        bucket[(exp, round(strike, 4))][option_side].append(iv)

    lookup: Dict[Tuple[str, float], Dict[str, Optional[float]]] = {}
    for key, values in bucket.items():
        call_iv = mean(values["call"]) if values["call"] else None
        put_iv = mean(values["put"]) if values["put"] else None
        avg_candidates = [v for v in (call_iv, put_iv) if v is not None]
        avg_iv = mean(avg_candidates) if avg_candidates else None
        lookup[key] = {
            "call_iv": round(call_iv, 6) if call_iv is not None else None,
            "put_iv": round(put_iv, 6) if put_iv is not None else None,
            "avg_iv": round(avg_iv, 6) if avg_iv is not None else None,
        }
    return lookup


def _avg_iv_by_expiration(
    expirations: List[str],
    strikes: List[float],
    iv_lookup: Dict[Tuple[str, float], Dict[str, Optional[float]]],
) -> Dict[str, Optional[float]]:
    results: Dict[str, Optional[float]] = {}
    for exp in expirations:
        vals: List[float] = []
        for strike in strikes:
            row = iv_lookup.get((exp, strike), {})
            avg_iv = _safe_float(row.get("avg_iv"))
            if avg_iv is not None:
                vals.append(avg_iv)
        results[exp] = round(mean(vals), 6) if vals else None
    return results


def _build_iv_matrix(
    expirations: List[str],
    strikes: List[float],
    iv_lookup: Dict[Tuple[str, float], Dict[str, Optional[float]]],
) -> List[List[Optional[float]]]:
    matrix: List[List[Optional[float]]] = []
    for exp in expirations:
        row: List[Optional[float]] = []
        for strike in strikes:
            avg_iv = _safe_float(iv_lookup.get((exp, strike), {}).get("avg_iv"))
            row.append(round(avg_iv, 6) if avg_iv is not None else None)
        matrix.append(row)
    return matrix


def _build_skew_curves(
    expirations: List[str],
    strikes: List[float],
    iv_lookup: Dict[Tuple[str, float], Dict[str, Optional[float]]],
) -> Dict[str, List[Dict[str, Optional[float]]]]:
    curves: Dict[str, List[Dict[str, Optional[float]]]] = {}
    for exp in expirations:
        curve: List[Dict[str, Optional[float]]] = []
        for strike in strikes:
            cell = iv_lookup.get((exp, strike), {})
            curve.append(
                {
                    "strike": round(strike, 4),
                    "call_iv": _safe_float(cell.get("call_iv")),
                    "put_iv": _safe_float(cell.get("put_iv")),
                    "avg_iv": _safe_float(cell.get("avg_iv")),
                }
            )
        curves[exp] = curve
    return curves


def _build_richness_scores(
    expirations: List[str],
    avg_iv_by_exp: Dict[str, Optional[float]],
    skew_curves: Dict[str, List[Dict[str, Optional[float]]]],
    underlying_price: Optional[float],
) -> Dict[str, Dict[str, Optional[float]]]:
    output: Dict[str, Dict[str, Optional[float]]] = {}

    all_avg_iv = [v for v in avg_iv_by_exp.values() if v is not None]
    global_avg_iv = mean(all_avg_iv) if all_avg_iv else None

    for exp in expirations:
        avg_iv = avg_iv_by_exp.get(exp)
        curve = skew_curves.get(exp, [])

        atm_candidates = curve
        if underlying_price is not None and curve:
            atm_candidates = sorted(curve, key=lambda x: abs(float(x["strike"]) - underlying_price))[:5]

        put_vals = [x["put_iv"] for x in atm_candidates if x.get("put_iv") is not None]
        call_vals = [x["call_iv"] for x in atm_candidates if x.get("call_iv") is not None]

        put_avg = mean(put_vals) if put_vals else None
        call_avg = mean(call_vals) if call_vals else None
        skew = (put_avg - call_avg) if (put_avg is not None and call_avg is not None) else None

        iv_premium_vs_surface = None
        if avg_iv is not None and global_avg_iv is not None:
            iv_premium_vs_surface = avg_iv - global_avg_iv

        richness_score = None
        if iv_premium_vs_surface is not None and skew is not None:
            richness_score = (iv_premium_vs_surface * 0.7) + (skew * 0.3)
        elif iv_premium_vs_surface is not None:
            richness_score = iv_premium_vs_surface
        elif skew is not None:
            richness_score = skew

        output[exp] = {
            "avg_iv": round(avg_iv, 6) if avg_iv is not None else None,
            "put_call_skew_near_spot": round(skew, 6) if skew is not None else None,
            "iv_premium_vs_surface": round(iv_premium_vs_surface, 6) if iv_premium_vs_surface is not None else None,
            "richness_score": round(richness_score, 6) if richness_score is not None else None,
        }

    return output


def build_vol_surface_payload(
    symbol: str,
    max_expirations: int = 7,
    strike_count: int = 21,
) -> Dict[str, Any]:
    flat = get_flat_option_chain(symbol=symbol, strike_count=max(strike_count, 21))
    chain_items = flat["contracts"]

    if not chain_items:
        return {
            "symbol": symbol.upper(),
            "expirations": [],
            "strikes": [],
            "underlying_price": None,
            "iv_matrix": [],
            "avg_iv_by_expiration": {},
            "skew_curves": {},
            "richness_scores": {},
            "count": 0,
        }

    expirations = _nearest_expirations(chain_items, max_expirations=max_expirations)
    filtered_items = [item for item in chain_items if str(item.get("expiration")) in expirations]

    underlying_price = _extract_underlying_price(filtered_items, fallback=_safe_float(flat.get("underlying_price")))
    strikes = _choose_centered_strikes(
        filtered_items,
        underlying_price=underlying_price,
        strike_count=strike_count,
    )

    iv_lookup = _build_iv_lookup(filtered_items)
    iv_matrix = _build_iv_matrix(expirations, strikes, iv_lookup)
    avg_iv_by_expiration = _avg_iv_by_expiration(expirations, strikes, iv_lookup)
    skew_curves = _build_skew_curves(expirations, strikes, iv_lookup)
    richness_scores = _build_richness_scores(
        expirations=expirations,
        avg_iv_by_exp=avg_iv_by_expiration,
        skew_curves=skew_curves,
        underlying_price=underlying_price,
    )

    return {
        "symbol": symbol.upper(),
        "underlying_price": underlying_price,
        "expirations": expirations,
        "strikes": strikes,
        "iv_matrix": iv_matrix,
        "avg_iv_by_expiration": avg_iv_by_expiration,
        "skew_curves": skew_curves,
        "richness_scores": richness_scores,
        "count": len(filtered_items),
        "selection_rule": "nearest_expiration_dates",
    }