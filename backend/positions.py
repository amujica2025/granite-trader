from __future__ import annotations
from typing import Any, Dict, List

def explode_position_quantity(position: Dict[str, Any]) -> List[Dict[str, Any]]:
    qty = int(abs(position.get("quantity", 0)))
    sign = -1 if position.get("quantity", 0) < 0 else 1
    if qty == 0:
        return []
    rows: List[Dict[str, Any]] = []
    for idx in range(qty):
        row = dict(position)
        row["quantity"] = sign * 1
        row["exploded_index"] = idx + 1
        rows.append(row)
    return rows

def normalize_mock_positions() -> List[Dict[str, Any]]:
    raw = [
        {"underlying": "SPY", "instrument_type": "Equity Option", "option_type": "Call", "expiration": "2026-04-17", "strike": 520.0, "quantity": 1, "mark": 1.82, "trade_price": 1.55, "group": "Call Butterfly"},
        {"underlying": "SPY", "instrument_type": "Equity Option", "option_type": "Call", "expiration": "2026-04-17", "strike": 522.0, "quantity": -2, "mark": 0.91, "trade_price": 1.12, "group": "Call Butterfly"},
        {"underlying": "SPY", "instrument_type": "Equity Option", "option_type": "Call", "expiration": "2026-04-17", "strike": 524.0, "quantity": 1, "mark": 0.33, "trade_price": 0.28, "group": "Call Butterfly"},
        {"underlying": "SPY", "instrument_type": "Equity Option", "option_type": "Put", "expiration": "2026-04-17", "strike": 520.0, "quantity": -6, "mark": 1.05, "trade_price": 1.18, "group": "Put Credit Spread"},
        {"underlying": "SPY", "instrument_type": "Equity Option", "option_type": "Put", "expiration": "2026-04-17", "strike": 519.0, "quantity": 6, "mark": 1.00, "trade_price": 1.03, "group": "Put Credit Spread"},
    ]
    exploded: List[Dict[str, Any]] = []
    for row in raw:
        exploded.extend(explode_position_quantity(row))
    out: List[Dict[str, Any]] = []
    for row in exploded:
        qty = int(row["quantity"])
        side = "short" if qty < 0 else "long"
        option_type = str(row["option_type"]).lower()
        mark = float(row["mark"])
        trade_price = float(row["trade_price"])
        pnl_open = (trade_price - mark) * 100 if side == "short" else (mark - trade_price) * 100
        strike = float(row["strike"])
        out.append({
            "id": f'{row["underlying"]}-{row["expiration"]}-{option_type}-{strike}-{row["exploded_index"]}-{side}',
            "underlying": row["underlying"],
            "group": row["group"],
            "instrument_type": row["instrument_type"],
            "option_type": option_type,
            "expiration": row["expiration"],
            "strike": strike,
            "quantity": qty,
            "display_qty": f'{qty:+d}',
            "mark": round(mark, 2),
            "trade_price": round(trade_price, 2),
            "pnl_open": round(pnl_open, 2),
            "short_value": round(mark * 100, 2) if side == "short" else 0.0,
            "long_cost": round(mark * 100, 2) if side == "long" else 0.0,
            "limit_impact": round(mark * 100, 2),
            "side": side,
        })
    return out
