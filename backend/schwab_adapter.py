from __future__ import annotations

import datetime as dt
import os
from typing import Any, Dict, List, Optional

from schwab.auth import client_from_token_file


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
                iv = _safe_float(contract.get("volatility"), default=0.0)
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


def get_quote(symbol: str) -> Dict[str, Any]:
    client = _get_client()
    response = client.get_quote(symbol.upper())
    response.raise_for_status()
    return response.json()


def get_option_chain_raw(
    symbol: str,
    strike_count: int = 25,
    from_date: Optional[str | dt.date] = None,
    to_date: Optional[str | dt.date] = None,
    include_underlying_quote: bool = True,
) -> Dict[str, Any]:
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
    strike_count: int = 25,
    from_date: Optional[str | dt.date] = None,
    to_date: Optional[str | dt.date] = None,
) -> Dict[str, Any]:
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


def get_available_expirations(symbol: str, strike_count: int = 25) -> List[str]:
    flat = get_flat_option_chain(symbol=symbol, strike_count=strike_count)
    return flat["expirations"]


def get_next_7_expirations(symbol: str, strike_count: int = 25) -> List[str]:
    expirations = get_available_expirations(symbol=symbol, strike_count=strike_count)
    return expirations[:7]


def get_next_7_opex(symbol: str, strike_count: int = 25) -> List[str]:
    """
    Kept for backward compatibility with older code paths.
    Now returns the 7 nearest expiration dates regardless of daily/weekly/monthly/quarterly type.
    """
    return get_next_7_expirations(symbol=symbol, strike_count=strike_count)