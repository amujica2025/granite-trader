from __future__ import annotations
import asyncio, os
from typing import Any, Dict, List
from tastytrade import Session
from tastytrade.account import Account

def _get_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value

async def _get_account_data_async() -> Dict[str, Any]:
    client_secret = _get_env("TASTY_CLIENT_SECRET")
    refresh_token = _get_env("TASTY_REFRESH_TOKEN")
    account_number = _get_env("TASTY_ACCOUNT_NUMBER")
    session = Session(client_secret, refresh_token)
    await session.refresh()
    accounts = await Account.get(session)
    target = None
    for acct in accounts:
        if getattr(acct, "account_number", None) == account_number:
            target = acct
            break
    if target is None:
        available = [getattr(a, "account_number", None) for a in accounts]
        raise RuntimeError(f"Tasty account {account_number} not found. Available accounts: {available}")
    balances = await target.get_balances(session)
    positions = await target.get_positions(session)
    return {"session_token": getattr(session, "session_token", None), "balances": balances, "positions": positions}

def _run(coro):
    try:
        return asyncio.run(coro)
    except RuntimeError:
        loop = asyncio.new_event_loop()
        try:
            return loop.run_until_complete(coro)
        finally:
            loop.close()

def fetch_account_snapshot() -> Dict[str, Any]:
    return _run(_get_account_data_async())

def extract_net_liq(snapshot: Dict[str, Any]) -> float:
    balances = snapshot["balances"]
    for value in [getattr(balances, "net_liquidating_value", None), getattr(balances, "net_liq", None), getattr(balances, "net_liquidating_value_effect", None)]:
        if value is not None:
            return float(value)
    raise RuntimeError("Could not find net liquidating value in tasty balances object.")

def normalize_live_positions(snapshot: Dict[str, Any]) -> List[Dict[str, Any]]:
    positions = snapshot["positions"]
    normalized: List[Dict[str, Any]] = []
    for pos in positions:
        qty_raw = float(getattr(pos, "quantity", 0) or 0)
        qty_abs = int(abs(qty_raw))
        if qty_abs == 0:
            continue
        symbol = getattr(pos, "symbol", None) or getattr(pos, "underlying_symbol", None) or "UNKNOWN"
        option_type = str(getattr(pos, "option_type", "") or "").lower()
        expiration = str(getattr(pos, "expires_at", None) or getattr(pos, "expiration_date", None) or "")
        strike = float(getattr(pos, "strike_price", 0) or 0)
        mark_price = float(getattr(pos, "mark_price", None) or getattr(pos, "mark", None) or getattr(pos, "close_price", None) or 0)
        trade_price = float(getattr(pos, "average_open_price", None) or getattr(pos, "average_open_price_effect", None) or mark_price)
        sign = -1 if qty_raw < 0 else 1
        for i in range(qty_abs):
            qty = sign * 1
            side = "short" if qty < 0 else "long"
            pnl_open = (trade_price - mark_price) * 100 if side == "short" else (mark_price - trade_price) * 100
            normalized.append({
                "id": f"{symbol}-{expiration}-{option_type}-{strike}-{i+1}-{side}",
                "underlying": symbol,
                "group": "tasty_live",
                "instrument_type": "Equity Option",
                "option_type": option_type,
                "expiration": expiration,
                "strike": strike,
                "quantity": qty,
                "display_qty": f"{qty:+d}",
                "mark": round(mark_price, 2),
                "trade_price": round(trade_price, 2),
                "pnl_open": round(pnl_open, 2),
                "short_value": round(mark_price * 100, 2) if side == "short" else 0.0,
                "long_cost": round(mark_price * 100, 2) if side == "long" else 0.0,
                "limit_impact": round(mark_price * 100, 2),
                "side": side,
            })
    return normalized
