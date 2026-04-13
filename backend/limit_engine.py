from __future__ import annotations

from typing import Any, Dict, List


def compute_credit_pct_risk(net_credit: float, defined_risk: float) -> float:
    if defined_risk <= 0:
        return 0.0
    return net_credit / defined_risk


def compute_limit_summary(net_liq: float, positions: List[Dict[str, Any]]) -> Dict[str, float]:
    max_limit = net_liq * 25.0
    total_short_value = sum(float(p.get("short_value", 0.0)) for p in positions)
    remaining_room = max_limit - total_short_value
    used_pct = (total_short_value / max_limit) if max_limit else 0.0
    return {
        "net_liq": round(net_liq, 2),
        "max_limit": round(max_limit, 2),
        "used_short_value": round(total_short_value, 2),
        "remaining_room": round(remaining_room, 2),
        "used_pct": round(used_pct, 4),
    }


def compute_selected_totals(selected_rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    total_short_value = sum(float(r.get("short_value", 0.0)) for r in selected_rows)
    total_long_cost = sum(float(r.get("long_cost", 0.0)) for r in selected_rows)
    total_pnl = sum(float(r.get("pnl_open", 0.0)) for r in selected_rows)
    total_limit_impact = max(total_short_value, total_long_cost) if selected_rows else 0.0

    total_net_credit = sum(float(r.get("net_credit", 0.0)) for r in selected_rows)
    total_defined_risk = sum(float(r.get("defined_risk", 0.0)) for r in selected_rows)
    selected_credit_pct_risk = compute_credit_pct_risk(total_net_credit, total_defined_risk)

    return {
        "selected_legs": len(selected_rows),
        "selected_short_value": round(total_short_value, 2),
        "selected_long_cost": round(total_long_cost, 2),
        "selected_pnl_open": round(total_pnl, 2),
        "selected_limit_impact": round(total_limit_impact, 2),
        "selected_net_credit": round(total_net_credit, 2),
        "selected_defined_risk": round(total_defined_risk, 2),
        "selected_credit_pct_risk": round(selected_credit_pct_risk, 6),
        "selected_credit_pct_risk_pct": round(selected_credit_pct_risk * 100.0, 2),
    }