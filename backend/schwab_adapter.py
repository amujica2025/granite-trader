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
                # Frontend displays as (v * 100).toFixed(2) + '%' â€” correct with decimal form.
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
        # Fields that need price history or proprietary models â€” filled by Barchart after-hours:
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
