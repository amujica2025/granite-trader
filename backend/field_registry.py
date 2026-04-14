"""
Central registry for scanner strategies and output fields.

Both the entry scanner and the future roll scanner read from here.
The frontend uses /field-registry to populate:
  - strategy dropdown
  - column visibility toggle menu
  - sort-by options

Adding a new field: append to SCANNER_FIELDS.
Adding a new strategy: append to ENTRY_STRATEGIES and wire the logic in scanner.py.
"""

from __future__ import annotations
from typing import Any, Dict, List

# ---------------------------------------------------------------------------
# Entry strategies
# ---------------------------------------------------------------------------

ENTRY_STRATEGIES: List[Dict[str, Any]] = [
    {"id": "credit_spread",  "label": "Credit Spread",  "enabled": True},
    {"id": "butterfly",      "label": "Butterfly",       "enabled": False},
    {"id": "iron_fly",       "label": "Iron Fly",        "enabled": False},
    {"id": "iron_condor",    "label": "Iron Condor",     "enabled": False},
    {"id": "custom",         "label": "Custom",          "enabled": False},
]

# ---------------------------------------------------------------------------
# Scanner output fields
# ---------------------------------------------------------------------------
# applies_to: "entry" | "roll" | "both"
# default_visible: shown by default in the table

SCANNER_FIELDS: List[Dict[str, Any]] = [
    # --- identity ---
    {"id": "expiration",     "label": "Exp",           "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "option_side",    "label": "Side",          "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "short_strike",   "label": "Short",         "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "long_strike",    "label": "Long",          "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "width",          "label": "Width",         "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "quantity",       "label": "Qty",           "sortable": True,  "default_visible": True,  "applies_to": "both"},

    # --- pricing / capital ---
    {"id": "net_credit",            "label": "Net Credit",       "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "gross_defined_risk",    "label": "Gross Risk",       "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "max_loss",              "label": "Max Loss",         "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "short_value",           "label": "Short Value",      "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "long_cost",             "label": "Long Cost",        "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "limit_impact",          "label": "Limit Impact",     "sortable": True,  "default_visible": True,  "applies_to": "both"},

    # --- reward/risk metrics ---
    {"id": "credit_pct_risk",       "label": "Credit % Risk",    "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "credit_pct_risk_pct",   "label": "Credit % Risk %",  "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "reward_to_max_loss",    "label": "Reward/Max Loss",  "sortable": True,  "default_visible": False, "applies_to": "both"},

    # --- vol / Greeks ---
    {"id": "short_delta",  "label": "Short Î”",  "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "long_delta",   "label": "Long Î”",   "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "short_iv",     "label": "Short IV", "sortable": True,  "default_visible": True,  "applies_to": "both"},
    {"id": "long_iv",      "label": "Long IV",  "sortable": True,  "default_visible": False, "applies_to": "both"},
    {"id": "avg_iv",       "label": "Avg IV",   "sortable": True,  "default_visible": False, "applies_to": "both"},

    # --- relative ranking ---
    {"id": "richness_score",              "label": "Richness",          "sortable": True,  "default_visible": True,  "applies_to": "entry"},
    {"id": "credit_pct_risk_rank_within_exp", "label": "Credit Rank",   "sortable": True,  "default_visible": False, "applies_to": "entry"},
    {"id": "iv_rank_within_exp",          "label": "IV Rank",           "sortable": True,  "default_visible": False, "applies_to": "entry"},
    {"id": "credit_pct_vs_exp_avg",       "label": "vs Exp Avg Credit", "sortable": True,  "default_visible": False, "applies_to": "entry"},
    {"id": "iv_vs_exp_avg",               "label": "vs Exp Avg IV",     "sortable": True,  "default_visible": False, "applies_to": "entry"},
]

VALID_SORT_KEYS = {"credit", "credit_pct_risk", "limit_impact", "max_loss", "richness"}
